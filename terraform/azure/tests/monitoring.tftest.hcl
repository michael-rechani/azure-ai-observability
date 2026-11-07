mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring"
      name = "monitoring"
    }
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  resource_group_name     = "monitoring"
  location                = "eastus"
  grafana_admin_object_id = "00000000-0000-0000-0000-000000000001"
  notification_email      = "demo@example.invalid"
}

run "ptu_alerts_for_provisioned_deployments" {
  command = plan
  variables {
    monitored_accounts = {
      foundry = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/foundry/providers/Microsoft.CognitiveServices/accounts/foundry"
        ptu_deployments = []
      }
      ptu = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.utilization) == 1 && length(azurerm_monitor_metric_alert.throttling) == 1
    error_message = "Only accounts with provisioned deployments should receive alerts."
  }
  assert {
    condition     = one(azurerm_monitor_metric_alert.utilization["ptu"].criteria).metric_name == "AzureOpenAIProvisionedManagedUtilizationV2"
    error_message = "Utilization alert must use the current V2 metric."
  }
  assert {
    condition = anytrue([
      for dimension in one(azurerm_monitor_metric_alert.throttling["ptu"].criteria).dimension :
      dimension.name == "StatusCode" && contains(dimension.values, "429")
    ])
    error_message = "Throttling alert must filter on HTTP 429."
  }
}

run "alerts_can_be_disabled" {
  command = plan
  variables {
    enable_ptu_alerts = false
    monitored_accounts = {
      ptu = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.utilization) == 0 && length(azurerm_monitor_metric_alert.throttling) == 0
    error_message = "Disabling alerts must omit both PTU rules."
  }
}

run "create_monitoring_resource_group" {
  command = plan
  variables {
    create_resource_group = true
    telemetry_publisher_principals = {
      agent = {
        principal_id = "00000000-0000-0000-0000-000000000003"
      }
    }
  }
  assert {
    condition     = length(azurerm_resource_group.monitoring) == 1 && azurerm_resource_group.monitoring[0].name == "monitoring" && azurerm_resource_group.monitoring[0].location == "eastus"
    error_message = "The monitoring resource group should be created when requested."
  }
  assert {
    condition     = length(data.azurerm_resource_group.monitoring) == 0
    error_message = "A managed resource group must not also be read as an existing group."
  }
  assert {
    condition     = azurerm_role_assignment.telemetry_publisher["agent"].role_definition_name == "Monitoring Metrics Publisher" && azurerm_role_assignment.telemetry_publisher["agent"].principal_type == "ServicePrincipal"
    error_message = "Configured agent identities must receive telemetry publishing permission."
  }
}

run "use_existing_resource_group_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_resource_group.monitoring) == 0 && length(data.azurerm_resource_group.monitoring) == 1
    error_message = "Existing deployments must keep using their existing resource group by default."
  }
  assert {
    condition     = length(azurerm_role_assignment.telemetry_publisher) == 0
    error_message = "Telemetry publisher access must be opt-in."
  }
  assert {
    condition     = local.suffix == substr(sha256(lower(data.azurerm_resource_group.monitoring[0].id)), 0, 8)
    error_message = "Existing resource names must retain their resource-group-based suffix."
  }
}

run "reject_duplicate_telemetry_publishers" {
  command = plan
  variables {
    telemetry_publisher_principals = {
      first  = { principal_id = "00000000-0000-0000-0000-000000000003" }
      second = { principal_id = "00000000-0000-0000-0000-000000000003" }
    }
  }
  expect_failures = [var.telemetry_publisher_principals]
}

run "reject_invalid_telemetry_publisher" {
  command = plan
  variables {
    telemetry_publisher_principals = {
      invalid = {
        principal_id   = "not-an-object-id"
        principal_type = "Application"
      }
    }
  }
  expect_failures = [var.telemetry_publisher_principals]
}

run "reject_other_subscription" {
  command = plan
  variables {
    monitored_accounts = {
      other = {
        resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/openai/providers/Microsoft.CognitiveServices/accounts/openai"
        ptu_deployments = ["gpt-ptu"]
      }
    }
  }
  expect_failures = [var.monitored_accounts]
}
