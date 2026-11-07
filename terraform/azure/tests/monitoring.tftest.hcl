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
