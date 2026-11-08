param(
    [Parameter(Mandatory)][string] $Scenario,
    [string] $NowUtc = '',
    [string] $CostQueryScope = 'subscription',
    [switch] $UseTimer
)

$ErrorActionPreference = 'Stop'
$env:IDENTITY_ENDPOINT = 'https://identity.example.invalid/token'
$env:IDENTITY_HEADER = 'mock-identity-header'
$global:DataRequestUris = [Collections.Generic.List[string]]::new()
$global:CostRequests = [Collections.Generic.List[object]]::new()
$global:Ingestions = [Collections.Generic.List[object]]::new()
$global:Sleeps = [Collections.Generic.List[int]]::new()
$global:Throttled = $false
$global:Paged = $false
$global:CostBatchCount = 0

if ($NowUtc) {
    $global:MockNow = [DateTime]::ParseExact(
        $NowUtc,
        "yyyy-MM-ddTHH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal
    )
    function global:Get-Date {
        return $global:MockNow
    }
}

function global:Start-Sleep {
    param([int] $Seconds)
    $global:Sleeps.Add($Seconds)
}

function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, [string] $StatusCodeVariable,
        [Nullable[int]] $MaximumRedirection)

    if ($Uri -like 'https://identity.example.invalid/*') {
        if ($Uri -notmatch 'api-version=2019-08-01' -or
            $Uri -notmatch 'client_id=00000000-0000-0000-0000-000000000003' -or
            $Headers['X-IDENTITY-HEADER'] -ne 'mock-identity-header') {
            throw 'Managed identity request omitted its version or identity.'
        }
        return [pscustomobject]@{ access_token = 'mock-token' }
    }

    if ($StatusCodeVariable) {
        if ($null -eq $MaximumRedirection -or $MaximumRedirection -ne 0) {
            throw 'Azure requests must not automatically follow redirects.'
        }
        $status = if ($Scenario -eq 'empty' -and $Uri -like 'https://management.azure.com/*') {
            204
        }
        elseif ($Scenario -eq 'unexpected-status' -and $Uri -like 'https://management.azure.com/*') {
            202
        }
        elseif ($Scenario -match '^ingestion-unexpected-(200|202|206)$' -and
            $Uri -like 'https://*.ingest.monitor.azure.com/*') {
            [int] $Matches[1]
        }
        elseif ($Scenario -match '^marker-unexpected-(200|202|206)$' -and
            $Uri -like 'https://*.ingest.monitor.azure.com/*') {
            $unexpectedStatus = [int] $Matches[1]
            $records = @(ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($Body)))
            if ($records[0].RecordType -eq 'Complete') { $unexpectedStatus } else { 204 }
        }
        elseif ($Uri -like 'https://*.ingest.monitor.azure.com/*') {
            204
        }
        else {
            200
        }
        Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1
    }

    $global:DataRequestUris.Add([string] $Uri)
    if ($Headers.Authorization -ne 'Bearer mock-token') {
        throw 'Azure request omitted the managed identity bearer token.'
    }
    $text = [Text.Encoding]::UTF8.GetString($Body)
    if ($Uri -like 'https://management.azure.com/*') {
        $query = ConvertFrom-Json $text
        $global:CostRequests.Add([pscustomobject]@{ Uri = $Uri; Query = $query })
        if ($Scenario -eq 'cost-error') {
            throw 'Mock Cost Management failure.'
        }
        if ($Scenario -eq 'denied-resource-group' -and $Uri -like '*/resourceGroups/denied/*') {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock resource group denial', $response)
        }
        if ($Scenario -match '^client-error-(400|401|403|404)$') {
            $statusCode = [int] $Matches[1]
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $statusCode)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock client error', $response)
        }
        if ($Scenario -match '^transient-http-(408|500)$') {
            $statusCode = [int] $Matches[1]
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $statusCode)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock transient error', $response)
        }
        if ($Scenario -eq 'transient-network') {
            throw [System.Net.Http.HttpRequestException]::new('Mock network error')
        }
        if (($Scenario -eq 'throttle' -and -not $global:Throttled) -or $Scenario -eq 'retry-exhausted') {
            $global:Throttled = $true
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '5')
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-entity-retry-after', '19')
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock throttling', $response)
        }
        if ($Scenario -eq 'empty' -or $Scenario -eq 'empty-200') {
            return ''
        }
        if ($Scenario -eq 'json-null') {
            return $null
        }

        $date = ([DateTime] $query.timePeriod.from).ToUniversalTime()
        if ($Uri.Contains('$skiptoken=')) {
            $date = $date.AddDays(1)
        }
        $dateNumber = [int] $date.ToString('yyyyMMdd')
        $columns = @(
            [pscustomobject]@{ name = 'Currency'; type = 'String' },
            [pscustomobject]@{ name = 'UsageDate'; type = 'Number' },
            [pscustomobject]@{ name = 'PreTaxCost'; type = 'Number' }
        )
        $rows = @()
        if ($Scenario -eq 'empty-rows') {
            $rows = @()
        }
        elseif ($Scenario -eq 'many' -or $Scenario -eq 'ingestion-error-late') {
            for ($i = 0; $i -lt 450; $i++) {
                $currency = '{0}{1}{2}' -f [char][int](65 + [Math]::Floor($i / 676)),
                    [char][int](65 + [Math]::Floor(($i % 676) / 26)), [char][int](65 + ($i % 26))
                $rows += ,@($currency, $dateNumber, -12.34)
            }
        }
        else {
            $rows += ,@('usd', $dateNumber, -12.34)
        }
        if ($Scenario -eq 'duplicate' -or $Scenario -eq 'conflict') {
            $amount = if ($Scenario -eq 'duplicate') { -12.34 } else { -13.34 }
            $rows += ,@('USD', $dateNumber, $amount)
        }
        if ($Scenario -eq 'currencies') {
            $rows += ,@('EUR', $dateNumber, 3.25)
        }
        if ($Scenario -eq 'bad-columns') {
            $columns = @($columns | Where-Object name -ne 'Currency')
        }
        switch ($Scenario) {
            'null-rows' { $rows = $null }
            'scalar-rows' { $rows = 'invalid' }
            'object-rows' { $rows = [pscustomobject]@{ value = 'invalid' } }
            'non-array-row' { $rows = @('invalid') }
            'boolean-cost' { $rows = @(,@('usd', $dateNumber, $true)) }
            'boolean-zero-cost' { $rows = @(,@('usd', $dateNumber, $false)) }
            'integer-cost' { $rows = @(,@('usd', $dateNumber, -12)) }
            'zero-cost' { $rows = @(,@('usd', $dateNumber, 0)) }
            'numeric-string-cost' { $rows = @(,@('usd', $dateNumber, '12.34')) }
            'duplicate-cost-column' {
                $columns += [pscustomobject]@{ name = 'PreTaxCost'; type = 'Number' }
                $rows = @(,@('usd', $dateNumber, -12.34, 42))
            }
            'duplicate-cost-column-case' {
                $columns += [pscustomobject]@{ name = 'pretaxcost'; type = 'Number' }
                $rows = @(,@('usd', $dateNumber, -12.34, 42))
            }
            'duplicate-currency-column' {
                $columns += [pscustomobject]@{ name = 'Currency'; type = 'String' }
                $rows = @(,@('usd', $dateNumber, -12.34, 'EUR'))
            }
            'duplicate-date-column' {
                $columns += [pscustomobject]@{ name = 'UsageDate'; type = 'Number' }
                $rows = @(,@('usd', $dateNumber, -12.34, $dateNumber))
            }
            'duplicate-column-after-page' {
                if ($Uri.Contains('$skiptoken=')) {
                    $columns += [pscustomobject]@{ name = 'PreTaxCost'; type = 'Number' }
                    $rows = @(,@('usd', $dateNumber, -12.34, 42))
                }
            }
            'null-column-name' { $columns[0] = [pscustomobject]@{ name = $null; type = 'String' } }
            'blank-column-name' { $columns[0] = [pscustomobject]@{ name = ' '; type = 'String' } }
            'numeric-column-name' { $columns[0] = [pscustomobject]@{ name = 1; type = 'String' } }
            'null-rows-after-page' {
                if ($Uri.Contains('$skiptoken=')) { $rows = $null }
            }
            'null-columns' { $columns = $null }
            'scalar-columns' { $columns = 'invalid' }
        }

        $next = $null
        if ($Scenario -in @('pagination', 'null-rows-after-page', 'duplicate-column-after-page',
                'invalid-next-array-after-page') -and
            -not $global:Paged -and $query.type -eq 'ActualCost') {
            $global:Paged = $true
            $next = $Uri + '&$skiptoken=next'
        }
        switch ($Scenario) {
            'invalid-next-empty-array' { $next = @() }
            'invalid-next-empty-object' { $next = [pscustomobject]@{} }
            'invalid-next-single-array' {
                if (-not $Uri.Contains('$skiptoken=')) { $next = @($Uri + '&$skiptoken=next') }
            }
            'invalid-next-boolean' { $next = $false }
            'invalid-next-number' { $next = 0 }
            'invalid-next-array-after-page' {
                if ($Uri.Contains('$skiptoken=')) { $next = @() }
            }
            'empty-next-string' { $next = '' }
            'bad-next' {
                $next = 'https://evil.example.invalid/steal'
            }
            'bad-next-host-suffix' {
                $next = $Uri.Replace('management.azure.com', 'management.azure.com.evil.example.invalid')
            }
            'bad-next-http' {
                $next = $Uri.Replace('https://', 'http://')
            }
            'bad-next-port' {
                $next = $Uri.Replace('management.azure.com', 'management.azure.com:8443')
            }
            'bad-next-userinfo' {
                $next = $Uri.Replace('management.azure.com', 'user@management.azure.com')
            }
            'bad-next-path' {
                $next = $Uri.Replace('/query?', '/exports?')
            }
            'bad-next-other-group' {
                $next = $Uri.Replace('/resourceGroups/ai/', '/resourceGroups/other/')
            }
            'bad-next-subscription' {
                $next = $Uri.Replace('/resourceGroups/ai/', '/')
            }
            'bad-next-repeat' {
                $next = $Uri
            }
            'bad-next-cycle' {
                $next = if ($Uri.Contains('$skiptoken=')) {
                    $Uri.Replace('&$skiptoken=cycle', '')
                }
                else {
                    $Uri + '&$skiptoken=cycle'
                }
            }
        }
        $properties = [ordered]@{ columns = $columns; rows = $rows }
        if ($Scenario -ne 'missing-next-property') {
            $properties.nextLink = $next
        }
        $result = [pscustomobject]@{ properties = [pscustomobject] $properties }
        if ($Scenario -like 'invalid-next-*') {
            $json = ConvertTo-Json -InputObject $result -Depth 10 -Compress
            return ConvertFrom-Json -InputObject $json
        }
        return $result
    }

    if ($Uri -like 'https://*.ingest.monitor.azure.com/*') {
        $records = @(ConvertFrom-Json -InputObject $text)
        $global:Ingestions.Add([pscustomobject]@{ Bytes = $Body.Length; Records = $records })
        if ($records[0].RecordType -eq 'Cost') {
            $global:CostBatchCount++
            if ($Scenario -eq 'ingestion-error' -or
                ($Scenario -eq 'ingestion-error-late' -and $global:CostBatchCount -eq 2)) {
                throw 'Mock Logs Ingestion failure.'
            }
        }
        return $null
    }
    throw "Unexpected mock request: $Uri"
}

