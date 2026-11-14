"""Build Grafana TestData previews that copy the real dashboard layouts, with sample series instead of Azure queries."""

import copy
import json
from pathlib import Path

import build_dashboards

ROOT = Path(__file__).resolve().parents[1]
DEMO_DS = {"type": "grafana-testdata-datasource", "uid": "ai-demo-data"}
DEMO_DASHBOARD_UIDS = {
    "demo-foundry-agent-operations",
    "demo-azure-openai-ptu",
    "demo-azure-ai-business-overview",
}
# The checked-in defaults are deployment placeholders; the preview shows plausible names instead.
DEMO_VARIABLES = {
    "deployment": "gpt-4o-prod",
    "ptuDeployment": "gpt-4o-prod",
    "resourceGroup": "ai-prod-rg",
    "ptuResourceGroup": "ai-prod-rg",
    "account": "contoso-openai",
    "ptuAccount": "contoso-openai",
    "workspaceResourceId": (
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring-rg"
        "/providers/Microsoft.OperationalInsights/workspaces/ai-observability-logs"
    ),
}


def series(name, values, ref_id):
    return {
        "datasource": DEMO_DS,
        "refId": ref_id,
        "scenarioId": "csv_metric_values",
        "alias": name,
        "stringInput": ",".join(str(value) for value in values),
    }


def table(content):
    return {"datasource": DEMO_DS, "refId": "A", "scenarioId": "csv_content", "csvContent": content}


PTU_DATA = {
    1: [("Average", [48, 50, 49, 52, 51, 53, 56, 59, 57, 55, 59, 61, 58, 56, 55, 58, 57, 55, 54, 56])],
    2: [("Maximum", [75, 78, 76, 80, 82, 79, 83, 87, 91, 94, 88, 85, 89, 84, 87, 86, 88, 85, 83, 84])],
    3: [
        ("200", [1050, 1100, 1080, 1150, 1200, 1180, 1250, 1280, 1310, 1250, 1290, 1340, 1300, 1270, 1320, 1290, 1250, 1280, 1300, 1260]),
        ("429", [10, 12, 9, 15, 18, 12, 20, 25, 30, 21, 28, 36, 27, 24, 33, 22, 18, 26, 23, 19]),
    ],
    4: [("429", [10, 12, 9, 15, 18, 12, 20, 25, 30, 21, 28, 36, 27, 24, 33, 22, 18, 26, 23, 19])],
    5: [("Input tokens", [82000, 86000, 84000, 91000, 96000, 93000, 102000, 110000, 115000, 108000, 116000, 120000, 112000, 109000, 114000, 107000, 100000, 103000, 98000, 95000])],
    6: [("Output tokens", [24000, 26000, 25000, 28000, 30000, 31000, 35000, 39000, 42000, 37000, 40000, 43000, 39000, 38000, 41000, 37000, 34000, 36000, 35000, 33000])],
    7: [("Time to response", [360, 370, 390, 385, 400, 420, 410, 450, 470, 430, 440, 460, 420, 410, 425, 405, 400, 390, 385, 380])],
    8: [("Time to last byte", [1800, 1900, 1850, 1950, 2050, 2000, 2100, 2200, 2300, 2150, 2250, 2350, 2200, 2100, 2150, 2050, 2000, 2050, 1950, 1900])],
    9: [("Time between tokens", [21, 22, 21, 23, 24, 23, 25, 26, 27, 25, 26, 28, 25, 24, 25, 24, 23, 24, 23, 22])],
    10: [("Cache match rate", [41, 43, 42, 44, 45, 46, 44, 47, 49, 48, 46, 49, 50, 48, 47, 49, 48, 47, 46, 47])],
    11: (
        "Field,Last *,Max,Mean\n"
        "gpt-4o-prod,84,94,85.9\n"
        "gpt-4o-mini-prod,52,71,58.4\n"
    ),
}
# The summary tiles reduce the same sample series the charts draw.
PTU_DATA[13] = PTU_DATA[2]
PTU_DATA[14] = PTU_DATA[4]

AGENT_RUN_COUNTS = [
    1100, 1150, 1130, 1200, 1250, 1230, 1280, 1320, 1400, 1350,
    1380, 1420, 1360, 1340, 1390, 1350, 1300, 1320, 1340, 1310,
]

