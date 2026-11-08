mock_provider "azurerm" {
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
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cost"
      principal_id = "00000000-0000-0000-0000-000000000008"
      client_id    = "00000000-0000-0000-0000-000000000009"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Storage/storageAccounts/aicost"
      primary_blob_endpoint = "https://aicost.blob.core.windows.net/"
    }
  }
  mock_resource "azurerm_monitor_data_collection_rule" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionRules/cost"
      immutable_id = "dcr-00000000000000000000000000000000"
    }
  }
  mock_resource "azurerm_monitor_data_collection_endpoint" {
    defaults = {
      id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionEndpoints/cost"
      logs_ingestion_endpoint = "https://example.eastus-1.ingest.monitor.azure.com"
    }
  }
  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Web/serverFarms/cost"
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

run "cost_pipeline_is_opt_in" {
  command = plan
  assert {
    condition = (
      length(azurerm_function_app_flex_consumption.cost) == 0 &&
      length(azurerm_log_analytics_workspace_table_custom_log.cost) == 0 &&
      length(azurerm_role_assignment.cost_reader) == 0 &&
      length(azurerm_role_definition.cost_group_query) == 0 &&
      length(azurerm_role_assignment.cost_group_query) == 0
    )
    error_message = "The Function, cost table, and subscription-wide permission must be opt-in."
  }
}

run "cost_pipeline_uses_managed_identity_and_complete_schema" {
  command = plan
  variables {
    enable_cost_pipeline = true
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  override_resource {
    target          = azurerm_monitor_data_collection_rule.cost[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionRules/cost"
    }
  }
  assert {
    condition = (
      azurerm_role_assignment.cost_reader[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      azurerm_role_assignment.cost_reader[0].role_definition_name == "Cost Management Reader" &&
      length(azurerm_role_definition.cost_group_query) == 0 &&
      length(azurerm_role_assignment.cost_group_query) == 0 &&
      azurerm_function_app_flex_consumption.cost[0].app_settings["COST_QUERY_SCOPE"] == "subscription" &&
      azurerm_role_assignment.cost_ingestion[0].scope == azurerm_monitor_data_collection_rule.cost[0].id &&
      azurerm_role_assignment.cost_ingestion[0].role_definition_name == "Monitoring Metrics Publisher"
    )
    error_message = "Cost access must be subscription-scoped and ingestion access limited to the DCR."
  }
  assert {
    condition = (
      azurerm_function_app_flex_consumption.cost[0].runtime_name == "powershell" &&
      azurerm_function_app_flex_consumption.cost[0].runtime_version == "7.6" &&
      azurerm_function_app_flex_consumption.cost[0].maximum_instance_count == 40 &&
      azurerm_function_app_flex_consumption.cost[0].storage_authentication_type == "UserAssignedIdentity" &&
      azurerm_function_app_flex_consumption.cost[0].app_settings["AzureWebJobsStorage__credential"] == "managedidentity" &&
      !azurerm_storage_account.cost[0].shared_access_key_enabled
    )
    error_message = "The Function and storage must use managed identity rather than account keys."
  }
  assert {
    condition = (
      azurerm_storage_account.cost[0].blob_properties[0].delete_retention_policy[0].days == 7 &&
      azurerm_storage_account.cost[0].blob_properties[0].container_delete_retention_policy[0].days == 7 &&
      length(azurerm_monitor_diagnostic_setting.cost_blob_read) == 1
    )
    error_message = "Cost deployment storage must retain deleted blobs and containers for seven days and log blob reads."
  }
  assert {
    condition = (
      azurerm_log_analytics_workspace_table_custom_log.cost[0].name == "AICostSnapshot_CL" &&
      contains([for c in azurerm_log_analytics_workspace_table_custom_log.cost[0].column : c.name], "ExpectedRows") &&
      contains([for c in azurerm_log_analytics_workspace_table_custom_log.cost[0].column : c.name], "UsageDate")
    )
    error_message = "The cost table must contain the snapshot completeness and usage-date fields."
  }
}

run "resource_group_cost_scope_omits_subscription_role" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroup"
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  override_resource {
    target          = azurerm_user_assigned_identity.cost[0]
    override_during = plan
    values = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cost"
      principal_id = "00000000-0000-0000-0000-000000000008"
      client_id    = "00000000-0000-0000-0000-000000000009"
    }
  }
  assert {
    condition = (
      length(azurerm_role_assignment.cost_reader) == 0 &&
      length(azurerm_role_definition.cost_group_query) == 0 &&
      length(azurerm_role_assignment.cost_group_query) == 0 &&
      azurerm_function_app_flex_consumption.cost[0].app_settings["COST_QUERY_SCOPE"] == "resourceGroup" &&
      output.cost_identity_principal_id == azurerm_user_assigned_identity.cost[0].principal_id
    )
    error_message = "Resource-group queries must not receive the automatic subscription cost role and must expose the identity for separate assignments."
  }
}

