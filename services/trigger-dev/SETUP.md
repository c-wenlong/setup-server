# trigger-dev — background jobs and cron (Trigger.dev v4)

TypeScript tasks with cron schedules, retries and a dashboard, on the
tailnet: `https://homeserver.tail-name.ts.net:8030`.

This is the job runner next to [n8n](../n8n/). n8n is visual workflows
that call other services; Trigger.dev is code you write (`schedules.task`,
`task()`) and deploy with the CLI. They overlap on "run something every
hour" and nothing else.

Chosen over running cron on the box, over n8n's cron node (already
here, often stopped), and over the cloud product: the tasks live next
to the rest of this server, and the dashboard is tailnet-only.

⚠️ **This stack is too heavy for this box.** Measured idle on
2026-09-15: **~1.9 GB** across nine containers (webapp ~860 MiB, then
Electric, MinIO, ClickHouse, supervisor, Postgres). The launcher sums
every `control` part, so the tile reads **~2 GB**. Official self-host
wants 6 GB + 8 GB; this deploy is already the slim cut (768 MiB Node
heap, no s2-lite, ClickHouse present only because v4.6.0 will not boot
without `CLICKHOUSE_URL`). On 7.7 GB with ollama and the rest, that is
still too much. **Stopped 2026-09-15 for that reason.** Prefer
[n8n](../n8n/) for cron and workflows here. Do not start this again
unless the box has a lot more RAM.

## Architecture

A combined webapp + supervisor stack. s2-lite is omitted. ClickHouse
runs because v4.6.0 refuses to boot without `CLICKHOUSE_URL`, but
events still live in Postgres (`RUN_REPLICATION_ENABLED=0`).

```
  phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:8030
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8030
            ▼
   ┌─────────────────────────────────────────────┐
   │ trigger-webapp     :3000 in-container       │
   │   dashboard + API + bootstrap               │
   └──────┬──────────────┬──────────────┬────────┘
          │              │              │
          ▼              ▼              ▼
   postgres:14      redis:7         minio (packets)
   electric         (streams v1)    registry :5000
   clickhouse                       (127.0.0.1 only)
   (boot only; events stay in Postgres)
          │
          ▼
   trigger-supervisor  ──docker-proxy──▶ host dockerd
        (runs your task containers on trigger-webapp /
         trigger-supervisor networks)
```

State lives under `~/services/trigger-dev`:

```
~/services/trigger-dev/
  shared/worker_token    # bootstrap worker group token (shown once in logs)
  postgres/              # the instance database
  redis/
  minio/                 # large payloads / outputs (mode 777: Bitnami uid 1001)
  registry/
    data/                # deployed task images
    auth.htpasswd        # bcrypt for registry-user
  .magic-link-requested  # marker: first login email already POSTed
```

Nothing here is published except:

| Host bind | What |
|---|---|
| `127.0.0.1:8030` | dashboard / API (Serve fronts HTTPS :8030) |
| `127.0.0.1:5000` | local image registry, for `npx trigger.dev deploy` **on this box** |

Postgres, Redis, Electric, MinIO and the docker socket proxy have no
host ports.

## Why this is slimmer than upstream

