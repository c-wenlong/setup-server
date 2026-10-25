# jellyfin — self-hosted media server (a Netflix you own)

Movies, TV, music and photos with a real client on every screen — TV, phone,
browser — on the tailnet:
`https://homeserver.tail-name.ts.net:8096`.

Chosen over Plex and Emby, and the reason is ownership rather than features.
Plex is the polished one, but it authenticates through **plex.tv**: a server
on a private tailnet still asks a company's cloud for permission to let you
in, and Plex has repeatedly moved features (remote streaming, most recently)
behind a subscription. Emby went source-available in 2018; Jellyfin is the
fork the community made from the last GPL Emby, and it is still GPLv2, still
has no accounts you do not control, and no paid tier to lose features to.

The cost is honest: Jellyfin's metadata scraping is a little worse than
Plex's, its clients are less uniform, and nobody is on call for it. On a box
whose whole premise is "no third party in the loop", that is the right trade.

## Architecture

One container. Nothing else — no database sidecar, no transcoding worker:

```
  TV / phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:8096
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8096
            ▼
   ┌────────────────────────────────┐
   │ container: jellyfin            │
   │   jellyfin/jellyfin:12.0       │
   │   (reports 12.0.0)             │
   │                                │
   │   web + API      :8096         │
   │   SQLite         (in-process)  │
   │   transcoding    CPU only      │
   └────────────┬───────────────────┘
                │ bind mounts
                ▼
      ~/services/jellyfin/config  →  /config   (rw)
      ~/services/jellyfin/cache   →  /cache    (rw)
      ~/services/jellyfin/media   →  /media    (ro)
```

State lives under `~/services/jellyfin`:

```
~/services/jellyfin/
  config/                  # the entire instance — the only backup target
    data/                  #   SQLite: users, libraries, watch state
    config/*.xml           #   server settings, encoding options
    log/                   #   server logs (also via docker logs)
    metadata/              #   fetched posters, fanart
  cache/                   # image + subtitle caches, plus transcode scratch
                           #   (transcodes/) — all disposable
  media/                   # MEDIA_DIR — mounted READ-ONLY into the container
  .wizard-complete         # marker: the first-run wizard already ran
                           #   (contains the admin username)
```

The `config/` sub-layout above is Jellyfin's long-standing shape and is what
matters for backups: **the whole of `config/` is the backup target**, so you
do not need to know which file holds what. 12.0 rewrote the database, so
individual filenames inside `config/data/` are not worth memorising — and
guides that name a specific `.db` file are talking about 10.x.

Idle footprint is **211 MiB** — measured, not estimated (`docker stats
jellyfin` on a freshly started container with an empty library). Transcoding
is what actually costs, and that is CPU, discussed below.

`config/` is the only directory that matters. `cache/` can be deleted at any
time; `media/` is yours and the container cannot write to it. Note that
transcode scratch lands under `config/transcodes`, **not** `cache/` — so
"reclaim space" and "back this up" are not quite the same directory.

The container runs as `${JELLYFIN_UID}:${JELLYFIN_GID}` (your uid/gid, baked
into `.env` from `id -u`/`id -g`). Without that the official image runs as
root and everything it writes into the bind mounts ends up root-owned, so
moving or backing up the library later needs `sudo`.

## Why v12 on this box, when the internet says stay on 10.11

`docker-compose.yml` pins `jellyfin/jellyfin:12.0` (reports **12.0.0**).

This deliberately contradicts the advice you will find everywhere right now,
so here is the whole reasoning rather than a shrug.

**v12.0 shipped 2026-09-08 — three days ago.** It is a .NET 10 rewrite and a
genuinely disruptive release:

- **Every third-party plugin breaks.** The plugin ABI changed; nothing built
  for 10.x loads.
- **The legacy API prefixes are gone.** `/emby/…` and `/mediabrowser/…` no
  longer exist. Old clients and scripts that hit those paths get 404s.
