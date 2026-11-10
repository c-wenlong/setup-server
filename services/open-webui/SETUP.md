# Open WebUI — chat UI over local ollama, tailnet-only

ChatGPT-style web interface (conversations, model switching, RAG on uploaded
docs, phone-friendly PWA) backed by the ollama instance already running on
the host. Reachable only from your Tailscale devices at
`https://<host>.<tailnet>.ts.net:3001`.

## Architecture

```
Clients (browser / iOS PWA)
        │ HTTPS (tailnet only)
        ▼
Tailscale Serve (:3001) ───▶ open-webui container ──▶ host ollama (:11434)
                             (host network, binds
                              127.0.0.1:3001 only)
```

- **Host network mode**: ollama runs on the host, so the container shares the
  host network namespace to reach it at `127.0.0.1:11434`. `HOST=127.0.0.1`
  keeps the UI itself loopback-only — nothing new is exposed to LAN.
- The published port equals the local port (:3001 both sides), the
  convention for services here. It was :10000 until 2026-09-13, a number
  chosen when Tailscale Serve only allowed 443/8443/10000; modern Tailscale
  allows any HTTPS serve port, so the indirection bought nothing.
- Boot-persistent via Docker's `restart: unless-stopped` — no systemd unit.
- Chat history, accounts, and uploaded docs live in `~/services/open-webui/data`.

## Dependencies

| Component | Role | Managed by |
|---|---|---|
| ollama | Runs the models (prerequisite, NOT installed here) | host systemd service |
| ghcr.io/open-webui/open-webui | Web UI + RAG + user accounts | this compose |
| Docker + Compose v2 | Runs the container | apt / Docker Desktop |
| tailscaled + Serve | VPN + HTTPS termination | system service |

## Deploy

```sh
./setup.sh                                  # local 3001, HTTPS 3001
LOCAL_PORT=3005 HTTPS_PORT=8443 ./setup.sh  # overrides
OLLAMA_BASE_URL=http://... ./setup.sh       # non-default ollama location
```

**Login is seeded, not raced**: the image is pinned (`0.13.2`, never
`:main`) and starts with `ENABLE_SIGNUP=false`, so open registration is off
from the first boot. `setup.sh` then creates the owner account over the API
(`WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` in `.env`) — the first signup
is exempt from the flag and lands the admin role, which is what keeps a
tailnet peer from grabbing it. Extra users come from the Admin Panel
("Add User"), not open signup; flip `ENABLE_SIGNUP=true` in `.env` only if
you really want public-to-the-tailnet registration.

## Phone usage

Open the URL in mobile Safari/Chrome → "Add to Home Screen" gives a
full-screen PWA that feels like the ChatGPT app, but running your models.
Requires Tailscale connected on the phone.

## Operations

```sh
D="--project-directory <this dir>"
docker compose $D ps|logs -f|restart|down
# upgrade: bump WEBUI_IMAGE in .env to the next pinned tag, then
docker compose $D pull && docker compose $D up -d
ollama list                                          # models the UI can offer
ollama pull <model>                                  # add models (UI picks up automatically)
```

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes the Serve
port(s) pointing at this service and runs `compose down`; data and `.env`
stay, so `./setup.sh` brings it back. `./teardown.sh --purge` also deletes
them, after you type `open-webui`. ollama and its models are never touched.

RAM note: the UI itself is light (~300–400 MB); it's ollama that claims
~5 GB while a 7–8B model is loaded. Ollama unloads idle models after a few
minutes by default.

## Tests

```sh
./tests/run-tests.sh          # mocked suite — no docker/system changes
./tests/run-tests.sh --live   # + verify the real deployment
```
