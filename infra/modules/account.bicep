param accountName string
param grafanaPrincipalId string
param actionGroupId string
param ptuDeployments string[]
param enableAlerts bool
param utilizationThreshold int

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

var readerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, grafanaPrincipalId, readerRole)
  scope: account
  properties: {
    principalId: grafanaPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole
  }
}

resource utilization 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableAlerts && !empty(ptuDeployments)) {
  name: '${accountName}-ptu-utilization'
  location: 'global'
  properties: {
    description: 'Sustained PTU utilization; investigate workload and capacity before changing deployments.'
    severity: 2
    enabled: true
    scopes: [account.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'utilization'
          metricNamespace: 'Microsoft.CognitiveServices/accounts'
          metricName: 'AzureOpenAIProvisionedManagedUtilizationV2'
          operator: 'GreaterThanOrEqual'
          threshold: utilizationThreshold
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'ModelDeploymentName'
              operator: 'Include'
              values: ptuDeployments
            }
          ]
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

resource throttling 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableAlerts && !empty(ptuDeployments)) {
  name: '${accountName}-ptu-throttling'
  location: 'global'
  properties: {
    description: 'One or more HTTP 429 responses on a named PTU deployment in five minutes.'
    severity: 2
    enabled: true
    scopes: [account.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'throttling'
          metricNamespace: 'Microsoft.CognitiveServices/accounts'
          metricName: 'AzureOpenAIRequests'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'ModelDeploymentName'
              operator: 'Include'
              values: ptuDeployments
            }
            {
              name: 'StatusCode'
              operator: 'Include'
              values: ['429']
            }
          ]
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}
