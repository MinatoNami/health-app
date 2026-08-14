import hashlib
import os
import secrets
import uuid
from datetime import timedelta

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


class Goal(models.Model):
    """A target the person set for themselves.

    Stored server-side rather than on the phone because the insight layer needs
    them: "am I on track" is unanswerable without knowing what the track is, and
    progress has to be *counted* rather than inferred by a model.
    """

    class Cadence(models.TextChoices):
        DAILY = "daily"
        WEEKLY = "weekly"

    metric_slug = models.CharField(max_length=128, db_index=True)
    label = models.CharField(max_length=128, blank=True)
    target_value = models.FloatField()
    unit = models.CharField(max_length=32, blank=True)
    cadence = models.CharField(max_length=16, choices=Cadence.choices, default=Cadence.DAILY)
    note = models.TextField(blank=True)
    active = models.BooleanField(default=True)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="health_goals",
        null=True,
        blank=True,
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("metric_slug",)
        constraints = [
            models.UniqueConstraint(
                fields=["metric_slug", "cadence"], name="unique_goal_per_metric_cadence"
            )
        ]

    def __str__(self):
        return f"{self.metric_slug} ≥ {self.target_value} {self.unit}".strip()


class AlertState(models.Model):
    """One open (or closed) alert, so the notifier does not nag.

    Without durable state the nightly freshness check would announce the same
    dead metric every night for a month, which is how an alert becomes something
    people filter to a folder they never open. `resolved_at` is what makes
    recovery reportable: you learn the fix worked without going to look.
    """

    key = models.CharField(max_length=128, unique=True)
    label = models.CharField(max_length=128, blank=True)
    detail = models.TextField(blank=True)
    first_seen_at = models.DateTimeField(auto_now_add=True)
    last_sent_at = models.DateTimeField(default=timezone.now)
    resolved_at = models.DateTimeField(null=True, blank=True)
    # False when the webhook was unreachable. The state is still written, so a
    # broken notifier cannot cause a re-alert storm once it recovers.
    notified = models.BooleanField(default=False)

    class Meta:
        ordering = ("-last_sent_at",)

    def __str__(self):
        return f"{self.key} ({'resolved' if self.resolved_at else 'open'})"


class ChatProject(models.Model):
    """A folder of related conversations, with instructions they all inherit.

    The grouping is the cheap half. The reason a project is a database row
    rather than a label on the sidebar is `instructions`: standing context that
    is prepended to the system prompt for every session inside it, so "I am
    training for a half marathon in October" is typed once instead of at the top
    of every chat. That is the only thing here the model actually reads, and it
    is deliberately free text the user wrote about themselves — never anything
    derived from their health records.
    """

    name = models.CharField(max_length=120)
    instructions = models.TextField(
        blank=True,
        help_text="Standing context prepended to the system prompt for every session "
        "in this project.",
    )
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="chat_projects",
        null=True,
        blank=True,
    )
    archived = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("name",)

    def as_dict(self, session_count: int | None = None) -> dict:
        payload = {
            "id": self.pk,
            "name": self.name,
            "instructions": self.instructions,
            "archived": self.archived,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
        }
        if session_count is not None:
            payload["session_count"] = session_count
        return payload

    def __str__(self):
        return self.name


