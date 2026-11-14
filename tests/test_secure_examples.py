from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SecureExampleTests(unittest.TestCase):
    def test_examples_configure_no_function_collector_or_github(self):
        examples = (
            ROOT / "terraform" / "azure" / "example.tfvars.example",
            ROOT / "infra" / "main.example.bicepparam",
        )
        for path in examples:
            with self.subTest(path=path.name):
                content = path.read_text(encoding="utf-8").lower()
                for removed in ("github", "collector", "cost_query_scope", "costqueryscope",
                                "enable_cost_pipeline", "enablecostpipeline", "cost_lookback_days",
                                "costlookbackdays"):
                    self.assertNotIn(removed, content)

    def test_examples_keep_optional_cost_paths_disabled(self):
        for path in (
            ROOT / "terraform" / "azure" / "example.tfvars.example",
            ROOT / "infra" / "main.example.bicepparam",
        ):
            with self.subTest(path=path.name):
                content = path.read_text(encoding="utf-8")
                self.assertNotRegex(
                    content,
                    r"(?m)^(?:param )?(?:enable_cost_infinity|enableCostInfinity)\s*=\s*true$",
                )


if __name__ == "__main__":
    unittest.main()
