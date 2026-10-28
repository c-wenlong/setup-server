# launcher — spec (first draft)

_Shipped note (2026-09-12): the launcher also ships a lifecycle control API
(`POST api/services/{key}/action` for start/stop/restart, with `launcher`,
`ntfy` and `ollama` hard-locked against it) and a per-service notes API
(`GET/POST api/services/{key}/notes`, `PATCH`/`DELETE .../notes/{id}`),
neither of which is described anywhere in this document, and the "Out of
scope" lists below (which say stop actions are not built) are stale as a
result._

A single-page app launcher for homeserver: every service as a tile,
tap to open. Tiles for services that are **not deployed yet** are dimmed and
carry a Deploy action that runs that service's `setup.sh` on the box — so
this is both an index of what exists and the place you install from.

Explicitly NOT a stats dashboard. No graphs, no widgets, no per-service
metrics. Uptime Kuma and beszel already do that and are one tap away.

## Why it exists

Opening a service today means typing
`https://homeserver.tail-name.ts.net:2283` on a phone. This replaces
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
  :8093/         │                    ├── serves static/ (static, no build step)
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
  "setup":   "services/immich/setup.sh"
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
`http://127.0.0.1:8080/healthz`), open-webui (Chat, 3001, health :3001; shipped on :10000, moved to
:3001 on 2026-09-13 so the published and local ports match),
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
- frontend agent: `static/view.js`, `static/view.css` (new), `static/app.js`,
  `static/app.css`, `static/index.html`
- readme agent: repo `README.md` only (service icons + links — unrelated to
  this feature, batched for the same push)

---

## v4 — editing env values (2026-09-12)

Requested: edit any environment variable from the detail page. The case
that matters is a password reset inside an app (Seafile, Kuma, Immich…):
the `.env` copy goes stale and there was no way to fix it short of SSH.

### Behaviour

- Every env row gains a pencil. Tapping it reveals the current value (one
  explicit POST, as before), puts it in an inline input with the text
  selected, and swaps the row's buttons for **save** and **cancel**. Enter
  saves, Escape cancels. A secret goes back behind its mask after saving.
- Save rewrites **that variable's line only**. Comments, blank lines,
  ordering, other variables, indentation, an `export ` prefix, CRLF endings
  and a missing final newline all survive byte-for-byte; the file's mode
  (0600) is copied onto the replacement.
- Editing cannot **add** a variable: the name must already be assigned in
  the file, otherwise 404 with the request never echoed back — the same
  rule reveal uses. This is what keeps the request from introducing a name
  the service's `setup.sh` never put there.
- The saved note says the service reads the file again on its next
  restart. That is the honest contract: services take `.env` at container
  start, and a password changed inside an app is already live — the file
  is the *record*.

### Quoting — the part that was measured

Every `.env` here is read by **three** things that must agree on a line:
`set -a; . .env` in each `setup.sh` (a POSIX shell), Docker Compose
(interpolation and `env_file`), and the launcher's own `parse_env`. The
rules are the intersection, verified 2026-09-12 against dash, bash and a
real container (`docker compose run … printenv`):

| Value | Written as | Why |
|---|---|---|
| `[A-Za-z0-9_./:@%+=,-]*` | bare `NAME=value` | every reader takes it literally |
| anything else without `'` | `NAME='value'` | shell and Compose both take single quotes literally, no interpolation |
| contains `'`, no `$` or backtick | `NAME="value"` with `\\` and `\"` escaped | the only two escapes all three readers unescape identically |
| contains `'` **and** `$` or backtick | **refused, 400** | the shell unescapes `\$` and `` \` ``; Compose does not — no spelling agrees |

`parse_env` learned to unescape `\\` and `\"` inside double quotes for
this. No existing file on the box had a backslash in a double-quoted value,
so nothing already deployed reads differently. Before writing, the server
parses the rewritten text back and refuses (500, file untouched) if it does
not yield the value that was sent — the quoting rules and the parser can
never silently drift apart.

### API