class ChatSession(models.Model):
    """One conversation: an ordered run of turns that share a context window.

    The primary key is a UUID rather than a sequence. Session ids travel in URLs
    the browser keeps and in the export endpoint's filters, and a guessable
    integer over health conversations is an enumeration invitation for no gain.

    `last_message_at` is set at creation and touched on every stored turn, so
    the sidebar can order by recency without a subquery and a brand-new empty
    chat still sorts to the top where the person just clicked. Ordering on
    `updated_at` instead would reshuffle the list every time a title was edited.
    """

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    project = models.ForeignKey(
        ChatProject,
        on_delete=models.SET_NULL,
        related_name="sessions",
        null=True,
        blank=True,
        help_text="Null means the chat sits outside any project.",
    )
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="chat_sessions",
        null=True,
        blank=True,
    )
    title = models.CharField(max_length=200, blank=True)
    # Set once somebody renames a chat by hand, which stops the first-question
    # autotitle from overwriting their name on the next message.
    title_locked = models.BooleanField(default=False)
    archived = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    last_message_at = models.DateTimeField(default=timezone.now, db_index=True)

    # Compaction. `summary` stands in for every turn up to `summary_through_at`
    # when the conversation is replayed, so a long chat keeps its thread instead
    # of losing its opening to a turn cap.
    #
    # It replaces those turns *in the prompt only*. The transcript on screen and
    # in the export is never rewritten — compaction exists to fit a context
    # window, and destroying what was actually said to save room would be a
    # strange trade in a system built around auditable answers.
    summary = models.TextField(blank=True)
    # A timestamp rather than a foreign key to the last folded turn: retention
    # deletes turns, and a FK would go null and leave a summary covering an
    # unknown range. A timestamp still answers "what comes after this".
    summary_through_at = models.DateTimeField(null=True, blank=True)
    summary_turns = models.IntegerField(default=0)
    summarised_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ("-last_message_at",)
        indexes = [models.Index(fields=["owner", "-last_message_at"])]

    TITLE_CHARS = 60

    def pending_turns(self):
        """Turns not yet folded into the summary, oldest first."""
        queryset = self.turns.order_by("created_at")
        if self.summary_through_at:
            queryset = queryset.filter(created_at__gt=self.summary_through_at)
        return queryset

    def clear_summary(self) -> None:
        self.summary = ""
        self.summary_through_at = None
        self.summary_turns = 0
        self.summarised_at = None

    def autotitle(self, question: str) -> None:
        """Name an untitled chat after its first question.

        Deterministic on purpose. Asking the model for a title would mean a
        second generation — tens of seconds on a local GPU — to produce
        something the first line of the question already says.
        """
        if self.title_locked or self.title:
            return
        text = " ".join((question or "").split())
        if not text:
            return
        self.title = text if len(text) <= self.TITLE_CHARS else text[: self.TITLE_CHARS - 1] + "…"

    def touch(self, when=None) -> None:
        self.last_message_at = when or timezone.now()

    def as_dict(self, *, message_count: int | None = None, preview: str | None = None) -> dict:
        payload = {
            "id": str(self.pk),
            "title": self.title or "New chat",
            "project_id": self.project_id,
            "archived": self.archived,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "last_message_at": self.last_message_at.isoformat(),
            "summary": self.summary or None,
            "summary_turns": self.summary_turns,
            "summary_through_at": (
                self.summary_through_at.isoformat() if self.summary_through_at else None
            ),
            "summarised_at": self.summarised_at.isoformat() if self.summarised_at else None,
        }
        if message_count is not None:
            payload["message_count"] = message_count
        if preview is not None:
            payload["preview"] = preview
        return payload

    def __str__(self):
        return self.title or f"chat {self.pk}"


