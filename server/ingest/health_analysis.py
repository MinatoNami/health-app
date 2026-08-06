"""Deterministic health analysis: baselines, trends, and data quality.

Everything an insight rests on is computed here, in ordinary Python, before any
model is involved. The LLM's job is to explain these numbers — not to derive
them from raw rows, which it would do inconsistently and without any way to
check the arithmetic.

Three ideas run through the whole module:

**Personal baselines beat population norms.** A resting heart rate of 62 means
nothing on its own; 62 against a personal baseline of 54 means something. So
every comparison is current-window versus the user's own preceding window.

**Complete days only.** `as_of` defaults to *yesterday*. Today is partial —
half a day of steps against a full-day baseline reads as a collapse in activity
that is really just the clock.

**Coverage is part of the answer.** Every comparison carries how many valid days
it saw and a confidence grade derived from that. A 7-day average built from two
days the watch happened to be worn is not a weekly average, and saying so is the
difference between an insight and a guess.
"""

import statistics
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from django.db.models import Count, Max, Min

from . import analytics, nutrition
from .models import Record

# Confidence grades, weakest first. Ordered so callers can compare.
CONFIDENCE_ORDER = ["insufficient", "low", "moderate", "high"]

# Windows. 7 against the preceding 28 is the shape §4 of the integration notes
# asks for; deliberately *non-overlapping*, because a 7-day mean compared
# against a 28-day mean that contains it dampens exactly the change being
# looked for.
CURRENT_DAYS = 7
BASELINE_DAYS = 28


@dataclass(frozen=True)
class MetricSpec:
    """What one metric needs to be summarised honestly.

    `daily` is how a day is reduced, and it is not a style choice: summing
    instantaneous heart-rate readings is meaningless, and averaging step samples
    answers a question nobody asked.

    `direction` records which way is generally better *for wellness framing
    only*. It never implies a clinical judgement — a resting heart rate above
    baseline is reported as above baseline, not as a problem.
    """

    slug: str
    label: str
    unit: str
    daily: str  # "sum" | "avg"
    direction: str  # "higher_better" | "lower_better" | "neutral"
    decimals: int = 0
    # Weight is stepped on a few times a week at best; the watch writes resting
    # heart rate nightly. The same "3 valid days" bar would call one unusable
    # and the other fine, so the bar is per metric.
    min_current_days: int = 3
    min_baseline_days: int = 7
    # Days the metric is genuinely expected on. Coverage of a metric recorded
    # twice a week should not be scored against a daily denominator.
    expected_cadence: float = 1.0
    # Written down by a person rather than measured by a sensor — a food diary,
    # not a watch. Three things follow, and all three are wrong for a sensor:
    # a gap means "not recorded", never "none consumed"; HealthKit's
    # user-entered flag is a tautology rather than a warning; and nobody should
    # be alerted that they stopped keeping a diary.
    self_reported: bool = False


# Nutrition, derived from the nutrient catalog rather than restated here: the
# canonical unit for each nutrient is a fact about the nutrient, and keeping a
# second copy of "vitamin C is reported in mg" is how the two drift apart.
#
# `min_baseline_days` is lower than a sensor's. Food logging starts the day
# somebody installs a food app, so the first month of a diary has a full current
# window and an empty baseline — and the honest answer to that is a comparison
# graded thin, not no comparison at all.
_NUTRITION_SPECS = [
    MetricSpec(
        n.slug,
        n.label,
        n.unit,
        "sum",
        n.direction,
        decimals=n.decimals,
        min_baseline_days=5,
        self_reported=True,
    )
    for n in nutrition.headline_nutrients()
]


METRICS: dict[str, MetricSpec] = {
    spec.slug: spec
    for spec in [
        # The five high-value signals from §14 of the integration notes.
        MetricSpec("step_count", "Steps", "count", "sum", "higher_better"),
        MetricSpec("sleep_analysis", "Sleep duration", "h", "sum", "higher_better", decimals=2),
        MetricSpec("resting_heart_rate", "Resting heart rate", "count/min", "avg", "lower_better"),
        MetricSpec("apple_exercise_time", "Exercise minutes", "min", "sum", "higher_better"),
        MetricSpec(
            "body_mass", "Weight", "kg", "avg", "neutral",
            decimals=1, min_current_days=2, min_baseline_days=4, expected_cadence=0.4,
        ),
        # Secondary, once the five above are reliable.
        MetricSpec("active_energy_burned", "Active energy", "kcal", "sum", "higher_better"),
        MetricSpec(
            "heart_rate_variability_sdnn", "Heart-rate variability", "ms", "avg",
            "higher_better", decimals=1,
        ),
        MetricSpec("respiratory_rate", "Respiratory rate", "count/min", "avg", "neutral", decimals=1),
        MetricSpec("oxygen_saturation", "Blood oxygen", "%", "avg", "neutral", decimals=1),
        MetricSpec(
            "walking_heart_rate_average", "Walking heart rate", "count/min", "avg", "lower_better"
        ),
        MetricSpec(
            "body_fat_percentage", "Body fat", "%", "avg", "neutral",
            decimals=1, min_current_days=2, min_baseline_days=4, expected_cadence=0.3,
        ),
        MetricSpec("distance_walking_running", "Walking + running distance", "km", "sum", "higher_better", decimals=2),
        MetricSpec("heart_rate", "Heart rate", "count/min", "avg", "neutral"),
    ]
    + _NUTRITION_SPECS
}

# What a snapshot leads with, in order. Short on purpose: six numbers someone
# reads beats thirteen they skim.
SNAPSHOT_METRICS = [
    "step_count",
    "sleep_analysis",
    "resting_heart_rate",
    "apple_exercise_time",
    "heart_rate_variability_sdnn",
    "body_mass",
]


class UnknownMetric(ValueError):
    """The caller asked for a metric this module has no spec for."""


def spec_for(slug: str) -> MetricSpec:
    try:
        return METRICS[slug]
    except KeyError as exc:
        raise UnknownMetric(
            f"unknown metric {slug!r}; known metrics: {', '.join(sorted(METRICS))}"
        ) from exc


# --------------------------------------------------------------------------
# Day series
# --------------------------------------------------------------------------


@dataclass
class DayValue:
    day: date
    value: float
    # True when the day was summed from raw samples rather than an
    # Apple-deduplicated rollup, so it may read high. Carried all the way to the
    # answer: a trend built mostly from estimates is a weaker claim.
    #
    # Only ever set for cumulative metrics. Averaging the same heart-rate
    # readings twice gives the same average, so "estimated" on a discrete metric
    # is not a weaker number — it is a false caveat, and one the model will
    # dutifully repeat back as a limitation that does not exist.
    estimated: bool


def today(tz_name: str | None = None) -> date:
    return datetime.now(analytics.zone(tz_name)).date()


def last_complete_day(tz_name: str | None = None) -> date:
    """Yesterday, locally.

    Today's numbers are partial by definition, and a partial day silently
    dragging an average down is the most common way a health summary lies.
    """
    return today(tz_name) - timedelta(days=1)


def _bounds(start_day: date, end_day: date, tz_name: str | None):
    tz = analytics.zone(tz_name)
    start = datetime.combine(start_day, datetime.min.time(), tzinfo=tz)
    end = datetime.combine(end_day + timedelta(days=1), datetime.min.time(), tzinfo=tz)
    return start, end


