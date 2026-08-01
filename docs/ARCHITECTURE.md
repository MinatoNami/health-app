# Apple Health → Workflow Engine: Architecture Plan

**Goal:** an iOS app that reads all available HealthKit data, normalizes it, and delivers it to a self-hosted API — with a manual file export as a secondary path.

**Decisions locked in:** self-hosted custom API destination · dual transport (automatic HTTP push + manual file export) · broad coverage of readable HealthKit types.

---

## 0. Before you build: the zero-code baseline

The Health app already has **Export All Health Data** (Profile → Export All Health Data), which produces a zip containing `export.xml` and `export_cda.xml`. It is a full dump, no incremental support, often 100 MB to over 1 GB, and the XML is awkward to parse.

Build the app if you want **incremental, scheduled, typed, structured** delivery. If you only need a one-time historical load, do the manual export first and use it to seed your database — then let the app handle everything going forward. Treat this as Phase 5 (backfill) getting done for free.

---

## 1. System shape

```
┌─────────────────────────── iPhone ────────────────────────────┐
│                                                                │
│  HealthKit store                                               │
│       │                                                        │
│       ▼                                                        │
│  [1] Read layer          anchored queries + statistics queries  │
│       │                  observer queries → background wake     │
│       ▼                                                        │
│  [2] Normalizer          HK types → single canonical record     │
│       │                                                        │
│       ▼                                                        │
│  [3] Local queue         SQLite: pending batches + anchors      │
│       │                                                        │
│       ├──► [4a] Uploader ──── HTTPS POST (NDJSON, gzip) ──────► │
│       │                       URLSession background config      │
│       └──► [4b] File export ─ share sheet / Files ────────────► │
└────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                        Your API: /v1/health/batches
                        idempotent upsert on sample UUID
                                    │
                                    ▼
                            Workflow engine triggers
```

The **local queue is the critical design choice**. Do not read-and-POST in one step. HealthKit gives you data at unpredictable times (background wake-ups, possibly while the device is locked and the store is unreadable), and your server may be down. A durable on-device queue decouples the two and makes the whole thing debuggable.

---

## 2. Project setup

**Capabilities and entitlements**

| Item | Value |
|---|---|
| Capability | HealthKit |
| Entitlement | `com.apple.developer.healthkit` |
| Background delivery | `com.apple.developer.healthkit.background-delivery` (HealthKit capability → "Background Delivery" checkbox). **Required on iOS 15+** — without it, `enableBackgroundDelivery` fails with `errorAuthorizationDenied`. |
| Background modes | Background fetch, Background processing |
| Info.plist | `NSHealthShareUsageDescription` (read — required) |
| Info.plist | `NSHealthUpdateUsageDescription` (only if you ever write back) |

You do not need `NSHealthUpdateUsageDescription` for a read-only exporter. Keep it out — fewer permissions to justify.

**Distribution reality check.** A free Apple ID lets you sideload to your own device, but the provisioning profile expires every 7 days and you re-install. Worse, free "Personal Team" support for the HealthKit capability is limited and unreliable. Pay for the **$99/yr Apple Developer Program** — 1-year profiles, TestFlight, and capabilities that actually provision. No special Apple approval is needed for HealthKit entitlements; even Clinical Health Records is a self-serve checkbox in Xcode (App Review is where misuse gets caught).

**Minimum deployment target:** iOS 17 or 18. iOS 16 introduced detailed sleep stages, iOS 18 added `HKStateOfMind`. Targeting recent OS versions removes a lot of conditional-availability code for a personal tool.

---

## 3. Read layer

### 3.1 Type inventory

There is **no public API to enumerate all HealthKit identifiers** — you must maintain an explicit list. Budget for roughly:

- ~100+ `HKQuantityTypeIdentifier` (steps, heart rate, HRV SDNN, VO2 max, body mass, blood glucose, dietary macros…)
- ~65+ `HKCategoryTypeIdentifier` (sleep analysis, mindful minutes, symptoms, cycle tracking, audio exposure events…)
- `HKCharacteristicType` — date of birth, biological sex, blood type, skin type, wheelchair use. **Static, read once, never poll.**
- `HKWorkoutType` + `HKWorkoutRoute` (GPS polylines) + per-workout statistics
- `HKCorrelationType` — blood pressure (systolic + diastolic as a pair), food entries
- `HKActivitySummary` — daily move/exercise/stand rings, queried separately

