mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.CostManagement/exports/cost"
      identity = {
        type         = "SystemAssigned"
        principal_id = "00000000-0000-0000-0000-000000000011"
        tenant_id    = "00000000-0000-0000-0000-000000000007"
      }
    }
  }
}

mock_provider "azurerm" {
  mock_resource "azurerm_kusto_cluster" {
    defaults = {
      id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Kusto/clusters/adx"
      uri = "https://adx.eastus.kusto.windows.net"
      identity = {
        type         = "SystemAssigned"
        principal_id = "00000000-0000-0000-0000-000000000010"
        tenant_id    = "00000000-0000-0000-0000-000000000007"
      }
    }
  }
  mock_resource "azurerm_kusto_database" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Kusto/clusters/adx/databases/costs"
    }
  }
  mock_data "azurerm_resource_group" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring"
      name = "monitoring"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/logs"
    }
  }
  mock_resource "azurerm_application_insights" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Insights/components/insights"
    }
  }
  mock_resource "azurerm_dashboard_grafana" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Dashboard/grafana/grafana"
      identity = {
        principal_id = "00000000-0000-0000-0000-000000000006"
        tenant_id    = "00000000-0000-0000-0000-000000000007"
      }
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Storage/storageAccounts/aicost"
      primary_blob_endpoint = "https://aicost.blob.core.windows.net/"
    }
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  resource_group_name     = "monitoring"
  location                = "eastus"
  grafana_admin_object_id = "00000000-0000-0000-0000-000000000001"
  notification_email      = "demo@example.invalid"
}

run "ptu_alerts_for_provisioned_deployments" {
  command = plan
  variables {
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
      ptu = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.utilization) == 1 && length(azurerm_monitor_metric_alert.throttling) == 1
    error_message = "Only accounts with provisioned deployments should receive alerts."
  }
  assert {
    condition     = one(azurerm_monitor_metric_alert.utilization["ptu"].criteria).metric_name == "AzureOpenAIProvisionedManagedUtilizationV2"
    error_message = "Utilization alert must use the current V2 metric."
  }
  assert {
    condition = anytrue([
      for dimension in one(azurerm_monitor_metric_alert.throttling["ptu"].criteria).dimension :
      dimension.name == "StatusCode" && contains(dimension.values, "429")
    ])
    error_message = "Throttling alert must filter on HTTP 429."
  }
}

run "alerts_can_be_disabled" {
  command = plan
  variables {
    enable_ptu_alerts = false
    monitored_accounts = {
      ptu = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.utilization) == 0 && length(azurerm_monitor_metric_alert.throttling) == 0
    error_message = "Disabling alerts must omit both PTU rules."
  }
}

run "agent_alerts_are_opt_in" {
  command = plan
  assert {
    condition = (
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_failure_rate) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_p95_latency) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_heartbeat) == 0
    )
    error_message = "Agent log alerts must remain disabled until telemetry and traffic expectations are validated."
  }
}

run "agent_alerts_use_explicit_windows_and_action_group" {
  command = plan
  variables {
    enable_agent_alerts = true
  }
  assert {
    condition = (
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_failure_rate) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_p95_latency) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.agent_heartbeat) == 1
    )
    error_message = "Enabling agent alerting must create failure-rate, p95 latency, and heartbeat rules."
  }
  assert {
    condition = (
      one(azurerm_monitor_scheduled_query_rules_alert_v2.agent_failure_rate).window_duration == "PT10M" &&
      one(azurerm_monitor_scheduled_query_rules_alert_v2.agent_heartbeat).window_duration == "PT15M"
    )
    error_message = "Agent alerts must use bounded windows matching their KQL query periods."
  }
}

