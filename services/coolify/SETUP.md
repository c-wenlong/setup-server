# coolify — self-hosted PaaS (a Heroku/Vercel you own)

Push a repo, get a running app, on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8101`.

Coolify is the control plane: dashboard, deployments, databases, one-click
services. It is **not** a substitute for Tailscale Serve. Upstream wants
Traefik on `:80`/`:443` bound to every interface so deployed apps get public
HTTPS. That fights this repo's loopback-only rule, so the proxy is left
off. Apps you later deploy through Coolify should publish a loopback port
and get their own `tailscale serve`.

Chosen over CapRover (same job, quieter community) and over running
compose files by hand (what this repo already does). Coolify earns its
keep the day you want a UI to stand up a one-off app without adding
another `setup.sh`.

Official wants 2 CPU / 2 GB RAM / 10 GB disk. This box has 7.7 GB shared
with ollama. Caps in `docker-compose.yml` keep the ceiling around 1.4 GB;
idle is a few hundred MiB. Unload ollama if the dashboard gets OOM-killed.

## Architecture

```
  phone / laptop on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8101
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8101
            ▼
   ┌─────────────────────────────────────────────┐
   │ coolify            :8080 in-container       │
   │   dashboard + API  coollabsio/coolify:4.3.21│
   └──────┬──────────────┬──────────────┬────────┘
          │              │              │
          ▼              ▼              ▼
   postgres:15       redis:7      soketi :6001
   (named volume)    (named vol)  (loopback + Serve)
```

State lives under `~/services/coolify`:

```
~/services/coolify/
  ssh/keys/            # ed25519 key Coolify uses to SSH to this box
  applications/        # app metadata Coolify writes
  databases/
  services/
  backups/
  images/
services/coolify/.env           # secrets + ports (gitignored, 600)
```

Postgres and Redis data live in Docker named volumes `coolify-db` and
`coolify-redis` — the images run as their own uids and cannot write a
host-owned bind mount without a sudo chown.

**`:8000` is taken.** OpenHands already publishes Agent Canvas there.
Coolify's upstream default is 8000; this deploy uses **8101**.

## Security model

- **Tailnet-only.** Dashboard `127.0.0.1:8101`, Soketi `127.0.0.1:6001`
  and metrics `127.0.0.1:6002`. Nothing on LAN or `0.0.0.0`.
- **First admin is seeded from `.env`** (`ROOT_USERNAME` /
  `ROOT_USER_EMAIL` / `ROOT_USER_PASSWORD`) so `/register` is never an
  open "whoever loads the page first is root" window. Coolify's own docs
  call that out as the failure mode.
- **`AUTOUPDATE=false`.** Coolify's in-app updater re-downloads official
  compose into `/data/coolify/source` and would undo the loopback binds.
  Upgrade by bumping `COOLIFY_VERSION` in `.env` and re-running `./setup.sh`.
- **Do not start Coolify's Traefik proxy** on this box. Upstream binds
  `:80`/`:443` on every interface.
- **SSH to localhost as `$USER`, not root.** `setup.sh` writes an
  ed25519 key under `~/services/coolify/ssh/keys/` and appends the
  pubkey to `~/.ssh/authorized_keys`. The Coolify container talks to
  `host.docker.internal`. You still need to be in the `docker` group.

⚠️ Password-sync rule: a password changed in the UI is not mirrored back
into `.env`.

Realtime (live deployment logs) goes through Soketi on `:6001`, also
Serve-published. The browser uses `PUSHER_SCHEME=https`; the Coolify
backend talks to `coolify-realtime:6001` over HTTP on the compose
network. Sharing `https` for both is a known Coolify bug (TLS handshake
against a plaintext socket).

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker restart policy handles boot | ✅ |
| Docker + Compose v2 | four containers | ✅ |
| curl | health checks | ✅ |
| Tailscale, logged in, MagicDNS | publishing, **and** `APP_URL` | ✅ |
| python3 or openssl | secret generation | APP_KEY dies without one |
| ssh-keygen | localhost SSH key | ⚠️ warns, dashboard still works |
| ≥ 10 GB free disk | images + whatever you later deploy | ⚠️ warns |

Coolify is a Linux product. Darwin is portable for the dashboard;
deploying apps onto a Mac through Coolify is unverified.

## Deploy

```bash
cd services/coolify && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, curl, Docker, Compose v2, Tailscale
   `Running`, numeric ports.
2. **Resolve the tailnet name** before writing `.env` — `APP_URL` is
   baked in at creation time.
3. **`.env`** — written only if absent, mode 600.
4. **`APP_URL` drift check** — warns, does not rewrite `.env`.
5. **Dirs + ACL for uid 9999** (Coolify's container user), then an
   ed25519 key and `authorized_keys` line.
6. **`docker compose up -d`**, wait for `/api/health` (up to ~4.5 min;
   first boot runs migrations).
7. **`tailscale serve`** for the dashboard (required) and Soketi
   (best-effort).
8. **Verify** HTTPS `/api/health`, then a `/register` check so an
   unseeded first-run form cannot look like a successful deploy.

## Client side

Any browser on the tailnet: `https://kai-home-server.taild6a23f.ts.net:8101`.
Login with `ROOT_USERNAME` / `ROOT_USER_PASSWORD` from `services/coolify/.env`.

To deploy an app onto this box from the UI: Servers → localhost → SSH
user `$USER` (not root). Give the app a loopback port, then:

```bash
tailscale serve --bg --https=<port> http://127.0.0.1:<port>
```

Do not enable the Coolify Proxy.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f coolify`
- Restart: `docker compose --project-directory . restart`
- Upgrade: bump `COOLIFY_VERSION` in `.env`, then `./setup.sh`
- Remove: `./teardown.sh` (or Remove in the launcher) unpublishes the
  dashboard and Soketi Serve ports and runs `compose down` on Coolify's own
  stack; apps it deployed keep running, and volumes, `~/services/coolify`,
  `.env` and the SSH key stay, so `./setup.sh` brings it back.
  `./teardown.sh --purge` also deletes them (and Coolify's
  `authorized_keys` line) after you type `coolify`; it refuses until the
  apps you deployed through Coolify are deleted there.
- Dump the database:
  ```bash
  docker compose --project-directory . exec -T postgres \
    pg_dump -U coolify coolify > coolify-$(date +%F).sql
  ```
  Keep that dump **and** `services/coolify/.env` (it has `APP_KEY`) off this box.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

## Notes

- Official installer is `curl | sudo bash` into `/data/coolify`. This
  script does not run it: it requires root, rewrites `daemon.json`, and
  binds `0.0.0.0`. Manual compose is the documented alternative and the
  one that fits this repo.
- `APP_KEY` encrypts values in Postgres. Losing `.env` loses the ability
  to decrypt a restored database.
- Soketi metrics on `:6002` stay loopback and unpublished.
