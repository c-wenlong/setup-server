# firefly-iii — Troubleshooting

⚠️ **This holds financial records and nothing on this box backs it up.** Before
you run anything on this page that stops, removes or recreates a container,
dump the ledger:

```bash
cd ~/dev/setup-server/services/firefly-iii
docker compose --project-directory . exec -T db \
  pg_dump -U firefly firefly | gzip > ~/firefly-$(date +%F).sql.gz
```

That takes seconds and it is the only copy that exists. Copying
`~/services/firefly-iii/db` while Postgres is running is not a backup.

Triage in layers, outermost failure first:

```
containers up?  ->  app answers locally?      ->  registered?     ->  publish?        ->  browser OK?
docker ps           curl 127.0.0.1:8097/          / -> /login        serve status       asset scheme
```

Quick triage:

```bash
cd ~/dev/setup-server/services/firefly-iii
docker compose --project-directory . ps                            # all three up?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8097/    # 302 = healthy
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8097/login   # 200 = healthy
curl -sI http://127.0.0.1:8097/ | sed -n 's/^[Ll]ocation: //p'     # /login or /register?
tailscale serve status | grep -E ':(8097|8099)'
./tests/run-tests.sh --live                                        # everything at once
```

If `docker` says "permission denied", you are not in the docker group in *this
shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite detects
this and says so, rather than reporting a healthy stack as down.

**Reading the status codes.** The two unauthenticated endpoints tell you almost
everything, and `/`'s *redirect target* is the single most useful signal here:

| Request | Code | Means |
|---|---|---|
| `/` | `000` | not accepting connections — cold start, or the container is not running |
| `/` | `302 → /register` | up, and **no user exists yet** — the deploy's registration step did not land |
| `/` | `302 → /login` | up, registered — **this is the healthy answer** |
| `/` | `302 → /new-user` | up, registered, logged in (you sent a session cookie) |
| `/` | `200` | you are not talking to Firefly. It never 200s on `/`. |
| `/login` | `200` | up and healthy — use this for Kuma, not `/` |
| `/login` | `500` | app is running but broken — almost always `APP_KEY`, see below |

⚠️ **Never health-check this service with `curl -fsS http://127.0.0.1:8097/`.**
`/` is a 302, `-f` treats nothing here as an error but the body is empty, and
you will conclude the service is dead when it is perfectly fine. Same reason
Kuma must point at `/login`.

---

## The login page loads but has no styling and nothing works

**The signature failure of this service**, and the one that will waste the most
time, because every automated check says it is healthy.

The symptom is a browser thing: the page renders as unstyled HTML — raw
headings, no layout, buttons that do nothing — and the browser console is full
of

```
Mixed Content: The page at 'https://kai-home-server.taild6a23f.ts.net:8097/login'
was loaded over HTTPS, but requested an insecure stylesheet
'http://kai-home-server.taild6a23f.ts.net:8097/build/assets/app-*.css'.
This request has been blocked.
```

Meanwhile `curl` reports **200** and `docker ps` reports healthy, because the
HTML *is* being served correctly. Only its contents are wrong.

**Diagnose by counting the asset scheme, not by reading the status code:**

```bash
URL="https://kai-home-server.taild6a23f.ts.net:8097/login"
curl -s "$URL" | grep -o -E '(src|href)="http://' | wc -l
#   0  = healthy
#  >0  = this is your bug
```

Zero is the only acceptable answer. The live suite runs exactly this check for
the same reason.

**Cause:** Firefly (Laravel) builds every asset URL from `APP_URL` and from
what the proxy headers tell it about the request scheme. Two settings decide it,
and either one alone is enough to break the page:

```bash
grep -E 'APP_URL|TRUSTED_PROXIES' docker-compose.yml .env
```

- `APP_URL` must be the **external tailnet HTTPS URL**
  (`https://kai-home-server.taild6a23f.ts.net:8097`) — *not*
  `http://127.0.0.1:8097`. The loopback URL is the natural thing to write,
  because it is what the container actually binds, and it is wrong.
- `TRUSTED_PROXIES: '**'` must be set, and **quoted** — bare `**` is not valid
  YAML in that position. Without it Firefly does not believe the
  `X-Forwarded-Proto: https` header Serve sends, so it decides the request
  arrived over plain HTTP and generates `http://` links.

