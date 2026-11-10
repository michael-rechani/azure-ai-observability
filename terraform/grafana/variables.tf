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

variable "enable_cost_infinity_dashboard" {
  description = "Provision the Infinity data source and the direct Cost Management dashboard. Needs enable_cost_infinity in the Azure stage, which installs the plugin and grants the service principal cost access. NOT secretless: the service principal client secret is stored in Grafana and also lands in this stage's Terraform state, so keep the state private and rotate the secret."
  type        = bool
  default     = false
}

variable "cost_infinity_tenant_id" {
  description = "Microsoft Entra tenant ID for the Infinity token request, from the Azure stage's cost_infinity_tenant_id output. Required with enable_cost_infinity_dashboard."
  type        = string
  default     = null
  validation {
    condition     = var.cost_infinity_tenant_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.cost_infinity_tenant_id))
    error_message = "cost_infinity_tenant_id must be a UUID."
  }
}

variable "cost_infinity_client_id" {
  description = "Client ID of the Infinity service principal, from the Azure stage's cost_infinity_client_id output. Required with enable_cost_infinity_dashboard."
  type        = string
  default     = null
  validation {
    condition     = var.cost_infinity_client_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.cost_infinity_client_id))
    error_message = "cost_infinity_client_id must be a UUID."
  }
}

variable "cost_infinity_client_secret" {
  description = "Client secret of the Infinity service principal. Supply it through TF_VAR_cost_infinity_client_secret rather than a tfvars file. Required with enable_cost_infinity_dashboard."
  type        = string
  default     = null
  sensitive   = true
}

variable "cost_infinity_scope" {
  description = "Cost Management scope the dashboard queries by default: /subscriptions/<id> or /subscriptions/<id>/resourceGroups/<name>. Defaults to the subscription. Use the Azure stage's cost_infinity_scope output; it must match the access that stage granted."
  type        = string
  default     = null
  validation {
    condition     = var.cost_infinity_scope == null || can(regex("^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/resourceGroups/[A-Za-z0-9._()-]+)?$", var.cost_infinity_scope))
    error_message = "cost_infinity_scope must be /subscriptions/<id> or /subscriptions/<id>/resourceGroups/<name>."
  }
}

variable "enable_cost_infinity_alert" {
  description = "Create an alert rule that fires when the Infinity data source can no longer query Cost Management, which is how an expired, revoked or wrong client secret shows up. Applies only with enable_cost_infinity_dashboard. Alerts need a contact point or notification policy that routes component=cost-infinity; see docs/costs.md."
  type        = bool
  default     = true
}

variable "cost_infinity_alert_interval_minutes" {
  description = "How often the alert rule queries Cost Management, in minutes. Hourly is plenty for a secret that lasts months, and every evaluation is one Cost Management query."
  type        = number
  default     = 60
  validation {
    condition     = var.cost_infinity_alert_interval_minutes >= 5 && var.cost_infinity_alert_interval_minutes <= 1440 && floor(var.cost_infinity_alert_interval_minutes) == var.cost_infinity_alert_interval_minutes
    error_message = "cost_infinity_alert_interval_minutes must be a whole number between 5 and 1440."
  }
}

variable "cost_infinity_alert_pending_minutes" {
  description = "How long the query must keep failing before the alert fires, in minutes. It absorbs Cost Management throttling (HTTP 429) and one-off failures. With the default hourly interval, 60 means two failed evaluations in a row."
  type        = number
  default     = 60
  validation {
    condition     = var.cost_infinity_alert_pending_minutes >= 0 && var.cost_infinity_alert_pending_minutes <= 1440 && floor(var.cost_infinity_alert_pending_minutes) == var.cost_infinity_alert_pending_minutes
    error_message = "cost_infinity_alert_pending_minutes must be a whole number between 0 and 1440."
  }
}
