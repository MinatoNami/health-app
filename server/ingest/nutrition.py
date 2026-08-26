"""Nutrition: what was logged, not what was eaten.

Every other metric in this system is written by a sensor. Nutrition is typed into
an app by a person, and that one difference drives everything in this module.

**A gap is not a fast.** A day with no food log is a day nobody wrote down. Every
other metric can treat a missing day as a missing day and move on; here the
missing day looks exactly like a day of eating nothing, which is the single most
dangerous reading this data supports. So days are counted as *logged* or *not
logged*, never as zero.

**A short day is usually a short log.** Breakfast entered and lunch forgotten
produces a 400 kcal Tuesday. Averaging that in reports a collapse in intake that
never happened, so implausibly light days are marked as incomplete logs and kept
out of the averages rather than dragging them down.

**Units arrive in whatever HealthKit chose.** The phone resolves a unit per
quantity type from the sample itself (`UnitResolver`), and for anything without
an explicit preference the first compatible unit on its ladder wins — which for
mass is *kilograms*. Real rows in this database record saturated fat in kg and
vitamin C in kg. Summing those beside a gram row gives a number a thousand times
wrong in a place nobody would think to check, so every value is converted to the
nutrient's canonical unit before it is added to anything. Anything that cannot be
converted is reported, never guessed at.
"""

from dataclasses import dataclass
from datetime import date, datetime

from django.db.models import Count, Max, Sum
from django.db.models.functions import TruncDate

from . import analytics
from .models import Record

# --------------------------------------------------------------------------
# Units
# --------------------------------------------------------------------------

# Keys are HealthKit `unitString` values as they arrive on the wire, plus the
# obvious alternate spellings. Membership in the same table *is* the
# same-dimension check in `convert`, so nothing here may span dimensions.
_ENERGY_TO_KCAL = {"kcal": 1.0, "kJ": 0.2390057361, "J": 0.0002390057361, "cal": 0.001}
_MASS_TO_GRAM = {"kg": 1000.0, "g": 1.0, "mg": 0.001, "mcg": 1e-6, "µg": 1e-6, "ug": 1e-6}
_VOLUME_TO_ML = {"L": 1000.0, "l": 1000.0, "mL": 1.0, "ml": 1.0, "fl_oz_us": 29.5735295625}

_TABLES = (_ENERGY_TO_KCAL, _MASS_TO_GRAM, _VOLUME_TO_ML)


def convert(value: float, from_unit: str, to_unit: str) -> float | None:
    """`value` in `to_unit`, or None if the two units are not the same kind of
    thing.

    Returning None rather than raising or falling back to the raw number is the
    point: an unconvertible unit means the sample cannot be added to a total, and
    silently adding it anyway is how a milligram becomes a gram.
    """
    if from_unit == to_unit:
        return value
    for table in _TABLES:
        if from_unit in table and to_unit in table:
            return value * table[from_unit] / table[to_unit]
    return None


# --------------------------------------------------------------------------
# The nutrients this server understands
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Nutrient:
    """One nutrient, and the unit its numbers are always reported in.

    `headline` marks the ones worth a full baseline comparison of their own —
    the macros and the handful of micronutrients people actually ask about.
    Everything else is here so its unit is normalised if it ever shows up, not
    because a molybdenum trend is a useful thing to compute.
    """

    slug: str
    label: str
    unit: str
    group: str  # "energy" | "macro" | "mineral" | "vitamin" | "fluid" | "other"
    decimals: int = 0
    # Energy per gram, for expressing a macro as a share of intake. Only the
    # three that carry energy have one.
    kcal_per_gram: float | None = None
    # Wellness framing only, exactly as MetricSpec.direction. "neutral" for
    # anything where a direction would imply a target this system must not set.
    direction: str = "neutral"
    headline: bool = False


