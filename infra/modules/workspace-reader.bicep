param workspaceName string
param grafanaPrincipalId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

var role = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, grafanaPrincipalId, role)
  scope: workspace
  properties: {
    principalId: grafanaPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: role
  }
}
