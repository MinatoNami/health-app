# Conversations

How a question becomes a conversation, on both the phone and the dashboard.

A question on its own is a transaction. A conversation is what you get when the
answer to "why?" knows what the previous answer said — and when you can leave,
come back a week later, and still find it.

Everything here is server-side. The phone and the dashboard are two views of the
same conversations: ask something on the phone at breakfast, open the dashboard
at lunch, and it is there to continue.

---

## The shape

```
ChatProject          a folder, with standing context every chat inside inherits
  └── ChatSession    one conversation — a title, a compaction summary
        └── InsightTurn   one question and the answer that came back
```

A turn can exist without a session (the weekly-review command can be told to
work that way, and any API caller can omit the session). It is still stored,
still subject to retention, still in the export — it just is not a conversation.

---

## Sessions are the context boundary

A question asked inside a session replays **that session's** earlier turns and
nothing else.

This is not a UI nicety. Scoping to the *person* instead would carry last week's
sleep question into a conversation about food and let the model answer as though
it had been asked — the single most confusing thing a chat history can do.

**A chat is opened by the question, not before it.** `POST /v1/insights/ask`
takes `start_session: true` and creates the conversation in the same request
that stores the first turn. The obvious ordering — create the session, then ask
— leaves an empty chat in the sidebar every time the question behind it never
lands, and the 10/min insight throttle makes that routine rather than
exceptional.

**Only summaries are replayed, never the evidence.** Earlier turns go back as
real assistant messages, capped at `INSIGHT_HISTORY_TURNS` (6), with the system
prompt saying plainly that they are there for continuity and are not
measurements. Every figure in every answer is re-read from the snapshot and the
tools. A model quoting its own earlier prose back is exactly how a number that
was hedged once becomes a fact later.

**The title is the first question, truncated.** Deterministic on purpose: asking
the model for a title would mean a second generation — tens of seconds on a
local GPU — to produce something the first line of the question already says.
Rename by hand and the autotitle never overwrites it again.

---

## Projects are folders with standing context

The grouping is the cheap half. `instructions` is what earns a project a table:
free text you wrote about your own circumstances — *"training for a half
marathon in October; I work nights on Tuesdays"* — prepended to the system
prompt for every chat inside.

It is capped, fenced, and explicitly demoted to background: not a measurement,
nothing in it quotable as a figure, and it relaxes no rule. The post-flight
safety check runs on the *answer* rather than the prompt, so instructions asking
for a diagnosis still produce a blocked answer. There is a test for exactly that.

**Deleting a project keeps its chats** and unfiles them. One mis-click must not
take months of conversations with it.

---

## Compaction

A turn cap alone means turn twenty has silently lost turns one to fourteen. The
bad part is not the forgetting — it is that the transcript still *reads*
complete on screen while the model answers as though the opening never happened.

So when the replayed history will not fit the budget, the older turns are folded
into a written summary and that summary is replayed in their place. Automatic
when the budget is exceeded; on demand through
`POST /v1/chat/sessions/<uuid>/compact`, the **Compact** button in the dashboard
header, or **Compact conversation** in the phone's menu.

Four things are deliberate:

- **The transcript is never rewritten.** Compaction changes what is *sent to the
  model*, nothing else. Both clients draw a seam where the fold is and keep
  every message above it readable.
- **The two most recent turns stay verbatim**, through every pass. The exchange
  you are still in the middle of is where the detail matters most.
- **The summary carries no figures**, by instruction. A number folded in here
  would be quoted weeks later as though it were current.
- **It runs the same prohibited-claim rules as an answer** and is discarded if it
  trips one. A summary is generated prose that a person reads and that is
  replayed into later prompts; exempting it would leave one piece of model
  output nobody checks.

The budget is derived: the context window, minus room for the answer, minus the
system prompt — which carries the snapshot and grows with how many metrics you
record — and history may occupy 35% of what remains. The window itself is asked
for, not configured: LM Studio reports the loaded model's length through
`/api/v0/models`, so swapping a 262k model for an 8k one adjusts by itself.

If compaction fails, the turn cap still bounds the history and the question is
answered anyway. A conversation that cannot be summarised is not a reason to
refuse to answer it.

---

## Feedback

Every answer carries a thumb and a note.

The note is the half worth having: *"used the wrong sleep window"* is something
you can act on, where a hundred bare thumbs-down tell you the score and not the
reason. A second press on the same thumb clears it — a rating you cannot take
back is one nobody trusts enough to give.

It is `POST /v1/chat/messages/<id>/feedback` rather than a `PATCH` on the
message, because the rest of a turn stays read-only: being able to reproduce a
generated health claim later is the whole reason to store one. Feedback is a
judgement recorded alongside it, not a licence to edit it.

**Every turn records `prompt_version`** — a digest of `prompts.py`: the system
prompt, the finalise instruction, the review and compaction prompts, and the
answer schema. Without it, answers written before and after a prompt edit are
indistinguishable and "did my change help?" cannot be asked. A hash rather than
a hand-maintained number, because one of those is only correct while somebody
remembers to bump it — and the turn it is wrong on is the turn you are trying to
explain.

`GET /v1/chat/feedback` is that comparison: overall counts, the same tally
grouped by model and by prompt version, and the answers you marked unhelpful
with their notes. Busiest group first, because a version with two ratings is
noise beside one with two hundred. An unjudged batch scores `null` rather than
zero — no opinion and a bad opinion are different things.

```bash
curl -sH "Authorization: Bearer $TOKEN" 'https://<host>/v1/chat/feedback'
curl -sH "Authorization: Bearer $TOKEN" 'https://<host>/v1/chat/messages?rating=down&limit=200'
```

---

## Retention

Messages are deleted after `INSIGHT_RETENTION_DAYS` (30), and pruning takes the
conversations it empties — a sidebar listing month-old chats that open blank
reads as data loss rather than as the policy working.

Two things survive differently:

- **A rated answer outlives the window.** `INSIGHT_KEEP_RATED` defaults to on. A
  thumb is you explicitly marking an answer as worth keeping, and without this
  the feedback loop could never hold more than thirty days of judged answers.
  Set it to `0` for the stricter behaviour.
- **A compaction summary is cleared** once the newest turn it folded in has aged
  out. It is generated *from* questions; leaving it would make retention
  something you can read around.

`GET /v1/chat/messages` reports `retention_days` in its own response, so a caller
cannot mistake thirty days for everything.

---

## Where the two clients differ

| | Dashboard | Phone |
|---|---|---|
| History | Permanent sidebar, drawer below 860px | Drawer from the toolbar |
| Projects | Create, rename, edit instructions, delete | Shown, grouped; not edited |
| Search | Yes, server-side, reaches question bodies | Yes, same endpoint |
| Rename / archive / delete | Row menu | Swipe actions |
| Compact | Header button | Overflow menu |
| Rating and notes | Yes | Yes |
| Per-chat download | `.md` / `.json` | — |
| Feedback summary | Settings → Answer feedback | — |

The phone deliberately does not edit project instructions: it is standing
context that shapes every answer in a project, and a 2000-character free-text
field is not something to fat-finger on a train.

---

See also: [ANALYSIS.md](ANALYSIS.md) for what the model may reach and what it
refuses to compute, [LLM-SETUP.md](LLM-SETUP.md) for tuning the context and
history settings, and [PRIVACY.md](PRIVACY.md) for what is sent and kept.