run "managed_resource_group_cost_roles_are_deduplicated_and_narrow" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
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
    target          = azurerm_user_assigned_identity.cost[0]
    override_during = plan
    values = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cost"
      principal_id = "00000000-0000-0000-0000-000000000008"
      client_id    = "00000000-0000-0000-0000-000000000009"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_group_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/foundry"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000011"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_group_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/openai"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000012"
    }
  }
  assert {
    condition = (
      length(azurerm_role_assignment.cost_reader) == 0 &&
      length(azurerm_role_definition.cost_group_query) == 2 &&
      length(azurerm_role_assignment.cost_group_query) == 2 &&
      azurerm_function_app_flex_consumption.cost[0].app_settings["COST_QUERY_SCOPE"] == "resourceGroup"
    )
    error_message = "Managed resource-group mode must deduplicate groups, omit the subscription role, and configure resource-group queries."
  }
  assert {
    condition = alltrue([
      for scope, role in azurerm_role_definition.cost_group_query :
      length(role.assignable_scopes) == 1 && role.assignable_scopes[0] == scope &&
      length(role.permissions) == 1 &&
      length(role.permissions[0].actions) == 1 &&
      role.permissions[0].actions[0] == "Microsoft.CostManagement/query/read" &&
      length(role.permissions[0].not_actions) == 0 &&
      length(role.permissions[0].data_actions) == 0 &&
      length(role.permissions[0].not_data_actions) == 0
    ])
    error_message = "Each custom role must be assignable only in its group and contain only the Cost Management query action."
  }
  assert {
    condition = alltrue([
      for scope, assignment in azurerm_role_assignment.cost_group_query :
      assignment.scope == scope &&
      assignment.role_definition_id == azurerm_role_definition.cost_group_query[scope].role_definition_resource_id &&
      assignment.principal_id == azurerm_user_assigned_identity.cost[0].principal_id &&
      assignment.principal_type == "ServicePrincipal"
    ])
    error_message = "Each assignment must bind the matching group-scoped role to the collector identity."
  }
}

run "managed_resource_group_roles_are_disabled_with_pipeline" {
  command = plan
  variables {
    enable_cost_pipeline = false
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  assert {
    condition = (
      length(azurerm_role_definition.cost_group_query) == 0 &&
      length(azurerm_role_assignment.cost_group_query) == 0
    )
    error_message = "Managed group roles must not exist when the cost pipeline is disabled."
  }
}

run "managed_resource_group_role_rejects_parent_scope" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/../providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "managed_resource_group_role_rejects_escaped_scope" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry%2fother/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "managed_resource_group_role_rejects_query_delimiter" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry?other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "managed_resource_group_role_rejects_fragment_delimiter" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry#other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "managed_resource_group_role_rejects_backslash_scope" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry\\other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "managed_resource_group_role_rejects_control_character_scope" {
  command = plan
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry\u0001other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_scope_must_be_valid" {
  command = plan
  variables {
    cost_query_scope = "invalid"
  }
  expect_failures = [var.cost_query_scope]
}

run "cost_collection_requires_accounts" {
  command = plan
  variables {
    enable_cost_pipeline = true
  }
  expect_failures = [azurerm_function_app_flex_consumption.cost]
}

run "cost_lookback_must_be_valid" {
  command = plan
  variables {
    cost_lookback_days = 7
  }
  expect_failures = [var.cost_lookback_days]
}

run "cost_collection_rejects_excessive_baseline_duration" {
  command = plan
  variables {
    enable_cost_pipeline = true
    monitored_accounts = {
      for i in range(15) : "account-${i}" => {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/account-${i}"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [azurerm_function_app_flex_consumption.cost]
}

run "cost_collection_accepts_maximum_default_accounts" {
  command = plan
  variables {
    enable_cost_pipeline = true
    monitored_accounts = {
      for i in range(14) : "account-${i}" => {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/account-${i}"
        ptu_deployments = []
      }
    }
  }
  assert {
    condition     = length(azurerm_function_app_flex_consumption.cost) == 1
    error_message = "Fourteen accounts with the default lookback must fit within the request-pacing limit."
  }
}

run "cost_scope_migration_initial_subscription_role" {
  command = apply
  plan_options {
    target = [azurerm_role_assignment.cost_reader]
  }
  variables {
    enable_cost_pipeline = true
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  assert {
    condition     = length(azurerm_role_assignment.cost_reader) == 1
    error_message = "The original subscription-scoped cost assignment must be represented in state."
  }
}

run "cost_scope_migration_removes_managed_subscription_role" {
  command = plan
  plan_options {
    target = [azurerm_role_assignment.cost_reader]
  }
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroup"
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  assert {
    condition     = length(azurerm_role_assignment.cost_reader) == 0
    error_message = "Switching to resource-group queries must remove the Terraform-managed subscription cost assignment."
  }
}

run "cost_scope_migration_to_managed_group_role" {
  command = plan
  plan_options {
    target = [azurerm_role_assignment.cost_reader, azurerm_role_assignment.cost_group_query]
  }
  variables {
    enable_cost_pipeline = true
    cost_query_scope     = "resourceGroupManaged"
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  assert {
    condition = (
      length(azurerm_role_assignment.cost_reader) == 0 &&
      length(azurerm_role_definition.cost_group_query) == 1 &&
      length(azurerm_role_assignment.cost_group_query) == 1
    )
    error_message = "Migrating to managed group mode must omit the old subscription assignment and create the group role and assignment."
  }
}
