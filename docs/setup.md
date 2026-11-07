# Setup

## Prerequisites

- Existing Foundry and/or Azure OpenAI accounts. PTU alerts need existing provisioned deployments.
- Azure CLI with Bicep and Python 3.12+. No `azd`, Prometheus, or AKS is required.
- An Azure Managed Grafana-supported region and permission to deploy resources and assign roles.
- An Entra object ID for the intended Grafana administrator and an alert email recipient.

Do not commit connection strings, tokens, personal addresses, or your local configuration.

## Deploy new monitoring infrastructure

Copy and edit `infra/main.example.bicepparam` as `infra/main.local.bicepparam`. Replace all examples, including subscription IDs, region, target account names, admin object ID, and notification email. Leave an account's `ptuDeployments` empty if it has no PTUs. List deployment names, not model names. Add existing telemetry workspaces to `existingTelemetryWorkspaces` if you already collect agent telemetry there. Do not list the same account/workspace twice.

The template creates Grafana Standard, Log Analytics, Application Insights, an action group, scoped RBAC, and PTU alerts. It never creates/modifies a model deployment. Check currently supported Grafana versions and region availability before deployment; `grafanaMajorVersion` is configurable.

Run in PowerShell after reviewing estimated Azure costs:

```powershell
az login
az account set --subscription "<monitoring-subscription-id>"
az group create --name "<monitoring-rg>" --location "<region>"
az deployment group what-if --resource-group "<monitoring-rg>" --parameters .\infra\main.local.bicepparam
# Only run after reviewing the what-if output:
az deployment group create --resource-group "<monitoring-rg>" --parameters .\infra\main.local.bicepparam
az deployment group show --resource-group "<monitoring-rg>" --name main --query properties.outputs
```

`az group create` creates a resource group before what-if; omit it if the group already exists. Deployments can fail if the caller lacks role-assignment permissions in any target scope. The deployment name defaults to the template filename (`main`); pass `--name` explicitly if desired.

Application Insights is configured for Entra-only ingestion. Grant your application identity **Monitoring Metrics Publisher** on the emitted Application Insights resource ID and configure the authenticated exporter before sending telemetry. The template intentionally does not grant publishing privileges to Grafana.

## Use existing monitoring infrastructure instead

Skip deployment entirely if you already have Grafana and telemetry storage. Grant the Grafana identity Monitoring Reader on target AI accounts and Log Analytics Reader on existing telemetry workspaces. Do not create a second telemetry pipeline unless you need a separate security/retention boundary.

## Configure the data source and dashboards

1. Open the Grafana endpoint and sign in as the assigned administrator. RBAC propagation can take several minutes.
2. Configure the built-in **Azure Monitor** data source for **Managed Identity** authentication. Run **Save & test**. No client secret is required.
3. Import `dashboards/foundry-overview.json`, `dashboards/foundry-agents.json`, and `dashboards/openai-ptu.json` using Grafana's dashboard import UI. Select the Azure Monitor data source for each import.
4. Set the top textbox controls to real values. `workspaceResourceId` is the **Log Analytics workspace ARM resource ID**, not its workspace GUID and not the Application Insights ID. Resource/region values must match the target account.
5. Optionally generate personalized files using `config.local.json`. The shared subscription default can be overridden independently in each dashboard; the workspace ARM ID can point to another subscription.

Import via the UI is intentional: managed Grafana APIs require their own Entra authentication and appropriate roles. This starter does not enable API keys or store a Grafana admin token.

## Connect Foundry agents

For service-managed agents, use the supported Foundry project Application Insights/tracing configuration for your agent type. For hosted/custom applications, configure an OpenTelemetry exporter in the application process. Creating Application Insights alone does not enable traces.

Inspect real retained attributes before relying on the included KQL. Provider/SDK versions can use different attribute names; adapt the documented contract or queries. Keep one model span per actual inference call so usage is not double-counted. See [telemetry](telemetry.md).

## Metric discovery

Before enabling PTU alerts, confirm metric names, dimensions, and observed values for each target:

```powershell
az monitor metrics list-definitions --resource "<AI-account-ARM-ID>" --query "[].{name:name.value,dimensions:dimensions[].value}" --output json
az monitor metrics list --resource "<AI-account-ARM-ID>" --metric AzureOpenAIProvisionedManagedUtilizationV2 --aggregation Average --interval PT1M --filter "ModelDeploymentName eq '<deployment-name>'"
az monitor metrics list --resource "<AI-account-ARM-ID>" --metric AzureOpenAIRequests --aggregation Total --interval PT1M --filter "ModelDeploymentName eq '<deployment-name>' and StatusCode eq '*'" --output json
```

Verify the actual StatusCode dimension values; the bundled 429 dashboard/alert assumes numeric HTTP status strings. Availability varies by model and SKU. Alerts do not bypass metric validation. Set `enablePtuAlerts = false` if you need to deploy read access first, then enable after discovery. Do not suppress missing metric errors as successful monitoring.

## Acceptance checklist

- All three dashboards import and query using the managed identity.
- Resource inventory contains expected authorized accounts/projects; missing rows trigger an RBAC check.
- A known agent execution produces correlated run, tool, and model spans with an OperationId.
- Model usage totals match known calls and do not count parent agent summaries twice.
- PTU utilization appears under the correct deployment; the legacy utilization metric is not used.
- A known request appears in request/token panels. No traffic is distinguished from missing permissions or unsupported metrics.
- A controlled failure appears in the trace table. Test alerts/action-group delivery in a nonproduction environment; do not overload a production PTU deployment to induce 429s.
- Evaluation panels are connected to actual evaluator events or clearly left unused.
- Retention, ingestion cap, access controls, and privacy settings meet your requirements.

The repository's offline CI cannot verify live data, KQL execution, model/SKU support, or notification delivery without your Azure environment.

## Private networking

Grafana and the new telemetry resources use public endpoints with authorization in this starter. For network-isolated environments, design Grafana private endpoints/outbound managed private endpoints plus Azure Monitor Private Link Scope, private DNS, and a deployment/ingestion host with the right network access. Do not simply disable public access without providing private paths. Existing Foundry inference network settings are untouched.

## Troubleshooting

| Symptom | Investigate |
| --- | --- |
| Grafana sign-in works but queries are forbidden | Managed identity data-source configuration, exact target RBAC scopes, role propagation |
| No PTU utilization | Correct account/deployment, provisioned SKU, metric definitions, region, time range, real traffic |
| Generic application traces but no agent charts | `gen_ai.operation.name` / agent attributes, actual SDK conventions, contract mapping |
| No traces at all | Exporter setup, publishing role, Entra authentication, ingestion network access, daily cap |
| KQL table/column errors | Querying the Log Analytics workspace tables, not an Application Insights classic table schema |
| Inaccurate percentiles/token totals | Sampling, missing usage fields, duplicate instrumentation, mixed workspaces |
| Alerts exist but no email | Action-group receiver, notification delivery, metric dimension matching, rule activation |
