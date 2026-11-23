"""Lifestyle signals: the behaviours and overnight measurements with the
strongest evidence behind them, computed as transparently as the rest.

Four things, each chosen because the research says it matters and each built
from data the phone was already uploading:

- **Overnight vitals** — last night's heart rate, HRV, breathing rate, wrist
  temperature, blood oxygen and sleep against the range of the person's own
  previous nights. Flagged only when two or more sit outside it at once, the
  rule Apple's Vitals app uses, because one metric out of range on one night is
  what a sensor does and two together is what a body does.
- **Sleep regularity** — the Sleep Regularity Index. In UK Biobank it predicted
  mortality better than sleep duration did, and adding duration to it explained
  nothing more.
- **Weekly activity** — exercise minutes over a rolling week against the WHO
  guideline, because the evidence is about the week, not the day: people who fit
  their week's activity into one or two days get much the same benefit.
- **Daylight and cardio fitness** — the existing baseline machinery, pointed at
  two signals nothing read.

None of it is a score. Every section is a measurement, the range or reference
it was judged against, how much data it rests on, and what it cannot say. A
composite "readiness" number would be easier to put on a screen and impossible
for anyone to check, which is the trade every vendor in this space has made and
this module declines.

Nothing here is a diagnosis. An overnight flag is "your body was doing
something unusual for you", with the ordinary explanations listed — alcohol, a
late meal, travel, hard training — and never a condition.
"""

import bisect
import math
import statistics
from datetime import date, datetime, timedelta

from django.db.models import Q

from . import analytics, health_analysis
from .health_analysis import CURRENT_DAYS, BASELINE_DAYS
from .models import Record

# --------------------------------------------------------------------------
# Overnight vitals
# --------------------------------------------------------------------------

# Apple's Vitals app needs seven nights before it will call anything typical,
# and that is the right order of magnitude: a range from three nights is a
# range from whatever those three nights happened to be.
MIN_RANGE_NIGHTS = 7

# The flag needs this many signals outside their range on the same night.
FLAG_THRESHOLD = 2

# How far back "last night" may reach. A phone that has not synced yet this
# morning shows the night before, dated; a week-old night is not last night
# and is not presented as one.
RECENT_NIGHT_DAYS = 2

# Samples a few minutes either side of the first and last asleep interval still
# belong to the night: the watch's respiratory and wrist-temperature samples
# are stamped to the sleep session, which starts a little before the first
# stage interval.
NIGHT_SLACK = timedelta(minutes=30)


class _Signal:
    """One overnight measurement.

    `floor` is the narrowest half-width the typical range may have. Someone
    whose sleeping heart rate has sat within one beat for a month would
    otherwise get a range so tight that the next ordinary night falls outside
    it. `log` judges the range on a log scale, which is how HRV varies — a
    20 ms drop from 80 is not the same event as a 20 ms drop from 30.
    """

    def __init__(
        self, key, slug, label, unit, floor, decimals=0, log=False, scale=None, spans_night=False
    ):
        self.key = key
        self.slug = slug
        self.label = label
        self.unit = unit
        self.floor = floor
        self.decimals = decimals
        self.log = log
        self.scale = scale
        # One sample covering the whole sleep session rather than readings taken
        # during it. Its start can sit well before the first asleep interval —
        # time in bed reading counts — so it is fetched by a wider net and
        # placed by its midpoint like everything else.
        self.spans_night = spans_night


SIGNALS = [
    _Signal("sleeping_heart_rate", "heart_rate", "Sleeping heart rate", "count/min", floor=3.0),
    _Signal(
        "overnight_hrv", "heart_rate_variability_sdnn", "Overnight HRV", "ms",
        floor=0.15, decimals=0, log=True,
    ),
    _Signal(
        "respiratory_rate", "respiratory_rate", "Breathing rate", "count/min",
        floor=1.0, decimals=1,
    ),
    _Signal(
        "wrist_temperature", "apple_sleeping_wrist_temperature", "Wrist temperature", "degC",
        floor=0.3, decimals=2, spans_night=True,
    ),
    # HealthKit's percent unit is a fraction: 97% arrives as 0.97. Shown as a
    # percentage, because nobody reads a blood-oxygen figure as 0.97.
    _Signal(
        "blood_oxygen", "oxygen_saturation", "Blood oxygen", "%",
        floor=2.0, decimals=1, scale="percent",
    ),
]

