# plane — locally hosted project management

Issues, cycles and pages (Linear/Jira-shaped), on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8105`.

This is **Plane Community**, not the commercial edition. Our compose,
not a wrap of Plane's interactive `setup.sh`.

## Architecture

```
  phone / laptop on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8105
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8105
            ▼
   ┌────────────────────────────────────────────┐
   │ container: plane-proxy                     │
   │   makeplane/plane-proxy:v1.4.2  :80 only   │
   └──────┬──────────┬──────────┬───────────────┘
          │          │          │
        web        api        admin / space / live
          │          │
          └──── worker / beat-worker
                     │
          postgres + valkey + rabbitmq + minio
          (named volumes; no host ports)
```

Eleven long-running containers plus a one-shot migrator. Marker dir
`~/services/plane`. MinIO is `quay.io/minio/minio` — Docker Hub froze
`minio/minio`. RabbitMQ is the alpine image, not `-management` (no
console published). Proxy HTTP-only; Serve has TLS.

`services/plane/.env` — ports, pin, secrets, first admin (gitignored, 600).

## Security model

Loopback + Tailscale Serve. No `:443` on the proxy (that would steal
the host's 443 from code-server). First instance admin is seeded from
`.env` via `POST /api/instances/admins/sign-up/` (form POST, **without**
`is_telemetry_enabled` — a string `"false"` 500s and leaves the
instance half-configured, makeplane/plane#9370). God Mode is at
`/god-mode`. Plane still has its own accounts (that is the product).

This stack is heavy. Caps total a few GB; unload ollama or Immich ML
if the box starts swapping.

## What the script does

1. Preflight: not root, Docker daemon, Compose v2, Tailscale Running,
   MagicDNS name. Warns if RAM is tight.
2. Write `.env` if absent (never overwrite).
3. `docker compose up -d` (api waits on migrator completing).
4. Wait on `GET /api/instances/`.
5. Seed the instance admin.
6. `tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$LOCAL_PORT`.
7. End-to-end HTTPS check.

```bash
cd services/plane && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Do **not** run Plane's own `setup.sh` from GitHub — it is interactive
and binds `0.0.0.0`.

## Client

Browser on the tailnet. Sign in with `PLANE_ADMIN_EMAIL` /
`PLANE_ADMIN_PASSWORD` from `.env`. Create a workspace. Instance
settings live at `/god-mode`.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/plane ps
docker compose --project-directory ~/dev/setup-server/services/plane logs -f
docker compose --project-directory ~/dev/setup-server/services/plane restart
```

Upgrade: bump `APP_RELEASE` in `.env`, then `./setup.sh`. Dump Postgres
first.

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes `:HTTPS_PORT`
and runs `compose down`; the `plane_*` named volumes and `.env` stay, so
`./setup.sh` brings it back. `./teardown.sh --purge` also drops the volumes
(`down -v`), the `PLANE_DATA` marker dir and `.env`, after you type `plane`.

Backup target: `docker compose exec -T plane-db pg_dump -U plane plane`
plus the MinIO named volume. Nothing on this box backs itself up.
