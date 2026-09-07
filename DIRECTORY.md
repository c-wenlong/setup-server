# Deployment directory — kai-home-server

What's actually running on `kai-home-server` (Ubuntu 24.04, Ryzen 5 2600,
7.7 GB RAM), audited 2026-09-07. All web services are tailnet-only:
`https://kai-home-server.taild6a23f.ts.net[:port]`, TLS terminated by
Tailscale Serve, apps bound to `127.0.0.1`.

## Services & ports

| HTTPS (tailnet) | Service | What it does | Local port | Runs as |
|---|---|---|---|---|
| :443 | [code-server](code-server/) | VS Code + terminal in the browser | 8080 | systemd user unit |
| :8443 | [seafile](seafile/) | Drive: file sync, web UI, iPhone photo backup | 8081 | Docker (+ MariaDB, Redis on internal network) |
| :10000 | [open-webui](open-webui/) | ChatGPT-style UI over local ollama | 3001 | Docker (host net) |
| :3002 | [monitoring](monitoring/) — Uptime Kuma | Status dashboard; probes everything below every 60s | 3002 | Docker (host net) |
| :3003 | [monitoring](monitoring/) — ntfy | Push notifications (topic `alerts`) to phone/web | 3003 | Docker (host net) |
| :5678 | [n8n](n8n/) | Workflow automation; workflows can call all local services | 5678 | Docker (host net) |

Supporting services (no Tailscale Serve entry):

| Port | Service | Notes |
|---|---|---|
| 22 | OpenSSH | LAN + tailnet; primary access is Tailscale SSH |
| 11434 | ollama | ⚠️ binds `*` (LAN-exposed) via systemd override; models: qwen2.5-coder:7b, llama3.1:8b. Loose end: tighten to 127.0.0.1 (Open WebUI only needs loopback) |
| — | seafile-mysql, seafile-redis | Docker-internal network only, no host ports |

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

## Loose ends / TODO (as of 2026-09-07)

- **ollama on `*:11434`** — LAN-exposed via systemd override; tighten to
  127.0.0.1 (Open WebUI + n8n only need loopback). Needs sudo.
- **Tailscale exit node** — not yet advertised (`tailscale set
  --advertise-exit-node` + one-time admin-console approval).
- **Phone apps pending (Kai)** — ntfy app (subscribe `alerts`), Seafile app
  (camera upload). Both server-side ready.
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