| Method | Path | Purpose |
|---|---|---|
| PATCH | `api/services/{key}/env/{var}` | `{"value": "…"}` → `{name, secret, value}`; 404 unknown service/variable/no file, 400 not a string / multi-line / over 4096 chars / unquotable, 403 env path outside the allowed roots |

PATCH, not POST, so it can never be confused with `…/env/{var}/reveal`
next to it. Same allowed-roots gate as reveal and deploy, same single lock
plus temp-file-and-`os.replace` discipline as `overrides.json`. The value
goes into the file and back to the caller; the log line carries the
variable name only.

## v5 — install receipts (2026-10-25)

Step 2 of the build order in `docs/catalogue-architecture.md`: the
**instance** layer. When a deploy started from the launcher exits 0, the
server writes `~/services/launcher/instances/<key>.json`:

| Field | Value |
|---|---|
| `version` | `1` |
| `key` | the registry key; the file is refused unless it matches |
| `repo` | git root holding the setup script, `~`-collapsed, or null |
| `revision` | that checkout's HEAD as 40 hex, read from `.git` directly (loose ref, packed-refs, worktree, detached), or null |
| `setup`, `data_dir` | the registry's `setup` and `marker`, verbatim |
| `ports` | `{NAME: int}` for every `*_PORT` in the service's `.env` that is a whole number in 1–65535 and not secret-looking |
| `installed_at` | first successful deploy (kept across redeploys) |
| `deployed_at`, `deploys`, `last_job` | latest success, running count, its job id |

Same atomic temp-file-and-`os.replace` write as `overrides.json`, under its
own lock. A write failure is logged and never fails the job. Keys must match
`^[a-z0-9][a-z0-9._-]{0,63}$` to have a receipt path at all.

The receipt is metadata, not state: `installed` and the tile state still
come from the marker and the health probe, so a receipt left behind by a
hand-removed service cannot make it look installed. `GET
api/services/{key}` carries it as `receipt` (null when absent), and the
detail page shows Installed / Last deploy / Revision / Ports rows from it.
Nothing writes receipts for services deployed from a terminal; that, and
removing a receipt on uninstall, come with the apply and remove steps.

## v6 — catalogue page (2026-10-25)

Step 4 of the build order in `docs/catalogue-architecture.md`. Decided
2026-10-25: a catalogue app still needs the full service contract
(`setup.sh`, docs, tests). Install runs that `setup.sh` through the existing
deploy job; there is no separate compose-only installer.

- **Route** `#/catalogue`, linked from a Catalogue button in the header.
  `catalogue.js` owns `#view-catalogue`; `app.js` only hides the grid and
  search row on that route (`showGrid`) and brings them back on `#/`.
- **Data**: no new endpoint. `GET api/services` gains `receipt` on every
  entry (null when absent), and `catalogue.js` paints from the list `app.js`
  already polls, through `window.LauncherApp.services()` / `.groups()`. It
  repaints on the `launcher:services` event `app.js` fires after each poll,
  so it never polls on its own.
- **Cards**, grouped by the registry's `groups`: icon, name, tagline, full
  description (clamped to four lines), author, a status line (Installed,
  running / stopped, with "since <date>" from the receipt; Not installed;
  Coming soon for an entry with no `setup`; Installing now while a job
  runs) and actions: Install (available), Installing… (running job,
  reattaches), Open (active with a URL), Details (`#/service/<key>`).
- **Install** calls `LauncherApp.deploy(key, button)`, which opens the
  grid's own deploy sheet: same confirm step, same log, same 409/429
  handling. The sheet closing triggers a poll, which repaints the page.
- **Search** across key, name, tagline, description and author; filter
  chips All / Installed / Not installed. Every control carries
  `data-act="<key>:<kind>"`, so focus returns to the same control after a
  repaint.
- **Running jobs** are labelled by `job.action` (Installing / Starting /
  Stopping / Restarting), as on the grid.
- **Failures**: `app.js` fires the same event when a poll fails and exposes
  `LauncherApp.error()`; with nothing loaded the page shows the error and a
  Retry. Board chrome (which locks page scroll) is never applied on this
  route, even though `render()` re-applies it after each poll.

