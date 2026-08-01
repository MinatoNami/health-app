"""Contract tests for POST /v1/health/batches.

These encode the promises the iOS client relies on, documented in the app
README: upsert on id, replay duplicates, and never report a batch as accepted
unless it is durably stored.
"""

import gzip
import json
import uuid

from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from ingest.models import ApiToken, Batch, Device, Record

ENDPOINT = "/v1/health/batches"


def header_line(batch_id="batch-1", device_id="device-1", record_count=1, **extra):
    payload = {
        "kind": "batch_header",
        "batch_id": batch_id,
        "device_id": device_id,
        "record_count": record_count,
        "app_version": "1.0 (1)",
        "schema_version": 1,
        "created_at": "2026-08-01T09:12:44+08:00",
    }
    payload.update(extra)
    return payload


def quantity(record_id=None, value=72.0, metric_slug="heart_rate", **extra):
    payload = {
        "id": record_id or str(uuid.uuid4()),
        "kind": "quantity",
        "metric": "HKQuantityTypeIdentifierHeartRate",
        "metric_slug": metric_slug,
        "value": value,
        "unit": "count/min",
        "start": "2026-07-31T08:14:02+08:00",
        "end": "2026-07-31T08:14:02+08:00",
        "tz": "Asia/Singapore",
        "aggregation": "discrete",
        "source": {
            "name": "Apple Watch",
            "bundle_id": "com.apple.health.x",
            "product_type": "Watch7,1",
            "os_version": "18.5",
        },
        "recorded_at": "2026-07-31T08:20:11+08:00",
        "schema_version": 1,
    }
    payload.update(extra)
    return payload


def ndjson(*objects):
    return ("\n".join(json.dumps(o) for o in objects) + "\n").encode("utf-8")


class IngestTestCase(TestCase):
    def setUp(self):
        self.token, self.raw = ApiToken.issue("test-iphone")

    def post(self, body, key="batch-a.ndjson", token=None, **extra):
        return self.client.post(
            ENDPOINT,
            data=body,
            content_type="application/x-ndjson",
            headers={
                "authorization": f"Bearer {token or self.raw}",
                "idempotency-key": key,
                "x-schema-version": "1",
                **extra,
            },
        )


class AuthTests(IngestTestCase):
    def test_missing_token_is_401(self):
        response = self.client.post(
            ENDPOINT, data=ndjson(header_line()), content_type="application/x-ndjson"
        )
        self.assertEqual(response.status_code, 401)

    def test_bad_token_is_401(self):
        response = self.post(ndjson(header_line()), token="nope")
        self.assertEqual(response.status_code, 401)

    def test_revoked_token_is_401(self):
        self.token.revoked_at = timezone.now()
        self.token.save()
        response = self.post(ndjson(header_line()))
        self.assertEqual(response.status_code, 401)

    def test_raw_token_is_not_stored(self):
        self.assertNotEqual(self.token.token_hash, self.raw)
        self.assertEqual(self.token.token_hash, ApiToken.hash_token(self.raw))


class HeaderTests(IngestTestCase):
    def test_missing_idempotency_key_is_400(self):
        response = self.client.post(
            ENDPOINT,
            data=ndjson(header_line()),
            content_type="application/x-ndjson",
            headers={"authorization": f"Bearer {self.raw}"},
        )
        self.assertEqual(response.status_code, 400)

    def test_empty_body_is_rejected(self):
        response = self.post(b"")
        self.assertEqual(response.status_code, 400)

    def test_first_line_must_be_header(self):
        response = self.post(ndjson(quantity()))
        self.assertEqual(response.status_code, 400)

    def test_newer_schema_version_is_refused(self):
        response = self.post(ndjson(header_line()), **{"x-schema-version": "2"})
        self.assertEqual(response.status_code, 400)

    def test_second_header_is_rejected(self):
        body = ndjson(header_line(), quantity(), header_line(batch_id="batch-2"))
        response = self.post(body)
        self.assertEqual(response.status_code, 400)


