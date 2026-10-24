# trigger-dev — Troubleshooting

Triage in layers, outermost failure first:

```
containers up?  ->  local API?              ->  publish?        ->  client?
docker ps           curl :8030/healthcheck      serve status        browser / CLI
```

Quick triage:

```bash
cd ~/dev/setup-server/services/trigger-dev
docker compose --project-directory . ps
curl -s http://127.0.0.1:8030/healthcheck
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Containers won't start / keep restarting

```bash
docker compose --project-directory . logs --tail=100 webapp
docker compose --project-directory . logs --tail=100 supervisor
```

- **`variable is not set` / `:?` guard** — `.env` is incomplete. Check
  with `docker compose --project-directory . config`. The file is
  generated once; do not delete individual keys.
- **Exit 137 (OOM-killed)** — expected risk on this box. Official wants
  6+8 GB; we cap the webapp at 1g and Node at 768 MiB. `docker stats`
  and `free -h`. Unload ollama (`systemctl --user stop` is not enough —
  it is a system unit) or stop Immich/OpenHands before retrying.
  `NODE_MAX_OLD_SPACE_SIZE` in `.env` must stay below `WEBAPP_MEM_LIMIT`.
- **webapp crash-loops mentioning ClickHouse** — this compose does not
  run ClickHouse. `RUN_REPLICATION_ENABLED` must be `0` and
  `EVENT_REPOSITORY_DEFAULT_STORE` must be `postgres` (both set in
  `docker-compose.yml`). A leftover `CLICKHOUSE_URL` in `.env` would
  send it looking for a host that is not there — remove it.
- **postgres `data directory has wrong ownership`** — the bind mount at
  `TRIGGER_POSTGRES` was created as the wrong user. Fix:
  `sudo chown -R $(id -u):$(id -g) ~/services/trigger-dev/postgres`
  only if you created it with sudo; otherwise just recreate the empty
  dir and let the image initdb.
- **supervisor: worker token file missing** — webapp bootstrap writes
  `~/services/trigger-dev/shared/worker_token`. If that file is empty,
  `docker logs trigger-webapp` for the "Trigger.dev Bootstrap - Worker
  Token" banner. Restart webapp, then supervisor:
  `docker compose --project-directory . restart webapp supervisor`.

## Local `/healthcheck` fails but containers say "running"

First boot runs Prisma migrations and can take a few minutes.

- Confirm the bind: `ss -ltn | grep 8030`. Two (or three) lines are
  expected — `127.0.0.1:8030` is the webapp, and the tailnet v4/v6
  addresses are **tailscaled's** Serve frontend (HTTPS port == local
  port). `0.0.0.0:8030` is the one that would be wrong.
- Electric is optional for `/healthcheck`. A red Electric container
  makes the dashboard less live; it should not take the health
  endpoint down.
- **MinIO `Permission denied` on `/bitnami/minio/data/.root_user`** —
  Bitnami MinIO runs as uid 1001 and cannot write a host-owned bind
  mount. `setup.sh` `chmod 0777`s `TRIGGER_MINIO` for that reason.
  If you created the dir some other way: `chmod 0777 ~/services/trigger-dev/minio`
  then `docker compose --project-directory . up -d`.
- MinIO must be healthy before the webapp is useful for deploys.
  `docker logs trigger-minio` — the `packets` bucket is created by
  `MINIO_DEFAULT_BUCKETS`.

## Dashboard loads, login does nothing / no email arrives

There is no SMTP. Magic links are printed to the webapp container:

```bash
docker logs trigger-webapp 2>&1 | grep -i magic
```

Then:

```bash
curl -sS -X POST http://127.0.0.1:8030/login/magic \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'action=send' \
  --data-urlencode "email=$(sed -n 's/^ADMIN_EMAIL=//p' .env)"
```

- **"This email is unauthorized"** — `WHITELISTED_EMAILS` in `.env`
  does not match what you typed. The regex is anchored. Edit `.env`
  and `docker compose --project-directory . up -d` (the webapp reads
  env on start).
- **Rate limited** — wait a minute. `LOGIN_RATE_LIMITS_ENABLED` is on.
- **Magic link points at localhost / the old host** — the link is minted
  from the request Host. `setup.sh` POSTs after Serve and rewrites a
  leftover `127.0.0.1` URL to the tailnet origin. If you requested one
  by hand against loopback, swap the host for the tailnet URL (same
  token). `APP_ORIGIN` / `LOGIN_ORIGIN` / `API_ORIGIN` drift is the
  other cause: setup.sh warns and will not rewrite `.env`. Set all
  three to `https://<this-box>.ts.net:8030` and recreate the webapp.

## `npx trigger.dev deploy` fails at push

The registry is `127.0.0.1:5000` on **this** box.

```bash
docker login -u registry-user localhost:5000   # password: DOCKER_REGISTRY_PASSWORD in .env
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5000/v2/
```

- Deploying from a laptop will not work: 5000 is not on the tailnet.
  Run deploy from this box, or from code-server.
- `unauthorized` — htpasswd does not match `.env`. Delete
  `~/services/trigger-dev/registry/auth.htpasswd` and re-run
  `./setup.sh` (it rewrites the file only when absent).
- CLI / platform mismatch — `npx trigger.dev@4.6.0` against
  `TRIGGER_IMAGE_TAG=v4.6.0`. Mixing lines produces opaque schema
  errors.

## Supervisor up, tasks never run

```bash
docker logs trigger-supervisor --tail=80
cat ~/services/trigger-dev/shared/worker_token
```

- Token file empty or "invalid token" — bootstrap already printed it
  once. The file on the shared volume is what the supervisor reads
  (`TRIGGER_WORKER_TOKEN=file:///home/node/shared/worker_token`).
  Do not paste a different group token unless you created one in the
  admin API.
- Runner cannot pull `localhost:5000/...` — host dockerd pulls that,
  so `docker login localhost:5000` on the host must have succeeded.
  setup.sh does this; a new shell does not need to repeat it (the
  creds live in `~/.docker/config.json`).
- Task OOMs — default machine is `micro` (256 MB). Override per task
  or raise the preset in `machine-presets.json` and recreate the
  webapp. Stay under what this box actually has free.

## Serve / HTTPS

Same recipe as every other service:

- `tailscale serve status` should show `:8030 -> http://127.0.0.1:8030`.
- Direct serve denied on Linux: `sudo tailscale set --operator=$USER`,
  then re-run `./setup.sh`.
- Approval URL: open it, press Enter at the prompt, the script retries.
- Cert still minting: `curl https://<host>.ts.net:8030/healthcheck`
  can take a minute the first time.

## Nuke and pave

This deletes the database, the registry, and every deployed task
image. The `.env` secrets stay, so a new stack can decrypt nothing
that was in the old volumes — that is fine, they will be empty.

```bash
cd ~/dev/setup-server/services/trigger-dev
docker compose --project-directory . down
rm -rf ~/services/trigger-dev
# keep .env (origins + secrets) unless you also want new passwords:
# rm -f .env
./setup.sh
```

To rotate only the registry password: delete
`~/services/trigger-dev/registry/auth.htpasswd`, change
`DOCKER_REGISTRY_PASSWORD` in `.env`, re-run `./setup.sh`, then
`docker login -u registry-user localhost:5000` again.
