# appflowy — Troubleshooting

Triage in layers, outermost failure first:

```
containers up?  ->  local API?         ->  publish?        ->  client?
docker ps           curl :8102             serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/appflowy
docker compose --project-directory . ps
curl -s http://127.0.0.1:8102/api/health
curl -s http://127.0.0.1:8102/gotrue/health
curl -s http://127.0.0.1:8102/gotrue/settings
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Containers won't start / keep restarting

```bash
docker compose --project-directory . logs --tail=100
```

- **`APPFLOWY_DATA missing from .env` / `variable is not set`** — `.env`
  is incomplete. `docker compose --project-directory . config` shows
  which `${…:?}` guard fired. Do not hand-write a partial `.env`; move
  it aside and re-run `./setup.sh` (that writes a new one — existing
  passwords would be lost, so copy secrets out first).
- **GoTrue `relation "identities" does not exist`** — `GOTRUE_DATABASE_URL`
  must end with `?search_path=auth`. Without it, migrations land in the
  `auth` schema and the admin seed queries `public`. Fix the URL, then
  `docker compose down` and `docker volume rm appflowy-postgres` (destroys
  the database) before `./setup.sh`.
- **Postgres `pg_isready` never succeeds** — `POSTGRES_USER` /
  `POSTGRES_PASSWORD` in `.env` must match the volume. A regenerated
  `.env` against an old `appflowy-postgres` volume will auth-fail
  forever. Either put the old password back or `docker volume rm
  appflowy-postgres`.
- **Permission errors under `/var/lib/postgresql/data` or `/data`** —
  should not happen; those are named volumes. If you switched them to
  bind mounts, the image uids cannot write a host-owned directory
  without a sudo chown — put the named volumes back.
- **GoTrue / cloud healthcheck never succeeds** — they curl
  `127.0.0.1` inside the container. If the image is too old to ship
  `curl`, the probe fails forever even though the process is up. Pins
  in `.env` are `0.18.x` images that do ship it.
- **Exit 137 (OOM-killed)** — ollama with a model loaded claims ~5 GB.
  `docker stats` and `free -h`. Caps in compose sum to ~2 GB worst
  case; if a container is still the victim, stop another service first.
  Do **not** add the AI or search containers on this box.

## Local `/api/health` fails but containers say "running"

First boot runs migrations and can take several minutes.
`docker compose --project-directory . logs -f appflowy_cloud` shows
progress.

- Check the port is on loopback: `ss -ltn | grep 8102`. `127.0.0.1:8102`
  is nginx; the tailnet address is **tailscaled's** Serve frontend.
  `0.0.0.0:8102` is the one that would be wrong.
- nginx 502: a backend is not up yet. `docker compose ps` — cloud,
  gotrue and web should be running. `docker compose logs nginx`.
- `/api/health` 200 with a broken web UI usually means
  `APPFLOWY_BASE_URL` / `APPFLOWY_WEBSOCKET_BASE_URL` point at the
  wrong origin (missing port, `http://`, trailing slash). Drift is
  warned on every `./setup.sh` run; the file is not rewritten.

## Web UI loads, login cookies / websockets are wrong

- `APPFLOWY_BASE_URL` and `APPFLOWY_WEB_URL` must be the tailnet HTTPS
  URL, port included, no trailing slash.
- `API_EXTERNAL_URL` must be that same origin plus `/gotrue`.
- `APPFLOWY_WEBSOCKET_BASE_URL` must be `wss://<host>:<port>/ws/v2`.
- `APPFLOWY_S3_PRESIGNED_URL_ENDPOINT` must be
  `https://<host>:<port>/minio-api`. File uploads fail with a console
  error about MinIO if this is still `http://minio:9000`.
- Hard-refresh. The web image inlines the base URL at container start.

## `/gotrue/settings` says `disable_signup: false`

**Treat this as an incident.** Anyone on the tailnet can create an
account.

`GOTRUE_DISABLE_SIGNUP=true` in `.env` is what GoTrue reads. Confirm
the container sees it:

```bash
docker compose --project-directory . exec gotrue \
  printenv GOTRUE_DISABLE_SIGNUP
```

If that is empty or `false`, the env file was edited after first boot
without a recreate: `docker compose --project-directory . up -d
--force-recreate gotrue`.

## Desktop app cannot connect

The cloud URL in the app must be the **HTTPS Serve URL including the
port** (`https://kai-home-server.taild6a23f.ts.net:8102`), not
`http://127.0.0.1:8102` and not the origin without a port. The phone
or laptop must be on the tailnet.

## File uploads fail, editing works

MinIO is up (`docker inspect -f '{{.State.Health.Status}}'
appflowy-minio`) but the browser cannot PUT to a presigned URL that
points at `http://minio:9000`. Fix
`APPFLOWY_S3_PRESIGNED_URL_ENDPOINT` (see above) and recreate
`appflowy_cloud`.

## Nuke and pave

Stops the stack, deletes data, keeps `.env` unless you remove it too.
There is no undo.

```bash
cd ~/dev/setup-server/services/appflowy
docker compose --project-directory . down
docker volume rm appflowy-postgres appflowy-redis appflowy-minio
rm -rf ~/services/appflowy
# optional: rm .env          # new passwords, new JWT
./setup.sh
```
