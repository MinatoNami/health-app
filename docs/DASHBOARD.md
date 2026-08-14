# The dashboard

Vue 3 + Vite, built by `./deploy.sh` and served as static files by nginx at
`/dashboard/`. Sign in with the same account the phone uses.

Same-origin, session-cookie auth, CSRF token echoed on unsafe methods. There is
no build-time API host — the dashboard is served by the server it talks to.

---

## Views

| View | What it is |
|---|---|
| **Overview** | KPI tiles and headline charts over the selected range |
| **Insights** | Chats on the left, the conversation in the middle, the measured week on the right |
| **Explore** | Any metric, any valid aggregation |
| **Export** | Pick metrics and a range, see the row count, download CSV |
| **Settings** | Goals, where processing happens, retention, answer feedback |

One filter row sits above everything it scopes — never per-card filters. It is
hidden on Insights and Settings, where a date control would silently do nothing.

---

## Insights

Three columns: the chats you have had, the one you are having, and the numbers
it is built from.

- **Sidebar** — projects (expandable, with their standing context and an
  instructions editor), then loose chats under Today / Yesterday / Previous 7
  days. Search is server-side so it reaches question bodies, not just titles.
  Row menu: rename, move to project, download as Markdown or JSON, archive,
  delete. "Load older chats" pages; "Show archived" toggles.
- **Transcript** — the conversation, with a thumb and a note under every stored
  answer, and a seam where compaction folded the earlier part.
- **Context rail** — this week against your 28-day baseline, so what the answer
  was built from stays in view while you read it.

The header carries the chat title, its project, measured context use once it
passes 50%, and **Download** / **Compact**.

Below 1180px the rail drops; below 860px the sidebar becomes a drawer. A 220px
list next to a 100px transcript is two unusable things instead of one usable one.

Everything explanatory — how the windows are chosen, where processing happens,
goals, retention — lives in Settings. It is read once; it was costing a
paragraph a day on Insights.

---

## Settings → Answer feedback

The feedback loop, as a panel: how many answers you have judged, the current
prompt version, whether rated answers survive retention, then the same tally
grouped by model and by prompt version, and the answers you marked unhelpful
with their notes.

A group appears only when there is more than one to compare — a single row
labelled "by model" is a table saying nothing.

---

## Layout

```
dashboard/src/
├── main.js               mounts App, imports the stylesheet package
├── api.js                every endpoint, one place
├── App.vue               shell: sign-in, tabs, the range filter
├── styles/
│   ├── index.css         @imports the rest, in cascade order
│   ├── tokens.css        design tokens, light and dark
│   ├── base.css          reset, document defaults, text utilities
│   ├── layout.css        app frame, topbar, filter row, cards, sign-in
│   ├── controls.css      buttons, chips, inputs, checkboxes
│   ├── data.css          tiles, tables, deltas, chart tooltip
│   └── chat.css          bubbles and the parts of a structured answer
├── components/
│   ├── ChatMessage.vue   one turn, with its rating controls
│   ├── ChatSidebar.vue   history, projects, search, row menus
│   ├── ContextRail.vue   the measured week beside the conversation
│   ├── LineChart.vue, ColumnChart.vue, ChartCard.vue
└── views/
    ├── InsightsView.vue, OverviewView.vue, ExploreView.vue,
    └── ExportView.vue, SettingsView.vue
```

---

## Styling

**Shared rules live in `styles/`, split by what a rule *is*.** A component keeps
only styling nobody else could want — its own grid, its own one-off spacing.

The rule of thumb: if you find yourself copying a block from one component into
another, it belongs in the package instead. That is not tidiness. The chart
tooltip was once declared identically in `LineChart` and `ColumnChart`, and a
change to one would have silently made the two charts disagree.

The chat rules are **namespaced** — `.chat-row`, `.chat-bubble`,
`.answer-summary` — rather than lifted as-is. `.summary` is fine inside one
scoped component and a collision waiting to happen in a global sheet.

**Tokens carry the theme.** Light values on bare `:root`, dark redefined under
both `prefers-color-scheme` and `[data-theme='dark']`. Status colours are split
by job: `--status-warning` is a good amber *bar* and scores 1.79:1 as text, so
`--warning-text` is the one that clears 4.5:1. Never set a caption in a fill
colour.

**One accent carries interaction; everything else is ink.** Status colour is
reserved for state and stays rare, or the page reads as a traffic light. In a
metric row only the delta is tinted — colouring the delta, the coverage bar and
the confidence word turns six metrics into eighteen coloured things.

**Colour is never the only channel.** Every chart ships direct labels and a
table view; the safety banner carries words as well as a tint; a pressed thumb
is filled *and* `aria-pressed`.

---

## Timezone

Every endpoint that slices by day takes `tz`, and the dashboard sends the
browser's IANA name on all of them. Without it the server falls back to
`DISPLAY_TIMEZONE` — right until you open the dashboard from another country, at
which point "yesterday" quietly becomes somebody else's and every daily total
shifts by the offset.

---

## Building

```bash
cd server/dashboard
npm install
npm run build      # ./deploy.sh does this and publishes dist/
```

---

See also: [CHAT.md](CHAT.md) for how conversations work, and
[ANALYSIS.md](ANALYSIS.md) for what the numbers mean.
