# n8n — Troubleshooting

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps
curl -fsS http://127.0.0.1:5678/healthz         # liveness
curl -fsS http://127.0.0.1:5678/rest/settings   # REST API readiness
tailscale serve status                          # :5678 mapped?
./tests/run-tests.sh --live
```

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
  credential is unreadable. Always restore `~/n8n/data` and `.env` as a pair.

## Nuke and pave (destroys workflows + credentials)

```sh
docker compose --project-directory . down
rm -rf ~/n8n .env
./setup.sh
```