class InsightTurn(models.Model):
    """One question and the answer that came back.

    Kept so an answer can be re-read and audited — a generated health claim that
    cannot be produced again later is not one anybody can check.

    Deliberately *not* stored: the health snapshot the answer was built from. It
    is derived from records still in this database and can be recomputed, so a
    second copy would only widen what a deletion request has to reach. §8 of the
    integration notes also asks that prompts and responses not be retained
    indefinitely, which `prune` enforces.

    `session` is nullable because turns predate sessions and because the phone
    and the `weekly_review` command both ask questions without opening a chat.
    A turn with no session is still a stored question subject to retention; it
    simply does not appear in the sidebar.
    """

    session = models.ForeignKey(
        ChatSession,
        on_delete=models.CASCADE,
        related_name="turns",
        null=True,
        blank=True,
    )
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="insight_turns",
        null=True,
        blank=True,
    )
    question = models.TextField(blank=True)
    answer = models.JSONField(null=True, blank=True)
    safety = models.JSONField(null=True, blank=True)
    tool_calls = models.JSONField(null=True, blank=True)
    model_name = models.CharField(max_length=128, blank=True)
    # Digest of the prompt text this build sent. Without it, answers written
    # before and after a prompt edit are indistinguishable in the export, and
    # "did my change help?" can only ever be answered about a single undated
    # blur of every answer ever given.
    prompt_version = models.CharField(max_length=16, blank=True, db_index=True)
    latency_ms = models.IntegerField(default=0)
    # Reported by the model server, so exact rather than estimated. Kept for two
    # reasons: a feedback loop wants to know what an answer cost, and the
    # compaction budget calibrates its own character-based estimate against the
    # last turn's real figure.
    prompt_tokens = models.IntegerField(default=0)
    completion_tokens = models.IntegerField(default=0)
    error = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    # What the person thought of the answer.
    #
    # The only field on this model somebody sets by hand, and the only one that
    # can be changed after the fact — everything else is a record of what
    # happened and editing it would destroy the reason to keep it. This is the
    # signal a feedback loop is actually built on: the rest of the row says what
    # the system did, and this says whether it was any good.
    #
    # `note` matters more than the thumb. "Used the wrong sleep window" is
    # something you can act on; a bare thumbs-down over a hundred answers tells
    # you the score and not the reason.
    class Rating(models.IntegerChoices):
        DOWN = -1, "Not useful"
        UP = 1, "Useful"

    rating = models.SmallIntegerField(
        null=True, blank=True, choices=Rating.choices, db_index=True
    )
    note = models.TextField(blank=True)
    rated_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ("-created_at",)
        indexes = [models.Index(fields=["session", "created_at"])]

    NOTE_CHARS = 2000

    @staticmethod
    def retention_days() -> int:
        try:
            return max(1, int(os.environ.get("INSIGHT_RETENTION_DAYS", "30")))
        except ValueError:
            return 30

    @staticmethod
    def keep_rated() -> bool:
        """Whether a turn you rated outlives the retention window.

        On by default, and that is a deliberate softening of §8 rather than an
        oversight. Retention exists so health questions are not kept
        indefinitely *by default*; a thumb or a note is the data subject — the
        only person involved — explicitly marking one as worth keeping. Without
        this the feedback loop can never hold more than thirty days of judged
        answers, which caps it at roughly nothing.

        `INSIGHT_KEEP_RATED=0` restores the stricter behaviour, and the
        retention table in docs/PRIVACY.md says which is in force.
        """
        return os.environ.get("INSIGHT_KEEP_RATED", "1").strip().lower() not in (
            "0",
            "false",
            "no",
        )

    @classmethod
    def prune(cls) -> int:
        """Delete expired turns, then the chats left holding nothing.

        The second half is not tidiness. Retention deletes the messages but the
        session row survives it, so a sidebar built on sessions alone would list
        month-old conversations that open empty — which reads as data loss
        rather than as the retention policy working. Sessions younger than the
        cutoff are left alone even when empty: that is a chat someone just
        opened and has not typed in yet.
        """
        cutoff = timezone.now() - timedelta(days=cls.retention_days())
        expired = cls.objects.filter(created_at__lt=cutoff)
        if cls.keep_rated():
            expired = expired.filter(rating__isnull=True, note="")
        deleted, _ = expired.delete()

        # A compaction is generated *from* questions. Once the newest turn it
        # folded in has aged out, every question behind it is gone and the
        # summary is the only surviving description of them — which would make
        # retention a thing you can read around. Clear it.
        for session in ChatSession.objects.filter(summary_through_at__lt=cutoff).exclude(summary=""):
            session.clear_summary()
            session.save(
                update_fields=[
                    "summary",
                    "summary_through_at",
                    "summary_turns",
                    "summarised_at",
                    "updated_at",
                ]
            )

        ChatSession.objects.filter(turns__isnull=True, created_at__lt=cutoff).delete()
        return deleted

    def as_dict(self) -> dict:
        return {
            "id": self.pk,
            "session_id": str(self.session_id) if self.session_id else None,
            "question": self.question,
            "answer": self.answer,
            "safety": self.safety,
            "tool_calls": self.tool_calls,
            "model_name": self.model_name,
            "prompt_version": self.prompt_version,
            "latency_ms": self.latency_ms,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "error": self.error,
            "created_at": self.created_at.isoformat(),
            "rating": self.rating,
            "note": self.note,
            "rated_at": self.rated_at.isoformat() if self.rated_at else None,
        }

    def set_feedback(self, rating, note: str) -> None:
        """Record what somebody thought of this answer.

        Clearing is a first-class outcome rather than an oversight: people
        mis-tap, and a rating you cannot take back is one nobody trusts enough
        to give. `rated_at` goes with it, so an un-rated turn does not look like
        one that was rated at some point and then blanked.
        """
        self.rating = rating
        self.note = (note or "")[: self.NOTE_CHARS]
        self.rated_at = timezone.now() if (rating is not None or self.note) else None

    def __str__(self):
        return f"{self.created_at:%Y-%m-%d %H:%M} {self.question[:60]}"
