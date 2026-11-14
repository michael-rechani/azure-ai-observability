"""Generate importable Grafana dashboards using only the Python standard library."""

import argparse
import json
from pathlib import Path
import re
import uuid

ROOT = Path(__file__).resolve().parents[1]
DS = {"type": "grafana-azure-monitor-datasource", "uid": "${DS_AZURE_MONITOR}"}
DS_INFINITY = {"type": "yesoreyeram-infinity-datasource", "uid": "${DS_COST_INFINITY}"}
NAMESPACE = "Microsoft.CognitiveServices/accounts"
COST_QUERY_URL = "https://management.azure.com${costScope}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
# Rows become one object per row keyed by column name, so the panels never depend on column order.
# A continuation link fails the query instead of silently showing a partial total.
COST_ROWS_JQ = (
    'if .properties.nextLink then error("incomplete_cost_response") else '
    '.properties as $p | ($p.columns | map(.name)) as $c | '
    '[$p.rows[] | . as $r | reduce range(0; ($c | length)) as $i ({}; .[$c[$i]] = $r[$i])] end'
)
COST_DATE_JQ = (
    ' | map(if has("UsageDate") then .UsageDate = ((.UsageDate | tostring) as $d | '
    '$d[0:4] + "-" + $d[4:6] + "-" + $d[6:8]) else . end)'
)
COST_ACCOUNT_JQ = (
    ' | map(.Account = (.ResourceId | split("/") | .[-1]) | .ResourceGroup = (.ResourceId | split("/") | .[4]))'
)


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
            "counted). Costs are rounded to cents. Use Azure Cost Management, or the optional cost "
            "dashboard, for billed cost."
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


def infinity_cost_query(columns, *, month_to_date=False, daily=False, grouping=(), quantity=False, extra_jq=""):
    """Cost Management Query API call made by the Infinity data source, filtered to AI accounts."""
    aggregation = {"totalCost": {"name": "PreTaxCost", "function": "Sum"}}
    if quantity:
        aggregation["totalQuantity"] = {"name": "UsageQuantity", "function": "Sum"}
    dataset = {
        "granularity": "Daily" if daily else "None",
        "aggregation": aggregation,
        "filter": {"dimensions": {
            "name": "ResourceType", "operator": "In", "values": [NAMESPACE.lower()],
        }},
    }
    if grouping:
        dataset["grouping"] = [{"type": "Dimension", "name": name} for name in grouping]
    body = {"type": "ActualCost"}
    if month_to_date:
        body["timeframe"] = "MonthToDate"
    else:
        body["timeframe"] = "Custom"
        body["timePeriod"] = {"from": "${__from:date:iso}", "to": "${__to:date:iso}"}
    body["dataset"] = dataset
    return {
        "refId": "A", "datasource": DS_INFINITY, "type": "json", "source": "url",
        "format": "table", "parser": "jq-backend",
        "url": COST_QUERY_URL, "root_selector": COST_ROWS_JQ + extra_jq,
        "columns": [{"selector": selector, "text": text, "type": kind} for selector, text, kind in columns],
        "url_options": {
            "method": "POST", "body_type": "raw", "body_content_type": "application/json",
            "data": json.dumps(body, separators=(",", ":")),
            "headers": [{"key": "ClientType", "value": "AzureAiObservability"}],
        },
    }


def thresholds(*steps):
    """Green below the first step; each (value, colour) step starts at its value."""
    return {"mode": "absolute", "steps": [{"color": "green", "value": None}] + [
        {"color": color, "value": value} for value, color in steps
    ]}


def set_thresholds(item, *steps, soft_max=None):
    defaults = item["fieldConfig"]["defaults"]
    defaults["thresholds"] = thresholds(*steps)
    if item["type"] == "timeseries":
        # Time series draw thresholds only when a style is set.
        defaults["custom"]["thresholdsStyle"] = {"mode": "dashed"}
        if soft_max is not None:
            defaults["custom"]["axisSoftMax"] = soft_max


def stat_panel(number, title, target, position, description, unit="short",
               calcs=("lastNotNull",), text_mode="auto", graph_mode="none"):
    item = panel(number, title, target, unit, "stat", description)
    item["gridPos"] = position
    item["fieldConfig"]["defaults"].update({
        "color": {"mode": "thresholds"}, "thresholds": thresholds(),
        # A missing value would take the green base threshold colour, and a green "No data" reads as healthy.
        "mappings": [{"type": "special", "options": {
            "match": "null+nan", "result": {"text": "No data", "color": "text", "index": 0},
        }}],
    })
    item["options"] = {
        "reduceOptions": {"values": False, "calcs": list(calcs), "fields": ""},
        "colorMode": "value", "graphMode": graph_mode, "textMode": text_mode,
        "justifyMode": "center", "orientation": "auto",
    }
    return item


