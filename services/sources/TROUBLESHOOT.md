# sources — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

The build runs in a machine-managed deploy clone at
`~/services/sources/repo`; the fetch clone at `~/dev/sources` only seeded
the remote URL at setup time. Nothing the fetch timers do to their own
tree — a dirty checkout, a held `sources-fetch.lock`, a missing clone —
can block a deploy. A broken deploy never affects fetching, and vice
versa.

## Quick status

```sh
~/services/deployd/bin/deployd --status                # what deployd last saw/deployed
systemctl --user list-timers deployd.timer             # deployd scheduled?
journalctl --user -u deployd -n 30                     # last poll + deploy runs
cat ~/services/sources/state/built-sha                 # what was last built
git -C ~/services/sources/repo rev-parse origin/main   # what the next deploy builds
docker inspect -f '{{.State.Status}}' sources          # nginx up?
curl -sI http://127.0.0.1:8098/ | head -1              # serving locally?
tailscale serve status                                 # :8098 published?
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` reports
a healthy container as not running. Re-run under `sg docker -c '...'`.

The Serve mapping stays in place while the container is stopped, so `:8098`
appearing in `tailscale serve status` proves nothing about the site.

## Layer 1 — deploys not happening

**A fetch or push landed but the site didn't update.**
- deployd polls every minute — deploy now with
  `~/services/sources/bin/deploy.sh --force`, or check the last run:
  `journalctl --user -u deployd -n 30` /
  `~/services/deployd/bin/deployd --status`. A `.fail` entry in
  `~/services/deployd/state/` means the last deploy attempt failed and
  deployd is backing off before retrying.
- `up to date at <sha>` with an old sha → `built-sha` equals
  `git -C ~/services/sources/repo rev-parse origin/main`, meaning the
  remote itself is behind: the fetch commit didn't land (check
  `journalctl -u sources-fetch`), the push went to another branch, or the
  fetch committed without pushing (deployd watches the *remote* — a commit
  that never reaches origin triggers nothing). `.env` `BRANCH` is what the
  deploy clone fetches; it must match the ref in
  `services/sources/app.json`'s deploy block.
- `fatal: could not read Username` / `git clone` or `git fetch` failures →
  the deploy clone can't reach `REPO_URL`: auth broke (`gh auth login &&
  gh auth setup-git`, or the SSH key is gone), the box is offline, or
  `.env` `REPO_URL` points somewhere unreadable — fix the line or delete
  it and re-run `setup.sh` (it re-seeds from the fetch clone's origin).
- `deployd asked for <sha> but origin/BRANCH is at <other>` → the fetch
  brought down a different tip than deployd resolved; transient when
  `main` is moving — it retries — but a remote stuck mid-push deserves a
  look (`git ls-remote $REPO_URL`).
- No log entries at all → deployd not running:
  `systemctl --user enable --now deployd.timer`; if the box just
  rebooted and nothing user-level runs, re-check lingering:
  `loginctl show-user $USER -p Linger` → fix with
  `sudo loginctl enable-linger $USER`.
- `another deploy is running — skipping` on every run → stale lock from a
  killed build; it self-clears after 60 min, or immediately:
  `rmdir ~/services/sources/.deploy.lock`.

**Build fails (site keeps serving the old version — that's by design).**
Run it by hand to see the full error:
```sh
~/services/sources/bin/deploy.sh --force
```
- `Set SITE_PASSPHRASE` → `.env` lost its passphrase line (it is read
  once at setup; restore it with the GitHub `site` workflow's
  `SITE_PASSPHRASE` secret value).
- `Passphrase must be at least` → the passphrase in `.env` is wrong/short;
  same fix.
- `uv` errors → `uv` must be on `.env`'s `UV_BIN` path; if uv moved,
  update `UV_BIN` or re-run setup.sh.
- `<out> is not empty and is not an earlier build` → `www/next` left over
  from a killed run; `rm -rf ~/services/sources/www/next` and retry.
- Anything about `catalog.db`, `raw/` or a yaml file → the repo's content
  itself is in a bad state; fix it upstream and push (or inspect the
  deploy clone: `git -C ~/services/sources/repo status`).

**Jobs missing from the sidebar.**
The build ships Jobs only when `data/jobs/jobs.db` exists in the deploy
clone, and `deploy.sh` links it in from the fetch clone each run.
- `ls -l ~/services/sources/repo/data/jobs/jobs.db` → should be a symlink
  into `SOURCE_REPO` (default `~/dev/sources`). Missing or dangling means
  the fetch clone has no `data/jobs/jobs.db`: check
  `ls -l ~/dev/sources/data/jobs/jobs.db` and, if it is absent, let the
  daily scrape run (or re-run it) first.
- The fetch clone has the file but the link does not → rebuild:
  `~/services/sources/bin/deploy.sh --force`. Its log line says which way
  it went ("jobs.db linked from the fetch clone" vs "no jobs.db in the
  fetch clone").

## Layer 2 — local serving broken

**`curl http://127.0.0.1:8098/` fails.**
- `docker ps | grep sources` — container gone entirely?
  `docker compose --project-directory ~/dev/setup-server/services/sources up -d`
