import copy
import importlib.util
import json
from pathlib import Path
import re
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
            variables |= {"DS_AZURE_MONITOR", "DS_COST_INFINITY", "__interval"}
            self.assertEqual(len({p["id"] for p in dashboard["panels"]}), len(dashboard["panels"]))
            for panel in dashboard["panels"]:
                if panel["type"] == "text":
                    continue
                scanned = copy.deepcopy(panel)
                for target in scanned["targets"]:
                    target.pop("root_selector", None)  # jq variables such as $p are not dashboard variables
                references = re.findall(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))", json.dumps(scanned))
                for braced, plain in references:
                    name = braced or plain
                    if not name.startswith("__"):
                        self.assertIn(name, variables)
                expected = {
                    "azure-ai-costs-infinity": builder.DS_INFINITY,
                }.get(dashboard["uid"], builder.DS)
                self.assertEqual(panel["targets"][0]["datasource"], expected)

    def test_infinity_cost_dashboard_queries_only_ai_accounts_with_a_bounded_scope(self):
        dashboard = self.dashboards["azure-ai-costs-infinity.json"]
        self.assertEqual(
            dashboard["__inputs"],
            [{
                "name": "DS_COST_INFINITY", "label": "Cost Management (Infinity)", "type": "datasource",
                "pluginId": "yesoreyeram-infinity-datasource", "pluginName": "Infinity",
            }],
        )
        self.assertEqual(dashboard["timezone"], "utc")
        self.assertIn("not zero cost", dashboard["description"])
        self.assertIn("rotate", dashboard["description"])
        scope = next(v for v in dashboard["templating"]["list"] if v["name"] == "costScope")
        self.assertEqual(scope["query"], f"/subscriptions/{self.config['subscription']}")
        for panel in dashboard["panels"]:
            target = panel["targets"][0]
            self.assertEqual(panel["datasource"], builder.DS_INFINITY)
            self.assertEqual(target["datasource"], builder.DS_INFINITY)
            self.assertEqual(
                target["url"],
                "https://management.azure.com${costScope}/providers/Microsoft.CostManagement/query"
                "?api-version=2023-11-01",
            )
            self.assertEqual(target["url_options"]["method"], "POST")
            self.assertEqual(target["parser"], "jq-backend")
            self.assertIn("incomplete_cost_response", target["root_selector"])
            body = self.cost_body(target)
            self.assertEqual(body["type"], "ActualCost")
            self.assertEqual(
                body["dataset"]["filter"],
                {"dimensions": {
                    "name": "ResourceType", "operator": "In",
                    "values": ["microsoft.cognitiveservices/accounts"],
                }},
            )
            self.assertEqual(body["dataset"]["aggregation"]["totalCost"]["name"], "PreTaxCost")
            self.assertIn("Currency", [column["selector"] for column in target["columns"]])
        total = next(p for p in dashboard["panels"] if p["title"].startswith("Month-to-date"))
        self.assertEqual(self.cost_body(total["targets"][0])["timeframe"], "MonthToDate")
        daily = next(p for p in dashboard["panels"] if p["title"] == "Daily actual cost")
        daily_body = self.cost_body(daily["targets"][0])
        self.assertEqual(daily_body["dataset"]["granularity"], "Daily")
        self.assertEqual(daily_body["timeframe"], "Custom")
        self.assertEqual(daily["transformations"][0]["options"]["fields"], ["Currency"])

    @staticmethod
    def cost_body(target):
        data = target["url_options"]["data"]
        return json.loads(data.replace("${__from:date:iso}", "from").replace("${__to:date:iso}", "to"))



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
                if target.get("queryType") == "Azure Log Analytics":
                    query = target["azureLogAnalytics"]
                    self.assertEqual(query["resources"], ["$workspaceResourceId"])
                    self.assertIn("$__timeFilter(TimeGenerated)", query["query"])
                    self.assertTrue(query["dashboardTime"])

    def test_removed_function_collector_leaves_no_dashboard_or_query_behind(self):
        self.assertNotIn("azure-ai-costs.json", self.dashboards)
        self.assertEqual(
            {dashboard["uid"] for dashboard in self.dashboards.values()},
            {
                "foundry-overview", "foundry-agent-operations", "azure-openai-ptu",
                "azure-ai-business-overview", "azure-ai-costs-infinity",
            },
        )
        self.assertEqual(list((ROOT / "queries").glob("cost-*.kql")), [])
        for dashboard in self.dashboards.values():
            self.assertNotIn("AICostSnapshot_CL", json.dumps(dashboard))

    def test_business_overview_keeps_data_sources_and_meaning_separate(self):
        dashboard = self.dashboards["business-overview.json"]
        panels = dashboard["panels"]
        self.assertEqual(dashboard["time"], {"from": "now-7d", "to": "now"})
        self.assertIn("does not calculate a blended health score", dashboard["description"])
        self.assertIn("shows no cost", dashboard["description"])
        self.assertEqual(len({item["id"] for item in panels}), len(panels))
        self.assertEqual(len(panels), 7)
        self.assertEqual(panels[0]["title"], "Observed agent runs per interval")
        self.assertIn("not the total for the selected range", panels[0]["description"])
        self.assertEqual(
            panels[0]["targets"][0]["azureLogAnalytics"]["query"],
            (ROOT / "queries" / "agent-run-volume.kql").read_text(),
        )
        self.assertEqual(
            panels[1]["targets"][0]["azureMonitor"]["metricName"],
            "AzureOpenAIProvisionedManagedUtilizationV2",
        )
        self.assertEqual(
            panels[3]["targets"][0]["azureMonitor"]["dimensionFilters"][1]["filters"],
            ["*"],
        )
        self.assertEqual(panels[4]["title"], "Throttled requests (429)")
        self.assertEqual(
            panels[4]["targets"][0]["azureMonitor"]["dimensionFilters"][1]["filters"],
            ["429"],
        )
        self.assertEqual(panels[5]["title"], "Agent run failure rate")
        self.assertIn("known success/failure outcome", panels[5]["description"])
        self.assertEqual(panels[5]["fieldConfig"]["defaults"]["unit"], "percent")
        self.assertEqual(panels[5]["fieldConfig"]["defaults"]["min"], 0)
        self.assertNotIn("max", panels[5]["fieldConfig"]["defaults"])
        failure_query = panels[5]["targets"][0]["azureLogAnalytics"]["query"]
        self.assertIn("FailureRatePercent", failure_query)
        self.assertIn("| where isnotnull(Success)", failure_query)
        self.assertIn("KnownOutcomeRuns = sum(ItemCount)", failure_query)
        self.assertIn("sumif(ItemCount, Success == false)", failure_query)
        self.assertEqual(panels[6]["title"], "PTU input and output tokens")
        self.assertEqual(
            {link["title"] for link in dashboard["links"]},
            {"Agent operations", "PTU performance"},
        )
        self.assertTrue(all(link["keepTime"] for link in dashboard["links"]))
        self.assertEqual(
            [item["name"] for item in dashboard["templating"]["list"]],
            [
                "workspaceResourceId", "ptuSubscription",
                "ptuResourceGroup", "ptuAccount", "ptuRegion", "ptuDeployment",
            ],
        )

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
        totals = {
            "AzureOpenAIRequests", "GeneratedTokens", "ProcessedPromptTokens", "TokenTransaction",
            "InputTokens", "OutputTokens",
        }
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
        self.assertIn('"chat", "text_completion", "invoke_agent"', query)
        self.assertIn("MissingUsageSpans", query)
        # invoke_agent usage is counted only when no model span in the trace carries usage.
        self.assertIn("OperationId !in (TracesWithModelUsage)", query)
        self.assertIn('Operation in ("chat", "text_completion")', query)
        self.assertIn("Success != false", query)

    def test_token_cost_panel_is_a_labelled_estimate_from_native_sources(self):
        panel = self.dashboards["foundry-overview.json"]["panels"][4]
        self.assertEqual(panel["id"], 5)
        self.assertEqual(panel["type"], "table")
        self.assertIn("Estimated", panel["title"])
        self.assertIn("not billed", panel["title"])
        for caveat in ("estimate", "cach", "PTU", "no list price", "Cost Management"):
            self.assertIn(caveat, panel["description"])
        by_ref = {target["refId"]: target for target in panel["targets"]}
        self.assertEqual(set(by_ref), {"A", "B", "C"})
        for ref, metric_name in (("A", "InputTokens"), ("B", "OutputTokens")):
            query = by_ref[ref]["azureMonitor"]
            self.assertEqual(query["metricName"], metric_name)
            self.assertEqual(query["aggregation"], "Total")
            self.assertEqual(query["dimensionFilters"],
                             [{"dimension": "ModelName", "operator": "eq", "filters": ["*"]}])
        prices = by_ref["C"]
        self.assertEqual(prices["queryType"], "Azure Log Analytics")
        self.assertEqual(prices["azureLogAnalytics"]["resources"], ["$workspaceResourceId"])
        self.assertEqual(prices["azureLogAnalytics"]["resultFormat"], "table")
        self.assertFalse(prices["azureLogAnalytics"]["dashboardTime"])
        self.assertEqual(prices["azureLogAnalytics"]["query"],
                         (ROOT / "queries" / "model-prices.kql").read_text(encoding="utf-8"))
        steps = [step["id"] for step in panel["transformations"]]
        self.assertEqual(steps[:4], ["labelsToFields", "merge", "groupBy", "filterByValue"])
        self.assertEqual(steps[-1], "organize")
        self.assertEqual(steps.count("calculateField"), 4)

    def test_model_price_table_matches_the_columns_the_panel_transforms(self):
        query = (ROOT / "queries" / "model-prices.kql").read_text(encoding="utf-8")
        self.assertIn("datatable(modelname: string, InputPer1M: real, OutputPer1M: real)", query)
        # The panel's groupBy needs both token fields even when one metric has no series.
        self.assertIn("['Input Tokens'] = real(null)", query)
        self.assertIn("['Output Tokens'] = real(null)", query)
        rows = re.findall(r'^\s*"([^"]+)",\s*([0-9.]+),\s*([0-9.]+),?\s*$', query, re.MULTILINE)
        names = [name for name, _, _ in rows]
        self.assertGreaterEqual(len(rows), 10)
        self.assertEqual(len(names), len(set(names)))
        for name, input_price, output_price in rows:
            with self.subTest(model=name):
                self.assertEqual(name, name.lower())
                self.assertGreater(float(input_price), 0)
                self.assertGreaterEqual(float(output_price), 0)
        for model in ("gpt-5.4", "gpt-5.4-mini", "gpt-4.1"):
            self.assertIn(model, names)
        grouped = next(
            step for step in self.dashboards["foundry-overview.json"]["panels"][4]["transformations"]
            if step["id"] == "groupBy"
        )["options"]["fields"]
        self.assertEqual(
            set(grouped), {"modelname", "Input Tokens", "Output Tokens", "InputPer1M", "OutputPer1M"}
        )

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
        labels = {
            entry["matcher"]["options"]: {
                item["id"]: item["value"] for item in entry["properties"]
            }
            for entry in panel["fieldConfig"]["overrides"]
            if entry["matcher"]["options"] in {"/^OperationId$/", "/^DurationMs$/", "/^ResultCode$/"}
        }
        self.assertEqual(labels["/^OperationId$/"]["displayName"], "Trace ID")
        self.assertEqual(labels["/^DurationMs$/"]["displayName"], "Duration")
        self.assertEqual(labels["/^ResultCode$/"]["displayName"], "Result")

    def test_agent_failure_rate_is_sampling_weighted_and_time_bounded(self):
        query = (ROOT / "queries" / "agent-failure-rate.kql").read_text()
        self.assertIn("$__timeFilter(TimeGenerated)", query)
        self.assertIn("| where isnotnull(Success)", query)
        self.assertIn("KnownOutcomeRuns = sum(ItemCount)", query)
        self.assertIn("FailedRuns = sumif(ItemCount, Success == false)", query)
        self.assertIn("100.0 * todouble(FailedRuns) / todouble(KnownOutcomeRuns)", query)
        self.assertIn("real(null)", query)

    def test_failed_operations_table_fits_its_half_width_panel(self):
        panel = self.dashboards["foundry-agents.json"]["panels"][4]
        widths = [
            item["value"]
            for entry in panel["fieldConfig"]["overrides"]
            for item in entry["properties"]
            if item["id"] == "custom.width"
        ]
        self.assertEqual(len(widths), 5)
        self.assertLessEqual(sum(widths), 700)
        query = (ROOT / "queries" / "failed-operations.kql").read_text()
        self.assertIn("project TimeGenerated, OperationId, Name, ResultCode, DurationMs", query)
        self.assertNotIn("Agent =", query)
        self.assertNotIn("Operation =", query)

    def test_agent_run_panels_disclose_per_interval_counts(self):
        panels = (
            self.dashboards["foundry-agents.json"]["panels"][1],
            self.dashboards["business-overview.json"]["panels"][0],
        )
        for panel in panels:
            with self.subTest(title=panel["title"]):
                self.assertIn("per interval", panel["title"])
                self.assertIn("time-bucket count", panel["description"])

    def test_dashboard_links_preserve_time_and_only_map_compatible_filters(self):
        dashboards_by_uid = {item["uid"]: item for item in self.dashboards.values()}

        def variable_names(item):
            return {variable["name"] for variable in item["templating"]["list"]}

        for dashboard in self.dashboards.values():
            for link in dashboard.get("links", []):
                with self.subTest(dashboard=dashboard["uid"], link=link["title"]):
                    self.assertTrue(link["url"].startswith("/d/"))
                    target = dashboards_by_uid[link["url"].split("/")[2]]
                    self.assertTrue(link["keepTime"])
                    self.assertFalse(link["includeVars"])
                    for target_variable, source_variable in re.findall(
                        r"var-([A-Za-z0-9_]+)=\$\{([A-Za-z0-9_]+):percentencode\}",
                        link["url"],
                    ):
                        self.assertIn(target_variable, variable_names(target))
                        self.assertIn(source_variable, variable_names(dashboard))
        business_ptu_link = next(
            link for link in self.dashboards["business-overview.json"]["links"]
            if link["title"] == "PTU performance"
        )
        self.assertIn("var-subscription=${ptuSubscription:percentencode}", business_ptu_link["url"])

    def test_ptu_deployment_table_uses_metric_not_resource_graph(self):
        panel = self.dashboards["openai-ptu.json"]["panels"][10]
        self.assertEqual(panel["type"], "table")
        target = panel["targets"][0]
        self.assertNotIn("azureResourceGraph", target)
        self.assertEqual(target["azureMonitor"]["metricName"], "AzureOpenAIProvisionedManagedUtilizationV2")
        self.assertEqual(target["azureMonitor"]["aggregation"], "Maximum")
        reduce = panel["transformations"][0]
        self.assertEqual(reduce["id"], "reduce")
        self.assertEqual(reduce["options"]["mode"], "seriesToRows")
        self.assertIn("allocated PTUs", panel["description"])
        self.assertFalse((ROOT / "queries" / "ptu-deployments.kql").exists())

    def test_agent_alert_queries_are_bounded_and_gated(self):
        failure = (ROOT / "queries" / "alerts" / "agent-failure-rate.kql").read_text()
        latency = (ROOT / "queries" / "alerts" / "agent-p95-latency.kql").read_text()
        heartbeat = (ROOT / "queries" / "alerts" / "agent-heartbeat.kql").read_text()
        for query in (failure, latency, heartbeat):
            with self.subTest(query=query[:40]):
                self.assertIn("union AppRequests, AppDependencies", query)
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
