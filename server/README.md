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
| POST | `/v1/health/batches` | Bearer | Ingest an NDJSON batch |
| GET | `/v1/health/ping` | Bearer | Cheap probe — powers Test Connection |
| GET | `/v1/health/stats` | Bearer | Per-device counts, top metrics |
| GET | `/healthz` | none | Liveness, touches the database |
| — | `/admin/` | session | Browse records, revoke tokens |

`gzip` request bodies are accepted (`Content-Encoding: gzip`) even though the
current client uploads uncompressed.

For an admin login:

```bash
ssh alena-tailscale 'cd health-server && docker compose run --rm web python manage.py createsuperuser'
```

---

## Security

- **Tokens are stored as SHA-256 digests.** The raw value is shown once at
  creation and is unrecoverable — a database dump yields nothing usable.
- **Postgres publishes no port.** It is reachable only from the web container;
  binding 5432 on this host would expose it to the whole tailnet.
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

The suite runs on SQLite so it needs no database server; the ingest path uses
`ON CONFLICT DO UPDATE`, which both engines support. To exercise the real thing:

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
│   ├── models.py          Device, ApiToken, Batch, Record
│   ├── ndjson.py          Streaming line reader
│   ├── service.py         Batch → rows, upsert, tombstones
│   ├── auth.py            Bearer token authentication
│   ├── parsers.py         Hands DRF the raw stream
│   └── views.py           Endpoints and status-code policy
└── tests/test_ingest.py   Contract tests
```
