# self-learn — troubleshooting

Layered triage: deploy pipeline → database → app → publish → client. Work
top-down; each layer assumes the one above it is healthy.

**A deliberately stopped app stays stopped.** The poller rebuilds and
migrates but only restarts the app if it was running, and Postgres is
put back in the state it was found (this is how the launcher's stop
button survives the daily poll and setup re-runs). So a red tile with
fresh deploy logs means stopped-on-purpose, not broken — `systemctl
--user start self-learn` or the launcher's start button.

## Quick status

```sh
systemctl --user is-active self-learn                  # app up?
systemctl --user list-timers self-learn-*              # poller + export scheduled?
journalctl --user -u self-learn-deploy -n 30           # last deploy runs
cat ~/services/self-learn/state/built-sha              # what was last built
docker inspect -f '{{.State.Status}}' self-learn-db    # Postgres up?
curl -sI http://127.0.0.1:8107/ | head -1              # app answering locally?
tailscale serve status                               # :8107 published?
ls ~/.self-learn/archive/latest                      # nightly export landing?
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — re-run under
`sg docker -c '...'`.

## Layer 1 — deploys not happening

**I pushed but the app didn't update.**

- The poller only runs daily by default — deploy now:
  `~/services/self-learn/bin/deploy.sh`, or check the last run:
  `journalctl --user -u self-learn-deploy -n 30`.
- `up to date at <sha>` with an old sha → the fetch isn't seeing your
  push: wrong branch? `.env` `BRANCH` must match what you push to.
- No log entries at all → timer not running:
  `systemctl --user enable --now self-learn-deploy.timer`; if the box
  just rebooted and nothing user-level runs, check lingering:
  `loginctl show-user $USER -p Linger` → `sudo loginctl enable-linger $USER`.
- `could not read Username` / auth errors → git credentials broke:
  `gh auth login && gh auth setup-git`, then run `deploy.sh` by hand.
- `another deploy is running — skipping` on every run → stale lock from a
  killed build; self-clears when the owner pid is dead or after 60 min,
  or: `rm -rf ~/services/self-learn/.deploy.lock`.

**Deploy fails.** Run it by hand for the full error:
`~/services/self-learn/bin/deploy.sh --force`

- `npm ci` / network errors → transient; the next timer tick retries.
- `catalog migrate` fails → Postgres down or `DATABASE_URL` wrong:
  `docker ps | grep self-learn-db`, and compare `DATABASE_URL` in
  `services/self-learn/.env` against `services/catalog/.env` inside the checkout —
  deploy.sh rewrites the checkout copy from `.env` on every run, so an
  edited-here value is the fix, not a symptom.
- `next build` fails after a pull → usually a real upstream regression;
  the deploy restores the previous `node_modules`/`.next` from its
  rename-aside snapshot and restarts the old build, so the site stays up
  on the last good commit. Fix upstream or roll back (below), then
  `--force`.
- Node errors after a system update → `node --version` must be >= 22.22.2
  and live where `.env`'s `NODE_BIN` points; if node moved (e.g. nix
  generation change), update `NODE_BIN` in `.env` and re-run `setup.sh`.

## Layer 2 — database broken

**`docker ps` shows self-learn-db down or restarting.**

- `docker logs self-learn-db` — a bad `POSTGRES_PASSWORD` change in
  `.env` is the classic: the password only applies at *first* container
  init; editing it later makes the app and CLI fail auth while the
  container itself is healthy. Revert `.env` to the generated value, or
  change it inside Postgres too.
- Port clash on :5432 → `ss -ltn | grep 5432` — a host Postgres or
  another container claimed it. Move ours: `PG_PORT=` in `.env`, update
  `DATABASE_URL` to match, re-run `setup.sh`.
- Dump restore failed partway → drop and recreate, then restore again:
  `docker exec -it self-learn-db psql -U catalog -d postgres -c 'DROP DATABASE self_learn WITH (FORCE); CREATE DATABASE self_learn;'`
  (password in `.env`), re-run `pg_restore`, then
  `npm run catalog -- migrate` in the checkout.
- `blob audit` refuses the root ("owner names another database") → a
  `.owner` marker was rsynced over from the laptop. Delete
  `~/.self-learn/blobs/.owner`, then
  `npm run catalog -- blob audit --fix` in the checkout.

## Layer 3 — app broken

**`curl http://127.0.0.1:8107/` fails or the unit won't stay up.**

