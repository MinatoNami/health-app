"""The only way the model can reach health data.

§5 of the integration notes: no database credentials, no SQL, no free-form
query. A fixed set of read-only functions, each returning already-computed
figures with their units, windows, valid-day counts, and confidence attached.

Two properties are worth preserving if this list grows:

* **Every result carries its own caveats.** A tool that returns a bare number
  invites the model to present it as fact. Returning `{value, unit, valid_days,
  confidence, confidence_reason}` makes the hedge part of the data rather than
  something the model has to remember to add.
* **Arguments are validated here, not trusted.** A model will eventually ask for
  a 4,000-day window or a metric that does not exist. Clamping and rejecting at
  this boundary means a malformed call costs one turn, not a slow query.
"""

from datetime import date, timedelta

from .. import correlations, health_analysis, patterns
from ..models import Goal

MAX_WINDOW_DAYS = 365
MAX_WORKOUTS = 25


class ToolError(ValueError):
    """A bad call. Returned to the model as a result, not raised to the user —
    it can read the message and try again with valid arguments."""


def _days(value, default: int, maximum: int = MAX_WINDOW_DAYS) -> int:
    try:
        days = int(value) if value is not None else default
    except (TypeError, ValueError):
        raise ToolError(f"days must be a whole number, got {value!r}") from None
    return max(1, min(days, maximum))


def _metric(value) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ToolError("metric is required")
    slug = value.strip()
    if slug not in health_analysis.METRICS:
        raise ToolError(
            f"unknown metric {slug!r}. Call list_available_metrics first; "
            f"this server knows: {', '.join(sorted(health_analysis.METRICS))}"
        )
    return slug


def _date(value, name: str) -> date:
    try:
        return date.fromisoformat(str(value))
    except (TypeError, ValueError):
        raise ToolError(f"{name} must be a date as YYYY-MM-DD, got {value!r}") from None


# --------------------------------------------------------------------------
# Implementations
# --------------------------------------------------------------------------


def list_available_metrics(tz_name: str | None = None, **_) -> dict:
    present = health_analysis.available_metrics()
    return {
        "metrics": [
            {
                "metric": slug,
                "label": health_analysis.METRICS[slug].label,
                "unit": health_analysis.METRICS[slug].unit,
                "daily_aggregation": health_analysis.METRICS[slug].daily,
            }
            for slug in present
        ],
        "note": "Only these metrics have data. Anything else has not been recorded.",
    }


def get_health_overview(days: int | None = None, tz_name: str | None = None, **_) -> dict:
    """The full snapshot: every headline metric against its own baseline."""
    snapshot = health_analysis.snapshot(tz_name=tz_name)
    # The snapshot is large; trim the per-day detail the model does not need to
    # reason about. Long tool results crowd out the conversation on a local
    # model with a modest context window.
    snapshot["workouts"] = {
        k: v for k, v in snapshot["workouts"].items() if k != "recent"
    }
    if snapshot.get("sleep"):
        snapshot["sleep"] = {k: v for k, v in snapshot["sleep"].items() if k != "nights"}
    if snapshot.get("nutrition"):
        snapshot["nutrition"] = {
            k: v for k, v in snapshot["nutrition"].items() if k != "days"
        }
    snapshot["data_quality"] = [
        {
            "metric": q["metric_slug"],
            "quality": q["quality"],
            "valid_days": q["valid_days"],
            "coverage": q["coverage"],
            "notes": q["notes"],
        }
        for q in snapshot["data_quality"]
    ]
    return snapshot


def get_metric_trend(
    metric: str | None = None, days: int | None = None, tz_name: str | None = None, **_
) -> dict:
    slug = _metric(metric)
    window = _days(days, 90)
    result = health_analysis.trend(slug, days=window, tz_name=tz_name)
    # Daily points are for charts, not for a model to re-derive averages from —
    # that is exactly the raw-row arithmetic this architecture exists to avoid.
    points = result.pop("points")
    result["daily_points_omitted"] = len(points)
    result["moving_average_7"] = result["moving_average_7"][-14:]
    result["moving_average_28"] = result["moving_average_28"][-14:]
    result["baseline_comparison"] = health_analysis.compare_to_baseline(slug, tz_name=tz_name)
    return result


