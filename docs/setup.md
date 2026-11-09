# Connect, validate, and troubleshoot

Use the [Terraform guide](terraform.md) or [Bicep guide](bicep.md) to deploy the monitoring resources and dashboards. Do not apply both tools to the same resources.

## Prerequisites

- Existing Foundry and/or Azure OpenAI accounts. PTU alerts need existing provisioned deployments.
- Azure CLI and PowerShell 7 for the Bicep helper, or Terraform for the Terraform path. Python 3.12+ is optional for the dashboard generators and offline tests.
- An Azure Managed Grafana-supported region and permission to deploy resources and assign roles.
- An Entra object ID for the intended Grafana administrator and an alert email recipient.

Do not commit connection strings, tokens, personal addresses, or your local configuration.

## Use existing monitoring infrastructure instead

Skip deployment entirely if you already have Grafana and telemetry storage. Grant the Grafana identity Monitoring Reader on target AI accounts and Log Analytics Reader on existing telemetry workspaces. Do not create a second telemetry pipeline unless you need a separate security/retention boundary.

## Manual data-source and dashboard import

The deployment guides provision these automatically. For an existing Grafana instance, or if you choose manual setup:

1. Open the Grafana endpoint and sign in as the assigned administrator. RBAC propagation can take several minutes.
2. Configure the built-in **Azure Monitor** data source for **Managed Identity** authentication. Run **Save & test**. No client secret is required.
3. Import `dashboards/foundry-overview.json`, `dashboards/foundry-agents.json`, and `dashboards/openai-ptu.json` using Grafana's dashboard import UI. If the cost pipeline is deployed, also import `dashboards/azure-ai-costs.json` and `dashboards/business-overview.json`. Select the Azure Monitor data source for each import.
4. Set the top textbox controls to real values. `workspaceResourceId` and the business overview's `monitoringWorkspaceResourceId` are **Log Analytics workspace ARM resource IDs**, not workspace GUIDs or Application Insights IDs. In the business overview, set the former to the agent-telemetry workspace and the latter to the cost collector's workspace. Resource/region values must match the target account.
5. Optionally generate personalized files using `config.local.json` and the Python dashboard generator. This is not required: the shared subscription default can be changed independently in each dashboard, and the workspace ARM ID can point to another subscription.

Managed Grafana APIs require their own Entra authentication and appropriate roles. This starter does not enable API keys or store a Grafana admin token.

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

Verify the actual StatusCode dimension values on your own deployments. The bundled 429 dashboard and alert assume numeric HTTP status strings, which is what a live Lab run returned (`200`, `400` and `429` as strings). Availability varies by model and SKU. Alerts do not bypass metric validation. Set `enablePtuAlerts = false` if you need to deploy read access first, then enable after discovery. Do not suppress missing metric errors as successful monitoring.

A read-only check of metric *definitions* on three real Foundry (AIServices) accounts in an isolated lab found that all nine metrics used by the PTU, Foundry overview, and business dashboards are exposed (`AzureOpenAIRequests`, `AzureOpenAIProvisionedManagedUtilizationV2`, `AzureOpenAIContextTokensCacheMatchRate`, `AzureOpenAINormalizedTBTInMS`, `AzureOpenAITimeToResponse`, `AzureOpenAITTLTInMS`, `GeneratedTokens`, `ProcessedPromptTokens`, and `TokenTransaction`). None of those accounts had a PTU deployment, so a later Lab run created a short-lived Foundry account with a `GlobalProvisionedManaged` deployment and drove load through it until it throttled. With that deployment:

- Every PTU panel on the PTU dashboard returned data, as did the PTU panels on the business overview. This was verified on the Bicep stack's Grafana; the Terraform stack's Grafana returned data for all the metric panels, and the capacity panel was replaced afterwards (see below). Utilization exceeded 100% under overload, and the 429 count, cache-match rate and token panels all showed values. Metrics carry `ModelDeploymentName` (lower-cased as `modeldeploymentname` in Grafana), `StatusCode` and `Region` dimensions.
- All four PTU alert rules deployed in both stacks and fired. The throttling rule fired during the burst; the utilization rule is a five-minute average, so it fired only after the load was sustained.
- `AzureOpenAIProvisionedManagedUtilizationV2` reports a percentage per deployment, but **nothing in Azure Monitor or Resource Graph reports allocated PTUs**. Resource Graph does not index `Microsoft.CognitiveServices/accounts/deployments`, and a `ProvisionedManaged` SKU filter would miss the global and data-zone variants anyway. The dashboard therefore lists the deployments that report utilization (last, max and mean) and does not display allocated capacity.
- `FoundryModelEstimatedCost` has `ProjectId`, `ModelDeploymentName`, `ModelName`, `ModelVersion` and `Region` dimensions, so it can attribute estimated cost to a deployment. In the test its total was far below an hourly provisioned charge. A comparison against billing on an existing pay-as-you-go account found it well below billed cost, so do not treat it as spend or as the PTU invoice. The Foundry overview instead estimates pay-as-you-go cost from token counts × list price; see [Native estimate from Azure Monitor metrics](costs.md#native-estimate-from-azure-monitor-metrics-no-collector-no-secret).

Agent-trace queries were checked against a real workspace that received Azure AI Projects SDK telemetry; see [what Foundry did and did not emit](telemetry.md#what-foundry-did-and-did-not-emit). That run was limited to one SDK version, one region, and no server-side Foundry telemetry, so confirm the panels on your own traces.

## Acceptance checklist

- The three core dashboards and, when enabled, the cost dashboard and business overview query using Grafana's managed identity. The cost dashboards read snapshots from Log Analytics; the collector's separate managed identity accesses Cost Management.
- Resource inventory contains expected authorized accounts/projects; missing rows trigger an RBAC check.
- A known agent execution produces correlated run, tool, and model spans with an OperationId.
- Model usage totals match known calls and do not count parent agent summaries twice.
- PTU utilization appears under the correct deployment; the legacy utilization metric is not used.
- A known request appears in request/token panels. No traffic is distinguished from missing permissions or unsupported metrics.
- A controlled failure appears in the trace table and the business overview failure-rate panel. Test alerts/action-group delivery in a nonproduction environment; do not overload a production PTU deployment to induce 429s.
- Evaluation panels are connected to actual evaluator events or clearly left unused.
- If the cost pipeline is enabled, the scheduled collector produces a complete snapshot, the cost dashboard reports the expected account/currency data, and the business overview reports collection status and actual cost by currency. The Function runs at 06:00 UTC. Billing data can lag.
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
