# hermes-agent — Nous Research's self-improving AI agent

An autonomous agent that keeps its own sessions, skills, memories and
scheduled jobs, with a web dashboard on the tailnet at
`https://homeserver.tail-name.ts.net:9119` and a key-gated
OpenAI-compatible API on loopback `:8642` for other services on this box.

**This is not the Hermes you may already have.** If a native install lives
at `~/.hermes` (or a `hermes-gateway.service` systemd unit is running), this
container does not touch it: separate data dir, separate config, separate
channels, separate ports. They coexist; each needs its own channels and
model keys configured.

## Architecture

One container, two surfaces:

```
  phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:9119
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:9119        ┌── loopback only ──┐
            ▼                               │ http://127.0.0.1  │
   ┌─────────────────────────────────┐      │        :8642      │
   │ container: hermes-agent         │ ◄─────┘  other services   │
   │   nousresearch/hermes-agent     │        on this box (Open  │
   │   :v0.22.5                      │        WebUI, n8n) talk   │
   │                                 │        to the API with    │
   │   s6 supervision tree:          │        API_SERVER_KEY     │
   │     gateway run                 │                         │
   │     web dashboard    :9119      └─────────────────────────┘
   │     API server       :8642
   └────────────┬────────────────────┘
                │ bind mount
                ▼
   ~/services/hermes-agent/data → /opt/data
     config.yaml, API keys, sessions/, skills/, memories/, logs
```

Upstream's compose uses `network_mode: host` and a separate dashboard
container; here the two ports that matter are published on `127.0.0.1` over
a bridge network, and the dashboard runs inside the same container under s6
(`HERMES_DASHBOARD=1`). Nothing listens on the LAN.

## Security model

- Both ports publish on `127.0.0.1` only; the tailnet is the security
  boundary. Upstream's `network_mode: host` is deliberately not used.
- Remote access is `tailscale serve` on the dashboard port only. The API
  port is **not** Serve-published — it exists for other services on this
  box (Open WebUI, n8n) and is key-gated (`API_SERVER_KEY`).
- The dashboard sits behind HTTP Basic auth (username + generated password
  in `.env`). Hermes requires an auth provider once it binds non-loopback;
  the tailnet is still the real boundary and basic auth is the second gate
  over the keys stored in the UI.
- `.env` (mode 600) holds `HERMES_DASHBOARD_PASSWORD`,
  `HERMES_DASHBOARD_SECRET` (session signing) and `API_SERVER_KEY`, all
  generated 32-hex values on first run.
- `HERMES_UID`/`HERMES_GID` remap the container's internal `hermes` user
  onto your ids, so `/opt/data` stays readable/writable from the host.

## Dependencies

| Needs | Why |
|---|---|
| Linux or macOS | anything else dies in preflight |
| `curl` | health checks (dashboard probe is authenticated) |
| Docker + Compose v2 | the gateway runs in a container |
| Tailscale logged in | MagicDNS name + Serve publish |
| sudo | at most once: `tailscale set --operator` on Linux |

## What setup.sh does

1. Preflight: non-root user, curl, Docker daemon reachable, Compose v2,
   Tailscale up, numeric ports, MagicDNS hostname.
2. Reports (and leaves alone) a native `~/.hermes`, a `hermes` CLI or a
   `hermes-gateway.service` unit — this deploy shares nothing with them.
3. Writes `.env` (mode 600) if absent: image tag, ports, `HERMES_DATA`,
   your uid/gid, dashboard credentials, `API_SERVER_KEY`. An existing
   `.env` is the source of truth and is never overwritten — port overrides
   after that are reported and ignored.
4. Creates `~/services/hermes-agent/data`.
5. `docker compose up -d`, then waits for the dashboard on `:9119` **with
   the basic-auth credentials** (anonymous sees a 401) and for the API on
   `:8642/health`.
6. `tailscale serve --bg --https=<HTTPS_PORT> http://127.0.0.1:<LOCAL_PORT>`
   — the API port is never published.
7. End-to-end HTTPS check (authenticated) on the tailnet URL.

## Deploy

```bash
cd services/hermes-agent
./setup.sh                                # dashboard :9119, API :8642
LOCAL_PORT=9120 ./setup.sh                # HTTPS port follows LOCAL_PORT
API_PORT=8643 HTTPS_PORT=8443 ./setup.sh
```

An explicit `HTTPS_PORT` is recorded in `.env` (delete that line to resume
following `LOCAL_PORT`); the launcher tile reads `.env` for its link, so it
always points at the real publish port.

Re-running is safe: it reuses `.env` and re-applies the Serve mapping.

## Client side

Open `https://<host>.<tailnet>.ts.net:9119` on a tailnet device; the browser
asks for HTTP Basic credentials — `HERMES_DASHBOARD_USERNAME` /
`HERMES_DASHBOARD_PASSWORD` in `services/hermes-agent/.env`.

First boot has no model or channels configured. In the dashboard, or:

```bash
docker exec -it hermes-agent hermes model    # pick a provider + model
docker exec -it hermes-agent hermes setup    # full wizard (keys, channels)
```

The loopback API for other services:

```bash
curl http://127.0.0.1:8642/v1/models -H "Authorization: Bearer $API_SERVER_KEY"
```

## Ops

```bash
cd services/hermes-agent
docker compose ps                 # container state
docker compose logs -f gateway    # logs
docker compose restart
docker compose pull && ./setup.sh # upgrade to HERMES_VERSION
./teardown.sh                     # unpublish + remove container (keeps data)
./teardown.sh --purge             # also deletes the data dir + .env
```

## Tests

`./tests/run-tests.sh` — 213-check mocked suite (stubbed docker/tailscale/
curl/sudo, including the basic-auth 401 path). `./tests/run-tests.sh --live`
additionally verifies the real deployment on this box, including that the
native `hermes-gateway.service` (when present) is still running.

## Notes

- `/opt/data` is the only backup target; the container is disposable.
- The compose `healthcheck` probes the API `/health` endpoint, which needs
  no key — that is also what Uptime Kuma watches.
- Host networking stays off. If a channel ever needs a host-visible port,
  publish it on `127.0.0.1` (or the tailnet IP) explicitly, never `host`.
