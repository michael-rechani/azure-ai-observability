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
  value       = var.enable_cost_infinity ? var.cost_infinity_client_id : null
}

output "cost_infinity_scope" {
  description = "Default cost scope for the Grafana stage's cost_infinity_scope: the subscription, or the first monitored resource group, or null when Infinity is disabled."
  value = !var.enable_cost_infinity ? null : (
    var.cost_infinity_scope == "subscription" ? "/subscriptions/${var.subscription_id}" : try(sort(values(local.cost_infinity_group_scopes))[0], null)
  )
}

output "cost_export_storage_account_name" {
  description = "Storage account receiving the Cost Management exports, or null when the export path is disabled."
  value       = try(azurerm_storage_account.cost_export[0].name, null)
}

output "cost_export_adx_cluster_uri" {
  description = "Azure Data Explorer cluster URI for the Grafana data source, or null when the export path is disabled."
  value       = try(azurerm_kusto_cluster.cost_export[0].uri, null)
}

output "cost_export_adx_database" {
  description = "Azure Data Explorer database name for the Grafana data source, or null when the export path is disabled."
  value       = try(azurerm_kusto_database.cost_export[0].name, null)
}

output "cost_export_adx_cluster_name" {
  description = "Azure Data Explorer cluster name. Pass it to scripts/approve_grafana_private_endpoint.ps1 when cost_export_grafana_access is not public."
  value       = try(azurerm_kusto_cluster.cost_export[0].name, null)
}

output "cost_export_grafana_private_endpoint_name" {
  description = "Name of the Grafana managed private endpoint to the cost cluster, or null when cost_export_grafana_access is public."
  value       = try(azapi_resource.cost_export_grafana_private_endpoint[0].name, null)
}
