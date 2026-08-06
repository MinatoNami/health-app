"""Tests for the nutrition layer.

Nutrition is the only signal in this system that a person writes down rather
than a sensor recording, and every test here is about one of the three ways that
misleads:

* a day nobody logged looks exactly like a day of eating nothing,
* a log abandoned after breakfast looks exactly like a very light day,
* and the same nutrient arrives in kilograms from one HealthKit type and grams
  from another, so the totals are a thousandfold apart with nothing to say which.

The arithmetic is the easy part. What is being tested is the refusals.
"""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from ingest import freshness, health_analysis, nutrition, safety
from ingest.llm import tools as llm_tools
from ingest.models import ApiToken, Batch, Device, Record

SGT = ZoneInfo("Asia/Singapore")


def at(day: date, hour: int = 12) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=SGT)


class NutritionTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.token, self.raw = ApiToken.issue("nutrition-test")
        self.device = Device.objects.create(device_id="nutrition-device")
        self.batch = Batch.objects.create(idempotency_key="nutrition.ndjson", device=self.device)
        self.as_of = health_analysis.last_complete_day()
        self.counter = 0

    def auth(self):
        return {"authorization": f"Bearer {self.raw}"}

    def nutrient(self, day: date, slug: str, value: float, unit: str | None = None, hour=12):
        """One logged entry, the way a food app writes it."""
        self.counter += 1
        spec = nutrition.NUTRIENTS.get(slug)
        return Record.objects.create(
            id=f"food-{self.counter}",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.QUANTITY,
            metric=f"HKQuantityTypeIdentifier{slug}",
            metric_slug=slug,
            unit=unit if unit is not None else (spec.unit if spec else ""),
            aggregation="cumulative",
            value=value,
            start=at(day, hour),
            end=at(day, hour),
            source_name="MyFitnessPal",
        )

    def meal_day(self, day: date, kcal: float, protein=110.0, carbs=250.0, fat=80.0, meals=3):
        """A day's eating, split across entries the way a diary accumulates."""
        for index in range(meals):
            self.nutrient(day, "dietary_energy_consumed", kcal / meals, hour=8 + index * 4)
        self.nutrient(day, "dietary_protein", protein)
        self.nutrient(day, "dietary_carbohydrates", carbs)
        self.nutrient(day, "dietary_fat_total", fat)

    def burned(self, day: date, active=600.0, resting=1700.0):
        self.counter += 1
        for slug, value in (
            ("active_energy_burned", active),
            ("basal_energy_burned", resting),
        ):
            self.counter += 1
            Record.objects.create(
                id=f"burn-{slug}-{day.isoformat()}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.QUANTITY,
                metric=f"HKQuantityTypeIdentifier{slug}",
                metric_slug=slug,
                unit="kcal",
                aggregation="cumulative",
                value=value,
                start=at(day),
                end=at(day),
            )


