import gzip
import io
import logging
import zlib

from django.contrib.auth import authenticate
from django.core.cache import cache
from django.db import DatabaseError
from django.db.models import Count, Max
from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.parsers import JSONParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from . import analytics
from .auth import BearerTokenAuthentication
from .models import ApiToken, Batch, Device, Record
from .ndjson import PayloadTooLarge
from .parsers import (
    NDJSONAltParser,
    NDJSONStreamParser,
    OctetStreamParser,
    PlainTextStreamParser,
)
from .service import BatchRejected, claim_batch, ingest

log = logging.getLogger(__name__)

SCHEMA_VERSION = 1


class BatchIngestView(APIView):
    """POST /v1/health/batches

    Status codes matter here more than usual, because the client acts on them:
    5xx/429/408 are retried with backoff, and every other 4xx parks the batch
    permanently. Anything ambiguous must therefore be reported as retryable —
    parking a batch that would have succeeded is silent data loss.
    """

    authentication_classes = [BearerTokenAuthentication]
    permission_classes = [IsAuthenticated]
    parser_classes = [
        NDJSONStreamParser,
        NDJSONAltParser,
        OctetStreamParser,
        PlainTextStreamParser,
    ]

    def post(self, request):
        idempotency_key = request.headers.get("Idempotency-Key", "").strip()
        if not idempotency_key:
            return Response(
                {"detail": "Idempotency-Key header is required"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if len(idempotency_key) > 255:
            return Response(
                {"detail": "Idempotency-Key exceeds 255 characters"},
                status=status.HTTP_400_BAD_REQUEST,
            )

        client_schema = request.headers.get("X-Schema-Version")
        if client_schema and client_schema.isdigit() and int(client_schema) > SCHEMA_VERSION:
            # Refusing is safer than silently dropping fields this build has
            # never seen. Permanent by design: a newer client needs a newer
            # server, and retrying will not change that.
            return Response(
                {
                    "detail": f"Unsupported schema version {client_schema}; "
                    f"this server speaks {SCHEMA_VERSION}"
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            byte_count = int(request.headers.get("Content-Length") or 0)
        except ValueError:
            byte_count = 0

        try:
            batch, is_new = claim_batch(idempotency_key, byte_count=byte_count)
        except DatabaseError:
            log.exception("Failed to claim batch %s", idempotency_key)
            return Response(
                {"detail": "Could not reserve batch; retry"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        if not is_new:
            if batch.status == Batch.Status.STORED:
                # The normal case after a network blip. Replay the original
                # answer so a retry is indistinguishable from the first call.
                body = dict(batch.response or {})
                body["duplicate"] = True
                log.info("Duplicate batch %s replayed", idempotency_key)
                return Response(body, status=status.HTTP_200_OK)
            # Still in flight elsewhere. Reporting 409 here would tell the
            # client it is safely stored when that is not yet known, so this
            # has to be retryable instead.
            return Response(
                {"detail": "Batch is already being processed; retry shortly"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
                headers={"Retry-After": "10"},
            )

        # NDJSONStreamParser hands back the raw stream, but DRF skips parsing
        # entirely for a zero-length body and yields an empty QueryDict. Coerce
        # that back to an empty stream so the "no header" path reports it.
        stream = request.data
        if not hasattr(stream, "read"):
            stream = io.BytesIO(b"")

        # nginx does not decompress request bodies, so this is the only place it
        # can happen. The current client uploads uncompressed, but the wire
        # format in docs/ARCHITECTURE.md allows gzip and NDJSON compresses about
        # tenfold — worth honouring before the phone starts doing it.
        if "gzip" in request.headers.get("Content-Encoding", "").lower():
            stream = gzip.GzipFile(fileobj=stream, mode="rb")

        try:
            result = ingest(stream, batch)
        except (gzip.BadGzipFile, zlib.error, EOFError) as exc:
            batch.mark_failed(f"corrupt gzip body: {exc}")
            return Response(
                {"detail": f"Body is not valid gzip: {exc}"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        except BatchRejected as exc:
            batch.mark_failed(str(exc))
            log.warning("Rejected batch %s: %s", idempotency_key, exc)
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        except PayloadTooLarge as exc:
            batch.mark_failed(str(exc))
            return Response(
                {"detail": str(exc)},
                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            )
        except Exception as exc:  # noqa: BLE001 - unknown failures must be retryable
            log.exception("Batch %s failed", idempotency_key)
            batch.mark_failed(f"{type(exc).__name__}: {exc}")
            return Response(
                {"detail": "Internal error storing batch; retry"},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )

        body = result.as_response(batch)
        batch.mark_stored(body)

        if result.skipped:
            log.warning(
                "Batch %s stored with %d skipped record(s): %s",
                idempotency_key,
                result.skipped,
                "; ".join(result.skip_samples),
            )
        if batch.declared_record_count and batch.declared_record_count != result.records_received:
            # Not fatal — the header count is the client's view of what it
            # wrote — but a persistent mismatch means truncated uploads.
            log.warning(
                "Batch %s declared %d records, received %d",
                idempotency_key,
                batch.declared_record_count,
                result.records_received,
            )
            body["declared_record_count"] = batch.declared_record_count

        log.info(
            "Batch %s stored: %d written, %d deletes, %d skipped",
            idempotency_key,
            result.records_written,
            result.deletes_applied + result.tombstones_created,
            result.skipped,
        )
        return Response(body, status=status.HTTP_200_OK)


class LoginView(APIView):
    """POST /v1/auth/login  {"username", "password", "device_label"?}

    Trades a username and password for a bearer token, so the phone never has
    to have one pasted into it. A fresh token is minted per sign-in rather than
    returning an existing one: only the digest is stored, so there is nothing to
    return, and per-device tokens can be revoked individually.

    Throttled, because unlike every other endpoint here this one accepts a
    password and is therefore worth guessing at.
    """

    authentication_classes = []
    permission_classes = [AllowAny]
    parser_classes = [JSONParser]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "login"

    def post(self, request):
        username = (request.data.get("username") or "").strip()
        password = request.data.get("password") or ""
        if not username or not password:
            return Response(
                {"detail": "username and password are required"},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = authenticate(request, username=username, password=password)
        if user is None or not user.is_active:
            # Deliberately identical for "no such user" and "wrong password" —
            # distinguishing them turns this into a username oracle.
            log.warning("Failed login for %r", username[:64])
            return Response(
                {"detail": "Invalid username or password"},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        label = (request.data.get("device_label") or "").strip()[:128] or f"{username}-device"
        token, raw = ApiToken.issue(label=label, owner=user)
        log.info("Issued token '%s' to %s via login", label, username)

        return Response(
            {
                "token": raw,
                "label": token.label,
                "username": user.get_username(),
                "created_at": token.created_at.isoformat(),
            },
            status=status.HTTP_200_OK,
        )


@api_view(["POST"])
@authentication_classes([BearerTokenAuthentication])
@permission_classes([IsAuthenticated])
def logout(request):
    """Revokes the token that authenticated this request.

    Sign-out has to happen server-side too: deleting the copy on the phone
    leaves a credential that still works for anyone holding it.
    """
    token = request.auth
    if token.revoked_at is None:
        token.revoked_at = timezone.now()
        token.save(update_fields=["revoked_at"])
        log.info("Revoked token '%s' on sign-out", token.label)
    return Response({"status": "revoked", "label": token.label})


@api_view(["GET"])
@authentication_classes([BearerTokenAuthentication])
@permission_classes([IsAuthenticated])
def ping(request):
    """Cheap authenticated probe, for the app's Test Connection button.

    Deliberately runs no aggregate queries: it answers "is the URL right, is
    TLS trusted, is this token valid" and nothing else.
    """
    return Response(
        {
            "status": "ok",
            "token": request.auth.label,
            "schema_version": SCHEMA_VERSION,
            "server_time": timezone.now().isoformat(),
        }
    )


STATS_CACHE_KEY = "ingest:stats:v2"
STATS_CACHE_SECONDS = 60

COVERAGE_CACHE_KEY = "ingest:coverage:v1"
COVERAGE_CACHE_SECONDS = 60


def _iso(value):
    return value.isoformat() if value else None


def _build_stats() -> dict:
    """Aggregates over the whole store.

    Every query here is a grouped aggregate rather than a per-object loop: with
    millions of rows, one query per device is the difference between a page that
    loads and one that times out.
    """
    devices = [
        {
            "device_id": row["device__device_id"],
            "label": row["device__label"],
            "app_version": row["device__last_app_version"],
            "last_seen_at": _iso(row["device__last_seen_at"]),
            "record_count": row["count"],
            "latest_sample_at": _iso(row["latest"]),
        }
        for row in Record.objects.filter(device__isnull=False)
        .values(
            "device__device_id",
            "device__label",
            "device__last_app_version",
            "device__last_seen_at",
        )
        .annotate(count=Count("id"), latest=Max("start"))
        .order_by("-count")
    ]

    metrics = [
        {
            "metric_slug": row["metric_slug"],
            "label": analytics.display_name(row["metric_slug"]),
            "count": row["count"],
            "latest_sample_at": _iso(row["latest"]),
            "unit": row["unit"],
        }
        for row in Record.objects.filter(deleted_at__isnull=True)
        .exclude(kind=Record.Kind.DELETE)
        .values("metric_slug")
        .annotate(count=Count("id"), latest=Max("start"), unit=Max("unit"))
        .order_by("-count")[:60]
    ]

    last_batch = (
        Batch.objects.filter(status=Batch.Status.STORED).order_by("-completed_at").first()
    )

    return {
        "records_total": Record.objects.count(),
        "records_deleted": Record.objects.filter(deleted_at__isnull=False).count(),
        "batches": {
            row["status"]: row["count"]
            for row in Batch.objects.values("status").annotate(count=Count("id"))
        },
        "last_batch_at": _iso(last_batch.completed_at) if last_batch else None,
        "last_batch_records": last_batch.stored_record_count if last_batch else 0,
        "devices": devices,
        "metrics": metrics,
        "generated_at": timezone.now().isoformat(),
    }


@api_view(["GET"])
@authentication_classes([BearerTokenAuthentication])
@permission_classes([IsAuthenticated])
def stats(request):
    """What the server actually holds — powers the app's Server tab.

    Cached briefly: the aggregates scan the whole table, and a pull-to-refresh
    that a user can repeat freely should not be able to load the database. Pass
    ?fresh=1 to bypass.
    """
    if request.query_params.get("fresh") == "1":
        payload = _build_stats()
        cache.set(STATS_CACHE_KEY, payload, STATS_CACHE_SECONDS)
        payload["cached"] = False
        return Response(payload)

    payload = cache.get(STATS_CACHE_KEY)
    cached = payload is not None
    if not cached:
        payload = _build_stats()
        cache.set(STATS_CACHE_KEY, payload, STATS_CACHE_SECONDS)

    return Response({**payload, "cached": cached})


def _build_coverage() -> dict:
    """Per-metric high-water marks for every metric, uncapped.

    Deliberately not served from `_build_stats`: that slices to the top 60
    metrics for display, and the client reconciles against this. With ~170
    metrics in the catalogue, "absent from the list" would otherwise mean
    "absent from the server" for every metric outside the top 60 — and the
    client's response to a missing metric is to rewind its anchor and re-read
    the entire history of that type.

    Tombstoned rows are excluded so a deleted sample cannot hold the high-water
    mark above what the server would actually serve back.
    """
    metrics = {
        row["metric_slug"]: {
            "count": row["count"],
            "latest_sample_at": _iso(row["latest_sample"]),
            "latest_recorded_at": _iso(row["latest_recorded"]),
        }
        for row in Record.objects.filter(deleted_at__isnull=True)
        .exclude(kind=Record.Kind.DELETE)
        .values("metric_slug")
        .annotate(
            count=Count("id"),
            latest_sample=Max("start"),
            latest_recorded=Max("recorded_at"),
        )
    }
    return {"metrics": metrics, "generated_at": timezone.now().isoformat()}


@api_view(["GET"])
@authentication_classes([BearerTokenAuthentication])
@permission_classes([IsAuthenticated])
def coverage(request):
    """GET /v1/health/coverage — what the server holds, per metric.

    The client compares this against its own anchors before a sync, so that a
    server that has silently lost data (a restore from an older backup, a
    dropped batch) gets it re-sent rather than the gap persisting forever.

    Cached like `stats` for the same reason: one grouped aggregate over the
    whole table. `?fresh=1` bypasses.
    """
    if request.query_params.get("fresh") == "1":
        payload = _build_coverage()
        cache.set(COVERAGE_CACHE_KEY, payload, COVERAGE_CACHE_SECONDS)
        return Response({**payload, "cached": False})

    payload = cache.get(COVERAGE_CACHE_KEY)
    cached = payload is not None
    if not cached:
        payload = _build_coverage()
        cache.set(COVERAGE_CACHE_KEY, payload, COVERAGE_CACHE_SECONDS)

    return Response({**payload, "cached": cached})


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def healthz(request):
    """Unauthenticated liveness probe for the deploy script and nginx.

    Touches the database so a green result means the whole path works, not
    just that gunicorn is accepting connections.
    """
    try:
        Batch.objects.exists()
    except DatabaseError:
        log.exception("Health check failed")
        return Response({"status": "degraded"}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
    return Response({"status": "ok", "schema_version": SCHEMA_VERSION})