## v7 — Remove (2026-10-25)

Step 5 of the build order. `remove` is a fourth lifecycle action on the
existing `POST api/services/{key}/action` (`{"action": "remove"}`), with the
same job, sheet, log and 403/409/429 handling as start/stop/restart.

- **Offered only** when the service is controllable and a `teardown.sh`
  sits beside its `setup.sh` (`removable` on the list and detail payloads).
  403 without one, and for locked services (launcher, ntfy, ollama). 409
  when the service is not installed (or already removed).
- **Steps**: pause the service's Kuma monitor (best effort), then run its
  `teardown.sh` with **no arguments** through the same docker-group wrapper
  as a deploy, then (only if the teardown failed, so the service is still
  up) resume the monitor. `--purge` is never sent; deleting data is
  terminal-only. The resume a reinstall does is appended to that deploy's
  job log, with a warning line when it fails.
- **On success** the receipt gets `removed_at`. While that is set and the
  health probe does not answer, `installed` is false and the tile and
  catalogue read Not installed ("Removed <date> · data kept"), even though
  the data dir that serves as the marker is still there. A deploy writes a
  fresh receipt with no `removed_at`, and resumes the monitor the remove
  paused.
- **UI**: a red Remove button on the detail page beside start/stop/restart
  and a Remove link on installed catalogue cards; the confirm sheet says the
  data and `.env` stay and that `teardown.sh --purge` is the terminal-only
  way to delete them.

## v8 — ops home and sidebar shell (2026-10-28)

The tile grid answered "what exists" well and "what is running, and is the
box OK" badly: 36 tiles of equal weight, state in a 6px dot, and every
start or stop one page away. The home page is now built for running the box.

**Diverges from the first draft** on one rule: "explicitly not a stats
dashboard". The page now opens on a four-cell health strip (apps running,
memory, disk, CPU load). It stays four numbers with no history or graphs;
the reason is that a full disk took deploys down and nothing on the page
said so. Above 95% disk a sentence says it before anything else.

**Also replaced:** the Grid / Table / Board views, sort select, star
pinning, the tab strip (All / Active / Paused / Updates / Uninstalled /
c-wenlong) and the Categories multi-select. In their place:

- Rows grouped **Running / Stopped / Not installed**. A degraded service
  (probe failing, parts alive) sits under Running with a red X glyph and
  "Not responding", where it will be seen.
- State in the glyph's **shape** (solid check, half ring, X, empty ring,
  dotted ring, dashed ring), colour only on top.
- One visible button per row (Open / Start / Install / Restart for a
  degraded one / View log while a job runs); everything else in a ⋯ action
  menu with a letter per item. Every verb still goes through app.js's
  confirm-then-log sheet (`LauncherApp.action`).
- Category pills, plus **Updates** while any tag has moved. Author is
  searchable rather than a tab.
