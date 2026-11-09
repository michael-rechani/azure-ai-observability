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

// Set true to deploy the cost pipeline and dashboard; all accounts must be in this subscription.
param enableCostPipeline = false
// Recommended when enabling costs: one query-only custom role per monitored resource group.
// The deployer needs role-definition write/delete and role-assignment permissions.
param costQueryScope = 'resourceGroupManaged'
param costLookbackDays = 90

// Optional monthly account-filtered budget, in subscription billing currency.
param monthlyAiCostBudgetAmount = 0
param costBudgetStartDate = ''
param costBudgetEndDate = ''

// Optional Function-free cost path: Cost Management export -> private storage -> Azure Data Explorer -> Grafana.
// The ADX cluster bills continuously (roughly $95/month at retail) and the export holds the whole subscription's
// cost rows. Register Microsoft.CostManagementExports first. See docs/costs.md.
param enableCostExport = false
// Required with enableCostExport: the deploying identity, granted AllDatabasesAdmin on the dedicated cost cluster
// (az ad signed-in-user show --query id -o tsv). Use costExportDeployerPrincipalType = 'App' for a service principal.
// param costExportDeployerObjectId = '00000000-0000-0000-0000-000000000000'
// After the first deployment, set costExportStartDate to the value used then; the default (tomorrow, UTC) moves on every deployment.
// param costExportStartDate = '2026-01-15'
