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
    5: "OperationId,Name,ResultCode,DurationMs,Agent,Operation\nexample-trace-001,model-request,429,1200,sample-agent,chat\nexample-trace-002,search-tool,503,2100,sample-agent,execute_tool\n",
    6: [
        ("ObservedSpans", [1600, 1650, 1630, 1700, 1750, 1730, 1780, 1820, 1900, 1850, 1880, 1920, 1860, 1840, 1890, 1850, 1800, 1820, 1840, 1810]),
        ("GenAISpans", [1200, 1250, 1230, 1300, 1350, 1330, 1380, 1420, 1500, 1450, 1480, 1520, 1460, 1440, 1490, 1450, 1400, 1420, 1440, 1410]),
        ("AgentRuns", AGENT_RUN_COUNTS),
        ("UnnamedAgentRuns", [4, 5, 4, 5, 6, 5, 5, 6, 7, 6, 5, 6, 5, 5, 6, 5, 4, 5, 5, 4]),
    ],
    7: "Evaluator,EvaluatedSamples,AverageScore,FailedSamples,InvalidSamples\nexample-evaluator,80,0.84,8,0\n",
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
    }


def main():
    output = ROOT / "demo" / "dashboards"
    output.mkdir(parents=True, exist_ok=True)
    for name, content in build().items():
        (output / name).write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
    print(f"Generated two simulated-data dashboards in {output}")


if __name__ == "__main__":
    main()
