"""Tests for the staleness alerting.

Written against the failure that motivated it: sleep stopped uploading on
2026-06-27 and nothing said so for 35 days. The tests that matter are the ones
about *not* becoming noise — an alert that fires nightly for a month is one
people mute, and a muted alert is the same as no alert.
"""

from datetime import datetime, time, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from ingest import freshness, health_analysis
from ingest.models import AlertState, Batch, Device, Record

SGT = ZoneInfo("Asia/Singapore")


class FreshnessTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.device = Device.objects.create(device_id="fresh-device")
        self.batch = Batch.objects.create(idempotency_key="fresh.ndjson", device=self.device)
        self.today = health_analysis.today()
        self.counter = 0

    def record(self, days_ago: int, slug="step_count", **kwargs):
        self.counter += 1
        day = self.today - timedelta(days=days_ago)
        stamp = datetime.combine(day, time(12), tzinfo=SGT)
        defaults = {
            "id": f"fresh-{self.counter}",
            "device": self.device,
            "batch": self.batch,
            "kind": Record.Kind.QUANTITY,
            "metric": f"HKQuantityTypeIdentifier{slug}",
            "metric_slug": slug,
            "unit": "count",
            "aggregation": "cumulative",
            "value": 5000,
            "start": stamp,
            "end": stamp,
        }
        defaults.update(kwargs)
        return Record.objects.create(**defaults)


class DetectionTests(FreshnessTestCase):
    def test_a_metric_arriving_today_is_not_stale(self):
        self.record(0)
        self.assertEqual(freshness.check(), [])

    def test_a_metric_that_stopped_is_found_with_when(self):
        self.record(35)

        found = freshness.check()

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].metric_slug, "step_count")
        self.assertEqual(found[0].days_since, 35)
        self.assertIn("35 days ago", found[0].describe())

    def test_thresholds_follow_expected_cadence(self):
        """Weight is recorded a couple of times a week. Alerting on it after 48
        hours is how an alert becomes something people filter away."""
        self.record(3, slug="body_mass", aggregation="discrete", unit="kg", value=74)
        self.assertEqual(freshness.check(), [])

        Record.objects.all().delete()
        self.record(3)  # step count, expected daily
        self.assertEqual(len(freshness.check()), 1)

    def test_a_metric_never_recorded_is_not_reported(self):
        """Alerting about a metric someone does not track is telling them off
        for a choice, not reporting a fault."""
        self.record(0)
        self.assertNotIn("body_mass", [f.metric_slug for f in freshness.check()])


class NotificationTests(FreshnessTestCase):
    def setUp(self):
        super().setUp()
        self.record(35)

    def run_check(self, **kwargs):
        with mock.patch.object(freshness, "send", return_value=True) as send:
            result = freshness.run(**kwargs)
        return result, send

    def test_a_new_finding_is_announced(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"):
            result, send = self.run_check()

        send.assert_called_once()
        title, message = send.call_args[0]
        self.assertIn("not syncing", title)
        self.assertIn("Steps", message)
        self.assertTrue(result["notified"])

    def test_the_same_finding_is_not_repeated_the_next_night(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"):
            self.run_check()
            _, second = self.run_check()

        second.assert_not_called()

    def test_it_repeats_once_the_renotify_window_passes(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook",
                           ALERT_RENOTIFY_DAYS=7):
            self.run_check()
            state = AlertState.objects.get()
            AlertState.objects.filter(pk=state.pk).update(
                last_sent_at=timezone.now() - timedelta(days=8)
            )
            _, second = self.run_check()

        second.assert_called_once()

    def test_recovery_is_reported_so_you_know_the_fix_worked(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"):
            self.run_check()
            self.record(0)  # syncing again
            result, send = self.run_check()

        self.assertEqual(result["recovered"], ["Steps"])
        self.assertIn("Syncing again", send.call_args[0][1])
        self.assertIsNotNone(AlertState.objects.get().resolved_at)

    def test_a_recovered_metric_that_dies_again_alerts_again(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"):
            self.run_check()
            self.record(0)
            self.run_check()  # recovers
            Record.objects.filter(start__gte=timezone.now() - timedelta(days=1)).delete()
            _, third = self.run_check()

        third.assert_called_once()

    def test_state_is_recorded_even_when_the_webhook_is_down(self):
        """If a failed send also skipped the bookkeeping, a notifier that was
        briefly down would re-alert for everything the moment it came back."""
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"), \
             mock.patch.object(freshness, "send", side_effect=freshness.NotifyFailed("down")):
            result = freshness.run()

        self.assertFalse(result["notified"])
        self.assertEqual(AlertState.objects.count(), 1)
        self.assertFalse(AlertState.objects.get().notified)

    def test_dry_run_changes_nothing(self):
        with self.settings(ALERT_WEBHOOK_URL="https://example.invalid/hook"):
            result, send = self.run_check(dry_run=True)

        send.assert_not_called()
        self.assertEqual(AlertState.objects.count(), 0)
        self.assertEqual(len(result["stale"]), 1)

    def test_no_webhook_still_reports_but_sends_nothing(self):
        with self.settings(ALERT_WEBHOOK_URL=""):
            result = freshness.run()

        self.assertFalse(result["webhook_configured"])
        self.assertFalse(result["notified"])
        self.assertEqual(len(result["stale"]), 1)


class CommandTests(FreshnessTestCase):
    def test_the_command_exits_cleanly_when_metrics_are_stale(self):
        """A stale metric is a finding, not a crash. Exiting non-zero would fill
        the cron log with mail about a working script."""
        from django.core.management import call_command
        from io import StringIO

        self.record(35)
        out = StringIO()
        call_command("check_freshness", "--dry-run", stdout=out)

        self.assertIn("not syncing", out.getvalue())
        self.assertIn("ALERT_WEBHOOK_URL", out.getvalue())
