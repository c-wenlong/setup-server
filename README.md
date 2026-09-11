# setup-server

One-shot, repeatable setup scripts for self-hosted services on private
(Tailscale) home servers. Each service lives in its own directory and can be
deployed independently by copying that directory to the target server and
running its `setup.sh`.

## Services

| Service | What it gives you | Deploy |
|---|---|---|
| [code-server](code-server/) | VS Code (with terminal) in the browser, tailnet-only over HTTPS | `cd code-server && ./setup.sh` |
| [seafile](seafile/) | Self-hosted Drive: file sync + web UI + mobile photo backup (Docker) | `cd seafile && ./setup.sh` |
| [open-webui](open-webui/) | ChatGPT-style UI over the host's ollama models (Docker) | `cd open-webui && ./setup.sh` |
| [monitoring](monitoring/) | Uptime Kuma dashboard + ntfy phone alerts for every service (Docker) | `cd monitoring && ./setup.sh` |
| [n8n](n8n/) | Workflow automation (self-hosted Zapier) wired to local services (Docker) | `cd n8n && ./setup.sh` |
| [kaichenpedia](kaichenpedia/) | Personal wiki (Quartz static site), auto-deploys from GitHub via a daily poller (Docker nginx) | `cd kaichenpedia && ./setup.sh` |
| [ntfy-control](ntfy-control/) | Start/stop services from the ntfy phone app (allowlisted commands; auto-pauses Kuma monitors) | `cd ntfy-control && ./setup.sh` |
| manimkc | Narrated ManimGL explainer videos from a JSON brief (HTTP job server; lives in the [manimkc repo](https://github.com/c-wenlong/manimkc) at `server/`) | `~/dev/manimkc/server/setup.sh` |
| [beszel](beszel/) | Resource monitoring — CPU/RAM/GPU/disk/network/temperature graphs + alerts (Docker hub + native agent) | `cd beszel && ./setup.sh` |
| [immich](immich/) | Self-hosted Google Photos: timeline, albums, phone background backup, optional face/semantic search (Docker) | `cd immich && ./setup.sh` |
| [forgejo](forgejo/) | Self-hosted git forge — repos, PRs, issues; v15 LTS, SQLite, ~100 MB (Docker) | `cd forgejo && ./setup.sh` |
| [jellyfin](jellyfin/) | Media server — films, shows, music to browser/phone/TV; software transcode, read-only media mount (Docker) | `cd jellyfin && ./setup.sh` |
| [remote-desktop](remote-desktop/) | This box's GNOME desktop in a browser tab — Guacamole + gnome-remote-desktop; **needs sudo** (configures a system daemon) | `cd remote-desktop && ./setup.sh` |
| [paperless-ngx](paperless-ngx/) | OCR'd, searchable archive of receipts, contracts and tax docs; SQLite + redis, ~659 MB (Docker) | `cd paperless-ngx && ./setup.sh` |
| [firefly-iii](firefly-iii/) | Personal finance — accounts, budgets, categories, reports; app + Postgres + Data Importer, ~195 MB (Docker) | `cd firefly-iii && ./setup.sh` |
| [homepage](homepage/) | YAML-configured dashboard of every service, with live status dots and widgets — a read-only front door alongside the launcher (Docker) | `cd homepage && ./setup.sh` |
| [adguard](adguard/) | Tailnet-wide DNS ad/tracker blocking — every device, no per-device app; needs one manual step in the Tailscale console to take effect (Docker) | `cd adguard && ./setup.sh` |
| [home-assistant](home-assistant/) | Local-first home automation — lights, plugs, sensors, media players, with LAN device discovery (Docker, host net) | `cd home-assistant && ./setup.sh` |
| [vaultwarden](vaultwarden/) | Password manager — Bitwarden-compatible server for the official Bitwarden apps; SQLite, ~12 MB, admin panel off (Docker) | `cd vaultwarden && ./setup.sh` |
| [launcher](launcher/) | One-tap app launcher for every service on the box — tile grid with live status, and a Deploy button for services not installed yet (Python stdlib, systemd user unit) | `cd launcher && ./setup.sh` |

Future service ideas live in [EXPLORATION.md](EXPLORATION.md).
The live deployment (every running service, port map, credentials pointers)
is documented in [DIRECTORY.md](DIRECTORY.md) — keep it updated when adding
services.

## Layout — every service directory contains

```
<service>/
  setup.sh          # idempotent one-shot deploy — the single entrypoint
  SETUP.md          # architecture, security model, dependencies, deploy + ops
  TROUBLESHOOT.md   # layered triage guide for when things break
  tests/
    run-tests.sh    # mocked suite (safe anywhere) + --live verification
```

## Conventions

- **`setup.sh` is idempotent.** Re-running upgrades/repairs; it never clobbers
  an existing user-edited config.
- **Run as a regular user.** Scripts self-escalate with `sudo` only for the
  few commands that need it, and say so before prompting.
- **Tailnet is the security boundary.** Services bind to `127.0.0.1` and are
  published via Tailscale Serve — nothing listens on LAN or internet
  interfaces, and Tailscale device auth replaces passwords.
- **Tests ship with the service.** `tests/run-tests.sh` runs the real setup
  script against a sandboxed fake server (no system changes) so it can be
  validated before touching a real machine; `--live` verifies an actual
  deployment.

## Prerequisites (all services)

- Linux server with systemd, or macOS (services run as launchd LaunchAgents;
  macOS support is portable by construction, so far verified only on Linux)
- Tailscale installed and logged in (`sudo tailscale up` / the macOS app)
- `curl` (plus Docker Desktop or OrbStack on macOS for Docker-based services)

## Adding a new service

Copy the layout above (see `AGENTS.md` for the full checklist), keep `setup.sh`
idempotent and localhost-bound + Tailscale-published unless there's a strong
reason otherwise, and add a row to the table here.
