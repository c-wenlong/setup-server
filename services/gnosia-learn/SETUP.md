# gnosia-learn — Gnosia study hub, auto-deployed from GitHub

A production build of the private
[c-wenlong/self-learn](https://github.com/c-wenlong/self-learn) repo: a
Next.js 16 app over a SQLite catalog, served natively and published
tailnet-only. Push to `main` and the box picks it up on its daily poll —
or immediately with `~/services/gnosia-learn/bin/deploy.sh --force`.

The repo's own `docs/HOMESERVER.md` describes this exact deployment shape;
this service wraps it in the repo's usual one-shot, idempotent form. Where
they differ: systemd **user** units instead of system units (the repo's
sudo rule), and the deploy/update order from upstream step 14 baked into a
poller. Upstream moved the catalog from Postgres to a single SQLite file
(`docs/SQLITE-MIGRATION.md` there): it lives at `$CATALOG_DB` under the
data root, so no database container runs at all.

## Architecture

```
git push (laptop)
        │
        ▼
   GitHub (private repo)
        ▲  outbound git fetch, daily (POLL_SECONDS)
        │
gnosia-learn-deploy.timer ──► bin/deploy.sh          gnosia-learn-export.timer
  (systemd user timer;          │                     (nightly 03:00:
   launchd on macOS)            │ 1. stop app + studio if   catalog export ->
                                │    running                ~/.gnosia/archive)
                                │ 2. git reset --hard
                                │    origin/main
                                │ 3. write checkout env files
                                │    (apps/web/.env.local,
                                │     services/catalog/.env)
                                │ 4. npm ci      (only when package-lock changes)
                                │ 5. catalog migrate
                                │ 6. next build
                                │ 7. start app + studio if they were running
                                ▼
              ~/services/gnosia-learn/repo  (machine-managed clone)
                                │  next start -p 8107 -H 127.0.0.1
                                ▼
              gnosia-learn.service (systemd user unit / launchd)
                     │           127.0.0.1:8107 ──► Tailscale Serve HTTPS :8107
                     │  https://homeserver.tail-name.ts.net:8107
                     │                            (tailnet only)
                     │  /studio/api/* proxied to ──► gnosia-learn-studio.service
                     ▼          (npm run studio — diagram job runner, spawns
        the catalog: one SQLite  the claude CLI per job, loopback-only on
        file the app, catalog    127.0.0.1:7250 — never Serve-published.
        CLI and studio all open  Runs only while STUDIO_ENABLED=1 in .env;
                     │           job state under ~/services/gnosia-learn/studio)
                     ▼
   ~/.gnosia/  catalog.db  blobs/ vault/ archive/
        (upstream layout — rsync target; catalog.db is the whole database,
        no server to run)
```

## Security model

- The app binds `127.0.0.1` only; HTTPS + device auth come from Tailscale
  Serve. Upstream's S6 notes Serve forwards `Host` and
  `X-Forwarded-Proto: https`, which is exactly what the app's session
  cookie and same-origin check read — no app-side setting needed.
- The catalog is one SQLite file at `$CATALOG_DB` under `~/.gnosia`:
  no server, no port, no credentials — its only boundary is the
  filesystem, which already holds the blob store beside it.
- Sign-in is the app's own `OWNER_PASSWORD` + signed cookie (one owner,
  upstream's "one reader" model). Tailnet is still the perimeter; the
  password gates a roommate on the tailnet, not the internet.
- `OWNER_PASSWORD` / `AUTH_SECRET` are generated into `.env` (mode 600)
  on first run and never overwritten. Every file that carries them — the
  checkout env files below — is written mode 600.
- The deploy clone (`~/services/gnosia-learn/repo`) is machine-managed and
  hard-reset on every deploy — **never edit it by hand**. The two env
  files inside it (`apps/web/.env.local`, `services/catalog/.env`) are
  rewritten from `.env` on every deploy; rotate secrets in `.env`, then
  `deploy.sh --force`.
- A deliberately stopped app stays stopped across deploys *and* setup
  re-runs: the poller rebuilds and migrates but only restarts the app if
  it was running. If a deploy step fails partway, the previous
  `node_modules`/`.next` are restored from the rename-aside snapshot and
  the old build restarted — never a half-written tree.

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git + non-interactive repo access | poller fetches the private repo unattended | `git ls-remote` with prompts disabled |
| Node.js >= 22.22.2 (+ npm) | upstream `engines`; build, catalog CLI, `next start`, studio runner | version compare |
| Tailscale (running) | HTTPS publish | backend state |
| `claude` CLI, logged in | the studio runner spawns it per job | resolved at unit-write time (`PATH`, then `~/.nix-profile`, `~/.claude/local`, homebrew); a miss only **warns** — the app deploys fine, studio jobs just fail until it lands |

Not needed: Docker or any database tools (the catalog is a SQLite file;
migrations and the seed go through the catalog CLI, and bringing the
laptop's data over is a file copy — below), the video-tool submodules
(`tools/manimkc`, `tools/remotionkc`,
`tools/revideokc` stay uninitialised — the seed import is pointed at
`/nonexistent` roots). The one submodule exception is `tools/tldrawkc`:
the studio runner refuses to queue jobs without it built, so while
`STUDIO_ENABLED=1` the deploy script keeps it initialised and rebuilds
it whenever the recorded gitlink moves.

## What setup.sh does

1. Preflight (above).
2. Writes `.env` if absent (ports, paths, the `GNOSIA_HOME`/`CATALOG_DB`
   catalog location, generated `OWNER_PASSWORD` and `AUTH_SECRET`). Re-runs
   read `.env` as the source of truth — `LOCAL_PORT=...` on the command
   line is ignored once `.env` exists. An `.env` written before the SQLite
   cut-over keeps working: its stale `postgres://` `DATABASE_URL` is
   unused, and `GNOSIA_HOME`/`CATALOG_DB` derive to the data root it names
   through `SELF_LEARN_HOME`. An `.env` from before the rename keeps its
   root at `~/.self-learn` the same way — the paths below assume the
   fresh default `~/.gnosia`.
3. Installs `deploy.sh` -> `~/services/gnosia-learn/bin/` (refreshed every
   run) and creates `$GNOSIA_HOME/blobs`.
4. Writes the units — `gnosia-learn.service` (the app),
   `gnosia-learn-studio.service` (the diagram job runner), the deploy
   `.timer`, the nightly export `.timer` — or the four LaunchAgents.
   The studio unit gets the resolved `claude` path baked in as
   `STUDIO_CLAUDE_BIN` and `STUDIO_HOME=~/services/gnosia-learn/studio`,
   so job workspaces survive a checkout re-clone.
5. Runs the initial deploy: clone, env files, `npm ci`, `catalog
   migrate` (creates the SQLite file on first connect), `next build`.
6. Bootstraps the catalog **once** (marker `state/db-bootstrapped`):
   `catalog import seed`, six `catalog flip`s in upstream order, and
   `catalog blob audit --fix` to claim the blob root for this database.
   `SKIP_SEED=1` skips this so the laptop's `catalog.db` can be dropped
   in place instead (below).
7. Enables + starts the app and both timers, enables lingering (Linux),
   and publishes `tailscale serve --bg --https=8107`. The studio runner
   is enabled + started only while `STUDIO_ENABLED=1` — flipping the flag
   to 0 and re-running stops and disables it. An app that was
   deliberately stopped before the re-run is left stopped (studio
   follows it).

## Deploy

```sh
cd services/gnosia-learn && ./setup.sh
```

Overrides (first run only — after that, edit `.env`): `LOCAL_PORT` /
`HTTPS_PORT` (default 8107), `REPO_URL`, `BRANCH`
(main), `POLL_SECONDS` (86400 = daily), `SKIP_SEED` (1 = leave the
catalog empty for a `catalog.db` drop-in), `OWNER_PASSWORD`, `AUTH_SECRET`,
`STUDIO_ENABLED` (0; 1 = run the studio job runner + UI — needs a
logged-in `claude`), `ASSET_FILES_ENABLED` (1).

For a real deployment, pass the **laptop's `AUTH_SECRET`** on first run
(`AUTH_SECRET=... ./setup.sh`): provider keys saved in Settings are
sealed under a key derived from it, so matching secrets keep them
readable on both machines (upstream S4). `OWNER_PASSWORD` is checked,
not used to encrypt anything — it can differ freely.

## Bringing the laptop's data over

The homeserver's database is its own `primary`, meant to diverge from
the laptop's (upstream S1) — the seed is only the demo slice. To move
the real history instead, copy the catalog file: the database is one
SQLite file now, so the old pg_dump/restore dance is a file copy.

```sh
# on the laptop — .backup makes a consistent single file even while a
# dev checkout has the database open
sqlite3 ~/.gnosia/catalog.db ".backup '$HOME/laptop-catalog.db'"
scp ~/laptop-catalog.db homeserver:~/catalog.db
rsync -a --exclude .owner ~/.gnosia/blobs/ homeserver:~/.gnosia/blobs/

# first deploy here — leave the catalog file empty
cd services/gnosia-learn && SKIP_SEED=1 AUTH_SECRET=<laptop's> ./setup.sh

# swap the laptop's file in for the migrated-but-empty one the deploy
# left (the app must be stopped while the file is replaced), then claim
# the blob root for it
systemctl --user stop gnosia-learn
mv ~/catalog.db ~/.gnosia/catalog.db
cd ~/services/gnosia-learn/repo && npm run catalog -- doctor && npm run catalog -- blob audit --fix
systemctl --user start gnosia-learn
```

(The same swap covers a catalog that *was* seeded — `mv` replaces the
file wholesale. On macOS the stop/start is `launchctl bootout` /
`bootstrap` on `com.gnosia-learn.web`.) The `--exclude .owner` matters:
the blob store's marker names its database by resolved path, so a copied
marker names the laptop's file — a path that is not here — and uploads
and `audit --fix` would refuse the root (upstream S3).

### Coming from the Postgres deployment

A box deployed before the cut-over keeps its catalog in the old
`self-learn-db` container (named volume `self-learn-postgres`) — the
scripts no longer manage either, so port the data once, then remove
them. The container still answers on its old loopback port even though
`docker-compose.yml` is gone:

```sh
docker start self-learn-db   # no-op if it is already running
set -a; . services/gnosia-learn/.env; set +a   # POSTGRES_USER, _PASSWORD, _DB, PG_PORT
cd ~/services/gnosia-learn/repo
node services/catalog/scripts/pg-to-sqlite.mjs \
  --from "postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:$PG_PORT/$POSTGRES_DB" \
  --to ~/.gnosia/catalog.db
```

The port migrates the fresh file to head, copies every table and runs
`foreign_key_check` before finishing (upstream
`docs/SQLITE-MIGRATION.md`); it refuses if `catalog.db` already exists —
delete the empty one a fresh deploy created first. Afterwards:
`npm run catalog -- doctor && npm run catalog -- blob audit --fix`, then
`docker rm -f self-learn-db && docker volume rm self-learn-postgres`.
Blobs need no move — `GNOSIA_HOME` derives to the same root the old
`.env`'s `SELF_LEARN_HOME` already named.

## Syncing with the MacBook (`sync.sh`)

The one-shot rsync above becomes continuous with `sync.sh`. Blobs ride a
dedicated Seafile library in both directions; the database rides
`push`/`pull` only when asked — the two catalogs are meant to diverge,
so a transfer is always a full replace (a copy of the whole `catalog.db`
file, swapped in while the receiving app is stopped), never a merge.

```
server                          Seafile                          MacBook
~/.gnosia/blobs/local ◄── gnosia-learn-blobs library ──► ~/.gnosia/blobs/local
  seaf-cli daemon      dedicated non-admin sync account          Seafile Client.app
  (gnosia-learn-         (.owner + .tmp sit beside local/,          (GUI pairing —
   seafile.service)     outside the synced tree)                   no seaf-cli on macOS)

./sync.sh push ──► copy catalog.db here ──► scp ──► swap it in on the Mac
./sync.sh pull ──► copy catalog.db on the Mac ──► scp ──► stop app ──► swap it in
```

```sh
./sync.sh install     # server: sync account + library + seaf-cli daemon unit
./sync.sh mac-setup   # Mac: lands seafile-ignore.txt first, then pairing steps
./sync.sh status      # both catalogs and both blob stores, side by side
./sync.sh push|pull   # full-catalog replace in the named direction
```

- `install` creates a **non-admin** Seafile account
  (`gnosia-learn-sync@<host>.local`) and a private `gnosia-learn-blobs` library,
  then runs `seaf-daemon` in the foreground under
  `gnosia-learn-seafile.service` (systemd user unit, `Restart=always` — a
  dead daemon is revived, and `active (running)` actually means syncing).
  Credentials persist into `.env` (mode 600) —
  `SEAFILE_SYNC_USER`/`_PASSWORD`/`_REPO`. Admin credentials are only
  read from the sibling `services/seafile/.env` at install time, never stored,
  and no password ever lands on a process list (`curl -K -` reads the
  request from stdin; `seaf-cli` takes it via its getpass stdin
  fallback).
- `mac-setup` writes `~/.gnosia/blobs/local/seafile-ignore.txt` on the
  Mac **before** any pairing. Only `blobs/local` is the library worktree —
  `.owner` and `.tmp` sit at `blobs/` root, outside the synced tree, so a
  foreign `.owner` can never be delivered onto either machine (the ignore
  file inside `local/` is a second line of defence). There is no
  `seaf-cli` for macOS, so pairing is the four
  GUI steps it prints (if a nix `seaf-cli` is ever present it pairs
  headless plus a LaunchAgent instead).
- `push`/`pull` rewrite the receiver's `blobs/.owner` for its own
  `catalog.db` path after every swap, and warn that the receiver's
  `vault/` is stale — rebuild it with `learn vault pull` on that
  machine. `pull` stops `gnosia-learn.service` for the swap (and
  restarts it only if it was running); `push` warns if a Next dev server
  is holding the file open on the Mac.
- Both directions take the same `.deploy.lock` the poller uses: a sync
  blocks a deploy and vice versa — a deploy must never migrate a
  database mid-swap.
- `status` tables each catalog table (count + newest timestamp) on both
  ends, plus `.owner`, blob counts, and whether each side's sync client
  is live — the quick way to see how far the two primaries have drifted.

## Ops

```sh
~/services/gnosia-learn/bin/deploy.sh --force          # pull + rebuild + migrate + restart now
~/services/gnosia-learn/bin/deploy.sh --sha <commit>   # pin to a commit (rollback — TROUBLESHOOT.md)
journalctl --user -u gnosia-learn -f                   # app logs
journalctl --user -u gnosia-learn-studio -f            # studio runner logs
curl -s http://127.0.0.1:7250/api/health             # runner health (loopback)
journalctl --user -u gnosia-learn-deploy -n 50         # deploy history
journalctl --user -u gnosia-learn-export               # nightly export runs
systemctl --user list-timers gnosia-learn-*
ls -l ~/.gnosia/catalog.db                       # the whole catalog, one file
ls ~/.gnosia/archive/latest                      # newest readable export
tailscale serve status
./sync.sh status                                     # both catalogs + blob stores
systemctl --user status gnosia-learn-seafile           # blob-sync daemon
```

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes every Serve
port that proxies to the app, disables the deploy and export timers and
stops the studio runner and the app, and keeps `~/services/gnosia-learn`
and `.env`, so `./setup.sh` brings it back running. `./teardown.sh
--purge` (type the name) also deletes the deploy clone, state, studio
and bin dirs, the unit files and `.env`. Neither touches `~/.gnosia`
— `catalog.db`, `blobs`, `vault` and the nightly exports in `archive/`
all survive a purge — or `sync.sh`'s `gnosia-learn-seafile.service`;
purge refuses while that blob link is installed. See TROUBLESHOOT.md,
"Nuke and pave".

The catalog CLI works in the checkout (`cd ~/services/gnosia-learn/repo &&
npm run catalog -- status`) — `services/catalog/.env` there points it at
this `catalog.db`.

## The studio runner

`STUDIO_ENABLED=1` (the server's `.env` has it on) runs a third service:
`gnosia-learn-studio` (`npm run studio` — `tsx services/studio/src/index.ts`),
the diagram job runner behind the app's `/studio/api/*` proxy. It binds
`127.0.0.1:7250`, is never published through Serve (the app proxies to it
and stamps the signed-in owner itself), and reaches the catalog the way
the app's own CLI does — it spawns `npm run catalog --`, which reads the
deploy-written `services/catalog/.env`. Each job spawns the `claude` CLI
resolved at setup time (`STUDIO_CLAUDE_BIN` in the unit), authenticating
with the login credentials in `~/.claude` — the runner's default
`STUDIO_AGENT_AUTH=login` strips `ANTHROPIC_API_KEY` from the job env.
Job workspaces and the write-ahead log live in
`~/services/gnosia-learn/studio` (`STUDIO_HOME`), outside the
machine-managed checkout. Its lifecycle follows the app: setup and the
deploy poller stop/start them together, and a deliberately stopped stack
stays stopped. Optional spend cap: set `STUDIO_DAILY_USD` in `.env` and
re-run `setup.sh` — the unit template propagates it into the runner's
environment (empty means no cap).

The runner's hard dependency inside the checkout is `tools/tldrawkc` —
it refuses to queue a job while that submodule is unbuilt (health says
`tldrawkc: false` with the fix command). `deploy.sh` handles it: under
`STUDIO_ENABLED=1` every deploy runs `git submodule update --init
tools/tldrawkc` and rebuilds (`npm ci && npm run build`) only when the
recorded gitlink moved — the last-built sha is stamped at
`~/services/gnosia-learn/state/tldrawkc-sha`.

## Not deployed (upstream leftovers)

- **The video tools** (`tools/manimkc`, `tools/remotionkc`,
  `tools/revideokc`): rendering stays on the Mac (upstream S5). The
  rendered videos themselves arrive via the blob-store rsync.
- **Funnel**: Serve is tailnet-only, matching upstream S6. The rate-limit
  question is upstream's "Open" section.

## Client side

Nothing to install. Open `https://homeserver.tail-name.ts.net:8107`,
sign in at `/sign-in` with `OWNER_PASSWORD` from `.env`. Editing the
curriculum happens wherever the gnosia repo is a working clone —
push to `main`, the box deploys it on the next poll.
