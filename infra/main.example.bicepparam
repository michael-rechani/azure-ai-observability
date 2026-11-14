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
// This template creates the app registration and service principal and grants one read-only action
// (Microsoft.CostManagement/query/read) through a custom role. The deployer needs an Entra role that can
// create applications, plus Owner or User Access Administrator. It is NOT secretless: Infinity supports only a
// client secret, which Bicep cannot create, so scripts/provision_grafana.ps1 creates it with your own sign-in.
// param enableCostInfinity = true
// 'subscription' assigns the query-only role on the subscription; 'resourceGroupManaged' assigns it per monitored group.
// param costInfinityScope = 'resourceGroupManaged'
// On by default with Infinity: an alert rule that fires when the data source cannot query Cost Management (for example
// the secret expired). It needs a contact point that routes component=cost-infinity; see docs/costs.md.
// param enableCostInfinityAlert = true
// param costInfinityAlertIntervalMinutes = 60
// param costInfinityAlertPendingMinutes = 60
