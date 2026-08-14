# Health Exporter — ingest server

Django + DRF endpoint that receives NDJSON batches from the iOS app and stores
them in Postgres. Runs on `alena-server` behind nginx, reachable over Tailscale.

    https://alena-server.tail03bec9.ts.net/v1/health/batches

---

## Deploy

```bash
./deploy.sh                 # build, push, migrate, reload nginx, verify
./deploy.sh user lionel     # create a login the app can sign in with
./deploy.sh token my-phone  # mint a bearer token directly (shown once)
./deploy.sh pin             # print the certificate pin for the app
./deploy.sh rotate-cert     # reissue the TLS keypair (changes the pin)
./deploy.sh backup          # run a database backup now
./deploy.sh backup-verify   # restore the newest backup into a scratch DB
./deploy.sh backup-pull     # copy backups off the server (~/health-backups)
./deploy.sh status          # container + endpoint health
./deploy.sh logs            # tail application logs
```

Everything is idempotent, so re-running is the normal way to ship a change.
Secrets and the TLS keypair are generated on the server on the first deploy and
never regenerated — redeploying does not rotate the pin or invalidate tokens.

The script refuses to reload nginx if the config doesn't validate, and removes
its own site first. This host already serves another app on 443; a bad reload
would take that down too.

### First-time setup

```bash
./deploy.sh
./deploy.sh user lionel     # prompts for a password
```

Then in the app: **Settings → Account → Sign In**. The URL and certificate pin
are pre-filled for this server. Signing in exchanges the password for a bearer
token, which is stored in the Keychain — the password itself is never written to
the device. Then turn on *Upload automatically*; **Test Connection** confirms
URL, pin, and token before any health data moves.

`./deploy.sh token <label>` still works if you'd rather paste a token directly;
those tokens simply have no owner attached.

### Authentication

| | |
|---|---|
| `POST /v1/auth/login` | `{username, password, device_label?}` → `{token, label, username}` |
| `POST /v1/auth/logout` | Revokes the token that made the request |

A **fresh token is minted per sign-in** rather than returning an existing one —
only the digest is stored, so there is nothing to return, and each device gets a
token that can be revoked on its own. Signing out revokes server-side, so a copy
of the token left anywhere else stops working too.

Login is **throttled to 10/min per IP** (`LOGIN_RATE_LIMIT` in `.env`). It is
the only endpoint that accepts a password, and therefore the only one worth
guessing at. Ingest is deliberately *not* throttled: the phone legitimately
drains a backlog of batches back to back.

The throttle counter lives in a **database-backed cache**, not Django's default
`LocMemCache` — that one is per-process, so with two gunicorn workers a 10/min
limit silently becomes 20/min and resets whenever a worker recycles.

---

## Why the endpoint looks like this

**Upsert on `id`, always.** Sample UUIDs are stable across reads, so a retry of
a request that already landed is free. That is the common case after a network
blip, not an edge case.

**`id` is a string, not a UUID.** Daily rollups use `stat:<slug>:<yyyy-mm-dd>`
so re-sending a day corrects it in place. A UUID column would reject them.

**Duplicate `Idempotency-Key` replays the original response.** The stored
response body is returned verbatim with `duplicate: true`.

**A batch still in flight gets 503, not 409.** The client treats 409 as "safely
stored, archive it". Saying that while the outcome is unknown would let it
delete the only other copy.

**One corrupt line is skipped, not fatal.** Any non-retryable 4xx parks a batch
on the phone permanently, so a single bad line must not cost the other 4,999
records. A body that is *mostly* unreadable — more than 5 bad records and over
10% of them — is still rejected outright.

**Deletion is one-way.** `deleted_at` is excluded from the upsert, so re-sending
an old batch cannot resurrect a record that HealthKit has since tombstoned.
Tombstones for records that were never received are stored anyway: a sample can
be deleted before the first sync ever shipped it.

### Status codes

