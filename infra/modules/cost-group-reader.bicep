targetScope = 'subscription'

param resourceGroupName string
param stackResourceGroupId string
param namePrefix string
param principalId string
param subscriptionMatches bool = true

@description('Distinguishes the role definition and assignment deployment when several consumers need the same permission at one group.')
@minLength(1)
@maxLength(24)
param roleLabel string = 'cost-query'

@description('Reject invalid or cross-subscription group targets before creating a role.')
@allowed([true])
// URI-encoded control bytes are %00-%1F and %7F.
// any() lets ARM validate the computed boolean against @allowed at deployment.
param scopeIsValid bool = any(subscriptionMatches && !empty(resourceGroupName) && !contains(['.', '..'], resourceGroupName) && !contains(resourceGroupName, '%') && !contains(resourceGroupName, '\\') && !contains(resourceGroupName, '/') && !contains(resourceGroupName, '?') && !contains(resourceGroupName, '#') && !contains(toUpper(uriComponent(resourceGroupName)), '%0') && !contains(toUpper(uriComponent(resourceGroupName)), '%1') && !contains(toUpper(uriComponent(resourceGroupName)), '%7F'))

var groupScope = scopeIsValid ? '${subscription().id}/resourceGroups/${resourceGroupName}' : ''
var defaultLabel = roleLabel == 'cost-query'
var roleKey = defaultLabel ? uniqueString(subscription().id, groupScope, stackResourceGroupId, namePrefix) : uniqueString(subscription().id, groupScope, stackResourceGroupId, namePrefix, roleLabel)

resource costQueryRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, groupScope, stackResourceGroupId, namePrefix, roleLabel)
  properties: {
    roleName: defaultLabel ? 'AI Observatory Cost Query ${roleKey}' : 'AI Observatory Cost Query ${roleLabel} ${roleKey}'
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
