# design-systems — gallery of the private design library, auto-deployed from the working clone

The docs site + gallery of the private
[c-wenlong/designs](https://github.com/c-wenlong/designs) repository — a
library of design systems captured from real products, one package per
product under `systems/<slug>/`, plus a scorecard of how complete each
capture is. Served by nginx and published tailnet-only. It is the same site
the repo's `make serve` builds locally; unlike the repo's public GitHub
Pages deploy (which strips the gallery and encrypts every page), this one
serves the gallery and the repo paths openly — that is the whole point of
running it, and tailnet-only is what makes it consistent with the repo's
"never publish `systems/` or the gallery" rule.

A commit on the clone's `main` goes live on the daily poll — or
immediately with `~/services/design-systems/bin/deploy.sh --force`.

## Architecture

```
        push from any device
               │
               ▼
        GitHub (private repo) ── outbound git pull --ff-only + lfs pull,
               │                    daily (POLL_SECONDS)
               ▼                          │
        ~/dev/design-systems ◄────────────┘
        (the working clone; the         design-systems-deploy.timer ──► bin/deploy.sh
         deploy only reads it            (systemd user timer;            │ 1. git pull --ff-only
          and pulls it forward,           launchd on macOS)              │    (best effort)
          never commits)                                               │ 2. git lfs pull (screenshots
          ▲                                                            │    are LFS objects)
          │                                                            │ 3. python3 tools/catalog.py build
          │                                                            │    (gallery data.json + thumbs/)
          │                                                            │ 4. python3 tools/scorecard.py
          │                                                            │    (docs/scorecard/ + zensical.toml)
          │                                                            │ 5. .venv/bin/zensical build --clean
          │                                                            │    (docs site into site/)
          │                                                            │ 6. atomic repoint  current -> releases/<sha>
          │                                                            ▼
          │                                              ~/services/design-systems/www/current
          │                                                            │  bind mount (ro)
          │                                                            ▼
          └──── /systems|/tools|/example|catalog.json|README.md ── nginx (Docker)
                 (read-only mount of the checkout,                  127.0.0.1:8108
                  same allowlist make serve answers)                     │
                                                                         ▼
                                                  Tailscale Serve  HTTPS :8108 (tailnet only)
                        https://kai-home-server.taild6a23f.ts.net:8108/gallery/
```

## Why the working clone, not a deploy clone

Same reasoning as `sources/`: the clone already exists at
`~/dev/design-systems` and a second copy would double ~300 MB of LFS media
for nothing. `deploy.sh` pulls `main` forward (`--ff-only`, best effort)
and builds whatever the working tree holds — uncommitted edits included,
which is exactly what the repo's own `make serve` does. It never commits,
resets or writes git state. (It does write build outputs into the
checkout's gitignored `docs/gallery/`, `docs/scorecard/` and `site/` — the
same files `make build` / `make serve` write.)

## Why nginx answers repo paths

The gallery's `data.json` records paths like
`systems/linear/screenshots/home.png` — full-size screenshots and package
files that are not part of the built site (they are LFS objects, ~300 MB).
The repo's dev server answers a fixed allowlist (`tools/catalog.py`'s
`REPO_PATHS`: `/systems/`, `/tools/`, `/example/`, `/catalog.json`,
`/README.md`) from the checkout. nginx does the same with `alias` onto a
read-only bind mount of `SOURCE_REPO`, so a release stays small and the
checkout is the single copy.

## Why polling, not a webhook

The box is tailnet-only, so GitHub can't reach it. Polling is outbound-only
and free; worst-case latency is `POLL_SECONDS` (daily by default), and
`deploy.sh --force` skips the wait.

## Security model

- nginx binds `127.0.0.1:8108` only; HTTPS + device auth come from
  Tailscale.
- The site is static files — no app code, no database, no accounts.
- **This site is deliberately not encrypted**, unlike the repo's Pages
  deploy. It serves readable package files, screenshots and the scorecard.
  That is within the repo's rules — AGENTS.md forbids publishing them
  *publicly* (the Pages site strips the gallery for that reason). The
  tailnet is the perimeter: anything on the tailnet can browse the full
  library. Treat it like the sources passphrase site, minus the passphrase.
- `.env` holds only paths and ports (no secrets), but is still written
  `0600` and gitignored like every service's.

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git | pull the clone forward | presence |
| python3 | `tools/catalog.py build` + `tools/scorecard.py` (stdlib-only; Pillow is used for thumbnails when installed) | presence |
| uv | installs the repo's pinned Zensical into `.venv` (once) | presence |
| git-lfs | materialise screenshot/font objects; without it the checkout holds ASCII pointers and the thumbnail step crashes | pointer scan → `git lfs pull`, die if any remain |
| the clone at `SOURCE_REPO` | the build's entire input + the served repo paths | `.git/` + `tools/catalog.py` exist |
| Docker + Compose v2 | nginx container | daemon reachable |
| Tailscale (running) | HTTPS publish | backend state |

## What setup.sh does

1. Preflight (above), including the LFS pointer scan — if any screenshot in
   `systems/` is still a pointer, it runs `git lfs pull` and dies only if
   pointers remain after it.
2. Writes `.env` if absent (repo path, branch, ports, poll interval, uv
   path, service home; mode `0600`). Re-runs read `.env` as the source of
   truth.
3. Writes `~/services/design-systems/nginx.conf` if absent (docs site +
   the repo-path aliases).
4. Installs `deploy.sh` -> `~/services/design-systems/bin/` (refreshed
   every run; edit the repo copy, then re-run setup.sh).
5. Runs the initial deploy: pull, `lfs pull`, `catalog.py build`,
   `scorecard.py`, `zensical build`, copy `site/` to `www/next`, swap.
   Bootstraps the repo's `.venv` with the pinned Zensical if missing.
6. `docker compose up -d` (nginx, `restart: unless-stopped`) + local health
   check on `/gallery/`.
7. Installs the poller: systemd user timer (`OnUnitActiveSec=POLL_SECONDS`)
   + lingering on Linux; a launchd `StartInterval` agent on macOS.
8. Publishes via `tailscale serve --bg --https=8108` and verifies
   `/gallery/` end-to-end.

## Deploy

```sh
cd design-systems && ./setup.sh
```

Overrides: `LOCAL_PORT` / `HTTPS_PORT` (default 8108), `SOURCE_REPO`
(default `~/dev/design-systems`), `BRANCH` (main), `POLL_SECONDS`
(86400 = daily).

## Ops

```sh
~/services/design-systems/bin/deploy.sh --force           # rebuild right now
journalctl --user -u design-systems-deploy -n 50          # deploy history
systemctl --user list-timers design-systems-deploy.timer
docker compose --project-directory ~/dev/setup-server/design-systems ps|logs|restart
tailscale serve status
```

A failed build leaves `www/current` pointing at the last release — a
broken commit never takes the site down, and the repoint itself is one
rename (no gap where nginx has no root). The previous release stays in
`www/releases/` for rollback. If `git pull` fails (dirty tree, offline,
diverged) the poller builds the local HEAD instead and notes it in the
log.

The repo-path aliases (`/systems/` etc.) are served live from the
checkout, not from the release — they reflect the working tree
immediately, independent of any deploy.

## Client side

Nothing to install. Open
`https://kai-home-server.taild6a23f.ts.net:8108/gallery/` from any tailnet
device. No passphrase — the tailnet is the boundary. The scorecard is at
`/scorecard/`, the docs site at `/`.
