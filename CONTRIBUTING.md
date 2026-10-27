# Contributing to setup-server

Thanks for your interest. This repo is a collection of one-shot deploy scripts
for self-hosted services on a Tailscale-private home server. One directory per
service, each self-contained, each with its own tests. **Each `setup.sh`
deploys one service** — do not put two products in the same folder. Bash is
the default; Python (stdlib only) appears where a service needs a real program.

## Getting started

```bash
git clone https://github.com/c-wenlong/setup-server.git
cd setup-server/services/code-server
./tests/run-tests.sh
```

That is the mocked suite, and it is safe to run anywhere. It executes the real
`setup.sh` inside a sandbox: a temporary `$HOME`, plus PATH stubs in
`tests/stubs/` for every external command the script touches (`tailscale`,
`sudo`, `systemctl`, `loginctl`, `curl`, `id`, and so on). The stubs log calls
and keep fake state, so nothing on your machine changes.

The live suite is the other half:

```bash
./tests/run-tests.sh --live
```

Run it **only on a box where that service is actually deployed**. It talks to
the running service, the real Tailscale Serve config, and the real systemd or
launchd unit. On a machine without the deployment it just fails noisily.

The launcher additionally has a Python unit suite:

```bash
python3 app/web/tests/test_server.py
```

From the repo root, `make` runs the same checks CI does:

```bash
make test          # every service's mocked suite, with a pass/fail summary
make lint          # shellcheck, the per-service contract check, actionlint
pre-commit install # run those gates on every commit (pip install pre-commit)
```

`make help` lists the rest, including `make test-python` for the launcher suite
under coverage.

There are two reference implementations: [code-server](services/code-server/setup.sh)
for a native service under a systemd user unit or a launchd LaunchAgent, and
[forgejo](services/forgejo/setup.sh) for the Docker shape. Read whichever matches the
service you are adding. Both source [lib/common.sh](lib/common.sh) for the output
helpers, preflight checks and the Tailscale Serve publish step; AGENTS.md's
"Shared helpers" section has the rules for using and extending it.

## Project layout

Every service directory contains the same four things:

| File | Purpose |
| --- | --- |
| `setup.sh` | The deploy, runnable as a regular user. Preflight, install, configure, service, publish, verify. Ends by printing the URL and the management commands. |
| `SETUP.md` | Architecture diagram, security model, dependency table, what the script does step by step, client-side setup, ops commands. |
| `TROUBLESHOOT.md` | Layered triage (service, local health, publish, client), symptom-keyed fixes, nuke-and-pave recipe. |
| `tests/run-tests.sh` | Mocked suite by default, real-deployment checks under `--live`. Stubs live in `tests/stubs/`. |

These shared files are touched by every new service, plus its own `app.json` (see below):

| File | Role |
| --- | --- |
| [README.md](README.md) | The Services table: one row per service, what it gives you, how to deploy it |
| [DIRECTORY.md](DIRECTORY.md) | What is actually running on the deployed box: ports, runtime, credentials pointers, loose ends |
| [services/monitoring/seed_kuma.py](services/monitoring/seed_kuma.py) | The Uptime Kuma monitors, seeded from the `PUBLISHED` list |
| [app/web/registry.json](app/web/registry.json) | Launcher tile order, groups, and tiles with no folder here; `scripts/build-registry.py` merges it with every `app.json` into `app/web/services.json` |

## What to contribute

- **New services.** Anything that fits the model: installs without root, binds
  loopback, publishes over Tailscale Serve. [EXPLORATION.md](EXPLORATION.md)
  holds the current ideas list.
- **Fixes to an existing `setup.sh`.** Especially repair paths: the case where
  a re-run has to undo drift an upgrade or a UI change introduced.
- **macOS verification.** The Darwin branches are portable by construction and
  have only ever been run on Linux. A real Mac run, with the test assertions
  corrected to match, is one of the most useful things you can send.
- **Docs and troubleshooting entries**, particularly symptoms you hit and the
  fix that actually worked.

## Guidelines

1. **`setup.sh` is idempotent.** A re-run upgrades or repairs, never breaks a
   working deployment, and never overwrites a config file the user may have
   edited (write a config only when it is absent).
2. **Bind `127.0.0.1`, publish with `tailscale serve`.** No `0.0.0.0`, no LAN
   interfaces, no opened firewall ports, and no password auth bolted on as a
   substitute for the tailnet boundary. The one sanctioned exception is a
   protocol Serve cannot carry (UDP, or one where peers must dial the node
   directly): it may bind **this node's tailnet IP** from `tailscale ip -4`
   and nothing wider, resolved at deploy time rather than hardcoded,
   documented in the service's `SETUP.md` and its `DIRECTORY.md` row, and
   asserted tailnet-only by the live suite.
3. **Sudo is surgical.** Escalate per command (`sudo loginctl ...`), say why
   before prompting, and design so sudo is needed at most on the first run.
4. **Linux and macOS both.** Branch on `uname -s`, die on anything else.
   systemd user units plus lingering on Linux, launchd LaunchAgents on macOS.
   No GNU-only flags: no `grep -P`, no `stat -c` without a `stat -f` fallback,
   no `ss` without an `lsof` fallback. Gate Linux-only concepts (docker group,
   Tailscale operator, lingering) and gate their test assertions on `$OS` too.
5. **Tests ship with the service.** The mocked suite must cover at minimum the
   fresh-install happy path, an idempotent re-run (config preserved, no sudo),
   option overrides, interactive-approval paths, and preflight failures. Get it
   green before running anything on a real box.
6. **Register a new service everywhere.** A row in the README table, a row in
   `DIRECTORY.md`, and an entry in `PUBLISHED` in `services/monitoring/seed_kuma.py` so
   Uptime Kuma probes it. Pick the health path carefully: several services here
   answer 200 or 302 on `/` while being broken underneath. Its launcher tile is
   `services/<service>/app.json` plus a key in `order` in
   `app/web/registry.json`; run `python3 scripts/build-registry.py` and commit
   the regenerated `app/web/services.json`.
7. **Never commit a `.env`.** `*/.env` is gitignored because `setup.sh`
   generates real credentials into it. Check the staged diff before committing.
8. **One concern per PR.** A real bug found outside the current scope gets its
   own branch and its own PR.

[AGENTS.md](AGENTS.md) carries the full conventions and the new-service
checklist. Read it before adding a service; this page is the short version.

## Pull request process

1. Branch from `main`. Never commit to `main` directly.
2. Run the mocked suite for **every service you touched**, and `--live` as well
   if that service is deployed on the machine you are working on.
3. Update the README table and `DIRECTORY.md` if behaviour, ports, or the
   service list changed.
4. Push and open a PR against `main`, describing what changed and why. Include
   the test counts you saw.
5. CI (`.github/workflows/ci.yml`) must pass: lint (shellcheck, the
   per-service contract check, actionlint), the per-service mocked suites, the
   Python tests with coverage, a syntax compile on the oldest and newest
   supported Python, and a gitleaks scan of the history.
6. [Greptile](https://greptile.com) reviews every PR. Answer each thread,
   either with the fix or with why the comment does not apply, and resolve it.

## Reporting bugs

Use the [bug report template](https://github.com/c-wenlong/setup-server/issues/new?template=bug_report.yml)
and include the service, your OS and Tailscale version, and the output of that
service's `./tests/run-tests.sh --live`. Redact anything that came out of a
`.env`.

Security issues do not go in the issue tracker: see [SECURITY.md](SECURITY.md).

## Questions

Open a [discussion](https://github.com/c-wenlong/setup-server/discussions).
