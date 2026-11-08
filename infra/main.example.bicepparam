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

// Set true to deploy the cost Function and dashboard; all accounts must be in this subscription.
param enableCostPipeline = false
// resourceGroup requires separately managed cost-role grants.
param costQueryScope = 'subscription'
param costLookbackDays = 90

// Optional monthly account-filtered budget, in subscription billing currency.
param monthlyAiCostBudgetAmount = 0
param costBudgetStartDate = ''
param costBudgetEndDate = ''
