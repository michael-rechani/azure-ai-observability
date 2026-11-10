variable "subscription_id" {
  description = "Subscription containing monitoring resources and monitored accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "resource_group_name" {
  description = "Resource group for the monitoring stack and alert rules."
  type        = string
}

variable "create_resource_group" {
  description = "Create and manage the monitoring resource group instead of using an existing one."
  type        = bool
  default     = false
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

variable "grafana_viewer_principals" {
  description = "Existing Entra principals to grant Grafana Viewer access; use object IDs and stable map keys."
  type = map(object({
    principal_id   = string
    principal_type = optional(string, "Group")
  }))
  default = {}
  validation {
    condition = alltrue([
      for principal in values(var.grafana_viewer_principals) :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal.principal_id)) &&
      contains(["User", "Group", "ServicePrincipal"], principal.principal_type)
    ])
    error_message = "Each Grafana viewer needs an Entra object ID and a User, Group, or ServicePrincipal type."
  }
  validation {
    condition     = length(distinct([for principal in values(var.grafana_viewer_principals) : try(lower(principal.principal_id), "")])) == length(var.grafana_viewer_principals)
    error_message = "Each Grafana viewer principal must be listed only once."
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
    condition = alltrue([
      for account in values(var.monitored_accounts) : try(
        !contains([".", ".."], split("/", account.resource_id)[4]) &&
        !can(regex("[\\\\%?#\\x00-\\x1f\\x7f]", split("/", account.resource_id)[4])),
        false
      )
    ])
    error_message = "Each account must have a valid resource group name without path traversal, URI delimiters, backslashes, or control characters."
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

variable "telemetry_publisher_principals" {
  description = "Stable map of existing Entra principals allowed to publish to the new Application Insights resource."
  type = map(object({
    principal_id   = string
    principal_type = optional(string, "ServicePrincipal")
  }))
  default = {}
  validation {
    condition = alltrue([
      for principal in values(var.telemetry_publisher_principals) :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal.principal_id)) &&
      contains(["User", "Group", "ServicePrincipal"], principal.principal_type)
    ])
    error_message = "Each telemetry publisher needs an Entra object ID and a User, Group, or ServicePrincipal type."
  }
  validation {
    condition     = length(distinct([for principal in values(var.telemetry_publisher_principals) : lower(principal.principal_id)])) == length(var.telemetry_publisher_principals)
    error_message = "Each telemetry publisher principal must be listed only once."
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

variable "enable_agent_alerts" {
  description = "Create optional agent failure-rate, p95 latency, and expected-traffic heartbeat log alerts."
  type        = bool
  default     = false
}

variable "agent_minimum_runs_for_failure_rate" {
  description = "Minimum sampled agent runs in ten minutes before calculating a failure rate."
  type        = number
  default     = 20
  validation {
    condition     = var.agent_minimum_runs_for_failure_rate >= 1 && floor(var.agent_minimum_runs_for_failure_rate) == var.agent_minimum_runs_for_failure_rate
    error_message = "agent_minimum_runs_for_failure_rate must be a positive integer."
  }
}

variable "agent_failure_rate_threshold_percent" {
  description = "Alert when the ten-minute agent failure rate exceeds this percentage."
  type        = number
  default     = 10
  validation {
    condition     = var.agent_failure_rate_threshold_percent > 0 && var.agent_failure_rate_threshold_percent <= 100
    error_message = "agent_failure_rate_threshold_percent must be greater than 0 and no more than 100."
  }
}

variable "agent_p95_latency_threshold_ms" {
  description = "Alert when the ten-minute retained-span agent p95 exceeds this duration."
  type        = number
  default     = 5000
  validation {
    condition     = var.agent_p95_latency_threshold_ms > 0
    error_message = "agent_p95_latency_threshold_ms must be greater than 0."
  }
}

variable "agent_expected_runs_per_15m" {
  description = "Expected minimum sampled agent runs in 15 minutes; heartbeat alerts are only appropriate when traffic is guaranteed."
  type        = number
  default     = 1
  validation {
    condition     = var.agent_expected_runs_per_15m >= 1 && floor(var.agent_expected_runs_per_15m) == var.agent_expected_runs_per_15m
    error_message = "agent_expected_runs_per_15m must be a positive integer."
  }
}

variable "monthly_ai_cost_budget_amount" {
  description = "Optional monthly Azure Cost Management budget amount in subscription billing currency; zero disables the budget."
  type        = number
  default     = 0
  validation {
    condition     = var.monthly_ai_cost_budget_amount >= 0
    error_message = "monthly_ai_cost_budget_amount cannot be negative."
  }
}

variable "cost_budget_start_date" {
  description = "UTC ISO-8601 budget start date, required when a monthly AI cost budget is enabled."
  type        = string
  default     = null
  validation {
    condition     = var.cost_budget_start_date == null || can(regex("^\\d{4}-\\d{2}-\\d{2}T00:00:00Z$", var.cost_budget_start_date))
    error_message = "cost_budget_start_date must use YYYY-MM-DDT00:00:00Z."
  }
}

variable "cost_budget_end_date" {
  description = "UTC ISO-8601 budget end date, required when a monthly AI cost budget is enabled."
  type        = string
  default     = null
  validation {
    condition     = var.cost_budget_end_date == null || can(regex("^\\d{4}-\\d{2}-\\d{2}T00:00:00Z$", var.cost_budget_end_date))
    error_message = "cost_budget_end_date must use YYYY-MM-DDT00:00:00Z."
  }
}

variable "cost_budget_threshold_percent" {
  description = "Actual spend percentage at which the optional monthly account-scope budget sends a notification."
  type        = number
  default     = 80
  validation {
    condition     = var.cost_budget_threshold_percent > 0 && var.cost_budget_threshold_percent <= 100
    error_message = "cost_budget_threshold_percent must be greater than 0 and no more than 100."
  }
}

variable "enable_cost_export" {
  description = "Deploy the cost export path: Cost Management exports into private storage, read by an Azure Data Explorer cluster through its managed identity, queried by Managed Grafana through its managed identity. The cluster is a standing cost. The subscription must have the Microsoft.CostManagementExports resource provider registered."
  type        = bool
  default     = false
}

variable "cost_export_adx_sku_name" {
  description = "Azure Data Explorer SKU for the cost export database. The default is the smallest Dev/Test SKU, which has no SLA."
  type        = string
  default     = "Dev(No SLA)_Standard_E2a_v4"
}

variable "cost_export_adx_capacity" {
  description = "Azure Data Explorer instance count. Dev/Test SKUs support exactly one."
  type        = number
  default     = 1
  validation {
    condition     = var.cost_export_adx_capacity >= 1 && floor(var.cost_export_adx_capacity) == var.cost_export_adx_capacity
    error_message = "cost_export_adx_capacity must be a positive integer."
  }
}

variable "cost_export_deployer_principal_type" {
  description = "Principal type of the identity running Terraform: User for a signed-in user, App for a service principal. That identity is granted AllDatabasesAdmin on the dedicated cost cluster, because only that role can set the managed-identity policy the export script needs."
  type        = string
  default     = "User"
  validation {
    condition     = contains(["User", "App", "Group"], var.cost_export_deployer_principal_type)
    error_message = "cost_export_deployer_principal_type must be User, App, or Group."
  }
}

variable "cost_export_grafana_access" {
  description = "How Managed Grafana reaches the cost cluster. public (default) uses the cluster public endpoint. privateEndpoint adds a Grafana managed private endpoint and keeps the public endpoint. privateOnly adds the managed private endpoint and disables the public endpoint. Either private option leaves the connection Pending until scripts/approve_grafana_private_endpoint.ps1 approves it, so use privateEndpoint first if Grafana must keep working during the switch."
  type        = string
  default     = "public"
  validation {
    condition     = contains(["public", "privateEndpoint", "privateOnly"], var.cost_export_grafana_access)
    error_message = "cost_export_grafana_access must be public, privateEndpoint, or privateOnly."
  }
}

variable "enable_cost_infinity" {
  description = "Opt in to direct Cost Management queries through the Grafana Infinity plugin: installs the plugin and grants cost query access to a service principal that you create. Adds no cluster or storage, but is NOT secretless: Infinity signs in with that principal's client secret, which you rotate and supply only to the Grafana stage."
  type        = bool
  default     = false
}

variable "cost_infinity_client_id" {
  description = "Application (client) ID of the service principal Infinity signs in with. Required with enable_cost_infinity. Create it with the az ad commands in docs/costs.md."
  type        = string
  default     = null
  validation {
    condition = !var.enable_cost_infinity || (
      var.cost_infinity_client_id != null &&
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.cost_infinity_client_id)) &&
      var.cost_infinity_client_id != "00000000-0000-0000-0000-000000000000"
    )
    error_message = "enable_cost_infinity needs cost_infinity_client_id set to the real application (client) ID, not the all-zero placeholder."
  }
}

