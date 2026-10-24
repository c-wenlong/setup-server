# appflowy — self-hosted Notion (docs, databases, wiki)

A workspace you own: documents, databases, boards, and a wiki, on the
tailnet: `https://kai-home-server.taild6a23f.ts.net:8102`.

Chosen over Outline (wiki-only) and over running Notion in a browser
against someone else's cloud. AppFlowy Cloud is the documented production
path ([AppFlowy-Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud));
the desktop and mobile apps talk to the same URL.

Official "from zero to production" compose also starts an AI container
(OpenAI key) and a search indexer that mmaps ~2 GB. Those are **not**
in this deploy. Core editing, sync, and the web client still work.
Turn AI on later by adding the service and an API key — not by flipping
a flag in this `.env` and hoping.

Idle RAM is several hundred MiB across nine containers, with compose
`mem_limit`s as the backstop. Unload ollama if a container gets
OOM-killed.

## Architecture

```
  phone / laptop on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8102
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8102
            ▼
   ┌─────────────────────────────────────────────┐
   │ nginx  :80 in-container (HTTP only)         │
   │   /            → appflowy_web               │
   │   /api /ws     → appflowy_cloud :8000       │
   │   /gotrue      → gotrue :9999               │
   │   /console     → admin_frontend :3000       │
   │   /minio-api   → minio :9000                │
   └──────┬──────────┬──────────┬────────┬───────┘
          │          │          │        │
          ▼          ▼          ▼        ▼
   postgres+pgvector redis     minio    worker
```

State lives under `~/services/appflowy` (launcher marker) plus three
named volumes — Postgres / Redis / MinIO run as their own uids and
cannot write a host-owned bind mount without a sudo chown:

```
~/services/appflowy/       # marker only; dumps you take land here
services/appflowy/.env              # secrets + ports (gitignored, 600)
services/appflowy/nginx.conf        # HTTP-only reverse proxy (in git)

Docker volumes:
  appflowy-postgres
  appflowy-redis
  appflowy-minio
```

Upstream nginx also listens on `:443` with dummy TLS certs. Tailscale
Serve already terminates TLS, so this `nginx.conf` binds `:80` only and
compose publishes `127.0.0.1:LOCAL_PORT`. No pgadmin, no MinIO console,
no Portainer.

**Image pins.** `appflowy_cloud` / `gotrue` / `worker` are `0.18.8`.
The web image has no `0.18.8` tag (newest is `0.18.4`); admin_frontend
tops out at `0.18.1`. Those are the latest published on the 0.18 line,
not a downgrade.

## Security model

- **Tailnet-only.** nginx `127.0.0.1:8102`. Postgres, Redis, MinIO,
  GoTrue, cloud, worker, admin and web stay on the compose network.
  Nothing on LAN or `0.0.0.0`.
- **First admin is seeded from `.env`** (`GOTRUE_ADMIN_EMAIL` /
  `GOTRUE_ADMIN_PASSWORD`) and **`GOTRUE_DISABLE_SIGNUP=true`**, so the
  web UI is never an open "whoever signs up first owns the workspace"
  window. `setup.sh` checks `/gotrue/settings` after publish.
- **No AI container, no search indexer.** AI wants an API key this box
  does not have; search defaults to a 2 GB mmap.
- **No MinIO console, no pgadmin.** `/minio-api` stays — clients need
  it for presigned uploads. That path is still behind Serve.

⚠️ Password-sync rule: a password changed in the UI is not mirrored
back into `.env`.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker restart policy handles boot | ✅ |
| Docker + Compose v2 | nine containers | ✅ |
| curl | health checks | ✅ |
| Tailscale, logged in, MagicDNS | publishing, **and** `APPFLOWY_BASE_URL` | ✅ |
| python3 (or `/dev/urandom`) | secret generation | hex fallback |
| ≥ ~5 GB free disk | images + Postgres + MinIO blobs | ⚠️ warns |

## Deploy

```bash
cd services/appflowy && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, curl, Docker, Compose v2, Tailscale
   `Running`, numeric ports, `nginx.conf` present.
2. **Resolve the tailnet name** before writing `.env` —
   `APPFLOWY_BASE_URL` / `API_EXTERNAL_URL` / websocket / MinIO
   presigned endpoint are baked in at creation time.
3. **`.env`** — written only if absent, mode 600.
4. **`APPFLOWY_BASE_URL` drift check** — warns, does not rewrite `.env`.
5. **Marker dir** `~/services/appflowy` (launcher "installed" check).
   Postgres / Redis / MinIO data are named volumes.
6. **`docker compose up -d`**, wait for `/api/health` (up to ~6 min;
   first boot runs migrations).
7. **`tailscale serve`** for nginx.
8. **Verify** HTTPS `/api/health`, then `/gotrue/settings` so an open
   sign-up cannot look like a successful deploy.

## Client side

Any browser on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8102`. Login with
`GOTRUE_ADMIN_EMAIL` / `GOTRUE_ADMIN_PASSWORD` from `services/appflowy/.env`.
Admin console: `/console`.

Desktop and mobile apps: set the self-hosted cloud URL to the same
HTTPS origin (port included). GoTrue's `GOTRUE_SITE_URL` stays
`appflowy-flutter://` so the apps can complete the OAuth bounce.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/appflowy ps
docker compose --project-directory ~/dev/setup-server/services/appflowy logs -f
docker compose --project-directory ~/dev/setup-server/services/appflowy restart
```

Upgrade: bump `APPFLOWY_CLOUD_VERSION` (and `GOTRUE_VERSION` /
`APPFLOWY_WORKER_VERSION` / `APPFLOWY_WEB_VERSION` /
`APPFLOWY_ADMIN_FRONTEND_VERSION`) in `.env`, then `./setup.sh`.

Backups: keep `.env` off-box with the named volumes
`appflowy-postgres` / `appflowy-redis` / `appflowy-minio`.
Postgres dump:

```bash
docker compose --project-directory ~/dev/setup-server/services/appflowy exec -T postgres \
  pg_dump -U appflowy appflowy > appflowy-$(date +%F).sql
```
