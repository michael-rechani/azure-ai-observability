# Alerting and response

## Included Azure Monitor metric alerts

| Rule | Default | Scope |
| --- | --- | --- |
| PTU utilization | Average utilization V2 >= 85% over five minutes, evaluated every minute | Each configured deployment dimension |
| PTU throttling | Total requests with StatusCode `429` > 0 over five minutes, evaluated every minute | Each configured deployment dimension |
| Agent failure rate | Optional; more than configured threshold after minimum run count, evaluated every five minutes | Agent name in `AppRequests` |
| Agent p95 latency | Optional; retained-span p95 above configured milliseconds, evaluated every five minutes | Agent name in `AppRequests` |
| Agent heartbeat | Optional; fewer than expected runs in 15 minutes, evaluated every five minutes | Monitoring workspace |

These are stateful Azure Monitor alerts with auto-mitigation and an email action group. The utilization threshold is configurable. Multiple named deployments are evaluated as separate time series, not an average that hides a saturated deployment. Deployment dimension values must be explicit provisioned deployment names.

The default utilization rule averages other dimensions (including stream type); the dashboard's maximum panel complements it. Adjust the aggregation or dimensions if your traffic mix requires a different saturation signal. Tune 429 thresholds for expected bursts and retry policy to reduce noise.

## Capacity runbook

1. Confirm the correct account, provisioned deployment, model/SKU, and matching metric dimensions.
2. Compare utilization average and maximum with 429s, token volume, cache match rate, and latency.
3. Inspect agent/model traces for workload changes, longer prompts, concurrency, tools, retries, and upstream errors.
4. Reduce unnecessary context/output, improve caching, bound concurrency, and honor provider retry guidance where appropriate.
5. Benchmark representative traffic before recommending capacity changes. Check regional capacity, quota, model minimums/increments, and cost impact through Azure management tools.

This repository never resizes or deletes deployments. Reducing deployment capacity does **not** cancel a PTU reservation. Deployment allocation, quota, available regional capacity, and reservation billing are separate concerns.

## Foundry alerts to configure after instrumentation

Agent log alerts are disabled by default. To enable them, set `enable_agent_alerts = true` in Terraform or `enableAgentAlerts = true` in Bicep only after confirming the logged operation name, agent property, run success semantics, sampling behavior, and expected traffic in your workspace. Failure-rate minimum counts and latency thresholds are configurable. The heartbeat rule is appropriate only where traffic is guaranteed; otherwise silence may be normal. Ingestion caps, sampling, and pipeline delays can make it fire even when the agent is healthy.

The KQL rules assume agent invocation requests are stored in `AppRequests` with `Properties["gen_ai.operation.name"] == "invoke_agent"` and an optional `Properties["gen_ai.agent.name"]`. Validate this schema and the behavior of your instrumentation before enabling notifications. Their query periods are explicit rather than Grafana macros. These examples do not cover every Foundry telemetry/exporter format.

The included agent rules always query the **new monitoring workspace**, even when a dashboard is configured to read an existing telemetry workspace. If your agents send data elsewhere, route the telemetry to the monitoring workspace or create separate alert rules scoped to the existing workspace; otherwise the heartbeat can report missing runs incorrectly.

Evaluation pass-rate regression and dependency failures are visible through workspace queries/dashboards but are not provisioned as alert rules; after confirming the relevant evaluator/dependency event schema, configure Azure Monitor scheduled-query rules or Grafana alert rules for:

- Evaluation pass-rate regression, with evaluator scale and sample-size requirements.
- Dependency failures for AI Search, memory/storage, or external tools actually used.

## Cost budget

The optional `monthly_ai_cost_budget_amount` in Terraform or `monthlyAiCostBudgetAmount` in Bicep creates a subscription-level Azure Cost Management budget filtered to the explicitly configured AI account resource IDs. It defaults to zero (disabled) and requires UTC start/end dates and at least one account. The notification threshold is configurable; the existing action group delivers email. Budgets are alerts, not hard spending caps, and Cost Management data can be delayed. This budget is account-scoped, not deployment/PTU-specific, and should not be interpreted as reservation charges. Use Cost Analysis and reservation reporting for billed detail.

Dashboard values for allocated PTUs describe current provisioned deployment capacity, not its price or available regional quota. The separate opt-in cost dashboard reads the latest complete account-attributed snapshot rather than estimating dollars from utilization. Its status panel reports missing or stale collections and incomplete selected periods; inspect Function Application Insights logs or the GitHub Actions run, plus ingestion/RBAC configuration, when collection fails. There is no automatic collector-failure alert in this starter. See [cost collection](costs.md) for limitations and recovery.

The checked-in dashboard KQL uses Grafana `$__timeFilter` / `$__interval` macros. Native averages should not be mislabeled p95/p99.

Use a nonproduction environment for controlled failure and notification testing. Do not generate expensive synthetic model traffic or overload production deployments just to test an alert.
