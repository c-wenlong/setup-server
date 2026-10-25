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

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, runs `compose down`, and refuses to delete a
marker dir that is not really inside `~/services/plane`.

```bash
cd ~/dev/setup-server/services/plane
./teardown.sh            # remove, keep the volumes + .env (the launcher's Remove)
./teardown.sh --purge    # also drop every plane_* volume, PLANE_DATA and .env; type the name
./setup.sh               # back, fresh if you purged
```

The live data is in the named volumes of compose project `plane` (fixed by
`name: plane` in the compose file): `plane_pgdata` (every workspace, issue
and user), `plane_uploads` (MinIO attachments), plus Valkey, RabbitMQ, proxy
and log volumes. `PLANE_DATA` (`~/services/plane`) is only a marker dir.
Plain `teardown.sh` keeps the volumes; `--purge` runs `down -v`. The `.env`
holds the generated DB, MinIO and admin secrets, so a purge removes it and
the next `./setup.sh` seeds a new admin. Teardown refuses to run if
`COMPOSE_PROJECT_NAME`, `COMPOSE_FILE` or `COMPOSE_PROFILES` is set. There
is no undo: dump Postgres first. From a terminal, pause the `plane` monitor
in Uptime Kuma first, or it pages; the launcher's Remove does that.
