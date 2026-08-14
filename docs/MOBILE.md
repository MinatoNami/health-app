# The iOS app

Reads Apple Health, ships it to your server, and is the everyday way in to what
the server makes of it.

Deploying and running it is in the [root README](../README.md). This is what it
does and how it is put together.

---

## What it does

**Sync.** Reads whichever HealthKit types you enable, normalises them, and
uploads NDJSON batches to your own server. Anchored, so a sync sends what
changed rather than everything. Retries on failure and reconciles against the
server's coverage report, so a server that silently lost data gets it re-sent.

**Summary.** The server's analysis, rendered: every headline metric over the
last 7 days against your own preceding 28, with coverage and a confidence grade.

**Insights.** A conversation about that analysis — see below.

**The morning brief.** An 08:00 notification with what actually moved. Computed
deterministically server-side, because the alert has to be dependable whether or
not the laptop running the model is awake.

**Diagnostics.** Per-type coverage, the outbox, sync anchors, and a log you can
read when something stops arriving.

---

## Screens

| Tab | What it is |
|---|---|
| **Status** | Sync state, the outbox, last upload, the morning brief |
| **Metrics** | Which HealthKit types are enabled, and per-type coverage |
| **Insights** | The conversation, chat history, the measured week |
| **Exports** | Manual file export |
| **Settings** | Server, account, brief, diagnostics, privacy |

---

## Insights, in detail

The tab opens on the measured week and a composer. Ask something and the
question appears immediately — the bubble is appended before the request, so it
is not waiting half a minute to show what you just typed.

**It is a real conversation.** The transcript is a list of turns, the session id
is persisted, and a follow-up carries what came before. Until recently this
screen held one question and one answer: asking a second thing silently erased
the first, and "what about last month?" reached the model with no idea what
"that" was.

- **Chats** (toolbar, left) slides in the history drawer from the left, with the
  conversation dimmed behind it: tap the dimmed area or drag it away to close.
  A drawer rather than a sheet because a chat list is *navigation* — you open it
  to glance, change your mind and put it back — where a sheet is modal and says
  "finish with me first". Projects first, then loose conversations under Today /
  Yesterday / Previous 7 days. Search reaches the questions inside a chat, not
  just titles. Swipe a row to rename, archive or delete. "Load older chats"
  pages.

  The close-drag lives on the scrim, not the drawer: the panel is a list whose
  rows carry swipe actions, and a container-level horizontal drag would eat them
  — swiping a chat to rename it would close the drawer instead.
- **⋯** (toolbar, right) starts a new chat or compacts the current one.
- **Thumbs and a note** sit under every stored answer.
- **A compaction seam** marks where the model's memory of the conversation
  became a paragraph — every message above it is still there to read.

The last-open chat is remembered across launches. Only the id is kept; the
transcript is refetched, because the server is the record and a stale copy on
the phone would be a second opinion about what was said.

**Nothing is recomputed on the device.** Baselines, coverage grading and the
deduplication rules underneath them are subtle enough that a second
implementation would drift, and a phone quietly disagreeing with the dashboard
about the same week is worse than either number alone. The same goes for the
safety verdict and for which turns belong to a conversation.

**The measured comparison renders first, the generated explanation second** —
which is also the order they arrive. The snapshot is one fast query; an answer
is a local model working for tens of seconds. When the model server is asleep,
the screen still carries everything that was actually recorded.

---

## Layout

```
HealthExporter/
├── App/            HealthExporterApp, AppServices (composition root)
├── Core/           Keychain, Paths + StateStore, Log, Timestamps, MetricName
├── Health/         HealthAuthorization, HealthReader, MetricCatalog,
│                   AnchorStore, UnitResolver
├── Model/
│   ├── HealthRecord.swift    the wire format
│   ├── HealthInsight.swift   snapshot, insight, safety verdict, daily brief
│   ├── ChatHistory.swift     sessions, projects, transcripts, ChatTurn
│   └── JSONValue.swift
├── Export/
│   ├── ExportSink.swift      HTTP client: ingest, analysis, insights, chat
│   ├── Normalizer.swift      HealthKit sample → HealthRecord
│   ├── Outbox.swift          durable queue of pending batches
│   ├── CertificatePinner.swift
│   └── ServerStatus.swift
├── Sync/
│   ├── SyncEngine.swift      the observable app state; owns the transcript
│   ├── BackgroundSync.swift
│   └── DailyBriefScheduler.swift
└── UI/
    ├── InsightsView.swift    transcript, composer, bubbles, rating
    ├── ChatHistoryView.swift the history drawer
    ├── StatusView.swift, MetricsView.swift, SettingsView.swift, …
    └── TrendCharts.swift, MetricStyle.swift, CoverageGrid.swift
```

`SyncEngine` is the single `@Published` surface the views observe. Adding a new
piece of server state means adding it there, not fetching from a view.

---

## Two things that will bite you

**Dates.** Django emits six fractional digits and `ISO8601DateFormatter` is only
dependable for three — and it returns `nil` rather than throwing, so the failure
surfaces as a decode error on an unrelated field. `ServerDate` in
`ChatHistory.swift` tries the formatter, then strips the fractional part and
retries. Everything older in `HealthInsight.swift` decodes dates as strings and
is unaffected.

**New files need Xcode project entries.** The project uses explicit file
references, not synchronised folders, so a new `.swift` file needs four entries
in `project.pbxproj` (build file, file reference, group child, sources phase) or
it simply will not compile.

Building from the command line needs the toolchain pointed at Xcode rather than
the Command Line Tools:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project HealthExporter.xcodeproj -scheme HealthExporter \
  -destination 'generic/platform=iOS Simulator' build
```

---

See also: [LIFECYCLE.md](LIFECYCLE.md) for startup, caching and the main-thread
rules, and [CHAT.md](CHAT.md) for how conversations work across both clients.
