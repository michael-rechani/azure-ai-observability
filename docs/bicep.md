# Bicep deployment

The Bicep path deploys Azure monitoring resources, scoped access, alerts, the Grafana data source and dashboards, an optional budget, and one opt-in billed-cost route. Foundry, PTU, agent-trace and capacity panels are read by Grafana's managed identity with no secret. Billed cost needs the opt-in route (see [billed cost options](costs.md)). Nothing here involves GitHub. **Terraform and Python are not required.** Bicep creates the Azure resources; the PowerShell 7 helper uses the Grafana data-plane API.

The complete Bicep deployment was run live in an isolated Lab subscription: Grafana, Log Analytics, alerts and the native data sources and dashboards deployed, and Grafana's managed identity read live Foundry metrics, Resource Graph inventory and agent traces. That run predates the removal of the optional cost pipeline, so confirm your own deployment. Start in nonproduction, review expected charges, and complete the [acceptance checklist](setup.md#acceptance-checklist). The templates monitor existing Foundry/OpenAI accounts; they do not create or resize model deployments, instrument applications, or run evaluations.

## Prerequisites

- Azure CLI 2.60+ with Bicep installed (`az bicep install`) and PowerShell 7. The helper runs on the machine with the Azure CLI credentials.
- An existing monitoring resource group in a region supporting Managed Grafana Standard and Application Insights.
- Permission to create resources and role assignments in the monitoring resource group and each selected account/workspace. The opt-in Infinity route also creates a Microsoft Entra app registration and a custom role in code, so it requires **permission to create app registrations** (for example Application Developer, Application Administrator or Global Administrator) and, at the chosen scope, permission to write role definitions and assignments (Owner or User Access Administrator). At the default `subscription` scope that is subscription deployment plus role-definition and role-assignment write/delete at subscription scope; the `resourceGroupManaged` scope needs the same in each monitored group. A budget requires permission to create subscription budgets.
- Bicep 0.36.1 or later for the Infinity route (the Azure CLI's bundled Bicep is enough on current versions). `infra\bicepconfig.json` enables the Microsoft Graph Bicep extension, which Bicep restores from the Microsoft Container Registry on first build, so that build needs network access.
- The signed-in identity must receive **Grafana Admin**. Use its Entra object ID for `grafanaAdminObjectId`, or grant it access separately. Azure subscription permissions alone are not Grafana data-plane access.
- Network access to Azure management APIs and the public Grafana endpoint. This starter does not implement sovereign-cloud endpoints or private networking.

**Choose Terraform or Bicep for a given deployment.** They do not share ownership or state, and some resource names differ. Applying both to the same environment is not migration and can create duplicates, conflicting role assignments, unexpected costs, or destructive changes.

## Configure

Copy `infra/main.example.bicepparam` to `infra/main.local.bicepparam` in the same directory. Replace the sample subscription IDs, account/resource-group names, regions, Grafana admin object ID, email, and deployment names. The file is ignored by Git; do not commit real local configuration, tokens, or credentials.

- `monitoredAccounts`: existing account subscription, resource group and name. Include actual **provisioned deployment names** in `ptuDeployments`; use `[]` for accounts without PTUs. Set `enablePtuAlerts = false` until you have checked [metric definitions and dimensions](setup.md#metric-discovery).
- `foundryDashboardAccount` and `ptuDashboardAccount`: initial dashboard controls. Each must reference an account in `monitoredAccounts`. Use the account's actual region, which may differ from the monitoring region. Use `'*'` or a real deployment name; the PTU dashboard is clearest with an explicit PTU deployment.
- `existingTelemetryWorkspaces`: existing workspaces to which Grafana needs Log Analytics Reader. Set `dashboardTelemetryWorkspaceResourceId` to one of their full ARM IDs to read agent telemetry there, or leave it empty to use the new workspace. The Business overview reads the same workspace.
- `grafanaViewerPrincipals`: optional Entra users/groups/service principals for read-only access. Specify `principalId` as an **object ID** and `principalType` as `User`, `Group`, or `ServicePrincipal`. Viewer is not a data-isolation boundary; see [business-user access](terraform.md#business-user-access).
- `telemetryPublisherPrincipals`: optional existing Entra principals granted Monitoring Metrics Publisher on the new Application Insights resource. This enables authenticated ingestion but does not instrument the application or attach Foundry tracing.
- `enableAgentAlerts`: optional failure-rate, p95 latency, and heartbeat alerts scoped to the **new monitoring workspace**. Enable only after verifying your actual telemetry schema and guaranteed traffic; an existing dashboard telemetry workspace does not change alert scope. See [alerting](alerts.md).

For example:

```bicep
param grafanaViewerPrincipals = [
  {
    principalId: '00000000-0000-0000-0000-000000000000' // Replace with the group's object ID.
    principalType: 'Group'
  }
]
param telemetryPublisherPrincipals = [
  {
    principalId: '00000000-0000-0000-0000-000000000000' // Replace with the application's object ID.
    principalType: 'ServicePrincipal'
  }
]
```

### Business overview and budget

Set `enableBusinessOverview = true` to also provision the Business overview dashboard (default `false`). It shows observed agent activity, failure rate and PTU signals side by side without calculating an overall health score, and it has no cost panels. It reads only the agent telemetry workspace (`dashboardTelemetryWorkspaceResourceId`, or the new monitoring workspace). It replaces the former `dashboardConfiguration.enableCostDashboard` switch; the cost pipeline parameters `enableCostPipeline`, `costQueryScope` and `costLookbackDays` no longer exist (see [migrating](costs.md#migrating-from-the-removed-cost-collector)).

For an optional monthly account-filtered budget, set a positive whole-number `monthlyAiCostBudgetAmount` in subscription billing currency and set `costBudgetStartDate` and `costBudgetEndDate` as UTC `YYYY-MM-DDT00:00:00Z` values. The start must be the first of a month and the end later. Tune `costBudgetThresholdPercent` (default 80). This is an alert, not a spending cap; costs may arrive late. At least one account is required, and **all monitored accounts must be in the monitoring subscription** whenever the budget is enabled (or the Infinity `resourceGroupManaged` scope is selected). Deploy separate stacks for other subscriptions. Without those features, Bicep can monitor accounts in other subscriptions when the deployer has access.

### Optional direct cost queries with Infinity

Set `enableCostInfinity = true` for the cheapest billed-cost path: Grafana queries the Cost Management Query API directly through the Infinity plugin. It adds no cluster or storage. **It is not secretless.** Infinity signs in as a service principal with a client secret, which Grafana stores and you must rotate. Read [the trade-offs](costs.md#direct-cost-management-queries-with-infinity-opt-in) first: the secret, a shared identity that any query editor inherits, API throttling and the 31-day daily limit.

Nothing is created by hand. Set:

```bicep
param enableCostInfinity = true
param costInfinityScope = 'subscription' // Or 'resourceGroupManaged' (needs monitoredAccounts)
```

The template creates, in code:

- a single-tenant **Microsoft Entra app registration and service principal** named `<namePrefix>-cost-query` (Microsoft Graph Bicep extension), with the deployer as its owner so the helper can mint secrets as that user;
- a **custom role whose only action is `Microsoft.CostManagement/query/read`**, assigned to the principal on the subscription or, for `resourceGroupManaged`, on each monitored resource group. The built-in Cost Management Reader role is not used, because it also includes `Microsoft.Support/*`;
- the Infinity plugin on the Grafana workspace (`grafanaPlugins`, a preview property).

**The secret is never a Bicep parameter or output.** The Graph extension cannot return secret text, so `scripts\provision_grafana.ps1` mints it with `az ad app credential reset --append` (180-day life) while signed in as the app's owner, stores it in the Infinity data source's secure data (uid `ai-observability-cost-infinity`), and then deletes the older `grafana-infinity` secrets on that app. It also imports the `azure-ai-costs-infinity` dashboard. To use a secret someone else created, pass `-CostInfinityClientSecret` (a `SecureString`) to `scripts\deploy_bicep.ps1` or set `AI_OBSERVABILITY_COST_CLIENT_SECRET`; the helper then mints and deletes nothing. `deploy_bicep.ps1` no longer stops when no secret is supplied. On a rerun the helper updates only a data source it created, which is how a rotated secret is applied; it refuses an unrelated data source with the same UID.

Limits specific to Microsoft Graph resources in Bicep:

- **Preview.** `-WhatIf` shows the role and the other Azure resources but marks the Graph resources unsupported, so the app registration is not previewed. Deployment stacks do not support them either.
- **Replication delay.** A first deployment can fail once while Entra replicates the new app and service principal. Rerun it.
- **Not removed with the resource group.** Setting the switch back to false, or deleting the group, leaves the app registration, its service principal and secrets, and the role assignments in place. See [Rotate or remove the secret](costs.md#rotate-or-remove-the-secret) for the cleanup commands.
- **Moving from the earlier manual setup:** see [Moving from the earlier manual setup](costs.md#moving-from-the-earlier-manual-setup). `costInfinityClientId` and `costInfinityServicePrincipalObjectId` are no longer parameters, and Bicep rejects them in a parameter file.

The helper also creates an alert rule, **Infinity cost data source cannot query Cost Management**, that fires when the cost query fails, for example after the secret expires. It is on by default; tune or disable it with `enableCostInfinityAlert`, `costInfinityAlertIntervalMinutes` (5-1440, default 60) and `costInfinityAlertPendingMinutes` (0-1440, default 60). You must add a Grafana contact point and a notification policy that routes `component = cost-infinity`, because Azure Managed Grafana's default contact point has no integration. The helper updates only a rule group it created (every rule labelled `managed_by = azure-ai-observability-bicep-v1`) and stops before any change if a group with the same name belongs to someone else. Setting `enableCostInfinityAlert` to false does not delete an existing rule group; remove it in Grafana. See [Get alerted when the secret fails](costs.md#get-alerted-when-the-secret-fails).

## Deploy and provision Grafana

Sign in and create the monitoring resource group if necessary. Creating the group is a real Azure change, even before what-if:

```powershell
az login
az account set --subscription "<subscription-id>"
az group create --name "<monitoring-rg>" --location "<region>"

pwsh -NoProfile -File .\scripts\deploy_bicep.ps1 -SubscriptionId "<subscription-id>" -ResourceGroup "<monitoring-rg>" -ParametersFile .\infra\main.local.bicepparam -WhatIf
# After reviewing the what-if output and charges:
pwsh -NoProfile -File .\scripts\deploy_bicep.ps1 -SubscriptionId "<subscription-id>" -ResourceGroup "<monitoring-rg>" -ParametersFile .\infra\main.local.bicepparam
```

The helper validates account/workspace inputs and pacing before deploying, compiles the parameters, and uses the checked-in `infra/main.bicep`. It provisions the Azure Monitor managed-identity data source and dashboards through Grafana's API. It acquires a short-lived Entra token for `https://dashboard.azure.com`, checks the endpoint, does not follow redirects, and does not print or save the token. Temporary compiled parameters are removed after the run. `-WhatIf` does not change Grafana data-plane resources; it does not preview those API changes.

Grafana Admin or managed-identity role assignments can take time to propagate. If an API call is rejected, verify the role and network access, wait, then rerun the same deployment. Azure resources may already have been created before a publishing or Grafana failure; a failed helper is not a rollback.

The helper marks resources it creates in Grafana. It refuses to overwrite an unrelated data source or dashboard with the same UID and does not force-update version conflicts. Managed dashboards are reconciled on rerun, so edit their checked-in JSON rather than relying on persistent Grafana UI edits. Review and resolve UID/ownership collisions explicitly.

## Lifecycle and removal

Bicep uses **incremental** Azure deployments: removing a principal or monitored group, setting an alert or cost feature to false, or setting the budget amount to zero does **not** delete resources created by a previous deployment. A budget can keep sending alerts, and removed Viewer/publisher or cost role assignments can remain effective. Explicitly review and remove the specific unwanted Azure resources and role assignments through Azure's management tools. Remove an obsolete managed cost role's assignments before deleting its role definition, after confirming neither is used elsewhere. Disabling a cost route also does not delete its Grafana dashboard or stored data. Preserve or delete data according to your retention requirements.

The helper updates its managed Grafana resources but does not delete them. Disabling the Business overview or a cost route does not remove its previously provisioned dashboard. Azure resources and dashboards have separate lifecycles; do not delete a resource group containing other workloads. For Terraform-managed resources, use the separate [Terraform lifecycle guidance](terraform.md#validation-and-lifecycle).
