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
tailscale serve status                          # :10000 -> 127.0.0.1:3001?
./tests/run-tests.sh --live                     # all of the above at once
```

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

- Is ollama running and does it have models? `ollama list`. Pull one:
  `ollama pull llama3.1:8b` — the UI refreshes automatically.
- Check the connection: Admin Panel → Settings → Connections → Ollama API
  should be `http://127.0.0.1:11434`. Test button should pass.
- If `OLLAMA_BASE_URL` changed, update `.env` **and**
  `docker compose --project-directory . up -d` (env vars only apply at
  container [re]creation).

## Login / accounts

- **Locked out / lost admin password** — user DB is
  `~/open-webui/data/webui.db`. Simplest recovery if there's nothing to keep:
  `docker compose down`, move `~/open-webui/data` aside, `up -d`, re-register
  (first account = admin again).
- **Unexpected signups** — only tailnet devices can reach it, but you can
  disable signups: Admin Panel → Settings → Enable New Sign Ups → off.

## Responses are slow

- Expected on CPU: a 7–8B model on the Ryzen 2600 generates a few tokens/sec.
  First response after idle is slower (ollama loads the model into RAM).
- Check nothing else is eating RAM: `free -h`; ollama needs ~5 GB headroom
  for a 7B model. Consider smaller models (`qwen2.5:3b`, `llama3.2:3b`) for
  snappier chat.

## Tailscale layer

Same patterns as the other services (see `../code-server/TROUBLESHOOT.md`):
cert minting delay on first request, client must be on the tailnet, serve
config reapply after tailscaled restarts:
`tailscale serve --bg --https=10000 http://127.0.0.1:3001`

## Nuke and pave (destroys chats, accounts, uploaded docs — not ollama models)

```sh
docker compose --project-directory . down
rm -rf ~/open-webui .env
./setup.sh
```