**Defer these to a later phase** — each needs bespoke handling and adds real complexity:

- `HKElectrocardiogram` — voltage measurements stream via a separate async query; a single ECG is ~15k samples
- `HKAudiogramSample`
- `HKClinicalRecord` (Health Records from providers) — needs `com.apple.developer.healthkit.access` set to `health-records` plus an `NSHealthClinicalHealthRecordsShareUsageDescription` string; read-only, and returns FHIR JSON (`fhirResource`) rather than HK samples. You *can* request these in the same `requestAuthorization` call — HealthKit just shows a second permission sheet — but the parsing is a separate project.
- `HKHeartbeatSeriesSample` — beat-to-beat data, high volume

Generate the type list in code as a `[HealthMetric]` array where each entry carries its identifier, preferred `HKUnit`, aggregation style (cumulative vs. discrete), and whether it participates in daily statistics. This table becomes the single source of truth for both querying and schema generation.

### 3.2 Authorization — the trap

`requestAuthorization(toShare:read:)` shows one sheet listing every type you ask for. Asking for 170 types at once produces a wall of toggles that is easy to reject wholesale.

**Better:** request in **logical groups** with a short in-app explanation before each — Activity, Vitals, Sleep, Body, Nutrition, Reproductive, Other. Let the user enable groups they care about.

Two things that will bite you:

1. **Read authorization is deliberately opaque.** `HKHealthStore.authorizationStatus(for:)` reports *sharing* (write) status only. For reads, Apple's docs are explicit: if permission isn't granted, "it simply appears as if there is no data of the requested type" — so you cannot distinguish "denied" from "authorized but empty." This is intentional, so apps can't infer health conditions from refusals. **Never treat an empty result as a denial**; show "no data found," not "permission denied." (One partial escape hatch: `getEarliestAuthorizedSampleDate(for:)` detects *time-limited* authorization, where the user granted access only from a certain date forward. Worth handling — it silently truncates your history otherwise.)
2. **You only get one prompt per type.** Calling `requestAuthorization` again for already-decided types returns immediately with no UI. Your "fix permissions" flow must deep-link the user to Settings → Privacy & Security → Health → *your app*.

### 3.3 Query strategy

Three query types, three jobs:

**`HKAnchoredObjectQuery` — the workhorse for incremental sync.**
Returns everything added since a saved `HKQueryAnchor`, *plus* a list of `HKDeletedObject` (UUID only) for samples removed since then. Archive the anchor per type with `NSKeyedArchiver` and persist it. This is the only query that correctly handles deletions, which matters because Health data does get retroactively edited.

Do not pass `HKObjectQueryNoLimit` on the first run — a multi-year heart-rate history can be millions of samples and will exhaust memory. Use a bounded `limit` (e.g. 5,000) and loop, persisting the anchor after each successful page.

**`HKStatisticsCollectionQuery` — for trustworthy daily numbers.**
Multiple sources write the same metric: iPhone counts steps, Apple Watch counts steps, and a third-party app may too. Raw samples therefore **overlap and double-count**. Apple's statistics queries deduplicate across sources for cumulative types; raw sample queries do not.

Recommendation: **export both.** Raw samples with full provenance (`HKSource`, `HKDevice`, `HKSourceRevision`) as the audit trail, and Apple-deduplicated daily statistics as the number your workflows actually consume. Mark them clearly with different record kinds so nothing downstream sums the wrong one.

**`HKObserverQuery` + `enableBackgroundDelivery` — for wake-ups.**
Register observers at app launch, every launch. They persist across relaunches, but re-registering is idempotent and cheap.

### 3.4 Background delivery: what actually happens