def compare_periods(
    metric: str | None = None,
    period_a_from: str | None = None,
    period_a_to: str | None = None,
    period_b_from: str | None = None,
    period_b_to: str | None = None,
    tz_name: str | None = None,
    **_,
) -> dict:
    slug = _metric(metric)
    a_from = _date(period_a_from, "period_a_from")
    a_to = _date(period_a_to, "period_a_to")
    b_from = _date(period_b_from, "period_b_from")
    b_to = _date(period_b_to, "period_b_to")
    for start, end, name in ((a_from, a_to, "period_a"), (b_from, b_to, "period_b")):
        if start > end:
            raise ToolError(f"{name} starts after it ends")
        if (end - start).days > MAX_WINDOW_DAYS:
            raise ToolError(f"{name} is longer than {MAX_WINDOW_DAYS} days")
    return health_analysis.compare_periods(slug, a_from, a_to, b_from, b_to, tz_name=tz_name)


def get_recent_workouts(
    days: int | None = None, limit: int | None = None, tz_name: str | None = None, **_
) -> dict:
    count = _days(limit, 10, maximum=MAX_WORKOUTS)
    return health_analysis.workouts(days=_days(days, 28), limit=count, tz_name=tz_name)


def get_sleep_summary(days: int | None = None, tz_name: str | None = None, **_) -> dict:
    window = _days(days, 14, maximum=90)
    summary = health_analysis.sleep_summary(days=window, tz_name=tz_name)
    summary["nights"] = summary["nights"][-14:]
    summary["baseline_comparison"] = health_analysis.compare_to_baseline(
        "sleep_analysis", tz_name=tz_name
    )
    return summary


def get_nutrition_summary(days: int | None = None, tz_name: str | None = None, **_) -> dict:
    """Food and drink as it was logged.

    Kept as its own tool rather than left to `get_metric_trend` on each nutrient
    because the three day-counts — logged, partially logged, not logged — are the
    part a model gets wrong on its own. Handed a bare average it will describe a
    week of forgotten lunches as a week of eating less, which is a claim about
    somebody's health built entirely out of their record-keeping.
    """
    window = _days(days, 14, maximum=90)
    summary = health_analysis.nutrition_summary(days=window, tz_name=tz_name)
    summary["days"] = summary["days"][-14:]
    return summary


def get_data_quality(
    metric: str | None = None, days: int | None = None, tz_name: str | None = None, **_
) -> dict:
    window = _days(days, 35)
    if metric:
        return health_analysis.data_quality(_metric(metric), days=window, tz_name=tz_name)
    return {
        "window_days": window,
        "metrics": [
            health_analysis.data_quality(slug, days=window, tz_name=tz_name)
            for slug in health_analysis.available_metrics()
        ],
    }


def get_goals(tz_name: str | None = None, **_) -> dict:
    """The user's own targets, with measured progress against them.

    Progress is computed here rather than left to the model: "you hit your step
    goal four times" is a claim that has to be countable, not inferred.
    """
    goals = []
    for goal in Goal.objects.filter(active=True).order_by("metric_slug"):
        spec = health_analysis.METRICS.get(goal.metric_slug)
        entry = {
            "metric": goal.metric_slug,
            "label": goal.label or (spec.label if spec else goal.metric_slug),
            "target": goal.target_value,
            "unit": goal.unit or (spec.unit if spec else ""),
            "cadence": goal.cadence,
            "note": goal.note,
        }
        if spec:
            entry["progress"] = goal_progress(goal, tz_name=tz_name)
        goals.append(entry)
    return {"goals": goals, "count": len(goals)}


def goal_progress(goal: Goal, tz_name: str | None = None) -> dict:
    """Days met in the current window, plus the streak."""
    as_of = health_analysis.last_complete_day(tz_name)
    window = 7 if goal.cadence == Goal.Cadence.DAILY else 28
    values = health_analysis.day_values(
        goal.metric_slug, as_of - timedelta(days=window - 1), as_of, tz_name
    )
    met = [d for d in values if d.value >= goal.target_value]
    streak = health_analysis.streak(goal.metric_slug, goal.target_value, as_of=as_of, tz_name=tz_name)
    return {
        "window_days": window,
        "days_with_data": len(values),
        "days_met": len(met),
        "current_streak_days": streak["current_streak_days"],
        "longest_streak_days": streak["longest_streak_days"],
        "as_of": as_of.isoformat(),
    }


