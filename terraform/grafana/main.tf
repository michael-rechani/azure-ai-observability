resource "grafana_data_source" "azure_monitor" {
  type = "grafana-azure-monitor-datasource"
  name = "AI observability - Azure Monitor"
  uid  = "ai-observability-azure-monitor"
  json_data_encoded = jsonencode({
    azureAuthType  = "msi"
    subscriptionId = var.subscription_id
  })
}

# Infinity cannot use a managed identity, so this is the one data source that holds a secret.
resource "grafana_data_source" "infinity" {
  count = var.enable_cost_infinity_dashboard ? 1 : 0
  type  = "yesoreyeram-infinity-datasource"
  name  = "AI observability - Cost Management (Infinity)"
  uid   = "ai-observability-cost-infinity"
  json_data_encoded = jsonencode({
    auth_method   = "oauth2"
    oauthPassThru = false
    allowedHosts  = ["https://management.azure.com"]
    oauth2 = {
      oauth2_type = "client_credentials"
      client_id   = var.cost_infinity_client_id
      token_url   = "https://login.microsoftonline.com/${coalesce(var.cost_infinity_tenant_id, "unset")}/oauth2/token"
      authStyle   = 1
    }
    oauth2EndPointParamsName1 = "resource"
  })
  secure_json_data_encoded = jsonencode({
    oauth2ClientSecret         = var.cost_infinity_client_secret
    oauth2EndPointParamsValue1 = "https://management.azure.com/"
  })

  lifecycle {
    precondition {
      condition = alltrue([
        var.cost_infinity_tenant_id != null,
        var.cost_infinity_client_id != null,
        var.cost_infinity_client_secret != null,
      ])
      error_message = "Set cost_infinity_tenant_id, cost_infinity_client_id and cost_infinity_client_secret (through TF_VAR_cost_infinity_client_secret) when enabling the Infinity cost dashboard."
    }
  }
}

locals {
  dashboard_files = merge({
    foundry_overview = "foundry-overview.json"
    foundry_agents   = "foundry-agents.json"
    openai_ptu       = "openai-ptu.json"
    }, var.enable_business_overview ? {
    business_overview = "business-overview.json"
    } : {}, var.enable_cost_infinity_dashboard ? {
    azure_ai_costs_infinity = "azure-ai-costs-infinity.json"
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
    foundry_overview        = merge(local.foundry_defaults, local.telemetry_defaults)
    foundry_agents          = local.telemetry_defaults
    openai_ptu              = local.ptu_defaults
    azure_ai_costs_infinity = tomap({ costScope = var.cost_infinity_scope != null ? var.cost_infinity_scope : "/subscriptions/${var.subscription_id}" })
    business_overview = merge(
      local.telemetry_defaults,
      local.business_ptu_defaults,
    )
  }
}

resource "grafana_dashboard" "monitoring" {
  for_each = local.dashboard_files
  config_json = replace(
    replace(
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
    ),
    "$${DS_COST_INFINITY}",
    try(grafana_data_source.infinity[0].uid, "")
  )
  overwrite = false

  lifecycle {
    precondition {
      condition     = each.key != "business_overview" || local.telemetry_workspace != null
      error_message = "Set dashboard_defaults.telemetry_workspace_resource_id (or monitoring_workspace_resource_id) when enabling the Business overview dashboard."
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

locals {
  infinity_alert_enabled = var.enable_cost_infinity_dashboard && var.enable_cost_infinity_alert
  infinity_alert_scope   = local.dashboard_default_values.azure_ai_costs_infinity.costScope
  # The alert sends the dashboard's own request, so a failure here is a failure the panels would show too.
  infinity_alert_target = local.infinity_alert_enabled ? one(flatten([
    for panel in local.source_dashboards["azure_ai_costs_infinity"].panels : [
      for target in try(panel.targets, []) : target if panel.title == "Month-to-date actual cost by currency"
    ]
  ])) : null
}

resource "grafana_folder" "infinity_alert" {
  count = local.infinity_alert_enabled ? 1 : 0
  title = "AI observability alerts"
  uid   = "ai-observability-alerts"
}
