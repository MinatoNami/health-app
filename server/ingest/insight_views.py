"""Analysis and insight endpoints.

Split into two groups on purpose, and the split is visible in the URLs:

* `/v1/analysis/*` is deterministic. Same inputs, same output, no model
  involved, no network call off this machine. These are the numbers.
* `/v1/insights/*` asks a language model to explain those numbers. Slower,
  non-deterministic, and clearly labelled as such in the UI.

Anything that reads health data requires authentication, and the analysis
endpoints are throttled like the rest of the dashboard. `/v1/insights/ask` gets
its own, much tighter limit: a single question occupies a local GPU for tens of
seconds, so an unbounded retry loop is a denial of service against yourself.
"""

import logging
from datetime import date

from django.core.cache import cache
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

from . import health_analysis
from .analytics_views import AUTH, AnalyticsThrottle, _FixedScopeThrottle
from .llm import client as llm_client
from .llm import service as llm_service
from .llm import tools as llm_tools
from .models import Goal, InsightTurn

log = logging.getLogger(__name__)


class InsightThrottle(_FixedScopeThrottle):
    """Generation is expensive and serial on a single local GPU. This is a
    queue-depth limit dressed as a rate limit."""

    scope = "insight"


def _tz(request) -> str | None:
    return request.query_params.get("tz") or None


def _as_of(request) -> date | None:
    raw = request.query_params.get("as_of")
    if not raw:
        return None
    try:
        return date.fromisoformat(raw)
    except ValueError:
        return None


def _owner(request):
    """The person behind the request, session or token.

    A bearer token authenticates a *device*, not a person, so `request.user` is
    a `TokenUser` with no primary key. But a token obtained by signing in
    records who signed in — and using that is what stops a question asked on the
    phone from being invisible in the dashboard's own history.
    """
    user = getattr(request, "user", None)
    if getattr(user, "pk", None):
        return user
    token = getattr(request, "auth", None)
    return getattr(token, "owner", None)


# --------------------------------------------------------------------------
# Deterministic analysis
# --------------------------------------------------------------------------

SNAPSHOT_CACHE_SECONDS = 120


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def snapshot(request):
    """The structured health snapshot. No model involved."""
    tz_name = _tz(request)
    as_of = _as_of(request)
    key = f"ingest:snapshot:v1:{as_of or 'auto'}:{tz_name or 'default'}"
    if request.query_params.get("fresh") != "1":
        cached = cache.get(key)
        if cached is not None:
            return Response({**cached, "cached": True})

    payload = health_analysis.snapshot(as_of=as_of, tz_name=tz_name)
    cache.set(key, payload, SNAPSHOT_CACHE_SECONDS)
    return Response({**payload, "cached": False})


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def trend(request):
    metric = request.query_params.get("metric", "").strip()
    try:
        days = min(365, max(7, int(request.query_params.get("days") or 90)))
    except ValueError:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)
    try:
        payload = health_analysis.trend(metric, days=days, as_of=_as_of(request), tz_name=_tz(request))
        payload["baseline"] = health_analysis.compare_to_baseline(
            metric, as_of=_as_of(request), tz_name=_tz(request)
        )
        payload["quality"] = health_analysis.data_quality(
            metric, as_of=_as_of(request), tz_name=_tz(request)
        )
    except health_analysis.UnknownMetric as exc:
        return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
    return Response(payload)


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def quality(request):
    """Data-quality report for every analysable metric that has data."""
    tz_name = _tz(request)
    as_of = _as_of(request)
    return Response(
        {
            "as_of": (as_of or health_analysis.last_complete_day(tz_name)).isoformat(),
            "metrics": [
                health_analysis.data_quality(slug, as_of=as_of, tz_name=tz_name)
                for slug in health_analysis.available_metrics()
            ],
        }
    )


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def sleep(request):
    try:
        days = min(90, max(3, int(request.query_params.get("days") or 14)))
    except ValueError:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)
    return Response(
        health_analysis.sleep_summary(days=days, as_of=_as_of(request), tz_name=_tz(request))
    )


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def anomalies(request):
    return Response({"anomalies": health_analysis.anomalies(as_of=_as_of(request), tz_name=_tz(request))})


# --------------------------------------------------------------------------
# Goals
# --------------------------------------------------------------------------


