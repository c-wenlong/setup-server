# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project has no version numbers; entries are grouped by merged PR, newest
first, dated by merge.

## [Unreleased]

### Added

- **Open-source hygiene for the repo itself.** An MIT `LICENSE`, this
  changelog, `CONTRIBUTING.md` and `SECURITY.md`, a pull request template, and
  issue forms for bug reports and feature requests, plus `CODEOWNERS`,
  a Dependabot config for the GitHub Actions used by CI, and an `.editorconfig`
  matching the styles already in the tree (2-space bash, 4-space Python).
- **Continuous integration** at `.github/workflows/ci.yml`: shellcheck over
  every shell file (the `*.sh` scripts plus the 145 PATH stubs, detected by
  shebang), the per-service mocked suites as a dynamic 20-wide matrix, the
  Python tests with coverage uploaded to Codecov, a Python 3.9 and 3.13 syntax
  floor, actionlint over the workflow, and a gitleaks history scan. Actions are
  pinned to commit SHAs, the token is read-only, and superseded PR runs are
  cancelled. Until now every suite was only ever run by hand on the box.
- **A root `Makefile`**: `make test` runs every mocked suite and prints a
  pass/fail table, `make lint` runs shellcheck, the structure check and
  actionlint, `make test-python` runs the launcher suite under coverage,
  `make test-live` runs the live suites on a deployed box. CI calls the same
  targets so local and CI stay identical.
- **`scripts/check-structure.sh`**: turns the per-service contract in
  `AGENTS.md` (required files, executable bits, a README row, a DIRECTORY.md
  row, no tracked `.env`) into a gate that runs in `make lint`, CI and
  pre-commit.
- **Pre-commit config** (`.pre-commit-config.yaml`): whitespace and YAML
  checks, shebang and executable-bit checks, private-key and secret detection,
  shellcheck, and the structure check.
- **A header card on the README**, so the front page says what the repo is
  before the service table starts.
- `.gitattributes` pinning LF endings on scripts and stubs, and `.shellcheckrc`
  with the three disabled codes and the reason for each.

### Changed

- Documentation audit across the root docs and the per-service pages, checking
  the claims in them against what the scripts actually do.

### Fixed

- **Three suites declared `FAKE_TS_IP` and never used it.** firefly-iii now
  asserts the listener audit accepted tailscaled's Serve proxy on the stub's
  tailnet address for both ports (and resolved it via `tailscale ip -4`),
  remote-desktop's two literal `100.77.77.77` assertions use the variable,
  and homepage drops it (its audit never names the address; the ss and
  tailscale stubs share it between themselves).

## [PR #4](https://github.com/c-wenlong/setup-server/pull/4) - 2026-09-12

Follow-up review of the parts of PR #3 that had not been looked at. Four
confirmed launcher defects, each fix carrying a test that fails without it.

### Fixed

- **CPU percentages could read 100% for a service at 40%.** In
  `service_resources`, the sample clock was read before `docker_name_map()`,
  which runs outside the resources lock and can block for `DOCKER_MAP_TIMEOUT`
  against a wedged daemon. The stale stamp shrank the wall delta that
  `_cpu_percent` divides by, and it stamped the cache entry already expired
  whenever the block outlasted `RESOURCE_TTL`. The clock is now read after the
  docker call.
- **`last_launched` could move backwards.** `record_touch` took the timestamp
  at request entry instead of inside `_usage_lock`, so of two near-simultaneous
  clicks the loser overwrote the winner.
- **A malformed `marker` field 500'd the whole grid.** `services.json` is
  hand-edited, and a numeric `marker` raised `TypeError` out of `expanduser` in
  `deployed_at` and `marker_exists`, both of which run for every service on
  every list request. They now degrade to null and False like every other
  malformed field.
- **The table said "Stoping...".** The running-job label in `view.js` appended
  `ing` to the verb; `stop` is the only one of the four verbs that breaks that
  way. The same file also reported "No parts are registered for this service."
  when the real cause was a server sending no `resources` key at all.
- **A test that tested nothing.** `test_a_broken_measurement_is_nulls_not_a_500`
  stubbed `_measure_resources` with a signature that had drifted, so the
  exception it claimed to exercise was never raised.

### Added

- The project banner image on the README.

Launcher Python suite: 430 tests, up from 426.

## [PR #3](https://github.com/c-wenlong/setup-server/pull/3) - 2026-09-12

### Added

- **Syncthing** (`syncthing/`): peer-to-peer folder sync at `:8384` (GUI,
  loopback behind Serve) plus `:22000` (BEP sync, tcp + quic, bound to the
  node's tailnet IP only, the same deliberate non-loopback exception AdGuard's
  resolver makes). Pinned v2.1.5 native binary in `~/.local/bin`,
  sha256-verified against the release list, systemd user unit with upstream's
  hardening, no Docker and no sudo. `config.xml` is patched before the first
  start so upstream's wildcard, relay and discovery defaults never go live even
  briefly; relays, global and local discovery, NAT-PMP, usage and crash
  reporting and self-upgrade are all off, so the box contacts no third party.
  Re-runs verify the running options over REST and exit non-zero on drift
  without reverting the user's file. Mocked 170/170, live 185/185.
- **Launcher v3**: View (Grid or Table) and Sort (Last used, Deployed, RAM)
  selects beside the tab strip, persisted per device. The table view is one row
  per service, updated in place on the 30 s poll. Installed tiles show RAM, and
  every detail page gains a Resources block (RAM, CPU, deployed, last launched,
  last opened, per-part table). Every list and detail entry now carries
  `usage`, `deployed_at` and `resources`, with RAM and CPU read from cgroup v2
  in sysfs rather than `docker stats`, so the launcher still needs no docker
  group. New `POST api/services/{key}/touch` records timestamps into
  `usage.json`. The contract is written down in `launcher/SPEC.md`.