NUTRIENTS: dict[str, Nutrient] = {
    n.slug: n
    for n in [
        Nutrient("dietary_energy_consumed", "Energy consumed", "kcal", "energy",
                 headline=True),
        # Macros. Direction stays neutral for the three that make up intake:
        # "more protein is better" is a target dressed as a framing choice.
        Nutrient("dietary_protein", "Protein", "g", "macro", kcal_per_gram=4.0,
                 headline=True),
        Nutrient("dietary_carbohydrates", "Carbohydrates", "g", "macro", kcal_per_gram=4.0,
                 headline=True),
        Nutrient("dietary_fat_total", "Total fat", "g", "macro", kcal_per_gram=9.0,
                 headline=True),
        Nutrient("dietary_fiber", "Fibre", "g", "macro", direction="higher_better",
                 headline=True),
        Nutrient("dietary_sugar", "Sugar", "g", "macro", direction="lower_better",
                 headline=True),
        Nutrient("dietary_fat_saturated", "Saturated fat", "g", "macro", decimals=1,
                 direction="lower_better", headline=True),
        Nutrient("dietary_fat_monounsaturated", "Monounsaturated fat", "g", "macro", decimals=1),
        Nutrient("dietary_fat_polyunsaturated", "Polyunsaturated fat", "g", "macro", decimals=1),
        Nutrient("dietary_cholesterol", "Cholesterol", "mg", "other", headline=True),
        Nutrient("dietary_water", "Water", "mL", "fluid", direction="higher_better",
                 headline=True),
        Nutrient("dietary_caffeine", "Caffeine", "mg", "other", headline=True),
        # Minerals.
        Nutrient("dietary_sodium", "Sodium", "mg", "mineral", direction="lower_better",
                 headline=True),
        Nutrient("dietary_potassium", "Potassium", "mg", "mineral", headline=True),
        Nutrient("dietary_calcium", "Calcium", "mg", "mineral", headline=True),
        Nutrient("dietary_iron", "Iron", "mg", "mineral", decimals=1, headline=True),
        Nutrient("dietary_magnesium", "Magnesium", "mg", "mineral"),
        Nutrient("dietary_phosphorus", "Phosphorus", "mg", "mineral"),
        Nutrient("dietary_zinc", "Zinc", "mg", "mineral", decimals=1),
        Nutrient("dietary_chloride", "Chloride", "mg", "mineral"),
        Nutrient("dietary_copper", "Copper", "mg", "mineral", decimals=2),
        Nutrient("dietary_manganese", "Manganese", "mg", "mineral", decimals=2),
        Nutrient("dietary_iodine", "Iodine", "mcg", "mineral"),
        Nutrient("dietary_selenium", "Selenium", "mcg", "mineral"),
        Nutrient("dietary_chromium", "Chromium", "mcg", "mineral"),
        Nutrient("dietary_molybdenum", "Molybdenum", "mcg", "mineral"),
        # Vitamins.
        Nutrient("dietary_vitamin_c", "Vitamin C", "mg", "vitamin", headline=True),
        Nutrient("dietary_vitamin_b6", "Vitamin B6", "mg", "vitamin", decimals=1),
        Nutrient("dietary_thiamin", "Thiamin", "mg", "vitamin", decimals=1),
        Nutrient("dietary_riboflavin", "Riboflavin", "mg", "vitamin", decimals=1),
        Nutrient("dietary_niacin", "Niacin", "mg", "vitamin", decimals=1),
        Nutrient("dietary_pantothenic_acid", "Pantothenic acid", "mg", "vitamin", decimals=1),
        Nutrient("dietary_vitamin_e", "Vitamin E", "mg", "vitamin", decimals=1),
        Nutrient("dietary_vitamin_a", "Vitamin A", "mcg", "vitamin"),
        Nutrient("dietary_vitamin_d", "Vitamin D", "mcg", "vitamin", decimals=1),
        Nutrient("dietary_vitamin_b12", "Vitamin B12", "mcg", "vitamin", decimals=1),
        Nutrient("dietary_vitamin_k", "Vitamin K", "mcg", "vitamin"),
        Nutrient("dietary_folate", "Folate", "mcg", "vitamin"),
        Nutrient("dietary_biotin", "Biotin", "mcg", "vitamin"),
    ]
}

ENERGY = "dietary_energy_consumed"

# Macros in the order a label prints them, which is the order people read.
MACRO_SLUGS = [
    "dietary_protein",
    "dietary_carbohydrates",
    "dietary_fat_total",
    "dietary_fat_saturated",
    "dietary_fiber",
    "dietary_sugar",
]


def is_nutrient(slug: str) -> bool:
    return slug in NUTRIENTS


def nutrient(slug: str) -> Nutrient | None:
    return NUTRIENTS.get(slug)


def headline_nutrients() -> list[Nutrient]:
    return [n for n in NUTRIENTS.values() if n.headline]


# --------------------------------------------------------------------------
# Incomplete logs
# --------------------------------------------------------------------------

# A day of eating that lands under this was almost certainly a day of logging
# that stopped early. It is a data-quality floor and nothing else: it is never
# reported as a target, never compared against, and deliberately never appears
# in any payload leaving this module, because a number this system publishes
# next to the word "energy" is a number somebody will read as a goal.
_MIN_PLAUSIBLE_DAY_KCAL = 1200.0


def is_complete_log(energy_kcal: float | None) -> bool:
    """Whether a day's logged energy is plausible as a whole day's eating.

    Erring towards "incomplete" is the safe direction. Calling a real light day
    an incomplete log costs one day of coverage; calling an abandoned log a real
    light day invents a fast that did not happen.
    """
    return energy_kcal is not None and energy_kcal >= _MIN_PLAUSIBLE_DAY_KCAL


# --------------------------------------------------------------------------
# Daily totals
# --------------------------------------------------------------------------


def _grouped(queryset, tz, aggregate):
    return (
        queryset.annotate(day=TruncDate("start", tzinfo=tz))
        .values("day", "unit")
        .annotate(total=aggregate, samples=Count("id"))
    )