- **The database schema is rewritten**, and there is no supported downgrade.
  A `config/` directory that has been opened by 12.0 cannot be handed back
  to 10.11.

Which is exactly why the community consensus is "stay on 10.11.x and wait for
12.0.1". That advice is correct — **for people with an existing library.**
They have plugins they depend on, clients pinned to old API paths, and years
of watch history in a database that a bad migration can eat.

**This box has none of that.** It is a greenfield install:

- No plugins are installed, so no plugins can break.
- No clients are configured yet, so nothing is calling `/emby/`.
- The database does not exist until `setup.sh` creates it, so there is no
  migration to survive — 12.0 simply writes a 12.0 schema.

Under those conditions the calculus inverts. Starting on 10.11 would mean
doing the painful migration **later, with real data in it** — the exact
scenario everyone is telling you to be careful about. Starting on 12.0 pays
zero migration cost now and skips the migration entirely.

**And the fallback is free while the library is empty.** If 12.0 turns out to
be unusable, the escape is not a downgrade — it is a re-install, which costs
nothing when there is nothing in it:

```bash
cd ~/dev/setup-server/services/jellyfin
docker compose --project-directory . down
rm -rf ~/services/jellyfin/config ~/services/jellyfin/cache   # empty anyway
rm -f  ~/services/jellyfin/.wizard-complete   # or the wizard is skipped
sed -i 's/^JELLYFIN_VERSION=.*/JELLYFIN_VERSION=10.11.11/' .env
./setup.sh
```

(The marker line matters: it is what tells a re-run the wizard has already
run. Forget it and `setup.sh` stops with a `Stale marker:` error — it
cross-checks the marker against the live server's `StartupWizardCompleted`
rather than trusting it — so the failure is named rather than mysterious, but
you still have to delete the file.)

**The moment that stops being free is the moment you have watch history.**
Once real users have watched real things, `config/data/` holds state that
only exists here, on a machine with no backup, in a schema 10.11 cannot read.
Re-decide the version *now*, while the answer is cheap.

## The readiness trap (why the deploy polls `/Startup/FirstUser`)

This is the single sharpest edge in automating Jellyfin, and getting it wrong
produces a deploy that reports success and cannot be logged into.

Jellyfin starts answering HTTP **before it has finished loading**:

| Endpoint | During startup | After startup |
|---|---|---|
| `GET /System/Info/Public` | **200** | 200 |
| `GET /Startup/FirstUser` | **503** "Jellyfin Server is loading" | 200 |

So the obvious health check — "wait until `/System/Info/Public` answers" —
returns true while the server is still booting. If the wizard POSTs start
there, the early calls hit 503s. The failure is not loud: the wizard sequence
can get far enough that `/Startup/Complete` succeeds and
`StartupWizardCompleted` flips to `true`, **while the `/Startup/User` call
that creates the admin account was one of the ones that 503'd**.

The result is a finished wizard with no admin account. The container is
healthy, the web UI loads, the deploy script printed a password — and that
password belongs to a user that does not exist. There is no "create the first
user" screen to fall back to, because the server believes setup is done.

`setup.sh` therefore gates on the endpoint that actually tracks readiness:

```
poll GET /Startup/FirstUser  until it stops returning 503
```

`tests/run-tests.sh` has a dedicated case for this: the `curl` stub returns
503 for the first N `/Startup/*` calls and the test asserts the script keeps
polling rather than proceeding to the wizard.

## Why `GET /Users/Public` is not a check

The intuitive way to confirm the admin exists is to list users. Do not.

**`GET /Users/Public` returns `[]` on a fully successful setup.** It does not
list users — it lists users *configured to appear on the login screen*, which
by default is none of them. An empty array is the correct, healthy response
for a working install with an admin account sitting in it.

Using it as a health or success check makes a perfect deploy look broken, and
"fixing" the deploy until that endpoint returns something means changing the
server's login-screen policy for no reason.

The real check is to log in. `setup.sh` finishes with:

```bash
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H 'Authorization: MediaBrowser Client="setup.sh", Device="homeserver", DeviceId="setup-sh", Version="1.0"' \
  -d '{"Username":"admin","Pw":"<from .env>"}' \
  http://127.0.0.1:8096/Users/AuthenticateByName
```

and requires **200** with `.User.Policy.IsAdministrator == true`. That one
call proves the account exists, the generated password works, and it is an
admin. Anything less is fatal — the deploy exits non-zero rather than
printing credentials that do not work.

⚠️ The `Authorization: MediaBrowser …` header is **mandatory**, not
decoration. Jellyfin rejects `AuthenticateByName` with 400 if the client
identity fields are missing. The four fields (`Client`, `Device`, `DeviceId`,
`Version`) are what shows up in Dashboard → Devices; the values do not matter,
their presence does.

`setup.sh` makes this call **over the tailnet HTTPS URL**, not over
`127.0.0.1`. That is deliberate: one request then proves the whole chain at
once — Serve routes, TLS works, the generated password logs in, and the
account is an administrator.

## `JELLYFIN_PUBLISHED_URL` — the other thing that fails silently

`.env` carries `JELLYFIN_PUBLISHED_URL=https://<tailnet-host>:<port>`, which
becomes `JELLYFIN_PublishedServerUrl` in the container.

This is the address Jellyfin **hands to clients** for streaming, remote
sessions and cast targets. Unset or wrong, the server advertises its own
container address and every client is told to fetch video from `127.0.0.1` —
which works on this box and fails on every other device, with nothing useful
in the logs. It is the same class of trap as Forgejo's `ROOT_URL`.

`setup.sh` resolves it from `tailscale status --json` before the container
starts, and on every run it:

- **warns if `.env` has drifted** from the live tailnet name or HTTPS port,
  printing the exact line to fix — it does not rewrite `.env`, which is
  yours; and
- **reads it back from the server** after the deploy: `LocalAddress` on
  `/System/Info/Public` echoes `PublishedServerUrl`, so a mismatch there is
  reported rather than assumed away.

## Hardware transcoding (NVENC) — opt-in, one command

Software transcoding is the default. `setup.sh` never enables NVENC by
itself, because the GPU plumbing needs `sudo`, touches the host's package
manager and restarts the Docker daemon — none of which belong in a deploy
script that is otherwise safe to re-run at any time.

The box has the hardware — a **GTX 1070**, driver **580** — and the kernel
driver is loaded (`nvidia-smi` works). What a container needs on top of that
is `nvidia-container-toolkit`, which registers an `nvidia` runtime with
dockerd. Until that is installed, no compose flag can reach the GPU.

That install lives in **`./enable-nvenc.sh`**, the sudo-requiring half:

```bash
./enable-nvenc.sh           # install the runtime, prove it, switch Jellyfin on
./enable-nvenc.sh --check   # report status, change nothing
JELLYFIN_NVENC=off ./setup.sh   # back to software (leaves the toolkit installed)
```

It adds NVIDIA's apt repo (the package is **not** in Ubuntu's archive),
installs the toolkit, runs `nvidia-ctk runtime configure --runtime=docker`,
restarts dockerd, then proves a container can actually see the GPU before it
changes anything about Jellyfin. Every step is skipped if already done, so a
re-run after a partial failure resumes rather than repeats.

**⚠️ The dockerd restart bounces every container on this box** — Immich,
Seafile, Forgejo, the lot. They all carry restart policies and come back on
their own, but do it deliberately, not at 2am.

### How the flag is wired

`JELLYFIN_NVENC` in `.env` is owned by `setup.sh` (the same idiom as immich's
`COMPOSE_PROFILES`). When it is `on`, setup.sh layers
`docker-compose.gpu.yml` over the base file; when `off`, the overlay is never
loaded. The GPU reservation is deliberately **not** a commented-out block in
`docker-compose.yml`, because a commented block invites someone to uncomment
it before the runtime exists and get a container that will not start.