class UnitTests(NutritionTestCase):
    """The kilogram problem, which is in the production database right now.

    `UnitResolver` picks a unit per HealthKit type by trying a ladder of
    candidates, and for any nutrient without an explicit preference the first
    compatible mass unit wins — kilograms. Saturated fat and vitamin C really are
    stored in kg here, and a gram row landing beside one of them is a total three
    orders of magnitude wrong.
    """

    def test_a_nutrient_logged_in_kilograms_is_reported_in_grams(self):
        # 22 g of saturated fat, as the phone actually uploaded it.
        self.nutrient(self.as_of, "dietary_fat_saturated", 0.022, unit="kg")
        self.nutrient(self.as_of, "dietary_energy_consumed", 2200)

        values = health_analysis.day_values(
            "dietary_fat_saturated", self.as_of, self.as_of
        )

        self.assertEqual(len(values), 1)
        self.assertAlmostEqual(values[0].value, 22.0, places=6)

    def test_micrograms_and_milligrams_do_not_add_up_raw(self):
        """Vitamin C in kg from one source and mg from another. Summing `value`
        in SQL — which is what every other metric does — gives 90.00009."""
        self.nutrient(self.as_of, "dietary_energy_consumed", 2200)
        self.nutrient(self.as_of, "dietary_vitamin_c", 0.00009, unit="kg")  # 90 mg
        self.nutrient(self.as_of, "dietary_vitamin_c", 30, unit="mg")

        values = health_analysis.day_values("dietary_vitamin_c", self.as_of, self.as_of)

        self.assertAlmostEqual(values[0].value, 120.0, places=6)

    def test_an_unconvertible_unit_is_surfaced_rather_than_guessed_at(self):
        """A nutrient arriving as a bare count is a bug to fix, not a number to
        add to a total in whatever unit is convenient."""
        self.nutrient(self.as_of, "dietary_protein", 40, unit="g")
        self.nutrient(self.as_of, "dietary_protein", 3, unit="count")

        start, end = health_analysis._bounds(self.as_of, self.as_of, None)
        payload = nutrition.daily_series("dietary_protein", start, end)

        self.assertAlmostEqual(payload["points"][0]["value"], 40.0, places=6)
        self.assertEqual(payload["unconvertible_samples"], [{"unit": "count", "samples": 1}])

    def test_energy_arriving_in_kilojoules_is_converted(self):
        self.nutrient(self.as_of, "dietary_energy_consumed", 8368, unit="kJ")

        values = health_analysis.day_values(
            "dietary_energy_consumed", self.as_of, self.as_of
        )

        self.assertAlmostEqual(values[0].value, 2000.0, places=0)

    def test_a_unit_that_is_not_a_unit_of_the_same_kind_is_refused(self):
        self.assertIsNone(nutrition.convert(5, "kcal", "g"))
        self.assertIsNone(nutrition.convert(5, "count", "mg"))
        self.assertEqual(nutrition.convert(2, "kg", "g"), 2000)
        self.assertEqual(nutrition.convert(1000, "mL", "L"), 1)


class IncompleteLogTests(NutritionTestCase):
    """Breakfast logged, lunch forgotten.

    This is the failure that produces a health claim out of nothing but
    record-keeping: a 300 kcal Tuesday averaged in with four real days reports a
    collapse in eating that never happened.
    """

    def test_an_abandoned_log_is_not_a_light_day(self):
        for offset in range(4):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)
        self.nutrient(self.as_of - timedelta(days=4), "dietary_energy_consumed", 300)

        summary = health_analysis.nutrition_summary(days=7)

        self.assertEqual(summary["days_logged"], 5)
        self.assertEqual(summary["days_fully_logged"], 4)
        self.assertEqual(summary["days_partially_logged"], 1)
        # The average is of the four real days, not of five including a breakfast.
        self.assertEqual(summary["energy"]["average_per_logged_day"], 2400)
        self.assertTrue(
            any("incomplete log" in note for note in summary["limitations"]),
            summary["limitations"],
        )

    def test_a_partial_day_is_still_shown_so_the_exclusion_is_visible(self):
        """Dropping it silently would leave a summary claiming four logged days
        in a window where five had something in them."""
        for offset in range(4):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)
        self.nutrient(self.as_of - timedelta(days=4), "dietary_energy_consumed", 300)

        days = health_analysis.nutrition_summary(days=7)["days"]

        partial = [d for d in days if not d["complete_log"]]
        self.assertEqual(len(partial), 1)
        self.assertEqual(partial[0]["energy_kcal"], 300)
        # Nothing from that day is offered as a total to reason about.
        self.assertEqual(partial[0]["totals"], {})

    def test_a_partial_day_does_not_reach_the_baseline_comparison(self):
        """Every consumer of day_values gets the same filtering, or the summary
        and the baseline comparison in one payload would disagree."""
        for offset in range(35):
            self.meal_day(self.as_of - timedelta(days=offset), 2400, meals=1)
        # Replace two days in the current window with abandoned logs.
        for offset in (1, 2):
            day = self.as_of - timedelta(days=offset)
            Record.objects.filter(
                metric_slug="dietary_energy_consumed", start__date=day
            ).delete()
            self.nutrient(day, "dietary_energy_consumed", 250)

        comparison = health_analysis.compare_to_baseline("dietary_energy_consumed")

        self.assertEqual(comparison["current"]["valid_days"], 5)
        self.assertEqual(comparison["current"]["value"], 2400)
        self.assertEqual(comparison["change"], 0)

    def test_macros_from_a_partial_day_are_left_out_too(self):
        """Protein from a half-finished Tuesday is as misleading as the energy
        figure it arrived with."""
        for offset in range(3):
            self.meal_day(self.as_of - timedelta(days=offset), 2400, protein=120)
        partial_day = self.as_of - timedelta(days=3)
        self.nutrient(partial_day, "dietary_energy_consumed", 400)
        self.nutrient(partial_day, "dietary_protein", 15)

        summary = health_analysis.nutrition_summary(days=7)
        protein = next(n for n in summary["nutrients"] if n["nutrient"] == "dietary_protein")

        self.assertEqual(protein["days_counted"], 3)
        self.assertEqual(protein["average_per_logged_day"], 120)


