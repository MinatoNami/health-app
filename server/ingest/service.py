"""Turning an NDJSON batch into rows.

The contract this implements is the one documented in the app's README:

* upsert on ``id`` so retries are free,
* replay the original response for a duplicate ``Idempotency-Key``,
* 5xx/429 means "try later", other 4xx means "never going to work".

The client parks a batch permanently on any non-retryable 4xx, so this leans
toward accepting-and-counting bad individual records rather than rejecting a
whole file over one corrupt line.
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone as dt_timezone

from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from .models import Batch, Device, Record
from .ndjson import iter_objects

log = logging.getLogger(__name__)

# A batch of 5,000 records at ~1KB each is ~5MB; 64MB leaves generous headroom
# without letting an unauthenticated-shaped request pin memory.
MAX_BATCH_BYTES = 64 * 1024 * 1024

# One corrupt line shouldn't park an entire batch on the client, but a body
# that is mostly garbage is a real error and should surface as one.
#
# Both bounds have to be crossed. A ratio alone rejects a 2-record batch over a
# single bad line, which is the opposite of the intent; a floor alone lets a
# 5,000-record batch quietly lose 400 records.
MAX_SKIP_RATIO = 0.10
MAX_SKIP_FLOOR = 5

UPSERT_CHUNK = 1_000

# Deliberately excludes `deleted_at`: a re-sent sample must never resurrect a
# record that HealthKit has since tombstoned. Deletion is one-way.
UPDATE_FIELDS = [
    "device",
    "batch",
    "kind",
    "metric",
    "metric_slug",
    "value",
    "unit",
    "value_label",
    "start",
    "end",
    "tz",
    "aggregation",
    "source_name",
    "source_bundle_id",
    "source_product_type",
    "source_os_version",
    "hardware",
    "metadata",
    "extra",
    "recorded_at",
    "schema_version",
    "updated_at",
]


class BatchRejected(Exception):
    """Permanent, client-visible failure — maps to 4xx."""


@dataclass
class IngestResult:
    records_received: int = 0
    records_written: int = 0
    deletes_applied: int = 0
    tombstones_created: int = 0
    skipped: int = 0
    skip_samples: list[str] = field(default_factory=list)

    def as_response(self, batch: Batch) -> dict:
        return {
            "status": "stored",
            "batch_id": batch.batch_id,
            "idempotency_key": batch.idempotency_key,
            "records_received": self.records_received,
            "records_written": self.records_written,
            "deletes_applied": self.deletes_applied,
            "tombstones_created": self.tombstones_created,
            "skipped": self.skipped,
            "duplicate": False,
        }


def _parse_ts(raw) -> datetime | None:
    """ISO-8601 with a per-sample UTC offset. Naive values are read as UTC —
    the app always emits an offset, so a naive timestamp means someone else
    wrote the file."""
    if not raw or not isinstance(raw, str):
        return None
    parsed = parse_datetime(raw)
    if parsed is None:
        return None
    if timezone.is_naive(parsed):
        return parsed.replace(tzinfo=dt_timezone.utc)
    return parsed


def _parse_float(raw) -> float | None:
    if raw is None or isinstance(raw, bool):
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    # NaN/inf round-trip out of JSON but have no meaning as a measurement, and
    # Postgres double precision accepts them silently.
    if value != value or value in (float("inf"), float("-inf")):
        return None
    return value


def _text(raw, limit: int) -> str:
    if raw is None:
        return ""
    return str(raw)[:limit]


def _record_from_wire(obj: dict, device: Device, batch: Batch) -> Record:
    source = obj.get("source") or {}
    if not isinstance(source, dict):
        source = {}

    metadata = obj.get("metadata")
    extra = obj.get("extra")

    return Record(
        id=_text(obj["id"], 255),
        device=device,
        batch=batch,
        kind=_text(obj.get("kind"), 32),
        metric=_text(obj.get("metric"), 128),
        metric_slug=_text(obj.get("metric_slug"), 128),
        value=_parse_float(obj.get("value")),
        unit=_text(obj.get("unit"), 64),
        value_label=_text(obj.get("value_label"), 128),
        start=_parse_ts(obj.get("start")),
        end=_parse_ts(obj.get("end")),
        tz=_text(obj.get("tz"), 64),
        aggregation=_text(obj.get("aggregation"), 16),
        source_name=_text(source.get("name"), 128),
        source_bundle_id=_text(source.get("bundle_id"), 255),
        source_product_type=_text(source.get("product_type"), 64),
        source_os_version=_text(source.get("os_version"), 64),
        hardware=_text(obj.get("device"), 255),
        metadata=metadata if isinstance(metadata, dict) else None,
        extra=extra if isinstance(extra, dict) else None,
        recorded_at=_parse_ts(obj.get("recorded_at")),
        deleted_at=_parse_ts(obj.get("deleted_at")),
        schema_version=int(obj.get("schema_version") or 1),
    )


def read_header(parsed) -> dict:
    """The first line must be the batch header. Without it there is no device
    identity and no declared count to check completeness against."""
    if parsed is None:
        raise BatchRejected("empty body: expected a batch_header line")
    if parsed.error:
        raise BatchRejected(f"first line is not valid JSON ({parsed.error})")
    if parsed.obj.get("kind") != "batch_header":
        raise BatchRejected("first line must be a batch_header record")
    if not parsed.obj.get("batch_id"):
        raise BatchRejected("batch_header is missing batch_id")
    if not parsed.obj.get("device_id"):
        raise BatchRejected("batch_header is missing device_id")
    return parsed.obj


def ingest(stream, batch: Batch) -> IngestResult:
    """Consumes the stream into rows. `batch` is an already-claimed row.

    Raises BatchRejected for permanent problems; anything else propagates and
    is reported as retryable.
    """
    result = IngestResult()
    stream_iter = iter_objects(stream, MAX_BATCH_BYTES)

    header = read_header(next(stream_iter, None))

    device, _ = Device.objects.get_or_create(
        device_id=_text(header["device_id"], 128),
        defaults={"last_app_version": _text(header.get("app_version"), 64)},
    )
    device.last_app_version = _text(header.get("app_version"), 64)
    device.save(update_fields=["last_app_version", "last_seen_at"])

    batch.device = device
    batch.batch_id = _text(header["batch_id"], 128)
    batch.declared_record_count = int(header.get("record_count") or 0)
    batch.app_version = _text(header.get("app_version"), 64)
    batch.schema_version = int(header.get("schema_version") or 1)
    batch.window_from = _parse_ts(header.get("window_from"))
    batch.window_to = _parse_ts(header.get("window_to"))
    batch.client_created_at = _parse_ts(header.get("created_at"))
    batch.save()

    # Deduplicated in-batch: Postgres refuses an ON CONFLICT DO UPDATE that
    # touches the same row twice, so a batch containing the same id on two
    # lines would fail the whole insert. Last line wins.
    pending: dict[str, Record] = {}
    delete_ids: list[str] = []

    for parsed in stream_iter:
        result.records_received += 1

        if parsed.error:
            result.skipped += 1
            if len(result.skip_samples) < 5:
                result.skip_samples.append(f"line {parsed.number}: {parsed.error}")
            continue

        obj = parsed.obj
        if obj.get("kind") == "batch_header":
            # A second header means two files were concatenated. The device and
            # counts would be wrong for everything after it.
            raise BatchRejected(f"unexpected second batch_header at line {parsed.number}")

        record_id = obj.get("id")
        if not record_id or not isinstance(record_id, str):
            result.skipped += 1
            if len(result.skip_samples) < 5:
                result.skip_samples.append(f"line {parsed.number}: missing id")
            continue

        if obj.get("kind") == Record.Kind.DELETE:
            delete_ids.append(record_id[:255])
            pending.pop(record_id[:255], None)
            continue

        try:
            pending[record_id[:255]] = _record_from_wire(obj, device, batch)
        except Exception as exc:  # noqa: BLE001 - one bad record must not kill the batch
            result.skipped += 1
            if len(result.skip_samples) < 5:
                result.skip_samples.append(f"line {parsed.number}: {exc}")

    if (
        result.skipped > MAX_SKIP_FLOOR
        and result.records_received
        and result.skipped / result.records_received > MAX_SKIP_RATIO
    ):
        raise BatchRejected(
            f"{result.skipped} of {result.records_received} records were unreadable: "
            + "; ".join(result.skip_samples)
        )

    with transaction.atomic():
        result.records_written = _upsert(list(pending.values()))
        applied, created = _apply_deletes(delete_ids, device, batch)
        result.deletes_applied = applied
        result.tombstones_created = created

    batch.stored_record_count = result.records_written
    batch.deleted_record_count = result.deletes_applied + result.tombstones_created
    batch.skipped_record_count = result.skipped
    return result


def _upsert(records: list[Record]) -> int:
    """Insert-or-update on the client's id. Sample UUIDs are stable across
    reads, so this is what makes a retry free."""
    written = 0
    for start in range(0, len(records), UPSERT_CHUNK):
        chunk = records[start : start + UPSERT_CHUNK]
        Record.objects.bulk_create(
            chunk,
            update_conflicts=True,
            update_fields=UPDATE_FIELDS,
            unique_fields=["id"],
        )
        written += len(chunk)
    return written


def _apply_deletes(delete_ids: list[str], device: Device, batch: Batch) -> tuple[int, int]:
    """Tombstones carry a UUID and nothing else — no type, no date.

    A delete can legitimately arrive for a sample this server never received
    (deleted before the first sync reached it), so unmatched ids are stored as
    delete-kind rows. Ignoring them lets the store diverge from Health
    permanently with nothing to indicate it happened.
    """
    if not delete_ids:
        return 0, 0

    unique_ids = list(dict.fromkeys(delete_ids))
    now = timezone.now()
    applied = 0
    tombstones: list[Record] = []

    for start in range(0, len(unique_ids), UPSERT_CHUNK):
        chunk = unique_ids[start : start + UPSERT_CHUNK]
        existing = set(
            Record.objects.filter(id__in=chunk).values_list("id", flat=True)
        )
        applied += Record.objects.filter(id__in=list(existing), deleted_at__isnull=True).update(
            deleted_at=now, updated_at=now
        )
        tombstones.extend(
            Record(
                id=record_id,
                device=device,
                batch=batch,
                kind=Record.Kind.DELETE,
                metric="unknown",
                metric_slug="unknown",
                deleted_at=now,
            )
            for record_id in chunk
            if record_id not in existing
        )

    created = 0
    for start in range(0, len(tombstones), UPSERT_CHUNK):
        chunk = tombstones[start : start + UPSERT_CHUNK]
        created += len(Record.objects.bulk_create(chunk, ignore_conflicts=True))

    return applied, created


# How long a batch may sit in PROCESSING before it is assumed dead.
#
# A worker killed mid-ingest — a deploy, an OOM, a restart — leaves the row
# claimed forever. The client then gets 503 on every retry of that key, backs
# off, gives up for the run, and tries again next sync: a batch that can never
# complete and never fails, retried indefinitely. Generous enough that a
# genuinely slow ingest is never stolen from a live worker.
STALE_PROCESSING_AFTER = timedelta(minutes=30)


@transaction.atomic
def claim_batch(idempotency_key: str, byte_count: int = 0) -> tuple[Batch, bool]:
    """Reserves the key. Returns (batch, is_new).

    A previously failed batch is reclaimed so a retry reprocesses it rather
    than replaying a failure forever. So is one abandoned mid-flight.
    """
    batch, created = Batch.objects.select_for_update().get_or_create(
        idempotency_key=idempotency_key,
        defaults={"batch_id": "", "byte_count": byte_count},
    )
    if created:
        return batch, True

    if batch.status == Batch.Status.FAILED:
        batch.status = Batch.Status.PROCESSING
        batch.error = ""
        batch.save(update_fields=["status", "error"])
        return batch, True

    if (
        batch.status == Batch.Status.PROCESSING
        and timezone.now() - batch.received_at > STALE_PROCESSING_AFTER
    ):
        log.warning(
            "Reclaiming batch %s abandoned in processing since %s",
            idempotency_key,
            batch.received_at,
        )
        batch.received_at = timezone.now()
        batch.save(update_fields=["received_at"])
        return batch, True

    return batch, created
