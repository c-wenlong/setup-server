# launcher — spec (first draft)

A single-page app launcher for kai-home-server: every service as a tile,
tap to open. Tiles for services that are **not deployed yet** are dimmed and
carry a Deploy action that runs that service's `setup.sh` on the box — so
this is both an index of what exists and the place you install from.

Explicitly NOT a stats dashboard. No graphs, no widgets, no per-service
metrics. Uptime Kuma and beszel already do that and are one tap away.

## Why it exists

Opening a service today means typing
`https://kai-home-server.taild6a23f.ts.net:2283` on a phone. This replaces
that with one bookmark.

## Design direction

Minimal, and deliberately unlike Kuma/ntfy. Reference points: Flame and
Heimdall for the launcher-first grid; the prevailing 2026 critique of
homelab dashboards is that they try to become control centres and drown the
one thing you actually want — a fast link. Resist that.

Rules:

- **Launcher first.** The grid is the entire product. One screen, no nav,
  no tabs, no settings page.
- **One accent colour** over a neutral grey type scale. No per-service
  brand colours, no gradients, no glassmorphism.
- **System font stack.** No webfonts (must work with no internet).
- **Type-to-filter**, focused on load for desktop, hidden behind the
  keyboard on mobile (do not autofocus on touch — it pops the keyboard).
- **Dark and light** via `prefers-color-scheme`. Both must look deliberate.
- Responsive grid: 2 columns at 360px → 3 at 600px → 4–6 at desktop.
  Tap targets ≥ 44px. Must feel native on an iPhone.

### Tile states (the part that matters)

Do **not** express state with opacity alone — dimming the whole tile fails
contrast on the label. Follow the iOS offloaded-app convention: dim the
*icon*, keep the label at full contrast, and add an explicit glyph.

| State | Condition | Look | Action on tap |
|---|---|---|---|
| `active` | health probe OK | full colour icon, green dot | opens `url` in a new tab |
| `stopped` | installed, health fails | full colour icon, amber dot | opens `url` anyway (+ hint it looks down) |
| `available` | `setup` exists, not installed | icon at 35% + ↓ glyph, label full contrast | opens the Deploy sheet |
| `planned` | no `setup` in repo | icon at 35% + dashed border, "planned" badge | nothing (not built yet) |

`ollama` has no web UI: `url` is null, so its tile shows status but never
navigates. Make that legible rather than looking broken.

## Architecture

```
Tailscale Serve ──▶ 127.0.0.1:8093  launcher (systemd user unit)
  :8093/         │                    ├── serves web/ (static, no build step)
  :443/home/     ┘                    ├── GET  api/services
                                      ├── POST api/services/{key}/deploy
                                      └── GET  api/jobs/{id}
```

Python 3 **standard library only** — no pip, no venv, no framework. This is
meant to be the first thing that comes up on the box and the thing you
reach for when something else is broken, so it must have no moving parts.

Published twice, both proxying the same backend:

- `https://<host>:8093/` — its own port, matching every other service here
- `https://<host>/home/` — a path handler on :443 alongside code-server,
  which keeps `/`. This is the short URL to bookmark.

**Verified contract:** `tailscale serve --set-path=/home` *strips* the
prefix before proxying — the backend sees `/` and `/app.css`. Therefore
every asset and API reference in the frontend MUST be relative
(`app.css`, `api/services`), never absolute (`/app.css`). One build has to
work at both URLs. This is the single easiest thing to get wrong.

## Service registry — `services.json`

`HOST` is substituted at runtime with the node's MagicDNS name (from
`tailscale status --json`), so nothing is hardcoded to one tailnet.

```json
{
  "key":     "immich",
  "name":    "Immich",
  "tagline": "Photos",
  "icon":    "camera",
  "url":     "https://HOST:2283/",
  "health":  "http://127.0.0.1:2283/api/server/ping",
  "marker":  "~/services/immich",
  "setup":   "immich/setup.sh"
}
```

- `url` — where the tile navigates. `null` for services with no web UI.
- `health` — loopback probe. Drives `active`. `null` ⇒ never active.
- `marker` — a path that exists once deployed (state dir or generated
  `.env`). Drives `installed` without needing Docker.
- `setup` — path to `setup.sh`, relative to the repo root. `null` ⇒
  `planned`.

**Status detection deliberately avoids the Docker CLI.** A systemd user
unit does not reliably inherit the `docker` group, and status must never
break because of that. `installed` = marker exists OR health responds;
`active` = health responds. Probes are loopback, 2s timeout, run
concurrently, and cached ~5s so a page refresh can't stampede.

### Registry contents

Deployed today — immich (Photos, 2283), seafile (Files, 8443, health
`http://127.0.0.1:8081/api2/ping/`), code-server (Code, :443, health
`http://127.0.0.1:8080/healthz`), open-webui (Chat, 10000, health :3001),
kaichenpedia (Wiki, 8091), n8n (Automation, 5678), beszel (Metrics, 8092),
uptime-kuma (Status, 3002), ntfy (Alerts, 3003), manimkc (Video, 8090),
ollama (Models, no URL, health :11434/api/version).

