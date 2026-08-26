"""Which of this person's signals move together, and which only look like they do.

The hard part of a correlation engine is not the arithmetic. It is that with
thirteen metrics there are seventy-eight pairs, and at the usual 5% threshold
four of them will look significant on pure noise. An engine that sweeps every
pair and reports what clears p < 0.05 is a machine for generating confident
nonsense — and health nonsense in particular, because the reader already has a
story ready for whatever it prints.

Four things keep this honest:

**The hypotheses are fixed, not fished.** `CANDIDATES` is a written-down list of
pairs with a reason each. Nothing is discovered by searching; a pair either was
worth asking about before the data was seen or it is not in the list.

**Everything tested is reported.** Suppressing the pairs that came back flat
would turn the surviving ones into "the correlations in your data" rather than
"the four we asked about, of which one stood out". Each result carries its rho,
its n, and its p, whether or not it survived.

**Correction across the run.** Holm–Bonferroni over every pair tested, so
`significant` means significant given how many questions were asked, not given
one question asked in isolation.

**A contrast in real units.** A rho of 0.34 tells a person nothing. "On your ten
longest nights HRV averaged 48 ms; on the ten shortest, 41 ms" is the same fact
in a form they can check against their own memory.

Two limits are worth stating plainly rather than burying. Daily health series are
autocorrelated — today's resting heart rate resembles yesterday's — which makes
every p-value here optimistic; and an association between two of a person's own
metrics can always be produced by a third thing neither of them measures, which
is why every result ships with the confounders somebody would have to rule out.
"""

import math
import statistics
from dataclasses import dataclass, field
from datetime import date, timedelta
from statistics import NormalDist

from . import health_analysis

# Long by default. At four weeks, Holm across a dozen pairs needs a rho around
# 0.5 before it will call anything significant, which for ordinary health signals
# means the engine reports nothing for months. Ninety days is where the test
# starts being able to see an effect of the size these relationships actually have.
DEFAULT_DAYS = 90
MAX_DAYS = 365

# Below this there is no point computing a rho at all: the confidence interval
# spans most of the range it could take.
MIN_PAIRED_DAYS = 14
MIN_PAIRED_WEEKS = 6

# A week needs most of itself present before its mean is allowed to stand for it,
# for the same reason a 7-day average needs four of its days.
MIN_DAYS_PER_WEEK = 4

ALPHA = 0.05


# --------------------------------------------------------------------------
# Statistics
# --------------------------------------------------------------------------


def _ranks(values: list[float]) -> list[float]:
    """Ranks with ties averaged.

    Ties are not an edge case here: exercise minutes and workout minutes are zero
    on most days, and ranking those arbitrarily rather than equally invents an
    ordering the data does not contain.
    """
    order = sorted(range(len(values)), key=lambda index: values[index])
    ranks = [0.0] * len(values)
    position = 0
    while position < len(order):
        last = position
        while last + 1 < len(order) and values[order[last + 1]] == values[order[position]]:
            last += 1
        average = (position + last) / 2 + 1
        for index in range(position, last + 1):
            ranks[order[index]] = average
        position = last + 1
    return ranks


