# The redesign

Source for a proposed redesign of the iOS app: six screens, a navigation map,
a teardown of what ships today, and the competitor research behind it.

Built, except where noted below. It started as a proposal to argue with; the
argument is over and the screens exist.

---

## The thesis, in one paragraph

Every comparable app — Bevel, Whoop, Oura, Athlytic — shows you a number and
never tells you how much to trust it. Whoop says 67% without mentioning the
watch was off for two of the seven nights. This app already computes a
confidence grade, a valid-day count and a reason for every figure
(`grade_confidence` in `health_analysis.py`), and reports a metric that stopped
as *stopped* rather than as zero. **None of it reaches the screen.** The
redesign makes that the visible product.

The rest follows from it: lead with one measured sentence instead of six equal
numbers, attach coverage to every figure, and end each metric with what it
cannot tell you.

---

## Files

| | |
|---|---|
| `Flow.dc.html` | How the six screens connect, and what triggers each move |
| `Main.dc.html` | **Today** — the lead sentence, what moved, what is steady, what stopped |
| `MetricDetail.dc.html` | One metric: figure, coverage, and its limits |
| `InsightsEmpty.dc.html` | Insights before a question — opens on the measured week |
| `InsightsAnswer.dc.html` | An answer with the figures it rests on attached |
| `Trends.dc.html` | One metric over time, gaps drawn as gaps |
| `Data.dc.html` | Sources and server state — the old Metrics and Server tabs, merged |
| `DirectionB.dc.html` | An alternate direction: data-forward, light, six sparklines on one axis |
| `Teardown.dc.html` | What is wrong (and right) with the current Summary tab |
| `Research.dc.html` | What the popular apps do, and what was deliberately not copied |
| `Onboarding.dc.html` | First run, built around the one Health prompt iOS gives you once |
| `FirstRun.dc.html` | The first week, before there is a baseline to compare against |
| `ErrorStates.dc.html` | Server unreachable, credential rejected, sync stalled |
| `ChatHistory.dc.html` | The conversation drawer |
| `Settings.dc.html` | Settings, pushed from Data |
| `canvas.json` | Layout: positions, pages, sticky notes |

**Still to build.** Nothing, on the screens. `DirectionB.dc.html` is the
rejected alternative and is not meant to be built.

Settings keeps its `Form` rather than becoming the artboard's custom cards. It
carries sign-in, a date picker, a stepper and two destructive confirmations, and
rebuilding those to match a drawing would risk the app's critical path for a
visual change. Headers, surfaces, footnotes and controls are on the palette; the
row *shapes* are the system's.

**Drawn but not buildable yet.** `InsightsAnswer.dc.html` shows the evidence
table with a coverage strip on every row. An answer does not carry that: an
`Observation` has a statement, a prose `evidence` string and a confidence word —
no metric slug, no figure, no valid/window days. The card is built from what the
answer really returns, and the strips wait on the server sending the numbers.
Drawing them from anything else would be inventing coverage, which is the exact
failure the strip exists to expose.

`.dc.html` is Claude Design's component format. Each file is one artboard and
opens in a browser on its own, though it needs the canvas runtime to render
properly.

---

## The design system

Everything a SwiftUI implementation needs. These are the values actually used in
the artboards, not an idealised palette.

### Colour

| Token | Hex | Where |
|---|---|---|
| Ground | `#121113` | Screen background. Warm near-black, not pure. |
| Surface | `#171518` | Cards, grouped rows |
| Surface raised | `#1A181B` | Chips, secondary buttons |
| Field | `#1E1B20` | The ask bar |
| Hairline | `#2E2A30` | Every border |
| Quoted | `#2A2429` | The bubble holding your own question |
| Divider | `#201D22` | Between rows inside a card |
| Ink | `#F4F1EC` | Primary text. Warm off-white. |
| Ink secondary | `#C9C2C8` | Body copy inside cards |
| Ink muted | `#9A939B` | Supporting figures, captions |
| Ink faint | `#665F68` | Section labels, units, timestamps |
| Danger | `#E86A62` | Destructive rows, where `accent` would read as ordinary emphasis |
| **Accent** | `#E64F5A` | The existing brand red, unchanged — `AccentColor` is `rgb(0.902, 0.310, 0.353)` |
| **Measured** | `#6FBFA8` | Coverage, confidence, a change in the good direction |
| **Absent** | `#E0A458` | Stopped arriving, stale, missing |

Measured-teal and absent-amber are *status* colours and are reserved. They never
carry series identity.

### Type

**IBM Plex Sans** for interface, **IBM Plex Mono** for every figure, unit,
timestamp and section label. The mono is doing real work: it makes numbers
scannable in a column and gives the whole thing an instrument-panel register
that suits an app whose argument is measurement honesty.

Fallbacks matter — pick metrically close ones (`Helvetica Neue`, `ui-monospace`).

| Role | Size / weight |
|---|---|
| Lead sentence | 26 / 600, line-height 1.26, tracking −0.019em |
| Screen title | 22 / 600, tracking −0.018em |
| Hero figure | 50 / 600 mono, tracking −0.032em |
| Row figure | 24 / 600 mono |
| Body | 15 / 400, line-height 1.55 |
| Row label | 15 / 500 |
| Supporting | 13 / 400 |
| Section label | 11 / 600 mono, tracking 0.1em, uppercase |
| Tab label | 10 / 600 |

### The signature element

A **seven-segment strip**: one segment per day in the window, filled when that
day has data. It is `valid_days / window_days` — a figure the server already
returns on every comparison and the UI has never shown.

- Inline under the lead: 15×4px segments, 3px gap
- In an evidence row: 50px total, 3px tall

The metric detail scales it up into a bar chart where each night is named, so a
gap is unmistakably a gap.

### Spacing and hit targets

20px screen gutter. 24px between major sections, 10–13px within a group.
Radii: 8 (chip), 12 (callout), 14 (card), 24 (ask bar).

Minimum tap target 44px; list rows are 62px, tab items 52px.

---

## Rules the screens follow

**No fake status bar.** Every phone artboard leaves 54px empty at the top. The
real status bar draws there; painting one looks doubled up on a device.

**A gap is never interpolated.** On `Trends.dc.html` the line breaks across the
two nights the watch was not worn. Joining them would draw sleep that never
happened — the same principle `nutrition.py` is written around.

**Effort is neutral.** Following Gentler Streak, which won a 2024 Apple Design
Award for refusing to shame. `MetricSpec` already marks effort `neutral`; the UI
should not undo that with green ticks.

**No invented composite score.** Whoop's 67% has no equivalent here and should
not get one — the architecture explicitly forbids the model doing arithmetic,
and a 0–100 number would need exactly that.

---

## Regenerating the canvas

The published canvas is assembled by Claude Design's seeder from these files
plus one screenshot:

```
--artboard Flow.dc.html --artboard Main.dc.html … --canvas canvas.json
--image docs/screenshots/01-summary.png
```

`Teardown.dc.html` references `01-summary.png` by bare filename and expects it
in the canvas's file set. Downsample it to roughly 60 KB first — the committed
copy is larger than a canvas wants to carry.

**One limitation worth knowing.** An earlier version of `Main.dc.html` was a
working prototype: four tabs, tappable rows, a simulated answer delay. Event
handlers do not fire in the canvas preview — tested with spaced and unspaced
bindings, flat and per-item handlers, on a `div` and on a real `button`, all
inert. Hence static screens and `Flow.dc.html` in place of tapping. If that is
ever fixed, the interactive version is recoverable from this repository's
history.
