# Azure AI observability

Monitoring-only starter for **Microsoft Foundry** and **Azure OpenAI provisioned throughput (PTUs)**, with separate dashboards on shared **Azure Managed Grafana + Azure Monitor + Application Insights / Log Analytics** infrastructure.

**No Prometheus, Kubernetes cluster, model deployments, PTU scaling, or reservations are created.** Azure infrastructure is deployed only when you explicitly run the deployment commands. This monitors Azure-hosted OpenAI, not OpenAI's direct API.

## Dashboards

These are **actual Grafana screenshots with simulated data**, not results from an Azure deployment. The included dashboards use the same layouts with Azure Monitor and Log Analytics when deployed.

### Foundry agent operations

![Grafana preview of Foundry agent operations with simulated data](docs/images/foundry-grafana-preview.png)

### Azure OpenAI PTU performance

![Grafana preview of Azure OpenAI PTU performance with simulated data](docs/images/ptu-grafana-preview.png)

## Deploy with Terraform

Terraform can create the monitoring resource group, Managed Grafana, Log Analytics, Application Insights, scoped permissions, PTU alerts, the Grafana data source, and all three dashboards. Deployment uses two Terraform stages: Azure infrastructure first, then Grafana's data-plane resources after access has propagated. Follow the [Terraform deployment guide](docs/terraform.md).

Existing Foundry/OpenAI accounts and PTU deployments are monitored, not created or resized. Applications still need to send agent telemetry, and live metric support, permissions, and alert delivery must be verified in your environment.

## What is included

| Area | Included | Prerequisite / boundary |
| --- | --- | --- |
| Foundry estate | Accessible accounts, projects, and ML workspace inventory | Resource Graph returns only resources visible to the Grafana identity |
| Foundry agents | Run latency percentiles, failures, tool performance, token usage, trace IDs, observed telemetry counts | Application Insights instrumentation matching the documented contract |
| Foundry model usage | OpenAI requests and inference tokens on a selected Foundry account | OpenAI-specific metrics; not a universal endpoint for all Foundry model providers |
| Evaluations | Optional evaluator score / pass-fail dashboard | Publish evaluation events explicitly; this repo does not run evaluations |
| Azure OpenAI PTUs | Utilization V2, requests by status, 429s, input/output tokens, gateway latency, cache hit rate | Existing provisioned deployments and supported metric definitions |
| Alerting | Per-deployment sustained PTU utilization and 429 metric alerts with an email action group | Named PTU deployments supplied in infrastructure parameters |
| Operations | Terraform, Bicep alternative, reproducible dashboard generator, queries, telemetry demo, CI, troubleshooting runbooks | No Azure credentials needed to validate source locally |

This is a foundation for broad Foundry observability, **not a claim that every Foundry feature emits telemetry automatically**. See [coverage and architecture](docs/architecture.md) for costs, safety, evaluations, dependencies, and gaps.

## Quick start

1. Follow [Terraform setup](docs/terraform.md) to deploy the Azure resources, Azure Monitor data source, and dashboards, or use the [Bicep/manual setup](docs/setup.md). Pick one tool to own a deployment; do not apply both to the same resources.
2. Enter the target subscription/account/region and Log Analytics workspace ARM ID in the dashboard's top controls, or generate personalized dashboard JSON before the Grafana Terraform stage.
3. Connect agent telemetry using [the instrumentation contract](docs/telemetry.md). Platform PTU metrics do not need an application exporter.

The checked-in dashboards use obvious example values. They are importable templates, not connected to a real subscription. For your own defaults, copy `config.example.json` to ignored `config.local.json`, then:

```powershell
python .\scripts\build_dashboards.py --config .\config.local.json --output .\local-dashboards
```

Keep personalized exports out of commits. Accounts can be switched with the dashboard controls; use a new dashboard copy for side-by-side environments. The Foundry agent dashboard aggregates the selected workspace, so use separate workspaces or add project/resource filters if teams share one.

## Preview the dashboards without Azure

With Docker and Docker Compose installed, run:

```powershell
docker compose -f .\demo\docker-compose.yml up -d
```

Open [Grafana at localhost:3100](http://127.0.0.1:3100), then open the **Simulated preview** folder. The two dashboards use Grafana's built-in TestData source, not Azure. Their banners, titles, and distinct UIDs mark every value as simulated; the displayed filter controls are layout examples and do not filter the sample data. The preview has the same panel positions and styles as the production dashboards, but Grafana's native interface may differ from the original illustrations.

The demo listens on `127.0.0.1` and permits anonymous viewing for local evaluation only. Never expose it publicly or use it for production. Stop it when finished:

```powershell
docker compose -f .\demo\docker-compose.yml down
```

## Repository layout

```text
infra/       Bicep monitoring resources, existing-target RBAC, PTU alerts
terraform/   Native Azure resources and Grafana data source/dashboard deployment
dashboards/  Importable Foundry overview, agent operations, and PTU dashboards
demo/        Local-only Grafana preview using clearly labeled simulated data
docs/images/ Actual Grafana screenshots with simulated data
queries/     Workspace KQL and Azure Resource Graph inventory query
scripts/     Standard-library dashboard generator
examples/    Synthetic OpenTelemetry example (no model calls)
docs/        Setup, coverage, telemetry contract, and alert runbooks
tests/       Dashboard structure, units, filtering, and reproducibility checks
```

## Local validation

```powershell
python .\scripts\build_dashboards.py
python .\scripts\build_demo_dashboards.py
python -m unittest discover -s .\tests -v
az bicep build --file .\infra\main.bicep --outfile "$env:TEMP\ai-observability-main.json"
az bicep build-params --file .\infra\main.example.bicepparam --outfile "$env:TEMP\ai-observability-params.json"
```

These commands do not deploy anything. CI also validates and mock-tests both Terraform stages. Offline checks do not replace live Azure metric, KQL, RBAC, and dashboard verification; use the [acceptance checklist](docs/setup.md#acceptance-checklist).

## Security and cost defaults

- Managed identity for Grafana; scoped read roles, no model management permissions.
- Application Insights local authentication disabled; telemetry senders need Entra authentication and the **Monitoring Metrics Publisher** role on the Application Insights resource. Terraform can assign this role to explicitly listed principals.
- Public endpoints with Entra authorization in this starter. Private endpoints and Azure Monitor Private Link require a separate networking design; see setup.
- No prompt, response, tool-argument, or exception-content capture in the demo.
- Log retention defaults to 30 days with a 1 GB daily ingestion cap. A cap can cause gaps and is **not** a complete spending limit.
- Grafana hosting, telemetry ingestion/retention, and alert rules can incur charges. PTU deployment and reservation charges remain separate.

## References

- [Azure OpenAI monitoring metrics](https://learn.microsoft.com/azure/foundry/openai/monitor-openai-reference)
- [Operating provisioned deployments](https://learn.microsoft.com/azure/foundry/openai/how-to/provisioned-get-started)
- [Foundry agent tracing](https://learn.microsoft.com/azure/foundry/observability/concepts/trace-agent-concept)
- [Application Insights agent monitoring and Grafana views](https://learn.microsoft.com/azure/azure-monitor/app/agents-view)
- [Azure Managed Grafana Azure Monitor integration](https://learn.microsoft.com/azure/managed-grafana/how-to-connect-azure-monitor)
