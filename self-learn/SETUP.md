# self-learn — Gnosia study hub, auto-deployed from GitHub

A production build of the private
[c-wenlong/self-learn](https://github.com/c-wenlong/self-learn) repo: a
Next.js 16 app over a Postgres 17 catalog, served natively and published
tailnet-only. Push to `main` and the box picks it up on its daily poll —
or immediately with `~/services/self-learn/bin/deploy.sh --force`.

The repo's own `docs/HOMESERVER.md` describes this exact deployment shape;
this service wraps it in the repo's usual one-shot, idempotent form. Where
they differ: systemd **user** units instead of system units (the repo's
sudo rule), generated Postgres credentials instead of `catalog:catalog`,
and the deploy/update order from upstream step 14 baked into a poller.

## Architecture

```
git push (laptop)
        │
        ▼
   GitHub (private repo)
        ▲  outbound git fetch, daily (POLL_SECONDS)
        │
self-learn-deploy.timer ──► bin/deploy.sh          self-learn-export.timer
  (systemd user timer;          │                     (nightly 03:00:
   launchd on macOS)            │ 1. stop app if running  catalog export ->
                                │ 2. git reset --hard     ~/.self-learn/archive)
                                │    origin/main
                                │ 3. write checkout env files
                                │    (apps/web/.env.local,
                                │     services/catalog/.env)
                                │ 4. npm ci      (only when package-lock changes)
                                │ 5. catalog migrate
                                │ 6. next build
                                │ 7. start app if it was running
                                ▼
              ~/services/self-learn/repo  (machine-managed clone)
                                │  next start -p 8107 -H 127.0.0.1
                                ▼
              self-learn.service (systemd user unit / launchd)
                     127.0.0.1:8107 ──► Tailscale Serve HTTPS :8107
        https://kai-home-server.taild6a23f.ts.net:8107   (tailnet only)

   self-learn-db (postgres:17 container) 127.0.0.1:5432
        ▲ app + `npm run catalog` on the host both connect here
   ~/.self-learn/  blobs/ vault/ archive/  (upstream layout — rsync target)
```

## Security model

- The app binds `127.0.0.1` only; HTTPS + device auth come from Tailscale
  Serve. Upstream's S6 notes Serve forwards `Host` and
  `X-Forwarded-Proto: https`, which is exactly what the app's session
  cookie and same-origin check read — no app-side setting needed.
- Postgres is published on `127.0.0.1:5432` — wider than other services'
  databases because the catalog CLI runs on the **host**, not in a
  container. Loopback is the narrowest bind that allows it; Docker
  publishes past ufw, so `0.0.0.0` would have opened the database to the
  LAN. Credentials are generated into `.env`, not upstream's literal
  `catalog:catalog`.
- Sign-in is the app's own `OWNER_PASSWORD` + signed cookie (one owner,
  upstream's "one reader" model). Tailnet is still the perimeter; the
  password gates a roommate on the tailnet, not the internet.
- `OWNER_PASSWORD` / `AUTH_SECRET` / `POSTGRES_PASSWORD` are generated
  into `.env` (mode 600) on first run and never overwritten. Every file
  that carries them — the checkout env files below and the export
  unit/plist with `DATABASE_URL` in it — is written mode 600.
- The deploy clone (`~/services/self-learn/repo`) is machine-managed and
  hard-reset on every deploy — **never edit it by hand**. The two env
  files inside it (`apps/web/.env.local`, `services/catalog/.env`) are
  rewritten from `.env` on every deploy; rotate secrets in `.env`, then
  `deploy.sh --force`.
- A deliberately stopped app stays stopped across deploys *and* setup
  re-runs: the poller rebuilds and migrates but only restarts the app if
  it was running, and Postgres is returned to whatever state it was
  found in. If a deploy step fails partway, the previous
  `node_modules`/`.next` are restored from the rename-aside snapshot and
  the old build restarted — never a half-written tree.

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git + non-interactive repo access | poller fetches the private repo unattended | `git ls-remote` with prompts disabled |
| Node.js >= 22.22.2 (+ npm) | upstream `engines`; build, catalog CLI, `next start` | version compare |
| Docker + Compose v2 | Postgres container | daemon reachable |
| Tailscale (running) | HTTPS publish | backend state |

Not needed: Postgres client tools (migrations and the seed go through the
catalog CLI; a dump restore can run `pg_restore` inside the container),
submodules (`tools/*` stays uninitialised — the seed import is pointed at
`/nonexistent` roots and the studio is not deployed).

## What setup.sh does

1. Preflight (above).
2. Writes `.env` if absent (ports, paths, generated `OWNER_PASSWORD`,
   `AUTH_SECRET`, `POSTGRES_PASSWORD`, assembled `DATABASE_URL`). Re-runs
   read `.env` as the source of truth — `LOCAL_PORT=...` on the command
   line is ignored once `.env` exists.
3. Installs `deploy.sh` -> `~/services/self-learn/bin/` (refreshed every
   run) and creates `~/.self-learn/blobs`.
4. Writes the units — `self-learn.service` (the app), the deploy
   `.timer`, the nightly export `.timer` — or the three LaunchAgents.
5. Runs the initial deploy: clone, env files, `npm ci`, Postgres up,
   `catalog migrate`, `next build`.
6. Bootstraps the catalog **once** (marker `state/db-bootstrapped`):
   `catalog import seed`, six `catalog flip`s in upstream order, and
   `catalog blob audit --fix` to claim the blob root for this database.
   `SKIP_SEED=1` skips this for a dump restore instead (below).
7. Enables + starts the app and both timers, enables lingering (Linux),
   and publishes `tailscale serve --bg --https=8107`. An app that was
   deliberately stopped before the re-run is left stopped (and Postgres
   put back the way it was found).

## Deploy

```sh
cd self-learn && ./setup.sh
```

Overrides (first run only — after that, edit `.env`): `LOCAL_PORT` /
`HTTPS_PORT` (default 8107), `PG_PORT` (5432), `REPO_URL`, `BRANCH`
(main), `POLL_SECONDS` (86400 = daily), `SKIP_SEED` (1 = leave the
catalog empty for a dump restore), `OWNER_PASSWORD`, `AUTH_SECRET`.

For a real deployment, pass the **laptop's `AUTH_SECRET`** on first run
(`AUTH_SECRET=... ./setup.sh`): provider keys saved in Settings are
sealed under a key derived from it, so matching secrets keep them
readable on both machines (upstream S4). `OWNER_PASSWORD` is checked,
not used to encrypt anything — it can differ freely.

## Bringing the laptop's data over

The homeserver's database is its own `primary`, meant to diverge from
the laptop's (upstream S1) — the seed is only the demo slice. To move
the real history instead:

```sh
# on the laptop
pg_dump -Fc self_learn > ~/self_learn.dump
scp ~/self_learn.dump kai-home-server:~/
rsync -a --exclude .owner ~/.self-learn/blobs/ kai-home-server:~/.self-learn/blobs/

# first deploy here — leave the catalog empty
cd self-learn && SKIP_SEED=1 AUTH_SECRET=<laptop's> ./setup.sh

# restore into the running container: drop the migrated-but-empty
# database first — the deploy already ran `catalog migrate`, and a bare
# pg_restore into that schema errors on existing objects
docker exec -it self-learn-db psql -U catalog -d postgres \
  -c 'DROP DATABASE self_learn WITH (FORCE); CREATE DATABASE self_learn;'
docker exec -i self-learn-db pg_restore --no-owner -U catalog -d self_learn < ~/self_learn.dump
cd ~/services/self-learn/repo && npm run catalog -- doctor && npm run catalog -- blob audit --fix
```

(The psql step prompts for `POSTGRES_PASSWORD` from `.env`. The same
drop-and-recreate covers a database that *was* seeded.) The
`--exclude .owner` matters: the blob store's marker names the laptop's
database, and a copied marker makes uploads and `audit --fix` refuse the
root (upstream S3).

## Syncing with the MacBook (`sync.sh`)

The one-shot rsync above becomes continuous with `sync.sh`. Blobs ride a
dedicated Seafile library in both directions; the database rides
`push`/`pull` only when asked — the two catalogs are meant to diverge,
so a transfer is always a full replace (`pg_dump` → drop+create →
`pg_restore`), never a merge.

```
server                          Seafile                          MacBook
~/.self-learn/blobs  ◄── self-learn-blobs library (private) ──►  ~/.self-learn/blobs
  seaf-cli daemon      dedicated non-admin sync account          Seafile Client.app
  (self-learn-         (.owner + .tmp stay machine-local          (GUI pairing —
   seafile.service)     via seafile-ignore.txt)                    no seaf-cli on macOS)

./sync.sh push ──► pg_dump here ──► scp ──► drop+create ──► pg_restore on the Mac
./sync.sh pull ──► pg_dump on the Mac ──► scp ──► stop app ──► drop+create ──► restore
```

```sh
./sync.sh install     # server: sync account + library + seaf-cli daemon unit
./sync.sh mac-setup   # Mac: lands seafile-ignore.txt first, then pairing steps
./sync.sh status      # both catalogs and both blob stores, side by side
./sync.sh push|pull   # full-catalog replace in the named direction
```

- `install` creates a **non-admin** Seafile account
  (`self-learn-sync@<host>`) and a private `self-learn-blobs` library,
  then runs `seaf-daemon` in the foreground under
  `self-learn-seafile.service` (systemd user unit, `Restart=always` — a
  dead daemon is revived, and `active (running)` actually means syncing).
  Credentials persist into `.env` (mode 600) —
  `SEAFILE_SYNC_USER`/`_PASSWORD`/`_REPO`. Admin credentials are only
  read from the sibling `seafile/.env` at install time, never stored,
  and no password ever lands on a process list (`curl -K -` reads the
  request from stdin; `seaf-cli` takes it via its getpass stdin
  fallback).
- `mac-setup` writes `~/.self-learn/blobs/seafile-ignore.txt` on the Mac
  **before** any pairing: `.owner` names one machine's database, and a
  synced marker would make uploads and `blob audit` refuse the other
  side's root. There is no `seaf-cli` for macOS, so pairing is the four
  GUI steps it prints (if a nix `seaf-cli` is ever present it pairs
  headless plus a LaunchAgent instead).
- `push`/`pull` rewrite the receiver's `blobs/.owner` for the new
  `pg_database` oid after every restore, and warn that the receiver's
  `vault/` is stale — rebuild it with `learn vault pull` on that
  machine. `pull` stops `self-learn.service` for the restore (and
  restarts it only if it was running); `push` warns if a Next dev server
  is holding connections on the Mac.
- Both directions take the same `.deploy.lock` the poller uses: a sync
  blocks a deploy and vice versa — a deploy must never migrate a
  database mid-restore.
- `status` tables each catalog table (count + newest timestamp) on both
  ends, plus `.owner`, blob counts, and whether each side's sync client
  is live — the quick way to see how far the two primaries have drifted.

## Ops

```sh
~/services/self-learn/bin/deploy.sh --force          # pull + rebuild + migrate + restart now
~/services/self-learn/bin/deploy.sh --sha <commit>   # pin to a commit (rollback — TROUBLESHOOT.md)
journalctl --user -u self-learn -f                   # app logs
journalctl --user -u self-learn-deploy -n 50         # deploy history
journalctl --user -u self-learn-export               # nightly export runs
systemctl --user list-timers self-learn-*
docker compose --project-directory ~/dev/setup-server/self-learn ps|logs
docker compose --project-directory ~/dev/setup-server/self-learn exec db \
  psql -U catalog self_learn                         # SQL in (password in .env)
ls ~/.self-learn/archive/latest                      # newest readable export
tailscale serve status
./sync.sh status                                     # both catalogs + blob stores
systemctl --user status self-learn-seafile           # blob-sync daemon
```

The catalog CLI works in the checkout (`cd ~/services/self-learn/repo &&
npm run catalog -- status`) — `services/catalog/.env` there points it at
this database.

## Not deployed (upstream leftovers)

- **The studio runner** (`npm run studio`, diagram/video jobs): needs
  `claude` logged in, the `tldrawkc` submodule built, and headless
  Chromium — upstream step 12. Diagram jobs on this box would also land in
  the homeserver's catalog, a second history to sync. Left out;
  `STUDIO_ENABLED` is deliberately absent from the generated
  `.env.local`.
- **The video tools** (`tools/manimkc`, `tools/remotionkc`,
  `tools/revideokc`): rendering stays on the Mac (upstream S5). The
  rendered videos themselves arrive via the blob-store rsync.
- **Funnel**: Serve is tailnet-only, matching upstream S6. The rate-limit
  question is upstream's "Open" section.

## Client side

Nothing to install. Open `https://kai-home-server.taild6a23f.ts.net:8107`,
sign in at `/sign-in` with `OWNER_PASSWORD` from `.env`. Editing the
curriculum happens wherever the self-learn repo is a working clone —
push to `main`, the box deploys it on the next poll.
