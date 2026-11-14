import copy
import importlib.util
import itertools
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
                references = re.findall(
                    r"\$(?:\{([A-Za-z_]\w*)(?::[^}]*)?\}|([A-Za-z_]\w*))", json.dumps(scanned)
                )
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
        self.assertIn("filter applies only to the agent panels", dashboard["description"])
        self.assertEqual(len({item["id"] for item in panels}), len(panels))
        self.assertEqual(len(panels), 10)
        self.assertEqual([item["id"] for item in panels[7:]], [8, 9, 10])
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
                "workspaceResourceId", "agent", "ptuSubscription",
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

    def test_agent_filter_is_injection_safe_and_declared_per_panel(self):
        reference = re.compile(r"\$(?:\{agent(?::[^}]*)?\}|agent\b)")
        declaration = 'let selectedAgent = url_decode("${agent:percentencode}");'
        filter_line = '| where selectedAgent in ("", "*") or Agent =~ selectedAgent'
        filtered = {
            "agent-latency.kql", "agent-runs.kql", "agent-run-volume.kql",
            "agent-failure-rate.kql", "agent-summary.kql",
        }
        for path in sorted((ROOT / "queries").glob("*.kql")):
            query = path.read_text()
            with self.subTest(query=path.name):
                if path.name in filtered:
                    # Grafana expands $__ macros after variable interpolation, even inside string literals,
                    # so a JSON-quoted value is not enough. Percent-encoding leaves no quote, backslash,
                    # dollar sign or parenthesis in the substituted text, and Kusto decodes it.
                    self.assertEqual(reference.findall(query), ["${agent:percentencode}"])
                    self.assertTrue(query.startswith(declaration + "\n"))
                    self.assertIn(filter_line, query)
                    self.assertLess(query.index("extend Agent ="), query.index(filter_line))
                else:
                    self.assertEqual(reference.findall(query), [])
        for dashboard in self.dashboards.values():
            self.assertLessEqual(
                set(reference.findall(json.dumps(dashboard["panels"]))), {"${agent:percentencode}"})
        # A panel says it ignores the filter exactly when its query does.
        for item in self.dashboards["foundry-agents.json"]["panels"]:
            query = item["targets"][0]["azureLogAnalytics"]["query"]
            with self.subTest(panel=item["title"]):
                self.assertEqual(
                    "${agent:percentencode}" in query,
                    "Not filtered by the agent variable" not in item["description"],
                )

    def test_agent_variable_defaults_to_all_and_is_shared_only_between_agent_dashboards(self):
        expected = {
            "foundry-agents.json": True, "business-overview.json": True, "foundry-overview.json": False,
            "openai-ptu.json": False, "azure-ai-costs-infinity.json": False,
        }
        for name, has_agent in expected.items():
            variables = {item["name"]: item for item in self.dashboards[name]["templating"]["list"]}
            with self.subTest(dashboard=name):
                self.assertEqual("agent" in variables, has_agent)
                if has_agent:
                    self.assertEqual(variables["agent"]["type"], "textbox")
                    self.assertEqual(variables["agent"]["current"]["value"], "*")
        carrying = {
            (dashboard["uid"], link["title"])
            for dashboard in self.dashboards.values()
            for link in dashboard.get("links", [])
            if "var-agent=${agent:percentencode}" in link["url"]
        }
        self.assertEqual(carrying, {
            ("foundry-agent-operations", "Business overview"),
            ("azure-ai-business-overview", "Agent operations"),
        })

    def test_summary_tiles_are_whole_period_and_null_safe(self):
        query = (ROOT / "queries" / "agent-summary.kql").read_text()
        self.assertIn("$__timeFilter(TimeGenerated)", query)
        self.assertNotIn("bin(", query)  # one row for the whole period, not one per interval
        self.assertIn("Runs = sum(ItemCount)", query)
        self.assertIn("KnownOutcomeRuns = sumif(ItemCount, isnotnull(Success))", query)
        self.assertIn("FailedRuns = sumif(ItemCount, Success == false)", query)
        self.assertIn("P95_ms = percentile(DurationMs, 95)", query)
        # Nothing observed must read as "No data", not as zero runs or a division error.
        self.assertIn("iff(Runs > 0, Runs, long(null))", query)
        self.assertIn("KnownOutcomeRuns > 0", query)
        self.assertIn("real(null)", query)
        by_id = {
            name: {item["id"]: item for item in self.dashboards[name]["panels"]}
            for name in ("openai-ptu.json", "foundry-agents.json", "business-overview.json")
        }
        for tile in (by_id["foundry-agents.json"][9], by_id["business-overview.json"][8]):
            with self.subTest(tile=tile["id"]):
                self.assertEqual(tile["type"], "stat")
                self.assertEqual(tile["targets"][0]["azureLogAnalytics"]["query"], query)
                self.assertEqual(tile["targets"][0]["azureLogAnalytics"]["resultFormat"], "table")
                self.assertEqual(tile["options"]["reduceOptions"]["calcs"], ["lastNotNull"])
        for peak in (by_id["openai-ptu.json"][13], by_id["business-overview.json"][9]):
            with self.subTest(tile=peak["id"]):
                target = peak["targets"][0]["azureMonitor"]
                self.assertEqual(target["metricName"], "AzureOpenAIProvisionedManagedUtilizationV2")
                self.assertEqual(target["aggregation"], "Maximum")
                self.assertEqual(peak["options"]["reduceOptions"]["calcs"], ["max"])
        for throttled in (by_id["openai-ptu.json"][14], by_id["business-overview.json"][10]):
            with self.subTest(tile=throttled["id"]):
                target = throttled["targets"][0]["azureMonitor"]
                self.assertEqual(target["metricName"], "AzureOpenAIRequests")
                self.assertEqual(target["aggregation"], "Total")
                self.assertIn(
                    {"dimension": "StatusCode", "operator": "eq", "filters": ["429"]},
                    target["dimensionFilters"],
                )
                self.assertEqual(throttled["options"]["reduceOptions"]["calcs"], ["sum"])
        # A missing value must render as neutral "No data", not take the green base threshold colour.
        no_data = [{"type": "special", "options": {
            "match": "null+nan", "result": {"text": "No data", "color": "text", "index": 0},
        }}]
        for name, tile_ids in (
            ("openai-ptu.json", (13, 14)), ("foundry-agents.json", (9,)), ("business-overview.json", (8, 9, 10)),
        ):
            for tile_id in tile_ids:
                with self.subTest(dashboard=name, tile=tile_id):
                    self.assertEqual(by_id[name][tile_id]["fieldConfig"]["defaults"]["mappings"], no_data)
        # On the Business dashboard the PTU tiles follow the PTU variables, not the Foundry ones.
        self.assertEqual(by_id["business-overview.json"][9]["targets"][0]["subscription"], "$ptuSubscription")
        self.assertIn(
            {"dimension": "ModelDeploymentName", "operator": "eq", "filters": ["$ptuDeployment"]},
            by_id["business-overview.json"][10]["targets"][0]["azureMonitor"]["dimensionFilters"],
        )

    def test_summary_tiles_sit_above_existing_panels_without_overlap(self):
        for name in ("openai-ptu.json", "foundry-agents.json", "business-overview.json"):
            panels = self.dashboards[name]["panels"]
            tiles = [item for item in panels if item["type"] == "stat"]
            others = [item for item in panels if item["type"] != "stat"]
            with self.subTest(dashboard=name):
                self.assertTrue(tiles)
                self.assertEqual({item["gridPos"]["y"] for item in tiles}, {0})
                self.assertEqual(min(item["gridPos"]["y"] for item in others), 4)
                for first, second in itertools.combinations(panels, 2):
                    a, b = first["gridPos"], second["gridPos"]
                    self.assertFalse(
                        a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"]
                        and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"],
                        f"{first['title']} overlaps {second['title']}",
                    )

    def test_dashboard_thresholds_mirror_the_default_alert_thresholds(self):
        terraform = (ROOT / "terraform" / "azure" / "variables.tf").read_text()
        bicep = (ROOT / "infra" / "main.bicep").read_text()

        def alert_default(variable, parameter):
            in_terraform = int(re.search(
                rf'variable "{variable}" \{{[^}}]*?default\s*=\s*(\d+)', terraform).group(1))
            in_bicep = int(re.search(rf"^param {parameter} int = (\d+)", bicep, re.MULTILINE).group(1))
            self.assertEqual(in_terraform, in_bicep)
            return in_terraform

        utilization = alert_default("ptu_utilization_threshold", "ptuUtilizationThreshold")
        failure = alert_default("agent_failure_rate_threshold_percent", "agentFailureRateThresholdPercent")
        latency = alert_default("agent_p95_latency_threshold_ms", "agentP95LatencyThresholdMs")
        utilization_steps = [("green", None), ("orange", utilization), ("red", 100)]
        failure_steps = [("green", None), ("orange", failure // 2), ("red", failure)]
        latency_steps = [("green", None), ("orange", latency // 2), ("red", latency)]

        def steps(thresholds):
            return [(step["color"], step["value"]) for step in thresholds["steps"]]

        by_id = {
            name: {item["id"]: item for item in self.dashboards[name]["panels"]}
            for name in ("openai-ptu.json", "foundry-agents.json", "business-overview.json")
        }
        for name, panel_id, expected, soft_max in (
            ("openai-ptu.json", 1, utilization_steps, 100),
            ("openai-ptu.json", 2, utilization_steps, 100),
            ("openai-ptu.json", 13, utilization_steps, None),
            ("business-overview.json", 2, utilization_steps, 100),
            ("business-overview.json", 9, utilization_steps, None),
            ("foundry-agents.json", 1, latency_steps, None),
            ("business-overview.json", 3, latency_steps, None),
            ("business-overview.json", 6, failure_steps, None),
            ("openai-ptu.json", 14, [("green", None), ("orange", 1)], None),
            ("business-overview.json", 10, [("green", None), ("orange", 1)], None),
        ):
            item = by_id[name][panel_id]
            defaults = item["fieldConfig"]["defaults"]
            with self.subTest(dashboard=name, panel=item["title"]):
                self.assertEqual(steps(defaults["thresholds"]), expected)
                if item["type"] == "timeseries":
                    # Time series draw thresholds only when a style is set.
                    self.assertEqual(defaults["custom"]["thresholdsStyle"], {"mode": "dashed"})
                    self.assertEqual(defaults["custom"].get("axisSoftMax"), soft_max)
        self.assertEqual(
            by_id["business-overview.json"][6]["fieldConfig"]["defaults"]["min"], 0)
        for tile in (by_id["foundry-agents.json"][9], by_id["business-overview.json"][8]):
            overrides = {
                entry["matcher"]["options"]: {prop["id"]: prop["value"] for prop in entry["properties"]}
                for entry in tile["fieldConfig"]["overrides"]
            }
            with self.subTest(tile=tile["id"]):
                self.assertEqual(steps(overrides["/^FailureRatePercent$/"]["thresholds"]), failure_steps)
                self.assertEqual(steps(overrides["/^P95_ms$/"]["thresholds"]), latency_steps)


if __name__ == "__main__":
    unittest.main()
