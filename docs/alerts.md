# Alerting and response

## Included Azure Monitor metric alerts

| Rule | Default | Scope |
| --- | --- | --- |
| PTU utilization | Average utilization V2 >= 85% over five minutes, evaluated every minute | Each configured deployment dimension |
| PTU throttling | Total requests with StatusCode `429` > 0 over five minutes, evaluated every minute | Each configured deployment dimension |

These are stateful Azure Monitor alerts with auto-mitigation and an email action group. The utilization threshold is configurable. Multiple named deployments are evaluated as separate time series, not an average that hides a saturated deployment. Deployment dimension values must be explicit provisioned deployment names.

The default utilization rule averages other dimensions (including stream type); the dashboard's maximum panel complements it. Change aggregation/dimensions deliberately if your traffic mix requires a different saturation signal. Tune 429 thresholds for expected bursts and retry policy to reduce noise.

## Capacity runbook

1. Confirm the correct account, provisioned deployment, model/SKU, and matching metric dimensions.
2. Compare utilization average and maximum with 429s, token volume, cache match rate, and latency.
3. Inspect agent/model traces for workload changes, longer prompts, concurrency, tools, retries, and upstream errors.
4. Reduce unnecessary context/output, improve caching, bound concurrency, and honor provider retry guidance where appropriate.
5. Benchmark representative traffic before recommending capacity changes. Check regional capacity, quota, model minimums/increments, and cost impact through Azure management tools.

This repository never resizes or deletes deployments. Reducing deployment capacity does **not** cancel a PTU reservation. Deployment allocation, quota, available regional capacity, and reservation billing are separate concerns.

## Foundry alerts to configure after instrumentation

The repository does not install universal Foundry alerts against an unknown telemetry schema. After confirming your actual telemetry, configure Azure Monitor scheduled-query rules or Grafana alert rules for:

- Agent run failure rate with a minimum traffic count.
- Agent/tool p95 latency against workload-specific SLOs.
- Missing telemetry heartbeat, including known expected traffic and ingestion-cap conditions.
- Evaluation pass-rate regression, with evaluator scale and sample-size requirements.
- Dependency failures for AI Search, memory/storage, or external tools actually used.

The checked-in KQL uses Grafana `$__timeFilter` / `$__interval` macros. For Azure Monitor log alerts, replace these with explicit `ago(...)` / `bin(..., ...)` windows and return the exact numeric column expected by the alert rule. Native averages should not be mislabeled p95/p99.

Use a nonproduction environment for controlled failure and notification testing. Do not generate expensive synthetic model traffic or overload production deployments just to test an alert.
