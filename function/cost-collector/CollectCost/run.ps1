param($Timer)

$ErrorActionPreference = 'Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'cost_collector.ps1') `
    -SubscriptionId $env:COST_SUBSCRIPTION_ID `
    -AccountIdsJson $env:COST_ACCOUNT_IDS `
    -IngestionEndpoint $env:COST_INGESTION_ENDPOINT `
    -RuleId $env:COST_DCR_IMMUTABLE_ID `
    -IdentityClientId $env:COST_IDENTITY_CLIENT_ID `
    -LookbackDays $env:COST_LOOKBACK_DAYS
