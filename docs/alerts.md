# Alerting and response

## Included Azure Monitor metric alerts

| Rule | Default | Scope |
| --- | --- | --- |
| PTU utilization | Average utilization V2 >= 85% over five minutes, evaluated every minute | Each configured deployment dimension |
| PTU throttling | Total requests with StatusCode `429` > 0 over five minutes, evaluated every minute | Each configured deployment dimension |
| Agent failure rate | Optional; more than configured threshold after minimum run count, evaluated every five minutes | Agent name in `AppRequests` or `AppDependencies` |
| Agent p95 latency | Optional; retained-span p95 above configured milliseconds, evaluated every five minutes | Agent name in `AppRequests` or `AppDependencies` |
| Agent heartbeat | Optional; fewer than expected runs in 15 minutes, evaluated every five minutes | Monitoring workspace |

These are stateful Azure Monitor alerts with auto-mitigation and an email action group. The utilization threshold is configurable. Multiple named deployments are evaluated as separate time series, not an average that hides a saturated deployment. Deployment dimension values must be explicit provisioned deployment names.

The default utilization rule averages other dimensions (including stream type); the dashboard's maximum panel complements it. Adjust the aggregation or dimensions if your traffic mix requires a different saturation signal. Tune 429 thresholds for expected bursts and retry policy to reduce noise.

**Live behaviour.** In a Lab test on a real provisioned deployment, the 429 rule fired during a short burst of requests. The utilization rule averages over five minutes, so it fired only after the load was sustained for several minutes; a brief spike that the maximum panel shows will not necessarily page anyone. All four PTU rules, in both the Bicep and Terraform stacks, evaluated and fired.

## Included Grafana alert rule (Infinity cost path only)

When the opt-in Infinity cost dashboard is deployed, the repo also creates one Grafana-managed rule, **Infinity cost data source cannot query Cost Management**, in the **AI observability alerts** folder. It fires when the Cost Management query fails, for example after the client secret expires or is revoked. It evaluates hourly and fires after a second consecutive failure by default, and it carries the labels `component = cost-infinity` and `severity = warning`.

Unlike the metric alerts above, it does not use the Azure Monitor action group. Azure Managed Grafana's default contact point has no integration, so add a Grafana contact point and a notification policy that routes `component = cost-infinity`, or nothing is delivered. It cannot warn before the secret expires. Settings, ownership rules and limits are in [Get alerted when the secret fails](costs.md#get-alerted-when-the-secret-fails).

## Capacity runbook

1. Confirm the correct account, provisioned deployment, model/SKU, and matching metric dimensions.
2. Compare utilization average and maximum with 429s, token volume, cache match rate, and latency.
3. Inspect agent/model traces for workload changes, longer prompts, concurrency, tools, retries, and upstream errors.
4. Reduce unnecessary context/output, improve caching, bound concurrency, and honor provider retry guidance where appropriate.
5. Benchmark representative traffic before recommending capacity changes. Check regional capacity, quota, model minimums/increments, and cost impact through Azure management tools.

This repository never resizes or deletes deployments. Reducing deployment capacity does **not** cancel a PTU reservation. Deployment allocation, quota, available regional capacity, and reservation billing are separate concerns.

## Foundry alerts to configure after instrumentation

Agent log alerts are disabled by default. To enable them, set `enable_agent_alerts = true` in Terraform or `enableAgentAlerts = true` in Bicep only after confirming the logged operation name, agent property, run success semantics, sampling behavior, and expected traffic in your workspace. Failure-rate minimum counts and latency thresholds are configurable. The heartbeat rule is appropriate only where traffic is guaranteed; otherwise silence may be normal. Ingestion caps, sampling, and pipeline delays can make it fire even when the agent is healthy.

The KQL rules read both `AppRequests` and `AppDependencies` and match spans with `Properties["gen_ai.operation.name"] == "invoke_agent"` and an optional `Properties["gen_ai.agent.name"]`. Both tables are needed: the Azure AI Projects SDK records an agent invocation as a **client** span, which Application Insights stores in `AppDependencies`, whereas a service that hosts the agent records it as a server span in `AppRequests`. The earlier `AppRequests`-only rules never saw SDK-originated runs, so the heartbeat fired even while the agent was running. Validate the schema and the behavior of your instrumentation before enabling notifications (see [agent telemetry](telemetry.md)). Their query periods are explicit rather than Grafana macros. These examples do not cover every Foundry telemetry/exporter format.

No server-side Foundry spans were observed in the connected Application Insights resource in the Lab test (see [agent telemetry](telemetry.md#what-foundry-did-and-did-not-emit)), so these rules measure the calling application's instrumentation. An agent invoked by an uninstrumented caller is invisible to them.

The included agent rules always query the **new monitoring workspace**, even when a dashboard is configured to read an existing telemetry workspace. If your agents send data elsewhere, route the telemetry to the monitoring workspace or create separate alert rules scoped to the existing workspace; otherwise the heartbeat can report missing runs incorrectly.

Evaluation pass-rate regression and dependency failures are visible through workspace queries/dashboards but are not provisioned as alert rules; after confirming the relevant evaluator/dependency event schema, configure Azure Monitor scheduled-query rules or Grafana alert rules for:

- Evaluation pass-rate regression, with evaluator scale and sample-size requirements.
- Dependency failures for AI Search, memory/storage, or external tools actually used.

## Cost budget

The optional `monthly_ai_cost_budget_amount` in Terraform or `monthlyAiCostBudgetAmount` in Bicep creates a subscription-level Azure Cost Management budget filtered to the explicitly configured AI account resource IDs. It defaults to zero (disabled) and requires UTC start/end dates and at least one account. The notification threshold is configurable; the existing action group delivers email. Budgets are alerts, not hard spending caps, and Cost Management data can be delayed. This budget is account-scoped, not deployment/PTU-specific, and should not be interpreted as reservation charges. Use Cost Analysis and reservation reporting for billed detail.

The PTU dashboard lists the deployments that report utilization, but neither Azure Monitor nor Azure Resource Graph exposes a deployment's allocated PTUs, its price or the available regional quota. Read allocated capacity from the deployment itself (portal, `az cognitiveservices account deployment show`, or ARM) and quota from Azure Quotas. Billed cost is not estimated from utilization. Read it in the Azure portal's Cost Management, or in Grafana through the opt-in Infinity dashboard (see [billed cost options](costs.md)), which has its own limitations. There is no alert for a missing or delayed cost dashboard, apart from the opt-in alert for a failing Infinity secret.

The checked-in dashboard KQL uses Grafana `$__timeFilter` / `$__interval` macros. Native averages should not be mislabeled p95/p99.

Use a nonproduction environment for controlled failure and notification testing. Do not generate expensive synthetic model traffic or overload production deployments just to test an alert.