class CoverageTests(NutritionTestCase):
    def test_days_with_no_log_are_unknown_rather_than_zero(self):
        for offset in range(3):
            self.meal_day(self.as_of - timedelta(days=offset), 2100)

        summary = health_analysis.nutrition_summary(days=14)

        self.assertEqual(summary["days_logged"], 3)
        self.assertEqual(summary["days_not_logged"], 11)
        self.assertEqual(summary["energy"]["days_counted"], 3)
        self.assertTrue(
            any("unknown, not days without food" in note for note in summary["limitations"]),
            summary["limitations"],
        )

    def test_nothing_logged_says_so_instead_of_averaging_nothing(self):
        summary = health_analysis.nutrition_summary(days=14)

        self.assertEqual(summary["days_logged"], 0)
        self.assertIsNone(summary["energy"]["average_per_logged_day"])
        self.assertEqual(summary["confidence"], "insufficient")
        self.assertIn("nothing was logged", summary["confidence_reason"])

    def test_a_new_food_log_is_graded_thin_rather_than_refused(self):
        """Somebody who started logging on Monday has a full current window and
        no baseline at all. "Insufficient" for ever would be useless; a graded
        answer that names the coverage is not."""
        for offset in range(5):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        summary = health_analysis.nutrition_summary(days=7)

        self.assertEqual(summary["confidence"], "moderate")
        self.assertIn("5 of 7 days", summary["confidence_reason"])
        self.assertEqual(summary["energy_vs_baseline"]["confidence"], "insufficient")

    def test_two_full_days_is_below_the_floor(self):
        for offset in range(2):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        summary = health_analysis.nutrition_summary(days=7)

        self.assertEqual(summary["confidence"], "insufficient")
        self.assertIn("at least 3", summary["confidence_reason"])

    def test_the_self_reported_caveat_leads_the_data_quality_notes(self):
        for offset in range(10):
            self.meal_day(self.as_of - timedelta(days=offset), 2300)

        report = health_analysis.data_quality("dietary_energy_consumed", days=14)

        self.assertIn("self-reported", report["notes"][0])
        self.assertIn("not the same as nothing consumed", report["notes"][0])

    def test_hand_typed_food_is_not_treated_as_a_data_problem(self):
        """HealthKit's user-entered flag is a warning on a metric a scale should
        have written and a tautology on a food diary. Applying the sensor rule
        pinned every nutrient at "low" for ever."""
        for offset in range(10):
            day = self.as_of - timedelta(days=offset)
            record = self.nutrient(day, "dietary_energy_consumed", 2200)
            Record.objects.filter(pk=record.pk).update(metadata={"HKWasUserEntered": True})

        report = health_analysis.data_quality("dietary_energy_consumed", days=14)
        comparison = health_analysis.compare_to_baseline("dietary_energy_consumed")

        self.assertFalse(any("entered by hand" in note for note in report["notes"]))
        self.assertNotIn("by hand", comparison["confidence_reason"])

    def test_the_confidence_reason_says_logged_not_recorded(self):
        """"4 of 7 days have data" and "4 of 7 days were logged" grade the same
        and mean different things to the person reading it."""
        for offset in range(4):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)
        for offset in range(7, 35):
            self.meal_day(self.as_of - timedelta(days=offset), 2400, meals=1)

        comparison = health_analysis.compare_to_baseline("dietary_energy_consumed")

        self.assertIn("were logged", comparison["confidence_reason"])


