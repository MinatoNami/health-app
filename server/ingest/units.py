"""Converting sensor quantities into the unit a metric is reported in.

`nutrition.py` already does this for food, and its docstring explains why: the
phone resolves a unit per HealthKit type from the sample itself, so the unit a
number arrives in is a property of the data, not of the metric. Nutrition got
the treatment because the failure was loud — vitamin C in kilograms.

Sensors have the same problem and it went unnoticed for longer, because the
number still looks plausible. `UnitResolver` resolves every distance type to
**metres**, while `MetricSpec("distance_walking_running", …, "km", …)` labels
the result kilometres. Nothing converted between them, so an 8.5 km walk was
reported to the model as "8500 km" — wrong by a thousand, in a direction that
reads as a heroic week rather than as an error.

**A factor, or nothing.** `convert` returns None when the two units are not the
same kind of thing, exactly as `nutrition.convert` does. Falling back to the raw
number is how a metre becomes a kilometre.

**No temperature.** °C to °F is an offset as well as a scale, so it cannot join
a table of factors, and a metric reported in the wrong temperature unit is
wrong by an amount that varies with the reading. Body temperature is stored and
displayed in whatever the phone sent; no spec asks for a conversion.
"""

# Every table is "how many of the base unit is one of these", so converting is
# value * table[from] / table[to]. Membership in the same table *is* the
# same-dimension check, which is why nothing here may span dimensions.
_LENGTH_TO_METRE = {
    "m": 1.0, "km": 1000.0, "cm": 0.01, "mm": 0.001,
    "mi": 1609.344, "ft": 0.3048, "in": 0.0254, "yd": 0.9144,
}
_SPEED_TO_M_PER_S = {
    "m/s": 1.0, "km/hr": 1 / 3.6, "km/h": 1 / 3.6, "kph": 1 / 3.6,
    "mi/hr": 0.44704, "mph": 0.44704, "ft/s": 0.3048,
}
_ENERGY_TO_KCAL = {"kcal": 1.0, "Cal": 1.0, "kJ": 0.2390057361, "J": 0.0002390057361, "cal": 0.001}
_MASS_TO_GRAM = {
    "kg": 1000.0, "g": 1.0, "mg": 0.001, "mcg": 1e-6, "µg": 1e-6, "ug": 1e-6,
    "lb": 453.59237, "oz": 28.349523125, "st": 6350.29318,
}
_TIME_TO_SECOND = {"s": 1.0, "sec": 1.0, "ms": 0.001, "min": 60.0, "hr": 3600.0, "h": 3600.0, "d": 86400.0}
_POWER_TO_WATT = {"W": 1.0, "kW": 1000.0, "mW": 0.001}
_VOLUME_TO_ML = {"L": 1000.0, "l": 1000.0, "mL": 1.0, "ml": 1.0, "fl_oz_us": 29.5735295625}
# HealthKit writes rates as compound units. `count/min` and `count/s` are the
# same dimension; beats per minute and steps per minute are both count/min, and
# nothing here needs to tell them apart.
_RATE_TO_PER_MINUTE = {"count/min": 1.0, "count/s": 60.0, "count/hr": 1 / 60.0, "1/min": 1.0}

_TABLES = (
    _LENGTH_TO_METRE,
    _SPEED_TO_M_PER_S,
    _ENERGY_TO_KCAL,
    _MASS_TO_GRAM,
    _TIME_TO_SECOND,
    _POWER_TO_WATT,
    _VOLUME_TO_ML,
    _RATE_TO_PER_MINUTE,
)


def convert(value: float, from_unit: str, to_unit: str) -> float | None:
    """`value` expressed in `to_unit`, or None if the two are not comparable.

    None rather than the raw number on purpose: an unconvertible unit means the
    caller does not know what it is holding, and quietly passing it through is
    the whole failure this module exists to stop.
    """
    if from_unit == to_unit:
        return value
    for table in _TABLES:
        if from_unit in table and to_unit in table:
            return value * table[from_unit] / table[to_unit]
    return None


def factor(from_unit: str, to_unit: str) -> float | None:
    """The multiplier taking `from_unit` to `to_unit`, or None.

    Separate from `convert` because a whole day series shares one factor, and
    working it out once beats calling `convert` per point.
    """
    return convert(1.0, from_unit, to_unit)


def known(unit: str) -> bool:
    """Whether any table has heard of this unit.

    A dimensionless metric — a count, a percentage, a score — is not in any
    table and does not need to be. Callers use this to tell "no conversion
    needed" apart from "conversion failed".
    """
    return any(unit in table for table in _TABLES)
