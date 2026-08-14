# API reference

Every endpoint, what authenticates it, and what it is for. Deploying the server
that serves them is in [../server/README.md](../server/README.md).

**Auth.** `session` is the dashboard's cookie. `bearer` is a token — issued by
signing in (which records who signed in) or minted on the CLI (which has no
owner). Anything reading health data needs one or the other.

---

## Ingest

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/v1/health/batches` | bearer | Ingest an NDJSON batch |
| GET | `/v1/health/ping` | bearer | Cheap probe — powers Test Connection |
| GET | `/v1/health/stats` | bearer | Per-device counts, top metrics |
| GET | `/v1/health/coverage` | bearer | Per-metric high-water marks, for reconciliation |
| POST | `/v1/auth/login` | none | Password → bearer token |
| POST | `/v1/auth/logout` | bearer | Revoke the token that made the request |
| GET | `/healthz` | none | Liveness; touches the database |

`gzip` request bodies are accepted. The status-code contract and the
reconciliation rules are in [../server/README.md](../server/README.md) — they are
the one part of this API where a wrong guess costs real data.

---

## Analysis — deterministic, no model

Same inputs, same output, no network call off the machine. All take `tz` (IANA
name) and most take `as_of`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/analysis/snapshot` | session/bearer | Baselines, trends, coverage |
| GET | `/v1/analysis/trend` | session/bearer | One metric: moving averages, slope |
| GET | `/v1/analysis/quality` | session/bearer | Data-quality report per metric |
| GET | `/v1/analysis/sleep` | session/bearer | Duration, bedtime, consistency |
| GET | `/v1/analysis/nutrition` | session/bearer | Logged intake, days logged, energy balance |
| GET | `/v1/analysis/anomalies` | session/bearer | Sustained shifts from personal baseline |
| GET | `/v1/analysis/correlations` | session/bearer | Pre-registered pairs, Holm-corrected |
| GET | `/v1/analysis/patterns` | session/bearer | Weekend and weekday rhythms |
| GET/POST | `/v1/analysis/goals` | session/bearer | Targets and measured progress |
| DELETE | `/v1/analysis/goals/<id>` | session/bearer | Remove a goal |

## Dashboard analytics

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/analytics/overview` | session/bearer | KPIs + headline charts |
| GET | `/v1/analytics/metrics` | session/bearer | Metric catalog |
| GET | `/v1/analytics/series` | session/bearer | Daily series for one metric |
| GET | `/v1/export/summary` | session/bearer | Row counts for an export |
| GET | `/v1/export/records.csv` | session/bearer | Streaming CSV export |

---

## Insights — a model runs

Slower and non-deterministic. Throttled far tighter than the rest: one question
occupies a local GPU for tens of seconds.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/insights/status` | session/bearer | Where processing happens, model, context, prompt version |
| GET | `/v1/insights/daily` | session/bearer | The morning brief (deterministic — no model) |
| POST | `/v1/insights/ask` | session/bearer | Ask a question |
| POST | `/v1/insights/weekly` | session/bearer | Weekly review |
| DELETE | `/v1/insights/history` | session | Delete every stored question |

### `POST /v1/insights/ask`

```jsonc
{
  "question": "How has my sleep changed?",
  "tz": "Asia/Singapore",       // IANA name; days are cut on it
  "session_id": "<uuid>",       // continue a conversation
  "start_session": true,        // …or open one, in this same request
  "project_id": 3,              // with start_session: file it here
  "context": "…",               // optional free text for this question only
  "remember": false             // store nothing; no chat is opened
}
```

Returns the answer, the safety verdict, the measured snapshot, the tools that
ran, the model, `session_id`, `turn_id`, and `compacted` (how many earlier turns
were folded to make room). **It always returns a payload** — if the model is
unreachable or its output fails the checks, `generated` is false and the
snapshot is still there.

---

## Conversations

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET/POST | `/v1/chat/projects` | session/bearer | Folders and their standing context |
| GET/PATCH/DELETE | `/v1/chat/projects/<id>` | session/bearer | Rename, re-instruct, delete (chats survive) |
| GET/POST | `/v1/chat/sessions` | session/bearer | The history list; open a chat explicitly |
| GET/PATCH/DELETE | `/v1/chat/sessions/<uuid>` | session/bearer | One transcript; rename, file, archive, delete |
| POST | `/v1/chat/sessions/<uuid>/compact` | session/bearer | Fold older turns into a summary (runs the model) |
| GET | `/v1/chat/sessions/<uuid>/export.md` | session/bearer | One conversation, to read |
| GET | `/v1/chat/sessions/<uuid>/export.json` | session/bearer | One conversation, everything |
| GET | `/v1/chat/messages` | session/bearer | Flat message export |
| POST | `/v1/chat/messages/<id>/feedback` | session/bearer | Rate one answer, and say why |
| GET | `/v1/chat/feedback` | session/bearer | Ratings grouped by model and prompt version |

The export extension is in the **path**, not a `?format=` parameter: DRF
reserves that name for content negotiation, so `?format=md` would resolve to "a
renderer called md" and 404 while `?format=json` worked by accident.

### `GET /v1/chat/messages`

The surface a feedback loop reads. Flat across every conversation, **oldest
first** — a loop reads forward from where it stopped, and newest-first paging
shifts every offset each time a question is asked.

| Filter | Meaning |
|---|---|
| `session`, `project` | One conversation, or one folder (`none` for unfiled) |
| `since`, `until` | ISO timestamps. Percent-encode the `+`, though the endpoint restores it |
| `generated=1\|0` | Turns a model answered, or the ones that failed |
| `rated=1\|0` | Judged, or not yet — how you find the next batch to look at |
| `rating=up\|down` | One side of the verdict |
| `prompt_version`, `model` | One side of a change |
| `q` | Substring of the question |
| `limit`, `offset` | Paging; `total` is counted before the page |

Each row is the whole turn: question, structured answer, safety verdict, tool
calls, model, prompt version, latency, tokens, error, rating and note. A
`sessions` block carries each conversation's compaction summary once, so the
export is a faithful record of what the model actually saw.

`retention_days` is in every response, because a caller that assumes it is
reading the whole history will quietly take the last thirty days for everything.

---

## Admin

| Path | Auth | Purpose |
|---|---|---|
| `/dashboard/` | session | The Vue dashboard |
| `/admin/` | session | Browse records, revoke tokens, read stored turns |

---

See also: [CHAT.md](CHAT.md) for the conversation model these endpoints serve,
and [ANALYSIS.md](ANALYSIS.md) for what the analysis endpoints compute.