SLEEP_SIGNAL = _Signal("sleep_duration", "sleep_analysis", "Sleep duration", "h", floor=1.0, decimals=2)

# What else moves these, in the order people most often meet them. Listed in
# the payload so an explanation reaches for an ordinary cause before an
# alarming one — and never names a condition.
POSSIBLE_FACTORS = [
    "alcohol",
    "a late or heavy meal",
    "travel or a different time zone",
    "unusually hard training",
    "stress",
    "a cold or other illness coming on",
    "altitude",
    "a new medication",
]


# Asleep stretches this close together are one sleep: waking for twenty minutes
# at 03:00 does not end the night, and a nap four hours after waking is not part
# of it.
BLOCK_GAP = timedelta(minutes=60)

# A main sleep shorter than this is far more often a nap, or a watch taken off
# partway through the night, than a night — the same bar sleep regularity uses.
MIN_NIGHT_SECONDS = 3 * 3600


def _main_sleeps(first_morning: date, last_morning: date, tz_name: str | None) -> dict[date, dict]:
    """Each morning's main sleep: its start, end and time asleep.

    Not `health_analysis._sleep_nights`, which files every asleep interval under
    the date it ends. That is right for "hours slept on Tuesday", and wrong for
    a window to read overnight signals inside: a 14:00 nap stretched the night
    to mid-afternoon and averaged the morning's heart rate — a run included —
    into "sleeping heart rate".

    Built in two passes. Overlapping intervals are merged first, so a night
    two sources both recorded is counted once rather than twice. Then stretches
    no more than `BLOCK_GAP` apart are joined into sleeps, and each morning
    keeps the longest one ending that day.
    """
    tz = analytics.zone(tz_name)
    # A night ending on `first_morning` can begin the evening before.
    start, end = health_analysis._bounds(first_morning - timedelta(days=1), last_morning, tz_name)
    rows = (
        analytics.live_records()
        .filter(kind=Record.Kind.SLEEP, extra__is_asleep=True, end__gt=start, start__lt=end)
        .values_list("start", "end")
    )
    intervals = sorted((s, e) for s, e in rows if s and e and e > s)

    segments: list[list[datetime]] = []
    for s, e in intervals:
        if segments and s <= segments[-1][1]:
            segments[-1][1] = max(segments[-1][1], e)
        else:
            segments.append([s, e])

    blocks: list[dict] = []
    for s, e in segments:
        if blocks and s - blocks[-1]["end"] <= BLOCK_GAP:
            blocks[-1]["end"] = e
            blocks[-1]["seconds"] += (e - s).total_seconds()
        else:
            blocks.append({"start": s, "end": e, "seconds": (e - s).total_seconds()})

    main: dict[date, dict] = {}
    for block in blocks:
        if block["seconds"] < MIN_NIGHT_SECONDS:
            continue
        morning = block["end"].astimezone(tz).date()
        if not (first_morning <= morning <= last_morning):
            continue
        if morning not in main or block["seconds"] > main[morning]["seconds"]:
            main[morning] = block
    return main


def _night_windows(nights: dict[date, dict]) -> list[tuple[datetime, datetime, date]]:
    windows = [
        (entry["start"] - NIGHT_SLACK, entry["end"] + NIGHT_SLACK, morning)
        for morning, entry in nights.items()
    ]
    windows.sort()
    return windows


def _per_night(signal: _Signal, windows) -> dict[date, float]:
    """The signal's average inside each night window.

    One query, restricted in SQL to the night windows themselves: a month of
    heart rate is tens of thousands of rows, nearly all of them daytime, and
    the night is the only part this asks about.
    """
    if not windows:
        return {}
    reach = timedelta(hours=12) if signal.spans_night else timedelta(0)
    clause = Q()
    for start, end, _ in windows:
        clause |= Q(start__gte=start - reach, start__lt=end)
    rows = (
        analytics.live_records()
        .filter(metric_slug=signal.slug)
        .exclude(kind=Record.Kind.STATISTIC)
        .filter(clause)
        .values("start", "end", "value")
    )

    starts = [w[0] for w in windows]
    buckets: dict[date, list[float]] = {}
    for row in rows:
        if row["value"] is None or not row["start"]:
            continue
        # A sample belongs to the night its midpoint falls in. For an
        # instantaneous reading that is its timestamp; for the one wrist
        # temperature sample that spans the whole night, it is the middle of
        # the night rather than the evening it was started.
        end = row["end"] or row["start"]
        midpoint = row["start"] + (end - row["start"]) / 2
        index = bisect.bisect_right(starts, midpoint) - 1
        if index < 0:
            continue
        window_start, window_end, morning = windows[index]
        if not (window_start <= midpoint < window_end):
            continue
        value = float(row["value"])
        if signal.scale == "percent":
            value = analytics.as_percent(value)
        if signal.log and value <= 0:
            continue
        buckets.setdefault(morning, []).append(value)

    out = {}
    for morning, values in buckets.items():
        if signal.log:
            out[morning] = math.exp(statistics.fmean(math.log(v) for v in values))
        else:
            out[morning] = statistics.fmean(values)
    return out


