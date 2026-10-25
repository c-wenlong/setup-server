# openhands — OpenHands Agent Canvas

Browser UI for coding agents (Claude Code / Codex via ACP) at
`https://homeserver.tail-name.ts.net:8000`. Tailnet only. Not on
the LAN or the public internet.

Paperclip is a **separate** service (`../paperclip/`). This script
deploys Agent Canvas only.

## Architecture

```
  Mac / phone on the tailnet
            │  https://homeserver.tail-name.ts.net:8000
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │
            ▼  http://127.0.0.1:8000
  container: openhands-agent-canvas
  ghcr.io/openhands/agent-canvas  --public, LOCAL_BACKEND_API_KEY
            │
            │  /projects  →  ~/agent-workspaces
            │  ~/.openhands state in ~/services/openhands/data
            └─ optional ~/.claude + ~/.codex mounts (never created here)
```

State:

```
~/services/openhands/data         # Agent Canvas settings + conversations
~/agent-workspaces/               # the only project tree OpenHands can see
  openhands-test/
services/openhands/.env                    # ports + OpenHands API key (gitignored, 600)
services/openhands/docker-compose.creds.yml  # optional host-cred mounts (gitignored)
```

## Why this shape

**OpenHands is the current Agent Canvas image**, not legacy OpenHands 0.x.
Docker, not a host `npx`, so the agent only sees `~/agent-workspaces`
(mounted at `/projects`). `--public` plus a generated
`LOCAL_BACKEND_API_KEY` is the official remote-access lock; Tailscale is
still the network boundary. Telemetry is off.

setup.sh never writes `~/.claude` or `~/.codex`. If those dirs already
exist, a compose overlay mounts them once and is never overwritten.

## Security model

- **Tailnet-only.** The socket binds `127.0.0.1`. Serve terminates TLS.
  No Funnel, no LAN bind, no opened firewall port.
- **API-key gated.** The key is in `.env` (mode 600). Anyone who has it
  can drive the Agent Server; keep it off chat logs.
- **Filesystem.** OpenHands sees `~/agent-workspaces` only. No `/`, no
  `$HOME`, no `--privileged`. The data dir and workspaces are ACL'd for
  the image user (uid `10001`); a host-only `0700` mount makes the
  agent server exit and the UI 502 on `:18000`.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker restart policy | ✅ |
| Docker + Compose v2 | Agent Canvas image | ✅ (incl. daemon reachability) |
| curl | health checks | ✅ |
| Tailscale, logged in, MagicDNS | publishing | ✅ |

Node.js / Paperclip are not required.

## Deploy

```bash
cd services/openhands && ./setup.sh     # idempotent; rerun to upgrade/repair
# current shell lacks the docker group?
sg docker -c ./setup.sh
```

Step by step:

1. **Preflight** — OS, non-root, curl, Docker daemon, Compose v2,
   Tailscale `Running`, numeric ports.
2. **Inspect** Claude / Codex — versions and auth, read-only.
3. **`.env`** — generated once (ports, paths, API keys). If
   `paperclip-openhands/.env` still exists, OpenHands keys are copied
   from it (the API key is **not** rotated).
4. **Workspace** — `~/agent-workspaces/openhands-test`, ACL'd for uid 10001.
5. **Optional creds overlay** if `~/.claude` / `~/.codex` already exist
   (written once, never overwritten).
6. **`docker compose up -d`**. If the old combined compose project still
   owns `openhands-agent-canvas`, that container is removed first so this
   project can recreate it; bind-mount data is unchanged.
7. **Publish** `:8000` with `tailscale serve --bg --https=…`.
8. **Verify** tailnet HTTPS.

Overrides (first run only; `.env` wins after):

```bash
OPENHANDS_PORT=8001 ./setup.sh
```

## Client

From any tailnet device:

1. Open the OpenHands URL, paste `OPENHANDS_API_KEY` from `.env` when
   asked.
2. Pick Claude Code or Codex under Settings → Agent.
3. Open `/projects/openhands-test`.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/openhands \
  ps|logs|restart
tailscale serve status
./tests/run-tests.sh          # mocked
./tests/run-tests.sh --live   # this box; use sg docker if needed
```

Upgrade: edit `OPENHANDS_VERSION` in `.env` then `./setup.sh`, or
`docker compose --project-directory . pull && ./setup.sh`.

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes
`:OPENHANDS_HTTPS_PORT` and runs `compose down`; data, `.env`, the creds
overlay and `~/agent-workspaces` stay, so `./setup.sh` brings it back.
`./teardown.sh --purge` also deletes `OPENHANDS_DATA` and `.env`, after you
type `openhands`. See TROUBLESHOOT.md "Nuke and pave".

## What this does not do

- It does not install or start Paperclip. That is `../paperclip/setup.sh`.
- It does not mount the host filesystem into the container.
- It does not enable Tailscale Funnel.
