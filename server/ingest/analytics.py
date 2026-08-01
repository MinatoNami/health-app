"""Aggregation for the dashboard.

The one thing that matters here is *not double-counting*. iPhone and Apple Watch
both write step counts for the same walk, so summing raw `quantity` samples
inflates every cumulative total — the app's README calls this out as the first
thing that bites you downstream.

HealthKit's own statistics queries deduplicate across sources, and the app ships
those as `kind=statistic` rows with deterministic per-day IDs. Those are
authoritative. But the app only re-emits a rolling window of them
(`statisticsLookbackDays`, 7 by default), so most historical days have no
rollup and the only option is to sum raw samples.

Rather than silently mixing the two, every point carries which method produced
it, and the dashboard labels the estimated ones. Quietly returning a number that
is 1.8× too large is far worse than showing a caveat.
"""

import os
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from django.db.models import Avg, Count, FloatField, Max, Min, Sum
from django.db.models.fields.json import KeyTextTransform
from django.db.models.functions import Cast, TruncDate

from .models import Record

# Samples carry a per-sample timezone, but a chart needs one definition of "day"
# or the buckets stop lining up. Configurable because the right answer is where
# the person lives, not where the server is: leaving this at UTC would split
# every Singapore evening across two days.
DEFAULT_TZ = os.environ.get("DISPLAY_TIMEZONE", "Asia/Singapore")

# Aggregations that are valid for a cumulative metric (summing is meaningful)
# versus a discrete one (summing is meaningless — averaging is the useful view).
CUMULATIVE_AGGS = {"sum", "max", "min", "count"}
DISCRETE_AGGS = {"avg", "min", "max", "count"}

SOURCE_ROLLUP = "statistic"
SOURCE_RAW = "raw_sum"

# Slugs whose plain reading is wrong, awkward, or simply not what Apple calls
# the same measurement. Everything else is derived, because there are ~170 of
# them and enumerating that by hand is a list that rots.
#
# Mirrors HealthExporter/Core/MetricName.swift. The duplication is deliberate:
# the phone names types it has never uploaded (the metric picker, the coverage
# grid), and the server names slugs no build of the app may know about, so
# neither can be the sole source. Keep the two tables in step.
_METRIC_NAMES = {
    "step_count": "Steps",
    "distance_walking_running": "Walking + Running Distance",
    "distance_cycling": "Cycling Distance",
    "distance_swimming": "Swimming Distance",
    "active_energy_burned": "Active Energy",
    "basal_energy_burned": "Resting Energy",
    "apple_exercise_time": "Exercise Minutes",
    "apple_stand_time": "Stand Minutes",
    "apple_stand_hour": "Stand Hours",
    "apple_walking_steadiness": "Walking Steadiness",
    "sleep_analysis": "Sleep",
    "body_mass": "Weight",
    "oxygen_saturation": "Blood Oxygen",
    "heart_rate_variability_sdnn": "Heart Rate Variability",
    "walking_heart_rate_average": "Walking Heart Rate",
    "resting_heart_rate": "Resting Heart Rate",
    "environmental_audio_exposure": "Environmental Sound Levels",
    "headphone_audio_exposure": "Headphone Audio Levels",
    "dietary_energy_consumed": "Dietary Energy",
    "dietary_water": "Water",
    "workout": "Workouts",
    "unknown": "Unknown",
}

# Acronyms and unit names. Title-casing these gives "Sdnn" and "Vo2", which read
# as typos.
_UPPERCASE_PARTS = {"sdnn", "vo2", "bmi", "uv", "ecg", "hrv", "spo2", "rr"}
_LOWERCASE_PARTS = {"of", "in", "on", "per", "and", "the"}


def display_name(slug: str) -> str:
    """The name a person would say for a metric slug.

    `heart_rate_variability_sdnn` is an identifier: right for the wire, for a
    dictionary key and for a log line, wrong for a screen.
    """
    if slug in _METRIC_NAMES:
        return _METRIC_NAMES[slug]
    if not slug:
        return "Unknown"

    parts = slug.split("_")
    # "Apple" is branding on the identifier, not part of the measurement's name.
    if len(parts) > 1 and parts[0] == "apple":
        parts = parts[1:]

    words = []
    for index, part in enumerate(parts):
        if part in _UPPERCASE_PARTS:
            words.append(part.upper())
        elif index > 0 and part in _LOWERCASE_PARTS:
            words.append(part)
        else:
            words.append(part[:1].upper() + part[1:])
    return " ".join(words)


