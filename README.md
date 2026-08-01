# Health Exporter

An iOS app that reads Apple Health data and exports it as NDJSON — to files now,
to your own HTTP endpoint when you're ready.

Full design rationale: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Run it on your iPhone

1. **Open the project**

   ```bash
   open HealthExporter.xcodeproj
   ```

2. **Set your signing team.** Select the `HealthExporter` target → *Signing &
   Capabilities* → pick your Team. Change the bundle identifier if
   `com.lionelchong.HealthExporter` is taken.

   If you change the bundle ID, also update the two entries under
   `BGTaskSchedulerPermittedIdentifiers` in `HealthExporter/App/Info.plist` and
   the matching constants in `Sync/BackgroundSync.swift` — background tasks fail
   to schedule if the identifiers don't line up.

3. **Confirm the capabilities came through.** *Signing & Capabilities* should
   list **HealthKit** with **Background Delivery** ticked, and **Background
   Modes** with *Background fetch* and *Background processing*. These come from
   `HealthExporter.entitlements` and `Info.plist`, but Xcode occasionally needs
   the capability re-added by hand for the provisioning profile to pick it up.

4. **Select your iPhone and Run.** HealthKit returns nothing useful in the
   Simulator, and background delivery doesn't work there at all.

5. **Grant access.** Tap *Request Health Access* on the Status tab. You get
   **one** prompt per data type, ever — enable every group you might want on the
   Metrics tab *before* requesting. Afterwards the only way to change your mind is
   Settings → Privacy & Security → Health.

A free Apple ID works but the provisioning profile expires every 7 days, and
Personal Team support for the HealthKit capability is unreliable. For something
that runs continuously in the background, the paid Developer Program is worth it.

---

## What comes out

NDJSON — one JSON object per line — in `Documents/Outbox/`. Reachable from the
Files app under *On My iPhone → Health Exporter*, or via the share sheet on the
Exports tab.

First line of every file is a header:

```json
{"kind":"batch_header","batch_id":"…","device_id":"…","record_count":1420,"app_version":"1.0 (1)","schema_version":1,"created_at":"2026-08-01T09:12:44+08:00"}
```

Then one record per line:

```json
{"id":"3F2A9C41-…","kind":"quantity","metric":"HKQuantityTypeIdentifierHeartRate","metric_slug":"heart_rate","value":72,"unit":"count/min","start":"2026-07-31T08:14:02+08:00","end":"2026-07-31T08:14:02+08:00","tz":"Asia/Singapore","aggregation":"discrete","source":{"name":"Apple Watch","bundle_id":"com.apple.health.…","product_type":"Watch7,1","os_version":"18.5"},"recorded_at":"2026-07-31T08:20:11+08:00","schema_version":1}
```

### Record kinds

| `kind` | Meaning |
|---|---|
| `quantity` | Numeric sample. `unit` always present; `aggregation` says whether summing is valid. |
| `category` | Enumerated sample. `value` is the raw Int, `value_label` the name. |
| `sleep` | Sleep stage interval. `extra.duration_seconds`, `extra.is_asleep`. |
| `workout` | One workout. `extra` has activity type, duration, energy, distance, events. |
| `statistic` | Apple-deduplicated daily rollup. Deterministic ID: `stat:<slug>:<yyyy-mm-dd>`. |
| `characteristic` | Static profile data — DOB, sex, blood type. |
| `delete` | Tombstone. UUID only; HealthKit reports deletions without type or date. |

### Two things that will bite you downstream

**Don't sum `quantity` records for steps.** iPhone and Apple Watch both write
step counts, so raw samples overlap. Use the `statistic` records for totals —
those come from HealthKit's statistics queries, which deduplicate across sources
the way the Health app does. Raw samples are exported for provenance and audit,
not for summing.

**Handle `delete` records.** Health data does get retroactively edited. Ignoring
tombstones means your store diverges from Health permanently, with nothing to
indicate it happened.

---

## Sending to the server

There's a Django server in [server/](server/) that implements this contract, and
a deploy script that puts it on a backend host behind nginx. Start there:

```bash
cd server
./deploy.sh                 # build, push, migrate, verify
./deploy.sh user lionel     # create a login — prompts for a password
```

Then on the phone: Settings tab → *Account* → **Sign In**. The URL and
certificate pin are pre-filled for that server. Signing in exchanges your
password for a bearer token; flip *Upload automatically* once it succeeds.
**Test Connection** proves the URL, the TLS pin, and the token in one request
without sending any health data — worth doing, because from then on failures are
silent by design.