class StorageTests(IngestTestCase):
    def test_stores_records_and_creates_device(self):
        record = quantity()
        response = self.post(ndjson(header_line(record_count=1), record))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["records_written"], 1)
        self.assertEqual(Device.objects.count(), 1)

        stored = Record.objects.get(id=record["id"])
        self.assertEqual(stored.value, 72.0)
        self.assertEqual(stored.unit, "count/min")
        self.assertEqual(stored.metric_slug, "heart_rate")
        self.assertEqual(stored.source_name, "Apple Watch")
        self.assertEqual(stored.tz, "Asia/Singapore")
        # 08:14:02+08:00 is 00:14:02Z — the per-sample offset has to survive.
        self.assertEqual(stored.start.isoformat(), "2026-07-31T00:14:02+00:00")

    def test_upsert_on_id_is_idempotent(self):
        record = quantity(value=72.0)
        self.post(ndjson(header_line(), record), key="a.ndjson")

        updated = dict(record, value=99.0)
        response = self.post(ndjson(header_line(batch_id="b"), updated), key="b.ndjson")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(Record.objects.count(), 1)
        self.assertEqual(Record.objects.get(id=record["id"]).value, 99.0)

    def test_duplicate_id_within_one_batch_does_not_fail(self):
        """Postgres refuses an ON CONFLICT that touches a row twice, so the
        batch has to be deduplicated before insert. Last line wins."""
        record = quantity(value=1.0)
        body = ndjson(header_line(record_count=2), record, dict(record, value=2.0))

        response = self.post(body)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(Record.objects.count(), 1)
        self.assertEqual(Record.objects.get(id=record["id"]).value, 2.0)

    def test_statistic_id_is_not_a_uuid(self):
        """Daily rollups use `stat:<slug>:<date>` so re-sending a day upserts.
        Modelling the PK as a UUID would break exactly this."""
        stat = {
            "id": "stat:step_count:2026-07-31",
            "kind": "statistic",
            "metric": "HKQuantityTypeIdentifierStepCount",
            "metric_slug": "step_count",
            "value": 8421,
            "unit": "count",
            "start": "2026-07-31T00:00:00+08:00",
            "end": "2026-07-31T23:59:59+08:00",
            "aggregation": "cumulative",
            "recorded_at": "2026-08-01T00:05:00+08:00",
            "schema_version": 1,
        }
        self.post(ndjson(header_line(), stat), key="s1.ndjson")
        self.post(ndjson(header_line(), dict(stat, value=9000)), key="s2.ndjson")

        self.assertEqual(Record.objects.filter(kind="statistic").count(), 1)
        self.assertEqual(Record.objects.get(id=stat["id"]).value, 9000.0)

    def test_null_value_and_missing_optional_fields(self):
        sparse = {
            "id": str(uuid.uuid4()),
            "kind": "characteristic",
            "metric": "HKCharacteristicTypeIdentifierBloodType",
            "metric_slug": "blood_type",
            "value_label": "APositive",
            "start": "2026-07-31T08:14:02+08:00",
            "end": "2026-07-31T08:14:02+08:00",
            "recorded_at": "2026-07-31T08:14:02+08:00",
        }
        response = self.post(ndjson(header_line(), sparse))

        self.assertEqual(response.status_code, 200)
        stored = Record.objects.get(id=sparse["id"])
        self.assertIsNone(stored.value)
        self.assertEqual(stored.value_label, "APositive")

    def test_metadata_and_extra_round_trip(self):
        record = quantity(
            metadata={"HKWasUserEntered": True},
            extra={"duration_seconds": 3600, "events": [{"type": "pause"}]},
        )
        self.post(ndjson(header_line(), record))

        stored = Record.objects.get(id=record["id"])
        self.assertEqual(stored.metadata, {"HKWasUserEntered": True})
        self.assertEqual(stored.extra["duration_seconds"], 3600)

    def test_nan_value_is_dropped_not_stored(self):
        record = quantity()
        line = json.dumps(record).replace("72.0", "NaN")
        body = (json.dumps(header_line()) + "\n" + line + "\n").encode()

        response = self.post(body)

        self.assertEqual(response.status_code, 200)
        self.assertIsNone(Record.objects.get(id=record["id"]).value)


