locals {
  cost_suffix = substr(sha256(lower("${var.subscription_id}/${var.resource_group_name}/${var.name_prefix}")), 0, 12)
  cost_columns = {
    TimeGenerated = "dateTime"
    RecordType    = "string"
    RunId         = "string"
    RowKey        = "string"
    CostType      = "string"
    ResourceId    = "string"
    UsageDate     = "dateTime"
    Currency      = "string"
    Cost          = "real"
    ExpectedRows  = "long"
    WindowStart   = "dateTime"
    WindowEnd     = "dateTime"
  }
  cost_deployment_script = "${path.module}/../../scripts/deploy_cost_function.ps1"
}

resource "azurerm_log_analytics_workspace_table_custom_log" "cost" {
  count             = var.enable_cost_pipeline ? 1 : 0
  name              = "AICostSnapshot_CL"
  workspace_id      = azurerm_log_analytics_workspace.monitoring.id
  description       = "Complete daily snapshots of account-attributed pretax Azure costs."
  plan              = "Analytics"
  retention_in_days = var.retention_in_days

  dynamic "column" {
    for_each = local.cost_columns
    content {
      name = column.key
      type = column.value
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "cost" {
  count                         = var.enable_cost_pipeline ? 1 : 0
  name                          = "ai-cost-${local.cost_suffix}"
  resource_group_name           = local.resource_group_name
  location                      = var.location
  public_network_access_enabled = true
}

resource "azurerm_monitor_data_collection_rule" "cost" {
  count                       = var.enable_cost_pipeline ? 1 : 0
  name                        = "ai-cost-${local.cost_suffix}"
  resource_group_name         = local.resource_group_name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.cost[0].id

  destinations {
    log_analytics {
      name                  = "workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.monitoring.id
    }
  }

  stream_declaration {
    stream_name = "Custom-AICostSnapshot"
    dynamic "column" {
      for_each = local.cost_columns
      content {
        name = column.key
        type = column.value == "dateTime" ? "datetime" : column.value
      }
    }
  }

  data_flow {
    streams       = ["Custom-AICostSnapshot"]
    destinations  = ["workspace"]
    transform_kql = "source"
    output_stream = "Custom-AICostSnapshot_CL"
  }

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.cost]
}

resource "azurerm_user_assigned_identity" "cost" {
  count               = var.enable_cost_pipeline ? 1 : 0
  name                = "ai-cost-${local.cost_suffix}"
  resource_group_name = local.resource_group_name
  location            = var.location
}

resource "azurerm_storage_account" "cost" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  name                             = "aicost${local.cost_suffix}"
  resource_group_name              = local.resource_group_name
  location                         = var.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  cross_tenant_replication_enabled = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "cost_blob_read" {
  count                      = var.enable_cost_pipeline ? 1 : 0
  name                       = "cost-storage-blob-read"
  target_resource_id         = "${azurerm_storage_account.cost[0].id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitoring.id

  enabled_log {
    category = "StorageRead"
  }
}

resource "azurerm_storage_container" "cost_deployment" {
  count                 = var.enable_cost_pipeline ? 1 : 0
  name                  = "function-deployment"
  storage_account_id    = azurerm_storage_account.cost[0].id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "cost_storage" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  scope                            = azurerm_storage_account.cost[0].id
  role_definition_name             = "Storage Blob Data Owner"
  principal_id                     = azurerm_user_assigned_identity.cost[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cost_storage_diagnostics" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  scope                            = azurerm_storage_account.cost[0].id
  role_definition_name             = "Storage Table Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.cost[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cost_reader" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  scope                            = "/subscriptions/${var.subscription_id}"
  role_definition_name             = "Cost Management Reader"
  principal_id                     = azurerm_user_assigned_identity.cost[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cost_ingestion" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  scope                            = azurerm_monitor_data_collection_rule.cost[0].id
  role_definition_name             = "Monitoring Metrics Publisher"
  principal_id                     = azurerm_user_assigned_identity.cost[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cost_telemetry" {
  count                            = var.enable_cost_pipeline ? 1 : 0
  scope                            = azurerm_application_insights.monitoring.id
  role_definition_name             = "Monitoring Metrics Publisher"
  principal_id                     = azurerm_user_assigned_identity.cost[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_service_plan" "cost" {
  count               = var.enable_cost_pipeline ? 1 : 0
  name                = "ai-cost-${local.cost_suffix}"
  resource_group_name = local.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "cost" {
  count                                          = var.enable_cost_pipeline ? 1 : 0
  name                                           = "ai-cost-${local.cost_suffix}"
  resource_group_name                            = local.resource_group_name
  location                                       = var.location
  service_plan_id                                = azurerm_service_plan.cost[0].id
  storage_container_type                         = "blobContainer"
  storage_container_endpoint                     = "${azurerm_storage_account.cost[0].primary_blob_endpoint}${azurerm_storage_container.cost_deployment[0].name}"
  storage_authentication_type                    = "UserAssignedIdentity"
  storage_user_assigned_identity_id              = azurerm_user_assigned_identity.cost[0].id
  runtime_name                                   = "powershell"
  runtime_version                                = "7.6"
  maximum_instance_count                         = 40
  instance_memory_in_mb                          = 2048
  https_only                                     = true
  public_network_access_enabled                  = true
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cost[0].id]
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.monitoring.connection_string
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
  }

  app_settings = {
    AzureWebJobsStorage__accountName          = azurerm_storage_account.cost[0].name
    AzureWebJobsStorage__credential           = "managedidentity"
    AzureWebJobsStorage__clientId             = azurerm_user_assigned_identity.cost[0].client_id
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "ClientId=${azurerm_user_assigned_identity.cost[0].client_id};Authorization=AAD"
    COST_SUBSCRIPTION_ID                      = var.subscription_id
    COST_ACCOUNT_IDS                          = jsonencode([for account in values(var.monitored_accounts) : account.resource_id])
    COST_INGESTION_ENDPOINT                   = azurerm_monitor_data_collection_endpoint.cost[0].logs_ingestion_endpoint
    COST_DCR_IMMUTABLE_ID                     = azurerm_monitor_data_collection_rule.cost[0].immutable_id
    COST_IDENTITY_CLIENT_ID                   = azurerm_user_assigned_identity.cost[0].client_id
    COST_LOOKBACK_DAYS                        = tostring(var.cost_lookback_days)
  }

  lifecycle {
    precondition {
      condition     = length(var.monitored_accounts) > 0
      error_message = "Configure at least one monitored account before enabling cost collection."
    }
    precondition {
      condition     = length(var.monitored_accounts) * ceil(var.cost_lookback_days / 27) * 2 * 16 <= 1800
      error_message = "The account count and lookback require more than 30 minutes of minimum API pacing. Reduce either or split the deployment."
    }
  }

  depends_on = [
    azurerm_role_assignment.cost_storage,
    azurerm_role_assignment.cost_storage_diagnostics,
    azurerm_role_assignment.cost_reader,
    azurerm_role_assignment.cost_ingestion,
    azurerm_role_assignment.cost_telemetry,
  ]
}

data "archive_file" "cost_function" {
  count       = var.enable_cost_pipeline ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../../function/cost-collector"
  output_path = "${path.module}/.terraform/cost-collector.zip"
}

resource "terraform_data" "cost_function_deployment" {
  count = var.enable_cost_pipeline ? 1 : 0
  triggers_replace = [
    azurerm_function_app_flex_consumption.cost[0].id,
    data.archive_file.cost_function[0].output_base64sha256,
    filesha256(local.cost_deployment_script),
  ]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File"]
    command     = abspath(local.cost_deployment_script)
    environment = {
      COST_FUNCTION_NAME         = azurerm_function_app_flex_consumption.cost[0].name
      COST_FUNCTION_GROUP        = local.resource_group_name
      COST_FUNCTION_PACKAGE      = abspath(data.archive_file.cost_function[0].output_path)
      COST_FUNCTION_SUBSCRIPTION = var.subscription_id
    }
  }
}
