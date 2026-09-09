# launcher — Troubleshooting

Triage in layers, outermost failure first:

```
unit up?            ->  local health?      ->  publish?          ->  client?
systemctl --user       curl 127.0.0.1:8093    tailscale serve       phone/browser
```

Quick triage:

```bash
cd ~/dev/setup-server/launcher
systemctl --user status launcher.service        # active (running)?
curl -s http://127.0.0.1:8093/healthz           # ok
tailscale serve status                          # :8093 / and :443 /home
./tests/run-tests.sh --live                     # all of the above at once
```

## The unit won't start / keeps restarting

```bash
journalctl --user -u launcher.service -n 100 --no-pager
```

- **`Restart=always` + instant exits (a restart loop)** — almost always a
  Python error on import. Reproduce it in the foreground, where you get the
  traceback immediately:
  `cd ~/dev/setup-server/launcher && LAUNCHER_PORT=8093 REPO_ROOT=.. python3 server.py`
  Re-running `./setup.sh` catches syntax errors before installing anything
  (`python3 -m py_compile`) but not import-time or runtime ones.
- **`Address already in use`** — something else has 8093.
  `ss -ltnp | grep 8093` (or `lsof -nP -iTCP:8093 -sTCP:LISTEN` on macOS).
  If it is a stale launcher, `systemctl --user stop launcher.service` and
  re-run. Otherwise deploy on another port: `LAUNCHER_PORT=8094 ./setup.sh`
  (and update the Kuma monitor).
- **`status=203/EXEC`** — `ExecStart` points at a `server.py` that has moved.
  The unit hard-codes the repo path at install time, so if you moved or
  renamed the repo, just re-run `./setup.sh` from the new location.
- **`No such file or directory` for `python3`** — the unit's `PATH` is explicit
  but assumes a system `python3`. A pyenv/asdf-only Python is not visible to a
  user unit; install the distro `python3`.
- **The unit is gone after a reboot, or only starts when you SSH in** —
  lingering is off. `loginctl show-user $USER -p Linger --value` should say
  `yes`; if not, `sudo loginctl enable-linger $USER` (or re-run `./setup.sh`).
- **macOS: nothing in `journalctl`** — there is no journalctl. Logs are at
  `~/Library/Logs/launcher.log`; reload with
  `launchctl kickstart -k gui/$(id -u)/com.launcher.server`.

## setup.sh refuses to run

These are all preflight failures, and all of them mean *nothing was installed*:

- **`Run as a regular user, not root`** — by design. The unit is a systemd
  *user* unit and deploys must run with your privileges, not root's.
- **`server.py does not compile`** — the traceback is printed above the error.
  Fix the syntax; setup.sh will not install a unit that would crash-loop.
- **`services.json is not valid JSON`** — the registry is the deploy allowlist,
  so a broken one is a hard stop rather than a warning.
  `python3 -m json.tool services.json` points at the line.
- **`Missing .../server.py` (or `services.json`, or `web/`)** — a partial
  checkout. `git -C ~/dev/setup-server status`.
- **`Tailscale is not up`** — `sudo tailscale up`, or open the Tailscale app on
  macOS.
- **`python3 >= 3.9 is required`** — the server uses stdlib features from 3.9.
  There is no venv to fix this in, on purpose.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this once,
  automatically).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  setup.sh prints the link and waits: open it, approve, press Enter. If you ran
  the script non-interactively it will have exited instead — re-run it from a
  terminal.
- **`:8093` is claimed by something else** — `tailscale serve status` shows
  what. Reset just that mapping: `tailscale serve --https=8093 off`.

## `/home` doesn't work but `:8093` does

This is the interesting failure mode, and it is almost always one of two
things.

- **The `/home` handler is missing.** `tailscale serve status` should show a
  `/home` line under the `:443` node proxying to `http://127.0.0.1:8093`. If
  not, re-run `./setup.sh` (or add it by hand:
  `tailscale serve --bg --https=443 --set-path=/home http://127.0.0.1:8093`).
