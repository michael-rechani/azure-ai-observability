targetScope = 'resourceGroup'

@description('Region supporting Azure Managed Grafana Standard and Application Insights.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(20)
param namePrefix string = 'ai-observe'

@description('Microsoft Entra object ID of the user/group receiving Grafana Admin access.')
@minLength(36)
@maxLength(36)
param grafanaAdminObjectId string

@allowed(['User', 'Group', 'ServicePrincipal'])
param grafanaAdminPrincipalType string = 'User'

@description('Alert email recipient. Supply at deployment time; do not commit personal addresses.')
@minLength(3)
param notificationEmail string

@description('Select a currently supported Grafana major version for the deployment region.')
param grafanaMajorVersion string = '12'

@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@minValue(1)
param dailyQuotaGb int = 1

type AccountTarget = {
  subscriptionId: string
  resourceGroup: string
  name: string
  ptuDeployments: string[]
}

type WorkspaceTarget = {
  subscriptionId: string
  resourceGroup: string
  name: string
}

type Principal = {
  principalId: string
  principalType: string
}

type DashboardAccount = {
  subscriptionId: string
  resourceGroup: string
  name: string
  region: string
  deployment: string
}

@description('Existing Foundry/Azure OpenAI accounts. An empty ptuDeployments list skips PTU alerts for that account.')
param monitoredAccounts AccountTarget[] = []

@description('Existing Log Analytics workspaces used by your agents; the new workspace is authorized automatically.')
param existingTelemetryWorkspaces WorkspaceTarget[] = []

@description('Existing Entra users, groups, or service principals to grant Grafana Viewer access.')
param grafanaViewerPrincipals Principal[] = []

@description('Existing Entra principals allowed to publish to the new Application Insights resource.')
param telemetryPublisherPrincipals Principal[] = []

@description('PTU alerts require metric definitions and named provisioned deployments to exist already.')
param enablePtuAlerts bool = true

@minValue(1)
@maxValue(100)
param ptuUtilizationThreshold int = 85

@description('Enable agent alerts only after verifying the telemetry schema and expected traffic.')
param enableAgentAlerts bool = false

@minValue(1)
param agentMinimumRunsForFailureRate int = 20

@minValue(1)
@maxValue(100)
param agentFailureRateThresholdPercent int = 10

@minValue(1)
param agentP95LatencyThresholdMs int = 5000

@minValue(1)
param agentExpectedRunsPer15m int = 1

@description('A positive amount enables a monthly budget for the monitored accounts in the subscription billing currency.')
@minValue(0)
param monthlyAiCostBudgetAmount int = 0

param costBudgetStartDate string = ''
param costBudgetEndDate string = ''

@minValue(1)
@maxValue(100)
param costBudgetThresholdPercent int = 80

@description('Deploy the optional daily cost collector and its Log Analytics ingestion pipeline.')
param enableCostPipeline bool = false

@description('Cost query scope. Resource-group mode requires cost role assignments managed separately.')
@allowed(['subscription', 'resourceGroup'])
param costQueryScope string = 'subscription'

@minValue(31)
@maxValue(366)
param costLookbackDays int = 90

@description('Initial account controls for the Foundry overview dashboard.')
param foundryDashboardAccount DashboardAccount?

@description('Initial account and deployment controls for the OpenAI PTU dashboard.')
param ptuDashboardAccount DashboardAccount?

@description('Existing telemetry workspace ARM ID, or empty to use the new monitoring workspace.')
param dashboardTelemetryWorkspaceResourceId string = ''

var suffix = uniqueString(resourceGroup().id)
var monitoringReaderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var logAnalyticsReaderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
var grafanaAdminRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')
var grafanaViewerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '60921a7e-fef1-4a43-9b16-a26c52ad4769')
var metricsPublisherRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
var monitoredAccountIds = [for account in monitoredAccounts: resourceId(account.subscriptionId, account.resourceGroup, 'Microsoft.CognitiveServices/accounts', account.name)]
var agentAlertRules = [
  {
    name: 'failure-rate'
    description: 'Agent failure rate exceeded its threshold after the minimum run count was observed.'
    query: replace(loadTextContent('../queries/alerts/agent-failure-rate.kql'), '\${minimum_agent_runs}', string(agentMinimumRunsForFailureRate))
    measure: 'FailureRatePercent'
    operator: 'GreaterThan'
    threshold: agentFailureRateThresholdPercent
    window: 'PT10M'
    dimensions: [{ name: 'Agent', operator: 'Include', values: ['*'] }]
  }
  {
    name: 'p95-latency'
    description: 'Retained-span p95 agent run latency exceeded its threshold.'
    query: loadTextContent('../queries/alerts/agent-p95-latency.kql')
    measure: 'P95Ms'
    operator: 'GreaterThan'
    threshold: agentP95LatencyThresholdMs
    window: 'PT10M'
    dimensions: [{ name: 'Agent', operator: 'Include', values: ['*'] }]
  }
  {
    name: 'heartbeat'
    description: 'Expected agent telemetry was not observed in the last fifteen minutes.'
    query: loadTextContent('../queries/alerts/agent-heartbeat.kql')
    measure: 'ObservedRuns'
    operator: 'LessThan'
    threshold: agentExpectedRunsPer15m
    window: 'PT15M'
    dimensions: []
  }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs-${suffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appinsights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2025-08-01' = {
  name: '${namePrefix}-${take(suffix, 8)}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Standard'
  }
  properties: {
    grafanaMajorVersion: grafanaMajorVersion
    apiKey: 'Disabled'
    creatorCanAdmin: 'Disabled'
    publicNetworkAccess: 'Enabled'
    deterministicOutboundIP: 'Disabled'
    zoneRedundancy: 'Disabled'
    grafanaConfigurations: {
      snapshots: {
        externalEnabled: false
      }
      users: {
        viewersCanEdit: false
        editorsCanAdmin: false
      }
    }
  }
}

