# deployd: push-to-deploy poller for a tailnet-only box

The box cannot receive GitHub webhooks (nothing inbound), so deployd polls
outbound instead: one oneshot every `POLL_SECONDS` (default 60 s) that pulls
this checkout, then runs each opted-in service's deploy command when its
watched git ref moves. It replaces per-service deploy timers — one clock,
every service.

## Architecture

```
setup-server checkout                      ~/services/deployd/
─────────────────────                      ────────────────────────────────
services/*/app.json                        bin/deployd      installed poller
  "deploy": { repo, ref, cmd }      ──▶    state/<key>.sha  last deployed sha
            ▲ git ls-remote                state/<key>.fail  retry backoff
            │ remote moved?                state/<key>.log   last output tail
            ▼                              .poll.lock        mkdir lock
      bash -c "<cmd>"  (cwd = repo root,
      DEPLOY_SHA/REF/NAME/REPO in env)
```

Each tick:

1. `git pull --ff-only` the checkout — deploy config lives in the repo, so
   the config self-updates. If the pull touched `services/deployd/` the
   poller re-runs its own `setup.sh` (self-update; the running tick finishes
   on the old build, the next tick uses the new one). A failed self-update
   leaves `state/self-update.pending` behind and is retried every tick
   until it succeeds — on macOS that child run skips re-loading the
   LaunchAgent (bootout would kill the tick itself), so plist changes land
   on the next manual `setup.sh` or login. The launcher gets the same
   treatment: a pull touching `app/web/` (except `static/` and
   `services.json`, which it re-reads live) restarts its unit so the new
   `server.py` loads — a stopped or absent launcher just drops the
   `state/launcher-restart.pending` marker, a failed restart keeps it.
   Changes to `app/web/setup.sh` only log a hint: unit/plist changes need
   a manual re-run.
2. Scan `services/*/app.json` for `deploy` blocks.
3. Per entry: `git ls-remote <repo> <ref>` → sha. Same as
   `state/<key>.sha` → done. Different → run `cmd`. Success → record the
   sha; failure → record `.fail` and back off `RETRY_SECONDS` before trying
   that sha again (clear the file or `--force` to retry early). One entry's
   failure never blocks another's.

## The `deploy` block

A service opts in inside its own `app.json` — the config travels with the
service definition:

```json
"deploy": {
  "repo": "https://github.com/c-wenlong/quiver.git",
  "ref": "main",
  "cmd": "QUIVER_REF=$DEPLOY_SHA QUIVER_TRACK=$DEPLOY_REF services/quiver-hub/setup.sh"
}
```

- `repo` — git URL `ls-remote` polls. Required.
- `ref` — branch or tag name, or a full 40-char sha (then no lookup is
  needed; `main` is the default when omitted).
- `cmd` — shell run via `bash -c` with the checkout as cwd. `$DEPLOY_SHA`,
  `$DEPLOY_REF`, `$DEPLOY_NAME`, `$DEPLOY_REPO` are in the environment; the
  pinned-sha form above avoids a second resolve race. The command must be
  idempotent — it is the same `setup.sh`/`deploy.sh` you would run by hand.
- `"enabled": false` — optional; keeps the block but skips it.

Trust: a `deploy` block runs as this user, so pushing to this repo can make
the box run anything — the same trust already granted to `setup.sh` files.
Keep the checkout on a branch only you push to.

## Install

```sh
cd services/deployd && ./setup.sh
```

Writes `.env` (below) on first run, installs `~/services/deployd/bin/deployd`,
then the poller — `deployd.timer` + `deployd.service` under
`~/.config/systemd/user/` on Linux (with lingering), or the
`com.setup-server.deployd` LaunchAgent on macOS — and runs one tick to prove
the wiring.

## `.env` fields

| Key | Default | Meaning |
|---|---|---|
| `SETUP_REPO` | the checkout this setup.sh sits in | the repo pulled + scanned each tick |
| `SERVICE_HOME` | `~/services/deployd` | state + lock + installed bin |
| `POLL_SECONDS` | `60` | poll cadence (baked into the timer — re-run setup.sh to change) |
| `RETRY_SECONDS` | `900` | backoff before retrying a failed deploy of the same sha |
| `DEPLOY_TIMEOUT` | `1800` | per-cmd cap in seconds |
| `PATH_PREFIX` | dirs of git/python3/uv/curl/docker/tailscale at setup time | prepended to PATH for the poller and every cmd (systemd/launchd PATHs lack userland tools) |

## Operate

```sh
~/services/deployd/bin/deployd --status         # entries, deployed shas, failures
~/services/deployd/bin/deployd --force <key>    # deploy one service now
                                                # (takes the same lock —
                                                # refuses while a poll runs)
journalctl --user -u deployd -n 100 --no-pager  # tick + deploy logs (Linux)
tail -f ~/Library/Logs/deployd.log              # macOS
systemctl --user list-timers deployd.timer      # next tick
```

## Disable / re-enable a service

A service's `teardown.sh` drops `state/<key>.disabled` so the next push to
its repo does not resurrect a service you just removed. Ticks skip it,
`--force` refuses it, and `--status` marks it `disabled`. To re-enable: run
the service's `setup.sh` again (it clears the flag), or delete the flag file
by hand.

## Notes

- No port, no container, nothing published — deployd is outbound-only. It
  is not a row in the launcher's app list (`"hidden": true` in `app.json`,
  `NO_TILE` in `scripts/check-structure.sh`): the launcher's **Deploys** page
  (`#/deploys`, in the sidebar) is its UI, with the timer's state, Pause /
  Resume, every watched repo and add / edit / delete for
  `state/pollers.json` entries. No Kuma monitor (nothing HTTP to probe; a dead timer is surfaced by
  the deploys not happening, and `--status` shows recorded state).
- `deployd` deliberately does not stop a poll mid-deploy; teardown refuses
  while the lock is fresh rather than kill another service's setup.sh.

## Update / Remove

- `./setup.sh` again — refreshes the poller + units; never rewrites `.env`.
- `./teardown.sh` — disables the timer/agent, keeps everything else.
- `./teardown.sh --purge` — also deletes `~/services/deployd` and `.env`
  (asks for `deployd` typed confirmation).

## Tests

```sh
./tests/run-tests.sh          # mocked suite — no host changes
./tests/run-tests.sh --live   # + asserts the real timer/agent is up here
```
