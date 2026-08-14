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
from django.core.exceptions import ValidationError
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

from . import correlations, health_analysis, patterns
from .analytics_views import AUTH, AnalyticsThrottle, _FixedScopeThrottle
from .auth import owner_of as _owner
from .llm import client as llm_client
from .llm import service as llm_service
from .llm import tools as llm_tools
from .models import ChatSession, Goal, InsightTurn

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
def nutrition(request):
    """What was logged to eat and drink, and what that can support.

    Deterministic, like every other `/v1/analysis` endpoint: the day-counts, the
    averages over fully logged days, and the comparison against estimated energy
    burned are all computed here. No model is involved, and none of it is a
    recommendation about what to eat.
    """
    try:
        days = min(90, max(1, int(request.query_params.get("days") or 14)))
    except ValueError:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)
    return Response(
        health_analysis.nutrition_summary(days=days, as_of=_as_of(request), tz_name=_tz(request))
    )


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def anomalies(request):
    return Response({"anomalies": health_analysis.anomalies(as_of=_as_of(request), tz_name=_tz(request))})


def _window(request, default: int, maximum: int):
    try:
        return min(maximum, max(14, int(request.query_params.get("days") or default)))
    except ValueError:
        return None


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def correlation_report(request):
    """Which signals move together, with every pair that was tested.

    Deterministic. The pairs are a fixed list decided in advance, corrected for
    how many were asked, and reported as associations — this endpoint never
    claims one metric causes another.
    """
    days = _window(request, correlations.DEFAULT_DAYS, correlations.MAX_DAYS)
    if days is None:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)
    return Response(correlations.discover(days=days, as_of=_as_of(request), tz_name=_tz(request)))


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def pattern_report(request):
    """Weekly rhythms: weekends, and any weekday that stands out."""
    days = _window(request, patterns.DEFAULT_DAYS, patterns.MAX_DAYS)
    if days is None:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)
    return Response(patterns.discover(days=days, as_of=_as_of(request), tz_name=_tz(request)))


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
def daily(request):
    """A few words for the phone's morning notification.

    No model runs behind this. The alert has to be dependable at 08:00 whether
    or not a laptop somewhere is awake, and a deterministic sentence about
    measured numbers is a better morning brief than a generated one that
    sometimes does not arrive.
    """
    tz_name = _tz(request)
    key = f"ingest:daily-brief:v1:{_as_of(request) or 'auto'}:{tz_name or 'default'}"
    cached = cache.get(key)
    if cached is not None and request.query_params.get("fresh") != "1":
        return Response({**cached, "cached": True})

    payload = health_analysis.daily_brief(as_of=_as_of(request), tz_name=tz_name)
    cache.set(key, payload, SNAPSHOT_CACHE_SECONDS)
    return Response({**payload, "cached": False})


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
    # What a conversation has to fit into, and how much of it history may use
    # before older turns are folded into a summary. Reported here rather than
    # left to be inferred: "why did my chat just compact?" is otherwise
    # unanswerable from the UI.
    info["context_tokens"] = llm_service.context_tokens()
    info["history_turns"] = llm_service.session_turns()
    return Response(info)


MAX_QUESTION_CHARS = 1000


class UnknownSession(Exception):
    pass


def _session(request):
    """The conversation this question belongs to, if one was named.

    Resolved through the caller's own scope, so a session id that belongs to
    somebody else is indistinguishable from one that does not exist. Absent
    entirely is fine and stays the default: the phone asks one-off questions and
    should not have to invent a chat to do it.
    """
    raw = request.data.get("session_id")
    if not raw:
        return None
    session = llm_service.scoped(ChatSession.objects.all(), _owner(request)).filter(pk=raw).first()
    if session is None:
        raise UnknownSession
    return session


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
    try:
        session = _session(request)
    except (UnknownSession, ValidationError):
        return Response({"detail": "no such session"}, status=status.HTTP_404_NOT_FOUND)

    payload = llm_service.answer(
        question,
        context=str(request.data.get("context") or "")[:1000],
        tz_name=_tz(request) or request.data.get("tz"),
        owner=_owner(request),
        persist=request.data.get("remember") is not False,
        # A session carries its own history without being asked; `follow_up`
        # stays for callers that have no session, which is how the phone asks.
        follow_up=bool(request.data.get("follow_up")),
        session=session,
    )
    return Response(payload)


@api_view(["POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([InsightThrottle])
def weekly_review(request):
    try:
        session = _session(request)
    except (UnknownSession, ValidationError):
        return Response({"detail": "no such session"}, status=status.HTTP_404_NOT_FOUND)
    return Response(
        llm_service.weekly_review(
            tz_name=_tz(request) or request.data.get("tz"),
            owner=_owner(request),
            session=session,
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
