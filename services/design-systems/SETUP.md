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
        GitHub (private repo) ◄─ deployd polls ls-remote every minute
               │                    (services/deployd)
               ▼                          │
        ~/dev/design-systems ◄────────────┘
        (the working clone; the         deployd ──► setup.sh ──► bin/deploy.sh
         deploy only reads it            (one poller for all               │ 1. git pull --ff-only
          and pulls it forward,           deploy blocks)                   │    (best effort)
          never commits)                                               │ 2. git lfs pull (screenshots
          ▲                                                            │    are LFS objects)
          │                                                            │ 3. python3 tools/catalog.py build
          │                                                            │    (gallery data.json + thumbs/)
          │                                                            │ 4. python3 tools/scorecard.py
          │                                                            │    (docs/scorecard/ pages)
          │                                                            │ 5. .venv/bin/python tools/site.py
          │                                                            │    (docs site into site/)
          │                                                            │ 6. atomic repoint  current -> releases/<sha>
          │                                                            ▼
          │                                              ~/services/design-systems/www/current
          │                                                            │  bind mount (ro)
          │                                                            ▼
          └──── /systems|/tools|/example|catalog.json|README.md ── nginx (Docker)
                 (read-only mount of the checkout,                  127.0.0.1:8108
                  same allowlist make serve answers)                     ▲
                                                                        │  bind mount (ro)
                                              ~/services/design-systems/media
                                              (refero shots/posters/videos/favicons,
                                               mirrored by tools/refero/mirror_media.py)
                                                                         ▼
                                                  Tailscale Serve  HTTPS :8108 (tailnet only)
                        https://homeserver.tail-name.ts.net:8108/gallery/
```

## Why the working clone, not a deploy clone

Same reasoning as `services/sources/`: the clone already exists at
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

Refero media follows the same idea but lives outside the repo: the
gallery's `#/refero` pages point at `/refero-media/shots|posters|videos|
detail|favicons/<slug>.*`, aliased onto `~/services/design-systems/media/
refero/` (populated by `python3 tools/refero/mirror_media.py` from the
repo). Videos are too heavy to commit or to copy per release, so the mirror
is a host-side dir — a missing file falls back to the refero CDN URL in
the browser, nothing breaks.

## Why polling, not a webhook

The box is tailnet-only, so GitHub can't reach it. deployd
(`services/deployd`) resolves `main` with `git ls-remote` every minute and
re-runs this service's `setup.sh` when it moves — `deploy.sh --force`
skips the wait entirely.

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
| uv | installs the site builder's `markdown` dep into `.venv` (once) | presence |
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
   the repo-path aliases + the `/refero-media/` media alias). It also
   carries the response policy: gzip for the text assets (`data.json`
   alone is ~1.5 MB, ~120 KB on the wire) and a Cache-Control per file
   class — `no-cache` revalidation for HTML, JSON, the unhashed
   `app.js`/`style.css` and the repo paths, 1 day for `gallery/thumbs/`
   (names are path-derived, not content-hashed) and 30 days for the
   write-once `/refero-media/` mirror. An existing conf is never
   overwritten; if it predates the media alias or the gzip/Cache-Control
   block, setup.sh prints what to add.
4. Installs `deploy.sh` -> `~/services/design-systems/bin/` (refreshed
   every run; edit the repo copy, then re-run setup.sh).
5. Runs the initial deploy: pull, `lfs pull`, `catalog.py build`,
   `scorecard.py`, `tools/site.py`, copy `site/` to `www/next`, swap.
   Bootstraps the repo's `.venv` (the `markdown` package the site build needs) if missing.
6. `docker compose up -d` (nginx, `restart: unless-stopped`) + local health
   check on `/gallery/`.
7. Removes the old per-service `design-systems-deploy` timer / LaunchAgent
   if a host still has one — deployd (`services/deployd`) owns scheduling
   now. Removal only happens once deployd itself is installed
   (`~/services/deployd/bin/deployd`); without it the old poller stays and
   setup warns, so install `services/deployd` first for auto-deploy.
8. Publishes via `tailscale serve --bg --https=8108` and verifies
   `/gallery/` end-to-end.

## Deploy

```sh
cd services/design-systems && ./setup.sh
```

Overrides: `LOCAL_PORT` / `HTTPS_PORT` (default 8108), `SOURCE_REPO`
(default `~/dev/design-systems`), `BRANCH` (main). Overriding `BRANCH` or
pointing `SOURCE_REPO` at a different remote desyncs auto-deploy: deployd
polls the repo/ref declared in `services/design-systems/app.json`'s `deploy`
block (`main` on `https://github.com/c-wenlong/designs.git`), so edit the
manifest to match or pushes to the override never trigger a deploy.

## Ops

```sh
~/services/design-systems/bin/deploy.sh --force           # rebuild right now
~/services/deployd/bin/deployd --status                   # what deployd last saw/deployed
journalctl --user -u deployd -n 50                        # poll + deploy history (macOS: ~/Library/Logs/deployd.log)
docker compose --project-directory ~/dev/setup-server/services/design-systems ps|logs|restart
tailscale serve status
./teardown.sh             # Remove: unpublish + stop container; keeps state, .env, your clone
./teardown.sh --purge     # also delete ~/services/design-systems state, the unit files and .env (asks first)
```

`teardown.sh` never touches the clone at `~/dev/design-systems` or
`designs-trigger.service` (which `setup.sh` does not create); it warns about
the latter if present.

A failed build leaves `www/current` pointing at the last release — a
broken commit never takes the site down, and the repoint itself is one
rename (no gap where nginx has no root). The previous release stays in
`www/releases/` for rollback. If `git pull` fails (dirty tree, offline,
diverged) the deploy builds the local HEAD instead and notes it in the
log.

The repo-path aliases (`/systems/` etc.) are served live from the
checkout, not from the release — they reflect the working tree
immediately, independent of any deploy.

## Client side

Nothing to install. Open
`https://homeserver.tail-name.ts.net:8108/gallery/` from any tailnet
device. No passphrase — the tailnet is the boundary. The scorecard is at
`/scorecard/`, the docs site at `/`.
