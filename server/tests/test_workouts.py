"""Exercise detail: units, per-session sensor summaries, and moving time.

The unit tests here are the important ones. `UnitResolver` on the phone resolves
every distance type to metres while this server labels those metrics
kilometres, and nothing converted between them — so an 8.5 km walk reached the
model as "8500 km". Wrong by a thousand, and plausible enough that it survived
until someone went looking.
"""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from ingest import health_analysis, units
from ingest.models import ApiToken, Batch, Device, Record

SGT = ZoneInfo("Asia/Singapore")


def at(day: date, hour: int = 12, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=SGT)


class UnitConversionTests(TestCase):
    def test_same_dimension_converts(self):
        self.assertAlmostEqual(units.convert(8500, "m", "km"), 8.5)
        self.assertAlmostEqual(units.convert(1, "km", "m"), 1000)
        self.assertAlmostEqual(units.convert(3.6, "km/hr", "m/s"), 1.0)
        self.assertAlmostEqual(units.convert(1000, "g", "kg"), 1.0)
        self.assertAlmostEqual(units.convert(1, "kW", "W"), 1000)

    def test_crossing_dimensions_returns_none(self):
        """None rather than the raw number: an unconvertible unit means the
        caller does not know what it is holding."""
        self.assertIsNone(units.convert(5, "kg", "km"))
        self.assertIsNone(units.convert(5, "W", "count/min"))
        self.assertIsNone(units.convert(5, "m", "kcal"))

    def test_an_unheard_of_unit_is_not_guessed_at(self):
        self.assertIsNone(units.convert(5, "smoots", "m"))
        self.assertFalse(units.known("smoots"))

    def test_dimensionless_units_are_not_in_any_table(self):
        """A count, a percentage or a score has nothing to convert to, and
        callers use `known` to tell that apart from a failed conversion."""
        for unit in ("count", "%", "score"):
            self.assertFalse(units.known(unit))

    def test_temperature_is_deliberately_absent(self):
        """Celsius to Fahrenheit is an offset as well as a scale, so it cannot
        join a table of factors and must not appear to."""
        self.assertIsNone(units.convert(20, "degC", "degF"))


class MetricUnitTests(TestCase):
    def setUp(self):
        cache.clear()
        self.device = Device.objects.create(device_id="workout-units")
        self.batch = Batch.objects.create(idempotency_key="wu.ndjson", device=self.device)
        self.as_of = health_analysis.last_complete_day()
        self.counter = 0

    def sample(self, day: date, value: float, slug: str, unit: str, **kwargs):
        self.counter += 1
        defaults = {
            "id": f"wu-{self.counter}",
            "device": self.device,
            "batch": self.batch,
            "kind": Record.Kind.QUANTITY,
            "metric": slug,
            "metric_slug": slug,
            "unit": unit,
            "aggregation": "cumulative",
            "value": value,
            "start": at(day),
            "end": at(day),
            "recorded_at": at(day),
        }
        defaults.update(kwargs)
        return Record.objects.create(**defaults)

    def test_metres_are_reported_as_the_kilometres_they_are_labelled(self):
        """The bug this file exists for. 8.5 km walked, stored in metres the way
        the phone stores it, must not be reported as 8500 km."""
        for i in range(35):
            self.sample(self.as_of - timedelta(days=i), 8500.0,
                        "distance_walking_running", "m")

        report = health_analysis.compare_to_baseline(
            "distance_walking_running", as_of=self.as_of
        )

        self.assertEqual(report["unit"], "km")
        self.assertAlmostEqual(report["current"]["value"], 8.5, places=2)

    def test_a_value_already_in_the_target_unit_is_untouched(self):
        for i in range(35):
            self.sample(self.as_of - timedelta(days=i), 8.5,
                        "distance_walking_running", "km")

        report = health_analysis.compare_to_baseline(
            "distance_walking_running", as_of=self.as_of
        )
        self.assertAlmostEqual(report["current"]["value"], 8.5, places=2)

    def test_an_unconvertible_unit_is_left_alone_rather_than_scaled(self):
        """Better a number in the wrong unit than a number scaled by a factor
        that was guessed at."""
        for i in range(35):
            self.sample(self.as_of - timedelta(days=i), 8500.0,
                        "distance_walking_running", "furlongs")

        report = health_analysis.compare_to_baseline(
            "distance_walking_running", as_of=self.as_of
        )
        self.assertAlmostEqual(report["current"]["value"], 8500.0, places=2)

    def test_mixed_units_are_not_scaled_by_one_of_them(self):
        """Two units for one metric means the SQL sum already added metres to
        kilometres. Picking either factor would make a wrong number look
        precise; it is left as-is for `data_quality` to report."""
        for i in range(35):
            day = self.as_of - timedelta(days=i)
            self.sample(day, 8500.0, "distance_walking_running", "m" if i % 2 else "km")

        report = health_analysis.compare_to_baseline(
            "distance_walking_running", as_of=self.as_of
        )
        self.assertAlmostEqual(report["current"]["value"], 8500.0, places=2)

    def test_nutrition_is_not_converted_twice(self):
        """Nutrition converts per row in its own module. Scaling the result
        again multiplies the conversion twice — 1 g of protein became 1000."""
        for i in range(35):
            day = self.as_of - timedelta(days=i)
            for hour in (8, 13, 19):
                self.sample(day, 0.05, "dietary_protein", "kg",
                            start=at(day, hour), end=at(day, hour))
                self.sample(day, 700.0, "dietary_energy_consumed", "kcal",
                            start=at(day, hour), end=at(day, hour))

        report = health_analysis.compare_to_baseline("dietary_protein", as_of=self.as_of)
        # 3 × 0.05 kg = 150 g.
        self.assertAlmostEqual(report["current"]["value"], 150.0, places=1)