run "ai_cost_budget_is_opt_in_and_scoped_to_accounts" {
  command = plan
  variables {
    monthly_ai_cost_budget_amount = 500
    cost_budget_start_date        = "2026-01-01T00:00:00Z"
    cost_budget_end_date          = "2027-01-01T00:00:00Z"
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
      ptu = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  assert {
    condition     = length(azurerm_consumption_budget_subscription.ai_accounts) == 1
    error_message = "A positive budget amount must create one subscription budget."
  }
  assert {
    condition = contains(
      one(one(one(azurerm_consumption_budget_subscription.ai_accounts).filter).dimension).values,
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
    )
    error_message = "The budget must include only the explicitly monitored account resource IDs."
  }
}

run "create_monitoring_resource_group" {
  command = plan
  variables {
    create_resource_group = true
    telemetry_publisher_principals = {
      agent = {
        principal_id = "00000000-0000-0000-0000-000000000003"
      }
    }
  }
  assert {
    condition     = length(azurerm_resource_group.monitoring) == 1 && azurerm_resource_group.monitoring[0].name == "monitoring" && azurerm_resource_group.monitoring[0].location == "eastus"
    error_message = "The monitoring resource group should be created when requested."
  }
  assert {
    condition     = length(data.azurerm_resource_group.monitoring) == 0
    error_message = "A managed resource group must not also be read as an existing group."
  }
  assert {
    condition     = azurerm_role_assignment.telemetry_publisher["agent"].role_definition_name == "Monitoring Metrics Publisher" && azurerm_role_assignment.telemetry_publisher["agent"].principal_type == "ServicePrincipal"
    error_message = "Configured agent identities must receive telemetry publishing permission."
  }
}

run "use_existing_resource_group_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_resource_group.monitoring) == 0 && length(data.azurerm_resource_group.monitoring) == 1
    error_message = "Existing deployments must keep using their existing resource group by default."
  }
  assert {
    condition     = length(azurerm_role_assignment.telemetry_publisher) == 0
    error_message = "Telemetry publisher access must be opt-in."
  }
  assert {
    condition     = length(azurerm_role_assignment.grafana_viewer) == 0
    error_message = "Grafana Viewer access must be opt-in."
  }
  assert {
    condition     = local.suffix == substr(sha256(lower(data.azurerm_resource_group.monitoring[0].id)), 0, 8)
    error_message = "Existing resource names must retain their resource-group-based suffix."
  }
}

run "business_users_can_view_grafana" {
  command = apply
  variables {
    grafana_viewer_principals = {
      business_group = { principal_id = "00000000-0000-0000-0000-000000000004" }
      analyst = {
        principal_id   = "00000000-0000-0000-0000-000000000005"
        principal_type = "User"
      }
    }
  }
  assert {
    condition = (
      length(azurerm_role_assignment.grafana_viewer) == 2 &&
      azurerm_role_assignment.grafana_viewer["business_group"].role_definition_name == "Grafana Viewer" &&
      azurerm_role_assignment.grafana_viewer["business_group"].principal_type == "Group" &&
      azurerm_role_assignment.grafana_viewer["business_group"].scope == azurerm_dashboard_grafana.monitoring.id &&
      azurerm_role_assignment.grafana_viewer["analyst"].principal_type == "User"
    )
    error_message = "Configured groups and users must receive Grafana Viewer on the Grafana workspace only."
  }
}

run "reject_duplicate_grafana_viewers" {
  command = plan
  variables {
    grafana_viewer_principals = {
      first  = { principal_id = "00000000-0000-0000-0000-000000000004" }
      second = { principal_id = "00000000-0000-0000-0000-000000000004" }
    }
  }
  expect_failures = [var.grafana_viewer_principals]
}

run "reject_invalid_grafana_viewer" {
  command = plan
  variables {
    grafana_viewer_principals = {
      invalid = {
        principal_id   = "not-an-object-id"
        principal_type = "Application"
      }
    }
  }
  expect_failures = [var.grafana_viewer_principals]
}

run "reject_duplicate_telemetry_publishers" {
  command = plan
  variables {
    telemetry_publisher_principals = {
      first  = { principal_id = "00000000-0000-0000-0000-000000000003" }
      second = { principal_id = "00000000-0000-0000-0000-000000000003" }
    }
  }
  expect_failures = [var.telemetry_publisher_principals]
}

run "reject_invalid_telemetry_publisher" {
  command = plan
  variables {
    telemetry_publisher_principals = {
      invalid = {
        principal_id   = "not-an-object-id"
        principal_type = "Application"
      }
    }
  }
  expect_failures = [var.telemetry_publisher_principals]
}