class EnergyBalanceTests(NutritionTestCase):
    def test_intake_is_compared_with_expenditure_over_the_same_days(self):
        for offset in range(5):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day, active=600, resting=1700)
        # Expenditure recorded well outside the logged days must not be averaged
        # in: it would produce a deficit out of a mismatch in the windows.
        for offset in range(5, 14):
            self.burned(self.as_of - timedelta(days=offset), active=100, resting=1700)

        balance = health_analysis.nutrition_summary(days=14)["energy_balance"]

        self.assertEqual(balance["days_compared"], 5)
        self.assertEqual(balance["intake_kcal_per_day"], 2400)
        self.assertEqual(balance["expenditure_kcal_per_day"], 2300)
        self.assertEqual(balance["difference_kcal_per_day"], 100)

    def test_a_day_without_resting_energy_is_not_compared(self):
        """Active energy alone is a few hundred kilocalories, so intake would
        tower over "expenditure" every day of the week."""
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.counter += 1
            Record.objects.create(
                id=f"active-only-{offset}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.QUANTITY,
                metric="HKQuantityTypeIdentifierActiveEnergyBurned",
                metric_slug="active_energy_burned",
                unit="kcal",
                aggregation="cumulative",
                value=500,
                start=at(day),
                end=at(day),
            )

        balance = health_analysis.nutrition_summary(days=7)["energy_balance"]

        self.assertEqual(balance["days_compared"], 0)
        self.assertIsNone(balance["difference_kcal_per_day"])
        self.assertIn("cannot be put side by side", balance["reason"])

    def test_expenditure_is_labelled_an_estimate(self):
        """§7: never present energy figures as exact. They are a model's output,
        not a measurement."""
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day)

        balance = health_analysis.nutrition_summary(days=7)["energy_balance"]

        self.assertIn("estimate", balance["note"])
        # The field names carry it too, so a model quoting one cannot drop the
        # caveat by accident.
        self.assertIn("active_kcal_per_day_estimated", balance)
        self.assertIn("resting_kcal_per_day_estimated", balance)

    def weigh(self, day: date, kg: float):
        self.counter += 1
        Record.objects.create(
            id=f"weight-{self.counter}",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.QUANTITY,
            metric="HKQuantityTypeIdentifierBodyMass",
            metric_slug="body_mass",
            unit="kg",
            aggregation="discrete",
            value=kg,
            start=at(day),
            end=at(day),
        )

    def test_measured_weight_is_reported_beside_the_estimated_arithmetic(self):
        """On real data, subtracting two estimates said "898 kcal short a day"
        while the scale was going up. Whichever is right, the model must be given
        the measured number, and told it is the stronger one."""
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day, active=700, resting=2600)
        for offset in range(0, 42, 2):
            self.weigh(self.as_of - timedelta(days=offset), 82.0 - offset * 0.06)

        summary = health_analysis.nutrition_summary(days=7)

        self.assertLess(summary["energy_balance"]["difference_kcal_per_day"], 0)
        weight = summary["weight_context"]
        self.assertEqual(weight["direction"], "rising")
        self.assertGreater(weight["kg_per_week"], 0)
        self.assertIn("better evidence", weight["note"])

    def test_a_slope_with_no_direction_explains_itself(self):
        """A bare 0.42 kg/week beside direction "unclear" reads as a finding while
        the field that should qualify it says nothing."""
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day)
        for offset in (0, 10, 20, 30, 40):
            self.weigh(self.as_of - timedelta(days=offset), 80.0 + offset * 0.05)

        weight = health_analysis.nutrition_summary(days=7)["weight_context"]

        self.assertEqual(weight["direction"], "unclear")
        self.assertIn("too few", weight["direction_reason"])
        self.assertIn("not a trend", weight["direction_reason"])

    def test_no_weight_data_leaves_the_anchor_out_rather_than_guessing(self):
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day)

        self.assertIsNone(health_analysis.nutrition_summary(days=7)["weight_context"])

    def test_macro_share_of_energy_is_computed_here_not_left_to_the_model(self):
        for offset in range(5):
            self.meal_day(self.as_of - timedelta(days=offset), 2000, protein=100, carbs=200, fat=67)

        nutrients = health_analysis.nutrition_summary(days=7)["nutrients"]
        by_slug = {n["nutrient"]: n for n in nutrients}

        # 100 g protein at 4 kcal/g is 400 of 2,000 kcal.
        self.assertEqual(by_slug["dietary_protein"]["share_of_logged_energy_pct"], 20.0)
        self.assertEqual(by_slug["dietary_carbohydrates"]["share_of_logged_energy_pct"], 40.0)
        # Fibre carries no energy figure, so it is not given a share.
        self.assertNotIn("share_of_logged_energy_pct", by_slug.get("dietary_fiber", {}))


