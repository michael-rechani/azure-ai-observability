targetScope = 'subscription'

param stackResourceGroupId string
param namePrefix string
param principalId string

var roleKey = uniqueString(subscription().id, stackResourceGroupId, namePrefix, 'infinity-cost-subscription')

// Read-only by construction: the only action is a Cost Management query. The built-in Cost Management Reader
// also grants Microsoft.Support/*, so it is not used.
resource costQueryRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, stackResourceGroupId, namePrefix, 'infinity-cost-subscription')
  properties: {
    roleName: 'AI Observatory Cost Query infinity-cost subscription ${roleKey}'
    description: 'Query Cost Management for the subscription.'
    type: 'CustomRole'
    permissions: [
      {
        actions: ['Microsoft.CostManagement/query/read']
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [subscription().id]
  }
}

resource costQueryAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, costQueryRole.id)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: costQueryRole.id
  }
}
