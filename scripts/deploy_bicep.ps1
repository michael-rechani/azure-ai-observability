[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [string] $ResourceGroup,
    [Parameter(Mandatory)]
    [string] $ParametersFile,
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'bicep_validation.ps1')

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI with Bicep is required; install it and sign in first.'
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    throw 'ResourceGroup is required.'
}
$parameterPath = (Resolve-Path -LiteralPath $ParametersFile).Path
if (-not $parameterPath.EndsWith('.bicepparam', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ParametersFile must be a .bicepparam file.'
}
$root = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $root 'infra' 'main.bicep'
$bundleText = (& az bicep build-params --file $parameterPath --stdout | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "Bicep parameter compilation failed with Azure CLI exit code $LASTEXITCODE."
}
$bundle = $bundleText | ConvertFrom-Json -AsHashtable -Depth 100
if (-not $bundle.parametersJson) {
    throw 'Azure CLI did not return compiled Bicep parameters.'
}
$compiledParameters = $bundle.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100
Test-BicepDeploymentParameters -Parameters $compiledParameters.parameters -SubscriptionId $SubscriptionId

$parameterTemp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ai-observability-$([guid]::NewGuid().ToString('N')).parameters.json")
try {
    [IO.File]::WriteAllText($parameterTemp, $bundle.parametersJson, [Text.UTF8Encoding]::new($false))
    $arguments = @(
        'deployment', 'group', $(if ($WhatIf) { 'what-if' } else { 'create' }),
        '--name', 'ai-observability',
        '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId,
        '--template-file', $templatePath,
        '--parameters', $parameterTemp,
        '--only-show-errors'
    )
    if ($WhatIf) {
        & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Azure what-if failed with exit code $LASTEXITCODE."
        }
        return
    }

    $arguments += @('--query', 'properties.outputs', '--output', 'json')
    $outputText = (& az @arguments | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep deployment failed with Azure CLI exit code $LASTEXITCODE."
    }
    $outputs = $outputText | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $outputs.grafanaEndpoint.value -or -not $outputs.dashboardConfiguration.value) {
        throw 'Azure deployment did not return the required Grafana endpoint and dashboard configuration.'
    }

    $costEnabled = [bool](Get-BicepParameter $compiledParameters.parameters 'enableCostPipeline' $false)
    $costMode = [string](Get-BicepParameter $compiledParameters.parameters 'costCollectorMode' 'githubOidc')
    if ($costEnabled -and $costMode -eq 'function') {
        $functionName = [string]$outputs.costFunctionName.value
        if ([string]::IsNullOrWhiteSpace($functionName)) {
            throw 'Azure deployment did not return the cost Function name.'
        }
        $package = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ai-cost-$([guid]::NewGuid().ToString('N')).zip")
        try {
            $functionDirectory = Join-Path $root 'function' 'cost-collector'
            Compress-Archive -Path (Join-Path $functionDirectory '*') -DestinationPath $package
            & (Join-Path $PSScriptRoot 'deploy_cost_function.ps1') `
                -ResourceGroup $ResourceGroup -FunctionName $functionName `
                -SubscriptionId $SubscriptionId -Package $package
        }
        finally {
            if (Test-Path -LiteralPath $package -PathType Leaf) {
                Remove-Item -LiteralPath $package
            }
        }
    }

    & (Join-Path $PSScriptRoot 'provision_grafana.ps1') `
        -Endpoint $outputs.grafanaEndpoint.value -SubscriptionId $SubscriptionId `
        -DashboardConfiguration $outputs.dashboardConfiguration.value
    Write-Host "Azure resources and Grafana dashboards deployed. Grafana: $($outputs.grafanaEndpoint.value)"
}
finally {
    if (Test-Path -LiteralPath $parameterTemp -PathType Leaf) {
        Remove-Item -LiteralPath $parameterTemp
    }
}
