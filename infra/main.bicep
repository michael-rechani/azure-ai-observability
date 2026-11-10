targetScope = 'resourceGroup'

@description('Region supporting Azure Managed Grafana Standard and Application Insights.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(20)
param namePrefix string = 'ai-observe'

@description('Microsoft Entra object ID of the user, group, or service principal receiving Grafana Admin access.')
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

@description('Provision the Business overview dashboard (agent and PTU signals) when Grafana is provisioned from dashboardConfiguration. It has no cost panels.')
param enableBusinessOverview bool = false

@description('Deploy the native cost path: subscription Cost Management Exports to private storage, read by Azure Data Explorer, queried by Grafana over managed identities. No secrets, but it adds a standing Azure Data Explorer cluster cost.')
param enableCostExport bool = false

@description('Azure Data Explorer SKU for the cost database. The Dev SKU is the cheapest and carries no SLA.')
param costExportAdxSkuName string = 'Dev(No SLA)_Standard_E2a_v4'

@minValue(1)
param costExportAdxCapacity int = 1

@description('Object ID of the identity that runs this deployment (for example, az ad signed-in-user show --query id). Required when enableCostExport is true: it is granted AllDatabasesAdmin on the dedicated cost cluster because only that role can set the managed-identity policy the export script needs. Remove the assignment afterwards if you do not need it.')
param costExportDeployerObjectId string = ''

@allowed(['User', 'App', 'Group'])
param costExportDeployerPrincipalType string = 'User'

@allowed(['public', 'privateEndpoint', 'privateOnly'])
@description('How Grafana reaches the cost cluster. public (default) uses the cluster public endpoint. privateEndpoint adds a Grafana managed private endpoint and keeps the public endpoint. privateOnly adds the managed private endpoint and disables the public endpoint. Either private option leaves the connection Pending until scripts/approve_grafana_private_endpoint.ps1 approves it, so use privateEndpoint first if you want Grafana to keep working during the switch.')
param costExportGrafanaAccess string = 'public'

@description('First scheduled export date (yyyy-MM-dd); it must be in the future. Pass the existing value on redeploys so the schedule is not moved.')
param costExportStartDate string = dateTimeAdd(utcNow(), 'P1D', 'yyyy-MM-dd')

@description('Last scheduled export date (yyyy-MM-dd). Exports stop after this date.')
param costExportEndDate string = dateTimeAdd(utcNow(), 'P5Y', 'yyyy-MM-dd')

@description('Opt in to direct Cost Management queries from Grafana through the Infinity plugin. It needs no export or cluster, but it is NOT secretless: Infinity supports only a service principal client secret, which you create, pass to the Grafana provisioning step (never to this template) and rotate.')
param enableCostInfinity bool = false

@description('Application (client) ID of the service principal Infinity signs in as. scripts/new_cost_infinity_principal.ps1 creates it.')
param costInfinityClientId string = ''

@description('Object ID of the same principal in Enterprise applications, used for the Cost Management role assignment.')
param costInfinityServicePrincipalObjectId string = ''

@description('Where Infinity may query cost: subscription (Cost Management Reader) or resourceGroupManaged (a query-only custom role per monitored resource group).')
@allowed(['subscription', 'resourceGroupManaged'])
param costInfinityScope string = 'subscription'

@description('Reject incomplete Infinity settings before any role is created.')
@allowed([true])
param costInfinityConfigured bool = any(!enableCostInfinity || (length(costInfinityClientId) == 36 && length(costInfinityServicePrincipalObjectId) == 36 && (costInfinityScope == 'subscription' || length(monitoredAccounts) > 0)))

@description('With enableCostInfinity, have the Grafana provisioning step create an alert rule that fires when the Infinity data source can no longer query Cost Management (for example an expired client secret). It still needs a contact point that routes component=cost-infinity.')
param enableCostInfinityAlert bool = true

@description('How often the Infinity alert rule queries Cost Management, in minutes. Every evaluation is one Cost Management query.')
@minValue(5)
@maxValue(1440)
param costInfinityAlertIntervalMinutes int = 60

@description('How long the Infinity query must keep failing before the alert fires, in minutes. It absorbs Cost Management throttling (HTTP 429) and one-off failures.')
@minValue(0)
@maxValue(1440)
param costInfinityAlertPendingMinutes int = 60

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
var costAccountGroupTargets = [for account in monitoredAccounts: {
  subscriptionId: toLower(account.subscriptionId)
  name: toLower(account.resourceGroup)
}]
var costAccountGroups = union(costAccountGroupTargets, [])
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
    grafanaPlugins: enableCostInfinity ? {
      'yesoreyeram-infinity-datasource': {}
    } : null
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

module costInfinityReader 'modules/cost-reader.bicep' = if (enableCostInfinity && costInfinityScope == 'subscription') {
  name: '${namePrefix}-cost-infinity-reader'
  scope: subscription()
  params: {
    principalId: costInfinityServicePrincipalObjectId
  }
}

module costInfinityGroupReaders 'modules/cost-group-reader.bicep' = [for group in costAccountGroups: if (enableCostInfinity && costInfinityScope == 'resourceGroupManaged') {
  name: '${namePrefix}-cost-infinity-rg-${uniqueString(resourceGroup().id, namePrefix, group.name)}'
  scope: subscription()
  params: {
    resourceGroupName: group.name
    stackResourceGroupId: resourceGroup().id
    namePrefix: namePrefix
    principalId: costInfinityServicePrincipalObjectId
    subscriptionMatches: group.subscriptionId == toLower(subscription().subscriptionId)
    roleLabel: 'infinity-cost'
  }
}]

module costExport 'modules/cost-export.bicep' = if (enableCostExport) {
  name: '${namePrefix}-cost-export'
  params: {
    location: location
    namePrefix: namePrefix
    grafanaPrincipalId: grafana.identity.principalId
    adxSkuName: costExportAdxSkuName
    adxCapacity: costExportAdxCapacity
    deployerObjectId: costExportDeployerObjectId
    deployerPrincipalType: costExportDeployerPrincipalType
    grafanaName: grafana.name
    grafanaAccess: costExportGrafanaAccess
  }
}

module costExports 'modules/cost-exports.bicep' = if (enableCostExport) {
  name: '${namePrefix}-cost-exports'
  scope: subscription()
  params: {
    location: location
    exportNamePrefix: '${namePrefix}-${take(suffix, 8)}'
    storageAccountId: costExport!.outputs.storageAccountId
    currentContainerName: costExport!.outputs.currentContainerName
    closedContainerName: costExport!.outputs.closedContainerName
    rootFolderPath: 'ai-observability'
    startDate: costExportStartDate
    endDate: costExportEndDate
  }
}

module costExportWriters 'modules/cost-export-writer.bicep' = if (enableCostExport) {
  name: '${namePrefix}-cost-export-writers'
  params: {
    storageAccountName: costExport!.outputs.storageAccountName
    exportIdentities: costExports!.outputs.exportIdentities
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
output costExportStorageAccountName string = enableCostExport ? costExport!.outputs.storageAccountName : ''
output costExportAdxClusterName string = enableCostExport ? costExport!.outputs.clusterName : ''
output costExportPrivateEndpointName string = enableCostExport ? costExport!.outputs.privateEndpointName : ''
output dashboardConfiguration object = {
  monitoringWorkspaceResourceId: workspace.id
  telemetryWorkspaceResourceId: empty(dashboardTelemetryWorkspaceResourceId) ? workspace.id : dashboardTelemetryWorkspaceResourceId
  foundryAccount: foundryDashboardAccount
  ptuAccount: ptuDashboardAccount
  enableBusinessOverview: enableBusinessOverview
  enableCostExportDashboard: enableCostExport
  costExportClusterUri: enableCostExport ? costExport!.outputs.clusterUri : ''
  costExportDatabase: enableCostExport ? costExport!.outputs.databaseName : ''
  enableCostInfinityDashboard: enableCostInfinity
  enableCostInfinityAlert: enableCostInfinity && enableCostInfinityAlert
  costInfinityAlertIntervalMinutes: costInfinityAlertIntervalMinutes
  costInfinityAlertPendingMinutes: costInfinityAlertPendingMinutes
  costInfinityTenantId: enableCostInfinity ? tenant().tenantId : ''
  costInfinityClientId: enableCostInfinity && costInfinityConfigured ? costInfinityClientId : ''
  costInfinityScope: enableCostInfinity ? (costInfinityScope == 'subscription' || length(monitoredAccounts) == 0 ? subscription().id : '${subscription().id}/resourceGroups/${monitoredAccounts[0].resourceGroup}') : ''
}
