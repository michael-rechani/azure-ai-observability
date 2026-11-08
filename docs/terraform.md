# Terraform deployment

The two Terraform roots use **native AzureRM and Grafana provider resources**:

1. `terraform/azure` creates Managed Grafana, Log Analytics, Application Insights, scoped RBAC, an action group, and per-account PTU metric alerts. It can also create the monitoring resource group, assign Grafana Viewer or telemetry-publisher access, and provision a cost pipeline that is Function-free by default (GitHub Actions OIDC to a managed identity) with an optional Azure Function.
2. `terraform/grafana` creates the Azure Monitor managed-identity data source and dashboards through the Grafana data-plane API, with optional cost and business overview dashboards.

The Grafana stage needs an existing endpoint and a propagated Grafana Admin role, so deploy it after the Azure stage. **No separate Python installation or local simulated preview is required to deploy.** These configurations do **not** create Foundry agents or model deployments, set up instrumentation in existing applications, deploy an evaluator, or resize PTUs. The Terraform path has not yet been validated in a live Azure subscription; start in nonproduction and run the [live acceptance checklist](setup.md#acceptance-checklist) afterward.

## Before you start

- Terraform 1.7+ and Azure CLI. These examples use PowerShell; deploying the optional Flex Consumption cost collector requires **PowerShell 7** and **Azure CLI 2.60.0+** on the Terraform machine. Python 3.12+ is optional for the repository's offline tests and dashboard generators; Terraform mock tests require Terraform 1.11+.
- A monitoring resource group in a supported region, either created by Terraform or already existing. The caller needs creation and role-assignment permissions at the monitoring resource group and the specified account/workspace scopes; creating a resource group also requires subscription-level permission.
- Existing Foundry/OpenAI accounts. All monitored accounts must be in the **same subscription** as this Terraform Azure stage. Deploy separate stacks for other subscriptions. Existing telemetry workspace IDs can be specified separately; permissions must exist at those scopes.
- The identity that runs the Grafana stage needs the Grafana Admin role; use its Entra **object ID** as `grafana_admin_object_id`, or assign it separately. The Azure subscription role alone is not Grafana data-plane access.
- The environment must reach both Azure APIs and the Grafana endpoint. Public endpoints are enabled by this starter; private networking requires a separate design.
- For the cost pipeline, the default cost scope requires permission to assign **Cost Management Reader at subscription scope**. Resource-group mode can use separate grants or create custom roles automatically; the latter needs role-definition write/delete permission at subscription scope and role-assignment write/delete permission in each monitored group. Function mode also needs SCM endpoint access, publishing permission, and Flex Consumption with PowerShell 7.6 in the region. GitHub mode needs permission to create a federated credential on the managed identity.

**State contains sensitive information.** AzureRM stores Application Insights connection strings and workspace keys in state even though they are not output here, and email addresses/resource metadata may also appear. Neither root configures a backend by default. Follow the [remote-state walkthrough](getting-started.md#prepare-remote-state-for-terraform) to configure separate encrypted, access-controlled, locked state blobs before real use. Local state is for evaluation only; never commit state, plans, credentials, or real `.tfvars`. Treat Terraform debug logs and plan files as sensitive.

**Choose Terraform or Bicep for a given deployment.** They use different state/ownership and some different resource names. Running both against the same resources is not migration and can create duplicates, conflicting role assignments, unexpected costs, or destructive changes. Migrate by planning and importing existing resources explicitly; do not simply apply the other configuration.

## 1. Azure resources

Copy `terraform/azure/example.tfvars.example` to `terraform/azure/local.tfvars`; replace all placeholder values. The example sets `create_resource_group = true` for a new group. Set it to `false` to use an existing group; the variable defaults to `false` for compatibility with existing deployments. Account IDs are full ARM resource IDs; `ptu_deployments` are actual provisioned deployment names, not model names. Use an empty set for an account without PTUs. The example creates an alert email action group; the address is stored in Terraform state and Azure. Set `enable_cost_pipeline = true` to deploy the optional cost collector.

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

Agent failure-rate, retained-span p95 latency, and heartbeat rules are opt-in (`enable_agent_alerts = true`) and always target the **new monitoring workspace**, not an existing dashboard telemetry workspace. Confirm the `AppRequests` schema, operation name, agent property, run success semantics, sampling, ingestion cap, and traffic expectations there before turning them on. Defaults are a minimum of 20 sampled runs per 10 minutes, a 10% failure-rate threshold, 5-second p95 threshold, and at least one run per 15-minute heartbeat window. Tune these thresholds to your own SLO and traffic profile; the heartbeat can be noisy for intermittent workloads.

An optional monthly Azure Cost Management budget is disabled by default (`monthly_ai_cost_budget_amount = 0`). To enable it, enter a positive amount in subscription billing currency and set `cost_budget_start_date` and `cost_budget_end_date` as UTC `YYYY-MM-DDT00:00:00Z` values. It includes only the configured monitored AI account resource IDs and sends the existing action-group email at `cost_budget_threshold_percent` (80% by default). This is an alert, not a hard cap; billing data can lag, and account-scope budgets are not PTU-deployment- or reservation-specific.

### Optional cost pipeline

To collect costs, configure at least one `monitored_accounts` entry and add to the Azure stage's `local.tfvars`:

```hcl
enable_cost_pipeline     = true
cost_collector_mode      = "githubOidc"
cost_github_oidc_subject = "<exact-repository-main-branch-subject>"
cost_query_scope         = "resourceGroupManaged" # Requires scoped role-definition permissions.
cost_lookback_days       = 90 # UTC days, including today; allowed range: 31-366
```

The example states the default `githubOidc` mode but leaves the subject empty until you supply the exact value; enabling the pipeline without it fails validation. Terraform creates the managed identity, its federated credential, a custom Log Analytics table, a data collection endpoint/rule, and their roles, without a Function or its storage. Its `cost_collector_configuration` output includes `collector_mode` and the non-secret settings the scheduled job needs. Complete [GitHub configuration and verification](costs.md#function-free-github-actions-collector) after applying. A separate Bicep-based lab tested the collector mode, but the Terraform implementation and complete deployment have not been validated live. **The module default changed from `function` to `githubOidc`:** existing configurations that use the Function must set `cost_collector_mode = "function"`, or the next plan removes the Function.

In Function mode (`cost_collector_mode = "function"`), Terraform also creates a Linux Flex Consumption Function and storage account with shared-key access disabled. The Function is scheduled daily at **06:00 UTC**, uses no always-ready instances, and queries Cost Management sequentially for each selected account and cost type. The storage account and Function endpoint are public-network resources protected by Entra authorization; sovereign clouds and private networking are not implemented.

Terraform packages the PowerShell Function and invokes `az functionapp deployment source config-zip` through a PowerShell 7 local provisioner after resource creation; the CLI uses Flex's supported deployment path. An authenticated Azure CLI 2.60.0+ and PowerShell 7 must be available to the **machine running Terraform**, including CI runners. Python is not required. The caller needs network access and publishing permission. The deployment reruns when the package or publishing command changes. If deployment fails, the apply fails; correct the issue and reapply. Azure role propagation can delay startup, publishing, or collection.

The default identity assignment is **Cost Management Reader for the entire subscription**, not just the selected accounts. For resource-group queries, set `cost_query_scope = "resourceGroup"` and arrange separate grants, or use `resourceGroupManaged` to create one single-action custom role and assignment per distinct group. See [cost collection](costs.md#configure-resource-group-query-mode) for the required deployer permissions, access migration, propagation, and lifecycle. The Terraform deployment path, including its managed-role mode, has not been validated live. For an existing Terraform deployment, review the plan for removal of its managed subscription assignment and review any inherited or externally managed access separately. Both collector modes use the same shared cost table; [review Function-to-GitHub migration](costs.md#migrate-from-the-function) before switching.

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

By default, agent dashboards use the monitoring workspace. To use an **existing telemetry workspace** instead, add its full ARM ID as `dashboard_defaults.telemetry_workspace_resource_id` and add it to `existing_telemetry_workspace_ids` in the Azure stage so Grafana gets Log Analytics Reader access. The cost dashboard always uses `monitoring_workspace_resource_id`, because the collector writes its snapshots there. The workspace ARM ID is not a workspace GUID or Application Insights ID.

If you enabled `enable_cost_pipeline` in the Azure stage, set `enable_cost_dashboard = true` in the Grafana stage. This provisions both the detailed cost dashboard and the business overview; the monitoring workspace ID is required. Both settings are off by default. The overview keeps cost status, actual cost by currency, observed agent activity, and PTU signals distinct; it does not calculate an overall health score. The separate [Bicep path](bicep.md) can provision the same dashboards and cost collector without Terraform.

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

This stage creates a data source using `azureAuthType=msi`; it does not broaden Grafana's Azure permissions. The Foundry resource inventory remains RBAC-filtered. The new data source and dashboards are not live-validated by mock tests.

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

Mock tests do not contact Azure/Grafana and cannot prove that provider authentication, Flex deployment, region/SKU availability, metric dimensions, dashboards, KQL, billing permissions, or alert delivery work in your environment. Keep the provider lock files committed and use the same locked versions in automation.

When updating providers, refresh the lock files for the platforms used by CI and contributors before committing them:

```powershell
terraform -chdir=terraform\azure providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_amd64 -platform=darwin_arm64
terraform -chdir=terraform\grafana providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_amd64 -platform=darwin_arm64
```

**Removal can delete data:** removing resources from configuration or running `terraform destroy` can remove dashboards, alerts, Grafana, telemetry resources, and stored telemetry. Review every plan and your retention policies. If retiring the entire stack, handle the Grafana stage first while the endpoint remains reachable, then the Azure stage. Existing model deployments and target account resources are not Terraform-managed.