variable "cost_infinity_service_principal_object_id" {
  description = "Object ID of that service principal's enterprise application (az ad sp show --id <client id> --query id), which receives the cost query role. This is not the application object ID. Required with enable_cost_infinity."
  type        = string
  default     = null
  validation {
    condition = !var.enable_cost_infinity || (
      var.cost_infinity_service_principal_object_id != null &&
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.cost_infinity_service_principal_object_id)) &&
      var.cost_infinity_service_principal_object_id != "00000000-0000-0000-0000-000000000000"
    )
    error_message = "enable_cost_infinity needs cost_infinity_service_principal_object_id set to the real service principal object ID, not the all-zero placeholder."
  }
}

variable "cost_infinity_scope" {
  description = "Cost access granted to the Infinity service principal: subscription (Cost Management Reader) or resourceGroupManaged (a query-only custom role on each monitored account's resource group)."
  type        = string
  default     = "subscription"
  validation {
    condition     = contains(["subscription", "resourceGroupManaged"], var.cost_infinity_scope)
    error_message = "cost_infinity_scope must be subscription or resourceGroupManaged."
  }
}

variable "cost_export_start_date" {
  description = "UTC date (YYYY-MM-DD) the export schedule starts. Required when enable_cost_export is true. Keep it unchanged on later applies, because changing it rewrites the schedule."
  type        = string
  default     = null
  validation {
    condition     = var.cost_export_start_date == null || can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.cost_export_start_date))
    error_message = "cost_export_start_date must use YYYY-MM-DD."
  }
}

variable "cost_export_end_date" {
  description = "UTC date (YYYY-MM-DD) the export schedule ends. Defaults to five years after the start date; exports stop silently after it."
  type        = string
  default     = null
  validation {
    condition     = var.cost_export_end_date == null || can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.cost_export_end_date))
    error_message = "cost_export_end_date must use YYYY-MM-DD."
  }
}