def agent_summary_panel(number, position):
    item = stat_panel(
        number, "Agent summary - selected period", logs("agent-summary.kql", table=True), position,
        "Whole-period figures over retained invoke_agent spans for the selected agent. Runs are weighted by "
        "ItemCount, the failure rate uses runs with a known outcome, and p95 is taken over retained spans "
        "without sampling weights. No data is not evidence of health: the agent may be idle, sampled out or "
        "uninstrumented. Threshold colours mirror the default alerts.",
        text_mode="value_and_name",
    )
    override(item, "/^ObservedRuns$/", {
        "displayName": "Observed runs", "color": {"mode": "fixed", "fixedColor": "blue"},
    })
    override(item, "/^FailureRatePercent$/", {
        "displayName": "Failure rate", "unit": "percent", "decimals": 1,
        "thresholds": thresholds((5, "orange"), (10, "red")),
    })
    override(item, "/^P95_ms$/", {
        "displayName": "P95 latency", "unit": "ms",
        "thresholds": thresholds((2500, "orange"), (5000, "red")),
    })
    return item


def ptu_summary_panels(first_number, positions, variable_prefix=""):
    deployment = "$ptuDeployment" if variable_prefix else "$deployment"
    peak = stat_panel(
        first_number, "Peak PTU utilization",
        metric("AzureOpenAIProvisionedManagedUtilizationV2", "Maximum", variable_prefix=variable_prefix),
        positions[0],
        "Highest per-interval maximum utilization in the selected period. Threshold colours mirror the default "
        "alert (orange from 85%, red at 100%) and do not follow alert overrides. Azure platform metric; "
        "availability varies by model and SKU. A * deployment shows one tile per deployment.",
        unit="percent", calcs=("max",), graph_mode="area",
    )
    set_thresholds(peak, (85, "orange"), (100, "red"))
    throttled = stat_panel(
        first_number + 1, "Throttled (429) - period total",
        metric("AzureOpenAIRequests", "Total", [
            {"dimension": "ModelDeploymentName", "operator": "eq", "filters": [deployment]},
            {"dimension": "StatusCode", "operator": "eq", "filters": ["429"]},
        ], variable_prefix=variable_prefix),
        positions[1],
        "Sum of 429 responses in the selected period, orange once any were returned. Azure platform metric. "
        "No data can mean no throttling, no matching traffic or an unavailable metric.",
        calcs=("sum",),
    )
    set_thresholds(throttled, (1, "orange"))
    return [peak, throttled]


def add_summary_row(panels, tiles):
    """Place summary tiles above the existing panels, which move down by the tiles' height."""
    height = max(tile["gridPos"]["h"] for tile in tiles)
    for item in panels:
        item["gridPos"]["y"] += height
    panels.extend(tiles)