The token is kept in the **Keychain**, not in `sync-settings.json`
(`AfterFirstUnlockThisDeviceOnly`, so background uploads work on a locked device
and the item never syncs to iCloud). **The password is never stored** — it is
used for the single request that returns the token and then discarded.

*Sign Out* revokes the token on the server as well as clearing it locally;
dropping only the local copy would leave a working credential in anyone else's
hands. Each sign-in mints its own token, so revoking one device doesn't sign out
the others.

### Why the certificate is pinned

The server lives on a Tailscale tailnet. A tailnet hostname can't get a
publicly trusted certificate unless HTTPS Certificates are enabled for the
tailnet — and for this one, Tailscale refuses. The alternative, installing a CA
profile on the phone, would make iOS trust that CA for *every* site it visits.

So the app trusts exactly one certificate, by SHA-256 of its DER encoding.
`./deploy.sh pin` prints the current value. An empty pin field means normal
system validation, so pointing the app at a server with a real certificate needs
no code change.

**Pinning alone is not sufficient on a device.** App Transport Security rejects
an untrusted certificate during connection setup and fails with
`NSURLErrorSecureConnectionFailed (-1200)` *before* the `URLSession` delegate is
consulted — so however correct the pinning code is, it never runs. `Info.plist`
therefore carries an `NSExceptionDomains` entry for this one host, which hands
the trust decision to `CertificatePinner` instead. That is stricter than what
ATS would have accepted, not weaker: an exact certificate match rather than
"anything a public CA vouches for".

Two traps worth knowing:

- **The Simulator does not enforce this.** The same build connects happily in
  the Simulator and fails on a phone. Test transport changes on a device.
- **The exception is keyed to the hostname in `Info.plist`.** Pointing the app
  at a *different* self-signed host means adding that host there too. A host
  with a publicly trusted certificate needs no entry — delete the dictionary and
  clear the pin.

### The contract

```
POST /v1/health/batches
Authorization: Bearer <token>
Content-Type: application/x-ndjson
Idempotency-Key: <batch filename>
X-Schema-Version: 1
```

Any other endpoint needs to:

- **Upsert on `id`.** Sample UUIDs are stable across reads, so upserting makes
  retries free. Note that `id` is not always a UUID — daily rollups use
  `stat:<slug>:<yyyy-mm-dd>`.
- **Return the original result for a duplicate `Idempotency-Key`** (200 or 409).
  The client treats 409 as delivered. Retrying a request that already succeeded
  is the normal case after a network blip, not an edge case. Don't return 409
  while the batch is still being written — that tells the client to delete its
  only other copy.
- **Use 5xx / 429 for "try later"** and 4xx for "never going to work." The client
  retries the former with backoff and parks the latter rather than looping.

Batches that fail stay in the outbox and appear on the Exports tab.

---

## How regular pulls work

Three overlapping mechanisms, because no single one is reliable:

1. **`HKObserverQuery` + background delivery** — HealthKit wakes the app when
   data lands. Registered for every enabled type on each launch. Frequency is
   `.hourly`; iOS throttles many types to that anyway.
2. **`BGProcessingTask`** — re-armed after every run, giving a longer runway to
   drain and upload.
3. **On launch and unlock** — a full pass when the app becomes active, and a
   drain of flagged types when the device unlocks.

The observer never does the work itself. It marks the type dirty, persists that
flag, requests a *coalesced* drain, and returns immediately — because if the
completion handler isn't called, HealthKit retries with backoff and **stops
background delivery entirely after three failures**. That failure is silent.

**Sync is strictly serialized**, and this is not optional. `HKObserverQuery` fires
once as soon as it's executed, so registering observers for ~130 types produces
~130 simultaneous drain requests at launch. Run in parallel they re-read the same
types from the same stale anchor, write duplicate batches, clobber each other's
anchors, and exhaust memory. `SyncEngine` gates every entry point behind
`isSyncing` and collapses concurrent requests into a single follow-up pass.

**Expect hourly-ish, not real-time.** And expect nothing at all while the phone
is locked: HealthKit encrypts its store, so reads fail with
`errorDatabaseInaccessible`. The app treats that as "not yet," not as an error,
and picks up on unlock.

### Watching for silent failure

Background sync fails quietly by default. Two things to check:

- **Status tab → Stale metrics.** Anything that produced data before but hasn't
  in 48 hours. Revoked permissions, background delivery dying after an OS update,
  and expired tokens all look like silence.
- **Exports tab → View Log.** Persisted across launches, exportable via the
  share sheet.

---

## Project layout

```
HealthExporter/
├── App/          Entry point, app delegate, Info.plist, entitlements
├── Core/         Logging, timestamps, file-backed state store, Keychain
├── Model/        HealthRecord wire format, JSON-safe value type
├── Health/       Metric catalog, unit resolution, authorization, readers
├── Export/       Normalizers, NDJSON outbox, sink protocol + HTTP sink, pinning
├── Sync/         Sync engine, observers, background tasks
└── UI/           SwiftUI screens

server/           Django ingest server + deploy script (see server/README.md)
server/dashboard/ Vue analytics dashboard (charts, CSV export)
```

Adding or removing Swift files means regenerating the project:

```bash
gem install xcodeproj --user-install
ruby Tools/generate_project.rb
```

The generated `.xcodeproj` is committed, so this is only needed when the file
list changes.

---

## Design decisions worth knowing before you change things

**Anchored queries do both backfill and incremental sync.** Starting from a nil
anchor walks the whole store in insertion order — that *is* the history — and
leaves the anchor correctly positioned for incremental runs. One mechanism, no
cutover, no possibility of a gap. Records older than the backfill date are read
but not emitted, so the cursor advances past ancient data without paying to
normalize and ship it.

**The anchor is only persisted after the page is on disk.** Advancing it earlier
turns any failure into silent, undetectable data loss.

**The spool is load-bearing.** Reads and delivery are decoupled deliberately:
HealthKit hands you data at unpredictable times, and your server may be down.
With a queue, a delivery failure is a retry.

**Units are resolved from the data, not from a table.** HealthKit throws if you
request an incompatible unit, and there's no API mapping types to valid units. A
hard-coded table of ~170 units is ~170 chances to crash. `UnitResolver` tries a
preference, verifies with `is(compatibleWith:)`, and falls back through a ladder
covering every dimension. A wrong preference costs an odd unit choice; it can't
throw.

**Identifiers are raw strings, not typed constants.** `quantityType(forIdentifier:)`
returns nil for anything the OS doesn't know, so the catalog degrades gracefully
instead of failing to compile. Unresolved names are listed in Settings →
Diagnostics so a typo never silently loses a metric.

**Swift 5 language mode.** Strict Swift 6 concurrency turns HealthKit's
non-Sendable sample classes into a wall of errors for no behavioural benefit here.

**No iCloud, anywhere.** App Store Review Guideline 5.1.3 prohibits storing
health information in iCloud, and iCloud Backup counts. Every directory that
touches health data is marked `isExcludedFromBackup` with
`completeUntilFirstUserAuthentication` protection.

---

## Not yet supported

Each of these needs a bespoke reader rather than the generic sample path. Listed
in Settings → Diagnostics too, so the gap stays visible:

| Type | Why it's deferred |
|---|---|
| `HKElectrocardiogram` | Voltage series, ~15k measurements per reading, separate async query |
| `HKHeartbeatSeriesSample` | Beat-to-beat intervals, very high volume |
| `HKWorkoutRoute` | GPS polylines via `HKWorkoutRouteQuery` |
| `HKStateOfMind` (iOS 18) | Valence, labels, associations — its own sample class |
| `HKAudiogramSample` | Per-frequency sensitivity points |
| `HKClinicalRecord` | Separate entitlement, returns FHIR resources |

Everything else in the standard quantity and category catalogs is covered — about
170 types across 11 groups.

## Known rough edges

- **Normalization runs on the main actor.** It yields every 200 samples so the UI
  stays responsive, but a large first sync still feels sluggish. Moving
  `Normalizer` off-actor is the real fix if it bothers you.
- **Batch record counts come from the filename**, not from reading the file.
  Counting newlines to answer "how many records?" made `pendingCount` cost
  O(bytes on disk) and, called after every drain, exhausted the file-descriptor
  limit. Don't reintroduce it.
- **Reproductive health and symptoms default to off.** Toggle them on in Metrics
  before requesting access if you want them.
- **First sync can take a while** with a multi-year history. Keep the app
  foregrounded and the phone charging; anchors checkpoint every page, so
  interrupting it is safe.