- **Editing `.env` values in place** from a launcher detail page, a pencil per
  row. It exists because a password reset in a service UI left the `.env` copy
  stale.
- **Service icons in the README table**, each linked to the project's official
  site or docs, using the same vendored files the launcher renders. Dark-mode
  marks use `<picture>`.

### Fixed

- **remote-desktop `security=nla`.** gnome-remote-desktop accepts NLA only, so
  `security=tls` failed with "Log in failed" before the password was ever
  checked.
- **remote-desktop `disable-audio=true`.** guacd's FreeRDP 2.11.7 offers
  AUDIO_PLAYBACK v6, which the server rejects as too old mid-session. It stays
  until guacd ships FreeRDP 3.x. Both are now in the template, in
  `TROUBLESHOOT.md`, and asserted by the suite (242/242). Documented alongside
  them: Guacamole caches connection parameters at login, so edits need a logout
  or a webapp restart.
- **homepage bookmark groups all crashed** because of `bookmarks.yaml` nesting.
- The launcher's docker name lookup moved outside the shared resources lock.

Launcher tests: 396/396, up 77.

## [PR #2](https://github.com/c-wenlong/setup-server/pull/2) - 2026-09-11

Seven new services, one commit each, with an audit-fixes commit up front and a
wiring commit at the end. All follow the repo conventions: idempotent
`setup.sh`, bind 127.0.0.1, published via `tailscale serve`, mocked and live
tests, a Kuma monitor in `monitoring/seed_kuma.py`.

### Added

| Service | Port | Checks |
| --- | --- | --- |
| vaultwarden | :8222 | 175 (162 mocked + 13 live) |
| adguard | :3080 + :53 (DNS on the tailnet IP) | 246 |
| home-assistant | :8123 | 277 (253 mocked + 24 live), 18 mutations caught |
| firefly-iii | :8097 (importer :8099) | 169 mocked, 204 with live |
| homepage | :8100 | 233 mocked, 266 with live, 10 mutations caught |
| paperless-ngx | :8095 | 135 mocked, 155 with live |
| remote-desktop | :8094 (RDP :3389, nftables-scoped) | 240 mocked, 275 live |

- **Jellyfin NVENC hardware transcoding** (`enable-nvenc.sh` plus
  `docker-compose.gpu.yml`), finished in a concurrent session and included here
  because `DIRECTORY.md` already documented it as live.

### Fixed

- An audit of every `TROUBLESHOOT.md`: stale nuke-and-pave paths, tools the
  images do not ship, invented model names.
- Three latent bugs the audit surfaced: beszel's unit used
  `Restart=on-failure` instead of `always`, an n8n data-path comment was stale,
  and ntfy-control emptied the phone panel whenever `services.json` was
  momentarily unreadable.
- **home-assistant** needed repair after an HA 2026.9 `.storage/http` migration
  reverted the loopback bind and the proxy trust; `setup.sh` now seeds and
  repairs that file on every run.

All seven deployed one-shot except home-assistant (above) and remote-desktop,
which needs interactive sudo for the nftables unit and the gnome-remote-desktop
system daemon. No `.env` file is in any commit.

## [PR #1](https://github.com/c-wenlong/setup-server/pull/1) - 2026-09-09

### Added

- **Immich** (`immich/`): self-hosted photo library at `:2283`. Machine
  learning is off by default because this box has 7.7 GB of RAM against
  Immich's documented 6 GB minimum and 8 GB recommendation, with ollama
  claiming around 5 GB when a model is loaded. `IMMICH_ML=on ./setup.sh` flips
  the container, the server setting and the marker together, and existing
  photos backfill. 98 checks including live.
- **Launcher** (`launcher/`): one-tap app launcher at `/home/`. Tile grid of
  every service with vendored brand logos (~41 KB local, no CDN), tabs
  filtering by All, Active, Paused and Uninstalled, and a Deploy button on
  tiles for services in the repo that are not installed. Python 3 stdlib only,
  no pip, no venv, no framework, because it is what you reach for when
  something else is broken. It shares `:443` with code-server via
  `--set-path=/home`, which adds a mount next to `/` rather than replacing it,
  and Tailscale strips the prefix before proxying, so every frontend URL is
  relative. A live test permanently asserts that code-server still owns
  `:443 /`. The deploy endpoint runs shell scripts, so it is allowlist-only:
  the key is looked up in the registry, the script path never comes from the
  request, `realpath` plus a component-boundary check guards the allowed roots,
  and `Popen` runs with an argument list and `shell=False`. 106 checks
  including live, 58 backend unit tests.

### Changed

- **Kuma monitors now probe tailnet URLs** rather than loopback, so the
  dashboard links to the address you actually open and the checks exercise
  Serve and the TLS certificate. The trade-off is documented: a tailscaled
  failure turns everything red at once, so `tailscale serve status` is the
  first triage step.

### Fixed

- Three Immich bugs found while deploying, each with a regression test
  confirmed to fail without its fix: `/admin/config` is an unreleased rename
  (v3.1.0 serves `/system-config`), so the script probes and falls back; the
  low-RAM tuning was gated on "admin created this run", which a run dying after
  admin creation would have skipped forever (the `.ml-mode` marker is the
  correct sentinel); and sourcing `.env` exported `COMPOSE_PROFILES`, which
  Compose prefers over the file, so an ML on-to-off flip still started the ML
  container.
- Seafile's monitor was silently taking a 301 on every check. Also documented:
  `tailscale serve reset` wipes every mapping on the node.
