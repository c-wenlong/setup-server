# launcher — the home screen for this box

Every service on homeserver in one list, grouped Running / Stopped / Not
installed, with the box's own health above it. Each row has one button for
the obvious thing (Open a running app, Start a stopped one, Install one that
is in this repo but **not deployed yet**, which runs its `setup.sh` on the
box) and a ⋯ menu for the rest. So it is the index of what exists, the place
you start and stop things, and the place you install from.

Bookmark: **`https://homeserver.tail-name.ts.net/home/`**
Also on its own port: `https://homeserver.tail-name.ts.net:8093/`

Still not a stats dashboard: the health strip is four numbers (apps running,
memory, the disk `~/services` lives on, CPU load) read from `/proc` and
`statvfs` on each poll, so a full disk is the first thing on the page. No
graphs or history; Uptime Kuma and beszel do that and are linked from the
sidebar. See [SPEC.md](SPEC.md) for the design rules.

## Architecture

```
                 ┌─ https://<host>:8093/      ──┐
Tailscale Serve ─┤                              ├─▶ 127.0.0.1:8093
                 └─ https://<host>/home/  ──────┘     launcher (systemd user unit)
                    (path handler on :443,            │
                     next to code-server's "/")       ├── static/       static SPA, no build step
                                                      ├── services.json the registry + deploy allowlist
                                                      ├── GET  api/services
                                                      ├── POST api/services/{key}/deploy  ──▶ <repo>/services/<service>/setup.sh
                                                      ├── PATCH api/services/{key}/env/{var} ──▶ rewrites one line of services/<service>/.env
                                                      ├── POST api/services/{key}/update ──▶ docker pull <moved refs> + setup.sh
                                                      ├── POST api/services/{key}/updates/check ──▶ registry manifest HEADs
                                                      ├── GET  api/jobs/{id}
                                                      └── GET  healthz
```

Python 3 **standard library only** — no pip, no venv, no framework, no Docker.
This is meant to be the first thing that comes up on the box and the thing you
reach for when something *else* is broken, so it must have no moving parts.

Nothing is copied out of the repo on install: the unit runs `server.py` in
place from `~/dev/setup-server/app/web`, with `REPO_ROOT` pointing at the repo
root. The repo *is* the installation, which is also what makes the deploy API
possible — the setup scripts it runs are the ones sitting next to it.

State lives under `~/services/launcher`:

```
~/services/launcher/
  jobs/<id>.log     # tee'd output of each deploy the UI has run
  updates.json      # last image-update check per service (safe to delete)
```

That directory is also launcher's own `marker` in the registry, so the
launcher tile knows it is installed without asking Docker anything.

## Why it is published twice

Both mappings proxy the same backend. They are not redundant:

| URL | Why it exists |
|---|---|
| `https://<host>:8093/` | Matches every other service in this repo — one port per service, discoverable from `tailscale serve status` and monitorable by Kuma. Survives anything happening to :443. |
| `https://<host>/home/` | The short URL. This is the one that goes on the iPhone Home Screen, because nobody wants to type a five-digit port on a phone. |

`:443` already serves **code-server** at `/`. `tailscale serve --set-path=/home`
adds a mount point *next to* the existing `/` handler and leaves it alone —
verified. `setup.sh` therefore never issues a bare `--https=443` mapping, and
the live test asserts code-server still owns `:443 /` afterwards.

### The relative-URL contract (the easiest thing to get wrong)

**Tailscale strips the `/home` prefix before proxying.** A request to
`https://<host>/home/app.css` arrives at the backend as `/app.css`; the backend
never sees the string `home` at all. One build has to work at both URLs, so:

- every asset and API reference in `static/` must be **relative** — `app.css`,
  `api/services`, `api/jobs/123` — never absolute (`/app.css`, `/api/services`)
- `<base href="...">` and any `location.origin + "/api/..."` construction are
  equally wrong

An absolute path works perfectly at `:8093` and 404s at `/home/`, which is why
the failure is usually found on the phone rather than in dev. Set
`SHORT_PATH=` if you ever want to skip the `/home` handler; the `:8093` URL is
unaffected.

## Security model

Tailnet-only, like everything here, and the backend binds `127.0.0.1`. There is
no login: the tailnet is the boundary, same as code-server and n8n.

