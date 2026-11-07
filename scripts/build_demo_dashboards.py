"""Build separate, clearly labeled Grafana TestData previews from the real dashboard layouts."""

import copy
import json
from pathlib import Path

import build_dashboards

ROOT = Path(__file__).resolve().parents[1]
DEMO_DS = {"type": "grafana-testdata-datasource", "uid": "ai-demo-data"}


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
        "Deployment,Model,ModelVersion,ScaleType,AllocatedPTUs,Region\n"
        "gpt-4o-prod,gpt-4o,2024-11-20,ProvisionedManaged,100,eastus\n"
        "gpt-4o-mini-prod,gpt-4o-mini,2024-07-18,ProvisionedManaged,50,eastus\n"
    ),
}

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
    5: "OperationId,Name,ResultCode,DurationMs,Agent,Operation\n0af7651916cd43dd8448eb211c80319c,model-request,429,1200,sample-agent,chat\n4bf92f3577b34da6a3ce929d0e0e4736,search-tool,503,2100,sample-agent,execute_tool\n",
    6: [
        ("ObservedSpans", [1600, 1650, 1630, 1700, 1750, 1730, 1780, 1820, 1900, 1850, 1880, 1920, 1860, 1840, 1890, 1850, 1800, 1820, 1840, 1810]),
        ("GenAISpans", [1200, 1250, 1230, 1300, 1350, 1330, 1380, 1420, 1500, 1450, 1480, 1520, 1460, 1440, 1490, 1450, 1400, 1420, 1440, 1410]),
        ("AgentRuns", AGENT_RUN_COUNTS),
        ("UnnamedAgentRuns", [4, 5, 4, 5, 6, 5, 5, 6, 7, 6, 5, 6, 5, 5, 6, 5, 4, 5, 5, 4]),
    ],
    7: "Evaluator,EvaluatedSamples,PassRatePercent,AverageScore,PassedSamples,FailedSamples,InvalidSamples\nexample-evaluator,80,90,0.84,72,8,0\n",
    8: "DependencyType,Dependency,ObservedCalls,FailedCalls,P95_ms\nHTTP,search.example.invalid,120,2,340\nHTTP,storage.example.invalid,86,1,210\n",
}

COST_ACTUAL = [
    112.50, 119.20, 116.30, 124.00, 127.40, 121.80, 132.10, 136.20, 139.50, 130.80,
    135.10, 141.20, 133.40, 128.60, 137.20, 131.30, 125.90, 129.40, 127.80, 126.10,
]
COST_AMORTIZED = [
    90.50, 95.20, 93.30, 99.00, 102.40, 97.80, 106.10, 110.20, 113.50, 105.80,
    109.10, 115.20, 107.40, 103.60, 111.20, 106.30, 100.90, 104.40, 102.80, 101.10,
]
actual_total = round(sum(COST_ACTUAL), 2)
amortized_total = round(sum(COST_AMORTIZED), 2)
actual_first = round(actual_total * 0.6, 2)
amortized_first = round(amortized_total * 0.6, 2)
COST_DATA = {
    2: (
        "Status,Coverage,LastCollectedUTC,HistoryFromUTC,HistoryThroughUTC,ReportedRows\n"
        "Current,Within history,2026-10-31 06:00,"
        "2026-08-03,2026-10-31,360\n"
    ),
    3: f"Currency,Amount\nUSD,{actual_total:.2f}\n",
    4: f"Currency,Amount\nUSD,{amortized_total:.2f}\n",
    5: [("Actual - USD", COST_ACTUAL)],
    6: [("Amortized - USD", COST_AMORTIZED)],
    7: (
        "Account,CostType,Currency,Amount,ResourceId\n"
        f"foundry-prod,ActualCost,USD,{actual_first:.2f},/subscriptions/demo/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/foundry-prod\n"
        f"foundry-prod,AmortizedCost,USD,{amortized_first:.2f},/subscriptions/demo/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/foundry-prod\n"
        f"openai-prod,ActualCost,USD,{actual_total - actual_first:.2f},/subscriptions/demo/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/openai-prod\n"
        f"openai-prod,AmortizedCost,USD,{amortized_total - amortized_first:.2f},/subscriptions/demo/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/openai-prod\n"
    ),
}
BUSINESS_DATA = {
    1: COST_DATA[2],
    2: COST_DATA[3],
    3: AGENT_DATA[2],
    4: PTU_DATA[1],
    5: COST_DATA[5],
    6: AGENT_DATA[1],
    7: PTU_DATA[3],
    8: [
        ("Input tokens", PTU_DATA[5][0][1]),
        ("Output tokens", PTU_DATA[6][0][1]),
    ],
}


def demo_dashboard(source, samples):
    result = copy.deepcopy(source)
    result["uid"] = f"demo-{source['uid']}"
    result["title"] = f"DEMO - {source['title']}"
    result["description"] = "SIMULATED DATA ONLY. This dashboard is not connected to Azure."
    result["tags"].append("demo-simulated-data")
    result.pop("__inputs", None)
    result["refresh"] = False
    for item in result["panels"]:
        item["gridPos"]["y"] += 3
        item["datasource"] = DEMO_DS
        if item["type"] == "text":
            continue
        sample = samples[item["id"]]
        item["targets"] = (
            [table(sample)] if isinstance(sample, str)
            else [series(name, values, chr(65 + index)) for index, (name, values) in enumerate(sample)]
        )
    result["panels"].insert(0, {
        "id": 999, "type": "text", "title": "SIMULATED DATA ONLY",
        "gridPos": {"h": 3, "w": 24, "x": 0, "y": 0},
        "options": {"mode": "markdown", "content": (
            "**Preview only.** Not connected to Azure; filters do not change the sample data."
        )},
    })
    return result


def build():
    config = json.loads((ROOT / "config.example.json").read_text(encoding="utf-8"))
    real = build_dashboards.build(config)
    return {
        "foundry-agents-demo.json": demo_dashboard(real["foundry-agents.json"], AGENT_DATA),
        "openai-ptu-demo.json": demo_dashboard(real["openai-ptu.json"], PTU_DATA),
        "azure-ai-costs-demo.json": demo_dashboard(real["azure-ai-costs.json"], COST_DATA),
        "business-overview-demo.json": demo_dashboard(real["business-overview.json"], BUSINESS_DATA),
    }


def main():
    output = ROOT / "demo" / "dashboards"
    output.mkdir(parents=True, exist_ok=True)
    for name, content in build().items():
        (output / name).write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
    print(f"Generated simulated-data dashboards in {output}")


if __name__ == "__main__":
    main()
