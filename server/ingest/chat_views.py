"""Chat sessions, projects, and the stored messages inside them.

`/v1/insights/ask` answers one question. These endpoints are what turn a run of
those into something you can leave and come back to: a conversation with a name,
optionally inside a project whose standing context every session in it inherits.

Three things are worth knowing before changing anything here.

**Sessions are the context boundary.** A question asked inside a session replays
that session's earlier turns and nothing else. This is not a UI nicety — an
owner's global last-N turns replayed into a named chat would carry last week's
sleep question into a conversation about food and let the model answer as though
it had been asked.

**Retention still applies.** Messages are deleted after
`INSIGHT_RETENTION_DAYS`, and `InsightTurn.prune` takes the emptied sessions with
them. A chat history feature does not get to quietly become indefinite storage
of health questions; `GET /v1/chat/messages` reports the window in its own
response so anything reading it knows what it can and cannot see.

**`/v1/chat/messages` is the export surface.** Flat, filterable and paginated
across every session, returning the whole turn — question, structured answer,
safety verdict, which tools ran, which model, how long it took, and what failed.
That is the raw material for judging whether answers are any good, which is why
it returns the machinery rather than just the prose, and why it accepts a bearer
token: a feedback loop that has to drive a browser to read its own data is not
one anybody keeps running.

Bearer access is a deliberate widening of `/v1/insights/history`, which is
session-only. It is defensible because a token scopes exactly as `_owned_by`
already does, and because a CLI-minted token can already stream the entire
health record through `/v1/export/records.csv` — the questions somebody asked
about that record are not the more sensitive half. A token obtained by signing
in carries an owner and is scoped to that person like any session.
"""

import json
import logging
import re
from datetime import timedelta

from django.core.exceptions import ValidationError
from django.db.models import Count, Q
from django.http import HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework import status
from rest_framework.decorators import (
    api_view,
    authentication_classes,
    permission_classes,
    throttle_classes,
)
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from .analytics_views import AUTH, AnalyticsThrottle
from .auth import owner_of as _owner
from .insight_views import InsightThrottle
from .llm import prompts
from .llm import service as llm_service
from .models import ChatProject, ChatSession, InsightTurn

log = logging.getLogger(__name__)

MAX_PROJECT_NAME = 120
MAX_SESSION_TITLE = 200
MAX_INSTRUCTIONS = 2000

DEFAULT_SESSION_PAGE = 50
MAX_SESSION_PAGE = 200
DEFAULT_MESSAGE_PAGE = 100
MAX_MESSAGE_PAGE = 500


# --------------------------------------------------------------------------
# Scoping
# --------------------------------------------------------------------------


def _sessions(request):
    return llm_service.scoped(ChatSession.objects.all(), _owner(request))


def _projects(request):
    return llm_service.scoped(ChatProject.objects.all(), _owner(request))


def _turns(request):
    return llm_service.scoped(InsightTurn.objects.all(), _owner(request))


def _paging(request, default: int, maximum: int) -> tuple[int, int] | None:
    """(limit, offset), or None if either was not a number.

    Returned rather than raised so the caller answers 400 with its own wording;
    a page size that silently falls back to the default is how an export loop
    quietly misses rows.
    """
    try:
        limit = min(maximum, max(1, int(request.query_params.get("limit") or default)))
        offset = max(0, int(request.query_params.get("offset") or 0))
    except ValueError:
        return None
    return limit, offset


def _flag(request, name: str) -> bool | None:
    """Tri-state query flag: true, false, or "don't filter on this"."""
    raw = request.query_params.get(name)
    if raw is None or raw == "":
        return None
    return raw.lower() in ("1", "true", "yes")