Planned, from EXPLORATION.md, `setup: null` — adguard (DNS), jellyfin
(Media), paperless-ngx (Documents), karakeep (Bookmarks), forgejo (Git).

## HTTP API

All paths relative to the mount point.

| Method | Path | Returns |
|---|---|---|
| GET | `api/services` | `{host, services:[{key,name,tagline,icon,url,state,installed,active}]}` |
| POST | `api/services/{key}/deploy` | `{job_id}`; `409` if one is already running for that key |
| GET | `api/jobs/{id}` | `{key,status:running\|done\|failed,exit_code,log}` |
| GET | `healthz` | `200 ok` — for the Kuma monitor |

Deploy runs `<repo>/<setup>` with cwd set to that service's directory,
output tee'd to `~/services/launcher/jobs/<id>.log`, and is polled by the
UI (~1s) rather than streamed — polling is simpler and survives a phone
locking its screen mid-deploy.

## Security

Tailnet-only, like everything here, and the backend binds `127.0.0.1`.

This endpoint executes shell scripts, so it is the most dangerous surface
on the box. Non-negotiable:

- `key` is looked up in the registry; anything not found is `404`. The
  script path comes from the registry, **never** from the request.
- Resolve the final path and assert it stays inside the repo (no `..`).
- `subprocess` with an argument list, `shell=False`. No string
  interpolation of any request data, anywhere.
- One concurrent job per key; a global cap of 2.
- The UI must require an explicit confirm before POSTing.

Precedent: `ntfy-control` already does allowlisted start/stop from the
phone. This follows the same allowlist-only shape.

## Repo conventions

Standard service layout — `setup.sh` (idempotent, non-root, preflight →
install → unit → publish → verify), `SETUP.md`, `TROUBLESHOOT.md`,
`tests/run-tests.sh` (mocked suite + `--live`). Long-running, so: systemd
**user** unit, `Restart=always`, `loginctl enable-linger`. Linux + macOS
(launchd) portability, no GNU-only flags.

## Out of scope for the first draft

Auth (tailnet is the boundary), editing the registry from the UI,
uninstall/stop actions, log history beyond the current job, PWA manifest,
reordering tiles.

---

# v2 — service detail pages

## Why

The tile grid answers "what exists and is it up". It cannot answer "what is
this, what is it configured with, and what was that password". That lives
scattered across DIRECTORY.md and nine `.env` files.

## Card interaction split

A tile becomes two targets side by side, not one:

- **Left — icon + name (+ tagline, status dot):** the link. Opens the
  service in a new tab. This is the shrunk hit area; it is deliberately no
  longer the whole card.
- **Right — blank space:** opens that service's detail page.

Both must be real, keyboard-reachable controls, and an `<a>` may not be
nested inside a `<button>` — use two siblings in a positioned container.
The right region needs an accessible name ("Details for Immich"); blank to
the eye is not blank to a screen reader.

`planned` tiles have no URL, so the whole tile opens details.

## Detail page

A hash route (`#/service/<key>`), so Back works and a page can be linked.
Not a modal-only affair.

Contents:
- Icon, name, status, and the URL as a real link.
- **Editable name and description**, saved back to the server.
- **Environment variables**, secrets masked, each with an eye toggle.
- Whatever `meta` is useful (setup script path, health URL, ports).

## Editing, and where edits live

Edits do NOT go into `services.json` — that file is tracked in git and is
the shipped default. They go to `~/services/launcher/overrides.json`, which
survives redeploys and keeps the repo clean. A service's effective name and
description are the registry values with the override layered on top.
Deleting the override file restores the shipped defaults.

## Secrets — read this before implementing

The reveal endpoint puts every secret on the box behind an HTTP endpoint:
database passwords, admin passwords, a JWT private key, and third-party API
keys (ElevenLabs, Sarvam). Anything on the tailnet can read them. That is a
real widening of exposure and is accepted deliberately, but it constrains
the design:

- Masked values are **never** sent in the list or detail payload. The
  detail response carries only names and a `secret` flag.
- Revealing is a separate, explicit **POST** per variable — not a GET, so
  it cannot be prefetched, link-previewed, or sit in browser history.
- Secret detection is by name: `PASS`, `SECRET`, `TOKEN`, `KEY`, `CRED`,
  `PRIVATE` (case-insensitive). When in doubt, treat it as a secret —
  over-masking is a nuisance, under-masking is a leak.
- The env file path comes from the registry only, is `realpath`'d, and must
  resolve inside the allowed roots — the same rule the deploy endpoint uses.
- Never write a revealed value to a log line.

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `api/services/{key}` | detail: identity, meta, env var names + `secret` flags (no values) |
| PATCH | `api/services/{key}` | `{name?, description?}` → persists to overrides.json |
| POST | `api/services/{key}/env/{var}/reveal` | `{value}` for one variable |

---

## v3 — view/sort controls, usage tracking, resource use (2026-09-12)