def day_values(
    slug: str, start_day: date, end_day: date, tz_name: str | None = None
) -> list[DayValue]:
    """One value per day that has data, inclusive of both ends.

    Delegates to the same aggregation the dashboard renders — Apple's
    deduplicated rollups preferred over raw sums, sleep summed from stage
    durations — so a number quoted in an insight and the same number on a chart
    can never disagree.
    """
    spec = spec_for(slug)
    start, end = _bounds(start_day, end_day, tz_name)

    if slug == "sleep_analysis":
        payload = analytics.sleep_hours(start, end, tz_name)
    elif nutrition.is_nutrient(slug):
        # Nutrients need their own path for two reasons. Their rows do not agree
        # on a unit — the same nutrient arrives in kg from one HealthKit type and
        # g from another, so summing that in SQL is a number a thousand times
        # wrong. And a day whose food log was abandoned halfway is a partial
        # recording: it is dropped here rather than averaged, for the same reason
        # today is left out of every window.
        payload = nutrition.daily_series(
            slug,
            start,
            end,
            tz_name=tz_name,
            only_days=nutrition.complete_log_days(start, end, tz_name),
        )
    else:
        payload = analytics.daily_series(slug, start, end, spec.daily, tz_name=tz_name)

    # Cross-source overlap only inflates a *sum*. `daily_series` marks every day
    # without an Apple rollup as raw, and for an average metric that is every
    # day — reporting those as estimates would put a caveat on the majority of
    # the data that is not true of any of it.
    inflatable = spec.daily == "sum"

    out = []
    for point in payload["points"]:
        if point["value"] is None:
            continue
        out.append(
            DayValue(
                day=date.fromisoformat(point["date"]),
                value=float(point["value"]),
                estimated=inflatable and point.get("source") == analytics.SOURCE_RAW,
            )
        )
    out.sort(key=lambda d: d.day)
    return out


# --------------------------------------------------------------------------
# Confidence
# --------------------------------------------------------------------------


def _coverage(valid_days: int, window_days: int, cadence: float) -> float:
    expected = max(1.0, window_days * cadence)
    return min(1.0, valid_days / expected)


def grade_confidence(
    spec: MetricSpec,
    current: list[DayValue],
    baseline: list[DayValue],
    current_days: int,
    baseline_days: int,
    manual_fraction: float = 0.0,
) -> tuple[str, str]:
    """Returns (grade, one-line reason).

    The reason matters as much as the grade: "moderate" with no explanation is
    a number the reader has to trust, while "moderate — 4 of 7 days have data"
    is one they can check.
    """
    # "4 of 7 days have data" and "4 of 7 days were logged" grade the same and
    # mean different things. A watch with three missing days is a watch left in a
    # drawer; a diary with three missing days is three days nobody wrote down,
    # and the reader can only act on the second if it says so.
    have = "were logged" if spec.self_reported else "have data"

    if len(current) < spec.min_current_days:
        return "insufficient", (
            f"only {len(current)} day(s) of {spec.label.lower()} "
            f"{'logged' if spec.self_reported else 'recorded'} in the current window; "
            f"at least {spec.min_current_days} are needed"
        )
    if len(baseline) < spec.min_baseline_days:
        return "insufficient", (
            f"only {len(baseline)} day(s) of baseline data; "
            f"at least {spec.min_baseline_days} are needed"
        )

    current_coverage = _coverage(len(current), current_days, spec.expected_cadence)
    baseline_coverage = _coverage(len(baseline), baseline_days, spec.expected_cadence)
    coverage = min(current_coverage, baseline_coverage)
    estimated = sum(1 for d in current + baseline if d.estimated) / max(
        1, len(current) + len(baseline)
    )

    if manual_fraction > 0.5:
        return "low", f"{manual_fraction:.0%} of samples were entered by hand rather than measured"
    if coverage < 0.5:
        return "low", (
            f"{len(current)} of {current_days} current days and "
            f"{len(baseline)} of {baseline_days} baseline days {have}"
        )
    if coverage < 0.8:
        return "moderate", (
            f"{len(current)} of {current_days} current days and "
            f"{len(baseline)} of {baseline_days} baseline days {have}"
        )
    if estimated > 0.5:
        return "moderate", (
            f"{estimated:.0%} of days are summed from raw samples rather than "
            "Apple's deduplicated totals, so they may read high"
        )
    return "high", f"{len(current)} of {current_days} current days {have}"


def _robust_spread(values: list[float]) -> float:
    """Median absolute deviation, scaled to be comparable with a standard
    deviation. Robust because one holiday or one missed night should not widen
    the band enough to hide a real shift."""
    if len(values) < 3:
        return 0.0
    median = statistics.median(values)
    mad = statistics.median([abs(v - median) for v in values])
    return mad * 1.4826


def classify_change(delta: float, baseline_values: list[float]) -> str:
    """How much of a change this is against the user's own variability.

    A 300-step move is noise for someone whose daily count swings by 4,000 and
    a real shift for someone who walks the same route every day. Comparing
    against a fixed percentage would get both wrong.
    """
    spread = _robust_spread(baseline_values)
    if spread <= 0:
        # No usable spread — fall back to a relative test so the answer is not
        # simply "stable" for everything.
        median = abs(statistics.median(baseline_values)) if baseline_values else 0.0
        if median == 0:
            return "unclear"
        ratio = abs(delta) / median
        return "notable" if ratio >= 0.15 else "slight" if ratio >= 0.05 else "stable"

    z = abs(delta) / spread
    if z >= 1.0:
        return "notable"
    if z >= 0.5:
        return "slight"
    return "stable"


# --------------------------------------------------------------------------
# Baseline comparison
# --------------------------------------------------------------------------


def _round(value: float | None, decimals: int) -> float | None:
    if value is None:
        return None
    return round(value, decimals) if decimals else round(value)


def compare_to_baseline(
    slug: str,
    as_of: date | None = None,
    current_days: int = CURRENT_DAYS,
    baseline_days: int = BASELINE_DAYS,
    tz_name: str | None = None,
) -> dict:
    """Current window against the user's own preceding window.

    The two windows do not overlap, so "8% above baseline" means the last seven
    days really were 8% above the twenty-eight before them.
    """
    spec = spec_for(slug)
    as_of = as_of or last_complete_day(tz_name)

    current_from = as_of - timedelta(days=current_days - 1)
    baseline_to = current_from - timedelta(days=1)
    baseline_from = baseline_to - timedelta(days=baseline_days - 1)

    series = day_values(slug, baseline_from, as_of, tz_name)
    current = [d for d in series if d.day >= current_from]
    baseline = [d for d in series if d.day <= baseline_to]

    # For a food diary, "entered by hand" is not a warning — it is the only way
    # the data could exist. Applying the sensor rule would pin every nutrient at
    # "low" for ever and say nothing the reader did not already know.
    manual_fraction = (
        0.0 if spec.self_reported else _manual_fraction(slug, baseline_from, as_of, tz_name)
    )
    grade, reason = grade_confidence(
        spec, current, baseline, current_days, baseline_days, manual_fraction
    )

    current_value = statistics.fmean([d.value for d in current]) if current else None
    baseline_value = statistics.fmean([d.value for d in baseline]) if baseline else None

    delta = change_pct = None
    significance = "unclear"
    if current_value is not None and baseline_value is not None:
        delta = current_value - baseline_value
        change_pct = (delta / baseline_value * 100) if baseline_value else None
        if grade != "insufficient":
            significance = classify_change(delta, [d.value for d in baseline])

    return {
        "metric_slug": slug,
        "label": spec.label,
        "unit": spec.unit,
        "daily_aggregation": spec.daily,
        "direction": spec.direction,
        "current": {
            "value": _round(current_value, spec.decimals),
            "from": current_from.isoformat(),
            "to": as_of.isoformat(),
            "valid_days": len(current),
            "window_days": current_days,
            # Scored against how often the metric is *expected*, not against
            # every calendar day. Weight measured three times in a week is full
            # coverage for weight; scoring it 3/7 marks normal behaviour as a
            # data problem.
            "coverage": round(_coverage(len(current), current_days, spec.expected_cadence), 2),
        },
        "baseline": {
            "value": _round(baseline_value, spec.decimals),
            "from": baseline_from.isoformat(),
            "to": baseline_to.isoformat(),
            "valid_days": len(baseline),
            "window_days": baseline_days,
            "coverage": round(_coverage(len(baseline), baseline_days, spec.expected_cadence), 2),
        },
        "expected_cadence": spec.expected_cadence,
        "change": _round(delta, spec.decimals),
        "change_pct": round(change_pct, 1) if change_pct is not None else None,
        # "notable" is a statement about this person's own variability, not a
        # clinical threshold.
        "significance": significance,
        "confidence": grade,
        "confidence_reason": reason,
        "estimated_days": sum(1 for d in series if d.estimated),
    }