def get_correlations(days: int | None = None, tz_name: str | None = None, **_) -> dict:
    """Which of this person's signals move together.

    Returns the pairs that survived correction first, then every pair that was
    tested. Both halves matter: handed only the survivors, a model presents them
    as "the relationships in your data" rather than as one result out of fourteen
    questions asked.
    """
    window = _days(days, correlations.DEFAULT_DAYS, maximum=correlations.MAX_DAYS)
    result = correlations.discover(days=window, tz_name=tz_name)
    # The full per-pair list is long and mostly nulls on a short history. The
    # model gets the findings, the count of what was tested, and the pairs that
    # were skipped for want of data — not fourteen objects of empty fields.
    result["all_pairs"] = [
        {
            "pair": pair["pair"],
            "question": pair["question"],
            "rho": pair["rho"],
            "strength": pair["strength"],
            "paired_points": pair["paired_points"],
            "significant": pair["significant"],
            "reason": pair.get("reason"),
        }
        for pair in result["all_pairs"]
    ]
    return result


def get_patterns(days: int | None = None, tz_name: str | None = None, **_) -> dict:
    """Weekly rhythms: weekends, and standout weekdays."""
    window = _days(days, patterns.DEFAULT_DAYS, maximum=patterns.MAX_DAYS)
    return patterns.discover(days=window, tz_name=tz_name)


def get_anomalies(tz_name: str | None = None, **_) -> dict:
    found = health_analysis.anomalies(tz_name=tz_name)
    return {
        "anomalies": found,
        "count": len(found),
        "note": (
            "Each entry means a value sits outside this person's own recent range. "
            "It is not a diagnosis and does not identify a cause."
        ),
    }


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------

_METRIC_ARG = {
    "type": "string",
    "description": "Metric slug, e.g. step_count, sleep_analysis, resting_heart_rate. "
    "Call list_available_metrics if unsure.",
}

