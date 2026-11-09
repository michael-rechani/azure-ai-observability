[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,
    [Parameter(Mandatory)]
    [string] $ClusterName,
    [Parameter(Mandatory)]
    [string] $GrafanaName,
    [string] $PrivateEndpointName = 'mpe-cost-adx',
    [string] $SubscriptionId,
    [ValidateRange(1, 30)]
    [int] $TimeoutMinutes = 10
)

# Approves the private endpoint connection that an Azure Managed Grafana managed private endpoint
# opens to the cost Azure Data Explorer cluster, then waits for Grafana to see it as Approved.
# Azure names the connection itself, so Bicep and Terraform cannot approve it; this fills that gap.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}
foreach ($pair in @(
        @('ResourceGroupName', $ResourceGroupName, '^[A-Za-z0-9_().-]{1,90}$'),
        @('ClusterName', $ClusterName, '^[a-z0-9]{4,22}$'),
        @('GrafanaName', $GrafanaName, '^[A-Za-z0-9-]{2,23}$'),
        @('PrivateEndpointName', $PrivateEndpointName, '^[A-Za-z0-9-]{1,64}$'))) {
    if ($pair[1] -notmatch $pair[2]) {
        throw "$($pair[0]) is not a valid Azure resource name."
    }
}
if ($SubscriptionId) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
        throw 'SubscriptionId must be a nonzero GUID.'
    }
}
else {
    $SubscriptionId = (az account show --query id -o tsv)
    if ($LASTEXITCODE -ne 0 -or -not $SubscriptionId) {
        throw 'Sign in with az login or pass -SubscriptionId.'
    }
}

function Invoke-Arm {
    param([string] $Method, [string] $Url, [string] $Body, [switch] $Quiet)
    $arguments = @('rest', '--method', $Method, '--url', $Url, '--output', 'json')
    $bodyFile = $null
    try {
        if ($Body) {
            $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ("aiobs-" + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($bodyFile, $Body, [Text.UTF8Encoding]::new($false))
            $arguments += @('--body', "@$bodyFile")
        }
        if ($Quiet) { $arguments += @('--only-show-errors') }
        $text = if ($Quiet) { & az @arguments 2>$null } else { & az @arguments }
        if ($LASTEXITCODE -ne 0) {
            $resource = $Url -replace '^https://management\.azure\.com/subscriptions/[^/]+', '' -replace '\?.*$', ''
            throw "Azure request failed: $Method $resource"
        }
        if ($text) { return ($text -join "`n") | ConvertFrom-Json }
    }
    finally {
        if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue }
    }
}

$arm = 'https://management.azure.com'
$clusterUrl = "$arm/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Kusto/clusters/$ClusterName"
$grafanaUrl = "$arm/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Dashboard/grafana/$GrafanaName"
$endpointSuffix = "/privateEndpoints/grafana-$GrafanaName-$PrivateEndpointName"
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)

# The connection appears on the cluster about a minute after the managed private endpoint is created.
$connection = $null
while (-not $connection) {
    $connections = Invoke-Arm -Method get -Url "$clusterUrl/privateEndpointConnections?api-version=2023-08-15"
    $connection = @($connections.value) | Where-Object {
        $_.properties.privateEndpoint.id -and $_.properties.privateEndpoint.id.EndsWith($endpointSuffix, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($connection) { break }
    if ([DateTime]::UtcNow -gt $deadline) {
        throw "No private endpoint connection from managed private endpoint '$PrivateEndpointName' reached cluster '$ClusterName'. Deploy with costExportGrafanaAccess set to privateEndpoint or privateOnly first."
    }
    Start-Sleep -Seconds 15
}

$state = $connection.properties.privateLinkServiceConnectionState.status
if ($state -eq 'Approved') {
    Write-Host 'The private endpoint connection is already approved.'
}
elseif ($state -ne 'Pending') {
    throw "The private endpoint connection is $state. Delete and recreate the managed private endpoint instead of approving it."
}
elseif ($PSCmdlet.ShouldProcess("$ClusterName/$($connection.name)", 'Approve Grafana private endpoint connection')) {
    $body = @{
        properties = @{
            privateLinkServiceConnectionState = @{
                status      = 'Approved'
                description = 'Approved for Azure Managed Grafana'
            }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-Arm -Method put -Url "$clusterUrl/privateEndpointConnections/$($connection.name)?api-version=2023-08-15" -Body $body | Out-Null
    Write-Host 'Approved the private endpoint connection.'
}
else {
    return
}

# Grafana caches the connection state, so ask it to refresh and then wait.
$endpointUrl = "$grafanaUrl/managedPrivateEndpoints/${PrivateEndpointName}?api-version=2024-10-01"
do {
    try {
        Invoke-Arm -Method post -Url "$grafanaUrl/refreshManagedPrivateEndpoints?api-version=2024-10-01" -Quiet | Out-Null
    }
    catch {
        Write-Verbose 'Grafana is still processing the previous refresh; retrying.'
    }
    $endpoint = Invoke-Arm -Method get -Url $endpointUrl
    $grafanaState = $endpoint.properties.connectionState.status
    if ($grafanaState -eq 'Approved') {
        Write-Host 'Grafana reports the managed private endpoint as Approved.'
        return
    }
    Start-Sleep -Seconds 15
} while ([DateTime]::UtcNow -lt $deadline)

throw "Grafana still reports the managed private endpoint as $grafanaState after $TimeoutMinutes minutes. Run this script again."
