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

**Percentages arrive as fractions.** HealthKit's percent unit stores 97% blood
oxygen as 0.97 and 22% body fat as 0.22, and the record keeps HealthKit's value.
`analytics` converts on the way out of every daily series and latest reading,
so the snapshot, trends, anomalies, the dashboard and the safety floors all read
percentages. Until it did, a normal 97% sat at 0.97 against the blood-oxygen
floor of 92, and the model was told blood oxygen "averaged 0.97 %". The CSV
export is a record dump and still carries HealthKit's fraction.

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

## Lifestyle signals

`lifestyle.py`, served at `/v1/analysis/lifestyle` and to the model as
`get_lifestyle_signals`. Chosen from a review of what the major wearables
shipped in 2024–26 and of the outcome research behind them, then held to the
rules above. Every input was already being uploaded; nothing here needed a new
HealthKit type.

None of it is a score. Every vendor in this space ships a composite —
readiness, recovery, energy — and none publishes the formula. Each section here
is a measurement, the range or reference it was judged against, how much data it
rests on, and what it cannot say.

**Overnight vitals.** The most recent night's sleeping heart rate, HRV,
breathing rate, wrist temperature, blood oxygen and sleep duration against the
range of the 28 nights before it: median ± two robust deviations, with a floor
per signal so a month of near-identical nights does not produce a range the next
ordinary night falls out of. HRV is judged on a log scale, which is how it
varies. Seven nights are needed before anything is called typical, and the
night is **flagged only when two or more signals are outside their range at
once** — the rule Apple's Vitals app uses, because one metric out on one night
is what a sensor does. A flag lists ordinary explanations (alcohol, a late meal,
travel, hard training) and never names a condition.

Each night is its **main sleep**: overlapping intervals merged first, so a
night two sources recorded counts once, then stretches under an hour apart
joined, and the longest one ending that morning kept. Filing every asleep
interval under the date it ended let a 14:00 nap stretch the night to
mid-afternoon and average the morning's heart rate into "sleeping heart rate".

This is the one place a date of *today* appears in the layer, deliberately:
windows end yesterday because today is a partial *day*, but last night ended
this morning and is complete. The night is always named by date, so a phone
that has not synced yet shows the previous night as the previous night. A flag
leads the morning brief — but only for the night that ended that morning, so an
unsynced phone does not get yesterday's alert again. `as_of` moves the night
with it: the night checked is the one ending the morning after.

**Sleep regularity.** The Sleep Regularity Index (Phillips 2017): the share of
minutes in the same state — asleep or awake — 24 hours apart, scaled so 100 is
an identical schedule every day. In 60,977 UK Biobank adults it predicted
mortality better than sleep duration did, and adding duration explained nothing
more. Computed on a minute mask per noon-to-noon sleep-day, so overlapping
sources collapse naturally. Minutes are wall-clock, not elapsed time — across a
DST change an unchanged schedule is an hour apart in elapsed time, and scored as
irregular. Same windows as everything else: this week against
the four before, graded against the spread of the person's own day-to-day
scores. A sleep-day with under three hours recorded is left out rather than
scored as awake — regularity indices tolerate data missing at random and are
badly thrown by data missing for a reason, and a watch on the charger is one.
The cohort's quintile cut-points travel with the figure as context, labelled as
not a target.

**Weekly activity.** Exercise minutes over four rolling weeks against the WHO's
150–300. A day with no exercise rollup is ambiguous — watch off, or watch on
and no exercise — and heart-rate data that day settles it: worn, so the honest
figure is zero. With neither, the day stays out of the sum. A week already past
150 has met it however few days were seen; a week under 150 with fewer than
five known days is reported as unknown. Weeks met out of four, not a streak,
and a week with over half its minutes on one or two days is described as the
weekend-warrior pattern, which large cohorts associate with much the same
benefit.

The guideline is the one published figure set beside a behaviour here, and it
is a guideline for behaviour, not a norm for a measurement — the line
"personal baselines, never population norms" was drawn for. The model is told
to quote it as context and never to extend the practice to any other metric.

**Daylight and cardio fitness.** Time in daylight goes through the ordinary
baseline comparison. VO2 max is a 90-day trend rather than a weekly one — the
watch estimates it only on outdoor walks and runs — and a change under one MET
(3.5 mL/kg/min) is reported as steady: that is the unit the outcome research is
measured in, and inside the watch's own error. `MetricSpec.noise_floor` applies
the same floor to the weekly comparison and to anomalies.

**Nightly samples are filed under the morning they end.** Wrist temperature and
breathing disturbances arrive as one sample spanning the night, so bucketing by
`start` put a night's temperature on the evening before and a day away from the
same night's sleep. `analytics.END_ANCHORED` buckets them by `end`, in the raw
series and the quality report alike.

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

Thirteen read-only tools. The model reaches data only through these, and every one
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
| `get_lifestyle_signals` | Overnight vitals, sleep regularity, weekly activity, daylight, cardio fitness |

Every one has a matching deterministic endpoint under `/v1/analysis/*`, so any
figure in an answer can be checked without a model in the loop.
