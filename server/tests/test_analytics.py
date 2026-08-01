"""Tests for the dashboard analytics and CSV export.

The one that matters most is `test_rollup_wins_over_raw_sum`: iPhone and Watch
both write step counts, so summing raw samples inflates daily totals — measured
at 1.9× and as much as 3.5× on real data. Presenting that as fact would be worse
than showing nothing.
"""

import csv
import io
import json
from datetime import datetime, timedelta, timezone as dt_timezone

from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase

from ingest.models import ApiToken, Batch, Device, Record


def iso(dt):
    return dt.isoformat()


class AnalyticsTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.token, self.raw = ApiToken.issue("analytics-test")
        self.device = Device.objects.create(device_id="analytics-device")
        self.batch = Batch.objects.create(idempotency_key="a.ndjson", device=self.device)
        # Fixed instant so day bucketing is deterministic. 04:00 UTC is midday
        # in Asia/Singapore, safely inside one local day either way.
        self.day = datetime(2026, 7, 15, 4, 0, tzinfo=dt_timezone.utc)

    def auth(self):
        return {"authorization": f"Bearer {self.raw}"}

    def make(self, **kwargs):
        defaults = {
            "device": self.device,
            "batch": self.batch,
            "kind": Record.Kind.QUANTITY,
            "metric": "HKQuantityTypeIdentifierStepCount",
            "metric_slug": "step_count",
            "unit": "count",
            "aggregation": "cumulative",
            "start": self.day,
            "end": self.day,
            "recorded_at": self.day,
        }
        defaults.update(kwargs)
        defaults.setdefault("id", f"rec-{Record.objects.count()}-{defaults['metric_slug']}")
        return Record.objects.create(**defaults)


class AggregationTests(AnalyticsTestCase):
    def test_rollup_wins_over_raw_sum(self):
        """The whole point of the design: Apple's deduplicated rollup is
        authoritative, and the inflated raw sum must not be what gets shown."""
        self.make(id="s1", value=5000, source_name="iPhone")
        self.make(id="s2", value=5000, source_name="Apple Watch")  # same steps, twice
        self.make(
            id="stat:step_count:2026-07-15",
            kind=Record.Kind.STATISTIC,
            value=5000,
        )

        response = self.client.get(
            "/v1/analytics/series?metric=step_count&agg=sum&from=2026-07-15&to=2026-07-15",
            headers=self.auth(),
        )

        body = response.json()
        self.assertEqual(body["points"][0]["value"], 5000)  # not 10000
        self.assertEqual(body["points"][0]["source"], "statistic")
        self.assertFalse(body["may_double_count"])

    def test_raw_sum_is_flagged_when_no_rollup_exists(self):
        self.make(id="s1", value=5000, source_name="iPhone")
        self.make(id="s2", value=5000, source_name="Apple Watch")

        body = self.client.get(
            "/v1/analytics/series?metric=step_count&agg=sum&from=2026-07-15&to=2026-07-15",
            headers=self.auth(),
        ).json()

        self.assertEqual(body["points"][0]["value"], 10000)
        self.assertEqual(body["points"][0]["source"], "raw_sum")
        # Flagged, so the UI can say "estimated" rather than assert it as fact.
        self.assertTrue(body["may_double_count"])

    def test_average_is_never_flagged(self):
        """Only sums can be inflated by cross-device overlap."""
        self.make(id="h1", metric_slug="heart_rate", aggregation="discrete", value=60)
        self.make(id="h2", metric_slug="heart_rate", aggregation="discrete", value=80)

        body = self.client.get(
            "/v1/analytics/series?metric=heart_rate&agg=avg&from=2026-07-15&to=2026-07-15",
            headers=self.auth(),
        ).json()

        self.assertEqual(body["points"][0]["value"], 70)
        self.assertFalse(body["may_double_count"])

    def test_tombstoned_records_are_excluded(self):
        self.make(id="s1", value=5000)
        self.make(id="s2", value=3000, deleted_at=self.day)

        body = self.client.get(
            "/v1/analytics/series?metric=step_count&agg=sum&from=2026-07-15&to=2026-07-15",
            headers=self.auth(),
        ).json()

        self.assertEqual(body["points"][0]["value"], 5000)

    def test_sleep_sums_durations_not_category_codes(self):
        """A sleep record's `value` is an enum (1 = asleepUnspecified). Averaging
        it yields a meaningless number; the duration is in extra."""
        for i, seconds in enumerate([3600, 1800, 5400]):
            self.make(
                id=f"sleep-{i}",
                kind=Record.Kind.SLEEP,
                metric_slug="sleep_analysis",
                metric="HKCategoryTypeIdentifierSleepAnalysis",
                value=1,
                unit="",
                aggregation="",
                extra={"is_asleep": True, "duration_seconds": seconds},
            )
        # inBed overlaps the asleep intervals and would nearly double the night.
        self.make(
            id="sleep-inbed",
            kind=Record.Kind.SLEEP,
            metric_slug="sleep_analysis",
            value=0,
            extra={"is_asleep": False, "duration_seconds": 9999},
        )

        body = self.client.get(
            "/v1/analytics/overview?from=2026-07-15&to=2026-07-15", headers=self.auth()
        ).json()
        sleep = next(c for c in body["charts"] if c["metric_slug"] == "sleep_analysis")

        self.assertEqual(sleep["unit"], "h")
        self.assertEqual(sleep["points"][0]["value"], 3.0)  # (3600+1800+5400)/3600

    def test_latest_tile_for_cumulative_is_a_day_total_not_a_sample(self):
        """"Latest steps: 18" — the last raw increment — is nonsense on a tile."""
        self.make(id="s1", value=4000, start=self.day, end=self.day)
        self.make(
            id="s2", value=18,
            start=self.day + timedelta(hours=2), end=self.day + timedelta(hours=2),
        )

        body = self.client.get(
            "/v1/analytics/overview?from=2026-07-15&to=2026-07-15", headers=self.auth()
        ).json()

        latest = body["latest"]["step_count"]
        self.assertEqual(latest["value"], 4018)
        self.assertEqual(latest["basis"], "day")

    def test_latest_tile_for_discrete_is_a_reading(self):
        self.make(id="h1", metric_slug="heart_rate", aggregation="discrete", value=60)
        self.make(
            id="h2", metric_slug="heart_rate", aggregation="discrete", value=83,
            start=self.day + timedelta(hours=1), end=self.day + timedelta(hours=1),
        )

        body = self.client.get(
            "/v1/analytics/overview?from=2026-07-15&to=2026-07-15", headers=self.auth()
        ).json()

        latest = body["latest"]["heart_rate"]
        self.assertEqual(latest["value"], 83)
        self.assertEqual(latest["basis"], "reading")

    def test_metric_catalog_offers_only_meaningful_aggregations(self):
        self.make(id="s1", value=1)
        self.make(id="h1", metric_slug="heart_rate", aggregation="discrete", value=60)

        catalog = {m["metric_slug"]: m for m in self.client.get(
            "/v1/analytics/metrics", headers=self.auth()).json()["metrics"]}

        # Summing instantaneous heart-rate readings is meaningless, so it is
        # not offered rather than merely discouraged.
        self.assertNotIn("sum", catalog["heart_rate"]["allowed_aggs"])
        self.assertIn("sum", catalog["step_count"]["allowed_aggs"])
        self.assertEqual(catalog["heart_rate"]["default_agg"], "avg")