- Container restarting → `docker logs sources`; an nginx config error means
  `~/services/sources/nginx.conf` was edited badly (delete it and re-run
  setup.sh to regenerate the default).
- 403/404 on `/` → `~/services/sources/www/current/index.html` missing:
  the initial build never completed; run `bin/deploy.sh --force`.
- `/` works but `d/catalog.bin` or `d/key.json` 404 → the build output was
  swapped halfway; redeploy with `bin/deploy.sh --force`.

**Everything decrypts to garbage / "wrong passphrase" in the browser.**
The build used a different `SITE_PASSPHRASE` than the one being typed.
Rebuild with the right value: fix `.env`, then `bin/deploy.sh --force`.

## Layer 3 — publish broken

**Local works, `https://…:8098` doesn't.**
- `tailscale serve status` should map `:8098` → `127.0.0.1:8098`. Re-add:
  `tailscale serve --bg --https=8098 http://127.0.0.1:8098`
- `Access denied` → operator not set: `sudo tailscale set --operator=$USER`.
- First-ever HTTPS hit can take ~60s (cert minting).
- ⚠️ **Never `tailscale serve reset`** to clear a bad mapping. It wipes the
  serve config for the whole node — every published service dark at once,
  each one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=8098 off`; `off` is absent from
  `tailscale serve --help` on 1.102.3 (which only advertises `reset` and
  `clear`) but is what Tailscale prints after a successful serve, and is
  verified working here.
- **Kuma red but the container is up** — the monitor probes the tailnet URL
  (`https://…:8098/`), not loopback, so it goes red for a publishing failure
  too. Curl `http://127.0.0.1:8098/` first; if that answers, the fault is
  Serve or the cert. Everything red at once is tailscaled.

## Layer 4 — client broken

- Other tailnet services (e.g. `:3002`) reachable? If not, it's the client's
  Tailscale, not this service.
- Blank page with a passphrase prompt that won't accept → wrong passphrase
  (see Layer 2), or a browser without Web Crypto over plain HTTP — the URL
  must be the `https://` tailnet one (or `localhost` when using
  `run_web.sh`, never a bare LAN IP).

## Rollback

`www/current` is a symlink into `www/releases/`; the previous release is
kept beside it. Directory names are the built sha, with a `.rebuild-<ts>`
suffix when a `--force` rebuilt a sha that was already live. Repoint
`current` at the older release:

```sh
cd ~/services/sources/www
ls releases/                       # pick the directory to go back to
ln -sfn releases/<name> current.new && mv -Tf current.new current
```

(Any later successful deploy moves `current` again — pin by stopping
deployd first: `systemctl --user stop deployd.timer`.)

## Nuke and pave

`./teardown.sh` is the authority; do not hand-run the old recipe. First
save the passphrase if you have no other copy: `.env` holds
`SITE_PASSPHRASE`, and `--purge` deletes `.env`.

```sh
cd ~/dev/setup-server/services/sources
grep '^SITE_PASSPHRASE=' .env          # backup step: copy it somewhere safe
./teardown.sh --purge                  # type "sources" to confirm
SITE_PASSPHRASE='...' ./setup.sh
```

`./teardown.sh` alone (what the launcher's Remove runs) unpublishes every
Serve port that proxies only to `127.0.0.1:8098`, removes the legacy
`sources-deploy` timer/service if one still exists, and runs
`docker compose down` (a local `docker-compose.override.yml` is picked up
the same way `setup.sh`'s `up` picks it up). Files, `.env` and unit files
stay, so `./setup.sh` brings it back. `--purge` also deletes what
`setup.sh` wrote under `~/services/sources` (`bin`, `repo`, `state`,
`www`, `nginx.conf`), `.env` and the two unit files, then removes the
marker dir only if nothing else is left in it.

It never touches the fetch clone (`SOURCE_REPO`, default `~/dev/sources`:
the corpus's source of truth, with GitHub), lingering, or units it did
not create: `sources-trigger.service` and its backups are named in a
warning and left alone. The deploy clone at `~/services/sources/repo` is
machine-managed, so `--purge` does delete it — `setup.sh` re-clones it.
