# launcher — spec (first draft)

_Shipped note (2026-09-12): the launcher also ships a lifecycle control API
(`POST api/services/{key}/action` for start/stop/restart, with `launcher`,
`ntfy` and `ollama` hard-locked against it) and a per-service notes API
(`GET/POST api/services/{key}/notes`, `PATCH`/`DELETE .../notes/{id}`),
neither of which is described anywhere in this document, and the "Out of
scope" lists below (which say stop actions are not built) are stale as a
result._

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
  chips All / Installed / Not installed. Focus stays on the same card's
  button across a repaint.