**The deploy endpoint executes shell scripts, so this is the most dangerous
surface on the box.** The design that makes that acceptable:

- **Allowlist only.** `POST api/services/{key}/deploy` looks `key` up in
  `services.json`. Not found ⇒ `404`. The script path comes from the registry,
  **never** from the request — there is no code path where request data becomes
  part of a command.
- **Path containment.** The resolved script path is asserted to stay inside
  `REPO_ROOT`; `..` cannot escape.
- **No shell.** `subprocess` with an argument list, `shell=False`. No string
  interpolation of request data anywhere.
- **Bounded concurrency.** One running job per key, a global cap of 2, so a
  stuck phone tab cannot fork-bomb the box.
- **Explicit confirm** in the UI before any POST.
- **Runs as you, not root.** `setup.sh` refuses to run as root and installs a
  systemd *user* unit, so a deploy has exactly the privileges you have — the
  setup scripts prompt for sudo themselves where they genuinely need it.

Precedent: `ntfy-control` already does allowlisted start/stop from the phone.
This is the same shape.

**The env editor writes to secret files.** `PATCH api/services/{key}/env/{var}`
rewrites one line of a service's `.env` — the same files the reveal endpoint
reads, so the same rules: the path comes from the registry only and must
resolve inside the repo or `~/dev`; the variable must already exist (it edits,
it never adds); the value is single-line, capped at 4 KB, and quoted so that a
shell `source`, Docker Compose and the launcher all read it back identically
(see SPEC.md v4 for the measured rules); the file is replaced atomically with
its mode copied over; the log line carries the variable name, never the value.

**Image updates.** A background thread (first run two minutes after start,
then every six hours) looks at each service's `control` containers: the ref
each was created from (`docker inspect` → `.Config.Image`) is looked up on its
registry with one manifest `HEAD` (anonymous token, the same one `docker pull`
gets), and the digest is compared with the running image's `RepoDigests`. A
different digest means the tag has moved, so the tile gets an accent badge,
the **Updates** tab counts it, and the detail page offers **Update** and a
**Check now**. This catches floating tags (`latest`, `release`, `v3`) and a
pinned tag that upstream rebuilt. It does not look for newer version tags: a
version pinned in `.env` is bumped by hand (the env editor) and a redeploy.
Digest-pinned refs (`…@sha256:`) and images built on the box are listed but
never checked.

**Update** is a job like any other (one per key, same global cap): pause the
Kuma monitor, `docker pull` each ref the last check marked as moved, re-run
the service's `setup.sh` (whose own `docker compose up -d` recreates the
containers), resume the monitor. That is the upgrade recipe every service's
SETUP.md already gives, run from the browser. The request carries the key
only; the refs come from `updates.json` and are shape-checked again before
they reach an argv. A failed pull stops before `setup.sh`, so nothing is
recreated. Success writes the install receipt and re-checks, which clears
the badge. Hard-locked and `locked` services are checked but never offered
the button.

⚠️ Anyone on the tailnet can deploy any service in the registry. That is the
intended blast radius (it is your tailnet), but it is the reason to keep the
tailnet small and not to add `setup` paths for scripts you would not want run
by a mis-tap.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | systemd user unit / launchd LaunchAgent | ✅ (dies on anything else) |
| Not root | user unit + deploys run as you | ✅ |
| python3 ≥ 3.9 | the whole server (stdlib only — no pip, no venv) | ✅ |
| curl | health checks | ✅ |
| systemd + loginctl (Linux) | the unit and boot persistence | ✅ |
| Tailscale, logged in | publishing | ✅ (BackendState must be `Running`) |
| `server.py` compiles | a crash-looping unit is worse than no unit | ✅ (`python3 -m py_compile`) |
| `services.json` parses | it is the deploy allowlist | ✅ (`json.load`) |
| `static/` present | the SPA | ✅ (`static/index.html` warns) |

No Docker. No pip. Deliberately.

## Deploy

```bash
cd app/web && ./setup.sh          # idempotent; rerun to upgrade/repair
```

Environment overrides:

| Var | Default | Effect |
|---|---|---|
| `LAUNCHER_PORT` | `8093` | loopback port the server binds |
| `HTTPS_PORT` | `8093` | the service's own tailnet HTTPS port |
| `SHORT_PATH` | `/home` | the `:443` mount point; **empty string disables it** |

