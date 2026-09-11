# paperless-ngx — Troubleshooting

⚠️ **This service holds documents, and this box has no backups.** Before you
run anything on this page that deletes a volume, removes a container or
"starts clean", read [Nuke and pave](#nuke-and-pave) — and run an export
first. Losing `media/` loses the documents; losing `data/` loses every tag,
title and correspondent you ever corrected by hand.

Triage in layers, outermost failure first:

```
containers up?  ->  local health?             ->  publish?      ->  browser login?
docker ps           curl :8095/accounts/login/    serve status     the 403 below
```

Quick triage:

```bash
cd ~/dev/setup-server/paperless-ngx
docker compose --project-directory . ps                    # both containers up?
curl -s -o /dev/null -w '%{http_code}\n' \
     http://127.0.0.1:8095/accounts/login/                 # 200 = healthy
tailscale serve status | grep -A2 ':8095'                  # -> 127.0.0.1:8095
docker compose --project-directory . logs --tail=50 webserver
./tests/run-tests.sh --live                                # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so, rather than reporting healthy containers as down.

**Reading the status codes** on `http://127.0.0.1:8095/accounts/login/`:

| Code | Means |
|---|---|
| `000` | not accepting connections — cold start / migrations, or the container is down |
| `200` | **healthy.** Django is up and serving the login page |
| `400` | `ALLOWED_HOSTS` rejected the Host header — see below. The app is *fine* |
| `500` | Django started but something inside it is broken; read the log |
| `502` | only over HTTPS: Serve is up, the backend behind it is not |

And do not health-check `/` or `/api/`: measured on the shipped image, both
return **302** to the login page when unauthenticated. Uptime Kuma scores a
302 as **down**, so a monitor pointed at `/` reports a permanent outage over a
perfectly healthy service.

---

## "I can load every page but I cannot log in" — 403 CSRF verification failed

The signature failure of this service. Everything looks right, `curl` says
200, the login page renders, and pressing **Sign in** gives:

> **Forbidden (403)**
> CSRF verification failed. Request aborted.

**This is a configuration error in `PAPERLESS_URL`, not a password problem, not
a cookie problem, and not a browser problem.** Nothing in the page tells you
that, because Django only prints the reason when `DEBUG` is on, which it is
not. The reason is in the container log:

```bash
docker logs --tail 50 paperless-ngx 2>&1 | grep csrf
```

```
[WARNING] [django.security.csrf] Forbidden (Origin checking failed -
  https://kai-home-server.taild6a23f.ts.net:8095 does not match any trusted
  origins.): /accounts/login/
```

### Why it happens

Tailscale Serve terminates TLS and proxies **plain HTTP** to `127.0.0.1:8095`,
preserving the Host header. So Django sees an `http` request for
`kai-home-server.taild6a23f.ts.net:8095` and computes its own idea of the
origin as:

```
http://kai-home-server.taild6a23f.ts.net:8095
```

while your browser sends:

```
Origin: https://kai-home-server.taild6a23f.ts.net:8095
```

Those are different strings, so Django falls through to an **exact string**
membership test against `CSRF_TRUSTED_ORIGINS` (Django 5.2,
`middleware/csrf.py::_origin_verified`). The only thing that puts that
`https://…:8095` string in the list is `PAPERLESS_URL`.

### The fix

```bash
grep PAPERLESS_URL ~/dev/setup-server/paperless-ngx/.env \
                   ~/dev/setup-server/paperless-ngx/docker-compose.yml
tailscale status --json | grep -m1 DNSName
```

It must be the **external** URL, with the scheme and the port, and no trailing
slash:

```
PAPERLESS_URL=https://kai-home-server.taild6a23f.ts.net:8095
```

Every one of these is wrong and every one produces this exact 403:

| Value | Why it fails |
|---|---|
| unset | `CSRF_TRUSTED_ORIGINS` is empty |
| `http://…:8095` | scheme mismatch — the browser sends `https` |
| `https://kai-home-server.taild6a23f.ts.net` | **port missing** — the compared string includes `:8095` |
| `https://127.0.0.1:8095` | that is the internal address, not what the browser sends |
| `https://…:8095/` | trailing slash; the comparison is exact |

Then restart — this is read at startup only:

```bash
cd ~/dev/setup-server/paperless-ngx
docker compose --project-directory . up -d      # picks up the changed env
```

### Confirming it is fixed without a browser

`curl` cannot reproduce the failure by accident, because it sends no `Origin`
header and the rule only fires when one is present. Send one deliberately:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Origin: https://kai-home-server.taild6a23f.ts.net:8095' \
  -d 'login=x&password=y' \
  http://127.0.0.1:8095/accounts/login/
```

You want **403 with the "requires a CSRF cookie" text** in the body — that
means the origin check *passed* and it stopped at the missing token, which is
correct for a request with no cookie jar. A 403 **without** that text is the
origin failure still happening:

```bash
curl -s -X POST -H 'Origin: https://kai-home-server.taild6a23f.ts.net:8095' \
  -d 'login=x&password=y' http://127.0.0.1:8095/accounts/login/ \
  | grep -c 'requires a CSRF cookie'
#   1 = origin accepted (good).   0 = origin rejected (still broken).
```

That distinction — same status code, different body — is the only way to tell
the two apart from the command line, and it is what the live suite asserts.

## "400 Bad Request — Invalid HTTP_HOST header"

The mirror image of the problem above, and it is almost always **self-
inflicted by tightening a setting that was already safe.**

```
Bad Request (400)
Invalid HTTP_HOST header: '127.0.0.1:8095'. You may need to add '127.0.0.1'
to ALLOWED_HOSTS.
```

Out of the box `PAPERLESS_ALLOWED_HOSTS` is unset and `ALLOWED_HOSTS` is
`["*"]`, which 400s nothing. Set it to the tailnet name — the obvious
hardening step — and Paperless appends `localhost` to the narrowed list but
**not `127.0.0.1`** (read it in `src/paperless/settings/__init__.py`):

```python
ALLOWED_HOSTS = get_list_from_env("PAPERLESS_ALLOWED_HOSTS", default=["*"])
if ALLOWED_HOSTS != ["*"]:
    ALLOWED_HOSTS.append("localhost")     # note: NOT 127.0.0.1
```

So the browser keeps working over the tailnet and everything that checks the
service locally breaks at once: the local health check, the Uptime Kuma
monitor, `./tests/run-tests.sh --live`, and the container's own healthcheck
(`curl -fs http://localhost:8000` — that one survives, because `localhost` is
the entry Django adds).