Requested: a dropdown to switch grid ↔ table, a dropdown for sort order
(default = last launched/opened; also deployed-date and RAM), and resource
use shown per service. Three agents build this against the contract below;
they do not need to talk to each other if they honour it exactly.

### Definitions

- **launched** — the user clicked the tile's icon/title (the `<a
  target="_blank">` on an installed tile) and the service opened in a tab.
- **opened** — the user opened the service's detail page (`openDetail`).
- **last_used** — the later of the two. The default sort key.
- **deployed_at** — mtime of the service's `marker` path, as an epoch
  float; `null` when the marker does not exist. This is what "chronological"
  sorts by, newest first.
- **resources** — RAM and CPU read from **cgroup v2 in sysfs**, never from
  `docker stats`. Measured 2026-09-12 on this box: docker containers live at
  `/sys/fs/cgroup/system.slice/docker-<64hex>.scope/`, user units at
  `/sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/app.slice/<unit>/`,
  and both expose `memory.current` and `cpu.stat` (`usage_usec`), readable by
  the launcher's own user. The **only** docker call is one cached
  `sg docker -c "docker ps -a --no-trunc --format '{{.Names}}\t{{.ID}}'"`
  to map container name → id, TTL 10 s, and if it fails every container
  part simply reports `null`. Status must keep working with no docker group
  at all — that rule is unchanged.

### Payload contract (server → web)

Every entry in `GET api/services` (list) AND the object from
`GET api/services/{key}` (detail) gains these three keys. All are always
present; missing data is `null`, never an absent key and never an error.

```json
"usage":       {"last_launched": 1757622000.1, "last_opened": null, "last_used": 1757622000.1},
"deployed_at": 1757550470.0,
"resources": {
  "rss_bytes":  1234567,          // sum over parts; null if no part could be read
  "cpu_pct":    2.4,              // percent of the WHOLE MACHINE (0-100), i.e.
                                  // delta usage_usec / (delta wall usec * nproc) * 100;
                                  // null until the server has two samples
  "sampled_at": 1757622001.0,
  "parts": [
    {"name": "immich_server", "kind": "container", "rss_bytes": 512000000, "cpu_pct": 1.9},
    {"name": "manimkc.service", "kind": "unit",    "rss_bytes": null,      "cpu_pct": null}
  ]
}
```

Parts come from the service's `control.parts` (container → `kind:
"container"`, unit → `kind: "unit"`), in that order. A service with no
control block gets `"parts": []` and nulls. The server keeps the previous
`(usage_usec, wall)` per cgroup in memory to compute `cpu_pct`; it is
recomputed on each list/detail request, cached with the same TTL discipline
as probes so a busy grid cannot hammer sysfs.

### New endpoint

`POST api/services/{key}/touch` with body `{"event": "launched"}` or
`{"event": "opened"}`. Records `time.time()` into
`~/services/launcher/usage.json` (same atomic-replace pattern and lock
discipline as `overrides.json`) and returns `200 {"usage": {...}}`.
`404` for an unknown key, `400` for any other event, `413`/`400` for a body
over 1 KB. The web fires it with `fetch(..., {keepalive: true})` on launch,
because that click navigates the tab away.

### Web behaviour

- A toolbar beside the existing search/tabs with two native `<select>`s,
  styled like the tabs: **View** (`Grid` | `Table`) and **Sort**
  (`Last used` | `Deployed` | `RAM`). Both persist in `localStorage` (per
  device, like `TAB_STORE`); default `Grid` + `Last used`.
- Sort is applied to whatever the active tab/filter yields, in both views:
  - Last used: `usage.last_used` desc; never-used services after, in
    registry order.
  - Deployed: `deployed_at` desc; not-deployed after, in registry order.
  - RAM: `resources.rss_bytes` desc; `null` after, in registry order.
- **Table view**: one row per service — icon, name + tagline, state pill,
  RAM (human units, `—` for null), CPU (`x.x %`, `—` for null), last used
  (relative, "3 h ago"), deployed (date), and the same two affordances as a
  tile: icon/name launches (and fires `touch launched`), the rest of the row
  opens details (and fires `touch opened`). The table sits in its own
  `overflow-x: auto` container so the page never scrolls sideways at 400 px.
- **Grid view** unchanged except that installed tiles may show the RAM
  figure in small muted text; nothing else moves.
- **Detail page**: a "Resources" block in the main column (not the notes
  column): total RAM, CPU, deployed date, last launched, last opened, and a
  per-part table (name, kind, RAM, CPU). Everything null-safe: the block
  renders `—` cells, not errors, against a server that predates this
  contract.
- Nothing new is fetched: the grid's existing 30 s poll of `api/services`
  carries the new keys; `cpu_pct` appears from the second poll.

### Ownership

- backend agent: `server.py`, `tests/test_server.py`
- frontend agent: `web/view.js`, `web/view.css` (new), `web/app.js`,
  `web/app.css`, `web/index.html`
- readme agent: repo `README.md` only (service icons + links — unrelated to
  this feature, batched for the same push)
