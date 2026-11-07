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
param grafanaMajorVersion string = '11'

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

@description('Existing Foundry/Azure OpenAI accounts. An empty ptuDeployments list skips PTU alerts for that account.')
param monitoredAccounts AccountTarget[] = []

@description('Existing Log Analytics workspaces used by your agents; the new workspace is authorized automatically.')
param existingTelemetryWorkspaces WorkspaceTarget[] = []

@description('PTU alerts require metric definitions and named provisioned deployments to exist already.')
param enablePtuAlerts bool = true

@minValue(1)
@maxValue(100)
param ptuUtilizationThreshold int = 85

var suffix = uniqueString(resourceGroup().id)
var monitoringReaderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var logAnalyticsReaderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
var grafanaAdminRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')

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

output grafanaEndpoint string = grafana.properties.endpoint
output grafanaName string = grafana.name
output grafanaPrincipalId string = grafana.identity.principalId
output workspaceResourceId string = workspace.id
output applicationInsightsResourceId string = insights.id
output actionGroupResourceId string = actionGroup.id