If the flag is `on` but dockerd has no `nvidia` runtime, setup.sh **aborts
before `compose up`** rather than letting compose fail with `could not select
device driver "nvidia"` — an error that reads like a Jellyfin fault, is
really a missing host package, and would take the running container down on
the way.

### The trap worth knowing about

`--gpus all` (and the compose `deploy.reservations` equivalent) defaults
`NVIDIA_DRIVER_CAPABILITIES` to `utility,compute` — which does **not**
include `video`. Without `video`, `libnvidia-encode` is never mounted into
the container: `nvidia-smi` works inside it, the Jellyfin dashboard happily
shows NVENC as enabled, and every transcode still runs on the CPU. That is
why `docker-compose.gpu.yml` sets `NVIDIA_DRIVER_CAPABILITIES: all`
explicitly, and why `enable-nvenc.sh` checks for the encoder library
separately from checking for the GPU.

### What this GPU can and cannot do

Pascal GP104: **encode** H.264 and HEVC (8-bit and 10-bit); **decode** H.264,
HEVC 8/10-bit, VP9, VC1, MPEG2. **No AV1** in either direction — Turing and
later only, so leave AV1 unticked in the dashboard or those files fail
instead of falling back to the CPU. Leave "low-power" off too; that is a
QuickSync setting. GeForce drivers also cap concurrent NVENC sessions, which
is fine for a household and a wall for a many-viewer server.

**What software transcoding actually costs here.** The CPU is a Ryzen 5 2600
(6 cores / 12 threads). It handles a 1080p transcode comfortably and can do
two if nothing else is busy. 4K transcoding is not realistic. In practice
this matters less than it sounds: **direct play does not transcode at all**,
and a client that can play the file natively (any modern TV app, the desktop
app, Infuse on Apple hardware) never asks the server to re-encode. Transcodes
happen when the client can't handle the codec, or when you force a lower
bitrate — and on a tailnet, where the "remote" clients are on the same LAN or
a Tailscale link, forcing a lower bitrate is rarely necessary.

**After `./enable-nvenc.sh` succeeds, one manual step remains**: Jellyfin does
not use the GPU until it is told to, in Dashboard → Playback → Transcoding →
hardware acceleration **NVIDIA NVENC**. Tick the codecs listed above, then
confirm a real transcode actually lands on the GPU — the `enc` column of
`nvidia-smi dmon -s u` should leave 0 while something is transcoding, and the
container log should mention `h264_nvenc`:

```bash
docker compose --project-directory ~/dev/setup-server/services/jellyfin logs jellyfin | grep -i nvenc
```

## ⚠️ The media directory is empty

`MEDIA_DIR` defaults to `~/services/jellyfin/media`, and **there is no media
library on this box**. On a first deploy that directory is created empty.

So the expected first-run state is: the server works, you can log in, and
Jellyfin shows **nothing**. That is not a bug and not a failed scan — there is
genuinely nothing to scan. `setup.sh` says so on the way out for this reason.

The mount is **read-only** (`:ro`). Jellyfin can read and index your files but
cannot rename, move or delete them, which is the correct posture for a media
server: the library is a view of your files, not their owner. The consequence
is that Jellyfin's "delete from disk" button and metadata-writeback (NFO/
poster files written next to the media) will fail. Fetched metadata lives in
`config/metadata/` instead, which is where you want it anyway.

**To point it at real media.** On a first deploy, pass it in:

```bash
MEDIA_DIR=/mnt/media ./setup.sh
```

Once `.env` exists, that env var is ignored with a warning — `.env` is the
source of truth, so a re-run cannot repoint a live library out from under
itself. Edit the file instead:

```bash
cd ~/dev/setup-server/services/jellyfin
sed -i 's|^MEDIA_DIR=.*|MEDIA_DIR=/mnt/media|' .env
./setup.sh
```

Then in the web UI: Dashboard → Libraries → **Add Media Library**, pick the
content type (Movies / Shows / Music — this drives which metadata scraper
runs), and add the folder **as the container sees it**, i.e. under `/media`,
not the host path. That is the single most common first-time mistake:

| Host path | Path to type into Jellyfin |
|---|---|
| `/mnt/media/movies` | `/media/movies` |
| `~/services/jellyfin/media/tv` | `/media/tv` |

Layout matters more than it does for other software, because the scrapers
match on paths. `Movies/Title (2019)/Title (2019).mkv` and
`Shows/Title/Season 01/Title - S01E02.mkv` are the shapes that just work.

For media on a second disk, mount it on the host and set `MEDIA_DIR` to that
mount point — do not add extra volumes by hand, they will not survive the
next `./setup.sh`.

## ⚠️ This box has no backup

Nothing on `homeserver` is backed up, and Jellyfin has two separately
irreplaceable things:

- **The media itself**, under `MEDIA_DIR`. If it lives only here, it is one
  disk failure from gone. Jellyfin is not a backup of your media — it is a
  reader of it.
- **`~/services/jellyfin/config`**, which holds watch state. Losing it does
  not lose a single video file, but it loses *which episode you were on*,
  every year, for everyone — the thing nobody thinks to back up and everybody
  misses.

The cheap cold backup of the small half:

```bash
cd ~/dev/setup-server/services/jellyfin
docker compose --project-directory . stop
tar czf ~/jellyfin-config-$(date +%F).tgz -C ~/services/jellyfin config
docker compose --project-directory . start
```

Then get the tarball **off this machine** — Seafile at `:8443` syncs to a
device that is not this one. Skip `cache/`; it regenerates. The media half
needs a real plan, not a tarball.

## Security model

- **Tailnet-only.** The container publishes `127.0.0.1:8096` and nothing
  else; Tailscale Serve terminates TLS. Not reachable from the LAN or the
  internet. No firewall rule opens it, and none should. This matters more for
  Jellyfin than for most services here: media servers are routinely
  port-forwarded to the internet, and Jellyfin's own docs assume you might.
  Do not.
- **UPnP is switched off in the wizard.** `/Startup/RemoteAccess` is POSTed
  with `{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}`.
  The first flag is what lets any client that is not on the box itself
  connect — the tailnet clients are "remote" as far as Jellyfin is concerned,
  so turning it off would break every device you own. The second is the sharp
  one: left on, Jellyfin asks the router to punch a hole to port 8096 **from
  the internet**, silently undoing the entire tailnet boundary. Off is the
  only correct setting here, and the mocked suite asserts it explicitly.
- **The admin account is created by `setup.sh`**, through the startup wizard,
  before anyone can reach the instance. There is no window in which someone
  else on the tailnet loads the page and claims the admin slot.
- **The wizard is a one-time window, and it is closed on the way out.** Until
  `/Startup/Complete` is POSTed, `/Startup/*` accepts unauthenticated writes
  from anyone who can reach the port — including "create the first user".
  A deploy that leaves the wizard half-finished is a deploy anyone on the
  tailnet can take over, which is why the live suite asserts
  `StartupWizardCompleted == true` rather than merely that the page loads.
- **Secrets** are generated into the gitignored `.env` (mode 600):
  `JELLYFIN_ADMIN_PASSWORD`. It is never overwritten on a re-run.
- **The media mount is read-only.** Even a full compromise of the container
  cannot delete your files through it.

⚠️ Same password-sync rule as every other service here: if you change the
admin password in the web UI, mirror it into `.env`. `setup.sh` finishes by
authenticating with the `.env` copy and **fails the deploy** if that is
rejected, rather than reporting success over an account you cannot log into.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | systemd/launchd not used — Docker's restart policy handles boot | ✅ |
| Docker + Compose v2 | the one container | ✅ (incl. daemon reachability) |
| curl | readiness polling, the wizard POSTs, the auth verification | ✅ |
| Tailscale, logged in, MagicDNS | publishing | ✅ (`BackendState` must be `Running`) |
| python3 | password generation — optional, falls back to `/dev/urandom` | — |
| Disk for `cache/` | transcode scratch; a 4K transcode can write GBs | ⚠️ warns |
| **NOT** an NVIDIA runtime | hardware transcoding is out of scope — see above | — |

