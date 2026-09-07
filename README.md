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