resource grafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, grafanaAdminObjectId, grafanaAdminRole)
  scope: grafana
  properties: {
    principalId: grafanaAdminObjectId
    principalType: grafanaAdminPrincipalType
    roleDefinitionId: grafanaAdminRole
  }
}

resource grafanaViewers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principal in grafanaViewerPrincipals: {
  name: guid(grafana.id, principal.principalId, grafanaViewerRole)
  scope: grafana
  properties: {
    principalId: principal.principalId
    principalType: principal.principalType
    roleDefinitionId: grafanaViewerRole
  }
}]

resource telemetryPublishers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principal in telemetryPublisherPrincipals: {
  name: guid(insights.id, principal.principalId, metricsPublisherRole)
  scope: insights
  properties: {
    principalId: principal.principalId
    principalType: principal.principalType
    roleDefinitionId: metricsPublisherRole
  }
}]

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, grafana.id, logAnalyticsReaderRole)
  scope: workspace
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReaderRole
  }
}

resource insightsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, grafana.id, monitoringReaderRole)
  scope: insights
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringReaderRole
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-alerts'
  location: 'global'
  properties: {
    groupShortName: 'AIObserve'
    enabled: true
    emailReceivers: [
      {
        name: 'operator'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

module accounts 'modules/account.bicep' = [for account in monitoredAccounts: {
  name: 'account-${uniqueString(account.subscriptionId, account.resourceGroup, account.name)}'
  scope: resourceGroup(account.subscriptionId, account.resourceGroup)
  params: {
    accountName: account.name
    grafanaPrincipalId: grafana.identity.principalId
    actionGroupId: actionGroup.id
    ptuDeployments: account.ptuDeployments
    enableAlerts: enablePtuAlerts
    utilizationThreshold: ptuUtilizationThreshold
  }
}]

module telemetryReaders 'modules/workspace-reader.bicep' = [for target in existingTelemetryWorkspaces: {
  name: 'logs-${uniqueString(target.subscriptionId, target.resourceGroup, target.name)}'
  scope: resourceGroup(target.subscriptionId, target.resourceGroup)
  params: {
    workspaceName: target.name
    grafanaPrincipalId: grafana.identity.principalId
  }
}]

resource agentAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for rule in agentAlertRules: if (enableAgentAlerts) {
  name: '${namePrefix}-${take(suffix, 8)}-agent-${rule.name}'
  location: location
  kind: 'LogAlert'
  properties: {
    description: rule.description
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: rule.window
    scopes: [workspace.id]
    severity: 2
    autoMitigate: true
    skipQueryValidation: false
    criteria: {
      allOf: [{
        query: rule.query
        metricMeasureColumn: rule.measure
        timeAggregation: 'Average'
        operator: rule.operator
        threshold: rule.threshold
        dimensions: rule.dimensions
      }]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}]

module cost 'modules/cost.bicep' = if (enableCostPipeline) {
  name: '${namePrefix}-cost'
  params: {
    location: location
    namePrefix: namePrefix
    workspaceName: workspace.name
    insightsName: insights.name
    accountIds: monitoredAccountIds
    costQueryScope: costQueryScope
    lookbackDays: costLookbackDays
    retentionInDays: retentionInDays
  }
}

module costReader 'modules/cost-reader.bicep' = if (enableCostPipeline && costQueryScope == 'subscription') {
  name: '${namePrefix}-cost-reader'
  scope: subscription()
  params: {
    principalId: cost!.outputs.principalId
  }
}

module budget 'modules/budget.bicep' = if (monthlyAiCostBudgetAmount > 0) {
  name: '${namePrefix}-budget'
  scope: subscription()
  params: {
    name: '${namePrefix}-ai-accounts-monthly'
    accountIds: monitoredAccountIds
    amount: monthlyAiCostBudgetAmount
    startDate: costBudgetStartDate
    endDate: costBudgetEndDate
    thresholdPercent: costBudgetThresholdPercent
    notificationEmail: notificationEmail
    actionGroupId: actionGroup.id
  }
}

output grafanaEndpoint string = grafana.properties.endpoint
output grafanaName string = grafana.name
output grafanaPrincipalId string = grafana.identity.principalId
output workspaceResourceId string = workspace.id
output applicationInsightsResourceId string = insights.id
output actionGroupResourceId string = actionGroup.id
output costFunctionName string = enableCostPipeline ? cost!.outputs.functionName : ''
output costIdentityPrincipalId string = enableCostPipeline ? cost!.outputs.principalId : ''
output dashboardConfiguration object = {
  monitoringWorkspaceResourceId: workspace.id
  telemetryWorkspaceResourceId: empty(dashboardTelemetryWorkspaceResourceId) ? workspace.id : dashboardTelemetryWorkspaceResourceId
  foundryAccount: foundryDashboardAccount
  ptuAccount: ptuDashboardAccount
  enableCostDashboard: enableCostPipeline
}
