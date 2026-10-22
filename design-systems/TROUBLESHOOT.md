# design-systems — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

This service builds the working clone at `~/dev/design-systems` — the same
clone you edit in. The deploy only reads it (and pulls it ff-only); a
broken deploy never touches your work in it, but a dirty tree does get
built — same as `make serve`.

## Quick status

```sh
systemctl --user list-timers design-systems-deploy.timer   # poller scheduled?
journalctl --user -u design-systems-deploy -n 30           # last deploy runs
cat ~/services/design-systems/state/built-sha              # what was last built
git -C ~/dev/design-systems rev-parse HEAD                 # what the repo is at
docker inspect -f '{{.State.Status}}' design-systems       # nginx up?
curl -sI http://127.0.0.1:8108/gallery/ | head -1          # serving locally?
tailscale serve status                                     # :8108 published?
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` reports
a healthy container as not running. Re-run under `sg docker -c '...'`.

The Serve mapping stays in place while the container is stopped, so `:8108`
appearing in `tailscale serve status` proves nothing about the site.

## Layer 1 — deploys not happening

**A push landed but the site didn't update.**
- The poller only runs daily by default — deploy now with
  `~/services/design-systems/bin/deploy.sh`, or check the last run:
  `journalctl --user -u design-systems-deploy -n 30`.
- `up to date at <sha>` with an old sha → `built-sha` equals
  `git -C ~/dev/design-systems rev-parse HEAD`, meaning the repo itself is
  behind: the push went to another branch, or was never pulled. `.env`
  `BRANCH` is only documentation here — deploy.sh builds HEAD, whatever it
  is.
- `note: git pull --ff-only did not apply` in the log → the clone is dirty
  or offline. The build still runs on the local working tree, so this is a
  warning, not a failure — but an unexpected dirty tree means your edits
  (or a half-finished worktree cleanup) are being served.
- No log entries at all → timer not running:
  `systemctl --user enable --now design-systems-deploy.timer`; if the box
  just rebooted and nothing user-level runs, re-check lingering:
  `loginctl show-user $USER -p Linger` → fix with
  `sudo loginctl enable-linger $USER`.
- `another deploy is running — skipping` on every run → stale lock from a
  killed build; it self-clears after 60 min, or immediately:
  `rmdir ~/services/design-systems/.deploy.lock`.

**Build fails (site keeps serving the old version — that's by design).**
Run it by hand to see the full error:
```sh
~/services/design-systems/bin/deploy.sh --force
```
- `cannot identify image file ...` (Pillow) → an LFS pointer reached the
  thumbnail step: the checkout's screenshots were never materialised.
  `git -C ~/dev/design-systems lfs pull` (install `git-lfs` first if
  needed), then re-run deploy.
- `tools/site.py` import errors (`import markdown`) → the repo's `.venv`
  was deleted or requirements.txt changed; deploy.sh recreates/re-syncs it
  (`uv venv` + `uv pip install -r requirements.txt`) — if that fails, `uv`
  must be on `.env`'s `UV_BIN` path; if uv moved, update `UV_BIN` or re-run
  setup.sh.
- `python3` import errors on `tools/scorecard.py` → it imports
  `tools/catalog.py`; both run from the repo root with system python3
  (stdlib only). If it fails, the repo itself is in a bad state —
  `git -C ~/dev/design-systems status` and fix there.
- `tools/site.py` render errors → a real docs/ markup problem; reproduce
  with `make docs` in the clone.
- A stuck `site/` or `www/next` → `rm -rf ~/dev/design-systems/site
  ~/services/design-systems/www/next` and retry (both are regenerated).

**The gallery renders but a package's files/screenshots 404.**
Those come from the repo-path aliases, live from the checkout — not from
the release. If `curl http://127.0.0.1:8108/catalog.json` fails while
`/gallery/` works, the `SOURCE_REPO` mount is wrong: check
`docker inspect design-systems | grep srv/repo` against `.env`'s
`SOURCE_REPO`, and that `tools/catalog.py`'s `REPO_PATHS` still matches
the allowlist in `~/services/design-systems/nginx.conf`.

## Layer 2 — local serving broken

**`curl http://127.0.0.1:8108/` fails.**
- `docker ps | grep design-systems` — container gone entirely?
  `docker compose --project-directory ~/dev/setup-server/design-systems up -d`
- Container restarting → `docker logs design-systems`; an nginx config
  error means `~/services/design-systems/nginx.conf` was edited badly
  (delete it and re-run setup.sh to regenerate the default).
- 403/404 on `/` or `/gallery/` → `www/current` missing or an empty
  release: the initial build never completed; run `bin/deploy.sh --force`.
- Gallery loads but `data.json` 404s or shows `{}` → `catalog.py build`
  didn't run in that deploy; redeploy with `bin/deploy.sh --force`.

**The site serves an old commit even after a successful deploy.**
`www/current` is a symlink — check it points at the new sha and that
`state/built-sha` updated. A deploy killed mid-swap can't leave a gap (the
repoint is one rename) but can leave `www/next` behind; see Layer 1.

