# Agent instructions — setup-server

Repo of one-shot deploy scripts for self-hosted services on Tailscale-private
home servers. One directory per service; each is self-contained.

## Non-negotiable conventions

- **Entrypoint is always `<service>/setup.sh`**, runnable as a regular user.
  Root refusal is a preflight check, not an afterthought.
- **Idempotent**: re-running must upgrade or repair, never break a working
  deployment, and never overwrite a config file the user may have edited
  (write configs only if absent).
- **Security model**: services bind to `127.0.0.1` only and are published
  tailnet-only via `tailscale serve`. Do not bind to `0.0.0.0` or LAN
  interfaces, do not open firewall ports, do not add password auth as a
  substitute for the tailnet boundary without being asked.
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

## Testing requirements

Every service ships tests in `tests/run-tests.sh` with two layers:

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

1. `mkdir <service>/tests/stubs`; start `setup.sh` from `code-server/setup.sh`
   as the reference implementation (preflight/info/ok/die helpers, ordering).
2. Write stubs for every external command the script calls; wire the mocked
   suite; get it green before ever running on a real box.
3. Write `SETUP.md` + `TROUBLESHOOT.md` (mirror code-server's structure).
4. Add the service row to the root `README.md` table.
5. Real-machine test: deploy, then `./tests/run-tests.sh --live`.

Only add a service-level `AGENTS.md` if the service has quirks that genuinely
deviate from these conventions.
