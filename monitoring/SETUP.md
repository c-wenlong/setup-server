# Monitoring — Uptime Kuma + ntfy, tailnet-only

Status dashboard for every service on this box, with push notifications to
your phone when something goes down (and when it recovers).

- **Dashboard**: `https://<host>.<tailnet>.ts.net:3002` — Uptime Kuma
- **Alerts**: `https://<host>.<tailnet>.ts.net:3003` — ntfy, topic `alerts`

## Architecture

```
Uptime Kuma ──probe──▶ code-server :8080 /healthz
 (127.0.0.1:3002)      seafile     :8081 /api2/ping
      │                open-webui  :3001 /health
      │ on failure     ollama      :11434 /api/version
      ▼
    ntfy (127.0.0.1:3003) ──push──▶ phone (ntfy app) + web subscribers
```

Both containers are host-networked (Kuma must reach services bound to the
host's loopback) and bind `127.0.0.1` only. Tailscale Serve fronts each with
HTTPS on its own port — modern Tailscale (>= ~1.90) allows arbitrary HTTPS
serve ports, not just 443/8443/10000.

Kuma is **pinned to 1.23.x**: the seeding library (`uptime-kuma-api`) does
not support Kuma 2.x. Don't bump the image without replacing `seed_kuma.py`.

## Deploy

```sh
./setup.sh
KUMA_PORT=3012 NTFY_TOPIC=my-alerts ./setup.sh   # overrides
```

What it does beyond the usual (preflight → .env → compose up → serve →
verify): **auto-seeds Kuma via its API** using `uv run --with
uptime-kuma-api` — creates the admin account (credentials generated into
`.env`, mode 600), an ntfy notification channel (default, applied to
everything), and one HTTP monitor per service (60s interval, 2 retries).
Seeding is idempotent (skips whatever exists) and best-effort: if `uv` is
missing or the API changes, the deploy still succeeds and you configure via
the web UI instead.

## Phone setup (the point of all this)

1. Install **ntfy** (App Store / Play Store)
2. Add server: `https://<host>.<tailnet>.ts.net:3003` (Tailscale must be
   connected on the phone)
3. Subscribe to topic **`alerts`**

Instant delivery on iOS relies on `NTFY_UPSTREAM_BASE_URL=https://ntfy.sh`:
self-hosted ntfy forwards a "poke" through ntfy.sh's APNS pipeline; message
content stays on your server. Remove that env var in `docker-compose.yml` if
you'd rather have delayed-but-fully-private delivery.

Send anything to your phone from scripts:

```sh
curl -d "backup finished" https://<host>.<tailnet>.ts.net:3003/alerts
```

## Adding monitors for future services

Either click them into the Kuma UI, or add a line to `MONITORS` in
`seed_kuma.py` and re-run `./setup.sh` (seeding only adds what's missing).

## Operations

```sh
D="--project-directory <this dir>"
docker compose $D ps|logs -f|restart|down
docker compose $D pull && docker compose $D up -d   # upgrade ntfy (Kuma: see pin note)
```

Kuma state (monitors, history, admin account): `~/monitoring/kuma`.
ntfy cache: `~/monitoring/ntfy`. Back both up if you care about history.

## Tests

```sh
./tests/run-tests.sh          # mocked suite
./tests/run-tests.sh --live   # + verify real deployment
```