| Code | Meaning | Client behaviour |
|---|---|---|
| 200 | Stored (or duplicate replay) | Archive the batch |
| 400 | Malformed body, bad header, unsupported schema | **Park permanently** |
| 401 | Missing, invalid, or revoked token | Park permanently |
| 413 | Body over 64 MB | Park permanently |
| 429, 5xx | Try again later | Retry with backoff |

---

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/dashboard/` | session | Vue analytics dashboard |
| GET | `/v1/analytics/overview` | session/bearer | KPIs + headline charts |
| GET | `/v1/analytics/metrics` | session/bearer | Metric catalog |
| GET | `/v1/analytics/series` | session/bearer | Daily series for one metric |
| GET | `/v1/export/records.csv` | session/bearer | Streaming CSV export |
| GET | `/v1/analysis/snapshot` | session/bearer | Baselines, trends, coverage — no model |
| GET | `/v1/analysis/trend` | session/bearer | One metric: moving averages, slope |
| GET | `/v1/analysis/quality` | session/bearer | Data-quality report per metric |
| GET | `/v1/analysis/sleep` | session/bearer | Duration, bedtime, consistency |
| GET | `/v1/analysis/nutrition` | session/bearer | Logged intake, days logged, energy balance |
| GET | `/v1/analysis/anomalies` | session/bearer | Sustained shifts from personal baseline |
| GET | `/v1/analysis/correlations` | session/bearer | Pre-registered pairs, Holm-corrected |
| GET | `/v1/analysis/patterns` | session/bearer | Weekend and weekday rhythms |
| GET/POST | `/v1/analysis/goals` | session/bearer | Targets and measured progress |
| GET | `/v1/insights/status` | session/bearer | Where summaries are processed |
| POST | `/v1/insights/ask` | session/bearer | Ask a question (runs the model) |
| POST | `/v1/insights/weekly` | session/bearer | Weekly review |
| GET/DELETE | `/v1/insights/history` | session | Stored questions; permanent deletion |
| GET/POST | `/v1/chat/projects` | session/bearer | Folders of chats, and their standing context |
| GET/PATCH/DELETE | `/v1/chat/projects/<id>` | session/bearer | Rename, re-instruct, delete (chats survive) |
| GET/POST | `/v1/chat/sessions` | session/bearer | The sidebar's list; start a chat |
| GET/PATCH/DELETE | `/v1/chat/sessions/<uuid>` | session/bearer | One transcript; rename, file, delete |
| POST | `/v1/chat/sessions/<uuid>/compact` | session/bearer | Fold older turns into a summary (runs the model) |
| GET | `/v1/chat/sessions/<uuid>/export.md\|.json` | session/bearer | One conversation as a file |
| GET | `/v1/chat/messages` | session/bearer | Flat message export, filterable and paginated |
| POST | `/v1/chat/messages/<id>/feedback` | session/bearer | Rate one answer, and say why |
| POST | `/v1/health/batches` | Bearer | Ingest an NDJSON batch |
| GET | `/v1/health/ping` | Bearer | Cheap probe — powers Test Connection |
| GET | `/v1/health/stats` | Bearer | Per-device counts, top metrics |
| GET | `/healthz` | none | Liveness, touches the database |
| — | `/admin/` | session | Browse records, revoke tokens |

`gzip` request bodies are accepted (`Content-Encoding: gzip`) even though the
current client uploads uncompressed.

### Reconciliation — the one contract to get right

`GET /v1/health/coverage` exists so a server that has silently lost data gets it
re-sent. The client compares it against its own anchors and, on a mismatch,
**clears the anchor and re-reads that type's entire history**. That is expensive
and user-visible, so a false positive is not a cosmetic bug — and both ways it can
go wrong have happened here:

**Compare the same slug.** The client asks about the slug its records were
*uploaded* under, which is not always the one derived from the HealthKit
identifier: workouts ship as `workout`, not `hk_workout_type_identifier`. Asked
about the derived slug, the server — holding all 126 of them — answered nothing,
and the client concluded every workout had been lost and re-uploaded the lot on
every launch. Both sides now ask `Normalizer.uploadSlug(for:)`.

**Compare the same instant.** The client's high-water mark is an **end** date.
For a sample that spans a period the two ends differ by the length of that period
— Apple's walking steadiness covers exactly seven days, a low-cardio-fitness event
up to eighty-one — so comparing an end against `latest_sample_at` (a *start*) put
both permanently outside the 24-hour tolerance and rewound them every launch, on
data that was never missing. Coverage therefore reports **both**:

| Field | Meaning |
|---|---|
| `latest_sample_at` | `Max(start)` of the newest sample |
| `latest_sample_end` | `Max(end)` — what an anchor's `lastSampleEnd` is comparable with |
| `count` | Live rows, tombstones excluded |

A client too old to know about `latest_sample_end` gets **no date check at all**
rather than the wrong one: the count check still catches real loss, and re-reading
years of history to repair data that was never lost is the more expensive mistake.

Two further rules this endpoint depends on: it is **never capped** (a metric
absent from the list means "absent from the server" to the client, so slicing to
the top 60 for display would rewind everything beyond it), and **tombstoned rows
are excluded**, so a deleted sample cannot hold the high-water mark above what the
server would actually serve back.

For an admin login:

```bash
ssh alena-tailscale 'cd health-server && docker compose run --rm web python manage.py createsuperuser'
```

---

## Backups

`deploy.sh` installs a nightly `cron.d` job at 03:20 that dumps the database to
`/var/backups/health/`, gzipped, with 30-day retention. The dump is written to a
`.partial` file and renamed only on success, then integrity-checked with
`gzip -t` — an interrupted run leaving a truncated file that *looks* like a
backup is how you discover you have none. Retention runs after the new backup
succeeds, so a failing run never prunes the last good copy.

Dumps are encrypted with gpg (AES-256, symmetric) before they touch the disk.
Be precise about what that buys, because the passphrase lives in `.env` on the
same machine:

- **Protected:** copies pulled to a laptop, backup media, and anyone who ends up
  with the files but not the `.env` — most of the realistic ways a dump escapes.
- **Not protected:** someone who already has root on the server.

```bash
./deploy.sh backup-key      # print the passphrase — save it OFF this machine
```

That last point is not optional. The passphrase sits on the server it protects,
so if the machine dies you have encrypted backups and no way to open them, which
is the same as having none.

```bash
./deploy.sh backup-verify   # restores the newest dump into a scratch database
./deploy.sh backup-pull     # copies them to ~/health-backups
```

**A backup nobody has restored is a hypothesis.** `backup-verify` loads the
newest dump into a throwaway database, counts rows, and drops it. Verified at
1,285,705 records.

`backup-pull` is the part that matters for hardware failure — a backup on the
same disk as the database only survives mistakes, not a dead drive. Worth
running periodically, or wiring into a cron on your laptop.

---

## Dashboard

`https://alena-server.tail03bec9.ts.net/dashboard/` — Vue 3 + Vite, built by
`./deploy.sh` and served as static files by nginx. Sign in with the same account
the app uses (`./deploy.sh user <name>`).

