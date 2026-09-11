# Monitoring — Troubleshooting

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/   # 302 = Kuma up
curl -s http://127.0.0.1:3003/v1/health                           # {"healthy":true}
tailscale serve status                      # :3002 and :3003 mapped?
./tests/run-tests.sh --live
```

Kuma's `/` is a 302 to the login page — that is healthy. Don't use `curl -fsS`
on it and expect output; `-f` passes a 302 silently, so you learn nothing.

If `docker` says "permission denied", you are not in the docker group in
*this shell*: re-run as `sg docker -c './tests/run-tests.sh --live'`. This
live suite does not detect the missing group for you — both container checks
just go red on a perfectly healthy stack.

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

- Kuma probes the **tailnet HTTPS URL**, so a red monitor can mean the app is
  down *or* that publishing is. Check which: `curl` the app's loopback port
  directly — if that answers, the app is fine and the fault is in Tailscale
  Serve (`tailscale serve status`) or the cert.
- **Everything red at once** is the signature of a tailscaled/Serve problem,
  not a dozen simultaneous app failures. Start with `tailscale serve status`.
  The one monitor that would stay green is `ollama`, because it is the only
  one still on loopback — everything green except ollama, or ollama alone
  green, both point at the publish layer rather than at the apps.

  ⚠️ **Do not "fix" it with `tailscale serve reset`.** That wipes the serve
  config for the *whole node* — every service on the box goes dark at once,
  and each one's `setup.sh` has to be re-run to republish it. This trap is
  easy to fall into because `reset` is one of only two removal commands the
  `tailscale serve --help` text advertises (the other, `clear`, is for
  Tailscale Services, not this).

  To remove **one** mapping, use the legacy-but-working form:

  ```sh
  tailscale serve --https=<port> off      # e.g. --https=3002 off
  ```

  `off` is absent from `--help` on 1.102.3 (re-checked on this box: the only
  removals it lists are `reset` and `clear`), but it is what Tailscale itself
  prints after a successful `serve` ("To disable the proxy, run: …"), and it
  is verified working here. It is the only removal that touches a single port
  instead of all of them.

  ⚠️ `:443` is the one port where even the single-port form is dangerous:
  it hosts **two** mounts, code-server at `/` and the launcher at `/home/`.
  A bare `tailscale serve --https=443 …` replaces the `/` handler and takes
  code-server down; `--https=443 off` removes the whole port. Neither is what
  you want when only one of the two is broken.
- Confirm the monitor's HTTPS port matches the service's published port
  (they can drift if you redeployed a service on a new port); re-running
  `monitoring/setup.sh` repoints monitors to whatever `seed_kuma.py` says.
  The repoint writes **only the URL**, so a paused monitor stays paused and a
  hand-tuned interval survives — re-seeding is safe on a live dashboard.
- `seafile` probes `/api2/ping/` **with the trailing slash** — `/api2/ping`
  returns a 301 to it, and plain `/` returns a 302 which Kuma counts as down.
  (Verified on the box: `301`, `200 "pong"`, `302` respectively.)
- ollama is the one monitor still on loopback (never published via Serve).
- **A monitor is red and the service is genuinely stopped, on purpose** —
  `kaichenpedia` and `n8n` are intentionally down (their Kuma monitors were
  paused when they were stopped). "Not running" is not automatically a fault;
  check DIRECTORY.md's loose-ends list before chasing one.

## Seeding failed

- `uv` missing → install uv, re-run `./setup.sh` (idempotent). Missing `uv` is
  a warning, not a failure: the deploy still publishes, it just skips seeding.
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
rm -rf ~/services/monitoring .env
./setup.sh
```

State is `~/services/monitoring/kuma` and `~/services/monitoring/ntfy`
(`KUMA_VOLUME` / `NTFY_VOLUME` in `.env`) — not `~/monitoring`, which was the
pre-2026-09-07 layout and no longer exists.

Deliberately **not** in that list: `tailscale serve --https=3002 off` and
`--https=3003 off`. `setup.sh` re-publishes both, and leaving them up means
the dashboard comes back the moment the containers do.
