# Open WebUI — Troubleshooting

Layered triage, top-down:

```
1. container running?  →  2. local /health?  →  3. ollama reachable?  →  4. serve/tailnet?
```

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps
curl -fsS http://127.0.0.1:3001/health          # expect {"status":true}
curl -fsS http://127.0.0.1:11434/api/version    # ollama up?
tailscale serve status                          # :10000 -> 127.0.0.1:3001
./tests/run-tests.sh --live                     # all of the above at once
```

If `docker` says "permission denied while trying to connect to the docker
API", you are not in the `docker` group *in this shell* — a shell opened
before the group was granted never picks it up, and `docker inspect` will
report a healthy container as not running. Re-run under
`sg docker -c './tests/run-tests.sh --live'`.

From a phone, the launcher at
`https://kai-home-server.taild6a23f.ts.net/home/` shows this service's live
status and has a restart button, which is quicker than any of the above.

## Container won't start

```sh
docker compose --project-directory . logs --tail 100 open-webui
```

- **Port already in use** — host networking means the container competes for
  host ports directly: `ss -ltnp | grep 3001`. Change `LOCAL_PORT` in `.env`,
  `docker compose up -d`, re-run `tailscale serve --bg --https=10000
  http://127.0.0.1:<new port>`.
- **`.env` missing** — re-run `./setup.sh` (regenerates only if absent).
- **Slow first start** — the image runs DB migrations and downloads a small
  embedding model on first boot; give it a minute or two.

## UI up but no models in the dropdown

- Is ollama running and does it have models? `ollama list` — this box has
  `qwen3:8b`, `qwen3:4b` and `nomic-embed-text`. Pull another with
  `ollama pull <model>`; the UI refreshes automatically.
- Check the connection: Admin Panel → Settings → Connections → Ollama API
  should be `http://127.0.0.1:11434`. Test button should pass.
- If `OLLAMA_BASE_URL` changed, update `.env` **and**
  `docker compose --project-directory . up -d` (env vars only apply at
  container [re]creation).

## Login / accounts

- **Locked out / lost admin password** — user DB is
  `~/services/open-webui/data/webui.db`. Simplest recovery if there's nothing
  to keep: `docker compose --project-directory . down`, move
  `~/services/open-webui/data` aside, `up -d`, re-register (first account =
  admin again).
- **Unexpected signups** — only tailnet devices can reach it, but you can
  disable signups: Admin Panel → Settings → Enable New Sign Ups → off.

## Responses are slow

- Expected on CPU: a 7–8B model on the Ryzen 2600 generates a few tokens/sec.
  First response after idle is slower (ollama loads the model into RAM).
- Check nothing else is eating RAM: `free -h`; `qwen3:8b` claims ~5 GB of the
  box's 7.7 GB while loaded, and it is now competing with Immich, Forgejo,
  Jellyfin and Seafile. Switch to `qwen3:4b` for snappier chat, or stop the
  heavier neighbours from the launcher first. If something gets OOM-killed
  (exit 137) mid-generation, that is the cause.

## Kuma says open-webui is down

The monitor probes the **tailnet** URL (`https://…:10000/health`), not
loopback, so it goes red for a publishing failure as readily as an app
failure. Curl `http://127.0.0.1:3001/health` first — if that answers, the
fault is Tailscale Serve or the cert. Everything red at once is tailscaled,
not every service failing at the same moment.

## Tailscale layer

Same patterns as the other services (see `../code-server/TROUBLESHOOT.md`):
cert minting delay on first request, client must be on the tailnet, serve
config reapply after tailscaled restarts:
`tailscale serve --bg --https=10000 http://127.0.0.1:3001`

⚠️ **Never `tailscale serve reset`** to clear a bad mapping. It wipes the
serve config for the whole node — every published service dark at once, each
one's `setup.sh` to be re-run. The single-port removal is
`tailscale serve --https=10000 off`; `off` is absent from
`tailscale serve --help` on 1.102.3 (which only advertises `reset` and
`clear`) but is what Tailscale prints after a successful serve, and is
verified working here.

## Nuke and pave (destroys chats, accounts, uploaded docs — not ollama models)

```sh
docker compose --project-directory . down
rm -rf ~/services/open-webui .env
tailscale serve --https=10000 off
./setup.sh
```
