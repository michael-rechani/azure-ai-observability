mock_provider "grafana" {}

variables {
  grafana_endpoint = "https://grafana.example.invalid"
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
}
