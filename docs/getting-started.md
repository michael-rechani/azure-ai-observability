# Deploy Azure AI Observatory: a first-time guide

This walkthrough takes you from an existing Azure AI account to dashboards in Azure Managed Grafana. It uses **PowerShell 7** commands on Windows, macOS, or Linux. Read the common preparation, then follow **either** the Bicep or Terraform section.

**Jump to:** [Preparation](#1-install-the-tools-and-get-the-repository) · [Bicep](#3a-deploy-with-bicep) · [Terraform](#3b-deploy-with-terraform) · [Verify](#4-open-and-verify-the-dashboards) · [Troubleshooting](#troubleshooting-and-cleanup)

> **Before you start:** Both the Bicep and the Terraform path were deployed in an isolated Lab subscription and read live Foundry metrics, PTU metrics and agent traces. That run predates the removal of the optional cost pipeline. The opt-in Infinity cost route is the least-proven part (the Infinity route returned no rows in its live run because the test resource group had no billed cost); see [billed cost options](costs.md). Start in a nonproduction subscription, review the resources and estimated charges with your Azure administrator, and complete the checks at the end. The README screenshots use sample data; this deployment uses real Azure data.

## What you need and what will be created

You need:

- An Azure subscription and permission to sign in to it.
- At least one existing Foundry or Azure OpenAI **account resource** (`Microsoft.CognitiveServices/accounts`). To see PTU metrics, you also need an existing provisioned model deployment and some traffic. This repository does not create accounts, deploy models, or purchase or resize PTUs.
- A region that supports Azure Managed Grafana, Log Analytics, and Application Insights.
- An email address for alert notifications and an existing Microsoft Entra user who will administer Grafana. The walkthrough uses your signed-in user for the initial Grafana administrator.
- Network access from your computer to Azure and the Grafana endpoint. This starter uses public endpoints with authentication; private networking and sovereign-cloud endpoints require a separate design.

The deployment creates Managed Grafana, a Log Analytics workspace, Application Insights, an alert action group, access assignments, an Azure Monitor data source, and dashboards. PTU alerts can be enabled after you verify metric support. Billed cost is not part of the default deployment: the Azure portal and an optional budget alert are the baseline, and one opt-in route can add a cost dashboard to Grafana (a direct query through Infinity, which needs a client secret); see [billed cost options](costs.md). An optional Business overview dashboard covers agent and PTU signals, with no cost data. Azure resources, retained data, queries, and alerts can incur charges; the workspace ingestion cap is **not** a total spending limit. Review your organization's pricing and policies first.

### Choose one deployment path

| Path | Choose this when | What happens |
| --- | --- | --- |
| **Bicep** | You are new to infrastructure as code and want an Azure-native starting point. | A Bicep template creates Azure resources; a PowerShell helper configures Grafana. |
| **Terraform** | Your team uses Terraform or needs its state-based workflow. | One Terraform stage creates Azure resources; a second configures Grafana. Each stage needs its own protected state. |

Use **only one** path for a particular deployment. They do not share ownership or state; applying both is not a migration and can create duplicates or conflicts. Neither path requires Python to deploy.

### Permissions to arrange

Ask your Azure administrator to confirm the following before deployment. An Azure **Contributor** role by itself generally cannot create role assignments.

| Who | Access needed |
| --- | --- |
| Person deploying | Permission to create or update the monitoring resources and write role assignments in the monitoring resource group and on each selected AI account and telemetry workspace. Creating a resource group also needs subscription-level permission. |
| Person deploying the optional Infinity cost route | Creates the app registration and custom role in code, so needs permission to **create Microsoft Entra app registrations** (for example Application Developer or Application Administrator) and to write role definitions and assignments at the scope (Owner or User Access Administrator). The principal gets a custom role whose only action is `Microsoft.CostManagement/query/read`, at subscription scope by default or on each monitored group for `resourceGroupManaged`; it is read-only, but it can read all cost data at that scope. Review [Infinity permissions](costs.md#direct-cost-management-queries-with-infinity-opt-in). |
| Grafana administrator | The signed-in identity running the Grafana configuration must receive **Grafana Admin** on the new instance. The deployment assigns this to the object ID you provide; Azure subscription permissions alone are not Grafana data-plane access. |
| Grafana managed identity | The deployment grants it monitoring access to the selected accounts and read access to selected workspaces. These are separate from the human administrator's permissions. |
| Business users, if desired | An existing Entra group or user can receive **Grafana Viewer**. Viewer is read-only, but it is **not a data-isolation boundary**: the shared data source can query data accessible to Grafana's identity. Use separate deployments or data boundaries for sensitive or different customer data. |

One common way to grant the deployer resource and role-assignment permissions is **Contributor plus User Access Administrator** at each required scope; an organization can instead use a suitable custom role. Subscription-wide Owner is not necessary solely for this starter. Ask your administrator to choose the least-privileged assignments that cover your deployment.

Role assignments can take several minutes to propagate. Your administrator may also need to register Azure resource providers or approve quota and regional availability.

## 1. Install the tools and get the repository

Install [Git](https://git-scm.com/downloads), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), and [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell). Azure CLI 2.60 or later is required for the Bicep path. Install [Terraform](https://developer.hashicorp.com/terraform/install) 1.7 or later **only if you choose Terraform**. The optional offline Terraform mock tests require 1.11 or later.

Open a **PowerShell 7** terminal (`pwsh`) and verify the tools. Skip the Terraform command if using Bicep:

```powershell
git --version
az version
pwsh --version
terraform version
```

Clone the repository and keep this terminal open. `$repo` is the local folder containing the files:

```powershell
git clone https://github.com/michael-rechani/azure-ai-observability.git
Set-Location azure-ai-observability
$repo = (Get-Location).Path
```

Cloning checks out the repository's default branch. If you are following this
guide on a different branch, switch to that same branch before continuing so
the deployment files match the instructions. For the current cost-observability
work-in-progress branch:

```powershell
git switch --track origin/wip/foundry-cost-observability
```

For **Bicep**, install the Bicep CLI through Azure CLI:

```powershell
az bicep install
az bicep version
```

Resolve any errors before proceeding. The examples below assume the same PowerShell session and do not require an Azure service-principal secret.

## 2. Sign in and collect your Azure details

This walkthrough uses an interactive user to deploy and administer Grafana. That login is separate from the managed identity used by the running Grafana Azure Monitor data source, which does not need a browser login, MFA, or a client secret.

For an unattended deployment, use a service principal or managed identity from your own automation; this repository provides no deployment workflow. It still needs the required Azure deployment and role-assignment permissions and Grafana Admin access. For a service principal or managed identity, use its **service-principal object ID**, not its client ID, for the Grafana admin, and set `grafana_admin_principal_type = "ServicePrincipal"` in Terraform or `grafanaAdminPrincipalType = 'ServicePrincipal'` in Bicep. The signed-in-user lookup below applies only to a user.

To follow this interactive walkthrough, sign in as the user who will deploy and administer Grafana. If browser sign-in is unavailable, use `az login --use-device-code` instead.

```powershell
az login
az account list --query "[].{Name:name,SubscriptionId:id,TenantId:tenantId,State:state}" --output table
```

Replace the placeholder with your subscription ID, select it, and verify the displayed subscription and tenant:

```powershell
$subscriptionId = '<subscription-id>'
az account set --subscription $subscriptionId
az account show --query "{Name:name,SubscriptionId:id,TenantId:tenantId}" --output table
```

For this first deployment, keep the monitored accounts in that same subscription. Bicep can monitor across subscriptions in some configurations, but costs and budgets require the monitored accounts to be in the monitoring subscription. Terraform requires that for all monitored accounts.

Get your signed-in user's **Entra object ID**. This is not your subscription ID, an application/client ID, or an email address. If your organization blocks this lookup, ask an Entra administrator for the user's object ID.

```powershell
$grafanaAdminObjectId = az ad signed-in-user show --query id --output tsv
$grafanaAdminObjectId
```

Find the accounts you can access. An AI *project*, a model *deployment*, and an AI *account resource* are different things; the account is the target of this starter's Azure Monitor access.

```powershell
az cognitiveservices account list `
  --query "[].{Name:name,ResourceGroup:resourceGroup,Region:location,Kind:kind,Id:id}" `
  --output table
```

Record each account's **name**, **resource group**, **region**, and full **resource ID**. You can also find these under the resource's **Overview** and **Properties** in the [Azure portal](https://portal.azure.com/). To inspect one account and its model deployments, replace the placeholders:

```powershell
$accountGroup = '<existing-ai-account-resource-group>'
$accountName = '<existing-ai-account-name>'
az cognitiveservices account show --resource-group $accountGroup --name $accountName `
  --query "{Name:name,ResourceGroup:resourceGroup,Region:location,Id:id}" --output json
az cognitiveservices account deployment list --resource-group $accountGroup --name $accountName `
  --query "[].{Deployment:name,Sku:sku.name,Capacity:sku.capacity,Model:properties.model.name}" --output table
```

For PTUs, record the **deployment name** with a provisioned SKU, not just the model name. If no provisioned deployment exists, use an empty PTU list below; PTU panels will not show utilization until one exists and emits supported metrics.

Choose a **new monitoring resource-group name** and a supported monitoring region. They can differ from the existing account's resource group and region:

```powershell
$monitoringGroup = '<new-monitoring-resource-group>'
$monitoringRegion = '<monitoring-region>' # For example, eastus if your required services are available there.
```

If business users need access, also obtain an existing Entra **group object ID** from your administrator. Do not put credentials, tokens, or real configuration values in Git.

## 3A. Deploy with Bicep

Skip this section if you chose Terraform.

### Configure the parameters

Copy the example. Open `infra/main.local.bicepparam` in a text editor; keep it in the `infra` folder. This local file is ignored by Git.

```powershell
$parametersFile = Join-Path $repo 'infra' 'main.local.bicepparam'
if (Test-Path -LiteralPath $parametersFile) {
    throw "Refusing to overwrite '$parametersFile'; edit the existing local configuration."
}
Copy-Item -LiteralPath (Join-Path $repo 'infra' 'main.example.bicepparam') -Destination $parametersFile -ErrorAction Stop
```

Replace every example subscription ID, account name, account resource group, account region, PTU deployment name, admin object ID, and email. Set:

| Parameter | Value |
| --- | --- |
| `location` | Your monitoring region, the same value as `$monitoringRegion`. |
| `namePrefix` | A 2-20 character prefix using lowercase letters, digits, or hyphens; start with a letter and end with a letter or digit. |
| `grafanaAdminObjectId` | The object ID printed by `$grafanaAdminObjectId`. |
| `notificationEmail` | A real address approved to receive alert notifications. |
| `monitoredAccounts` | The existing accounts to monitor and their actual provisioned deployment names. Use `ptuDeployments: []` for an account without PTUs. |
| `foundryDashboardAccount`, `ptuDashboardAccount` | Initial dashboard selections. Each non-null account must also appear in `monitoredAccounts`; use that account's actual region. |
| `enableAgentAlerts` | Leave `false` until real agent telemetry and expected traffic are verified. |
| `enableBusinessOverview` | Leave `false`, or set `true` to also provision the Business overview dashboard (agent runs, failure rate and PTU signals; no cost data). It needs only the agent telemetry workspace. |
| `enableCostInfinity` | Leave `false`, or set `true` for the [direct query through Infinity](bicep.md#optional-direct-cost-queries-with-infinity). It adds no cluster, but it is **not secretless**: it needs a service principal client secret that Grafana stores and you must rotate. The template creates the app registration, service principal and a read-only custom role (`Microsoft.CostManagement/query/read` only) for you; the deployment helper then mints the secret. Optionally set `costInfinityScope` (`subscription` or `resourceGroupManaged`; review [permissions](costs.md#direct-cost-management-queries-with-infinity-opt-in)). |

**Add** `param enablePtuAlerts = false` to the file: PTU alerts otherwise default to enabled. Turn them on later, after [discovering the metrics](setup.md#metric-discovery).

For example, if the **same account** supplies Foundry and PTU data, replace the three existing account blocks with the following and replace every `<...>` value. List the shared account only once in `monitoredAccounts`:

```bicep
param monitoredAccounts = [
  {
    subscriptionId: '<subscription-id>'
    resourceGroup: '<ai-account-resource-group>'
    name: '<ai-account-name>'
    ptuDeployments: ['<provisioned-deployment-name>']
  }
]
param foundryDashboardAccount = {
  subscriptionId: '<subscription-id>'
  resourceGroup: '<ai-account-resource-group>'
  name: '<ai-account-name>'
  region: '<ai-account-region>'
  deployment: '*'
}
param ptuDashboardAccount = {
  subscriptionId: '<subscription-id>'
  resourceGroup: '<ai-account-resource-group>'
  name: '<ai-account-name>'
  region: '<ai-account-region>'
  deployment: '<provisioned-deployment-name>'
}
```

If you have separate accounts, keep two distinct entries as in the example file. If you do not have a PTU deployment, use `ptuDeployments: []` and replace the `ptuDashboardAccount` block with `param ptuDashboardAccount = null`; the PTU dashboard cannot show real PTU data yet. You can similarly set `foundryDashboardAccount` to `null` if it is not relevant.

For an existing business-user group, replace the `grafanaViewerPrincipals = []` line with:

```bicep
param grafanaViewerPrincipals = [
  {
    principalId: '<entra-group-object-id>'
    principalType: 'Group'
  }
]
```

Leave `existingTelemetryWorkspaces` empty and `dashboardTelemetryWorkspaceResourceId` as `''` unless you have an existing agent-telemetry workspace to connect. See [Bicep configuration](bicep.md#configure) for that option. Save the file.

### Preview and deploy

Create the new monitoring resource group. **This command changes Azure**, even though the next command is only a preview. Do not reuse a group containing unrelated workloads without understanding its lifecycle.

```powershell
az group create --name $monitoringGroup --location $monitoringRegion
```

Preview the Azure resource changes:

```powershell
& (Join-Path $repo 'scripts' 'deploy_bicep.ps1') `
  -SubscriptionId $subscriptionId -ResourceGroup $monitoringGroup `
  -ParametersFile $parametersFile -WhatIf
```

What-if does **not** preview Grafana data-plane changes. After reviewing the output and charges, deploy:

```powershell
& (Join-Path $repo 'scripts' 'deploy_bicep.ps1') `
  -SubscriptionId $subscriptionId -ResourceGroup $monitoringGroup `
  -ParametersFile $parametersFile
```

The helper prints the Grafana URL when Azure deployment and dashboard configuration have succeeded. If it fails after creating Azure resources, that is **not a rollback**. Correct the reported permissions, network, or configuration problem and rerun; role propagation can require a wait. Do not switch to Terraform as a retry.

If you need to retrieve the endpoint later:

```powershell
az deployment group show --resource-group $monitoringGroup --name ai-observability `
  --query 'properties.outputs.grafanaEndpoint.value' --output tsv
```

Continue to [open and verify the dashboards](#4-open-and-verify-the-dashboards).

## 3B. Deploy with Terraform

Skip this section if you chose Bicep. Terraform has **two separate stages**: Azure resources first, then Grafana's data source and dashboards. Both stages need their own state blob.

### Prepare remote state for Terraform

Neither Terraform stage has a backend configured by default. State can contain Application Insights connection strings, workspace keys, email addresses, and resource metadata. For a real environment, use encrypted, access-controlled remote storage with locking; do not commit state, plans, credentials, or real `.tfvars`.

The following is a starting point for a **new** deployment using Azure Blob Storage and your Azure CLI sign-in. Ask your administrator for an approved existing storage account/container instead if your organization already manages Terraform state. You need **Storage Blob Data Contributor** on the container, access to its network endpoint, and a standard storage endpoint for these commands. Adapt networking, retention, redundancy, and access to your organization's requirements.

Already have an approved container? Skip the creation commands and [use the existing container](#use-an-existing-state-container).

To create a separate state account yourself, choose a **new** resource group and a globally unique storage account name of 3-24 lowercase letters and numbers. This creates billable Azure resources. Keep the state group separate from the monitoring group so destroying the monitoring stack does not destroy its own state.

```powershell
$stateGroup = '<new-state-resource-group>'
$stateStorage = '<globally-unique-state-storage-name>'
$stateContainer = 'tfstate'
az group create --name $stateGroup --location $monitoringRegion
az storage account create --resource-group $stateGroup --name $stateStorage `
  --location $monitoringRegion --sku Standard_LRS --kind StorageV2 `
  --https-only true --min-tls-version TLS1_2 `
  --allow-blob-public-access false --allow-shared-key-access false
```

Enable versioning and blob soft delete, then grant your signed-in user data access. This bootstrap assignment is scoped to the dedicated storage account; an administrator can instead grant access at container scope.

```powershell
az storage account blob-service-properties update --resource-group $stateGroup `
  --account-name $stateStorage --enable-versioning true `
  --enable-delete-retention true --delete-retention-days 30
$stateAccountId = az storage account show --resource-group $stateGroup `
  --name $stateStorage --query id --output tsv
az role assignment create --role 'Storage Blob Data Contributor' `
  --assignee-object-id $grafanaAdminObjectId --assignee-principal-type User `
  --scope $stateAccountId
```

Wait for the role assignment to propagate, then create the container using your Entra sign-in. If access is denied, check the assignment and networking, wait, and retry this command.

```powershell
az storage container create --account-name $stateStorage `
  --name $stateContainer --auth-mode login
```

The example storage account has a public network endpoint; anonymous blob access and shared-key authentication are disabled, but this is not a private-network design. Follow your security team's requirements before production use. Continue to [configure the backends](#configure-both-terraform-backends).

#### Use an existing state container

For an **existing approved container**, set these values to its names; do not recreate or alter it:

```powershell
$stateStorage = '<existing-state-storage-account>'
$stateContainer = '<existing-state-container>'
```

#### Configure both Terraform backends

For either option, copy the provided backend declaration into **both** Terraform stages:

```powershell
$azureStage = Join-Path $repo 'terraform' 'azure'
$grafanaStage = Join-Path $repo 'terraform' 'grafana'
$backendExample = Join-Path $repo 'terraform' 'azurerm.backend.tf.example'
$azureBackendFile = Join-Path $azureStage 'backend.local.tf'
$grafanaBackendFile = Join-Path $grafanaStage 'backend.local.tf'
foreach ($destination in @($azureBackendFile, $grafanaBackendFile)) {
    if (Test-Path -LiteralPath $destination) {
        throw "Refusing to overwrite '$destination'; edit the existing local backend configuration."
    }
}
Copy-Item -LiteralPath $backendExample -Destination $azureBackendFile -ErrorAction Stop
Copy-Item -LiteralPath $backendExample -Destination $grafanaBackendFile -ErrorAction Stop
```

Choose a unique, nonsecret key prefix for this deployment and environment, such as `dev-ai-observatory-team1`. Do not reuse another stack's keys. Initialize each stage with a **different key** in the same container:

```powershell
$stateKeyPrefix = '<unique-deployment-key-prefix>'
terraform "-chdir=$azureStage" init `
  "-backend-config=storage_account_name=$stateStorage" `
  "-backend-config=container_name=$stateContainer" `
  "-backend-config=key=${stateKeyPrefix}-azure.tfstate" `
  "-backend-config=use_azuread_auth=true"
```

When that command succeeds, initialize the second stage:

```powershell
terraform "-chdir=$grafanaStage" init `
  "-backend-config=storage_account_name=$stateStorage" `
  "-backend-config=container_name=$stateContainer" `
  "-backend-config=key=${stateKeyPrefix}-grafana.tfstate" `
  "-backend-config=use_azuread_auth=true"
```

The `backend.local.tf` files are ignored by Git and contain no credentials. Terraform records backend settings locally; never pass secrets in `-backend-config`. For CI, use an approved workload identity instead of an interactive user. If you already have local state, do not overwrite or delete it: securely back it up and follow [Terraform's backend migration guidance](https://developer.hashicorp.com/terraform/language/settings/backends/configuration#migrating-between-backends).

### Configure and deploy the Azure stage

Copy the example and open `terraform/azure/local.tfvars` in a text editor:

```powershell
$azureTfvarsFile = Join-Path $azureStage 'local.tfvars'
if (Test-Path -LiteralPath $azureTfvarsFile) {
    throw "Refusing to overwrite '$azureTfvarsFile'; edit the existing local configuration."
}
Copy-Item -LiteralPath (Join-Path $azureStage 'example.tfvars.example') -Destination $azureTfvarsFile -ErrorAction Stop
```

Replace the example values:

| Setting | Value |
| --- | --- |
| `subscription_id` | The selected subscription ID. |
| `resource_group_name`, `location` | Your new monitoring group and region. The example's `create_resource_group = true` makes Terraform manage that new group. Set it to `false` if you deliberately use an existing group. |
| `grafana_admin_object_id`, `notification_email` | Your Entra user object ID and the approved alert email address. |
| `monitored_accounts` | The full account resource IDs and actual provisioned deployment names. Use `ptu_deployments = []` for accounts without PTUs; list a shared Foundry/PTU account only once. |
| `enable_agent_alerts` | Leave `false` until real agent telemetry and expected traffic are verified. |
| `enable_cost_infinity` | Leave `false`, or set `true` for the [direct query through Infinity](terraform.md#optional-direct-cost-queries-with-infinity). It adds no cluster, but it is **not secretless**: it needs a service principal client secret that Grafana stores (and both stages' state record) and you must rotate. Terraform creates the app registration, service principal, secret and a read-only custom role (`Microsoft.CostManagement/query/read` only) for you. Optionally set `cost_infinity_scope`; review [permissions](costs.md#direct-cost-management-queries-with-infinity-opt-in). |
Add `enable_ptu_alerts = false` to the file; the default is `true`. If one account is used for both Foundry and PTUs, the account map can look like this:

```hcl
monitored_accounts = {
  primary = {
    resource_id     = "<full-ai-account-resource-id>"
    ptu_deployments = ["<provisioned-deployment-name>"]
  }
}
```

For business users, replace `grafana_viewer_principals = {}` with:

```hcl
grafana_viewer_principals = {
  business_readers = {
    principal_id   = "<entra-group-object-id>"
    principal_type = "Group"
  }
}
```

Leave `existing_telemetry_workspace_ids = []` unless you need to connect an existing telemetry workspace; see [Terraform configuration](terraform.md#1-azure-resources). Save the file.

Review the plan, including which resource group is managed and any role assignments. A later apply produces a fresh plan, so review that output again before approving it.

```powershell
terraform "-chdir=$azureStage" plan -var-file=local.tfvars
```

If the plan is correct and you accept the charges, apply it and type `yes` only when prompted:

```powershell
terraform "-chdir=$azureStage" apply -var-file=local.tfvars
```

If apply fails, resolve the error and reapply rather than assuming it rolled back.

Print the two outputs needed by the next stage:

```powershell
terraform "-chdir=$azureStage" output -raw grafana_endpoint
terraform "-chdir=$azureStage" output -raw workspace_resource_id
```

### Configure and deploy the Grafana stage

Wait for your **Grafana Admin** assignment to propagate. Copy the example and open `terraform/grafana/local.tfvars`:

```powershell
$grafanaTfvarsFile = Join-Path $grafanaStage 'local.tfvars'
if (Test-Path -LiteralPath $grafanaTfvarsFile) {
    throw "Refusing to overwrite '$grafanaTfvarsFile'; edit the existing local configuration."
}
Copy-Item -LiteralPath (Join-Path $grafanaStage 'example.tfvars.example') -Destination $grafanaTfvarsFile -ErrorAction Stop
```

Set `grafana_endpoint` to the first output above, `subscription_id` to the selected subscription, and `dashboard_defaults.monitoring_workspace_resource_id` to the second output. Replace the `foundry_account` and `ptu_account` details with the existing accounts' resource groups, names, and **account regions**, plus the real PTU deployment name. If you do not have a PTU deployment, remove the `ptu_account` block; the PTU dashboard retains placeholder defaults until you configure one. You can also remove `foundry_account` if it is not relevant.

Set `enable_business_overview = true` here to also provision the Business overview dashboard (agent and PTU signals, no cost data); leave it `false` otherwise. For agent telemetry in an existing workspace, configure the separate telemetry workspace and its access as described in the [Terraform guide](terraform.md#2-configure-the-grafana-stage). Save the file.

Get a short-lived Grafana token without printing it, and review the plan:

```powershell
$env:GRAFANA_AUTH = az account get-access-token --resource https://dashboard.azure.com --query accessToken --output tsv
if ($LASTEXITCODE -ne 0 -or -not $env:GRAFANA_AUTH) { throw 'Could not obtain a Grafana token.' }
terraform "-chdir=$grafanaStage" plan -var-file=local.tfvars
```

After the plan succeeds, review it and apply:

```powershell
terraform "-chdir=$grafanaStage" apply -var-file=local.tfvars
```

Review the apply's fresh plan and type `yes` only when prompted. After a successful apply, inspect the URLs and remove the token:

```powershell
terraform "-chdir=$grafanaStage" output dashboard_urls
Remove-Item Env:\GRAFANA_AUTH
```

If a command fails or you stop before the last line, remove the token with `Remove-Item Env:\GRAFANA_AUTH`; obtain a new one before a later plan or apply. Never paste it into a file, terminal transcript, or issue. If Grafana returns an authorization error, verify the Grafana Admin role, wait for propagation, and retry.

## 4. Open and verify the dashboards

1. Open the Grafana URL from the successful deployment and sign in as the Grafana administrator. Find the Foundry overview, Foundry agents, and OpenAI PTU dashboards. If you enabled the Business overview or the opt-in Infinity cost route, also find the Business overview and the cost visibility dashboard.
2. Check each dashboard's subscription, account, region, deployment, workspace, agent and time-range controls. Use the **Log Analytics workspace ARM resource ID**, not a workspace GUID or Application Insights ID, where a workspace resource ID is requested. Leave the agent control at `*` to see every agent, or enter one exact agent name; it narrows only the agent run panels (see [Reading the dashboards](setup.md#reading-the-dashboards)).
3. Generate or observe known traffic on an existing account. Confirm that supported request, token, and PTU utilization metrics appear for the intended resource and deployment. An empty graph can mean no traffic, an unsupported metric/dimension, a wrong filter, or missing access; it does not prove zero usage. On the Foundry overview, the **Estimated pay-as-you-go token cost** table is a list-price estimate, not billed cost; a model missing from `queries/model-prices.kql` shows `no list price`, and the [cost guide](costs.md#native-estimate-from-azure-monitor-metrics-no-secret) lists what it does not cover.
4. Configure your Foundry agent or application to send real traces to Application Insights, then run a known agent request. Creating Application Insights alone does not instrument agents or create evaluation events. Follow the [telemetry guide](telemetry.md) and check the actual attributes and workspace.
5. Before enabling PTU alerts, inspect the account's [metric definitions and dimensions](setup.md#metric-discovery). Then change `enablePtuAlerts` or `enable_ptu_alerts` to `true`, review the new deployment/plan, and deploy again. Enable agent alerts only after verifying the telemetry schema, sampling, and expected traffic.
6. If you enabled the opt-in Infinity cost route, compare its cost dashboard with Cost Management in the Azure portal. Billing data can lag or be revised. It shows actual cost in billing currency, not amortized cost, invoice totals or per-deployment PTU prices; the route is throttled and limited to 31 days of daily data per query. The Business overview shows agent and PTU signals only.
7. Ask a member of the configured Viewer group to sign in and confirm access. Review what the Grafana identity can query before sharing dashboards. Test alert delivery in nonproduction.

Use the full [acceptance checklist](setup.md#acceptance-checklist) before relying on the dashboards. Offline validation cannot prove live Azure permissions, metric availability, queries, costs, or notification delivery.

## Troubleshooting and cleanup

| Symptom | First checks |
| --- | --- |
| Account or deployment is missing | Confirm the selected subscription, existing resource group/account, account type, deployment name, and your Azure permissions. |
| Deployment or role assignment is forbidden | Check the deployment identity's resource and role-assignment permissions at every affected scope; verify provider registration and regional availability. |
| Grafana configuration returns 403 | Confirm that the signed-in user has Grafana Admin on the instance, wait for propagation, and verify network access. Rerun the same deployment path. |
| Dashboard opens but data queries fail | Check the Grafana managed identity's Monitoring Reader or Log Analytics Reader assignments, data-source configuration, selected resource IDs, and role propagation. |
| Agent charts are empty | Confirm actual tracing/exporter configuration, workspace, ingestion permissions, and the attribute contract; see [telemetry troubleshooting](telemetry.md). |
| PTU panels are empty | Confirm a provisioned SKU, the deployment name, real traffic, time range, and supported metric definitions and dimensions. |
| Cost dashboard is missing or empty | Confirm the opt-in switch you meant to enable (`enableCostInfinity` / `enable_cost_infinity_dashboard`), the data source's authentication, cost access at the configured scope, and billing availability. See [cost troubleshooting](costs.md#troubleshooting). |
| Terraform cannot access state | Check the storage/container names, distinct state keys, Blob Data Contributor role, role propagation, endpoint networking, and Azure CLI sign-in. |

**Cleanup can delete data.** Terraform-managed dashboards should be removed with the Grafana stage while Grafana is still reachable, before removing the Azure stage; review each destruction plan and retention policy. A Terraform-managed resource group may be deleted along with its contents. Keep the separate state account until the lifecycle is complete and your retention policy permits removal.

Bicep deployments are incremental: setting a feature or Viewer to disabled does **not** remove previously created resources, dashboards, data, or role assignments. Review and remove unwanted resources and access explicitly. Never delete a shared resource group or existing AI account as a shortcut. See the [Bicep lifecycle](bicep.md#lifecycle-and-removal) and [Terraform lifecycle](terraform.md#validation-and-lifecycle) guidance.