class ExportTests(AnalyticsTestCase):
    def test_csv_streams_selected_metrics(self):
        self.make(id="s1", value=100)
        self.make(id="h1", metric_slug="heart_rate", aggregation="discrete", value=60)

        response = self.client.get(
            "/v1/export/records.csv?metrics=step_count&from=2026-07-15&to=2026-07-15",
            headers=self.auth(),
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "text/csv")
        self.assertIn("attachment;", response["Content-Disposition"])

        body = b"".join(response.streaming_content).decode()
        rows = list(csv.DictReader(io.StringIO(body)))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["metric_slug"], "step_count")
        self.assertEqual(rows[0]["value"], "100.0")

    def test_csv_excludes_deleted_by_default(self):
        self.make(id="s1", value=100)
        self.make(id="s2", value=200, deleted_at=self.day)

        body = b"".join(
            self.client.get(
                "/v1/export/records.csv?from=2026-07-15&to=2026-07-15", headers=self.auth()
            ).streaming_content
        ).decode()

        self.assertEqual(len(list(csv.DictReader(io.StringIO(body)))), 1)

    def test_export_summary_counts_before_download(self):
        for i in range(5):
            self.make(id=f"s{i}", value=1)

        body = self.client.get(
            "/v1/export/summary?from=2026-07-15&to=2026-07-15", headers=self.auth()
        ).json()

        self.assertEqual(body["rows"], 5)
        self.assertFalse(body["capped"])

    def test_export_requires_auth(self):
        self.assertIn(self.client.get("/v1/export/records.csv").status_code, (401, 403))


class DashboardSessionTests(TestCase):
    def setUp(self):
        cache.clear()
        User.objects.create_user(username="dash", password="dash-p4ssw0rd-x")

    def login(self, password="dash-p4ssw0rd-x"):
        self.client.get("/v1/auth/csrf")
        return self.client.post(
            "/v1/auth/session",
            data=json.dumps({"username": "dash", "password": password}),
            content_type="application/json",
        )

    def test_session_login_then_analytics(self):
        self.assertEqual(self.login().status_code, 200)
        self.assertEqual(self.client.get("/v1/analytics/metrics").status_code, 200)

    def test_bad_password_rejected(self):
        self.assertEqual(self.login(password="nope").status_code, 401)

    def test_me_reports_signed_out_before_login(self):
        self.assertFalse(self.client.get("/v1/auth/me").json()["authenticated"])

    def test_logout_ends_the_session(self):
        self.login()
        self.client.post("/v1/auth/session/logout")
        self.assertIn(self.client.get("/v1/analytics/metrics").status_code, (401, 403))


class ThrottleIdentityTests(TestCase):
    """The login throttle must key on the real client, not a client-supplied
    header. nginx *appends* to X-Forwarded-For, so the first entry is whatever
    the caller sent — trusting it makes the limit decorative."""

    def setUp(self):
        cache.clear()
        User.objects.create_user(username="thr", password="thr-p4ssw0rd-x")

    def attempt(self, xff=None):
        headers = {"x-forwarded-for": xff} if xff else {}
        return self.client.post(
            "/v1/auth/login",
            data=json.dumps({"username": "thr", "password": "wrong"}),
            content_type="application/json",
            headers=headers,
        )

    def test_spoofed_forwarded_for_cannot_reset_the_limit(self):
        """Simulates the production topology, where nginx appends the real peer
        to whatever the caller sent. NUM_PROXIES=1 makes DRF read the last
        entry — the peer — instead of the attacker-controlled first one."""
        spoofed_then_real = "9.9.9.9, 127.0.0.1"
        other_spoof = "8.8.8.8, 127.0.0.1"

        codes = [self.attempt(xff=spoofed_then_real).status_code for _ in range(12)]
        self.assertIn(429, codes, "the limit never engaged at all")

        # A different spoofed prefix must not buy a fresh bucket.
        self.assertEqual(self.attempt(xff=other_spoof).status_code, 429)
        self.assertEqual(self.attempt(xff="1.2.3.4, 127.0.0.1").status_code, 429)