- **The page loads but is unstyled, or the tiles never populate.** Open the
  browser console: you will see 404s for `/app.css` or `/api/services`.
  Tailscale **strips** the `/home` prefix before proxying, so the backend sees
  `/` — which means *every* asset and API reference in `web/` must be
  relative (`app.css`, `api/services`), never absolute (`/app.css`,
  `/api/services`). An absolute path works perfectly at `:8093` and 404s at
  `/home/`, which is why this usually shows up first on the phone. Fix the
  reference in `web/`, then
  `systemctl --user restart launcher.service`.

  Quick check from the box:
  ```bash
  curl -s https://kai-home-server.taild6a23f.ts.net/home/ | grep -o 'href="[^"]*"'
  ```
  Anything starting with `/` is the bug.

## code-server broke when I deployed launcher

It should not — `--set-path=/home` adds a mount point beside the existing `/`
handler on `:443` and leaves it alone (verified, and asserted by the live
test). If `https://kai-home-server.taild6a23f.ts.net/` stopped working:

```bash
tailscale serve status          # is there still a "/" -> 127.0.0.1:8080 line?
cd ~/dev/setup-server/code-server && ./setup.sh    # re-adds it
```

The thing that *does* clobber it is a bare `tailscale serve --https=443
http://...` with no `--set-path`, which replaces the root handler. Never run
that on :443 on this box.

## HTTPS URL doesn't load from a client

- Is the client on the tailnet? None of this is reachable off-tailnet, by design.
- First load after a new port can take ~60s while the cert is minted:
  `curl -v https://kai-home-server.taild6a23f.ts.net:8093/healthz`
- MagicDNS off → use the tailnet IP `100.85.87.87` (`/home/` works there too;
  the `:8093` form needs the port).
- **iOS shows the old page after an update** — Safari caches aggressively for
  Home Screen apps. Long-press the icon → delete, then re-add from Safari.

## Tiles are wrong

- **Everything shows as down** — the backend's health probes are loopback
  requests with a 2s timeout, cached ~5s. If the tiles are all amber but the
  services work in a browser, check the box can reach itself:
  `curl -s http://127.0.0.1:2283/api/server/ping`. Note the probe deliberately
  never uses the Docker CLI (a user unit does not reliably inherit the `docker`
  group), so "docker ps works but tiles say down" is a real bug, not a group
  problem.
- **A deployed service shows as `available` (dimmed, ↓)** — its `marker` path in
  `services.json` does not exist and its `health` probe is failing. Fix the
  marker to something that actually exists once deployed (a state dir or a
  generated `.env`).
- **`ollama` never opens** — correct: `url` is `null` because it has no web UI.
  It reports status only.
- **A service is missing entirely** — it is not in `services.json`. Add it,
  then `./setup.sh` (which re-validates the JSON) or
  `systemctl --user restart launcher.service`.

## Deploy from the UI fails

- **The button does nothing / `404`** — the `key` is not in the registry, or its
  `setup` is `null` (a `planned` service). Both are the allowlist working.
- **`409`** — a job is already running for that key, or the global cap of 2
  concurrent jobs is hit. Wait, or check `~/services/launcher/jobs/`.
- **The job log ends at a `sudo` prompt** — the deploy runs non-interactively,
  so a setup script that needs a *new* sudo grant (e.g. first-ever
  `enable-linger`) cannot complete from the phone. Run that one service's
  `setup.sh` once from a terminal; afterwards it is re-runnable from the UI.
- **The job log ends at a Tailscale approval link** — same class of problem:
  the approval loop needs an Enter. Approve in the browser, then re-deploy from
  the UI.
- **`Permission denied` on a docker command** — the unit's `PATH` is set but
  group membership is not: a systemd user manager bakes in supplementary groups
  at *its* start, so a `docker` grant newer than your login session is invisible
  to it. `systemctl --user daemon-reexec`, or log out and back in.

## Nuke and pave

Nothing here holds data you care about — the registry is in git and the job
logs are disposable.

```bash
cd ~/dev/setup-server/launcher
systemctl --user disable --now launcher.service
rm -f ~/.config/systemd/user/launcher.service
systemctl --user daemon-reload
rm -rf ~/services/launcher          # job logs only
tailscale serve --https=8093 off
tailscale serve --https=443 --set-path=/home off   # leaves code-server's "/" alone
./setup.sh
```

macOS equivalent for the service part:

```bash
launchctl bootout gui/$(id -u)/com.launcher.server
rm -f ~/Library/LaunchAgents/com.launcher.server.plist
```
