data "azurerm_resource_group" "monitoring" {
  name = var.resource_group_name
}

locals {
  suffix         = substr(sha256(lower(data.azurerm_resource_group.monitoring.id)), 0, 8)
  grafana_name   = "${var.name_prefix}-${local.suffix}"
  alert_accounts = { for key, account in var.monitored_accounts : key => account if var.enable_ptu_alerts && length(account.ptu_deployments) > 0 }
}

resource "azurerm_log_analytics_workspace" "monitoring" {
  name                       = "${var.name_prefix}-logs-${local.suffix}"
  location                   = var.location
  resource_group_name        = data.azurerm_resource_group.monitoring.name
  sku                        = "PerGB2018"
  retention_in_days          = var.retention_in_days
  daily_quota_gb             = var.daily_quota_gb
  internet_ingestion_enabled = true
  internet_query_enabled     = true
}

resource "azurerm_application_insights" "monitoring" {
  name                         = "${var.name_prefix}-appinsights-${local.suffix}"
  location                     = var.location
  resource_group_name          = data.azurerm_resource_group.monitoring.name
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.monitoring.id
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
}

resource "azurerm_dashboard_grafana" "monitoring" {
  name                              = local.grafana_name
  location                          = var.location
  resource_group_name               = data.azurerm_resource_group.monitoring.name
  grafana_major_version             = var.grafana_major_version
  sku                               = "Standard"
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = false
  public_network_access_enabled     = true
  zone_redundancy_enabled           = false
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "grafana_admin" {
  scope                = azurerm_dashboard_grafana.monitoring.id
  role_definition_name = "Grafana Admin"
  principal_id         = var.grafana_admin_object_id
  principal_type       = var.grafana_admin_principal_type
}

resource "azurerm_role_assignment" "workspace_reader" {
  scope                            = azurerm_log_analytics_workspace.monitoring.id
  role_definition_name             = "Log Analytics Reader"
  principal_id                     = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "insights_reader" {
  scope                            = azurerm_application_insights.monitoring.id
  role_definition_name             = "Monitoring Reader"
  principal_id                     = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "account_reader" {
  for_each                         = var.monitored_accounts
  scope                            = each.value.resource_id
  role_definition_name             = "Monitoring Reader"
  principal_id                     = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "existing_workspace_reader" {
  for_each                         = var.existing_telemetry_workspace_ids
  scope                            = each.value
  role_definition_name             = "Log Analytics Reader"
  principal_id                     = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_monitor_action_group" "notifications" {
  name                = "${var.name_prefix}-alerts"
  resource_group_name = data.azurerm_resource_group.monitoring.name
  short_name          = "AIObserve"
  enabled             = true
  email_receiver {
    name                    = "operator"
    email_address           = var.notification_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "utilization" {
  for_each            = local.alert_accounts
  name                = "${var.name_prefix}-${substr(sha256(lower(each.value.resource_id)), 0, 8)}-ptu-utilization"
  resource_group_name = data.azurerm_resource_group.monitoring.name
  scopes              = [each.value.resource_id]
  description         = "Sustained PTU utilization; investigate workload and capacity before changing deployments."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true
  auto_mitigate       = true
  criteria {
    metric_namespace       = "Microsoft.CognitiveServices/accounts"
    metric_name            = "AzureOpenAIProvisionedManagedUtilizationV2"
    aggregation            = "Average"
    operator               = "GreaterThanOrEqual"
    threshold              = var.ptu_utilization_threshold
    skip_metric_validation = false
    dimension {
      name     = "ModelDeploymentName"
      operator = "Include"
      values   = each.value.ptu_deployments
    }
  }
  action {
    action_group_id = azurerm_monitor_action_group.notifications.id
  }
}

resource "azurerm_monitor_metric_alert" "throttling" {
  for_each            = local.alert_accounts
  name                = "${var.name_prefix}-${substr(sha256(lower(each.value.resource_id)), 0, 8)}-ptu-throttling"
  resource_group_name = data.azurerm_resource_group.monitoring.name
  scopes              = [each.value.resource_id]
  description         = "One or more HTTP 429 responses on a named PTU deployment in five minutes."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true
  auto_mitigate       = true
  criteria {
    metric_namespace       = "Microsoft.CognitiveServices/accounts"
    metric_name            = "AzureOpenAIRequests"
    aggregation            = "Total"
    operator               = "GreaterThan"
    threshold              = 0
    skip_metric_validation = false
    dimension {
      name     = "ModelDeploymentName"
      operator = "Include"
      values   = each.value.ptu_deployments
    }
    dimension {
      name     = "StatusCode"
      operator = "Include"
      values   = ["429"]
    }
  }
  action {
    action_group_id = azurerm_monitor_action_group.notifications.id
  }
}