def _typical_range(signal: _Signal, values: list[float]) -> dict | None:
    """Median ± max(2 robust deviations, floor), on the signal's own scale.

    Two robust deviations is roughly the middle 95% of this person's nights.
    With five or six signals each outside that band one night in twenty,
    two at once by chance is about one night in thirty — rare enough that a
    flag means something, common enough that it is not a fire alarm.
    """
    if len(values) < MIN_RANGE_NIGHTS:
        return None
    scaled = [math.log(v) for v in values] if signal.log else values
    median = statistics.median(scaled)
    half = max(2 * health_analysis._robust_spread(scaled), signal.floor)
    low, high = median - half, median + half
    if signal.log:
        median, low, high = math.exp(median), math.exp(low), math.exp(high)
    return {"median": median, "low": low, "high": high}


def _lower_first(label: str) -> str:
    """"Overnight HRV" → "overnight HRV". Not `.lower()`, which turns the
    acronym into "hrv" — the same trap `daily_brief` warns about."""
    return label[:1].lower() + label[1:]


def _round(value: float | None, decimals: int):
    if value is None:
        return None
    return round(value, decimals) if decimals else round(value)


def overnight_vitals(morning: date | None = None, tz_name: str | None = None) -> dict:
    """The most recent night against the range of the 28 before it.

    The one place a date of *today* appears in this layer, and deliberately:
    windows end yesterday because today is a partial day, but last night is not
    part of today — it ended this morning and is complete. A morning check that
    could only see the night before last would be answering the wrong question.
    The night is always named by date, so a phone that has not synced yet this
    morning shows the previous night *as* the previous night.
    """
    tz = analytics.zone(tz_name)
    morning = morning or health_analysis.today(tz_name)

    # Everything that could be the target night or its baseline, in one read.
    first_morning = morning - timedelta(days=RECENT_NIGHT_DAYS + BASELINE_DAYS)
    nights = _main_sleeps(first_morning, morning, tz_name)

    recent = sorted(
        (m for m in nights if m >= morning - timedelta(days=RECENT_NIGHT_DAYS)), reverse=True
    )
    rule = (
        f"Each measurement is compared with the range of your previous {BASELINE_DAYS} nights "
        f"(at least {MIN_RANGE_NIGHTS} needed). Flagged only when {FLAG_THRESHOLD} or more "
        "are outside it on the same night."
    )
    if not recent:
        return {
            "status": "no_recent_night",
            "night_of": None,
            "morning_of": None,
            "metrics": [],
            "outside_range": 0,
            "observation": "No night has been recorded in the last few days.",
            "rule": rule,
        }

    target = recent[0]
    baseline_mornings = {
        m for m in nights if target - timedelta(days=BASELINE_DAYS) <= m < target
    }
    windows = _night_windows(
        {m: e for m, e in nights.items() if m == target or m in baseline_mornings}
    )

    per_signal = [(signal, _per_night(signal, windows)) for signal in SIGNALS]
    per_signal.append(
        (
            SLEEP_SIGNAL,
            {
                m: e["seconds"] / 3600
                for m, e in nights.items()
                if (m == target or m in baseline_mornings) and e["seconds"] > 0
            },
        )
    )

    metrics = []
    for signal, values in per_signal:
        tonight = values.get(target)
        history = [v for m, v in values.items() if m in baseline_mornings]
        if tonight is None and not history:
            # Not tracked at all — not a gap worth a row.
            continue
        band = _typical_range(signal, history)
        if tonight is None:
            status = "missing"
        elif band is None:
            status = "no_range"
        elif tonight > band["high"]:
            status = "above"
        elif tonight < band["low"]:
            status = "below"
        else:
            status = "within"
        metrics.append(
            {
                "metric": signal.key,
                "label": signal.label,
                "unit": signal.unit,
                "value": _round(tonight, signal.decimals),
                "typical_low": _round(band["low"], signal.decimals) if band else None,
                "typical_high": _round(band["high"], signal.decimals) if band else None,
                "typical": _round(band["median"], signal.decimals) if band else None,
                "baseline_nights": len(history),
                "status": status,
            }
        )

    outside = [m for m in metrics if m["status"] in ("above", "below")]
    ranged = [m for m in metrics if m["status"] in ("above", "below", "within")]

    if len(ranged) < FLAG_THRESHOLD:
        status = "building"
        needed = max(
            0, MIN_RANGE_NIGHTS - max((m["baseline_nights"] for m in metrics), default=0)
        )
        observation = (
            "Still learning your typical overnight range"
            + (f" — about {needed} more nights needed." if needed else ".")
        )
    elif len(outside) >= FLAG_THRESHOLD:
        status = "outside_range"
        parts = [f"{_lower_first(m['label'])} {m['status']}" for m in outside]
        observation = (
            f"{len(outside)} overnight measurements were outside your usual range: "
            + ", ".join(parts)
            + ". This describes a change from your own normal, not a cause."
        )
    else:
        status = "within_range"
        observation = (
            "Overnight measurements were within your usual range."
            if not outside
            else f"Only {_lower_first(outside[0]['label'])} was outside your usual range — "
            "on its own that is common and not flagged."
        )

    night_of = target - timedelta(days=1)
    today = datetime.now(tz).date()
    return {
        "status": status,
        "night_of": night_of.isoformat(),
        "morning_of": target.isoformat(),
        # The night that ended this morning, or an older one because nothing
        # newer has arrived yet. Clients name the night either way.
        "is_last_night": target == today,
        "metrics": metrics,
        "outside_range": len(outside),
        "observation": observation,
        "possible_factors": POSSIBLE_FACTORS if status == "outside_range" else [],
        "rule": rule,
    }


