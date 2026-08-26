"""Scoring one stored answer against the question it was supposed to answer.

Kept out of `prompts.py` deliberately. `prompts.VERSION` is a digest of the text
the *answering* model is sent, and it is what groups ratings in
`/v1/chat/feedback`. Folding the judge's wording into that digest would move the
version every time the scoring rubric was edited, and the comparison the version
exists for — "did my prompt change help?" — would silently reset on a change that
never reached the answering model at all.

The judge reads relevance, not truth in the world: whether the answer addressed
the question that was asked, over the period that was asked about, using figures
that appear in the evidence it was given. Whether the figures themselves are
right is a question for `tests/`, which has the database.

A caveat worth keeping in view: by default this runs the same local model that
wrote the answer. A model grading its own work is a weak judge and grades
generously. It is still worth having — it catches the answer that reported on a
different week entirely — but treat a rising score as an invitation to read the
failures, not as proof anything improved. `--judge-model` points it at a
different one when a second model is loaded.
"""

import json
import logging

from . import client

log = logging.getLogger(__name__)

SYSTEM = """You grade one answer produced by a health-data assistant. You are not
answering the question yourself and you are not deciding whether the person is
healthy.

You are given the question, the evidence the assistant had, and the answer it
wrote. Judge three things, and nothing else.

RELEVANCE — did it answer the question that was asked?
- A correct report about something else is not a relevant answer. If the question
  named a day, a night, a date or one metric, the answer is about that.
- An answer that leads with a general weekly summary when one specific thing was
  asked about is not relevant, even if every figure in it is correct.
- Saying "there is no data for that" *is* relevant when it is true. Refusing to
  answer is not automatically a failure.
- A greeting or an acknowledgement answered with a health report is not relevant.

SCOPE — does the period it examined match the period that was asked about?
- If they differ and the answer says so and explains why, that is fine.
- If they differ silently, that is a scope failure.

GROUNDING — does every figure in the answer appear in the evidence?
- Look them up. A number that is not in the evidence is fabricated, however
  plausible it looks.
- Watch for a window average reported as a single day's or single night's figure.
  The evidence labels these: anything called average, per-logged-day, typical,
  lowest or highest describes a window, never one day inside it. Quoting one
  against a named date is a grounding failure.

Be strict and be specific. In `reason`, quote the exact figure or phrase that
decided it. "Seems fine" is not a review."""

SCHEMA = {
    "type": "object",
    "properties": {
        "relevant": {"type": "boolean"},
        "scope_ok": {"type": "boolean"},
        "grounded": {"type": "boolean"},
        "score": {
            "type": "integer",
            "description": "0 answered a different question, 1 partly on topic but "
            "led with something else, 2 answered it with a flaw worth noting, "
            "3 answered exactly what was asked.",
        },
        "reason": {
            "type": "string",
            "description": "One or two sentences, quoting the figure or phrase that "
            "decided the verdict.",
        },
    },
    "required": ["relevant", "scope_ok", "grounded", "score", "reason"],
}

RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {"name": "answer_grade", "strict": True, "schema": SCHEMA},
}


def _evidence(payload: dict) -> str:
    """What the assistant actually had in front of it, as the judge sees it.

    The condensed snapshot rather than the raw one: grading against evidence the
    answering model was never shown would mark a fabrication as grounded, which
    is the one thing this must not do.
    """
    from . import service

    parts = [
        "SNAPSHOT (the assistant had this in its system prompt):",
        json.dumps(service._condense(payload.get("snapshot") or {}), default=str),
    ]
    calls = payload.get("tool_calls") or []
    if calls:
        parts.append("\nTOOLS THE ASSISTANT CALLED:")
        parts.append(json.dumps(calls, default=str))
    else:
        parts.append("\nThe assistant called no tools, so the snapshot is all it had.")
    return "\n".join(parts)


def grade(payload: dict, rubric: str = "", model: str | None = None) -> dict:
    """Score one `service.answer` payload. Never raises — a judge that dies mid-run
    would take an evaluation of forty cases down with it, so a failure is returned
    as an ungraded row and the run carries on.
    """
    answer = payload.get("answer")
    if not answer:
        return {
            "relevant": False,
            "scope_ok": False,
            "grounded": False,
            "score": 0,
            "reason": f"No answer was produced: {payload.get('error') or 'unknown'}",
        }

    user = (
        f"QUESTION ASKED\n{payload.get('question') or '(empty)'}\n\n"
        f"{_evidence(payload)}\n\n"
        f"THE ANSWER TO GRADE\n{json.dumps(answer, default=str)}\n"
    )
    if rubric:
        user += (
            f"\nWHAT A GOOD ANSWER LOOKS LIKE HERE\n{rubric}\n"
            "This describes the target, not a script. An answer that gets there "
            "by other wording is still a good answer."
        )

    try:
        # Resolved here rather than left as None: the server takes a null model
        # as a literal name and fails to load it, so an unset --judge-model would
        # turn every row in the run into "judge unavailable".
        result = client.chat(
            [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}],
            model=model or client.resolve_model(),
            response_format=RESPONSE_FORMAT,
            temperature=0,
            max_tokens=800,
        )
        # Through the same tolerant parser the answers go through, not a bare
        # json.loads. The model behind this reasons out loud and wraps its object
        # in a <think> block; parsing raw returns an empty dict, which scores
        # every case zero and reads exactly like a prompt that broke everything.
        from . import service

        verdict = service._parse_json(result["message"])
    except (client.LLMUnavailable, json.JSONDecodeError, ValueError, TypeError) as exc:
        log.warning("Judge failed: %s", exc)
        return {
            "relevant": None,
            "scope_ok": None,
            "grounded": None,
            "score": None,
            "reason": f"judge unavailable: {exc}",
        }

    return {
        "relevant": bool(verdict.get("relevant")),
        "scope_ok": bool(verdict.get("scope_ok")),
        "grounded": bool(verdict.get("grounded")),
        "score": int(verdict.get("score") or 0),
        "reason": str(verdict.get("reason") or "").strip(),
    }
