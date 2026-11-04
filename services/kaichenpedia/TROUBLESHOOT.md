# kaichenpedia — troubleshooting

Layered triage: deploy pipeline → local serving → publish → client. Work
top-down; each layer assumes the one above it is healthy.

**A stale page with a green tile means a build is failing, not that the
site is down.** deploy.sh never touches the running container when a build
fails, and rolls back a new one that does not turn healthy, so the last good
version keeps serving. Check the deployd log (Layer 1) before the container.

If the container has been stopped on purpose (ntfy-control or the launcher's
stop button), `Exited (0)` and connection refused on :8091 are expected:
`docker start kaichenpedia` brings it back.

## Quick status

```sh
~/services/deployd/bin/deployd --status                # what deployd last saw/deployed
systemctl --user list-timers deployd.timer             # deployd scheduled?
journalctl --user -u deployd -n 30                     # last poll + deploy runs
cat ~/services/kaichenpedia/state/built-sha              # what was last deployed
cat ~/services/kaichenpedia/state/image                  # the image it runs
docker inspect -f '{{.State.Status}} {{.Config.Image}}' kaichenpedia   # up, and on which image?
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
- deployd polls every minute — deploy now with
  `~/services/kaichenpedia/bin/deploy.sh --force`, or check the last run:
  `journalctl --user -u deployd -n 30` /
  `~/services/deployd/bin/deployd --status`. A `.fail` entry in
  `~/services/deployd/state/` means the last attempt failed and deployd is
  backing off before retrying.
- `up to date at <sha>` with an old sha → the fetch isn't seeing your push:
  wrong branch? `.env` `BRANCH` must match what you push to.
- No log entries at all → deployd not running:
  `systemctl --user enable --now deployd.timer`; if the box just
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
- Network errors pulling the base image or npm packages → transient;
  deployd retries the sha after its backoff.
- `npm run build` errors inside `docker build` usually mean a bad
  markdown/frontmatter push or a broken site change — reproduce locally
  with `npm run build` in the wiki repo's `site/`, fix, push again.
- `did not answer as a probe` → the new image built but crashed or hung
  on start. deploy.sh runs every new image as a throwaway probe container
  before touching the live one, and prints the probe's last 80 log lines
  into the deploy log (`~/services/deployd/state/kaichenpedia.log`). The
  live container was not touched.
- `did not take over` then `rolling back` → the probe passed but the swap
  failed (port clash, a bad value in `.env`). The live container's logs
  are printed before the rollback.
- Disk filling up → `docker image ls kaichenpedia`: deploy.sh keeps two
  images and prunes the rest, but build cache grows; `docker builder prune`
  is safe.

## Layer 2 — local serving broken

**`curl http://127.0.0.1:8091/` fails.**
- First check it is not the deliberate stop at the top of this file:
  `docker inspect -f '{{.State.Status}} {{.State.FinishedAt}}' kaichenpedia`.
  `exited` with a date and exit code 0 means someone stopped it on purpose;
  `docker start kaichenpedia` brings it back.
- `docker ps | grep kaichenpedia` — container gone entirely?
  `~/services/kaichenpedia/bin/deploy.sh` brings the recorded image back up.
- Container restarting → `docker logs kaichenpedia`. A missing or mistyped
  env var in `.env` is the usual cause; fix it and run
  `~/services/kaichenpedia/bin/deploy.sh`, which recreates the container
  from the recorded image (`state/image`) without rebuilding. Plain
  `docker compose up` would look for `kaichenpedia:local`, which is never
  built.
- `state/image` names an image that `docker image ls kaichenpedia` does not
  have (pruned by hand) → `bin/deploy.sh --force` rebuilds it.

**`/api/*` answers HTML or 404.** The app serves `/api/*` itself now; there
is no nginx proxy or `kaichenpedia-api` sidecar. A leftover
`kaichenpedia-api` container from before the migration is harmless and is
removed by the next `setup.sh` (`--remove-orphans`).

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
- Hard-refresh: a tab opened before a deploy can hold old client chunks;
  a forced reload fetches the new ones.

## Rollback

The image before the current one is kept. To go back to it by hand:
```sh
docker image ls kaichenpedia            # tags are <sha>-<build time>; pick the previous one
cd ~/dev/setup-server/services/kaichenpedia
KAICHENPEDIA_IMAGE=kaichenpedia:<tag> docker compose up -d
echo kaichenpedia:<tag> > ~/services/kaichenpedia/state/image   # so deploy.sh repairs to it
```
(Any later successful deploy replaces it — pin by stopping deployd first:
`systemctl --user stop deployd.timer`. To undo a bad commit for good,
revert it in the wiki repo; the wiki's Run Log page lists the revert
command for every run.)

## Nuke and pave

```sh
cd ~/dev/setup-server/services/kaichenpedia
./teardown.sh --purge     # asks you to type "kaichenpedia"
./setup.sh
```

`--purge` unpublishes the Serve port(s) pointing at the wiki, removes the
legacy `kaichenpedia-deploy` timer/service if one still exists, runs `docker compose down`,
then deletes what setup.sh / deploy.sh made under `SERVICE_HOME` (`repo/`,
`bin/`, `state/`, `.deploy.lock`, and `www/` / `nginx.conf` left by a
pre-Docker install), the two unit files and
`.env`. A file you put in `SERVICE_HOME` yourself is kept. Plain `./teardown.sh` (what the launcher's
Remove runs) stops everything but keeps all of that on disk.

Nothing of value lives on the box — the wiki's source of truth is GitHub.
