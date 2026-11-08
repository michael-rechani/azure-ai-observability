resource "grafana_data_source" "azure_monitor" {
  type = "grafana-azure-monitor-datasource"
  name = "AI observability - Azure Monitor"
  uid  = "ai-observability-azure-monitor"
  json_data_encoded = jsonencode({
    azureAuthType  = "msi"
    subscriptionId = var.subscription_id
  })
}

locals {
  dashboard_files = merge({
    foundry_overview = "foundry-overview.json"
    foundry_agents   = "foundry-agents.json"
    openai_ptu       = "openai-ptu.json"
    }, var.enable_cost_dashboard ? {
    azure_ai_costs    = "azure-ai-costs.json"
    business_overview = "business-overview.json"
  } : {})

  source_dashboards = {
    for key, filename in local.dashboard_files :
    key => jsondecode(file("${var.dashboard_directory}/${filename}"))
  }
  dashboard_uids      = [for dashboard in values(local.source_dashboards) : dashboard.uid]
  telemetry_workspace = var.dashboard_defaults.telemetry_workspace_resource_id != null ? var.dashboard_defaults.telemetry_workspace_resource_id : var.dashboard_defaults.monitoring_workspace_resource_id
  telemetry_defaults = local.telemetry_workspace == null ? tomap({}) : tomap({
    workspaceResourceId = local.telemetry_workspace
  })
  cost_defaults = var.dashboard_defaults.monitoring_workspace_resource_id == null ? tomap({}) : tomap({
    workspaceResourceId = var.dashboard_defaults.monitoring_workspace_resource_id
  })
  business_cost_defaults = var.dashboard_defaults.monitoring_workspace_resource_id == null ? tomap({}) : tomap({
    monitoringWorkspaceResourceId = var.dashboard_defaults.monitoring_workspace_resource_id
  })
  foundry_defaults = var.dashboard_defaults.foundry_account == null ? tomap({}) : tomap({
    subscription  = var.subscription_id
    resourceGroup = var.dashboard_defaults.foundry_account.resource_group
    account       = var.dashboard_defaults.foundry_account.name
    region        = var.dashboard_defaults.foundry_account.region
    deployment    = var.dashboard_defaults.foundry_account.deployment
  })
  ptu_defaults = var.dashboard_defaults.ptu_account == null ? tomap({}) : tomap({
    subscription  = var.subscription_id
    resourceGroup = var.dashboard_defaults.ptu_account.resource_group
    account       = var.dashboard_defaults.ptu_account.name
    region        = var.dashboard_defaults.ptu_account.region
    deployment    = var.dashboard_defaults.ptu_account.deployment
  })
  business_ptu_defaults = var.dashboard_defaults.ptu_account == null ? tomap({}) : tomap({
    ptuSubscription  = var.subscription_id
    ptuResourceGroup = var.dashboard_defaults.ptu_account.resource_group
    ptuAccount       = var.dashboard_defaults.ptu_account.name
    ptuRegion        = var.dashboard_defaults.ptu_account.region
    ptuDeployment    = var.dashboard_defaults.ptu_account.deployment
  })
  dashboard_default_values = {
    foundry_overview = merge(local.foundry_defaults, local.telemetry_defaults)
    foundry_agents   = local.telemetry_defaults
    openai_ptu       = local.ptu_defaults
    azure_ai_costs   = local.cost_defaults
    business_overview = merge(
      local.telemetry_defaults,
      local.business_cost_defaults,
      local.business_ptu_defaults,
    )
  }
}

resource "grafana_dashboard" "monitoring" {
  for_each = local.dashboard_files
  config_json = replace(
    jsonencode(merge(local.source_dashboards[each.key], {
      links = [
        for link in try(local.source_dashboards[each.key].links, []) :
        link if contains(local.dashboard_uids, split("/", link.url)[2])
      ]
      templating = merge(local.source_dashboards[each.key].templating, {
        list = [
          for variable in local.source_dashboards[each.key].templating.list :
          contains(keys(local.dashboard_default_values[each.key]), variable.name) ? merge(variable, {
            query = local.dashboard_default_values[each.key][variable.name]
            current = merge(try(variable.current, {}), {
              text  = local.dashboard_default_values[each.key][variable.name]
              value = local.dashboard_default_values[each.key][variable.name]
            })
          }) : variable
        ]
      })
    })),
    "$${DS_AZURE_MONITOR}",
    grafana_data_source.azure_monitor.uid
  )
  overwrite = false

  lifecycle {
    precondition {
      condition     = !contains(["azure_ai_costs", "business_overview"], each.key) || var.dashboard_defaults.monitoring_workspace_resource_id != null
      error_message = "Set dashboard_defaults.monitoring_workspace_resource_id when enabling cost dashboards."
    }
    precondition {
      condition = alltrue([
        for name in keys(local.dashboard_default_values[each.key]) :
        contains([for variable in local.source_dashboards[each.key].templating.list : variable.name if variable.type == "textbox"], name)
      ])
      error_message = "Each configured dashboard default must match a textbox variable in the selected dashboard JSON."
    }
  }
}

output "dashboard_urls" {
  value = { for key, dashboard in grafana_dashboard.monitoring : key => dashboard.url }
}
