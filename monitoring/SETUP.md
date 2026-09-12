# Monitoring — Uptime Kuma + ntfy, tailnet-only

Status dashboard for every service on this box, with push notifications to
your phone when something goes down (and when it recovers).

- **Dashboard**: `https://<host>.<tailnet>.ts.net:3002` — Uptime Kuma
- **Alerts**: `https://<host>.<tailnet>.ts.net:3003` — ntfy, topic `alerts`

## Architecture

```
Uptime Kuma ──probe──▶ https://<tailnet host>/healthz          (code-server)
 (127.0.0.1:3002)      https://<tailnet host>:8443/api2/ping/  (seafile)
      │                https://<tailnet host>:10000/health     (open-webui)
      │                https://<tailnet host>:2283/api/...     (immich)
      │ on failure     http://127.0.0.1:11434/api/version      (ollama*)
      ▼
    ntfy (127.0.0.1:3003) ──push──▶ phone (ntfy app) + web subscribers
```

Monitors probe the **tailnet HTTPS URL**, not loopback. Two reasons: the
dashboard then shows the address you actually open (Kuma renders the probe
URL as the monitor's link — there is no separate "display URL" field), and
each check exercises the whole path, so a lost `tailscale serve` mapping or
an expired cert registers as downtime. From a phone's point of view that
*is* downtime, and a loopback check is blind to it.

The accepted trade-off: if tailscaled itself breaks, every monitor goes red
at once without singling out the app. When everything fails together, check
`tailscale serve status` before suspecting the services.

\* ollama is deliberately not published via Tailscale Serve, so it has no
tailnet URL and is the one monitor still probing loopback.

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

Either click them into the Kuma UI, or add a line to `PUBLISHED` in
`seed_kuma.py` — `(name, tailnet HTTPS port or None for :443, health path)`
— and re-run `./setup.sh`. Seeding adds what's missing and repoints any
monitor whose URL has changed; it only writes the URL, so a paused monitor
stays paused and a hand-tuned interval survives. A service that is *not*
published via Tailscale Serve should be appended to `MONITORS` directly with
a loopback URL, as ollama is.

## Operations

```sh
D="--project-directory <this dir>"
docker compose $D ps|logs -f|restart|down
docker compose $D pull && docker compose $D up -d   # upgrade ntfy (Kuma: see pin note)
```

Kuma state (monitors, history, admin account): `~/services/monitoring/kuma`.
ntfy cache: `~/services/monitoring/ntfy`. Back both up if you care about history.

## Tests

```sh
./tests/run-tests.sh          # mocked suite
./tests/run-tests.sh --live   # + verify real deployment
```
