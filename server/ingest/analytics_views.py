"""Dashboard endpoints.

Authenticated by session *or* bearer token: the dashboard is a browser SPA, so
it logs in with Django's session and downloads CSVs through plain links, while
the same endpoints stay usable from a script with a token.
"""

import csv
import logging

from django.core.cache import cache
from django.http import StreamingHttpResponse
from rest_framework import status
from rest_framework.authentication import SessionAuthentication
from rest_framework.decorators import (
    api_view,
    authentication_classes,
    permission_classes,
    throttle_classes,
)
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import SimpleRateThrottle

from . import analytics
from .auth import BearerTokenAuthentication
from .models import Record

log = logging.getLogger(__name__)

AUTH = [SessionAuthentication, BearerTokenAuthentication]

# Metrics the default view leads with, in the order they appear. Chosen because
# they are the ones with a daily rhythm worth watching; everything else is
# reachable through the explorer.
HEADLINE_METRICS = [
    "step_count",
    "active_energy_burned",
    "heart_rate",
    "resting_heart_rate",
    "sleep_analysis",
    "body_mass",
]

MAX_EXPORT_ROWS = 2_000_000


class _FixedScopeThrottle(SimpleRateThrottle):
    """SimpleRateThrottle, not ScopedRateThrottle.

    ScopedRateThrottle reads `throttle_scope` off the *view*, not `scope` off
    the throttle class, and silently allows the request when it finds neither —
    so a scope set here would have made the limit a no-op that looks configured.
    Keyed on client IP, which NUM_PROXIES makes trustworthy.
    """

    def get_cache_key(self, request, view):
        return self.cache_format % {"scope": self.scope, "ident": self.get_ident(request)}


class AnalyticsThrottle(_FixedScopeThrottle):
    scope = "analytics"


class ExportThrottle(_FixedScopeThrottle):
    """Export is the one endpoint where a stuck retry loop is genuinely
    expensive — each call can stream hundreds of megabytes and hold a worker
    for a minute."""

    scope = "export"


def _range_or_error(request, default_days=30):
    """Returns (parsed, error_response). A bad date is the caller's mistake and
    should say so, rather than quietly answering for a different range."""
    try:
        return analytics.parse_range(
            request.query_params.get("from"),
            request.query_params.get("to"),
            default_days=default_days,
        ), None
    except analytics.InvalidRange as exc:
        return None, Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def metrics(request):
    return Response({"metrics": analytics.metric_catalog()})


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def series(request):
    metric = request.query_params.get("metric", "").strip()
    if not metric:
        return Response({"detail": "metric is required"}, status=status.HTTP_400_BAD_REQUEST)

    parsed, error = _range_or_error(request)
    if error:
        return error
    start, end, start_date, end_date = parsed
    agg = request.query_params.get("agg", "").strip().lower()
    if agg not in analytics.CUMULATIVE_AGGS | analytics.DISCRETE_AGGS:
        catalog = {m["metric_slug"]: m for m in analytics.metric_catalog()}
        agg = catalog.get(metric, {}).get("default_agg", "avg")

    payload = analytics.daily_series(
        metric, start, end, agg, tz_name=request.query_params.get("tz")
    )
    payload["from"] = start_date.isoformat()
    payload["to"] = end_date.isoformat()
    return Response(payload)