def dashboard(uid, title, variables, panels, related=(), inputs=None):
    result = {
        "uid": uid, "title": title, "schemaVersion": 39, "version": 1,
        "editable": True, "tags": ["azure", "ai-observability"],
        "timezone": "browser", "refresh": "1m",
        "time": {"from": "now-6h", "to": "now"}, "panels": panels,
        "templating": {"list": variables},
        "__inputs": inputs or [{
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
    # Dashboard thresholds mirror the default alert thresholds (docs/alerts.md); they do not follow IaC overrides.
    for index in (0, 1):
        set_thresholds(ptu["panels"][index], (85, "orange"), (100, "red"), soft_max=100)
    add_summary_row(ptu["panels"], ptu_summary_panels(13, (
        {"h": 4, "w": 12, "x": 0, "y": 0},
        {"h": 4, "w": 12, "x": 12, "y": 0},
    )))
    agent_specs = [
        ("Agent run latency", "agent-latency.kql", "ms", False),
        ("Agent runs per interval and failures", "agent-runs.kql", "short", False),
        ("Tool performance", "tool-performance.kql", "short", True),
        ("Model token usage and missing usage spans", "model-tokens.kql", "short", False),
        ("Failed operations - trace IDs", "failed-operations.kql", "short", True),
        ("Observed instrumentation", "telemetry-coverage.kql", "short", False),
        ("Evaluation results (optional custom events)", "evaluations.kql", "short", True),
    ]
    agents = dashboard("foundry-agent-operations", "Foundry - Agent operations", [
        workspace, textbox("agent", "*", "Agent (or * for all)"),
    ], [
        panel(i, title, logs(filename, table), unit, "table" if table else "timeseries",
              "Requires the documented telemetry contract. No data is not evidence of health. Latency percentiles reflect retained spans.")
        for i, (title, filename, unit, table) in enumerate(agent_specs, 1)
    ], related=(
        ("Foundry overview", "foundry-overview", (("workspaceResourceId", "workspaceResourceId"),)),
        ("PTU performance", "azure-openai-ptu", ()),
        ("Business overview", "azure-ai-business-overview", (
            ("workspaceResourceId", "workspaceResourceId"),
            ("agent", "agent"),
        )),
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
    for item in agents["panels"][2:]:
        item["description"] += " Not filtered by the agent variable."
    set_thresholds(agents["panels"][0], (2500, "orange"), (5000, "red"))
    add_summary_row(agents["panels"], [agent_summary_panel(9, {"h": 4, "w": 24, "x": 0, "y": 0})])
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
    business_variables = [
        textbox("workspaceResourceId", config["workspaceResourceId"], "Agent telemetry workspace ARM ID"),
        textbox("agent", "*", "Agent (agent panels only; * for all)"),
        textbox("ptuSubscription", config["subscription"]),
        textbox("ptuResourceGroup", config["ptu"]["resourceGroup"]),
        textbox("ptuAccount", config["ptu"]["account"]),
        textbox("ptuRegion", config["ptu"]["region"]),
        textbox("ptuDeployment", config["ptu"]["deployment"]),
    ]
    business_panels = [
        panel(
            1, "Observed agent runs per interval",
            logs("agent-run-volume.kql"),
            description="Each point is a time-bucket count, not the total for the selected range. "
            "Counts are weighted for sampling when present. No data is not evidence of zero activity or healthy service.",
        ),
        panel(
            2, "PTU utilization - average",
            metric("AzureOpenAIProvisionedManagedUtilizationV2", variable_prefix="ptu"),
            unit="percent",
            description="Azure platform metric for the configured provisioned deployment. "
            "Availability depends on the model and SKU.",
        ),
        panel(
            3, "Agent run latency",
            logs("agent-latency.kql"),
            unit="ms",
            description="Percentiles reflect retained, instrumented spans and are not an end-to-end "
            "service-level objective.",
        ),
        panel(
            4, "PTU requests by status code",
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
            5, "Throttled requests (429)",
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
            6, "Agent run failure rate",
            logs("agent-failure-rate.kql"),
            unit="percent",
            description="Failed runs divided by runs with a known success/failure outcome, weighted by ItemCount "
            "where sampling is present. No data is not a zero failure rate; retained spans may be sampled.",
        ),
        panel(
            7, "PTU input and output tokens",
            metric("ProcessedPromptTokens", "Total", variable_prefix="ptu"),
            description="Azure platform token counts per time bucket for the configured deployment.",
        ),
    ]
    output_tokens = metric("GeneratedTokens", "Total", variable_prefix="ptu")
    output_tokens["refId"] = "B"
    business_panels[6]["targets"].append(output_tokens)
    business_positions = [
        {"h": 8, "w": 12, "x": 0, "y": 0},
        {"h": 8, "w": 12, "x": 12, "y": 0},
        {"h": 8, "w": 12, "x": 0, "y": 8},
        {"h": 8, "w": 8, "x": 0, "y": 16},
        {"h": 8, "w": 8, "x": 8, "y": 16},
        {"h": 8, "w": 12, "x": 12, "y": 8},
        {"h": 8, "w": 8, "x": 16, "y": 16},
    ]
    for item, position in zip(business_panels, business_positions, strict=True):
        item["gridPos"] = position
    for index, field, color in (
        (0, "ObservedRuns", "blue"),
        (4, "429", "orange"),
        (5, "FailureRatePercent", "red"),
    ):
        override(business_panels[index], f"/.*{field}.*/", {
            "color": {"mode": "fixed", "fixedColor": color},
        })
    business_panels[5]["fieldConfig"]["defaults"]["min"] = 0
    set_thresholds(business_panels[1], (85, "orange"), (100, "red"), soft_max=100)
    set_thresholds(business_panels[2], (2500, "orange"), (5000, "red"))
    set_thresholds(business_panels[5], (5, "orange"), (10, "red"))
    add_summary_row(business_panels, [
        agent_summary_panel(8, {"h": 4, "w": 12, "x": 0, "y": 0}),
        *ptu_summary_panels(9, (
            {"h": 4, "w": 6, "x": 12, "y": 0},
            {"h": 4, "w": 6, "x": 18, "y": 0},
        ), variable_prefix="ptu"),
    ])
    business = dashboard(
        "azure-ai-business-overview", "Azure AI - Business overview",
        business_variables, business_panels,
        related=(
            ("Agent operations", "foundry-agent-operations", (
                ("workspaceResourceId", "workspaceResourceId"),
                ("agent", "agent"),
            )),
            ("PTU performance", "azure-openai-ptu", (
                ("subscription", "ptuSubscription"),
                ("resourceGroup", "ptuResourceGroup"),
                ("account", "ptuAccount"),
                ("region", "ptuRegion"),
                ("deployment", "ptuDeployment"),
            )),
        ),
    )
    business["description"] = (
        "A concise view of observed agent activity and Azure OpenAI PTU signals. "
        "The agent filter applies only to the agent panels; PTU panels cover the configured deployment. "
        "It does not calculate a blended health score and shows no cost; use Azure Cost Management or the "
        "optional cost dashboard for billed cost. No data can indicate no traffic, missing permissions, "
        "unsupported metrics, or absent instrumentation. Agent telemetry requires application instrumentation."
    )
    business["timezone"] = "utc"
    business["refresh"] = "1h"
    business["time"] = {"from": "now-7d", "to": "now"}

    infinity_panels = [
        panel(
            1, "Month-to-date actual cost by currency",
            infinity_cost_query(
                [("PreTaxCost", "Cost", "number"), ("Currency", "Currency", "string")],
                month_to_date=True,
            ),
            unit="none", kind="table",
            description="Actual cost of Foundry and Azure OpenAI accounts since the start of the UTC month, read "
            "from the Cost Management Query API. Billing can be revised or delayed.",
        ),
        panel(
            2, "Daily actual cost",
            infinity_cost_query(
                [("UsageDate", "Date", "timestamp"), ("PreTaxCost", "Cost", "number"),
                 ("Currency", "Currency", "string")],
                daily=True, extra_jq=COST_DATE_JQ,
            ),
            unit="none",
            description="Daily actual cost per billing currency for the selected period. The Query API allows at "
            "most 31 days of daily data, so a longer dashboard range fails instead of being truncated.",
        ),
        panel(
            3, "Cost by account",
            infinity_cost_query(
                [("Account", "Account", "string"), ("ResourceGroup", "Resource group", "string"),
                 ("PreTaxCost", "Cost", "number"), ("Currency", "Currency", "string")],
                grouping=("ResourceId",), extra_jq=COST_ACCOUNT_JQ,
            ),
            unit="none", kind="table",
            description="Actual cost by Foundry or Azure OpenAI account for the selected period.",
        ),
        panel(
            4, "Cost by meter",
            infinity_cost_query(
                [("Meter", "Meter", "string"), ("UsageQuantity", "Quantity", "number"),
                 ("PreTaxCost", "Cost", "number"), ("Currency", "Currency", "string")],
                grouping=("Meter",), quantity=True,
            ),
            unit="none", kind="table",
            description="Actual cost and quantity by meter, which separates input, output and provisioned charges.",
        ),
    ]
    for item in infinity_panels:
        item["datasource"] = DS_INFINITY
    infinity_panels[1]["transformations"] = [{
        "id": "partitionByValues",
        "options": {"fields": ["Currency"], "keepFields": False, "naming": {"asLabels": False}},
    }]
    for item, position in zip(infinity_panels, (
        {"h": 6, "w": 24, "x": 0, "y": 0},
        {"h": 9, "w": 24, "x": 0, "y": 6},
        {"h": 9, "w": 12, "x": 0, "y": 15},
        {"h": 9, "w": 12, "x": 12, "y": 15},
    ), strict=True):
        item["gridPos"] = position
    infinity = dashboard(
        "azure-ai-costs-infinity", "Azure AI - Cost visibility (direct Cost Management query)",
        [textbox("costScope", f"/subscriptions/{config['subscription']}", "Cost query scope")],
        infinity_panels,
        inputs=[{
            "name": "DS_COST_INFINITY", "label": "Cost Management (Infinity)",
            "type": "datasource", "pluginId": "yesoreyeram-infinity-datasource",
            "pluginName": "Infinity",
        }],
    )
    infinity["description"] = (
        "Actual cost of Azure AI resources queried directly from the Cost Management Query API through the "
        "Infinity data source, with no export, storage or cluster. The data source uses a "
        "service principal client secret that you must rotate, and every user who can edit its queries "
        "inherits that principal's cost access. No data can mean billing has not caught up, not zero cost."
    )
    infinity["timezone"] = "utc"
    infinity["refresh"] = "1h"
    infinity["time"] = {"from": "now-30d", "to": "now"}
    return {
        "foundry-overview.json": foundry, "foundry-agents.json": agents,
        "openai-ptu.json": ptu,
        "business-overview.json": business,
        "azure-ai-costs-infinity.json": infinity,
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
