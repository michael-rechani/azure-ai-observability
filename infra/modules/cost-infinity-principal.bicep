extension microsoftGraphV1

@description('Display name of the app registration Grafana Infinity signs in as.')
param displayName string

@description('Stable name that makes redeployments update the same app registration instead of creating another.')
param uniqueName string

@description('Object ID that owns the app registration. The Grafana provisioning step needs ownership to create its client secret.')
param ownerObjectId string

resource application 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  owners: {
    relationships: [ownerObjectId]
  }
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: application.appId
}

output clientId string = application.appId
output servicePrincipalObjectId string = servicePrincipal.id
