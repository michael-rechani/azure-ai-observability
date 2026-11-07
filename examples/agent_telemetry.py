"""Demonstrate the telemetry contract without sending a prompt or calling a model."""

import os

from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.trace import SpanKind


def main():
    connection_string = os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"]
    configure_azure_monitor(
        connection_string=connection_string,
        credential=DefaultAzureCredential(),
        sampling_ratio=1.0,
    )
    tracer = trace.get_tracer("ai-observability-demo")
    with tracer.start_as_current_span("demo-agent-run", kind=SpanKind.SERVER) as agent:
        agent.set_attribute("gen_ai.operation.name", "invoke_agent")
        agent.set_attribute("gen_ai.agent.name", "telemetry-demo")
        agent.set_attribute("obs.telemetry.synthetic", True)
        with tracer.start_as_current_span("demo-tool", kind=SpanKind.CLIENT) as tool:
            tool.set_attribute("gen_ai.operation.name", "execute_tool")
            tool.set_attribute("gen_ai.tool.name", "synthetic-noop")
            tool.set_attribute("obs.telemetry.synthetic", True)
    trace.get_tracer_provider().force_flush()
    print("Sent synthetic agent/tool spans. No model was called; no token usage was fabricated.")


if __name__ == "__main__":
    main()