# --------------------------------------------------------------------------
# Trend
# --------------------------------------------------------------------------


def _moving_average(series: list[DayValue], window: int) -> list[dict]:
    """Trailing average over calendar days, not over the last N *present* days.

    Averaging the last seven recorded values when only three days were recorded
    silently stretches a week into a fortnight, which is how a "7-day average"
    ends up describing a period nobody asked about.
    """
    by_day = {d.day: d.value for d in series}
    out = []
    for point in series:
        window_days = [
            by_day[point.day - timedelta(days=offset)]
            for offset in range(window)
            if point.day - timedelta(days=offset) in by_day
        ]
        # Half the window has to be present, otherwise the "average" is a
        # single day wearing a longer label.
        if len(window_days) * 2 >= window:
            out.append({"date": point.day.isoformat(), "value": statistics.fmean(window_days)})
    return out


def _linear_slope(series: list[DayValue]) -> tuple[float | None, float | None]:
    """Least-squares slope per day, plus r² so a caller can tell a trend from a
    line drawn through noise."""
    if len(series) < 4:
        return None, None
    origin = series[0].day
    xs = [(d.day - origin).days for d in series]
    ys = [d.value for d in series]
    mean_x = statistics.fmean(xs)
    mean_y = statistics.fmean(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx == 0:
        return None, None
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    slope = sxy / sxx
    syy = sum((y - mean_y) ** 2 for y in ys)
    r2 = (sxy**2 / (sxx * syy)) if syy > 0 else None
    return slope, r2


def trend(
    slug: str,
    days: int = 90,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """Daily points, 7- and 28-day moving averages, week-over-week, and slope."""
    spec = spec_for(slug)
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)
    series = day_values(slug, start_day, as_of, tz_name)

    slope, r2 = _linear_slope(series)
    week = [d.value for d in series if d.day > as_of - timedelta(days=7)]
    prior = [
        d.value
        for d in series
        if as_of - timedelta(days=14) < d.day <= as_of - timedelta(days=7)
    ]
    week_over_week = None
    if week and prior:
        week_over_week = statistics.fmean(week) - statistics.fmean(prior)

    # A slope is only worth stating if the line explains a real share of the
    # variation. Below that it is a direction fitted to noise, and quoting it
    # invites a story about a change that did not happen.
    direction = "unclear"
    if slope is not None and r2 is not None and len(series) >= 14:
        if r2 < 0.15:
            direction = "flat"
        elif slope > 0:
            direction = "rising"
        else:
            direction = "falling"

    return {
        "metric_slug": slug,
        "label": spec.label,
        "unit": spec.unit,
        "from": start_day.isoformat(),
        "to": as_of.isoformat(),
        "points": [
            {"date": d.day.isoformat(), "value": _round(d.value, spec.decimals),
             "estimated": d.estimated}
            for d in series
        ],
        "moving_average_7": [
            {"date": p["date"], "value": _round(p["value"], spec.decimals)}
            for p in _moving_average(series, 7)
        ],
        "moving_average_28": [
            {"date": p["date"], "value": _round(p["value"], spec.decimals)}
            for p in _moving_average(series, 28)
        ],
        "week_over_week_change": _round(week_over_week, spec.decimals),
        "slope_per_week": _round(slope * 7, spec.decimals + 2) if slope is not None else None,
        "fit_quality": round(r2, 2) if r2 is not None else None,
        "trend_direction": direction,
        "valid_days": len(series),
        "window_days": days,
    }


def streak(slug: str, target: float, as_of: date | None = None, tz_name: str | None = None) -> dict:
    """Consecutive complete days at or above `target`, counting back from
    `as_of`. Days with no data break the streak rather than being skipped —
    treating missing data as a met goal is exactly the failure mode §7 warns
    about."""
    spec = spec_for(slug)
    as_of = as_of or last_complete_day(tz_name)
    series = {d.day: d.value for d in day_values(slug, as_of - timedelta(days=180), as_of, tz_name)}

    current = 0
    day = as_of
    while day in series and series[day] >= target:
        current += 1
        day -= timedelta(days=1)

    longest = run = 0
    for offset in range(180, -1, -1):
        probe = as_of - timedelta(days=offset)
        if probe in series and series[probe] >= target:
            run += 1
            longest = max(longest, run)
        else:
            run = 0

    return {
        "metric_slug": slug,
        "label": spec.label,
        "target": target,
        "unit": spec.unit,
        "current_streak_days": current,
        "longest_streak_days": longest,
        "as_of": as_of.isoformat(),
    }


# --------------------------------------------------------------------------
# Data quality
# --------------------------------------------------------------------------


def _records(slug: str, start_day: date, end_day: date, tz_name: str | None):
    start, end = _bounds(start_day, end_day, tz_name)
    return (
        analytics.live_records()
        .filter(metric_slug=slug, start__gte=start, start__lt=end)
        .exclude(kind=Record.Kind.STATISTIC)
    )


def _manual_fraction(slug: str, start_day: date, end_day: date, tz_name: str | None) -> float:
    """Share of samples HealthKit flagged as typed in rather than measured.

    Manual entries are not wrong, but they are a different measurement method,
    and a weight "trend" made of three hand-typed numbers is not the same claim
    as one made of thirty scale readings.
    """
    qs = _records(slug, start_day, end_day, tz_name)
    total = qs.count()
    if not total:
        return 0.0
    manual = qs.filter(metadata__HKWasUserEntered=True).count()
    return manual / total


def data_quality(
    slug: str,
    days: int = BASELINE_DAYS + CURRENT_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """What can and cannot be concluded from this metric's recent data.

    §13 of the integration notes lists why HealthKit data misleads — watch not
    worn, multiple devices writing the same metric, manual entry, delayed sync.
    This is the machine-readable version of that list, so an insight can carry
    its own caveats rather than relying on the model to invent them.
    """
    spec = spec_for(slug)
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)

    series = day_values(slug, start_day, as_of, tz_name)
    qs = _records(slug, start_day, as_of, tz_name)

    total_samples = qs.count()
    manual = qs.filter(metadata__HKWasUserEntered=True).count() if total_samples else 0
    sources = [
        {"name": row["source_name"] or "unknown", "samples": row["count"]}
        for row in qs.values("source_name").annotate(count=Count("id")).order_by("-count")[:8]
    ]
    devices = sorted(
        {row for row in qs.values_list("source_product_type", flat=True).distinct() if row}
    )

    present = {d.day for d in series}
    missing = [
        (start_day + timedelta(days=offset)).isoformat()
        for offset in range(days)
        if start_day + timedelta(days=offset) not in present
    ]

    longest_gap = gap = 0
    for offset in range(days):
        if start_day + timedelta(days=offset) in present:
            gap = 0
        else:
            gap += 1
            longest_gap = max(longest_gap, gap)

    latest = qs.aggregate(latest=Max("start"), earliest=Min("start"))
    coverage = _coverage(len(series), days, spec.expected_cadence)
    estimated = sum(1 for d in series if d.estimated)

    notes = []
    if spec.self_reported:
        # Leads, because it changes how every other number here should be read.
        notes.append(
            f"{spec.label} is self-reported: these are the amounts written down in a food "
            f"app, not measured. Days with no entry mean nothing was logged, which is not "
            f"the same as nothing consumed, and anything eaten but not logged is missing "
            f"from every total."
        )
    if len(sources) > 1 and spec.daily == "sum":
        notes.append(
            f"{len(sources)} sources write this metric. Days without an Apple rollup are "
            "summed from raw samples and can double-count."
        )
    if estimated:
        notes.append(
            f"{estimated} of {len(series)} day(s) are estimated from raw samples rather than "
            "Apple's deduplicated daily totals."
        )
    if manual and total_samples and not spec.self_reported:
        notes.append(
            f"{manual / total_samples:.0%} of samples were entered by hand, not measured by a device."
        )
    if longest_gap >= 3:
        notes.append(f"Longest run of days with no data: {longest_gap}.")
    if len(devices) > 1:
        notes.append(
            "More than one device model recorded this metric; sensor behaviour can differ "
            f"between them ({', '.join(devices)})."
        )

    hand_typed = bool(total_samples) and not spec.self_reported and manual / total_samples > 0.5
    if coverage < 0.3 or len(series) < spec.min_current_days:
        classification = "insufficient"
    elif coverage < 0.6 or hand_typed:
        classification = "low"
    elif coverage < 0.85 or estimated > len(series) / 2:
        classification = "moderate"
    else:
        classification = "high"

    return {
        "metric_slug": slug,
        "label": spec.label,
        "from": start_day.isoformat(),
        "to": as_of.isoformat(),
        "window_days": days,
        "valid_days": len(series),
        "coverage": round(coverage, 2),
        "estimated_days": estimated,
        "samples": total_samples,
        "manual_samples": manual,
        "sources": sources,
        "device_models": devices,
        "missing_days": missing[:40],
        "longest_gap_days": longest_gap,
        "earliest_sample_at": latest["earliest"].isoformat() if latest["earliest"] else None,
        "latest_sample_at": latest["latest"].isoformat() if latest["latest"] else None,
        "quality": classification,
        "notes": notes,
    }


def comparable(slug: str, *reports: dict) -> bool:
    """Whether two periods have enough coverage to be compared at all.

    §13: "avoid comparing two periods unless both have sufficient coverage."
    Returning a percentage change between a full week and a two-day week is
    worse than returning nothing.
    """
    return all(r["quality"] not in ("insufficient", "low") for r in reports)


# --------------------------------------------------------------------------
# Sleep
# --------------------------------------------------------------------------


def _minutes_since_noon(moment: datetime) -> float:
    """Bedtimes straddle midnight, so clock minutes wrap and averaging 23:50
    with 00:10 gives lunchtime. Measuring from noon puts a normal night on one
    continuous scale."""
    minutes = moment.hour * 60 + moment.minute + moment.second / 60
    return minutes - 720 if minutes >= 720 else minutes + 720


def _clock(minutes_since_noon: float) -> str:
    total = (minutes_since_noon + 720) % 1440
    return f"{int(total // 60):02d}:{int(total % 60):02d}"


def _sleep_nights(start_day: date, end_day: date, tz_name: str | None) -> dict[date, dict]:
    """One entry per night, keyed by the morning it ended on.

    Bucketed by `end`, because a night beginning at 23:40 belongs to the morning
    it ends — which is what anyone means by "Tuesday's sleep". Shared by the
    summary and by `bedtime_series`: the bucketing is the part that is easy to get
    subtly wrong and expensive to get wrong twice.
    """
    tz = analytics.zone(tz_name)
    start, end = _bounds(start_day, end_day, tz_name)
    rows = (
        analytics.live_records()
        .filter(kind=Record.Kind.SLEEP, end__gte=start, end__lt=end, extra__is_asleep=True)
        .values("start", "end", "extra", "source_name")
    )

    nights: dict[date, dict] = {}
    for row in rows:
        if not row["start"] or not row["end"]:
            continue
        local_start = row["start"].astimezone(tz)
        local_end = row["end"].astimezone(tz)
        night = local_end.date()
        entry = nights.setdefault(
            night, {"seconds": 0.0, "first": local_start, "last": local_end, "sources": set()}
        )
        try:
            entry["seconds"] += float((row["extra"] or {}).get("duration_seconds") or 0)
        except (TypeError, ValueError):
            pass
        entry["first"] = min(entry["first"], local_start)
        entry["last"] = max(entry["last"], local_end)
        if row["source_name"]:
            entry["sources"].add(row["source_name"])
    return nights


def bedtime_series(
    days: int, as_of: date | None = None, tz_name: str | None = None
) -> dict[date, float]:
    """Bedtime per morning, in minutes since noon.

    Minutes since noon rather than clock time so the numbers stay on one
    continuous scale across midnight — a series where 23:50 is 1430 and 00:10 is
    10 would correlate against nothing but its own wrap-around.

    Keyed by the morning, matching how `sleep_analysis` day values are bucketed,
    so the two line up day for day without a lag.
    """
    as_of = as_of or last_complete_day(tz_name)
    nights = _sleep_nights(as_of - timedelta(days=days - 1), as_of, tz_name)
    return {night: _minutes_since_noon(entry["first"]) for night, entry in nights.items()}


def workout_minutes_series(
    days: int, as_of: date | None = None, tz_name: str | None = None
) -> dict[date, float]:
    """Recorded workout minutes per day, zero-filled across the window.

    Zero-filled on purpose, and it is the opposite of the rule everywhere else
    here: a day with no workout record really is a day with no workout, because
    the phone uploads workouts whenever they happen rather than on a schedule.
    Treating those as missing would compare hard days only against other hard
    days and find nothing.
    """
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)
    tz = analytics.zone(tz_name)
    start, end = _bounds(start_day, as_of, tz_name)

    minutes = {
        start_day + timedelta(days=offset): 0.0 for offset in range((as_of - start_day).days + 1)
    }
    rows = (
        analytics.live_records()
        .filter(kind=Record.Kind.WORKOUT, start__gte=start, start__lt=end)
        .values("start", "extra")
    )
    for row in rows:
        if not row["start"]:
            continue
        extra = row["extra"] if isinstance(row["extra"], dict) else {}
        try:
            seconds = float(extra.get("duration_seconds") or 0)
        except (TypeError, ValueError):
            continue
        day = row["start"].astimezone(tz).date()
        if day in minutes:
            minutes[day] += seconds / 60
    return minutes


