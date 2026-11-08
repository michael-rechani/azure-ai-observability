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
  description = "Scheduled cost collector Function App, or null when Function mode is not enabled."
  value       = try(azurerm_function_app_flex_consumption.cost[0].name, null)
}

output "cost_identity_principal_id" {
  description = "Cost collector managed identity object ID, or null when the pipeline is disabled."
  value       = try(azurerm_user_assigned_identity.cost[0].principal_id, null)
}

output "cost_collector_configuration" {
  description = "Non-secret settings for configuring the cost collector, or null when disabled."
  value = var.enable_cost_pipeline ? {
    subscription_id                   = var.subscription_id
    account_ids                       = [for account in values(var.monitored_accounts) : account.resource_id]
    query_scope                       = var.cost_query_scope == "resourceGroupManaged" ? "resourceGroup" : var.cost_query_scope
    ingestion_endpoint                = azurerm_monitor_data_collection_endpoint.cost[0].logs_ingestion_endpoint
    data_collection_rule_immutable_id = azurerm_monitor_data_collection_rule.cost[0].immutable_id
    identity_client_id                = azurerm_user_assigned_identity.cost[0].client_id
    lookback_days                     = var.cost_lookback_days
  } : null
}