## Layer 3 — publish broken

**Local works, `https://…:8108` doesn't.**
- `tailscale serve status` should map `:8108` → `127.0.0.1:8108`. Re-add:
  `tailscale serve --bg --https=8108 http://127.0.0.1:8108`
- `Access denied` → operator not set: `sudo tailscale set --operator=$USER`.
- First-ever HTTPS hit can take ~60s (cert minting).
- ⚠️ **Never `tailscale serve reset`** to clear a bad mapping. It wipes the
  serve config for the whole node — every published service dark at once,
  each one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=8108 off`; `off` is absent from
  `tailscale serve --help` on 1.102.3 (which only advertises `reset` and
  `clear`) but is what Tailscale prints after a successful serve, and is
  verified working here.
- **Kuma red but the container is up** — the monitor probes the tailnet URL
  (`https://…:8108/gallery/`), not loopback, so it goes red for a
  publishing failure too. Curl `http://127.0.0.1:8108/gallery/` first; if
  that answers, the fault is Serve or the cert. Everything red at once is
  tailscaled.

## Layer 4 — client broken

- Other tailnet services (e.g. `:3002`) reachable? If not, it's the
  client's Tailscale, not this service.
- Gallery loads but every screenshot is broken → the checkout's LFS objects
  are missing (Layer 1: `git lfs pull`). `data.json` falls back to the
  full-size path when no thumb exists, so this also looks like permanently
  grey covers.
- A package's README.md link downloads instead of displaying →
  `~/services/design-systems/nginx.conf` lost its `types { text/markdown
  md; }` block (a stale or hand-edited copy). Delete it and re-run
  setup.sh to regenerate the default.

## Rollback

`www/current` is a symlink into `www/releases/`; the previous release is
kept beside it. Directory names are the built sha, with a `.rebuild-<ts>`
suffix when a `--force` rebuilt a sha that was already live. Repoint
`current` at the older release:

```sh
cd ~/services/design-systems/www
ls releases/                       # pick the directory to go back to
ln -sfn releases/<name> current.new && mv -Tf current.new current
```

(Any later successful deploy moves `current` again — pin by stopping the
timer first: `systemctl --user stop design-systems-deploy.timer`. The
repo-path aliases keep serving the live checkout either way.)

## Nuke and pave

```sh
systemctl --user disable --now design-systems-deploy.timer
rm -f ~/.config/systemd/user/design-systems-deploy.{service,timer}
systemctl --user daemon-reload
docker compose --project-directory ~/dev/setup-server/design-systems down
rm -rf ~/services/design-systems
rm -f ~/dev/setup-server/design-systems/.env
tailscale serve --https=8108 off
cd ~/dev/setup-server/design-systems && ./setup.sh
```
Nothing of value lives in `~/services/design-systems` — the source of
truth is the git repo at `~/dev/design-systems` (and GitHub), which this
never writes to beyond the repo's own gitignored build outputs.
