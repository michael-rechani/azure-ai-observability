targetScope = 'subscription'

param name string
param accountIds string[]
param amount int
param startDate string
param endDate string
param thresholdPercent int
param notificationEmail string
param actionGroupId string

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: name
  properties: {
    amount: amount
    category: 'Cost'
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
      endDate: endDate
    }
    filter: {
      dimensions: {
        name: 'ResourceId'
        operator: 'In'
        values: accountIds
      }
    }
    notifications: {
      actual: {
        enabled: true
        operator: 'GreaterThan'
        threshold: thresholdPercent
        thresholdType: 'Actual'
        contactEmails: [notificationEmail]
        contactGroups: [actionGroupId]
      }
    }
  }
}
