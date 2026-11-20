"""Tests for the lifestyle signals.

As in the rest of the analysis suite, the refusals carry as much weight as the
arithmetic: a regularity index from three nights, a typical range from four, a
week of exercise counted from one known day, and a fitness "gain" inside the
watch's own error are all numbers this layer must decline to state.
"""

from datetime import date, timedelta

from django.core.cache import cache

from ingest import health_analysis, lifestyle
from ingest.llm import tools as llm_tools
from ingest.models import Record

from .test_analysis import AnalysisTestCase, at


class LifestyleTestCase(AnalysisTestCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.today = health_analysis.today()

    def night(self, morning: date, bed=(23, 0), wake=(7, 0), hours=None):
        """One asleep interval ending on `morning`."""
        self.counter += 1
        bed_day = morning - timedelta(days=1) if bed[0] >= 12 else morning
        start = at(bed_day, bed[0]).replace(minute=bed[1])
        end = at(morning, wake[0]).replace(minute=wake[1])
        seconds = (end - start).total_seconds() if hours is None else hours * 3600
        return Record.objects.create(
            id=f"sleep-{self.counter}",
            device=self.device,
            batch=self.batch,
            kind=Record.Kind.SLEEP,
            metric="HKCategoryTypeIdentifierSleepAnalysis",
            metric_slug="sleep_analysis",
            value=1,
            start=start,
            end=end,
            extra={"is_asleep": True, "duration_seconds": seconds},
        )

    def reading(self, morning: date, hour: int, slug: str, value: float, unit="count/min"):
        """An instantaneous reading taken during the night ending `morning`."""
        moment = at(morning, hour)
        return self.sample(
            morning, value, slug=slug, unit=unit, aggregation="discrete",
            start=moment, end=moment,
        )

    def wrist_temperature(self, morning: date, value: float):
        """One sample spanning the whole night, the way the watch writes it."""
        return self.sample(
            morning, value, slug="apple_sleeping_wrist_temperature", unit="degC",
            aggregation="discrete",
            start=at(morning - timedelta(days=1), 23), end=at(morning, 7),
        )


# --------------------------------------------------------------------------
# Day bucketing
# --------------------------------------------------------------------------


class EndAnchoredTests(LifestyleTestCase):
    def test_wrist_temperature_is_filed_under_the_morning(self):
        """Started the evening before, so bucketing by start put a night's
        temperature on a different day from the same night's sleep."""
        morning = self.as_of
        self.wrist_temperature(morning, 34.6)

        days = health_analysis.day_values(
            "apple_sleeping_wrist_temperature", morning - timedelta(days=1), morning
        )

        self.assertEqual([d.day for d in days], [morning])


class NoiseFloorTests(LifestyleTestCase):
    def vo2(self, day: date, value: float):
        self.counter += 1
        return self.sample(
            day, value, slug="vo2_max", unit="mL/kg/min", aggregation="discrete",
            id=f"stat:vo2_max:{day.isoformat()}-{self.counter}", kind=Record.Kind.STATISTIC,
        )

    def test_vo2_wobble_inside_one_met_is_stable(self):
        """The watch smooths VO2 max so heavily that its own spread is tiny, and
        a one-point move would grade as notable against it."""
        for offset in range(8, 35, 3):
            self.vo2(self.as_of - timedelta(days=offset), 40.0 + (offset % 2) * 0.1)
        for offset in range(0, 7, 3):
            self.vo2(self.as_of - timedelta(days=offset), 41.2)

        comparison = health_analysis.compare_to_baseline("vo2_max")

        self.assertNotEqual(comparison["confidence"], "insufficient")
        self.assertEqual(comparison["significance"], "stable")

    def test_cardio_fitness_steady_unless_it_moves_a_met(self):
        for offset in range(0, 90, 5):
            self.vo2(self.as_of - timedelta(days=offset), 40.0 + (90 - offset) * 0.01)

        fitness = lifestyle.cardio_fitness()

        self.assertEqual(fitness["direction"], "steady")
        self.assertEqual(fitness["estimates"], 18)

    def test_cardio_fitness_rising_over_the_window(self):
        for offset in range(0, 90, 5):
            self.vo2(self.as_of - timedelta(days=offset), 38.0 + (90 - offset) * 0.08)

        fitness = lifestyle.cardio_fitness()

        self.assertEqual(fitness["direction"], "rising")
        self.assertGreater(fitness["change_over_window"], 3.5)

    def test_no_vo2_data_is_no_section(self):
        self.assertIsNone(lifestyle.cardio_fitness())


# --------------------------------------------------------------------------
# Sleep regularity
# --------------------------------------------------------------------------


class SleepRegularityTests(LifestyleTestCase):
    def test_identical_schedule_is_100(self):
        for offset in range(36):
            self.night(self.as_of - timedelta(days=offset))

        result = lifestyle.sleep_regularity()

        self.assertEqual(result["sri"], 100)
        self.assertEqual(result["baseline"]["sri"], 100)
        self.assertEqual(result["label"], "very regular")
        self.assertEqual(result["valid_pairs"], 7)
        self.assertEqual(result["confidence"], "high")

    def test_alternating_schedule_scores_low(self):
        """23:00–07:00 one night, 03:00–11:00 the next: four shared hours asleep
        and twelve shared awake, so 960 of 1,440 minutes agree — an SRI of 33."""
        for offset in range(8):
            morning = self.as_of - timedelta(days=offset)
            if offset % 2:
                self.night(morning, bed=(3, 0), wake=(11, 0))
            else:
                self.night(morning)

        result = lifestyle.sleep_regularity()

        self.assertEqual(result["sri"], 33)
        self.assertEqual(result["label"], "irregular")

    def test_a_short_partial_night_is_left_out_not_scored_awake(self):
        """A watch taken off at 01:00 is a gap, not five hours awake."""
        for offset in range(8):
            morning = self.as_of - timedelta(days=offset)
            if offset == 3:
                self.night(morning, bed=(23, 0), wake=(1, 0))
            else:
                self.night(morning)

        result = lifestyle.sleep_regularity()

        self.assertEqual(result["valid_pairs"], 5)
        self.assertEqual(result["sri"], 100)

    def test_three_nights_is_not_an_index(self):
        for offset in range(3):
            self.night(self.as_of - timedelta(days=offset))

        result = lifestyle.sleep_regularity()

        self.assertIsNone(result["sri"])
        self.assertEqual(result["confidence"], "insufficient")
        self.assertIn("at least 5", result["confidence_reason"])

    def test_less_regular_than_usual_is_graded_against_own_spread(self):
        for offset in range(7, 36):
            self.night(self.as_of - timedelta(days=offset))
        for offset in range(7):
            morning = self.as_of - timedelta(days=offset)
            if offset % 2:
                self.night(morning, bed=(2, 0), wake=(10, 0))
            else:
                self.night(morning)

        result = lifestyle.sleep_regularity()

        self.assertLess(result["change"], 0)
        self.assertEqual(result["significance"], "notable")

    def test_sleep_tool_carries_regularity(self):
        for offset in range(8):
            self.night(self.as_of - timedelta(days=offset))

        summary = llm_tools.call("get_sleep_summary", {})

        self.assertEqual(summary["regularity"]["sri"], 100)


# --------------------------------------------------------------------------
# Overnight vitals
# --------------------------------------------------------------------------


class OvernightVitalsTests(LifestyleTestCase):
    def history(self, nights=14, start=1, temperature=True):
        """`nights` ordinary nights ending before today."""
        for offset in range(start, start + nights):
            morning = self.today - timedelta(days=offset)
            self.night(morning)
            self.reading(morning, 3, "heart_rate", 52 + offset % 3)
            self.reading(morning, 2, "heart_rate_variability_sdnn", 60 + (offset % 3) * 5, unit="ms")
            self.reading(morning, 4, "respiratory_rate", 14 + (offset % 3) * 0.2)
            self.reading(morning, 5, "oxygen_saturation", 0.97, unit="%")
            if temperature:
                self.wrist_temperature(morning, 34.5 + (offset % 3) * 0.1)

    def last_night(self, hr=53, hrv=65, rr=14.2, spo2=0.97, temperature=34.6):
        self.night(self.today)
        self.reading(self.today, 3, "heart_rate", hr)
        self.reading(self.today, 2, "heart_rate_variability_sdnn", hrv, unit="ms")
        self.reading(self.today, 4, "respiratory_rate", rr)
        self.reading(self.today, 5, "oxygen_saturation", spo2, unit="%")
        if temperature is not None:
            self.wrist_temperature(self.today, temperature)

    def by_key(self, result):
        return {m["metric"]: m for m in result["metrics"]}

    def test_an_ordinary_night_is_within_range(self):
        self.history()
        self.last_night()

        result = lifestyle.overnight_vitals()

        self.assertEqual(result["status"], "within_range")
        self.assertEqual(result["outside_range"], 0)
        self.assertTrue(result["is_last_night"])
        self.assertEqual(result["morning_of"], self.today.isoformat())
        self.assertEqual(result["possible_factors"], [])

    def test_two_signals_out_is_flagged_without_naming_a_cause(self):
        self.history()
        self.last_night(hr=62, hrv=35)

        result = lifestyle.overnight_vitals()
        metrics = self.by_key(result)

        self.assertEqual(result["status"], "outside_range")
        self.assertEqual(metrics["sleeping_heart_rate"]["status"], "above")
        self.assertEqual(metrics["overnight_hrv"]["status"], "below")
        self.assertEqual(metrics["respiratory_rate"]["status"], "within")
        self.assertIn("not a cause", result["observation"])
        # Cased by hand: `.lower()` would print the acronym as "hrv".
        self.assertIn("overnight HRV below", result["observation"])
        self.assertIn("alcohol", result["possible_factors"])

    def test_one_signal_out_is_not_flagged(self):
        """One measurement out of range on one night is what sensors do."""
        self.history()
        self.last_night(hr=62)

        result = lifestyle.overnight_vitals()

        self.assertEqual(result["status"], "within_range")
        self.assertEqual(result["outside_range"], 1)
        self.assertIn("not flagged", result["observation"])

    def test_wrist_temperature_spanning_the_night_is_placed_in_it(self):
        self.history()
        self.last_night(temperature=35.3)

        metrics = self.by_key(lifestyle.overnight_vitals())

        self.assertEqual(metrics["wrist_temperature"]["value"], 35.3)
        self.assertEqual(metrics["wrist_temperature"]["status"], "above")
        self.assertEqual(metrics["wrist_temperature"]["baseline_nights"], 14)

    def test_blood_oxygen_reads_as_a_percentage(self):
        self.history()
        self.last_night(spo2=0.96)

        oxygen = self.by_key(lifestyle.overnight_vitals())["blood_oxygen"]

        self.assertEqual(oxygen["value"], 96.0)
        self.assertEqual(oxygen["typical"], 97.0)
        self.assertEqual(oxygen["status"], "within")

    def test_daytime_readings_are_not_part_of_the_night(self):
        self.history()
        self.last_night()
        # A workout at 18:00 yesterday: very high, and nothing to do with sleep.
        moment = at(self.today - timedelta(days=1), 18)
        self.sample(
            self.today, 165, slug="heart_rate", unit="count/min", aggregation="discrete",
            start=moment, end=moment,
        )

        metrics = self.by_key(lifestyle.overnight_vitals())

        self.assertEqual(metrics["sleeping_heart_rate"]["value"], 53)

    def test_four_nights_is_not_a_range(self):
        self.history(nights=4)
        self.last_night(hr=70, hrv=20)

        result = lifestyle.overnight_vitals()

        self.assertEqual(result["status"], "building")
        self.assertTrue(all(m["typical_low"] is None for m in result["metrics"]))
        self.assertIn("3 more nights", result["observation"])

    def test_an_unsynced_morning_names_the_older_night(self):
        self.history(nights=14, start=1)

        result = lifestyle.overnight_vitals()

        self.assertFalse(result["is_last_night"])
        self.assertEqual(result["morning_of"], (self.today - timedelta(days=1)).isoformat())

    def test_a_week_old_night_is_not_last_night(self):
        self.history(nights=10, start=6)

        result = lifestyle.overnight_vitals()

        self.assertEqual(result["status"], "no_recent_night")
        self.assertEqual(result["metrics"], [])

    def test_the_brief_leads_with_a_flag(self):
        self.history(temperature=False)
        self.last_night(hr=62, hrv=35, temperature=None)

        brief = health_analysis.daily_brief()

        self.assertTrue(brief["worth_notifying"])
        self.assertTrue(brief["headline"].startswith("2 overnight vitals"), brief["headline"])
        self.assertEqual(brief["overnight"]["status"], "outside_range")
        self.assertEqual(len(brief["overnight"]["outside"]), 2)

    def test_the_brief_says_nothing_about_an_ordinary_night(self):
        self.history()
        self.last_night()

        brief = health_analysis.daily_brief()

        self.assertNotIn("overnight", brief["line"])
        self.assertEqual(brief["overnight"]["outside"], [])


# --------------------------------------------------------------------------
# Weekly activity
# --------------------------------------------------------------------------


class WeeklyActivityTests(LifestyleTestCase):
    def exercise(self, offset: int, minutes: float):
        day = self.as_of - timedelta(days=offset)
        self.rollup(day, minutes, slug="apple_exercise_time")

    def worn(self, offset: int):
        day = self.as_of - timedelta(days=offset)
        self.sample(day, 70, slug="heart_rate", unit="count/min", aggregation="discrete")

    def test_a_spread_out_week_meets_the_guideline(self):
        for offset in range(7):
            self.worn(offset)
        for offset in range(5):
            self.exercise(offset, 30)

        result = lifestyle.weekly_activity()

        self.assertEqual(result["current"]["minutes"], 150)
        self.assertTrue(result["current"]["met_guideline"])
        self.assertFalse(result["current"]["concentrated"])
        self.assertEqual(result["band"], "in_range")

    def test_a_weekend_warrior_week_counts(self):
        for offset in range(7):
            self.worn(offset)
        self.exercise(1, 90)
        self.exercise(2, 80)

        result = lifestyle.weekly_activity()

        self.assertTrue(result["current"]["met_guideline"])
        self.assertTrue(result["current"]["concentrated"])
        self.assertIn("one or two days", result["observation"])

    def test_a_worn_day_without_exercise_is_a_real_zero(self):
        for offset in range(6):
            self.worn(offset)
        self.exercise(0, 20)
        self.exercise(3, 20)

        result = lifestyle.weekly_activity()

        self.assertEqual(result["current"]["known_days"], 6)
        self.assertFalse(result["current"]["met_guideline"])
        self.assertEqual(result["band"], "below_range")
        self.assertIn("110 short of 150", result["observation"])

    def test_one_known_day_cannot_say_the_week_fell_short(self):
        """A gap is not a rest day."""
        self.worn(0)
        self.exercise(0, 100)

        result = lifestyle.weekly_activity()

        self.assertIsNone(result["current"]["met_guideline"])
        self.assertEqual(result["band"], "unknown")
        self.assertIn("only 1 of those days", result["observation"])

    def test_partial_data_already_past_150_has_met_it(self):
        self.worn(0)
        self.exercise(0, 160)

        self.assertTrue(lifestyle.weekly_activity()["current"]["met_guideline"])

    def test_weeks_met_not_a_streak(self):
        for offset in range(28):
            self.worn(offset)
        for week in (0, 2, 3):
            for day in range(5):
                self.exercise(week * 7 + day, 35)

        result = lifestyle.weekly_activity()

        self.assertEqual(result["weeks_met"], 3)
        self.assertEqual(result["weeks_counted"], 4)

    def test_no_exercise_data_is_no_section(self):
        self.worn(0)
        self.assertIsNone(lifestyle.weekly_activity())


# --------------------------------------------------------------------------
# The endpoint and the tool
# --------------------------------------------------------------------------


class LifestyleSurfaceTests(LifestyleTestCase):
    def test_endpoint_returns_every_section(self):
        for offset in range(8):
            self.night(self.as_of - timedelta(days=offset))

        body = self.client.get("/v1/analysis/lifestyle", headers=self.auth()).json()

        for key in ("overnight", "sleep_regularity", "activity", "daylight", "cardio_fitness"):
            self.assertIn(key, body)
        self.assertEqual(body["sleep_regularity"]["sri"], 100)
        # Nothing behind them, so nothing to draw.
        self.assertIsNone(body["daylight"])
        self.assertIsNone(body["cardio_fitness"])

    def test_endpoint_requires_auth(self):
        self.assertIn(self.client.get("/v1/analysis/lifestyle").status_code, (401, 403))

    def test_daylight_uses_the_baseline_machinery(self):
        for offset in range(35):
            self.rollup(self.as_of - timedelta(days=offset), 45 if offset < 7 else 20,
                        slug="time_in_daylight")

        daylight = lifestyle.daylight()

        self.assertEqual(daylight["current"]["value"], 45)
        self.assertEqual(daylight["baseline"]["value"], 20)
        self.assertEqual(daylight["significance"], "notable")

    def test_tool_is_registered_and_labelled(self):
        self.assertIn("get_lifestyle_signals", llm_tools.REGISTRY)
        self.assertIn("get_lifestyle_signals", llm_tools.LABELS)
        result = llm_tools.call("get_lifestyle_signals", {})
        self.assertIn("sleep_regularity", result)
