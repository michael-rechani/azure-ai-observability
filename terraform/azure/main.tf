data "azurerm_resource_group" "monitoring" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "monitoring" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
}

locals {
  resource_group_name = var.create_resource_group ? azurerm_resource_group.monitoring[0].name : data.azurerm_resource_group.monitoring[0].name
  resource_group_id   = var.create_resource_group ? azurerm_resource_group.monitoring[0].id : data.azurerm_resource_group.monitoring[0].id
  suffix              = substr(sha256(lower(var.create_resource_group ? "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}" : data.azurerm_resource_group.monitoring[0].id)), 0, 8)
  grafana_name        = "${var.name_prefix}-${local.suffix}"
  alert_accounts      = { for key, account in var.monitored_accounts : key => account if var.enable_ptu_alerts && length(account.ptu_deployments) > 0 }
  agent_alert_suffix  = "${var.name_prefix}-${local.suffix}-agent"

  # Suffix for the Infinity cost resource names; changing it renames those resources.
  cost_suffix = substr(sha256(lower("${var.subscription_id}/${var.resource_group_name}/${var.name_prefix}")), 0, 12)
}

resource "azurerm_log_analytics_workspace" "monitoring" {
  name                       = "${var.name_prefix}-logs-${local.suffix}"
  location                   = var.location
  resource_group_name        = local.resource_group_name
  sku                        = "PerGB2018"
  retention_in_days          = var.retention_in_days
  daily_quota_gb             = var.daily_quota_gb
  internet_ingestion_enabled = true
  internet_query_enabled     = true
}

resource "azurerm_application_insights" "monitoring" {
  name                         = "${var.name_prefix}-appinsights-${local.suffix}"
  location                     = var.location
  resource_group_name          = local.resource_group_name
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.monitoring.id
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
}

resource "azurerm_dashboard_grafana" "monitoring" {
  name                              = local.grafana_name
  location                          = var.location
  resource_group_name               = local.resource_group_name
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

resource "azurerm_role_assignment" "grafana_viewer" {
  for_each                         = var.grafana_viewer_principals
  scope                            = azurerm_dashboard_grafana.monitoring.id
  role_definition_name             = "Grafana Viewer"
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  skip_service_principal_aad_check = each.value.principal_type == "ServicePrincipal"
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

resource "azurerm_role_assignment" "telemetry_publisher" {
  for_each                         = var.telemetry_publisher_principals
  scope                            = azurerm_application_insights.monitoring.id
  role_definition_name             = "Monitoring Metrics Publisher"
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  skip_service_principal_aad_check = each.value.principal_type == "ServicePrincipal"
}

resource "azurerm_monitor_action_group" "notifications" {
  name                = "${var.name_prefix}-alerts"
  resource_group_name = local.resource_group_name
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
  resource_group_name = local.resource_group_name
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
  resource_group_name = local.resource_group_name
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

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "agent_failure_rate" {
  count                   = var.enable_agent_alerts ? 1 : 0
  name                    = "${local.agent_alert_suffix}-failure-rate"
  resource_group_name     = local.resource_group_name
  location                = var.location
  description             = "Agent failure rate exceeded its threshold after the minimum run count was observed."
  enabled                 = true
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  scopes                  = [azurerm_log_analytics_workspace.monitoring.id]
  severity                = 2
  auto_mitigation_enabled = true
  criteria {
    query = templatefile("${path.module}/../../queries/alerts/agent-failure-rate.kql", {
      minimum_agent_runs = var.agent_minimum_runs_for_failure_rate
    })
    time_aggregation_method = "Average"
    metric_measure_column   = "FailureRatePercent"
    operator                = "GreaterThan"
    threshold               = var.agent_failure_rate_threshold_percent
    dimension {
      name     = "Agent"
      operator = "Include"
      values   = ["*"]
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.notifications.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "agent_p95_latency" {
  count                   = var.enable_agent_alerts ? 1 : 0
  name                    = "${local.agent_alert_suffix}-p95-latency"
  resource_group_name     = local.resource_group_name
  location                = var.location
  description             = "Retained-span p95 agent run latency exceeded its threshold."
  enabled                 = true
  evaluation_frequency    = "PT5M"
  window_duration         = "PT10M"
  scopes                  = [azurerm_log_analytics_workspace.monitoring.id]
  severity                = 2
  auto_mitigation_enabled = true
  criteria {
    query                   = file("${path.module}/../../queries/alerts/agent-p95-latency.kql")
    time_aggregation_method = "Average"
    metric_measure_column   = "P95Ms"
    operator                = "GreaterThan"
    threshold               = var.agent_p95_latency_threshold_ms
    dimension {
      name     = "Agent"
      operator = "Include"
      values   = ["*"]
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.notifications.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "agent_heartbeat" {
  count                   = var.enable_agent_alerts ? 1 : 0
  name                    = "${local.agent_alert_suffix}-heartbeat"
  resource_group_name     = local.resource_group_name
  location                = var.location
  description             = "Expected agent telemetry was not observed in the last fifteen minutes."
  enabled                 = true
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  scopes                  = [azurerm_log_analytics_workspace.monitoring.id]
  severity                = 2
  auto_mitigation_enabled = true
  criteria {
    query                   = file("${path.module}/../../queries/alerts/agent-heartbeat.kql")
    time_aggregation_method = "Average"
    metric_measure_column   = "ObservedRuns"
    operator                = "LessThan"
    threshold               = var.agent_expected_runs_per_15m
  }
  action {
    action_groups = [azurerm_monitor_action_group.notifications.id]
  }
}

resource "azurerm_consumption_budget_subscription" "ai_accounts" {
  count           = var.monthly_ai_cost_budget_amount > 0 ? 1 : 0
  name            = "${var.name_prefix}-ai-accounts-monthly"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.monthly_ai_cost_budget_amount
  time_grain      = "Monthly"

  lifecycle {
    precondition {
      condition     = length(var.monitored_accounts) > 0
      error_message = "Configure at least one monitored account before enabling the AI cost budget."
    }
    precondition {
      condition = (
        var.cost_budget_start_date != null &&
        var.cost_budget_end_date != null &&
        timecmp(var.cost_budget_start_date, var.cost_budget_end_date) < 0
      )
      error_message = "Set a start and end date, with the end after the start, before enabling the AI cost budget."
    }
  }

  time_period {
    start_date = var.cost_budget_start_date
    end_date   = var.cost_budget_end_date
  }

  filter {
    dimension {
      name   = "ResourceId"
      values = [for account in values(var.monitored_accounts) : account.resource_id]
    }
  }

  notification {
    enabled        = true
    threshold      = var.cost_budget_threshold_percent
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.notification_email]
    contact_groups = [azurerm_monitor_action_group.notifications.id]
  }
}
