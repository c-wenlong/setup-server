# metabase — locally hosted BI

Dashboards, SQL questions and charts over databases you already run, on
the tailnet: `https://kai-home-server.taild6a23f.ts.net:8104`.

Chosen over Metabase Cloud (data leaves the tailnet) and over a pile of
ad-hoc SQL. OSS image, not Pro/Enterprise.

**`:3000` is taken.** forgejo already publishes git there. Metabase's
upstream default is 3000; this deploy uses **8104**.

## Architecture

```
  phone / laptop on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8104
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8104
            ▼
   ┌────────────────────────────────────────────┐
   │ container: metabase                        │
   │   metabase/metabase:v0.63.17.3             │
   │   JVM + Jetty               :3000          │
   └──────────────────┬─────────────────────────┘
                      │ compose network
                      ▼
            metabase-db (postgres:16-alpine)
            named volume metabase-postgres
```

Postgres is unpublished. Marker dir `~/services/metabase` (launcher
"installed"); the app DB is the named volume.

`metabase/.env` — ports, pin, admin, DB password (gitignored, 600).

## Security model

Loopback + Tailscale Serve. No LAN bind, no extra password in front of
Serve. Metabase still has its own accounts (that is the product). First
admin is seeded from `.env` via `POST /api/setup`. Anonymous tracking
off (`MB_ANON_TRACKING_ENABLED=false`). `MB_SITE_URL` is the tailnet
HTTPS URL so reset/embed links never pick up a forged Host header.

## What the script does

1. Preflight: not root, Docker daemon, Compose v2, Tailscale Running,
   MagicDNS name.
2. Write `.env` if absent (never overwrite).
3. `docker compose up -d`.
4. Wait on `GET /api/health` (`{"status":"ok"}`).
5. `POST /api/setup` with the setup-token from `/api/session/properties`.
6. `tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$LOCAL_PORT`.
7. End-to-end HTTPS check.

```bash
cd metabase && ./setup.sh     # idempotent; rerun to upgrade/repair
```

## Client

Browser on the tailnet. Sign in with `MB_ADMIN_EMAIL` / `MB_ADMIN_PASSWORD`
from `.env`. Then add databases (Postgres, etc.) in Admin → Databases —
those are your data sources, not the app DB.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/metabase ps
docker compose --project-directory ~/dev/setup-server/metabase logs -f
docker compose --project-directory ~/dev/setup-server/metabase restart
```

Upgrade: bump `METABASE_VERSION` in `.env`, then `./setup.sh`. Dump the
app DB first.

Backup target: `docker compose exec -T db pg_dump -U metabase metabase`.
Nothing on this box backs itself up.