class DeleteTests(IngestTestCase):
    def test_delete_tombstones_existing_record(self):
        record = quantity()
        self.post(ndjson(header_line(), record), key="a.ndjson")

        tombstone = {
            "id": record["id"],
            "kind": "delete",
            "metric": "unknown",
            "metric_slug": "unknown",
            "start": "2026-08-01T00:00:00+08:00",
            "end": "2026-08-01T00:00:00+08:00",
            "recorded_at": "2026-08-01T00:00:00+08:00",
            "deleted_at": "2026-08-01T00:00:00+08:00",
        }
        response = self.post(ndjson(header_line(batch_id="b"), tombstone), key="b.ndjson")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["deletes_applied"], 1)
        stored = Record.objects.get(id=record["id"])
        self.assertIsNotNone(stored.deleted_at)
        # The original detail is kept — a tombstone says "removed", not "forget".
        self.assertEqual(stored.metric_slug, "heart_rate")

    def test_delete_for_unknown_id_creates_tombstone(self):
        """A sample can be deleted before the first sync ever shipped it."""
        unknown = str(uuid.uuid4())
        tombstone = {"id": unknown, "kind": "delete", "metric": "unknown"}

        response = self.post(ndjson(header_line(), tombstone))

        self.assertEqual(response.json()["tombstones_created"], 1)
        self.assertIsNotNone(Record.objects.get(id=unknown).deleted_at)

    def test_resend_does_not_resurrect_deleted_record(self):
        """Deletion is one-way: a batch retried from the outbox must not undo a
        tombstone that arrived after it."""
        record = quantity()
        self.post(ndjson(header_line(), record), key="a.ndjson")
        self.post(
            ndjson(header_line(batch_id="b"), {"id": record["id"], "kind": "delete"}),
            key="b.ndjson",
        )

        self.post(ndjson(header_line(batch_id="c"), record), key="c.ndjson")

        self.assertIsNotNone(Record.objects.get(id=record["id"]).deleted_at)


class IdempotencyTests(IngestTestCase):
    def test_duplicate_key_replays_original_response(self):
        record = quantity()
        first = self.post(ndjson(header_line(), record), key="same.ndjson")
        second = self.post(ndjson(header_line(), record), key="same.ndjson")

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertFalse(first.json()["duplicate"])
        self.assertTrue(second.json()["duplicate"])
        self.assertEqual(
            first.json()["records_written"], second.json()["records_written"]
        )
        self.assertEqual(Batch.objects.count(), 1)

    def test_in_flight_duplicate_is_retryable_not_409(self):
        """A 409 tells the client the batch is safely stored. Claiming that
        while it is still processing would let the client archive data the
        server might yet fail to write."""
        Batch.objects.create(idempotency_key="busy.ndjson", status=Batch.Status.PROCESSING)

        response = self.post(ndjson(header_line()), key="busy.ndjson")

        self.assertEqual(response.status_code, 503)

    def test_batch_abandoned_mid_flight_is_reclaimed(self):
        """A worker killed during ingest leaves the row claimed forever. Without
        reclaiming, the client gets 503 on every retry of that key: a batch that
        can never complete and never fails."""
        from datetime import timedelta

        from ingest.service import STALE_PROCESSING_AFTER

        stuck = Batch.objects.create(
            idempotency_key="stuck.ndjson", status=Batch.Status.PROCESSING
        )
        Batch.objects.filter(pk=stuck.pk).update(
            received_at=timezone.now() - STALE_PROCESSING_AFTER - timedelta(minutes=1)
        )

        response = self.post(ndjson(header_line(), quantity()), key="stuck.ndjson")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(Record.objects.count(), 1)

    def test_recently_claimed_batch_is_not_stolen(self):
        """A slow but live ingest must not have its key taken out from under it."""
        Batch.objects.create(idempotency_key="live.ndjson", status=Batch.Status.PROCESSING)
        response = self.post(ndjson(header_line(), quantity()), key="live.ndjson")
        self.assertEqual(response.status_code, 503)

    def test_failed_batch_is_reprocessed_on_retry(self):
        record = quantity()
        Batch.objects.create(idempotency_key="retry.ndjson", status=Batch.Status.FAILED)

        response = self.post(ndjson(header_line(), record), key="retry.ndjson")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(Record.objects.count(), 1)


