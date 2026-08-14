# Architecture

The system as built. For the design document written before it,
see [ORIGINAL-PLAN.md](ORIGINAL-PLAN.md) — where the two disagree, this one is
right.

---

## Shape

```
   iPhone                    alena-server                     MacBook
┌────────────┐   TLS,     ┌──────────────────┐   WireGuard  ┌───────────┐
│ HealthKit  │  pinned    │ Django + DRF     │  over the    │ LM Studio │
│    ↓       │  cert      │      ↓           │  tailnet     │  (a model │
│ Normalizer │ ─────────▶ │  Postgres        │ ───────────▶ │   you own)│
│    ↓       │            │      ↓           │              └───────────┘
│  Outbox    │            │  analysis        │
└────────────┘            │      ↓           │   nginx
                          │  safety → LLM    │ ◀────────── Vue dashboard
                          └──────────────────┘
```

Three components, one direction of trust: the phone sends, the server computes,
the model explains. Nothing flows back into the health record.

| | |
|---|---|
| [The phone](MOBILE.md) | Reads HealthKit, uploads, and is the everyday client |
| [The server](../server/README.md) | Stores, computes, and controls the model |
| [The dashboard](DASHBOARD.md) | The wide view: charts, exploration, export, feedback |

---

## The pipeline

```
HealthKit → validated storage → deterministic summaries → controlled LLM → cautious explanations
```

The split that matters is between `/v1/analysis/*` and `/v1/insights/*`.
Analysis is arithmetic: same inputs, same output, no network call off the
machine. Insights asks a language model to explain that arithmetic. Both clients
label them differently for the same reason.

---

## The invariants

These are the rules the whole thing is organised around. Most of the code that
looks over-careful is enforcing one of them.

**The model never does arithmetic.** It reaches data through twelve read-only
tools that return already-computed figures with units, windows, valid-day counts
and confidence attached. No SQL, no credentials, no raw rows.

**Windows end yesterday.** Today is partial, and a half day of steps against
full-day baselines reads as a collapse in activity that is only the clock. The
7-day current window and the 28-day baseline do not overlap.

**Coverage travels with every figure.** A weekly average built from two recorded
days is not a weekly average, and the payload says so.

**A gap is not a zero.** A watch that was not worn is not a night without sleep.
Metrics that stopped arriving are reported as *stopped arriving*, with a date.

**Days are cut in the caller's timezone.** Every endpoint that slices by day
takes `tz`; both clients send it. The model is told the current local date and
time so "this week" resolves against a real clock rather than whatever calendar
it was trained on — and told in the same breath that it has no figures for today.

**Safety is decided by rules, not by the model.** Anything reaching `urgent` — a
reported symptom like chest pain — is answered from reviewed text with the model
never called. A post-flight pass blocks diagnoses, medication advice and claims
that wearable data rules out illness, with negation guards, because "this data
cannot rule out an illness" is the phrasing the prompt *asks* for.

**Degradation beats failure.** If the model server is unreachable, slow, or
produces something the checks reject, the measured snapshot is still returned.
That part was measured.

**One implementation of anything subtle.** Baselines, coverage grading, the
safety verdict, which turns belong to a conversation — all server-side, decoded
by the clients rather than re-derived. A phone quietly disagreeing with the
dashboard about the same week is worse than either number alone.

---

## Data model

```
Device ─┬─ Batch ─── Record          the health record
        └─ ApiToken

ChatProject ── ChatSession ── InsightTurn      the conversations
Goal, AlertState                               targets, and the freshness notifier
```

`Record.id` is the client's id and is a **string**, not a UUID: daily rollups use
a deterministic `stat:<slug>:<yyyy-mm-dd>` so re-sending a day upserts instead of
duplicating. Modelling it as a UUID column is the single easiest way to break
rollups.

Every write is an upsert on that id, because a retry of a request that already
landed is the common case after a network blip, not an edge case. Deletion is
one-way: `deleted_at` is excluded from the upsert, so re-sending an old batch
cannot resurrect a record HealthKit has since tombstoned.

---

## The reconciliation contract

`GET /v1/health/coverage` exists so a server that has silently lost data gets it
re-sent. The client compares it against its own anchors and, on a mismatch,
clears the anchor and re-reads that type's entire history.

That is expensive and user-visible, so a false positive is not cosmetic — and
both ways it can go wrong have happened here. The details are in
[../server/README.md](../server/README.md), and it is the one part of this system
where a wrong guess costs real data.

---

## Failure modes it is built against

**Silence.** The default failure of the whole architecture is that nothing
errors and the numbers just stop. A revoked token, a disabled HealthKit type, a
phone that stopped syncing — all look identical to "nothing happened this week".
Hence the freshness check, the coverage report, and metrics reported as *not
syncing* rather than as zero.

**Quiet disagreement.** Two implementations of one calculation drifting apart.
Hence one implementation, server-side, decoded everywhere else.

**Plausible wrongness.** A generated health claim that reads well and is not
supported. Hence structured output, tools that return pre-computed figures,
confidence grades that travel with the numbers, and a post-flight check that
blocks rather than edits — a silently deleted sentence leaves an answer that
reads as complete but no longer says what the model concluded.

**Storage creep.** A feature that quietly becomes indefinite retention of health
questions. Hence pruning, and the export stating the window it is bounded by.

---

## Reading order

| | |
|---|---|
| [ANALYSIS.md](ANALYSIS.md) | What each layer computes — and refuses to compute |
| [CHAT.md](CHAT.md) | Conversations: sessions, projects, compaction, feedback |
| [API.md](API.md) | Every endpoint |
| [MOBILE.md](MOBILE.md) / [DASHBOARD.md](DASHBOARD.md) | The two clients |
| [LIFECYCLE.md](LIFECYCLE.md) | App startup, caching, main-thread rules |
| [LLM-SETUP.md](LLM-SETUP.md) | Pointing the model layer at your machine |
| [PRIVACY.md](PRIVACY.md) | What is collected, where it goes, how to delete it |