**Diagnose:**

```bash
docker exec paperless-ngx env | grep -E 'PAPERLESS_(URL|ALLOWED_HOSTS)'
curl -s -o /dev/null -w 'loopback %{http_code}\n' http://127.0.0.1:8095/accounts/login/
curl -s -o /dev/null -w 'tailnet  %{http_code}\n' \
     https://kai-home-server.taild6a23f.ts.net:8095/accounts/login/
```

A `400` on the first and `200` on the second is this problem exactly.

**Fix:** remove `PAPERLESS_ALLOWED_HOSTS` and let it go back to `["*"]`, or —
if you really want it narrow — include the loopback address:

```yaml
PAPERLESS_ALLOWED_HOSTS: kai-home-server.taild6a23f.ts.net,127.0.0.1
```

`["*"]` is not the exposure it looks like here. The only things that can reach
the port are loopback and Tailscale Serve, and Serve only accepts tailnet
clients. `ALLOWED_HOSTS` is a defence against Host-header poisoning from the
open internet, and this service has no path to the open internet.

## `000` / connection refused right after starting

Normal for the first minute, and the reason is worth knowing: **on a first
boot Paperless runs database migrations before it starts serving.** Until
those finish, nothing is listening on the port at all — `curl` reports exit 7
and HTTP `000`, not a polite 503.

```bash
docker compose --project-directory . logs -f webserver
```

Watch for the migrations to finish and gunicorn to come up. If it is still
refusing after a couple of minutes, it is not the readiness race:

```bash
docker compose --project-directory . ps           # is the container even up?
docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' paperless-ngx
docker compose --project-directory . logs --tail=100 webserver
```

### The container exits immediately: `ImproperlyConfigured`

```
django.core.exceptions.ImproperlyConfigured: PAPERLESS_SECRET_KEY is not set
or is the default 'change-me' value.
```

Exactly what it says — the image refuses to start without a real secret key,
which is correct behaviour, not a bug. `setup.sh` generates one into `.env`.