def sleep_summary(
    days: int = CURRENT_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """Duration, typical bedtime and wake time, and consistency.

    Consistency is the spread of the sleep *midpoint*, which is the part of a
    sleep schedule that actually shifts: someone can sleep seven hours every
    night and still be all over the place about when.
    """
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)
    nights = _sleep_nights(start_day, as_of, tz_name)

    detail = []
    for night in sorted(nights):
        entry = nights[night]
        bedtime = _minutes_since_noon(entry["first"])
        wake = entry["last"].hour * 60 + entry["last"].minute
        detail.append(
            {
                "night_of": (night - timedelta(days=1)).isoformat(),
                "morning_of": night.isoformat(),
                "hours_asleep": round(entry["seconds"] / 3600, 2),
                "bedtime": _clock(bedtime),
                "wake_time": entry["last"].strftime("%H:%M"),
                "_bedtime_minutes": bedtime,
                "_midpoint_minutes": bedtime + (entry["seconds"] / 60) / 2,
                "_wake_minutes": wake,
                "sources": sorted(entry["sources"]),
            }
        )

    hours = [d["hours_asleep"] for d in detail if d["hours_asleep"] > 0]
    bedtimes = [d["_bedtime_minutes"] for d in detail]
    midpoints = [d["_midpoint_minutes"] for d in detail]
    wakes = [d["_wake_minutes"] for d in detail]

    consistency_minutes = round(statistics.pstdev(midpoints)) if len(midpoints) >= 3 else None
    if consistency_minutes is None:
        consistency = "unknown"
    elif consistency_minutes <= 30:
        consistency = "very consistent"
    elif consistency_minutes <= 60:
        consistency = "fairly consistent"
    elif consistency_minutes <= 90:
        consistency = "variable"
    else:
        consistency = "highly variable"

    for entry in detail:
        for key in ("_bedtime_minutes", "_midpoint_minutes", "_wake_minutes"):
            entry.pop(key)

    quality = data_quality("sleep_analysis", days=days, as_of=as_of, tz_name=tz_name)

    return {
        "from": start_day.isoformat(),
        "to": as_of.isoformat(),
        "nights_recorded": len(detail),
        "window_days": days,
        "average_hours": round(statistics.fmean(hours), 2) if hours else None,
        "shortest_hours": round(min(hours), 2) if hours else None,
        "longest_hours": round(max(hours), 2) if hours else None,
        "typical_bedtime": _clock(statistics.fmean(bedtimes)) if bedtimes else None,
        "typical_wake_time": (
            f"{int(statistics.fmean(wakes) // 60):02d}:{int(statistics.fmean(wakes) % 60):02d}"
            if wakes
            else None
        ),
        "midpoint_spread_minutes": consistency_minutes,
        "consistency": consistency,
        "nights": detail,
        "data_quality": quality["quality"],
        "limitations": quality["notes"],
    }