Step by step:

1. **Preflight** — OS (`Linux`/`Darwin`, dies on anything else), non-root,
   `python3 >= 3.9`, `curl`, `systemctl`/`loginctl` on Linux, the Tailscale CLI
   (PATH, or the macOS app bundle) with `BackendState == Running`, numeric
   ports, and a `SHORT_PATH` rooted at `/`.
2. **App checks** — `server.py`, `services.json` and `static/` must exist;
   `server.py` must survive `python3 -m py_compile` (compiled from a scratch
   copy, so the repo never grows a `__pycache__`); `services.json` must parse.
   Each of these fails loudly *before* anything is installed, because the
   alternative is a unit that restarts forever.
3. **State** — `mkdir -p ~/services/launcher/jobs`.
4. **Service** —
   - *Linux*: writes `~/.config/systemd/user/launcher.service` (regenerated
     every run — it is a generated file, never hand-edit it), `Restart=always`,
     `RestartSec=3`, `WorkingDirectory` and `ExecStart` pointing at the repo,
     `LAUNCHER_PORT` and `REPO_ROOT` in the environment, and an explicit `PATH`
     (a user unit inherits a minimal one, and the setup scripts it executes
     need `docker`/`curl`/`tailscale`/`uv`). Then `daemon-reload`, `enable`,
     and **`restart`** — always restart, so an edited unit is actually picked
     up rather than silently ignored on a re-run.
   - *macOS*: writes `~/Library/LaunchAgents/com.launcher.server.plist` with
     `RunAtLoad` + `KeepAlive`, then `bootout` and `bootstrap`.
5. **Lingering** (Linux) — `loginctl enable-linger` via one surgical `sudo`,
   only if it is not already on, so the service starts at boot with nobody
   logged in. This is the only `sudo` on a normal first run, and there is none
   on a re-run.
6. **Local health** — polls `http://127.0.0.1:$PORT/healthz` for up to 40s;
   on failure it dies with the exact `journalctl --user -u launcher.service`
   command to run.
7. **Publish, twice** —
   ```
   tailscale serve --bg --https=8093 http://127.0.0.1:8093
   tailscale serve --bg --https=443 --set-path=/home http://127.0.0.1:8093
   ```
   Both go through the same helper, so both get the operator-grant fallback
   (`sudo tailscale set --operator=$USER` on Linux) and the approval-link loop
   (print the URL Tailscale gave you, wait for Enter, retry). `tailscale serve`
   is declarative, so re-running produces the same two mappings, not four.
8. **Verify** end to end over HTTPS on **both** URLs, then print the short URL,
   the Home Screen instructions and the management commands.

## Client side

**iPhone Home Screen — this is the whole point.**

1. Open `https://homeserver.tail-name.ts.net/home/` in **Safari**
   (Safari specifically; Chrome on iOS cannot add Home Screen icons).
2. Tap the Share button (square with an arrow).
3. Scroll down, tap **Add to Home Screen**, name it `home`, tap **Add**.

The icon then opens the launcher full-screen, like a native app. Tailscale must
be connected on the phone — the URL does not resolve off-tailnet, by design.

**Desktop.** Same URL. `/` jumps to search, ↑/↓ moves the selected row, ↵
runs its button (Open, Start, Install) and ⌘K / Ctrl-K opens its action
menu (Restart, Stop, Update, Copy address, Details, Remove), each item with
its own letter. The bar along the bottom shows what is selected. The pills
under the search filter by category, plus **Updates** when any image tag
has moved; sort the Running group by clicking its column headers. The
sidebar collapses to icons (button at its foot) and holds the theme button,
which cycles System → Light → Dark. All of it is remembered on that device.

**Deploys.** The sidebar's Deploys page is deployd's UI: whether the
timer is polling (with Pause / Resume), each watched repo and the sha it
last deployed, and **+ Add poller** for a repo, branch and command stored
in `~/services/deployd/state/pollers.json`. See
[services/deployd/SETUP.md](../../services/deployd/SETUP.md).

