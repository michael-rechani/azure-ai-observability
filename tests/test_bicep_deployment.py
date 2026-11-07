import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
AZ = shutil.which("az")
SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
OTHER_SUBSCRIPTION = "33333333-3333-3333-3333-333333333333"
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
    def run_harness(self, action, values=None, mode="new", endpoint=None, what_if=False):
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
            })
            result = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "tests" / "bicep_harness.ps1")],
                env=environment, capture_output=True, text=True,
            )
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
        for values, expected in cases:
            with self.subTest(expected=expected):
                result, _ = self.run_harness("validate", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_grafana_creates_dashboards_with_separate_workspace_defaults(self):
        result, calls = self.run_harness("grafana")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call["maximumRedirection"] == 0 for call in calls["http"]))
        posts = [call for call in calls["http"] if call["method"] == "Post"]
        self.assertEqual(len(posts), 5)
        source = posts[0]["body"]
        self.assertEqual(source["jsonData"]["azureAuthType"], "msi")
        self.assertEqual(source["jsonData"]["subscriptionId"], SUBSCRIPTION)
        dashboards = {call["body"]["dashboard"]["uid"]: call["body"] for call in posts[1:]}
        self.assertEqual(len(dashboards), 4)
        for body in dashboards.values():
            self.assertFalse(body["overwrite"])
            self.assertIn("managed-by-azure-ai-observability-bicep", body["dashboard"]["tags"])
            self.assertNotIn("${DS_AZURE_MONITOR}", json.dumps(body))
        agent_vars = dashboards["foundry-agent-operations"]["dashboard"]["templating"]["list"]
        cost_vars = dashboards["azure-ai-costs"]["dashboard"]["templating"]["list"]
        self.assertIn("/resourceGroups/agents/", agent_vars[0]["current"]["value"])
        self.assertIn("/resourceGroups/monitoring/", cost_vars[0]["current"]["value"])

    def test_grafana_updates_owned_resources_with_versions(self):
        result, calls = self.run_harness("grafana", mode="existing")
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(call for call in calls["http"] if call["method"] == "Put")
        self.assertEqual(update["body"]["version"], 7)
        dashboards = [call["body"] for call in calls["http"] if call["path"] == "/api/dashboards/db"]
        self.assertEqual(len(dashboards), 4)
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

    def test_deploy_orchestrates_function_and_grafana_and_cleans_temporary_files(self):
        result, calls = self.run_harness("deploy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["cli"][1][:3], ["deployment", "group", "create"])
        self.assertEqual(calls["cli"][2][:3], ["functionapp", "deployment", "source"])
        self.assertIn("host.json", calls["zipEntries"])
        self.assertIn("CollectCost/function.json", [name.replace("\\", "/") for name in calls["zipEntries"]])
        self.assertFalse(Path(calls["parameterTemp"]).exists())
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 4)

    def test_what_if_performs_no_publishing_or_grafana_changes(self):
        result, calls = self.run_harness("deploy", what_if=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["cli"][1][:3], ["deployment", "group", "what-if"])
        self.assertEqual(len(calls["cli"]), 2)
        self.assertEqual(calls["http"], [])
        self.assertFalse(Path(calls["parameterTemp"]).exists())


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
        resources = resources_of(template)
        self.assertTrue(any(r["type"].lower() == "microsoft.insights/scheduledqueryrules" for r in resources))
        nested = [r["properties"]["template"] for r in resources
                  if r["type"].lower() == "microsoft.resources/deployments"]
        cost_template = next(t for t in nested if any(
            r["type"].lower() == "microsoft.web/sites" for r in resources_of(t)
        ))
        cost_resources = resources_of(cost_template)
        app = next(r for r in cost_resources if r["type"].lower() == "microsoft.web/sites")
        config = app["properties"]["functionAppConfig"]
        self.assertEqual(config["runtime"], {"name": "powershell", "version": "7.6"})
        self.assertEqual(config["scaleAndConcurrency"]["maximumInstanceCount"], 40)
        self.assertEqual(config["deployment"]["storage"]["authentication"]["type"], "UserAssignedIdentity")
        self.assertTrue(any(r["type"].lower() == "microsoft.operationalinsights/workspaces/tables" for r in cost_resources))
        budget_template = next(t for t in nested if any(
            r["type"].lower() == "microsoft.consumption/budgets" for r in resources_of(t)
        ))
        budget = next(r for r in resources_of(budget_template) if r["type"].lower() == "microsoft.consumption/budgets")
        self.assertEqual(budget["properties"]["filter"]["dimensions"]["name"], "ResourceId")


if __name__ == "__main__":
    unittest.main()