$repo = Split-Path -Parent $PSScriptRoot
$collector = Join-Path (Join-Path (Join-Path $repo 'function') 'cost-collector') 'cost_collector.ps1'
$account = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/example'
$accounts = @($account)
switch ($Scenario) {
    'multiple-resource-groups' {
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/AI/').Replace('/accounts/example', '/accounts/second')
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/rg (east)/').Replace('/accounts/example', '/accounts/third')
    }
    'denied-resource-group' {
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/denied/').Replace('/accounts/example', '/accounts/second')
    }
    'invalid-group-dot' {
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/../').Replace('/accounts/example', '/accounts/second')
    }
    'invalid-group-encoded' {
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/%2e%2e/').Replace('/accounts/example', '/accounts/second')
    }
    'invalid-group-backslash' {
        $accounts += $account.Replace('/resourceGroups/ai/', '/resourceGroups/invalid\group/').Replace('/accounts/example', '/accounts/second')
    }
}
$accountIds = ConvertTo-Json -InputObject $accounts -Compress
$success = $false
$message = ''
try {
    $parameters = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000000'
        AccountIdsJson = $accountIds
        IngestionEndpoint = 'https://test.eastus-1.ingest.monitor.azure.com'
        RuleId = 'dcr-00000000000000000000000000000000'
        IdentityClientId = '00000000-0000-0000-0000-000000000003'
        LookbackDays = 62
    }
    if ($UseTimer) {
        $env:COST_SUBSCRIPTION_ID = $parameters.SubscriptionId
        $env:COST_ACCOUNT_IDS = $parameters.AccountIdsJson
        $env:COST_INGESTION_ENDPOINT = $parameters.IngestionEndpoint
        $env:COST_DCR_IMMUTABLE_ID = $parameters.RuleId
        $env:COST_IDENTITY_CLIENT_ID = $parameters.IdentityClientId
        $env:COST_LOOKBACK_DAYS = $parameters.LookbackDays
        if ($CostQueryScope -eq '__missing__') {
            Remove-Item Env:\COST_QUERY_SCOPE -ErrorAction SilentlyContinue
        }
        else {
            $env:COST_QUERY_SCOPE = $CostQueryScope
        }
        $timer = Join-Path (Join-Path (Split-Path -Parent $collector) 'CollectCost') 'run.ps1'
        $null = & $timer -Timer $null
    }
    else {
        $parameters.CostQueryScope = $CostQueryScope
        $null = & $collector @parameters
    }
    $success = $true
}
catch {
    $message = $_.Exception.Message
}

$result = [ordered]@{
    Success         = $success
    Error           = $message
    DataRequestUris = @($global:DataRequestUris)
    CostRequests    = @($global:CostRequests)
    Ingestions      = @($global:Ingestions)
    Sleeps          = @($global:Sleeps)
}
Write-Output ('RESULT=' + (ConvertTo-Json -InputObject $result -Depth 20 -Compress))
