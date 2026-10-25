# firefly-iii — self-hosted double-entry personal finance

A real double-entry ledger for the six accounts listed in
[COMPETITIVE-ANALYSIS.md](COMPETITIVE-ANALYSIS.md): asset/expense/revenue
accounts, budgets, categories, multi-currency with a live FX source, and a REST
API that the future pullers will post to. Web UI:
`https://homeserver.tail-name.ts.net:8097`.

**What is built here is Phase 1 of [PLAN.md](PLAN.md) and nothing else** — the
deploy. Phases 2–6 (the Wise / Tiger / DBS pullers, statement parsing, the
Notion cutover) are future work and are gated on the Phase 0 verification
questions, which need Kai and are still unanswered. See
[Scope: only Phase 1](#scope-only-phase-1) below before assuming anything
imports itself.

## ⚠️ This is a financial system of record on a box with no backups

Say it plainly, because everything else in this document is downstream of it.
Once transactions live in Firefly III and Notion stops being updated, this
Postgres volume *is* Kai's financial history. Nothing on `homeserver`
backs it up — there is no snapshot schedule, no offsite copy, no Seafile sync
of `~/services/firefly-iii`, and a disk failure or a careless
`docker compose down -v` loses the lot with no recovery path. That is not a
theoretical risk on a single consumer SSD with 1.9 GB of swap already in use.

Two consequences worth acting on:

- **Do not decommission Notion** until backups exist. PLAN.md Phase 6 already
  says to archive rather than delete; this is the reason.
- **Take a dump before anything destructive**, and before every upgrade:

  ```bash
  cd ~/dev/setup-server/services/firefly-iii
  docker compose --project-directory . exec -T db \
    pg_dump -U firefly firefly | gzip > ~/firefly-$(date +%F).sql.gz
  ```

  Copying `~/services/firefly-iii/db` while Postgres is running is **not** a
  valid backup. Use `pg_dump`.

Wiring `~/services/firefly-iii` into a real backup is the open item that most
deserves doing next, and it is out of scope for this directory.

## Architecture

Three containers on a Compose bridge network:

| Compose service | Container | Image |
|---|---|---|
| `app` | `firefly-iii` | `fireflyiii/core:version-6.4.2` |
| `db` | `firefly-iii-db` | `postgres:16-alpine` |
| `importer` | `firefly-iii-importer` | `fireflyiii/data-importer:version-1.9.0` |

- **`app`** — the web UI, the REST API, and the cron entrypoint. Published on
  `127.0.0.1:8097` only; Tailscale Serve terminates TLS in front of it on
  `:8097`. Inside the container it listens on `8080`.
- **`db`** — the ledger. **No published port at all**; reachable only from the
  other two containers on the Compose project's private network. Use
  `docker compose exec db psql` when you need it.
- **`importer`** — the CSV / CAMT.053 import UI. Published on `127.0.0.1:8099`,
  served on `:8099`. It reaches Firefly over the Compose network as
  `http://app:8080`, not over the tailnet. **Deployed but idle** — see below.

All three tags are pinned. No `:latest` on a system of record: a surprise major
version that runs a one-way database migration is not something to discover
during a `docker compose pull`.

State lives under `~/services/firefly-iii`:

```
~/services/firefly-iii/
  db/          # Postgres data directory — THE LEDGER. Back this up.
  upload/      # attachments (receipts, statement PDFs) uploaded through the UI
  importer/    # saved Data Importer configurations (JSON), once any exist
```

Secrets are generated into the gitignored `.env` (mode 600) beside `setup.sh`:
`APP_KEY`, `DB_PASSWORD`, and the admin account's email + password. Nothing
here goes in git — `.gitignore` already covers `.env`, and per
[AGENTS.md](AGENTS.md) anything a human needs to retrieve later belongs in
vaultwarden (`:8222`).

## Security model

- **Tailnet-only.** The app and the importer bind `127.0.0.1`; Postgres
  publishes no port at all. Nothing is reachable from the LAN or the internet.
  Tailscale Serve is the only ingress and it proxies from `127.0.0.1`.
- **Firefly has its own login** and it is not optional: the app is stateful,
  the API is token-authenticated, and the first-run `/register` page will hand
  the admin account to *whoever loads it first*. `setup.sh` therefore registers
  the admin during the deploy rather than leaving that window open on the
  tailnet — the same reasoning as immich's `admin-sign-up`.
- **`TRUSTED_PROXIES: '**'` is deliberate and safe here**, and only because of
  the bind. Serve connects from `127.0.0.1`, and nothing else can reach the
  port, so the only proxy Firefly can ever be behind is Serve. On a
  LAN-exposed box this setting would let anyone spoof `X-Forwarded-For`; on a
  loopback-only bind there is no one to spoof it.
- **No password auth in front of Firefly's own.** The tailnet is the outer
  boundary, the login is the inner one, per the repo's rules.

⚠️ **Password-sync rule**, same as every other service here: if you change the
admin password in the web UI, mirror it into `.env`. Nothing automatically
re-reads it, and a stale `.env` is how you end up locked out of a service whose
password you thought you had written down.

## The two settings that decide whether the UI actually works

Measured end to end through a real Serve mount, and worth understanding before
touching the compose file, because getting either wrong produces a **200 that
looks fine to `curl` and a blank, unstyled page in the browser**:

```yaml
APP_URL: https://homeserver.tail-name.ts.net:8097   # the EXTERNAL url
TRUSTED_PROXIES: '**'
```

Firefly (Laravel) builds every asset URL from `APP_URL` and from what the proxy
headers tell it about the scheme. Set `APP_URL` to the loopback URL — the
natural thing to write, since that is what the container binds — or leave
`TRUSTED_PROXIES` unset, and the login page comes back **200 with every
stylesheet and script referenced as `http://`**. The browser blocks them as
mixed content on an HTTPS page and renders unstyled HTML with no working
JavaScript. `curl` cannot see this: it fetches the HTML, gets 200, and reports
success.

So: `APP_URL` is the *external* tailnet HTTPS URL, not the port the container
listens on. `'**'` must be quoted in YAML or it parses as an alias. And the
live test counts `src="http://` and `href="http://` in the login page and
requires **zero** — a 200-only check is precisely the check that fails here.
TROUBLESHOOT.md has the one-liner.

## The Data Importer is deployed but idle

This is intentional, and it is the one thing most likely to read as an
unfinished deploy.

`firefly-importer` comes up, serves its UI on `:8099`, and can do **nothing**
until it holds a Firefly III **personal access token**. Minting one requires a
logged-in browser session:

> `https://homeserver.tail-name.ts.net:8097` → **Options → Profile →
> OAuth → Personal Access Tokens → Create New Token**

Copy the token (it is shown once), then either paste it into the importer's
first-run form at `https://homeserver.tail-name.ts.net:8099`, or put it
in `.env` as `FIREFLY_III_ACCESS_TOKEN` and re-run `./setup.sh`.

**Automating this was deliberately not attempted.** Creating a token means
driving Firefly's authenticated web session — logging in as the admin, holding
the session cookie, scraping another CSRF token, posting the create-token form
and scraping the one-time secret out of a modal. That is a brittle screen-scrape
of an authenticated flow whose only purpose is to save Kai ninety seconds of
clicking, on a system of record, and it would silently break on any upstream UI
change. Registration is scripted because leaving `/register` open on the tailnet
is a real exposure with a real window; the token has no such urgency. Kai does
it once, by hand.

Until then the importer is a running container with a working web UI and no
credentials. That is the expected state on a fresh deploy, and the live test
asserts the container is *running*, not that it is *configured*.

## Scope: only Phase 1

[PLAN.md](PLAN.md) describes six phases. Everything in this directory
implements **Phase 1** — deploy Firefly III + Postgres + Data Importer,
tailnet-only, with the repo's usual docs and tests.

Not built, and deliberately not scaffolded:

| Phase | What it is | Why it is not here |
|---|---|---|
| 2 | Wise puller | Gated on PLAN.md **0.1** — can Kai's *personal* Wise profile mint an API token that reads balance statements? Vendor docs contradict themselves. Unanswered. |
| 3 | Tiger Brokers puller | Needs Kai to register at the developer portal and save a private key that is displayed exactly once. |
| 4 | DBS transaction-alert email parsing | Gated on **0.3** — do the alert emails exist, and in what formats? |
| 5 | Manual statement importers | Depends on the Data Importer being configured, i.e. on the token above. |
| 6 | Notion cutover | Depends on everything above, and on backups existing. |

Phase 0 is a **verification gate** whose questions need Kai, not an agent. Do
not start Phase 2+ by guessing the answers, and do not reverse-engineer a bank
app — that is the finding, not an obstacle (see AGENTS.md → Boundaries).

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker's restart policy handles boot; no systemd unit needed | ✅ |
| Docker + Compose v2 | all three containers | ✅ (incl. daemon reachability) |
| curl | readiness probe + the registration POST | ✅ |
| Tailscale, logged in | publishing | ✅ (`BackendState` must be `Running`) |
| ports 8097 + 8099 free | the publish | ✅ |
| ~600 MB RAM headroom | see below | ⚠️ warns |
| ≥ 2 GB free disk | Postgres + attachments | ⚠️ warns |

Not needed: python3 (no JSON API calls during the deploy), and no artisan
command — see *Why registration goes through the web form* below.

## Memory

The box is 7.7 GB total and was at **3.5 GB available with 1.9 GB of swap
already in use** when this was measured. ollama claims ~5 GB the moment a model
loads, so the headroom is real but not generous.

Every container carries a `mem_limit`. Measured idle RSS on this box, from
`docker stats --no-stream` shortly after a deploy:

| Container | `mem_limit` | `.env` override |
|---|---|---|
| `firefly-iii` | 768m | `FIREFLY_MEM_LIMIT` |
| `firefly-iii-db` | 512m | `FIREFLY_DB_MEM_LIMIT` |
| `firefly-iii-importer` | 512m | `FIREFLY_IMPORTER_MEM_LIMIT` |

The limits are caps, not reservations — measured idle for the whole stack is
roughly **175–200 MB** (app ~66 MB, db ~29 MB, importer ~80 MB), well under the
~1.75 GB the caps would allow, and the caps exist so a runaway import or a
stuck php-fpm cannot take the rest of the box down with it. Record the real
number for your deploy:

```bash
docker stats --no-stream firefly-iii firefly-iii-db firefly-iii-importer
```

If a container sits *exactly* at its limit, it is being throttled rather than
merely busy — raise the value in `.env` and re-run `./setup.sh`.

Per Kai's instruction, **this service does not have to stay running.** Once the
deploy is confirmed and the tests pass it is fine to
`docker compose --project-directory . stop` and start it again when needed;
Postgres survives in `~/services/firefly-iii/db`. That is also the correct
thing to do before running something memory-hungry.

## Deploy

```bash
cd ~/dev/setup-server/services/firefly-iii && ./setup.sh    # idempotent; re-run to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, curl, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports, and that 8097/8099 are free. Then the
   RAM and free-disk advisories.
2. **`.env`** — written only if absent, mode 600. Generates `APP_KEY`
   (**exactly 32 characters** — Firefly accepts a plain 32-char string, no
   `base64:` prefix; a wrong length is a common and confusing boot failure),
   `DB_PASSWORD`, and the admin email + a **≥ 16 character** password (see
   below). An existing `.env` is never rewritten — that is where your admin
   password lives.
3. **State dirs** — `~/services/firefly-iii/{db,upload,importer}`.
4. **Compose up** — pulls on first run. First boot runs the database
   migrations; the app answers HTTP in roughly **25 seconds** with a cold
   Postgres.
5. **Wait for readiness** — poll `GET /login` on the loopback port until it
   answers. A cold container is not listening at all: `curl` exits 7 and
   reports HTTP `000`. That is a refused connection, not a 503, and the loop
   is written to survive it rather than to treat the first failure as fatal.
6. **Register the admin** — `GET /register`, scrape the CSRF `_token`, `POST
   /register` with the same cookie jar, then **verify the user exists** rather
   than trusting the redirect. Details below; this step has two sharp edges.
7. **`tailscale serve --bg --https=8097` and `--https=8099`**, with the
   operator-grant and approval-link fallbacks the other services use.
8. **Verify** end to end over HTTPS — including the asset-scheme check — then
   print the URL, the credentials, and the Data Importer token instructions.

### Why registration goes through the web form

Because there is no usable CLI path, and that took measuring to establish.

The `firefly-iii:*` artisan namespace contains `create-database`,
`correct-database`, `upgrade-database`, `cron`, `export-data`,
`report-integrity` and a dozen more — nothing that creates a user. There *is*
one command in a different namespace, `system:create-first-user <email>`, and
it is a dead end for two independent reasons, both measured against this exact
image:

```
$ php artisan system:create-first-user kai@example.com
  [x]  This command only works in the testing environment.
```

It hard-refuses unless `APP_ENV=testing`, and running a financial system of
record in Laravel's testing environment to bootstrap an account is not a
trade anyone should make. Even with `APP_ENV=testing` forced it **generates its
own password and prints it** — you cannot supply one — so the deploy would have
to scrape a secret out of command output and write it back to `.env`, which is
strictly worse than choosing the password up front. Upstream's own description
says "Strictly for testing."

So the account is made the way a browser would make it:

```
GET  /register     -> scrape name="_token" value="..."   (40 chars)
POST /register     -> _token, email, password, password_confirmation
                      (same cookie jar for both: curl -c on the GET, -b -c on the POST)
                   -> 302 on success
```

`/` redirects to `/register` while no user exists and to `/login` once one
does, which is a clean unauthenticated way to tell the two states apart. After
registering, `/` lands on `/new-user`.

**Two things go wrong here, and both look like success:**

- **CSRF.** A missing or mismatched cookie jar gives **HTTP 419 "Page
  Expired"**, not a validation error. Only the `XSRF-TOKEN` cookie appears in
  the jar; that is normal and sufficient.
- **The 16-character password minimum.** A 15-character password is rejected
  with a **302 back to `/register`** and the error flashed into the session —
  so a script that checks only the status code sees a redirect, calls it
  success, and leaves **no user created**. The error is only visible on the
  next `GET`:
  `<li>The password must be at least 16 characters.</li>`

  `setup.sh` generates well over 16 and then verifies the user exists (`/` no
  longer redirects to `/register`) instead of trusting the 302. The test suite
  asserts both halves.

**Re-running is safe.** On a second run the account already exists, which is
**success, not an error** — a deploy that treats "already registered" as a
failure cannot be run twice, and idempotency is non-negotiable here.

## First login

```
URL:      https://homeserver.tail-name.ts.net:8097
Email:    see FIREFLY_ADMIN_EMAIL in .env
Password: see FIREFLY_ADMIN_PASSWORD in .env
```

The device must be on the tailnet. Firefly drops you on `/new-user`, which asks
for a bank name and an opening balance — fill it in or skip it; it only creates
a first asset account.

Then, in order:

1. **Currencies — do not skip.** Administration → Currencies. Enable **SGD and
   make it the default**, plus **USD**, **EUR**, and every currency held in a
   YouTrip / Wise / Revolut wallet. Then configure a real exchange-rate source.
   A silent 1:1 FX fallback is the specific flaw that disqualified Securo in
   COMPETITIVE-ANALYSIS.md; do not reproduce it here by leaving rates unset.
2. **Personal access token** for the Data Importer — the click-path is in *The
   Data Importer is deployed but idle* above.
3. **Accounts** — create the asset accounts for DBS, PayLah!, YouTrip, Revolut,
   Wise and Tiger. The pullers will target these by name later, so name them
   deliberately.

## Ops

```bash
cd ~/dev/setup-server/services/firefly-iii

docker compose --project-directory . ps                    # status
docker compose --project-directory . logs -f app   # app logs
docker compose --project-directory . stop                  # free the RAM
docker compose --project-directory . up -d                 # bring it back
docker stats --no-stream firefly-iii firefly-iii-db firefly-iii-importer

tailscale serve status | grep -E ':(8097|8099)'            # publish config
./tests/run-tests.sh --live                                # everything at once
```

**Remove**: `./teardown.sh` (or Remove in the launcher) unpublishes both Serve
ports (the app and the Data Importer) and runs `compose down`; the ledger,
uploads and `.env` stay, so `./setup.sh` brings it back. `./teardown.sh --purge`
also deletes the ledger, uploads, importer config and `.env` after you type
`firefly-iii`. It destroys the ledger and the `APP_KEY`: dump first.

**Upgrade** — read the release notes first; Firefly's migrations are one-way:

```bash
# 1. dump the ledger (see the backups warning at the top)
docker compose --project-directory . exec -T db \
  pg_dump -U firefly firefly | gzip > ~/firefly-$(date +%F).sql.gz
# 2. bump FIREFLY_VERSION / IMPORTER_VERSION in .env deliberately, then:
docker compose --project-directory . pull && ./setup.sh
```

`setup.sh` re-applies the serve config and re-verifies; it will not re-register
the admin or touch an existing `.env`.

**Monitoring.** Kuma should watch `http://127.0.0.1:8097/login`, **not** `/`.
`/` is a 302 and Kuma scores a redirect as down. `/login` returns 200 and is
the stable choice.

## Ports

| Component | Local | Tailnet HTTPS |
|---|---|---|
| Firefly III web | `127.0.0.1:8097` | `:8097` |
| Data Importer | `127.0.0.1:8099` | `:8099` |
| Postgres | not published | — |

⚠️ **Not 8098.** It is held by an ad-hoc `python3 echosrv.py` (pid 1781019, up
over a day, not a managed service, absent from `DIRECTORY.md`). It is not ours,
Kai has not been asked about it, and nothing here may reclaim it. ⚠️ **Not
8080** either — that is code-server, and it happens to be Firefly's upstream
default port, which makes it an easy trap.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere, changes nothing
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` against a sandboxed `$HOME` with PATH
stubs, and proves it touched nothing by checksumming the service directory and
`~/services/firefly-iii` before and after. The `curl` stub fakes Firefly's
registration surface — the CSRF token round-trip, the **419** a bad cookie jar
produces, the **302-back-to-`/register`** a short password produces with no user
created, the already-registered path, and a cold start as a real refused
connection (exit 7, HTTP `000`) — so the registration logic is genuinely
exercised rather than rubber-stamped.

`--live` additionally asserts what `curl`'s status code cannot: that the login
page fetched over tailnet HTTPS contains **zero** `http://` asset references.

If `docker` says "permission denied", you are not in the docker group *in this
shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite detects
this and says so rather than reporting a healthy stack as down.

## Notes

- `SITE_OWNER` is only the contact address printed in Firefly's error mails.
  Harmless; set to the admin email.
- The DB user, password and database name are consumed identically by Postgres
  and by Firefly. A mismatch does **not** produce a clean error — it shows up
  as the first-boot migrations hanging. TROUBLESHOOT.md covers the symptom.
- HTTPS port equals the local port for both services, following the
  jellyfin/beszel convention rather than immich's split.
- Postgres is `postgres:16-alpine` — stock. Unlike immich, Firefly needs no
  database extensions, so there is no reason to run a custom build.
