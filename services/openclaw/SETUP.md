# openclaw — self-hosted AI assistant gateway

One gateway that fronts a personal AI assistant: a browser Control UI, chat
channels (Telegram, WhatsApp, Discord, Slack, Signal…), voice, canvas and a
WebSocket API, on the tailnet at `https://homeserver.tail-name.ts.net:18789`.

Docker rather than a host install on purpose: OpenClaw wants Node 24+ (26
recommended) and this box runs Node 22. The official GHCR image carries its
own runtime, so the host's Node version is irrelevant.

## Architecture

One long-running container plus a profile-gated CLI sidecar:

```
  phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:18789
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:18789
            ▼
   ┌────────────────────────────────────────┐
   │ container: openclaw-gateway            │
   │   ghcr.io/openclaw/openclaw:2026.10.7  │
   │                                        │
   │   Gateway + Control UI   :18789        │
   │   node bridge            :18790 (off)  │
   │   MS Teams               :3978  (off)  │
   └────────────┬───────────────────────────┘
                │ bind mounts
                ▼
   ~/services/openclaw/
     config/       → /home/node/.openclaw      (openclaw.json, sessions, creds)
     workspace/    → /home/node/.openclaw/workspace  (agent scratch + files)
     auth-secrets/ → /home/node/.config/openclaw    (channel auth profiles)

   optional, only if they exist on the host:
     ~/.claude     → /home/node/.claude   (Claude Code login reused)
     ~/.codex      → /home/node/.codex    (Codex login reused)
```

`openclaw-cli` (same image, `cli` profile) shares the gateway's network
namespace so its `localhost` is the gateway listener — that is how channels
are added and how the pre-start config sync runs. It never runs as a daemon:
`up -d` skips it via the profile, `docker compose run --rm openclaw-cli …`
brings it up for one command.

## Security model

- The gateway port is published on `127.0.0.1` only. Upstream's compose
  binds `0.0.0.0:18789`; this one does not — nothing on the LAN can reach it.
- Remote access is `tailscale serve` (tailnet-only HTTPS with a real cert),
  which is also the upstream-recommended topology: loopback plus Tailscale.
- `OPENCLAW_GATEWAY_TOKEN` (32 hex chars, generated into `.env`, mode 600)
  gates the Control UI and API. Tailscale is the network boundary; the token
  is the app-level gate for anything on the tailnet.
- The container drops `NET_RAW`/`NET_ADMIN` and runs `no-new-privileges`.
- `~/.claude` and `~/.codex` are mounted only when they already exist, so the
  bundled Claude/Codex providers can reuse their logins (token refresh needs
  them writable, same trade-off as services/openhands). setup.sh never
  creates, copies or overwrites them.
- `gateway.mode` is pinned to `local` and `gateway.bind` to `lan` in
  `openclaw.json` before first boot — `lan` inside the container is what the
  published loopback port forwards to, and `local` keeps onboarding off the
  public-facing wizard paths.
- `controlUi.allowedOrigins` is seeded to loopback plus the tailnet HTTPS URL.
  If the config already has origins set, setup.sh leaves them alone.
- `gateway.trustedProxies` is seeded to the compose network's pinned subnet
  (`192.168.144.0/24`). Every request — Serve's and local curl's — reaches
  the container through docker-proxy from that network's gateway, and
  OpenClaw 403s forwarded client headers from a proxy it does not trust
  (`proxy_attribution_required`). The subnet is pinned in
  `docker-compose.yml` because docker would otherwise reallocate it on
  network recreation and silently break the tailnet path. A hand-set value
  is left alone.

## Dependencies

| Needs | Why |
|---|---|
| Linux or macOS | anything else dies in preflight |
| `curl` | health checks |
| Docker + Compose v2 | the gateway runs in a container |
| Tailscale logged in | MagicDNS name + Serve publish |
| sudo | at most once: `tailscale set --operator` on Linux |

## What setup.sh does

1. Preflight: non-root user, curl, Docker daemon reachable, Compose v2,
   Tailscale up, numeric ports, MagicDNS hostname.
2. Writes `.env` (mode 600) if absent: image tag, ports, state paths,
   generated `OPENCLAW_GATEWAY_TOKEN`. An existing `.env` is the source of
   truth and is never overwritten — port overrides after that are reported
   and ignored.
3. Creates `~/services/openclaw/{config,workspace,auth-secrets}`.
4. Writes `docker-compose.creds.yml` once when `~/.claude` or `~/.codex`
   exists (the bind mounts above).
5. Syncs `openclaw.json` through a throwaway container (`gateway.mode`,
   `gateway.bind` always; `controlUi.allowedOrigins` and
   `gateway.trustedProxies` only when unset). The running gateway locks its
   own config, so this happens pre-start; once deployed, use
   `docker exec openclaw-gateway node dist/index.js config …` instead.
6. `docker compose up -d openclaw-gateway`, waits for `127.0.0.1:18789/`.
7. `tailscale serve --bg --https=<HTTPS_PORT> http://127.0.0.1:<LOCAL_PORT>`.
8. End-to-end HTTPS check on the tailnet URL.

## Deploy

```bash
cd services/openclaw
./setup.sh                        # local :18789, tailnet HTTPS :18789
LOCAL_PORT=18790 ./setup.sh       # HTTPS port follows LOCAL_PORT
HTTPS_PORT=8443 ./setup.sh        # or set it explicitly
```

An explicit `HTTPS_PORT` is recorded in `.env` (delete that line to resume
following `LOCAL_PORT`); the launcher tile reads `.env` for its link, so it
always points at the real publish port.

Re-running is safe: it reuses `.env`, leaves a configured `allowedOrigins`
alone, and re-applies the Serve mapping.

## Client side

Open `https://<host>.<tailnet>.ts.net:18789` on any tailnet device and paste
`OPENCLAW_GATEWAY_TOKEN` from `services/openclaw/.env` when the Control UI
asks. Then connect a model provider (a mounted `~/.claude`/`~/.codex` login
is reused) and add a channel:

```bash
cd services/openclaw
docker compose run --rm openclaw-cli channels add --channel telegram --token "<bot token>"
```

## Ops

```bash
cd services/openclaw
docker compose ps                          # container state
docker compose logs -f openclaw-gateway    # logs
docker compose restart openclaw-gateway
docker compose pull && ./setup.sh          # upgrade to OPENCLAW_VERSION
./teardown.sh                              # unpublish + remove container (keeps state)
./teardown.sh --purge                      # also deletes ~/services/openclaw + .env
```

## Tests

`./tests/run-tests.sh` — 200-check mocked suite (stubbed docker/tailscale/
curl/sudo). `./tests/run-tests.sh --live` additionally verifies the real
deployment on this box.

## Notes

- The node bridge (`:18790`) and MS Teams (`:3978`) listeners are in the
  upstream compose but unpublished here; uncomment the port lines if a
  channel needs them.
- `host.docker.internal` is mapped so bundled local-model providers can
  reach a host ollama/LM Studio.
- Backing up `~/services/openclaw` backs up everything that matters; the
  container is disposable.