- `HKUpdateFrequency` offers `.immediate`, `.hourly`, `.daily`, `.weekly`. On iOS, specific types are capped — `stepCount` is hourly at best — while on watchOS most types are hourly-capped. Don't design around real-time delivery.
- **Critical:** HealthKit encrypts its store when the device is locked, so reads fail with `HKError.errorDatabaseInaccessible` while locked (writes are cached and applied later). Your background wake can fire when you cannot read anything. Check `UIApplication.shared.isProtectedDataAvailable`, or observe `protectedDataDidBecomeAvailable`, and defer the read rather than treating the failure as "no data."
- You **must** call the observer's completion handler as soon as you're done. If you don't call it, HealthKit retries with backoff — and per Apple's docs, **if your app fails to respond three times, HealthKit stops sending background updates entirely**. That's a silent, permanent-until-relaunch failure. So: observer fires → enqueue a marker → call completion immediately → do the real work in a `BGProcessingTask`.
- Use `BGProcessingTask` for the read-normalize-enqueue pass and `URLSession` with a **background configuration** for uploads, so transfers survive app termination.

---

## 4. Canonical data model

One flat record shape across all sample kinds. Flat beats faithful — your workflow engine wants uniform rows, not a discriminated union mirroring HealthKit's class hierarchy.

```json
{
  "id": "3F2A9C41-...",
  "kind": "quantity",
  "metric": "HKQuantityTypeIdentifierHeartRate",
  "metric_slug": "heart_rate",
  "value": 72.0,
  "unit": "count/min",
  "start": "2026-07-31T08:14:02+08:00",
  "end":   "2026-07-31T08:14:02+08:00",
  "tz": "Asia/Singapore",
  "aggregation": "discrete",
  "source": {
    "name": "Apple Watch",
    "bundle_id": "com.apple.health.9A8B...",
    "product_type": "Watch7,1",
    "os_version": "18.5"
  },
  "metadata": { "HKWasUserEntered": false },
  "recorded_at": "2026-07-31T08:20:11+08:00",
  "schema_version": 1
}
```

**Non-obvious rules that will save you pain:**

- **Always ship the unit string with the value.** HealthKit forces you to name a unit at read time; if you drop it, the number is meaningless and unit changes become silent data corruption.
- **`start` and `end` differ meaningfully.** Cumulative types (steps, energy) cover an interval — a "500 steps" sample spanning 10 minutes is not a point event. Discrete types (heart rate, weight) are usually instants. Carry `aggregation` so downstream code knows whether summing is valid.
- **Timezone.** Store ISO 8601 with offset. Some samples carry `HKMetadataKeyTimeZone`; when present, prefer it, because it tells you the zone the user was actually in. Daily aggregates must use the user's calendar, not UTC, or your step counts land on the wrong day when travelling.
- **UUID is your natural key.** Stable across reads. Makes upserts idempotent for free.
- **Deletions are first-class.** Emit `{"kind": "delete", "id": "<uuid>", "deleted_at": "..."}` records from the anchored query's deleted-objects list. If you ignore these, your store diverges from Health permanently.
- **`HKWasUserEntered`** distinguishes manual entries from device measurements — often worth filtering on.

**Kind-specific extensions** (same envelope, extra fields):

- `sleep` — `HKCategoryValueSleepAnalysis` gives `inBed`, `asleepUnspecified`, `asleepCore`, `asleepDeep`, `asleepREM`, `awake` (stages since iOS 16). Each is a separate interval sample; a night is dozens of records. Emit raw intervals and optionally a derived per-night summary.
- `workout` — activity type, duration, total energy, total distance, plus `HKWorkoutEvent` array (pause/resume/lap) and an optional route as an encoded polyline or GeoJSON.
- `correlation` — blood pressure as `{systolic, diastolic}` in one record rather than two orphaned samples.
- `statistic` — daily rollups: `{metric, day, sum|avg|min|max, unit, source_count}`.
- `characteristic` — one-off profile record, sent once.

---

## 5. Transport A: push to your API

### Wire format

**NDJSON, gzipped.** One record per line. Streams cleanly, appends cheaply, and your server can process line-by-line without loading the whole batch. JSON arrays force full-document parsing; CSV can't hold nested metadata.