AGENT_DATA = {
    1: [
        ("P50_ms", [430, 420, 445, 440, 450, 455, 460, 480, 520, 460, 450, 475, 490, 470, 460, 455, 480, 465, 450, 455]),
        ("P95_ms", [1050, 1100, 1080, 1120, 1150, 1180, 1200, 1270, 1450, 1250, 1200, 1220, 1300, 1250, 1200, 1180, 1280, 1220, 1190, 1210]),
        ("P99_ms", [1800, 1850, 1820, 1900, 1950, 1980, 2050, 2150, 2500, 2150, 2050, 2100, 2200, 2150, 2050, 2000, 2200, 2100, 2050, 2100]),
    ],
    2: [
        ("ObservedRuns", AGENT_RUN_COUNTS),
        ("FailedRuns", [8, 10, 9, 11, 12, 10, 13, 15, 19, 14, 16, 18, 15, 14, 17, 15, 12, 13, 14, 12]),
    ],
    3: "Tool,ObservedCalls,FailedCalls,P95_ms\nfile_search,240,3,1180\nweb_search,180,4,1620\ncode_interpreter,92,2,2420\n",
    4: [
        ("InputTokens", [65000, 68000, 66000, 71000, 73000, 72000, 76000, 81000, 85000, 80000, 83000, 87000, 81000, 79000, 84000, 80000, 77000, 79000, 78000, 76000]),
        ("OutputTokens", [24000, 25000, 24500, 26000, 27000, 26500, 28000, 30000, 32000, 30000, 31000, 33000, 30000, 29000, 31000, 30000, 28000, 29000, 28500, 27500]),
        ("MissingUsageSpans", [1, 0, 1, 1, 2, 1, 1, 2, 3, 2, 1, 2, 1, 1, 2, 1, 1, 0, 1, 1]),
    ],
    5: "OperationId,Name,ResultCode,DurationMs\n0af7651916cd43dd8448eb211c80319c,model-request,429,1200\n4bf92f3577b34da6a3ce929d0e0e4736,search-tool,503,2100\n",
    6: [
        ("ObservedSpans", [1600, 1650, 1630, 1700, 1750, 1730, 1780, 1820, 1900, 1850, 1880, 1920, 1860, 1840, 1890, 1850, 1800, 1820, 1840, 1810]),
        ("GenAISpans", [1200, 1250, 1230, 1300, 1350, 1330, 1380, 1420, 1500, 1450, 1480, 1520, 1460, 1440, 1490, 1450, 1400, 1420, 1440, 1410]),
        ("AgentRuns", AGENT_RUN_COUNTS),
        ("UnnamedAgentRuns", [4, 5, 4, 5, 6, 5, 5, 6, 7, 6, 5, 6, 5, 5, 6, 5, 4, 5, 5, 4]),
    ],
    7: "Evaluator,EvaluatedSamples,PassRatePercent,AverageScore,PassedSamples,FailedSamples,InvalidSamples\ngroundedness,80,90,0.84,72,8,0\n",
    8: "DependencyType,Dependency,ObservedCalls,FailedCalls,P95_ms\nHTTP,search.contoso.com,120,2,340\nHTTP,storage.contoso.com,86,1,210\n",
}
# Whole-period figures consistent with the charts: total runs, failed share of runs, and a p95 within the per-interval p95 range.
AGENT_DATA[9] = (
    "ObservedRuns,FailureRatePercent,P95_ms\n"
    f"{sum(AGENT_RUN_COUNTS)},{100 * sum(AGENT_DATA[2][1][1]) / sum(AGENT_RUN_COUNTS):.2f},1260\n"
)

BUSINESS_DATA = {
    1: AGENT_DATA[2][:1],
    2: PTU_DATA[1],
    3: AGENT_DATA[1],
    4: PTU_DATA[3],
    5: PTU_DATA[4],
    6: [("FailureRatePercent", [
        round(100 * failed / observed, 2)
        for failed, observed in zip(AGENT_DATA[2][1][1], AGENT_RUN_COUNTS, strict=True)
    ])],
    7: [
        ("Input tokens", PTU_DATA[5][0][1]),
        ("Output tokens", PTU_DATA[6][0][1]),
    ],
    8: AGENT_DATA[9],
    9: PTU_DATA[13],
    10: PTU_DATA[14],
}


def demo_dashboard(source, samples):
    result = copy.deepcopy(source)
    # The uid prefix keeps the preview from ever replacing a live dashboard that shares a Grafana.
    result["uid"] = f"demo-{source['uid']}"
    result.pop("__inputs", None)
    result["refresh"] = False
    for variable in result["templating"]["list"]:
        if variable["name"] in DEMO_VARIABLES:
            value = DEMO_VARIABLES[variable["name"]]
            variable.update({"query": value, "current": {"text": value, "value": value}})
    result["links"] = [
        {
            **link,
            "url": link["url"].replace(
                f"/d/{link['url'].split('/')[2]}/",
                f"/d/demo-{link['url'].split('/')[2]}/",
                1,
            ),
        }
        for link in result.get("links", [])
        if not link["url"].startswith("/d/")
        or f"demo-{link['url'].split('/')[2]}" in DEMO_DASHBOARD_UIDS
    ]
    for item in result["panels"]:
        item["datasource"] = DEMO_DS
        if item["type"] == "text":
            continue
        sample = samples[item["id"]]
        if isinstance(sample, str):
            # The demo CSV is already in reduced form.
            item["transformations"] = [t for t in item.get("transformations", []) if t["id"] != "reduce"]
            if not item["transformations"]:
                item.pop("transformations")
        item["targets"] = (
            [table(sample)] if isinstance(sample, str)
            else [series(name, values, chr(65 + index)) for index, (name, values) in enumerate(sample)]
        )
    return result


def build():
    config = json.loads((ROOT / "config.example.json").read_text(encoding="utf-8"))
    real = build_dashboards.build(config)
    return {
        "foundry-agents-demo.json": demo_dashboard(real["foundry-agents.json"], AGENT_DATA),
        "openai-ptu-demo.json": demo_dashboard(real["openai-ptu.json"], PTU_DATA),
        "business-overview-demo.json": demo_dashboard(real["business-overview.json"], BUSINESS_DATA),
    }


def main():
    output = ROOT / "demo" / "dashboards"
    output.mkdir(parents=True, exist_ok=True)
    for name, content in build().items():
        (output / name).write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
    print(f"Generated preview dashboards in {output}")


if __name__ == "__main__":
    main()
