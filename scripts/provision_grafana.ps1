[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Endpoint,
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $DashboardConfiguration
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$uri = $null
if (-not [uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref] $uri) -or
    $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
    $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or
    $uri.Host -notmatch '^(?i:[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)*\.grafana\.azure\.com)$') {
    throw 'Grafana endpoint must be a public Azure Managed Grafana HTTPS host with no credentials, path, query, or custom port.'
}
$Endpoint = $uri.GetLeftPart([UriPartial]::Authority)
$parsedSubscription = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref] $parsedSubscription) -or $parsedSubscription -eq [guid]::Empty) {
    throw 'SubscriptionId must be a nonzero GUID.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required to authenticate to Grafana.'
}

$sourceUid = 'ai-observability-azure-monitor'
$sourceName = 'AI observability - Azure Monitor'
$owner = 'azure-ai-observability-bicep-v1'
$ownerTag = 'managed-by-azure-ai-observability-bicep'
$root = Split-Path -Parent $PSScriptRoot
$files = [ordered]@{
    'foundry-overview.json' = 'foundry'
    'foundry-agents.json' = 'agents'
    'openai-ptu.json' = 'ptu'
}
if ($DashboardConfiguration.enableCostDashboard) {
    $files['azure-ai-costs.json'] = 'cost'
    $files['business-overview.json'] = 'business'
}

function Get-AccountDefaults {
    param($Account)
    if ($null -eq $Account) {
        return @{}
    }
    return @{
        subscription = $Account.subscriptionId
        resourceGroup = $Account.resourceGroup
        account = $Account.name
        region = $Account.region
        deployment = $Account.deployment
    }
}

function Set-DashboardDefaults {
    param([System.Collections.IDictionary] $Dashboard, [hashtable] $Defaults)
    if (-not $Dashboard.Contains('templating') -or -not $Dashboard.templating.Contains('list')) {
        throw "Dashboard '$($Dashboard.uid)' is missing its template variables."
    }
    $matched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($variable in $Dashboard.templating.list) {
        if ($Defaults.ContainsKey($variable.name)) {
            if ($variable.type -ne 'textbox') {
                throw "Dashboard '$($Dashboard.uid)' variable '$($variable.name)' is not a textbox."
            }
            $value = [string]$Defaults[$variable.name]
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Dashboard '$($Dashboard.uid)' variable '$($variable.name)' has an empty configured value."
            }
            $variable['query'] = $value
            if (-not $variable.Contains('current') -or $null -eq $variable.current) {
                $variable['current'] = @{}
            }
            $variable.current['text'] = $value
            $variable.current['value'] = $value
            [void]$matched.Add($variable.name)
        }
    }
    foreach ($name in $Defaults.Keys) {
        if (-not $matched.Contains($name)) {
            throw "Dashboard '$($Dashboard.uid)' does not contain the configured textbox '$name'."
        }
    }
}

$prepared = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $files.GetEnumerator()) {
    $path = Join-Path $root 'dashboards' $entry.Key
    $content = [IO.File]::ReadAllText($path).Replace('${DS_AZURE_MONITOR}', $sourceUid)
    $dashboard = $content | ConvertFrom-Json -AsHashtable -Depth 100
    if ($dashboard.uid -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Dashboard '$($entry.Key)' has an invalid UID."
    }
    $defaults = switch ($entry.Value) {
        'foundry' {
            $values = Get-AccountDefaults $DashboardConfiguration.foundryAccount
            $values['workspaceResourceId'] = $DashboardConfiguration.telemetryWorkspaceResourceId
            $values
        }
        'agents' { @{ workspaceResourceId = $DashboardConfiguration.telemetryWorkspaceResourceId } }
        'ptu' { Get-AccountDefaults $DashboardConfiguration.ptuAccount }
        'cost' { @{ workspaceResourceId = $DashboardConfiguration.monitoringWorkspaceResourceId } }
        'business' {
            $values = @{
                workspaceResourceId = $DashboardConfiguration.telemetryWorkspaceResourceId
                monitoringWorkspaceResourceId = $DashboardConfiguration.monitoringWorkspaceResourceId
            }
            if ($DashboardConfiguration.ptuAccount) {
                $values['ptuSubscription'] = $DashboardConfiguration.ptuAccount.subscriptionId
                $values['ptuResourceGroup'] = $DashboardConfiguration.ptuAccount.resourceGroup
                $values['ptuAccount'] = $DashboardConfiguration.ptuAccount.name
                $values['ptuRegion'] = $DashboardConfiguration.ptuAccount.region
                $values['ptuDeployment'] = $DashboardConfiguration.ptuAccount.deployment
            }
            $values
        }
    }
    Set-DashboardDefaults -Dashboard $dashboard -Defaults $defaults
    $dashboard['tags'] = @($dashboard.tags | Where-Object { $_ -ne $ownerTag }) + @($ownerTag)
    $prepared.Add(@{ dashboard = $dashboard; existing = $null })
}

