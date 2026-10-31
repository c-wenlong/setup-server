# ollama

Local model runtime for every other service on the box — Open WebUI chats
through it, n8n workflows call it. No web UI of its own; it is a backend,
deliberately reachable from `127.0.0.1` only and never published through
Tailscale Serve.

## Architecture

```
other services on this box        (Open WebUI, n8n, …)
        |
        v   http://127.0.0.1:11434
  ollama serve          ← systemd *user* unit  (~/.config/systemd/user/ollama.service)
        |                  Restart=always + lingering = starts at boot
        v
  ~/.ollama/models      ← pulled models (the disk weight — ~5 GB each)
```

Two Linux paths coexist with the same end state:

- **Fresh box** — the official tarball lands in `~/.local` (no sudo).
- **Stock install present** — a system unit `/etc/systemd/system/ollama.service`
  (running as user `ollama`, possibly with an `OLLAMA_HOST=0.0.0.0` override
  that binds `*:11434` to the LAN) is **stopped and disabled once, with sudo**,
  and its `/usr/local/bin/ollama` binary is reused by the user unit.

Why a *user* unit and not the stock system one: the launcher's
start/stop/restart buttons work through `systemctl --user`, which has no
sudo path — a system unit could never be controlled that way. The migration
also retires the `0.0.0.0` bind for good.

## Security model

- Binds `127.0.0.1:11434` only (`OLLAMA_HOST` in the unit). Loopback means
  every service on the box can call it and nothing off-box can — the
  tailnet needs no rule at all. The API has no auth; that is fine because
  only local processes reach it.
- No Tailscale Serve mapping is created. That is deliberate: other *apps*
  on this box are the consumers. If you want a remote client to reach it,
  publish the frontend (e.g. Open WebUI), not this.
- Sudo is needed at most once — retiring a live stock system unit — and
  again only if lingering is not already on.

## Dependencies

| Need | Used for |
|---|---|
| Linux + systemd user session | the unit |
| macOS + launchd | the LaunchAgent |
| curl | tarball download, health probe |
| `loginctl` (Linux) | lingering |
| sudo (Linux, once) | `systemctl disable --now ollama.service` on the stock unit, `loginctl enable-linger` |

## What setup.sh does, step by step

1. **Preflight** — refuses root, needs curl + (Linux) systemctl. The port
   is fixed at `11434`: the launcher's health probe and seed_kuma's monitor
   both assume it.
2. **Binary** — reuses `~/.local/bin/ollama`, then `command -v ollama`
   (covers a stock `/usr/local/bin/ollama`); otherwise downloads
   `ollama-linux-<arch>.tgz` into `~/.local`. On macOS it uses
   `brew install ollama` (there is no standalone darwin tarball).
3. **Retire the stock system unit (Linux)** — if `systemctl cat
   ollama.service` finds a unit file that is still enabled or active:
   `sudo systemctl disable --now ollama.service`. The unit file is left on
   disk; an existing `/usr/share/ollama/.ollama` (the *system* user's model
   store) is reported but never migrated — pull again as yourself or copy
   with sudo.
4. **Service** — writes `~/.config/systemd/user/ollama.service`
   (`ExecStart=<bin> serve`, `OLLAMA_HOST=127.0.0.1:<port>`,
   `Restart=always`) and `systemctl --user enable + restart`. macOS writes
   `~/Library/LaunchAgents/ai.ollama.serve.plist` and bootstraps it.
5. **Health** — waits for `http://127.0.0.1:<port>/api/version`.
6. **Lingering (Linux)** — `sudo loginctl enable-linger` once, so the unit
   starts at boot without a login.

Re-running is idempotent: binary reused, unit rewritten and restarted, no
sudo when there is nothing left to retire.

## Client-side / usage

- `ollama pull qwen3:4b` — models land in `~/.ollama/models`.
- Other services point at `http://127.0.0.1:11434` (Open WebUI's
  `OLLAMA_BASE_URL`, n8n's Ollama node).
- The launcher's ollama tile shows live status and Start/Stop/Restart —
  the tile never navigates (no UI to open).

## Ops commands

```bash
systemctl --user status|restart ollama       # service
journalctl --user -u ollama -f               # logs
ollama list                                  # pulled models
ollama ps                                    # what is loaded right now

./teardown.sh            # stop + disable; binary and models kept
./teardown.sh --purge    # also delete ~/.ollama (models) and the unit file
```

A retired stock unit still has its file at
`/etc/systemd/system/ollama.service` — leave it disabled; delete it by hand
only if you never want the packaged install back.
