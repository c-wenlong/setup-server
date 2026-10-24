# n8n — Troubleshooting

**Before anything else: n8n is intentionally stopped on this box** (since
2026-09-08, via ntfy-control; its Kuma monitor is paused and the launcher
shows it as an amber "Paused" tile). "Container not running", "connection
refused on :5678" and "no Kuma data" are all the expected state, not a fault.
Start it with the ntfy panel, the launcher's start button, or
`docker start n8n`. Scheduled workflows do not run while it is down.

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps
curl -fsS http://127.0.0.1:5678/healthz         # liveness
curl -fsS http://127.0.0.1:5678/rest/settings   # REST API readiness
tailscale serve status                          # :5678 -> 127.0.0.1:5678
./tests/run-tests.sh --live
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` will
report a healthy container as not running. Re-run under
`sg docker -c './tests/run-tests.sh --live'`.

The Tailscale Serve mapping stays in place while the container is stopped, so
`tailscale serve status` showing `:5678` proves nothing about the app.

## Container up but UI won't load / 503

- First boot runs DB migrations — `/healthz` answers before the app is
  actually ready. Wait a minute; watch
  `docker compose --project-directory . logs -f n8n` for
  "Editor is now accessible".

## Can't log in

- Credentials are in `.env` (`OWNER_EMAIL` / `OWNER_PASSWORD`). Reminder:
  editing `.env` after setup does NOT change the live account — same
  lesson as Kuma. Change password in the UI (Settings → Personal), then
  mirror it into `.env`.
- Nuclear option: `docker exec -it n8n n8n user-management:reset` wipes
  user accounts back to setup state (workflows survive), then re-run
  `./setup.sh` to re-seed.

## Owner seeding failed during setup

- "n8n is starting up. Please wait" — API wasn't ready; just re-run
  `./setup.sh` (idempotent).
- "Cannot POST /rest/owner/setup" — missing `browser-id` header (n8n 2.x
  rejects browserless POSTs); the script sends it, but if you're seeding
  manually: `curl -X POST http://127.0.0.1:5678/rest/owner/setup -H
  'Content-Type: application/json' -H 'browser-id: manual' -d '{...}'`
- Password policy rejection — needs ≥8 chars, a number, AND a capital.

## Webhooks don't fire

- Webhook URLs are tailnet-only (`https://<host>:5678/webhook/...`) —
  reachable from your devices, NOT from the public internet. GitHub/Stripe/
  etc. cannot call them. Exposing them publicly would need Tailscale
  Funnel — a deliberate decision, don't do it casually.
- Test webhooks ("Listen for test event") use a different path than
  production; make sure the workflow is activated for production URLs.

## Credentials broken after moving/restoring data

- Workflow credentials are encrypted with `N8N_ENCRYPTION_KEY`. If the key
  in `.env` doesn't match the one the data was written with, every stored
  credential is unreadable. Always restore `~/services/n8n/data` and `.env`
  as a pair.

## Kuma says n8n is down

- Expected while it is deliberately stopped (top of this file) — and the
  monitor should be *paused*, not red. A red monitor means someone stopped
  the container without going through ntfy-control or the launcher, which is
  what does the pausing.
- Otherwise: the monitor probes the **tailnet** URL
  (`https://…:5678/healthz`), not loopback, so it also goes red when
  publishing is broken and the app is fine. Curl
  `http://127.0.0.1:5678/healthz` first — if that answers, the fault is
  Tailscale Serve or the cert. Everything red at once is tailscaled, not
  every service failing at the same moment.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — you are not the tailscaled
  operator: `sudo tailscale set --operator=$USER`, then re-run `./setup.sh`.
- **Re-adding the mapping by hand**:
  `tailscale serve --bg --https=5678 http://127.0.0.1:5678`
- ⚠️ **Never `tailscale serve reset`** to clear a bad mapping. It wipes the
  serve config for the whole node — every published service dark at once, each
  one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=5678 off`. `off` is absent from
  `tailscale serve --help` on 1.102.3 (which only advertises `reset` and
  `clear`) but is what Tailscale prints after a successful serve, and is
  verified working here.

## Nuke and pave (--purge destroys workflows + credentials)

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, runs `compose down`, and refuses to delete a
data dir that is not really inside `~/services/`.

```bash
cd ~/dev/setup-server/services/n8n
./teardown.sh            # remove, keep data + .env (the launcher's Remove)
./teardown.sh --purge    # also delete N8N_VOLUME and .env; type "n8n"
./setup.sh               # back, fresh if you purged
```

There is no undo for `--purge`. It deletes the workflows and the
`N8N_ENCRYPTION_KEY` in `.env`, so every saved credential is unrecoverable:
back up `.env` and the data dir first if you might want them. From a
terminal, pause the `n8n` monitor in Uptime Kuma first, or it pages; the
launcher's Remove does that.
