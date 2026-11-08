import calendar
import datetime as dt
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell 7 is required to exercise the Function collector")
class CostCollectorTests(unittest.TestCase):
    def run_collector(self, scenario, now_utc=None, query_scope=None, use_timer=False):
        command = [PWSH, "-NoLogo", "-NoProfile", "-File", str(ROOT / "tests" / "cost_collector_harness.ps1"), scenario]
        if now_utc:
            command.extend(["-NowUtc", now_utc])
        if query_scope is not None:
            command.extend(["-CostQueryScope", query_scope])
        if use_timer:
            command.append("-UseTimer")
        process = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        result = next(line[7:] for line in process.stdout.splitlines() if line.startswith("RESULT="))
        return json.loads(result)

    @staticmethod
    def records(result):
        return [record for batch in result["Ingestions"] for record in batch["Records"]]

    def test_queries_are_daily_scoped_and_split_into_safe_27_day_windows(self):
        result = self.run_collector("normal")
        self.assertTrue(result["Success"], result["Error"])
        requests = result["CostRequests"]
        self.assertEqual(len(requests), 6)
        self.assertEqual({entry["Query"]["type"] for entry in requests}, {"ActualCost", "AmortizedCost"})
        for entry in requests:
            query = entry["Query"]
            self.assertIn("/subscriptions/00000000-0000-0000-0000-000000000000/providers/", entry["Uri"])
            start = dt.datetime.fromisoformat(query["timePeriod"]["from"].replace("Z", "+00:00"))
            end = dt.datetime.fromisoformat(query["timePeriod"]["to"].replace("Z", "+00:00"))
            self.assertLess(end - start, dt.timedelta(days=27))
            self.assertEqual(query["dataset"]["granularity"], "Daily")
            self.assertEqual(query["dataset"]["aggregation"]["totalCost"]["name"], "PreTaxCost")
            self.assertEqual(query["dataset"]["filter"]["dimensions"]["name"], "ResourceId")
            self.assertEqual(len(query["dataset"]["filter"]["dimensions"]["values"]), 1)
        for cost_type in ("ActualCost", "AmortizedCost"):
            windows = sorted(
                (dt.datetime.fromisoformat(entry["Query"]["timePeriod"]["from"].replace("Z", "+00:00")),
                 dt.datetime.fromisoformat(entry["Query"]["timePeriod"]["to"].replace("Z", "+00:00")))
                for entry in requests if entry["Query"]["type"] == cost_type
            )
            for previous, following in zip(windows, windows[1:]):
                self.assertEqual(previous[1] + dt.timedelta(seconds=1), following[0])

        records = self.records(result)
        costs = [row for row in records if row["RecordType"] == "Cost"]
        marker = records[-1]
        self.assertEqual(marker["RecordType"], "Complete")
        self.assertEqual(marker["ExpectedRows"], len(costs))
        self.assertEqual(len({row["RowKey"] for row in costs}), len(costs))
        self.assertTrue(all(row["Currency"] == "USD" and row["Cost"] == -12.34 for row in costs))
        self.assertEqual({row["RunId"] for row in records}, {marker["RunId"]})

    def test_resource_group_queries_follow_each_account_and_encode_group_names(self):
        result = self.run_collector("multiple-resource-groups", query_scope="resourceGroup")
        self.assertTrue(result["Success"], result["Error"])
        self.assertEqual(len(result["CostRequests"]), 18)
        for request in result["CostRequests"]:
            account = request["Query"]["dataset"]["filter"]["dimensions"]["values"][0]
            group = account.split("/")[4]
            expected = "rg%20%28east%29" if group == "rg (east)" else group
            self.assertIn(f"/resourceGroups/{expected}/providers/Microsoft.CostManagement/query?", request["Uri"])
        costs = [row for row in self.records(result) if row["RecordType"] == "Cost"]
        self.assertEqual(len(costs), 18)
        self.assertEqual(self.records(result)[-1]["ExpectedRows"], 18)

    def test_resource_group_mode_rejects_unsafe_scopes_and_does_not_publish_partial_results(self):
        for scenario in ("invalid-group-dot", "invalid-group-encoded", "invalid-group-backslash"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario, query_scope="resourceGroup")
                self.assertFalse(result["Success"])
                self.assertIn("invalid resource group", result["Error"])
                self.assertEqual(result["DataRequestUris"], [])
                self.assertEqual(result["Ingestions"], [])

        denied = self.run_collector("denied-resource-group", query_scope="resourceGroup")
        self.assertFalse(denied["Success"])
        self.assertIn("resource group denial", denied["Error"])
        self.assertEqual(len(denied["CostRequests"]), 7)
        self.assertEqual(denied["Ingestions"], [])

        for scenario in ("bad-next-other-group", "bad-next-subscription"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario, query_scope="resourceGroup")
                self.assertFalse(result["Success"])
                self.assertIn("continuation URL", result["Error"])
                self.assertEqual(len(result["CostRequests"]), 1)
                self.assertEqual(result["Ingestions"], [])

    def test_timer_defaults_to_subscription_and_rejects_invalid_scope(self):
        default = self.run_collector("normal", query_scope="__missing__", use_timer=True)
        self.assertTrue(default["Success"], default["Error"])
        self.assertTrue(all("/resourceGroups/" not in entry["Uri"] for entry in default["CostRequests"]))

        scoped = self.run_collector("normal", query_scope="resourceGroup", use_timer=True)
        self.assertTrue(scoped["Success"], scoped["Error"])
        self.assertTrue(all("/resourceGroups/ai/" in entry["Uri"] for entry in scoped["CostRequests"]))

        for use_timer in (False, True):
            with self.subTest(use_timer=use_timer):
                invalid = self.run_collector("normal", query_scope="invalid", use_timer=use_timer)
                self.assertFalse(invalid["Success"])
                self.assertIn("CostQueryScope", invalid["Error"])
                self.assertEqual(invalid["DataRequestUris"], [])
                self.assertEqual(invalid["Ingestions"], [])

    def test_windows_cover_short_months_leap_days_and_partial_days(self):
        for timestamp in (
            "2023-03-01T00:00:01Z",
            "2024-03-01T23:59:59Z",
            "2024-03-31T06:00:00Z",
        ):
            with self.subTest(timestamp=timestamp):
                result = self.run_collector("normal", timestamp)
                self.assertTrue(result["Success"], result["Error"])
                now = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
                for cost_type in ("ActualCost", "AmortizedCost"):
                    windows = sorted(
                        (
                            dt.datetime.fromisoformat(entry["Query"]["timePeriod"]["from"].replace("Z", "+00:00")),
                            dt.datetime.fromisoformat(entry["Query"]["timePeriod"]["to"].replace("Z", "+00:00")),
                        )
                        for entry in result["CostRequests"] if entry["Query"]["type"] == cost_type
                    )
                    self.assertEqual(windows[0][0], now.replace(hour=0, minute=0, second=0) - dt.timedelta(days=61))
                    self.assertEqual(windows[-1][1], now)
                    for index, (start, end) in enumerate(windows):
                        if index:
                            self.assertEqual(start, windows[index - 1][1] + dt.timedelta(seconds=1))
                        previous_year = end.year - (end.month == 1)
                        previous_month = 12 if end.month == 1 else end.month - 1
                        previous_day = min(end.day, calendar.monthrange(previous_year, previous_month)[1])
                        cutoff = end.replace(year=previous_year, month=previous_month, day=previous_day) + dt.timedelta(days=1)
                        self.assertGreaterEqual(start, cutoff)
                marker = self.records(result)[-1]
                self.assertEqual(marker["WindowEnd"], timestamp)

    def test_empty_result_is_not_fabricated_zero_cost(self):
        for scenario in ("empty", "empty-rows"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertTrue(result["Success"], result["Error"])
                records = self.records(result)
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["RecordType"], "Complete")
                self.assertEqual(records[0]["ExpectedRows"], 0)

    def test_no_content_after_continuation_does_not_publish_a_partial_snapshot(self):
        for scope in ("subscription", "resourceGroup"):
            with self.subTest(scope=scope):
                result = self.run_collector("empty-continuation", query_scope=scope)
                self.assertFalse(result["Success"])
                self.assertIn("continuation", result["Error"])
                self.assertEqual(len(result["CostRequests"]), 2)
                self.assertEqual(result["Ingestions"], [])

    def test_invalid_successful_cost_responses_do_not_publish_a_snapshot(self):
        for scenario in (
            "empty-200", "json-null", "unexpected-status",
            "null-rows", "scalar-rows", "object-rows", "non-array-row", "null-rows-after-page",
            "null-columns", "scalar-columns",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertIn("Cost Management", result["Error"])
                self.assertEqual(result["Ingestions"], [])
                if scenario == "null-rows-after-page":
                    self.assertEqual(len(result["CostRequests"]), 2)

    def test_ambiguous_columns_and_boolean_cost_do_not_publish_a_snapshot(self):
        for scenario in (
            "duplicate-cost-column", "duplicate-cost-column-case",
            "duplicate-currency-column", "duplicate-date-column",
            "duplicate-column-after-page", "boolean-cost", "boolean-zero-cost",
            "null-column-name", "blank-column-name", "numeric-column-name",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertIn("Cost Management", result["Error"])
                if scenario.startswith("duplicate"):
                    self.assertIn("duplicate column names", result["Error"])
                elif scenario.endswith("column-name"):
                    self.assertIn("invalid column name", result["Error"])
                else:
                    self.assertIn("invalid date, currency, or cost", result["Error"])
                self.assertEqual(result["Ingestions"], [])
                if scenario == "duplicate-column-after-page":
                    self.assertEqual(len(result["CostRequests"]), 2)

    def test_numeric_costs_are_preserved(self):
        for scenario, expected in (
            ("integer-cost", -12), ("zero-cost", 0), ("numeric-string-cost", 12.34),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertTrue(result["Success"], result["Error"])
                costs = [row for row in self.records(result) if row["RecordType"] == "Cost"]
                self.assertTrue(costs)
                self.assertTrue(all(row["Cost"] == expected for row in costs))
                self.assertEqual(self.records(result)[-1]["ExpectedRows"], len(costs))

    def test_real_http_transport_distinguishes_empty_and_malformed_responses(self):
        requests = []
        redirected_requests = []
        responses = {
            "/no-content": (204, b""),
            "/empty-success": (200, b""),
            "/json-null": (200, b"null"),
            "/unexpected-status": (202, b'{"properties":{"columns":[],"rows":[]}}'),
            "/valid": (200, b'{"properties":{"columns":[],"rows":[]}}'),
            "/ingestion-valid": (204, b""),
            "/ingestion-unexpected-200": (200, b'{"error":"unexpected"}'),
            "/ingestion-unexpected-202": (202, b"{}"),
            "/ingestion-unexpected-206": (206, b"{}"),
        }
        for status in (301, 302, 303, 307, 308):
            for kind in ("cost", "ingestion"):
                responses[f"/redirect-{kind}-{status}"] = (status, b"")

        class RedirectHandler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                redirected_requests.append((self.command, self.path, body))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"properties":{"columns":[],"rows":[]}}')

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

        redirect_server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        redirect_thread = threading.Thread(target=redirect_server.serve_forever, daemon=True)
        redirect_thread.start()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                requests.append(self.path)
                status, body = responses[self.path]
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                if self.path.startswith("/redirect-"):
                    self.send_header(
                        "Location", f"http://127.0.0.1:{redirect_server.server_port}/target"
                    )
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ.copy()
        for key in list(env):
            if key.lower() in ("http_proxy", "https_proxy", "all_proxy"):
                env.pop(key)
        env["COST_COLLECTOR_SOURCE"] = str(ROOT / "function" / "cost-collector" / "cost_collector.ps1")
        env["COST_COLLECTOR_TEST_URL"] = f"http://127.0.0.1:{server.server_port}"
        script = r"""
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $env:COST_COLLECTOR_SOURCE, [ref] $tokens, [ref] $errors
            )
            if ($errors.Count -gt 0) { throw 'Unable to parse the collector.' }
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Invoke-AzurePost'
            }, $true)
            if ($null -eq $definition) { throw 'Collector transport function not found.' }
            . ([ScriptBlock]::Create($definition.Extent.Text))
            function Get-ManagedToken { param($Resource) return 'mock-token' }

            $cases = @(
                'no-content', 'empty-success', 'json-null', 'unexpected-status', 'valid',
                'ingestion-valid', 'ingestion-unexpected-200', 'ingestion-unexpected-202',
                'ingestion-unexpected-206'
            )
            foreach ($status in @(301, 302, 303, 307, 308)) {
                $cases += "redirect-cost-$status", "redirect-ingestion-$status"
            }
            $results = @(foreach ($case in $cases) {
                $script:LastCostRequest = $null
                try {
                    $value = Invoke-AzurePost -Uri ($env:COST_COLLECTOR_TEST_URL + '/' + $case) `
                        -Audience 'mock' -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"synthetic"}')) `
                        -CostRequest:($case -notlike '*ingestion*')
                    [pscustomobject]@{
                        Case = $case
                        Success = $true
                        IsNull = $null -eq $value
                        HasProperties = $null -ne $value -and $null -ne $value.PSObject.Properties['properties']
                    }
                }
                catch {
                    [pscustomobject]@{
                        Case = $case
                        Success = $false
                        Error = $_.Exception.Message
                    }
                }
            })
            Write-Output ('RESULT=' + (ConvertTo-Json -InputObject $results -Compress))
        """
        try:
            process = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                capture_output=True,
                text=True,
                env=env,
                timeout=30,
                check=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            redirect_server.shutdown()
            redirect_server.server_close()
            redirect_thread.join()
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(next(line[7:] for line in process.stdout.splitlines() if line.startswith("RESULT=")))
        by_case = {entry["Case"]: entry for entry in result}
        self.assertCountEqual(requests, responses)
        self.assertTrue(by_case["no-content"]["Success"])
        self.assertTrue(by_case["no-content"]["IsNull"])
        self.assertTrue(by_case["valid"]["Success"])
        self.assertFalse(by_case["valid"]["IsNull"])
        self.assertTrue(by_case["valid"]["HasProperties"])
        self.assertTrue(by_case["ingestion-valid"]["Success"])
        for status in (200, 202, 206):
            with self.subTest(ingestion_status=status):
                result = by_case[f"ingestion-unexpected-{status}"]
                self.assertFalse(result["Success"])
                self.assertIn("Logs Ingestion", result["Error"])
        for case in ("empty-success", "json-null", "unexpected-status"):
            with self.subTest(case=case):
                self.assertFalse(by_case[case]["Success"])
                self.assertIn("Cost Management", by_case[case]["Error"])
        for status in (301, 302, 303, 307, 308):
            for kind in ("cost", "ingestion"):
                with self.subTest(status=status, kind=kind):
                    self.assertFalse(by_case[f"redirect-{kind}-{status}"]["Success"])
        self.assertEqual(redirected_requests, [])

    def test_managed_identity_requests_do_not_follow_redirects(self):
        requests = []
        redirected_requests = []

        class RedirectHandler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                redirected_requests.append(self.headers.get("X-IDENTITY-HEADER"))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"access_token":"unexpected-token"}')

        redirect_server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        redirect_thread = threading.Thread(target=redirect_server.serve_forever, daemon=True)
        redirect_thread.start()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get("X-IDENTITY-HEADER")))
                case = self.path.split("?", 1)[0].rsplit("/", 1)[-1]
                status = 200 if case == "valid" else int(case)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                if status != 200:
                    self.send_header("Location", f"http://127.0.0.1:{redirect_server.server_port}/target")
                self.end_headers()
                if status == 200:
                    self.wfile.write(b'{"access_token":"mock-token"}')

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ.copy()
        for key in list(env):
            if key.lower() in ("http_proxy", "https_proxy", "all_proxy"):
                env.pop(key)
        env["COST_COLLECTOR_SOURCE"] = str(ROOT / "function" / "cost-collector" / "cost_collector.ps1")
        env["COST_COLLECTOR_TEST_URL"] = f"http://127.0.0.1:{server.server_port}"
        script = r"""
            $errors = $null
            $tokens = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $env:COST_COLLECTOR_SOURCE, [ref] $tokens, [ref] $errors
            )
            if ($errors.Count -gt 0) { throw 'Unable to parse the collector.' }
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Get-ManagedToken'
            }, $true)
            if ($null -eq $definition) { throw 'Managed identity function not found.' }
            . ([ScriptBlock]::Create($definition.Extent.Text))
            $IdentityClientId = 'synthetic-client-id'
            $env:IDENTITY_HEADER = 'synthetic-identity-header'
            $results = @(foreach ($case in @('valid', '301', '302', '303', '307', '308')) {
                $env:IDENTITY_ENDPOINT = $env:COST_COLLECTOR_TEST_URL + '/' + $case
                try {
                    $value = Get-ManagedToken -Resource 'https://management.azure.com/'
                    [pscustomobject]@{ Case = $case; Success = $true; IsExpected = $value -eq 'mock-token' }
                }
                catch {
                    [pscustomobject]@{ Case = $case; Success = $false }
                }
            })
            Write-Output ('RESULT=' + (ConvertTo-Json -InputObject $results -Compress))
        """
        try:
            process = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                capture_output=True, text=True, env=env, timeout=30, check=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            redirect_server.shutdown()
            redirect_server.server_close()
            redirect_thread.join()
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(next(line[7:] for line in process.stdout.splitlines() if line.startswith("RESULT=")))
        by_case = {entry["Case"]: entry for entry in result}
        self.assertTrue(by_case["valid"]["Success"])
        self.assertTrue(by_case["valid"]["IsExpected"])
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                self.assertFalse(by_case[str(status)]["Success"])
        self.assertEqual(len(requests), 6)
        self.assertTrue(all(header == "synthetic-identity-header" for _, header in requests))
        self.assertEqual(redirected_requests, [])

    def test_follows_safe_pagination_and_rejects_unsafe_continuations(self):
        result = self.run_collector("pagination")
        self.assertTrue(result["Success"], result["Error"])
        self.assertEqual(len(result["CostRequests"]), 7)
        self.assertEqual(self.records(result)[-1]["ExpectedRows"], 7)
        continuation = next(entry for entry in result["CostRequests"] if "$skiptoken=" in entry["Uri"])
        initial_uri = continuation["Uri"].split("&$skiptoken=", 1)[0]
        self.assertTrue(any(
            entry["Uri"] == initial_uri and entry["Query"] == continuation["Query"]
            for entry in result["CostRequests"]
        ))

        for scenario, expected_requests in (
            ("bad-next", 1),
            ("bad-next-host-suffix", 1),
            ("bad-next-http", 1),
            ("bad-next-port", 1),
            ("bad-next-userinfo", 1),
            ("bad-next-path", 1),
            ("bad-next-repeat", 1),
            ("bad-next-cycle", 2),
        ):
            with self.subTest(scenario=scenario):
                rejected = self.run_collector(scenario)
                self.assertFalse(rejected["Success"])
                self.assertIn("continuation URL", rejected["Error"])
                self.assertEqual(len(rejected["CostRequests"]), expected_requests)
                self.assertEqual(
                    rejected["DataRequestUris"],
                    [entry["Uri"] for entry in rejected["CostRequests"]],
                )
                self.assertEqual(rejected["Ingestions"], [])

    def test_rejects_non_string_continuation_metadata_without_publishing(self):
        for scenario, expected_requests in (
            ("invalid-next-empty-array", 1),
            ("invalid-next-empty-object", 1),
            ("invalid-next-single-array", 1),
            ("invalid-next-boolean", 1),
            ("invalid-next-number", 1),
            ("invalid-next-array-after-page", 2),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertIn("invalid continuation URL", result["Error"])
                self.assertEqual(len(result["CostRequests"]), expected_requests)
                self.assertEqual(result["Ingestions"], [])

    def test_missing_null_or_empty_string_continuation_ends_pagination(self):
        for scenario in ("missing-next-property", "normal", "empty-next-string"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertTrue(result["Success"], result["Error"])
                self.assertEqual(len(result["CostRequests"]), 6)
                self.assertEqual(self.records(result)[-1]["ExpectedRows"], 6)

    def test_deduplicates_identical_rows_but_rejects_conflicts(self):
        result = self.run_collector("duplicate")
        self.assertTrue(result["Success"], result["Error"])
        self.assertEqual(self.records(result)[-1]["ExpectedRows"], 6)
        conflict = self.run_collector("conflict")
        self.assertFalse(conflict["Success"])
        self.assertIn("conflicting totals", conflict["Error"])
        self.assertEqual(conflict["Ingestions"], [])

    def test_currencies_are_preserved_separately(self):
        result = self.run_collector("currencies")
        self.assertTrue(result["Success"], result["Error"])
        rows = [row for row in self.records(result) if row["RecordType"] == "Cost"]
        self.assertEqual({row["Currency"] for row in rows}, {"USD", "EUR"})
        self.assertEqual(len(rows), 12)

    def test_rate_limit_honors_longest_retry_header(self):
        result = self.run_collector("throttle")
        self.assertTrue(result["Success"], result["Error"])
        self.assertIn(19, result["Sleeps"])
        self.assertEqual(len(result["CostRequests"]), 7)
        failed = self.run_collector("retry-exhausted")
        self.assertFalse(failed["Success"])
        self.assertEqual(len(failed["CostRequests"]), 6)
        self.assertEqual(failed["Ingestions"], [])

    def test_invalid_or_excessive_retry_headers_fail_without_retrying(self):
        for scenario in (
            "invalid", "invalid-azure", "negative", "nan", "infinity", "empty",
            "ambiguous", "invalid-date", "huge", "future-rfc", "future-rfc850", "future-asctime",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(f"throttle-header-{scenario}")
                self.assertFalse(result["Success"])
                message = "retry delay exceeding" if scenario == "huge" or scenario.startswith("future-") else "invalid retry-after"
                self.assertIn(message, result["Error"].lower())
                self.assertEqual(len(result["CostRequests"]), 1)
                self.assertEqual(result["Sleeps"], [])
                self.assertEqual(result["Ingestions"], [])

        for scenario, message in (
            ("ingestion-throttle-invalid", "invalid retry-after"),
            ("ingestion-throttle-huge", "retry delay exceeding"),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertIn(message, result["Error"].lower())
                self.assertEqual(len(result["Ingestions"]), 1)
                self.assertFalse(any(row["RecordType"] == "Complete" for row in self.records(result)))

    def test_valid_retry_headers_and_missing_header_are_honored(self):
        for scenario, delay in (("fractional", 20), ("zero", 1), ("date", 1), ("missing", 1)):
            with self.subTest(scenario=scenario):
                result = self.run_collector(f"throttle-header-{scenario}")
                self.assertTrue(result["Success"], result["Error"])
                self.assertEqual(result["Sleeps"][0], delay)
                self.assertEqual(len(result["CostRequests"]), 7)

        for date_format in ("rfc", "rfc850", "asctime"):
            with self.subTest(date_format=date_format):
                result = self.run_collector(f"throttle-header-soon-{date_format}")
                self.assertTrue(result["Success"], result["Error"])
                target = dt.datetime.fromisoformat(result["RetryTarget"])
                slept_at = dt.datetime.fromisoformat(result["RetrySleepTime"])
                remaining = max(1, math.ceil((target - slept_at).total_seconds()))
                self.assertGreaterEqual(result["Sleeps"][0], remaining)
                self.assertLessEqual(result["Sleeps"][0], 35)
                self.assertEqual(len(result["CostRequests"]), 7)

    def test_non_transient_http_errors_are_not_retried(self):
        for status in (400, 401, 403, 404):
            with self.subTest(status=status):
                result = self.run_collector(f"client-error-{status}")
                self.assertFalse(result["Success"])
                self.assertEqual(len(result["CostRequests"]), 1)
                self.assertEqual(result["Sleeps"], [])
                self.assertEqual(result["Ingestions"], [])

    def test_transient_http_and_network_errors_are_retried(self):
        for scenario in ("transient-http-408", "transient-http-500", "transient-network"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertEqual(len(result["CostRequests"]), 6)
                self.assertTrue(result["Sleeps"])
                self.assertEqual(result["Ingestions"], [])

    def test_bad_cost_response_fails_before_ingestion(self):
        for scenario in ("cost-error", "bad-columns"):
            with self.subTest(scenario=scenario):
                result = self.run_collector(scenario)
                self.assertFalse(result["Success"])
                self.assertEqual(result["Ingestions"], [])

    def test_batches_are_bounded_and_failures_never_publish_completion(self):
        result = self.run_collector("many")
        self.assertTrue(result["Success"], result["Error"])
        self.assertGreater(len(result["Ingestions"]), 2)
        self.assertTrue(all(batch["Bytes"] <= 900000 for batch in result["Ingestions"]))
        self.assertEqual(self.records(result)[-1]["ExpectedRows"], 2700)
        for scenario in ("ingestion-error", "ingestion-error-late"):
            with self.subTest(scenario=scenario):
                failed = self.run_collector(scenario)
                self.assertFalse(failed["Success"])
                self.assertTrue(failed["Ingestions"])
                self.assertFalse(any(row["RecordType"] == "Complete" for row in self.records(failed)))

    def test_unexpected_ingestion_success_status_does_not_publish_completion(self):
        for status in (200, 202, 206):
            with self.subTest(status=status):
                result = self.run_collector(f"ingestion-unexpected-{status}")
                self.assertFalse(result["Success"])
                self.assertIn(f"Logs Ingestion returned an unexpected HTTP status: {status}", result["Error"])
                self.assertEqual(len(result["Ingestions"]), 1)
                self.assertFalse(any(row["RecordType"] == "Complete" for row in self.records(result)))

    def test_unexpected_completion_response_is_reported_as_failure(self):
        for status in (200, 202, 206):
            with self.subTest(status=status):
                result = self.run_collector(f"marker-unexpected-{status}")
                self.assertFalse(result["Success"])
                self.assertIn(f"Logs Ingestion returned an unexpected HTTP status: {status}", result["Error"])
                self.assertEqual([row["RecordType"] for row in self.records(result)][-1], "Complete")


if __name__ == "__main__":
    unittest.main()
