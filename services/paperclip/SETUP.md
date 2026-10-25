# paperclip — Paperclip

Agent control plane (task queue, heartbeats, `claude_local` / `codex_local`)
at `https://kai-home-server.taild6a23f.ts.net:3100`. Tailnet only. Not on
the LAN or the public internet.

OpenHands Agent Canvas is a **separate** service (`../openhands/`). This
script deploys Paperclip only.

## Architecture

```
  Mac / phone on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:3100
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │
            ▼  http://127.0.0.1:3100
  paperclipai.service
  (official managed CLI + embedded Postgres)
            │  claude_local / codex_local
            ▼
  host `claude` / `codex`  (existing logins, untouched)
```

State:

```
~/services/paperclip/             # deploy marker, CEO invite, agent markers
~/.paperclip/                     # official Paperclip instance (config, db, secrets, CLI store)
~/agent-workspaces/paperclip-test # scratch cwd for hired agents
services/paperclip/.env                    # ports + paths (gitignored, 600)
```

## Why this shape

**Paperclip is the official managed install**, not a clone of the repo.
`npx paperclipai install --yes` then `paperclipai onboard --yes --bind
tailnet --no-install-service` is the documented headless path. `--bind
loopback` plus `--yes` would force `local_trusted`, and publishing that
over Serve would hand every tailnet device implicit board authority.
`--bind tailnet` gives `authenticated` + `private`, which is what we want.

Serve proxies `127.0.0.1`, so after onboard the script rewrites
`server.bind` to `loopback` / `127.0.0.1` and allowlists the MagicDNS
name. That pairing — authenticated + loopback behind a reverse proxy — is
what Paperclip's own `DEPLOYMENT-MODES.md` describes. The tailnet IP is
never left listening.

Claude Code is already logged in on this box (`claude.ai` / Max). Codex
is not installed. Paperclip's `codex_local` adapter pins each agent to
its own `CODEX_HOME`, so when Codex does land it will not rewrite
`~/.codex`. setup.sh never writes `~/.claude` or `~/.codex`.

## Security model

- **Tailnet-only.** The socket binds `127.0.0.1`. Serve terminates TLS.
  No Funnel, no LAN bind, no opened firewall port.
- **Authenticated + private**, never `local_trusted` after publish. The
  live suite and the deploy itself die if `local_trusted` is still in
  `config.json`.
- **Secrets master key.**
  `~/.paperclip/instances/default/secrets/master.key` encrypts stored
  credentials. Losing it makes them unreadable. Back it up off this box
  (Seafile at `:8443`). Mode 600; never commit it.
- **No second auth store.** Existing Claude / Codex logins are reused,
  not copied, not rotated.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | systemd user unit / launchd | ✅ |
| Node.js ≥ 24.11.0 | official managed install refuses older | ✅ |
| curl, python3 | health checks + the config patch | ✅ |
| Tailscale, logged in, MagicDNS | publishing | ✅ |
| `claude` on PATH | `claude_local` actually runs | ⚠️ warns |
| `codex` on PATH | `codex_local` actually runs | ⚠️ warns |

Docker is not required. Agent Canvas lives in `services/openhands/`.

## Deploy

```bash
cd services/paperclip && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, curl, python3, Node ≥ 24.11, Tailscale
   `Running`, numeric ports.
2. **Inspect** Claude / Codex — versions and auth, read-only.
3. **`.env`** — generated once (ports, paths, placeholder
   `PAPERCLIP_EMAIL` / `PAPERCLIP_PASSWORD`). Those login keys are not
   applied to the instance yet; edit them in `.env` or the launcher.
   Missing keys are appended on a re-run. If `paperclip-openhands/.env`
   still exists, Paperclip keys are copied from it (nothing is rotated).
4. **Workspace** — `~/agent-workspaces/paperclip-test`.
5. **Paperclip** — managed CLI if missing; `onboard --yes --bind tailnet`
   only when no config exists (`--yes` would otherwise start a foreground
   server and never return); rewrite bind to loopback; allowlist MagicDNS;
   `service install --enable-linger`.
6. **Publish** `:3100` with `tailscale serve --bg --https=…`.
7. **Verify** tailnet HTTPS. Refuse `local_trusted`.
8. **CEO invite** — `paperclipai auth bootstrap-ceo`. Accept it in the
   browser, then hire `claude_local` / `codex_local` (or put
   `PAPERCLIP_COMPANY_ID` + `PAPERCLIP_API_KEY` in `.env` and re-run).

Overrides (first run only; `.env` wins after):

```bash
PAPERCLIP_PORT=3101 ./setup.sh
```

## Client

From any tailnet device:

1. Open the Paperclip URL, accept the CEO invite, create the company.
2. Set (or change) the sign-in email and password on **Settings →
   Profile** (`/company/settings/instance/profile`). Paperclip's own
   Profile form leaves email read-only and has no password field;
   `setup.sh` adds editable ones on that page. Re-run `./setup.sh`
   after `paperclipai update` so the overlay is put back.
3. Hire a `claude_local` agent with cwd
   `/home/kaichen/agent-workspaces/paperclip-test` (or the equivalent on
   another machine). Repeat for `codex_local` once Codex is installed.

## Ops

```bash
paperclipai service status|restart|logs
tailscale serve status
./tests/run-tests.sh          # mocked
./tests/run-tests.sh --live   # this box
./teardown.sh                 # Remove: Serve off, unit disabled; data, .env, ~/.paperclip kept
./teardown.sh --purge         # also .env, unit file, markers (back up master.key first)
```

Upgrade: `paperclipai update` (hot-restarts the service), then re-run
`./setup.sh` so the Profile overlay is put back.

## What this does not do

- It does not install or start OpenHands. That is `../openhands/setup.sh`.
- It does not install Codex. The adapter is ready; the binary is not here.
- It does not accept the CEO invite for you. That is a browser step.
- It does not enable Tailscale Funnel.