```
POST /v1/health/batches
Authorization: Bearer <device-token>
Content-Type: application/x-ndjson
Content-Encoding: gzip
Idempotency-Key: <batch-uuid>
X-Schema-Version: 1
```

First line is a header record, rest are data:

```json
{"kind":"batch_header","batch_id":"...","device_id":"...","record_count":1420,"window":{"from":"...","to":"..."},"app_version":"1.0.3"}
```

**Response contract:**

```json
{ "accepted": 1420, "rejected": 0, "batch_id": "...", "errors": [] }
```

Return **409 with the original result** for a duplicate `Idempotency-Key` rather than reprocessing. The client will retry after network failures where the request actually succeeded — this is the normal case, not an edge case.

### Reliability

- **Batch size:** cap at ~5,000 records or ~5 MB compressed, whichever hits first.
- **Retry:** exponential backoff with jitter, 2s → 5min ceiling. Retry 5xx, timeouts, and 429 (honour `Retry-After`). Do **not** retry 4xx other than 408/429 — park the batch and surface it in a debug screen instead of looping forever.
- **Advance the anchor only after a 2xx.** If you persist the anchor before confirmed delivery, failure means permanent data loss with no way to detect it.
- **Auth:** a long-lived bearer token in the **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background uploads work on a locked device without the item syncing to iCloud) is proportionate for a single-user self-hosted setup. OAuth is overkill. *Implemented in `Core/Keychain.swift`.*
- **Certificate pinning:** the server certificate is pinned by SHA-256 of its DER encoding (`Export/CertificatePinner.swift`). The destination is a Tailscale host, which can't hold a publicly trusted certificate unless the tailnet enables HTTPS certificates; trusting one certificate is narrower than installing a CA profile, which would apply to every site the phone visits. An empty pin falls back to system validation. mTLS with a client cert in the Keychain remains the next step up.
- **TLS only.** No plaintext, ever — this is health data leaving a device. One narrowly scoped ATS exception does exist, for the single self-signed tailnet host: ATS fails an untrusted certificate with `-1200` *before* the `URLSession` delegate runs, so without it the pinning code is never reached. The exception moves the trust decision to `CertificatePinner`, which demands an exact certificate match — a stricter test than the one ATS was performing. Scoped to one host, `NSIncludesSubdomains` false, TLS 1.2 minimum. Note the Simulator does not enforce this, so it will happily connect where a device refuses.

### Triggering the workflow engine

Two options — pick based on how quickly you need reactions:

1. **Server-side trigger:** ingest endpoint writes to your DB, then fires the workflow (queue message, webhook, direct call). Fast, tightly coupled.
2. **Polling:** engine polls `/v1/health/records?since=<cursor>`. Slower but the ingest path stays dumb and never fails because a downstream workflow broke.

Recommendation: (1) with the trigger **decoupled via a queue** so a broken workflow can never cause ingest to reject data.

---

## 6. Transport B: manual file export

For backfills, debugging, and getting data out when the server is down.

- Write NDJSON (or CSV for a flattened single-metric extract) to the app's Documents directory, then present `UIActivityViewController`.
- Offer a date-range picker and a metric-group filter. A full-history export of everything is unmanageably large through a share sheet.
- Zip if the export exceeds a few MB.
- **Do not default the save location to iCloud Drive.** App Store Review Guideline 5.1.3 prohibits storing users' health information in iCloud. Default to "On My iPhone" and, if you ever ship this publicly, avoid any iCloud sync of health data — including CloudKit and iCloud backup of your SQLite queue. Set `isExcludedFromBackup` on the queue database.
- Nice extra: an **App Intent** so you can trigger an export from Shortcuts or an automation.

---

## 7. Initial backfill

The hardest part operationally. Full history is large and the first sync is where things break.

