output "resource_group_id" {
  value = local.resource_group_id
}

output "grafana_endpoint" {
  value = azurerm_dashboard_grafana.monitoring.endpoint
}

output "grafana_name" {
  value = azurerm_dashboard_grafana.monitoring.name
}

output "grafana_principal_id" {
  value = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
}

output "workspace_resource_id" {
  value = azurerm_log_analytics_workspace.monitoring.id
}

output "application_insights_resource_id" {
  value = azurerm_application_insights.monitoring.id
}

output "action_group_resource_id" {
  value = azurerm_monitor_action_group.notifications.id
}

output "cost_infinity_tenant_id" {
  description = "Tenant ID for the Grafana stage's cost_infinity_tenant_id, or null when Infinity is disabled."
  value       = var.enable_cost_infinity ? azurerm_dashboard_grafana.monitoring.identity[0].tenant_id : null
}

output "cost_infinity_client_id" {
  description = "Client ID for the Grafana stage's cost_infinity_client_id, or null when Infinity is disabled."
  value       = var.enable_cost_infinity ? azuread_application.cost_infinity[0].client_id : null
}

output "cost_infinity_client_secret" {
  description = "Client secret for the Grafana stage's cost_infinity_client_secret (read it with terraform output -raw and pass it as TF_VAR_cost_infinity_client_secret), or null when Infinity is disabled. It is also recorded in this stage's state, so protect the state like a credential."
  value       = var.enable_cost_infinity ? azuread_application_password.cost_infinity[0].value : null
  sensitive   = true
}

output "cost_infinity_scope" {
  description = "Default cost scope for the Grafana stage's cost_infinity_scope: the subscription, or the first monitored resource group, or null when Infinity is disabled."
  value = !var.enable_cost_infinity ? null : (
    var.cost_infinity_scope == "subscription" ? "/subscriptions/${var.subscription_id}" : try(sort(values(local.cost_infinity_group_scopes))[0], null)
  )
}
