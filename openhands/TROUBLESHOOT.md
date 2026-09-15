# openhands — Troubleshooting

Triage in layers, outermost failure first:

```
container up? → local :8000 → /health is not 502 → serve :8000 → tailnet HTTPS
```

Quick triage:

```bash
cd ~/dev/setup-server/openhands
docker inspect -f '{{.State.Status}}' openhands-agent-canvas
curl -fsS -o /dev/null http://127.0.0.1:8000/       # or /canvas
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/health
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", this shell is not in the docker
group: `sg docker -c './tests/run-tests.sh --live'`.

## Container will not start / keeps restarting

```bash
docker compose --project-directory ~/dev/setup-server/openhands \
  logs --tail=100 openhands
```

- **`--public` rejected** — an older image that does not take that
  flag. Check `OPENHANDS_VERSION` in `.env`; the documented channel is
  `latest` on `ghcr.io/openhands/agent-canvas`.
- **OOM (exit 137)** — the box has 7.7 GB and ollama already claims a
  lot. `OPENHANDS_MEM_LIMIT` defaults to `2g`. Lower it in `.env` or
  stop a neighbour (`n8n`, kaichenpedia) first.
- **`variable is not set`** — `.env` is incomplete. Compose guards
  `OPENHANDS_API_KEY`, `OH_SECRET_KEY`, `OPENHANDS_DATA`,
  `AGENT_WORKSPACES`.
- **Permission on the data dir / 502 `ECONNREFUSED 127.0.0.1:18000`** —
  the UI on `:8000` is the ingress; `/api` is proxied to the agent
  server on `:18000` *inside* the container. That process runs as uid
  `10001`. If `~/services/openhands/data` is `0700` and host-owned, it
  cannot mkdir `conversations/`, exits, and every Canvas API call 502s.
  `setup.sh` grants `u:10001:rwx` via ACL (or `0777` if `setfacl` is
  missing). Repair in place:

  ```bash
  setfacl -m u:10001:rwx -d -m u:10001:rwx ~/services/openhands/data
  setfacl -m u:10001:rwx -d -m u:10001:rwx ~/agent-workspaces
  sg docker -c 'docker compose --project-directory ~/dev/setup-server/openhands restart'
  ```

  Do not chmod a `~/.claude` mount.

## Canvas loads but the backend asks for a key / is disconnected

That is `--public` working. Paste `OPENHANDS_API_KEY` from
`openhands/.env`. A key changed in the UI is *not* synced back; mirror
it into `.env` or the next `./setup.sh` will keep serving the old one
to Compose.

## Claude Code / Codex ACP inside Canvas fails

The container only sees `/projects` plus whatever
`docker-compose.creds.yml` mounted. That overlay is written once, when
`~/.claude` or `~/.codex` already existed, and is never overwritten.
Delete it only if you intend to drop those mounts, then re-run.

OpenHands documents a shared-HOME race for concurrent same-provider ACP
conversations in one container.

Do not mount `/` or `$HOME` to "make ACP work".

## Serve / HTTPS

```bash
tailscale serve status
# expect:
#   :8000 -> http://127.0.0.1:8000
```

- Cert still minting: wait a minute, `curl -I` the HTTPS URL.
- Operator denied: `sudo tailscale set --operator="$USER"` then re-run.
- Never `tailscale serve reset` — it wipes every service on this box.
- Never enable Funnel.

## Nuke and pave

Keeps Paperclip and host Claude/Codex auth:

```bash
docker compose --project-directory ~/dev/setup-server/openhands down
rm -rf ~/services/openhands/data
# then ./setup.sh  — existing .env is reused, including the API key
tailscale serve --https=8000 off
```
