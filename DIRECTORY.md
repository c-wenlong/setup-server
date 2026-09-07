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
- **Phone apps** — ntfy app connected (2026-09-08, subscribed `alerts`;
  service control via [ntfy-control](ntfy-control/) buttons — send `panel`
  to re-pop the menu). Seafile app (camera upload) still pending.
- **n8n intentionally stopped** (2026-09-08, via ntfy-control; Kuma monitor
  paused). Start it from the panel or `docker start n8n` when needed —
  scheduled workflows don't run while it's down.
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