```bash
grep PAPERLESS_SECRET_KEY ~/dev/setup-server/paperless-ngx/.env
```

If it is missing or literally `change-me`, generate one and restart:

```bash
cd ~/dev/setup-server/paperless-ngx
python3 -c 'import secrets; print("PAPERLESS_SECRET_KEY=" + secrets.token_hex(32))' >> .env
docker compose --project-directory . up -d
```

⚠️ **Changing an existing secret key** invalidates every active session (people
get logged out) and, more importantly, breaks anything signed with the old key.
Do not rotate it to "try something" — set it once and leave it.

## Documents sit in `consume/` and nothing happens

The file is in `~/services/paperless-ngx/consume/`, it is still there minutes
later, and the UI shows nothing. There is no error in the UI because the UI
never heard about the file.

Work down this list:

```bash
ls -la ~/services/paperless-ngx/consume/
docker exec paperless-ngx ls -la /usr/src/paperless/consume/
docker compose --project-directory . logs --tail=100 webserver | grep -i consum
```

**1. The container cannot read the file (the usual one).** Compare the uid
that owns the file on the host with the uid the container runs as:

```bash
stat -c '%u %g %a %n' ~/services/paperless-ngx/consume/* 2>/dev/null \
  || stat -f '%u %g %Lp %N' ~/services/paperless-ngx/consume/*
docker exec paperless-ngx id
grep -E 'USERMAP|PAPERLESS_UID|PAPERLESS_GID' \
     ~/dev/setup-server/paperless-ngx/.env
```

If the file is owned by some other uid with no read bit for the container's
user, Paperless never sees it. Files arriving by `scp`, from a Seafile sync
running as a different user, or copied with `sudo` are the usual sources.

```bash
chown $(id -u):$(id -g) ~/services/paperless-ngx/consume/*
chmod 644 ~/services/paperless-ngx/consume/*
```

The durable fix is `PAPERLESS_USERMAP_UID` / `PAPERLESS_USERMAP_GID` in `.env`
set to your `id -u` / `id -g` (which is what `setup.sh` does) so the container
runs as you and everything it writes back is yours too. Without that the
official image runs as its own user and every archived document ends up owned
by someone else on the host — which you discover later, when you try to back
them up.

**2. The directory inside the container is not the directory you dropped into.**
A bind mount that does not line up is silent:

```bash
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' paperless-ngx
```

`~/services/paperless-ngx/consume` must map to `/usr/src/paperless/consume`.

**3. The filesystem does not deliver inotify events.** Paperless watches the
directory with inotify, which does not work across some network filesystems
(NFS, SMB, some FUSE mounts — including things a Seafile client may present).
Symptom: dropping a file changes nothing, but restarting the container ingests
everything sitting there. The fix is polling:

```yaml
      PAPERLESS_CONSUMER_POLLING: 10          # seconds; 0 = inotify only
      PAPERLESS_CONSUMER_POLLING_RETRY_COUNT: 5
```

`~/services` is on this box's own disk, so this should not apply — but it is
the first thing to suspect if the consume directory is ever moved.

**4. The file is being ingested and rejected.** Duplicates are refused by
design (Paperless hashes content):

```
Not consuming <file>: It is a duplicate of <existing document>
```

That is correct behaviour. The file stays where it is so you can decide.

**5. It was consumed and you missed it.** Successful consumption **deletes the
file from `consume/`** and it appears in the documents list — possibly with an
unhelpful title. Search rather than scroll; the document may not be where you
expected in date order.

## OCR is slow, or a document never finishes processing

First, calibrate: **this is a 2018 Ryzen 5 2600 with no GPU acceleration.**
Tesseract is CPU-only — no graphics card would help — and OCR is by far the
most expensive thing this service does. Tens of seconds for a multi-page scan
is normal, and a bulk import of hundreds of documents will occupy this CPU for
hours and make everything else on the box feel slow.

Check whether it is working or stuck:

```bash
docker stats --no-stream paperless-ngx paperless-redis
docker compose --project-directory . logs --tail=100 webserver | grep -iE 'ocr|task|error'
```

In the UI, **Manage → Tasks** shows the queue, what is running, and the
failures with their tracebacks. That is the right place to look, not the log.

Common causes of genuinely stuck, as opposed to slow:

- **The worker died and the queue is not draining.** Nothing is in `docker
  stats` but tasks are pending. Restart:
  `docker compose --project-directory . restart`