This was reproduced end to end through a real Serve mount: with a loopback
`APP_URL` and no `TRUSTED_PROXIES` the count above was in the dozens; with both
set correctly it is zero.

**Fix:**

```bash
cd ~/dev/setup-server/services/firefly-iii
# correct APP_URL / TRUSTED_PROXIES in docker-compose.yml (or .env), then:
docker compose --project-directory . up -d --force-recreate app
curl -s https://kai-home-server.taild6a23f.ts.net:8097/login \
  | grep -c -E '(src|href)="http://'      # must print 0
```

Recreating the container is required — these are environment variables, so a
`restart` alone does not re-read a changed compose file.

**Why trusting the proxy is safe here:** Serve connects from `127.0.0.1`, the
container publishes on `127.0.0.1` only, and nothing on the LAN can reach the
port. There is no third party in a position to spoof the header. On a
`0.0.0.0` bind this setting would be a genuine hole — which is another reason
not to change the bind.

## HTTP 419 "Page Expired"

You will see this from a script, not from a browser. It is Laravel's CSRF
rejection and it is **not** a validation error, so it does not tell you what
was actually wrong with your request.

```
419
<h1>Page Expired</h1>
```

**Cause:** the `_token` you posted does not match the session the cookie
identifies. In practice, one of:

- **No cookie jar at all.** `curl` was called without `-b`/`-c`, so the POST
  arrived with no session cookie and the token belongs to nobody.
- **Two different jars.** The `GET /register` wrote its cookies to one file and
  the `POST` read from another — or from none.
- **A stale token.** The `_token` was scraped from an earlier fetch, in a
  session that has since been replaced.

**Do it like this** — one jar, written by the GET, read *and rewritten* by the
POST:

```bash
JAR="$(mktemp)"
TOKEN="$(curl -s -c "$JAR" http://127.0.0.1:8097/register \
  | sed -n 's/.*name="_token"[^>]*value="\([^"]*\)".*/\1/p' | head -1)"
echo "${#TOKEN}"     # 40. Empty means the scrape failed — see below.

curl -s -b "$JAR" -c "$JAR" -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8097/register \
  -d "_token=$TOKEN" \
  -d "email=you@example.com" \
  -d "password=SOME-LONG-PASSWORD-16PLUS" \
  -d "password_confirmation=SOME-LONG-PASSWORD-16PLUS"
rm -f "$JAR"
```

Note `-c` on **both** calls: the POST rotates the session and the jar has to
keep up if you intend to make another request.

**Only `XSRF-TOKEN` appears in the jar.** That is normal and sufficient — do
not go hunting for a missing `laravel_session` entry; its absence is not the
problem.

**If `$TOKEN` is empty**, you did not get the register page. Check what you
actually fetched — if `/register` redirected, a user already exists and there
is nothing to register:

```bash
curl -sI http://127.0.0.1:8097/register | head -3
```

## The deploy said it registered the admin, but you cannot log in

Or: `/` still redirects to `/register` after a "successful" run.

**Cause, nearly always: the password was shorter than 16 characters.** Firefly
enforces a **16-character minimum**, and it rejects a short one with a **302
back to `/register`** with the error flashed into the session. A script that
checks only the HTTP status sees a 302 — the same code a successful
registration returns — and reports success. **No user was created.**

Confirm the state in one command:

```bash
curl -sI http://127.0.0.1:8097/ | sed -n 's/^[Ll]ocation: //p'
#   .../login     -> a user exists; your password is simply wrong
#   .../register  -> NO USER EXISTS. The registration never happened.
```

To see the actual error, fetch `/register` again with the same jar you posted
with — the message lives in the session and only renders on the next GET:

```bash
curl -s -b "$JAR" http://127.0.0.1:8097/register | grep -o '<li>[^<]*</li>'
# <li>The password must be at least 16 characters.</li>
```

**Fix:** put a long password in `.env` and re-run.

```bash
cd ~/dev/setup-server/services/firefly-iii
grep FIREFLY_ADMIN_PASSWORD .env | sed 's/=.*/=<redacted>/'
awk -F= '/^FIREFLY_ADMIN_PASSWORD=/{gsub(/"/,"",$2); print length($2)}' .env   # must be >= 16
```

