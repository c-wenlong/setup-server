# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project has no version numbers; entries are grouped by merged PR, newest
first, dated by merge.

## [Unreleased]

### Added

- **teardown.sh for adguard**, so it gets the launcher's Remove button,
  behind a DNS safety gate. Before changing anything it reads
  `tailscale dns status --json` and dies if this node's tailnet address
  is still a tailnet DNS resolver (stopping AdGuard then would cut DNS
  for every device). If the answer cannot be read it dies unless you
  pass `--dns-removed`. Default keeps `conf/`, `work/` and `.env`;
  `--purge` deletes them, using a throwaway container of the pinned image
  for root-owned files.

- **teardown.sh for the six services whose data hurts most to lose**:
  vaultwarden, immich, paperless-ngx, seafile, appflowy and plane, so each
  gets the launcher's Remove button. The vaultwarden, immich and
  paperless-ngx purges warn that nothing backs the box up and say what to
  export first. Service-specific:
  immich stops the server and ML before the database and always includes
  the `ml` profile; paperless keeps a non-empty `export/` (your backup) and
  `consume/` (unfiled originals); seafile purges both data and MySQL dirs
  and names the services that read its `.env`; appflowy and plane drop
  their fixed-name named volumes with `down -v` on purge only; vaultwarden,
  immich, paperless and seafile clear container-owned files with a
  throwaway container of an image already on the box.

### Fixed

- **Every teardown.sh refuses `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` or
  `COMPOSE_ENV_FILES`** in `.env` or the shell (and `COMPOSE_PROFILES`,
  except immich, whose setup.sh writes it). Compose honours them even with
  `--project-directory`, so a stray `COMPOSE_FILE` pointing at another
  stack would have let `down -v` on purge delete that stack's volumes
  (metabase and umami were already merged with this gap).

### Added

- **teardown.sh for eight more services**: firefly-iii, home-assistant,
  homepage, jellyfin, metabase, n8n, open-webui and umami, so each gets the
  launcher's Remove button. Same contract as stirling-pdf's (only the Serve
  ports pointing at the service go off, `compose down` without `-v`, data
  and `.env` kept; `--purge` behind a typed name and the real-path guard).
  Service-specific: metabase and umami purge their Postgres named volume
  with `down -v`; home-assistant, firefly-iii and open-webui clear
  root/uid-owned files with a throwaway container of the image already on
  the box instead of sudo; jellyfin's purge never deletes `MEDIA_DIR` and
  refuses if a state dir would contain it; firefly-iii unpublishes both the
  app and the Data Importer ports. Purges also remove the now-empty
  `~/services/<name>` marker, and jellyfin's marker moved to its config dir
  (its media folder stays), so a purged app reads as not installed.

### Added

- **Remove an app from the launcher.** Services that ship a `teardown.sh`
  get a Remove button (detail page and catalogue): it pauses the app's Kuma
  monitor, runs `teardown.sh` with no flags (unpublish only that app's Serve
  port, stop it), and records `removed_at` in its receipt so it reads Not
  installed while its data and `.env` stay. Installing it again resumes the
  monitor. `teardown.sh --purge` (typed confirmation) is the terminal-only
  way to delete the data. First teardown: `services/stirling-pdf`; the
  contract is in `AGENTS.md`, spec in `app/web/SPEC.md` (v7).

### Added

- **Catalogue page in the launcher.** `#/catalogue` (Catalogue button in the
  header) lists every app by category with its description, author and
  status, from the same `api/services` poll as the grid, which now carries
  each app's install receipt. Install opens the grid's existing deploy
  sheet, so it is the same confirm-then-log flow; installed apps show
  "since <date>" from the receipt, apps with no setup.sh show Coming soon.
  Search plus All / Installed / Not installed filters. Step 4 of the
  catalogue build order; spec in `app/web/SPEC.md` (v6).

### Added

- **Launcher install receipts.** A deploy run from the launcher that exits 0
  now writes `~/services/launcher/instances/<key>.json`: the repo and git
  revision it came from (read from `.git`, no subprocess), the registry's
  setup path and data dir, the non-secret `*_PORT` values from its `.env`,
  first-install and latest-deploy times and a deploy count. The detail page
  shows them as Installed / Last deploy / Revision / Ports. Tile state still
  comes from the marker and health probe. Step 2 of the catalogue build
  order; schema in `app/web/SPEC.md` (v5).

### Added

- **Launcher tiles come from per-service manifests.** Each service folder
  now has an `app.json` holding its tile (monitoring has two: Uptime Kuma
  and ntfy), and `app/web/registry.json` holds groups, control plumbing,
  tile order and the three tiles with no folder here (manimkc, ollama,
  karakeep). `scripts/build-registry.py` merges them into
  `app/web/services.json`, which the launcher and ntfy-control read as
  before; the generated file is identical in content to the hand-written
  one it replaces. `make lint` runs `build-registry.py --check`,
  `check-structure.sh` requires an `app.json` per service (ntfy-control has
  no tile), and `scripts/tests/test-build-registry.sh` covers the generator.
  First step of the catalogue build order in
  `docs/catalogue-architecture.md`.

