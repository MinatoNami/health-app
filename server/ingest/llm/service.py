"""Orchestration: snapshot → safety → tools → structured answer → safety.

The order is the point. By the time the model is asked anything, the numbers
already exist and the escalation level has already been decided. The model
contributes wording and prioritisation; it does not contribute arithmetic, and
it does not get to decide whether something is serious.

Failure is designed for rather than handled. If the model server is down, slow,
or produces something that trips the post-flight check, the caller still gets
the deterministic snapshot — which is the part that was actually measured.
"""

import json
import logging
import re

from django.db.models import Q
from django.utils import timezone

from .. import health_analysis, safety
from ..models import InsightTurn
from . import client, prompts, tools

log = logging.getLogger(__name__)

# A local model will occasionally decide it needs one more tool call forever.
# Six rounds is more than any question here needs; past that, answer with what
# has been gathered rather than spinning.
MAX_TOOL_ROUNDS = 6

# Reasoning models emit their scratchpad inline on some builds. It is not part
# of the answer and it is definitely not part of the JSON.
THINK_BLOCK = re.compile(r"<(think|thinking|reasoning)>.*?</\1>", re.DOTALL | re.IGNORECASE)


def _condense(snapshot: dict) -> dict:
    """The snapshot, trimmed to what a model can hold and reason about.

    Per-day arrays are dropped: they invite exactly the raw-row arithmetic this
    architecture exists to prevent, and they crowd a modest local context window
    with numbers the answer will never quote.
    """
    condensed = {
        "as_of": snapshot["as_of"],
        "timezone": snapshot["timezone"],
        "windows": snapshot["generated_for"],
        "overall_confidence": snapshot["overall_confidence"],
        "metrics": [
            {
                "metric": m["metric_slug"],
                "label": m["label"],
                "unit": m["unit"],
                "current": m["current"]["value"],
                "current_window": f"{m['current']['from']}..{m['current']['to']}",
                "current_valid_days": m["current"]["valid_days"],
                "baseline": m["baseline"]["value"],
                "baseline_window": f"{m['baseline']['from']}..{m['baseline']['to']}",
                "baseline_valid_days": m["baseline"]["valid_days"],
                "change": m["change"],
                "change_pct": m["change_pct"],
                "significance": m["significance"],
                "confidence": m["confidence"],
                "confidence_reason": m["confidence_reason"],
            }
            for m in snapshot["metrics"]
        ],
        "data_quality": [
            {
                "metric": q["metric_slug"],
                "quality": q["quality"],
                "valid_days": q["valid_days"],
                "window_days": q["window_days"],
                "notes": q["notes"],
            }
            for q in snapshot["data_quality"]
        ],
        "workouts": {
            k: v for k, v in snapshot["workouts"].items() if k not in ("recent", "by_activity")
        },
        "metrics_never_recorded": snapshot["metrics_unavailable"],
        # Named separately so the model can say "sleep has not synced since
        # 27 June" instead of "you slept 0 hours", which is what a bare gap
        # looks like.
        "metrics_that_stopped_syncing": snapshot.get("metrics_not_syncing") or [],
    }
    if snapshot.get("sleep"):
        condensed["sleep"] = {
            k: v for k, v in snapshot["sleep"].items() if k != "nights"
        }
    return condensed


def _system_prompt(verdict: safety.SafetyVerdict, snapshot: dict) -> str:
    constraints = "\n".join(f"- {c}" for c in verdict.constraints)
    return (
        f"{prompts.SYSTEM}\n"
        f"CONSTRAINTS FOR THIS ANSWER (escalation level: {verdict.level})\n"
        f"{constraints}\n\n"
        "PREPARED SNAPSHOT — already computed from the database, correct, and safe to "
        "quote directly. Use these figures rather than recomputing anything. Call tools "
        "only for detail this does not contain.\n"
        f"{json.dumps(_condense(snapshot), default=str)}\n"
    )


