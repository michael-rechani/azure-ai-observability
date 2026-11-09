targetScope = 'resourceGroup'

param location string
param namePrefix string
param grafanaPrincipalId string
param adxSkuName string
param adxCapacity int

@description('Object ID of the identity running this deployment. Only the cluster-level AllDatabasesAdmin role can set the database managed-identity policy that the script needs.')
@minLength(36)
@maxLength(36)
param deployerObjectId string

@allowed(['User', 'App', 'Group'])
param deployerPrincipalType string = 'User'

var suffix = take(uniqueString(subscription().id, resourceGroup().id, namePrefix), 12)
var databaseName = 'costs'
var currentContainerName = 'cost-current'
var closedContainerName = 'cost-closed'
var storageBlobDataReaderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var adxTier = startsWith(adxSkuName, 'Dev(No SLA)') ? 'Basic' : 'Standard'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'aiexp${suffix}'
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
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
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

resource currentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: currentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource closedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: closedContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource cluster 'Microsoft.Kusto/clusters@2024-04-13' = {
  name: 'aiadx${suffix}'
  location: location
  sku: {
    name: adxSkuName
    tier: adxTier
    capacity: adxCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enableStreamingIngest: false
    enableAutoStop: false
    publicNetworkAccess: 'Enabled'
  }
}

resource database 'Microsoft.Kusto/clusters/databases@2024-04-13' = {
  parent: cluster
  name: databaseName
  location: location
  kind: 'ReadWrite'
  properties: {
    hotCachePeriod: 'P31D'
    softDeletePeriod: 'P365D'
  }
}

resource clusterBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, cluster.id, storageBlobDataReaderRole)
  scope: storage
  properties: {
    principalId: cluster.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRole
  }
}

resource deployerAdmin 'Microsoft.Kusto/clusters/principalAssignments@2024-04-13' = {
  parent: cluster
  name: guid(cluster.id, deployerObjectId, 'AllDatabasesAdmin')
  properties: {
    principalId: deployerObjectId
    principalType: deployerPrincipalType
    role: 'AllDatabasesAdmin'
    tenantId: tenant().tenantId
  }
}

resource databaseScript 'Microsoft.Kusto/clusters/databases/scripts@2024-04-13' = {
  parent: database
  name: 'cost-export'
  properties: {
    continueOnErrors: false
    scriptContent: replace(
      replace(loadTextContent('../kusto/cost-export.kql'), '{{CURRENT_URL}}', '${storage.properties.primaryEndpoints.blob}${currentContainerName}'),
      '{{CLOSED_URL}}',
      '${storage.properties.primaryEndpoints.blob}${closedContainerName}'
    )
  }
  dependsOn: [
    clusterBlobReader
    deployerAdmin
    currentContainer
    closedContainer
  ]
}

resource grafanaViewer 'Microsoft.Kusto/clusters/databases/principalAssignments@2024-04-13' = {
  parent: database
  name: guid(database.id, grafanaPrincipalId, 'Viewer')
  properties: {
    principalId: grafanaPrincipalId
    principalType: 'App'
    role: 'Viewer'
    tenantId: tenant().tenantId
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
output currentContainerName string = currentContainerName
output closedContainerName string = closedContainerName
output clusterName string = cluster.name
output clusterUri string = cluster.properties.uri
output databaseName string = databaseName
