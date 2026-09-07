# Monitoring — Troubleshooting

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps
curl -fsS http://127.0.0.1:3002/            # Kuma up?
curl -fsS http://127.0.0.1:3003/v1/health   # ntfy up?
tailscale serve status                      # :3002 and :3003 mapped?
./tests/run-tests.sh --live
```

## No alert arrived on the phone but a service is down

Walk the chain backwards:

1. **Does Kuma see it as down?** Dashboard → the monitor should be red. If
   it's green, Kuma's probe target may not match the real failure (e.g. the
   container answers but the app is broken) — tighten the monitor (keyword
   checks, status codes).
2. **Did Kuma fire the notification?** Monitor → latest events show
   notification attempts. If not attached: monitor → Edit → Notifications →
   tick `ntfy-alerts`.
3. **Did ntfy get it?** Open `https://<host>:3003/alerts` in a browser and
   test: `curl -d test https://<host>:3003/alerts` — the message should
   appear live.
4. **Did the phone get it?** iOS instant delivery needs the upstream relay
   (`NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` in docker-compose.yml) and the
   phone needs the topic subscribed on the *self-hosted server* (not
   ntfy.sh). Also check iOS notification permissions for the ntfy app.

## Kuma monitor shows down but the service is fine

- Kuma probes `127.0.0.1:<port>` from the host network — confirm the port in
  the monitor matches the service's actual LOCAL_PORT (they can drift if you
  redeployed a service on a new port).
- `seafile` probe uses `/api2/ping` (returns 200); plain `/` returns a 302
  which Kuma counts as down by default.

## Seeding failed

- `uv` missing → install uv, re-run `./setup.sh` (idempotent).
- `uptime-kuma-api` errors → the Kuma image was probably bumped to 2.x;
  pin back to `louislam/uptime-kuma:1.23.16` in `.env`, or configure by hand
  in the UI and ignore seeding.
- Partial seed is safe to re-run: it skips existing account/notification/monitors.

## Lost the Kuma admin password

It's in `.env` (`KUMA_ADMIN_PASSWORD`). If `.env` is gone too:
`docker exec -it uptime-kuma node extra/reset-password.js`

## Containers / ports

- Host networking means port conflicts are with the host directly:
  `ss -ltnp | grep -E ':(3002|3003)'`. Change `KUMA_PORT`/`NTFY_PORT` in
  `.env`, `docker compose up -d`, then re-run the two
  `tailscale serve --bg --https=<port> http://127.0.0.1:<port>` mappings.
- Expected listeners per port: `127.0.0.1:<port>` (the app) plus the tailnet
  IP `100.x.y.z:<port>` (tailscaled's serve frontend). A `0.0.0.0` listener
  is wrong — check the compose env bindings.

## Nuke and pave (destroys monitor history + accounts)

```sh
docker compose --project-directory . down
rm -rf ~/monitoring .env
./setup.sh
```
