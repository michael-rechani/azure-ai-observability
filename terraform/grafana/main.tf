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
  dashboard_files = {
    foundry_overview = "foundry-overview.json"
    foundry_agents   = "foundry-agents.json"
    openai_ptu       = "openai-ptu.json"
  }
}

resource "grafana_dashboard" "monitoring" {
  for_each = local.dashboard_files
  config_json = replace(
    file("${var.dashboard_directory}/${each.value}"),
    "$${DS_AZURE_MONITOR}",
    grafana_data_source.azure_monitor.uid
  )
  overwrite = false
}

output "dashboard_urls" {
  value = { for key, dashboard in grafana_dashboard.monitoring : key => dashboard.url }
}