def _candidate_texts(message: dict) -> list[str]:
    """Every field a server might have put the answer in.

    `reasoning_content` is not a fallback for tidiness — it is where Qwen-class
    reasoning models running under LM Studio actually put grammar-constrained
    output. The JSON schema constrains the first channel the model emits, which
    for a thinking model is the reasoning channel, and `content` comes back
    empty. Reading only `content` throws away a perfectly good answer.
    """
    return [
        str(message.get(key) or "").strip()
        for key in ("content", "reasoning_content", "thinking")
        if str(message.get(key) or "").strip()
    ]


def _parse_json(message: dict) -> dict:
    """The model's final message, as an object.

    Tolerant on purpose: a model that has been thinking out loud sometimes wraps
    the object in a fence or trails a sentence after it, and discarding a good
    answer over a backtick would be a poor trade.
    """
    errors = []
    for raw in _candidate_texts(message):
        cleaned = THINK_BLOCK.sub("", raw).strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.MULTILINE).strip()
        try:
            return json.loads(cleaned)
        except json.JSONDecodeError as exc:
            errors.append(exc)
            start, end = cleaned.find("{"), cleaned.rfind("}")
            if start != -1 and end > start:
                try:
                    return json.loads(cleaned[start : end + 1])
                except json.JSONDecodeError as inner:
                    errors.append(inner)
    raise errors[0] if errors else json.JSONDecodeError("empty model response", "", 0)


def _normalise(insight: dict) -> dict:
    """Coerce the model's object into the shape the UI renders.

    A missing key here would be a blank panel rather than an error, which is the
    kind of failure nobody notices for a month.
    """
    def strings(values):
        return [str(v) for v in values if isinstance(v, (str, int, float)) and str(v).strip()]

    observations = []
    for item in insight.get("observations") or []:
        if not isinstance(item, dict):
            continue
        observations.append(
            {
                "statement": str(item.get("statement") or "").strip(),
                "evidence": str(item.get("evidence") or "").strip(),
                "confidence": str(item.get("confidence") or "moderate").lower(),
            }
        )

    actions = []
    for item in (insight.get("actions") or [])[:3]:
        if not isinstance(item, dict):
            continue
        actions.append(
            {
                "action": str(item.get("action") or "").strip(),
                "reason": str(item.get("reason") or "").strip(),
                "timeframe": str(item.get("timeframe") or "").strip(),
            }
        )

    return {
        "summary": str(insight.get("summary") or "").strip(),
        "period_examined": str(insight.get("period_examined") or "").strip(),
        "observations": [o for o in observations if o["statement"]],
        "actions": [a for a in actions if a["action"]],
        "limitations": strings(insight.get("limitations") or []),
        "confidence": str(insight.get("confidence") or "low").lower(),
        "professional_review_recommended": bool(
            insight.get("professional_review_recommended")
        ),
        "professional_review_reason": str(
            insight.get("professional_review_reason") or ""
        ).strip(),
    }


def _urgent_answer(verdict: safety.SafetyVerdict, snapshot: dict) -> dict:
    """A fixed, reviewed response for anything that reached `urgent`.

    The model is not called. §7 is explicit that serious situations should use
    reviewed guidance rather than letting a model invent thresholds, and there
    is no version of "generated text about chest pain" that is safer than a
    sentence someone wrote and checked.
    """
    return {
        "summary": safety.URGENT_NOTICE,
        "period_examined": f"snapshot as of {snapshot['as_of']}",
        "observations": [
            {
                "statement": reason,
                "evidence": "Reported by you in this question.",
                "confidence": "high",
            }
            for reason in verdict.reasons
        ],
        "actions": [
            {
                "action": "Contact urgent care or your local emergency number now.",
                "reason": "The symptom you described can have causes that need to be ruled "
                "out by a clinician, and no wearable measurement can do that.",
                "timeframe": "immediately",
            }
        ],
        "limitations": [
            "This app cannot assess symptoms.",
            "Normal-looking heart rate, oxygen, or sleep data does not rule out a serious cause.",
        ],
        "confidence": "high",
        "professional_review_recommended": True,
        "professional_review_reason": "You described a symptom that needs prompt medical attention.",
    }


