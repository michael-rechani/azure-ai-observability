# Agent telemetry contract

The dashboards query workspace tables `AppRequests`, `AppDependencies`, and optionally `AppEvents`. They do not assume classic Application Insights `requests` / `dependencies` table names or undocumented Foundry-specific custom event schemas. Both span tables are always read together, because which one holds an agent run depends on the span kind: the Azure AI Projects SDK emits agent runs as client spans (`AppDependencies`), while a service that hosts an agent emits server spans (`AppRequests`).

## Required attributes

| Span | Attribute | Expected value |
| --- | --- | --- |
| Agent execution | `gen_ai.operation.name` | `invoke_agent` |
| Agent execution | `gen_ai.agent.name` | Actual agent name. The dashboards' optional `agent` control matches it case-insensitively and exactly (see [Reading the dashboards](setup.md#reading-the-dashboards)) |
| Tool execution | `gen_ai.operation.name` | `execute_tool` |
| Tool execution | `gen_ai.tool.name` | Actual tool name |
| Model request | `gen_ai.operation.name` | `chat` or `text_completion`; for Foundry prompt agents, the `invoke_agent` span itself carries the usage |
| Model request | `gen_ai.response.model` | Actual response model |
| Model request | `gen_ai.usage.input_tokens` | Actual numeric input token count |
| Model request | `gen_ai.usage.output_tokens` | Actual numeric output token count |

These follow OpenTelemetry GenAI naming conventions, but **instrumentation and exporter versions can differ**. Verify attributes in `Properties` with a known execution and map SDK-specific attributes if necessary. The generic Azure Monitor exporter alone does not instrument every agent framework.

Use properly nested spans to preserve the trace/OperationId and parent IDs. Mark failures with OpenTelemetry `StatusCode.ERROR`; do not catch and silently convert failures to success. Attach numeric usage only when returned by the provider. Do not estimate missing token counts as zero. The token panel counts `chat` and `text_completion` spans, and counts an `invoke_agent` span's usage only when no `chat` or `text_completion` span in the same trace carries usage, so a framework that reports tokens on both the agent span and its child model spans is not counted twice. Spans without usage appear as missing usage; a failed `invoke_agent` span with no usage is not counted as missing, because the run may never have reached the model.

The queries use `ItemCount` for sampled request totals. Trace percentile calculations reflect retained spans, not guaranteed population percentiles. Tail sampling, ingestion caps, missing spans, and duplicate instrumentation can change results. The sample uses 100% sampling for demonstration; configure sampling for your production workload.

## Optional attribution

Preserve `gen_ai.agent.id`, the actual deployment name, a project identifier such as `obs.project.name`, application role, and environment on spans. Do not use prompt contents or customer identifiers as attribute labels. The starter groups by agent/model/tool, not project; add explicit project/resource filters before sharing a workspace across unrelated teams.

## What Foundry did and did not emit

Observed in the Lab with a real Foundry prompt agent, `azure-ai-projects` 2.6.1 and the Azure Monitor OpenTelemetry distro in the calling application, with Application Insights connected to the project. This is one SDK version and one agent type; treat it as a worked example and re-check your own.

- **Where it lands.** Within about a minute, client spans appeared in `AppDependencies`, metrics in `AppMetrics`, and message structure in `AppGenAIContent`. Nothing agent-related appeared in `AppRequests` except a span the example script created itself.
- **Span names.** `invoke_agent <agent name>`, `create_agent <agent name>`, `create_conversation`, `AIProjectClient.get_openai_client`, and the underlying `POST /api/projects/.../agents/.../versions` HTTP calls.
- **Attributes on `invoke_agent`.** `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.agent.name`, `gen_ai.agent.id`, `gen_ai.agent.version`, `gen_ai.conversation.id`, `gen_ai.response.id`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `microsoft.gen_ai.main_agent.*` and `_MS.GenAIContentId`.
- **No `chat` spans.** Token usage sits on the `invoke_agent` span; the `gen_ai.client.token.usage` metric agreed with it. A run that failed (for example, an unknown agent name) carries no usage and no response model.
- **Noise.** The Azure Monitor exporter adds dependency spans such as `GET /metadata/instance/compute`, `GET /metadata/identity/oauth2/token` and `GET /AzMonSDKDynamicConfiguration*`. The dashboards ignore them because they carry no `gen_ai.operation.name`.
- **No server-side Foundry telemetry.** Three agent invocations were made without client-side tracing and nothing appeared in any Application Insights table after about eight minutes. Application Insights was connected to the project with local authentication disabled; the opposite configuration was not tested. Plan on instrumenting the calling application, and do not assume Foundry traces runs you do not instrument.

## `AppGenAIContent` is a data-protection surface

Current exporters write a workspace table, `AppGenAIContent`, with columns including `TraceId`, `SpanId`, `ParentSpanId`, `AgentName`, `AgentId`, `ModelName`, `InputMessages`, `OutputMessages`, `SystemInstructions`, `ToolDefinitions`, `ToolCallArguments`, `ToolCallResult` and `EvaluationExplanation`. With content recording off, the Lab rows held structure only (roles, part types, tool-call IDs) with no text. If you enable content recording, prompts, responses, tool arguments and tool results are stored there. No dashboard query reads this table, but any identity with Log Analytics Reader on the workspace, including Grafana's managed identity, can read it. Keep content recording off unless you need it, and use table-level access control and retention for this table when you do.

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