class ExerciseMetricTests(MetricUnitTests):
    def test_exercise_metrics_are_analysable(self):
        """They were uploaded and stored all along; nothing named them here, so
        `available_metrics` filtered them out and the model never saw a power
        meter."""
        for slug in (
            "cycling_power", "running_power", "cycling_cadence", "cycling_speed",
            "running_speed", "distance_cycling", "distance_swimming",
            "vo2_max", "flights_climbed", "estimated_workout_effort_score",
        ):
            self.assertIn(slug, health_analysis.METRICS, slug)

    def test_a_power_meter_produces_a_comparison(self):
        for i in range(35):
            self.sample(self.as_of - timedelta(days=i), 210.0, "cycling_power", "W")

        report = health_analysis.compare_to_baseline("cycling_power", as_of=self.as_of)
        self.assertEqual(report["unit"], "W")
        self.assertAlmostEqual(report["current"]["value"], 210.0, places=1)

    def test_the_snapshot_still_leads_with_six(self):
        """Adding eleven metrics must not lengthen the headline. Six numbers
        someone reads beats seventeen they skim."""
        self.assertEqual(len(health_analysis.SNAPSHOT_METRICS), 6)

    def test_an_occasional_metric_is_not_called_stale_after_two_days(self):
        """Freshness derives its threshold from `expected_cadence`. Left at the
        default, a normal week of not cycling would alert as a broken sync."""
        from ingest import freshness

        for slug in ("cycling_power", "distance_swimming", "vo2_max"):
            spec = health_analysis.METRICS[slug]
            self.assertGreater(freshness.stale_after_days(spec), 4, slug)