Official Docker self-hosting
(https://trigger.dev/docs/self-hosting/docker) asks for **6 GB** for
the webapp machine and **8 GB** for a worker, and ships ClickHouse +
s2-lite. This box already swaps. The cuts:

| Upstream | Here | Why |
|---|---|---|
| ClickHouse as event store | present, unpublished, unused for events | v4.6.0 Zod-requires `CLICKHOUSE_URL` at boot; `EVENT_REPOSITORY_DEFAULT_STORE=postgres` and `RUN_REPLICATION_ENABLED=0` |
| s2-lite (realtime v2) | omitted | Redis-backed streams (`REALTIME_STREAMS_DEFAULT_VERSION=v1`) |
| `NODE_MAX_OLD_SPACE_SIZE=8192` | `768` | the image default would OOM the host; webapp `mem_limit` is 1g |
| concurrency 100 | 2 / org 6 | one user, cron, not a SaaS |
| default machine `small-1x` (0.5 GB) | `micro` (0.25 GB) | `machine-presets.json`; `small-2x` is capped at 0.75 GB |
| webapp on `0.0.0.0:8030` | `127.0.0.1` | tailnet is the security boundary |
| datastore ports on loopback | unpublished | nothing on this box talks to them from the host |

Idle ceiling with the `mem_limit`s is about 2.2 GB. A running task adds
whatever the machine preset says. Unload ollama if a deploy gets
OOM-killed.

## Why v4.6.0

`TRIGGER_IMAGE_TAG=v4.6.0` pins both `ghcr.io/triggerdotdev/trigger.dev`
and `ghcr.io/triggerdotdev/supervisor`. The CLI must match:

```
npx trigger.dev@4.6.0 login -a https://homeserver.tail-name.ts.net:8030
```

v3 is end of life. 4.5.0 was the last release that would run v3 tasks;
4.5.1+ reject them. There are no v3 tasks here, so 4.6.0 is the current
line. Bump the tag in `.env` and the CLI together, then
`docker compose pull && ./setup.sh`.

## Security model

- Dashboard binds `127.0.0.1` only. Tailscale Serve is the only way in.
- The registry binds `127.0.0.1:5000` only. It is **not** on the
  tailnet — `deploy` is meant to run on this box (or via code-server).
- Magic-link auth, no SMTP: links are printed to `docker logs trigger-webapp`.
- `WHITELISTED_EMAILS` / `ADMIN_EMAILS` are the admin address from
  `.env`. Nobody else can sign up; that first user is an admin.
- `TRIGGER_TELEMETRY_DISABLED=1`.
- Docker socket access is via `tecnativa/docker-socket-proxy` with
  CONTAINERS/IMAGES/NETWORKS/INFO only — same idea as upstream, not a
  raw socket mount on the webapp.

Login is **not** a substitute for the tailnet. Anyone on the tailnet
who can read the webapp logs can grab a magic link. That is the same
trust boundary as every other service here.

## Dependencies

| Need | Why |
|---|---|
| Docker + Compose v2 | the whole stack |
| Tailscale, logged in, MagicDNS on | Serve + `APP_ORIGIN` |
| curl | health checks and the magic-link POST |
| ~2 GB RAM free | first boot + idle. Tight on this box — see above |
| ~5 GB disk | images + Postgres + registry |

## What `setup.sh` does

1. Preflight: OS, not root, curl, Docker daemon, Compose v2, Tailscale
   running, numeric ports, MagicDNS name.
2. Write `.env` **only if absent** (secrets, origins, paths, whitelist).
3. Write `~/services/trigger-dev/registry/auth.htpasswd` only if absent
   (bcrypt via `htpasswd` or a one-shot `httpd:2` container).
4. `docker compose up -d`, wait on `http://127.0.0.1:LOCAL_PORT/healthcheck`.
5. Wait for the bootstrap worker token on the shared volume.
6. `docker login` the host daemon to `localhost:5000`.
7. Once: POST `/login/magic` for `ADMIN_EMAIL` and scrape the link from
   webapp logs.
8. `tailscale serve --bg --https=HTTPS_PORT http://127.0.0.1:LOCAL_PORT`
   (operator grant + approval-link loop, same as every other service).
9. HTTPS `/healthcheck`, then print the URL, the magic link, and the
   CLI commands.

Re-running upgrades/repairs. It never overwrites `.env` or the
htpasswd. A `LOCAL_PORT` override after first run is ignored — edit
`.env`. If `APP_ORIGIN` no longer matches this box, it warns and leaves
the file alone.

## Client-side setup

1. Open the URL printed by `setup.sh` (or the magic link).
2. First browser visit creates the admin from `ADMIN_EMAIL`.
3. In a project directory on this box (code-server is fine):

```
npx trigger.dev@4.6.0 login -a https://homeserver.tail-name.ts.net:8030
npx trigger.dev@4.6.0 init
npx trigger.dev@4.6.0 deploy
```

A scheduled task looks like:

```ts
import { schedules } from "@trigger.dev/sdk/v3";

export const nightly = schedules.task({
  id: "nightly-cron",
  cron: "0 2 * * *",
  run: async () => {
    // ...
  },
});
```

`dev` mode (`npx trigger.dev@4.6.0 dev`) runs tasks on the machine
where the CLI is, talking to this webapp. `deploy` builds an image,
pushes it to `localhost:5000`, and the supervisor runs it here.

Tasks that need other loopback services (ntfy :3003, ollama :11434)
will **not** reach them from a runner container on the compose bridge.
Call them via the tailnet URL, or add `network_mode` / extra_hosts
later. That is a documented gap, not a bug.

## Operations

```
D="--project-directory ~/dev/setup-server/services/trigger-dev"
docker compose $D ps|logs -f|restart|down
docker compose $D logs -f webapp          # magic links land here
docker compose $D pull && ./setup.sh      # after bumping TRIGGER_IMAGE_TAG
```

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes every Serve
port pointing at `:LOCAL_PORT` and runs `compose down`; data under
`~/services/trigger-dev` and `.env` stay, so `./setup.sh` brings it back. It
stops without changing anything if a task-runner container outside the
compose project is still on a `trigger-*` network, naming it. `./teardown.sh
--purge` also deletes the state setup.sh made (Postgres, ClickHouse, Redis,
MinIO, registry, shared worker token, magic-link marker) and `.env`, after
you type `trigger-dev`.

Kuma probes `/healthcheck` (services/monitoring/seed_kuma.py). Backup =
`~/services/trigger-dev` plus this directory's `.env`. Rotating
`ENCRYPTION_KEY` or `SESSION_SECRET` orphans data and sessions.

## Tests

```
./tests/run-tests.sh          # mocked suite
./tests/run-tests.sh --live   # + verify real deployment
```
