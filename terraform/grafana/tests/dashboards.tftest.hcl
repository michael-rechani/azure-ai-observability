mock_provider "grafana" {}

variables {
  grafana_endpoint = "https://grafana.eastus.grafana.azure.com"
  subscription_id  = "00000000-0000-0000-0000-000000000000"
}

run "dashboard_bindings" {
  command = plan
  assert {
    condition     = length(grafana_dashboard.monitoring) == 3
    error_message = "Expected separate Foundry overview, agent, and PTU dashboards."
  }
  assert {
    condition     = !contains(keys(grafana_dashboard.monitoring), "business_overview")
    error_message = "The Business overview dashboard must not be created unless enable_business_overview is set."
  }

  assert {
    condition     = jsondecode(grafana_data_source.azure_monitor.json_data_encoded).azureAuthType == "msi"
    error_message = "The Azure Monitor data source must use managed identity."
  }
  assert {
    condition     = !strcontains(grafana_dashboard.monitoring["openai_ptu"].config_json, "$${DS_AZURE_MONITOR}")
    error_message = "Dashboard data source placeholder must be replaced."
  }
  assert {
    condition = alltrue(flatten([
      for dashboard in values(grafana_dashboard.monitoring) : [
        for link in try(jsondecode(dashboard.config_json).links, []) :
        contains(local.dashboard_uids, split("/", link.url)[2])
      ]
    ]))
    error_message = "Dashboard links must only target dashboards included in this deployment."
  }
  assert {
    condition = (
      [for v in jsondecode(grafana_dashboard.monitoring["openai_ptu"].config_json).templating.list : v.current.value] ==
      [for v in jsondecode(file("${var.dashboard_directory}/openai-ptu.json")).templating.list : v.current.value]
    )
    error_message = "Without configured defaults, existing dashboard values must be preserved."
  }
}

run "business_overview_is_opt_in" {
  command = plan
  variables {
    enable_business_overview = true
    dashboard_defaults = {
      monitoring_workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/monitoring"
    }
  }
  assert {
    condition = (
      length(grafana_dashboard.monitoring) == 4 &&
      contains(keys(grafana_dashboard.monitoring), "business_overview") &&
      !contains(keys(grafana_dashboard.monitoring), "azure_ai_costs")
    )
    error_message = "Enabling the Business overview must add only that dashboard without replacing the others."
  }
  assert {
    condition = (
      length(grafana_data_source.infinity) == 0 &&
      !contains(keys(grafana_dashboard.monitoring), "azure_ai_costs_infinity")
    )
    error_message = "Enabling the Business overview must not enable any cost data source or dashboard."
  }
  assert {
    condition     = !strcontains(grafana_dashboard.monitoring["business_overview"].config_json, "$${DS_AZURE_MONITOR}")
    error_message = "The business overview must use the provisioned Azure Monitor data source."
  }
  assert {
    condition = (
      { for v in jsondecode(grafana_dashboard.monitoring["foundry_agents"].config_json).templating.list : v.name => v.current.value } == {
        workspaceResourceId = var.dashboard_defaults.monitoring_workspace_resource_id
        agent               = "*"
      }
    )
    error_message = "Agent dashboards should use the monitoring workspace unless a separate telemetry workspace is configured, and show every agent by default."
  }
  assert {
    condition = one([
      for v in jsondecode(grafana_dashboard.monitoring["business_overview"].config_json).templating.list :
      v.current.value if v.name == "workspaceResourceId"
    ]) == var.dashboard_defaults.monitoring_workspace_resource_id
    error_message = "The Business overview must fall back to the monitoring workspace for telemetry."
  }
}