### Changed

- **Repo layout: services in `services/`, the launcher in `app/web/`.** All
  32 service folders moved from the repo root to `services/<service>/`, and
  `launcher/` moved to `app/web/` with its static UI renamed from `web/` to
  `static/`, leaving room for `app/desktop/` later. Every root-relative path
  in docs, `services.json`, tests, CI and the Makefile follows. The launcher
  finds the repo root two levels up; ntfy-control finds `services.json` at
  `app/web/`. `scripts/check-structure.sh` now fails a `setup.sh` left at the
  root. **A deployed box must run `./scripts/migrate-layout.sh` right after
  pulling**: it moves each `.env` and other untracked files to the new
  folders (including an unsplit `paperclip-openhands/`), rewrites old paths
  in place in `.env` files, the `*-deploy` timers' deploy.sh copies under
  `~/services/*/bin/` and the systemd units / LaunchAgents, refreshes
  ntfy-control's bin/ copies, restarts only the units it repointed (it does
  not re-run setup.sh, which would re-apply default ports), and recreates
  the containers that bind-mount a file from an old folder (appflowy nginx,
  coolify, trigger-dev webapp and ClickHouse). It has a `--dry-run` and a
  mocked suite (`make test-scripts`, also in CI).

### Fixed

- **Stopped apps no longer come back after a reboot.** The 15 compose files
  that set `restart: always` (appflowy, coolify, firefly-iii, forgejo,
  home-assistant, immich, jellyfin, metabase, openhands, plane, self-learn,
  stirling-pdf, trigger-dev, umami, vaultwarden) now use `unless-stopped` on
  every service. `always` restarts a container whenever dockerd starts, even
  after the `docker stop` the launcher and ntfy-control use, so the
  2026-10-09 reboot started 35 stopped containers and filled RAM and swap.
  `scripts/check-structure.sh` now fails any compose file that sets
  `restart: always`, and AGENTS.md makes `unless-stopped` the rule.

### Added

