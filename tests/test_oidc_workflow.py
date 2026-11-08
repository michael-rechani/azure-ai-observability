from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class OidcWorkflowTests(unittest.TestCase):
    def test_cost_workflow_is_opt_in_main_only_and_secretless(self):
        workflow = (ROOT / ".github" / "workflows" / "collect-cost.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("cron: '17 6 * * *'", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("vars.COST_COLLECTOR_ENABLED == 'true'", workflow)
        self.assertIn("timeout-minutes: 50", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("allow-no-subscriptions: true", workflow)
        self.assertNotIn("subscription-id:", workflow)
        self.assertNotIn("environment:", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("scripts\\run_cost_github.ps1", workflow)
        for action_ref in re.findall(r"(?m)^\s+- uses: ([^#\s]+)", workflow):
            self.assertRegex(action_ref, r"@[0-9a-f]{40}$")

    def test_bicep_workflow_is_manual_and_protected(self):
        workflow = (ROOT / ".github" / "workflows" / "deploy-bicep.yml").read_text(
            encoding="utf-8"
        )

        triggers = workflow.split("permissions:", maxsplit=1)[0]
        self.assertIn("workflow_dispatch:", triggers)
        self.assertNotRegex(triggers, r"(?m)^\s+(?:push|pull_request):")
        self.assertRegex(workflow, r"(?m)^\s+default: what-if$")
        self.assertIn("id-token: write", workflow)
        self.assertIn("environment: azure-production", workflow)
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)

    def test_bicep_workflow_pins_actions_and_removes_local_parameters(self):
        workflow = (ROOT / ".github" / "workflows" / "deploy-bicep.yml").read_text(
            encoding="utf-8"
        )

        action_refs = re.findall(r"(?m)^\s+- uses: ([^#\s]+)", workflow)
        self.assertGreaterEqual(len(action_refs), 2)
        for action_ref in action_refs:
            self.assertRegex(action_ref, r"@[0-9a-f]{40}$")

        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("Remove-Item -LiteralPath $parametersPath", workflow)
        self.assertIn("Remove-Item Env:BICEP_PARAMETERS", workflow)


if __name__ == "__main__":
    unittest.main()