If it is short, edit `.env` to a longer one (24+ costs nothing) and
`./setup.sh`. If it is already long and the user still does not exist, the
registration POST failed for another reason — check for a 419 above, and read
the app log:

```bash
docker compose --project-directory . logs --tail=50 app
```

**If a user exists but the password is wrong** — for instance it was changed in
the web UI and `.env` was never updated — there is no reset link on a
tailnet-only instance without mail configured. Reset it from the container:

```bash
docker compose --project-directory . exec -T db \
  psql -U firefly -d firefly -c 'select id, email from users;'
```

Firefly ships **no artisan password-reset**. The full command list was read out
of the image; the only user-creating command is `system:create-first-user`,
which refuses outright with `This command only works in the testing
environment.` unless `APP_ENV=testing`, and generates its own password anyway.
Do not set `APP_ENV=testing` on this instance to get around that.

`MAIL_MAILER: log` also means **Forgot password** does not send anything — the
mail is written into the container's log instead. That is actually a usable
route on a single-user box:

```bash
# click "Forgot password" in the UI, then read the mail out of the log:
docker compose --project-directory . logs --tail=200 app | grep -i -A20 'reset'
```

Otherwise, delete the single user row and let `./setup.sh` re-register:

```bash
# ⚠️ Destroys that user's data associations. Dump first (top of this page).
docker compose --project-directory . exec -T db \
  psql -U firefly -d firefly -c "delete from users where email='<the email>';"
./setup.sh
```

On a fresh, empty ledger that is cheap. On a populated one it is not — take the
dump.

## "Already registered" on a re-run is success, not an error

A second `./setup.sh` finds the user already there, skips registration and
exits zero. That is correct: idempotency is non-negotiable in this repo, and a
deploy that dies on "user exists" cannot repair or upgrade anything.

If a run *fails* with something like "registration failed" on a box where the
UI plainly works, that is a bug in the detection, not a reason to delete the
user. Check which state you are actually in first:

```bash
curl -sI http://127.0.0.1:8097/ | sed -n 's/^[Ll]ocation: //p'   # /login = registered
```

## The container starts, then nothing — migrations hang

`docker ps` shows `firefly-iii` up. `curl http://127.0.0.1:8097/` returns
`000` forever. The logs stop after the boot banner and never reach "Database is
ready".

```bash
docker compose --project-directory . logs --tail=50 app
docker compose --project-directory . logs --tail=50 db
```

**Give it 30 seconds first.** A cold start with an empty database runs the full
migration set and takes roughly **25 seconds** on this box before the first
HTTP answer. `curl` exiting 7 with HTTP `000` during that window is normal, not
a fault — that is a refused connection, because nothing is listening yet.

**If it is still silent after a minute, suspect a database credential
mismatch.** This is the ugly one: the DB user, password and database name are
consumed by *both* containers, and when they disagree Firefly does not fail
cleanly — it retries the connection and the migration step simply never
completes. There is no obvious "authentication failed" line at the top of the
log.

Check that both sides agree:

```bash
grep -E '^(DB_|POSTGRES_)' .env
docker compose --project-directory . exec db env | grep POSTGRES_
docker compose --project-directory . exec app env | grep -E '^DB_'
```

`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` must equal
`DB_USERNAME`/`DB_PASSWORD`/`DB_DATABASE`. Then confirm the app can actually
authenticate:

```bash
docker compose --project-directory . exec -T db \
  psql -U firefly -d firefly -c 'select 1;'
```

`FATAL: password authentication failed for user "firefly"` is the answer you
are looking for and the one the app log will not give you.

**The trap in fixing it:** Postgres only reads `POSTGRES_PASSWORD` when it
*initialises an empty data directory*. Changing it in `.env` and restarting
does nothing — the old password is already baked into
`~/services/firefly-iii/db`. Either change the password in the database:

```bash
docker compose --project-directory . exec -T db \
  psql -U firefly -d postgres -c "alter user firefly with password '<the .env one>';"
docker compose --project-directory . restart app
```

…or, **only if the ledger is empty**, delete the data directory and let it
re-initialise (see *Nuke and pave*).

## `/login` returns 500

The app is running and its database is fine; something is wrong with the
application config. In order of likelihood:

