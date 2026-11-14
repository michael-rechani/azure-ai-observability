# Optional direct Cost Management queries through the Grafana Infinity plugin. Unlike the rest of
# this stack it is not secretless: Infinity can only sign in with a client secret. Terraform creates
# the app registration, service principal and a rotating secret, and grants the principal one
# read-only action. The secret reaches only the Grafana stage, through a sensitive output.
locals {
  cost_infinity_plugin_id = "yesoreyeram-infinity-datasource"
  cost_infinity_group_candidates = var.enable_cost_infinity && var.cost_infinity_scope == "resourceGroupManaged" ? {
    for account in values(var.monitored_accounts) :
    lower(join("/", slice(split("/", account.resource_id), 0, 5))) =>
    "/subscriptions/${split("/", account.resource_id)[2]}/resourceGroups/${split("/", account.resource_id)[4]}"...
    if length(split("/", account.resource_id)) >= 5
  } : {}
  cost_infinity_group_scopes = { for key, scopes in local.cost_infinity_group_candidates : key => scopes[0] }

  # One query-only role per scope: the whole subscription, or each monitored resource group.
  cost_infinity_role_scopes = !var.enable_cost_infinity ? {} : (
    var.cost_infinity_scope == "subscription" ? {
      (lower("/subscriptions/${var.subscription_id}")) = "/subscriptions/${var.subscription_id}"
    } : local.cost_infinity_group_scopes
  )
}

data "azuread_client_config" "current" {
  count = var.enable_cost_infinity ? 1 : 0
}

resource "azuread_application" "cost_infinity" {
  count            = var.enable_cost_infinity ? 1 : 0
  display_name     = "${var.name_prefix}-cost-query"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current[0].object_id]
}

resource "azuread_service_principal" "cost_infinity" {
  count     = var.enable_cost_infinity ? 1 : 0
  client_id = azuread_application.cost_infinity[0].client_id
  owners    = [data.azuread_client_config.current[0].object_id]
}

resource "time_rotating" "cost_infinity_secret" {
  count         = var.enable_cost_infinity ? 1 : 0
  rotation_days = var.cost_infinity_secret_rotation_days
}

# The secret expires 30 days after it is due for rotation, so a late apply does not break Grafana.
# Replacing it creates the new secret before removing the old one; apply this stage and then the
# Grafana stage to move Grafana to the new value.
resource "azuread_application_password" "cost_infinity" {
  count               = var.enable_cost_infinity ? 1 : 0
  application_id      = azuread_application.cost_infinity[0].id
  display_name        = "grafana-infinity"
  end_date            = timeadd(time_rotating.cost_infinity_secret[0].rotation_rfc3339, "720h")
  rotate_when_changed = { rotation = time_rotating.cost_infinity_secret[0].id }

  lifecycle {
    create_before_destroy = true
  }
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

resource "azurerm_role_definition" "cost_infinity_query" {
  for_each    = local.cost_infinity_role_scopes
  name        = "AI Observatory Cost Query infinity-cost ${substr(sha256("${local.cost_suffix}/infinity/${each.key}"), 0, 16)}"
  scope       = "/subscriptions/${var.subscription_id}"
  description = "Query Cost Management at one scope for the Infinity service principal. Read-only: this is its only action."

  permissions {
    actions          = ["Microsoft.CostManagement/query/read"]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = [each.key]
}

resource "azurerm_role_assignment" "cost_infinity_query" {
  for_each                         = local.cost_infinity_role_scopes
  scope                            = each.value
  role_definition_id               = azurerm_role_definition.cost_infinity_query[each.key].role_definition_resource_id
  principal_id                     = azuread_service_principal.cost_infinity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