def _run_tool_loop(messages: list[dict], model: str, tz_name: str | None) -> tuple[list[dict], list[dict], dict]:
    """Returns (messages, tool_call_log, usage totals)."""
    schema = tools.openai_schema()
    log_entries: list[dict] = []
    usage = {"prompt_tokens": 0, "completion_tokens": 0, "latency_ms": 0}

    for _round in range(MAX_TOOL_ROUNDS):
        result = client.chat(messages, model=model, tools=schema, max_tokens=1200)
        usage["prompt_tokens"] += result["usage"].get("prompt_tokens", 0) or 0
        usage["completion_tokens"] += result["usage"].get("completion_tokens", 0) or 0
        usage["latency_ms"] += result["latency_ms"]

        message = result["message"]
        calls = message.get("tool_calls") or []

        # Reasoning traces and the assistant's own prose between tool calls are
        # dropped from the history: they are not evidence, and keeping them lets
        # a model quote its own earlier guess back as if it were a measurement.
        messages.append(
            {
                "role": "assistant",
                "content": THINK_BLOCK.sub("", message.get("content") or "").strip(),
                **({"tool_calls": calls} if calls else {}),
            }
        )
        if not calls:
            break

        for entry in calls:
            function = entry.get("function") or {}
            name = function.get("name") or ""
            raw = function.get("arguments")
            try:
                arguments = json.loads(raw) if isinstance(raw, str) and raw.strip() else (raw or {})
            except json.JSONDecodeError:
                arguments = {}
            payload = tools.call(name, arguments if isinstance(arguments, dict) else {}, tz_name)
            log_entries.append({"tool": name, "arguments": arguments, "ok": "error" not in payload})
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": entry.get("id") or name,
                    "name": name,
                    "content": json.dumps(payload, default=str),
                }
            )
    else:
        log.warning("Tool loop hit the %d-round ceiling", MAX_TOOL_ROUNDS)

    return messages, log_entries, usage


