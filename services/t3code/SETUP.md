# t3code: T3 Code, tailnet-only

Runs upstream's [`t3 serve`](https://github.com/pingdotgg/t3code) on an
always-on box, so any browser on the tailnet can watch and steer the coding
agents (Claude Code, Codex, Cursor, Devin, …) running on
this machine. Reachable only from your Tailscale devices at
`https://<host>.<tailnet>.ts.net:8109`.

## Architecture

```
browser ──HTTPS──▶ Tailscale Serve (:8109) ──▶ t3 serve (127.0.0.1:8109)
  (any tailnet device)      (tailnet only)         │ web UI + WebSocket
                                                   │ state: ~/services/t3code
                                                   ▼
                                          agent CLIs on this box
                                          (claude, codex, cursor-agent,
                                           devin, gh, tmux — via PATH)
```

Security model:

- `t3 serve` binds `127.0.0.1` only. Tailscale Serve terminates TLS and is
  the only way in, so only tailnet devices reach it.
- Pairing is the app-level gate: the first browser to connect is paired,
  and other devices get in with a token from `t3 pair`. That is upstream's
  model; this script does not add a substitute password.
- The unit's `PATH` puts `~/.nix-profile/bin`, `/nix/var/nix/profiles/...`,
  `~/.local/bin` and `~/.npm-global/bin` first, because a systemd user unit
  starts with a minimal `PATH` and t3 orchestrates the agent CLIs installed
  there. Keep agent CLIs in one of those places (or edit the unit's
  `Environment=PATH` — it is regenerated on every `setup.sh` run, so put
  customisations in `.env`/upstream config instead).
- State lives in `~/services/t3code` (`--base-dir`): projects, threads,
  paired devices. It is deleted only by `teardown.sh --purge`.
- The release lives in `~/.local/share/t3code` (`releases/<ver>` + `bin`
  symlink). `installed-ver` records what is live; the previous release is
  kept for rollback.

## Dependencies

| Component | Role | Installed as |
|---|---|---|
| `t3` | The service itself | Upstream release tarball, fetched by setup.sh (not Nix — this repo deploys to any box) |
| `curl`, `tar` | Download + extract | OS packages |
| systemd `--user` + lingering (Linux) / launchd LaunchAgent (macOS) | Keepalive | OS |
| Tailscale | Serve publish + tailnet boundary | OS |

`uname -m` picks the asset: `linux-x64`, `linux-arm64`, `darwin-arm64`.
Upstream ships **no Intel-Mac build** — `Darwin/x86_64` is refused.

## What setup.sh does

1. Preflight: regular user, `curl`+`tar`, systemd/launchd, Tailscale up,
   supported OS/arch. Resolves the tailnet DNS name.
2. Writes `.env` on first run only (`LOCAL_PORT`, `HTTPS_PORT`,
   `T3_VERSION`), then reads it back — `.env` wins over environment
   variables on every re-run, so a live deployment never silently moves.
   Refuses `HTTPS_PORT=443` (that is code-server's `/` handler on this
   box) and refuses to publish over a Serve port already owned by another
   target.
3. Resolves `T3_VERSION`: `latest` (default) follows the GitHub
   `releases/latest` redirect and upgrades when it moved; `0.1.8`/`v0.1.8`
   pins. Downloads `t3-<ver>-<target>.tar.gz`, extracts to
   `releases/<ver>`, flips the `bin` symlink, prunes all but live+previous.
4. Writes the systemd user unit (`t3code.service`) or LaunchAgent
   (`com.setup-server.t3code`) running
   `t3 serve --host=127.0.0.1 --port=$LOCAL_PORT --base-dir=$DATA_DIR`,
   enables + restarts it.
5. Waits for `http://127.0.0.1:$LOCAL_PORT/` to answer, enables lingering
   on Linux (sudo, first run only).
6. Publishes `https://<host>:<HTTPS_PORT>` → the loopback port via
   `tailscale serve --bg` (operator grant once if needed; approval-link
   retry loop if Serve demands it). Never `serve reset`.
7. End-to-end HTTPS check and prints the URL + manage commands.

## Client-side setup

- Open `https://<host>.<tailnet>.ts.net:8109/` in a tailnet browser. The
  first visit pairs it.
- Another device: on the box run
  `t3 pair --base-dir ~/services/t3code` — it prints a QR code / link
  (5-minute TTL). The `--base-dir` must match the unit's or it will not
  find the running server.

## Ops

```bash
./setup.sh                    # upgrade to latest / repair
LOCAL_PORT=8110 ./setup.sh    # first run only — .env wins afterwards
T3_VERSION=0.1.8 ./setup.sh   # pin this run; or set it in .env
systemctl --user status t3code.service
journalctl --user -u t3code.service -f
tailscale serve status        # or: tailscale serve --https=8109 off
./teardown.sh                 # remove, keep data
./teardown.sh --purge         # also delete ~/services/t3code + .env
./tests/run-tests.sh --live   # verify this deployment
```