class InvalidRange(ValueError):
    """A date the caller supplied could not be parsed."""


def zone(name: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(name or DEFAULT_TZ)
    except Exception:
        return ZoneInfo(DEFAULT_TZ)


def live_records():
    """Excludes tombstones. A deleted sample must never appear in a total."""
    return Record.objects.filter(deleted_at__isnull=True).exclude(kind=Record.Kind.DELETE)


def metric_catalog() -> list[dict]:
    """Every metric present, with enough shape for the UI to pick a chart."""
    rows = (
        live_records()
        .exclude(metric_slug="unknown")
        .values("metric_slug")
        .annotate(
            count=Count("id"),
            unit=Max("unit"),
            aggregation=Max("aggregation"),
            kind=Max("kind"),
            first=Min("start"),
            last=Max("start"),
        )
        .order_by("-count")
    )
    catalog = []
    for row in rows:
        cumulative = row["aggregation"] == "cumulative"
        catalog.append(
            {
                "metric_slug": row["metric_slug"],
                "label": display_name(row["metric_slug"]),
                "count": row["count"],
                "unit": row["unit"] or "",
                "aggregation": row["aggregation"] or "",
                "kind": row["kind"] or "",
                "cumulative": cumulative,
                "default_agg": "sum" if cumulative else "avg",
                "allowed_aggs": sorted(CUMULATIVE_AGGS if cumulative else DISCRETE_AGGS),
                "first_sample": row["first"].isoformat() if row["first"] else None,
                "last_sample": row["last"].isoformat() if row["last"] else None,
            }
        )
    return catalog


def _rollup_series(metric: str, start, end, tz) -> dict[date, float]:
    """Apple-deduplicated daily totals, where the app has shipped them."""
    rows = (
        live_records()
        .filter(kind=Record.Kind.STATISTIC, metric_slug=metric, start__gte=start, start__lt=end)
        .annotate(day=TruncDate("start", tzinfo=tz))
        .values("day")
        .annotate(value=Max("value"))
    )
    return {row["day"]: row["value"] for row in rows if row["value"] is not None}


def _raw_series(metric: str, start, end, tz, agg: str) -> dict[date, float]:
    aggregate = {
        "sum": Sum("value"),
        "avg": Avg("value"),
        "min": Min("value"),
        "max": Max("value"),
        "count": Count("id"),
    }[agg]
    rows = (
        live_records()
        .filter(metric_slug=metric, start__gte=start, start__lt=end)
        .exclude(kind=Record.Kind.STATISTIC)  # never mix rollups into a raw sum
        .annotate(day=TruncDate("start", tzinfo=tz))
        .values("day")
        .annotate(value=aggregate)
    )
    return {row["day"]: row["value"] for row in rows if row["value"] is not None}


def daily_series(
    metric: str,
    start: datetime,
    end: datetime,
    agg: str,
    tz_name: str | None = None,
    prefer_rollups: bool = True,
) -> dict:
    """Daily points for one metric.

    For a `sum` over a cumulative metric, per-day rollups win where they exist
    and a raw sum fills the gaps. Each point says which it was, so the UI can be
    honest about the difference rather than presenting an inflated estimate as
    fact.
    """
    tz = zone(tz_name)
    rollups: dict[date, float] = {}
    if prefer_rollups and agg == "sum":
        rollups = _rollup_series(metric, start, end, tz)

    raw = _raw_series(metric, start, end, tz, agg)

    points = []
    for day in sorted(set(rollups) | set(raw)):
        if day in rollups:
            points.append({"date": day.isoformat(), "value": rollups[day], "source": SOURCE_ROLLUP})
        else:
            points.append({"date": day.isoformat(), "value": raw[day], "source": SOURCE_RAW})

    estimated = sum(1 for p in points if p["source"] == SOURCE_RAW)
    return {
        "metric_slug": metric,
        "aggregation": agg,
        "timezone": str(tz),
        "points": points,
        "rollup_days": len(points) - estimated,
        "estimated_days": estimated,
        # Only cumulative sums can be inflated by cross-device overlap; an
        # average or a min/max over the same samples is unaffected.
        "may_double_count": agg == "sum" and estimated > 0,
    }


def summary(start: datetime, end: datetime, tz_name: str | None = None) -> dict:
    """Headline numbers for the KPI row."""
    tz = zone(tz_name)
    records = live_records().filter(start__gte=start, start__lt=end)

    active_days = (
        records.annotate(day=TruncDate("start", tzinfo=tz)).values("day").distinct().count()
    )
    workouts = records.filter(kind=Record.Kind.WORKOUT)
    workout_seconds = 0
    for extra in workouts.values_list("extra", flat=True):
        if isinstance(extra, dict):
            try:
                workout_seconds += float(extra.get("duration_seconds") or 0)
            except (TypeError, ValueError):
                continue

    return {
        "records_in_range": records.count(),
        "active_days": active_days,
        "workouts": workouts.count(),
        "workout_hours": round(workout_seconds / 3600, 1),
        "metrics_seen": records.values("metric_slug").distinct().count(),
    }


def sleep_hours(start: datetime, end: datetime, tz_name: str | None = None) -> dict:
    """Hours asleep per night.

    Sleep needs its own path: a sleep record's `value` is a category code
    (1 = asleepUnspecified, 4 = asleepREM …), so averaging it produces a number
    with no meaning. The actual duration lives in `extra.duration_seconds`, one
    row per stage interval, which is why this sums rather than averages.

    Bucketed by `end`, not `start`: a night that begins at 23:40 belongs to the
    morning you wake up, which is how anyone reading "Tuesday's sleep" means it.
    `inBed` intervals are excluded — they overlap the asleep ones and would
    roughly double every night.
    """
    tz = zone(tz_name)
    rows = (
        live_records()
        .filter(kind=Record.Kind.SLEEP, end__gte=start, end__lt=end, extra__is_asleep=True)
        .annotate(seconds=Cast(KeyTextTransform("duration_seconds", "extra"), FloatField()))
        .annotate(day=TruncDate("end", tzinfo=tz))
        .values("day")
        .annotate(total=Sum("seconds"))
        .order_by("day")
    )
    points = [
        {"date": row["day"].isoformat(), "value": round(row["total"] / 3600, 2), "source": SOURCE_ROLLUP}
        for row in rows
        if row["total"]
    ]
    return {
        "metric_slug": "sleep_analysis",
        "aggregation": "sum",
        "timezone": str(tz),
        "points": points,
        "rollup_days": len(points),
        "estimated_days": 0,
        # Stage intervals within a night don't overlap, so summing them is exact.
        "may_double_count": False,
    }


def latest_values(metrics: list[str]) -> dict[str, dict]:
    """Most recent reading per metric, for stat tiles."""
    out = {}
    for metric in metrics:
        row = (
            live_records()
            .filter(metric_slug=metric)
            .exclude(kind=Record.Kind.STATISTIC)
            .order_by("-start")
            .values("value", "unit", "start")
            .first()
        )
        if row and row["value"] is not None:
            out[metric] = {
                "value": row["value"],
                "unit": row["unit"] or "",
                "at": row["start"].isoformat() if row["start"] else None,
            }
    return out


def parse_range(from_raw: str | None, to_raw: str | None, default_days: int = 30):
    """Inclusive `to`: the end bound is pushed to the start of the next day so a
    range ending "today" includes today's samples."""
    tz = zone(None)
    today = datetime.now(tz).date()

    def parse(value, fallback):
        if not value:
            return fallback
        try:
            return date.fromisoformat(value)
        except ValueError as exc:
            # Silently substituting a default would answer a question nobody
            # asked, and the caller would believe the numbers apply to the
            # range they typed.
            raise InvalidRange(f"invalid date {value!r}; expected YYYY-MM-DD") from exc

    end_date = parse(to_raw, today)
    start_date = parse(from_raw, end_date - timedelta(days=default_days - 1))
    if start_date > end_date:
        start_date, end_date = end_date, start_date

    start = datetime.combine(start_date, datetime.min.time(), tzinfo=tz)
    end = datetime.combine(end_date + timedelta(days=1), datetime.min.time(), tzinfo=tz)
    return start, end, start_date, end_date
