# The analysis layer

What the server computes before any model is involved, and why each part refuses
as often as it answers.

Everything here is deterministic: same rows in, same numbers out, no network call
off the machine. The language model is a separate layer that *explains* these
figures and never produces them — see [the tool surface](#the-tool-surface) at
the end.

Operational matters — deploying, pointing at LM Studio, retention — live in
[server/README.md](../server/README.md). The app↔server sync contract lives
there too, under *Reconciliation*.

---

## The three rules everything obeys

**Windows end yesterday.** Today is partial by definition, and half a day of
steps against a full-day baseline reads as a collapse in activity that is only
the clock.

**The current window and the baseline do not overlap.** Seven days against the
*preceding* twenty-eight, not against a twenty-eight that contains them —
otherwise the baseline is dampened by the very change being looked for.

**Coverage travels with every figure.** A weekly average built from two recorded
days is not a weekly average. Every comparison carries `valid_days`, `coverage`,
a `confidence` grade and a one-line `confidence_reason` a reader can check.

Personal baselines, never population norms. A resting heart rate of 62 means
nothing on its own; 62 against this person's own 54 means something.

---

## Metric specs

`health_analysis.METRICS` maps a slug to a `MetricSpec` — the minimum a metric
needs to be summarised honestly:

| Field | Why it exists |
|---|---|
| `daily` | `sum` or `avg`. Summing instantaneous heart-rate readings is meaningless; averaging step samples answers a question nobody asked. |
| `direction` | Wellness framing only — `lower_better` on resting heart rate never implies a clinical judgement. |
| `min_current_days`, `min_baseline_days` | Per metric, because weight is stepped on twice a week and resting heart rate is written nightly. One "3 valid days" bar would call one unusable and the other fine. |
| `expected_cadence` | The denominator for coverage. Weight measured three times in a week is *full* coverage for weight; scoring it 3/7 marks normal behaviour as a data problem. |
| `self_reported` | Written down by a person, not measured by a sensor. See [Nutrition](#nutrition). |

A metric absent from `METRICS` is not analysable — no baseline, no trend, no
goal. That is deliberate: `blood_glucose` is uploaded and charted, and nothing
here knows how to baseline it, so a goal against it would report progress it
cannot measure.

## Confidence grading

`insufficient` → `low` → `moderate` → `high`, decided by coverage against
`expected_cadence`, with two extra demotions: more than half the samples typed in
by hand, or more than half the days summed from raw samples rather than Apple's
deduplicated rollups.

The *reason* matters as much as the grade. "moderate" is a number a reader has to
trust; "moderate — 4 of 7 days have data" is one they can check.

## Significance

`classify_change` grades a change against the person's **own variability**, using
a median absolute deviation rather than a standard deviation so one holiday does
not widen the band enough to hide a real shift. A 300-step move is noise for
someone whose daily count swings by 4,000 and a real shift for someone who walks
the same route every day; a fixed percentage would get one of them wrong.

## Trends

Daily points, 7- and 28-day moving averages, week-over-week, and a least-squares
slope with r². Two refusals worth knowing:

- A moving average needs **half its window present**, or the "7-day average" is a
  single day wearing a longer label.
- A slope with r² below 0.15 is reported as `flat`, not as a direction. Below
  that it is a line fitted to noise, and quoting it invites a story about a
  change that did not happen.

## Data quality

The machine-readable version of "why HealthKit data misleads": sources writing
the same metric, manual entry, estimated days, the longest run of missing days,
device models. So an insight can carry its own caveats instead of relying on a
model to invent them.

`comparable()` refuses to compare two periods unless both clear the coverage bar.
A percentage change between a full week and a two-day week is a number that looks
like an answer and is not one.

## Anomalies

Deliberately conservative, and all three gates must pass: at least two robust
deviations from the personal baseline, coverage of at least `moderate`, and the
shift **sustained across three or more days**. A one-night dip in HRV after a
late meal is not a finding, and surfacing it as one is how alerts become noise
people learn to dismiss.

Findings are phrased as observations about the person's own range — never a cause
and never a condition.

---

## Nutrition

`nutrition.py` plus `health_analysis.nutrition_summary()`. This is the only
signal in the system a person writes themselves rather than a sensor recording,
and that single difference drives the whole module.

**A gap is not a fast.** A day with no food log is a day nobody wrote down.
Days are counted as fully logged, partially logged and not logged — never
collapsed into one "days with data" figure, because a fortnight containing four
abandoned breakfasts would read as a fortnight of barely eating.

**A short day is usually a short log.** Breakfast entered and lunch forgotten
produces a 400 kcal Tuesday. Days whose logged energy is implausible for a whole
day are dropped from every average, baseline and trend — filtered inside
`day_values`, so the summary and the baseline comparison in one payload cannot
disagree. The plausibility floor stays inside the module: published next to the
word *energy* it becomes a number somebody reads as a target.

**Units arrive in whatever HealthKit chose.** The phone resolves a unit per
quantity type from the sample itself, and for any nutrient without an explicit
preference the first compatible mass unit wins — **kilograms**. Real rows in this
database stored saturated fat and vitamin C in kg while sodium and protein
arrived in mg and g, so one SQL `SUM` over a single nutrient was adding numbers
three orders of magnitude apart. Every value is now converted to the nutrient's
canonical unit before it is added to anything, and a unit nothing can convert is
reported rather than guessed at.

### Energy balance

Logged intake against resting **plus** active energy, over the *same* days —
comparing five logged days of intake against a month of expenditure produces a
deficit out of a mismatch in the windows. Active energy alone is a few hundred
kilocalories, so omitting resting energy is not a smaller claim but a wrong one.

Both sides are estimates and the difference carries both errors: resting energy
is a formula over body metrics and runs generous, intake is eyeballed portions.
So `weight_context` reports **measured** weight alongside and names it the
stronger evidence. On real data this mattered: subtracting the two estimates
said 898 kcal short per day while the scale was going *up*.

### What is deliberately not done

No calorie or macronutrient targets, no comparison against a recommended
allowance, and no describing the intake-minus-expenditure figure as a deficit or
a rate of weight change. Enforced in the prompt, in `safety.NUTRITION_CONSTRAINTS`,
and by a post-flight rule that blocks a prescriptive verb plus a number plus a
food unit — while still letting an answer quote what was logged.

Nutrition sits beside `sleep` and `workouts` in the snapshot rather than among
the headline metrics, so a five-day-old food log cannot drag `overall_confidence`
down and leave every answer about steps hedged about coverage that is fine.

---

## Correlations

`correlations.py`. The hard part is not the arithmetic: thirteen metrics make
seventy-eight pairs, and at p<0.05 about four will look significant on pure
noise. An engine that sweeps every pair and reports what clears the threshold is
a machine for generating confident nonsense.

Four things hold it honest:

1. **The hypotheses are fixed, not fished.** `CANDIDATES` is a written-down list
   of pairs with a stated reason each. Nothing is discovered by searching.
2. **Everything tested is reported** — rho, n and p — whether or not it survived.
   Publishing only the survivors turns one hit out of fourteen into "the
   relationships in your data".
3. **Holm–Bonferroni across the whole run**, so `significant` accounts for how
   many questions were asked.
4. **A contrast in real units.** A rho of 0.34 tells nobody anything. *"On your
   ten longest nights HRV averaged 48 ms; on the ten shortest, 41 ms"* is the
   same fact in a form somebody can check against their own memory.

**Lags are reasoned from each series' own bucketing.** Sleep is filed under the
morning it ended, so last night's sleep and this morning's HRV are already the
same calendar day and need no lag — while today's steps and tonight's sleep are a
day apart. Every candidate's lag is chosen against that convention.

**Weight is paired by non-overlapping calendar week.** Daily weight against daily
steps mostly measures hydration, and a rolling window would make consecutive
points near-copies and inflate any significance computed from them.

Two limits are stated in the payload rather than buried: daily health series are
autocorrelated, which makes every p-value optimistic; and an association between
two of a person's own metrics can always be produced by a third thing neither
measures — which is what the per-pair `confounders` list is for.

## Patterns

`patterns.py` — weekend versus weekday, and the single strongest standout
weekday. A pattern is a weaker claim than a correlation and gets a different
test: **no p-values**, because seven weekdays across six metrics is forty-two
chances to find nothing dressed as something.

Instead it reuses the vocabulary the rest of the codebase grades changes with —
a weekday is reported when it sits outside the person's own robust spread, and
described as "notable against your own variation" rather than "significant".

At most one weekday per metric, the strongest. "Your Tuesdays and also slightly
your Thursdays and possibly your Sundays" is how a finding turns into a horoscope.

---

## Safety

Rules, before and after the model, because a language model asked "is 105 bpm
resting worrying?" produces a fluent answer either way and which way depends on
phrasing.

**Pre-flight** turns the snapshot into an escalation level
(`informational` → `coaching` → `review_recommended` → `urgent`) and a set of
constraints the prompt carries. Reported symptoms outrank every measurement: "my
chest hurts but my watch says I'm fine" must never resolve to reassurance.
Anything reaching `urgent` is answered from **reviewed text with the model never
called**.

**Post-flight** re-reads what the model produced and blocks diagnosis, medication
advice, restrictive diet advice, intake targets, correlation-as-cause, and claims
that wearable data rules out illness. Each rule carries a negation guard, because
"this data cannot rule out an underlying illness" is the sentence the prompt
*asks* for, and a checker that matches on "rule out illness" blocks the correct
answer while letting nothing useful through.

Blocking rather than editing: silently deleting a sentence leaves an answer that
reads as complete but no longer says what the model concluded. The measured
snapshot is returned either way.

---

## The tool surface

Twelve read-only tools. The model reaches data only through these, and every one
returns already-computed figures with units, windows, valid-day counts and
confidence attached. No SQL, no credentials, no raw rows — and per-day arrays are
stripped before the model sees them, because handing it 90 daily values invites
exactly the arithmetic this design exists to prevent.

| Tool | For |
|---|---|
| `list_available_metrics` | What this person actually has data for |
| `get_health_overview` | The snapshot: every headline metric against baseline |
| `get_metric_trend` | One metric: moving averages, slope, direction |
| `compare_periods` | Two arbitrary ranges, with a refusal when either is thin |
| `get_sleep_summary` | Duration, bedtime, wake time, consistency |
| `get_nutrition_summary` | Logged intake, day-counts, macros, energy balance |
| `get_recent_workouts` | Sessions and frequency |
| `get_correlations` | Pre-registered pairs, Holm-corrected |
| `get_patterns` | Weekend and weekday rhythms |
| `get_data_quality` | What can and cannot be concluded per metric |
| `get_goals` | Targets and measured progress |
| `get_anomalies` | Sustained shifts from personal baseline |

Every one has a matching deterministic endpoint under `/v1/analysis/*`, so any
figure in an answer can be checked without a model in the loop.