class ToleranceTests(IngestTestCase):
    def test_one_corrupt_line_is_skipped_not_fatal(self):
        """A permanent 4xx parks the batch on the client forever, so a single
        bad line must not cost the other 4,999 records."""
        good = [quantity() for _ in range(20)]
        body = (
            json.dumps(header_line(record_count=21))
            + "\n"
            + "\n".join(json.dumps(r) for r in good)
            + "\n{not json at all\n"
        ).encode()

        response = self.post(body)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["records_written"], 20)
        self.assertEqual(response.json()["skipped"], 1)

    def test_mostly_garbage_body_is_rejected(self):
        body = (
            json.dumps(header_line())
            + "\n"
            + "\n".join("{broken" for _ in range(10))
            + "\n"
        ).encode()

        response = self.post(body)

        self.assertEqual(response.status_code, 400)

    def test_record_without_id_is_skipped(self):
        no_id = {"kind": "quantity", "metric_slug": "heart_rate", "value": 1}
        response = self.post(ndjson(header_line(), quantity(), no_id))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["skipped"], 1)
        self.assertEqual(response.json()["records_written"], 1)


class CompressionTests(IngestTestCase):
    def test_gzipped_body_is_accepted(self):
        record = quantity()
        body = gzip.compress(ndjson(header_line(), record))

        response = self.post(body, **{"content-encoding": "gzip"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["records_written"], 1)
        self.assertEqual(Record.objects.get(id=record["id"]).value, 72.0)

    def test_corrupt_gzip_is_a_permanent_error(self):
        response = self.post(b"not gzip at all", **{"content-encoding": "gzip"})
        self.assertEqual(response.status_code, 400)


class LoginTests(TestCase):
    """Signing in trades a password for a bearer token, so the phone never has
    one pasted into it."""

    def setUp(self):
        # DRF keeps throttle history in the cache, which outlives a test case.
        # Without this the rate-limit test poisons every test that runs after it.
        cache.clear()
        self.user = User.objects.create_user(username="lionel", password="corr3ct-h0rse-battery")

    def login(self, username="lionel", password="corr3ct-h0rse-battery", **extra):
        return self.client.post(
            "/v1/auth/login",
            data=json.dumps({"username": username, "password": password, **extra}),
            content_type="application/json",
        )

    def test_login_returns_a_working_token(self):
        response = self.login(device_label="lionel-iphone")

        self.assertEqual(response.status_code, 200)
        token = response.json()["token"]
        self.assertEqual(response.json()["label"], "lionel-iphone")

        probe = self.client.get("/v1/health/ping", headers={"authorization": f"Bearer {token}"})
        self.assertEqual(probe.status_code, 200)

    def test_token_is_owned_by_the_user(self):
        self.login()
        self.assertEqual(ApiToken.objects.get().owner, self.user)

    def test_only_the_digest_is_stored(self):
        raw = self.login().json()["token"]
        stored = ApiToken.objects.get()
        self.assertEqual(stored.token_hash, ApiToken.hash_token(raw))
        self.assertNotIn(raw, stored.token_hash)

    def test_wrong_password_is_401(self):
        self.assertEqual(self.login(password="wrong").status_code, 401)

    def test_unknown_user_is_401_with_the_same_message(self):
        """Distinguishing 'no such user' from 'wrong password' would turn this
        into a username oracle."""
        unknown = self.login(username="nobody")
        wrong = self.login(password="wrong")
        self.assertEqual(unknown.status_code, 401)
        self.assertEqual(unknown.json()["detail"], wrong.json()["detail"])

    def test_inactive_user_cannot_sign_in(self):
        self.user.is_active = False
        self.user.save()
        self.assertEqual(self.login().status_code, 401)

    def test_missing_fields_is_400(self):
        response = self.client.post(
            "/v1/auth/login",
            data=json.dumps({"username": "lionel"}),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 400)

    def test_each_login_mints_a_distinct_token(self):
        first = self.login().json()["token"]
        second = self.login().json()["token"]
        self.assertNotEqual(first, second)
        self.assertEqual(ApiToken.objects.count(), 2)

    def test_logout_revokes_only_that_token(self):
        keep = self.login().json()["token"]
        drop = self.login().json()["token"]

        response = self.client.post(
            "/v1/auth/logout", headers={"authorization": f"Bearer {drop}"}
        )
        self.assertEqual(response.status_code, 200)

        # The revoked one stops working; the other device stays signed in.
        self.assertEqual(
            self.client.get("/v1/health/ping", headers={"authorization": f"Bearer {drop}"}).status_code,
            401,
        )
        self.assertEqual(
            self.client.get("/v1/health/ping", headers={"authorization": f"Bearer {keep}"}).status_code,
            200,
        )

    def test_login_is_rate_limited(self):
        """This is the only endpoint that accepts a password, so it is the only
        one worth guessing at."""
        codes = {self.login(password="wrong").status_code for _ in range(12)}
        self.assertIn(429, codes)


class ProbeTests(IngestTestCase):
    def test_healthz_needs_no_token(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")

    def test_ping_requires_token(self):
        self.assertEqual(self.client.get("/v1/health/ping").status_code, 401)

    def test_ping_reports_token_label(self):
        response = self.client.get(
            "/v1/health/ping", headers={"authorization": f"Bearer {self.raw}"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["token"], "test-iphone")

    def test_stats_summarises(self):
        cache.clear()
        self.post(ndjson(header_line(), quantity()))
        response = self.client.get(
            "/v1/health/stats?fresh=1", headers={"authorization": f"Bearer {self.raw}"}
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["records_total"], 1)
        self.assertEqual(len(body["devices"]), 1)
        self.assertEqual(body["devices"][0]["record_count"], 1)
        self.assertEqual(body["metrics"][0]["metric_slug"], "heart_rate")
        self.assertEqual(body["metrics"][0]["unit"], "count/min")
        self.assertIsNotNone(body["last_batch_at"])

    def test_stats_excludes_tombstones_from_metrics(self):
        """A deleted record must not still be counted as live data — that would
        make the app report sync as healthy after everything was removed."""
        cache.clear()
        record = quantity()
        self.post(ndjson(header_line(), record), key="a.ndjson")
        self.post(
            ndjson(header_line(batch_id="b"), {"id": record["id"], "kind": "delete"}),
            key="b.ndjson",
        )

        body = self.client.get(
            "/v1/health/stats?fresh=1", headers={"authorization": f"Bearer {self.raw}"}
        ).json()

        self.assertEqual(body["records_deleted"], 1)
        self.assertEqual([m for m in body["metrics"] if m["metric_slug"] == "heart_rate"], [])

    def test_stats_is_cached_between_calls(self):
        cache.clear()
        self.post(ndjson(header_line(), quantity()))
        first = self.client.get(
            "/v1/health/stats", headers={"authorization": f"Bearer {self.raw}"}
        ).json()
        second = self.client.get(
            "/v1/health/stats", headers={"authorization": f"Bearer {self.raw}"}
        ).json()

        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        # Aggregates scan the whole table; pull-to-refresh must not be able to
        # hammer the database.
        self.assertEqual(first["generated_at"], second["generated_at"])