run "dashboard_defaults_target_real_resources" {
  command = plan
  variables {
    enable_business_overview = true
    dashboard_defaults = {
      monitoring_workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/costs"
      telemetry_workspace_resource_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/apps/providers/Microsoft.OperationalInsights/workspaces/agents"
      foundry_account = {
        resource_group = "foundry-rg"
        name           = "foundry-prod"
        region         = "eastus2"
      }
      ptu_account = {
        resource_group = "ptu-rg"
        name           = "openai-prod"
        region         = "westus3"
        deployment     = "gpt-ptu"
      }
    }
  }
  assert {
    condition = (
      { for v in jsondecode(grafana_dashboard.monitoring["foundry_overview"].config_json).templating.list : v.name => v.current.value } == {
        subscription        = var.subscription_id
        workspaceResourceId = var.dashboard_defaults.telemetry_workspace_resource_id
        resourceGroup       = "foundry-rg"
        account             = "foundry-prod"
        region              = "eastus2"
        deployment          = "*"
      }
    )
    error_message = "The Foundry dashboard must receive the selected Foundry account and telemetry workspace."
  }
  assert {
    condition = (
      { for v in jsondecode(grafana_dashboard.monitoring["openai_ptu"].config_json).templating.list : v.name => v.current.value } == {
        subscription  = var.subscription_id
        resourceGroup = "ptu-rg"
        account       = "openai-prod"
        region        = "westus3"
        deployment    = "gpt-ptu"
      }
    )
    error_message = "The PTU dashboard must receive its own account, region, and deployment."
  }
  assert {
    condition = (
      { for v in jsondecode(grafana_dashboard.monitoring["foundry_agents"].config_json).templating.list : v.name => v.current.value } == {
        workspaceResourceId = var.dashboard_defaults.telemetry_workspace_resource_id
        agent               = "*"
      } &&
      { for v in jsondecode(grafana_dashboard.monitoring["business_overview"].config_json).templating.list : v.name => v.current.value } == {
        workspaceResourceId = var.dashboard_defaults.telemetry_workspace_resource_id
        agent               = "*"
        ptuSubscription     = var.subscription_id
        ptuResourceGroup    = "ptu-rg"
        ptuAccount          = "openai-prod"
        ptuRegion           = "westus3"
        ptuDeployment       = "gpt-ptu"
      }
    )
    error_message = "Agent telemetry and the Business overview must use the telemetry workspace, and the Business overview must receive the PTU account."
  }
  assert {
    condition     = !contains(keys(grafana_dashboard.monitoring), "azure_ai_costs")
    error_message = "The removed cost dashboard must not be provisioned."
  }
  assert {
    condition = alltrue(flatten([
      for dashboard in values(grafana_dashboard.monitoring) : [
        for variable in jsondecode(dashboard.config_json).templating.list :
        variable.query == variable.current.value && variable.current.text == variable.current.value
      ]
    ]))
    error_message = "Every textbox query, displayed value, and selected value must agree."
  }
}

run "cost_infinity_dashboard_is_opt_in" {
  command = plan
  assert {
    condition     = length(grafana_data_source.infinity) == 0 && !contains(keys(grafana_dashboard.monitoring), "azure_ai_costs_infinity")
    error_message = "The Infinity data source and dashboard must be opt-in."
  }
}

run "cost_infinity_dashboard_binds_the_secret_only_in_secure_data" {
  command = plan
  variables {
    enable_cost_infinity_dashboard = true
    cost_infinity_tenant_id        = "00000000-0000-0000-0000-0000000000b1"
    cost_infinity_client_id        = "00000000-0000-0000-0000-0000000000b2"
    cost_infinity_client_secret    = "unit-test-secret-value"
  }
  assert {
    condition = (
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).auth_method == "oauth2" &&
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).oauthPassThru == false &&
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).allowedHosts == ["https://management.azure.com"] &&
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).oauth2.oauth2_type == "client_credentials" &&
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).oauth2.client_id == "00000000-0000-0000-0000-0000000000b2" &&
      jsondecode(grafana_data_source.infinity[0].json_data_encoded).oauth2.token_url == "https://login.microsoftonline.com/00000000-0000-0000-0000-0000000000b1/oauth2/token"
    )
    error_message = "The Infinity data source must sign in with the client credentials flow against the supplied tenant and client."
  }
  assert {
    condition = (
      jsondecode(grafana_data_source.infinity[0].secure_json_data_encoded).oauth2ClientSecret == "unit-test-secret-value" &&
      !strcontains(grafana_data_source.infinity[0].json_data_encoded, "unit-test-secret-value") &&
      !strcontains(grafana_dashboard.monitoring["azure_ai_costs_infinity"].config_json, "unit-test-secret-value")
    )
    error_message = "The client secret must live only in the data source's secure data."
  }
  assert {
    condition = (
      contains(keys(grafana_dashboard.monitoring), "azure_ai_costs_infinity") &&
      !strcontains(grafana_dashboard.monitoring["azure_ai_costs_infinity"].config_json, "$${DS_COST_INFINITY}") &&
      strcontains(grafana_dashboard.monitoring["azure_ai_costs_infinity"].config_json, "ai-observability-cost-infinity")
    )
    error_message = "The Infinity cost dashboard must use the provisioned Infinity data source."
  }
  assert {
    condition = (
      [for v in jsondecode(grafana_dashboard.monitoring["azure_ai_costs_infinity"].config_json).templating.list : v.current.value if v.name == "costScope"] ==
      ["/subscriptions/00000000-0000-0000-0000-000000000000"]
    )
    error_message = "The cost scope must default to the subscription."
  }
}

