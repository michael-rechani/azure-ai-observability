variable "grafana_endpoint" {
  description = "HTTPS endpoint from the Azure infrastructure stage."
  type        = string
  validation {
    condition     = can(regex("(?i)^https://[a-z0-9][a-z0-9-]*(\\.[a-z0-9][a-z0-9-]*)*\\.grafana\\.azure\\.com/?$", var.grafana_endpoint))
    error_message = "grafana_endpoint must be a public Azure Managed Grafana HTTPS host without credentials, a path, or a custom port."
  }
}

variable "subscription_id" {
  description = "Default Azure subscription GUID for the Azure Monitor data source."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "dashboard_directory" {
  description = "Directory containing dashboard JSON files."
  type        = string
  default     = "../../dashboards"
}

variable "dashboard_defaults" {
  description = "Optional real Azure workspace and account defaults for the deployed dashboards."
  type = object({
    monitoring_workspace_resource_id = optional(string)
    telemetry_workspace_resource_id  = optional(string)
    foundry_account = optional(object({
      resource_group = string
      name           = string
      region         = string
      deployment     = optional(string, "*")
    }))
    ptu_account = optional(object({
      resource_group = string
      name           = string
      region         = string
      deployment     = optional(string, "*")
    }))
  })
  default = {}

  validation {
    condition = alltrue([
      for id in [
        var.dashboard_defaults.monitoring_workspace_resource_id,
        var.dashboard_defaults.telemetry_workspace_resource_id
      ] : id == null ? true : can(regex("(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourcegroups/[^/]+/providers/microsoft\\.operationalinsights/workspaces/[^/]+$", id))
    ])
    error_message = "Workspace defaults must be full Log Analytics workspace ARM resource IDs."
  }
  validation {
    condition = alltrue([
      for account in [var.dashboard_defaults.foundry_account, var.dashboard_defaults.ptu_account] :
      account == null ? true : (
        trimspace(account.resource_group) != "" &&
        trimspace(account.name) != "" &&
        can(regex("^[A-Za-z0-9-]+$", account.region)) &&
        can(regex("^([A-Za-z0-9_.-]+|\\*)$", account.deployment))
      )
    ])
    error_message = "Dashboard account defaults need a resource group, name, Azure region, and a deployment name or *."
  }
}

variable "enable_cost_dashboard" {
  description = "Provision the cost dashboard after enabling the Azure cost pipeline and its custom table."
  type        = bool
  default     = false
}

variable "enable_cost_export_dashboard" {
  description = "Provision the Azure Data Explorer data source and the cost export dashboard after enabling the Azure stage's cost export."
  type        = bool
  default     = false
}

variable "cost_export_cluster_uri" {
  description = "Azure Data Explorer cluster URI, from the Azure stage's cost_export_adx_cluster_uri output. Required with enable_cost_export_dashboard."
  type        = string
  default     = null
  validation {
    condition     = var.cost_export_cluster_uri == null || can(regex("(?i)^https://[a-z0-9][a-z0-9-]*\\.[a-z0-9]+\\.kusto\\.windows\\.net/?$", var.cost_export_cluster_uri))
    error_message = "cost_export_cluster_uri must be an Azure Data Explorer HTTPS cluster URI such as https://name.region.kusto.windows.net."
  }
}

variable "cost_export_database" {
  description = "Azure Data Explorer database holding the cost export, from the Azure stage's cost_export_adx_database output."
  type        = string
  default     = "costs"
}
