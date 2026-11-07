variable "subscription_id" {
  description = "Subscription containing monitoring resources and monitored accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "resource_group_name" {
  description = "Existing resource group for the monitoring stack and alert rules."
  type        = string
}

variable "location" {
  description = "Azure region supporting Managed Grafana and Application Insights."
  type        = string
}

variable "name_prefix" {
  description = "Lowercase alphanumeric prefix for globally unique monitoring names."
  type        = string
  default     = "ai-observe"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 2-20 lowercase letters, digits or hyphens, beginning with a letter and ending with a letter or digit."
  }
}

variable "grafana_admin_object_id" {
  description = "Entra object ID of Grafana administrator; the Terraform dashboard caller needs Grafana Admin."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.grafana_admin_object_id))
    error_message = "grafana_admin_object_id must be a UUID."
  }
}

variable "grafana_admin_principal_type" {
  type    = string
  default = "User"
  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], var.grafana_admin_principal_type)
    error_message = "grafana_admin_principal_type must be User, Group, or ServicePrincipal."
  }
}

variable "notification_email" {
  description = "Email recipient for the action group; never commit your actual tfvars."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "grafana_major_version" {
  description = "Grafana major version supported by the locked AzureRM provider and target region."
  type        = number
  default     = 12
}

variable "retention_in_days" {
  type    = number
  default = 30
  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730 && floor(var.retention_in_days) == var.retention_in_days
    error_message = "retention_in_days must be an integer between 30 and 730."
  }
}

variable "daily_quota_gb" {
  description = "Log Analytics daily ingestion cap; not a complete spending limit."
  type        = number
  default     = 1
  validation {
    condition     = var.daily_quota_gb >= 1
    error_message = "daily_quota_gb must be at least 1."
  }
}

variable "monitored_accounts" {
  description = "Existing accounts in the monitoring subscription. Stable map keys identify Terraform resources."
  type = map(object({
    resource_id     = string
    ptu_deployments = set(string)
  }))
  default = {}
  validation {
    condition = alltrue([
      for account in values(var.monitored_accounts) :
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.CognitiveServices/accounts/[^/]+$", account.resource_id)) &&
      alltrue([for deployment in account.ptu_deployments : can(regex("^[A-Za-z0-9_.-]+$", deployment))])
    ])
    error_message = "Each account needs an AI account ARM resource ID and concrete PTU deployment names (no wildcard)."
  }
  validation {
    condition     = alltrue([for account in values(var.monitored_accounts) : lower(split("/", account.resource_id)[2]) == lower(var.subscription_id)])
    error_message = "All monitored accounts must be in subscription_id. Deploy another stack for a different subscription."
  }
  validation {
    condition     = length(distinct([for account in values(var.monitored_accounts) : lower(account.resource_id)])) == length(var.monitored_accounts)
    error_message = "Each monitored account must be listed only once."
  }
}

variable "existing_telemetry_workspace_ids" {
  description = "Existing workspace ARM IDs requiring Log Analytics Reader for Grafana."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([
      for id in var.existing_telemetry_workspace_ids :
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.OperationalInsights/workspaces/[^/]+$", id))
    ])
    error_message = "existing_telemetry_workspace_ids must contain valid workspace ARM IDs."
  }
}

variable "enable_ptu_alerts" {
  type    = bool
  default = true
}

variable "ptu_utilization_threshold" {
  type    = number
  default = 85
  validation {
    condition     = var.ptu_utilization_threshold >= 1 && var.ptu_utilization_threshold <= 100
    error_message = "ptu_utilization_threshold must be between 1 and 100 percent."
  }
}
