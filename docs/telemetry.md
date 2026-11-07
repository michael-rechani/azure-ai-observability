# Agent telemetry contract

The dashboards query workspace tables `AppRequests`, `AppDependencies`, and (optionally) `AppEvents`. They deliberately do not assume classic Application Insights `requests` / `dependencies` table names or undocumented Foundry-specific custom event schemas.

## Required attributes

| Span | Attribute | Expected value |
| --- | --- | --- |
| Agent execution | `gen_ai.operation.name` | `invoke_agent` |
| Agent execution | `gen_ai.agent.name` | Actual agent name |
| Tool execution | `gen_ai.operation.name` | `execute_tool` |
| Tool execution | `gen_ai.tool.name` | Actual tool name |
| Model request | `gen_ai.operation.name` | `chat` or `text_completion` |
| Model request | `gen_ai.response.model` | Actual response model |
| Model request | `gen_ai.usage.input_tokens` | Actual numeric input token count |
| Model request | `gen_ai.usage.output_tokens` | Actual numeric output token count |

These follow OpenTelemetry GenAI naming conventions, but **instrumentation and exporter versions can differ**. Verify attributes in `Properties` with a known execution and map SDK-specific attributes if necessary. The generic Azure Monitor exporter alone does not instrument every agent framework.

Use properly nested spans to preserve the trace/OperationId and parent IDs. Mark failures with OpenTelemetry `StatusCode.ERROR`; do not catch and silently convert failures to success. Attach numeric usage only when returned by the provider. Do not estimate missing token counts as zero. The token panel exposes missing usage spans, and counts only model request spans to avoid parent/child double counting.

The queries use `ItemCount` for sampled request totals. Trace percentile calculations reflect retained spans, not guaranteed population percentiles. Tail sampling, ingestion caps, missing spans, and duplicate instrumentation can change results. The sample uses 100% sampling for a small demonstration only; choose production settings deliberately.

## Optional attribution

Preserve `gen_ai.agent.id`, the actual deployment name, a project identifier such as `obs.project.name`, application role, and environment on spans. Do not use prompt contents or customer identifiers as attribute labels. The starter groups by agent/model/tool, not project; add explicit project/resource filters before sharing a workspace across unrelated teams.

## Synthetic demonstration

`examples/agent_telemetry.py` sends one synthetic agent run and one nested synthetic tool span. It calls no model and invents no usage metrics. It is not a Foundry agent or an end-to-end AI integration.

Use an isolated demo Application Insights resource. Set `APPLICATIONINSIGHTS_CONNECTION_STRING` in your environment using the real resource's connection string, without committing it. Since the template disables local ingestion authentication, the credential used by `DefaultAzureCredential` needs **Monitoring Metrics Publisher** on that Application Insights resource.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\examples\requirements.txt
# Authenticate locally or configure a managed identity in the runtime.
az login
.\.venv\Scripts\python.exe .\examples\agent_telemetry.py
```

The example depends on the Azure Monitor OpenTelemetry distro, which remains supported; consult current Microsoft guidance for new applications and framework-specific instrumentation. Do not combine two exporters that send the same spans to the same destination.

## Evaluation events

The optional evaluator panel expects actual evaluation results sent as Application Insights custom events:

| Field | Value |
| --- | --- |
| Event name | `obs.evaluation` |
| Property `obs.evaluator.name` | Evaluator name |
| Property `obs.evaluation.score` | Numeric score, with the evaluator's scale documented |
| Property `obs.evaluation.passed` | Boolean |

Each event represents one evaluated sample. Do not attach raw prompts, responses, or sensitive labels. The panel groups scores by evaluator and reports malformed samples; it does not combine incompatible score scales or run an evaluator. Configure your evaluation workflow/exporter to emit custom events using the supported SDK path; ordinary spans are not automatically converted to `AppEvents`.

## Privacy

Leave prompt/response body capture off. Audit framework-specific content-recording switches, tool arguments, exception messages, HTTP logs, and automatic instrumentations before production. SDK defaults differ: omission from the demo does not guarantee other instrumentors won't capture content. Restrict telemetry access and align retention with your organization's policy.

## Inspect actual schema

Run this in the **Log Analytics workspace** query editor (no Grafana macros):

```kusto
union AppRequests, AppDependencies
| where TimeGenerated > ago(1h)
| project TimeGenerated, Name, OperationId, Success, Properties
| take 20
```

Raw `Properties` can contain sensitive attributes in existing systems; inspect only within authorized Azure tooling. Query failures are setup errors, not evidence of a healthy agent.
