param(
    [Parameter(Mandatory)][string] $Scenario,
    [string] $NowUtc = ''
)

$ErrorActionPreference = 'Stop'
$env:IDENTITY_ENDPOINT = 'https://identity.example.invalid/token'
$env:IDENTITY_HEADER = 'mock-identity-header'
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
    param($Method, $Uri, $Headers, $ContentType, $Body)

    if ($Uri -like 'https://identity.example.invalid/*') {
        if ($Uri -notmatch 'api-version=2019-08-01' -or
            $Uri -notmatch 'client_id=00000000-0000-0000-0000-000000000003' -or
            $Headers['X-IDENTITY-HEADER'] -ne 'mock-identity-header') {
            throw 'Managed identity request omitted its version or identity.'
        }
        return [pscustomobject]@{ access_token = 'mock-token' }
    }

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
        if (($Scenario -eq 'throttle' -and -not $global:Throttled) -or $Scenario -eq 'retry-exhausted') {
            $global:Throttled = $true
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '5')
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-entity-retry-after', '19')
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock throttling', $response)
        }
        if ($Scenario -eq 'empty') {
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
        if ($Scenario -eq 'many' -or $Scenario -eq 'ingestion-error-late') {
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

        $next = $null
        if ($Scenario -eq 'pagination' -and -not $global:Paged -and $query.type -eq 'ActualCost') {
            $global:Paged = $true
            $next = $Uri + '&$skiptoken=next'
        }
        if ($Scenario -eq 'bad-next') {
            $next = 'https://evil.example.invalid/steal'
        }
        return [pscustomobject]@{
            properties = [pscustomobject]@{ columns = $columns; rows = $rows; nextLink = $next }
        }
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
$accountIds = ConvertTo-Json -InputObject @($account) -Compress
$success = $false
$message = ''
try {
    $null = & $collector `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -AccountIdsJson $accountIds `
        -IngestionEndpoint 'https://test.eastus-1.ingest.monitor.azure.com' `
        -RuleId 'dcr-00000000000000000000000000000000' `
        -IdentityClientId '00000000-0000-0000-0000-000000000003' `
        -LookbackDays 62
    $success = $true
}
catch {
    $message = $_.Exception.Message
}

$result = [ordered]@{
    Success      = $success
    Error        = $message
    CostRequests = @($global:CostRequests)
    Ingestions   = @($global:Ingestions)
    Sleeps       = @($global:Sleeps)
}
Write-Output ('RESULT=' + (ConvertTo-Json -InputObject $result -Depth 20 -Compress))
