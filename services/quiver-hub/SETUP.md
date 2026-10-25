# quiver-hub: Quiver's remote-control hub, tailnet-only

Runs `swe remote serve` from [Quiver](https://github.com/c-wenlong/quiver) on
an always-on box, so a phone on the tailnet can watch and steer coding-agent
sessions (sessions, inbox, Usage tab) and laptops can join as satellites.
Reachable only from your Tailscale devices at
`https://<host>.<tailnet>.ts.net:8477`.

## Architecture

```
phone (PWA) ──HTTPS──▶ Tailscale Serve (:8477) ──▶ swe remote serve (127.0.0.1:8477)
MacBook ─────HTTPS──▶      (tailnet only)              │ hub: catalog, journals, REST + SSE
  `swe remote agent`                                   │ state: ~/.quiver/data/remote/
  (dials out, nothing listens on the Mac)              ▼
                                               sessions on this box
                                               (~/.claude, ~/.codex, ... via claude/codex/tmux)
```

Security model:

- The hub binds `127.0.0.1` only. Tailscale Serve terminates TLS and is the
  only way in, so only tailnet devices reach it.
- Every API route except `/v1/status` and the pairing routes wants a
  per-device bearer credential from `~/.quiver/data/remote/devices.json`
  (0600). A device gets one by **Pair with Tailscale** (the hub identifies
  the tailnet node with `tailscale whois`, and you approve its 6-digit code
  on the hub or from a paired device) or by exchanging a single-use,
  5-minute pair token (`./pair.sh`). Revoking a lost phone is
  `swe remote devices --revoke=<id>`, without touching the tailnet.
- The unit runs `swe remote serve --public-url=https://<host>:<HTTPS_PORT>`
  (quiver 6c70755, #570). With it, the hub trusts Serve's
  `X-Forwarded-For`/`-Proto` headers, but only from loopback peers, which
  behind Serve is tailscaled. That is how whois sees the real phone instead
  of `127.0.0.1`. It also makes the hub hand out https pair links and ntfy
  buttons, and accept https `Origin`s on the approval routes. The flip
  side: any process on this box can set those headers. It runs as a user
  who could read `devices.json` anyway, so this only matters if other,
  untrusted accounts share the box.
- The hub executes on this box by design: an attached session runs
  `claude -p`, `codex app-server` or tmux as you. The credential gates that.

Quiver's own design binds the hub to the tailnet IP instead. That is not done
here: AGENTS.md allows a tailnet-IP bind only for protocols Serve cannot
carry, and this is plain HTTP + SSE.

## Dependencies

| Component | Role | Installed as |
|---|---|---|
| quiver (`swe`) | The hub, the PWA it serves, `swe remote pair/devices` | uv tool in `~/.local/share/quiver-hub/` (pinned commit) |
| uv | Installs quiver from git, provides Python >= 3.11 if the system's is older | Prerequisite (`curl -LsSf https://astral.sh/uv/install.sh \| sh`) |
| git | `git ls-remote` to resolve `QUIVER_REF` to a commit | Prerequisite |
| systemd (user) / launchd | Keeps the hub running, starts it at boot/login | `~/.config/systemd/user/quiver-hub.service` / `~/Library/LaunchAgents/com.setup-server.quiver-hub.plist` |
| tailscaled + Serve | WireGuard mesh, HTTPS termination, tailnet-only exposure | System service (prerequisite) |
| claude, codex, tmux, opencode | Harnesses the hub tails and drives | Whatever is on the user PATH (see below) |

### Why a dedicated uv tool dir

The `swe` on your interactive PATH is a separate install. On this box it is
the home-manager build from `~/dotfiles` (Nix, pinned in that repo's
`flake.lock`), and on a Mac it may be Nix, brew or `uv tool`. The hub needs a
build new enough to have `swe remote`, and it must not move when some other
tool upgrades or rolls back the interactive one. So `setup.sh` gives the hub
its own uv tool dir and bin dir (`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` under
`~/.local/share/quiver-hub/`):

- **Pinnable**: `QUIVER_REF` is resolved to a full commit with
  `git ls-remote`, installed as `quiver @ git+https://...@<sha>`, and the
  commit is recorded in `~/.local/share/quiver-hub/installed-rev`.
- **Idempotent upgrade**: a re-run resolves the ref again and reinstalls only
  if the commit moved. `QUIVER_REF=main` (the default) means "track main".
- **A bad upgrade can't take the hub down**: each commit installs into its
  own `releases/<sha>/` (a forced reinstall of the live commit uses
  `releases/<sha>.<epoch>/`) and is checked for `swe remote serve` there.
  Only then does `~/.local/share/quiver-hub/bin` (a symlink, and the path
  the unit runs) move to it. A failed or too-old install is deleted and the
  live build is untouched. The build it replaced is kept for a manual
  rollback. In `~/.local/share/quiver-hub`, `readlink bin` names the live
  directory and `ls releases/` shows it and the kept one. Then
  `ln -sfn releases/<kept dir name>/bin bin` (the full name, suffix
  included), write its 40-char sha (the name without the `.<epoch>` part) to
  `installed-rev`, and restart the unit.
- **No Nix requirement**: the flake would pin just as well, but this repo
  targets plain Linux and macOS boxes, and quiver's core is stdlib-only, so
  a wheel install is all it needs.

The Nix flake (`github:c-wenlong/quiver`) was the other option. It would tie
the deploy to Nix being present and to a `nix build` (which runs quiver's
whole test suite) on every upgrade.

`setup.sh` warns when the `swe` on PATH has no `swe remote`. Until that
install is upgraded (on this box: bump the `quiver` input in `~/dotfiles`),
run hub-side commands with the hub's build: `~/.local/share/quiver-hub/bin/swe`.

## Deploy

Prerequisites: Linux with systemd or macOS, curl, git, uv, Tailscale logged in.

```sh
./setup.sh                               # local 8477, HTTPS 8477, quiver main
LOCAL_PORT=8478 ./setup.sh               # first run: HTTPS follows LOCAL_PORT
QUIVER_REF=680d9d010aec... ./setup.sh    # install this commit (or a tag/branch) this run
```

`.env` (gitignored, written once) records `LOCAL_PORT`, `HTTPS_PORT` and
`QUIVER_REF`. After the first run it is the source of truth: a different
`LOCAL_PORT` on the command line is ignored with a warning. Edit `.env` and
re-run to move a port or change the tracked ref; an explicit `QUIVER_REF=`
on the command line wins for that run only.

Sudo is needed at most twice on Linux, one time each:

1. `loginctl enable-linger`: user services start at boot, survive logout
2. `tailscale set --operator=$USER`: manage Serve without root

On a tailnet that has never used Serve, it pauses once with an approval URL.

What it does, in order:

1. Preflight: Linux/macOS, not root, curl + git + uv, Tailscale running,
   MagicDNS name
2. Writes `.env` if absent, reads it back
3. Refuses `HTTPS_PORT=443` (a bare `--https=443` would replace
   code-server's `/`) and any HTTPS port Serve already maps to another backend
4. Resolves `QUIVER_REF` to a commit; installs it with `uv tool install`
   unless that commit is already installed
5. Checks the build has `swe remote serve --public-url` (quiver 6c70755 or
   later), so a too-old pin never becomes a crash-looping unit
6. Writes and (re)starts the systemd user unit / LaunchAgent:
   `swe remote serve --host=127.0.0.1 --port=$LOCAL_PORT
   --public-url=https://<host>:$HTTPS_PORT`, `Restart=always`. On start the
   hub writes `~/.quiver/data/remote/hub.json`, which `swe remote pair` and
   `swe remote status` read, so neither needs flags
7. Waits for `GET /v1/status` → `{"ok": true}` on loopback
8. Enables lingering (Linux, only if off)
9. `tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$LOCAL_PORT`
10. Verifies `https://<host>:$HTTPS_PORT/v1/status` end to end

The unit's `PATH` is spelled out because a user unit starts with a minimal
one: the hub's own bin dir first (so any `swe` it spawns is the same build),
then `~/.nix-profile/bin`, `~/.local/bin`, `~/.npm-global/bin` and the system
dirs, which is where `claude`, `codex` and `tmux` live on this box. A harness
installed somewhere else needs that line extended in `setup.sh`.

## Pairing

### Phone (PWA)

1. Open `https://<host>:8477/` on the phone (Safari on iPhone) and tap
   **Pair with Tailscale**. It shows a 6-digit code.
2. Approve it on the hub: `~/.local/share/quiver-hub/bin/swe remote devices
   --approve=<code>` (`--requests` lists pending ones). Or approve from a
   device that is already paired, on its `#approve` page. A device can't
   approve its own request, and the request expires after 5 minutes.
3. Share → **Add to Home Screen** for the app icon.

By token instead (for a device Tailscale can't identify): `./pair.sh iphone`
prints `https://<host>:8477/#pair=<token>&name=iphone`; open it on the phone,
or paste the token into **Have a pair token?**. Single use, 5 minutes.

### MacBook as a satellite

On the hub run `./pair.sh macbook`, then on the Mac (any `swe` with
`swe remote`):

```sh
swe remote agent --hub=https://homeserver.tail-name.ts.net:8477 --token=<token>
```

The first run exchanges the token for a stored credential; after that
`swe remote agent` alone reconnects. Keep it running. It dials out only, so nothing listens on the
Mac. Its sessions and its usage figures (pushed every 300 s) appear on the
hub, and a sleeping Mac shows as offline with its last usage report.

### Managing devices (on the hub)

```sh
S=~/.local/share/quiver-hub/bin/swe
$S remote devices                     # list paired devices
$S remote devices --revoke=<id>       # lost phone
$S remote devices --requests          # pending "Pair with Tailscale" requests
$S remote status                      # probes 127.0.0.1 via hub.json
```

## Behind Serve

The hub was first written to bind the tailnet IP and talk to clients
directly. Until quiver 6c70755 (#570), running it behind Serve meant it saw
every client as `127.0.0.1` and advertised `http://127.0.0.1:8477`. So
"Pair with Tailscale" answered 403 `not_tailnet`, `swe remote pair` printed
an http link, ntfy buttons pointed at loopback, and browser approval was
refused on `Origin`. `--public-url` fixes all four; `setup.sh` refuses older
builds rather than run them without it.

## Operations

```sh
systemctl --user status quiver-hub.service      # is it running?
journalctl --user -u quiver-hub.service -f      # live logs
systemctl --user restart quiver-hub.service
tailscale serve status                          # expect :8477 / proxy http://127.0.0.1:8477
tailscale serve --https=8477 off                # unpublish (this port only)
./teardown.sh                                   # Remove: unpublish + stop; .env, unit, build kept
./teardown.sh --purge                           # also delete .env + unit file (asks for the name)
./setup.sh                                      # upgrade to the current QUIVER_REF tip
cat ~/.local/share/quiver-hub/installed-rev     # which quiver commit is running
```

State: `~/.quiver/data/remote/` (devices, pair tokens, per-session journals,
transcript cursors, satellite usage reports). It stays in quiver's default
location rather than `~/services/quiver-hub` because the interactive
`swe remote pair` and `swe remote devices` read and write the same files the
running hub does. Back it up if you don't want to re-pair devices.

## Tests

```sh
./tests/run-tests.sh          # mocked suite: sandboxed, no system changes
./tests/run-tests.sh --live   # + verify the real deployment on this machine
```

The mocked suite runs the real `setup.sh` and `pair.sh` from a sandbox copy
of this directory with a fake `$HOME` and PATH stubs for curl, git, uv,
tailscale, sudo, systemctl, loginctl, launchctl, id, sleep and an old
interactive `swe`. It covers the fresh install, an idempotent re-run (no
reinstall, no sudo, `.env` kept), upgrade when main moves, pinning by SHA and
by tag, unknown refs, GitHub or uv failures, a too-old quiver (no `swe remote`, or no `--public-url`), port
overrides and `.env` precedence, the `:443` refusal, an HTTPS port owned by
another service, a hub that never gets healthy, the Serve approval loop, and
`pair.sh`'s https links, and `teardown.sh` (only this hub's Serve ports go
off, the unit is disabled, `--purge` confirmation and path guards, `~/.quiver`
and units it did not write left alone).

The live suite checks the unit is active and enabled, lingering, the unit
binds 127.0.0.1, `/v1/status` on loopback and over the tailnet, no listener
on a LAN interface, the Serve mapping, the PWA at `/`, and that the API
refuses a request without a device credential (401). It also checks the unit
passes `--public-url`, the hub saved it to `hub.json`, and `swe remote pair`
hands out an `https://` link (this mints one real token, unused, which
expires after 5 minutes).
