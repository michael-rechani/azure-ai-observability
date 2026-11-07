# Terraform deployment

The two Terraform roots use **native AzureRM and Grafana provider resources**:

1. `terraform/azure` creates Managed Grafana, Log Analytics, Application Insights, scoped RBAC, an action group, and per-account PTU metric alerts.
2. `terraform/grafana` creates the Azure Monitor managed-identity data source and the three dashboards through the Grafana data-plane API.

The deployment is intentionally two-stage: the Grafana endpoint and caller's Grafana Admin role need to exist and propagate before Terraform can connect to the data plane. These configurations do **not** create Foundry agents or model deployments, set up instrumentation in existing applications, deploy an evaluator, or resize PTUs. Run the [live acceptance checklist](setup.md#acceptance-checklist) afterward.

## Before you start

- Terraform 1.7+ (mock tests require 1.7+), Azure CLI, and Python 3.12+.
- An existing monitoring resource group in a supported region. The caller needs creation and role-assignment permissions at the monitoring resource group and the specified account/workspace scopes.
- Existing Foundry/OpenAI accounts. All monitored accounts must be in the **same subscription** as this Terraform Azure stage. Deploy separate stacks for other subscriptions. Existing telemetry workspace IDs can be specified separately; permissions must exist at those scopes.
- The identity that runs the Grafana stage needs the Grafana Admin role; use its Entra **object ID** as `grafana_admin_object_id`, or assign it separately. The Azure subscription role alone is not Grafana data-plane access.
- The environment must reach both Azure APIs and the Grafana endpoint. Public endpoints are enabled by this starter; private networking requires a separate design.

**State contains sensitive information.** AzureRM stores Application Insights connection strings and workspace keys in state even though they are not output here, and email addresses/resource metadata may also appear. Configure separate encrypted remote backends with access control and locking for both roots before real use. Local state is for evaluation only; never commit state, plans, credentials, or real `.tfvars`. Treat Terraform debug logs and plan files as sensitive.

**Choose Terraform or Bicep for a given deployment.** They use different state/ownership and some different resource names. Running both against the same resources is not migration and can create duplicates, conflicting role assignments, unexpected costs, or destructive changes. Migrate by planning and importing existing resources explicitly; do not simply apply the other configuration.

## 1. Azure resources

Copy `terraform/azure/example.tfvars.example` to `terraform/azure/local.tfvars`; replace all placeholder values. Account IDs are full ARM resource IDs; `ptu_deployments` are actual provisioned deployment names, not model names. Use an empty set for an account without PTUs. The example creates an alert email action group; the address is stored in Terraform state and Azure.

Discover metric definitions and confirm dimensions before enabling alerts as described in [metric discovery](setup.md#metric-discovery). To provision access first, set `enable_ptu_alerts = false`, then enable after verification. Account map keys must be stable; renaming one changes its Terraform addresses.

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

The monitoring resource group must already exist. Deployment may fail for lack of resource/role assignment permissions, unsupported Grafana version, unavailable metric dimensions, or restricted network access; correct the issue rather than bypassing metric validation.

## 2. Configure dashboard defaults

Copy `config.example.json` to `config.local.json`, replace the account/subscription/region and workspace ARM ID placeholders with your real values, and generate local dashboards:

```powershell
python .\scripts\build_dashboards.py --config .\config.local.json --output .\local-dashboards
```

This generator has one subscription default; each dashboard can be changed independently after deployment. The workspace ID is the Log Analytics workspace ARM ID from `terraform -chdir=terraform\azure output -raw workspace_resource_id`, not the Application Insights ID. If you skip this step, the dashboards deploy with placeholder defaults until you edit their controls.

## 3. Grafana data source and dashboards

Copy `terraform/grafana/example.tfvars.example` to `terraform/grafana/local.tfvars`, set `grafana_endpoint` to the Azure stage's `grafana_endpoint` output, and set `subscription_id`. To use the generated dashboards, add:

```hcl
dashboard_directory = "../../local-dashboards"
```

Terraform's Grafana provider receives an **Entra access token** in its `GRAFANA_AUTH` environment variable. Grafana's separate Azure Monitor data source uses the Grafana managed identity to query Azure; no API key or client secret is enabled. The token must be issued for `https://dashboard.azure.com` and the caller must have Grafana Admin:

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

Mock tests do not contact Azure/Grafana and cannot prove that provider authentication, region/SKU availability, metric dimensions, dashboards, KQL, or alert delivery work in your environment. Keep the provider lock files committed and use the same locked versions in automation.

**Destruction is destructive:** removing resources from configuration or running `terraform destroy` can remove dashboards, alerts, Grafana, telemetry resources, and stored telemetry. Review every plan and your retention policies. If intentionally retiring the entire stack, handle the Grafana stage first while the endpoint remains reachable, then the Azure stage. Existing model deployments and target account resources are not Terraform-managed.
