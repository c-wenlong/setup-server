# homepage — a config-file service dashboard (gethomepage.dev)

One page listing every service on this box, with a live status dot next to
each, a header strip of CPU/RAM/disk/uptime, and a bookmarks block. The whole
thing is four YAML files you edit by hand; there is no admin UI and no
database. Editing the YAML **is** the product.

- **URL:** `https://kai-home-server.taild6a23f.ts.net:8100` (tailnet only)
- **Local port:** `127.0.0.1:8100`
- **Config:** `~/services/homepage/config/*.yaml` — yours, hand-edited, never
  overwritten by a re-run
- **Auth:** none. Homepage has no login of its own, the same as code-server.
  The tailnet is the entire access-control layer.

> ### ⚠️ The one setting that breaks this service silently
>
> Homepage v1.4.5 checks the HTTP `Host` header of every `/api/*` request
> against `HOMEPAGE_ALLOWED_HOSTS` and answers **HTTP 400** if it is not on
> the list. `tailscale serve` forwards the Host verbatim, **including the
> port**, so `kai-home-server.taild6a23f.ts.net:8100` has to be in that list
> literally.
>
> When it is wrong, **`GET /` still returns HTTP 200 with a byte-identical
> HTML page** — measured with `cmp`, 44801 bytes either way. `/` is a
> build-time static shell that does not reflect your config at all; every real
> value arrives later from `/api/*`. So the dashboard loads looking almost
> right and then has no status dots, no widgets and no service list.
>
> This is why nothing in this service verifies with a status code, and why
> even "assert real Homepage markup on `/`" is not enough. The check that
> works is `GET /api/services` **with the tailnet Host header**. See
> [Host validation](#host-validation-the-failure-that-returns-200).

> ### ⚠️ This box already has a dashboard
>
> The [launcher](../launcher/) at `https://…/home/` and `:8093` covers
> overlapping ground and can do things Homepage cannot (deploy, start, stop).
> Homepage does not replace it and this deploy does not touch it. The two keep
> **separate service lists that will drift**. See
> [Overlap with the launcher](#overlap-with-the-launcher-read-this-before-you-edit-either).

## What this is

[Homepage](https://gethomepage.dev) is a Next.js app that reads YAML off disk
and renders a dashboard. This deploy pins **v1.4.5**.

What you get:

- **A tile per service**, with an icon, a description, and the tailnet URL it
  opens.
- **Status dots that mean something.** Each tile can carry a `siteMonitor:`
  URL that Homepage fetches itself, over loopback, and reports the HTTP status
  of. `http://127.0.0.1:2283/api/server/ping` is a real question about Immich,
  not "is a container named immich_server running".
- **Info widgets** in the header — CPU, memory, disk, uptime, clock. These
  read `/proc` from inside a host-namespace container, so they are the host's
  real numbers.
- **A large widget ecosystem** (~100 service integrations: Immich's photo
  count, Jellyfin's now-playing, AdGuard's block rate, …). Most need an API
  key from the service in question. None are enabled here; see
  [Widgets](#widgets-and-why-none-are-turned-on).

What it is not:

- **Not a control panel.** Nothing on this page can start, stop, deploy or
  restart anything. Homepage's only write-capable integration is the Docker
  socket, which is deliberately not mounted — see
  [Security model](#security-model).
- **Not a monitor.** It shows the status *right now*, when you happen to be
  looking. Uptime Kuma (`:3002`) is the thing that probes every 60s and pages
  the phone; beszel (`:8092`) is the thing that keeps history. Homepage is a
  home page.
- **Not auto-discovering.** The service list is a file you maintain. It does
  not read `launcher/services.json`, `docker ps` or Kuma.

## Architecture

```
   browser on the tailnet
         │
         │  https://kai-home-server.taild6a23f.ts.net:8100
         ▼
   tailscaled  (Tailscale Serve, TLS)      ← binds the tailnet IP on :8100
         │
         │  http://127.0.0.1:8100
         │  Host: kai-home-server.taild6a23f.ts.net:8100   ← forwarded VERBATIM
         ▼
   ┌───────────────────────────────────────────────────────────┐
   │ container: homepage                                       │
   │   ghcr.io/gethomepage/homepage:v1.4.5                     │
   │   network_mode: host                                      │
   │   HOSTNAME=127.0.0.1  PORT=8100   ← binds loopback ONLY   │
   │                                                           │
   │   Next.js middleware on /api/:path*                       │
   │     Host ∈ HOMEPAGE_ALLOWED_HOSTS ?  serve  :  400        │
   └───────┬──────────────────────────────┬────────────────────┘
           │ bind mount                   │ siteMonitor probes, over the
           ▼                              │ HOST's own loopback
   ~/services/homepage/config/            ▼
     services.yaml                  127.0.0.1:2283  immich
     settings.yaml                  127.0.0.1:8081  seafile
     widgets.yaml                   127.0.0.1:8222  vaultwarden
     bookmarks.yaml                 127.0.0.1:8080  code-server
     logs/homepage.log              …and every other service on this box
```

### Why host networking, and why that is still loopback-only

This is the one structurally unusual thing here, and it is not a shortcut.

Every service on this box binds `127.0.0.1` only. From a **bridge**-network
container, `127.0.0.1` is the container itself, the bridge gateway is refused
for the same reason, and MagicDNS names come back NXDOMAIN because Docker
hands the container the router's resolver instead of Tailscale's. A bridged
Homepage therefore cannot reach a single service it is meant to be watching:
every tile is a dead link with no status.

`network_mode: host` puts it in the host's namespace, where
`siteMonitor: http://127.0.0.1:<port>/` reaches all of them.

The trade is that there is no longer a Docker port-publish spec doing the
loopback confinement. **`HOSTNAME=127.0.0.1` in `docker-compose.yml` is the
only thing keeping the dashboard off the LAN.** The image ships
`HOSTNAME=0.0.0.0`; Next.js binds whatever that says. Measured: with
`HOSTNAME=127.0.0.1`, a request to the container's own bridge IP is refused
(curl exit 7) while loopback inside answers — the setting genuinely confines
the socket. Change it and you publish this to every device on the LAN, with no
password in front of it.

`setup.sh` re-checks the actual listeners after every deploy rather than
trusting the file, and `tests/run-tests.sh --live` asserts it independently.
The tailnet IP legitimately appears on `:8100` as well — that listener is
tailscaled's Serve proxy, not Homepage.

Same pattern as open-webui and n8n on this box.

## Host validation: the failure that returns 200

Read this once and you will never lose an afternoon to it.

`HOMEPAGE_ALLOWED_HOSTS` is a comma-separated exact-match list. v1.4.5 runs a
Next.js middleware matched on `/api/:path*` that compares the request's `Host`
header to it. Measured against the shipped image:

| Request | Host on the list | Host not on the list |
|---|---|---|
| `GET /` | 200, 44801 bytes | **200, 44801 bytes — `cmp`-identical** |
| `GET /api/services` | 200, the real service list | 400 `{"error":"Host validation failed…"}` |
| `GET /api/widgets` | 200 | 400 |
| `GET /api/healthcheck` | 200 `up` | 400 |
| `GET /api/config/custom.css` | 200 | 400 |

The middleware's matcher is `/api/:path*`, so `/` is never validated. And `/`
is not merely "200 either way" — it is a **build-time static shell**. Measured
against a correctly configured install with four real groups: the served HTML
contains **zero** occurrences of `Daily`, `Infrastructure`, `Immich` or
`kai-home-server`, and still contains the upstream `My First Service`
placeholder, baked into `__NEXT_DATA__.fallback` at image build time. SWR
replaces it client-side from `/api/*`. The bytes are identical whatever the
Host header **and** whatever is in `services.yaml`.

Consequences worth internalising:

- A `%{http_code}` check on `/` passes against a completely broken dashboard.
- A **markup** check on `/` also passes against a completely broken dashboard.
- Conversely, "the page must not contain `My First Service`" and "the page
  must contain a real group name" both **fail against a perfectly good
  deployment**. Do not write either assertion.
- `<title>` stays the literal `Homepage`; `title:` in `settings.yaml` does not
  change it. Do not assert on it. `setup.sh` matches `homepage.ico` on `/`
  instead, purely as a "some Homepage container answered here" check.
- Uptime Kuma pointed at `/` would report this service as UP, forever, while
  it is unusable. (The Kuma monitor for this service should hit
  `/api/healthcheck` — but note that endpoint is also host-validated, so the
  monitor's own Host has to be on the list. See
  [Adding another way in](#adding-another-way-in).)

The list this deploy writes:

```
HOMEPAGE_ALLOWED_HOSTS=kai-home-server.taild6a23f.ts.net:8100,kai-home-server.taild6a23f.ts.net,127.0.0.1:8100,localhost:8100
```

Four entries, each earning its place: the tailnet name **with** the Serve
port (what a browser sends), the bare tailnet name (so moving Serve to `:443`,
where the Host carries no port, keeps working), and the two loopback forms
that `setup.sh`, the tests and any local `curl` use.

**Do not "fix" a 400 by setting the list to `*`.** Measured: a single `*`
disables the check entirely and every Host is accepted. The check exists to
stop a page in your browser from resolving an attacker-controlled name to
`127.0.0.1` and driving this dashboard's API — DNS rebinding. `setup.sh`
tolerates a `*` in the list (it is your file) but the `.env` comment says not
to, and it is the wrong answer to a problem whose right answer is one exact
string.

## Security model

- **Bound to `127.0.0.1:8100` only**, enforced by `HOSTNAME=127.0.0.1` rather
  than by a Docker publish spec (see above). Verified after every deploy and
  by the live test suite.
- **Published tailnet-only** via `tailscale serve --https=8100`. No firewall
  port is opened; nothing listens on the LAN.
- **No authentication of its own.** Homepage has no users, no sessions and no
  password. Anyone who can reach the URL sees the dashboard. On a tailnet with
  one owner that is the same posture as code-server, and it is deliberate —
  but it is why the next bullet is not negotiable.
- **The Docker socket is NOT mounted.** Commented out in
  `docker-compose.yml`, asserted absent by `setup.sh` and by the tests.

  Mounting `/var/run/docker.sock` would give a web-facing Node app with **no
  authentication of its own** root-equivalent control of this machine:
  anything that can reach that socket can start a privileged container and
  read or write the entire filesystem — `/home`, every service's `.env`, the
  Vaultwarden database. `:ro` does not help; the socket is an HTTP API and the
  dangerous calls are POSTs that a read-only file descriptor carries happily.

  What you would be buying is container-level status and per-tile CPU/RAM.
  `siteMonitor` already answers a *better* question — "is this service
  actually responding?" rather than "is a container running?" — and needs no
  privilege at all. If you ever do want it, put
  `tecnativa/docker-socket-proxy` with `CONTAINERS=1` and nothing else in
  between; do not hand over the raw socket.
- **Host validation on**, exact-match, never `*` (above).
- **Config files are yours, not root's.** `PUID`/`PGID` are set from `id -u`
  and `id -g` and the container's entrypoint chowns `/app/config` on the way
  down from root. Measured: the YAML lands owned by you and is editable without
  sudo. This matters more here than elsewhere, because editing these files by
  hand is the entire point of the service.

  One wart worth knowing: if `setup.sh` is run as `sg docker -c ./setup.sh`
  (the usual fix for a shell that predates the docker group), `id -g` reports
  **the docker group**, not yours — so `HOMEPAGE_GID` ends up `124` and the
  files land `kaichen:docker`. That is exactly what happened on this box. It is
  harmless — you still own every file and can edit it — but do not "correct"
  `HOMEPAGE_GID` to `1000` unless you intend the chown that follows.
- **`mem_limit: 512m`.** Idle is ~112 MB; the cap is a hard stop so a leak in
  the dashboard cannot push this box (7.7 GB, already using swap) into
  swapping the services it is supposed to be watching.
- **Outbound requests.** Two, both avoidable:
  - Tile **icons** come from the dashboard-icons CDN and are fetched by *your
    browser*, not by this box. Replace `icon:` with a bundled `mdi-…` name to
    stop it.
  - The footer **version badge** makes this box call `api.github.com` on every
    load. `hideVersion: true` in `settings.yaml` turns it off, and it is off.

## Dependencies

| Needs | Why | Checked by |
|---|---|---|
| Linux (or macOS, degraded) | `network_mode: host` only shares the real loopback on Linux | `setup.sh` preflight warns on Darwin |
| Docker + Compose v2 | the container | preflight, and `docker ps` for daemon reachability |
| Tailscale, logged in, MagicDNS on | the tailnet name goes into `HOMEPAGE_ALLOWED_HOSTS`; without it every tailnet API call 400s | preflight dies if `DNSName` is empty |
| `curl` | readiness and verification | preflight |
| Port 8100 free | host networking, so nothing arbitrates the conflict for you | `ss -ltnp \| grep :8100` |

**macOS is untested and partly broken by design.** Docker Desktop runs
containers in a Linux VM, so `network_mode: host` shares the *VM's* loopback,
not the Mac's: every `siteMonitor` probe fails and the listener does not appear
on the Mac at all. `setup.sh` warns loudly and tells you to switch to a bridge
network with `ports: 127.0.0.1:8100:3000` and tailnet URLs for the probes.

## Deploy

```bash
cd ~/dev/setup-server/homepage
./setup.sh
```

Options, first run only (`.env` wins afterwards):

```bash
LOCAL_PORT=8100 HTTPS_PORT=8100 ./setup.sh
```

What it does, in order:

1. **Preflight** — OS, not-root, `curl`, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports, the `config/` templates present. Reads
   the MagicDNS name and **dies if it is empty**, because that name is what
   goes into the allowlist.
2. **`.env`** — written mode 600 if absent, **never rewritten**. Holds
   `HOMEPAGE_VERSION`, `LOCAL_PORT`, `TZ`, `HOMEPAGE_CONFIG`,
   `HOMEPAGE_UID`/`GID`, `HOMEPAGE_ALLOWED_HOSTS`, `HOMEPAGE_MEM_LIMIT`. On a
   re-run it is read back and **it wins** — a `LOCAL_PORT=` on the command
   line is reported as ignored rather than silently moving a live deployment.
3. **Allowlist drift check** — warns (does not rewrite) if
   `HOMEPAGE_ALLOWED_HOSTS` no longer contains `<tailnet-name>:<https-port>`.
   This is the failure that returns 200, so it gets named out loud.
4. **Seed config** — for each template in `homepage/config/`, copy it to
   `~/services/homepage/config/` **only if that file does not already exist**,
   substituting `__TS_HOST__` for the MagicDNS name. Files you have edited are
   counted and left alone. This must happen *before* the container starts:
   Homepage writes its own upstream default for any file missing when the API
   first asks for it, and that placeholder would win the race.
5. **Pull and `up -d`.**
6. **Readiness** — polls `GET /api/healthcheck` on loopback for up to 60s,
   riding out the connection refusals of a cold start (curl exit 7 / HTTP
   `000`, not a tidy 503). A `400` here is called out specifically as the
   allowlist missing `127.0.0.1:8100`.
7. **Publish** — `tailscale serve --bg --https=8100 http://127.0.0.1:8100`,
   with the operator-grant and approval-link retries every service here uses.
8. **Verify**, seven checks: container running; real Homepage markup on `/`;
   `/api/services` on loopback returns a **non-empty** list; **`/api/services`
   over the tailnet URL with the real Host header** (the one that matters);
   no `Host validation failed` lines in the container log; nothing listening
   off loopback/tailnet on `:8100`; the Docker socket is not mounted.

Re-running is safe: it upgrades the image, repairs the Serve mapping, leaves
`.env` and every config file you have touched exactly as they are.

## Editing the config — this is the product

Five files seeded into `~/services/homepage/config/` from
[`homepage/config/`](config/) in this repo — `services.yaml`, `settings.yaml`,
`widgets.yaml`, `bookmarks.yaml` and `docker.yaml` (that last one deliberately
empty; it exists only to explain why the Docker socket is not mounted).
Homepage adds `kubernetes.yaml`, `custom.css`, `custom.js` and `logs/` itself.

Homepage **re-reads the YAML per API request**, so save the file and reload the
page; there is no restart and no rebuild. The seeded versions ship with
comments explaining each field.

```bash
cd ~/services/homepage/config
$EDITOR services.yaml     # then just reload the browser tab
```

If a file goes missing, Homepage writes the upstream default back — so
`rm settings.yaml` is a reset button, not a way to delete a feature.

### `services.yaml` — the tiles

The shape is: a list of groups, each group a list of services.

```yaml
- Daily:                                    # group name — must match settings.yaml
    - Immich:                               # tile title
        icon: immich.png                    # dashboard-icons name, or mdi-<name>
        href: https://kai-home-server.taild6a23f.ts.net:2283/
        description: Photos — timeline, albums, phone backup
        siteMonitor: http://127.0.0.1:2283/api/server/ping
```

- **`href`** is where the tile takes you: always the **tailnet HTTPS URL**,
  because that is what your phone and laptop can reach.
- **`siteMonitor`** is what Homepage fetches to colour the status dot: always
  a **`http://127.0.0.1:<local-port>` URL**, because Homepage is in the host
  namespace and every service on this box binds loopback. Redirects are
  followed (measured: a 302 root shows as 200), so a plain `/` works when a
  service has no health path. Prefer a real health endpoint where one exists —
  `launcher/services.json` already has the researched ones.
- **`icon`** — bare names like `immich.png` come from the dashboard-icons CDN
  and are fetched **by your browser**. `mdi-video-outline` and friends are
  bundled locally. Paperclip, OpenHands and Trigger.dev are not in that set,
  so those three tiles use a full URL (selfh.st / the Trigger.dev brand kit).
  A missing icon renders as a letter tile, not an error.
- **A tile showing an error status is often correct.** Several services here
  are start-on-demand. Homepage is reporting, not complaining.

To add a service: copy an existing block, change the four fields, save,
reload. To reorder groups, see `layout:` below. To remove a tile, delete its
block — nothing else references it.

### `settings.yaml` — title, layout, theme

```yaml
title: kai-home-server
layout:
  Daily:                      # keys MUST match the group names in services.yaml
    style: row
    columns: 4
headerStyle: boxed
statusStyle: dot
hideVersion: true             # keep this: the badge calls api.github.com per load
theme: dark
color: slate
```

The most common mistake is a `layout:` key that does not exactly match a group
name in `services.yaml` — a renamed group silently falls back to alphabetical
placement rather than erroring. If a group jumps to the wrong place after an
edit, compare the two spellings first.

### `widgets.yaml` — the header strip

Info widgets, not service widgets: `resources` (CPU/memory/disk/uptime, real
host numbers thanks to host networking), `datetime`, optionally `search` and
`weather`. The weather widget needs an API key and your coordinates and phones
out on every page load; it is deliberately absent. So is the search widget,
which types into DuckDuckGo.

### `bookmarks.yaml` — plain links

No status probing, no fetching. Useful for the Tailscale admin console, the
repo, the Homepage docs, and the dashboard-icons index.

### Widgets, and why none are turned on

Beyond the header strip, Homepage can put a *service* widget inside a tile —
Immich's photo and user counts, Jellyfin's now-playing, AdGuard's queries and
block percentage, Uptime Kuma's up/down totals. They look like this:

```yaml
    - Immich:
        href: https://…:2283/
        widget:
          type: immich
          url: http://127.0.0.1:2283
          key: {{HOMEPAGE_VAR_IMMICH_KEY}}
```

**Almost every one needs an API key or admin credentials for the service it
is reading**, and that key ends up readable by a dashboard with no login of
its own. None are enabled here. If you add one, put the secret in
`~/services/homepage/config/.env` (Homepage's own env file, read as
`{{HOMEPAGE_VAR_…}}`) rather than inline in `services.yaml`, and use a
read-only or scoped key where the service offers one. A widget whose key is
wrong renders as an error box inside the tile and does not break the rest of
the page — see TROUBLESHOOT.md.

## Overlap with the launcher — read this before you edit either

This box already had a dashboard before Homepage: [`launcher/`](../launcher/),
at `https://kai-home-server.taild6a23f.ts.net/home/` and `:8093`, a
stdlib-only Python service driven by `launcher/services.json`. Kai asked for
both. They genuinely overlap, and pretending otherwise would make the next
person delete the wrong one.

| | launcher (`/home/`, `:8093`) | Homepage (`:8100`) |
|---|---|---|
| Service list lives in | `launcher/services.json` (in git) | `~/services/homepage/config/services.yaml` (not in git) |
| Live status | yes, loopback health probes | yes, loopback `siteMonitor` probes |
| **Start / stop a service** | **yes**, allowlisted, from the phone | no |
| **Deploy a service that isn't installed** | **yes**, runs its `setup.sh` and streams the log | no |
| Knows about *not-yet-installed* services | yes — dimmed tiles with a ↓ | no, only what you typed in |
| Kuma integration | yes, pauses/resumes monitors around a stop | no |
| Widgets / metrics | deliberately none | ~100 service integrations, header info strip |
| Bookmarks, layout, theming | none | yes, that is most of what it does |
| Dependencies | Python 3 stdlib, no Docker | a Docker container, Next.js, ~112 MB |
| Survives Docker being broken | yes | no |

**What each is better at.** The launcher is the *control plane* and the thing
to reach for when something is broken — no Docker, no dependencies, and it can
actually restart the thing you are looking at. Homepage is the *view*: it is
prettier, it has bookmarks and a header strip, its config is a file you can
diff, and it has a widget ecosystem the launcher will never grow. If you put
one on the phone's home screen, the launcher's short `/home/` URL is still the
better bookmark, because it is the one that can fix things.

**The honest cost: the service list now lives in two places and will drift.**
`homepage/config/services.yaml` was seeded *from* `launcher/services.json`, but
nothing keeps them in step. Add a service and you must edit both — plus
`DIRECTORY.md`, `README.md` and `monitoring/seed_kuma.py`, which was already
true. The symptom of drift is quiet: a tile that is missing from one dashboard
and present on the other, or a `siteMonitor` URL that still points at a port
the service moved off.

Two rules that keep it manageable:

- **`launcher/services.json` is upstream.** When they disagree, it is the one
  that has been kept current, because the deploy buttons on it stop working if
  it goes stale. Copy from it into `services.yaml`, not the other way.
- **A dead tile in Homepage is cosmetic; a dead entry in the launcher is a
  broken Deploy button.** Fix the launcher first.

Neither dashboard should be removed. If one ever is, it should be a decision
someone makes on purpose, not a cleanup — and this table is the argument.

## Ops

```bash
cd ~/dev/setup-server/homepage
docker compose --project-directory . ps
docker compose --project-directory . logs --tail=50 homepage
docker compose --project-directory . restart
docker compose --project-directory . down          # stop; config survives

# the two views of the log — YAML parse errors go ONLY to the second one
docker compose --project-directory . logs homepage
tail -20 ~/services/homepage/config/logs/homepage.log

# is it really working? (a 200 on / proves nothing — see Host validation)
curl -sS http://127.0.0.1:8100/api/services | head -c 200
curl -sS https://kai-home-server.taild6a23f.ts.net:8100/api/services | head -c 200

tailscale serve status | grep -A2 ':8100'
./tests/run-tests.sh            # mocked, no side effects
./tests/run-tests.sh --live     # verify this box's real deployment
```

Upgrade:

```bash
$EDITOR .env                    # bump HOMEPAGE_VERSION
docker compose --project-directory . pull && ./setup.sh
```

Re-read the allowlist notes in `docker-compose.yml` before a major bump — the
host-validation middleware is exactly where upstream changes bite, and it
already changed once (it did not exist before v1.x).

### Adding another way in

If you publish Homepage on a second port or path — say `--set-path=/dash` on
`:443` — the browser's `Host` becomes `kai-home-server.taild6a23f.ts.net`
(no port on 443) or whatever the new port is. **Add it to
`HOMEPAGE_ALLOWED_HOSTS` in `.env` and re-run `setup.sh`,** or every API call
through the new door 400s while `/` keeps returning 200. The bare hostname is
already on the list for exactly the `:443` case.

The same applies to a Uptime Kuma monitor: give it
`https://kai-home-server.taild6a23f.ts.net:8100/api/healthcheck` (a
host-validated endpoint whose Host is already allowlisted, and which returns
the literal body `up`) rather than `/`, or the monitor will be green against a
broken dashboard forever.

## Tests

```bash
./tests/run-tests.sh          # mocked: runs setup.sh in a temp sandbox
./tests/run-tests.sh --live   # asserts the real deployment on this box
```

The mocked suite runs the real `setup.sh` against PATH stubs with a temp
`$HOME`, and proves it changed nothing on the host with before/after
checksums. The live suite needs the docker group — `sg docker -c
'./tests/run-tests.sh --live'` if `docker ps` fails in your shell; it detects
that and says so rather than reporting a healthy container as down.

The live suite's headline assertion is the one described above: fetch
`/api/services` over **tailnet HTTPS**, with the real `Host` header, and
require a non-empty service list. Nothing weaker distinguishes a working
dashboard from a broken one.

## Notes

- `~/services/homepage/config/` is the only state. Back that directory up and
  you can rebuild this deploy anywhere; there is no database.
- The container is in the **host** network namespace, so `docker inspect` shows
  no port bindings and `docker ps` shows no `PORTS` column entry. That is
  expected, not a fault — `ss -ltnp | grep :8100` is where the listener is.
- Homepage writes `config/logs/homepage.log` itself. `docker logs` is capped at
  3 × 10 MB by the `logging:` block; the file is not, so it is worth a glance
  if the config directory ever grows unexpectedly.