1. **Ask for a start date** rather than defaulting to all-time. Most people want 1–2 years, not everything since 2015.
2. **Chunk by time window** — one month at a time, oldest first, per metric. Bounded memory, resumable, and progress is legible to the user.
3. **Checkpoint after every chunk.** `(metric, window_end)` in SQLite. Killing the app mid-backfill must not restart from zero.
4. **Foreground-only, with a progress screen.** Background tasks get minutes; a full backfill may need much longer. Show it running and let the user leave it plugged in.
5. **Downsample high-frequency metrics if you don't need raw fidelity.** Heart rate at 5-second intervals during workouts dominates total volume. Per-minute statistics instead of raw samples can cut the payload by an order of magnitude.
6. **Cut over to anchored queries** once the backfill window closes, seeding each anchor from the incremental read.

Consider the shortcut from §0: seed the database from the Health app's own XML export, then start the app in incremental mode only. Much less code, one afternoon of parsing.

---

## 8. Observability

You are going to need this — silent background sync failure is the default failure mode.

**On device:**

- Sync status screen: last successful sync per metric, pending batch count, queue size, last error with timestamp.
- Rolling local log (`OSLog` + a ring buffer you can export via the share sheet).
- Manual "Sync now" button. Non-negotiable for debugging.

**On server:**

- Per-batch record counts, per-metric freshness (last-seen timestamp per metric), rejection reasons.
- **Staleness alert.** If any metric you expect daily hasn't arrived in 48 hours, notify yourself. This catches revoked permissions, background delivery quietly dying after an OS update, and expired tokens — none of which produce an error, just silence.

---

## 9. App Store & privacy constraints

Even for personal use, these shape the design:

- **Guideline 5.1.3:** health data must not be stored in iCloud; must not be used for advertising, marketing, or data mining; must not be shared with third parties without explicit user consent. A privacy policy is required for any HealthKit app submitted to the store.
- **Keep health data out of `UserDefaults`.** Not an explicit Apple rule (the documented storage prohibition is iCloud), but a plist with weaker data protection is the wrong home for it. Use a SQLite file with data protection enabled, excluded from backup.
- **Purpose strings must be specific.** "Reads your health data" gets rejected; "Reads your activity, sleep, and vitals so they can be exported to your personal server" does not. Note also that a missing `NSHealthShareUsageDescription` doesn't degrade gracefully — the app crashes when you call `requestAuthorization`.
- **Data minimisation is still worth it** even self-hosted. Every metric you sync is a metric you have to secure. "Everything available" is a fine starting scope, but consider trimming after a month once you see what your workflows actually use.
- If you ever add write-back to HealthKit, note that writing false or inaccurate data is an explicit rejection reason.

---

## 10. Phasing

| Phase | Scope | Rough effort |
|---|---|---|
| 0 | Xcode project, entitlements, auth flow, read one metric (steps) to console | 0.5 day |
| 1 | Metric table for all types, grouped authorization UI, anchored queries with persisted anchors | 2–3 days |
| 2 | Normalizer → canonical records, incl. sleep/workout/correlation special cases | 2–3 days |
| 3 | SQLite queue, NDJSON serialization, upload with retry + idempotency | 2 days |
| 4 | Server ingest endpoint, idempotent upsert, workflow trigger | 1–2 days |
| 5 | Observer queries + background delivery + `BGProcessingTask`, locked-device handling | 2 days |
| 6 | Backfill engine with chunking and checkpoints | 2 days |
| 7 | File export + share sheet + App Intent | 1 day |
| 8 | Sync status UI, server-side staleness alerting | 1–2 days |

**Ship after Phase 4.** A foreground-only "open app, tap sync" version is genuinely useful and validates the whole pipeline end-to-end before you take on background execution, which is where the subtle bugs live.

---

## 11. Open questions to resolve before Phase 1

1. **Raw samples, daily aggregates, or both?** Both is the safe answer, but it roughly doubles ingest volume and needs clear separation server-side so nothing double-counts.
2. **How far back?** Sets the backfill budget and whether §0's XML shortcut is worth it.
3. **Downsampling policy for high-frequency metrics** — raw heart rate is where 80% of your volume lives.
4. **Server reachability.** Is your API on a public HTTPS endpoint, or behind Tailscale/VPN? The latter means uploads only succeed on certain networks — the queue handles it, but you'll want to detect and surface the condition.
5. **Retention on device.** How long do you keep already-uploaded records in the local queue? Some window is useful for re-sends; unbounded is a liability.
