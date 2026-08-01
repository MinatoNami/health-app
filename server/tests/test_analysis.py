"""Tests for the deterministic analysis service.

The ones that matter are the refusals. Any statistics library can compute a
7-day mean; the value of this layer is that it declines to compute one from two
days of data, declines to compare two periods when one of them is mostly
missing, and never lets a partial day masquerade as a complete one.
"""

from datetime import date, datetime, time, timedelta, timezone as dt_timezone
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from ingest import health_analysis, safety
from ingest.models import ApiToken, Batch, Device, Goal, Record

SGT = ZoneInfo("Asia/Singapore")


def at(day: date, hour: int = 12) -> datetime:
    """Midday in the display timezone, so a day bucket is never ambiguous."""
    return datetime.combine(day, time(hour), tzinfo=SGT)


class AnalysisTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.token, self.raw = ApiToken.issue("analysis-test")
        self.device = Device.objects.create(device_id="analysis-device")
        self.batch = Batch.objects.create(idempotency_key="analysis.ndjson", device=self.device)
        # Windows are anchored on the last *complete* day, so every fixture is
        # positioned relative to it rather than to a hard-coded date.
        self.as_of = health_analysis.last_complete_day()
        self.counter = 0

    def auth(self):
        return {"authorization": f"Bearer {self.raw}"}

    def sample(self, day: date, value: float, slug="step_count", **kwargs):
        self.counter += 1
        defaults = {
            "id": f"rec-{self.counter}",
            "device": self.device,
            "batch": self.batch,
            "kind": Record.Kind.QUANTITY,
            "metric": f"HKQuantityTypeIdentifier{slug}",
            "metric_slug": slug,
            "unit": "count",
            "aggregation": "cumulative",
            "value": value,
            "start": at(day),
            "end": at(day),
            "recorded_at": at(day),
        }
        defaults.update(kwargs)
        return Record.objects.create(**defaults)

    def rollup(self, day: date, value: float, slug="step_count"):
        """A deduplicated daily total, the way the phone ships them."""
        return self.sample(
            day,
            value,
            slug=slug,
            id=f"stat:{slug}:{day.isoformat()}",
            kind=Record.Kind.STATISTIC,
        )

    def fill(self, days: int, value_for, slug="step_count", offset: int = 0, rollups=True):
        """`days` consecutive days ending `offset` days before as_of."""
        for i in range(days):
            day = self.as_of - timedelta(days=offset + i)
            value = value_for(i) if callable(value_for) else value_for
            if rollups:
                self.rollup(day, value, slug=slug)
            else:
                self.sample(day, value, slug=slug)


class BaselineTests(AnalysisTestCase):
    def test_current_and_baseline_windows_do_not_overlap(self):
        """A 7-day mean compared against a 28-day mean containing it dampens the
        very change being looked for. The windows are adjacent, not nested."""
        self.fill(7, 12_000)  # current week
        self.fill(28, 8_000, offset=7)  # the 28 days before it

        result = health_analysis.compare_to_baseline("step_count")

        self.assertEqual(result["current"]["value"], 12_000)
        self.assertEqual(result["baseline"]["value"], 8_000)
        self.assertEqual(result["change"], 4_000)
        self.assertEqual(result["change_pct"], 50.0)
        self.assertEqual(
            date.fromisoformat(result["baseline"]["to"]),
            date.fromisoformat(result["current"]["from"]) - timedelta(days=1),
        )

    def test_today_is_excluded_because_it_is_incomplete(self):
        """Half a day of steps against full-day baselines reads as a collapse in
        activity that is really just the clock."""
        self.fill(7, 10_000)
        self.fill(28, 10_000, offset=7)
        self.rollup(health_analysis.today(), 300)  # a couple of hours in

        result = health_analysis.compare_to_baseline("step_count")

        self.assertEqual(result["current"]["value"], 10_000)
        self.assertEqual(result["current"]["to"], self.as_of.isoformat())

    def test_thin_current_window_is_insufficient_not_wrong(self):
        self.fill(2, 9_000)
        self.fill(28, 9_000, offset=7)

        result = health_analysis.compare_to_baseline("step_count")

        self.assertEqual(result["confidence"], "insufficient")
        self.assertIn("at least 3", result["confidence_reason"])
        # No claim about the change is made at all.
        self.assertEqual(result["significance"], "unclear")

    def test_thin_baseline_is_insufficient(self):
        self.fill(7, 9_000)
        self.fill(4, 9_000, offset=7)

        self.assertEqual(
            health_analysis.compare_to_baseline("step_count")["confidence"], "insufficient"
        )

    def test_partial_coverage_lowers_confidence_and_says_why(self):
        self.fill(4, 10_000)  # 4 of 7 current days
        self.fill(28, 10_000, offset=7)

        result = health_analysis.compare_to_baseline("step_count")

        self.assertEqual(result["confidence"], "moderate")
        self.assertIn("4 of 7", result["confidence_reason"])

    def test_change_is_graded_against_personal_variability(self):
        """300 steps is noise for someone who swings by 4,000 and a real shift
        for someone who walks the same route daily. A fixed percentage would get
        one of them wrong."""
        steady_days = [10_000, 10_100, 9_900, 10_050, 9_950, 10_000, 10_020]
        self.fill(7, lambda i: 10_400)
        for i, value in enumerate(steady_days * 4):
            self.rollup(self.as_of - timedelta(days=7 + i), value)

        steady = health_analysis.compare_to_baseline("step_count")
        self.assertEqual(steady["significance"], "notable")

        Record.objects.all().delete()
        cache.clear()
        self.fill(7, lambda i: 10_400)
        for i in range(28):
            self.rollup(self.as_of - timedelta(days=7 + i), 6_000 + (i % 7) * 2_000)

        volatile = health_analysis.compare_to_baseline("step_count")
        self.assertEqual(volatile["significance"], "stable")


