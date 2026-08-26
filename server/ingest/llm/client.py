"""Chat client for a locally hosted OpenAI-compatible server (LM Studio).

Local by default, and that is a privacy decision rather than a convenience one:
§8 of the integration notes asks for a mode where health information never
leaves infrastructure the user controls. Pointing `LLM_BASE_URL` at a hosted
provider works — the wire format is the same — but it changes who sees the
summaries, so the status endpoint reports the destination plainly and the UI
shows it.

`urllib` rather than an HTTP library: this makes one kind of request to one
host, and a dependency that ships its own TLS stack is not worth adding to a
container that handles health data.
"""

import json
import logging
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from django.conf import settings

log = logging.getLogger(__name__)

# LM Studio's default listener. The trailing /v1 is part of the base so a
# non-LM-Studio endpoint with a different prefix can be configured whole.
DEFAULT_BASE_URL = "http://127.0.0.1:1234/v1"


class LLMUnavailable(RuntimeError):
    """The model server could not be reached or refused the request.

    Distinct from a bad answer: the caller falls back to the deterministic
    summary, which is always available, rather than showing an error page.
    """


def base_url() -> str:
    return str(getattr(settings, "LLM_BASE_URL", DEFAULT_BASE_URL) or DEFAULT_BASE_URL).rstrip("/")


def configured_model() -> str:
    # Read from the environment rather than settings: on LM Studio the loaded
    # model changes without a redeploy, and pinning it is the exception rather
    # than the rule.
    return os.environ.get("LLM_MODEL", "").strip()


def timeout_seconds() -> float:
    # Generous: a 30B-class model on consumer hardware working through a
    # tool-calling loop is not fast, and a timeout that fires mid-answer looks
    # exactly like a broken server.
    try:
        return float(os.environ.get("LLM_TIMEOUT_SECONDS", "180"))
    except ValueError:
        return 180.0


def is_enabled() -> bool:
    return bool(getattr(settings, "LLM_ENABLED", True))


# A tailnet address: Tailscale's CGNAT range, or a MagicDNS name.
TAILNET_HOST = re.compile(r"\.ts\.net$|^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.")


def destination() -> dict:
    """Where health summaries are actually sent, classified for the UI.

    Three cases, and the difference between them is a real privacy claim rather
    than a technical detail:

    * `loopback` — the model runs on this server.
    * `tailnet` — the model runs on another machine on the user's own private
      network, reached over a WireGuard link nobody else can see. This is the
      normal setup here: LM Studio lives on a laptop, the server does not have a
      GPU worth using.
    * `external` — anything else, which means a third party receives health
      summaries. §8 requires that be stated plainly rather than inferred.
    """
    host = urllib.parse.urlparse(base_url()).hostname or ""
    if host in {"127.0.0.1", "localhost", "::1", "host.docker.internal"}:
        kind, description = "loopback", "on this server"
    elif TAILNET_HOST.search(host):
        kind, description = "tailnet", f"on your own machine ({host}) over your private tailnet"
    else:
        kind, description = "external", f"to an external service at {host}"
    return {"kind": kind, "host": host, "description": description}


def is_local() -> bool:
    """True when no third party receives health summaries."""
    return destination()["kind"] != "external"


def _post(path: str, payload: dict, timeout: float | None = None) -> dict:
    request = urllib.request.Request(
        f"{base_url()}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    key = os.environ.get("LLM_API_KEY", "").strip()
    if key:
        request.add_header("Authorization", f"Bearer {key}")

    try:
        with urllib.request.urlopen(request, timeout=timeout or timeout_seconds()) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise LLMUnavailable(f"model server returned HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise LLMUnavailable(f"could not reach the model server at {base_url()}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise LLMUnavailable(f"model server returned a non-JSON body: {exc}") from exc


def available_models() -> list[str]:
    request = urllib.request.Request(f"{base_url()}/models", method="GET")
    key = os.environ.get("LLM_API_KEY", "").strip()
    if key:
        request.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.loads(response.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 - any failure means "not reachable"
        raise LLMUnavailable(f"could not list models at {base_url()}: {exc}") from exc
    return [item.get("id", "") for item in body.get("data", []) if item.get("id")]


# LM Studio's own REST API, alongside the OpenAI-compatible one. It is the only
# place the context length is available: /v1/models follows OpenAI's schema,
# which has no field for it.
LMSTUDIO_API = "/api/v0/models"


def loaded_context_length() -> int | None:
    """How much context the loaded model was actually given, if the server says.

    Worth asking rather than configuring, because the answer changes whenever
    somebody reloads a model in LM Studio — and a stale number here is not
    inert: too low means paying for summarisation that was not needed, too high
    means finding the real limit as a truncated answer halfway through a
    conversation.

    Returns None for anything that is not LM Studio, which is not an error. The
    caller falls back to LLM_CONTEXT_TOKENS.
    """
    root = base_url().removesuffix("/v1")
    request = urllib.request.Request(f"{root}{LMSTUDIO_API}", method="GET")
    key = os.environ.get("LLM_API_KEY", "").strip()
    if key:
        request.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = json.loads(response.read().decode("utf-8"))
    except Exception:  # noqa: BLE001 - any failure just means "cannot tell"
        return None

    models = [m for m in body.get("data", []) if isinstance(m, dict)]
    wanted = configured_model()
    candidates = [m for m in models if m.get("id") == wanted] if wanted else []
    candidates = candidates or [m for m in models if m.get("state") == "loaded"]
    for model in candidates:
        length = model.get("loaded_context_length") or model.get("max_context_length")
        if isinstance(length, int) and length > 0:
            return length
    return None


def resolve_model() -> str:
    """The configured model, or the first one the server offers.

    Embedding models are skipped — LM Studio lists them alongside chat models
    and picking one produces a confusing failure several seconds later.
    """
    configured = configured_model()
    if configured:
        return configured
    models = [m for m in available_models() if "embed" not in m.lower()]
    if not models:
        raise LLMUnavailable("the model server has no chat model loaded")
    return models[0]


def chat(
    messages: list[dict],
    *,
    model: str,
    tools: list[dict] | None = None,
    response_format: dict | None = None,
    temperature: float = 0.2,
    max_tokens: int = 1600,
) -> dict:
    """One completion. Returns `{message, usage, latency_ms, finish_reason}`."""
    payload = {
        "model": model,
        "messages": messages,
        # Low but not zero. Greedy decoding on a small local model tends to
        # loop on tool calls; a little noise breaks the cycle without making the
        # numbers move, since the numbers come from tools rather than the model.
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    if response_format:
        payload["response_format"] = response_format

    started = time.monotonic()
    body = _post("/chat/completions", payload)
    latency_ms = int((time.monotonic() - started) * 1000)

    choices = body.get("choices") or []
    if not choices:
        raise LLMUnavailable("model server returned no choices")

    return {
        "message": choices[0].get("message") or {},
        "finish_reason": choices[0].get("finish_reason"),
        "usage": body.get("usage") or {},
        "latency_ms": latency_ms,
        "model": body.get("model") or model,
    }


def status() -> dict:
    """What the UI needs to say where health summaries are being processed."""
    info = {
        "enabled": is_enabled(),
        "base_url": base_url(),
        "local": is_local(),
        "destination": destination(),
        "configured_model": configured_model() or None,
    }
    if not is_enabled():
        info.update(reachable=False, detail="Insight generation is switched off on this server.")
        return info
    try:
        models = available_models()
        info.update(
            reachable=True,
            models=models,
            model=resolve_model(),
            detail=None,
        )
    except LLMUnavailable as exc:
        info.update(reachable=False, models=[], model=None, detail=str(exc))
    return info