No database server, no Redis, no reverse proxy of our own.

## Deploy

```bash
cd services/jellyfin && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, `curl`, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports.
2. **Resolve the tailnet name** from `tailscale status --json`. Unlike
   Forgejo, Jellyfin does not need this baked into config — it builds URLs
   relative to the request — so it is used only for the serve mapping and the
   final message.
3. **`.env`** — written only if absent, mode 600:
   `JELLYFIN_VERSION=12.0`, `LOCAL_PORT`, `TZ` (from
   `readlink /etc/localtime`), `JELLYFIN_CONFIG`, `JELLYFIN_CACHE`,
   `MEDIA_DIR`, `JELLYFIN_UID`/`GID`, `JELLYFIN_PUBLISHED_URL`,
   `JELLYFIN_ADMIN_USERNAME` and a generated `JELLYFIN_ADMIN_PASSWORD`
   (32 hex chars — deliberately `[a-f0-9]` so it survives `.env`, shell
   quoting, a JSON body and a TV remote's on-screen keyboard unescaped).
   On a re-run `.env` is the source of truth: it is never rewritten, and a
   `LOCAL_PORT=` on the command line that disagrees with it is ignored with a
   warning rather than silently moving a live deployment.
   The admin username is validated in preflight — `[A-Za-z0-9._-]` only,
   because it goes into a JSON body unescaped.
4. **Create the state dirs** — `config/`, `cache/`, `media/` under
   `~/services/jellyfin`, check they are writable/readable by the uid the
   container will run as, warn if there is under 50 GB free where the media
   goes, then `docker compose up -d` (first run pulls ~500 MB).
5. **Wait for readiness the *right* way** — poll `GET /Startup/FirstUser`
   until it stops returning 503. Not `/System/Info/Public`; see "The
   readiness trap" above. This is the step that makes the difference between
   a working deploy and a wizard with no admin in it.
6. **Run the wizard**, four POSTs in order, each expecting **204**:
   `/Startup/Configuration` (UI culture `en-US`, metadata country `SG`,
   language `en` — override with `JELLYFIN_UI_CULTURE`,
   `JELLYFIN_METADATA_COUNTRY`, `JELLYFIN_METADATA_LANGUAGE`) →
   `/Startup/User` (the admin account) → `/Startup/RemoteAccess` (UPnP
   **off**) → `/Startup/Complete`, then it re-reads
   `StartupWizardCompleted` to confirm the flag actually flipped.

   Two independent guards keep this to at most once: the
   `~/services/jellyfin/.wizard-complete` marker means a normal re-run does
   not touch the wizard at all, and if the marker is missing but the live
   server already reports `StartupWizardCompleted: true`, the wizard is
   skipped and the marker rewritten. (A run that died between finishing the
   wizard and writing the marker recovers cleanly.)
7. **`tailscale serve --bg --https=8096 http://127.0.0.1:8096`**, with the
   operator-grant (`sudo tailscale set --operator=$USER`, first run only) and
   approval-link fallbacks.
8. **Verify over HTTPS** — first `GET /System/Info/Public` on the tailnet URL
   (a warning, not a failure, while the cert is still minting), checking that
   the `LocalAddress` it reports is the address clients will be handed; then
   `POST /Users/AuthenticateByName` with the `.env` credentials and the
   `MediaBrowser` authorization header, requiring 200 and `IsAdministrator`.
   **That one is fatal.** Then it prints the URL, the credentials, the client
   list, and the reminder that the media directory is empty.

## Client side

The tailnet is the boundary: a client is anything on the tailnet with a
Jellyfin app. **The phone, TV or laptop must be on the tailnet** — install
Tailscale on it and log in first. There is no other way in, deliberately.

### Which app

