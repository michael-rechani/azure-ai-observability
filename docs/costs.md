# Azure AI billed cost options

Billed cost is not collected by default. Foundry, PTU, agent-trace and capacity panels are read directly by Azure Managed Grafana's managed identity, but no Grafana data source tested here can query Cost Management with that identity (see [Direct Grafana queries](#direct-grafana-queries-and-per-viewer-access)). The baseline is the Azure portal and a budget; one opt-in route puts billed cost into Grafana.

| | Portal and budget (baseline) | [Direct query with Infinity](#direct-cost-management-queries-with-infinity-opt-in) |
| --- | --- | --- |
| Switch | Always available in the portal. `monthlyAiCostBudgetAmount` (Bicep) or `monthly_ai_cost_budget_amount` (Terraform) adds a budget | `enableCostInfinity` (Bicep), `enable_cost_infinity` (Terraform) |
| Moving parts | Azure Cost Management in the portal; the budget notifies the existing action group | The Infinity plugin on Grafana, one service principal and its role |
| Secrets | None | **A rotating client secret** stored in Grafana (and in Terraform state) |
| Standing cost | None | None beyond Grafana itself |
| History and limits | Whatever Cost Management shows in the portal. The budget is a threshold notification, not a spending cap | Live Cost Management Query API: throttled (HTTP 429), daily data capped at 31 days per query, no stored history |
| Cost basis | Portal views and Cost Management exports are your choice | Actual cost only (not amortized) |
| Visibility | Each person's own Azure RBAC in the portal | Anyone who can edit queries on the Infinity data source inherits the principal's cost access |
| Dashboard | None in Grafana | `azure-ai-costs-infinity` |

The Business overview dashboard (`enableBusinessOverview` in Bicep, `enable_business_overview` in Terraform) has no cost panels; it shows agent and PTU signals only. The Foundry overview also carries a per-model estimate from token counts and list prices (see [Native estimate from Azure Monitor metrics](#native-estimate-from-azure-monitor-metrics-no-secret)), which is an estimate and not billed cost.

These are shared workload identities, not per-viewer Azure authorization. A successful workload-identity test does not establish that each viewer can see only costs permitted by that viewer's own Azure roles.

## Migrating from the removed cost collector

The optional Azure Function cost collector, its `AICostSnapshot_CL` table and the original cost dashboard have been removed. For billed cost in Grafana, use the [Infinity route](#direct-cost-management-queries-with-infinity-opt-in). Rename `enable_cost_dashboard` to `enable_business_overview` (Terraform) and `dashboardConfiguration.enableCostDashboard` to `enableBusinessOverview` (Bicep); it now gates only the Business overview dashboard. The `enableCostPipeline` / `costQueryScope` / `costLookbackDays` parameters (Bicep) and `enable_cost_pipeline` / `cost_query_scope` / `cost_lookback_days` variables (Terraform) no longer exist, so remove them from your parameter and variable files. Existing deployments should remove the pipeline resources. With Terraform, `terraform apply` removes them. Bicep deployments are incremental, so delete the Function app and its plan, the data collection rule and endpoint, the custom table, the storage account, the user-assigned managed identity and its role assignments (and any per-group custom roles) yourself, after confirming nothing else uses them. Existing `AICostSnapshot_CL` data is no longer read by any dashboard.

## Migrating from the removed Azure Data Explorer export

The optional Cost Management export to Azure Data Explorer (ADX), its `azure-ai-costs-native` dashboard and the helper that approved a Grafana managed private endpoint to the cluster have been removed. The cluster billed continuously, and the Infinity route covers the same billed-cost need. **The export was the only secretless way to put billed cost into Grafana.** Billed cost in Grafana now comes only from [Infinity](#direct-cost-management-queries-with-infinity-opt-in), which stores one rotating client secret; without it, the baseline is the Azure portal and a budget.

Remove `enableCostExport` and the `costExport*` parameters (Bicep) or `enable_cost_export`, `enable_cost_export_dashboard` and the `cost_export_*` variables (Terraform) from your parameter and variable files, and the `costExport*` outputs from anything that reads them.

- **Terraform.** The next `terraform apply` of each stage plans to destroy what the export created: the cluster, storage account, exports and any managed private endpoint (Azure stage), and the ADX data source and dashboard (Grafana stage). Review the plan first. The export path was only checked with `terraform validate` and mock-provider tests, never deployed with Terraform, so this destroy is untested.
- **Bicep.** Deployments are incremental, so nothing is removed for you. After confirming nothing else uses them, delete the ADX cluster, the export storage account, the two subscription-scoped exports (`cost-current` and `cost-closed`), the Grafana managed private endpoint `mpe-cost-adx` if you created one, and the role assignments the export set up. In Grafana, delete the **AI observability - Azure Data Explorer** data source and the **Azure AI - Cost visibility (Cost Management export)** dashboard; the provisioning helper never deletes Grafana resources.
- **Data.** The exported CSV files and the ADX tables go with the resources. Download anything you need to keep first.

## Direct Cost Management queries with Infinity (opt-in)

This is the only billed-cost path in Grafana, and it is **not secretless**. Grafana's Infinity plugin calls the Cost Management Query API directly, so there is no cluster, storage account or export. The cost is one rotating secret and the access caveats below.

**Why it needs a secret.** Infinity 4.x (the version available to Azure Managed Grafana) cannot sign in with Grafana's managed identity or a federated credential. It supports OAuth2 client credentials, so a service principal signs in with a client secret that Grafana stores encrypted. The built-in Azure Monitor data source's managed-identity proxy rejects Cost Management requests. Nothing in this repository can remove the secret while that remains true; [issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) tracks it.

**What you get.** The `azure-ai-costs-infinity` dashboard shows month-to-date actual cost by currency, daily actual cost, cost by account and cost by meter for `microsoft.cognitiveservices/accounts` (Foundry, Azure OpenAI and Azure AI Services). Its `costScope` textbox holds the Cost Management scope being queried. Amounts are actual (not amortized) pretax costs in billing currency.

### Set it up

1. **Deploy.** There is nothing to create by hand. Bicep: set `enableCostInfinity` and `costInfinityScope` ([Bicep](bicep.md#optional-direct-cost-queries-with-infinity)). Terraform: set `enable_cost_infinity` and `cost_infinity_scope` in the Azure stage and `enable_cost_infinity_dashboard` in the Grafana stage ([Terraform](terraform.md#optional-direct-cost-queries-with-infinity)). Either path creates, in code:
   - a single-tenant **app registration and service principal** named `<name_prefix>-cost-query`;
   - a **custom role whose only action is `Microsoft.CostManagement/query/read`**, assigned to that principal at the chosen scope (the built-in Cost Management Reader role is no longer used);
   - the client secret ([who creates it](#who-creates-the-secret));
   - the Infinity plugin on the workspace, the data source and the dashboard.

2. **Choose the scope.** Both scopes use the same single-action role, so access is read-only in either case.
   - `subscription` (default) assigns it on the whole subscription. The dashboard then shows every AI account in the subscription, not only the monitored ones.
   - `resourceGroupManaged` assigns it on each monitored resource group, which needs monitored accounts. The dashboard defaults to one monitored group; change `costScope` to `/subscriptions/<id>/resourceGroups/<name>` to see another.

   The role name starts with `AI Observatory Cost Query infinity-cost` and ends with a hash, so you can find it in **Access control (IAM)**.

3. **Check what the deployer needs.** Creating the principal and the role takes two kinds of rights, and a deployment without them fails:
   - **Microsoft Entra:** permission to create app registrations (for example Application Developer, Application Administrator or Global Administrator, or the Graph permission `Application.ReadWrite.All`).
   - **Azure:** permission to create role definitions and assignments at the scope (Owner or User Access Administrator).

#### Who creates the secret

Infinity needs a client secret, and the two paths differ because of what each tool can do:

- **Terraform** creates it (`azuread_application_password`) and rotates it on a schedule, as described under [rotate or remove](#rotate-or-remove-the-secret). Both stages' state hold it, so protect the state as a credential.
- **Bicep** cannot create it. The Microsoft Graph Bicep extension's credential type has no field that returns the secret text, so the resource would be created without a usable value. The provisioning helper `scripts\provision_grafana.ps1` mints one instead, as the deployer who owns the app registration (`az ad app credential reset --append`, 180-day life), sends it only to Grafana and never writes it to a parameter, output or deployment record. You can still supply your own with `-CostInfinityClientSecret` or `AI_OBSERVABILITY_COST_CLIENT_SECRET`, for example when an Entra administrator creates it for you.

### Rotate or remove the secret

**Terraform rotates it for you.** The secret is replaced when it is older than `cost_infinity_secret_rotation_days` (default 90, 7 to 300), and the old one stays valid for 30 more days. When the period passes, apply the Azure stage, then reapply the Grafana stage so the data source gets the new secret. Confirm the dashboard still returns data (look at the panels, not the data source's **Save & test**). Nothing applies on its own, so schedule the applies and keep a reminder.

**Bicep: rerun the helper.** `scripts\deploy_bicep.ps1` (or `scripts\provision_grafana.ps1` alone) mints a new 180-day secret, updates the data source and, only after the data source is saved, deletes the earlier secrets named `grafana-infinity` on that app. It never touches secrets with other names. The first query after the update may still fail once with `AADSTS7000215`; reload after a few seconds. A rerun took about 72 seconds in testing, when the secret was supplied.

**Bring your own secret.** For either path you can create a secret yourself with `az ad app credential reset --append` and supply it (`TF_VAR_cost_infinity_client_secret` for the Terraform Grafana stage, `AI_OBSERVABILITY_COST_CLIENT_SECRET` or `-CostInfinityClientSecret` for the Bicep helper), then delete the old key with `az ad app credential delete --id <appId> --key-id <old-key-id>`.

**Remove the feature.** Set the switch to false and redeploy.

- **Terraform** destroys the app registration, service principal, secret, custom role and assignment with the next apply. Review the plan first.
- **Bicep** is incremental, and Microsoft Graph resources are not deleted with the resource group, so clean up explicitly:

  ```powershell
  az role assignment delete --assignee <sp-object-id>       # then delete the AI Observatory Cost Query infinity-cost roles
  az ad app delete --id <app-id>                            # also removes the service principal and its secrets
  ```

  The app is named `<name_prefix>-cost-query`; `az ad app list --display-name <name_prefix>-cost-query` finds it.

Delete the Infinity data source and dashboard in Grafana if you no longer want them. Delete the **Infinity cost data source** alert rule group (folder **AI observability alerts**, under **Alerting**) first or at the same time: once the data source or the service principal is gone the rule's query fails, and the rule fires on every evaluation until it is removed. With Terraform the rule group is destroyed together with the data source.

### Moving from the earlier manual setup

Earlier versions asked you to create the app registration and secret with `az ad` commands and pass their IDs in. Those inputs are gone.

1. Delete `costInfinityClientId` and `costInfinityServicePrincipalObjectId` (Bicep), or `cost_infinity_client_id` and `cost_infinity_service_principal_object_id` (Terraform), from your parameter and variable files. They are no longer accepted: Bicep rejects an undeclared parameter, and Terraform only warns about an undeclared variable in a `.tfvars` file, so remove them rather than leave them.
2. Redeploy. A **new** app registration, service principal and secret are created, and the Grafana data source is updated to use them. The `subscription` scope switches from the built-in Cost Management Reader to the single-action custom role; Terraform removes the old Reader assignment, while Bicep leaves it in place.
3. After the dashboard works, delete the old hand-made app (`az ad app delete --id <old-app-id>`) and, for Bicep, its leftover Cost Management Reader assignment.

### Things to know before you enable it

- **It is a shared identity, not per-viewer access.** Every viewer of the dashboard sees what the principal can read. Anyone who can edit queries on the Infinity data source (Grafana Editor and Admin) can run any Cost Management query the principal's role allows. The role allows only `Microsoft.CostManagement/query/read`, but that can expose all cost data at the scope, so use `resourceGroupManaged` where you can and restrict those roles.
- **The secret lives in Grafana, and in Terraform state.** Grafana never returns it through its API, but Terraform records it in the state of both stages. Supply the Grafana stage's copy as `TF_VAR_cost_infinity_client_secret`, never in a `.tfvars` file, and protect the state like a credential. The Bicep path keeps it out of the parameters, outputs and deployment history: the helper mints it, or reads `AI_OBSERVABILITY_COST_CLIENT_SECRET` or `-CostInfinityClientSecret`, and sends it only to Grafana.
- **Creating the principal needs Entra rights.** See [what the deployer needs](#set-it-up). If you cannot get them, create the secret out of band and use the Bicep override, or leave the feature off.
- **Bicep cannot preview the principal.** What-if and deployment stacks are not supported for Microsoft Graph resources, so the app registration is not shown in a preview. Microsoft Graph replication can also delay the first deployment; rerun if it fails once.
- **Expiry silently breaks the panels, and the health check will not tell you.** The panels fail with an authentication error (`AADSTS7000222` expired, `AADSTS7000215` wrong or revoked), but the data source's **Save & test** keeps reporting "Health check successful" with a wrong, revoked or expired secret, so it cannot be used to check the secret. The repo therefore ships a Grafana alert rule that fires when the Cost Management query fails (see [Get alerted when the secret fails](#get-alerted-when-the-secret-fails)). It detects a failure; it cannot warn before expiry, because Grafana cannot see the credential's end date, so still set a calendar reminder for the end date.
- **A cached token can hide a bad secret for up to an hour.** Grafana keeps using the access token it already has after the secret is revoked or expires. The failure appears when the token expires (about an hour) or when the data source is updated, so a rotation can look fine until later. Always confirm after you update the data source.
- **The Query API is throttled.** It returns HTTP 429 often. Infinity does not retry, so a panel can fail intermittently on refresh. Reload after a short wait. The daily panel is capped at 31 days per query (the API's limit for daily granularity), so the dashboard's time range should stay within a month.
- **It is live, not historical storage.** Nothing is kept outside Cost Management. If you need long history, set up a Cost Management export in the portal.
- **A continuation link fails the query** instead of silently showing a partial total.
- **Plugin installation by ARM is a preview feature** (`grafanaPlugins` on the Grafana workspace). If it is unavailable in your tenant, install **Infinity** from the Grafana plugin catalog and rerun; the helper stops with that instruction when the plugin is missing.

### Get alerted when the secret fails

The Infinity dashboard deployment also creates one Grafana-managed alert rule, **Infinity cost data source cannot query Cost Management**, in the folder **AI observability alerts** (rule group **Infinity cost data source**). It runs the dashboard's own month-to-date cost query, reduced to a single row count, so it checks the same scope, URL and credential the panels use. A failed query (expired, revoked or wrong secret, a removed Cost Management role, a network error) puts the rule in the `Alerting` state. An empty result counts as healthy, and the threshold on the count can never be reached, so the size of your bill never triggers it.

| Setting | Terraform variable | Bicep parameter | Default |
|---|---|---|---|
| Create the rule | `enable_cost_infinity_alert` | `enableCostInfinityAlert` | `true` |
| Evaluation interval (minutes, 5-1440) | `cost_infinity_alert_interval_minutes` | `costInfinityAlertIntervalMinutes` | `60` |
| Failure must last this long before it fires (minutes, 0-1440) | `cost_infinity_alert_pending_minutes` | `costInfinityAlertPendingMinutes` | `60` |

The defaults evaluate hourly and fire when two evaluations in a row fail. That is deliberate: the Cost Management Query API throttles with HTTP 429 and Infinity does not retry, so a single failure should not page anyone. Lowering the interval makes the rule hit that API more often. The minimum is 5 minutes so you can test the rule without waiting an hour. Setting the pending period to `0` fires on the first failed evaluation.

**You must add a contact point.** The repo creates the rule, not a way to notify anyone. In Azure Managed Grafana the default notification policy sends to a contact point named `empty` that has no integration, so a firing rule is visible in **Alerting** but nothing is delivered until you act. SMTP is also off by default, so an email contact point needs SMTP configured first; a webhook, Teams, Slack or similar contact point works without it. Create the contact point, then add a notification policy that routes the rule's labels to it:

- `component = cost-infinity` (the rule always carries this label)
- `severity = warning`
- `managed_by` is `azure-ai-observability-terraform` or `azure-ai-observability-bicep-v1`, depending on how it was deployed

**Ownership and removal.** Terraform owns the rule group it creates and removes it on `terraform destroy` or when the switch is false. The Bicep helper owns a rule group only if every rule in it carries its `managed_by` label; it stops before changing anything if a group with the same name belongs to someone else. Because the helper never deletes Grafana resources, setting `enableCostInfinityAlert` to false stops creating the rule but does not remove one that already exists; delete the **Infinity cost data source** group in **Alerting** yourself. A rule is created only together with the Infinity dashboard.

**What it will not do.**

- It does not warn before the secret expires. It fires after something has already failed, so keep the calendar reminder.
- Grafana keeps using the access token it already has, so a secret that is revoked or expires in Entra can take up to about an hour (the token lifetime) to surface through the rule. That delay is inferred from the cached-token behavior described above; it was not measured through the rule. Updating the data source, which a rotation does, makes Grafana request a new token, and a wrong secret written that way fired the rule at the next evaluation.
- A transient 429 fails the evaluation it hits (seen once in a preview evaluation). With the default pending period that only fires if failures continue for the whole period; how often real scheduled evaluations hit a 429 was not measured.

### Alternatives that were checked

Checked for a secretless option on 2026-11; none was found at lower cost:

- **Resource Graph `costresources`.** Tested live; the table is rejected (`DisallowedLogicalTableName`).
- **Infinity with managed identity or workload identity.** Infinity 4.1.6, the latest release at the time, has neither, and its documented Azure example uses a client secret.
- **Will federation arrive?** Not visibly planned, and no timeline exists. The Infinity maintainer's pull request for Azure managed and workload identity ([#785](https://github.com/grafana/grafana-infinity-datasource/pull/785)) was closed unmerged in 2026-03, as was a generic OAuth2 token-exchange request ([#1569](https://github.com/grafana/grafana-infinity-datasource/pull/1569)). Infinity 4.1.0 did add AWS IAM role authentication, so cloud identity is possible, but only for AWS so far, and there are no open Azure issues or pull requests. Grafana's Azure SDK has managed- and workload-identity credentials, but Grafana only forwards its `[azure]` settings to a listed set of plugins (Azure Monitor, Data Explorer, Prometheus, MSSQL, Databricks), and Infinity is not one of them. A secretless Infinity on Azure would need Infinity to add Azure authentication, Grafana to forward the settings to it, and Azure Managed Grafana to enable that. [Issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) stays open to revisit it.
- **Log Analytics `externaldata`.** Managed-identity access is documented only for ADX and Fabric, and Log Analytics cannot reach private storage.
- **Cost export to Log Analytics.** Exports go only to Storage (or Fabric).
- **Not built, not tested:**
  - **Infinity `oauthPassThru`**, which would forward each viewer's own token (per-viewer authorization). Nothing documents a forwarded token with an Azure Resource Manager audience in Azure Managed Grafana.
  - **Synapse serverless SQL** over Cost Management export storage. It is billed per TB scanned (pennies) and can read firewall-protected storage with its managed identity, so it is the most promising secretless alternative. It adds a workspace and T-SQL login setup, Managed Grafana cannot reach Synapse over a managed private endpoint (so it would use a public Entra-only endpoint), and managed-identity authentication from Grafana's SQL data source is unverified.
  - **Azure SQL** `OPENROWSET`, judged fragile (no Parquet; CSV needs a format file).

### What has been validated

**Principal, secret and role created in code, verified live** in two further throwaway deployments (tagged resource groups, torn down afterwards). The deployer was a Global Administrator and subscription Owner, so the minimum Entra and Azure rights listed under [Set it up](#set-it-up) were **not** isolated.

- **Bicep.** The real `infra\main.bicep` with `enableCostInfinity = true` and `costInfinityScope = 'subscription'` succeeded. It created a single-tenant (`AzureADMyOrg`) app registration with **no secrets**, its service principal with the deployer as owner, and one custom role whose only action is `Microsoft.CostManagement/query/read`, assigned to the principal at subscription scope. The principal had no other assignment, direct or inherited.
- **Helper-minted secret.** As the deployer, `az ad app credential reset --append` (the helper's command) minted a secret for that app. The principal used it to sign in and run a Cost Management month-to-date query at subscription scope. This shows that a role with **only `query/read`** is enough at subscription scope, and that the app's owner can mint the secret. The provisioning helper itself was not run end to end against Grafana in this deployment; its flow is covered by unit tests with mocked `az` and Grafana calls.
- **Read-only.** With that token, reading the resource group directly returned HTTP 403, and listing resource groups, resources and role assignments returned empty results.
- **Terraform.** The Azure stage (pre-created resource group, `subscription` scope, no monitored accounts) applied 14 resources, including the app registration, service principal, secret and role, and a second plan showed no changes. The secret from the sensitive `cost_infinity_client_secret` output signed in and ran the same query, with a lifetime of the 90-day rotation plus the 30-day overlap. `terraform destroy` followed by deleting the resource group left no app registration or custom role behind. The Grafana stage was not re-run for this change; its Infinity data source was verified earlier, with a hand-made principal.
- **Not verified:** `resourceGroupManaged` with the new principal (the role and assignment modules are unchanged, and the Terraform change is covered by mock-provider tests), a deployer that is a service principal rather than a user (`deployer().objectId` is untested for that case), the Terraform rotation after 90 days, and Bicep what-if for Graph resources.

**Earlier validation, with a hand-made principal.** A throwaway deployment in a sandbox subscription used the real `scripts\deploy_bicep.ps1` with `resourceGroupManaged` scope and a temporary service principal created with `az ad` commands, which the repo no longer needs. The service principal, its secret and the resource group were removed afterwards.

**Verified live:**

- The `az ad` commands for creating the app, service principal and secret worked.
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

**Alert on a failing secret, verified live.** A prototype rule created through the provisioning API in the Terraform deployment above showed the mechanism: with a good secret it stayed `inactive`; after a bad secret was written it went to `firing` with `health=error` and the `AADSTS7000215` message within one evaluation; after the good secret was restored it cleared. The rule that ships with the repo ([issue #28](https://github.com/michael-rechani/azure-ai-observability/issues/28)) was then tested in a fourth throwaway deployment, with the evaluation interval and pending period both set to 5 minutes so the test was practical:

- **Terraform rule.** The Grafana stage created the folder and the rule group. The stored rule had the intended interval, pending period, no-data and error handling, and labels, and its query returned one numeric row-count frame. With a good secret it stayed `inactive` and healthy.
- **Failure, Terraform path.** Applying a wrong secret changed only the data source; the rule itself was untouched. At the first failed evaluation the rule went to `pending` with `health=error` (the pending period applies to error evaluations), and to `firing` at the second, with the `AADSTS7000215` message. Alertmanager listed one active alert with the expected labels and annotations.
- **Notification delivery.** Because the default contact point has no integration, a temporary Logic App with an HTTP trigger was created as a webhook contact point, with a notification policy that routed `component = cost-infinity` to it. A `firing` webhook arrived with the right labels and summary. After the good secret was restored through Terraform the rule cleared at the next evaluation and a `resolved` webhook arrived. The Logic App was a test receiver only and is not part of the repo. Email delivery was not tested.
- **Empty and non-empty results.** The cost query returned zero rows in this deployment. The rule evaluates the same way in both cases: with the query's row count overridden to 5 (the real URL and plugin still used) in a rule preview, the condition stayed false, so a result with data does not fire it.
- **Bicep helper.** A pre-existing rule group with the same name but a different `managed_by` label made the helper stop before any write, with a message naming the group and no data source or dashboard created. With the foreign group removed, the first run created the dashboards, the data source and the rule. A second run updated the same rule in place (still one rule, same UID), so the helper is idempotent. The rule it created then went through the same cycle as the Terraform one: healthy with a good secret, `pending` at the first failed evaluation and `firing` at the second after a wrong secret was applied with the helper, a `firing` webhook labelled `managed_by = azure-ai-observability-bicep-v1`, then cleared at the next evaluation after the good secret was restored, with a `resolved` webhook.
- **Teardown.** `terraform destroy` of the Grafana stage removed the rule group and folder, and none of the repo's data sources or dashboards remained.

**Not verified:**

- Rows for `microsoft.cognitiveservices/accounts`. The sandbox has no billed Azure AI cost, so the monitored group returned HTTP 200 with zero rows, which matched direct API calls.
- How the panels render in a browser, including the daily time series.
- Whether an in-place update of the Grafana workspace by the azurerm provider keeps the installed plugin. The Terraform stage reinstalls it if the `azapi` resource is replaced.
- How long Grafana keeps a cached token beyond the update that was tested (the token lifetime is about an hour).
- The alert rule on a real expiry (`AADSTS7000222`). The rule was exercised with a wrong secret (`AADSTS7000215`), not with a secret that expired on its own.
- The alert rule against real billed cost rows. The sandbox has none; the non-empty case was tested only by overriding the row count in a rule preview.
- How often real scheduled evaluations hit a transient 429, and whether the default pending period absorbs them in practice.
- Email delivery of the alert. SMTP is off in Azure Managed Grafana by default and was not configured.

## Direct Grafana queries and per-viewer access

**Short version:** Grafana's managed identity reads Azure Monitor, Log Analytics and Resource Graph natively, which is why those panels need no secret. For Cost Management, the tested Infinity plugin offers no managed-identity or federated-credential authentication, and the Azure Monitor data source's managed-identity proxy rejected the Cost Management request. Until a Grafana data source can do that without a stored secret, choose the [direct Infinity query](#direct-cost-management-queries-with-infinity-opt-in) (no extra resources, but a rotating client secret). Without it, billed cost stays in the Azure portal and the budget alerts.

Azure Managed Grafana can use a managed identity with [data sources that support it](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-authentication-permissions); that does not make the identity available to every REST plugin. A private workspace test used signed Infinity 4.0.0 on Grafana 12.4.13 with a temporary OAuth client-credentials service principal to query Cost Management directly. One actual-cost row and one amortized-cost row matched separate API queries for one account. The principal had a single-action cost-query role at its resource group. A direct subscription-scope API request was denied with `RBACAccessDenied`, and the corresponding Grafana query reported an upstream HTTP 401. This was a **shared client-secret identity**, not Grafana managed identity or per-viewer authentication. The test did not establish complete historical coverage, continuation handling, or production readiness.

The examined Infinity version did not expose a native managed-identity option for generic REST queries. Grafana's documented [Infinity Azure API example](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/examples/examples/azure/) also uses a client secret and a shared service identity, not each viewer's permissions. In the same private workspace, the built-in Azure Monitor data source's managed-identity resource proxy accepted a subscription-list control request but rejected the tested Cost Management POST as an unsupported path before authorization. The workspace identity had no cost role, so this is not a test of its Cost Management permissions or proof that every possible managed-identity integration is unavailable. Do not persist a user's access token as a production data-source credential.

Microsoft documents [federating an app registration with a user-assigned managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity) without an app secret. That general capability does not establish that the tested Grafana/Infinity configuration can perform the required token exchange; direct Grafana federation has not been demonstrated.

Microsoft recommends considering [Current User authentication](https://learn.microsoft.com/en-us/azure/managed-grafana/secure-azure-managed-grafana#identity-and-access-management) for supported data sources, and Grafana documents it for the [Azure Monitor data source](https://grafana.com/docs/grafana/latest/datasources/azure-monitor/configure/#current-user). Signing in to Grafana does not by itself grant access to Cost Management or Log Analytics, or establish that Infinity receives an Azure Resource Manager token. The upstream Current User provisioning guidance specifies `oauthPassThru: true` and `disableGrafanaCache: true` to forward credentials and prevent cached responses from exposing resources across users. Support for these settings and their behavior have not been verified in the target Azure Managed Grafana workspace.

In [upstream Grafana 12.4.13](https://github.com/grafana/grafana/blob/v12.4.13/pkg/services/login/authinfoimpl/store.go), the authentication store encrypts and persists OAuth access and refresh tokens. OAuth passthrough therefore does not imply that tokens exist only in memory. Restrict access to the authentication store and encryption keys, and verify Azure Managed Grafana's own storage, retention, and access controls before relying on this approach; those managed-service details have not been verified here.

Current User requires an interactive user for those queries; background alerting and reporting require a separately authorized identity or another approach. Upstream Grafana's documentation says enabling Current User also enables fallback service credentials at the instance level by default; whether and how Azure Managed Grafana exposes that setting is unverified. Explicitly review and test fallback credentials so a more-privileged shared identity is not silently substituted for a viewer's permissions. A shared data source does not automatically inherit each viewer's Cost Management permissions, and this repository's cost dashboards do not enforce per-viewer access.

For separately administered **group-based** access, Microsoft documents [Grafana Limited Viewer and component permissions](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-manage-access-permissions-users-identities), including data-source permissions. A possible design is a separate, narrowly scoped workload identity and data source for each access boundary, with explicit Grafana team grants. Azure Managed Grafana supports [only one managed identity per workspace](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-authentication-permissions#use-a-user-assigned-managed-identity), so separate identities would require an appropriate supported data-source authentication method or separate workspaces. This would not automatically mirror each person's Azure Cost Management permissions. Grafana's [data-source documentation](https://grafana.com/docs/grafana/latest/administration/data-source-management/#data-source-permissions) says a Viewer can query a data source beyond the queries shown on dashboards by default, and identifies data-source permissions as an Enterprise/Cloud feature. Verify availability for the target Azure Managed Grafana version and tier. Inherited or broader roles, Grafana administrators, and other data sources or workspaces with overlapping access must also be considered. This repository does not configure or validate such a boundary; real access, cache, background-query, and cost-completeness tests are required before relying on it.

A Lab attempt created two temporary Entra test users with no initial group memberships or Azure role assignments. The first user's normal interactive sign-in stopped at a security-information registration prompt; a separate temporary-user diagnostic reached the same prompt after password entry. No delegated token was obtained, and no two-user cost or Grafana authorization comparison ran. All temporary users were independently verified absent from active and deleted users; no MFA or tenant policies were changed. Passwords were generated in memory rather than stored in Terraform state.

A later manual attempt returned a delegated token, but the test stopped because one or more expected token claims did not match; the previous helper did not record which claim category failed. No Cost Management query or two-user comparison ran. A subsequent ownership-checked cleanup pass independently verified both temporary users absent from active and deleted items; no cost role or assignment was created during this attempt. A revised private helper reports only mismatched claim categories, not claim values. A subsequent retry was stopped at the user's request during browser sign-in, before any cost query or role assignment; both temporary users were independently verified absent. The revised diagnostics have synthetic coverage but have not been evaluated live.

A separate localhost test used Grafana OSS 12.4.13 and signed Infinity 4.0.0 with two PKCE-authenticated synthetic viewers and a synthetic backend that assigned each viewer a different scope. With `oauthPassThru: true` and `disableGrafanaCache: true` configured, each viewer received only its authorized row and was denied the other scope, including when identical queries were repeated in both viewer orders. Each repeated query reached the backend; a local Grafana user without an OAuth token was denied. After synthetic token expiration, both viewers refreshed their tokens and retained their respective restrictions. A deliberately failed refresh returned HTTP 401 without a successful backend query; the other viewer remained able to query. No fallback credential was configured for that passthrough data source. With a shared synthetic credential, both viewers could read both scopes. This did not test Entra, Cost Management, Azure Managed Grafana, an active query cache, real Entra token refresh, or background identity fallback; it does not establish production per-viewer isolation.

For an interactive alternative outside Grafana, [Azure Workbooks](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview#access-control) base access on the viewer's resource permissions, and their [Azure Resource Manager data source](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources#azure-resource-manager) supports POST requests without a manually supplied authorization header. A workbook querying Cost Management is a candidate for investigation, not a validated Grafana integration or a substitute for testing two users, billing scopes, continuation handling, and error behavior.

The [Cost Management exports](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports) to Blob Storage that Azure Data Explorer reads through external tables, queried through the [Azure Managed Grafana data source](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-connect-azure-data-explorer), is a secretless route that this repository implemented and has [removed](#migrating-from-the-removed-azure-data-explorer-export). A variant using [Azure Data Explorer ingestion](https://learn.microsoft.com/en-us/azure/data-explorer/ingest-data-event-grid-overview) through Event Grid, or Current User authentication to Data Explorer, was **not implemented or tested**. Exports support resource-group scopes; the export-to-storage and Event Grid ingestion paths can be configured with managed identities, and the Grafana data source supports both managed identity and Current User. The Event Grid data connection defaults to key-based authentication unless managed identity is explicitly configured. This is an exported-data pipeline, not a direct Cost Management query, and adds Data Explorer, storage and associated cost.

An export can contain multiple partitions and a manifest, and daily files can contain revised month-to-date data or overwrite earlier files. A design must verify every partition, reconcile revisions and retries, and publish only complete runs rather than blindly ingesting each blob as an independent cost total. Current User authenticates to Data Explorer using the viewer's **Data Explorer** permissions; it does not automatically inherit their Cost Management permissions. Data Explorer [row-level security](https://learn.microsoft.com/en-us/kusto/management/row-level-security-policy?view=azure-data-explorer) is a possible separate boundary, but cannot be configured on external tables. Per-viewer isolation, caching, background identities, network paths, and billing coverage would all require validation before relying on it.

A separate signed-in Azure CLI **user** comparison queried actual cost for the same account over 90 days, once as a single request and again in four non-overlapping windows of at most 27 days. Each approach returned the same one date/currency row and amount, without a continuation. This is a narrow comparison for one account and billing context, not proof of complete history, amortized history, pagination, or Grafana's handling of other windows.

The original [JSON API plugin](https://grafana.com/docs/plugins/marcusolsson-json-datasource/latest/) is deprecated, lacks OAuth2/JWT authentication and backend alerting, and is scheduled to lose support on February 1, 2027. Local Infinity tests also matched a single-page actual-cost query to the API using an Azure CLI user token, but did not establish managed-identity or real two-user isolation. Some tested pagination configurations returned incomplete synthetic results without an error; live continuation remains unverified.

Treat the Infinity route as the supported option unless an alternative demonstrates least-privilege authentication, complete results and explicit error handling. Per-viewer access also needs two independently authenticated users with different effective permissions, including cold and warm caches, token refresh, and the identity used for background queries. Controlled test users can exercise that boundary but do not validate real-human workflows. See [issue #4](https://github.com/michael-rechani/azure-ai-observability/issues/4) for test details and remaining checks.

### Native estimate from Azure Monitor metrics (no secret)

Grafana's managed identity can already read per-model token metrics (`InputTokens`, `OutputTokens`) and `FoundryModelEstimatedCost` from Azure Monitor. A read-only comparison against Cost Management actual cost covered one existing pay-as-you-go Foundry account: five usage days and three models. The subscription's other two accounts had no estimate data and were not compared. It found:

- **`FoundryModelEstimatedCost` is not a usable spend figure.** It was close on the smallest days but about 2x below billed for the small models, and about 14x below (roughly 7% of billed) for the largest model on its two heavy days. It also reports no unit.
- **Output tokens × the model's per-1M output price reproduced the billed output charge** for every model-day compared. Input tokens priced the same way reproduced the billed input charge on days without prompt caching.
- **Prompt caching breaks the input side.** `InputTokens` includes cached tokens, which bill at a much lower rate. For the largest model about three quarters of input tokens were cached. No usable per-model cached-token metric was found: `cacheReadInputTokens` had no data and the cache-match-rate average did not match the billed split. Pricing all input as uncached overstated total cost by roughly 30–50% on those days.
- **Not covered:** provisioned (PTU) hourly charges, hosted-agent compute, negotiated or discounted rates, tax, and later price changes.

The Foundry overview dashboard now has a table built on exactly this: **Estimated pay-as-you-go token cost by model (list price, not billed)**. It is a native, secretless **estimate**. The Azure portal, the budget alerts and the opt-in Infinity dashboard remain the source of billed cost. The reconciliation above is one account over a few days, so repeat the comparison on your own accounts before relying on the panel.

#### How the panel works

- **Tokens.** `InputTokens` and `OutputTokens` (Total) split by the `ModelName` dimension for the account selected on the dashboard, read by Grafana's managed identity through the Azure Monitor datasource.
- **Prices.** A `datatable` in [`queries/model-prices.kql`](../queries/model-prices.kql): USD per 1M tokens, Global Standard, `eastus2`, from the Azure Retail Prices API. It is read through the Azure Monitor datasource's Log Analytics query against the dashboard's **Telemetry workspace ARM ID**, so that variable must hold a workspace Grafana can query. The query reads no tables.
- **Join.** Grafana transformations join tokens to prices on the model name and multiply. There is no secret or extra resource.

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

The Infinity dashboard reports **actual cost** for Cognitive Services accounts (Foundry, Azure OpenAI and Azure AI Services) as Cost Management reports it, in billing currency, with currencies kept separate. It does not show amortized cost. It is not an invoice, total subscription spend, a per-deployment or PTU price, or a reservation-coverage report; reservation purchases, shared or billing-scope charges and tax can be omitted. Compare the totals with the Azure portal before relying on them.

Billing can arrive late or be revised, so recent days can change. No rows means **no cost reported yet**, not zero cost. Validate coverage and billing behavior with your own agreement before making financial decisions.

The Infinity principal uses a custom role with the single action `Microsoft.CostManagement/query/read` at both scopes, not the built-in [Cost Management Reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/management-and-governance#cost-management-reader), which also includes `Microsoft.Support/*` and so is not strictly read-only. Read-only here still means it can read all cost data available at its scope: Viewer access and dashboard filters do not enforce the viewer's own Azure cost permissions. Review permissions for each customer, including permissions left over from an earlier deployment (for example a Cost Management Reader assignment from the earlier manual setup).

A separate [investigation](https://github.com/michael-rechani/azure-ai-observability/issues/4) verified that a temporary managed identity with only `Microsoft.CostManagement/query/read` on one resource group could query that group's actual and amortized costs in one subscription. Queries at subscription scope and another resource group, and a query by an unassigned identity, were denied. That test did not cover Grafana or other billing environments, so test any custom role and billing agreement before relying on it. The Infinity-specific live results are under [what has been validated](#what-has-been-validated).

## Troubleshooting

- **Infinity panels fail with an authentication error.** `AADSTS7000222` means the client secret expired and `AADSTS7000215` means it is wrong or revoked. The data source's **Save & test** can still report healthy, so check the panels. See [Rotate or remove the secret](#rotate-or-remove-the-secret) and [Get alerted when the secret fails](#get-alerted-when-the-secret-fails).
- **An Infinity panel fails once, then works.** The Cost Management Query API returns HTTP 429 under load and Infinity does not retry. Reload after a short wait.
- **The Infinity dashboard is empty.** Cost Management can lag, and the role at the configured `costScope` must allow the query. An empty result is not zero spend.
- **Role changes just made.** Azure role propagation can delay the first successful query.