- `journalctl --user -u self-learn -n 100` — port taken? `-p` arg wrong?
  `next` binary missing (an interrupted `npm ci` — re-run
  `deploy.sh --force`)?
- Landing page loads but every content page says "could not read its
  content" → the app reaches Postgres but a type isn't flipped (fresh
  seed path runs six flips; a restored dump carries its own). Check:
  `cd ~/services/self-learn/repo && npm run catalog -- status`, and flip
  what it names.
- Pages load but say the database is unreachable / writes 503 →
  `DATABASE_URL` mismatch: `apps/web/.env.local` in the checkout is
  rewritten from `services/self-learn/.env` each deploy; fix `.env`, then
  `deploy.sh --force`.
- Sign-in refuses the correct password → you edited
  `apps/web/.env.local` in the checkout and a deploy reverted it; the
  source of truth is `services/self-learn/.env`. An `.env.local` at the repo ROOT
  is never read — the app reads it from `apps/web/` only.
- "was not running — left stopped" in deploy logs → expected after a
  manual stop; `systemctl --user start self-learn`.

## Layer 4 — publish broken

**Local works, `https://…:8107` doesn't.**

- `tailscale serve status` should map `:8107` → `127.0.0.1:8107`. Re-add:
  `tailscale serve --bg --https=8107 http://127.0.0.1:8107`
- `Access denied` → operator not set: `sudo tailscale set --operator=$USER`.
- First-ever HTTPS hit can take ~60s (cert minting).
- ⚠️ **Never `tailscale serve reset`** — it wipes the serve config for
  the whole node. Single-port removal: `tailscale serve --https=8107 off`.
- Sign-in succeeds but the session cookie won't stick over plain
  `http://` → by design: the cookie is `Secure` only over https
  (upstream S6). Use the `https://` URL.
- **Kuma red but the app is up** — the monitor probes the tailnet URL,
  so a publishing failure scores down too. Curl loopback first.
  Everything red at once is tailscaled.

## Layer 5 — client broken

