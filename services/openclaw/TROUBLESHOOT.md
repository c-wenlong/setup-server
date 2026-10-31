# openclaw — Troubleshooting

Work the layers in order: container → local HTTP → Serve publish → client.
Each section names the layer it belongs to.

## Container won't start / keeps restarting

```bash
docker compose --project-directory services/openclaw ps
docker compose --project-directory services/openclaw logs openclaw-gateway
```

- **`OPENCLAW_GATEWAY_TOKEN missing from .env`** — `.env` is incomplete or a
  stale copy. Re-run `./setup.sh`; it fills the file only when absent, so a
  hand-emptied file needs the key added back.
- **port 18789 already in use** — something else claimed the local port.
  `sudo ss -ltnp | grep 18789`, then either free it or set `LOCAL_PORT` in
  `.env` (not on the command line once `.env` exists) and re-run setup.
- **image pull fails** — GHCR rate-limit or auth. `docker pull
  ghcr.io/openclaw/openclaw:2026.10.7` by hand to see the real error.
- **container is `unhealthy`** — the healthcheck runs
  `dist/docker-healthcheck.js` inside the container; run it yourself for the
  real error: `docker exec openclaw-gateway node dist/docker-healthcheck.js`.

## Local `127.0.0.1:18789/` fails but the container is "running"

- Give it a minute on first boot — setup waits 3 minutes, but a slow pull or
  first-run config write can outlast a manual check.
- Check it is actually the gateway answering:
  `docker inspect -f '{{.State.Health.Status}}' openclaw-gateway`.
- If the gateway is up but refuses connections, its config may have a
  different `gateway.bind`/`gateway.port`. Sync it again:
  `docker compose --project-directory services/openclaw run --rm --no-deps
   --entrypoint node openclaw-gateway dist/index.js config get gateway.bind`.

## The Control UI loads but rejects the token

- The token is `OPENCLAW_GATEWAY_TOKEN` in `services/openclaw/.env` — it is
  generated once and never rotated by setup.sh. A `.env` written by hand (or
  copied from another box) desyncs it from what the browser expects; the
  container logs show auth failures.
- After a `--purge` + fresh setup the token changes — old browser sessions
  must re-login.

## `tailscale serve` errors during setup

- **`serve is not enabled` / permission denied** — first publish on a node
  needs the tailnet operator set (setup does `sudo tailscale set
  --operator=$USER` itself on Linux) or an admin approval: it prints a link,
  approve in the admin console, press Enter.
- **`https=18789 already in use`** — another service owns that Serve port.
  `tailscale serve status` shows which; pick another `HTTPS_PORT`.
- Nothing else may publish here — check `tailscale serve status` for a
  stale mapping pointing at a dead port and remove it:
  `tailscale serve --https=<port> off`.

## HTTPS answers 403 `proxy_attribution_required`

The gateway sees Serve's forwarded client headers coming from a proxy it
does not trust. `gateway.trustedProxies` must cover the docker bridge
subnet pinned in `docker-compose.yml` (`192.168.144.0/24`):

```bash
docker exec openclaw-gateway node dist/index.js config get gateway.trustedProxies
docker exec openclaw-gateway node dist/index.js config set --batch-json \
  '[{"path":"gateway.trustedProxies","value":["192.168.144.0/24"]}]'
```

A bare `config set` from `docker compose run` fails with a
`GatewayLockNamespaceError` while the gateway is up — config writes go
through `docker exec` once it is running (setup.sh only uses the throwaway
container pre-start, when no gateway holds the lock).

## Browser refused on the published URL, but curl checks pass

`controlUi.allowedOrigins` was seeded at first deploy and setup.sh never
rewrites a list that already exists. If the publish later moved to a
different `HTTPS_PORT`, the new origin is missing and browsers are rejected
while every `/healthz` check stays green. setup.sh warns when it sees this.
Check and repair (keep the entries already there):

```bash
docker exec openclaw-gateway node dist/index.js config get gateway.controlUi.allowedOrigins
docker exec openclaw-gateway node dist/index.js config set --batch-json \
  '[{"path":"gateway.controlUi.allowedOrigins","value":["<new origin>","<old entries>"]}]'
```

## HTTPS URL doesn't load from a client

- Confirm the publish exists and points at this service:
  `tailscale serve status | grep -A2 18789` should show
  `proxy http://127.0.0.1:18789`.
- The local hop must work first: `curl -I http://127.0.0.1:18789/` on the box.
- The tailnet URL is `https://<host>.<tailnet>.ts.net:18789` — the port is
  in the URL, not optional.
- First request after publish can take ~60 s while the cert is minted;
  retry before assuming it is broken.

## Channels / onboarding problems

- Channel auth profiles live in `~/services/openclaw/auth-secrets`; a
  channel that keeps logging out has usually lost write access there —
  `ls -l ~/services/openclaw` should show the dirs owned by you.
- The CLI is the fix path for most channel issues:
  `docker compose --project-directory services/openclaw run --rm
   openclaw-cli channels list` / `channels logs <channel>`.

## A native `~/.openclaw` also exists

setup.sh never writes there — this deploy keeps everything under
`~/services/openclaw`. A stray `~/.openclaw` belongs to some other install
and is outside this service's scope (and outside teardown's reach).

## Nuke and pave

```bash
cd services/openclaw
./teardown.sh --purge     # type "openclaw" to confirm
./setup.sh
```

`--purge` deletes `~/services/openclaw` (gateway config, sessions, agent
workspace, auth profiles) and `.env`, after stopping the container and
unpublishing only the Serve ports that point at this service. If
`.env` moved one of the `OPENCLAW_*_DIR` paths outside `~/services/openclaw`,
purge refuses and keeps `.env` — move the dir back inside or remove it by
hand first, so nothing the record points at is left behind. Without
`--purge`, teardown stops the container and keeps all state — `./setup.sh`
brings the same deployment back.