```bash
docker compose --project-directory . logs --tail=80 app | grep -i -E 'error|exception'
awk -F= '/^APP_KEY=/{gsub(/"/,"",$2); print length($2)}' .env    # must print exactly 32
```

**`APP_KEY` of the wrong length** is the common one and produces an
unhelpful cipher error. Firefly accepts a **plain 32-character string** — no
`base64:` prefix needed — and anything else fails. Note that `APP_KEY` also
encrypts stored values, so changing it on a populated instance is not free;
on a fresh one it is:

```bash
# fresh instance only
sed -i.bak "s/^APP_KEY=.*/APP_KEY=\"$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)\"/" .env
docker compose --project-directory . up -d --force-recreate app
```

Keep the `.bak` until you have confirmed the instance still opens; if there was
real data, the old key is the only thing that can decrypt it.

## The Data Importer shows a setup screen / cannot reach Firefly

Expected on a fresh deploy. **The importer is deployed but idle by design** —
it has no Firefly personal access token, and creating one requires a logged-in
browser session, which is deliberately not automated (SETUP.md explains why).

```
https://…:8097 → Options → Profile → OAuth → Personal Access Tokens → Create New Token
```

Paste it into the importer at `https://…:8099`, or set
`FIREFLY_III_ACCESS_TOKEN` in `.env` and `./setup.sh`.

If a token **is** configured and the importer still cannot reach Firefly, the
usual cause is that it is pointed at the wrong URL. From inside the importer
container Firefly is reachable by its **compose service name**, not by
`127.0.0.1` — loopback inside that container is the importer itself:

```bash
docker compose --project-directory . exec importer env | grep -i firefly_iii_url
docker compose --project-directory . exec importer \
  curl -s -o /dev/null -w '%{http_code}\n' http://firefly-iii:8080/login   # 200
```

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` shows what holds it.
  Remove just that one:

  ```bash
  tailscale serve --https=8097 off
  tailscale serve --https=8099 off
  ```

  ⚠️ **Never `tailscale serve reset`.** That clears **every** mapping on this
  node — code-server, Seafile, Immich, forgejo, AdGuard, Home Assistant,
  Vaultwarden, ntfy, Uptime Kuma, all of it — and nothing will tell you it
  happened except every other service going dark at once. `off` is undocumented
  in `--help` but is what Tailscale itself prints, and it is the only
  single-port removal.

## Reachable on loopback but not over HTTPS

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8097/login          # 200?
curl -s -o /dev/null -w '%{http_code}\n' https://kai-home-server.taild6a23f.ts.net:8097/login
tailscale serve status | grep -A2 ':8097'      # should proxy to http://127.0.0.1:8097
tailscale status | head -3                     # is this node even up?
```

- **Loopback 200, HTTPS times out** — publish problem. Re-run `./setup.sh`, or
  re-apply by hand:
  `tailscale serve --bg --https=8097 http://127.0.0.1:8097`
- **Works from the server, not from the phone/laptop** — that device is not on
  the tailnet, or an ACL blocks it. `tailscale status` on that device.
- **HTTPS 200 but the page is unstyled** — that is the mixed-content bug at the
  top of this page, not a publish problem.

## Nothing is listening on 8097

```bash
ss -ltn | grep -E ':(8097|8099)'      # expect 127.0.0.1 only (plus tailscaled's own)
docker compose --project-directory . ps
docker compose --project-directory . logs --tail=50 app
```

If the container is restarting, read the log — it is usually `APP_KEY` or the
database. If the port is held by something else, find out what before doing
anything:

```bash
ss -ltnp | grep -E ':(8097|8099)'
```

⚠️ **8098 is not ours.** It is an ad-hoc `python3 echosrv.py` (pid 1781019, up
over a day, not a managed service, absent from `DIRECTORY.md`). Nothing in this
directory uses it and nothing here may reclaim it — ask Kai first. If you find
Firefly configured on 8098, that is the bug.

## Is it eating the box's memory?

```bash
docker stats --no-stream firefly-iii firefly-iii-db firefly-iii-importer
free -m
```

Expect roughly 175–200 MB total at idle. A container sitting exactly at its
`mem_limit` is being throttled, not merely busy — raise the limit in
`docker-compose.yml` and `./setup.sh`.

