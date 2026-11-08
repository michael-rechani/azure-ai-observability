targetScope = 'subscription'

param resourceGroupName string
param stackResourceGroupId string
param namePrefix string
param principalId string
param subscriptionMatches bool = true

@description('Reject invalid or cross-subscription group targets before creating a role.')
@allowed([true])
// URI-encoded control bytes are %00-%1F and %7F.
// any() lets ARM validate the computed boolean against @allowed at deployment.
param scopeIsValid bool = any(subscriptionMatches && !empty(resourceGroupName) && !contains(['.', '..'], resourceGroupName) && !contains(resourceGroupName, '%') && !contains(resourceGroupName, '\\') && !contains(resourceGroupName, '/') && !contains(resourceGroupName, '?') && !contains(resourceGroupName, '#') && !contains(toUpper(uriComponent(resourceGroupName)), '%0') && !contains(toUpper(uriComponent(resourceGroupName)), '%1') && !contains(toUpper(uriComponent(resourceGroupName)), '%7F'))

var groupScope = scopeIsValid ? '${subscription().id}/resourceGroups/${resourceGroupName}' : ''
var roleKey = uniqueString(subscription().id, groupScope, stackResourceGroupId, namePrefix)

resource costQueryRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, groupScope, stackResourceGroupId, namePrefix, 'cost-query')
  properties: {
    roleName: 'AI Observatory Cost Query ${roleKey}'
    description: 'Query Cost Management at one monitored resource group.'
    type: 'CustomRole'
    permissions: [
      {
        actions: ['Microsoft.CostManagement/query/read']
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [groupScope]
  }
}

module assignment 'cost-group-assignment.bicep' = {
  name: 'cost-group-${roleKey}'
  scope: resourceGroup(resourceGroupName)
  params: {
    principalId: principalId
    roleDefinitionId: costQueryRole.id
  }
}
