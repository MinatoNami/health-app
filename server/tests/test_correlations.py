"""Tests for the correlation engine and pattern discovery.

The engine's job is not to find relationships — with seventy-eight possible pairs
and a 5% threshold, finding them is trivial and about four of them will be
imaginary. Its job is to find them and be right, so most of these tests feed it
data with a known answer and check it does not overclaim:

* independent noise must come back with nothing,
* a planted relationship must be recovered with the right sign,
* a thin overlap must be refused rather than estimated,
* and one marginal hit among many questions must not survive correction.
"""

import random
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from ingest import correlations, health_analysis, patterns
from ingest.llm import tools as llm_tools
from ingest.models import ApiToken, Batch, Device, Record

SGT = ZoneInfo("Asia/Singapore")


def at(day: date, hour: int = 12) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=SGT)


class StatisticsTests(TestCase):
    """The arithmetic, with no database involved."""

    def test_a_perfect_ranking_is_one(self):
        self.assertEqual(correlations.spearman([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 1.0)
        self.assertEqual(correlations.spearman([1, 2, 3, 4, 5], [50, 40, 30, 20, 10]), -1.0)

    def test_it_reads_a_curve_a_straight_line_would_miss(self):
        """Rank correlation, not Pearson: the relationship here is perfect and
        monotonic, and nothing about it is a straight line."""
        xs = [1, 2, 3, 4, 5, 6, 7]
        ys = [x**3 for x in xs]
        self.assertEqual(correlations.spearman(xs, ys), 1.0)

    def test_ties_are_ranked_equally_rather_than_arbitrarily(self):
        """Workout minutes are zero on most days. Breaking those ties by
        position would invent an ordering the data does not have."""
        self.assertEqual(correlations._ranks([0, 0, 0, 5]), [2.0, 2.0, 2.0, 4.0])
        self.assertEqual(correlations._ranks([3, 1, 1, 3]), [3.5, 1.5, 1.5, 3.5])

    def test_a_flat_series_correlates_with_nothing(self):
        self.assertIsNone(correlations.spearman([5, 5, 5, 5, 5], [1, 2, 3, 4, 5]))

    def test_a_weak_correlation_over_few_points_is_not_significant(self):
        self.assertGreater(correlations.p_value(0.3, 14), 0.05)
        self.assertLess(correlations.p_value(0.6, 60), 0.001)

    def test_holm_stops_at_the_first_failure(self):
        """One marginal hit among fourteen questions is what you expect from
        noise, and must not be reported as a finding."""
        p_values = [0.003, 0.03, 0.2, 0.5] + [0.6] * 10
        flags = correlations.holm(p_values)

        # 0.003 clears 0.05/14 = 0.0036; 0.03 does not clear 0.05/13, and Holm
        # stops at the first failure.
        self.assertEqual(flags[0], True)
        self.assertEqual(flags[1:], [False] * 13)

    def test_a_lone_question_is_judged_on_its_own(self):
        self.assertEqual(correlations.holm([0.03]), [True])

    def test_untestable_pairs_do_not_dilute_the_correction(self):
        """A pair skipped for want of data was not a question asked, so it must
        not make the surviving ones harder to reach."""
        self.assertEqual(correlations.holm([0.04, None, None]), [True, False, False])


class CorrelationTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.token, self.raw = ApiToken.issue("correlation-test")
        self.device = Device.objects.create(device_id="correlation-device")
        self.batch = Batch.objects.create(idempotency_key="corr.ndjson", device=self.device)
        self.as_of = health_analysis.last_complete_day()
        self.counter = 0

    def auth(self):
        return {"authorization": f"Bearer {self.raw}"}

    def quantity(self, day: date, slug: str, value: float, unit="count", agg="cumulative"):
        self.counter += 1
        return Record.objects.create(
            id=f"q-{self.counter}",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.QUANTITY,
            metric=f"HKQuantityTypeIdentifier{slug}",
            metric_slug=slug,
            unit=unit,
            aggregation=agg,
            value=value,
            start=at(day),
            end=at(day),
        )

    def hrv(self, day: date, ms: float):
        self.quantity(day, "heart_rate_variability_sdnn", ms, unit="ms", agg="discrete")

    def steps(self, day: date, count: float):
        self.quantity(day, "step_count", count)

    def night(self, morning: date, hours: float, bed_hour=23):
        """One night, filed under the morning it ends on."""
        bed_date = morning if bed_hour < 12 else morning - timedelta(days=1)
        start = datetime.combine(bed_date, time(bed_hour), tzinfo=SGT)
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
            end=start + timedelta(hours=hours),
            extra={"is_asleep": True, "duration_seconds": hours * 3600},
        )

    def find(self, report: dict, pair: str) -> dict:
        return next(p for p in report["all_pairs"] if p["pair"] == pair)


class DiscoveryTests(CorrelationTestCase):
    def test_independent_noise_produces_no_findings(self):
        """The test that matters most. Random sleep against random HRV over three
        months is fourteen chances to report something, and the answer is none."""
        generator = random.Random(20260807)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            self.night(day, generator.uniform(5.5, 8.5))
            self.hrv(day, generator.uniform(35, 60))
            self.steps(day, generator.uniform(4_000, 14_000))
            self.quantity(day, "resting_heart_rate", generator.uniform(52, 62),
                          unit="count/min", agg="discrete")

        report = correlations.discover(days=90)

        self.assertEqual(report["associations_found"], 0, report["associations"])
        self.assertGreater(report["pairs_tested"], 3)

    def test_a_planted_relationship_is_recovered_with_the_right_sign(self):
        generator = random.Random(11)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            hours = generator.uniform(5.0, 9.0)
            self.night(day, hours)
            # HRV rises with sleep, with real noise on top.
            self.hrv(day, 20 + hours * 4 + generator.uniform(-2, 2))

        report = correlations.discover(days=90)
        pair = self.find(report, "sleep_hours->hrv")

        self.assertTrue(pair["significant"])
        self.assertGreater(pair["rho"], 0.7)
        self.assertEqual(report["associations"][0]["pair"], "sleep_hours->hrv")
        self.assertEqual(report["associations"][0]["direction"], "together")

    def test_an_inverse_relationship_keeps_its_sign(self):
        generator = random.Random(12)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            hours = generator.uniform(5.0, 9.0)
            self.night(day, hours)
            self.quantity(day, "resting_heart_rate", 75 - hours * 2 + generator.uniform(-1, 1),
                          unit="count/min", agg="discrete")

        pair = self.find(correlations.discover(days=90), "sleep_hours->resting_hr")

        self.assertLess(pair["rho"], -0.7)
        self.assertEqual(pair["direction"], "opposite")

    def test_the_contrast_is_reported_in_units_a_person_can_check(self):
        """A rho of 0.8 tells nobody anything. "48 ms on your longest nights
        against 41 on your shortest" is the same fact, checkable."""
        generator = random.Random(13)
        for offset in range(60):
            day = self.as_of - timedelta(days=offset)
            hours = 5.0 + (offset % 4)
            self.night(day, hours)
            self.hrv(day, 30 + hours * 3 + generator.uniform(-1, 1))

        pair = self.find(correlations.discover(days=60), "sleep_hours->hrv")
        contrast = pair["contrast"]

        self.assertGreater(contrast["outcome_on_high_days"], contrast["outcome_on_low_days"])
        self.assertGreater(contrast["driver_high_mean"], contrast["driver_low_mean"])
        self.assertIn("ms", contrast["description"])
        self.assertIn("h", contrast["description"])

    def test_a_thin_overlap_is_refused_rather_than_estimated(self):
        for offset in range(6):
            day = self.as_of - timedelta(days=offset)
            self.night(day, 7.0 + offset * 0.2)
            self.hrv(day, 40 + offset)

        pair = self.find(correlations.discover(days=90), "sleep_hours->hrv")

        self.assertFalse(pair["significant"])
        self.assertIsNone(pair["rho"])
        self.assertIn("at least 14", pair["reason"])

    def test_a_lagged_pair_aligns_the_day_after(self):
        """Today's steps against tonight's sleep, which is filed under tomorrow
        morning. Getting this backwards would test the night before the walk."""
        for offset in range(60):
            day = self.as_of - timedelta(days=offset)
            # Steps alternate high/low; sleep follows the *previous* day's steps.
            self.steps(day, 15_000 if offset % 2 == 0 else 5_000)
        for offset in range(60):
            day = self.as_of - timedelta(days=offset)
            # A day whose preceding day was high-step sleeps longer.
            preceding_was_high = (offset + 1) % 2 == 0
            self.night(day, 8.2 if preceding_was_high else 6.4)

        pair = self.find(correlations.discover(days=60), "steps->sleep_hours+1d")

        self.assertEqual(pair["strength"], "strong")
        self.assertTrue(pair["significant"])

    def test_weight_is_paired_by_week_not_by_day(self):
        """Daily weight against daily steps mostly measures hydration. Weeks are
        the timescale weight actually answers on."""
        generator = random.Random(14)
        for offset in range(84):
            day = self.as_of - timedelta(days=offset)
            week = offset // 7
            self.steps(day, 6_000 + week * 900 + generator.uniform(-200, 200))
            self.quantity(day, "body_mass", 84.0 - week * 0.35 + generator.uniform(-0.1, 0.1),
                          unit="kg", agg="discrete")

        pair = self.find(correlations.discover(days=84), "steps->weight")

        self.assertEqual(pair["resolution"], "week")
        self.assertEqual(pair["point_unit"], "weeks")
        self.assertLessEqual(pair["paired_points"], 13)
        self.assertLess(pair["rho"], 0)

    def test_a_week_missing_most_of_its_days_does_not_stand_for_a_week(self):
        weekly = correlations._to_weeks(
            {self.as_of - timedelta(days=offset): 10.0 for offset in range(3)}
        )
        self.assertEqual(weekly, {})

    def test_every_pair_tested_is_reported_not_just_the_survivors(self):
        """Reporting only what survived would turn one finding out of fourteen
        questions into "the relationships in your data"."""
        generator = random.Random(15)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            hours = generator.uniform(5, 9)
            self.night(day, hours)
            self.hrv(day, 20 + hours * 4 + generator.uniform(-2, 2))

        report = correlations.discover(days=90)

        self.assertEqual(len(report["all_pairs"]), len(correlations.CANDIDATES))
        self.assertGreater(report["pairs_skipped"], 0)
        self.assertTrue(any(not p["significant"] for p in report["all_pairs"]))

    def test_every_association_carries_a_confounder_and_no_cause(self):
        generator = random.Random(16)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            hours = generator.uniform(5, 9)
            self.night(day, hours)
            self.hrv(day, 20 + hours * 4 + generator.uniform(-2, 2))

        report = correlations.discover(days=90)

        for association in report["associations"]:
            self.assertTrue(association["confounders"], association["pair"])
        self.assertTrue(any("shown to cause the other" in limit for limit in report["limitations"]))
        self.assertIn("optimistic", " ".join(report["limitations"]))


class PatternTests(CorrelationTestCase):
    def test_a_real_weekday_dip_is_found_and_named(self):
        for offset in range(84):
            day = self.as_of - timedelta(days=offset)
            # Tuesdays are short nights; everything else is steady.
            self.night(day, 5.0 if day.weekday() == 1 else 7.6)

        report = patterns.discover(days=84)
        sleep = [p for p in report["patterns"] if p["metric_slug"] == "sleep_analysis"]

        self.assertTrue(sleep)
        tuesday = next(p for p in sleep if p["group"] == "Tuesdays")
        self.assertEqual(tuesday["direction"], "lower")
        self.assertEqual(tuesday["significance"], "notable")
        self.assertIn("Tuesdays", tuesday["statement"])
        self.assertIn("against this person's own day-to-day variation", tuesday["statement"])

    def test_a_steady_week_produces_no_pattern(self):
        generator = random.Random(17)
        for offset in range(84):
            self.night(self.as_of - timedelta(days=offset), generator.uniform(7.2, 7.6))

        report = patterns.discover(days=84)

        self.assertEqual(
            [p for p in report["patterns"] if p["metric_slug"] == "sleep_analysis"], []
        )

    def test_the_weekend_split_is_reported_in_its_own_right(self):
        for offset in range(84):
            day = self.as_of - timedelta(days=offset)
            self.steps(day, 3_000 if day.weekday() >= 5 else 12_000)

        report = patterns.discover(days=84)
        weekend = next(
            p for p in report["patterns"]
            if p["metric_slug"] == "step_count" and p["group"] == "weekends"
        )

        self.assertEqual(weekend["direction"], "lower")
        self.assertEqual(weekend["group_mean"], 3_000)
        self.assertEqual(weekend["rest_mean"], 12_000)

    def test_only_the_strongest_weekday_is_reported_per_metric(self):
        """Six mildly unusual weekdays is a horoscope, not a finding."""
        for offset in range(84):
            day = self.as_of - timedelta(days=offset)
            hours = {0: 5.0, 1: 5.2, 2: 7.5, 3: 7.5, 4: 7.5, 5: 9.5, 6: 9.4}[day.weekday()]
            self.night(day, hours)

        report = patterns.discover(days=84)
        weekdays = [
            p for p in report["patterns"]
            if p["metric_slug"] == "sleep_analysis" and p["group"] != "weekends"
        ]

        self.assertLessEqual(len(weekdays), 1)

    def test_too_few_weeks_is_skipped_with_a_reason(self):
        for offset in range(5):
            self.night(self.as_of - timedelta(days=offset), 7.5)

        report = patterns.discover(days=90)
        skipped = {item["metric_slug"]: item["reason"] for item in report["metrics_skipped"]}

        self.assertIn("sleep_analysis", skipped)
        self.assertIn("only 5 day(s)", skipped["sleep_analysis"])

    def test_it_never_calls_a_pattern_statistically_significant(self):
        """The word would be a claim seven weekdays across six metrics cannot
        carry, and a reader would take it as one."""
        for offset in range(84):
            day = self.as_of - timedelta(days=offset)
            self.night(day, 5.0 if day.weekday() == 1 else 7.6)

        report = patterns.discover(days=84)
        text = " ".join(p["statement"] for p in report["patterns"]) + str(report["method"])

        self.assertNotIn("statistically significant", text)
        self.assertIn("No p-values", report["method"]["test"])


class AnalysisToolTests(CorrelationTestCase):
    def test_both_tools_are_dispatchable_and_clamped(self):
        result = llm_tools.call("get_correlations", {"days": 9_000})
        self.assertEqual(result["window_days"], correlations.MAX_DAYS)

        result = llm_tools.call("get_patterns", {"days": 9_000})
        self.assertEqual(result["window_days"], patterns.MAX_DAYS)

    def test_the_correlation_tool_trims_the_pair_list_but_keeps_the_count(self):
        generator = random.Random(18)
        for offset in range(90):
            day = self.as_of - timedelta(days=offset)
            hours = generator.uniform(5, 9)
            self.night(day, hours)
            self.hrv(day, 20 + hours * 4 + generator.uniform(-2, 2))

        result = llm_tools.call("get_correlations", {})

        self.assertEqual(len(result["all_pairs"]), len(correlations.CANDIDATES))
        # Trimmed to the fields a model needs, not fourteen full objects.
        self.assertNotIn("contrast", result["all_pairs"][0])
        self.assertIn("contrast", result["associations"][0])

    def test_the_endpoints_require_auth_and_answer(self):
        for path in ("/v1/analysis/correlations", "/v1/analysis/patterns"):
            self.assertIn(self.client.get(path).status_code, (401, 403))
            body = self.client.get(f"{path}?days=90", headers=self.auth()).json()
            self.assertEqual(body["window_days"], 90)

    def test_the_endpoints_reject_a_days_value_that_is_not_a_number(self):
        for path in ("/v1/analysis/correlations", "/v1/analysis/patterns"):
            response = self.client.get(f"{path}?days=heaps", headers=self.auth())
            self.assertEqual(response.status_code, 400)
