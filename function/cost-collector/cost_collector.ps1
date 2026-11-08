[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $AccountIdsJson,

    [Parameter(Mandatory)]
    [string] $IngestionEndpoint,

    [Parameter(Mandatory)]
    [ValidatePattern('^dcr-[0-9a-fA-F]{32}$')]
    [string] $RuleId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $IdentityClientId,

    [ValidateSet('subscription', 'resourceGroup')]
    [string] $CostQueryScope = 'subscription',

    [ValidateRange(31, 366)]
    [int] $LookbackDays = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:LastCostRequest = $null
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-ManagedToken {
    param([string] $Resource)

    if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) {
        throw 'Azure Functions managed identity endpoint is unavailable.'
    }

    $uri = $env:IDENTITY_ENDPOINT + '?api-version=2019-08-01&resource=' +
        [uri]::EscapeDataString($Resource) + '&client_id=' + [uri]::EscapeDataString($IdentityClientId)
    $identityResponse = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
        Metadata            = 'true'
    }
    if (-not $identityResponse.access_token) {
        throw 'Azure Functions managed identity returned no access token.'
    }
    return $identityResponse.access_token
}

function Get-RetryDelay {
    param($Response, [int] $Attempt)

    $delay = [double][Math]::Min(60, [Math]::Pow(2, $Attempt))
    if ($null -ne $Response -and $null -ne $Response.Headers) {
        foreach ($header in $Response.Headers) {
            if ($header.Key -notmatch '^(?i:retry-after|x-ms-ratelimit-.*retry-after)$') {
                continue
            }
            foreach ($value in $header.Value) {
                $seconds = 0.0
                $date = [DateTimeOffset]::MinValue
                if ([double]::TryParse(
                    [string] $value,
                    [System.Globalization.NumberStyles]::Float,
                    $script:InvariantCulture,
                    [ref] $seconds
                )) {
                    $delay = [Math]::Max($delay, $seconds)
                }
                elseif ([DateTimeOffset]::TryParse([string] $value, [ref] $date)) {
                    $delay = [Math]::Max($delay, ($date - [DateTimeOffset]::UtcNow).TotalSeconds)
                }
            }
        }
    }
    return [int][Math]::Ceiling($delay)
}