OVERVIEW_CACHE_SECONDS = 60


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def overview(request):
    parsed, error = _range_or_error(request)
    if error:
        return error
    start, end, start_date, end_date = parsed
    tz_name = request.query_params.get("tz")

    # Cached per range: a two-year overview runs seven aggregates over the whole
    # table and measured ~1.6s, and flipping between range presets re-requests
    # it constantly. Short enough that new uploads still show up promptly.
    cache_key = f"ingest:overview:v1:{start_date}:{end_date}:{tz_name or 'default'}"
    cached = cache.get(cache_key)
    if cached is not None and request.query_params.get("fresh") != "1":
        return Response({**cached, "cached": True})

    catalog = {m["metric_slug"]: m for m in analytics.metric_catalog()}

    charts = []
    for metric in HEADLINE_METRICS:
        meta = catalog.get(metric)
        if not meta:
            continue  # metric not enabled on this phone — skip rather than show an empty card

        if metric == "sleep_analysis":
            payload = analytics.sleep_hours(start, end, tz_name)
            payload["unit"] = "h"
            payload["cumulative"] = True
        else:
            payload = analytics.daily_series(
                metric, start, end, meta["default_agg"], tz_name=tz_name
            )
            payload["unit"] = meta["unit"]
            payload["cumulative"] = meta["cumulative"]
        charts.append(payload)

    # "Latest" means different things by metric, and conflating them produces
    # nonsense: the most recent *sample* of a cumulative metric is one tiny
    # increment ("latest steps: 18"), not a meaningful reading. So cumulative
    # metrics report the most recent completed day, and only instantaneous ones
    # report an actual last reading.
    discrete = [c["metric_slug"] for c in charts if not c["cumulative"]]
    latest = {}
    for slug, reading in analytics.latest_values(discrete).items():
        latest[slug] = {**reading, "basis": "reading"}
    for chart in charts:
        if chart["cumulative"] and chart["points"]:
            last = chart["points"][-1]
            latest[chart["metric_slug"]] = {
                "value": last["value"],
                "unit": chart.get("unit", ""),
                "at": last["date"],
                "basis": "day",
            }

    payload = {
        "from": start_date.isoformat(),
        "to": end_date.isoformat(),
        "summary": analytics.summary(start, end, tz_name),
        "latest": latest,
        "charts": charts,
        "available_metrics": len(catalog),
    }
    cache.set(cache_key, payload, OVERVIEW_CACHE_SECONDS)
    return Response({**payload, "cached": False})


class _Echo:
    """csv.writer needs a file-like object; this just hands the line back so
    rows can be streamed instead of assembled in memory."""

    def write(self, value):
        return value


EXPORT_COLUMNS = [
    "id",
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
    "source_product_type",
    "recorded_at",
    "deleted_at",
]


def _export_rows(queryset):
    writer = csv.writer(_Echo())
    yield writer.writerow(EXPORT_COLUMNS)
    # iterator() keeps Postgres streaming rather than materialising a million
    # rows in the process before the first byte reaches the client.
    for row in queryset.values_list(*EXPORT_COLUMNS).iterator(chunk_size=2_000):
        yield writer.writerow(
            [v.isoformat() if hasattr(v, "isoformat") else v for v in row]
        )


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([ExportThrottle])
def export_csv(request):
    """Streams matching records as CSV.

    Streamed, not buffered: this table holds millions of rows and an export of
    "everything" must not have to fit in memory first.
    """
    parsed, error = _range_or_error(request, default_days=3650)
    if error:
        return error
    start, end, start_date, end_date = parsed

    queryset = Record.objects.filter(start__gte=start, start__lt=end)

    raw_metrics = request.query_params.get("metrics", "").strip()
    if raw_metrics:
        wanted = [m.strip() for m in raw_metrics.split(",") if m.strip()]
        queryset = queryset.filter(metric_slug__in=wanted)

    kind = request.query_params.get("kind", "").strip()
    if kind:
        queryset = queryset.filter(kind=kind)

    if request.query_params.get("include_deleted") != "1":
        queryset = queryset.filter(deleted_at__isnull=True)

    queryset = queryset.order_by("metric_slug", "start")[:MAX_EXPORT_ROWS]

    label = raw_metrics.replace(",", "-")[:60] or "all-metrics"
    filename = f"health-{label}-{start_date}-to-{end_date}.csv"

    response = StreamingHttpResponse(_export_rows(queryset), content_type="text/csv")
    response["Content-Disposition"] = f'attachment; filename="{filename}"'
    # Without this, nginx buffers the whole stream before sending anything and
    # a large export looks like a hang.
    response["X-Accel-Buffering"] = "no"
    log.info("CSV export: %s %s..%s", label, start_date, end_date)
    return response


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([ExportThrottle])
def export_summary(request):
    """Row count and rough size for a prospective export, so the UI can warn
    before someone downloads a million rows."""
    parsed, error = _range_or_error(request, default_days=3650)
    if error:
        return error
    start, end, _, _ = parsed
    queryset = Record.objects.filter(start__gte=start, start__lt=end, deleted_at__isnull=True)
    raw_metrics = request.query_params.get("metrics", "").strip()
    if raw_metrics:
        queryset = queryset.filter(
            metric_slug__in=[m.strip() for m in raw_metrics.split(",") if m.strip()]
        )
    count = queryset.count()
    return Response(
        {
            "rows": count,
            "capped": count > MAX_EXPORT_ROWS,
            "max_rows": MAX_EXPORT_ROWS,
            "estimated_bytes": count * 180,
        }
    )
