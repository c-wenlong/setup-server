# Agent instructions — setup-server

Repo of one-shot deploy scripts for self-hosted services on Tailscale-private
home servers. One directory per service under `services/`; each is
self-contained. **One directory, one `setup.sh`, one service.** A folder must
not deploy two products (Paperclip and OpenHands are `services/paperclip/` and
`services/openhands/`, not a combined `services/paperclip-openhands/`). Complementary tools that share a
workspace tree still get their own script, `.env`, tests, and docs.

Human-facing contribution rules (branch naming, PR expectations, how to run a
service's suite) live in `CONTRIBUTING.md`; this file is the agent-facing
version and wins where the two overlap on conventions. CI is defined in
`.github/workflows/ci.yml`; read it before assuming a local pass is enough, and
keep it in step when you add a service.

## Repo layout

| Path | What lives there |
|---|---|
| `services/<service>/` | One deployable service each: everything the launcher can install. |
| `app/<surface>/` | Front ends for the box itself. `app/web/` is the launcher (Python server plus its static UI in `app/web/static/`); a future desktop app goes in `app/desktop/`. Each one follows the same per-directory contract as a service. |
| `scripts/` | Repo tooling (`check-structure.sh`, one-off migrations). |
| `docs/` | Cross-service design notes. |

Runtime state stays at `~/services/<service>/` on the box, which is separate
from the repo's `services/` folder despite the shared name.

## Non-negotiable conventions

- **Entrypoint is always `services/<service>/setup.sh`**, runnable as a regular user.
  Root refusal is a preflight check, not an afterthought. That script
  deploys **exactly one** service. Do not combine two runtimes, compose
  projects, or systemd units in one directory so they can share a
  workspace or a Tailscale box — add a second directory instead.
- **Linux + macOS portability.** Branch on `uname -s` (`Linux`/`Darwin`, die on
  anything else). Services: systemd user units + lingering on Linux, launchd
  LaunchAgents on macOS (Docker services need neither — dockerd/Docker Desktop
  handles restarts). Resolve the Tailscale CLI from PATH or the macOS app
  bundle (`/Applications/Tailscale.app/Contents/MacOS/Tailscale`). No
  GNU-only tool flags: no `grep -P` (use `sed -n 's/../p'`), no `stat -c`
  without a `stat -f` fallback, no `ss` without an `lsof` fallback, no
  `/etc/timezone` without a `readlink /etc/localtime` fallback. Linux-only
  concepts (docker group, tailscale operator, lingering) must be gated, and
  their test assertions gated on `$OS` too. macOS paths are portable by
  construction — mark them verified only after a real run on a Mac.
- **Idempotent**: re-running must upgrade or repair, never break a working
  deployment, and never overwrite a config file the user may have edited
  (write configs only if absent).
- **Security model**: services bind to `127.0.0.1` only and are published
  tailnet-only via `tailscale serve`. Do not bind to `0.0.0.0` or LAN
  interfaces, do not open firewall ports, do not add password auth as a
  substitute for the tailnet boundary without being asked. The one
  sanctioned exception: a protocol Serve cannot carry (UDP, or one where
  peers must dial the node directly) may bind **this node's tailnet IP**
  (`tailscale ip -4`) and nothing wider — AdGuard's DNS on `:53` and
  Syncthing's sync listener on `:22000` do this. Such a listener must be
  resolved at deploy time (never hardcoded), documented as an exception in
  the service's SETUP.md and DIRECTORY.md row, and asserted by the live
  suite to be on the tailnet address only.
- **Sudo is surgical**: escalate per-command (`sudo loginctl ...`), announce
  why before prompting, and design so sudo is needed at most on first run.
- **Long-running services** use systemd *user* units in
  `~/.config/systemd/user/` with `Restart=always`, plus lingering
  (`loginctl enable-linger`) for boot persistence.
- **Interactive pauses are allowed only for one-time approvals** that
  genuinely can't be automated (e.g. Tailscale Serve enablement link). Print
  the URL, wait for Enter, retry in a loop.

## Required files per service

| File | Purpose |
|---|---|
| `setup.sh` | The deploy. Preflight → install → configure → service → publish → verify. Ends by printing the URL and management commands. |
| `SETUP.md` | Architecture diagram, security model, dependency table, what the script does step-by-step, client-side setup, ops commands. |
| `TROUBLESHOOT.md` | Layered triage (service → local health → publish → client), symptom-keyed fixes, nuke-and-pave recipe. |
| `tests/run-tests.sh` | See below. |
| `docker-compose.yml` | Docker-based services only (most of them). Ports published to `127.0.0.1` only, `restart: unless-stopped` on every service (never `always`, so a stopped app stays stopped across reboots), so no systemd unit is needed. Jellyfin adds a second overlay file, `docker-compose.gpu.yml`, for its opt-in NVENC path. |

Planning documents (`PLAN.md`, `SPEC.md`, `COMPETITIVE-ANALYSIS.md`, a `docs/`
folder) are optional and kept after a service ships; when the shipped service
diverges from one, note the divergence in that document rather than deleting it.

## Testing requirements

Every service ships tests in `tests/run-tests.sh` with two layers (the one
exception is `beszel`, whose default layer is static analysis of `setup.sh` and
`docker-compose.yml` rather than a PATH-stub sandbox, so it has no
`tests/stubs/`; the rationale is in `services/beszel/SETUP.md`):

1. **Mocked suite (default)** — runs the real `setup.sh` in a sandbox: temp
   `$HOME`, and PATH stubs (in `tests/stubs/`) for every external command the
   script touches (`tailscale`, `sudo`, `systemctl`, `loginctl`, `curl`, `id`,
   …). Stubs log calls to `$CALLS_LOG` and keep state in `$STATE_DIR`. Must
   cover at minimum: fresh-install happy path, idempotent re-run (config
   preserved, no sudo), option overrides, interactive-approval paths, and
   preflight failures. Zero changes to the host system.
2. **Live suite (`--live`)** — verifies a real deployment on the current
   machine: service active/enabled, lingering on, local health endpoint,
   *not* listening on non-localhost interfaces, publish config present,
   end-to-end HTTPS check.

Harness gotcha: mocked tests override `$HOME` — always restore it in
teardown or live checks will read the deleted sandbox.

Before committing changes to a `setup.sh`, run its mocked suite; if the
service is deployed on this machine, run `--live` too.

## Adding a new service (checklist)

1. `mkdir services/<service>/tests/stubs`; start `setup.sh` from a reference
   implementation (preflight/info/ok/warn/die helpers, section ordering):
   `services/code-server/setup.sh` for a native binary under a systemd user unit or a
   launchd LaunchAgent, `services/forgejo/setup.sh` for the Docker shape (gitignored
   `.env`, `LOCAL_PORT`/`HTTPS_PORT`, Compose restart policy instead of a unit).
   One directory deploys one service — never two products in the same folder.
2. Write stubs for every external command the script calls; wire the mocked
   suite; get it green before ever running on a real box.
3. Write `SETUP.md` + `TROUBLESHOOT.md` (mirror code-server's structure).
4. Add the service row to the root `README.md` table and to `DIRECTORY.md`
   (services table plus any loose end it introduces), and add a monitor line in
   `services/monitoring/seed_kuma.py`.
5. Write `services/<service>/app.json` (its launcher tile: copy a similar
   service's, leave out `setup`), add its key to `order` in
   `app/web/registry.json`, then run `python3 scripts/build-registry.py` and
   commit the regenerated `app/web/services.json`. Never edit that file by
   hand; `make lint` fails when it drifts from the manifests.
6. Real-machine test: deploy, then `./tests/run-tests.sh --live`.

Only add a service-level `AGENTS.md` if the service has quirks that genuinely
deviate from these conventions.
