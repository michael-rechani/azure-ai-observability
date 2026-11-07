import copy
import importlib.util
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

    def test_demo_cannot_be_confused_with_live_dashboard(self):
        real_uids = {dashboard["uid"] for dashboard in self.real.values()}
        for dashboard in self.demo.values():
            self.assertTrue(dashboard["uid"].startswith("demo-"))
            self.assertNotIn(dashboard["uid"], real_uids)
            self.assertIn("SIMULATED", dashboard["description"])
            self.assertIn("SIMULATED DATA", dashboard["panels"][0]["title"])
            self.assertIn("do not change the sample data", dashboard["panels"][0]["options"]["content"])
            for panel in dashboard["panels"][1:]:
                self.assertEqual(panel["datasource"], demo_builder.DEMO_DS)
                for target in panel["targets"]:
                    self.assertEqual(target["datasource"], demo_builder.DEMO_DS)
                    self.assertIn(target["scenarioId"], {"csv_metric_values", "csv_content"})
                    self.assertNotIn("azureMonitor", target)
                    self.assertNotIn("azureLogAnalytics", target)

    def test_demo_uses_production_layout_and_style(self):
        pairs = (
            ("foundry-agents.json", "foundry-agents-demo.json"),
            ("openai-ptu.json", "openai-ptu-demo.json"),
        )
        for real_name, demo_name in pairs:
            real_panels = {panel["id"]: panel for panel in self.real[real_name]["panels"]}
            demo_panels = {panel["id"]: panel for panel in self.demo[demo_name]["panels"][1:]}
            self.assertEqual(set(real_panels), set(demo_panels))
            for panel_id, real_panel in real_panels.items():
                with self.subTest(dashboard=real_name, panel=panel_id):
                    rendered = copy.deepcopy(demo_panels[panel_id])
                    self.assertEqual(rendered["fieldConfig"], real_panel["fieldConfig"])
                    self.assertEqual(rendered["options"], real_panel["options"])
                    rendered["gridPos"]["y"] -= 3
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
