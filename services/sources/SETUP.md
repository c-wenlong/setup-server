# sources — encrypted archive browser, auto-deployed from the fetch clone

The passphrase-encrypted static build of the private
[c-wenlong/sources](https://github.com/c-wenlong/sources) archive (YouTube
transcripts, blogs, newsletters, papers, personas), served by nginx and
published tailnet-only. It is the same build `apps/web/build/run_web.sh` serves
locally and the `site` workflow pushes to GitHub Pages — same passphrase
unlocks all three. A commit on the fetch clone's `main` (the weekly fetch,
or a push from any device) goes live on the daily poll — or immediately
with `~/services/sources/bin/deploy.sh --force`.

## Architecture

```
weekly fetch timer ──┐                     push from any device
 (commits + pushes   │                            │
  on this clone)     ▼                            ▼
              ~/dev/sources  ◄────────────  GitHub (private repo)
              (the fetch clone,         ▲
               already machine-         │ deployd polls ls-remote every
               managed on main)         │ minute (services/deployd)
                     ▲                       │
                     │      deployd ──► setup.sh ──► bin/deploy.sh
                     │     (one poller for        │ 1. flock .git/sources-fetch.lock
                     │      all deploy blocks)   │    (shared with fetch_all.sh —
                     │                            │     no build over a half-fetched tree)
                     │                            │ 2. git pull --ff-only (best effort)
                     │                            │ 3. uv sync --quiet
                     │                            │ 4. uv run apps/web/build/build_site.py --out www/next
                     │                            │    (gzip + AES-256-GCM per file;
                     │                            │     SITE_PASSPHRASE from .env)
                     │                            │ 5. atomic repoint  current -> releases/<sha>
                     │                                ▼
                     │                     ~/services/sources/www/current
                     │                                │  bind mount (ro)
                     │                                ▼
                     └──────── reads ──  nginx (Docker) 127.0.0.1:8098
                                                │
                                                ▼
                              Tailscale Serve  HTTPS :8098 (tailnet only)
                     https://homeserver.tail-name.ts.net:8098
```

## Why the fetch clone, not a deploy clone

kaichenpedia keeps a machine-managed clone in `~/services/kaichenpedia/repo`
because nothing else on the box needs it. For sources that clone already
exists: `~/dev/sources` is where `sources-fetch.timer` pulls, fetches and
commits every week, and its docs already require it to stay clean on `main`
(`docs/FETCHING.md`: develop in a worktree). A second clone would double a
multi-GB corpus for nothing, so `deploy.sh` shares the fetch clone: it pulls
`main` forward (`--ff-only`, best effort) and builds whatever HEAD lands on.
It never commits, resets or writes into the repo. Only committed state is
ever built — a fetch run mid-flight still shows the last commit's tree.

## Why polling, not a webhook

Same reasoning as kaichenpedia: the box is tailnet-only, so GitHub can't
reach it. deployd (`services/deployd`) resolves `main` with
`git ls-remote` every minute and re-runs this service's `setup.sh` when it
moves — `deploy.sh --force` skips the wait entirely. Anything pushed to
origin (the weekly fetch included) lands on the next tick; a commit that
only ever exists in the local clone never reaches the remote, so it does
not trigger a deploy.

## Security model

- nginx binds `127.0.0.1:8098` only; HTTPS + device auth come from Tailscale.
- The site is static files — no app code, no database, no accounts.
- Every corpus file (`d/*.bin`) is gzip + AES-256-GCM under a key derived
  from `SITE_PASSPHRASE` (PBKDF2-SHA256, fixed salt in
  `apps/web/build/build_site.py`). Only the app shell is plaintext. The passphrase
  is the same one as the sources repo's GitHub secret and what you type to
  unlock the site; use the same value so one passphrase opens both sites.
- `.env` holds the passphrase, so it is written `0600` and is gitignored —
  the repo-wide check in `scripts/check-structure.sh` fails if any `.env`
  is ever tracked.
- Web Crypto needs a secure context; `https://*.ts.net` qualifies (so does
  `localhost` for `run_web.sh`).

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git | pull the fetch clone forward | presence |
| uv | `uv run apps/web/build/build_site.py` | presence |
| the sources clone at `SOURCE_REPO` | the build's entire input | `.git/` + `apps/web/build/build_site.py` (or the older `scripts/build_site.py`) exist |
| `SITE_PASSPHRASE` (first run) | encryption key; lands in `.env` | non-empty |
| Docker + Compose v2 | nginx container | daemon reachable |
| Tailscale (running) | HTTPS publish | backend state |

## What setup.sh does

1. Preflight (above), including that the fetch clone exists and that a
   first run has `SITE_PASSPHRASE` in the environment.
2. Writes `.env` if absent (repo path, branch, ports, poll interval, uv
   path, service home, passphrase; mode `0600`). Re-runs read `.env` as
   the source of truth and never need the passphrase again.
3. Writes `~/services/sources/nginx.conf` if absent (plain static serving;
   all routing is client-side hash routes).
4. Installs `deploy.sh` -> `~/services/sources/bin/` (refreshed every run;
   edit the repo copy, then re-run setup.sh).
5. Runs the initial deploy: pull, `uv sync`, `build_site.py`, swap.
6. `docker compose up -d` (nginx, `restart: unless-stopped`) + local health
   check.
7. Removes the old per-service `sources-deploy` timer / LaunchAgent if a
   host still has one — deployd (`services/deployd`) owns scheduling now.
   Removal only happens once deployd itself is installed
   (`~/services/deployd/bin/deployd`); without it the old poller stays and
   setup warns, so install `services/deployd` first for auto-deploy.
8. Publishes via `tailscale serve --bg --https=8098` and verifies
   end-to-end.

## Deploy

```sh
cd services/sources && SITE_PASSPHRASE='the site passphrase' ./setup.sh
```

Overrides: `LOCAL_PORT` / `HTTPS_PORT` (default 8098), `SOURCE_REPO`
(default `~/dev/sources`), `BRANCH` (main). Overriding `BRANCH` or pointing
`SOURCE_REPO` at a different remote desyncs auto-deploy: deployd polls the
repo/ref declared in `services/sources/app.json`'s `deploy` block
(`main` on `https://github.com/c-wenlong/sources`), so edit the manifest to
match or pushes to the override never trigger a deploy.

## Ops

```sh
~/services/sources/bin/deploy.sh --force             # rebuild right now
~/services/deployd/bin/deployd --status              # what deployd last saw/deployed
journalctl --user -u deployd -n 50                   # poll + deploy history (macOS: ~/Library/Logs/deployd.log)
docker compose --project-directory ~/dev/setup-server/services/sources ps|logs|restart
tailscale serve status
./teardown.sh                                        # Remove: unpublish + stop container; files and .env kept
./teardown.sh --purge                                # also delete site files, .env (SITE_PASSPHRASE!) and unit files
```

A failed build leaves `www/current` pointing at the last release — a
broken commit never takes the site down, and the repoint itself is one
rename (no gap where nginx has no root). The previous release stays in
`www/releases/` for rollback. If `git pull` fails (dirty tree, offline,
diverged) the deploy builds the local HEAD instead and notes it in the
log; if a fetch is mid-run the deploy waits for its lock up to 15 min,
then skips to the next tick.

## Client side

Nothing to install. Open
`https://homeserver.tail-name.ts.net:8098` from any tailnet device
and unlock with the site passphrase (the same one the GitHub Pages site
uses — changing it anywhere logs everyone out everywhere, since the salt
is fixed).
