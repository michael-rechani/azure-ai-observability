targetScope = 'resourceGroup'

param location string
param namePrefix string
param workspaceName string
param insightsName string
param accountIds string[]
param costQueryScope string
param lookbackDays int
param retentionInDays int

var suffix = take(uniqueString(subscription().id, resourceGroup().id, namePrefix), 12)
var costColumns = [
  { name: 'TimeGenerated', type: 'dateTime' }
  { name: 'RecordType', type: 'string' }
  { name: 'RunId', type: 'string' }
  { name: 'RowKey', type: 'string' }
  { name: 'CostType', type: 'string' }
  { name: 'ResourceId', type: 'string' }
  { name: 'UsageDate', type: 'dateTime' }
  { name: 'Currency', type: 'string' }
  { name: 'Cost', type: 'real' }
  { name: 'ExpectedRows', type: 'long' }
  { name: 'WindowStart', type: 'dateTime' }
  { name: 'WindowEnd', type: 'dateTime' }
]
var streamColumns = [for column in costColumns: {
  name: column.name
  type: column.type == 'dateTime' ? 'datetime' : column.type
}]
var blobOwnerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var tableContributorRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var metricsPublisherRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: insightsName
}

resource costTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: 'AICostSnapshot_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    schema: {
      name: 'AICostSnapshot_CL'
      description: 'Complete daily snapshots of account-attributed pretax Azure costs.'
      columns: costColumns
    }
  }
}

resource endpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'ai-cost-${suffix}'
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource rule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'ai-cost-${suffix}'
  location: location
  properties: {
    dataCollectionEndpointId: endpoint.id
    streamDeclarations: {
      'Custom-AICostSnapshot': {
        columns: streamColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-AICostSnapshot']
        destinations: ['workspace']
        transformKql: 'source'
        outputStream: 'Custom-AICostSnapshot_CL'
      }
    ]
  }
  dependsOn: [costTable]
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'ai-cost-${suffix}'
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'aicost${suffix}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'cost-storage-blob-read'
  scope: blobService
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
    ]
    metrics: []
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'function-deployment'
  properties: {
    publicAccess: 'None'
  }
}

resource blobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobOwnerRole)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobOwnerRole
  }
}

resource tableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, tableContributorRole)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableContributorRole
  }
}

resource ingestionPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(rule.id, identity.id, metricsPublisherRole)
  scope: rule
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: metricsPublisherRole
  }
}

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, identity.id, metricsPublisherRole)
  scope: insights
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: metricsPublisherRole
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'ai-cost-${suffix}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: 'ai-cost-${suffix}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      runtime: {
        name: 'powershell'
        version: '7.6'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
    }
  }
  dependsOn: [
    blobOwner
    tableContributor
    ingestionPublisher
    telemetryPublisher
  ]
}

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: app
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: identity.properties.clientId
    APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${identity.properties.clientId};Authorization=AAD'
    COST_SUBSCRIPTION_ID: subscription().subscriptionId
    COST_ACCOUNT_IDS: string(accountIds)
    COST_QUERY_SCOPE: costQueryScope
    COST_INGESTION_ENDPOINT: endpoint.properties.logsIngestion.endpoint
    COST_DCR_IMMUTABLE_ID: rule.properties.immutableId
    COST_IDENTITY_CLIENT_ID: identity.properties.clientId
    COST_LOOKBACK_DAYS: string(lookbackDays)
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

output functionName string = app.name
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output ingestionEndpoint string = endpoint.properties.logsIngestion.endpoint
output ruleImmutableId string = rule.properties.immutableId
