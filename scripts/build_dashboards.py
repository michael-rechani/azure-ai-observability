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
    defaults = {"unit": unit, "noValue": "No data"}
    if kind == "timeseries":
        defaults.update({
            "color": {"mode": "palette-classic"},
            "custom": {
                "drawStyle": "line",
                "lineInterpolation": "linear",
                "lineWidth": 2,
                "fillOpacity": 10,
                "gradientMode": "opacity",
                "showPoints": "never",
                "spanNulls": False,
                "axisPlacement": "auto",
            },
        })
    return {
        "id": number, "title": title, "type": kind, "description": description,
        "datasource": DS, "targets": [target],
        "gridPos": {"h": 8, "w": 12, "x": ((number - 1) % 2) * 12, "y": ((number - 1) // 2) * 8},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": (
            {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull"]},
             "tooltip": {"mode": "multi", "sort": "none"}}
            if kind == "timeseries" else {"showHeader": True}
        ),
    }


def fixed_color(item, color):
    item["fieldConfig"]["defaults"]["color"] = {"mode": "fixed", "fixedColor": color}


def override(item, pattern, properties):
    item["fieldConfig"]["overrides"].append({
        "matcher": {"id": "byRegexp", "options": pattern},
        "properties": [{"id": name, "value": value} for name, value in properties.items()],
    })


def metric(name, aggregation="Average", dimensions=None, variable_prefix=""):
    def variable(name):
        suffix = name[0].upper() + name[1:] if variable_prefix else name
        return f"${variable_prefix}{suffix}"

    return {
        "refId": "A", "datasource": DS, "queryType": "Azure Monitor",
        "subscription": variable("subscription"),
        "azureMonitor": {
            "resources": [{
                "subscription": variable("subscription"), "resourceGroup": variable("resourceGroup"),
                "resourceName": variable("account"), "region": variable("region"),
                "metricNamespace": NAMESPACE,
            }],
            "metricNamespace": NAMESPACE, "metricName": name,
            "aggregation": aggregation, "timeGrain": "auto", "top": "100",
            "dimensionFilters": dimensions or [
                {
                    "dimension": "ModelDeploymentName",
                    "operator": "eq",
                    "filters": [variable("deployment")],
                }
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


def cost_logs(filename, table=False, workspace="workspaceResourceId"):
    target = logs(filename, table)
    query = target["azureLogAnalytics"]
    query["resources"] = [f"${workspace}"]
    prefix = (ROOT / "queries" / "cost-snapshot.kql").read_text(encoding="utf-8")
    query["query"] = prefix + "\n" + query["query"]
    query["dashboardTime"] = False
    return target


def token_cost_panel(number):
    """Estimated pay-as-you-go cost: token metrics x a list-price table, joined in Grafana."""
    model_dimension = [{"dimension": "ModelName", "operator": "eq", "filters": ["*"]}]
    input_tokens = metric("InputTokens", "Total", model_dimension)
    output_tokens = metric("OutputTokens", "Total", model_dimension)
    output_tokens["refId"] = "B"
    prices = logs("model-prices.kql", table=True)
    prices["refId"] = "C"
    prices["azureLogAnalytics"]["dashboardTime"] = False

    def calculate(alias, left, operator, right):
        side = lambda name: {"matcher": {"id": "byName", "options": name}}
        return {"id": "calculateField", "options": {
            "mode": "binary", "alias": alias,
            "binary": {
                "left": side(left), "operator": operator,
                "right": {"fixed": right} if right.isdigit() else side(right),
            },
        }}

    def positive(field):
        return {"fieldName": field, "config": {"id": "greater", "options": {"value": 0}}}

    transformations = [
        {"id": "labelsToFields", "options": {"mode": "columns"}},
        {"id": "merge", "options": {}},
        {"id": "groupBy", "options": {"fields": {
            "modelname": {"aggregations": [], "operation": "groupby"},
            "Input Tokens": {"aggregations": ["sum"], "operation": "aggregate"},
            "Output Tokens": {"aggregations": ["sum"], "operation": "aggregate"},
            "InputPer1M": {"aggregations": ["max"], "operation": "aggregate"},
            "OutputPer1M": {"aggregations": ["max"], "operation": "aggregate"},
        }}},
        {"id": "filterByValue", "options": {
            "type": "include", "match": "any",
            "filters": [positive("Input Tokens (sum)"), positive("Output Tokens (sum)")],
        }},
        calculate("inputUsd", "Input Tokens (sum)", "*", "InputPer1M (max)"),
        calculate("outputUsd", "Output Tokens (sum)", "*", "OutputPer1M (max)"),
        calculate("totalMicroUsd", "inputUsd", "+", "outputUsd"),
        calculate("Estimated cost", "totalMicroUsd", "/", "1000000"),
        {"id": "organize", "options": {
            "excludeByName": {"inputUsd": True, "outputUsd": True, "totalMicroUsd": True},
            "indexByName": {
                "modelname": 0, "Input Tokens (sum)": 1, "Output Tokens (sum)": 2,
                "InputPer1M (max)": 3, "OutputPer1M (max)": 4, "Estimated cost": 5,
            },
            "renameByName": {
                "modelname": "Model",
                "Input Tokens (sum)": "Input tokens",
                "Output Tokens (sum)": "Output tokens",
                "InputPer1M (max)": "Input price/1M",
                "OutputPer1M (max)": "Output price/1M",
                "Estimated cost": "Est. cost (USD)",
            },
        }},
    ]
    item = panel(
        number, "Estimated pay-as-you-go token cost by model (list price, not billed)", input_tokens,
        kind="table",
        description=(
            "An estimate, not billed cost. Tokens in the selected time range (Azure Monitor InputTokens "
            "and OutputTokens for every model on the selected account) multiplied by the Global Standard "
            "list prices in queries/model-prices.kql. Input tokens are priced as uncached, so a workload "
            "with heavy prompt caching is overstated. Batch, Flex, Priority, regional and data-zone "
            "pricing, hosted-agent compute, PTU hourly charges and tax are not covered; tokens served by "
            "a PTU deployment are priced as if pay-as-you-go. A model missing from the price table shows "
            "'no list price' and is left out of the cost total in the footer (its tokens are still "
            "counted). Costs are rounded to cents. Use the cost collector and the "
            "Costs dashboard for billed cost."
        ),
    )
    item["targets"] = [input_tokens, output_tokens, prices]
    item["gridPos"] = {"h": 10, "w": 24, "x": 0, "y": ((number - 1) // 2) * 8}
    item["transformations"] = transformations
    item["fieldConfig"]["defaults"]["unit"] = "short"
    item["options"].update({
        "sortBy": [{"displayName": "Est. cost (USD)", "desc": True}],
        "footer": {
            "show": True, "reducer": ["sum"], "countRows": False,
            "fields": ["Input tokens", "Output tokens", "Est. cost (USD)"],
        },
    })
    override(item, "/^(Input|Output) price\\/1M$/", {
        "unit": "currencyUSD", "decimals": 2, "noValue": "not listed",
    })
    override(item, "/^Est\\. cost \\(USD\\)$/", {
        "unit": "currencyUSD", "decimals": 2,
        "mappings": [{"type": "value", "options": {"0": {"text": "no list price", "index": 0}}}],
    })
    return item


def resource_graph(filename, subscription):
    return {
        "refId": "A", "datasource": DS, "queryType": "Azure Resource Graph",
        "subscriptions": [subscription],
        "azureResourceGraph": {
            "query": (ROOT / "queries" / filename).read_text(encoding="utf-8"),
            "resultFormat": "table", "scope": "subscription",
        },
    }


def dashboard(uid, title, variables, panels, related=()):
    result = {
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
    if related:
        result["links"] = [
            {
                "type": "link", "title": link_title,
                "url": f"/d/{link_uid}/_" + (
                    "?" + "&".join(
                        f"var-{target}=${{{source}:percentencode}}"
                        for target, source in variable_map
                    ) if variable_map else ""
                ),
                "icon": "external link alt", "keepTime": True,
                "includeVars": False, "targetBlank": False,
            }
            for link_title, link_uid, variable_map in related
        ]
    return result


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
    ], related=(
        ("Foundry agent operations", "foundry-agent-operations", ()),
        ("Business overview", "azure-ai-business-overview", (
            ("ptuSubscription", "subscription"),
            ("ptuResourceGroup", "resourceGroup"),
            ("ptuAccount", "account"),
            ("ptuRegion", "region"),
            ("ptuDeployment", "deployment"),
        )),
        ("Cost details", "azure-ai-costs", ()),
    ))
    ptu["panels"].append(panel(
        11, "Provisioned deployments reporting utilization",
        metric("AzureOpenAIProvisionedManagedUtilizationV2", "Maximum"), "percent", kind="table",
        description="Deployments that reported PTU utilization in the selected period, with last, maximum and "
        "mean of the per-interval maximum utilization. Follows the deployment variable; use * to list all. "
        "Only provisioned deployments emit this metric. "
        "Neither Azure Monitor nor Azure Resource Graph exposes allocated PTUs or regional quota; read those "
        "from the deployment (portal, CLI or ARM) and Azure Quotas.",
    ))
    ptu["panels"][-1]["transformations"] = [{
        "id": "reduce",
        "options": {"mode": "seriesToRows", "reducers": ["lastNotNull", "max", "mean"]},
    }]
    ptu["panels"].append({
        "id": 12, "type": "text", "title": "Cost and quota",
        "description": "Use Azure Cost Management for actual billed and amortized reservation costs.",
        "datasource": DS, "targets": [],
        "gridPos": {"h": 4, "w": 24, "x": 0, "y": 48},
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"mode": "markdown", "content": (
            "PTU utilization describes consumed versus deployed throughput; it is **not a cost estimate**. "
            "For actual charges and reservation coverage, open "
            "[Azure Cost Management](https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/overview). "
            "Use Azure Quotas to review regional deployment availability. "
            "Optional Terraform budgets can alert on actual month-to-date costs for the selected AI accounts."
        )},
    })
    for index, color in ((0, "green"), (1, "blue"), (3, "orange"),
                         (4, "purple"), (5, "light-blue")):
        fixed_color(ptu["panels"][index], color)
    override(ptu["panels"][2], "/.*200.*/", {"color": {"mode": "fixed", "fixedColor": "green"}})
    override(ptu["panels"][2], "/.*429.*/", {"color": {"mode": "fixed", "fixedColor": "orange"}})
    ptu["panels"][0]["fieldConfig"]["defaults"]["thresholds"] = {
        "mode": "absolute", "steps": [
            {"color": "green", "value": None}, {"color": "orange", "value": 85},
            {"color": "red", "value": 100},
        ],
    }
    agent_specs = [
        ("Agent run latency", "agent-latency.kql", "ms", False),
        ("Agent runs per interval and failures", "agent-runs.kql", "short", False),
        ("Tool performance", "tool-performance.kql", "short", True),
        ("Model token usage and missing usage spans", "model-tokens.kql", "short", False),
        ("Failed operations - trace IDs", "failed-operations.kql", "short", True),
        ("Observed instrumentation", "telemetry-coverage.kql", "short", False),
        ("Evaluation results (optional custom events)", "evaluations.kql", "short", True),
    ]
    agents = dashboard("foundry-agent-operations", "Foundry - Agent operations", [workspace], [
        panel(i, title, logs(filename, table), unit, "table" if table else "timeseries",
              "Requires the documented telemetry contract. No data is not evidence of health. Latency percentiles reflect retained spans.")
        for i, (title, filename, unit, table) in enumerate(agent_specs, 1)
    ], related=(
        ("Foundry overview", "foundry-overview", (("workspaceResourceId", "workspaceResourceId"),)),
        ("PTU performance", "azure-openai-ptu", ()),
        ("Business overview", "azure-ai-business-overview", (("workspaceResourceId", "workspaceResourceId"),)),
    ))
    agents["panels"].append(panel(
        8, "Dependency performance",
        logs("agent-dependencies.kql", table=True), kind="table",
        description="Client-observed calls and latency to external dependencies. Hostnames in Target "
        "are telemetry metadata; do not emit secrets or customer data there.",
    ))
    override(agents["panels"][4], "/^OperationId$/", {
        "links": [{
            "title": "Open this operation in Azure Logs",
            "url": (
                "https://portal.azure.com/#blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/"
                "resourceId/${workspaceResourceId:percentencode}/source/LogsBlade.AnalyticsShareLinkToQuery/"
                "q/AppRequests%20%7C%20where%20OperationId%20%3D%3D%20%27${__value.raw}%27%20"
                "%7C%20union%20%28AppDependencies%20%7C%20where%20OperationId%20%3D%3D%20"
                "%27${__value.raw}%27%29%20%7C%20project%20TimeGenerated%2C%20OperationId%2C%20"
                "ParentId%2C%20Name%2C%20ResultCode%2C%20Success%2C%20DurationMs%20%7C%20"
                "order%20by%20TimeGenerated%20asc/isQueryBase64Compressed/false"
            ),
            "targetBlank": True,
        }],
    })
    for field, color in (("P50_ms", "blue"), ("P95_ms", "purple"), ("P99_ms", "green")):
        override(agents["panels"][0], f"/.*{field}.*/", {"color": {"mode": "fixed", "fixedColor": color}})
    override(agents["panels"][1], "/.*ObservedRuns.*/", {"color": {"mode": "fixed", "fixedColor": "blue"}})
    override(agents["panels"][1], "/.*FailedRuns.*/", {
        "color": {"mode": "fixed", "fixedColor": "red"},
        "custom.axisPlacement": "right",
    })
    override(agents["panels"][2], "/^P95_ms$/", {"unit": "ms"})
    for field, color in (("InputTokens", "blue"), ("OutputTokens", "purple")):
        override(agents["panels"][3], f"/.*{field}.*/", {"color": {"mode": "fixed", "fixedColor": color}})
    override(agents["panels"][3], "/.*MissingUsageSpans.*/", {
        "color": {"mode": "fixed", "fixedColor": "orange"},
        "custom.axisPlacement": "right",
    })
    for field, label, width in (
        ("TimeGenerated", "Time", 145),
        ("OperationId", "Trace ID", 220),
        ("Name", "Operation name", 145),
        ("ResultCode", "Result", 85),
        ("DurationMs", "Duration", 90),
    ):
        properties = {
            "displayName": label,
            "custom.width": width,
        }
        if field == "DurationMs":
            properties["unit"] = "ms"
        override(agents["panels"][4], f"/^{field}$/", properties)
    agents["panels"][1]["description"] = (
        "Each point is a time-bucket count, not the total for the selected range. Observed and failed runs "
        "use separate axes; counts retain ItemCount sampling weights."
    )
    agents["panels"][3]["description"] = (
        "Input/output token totals are derived from retained model spans. Missing usage spans use "
        "the right axis; absent usage is not evidence of zero token consumption."
    )
    agents["panels"][5]["description"] = (
        "Counts of observed and recognized spans, not a coverage percentage. A completely silent "
        "workspace cannot establish telemetry health."
    )
    foundry_variables = [subscription, workspace] + [
        textbox(name, config["foundry"][key])
        for name, key in (("resourceGroup", "resourceGroup"), ("account", "account"), ("region", "region"))
    ] + [textbox("deployment", "*", "OpenAI deployment (or *)")]
    foundry = dashboard("foundry-overview", "Foundry - Resource and model overview", foundry_variables, [
        panel(1, "Accessible Foundry / OpenAI / ML resources",
              resource_graph("inventory.kql", "$subscription"), kind="table",
              description="Inventory is RBAC-filtered and includes ML workspaces; not every row is a Foundry hub."),
        panel(2, "Observed agent telemetry", logs("telemetry-coverage.kql"),
              description="Counts of observed and recognized spans, not a coverage percentage. "
              "A completely silent workspace cannot establish telemetry health."),
        panel(3, "OpenAI requests by deployment and status", metric("AzureOpenAIRequests", "Total", request_dimensions)),
        panel(4, "OpenAI inference tokens per interval", metric("TokenTransaction", "Total")),
    ], related=(
        ("Agent operations", "foundry-agent-operations", (("workspaceResourceId", "workspaceResourceId"),)),
        ("PTU performance", "azure-openai-ptu", (("subscription", "subscription"),)),
        ("Business overview", "azure-ai-business-overview", (
            ("workspaceResourceId", "workspaceResourceId"),
            ("ptuSubscription", "subscription"),
        )),
    ))
    for item in foundry["panels"][2:]:
        item["description"] = "OpenAI-specific metric on the selected account; not a universal metric for every Foundry model."
    foundry["panels"].append(token_cost_panel(5))
    cost_panels = [{
        "id": 1, "type": "text", "title": "Understand these costs",
        "datasource": DS, "targets": [],
        "gridPos": {"h": 5, "w": 24, "x": 0, "y": 0},
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"mode": "markdown", "content": (
            "**Pretax account costs, not invoice or deployment totals.** "
            "Actual and amortized are alternatives: **do not add them together**. "
            "Billing can lag; missing data is not zero. Currencies stay separate. "
            "Partial UTC days include the full reported day."
        )},
    }]
    cost_specs = [
        (2, "Collection status and selected-period coverage", "cost-status.kql", True,
         "The latest fully ingested snapshot from the last 14 days. Stale means the collection is "
         "over 48 hours old. A range outside collected history can be incomplete.",
         {"h": 5, "w": 24, "x": 0, "y": 5}),
        (3, "Actual cost by currency", "cost-actual-total.kql", True,
         "Reported resource-attributed actual pretax cost for the selected UTC usage days.",
         {"h": 5, "w": 12, "x": 0, "y": 10}),
        (4, "Amortized cost by currency", "cost-amortized-total.kql", True,
         "Reported resource-attributed amortized pretax cost; do not add to actual cost.",
         {"h": 5, "w": 12, "x": 12, "y": 10}),
        (5, "Daily actual cost", "cost-actual-trend.kql", False,
         "Daily resource-attributed actual cost. Each currency is a separate series.",
         {"h": 9, "w": 12, "x": 0, "y": 15}),
        (6, "Daily amortized cost", "cost-amortized-trend.kql", False,
         "Daily resource-attributed amortized cost. Each currency is a separate series.",
         {"h": 9, "w": 12, "x": 12, "y": 15}),
        (7, "Cost by AI account", "cost-accounts.kql", True,
         "Account resource IDs remain visible so accounts with identical names are distinguishable. "
         "Actual and amortized rows are alternatives, separated by currency.",
         {"h": 9, "w": 24, "x": 0, "y": 24}),
    ]
    for number, title, filename, table, description, position in cost_specs:
        item = panel(number, title, cost_logs(filename, table), unit="none",
                     kind="table" if table else "timeseries",
                     description=description)
        item["gridPos"] = position
        item["fieldConfig"]["defaults"]["noValue"] = "No data reported"
        override(item, "/^Amount$/", {"decimals": 2})
        if number == 7:
            for field, width in (("Account", 160), ("CostType", 150), ("Currency", 110),
                                 ("Amount", 130), ("ResourceId", 600)):
                override(item, f"/^{field}$/", {"custom.width": width})
        cost_panels.append(item)
    costs = dashboard(
        "azure-ai-costs", "Azure AI - Cost visibility",
        [textbox("workspaceResourceId", config["workspaceResourceId"], "Cost data workspace ARM ID")],
        cost_panels,
        related=(
            ("Business overview", "azure-ai-business-overview", (
                ("monitoringWorkspaceResourceId", "workspaceResourceId"),
            )),
            ("PTU performance", "azure-openai-ptu", ()),
        ),
    )
    costs["timezone"] = "utc"
    costs["refresh"] = "1h"
    costs["time"] = {"from": "now-30d", "to": "now"}

    business_variables = [
        textbox("workspaceResourceId", config["workspaceResourceId"], "Agent telemetry workspace ARM ID"),
        textbox("monitoringWorkspaceResourceId", config["workspaceResourceId"], "Cost data workspace ARM ID"),
        textbox("ptuSubscription", config["subscription"]),
        textbox("ptuResourceGroup", config["ptu"]["resourceGroup"]),
        textbox("ptuAccount", config["ptu"]["account"]),
        textbox("ptuRegion", config["ptu"]["region"]),
        textbox("ptuDeployment", config["ptu"]["deployment"]),
    ]
    business_panels = [
        panel(
            1, "Cost collection status",
            cost_logs("cost-status.kql", table=True, workspace="monitoringWorkspaceResourceId"),
            unit="none", kind="table",
            description="Shows whether a complete snapshot is current and covers the selected period. "
            "Missing or stale collection is not zero cost.",
        ),
        panel(
            2, "Actual cost by currency",
            cost_logs("cost-actual-total.kql", table=True, workspace="monitoringWorkspaceResourceId"),
            unit="none", kind="table",
            description="Pretax account-attributed actual cost for the selected UTC period. "
            "Currencies remain separate; use the cost dashboard for amortized cost.",
        ),
        panel(
            3, "Observed agent runs per interval",
            logs("agent-run-volume.kql"),
            description="Each point is a time-bucket count, not the total for the selected range. "
            "Counts are weighted for sampling when present. No data is not evidence of zero activity or healthy service.",
        ),
        panel(
            4, "PTU utilization - average",
            metric("AzureOpenAIProvisionedManagedUtilizationV2", variable_prefix="ptu"),
            unit="percent",
            description="Azure platform metric for the configured provisioned deployment. "
            "Availability depends on the model and SKU.",
        ),
        panel(
            5, "Daily actual cost by currency",
            cost_logs("cost-actual-trend.kql", workspace="monitoringWorkspaceResourceId"),
            unit="none",
            description="Daily account-attributed actual cost. Each currency is a separate series; "
            "billing may be revised or delayed.",
        ),
        panel(
            6, "Agent run latency",
            logs("agent-latency.kql"),
            unit="ms",
            description="Percentiles reflect retained, instrumented spans and are not an end-to-end "
            "service-level objective.",
        ),
        panel(
            7, "PTU requests by status code",
            metric(
                "AzureOpenAIRequests", "Total",
                [
                    {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$ptuDeployment"]},
                    {"dimension": "StatusCode", "operator": "eq", "filters": ["*"]},
                ],
                variable_prefix="ptu",
            ),
            description="Azure platform request counts by status for the configured deployment. "
            "Counts are per time bucket, not per second.",
        ),
        panel(
            8, "Throttled requests (429)",
            metric(
                "AzureOpenAIRequests", "Total",
                [
                    {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$ptuDeployment"]},
                    {"dimension": "StatusCode", "operator": "eq", "filters": ["429"]},
                ],
                variable_prefix="ptu",
            ),
            description="Azure platform 429 request counts per time bucket, not a rate. "
            "No data can mean no matching traffic or unavailable metrics.",
        ),
        panel(
            9, "Agent run failure rate",
            logs("agent-failure-rate.kql"),
            unit="percent",
            description="Failed runs divided by runs with a known success/failure outcome, weighted by ItemCount "
            "where sampling is present. No data is not a zero failure rate; retained spans may be sampled.",
        ),
        panel(
            10, "PTU input and output tokens",
            metric("ProcessedPromptTokens", "Total", variable_prefix="ptu"),
            description="Azure platform token counts per time bucket for the configured deployment.",
        ),
    ]
    output_tokens = metric("GeneratedTokens", "Total", variable_prefix="ptu")
    output_tokens["refId"] = "B"
    business_panels[9]["targets"].append(output_tokens)
    business_positions = [
        {"h": 5, "w": 6, "x": 0, "y": 0},
        {"h": 5, "w": 6, "x": 6, "y": 0},
        {"h": 5, "w": 6, "x": 12, "y": 0},
        {"h": 5, "w": 6, "x": 18, "y": 0},
        {"h": 9, "w": 12, "x": 0, "y": 5},
        {"h": 9, "w": 12, "x": 12, "y": 5},
        {"h": 8, "w": 8, "x": 0, "y": 14},
        {"h": 8, "w": 8, "x": 8, "y": 14},
        {"h": 8, "w": 8, "x": 16, "y": 14},
        {"h": 8, "w": 24, "x": 0, "y": 22},
    ]
    for item, position in zip(business_panels, business_positions, strict=True):
        item["gridPos"] = position
    business_panels[0]["transformations"] = [{
        "id": "organize",
        "options": {
            "excludeByName": {
                "LastCollectedUTC": True,
                "HistoryFromUTC": True,
                "HistoryThroughUTC": True,
                "ReportedRows": True,
            },
            "indexByName": {"Status": 0, "Coverage": 1},
        },
    }]
    for index, field, color in (
        (2, "ObservedRuns", "blue"),
        (7, "429", "orange"),
        (8, "FailureRatePercent", "red"),
    ):
        override(business_panels[index], f"/.*{field}.*/", {
            "color": {"mode": "fixed", "fixedColor": color},
        })
    business_panels[8]["fieldConfig"]["defaults"]["min"] = 0
    business = dashboard(
        "azure-ai-business-overview", "Azure AI - Business overview",
        business_variables, business_panels,
        related=(
            ("Agent operations", "foundry-agent-operations", (("workspaceResourceId", "workspaceResourceId"),)),
            ("PTU performance", "azure-openai-ptu", (
                ("subscription", "ptuSubscription"),
                ("resourceGroup", "ptuResourceGroup"),
                ("account", "ptuAccount"),
                ("region", "ptuRegion"),
                ("deployment", "ptuDeployment"),
            )),
            ("Cost details", "azure-ai-costs", (("workspaceResourceId", "monitoringWorkspaceResourceId"),)),
        ),
    )
    business["description"] = (
        "A concise view of cost, observed agent activity, and Azure OpenAI PTU signals. "
        "It does not calculate a blended health score. Cost is optional; missing or stale data "
        "must not be interpreted as zero. No data can indicate no traffic, missing permissions, "
        "unsupported metrics, or absent instrumentation. Agent telemetry requires application instrumentation."
    )
    business["timezone"] = "utc"
    business["refresh"] = "1h"
    business["time"] = {"from": "now-7d", "to": "now"}
    return {
        "foundry-overview.json": foundry, "foundry-agents.json": agents,
        "openai-ptu.json": ptu, "azure-ai-costs.json": costs,
        "business-overview.json": business,
    }


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
