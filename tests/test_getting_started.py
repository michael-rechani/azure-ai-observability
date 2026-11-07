import re
import shutil
import subprocess
import unittest
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
GUIDE = ROOT / "docs" / "getting-started.md"
PWSH = shutil.which("pwsh")


def markdown_headings(path):
    seen = {}
    anchors = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue
        title = re.sub(r"`([^`]*)`", r"\1", match.group(1))
        title = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", title)
        slug = re.sub(r"[^\w -]", "", title.lower())
        slug = re.sub(r"\s+", "-", slug.strip())
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        anchors.add(slug if count == 0 else f"{slug}-{count}")
    return anchors


class GettingStartedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.markdown = GUIDE.read_text(encoding="utf-8")

    def test_local_links_and_heading_anchors_resolve(self):
        links = re.findall(r"(?<!!)\[[^\]]*\]\(([^)]+)\)", self.markdown)
        self.assertTrue(links, "The guide should contain links to validate.")
        for raw_target in links:
            target = raw_target.split(maxsplit=1)[0].strip("<>")
            parsed = urlsplit(target)
            if parsed.scheme or target.startswith("//"):
                continue
            linked_file = (GUIDE.parent / unquote(parsed.path)).resolve() if parsed.path else GUIDE
            with self.subTest(target=target):
                self.assertTrue(linked_file.is_file(), f"Missing local link target: {target}")
                if parsed.fragment:
                    self.assertIn(
                        unquote(parsed.fragment).lower(),
                        markdown_headings(linked_file),
                        f"Missing heading anchor: {target}",
                    )

    def test_local_copy_commands_refuse_to_overwrite_existing_files(self):
        commands = re.findall(r"(?m)^\s*Copy-Item\b[^\r\n]*", self.markdown)
        self.assertEqual(len(commands), 5, "Review newly added local-copy commands.")
        self.assertTrue(all("-Destination" in command and "-ErrorAction Stop" in command for command in commands))
        for destination in (
            "$parametersFile", "$azureBackendFile", "$grafanaBackendFile",
            "$azureTfvarsFile", "$grafanaTfvarsFile",
        ):
            with self.subTest(destination=destination):
                self.assertIn(destination, self.markdown)
        self.assertIn("foreach ($destination in @($azureBackendFile, $grafanaBackendFile))", self.markdown)
        self.assertIn("Test-Path -LiteralPath $destination", self.markdown)

    def test_manual_import_documents_all_dashboards(self):
        setup = (ROOT / "docs" / "setup.md").read_text(encoding="utf-8")
        manual = setup.split("## Manual data-source and dashboard import", 1)[1].split("\n## ", 1)[0]
        dashboards = sorted((ROOT / "dashboards").glob("*.json"))
        self.assertTrue(dashboards, "No dashboards found to document.")
        for dashboard in dashboards:
            with self.subTest(dashboard=dashboard.name):
                self.assertIn(f"dashboards/{dashboard.name}", manual)

    @unittest.skipUnless(PWSH, "PowerShell 7 is required to parse the documented examples")
    def test_powershell_examples_parse_without_execution(self):
        examples = re.findall(
            r"(?ms)^```powershell\s*\n(.*?)^```[ \t]*$", self.markdown, re.IGNORECASE
        )
        self.assertGreater(len(examples), 0, "The guide should contain PowerShell examples.")
        source = "\n\n".join(examples)
        parser = (
            "$source = [Console]::In.ReadToEnd(); "
            "$tokens = $null; $errors = $null; "
            "[System.Management.Automation.Language.Parser]::ParseInput("
            "$source, [ref]$tokens, [ref]$errors) | Out-Null; "
            "if ($errors.Count -gt 0) { "
            "$errors | ForEach-Object { Write-Error $_.ToString() }; exit 1 }"
        )
        result = subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", parser],
            input=source, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