**New app.** **+ New app** on the Deploys page turns a GitHub repo with a
Dockerfile into an app on this box: pick a repo (the box's `gh` login
lists yours; type `owner/name` for any other), choose the branch, check
the container port and key, add env lines, then **Create and deploy**.
The first build streams in the usual job sheet; after that every push to
the branch redeploys it. It shows under **From GitHub** with the usual
Open / Start / Stop / Remove and .env editing. Its detail page has a
**Source** section with **Export to repo**, which opens a pull request on
this repo adding its definition as `app/web/apps/<key>.json` (no secrets;
the `.env` stays on the box). On a rebuilt box, each exported app shows
under From GitHub as not installed; **Install** copies its definition onto
the box, starts its `.env` with the variable names and empty values, and
deploys it. Fill the values in under Environment, then deploy again if the
first build fails its health check.

**Phone.** The sidebar is a drawer behind the ☰ in the top bar; the ⋯ menu
opens as a sheet from the bottom.

**Deploying from the phone.** A row under **Not installed** is a service in
the repo that is not on this box. Tap **Install**, confirm, and the job runs
on the box with its log polled about once a second — polling, not streaming,
so locking the phone mid-deploy does not kill anything. The log survives in
`~/services/launcher/jobs/<id>.log`. Stop, Restart and Update ask for the
same confirm; Start does not, since it is the recovery action.

## Ops

```bash
systemctl --user status launcher.service      # is it up
systemctl --user restart launcher.service     # after editing server.py by hand
journalctl --user -u launcher.service -f      # logs, including deploy output
tailscale serve status                        # both mappings, plus code-server's /
curl -s http://127.0.0.1:8093/healthz         # ok
git -C ~/dev/setup-server pull && ./setup.sh  # upgrade (restarts + re-publishes)
```

Adding or editing a tile means editing `services/<service>/app.json` (or
`registry.json` here for groups, order and tiles with no folder in this repo),
then `python3 scripts/build-registry.py` from the repo root to regenerate
`services.json`. The server re-reads it when its mtime changes, so no restart
is needed. Never hand-edit `services.json`: `make lint` fails when it differs
from the manifests.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` against a sandboxed `$HOME` with PATH
stubs for `tailscale`, `curl`, `sudo`, `id`, `systemctl`, `loginctl` and
`launchctl`. `python3` is deliberately **not** stubbed — `setup.sh` uses it for
real work (version gate, `py_compile`, JSON validation), and faking that would
test nothing. Instead the sandbox is given a fixture `server.py`,
`services.json` and `static/index.html`, which keeps the suite hermetic and lets
the broken-`server.py` test prove the compile gate actually bites.

Covered: preflight failures (root, Tailscale down, non-numeric ports, bad
`SHORT_PATH`, missing `server.py`/`services.json`/`static/`, uncompilable
`server.py`, unparseable registry), fresh install, idempotent re-run (unit
regenerated, no duplicate serve mappings, no `sudo`), both serve invocations
with exact arguments, `SHORT_PATH=` disabling only the `:443` handler, option
overrides, the operator-escalation path, the serve-approval prompt, and the
"cert still minting" path. The `tailscale` stub models Serve's *declarative*
behaviour, so a duplicated mapping would show up as a failure.

`--live` additionally checks: the unit is active **and** enabled, lingering is
on, `healthz` and `api/services` answer on loopback, the port is not listening
on any non-loopback, non-Tailscale interface, both serve mappings are present,
code-server still owns `:443 /`, both HTTPS URLs answer, and the backend's own
`python3 -m unittest discover -s tests` passes.

## Notes

- Port 8093 continues the repo's convention of HTTPS port == local port. It sits
  next to kaichenpedia (8091) and beszel (8092) in the port map.
- Status detection deliberately avoids the Docker CLI: a systemd user unit does
  not reliably inherit the `docker` group, and the launcher must never show
  everything as down because of that. `installed` = marker exists OR health
  responds; `active` = health responds. Probes are loopback, 2s timeout,
  concurrent, cached ~5s so a page refresh cannot stampede the box.
- `ollama` has no web UI, so its tile has `url: null` — it reports status and
  never navigates. That is intentional, not a broken tile.
- Out of scope on purpose: auth, editing the registry from the UI, uninstall
  actions, log history beyond the current job, a PWA manifest, tile reordering.
