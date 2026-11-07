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
                if panel["type"] == "text":
                    continue
                references = re.findall(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))", json.dumps(panel))
                for braced, plain in references:
                    name = braced or plain
                    if not name.startswith("__"):
                        self.assertIn(name, variables)
                self.assertEqual(panel["targets"][0]["datasource"], builder.DS)

    def test_ptu_uses_v2_and_real_units(self):
        panels = self.dashboards["openai-ptu.json"]["panels"]
        self.assertEqual(panels[0]["targets"][0]["azureMonitor"]["metricName"],
                         "AzureOpenAIProvisionedManagedUtilizationV2")
        self.assertEqual(panels[0]["fieldConfig"]["defaults"]["unit"], "percent")
        self.assertEqual(panels[6]["fieldConfig"]["defaults"]["unit"], "ms")
        names = {
            p["targets"][0]["azureMonitor"]["metricName"]
            for p in panels
            if p["targets"] and "azureMonitor" in p["targets"][0]
        }
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
                if panel["type"] == "text":
                    continue
                target = panel["targets"][0]
                if target["queryType"] == "Azure Log Analytics":
                    query = target["azureLogAnalytics"]
                    expected_workspace = (
                        "$monitoringWorkspaceResourceId"
                        if dashboard["uid"] == "azure-ai-business-overview"
                        and panel["id"] in {1, 2, 5}
                        else "$workspaceResourceId"
                    )
                    self.assertEqual(query["resources"], [expected_workspace])
                    if dashboard["uid"] == "azure-ai-costs":
                        self.assertIn("TimeGenerated >= ago(14d)", query["query"])
                        self.assertFalse(query["dashboardTime"])
                    elif dashboard["uid"] == "azure-ai-business-overview" and panel["id"] in {1, 2, 5}:
                        self.assertIn("TimeGenerated >= ago(14d)", query["query"])
                        self.assertFalse(query["dashboardTime"])
                    else:
                        self.assertIn("$__timeFilter(TimeGenerated)", query["query"])
                        self.assertTrue(query["dashboardTime"])

    def test_cost_queries_select_only_the_latest_complete_deduplicated_snapshot(self):
        prefix = (ROOT / "queries" / "cost-snapshot.kql").read_text()
        self.assertIn("summarize arg_max(TimeGenerated, *) by RunId, RowKey", prefix)
        self.assertIn("summarize IngestedRows = count() by RunId", prefix)
        self.assertIn("ExpectedRows == IngestedRows", prefix)
        self.assertIn("top 1 by SnapshotTime desc", prefix)
        self.assertNotIn("dcount(", prefix)
        panels = self.dashboards["azure-ai-costs.json"]["panels"]
        for item in panels:
            if item["type"] != "text":
                query = item["targets"][0]["azureLogAnalytics"]["query"]
                self.assertTrue(query.startswith(prefix))
        status = panels[1]["targets"][0]["azureLogAnalytics"]["query"]
        for state in ("Missing snapshot", "Stale - check logs", "No cost data",
                      "Before history", "After history"):
            self.assertIn(state, status)
        self.assertIn("ago(48h)", status)

    def test_business_overview_keeps_data_sources_and_meaning_separate(self):
        dashboard = self.dashboards["business-overview.json"]
        panels = dashboard["panels"]
        self.assertEqual(dashboard["time"], {"from": "now-7d", "to": "now"})
        self.assertIn("does not calculate a blended health score", dashboard["description"])
        self.assertEqual(len({item["id"] for item in panels}), len(panels))
        self.assertEqual(panels[0]["title"], "Cost collection status")
        self.assertIn("not zero cost", panels[0]["description"])
        self.assertEqual([item["gridPos"]["w"] for item in panels], [8, 8, 8, 8, 8, 8, 12, 12])
        collection_fields = panels[0]["transformations"][0]["options"]
        self.assertEqual(
            collection_fields["indexByName"],
            {"Status": 0, "Coverage": 1},
        )
        self.assertEqual(
            collection_fields["excludeByName"],
            {
                "LastCollectedUTC": True,
                "HistoryFromUTC": True,
                "HistoryThroughUTC": True,
                "ReportedRows": True,
            },
        )
        self.assertIn("ActualCost", panels[1]["targets"][0]["azureLogAnalytics"]["query"])
        self.assertIn("Currency", panels[1]["targets"][0]["azureLogAnalytics"]["query"])
        self.assertIn("not a coverage percentage", panels[2]["description"])
        self.assertEqual(
            panels[3]["targets"][0]["azureMonitor"]["metricName"],
            "AzureOpenAIProvisionedManagedUtilizationV2",
        )
        self.assertEqual(
            panels[6]["targets"][0]["azureMonitor"]["dimensionFilters"][1]["filters"],
            ["*"],
        )
        self.assertEqual(
            [item["name"] for item in dashboard["templating"]["list"]],
            [
                "workspaceResourceId", "monitoringWorkspaceResourceId", "ptuSubscription",
                "ptuResourceGroup", "ptuAccount", "ptuRegion", "ptuDeployment",
            ],
        )

    def test_cost_totals_and_trends_keep_types_currencies_and_usage_dates_separate(self):
        panels = self.dashboards["azure-ai-costs.json"]["panels"]
        for index, cost_type in ((2, "ActualCost"), (3, "AmortizedCost"),
                                 (4, "ActualCost"), (5, "AmortizedCost")):
            query = panels[index]["targets"][0]["azureLogAnalytics"]["query"].split("let LatestCostRows", 1)[1]
            self.assertIn(f'CostType == "{cost_type}"', query)
            self.assertIn("Currency", query.split("summarize Amount = sum(Cost) by ", 1)[1])
            self.assertIn("UsageDate >= startofday($__timeFrom())", query)
            self.assertIn("UsageDate < $__timeTo()", query)
            self.assertNotIn("coalesce(sum(Cost)", query)
            self.assertEqual(panels[index]["fieldConfig"]["defaults"]["unit"], "none")
        account_query = panels[6]["targets"][0]["azureLogAnalytics"]["query"]
        self.assertIn("by ResourceId, CostType, Currency", account_query)
        self.assertEqual(self.dashboards["azure-ai-costs.json"]["timezone"], "utc")
        self.assertIn("do not add them together", panels[0]["options"]["content"])

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
        business = self.dashboards["business-overview.json"]
        business_defaults = {v["name"]: v["current"]["value"] for v in business["templating"]["list"]}
        self.assertEqual(business_defaults["ptuAccount"], self.config["ptu"]["account"])
        self.assertEqual(business_defaults["ptuDeployment"], self.config["ptu"]["deployment"])

    def test_all_configured_metrics_use_documented_aggregations(self):
        totals = {"AzureOpenAIRequests", "GeneratedTokens", "ProcessedPromptTokens", "TokenTransaction"}
        averages = {
            "AzureOpenAIProvisionedManagedUtilizationV2", "AzureOpenAITimeToResponse",
            "AzureOpenAITTLTInMS", "AzureOpenAINormalizedTBTInMS",
            "AzureOpenAIContextTokensCacheMatchRate",
        }
        for dashboard in self.dashboards.values():
            for panel in dashboard["panels"]:
                query = panel["targets"][0].get("azureMonitor") if panel["targets"] else None
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

    def test_failed_operation_links_to_workspace_trace_query(self):
        panel = self.dashboards["foundry-agents.json"]["panels"][4]
        operation_id = next(
            item for item in panel["fieldConfig"]["overrides"]
            if item["matcher"]["options"] == "/^OperationId$/"
        )
        link = operation_id["properties"][0]["value"][0]["url"]
        self.assertIn("${workspaceResourceId:percentencode}", link)
        self.assertIn("${__value.raw}", link)
        self.assertIn("AppDependencies", link)
        self.assertIn("isQueryBase64Compressed/false", link)

    def test_ptu_capacity_inventory_is_scoped_to_account(self):
        panel = self.dashboards["openai-ptu.json"]["panels"][10]
        query = panel["targets"][0]["azureResourceGraph"]["query"]
        self.assertIn('type =~ "microsoft.cognitiveservices/accounts/deployments"', query)
        self.assertIn('resourceGroup =~ "$resourceGroup"', query)
        self.assertIn('name startswith strcat("$account", "/")', query)
        self.assertIn('sku.name =~ "ProvisionedManaged"', query)
        self.assertIn("not regional quota", panel["description"])

    def test_agent_alert_queries_are_bounded_and_gated(self):
        failure = (ROOT / "queries" / "alerts" / "agent-failure-rate.kql").read_text()
        latency = (ROOT / "queries" / "alerts" / "agent-p95-latency.kql").read_text()
        heartbeat = (ROOT / "queries" / "alerts" / "agent-heartbeat.kql").read_text()
        for query in (failure, latency, heartbeat):
            with self.subTest(query=query[:40]):
                self.assertIn("AppRequests", query)
                self.assertIn("ago(", query)
                self.assertNotIn("$__timeFilter", query)
        self.assertIn("${minimum_agent_runs}", failure)
        self.assertIn("FailureRatePercent", failure)
        self.assertIn("P95Ms", latency)
        self.assertIn("ObservedRuns", heartbeat)

    def test_dependency_query_is_scoped_and_aggregated(self):
        query = (ROOT / "queries" / "agent-dependencies.kql").read_text()
        self.assertIn("$__timeFilter(TimeGenerated)", query)
        self.assertIn("AppDependencies", query)
        self.assertIn("P95_ms", query)

    def test_evaluations_report_sample_pass_rate_without_empty_division(self):
        query = (ROOT / "queries" / "evaluations.kql").read_text()
        self.assertIn("PassRatePercent", query)
        self.assertIn("ValidSamples > 0", query)
        self.assertIn("InvalidSamples", query)


if __name__ == "__main__":
    unittest.main()