The box has 7.7 GB with ~1.9 GB of swap already in use, and ollama takes ~5 GB
the moment a model loads. **It is fine to stop this service** — per Kai's
instruction it does not have to stay running, and the ledger survives in
`~/services/firefly-iii/db`:

```bash
docker compose --project-directory . stop     # frees the RAM
docker compose --project-directory . up -d    # brings it back
```

## Nuke and pave

**This destroys the ledger** — every transaction, account, budget, rule and
attachment. On a system of record that is not a debugging step, it is a
decision. Take the dump first, and read *If the ledger has real data in it*
below.

```bash
cd ~/dev/setup-server/services/firefly-iii

# 1. DUMP. Not optional. Nothing else on this box backs it up.
docker compose --project-directory . exec -T db \
  pg_dump -U firefly firefly | gzip > ~/firefly-$(date +%F).sql.gz
ls -lh ~/firefly-$(date +%F).sql.gz      # a few KB on an empty ledger; NOT 0 bytes

# 2. Confirm the paths before deleting them. A `rm -rf` of a path that never
#    existed is a silent no-op that leaves you thinking you started clean.
ls -ld ~/services/firefly-iii ~/services/firefly-iii/db \
       ~/services/firefly-iii/upload ~/services/firefly-iii/importer
grep -E '^(FIREFLY_DB_DIR|FIREFLY_UPLOAD_DIR|FIREFLY_IMPORTER_DIR)=' .env

# 3. Tear down. -v also removes any named volumes the compose file declares.
docker compose --project-directory . down -v

# 4. Delete the state. sudo: Postgres runs as its own uid inside the container,
#    so ~/services/firefly-iii/db is not owned by you even though the parent
#    directory is. A plain rm -rf fails partway and a half-deleted data
#    directory is worse than either extreme.
sudo rm -rf ~/services/firefly-iii

# 5. New secrets: a fresh APP_KEY, DB password and admin password.
rm -f .env

# 6. Un-publish the two ports. NOT `serve reset` — that clears every port on
#    this node, for every service.
tailscale serve --https=8097 off
tailscale serve --https=8099 off

# 7. Redeploy.
./setup.sh
```

Two things that make this recipe safe rather than superstitious:

- **The `.env` paths in step 2 are the authority.** If `setup.sh` was ever run
  with the state directories pointed elsewhere, `~/services/firefly-iii` is not
  where the data is, and the `rm -rf` is a silent no-op that leaves you
  convinced you started clean while the old ledger is still on disk. Check
  before you delete, not after — that is why step 2 prints the `.env` values
  next to the paths.
- **`sudo` on the `rm -rf`.** The directory is yours; the Postgres data
  directory's contents are not, because the container runs as its own uid.

If you would rather not use sudo, delete the contents from inside a container
that is already root:

```bash
docker run --rm -v ~/services/firefly-iii:/x --entrypoint rm alpine -rf /x/db /x/upload /x/importer
```

### Smaller hammers, in order

Try these before the one above — each keeps the ledger:

```bash
cd ~/dev/setup-server/services/firefly-iii

# Config change (APP_URL, TRUSTED_PROXIES, mem_limit, image tag) — recreate the
# container so the new environment is read. A `restart` does NOT re-read it.
docker compose --project-directory . up -d --force-recreate app

# Rebuild every container, keep all data:
docker compose --project-directory . up -d --force-recreate

# Wrong admin password only — delete the user row, keep everything else, and
# let setup.sh re-register. Cheap on a fresh ledger, not on a populated one.
docker compose --project-directory . exec -T db \
  psql -U firefly -d firefly -c "delete from users where email='<the email>';"
./setup.sh
```

### If the ledger has real data in it

Do not nuke it. Restore into a fresh database instead of starting from empty:

```bash
# after step 7 above brings a clean instance up, before registering anything:
gunzip -c ~/firefly-YYYY-MM-DD.sql.gz \
  | docker compose --project-directory . exec -T db psql -U firefly -d firefly
```

⚠️ A restore only works with the **`APP_KEY` that was in use when the dump was
taken** — Firefly encrypts some stored values with it. If you deleted `.env` in
step 5 without recording the old key, encrypted fields in the restored dump are
unrecoverable. Save the old `APP_KEY` alongside the dump, or do not delete
`.env`.
