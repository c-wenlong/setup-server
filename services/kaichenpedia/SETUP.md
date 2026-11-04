# kaichenpedia — personal wiki, auto-deployed from GitHub

A Next.js app built from the private
[c-wenlong/kaichenpedia](https://github.com/c-wenlong/kaichenpedia) repo's
`site/Dockerfile`, run as one container and published tailnet-only. Push
to `main` from any device and deployd rebuilds it within a few minutes,
or immediately with `~/services/kaichenpedia/bin/deploy.sh --force`.

## Architecture

```
git push (any device)
        │
        ▼
   GitHub (private repo)
        ▲  deployd polls ls-remote every minute (services/deployd)
        │
deployd ──► setup.sh ──► bin/deploy.sh
  (one poller for all             │ 1. git reset --hard origin/main
   deploy blocks)                 │ 2. docker build -f site/Dockerfile -t kaichenpedia:<sha> <repo>
                                  │ 3. docker compose up -d   (KAICHENPEDIA_IMAGE=kaichenpedia:<sha>)
                                  │ 4. health check; roll back to the previous image if it fails
                                  ▼
                    kaichenpedia (Docker) 127.0.0.1:8091 -> :8080
                      Next.js standalone server: the pages and /api/*
                      (in-browser edits + copilot) in one process
                                  │
                                  ▼
              Tailscale Serve  HTTPS :8091 (tailnet only)
        https://homeserver.tail-name.ts.net:8091
```

## Why polling, not a webhook

The server is tailnet-only (nothing listens on the internet), so GitHub's
webhooks can't reach it. The push-to-deploy options were:

| Option | Verdict |
|---|---|
| **Poll from the box** (this design) | ✅ Outbound-only, zero new attack surface, no GitHub-side config. Worst-case latency ≈ a minute (deployd's tick; `deploy.sh --force` deploys now). A no-change poll is one cheap `git ls-remote`. |
| GitHub Actions self-hosted runner | True push-trigger (runner long-polls GitHub), but adds a persistent runner daemon with a repo token plus a workflow in the wiki repo. The upgrade path if polling ever feels slow. |
| Webhook via Tailscale Funnel | ❌ Funnel exposes an endpoint to the public internet — violates this repo's tailnet-only security model. |
| Webhook relay (smee.io, Cloudflare Tunnel) | ❌ Third-party dependency for a problem polling solves for free. |

## Security model

- The container publishes `127.0.0.1:8091` only; HTTPS + device auth come
  from Tailscale. It serves the pages and `/api/*` from the same process.
- `COPILOT_SECRET` stays unset here: tailnet-only means `/api/*` runs in
  open mode (the UI never prompts). Set it if the site is ever published
  wider. `/api/*` POSTs still require `application/json` + a same-origin
  `Sec-Fetch-Site`, so cross-site pages can't commit through a reader's
  browser.
- `.env` gains one secret, `GH_TOKEN` (GitHub PAT, repo scope): `/api/save`
  and the copilot commit through the GitHub API. Everything else in `.env`
  is paths + ports. Repo auth for deployd's polling and the deploy clone's
  fetch still comes from git's credential helper (`gh auth setup-git`).
- The deploy clone (`~/services/kaichenpedia/repo`) is machine-managed and
  hard-reset on every deploy — **never edit it by hand**; a human working
  copy belongs in `~/dev` per the filesystem layout in `DIRECTORY.md`.

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git + non-interactive repo access | poller fetches the private repo unattended | `git ls-remote` with prompts disabled |
| Docker + Compose v2 | builds the image and runs the container (Node lives inside the image) | daemon reachable |
| Tailscale (running) | HTTPS publish | backend state |

## What setup.sh does

1. Preflight (above), including proving the private repo is readable
   without a terminal prompt — fails early with the `gh auth` fix if not.
2. Writes `.env` if absent (repo URL, branch, ports, service home, the
   commented-out API secrets). Re-runs read `.env` as the source of truth.
3. Installs `deploy.sh` -> `~/services/kaichenpedia/bin/` (refreshed every
   run; edit the repo copy, then re-run setup.sh).
4. Runs `deploy.sh`: clone, `docker build`, `docker compose up -d`,
   health check. When the image for the current sha already exists it skips
   the build.
5. `docker compose up -d --remove-orphans` again with the recorded image,
   which repairs a stopped or removed container and removes the old
   `kaichenpedia-api` sidecar on hosts that had it. Then a local health
   check on the page and a JSON probe through `POST /api/save`. Warns if
   `GH_TOKEN` is unset.
6. Removes `~/services/kaichenpedia/www`, the old Quartz build, on hosts
   that had it. A pre-Docker `nginx.conf` is left alone, unused.
7. Removes the old per-service `kaichenpedia-deploy` timer / LaunchAgent
   if a host still has one — deployd (`services/deployd`) owns scheduling
   now. Removal only happens once deployd itself is installed
   (`~/services/deployd/bin/deployd`); without it the old poller stays and
   setup warns, so install `services/deployd` first for auto-deploy.
8. Publishes via `tailscale serve --bg --https=8091` and verifies
   end-to-end.

## Deploy

```sh
cd services/kaichenpedia && ./setup.sh
```

Overrides: `LOCAL_PORT` / `HTTPS_PORT` (default 8091), `REPO_URL`, `BRANCH`
(main). Overriding `BRANCH` or `REPO_URL` desyncs auto-deploy: deployd polls
the repo/ref declared in `services/kaichenpedia/app.json`'s `deploy` block
(`main` on `https://github.com/c-wenlong/kaichenpedia.git`), so edit the
manifest to match or pushes to the override never trigger a deploy.

## Ops

```sh
~/services/kaichenpedia/bin/deploy.sh --force        # rebuild the image right now
docker logs -f kaichenpedia                          # the running app
~/services/deployd/bin/deployd --status              # what deployd last saw/deployed
journalctl --user -u deployd -n 50                   # poll + deploy history (macOS: ~/Library/Logs/deployd.log)
docker compose --project-directory ~/dev/setup-server/services/kaichenpedia ps|logs|restart
tailscale serve status
./teardown.sh               # Remove: unpublish + stop container; keeps clone, state, .env
./teardown.sh --purge       # also delete the clone, state, units and .env (GitHub stays canonical)
```

A failed build leaves the running container untouched, and a new container
that does not answer its health check within about a minute is swapped back
to the previous image, so broken pushes never take the site down. The
running image and the one before it are kept; older `kaichenpedia:<sha>`
images are removed after each successful deploy.

## Client side

Nothing to install. Open
`https://homeserver.tail-name.ts.net:8091` from any tailnet device.
Editing happens wherever the kaichenpedia repo is cloned — push to `main`
— it goes live once deployd rebuilds it (a few minutes), or run
`~/services/kaichenpedia/bin/deploy.sh` on the box to deploy now.
