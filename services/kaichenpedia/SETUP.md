# kaichenpedia — personal wiki, auto-deployed from GitHub

A [Quartz 4](https://quartz.jzhao.xyz) static build of the private
[c-wenlong/kaichenpedia](https://github.com/c-wenlong/kaichenpedia) repo,
served by nginx and published tailnet-only. Push to `main` from any device
and the box picks it up on its daily poll — or immediately with
`~/services/kaichenpedia/bin/deploy.sh --force`.

## Architecture

```
git push (any device)
        │
        ▼
   GitHub (private repo)
        ▲  outbound git fetch, daily (POLL_SECONDS)
        │
kaichenpedia-deploy.timer ──► bin/deploy.sh
  (systemd user timer;          │ 1. git reset --hard origin/main
   launchd on macOS)            │ 2. python3 scripts/sync_wiki_to_site.py   (wiki/ -> site/content/)
                                │ 3. npm ci            (only when package-lock changes)
                                │ 4. npx quartz build  (-> site/public/)
                                │ 5. atomic swap        www/next -> www/current
                                ▼
                     ~/services/kaichenpedia/www/current
                                │  bind mount (ro)
                                ▼
                    nginx (Docker) 127.0.0.1:8091
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
| **Poll from the box** (this design) | ✅ Outbound-only, zero new attack surface, no GitHub-side config. Worst-case latency = `POLL_SECONDS` (default daily; `deploy.sh --force` deploys now). A no-change poll is one cheap `git fetch`. |
| GitHub Actions self-hosted runner | True push-trigger (runner long-polls GitHub), but adds a persistent runner daemon with a repo token plus a workflow in the wiki repo. The upgrade path if polling ever feels slow. |
| Webhook via Tailscale Funnel | ❌ Funnel exposes an endpoint to the public internet — violates this repo's tailnet-only security model. |
| Webhook relay (smee.io, Cloudflare Tunnel) | ❌ Third-party dependency for a problem polling solves for free. |

## Security model

- nginx binds `127.0.0.1:8091` only; HTTPS + device auth come from Tailscale.
- The site is static files — no app code, no database, no accounts.
- `.env` holds no secrets (paths + ports only). Repo auth for the poller
  comes from git's existing credential helper (`gh auth setup-git`).
- The deploy clone (`~/services/kaichenpedia/repo`) is machine-managed and
  hard-reset on every deploy — **never edit it by hand**; a human working
  copy belongs in `~/dev` per the filesystem layout in `DIRECTORY.md`.

## Dependencies

| Dependency | Why | Checked in preflight |
|---|---|---|
| git + non-interactive repo access | poller fetches the private repo unattended | `git ls-remote` with prompts disabled |
| Node.js >= 22 (+ npm/npx) | Quartz build | version parse |
| python3 | repo's `scripts/sync_wiki_to_site.py` | presence |
| Docker + Compose v2 | nginx container | daemon reachable |
| Tailscale (running) | HTTPS publish | backend state |

## What setup.sh does

1. Preflight (above), including proving the private repo is readable
   without a terminal prompt — fails early with the `gh auth` fix if not.
2. Writes `.env` if absent (repo URL, branch, ports, poll interval, node
   path, service home). Re-runs read `.env` as the source of truth.
3. Writes `~/services/kaichenpedia/nginx.conf` if absent (`try_files`
   maps Quartz's extensionless links to `.html` files).
4. Installs `deploy.sh` -> `~/services/kaichenpedia/bin/` (refreshed every
   run; edit the repo copy, then re-run setup.sh).
5. Runs the initial deploy: clone, sync, `npm ci`, `quartz build`, swap.
6. `docker compose up -d` (nginx, `restart: unless-stopped`) + local health
   check.
7. Installs the poller: systemd user timer (`OnUnitActiveSec=POLL_SECONDS`) +
   lingering on Linux; a launchd `StartInterval` agent on macOS.
8. Publishes via `tailscale serve --bg --https=8091` and verifies
   end-to-end.

## Deploy

```sh
cd services/kaichenpedia && ./setup.sh
```

Overrides: `LOCAL_PORT` / `HTTPS_PORT` (default 8091), `REPO_URL`, `BRANCH`
(main), `POLL_SECONDS` (86400 = daily).

## Ops

```sh
~/services/kaichenpedia/bin/deploy.sh --force        # rebuild right now
journalctl --user -u kaichenpedia-deploy -n 50       # deploy history
systemctl --user list-timers kaichenpedia-deploy.timer
docker compose --project-directory ~/dev/setup-server/services/kaichenpedia ps|logs|restart
tailscale serve status
./teardown.sh               # Remove: unpublish, stop poller + container; keeps clone, site, .env
./teardown.sh --purge       # also delete the clone, site, units and .env (GitHub stays canonical)
```

A failed build leaves the previous `www/current` serving untouched — broken
pushes never take the site down. The last good build is also kept in
`www/prev`.

## Client side

Nothing to install. Open
`https://homeserver.tail-name.ts.net:8091` from any tailnet device.
Editing happens wherever the kaichenpedia repo is cloned — push to `main`
— it goes live on the next daily poll, or run
`~/services/kaichenpedia/bin/deploy.sh` on the box to deploy now.
