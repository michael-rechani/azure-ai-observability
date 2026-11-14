import csv
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("demo_builder", ROOT / "scripts" / "build_demo_dashboards.py")
demo_builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo_builder)


class DemoDashboardTests(unittest.TestCase):
    PAIRS = (
        ("foundry-agents.json", "foundry-agents-demo.json"),
        ("openai-ptu.json", "openai-ptu-demo.json"),
        ("business-overview.json", "business-overview-demo.json"),
    )

    @classmethod
    def setUpClass(cls):
        config = json.loads((ROOT / "config.example.json").read_text(encoding="utf-8"))
        cls.real = demo_builder.build_dashboards.build(config)
        cls.demo = demo_builder.build()

    def test_checked_in_previews_are_reproducible(self):
        for name, dashboard in self.demo.items():
            with self.subTest(name=name):
                self.assertEqual(
                    json.loads((ROOT / "demo" / "dashboards" / name).read_text(encoding="utf-8")),
                    dashboard,
                )

    def test_readme_leads_with_grafana_screenshots(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        introduction = readme.split("## What is included", 1)[0]
        self.assertIn("## Dashboards", introduction)
        for name in ("foundry-grafana-preview.png", "ptu-grafana-preview.png",
                     "business-overview-preview.png"):
            path = f"docs/images/{name}"
            with self.subTest(image=name):
                self.assertIn(f"]({path})", introduction)
                self.assertTrue((ROOT / path).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_demo_is_isolated_from_live_dashboards(self):
        real_uids = {dashboard["uid"] for dashboard in self.real.values()}
        demo_uids = {dashboard["uid"] for dashboard in self.demo.values()}
        for dashboard in self.demo.values():
            self.assertTrue(dashboard["uid"].startswith("demo-"))
            self.assertNotIn(dashboard["uid"], real_uids)
            for link in dashboard.get("links", []):
                self.assertIn(link["url"].split("/")[2], demo_uids)
                self.assertTrue(link["url"].split("/")[2].startswith("demo-"))
            for panel in dashboard["panels"]:
                self.assertEqual(panel["datasource"], demo_builder.DEMO_DS)
                if panel["type"] == "text":
                    self.assertEqual(panel.get("targets", []), [])
                    continue
                for target in panel["targets"]:
                    self.assertEqual(target["datasource"], demo_builder.DEMO_DS)
                    self.assertIn(target["scenarioId"], {"csv_metric_values", "csv_content"})
                    self.assertNotIn("azureMonitor", target)
                    self.assertNotIn("azureLogAnalytics", target)

    def test_demo_dashboards_carry_no_preview_labelling(self):
        for real_name, demo_name in self.PAIRS:
            real, demo = self.real[real_name], self.demo[demo_name]
            with self.subTest(dashboard=demo_name):
                for key in ("title", "tags", "description"):
                    self.assertEqual(demo.get(key), real.get(key))
                self.assertEqual([p["id"] for p in demo["panels"]], [p["id"] for p in real["panels"]])
                for variable in demo["templating"]["list"]:
                    for placeholder in ("replace", "existing-"):
                        self.assertNotIn(placeholder, variable.get("query", ""))
        for path in (ROOT / "demo" / "provisioning").rglob("*.yml"):
            with self.subTest(provisioning=path.name):
                self.assertNotIn("simulated", path.read_text(encoding="utf-8").lower())

    def test_demo_uses_production_layout_and_style(self):
        for real_name, demo_name in self.PAIRS:
            real_panels = {panel["id"]: panel for panel in self.real[real_name]["panels"]}
            demo_panels = {panel["id"]: panel for panel in self.demo[demo_name]["panels"]}
            self.assertEqual(set(real_panels), set(demo_panels))
            for panel_id, real_panel in real_panels.items():
                with self.subTest(dashboard=real_name, panel=panel_id):
                    rendered = demo_panels[panel_id]
                    self.assertEqual(rendered["fieldConfig"], real_panel["fieldConfig"])
                    self.assertEqual(rendered["options"], real_panel["options"])
                    self.assertEqual(rendered["gridPos"], real_panel["gridPos"])

    def test_simulated_series_are_coherent(self):
        utilization = demo_builder.PTU_DATA
        self.assertTrue(all(avg <= maximum for avg, maximum in zip(
            utilization[1][0][1], utilization[2][0][1], strict=True)))
        latency = demo_builder.AGENT_DATA[1]
        self.assertTrue(all(p50 <= p95 <= p99 for p50, p95, p99 in zip(
            latency[0][1], latency[1][1], latency[2][1], strict=True)))
        observed, failed = demo_builder.AGENT_DATA[2]
        self.assertTrue(all(failures <= runs for runs, failures in zip(
            observed[1], failed[1], strict=True)))
        spans, genai, agent_runs, unnamed = (
            values for _, values in demo_builder.AGENT_DATA[6]
        )
        self.assertEqual(observed[1], agent_runs)
        self.assertTrue(all(0 <= missing <= runs <= ai <= total for total, ai, runs, missing in zip(
            spans, genai, agent_runs, unnamed, strict=True)))
        for row in csv.DictReader(io.StringIO(demo_builder.PTU_DATA[11])):
            self.assertLessEqual(float(row["Mean"]), float(row["Max"]))
            self.assertLessEqual(float(row["Last *"]), float(row["Max"]))
        self.assertNotIn("AllocatedPTUs", demo_builder.PTU_DATA[11])
        self.assertIn("PassRatePercent", demo_builder.AGENT_DATA[7])
        # The summary tile agrees with the charts it summarizes.
        summary = next(csv.DictReader(io.StringIO(demo_builder.AGENT_DATA[9])))
        self.assertEqual(int(summary["ObservedRuns"]), sum(observed[1]))
        self.assertAlmostEqual(
            float(summary["FailureRatePercent"]), 100 * sum(failed[1]) / sum(observed[1]), places=2)
        self.assertTrue(min(latency[1][1]) <= float(summary["P95_ms"]) <= max(latency[1][1]))
        self.assertEqual(demo_builder.BUSINESS_DATA[8], demo_builder.AGENT_DATA[9])

    def test_dedicated_axes_distinguish_small_counts(self):
        agents = self.real["foundry-agents.json"]["panels"]
        for index, field in ((1, "FailedRuns"), (3, "MissingUsageSpans")):
            matches = [
                override for override in agents[index]["fieldConfig"]["overrides"]
                if field in override["matcher"]["options"]
            ]
            self.assertEqual(len(matches), 1)
            self.assertIn(
                {"id": "custom.axisPlacement", "value": "right"},
                matches[0]["properties"],
            )
        self.assertIn("not a coverage percentage", agents[5]["description"])


if __name__ == "__main__":
    unittest.main()
