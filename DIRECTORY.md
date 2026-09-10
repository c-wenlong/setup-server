# Deployment directory — kai-home-server

What's actually running on `kai-home-server` (Ubuntu 24.04, Ryzen 5 2600,
7.7 GB RAM), audited 2026-09-07. All web services are tailnet-only:
`https://kai-home-server.taild6a23f.ts.net[:port]`, TLS terminated by
Tailscale Serve, apps bound to `127.0.0.1`.

## Filesystem layout (since 2026-09-07)

Code and state are separated; `~` root stays flat no matter how many
services are added:

- `~/dev/<repo>` — git clones (this repo lives at `~/dev/setup-server`;
  service code like `~/dev/manimkc` too)
- `~/services/<name>` — runtime state only: Docker bind mounts, data
  dirs, job workdirs. Never in git; this is the backup target.

A new service claims one dir in each. Volume paths are set in each
service's `setup.sh` (defaults) and baked into its gitignored `.env`
on first run — a path change must edit both. code-server is the
exception: its state is in `~/.config/code-server` (systemd user unit,
no Docker).

## Services & ports

| HTTPS (tailnet) | Service | What it does | Local port | Runs as |
|---|---|---|---|---|
| :443 | [code-server](code-server/) | VS Code + terminal in the browser | 8080 | systemd user unit |
| :8443 | [seafile](seafile/) | Drive: file sync, web UI, iPhone photo backup | 8081 | Docker (+ MariaDB, Redis on internal network) |
| :10000 | [open-webui](open-webui/) | ChatGPT-style UI over local ollama | 3001 | Docker (host net) |
| :3002 | [monitoring](monitoring/) — Uptime Kuma | Status dashboard; probes everything below every 60s | 3002 | Docker (host net) |
| :3003 | [monitoring](monitoring/) — ntfy | Push notifications (topic `alerts`) to phone/web | 3003 | Docker (host net) |
| :5678 | [n8n](n8n/) | Workflow automation; workflows can call all local services | 5678 | Docker (host net) |
| :8091 | [kaichenpedia](kaichenpedia/) | Personal wiki (Quartz static build of the private kaichenpedia repo); polls GitHub daily and redeploys on new commits (`bin/deploy.sh --force` deploys now) | 8091 | Docker (nginx) + systemd user timer |
| :8090 | manimkc (`~/dev/manimkc/server/`) | Video-gen job server: JSON brief → narrated ManimGL video → Seafile `manimkc` library | 8090 | systemd user unit |
| :8092 | [beszel](beszel/) | Resource monitoring: CPU/RAM/GPU/disk/net/temps, history + ntfy-able alerts (complements Kuma's uptime checks) | 8092 | Docker (host net, loopback-bound) + native agent on 127.0.0.1:45876 (systemd user unit) |
| :443**/home/** + :8093 | [launcher](launcher/) | One-tap app launcher: tile grid of every service with live status; dimmed tiles for services not installed yet, with a Deploy button that runs their `setup.sh`. **The short URL to bookmark on the phone.** Shares :443 with code-server via a `--set-path=/home` handler, which leaves `/` untouched | 8093 | systemd user unit (Python 3 stdlib, no deps) |
| :3000 | [forgejo](forgejo/) | Self-hosted git forge: repos, pull requests, issues. v15 **LTS** (to 2027-07-15) not v16 (EOL 2026-10-29); SQLite not Postgres, so one container at ~100 MB. Built-in SSH off — port 22 is the box's own sshd — so clone over HTTPS. Sign-ups disabled | 3000 | Docker (single container, loopback-published) |
| :2283 | [immich](immich/) | Self-hosted Google Photos: timeline, albums, phone background backup; ML (faces/semantic search) behind a flag, **off by default** on this box's 7.7 GB | 2283 | Docker (bridge; server loopback-published, postgres+redis unpublished) |

Supporting services (no Tailscale Serve entry):

| Port | Service | Notes |
|---|---|---|
| 22 | OpenSSH | LAN + tailnet; primary access is Tailscale SSH |
| 11434 | ollama | ⚠️ binds `*` (LAN-exposed) via systemd override; models: qwen3:8b, qwen3:4b, nomic-embed-text. Loose end: tighten to 127.0.0.1 (Open WebUI + n8n only need loopback) |
| — | seafile-mysql, seafile-redis | Docker-internal network only, no host ports |
| — | [ntfy-control](ntfy-control/) | Listens on ntfy topic `control` (loopback subscribe, no port); allowlisted start/stop of services from the phone app, replies + Kuma pause included | systemd user unit |

## Port allocation rules

- Modern Tailscale (>= ~1.90) serves HTTPS on **any** port — the old
  443/8443/10000 limit is gone.
- A port can host **several** mounts: `tailscale serve --set-path=/foo` adds a
  handler next to whatever already owns `/`, so :443 serves code-server at `/`
  and the launcher at `/home/`. Tailscale **strips** the prefix before
  proxying (the backend sees `/`), so anything published this way must use
  relative URLs. Never issue a bare `--https=443` — it replaces the `/`
  handler and takes code-server down.
- Convention: monitoring-class services use HTTPS port == local port
  (3002/3003); earlier services predate that and differ.
- Before claiming a port for a new service: check this table, then
  `ss -ltn` and `tailscale serve status` on the box, then add rows here,
  a monitor line in `monitoring/seed_kuma.py`, and a row in README.md.

## Credentials & auth

- code-server: no password — tailnet is the auth layer
- Seafile / Kuma / n8n: admin credentials in each service's gitignored `.env`
- Open WebUI: first-registered account is admin (registered by Kai)
- ntfy: open on the tailnet (anyone on the tailnet can pub/sub)
- Immich: admin `chenwenlongofficial@gmail.com`, password generated into
  `immich/.env` (`IMMICH_ADMIN_PASSWORD`); DB password there too. Same
  password-sync rule — a UI change must be mirrored back into `.env`, or
  setup.sh warns and skips the settings step on the next run.
- manimkc: uploads as service account `manimkc@kaichen.local` (API token in
  `~/dev/manimkc/.env`, no password stored); library `manimkc` shared rw to
  Kai's account. ⚠️ service account is a Seafile admin (self-demotion via API
  rejected) — demote in Seafile web UI when convenient. NOTE: Kai's own
  Seafile admin password drifted from `seafile/.env` (UI change?) — the
  `.env` copy no longer authenticates; fix per the password-sync rule below.

## Loose ends / TODO (as of 2026-09-07)

- **ollama on `*:11434`** — LAN-exposed via systemd override; tighten to
  127.0.0.1 (Open WebUI + n8n only need loopback). Needs sudo.
- **Tailscale exit node** — not yet advertised (`tailscale set
  --advertise-exit-node` + one-time admin-console approval).
- **Launcher state is not in git and not backed up** —
  `~/services/launcher/overrides.json` (per-service name/description edits)
  and `~/services/launcher/notes.json` (developer notes) are user-authored
  content living only on this disk. `services.json` in the repo is the
  shipped default; overrides layer on top, and deleting either file falls
  back cleanly. If notes accumulate real operational knowledge, they need to
  be in the backup job alongside the Immich library and database.
- **Launcher can start/stop/restart services**, sharing one allowlist with
  ntfy-control: the `control` block per service in `launcher/services.json`,
  read by both. `ntfy`, `ollama` and `launcher` are locked out server-side
  (checked before the registry, so editing services.json cannot re-enable
  them) — stopping ntfy or the launcher removes the only way to start them
  again, and ollama is a system unit that would need sudo.
- **Immich RAM ceiling** — deployed 2026-09-10 with machine learning OFF
  (`IMMICH_ML=off`, the default): 7.7 GB total, and ollama claims ~5 GB with a
  model loaded, against Immich's documented 6 GB minimum / 8 GB recommended.
  Semantic search, face grouping and OCR stay dark until then. This box is
  AM4/DDR4, so 32 GB is a ~$50–90 upgrade; after it lands run
  `IMMICH_ML=on ./setup.sh` and the existing library backfills. The ~150 GB
  free disk is the other gate — a Takeout import wants a dedicated drive.
- **Seafile vs Immich camera upload** — pick one, not both, or every photo is
  stored twice. Seafile camera upload was never enabled, so Immich takes the
  role and Seafile stays Drive-only.
- **Phone apps** — ntfy app connected (2026-09-08, subscribed `alerts`;
  service control via [ntfy-control](ntfy-control/) buttons — send `panel`
  to re-pop the menu). Seafile app (camera upload) still pending.
- **n8n intentionally stopped** (2026-09-08, via ntfy-control; Kuma monitor
  paused). Start it from the panel or `docker start n8n` when needed —
  scheduled workflows don't run while it's down.
- **kaichenpedia intentionally stopped** (2026-09-08, via ntfy-control; Kuma
  monitor paused, container `Exited (0)`). Not needed up right now. Start it
  from the ntfy panel or `docker start kaichenpedia`; the daily GitHub poller
  only redeploys while the container is running. Both this and n8n show as
  amber "Paused" tiles in the launcher, which is accurate, not a fault.
- **kaichenpedia baseUrl** — `site/quartz.config.ts` in the wiki repo still
  points at the old Cloudflare domain (cosmetic: og/sitemap links only).
- **AdGuard Home** — agreed next service (see EXPLORATION.md).
- **macOS script paths** — portable by construction, still unverified on a
  real Mac (`tests/run-tests.sh` mocked suite would confirm).
- **Password sync rule** — service `.env` files are read once at seeding;
  UI password changes must be manually mirrored into `.env` or re-seeding
  breaks (bit us once with Kuma). n8n's password differs from Kuma's by a
  capital K (n8n policy).
- **WhatsApp via Composio** — broken upstream (Graph API error 100);
  Telegram is the working personal channel.

## Quick health check

Dashboard: https://kai-home-server.taild6a23f.ts.net:3002 — or from the box:
each service's `./tests/run-tests.sh --live`.