- **quiver-hub: "Pair with Tailscale" works behind Serve.** The unit now
  runs `swe remote serve --public-url=https://<host>:<HTTPS_PORT>` (quiver
  6c70755, #570), so the hub trusts Serve's forwarded headers from loopback
  peers only, identifies the real tailnet device, and hands out https pair
  links and ntfy buttons. setup.sh refuses a quiver build without
  `--public-url`. `pair.sh` now wraps `swe remote pair`, which reads the
  public URL from the hub's `hub.json`, and refuses an http link. The live
  suite checks the flag, `hub.json` and that `swe remote pair` gives https.
- **quiver-hub: Quiver's remote-control hub (`swe remote serve`)** as a
  systemd user unit on `127.0.0.1:8477`, published tailnet-only on
  `:8477`. The phone PWA (sessions, inbox, Usage tab) and MacBook
  satellites both use that URL. quiver is installed from git at a pinned
  commit into its own uv tool dir (`~/.local/share/quiver-hub/`), so the
  interactive `swe` and the hub never upgrade each other; `QUIVER_REF`
  (default `main`) is resolved with `git ls-remote` and a re-run reinstalls
  only when the commit moved. `pair.sh` mints a pair token and prints the
  `https://` Serve link, because behind Serve the hub can't identify
  devices with `tailscale whois` and `swe remote pair` prints its loopback
  bind address. SETUP.md lists the four known gaps behind Serve. Also added
  to the README, DIRECTORY.md, the Kuma seed and the launcher registry.
  Mocked suite covers install, re-run, upgrade, SHA/tag pins, failures,
  port precedence, Serve port conflicts and `pair.sh`.
- **metabase: one-shot deploy of Metabase OSS v0.63.17.3** (self-hosted
  BI). App + Postgres, loopback-only behind Serve on `:8104` (forgejo
  already owns Metabase's upstream `:3000`). First admin seeded from
  `.env` via `POST /api/setup`. Anonymous tracking off. Mocked suite
  covers preflight, fresh install, port overrides, MB_SITE_URL drift,
  setup-API failure, operator grant and serve approval.
- **plane: one-shot deploy of Plane Community v1.4.2** (self-hosted
  Linear/Jira). Our compose, not a wrap of Plane's interactive
  setup.sh. HTTP-only proxy on `:8105`, no `:443`. First instance admin
  seeded from `.env`. MinIO from quay.io. Mocked suite covers
  preflight, fresh install, port overrides, WEB_URL drift, sign-up
  failure, operator grant and serve approval.
- **umami: one-shot deploy of Umami 3.3.1** (self-hosted web analytics).
  App + Postgres, loopback-only behind Serve on `:8106` (forgejo already
  owns Umami's upstream `:3000`). Default `admin`/`umami` password
  rotated on first boot. Mocked suite covers preflight, fresh install,
  port overrides, PUBLIC_URL drift, rotation failure, operator grant
  and serve approval.
- **Launcher theme: System, Light or Dark.** A button to the right of
  the search box cycles the three; persisted per device. System (the
  default) still follows the OS. Brand marks with a dark companion
  follow the same choice.
- **Launcher category filter.** A multi-select next to search filters
  the grid by Daily / AI & automation / Knowledge & media /
  Infrastructure.

### Changed

- **Services are grouped into four buckets** — Daily, AI & automation,
  Knowledge & media, Infrastructure — on the launcher grid/table (a
  `group` field plus a file-level catalog in `services.json`) and in the
  README. Homepage already used the same headings. Last-used / RAM /
  deployed sort still applies, inside each bucket.
- **Launcher and README brand marks for paperclip, openhands and
  trigger-dev.** Those three were falling back to the generic glyphs.
  Marks are vendored in `launcher/web/icons/` (selfh.st for Paperclip and
  OpenHands; Trigger.dev's official lime triangle). README table rows now
  show the same files.
- **Paperclip and OpenHands are separate services.** Combined
  `paperclip-openhands/` is gone. Deploy with `cd paperclip && ./setup.sh`
  and `cd openhands && ./setup.sh`. Each directory's `setup.sh` deploys
  exactly one service (now a convention in `AGENTS.md`). Existing
  `paperclip-openhands/.env` is split on first run without rotating
  secrets.
- The README coverage badge carries Codecov's graphing token, which is what a
  private repo needs for the badge to render a number instead of "unknown".
  The token is read-only and badge-scoped, so it is safe in the README.

### Added

- **stirling-pdf: one-shot deploy of Stirling PDF 2.14.3** (self-hosted
  PDF toolbox). Single container, loopback-only behind Serve on `:8103`
  (code-server already owns Stirling's upstream `:8080`). Login off —
  upstream defaults to a well-known `admin`/`stirling` pair. Mocked
  suite covers preflight, fresh install, port overrides, FRONTENDURL
  drift, leftover login form, operator grant and serve approval.
- **appflowy: one-shot deploy of AppFlowy Cloud** (self-hosted Notion).
  nginx + Postgres/pgvector + Redis + MinIO + GoTrue + cloud + admin +
  worker + web, loopback-only behind Serve on `:8102`. HTTP-only nginx
  (Serve terminates TLS). AI and the search indexer left out. Sign-up
  locked; first admin seeded from `.env`. Mocked suite covers
  preflight, fresh install, port overrides, BASE_URL drift, open
  sign-up warning, operator grant and serve approval.
- **coolify: one-shot deploy of Coolify 4.3.21** (self-hosted PaaS).
  Dashboard + Postgres + Redis + Soketi, loopback-only behind Serve on
  `:8101` (OpenHands already owns Coolify's upstream `:8000`). Traefik
  proxy off. First admin seeded from `.env`. Mocked suite covers
  preflight, fresh install, port overrides, APP_URL drift, open
  registration warning, operator grant and serve approval.
- **trigger-dev: one-shot deploy of Trigger.dev v4** for TypeScript
  background jobs and cron. Combined webapp + supervisor, pinned to
  `v4.6.0`, loopback-only behind Serve on `:8030`. Slimmed versus
  upstream (no s2-lite, events in Postgres, 768 MiB Node heap, concurrency 2).
  ClickHouse still runs — v4.6.0 Zod-requires `CLICKHOUSE_URL` at boot.
  so it fits a 7.7 GB box. Local registry on `127.0.0.1:5000`. Mocked
  suite covers preflight, fresh install, port overrides, origin drift,
  magic-link-once, operator grant and serve approval.
- **paperclip: one-shot deploy of the Paperclip control plane.** Official
  managed CLI (`onboard --yes --bind tailnet`, then rewritten to
  authenticated + loopback so Serve can front it — never `local_trusted`
  on the tailnet). Existing Claude/Codex credentials are not written.
  Mocked suite covers preflight, fresh install, the managed-CLI path,
  local_trusted repair, idempotent re-run, port overrides, serve
  approval, CEO-invite races and agent provisioning.
- **openhands: one-shot deploy of OpenHands Agent Canvas.** Official
  image on `:8000` (`--public`, generated API key, `~/agent-workspaces`
  only). Existing Claude/Codex credentials are not written.
- **paperclip: editable email and password on Profile.** Upstream leaves
  those read-only / missing. `setup.sh` now enables Better Auth
  `change-email` without SMTP and injects fields on Settings → Profile.
- **paperclip: placeholder `PAPERCLIP_EMAIL` / `PAPERCLIP_PASSWORD` in
  `.env`.** Written on first run and appended if missing; not applied to
  the instance yet. Default `changeme@example.com` / `changeme`.

### Fixed

- **openhands: Canvas 502 `ECONNREFUSED 127.0.0.1:18000`.**
  `setup.sh` created `~/services/openhands/data` as `0700` for the host
  user; the image runs as uid `10001`, so the agent server died on
  `conversations/` and the ingress proxyed a 502. Grant uid 10001 write
  via ACL (or `a+rwx` where `setfacl` is missing) on the data dir and
  `~/agent-workspaces`.
- **immich: overriding only `LOCAL_PORT` split the two ports.** `HTTPS_PORT`
  defaulted to a literal 2283 instead of following `LOCAL_PORT` the way n8n
  and kaichenpedia do, so `LOCAL_PORT=2284 ./setup.sh` published
  `:2283 -> 127.0.0.1:2284`. The default now follows the local port, on the
  first run and on a re-run where `.env` holds the port, while an explicit
  `HTTPS_PORT` is honoured as given. New mocked test covers all three cases.
- **beszel/setup.sh could not run on macOS and skipped the preflight
  convention.** It was the one script with no `uname -s` branch, no root
  refusal, no Tailscale-running check, and a bare `tailscale` call that the
  macOS app bundle never satisfies. It now follows the code-server (native)
  and forgejo (Docker) references: OS branch, root refusal, resolved Tailscale
  CLI, daemon and Compose v2 checks, the agent tarball picked by OS and
  architecture, a launchd LaunchAgent on macOS, lingering and the Serve
  operator grant as the two one-time Linux sudos, and a final URL resolved
  from the tailnet rather than hardcoded. `.env` is now the source of truth
  for the port on a re-run. The static suite gained ten checks for the
  contract; verified by a live re-run on the box.
- **Three suites declared `FAKE_TS_IP` and never used it.** firefly-iii now
  asserts the listener audit accepted tailscaled's Serve proxy on the stub's
  tailnet address for both ports (and resolved it via `tailscale ip -4`),
  remote-desktop's two literal `100.77.77.77` assertions use the variable,
  and homepage drops it (its audit never names the address; the ss and
  tailscale stubs share it between themselves).
- **Stale comments and dead code left over from the docs audit.**
  code-server's suite header named a script that never existed; seafile's
  header and SETUP.md still said `~/seafile/` (it is
  `~/services/seafile/{data,mysql}`); home-assistant's suite and SETUP.md
  cited an `HA-DERISK.md` that is not in the repo. Removed
  `HTTP_STORE_ACTION` (home-assistant), `CONTAINER` (jellyfin) and two unused
  locals in the paperless-ngx and remote-desktop live suites, all assigned
  and never read. `control.primary` in `launcher/services.json` is read by
  ntfy-control's listener, not the launcher; the schema comment and the
  copy in `launcher/server.py` now say so instead of implying the launcher
  uses it.
- **The structure check could fail CI on a branch whose README was identical
  to main's.** `links_to` piped `grep` into `grep -q` under `pipefail`; when
  the reader exited on its first match the writer took SIGPIPE and the row
  was reported missing. One awk scan now, no pipe.
- **Eight more services defaulted `HTTPS_PORT` to a literal instead of
  `LOCAL_PORT`.** forgejo, jellyfin, vaultwarden, adguard, homepage,
  paperless-ngx, firefly-iii (both port pairs) and home-assistant now follow
  the same rule immich got: the published port follows the local port unless
  set explicitly, on the first run and on re-runs. The five whose `.env` holds
  no `HTTPS_PORT` carry the same read-back guard as immich; the three that
  store it needed only the default line. One mocked test per service.
- **open-webui is published on `:3001`, not `:10000`.** The old number was
  picked when Tailscale Serve only allowed 443/8443/10000, a limit that is
  long gone, so the published port now follows the local port like every
  other service. `HTTPS_PORT` still wins when set explicitly. The listener
  audit in its live suite moved to the canonical `no_external_listener`:
  with both ports on 3001, tailscaled's own Serve proxy holds the tailnet
  address on that number, and the old "anything but 127.0.0.1 is a leak"
  reading failed a correct deploy. DIRECTORY.md, the README of the service,
  the Kuma seed, the Homepage tile and the launcher registry follow. A re-run
  on a box still published on :10000 withdraws that mapping, but only when it
  points at this service, since Serve otherwise keeps both ports alive.

## [PR #6](https://github.com/c-wenlong/setup-server/pull/6) - 2026-09-12

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

- The homepage mocked suite compared `PUID` against the real uid while the
  `id` stub always reports 1000, so it failed on a GitHub runner (uid 1001).

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
