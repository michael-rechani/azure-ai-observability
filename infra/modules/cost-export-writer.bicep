targetScope = 'resourceGroup'

param storageAccountName string
param exportIdentities array

var storageBlobDataContributorRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource writers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for identity in exportIdentities: {
  name: guid(storage.id, identity.key, storageBlobDataContributorRole)
  scope: storage
  properties: {
    principalId: identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRole
  }
}]