- Other tailnet services reachable? If not, it's the client's Tailscale.
- Signed out everywhere at once → `AUTH_SECRET` rotated (`.env` edited,
  or a first-run without the laptop's value). Sign in again; provider
  keys saved in Settings must be re-entered.

## Studio runner broken (`self-learn-studio`)

**The Studio page loads but jobs never start / the panel says the runner is down.**

- `curl -s http://127.0.0.1:7250/api/health` — the runner's own surface
  (loopback only; the app proxies `/studio/api/*` to it). If it fails:
  `journalctl --user -u self-learn-studio -n 100`. Unit missing entirely →
  re-run `setup.sh`.
- Health answers but `"tldrawkc": false` / queue refuses every job → the
  submodule isn't built. Under `STUDIO_ENABLED=1` the next
  `deploy.sh --force` rebuilds it; by hand:
  `cd ~/services/self-learn/repo && git submodule update --init tools/tldrawkc
  && (cd tools/tldrawkc && npm ci && npm run build)`, then restart
  `self-learn-studio` so its cached probe re-runs.
- Studio missing from the UI at all → `STUDIO_ENABLED` isn't 1 in
  `services/self-learn/.env`. Set it and re-run `setup.sh` — that flag gates both
  the web UI and the runner's enable. Flipping it back to 0 and
  re-running stops and disables the unit.
- Jobs start and immediately fail with a claude/auth error → the runner
  spawns `STUDIO_CLAUDE_BIN` (baked into the unit at setup time). Check
  `claude` still exists at that path and `~/.claude` credentials are
  still valid — `claude -p 'say hi'` as the deploy user proves both.
- Jobs fail with "catalog" errors → the runner reaches Postgres by
  spawning `npm run catalog` in the checkout, which reads
  `services/catalog/.env` — same diagnosis as Layer 2.
- A deploy appeared to kill a job mid-run → expected: the poller stops
  and restarts the runner with the app (it shares the checkout's
  `node_modules`). Job state under `~/services/self-learn/studio` is the
  write-ahead log — interrupted jobs resume or can be re-enqueued.

## Layer 6 — sync broken (`sync.sh`)

`./sync.sh status` is the triage entry point: it tables both catalogs and
reports whether each side's sync client is alive.

**`seaf : not installed` / daemon not answering.**

- `systemctl --user status self-learn-seafile` — the unit runs
  `seaf-daemon` in the foreground, so `active (running)` is healthy and a
  crashed daemon restarts itself (`Restart=always`). `journalctl --user -u
  self-learn-seafile` has the daemon's own errors. Re-run
  `./sync.sh install` to repair — it is idempotent (existing
  account/library are reused).
- `seaf-cli list -c ~/services/self-learn/seafile/ccnet` — the
  `self-learn-blobs` row should say `synchronized`. If the library is
  missing, the daemon dropped it: `./sync.sh install` re-links.
- Nothing syncs after a reboot → lingering off? `loginctl show-user
  $USER -p Linger`. Also check `seaf-daemon`/`ccnet` actually run:
  `pgrep -fl 'seaf-daemon|ccnet'`.

**On the Mac.** No seaf-cli on macOS — the Seafile Client app owns the
sync. Check the client's library list: `self-learn-blobs` should show a
green state. A red/error state → right-click → resync, or delete the
local sync entry and repeat the `mac-setup` pairing steps — into
`~/.self-learn/blobs/local`, not `~/.self-learn/blobs` (the whole `blobs`
dir as library root is the retired layout; `.owner` lived inside it and
syncs clobbered it across machines). Confirm
`~/.self-learn/blobs/local/seafile-ignore.txt` still lists `/.owner` and
`/.tmp`.

**`blob audit` reports rows "outstanding" / findings.**

Expected right after a `push`/`pull` or while Seafile is still
delivering — rows are catalog entries whose objects haven't arrived
yet. Give the daemon a few minutes, re-run `status`. If findings never
drain, the daemon on one end is dead (above). Do **not** run `blob audit
--fix` on either machine: it deletes orphans older than a day, and on a
shared store a delete propagates to the other side.

**`blob audit` refuses the root ("owner names another database").**

A foreign `.owner` landed — only possible via manual file copy or a
`push`/`pull` restore that didn't rewrite the marker (`.owner` sits
outside the synced `blobs/local` tree, so Seafile can't deliver one). Fix: delete `blobs/.owner` on the affected machine
and re-run `./sync.sh push` or `pull` (it rewrites the marker for the
current `pg_database` oid), or `npm run catalog -- blob audit --fix` in
the local checkout if nothing is mid-transfer.

**`push`/`pull` fails.**

- `cannot ssh kaichen@…` → Tailscale down on either end, or the ssh key
  isn't installed for BatchMode. `ssh kaichen@<mac> true` must succeed
  non-interactively.
- `a deploy or sync is running` → the shared `.deploy.lock` is held.
  Same rules as deploy: it self-clears when the owner pid dies or after
  60 min, or `rm -rf ~/services/self-learn/.deploy.lock`.
- `pg_restore failed` on either side → the receiving database may be
  left empty/partial — re-run the same command; a restore is always
  drop+create first, so retrying is safe. pg version skew matters:
  `pg_restore` on the receiver must be >= the dumper's major version.
- `pull` stops `self-learn.service` for the restore; if it dies between
  stop and start the app stays stopped —
  `systemctl --user start self-learn` once the DB is whole.
- A `pgrep` warning about a Next dev server on the Mac means `push`'s
  `DROP … WITH (FORCE)` will sever its connections — expected; restart
  the dev server after.

**Undoing the sync.** Mac: right-click the library in Seafile Client →
unsync (folder stays). Server: `systemctl --user disable --now
self-learn-seafile.service`, remove the `SEAFILE_SYNC_*`/`MAC_*` lines
from `.env`, `rm -rf ~/services/self-learn/seafile`. The blob folders
and catalogs on both ends are untouched — they just stop converging.

## Rollback

`deploy.sh --sha` pins the build to a specific commit. Pause the poll
first — the next tick redeploys the branch tip and undoes the pin:

```sh
systemctl --user stop self-learn-deploy.timer    # don't let the poll re-pull
~/services/self-learn/bin/deploy.sh --sha <previous-sha>
# ...fixed upstream? resume the daily poll (redeploys origin/main):
systemctl --user start self-learn-deploy.timer
```

Or skip the pin and push a revert commit instead — cleanest, the poller
deploys it like anything else. Database migrations are forward-only: a
rolled-back app against a migrated DB is upstream's expected state
(`migrate` is a hash check, not a replay).

## Nuke and pave

Use `teardown.sh`, not a hand recipe. It unpublishes only the Serve ports
that proxy to the app's port, disables the deploy + export timers first (so
the poller cannot restart anything mid-teardown), then stops the studio
runner, the app and Postgres, and refuses to start while a deploy or
`sync.sh` push/pull holds the deploy lock, then holds that lock itself until
it finishes. It never touches
`~/.self-learn` (blobs, vault, nightly exports) or anything `sync.sh`
installed.