def daily_series(
    slug: str,
    start: datetime,
    end: datetime,
    tz_name: str | None = None,
    only_days: set[date] | None = None,
) -> dict:
    """Daily totals for one nutrient, in its canonical unit.

    Shaped exactly like `analytics.daily_series` so callers can treat the two
    interchangeably, and rollup-preferring for the same reason: two apps writing
    the same meal inflates a raw sum, and Apple's deduplicated daily total is the
    only thing that knows the difference.

    The unit handling is what this cannot borrow from `analytics`. That function
    sums `value` in SQL across whatever units the rows happen to carry; for step
    counts there is only ever one unit, and for nutrients there are three.

    `only_days` restricts the result to days whose log looks complete (see
    `complete_log_days`). Callers that are going to average, compare, or trend
    the result want that: a day the diary was abandoned halfway is a partial
    recording, and this codebase's rule for partial recordings is that they never
    get to stand in for whole ones.
    """
    spec = NUTRIENTS.get(slug)
    unit = spec.unit if spec else ""
    tz = analytics.zone(tz_name)
    base = analytics.live_records().filter(
        metric_slug=slug, start__gte=start, start__lt=end
    )

    unconvertible: dict[str, int] = {}

    def scaled(row) -> float | None:
        converted = convert(row["total"], row["unit"] or unit, unit)
        if converted is None:
            unconvertible[row["unit"] or "(none)"] = (
                unconvertible.get(row["unit"] or "(none)", 0) + row["samples"]
            )
        return converted

    # One row per day per unit. A rollup day should only ever have one row, but
    # taking the largest converted value rather than the first keeps this
    # faithful to the Max() the dashboard uses if that assumption ever breaks.
    rollups: dict[object, float] = {}
    for row in _grouped(
        base.filter(kind=Record.Kind.STATISTIC), tz, Max("value")
    ):
        value = scaled(row)
        if value is not None:
            rollups[row["day"]] = max(rollups.get(row["day"], value), value)

    raw: dict[object, float] = {}
    entries: dict[object, int] = {}
    for row in _grouped(base.exclude(kind=Record.Kind.STATISTIC), tz, Sum("value")):
        value = scaled(row)
        if value is None:
            continue
        raw[row["day"]] = raw.get(row["day"], 0.0) + value
        entries[row["day"]] = entries.get(row["day"], 0) + row["samples"]

    points = []
    for day in sorted(set(rollups) | set(raw)):
        if only_days is not None and day not in only_days:
            continue
        rollup = day in rollups
        points.append(
            {
                "date": day.isoformat(),
                "value": rollups[day] if rollup else raw[day],
                "source": analytics.SOURCE_ROLLUP if rollup else analytics.SOURCE_RAW,
                # How many separate things were written down that day. Not a
                # quality gate on its own — one restaurant entry can be a whole
                # day — but it is the difference between a diary someone kept and
                # one they opened.
                "entries": entries.get(day, 0),
            }
        )

    estimated = sum(1 for p in points if p["source"] == analytics.SOURCE_RAW)
    payload = {
        "metric_slug": slug,
        "aggregation": "sum",
        "unit": unit,
        "timezone": str(tz),
        "points": points,
        "rollup_days": len(points) - estimated,
        "estimated_days": estimated,
        "may_double_count": estimated > 0,
    }
    if unconvertible:
        # Surfaced rather than dropped quietly, the way the phone surfaces a
        # HealthKit identifier it could not resolve. A nutrient arriving in a
        # unit this table has never seen is a bug to fix, not a rounding error.
        payload["unconvertible_samples"] = [
            {"unit": found, "samples": count} for found, count in sorted(unconvertible.items())
        ]
    return payload


def complete_log_days(start: datetime, end: datetime, tz_name: str | None = None) -> set:
    """Days in the range whose food log plausibly covers the whole day.

    Every average, baseline, and trend over a nutrient is filtered through this.
    Without it, a fortnight containing four forgotten lunches reads as a fortnight
    of eating far less — a decline in the numbers that is really a decline in
    record-keeping, and the one conclusion this data must never produce on its own.
    """
    payload = daily_series(ENERGY, start, end, tz_name=tz_name)
    return {
        date.fromisoformat(point["date"])
        for point in payload["points"]
        if is_complete_log(point["value"])
    }


def sources(start: datetime, end: datetime) -> list[dict]:
    """Which apps wrote the food log, most prolific first.

    Worth reporting because "MyFitnessPal" and "typed into Health by hand" are
    different kinds of evidence, and because two food apps writing the same meal
    is the one way a nutrition total can double-count.
    """
    rows = (
        analytics.live_records()
        .filter(metric_slug__in=list(NUTRIENTS), start__gte=start, start__lt=end)
        .exclude(kind=Record.Kind.STATISTIC)
        .values("source_name")
        .annotate(samples=Count("id"))
        .order_by("-samples")[:8]
    )
    return [
        {"name": row["source_name"] or "unknown", "samples": row["samples"]} for row in rows
    ]


def logged_metrics() -> list[str]:
    """Nutrients this store actually holds anything for."""
    present = set(
        analytics.live_records()
        .filter(metric_slug__in=list(NUTRIENTS))
        .values_list("metric_slug", flat=True)
        .distinct()
    )
    return [slug for slug in NUTRIENTS if slug in present]
