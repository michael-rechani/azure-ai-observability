import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
SOURCE = (ROOT / "terraform" / "azure" / "cost.tf").read_text(encoding="utf-8")
PUBLISHER = ROOT / "scripts" / "deploy_cost_function.ps1"


@unittest.skipUnless(PWSH, "PowerShell 7 is required to exercise Function deployment")
class CostFunctionDeploymentTests(unittest.TestCase):
    def run_deployment(self, settings, exit_code=0, cli_available=True):
        mock_cli = """
            function global:az {
                ConvertTo-Json -InputObject @($args) -Compress |
                    Set-Content -LiteralPath $env:AZ_CALL_LOG -Encoding UTF8
                $global:LASTEXITCODE = [int] $env:AZ_EXIT_CODE
            }
        """
        if not cli_available:
            mock_cli += "\nfunction global:Get-Command { return $null }\n"
        environment = os.environ.copy()
        environment.update(settings)
        environment["AZ_EXIT_CODE"] = str(exit_code)
        environment["PUBLISHER_SCRIPT"] = str(PUBLISHER)
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
             textwrap.dedent(mock_cli) + "\n& $env:PUBLISHER_SCRIPT\n"],
            env=environment,
            capture_output=True,
            text=True,
        )

    def test_publishes_package_with_explicit_subscription(self):
        with tempfile.TemporaryDirectory(prefix="function package ") as directory:
            package = Path(directory) / "cost collector.zip"
            package.touch()
            log = Path(directory) / "call.json"
            settings = {
                "COST_FUNCTION_PACKAGE": str(package),
                "COST_FUNCTION_GROUP": "monitoring group &",
                "COST_FUNCTION_NAME": "cost-function",
                "COST_FUNCTION_SUBSCRIPTION": "subscription-id",
                "AZ_CALL_LOG": str(log),
            }
            result = self.run_deployment(settings)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(log.read_text(encoding="utf-8-sig")),
                [
                    "functionapp", "deployment", "source", "config-zip",
                    "--resource-group", "monitoring group &", "--name", "cost-function",
                    "--subscription", "subscription-id", "--src", str(package),
                    "--only-show-errors", "--output", "none",
                ],
            )

    def test_missing_cli_package_or_settings_fails_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.zip"
            package.touch()
            settings = {
                "COST_FUNCTION_PACKAGE": str(package),
                "COST_FUNCTION_GROUP": "rg",
                "COST_FUNCTION_NAME": "app",
                "COST_FUNCTION_SUBSCRIPTION": "subscription",
                "AZ_CALL_LOG": str(Path(directory) / "call.json"),
            }
            missing_cli = self.run_deployment(settings, cli_available=False)
            self.assertNotEqual(missing_cli.returncode, 0)
            self.assertIn("Azure CLI is required", missing_cli.stderr)
            missing_package = self.run_deployment({**settings, "COST_FUNCTION_PACKAGE": str(package) + ".missing"})
            self.assertNotEqual(missing_package.returncode, 0)
            self.assertIn("package does not exist", missing_package.stderr)
            missing_setting = self.run_deployment({**settings, "COST_FUNCTION_GROUP": ""})
            self.assertNotEqual(missing_setting.returncode, 0)
            self.assertIn("ResourceGroup is required", missing_setting.stderr)
            self.assertFalse(Path(settings["AZ_CALL_LOG"]).exists())

    def test_cli_deployment_failure_propagates(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.zip"
            package.touch()
            settings = {
                "COST_FUNCTION_PACKAGE": str(package),
                "COST_FUNCTION_GROUP": "rg",
                "COST_FUNCTION_NAME": "app",
                "COST_FUNCTION_SUBSCRIPTION": "subscription",
                "AZ_CALL_LOG": str(Path(directory) / "call.json"),
            }
            result = self.run_deployment(settings, exit_code=7)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exit code 7", result.stderr)

    def test_terraform_runs_the_command_without_python(self):
        self.assertIn('interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File"]', SOURCE)
        self.assertIn("command     = abspath(local.cost_deployment_script)", SOURCE)
        self.assertIn("filesha256(local.cost_deployment_script)", SOURCE)
        self.assertIn("abspath(data.archive_file.cost_function[0].output_path)", SOURCE)


if __name__ == "__main__":
    unittest.main()