DEFINITIONS = [
    {
        "name": "list_available_metrics",
        "description": "List the metrics this person actually has data for. Call this first "
        "if a question names a metric you are not sure exists.",
        "parameters": {"type": "object", "properties": {}},
        "fn": list_available_metrics,
    },
    {
        "name": "get_health_overview",
        "description": "Health snapshot: every headline metric over the last 7 days against "
        "the 28 days before it, with valid-day counts, confidence, sleep, and workouts. "
        "Start here for broad questions.",
        "parameters": {"type": "object", "properties": {}},
        "fn": get_health_overview,
    },
    {
        "name": "get_metric_trend",
        "description": "One metric over time: 7- and 28-day moving averages, week-over-week "
        "change, trend direction, and the current-versus-baseline comparison.",
        "parameters": {
            "type": "object",
            "properties": {
                "metric": _METRIC_ARG,
                "days": {
                    "type": "integer",
                    "description": "Window length in days, 1–365. Defaults to 90.",
                },
            },
            "required": ["metric"],
        },
        "fn": get_metric_trend,
    },
    {
        "name": "compare_periods",
        "description": "Compare one metric between two explicit date ranges. Returns "
        "comparable=false when either period has too little data to compare.",
        "parameters": {
            "type": "object",
            "properties": {
                "metric": _METRIC_ARG,
                "period_a_from": {"type": "string", "description": "YYYY-MM-DD"},
                "period_a_to": {"type": "string", "description": "YYYY-MM-DD"},
                "period_b_from": {"type": "string", "description": "YYYY-MM-DD"},
                "period_b_to": {"type": "string", "description": "YYYY-MM-DD"},
            },
            "required": [
                "metric",
                "period_a_from",
                "period_a_to",
                "period_b_from",
                "period_b_to",
            ],
        },
        "fn": compare_periods,
    },
    {
        "name": "get_sleep_summary",
        "description": "Sleep duration, typical bedtime and wake time, schedule consistency, "
        "and per-night detail.",
        "parameters": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "description": "Nights to cover, 1–90. Defaults to 14."}
            },
        },
        "fn": get_sleep_summary,
    },
    {
        "name": "get_nutrition_summary",
        "description": "Food and drink logged in an app: energy, protein, carbohydrates, fat, "
        "fibre, sugar, sodium, water, and how logged intake compares with estimated energy "
        "burned over the same days. Use this for any question about eating, intake, "
        "macronutrients, or hydration. Counts days with a full log, days with a partial log, "
        "and days with no log separately — a day with no log is a day nobody wrote down, "
        "never a day of not eating.",
        "parameters": {
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Days to cover, 1–90. Defaults to 14.",
                }
            },
        },
        "fn": get_nutrition_summary,
    },
    {
        "name": "get_recent_workouts",
        "description": "Recorded workouts: how many, how often per week, which activities, "
        "and the most recent sessions.",
        "parameters": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "description": "Window in days. Defaults to 28."},
                "limit": {"type": "integer", "description": "Sessions to list, up to 25."},
            },
        },
        "fn": get_recent_workouts,
    },
    {
        "name": "get_data_quality",
        "description": "How complete and trustworthy the recent data is: valid days, coverage, "
        "gaps, manual entries, and which devices wrote it. Use this before claiming a trend.",
        "parameters": {
            "type": "object",
            "properties": {
                "metric": {**_METRIC_ARG, "description": _METRIC_ARG["description"]
                           + " Omit for every metric."},
                "days": {"type": "integer", "description": "Window in days. Defaults to 35."},
            },
        },
        "fn": get_data_quality,
    },
    {
        "name": "get_goals",
        "description": "The person's own targets and measured progress against them.",
        "parameters": {"type": "object", "properties": {}},
        "fn": get_goals,
    },
    {
        "name": "get_correlations",
        "description": "Which of this person's signals move together — sleep and HRV, "
        "workouts and next-day recovery, walking and sleep, logged energy and weight. Use "
        "for any question about whether one thing affects another. Every pair is a "
        "pre-registered question tested over a long window and corrected for how many were "
        "asked; each result carries the confounders that could produce it instead. These "
        "are associations, never causes.",
        "parameters": {
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Window in days, up to 365. Defaults to 90, and shorter "
                    "windows rarely find anything.",
                }
            },
        },
        "fn": get_correlations,
    },
    {
        "name": "get_patterns",
        "description": "Recurring weekly rhythms: whether weekends differ from weekdays, "
        "and whether any single weekday stands out, for sleep, steps, exercise, resting "
        "heart rate, HRV and logged energy. Use for questions about habits and routines.",
        "parameters": {
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Window in days, up to 365. Defaults to 90.",
                }
            },
        },
        "fn": get_patterns,
    },
    {
        "name": "get_anomalies",
        "description": "Metrics currently sitting well outside this person's own recent range, "
        "sustained over several days.",
        "parameters": {"type": "object", "properties": {}},
        "fn": get_anomalies,
    },
]

REGISTRY = {definition["name"]: definition["fn"] for definition in DEFINITIONS}


def openai_schema() -> list[dict]:
    """Tool definitions in the shape LM Studio and the OpenAI API both expect."""
    return [
        {
            "type": "function",
            "function": {
                "name": d["name"],
                "description": d["description"],
                "parameters": d["parameters"],
            },
        }
        for d in DEFINITIONS
    ]


def call(name: str, arguments: dict, tz_name: str | None = None) -> dict:
    """Dispatch. Unknown names and bad arguments come back as results the model
    can read and correct, because raising would end the turn over something it
    could have fixed itself."""
    fn = REGISTRY.get(name)
    if fn is None:
        return {
            "error": f"no such tool {name!r}",
            "available": sorted(REGISTRY),
        }
    if not isinstance(arguments, dict):
        return {"error": "arguments must be a JSON object"}
    try:
        return fn(tz_name=tz_name, **arguments)
    except ToolError as exc:
        return {"error": str(exc)}
    except health_analysis.UnknownMetric as exc:
        return {"error": str(exc)}
