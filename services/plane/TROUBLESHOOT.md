# plane — Troubleshooting

Triage in layers, outermost failure first:

```
containers up?  ->  local API?             ->  publish?        ->  client?
docker ps           curl :8105                 serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/plane
docker compose --project-directory . ps
curl -s http://127.0.0.1:8105/api/instances/
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100
docker compose --project-directory . logs migrator
```

- **`SECRET_KEY missing from .env`** — `.env` is incomplete. Move it
  aside and re-run `./setup.sh`.
- **api never starts** — it waits on `migrator` (`service_completed_successfully`).
  If migrator exited non-zero, api will sit at "Created". Fix migrator
  first; do not `up -d --no-deps api`.
- **Exit 137 (OOM-killed)** — eleven containers. Unload ollama / Immich
  ML. Caps are in `.env` (`PLANE_*_MEM_LIMIT`).
- **MinIO pull fails** — we use `quay.io/minio/minio`, not Docker Hub.

## Local `/api/instances/` fails but proxy says "running"

First boot is migrator + Gunicorn. Several minutes is normal.

- Check the port is on loopback: `ss -ltn | grep 8105`. `127.0.0.1:8105`
  is the proxy; `0.0.0.0:8105` is the one that would be wrong.
- CORS errors in the browser: `WEB_URL` and `CORS_ALLOWED_ORIGINS` in
  `.env` must be the tailnet HTTPS URL, no trailing slash. Drift is
  warned on every `./setup.sh` run; the file is not rewritten.

## God Mode / first admin

If setup.sh warned that sign-up returned non-200, open
`https://<host>:8105/god-mode` and create the admin with
`PLANE_ADMIN_EMAIL` from `.env`. Do **not** POST `is_telemetry_enabled`
as a form field (makeplane/plane#9370) — if you already did, the
recovery is `UPDATE instances SET is_setup_done = true;` in Postgres.

Changing `PLANE_ADMIN_PASSWORD` in `.env` after first boot does not
rotate the live password.

## Mixed content / assets on http://

The proxy is HTTP-only on purpose. Serve must send
`X-Forwarded-Proto: https`. If the UI still emits `http://` links,
`WEB_URL` is wrong.

## Nuke and pave

Stops the stack, deletes named volumes, keeps `.env` unless you remove
it too. There is no undo.

```bash
cd ~/dev/setup-server/services/plane
docker compose --project-directory . down -v
rm -rf ~/services/plane
# optional: rm .env
./setup.sh
```
