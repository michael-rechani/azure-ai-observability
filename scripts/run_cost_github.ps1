[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $TenantId,
    [Parameter(Mandatory)]
    [string] $AccountIdsJson,
    [Parameter(Mandatory)]
    [string] $IngestionEndpoint,
    [Parameter(Mandatory)]
    [string] $RuleId,
    [Parameter(Mandatory)]
    [string] $IdentityClientId,
    [ValidateSet('subscription', 'resourceGroup')]
    [string] $CostQueryScope = 'resourceGroup',
    [ValidateRange(31, 366)]
    [int] $LookbackDays = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required after GitHub OIDC login.'
}

function Get-CliAccessToken {
    param([string] $Resource)

    $text = (& az account get-access-token --tenant $TenantId --resource $Resource `
        --query '{accessToken:accessToken,expires_on:expires_on}' --output json --only-show-errors | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI could not obtain the $Resource access token."
    }
    try {
        $response = ConvertFrom-Json -InputObject $text
    }
    catch {
        throw 'Azure CLI returned invalid access-token metadata.'
    }
    $expiresOn = 0L
    if ($null -eq $response -or
        $null -eq $response.PSObject.Properties['accessToken'] -or
        [string]::IsNullOrWhiteSpace([string] $response.accessToken) -or
        $null -eq $response.PSObject.Properties['expires_on'] -or
        -not [long]::TryParse([string] $response.expires_on, [ref] $expiresOn)) {
        throw 'Azure CLI returned incomplete access-token metadata.'
    }
    if ($expiresOn -lt [DateTimeOffset]::UtcNow.AddMinutes(51).ToUnixTimeSeconds()) {
        throw 'The Azure access token expires too soon for the 50-minute collector job.'
    }
    return [string] $response.accessToken
}

$armToken = $null
$ingestionToken = $null
try {
    $armToken = Get-CliAccessToken -Resource 'https://management.azure.com/'
    $ingestionToken = Get-CliAccessToken -Resource 'https://monitor.azure.com/'
    $collector = Join-Path (Split-Path -Parent $PSScriptRoot) 'function' 'cost-collector' 'cost_collector.ps1'
    & $collector -SubscriptionId $SubscriptionId -AccountIdsJson $AccountIdsJson `
        -IngestionEndpoint $IngestionEndpoint -RuleId $RuleId -IdentityClientId $IdentityClientId `
        -IdentityProvider 'accessTokens' -ArmAccessToken $armToken -IngestionAccessToken $ingestionToken `
        -CostQueryScope $CostQueryScope -LookbackDays $LookbackDays
}
finally {
    $armToken = $null
    $ingestionToken = $null
}