run "reject_other_subscription" {
  command = plan
  variables {
    monitored_accounts = {
      other = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_parent_scope" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/../providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_escaped_scope" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry%2fother/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_query_delimiter" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry?other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_fragment_delimiter" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry#other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_backslash_scope" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry\\other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_group_role_rejects_control_character_scope" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry\u0001other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_export_is_opt_in" {
  command = plan
  assert {
    condition = (
      length(azurerm_storage_account.cost_export) == 0 &&
      length(azurerm_kusto_cluster.cost_export) == 0 &&
      length(azurerm_kusto_script.cost_export) == 0 &&
      length(azapi_resource.cost_export) == 0 &&
      length(azurerm_role_assignment.cost_export_writer) == 0
    )
    error_message = "The export storage, Azure Data Explorer cluster, and exports must be opt-in."
  }
}

run "cost_export_is_secretless_end_to_end" {
  command = plan
  variables {
    enable_cost_export     = true
    cost_export_start_date = "2026-11-10"
  }
  assert {
    condition = (
      azurerm_storage_account.cost_export[0].shared_access_key_enabled == false &&
      azurerm_storage_account.cost_export[0].network_rules[0].default_action == "Deny" &&
      contains(azurerm_storage_account.cost_export[0].network_rules[0].bypass, "AzureServices") &&
      length(azurerm_storage_container.cost_export) == 2
    )
    error_message = "Export storage must disable shared keys and admit only trusted Azure services."
  }
  assert {
    condition = (
      azurerm_kusto_cluster.cost_export[0].identity[0].type == "SystemAssigned" &&
      azurerm_kusto_cluster.cost_export[0].auto_stop_enabled == false &&
      azurerm_kusto_cluster.cost_export[0].sku[0].name == "Dev(No SLA)_Standard_E2a_v4"
    )
    error_message = "The cluster must use a system identity, must not auto-stop, and must default to the smallest Dev/Test SKU."
  }
  assert {
    condition = (
      azurerm_role_assignment.cost_export_reader[0].role_definition_name == "Storage Blob Data Reader" &&
      azurerm_kusto_database_principal_assignment.cost_export_grafana[0].role == "Viewer" &&
      azurerm_kusto_database_principal_assignment.cost_export_grafana[0].principal_type == "App" &&
      azurerm_kusto_database_principal_assignment.cost_export_grafana[0].database_name == "costs"
    )
    error_message = "The cluster must read storage and Grafana must be a database viewer, with nothing broader."
  }
  assert {
    condition = (
      azurerm_kusto_cluster_principal_assignment.cost_export_deployer[0].role == "AllDatabasesAdmin" &&
      azurerm_kusto_cluster_principal_assignment.cost_export_deployer[0].principal_type == "User"
    )
    error_message = "The deployer must be granted the cluster role that can set the managed-identity policy, so the database script can run."
  }
  assert {
    condition = (
      toset(keys(azapi_resource.cost_export)) == toset(["closed", "current"]) &&
      toset(keys(azurerm_role_assignment.cost_export_writer)) == toset(["closed", "current"]) &&
      alltrue([
        for role in values(azurerm_role_assignment.cost_export_writer) :
        role.role_definition_name == "Storage Blob Data Contributor"
      ])
    )
    error_message = "Each export needs its own identity granted write access to the export storage."
  }
  assert {
    condition = (
      azapi_resource.cost_export["current"].body.properties.schedule.status == "Active" &&
      azapi_resource.cost_export["current"].body.properties.schedule.recurrence == "Daily" &&
      azapi_resource.cost_export["current"].body.properties.definition.timeframe == "MonthToDate" &&
      azapi_resource.cost_export["closed"].body.properties.schedule.recurrence == "Monthly" &&
      azapi_resource.cost_export["closed"].body.properties.definition.timeframe == "TheLastMonth" &&
      azapi_resource.cost_export["closed"].body.properties.dataOverwriteBehavior == "OverwritePreviousReport"
    )
    error_message = "Exports must be active, with a daily month-to-date and a monthly closed-month schedule that overwrite previous reports."
  }
  assert {
    condition = (
      azapi_resource.cost_export["current"].body.properties.schedule.recurrencePeriod.from == "2026-11-10T00:00:00Z" &&
      azapi_resource.cost_export["current"].body.properties.schedule.recurrencePeriod.to == "2031-11-09T00:00:00Z"
    )
    error_message = "The schedule must start on the configured date and default to about five years."
  }
}

run "cost_export_requires_start_date" {
  command = plan
  variables {
    enable_cost_export = true
  }
  expect_failures = [
    azapi_resource.cost_export["current"],
    azapi_resource.cost_export["closed"],
  ]
}

run "cost_export_rejects_malformed_start_date" {
  command = plan
  variables {
    cost_export_start_date = "11/10/2026"
  }
  expect_failures = [var.cost_export_start_date]
}

run "cost_export_rejects_unknown_deployer_principal_type" {
  command = plan
  variables {
    cost_export_deployer_principal_type = "ServicePrincipal"
  }
  expect_failures = [var.cost_export_deployer_principal_type]
}

run "cost_export_grafana_access_defaults_to_public" {
  command = plan
  variables {
    enable_cost_export     = true
    cost_export_start_date = "2026-11-10"
  }
  assert {
    condition = (
      azurerm_kusto_cluster.cost_export[0].public_network_access_enabled == true &&
      length(azapi_resource.cost_export_grafana_private_endpoint) == 0
    )
    error_message = "By default Grafana uses the public endpoint and no managed private endpoint is created."
  }
}

run "cost_export_private_endpoint_keeps_public_access" {
  command = plan
  variables {
    enable_cost_export         = true
    cost_export_start_date     = "2026-11-10"
    cost_export_grafana_access = "privateEndpoint"
  }
  assert {
    condition = (
      azurerm_kusto_cluster.cost_export[0].public_network_access_enabled == true &&
      length(azapi_resource.cost_export_grafana_private_endpoint) == 1 &&
      azapi_resource.cost_export_grafana_private_endpoint[0].type == "Microsoft.Dashboard/grafana/managedPrivateEndpoints@2024-10-01" &&
      azapi_resource.cost_export_grafana_private_endpoint[0].body.properties.groupIds[0] == "cluster"
    )
    error_message = "privateEndpoint must add the Grafana managed private endpoint to the cluster group without closing the public endpoint."
  }
}

run "cost_export_private_only_disables_public_access" {
  command = plan
  variables {
    enable_cost_export         = true
    cost_export_start_date     = "2026-11-10"
    cost_export_grafana_access = "privateOnly"
  }
  assert {
    condition = (
      azurerm_kusto_cluster.cost_export[0].public_network_access_enabled == false &&
      length(azapi_resource.cost_export_grafana_private_endpoint) == 1
    )
    error_message = "privateOnly must create the managed private endpoint and disable the cluster public endpoint."
  }
}

run "cost_export_rejects_unknown_grafana_access" {
  command = plan
  variables {
    cost_export_grafana_access = "private"
  }
  expect_failures = [var.cost_export_grafana_access]
}

run "cost_infinity_is_opt_in" {
  command = plan
  assert {
    condition = (
      length(azapi_update_resource.grafana_infinity_plugin) == 0 &&
      length(azurerm_role_assignment.cost_infinity_reader) == 0 &&
      length(azurerm_role_definition.cost_infinity_group_query) == 0 &&
      length(azurerm_role_assignment.cost_infinity_group_query) == 0 &&
      output.cost_infinity_scope == null &&
      output.cost_infinity_client_id == null &&
      output.cost_infinity_tenant_id == null
    )
    error_message = "The Infinity plugin, its roles and its outputs must be opt-in."
  }
}

run "cost_infinity_subscription_scope_installs_the_plugin_and_grants_cost_reader" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
  }
  assert {
    condition = (
      azapi_update_resource.grafana_infinity_plugin[0].type == "Microsoft.Dashboard/grafana@2025-08-01" &&
      azapi_update_resource.grafana_infinity_plugin[0].body.properties.grafanaPlugins == { "yesoreyeram-infinity-datasource" = {} }
    )
    error_message = "The plugin must be installed through the Grafana workspace's grafanaPlugins property."
  }
  assert {
    condition = (
      length(azurerm_role_assignment.cost_infinity_reader) == 1 &&
      azurerm_role_assignment.cost_infinity_reader[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      azurerm_role_assignment.cost_infinity_reader[0].role_definition_name == "Cost Management Reader" &&
      azurerm_role_assignment.cost_infinity_reader[0].principal_id == "00000000-0000-0000-0000-0000000000a2" &&
      azurerm_role_assignment.cost_infinity_reader[0].principal_type == "ServicePrincipal" &&
      length(azurerm_role_definition.cost_infinity_group_query) == 0
    )
    error_message = "Subscription scope must grant only Cost Management Reader to the supplied service principal."
  }
  assert {
    condition = (
      output.cost_infinity_scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      output.cost_infinity_client_id == "00000000-0000-0000-0000-0000000000a1"
    )
    error_message = "The outputs must carry the values the Grafana stage needs, and never a secret."
  }
}

run "cost_infinity_group_scope_grants_a_query_only_role_per_deduplicated_group" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
    monitored_accounts = {
      first = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Foundry/providers/Microsoft.CognitiveServices/accounts/first"
        ptu_deployments = []
      }
      second = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/second"
        ptu_deployments = []
      }
      third = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/third"
        ptu_deployments = []
      }
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_infinity_group_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/foundry"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000021"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_infinity_group_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/openai"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000022"
    }
  }
  assert {
    condition = (
      length(azurerm_role_assignment.cost_infinity_reader) == 0 &&
      length(azurerm_role_definition.cost_infinity_group_query) == 2 &&
      length(azurerm_role_assignment.cost_infinity_group_query) == 2
    )
    error_message = "Group scope must omit the subscription role and deduplicate groups."
  }
  assert {
    condition = alltrue([
      for scope, role in azurerm_role_definition.cost_infinity_group_query :
      length(role.assignable_scopes) == 1 && role.assignable_scopes[0] == scope &&
      length(role.permissions) == 1 &&
      length(role.permissions[0].actions) == 1 &&
      role.permissions[0].actions[0] == "Microsoft.CostManagement/query/read" &&
      length(role.permissions[0].not_actions) == 0 &&
      length(role.permissions[0].data_actions) == 0 &&
      length(role.permissions[0].not_data_actions) == 0 &&
      startswith(role.name, "AI Observatory Cost Query infinity-cost ")
    ])
    error_message = "Each custom role must be assignable only in its group and contain only the Cost Management query action."
  }
  assert {
    condition = alltrue([
      for scope, assignment in azurerm_role_assignment.cost_infinity_group_query :
      assignment.principal_id == "00000000-0000-0000-0000-0000000000a2" &&
      assignment.principal_type == "ServicePrincipal" &&
      assignment.role_definition_id == azurerm_role_definition.cost_infinity_group_query[scope].role_definition_resource_id
    ])
    error_message = "Each assignment must bind the matching group role to the Infinity service principal."
  }
  assert {
    condition     = output.cost_infinity_scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Foundry"
    error_message = "The default dashboard scope must be the first monitored resource group."
  }
}

run "cost_infinity_requires_real_principal_ids" {
  command = plan
  variables {
    enable_cost_infinity = true
  }
  expect_failures = [
    var.cost_infinity_client_id,
    var.cost_infinity_service_principal_object_id,
  ]
}

run "cost_infinity_rejects_the_placeholder_ids" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-000000000000"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-000000000000"
  }
  expect_failures = [
    var.cost_infinity_client_id,
    var.cost_infinity_service_principal_object_id,
  ]
}

run "cost_infinity_rejects_unknown_scope" {
  command = plan
  variables {
    cost_infinity_scope = "resourceGroup"
  }
  expect_failures = [var.cost_infinity_scope]
}

run "cost_infinity_group_scope_requires_monitored_accounts" {
  command = plan
  variables {
    enable_cost_infinity                      = true
    cost_infinity_client_id                   = "00000000-0000-0000-0000-0000000000a1"
    cost_infinity_service_principal_object_id = "00000000-0000-0000-0000-0000000000a2"
    cost_infinity_scope                       = "resourceGroupManaged"
  }
  expect_failures = [azapi_update_resource.grafana_infinity_plugin]
}