Five views: **Overview** (KPI tiles and headline charts), **Insights** (chats
down the left, the conversation in the middle, the measured week on the right),
**Explore** (any metric, any valid aggregation), **Export** (pick metrics and a
range, see the row count, download CSV) and **Settings** (goals, where
processing happens, retention).

### Don't sum raw samples

iPhone and Apple Watch both write step counts for the same walk, so summing raw
`quantity` records inflates every cumulative total. On this data that is **~1.9×
and as much as 3.5×** — one day reads 31,756 steps raw against Apple's 9,008.

HealthKit's statistics queries deduplicate across sources, and the app ships
those as `kind=statistic` rows. Those win wherever they exist. But the app only
re-emits a rolling window (`statisticsLookbackDays`, 7 by default), so older days
have no rollup and can only be estimated from raw samples — those are summed,
**flagged `may_double_count`, and labelled "≈ estimated"** in the UI rather than
presented as fact. Raising the lookback in the app's Settings backfills
authoritative rollups for more days.

Averages, minima and maxima are unaffected; only sums can be inflated this way.

**Sleep is computed separately.** A sleep record's `value` is a category code
(1 = asleepUnspecified), so averaging it is meaningless — the duration lives in
`extra.duration_seconds`. Nights are bucketed by wake time, and `inBed`
intervals are excluded because they overlap the asleep ones.