# --------------------------------------------------------------------------
# Workouts
# --------------------------------------------------------------------------


def workouts(
    days: int = BASELINE_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
    limit: int = 20,
) -> dict:
    """Recent sessions and how often they happen.

    Energy figures are carried through as HealthKit reported them and labelled
    as estimates — a wearable's calorie number is a model output, not a
    measurement, and presenting it as exact is on the prohibited list in §7.
    """
    tz = analytics.zone(tz_name)
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)
    start, end = _bounds(start_day, as_of, tz_name)

    rows = (
        analytics.live_records()
        .filter(kind=Record.Kind.WORKOUT, start__gte=start, start__lt=end)
        .order_by("-start")
        .values("start", "end", "extra", "source_name")
    )

    sessions = []
    total_seconds = 0.0
    by_activity: dict[str, dict] = {}
    for row in rows:
        extra = row["extra"] if isinstance(row["extra"], dict) else {}
        try:
            seconds = float(extra.get("duration_seconds") or 0)
        except (TypeError, ValueError):
            seconds = 0.0
        activity = str(extra.get("activity_name") or "Workout")
        total_seconds += seconds
        bucket = by_activity.setdefault(activity, {"sessions": 0, "minutes": 0.0})
        bucket["sessions"] += 1
        bucket["minutes"] += seconds / 60

        if len(sessions) < limit:
            energy = extra.get("active_energy_kcal")
            distance = extra.get("distance_m")
            sessions.append(
                {
                    "started_at": row["start"].astimezone(tz).isoformat() if row["start"] else None,
                    "activity": activity,
                    "minutes": round(seconds / 60, 1),
                    "active_energy_kcal_estimated": round(float(energy), 1)
                    if isinstance(energy, (int, float))
                    else None,
                    "distance_km": round(float(distance) / 1000, 2)
                    if isinstance(distance, (int, float))
                    else None,
                    "source": row["source_name"] or "unknown",
                }
            )

    count = len(rows)
    return {
        "from": start_day.isoformat(),
        "to": as_of.isoformat(),
        "window_days": days,
        "total_workouts": count,
        "per_week": round(count / (days / 7), 1) if days else None,
        "total_minutes": round(total_seconds / 60),
        "by_activity": [
            {"activity": name, "sessions": v["sessions"], "minutes": round(v["minutes"])}
            for name, v in sorted(by_activity.items(), key=lambda kv: -kv[1]["sessions"])
        ],
        "recent": sessions,
        "note": "Active energy is HealthKit's estimate, not a measurement.",
    }


# --------------------------------------------------------------------------
# Nutrition
# --------------------------------------------------------------------------


def _kcal_by_day(slug: str, start, end, tz_name: str | None) -> dict[date, float]:
    payload = analytics.daily_series(slug, start, end, "sum", tz_name=tz_name)
    return {
        date.fromisoformat(p["date"]): float(p["value"])
        for p in payload["points"]
        if p["value"] is not None
    }