class TrendTests(AnalysisTestCase):
    def test_moving_average_uses_calendar_days_not_recorded_days(self):
        """Averaging "the last seven values" when only three days were recorded
        stretches a week into a fortnight under a label that says otherwise."""
        for i in range(0, 30, 3):  # every third day only
            self.rollup(self.as_of - timedelta(days=i), 10_000)

        result = health_analysis.trend("step_count", days=30)

        # Each 7-day window holds at most 3 recorded days, which fails the
        # half-the-window floor, so no 7-day average is published at all.
        self.assertEqual(result["moving_average_7"], [])
        self.assertEqual(result["valid_days"], 10)

    def test_a_line_through_noise_is_reported_as_flat(self):
        for i in range(60):
            self.rollup(self.as_of - timedelta(days=i), 8_000 + (i % 5) * 3_000)

        self.assertEqual(health_analysis.trend("step_count", days=60)["trend_direction"], "flat")

    def test_a_real_decline_is_reported_as_falling(self):
        for i in range(60):
            self.rollup(self.as_of - timedelta(days=i), 5_000 + i * 120)

        result = health_analysis.trend("step_count", days=60)
        self.assertEqual(result["trend_direction"], "falling")
        self.assertLess(result["slope_per_week"], 0)


class StreakTests(AnalysisTestCase):
    def test_a_missing_day_breaks_the_streak(self):
        """Treating a gap as a met goal is exactly the failure §7 warns about."""
        for i in [0, 1, 2, 4, 5, 6, 7]:  # day 3 missing entirely
            self.rollup(self.as_of - timedelta(days=i), 12_000)

        result = health_analysis.streak("step_count", 10_000)

        self.assertEqual(result["current_streak_days"], 3)
        self.assertEqual(result["longest_streak_days"], 4)


