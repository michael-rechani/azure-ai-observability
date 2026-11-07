import calendar
import datetime as dt
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell 7 is required to exercise the Function collector")
class CostCollectorTests(unittest.TestCase):
    def run_collector(self, scenario, now_utc=None):
        command = [PWSH, "-NoLogo", "-NoProfile", "-File", str(ROOT / "tests" / "cost_collector_harness.ps1"), scenario]
        if now_utc:
            command.extend(["-NowUtc", now_utc])
        process = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
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
        result = self.run_collector("empty")
        self.assertTrue(result["Success"], result["Error"])
        records = self.records(result)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["RecordType"], "Complete")
        self.assertEqual(records[0]["ExpectedRows"], 0)

    def test_follows_safe_pagination_and_rejects_external_continuations(self):
        result = self.run_collector("pagination")
        self.assertTrue(result["Success"], result["Error"])
        self.assertEqual(len(result["CostRequests"]), 7)
        self.assertEqual(self.records(result)[-1]["ExpectedRows"], 7)
        rejected = self.run_collector("bad-next")
        self.assertFalse(rejected["Success"])
        self.assertIn("unexpected continuation", rejected["Error"])
        self.assertEqual(rejected["Ingestions"], [])

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


if __name__ == "__main__":
    unittest.main()