def _energy_balance(
    days_wanted: list[date],
    intake: dict[date, float],
    start,
    end,
    tz_name: str | None,
) -> dict:
    """Logged intake against estimated expenditure, on the same days.

    The same days is the whole trick. Comparing five logged days of intake
    against a month's average expenditure produces a deficit or a surplus out of
    a mismatch in the windows, and it is the sort of number that looks like an
    answer.

    Resting energy is included because leaving it out is not a smaller claim, it
    is a wrong one: active energy alone is a few hundred kilocalories, so intake
    would tower over "expenditure" every single day.
    """
    active = _kcal_by_day("active_energy_burned", start, end, tz_name)
    basal = _kcal_by_day("basal_energy_burned", start, end, tz_name)

    # Both halves are required. A day with active energy and no resting figure
    # would understate expenditure by most of it.
    usable = [d for d in days_wanted if d in intake and d in active and d in basal]

    # Worth being blunt about, because the difference between two estimates is
    # the number in this payload most likely to be quoted as though it were
    # measured. Resting energy is a formula over age, sex, height and weight —
    # Apple's runs generously — and logged intake is portion sizes somebody eyed.
    # Subtracting one from the other stacks both errors into a single figure.
    note = (
        "Expenditure is HealthKit's estimate of resting plus active energy, not a "
        "measurement: the resting part is calculated from body metrics rather than "
        "observed, and it tends to read high. Intake is what was written down, from "
        "estimated portions. The difference between the two therefore carries both "
        "errors and is a direction at best. Measured weight over the same period is "
        "the better evidence about whether intake matches need."
    )
    if not usable:
        return {
            "days_compared": 0,
            "intake_kcal_per_day": None,
            "expenditure_kcal_per_day": None,
            "difference_kcal_per_day": None,
            "reason": (
                "No day in this window has both a full food log and a complete "
                "energy-burned record, so intake and expenditure cannot be put "
                "side by side."
            ),
            "note": note,
        }

    intake_mean = statistics.fmean([intake[d] for d in usable])
    active_mean = statistics.fmean([active[d] for d in usable])
    basal_mean = statistics.fmean([basal[d] for d in usable])
    return {
        "days_compared": len(usable),
        "from": min(usable).isoformat(),
        "to": max(usable).isoformat(),
        "intake_kcal_per_day": round(intake_mean),
        "expenditure_kcal_per_day": round(active_mean + basal_mean),
        "active_kcal_per_day_estimated": round(active_mean),
        "resting_kcal_per_day_estimated": round(basal_mean),
        "difference_kcal_per_day": round(intake_mean - (active_mean + basal_mean)),
        "note": note,
    }


def _weight_context(as_of: date, tz_name: str | None) -> dict | None:
    """Measured weight over the recent past, reported beside the energy figures.

    It is here as the empirical check on the arithmetic above. Intake and
    expenditure are both estimates, and their difference is quoted in kilocalories
    as though it settled something; weight is the one number in this comparison
    that a device actually measured. A weight that has not moved over eight weeks
    says intake and need are matching, whatever subtracting two estimates
    suggests.
    """
    report = trend("body_mass", days=56, as_of=as_of, tz_name=tz_name)
    if report["valid_days"] < 4:
        return None
    context = {
        "metric_slug": "body_mass",
        "unit": report["unit"],
        "from": report["from"],
        "to": report["to"],
        "direction": report["trend_direction"],
        "kg_per_week": report["slope_per_week"],
        "fit_quality": report["fit_quality"],
        "weighings": report["valid_days"],
        "note": (
            "Weight is measured rather than calculated, so it is better evidence about "
            "whether intake matches need than the difference between two estimated "
            "energy figures. It also moves with hydration, glycogen and food in transit, "
            "so a single week of it says little."
        ),
    }
    if context["direction"] == "unclear":
        # A slope with no direction beside it is the worst of both: the number
        # reads as a finding while the field that would qualify it says nothing.
        context["direction_reason"] = (
            f"{report['valid_days']} weighing(s) over {report['window_days']} days is too "
            "few for this module to call a direction. The fitted slope is given for "
            "context and is not a trend."
        )
    return context


