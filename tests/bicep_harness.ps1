$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$global:HttpCalls = [System.Collections.ArrayList]::new()
$global:CliCalls = [System.Collections.ArrayList]::new()
$global:TempParameters = ''
$global:ZipEntries = @()
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
    enableCostDashboard = $env:TEST_COST_DASHBOARD -ne 'false'
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
                costFunctionName = @{ value = 'ai-cost-example' }
            } | ConvertTo-Json -Depth 30 -Compress
        }
        return
    }
    if ($arguments[0] -eq 'functionapp') {
        $index = [Array]::IndexOf($arguments, '--src')
        $archive = [IO.Compression.ZipFile]::OpenRead($arguments[$index + 1])
        try {
            $global:ZipEntries = @($archive.Entries | ForEach-Object FullName)
        }
        finally {
            $archive.Dispose()
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
    elseif ($Method -eq 'Get' -and $path -like '/api/datasources/uid/*') {
        if ($mode -eq 'new') {
            $status = 404
        }
        else {
            $content = @{
                id = 4
                version = 7
                uid = 'ai-observability-azure-monitor'
                name = 'AI observability - Azure Monitor'
                type = 'grafana-azure-monitor-datasource'
                readOnly = $false
                jsonData = if ($mode -eq 'unmanaged-source') { @{} } else { @{ aiObservabilityOwner = 'azure-ai-observability-bicep-v1' } }
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
            & (Join-Path $root 'scripts' 'provision_grafana.ps1') `
                -Endpoint $env:TEST_ENDPOINT -SubscriptionId $subscription -DashboardConfiguration $configuration
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
        zipEntries = @($global:ZipEntries)
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $env:TEST_LOG -Encoding utf8
}