- **Redis is not reachable.** Then *nothing* processes, ever, while the web UI
  works perfectly — the most confusing version of this.

  ```bash
  docker compose --project-directory . ps            # is redis up?
  docker exec paperless-redis redis-cli ping         # PONG
  docker exec paperless-ngx env | grep PAPERLESS_REDIS
  ```

- **The box is out of memory and the OOM killer took a worker.**

  ```bash
  free -m
  dmesg 2>/dev/null | tail -30 | grep -i 'killed process'
  docker inspect -f '{{.State.OOMKilled}}' paperless-ngx
  ```

  Every container here has a `mem_limit` for exactly this reason — an OCR
  worker on a huge scan is the most plausible thing on this box to run away
  with memory, and without a limit it takes the whole machine with it, not
  just itself. If `OOMKilled` is `true` on a specific large document, raising
  `mem_limit` for that job is more honest than pretending the document is
  corrupt.

- **The PDF is genuinely pathological** — a 400-page scan, or one with a
  broken text layer. Force it through with a different mode:
  `PAPERLESS_OCR_MODE: force` (re-OCRs everything, slower) or `skip_noarchive`.

To turn the volume down so the rest of the box stays usable:

```yaml
      PAPERLESS_TASK_WORKERS: 2          # concurrent documents
      PAPERLESS_THREADS_PER_WORKER: 2    # threads inside each
```

## Cannot log in (and it is not the CSRF 403)

The login page returns 200, you submit, and it comes back with *"The username
and/or password you specified are not correct."* — a normal-looking form
error, not a 403.

**Do not assume `.env` is the truth.** The password in `.env` is only what the
account was *created* with. Read out of the shipped image
(`manage_superuser.py`), the container's superuser step on every start is:

```python
if User.objects.filter(username=username).exists():   return   # no-op
if User.objects.filter(is_superuser=True).count() > 0: return   # no-op
User.objects.create_superuser(username, mail, password)
```

It never calls `set_password`. So:

- A password you changed in the UI is authoritative forever; `.env` goes stale
  and nothing warns you. **This is deliberate and good** — a re-run of
  `setup.sh` cannot stomp your password.
- Changing `PAPERLESS_ADMIN_USER` in `.env` after the first deploy creates
  **nothing**, silently, because a superuser already exists.

Reset it properly:

```bash
docker exec -it paperless-ngx python3 manage.py changepassword kai
```

List the accounts that actually exist, if you are unsure which username you
are typing:

```bash
docker exec paperless-ngx python3 manage.py shell -c \
  "from django.contrib.auth.models import User; print([(u.username, u.is_superuser) for u in User.objects.all()])"
```

If the list is **empty**, the account was never created — `PAPERLESS_ADMIN_USER`
was not set when the container first started, and the init step logged "Not
creating superuser" and moved on. Make one:

```bash
docker exec -it paperless-ngx python3 manage.py createsuperuser
```

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve has never been enabled for this
  tailnet. Open the link, approve, re-run `./setup.sh`.
- **The tailnet URL times out or 502s while loopback is fine** — Serve is
  pointed somewhere else, or the mapping is missing:

  ```bash
  tailscale serve status | grep -A2 ':8095'
  #   https://kai-home-server.taild6a23f.ts.net:8095 (tailnet only)
  #   |-- / proxy http://127.0.0.1:8095
  ```

- **A brand-new port can take up to a minute** on its first request while the
  TLS certificate is minted. A single slow first load is not a fault.

### Removing the publish

To unpublish just this service:

```bash
tailscale serve --https=8095 off
```

⚠️ **Never `tailscale serve reset`.** That clears **every** mapping on this
node — code-server, Seafile, Immich, Open WebUI, Uptime Kuma, ntfy, n8n,
forgejo, Home Assistant, AdGuard, the lot — and they do not come back on their
own. `off` is the single-port removal; it is missing from `--help` but it is
what Tailscale itself prints.

Verify afterwards that you removed one line and not thirteen:

```bash
tailscale serve status
```

## Disk filling up

```bash
du -sh ~/services/paperless-ngx/*
df -h ~
```

`media/` grows with every document and holds **two** copies of most of them —
the original you fed in, plus the OCR'd archive PDF Paperless generated. That
is the design, and it is what makes the archive readable without Paperless.

