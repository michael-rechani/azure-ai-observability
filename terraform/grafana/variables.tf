variable "grafana_endpoint" {
  description = "HTTPS endpoint from the Azure infrastructure stage."
  type        = string
  validation {
    condition     = can(regex("^https://[a-zA-Z0-9.-]+/?$", var.grafana_endpoint))
    error_message = "grafana_endpoint must be an HTTPS host URL without credentials or a path."
  }
}

variable "subscription_id" {
  description = "Default Azure subscription GUID for the Azure Monitor data source."
  type        = string
}

variable "dashboard_directory" {
  description = "Directory containing generated JSON dashboard files."
  type        = string
  default     = "../../dashboards"
}
