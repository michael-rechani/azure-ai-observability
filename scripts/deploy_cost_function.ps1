[CmdletBinding()]
param(
    [string] $ResourceGroup = $env:COST_FUNCTION_GROUP,
    [string] $FunctionName = $env:COST_FUNCTION_NAME,
    [string] $SubscriptionId = $env:COST_FUNCTION_SUBSCRIPTION,
    [string] $Package = $env:COST_FUNCTION_PACKAGE
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required to deploy the cost Function; install it and sign in first.'
}
foreach ($entry in @{
    ResourceGroup  = $ResourceGroup
    FunctionName   = $FunctionName
    SubscriptionId = $SubscriptionId
    Package        = $Package
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        throw "$($entry.Key) is required to deploy the cost Function."
    }
}
if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
    throw "Cost Function package does not exist: $Package"
}

$arguments = @(
    'functionapp', 'deployment', 'source', 'config-zip',
    '--resource-group', $ResourceGroup,
    '--name', $FunctionName,
    '--subscription', $SubscriptionId,
    '--src', $Package,
    '--only-show-errors', '--output', 'none'
)
& az @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Cost Function deployment failed with Azure CLI exit code $LASTEXITCODE."
}