function Invoke-AzurePost {
    param(
        [string] $Uri,
        [string] $Audience,
        [byte[]] $Body,
        [switch] $CostRequest
    )

    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        if ($CostRequest) {
            if ($null -ne $script:LastCostRequest) {
                $remaining = 16 - ([DateTime]::UtcNow - $script:LastCostRequest).TotalSeconds
                if ($remaining -gt 0) {
                    Start-Sleep -Seconds ([int][Math]::Ceiling($remaining))
                }
            }
            $script:LastCostRequest = [DateTime]::UtcNow
        }

        try {
            $token = Get-ManagedToken -Resource $Audience
            $headers = @{
                Authorization = "Bearer $token"
                ClientType    = 'AzureAIObservabilityCostCollector'
            }
            $statusCode = $null
            $result = Invoke-RestMethod -Method Post -Uri $Uri -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $Body `
                -MaximumRedirection 0 -StatusCodeVariable statusCode
            if ($CostRequest) {
                if ($statusCode -eq 204) {
                    return $null
                }
                if ($statusCode -ne 200) {
                    throw "Cost Management returned an unexpected HTTP status: $statusCode."
                }
                if ($null -eq $result -or
                    ($result -is [string] -and [string]::IsNullOrWhiteSpace($result))) {
                    throw 'Cost Management returned an empty HTTP 200 response.'
                }
            }
            elseif ($statusCode -ne 204) {
                throw "Logs Ingestion returned an unexpected HTTP status: $statusCode."
            }
            return $result
        }
        catch {
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
            $status = if ($null -ne $response) { [int] $response.StatusCode } else { 0 }
            $transient = $status -eq 408 -or $status -eq 429 -or $status -ge 500 -or
                ($status -eq 0 -and (
                    $_.Exception -is [System.Net.Http.HttpRequestException] -or
                    $_.Exception -is [System.Threading.Tasks.TaskCanceledException]
                ))
            if (-not $transient -or $attempt -eq 5) {
                throw
            }
            $delay = Get-RetryDelay -Response $response -Attempt $attempt
            if ($delay -gt 900) {
                throw "Azure requested a retry delay of $delay seconds; retry the failed job later."
            }
            Write-Warning "Azure request failed with status $status; retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CostRows {
    param(
        [string] $AccountId,
        [string] $CostType,
        [DateTime] $Start,
        [DateTime] $End,
        [string] $InitialUri
    )

    $query = @{
        type       = $CostType
        timeframe  = 'Custom'
        timePeriod = @{
            from = $Start.ToString("yyyy-MM-ddTHH:mm:ss'Z'", $script:InvariantCulture)
            to   = $End.ToString("yyyy-MM-ddTHH:mm:ss'Z'", $script:InvariantCulture)
        }
        dataset    = @{
            granularity = 'Daily'
            aggregation = @{
                totalCost = @{ name = 'PreTaxCost'; function = 'Sum' }
            }
            filter      = @{
                dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($AccountId) }
            }
        }
    }
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $query -Depth 10 -Compress))
    $next = $InitialUri
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedPath = ([uri] $InitialUri).AbsolutePath

    while ($next) {
        $uri = [uri] $next
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
            $uri.Port -ne 443 -or $uri.UserInfo -or $uri.AbsolutePath -ine $expectedPath) {
            throw 'Cost Management returned an unexpected continuation URL.'
        }
        if (-not $seen.Add($next)) {
            throw 'Cost Management returned a repeated continuation URL.'
        }

        $result = Invoke-AzurePost -Uri $next -Audience 'https://management.azure.com/' `
            -Body $body -CostRequest
        if ($null -eq $result) {
            break
        }
        if ($null -eq $result.PSObject.Properties['properties'] -or $null -eq $result.properties) {
            throw 'Cost Management returned a response without query properties.'
        }

        $properties = $result.properties
        if ($null -eq $properties.PSObject.Properties['columns'] -or
            $null -eq $properties.PSObject.Properties['rows']) {
            throw 'Cost Management returned a response without columns or rows.'
        }
        if ($properties.columns -isnot [array] -or $properties.rows -isnot [array]) {
            throw 'Cost Management returned columns or rows that are not arrays.'
        }
        $indexes = @{}
        for ($index = 0; $index -lt $properties.columns.Count; $index++) {
            $column = $properties.columns[$index]
            if ($null -eq $column -or $null -eq $column.PSObject.Properties['name'] -or
                $column.name -isnot [string] -or [string]::IsNullOrWhiteSpace($column.name)) {
                throw 'Cost Management returned an invalid column name.'
            }
            if ($indexes.ContainsKey($column.name)) {
                throw 'Cost Management returned duplicate column names.'
            }
            $indexes[$column.name] = $index
        }
        foreach ($required in @('PreTaxCost', 'UsageDate', 'Currency')) {
            if (-not $indexes.ContainsKey($required)) {
                throw "Cost Management response is missing the $required column."
            }
        }

        foreach ($row in $properties.rows) {
            if ($row -isnot [array] -or $row.Count -ne $properties.columns.Count) {
                throw 'Cost Management returned a row with an unexpected number of columns.'
            }
            $usageDate = [DateTime]::ParseExact(
                [string] $row[$indexes['UsageDate']],
                'yyyyMMdd',
                $script:InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
            $currency = [string] $row[$indexes['Currency']]
            $cost = $row[$indexes['PreTaxCost']]
            if ($usageDate.Date -lt $Start.Date -or $usageDate.Date -gt $End.Date -or
                $currency -notmatch '^[A-Za-z]{3}$' -or
                $null -eq $cost -or $cost -is [bool]) {
                throw 'Cost Management returned an invalid date, currency, or cost.'
            }
            $amount = [Convert]::ToDecimal($cost, $script:InvariantCulture)
            [pscustomobject]@{
                AccountId = $AccountId
                CostType  = $CostType
                UsageDate = $usageDate
                Currency  = $currency.ToUpperInvariant()
                Cost      = $amount
            }
        }
        $nextProperty = $properties.PSObject.Properties['nextLink']
        $next = ''
        if ($null -ne $nextProperty -and $null -ne $nextProperty.Value) {
            if ($nextProperty.Value -isnot [string]) {
                throw 'Cost Management returned an invalid continuation URL.'
            }
            $next = $nextProperty.Value
        }
    }
}

function Send-CostRecords {
    param([object[]] $Records, [string] $Uri)

    $offset = 0
    $batchSize = 200
    while ($offset -lt $Records.Count) {
        $count = [Math]::Min($batchSize, $Records.Count - $offset)
        $batch = @($Records[$offset..($offset + $count - 1)])
        $json = ConvertTo-Json -InputObject $batch -Depth 10 -Compress
        $body = [Text.Encoding]::UTF8.GetBytes($json)
        if ($body.Length -gt 900000) {
            if ($count -eq 1) {
                throw 'A cost record exceeds the Logs Ingestion API payload limit.'
            }
            $batchSize = [Math]::Floor($count / 2)
            continue
        }
        $null = Invoke-AzurePost -Uri $Uri -Audience 'https://monitor.azure.com/' -Body $body
        $offset += $count
    }
}

$endpoint = [uri] $IngestionEndpoint
if ($endpoint.Scheme -ne 'https' -or $endpoint.Port -ne 443 -or $endpoint.UserInfo -or
    $endpoint.Host -notlike '*.ingest.monitor.azure.com' -or
    $endpoint.AbsolutePath -notin @('', '/') -or $endpoint.Query -or $endpoint.Fragment) {
    throw 'The Logs Ingestion endpoint must be an Azure public-cloud ingestion endpoint.'
}

$accounts = @(ConvertFrom-Json -InputObject $AccountIdsJson)
if ($accounts.Count -eq 0) {
    throw 'At least one monitored AI account is required.'
}
$accountPattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId) +
    '/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.CognitiveServices/accounts/[^/]+$'
$accountSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$accountScopes = @{}
$subscriptionScope = "https://management.azure.com/subscriptions/$SubscriptionId"
foreach ($account in $accounts) {
    if ($account -isnot [string]) {
        throw 'Monitored accounts must be unique AI account resource IDs in the configured subscription.'
    }
    $match = [regex]::Match($account, $accountPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success -or -not $accountSet.Add($account)) {
        throw 'Monitored accounts must be unique AI account resource IDs in the configured subscription.'
    }
    $scope = $subscriptionScope
    if ($CostQueryScope -eq 'resourceGroup') {
        $resourceGroup = $match.Groups['resourceGroup'].Value
        if ($resourceGroup -in @('.', '..') -or $resourceGroup -match '[\\%\x00-\x1f\x7f]') {
            throw 'The monitored account contains an invalid resource group name.'
        }
        $scope += '/resourceGroups/' + [uri]::EscapeDataString($resourceGroup)
    }
    $accountScopes[$account] = $scope
}

$now = (Get-Date).ToUniversalTime()
$windowStart = $now.Date.AddDays(1 - $LookbackDays)
$ingestionUri = $IngestionEndpoint.TrimEnd('/') +
    "/dataCollectionRules/$RuleId/streams/Custom-AICostSnapshot?api-version=2023-01-01"
$uniqueRows = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)

foreach ($account in $accounts) {
    $costUri = $accountScopes[$account] + '/providers/Microsoft.CostManagement/query?api-version=2025-03-01'
    foreach ($costType in @('ActualCost', 'AmortizedCost')) {
        # Leave a full-day margin inside Cost Management's calendar-month limit.
        for ($start = $windowStart; $start -le $now.Date; $start = $start.AddDays(27)) {
            $end = $start.AddDays(27).AddSeconds(-1)
            if ($end -gt $now) {
                $end = $now
            }
            foreach ($row in @(Get-CostRows -AccountId $account -CostType $costType `
                        -Start $start -End $end -InitialUri $costUri)) {
                $keyText = '{0}|{1}|{2}|{3}' -f $row.AccountId.ToLowerInvariant(),
                    $row.CostType, $row.UsageDate.ToString('yyyyMMdd', $script:InvariantCulture), $row.Currency
                $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($keyText)
                ))
                if ($uniqueRows.ContainsKey($key)) {
                    if ($uniqueRows[$key].Cost -ne $row.Cost) {
                        throw 'Cost Management returned conflicting totals for the same account, date, and currency.'
                    }
                    continue
                }
                $uniqueRows.Add($key, $row)
            }
        }
    }
}

$runId = [guid]::NewGuid().ToString()
$completedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fff'Z'", $script:InvariantCulture)
$records = [Collections.Generic.List[object]]::new()
foreach ($entry in $uniqueRows.GetEnumerator()) {
    $row = $entry.Value
    $records.Add([ordered]@{
        TimeGenerated = $completedAt
        RecordType    = 'Cost'
        RunId         = $runId
        RowKey        = $entry.Key
        CostType      = $row.CostType
        ResourceId    = $row.AccountId
        UsageDate     = $row.UsageDate.ToString("yyyy-MM-ddTHH:mm:ss'Z'", $script:InvariantCulture)
        Currency      = $row.Currency
        Cost          = $row.Cost
    })
}
Send-CostRecords -Records $records.ToArray() -Uri $ingestionUri

$marker = [ordered]@{
    TimeGenerated = $completedAt
    RecordType    = 'Complete'
    RunId         = $runId
    RowKey        = 'complete'
    ExpectedRows  = $records.Count
    WindowStart   = $windowStart.ToString("yyyy-MM-ddTHH:mm:ss'Z'", $script:InvariantCulture)
    WindowEnd     = $now.ToString("yyyy-MM-ddTHH:mm:ss'Z'", $script:InvariantCulture)
}
Send-CostRecords -Records @($marker) -Uri $ingestionUri
Write-Output "Cost snapshot submitted: $($records.Count) distinct rows. Azure billing data can arrive later."