| Platform | App | Notes |
|---|---|---|
| Any browser | just the URL | Full-featured; the admin dashboard is browser-only |
| Android / iOS | **Jellyfin** (official) | Needs the Tailscale app running |
| Android TV / Fire TV | **Jellyfin for Android TV** | Tailscale runs on Android TV too |
| Apple TV | **Swiftfin** (official) or **Infuse** | Infuse is paid, plays more formats natively |
| Desktop | **Jellyfin Media Player** | mpv-based; better format support than the browser |
| Kodi | **Jellyfin for Kodi** | Add-on, syncs the library into Kodi |

Roku and older smart TVs are the weak spot — Jellyfin's Roku client is
community-maintained and Tailscale does not run on Roku at all, so a Roku on
this setup needs a subnet router. Plan around it rather than fighting it.

### Adding the server

Every client asks for a server address on first launch. Give it the full
tailnet URL **including the port**:

```
https://homeserver.tail-name.ts.net:8096
```

Then the username and the password from `.env`. Common failures:

- **Leaving off `:8096`** — the client tries 443, which is code-server, and
  reports a confusing error rather than "wrong port".
- **Using `http://`** — Serve is HTTPS-only; the port will not answer plain
  HTTP.
- **Tailscale not connected on the client** — the name will not resolve at
  all. Check the Tailscale app is showing "Connected" first.
- **"Server not found" on a TV that was working** — the TV dropped off the
  tailnet, usually after a reboot; the Tailscale Android TV app does not
  always restart itself.

The tailnet IP `100.77.77.77:8096` works identically if MagicDNS is off, and
is a useful thing to try when a client cannot resolve the name.

### Adding your media

See "The media directory is empty" above — the short version is that library
paths are typed as the **container** sees them (`/media/...`), and that
`MEDIA_DIR` in `.env` is what decides which host directory that is.

### Users

One admin account exists. Add family members from Dashboard → Users → **+**,
and give them their own account rather than sharing yours — watch state is
per-user, which is the entire point. For a kid's account, set Parental
Control → maximum allowed rating on the user, and untick the libraries they
should not see.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f jellyfin`
  (also in the UI: Dashboard → Logs)
- Restart: `docker compose --project-directory . restart`
- Upgrade: bump `JELLYFIN_VERSION` in `.env`, then
  `docker compose --project-directory . pull && ./setup.sh`.
  ⚠️ Read the release notes first — 12.x runs schema migrations, and there is
  no downgrade. Take the config tarball above before any version bump.
- What version is actually running:
  `curl -s http://127.0.0.1:8096/System/Info/Public` → `.Version`
- Is the wizard really finished:
  `curl -s http://127.0.0.1:8096/System/Info/Public` →
  `.StartupWizardCompleted` must be `true`
- Reset a forgotten password: Dashboard → Users → the user → **Reset
  Password**, then mirror it into `.env`. There is no CLI for this — see
  TROUBLESHOOT.md for the locked-out-completely case.
- Rescan the library: Dashboard → Libraries → **Scan All Libraries**
- Reclaim space: `rm -rf ~/services/jellyfin/cache/*` with the container
  stopped (image and subtitle caches — nothing there is precious). In-flight
  transcode segments live under `config/transcodes/` instead and are cleaned
  up by Dashboard → Scheduled Tasks → **Clean Transcode Directory**.
- Disk usage: `du -sh ~/services/jellyfin/*`
- Remove: `./teardown.sh` (or Remove in the launcher) unpublishes the Serve
  port(s) that point here and runs `compose down` (with the GPU overlay when
  NVENC is on); config, cache, media and `.env` stay, so `./setup.sh` brings
  it back. `./teardown.sh --purge` also deletes `JELLYFIN_CONFIG`,
  `JELLYFIN_CACHE`, the wizard marker and `.env`, after you type `jellyfin`.
  It never deletes `MEDIA_DIR`, even inside `~/services/jellyfin`.
- What is transcoding right now: Dashboard → **Activity**. A session showing
  "Transcode" instead of "Direct Play" is the CPU cost described above.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