def nutrition_summary(
    days: int = CURRENT_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """What was logged over the window, and what it can and cannot support.

    Three counts do most of the work here, and they are deliberately separate:
    days with a full log, days with a partial log, and days with nothing logged
    at all. Collapsed into one "days with data" figure — which is how every other
    metric in this module is scored — a fortnight containing four abandoned
    breakfasts reads as a fortnight of barely eating.

    Averages are taken over fully logged days only, and every one of them says
    how many days it came from.
    """
    as_of = as_of or last_complete_day(tz_name)
    start_day = as_of - timedelta(days=days - 1)
    start, end = _bounds(start_day, as_of, tz_name)

    # Only nutrients this person has ever logged. Reporting forty nutrients as
    # "no data" costs forty queries to say nothing.
    present = set(nutrition.logged_metrics())
    reported = [n for n in nutrition.headline_nutrients() if n.slug in present]

    # Energy first and unfiltered, because the partial days this drops are
    # themselves part of the answer: "you logged something on six days and
    # finished the log on four" is the honest shape of a food diary.
    values: dict[str, dict[date, float]] = {}
    entries: dict[date, int] = {}
    estimated_days = 0
    unconvertible: list[dict] = []

    energy: dict[date, float] = {}
    if nutrition.ENERGY in present:
        payload = nutrition.daily_series(nutrition.ENERGY, start, end, tz_name=tz_name)
        for point in payload["points"]:
            day = date.fromisoformat(point["date"])
            energy[day] = float(point["value"])
            entries[day] = point.get("entries") or 0
        estimated_days = payload["estimated_days"]
        unconvertible.extend(payload.get("unconvertible_samples") or [])
    values[nutrition.ENERGY] = energy

    # A day is only "fully logged" if its *energy* is plausible for a whole day.
    # Every other nutrient is then read on those days only: protein from a
    # half-finished Tuesday is as misleading as the energy figure it came with.
    complete_set = {day for day, kcal in energy.items() if nutrition.is_complete_log(kcal)}

    for spec in reported:
        if spec.slug == nutrition.ENERGY:
            continue
        payload = nutrition.daily_series(
            spec.slug, start, end, tz_name=tz_name, only_days=complete_set
        )
        values[spec.slug] = {
            date.fromisoformat(point["date"]): float(point["value"])
            for point in payload["points"]
        }
        unconvertible.extend(payload.get("unconvertible_samples") or [])

    logged = sorted({day for table in values.values() for day in table})
    complete = [day for day in logged if day in complete_set]
    partial = [day for day in logged if day not in complete_set]

    def mean_over(table: dict[date, float]) -> tuple[float | None, int]:
        picked = [table[day] for day in complete if day in table]
        return (statistics.fmean(picked) if picked else None), len(picked)

    energy_mean, energy_days = mean_over(energy)
    energy_values = [energy[day] for day in complete if day in energy]

    nutrients = []
    for spec in reported:
        average, counted = mean_over(values[spec.slug])
        row = {
            "nutrient": spec.slug,
            "label": spec.label,
            "unit": spec.unit,
            "group": spec.group,
            "average_per_logged_day": _round(average, spec.decimals),
            "days_counted": counted,
        }
        # Share of intake, for the three macros that carry energy. Uses the
        # ordinary 4/4/9 kcal-per-gram convention, which is an approximation and
        # is labelled as one — not a recommendation about what the split ought
        # to be.
        if spec.kcal_per_gram and average is not None and energy_mean:
            row["share_of_logged_energy_pct"] = round(
                average * spec.kcal_per_gram / energy_mean * 100, 1
            )
        nutrients.append(row)

    coverage = len(complete) / days if days else 0.0
    if not logged:
        confidence = "insufficient"
        reason = f"nothing was logged in the {days} days to {as_of.isoformat()}"
    elif len(complete) < 3:
        confidence = "insufficient"
        reason = (
            f"only {len(complete)} day(s) in this window have a full food log; "
            "at least 3 are needed to average anything"
        )
    elif coverage < 0.5:
        confidence = "low"
        reason = f"{len(complete)} of {days} days have a full food log"
    elif coverage < 0.8:
        confidence = "moderate"
        reason = f"{len(complete)} of {days} days have a full food log"
    else:
        confidence = "high"
        reason = f"{len(complete)} of {days} days have a full food log"

    limitations = [
        "These are logged amounts, not measurements. Anything eaten and not written "
        "down is missing from every total here, and portion sizes in a food app are "
        "estimates."
    ]
    if partial:
        limitations.append(
            f"{len(partial)} day(s) had too little logged to be a whole day's eating, so "
            "they are treated as incomplete logs and left out of the averages. They are "
            "not evidence of light days."
        )
    not_logged = days - len(logged)
    if not_logged > 0:
        limitations.append(
            f"{not_logged} of {days} days have no food log at all. Those days are unknown, "
            "not days without food."
        )
    if estimated_days:
        limitations.append(
            f"{estimated_days} day(s) are summed from individual entries rather than Apple's "
            "deduplicated daily total, so a meal logged twice would be counted twice."
        )
    if unconvertible:
        limitations.append(
            "Some samples arrived in a unit this server could not convert and were left "
            "out: " + ", ".join(f"{u['samples']}× {u['unit']}" for u in unconvertible) + "."
        )

    payload = {
        "from": start_day.isoformat(),
        "to": as_of.isoformat(),
        "window_days": days,
        "days_logged": len(logged),
        "days_fully_logged": len(complete),
        "days_partially_logged": len(partial),
        "days_not_logged": not_logged,
        "coverage": round(coverage, 2),
        "energy": {
            "unit": "kcal",
            "average_per_logged_day": _round(energy_mean, 0),
            "lowest_logged_day": _round(min(energy_values), 0) if energy_values else None,
            "highest_logged_day": _round(max(energy_values), 0) if energy_values else None,
            "days_counted": energy_days,
        },
        "nutrients": nutrients,
        "energy_balance": _energy_balance(complete, energy, start, end, tz_name),
        "weight_context": _weight_context(as_of, tz_name),
        "days": [
            {
                "date": day.isoformat(),
                "energy_kcal": _round(energy.get(day), 0),
                "entries": entries.get(day, 0),
                "complete_log": day in complete_set,
                "totals": {
                    spec.slug: _round(values[spec.slug][day], spec.decimals)
                    for spec in reported
                    if day in values[spec.slug] and spec.slug != nutrition.ENERGY
                },
            }
            for day in logged
        ],
        "sources": nutrition.sources(start, end),
        "confidence": confidence,
        "confidence_reason": reason,
        "limitations": limitations,
        "note": (
            "Nutrition is the one signal here nobody's watch records. Missing days mean "
            "nothing was written down."
        ),
    }
    if nutrition.ENERGY in present:
        # The person's own recent norm, which is the only comparison this system
        # makes. It is graded thin while a food log is new, and that grade is the
        # answer to "is this a lot or a little for me" until there is a baseline.
        payload["energy_vs_baseline"] = compare_to_baseline(
            nutrition.ENERGY, as_of=as_of, tz_name=tz_name
        )
    return payload


# --------------------------------------------------------------------------
# Snapshot
# --------------------------------------------------------------------------


def last_recorded(slug: str) -> datetime | None:
    """Most recent sample of a metric, over all time.

    Distinct from anything windowed: a metric that stopped syncing five weeks
    ago has no data in the current window and no data in the baseline, so every
    windowed query says the same unhelpful nothing. The useful fact is *when it
    stopped*, which is the difference between "you don't track this" and "this
    broke".
    """
    row = (
        analytics.live_records()
        .filter(metric_slug=slug)
        .aggregate(latest=Max("end"), latest_start=Max("start"))
    )
    candidates = [value for value in (row["latest"], row["latest_start"]) if value]
    return max(candidates) if candidates else None


def available_metrics() -> list[str]:
    """Metrics this module can analyse *and* the store actually holds.

    Offering a comparison for a metric with no rows produces a confident-looking
    empty answer, which is worse than saying the data is not there.
    """
    present = set(
        analytics.live_records()
        .filter(metric_slug__in=list(METRICS))
        .values_list("metric_slug", flat=True)
        .distinct()
    )
    return [slug for slug in METRICS if slug in present]


def snapshot(
    as_of: date | None = None,
    metrics: list[str] | None = None,
    tz_name: str | None = None,
) -> dict:
    """The structured health snapshot §3 describes — everything an insight needs,
    computed, before any model is involved."""
    as_of = as_of or last_complete_day(tz_name)
    present = set(available_metrics())
    wanted = [m for m in (metrics or SNAPSHOT_METRICS) if m in present]

    comparisons = [compare_to_baseline(slug, as_of=as_of, tz_name=tz_name) for slug in wanted]
    quality = [data_quality(slug, as_of=as_of, tz_name=tz_name) for slug in wanted]

    sleep = sleep_summary(as_of=as_of, tz_name=tz_name) if "sleep_analysis" in present else None
    activity = workouts(as_of=as_of, tz_name=tz_name)

    # Alongside sleep and workouts rather than inside `metrics`, and that
    # placement is the whole design. A food log is days old the week somebody
    # starts one, so as a headline metric its "insufficient" grade would become
    # the snapshot's overall grade and every answer about steps and heart rate
    # would arrive hedged about coverage that is perfectly good.
    food = (
        nutrition_summary(as_of=as_of, tz_name=tz_name)
        if nutrition.logged_metrics()
        else None
    )

    # A metric with nothing in either window has not been recorded lately — it
    # is a sync problem, not a weak measurement. Kept in `metrics` so the gap
    # stays visible, but excluded from the overall grade: letting one metric
    # that stopped uploading five weeks ago drag the whole snapshot to
    # "insufficient" makes every answer hedge about steps and heart rate that
    # were recorded perfectly well.
    stale = []
    active = []
    for comparison in comparisons:
        if comparison["current"]["valid_days"] or comparison["baseline"]["valid_days"]:
            active.append(comparison)
            continue
        seen = last_recorded(comparison["metric_slug"])
        stale.append(
            {
                "metric_slug": comparison["metric_slug"],
                "label": analytics.display_name(comparison["metric_slug"]),
                "last_recorded_at": seen.isoformat() if seen else None,
                "days_since": (as_of - seen.astimezone(analytics.zone(tz_name)).date()).days
                if seen
                else None,
            }
        )

    weakest = min(
        (c["confidence"] for c in active),
        key=CONFIDENCE_ORDER.index,
        default="insufficient",
    )

    return {
        "as_of": as_of.isoformat(),
        "generated_for": {
            "current_window_days": CURRENT_DAYS,
            "baseline_window_days": BASELINE_DAYS,
        },
        "timezone": str(analytics.zone(tz_name)),
        "metrics": comparisons,
        "data_quality": quality,
        "sleep": sleep,
        "workouts": activity,
        "nutrition": food,
        "overall_confidence": weakest,
        "metrics_unavailable": [m for m in (metrics or SNAPSHOT_METRICS) if m not in present],
        # Recorded at some point, but nothing recent. Almost always a sync that
        # stopped rather than a habit that changed, and worth saying out loud.
        "metrics_not_syncing": stale,
        "note": (
            "Windows end yesterday because today is incomplete. Baseline and current "
            "windows do not overlap."
        ),
    }


def daily_brief(as_of: date | None = None, tz_name: str | None = None) -> dict:
    """A few words for a notification, plus the detail behind them.

    Deterministic and fast on purpose. This is what fires at 08:00, and a
    morning alert that depends on a language model running on a laptop is an
    alert that silently stops the first time the laptop is shut.

    Ranked by how far each metric has moved relative to its own baseline, so the
    line says the most interesting true thing rather than the first thing in the
    list. Anything that stopped syncing outranks all of it: a number that is
    missing matters more than a number that moved.
    """
    snap = snapshot(as_of=as_of, tz_name=tz_name)

    movers = sorted(
        (
            m
            for m in snap["metrics"]
            if m["significance"] == "notable"
            and m["confidence"] not in ("insufficient", "low")
            and m["change_pct"] is not None
        ),
        key=lambda m: -abs(m["change_pct"]),
    )

    def phrase(metric: dict) -> str:
        pct = metric["change_pct"]
        label = SHORT_LABELS.get(metric["metric_slug"], metric["label"])
        # No .capitalize() anywhere near this: it lowercases everything after
        # the first character, which turns "HRV" into "hrv". The labels are
        # already cased correctly.
        return f"{label} {'up' if pct > 0 else 'down'} {abs(pct):.0f}%"

    stale = snap.get("metrics_not_syncing") or []
    stale_phrases = [
        f"{SHORT_LABELS.get(s['metric_slug'], s['label'])} not syncing"
        + (f" ({s['days_since']}d)" if s.get("days_since") else "")
        for s in stale[:2]
    ]

    fragments = [phrase(m) for m in movers[:4]]
    # Staleness leads when nothing moved. "Nothing much changed" as the headline
    # with "sleep not syncing" trailing behind it buries the only actionable
    # thing in the message under a reassurance.
    if fragments:
        fragments.extend(stale_phrases)
    else:
        fragments = stale_phrases or [
            "Nothing much moved against your baseline"
            if snap["metrics"]
            else "No health data yet"
        ]

    headline = fragments[0]
    detail = " · ".join(fragments[1:])

    return {
        "as_of": snap["as_of"],
        "headline": headline,
        "detail": detail,
        # Joined here rather than on the phone, so the phrasing lives in one
        # place instead of being glued together differently by each client.
        "line": " · ".join(fragments),
        "movers": movers[:5],
        "not_syncing": stale,
        "overall_confidence": snap["overall_confidence"],
        # Something is worth saying only when a metric actually moved or broke.
        # A daily alert that fires with "nothing changed" every day is one people
        # switch off, and then miss the day it matters.
        "worth_notifying": bool(movers or stale),
    }


SHORT_LABELS = {
    "resting_heart_rate": "Resting HR",
    "heart_rate_variability_sdnn": "HRV",
    "walking_heart_rate_average": "Walking HR",
    "apple_exercise_time": "Exercise",
    "sleep_analysis": "Sleep",
    "active_energy_burned": "Active energy",
    "distance_walking_running": "Distance",
    "step_count": "Steps",
    "body_mass": "Weight",
}


def compare_periods(
    slug: str,
    period_a_from: date,
    period_a_to: date,
    period_b_from: date,
    period_b_to: date,
    tz_name: str | None = None,
) -> dict:
    """Two arbitrary periods, with a refusal when either is too thin.

    The refusal is the feature. A percentage change between a fully recorded
    fortnight and one with three days of data is a number that looks like an
    answer and is not one.
    """
    spec = spec_for(slug)
    a = day_values(slug, period_a_from, period_a_to, tz_name)
    b = day_values(slug, period_b_from, period_b_to, tz_name)

    a_days = (period_a_to - period_a_from).days + 1
    b_days = (period_b_to - period_b_from).days + 1
    a_cov = _coverage(len(a), a_days, spec.expected_cadence)
    b_cov = _coverage(len(b), b_days, spec.expected_cadence)

    a_value = statistics.fmean([d.value for d in a]) if a else None
    b_value = statistics.fmean([d.value for d in b]) if b else None

    sufficient = (
        len(a) >= spec.min_current_days
        and len(b) >= spec.min_current_days
        and a_cov >= 0.5
        and b_cov >= 0.5
    )
    delta = (b_value - a_value) if (a_value is not None and b_value is not None) else None

    return {
        "metric_slug": slug,
        "label": spec.label,
        "unit": spec.unit,
        "period_a": {
            "from": period_a_from.isoformat(),
            "to": period_a_to.isoformat(),
            "value": _round(a_value, spec.decimals),
            "valid_days": len(a),
            "window_days": a_days,
            "coverage": round(a_cov, 2),
        },
        "period_b": {
            "from": period_b_from.isoformat(),
            "to": period_b_to.isoformat(),
            "value": _round(b_value, spec.decimals),
            "valid_days": len(b),
            "window_days": b_days,
            "coverage": round(b_cov, 2),
        },
        "change": _round(delta, spec.decimals) if sufficient else None,
        "change_pct": (
            round(delta / a_value * 100, 1)
            if sufficient and delta is not None and a_value
            else None
        ),
        "comparable": sufficient,
        "reason": (
            None
            if sufficient
            else "One or both periods have too few recorded days to compare meaningfully."
        ),
    }


# --------------------------------------------------------------------------
# Anomalies
# --------------------------------------------------------------------------


def anomalies(
    as_of: date | None = None,
    tz_name: str | None = None,
    threshold: float = 2.0,
) -> list[dict]:
    """Metrics sitting well outside the user's own recent range.

    Deliberately conservative: robust statistics, a coverage floor, and a
    requirement that the shift persist for several days. A one-night dip in HRV
    after a late meal is not a finding, and surfacing it as one is how alerts
    become noise people learn to dismiss.
    """
    as_of = as_of or last_complete_day(tz_name)
    out = []
    for slug in available_metrics():
        spec = METRICS[slug]
        comparison = compare_to_baseline(slug, as_of=as_of, tz_name=tz_name)
        if comparison["confidence"] in ("insufficient", "low"):
            continue

        series = day_values(slug, as_of - timedelta(days=BASELINE_DAYS + CURRENT_DAYS - 1), as_of, tz_name)
        baseline_values = [
            d.value for d in series if d.day <= as_of - timedelta(days=CURRENT_DAYS)
        ]
        spread = _robust_spread(baseline_values)
        if spread <= 0 or comparison["change"] is None:
            continue

        z = comparison["change"] / spread
        if abs(z) < threshold:
            continue

        # Sustained, not a single day: how many of the current window's days sit
        # on the same side of the baseline by at least one spread.
        median = statistics.median(baseline_values)
        current = [d for d in series if d.day > as_of - timedelta(days=CURRENT_DAYS)]
        sustained = sum(
            1 for d in current if (d.value - median) / spread * (1 if z > 0 else -1) >= 1
        )
        if sustained < 3:
            continue

        out.append(
            {
                "metric_slug": slug,
                "label": spec.label,
                "unit": spec.unit,
                "direction": "above" if z > 0 else "below",
                "current": comparison["current"]["value"],
                "baseline": comparison["baseline"]["value"],
                "change": comparison["change"],
                "change_pct": comparison["change_pct"],
                "deviations_from_baseline": round(abs(z), 1),
                "days_sustained": sustained,
                "confidence": comparison["confidence"],
                # Framed as an observation about the user's own range. Anything
                # stronger would be a clinical claim this data cannot support.
                "observation": (
                    f"{spec.label} averaged {comparison['current']['value']} {spec.unit} over the "
                    f"last {CURRENT_DAYS} days, {'above' if z > 0 else 'below'} the "
                    f"{BASELINE_DAYS}-day baseline of {comparison['baseline']['value']} {spec.unit}."
                ),
            }
        )

    out.sort(key=lambda item: -item["deviations_from_baseline"])
    return out
