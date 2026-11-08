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
        "costGithubOidcSubject": {"value": "repo:example/observability:ref:refs/heads/main"},
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
                self.assertEqual(
                    resource["condition"], "[equals(parameters('collectorMode'), 'function')]"
                )
        conditional_roles = [
            item for item in resources
            if item["type"] == "Microsoft.Authorization/roleAssignments" and "condition" in item
        ]
        self.assertEqual(len(conditional_roles), 3)
        self.assertTrue(all(
            item["condition"] == "[equals(parameters('collectorMode'), 'function')]"
            for item in conditional_roles
        ))
        federation = next(
            item for item in resources
            if item["type"] == "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials"
        )
        self.assertEqual(federation["condition"], "[equals(parameters('collectorMode'), 'githubOidc')]")
        self.assertEqual(federation["properties"]["issuer"], "https://token.actions.githubusercontent.com")
        self.assertEqual(federation["properties"]["subject"], "[parameters('githubOidcSubject')]")
        self.assertEqual(federation["properties"]["audiences"], ["api://AzureADTokenExchange"])

    def run_harness(self, action, values=None, mode="new", endpoint=None, what_if=False, cost_dashboard=True):
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

    def test_github_oidc_requires_an_exact_main_branch_subject(self):
        for subject in (
            "repo:example/observability:ref:refs/heads/main",
            "repo:example@123/observability@456:ref:refs/heads/main",
        ):
            with self.subTest(subject=subject):
                values = parameters()
                values["costCollectorMode"] = {"value": "githubOidc"}
                values["costGithubOidcSubject"] = {"value": subject}
                result, _ = self.run_harness("validate", values)
                self.assertEqual(result.returncode, 0, result.stderr)
        for subject in ("", "repo:example/observability:environment:production",
                        "repo:example/observability:ref:refs/heads/feature"):
            with self.subTest(subject=subject):
                values = parameters()
                values["costCollectorMode"] = {"value": "githubOidc"}
                values["costGithubOidcSubject"] = {"value": subject}
                result, _ = self.run_harness("validate", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("costGithubOidcSubject", result.stderr)
                self.assertIn("main-branch", result.stderr)

        disabled = parameters()
        disabled["enableCostPipeline"] = {"value": False}
        disabled["costCollectorMode"] = {"value": "githubOidc"}
        disabled["costGithubOidcSubject"] = {"value": ""}
        result, _ = self.run_harness("validate", disabled)
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

    def test_function_mode_deploy_orchestrates_function_and_grafana_and_cleans_temporary_files(self):
        values = parameters()
        values["costCollectorMode"] = {"value": "function"}
        result, calls = self.run_harness("deploy", values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls["cli"][1][:3], ["deployment", "group", "create"])
        self.assertEqual(calls["cli"][2][:3], ["functionapp", "deployment", "source"])
        self.assertIn("host.json", calls["zipEntries"])
        self.assertIn("CollectCost/function.json", [name.replace("\\", "/") for name in calls["zipEntries"]])
        self.assertFalse(Path(calls["parameterTemp"]).exists())
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 5)

    def test_default_deploy_is_function_free_and_provisions_grafana(self):
        result, calls = self.run_harness("deploy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[0] == "functionapp" for command in calls["cli"]))
        self.assertEqual(calls["zipEntries"], [])
        self.assertFalse(Path(calls["parameterTemp"]).exists())
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 5)

    def test_explicit_github_oidc_deploy_provisions_grafana_without_publishing_a_function(self):
        values = parameters()
        values["costCollectorMode"] = {"value": "githubOidc"}
        values["costGithubOidcSubject"] = {"value": "repo:example/observability:ref:refs/heads/main"}
        result, calls = self.run_harness("deploy", values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[0] == "functionapp" for command in calls["cli"]))
        self.assertEqual(calls["zipEntries"], [])
        self.assertFalse(Path(calls["parameterTemp"]).exists())
        self.assertEqual(len([c for c in calls["http"] if c["path"] == "/api/dashboards/db"]), 5)

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
        self.assertEqual(template["parameters"]["costQueryScope"]["defaultValue"], "subscription")
        self.assertEqual(template["parameters"]["costCollectorMode"]["defaultValue"], "githubOidc")
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


if __name__ == "__main__":
    unittest.main()