Back up first. `--purge` drops the Postgres volume, and the newest export
in `~/.self-learn/archive/` is then the only copy of the catalog:

```sh
systemctl --user start self-learn-export.service       # fresh export into ~/.self-learn/archive
docker compose --project-directory ~/dev/setup-server/services/self-learn exec -T db \
  pg_dump -U catalog -Fc self_learn > ~/self_learn-$(date +%F).dump   # also keeps sealed provider keys
cp ~/dev/setup-server/services/self-learn/.env ~/self-learn.env.bak  # AUTH_SECRET unseals those keys
```

Then, from `~/dev/setup-server/services/self-learn`:

```sh
./teardown.sh            # remove, keep the volume, state + .env (the launcher's Remove)
./teardown.sh --purge    # also drop the volume (down -v), the deploy clone, state/,
                         # studio/, bin/, the unit files and .env; type the name
./setup.sh               # bring it back (after a plain teardown it starts the stack again)
```

A `./setup.sh` re-run after a plain teardown restarts the app. Starting it
in between — launcher, phone or `systemctl --user start` — clears
`~/services/self-learn/state/torn-down` (the unit's `ExecStartPre` and the
LaunchAgent's wrapper do it), so a later stop reads as yours and stays
stopped across the re-run. To keep it stopped without ever starting it,
delete `~/services/self-learn/state/torn-down` before re-running.

`--purge` refuses while `sync.sh`'s blob link is installed
(`self-learn-seafile.service`, or `SEAFILE_SYNC_USER` in `.env`): that
unit is not `setup.sh`'s, and `.env` holds the sync account's password.
Plain `teardown.sh` leaves it running and says so. To remove the link by
hand first:

```sh
systemctl --user disable --now self-learn-seafile
rm -f ~/.config/systemd/user/self-learn-seafile.service && systemctl --user daemon-reload
rm -rf ~/services/self-learn/seafile
# then delete the "blob/db sync (written by sync.sh install)" block from .env;
# the self-learn-sync account and its library stay in Seafile until you delete them there
```

`rm -rf ~/.self-learn` (blobs, vault, exports) is never scripted; do it by
hand only if you really want the blob store gone.

The only irreplaceable state is the Postgres volume (learner history) and
`~/.self-learn/blobs` (videos, diagrams). A `pg_dump` plus the latest
`~/.self-learn/archive/` export is a full backup; `pg_dump` also covers
the sealed provider keys, which `~/.self-learn` alone does not — and a
dump only restores sealed keys under the same `AUTH_SECRET`.