class SessionDetailTests(MetricUnitTests):
    def workout(self, day: date, minutes: int = 60, **extra):
        self.counter += 1
        start = at(day, 18)
        payload = {"activity_name": "Cycling", "duration_seconds": minutes * 60}
        payload.update(extra)
        return Record.objects.create(
            id=f"w-{self.counter}", device=self.device, batch=self.batch,
            kind=Record.Kind.WORKOUT, metric="HKWorkoutTypeIdentifier",
            metric_slug="workout", value=minutes * 60, unit="s",
            start=start, end=start + timedelta(minutes=minutes),
            source_name="Apple Watch", recorded_at=start, extra=payload,
        )

    def test_sensor_streams_are_summarised_onto_the_session(self):
        day = self.as_of
        self.workout(day, minutes=60)
        for offset, bpm in enumerate([120, 140, 165]):
            self.sample(day, bpm, "heart_rate", "count/min",
                        start=at(day, 18, offset * 10), end=at(day, 18, offset * 10))
        for offset, watts in enumerate([180, 220, 260]):
            self.sample(day, watts, "cycling_power", "W",
                        start=at(day, 18, offset * 10), end=at(day, 18, offset * 10))

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]

        self.assertAlmostEqual(session["avg_heart_rate_bpm"], 141.7, places=1)
        self.assertEqual(session["max_heart_rate_bpm"], 165)
        self.assertAlmostEqual(session["avg_cycling_power_w"], 220.0, places=1)
        self.assertEqual(session["max_cycling_power_w"], 260)

    def test_a_sample_outside_the_window_is_not_counted(self):
        """A day-long average over a 45-minute ride is mostly a measurement of
        sitting still, which is the whole reason this is windowed."""
        day = self.as_of
        self.workout(day, minutes=60)
        self.sample(day, 150, "heart_rate", "count/min", start=at(day, 18), end=at(day, 18))
        self.sample(day, 55, "heart_rate", "count/min", start=at(day, 4), end=at(day, 4))

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["avg_heart_rate_bpm"], 150)

    def test_a_daily_rollup_is_not_mistaken_for_a_session_figure(self):
        day = self.as_of
        self.workout(day, minutes=60)
        self.sample(day, 150, "heart_rate", "count/min", start=at(day, 18), end=at(day, 18))
        self.sample(day, 70, "heart_rate", "count/min",
                    id=f"stat:heart_rate:{day.isoformat()}", kind=Record.Kind.STATISTIC,
                    start=at(day, 18), end=at(day, 18))

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["avg_heart_rate_bpm"], 150)

    def test_pace_uses_distance_and_moving_time(self):
        day = self.as_of
        self.workout(day, minutes=50, distance_m=10_000)

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertAlmostEqual(session["distance_km"], 10.0)
        self.assertAlmostEqual(session["pace_min_per_km"], 5.0, places=2)

    def test_a_trivial_distance_produces_no_pace(self):
        """A three-metre GPS twitch on a strength session yields a pace per
        kilometre in the thousands."""
        day = self.as_of
        self.workout(day, minutes=45, distance_m=3)

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertIsNone(session["pace_min_per_km"])

    def test_paired_pause_and_resume_shorten_moving_time(self):
        day = self.as_of
        self.workout(day, minutes=60, events=[
            {"type": 1, "start": at(day, 18, 20).isoformat(), "end": at(day, 18, 20).isoformat()},
            {"type": 2, "start": at(day, 18, 30).isoformat(), "end": at(day, 18, 30).isoformat()},
        ])

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["minutes"], 60.0)
        self.assertEqual(session["moving_minutes"], 50.0)

    def test_a_pause_carrying_its_own_interval_is_not_double_counted(self):
        """HealthKit produces both shapes. Counting a closed interval *and*
        pairing it with the following resume would subtract twenty minutes for
        a ten-minute stop."""
        day = self.as_of
        self.workout(day, minutes=60, events=[
            {"type": 1, "start": at(day, 18, 20).isoformat(), "end": at(day, 18, 30).isoformat()},
            {"type": 2, "start": at(day, 18, 30).isoformat(), "end": at(day, 18, 30).isoformat()},
        ])

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["moving_minutes"], 50.0)

    def test_no_pause_events_reports_no_moving_time_rather_than_guessing(self):
        """A recorder that never emits pause events looks identical to one that
        was never paused, and only the second is a fact."""
        day = self.as_of
        self.workout(day, minutes=60)

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertIsNone(session["moving_minutes"])

    def test_a_naive_timestamp_does_not_raise(self):
        """Event timestamps are compared against timezone-aware DB values, and
        mixing the two raises several frames from the cause."""
        day = self.as_of
        self.workout(day, minutes=60, events=[
            {"type": 1, "start": "2026-07-31T18:20:00", "end": "2026-07-31T18:20:00"},
        ])

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["minutes"], 60.0)

    def test_healthkits_own_summary_beats_re_deriving_it(self):
        """The phone ships HealthKit's session summary, deduplicated across
        sources. Where it exists it wins over the sample-derived figure, the
        same way a daily rollup beats a raw sum."""
        day = self.as_of
        self.workout(day, minutes=60, avg_heart_rate_bpm=148.0, max_heart_rate_bpm=171.0)
        self.sample(day, 100, "heart_rate", "count/min", start=at(day, 18), end=at(day, 18))

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["avg_heart_rate_bpm"], 148.0)
        self.assertEqual(session["max_heart_rate_bpm"], 171.0)

    def test_the_sample_stream_still_fills_in_when_the_phone_sent_no_summary(self):
        day = self.as_of
        self.workout(day, minutes=60)
        self.sample(day, 100, "heart_rate", "count/min", start=at(day, 18), end=at(day, 18))

        session = health_analysis.workouts(as_of=self.as_of)["recent"][0]
        self.assertEqual(session["avg_heart_rate_bpm"], 100)
