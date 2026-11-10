import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
AZ = shutil.which("az")
SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
OTHER_SUBSCRIPTION = "33333333-3333-3333-3333-333333333333"
INFINITY_SECRET = "test-secret-value"
INFINITY_CLIENT_ID = "66666666-6666-6666-6666-666666666666"
INFINITY_OBJECT_ID = "77777777-7777-7777-7777-777777777777"
ACCOUNT = {
    "subscriptionId": SUBSCRIPTION,
    "resourceGroup": "foundry-rg",
    "name": "foundry-account",
    "ptuDeployments": ["ptu-one"],
}


def parameters():
    return {
        "grafanaAdminObjectId": {"value": "22222222-2222-2222-2222-222222222222"},
        "notificationEmail": {"value": "alerts@customer.example"},
        "monitoredAccounts": {"value": [copy.deepcopy(ACCOUNT)]},
        "existingTelemetryWorkspaces": {"value": []},
        "enableCostPipeline": {"value": True},
        "costLookbackDays": {"value": 90},
        "monthlyAiCostBudgetAmount": {"value": 0},
    }


@unittest.skipUnless(PWSH, "PowerShell 7 is required to exercise Bicep deployment")
class BicepDeploymentTests(unittest.TestCase):
    @unittest.skipUnless(AZ, "Azure CLI with Bicep is required to inspect compiled cost resources")
    def test_cost_storage_has_soft_delete_and_blob_read_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "cost.json"
            result = subprocess.run(
                [
                    AZ, "bicep", "build", "--file", str(ROOT / "infra" / "modules" / "cost.bicep"),
                    "--outfile", str(output),
                ],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            template_resources = json.loads(output.read_text(encoding="utf-8"))["resources"]
        resources = list(template_resources.values()) if isinstance(template_resources, dict) else template_resources
        blob_service = next(item for item in resources if item["type"] == "Microsoft.Storage/storageAccounts/blobServices")
        policies = blob_service["properties"]
        self.assertEqual(policies["deleteRetentionPolicy"], {"enabled": True, "days": 7})
        self.assertEqual(policies["containerDeleteRetentionPolicy"], {"enabled": True, "days": 7})
        diagnostics = next(item for item in resources if item["type"] == "Microsoft.Insights/diagnosticSettings")
        self.assertIn(
            {"category": "StorageRead", "enabled": True},
            diagnostics["properties"]["logs"],
        )
        function_types = {
            "Microsoft.Storage/storageAccounts",
            "Microsoft.Storage/storageAccounts/blobServices",
            "Microsoft.Storage/storageAccounts/blobServices/containers",
            "Microsoft.Insights/diagnosticSettings",
            "Microsoft.Web/serverfarms",
            "Microsoft.Web/sites",
            "Microsoft.Web/sites/config",
            "Microsoft.Web/sites/basicPublishingCredentialsPolicies",
        }
        for resource in resources:
            if resource["type"] in function_types:
                self.assertNotIn("condition", resource)
        role_assignments = [
            item for item in resources if item["type"] == "Microsoft.Authorization/roleAssignments"
        ]
        self.assertTrue(role_assignments)
        self.assertFalse([item for item in role_assignments if "condition" in item])
        self.assertFalse([
            item for item in resources
            if item["type"] == "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials"
        ])

    def run_harness(self, action, values=None, mode="new", endpoint=None, what_if=False, cost_dashboard=True,
                    fail_function=False, cost_export=False, cost_export_uri=None, cost_infinity=False,
                    infinity_secret=None, plugin_missing=False, infinity_scope=None, infinity_alert=True,
                    alert_interval=None, alert_pending=None):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            parameter_data = parameters() if values is None else values
            parameter_file = directory / "parameters.json"
            parameter_file.write_text(json.dumps(parameter_data), encoding="utf-8")
            bicepparam = directory / "local.bicepparam"
            bicepparam.touch()
            bundle = directory / "bundle.json"
            bundle.write_text(json.dumps({
                "parametersJson": json.dumps({"parameters": parameter_data}),
                "templateJson": "{}",
            }), encoding="utf-8")
            log = directory / "calls.json"
            environment = os.environ.copy()
            environment.update({
                "TEST_ACTION": action,
                "TEST_MODE": mode,
                "TEST_ENDPOINT": endpoint or "https://test.eastus.grafana.azure.com",
                "TEST_PARAMETERS": str(parameter_file),
                "TEST_PARAMETER_FILE": str(bicepparam),
                "TEST_BUNDLE": str(bundle),
                "TEST_LOG": str(log),
                "TEST_WHAT_IF": str(what_if).lower(),
                "TEST_COST_DASHBOARD": str(cost_dashboard).lower(),
                "TEST_FAIL_FUNCTION": str(fail_function).lower(),
                "TEST_COST_EXPORT": str(cost_export).lower(),
                "TEST_COST_EXPORT_URI": cost_export_uri or "",
                "TEST_COST_INFINITY": str(cost_infinity).lower(),
                "TEST_PLUGIN_MISSING": str(plugin_missing).lower(),
                "TEST_INFINITY_SCOPE": infinity_scope or "",
                "TEST_INFINITY_ALERT": str(infinity_alert).lower(),
                "TEST_ALERT_INTERVAL": str(alert_interval or ""),
                "TEST_ALERT_PENDING": str(alert_pending if alert_pending is not None else ""),
                "TEST_INFINITY_SECRET_PARAMETER": str(infinity_secret == "parameter").lower(),
            })
            environment.pop("AI_OBSERVABILITY_COST_CLIENT_SECRET", None)
            if infinity_secret == "env":
                environment["AI_OBSERVABILITY_COST_CLIENT_SECRET"] = INFINITY_SECRET
            result = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "tests" / "bicep_harness.ps1")],
                env=environment, capture_output=True, text=True,
            )
            # PowerShell's error view wraps long messages at the terminal width, which differs by platform.
            result.stderr = re.sub(r"\s*\n(?:\s*\|)?\s*", " ", re.sub(r"\x1b\[[0-9;]*m", "", result.stderr))
            calls = json.loads(log.read_text(encoding="utf-8-sig"))
            return result, calls

    def test_cost_pacing_boundary_and_cross_subscription_validation(self):
        at_limit = parameters()
        at_limit["monitoredAccounts"]["value"] = [
            {**ACCOUNT, "name": f"account-{index}"} for index in range(14)
        ]
        result, _ = self.run_harness("validate", at_limit)
        self.assertEqual(result.returncode, 0, result.stderr)

        over_limit = copy.deepcopy(at_limit)
        over_limit["monitoredAccounts"]["value"].append({**ACCOUNT, "name": "account-14"})
        result, _ = self.run_harness("validate", over_limit)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("more than 30 minutes", result.stderr)

        cross = parameters()
        cross["monitoredAccounts"]["value"][0]["subscriptionId"] = OTHER_SUBSCRIPTION
        result, _ = self.run_harness("validate", cross)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("monitoring subscription", result.stderr)

        cross["enableCostPipeline"]["value"] = False
        result, _ = self.run_harness("validate", cross)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cost_export_requires_a_real_deployer_object_id(self):
        missing = parameters()
        missing["enableCostExport"] = {"value": True}
        result, _ = self.run_harness("validate", missing)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("costExportDeployerObjectId", result.stderr)

        missing["costExportDeployerObjectId"] = {"value": "44444444-4444-4444-4444-444444444444"}
        result, _ = self.run_harness("validate", missing)
        self.assertEqual(result.returncode, 0, result.stderr)

        disabled = parameters()
        result, _ = self.run_harness("validate", disabled)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_budget_workspace_duplicates_and_placeholders_fail(self):
        cases = []
        invalid_budget = parameters()
        invalid_budget["monthlyAiCostBudgetAmount"] = {"value": 100}
        invalid_budget["costBudgetStartDate"] = {"value": "2026-11-02T00:00:00Z"}
        invalid_budget["costBudgetEndDate"] = {"value": "2027-01-01T00:00:00Z"}
        cases.append((invalid_budget, "starting on the first"))
        workspace = parameters()
        workspace["dashboardTelemetryWorkspaceResourceId"] = {"value": "/subscriptions/missing"}
        cases.append((workspace, "existingTelemetryWorkspaces"))
        duplicate = parameters()
        duplicate["monitoredAccounts"]["value"].append(copy.deepcopy(ACCOUNT))
        cases.append((duplicate, "listed more than once"))
        placeholder = parameters()
        placeholder["grafanaAdminObjectId"] = {"value": "00000000-0000-0000-0000-000000000000"}
        cases.append((placeholder, "nonzero GUID"))
        invalid_prefix = parameters()
        invalid_prefix["namePrefix"] = {"value": "Invalid-Prefix"}
        cases.append((invalid_prefix, "namePrefix must"))
        invalid_scope = parameters()
        invalid_scope["costQueryScope"] = {"value": "invalid"}
        cases.append((invalid_scope, "costQueryScope must"))
        for values, expected in cases:
            with self.subTest(expected=expected):
                result, _ = self.run_harness("validate", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_resource_group_cost_scope_is_accepted_by_deployment_validation(self):
        for mode in ("resourceGroup", "resourceGroupManaged"):
            with self.subTest(mode=mode):
                scoped = parameters()
                scoped["costQueryScope"] = {"value": mode}
                result, _ = self.run_harness("validate", scoped)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_account_group_names_cannot_escape_managed_cost_scope(self):
        for group in (".", "..", "foundry%2fother", "foundry?other", "foundry#other", "foundry\\other", "foundry/other", "foundry\x01other"):
            with self.subTest(group=group):
                scoped = parameters()
                scoped["costQueryScope"] = {"value": "resourceGroupManaged"}
                scoped["monitoredAccounts"]["value"][0]["resourceGroup"] = group
                result, _ = self.run_harness("validate", scoped)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("resource group", result.stderr)

    def test_grafana_creates_dashboards_with_separate_workspace_defaults(self):
        result, calls = self.run_harness("grafana")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call["maximumRedirection"] == 0 for call in calls["http"]))
        posts = [call for call in calls["http"] if call["method"] == "Post"]
        self.assertEqual(len(posts), 6)
        source = posts[0]["body"]
        self.assertEqual(source["jsonData"]["azureAuthType"], "msi")
        self.assertEqual(source["jsonData"]["subscriptionId"], SUBSCRIPTION)
        dashboards = {call["body"]["dashboard"]["uid"]: call["body"] for call in posts[1:]}
        self.assertEqual(len(dashboards), 5)
        available_uids = set(dashboards)
        for body in dashboards.values():
            for link in body["dashboard"].get("links", []):
                self.assertIn(link["url"].split("/")[2], available_uids)
        for body in dashboards.values():
            self.assertFalse(body["overwrite"])
            self.assertIn("managed-by-azure-ai-observability-bicep", body["dashboard"]["tags"])
            self.assertNotIn("${DS_AZURE_MONITOR}", json.dumps(body))
        agent_vars = dashboards["foundry-agent-operations"]["dashboard"]["templating"]["list"]
        cost_vars = dashboards["azure-ai-costs"]["dashboard"]["templating"]["list"]
        business_vars = dashboards["azure-ai-business-overview"]["dashboard"]["templating"]["list"]
        self.assertIn("/resourceGroups/agents/", agent_vars[0]["current"]["value"])
        self.assertIn("/resourceGroups/monitoring/", cost_vars[0]["current"]["value"])
        business_defaults = {item["name"]: item["current"]["value"] for item in business_vars}
        self.assertIn("/resourceGroups/monitoring/", business_defaults["monitoringWorkspaceResourceId"])
        self.assertEqual(business_defaults["ptuAccount"], "foundry-account")
        self.assertEqual(business_defaults["ptuDeployment"], "ptu-one")

    def test_grafana_omits_links_to_optional_cost_dashboards_when_disabled(self):
        result, calls = self.run_harness("grafana", cost_dashboard=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        posts = [call for call in calls["http"] if call["method"] == "Post"]
        dashboards = {call["body"]["dashboard"]["uid"]: call["body"]["dashboard"] for call in posts[1:]}
        self.assertEqual(
            set(dashboards),
            {"foundry-overview", "foundry-agent-operations", "azure-openai-ptu"},
        )
        available_uids = set(dashboards)
        for dashboard in dashboards.values():
            for link in dashboard.get("links", []):
                self.assertIn(link["url"].split("/")[2], available_uids)

    def test_grafana_provisions_data_explorer_source_and_native_cost_dashboard(self):
        result, calls = self.run_harness("grafana", cost_export=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        posts = [call for call in calls["http"] if call["method"] == "Post"]
        sources = [call["body"] for call in posts if call["path"] == "/api/datasources"]
        self.assertEqual(len(sources), 2)
        adx = next(body for body in sources if body["type"] == "grafana-azure-data-explorer-datasource")
        self.assertEqual(adx["uid"], "ai-observability-azure-data-explorer")
        self.assertEqual(adx["jsonData"]["azureCredentials"], {"authType": "msi"})
        self.assertEqual(adx["jsonData"]["clusterUrl"], "https://adx.eastus.kusto.windows.net")
        self.assertEqual(adx["jsonData"]["defaultDatabase"], "costs")
        self.assertNotIn("password", json.dumps(adx).lower())
        dashboards = {
            call["body"]["dashboard"]["uid"]: call["body"]
            for call in posts if call["path"] == "/api/dashboards/db"
        }
        self.assertEqual(len(dashboards), 6)
        native = dashboards["azure-ai-costs-native"]
        self.assertNotIn("${DS_AZURE_DATA_EXPLORER}", json.dumps(native))
        self.assertIn("ai-observability-azure-data-explorer", json.dumps(native))

    def test_grafana_omits_data_explorer_by_default(self):
        result, calls = self.run_harness("grafana")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(
            call["body"] and call["body"].get("type") == "grafana-azure-data-explorer-datasource"
            for call in calls["http"] if call["path"] == "/api/datasources"
        ))
        self.assertFalse(any(
            call["body"]["dashboard"]["uid"] == "azure-ai-costs-native"
            for call in calls["http"] if call["path"] == "/api/dashboards/db"
        ))

    def test_grafana_updates_owned_data_explorer_source_and_rejects_unowned(self):
        result, calls = self.run_harness("grafana", mode="existing", cost_export=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        updates = [call for call in calls["http"] if call["method"] == "Put"]
        self.assertEqual(
            {call["path"] for call in updates},
            {
                "/api/datasources/uid/ai-observability-azure-monitor",
                "/api/datasources/uid/ai-observability-azure-data-explorer",
            },
        )
        adx_update = next(call for call in updates if call["path"].endswith("azure-data-explorer"))
        self.assertEqual(adx_update["body"]["version"], 3)

        result, calls = self.run_harness("grafana", mode="unmanaged-adx-source", cost_export=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not managed", result.stderr)
        self.assertFalse(any(call["method"] in ("Post", "Put") for call in calls["http"]))

    def test_grafana_rejects_untrusted_data_explorer_cluster_uri(self):
        for uri in (
            "http://adx.eastus.kusto.windows.net",
            "https://adx.eastus.kusto.windows.net.attacker.example",
            "https://adx.eastus.kusto.windows.net/path",
        ):
            with self.subTest(uri=uri):
                result, calls = self.run_harness("grafana", cost_export=True, cost_export_uri=uri)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("costExportClusterUri", result.stderr)
                self.assertEqual(calls["http"], [])

    def infinity_parameters(self, scope="subscription"):
        values = parameters()
        values["enableCostInfinity"] = {"value": True}
        values["costInfinityClientId"] = {"value": INFINITY_CLIENT_ID}
        values["costInfinityServicePrincipalObjectId"] = {"value": INFINITY_OBJECT_ID}
        values["costInfinityScope"] = {"value": scope}
        return values

    def test_infinity_requires_real_principal_ids_and_a_valid_scope(self):
        result, _ = self.run_harness("validate", self.infinity_parameters())
        self.assertEqual(result.returncode, 0, result.stderr)

        for name in ("costInfinityClientId", "costInfinityServicePrincipalObjectId"):
            with self.subTest(name=name):
                for bad in ("", "not-a-guid", "00000000-0000-0000-0000-000000000000"):
                    values = self.infinity_parameters()
                    values[name] = {"value": bad}
                    result, _ = self.run_harness("validate", values)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)

        bad_scope = self.infinity_parameters("resourceGroup")
        result, _ = self.run_harness("validate", bad_scope)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("costInfinityScope", result.stderr)

        disabled = parameters()
        result, _ = self.run_harness("validate", disabled)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_infinity_resource_group_scope_needs_monitored_accounts_in_this_subscription(self):
        ok = self.infinity_parameters("resourceGroupManaged")
        result, _ = self.run_harness("validate", ok)
        self.assertEqual(result.returncode, 0, result.stderr)

        none = self.infinity_parameters("resourceGroupManaged")
        none["monitoredAccounts"]["value"] = []
        result, _ = self.run_harness("validate", none)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("monitored account", result.stderr)

        cross = self.infinity_parameters("resourceGroupManaged")
        cross["monitoredAccounts"]["value"][0]["subscriptionId"] = OTHER_SUBSCRIPTION
        cross["enableCostPipeline"]["value"] = False
        result, _ = self.run_harness("validate", cross)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("monitoring subscription", result.stderr)

    def test_grafana_provisions_infinity_source_with_the_secret_only_in_secure_data(self):
        for how in ("env", "parameter"):
            with self.subTest(secret=how):
                result, calls = self.run_harness("grafana", cost_infinity=True, infinity_secret=how)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(INFINITY_SECRET, result.stdout + result.stderr)
                posts = [call for call in calls["http"] if call["method"] == "Post"]
                sources = [call["body"] for call in posts if call["path"] == "/api/datasources"]
                infinity = next(body for body in sources if body["type"] == "yesoreyeram-infinity-datasource")
                self.assertEqual(infinity["uid"], "ai-observability-cost-infinity")
                self.assertEqual(infinity["jsonData"]["auth_method"], "oauth2")
                self.assertFalse(infinity["jsonData"]["oauthPassThru"])
                self.assertEqual(infinity["jsonData"]["allowedHosts"], ["https://management.azure.com"])
                self.assertEqual(infinity["jsonData"]["oauth2"]["oauth2_type"], "client_credentials")
                self.assertEqual(infinity["jsonData"]["oauth2"]["client_id"], INFINITY_CLIENT_ID)
                self.assertEqual(
                    infinity["jsonData"]["oauth2"]["token_url"],
                    "https://login.microsoftonline.com/55555555-5555-5555-5555-555555555555/oauth2/token",
                )
                self.assertEqual(infinity["secureJsonData"]["oauth2ClientSecret"], INFINITY_SECRET)
                self.assertNotIn(INFINITY_SECRET, json.dumps(infinity["jsonData"]))
                for call in calls["http"]:
                    if call["body"] is not None and call["path"] != "/api/datasources":
                        self.assertNotIn(INFINITY_SECRET, json.dumps(call["body"]))
                dashboards = {
                    call["body"]["dashboard"]["uid"]: call["body"]["dashboard"]
                    for call in posts if call["path"] == "/api/dashboards/db"
                }
                self.assertEqual(len(dashboards), 6)
                dashboard = dashboards["azure-ai-costs-infinity"]
                self.assertNotIn("${DS_COST_INFINITY}", json.dumps(dashboard))
                self.assertIn("ai-observability-cost-infinity", json.dumps(dashboard))
                scope = next(item for item in dashboard["templating"]["list"] if item["name"] == "costScope")
                self.assertEqual(scope["current"]["value"], f"/subscriptions/{SUBSCRIPTION}")

    def test_grafana_scopes_the_infinity_dashboard_to_the_configured_resource_group(self):
        scope = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/foundry-rg"
        result, calls = self.run_harness(
            "grafana", cost_infinity=True, infinity_secret="env", infinity_scope=scope,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        dashboard = next(
            call["body"]["dashboard"] for call in calls["http"]
            if call["path"] == "/api/dashboards/db" and call["body"]["dashboard"]["uid"] == "azure-ai-costs-infinity"
        )
        variable = next(item for item in dashboard["templating"]["list"] if item["name"] == "costScope")
        self.assertEqual(variable["current"]["value"], scope)

    def test_grafana_rejects_an_untrusted_infinity_scope(self):
        for scope in (
            "/subscriptions/not-a-guid",
            f"/subscriptions/{SUBSCRIPTION}/providers/Microsoft.Authorization",
            f"/subscriptions/{SUBSCRIPTION}/resourceGroups/a/../b",
        ):
            with self.subTest(scope=scope):
                result, calls = self.run_harness(
                    "grafana", cost_infinity=True, infinity_secret="env", infinity_scope=scope,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("costInfinityScope", result.stderr)
                self.assertEqual(calls["http"], [])

    def test_grafana_requires_the_infinity_secret_and_plugin_before_changing_anything(self):
        result, calls = self.run_harness("grafana", cost_infinity=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("client secret", result.stderr)
        self.assertEqual(calls["http"], [])

        result, calls = self.run_harness("grafana", cost_infinity=True, infinity_secret="env", plugin_missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not installed", result.stderr)
        self.assertNotIn(INFINITY_SECRET, result.stdout + result.stderr)
        self.assertFalse(any(call["method"] in ("Post", "Put") for call in calls["http"]))

    def test_grafana_rotates_an_owned_infinity_source_and_rejects_an_unowned_one(self):
        result, calls = self.run_harness("grafana", mode="existing", cost_infinity=True, infinity_secret="env")
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(
            call for call in calls["http"]
            if call["method"] == "Put" and call["path"].endswith("ai-observability-cost-infinity")
        )
        self.assertEqual(update["body"]["version"], 2)
        self.assertEqual(update["body"]["secureJsonData"]["oauth2ClientSecret"], INFINITY_SECRET)

        result, calls = self.run_harness(
            "grafana", mode="unmanaged-infinity-source", cost_infinity=True, infinity_secret="env",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not managed", result.stderr)
        self.assertFalse(any(call["method"] in ("Post", "Put") for call in calls["http"]))

    def alert_group_calls(self, calls):
        return [
            call for call in calls["http"]
            if call["method"] == "Put" and "/rule-groups/" in call["path"]
        ]

    def test_grafana_creates_the_infinity_alert_from_the_dashboards_query(self):
        scope = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/foundry-rg"
        result, calls = self.run_harness(
            "grafana", cost_infinity=True, infinity_secret="env", infinity_scope=scope,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(INFINITY_SECRET, result.stdout + result.stderr)
        folders = [call for call in calls["http"] if call["method"] == "Post" and call["path"] == "/api/folders"]
        self.assertEqual([call["body"]["uid"] for call in folders], ["ai-observability-alerts"])
        puts = self.alert_group_calls(calls)
        self.assertEqual(len(puts), 1)
        self.assertEqual(
            puts[0]["path"],
            "/api/v1/provisioning/folder/ai-observability-alerts/rule-groups/Infinity%20cost%20data%20source",
        )
        group = puts[0]["body"]
        self.assertEqual(group["interval"], 3600)
        self.assertEqual(group["folderUid"], "ai-observability-alerts")
        rule = group["rules"][0]
        self.assertEqual(len(group["rules"]), 1)
        self.assertEqual(rule["condition"], "C")
        self.assertEqual(rule["execErrState"], "Alerting")
        self.assertEqual(rule["noDataState"], "OK")
        self.assertEqual(rule["for"], "60m")
        self.assertEqual(rule["labels"]["component"], "cost-infinity")
        self.assertEqual(rule["labels"]["managed_by"], "azure-ai-observability-bicep-v1")
        self.assertEqual([item["refId"] for item in rule["data"]], ["A", "B", "C"])
        query = rule["data"][0]
        self.assertEqual(query["datasourceUid"], "ai-observability-cost-infinity")
        self.assertEqual(query["model"]["parser"], "jq-backend")
        self.assertEqual(
            query["model"]["url"],
            f"https://management.azure.com{scope}/providers/Microsoft.CostManagement/query?api-version=2023-11-01",
        )
        self.assertEqual(query["model"]["url_options"]["method"], "POST")
        self.assertIn("microsoft.cognitiveservices/accounts", query["model"]["url_options"]["data"])
        self.assertNotIn("costScope", json.dumps(query["model"]))
        threshold = rule["data"][2]["model"]["conditions"][0]["evaluator"]
        self.assertEqual(threshold["type"], "gt")
        self.assertGreaterEqual(threshold["params"][0], 1_000_000_000)
        self.assertNotIn(INFINITY_SECRET, json.dumps(group))
        order = [(call["method"], call["path"]) for call in calls["http"] if call["method"] in ("Post", "Put")]
        datasource = order.index(("Post", "/api/datasources"))
        self.assertLess(datasource, order.index(("Post", "/api/folders")))
        self.assertLess(
            max(index for index, item in enumerate(order) if item[1] == "/api/dashboards/db"),
            order.index(("Post", "/api/folders")),
        )

    def test_grafana_updates_an_owned_alert_group_in_place_and_rejects_an_unowned_one(self):
        result, calls = self.run_harness("grafana", mode="existing", cost_infinity=True, infinity_secret="env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call["method"] == "Post" and call["path"] == "/api/folders" for call in calls["http"]))
        puts = self.alert_group_calls(calls)
        self.assertEqual(len(puts), 1)
        self.assertEqual(puts[0]["body"]["rules"][0]["uid"], "ai-observability-infinity-cost")

        result, calls = self.run_harness(
            "grafana", mode="unmanaged-alert-group", cost_infinity=True, infinity_secret="env",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not managed", result.stderr)
        self.assertIn("alert rule group", result.stderr)
        self.assertFalse(any(call["method"] in ("Post", "Put") for call in calls["http"]))

    def test_grafana_alert_can_be_disabled_and_follows_the_configured_timing(self):
        result, calls = self.run_harness("grafana", cost_infinity=True, infinity_secret="env", infinity_alert=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.alert_group_calls(calls), [])
        self.assertFalse(any(call["path"] == "/api/folders" or call["path"].startswith("/api/v1/provisioning") for call in calls["http"]))
        self.assertTrue(any(call["path"] == "/api/datasources" for call in calls["http"]))

        result, calls = self.run_harness(
            "grafana", cost_infinity=True, infinity_secret="env", alert_interval=120, alert_pending=0,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        group = self.alert_group_calls(calls)[0]["body"]
        self.assertEqual(group["interval"], 7200)
        self.assertEqual(group["rules"][0]["for"], "0m")

    def test_grafana_rejects_unreasonable_alert_timing_before_changing_anything(self):
        for name, interval, pending in (("interval", 1, None), ("interval", 2000, None), ("pending", None, -1), ("pending", None, "soon")):
            with self.subTest(setting=name, interval=interval, pending=pending):
                result, calls = self.run_harness(
                    "grafana", cost_infinity=True, infinity_secret="env",
                    alert_interval=interval, alert_pending=pending,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("costInfinityAlert", result.stderr)
                self.assertEqual(calls["http"], [])

    def test_grafana_omits_infinity_by_default(self):
        result, calls = self.run_harness("grafana", infinity_secret="env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.alert_group_calls(calls), [])
        self.assertFalse(any(call["path"] == "/api/folders" for call in calls["http"]))
        self.assertFalse(any(
            call["body"] and call["body"].get("type") == "yesoreyeram-infinity-datasource"
            for call in calls["http"] if call["path"] == "/api/datasources"
        ))
        self.assertFalse(any(call["path"].startswith("/api/plugins/") for call in calls["http"]))
        self.assertFalse(any(
            call["body"]["dashboard"]["uid"] == "azure-ai-costs-infinity"
            for call in calls["http"] if call["path"] == "/api/dashboards/db"
        ))

    def test_deploy_stops_before_azure_when_the_infinity_secret_is_missing(self):
        result, calls = self.run_harness("deploy", self.infinity_parameters())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("client secret", result.stderr)
        self.assertFalse(any(command[0] == "deployment" for command in calls["cli"]))
        self.assertEqual(calls["http"], [])

    def test_deploy_passes_the_infinity_secret_to_grafana_provisioning(self):
        values = self.infinity_parameters()
        values["enableCostPipeline"]["value"] = False
        result, calls = self.run_harness(
            "deploy", values, cost_infinity=True, infinity_secret="parameter",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(INFINITY_SECRET, result.stdout + result.stderr)
        self.assertFalse(INFINITY_SECRET in json.dumps(calls["cli"]))
        infinity = next(
            call["body"] for call in calls["http"]
            if call["path"] == "/api/datasources" and call["body"]["type"] == "yesoreyeram-infinity-datasource"
        )
        self.assertEqual(infinity["secureJsonData"]["oauth2ClientSecret"], INFINITY_SECRET)
        self.assertFalse(Path(calls["parameterTemp"]).exists())

    def test_what_if_does_not_need_the_infinity_secret(self):
        result, calls = self.run_harness("deploy", self.infinity_parameters(), what_if=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["http"], [])

    def test_grafana_updates_owned_resources_with_versions(self):
        result, calls = self.run_harness("grafana", mode="existing")
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(call for call in calls["http"] if call["method"] == "Put")
        self.assertEqual(update["body"]["version"], 7)
        dashboards = [call["body"] for call in calls["http"] if call["path"] == "/api/dashboards/db"]
        self.assertEqual(len(dashboards), 5)
        for body in dashboards:
            self.assertEqual(body["dashboard"]["version"], 12)
            self.assertEqual(body["dashboard"]["id"], 10)
            self.assertEqual(body["folderUid"], "my-folder")
            self.assertFalse(body["overwrite"])

    def test_grafana_rejects_unmanaged_resources_auth_errors_and_redirects(self):
        for mode, expected in [
            ("unmanaged-source", "not managed"),
            ("unmanaged-dashboard", "not managed"),
            ("missing-dashboard-tags", "not managed"),
            ("denied", "Grafana Admin"),
            ("redirect", "redirects"),
        ]:
            with self.subTest(mode=mode):
                result, calls = self.run_harness("grafana", mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertFalse(any(call["method"] in ("Post", "Put") for call in calls["http"]))
                self.assertNotIn("fake-grafana-token", result.stderr + result.stdout)
        result, _ = self.run_harness("grafana", mode="version-conflict")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version conflicted", result.stderr)

    def test_grafana_rejects_untrusted_endpoint_before_token_acquisition(self):
        for endpoint in [
            "http://test.eastus.grafana.azure.com",
            "https://test.grafana.azure.com.attacker.example",
            "https://user@test.grafana.azure.com",
            "https://test.grafana.azure.com:444",
            "https://test.grafana.azure.com/some/path",
        ]:
            with self.subTest(endpoint=endpoint):
                result, calls = self.run_harness("grafana", endpoint=endpoint)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Grafana endpoint must", result.stderr)
                self.assertEqual(calls["cli"], [])
                self.assertEqual(calls["http"], [])

    def test_deploy_publishes_function_and_provisions_grafana_and_cleans_temporary_files(self):
        result, calls = self.run_harness("deploy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["cli"][1][:3], ["deployment", "group", "create"])
        commands = [command[:3] for command in calls["cli"]]
        publish = commands.index(["functionapp", "deployment", "source"])
        self.assertLess(commands.index(["account", "get-access-token", "--subscription"]), publish)
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 5)
        self.assertIn("host.json", calls["zipEntries"])
        self.assertIn("CollectCost/function.json", [name.replace("\\", "/") for name in calls["zipEntries"]])
        self.assertFalse(Path(calls["parameterTemp"]).exists())

    def test_function_publish_failure_still_provisions_grafana(self):
        result, calls = self.run_harness("deploy", fail_function=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 5)
        self.assertFalse(Path(calls["parameterTemp"]).exists())

    def test_deploy_without_cost_pipeline_publishes_no_function(self):
        values = parameters()
        values["enableCostPipeline"] = {"value": False}
        result, calls = self.run_harness("deploy", values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[0] == "functionapp" for command in calls["cli"]))
        self.assertEqual(calls["zipEntries"], [])
        self.assertFalse(Path(calls["parameterTemp"]).exists())
    def test_what_if_performs_no_publishing_or_grafana_changes(self):
        result, calls = self.run_harness("deploy", what_if=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["cli"][1][:3], ["deployment", "group", "what-if"])
        self.assertEqual(len(calls["cli"]), 2)
        self.assertEqual(calls["http"], [])
        self.assertFalse(Path(calls["parameterTemp"]).exists())


class CostExportKqlTests(unittest.TestCase):
    def test_external_tables_ignore_the_export_manifest(self):
        kql = (ROOT / "infra" / "kusto" / "cost-export.kql").read_text(encoding="utf-8")
        tables = kql.count(".create-or-alter external table")
        self.assertEqual(tables, 2)
        self.assertEqual(kql.count("fileExtension='.csv'"), tables)


@unittest.skipUnless(AZ, "Azure CLI with Bicep is required to inspect compiled templates")
class BicepTemplateTests(unittest.TestCase):
    def test_compiled_template_contains_cost_and_access_resources(self):
        def resources_of(template):
            resources = template["resources"]
            return list(resources.values()) if isinstance(resources, dict) else resources

        result = subprocess.run(
            [AZ, "bicep", "build", "--file", str(ROOT / "infra" / "main.bicep"), "--stdout"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        template = json.loads(result.stdout)
        self.assertEqual(template["parameters"]["grafanaMajorVersion"]["defaultValue"], "12")
        self.assertEqual(template["parameters"]["costQueryScope"]["defaultValue"], "subscription")
        self.assertNotIn("costCollectorMode", template["parameters"])
        self.assertNotIn("costGithubOidcSubject", template["parameters"])
        self.assertNotIn("costCollectorConfiguration", template["outputs"])
        self.assertEqual(
            template["parameters"]["costQueryScope"]["allowedValues"],
            ["subscription", "resourceGroup", "resourceGroupManaged"],
        )
        self.assertIn("costIdentityPrincipalId", template["outputs"])
        resources = resources_of(template)
        self.assertTrue(any(r["type"].lower() == "microsoft.insights/scheduledqueryrules" for r in resources))
        nested = [r["properties"]["template"] for r in resources
                  if r["type"].lower() == "microsoft.resources/deployments"]
        cost_template = next(t for t in nested if any(
            r["type"].lower() == "microsoft.web/sites" for r in resources_of(t)
        ))
        cost_deployment = next(r for r in resources
                               if r["type"].lower() == "microsoft.resources/deployments"
                               and r["properties"]["template"] == cost_template)
        self.assertEqual(
            cost_deployment["properties"]["parameters"]["costQueryScope"],
            "[if(equals(parameters('costQueryScope'), 'resourceGroupManaged'), createObject('value', 'resourceGroup'), createObject('value', parameters('costQueryScope')))]",
        )
        cost_reader = next(r for r in resources
                           if r["type"].lower() == "microsoft.resources/deployments"
                           and "-cost-reader" in r["name"])
        self.assertEqual(
            cost_reader["condition"],
            "[and(parameters('enableCostPipeline'), equals(parameters('costQueryScope'), 'subscription'))]",
        )
        self.assertEqual(cost_reader["subscriptionId"], "[subscription().subscriptionId]")
        self.assertEqual(
            cost_reader["properties"]["parameters"]["principalId"]["value"],
            "[reference('cost').outputs.principalId.value]",
        )
        cost_group_reader = next(r for r in resources
                                 if r["type"].lower() == "microsoft.resources/deployments"
                                 and "-cost-rg-" in r["name"])
        self.assertEqual(cost_group_reader["copy"]["count"], "[length(variables('costAccountGroups'))]")
        self.assertEqual(
            template["variables"]["costAccountGroups"],
            "[union(variables('costAccountGroupTargets'), createArray())]",
        )
        self.assertIn("resourceGroupManaged", cost_group_reader["condition"])
        subscription_guard = cost_group_reader["properties"]["parameters"]["subscriptionMatches"]["value"]
        self.assertIn("subscriptionId", subscription_guard)
        self.assertEqual(
            cost_group_reader["properties"]["parameters"]["principalId"]["value"],
            "[reference('cost').outputs.principalId.value]",
        )
        group_template = cost_group_reader["properties"]["template"]
        self.assertEqual(group_template["parameters"]["scopeIsValid"]["allowedValues"], [True])
        scope_guard = group_template["parameters"]["scopeIsValid"]["defaultValue"]
        self.assertIn("createArray('.', '..')", scope_guard)
        self.assertIn("'%'", scope_guard)
        self.assertIn("'?'", scope_guard)
        self.assertIn("'#'", scope_guard)
        self.assertIn("uriComponent", scope_guard)
        self.assertIn("'%0'", scope_guard)
        self.assertIn("'%1'", scope_guard)
        self.assertIn("'%7F'", scope_guard)
        group_resources = resources_of(group_template)
        group_role = next(r for r in group_resources
                          if r["type"].lower() == "microsoft.authorization/roledefinitions")
        self.assertEqual(group_role["properties"]["assignableScopes"], ["[variables('groupScope')]"])
        self.assertEqual(group_role["properties"]["permissions"], [{
            "actions": ["Microsoft.CostManagement/query/read"],
            "notActions": [],
            "dataActions": [],
            "notDataActions": [],
        }])
        group_assignment_deployment = next(r for r in group_resources
                                           if r["type"].lower() == "microsoft.resources/deployments")
        self.assertEqual(group_assignment_deployment["resourceGroup"], "[parameters('resourceGroupName')]")
        group_assignment = resources_of(group_assignment_deployment["properties"]["template"])[0]
        self.assertEqual(group_assignment["type"].lower(), "microsoft.authorization/roleassignments")
        self.assertEqual(group_assignment["properties"]["principalId"], "[parameters('principalId')]")
        self.assertEqual(group_assignment["properties"]["principalType"], "ServicePrincipal")
        self.assertEqual(group_assignment["properties"]["roleDefinitionId"], "[parameters('roleDefinitionId')]")
        cost_resources = resources_of(cost_template)
        app = next(r for r in cost_resources if r["type"].lower() == "microsoft.web/sites")
        config = app["properties"]["functionAppConfig"]
        self.assertEqual(config["runtime"], {"name": "powershell", "version": "7.6"})
        self.assertEqual(config["scaleAndConcurrency"]["maximumInstanceCount"], 40)
        self.assertEqual(config["deployment"]["storage"]["authentication"]["type"], "UserAssignedIdentity")
        app_settings = next(r for r in cost_resources if r["type"].lower() == "microsoft.web/sites/config")
        self.assertEqual(app_settings["properties"]["COST_QUERY_SCOPE"], "[parameters('costQueryScope')]")
        self.assertTrue(any(r["type"].lower() == "microsoft.operationalinsights/workspaces/tables" for r in cost_resources))
        budget_template = next(t for t in nested if any(
            r["type"].lower() == "microsoft.consumption/budgets" for r in resources_of(t)
        ))
        budget = next(r for r in resources_of(budget_template) if r["type"].lower() == "microsoft.consumption/budgets")
        self.assertEqual(budget["properties"]["filter"]["dimensions"]["name"], "ResourceId")

    def test_cost_export_grafana_access_is_opt_in_and_private_only_closes_the_cluster(self):
        result = subprocess.run(
            [AZ, "bicep", "build", "--file", str(ROOT / "infra" / "modules" / "cost-export.bicep"), "--stdout"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        template = json.loads(result.stdout)
        access = template["parameters"]["grafanaAccess"]
        self.assertEqual(access["defaultValue"], "public")
        self.assertEqual(access["allowedValues"], ["public", "privateEndpoint", "privateOnly"])
        resources = template["resources"]
        resources = list(resources.values()) if isinstance(resources, dict) else resources
        endpoint = next(r for r in resources
                        if r["type"].lower() == "microsoft.dashboard/grafana/managedprivateendpoints")
        self.assertEqual(endpoint["condition"], "[not(equals(parameters('grafanaAccess'), 'public'))]")
        self.assertEqual(endpoint["properties"]["groupIds"], ["cluster"])
        cluster = next(r for r in resources if r["type"].lower() == "microsoft.kusto/clusters")
        self.assertEqual(
            cluster["properties"]["publicNetworkAccess"],
            "[if(equals(parameters('grafanaAccess'), 'privateOnly'), 'Disabled', 'Enabled')]",
        )
    def test_infinity_is_opt_in_installs_the_plugin_and_grants_only_cost_query(self):
        result = subprocess.run(
            [AZ, "bicep", "build", "--file", str(ROOT / "infra" / "main.bicep"), "--stdout"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        template = json.loads(result.stdout)
        parameters_ = template["parameters"]
        self.assertFalse(parameters_["enableCostInfinity"]["defaultValue"])
        self.assertEqual(parameters_["costInfinityScope"]["allowedValues"], ["subscription", "resourceGroupManaged"])
        self.assertFalse(any("secret" in name.lower() for name in parameters_), "the client secret must never be a template parameter")
        self.assertEqual(parameters_["costInfinityConfigured"]["allowedValues"], [True])
        resources = template["resources"]
        resources = list(resources.values()) if isinstance(resources, dict) else resources
        grafana = next(r for r in resources if r["type"].lower() == "microsoft.dashboard/grafana")
        self.assertEqual(
            grafana["properties"]["grafanaPlugins"],
            "[if(parameters('enableCostInfinity'), createObject('yesoreyeram-infinity-datasource', createObject()), null())]",
        )
        deployments = [r for r in resources if r["type"].lower() == "microsoft.resources/deployments"]
        reader = next(r for r in deployments if "-cost-infinity-reader" in r["name"])
        self.assertEqual(
            reader["condition"],
            "[and(parameters('enableCostInfinity'), equals(parameters('costInfinityScope'), 'subscription'))]",
        )
        self.assertEqual(
            reader["properties"]["parameters"]["principalId"]["value"],
            "[parameters('costInfinityServicePrincipalObjectId')]",
        )
        group = next(r for r in deployments if "-cost-infinity-rg-" in r["name"])
        self.assertEqual(group["properties"]["parameters"]["roleLabel"]["value"], "infinity-cost")
        self.assertIn("resourceGroupManaged", group["condition"])
        for output in ("enableCostInfinityDashboard", "costInfinityTenantId", "costInfinityClientId", "costInfinityScope"):
            self.assertIn(output, template["outputs"]["dashboardConfiguration"]["value"])
        self.assertTrue(parameters_["enableCostInfinityAlert"]["defaultValue"])
        self.assertEqual(parameters_["costInfinityAlertIntervalMinutes"]["defaultValue"], 60)
        self.assertEqual(parameters_["costInfinityAlertIntervalMinutes"]["minValue"], 5)
        self.assertEqual(parameters_["costInfinityAlertPendingMinutes"]["defaultValue"], 60)
        configuration = template["outputs"]["dashboardConfiguration"]["value"]
        self.assertEqual(
            configuration["enableCostInfinityAlert"],
            "[and(parameters('enableCostInfinity'), parameters('enableCostInfinityAlert'))]",
        )
        self.assertEqual(configuration["costInfinityAlertIntervalMinutes"], "[parameters('costInfinityAlertIntervalMinutes')]")
        self.assertEqual(configuration["costInfinityAlertPendingMinutes"], "[parameters('costInfinityAlertPendingMinutes')]")
        self.assertNotIn("secret", json.dumps(template["outputs"]).lower())

    def test_default_group_cost_role_names_are_unchanged_by_the_role_label(self):
        result = subprocess.run(
            [AZ, "bicep", "build", "--file", str(ROOT / "infra" / "modules" / "cost-group-reader.bicep"), "--stdout"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        template = json.loads(result.stdout)
        self.assertEqual(template["parameters"]["roleLabel"]["defaultValue"], "cost-query")
        role = next(
            r for r in (template["resources"].values() if isinstance(template["resources"], dict) else template["resources"])
            if r["type"].lower() == "microsoft.authorization/roledefinitions"
        )
        self.assertIn("variables('roleKey')", role["properties"]["roleName"])
        self.assertIn("parameters('roleLabel')", role["name"])
        self.assertIn("uniqueString(subscription().id, variables('groupScope'), parameters('stackResourceGroupId'), parameters('namePrefix'))", template["variables"]["roleKey"])


if __name__ == "__main__":
    unittest.main()