# --------------------------------------------------------------------------
# Sleep regularity
# --------------------------------------------------------------------------

MINUTES_PER_DAY = 1440

# A sleep-day with less than this recorded is far more often a watch taken off
# partway through the night than a three-hour night, and counting it would
# score every missing hour as awake. Regularity indices are robust to data
# missing at random and badly thrown by data missing for a reason — and a watch
# on the charger is a reason.
MIN_ASLEEP_MINUTES = 180

# At least five days of 24-hour-apart pairs, the bar UK Biobank analyses used.
MIN_CURRENT_PAIRS = 5
MIN_BASELINE_PAIRS = 14

# Context, not a target: UK Biobank, 60,977 adults with a week of wrist
# accelerometry (Windred et al., Sleep 2024). Quintile cut-points of the cohort.
SRI_REFERENCE = {
    "source": "UK Biobank, 60,977 adults (Windred et al., Sleep 2024)",
    "median": 81,
    "most_regular_fifth_above": 87.3,
    "least_regular_fifth_below": 71.6,
    "note": (
        "Measured there with a research accelerometer worn for a week. Context for "
        "reading the number, not a target to hit."
    ),
}


def _sri_label(value: float) -> str:
    if value >= SRI_REFERENCE["most_regular_fifth_above"]:
        return "very regular"
    if value >= SRI_REFERENCE["median"]:
        return "regular"
    if value >= SRI_REFERENCE["least_regular_fifth_below"]:
        return "somewhat irregular"
    return "irregular"


