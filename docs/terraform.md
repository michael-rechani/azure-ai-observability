# Terraform deployment

The two Terraform roots use **native AzureRM and Grafana provider resources**:

1. `terraform/azure` creates Managed Grafana, Log Analytics, Application Insights, scoped RBAC, an action group, and per-account PTU metric alerts. It can also create the monitoring resource group, assign Grafana Viewer or telemetry-publisher access, and provision an optional budget and the opt-in billed-cost resources described in [billed cost options](costs.md).
2. `terraform/grafana` creates the Azure Monitor managed-identity data source and dashboards through the Grafana data-plane API, with optional Business overview and cost dashboards.

The Grafana stage needs an existing endpoint and a propagated Grafana Admin role, so deploy it after the Azure stage. **No separate Python installation or local sample-data preview is required to deploy.** These configurations do **not** create Foundry agents or model deployments, set up instrumentation in existing applications, deploy an evaluator, or resize PTUs. The Terraform path has been applied live in an isolated Lab subscription (both stages, including the Grafana data source and its dashboards, with an idempotent re-plan of the Grafana stage). That run predates the removal of the optional cost pipeline and found and fixed two defects (see [live findings](#live-findings)). Start in nonproduction and run the [live acceptance checklist](setup.md#acceptance-checklist) afterward.

## Before you start

- Terraform 1.7+ and Azure CLI. These examples use PowerShell. Python 3.12+ is optional for the repository's offline tests and dashboard generators; Terraform mock tests require Terraform 1.11+.
- A monitoring resource group in a supported region, either created by Terraform or already existing. The caller needs creation and role-assignment permissions at the monitoring resource group and the specified account/workspace scopes; creating a resource group also requires subscription-level permission.
- Existing Foundry/OpenAI accounts. All monitored accounts must be in the **same subscription** as this Terraform Azure stage. Deploy separate stacks for other subscriptions. Existing telemetry workspace IDs can be specified separately; permissions must exist at those scopes.
- The identity that runs the Grafana stage needs the Grafana Admin role; use its Entra **object ID** as `grafana_admin_object_id`, or assign it separately. The Azure subscription role alone is not Grafana data-plane access.
- The environment must reach both Azure APIs and the Grafana endpoint. Public endpoints are enabled by this starter; private networking requires a separate design.
- For the opt-in Infinity route, the identity that runs the Azure stage also needs permission to create app registrations in Microsoft Entra (for example Application Developer or Application Administrator) and to create role definitions and assignments at the scope: subscription scope for the default `subscription` setting, or each monitored group for `resourceGroupManaged`. Owner or User Access Administrator covers the Azure side.

**State contains sensitive information.** AzureRM stores Application Insights connection strings and workspace keys in state even though they are not output here, and email addresses/resource metadata may also appear. Neither root configures a backend by default. Follow the [remote-state walkthrough](getting-started.md#prepare-remote-state-for-terraform) to configure separate encrypted, access-controlled, locked state blobs before real use. Local state is for evaluation only; never commit state, plans, credentials, or real `.tfvars`. Treat Terraform debug logs and plan files as sensitive.

**Choose Terraform or Bicep for a given deployment.** They use different state/ownership and some different resource names. Running both against the same resources is not migration and can create duplicates, conflicting role assignments, unexpected costs, or destructive changes. Migrate by planning and importing existing resources explicitly; do not simply apply the other configuration.

## 1. Azure resources

Copy `terraform/azure/example.tfvars.example` to `terraform/azure/local.tfvars`; replace all placeholder values. The example sets `create_resource_group = true` for a new group. Set it to `false` to use an existing group; the variable defaults to `false` for compatibility with existing deployments. Account IDs are full ARM resource IDs; `ptu_deployments` are actual provisioned deployment names, not model names. Use an empty set for an account without PTUs. The example creates an alert email action group; the address is stored in Terraform state and Azure.

Optionally list existing application identities to grant **Monitoring Metrics Publisher** on the new Application Insights resource. Use Entra **object IDs**, not application/client IDs; omit the map if another process manages these permissions:

```hcl
telemetry_publisher_principals = {
  agent = {
    principal_id   = "00000000-0000-0000-0000-000000000000"
    principal_type = "ServicePrincipal" # Also accepts User or Group.
  }
}
```

The role enables authenticated ingestion; it does not instrument the application or connect a Foundry project. Configure the supported tracing/exporter for your agent separately as described in [telemetry](telemetry.md). Use stable map keys and import any pre-existing identical role assignment rather than creating a duplicate.

### Business-user access

Each customer can deploy this stack in its own Azure environment and optionally give an existing Microsoft Entra group read-only **Grafana Viewer** access. Set the group's **object ID** in `local.tfvars`; the map is empty by default:

```hcl
grafana_viewer_principals = {
  business_readers = {
    principal_id   = "00000000-0000-0000-0000-000000000000"
    principal_type = "Group"
  }
}
```

Individual Entra `User` and `ServicePrincipal` identities are supported too; `Group` is the default type. Use stable map keys and import an existing identical assignment rather than duplicating it. Share the Azure stage's `grafana_endpoint` output after dashboards are deployed. Viewers sign in through Entra and can see the existing dashboards without Azure portal access; Azure Logs trace links may require separate permissions.

**Viewer means read-only, not data isolation.** The Azure Monitor data source queries with Grafana's managed identity, so a viewer can potentially query data beyond the panels they see. Do not rely on dashboard filters or folder visibility to protect sensitive traces or separate customers. Scope the managed identity's access to appropriate data, and use separate deployments/data boundaries where needed. A user who also has a stronger Grafana role retains that access. See [Grafana data-source security](https://grafana.com/docs/grafana/latest/administration/data-source-management/).

Azure Managed Grafana also documents [Grafana Limited Viewer](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-manage-access-permissions-users-identities#learn-about-grafana-roles) with explicit component permissions; it is unavailable on Grafana v9. This starter does not configure that role or those permissions. Verify workspace feature availability and inherited access before using it. Restricting access to a data source does not make its shared identity act as the viewer or enforce per-user Azure permissions within that data source.

**Resource group ownership is a lifecycle decision.** Do not toggle `create_resource_group` on an existing stack without a deliberate state migration and reviewed plan. Changing it from `true` to `false` without removing the resource from Terraform state can plan deletion of the entire resource group and its contents; changing from `false` to `true` for an existing group requires import. A Terraform-managed resource group may also be deleted on destroy.

Discover metric definitions and confirm dimensions before enabling alerts as described in [metric discovery](setup.md#metric-discovery). To provision access first, set `enable_ptu_alerts = false`, then enable after verification. Account map keys must be stable; renaming one changes its Terraform addresses.

Agent failure-rate, retained-span p95 latency, and heartbeat rules are opt-in (`enable_agent_alerts = true`) and always target the **new monitoring workspace**, not an existing dashboard telemetry workspace. Confirm the `AppRequests` and `AppDependencies` schemas, operation name, agent property, run success semantics, sampling, ingestion cap, and traffic expectations there before turning them on. Defaults are a minimum of 20 sampled runs per 10 minutes, a 10% failure-rate threshold, 5-second p95 threshold, and at least one run per 15-minute heartbeat window. Tune these thresholds to your own SLO and traffic profile; the heartbeat can be noisy for intermittent workloads.

An optional monthly Azure Cost Management budget is disabled by default (`monthly_ai_cost_budget_amount = 0`). To enable it, enter a positive amount in subscription billing currency and set `cost_budget_start_date` and `cost_budget_end_date` as UTC `YYYY-MM-DDT00:00:00Z` values. It includes only the configured monitored AI account resource IDs and sends the existing action-group email at `cost_budget_threshold_percent` (80% by default). This is an alert, not a hard cap; billing data can lag, and account-scope budgets are not PTU-deployment- or reservation-specific.

### Optional direct cost queries with Infinity

The billed-cost path: Grafana queries the Cost Management Query API directly through the Infinity plugin, with no cluster or storage. **It is not secretless.** Infinity signs in as a service principal with a client secret that Grafana stores, and **both stages' Terraform state will contain that secret**. Read [the trade-offs](costs.md#direct-cost-management-queries-with-infinity-opt-in) first.

Terraform creates the principal for you (azuread provider): an app registration and service principal named `<name_prefix>-cost-query`, a rotating client secret, and a custom role whose **only action is `Microsoft.CostManagement/query/read`**. In the Azure stage's `local.tfvars`:

```hcl
enable_cost_infinity               = true
cost_infinity_scope                = "resourceGroupManaged" # Or "subscription"; both use the same single-action role
cost_infinity_secret_rotation_days = 90                     # 7 to 300; the old secret stays valid 30 more days
```

Terraform installs the Infinity plugin on the Grafana workspace through `azapi` (`grafanaPlugins`, a preview property) and assigns the role at the subscription or on each monitored resource group. In the Grafana stage, enable the dashboard and pass the Azure stage's outputs. Give the secret through the environment, never a `.tfvars` file:

```powershell
$env:TF_VAR_cost_infinity_client_secret = terraform -chdir=terraform\azure output -raw cost_infinity_client_secret
terraform -chdir=terraform\azure output -raw cost_infinity_tenant_id
terraform -chdir=terraform\azure output -raw cost_infinity_client_id
terraform -chdir=terraform\azure output -raw cost_infinity_scope
```

Set `enable_cost_infinity_dashboard = true`, `cost_infinity_tenant_id`, `cost_infinity_client_id` and (optionally) `cost_infinity_scope` in the Grafana stage's `local.tfvars`. Terraform then creates the Infinity data source (uid `ai-observability-cost-infinity`, client-credentials OAuth, the secret held only in the data source's secure data), the `azure-ai-costs-infinity` dashboard and an alert rule, **Infinity cost data source cannot query Cost Management**, that fires when the cost query fails (for example after the secret expires). A missing tenant ID, client ID or secret fails the plan.

The identity that runs the Azure stage needs permission to create app registrations in Microsoft Entra and to create role definitions and assignments (see [what the deployer needs](costs.md#set-it-up)). To rotate, run `terraform apply` on the Azure stage after the rotation period and then the Grafana stage again; nothing applies on its own.

The alert rule is on by default. Tune or disable it with `enable_cost_infinity_alert`, `cost_infinity_alert_interval_minutes` (5-1440, default 60) and `cost_infinity_alert_pending_minutes` (0-1440, default 60). Terraform creates the rule, not a way to notify anyone: add a Grafana contact point and a notification policy that routes `component = cost-infinity`, because Azure Managed Grafana's default contact point has no integration. See [Get alerted when the secret fails](costs.md#get-alerted-when-the-secret-fails).

**This path has been applied live** in throwaway deployments (see [what has been validated](costs.md#what-has-been-validated)). The Azure stage, including the app registration, secret and single-action role, was applied, re-planned with no changes and destroyed with the principal in code. An earlier deployment also applied the Grafana stage with a hand-made principal: the `azapi` resource installed the Infinity plugin, the role limited queries to the monitored resource group, all four panels returned HTTP 200 through Grafana, and rotating the secret changed the data source in place. The monitored group had no billed Azure AI cost, so no panel returned rows in that run. If an in-place update of the Grafana workspace removes the plugin, the `azapi` resource is replaced and reinstalls it on the next apply. Rotate the secret as described in [Rotate or remove the secret](costs.md#rotate-or-remove-the-secret) and reapply the Grafana stage.

From the repository root in PowerShell:

```powershell
az login
az account set --subscription "<monitoring-subscription-id>"
terraform -chdir=terraform\azure init
terraform -chdir=terraform\azure plan -var-file=local.tfvars
# Only after inspecting the plan and confirming costs:
terraform -chdir=terraform\azure apply -var-file=local.tfvars
terraform -chdir=terraform\azure output
```

Deployment may fail for lack of resource/role assignment permissions, unsupported Grafana version, unavailable metric dimensions, or restricted network access; correct the issue rather than bypassing metric validation.

## 2. Configure the Grafana stage

Copy `terraform/grafana/example.tfvars.example` to `terraform/grafana/local.tfvars` and replace its examples. Get the endpoint and monitoring workspace ARM resource ID from the first stage:

```powershell
terraform -chdir=terraform\azure output -raw grafana_endpoint
terraform -chdir=terraform\azure output -raw workspace_resource_id
```

In the Grafana `local.tfvars`, set `grafana_endpoint`, `subscription_id`, and `dashboard_defaults.monitoring_workspace_resource_id` to those real values. Set `foundry_account` and `ptu_account` to the actual account resource-group names, account names, and **account regions**, which can differ from the monitoring region. Set `ptu_account.deployment` to a real provisioned deployment name. The example file has all of these fields.

Terraform sets the checked-in dashboards' initial controls from `dashboard_defaults` when it provisions them; no generated local JSON or Python is needed. Its subscription comes from the Grafana stage's `subscription_id`. Dashboard controls can still be changed after deployment. If an account block is omitted, that dashboard retains the source JSON's existing values, which are placeholders in the checked-in files.

By default, agent dashboards use the monitoring workspace. To use an **existing telemetry workspace** instead, add its full ARM ID as `dashboard_defaults.telemetry_workspace_resource_id` and add it to `existing_telemetry_workspace_ids` in the Azure stage so Grafana gets Log Analytics Reader access. The workspace ARM ID is not a workspace GUID or Application Insights ID.

Set `enable_business_overview = true` in the Grafana stage to also provision the Business overview dashboard (off by default). It shows observed agent activity, failure rate and PTU signals side by side without calculating an overall health score, and it has no cost panels, so it needs only the agent telemetry workspace (`telemetry_workspace_resource_id`, or `monitoring_workspace_resource_id` when that is not set). It replaces the former `enable_cost_dashboard`; the cost pipeline variables `enable_cost_pipeline`, `cost_query_scope` and `cost_lookback_days` no longer exist (see [migrating](costs.md#migrating-from-the-removed-cost-collector)). The separate [Bicep path](bicep.md) can provision the same dashboard (`enableBusinessOverview`) without Terraform.

For advanced customization, `dashboard_directory` can point at other dashboard JSON files. Explicit `dashboard_defaults` override matching textbox values in those files; Terraform rejects a configured default if its target textbox is missing. The optional Python generator is for maintaining or customizing JSON outside this deployment flow.

## 3. Deploy the Grafana data source and dashboards

Terraform's Grafana provider receives an **Entra access token** in its `GRAFANA_AUTH` environment variable. To avoid sending this token to an unrelated host, the stage accepts only public `*.grafana.azure.com` HTTPS endpoints. Grafana's separate Azure Monitor data source uses the Grafana managed identity to query Azure; no API key or client secret is enabled. The token must be issued for `https://dashboard.azure.com` and the caller must have Grafana Admin:

```powershell
$env:GRAFANA_AUTH = az account get-access-token --resource https://dashboard.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $env:GRAFANA_AUTH) { throw "Could not obtain a Grafana Entra token" }
terraform -chdir=terraform\grafana init
terraform -chdir=terraform\grafana plan -var-file=local.tfvars
# Only after inspecting the plan:
terraform -chdir=terraform\grafana apply -var-file=local.tfvars
Remove-Item Env:\GRAFANA_AUTH
```

Never print or commit the token, store it in `.tfvars`, or enable verbose provider logs in an untrusted environment. Tokens expire; renew before running a later plan or apply. Wait for role propagation after the Azure stage. Automation can acquire a short-lived token via a managed identity/service principal with the appropriate Grafana role. [Microsoft's data-plane authentication guidance](https://learn.microsoft.com/azure/managed-grafana/how-to-authenticate-data-plane-api) describes the audience and authentication alternatives.

Dashboard UIDs and data-source UID are stable. The stage does not silently overwrite an unmanaged dashboard with the same UID: resolve conflicts by importing or selecting separate UIDs after review. If the Azure Monitor data source name or UID already exists, import it or use a distinct name/UID. Dashboard UI edits may be reconciled or overwritten by a future Terraform apply; manage the JSON as the source of truth.

This stage creates a data source using `azureAuthType=msi`; it does not broaden Grafana's Azure permissions. The Foundry resource inventory remains RBAC-filtered. In a live Lab run the stage created one data source and its dashboards, and a second plan reported no changes. The Entra token and the `Grafana Admin` role were enough; no API key or client secret was created.

## Live findings

An end-to-end Lab deployment of both stages surfaced two Terraform defects, now fixed, that the mock tests could not catch:

- **Storage data-plane lookups.** The `azurerm` provider reads the storage account's data plane after creating it. That read fails when a policy or a network rule blocks data-plane access, which broke `apply` for a storage account in that run. `terraform\azure\versions.tf` sets `storage { data_plane_available = false }` so the provider uses only the management plane; the deployment does not need data-plane access to the account.
- **Role-assignment scope casing.** Azure reads a resource-group scope back as `resourceGroups`, but a managed role assignment used the lower-cased deduplication key (`resourcegroups`) as its scope. Terraform saw a different value on every plan and replaced the assignment each time. The key stays lower-case for deduplication and stable role names, the assignment scope now uses Azure's canonical casing, and a test asserts the mapping.

**Destroy stops at a Terraform-created resource group.** The Lab `terraform destroy` removed every managed resource, then failed on the resource group itself (`create_resource_group = true`). Azure creates a *Failure Anomalies* smart-detector alert rule in the group when Application Insights is created. Terraform does not manage it, so the `azurerm` provider's `prevent_deletion_if_contains_resources` check refuses to delete the group. That check is a safeguard, so the configuration leaves it on. Delete the group yourself once you have confirmed nothing else you care about lives in it:

```powershell
az group delete --name <resource-group> --yes
```

## Validation and lifecycle

Without logging in to Azure or deploying:

```powershell
terraform fmt -check -recursive .\terraform
terraform -chdir=terraform\azure init -backend=false -input=false
terraform -chdir=terraform\azure validate
terraform -chdir=terraform\azure test
terraform -chdir=terraform\grafana init -backend=false -input=false
terraform -chdir=terraform\grafana validate
terraform -chdir=terraform\grafana test
```

Mock tests do not contact Azure/Grafana and cannot prove that provider authentication, region/SKU availability, metric dimensions, dashboards, KQL, billing permissions, or alert delivery work in your environment. Keep the provider lock files committed and use the same locked versions in automation.

When updating providers, refresh the lock files for the platforms used by CI and contributors before committing them:

```powershell
terraform -chdir=terraform\azure providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_amd64 -platform=darwin_arm64
terraform -chdir=terraform\grafana providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_amd64 -platform=darwin_arm64
```

**Removal can delete data:** removing resources from configuration or running `terraform destroy` can remove dashboards, alerts, Grafana, telemetry resources, and stored telemetry. Review every plan and your retention policies. If retiring the entire stack, handle the Grafana stage first while the endpoint remains reachable, then the Azure stage. Existing model deployments and target account resources are not Terraform-managed.
