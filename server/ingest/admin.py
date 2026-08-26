from django.contrib import admin
from django.utils import timezone

from .models import (
    ApiToken,
    Batch,
    ChatProject,
    ChatSession,
    Device,
    Goal,
    InsightTurn,
    Record,
)


@admin.register(Device)
class DeviceAdmin(admin.ModelAdmin):
    list_display = ("device_id", "label", "last_app_version", "last_seen_at")
    search_fields = ("device_id", "label")


@admin.register(ApiToken)
class ApiTokenAdmin(admin.ModelAdmin):
    list_display = ("label", "owner", "created_at", "last_used_at", "revoked_at")
    list_filter = ("owner",)
    readonly_fields = ("token_hash", "created_at", "last_used_at")
    actions = ("revoke",)

    def has_add_permission(self, request):
        # Tokens are minted by `manage.py issue_token`, which is the only path
        # that shows the raw secret. Creating one here would store a digest of
        # nothing usable.
        return False

    @admin.action(description="Revoke selected tokens")
    def revoke(self, request, queryset):
        updated = queryset.filter(revoked_at__isnull=True).update(revoked_at=timezone.now())
        self.message_user(request, f"Revoked {updated} token(s).")


@admin.register(Batch)
class BatchAdmin(admin.ModelAdmin):
    list_display = (
        "idempotency_key",
        "status",
        "device",
        "declared_record_count",
        "stored_record_count",
        "skipped_record_count",
        "received_at",
    )
    list_filter = ("status", "device")
    search_fields = ("idempotency_key", "batch_id")
    readonly_fields = tuple(f.name for f in Batch._meta.fields)


@admin.register(Record)
class RecordAdmin(admin.ModelAdmin):
    list_display = ("id", "kind", "metric_slug", "value", "unit", "start", "deleted_at")
    list_filter = ("kind", "aggregation", "deleted_at")
    search_fields = ("id", "metric", "metric_slug")
    readonly_fields = tuple(f.name for f in Record._meta.fields)
    # Counting millions of rows to render a paginator makes the changelist
    # unusable; Postgres has no cheap exact COUNT for a filtered table.
    show_full_result_count = False

    def has_add_permission(self, request):
        return False


@admin.register(Goal)
class GoalAdmin(admin.ModelAdmin):
    list_display = ("metric_slug", "target_value", "unit", "cadence", "active", "owner")
    list_filter = ("cadence", "active")
    search_fields = ("metric_slug", "label")


@admin.register(ChatProject)
class ChatProjectAdmin(admin.ModelAdmin):
    list_display = ("name", "owner", "archived", "updated_at")
    list_filter = ("archived",)
    search_fields = ("name", "instructions")


@admin.register(ChatSession)
class ChatSessionAdmin(admin.ModelAdmin):
    list_display = ("title", "project", "owner", "archived", "last_message_at")
    list_filter = ("archived", "project")
    search_fields = ("title",)
    readonly_fields = ("id", "created_at", "updated_at")


@admin.register(InsightTurn)
class InsightTurnAdmin(admin.ModelAdmin):
    """Read-only, and prunes on the schedule the model defines.

    Editing a stored answer would destroy the only reason to keep one: being
    able to see what was actually said.
    """

    list_display = (
        "created_at", "session", "question", "model_name", "latency_ms", "rating", "error",
    )
    list_filter = ("model_name", "rating")
    search_fields = ("question", "note")
    # Everything except the feedback, which is the one field a person sets by
    # hand rather than a record of what happened.
    readonly_fields = tuple(
        f.name for f in InsightTurn._meta.fields if f.name not in ("rating", "note")
    )
    actions = ("prune_now",)

    def has_add_permission(self, request):
        return False

    @admin.action(description="Delete turns past the retention window")
    def prune_now(self, request, queryset):
        self.message_user(request, f"Deleted {InsightTurn.prune()} expired turn(s).")