def answer(
    question: str,
    *,
    context: str = "",
    tz_name: str | None = None,
    owner=None,
    persist: bool = True,
    instruction: str | None = None,
) -> dict:
    """Answer one question about this person's health data.

    Always returns a payload. `generated` says whether the model contributed; if
    it is false, `snapshot` is still the measured truth and the UI shows it.
    """
    question = (question or "").strip()
    snapshot = health_analysis.snapshot(tz_name=tz_name)
    verdict = safety.preflight(question, snapshot, context)

    payload = {
        "question": question,
        "asked_at": timezone.now().isoformat(),
        "snapshot": snapshot,
        "safety": verdict.as_dict(),
        "answer": None,
        "generated": False,
        "tool_calls": [],
        "model": None,
        "error": None,
    }

    if verdict.level == "urgent":
        payload["answer"] = _urgent_answer(verdict, snapshot)
        payload["source"] = "safety_rules"
        _persist(payload, owner, persist)
        return payload

    if not client.is_enabled():
        payload["error"] = "Insight generation is switched off on this server."
        _persist(payload, owner, persist)
        return payload

    try:
        model = client.resolve_model()
    except client.LLMUnavailable as exc:
        payload["error"] = str(exc)
        _persist(payload, owner, persist)
        return payload

    user_message = question
    if context:
        user_message += f"\n\nContext I want you to take into account:\n{context}"
    if instruction:
        user_message = f"{instruction}\n\n{user_message}" if question else instruction

    messages = [
        {"role": "system", "content": _system_prompt(verdict, snapshot)},
        {"role": "user", "content": user_message},
    ]

    try:
        messages, tool_log, usage = _run_tool_loop(messages, model, tz_name)
        messages.append({"role": "user", "content": prompts.FINALISE})
        final = client.chat(
            messages,
            model=model,
            response_format=prompts.RESPONSE_FORMAT,
            temperature=0.1,
            max_tokens=2000,
        )
        insight = _normalise(_parse_json(final["message"]))
    except client.LLMUnavailable as exc:
        log.warning("Insight generation unavailable: %s", exc)
        payload["error"] = str(exc)
        _persist(payload, owner, persist)
        return payload
    except (json.JSONDecodeError, ValueError, TypeError) as exc:
        log.warning("Model returned an unusable answer: %s", exc)
        payload["error"] = (
            "The model produced an answer that could not be read as structured output. "
            "The measured summary below is unaffected."
        )
        _persist(payload, owner, persist)
        return payload

    verdict = safety.postflight(insight, verdict)
    payload["safety"] = verdict.as_dict()
    payload["tool_calls"] = tool_log
    payload["model"] = {
        "name": final["model"],
        "endpoint": client.base_url(),
        "local": client.is_local(),
        "destination": client.destination(),
        "prompt_tokens": usage["prompt_tokens"] + (final["usage"].get("prompt_tokens") or 0),
        "completion_tokens": usage["completion_tokens"]
        + (final["usage"].get("completion_tokens") or 0),
        "latency_ms": usage["latency_ms"] + final["latency_ms"],
        "tool_rounds": len(tool_log),
    }

    if verdict.blocked:
        payload["answer"] = None
        payload["error"] = verdict.blocked_reason
    else:
        payload["answer"] = insight
        payload["generated"] = True
        payload["source"] = "model"

    _persist(payload, owner, persist)
    return payload


def weekly_review(tz_name: str | None = None, owner=None, persist: bool = True) -> dict:
    """The proactive review from §10 phase 4, on demand rather than on a timer."""
    return answer(
        "",
        instruction=prompts.WEEKLY_REVIEW,
        tz_name=tz_name,
        owner=owner,
        persist=persist,
    )


# --------------------------------------------------------------------------
# Retention
# --------------------------------------------------------------------------


def _persist(payload: dict, owner, persist: bool):
    """Stores the turn, then prunes.

    §8 asks that prompts and model responses not be retained indefinitely. The
    snapshot is deliberately *not* stored — it is derived from records that are
    still in the database and can be recomputed, so keeping a second copy of
    health figures inside a conversation log buys nothing and doubles what a
    deletion request has to reach.
    """
    if not persist:
        return
    try:
        InsightTurn.objects.create(
            owner=owner if getattr(owner, "pk", None) else None,
            question=payload["question"][:2000],
            answer=payload.get("answer"),
            safety=payload.get("safety"),
            tool_calls=payload.get("tool_calls"),
            model_name=(payload.get("model") or {}).get("name", "")[:128],
            latency_ms=(payload.get("model") or {}).get("latency_ms") or 0,
            error=(payload.get("error") or "")[:500],
        )
        InsightTurn.prune()
    except Exception:  # noqa: BLE001 - a logging failure must not lose the answer
        log.exception("Could not record insight turn")


def _owned_by(owner):
    """This person's turns, plus the unowned ones.

    Turns arrive unowned when the caller authenticated with a token minted on
    the CLI, which has no user behind it. Hiding those from the one dashboard
    that can show them would mean questions that are stored, subject to
    retention, and invisible — the worst of both.
    """
    queryset = InsightTurn.objects.all()
    if getattr(owner, "pk", None):
        return queryset.filter(Q(owner=owner) | Q(owner__isnull=True))
    return queryset


def history(owner=None, limit: int = 20) -> list[dict]:
    return [turn.as_dict() for turn in _owned_by(owner)[:limit]]


def forget(owner=None) -> int:
    """Permanent deletion of stored questions and answers."""
    deleted, _ = _owned_by(owner).delete()
    return deleted