$token = (& az account get-access-token --subscription $SubscriptionId `
    --resource 'https://dashboard.azure.com' --query accessToken --output tsv --only-show-errors | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Could not obtain an Azure Managed Grafana Entra token. Sign in with an identity that has Grafana Admin access.'
}
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

function Invoke-GrafanaApi {
    param([string] $Method, [string] $Path, $Body = $null, [switch] $AllowNotFound)
    $request = @{
        Uri = "$Endpoint$Path"
        Method = $Method
        Headers = $headers
        MaximumRedirection = 0
        TimeoutSec = 60
        SkipHttpErrorCheck = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request['ContentType'] = 'application/json; charset=utf-8'
        $request['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress))
    }
    $response = Invoke-WebRequest @request
    $status = [int]$response.StatusCode
    if ($status -eq 404 -and $AllowNotFound) {
        return $null
    }
    if ($status -in @(401, 403)) {
        throw "Grafana returned HTTP $status for $Path. Ensure the signed-in identity has Grafana Admin access, allow time for role propagation, and rerun."
    }
    if ($status -in @(409, 412)) {
        throw "Grafana returned HTTP $status for $Path because a resource or version conflicted. Review existing resources and rerun; nothing is force-overwritten."
    }
    if ($status -lt 200 -or $status -ge 300) {
        throw "Grafana returned HTTP $status for $Path; redirects and unsuccessful responses are not followed."
    }
    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return @{}
    }
    return $response.Content | ConvertFrom-Json -AsHashtable -Depth 100
}

$existingSource = Invoke-GrafanaApi -Method 'Get' -Path "/api/datasources/uid/$sourceUid" -AllowNotFound
if ($null -ne $existingSource) {
    if (-not $existingSource.Contains('type') -or
        $existingSource.type -ne 'grafana-azure-monitor-datasource' -or
        -not $existingSource.Contains('name') -or
        $existingSource.name -ne $sourceName -or
        -not $existingSource.Contains('jsonData') -or
        $null -eq $existingSource.jsonData -or
        -not $existingSource.jsonData.Contains('aiObservabilityOwner') -or
        $existingSource.jsonData.aiObservabilityOwner -ne $owner -or
        ($existingSource.Contains('readOnly') -and $existingSource.readOnly) -or
        -not $existingSource.Contains('id') -or
        -not $existingSource.Contains('version')) {
        throw "Grafana data source '$sourceUid' already exists but is not managed by this Bicep deployment. Resolve the ownership conflict before rerunning."
    }
}
foreach ($item in $prepared) {
    $current = Invoke-GrafanaApi -Method 'Get' -Path "/api/dashboards/uid/$($item.dashboard.uid)" -AllowNotFound
    if ($null -ne $current) {
        if (-not $current.Contains('dashboard') -or $null -eq $current.dashboard -or
            -not $current.dashboard.Contains('tags') -or $ownerTag -notin @($current.dashboard.tags)) {
            throw "Grafana dashboard '$($item.dashboard.uid)' already exists but is not managed by this Bicep deployment. Resolve the ownership conflict before rerunning."
        }
        if (-not $current.dashboard.Contains('id') -or -not $current.dashboard.Contains('version')) {
            throw "Grafana dashboard '$($item.dashboard.uid)' did not return an ID and version for a safe update."
        }
        $item.existing = $current
    }
}

$source = @{
    uid = $sourceUid
    name = $sourceName
    type = 'grafana-azure-monitor-datasource'
    access = 'proxy'
    jsonData = @{
        azureAuthType = 'msi'
        subscriptionId = $SubscriptionId
        aiObservabilityOwner = $owner
    }
}
if ($null -eq $existingSource) {
    [void](Invoke-GrafanaApi -Method 'Post' -Path '/api/datasources' -Body $source)
}
else {
    $source['id'] = $existingSource.id
    $source['version'] = $existingSource.version
    [void](Invoke-GrafanaApi -Method 'Put' -Path "/api/datasources/uid/$sourceUid" -Body $source)
}

foreach ($item in $prepared) {
    if ($null -eq $item.existing) {
        $item.dashboard['id'] = $null
        $item.dashboard['version'] = 0
    }
    else {
        $item.dashboard['id'] = $item.existing.dashboard.id
        $item.dashboard['version'] = $item.existing.dashboard.version
    }
    $body = @{
        dashboard = $item.dashboard
        overwrite = $false
        message = 'Managed by Azure AI observability Bicep deployment'
    }
    if ($null -ne $item.existing -and $item.existing.Contains('meta') -and $null -ne $item.existing.meta -and
        $item.existing.meta.Contains('folderUid') -and $item.existing.meta.folderUid) {
        $body['folderUid'] = $item.existing.meta.folderUid
    }
    $result = Invoke-GrafanaApi -Method 'Post' -Path '/api/dashboards/db' -Body $body
    if (-not $result.Contains('url') -or -not $result.url) {
        throw "Grafana did not return a URL for dashboard '$($item.dashboard.uid)'."
    }
    Write-Host "Dashboard ready: $Endpoint$($result.url)"
}
