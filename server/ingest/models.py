import hashlib
import secrets

from django.conf import settings
from django.db import models
from django.utils import timezone


class Device(models.Model):
    """One iPhone. `device_id` is the UUID the app generates on first launch and
    persists in `device-id.json` — it survives reinstalls only if the app data
    does, so a reinstalled app shows up as a new device rather than silently
    merging into the old one."""

    device_id = models.CharField(max_length=128, unique=True)
    label = models.CharField(max_length=128, blank=True)
    last_app_version = models.CharField(max_length=64, blank=True)
    first_seen_at = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return self.label or self.device_id


class ApiToken(models.Model):
    """Bearer token for the ingest endpoint.

    Only the SHA-256 digest is stored. The raw token is shown exactly once, at
    creation time — there is no recovery path, which is the point: a database
    dump must not yield working credentials for a health-data endpoint.
    """

    token_hash = models.CharField(max_length=64, unique=True, db_index=True)
    label = models.CharField(max_length=128)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="api_tokens",
        null=True,
        blank=True,
        help_text="Set when the token was obtained by signing in; null for tokens minted on the CLI.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    last_used_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    @staticmethod
    def hash_token(raw: str) -> str:
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    @classmethod
    def issue(cls, label: str, owner=None) -> tuple["ApiToken", str]:
        """Returns (token, raw_secret). The raw secret is unrecoverable after this."""
        raw = secrets.token_urlsafe(32)
        token = cls.objects.create(
            token_hash=cls.hash_token(raw), label=label, owner=owner
        )
        return token, raw

    @property
    def is_active(self) -> bool:
        return self.revoked_at is None

    def __str__(self):
        state = "revoked" if self.revoked_at else "active"
        return f"{self.label} ({state})"


class Batch(models.Model):
    """One uploaded NDJSON file.

    `idempotency_key` is the batch filename the client sends in the
    Idempotency-Key header. It is the deduplication key for the whole endpoint:
    the client retries aggressively after network failures, and most retries are
    of requests that already landed.
    """

    class Status(models.TextChoices):
        PROCESSING = "processing"
        STORED = "stored"
        FAILED = "failed"

    idempotency_key = models.CharField(max_length=255, unique=True)
    batch_id = models.CharField(max_length=128, db_index=True)
    device = models.ForeignKey(
        Device, on_delete=models.CASCADE, related_name="batches", null=True
    )
    status = models.CharField(
        max_length=16, choices=Status.choices, default=Status.PROCESSING
    )
    declared_record_count = models.IntegerField(default=0)
    stored_record_count = models.IntegerField(default=0)
    deleted_record_count = models.IntegerField(default=0)
    skipped_record_count = models.IntegerField(default=0)
    app_version = models.CharField(max_length=64, blank=True)
    schema_version = models.IntegerField(default=1)
    window_from = models.DateTimeField(null=True, blank=True)
    window_to = models.DateTimeField(null=True, blank=True)
    client_created_at = models.DateTimeField(null=True, blank=True)
    received_at = models.DateTimeField(auto_now_add=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    byte_count = models.BigIntegerField(default=0)
    error = models.TextField(blank=True)
    # The exact body returned on first success, replayed verbatim for duplicate
    # Idempotency-Keys so a retry is indistinguishable from the original call.
    response = models.JSONField(null=True, blank=True)

    class Meta:
        ordering = ("-received_at",)
        indexes = [models.Index(fields=["status", "received_at"])]

    def mark_stored(self, response: dict):
        self.status = self.Status.STORED
        self.response = response
        self.completed_at = timezone.now()
        self.save(
            update_fields=[
                "status",
                "response",
                "completed_at",
                "stored_record_count",
                "deleted_record_count",
                "skipped_record_count",
            ]
        )

    def mark_failed(self, error: str):
        self.status = self.Status.FAILED
        self.error = error[:4000]
        self.save(update_fields=["status", "error"])

    def __str__(self):
        return self.idempotency_key


class Record(models.Model):
    """One HealthKit datum, flat.

    The primary key is the client's `id`, which is *not* always a UUID: daily
    rollups use a deterministic `stat:<slug>:<yyyy-mm-dd>` so re-sending a day
    upserts instead of duplicating. Hence CharField rather than UUIDField —
    modelling this as a UUID column is the single easiest way to break rollups.
    """

    class Kind(models.TextChoices):
        QUANTITY = "quantity"
        CATEGORY = "category"
        SLEEP = "sleep"
        WORKOUT = "workout"
        CORRELATION = "correlation"
        STATISTIC = "statistic"
        CHARACTERISTIC = "characteristic"
        DELETE = "delete"

    id = models.CharField(max_length=255, primary_key=True)
    device = models.ForeignKey(
        Device, on_delete=models.CASCADE, related_name="records", null=True
    )
    batch = models.ForeignKey(
        Batch, on_delete=models.SET_NULL, related_name="records", null=True
    )

    kind = models.CharField(max_length=32, choices=Kind.choices)
    metric = models.CharField(max_length=128)
    metric_slug = models.CharField(max_length=128)

    value = models.FloatField(null=True, blank=True)
    unit = models.CharField(max_length=64, blank=True)
    value_label = models.CharField(max_length=128, blank=True)

    start = models.DateTimeField(null=True, db_index=True)
    end = models.DateTimeField(null=True)
    tz = models.CharField(max_length=64, blank=True)
    aggregation = models.CharField(max_length=16, blank=True)

    source_name = models.CharField(max_length=128, blank=True)
    source_bundle_id = models.CharField(max_length=255, blank=True)
    source_product_type = models.CharField(max_length=64, blank=True)
    source_os_version = models.CharField(max_length=64, blank=True)
    hardware = models.CharField(max_length=255, blank=True)

    metadata = models.JSONField(null=True, blank=True)
    extra = models.JSONField(null=True, blank=True)

    recorded_at = models.DateTimeField(null=True, blank=True)
    # Set when HealthKit reports the sample was removed. Tombstones carry a UUID
    # and nothing else, so a delete can arrive for a record that was never
    # received — those are stored as kind=delete with metric="unknown" so a
    # later-arriving sample can still be reconciled against them.
    deleted_at = models.DateTimeField(null=True, blank=True, db_index=True)
    schema_version = models.IntegerField(default=1)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        indexes = [
            models.Index(fields=["metric_slug", "start"]),
            models.Index(fields=["device", "start"]),
            models.Index(fields=["kind", "start"]),
        ]

    def __str__(self):
        return f"{self.metric_slug}@{self.start:%Y-%m-%d %H:%M}" if self.start else self.id
