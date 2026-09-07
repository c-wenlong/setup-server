# kaichenpedia — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

## Quick status

```sh
systemctl --user list-timers kaichenpedia-deploy.timer   # poller scheduled?
journalctl --user -u kaichenpedia-deploy -n 30           # last deploy runs
cat ~/services/kaichenpedia/state/built-sha              # what's live
docker inspect -f '{{.State.Status}}' kaichenpedia       # nginx up?
curl -sI http://127.0.0.1:8091/ | head -1                # serving locally?
tailscale serve status                                   # published?
```

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
- `docker ps | grep kaichenpedia` — container gone? 
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
