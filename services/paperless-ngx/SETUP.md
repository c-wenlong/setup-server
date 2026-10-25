# paperless-ngx — OCR'd, searchable document archive

Scan or drop a PDF in; get back a document with its text extracted, its date
and correspondent guessed, tagged, full-text searchable, and filed under a
name you can actually read. On the tailnet at
`https://kai-home-server.taild6a23f.ts.net:8095`.

This is the box's answer to the shoebox of PDFs: tax filings, payslips,
tenancy agreements, insurance, warranties, medical letters. Seafile (`:8443`)
already stores files; Paperless is the layer that makes a decade of them
*findable* — OCR over scans so a photographed receipt is searchable text, and
metadata (correspondent / document type / tags / date) so "the 2024 tax
assessment" is one query rather than a directory crawl.

Read the honest paragraph in [What this is now the archive of
record for](#what-this-is-now-the-archive-of-record-for) before you start
feeding it originals. It matters more than anything else on this page.

## Architecture

Two containers. Paperless itself, and the Redis broker its task queue
requires:

```
  browser / phone on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8095
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8095       ← Host: header preserved
            ▼
   ┌──────────────────────────────────────────────┐
   │ container: paperless-ngx                     │
   │   ghcr.io/paperless-ngx/paperless-ngx:<pin>  │
   │                                              │
   │   granian / Django 5.2       :8000           │
   │   celery workers   ─ OCR, thumbnails, index  │
   │   OCRmyPDF + Tesseract       (CPU only)      │
   │   SQLite                     (in-process)    │
   │   Whoosh full-text index                     │
   └───────┬──────────────────────────────┬───────┘
           │ bind mounts                  │ redis://redis:6379
           ▼                              ▼
   ~/services/paperless-ngx/…    ┌────────────────────┐
                                 │ container: redis   │
                                 │   redis:7-alpine   │
                                 │   task broker only │
                                 └────────────────────┘
```

**Redis is a broker, not a database.** Paperless hands OCR jobs to celery
through it; nothing durable lives there. Losing the Redis volume loses at most
the queue of documents not yet consumed — the documents themselves are on
disk. It is configured to persist nothing for exactly that reason.

**SQLite, not PostgreSQL.** Paperless supports both. On a single-user box with
a few thousand documents SQLite is the right call: one fewer container, a few
hundred MB less RAM on a machine that is short of it, and a backup that is a
file copy instead of a `pg_dump`. Postgres earns its keep at multi-user
concurrency this box will never see. If you ever want to switch, Paperless
ships `document_exporter` / `document_importer` and the migration is a
documented export-and-reimport, not a hack.

### Storage layout

Everything lives under `~/services/paperless-ngx`:

```
~/services/paperless-ngx/
  data/        # SQLite DB, the Whoosh search index, classification model
  media/       # THE DOCUMENTS — originals + generated archive PDFs + thumbnails
  consume/     # DROP FOLDER — anything landing here gets ingested and deleted
  export/      # destination for `document_exporter` (empty until you run one)
```

Two of these matter and they matter differently:

- **`media/` is the irreplaceable one.** It holds the original file you fed in
  *and* the OCR'd archive PDF Paperless generated from it.
- **`data/` is rebuildable but painful.** The search index and the ML
  classifier can be regenerated (`document_index reindex`,
  `document_create_classifier`); the SQLite database holds the *metadata* —
  every tag, correspondent, date and title, including the ones you corrected
  by hand. Losing it means keeping the files and losing the filing.

`consume/` is a mailbox, not storage. Paperless watches it, ingests what
appears, and **removes the file** once it is safely stored in `media/`. Files
sitting in `consume/` for more than a minute or two mean something is wrong —
see TROUBLESHOOT.md.

## Security model

The standard shape for this repo, and it carries more weight here than usual:

- The container publishes to **`127.0.0.1:8095` only**. Nothing binds a LAN
  interface, no firewall port is opened.
- `tailscale serve --bg --https=8095` puts it on the tailnet, TLS terminated
  by tailscaled, reachable only by devices on the tailnet.
- Paperless has its own login on top of that (`PAPERLESS_ADMIN_USER`), so the
  tailnet boundary is not the only thing between a document archive and a
  stranger. That is deliberate: this is the one service on the box where the
  contents are, categorically, the sensitive ones.

Port **8095** is this service's. Note **8098 is not free** — an ad-hoc
`python3 echosrv.py` has held it since before this deploy and is not managed
by this repo; do not reclaim it.

### The reverse-proxy trap — read this one

Paperless is Django, and Django is strict about which hostnames it will answer
to and which origins it will accept a form POST from. Behind Tailscale Serve,
getting this wrong produces failures that do not look like configuration
failures. Both halves below were read out of the shipped image
(`src/paperless/settings/__init__.py`, and Django 5.2.16's
`middleware/csrf.py`), not from memory.

**One variable drives all of it:**

```yaml
PAPERLESS_URL: https://kai-home-server.taild6a23f.ts.net:8095
```

`PAPERLESS_URL` is not cosmetic and it is not just for links in emails. The
image expands it into three settings at startup:

```python
CSRF_TRUSTED_ORIGINS.append(url)                  # the whole string, exact
CORS_ALLOWED_ORIGINS.append(url)
ALLOWED_HOSTS.append(urlparse(url).hostname)      # hostname only, port dropped
```

**It must carry the scheme and the port.** Django's CSRF check compares the
browser's `Origin` header against `CSRF_TRUSTED_ORIGINS` by **exact string**.
Serve terminates TLS and proxies plain HTTP, so Django computes its own idea of
the origin as `http://kai-home-server.taild6a23f.ts.net:8095` while the browser
sends `https://…:8095`. Those differ, so the only thing that lets a login
through is that exact `https://…:8095` string being in the trusted list.

The symptom when it is missing is the nasty part:

> Every page loads fine. `curl` returns 200. The login page renders. You type
> your password, press Sign in, and get **403 Forbidden — "CSRF verification
> failed. Request aborted."**

Nothing about that says "a URL is wrong", and no `curl` health check can see
it, because `curl` does not send an `Origin` header — the rule only fires for
browser POSTs. That is why this repo's live suite performs an actual login,
with an `Origin` header, rather than fetching a page and calling it green.

**Do not "harden" `ALLOWED_HOSTS`.** The other half of the trap runs the
opposite way. Out of the box `ALLOWED_HOSTS` is `["*"]`, so nothing 400s.
Setting `PAPERLESS_ALLOWED_HOSTS` to the tailnet name looks like an
improvement and is a regression: Django appends `localhost` to a narrowed list
— but **not `127.0.0.1`** — so the browser keeps working while

```
http://127.0.0.1:8095/  ->  400 Bad Request
                            Invalid HTTP_HOST header: '127.0.0.1:8095'.
```

which is the local health check, the Uptime Kuma monitor, and this repo's live
suite, all red against a perfectly healthy app. `["*"]` is not a real exposure
here: the only things that can reach the port are loopback and Serve, and
Serve only accepts tailnet clients. The boundary is the network, not the
header. If you insist on narrowing it, `127.0.0.1` must be in the list.

## Dependencies

| Dependency | Why | Checked by |
|---|---|---|
| Docker + compose v2 | both containers | preflight |
| Tailscale, up | the only way in | preflight (`BackendState`) |
| Tailscale Serve enabled on the tailnet | publishes :8095 | prompts + retries |
| `tailscale` operator = you | `serve` without sudo | granted once via sudo |
| ~1 GB RAM headroom | Paperless + Redis | see below |
| Free port 8095 | the publish | preflight |

No Tesseract, OCRmyPDF, Ghostscript or Python on the host — every one of those
is inside the image. Nothing is installed on this machine but the containers.

## What is NOT deployed: Tika and Gotenberg

Upstream's reference `docker-compose` ships two more containers:

| Container | What it adds |
|---|---|
| **Gotenberg** | converts Office documents (`.docx`, `.xlsx`, `.pptx`, `.odt`) to PDF so Paperless can archive them |
| **Apache Tika** | extracts text/metadata from those same Office formats |

**Neither is deployed here, and the reason is RAM.** This box has 7.7 GB total,
and at the time of writing was sitting at roughly 2.5 GB available with 1.9 GB
of swap already in use — ollama alone claims ~5 GB the moment a model loads.
Gotenberg and Tika are both JVM-and-headless-browser shaped; together they are
several hundred MB of resident memory, permanently, in exchange for a feature
whose whole job is Word documents. **The archive of record for this box is PDFs
and scans**, which the base image handles natively. That is a deliberate trade,
not an oversight.

**Nothing is lost permanently by leaving them off.** Office files can still be
stored — Paperless keeps them as originals — they just are not converted to an
archival PDF or full-text indexed. Turn the pair on later and re-run
`document_archiver` and they get processed retroactively.

To enable them, add to `docker-compose.yml`:

```yaml
  gotenberg:
    image: docker.io/gotenberg/gotenberg:8.24            # pin it
    container_name: paperless-gotenberg
    restart: unless-stopped
    mem_limit: 512m
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"

  tika:
    image: docker.io/apache/tika:3.2.3.0                 # pin it
    container_name: paperless-tika
    restart: unless-stopped
    mem_limit: 512m
```

and to the web container's environment:

```yaml
      PAPERLESS_TIKA_ENABLED: 1
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000
      PAPERLESS_TIKA_ENDPOINT: http://tika:9998
```

Then `docker compose --project-directory . up -d` and watch `free -m`. If the
box starts swapping harder than it already is, that is your answer: take them
back out. Neither container binds a host port, so this adds no exposure.

## OCR on this box: what to expect

The CPU is an **AMD Ryzen 5 2600** (6 cores / 12 threads, Zen+, 2018) and
there is **no GPU acceleration** — Tesseract does not use one, so a graphics
card would not help even if this box had a useful one. OCR is pure CPU and it
is the slowest thing Paperless does by a wide margin.

Practical consequences:

- A freshly ingested multi-page scan takes **tens of seconds to minutes**, not
  the instant response the rest of the UI gives you. This is normal. The
  document appears in the list first and its text arrives when the worker
  finishes.
- **A bulk import of hundreds of documents will saturate this CPU for hours.**
  Do it overnight, and expect everything else on the box (code-server, Immich
  thumbnailing, ollama) to feel it. Paperless's `PAPERLESS_TASK_WORKERS` and
  `PAPERLESS_THREADS_PER_WORKER` are the throttle if you need one to stay
  polite.
- A **digital** PDF that already has a text layer is fast — Paperless skips
  OCR for it by default (`PAPERLESS_OCR_MODE: skip`). The expensive case is
  photographs and flatbed scans.
- Scan quality dominates the result. 300 dpi, straight, good contrast. No
  amount of CPU rescues a phone photo taken at an angle in bad light.

`PAPERLESS_OCR_LANGUAGE` is set to `eng`. Additional languages need their
Tesseract data installed in the image
(`PAPERLESS_OCR_LANGUAGES: "chi_sim deu"` makes the container fetch them at
start, which costs a slower first boot).

## First login

```
URL:      https://kai-home-server.taild6a23f.ts.net:8095
Login:    kai
Password: PAPERLESS_ADMIN_PASSWORD in services/paperless-ngx/.env
```

`.env` is mode 600 and is git-ignored. `setup.sh` generates the password on
the first run and never touches it again.

**Change it in the UI if you want to** — Settings → your user. Doing so is
safe and will *not* be undone by a later `./setup.sh`: the container's
`manage_superuser` step is a no-op once the account exists (see below), so the
value in `.env` simply goes stale. Update the `.env` comment or your password
manager; nothing in the deploy re-reads it.

First things worth doing, in the UI:

1. **Settings → check the date format** matches how your documents are
   written, or date detection will guess wrong.
2. **Create a couple of correspondents and document types** (`Tax`, `Bank`,
   `Insurance`, …). Paperless's classifier learns from your corrections, so the
   first twenty documents you file by hand are what make the next two hundred
   file themselves.
3. **Mail** (optional): Settings → Mail accounts can pull attachments straight
   out of an IMAP folder. Nothing is configured by this deploy.

### Why re-running setup.sh will not reset your password

Worth stating precisely, because the opposite is a common (and true) complaint
about other self-hosted apps. Read out of the shipped image —
`src/documents/management/commands/manage_superuser.py`, byte-identical in
2.18.4 and 3.1.3 — the container runs this on **every** start:

```python
if User.objects.filter(username=username).exists():
    "Did not create superuser, a user X already exists";  return
if User.objects.filter(is_superuser=True).count() > 0:
    "Did not create superuser, the DB already contains superusers";  return
User.objects.create_superuser(username, mail, password)
```

So: created once, then an explicit early return. **It never calls
`set_password`.** A password you change in the UI survives every restart and
every re-run of `setup.sh`.

The corollary is the failure mode: if the database already contains *any*
superuser, an account for a *new* `PAPERLESS_ADMIN_USER` is silently not
created. Changing the admin username in `.env` after the first deploy does
nothing at all, with no error. Add users in the UI instead.

## Getting documents in

Four routes, roughly in order of how much you will actually use them.

### 1. The consumption directory (the good one)

```
~/services/paperless-ngx/consume/
```

Anything that lands there is ingested and then **deleted from the folder** —
the file now lives in `media/`, under Paperless's own naming. Copy a PDF in
and it shows up in the UI within a few seconds (plus OCR time).

```bash
cp ~/Downloads/tax-assessment-2025.pdf ~/services/paperless-ngx/consume/
```

Filenames are not thrown away — Paperless uses them as the initial title, and
can parse dates out of them. `2025-04-12 IRAS assessment.pdf` gives it a real
head start over `scan0001.pdf`.

⚠️ **Ownership.** The container writes as its own uid. If files you drop in are
not readable by it, they sit there forever with nothing in the UI to tell you
why — the log is the only place it shows up. `setup.sh` creates the directory
with your uid/gid for this reason. See TROUBLESHOOT.md →
*Documents sit in consume/ and nothing happens* before you go changing
permissions by hand.

### 2. Drag and drop in the web UI

Top-right of the documents list. Fine for one file, fine from a phone, and it
is the only route that works from a device that is not this machine without
setting something else up.

### 3. Via Seafile — the drop-folder flow

**Seafile is already running on this box** at
`https://kai-home-server.taild6a23f.ts.net:8443`, with a desktop client and
phone photo backup. It is the natural front end for "scan this and file it"
from anywhere: put a document in a Seafile library from your phone, have it
sync to this box, and let Paperless consume it.

The wiring is not automatic and this deploy does **not** set it up — it would
mean reaching into Seafile's storage layout, which is another service's
business. The two sane options:

- **Point a Seafile library's synced copy at the consume directory** on this
  host (a Seafile *sync* rather than the seaf-data internal store), so files
  arriving from your phone land in `consume/`.
- **Or a one-line cron/systemd timer** that moves files from a synced folder
  into `consume/`. Crude, obvious, easy to debug — which on a box with no
  backups is worth more than elegance.

Do it deliberately, and remember that Paperless *deletes* what it consumes: if
it consumes out of a synced Seafile folder, the deletion syncs too. That is
usually what you want (the document is now in Paperless) but it will look like
data loss the first time.

### 4. Email

Paperless can poll IMAP and ingest attachments. Nothing is set up by this
deploy; it is entirely a UI configuration (Settings → Mail). Useful for
statements that arrive as attachments, and it is the one route that files
things without you being involved at all.

## What this is now the archive of record for

Be clear-eyed about what you are about to do.

The point of this service is that you feed it originals — the tax assessment,
the tenancy agreement, the insurance policy, the medical letter — and then
stop maintaining a parallel copy, because the whole value is having one
searchable place. Within a few months this box will be the only place several
of those documents exist in a form you can find.

**This box has no backups.** Not a degraded backup, not an old backup: none.
Its disk is a single point of failure, and everything above — `media/`,
`data/`, the SQLite database holding every tag and title you corrected by hand
— dies with it. A drive failure, a bad `rm -rf`, or a container that eats its
own volume takes the archive with it, and unlike photos or code there is
frequently **no second copy anywhere in the world** of a signed PDF someone
emailed you in 2019.

So, honestly:

- **Do not shred the paper** because it is in Paperless. Not yet, and probably
  not ever for the documents that are legally annoying to replace.
- **Do run an export.** Paperless has a first-class answer and it is one
  command:

  ```bash
  cd ~/dev/setup-server/services/paperless-ngx
  docker compose --project-directory . exec -T webserver \
    document_exporter ../export
  ```

  That writes `media/`'s documents *plus* a JSON manifest of all the metadata
  into `~/services/paperless-ngx/export/` — a self-contained, importable
  archive that does not need this box, this database or this version to be
  readable. Copy the result somewhere else: a Seafile library that syncs to
  your laptop, an external disk, anywhere that is not this drive.
- **Then actually verify it once.** An export you have never restored is a
  belief, not a backup.

Nothing in this deploy does that for you on a schedule. It is the single
highest-value thing to automate next (n8n is on `:5678` and would do it), and
until it exists, treat this service as a very good index of documents you
still hold elsewhere.

## What `setup.sh` does

Idempotent throughout — re-running upgrades or repairs, never resets.

1. **Preflight** — refuses to run as root; checks docker reachability, compose
   v2, Tailscale up, the port is free, and that the tailnet name resolves.
2. **Resolve the tailnet URL** from `tailscale status`, never hardcoded. This
   is what becomes `PAPERLESS_URL`, and therefore `CSRF_TRUSTED_ORIGINS` — a
   baked-in hostname would be a login that fails on any other machine.
3. **Generate `.env` if absent** (mode 600): the admin password, the Django
   `PAPERLESS_SECRET_KEY`, the pinned image tag, the ports, the data paths. If
   `.env` exists it is left completely alone.
4. **Create the data directories** with your uid/gid.
5. **`docker compose up -d`** with the pinned tag. First boot runs migrations
   and creates the admin account.
6. **Wait for readiness properly** — a cold Paperless is not listening at all
   while migrations run, so the probe treats a refused connection (curl exit 7,
   HTTP `000`) as "not yet", not as failure.
7. **Publish** with `tailscale serve --bg --https=8095`, granting the operator
   bit via sudo once if needed, and printing the approval link if the tailnet
   has never had Serve enabled.
8. **Verify** — health path 200 on loopback, 200 over tailnet HTTPS, the
   listener audit (loopback only), and a real login POST with an `Origin`
   header to prove the CSRF configuration is right.

## Ops

```bash
cd ~/dev/setup-server/services/paperless-ngx

docker compose --project-directory . ps
docker compose --project-directory . logs -f --tail=50
docker compose --project-directory . restart
docker compose --project-directory . up -d          # after editing compose
./teardown.sh                                       # Remove: unpublish + down, archive and .env kept
./teardown.sh --purge                               # ALSO delete data/ media/ .env (export first!)

./tests/run-tests.sh                                # mocked, no side effects
sg docker -c './tests/run-tests.sh --live'          # against the real deploy
```

Health, by hand:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/accounts/login/
#   200 = healthy.  000 = not listening.  400 = ALLOWED_HOSTS (see above).
```

`/accounts/login/` — **not `/`** — is the health path, here and in the Uptime
Kuma monitor. `/` returns a 302 to the login page, and Kuma scores a 302 as
**down**.

Useful management commands (all inside the container):

```bash
dc() { docker compose --project-directory ~/dev/setup-server/services/paperless-ngx "$@"; }

dc exec -T webserver document_exporter ../export     # full backup, see above
dc exec -T webserver document_index reindex          # rebuild the search index
dc exec -T webserver document_create_classifier      # retrain the auto-tagger
dc exec -T webserver document_archiver               # regenerate archive PDFs
dc exec -T webserver document_retagger -c -T -t      # re-apply rules to everything
```

## Related

- **TROUBLESHOOT.md** — the 403/400 reverse-proxy failures, consume-directory
  permissions, OCR that never finishes, removing the Serve mapping safely, and
  a nuke-and-pave with verified paths.
- **Uptime Kuma** (`:3002`) monitors `/accounts/login/` for a 200.
- **Seafile** (`:8443`) — the drop-folder story above.