class SnapshotTests(NutritionTestCase):
    def test_a_thin_food_log_does_not_drag_the_whole_snapshot_grade(self):
        """The regression this placement exists to prevent. A food log is days
        old the week somebody starts one; as a headline metric its "insufficient"
        grade becomes the snapshot's grade, and then every answer about steps
        arrives hedged about coverage that is perfectly good."""
        for offset in range(35):
            day = self.as_of - timedelta(days=offset)
            self.counter += 1
            Record.objects.create(
                id=f"stat:step_count:{day.isoformat()}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.STATISTIC,
                metric="HKQuantityTypeIdentifierStepCount",
                metric_slug="step_count",
                unit="count",
                aggregation="cumulative",
                value=10_000,
                start=at(day),
                end=at(day),
            )
        for offset in range(3):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        snapshot = health_analysis.snapshot()

        self.assertEqual(snapshot["overall_confidence"], "high")
        self.assertNotIn(
            "dietary_energy_consumed", [m["metric_slug"] for m in snapshot["metrics"]]
        )
        self.assertEqual(snapshot["nutrition"]["days_fully_logged"], 3)

    def test_the_snapshot_omits_nutrition_entirely_when_nothing_is_logged(self):
        snapshot = health_analysis.snapshot()
        self.assertIsNone(snapshot["nutrition"])

    def test_a_paused_food_log_does_not_raise_an_alert(self):
        """The freshness check exists to catch a signal that died. Somebody who
        stopped writing their lunch down has not broken anything, and an alert
        about it is how the alert that matters gets muted."""
        stale_day = self.as_of - timedelta(days=10)
        self.meal_day(stale_day, 2400)
        self.counter += 1
        Record.objects.create(
            id="stale-steps",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.QUANTITY,
            metric="HKQuantityTypeIdentifierStepCount",
            metric_slug="step_count",
            unit="count",
            aggregation="cumulative",
            value=9_000,
            start=at(stale_day),
            end=at(stale_day),
        )

        slugs = [finding.metric_slug for finding in freshness.check()]

        self.assertIn("step_count", slugs)
        self.assertNotIn("dietary_energy_consumed", slugs)


class NutritionToolTests(NutritionTestCase):
    def test_the_tool_returns_the_day_counts_a_model_gets_wrong_alone(self):
        for offset in range(4):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        result = llm_tools.call("get_nutrition_summary", {"days": 14})

        self.assertEqual(result["days_fully_logged"], 4)
        self.assertEqual(result["days_not_logged"], 10)
        self.assertIn("limitations", result)

    def test_an_absurd_window_is_clamped(self):
        result = llm_tools.call("get_nutrition_summary", {"days": 5_000})
        self.assertEqual(result["window_days"], 90)

    def test_a_nutrient_is_trendable_by_slug(self):
        for offset in range(35):
            self.meal_day(self.as_of - timedelta(days=offset), 2400, protein=100, meals=1)

        result = llm_tools.call("get_metric_trend", {"metric": "dietary_protein", "days": 30})

        self.assertEqual(result["unit"], "g")
        self.assertEqual(result["baseline_comparison"]["current"]["value"], 100)

    def test_the_overview_carries_nutrition_without_the_daily_table(self):
        for offset in range(4):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        overview = llm_tools.call("get_health_overview", {})

        self.assertIn("nutrition", overview)
        self.assertNotIn("days", overview["nutrition"])
        self.assertEqual(overview["nutrition"]["days_fully_logged"], 4)


