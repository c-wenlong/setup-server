# umami — locally hosted web analytics

Privacy-respecting pageviews and events for sites you already run, on
the tailnet: `https://homeserver.tail-name.ts.net:8106`.

Chosen over Google Analytics / Plausible Cloud (data leaves the
tailnet). Umami v3 is Postgres-only.

**`:3000` is taken.** forgejo already publishes git there. Umami's
upstream default is 3000; this deploy uses **8106**.

## Architecture

```
  phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:8106
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8106
            ▼
   ┌────────────────────────────────────────────┐
   │ container: umami                           │
   │   ghcr.io/umami-software/umami:3.3.1       │
   │   Next.js                   :3000          │
   └──────────────────┬─────────────────────────┘
                      │ compose network
                      ▼
            umami-db (postgres:16-alpine)
            named volume umami-postgres
```

Postgres is unpublished. Marker dir `~/services/umami`.

`services/umami/.env` — ports, pin, admin, secrets (gitignored, 600).

## Security model

Loopback + Tailscale Serve. Umami still has its own accounts (that is
the product). Upstream seeds `admin` / `umami` on first boot — a
well-known pair. `setup.sh` rotates that password via the API to
`UMAMI_ADMIN_PASSWORD`. Telemetry off. Tracker snippets on *public*
sites will POST to this tailnet URL; that only works from devices on
the tailnet (or if you later publish Umami more widely — this deploy
does not).

## What the script does

1. Preflight: not root, Docker daemon, Compose v2, Tailscale Running,
   MagicDNS name.
2. Write `.env` if absent (never overwrite).
3. `docker compose up -d`.
4. Wait on `GET /api/heartbeat`.
5. Log in as `admin`/`umami` and `POST /api/users/{id}/password`.
6. `tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$LOCAL_PORT`.
7. End-to-end HTTPS check.

```bash
cd services/umami && ./setup.sh     # idempotent; rerun to upgrade/repair
```

## Client

Browser on the tailnet. Sign in as `admin` with `UMAMI_ADMIN_PASSWORD`
from `.env`. Add a website, copy the tracker snippet into pages that
can reach this URL.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/umami ps
docker compose --project-directory ~/dev/setup-server/services/umami logs -f
docker compose --project-directory ~/dev/setup-server/services/umami restart
```

Upgrade: bump `UMAMI_VERSION` in `.env`, then `./setup.sh`.

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes the Serve
port(s) pointing at `LOCAL_PORT` and runs `compose down`; the `umami-postgres`
volume and `.env` stay, so `./setup.sh` brings it back. `./teardown.sh --purge`
also deletes the volume (all analytics), the marker dir and `.env`, after you
type `umami`. From a terminal, pause the `umami` monitor in Uptime Kuma first.

Backup target: `docker compose exec -T db pg_dump -U umami umami`.
Nothing on this box backs itself up.
