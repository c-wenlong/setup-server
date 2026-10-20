# sources — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

This service shares the fetch clone at `~/dev/sources` with
`sources-fetch.timer` — the two are independent: the fetch timer writes the
repo, the deploy timer only reads it. A broken deploy never affects
fetching, and vice versa.

## Quick status

```sh
systemctl --user list-timers sources-deploy.timer        # poller scheduled?
journalctl --user -u sources-deploy -n 30                # last deploy runs
cat ~/services/sources/state/built-sha                   # what was last built
git -C ~/dev/sources rev-parse HEAD                      # what the repo is at
docker inspect -f '{{.State.Status}}' sources            # nginx up?
curl -sI http://127.0.0.1:8098/ | head -1                # serving locally?
tailscale serve status                                   # :8098 published?
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` reports
a healthy container as not running. Re-run under `sg docker -c '...'`.

The Serve mapping stays in place while the container is stopped, so `:8098`
appearing in `tailscale serve status` proves nothing about the site.

## Layer 1 — deploys not happening

**A fetch or push landed but the site didn't update.**
- The poller only runs daily by default — deploy now with
  `~/services/sources/bin/deploy.sh`, or check the last run:
  `journalctl --user -u sources-deploy -n 30`.
- `up to date at <sha>` with an old sha → `built-sha` equals
  `git -C ~/dev/sources rev-parse HEAD`, meaning the repo itself is behind:
  the fetch commit didn't land (check `journalctl -u sources-fetch`) or the
  push went to another branch. `.env` `BRANCH` is only documentation here —
  deploy.sh builds HEAD, whatever it is.
- `note: git pull --ff-only did not apply` in the log → the clone is dirty
  or offline. The build still runs on the local HEAD, so this is a warning,
  not a failure — but a permanently dirty clone also breaks
  `sources-fetch.timer`, so clean it:
  `git -C ~/dev/sources status` (restore or commit the changes; the repo
  docs say develop in a worktree, never this clone).
- No log entries at all → timer not running:
  `systemctl --user enable --now sources-deploy.timer`; if the box just
  rebooted and nothing user-level runs, re-check lingering:
  `loginctl show-user $USER -p Linger` → fix with
  `sudo loginctl enable-linger $USER`.
- `another deploy is running — skipping` on every run → stale lock from a
  killed build; it self-clears after 60 min, or immediately:
  `rmdir ~/services/sources/.deploy.lock`.
- `fetch_all.sh still holds ... sources-fetch.lock` → a fetch was running;
  the deploy waited up to `SOURCES_DEPLOY_LOCK_WAIT` (default 900s) and
  skipped. Routine fetches take ~2 min, so repeats of this line mean a
  fetch is stuck — check `journalctl -u sources-fetch`.

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
- Anything about `catalog.db`, `raw/` or a yaml file → the repo itself is
  in a bad state; `git -C ~/dev/sources status` and fix there.

## Layer 2 — local serving broken

**`curl http://127.0.0.1:8098/` fails.**
- `docker ps | grep sources` — container gone entirely?
  `docker compose --project-directory ~/dev/setup-server/sources up -d`
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

(Any later successful deploy moves `current` again — pin by stopping the
timer first: `systemctl --user stop sources-deploy.timer`.)

## Nuke and pave

```sh
systemctl --user disable --now sources-deploy.timer
rm -f ~/.config/systemd/user/sources-deploy.{service,timer}
systemctl --user daemon-reload
docker compose --project-directory ~/dev/setup-server/sources down
rm -rf ~/services/sources
rm -f ~/dev/setup-server/sources/.env
tailscale serve --https=8098 off
cd ~/dev/setup-server/sources && SITE_PASSPHRASE='...' ./setup.sh
```
Nothing of value lives in `~/services/sources` — the corpus's source of
truth is the git repo at `~/dev/sources` (and GitHub), which this never
touches.
