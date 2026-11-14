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

// Use object IDs for existing Entra users, groups, or service principals.
param grafanaViewerPrincipals = []
param telemetryPublisherPrincipals = []

// Set these to real accounts already listed in monitoredAccounts.
param foundryDashboardAccount = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroup: 'existing-foundry-rg'
  name: 'existing-foundry-account'
  region: 'eastus'
  deployment: '*'
}
param ptuDashboardAccount = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroup: 'existing-openai-rg'
  name: 'existing-openai-account'
  region: 'eastus'
  deployment: 'replace-with-provisioned-deployment-name'
}

// Set to a listed existing telemetry workspace ARM ID if agent data lives elsewhere.
param dashboardTelemetryWorkspaceResourceId = ''

// Verify the telemetry schema and guaranteed traffic before enabling agent alerts.
param enableAgentAlerts = false

// Set true to include the Business overview dashboard (agent and PTU signals, no cost panels) when Grafana is provisioned.
param enableBusinessOverview = false

// Optional monthly account-filtered budget, in subscription billing currency.
param monthlyAiCostBudgetAmount = 0
param costBudgetStartDate = ''
param costBudgetEndDate = ''

// Optional billed-cost path: Grafana queries Cost Management directly through the Infinity plugin.
// It adds no cluster or storage, but it is NOT secretless: Infinity signs in with a service principal
// client secret that you create, supply only to the provisioning step (never to this template) and rotate.
// Create the principal with the `az ad` commands in docs/costs.md, then fill in its client ID and service principal object ID.
// param enableCostInfinity = true
// param costInfinityClientId = '00000000-0000-0000-0000-000000000000'
// param costInfinityServicePrincipalObjectId = '00000000-0000-0000-0000-000000000000'
// 'subscription' grants Cost Management Reader; 'resourceGroupManaged' grants a query-only role per monitored group.
// param costInfinityScope = 'resourceGroupManaged'
// On by default with Infinity: an alert rule that fires when the data source cannot query Cost Management (for example
// the secret expired). It needs a contact point that routes component=cost-infinity; see docs/costs.md.
// param enableCostInfinityAlert = true
// param costInfinityAlertIntervalMinutes = 60
// param costInfinityAlertPendingMinutes = 60
