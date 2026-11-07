from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CostStorageTests(unittest.TestCase):
    def test_terraform_enables_blob_read_diagnostics_on_the_blob_service(self):
        source = (ROOT / "terraform" / "azure" / "cost.tf").read_text(encoding="utf-8")
        self.assertIn(
            'target_resource_id         = "${azurerm_storage_account.cost[0].id}/blobServices/default"',
            source,
        )
        self.assertRegex(source, r'enabled_log\s*\{\s*category\s*=\s*"StorageRead"\s*\}')

    def test_bicep_and_terraform_use_the_same_soft_delete_window(self):
        terraform = (ROOT / "terraform" / "azure" / "cost.tf").read_text(encoding="utf-8")
        bicep = (ROOT / "infra" / "modules" / "cost.bicep").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"days\s*=\s*7", terraform)), 2)
        self.assertEqual(len(re.findall(r"days:\s*7", bicep)), 2)
        self.assertIn("containerDeleteRetentionPolicy", bicep)
        self.assertIn("StorageRead", bicep)


if __name__ == "__main__":
    unittest.main()
