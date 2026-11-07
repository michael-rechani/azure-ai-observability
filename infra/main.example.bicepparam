using './main.bicep'

param location = 'eastus'
param namePrefix = 'ai-observe'
param grafanaAdminObjectId = '00000000-0000-0000-0000-000000000000'
param notificationEmail = 'replace-me@example.invalid'
param monitoredAccounts = [
  {
    subscriptionId: '00000000-0000-0000-0000-000000000000'
    resourceGroup: 'existing-foundry-rg'
    name: 'existing-foundry-account'
    ptuDeployments: []
  }
  {
    subscriptionId: '00000000-0000-0000-0000-000000000000'
    resourceGroup: 'existing-openai-rg'
    name: 'existing-openai-account'
    ptuDeployments: ['replace-with-provisioned-deployment-name']
  }
]
param existingTelemetryWorkspaces = []