def _moment(raw: str):
    """An ISO timestamp, tolerating the `+` a URL ate.

    The round trip this endpoint exists for is: read `created_at` off a message,
    pass it back as `since` next time. Do that without percent-encoding and the
    `+` of `+00:00` arrives as a space, so a caller gets a 400 for handing back
    a timestamp this API gave them. There is no valid ISO 8601 datetime with a
    space in that position, so restoring it is unambiguous rather than lenient.
    """
    moment = parse_datetime(raw)
    if moment is None and " " in raw:
        head, _, tail = raw.rpartition(" ")
        moment = parse_datetime(f"{head}+{tail}")
    return moment


# --------------------------------------------------------------------------
# Projects
# --------------------------------------------------------------------------


@api_view(["GET", "POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def projects(request):
    if request.method == "GET":
        archived = _flag(request, "archived")
        queryset = _projects(request).annotate(session_count=Count("sessions"))
        if archived is not None:
            queryset = queryset.filter(archived=archived)
        return Response(
            {"projects": [p.as_dict(session_count=p.session_count) for p in queryset]}
        )

    name = str(request.data.get("name") or "").strip()
    if not name:
        return Response({"detail": "name is required"}, status=status.HTTP_400_BAD_REQUEST)

    project = ChatProject.objects.create(
        name=name[:MAX_PROJECT_NAME],
        instructions=str(request.data.get("instructions") or "")[:MAX_INSTRUCTIONS],
        owner=_owner(request),
    )
    return Response(project.as_dict(session_count=0), status=status.HTTP_201_CREATED)


@api_view(["GET", "PATCH", "DELETE"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def project_detail(request, project_id: int):
    project = get_object_or_404(_projects(request), pk=project_id)

    if request.method == "DELETE":
        # The sessions survive and fall back to no project — `on_delete` is
        # SET_NULL. Deleting a folder should not silently destroy months of
        # conversations that happened to be filed in it; the chats stay
        # reachable and can be deleted one at a time on purpose.
        moved = project.sessions.count()
        project.delete()
        return Response({"status": "deleted", "sessions_unfiled": moved})

    if request.method == "PATCH":
        fields = []
        if "name" in request.data:
            name = str(request.data.get("name") or "").strip()
            if not name:
                return Response(
                    {"detail": "name cannot be empty"}, status=status.HTTP_400_BAD_REQUEST
                )
            project.name = name[:MAX_PROJECT_NAME]
            fields.append("name")
        if "instructions" in request.data:
            project.instructions = str(request.data.get("instructions") or "")[
                :MAX_INSTRUCTIONS
            ]
            fields.append("instructions")
        if "archived" in request.data:
            project.archived = bool(request.data.get("archived"))
            fields.append("archived")
        if fields:
            project.save(update_fields=[*fields, "updated_at"])

    return Response(project.as_dict(session_count=project.sessions.count()))


# --------------------------------------------------------------------------
# Sessions
# --------------------------------------------------------------------------


def _preview(session) -> str:
    """The first question in the chat, for the sidebar's second line.

    The *first* rather than the most recent: a title is already the opening
    question truncated, and a preview showing the latest question would leave
    the two lines saying nearly the same thing on a two-message chat.
    """
    turn = session.turns.order_by("created_at").first()
    return (turn.question if turn else "") or ""


def _session_list_payload(sessions: list) -> list[dict]:
    """Counts and previews for a page of chats, in one extra query.

    Not `annotate(Count("turns"))`, for two reasons. It is a query per chat once
    a preview is wanted alongside it, and the sidebar reloads after every
    question asked. And when the list is filtered by `q`, the search already
    joined `turns` — Django reuses that join, so the annotation would count only
    the turns that *matched the search* and report a five-message chat as having
    one. Walking the page's turns once sidesteps both.
    """
    counts: dict = {}
    previews: dict = {}
    rows = (
        InsightTurn.objects.filter(session__in=sessions)
        .order_by("session_id", "created_at")
        .values_list("session_id", "question")
    )
    for session_id, question in rows:
        counts[session_id] = counts.get(session_id, 0) + 1
        previews.setdefault(session_id, question or "")

    return [
        session.as_dict(
            message_count=counts.get(session.pk, 0),
            preview=previews.get(session.pk, ""),
        )
        for session in sessions
    ]


@api_view(["GET", "POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def sessions(request):
    if request.method == "POST":
        project = None
        if request.data.get("project_id") is not None:
            project = get_object_or_404(_projects(request), pk=request.data["project_id"])
        title = str(request.data.get("title") or "").strip()[:MAX_SESSION_TITLE]
        session = ChatSession.objects.create(
            owner=_owner(request),
            project=project,
            title=title,
            # A title given at creation is a name somebody chose, so the first
            # question must not overwrite it.
            title_locked=bool(title),
        )
        return Response(
            session.as_dict(message_count=0, preview=""), status=status.HTTP_201_CREATED
        )

    page = _paging(request, DEFAULT_SESSION_PAGE, MAX_SESSION_PAGE)
    if page is None:
        return Response(
            {"detail": "limit and offset must be numbers"}, status=status.HTTP_400_BAD_REQUEST
        )
    limit, offset = page

    queryset = _sessions(request).select_related("project")

    archived = _flag(request, "archived")
    if archived is not None:
        queryset = queryset.filter(archived=archived)

    project_id = request.query_params.get("project")
    if project_id == "none":
        queryset = queryset.filter(project__isnull=True)
    elif project_id:
        try:
            queryset = queryset.filter(project_id=int(project_id))
        except ValueError:
            return Response(
                {"detail": "project must be an id or 'none'"},
                status=status.HTTP_400_BAD_REQUEST,
            )

    # Search covers the questions inside a chat as well as its title, because
    # the title is only ever the first question — searching titles alone would
    # miss everything anybody asked after the opening line. distinct() because
    # the join multiplies a session by its matching turns.
    search = (request.query_params.get("q") or "").strip()
    if search:
        queryset = queryset.filter(
            Q(title__icontains=search) | Q(turns__question__icontains=search)
        ).distinct()

    total = queryset.count()
    return Response(
        {
            "sessions": _session_list_payload(list(queryset[offset : offset + limit])),
            "total": total,
            "limit": limit,
            "offset": offset,
        }
    )


@api_view(["GET", "PATCH", "DELETE"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def session_detail(request, session_id):
    session = get_object_or_404(_sessions(request), pk=session_id)

    if request.method == "DELETE":
        # Cascades to the turns. This is the "delete this conversation" the
        # sidebar offers, and it has to actually delete the messages — a chat
        # that disappears from the list while its questions stay in the database
        # is the kind of deletion that is worse than none.
        deleted = session.turns.count()
        session.delete()
        return Response({"status": "deleted", "messages_deleted": deleted})

    if request.method == "PATCH":
        fields = []
        if "title" in request.data:
            title = str(request.data.get("title") or "").strip()[:MAX_SESSION_TITLE]
            session.title = title
            # Clearing the title hands naming back to the next question.
            session.title_locked = bool(title)
            fields += ["title", "title_locked"]
        if "project_id" in request.data:
            raw = request.data.get("project_id")
            session.project = (
                None if raw in (None, "", "none")
                else get_object_or_404(_projects(request), pk=raw)
            )
            fields.append("project")
        if "archived" in request.data:
            session.archived = bool(request.data.get("archived"))
            fields.append("archived")
        if fields:
            session.save(update_fields=[*fields, "updated_at"])

    turns = list(session.turns.order_by("created_at"))
    # The last turn's prompt_tokens is what the model server actually counted,
    # so the UI reports measured usage rather than the estimate the compaction
    # threshold runs on. Zero until a model has answered in here at least once.
    used = next((t.prompt_tokens for t in reversed(turns) if t.prompt_tokens), 0)
    return Response(
        {
            **session.as_dict(message_count=len(turns), preview=_preview(session)),
            "project": session.project.as_dict() if session.project else None,
            "messages": [turn.as_dict() for turn in turns],
            "retention_days": InsightTurn.retention_days(),
            "context": {
                "limit_tokens": llm_service.context_tokens(),
                "last_prompt_tokens": used,
                "pending_turns": session.pending_turns().count(),
            },
        }
    )


@api_view(["POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([InsightThrottle])
def session_compact(request, session_id):
    """Fold this conversation's older turns into a written summary, now.

    Throttled with the generation limit rather than the analytics one: this runs
    the model, and on a local GPU that is the scarce resource the insight
    throttle exists to protect.

    Returns 200 whether or not anything was compacted, with `compacted` and a
    `reason`. A short chat and an unreachable model server are both ordinary
    outcomes of pressing this button, not errors — and the conversation is
    unchanged either way, because compaction only ever affects what is sent to
    the model, never the transcript.
    """
    session = get_object_or_404(_sessions(request), pk=session_id)
    outcome = llm_service.compact(session, force=True)
    session.refresh_from_db()
    return Response({**outcome, "session": session.as_dict()})


def _slug(text: str) -> str:
    keep = [c.lower() if c.isalnum() else "-" for c in (text or "")]
    return re.sub(r"-+", "-", "".join(keep)).strip("-")[:60] or "chat"


def _markdown(session: ChatSession, turns: list[InsightTurn]) -> str:
    """One conversation as something readable outside this app.

    Markdown rather than the JSON next door because the two are for different
    people: JSON is for whatever scores these answers, and this is for reading,
    pasting into a note, or taking to an appointment. The caveats travel with
    it — an answer separated from its confidence and its limitations is exactly
    the artefact this system spends its effort not producing.
    """
    lines = [f"# {session.title or 'Chat'}", ""]
    if session.project:
        lines.append(f"**Project:** {session.project.name}")
    lines.append(f"**Started:** {session.created_at:%Y-%m-%d %H:%M}")
    lines.append(f"**Messages:** {len(turns)}")
    lines += [
        "",
        "> Wellness guidance generated from this person's own recorded data.",
        "> Not medical advice, and not a clinical record.",
        "",
    ]

    if session.summary:
        lines += [
            "## Earlier in this conversation",
            "",
            f"_{session.summary_turns} messages, summarised to fit the model's context. "
            "The messages themselves are below._",
            "",
            session.summary,
            "",
        ]

    for turn in turns:
        lines += ["---", "", f"### {turn.question or 'Weekly review'}", ""]
        lines.append(f"_{turn.created_at:%Y-%m-%d %H:%M}_")
        lines.append("")

        answer = turn.answer or {}
        if turn.error:
            lines += [f"**No answer:** {turn.error}", ""]
        if answer.get("summary"):
            lines += [answer["summary"], ""]
        if answer.get("period_examined"):
            lines += [f"*Period examined: {answer['period_examined']}*", ""]

        if answer.get("observations"):
            lines.append("**Observations**")
            lines.append("")
            for item in answer["observations"]:
                lines.append(f"- {item.get('statement', '')}")
                if item.get("evidence"):
                    lines.append(f"  - Evidence: {item['evidence']}")
                if item.get("confidence"):
                    lines.append(f"  - Confidence: {item['confidence']}")
            lines.append("")

        if answer.get("actions"):
            lines += ["**Suggestions**", ""]
            for item in answer["actions"]:
                lines.append(
                    f"- {item.get('action', '')} — {item.get('reason', '')} "
                    f"({item.get('timeframe', '')})"
                )
            lines.append("")

        if answer.get("limitations"):
            lines += ["**Limits of this answer**", ""]
            lines += [f"- {item}" for item in answer["limitations"]]
            lines.append("")

        if answer.get("professional_review_recommended"):
            lines += [
                "> **Worth raising with a healthcare professional.** "
                + (answer.get("professional_review_reason") or ""),
                "",
            ]

        meta = []
        if turn.model_name:
            meta.append(f"model {turn.model_name}")
        if turn.latency_ms:
            meta.append(f"{turn.latency_ms / 1000:.0f}s")
        if turn.tool_calls:
            meta.append(f"{len(turn.tool_calls)} tool call(s)")
        if turn.rating is not None:
            meta.append(f"rated {'useful' if turn.rating > 0 else 'not useful'}")
        if meta:
            lines += [f"<sub>{' · '.join(meta)}</sub>", ""]
        if turn.note:
            lines += [f"> Your note: {turn.note}", ""]

    return "\n".join(lines)


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def session_export(request, session_id, fmt: str):
    """One conversation, as a file.

    `.md` for something a person reads, `.json` for everything the row holds.
    Served as an attachment so the browser saves it under a name that says which
    conversation it was, rather than the UUID.
    """
    session = get_object_or_404(_sessions(request).select_related("project"), pk=session_id)
    turns = list(session.turns.order_by("created_at"))
    stem = f"{_slug(session.title)}-{session.created_at:%Y%m%d}"
    fmt = (fmt or "md").lower()

    if fmt == "json":
        body = json.dumps(
            {
                **session.as_dict(message_count=len(turns)),
                "project": session.project.as_dict() if session.project else None,
                "messages": [turn.as_dict() for turn in turns],
                "exported_at": timezone.now().isoformat(),
                "retention_days": InsightTurn.retention_days(),
            },
            indent=2,
        )
        response = HttpResponse(body, content_type="application/json")
    elif fmt == "md":
        response = HttpResponse(
            _markdown(session, turns), content_type="text/markdown; charset=utf-8"
        )
    else:
        return Response(
            {"detail": "export must end in .md or .json"}, status=status.HTTP_400_BAD_REQUEST
        )

    response["Content-Disposition"] = f'attachment; filename="{stem}.{fmt}"'
    return response


# --------------------------------------------------------------------------
# Messages — the flat, filterable export
# --------------------------------------------------------------------------


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def messages(request):
    """Stored turns across every session, oldest-newest, filterable.

    Filters: `session`, `project` (id or `none`), `since`/`until` (ISO
    timestamps), `generated=1` for turns a model actually answered, `q` for a
    substring of the question. Paginated with `limit`/`offset`, and `total` is
    the count *before* paging so a caller knows how far it has to walk.

    Each row carries the session and project it belongs to. Denormalised on
    purpose: the alternative is that anything scoring these answers has to hold
    a session table in memory to know which conversation a message came from.
    """
    page = _paging(request, DEFAULT_MESSAGE_PAGE, MAX_MESSAGE_PAGE)
    if page is None:
        return Response(
            {"detail": "limit and offset must be numbers"}, status=status.HTTP_400_BAD_REQUEST
        )
    limit, offset = page

    queryset = _turns(request).select_related("session", "session__project")

    session_id = request.query_params.get("session")
    if session_id:
        # Resolved through the scoped queryset rather than filtered on directly,
        # so asking for somebody else's session is a 404 rather than an empty
        # list that reads as "that conversation had no messages". The id arrives
        # as a query parameter, so it has not been through the URL converter and
        # a malformed one would otherwise raise out of the field.
        try:
            session = get_object_or_404(_sessions(request), pk=session_id)
        except (ValidationError, ValueError):
            return Response({"detail": "no such session"}, status=status.HTTP_404_NOT_FOUND)
        queryset = queryset.filter(session=session)

    project_id = request.query_params.get("project")
    if project_id == "none":
        queryset = queryset.filter(session__project__isnull=True)
    elif project_id:
        try:
            queryset = queryset.filter(session__project_id=int(project_id))
        except ValueError:
            return Response(
                {"detail": "project must be an id or 'none'"},
                status=status.HTTP_400_BAD_REQUEST,
            )

    for name, lookup in (("since", "created_at__gte"), ("until", "created_at__lt")):
        raw = request.query_params.get(name)
        if not raw:
            continue
        moment = _moment(raw)
        if moment is None:
            return Response(
                {"detail": f"{name} must be an ISO 8601 timestamp"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        queryset = queryset.filter(**{lookup: moment})

    generated = _flag(request, "generated")
    if generated is True:
        queryset = queryset.filter(answer__isnull=False)
    elif generated is False:
        queryset = queryset.filter(answer__isnull=True)

    # `rated` splits judged from unjudged, `rating` picks a side. Both matter to
    # a feedback loop and they are not the same question: "what have I not got
    # round to rating?" is how you find the next batch to look at.
    rated = _flag(request, "rated")
    if rated is True:
        queryset = queryset.filter(rating__isnull=False)
    elif rated is False:
        queryset = queryset.filter(rating__isnull=True)

    rating = (request.query_params.get("rating") or "").strip().lower()
    if rating in ("up", "1"):
        queryset = queryset.filter(rating=InsightTurn.Rating.UP)
    elif rating in ("down", "-1"):
        queryset = queryset.filter(rating=InsightTurn.Rating.DOWN)
    elif rating:
        return Response(
            {"detail": "rating must be 'up' or 'down'"}, status=status.HTTP_400_BAD_REQUEST
        )

    # The whole point of recording a prompt version: pulling one side of a
    # prompt change to compare against the other.
    version = (request.query_params.get("prompt_version") or "").strip()
    if version:
        queryset = queryset.filter(prompt_version=version)

    model_name = (request.query_params.get("model") or "").strip()
    if model_name:
        queryset = queryset.filter(model_name=model_name)

    search = (request.query_params.get("q") or "").strip()
    if search:
        queryset = queryset.filter(question__icontains=search)

    total = queryset.count()
    # Oldest first: a feedback loop reads forward from where it stopped, and
    # newest-first paging shifts every offset each time a question is asked.
    rows = queryset.order_by("created_at")[offset : offset + limit]

    rows = list(rows)
    # One entry per conversation on this page rather than a copy of the summary
    # on every row: a compaction runs to 150 words and repeating it beside each
    # message would be most of the payload. Without it the export is not a
    # faithful record of what the model saw — some of those turns were replaced
    # by the summary in every later prompt.
    seen_sessions = {}
    for turn in rows:
        if turn.session and turn.session_id not in seen_sessions:
            seen_sessions[turn.session_id] = {
                "id": str(turn.session_id),
                "title": turn.session.title,
                "project_id": turn.session.project_id,
                "project_name": turn.session.project.name if turn.session.project else None,
                "summary": turn.session.summary or None,
                "summary_turns": turn.session.summary_turns,
                "summary_through_at": (
                    turn.session.summary_through_at.isoformat()
                    if turn.session.summary_through_at
                    else None
                ),
            }

    return Response(
        {
            "messages": [
                {
                    **turn.as_dict(),
                    "session_title": turn.session.title if turn.session else None,
                    "project_id": turn.session.project_id if turn.session else None,
                    "project_name": (
                        turn.session.project.name
                        if turn.session and turn.session.project
                        else None
                    ),
                }
                for turn in rows
            ],
            "sessions": list(seen_sessions.values()),
            "total": total,
            "limit": limit,
            "offset": offset,
            # Stated in the payload because it bounds what this endpoint can
            # ever return. A caller that assumes it is reading the full history
            # will quietly train on the last 30 days and call it everything.
            # Ratings live on the turn, so they expire with it — rate as you go
            # and export regularly, or raise the window.
            "retention_days": InsightTurn.retention_days(),
        }
    )


MAX_FEEDBACK_EXAMPLES = 20


def _tally(rows) -> dict:
    up = sum(1 for r in rows if r["rating"] == InsightTurn.Rating.UP)
    down = sum(1 for r in rows if r["rating"] == InsightTurn.Rating.DOWN)
    return {
        "answers": len(rows),
        "up": up,
        "down": down,
        "unrated": len(rows) - up - down,
        # None rather than 0 when nothing was rated: a score of zero and no
        # opinion at all are different things, and a bar chart that renders them
        # the same is how you conclude a prompt is failing when nobody judged it.
        "score": round(up / (up + down), 2) if (up + down) else None,
    }


@api_view(["GET"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def feedback_summary(request):
    """How the answers are doing, grouped by what produced them.

    A rating on its own says an answer was bad. Grouped by model and by prompt
    version it says something you can act on — that the last prompt edit made
    things worse, or that swapping the model did nothing. That comparison is the
    entire reason `prompt_version` is stored, and computing it here rather than
    leaving every caller to reduce the export themselves is what makes it a
    glance instead of a script.

    `days` bounds the window; the default covers everything still retained.
    """
    try:
        days = int(request.query_params.get("days") or 0)
    except ValueError:
        return Response({"detail": "days must be a number"}, status=status.HTTP_400_BAD_REQUEST)

    queryset = _turns(request).exclude(answer__isnull=True)
    if days > 0:
        queryset = queryset.filter(created_at__gte=timezone.now() - timedelta(days=days))

    rows = list(queryset.values("rating", "model_name", "prompt_version"))

    def grouped(key):
        buckets: dict = {}
        for row in rows:
            buckets.setdefault(row[key] or "unknown", []).append(row)
        return [
            {key: name, **_tally(items)}
            # Most-judged first: a version with two ratings is noise beside one
            # with two hundred, and sorting by score would put the noise on top.
            for name, items in sorted(buckets.items(), key=lambda kv: -len(kv[1]))
        ]

    negatives = (
        queryset.filter(rating=InsightTurn.Rating.DOWN)
        .select_related("session")
        .order_by("-created_at")[:MAX_FEEDBACK_EXAMPLES]
    )

    return Response(
        {
            "overall": _tally(rows),
            "by_model": grouped("model_name"),
            "by_prompt_version": grouped("prompt_version"),
            "current_prompt_version": prompts.VERSION,
            # The actual complaints. Counts tell you something went wrong; these
            # tell you what, which is the half you can do something about.
            "recent_negative": [
                {
                    "id": turn.pk,
                    "question": turn.question,
                    "note": turn.note,
                    "model_name": turn.model_name,
                    "prompt_version": turn.prompt_version,
                    "session_id": str(turn.session_id) if turn.session_id else None,
                    "session_title": turn.session.title if turn.session else None,
                    "created_at": turn.created_at.isoformat(),
                }
                for turn in negatives
            ],
            "retention_days": InsightTurn.retention_days(),
            "rated_turns_kept": InsightTurn.keep_rated(),
        }
    )


@api_view(["POST"])
@authentication_classes(AUTH)
@permission_classes([IsAuthenticated])
@throttle_classes([AnalyticsThrottle])
def message_feedback(request, turn_id: int):
    """Record what you thought of one answer.

    A dedicated path rather than a PATCH on the message, because the rest of a
    turn is a record of what happened and must stay read-only — being able to
    reproduce a generated health claim later is the whole reason to store one.
    This adds a judgement alongside it; it does not edit it.

    `rating` is 1, -1, or null to clear. `note` is the half worth having: "used
    the wrong sleep window" is something you can act on, where a hundred bare
    thumbs-down tell you the score and not the reason.
    """
    turn = get_object_or_404(_turns(request), pk=turn_id)

    raw = request.data.get("rating", "keep")
    if raw == "keep":
        rating = turn.rating
    elif raw in (None, "", "none"):
        rating = None
    else:
        try:
            rating = int(raw)
        except (TypeError, ValueError):
            rating = None
            raw = "bad"
        if raw == "bad" or rating not in InsightTurn.Rating.values:
            return Response(
                {"detail": "rating must be 1, -1, or null"},
                status=status.HTTP_400_BAD_REQUEST,
            )

    note = turn.note if "note" not in request.data else str(request.data.get("note") or "")
    turn.set_feedback(rating, note)
    turn.save(update_fields=["rating", "note", "rated_at"])
    return Response(turn.as_dict())