Things that are safe to delete:

- `~/services/paperless-ngx/export/` — regenerate it whenever you like. If it
  is large, it is an old export you already copied elsewhere (you did copy it
  elsewhere?).
- `~/services/paperless-ngx/redis/` — broker scratch, nothing durable.

Things that are **not** safe to delete: `media/` (the documents) and `data/`
(the metadata). "Clearing the cache" is not a thing here.

Thumbnails can be regenerated if something went wrong with them, without
touching originals:

```bash
docker exec paperless-ngx document_thumbnails
```

## Nuke and pave

Destroys **every document, every tag, every correspondent and the search
index**. This is not the same class of operation as it is for the other
services in this repo — for AdGuard it costs you a blocklist choice; here it
costs you the archive. This box has no backups.

**Step 1 is not optional.**

```bash
cd ~/dev/setup-server/paperless-ngx

# 1. EXPORT FIRST. Self-contained: documents + a JSON manifest of all metadata,
#    importable into any Paperless. Then COPY IT OFF THIS BOX.
docker exec paperless-ngx document_exporter ../export
ls -la ~/services/paperless-ngx/export/ | head
du -sh ~/services/paperless-ngx/export/
#    ...and now actually move it somewhere else. A copy on the same disk is
#    not a backup of a disk failure.

# 2. Confirm the paths before deleting them. A `rm -rf` of a path that never
#    existed is a silent no-op that leaves you convinced you started clean.
#    The .env values are the authority — if setup.sh was ever run with
#    different paths, ~/services/paperless-ngx is NOT where the data is.
grep -E '^(PAPERLESS_DATA|PAPERLESS_MEDIA|PAPERLESS_CONSUME|PAPERLESS_EXPORT|PAPERLESS_ROOT)' .env
ls -ld ~/services/paperless-ngx \
       ~/services/paperless-ngx/data \
       ~/services/paperless-ngx/media \
       ~/services/paperless-ngx/consume \
       ~/services/paperless-ngx/export
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' paperless-ngx
#    The Source paths above are the ground truth for what to delete. If a path
#    printed by `ls -ld` errors with "No such file or directory", do not
#    include it in step 4 — find where the data really is first.

# 3. Tear down the containers and their anonymous volumes.
docker compose --project-directory . down -v

# 4. Delete the state. Only the paths you confirmed exist in step 2.
rm -rf ~/services/paperless-ngx/data \
       ~/services/paperless-ngx/media \
       ~/services/paperless-ngx/consume \
       ~/services/paperless-ngx/redis
#    NOTE: export/ is deliberately not in that list — it is your escape hatch.

# 5. New credentials and a new secret key on the next deploy.
rm -f .env

# 6. Unpublish this ONE port. Not `serve reset`.
tailscale serve --https=8095 off

# 7. Redeploy.
./setup.sh
```

Two things make this recipe safe rather than superstitious:

- **Step 2 prints the mounts from the container itself.** `docker inspect`'s
  `.Mounts` is what the running container is genuinely using, which beats both
  `.env` and this document if they ever disagree. Delete what it names.
- **`rm -rf` here does not need `sudo`** *if* the container ran as your uid
  (`PAPERLESS_USERMAP_UID`, which is what `setup.sh` sets). If it did not, the
  files are owned by the image's user and a plain `rm -rf` fails partway
  through, leaving a half-deleted data directory — which is worse than either
  extreme, because Paperless will start on it and behave strangely. Check
  first:

  ```bash
  stat -c '%U' ~/services/paperless-ngx/media 2>/dev/null \
    || stat -f '%Su' ~/services/paperless-ngx/media
  ```

  If that is not you, delete from inside a root container instead of reaching
  for `sudo`:

  ```bash
  docker run --rm -v ~/services/paperless-ngx:/x --entrypoint rm alpine \
    -rf /x/data /x/media /x/consume /x/redis
  ```

### The much smaller hammer you probably want

To rebuild the containers and keep every document:

```bash
cd ~/dev/setup-server/paperless-ngx
docker compose --project-directory . up -d --force-recreate
```

To fix a broken search index without touching documents:

```bash
docker exec paperless-ngx document_index reindex
docker exec paperless-ngx document_create_classifier
```

To restore from an export into a fresh instance:

```bash
docker exec paperless-ngx document_importer ../export
```