**167 mocked checks**, all green, in about four seconds. The suite runs the
real `setup.sh` against a sandboxed `$HOME` with PATH stubs for `docker`,
`tailscale`, `curl`, `sudo`, `id` and `sleep`. The `curl` stub fakes the whole
Jellyfin surface: `/System/Info/Public` (including whether
`StartupWizardCompleted` has flipped, and echoing `PublishedServerUrl` back
as `LocalAddress`), the four `/Startup/*` wizard steps — recording their
order **and their JSON bodies** — `/Users/Public` returning `[]` the way the
real server does, and `/Users/AuthenticateByName`.

Covered: preflight failures (root, docker unreachable, Tailscale down,
non-numeric ports, an admin username that would break the JSON body); a fresh
deploy driving all four wizard steps in the right order with the generated
password in the `/Startup/User` body and UPnP off in the `/Startup/RemoteAccess`
body; **the readiness race** — the stub refuses the connection twice and then
503s the next four `/Startup/*` calls, and the test asserts the script polled
seven times, slept between polls, and POSTed no wizard step during the
window; a server that never finishes loading (dies before touching the wizard
or publishing anything); a wizard step failing, a step 503ing mid-wizard, and
all four steps succeeding while the flag never flips; idempotent re-run with
the wizard skipped; recovery when the marker is lost but the server is
already set up; a **stale marker over a wiped config** (caught at the marker
and named, rather than misdiagnosed three steps later as a bad password); a
password changed in the UI and an account that is not an admin, both fatal;
port and `MEDIA_DIR` overrides honoured fresh and ignored on a re-run;
`JELLYFIN_PUBLISHED_URL` drift; the empty-vs-populated media directory; the
exact `tailscale serve` invocation; operator escalation and the
serve-approval prompt. Plus static assertions that the compose file binds
loopback only, mounts the media read-only, publishes no DLNA ports, does not
use `network_mode: host`, and keeps the NVENC block commented out.

`sleep` is stubbed for a reason worth knowing: the readiness loop is 90
attempts × 2 s, so without it the "never finishes loading" case would sit
there for three real minutes. The stub's log line is also what proves the
script *polls* rather than spinning on `curl`.

The live suite adds **10 checks** against the real deployment: the container
is running, local `/System/Info/Public` answers, the port is listening on
nothing but loopback and Tailscale's own tailnet address, the serve mapping
exists, the tailnet HTTPS URL answers, the media directory exists, and the
running version is on the pinned 12.x line.

Three of those are the ones a green-looking deploy still gets wrong, and they
are the reason the suite exists:

- **`StartupWizardCompleted` is really `true`** — an unfinished wizard leaves
  `/Startup/*` open to anyone on the tailnet.
- **The credentials in `.env` really do authenticate, with administrator
  rights** — this is what catches the readiness race. A wizard whose
  `/Startup/User` call was swallowed by a 503 passes every other check and
  fails here.
- **The server advertises the tailnet URL to clients** (`LocalAddress` on
  `/System/Info/Public`) — wrong, and playback fails on every device except
  this box.

If `docker` is unreachable the live suite says so and stops, rather than
reporting a healthy stack as down: re-run it as
`sg docker -c './tests/run-tests.sh --live'`.

## Notes

- Port 8096 is Jellyfin's default, and the HTTPS port matches the local port,
  following the newer convention in this repo. That overlap is why the live
  suite's `no_external_listener` check has to allow Tailscale's own tailnet
  listener on the same number.
- The DLNA server is off. It broadcasts on the LAN, which is precisely the
  boundary this deploy exists to hold, and it would also be the one part of
  the service reachable without Tailscale.
- No plugins are installed, and on 12.0 none would load anyway. If you find
  yourself wanting one badly enough to matter, that is the argument for
  reconsidering the version choice — while the library is still empty.
- `cache/` is a separate mount on purpose. Keeping transcode scratch out of
  `config/` means the backup tarball above stays small and the "reclaim
  space" step is a single `rm -rf` that cannot touch anything important.
