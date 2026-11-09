targetScope = 'subscription'

param location string
param exportNamePrefix string
param storageAccountId string
param currentContainerName string
param closedContainerName string
param rootFolderPath string
param startDate string
param endDate string

var recurrencePeriod = {
  from: '${startDate}T00:00:00Z'
  to: '${endDate}T00:00:00Z'
}

resource current 'Microsoft.CostManagement/exports@2025-03-01' = {
  name: '${exportNamePrefix}-current'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    format: 'Csv'
    compressionMode: 'None'
    dataOverwriteBehavior: 'OverwritePreviousReport'
    deliveryInfo: {
      destination: {
        resourceId: storageAccountId
        container: currentContainerName
        rootFolderPath: rootFolderPath
      }
    }
    definition: {
      type: 'ActualCost'
      timeframe: 'MonthToDate'
    }
    schedule: {
      status: 'Active'
      recurrence: 'Daily'
      recurrencePeriod: recurrencePeriod
    }
  }
}

resource closed 'Microsoft.CostManagement/exports@2025-03-01' = {
  name: '${exportNamePrefix}-closed'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    format: 'Csv'
    compressionMode: 'None'
    dataOverwriteBehavior: 'OverwritePreviousReport'
    deliveryInfo: {
      destination: {
        resourceId: storageAccountId
        container: closedContainerName
        rootFolderPath: rootFolderPath
      }
    }
    definition: {
      type: 'ActualCost'
      timeframe: 'TheLastMonth'
    }
    schedule: {
      status: 'Active'
      recurrence: 'Monthly'
      recurrencePeriod: recurrencePeriod
    }
  }
}

output exportIdentities array = [
  {
    key: current.name
    principalId: current.identity.principalId
  }
  {
    key: closed.name
    principalId: closed.identity.principalId
  }
]
output currentExportName string = current.name
output closedExportName string = closed.name
