from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SecureExampleTests(unittest.TestCase):
    def test_cost_examples_select_resource_group_scoped_roles(self):
        examples = (
            (
                ROOT / "terraform" / "azure" / "example.tfvars.example",
                r'(?m)^cost_query_scope\s*=\s*"resourceGroupManaged"',
            ),
            (
                ROOT / "infra" / "main.example.bicepparam",
                r"(?m)^param costQueryScope = 'resourceGroupManaged'$",
            ),
        )
        for path, pattern in examples:
            with self.subTest(path=path.name):
                content = path.read_text(encoding="utf-8")
                self.assertRegex(content, pattern)
                self.assertRegex(content, r"(?m)^(?:enable_cost_pipeline|param enableCostPipeline)\s*=?\s*(?:false|= false)$")

    def test_function_free_examples_require_an_explicit_subject(self):
        examples = (
            (
                ROOT / "terraform" / "azure" / "example.tfvars.example",
                r'(?m)^cost_collector_mode\s*=\s*"githubOidc"',
                r'(?m)^cost_github_oidc_subject\s*=\s*""',
            ),
            (
                ROOT / "infra" / "main.example.bicepparam",
                r"(?m)^param costCollectorMode = 'githubOidc'$",
                r"(?m)^param costGithubOidcSubject = ''$",
            ),
        )
        for path, mode, empty_subject in examples:
            with self.subTest(path=path.name):
                content = path.read_text(encoding="utf-8")
                self.assertRegex(content, mode)
                self.assertRegex(content, empty_subject)


if __name__ == "__main__":
    unittest.main()
