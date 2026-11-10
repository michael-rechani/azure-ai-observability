# Azure AI cost collection

There are three opt-in ways to get billed cost into Grafana. None is on by default, and they can coexist.

| | [Direct query with Infinity](#direct-cost-management-queries-with-infinity-opt-in) | [Cost Management export to Azure Data Explorer](#cost-management-export-to-azure-data-explorer-no-function) | [Function collector](#deploy-the-optional-function-collector) |
| --- | --- | --- | --- |
| Switch | `enableCostInfinity` (Bicep), `enable_cost_infinity` (Terraform) | `enableCostExport`, `enable_cost_export` | `enableCostPipeline`, `enable_cost_pipeline` |
| Moving parts | The Infinity plugin on Grafana, one service principal and its role | A Cost Management export, a private storage account and an Azure Data Explorer (ADX) cluster | An Azure Function, a storage account, a data collection rule and a Log Analytics table |
| Code you own | None | None | PowerShell collector |
| Secrets | **A rotating client secret** stored in Grafana (and in Terraform state) | None | None |
| Standing cost | None beyond Grafana itself | **About $95 per month at retail for the smallest ADX cluster, plus storage.** Approximate; confirm in the Azure pricing calculator | Pennies |
| History and limits | Live Cost Management Query API: throttled (HTTP 429), daily data capped at 31 days per query | Exported files, full history from the export start date | Rolling window you choose (90 days by default) |
| Visibility | Anyone who can edit queries on the Infinity data source inherits the principal's cost access | Whole-subscription cost rows are queryable by anyone who can edit queries on the ADX data source | Only the selected accounts are stored |
| Dashboard | `azure-ai-costs-infinity` | `azure-ai-costs-native` | `azure-ai-costs` and the business overview |

You can deploy a cost collector, a detailed Grafana cost dashboard, and a business overview using `enable_cost_pipeline` plus `enable_cost_dashboard` in [Terraform](terraform.md#optional-cost-pipeline), or `enableCostPipeline` in [Bicep](bicep.md#optional-cost-collection-and-budget). **Only billed cost needs a collector.** Foundry, PTU, agent-trace and capacity panels are read directly by Azure Managed Grafana's managed identity. Cost Management is different: no Grafana data source tested here can query it with that identity (see [Direct Grafana queries](#direct-grafana-queries-and-per-viewer-access)), so the optional pipeline runs an **Azure Function inside your subscription** that writes daily snapshots to Log Analytics. It uses a managed identity; no GitHub, external scheduler, app registration or client secret is involved. The overview shows collection status, actual cost by currency, observed agent activity, and PTU signals without combining them into a health score. A separate lab probe verified a complete live snapshot with the Function module, and a later full Bicep deployment ran the same collector code under the stack's own managed identity and role (see [what has been validated](#operation-and-permissions)). The scheduled run of a Function published by the full stack is unverified, because a tenant policy blocked publishing it (see [tenants that force storage public access off](#tenants-that-force-storage-public-access-off)).

| Part | Where it lives | Authentication |
| --- | --- | --- |
| Metrics, log and Resource Graph panels | Azure Monitor, Log Analytics and Resource Graph, read by Grafana | Grafana's managed identity (Monitoring Reader, Log Analytics Reader); no secret, no collector |
| Cost snapshots (the only part that needs a collector) | `AICostSnapshot_CL` in the monitoring Log Analytics workspace, written through a data collection endpoint and rule | Collector's user-assigned managed identity: a one-action Cost Management query role plus Monitoring Metrics Publisher on the rule |
| Scheduled collector | An Azure Function (daily, 06:00 UTC) in the monitoring resource group | The collector's user-assigned managed identity |

## Runtime identity and deployment authentication

The Terraform and Bicep cost-pipeline definitions create a **user-assigned managed identity** for the collector. The Function uses it directly to obtain short-lived Cost Management and Logs Ingestion tokens. The Azure Monitor data source uses a separate Grafana workspace managed identity to read the collected data. Neither requires a user's browser session, MFA, or a client secret. Infrastructure deployment still needs an authenticated principal with the necessary resource and role-assignment permissions; the deployment identity is separate from those runtime identities.

These are shared workload identities, not per-viewer Azure authorization. A successful workload-identity test does not establish that each viewer can see only costs permitted by that viewer's own Azure roles.

## Cost Management export to Azure Data Explorer (no Function)

Grafana cannot read Cost Management or a private storage account directly without a stored secret (see [Direct Grafana queries](#direct-grafana-queries-and-per-viewer-access)). It **can** query Azure Data Explorer with its managed identity, and ADX can read a private storage account with its own managed identity. This path chains those together, so no Function, secret, GitHub or public storage access is involved:

```
Cost Management export -> private storage account -> ADX external table -> Grafana (ADX data source)
```

Everything authenticates with managed identities:

| Hop | Identity and role |
| --- | --- |
| Export writes CSV files to storage | The export's system-assigned identity, **Storage Blob Data Contributor** on the account |
| ADX reads the files | The cluster's system-assigned identity, **Storage Blob Data Reader** on the account, plus a database `managed_identity` policy |
| Grafana queries ADX | Grafana's managed identity, database **Viewer** |
| Deployment sets up the database | The deploying identity, **AllDatabasesAdmin** on the dedicated cost cluster (only that role can set the `managed_identity` policy); removable after deployment |

Enable it with `enableCostExport = true` ([Bicep](bicep.md#optional-cost-export-to-azure-data-explorer), which also provisions the Grafana data source and dashboard) or `enable_cost_export = true` plus `enable_cost_export_dashboard = true` in the Grafana stage ([Terraform](terraform.md#optional-cost-export-to-azure-data-explorer)). It deploys two exports into the deployment subscription: a daily month-to-date export (`cost-current`) and a monthly export of the previous month (`cost-closed`). Both set `OverwritePreviousReport`, so each period keeps one current file instead of accumulating duplicates. The ADX script defines external tables over both containers and an `AiCost()` function that keeps rows for `Microsoft.CognitiveServices` resources (Foundry, Azure OpenAI and Azure AI Services accounts) and, for a month present in both, uses only the closed-month file. The `azure-ai-costs-native` dashboard queries only `AiCost()`.

### Before you enable it

- **Register the provider.** The subscription needs `Microsoft.CostManagementExports` registered (`az provider register --namespace Microsoft.CostManagementExports`). Without it the export deployment fails.
- **Set a start date for Terraform.** `cost_export_start_date` is required. In Bicep, `costExportStartDate` defaults to tomorrow (UTC) and therefore **changes on every redeploy**. To keep the same schedule, pass the value you first deployed. The end date defaults to about five years later; exports silently stop after it, so extend it before then.
- **Plan for history.** Data starts when the export first runs, plus last month after the first closed-month run. It does not backfill older months. Only the deployment subscription is covered.
- **Expect a delay.** A scheduled export first runs the day after deployment. To see data sooner, use **Run now** on each export in the portal or `POST .../providers/Microsoft.CostManagement/exports/<name>/run?api-version=2025-03-01`. Manual runs took about five to seventeen minutes. Billing data itself can lag by a day or more.
- **Know what it costs.** The deployment creates an ADX cluster (the smallest Dev/Test SKU by default). It bills while it exists, whether or not anyone is querying it, and auto-stop is deliberately disabled because a stopped cluster would break dashboards. Treat the figure above as approximate.
- **Know who can see what.** The export contains the **entire subscription's** cost rows, not only AI. Anyone who can use Explore or edit queries on the ADX data source can query `CostExportCurrent` and `CostExportClosed` directly, which is equivalent to Cost Management Reader on the subscription. Limit Grafana Editor and Admin roles accordingly. The Function path filters at the source instead.
- **The CSV schema is positional.** The external tables map the 45 export columns by position. If Cost Management reorders or adds columns, values can silently misalign. Check the dashboard totals against the portal after any export format change, and compare `AiCost()` with a Cost Management query when you first deploy.
- **Tenants with storage policies.** Some tenants force `publicNetworkAccess=Disabled` and `allowSharedKeyAccess=false` on storage accounts and revert manual changes. This design works under such a policy in the Lab: the export and ADX reach storage as trusted Azure services, and no shared key is used. Terraform may show the normalized setting as drift on later plans.

### Private access from Grafana (optional)

Grafana cannot reach Azure Storage privately: Storage is not a supported target for Managed Grafana managed private endpoints, and Grafana has no managed-identity blob data source. It does not need to. The only service Grafana talks to is ADX, which **is** a supported target. The export writes to storage and ADX reads from it as trusted Azure services, so neither hop needs a private endpoint of its own. Private access therefore applies to the **Grafana to ADX** hop only.

`costExportGrafanaAccess` (Bicep) or `cost_export_grafana_access` (Terraform) chooses how Grafana reaches the cluster:

| Value | Effect |
| --- | --- |
| `public` (default) | Grafana uses the cluster's public endpoint. |
| `privateEndpoint` | Also creates a Grafana managed private endpoint (`mpe-cost-adx`) to the cluster. It stays **Pending** until approved. The public endpoint stays open. |
| `privateOnly` | The same endpoint, and the cluster's public network access is **Disabled**. |

Azure names the ADX side of the connection with a generated GUID, so Bicep and Terraform cannot approve it. Use the helper once after deployment:

```powershell
.\scripts\approve_grafana_private_endpoint.ps1 -ResourceGroupName "<monitoring-rg>" -ClusterName "<cluster-name>" -GrafanaName "<grafana-name>"
```

The cluster name is the `costExportAdxClusterName` Bicep output or the `cost_export_adx_cluster_name` Terraform output. The script approves the pending connection, asks Grafana to refresh its cached state and waits until Grafana reports **Approved**. It supports `-WhatIf`. The identity running it needs permission to approve private endpoint connections on the cluster and to read and refresh the Grafana workspace.

- **Recommended order.** Deploy with `privateEndpoint`, approve, confirm the dashboard returns data, then redeploy with `privateOnly`. Going to `privateOnly` immediately leaves Grafana without ADX access until the approval finishes.
- **Allow a few minutes, and more after a delete.** On a first deployment, panels returned data about 30 seconds after Grafana reported Approved. In one earlier test, an endpoint created shortly after deleting a different Grafana managed private endpoint carried no traffic for about 12 minutes even though both sides reported Approved; deleting and recreating it fixed it. The cause was not identified (stale Grafana state is the likely explanation). If you delete a managed private endpoint, wait about ten minutes before recreating it, and if a new one stays silent, delete and recreate it.
- **What `privateOnly` removes.** The cluster is no longer reachable from the public internet, so the ADX web UI, Kusto Explorer and the repository's local KQL helper scripts work only from a network with private access. Check the dashboard instead. The ARM database script (Bicep and Terraform) still deploys with the public endpoint disabled.
- **Requirements and cost.** The Grafana workspace must be on the Standard tier, which this repository always uses. Private endpoints add their own hourly and data-processing charges; confirm current pricing.
- **Secretless.** The path still uses managed identities only; no key, token or firewall exemption is added.

### What has been validated

- **Live, with Bicep, in a Lab subscription:** the whole chain, from a clean resource group through a full `main.bicep` deployment, then a repeat deployment that succeeded unchanged. Manual runs of both exports wrote CSV files to a private storage account under the tenant policy above, ADX external tables read them with managed identity, and Grafana queried ADX with managed identity. The ADX total for the current month matched a Cost Management Query API request for the same window and filter. All five panels of the native dashboard returned data through Grafana, and `AiCost()` returned the closed month from `cost-closed` together with the current month from `cost-current`.
- **Found and fixed during live validation:** the deployer needs cluster-level AllDatabasesAdmin to set the `managed_identity` policy; the export API rejects `partitionData = false`, so the property is omitted; and each export also writes a `manifest.json` beside its CSV, which breaks the external tables unless they set `fileExtension='.csv'`.
- **Private access, live with Bicep:** with the cluster's public network access `Disabled`, all five dashboard panels still returned data through Grafana's managed identity, and the same panels failed with a connection timeout once the managed private endpoint was removed (negative control), so the private endpoint is what carries the traffic. The `privateOnly` Bicep deployment, including its ARM database script with public access disabled, succeeded and created the endpoint; after `scripts\approve_grafana_private_endpoint.ps1` approved it, all five panels returned data on the first attempt. Direct access to the cluster from outside timed out. The one failure seen (see the note on deleting an endpoint above) was resolved by recreating the endpoint.
- **Not validated:** an **Active scheduled** export run (validation used manual runs, and the first scheduled run is the day after deployment), the month rollover from `cost-current` to `cost-closed`, a month that appears in both containers (the closed-month-wins logic is untested against real overlapping files), a deployment of the Terraform path including its managed private endpoint (it passes `terraform validate` and mock-provider tests only), switching an existing `privateEndpoint` deployment to `privateOnly`, and exports beyond the five-year end date.

### Query the data

```kusto
AiCost()
| where Date >= startofmonth(now())
| summarize BillingCost = sum(Cost) by BillingCurrency
```

Amounts are in billing currency. `CostUsd` is also available, but sums across currencies are not meaningful, so the dashboard groups by `BillingCurrency`. An empty result means no AI charges have been exported yet, not zero cost.

## Deploy the optional Function collector

Billed cost is the only dataset that needs a collector (see [Direct Grafana queries](#direct-grafana-queries-and-per-viewer-access) for why Grafana's managed identity cannot read it). The collector is an Azure Function (Flex Consumption, PowerShell 7.6) that runs **inside your subscription**: no GitHub, external scheduler, app registration or client secret. Azure hosts the Function, its plan and deployment storage, the Log Analytics table, the data collection endpoint/rule, a user-assigned managed identity, and its roles. Function execution, storage, ingestion, retained logs, queries, and Grafana can incur charges. It is not direct Grafana-to-Cost-Management access and does not provide per-viewer cost authorization; track that in [issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4).

1. Choose a query scope and review its roles in [Operation and permissions](#operation-and-permissions).
2. Set `enable_cost_pipeline = true` in [Terraform](terraform.md#optional-cost-pipeline) or `enableCostPipeline = true` in [Bicep](bicep.md#optional-cost-collection-and-budget). Both create everything listed above, and both publish the Function package from `function/cost-collector/`; the deployer needs the publishing prerequisites in those pages. Review the plan or what-if and estimated charges before applying.
3. If you use `resourceGroup` scope, grant the cost-query role at every monitored group as described [below](#grant-separately-in-resourcegroup-mode).
4. After role propagation, wait for the daily **06:00 UTC** run, then verify a complete snapshot in Log Analytics and the expected account and currency data in both Grafana cost dashboards. Do not mark the deployment live-validated merely because offline tests pass.

After changing monitored accounts, cost scope, lookback, or ingestion resources, redeploy and verify another snapshot. A completion marker confirms only the accounts supplied to that run.

### Upgrading from the removed GitHub Actions collector

Earlier revisions offered a GitHub Actions OIDC collector (`costCollectorMode = 'githubOidc'`, the default for a short time). It has been removed with its workflows, the `costCollectorMode`, `costGithubOidcSubject`, `cost_collector_mode` and `cost_github_oidc_subject` inputs, and the `costCollectorConfiguration` / `cost_collector_configuration` outputs.

- Delete the removed inputs from your parameter and variable files; Terraform rejects undeclared variables.
- With the pipeline enabled, the Function, its plan, storage and Function-only roles are now always deployed. Review the plan or what-if for them.
- Terraform plans removal of the GitHub federated credential. Bicep is incremental and does **not** delete an existing one (issuer `https://token.actions.githubusercontent.com`): review it on the identity and delete it explicitly, since it remains a trust path until removed.
- If you configured the old workflow, delete its `COST_*` repository variables and disable it in GitHub. Stored snapshots in Log Analytics are kept.

## Direct Cost Management queries with Infinity (opt-in)

This is the cheapest and simplest billed-cost path, and the only one that is **not secretless**. Grafana's Infinity plugin calls the Cost Management Query API directly, so there is no cluster, Function, storage account or export. The cost is one rotating secret and the access caveats below.

**Why it needs a secret.** Infinity 4.x (the version available to Azure Managed Grafana) cannot sign in with Grafana's managed identity or a federated credential. It supports OAuth2 client credentials, so a service principal signs in with a client secret that Grafana stores encrypted. The built-in Azure Monitor data source's managed-identity proxy rejects Cost Management requests. Nothing in this repository can remove the secret while that remains true; [issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) tracks it.

**What you get.** The `azure-ai-costs-infinity` dashboard shows month-to-date actual cost by currency, daily actual cost, cost by account and cost by meter for `microsoft.cognitiveservices/accounts` (Foundry, Azure OpenAI and Azure AI Services). Its `costScope` textbox holds the Cost Management scope being queried. Amounts are actual (not amortized) pretax costs in billing currency.

### Set it up

1. **Create the service principal and a bounded secret.** No script is needed:

   ```powershell
   $app = az ad app create --display-name "ai-observability-cost-query" --sign-in-audience AzureADMyOrg | ConvertFrom-Json
   $sp  = az ad sp create --id $app.appId | ConvertFrom-Json
   # The secret is shown once. Keep it in your secret store, and give it a short, bounded life.
   $env:AI_OBSERVABILITY_COST_CLIENT_SECRET = az ad app credential reset --id $app.appId --append --display-name grafana-infinity --end-date (Get-Date).AddMonths(6).ToString('yyyy-MM-dd') --query password -o tsv
   $app.appId   # costInfinityClientId / cost_infinity_client_id
   $sp.id       # costInfinityServicePrincipalObjectId / cost_infinity_service_principal_object_id
   ```

   Use the **service principal (enterprise application) object ID**, `$sp.id`, not the app registration's object ID. The service principal has no roles until you deploy.

2. **Deploy.** Bicep: set `enableCostInfinity`, `costInfinityClientId`, `costInfinityServicePrincipalObjectId` and `costInfinityScope` ([Bicep](bicep.md#optional-direct-cost-queries-with-infinity)). Terraform: set `enable_cost_infinity` and the matching variables in the Azure stage and `enable_cost_infinity_dashboard` in the Grafana stage ([Terraform](terraform.md#optional-direct-cost-queries-with-infinity)). Either path installs the Infinity plugin on the workspace, grants the principal read-only cost access, creates the data source and imports the dashboard.

3. **Choose the scope.**
   - `subscription` (default) grants **Cost Management Reader** on the whole subscription. The dashboard then shows every AI account in the subscription, not only the monitored ones.
   - `resourceGroupManaged` grants a custom role with the single action `Microsoft.CostManagement/query/read` on each monitored resource group, which needs monitored accounts and permission to create role definitions. The dashboard defaults to one monitored group; change `costScope` to `/subscriptions/<id>/resourceGroups/<name>` to see another. The role is named `AI Observatory Cost Query infinity-cost <hash>`, so it never collides with the Function collector's roles.

### Rotate or remove the secret

Rotate before the expiry you chose. Create a new secret with `az ad app credential reset --append`, put it in `AI_OBSERVABILITY_COST_CLIENT_SECRET` (Bicep helper) or `TF_VAR_cost_infinity_client_secret` (Terraform), redeploy to update the data source, confirm the dashboard still returns data (look at the panels, not the data source's **Save & test**), then delete the old secret with `az ad app credential delete --id <appId> --key-id <old-key-id>`. The Bicep helper rerun took about 72 seconds in testing. After the update, the first query may still fail once with `AADSTS7000215`; reload after a few seconds.

To remove the feature, set the switch to false and redeploy, then clean up explicitly because Bicep is incremental and Grafana resources are never deleted by the helper:

```powershell
az role assignment delete --assignee <sp-object-id>       # then delete the AI Observatory Cost Query infinity-cost roles
az ad app delete --id <app-id>                            # also removes the service principal and its secrets
```

Delete the Infinity data source and dashboard in Grafana if you no longer want them.

### Things to know before you enable it

- **It is a shared identity, not per-viewer access.** Every viewer of the dashboard sees what the principal can read. Anyone who can edit queries on the Infinity data source (Grafana Editor and Admin) can run any Cost Management query the principal's role allows, so use `resourceGroupManaged` where you can and restrict those roles.
- **The secret lives in Grafana, and in Terraform state.** Grafana never returns it through its API, but the Terraform Grafana stage records it in state. Supply it as `TF_VAR_cost_infinity_client_secret`, never in a `.tfvars` file, and protect the state like a credential. The Bicep path keeps it out of the parameters: the helper reads it from `AI_OBSERVABILITY_COST_CLIENT_SECRET` or `-CostInfinityClientSecret` and sends it only to Grafana.
- **Expiry silently breaks the panels, and the health check will not tell you.** Nothing alerts you by default when the secret expires or is revoked. The panels fail with an authentication error (`AADSTS7000222` expired, `AADSTS7000215` wrong or revoked), but the data source's **Save & test** keeps reporting "Health check successful" with a wrong, revoked or expired secret, so it cannot be used to check the secret. Check the panels. You can add a Grafana alert rule on the data source that fires when the query fails (see [the live results](#what-has-been-validated-1)); it detects a failure, it does not warn before expiry, because Grafana cannot see the credential's end date. Until that rule ships with the repo ([issue #28](https://github.com/michael-rechani/azure-ai-observability/issues/28)), set a calendar reminder for the end date.
- **A cached token can hide a bad secret for up to an hour.** Grafana keeps using the access token it already has after the secret is revoked or expires. The failure appears when the token expires (about an hour) or when the data source is updated, so a rotation can look fine until later. Always confirm after you update the data source.
- **The Query API is throttled.** It returns HTTP 429 often. Infinity does not retry, so a panel can fail intermittently on refresh. Reload after a short wait. The daily panel is capped at 31 days per query (the API's limit for daily granularity), so the dashboard's time range should stay within a month.
- **It is live, not historical storage.** Nothing is kept outside Cost Management. If you need long history or alerting on cost data, use the export or the Function.
- **A continuation link fails the query** instead of silently showing a partial total.
- **Plugin installation by ARM is a preview feature** (`grafanaPlugins` on the Grafana workspace). If it is unavailable in your tenant, install **Infinity** from the Grafana plugin catalog and rerun; the helper stops with that instruction when the plugin is missing.

### Alternatives that were checked

Checked for a secretless option on 2026-11; none was found at lower cost:

- **Resource Graph `costresources`.** Tested live; the table is rejected (`DisallowedLogicalTableName`).
- **Infinity with managed identity or workload identity.** Infinity 4.1.6, the latest release at the time, has neither, and its documented Azure example uses a client secret.
- **Will federation arrive?** Not visibly planned, and no timeline exists. The Infinity maintainer's pull request for Azure managed and workload identity ([#785](https://github.com/grafana/grafana-infinity-datasource/pull/785)) was closed unmerged in 2026-03, as was a generic OAuth2 token-exchange request ([#1569](https://github.com/grafana/grafana-infinity-datasource/pull/1569)). Infinity 4.1.0 did add AWS IAM role authentication, so cloud identity is possible, but only for AWS so far, and there are no open Azure issues or pull requests. Grafana's Azure SDK has managed- and workload-identity credentials, but Grafana only forwards its `[azure]` settings to a listed set of plugins (Azure Monitor, Data Explorer, Prometheus, MSSQL, Databricks), and Infinity is not one of them. A secretless Infinity on Azure would need Infinity to add Azure authentication, Grafana to forward the settings to it, and Azure Managed Grafana to enable that. [Issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) stays open to revisit it.
- **Log Analytics `externaldata`.** Managed-identity access is documented only for ADX and Fabric, and Log Analytics cannot reach private storage.
- **ADX free cluster.** No external tables, managed identities or VNet support.
- **Cost export to Log Analytics.** Exports go only to Storage (or Fabric).
- **Not built, not tested:**
  - **Infinity `oauthPassThru`**, which would forward each viewer's own token (per-viewer authorization). Nothing documents a forwarded token with an Azure Resource Manager audience in Azure Managed Grafana.
  - **Synapse serverless SQL** over the export storage. It is billed per TB scanned (pennies) and can read firewall-protected storage with its managed identity, so it is the most promising secretless alternative to ADX. It adds a workspace and T-SQL login setup, Managed Grafana cannot reach Synapse over a managed private endpoint (so it would use a public Entra-only endpoint), and managed-identity authentication from Grafana's SQL data source is unverified.
  - **Azure SQL** `OPENROWSET`, judged fragile (no Parquet; CSV needs a format file).

### What has been validated

A throwaway deployment in a sandbox subscription used the real `scripts\deploy_bicep.ps1` with `resourceGroupManaged` scope and a temporary service principal created with the commands above. The service principal, its secret and the resource group were removed afterwards.

**Verified live:**

- The three `az ad` commands work as documented.
- The deployment succeeded end to end. ARM installed Infinity 4.0.0 on a Grafana 12 workspace at create time, the helper created the data source, and all four dashboards were imported. The only access created on the monitored resource group was the single-action custom role.
- Grafana stores the client secret write-only: the data source reports only that a secret is set and never returns it.
- All four panel queries run through Grafana's backend, which expands the `${__from:date:iso}` and `${__to:date:iso}` time macros itself.
- Against a resource group with real billed cost (the resource-type filter swapped to storage accounts, because the sandbox has no billed Azure AI cost), all four panels returned correctly shaped rows: month-to-date total, 31 daily rows with the date converted to a time field, account and resource group extracted from the resource ID, and meter with quantity. This checks the column mapping, the `ResourceType` `In` filter and the retry on HTTP 429, which occurred once.
- Removing and re-adding the plugin with `PATCH` on `Microsoft.Dashboard/grafana` (`null` removes, `{}` installs, api-version `2025-08-01`) works, and a data source survives it. ARM rejects plugin IDs it does not know. This is the mechanism the Terraform stage uses.

**Secret lifecycle, verified live** in a second throwaway deployment with the Bicep helper:

- **Rotation.** A new secret was created with `--append` and the helper rerun (72 seconds). All panels recovered, including from a deliberately wrong secret. Deleting the old secret in Entra afterwards broke nothing.
- **Wrong or revoked secret.** Every panel failed with `AADSTS7000215: Invalid client secret provided`. **The data source health check still said it was healthy.**
- **Expired secret.** After a secret passed its end date, Entra kept accepting it for about five more minutes, then rejected it with `AADSTS7000222`. Once Grafana had to request a new token (after the data source was updated), every panel failed with that error. Again the health check still said it was healthy.
- **Cached token.** Until the data source was updated, panels kept working with the token Grafana already held, even after Entra rejected the secret. A token lasts about an hour; the observed behavior was only until the update, not through a full token lifetime.
- **Propagation.** After a secret change, an occasional single panel query failed with `AADSTS7000215` before succeeding on the next one. It was also seen once with no change in between. Treat a one-off failure right after a rotation as transient; repeated failures are not.

**Terraform path, verified live** in a third throwaway deployment (a pre-created resource group, both stages applied, then destroyed):

- **Azure stage.** 11 resources were created in about 5.5 minutes. The `azapi` resource installed Infinity on the new Grafana 12.4 workspace, and the plugin was present when queried through ARM. Terraform created one custom role with the single `Microsoft.CostManagement/query/read` action and assigned it on the monitored resource group.
- **Grafana stage.** Six resources were created: the Infinity data source (secret stored write-only), the Azure Monitor data source and four dashboards.
- **Panels and scope.** All four panel queries returned HTTP 200 through Grafana's backend (zero rows, because the sandbox has no billed Azure AI cost). Scopes outside the role (the subscription and another resource group) returned `401 RBACAccessDenied` from Cost Management, so the least-privilege role does what it says.
- **Idempotency.** A second `terraform plan -detailed-exitcode` exited 0 on both stages.
- **Rotation through Terraform.** A second secret was created with `--append`. Changing only `TF_VAR_cost_infinity_client_secret` and reapplying the Grafana stage produced one in-place change to the data source and took about 4 seconds. The panels kept working, and they still worked after the old secret was deleted, which Entra then rejected with `AADSTS7000215`.
- **Destroy.** `terraform destroy` removed both stages cleanly, including the role definition and assignment. This used a resource group that was not created by Terraform; the earlier finding that a Terraform-created group cannot be destroyed because of the Failure Anomalies alert rule is unchanged.

**Alert on a failing secret, verified live** in the same deployment, using a Grafana-managed alert rule created through the provisioning API. It queries the Infinity data source with the month-to-date query, has error handling set to `Alerting`, and is evaluated every minute:

- With a good secret the rule stayed `inactive` and healthy.
- After a bad secret was written to the data source, the rule went to `firing` with `health=error` at the next evaluation (under 35 seconds), with the `AADSTS7000215` message, and the alert showed in Grafana's Alertmanager.
- After a good secret was restored, the rule cleared after one more evaluation.
- Alerting works in Azure Managed Grafana, but SMTP is off by default, so you must configure a contact point. Notification delivery, a real expiry, behavior with a transient 429 and a Terraform-managed rule were not tested; see [issue #28](https://github.com/michael-rechani/azure-ai-observability/issues/28).

**Not verified:**

- Rows for `microsoft.cognitiveservices/accounts`. The sandbox has no billed Azure AI cost, so the monitored group returned HTTP 200 with zero rows, which matched direct API calls.
- How the panels render in a browser, including the daily time series.
- Whether an in-place update of the Grafana workspace by the azurerm provider keeps the installed plugin. The Terraform stage reinstalls it if the `azapi` resource is replaced.
- How long Grafana keeps a cached token beyond the update that was tested (the token lifetime is about an hour).

## Direct Grafana queries and per-viewer access

**Short version:** Grafana's managed identity reads Azure Monitor, Log Analytics and Resource Graph natively, which is why those panels need no collector. For Cost Management, the tested Infinity plugin offers no managed-identity or federated-credential authentication, and the Azure Monitor data source's managed-identity proxy rejected the Cost Management request. Until a Grafana data source can do that without a stored secret, choose the [direct Infinity query](#direct-cost-management-queries-with-infinity-opt-in) (no extra resources, but a rotating client secret), the [export to ADX](#cost-management-export-to-azure-data-explorer-no-function) path (no code, no secret, higher standing cost) or the in-Azure Function below (pennies, one more component to run).

Azure Managed Grafana can use a managed identity with [data sources that support it](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-authentication-permissions); that does not make the identity available to every REST plugin. A private workspace test used signed Infinity 4.0.0 on Grafana 12.4.13 with a temporary OAuth client-credentials service principal to query Cost Management directly, without the Function. One actual-cost row and one amortized-cost row matched separate API queries for one account. The principal had a single-action cost-query role at its resource group. A direct subscription-scope API request was denied with `RBACAccessDenied`, and the corresponding Grafana query reported an upstream HTTP 401. This was a **shared client-secret identity**, not Grafana managed identity or per-viewer authentication. The test did not establish complete historical coverage, continuation handling, or production readiness.

The examined Infinity version did not expose a native managed-identity option for generic REST queries. Grafana's documented [Infinity Azure API example](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/examples/examples/azure/) also uses a client secret and a shared service identity, not each viewer's permissions. In the same private workspace, the built-in Azure Monitor data source's managed-identity resource proxy accepted a subscription-list control request but rejected the tested Cost Management POST as an unsupported path before authorization. The workspace identity had no cost role, so this is not a test of its Cost Management permissions or proof that every possible managed-identity integration is unavailable. Do not persist a user's access token as a production data-source credential.

Microsoft documents [federating an app registration with a user-assigned managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity) without an app secret. That general capability does not establish that the tested Grafana/Infinity configuration can perform the required token exchange; direct Grafana federation has not been demonstrated.

Microsoft recommends considering [Current User authentication](https://learn.microsoft.com/en-us/azure/managed-grafana/secure-azure-managed-grafana#identity-and-access-management) for supported data sources, and Grafana documents it for the [Azure Monitor data source](https://grafana.com/docs/grafana/latest/datasources/azure-monitor/configure/#current-user). Signing in to Grafana does not by itself grant access to Cost Management or Log Analytics, or establish that Infinity receives an Azure Resource Manager token. The upstream Current User provisioning guidance specifies `oauthPassThru: true` and `disableGrafanaCache: true` to forward credentials and prevent cached responses from exposing resources across users. Support for these settings and their behavior have not been verified in the target Azure Managed Grafana workspace.

In [upstream Grafana 12.4.13](https://github.com/grafana/grafana/blob/v12.4.13/pkg/services/login/authinfoimpl/store.go), the authentication store encrypts and persists OAuth access and refresh tokens. OAuth passthrough therefore does not imply that tokens exist only in memory. Restrict access to the authentication store and encryption keys, and verify Azure Managed Grafana's own storage, retention, and access controls before relying on this approach; those managed-service details have not been verified here.

Current User requires an interactive user for those queries; background alerting and reporting require a separately authorized identity or another approach. Upstream Grafana's documentation says enabling Current User also enables fallback service credentials at the instance level by default; whether and how Azure Managed Grafana exposes that setting is unverified. Explicitly review and test fallback credentials so a more-privileged shared identity is not silently substituted for a viewer's permissions. A shared Log Analytics table does not automatically inherit each viewer's Cost Management permissions, and this repository's cost dashboard does not enforce per-viewer access.

For separately administered **group-based** access, Microsoft documents [Grafana Limited Viewer and component permissions](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-manage-access-permissions-users-identities), including data-source permissions. A possible design is a separate, narrowly scoped workload identity and data source for each access boundary, with explicit Grafana team grants. Azure Managed Grafana supports [only one managed identity per workspace](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-authentication-permissions#use-a-user-assigned-managed-identity), so separate identities would require an appropriate supported data-source authentication method or separate workspaces. This would not automatically mirror each person's Azure Cost Management permissions. Grafana's [data-source documentation](https://grafana.com/docs/grafana/latest/administration/data-source-management/#data-source-permissions) says a Viewer can query a data source beyond the queries shown on dashboards by default, and identifies data-source permissions as an Enterprise/Cloud feature. Verify availability for the target Azure Managed Grafana version and tier. Inherited or broader roles, Grafana administrators, and other data sources or workspaces with overlapping access must also be considered. This repository does not configure or validate such a boundary; real access, cache, background-query, and cost-completeness tests are required before relying on it.

A Lab attempt created two temporary Entra test users with no initial group memberships or Azure role assignments. The first user's normal interactive sign-in stopped at a security-information registration prompt; a separate temporary-user diagnostic reached the same prompt after password entry. No delegated token was obtained, and no two-user cost or Grafana authorization comparison ran. All temporary users were independently verified absent from active and deleted users; no MFA or tenant policies were changed. Passwords were generated in memory rather than stored in Terraform state.

A later manual attempt returned a delegated token, but the test stopped because one or more expected token claims did not match; the previous helper did not record which claim category failed. No Cost Management query or two-user comparison ran. A subsequent ownership-checked cleanup pass independently verified both temporary users absent from active and deleted items; no cost role or assignment was created during this attempt. A revised private helper reports only mismatched claim categories, not claim values. A subsequent retry was stopped at the user's request during browser sign-in, before any cost query or role assignment; both temporary users were independently verified absent. The revised diagnostics have synthetic coverage but have not been evaluated live.

A separate localhost test used Grafana OSS 12.4.13 and signed Infinity 4.0.0 with two PKCE-authenticated synthetic viewers and a synthetic backend that assigned each viewer a different scope. With `oauthPassThru: true` and `disableGrafanaCache: true` configured, each viewer received only its authorized row and was denied the other scope, including when identical queries were repeated in both viewer orders. Each repeated query reached the backend; a local Grafana user without an OAuth token was denied. After synthetic token expiration, both viewers refreshed their tokens and retained their respective restrictions. A deliberately failed refresh returned HTTP 401 without a successful backend query; the other viewer remained able to query. No fallback credential was configured for that passthrough data source. With a shared synthetic credential, both viewers could read both scopes. This did not test Entra, Cost Management, Azure Managed Grafana, an active query cache, real Entra token refresh, or background identity fallback; it does not establish production per-viewer isolation.

For an interactive alternative outside Grafana, [Azure Workbooks](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview#access-control) base access on the viewer's resource permissions, and their [Azure Resource Manager data source](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources#azure-resource-manager) supports POST requests without a manually supplied authorization header. A workbook querying Cost Management is a candidate for investigation, not a validated Grafana integration or a substitute for testing two users, billing scopes, continuation handling, and error behavior.

A different **not yet implemented or tested** candidate that avoids a collector function is [Cost Management exports](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports) to Blob Storage, followed by [Azure Data Explorer ingestion](https://learn.microsoft.com/en-us/azure/data-explorer/ingest-data-event-grid-overview) and its [Azure Managed Grafana data source](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-connect-azure-data-explorer). Exports support resource-group scopes; the export-to-storage and Event Grid ingestion paths can be configured with managed identities, and the Grafana data source supports both managed identity and Current User. The Event Grid data connection defaults to key-based authentication unless managed identity is explicitly configured. This is an exported-data pipeline, not a direct Cost Management query, and adds Data Explorer, storage, event infrastructure, and associated cost. The existing Log Analytics dashboard and completion marker do not implement this pipeline.

An export can contain multiple partitions and a manifest, and daily files can contain revised month-to-date data or overwrite earlier files. A design must verify every partition, reconcile revisions and retries, and publish only complete runs rather than blindly ingesting each blob as an independent cost total. Current User authenticates to Data Explorer using the viewer's **Data Explorer** permissions; it does not automatically inherit their Cost Management permissions. Data Explorer [row-level security](https://learn.microsoft.com/en-us/kusto/management/row-level-security-policy?view=azure-data-explorer) is a possible separate boundary, but cannot be configured on external tables. Per-viewer isolation, caching, background identities, network paths, and billing coverage would all require validation before replacing the collector.

Partitioned workspaces or [Log Analytics granular RBAC](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/granular-rbac-log-analytics) are possible designs to investigate, not validated features of this repository. Granular RBAC is additive: broader grants can override conditional restrictions, and its policies do not automatically mirror Cost Management access. The current completion marker has no account identifier and counts all rows in a snapshot. Restricting a viewer to a subset can hide the marker or make its expected count disagree with the visible rows, so the existing dashboard may reject the snapshot. A per-viewer design needs a new completion boundary and explicit authorization tests.

An isolated Log Analytics probe with **synthetic data only** did not establish the proposed row boundary. A table read back as `Protected`, and the workspace read back `dataAuthorizationMode: true`. Two fresh managed identities had separate conditional assignments for `alpha` and `beta`, with no other workspace or inherited assignments found; nevertheless, each explicitly queried the other boundary's rows. The `alpha` identity could not read a second table, a control-plane-only Reader saw no rows, and an unassigned identity was denied. The identities were attached to one test worker, and the workspace's ingestion and query endpoints were publicly reachable with Entra authorization. This is a failure of the tested configuration, not proof that all granular RBAC configurations fail. Its cause is unresolved; do not use this configuration to isolate sensitive data. It did not test Grafana or delegated human users.

A separate synthetic probe using a `General` table and table-and-row conditions passed after allowing at least 16 minutes for role propagation and refreshing identity tokens. The `alpha` and `beta` identities saw their respective 5 and 4 rows, including their completion markers; an identity authorized for both saw 9, and an unrestricted control saw all 11, including unlabeled and differently cased rows. Explicit cross-boundary queries returned no rows, the conditional identities could not read a second table, a control-plane-only Reader saw no rows, and an unassigned identity received HTTP 403. Query audit entries for the conditional identities indicated that a condition was applied. A synthetic per-boundary snapshot check also passed. As above, the identities shared a test worker and the endpoints were publicly reachable with Entra authorization. This result does not resolve the protected-table failure or validate Grafana, human delegated access, real cost permissions, or production isolation.

A separate signed-in Azure CLI **user** comparison queried actual cost for the same account over 90 days, once as a single request and again in four non-overlapping windows of at most 27 days. Each approach returned the same one date/currency row and amount, without a continuation. This is a narrow comparison for one account and billing context, not proof of complete history, amortized history, pagination, or Grafana's handling of other windows.

The original [JSON API plugin](https://grafana.com/docs/plugins/marcusolsson-json-datasource/latest/) is deprecated, lacks OAuth2/JWT authentication and backend alerting, and is scheduled to lose support on February 1, 2027. Local Infinity tests also matched a single-page actual-cost query to the API using an Azure CLI user token, but did not establish managed-identity or real two-user isolation. Some tested pagination configurations returned incomplete synthetic results without an error; live continuation remains unverified.

Keep the collector unless a supported alternative demonstrates least-privilege authentication, complete results and explicit error handling. Per-viewer access also needs two independently authenticated users with different effective permissions, including cold and warm caches, token refresh, and the identity used for background queries. Controlled test users can exercise that boundary but do not validate real-human workflows. See [issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) for test details and remaining checks.

### Native estimate from Azure Monitor metrics (no collector, no secret)

Grafana's managed identity can already read per-model token metrics (`InputTokens`, `OutputTokens`) and `FoundryModelEstimatedCost` from Azure Monitor. A read-only comparison against Cost Management actual cost covered one existing pay-as-you-go Foundry account: five usage days and three models. The subscription's other two accounts had no estimate data and were not compared. It found:

- **`FoundryModelEstimatedCost` is not a usable spend figure.** It was close on the smallest days but about 2x below billed for the small models, and about 14x below (roughly 7% of billed) for the largest model on its two heavy days. It also reports no unit.
- **Output tokens × the model's per-1M output price reproduced the billed output charge** for every model-day compared. Input tokens priced the same way reproduced the billed input charge on days without prompt caching.
- **Prompt caching breaks the input side.** `InputTokens` includes cached tokens, which bill at a much lower rate. For the largest model about three quarters of input tokens were cached. No usable per-model cached-token metric was found: `cacheReadInputTokens` had no data and the cache-match-rate average did not match the billed split. Pricing all input as uncached overstated total cost by roughly 30–50% on those days.
- **Not covered:** provisioned (PTU) hourly charges, hosted-agent compute, negotiated or discounted rates, tax, and later price changes.

The Foundry overview dashboard now has a table built on exactly this: **Estimated pay-as-you-go token cost by model (list price, not billed)**. It is a native, secretless **estimate**. The collector and the Costs dashboard stay the source of billed cost. The reconciliation above is one account over a few days, so repeat the comparison on your own accounts before relying on the panel.

#### How the panel works

- **Tokens.** `InputTokens` and `OutputTokens` (Total) split by the `ModelName` dimension for the account selected on the dashboard, read by Grafana's managed identity through the Azure Monitor datasource.
- **Prices.** A `datatable` in [`queries/model-prices.kql`](../queries/model-prices.kql): USD per 1M tokens, Global Standard, `eastus2`, from the Azure Retail Prices API. It is read through the Azure Monitor datasource's Log Analytics query against the dashboard's **Telemetry workspace ARM ID**, so that variable must hold a workspace Grafana can query. The query reads no tables.
- **Join.** Grafana transformations join tokens to prices on the model name and multiply. There is no collector, secret or extra resource.

#### Keep the price table current

Prices change and your agreement may differ. To update them, edit `queries/model-prices.kql`, run `python scripts/build_dashboards.py`, then re-import or redeploy the dashboards. A model missing from the table is not dropped: it shows `not listed` for prices and `no list price` for cost, and its tokens are still counted. The footer's cost total leaves it out. Costs are rounded to cents, so a low-volume model can show `$0.00`.

#### What it does not cover

- **Prompt caching.** All input tokens are priced as uncached, so a workload with heavy caching is overstated (see the comparison above).
- Batch, Flex, Priority, data-zone and regional pricing, long-context tiers (`gpt-5.5` and later are not in the table), hosted-agent compute, negotiated or discounted rates, and tax.
- **PTU.** Tokens served by a provisioned deployment are priced as if pay-as-you-go. That is a pay-as-you-go equivalent, not the PTU hourly bill.
- The panel relies on the metric names `Input Tokens` and `Output Tokens` and the `ModelName` dimension. If Azure changes them the panel visibly breaks rather than showing wrong numbers.

#### What was and was not validated

- **Validated live.** A throwaway Managed Grafana (Bicep deployment) read a Foundry account through its managed identity. Token totals in the panel matched the usage the API reported for the test calls. A priced model, a second priced model and an unpriced embedding model all rendered correctly in a browser on Grafana 12.4, with sorting, the footer and the `no list price` path. A repeat deployment updated the dashboards cleanly. The real queries, frames and transformations were exercised, not only synthetic data.
- **Not validated.** The dollar figure against an invoice for those calls (the amounts were too small and billing lags), PTU deployments, accounts with their own negotiated rates, other Grafana versions, and prices for regions other than `eastus2`.

## What the numbers mean

The dashboard reports **pretax costs attributed by Cost Management to the exact configured AI account resource IDs**. It is not an invoice, total subscription spend, a per-deployment/PTU price, or a reservation-coverage report. Reservation purchases, shared or billing-scope charges, child-resource costs, and tax can be omitted. Actual and amortized costs are alternative views and must not be added together; currencies remain separate. Values are rounded for display.

Billing can arrive late or be revised. The collector refreshes a rolling window (90 UTC days by default); corrections older than that window are not automatically captured. Usage-day filtering is UTC and includes the full reported day when a selected range starts partway through it. Validate coverage and billing behavior with your own agreement before making financial decisions.

## Operation and permissions

The collector queries each selected account for actual and amortized costs and writes to `AICostSnapshot_CL` through a data collection endpoint and rule. It runs daily at **06:00 UTC** on Flex Consumption with no always-ready instances; its scale-out maximum of 40 is a ceiling, not 40 running instances.

The deployment offers three query and role modes:

| Mode | Cost Management access granted to the collector identity |
| --- | --- |
| `subscription` (default) | Assigns **Cost Management Reader for the entire subscription**, even though queries filter to selected accounts. |
| `resourceGroup` | Queries each account's resource group but creates **no cost role assignment**; arrange separate grants for every monitored group. |
| `resourceGroupManaged` | Queries each account's resource group and creates one custom role per distinct group, containing only `Microsoft.CostManagement/query/read`, and assigns it to the collector identity at that group. |

These query scopes apply to the collector, not direct Grafana or per-viewer queries. The collector identity also gets Monitoring Metrics Publisher on the data collection rule and on Application Insights, plus Storage Blob Data Owner and Storage Table Data Contributor on the Function's storage account. Review permissions for each customer, including permissions left over from an earlier deployment.

The [built-in Cost Management Reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/management-and-governance#cost-management-reader) includes `Microsoft.Support/*`, which can permit support-ticket writes where those operations apply. It is not strictly read-only. An account filter does not limit either role's permissions: a resource-group assignment can expose all cost data available at that group. Grafana reads the resulting table using its shared workspace-reader identity; Viewer access and dashboard filters do not enforce the viewer's own Azure cost permissions.

A separate [investigation](https://github.com/michael-rechani/azure-ai-observability/issues/4) verified that a temporary managed identity with only `Microsoft.CostManagement/query/read` on one resource group could query that group's actual and amortized costs in one subscription. Queries at subscription scope and another resource group, and a query by an unassigned identity, were denied. This identity-only test did **not** validate the deployed collector, the role in other billing environments, or direct Grafana queries. Test any custom role and billing agreement before relying on them.

A later isolated Lab deployment of the Bicep group-role module created the expected single-action role and assignment at one resource group for a temporary service principal without credentials. Both resources and the temporary application, principal, and deployment records were independently verified absent after cleanup. This tested the module's provisioning and removal, not a cost query through that principal, the complete Bicep or Terraform deployment, or per-viewer access.

A subsequent lab test deployed that same Bicep role module for a temporary service principal with a one-hour credential held in memory. Before assignment, the principal was denied a cost query. After assignment, its actual and amortized daily results for one AI account over 90 days matched separate resource-group queries by the signed-in Azure CLI user, with no continuation in those responses; a subscription-scope query was denied. The credential was revoked, and the role, assignment, application, principal, and deployment records were independently verified absent after cleanup. This validates the module and Cost Management query using a service principal in that billing context, not Grafana, human delegated access, another account or billing agreement, pagination, or the complete Bicep or Terraform stack.

Read-only Azure Resource Manager validation of the root Bicep template returned `Succeeded`, listing 26 validated resources and no diagnostic codes. The returned list did not include role definitions or role assignments, so this does not establish that the nested authorization resources were validated and is not a full-stack deployment.

A follow-up comparison using a signed-in Azure CLI user queried one AI account with the collector's resource ID filter at both resource-group and subscription scope. Actual and amortized daily totals matched for that account over one 27-day window, with 13 rows in each result and no continuation. This was not a collector or managed-identity test; other accounts, billing agreements, windows, and pagination still need validation.

A second local probe ran the collector's resource-group mode against live Cost Management for one account over 31 days, using an Azure CLI **user** token in place of the Function identity. Four queries produced 16 actual and 16 amortized records; ingestion was intercepted locally and the completion marker was checked without writing to Azure. This did not test the deployed Function, its managed identity, live ingestion, pagination, or Grafana.

A subsequent isolated lab probe deployed the repository's Bicep cost Function module and used its managed identity with the single-action custom role at one account resource group. With temporary private storage endpoints and networking, a test-only timer ran the unchanged collector, which submitted 32 distinct cost records. The dashboard's shared snapshot-selection query found a completion marker matching all 32 distinct rows: 16 actual and 16 amortized. A separate synthetic query checked duplicate suppression and rejection of an incomplete snapshot. The private network was a test-only storage overlay, not a complete private Terraform or Bicep deployment; the test's Log Analytics and ingestion endpoints remained publicly reachable with Entra authorization. The probe did not test the production timer schedule, the Grafana UI, other billing environments, pagination, or delegated user access.

A later local 90-day recheck, after response-validation hardening, compared one actual and one amortized row and the completion marker with live Cost Management responses. It again used an Azure CLI user token and intercepted ingestion locally; it did not test the deployed Function or its managed identity.

A full Bicep deployment in a Lab subscription (Grafana, workspace, alerts, native data sources, dashboards and the cost resources, with `resourceGroupManaged` scope) then provisioned the cost identity, its single-action role at the account's resource group, the data collection endpoint and rule, and the table. Because policy blocked publishing the Function, the unchanged `run.ps1` was run in a temporary container that signed in as that **stack-created managed identity**, with the repository mounted at the tested commit. It queried Cost Management at resource-group scope with the stack's role, completed with exit code 0, and posted to the stack's data collection endpoint and rule; the workspace then held a `Complete` marker with `ExpectedRows = 0`. That proves the role grants the queries the collector issues and that the identity can ingest through the stack's endpoint. It does **not** prove real cost values: the account was about an hour old and Cost Management had reported nothing for it, so the run correctly reported **no cost data**, not zero cost. The cost dashboards rendered against that marker without errors, and their cost panels were empty. It also did not run the Function runtime or its timer. Re-verify with real rows after Cost Management has data for your accounts, which can take many hours.

Daily queries use windows of at most 27 days to avoid calendar-month truncation, including around February and partial days. Cost Management continuation URLs must stay on the expected host and query path; managed-identity, cost, and ingestion requests reject HTTP redirects. Deployments reject combinations requiring more than 30 minutes of *minimum* estimated request pacing: `accounts x ceil(lookback_days / 27) x 2 x 16 seconds`. At the 90-day default this permits at most 14 accounts per stack. Pagination and retries can take longer; the Function timeout is 55 minutes. Split larger estates or reduce the lookback.

Transient failures are retried with bounded attempts, honoring the longest valid `Retry-After` or Azure rate-limit retry header in addition to the minimum Cost Management pacing. If a retry header is malformed, negative, nonfinite, or requests a delay over 900 seconds, the run fails rather than retrying prematurely. A missing retry header uses bounded exponential backoff.

Each successful run appends a snapshot. A completion marker is submitted only after all cost batches are accepted, and the dashboard waits until the expected distinct row count is queryable. Runs without both a queryable marker and its matching row count are ignored; the next scheduled run starts over. If the marker request fails or returns an unexpected response, its acceptance is ambiguous: Azure may still have received it after the cost batches were accepted. An initial Cost Management HTTP 204 means no rows were reported for that query. An HTTP 204 after a continuation fails the run because the remaining results cannot be verified. A malformed HTTP 200 response, including duplicate column names, a Boolean cost, or a non-string continuation value, or an unsupported success status also fails the run. Logs Ingestion must return its documented HTTP 204; an unexpected status fails the run. The dashboard searches for completed snapshots from the last 14 days, flags those older than 48 hours as stale, and warns when the selected period is outside the collected window. No reported rows means **no cost data reported**, not zero cost.

The workspace's retention and daily ingestion cap apply to these records. Snapshot copies, queries, collector execution, Grafana, and alerts can incur charges. The deployment storage account enables seven-day soft delete for blobs and containers; deleted packages remain recoverable during that window and can incur storage charges. Blob `StorageRead` diagnostics are sent to the monitoring workspace and can incur ingestion and retention charges. The Function and storage use public endpoints protected by Entra authorization; private networking requires a separate design.

### Tenants that force storage public access off

A live Bicep and a live Terraform deployment in a Microsoft-managed sandbox tenant (Azure Policy `Modify` effect on storage accounts) showed that the cost Function **cannot be published there**. The policy rewrites `publicNetworkAccess` to `Disabled` right after the account is created, a manual re-enable is reverted, and publishing the package fails with `403 This request is not authorized to perform this operation`. The Flex Consumption Function's deployment storage would be unreachable at runtime too. In Terraform the same policy also shows up as a perpetual plan difference on the storage account's `public_network_access_enabled`; that drift is the policy, not a defect, and it only appears when `enable_cost_pipeline` is on. Everything else, including the Grafana data sources and the Foundry, agent, and PTU dashboards, deploys and works in such a tenant. Only billed cost is affected.

If your tenant enforces this, either request a policy exemption for the cost storage account, or leave `enableCostPipeline` at `false` and use the dashboards without billed cost. Private-endpoint and VNet-integrated storage is tracked as future work and is not implemented.

## Configure resource-group query mode

The deployment examples select `resourceGroupManaged` for least-privilege cost-query access. With cost collection enabled, this creates one narrowly scoped role and assignment per distinct monitored group. Each custom role is assignable only at its monitored resource group; several accounts in the same group share one role and assignment. The deployer needs `Microsoft.Authorization/roleDefinitions/write` and, for lifecycle cleanup, `Microsoft.Authorization/roleDefinitions/delete` at subscription scope, plus role-assignment write/delete permission on each monitored group. Bicep also requires subscription deployment permissions for its nested role modules. Check custom-role quotas and organizational policies. A full Bicep deployment in the Lab created and assigned the managed role correctly, and the collector queried Cost Management with it at resource-group scope (see [what has been validated](#operation-and-permissions): the run produced no rows because the account was new, so no real cost values were checked). The Terraform path created the equivalent role and assignment in a Lab deployment, which also found and fixed a scope-casing defect that made the role assignment replace on every plan; Terraform's Function publish was blocked by the same storage policy. The module default remains `subscription` for compatibility, so explicitly review the generated parameters and plans.

Alternatively, set `cost_query_scope = "resourceGroup"` or `param costQueryScope = 'resourceGroup'` to manage the group grants yourself. This changes the query endpoint but does not create or remove cost grants. Separately managed grants must cover **every** resource group containing a monitored account. Both deployment paths default to `subscription` for compatibility.

### Grant separately in `resourceGroup` mode

After deploying the enabled pipeline, retrieve the cost identity's **object ID**. For Terraform, from the repository root:

```powershell
$principalId = terraform -chdir=terraform\azure output -raw cost_identity_principal_id
if ($LASTEXITCODE -ne 0 -or -not $principalId) { throw "Cost identity output is unavailable" }
```

For the Bicep helper's `ai-observability` deployment:

```powershell
$principalId = az deployment group show --subscription "<subscription-id>" --resource-group "<monitoring-rg>" --name ai-observability --query "properties.outputs.costIdentityPrincipalId.value" --output tsv
if ($LASTEXITCODE -ne 0 -or -not $principalId) { throw "Cost identity output is unavailable" }
```

An administrator can assign an **already approved** custom role at each monitored group. For example, replace the placeholders below with the monitoring subscription, an account's resource group, and the full ID of a suitable custom role whose assignable scopes permit the group. The investigated role contained only `Microsoft.CostManagement/query/read`; this example does not create or validate that role.

```powershell
$subscriptionId = "<monitoring-subscription-id>"
$accountGroup = "<account-resource-group>"
$roleDefinitionId = "<approved-custom-role-definition-id>"
$scope = "/subscriptions/$subscriptionId/resourceGroups/$accountGroup"
az role assignment create --subscription $subscriptionId --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role $roleDefinitionId --scope $scope
if ($LASTEXITCODE -ne 0) { throw "Cost role assignment failed" }
```

Repeat for every distinct monitored group. Allow time for role propagation, then verify actual and amortized collection for your billing environment. The collector can fail its first run until these grants exist and propagate; a denied or incomplete collection does not publish a completion marker.

### Review and migrate existing access

**Existing deployments need an access migration.** Where possible, grant and verify the new group access first; propagation and the order of role changes can interrupt collection. For Terraform, inspect the plan: switching scope should remove `azurerm_role_assignment.cost_reader[0]` if that subscription assignment is managed by this state. Terraform also manages the new custom roles and assignments in state; removing a group, disabling the pipeline, or changing scope can plan their removal. Apply only after reviewing the plan. For Bicep, incremental deployment does **not** delete a previously created subscription assignment, group assignment, or custom role when a module or monitored group is omitted. Review and explicitly remove each specific unwanted assignment first, then its custom role definition if it is no longer used. Never remove a role or assignment used by another workload. Externally managed grants have their own lifecycle in either path.

In both cases, other direct, inherited, group-based, or billing-scope permissions can remain. A successful group query while broader access remains does **not** prove the group grant is sufficient: verify with an isolated identity lacking broader access or after reviewing and removing unwanted grants, including negative tests at excluded scopes in an authorized test environment. Review effective access before claiming reduced privilege; do not remove an assignment needed by another workload. For each monitored group, this read-only command lists direct assignments to the identity at that scope and inherited parent scopes, but does not by itself prove effective permissions or enumerate every group or billing grant:

```powershell
az role assignment list --subscription $subscriptionId --assignee-object-id $principalId --scope $scope --include-inherited --fill-principal-name false --output table
if ($LASTEXITCODE -ne 0) { throw "Cost role assignment review failed" }
```

## Troubleshooting

If the dashboard reports a missing or stale snapshot, check the Function's invocations and its Application Insights logs. Also check cost access at the configured subscription or every monitored resource group, data collection rule publishing role, network access, workspace cap, and actual billing availability. Azure role propagation can delay the first successful collection. A collector-failure alert is not provisioned automatically. Do not interpret a missing snapshot as zero spend.