- Keyboard: `/` search, ↑/↓ select, ↵ primary, ⌘K / Ctrl-K menu.
- A sidebar (collapsible to icons; a drawer below 900px) with Apps,
  Catalogue, Deploys (deployd's page) and shortcuts to the running
  monitoring apps (Uptime Kuma, beszel, ntfy).

view.js keeps only the theme control, the detail page's Resources block and
the usage beacons; its table, board, toolbar, star and tile-RAM code is
deleted along with the grid, tab and category code in app.js and app.css.

### Payload

`GET /api/services` gains a top-level `system` object. Every key is always
present and null when the platform cannot say (macOS has no `/proc`):

| key | value |
|---|---|
| `memory` | `{total, available}` bytes from `/proc/meminfo` (`MemAvailable`); `{total, available: null}` from `sysconf` elsewhere |
| `disk` | `{mount, total, used, free}` bytes for the filesystem holding `~` |
| `load` | `[1, 5, 15]` minute load averages |
| `cpus` | `os.cpu_count()` |
| `uptime_s` | seconds, from `/proc/uptime` |

Thresholds live in home.js: disk warns at 85% and is critical at 95%
(df's arithmetic, `used / (used + free)`); memory is tight below 10%
available.

## v9 — Deploys page (2026-10-28)

deployd stops being a row in the app list and becomes the launcher's
**Deploys** page (`#/deploys`, linked from the sidebar). The engine is
unchanged: the same systemd timer, the same `app.json` `deploy` blocks and
`state/pollers.json` edit layer. What moved is where you manage it.

- `app.json` gains an optional `"hidden": true`: machinery with a page of
  its own rather than a row. `GET /api/services` always carries `hidden`
  (only a JSON `true` hides); the home list and the catalogue skip it, the
  payload keeps it so the page can drive its controls.
- The page header shows the timer as **Polling** (`active`), **Paused**
  (`inactive`), **Timer failed** (`failed`, in the error colour) or
  Starting… / Stopping… while it changes, with Pause / Resume / Restart
  (deployd's stop / start, through the confirm sheet; none mid-change) and
  **+ Add poller**; below it every watched repo, the not-polled list and the
  notes deployd leaves (failed self-update, pending launcher restart).
- `#/service/deployd` redirects to `#/deploys`. Other detail pages keep
  their own one-row Deploys section.

Next (v10): new apps straight from a GitHub repo (Dockerfile builds,
repo picker on the box's `gh` login, config on the box with Export to
repo).

## v10 — apps from GitHub: the runner and API (2026-10-28)

The second half of "deploys in the dashboard": a repo with a Dockerfile
becomes an app on this box without a `setup.sh` folder in this repo.
Decided with the owner on 2026-10-28: the engine stays deployd's hidden
timer, Dockerfile builds first, private repos through the box's existing
`gh` login (git's credential helper; no token in the launcher), config on
the box with an Export to repo button later. This version is the backend;
the New app screens on the Deploys page follow in v11.

**One app = one definition + one runtime dir.**
`~/services/launcher/apps/<key>.json` (repo, ref, Dockerfile path, context,
container port, allocated port, health path, optional volume) and
`~/services/apps/<key>/` (`src/` at the deployed commit, `.env` 0600,
`data/`, `deployed.json`, `.lock`).

**`app/web/ghapp.py deploy|remove <key>`** (stdlib). Deploy: resolve the
ref (or `$DEPLOY_SHA` from deployd) → fetch that exact commit → `docker
build` tagged `launcher-app/<key>:<sha12>` → swap the `app-<key>` container
(`127.0.0.1:<port>`, `--restart unless-stopped`, `--env-file`, optional
volume) → health-check `127.0.0.1:<port><health_path>` for 90 s → if the new
container cannot start OR does not answer, put back the image that was
running (by image ID, captured before the build, so a rebuild of the same
commit can still roll back) and fail the job → `tailscale serve
--https=<port>` unless already mapped → write `deployed.json`, record the
sha in deployd's `state/<key>.sha` (so its next tick does not rebuild it)
and clear `state/<key>.disabled` → keep one older image. Remove: drop the
container and this port's Serve handler (only when it proxies to this app;
nothing changes unless Docker answers and Serve status reads, and a
container or route that will not go fails the job and keeps
`deployed.json`),
drop `state/<key>.disabled` so a push cannot bring it back (the teardown.sh
contract), keep `src/`, `.env`, `data/` and the definition. `origin` is
re-pointed at the definition's repo before every fetch (a key can be
re-created for another repo). A per-app flock serialises deployd and the
launcher, and the definition is re-read under it; without the docker group
(a user unit) the runner re-enters under `sg docker` once.

**Registry merge.** `load_registry()` appends the definitions as entries
with `runner: "ghapp"`, group `github` ("From GitHub", added to the groups
list only when an app exists), container control part `app-<key>`, marker
`deployed.json`. A registry key always wins over a definition with the
same key. Everything downstream (state, Open, Start/Stop, Remove, the .env
editor, image-update checks) goes through the existing paths, with
`runner_args()` adding `deploy|remove <key>` to the argv and `env_path()`
deriving the `.env` from the key instead of the allowed-roots gate. That
`.env` is Docker's `--env-file` format, which keeps quotes as part of the
value, so the editor reads and writes it bare (`KEY=hello world`) and
refuses a value with leading or trailing whitespace.

**Auto-deploy** is a custom `state/pollers.json` entry written on create:
`{repo: https://github.com/<repo>.git, ref, cmd: "app/web/ghapp.py deploy
<key>"}`. It starts paused (`state/<key>.disabled`) and the first
successful deploy un-pauses it, so deployd never races the launcher's own
first run. deployd is unchanged; the Deploys page lists it like any poller.
Create is refused (409) when a custom poller of that key already exists
with another command. Delete is refused while a launcher job runs or a
deploy holds the app's lock.

**API.**

| Route | Does |
|---|---|
| `GET api/github/repos` | the login's repos, pushed-recently first (`gh api user/repos`, cached 2 min) |
| `POST api/github/inspect` `{repo, ref?}` | branches, default branch, whether `Dockerfile` exists at the ref, the first `EXPOSE` port, a free key |
| `POST api/apps` `{repo, ref, key, name?, tagline?, container_port, health_path?, volume?, dockerfile?, context?, env?}` | validate, allocate a port, write definition + `.env` + poller, start the first deploy; 202 `{key, port, auto_deploy, job_id}` |
| `DELETE api/apps/{key}` | forget a GitHub app (409 while installed: Remove it first); keeps `~/services/apps/<key>` |

**Ports.** 8300–8399, local == HTTPS, first free: not in any registry URL
or health probe, not any configured Serve port (proxy, static or text), not
listening. Recorded in DIRECTORY.md.

## v11 — New app from GitHub: the screens (2026-10-28)

The front end for v10's API, on the Deploys page. `static/newapp.js`
(plus `newapp.css`) is a self-contained dialog, the same module contract
as notes.js and deployd.js: deployd.js adds **+ New app** (the accent
button; **+ Add poller** drops to a plain one) and calls
`window.LauncherNewApp.open(button)`.

1. **Pick a repo.** `GET api/github/repos` fills a list (archived repos
   hidden, newest push first, a Private tag, description and push age),
   filtered as you type. A query shaped `owner/name` that is not in the
   list becomes a "Use this repo" row, so a public repo of someone else's,
   or one the listing missed, still works. When the listing fails (no `gh`
   login) the error says so and typing `owner/name` still works.
2. **Configure.** `POST api/github/inspect` fills: Name (repo name), Key
   (the suggested free key), Branch (a select of the repo's branches),
   Container port (the first `EXPOSE`), Health path (`/`), Environment
   (KEY=value lines), and under Advanced the Dockerfile path, build context
   and data volume. A status line says whether a Dockerfile sits at the
   root of that branch. Create stays disabled without one unless Advanced
   names another path. Changing the branch re-inspects it and refreshes the
   port unless it was typed.
3. **Create and deploy** posts `api/apps`. On 202 the dialog closes,
   `LauncherApp.refresh()` brings the new From GitHub row in, and
   `LauncherApp.watchJob(key, job_id, 'deploy')` streams the first build
   in app.js's job sheet. Errors (409 key taken, 400 bad field, 503 no
   free port) show inline and keep the form. Create stays off while a
   request is in flight or a branch check is running or failed. When the
   reply says `auto_deploy: false` (deployd's poller could not be added),
   the dialog stays open on a "Created" step that says pushes will not
   redeploy, with **Watch the build** to continue.

Keys and ports are checked in the browser only for a quick message; the
server's checks are the authority. Esc, the scrim and Back/Cancel close or
step back; focus returns to **+ New app**.

Not yet: forgetting an app from the UI (`DELETE api/apps/{key}` exists).
Export to repo landed in v12.

## v12 — Export to repo (2026-10-28)

The "Export to repo button later" half of the config decision in v10: a
GitHub app's definition lives on the box, and can be copied into this repo
as `app/web/apps/<key>.json` through a pull request.

**Server.** `POST api/apps/{key}/export` (GitHub apps only, 404 otherwise;
409 when the repo copy already equals the box copy). It reads this
checkout's `origin` (must be GitHub), then through the box's `gh` login and
the GitHub API only (never the checkout, which deployd ff-pulls and other
sessions share): the default branch's head → a new branch
`launcher/export-<key>-<timestamp>` → PUT the file (with the file's sha
as read on that new branch, so a merge to the default branch in between
cannot mismatch) → open a PR. Exports never queue: a second one while one
runs is a 409. A retry of the same bytes while the recorded PR is still
open is a 409 naming that PR; once it is closed unmerged, export runs
again. The page waits 180 s, above the server's worst case. The PR body lists
the app's `.env` variable NAMES, never values. The reply `{key, url,
number, branch}` is also recorded in `~/services/apps/<key>/exported.json`
with a sha256 of the exported bytes.

`gh_write()` runs `gh api -X <method> <path> -f k=v ...`: `-f` sends raw
strings (no `@file` or number magic) and the argv never meets a shell. It
shares `gh_api()`'s error mapping (404, 503 not logged in, 502 else).

**Payload.** `/api/services` gains `github` (appended last; `null` for
everything that is not a GitHub app): `{repo, ref, in_repo, export_pr}`.
`in_repo` compares this checkout's file with the box copy: `same`,
`differs` or `absent`. `export_pr` is the recorded PR URL while its digest
still matches the box copy and the repo does not have it yet.

**UI.** `static/ghsource.js` (+ `ghsource.css`), the notes.js contract,
mounted at `#ghsource-mount` under the deploy section of the detail page:
a Source section with the repo and branch, the in-repo status, the open
export PR, and **Export to repo** / **Export changes** / **Export again**.

**CI.** `ExportedAppsInRepoTest` checks every file in `app/web/apps/`:
`ghapp.validate` accepts it, it is named `<key>.json`, its key is not a
service in `services.json`, its port is in 8300–8399 and no two share one.

Bringing an exported app back on a fresh box landed in v13.

## v13 — Restore from repo (2026-10-28)

The other half of v12: an `app/web/apps/<key>.json` in this checkout with
no box copy is a restore candidate, listed and deployable like any app.

**Listing.** `_ghapp_defs()` returns `(definition, source)` pairs: every
valid box definition (`box`), then each valid repo file whose key the box
lacks (`repo`). A repo file must pass `ghapp.validate` and be named for its
key; a bad one is logged and skipped. The entry carries `ghapp_source` and
`env_names`, and no health probe or control parts, and `restore_pending()`
forces it to not installed and not active in both `/api/services` and the
detail response: something else may answer on its exported port on a
rebuilt box, and it must still offer Install (which reaches the port check
in `adopt_app`), never Open. Its state is `available` and it shows under
From GitHub with Install. Create refuses a
key the repo defines (409): Deploy that one instead.

**Adopt on Deploy.** `start_deploy` on a repo-only entry first runs
`adopt_app` under the GitHub-apps lock: 409 if a job is running or a
custom poller of that key has another command; copy the definition to the
box unchanged, except the port when anything else has it (another
registry entry, a Serve handler proxying elsewhere, or a listener not
behind its own Serve handler), which gets the first free one; write a 0600
`.env` with each `env_names` entry and an empty value (only if absent);
wire the paused poller exactly as create does. Then the normal deploy
runs. A kept port means `in_repo` reads `same` afterwards; a new one reads
`differs`, and Export changes records it.

**`env_names`.** Create now stores the names (never values) of the env
lines it was given as an optional `env_names` list; `ghapp.validate`
accepts it when it is a list of up to 100 env-var names. It is what lets a
restored app's `.env` editor show the variables to fill in, since the
editor edits names and never adds them.

**UI.** The Source section's `only` state: "Not set up on this box yet",
which values the `.env` starts empty, and no Export button. Export and
Delete refuse a repo-only app (409).
