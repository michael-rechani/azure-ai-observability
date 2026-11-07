"""Generate importable Grafana dashboards using only the Python standard library."""

import argparse
import json
from pathlib import Path
import re
import uuid

ROOT = Path(__file__).resolve().parents[1]
DS = {"type": "grafana-azure-monitor-datasource", "uid": "${DS_AZURE_MONITOR}"}
NAMESPACE = "Microsoft.CognitiveServices/accounts"


def validate_config(config):
    uuid.UUID(config["subscription"])
    for section in ("foundry", "ptu"):
        for field in ("resourceGroup", "account", "region"):
            value = config[section][field]
            if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.()-]+", value):
                raise ValueError(f"{section}.{field} must be a nonempty Azure resource name/region")
    deployment = config["ptu"]["deployment"]
    if not isinstance(deployment, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+|\*", deployment):
        raise ValueError("ptu.deployment must be a deployment name or *")
    workspace = config["workspaceResourceId"]
    if not isinstance(workspace, str) or not re.fullmatch(
        r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/"
        r"providers/Microsoft\.OperationalInsights/workspaces/[^/]+", workspace
    ):
        raise ValueError("workspaceResourceId must be a Log Analytics workspace ARM ID")
    uuid.UUID(workspace.split("/")[2])


def textbox(name, value, label=None):
    return {
        "name": name, "label": label or name, "type": "textbox",
        "query": value, "current": {"text": value, "value": value},
        "hide": 0,
    }


def panel(number, title, target, unit="short", kind="timeseries", description=""):
    return {
        "id": number, "title": title, "type": kind, "description": description,
        "datasource": DS, "targets": [target],
        "gridPos": {"h": 8, "w": 12, "x": ((number - 1) % 2) * 12, "y": ((number - 1) // 2) * 8},
        "fieldConfig": {"defaults": {"unit": unit, "noValue": "No data"}, "overrides": []},
        "options": (
            {"legend": {"displayMode": "list", "placement": "bottom"},
             "tooltip": {"mode": "multi", "sort": "none"}}
            if kind == "timeseries" else {"showHeader": True}
        ),
    }


def metric(name, aggregation="Average", dimensions=None):
    return {
        "refId": "A", "datasource": DS, "queryType": "Azure Monitor",
        "subscription": "$subscription",
        "azureMonitor": {
            "resources": [{
                "subscription": "$subscription", "resourceGroup": "$resourceGroup",
                "resourceName": "$account", "region": "$region", "metricNamespace": NAMESPACE,
            }],
            "metricNamespace": NAMESPACE, "metricName": name,
            "aggregation": aggregation, "timeGrain": "auto", "top": "100",
            "dimensionFilters": dimensions or [
                {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$deployment"]}
            ],
        },
    }


def logs(filename, table=False):
    return {
        "refId": "A", "datasource": DS, "queryType": "Azure Log Analytics",
        "azureLogAnalytics": {
            "resources": ["$workspaceResourceId"],
            "query": (ROOT / "queries" / filename).read_text(encoding="utf-8"),
            "resultFormat": "table" if table else "time_series",
            "timeColumn": "TimeGenerated", "dashboardTime": True,
        },
    }


def dashboard(uid, title, variables, panels):
    return {
        "uid": uid, "title": title, "schemaVersion": 39, "version": 1,
        "editable": True, "tags": ["azure", "ai-observability"],
        "timezone": "browser", "refresh": "1m",
        "time": {"from": "now-6h", "to": "now"}, "panels": panels,
        "templating": {"list": variables},
        "__inputs": [{
            "name": "DS_AZURE_MONITOR", "label": "Azure Monitor",
            "type": "datasource", "pluginId": "grafana-azure-monitor-datasource",
            "pluginName": "Azure Monitor",
        }],
    }


def build(config):
    validate_config(config)
    subscription = textbox("subscription", config["subscription"])
    workspace = textbox("workspaceResourceId", config["workspaceResourceId"], "Telemetry workspace ARM ID")
    ptu_variables = [subscription] + [
        textbox(name, config["ptu"][key])
        for name, key in (("resourceGroup", "resourceGroup"), ("account", "account"), ("region", "region"))
    ] + [textbox("deployment", config["ptu"]["deployment"], "PTU deployment (or * to split all)")]
    request_dimensions = [
        {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$deployment"]},
        {"dimension": "StatusCode", "operator": "eq", "filters": ["*"]},
    ]
    throttling_dimensions = [
        {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$deployment"]},
        {"dimension": "StatusCode", "operator": "eq", "filters": ["429"]},
    ]
    specifications = [
        ("PTU utilization - average", "AzureOpenAIProvisionedManagedUtilizationV2", "Average", "percent", None),
        ("PTU utilization - maximum", "AzureOpenAIProvisionedManagedUtilizationV2", "Maximum", "percent", None),
        ("Requests by status code", "AzureOpenAIRequests", "Total", "short", request_dimensions),
        ("Throttled requests (429)", "AzureOpenAIRequests", "Total", "short", throttling_dimensions),
        ("Input tokens per interval", "ProcessedPromptTokens", "Total", "short", None),
        ("Output tokens per interval", "GeneratedTokens", "Total", "short", None),
        ("Time to response - gateway average", "AzureOpenAITimeToResponse", "Average", "ms", None),
        ("Time to last byte - average", "AzureOpenAITTLTInMS", "Average", "ms", None),
        ("Time between tokens - average", "AzureOpenAINormalizedTBTInMS", "Average", "ms", None),
        ("Prompt cache match rate", "AzureOpenAIContextTokensCacheMatchRate", "Average", "percent", None),
    ]
    ptu = dashboard("azure-openai-ptu", "Azure OpenAI - PTU performance", ptu_variables, [
        panel(i, title, metric(name, agg, dimensions), unit,
              description="Azure platform metric. Availability varies by model/SKU. Counts are per time bucket, not per second.")
        for i, (title, name, agg, unit, dimensions) in enumerate(specifications, 1)
    ])
    ptu["panels"][0]["fieldConfig"]["defaults"]["thresholds"] = {
        "mode": "absolute", "steps": [
            {"color": "green", "value": None}, {"color": "orange", "value": 85},
            {"color": "red", "value": 100},
        ],
    }
    agent_specs = [
        ("Agent run latency", "agent-latency.kql", "ms", False),
        ("Agent runs and failures", "agent-runs.kql", "short", False),
        ("Tool performance", "tool-performance.kql", "short", True),
        ("Model token usage and missing usage spans", "model-tokens.kql", "short", False),
        ("Failed operations - trace IDs", "failed-operations.kql", "short", True),
        ("Instrumentation coverage", "telemetry-coverage.kql", "short", False),
        ("Evaluation results (optional custom events)", "evaluations.kql", "short", True),
    ]
    agents = dashboard("foundry-agent-operations", "Foundry - Agent operations", [workspace], [
        panel(i, title, logs(filename, table), unit, "table" if table else "timeseries",
              "Requires the documented telemetry contract. No data is not evidence of health. Latency percentiles reflect retained spans.")
        for i, (title, filename, unit, table) in enumerate(agent_specs, 1)
    ])
    inventory_target = {
        "refId": "A", "datasource": DS, "queryType": "Azure Resource Graph",
        "subscriptions": ["$subscription"],
        "azureResourceGraph": {
            "query": (ROOT / "queries" / "inventory.kql").read_text(encoding="utf-8"),
            "resultFormat": "table", "scope": "subscription",
        },
    }
    foundry_variables = [subscription, workspace] + [
        textbox(name, config["foundry"][key])
        for name, key in (("resourceGroup", "resourceGroup"), ("account", "account"), ("region", "region"))
    ] + [textbox("deployment", "*", "OpenAI deployment (or *)")]
    foundry = dashboard("foundry-overview", "Foundry - Resource and model overview", foundry_variables, [
        panel(1, "Accessible Foundry / OpenAI / ML resources", inventory_target, kind="table",
              description="Inventory is RBAC-filtered and includes ML workspaces; not every row is a Foundry hub."),
        panel(2, "Agent telemetry coverage", logs("telemetry-coverage.kql")),
        panel(3, "OpenAI requests by deployment and status", metric("AzureOpenAIRequests", "Total", request_dimensions)),
        panel(4, "OpenAI inference tokens per interval", metric("TokenTransaction", "Total")),
    ])
    for item in foundry["panels"][2:]:
        item["description"] = "OpenAI-specific metric on the selected account; not a universal metric for every Foundry model."
    return {"foundry-overview.json": foundry, "foundry-agents.json": agents, "openai-ptu.json": ptu}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "config.example.json")
    parser.add_argument("--output", type=Path, default=ROOT / "dashboards")
    args = parser.parse_args()
    dashboards = build(json.loads(args.config.read_text(encoding="utf-8")))
    args.output.mkdir(parents=True, exist_ok=True)
    for name, content in dashboards.items():
        (args.output / name).write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(dashboards)} dashboards in {args.output}")


if __name__ == "__main__":
    main()
