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

    def test_examples_configure_no_github_collector(self):
        examples = (
            ROOT / "terraform" / "azure" / "example.tfvars.example",
            ROOT / "infra" / "main.example.bicepparam",
        )
        for path in examples:
            with self.subTest(path=path.name):
                content = path.read_text(encoding="utf-8").lower()
                self.assertNotIn("github", content)
                self.assertNotIn("collector_mode", content)
                self.assertNotIn("collectormode", content)


if __name__ == "__main__":
    unittest.main()