class DataQualityTests(AnalysisTestCase):
    def test_manual_entries_are_counted_and_flagged(self):
        for i in range(20):
            self.sample(
                self.as_of - timedelta(days=i),
                72.0,
                slug="body_mass",
                aggregation="discrete",
                unit="kg",
                metadata={"HKWasUserEntered": True},
            )

        report = health_analysis.data_quality("body_mass")

        self.assertEqual(report["manual_samples"], 20)
        self.assertTrue(any("entered by hand" in note for note in report["notes"]))
        self.assertEqual(report["quality"], "low")

    def test_estimated_days_are_named_as_estimates(self):
        """Two sources writing the same walk means a raw sum double-counts. The
        report has to say which days that applies to."""
        for i in range(20):
            day = self.as_of - timedelta(days=i)
            self.sample(day, 5_000, source_name="iPhone")
            self.sample(day, 5_000, source_name="Apple Watch")

        report = health_analysis.data_quality("step_count")

        self.assertEqual(report["estimated_days"], 20)
        self.assertTrue(any("double-count" in note for note in report["notes"]))

    def test_an_averaged_metric_is_never_called_estimated(self):
        """Averaging the same readings twice gives the same average, so cross-source
        overlap cannot inflate a discrete metric. Flagging it anyway put a caveat
        on every day of heart-rate data that was untrue of all of it — and the
        model repeated it back as a real limitation."""
        for i in range(30):
            day = self.as_of - timedelta(days=i)
            self.sample(day, 55, slug="resting_heart_rate", aggregation="discrete",
                        unit="count/min", source_name="Apple Watch")
            self.sample(day, 56, slug="resting_heart_rate", aggregation="discrete",
                        unit="count/min", source_name="iPhone")

        report = health_analysis.data_quality("resting_heart_rate")

        self.assertEqual(report["estimated_days"], 0)
        self.assertFalse(any("estimated" in note for note in report["notes"]))
        self.assertFalse(any("double-count" in note for note in report["notes"]))

    def test_a_summed_metric_is_still_flagged(self):
        """The same overlap on step count genuinely does double-count."""
        for i in range(30):
            day = self.as_of - timedelta(days=i)
            self.sample(day, 5_000, source_name="iPhone")
            self.sample(day, 5_000, source_name="Apple Watch")

        self.assertEqual(health_analysis.data_quality("step_count")["estimated_days"], 30)

    def test_gaps_are_measured_not_smoothed_over(self):
        for i in list(range(0, 5)) + list(range(12, 35)):
            self.rollup(self.as_of - timedelta(days=i), 10_000)

        report = health_analysis.data_quality("step_count")

        self.assertEqual(report["longest_gap_days"], 7)
        self.assertIn("Longest run of days with no data: 7.", report["notes"])

    def test_two_thin_periods_are_refused_rather_than_compared(self):
        """§13: do not compare two periods unless both have enough coverage.
        A percentage change between them looks like an answer and is not one."""
        self.rollup(self.as_of, 10_000)
        self.rollup(self.as_of - timedelta(days=20), 6_000)

        result = health_analysis.compare_periods(
            "step_count",
            self.as_of - timedelta(days=27),
            self.as_of - timedelta(days=14),
            self.as_of - timedelta(days=13),
            self.as_of,
        )

        self.assertFalse(result["comparable"])
        self.assertIsNone(result["change"])
        self.assertIn("too few recorded days", result["reason"])


class SleepTests(AnalysisTestCase):
    def night(self, morning: date, bed_hour=23, hours=7.5):
        """One night as HealthKit records it: interval samples, bucketed by the
        morning they end on.

        A bedtime after midnight falls on the same calendar date as the morning;
        an evening one falls on the day before. Getting this wrong in the
        fixture would land two nights in one bucket and quietly double a night.
        """
        bed_date = morning if bed_hour < 12 else morning - timedelta(days=1)
        start = datetime.combine(bed_date, time(bed_hour), tzinfo=SGT)
        end = start + timedelta(hours=hours)
        self.counter += 1
        Record.objects.create(
            id=f"sleep-{self.counter}",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.SLEEP,
            metric="HKCategoryTypeIdentifierSleepAnalysis",
            metric_slug="sleep_analysis",
            value=1,
            start=start,
            end=end,
            extra={"is_asleep": True, "duration_seconds": hours * 3600},
        )

    def test_bedtime_average_survives_midnight(self):
        """Clock minutes wrap, so averaging 23:50 with 00:10 naively gives
        lunchtime."""
        for i in range(6):
            self.night(self.as_of - timedelta(days=i), bed_hour=23 if i % 2 else 0)

        summary = health_analysis.sleep_summary(days=7)

        hour = int(summary["typical_bedtime"].split(":")[0])
        self.assertIn(hour, (23, 0), f"bedtime averaged to {summary['typical_bedtime']}")

    def test_consistency_measures_schedule_not_duration(self):
        """Seven hours every night, wildly different times — the duration is
        stable and the schedule is not."""
        for i in range(7):
            self.night(self.as_of - timedelta(days=i), bed_hour=[22, 2, 23, 1, 21, 3, 22][i])

        summary = health_analysis.sleep_summary(days=7)

        self.assertEqual(summary["average_hours"], 7.5)
        self.assertIn(summary["consistency"], ("variable", "highly variable"))

    def test_a_regular_schedule_reads_as_consistent(self):
        for i in range(7):
            self.night(self.as_of - timedelta(days=i), bed_hour=23)

        self.assertEqual(health_analysis.sleep_summary(days=7)["consistency"], "very consistent")


