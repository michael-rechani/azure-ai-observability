# Bicep deployment

The Bicep path deploys Azure monitoring resources, scoped access, alerts, the Grafana data source and dashboards, and an optional cost-collection Function. **Terraform and Python are not required.** Bicep creates the Azure resources; the PowerShell 7 helper packages and publishes the Function and uses the Grafana data-plane API, which are not native Bicep resources.

Neither complete deployment path has been validated in a live Azure subscription. Isolated lab tests covered the optional Bicep cost Function module and the scoped role module separately; see [cost collection](costs.md). Start in nonproduction, review expected charges, and complete the [acceptance checklist](setup.md#acceptance-checklist). The templates monitor existing Foundry/OpenAI accounts; they do not create or resize model deployments, instrument applications, or run evaluations.

## Prerequisites

- Azure CLI 2.60+ with Bicep installed (`az bicep install`) and PowerShell 7. The helper runs on the machine with the Azure CLI credentials.
- An existing monitoring resource group in a region supporting Managed Grafana Standard, Application Insights, and, if enabled, Functions Flex Consumption with PowerShell 7.6.
- Permission to create resources and role assignments in the monitoring resource group and each selected account/workspace. The default cost collector also requires permission to assign **Cost Management Reader at subscription scope**. Resource-group mode can use separate grants or create custom roles automatically; the latter needs subscription deployment and role-definition write/delete permission at subscription scope, and role-assignment write/delete permission in each monitored group. A budget requires permission to create subscription budgets.
- The signed-in identity must receive **Grafana Admin**. Use its Entra object ID for `grafanaAdminObjectId`, or grant it access separately. Azure subscription permissions alone are not Grafana data-plane access.
- Network access to Azure management APIs, the public Grafana endpoint, and the Function SCM endpoint when publishing the cost collector. This starter does not implement sovereign-cloud endpoints or private networking.

**Choose Terraform or Bicep for a given deployment.** They do not share ownership or state, and some resource names differ. Applying both to the same environment is not migration and can create duplicates, conflicting role assignments, unexpected costs, or destructive changes.

## Configure

Copy `infra/main.example.bicepparam` to `infra/main.local.bicepparam` in the same directory. Replace the sample subscription IDs, account/resource-group names, regions, Grafana admin object ID, email, and deployment names. The file is ignored by Git; do not commit real local configuration, tokens, or credentials.

- `monitoredAccounts`: existing account subscription, resource group and name. Include actual **provisioned deployment names** in `ptuDeployments`; use `[]` for accounts without PTUs. Set `enablePtuAlerts = false` until you have checked [metric definitions and dimensions](setup.md#metric-discovery).
- `foundryDashboardAccount` and `ptuDashboardAccount`: initial dashboard controls. Each must reference an account in `monitoredAccounts`. Use the account's actual region, which may differ from the monitoring region. Use `'*'` or a real deployment name; the PTU dashboard is clearest with an explicit PTU deployment.
- `existingTelemetryWorkspaces`: existing workspaces to which Grafana needs Log Analytics Reader. Set `dashboardTelemetryWorkspaceResourceId` to one of their full ARM IDs to read agent telemetry there, or leave it empty to use the new workspace. The cost dashboard always uses the new monitoring workspace.
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

### Optional cost collection and budget

Set `enableCostPipeline = true` for the daily collector, detailed cost dashboard, and business overview. The overview keeps cost collection status, actual cost by currency, observed agent activity, and PTU signals distinct; it does not calculate an overall health score. `costLookbackDays` defaults to 90 and can be 31-366 days. At least one account is required, and **all monitored accounts must be in the monitoring subscription** whenever cost collection or the budget is enabled. Deploy separate stacks for other subscriptions. Without those features, Bicep can monitor accounts in other subscriptions when the deployer has access.

`costQueryScope` defaults to `subscription` for compatibility, which creates the subscription-wide cost-reader assignment. The example parameters select `resourceGroupManaged` instead, creating one single-action custom role and assignment per distinct monitored group when cost collection is enabled. This requires role-definition write/delete permission at subscription scope and role-assignment permissions at each group. Alternatively, use `resourceGroup` with separately managed grants. See [cost collection](costs.md#configure-resource-group-query-mode) for access migration, propagation, and lifecycle. The complete Bicep deployment and the new managed-role mode have not been validated end to end in Azure. **Switching an existing Bicep deployment does not delete old assignments or custom roles**; inspect and remove unwanted access explicitly. Both group modes still use the Function and a shared cost table.

The helper rejects combinations exceeding 30 minutes of minimum Cost Management API pacing: `accounts x ceil(lookbackDays / 27) x 2 x 16 seconds`. At 90 days, this permits up to 14 accounts. See [cost collection](costs.md) for permissions, billing interpretation, timing, snapshot completion, and limitations.

For an optional monthly account-filtered budget, set a positive whole-number `monthlyAiCostBudgetAmount` in subscription billing currency and set `costBudgetStartDate` and `costBudgetEndDate` as UTC `YYYY-MM-DDT00:00:00Z` values. The start must be the first of a month and the end later. Tune `costBudgetThresholdPercent` (default 80). This is an alert, not a spending cap; costs may arrive late.

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

The helper validates account/workspace inputs and pacing before deploying, compiles the parameters, and uses the checked-in `infra/main.bicep`. It then publishes the optional Function with Azure CLI and provisions the Azure Monitor managed-identity data source and dashboards through Grafana's API. It acquires a short-lived Entra token for `https://dashboard.azure.com`, checks the endpoint, does not follow redirects, and does not print or save the token. Temporary compiled parameters and Function packages are removed after the run. `-WhatIf` does not publish the Function or change Grafana data-plane resources; it does not preview those API changes.

Grafana Admin or managed-identity role assignments can take time to propagate. If an API call is rejected, verify the role and network access, wait, then rerun the same deployment. Azure resources may already have been created before a publishing or Grafana failure; a failed helper is not a rollback.

The helper marks resources it creates in Grafana. It refuses to overwrite an unrelated data source or dashboard with the same UID and does not force-update version conflicts. Managed dashboards are reconciled on rerun, so edit their checked-in JSON rather than relying on persistent Grafana UI edits. Review and resolve UID/ownership collisions explicitly.

## Optional GitHub Actions OIDC deployment

`.github/workflows/deploy-bicep.yml` provides a manually dispatched deployment on the `main` branch. It uses GitHub's OIDC token with `Azure/login`, not a client secret, and invokes the same `scripts/deploy_bicep.ps1` helper as a local deployment. The default operation is **what-if**; **apply** runs the full Bicep deployment and, if enabled, Function publishing and Grafana provisioning. The what-if previews only the ARM deployment, not those post-deployment operations. The workflow has not been validated against a live Azure subscription.

Before using it:

1. Create a GitHub Environment named `azure-production`. Restrict its deployment branches to `main` and configure required reviewers so an apply must receive human approval. Merely referencing an Environment in the workflow does not enable these protection rules; configure them in repository settings before use.
2. Add these environment variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_RESOURCE_GROUP`. The resource group must already exist.
3. Add an environment secret named `BICEP_PARAMETERS` containing the complete text of a parameter file based on `infra/main.example.bicepparam`, including `using './main.bicep'`. Do not put credentials in the parameter file.
4. Configure an Entra federated identity credential for `https://token.actions.githubusercontent.com` with audience `api://AzureADTokenExchange`. Its subject must match this repository's GitHub OIDC subject for the `azure-production` environment. Do not use a wildcard subject. Restrict the GitHub Environment to `main` as well.
5. Grant the federated identity only the Azure permissions required by the selected configuration. The role-assignment and optional custom-role-definition permissions in [Prerequisites](#prerequisites) still apply; the workflow does not create the resource group or grant itself access.

From the repository's **Actions** tab, run **Deploy Bicep to Azure** on `main` and select `what-if` first. Review the ARM changes and expected charges. Select `apply` only when ready; it executes the full helper and may create billable resources or change Azure and Grafana state. The workflow writes the parameter secret to the ignored `infra/main.local.bicepparam` path only for the job and removes it afterward. The runner is ephemeral, but this cleanup is not a substitute for protecting the GitHub Environment and its secrets.

## Lifecycle and removal

Bicep uses **incremental** Azure deployments: removing a principal or monitored group, changing cost modes, setting an alert or cost feature to false, or setting the budget amount to zero does **not** delete resources created by a previous deployment. A previously deployed cost Function can keep running and incurring charges, a budget can keep sending alerts, and removed Viewer/publisher or cost role assignments can remain effective. Explicitly review and remove the specific unwanted Azure resources and role assignments through Azure's management tools. Remove an obsolete managed cost role's assignments before deleting its role definition, after confirming neither is used elsewhere. Disabling cost collection also does not delete the Grafana cost dashboard or historical workspace data. Preserve or delete data according to your retention requirements.

The helper updates its managed Grafana resources but does not delete them. Disabling cost collection does not remove previously provisioned cost or business dashboards. Azure resources and dashboards have separate lifecycles; do not delete a resource group containing other workloads. For Terraform-managed resources, use the separate [Terraform lifecycle guidance](terraform.md#validation-and-lifecycle).