def _sleep_masks(first_morning: date, last_morning: date, tz_name: str | None) -> dict[date, bytearray]:
    """A minute-by-minute asleep mask for each sleep-day.

    A sleep-day runs noon to noon and is named by its morning, the same
    convention every night in this codebase is filed under. Overlapping sources
    — the watch, the phone, a third-party sleep app — collapse naturally: a
    minute is asleep if any of them says so.
    """
    tz = analytics.zone(tz_name)
    days = (last_morning - first_morning).days + 1
    # Minutes are counted on the local wall clock, not as elapsed time. The
    # index asks "was this person asleep at 03:10", and across a DST change an
    # unchanged 23:00–07:00 schedule is an hour apart in elapsed time — which
    # scored a perfectly regular sleeper as irregular twice a year.
    origin = datetime.combine(first_morning - timedelta(days=1), datetime.min.time()) + timedelta(hours=12)
    horizon = origin + timedelta(days=days)

    masks = {first_morning + timedelta(days=i): bytearray(MINUTES_PER_DAY) for i in range(days)}
    rows = (
        analytics.live_records()
        .filter(
            kind=Record.Kind.SLEEP,
            extra__is_asleep=True,
            end__gt=origin.replace(tzinfo=tz),
            start__lt=horizon.replace(tzinfo=tz),
        )
        .values("start", "end")
    )
    for row in rows:
        if not row["start"] or not row["end"]:
            continue
        start = max(row["start"].astimezone(tz).replace(tzinfo=None), origin)
        end = min(row["end"].astimezone(tz).replace(tzinfo=None), horizon)
        if end <= start:
            continue
        first = int((start - origin).total_seconds() // 60)
        last = int(math.ceil((end - origin).total_seconds() / 60))
        for minute in range(first, min(last, days * MINUTES_PER_DAY)):
            day, offset = divmod(minute, MINUTES_PER_DAY)
            masks[first_morning + timedelta(days=day)][offset] = 1
    return masks


def _pair_scores(masks: dict[date, bytearray], mornings: list[date]) -> list[float]:
    """SRI for each recorded pair of consecutive sleep-days.

    Phillips et al. 2017: the share of minutes in the same state 24 hours apart,
    rescaled so 100 is the same schedule every day and 0 is no relationship.
    Every pair compares 1,440 minutes, so the window's index is the mean of
    these — which also gives a spread to grade a change against.
    """
    scores = []
    for morning in mornings:
        today = masks.get(morning)
        yesterday = masks.get(morning - timedelta(days=1))
        if today is None or yesterday is None:
            continue
        if sum(today) < MIN_ASLEEP_MINUTES or sum(yesterday) < MIN_ASLEEP_MINUTES:
            continue
        same = sum(1 for a, b in zip(today, yesterday) if a == b)
        scores.append(200 * same / MINUTES_PER_DAY - 100)
    return scores


def sleep_regularity(as_of: date | None = None, tz_name: str | None = None) -> dict:
    """The Sleep Regularity Index this week, against the four weeks before it.

    Same windows as everything else: seven days ending yesterday's morning,
    compared with the twenty-eight before them, so "less regular than usual"
    means less regular than this person's own last month.
    """
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    current_from = as_of - timedelta(days=CURRENT_DAYS - 1)
    baseline_to = current_from - timedelta(days=1)
    baseline_from = baseline_to - timedelta(days=BASELINE_DAYS - 1)

    # One extra day before the baseline so its first morning has a partner.
    masks = _sleep_masks(baseline_from - timedelta(days=1), as_of, tz_name)

    def mornings(start, end):
        return [start + timedelta(days=i) for i in range((end - start).days + 1)]

    current = _pair_scores(masks, mornings(current_from, as_of))
    baseline = _pair_scores(masks, mornings(baseline_from, baseline_to))

    current_value = statistics.fmean(current) if len(current) >= MIN_CURRENT_PAIRS else None
    baseline_value = statistics.fmean(baseline) if len(baseline) >= MIN_BASELINE_PAIRS else None

    coverage = len(current) / CURRENT_DAYS
    if current_value is None:
        confidence = "insufficient"
    elif coverage >= 0.85:
        confidence = "high"
    else:
        confidence = "moderate"
    reason = (
        f"{len(current)} of {CURRENT_DAYS} days have a recorded night and the night before it"
        + ("" if current_value is not None else f" — at least {MIN_CURRENT_PAIRS} are needed")
    )

    change = significance = None
    if current_value is not None and baseline_value is not None:
        change = current_value - baseline_value
        significance = health_analysis.classify_change(change, baseline)

    return {
        "from": current_from.isoformat(),
        "to": as_of.isoformat(),
        "window_days": CURRENT_DAYS,
        "sri": _round(current_value, 0),
        "label": _sri_label(current_value) if current_value is not None else None,
        "valid_pairs": len(current),
        "baseline": {
            "from": baseline_from.isoformat(),
            "to": baseline_to.isoformat(),
            "window_days": BASELINE_DAYS,
            "sri": _round(baseline_value, 0),
            "valid_pairs": len(baseline),
        },
        "change": _round(change, 0),
        # Graded against the spread of this person's own day-to-day scores,
        # the same vocabulary every other comparison here uses.
        "significance": significance or "unclear",
        "confidence": confidence,
        "confidence_reason": reason,
        "reference": SRI_REFERENCE,
        "method": (
            "Sleep Regularity Index (Phillips 2017): the share of minutes asleep or awake at "
            "the same clock time 24 hours apart, scaled so 100 is an identical schedule every "
            "day. Days with under three hours recorded are left out rather than counted as "
            "awake."
        ),
    }


# --------------------------------------------------------------------------
# Weekly activity
# --------------------------------------------------------------------------

GUIDELINE = {
    "source": "WHO 2020 physical activity guidelines",
    "minutes_low": 150,
    "minutes_high": 300,
    "note": (
        "150–300 minutes of moderate activity a week. Apple counts exercise minutes at "
        "about a brisk walk or harder, so they stand in for moderate-to-vigorous minutes. "
        "A guideline for behaviour, not a norm for a measurement."
    ),
}

WEEKS = 4
# A week needs most of its days known before "under 150" means anything. A
# week that has already passed 150 has met it however few days were seen.
MIN_KNOWN_DAYS = 5
# Share of the week's minutes carried by its two biggest days, above which the
# week counts as concentrated.
CONCENTRATED_SHARE = 0.5


def _known_exercise_days(start: date, end: date, tz_name: str | None) -> dict[date, float]:
    """Exercise minutes for each day the watch was demonstrably worn.

    A day with no exercise rollup is ambiguous: the watch was off, or it was on
    and nobody exercised. Heart-rate data on that day settles it — worn, so the
    honest figure is zero. With neither, the day is unknown, and stays out of
    the sum rather than being counted as a rest day nobody can vouch for.
    """
    exercise = {
        d.day: d.value for d in health_analysis.day_values("apple_exercise_time", start, end, tz_name)
    }
    worn = {
        d.day for d in health_analysis.day_values("heart_rate", start, end, tz_name)
    }
    known = dict(exercise)
    for day in worn:
        known.setdefault(day, 0.0)
    return known


def weekly_activity(as_of: date | None = None, tz_name: str | None = None) -> dict | None:
    """Exercise minutes over the last four rolling weeks, against the guideline.

    A rolling week rather than a calendar one, so "this week" on a Monday is
    not one day long. Reported as weeks met out of four rather than a streak:
    a streak one missed week resets to zero is how people stop, and the
    evidence is about the habit, not about never breaking it.
    """
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    start = as_of - timedelta(days=WEEKS * 7 - 1)
    known = _known_exercise_days(start, as_of, tz_name)
    if not any(v > 0 for v in known.values()):
        return None

    weeks = []
    for index in range(WEEKS):
        week_to = as_of - timedelta(days=index * 7)
        week_from = week_to - timedelta(days=6)
        days = [week_from + timedelta(days=i) for i in range(7)]
        values = [known[d] for d in days if d in known]
        minutes = sum(values)
        if minutes >= GUIDELINE["minutes_low"]:
            met = True
        elif len(values) >= MIN_KNOWN_DAYS:
            met = False
        else:
            met = None
        top_two = sum(sorted(values, reverse=True)[:2])
        weeks.append(
            {
                "from": week_from.isoformat(),
                "to": week_to.isoformat(),
                "minutes": round(minutes),
                "known_days": len(values),
                # Ten minutes: more than the stray minute a brisk walk to the
                # car earns, less than any deliberate session.
                "active_days": sum(1 for v in values if v >= 10),
                "met_guideline": met,
                "concentrated": bool(minutes and top_two / minutes >= CONCENTRATED_SHARE),
            }
        )

    current = weeks[0]
    if current["minutes"] >= GUIDELINE["minutes_high"]:
        band = "above_range"
    elif current["met_guideline"]:
        band = "in_range"
    elif current["met_guideline"] is False:
        band = "below_range"
    else:
        band = "unknown"

    if band == "unknown":
        observation = (
            f"{current['minutes']} exercise minutes recorded over the last 7 days, but only "
            f"{current['known_days']} of those days can be accounted for."
        )
    else:
        observation = f"{current['minutes']} exercise minutes over the last 7 days"
        if current["met_guideline"]:
            observation += ", within or above the 150–300 minute guideline"
            if current["concentrated"]:
                observation += (
                    " — over half of it on one or two days, which large studies associate "
                    "with much the same benefit as spreading it out"
                )
        else:
            observation += f", {GUIDELINE['minutes_low'] - current['minutes']} short of 150"
        observation += "."

    return {
        "as_of": as_of.isoformat(),
        "current": current,
        "weeks": weeks,
        "weeks_met": sum(1 for w in weeks if w["met_guideline"]),
        "weeks_counted": sum(1 for w in weeks if w["met_guideline"] is not None),
        "band": band,
        "observation": observation,
        "guideline": GUIDELINE,
        "note": (
            "Days the watch shows no sign of being worn are left out of the sum, not counted "
            "as rest days."
        ),
    }


# --------------------------------------------------------------------------
# Cardio fitness
# --------------------------------------------------------------------------

FITNESS_DAYS = 90


def cardio_fitness(as_of: date | None = None, tz_name: str | None = None) -> dict | None:
    """VO2 max over the last 90 days: the latest estimate and which way it is going.

    A trend, not a weekly comparison. The watch estimates it only during
    outdoor walks, runs and hikes, and it moves over months — so the seven
    days against twenty-eight every other metric gets is a window it barely
    has data in. A change smaller than one MET over the window is reported as
    steady: that is the unit the outcome research is measured in, and inside
    the watch's own error against a lab test.
    """
    if "vo2_max" not in health_analysis.available_metrics():
        return None
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    spec = health_analysis.spec_for("vo2_max")
    result = health_analysis.trend("vo2_max", days=FITNESS_DAYS, as_of=as_of, tz_name=tz_name)
    points = result["points"]
    if not points:
        return None

    first, latest = points[0], points[-1]
    slope = result["slope_per_week"]
    change = (slope / 7) * FITNESS_DAYS if slope is not None else None

    direction = result["trend_direction"]
    if direction in ("rising", "falling") and change is not None and abs(change) < spec.noise_floor:
        direction = "steady"
    elif direction == "flat":
        direction = "steady"

    return {
        "from": result["from"],
        "to": result["to"],
        "latest": latest["value"],
        "latest_date": latest["date"],
        "first": first["value"],
        "first_date": first["date"],
        "estimates": len(points),
        "unit": spec.unit,
        "change_over_window": _round(change, 1),
        "direction": direction,
        "fit_quality": result["fit_quality"],
        "note": (
            "Apple's estimate tends to read lower than a lab test and wanders by a few points; "
            "the direction over months means more than any one value. Changes under "
            f"{spec.noise_floor} {spec.unit} over the window are reported as steady."
        ),
    }


# --------------------------------------------------------------------------
# Everything together
# --------------------------------------------------------------------------


def daylight(as_of: date | None = None, tz_name: str | None = None) -> dict | None:
    if "time_in_daylight" not in health_analysis.available_metrics():
        return None
    comparison = health_analysis.compare_to_baseline(
        "time_in_daylight", as_of=as_of, tz_name=tz_name
    )
    if not comparison["current"]["valid_days"] and not comparison["baseline"]["valid_days"]:
        return None
    return comparison


def signals(as_of: date | None = None, tz_name: str | None = None) -> dict:
    """Every lifestyle signal there is data for. A section with nothing behind
    it is `None` rather than an empty shape, so a client can leave it off the
    screen instead of drawing a card that says nothing."""
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    # The night that ended the morning after `as_of` — this morning by default,
    # and the matching night when a past date was asked for, rather than today's
    # night beside a month-old week.
    overnight = overnight_vitals(morning=as_of + timedelta(days=1), tz_name=tz_name)
    regularity = sleep_regularity(as_of=as_of, tz_name=tz_name)
    return {
        "as_of": as_of.isoformat(),
        "timezone": str(analytics.zone(tz_name)),
        "overnight": overnight if overnight["metrics"] else None,
        "sleep_regularity": regularity if regularity["valid_pairs"] else None,
        "activity": weekly_activity(as_of=as_of, tz_name=tz_name),
        "daylight": daylight(as_of=as_of, tz_name=tz_name),
        "cardio_fitness": cardio_fitness(as_of=as_of, tz_name=tz_name),
        "note": (
            "Measurements judged against this person's own range, plus two published "
            "references (the WHO activity guideline and a sleep-regularity cohort) given as "
            "context. None of it is a score or a diagnosis."
        ),
    }