### Charts

Hand-rolled SVG rather than a chart library, to hold the mark specs exactly:
2px lines, ≤24px bars with a 4px rounded data-end square at the baseline, 2px
surface gaps, hairline solid gridlines, selective direct labels (endpoint and
extreme only), and a crosshair tooltip. Every chart has a **table view**, so no
value is reachable by colour or hover alone. The categorical palette was checked
with the dataviz validator in both light and dark modes.

---

## Security

- **Tokens are stored as SHA-256 digests.** The raw value is shown once at
  creation and is unrecoverable — a database dump yields nothing usable.
- **Postgres publishes no port.** It is reachable only from the web container;
  binding 5432 on this host would expose it to the whole tailnet.
- **Login is rate-limited per real client IP.** `NUM_PROXIES=1` plus nginx
  overwriting `X-Forwarded-For` — with nginx *appending* and DRF reading the
  first entry, one spoofed header bought a fresh bucket and the limit was
  decorative. Analytics reads (240/min) and exports (12/min) are throttled too,
  using `SimpleRateThrottle`: `ScopedRateThrottle` reads `throttle_scope` off
  the view and silently allows everything without it.
- **gunicorn binds 127.0.0.1 only.** nginx terminates TLS; without this there
  would be an unencrypted copy of the endpoint on the tailnet.
- **The certificate is self-signed and pinned by the app.** Tailscale refused a
  Let's Encrypt certificate for this tailnet (`HTTPS Certificates` is off in the
  admin console), and installing a CA profile on the phone would make it trust
  that CA for every site. Pinning one certificate is narrower and stronger.
- **The keypair is ECDSA P-256, not RSA.** This is a size constraint, not a
  cryptographic preference. The certificate travels inside the TLS handshake,
  and the tailnet MTU is 1280 bytes; an RSA-4096 certificate is 1431 bytes on
  its own, so the handshake could not fit in one packet and failed with "An SSL
  error has occurred" on relayed paths — a phone on cellular, not a laptop on
  the same LAN. P-256 brings it to 522 bytes and is comparable in strength to
  RSA-3072.

Rotating the certificate changes the pin. `SinkConfiguration.supersededPins` in
the app carries old pins forward automatically, because the persisted settings
value otherwise wins over the new default and strands the install.

**The app needs an ATS exception for this host, not just the pin.** iOS rejects
an untrusted certificate with `-1200` before the `URLSession` delegate runs, so
pinning alone never gets a chance; `HealthExporter/App/Info.plist` names this
hostname under `NSExceptionDomains`. If you change `SERVER_NAME`, change it
there too. The iOS Simulator does not enforce this and will connect regardless —
transport changes have to be tested on a device.

If you later enable HTTPS certificates for the tailnet, switch to a real
certificate with `tailscale cert`, point nginx at it, and clear the pin field in
the app — an empty pin falls back to normal system validation.

---

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
DJANGO_SECRET_KEY=dev POSTGRES_PASSWORD=dev \
  .venv/bin/python manage.py test tests --settings=healthserver.settings_test
