# Optional direct Cost Management queries through the Grafana Infinity plugin. Unlike the rest of
# this stack it is not secretless: the service principal and its client secret are created outside
# Terraform, and the secret goes only to the Grafana stage.
locals {
  cost_infinity_plugin_id = "yesoreyeram-infinity-datasource"
  cost_infinity_group_candidates = var.enable_cost_infinity && var.cost_infinity_scope == "resourceGroupManaged" ? {
    for account in values(var.monitored_accounts) :
    lower(join("/", slice(split("/", account.resource_id), 0, 5))) =>
    "/subscriptions/${split("/", account.resource_id)[2]}/resourceGroups/${split("/", account.resource_id)[4]}"...
    if length(split("/", account.resource_id)) >= 5
  } : {}
  cost_infinity_group_scopes = { for key, scopes in local.cost_infinity_group_candidates : key => scopes[0] }
}

# Replacing this resource only repeats the PATCH, so any update of the Grafana workspace reinstalls
# the plugin instead of leaving it dropped.
resource "azapi_update_resource" "grafana_infinity_plugin" {
  count       = var.enable_cost_infinity ? 1 : 0
  type        = "Microsoft.Dashboard/grafana@2025-08-01"
  resource_id = azurerm_dashboard_grafana.monitoring.id
  body = {
    properties = {
      grafanaPlugins = {
        (local.cost_infinity_plugin_id) = {}
      }
    }
  }

  lifecycle {
    replace_triggered_by = [azurerm_dashboard_grafana.monitoring]
    precondition {
      condition     = var.cost_infinity_scope != "resourceGroupManaged" || length(var.monitored_accounts) > 0
      error_message = "cost_infinity_scope = resourceGroupManaged needs at least one monitored account."
    }
  }
}

resource "azurerm_role_assignment" "cost_infinity_reader" {
  count                            = var.enable_cost_infinity && var.cost_infinity_scope == "subscription" ? 1 : 0
  scope                            = "/subscriptions/${var.subscription_id}"
  role_definition_name             = "Cost Management Reader"
  principal_id                     = var.cost_infinity_service_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_definition" "cost_infinity_group_query" {
  for_each    = local.cost_infinity_group_scopes
  name        = "AI Observatory Cost Query infinity-cost ${substr(sha256("${local.cost_suffix}/infinity/${each.key}"), 0, 16)}"
  scope       = "/subscriptions/${var.subscription_id}"
  description = "Query Cost Management at one monitored resource group for the Infinity service principal."

  permissions {
    actions          = ["Microsoft.CostManagement/query/read"]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = [each.key]
}

resource "azurerm_role_assignment" "cost_infinity_group_query" {
  for_each                         = local.cost_infinity_group_scopes
  scope                            = each.value
  role_definition_id               = azurerm_role_definition.cost_infinity_group_query[each.key].role_definition_resource_id
  principal_id                     = var.cost_infinity_service_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
