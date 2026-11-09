data "azurerm_client_config" "current" {}

locals {
  cost_export_database       = "costs"
  cost_export_current_folder = "cost-current"
  cost_export_closed_folder  = "cost-closed"
  cost_export_start          = var.cost_export_start_date
  # Five years, expressed in hours because timeadd has no larger unit.
  cost_export_end = var.cost_export_end_date != null ? var.cost_export_end_date : (
    var.cost_export_start_date == null ? null : formatdate("YYYY-MM-DD", timeadd("${var.cost_export_start_date}T00:00:00Z", "43800h"))
  )
  cost_exports = var.enable_cost_export ? {
    current = {
      timeframe  = "MonthToDate"
      recurrence = "Daily"
      container  = local.cost_export_current_folder
    }
    closed = {
      timeframe  = "TheLastMonth"
      recurrence = "Monthly"
      container  = local.cost_export_closed_folder
    }
  } : {}
}

resource "azurerm_storage_account" "cost_export" {
  count                            = var.enable_cost_export ? 1 : 0
  name                             = "aiexp${local.cost_suffix}"
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
  public_network_access_enabled    = true

  # Cost Management and Azure Data Explorer reach the account as trusted Azure services.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "cost_export" {
  for_each              = local.cost_exports
  name                  = each.value.container
  storage_account_id    = azurerm_storage_account.cost_export[0].id
  container_access_type = "private"
}

resource "azurerm_kusto_cluster" "cost_export" {
  count                         = var.enable_cost_export ? 1 : 0
  name                          = "aiadx${local.cost_suffix}"
  resource_group_name           = local.resource_group_name
  location                      = var.location
  auto_stop_enabled             = false
  streaming_ingestion_enabled   = false
  public_network_access_enabled = true

  sku {
    name     = var.cost_export_adx_sku_name
    capacity = var.cost_export_adx_capacity
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_kusto_database" "cost_export" {
  count               = var.enable_cost_export ? 1 : 0
  name                = local.cost_export_database
  resource_group_name = local.resource_group_name
  location            = var.location
  cluster_name        = azurerm_kusto_cluster.cost_export[0].name
  hot_cache_period    = "P31D"
  soft_delete_period  = "P365D"
}

resource "azurerm_role_assignment" "cost_export_reader" {
  count                            = var.enable_cost_export ? 1 : 0
  scope                            = azurerm_storage_account.cost_export[0].id
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_kusto_cluster.cost_export[0].identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_kusto_cluster_principal_assignment" "cost_export_deployer" {
  count               = var.enable_cost_export ? 1 : 0
  name                = "deployer-admin"
  resource_group_name = local.resource_group_name
  cluster_name        = azurerm_kusto_cluster.cost_export[0].name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  principal_id        = data.azurerm_client_config.current.object_id
  principal_type      = var.cost_export_deployer_principal_type
  role                = "AllDatabasesAdmin"
}

resource "azurerm_kusto_script" "cost_export" {
  count                      = var.enable_cost_export ? 1 : 0
  name                       = "cost-export"
  database_id                = azurerm_kusto_database.cost_export[0].id
  continue_on_errors_enabled = false
  script_content = replace(
    replace(
      file("${path.module}/../../infra/kusto/cost-export.kql"),
      "{{CURRENT_URL}}",
      "${azurerm_storage_account.cost_export[0].primary_blob_endpoint}${local.cost_export_current_folder}"
    ),
    "{{CLOSED_URL}}",
    "${azurerm_storage_account.cost_export[0].primary_blob_endpoint}${local.cost_export_closed_folder}"
  )

  depends_on = [
    azurerm_role_assignment.cost_export_reader,
    azurerm_kusto_cluster_principal_assignment.cost_export_deployer,
    azurerm_storage_container.cost_export,
  ]
}

resource "azurerm_kusto_database_principal_assignment" "cost_export_grafana" {
  count               = var.enable_cost_export ? 1 : 0
  name                = "grafana-viewer"
  resource_group_name = local.resource_group_name
  cluster_name        = azurerm_kusto_cluster.cost_export[0].name
  database_name       = azurerm_kusto_database.cost_export[0].name
  tenant_id           = azurerm_dashboard_grafana.monitoring.identity[0].tenant_id
  principal_id        = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type      = "App"
  role                = "Viewer"
}

resource "azapi_resource" "cost_export" {
  for_each  = local.cost_exports
  type      = "Microsoft.CostManagement/exports@2025-03-01"
  name      = "${var.name_prefix}-${local.suffix}-${each.key}"
  parent_id = "/subscriptions/${var.subscription_id}"
  location  = var.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      format                = "Csv"
      compressionMode       = "None"
      dataOverwriteBehavior = "OverwritePreviousReport"
      deliveryInfo = {
        destination = {
          resourceId     = azurerm_storage_account.cost_export[0].id
          container      = each.value.container
          rootFolderPath = "ai-observability"
        }
      }
      definition = {
        type      = "ActualCost"
        timeframe = each.value.timeframe
      }
      schedule = {
        status     = "Active"
        recurrence = each.value.recurrence
        recurrencePeriod = {
          from = "${local.cost_export_start}T00:00:00Z"
          to   = "${local.cost_export_end}T00:00:00Z"
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cost_export_start_date != null
      error_message = "Set cost_export_start_date (YYYY-MM-DD, tomorrow or later) when enabling the cost export."
    }
  }

  depends_on = [azurerm_storage_container.cost_export]
}

resource "azurerm_role_assignment" "cost_export_writer" {
  for_each                         = local.cost_exports
  scope                            = azurerm_storage_account.cost_export[0].id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azapi_resource.cost_export[each.key].identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
