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
    condition     = jsondecode(grafana_data_source.azure_monitor.json_data_encoded).azureAuthType == "msi"
    error_message = "The Azure Monitor data source must use managed identity."
  }
  assert {
    condition     = !strcontains(grafana_dashboard.monitoring["openai_ptu"].config_json, "$${DS_AZURE_MONITOR}")
    error_message = "Dashboard data source placeholder must be replaced."
  }
  assert {
    condition = (
      [for v in jsondecode(grafana_dashboard.monitoring["openai_ptu"].config_json).templating.list : v.current.value] ==
      [for v in jsondecode(file("${var.dashboard_directory}/openai-ptu.json")).templating.list : v.current.value]
    )
    error_message = "Without configured defaults, existing dashboard values must be preserved."
  }
}

run "cost_dashboard_is_opt_in" {
  command = plan
  variables {
    enable_cost_dashboard = true
    dashboard_defaults = {
      monitoring_workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/monitoring"
    }
  }
  assert {
    condition = (
      length(grafana_dashboard.monitoring) == 5 &&
      contains(keys(grafana_dashboard.monitoring), "azure_ai_costs") &&
      contains(keys(grafana_dashboard.monitoring), "business_overview")
    )
    error_message = "Enabling cost dashboards must add both cost and business overviews without replacing other dashboards."
  }
  assert {
    condition     = !strcontains(grafana_dashboard.monitoring["azure_ai_costs"].config_json, "$${DS_AZURE_MONITOR}")
    error_message = "The cost dashboard must use the provisioned Azure Monitor data source."
  }
  assert {
    condition     = !strcontains(grafana_dashboard.monitoring["business_overview"].config_json, "$${DS_AZURE_MONITOR}")
    error_message = "The business overview must use the provisioned Azure Monitor data source."
  }
  assert {
    condition = (
      one(jsondecode(grafana_dashboard.monitoring["foundry_agents"].config_json).templating.list).current.value ==
      var.dashboard_defaults.monitoring_workspace_resource_id
    )
    error_message = "Agent dashboards should use the monitoring workspace unless a separate telemetry workspace is configured."
  }
}

run "dashboard_defaults_target_real_resources" {
  command = plan
  variables {
    enable_cost_dashboard = true
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
      one(jsondecode(grafana_dashboard.monitoring["foundry_agents"].config_json).templating.list).current.value == var.dashboard_defaults.telemetry_workspace_resource_id &&
      one(jsondecode(grafana_dashboard.monitoring["azure_ai_costs"].config_json).templating.list).current.value == var.dashboard_defaults.monitoring_workspace_resource_id &&
      one([
        for v in jsondecode(grafana_dashboard.monitoring["business_overview"].config_json).templating.list :
        v.current.value if v.name == "monitoringWorkspaceResourceId"
      ]) == var.dashboard_defaults.monitoring_workspace_resource_id
    )
    error_message = "Agent telemetry and cost snapshots must use their independently selected workspaces."
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

run "cost_dashboard_requires_monitoring_workspace" {
  command = plan
  variables {
    enable_cost_dashboard = true
  }
  expect_failures = [
    grafana_dashboard.monitoring["azure_ai_costs"],
    grafana_dashboard.monitoring["business_overview"],
  ]
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
