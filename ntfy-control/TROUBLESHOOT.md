# ntfy-control — troubleshooting

Layered triage: phone → ntfy server → listener → registry → the action itself.

## What is controllable is not in this directory

The listener has **no hard-coded service list**. It reads the `control` block
of each entry in `launcher/services.json` — the single registry the launcher's
web UI reads for the same purpose, so the phone panel and the launcher's
start/stop buttons can never disagree. Adding a service to the panel means
adding a `control` block there, not editing `control_listener.py`.

The file is re-read whenever its mtime changes, so an edit takes effect
without restarting the listener. On startup (and on each reload) it logs which
file won:

```
control registry: 19 services from /home/kaichen/dev/setup-server/launcher/services.json
```

Trust that line over this one — controllable as of 2026-09-12 (19, up from
the original 6): `adguard`, `beszel`, `code-server`, `firefly-iii`, `forgejo`,
`home-assistant`, `homepage`, `immich`, `jellyfin`, `kaichenpedia`, `manimkc`,
`n8n`, `open-webui`, `paperless-ngx`, `remote-desktop`, `seafile`,
`syncthing`, `uptime-kuma`, `vaultwarden`.
Send `panel` for the button menu, or `pick stop` for a picker.

`ntfy`, `ollama` and `launcher` are **locked out in code** (`HARD_LOCKED` in
`control_listener.py`), checked *before* the registry — so adding a `control`
block for them in `services.json` cannot re-enable them. Stopping ntfy or the
launcher would remove the only way to start anything again; ollama is a system
unit and this endpoint deliberately has no sudo path.

## Quick status

```sh
systemctl --user is-active ntfy-control            # listener up?
journalctl --user -u ntfy-control -n 20            # what it saw/did + registry line
curl -fsS http://127.0.0.1:3003/v1/health          # ntfy up? {"healthy":true}
curl -d "status" http://127.0.0.1:3003/control     # end-to-end from the box
```

The last one really does push a card to the phone — it is the end-to-end test,
not a silent read. `status`, `list` and `menu` are all aliases for `panel`.

## Layer 1 — nothing happens when I send a command

- **From the box**, run `curl -d "status" http://127.0.0.1:3003/control`.
  If a reply lands in the `alerts` topic, the server side is fine — the
  problem is the phone (Layer 0 below).
- No reply → is the listener running?
  `systemctl --user restart ntfy-control`, then check
  `journalctl --user -u ntfy-control -n 20` — a healthy start logs
  `listening on http://127.0.0.1:3003/control/json`.
- Repeated `subscribe error: … — reconnecting in 5s` (or `subscription
  dropped — reconnecting in 5s`) → ntfy itself is down:
  `docker start ntfy` (this is why ntfy isn't remotely controllable).

## Layer 1b — it replies, but "unknown service" / the panel is empty

The registry did not load. `journalctl --user -u ntfy-control -n 30` will say
either `no control registry found — nothing is controllable` or
`control registry unreadable (<path>): <error>`.

- **Unreadable** → `launcher/services.json` has a JSON syntax error from a
  hand edit. `python3 -m json.tool launcher/services.json` points at the line.
  Note there is no fall-back to the last good copy: one bad character empties
  the whole panel until the file parses again. Validate before saving.
- **Not found** → the listener locates the repo from `KUMA_ENV_FILE` in its
  `.env` (an absolute path to `<repo>/monitoring/.env`), falling back to
  `~/dev/setup-server/launcher/services.json`. If the repo moved, re-run
  `./setup.sh` so `.env` is rewritten. `CONTROL_REGISTRY=/path/to/services.json`
  overrides it outright.
- **One service missing from the panel, others fine** → its `control` block
  is `null`, marked `locked`, or all of its `parts` entries were dropped as
  malformed (each must be `{"container": "..."}` or `{"unit": "..."}` with a
  plain name). Not-yet-deployed services like AdGuard Home have `null` on
  purpose.

## Layer 0 — phone can't reach ntfy at all

- Tailscale app installed, logged in, and **connected**? Test by opening
  `https://kai-home-server.taild6a23f.ts.net:3002` (Kuma) in the phone
  browser.
- Service URL must be exactly `https://kai-home-server.taild6a23f.ts.net:3003`
  — https, port included, no trailing path.
- Username/password: leave empty. If the app version insists on
  credentials on that screen, you're likely in "Manage users / default
  server" — add the server during **subscribe** ("Use another server")
  instead.

## Layer 2 — command runs but reports FAILED

- The reply includes the first 300 chars of the docker/systemctl error.
- `(kuma pause failed)` / `(kuma resume failed)` note → Kuma is stopped,
  `monitoring/.env` is missing, or `uv` is not on the unit's PATH. The
  service action itself still succeeded — the Kuma step is best-effort by
  design and never changes the outcome.
- Never got a "start" to work after `stop uptime-kuma`? Start order is
  fine — the kuma *monitor* resume fails while Kuma boots; harmless.
- `permission denied … /var/run/docker.sock` in the error → the unit's
  `ExecStart` lost its `sg docker -c '...'` wrapper. The listener is started
  that way on purpose: a login session that predates the `docker` group grant
  cannot reach the daemon, and `docker inspect` then reports healthy
  containers as not running. Re-run `./setup.sh` to rewrite the unit. Same
  trap if you run `control_listener.py` by hand — use
  `sg docker -c 'python3 ~/services/ntfy-control/bin/control_listener.py'`.
- Multi-part services (`immich`, `seafile`, `beszel`) stop in the order listed
  in their `parts` array and start in the exact reverse, one command per part.
  The first *required* part to fail aborts the rest, so a half-stopped stack
  is possible — `panel` will show the mixed state. Parts marked `optional`
  (Immich's ML container, absent when the `ml` profile is off) may fail
  without stopping the run.

## Layer 3 — command executed but service still "down"

- `sg docker -c 'docker ps -a'` — check the container's real state; a
  crash-on-start is a service problem, not a control problem. See that
  service's TROUBLESHOOT.md.
- Remember `restart: unless-stopped`: a service stopped via ntfy stays
  stopped across reboots until you `start` it again. `kaichenpedia` and `n8n`
  are currently stopped this way on purpose — the panel showing them down is
  correct, not a fault.
- Kuma still red for a service you stopped from here → the pause step
  failed (see Layer 2). Pause it by hand in the Kuma UI, or the monitor will
  page about downtime you asked for.
- The launcher's web UI at `https://kai-home-server.taild6a23f.ts.net/home/`
  drives the same registry and the same allowlist, so it is a useful
  cross-check: if a service starts there but not from the phone, the fault is
  in the ntfy path, not in lifecycle control.

## Nuke and pave

```sh
systemctl --user disable --now ntfy-control
rm -f ~/.config/systemd/user/ntfy-control.service
systemctl --user daemon-reload
rm -rf ~/services/ntfy-control ~/dev/setup-server/ntfy-control/.env
cd ~/dev/setup-server/ntfy-control && ./setup.sh
```
Stateless — nothing is lost by re-deploying.