def _goal_payload(goal: Goal, tz_name: str | None) -> dict:
    spec = health_analysis.METRICS.get(goal.metric_slug)
    payload = {
        "id": goal.pk,
        "metric_slug": goal.metric_slug,
        "label": goal.label or (spec.label if spec else goal.metric_slug),
        "target_value": goal.target_value,
        "unit": goal.unit or (spec.unit if spec else ""),
        "cadence": goal.cadence,
        "note": goal.note,
        "active": goal.active,
    }
    if spec:
        payload["progress"] = llm_tools.goal_progress(goal, tz_name=tz_name)
    return payload


@api_view(["GET", "POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def goals(request):
    tz_name = _tz(request)
    if request.method == "GET":
        return Response(
            {
                "goals": [
                    _goal_payload(goal, tz_name) for goal in Goal.objects.filter(active=True)
                ],
                "analysable_metrics": [
                    {
                        "metric_slug": slug,
                        "label": health_analysis.METRICS[slug].label,
                        "unit": health_analysis.METRICS[slug].unit,
                        "daily_aggregation": health_analysis.METRICS[slug].daily,
                    }
                    for slug in health_analysis.available_metrics()
                ],
            }
        )

    metric = (request.data.get("metric_slug") or "").strip()
    if metric not in health_analysis.METRICS:
        return Response(
            {"detail": f"unknown metric {metric!r}"}, status=status.HTTP_400_BAD_REQUEST
        )
    try:
        target = float(request.data.get("target_value"))
    except (TypeError, ValueError):
        return Response(
            {"detail": "target_value must be a number"}, status=status.HTTP_400_BAD_REQUEST
        )
    if target <= 0:
        return Response(
            {"detail": "target_value must be greater than zero"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    cadence = request.data.get("cadence") or Goal.Cadence.DAILY
    if cadence not in Goal.Cadence.values:
        return Response({"detail": "cadence must be daily or weekly"}, status=status.HTTP_400_BAD_REQUEST)

    goal, _ = Goal.objects.update_or_create(
        metric_slug=metric,
        cadence=cadence,
        defaults={
            "target_value": target,
            "unit": health_analysis.METRICS[metric].unit,
            "note": str(request.data.get("note") or "")[:500],
            "label": str(request.data.get("label") or "")[:128],
            "active": True,
            "owner": _owner(request),
        },
    )
    return Response(_goal_payload(goal, tz_name), status=status.HTTP_200_OK)


@api_view(["DELETE"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def goal_detail(request, goal_id: int):
    deleted, _ = Goal.objects.filter(pk=goal_id).delete()
    if not deleted:
        return Response({"detail": "no such goal"}, status=status.HTTP_404_NOT_FOUND)
    return Response({"status": "deleted"})


# --------------------------------------------------------------------------
# LLM-backed insights
# --------------------------------------------------------------------------


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def llm_status(request):
    """Where health summaries are processed, and whether that is working.

    Surfaced rather than buried in configuration: §8 requires the user be told
    which provider receives their data, and "local" versus "somewhere else" is
    the single most important thing this screen can say.
    """
    info = llm_client.status()
    info["retention_days"] = InsightTurn.retention_days()
    return Response(info)


MAX_QUESTION_CHARS = 1000


@api_view(["POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([InsightThrottle])
def ask(request):
    """Ask a question about your own health data."""
    question = str(request.data.get("question") or "").strip()
    if not question:
        return Response({"detail": "question is required"}, status=status.HTTP_400_BAD_REQUEST)
    if len(question) > MAX_QUESTION_CHARS:
        return Response(
            {"detail": f"question is longer than {MAX_QUESTION_CHARS} characters"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    payload = llm_service.answer(
        question,
        context=str(request.data.get("context") or "")[:1000],
        tz_name=_tz(request) or request.data.get("tz"),
        owner=_owner(request),
        persist=request.data.get("remember") is not False,
        follow_up=bool(request.data.get("follow_up")),
    )
    return Response(payload)


@api_view(["POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([InsightThrottle])
def weekly_review(request):
    return Response(
        llm_service.weekly_review(
            tz_name=_tz(request) or request.data.get("tz"), owner=_owner(request)
        )
    )


@api_view(["GET", "DELETE"])
@authentication_classes([SessionAuthentication])
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def insight_history(request):
    """Stored questions and answers, and a way to delete all of them.

    Session-only: this is a person's question history, and the phone's device
    token authenticates a device rather than a person.
    """
    if request.method == "DELETE":
        return Response({"deleted": llm_service.forget(_owner(request))})
    return Response(
        {
            "turns": llm_service.history(_owner(request)),
            "retention_days": InsightTurn.retention_days(),
        }
    )
