# kaichenpedia — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

**Before anything else: the nginx container is intentionally stopped** on this
box (since 2026-09-08, via ntfy-control; its Kuma monitor is paused and the
launcher shows it as an amber "Paused" tile). `Exited (0)`, connection refused
on :8091, and a blank Kuma graph are all the expected state, not a fault.
Start it from the ntfy panel, the launcher's start button, or
`docker start kaichenpedia`.

Note that the **deploy timer keeps running while the container is stopped** —
it pulls from GitHub and rebuilds into `www/current` on schedule (verified:
it built `c0c8d6e` at 23:58 with the container down since 2026-09-08). So a
fresh `built-sha` proves the pipeline works and says nothing about whether
anything is being served.

## Quick status

```sh
systemctl --user list-timers kaichenpedia-deploy.timer   # poller scheduled?
journalctl --user -u kaichenpedia-deploy -n 30           # last deploy runs
cat ~/services/kaichenpedia/state/built-sha              # what was last built
docker inspect -f '{{.State.Status}}' kaichenpedia       # nginx up?
curl -sI http://127.0.0.1:8091/ | head -1                # serving locally?
tailscale serve status                                   # :8091 published?
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` reports a
healthy container as not running. Re-run under `sg docker -c '...'`.

The Serve mapping stays in place while the container is stopped, so `:8091`
appearing in `tailscale serve status` proves nothing about the site.

## Layer 1 — deploys not happening

**I pushed but the site didn't update.**
- The poller only runs daily by default — deploy now with
  `~/services/kaichenpedia/bin/deploy.sh`, or check the last run:
  `journalctl --user -u kaichenpedia-deploy -n 30`.
- `up to date at <sha>` with an old sha → the fetch isn't seeing your push:
  wrong branch? `.env` `BRANCH` must match what you push to.
- No log entries at all → timer not running:
  `systemctl --user enable --now kaichenpedia-deploy.timer`; if the box just
  rebooted and nothing user-level runs, re-check lingering:
  `loginctl show-user $USER -p Linger` → fix with
  `sudo loginctl enable-linger $USER`.
- `could not read Username` / auth errors → git credentials broke:
  `gh auth login && gh auth setup-git`, then
  `~/services/kaichenpedia/bin/deploy.sh` by hand to confirm.
- `another deploy is running — skipping` on every run → stale lock from a
  killed build; it self-clears after 60 min, or immediately:
  `rmdir ~/services/kaichenpedia/.deploy.lock`.

**Build fails (site keeps serving the old version — that's by design).**
Run it by hand to see the full error:
```sh
~/services/kaichenpedia/bin/deploy.sh --force
```
- `npm ci` / network errors → transient; the next timer tick retries.
- Quartz build errors usually mean a bad markdown/frontmatter push — fix in
  the wiki repo and push again.
- Node errors after a system update → `node --version` must be >= 22 and
  live where `.env`'s `NODE_BIN` points; if node moved, update `NODE_BIN`.

## Layer 2 — local serving broken

**`curl http://127.0.0.1:8091/` fails.**
- First check it is not the deliberate stop at the top of this file:
  `docker inspect -f '{{.State.Status}} {{.State.FinishedAt}}' kaichenpedia`.
  `exited` with a date and exit code 0 means someone stopped it on purpose;
  `docker start kaichenpedia` brings it back.
- `docker ps | grep kaichenpedia` — container gone entirely?
  `docker compose --project-directory ~/dev/setup-server/kaichenpedia up -d`
- Container restarting → `docker logs kaichenpedia`; an nginx config error
  means `~/services/kaichenpedia/nginx.conf` was edited badly (delete it and
  re-run setup.sh to regenerate the default).
- 403/404 on `/` → `~/services/kaichenpedia/www/current/index.html` missing:
  the initial build never completed; run `bin/deploy.sh --force`.

**Pages 404 but the homepage works.** The `try_files $uri $uri/ $uri.html`
line in nginx.conf is what resolves Quartz's extensionless links — restore
it if the config was customized.

## Layer 3 — publish broken

**Local works, `https://…:8091` doesn't.**
- `tailscale serve status` should map `:8091` → `127.0.0.1:8091`. Re-add:
  `tailscale serve --bg --https=8091 http://127.0.0.1:8091`
- `Access denied` → operator not set: `sudo tailscale set --operator=$USER`.
- First-ever HTTPS hit can take ~60s (cert minting).
- ⚠️ **Never `tailscale serve reset`** to clear a bad mapping. It wipes the
  serve config for the whole node — every published service dark at once, each
  one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=8091 off`; `off` is absent from
  `tailscale serve --help` on 1.102.3 (which only advertises `reset` and
  `clear`) but is what Tailscale prints after a successful serve, and is
  verified working here.
- **Kuma red but the container is up** — the monitor probes the tailnet URL
  (`https://…:8091/`), not loopback, so it goes red for a publishing failure
  too. Curl `http://127.0.0.1:8091/` first; if that answers, the fault is
  Serve or the cert. Everything red at once is tailscaled.

## Layer 4 — client broken

- Other tailnet services (e.g. `:3002`) reachable? If not, it's the client's
  Tailscale, not this service.
- Hard-refresh: Quartz sites use a service worker-ish SPA router; stale
  assets clear with a forced reload.

## Rollback

The previous build stays in `www/prev`:
```sh
cd ~/services/kaichenpedia/www
mv current bad && mv prev current
```
(Any later successful deploy overwrites the rollback — pin by stopping the
timer first: `systemctl --user stop kaichenpedia-deploy.timer`.)

## Nuke and pave

```sh
systemctl --user disable --now kaichenpedia-deploy.timer
rm -f ~/.config/systemd/user/kaichenpedia-deploy.{service,timer}
systemctl --user daemon-reload
docker compose --project-directory ~/dev/setup-server/kaichenpedia down
rm -rf ~/services/kaichenpedia
rm -f ~/dev/setup-server/kaichenpedia/.env
tailscale serve --https=8091 off
cd ~/dev/setup-server/kaichenpedia && ./setup.sh
```
Nothing of value lives on the box — the wiki's source of truth is GitHub.
