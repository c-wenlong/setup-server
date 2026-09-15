# metabase — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?              ->  publish?        ->  client?
docker ps          curl :8104                  serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/metabase
docker compose --project-directory . ps
curl -s http://127.0.0.1:8104/api/health
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 metabase
```

- **`METABASE_DB_PASSWORD missing from .env`** — `.env` is incomplete.
  Move it aside and re-run `./setup.sh`.
- **Exit 137 (OOM-killed)** — JVM. Cap is 1536 MiB / `-Xmx1g`. Unload
  ollama, or bump `METABASE_MEM_LIMIT` / `METABASE_JAVA_OPTS` and re-run.
- **Migrations hang** — Postgres not healthy. `docker compose logs db`.
  First boot of Metabase can take a few minutes.

## Local `/api/health` fails but the container says "running"

First boot is a JVM start plus Liquibase.

- Check the port is on loopback: `ss -ltn | grep 8104`. `127.0.0.1:8104`
  is Metabase; the tailnet address is **tailscaled's** Serve frontend.
  `0.0.0.0:8104` is the one that would be wrong.
- `{"status":"ok"}` is the healthy body. HTML means the probe hit the UI.

## Setup wizard still showing / cannot log in

`POST /api/setup` is what seeds `MB_ADMIN_*`. If it failed, setup.sh
warned. Complete the wizard in the browser with that email, or:

```bash
curl -s http://127.0.0.1:8104/api/session/properties | grep setup-token
```

Changing `MB_ADMIN_PASSWORD` in `.env` after first boot does not rotate
the live password — do that in the UI.

## UI loads, reset links point at localhost

`MB_SITE_URL` in `.env` must be the tailnet HTTPS URL, no trailing
slash. Drift is warned on every `./setup.sh` run; the file is not
rewritten.

## Nuke and pave

Stops the stack, deletes data, keeps `.env` unless you remove it too.
There is no undo.

```bash
cd ~/dev/setup-server/metabase
docker compose --project-directory . down -v
rm -rf ~/services/metabase
# optional: rm .env
./setup.sh
```