def _pearson(xs: list[float], ys: list[float]) -> float | None:
    mean_x = statistics.fmean(xs)
    mean_y = statistics.fmean(ys)
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    sxx = sum((x - mean_x) ** 2 for x in xs)
    syy = sum((y - mean_y) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def spearman(xs: list[float], ys: list[float]) -> float | None:
    """Rank correlation.

    Rank rather than Pearson because these relationships are not expected to be
    straight lines and one bad night should not set the slope. It is the same
    reasoning that puts a median absolute deviation in `health_analysis` instead
    of a standard deviation.
    """
    if len(xs) != len(ys) or len(xs) < 3:
        return None
    return _pearson(_ranks(xs), _ranks(ys))


def p_value(rho: float | None, n: int) -> float | None:
    """Two-sided p for a rank correlation, via the Fisher transform.

    An approximation, and named as one: with no scipy here the alternative is
    hand-rolling an incomplete beta function, and the normal approximation is
    accurate enough at these sample sizes to decide "worth mentioning" from "not".
    It is not accurate enough to quote to three decimal places, which is why
    nothing downstream does.
    """
    if rho is None or n < 6:
        return None
    clamped = max(-0.999999, min(0.999999, rho))
    z = math.atanh(clamped) * math.sqrt(n - 3)
    return 2 * NormalDist().cdf(-abs(z))


def holm(p_values: list[float | None], alpha: float = ALPHA) -> list[bool]:
    """Holm–Bonferroni: which of these survive, given that all of them were asked.

    Step-down rather than plain Bonferroni because plain Bonferroni over a dozen
    pairs discards real effects along with the false ones. Holm stops at the first
    failure by construction — everything weaker than a hypothesis that failed
    fails too.
    """
    usable = [(index, p) for index, p in enumerate(p_values) if p is not None]
    flags = [False] * len(p_values)
    total = len(usable)
    for rank, (index, p) in enumerate(sorted(usable, key=lambda pair: pair[1])):
        if p <= alpha / (total - rank):
            flags[index] = True
        else:
            break
    return flags


def strength(rho: float | None) -> str:
    if rho is None:
        return "none"
    magnitude = abs(rho)
    if magnitude < 0.2:
        return "negligible"
    if magnitude < 0.4:
        return "weak"
    if magnitude < 0.6:
        return "moderate"
    return "strong"


# --------------------------------------------------------------------------
# Signals
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Signal:
    """One day-indexed series that can go on either side of a pair."""

    key: str
    label: str
    unit: str
    source: str  # "metric" | "bedtime" | "workout_minutes"
    slug: str | None = None
    decimals: int = 1


SIGNALS: dict[str, Signal] = {
    signal.key: signal
    for signal in [
        Signal("sleep_hours", "Sleep", "h", "metric", slug="sleep_analysis", decimals=2),
        Signal("hrv", "HRV", "ms", "metric", slug="heart_rate_variability_sdnn"),
        Signal("resting_hr", "Resting heart rate", "count/min", "metric",
               slug="resting_heart_rate"),
        Signal("respiratory_rate", "Respiratory rate", "count/min", "metric",
               slug="respiratory_rate"),
        Signal("steps", "Steps", "count", "metric", slug="step_count", decimals=0),
        Signal("exercise_minutes", "Exercise minutes", "min", "metric",
               slug="apple_exercise_time", decimals=0),
        Signal("active_energy", "Active energy", "kcal", "metric",
               slug="active_energy_burned", decimals=0),
        Signal("weight", "Weight", "kg", "metric", slug="body_mass", decimals=2),
        Signal("intake", "Logged energy", "kcal", "metric",
               slug="dietary_energy_consumed", decimals=0),
        Signal("caffeine", "Logged caffeine", "mg", "metric", slug="dietary_caffeine",
               decimals=0),
        Signal("protein", "Logged protein", "g", "metric", slug="dietary_protein", decimals=0),
        # Derived. Bedtime is minutes since noon so it stays continuous across
        # midnight; a larger number is a later night.
        Signal("bedtime", "Bedtime", "min after noon", "bedtime", decimals=0),
        Signal("workout_minutes", "Workout minutes", "min", "workout_minutes", decimals=0),
    ]
}


def _series(
    signal: Signal, days: int, as_of: date, tz_name: str | None
) -> dict[date, float]:
    if signal.source == "bedtime":
        return health_analysis.bedtime_series(days, as_of=as_of, tz_name=tz_name)
    if signal.source == "workout_minutes":
        return health_analysis.workout_minutes_series(days, as_of=as_of, tz_name=tz_name)
    start_day = as_of - timedelta(days=days - 1)
    return {
        value.day: value.value
        for value in health_analysis.day_values(signal.slug, start_day, as_of, tz_name)
    }


# --------------------------------------------------------------------------
# The questions worth asking
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Candidate:
    """One pre-registered question.

    `lag_days` shifts the *outcome* forward: outcome[day + lag] against
    driver[day]. Reading the lags requires one piece of context — a night of
    sleep is filed under the morning it ended, so last night's sleep and this
    morning's HRV are already the same calendar day and need no lag, while today's
    steps and tonight's sleep are a day apart.
    """

    driver: str
    outcome: str
    question: str
    lag_days: int = 0
    resolution: str = "day"
    confounders: tuple[str, ...] = field(default_factory=tuple)

    @property
    def key(self) -> str:
        suffix = f"+{self.lag_days}d" if self.lag_days else ""
        return f"{self.driver}->{self.outcome}{suffix}"


_ILLNESS = "an illness or infection, which moves heart rate, sleep and activity together"
_ALCOHOL = "alcohol, which lowers HRV and fragments sleep without appearing in any of this data"
_WORK = "a heavy week at work, which shortens sleep and reduces activity at the same time"
_TRAVEL = "travel or a timezone change"

CANDIDATES: list[Candidate] = [
    # Sleep is filed under the morning it ended and overnight HRV samples land on
    # that same morning, so these two are already aligned. A lag here would
    # compare a night against the morning after the one it belongs to.
    Candidate(
        "sleep_hours", "hrv",
        "Does a longer night go with higher heart-rate variability?",
        confounders=(_ALCOHOL, _ILLNESS, "late or large evening meals"),
    ),
    Candidate(
        "sleep_hours", "resting_hr",
        "Does a longer night go with a lower resting heart rate?",
        confounders=(_ALCOHOL, _ILLNESS, "a warm room"),
    ),
    Candidate(
        "sleep_hours", "exercise_minutes",
        "Does how much you slept go with how much you exercise that day?",
        confounders=(_WORK, "weekends, which change both at once"),
    ),
    Candidate(
        "sleep_hours", "steps",
        "Does how much you slept go with how much you walk that day?",
        confounders=(_WORK, "weather", "weekends, which change both at once"),
    ),
    # Bedtime and sleep length share the morning bucket too.
    Candidate(
        "bedtime", "sleep_hours",
        "Does going to bed later go with sleeping less?",
        confounders=("a fixed wake time, which mechanically shortens a late night",),
    ),
    # Today's exertion, tomorrow's recovery.
    Candidate(
        "exercise_minutes", "hrv",
        "Does exercising more show up in the next day's HRV?",
        lag_days=1,
        confounders=(_ALCOHOL, "hard sessions clustering on the same days each week"),
    ),
    Candidate(
        "workout_minutes", "hrv",
        "Does a longer workout show up in the next day's HRV?",
        lag_days=1,
        confounders=(_ALCOHOL, "how hard the session was, which minutes do not capture"),
    ),
    Candidate(
        "workout_minutes", "hrv",
        "Is HRV still affected two days after a longer workout?",
        lag_days=2,
        confounders=("a second session in between", _ALCOHOL),
    ),
    Candidate(
        "workout_minutes", "resting_hr",
        "Does a longer workout show up in the next day's resting heart rate?",
        lag_days=1,
        confounders=(_ILLNESS, _ALCOHOL),
    ),
    # Today's steps, tonight's sleep — a day apart, because tonight's sleep is
    # filed under tomorrow morning.
    Candidate(
        "steps", "sleep_hours",
        "Does walking more go with sleeping longer that night?",
        lag_days=1,
        confounders=(_WORK, "an early start the next day", _TRAVEL),
    ),
    Candidate(
        "caffeine", "sleep_hours",
        "Does logged caffeine go with sleeping less that night?",
        lag_days=1,
        confounders=("when in the day it was drunk, which this data does not record",
                     "caffeine drunk to compensate for an already short night"),
    ),
    Candidate(
        "caffeine", "hrv",
        "Does logged caffeine go with the next morning's HRV?",
        lag_days=1,
        confounders=("when in the day it was drunk", _ALCOHOL),
    ),
    # Weight answers over weeks, not days. Pairing it daily would mostly measure
    # hydration.
    Candidate(
        "steps", "weight",
        "Do weeks with more walking go with a lower weight?",
        resolution="week",
        confounders=("food intake, which is the larger term and separately logged",
                     "glycogen and hydration, which move weight faster than fat does"),
    ),
    Candidate(
        "intake", "weight",
        "Do weeks with more logged energy go with a higher weight?",
        resolution="week",
        confounders=("unlogged food, which is invisible here",
                     "glycogen and hydration", "how much you moved that week"),
    ),
]


# --------------------------------------------------------------------------
# Pairing
# --------------------------------------------------------------------------


def _pair_days(
    driver: dict[date, float], outcome: dict[date, float], lag: int
) -> list[tuple[date, float, float]]:
    return [
        (day, value, outcome[day + timedelta(days=lag)])
        for day, value in sorted(driver.items())
        if day + timedelta(days=lag) in outcome
    ]


def _to_weeks(series: dict[date, float]) -> dict[date, float]:
    """Weekly means, keyed by the Monday, and only for weeks that are mostly there.

    Non-overlapping calendar weeks rather than a rolling mean: overlapping windows
    share most of their days, which makes consecutive points near-copies of each
    other and inflates any significance computed from them.
    """
    buckets: dict[date, list[float]] = {}
    for day, value in series.items():
        monday = day - timedelta(days=day.weekday())
        buckets.setdefault(monday, []).append(value)
    return {
        monday: statistics.fmean(values)
        for monday, values in buckets.items()
        if len(values) >= MIN_DAYS_PER_WEEK
    }


def _contrast(
    pairs: list[tuple[date, float, float]],
    driver: Signal,
    outcome: Signal,
    point_name: str,
) -> dict | None:
    """The same finding in units, by comparing the top third against the bottom.

    Terciles rather than a median split so the two groups are actually different
    from each other; with a median split on a metric that barely varies, "high"
    and "low" are the same days with different labels.
    """
    if len(pairs) < 9:
        return None
    ordered = sorted(pairs, key=lambda row: row[1])
    size = max(3, len(ordered) // 3)
    low, high = ordered[:size], ordered[-size:]

    def mean(rows, index):
        return statistics.fmean([row[index] for row in rows])

    high_outcome = mean(high, 2)
    low_outcome = mean(low, 2)
    return {
        "group_size": size,
        "driver_high_mean": round(mean(high, 1), driver.decimals),
        "driver_low_mean": round(mean(low, 1), driver.decimals),
        "outcome_on_high_days": round(high_outcome, outcome.decimals),
        "outcome_on_low_days": round(low_outcome, outcome.decimals),
        "difference": round(high_outcome - low_outcome, outcome.decimals),
        "description": (
            f"On the {size} highest-{driver.label.lower()} {point_name} "
            f"({round(mean(high, 1), driver.decimals)} {driver.unit} on average), "
            f"{outcome.label.lower()} averaged "
            f"{round(high_outcome, outcome.decimals)} {outcome.unit}; on the {size} "
            f"lowest ({round(mean(low, 1), driver.decimals)} {driver.unit}), "
            f"{round(low_outcome, outcome.decimals)} {outcome.unit}."
        ),
    }


def _examine(
    candidate: Candidate, days: int, as_of: date, tz_name: str | None
) -> dict:
    driver = SIGNALS[candidate.driver]
    outcome = SIGNALS[candidate.outcome]

    # Weekly candidates need a longer reach to reduce to six usable weeks, and
    # the lag is left at zero: a week-to-week relationship offset by one day is
    # not a different question.
    driver_series = _series(driver, days, as_of, tz_name)
    outcome_series = _series(outcome, days + candidate.lag_days, as_of, tz_name)

    result = {
        "pair": candidate.key,
        "question": candidate.question,
        "driver": {"signal": driver.key, "label": driver.label, "unit": driver.unit},
        "outcome": {"signal": outcome.key, "label": outcome.label, "unit": outcome.unit},
        "lag_days": candidate.lag_days,
        "resolution": candidate.resolution,
        "confounders": list(candidate.confounders),
    }

    if candidate.resolution == "week":
        weekly_driver = _to_weeks(driver_series)
        weekly_outcome = _to_weeks(outcome_series)
        pairs = [
            (monday, value, weekly_outcome[monday])
            for monday, value in sorted(weekly_driver.items())
            if monday in weekly_outcome
        ]
        minimum, unit_name = MIN_PAIRED_WEEKS, "weeks"
    else:
        pairs = _pair_days(driver_series, outcome_series, candidate.lag_days)
        minimum, unit_name = MIN_PAIRED_DAYS, "days"

    result["paired_points"] = len(pairs)
    result["point_unit"] = unit_name

    if len(pairs) < minimum:
        result.update(
            {
                "rho": None,
                "p_value": None,
                "strength": "none",
                "testable": False,
                "reason": (
                    f"only {len(pairs)} "
                    f"{unit_name if len(pairs) != 1 else unit_name.rstrip('s')} "
                    f"{'have' if len(pairs) != 1 else 'has'} both "
                    f"{driver.label.lower()} and {outcome.label.lower()} recorded; "
                    f"at least {minimum} are needed"
                ),
            }
        )
        return result

    xs = [row[1] for row in pairs]
    ys = [row[2] for row in pairs]
    rho = spearman(xs, ys)
    # `p or 1.0` here would be a real bug rather than a style point: a strong
    # correlation produces a p of 0.0, which is falsy, so the fallback would
    # rewrite the most convincing results in the payload as the least.
    p = p_value(rho, len(pairs))
    if rho is None:
        result.update(
            {
                "rho": None,
                "p_value": None,
                "strength": "none",
                "testable": False,
                "reason": (
                    f"{driver.label.lower()} or {outcome.label.lower()} does not vary over "
                    "this period, so there is nothing to correlate"
                ),
            }
        )
        return result

    result.update(
        {
            "from": pairs[0][0].isoformat(),
            "to": pairs[-1][0].isoformat(),
            "rho": round(rho, 2),
            "p_value": None if p is None else round(p, 6),
            "direction": "together" if rho > 0 else "opposite",
            "strength": strength(rho),
            "testable": True,
            "contrast": _contrast(pairs, driver, outcome, unit_name),
        }
    )
    return result


def discover(
    days: int = DEFAULT_DAYS,
    as_of: date | None = None,
    tz_name: str | None = None,
) -> dict:
    """Every pre-registered pair, tested and corrected together."""
    as_of = as_of or health_analysis.last_complete_day(tz_name)
    days = max(MIN_PAIRED_DAYS, min(days, MAX_DAYS))

    results = [_examine(candidate, days, as_of, tz_name) for candidate in CANDIDATES]

    testable = [r for r in results if r["testable"]]
    flags = holm([r["p_value"] for r in testable])
    for result, significant in zip(testable, flags):
        result["significant"] = bool(significant)
    for result in results:
        result.setdefault("significant", False)

    found = sorted(
        (r for r in testable if r["significant"]),
        key=lambda r: -abs(r["rho"]),
    )
    return {
        "from": (as_of - timedelta(days=days - 1)).isoformat(),
        "to": as_of.isoformat(),
        "window_days": days,
        "pairs_tested": len(testable),
        "pairs_skipped": len(results) - len(testable),
        "associations_found": len(found),
        "associations": found,
        "all_pairs": results,
        "method": {
            "statistic": "Spearman rank correlation",
            "p_value": "two-sided, from the Fisher transform — an approximation, good "
            "enough to sort worth-mentioning from not, not to quote precisely",
            "correction": f"Holm-Bonferroni across the {len(testable)} pairs tested, "
            f"alpha {ALPHA}",
            "lag": "positive lag means the outcome is taken that many days after the "
            "driver. Sleep is filed under the morning it ended, so last night's sleep "
            "and this morning's HRV are the same day and need no lag.",
            "hypotheses": "a fixed list, written down in advance. Nothing here was found "
            "by searching every pair of metrics, which at this alpha would produce a "
            "false finding for every twenty questions asked.",
        },
        "limitations": [
            "These are associations between two of this person's own metrics. Neither one "
            "is shown to cause the other, and a third thing that neither measures can "
            "produce the pattern on its own — which is what the confounders on each pair "
            "are there to name.",
            "Health measurements taken day after day resemble each other, and that "
            "resemblance is not corrected for here. Every p-value is therefore optimistic; "
            "a marginal result is weaker than it looks.",
            "A pair reported as not significant has not been shown to be unrelated. It "
            "means this window could not distinguish it from noise.",
        ],
    }
