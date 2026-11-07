import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("builder", ROOT / "scripts" / "build_dashboards.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class DashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = json.loads((ROOT / "config.example.json").read_text())
        cls.dashboards = builder.build(cls.config)

    def test_checked_in_dashboards_match_generator(self):
        for name, expected in self.dashboards.items():
            with self.subTest(name=name):
                self.assertEqual(json.loads((ROOT / "dashboards" / name).read_text()), expected)

    def test_panel_ids_and_template_references(self):
        for dashboard in self.dashboards.values():
            variables = {v["name"] for v in dashboard["templating"]["list"]}
            variables |= {"DS_AZURE_MONITOR", "__interval"}
            self.assertEqual(len({p["id"] for p in dashboard["panels"]}), len(dashboard["panels"]))
            for panel in dashboard["panels"]:
                references = re.findall(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))", json.dumps(panel))
                for braced, plain in references:
                    name = braced or plain
                    if name != "__timeFilter":
                        self.assertIn(name, variables)
                self.assertEqual(panel["targets"][0]["datasource"], builder.DS)

    def test_ptu_uses_v2_and_real_units(self):
        panels = self.dashboards["openai-ptu.json"]["panels"]
        self.assertEqual(panels[0]["targets"][0]["azureMonitor"]["metricName"],
                         "AzureOpenAIProvisionedManagedUtilizationV2")
        self.assertEqual(panels[0]["fieldConfig"]["defaults"]["unit"], "percent")
        self.assertEqual(panels[6]["fieldConfig"]["defaults"]["unit"], "ms")
        names = {p["targets"][0]["azureMonitor"]["metricName"] for p in panels}
        self.assertNotIn("Latency", names)
        self.assertNotIn("AzureOpenAIProvisionedManagedUtilization", names)

    def test_throttling_has_deployment_and_429_filters(self):
        target = self.dashboards["openai-ptu.json"]["panels"][3]["targets"][0]["azureMonitor"]
        self.assertEqual(target["aggregation"], "Total")
        self.assertIn({"dimension": "StatusCode", "operator": "eq", "filters": ["429"]},
                      target["dimensionFilters"])
        self.assertIn({"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$deployment"]},
                      target["dimensionFilters"])

    def test_log_queries_are_time_bounded_and_workspace_scoped(self):
        for dashboard in self.dashboards.values():
            for panel in dashboard["panels"]:
                target = panel["targets"][0]
                if target["queryType"] == "Azure Log Analytics":
                    query = target["azureLogAnalytics"]
                    self.assertIn("$__timeFilter(TimeGenerated)", query["query"])
                    self.assertEqual(query["resources"], ["$workspaceResourceId"])
                    self.assertTrue(query["dashboardTime"])

    def test_invalid_configuration_is_rejected(self):
        cases = [
            ("subscription", "invalid"),
            ("workspaceResourceId", "not-an-arm-id"),
        ]
        for key, value in cases:
            config = copy.deepcopy(self.config)
            config[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                builder.build(config)
        config = copy.deepcopy(self.config)
        config["ptu"]["deployment"] = "bad'filter"
        with self.assertRaises(ValueError):
            builder.build(config)

    def test_foundry_and_ptu_targets_remain_independent(self):
        foundry = self.dashboards["foundry-overview.json"]
        ptu = self.dashboards["openai-ptu.json"]
        foundry_defaults = {v["name"]: v["current"]["value"] for v in foundry["templating"]["list"]}
        ptu_defaults = {v["name"]: v["current"]["value"] for v in ptu["templating"]["list"]}
        self.assertEqual(foundry_defaults["account"], self.config["foundry"]["account"])
        self.assertEqual(ptu_defaults["account"], self.config["ptu"]["account"])
        self.assertNotEqual(foundry_defaults["account"], ptu_defaults["account"])
        self.assertEqual(foundry_defaults["deployment"], "*")
        self.assertEqual(ptu_defaults["deployment"], self.config["ptu"]["deployment"])

    def test_all_configured_metrics_use_documented_aggregations(self):
        totals = {"AzureOpenAIRequests", "GeneratedTokens", "ProcessedPromptTokens", "TokenTransaction"}
        averages = {
            "AzureOpenAIProvisionedManagedUtilizationV2", "AzureOpenAITimeToResponse",
            "AzureOpenAITTLTInMS", "AzureOpenAINormalizedTBTInMS",
            "AzureOpenAIContextTokensCacheMatchRate",
        }
        for dashboard in self.dashboards.values():
            for panel in dashboard["panels"]:
                query = panel["targets"][0].get("azureMonitor")
                if query:
                    self.assertIn(query["metricName"], totals | averages)
                    expected = {"Total"} if query["metricName"] in totals else {"Average", "Maximum"}
                    self.assertIn(query["aggregation"], expected)
                    self.assertEqual(query["metricNamespace"], builder.NAMESPACE)

    def test_token_query_avoids_parent_child_double_counting(self):
        query = (ROOT / "queries" / "model-tokens.kql").read_text()
        self.assertIn('in ("chat", "text_completion")', query)
        self.assertIn("MissingUsageSpans", query)
        self.assertNotIn('"invoke_agent"', query)

    def test_agent_table_duration_units(self):
        panels = self.dashboards["foundry-agents.json"]["panels"]
        for index, field in ((2, "P95_ms"), (4, "DurationMs")):
            with self.subTest(field=field):
                matches = [
                    override for override in panels[index]["fieldConfig"]["overrides"]
                    if override["matcher"]["options"] == f"/^{field}$/"
                ]
                self.assertEqual(len(matches), 1)
                self.assertIn({"id": "unit", "value": "ms"}, matches[0]["properties"])

    def test_instrumentation_counts_do_not_imply_percentage(self):
        panels = (
            self.dashboards["foundry-agents.json"]["panels"][5],
            self.dashboards["foundry-overview.json"]["panels"][1],
        )
        for panel in panels:
            with self.subTest(title=panel["title"]):
                self.assertIn("Observed", panel["title"])
                self.assertIn("not a coverage percentage", panel["description"])


if __name__ == "__main__":
    unittest.main()
