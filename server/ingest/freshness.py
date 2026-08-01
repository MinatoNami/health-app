"""Which signals have gone quiet, and telling someone about it.

This exists because of a real failure: sleep stopped uploading on 2026-06-27 and
nobody noticed for 35 days. Nothing errored. The app kept syncing, the dashboard
kept drawing, the backups kept running — one of the five signals the whole
system is built on simply stopped, and every screen that could have said so
required you to already suspect it.

Silence is the default failure mode of this architecture. A revoked Health
permission, a watch left in a drawer, and background delivery dying after an OS
update all look exactly like a quiet week. So the check runs on a timer and
pushes, rather than waiting to be visited.

Two things keep it from becoming noise people mute:

* **Cadence-aware thresholds.** Weight is not step count. Alerting after 48h on
  a metric someone records twice a week trains them to ignore the alert.
* **State.** A dead metric is reported once, then at most weekly — not every
  night for a month. Recovery is reported too, so you learn the fix worked
  without having to go and check.
"""

import json
import logging
import math
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from . import health_analysis
from .models import AlertState

log = logging.getLogger(__name__)

# Grace before a quiet metric is called stale, expressed as "roughly two
# expected recordings missed". Daily metrics get 2 days; weight, expected about
# twice a week, gets 5.
MIN_STALE_DAYS = 2


def stale_after_days(spec: health_analysis.MetricSpec) -> int:
    cadence = max(0.05, spec.expected_cadence)
    return max(MIN_STALE_DAYS, math.ceil(2 / cadence))


@dataclass
class Finding:
    metric_slug: str
    label: str
    days_since: int
    threshold_days: int
    last_recorded_at: str | None

    @property
    def key(self) -> str:
        return f"freshness:{self.metric_slug}"

    def describe(self) -> str:
        when = self.last_recorded_at[:10] if self.last_recorded_at else "never"
        return f"{self.label}: last recorded {when} ({self.days_since} days ago)"


def check(tz_name: str | None = None) -> list[Finding]:
    """Metrics that were arriving and have stopped.

    Only considers metrics with data at some point. A metric that has never
    appeared is one this person does not track, and alerting about it would be
    telling them off for a choice rather than reporting a fault.
    """
    today = health_analysis.today(tz_name)
    zone = health_analysis.analytics.zone(tz_name)
    findings = []

    for slug in health_analysis.available_metrics():
        spec = health_analysis.METRICS[slug]
        seen = health_analysis.last_recorded(slug)
        if seen is None:
            continue
        days = (today - seen.astimezone(zone).date()).days
        threshold = stale_after_days(spec)
        if days >= threshold:
            findings.append(
                Finding(
                    metric_slug=slug,
                    label=spec.label,
                    days_since=days,
                    threshold_days=threshold,
                    last_recorded_at=seen.isoformat(),
                )
            )

    findings.sort(key=lambda f: -f.days_since)
    return findings


# --------------------------------------------------------------------------
# Notification
# --------------------------------------------------------------------------


def webhook_url() -> str:
    return str(getattr(settings, "ALERT_WEBHOOK_URL", "") or "").strip()


def webhook_format() -> str:
    return str(getattr(settings, "ALERT_WEBHOOK_FORMAT", "text") or "text").strip().lower()


def renotify_days() -> int:
    return int(getattr(settings, "ALERT_RENOTIFY_DAYS", 7) or 7)


class NotifyFailed(RuntimeError):
    """The webhook could not be reached. Logged, never raised to cron as a
    crash — a broken notifier must not also stop the check from recording
    state, or every run would re-alert forever."""


def send(title: str, message: str) -> bool:
    """POSTs to the configured webhook. Returns whether it went out.

    Two formats because the useful targets disagree: ntfy and most generic
    receivers want a plain-text body, while Slack and Discord want JSON under
    different keys. Sending `text` and `content` together covers both without
    asking which one this is.
    """
    url = webhook_url()
    if not url:
        return False

    if webhook_format() == "json":
        body = json.dumps(
            {"title": title, "message": message, "text": f"{title}\n{message}",
             "content": f"**{title}**\n{message}"}
        ).encode()
        headers = {"Content-Type": "application/json"}
    else:
        body = message.encode()
        headers = {"Content-Type": "text/plain; charset=utf-8", "Title": title}

    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        log.error("Alert webhook failed: %s", exc)
        raise NotifyFailed(str(exc)) from exc


def _due(key: str) -> bool:
    """Whether this finding may be announced again yet."""
    state = AlertState.objects.filter(key=key).first()
    if state is None or state.resolved_at is not None:
        return True
    return timezone.now() - state.last_sent_at >= timedelta(days=renotify_days())


def run(tz_name: str | None = None, force: bool = False, dry_run: bool = False) -> dict:
    """One pass: check, notify what is newly wrong or wrong again, and close out
    anything that has recovered."""
    findings = check(tz_name)
    found = {f.key: f for f in findings}

    to_report = [f for f in findings if force or _due(f.key)]

    # Recovery: previously open, no longer failing. Reported so you learn the
    # fix worked without going to look, which is the difference between an
    # alert you trust and one you check manually anyway.
    recovered = [
        state
        for state in AlertState.objects.filter(resolved_at__isnull=True)
        if state.key.startswith("freshness:") and state.key not in found
    ]

    sent = False
    lines = []
    if to_report:
        lines.append("Not syncing:")
        lines.extend(f"  • {f.describe()}" for f in to_report)
    if recovered:
        lines.append("Syncing again:")
        lines.extend(f"  • {state.label}" for state in recovered)

    if lines and not dry_run:
        title = (
            f"Health data: {len(to_report)} metric(s) not syncing"
            if to_report
            else "Health data: syncing again"
        )
        try:
            sent = send(title, "\n".join(lines))
        except NotifyFailed:
            sent = False

    if not dry_run:
        now = timezone.now()
        # State is recorded whether or not the webhook worked. If a failed send
        # also skipped the bookkeeping, a broken notifier would mean every run
        # re-alerts forever the moment it comes back.
        for finding in to_report:
            AlertState.objects.update_or_create(
                key=finding.key,
                defaults={
                    "label": finding.label,
                    "detail": finding.describe(),
                    "last_sent_at": now,
                    "resolved_at": None,
                    "notified": sent,
                },
            )
        for state in recovered:
            state.resolved_at = now
            state.save(update_fields=["resolved_at"])

    return {
        "checked_at": timezone.now().isoformat(),
        "stale": [f.describe() for f in findings],
        "reported": [f.describe() for f in to_report],
        "recovered": [state.label for state in recovered],
        "notified": sent,
        "webhook_configured": bool(webhook_url()),
        "dry_run": dry_run,
    }
