from django.contrib import admin
from django.utils import timezone

from .models import ApiToken, Batch, Device, Record


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
