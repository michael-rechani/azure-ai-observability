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

output "cost_function_name" {
  description = "Scheduled cost collector Function App, or null when the pipeline is disabled."
  value       = try(azurerm_function_app_flex_consumption.cost[0].name, null)
}

output "cost_identity_principal_id" {
  description = "Cost collector managed identity object ID, or null when the pipeline is disabled."
  value       = try(azurerm_user_assigned_identity.cost[0].principal_id, null)
}