class NutritionSafetyTests(NutritionTestCase):
    def test_a_question_about_eating_carries_the_no_targets_rule(self):
        for offset in range(5):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        verdict = safety.preflight("Am I eating enough?", health_analysis.snapshot())

        constraints = " ".join(verdict.constraints)
        self.assertIn("Never state a number as an amount this person should eat", constraints)
        self.assertIn("self-reported", constraints)
        self.assertIn("cannot be established from a food diary", constraints)

    def test_asking_about_food_with_nothing_logged_is_answered_by_saying_so(self):
        """Weight and energy burned are the nearest things to hand, and neither
        is a record of eating."""
        verdict = safety.preflight("Am I eating enough?", health_analysis.snapshot())

        self.assertTrue(any("No food or drink has been logged" in r for r in verdict.reasons))
        self.assertTrue(any("do not infer intake from weight" in c for c in verdict.constraints))

    def test_a_thin_food_log_becomes_a_visible_reason(self):
        for offset in range(3):
            self.meal_day(self.as_of - timedelta(days=offset), 2400)

        verdict = safety.preflight("How is my diet?", health_analysis.snapshot())

        self.assertTrue(any("food log covers 3 of the last 7 days" in r for r in verdict.reasons))

    def test_a_question_about_steps_does_not_collect_the_nutrition_rules(self):
        verdict = safety.preflight("Am I walking more this week?", health_analysis.snapshot())

        self.assertNotIn(
            "cannot be established from a food diary", " ".join(verdict.constraints)
        )

    def test_an_intake_target_in_an_answer_is_blocked(self):
        """The prompt forbids this and a local model will write it anyway, which
        is the entire argument for a post-flight check."""
        for text in (
            "You should eat 2,600 kcal a day to close that gap.",
            "Aim for 140 g of protein daily.",
            "Try to hit 2000 kcal tomorrow.",
        ):
            with self.subTest(text=text):
                insight = {
                    "summary": text,
                    "period_examined": "last 7 days",
                    "observations": [],
                    "actions": [],
                    "limitations": [],
                    "confidence": "moderate",
                    "professional_review_recommended": False,
                }
                result = safety.postflight(insight, safety.SafetyVerdict())
                self.assertTrue(result.blocked, text)
                self.assertIn("target", result.blocked_reason)

    def test_reporting_what_was_logged_is_not_a_target(self):
        """The numbers have to survive. An answer that cannot say "you logged
        2,430 kcal a day over five days" is not a safer answer, it is a useless
        one."""
        insight = {
            "summary": "You logged 2,430 kcal a day across the five days you finished a log.",
            "period_examined": "2 to 6 August",
            "observations": [
                {
                    "statement": "Logged intake sat close to estimated expenditure.",
                    "evidence": "2,430 kcal logged against an estimated 2,300 kcal burned "
                    "over the same 5 days.",
                    "confidence": "moderate",
                }
            ],
            "actions": [
                {
                    "action": "Finish the log on the two days you started one.",
                    "reason": "Two days have entries but stop after breakfast.",
                    "timeframe": "this week",
                }
            ],
            "limitations": [
                "Nine of 14 days have no food log, so those days are unknown.",
                "Whether this is enough for you is not something a food diary can settle.",
            ],
            "confidence": "moderate",
            "professional_review_recommended": False,
        }

        result = safety.postflight(insight, safety.SafetyVerdict())

        self.assertFalse(result.blocked, result.blocked_reason)


class NutritionEndpointTests(NutritionTestCase):
    def test_it_requires_auth(self):
        self.assertIn(self.client.get("/v1/analysis/nutrition").status_code, (401, 403))

    def test_it_returns_the_deterministic_summary(self):
        for offset in range(4):
            day = self.as_of - timedelta(days=offset)
            self.meal_day(day, 2400)
            self.burned(day)

        body = self.client.get("/v1/analysis/nutrition?days=7", headers=self.auth()).json()

        self.assertEqual(body["window_days"], 7)
        self.assertEqual(body["days_fully_logged"], 4)
        self.assertEqual(body["energy"]["average_per_logged_day"], 2400)
        self.assertEqual(body["sources"][0]["name"], "MyFitnessPal")

    def test_it_rejects_a_days_value_that_is_not_a_number(self):
        response = self.client.get("/v1/analysis/nutrition?days=lots", headers=self.auth())
        self.assertEqual(response.status_code, 400)