class AnomalyTests(AnalysisTestCase):
    def rhr(self, day: date, value: float):
        self.sample(day, value, slug="resting_heart_rate", aggregation="discrete", unit="count/min")

    def test_a_single_odd_day_is_not_an_anomaly(self):
        for i in range(35):
            self.rhr(self.as_of - timedelta(days=i), 55)
        self.rhr(self.as_of, 78)

        self.assertEqual(health_analysis.anomalies(), [])

    def test_a_sustained_shift_is_surfaced_without_a_cause(self):
        for i in range(7, 35):
            self.rhr(self.as_of - timedelta(days=i), 54 + (i % 3))
        for i in range(7):
            self.rhr(self.as_of - timedelta(days=i), 66)

        found = health_analysis.anomalies()

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["metric_slug"], "resting_heart_rate")
        self.assertEqual(found[0]["direction"], "above")
        self.assertGreaterEqual(found[0]["days_sustained"], 3)
        # The wording is an observation about the person's own range, never a
        # cause or a condition.
        self.assertIn("baseline", found[0]["observation"])


class AnalysisEndpointTests(AnalysisTestCase):
    def test_snapshot_requires_auth(self):
        self.assertIn(self.client.get("/v1/analysis/snapshot").status_code, (401, 403))

    def test_snapshot_reports_metrics_it_has_no_data_for(self):
        self.fill(7, 10_000)
        self.fill(28, 9_000, offset=7)

        body = self.client.get("/v1/analysis/snapshot", headers=self.auth()).json()

        slugs = [m["metric_slug"] for m in body["metrics"]]
        self.assertEqual(slugs, ["step_count"])
        self.assertIn("sleep_analysis", body["metrics_unavailable"])
        self.assertEqual(body["as_of"], self.as_of.isoformat())

    def test_a_metric_that_stopped_syncing_does_not_poison_the_whole_grade(self):
        """Real case: sleep stopped uploading five weeks ago while steps kept
        arriving. Taking the weakest grade across every metric dragged the whole
        snapshot to "insufficient", which makes the model hedge about numbers
        that were recorded perfectly well."""
        self.fill(7, 10_000)
        self.fill(28, 9_000, offset=7)
        # Sleep, healthy but old — outside both windows.
        old = self.as_of - timedelta(days=45)
        Record.objects.create(
            id="sleep-old", device=self.device, batch=self.batch,
            kind=Record.Kind.SLEEP, metric="HKCategoryTypeIdentifierSleepAnalysis",
            metric_slug="sleep_analysis", value=1,
            start=at(old, 23), end=at(old + timedelta(days=1), 7),
            extra={"is_asleep": True, "duration_seconds": 28_800},
        )

        body = self.client.get("/v1/analysis/snapshot", headers=self.auth()).json()

        self.assertEqual(body["overall_confidence"], "high")
        stale = {item["metric_slug"]: item for item in body["metrics_not_syncing"]}
        self.assertIn("sleep_analysis", stale)
        # The useful fact is *when it stopped*, not that it is missing.
        self.assertEqual(stale["sleep_analysis"]["days_since"], 44)

    def test_a_metric_with_data_is_not_called_stale(self):
        self.fill(7, 10_000)
        self.fill(28, 9_000, offset=7)

        body = self.client.get("/v1/analysis/snapshot", headers=self.auth()).json()

        self.assertEqual(body["metrics_not_syncing"], [])

    def test_trend_rejects_an_unknown_metric(self):
        response = self.client.get("/v1/analysis/trend?metric=nonsense", headers=self.auth())
        self.assertEqual(response.status_code, 400)
        self.assertIn("unknown metric", response.json()["detail"])

    def test_goals_round_trip_with_measured_progress(self):
        self.fill(7, 12_000)

        created = self.client.post(
            "/v1/analysis/goals",
            data={"metric_slug": "step_count", "target_value": 10_000, "cadence": "daily"},
            content_type="application/json",
            headers=self.auth(),
        )
        self.assertEqual(created.status_code, 200)

        body = self.client.get("/v1/analysis/goals", headers=self.auth()).json()
        goal = body["goals"][0]
        self.assertEqual(goal["target_value"], 10_000)
        self.assertEqual(goal["progress"]["days_met"], 7)
        self.assertEqual(goal["progress"]["current_streak_days"], 7)

    def test_goal_rejects_an_unanalysable_metric(self):
        response = self.client.post(
            "/v1/analysis/goals",
            data={"metric_slug": "dietary_sugar", "target_value": 10},
            content_type="application/json",
            headers=self.auth(),
        )
        self.assertEqual(response.status_code, 400)
