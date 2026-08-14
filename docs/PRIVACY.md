# Privacy

What this system holds, where it goes, and how to get rid of it.

This describes a **self-hosted, single-person deployment**: one phone, one server
on a private Tailscale network, one model running on a laptop. Nothing here is a
promise made by a company — it is a description of what the code actually does,
and it is checked against the code rather than aspirational.

---

## What is collected

Whatever HealthKit types you enable in the app's **Metrics** tab, and nothing
else. The app asks for read access per type; anything you decline is never read.

For each sample the app stores the measurement, its unit, its start and end
times, the timezone, and provenance — which app and which device recorded it,
and whether it was typed in by hand rather than measured. Provenance is kept
because it changes what the number means: two devices writing the same walk
inflate a naive step total, and a hand-typed weight is a different kind of
measurement from a scale reading.

Also stored: workouts (activity, duration, energy estimate, distance), sleep
stage intervals, one-off profile characteristics, and Apple's own deduplicated
daily totals.

**Not collected:** location or workout routes, ECG voltage traces, clinical
records from healthcare providers, and audiograms. Some are on the roadmap; none
are read today.

---

## Where it goes

```
iPhone  ──TLS, pinned certificate──▶  Django + Postgres        (your server, on your tailnet)
                                              │
                                              └──WireGuard──▶  LM Studio  (your laptop)
```

- **On the phone:** a local SQLite queue and NDJSON batch files in the app's
  container, excluded from iCloud backup. The server credential lives in the
  Keychain, not in `UserDefaults`.
- **In transit to the server:** HTTPS only, with the server's certificate pinned
  by SHA-256. The app refuses a non-`https://` destination outright.
- **On the server:** Postgres in a Docker volume, reachable only over the
  tailnet. The database port is bound to loopback, so the only route in is an
  SSH tunnel.
- **To the model:** plain HTTP over the tailnet, which Tailscale encrypts with
  WireGuard. Both ends are machines you control. LM Studio cannot terminate TLS,
  and adding a proxy that could would not improve on WireGuard here.

**No third party receives health data** in the default configuration. Pointing
`LLM_BASE_URL` at a hosted provider would change that; the dashboard and the app
both display where processing happens, and say "an external service at
&lt;host&gt;" rather than implying otherwise. See `/v1/insights/status`.

---

## What the model is given

Not your records. The model receives a **prepared summary**: per-metric averages
over the last 7 days and the preceding 28, with units, valid-day counts and
confidence — plus whatever it fetches through eight read-only tools that return
the same kind of computed figures.

It has no database credentials, no SQL, and no access to individual samples.

Your questions are sent as you type them. If you describe a symptom, that text
reaches the model — except when the safety rules classify it as urgent, in which
case the model is **not called at all** and a reviewed response is returned.

Inside a chat, the earlier turns of **that conversation** go with it, so a
follow-up makes sense: your questions, and the summary line of each answer, up to
`INSIGHT_HISTORY_TURNS` (6). Never the observations or the evidence, and never
anything from a different conversation. If the chat is in a project, the standing
context you wrote for that project is sent too — it is part of the prompt, so
treat it as something the model reads every time.

---

## How long things are kept

| Data | Retention |
|---|---|
| Health records | Indefinitely, until you delete them |
| Uploaded batch files (phone) | Pruned after delivery; archive trimmed automatically |
| Questions and generated answers | `INSIGHT_RETENTION_DAYS`, 30 by default, then deleted |
| Chats and their titles | As above — a chat is deleted once retention has emptied it |
| Project names and standing context | Until you delete the project. It is text you wrote, not health data |
| The snapshot an answer was built from | **Never stored** — recomputed on demand |
| Database backups | 30 days, encrypted with AES-256 |
| Application logs | Record counts, metric names and error reasons. No measurements. |

Answers do not store the health figures they were built from. Those are
derivable from records already in the database, so a second copy would only
widen what a deletion has to reach.

---

## Deleting it

```bash
./deploy.sh purge              # every record, batch, goal and stored question
```

It prints what it will destroy and what it will **not** — which is the part
people miss:

1. **Backups.** `/var/backups/health/` and anything pulled to your laptop by
   `./deploy.sh backup-pull`. A restore brings all of it back.
2. **The phone.** Apple Health still has the data, and the app will re-upload it
   on the next sync unless you reset the sync cursors in
   *Settings → Diagnostics*.
3. **Apple Health itself.** Deleting here never touches it. Use the Health app.

To delete only stored questions, without touching health records: the
**Insights** tab's "Delete stored questions", or `DELETE /v1/insights/history`.
That clears the chat list too, since a chat is its messages.

To delete a single conversation and everything said in it: the ⋯ menu beside it
in the sidebar, or `DELETE /v1/chat/sessions/<uuid>`. Deleting a *project*
deliberately does not delete its chats — they are unfiled and stay reachable, so
one mis-click cannot take months of conversations with it.

To take your data with you: **Export** tab, or `/v1/export/records.csv`.

---

## Model training

No health data is used to train anything. The local model is a fixed set of
weights on your laptop; it does not learn from what you ask it, and nothing is
sent anywhere for training. If you point the system at a hosted provider, that
provider's terms apply instead — check them.

---

## Advertising and sharing

None. Nothing is sold, shared, or used for advertising. There is no analytics
SDK, no crash reporter, and no telemetry in the app or the server.

---

## Known limitations

Stated because they are real, not because they are comfortable.

- **Health records are not scoped to a user.** Any valid session or bearer token
  can read every record in the database. That is correct for one person's
  server and wrong the moment two people share one. The server emits a startup
  warning if a second active account appears.
- **The backup passphrase lives on the machine it protects.** Encryption defends
  the dumps if they are copied off, lost, or pulled to a laptop. It does not
  defend against someone who already has root on the server, who can read
  `.env`. Store the passphrase somewhere else too — otherwise losing the server
  means losing the backups as well.
- **Postgres is not encrypted at rest** beyond whatever full-disk encryption the
  host provides. The Docker volume is plaintext on that disk.
- **No consent versioning.** Deliberate: there is no third party to consent to,
  one person operates the whole system, and a consent ledger with a single
  signatory records nothing that `git log` does not. This would need to change
  before anyone else's data touched it.
- **Alert webhooks leave the tailnet if you configure one.** Metric names and
  dates only — "Sleep duration: last recorded 2026-06-27" — but that is still
  health-adjacent metadata. A self-hosted receiver avoids it.