```

348 tests. The suite runs on SQLite so it needs no database server; the ingest
path uses `ON CONFLICT DO UPDATE`, which both engines support.

The analysis tests are worth reading before changing that layer, because most of
them assert a *refusal* rather than a calculation — any statistics library can
compute a 7-day mean, and the value here is that it declines to compute one from
two days of data. `test_correlations.py` goes furthest: it feeds the engine data
with a known answer and checks it does not overclaim — independent noise must
return nothing, a planted relationship must come back with the right sign, a thin
overlap must be refused, and one marginal hit among fourteen questions must not
survive correction.

To exercise the real thing:

```bash
ssh alena-tailscale 'cd health-server && docker compose run --rm web python manage.py test tests'
```

### Layout

```
server/
├── deploy.sh              Deployment (build, cert, nginx, migrate, verify)
├── deploy/nginx-health.conf
├── docker-compose.yml     Postgres + gunicorn
├── healthserver/          Django project settings
├── ingest/
│   ├── models.py          Device, ApiToken, Batch, Record, Goal, ChatProject,
│   │                      ChatSession, InsightTurn
│   ├── ndjson.py          Streaming line reader
│   ├── service.py         Batch → rows, upsert, tombstones
│   ├── auth.py            Bearer token authentication
│   ├── parsers.py         Hands DRF the raw stream
│   ├── views.py           Endpoints and status-code policy
│   ├── analytics.py       Dashboard aggregation (rollups over raw sums)
│   ├── health_analysis.py Baselines, trends, coverage grading
│   ├── nutrition.py       Nutrient units, and logged vs unlogged days
│   ├── correlations.py    Pre-registered pairs, Spearman, Holm correction
│   ├── patterns.py        Weekend and weekday rhythms
│   ├── safety.py          Rule-based escalation, before and after the model
│   ├── insight_views.py   /v1/analysis/* and /v1/insights/*
│   ├── chat_views.py      /v1/chat/* — conversations, projects, message export
│   └── llm/
│       ├── client.py      OpenAI-compatible chat over the tailnet
│       ├── tools.py       The read-only tools the model may call
│       ├── prompts.py     System prompt and the structured answer schema
│       └── service.py     snapshot → safety → tools → answer → safety
└── tests/                 Contract, analysis, and safety tests
```

---

## Insights

```
HealthKit → validated storage → deterministic summaries → controlled LLM → cautious explanations
```

The split that matters is between `/v1/analysis/*` and `/v1/insights/*`. Analysis
is arithmetic: same inputs, same output, no network call off the machine. Insights
asks a language model to explain that arithmetic, and is slower and
non-deterministic. The dashboard labels them differently for the same reason.

**The model never does arithmetic.** It reaches data through twelve read-only
tools that return already-computed figures with units, windows, valid-day counts
and confidence attached. No SQL, no credentials, no raw rows.

**Three rules shape every number:**

- Windows end *yesterday*. Today is partial, and a half day of steps against
  full-day baselines reads as a collapse in activity that is only the clock.
- The 7-day current window and the 28-day baseline do **not** overlap.
- Coverage travels with every figure. A weekly average built from two recorded
  days is not a weekly average, and the payload says so.

**Safety is decided by rules, not by the model.** Anything that reaches `urgent`
— a reported symptom like chest pain — is answered from reviewed text with the
model never called. A post-flight pass blocks diagnoses, medication advice and
claims that wearable data rules out illness, with negation guards, because "this
data cannot rule out an illness" is the phrasing the prompt *asks* for.

If the model server is unreachable, slow, or produces something the checks
reject, the measured snapshot is still returned. That part was measured.

**[docs/ANALYSIS.md](../docs/ANALYSIS.md) is the full account** of what each layer
computes and what it refuses to compute: metric specs and confidence grading,
nutrition (including why a missing day is not a fast and why nutrients arrived in
kilograms), the correlation engine's pre-registered pairs and multiple-comparison
correction, pattern discovery, and the twelve tools. What follows here is how to
run it.

### Conversations

A question on its own is a transaction. A conversation is what you get when the
answer to "why?" knows what the previous answer said, and that is what
`/v1/chat/*` adds: named chats, optionally filed into projects, listed in the
dashboard sidebar the way anyone would expect.

**The session is the context boundary.** A question asked inside a session
replays that session's earlier turns and nothing else. Scoping to the *person*
instead would carry last week's sleep question into a conversation about food and
let the model answer as though it had been asked — which is the single most
confusing thing a chat history can do. Sessionless questions (the phone, the
`weekly_review` command) still work and still carry nothing.

**Only summaries are replayed, never the evidence.** Earlier turns go back as
real assistant messages, capped at `INSIGHT_HISTORY_TURNS` (6), with the system
prompt saying plainly that they are there for continuity and are not
measurements. Every figure in every answer is re-read from the snapshot and the
tools. A model quoting its own earlier prose back is exactly how a number that
was hedged once becomes a fact later.

**A project is a folder with standing context.** The grouping is the cheap half.
`instructions` is the part that earns the model a row in the database: free text
someone wrote about their own circumstances — "training for a half marathon in
October" — prepended to the system prompt for every chat inside, capped, fenced,
and explicitly demoted to background. It never relaxes the safety rules, which
run on the answer rather than the prompt; there is a test for that. Deleting a
project keeps its chats and unfiles them.

**A long chat compacts rather than forgetting.** A turn cap alone means turn 20
has silently lost turns 1–14, which is worse than it sounds: the conversation
still *reads* complete on screen while the model answers as though the opening
never happened. So when the replayed history would not fit the budget, the older
turns are summarised into the session and that summary is replayed in their
place. `POST /v1/chat/sessions/<uuid>/compact` does it on demand; the dashboard
puts a **Compact** button in the chat header and draws a seam in the transcript
where the fold is, with the summary one click away.

Four things about it are deliberate:

- **The transcript is never rewritten.** Compaction changes what is *sent to the
  model*, nothing else. Destroying what was actually said to save room would be
  a strange trade in a system built around answers you can go back and check.
- **The two most recent turns always stay verbatim**, through every pass. The
  exchange somebody is still in the middle of is where the detail matters most.
- **The summary carries no figures.** It records what was asked and what the
  person said about themselves — not averages, counts or dates. A number folded
  in here would be quoted weeks later as though it were current, and every
  figure is re-read from the live snapshot on every turn anyway.
- **It goes through the same prohibited-claim rules as an answer**, and is
  discarded if it trips one. A summary is generated prose that a person reads
  and that is replayed into later prompts; exempting it would leave one piece of
  model output nobody checks.

The budget is derived, not fixed: the context window, minus room for the answer,
minus the system prompt — which carries the snapshot and grows with how many
metrics you record — and history may occupy 35% of what remains. Auto-compaction
fires only when that is exceeded, because it costs a whole extra model call. If
it fails, the turn cap still bounds the history and the question is answered
anyway; a conversation that cannot be summarised is not a reason to refuse to
answer it.

**The context window is asked for, not configured.** LM Studio reports the
loaded model's length through its own `/api/v0/models`, which is the only place
it is available — the OpenAI-compatible `/v1/models` follows a schema with no
field for it. So swapping a 262k model for an 8k one adjusts the budget by
itself, instead of leaving a hand-maintained number to go stale and truncate an
answer halfway through. `LLM_CONTEXT_TOKENS` overrides it when you want a
smaller working window than the model technically has, and a server that cannot
answer falls back to a conservative 8192.

**`GET /v1/chat/messages` is the export.** Flat across every conversation,
oldest first, filterable by `session`, `project`, `since`/`until`, `generated`
and `q`, paginated with `limit`/`offset`, and `total` counted before the page:

```bash
curl -sH "Authorization: Bearer $TOKEN" \
  'https://<host>/v1/chat/messages?since=2026-08-01T00:00:00Z&generated=1&limit=200'
```

Each row is the whole turn — question, structured answer, safety verdict, which
tools ran, which model answered, how long it took, how many tokens it cost, and
what failed. Prose alone
cannot tell you whether an answer was any good; the machinery around it is most
of the signal, which is why the endpoint returns it and why a bearer token is
enough to read it. Oldest-first is not a style choice: a loop reads forward from
where it stopped, and newest-first paging shifts every offset each time a
question is asked.

**The verdict is the missing half, and it comes from you.** Every answer in the
dashboard carries a thumb and a note, saved through
`POST /v1/chat/messages/<id>/feedback` (`{"rating": 1 | -1 | null, "note": "…"}`).
The note is the part worth having: *"used the wrong sleep window"* is something
you can act on, where a hundred bare thumbs-down tell you the score and not the
reason. Filter the export by `rated=0` to find what you have not judged yet, or
`rating=down` to pull the failures with their tool calls and safety verdict
attached:

```bash
curl -sH "Authorization: Bearer $TOKEN" \
  'https://<host>/v1/chat/messages?rating=down&limit=200'
```

It is a dedicated path rather than a `PATCH` on the message because the rest of
a turn stays read-only — being able to reproduce a generated health claim later
is the whole reason to store one. Feedback is a judgement recorded alongside it,
not a licence to edit it. And it lives on the turn, so **it expires with the
turn**: rate as you go and export regularly, or raise `INSIGHT_RETENTION_DAYS`.

**One conversation can also leave as a file**, through
`/v1/chat/sessions/<uuid>/export.md` or `.json` — Markdown for reading or
printing, JSON for everything the row holds. The Markdown carries the confidence,
the limitations and the review flag alongside each answer, because an answer
separated from its caveats is exactly the artefact this system spends its effort
not producing. The extension is in the path rather than a `?format=` parameter:
DRF reserves that name for content negotiation, so `?format=md` would resolve to
"a renderer called md" and 404 while `?format=json` worked by accident.

### Running and testing it

Pointing the server at LM Studio over the tailnet, and the checks that matter
once it answers — grounding against the snapshot, missing data reported as
missing, and the safety short-circuit returning without ever calling the model —
are in **[docs/LLM-SETUP.md](../docs/LLM-SETUP.md)**.

Questions and answers are kept for `INSIGHT_RETENTION_DAYS` (30 by default) and
then deleted. The snapshot they were built from is deliberately not stored: it is
recomputable from records already in the database, so a second copy would only
widen what a deletion request has to reach.

Chats are made of those questions, so retention bounds the history too. Pruning
takes the emptied conversations with it — a sidebar listing month-old chats that
open blank reads as data loss rather than as the policy working — and
`/v1/chat/messages` states the window in its own response, so a caller cannot
mistake thirty days for everything.

---

## Knowing when a signal dies

The default failure mode of this whole architecture is **silence**. A revoked
Health permission, a watch left in a drawer, and background delivery dying after
an OS update all look exactly like a quiet week. Sleep stopped uploading on
2026-06-27 and nothing said so for 35 days.

So the check runs on a timer and pushes, rather than waiting to be visited:

```bash
./deploy.sh alerts https://ntfy.example.com/health-sync   # where to push
./deploy.sh alerts check     # what is stale right now, sends nothing
./deploy.sh alerts test      # force one through, to prove the webhook works
./deploy.sh alerts off
```

Installed by `deploy.sh` as cron: freshness daily at 09:00, weekly review on
Mondays at 08:30, both logging to `/var/log/health-freshness.log`.

Two things keep it from becoming noise people mute:

- **Thresholds follow expected cadence.** Weight is not step count; alerting
  after 48h on a metric recorded twice a week trains you to ignore the alert.
- **It has state.** A dead metric is reported once, then at most weekly.
  Recovery is reported too, so you learn the fix worked without going to look.

Without `ALERT_WEBHOOK_URL` the check still runs and logs — but logging is what
it already did, and that is what failed for 35 days.

What leaves the tailnet when an alert fires is metric names and dates ("Sleep
duration: last recorded 2026-06-27"), never measurements. Still health-adjacent,
so a self-hosted receiver is the better choice.

The weekly review uses `--skip-if-unreachable`: the model lives on a laptop, and
a shut laptop is the normal case rather than a fault worth mailing about.

---

## Deleting everything

```bash
./deploy.sh purge
```

Prints what it will destroy and, more usefully, what it will not: the backups,
any copies pulled to your laptop, and the data still in Apple Health — which
re-uploads on the next sync unless you also reset the cursors in the app. See
[docs/PRIVACY.md](../docs/PRIVACY.md).
