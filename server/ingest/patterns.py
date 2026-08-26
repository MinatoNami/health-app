"""Recurring habits: the day of the week, and the weekend.

A pattern is a weaker claim than a correlation and needs a different test. "You
sleep worse on Tuesdays" is one weekday's dozen observations against the other
six weekdays' seventy, and a p-value computed from that — seven of them per
metric, across six metrics — is forty-two more chances to find nothing dressed as
something.

So this does not compute p-values. It reuses the vocabulary the rest of this
codebase already grades changes with: a weekday is reported when it sits outside
the person's own day-to-day variability, measured with the same robust spread
`classify_change` uses, and it is described in exactly those terms — "notable
against your own variation" rather than "significant". A reader can act on the
first. The second would be a claim this sample size cannot carry.

Two floors keep it quiet. Every weekday needs a minimum number of observations
before it is eligible at all, and only the single strongest weekday per metric is
reported — because "your Tuesdays and also slightly your Thursdays and possibly
your Sundays" is how a finding turns into a horoscope.
"""

import statistics
from datetime import date, timedelta

from . import health_analysis

DEFAULT_DAYS = 90
MAX_DAYS = 365

# Four observations of a weekday means four weeks of data behind the claim. Below
# that, one holiday Tuesday is the whole finding.
MIN_OBSERVATIONS = 4
MIN_OTHER_OBSERVATIONS = 12

WEEKDAY_NAMES = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
]

# The metrics where a weekly rhythm is a real thing somebody could act on.
# Deliberately short: run this over forty metrics and something will always look
# like a Tuesday problem.
EXAMINED = [
    "sleep_analysis",
    "step_count",
    "apple_exercise_time",
    "resting_heart_rate",
    "heart_rate_variability_sdnn",
    "dietary_energy_consumed",
]


def _fmt(value: float, decimals: int) -> float:
    return round(value, decimals) if decimals else round(value)


def _say(value: float, spec) -> str:
    """A number the way it would be said out loud.

    `step_count` carries the unit "count", which is right on the wire and reads
    as broken English in a sentence — "steps on weekends averages 6275 count".
    The label already says what is being counted.
    """
    rounded = _fmt(value, spec.decimals)
    text = f"{rounded:,}" if abs(rounded) >= 1000 else f"{rounded}"
    return text if spec.unit == "count" else f"{text} {spec.unit}"


def _describe(spec, label: str, group: list[float], others: list[float], significance: str) -> str:
    difference = statistics.fmean(group) - statistics.fmean(others)
    direction = "higher" if difference > 0 else "lower"
    return (
        f"{spec.label} on {label} averages {_say(statistics.fmean(group), spec)}, "
        f"{_say(abs(difference), spec)} {direction} than the rest of the week "
        f"({_say(statistics.fmean(others), spec)}) "
        f"across {len(group)} of them. That gap is {significance} against this person's "
        f"own day-to-day variation."
    )


def _split(
    values: dict[date, float], belongs: callable
) -> tuple[list[float], list[float]]:
    group = [value for day, value in values.items() if belongs(day)]
    others = [value for day, value in values.items() if not belongs(day)]
    return group, others


def _assess(spec, label: str, group: list[float], others: list[float]) -> dict | None:
    """One group against the rest, graded the way every other change here is."""
    if len(group) < MIN_OBSERVATIONS or len(others) < MIN_OTHER_OBSERVATIONS:
        return None
    difference = statistics.fmean(group) - statistics.fmean(others)
    significance = health_analysis.classify_change(difference, others)
    return {
        "metric_slug": spec.slug,
        "label": spec.label,
        "unit": spec.unit,
        "group": label,
        "observations": len(group),
        "comparison_observations": len(others),
        "group_mean": _fmt(statistics.fmean(group), spec.decimals),
        "rest_mean": _fmt(statistics.fmean(others), spec.decimals),
        "difference": _fmt(difference, spec.decimals),
        "direction": "higher" if difference > 0 else "lower",
        "significance": significance,
        "statement": _describe(spec, label, group, others, significance),
    }


def _metric_days(slug: str, days: int, as_of: date, tz_name: str | None) -> dict[date, float]:
    start_day = as_of - timedelta(days=days - 1)
    return {
        value.day: value.value
        for value in health_analysis.day_values(slug, start_day, as_of, tz_name)
    }


def discover(
    days: int = DEFAULT_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """Weekday and weekend rhythms, one finding per metric at most."""
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    days = max(14, min(days, MAX_DAYS))

    available = set(health_analysis.available_metrics())
    weekday_findings = []
    weekend_findings = []
    examined = []
    skipped = []

    for slug in EXAMINED:
        if slug not in available:
            skipped.append({"metric_slug": slug, "reason": "no data recorded"})
            continue
        spec = health_analysis.METRICS[slug]
        values = _metric_days(slug, days, as_of, tz_name)
        if len(values) < MIN_OBSERVATIONS + MIN_OTHER_OBSERVATIONS:
            skipped.append(
                {
                    "metric_slug": slug,
                    "reason": f"only {len(values)} day(s) recorded in {days} days",
                }
            )
            continue
        examined.append(slug)

        # Weekend against weekday, which is the pattern people actually have.
        group, others = _split(values, lambda day: day.weekday() >= 5)
        weekend = _assess(spec, "weekends", group, others)
        if weekend and weekend["significance"] in ("notable", "slight"):
            weekend_findings.append(weekend)

        # Then the single strongest individual weekday, if any stands out. Only
        # the strongest: a list of six mildly unusual weekdays is a horoscope.
        best = None
        for index, name in enumerate(WEEKDAY_NAMES):
            group, others = _split(values, lambda day, index=index: day.weekday() == index)
            finding = _assess(spec, f"{name}s", group, others)
            if finding is None or finding["significance"] != "notable":
                continue
            if best is None or abs(finding["difference"]) > abs(best["difference"]):
                best = finding
        if best:
            weekday_findings.append(best)

    findings = sorted(
        weekend_findings + weekday_findings,
        key=lambda item: (item["significance"] != "notable", -abs(item["difference"] or 0)),
    )
    return {
        "from": (as_of - timedelta(days=days - 1)).isoformat(),
        "to": as_of.isoformat(),
        "window_days": days,
        "metrics_examined": examined,
        "metrics_skipped": skipped,
        "patterns_found": len(findings),
        "patterns": findings,
        "method": {
            "test": "each group's mean against the rest of the week, graded against the "
            "person's own robust spread — the same scale used to call a change notable "
            "anywhere else here. No p-values: seven weekdays across six metrics is far "
            "too many comparisons for one to mean anything.",
            "floors": f"a group needs at least {MIN_OBSERVATIONS} observations and at "
            f"least {MIN_OTHER_OBSERVATIONS} to compare against",
            "reporting": "at most one individual weekday per metric, the strongest",
        },
        "limitations": [
            "A weekly rhythm in the data is a rhythm in the life around it — shift "
            "patterns, a standing Tuesday commitment, when the watch gets charged. It is "
            "not a property of the day.",
            "Weekday groups are small. Four Tuesdays is four Tuesdays, and one unusual "
            "week can be most of a finding.",
            "A metric with no pattern reported has not been shown to be even; this window "
            "just could not tell one from ordinary variation.",
        ],
    }
