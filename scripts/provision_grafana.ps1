[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Endpoint,
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $DashboardConfiguration,
    [System.Security.SecureString] $CostInfinityClientSecret
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
$infinityUid = 'ai-observability-cost-infinity'
$infinityName = 'AI observability - Cost Management (Infinity)'
$infinityPluginId = 'yesoreyeram-infinity-datasource'
$alertFolderUid = 'ai-observability-alerts'
$alertFolderTitle = 'AI observability alerts'
$alertGroup = 'Infinity cost data source'
$alertRuleUid = 'ai-observability-infinity-cost'
$alertCostPanelTitle = 'Month-to-date actual cost by currency'
$owner = 'azure-ai-observability-bicep-v1'
$ownerTag = 'managed-by-azure-ai-observability-bicep'
$root = Split-Path -Parent $PSScriptRoot
$files = [ordered]@{
    'foundry-overview.json' = 'foundry'
    'foundry-agents.json' = 'agents'
    'openai-ptu.json' = 'ptu'
}
if ($DashboardConfiguration.enableBusinessOverview) {
    $files['business-overview.json'] = 'business'
}
$infinityTenantId = $null
$infinityClientId = $null
$infinityScope = $null
$infinitySecret = $null
$infinityEnabled = $false
$infinityAlertEnabled = $true
$infinityAlertIntervalMinutes = 60
$infinityAlertPendingMinutes = 60
if ($DashboardConfiguration.enableCostInfinityDashboard) {
    $infinityTenantId = [string]$DashboardConfiguration.costInfinityTenantId
    $infinityClientId = [string]$DashboardConfiguration.costInfinityClientId
    $infinityScope = [string]$DashboardConfiguration.costInfinityScope
    $parsedGuid = [guid]::Empty
    foreach ($pair in @(@($infinityTenantId, 'costInfinityTenantId'), @($infinityClientId, 'costInfinityClientId'))) {
        if (-not [guid]::TryParse($pair[0], [ref] $parsedGuid) -or $parsedGuid -eq [guid]::Empty) {
            throw "$($pair[1]) must be a nonzero GUID."
        }
    }
    if ($infinityScope -notmatch '^/subscriptions/[0-9A-Fa-f-]{36}(/resourceGroups/[A-Za-z0-9._()-]+)?$') {
        throw 'costInfinityScope must be /subscriptions/<id> or /subscriptions/<id>/resourceGroups/<name>.'
    }
    if ($null -eq $CostInfinityClientSecret -and $env:AI_OBSERVABILITY_COST_CLIENT_SECRET) {
        $CostInfinityClientSecret = ConvertTo-SecureString -String $env:AI_OBSERVABILITY_COST_CLIENT_SECRET -AsPlainText -Force
    }
    # Bicep cannot create a client secret, so without a supplied one this script creates it for the
    # Bicep-created application, using your own Azure CLI sign-in. It never leaves this process.
    if ($null -ne $CostInfinityClientSecret -and $CostInfinityClientSecret.Length -gt 0) {
        $infinitySecret = [System.Net.NetworkCredential]::new('', $CostInfinityClientSecret).Password
    }
    $infinityEnabled = $true
    $files['azure-ai-costs-infinity.json'] = 'infinity'
    if ($DashboardConfiguration.Contains('enableCostInfinityAlert')) {
        $infinityAlertEnabled = [bool]$DashboardConfiguration.enableCostInfinityAlert
    }
    foreach ($setting in @(
        @('costInfinityAlertIntervalMinutes', 5, 1440),
        @('costInfinityAlertPendingMinutes', 0, 1440)
    )) {
        if ($DashboardConfiguration.Contains($setting[0])) {
            $minutes = 0
            if (-not [int]::TryParse([string]$DashboardConfiguration[$setting[0]], [ref] $minutes) -or $minutes -lt $setting[1] -or $minutes -gt $setting[2]) {
                throw "$($setting[0]) must be a whole number between $($setting[1]) and $($setting[2])."
            }
            if ($setting[0] -eq 'costInfinityAlertIntervalMinutes') { $infinityAlertIntervalMinutes = $minutes } else { $infinityAlertPendingMinutes = $minutes }
        }
    }
}
$infinityAlertEnabled = $infinityAlertEnabled -and $infinityEnabled

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
    $content = [IO.File]::ReadAllText($path).Replace('${DS_AZURE_MONITOR}', $sourceUid).Replace('${DS_COST_INFINITY}', $infinityUid)
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
        'infinity' { @{ costScope = $infinityScope } }
        'business' {
            $values = @{
                workspaceResourceId = $DashboardConfiguration.telemetryWorkspaceResourceId
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

$availableDashboardUids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in $prepared) {
    [void]$availableDashboardUids.Add([string]$item.dashboard.uid)
}
foreach ($item in $prepared) {
    if ($item.dashboard.Contains('links')) {
        $item.dashboard['links'] = @($item.dashboard.links | Where-Object {
            $match = [regex]::Match([string]$_.url, '^/d/([^/]+)/')
            -not $match.Success -or $availableDashboardUids.Contains($match.Groups[1].Value)
        })
    }
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

function Assert-OwnedDataSource {
    param($Existing, [string] $Uid, [string] $Name, [string] $Type)
    if ($null -eq $Existing) {
        return
    }
    if (-not $Existing.Contains('type') -or
        $Existing.type -ne $Type -or
        -not $Existing.Contains('name') -or
        $Existing.name -ne $Name -or
        -not $Existing.Contains('jsonData') -or
        $null -eq $Existing.jsonData -or
        -not $Existing.jsonData.Contains('aiObservabilityOwner') -or
        $Existing.jsonData.aiObservabilityOwner -ne $owner -or
        ($Existing.Contains('readOnly') -and $Existing.readOnly) -or
        -not $Existing.Contains('id') -or
        -not $Existing.Contains('version')) {
        throw "Grafana data source '$Uid' already exists but is not managed by this Bicep deployment. Resolve the ownership conflict before rerunning."
    }
}

function Save-DataSource {
    param($Existing, [hashtable] $Source)
    if ($null -eq $Existing) {
        [void](Invoke-GrafanaApi -Method 'Post' -Path '/api/datasources' -Body $Source)
    }
    else {
        $Source['id'] = $Existing.id
        $Source['version'] = $Existing.version
        [void](Invoke-GrafanaApi -Method 'Put' -Path "/api/datasources/uid/$($Source.uid)" -Body $Source)
    }
}

$existingSource = Invoke-GrafanaApi -Method 'Get' -Path "/api/datasources/uid/$sourceUid" -AllowNotFound
Assert-OwnedDataSource -Existing $existingSource -Uid $sourceUid -Name $sourceName -Type 'grafana-azure-monitor-datasource'
$existingInfinitySource = $null
if ($infinityEnabled) {
    $plugin = Invoke-GrafanaApi -Method 'Get' -Path "/api/plugins/$infinityPluginId/settings" -AllowNotFound
    if ($null -eq $plugin) {
        throw "The Infinity plugin ($infinityPluginId) is not installed on this Grafana workspace. Redeploy with enableCostInfinity = true, or install it from the Grafana plugin catalog, and rerun."
    }
    $existingInfinitySource = Invoke-GrafanaApi -Method 'Get' -Path "/api/datasources/uid/$infinityUid" -AllowNotFound
    Assert-OwnedDataSource -Existing $existingInfinitySource -Uid $infinityUid -Name $infinityName -Type $infinityPluginId
}
$existingAlertFolder = $null
$alertGroupPath = "/api/v1/provisioning/folder/$alertFolderUid/rule-groups/$([uri]::EscapeDataString($alertGroup))"
if ($infinityAlertEnabled) {
    $existingAlertFolder = Invoke-GrafanaApi -Method 'Get' -Path "/api/folders/$alertFolderUid" -AllowNotFound
    $existingAlertGroup = Invoke-GrafanaApi -Method 'Get' -Path $alertGroupPath -AllowNotFound
    if ($null -ne $existingAlertGroup) {
        foreach ($existingRule in @($existingAlertGroup.rules)) {
            if ($null -eq $existingRule -or -not $existingRule.Contains('labels') -or $null -eq $existingRule.labels -or
                -not $existingRule.labels.Contains('managed_by') -or $existingRule.labels.managed_by -ne $owner) {
                throw "Grafana alert rule group '$alertGroup' already exists but is not managed by this Bicep deployment. Resolve the ownership conflict before rerunning."
            }
        }
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

$retiredInfinityKeyIds = @()
if ($infinityEnabled -and $null -eq $infinitySecret) {
    # Mint before any Grafana write so a permission problem leaves nothing half-provisioned. Earlier
    # secrets with this name are removed only after Grafana holds the new one.
    $infinitySecretName = 'grafana-infinity'
    $listed = @(& az ad app credential list --id $infinityClientId --query "[?displayName=='$infinitySecretName'].keyId" --output tsv)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list the Infinity application credentials. Sign in with az login as an owner of that application, or supply -CostInfinityClientSecret.'
    }
    $retiredInfinityKeyIds = @($listed | Where-Object { $_ })
    $endDate = (Get-Date).ToUniversalTime().AddDays(180).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $infinitySecret = (& az ad app credential reset --id $infinityClientId --append --display-name $infinitySecretName --end-date $endDate --query password --output tsv) -join ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($infinitySecret)) {
        throw 'Could not create the Infinity client secret. Sign in with az login as an owner of the application, or supply -CostInfinityClientSecret.'
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
Save-DataSource -Existing $existingSource -Source $source
if ($infinityEnabled) {
    Save-DataSource -Existing $existingInfinitySource -Source @{
        uid = $infinityUid
        name = $infinityName
        type = $infinityPluginId
        access = 'proxy'
        jsonData = @{
            auth_method = 'oauth2'
            oauthPassThru = $false
            allowedHosts = @('https://management.azure.com')
            oauth2 = @{
                oauth2_type = 'client_credentials'
                client_id = $infinityClientId
                token_url = "https://login.microsoftonline.com/$infinityTenantId/oauth2/token"
                authStyle = 1
            }
            oauth2EndPointParamsName1 = 'resource'
            aiObservabilityOwner = $owner
        }
        secureJsonData = @{
            oauth2ClientSecret = $infinitySecret
            oauth2EndPointParamsValue1 = 'https://management.azure.com/'
        }
    }
    # Retire earlier secrets only after Grafana holds the new one.
    foreach ($keyId in $retiredInfinityKeyIds) {
        & az ad app credential delete --id $infinityClientId --key-id $keyId --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not delete the earlier Infinity client secret $keyId. Remove it with az ad app credential delete."
        }
    }
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

if ($infinityAlertEnabled) {
    $costTarget = $null
    foreach ($item in $prepared) {
        foreach ($panel in @($item.dashboard.panels)) {
            if ($panel.title -eq $alertCostPanelTitle -and $panel.targets) {
                $costTarget = $panel.targets[0]
            }
        }
    }
    if ($null -eq $costTarget) {
        throw "The Infinity dashboard has no '$alertCostPanelTitle' panel to base the alert on."
    }
    $queryModel = $costTarget | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $queryModel['refId'] = 'A'
    $queryModel['datasource'] = @{ type = $infinityPluginId; uid = $infinityUid }
    $queryModel['url'] = ([string]$queryModel.url).Replace('${costScope}', $infinityScope)
    $queryModel['root_selector'] = 'if .properties.rows then [{rows: (.properties.rows | length)}] else error("no_cost_rows_property") end'
    $queryModel['columns'] = @(@{ selector = 'rows'; text = 'rows'; type = 'number' })
    $queryModel['intervalMs'] = 1000
    $queryModel['maxDataPoints'] = 43200
    if ($null -eq $existingAlertFolder) {
        [void](Invoke-GrafanaApi -Method 'Post' -Path '/api/folders' -Body @{ uid = $alertFolderUid; title = $alertFolderTitle })
    }
    $expression = @{ type = '__expr__'; uid = '__expr__' }
    $rule = @{
        uid = $alertRuleUid
        title = 'Infinity cost data source cannot query Cost Management'
        ruleGroup = $alertGroup
        folderUID = $alertFolderUid
        orgID = 1
        condition = 'C'
        noDataState = 'OK'
        execErrState = 'Alerting'
        'for' = "${infinityAlertPendingMinutes}m"
        isPaused = $false
        labels = @{ component = 'cost-infinity'; severity = 'warning'; managed_by = $owner }
        annotations = @{
            summary = 'The AI observability cost panels cannot reach Cost Management'
            description = "The Infinity data source's Cost Management query failed. The usual cause is an expired, revoked or wrong service principal client secret (AADSTS7000215 or AADSTS7000222), or a removed Cost Management role. Rotate the secret as described in docs/costs.md. Grafana caches the access token, so a secret that has just expired can take up to an hour to surface."
        }
        data = @(
            @{ refId = 'A'; datasourceUid = $infinityUid; relativeTimeRange = @{ from = 600; to = 0 }; model = $queryModel },
            @{ refId = 'B'; datasourceUid = '__expr__'; relativeTimeRange = @{ from = 0; to = 0 }; model = @{
                refId = 'B'; type = 'reduce'; datasource = $expression; expression = 'A'; reducer = 'count'; settings = @{ mode = 'dropNN' }
            } },
            @{ refId = 'C'; datasourceUid = '__expr__'; relativeTimeRange = @{ from = 0; to = 0 }; model = @{
                refId = 'C'; type = 'threshold'; datasource = $expression; expression = 'B'
                conditions = @(@{ evaluator = @{ type = 'gt'; params = @(1000000000) } })
            } }
        )
    }
    [void](Invoke-GrafanaApi -Method 'Put' -Path $alertGroupPath -Body @{
        title = $alertGroup
        folderUid = $alertFolderUid
        interval = $infinityAlertIntervalMinutes * 60
        rules = @($rule)
    })
    Write-Host "Alert rule ready: $alertGroup (evaluates every $infinityAlertIntervalMinutes minutes, fires after $infinityAlertPendingMinutes more minutes of failure)"
}
