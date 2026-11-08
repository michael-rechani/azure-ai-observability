function Get-BicepParameter {
    param([hashtable] $Parameters, [string] $Name, $Default = $null)
    if (-not $Parameters.ContainsKey($Name)) {
        return $Default
    }
    if (-not $Parameters[$Name].ContainsKey('value')) {
        throw "Parameter '$Name' must have a resolved value; external references are not supported by this deployment helper."
    }
    return $Parameters[$Name].value
}

function Assert-RealGuid {
    param([string] $Value, [string] $Description)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Description must be a nonzero GUID."
    }
}

function Assert-TargetName {
    param([string] $Value, [string] $Description)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[/\\]' -or $Value -match '^(?i:replace-me|replace-with)') {
        throw "$Description must be a real resource name without path separators."
    }
}

function Test-BicepDeploymentParameters {
    param([hashtable] $Parameters, [string] $SubscriptionId)

    Assert-RealGuid $SubscriptionId 'Monitoring subscription ID'
    $adminId = Get-BicepParameter $Parameters 'grafanaAdminObjectId'
    Assert-RealGuid $adminId 'Grafana administrator object ID'
    $namePrefix = [string](Get-BicepParameter $Parameters 'namePrefix' 'ai-observe')
    if ($namePrefix -cnotmatch '^[a-z][a-z0-9-]{0,18}[a-z0-9]$') {
        throw 'namePrefix must be 2-20 lowercase letters, digits or hyphens, beginning with a letter and ending with a letter or digit.'
    }
    $email = [string](Get-BicepParameter $Parameters 'notificationEmail')
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -or $email -match '(?i)\.invalid$') {
        throw 'notificationEmail must be a real alert recipient.'
    }

    $accounts = @(Get-BicepParameter $Parameters 'monitoredAccounts' @())
    $workspaces = @(Get-BicepParameter $Parameters 'existingTelemetryWorkspaces' @())
    $accountIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $workspaceIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in $accounts) {
        Assert-RealGuid $target.subscriptionId 'Account subscription ID'
        Assert-TargetName $target.resourceGroup 'Account resource group'
        if ($target.resourceGroup -in @('.', '..') -or $target.resourceGroup -match '[\\%?#\x00-\x1f\x7f]') {
            throw 'Account resource group cannot contain path traversal, URI delimiters, backslashes, or control characters.'
        }
        Assert-TargetName $target.name 'Account name'
        $id = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($target.name)"
        if (-not $accountIds.Add($id)) {
            throw "Monitored account is listed more than once: $id"
        }
        foreach ($deployment in @($target.ptuDeployments)) {
            Assert-TargetName $deployment 'PTU deployment name'
        }
    }
    foreach ($target in $workspaces) {
        Assert-RealGuid $target.subscriptionId 'Telemetry workspace subscription ID'
        Assert-TargetName $target.resourceGroup 'Telemetry workspace resource group'
        Assert-TargetName $target.name 'Telemetry workspace name'
        $id = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.name)"
        if (-not $workspaceIds.Add($id)) {
            throw "Telemetry workspace is listed more than once: $id"
        }
    }

    foreach ($parameterName in @('grafanaViewerPrincipals', 'telemetryPublisherPrincipals')) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($principal in @(Get-BicepParameter $Parameters $parameterName @())) {
            Assert-RealGuid $principal.principalId "$parameterName principal ID"
            if ($principal.principalType -cnotin @('User', 'Group', 'ServicePrincipal')) {
                throw "$parameterName principalType must be User, Group, or ServicePrincipal."
            }
            if (-not $seen.Add($principal.principalId)) {
                throw "$parameterName contains a duplicate principal."
            }
        }
    }

    foreach ($parameterName in @('foundryDashboardAccount', 'ptuDashboardAccount')) {
        $target = Get-BicepParameter $Parameters $parameterName
        if ($null -eq $target) {
            continue
        }
        Assert-RealGuid $target.subscriptionId "$parameterName subscription ID"
        Assert-TargetName $target.resourceGroup "$parameterName resource group"
        Assert-TargetName $target.name "$parameterName account"
        if ($target.region -notmatch '^[A-Za-z0-9-]+$' -or $target.deployment -notmatch '^([A-Za-z0-9_.-]+|\*)$' -or $target.deployment -match '^(?i:replace-me|replace-with)') {
            throw "$parameterName needs a real Azure region and a deployment name or *."
        }
        $id = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($target.name)"
        if (-not $accountIds.Contains($id)) {
            throw "$parameterName must reference an account in monitoredAccounts."
        }
    }

    $telemetryWorkspace = [string](Get-BicepParameter $Parameters 'dashboardTelemetryWorkspaceResourceId' '')
    if ($telemetryWorkspace -and -not $workspaceIds.Contains($telemetryWorkspace)) {
        throw 'dashboardTelemetryWorkspaceResourceId must identify an entry in existingTelemetryWorkspaces; leave it empty to use the new workspace.'
    }

    $enableCost = [bool](Get-BicepParameter $Parameters 'enableCostPipeline' $false)
    $budget = [int](Get-BicepParameter $Parameters 'monthlyAiCostBudgetAmount' 0)
    $lookback = [int](Get-BicepParameter $Parameters 'costLookbackDays' 90)
    $costScope = [string](Get-BicepParameter $Parameters 'costQueryScope' 'subscription')
    $collectorMode = [string](Get-BicepParameter $Parameters 'costCollectorMode' 'githubOidc')
    $githubSubject = [string](Get-BicepParameter $Parameters 'costGithubOidcSubject' '')
    if ($collectorMode -cnotin @('function', 'githubOidc')) {
        throw 'costCollectorMode must be function or githubOidc.'
    }
    if ($enableCost -and $collectorMode -eq 'githubOidc' -and
        $githubSubject -cnotmatch '^repo:[A-Za-z0-9_.@-]+/[A-Za-z0-9_.@-]+:ref:refs/heads/main$') {
        throw 'costGithubOidcSubject must be the exact GitHub repository main-branch subject.'
    }
    if ($costScope -cnotin @('subscription', 'resourceGroup', 'resourceGroupManaged')) {
        throw 'costQueryScope must be subscription, resourceGroup, or resourceGroupManaged.'
    }
    if ($lookback -lt 31 -or $lookback -gt 366) {
        throw 'costLookbackDays must be between 31 and 366.'
    }
    if ($budget -lt 0) {
        throw 'monthlyAiCostBudgetAmount cannot be negative.'
    }
    if ($enableCost -or $budget -gt 0) {
        if ($accounts.Count -eq 0) {
            throw 'Configure at least one monitored account before enabling cost collection or the budget.'
        }
        foreach ($target in $accounts) {
            if ($target.subscriptionId -ine $SubscriptionId) {
                throw 'Cost collection and the account budget require all monitored accounts to be in the monitoring subscription. Deploy separate stacks for other subscriptions.'
            }
        }
    }
    if ($enableCost -and ($accounts.Count * [Math]::Ceiling($lookback / 27.0) * 2 * 16) -gt 1800) {
        throw 'The account count and lookback require more than 30 minutes of minimum API pacing. Reduce either or split the deployment.'
    }
    if ($budget -gt 0) {
        $startText = [string](Get-BicepParameter $Parameters 'costBudgetStartDate' '')
        $endText = [string](Get-BicepParameter $Parameters 'costBudgetEndDate' '')
        $start = [datetime]::MinValue
        $end = [datetime]::MinValue
        $format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $style = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [datetime]::TryParseExact($startText, $format, $culture, $style, [ref] $start) -or
            -not [datetime]::TryParseExact($endText, $format, $culture, $style, [ref] $end) -or
            $start.Day -ne 1 -or $start.TimeOfDay -ne [timespan]::Zero -or
            $end.TimeOfDay -ne [timespan]::Zero -or $end -le $start) {
            throw 'The monthly budget requires UTC start/end dates in YYYY-MM-DDT00:00:00Z format, starting on the first of a month and ending later.'
        }
    }
}