run "cost_infinity_dashboard_uses_the_configured_scope" {
  command = plan
  variables {
    enable_cost_infinity_dashboard = true
    cost_infinity_tenant_id        = "00000000-0000-0000-0000-0000000000b1"
    cost_infinity_client_id        = "00000000-0000-0000-0000-0000000000b2"
    cost_infinity_client_secret    = "unit-test-secret-value"
    cost_infinity_scope            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg"
  }
  assert {
    condition = (
      [for v in jsondecode(grafana_dashboard.monitoring["azure_ai_costs_infinity"].config_json).templating.list : [v.query, v.current.text, v.current.value] if v.name == "costScope"] ==
      [["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg"]]
    )
    error_message = "The textbox query, displayed value and selected value must all be the configured scope."
  }
}

run "cost_infinity_alert_watches_the_data_source_and_never_triggers_on_cost" {
  command = plan
  variables {
    enable_cost_infinity_dashboard = true
    cost_infinity_tenant_id        = "00000000-0000-0000-0000-0000000000b1"
    cost_infinity_client_id        = "00000000-0000-0000-0000-0000000000b2"
    cost_infinity_client_secret    = "unit-test-secret-value"
    cost_infinity_scope            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg"
  }
  assert {
    condition = (
      length(grafana_folder.infinity_alert) == 1 &&
      length(grafana_rule_group.infinity_alert) == 1 &&
      grafana_rule_group.infinity_alert[0].interval_seconds == 3600 &&
      grafana_rule_group.infinity_alert[0].rule[0].for == "60m"
    )
    error_message = "By default the alert must evaluate hourly and wait one extra hour before firing, so a throttled query does not page anyone."
  }
  assert {
    condition = (
      grafana_rule_group.infinity_alert[0].rule[0].exec_err_state == "Alerting" &&
      grafana_rule_group.infinity_alert[0].rule[0].no_data_state == "OK" &&
      grafana_rule_group.infinity_alert[0].rule[0].condition == "C"
    )
    error_message = "A query error must raise the alert, and an empty result must not."
  }
  assert {
    condition = (
      grafana_rule_group.infinity_alert[0].rule[0].labels.component == "cost-infinity" &&
      grafana_rule_group.infinity_alert[0].rule[0].labels.severity == "warning"
    )
    error_message = "The rule needs stable labels so a notification policy can route it."
  }
  assert {
    condition = (
      [for d in grafana_rule_group.infinity_alert[0].rule[0].data : d.ref_id] == ["A", "B", "C"] &&
      grafana_rule_group.infinity_alert[0].rule[0].data[0].datasource_uid == "ai-observability-cost-infinity" &&
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[0].model).parser == "jq-backend" &&
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[0].model).datasource.uid == "ai-observability-cost-infinity"
    )
    error_message = "The query must use the Infinity data source with the backend parser that alert rules require."
  }
  assert {
    condition = (
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[0].model).url == "https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry-rg/providers/Microsoft.CostManagement/query?api-version=2023-11-01" &&
      !strcontains(grafana_rule_group.infinity_alert[0].rule[0].data[0].model, "costScope")
    )
    error_message = "The query must target the configured scope, with no template variable left in it."
  }
  assert {
    condition = (
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[0].model).url_options.method == "POST" &&
      strcontains(jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[0].model).url_options.data, "microsoft.cognitiveservices/accounts")
    )
    error_message = "The alert must send the dashboard's own Cost Management request."
  }
  assert {
    condition = (
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[2].model).conditions[0].evaluator.type == "gt" &&
      jsondecode(grafana_rule_group.infinity_alert[0].rule[0].data[2].model).conditions[0].evaluator.params[0] >= 1000000000
    )
    error_message = "The threshold must be unreachable, so only a failing query can raise the alert."
  }
  assert {
    condition     = !anytrue([for d in grafana_rule_group.infinity_alert[0].rule[0].data : strcontains(d.model, "unit-test-secret-value")])
    error_message = "The client secret must not appear in the alert rule."
  }
}

