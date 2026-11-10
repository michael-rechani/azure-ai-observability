$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$global:HttpCalls = [System.Collections.ArrayList]::new()
$global:CliCalls = [System.Collections.ArrayList]::new()
$global:TempParameters = ''
$subscription = '11111111-1111-1111-1111-111111111111'
$workspace = "/subscriptions/$subscription/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/logs"
$configuration = @{
    monitoringWorkspaceResourceId = $workspace
    telemetryWorkspaceResourceId = "/subscriptions/$subscription/resourceGroups/agents/providers/Microsoft.OperationalInsights/workspaces/telemetry"
    foundryAccount = @{
        subscriptionId = $subscription
        resourceGroup = 'foundry-rg'
        name = 'foundry-account'
        region = 'eastus'
        deployment = '*'
    }
    ptuAccount = @{
        subscriptionId = $subscription
        resourceGroup = 'foundry-rg'
        name = 'foundry-account'
        region = 'eastus'
        deployment = 'ptu-one'
    }
    enableBusinessOverview = $env:TEST_BUSINESS_OVERVIEW -ne 'false'
    enableCostExportDashboard = $env:TEST_COST_EXPORT -eq 'true'
    costExportClusterUri = if ($env:TEST_COST_EXPORT_URI) { $env:TEST_COST_EXPORT_URI } else { 'https://adx.eastus.kusto.windows.net' }
    costExportDatabase = 'costs'
    enableCostInfinityDashboard = $env:TEST_COST_INFINITY -eq 'true'
    costInfinityTenantId = '55555555-5555-5555-5555-555555555555'
    costInfinityClientId = if ($env:TEST_INFINITY_CLIENT_ID) { $env:TEST_INFINITY_CLIENT_ID } else { '66666666-6666-6666-6666-666666666666' }
    costInfinityScope = if ($env:TEST_INFINITY_SCOPE) { $env:TEST_INFINITY_SCOPE } else { "/subscriptions/$subscription" }
    enableCostInfinityAlert = $env:TEST_INFINITY_ALERT -ne 'false'
}
if ($env:TEST_ALERT_INTERVAL) {
    $configuration['costInfinityAlertIntervalMinutes'] = $env:TEST_ALERT_INTERVAL
}
if ($env:TEST_ALERT_PENDING) {
    $configuration['costInfinityAlertPendingMinutes'] = $env:TEST_ALERT_PENDING
}

function global:az {
    $arguments = @($args)
    [void]$global:CliCalls.Add($arguments)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'bicep') {
        return Get-Content -LiteralPath $env:TEST_BUNDLE -Raw
    }
    if ($arguments[0] -eq 'account') {
        return 'fake-grafana-token'
    }
    if ($arguments[0] -eq 'deployment') {
        $index = [Array]::IndexOf($arguments, '--parameters')
        $global:TempParameters = $arguments[$index + 1]
        if (-not (Test-Path -LiteralPath $global:TempParameters)) {
            throw 'Compiled parameters were not passed to the deployment.'
        }
        if ($arguments[2] -eq 'create') {
            return @{
                grafanaEndpoint = @{ value = 'https://test.eastus.grafana.azure.com' }
                dashboardConfiguration = @{ value = $configuration }
            } | ConvertTo-Json -Depth 30 -Compress
        }
        return
    }
    throw "Unexpected mocked Azure CLI command: $($arguments[0])"
}

