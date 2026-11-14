mock_provider "azapi" {}

mock_provider "time" {}

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      object_id = "00000000-0000-0000-0000-0000000000b1"
    }
  }
}

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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
    monitored_accounts = {
      invalid = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry\u0001other/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}

run "cost_infinity_is_opt_in" {
  command = plan
  assert {
    condition = (
      length(azapi_update_resource.grafana_infinity_plugin) == 0 &&
      length(azuread_application.cost_infinity) == 0 &&
      length(azuread_service_principal.cost_infinity) == 0 &&
      length(azuread_application_password.cost_infinity) == 0 &&
      length(time_rotating.cost_infinity_secret) == 0 &&
      length(azurerm_role_definition.cost_infinity_query) == 0 &&
      length(azurerm_role_assignment.cost_infinity_query) == 0 &&
      output.cost_infinity_scope == null &&
      output.cost_infinity_client_id == null &&
      output.cost_infinity_client_secret == null &&
      output.cost_infinity_tenant_id == null
    )
    error_message = "The Infinity plugin, its principal, its roles and its outputs must be opt-in."
  }
}

run "cost_infinity_subscription_scope_installs_the_plugin_and_creates_a_query_only_principal" {
  command = plan
  variables {
    enable_cost_infinity = true
  }
  override_resource {
    target          = azuread_application.cost_infinity[0]
    override_during = plan
    values = {
      id        = "/applications/00000000-0000-0000-0000-0000000000a0"
      client_id = "00000000-0000-0000-0000-0000000000a1"
    }
  }
  override_resource {
    target          = azuread_service_principal.cost_infinity[0]
    override_during = plan
    values = {
      object_id = "00000000-0000-0000-0000-0000000000a2"
    }
  }
  override_resource {
    target          = time_rotating.cost_infinity_secret[0]
    override_during = plan
    values = {
      id               = "2027-02-11T00:00:00Z"
      rotation_rfc3339 = "2027-02-11T00:00:00Z"
    }
  }
  override_resource {
    target          = azuread_application_password.cost_infinity[0]
    override_during = plan
    values = {
      value = "mock-secret-value"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000021"
    }
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
      azuread_application.cost_infinity[0].sign_in_audience == "AzureADMyOrg" &&
      azuread_application.cost_infinity[0].display_name == "ai-observe-cost-query" &&
      azuread_application_password.cost_infinity[0].display_name == "grafana-infinity" &&
      time_rotating.cost_infinity_secret[0].rotation_days == 90 &&
      azuread_application_password.cost_infinity[0].end_date == "2027-03-13T00:00:00Z"
    )
    error_message = "Terraform must create a single-tenant application and a secret that expires 30 days after its 90-day rotation."
  }
  assert {
    condition = (
      length(azurerm_role_definition.cost_infinity_query) == 1 &&
      length(azurerm_role_assignment.cost_infinity_query) == 1 &&
      azurerm_role_assignment.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      azurerm_role_assignment.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000"].principal_id == "00000000-0000-0000-0000-0000000000a2" &&
      azurerm_role_assignment.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000"].principal_type == "ServicePrincipal"
    )
    error_message = "Subscription scope must assign one custom role to the created service principal."
  }
  assert {
    condition = alltrue([
      for scope, role in azurerm_role_definition.cost_infinity_query :
      length(role.assignable_scopes) == 1 && role.assignable_scopes[0] == scope &&
      length(role.permissions) == 1 &&
      length(role.permissions[0].actions) == 1 &&
      role.permissions[0].actions[0] == "Microsoft.CostManagement/query/read" &&
      length(role.permissions[0].not_actions) == 0 &&
      length(role.permissions[0].data_actions) == 0 &&
      length(role.permissions[0].not_data_actions) == 0
    ])
    error_message = "The subscription role must contain only the Cost Management query action, not a built-in reader role."
  }
  assert {
    condition = (
      output.cost_infinity_scope == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      output.cost_infinity_client_id == "00000000-0000-0000-0000-0000000000a1" &&
      output.cost_infinity_client_secret == "mock-secret-value"
    )
    error_message = "The outputs must carry the values the Grafana stage needs."
  }
}

run "cost_infinity_group_scope_grants_a_query_only_role_per_deduplicated_group" {
  command = plan
  variables {
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
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
    target          = azuread_service_principal.cost_infinity[0]
    override_during = plan
    values = {
      object_id = "00000000-0000-0000-0000-0000000000a2"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/foundry"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000021"
    }
  }
  override_resource {
    target          = azurerm_role_definition.cost_infinity_query["/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/openai"]
    override_during = plan
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000022"
    }
  }
  assert {
    condition = (
      length(azurerm_role_definition.cost_infinity_query) == 2 &&
      length(azurerm_role_assignment.cost_infinity_query) == 2 &&
      !contains(keys(azurerm_role_definition.cost_infinity_query), "/subscriptions/00000000-0000-0000-0000-000000000000")
    )
    error_message = "Group scope must omit the subscription role and deduplicate groups."
  }
  assert {
    condition = alltrue([
      for scope, role in azurerm_role_definition.cost_infinity_query :
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
      for scope, assignment in azurerm_role_assignment.cost_infinity_query :
      assignment.principal_id == "00000000-0000-0000-0000-0000000000a2" &&
      assignment.principal_type == "ServicePrincipal" &&
      assignment.role_definition_id == azurerm_role_definition.cost_infinity_query[scope].role_definition_resource_id
    ])
    error_message = "Each assignment must bind the matching group role to the Infinity service principal."
  }
  assert {
    condition     = output.cost_infinity_scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Foundry"
    error_message = "The default dashboard scope must be the first monitored resource group."
  }
}

run "cost_infinity_rejects_unknown_scope" {
  command = plan
  variables {
    cost_infinity_scope = "resourceGroup"
  }
  expect_failures = [var.cost_infinity_scope]
}

run "cost_infinity_rejects_unsafe_secret_rotation" {
  command = plan
  variables {
    cost_infinity_secret_rotation_days = 3
  }
  expect_failures = [var.cost_infinity_secret_rotation_days]
}

run "cost_infinity_group_scope_requires_monitored_accounts" {
  command = plan
  variables {
    enable_cost_infinity = true
    cost_infinity_scope  = "resourceGroupManaged"
  }
  expect_failures = [azapi_update_resource.grafana_infinity_plugin]
}