run "cost_infinity_alert_follows_the_configured_timing" {
  command = plan
  variables {
    enable_cost_infinity_dashboard       = true
    cost_infinity_tenant_id              = "00000000-0000-0000-0000-0000000000b1"
    cost_infinity_client_id              = "00000000-0000-0000-0000-0000000000b2"
    cost_infinity_client_secret          = "unit-test-secret-value"
    cost_infinity_alert_interval_minutes = 120
    cost_infinity_alert_pending_minutes  = 0
  }
  assert {
    condition = (
      grafana_rule_group.infinity_alert[0].interval_seconds == 7200 &&
      grafana_rule_group.infinity_alert[0].rule[0].for == "0m"
    )
    error_message = "The interval and pending period must come from the variables."
  }
}

run "cost_infinity_alert_can_be_turned_off" {
  command = plan
  variables {
    enable_cost_infinity_dashboard = true
    cost_infinity_tenant_id        = "00000000-0000-0000-0000-0000000000b1"
    cost_infinity_client_id        = "00000000-0000-0000-0000-0000000000b2"
    cost_infinity_client_secret    = "unit-test-secret-value"
    enable_cost_infinity_alert     = false
  }
  assert {
    condition     = length(grafana_folder.infinity_alert) == 0 && length(grafana_rule_group.infinity_alert) == 0
    error_message = "Turning the alert off must create no folder or rule."
  }
}

run "cost_infinity_alert_is_absent_without_the_infinity_dashboard" {
  command = plan
  assert {
    condition     = length(grafana_folder.infinity_alert) == 0 && length(grafana_rule_group.infinity_alert) == 0
    error_message = "The alert must not exist unless the Infinity data source does."
  }
}

run "cost_infinity_alert_rejects_unreasonable_timing" {
  command = plan
  variables {
    cost_infinity_alert_interval_minutes = 1
    cost_infinity_alert_pending_minutes  = -5
  }
  expect_failures = [
    var.cost_infinity_alert_interval_minutes,
    var.cost_infinity_alert_pending_minutes,
  ]
}

run "cost_infinity_dashboard_requires_the_principal_and_secret" {
  command = plan
  variables {
    enable_cost_infinity_dashboard = true
  }
  expect_failures = [
    grafana_data_source.infinity[0],
  ]
}

run "cost_infinity_rejects_untrusted_scope" {
  command = plan
  variables {
    cost_infinity_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/a/../b"
  }
  expect_failures = [var.cost_infinity_scope]
}

run "cost_infinity_rejects_malformed_ids" {
  command = plan
  variables {
    cost_infinity_tenant_id = "not-a-guid"
    cost_infinity_client_id = "not-a-guid"
  }
  expect_failures = [
    var.cost_infinity_tenant_id,
    var.cost_infinity_client_id,
  ]
}

run "business_overview_requires_a_telemetry_workspace" {
  command = plan
  variables {
    enable_business_overview = true
  }
  expect_failures = [
    grafana_dashboard.monitoring["business_overview"],
  ]
}

run "business_overview_accepts_a_telemetry_workspace_alone" {
  command = plan
  variables {
    enable_business_overview = true
    dashboard_defaults = {
      telemetry_workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/apps/providers/Microsoft.OperationalInsights/workspaces/agents"
    }
  }
  assert {
    condition = one([
      for v in jsondecode(grafana_dashboard.monitoring["business_overview"].config_json).templating.list :
      v.current.value if v.name == "workspaceResourceId"
    ]) == var.dashboard_defaults.telemetry_workspace_resource_id
    error_message = "The Business overview needs only the telemetry workspace."
  }
}

run "reject_invalid_dashboard_workspace" {
  command = plan
  variables {
    dashboard_defaults = {
      monitoring_workspace_resource_id = "workspace-guid-not-a-resource-id"
    }
  }
  expect_failures = [var.dashboard_defaults]
}

run "reject_untrusted_grafana_endpoint" {
  command = plan
  variables {
    grafana_endpoint = "https://grafana.azure.com.attacker.example"
  }
  expect_failures = [var.grafana_endpoint]
}

run "reject_grafana_endpoint_with_path" {
  command = plan
  variables {
    grafana_endpoint = "https://grafana.eastus.grafana.azure.com/path"
  }
  expect_failures = [var.grafana_endpoint]
}