function global:Invoke-WebRequest {
    param($Uri, $Method, $Headers, $MaximumRedirection, $TimeoutSec, $SkipHttpErrorCheck, $ErrorAction, $ContentType, $Body)
    $path = ([uri]$Uri).AbsolutePath
    $parsedBody = if ($null -ne $Body) {
        [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable -Depth 100
    } else { $null }
    [void]$global:HttpCalls.Add(@{
        method = $Method
        path = $path
        maximumRedirection = $MaximumRedirection
        body = $parsedBody
    })
    $mode = $env:TEST_MODE
    $status = 200
    $content = @{}
    if ($mode -eq 'denied') {
        $status = 403
    }
    elseif ($mode -eq 'redirect') {
        $status = 302
    }
    elseif ($Method -eq 'Get' -and $path -like '/api/plugins/*/settings') {
        if ($env:TEST_PLUGIN_MISSING -eq 'true') {
            $status = 404
        }
        else {
            $content = @{ id = $path.Split('/')[3]; signature = 'valid' }
        }
    }
    elseif ($Method -eq 'Get' -and $path -like '/api/datasources/uid/*') {
        if ($mode -eq 'new') {
            $status = 404
        }
        else {
            $uid = $path.Split('/')[-1]
            $isAdx = $uid -eq 'ai-observability-azure-data-explorer'
            $isInfinity = $uid -eq 'ai-observability-cost-infinity'
            $unmanaged = $mode -eq 'unmanaged-source' -or ($isAdx -and $mode -eq 'unmanaged-adx-source') -or ($isInfinity -and $mode -eq 'unmanaged-infinity-source')
            $content = @{
                id = if ($isInfinity) { 6 } elseif ($isAdx) { 5 } else { 4 }
                version = if ($isInfinity) { 2 } elseif ($isAdx) { 3 } else { 7 }
                uid = $uid
                name = if ($isInfinity) { 'AI observability - Cost Management (Infinity)' } elseif ($isAdx) { 'AI observability - Azure Data Explorer' } else { 'AI observability - Azure Monitor' }
                type = if ($isInfinity) { 'yesoreyeram-infinity-datasource' } elseif ($isAdx) { 'grafana-azure-data-explorer-datasource' } else { 'grafana-azure-monitor-datasource' }
                readOnly = $false
                jsonData = if ($unmanaged) { @{} } else { @{ aiObservabilityOwner = 'azure-ai-observability-bicep-v1' } }
            }
        }
    }
    elseif ($Method -eq 'Get' -and $path -like '/api/dashboards/uid/*') {
        if ($mode -eq 'new') {
            $status = 404
        }
        else {
            $uid = $path.Split('/')[-1]
            $content = @{
                dashboard = @{
                    uid = $uid
                    id = 10
                    version = 12
                    tags = if ($mode -eq 'unmanaged-dashboard') { @('other') } else { @('managed-by-azure-ai-observability-bicep') }
                }
                meta = @{ folderUid = 'my-folder' }
            }
            if ($mode -eq 'missing-dashboard-tags') {
                [void]$content.dashboard.Remove('tags')
            }
        }
    }
    elseif ($Method -eq 'Get' -and $path -like '/api/folders/*') {
        if ($mode -eq 'new') {
            $status = 404
        }
        else {
            $content = @{ id = 20; uid = $path.Split('/')[-1]; title = 'AI observability alerts'; version = 1 }
        }
    }
    elseif ($Method -eq 'Get' -and $path -like '/api/v1/provisioning/folder/*/rule-groups/*') {
        if ($mode -eq 'new') {
            $status = 404
        }
        else {
            $content = @{
                title = [uri]::UnescapeDataString($path.Split('/')[-1])
                folderUid = $path.Split('/')[4]
                interval = 3600
                rules = @(@{
                    uid = 'ai-observability-infinity-cost'
                    labels = if ($mode -eq 'unmanaged-alert-group') { @{ team = 'other' } } else { @{ managed_by = 'azure-ai-observability-bicep-v1' } }
                })
            }
        }
    }
    elseif ($Method -eq 'Post' -and $path -eq '/api/folders') {
        $content = @{ id = 20; uid = $parsedBody.uid; title = $parsedBody.title }
    }
    elseif ($Method -eq 'Post' -and $path -eq '/api/dashboards/db') {
        if ($mode -eq 'version-conflict') {
            $status = 412
        }
        else {
            $content = @{ url = "/d/$($parsedBody.dashboard.uid)/dashboard" }
        }
    }
    return [pscustomobject]@{
        StatusCode = $status
        Content = ($content | ConvertTo-Json -Depth 100 -Compress)
    }
}

try {
    switch ($env:TEST_ACTION) {
        'validate' {
            . (Join-Path $root 'scripts' 'bicep_validation.ps1')
            $parameters = Get-Content -LiteralPath $env:TEST_PARAMETERS -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            Test-BicepDeploymentParameters -Parameters $parameters -SubscriptionId $subscription
        }
        'grafana' {
            $grafanaArguments = @{
                Endpoint = $env:TEST_ENDPOINT
                SubscriptionId = $subscription
                DashboardConfiguration = $configuration
            }
            if ($env:TEST_INFINITY_SECRET_PARAMETER -eq 'true') {
                $grafanaArguments['CostInfinityClientSecret'] = ConvertTo-SecureString -String 'test-secret-value' -AsPlainText -Force
            }
            & (Join-Path $root 'scripts' 'provision_grafana.ps1') @grafanaArguments
        }
        'deploy' {
            $arguments = @{
                SubscriptionId = $subscription
                ResourceGroup = 'monitoring'
                ParametersFile = $env:TEST_PARAMETER_FILE
            }
            if ($env:TEST_WHAT_IF -eq 'true') {
                $arguments['WhatIf'] = $true
            }
            if ($env:TEST_INFINITY_SECRET_PARAMETER -eq 'true') {
                $arguments['CostInfinityClientSecret'] = ConvertTo-SecureString -String 'test-secret-value' -AsPlainText -Force
            }
            & (Join-Path $root 'scripts' 'deploy_bicep.ps1') @arguments
        }
        default { throw 'Unknown harness action.' }
    }
}
finally {
    @{
        http = @($global:HttpCalls)
        cli = @($global:CliCalls)
        parameterTemp = $global:TempParameters
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $env:TEST_LOG -Encoding utf8
}
