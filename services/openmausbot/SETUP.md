# OpenMausBot setup

[OpenMausBot](https://github.com/milind-soni/OpenMausBot) is an open-source
Grokbot-style workspace: persistent AI bots, each with its own files and
memory, driven from a browser. One Node process serves both the web UI and
the owner API.

## Architecture

```
MacBook / phone browser
        |  HTTPS, tailnet-only
        v
Tailscale Serve  :8799  (TLS terminates here; nothing public)
        |  proxy
        v
openmausbot serve   127.0.0.1:8799   (web UI + owner API)
        |  spawns per-bot sessions
        v
engine CLIs on this box (claude, codex, opencode, ...)  -- as THIS user
```

- The server hard-binds `127.0.0.1`; it never listens on a LAN interface.
  Upstream also runs a webhook receiver on `127.0.0.1:OMB_PORT+1` (8800) —
  loopback too, and deliberately not published (`OMB_WEBHOOK_PUBLIC_URL`
  stays unset so automation addresses are shown honestly as local).
- Tailscale Serve is the only way in. We never use upstream's `--tunnel`
  (vendor tunnel) or `--domain` (public Caddy on 80/443).
- Local port and the published HTTPS port are both `8799` by default
  (`OMB_PORT` / `HTTPS_PORT` in `.env`); the tailnet URL is
  `https://<tailnet-host>:8799`.

## Prerequisites

- **Node.js >= 24** and `npm` on PATH.
- **Tailscale** running with HTTPS/Serve enabled in the tailnet
  (`tailscale up`). First Serve use may print an admin approval link —
  that is a one-time tailnet setting.
- A regular (non-root) user. On Linux the script needs `sudo` once, for
  `loginctl enable-linger` and `tailscale set --operator`.

| Dependency | What it is for | How it is supplied |
|---|---|---|
| Node.js >= 24 + npm | Runs the server; `npm install -g` installs it | You install it (nvm, brew, distro) before running |
| curl | Local health probe and the end-to-end tailnet check | OS package manager |
| Tailscale | The only external access path (HTTPS Serve on the tailnet) | Installed and logged in (`tailscale up`); HTTPS/Serve enabled in the tailnet admin console — a one-time toggle the script's retry loop points at |
| systemd --user + `loginctl` | Keeps the server alive and starting at boot (Linux) | Standard on the target distro |
| launchd | Keeps the server alive and starting at login (macOS) | Built into macOS |
| sudo (Linux only, first run) | `loginctl enable-linger` + `tailscale set --operator` | Interactive, once per box |

## What the script does

1. Preflight: Linux or macOS, not root, `node --version` >= 24, npm present,
   Tailscale up, tailnet DNS name resolvable.
2. npm global install: `npm install -g openmausbot` under a prefix inside
   `$HOME` (moves the prefix to `~/.local` first if npm's is system-owned,
   e.g. `/usr`). No sudo, no `npx` cache for the daemon.
3. Writes `services/openmausbot/.env` **only if absent** (mode 600):
   `OMB_PORT`, `HTTPS_PORT`, `OMB_DATA_DIR=~/services/openmausbot/data`,
   `OMB_PUBLIC_URL`, `OMB_LOOPBACK_TRUST=owner`, plus `NODE_BIN`, `NPM_BIN`,
   `OMB_BIN` so the unit knows where the toolchain lives. An existing `.env`
   wins over CLI port flags (a warning says so).
4. Installs a **systemd user unit** (`~/.config/systemd/user/openmausbot.service`,
   `Restart=always`, `EnvironmentFile=` the `.env`, `PATH=` the npm bin dir +
   node dir) or a **LaunchAgent** (`~/Library/LaunchAgents/com.openmausbot.server.plist`)
   on macOS. Both run `openmausbot serve --no-pair` — `--no-pair` because the
   service must never spew pairing codes into a journal on every start.
5. `loginctl enable-linger` (Linux) so the unit survives logout/reboot.
6. Waits for `http://127.0.0.1:8799/api/health`, publishes
   `tailscale serve --bg --https=8799 http://127.0.0.1:8799`, then verifies
   the tailnet URL end-to-end.
7. Prints the URL. It never prints a pairing code, token, or credential.

## After install (manual, one-time)

The web UI is at `https://<tailnet-host>:8799` on every tailnet device, but a
browser is not trusted until it is **paired**:

```sh
openmausbot pair --label "kai macbook"
```

Run it on the box as the service user. It prints a `/pair#code=...` link
(interactive sessions only — codes are never written to the journal); open
that link in the MacBook browser once. Repeat per browser/device.

Engines are separate sign-ins, also as the service user on the box:

```sh
claude auth        # Claude Code
codex auth         # Codex
```

OpenMausBot launches whichever engine a bot is configured to use; unverified
engines (Cursor) are not configured by this deploy.

### Devin over ACP (optional)

Upstream ships a generic `customAcp` engine for any agent CLI speaking the
Agent Client Protocol over stdio, and the Devin CLI is itself an ACP server
(`devin acp`). Two gaps need a shim, shipped as `contrib/devin-acp`:

- OMB's version probe appends `--version` to the whole cli; `devin acp`
  rejects unknown flags, so the shim routes the probe at `devin --version`.
- `devin acp` ignores local credentials by design — the ACP *host* must call
  `authenticate` with `params._meta.api_key`. customAcp never authenticates,
  so the shim injects the call itself after `initialize`, reading the key
  from `~/.local/share/devin/credentials.toml` (created by `devin auth login`).

```sh
devin auth login                                    # as the service user
install -m 755 contrib/devin-acp ~/.local/bin/      # set DEVIN inside to the
                                                    # absolute `which devin`
```

Then add an engine instance (UI: Settings → Engines, or `instances` in
`data/config.json`; if `instances` is written by hand it **replaces** the
default fleet, so include every entry you want to keep):

```json
"devin": { "driver": "customAcp", "displayName": "Devin",
           "config": { "cli": "/home/USER/.local/bin/devin-acp" } }
```

Or patch a running server (loopback owner trust, no restart):

```sh
curl -X PATCH http://127.0.0.1:8799/api/instances/devin \
  -H 'content-type: application/json' \
  -d '{"cli":"/home/'"$USER"'/.local/bin/devin-acp"}'
```

The engine then reports `available` and exposes Devin's model catalog in the
model picker. If a turn fails with an auth error, the stored key is stale:
`devin auth logout && devin auth login` on the box.

## Trust model

`OMB_LOOPBACK_TRUST=owner` (the upstream default for self-hosting) means any
**process on this box** that can reach `127.0.0.1:8799` acts as owner without
pairing. That is deliberate: it keeps local CLI commands (`pair`, `sessions`,
`browser install`) working. `service` trust was rejected — upstream refuses
CLI pairing under it, which would make browser pairing impossible to mint.
The owner API is still unreachable from anywhere except this box and paired
tailnet browsers, because the only listener is loopback and the only external
path is Tailscale Serve.

## Ops

```sh
systemctl --user status|restart openmausbot   # manage the unit
journalctl --user -u openmausbot -f           # logs
launchctl print gui/$UID/com.openmausbot.server   # macOS
tailscale serve status                        # the publish
./tests/run-tests.sh                          # mocked suite
./tests/run-tests.sh --live                   # verify this deployment
./teardown.sh                                 # remove service + publish, keep data
./teardown.sh --purge                         # also delete .env + ~/services/openmausbot
```

Re-running `setup.sh` is safe: it upgrades the npm package, rewrites the
unit, restarts, and re-asserts the Serve publish. `.env` and
`~/services/openmausbot/data` (bots, chats, memories, browser profile) are
never overwritten.
