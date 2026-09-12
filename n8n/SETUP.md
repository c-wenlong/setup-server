# n8n — workflow automation, tailnet-only

Self-hosted Zapier: visual workflows connecting APIs, schedules, webhooks,
and the other services on this box. Reachable only from your Tailscale
devices at `https://<host>.<tailnet>.ts.net:5678`.

## Architecture

```
Clients (browser) ──HTTPS──▶ Tailscale Serve (:5678) ──▶ n8n (127.0.0.1:5678)
                                                              │ workflows can call
                                                              ▼
                                    ollama :11434 · ntfy :3003 · seafile :8081 · anything
```

- **Host network mode** so workflows can hit localhost-bound services
  directly; `N8N_LISTEN_ADDRESS=127.0.0.1` keeps the UI loopback-only.
- SQLite storage (fine for single-user); data + **encryption key** in
  `~/services/n8n/data`. The key also lives in `.env` — it encrypts every credential
  you save in workflows, so back up `.env` with the data.
- `WEBHOOK_URL`/`N8N_EDITOR_BASE_URL` are set to the tailnet URL, so
  webhook nodes display URLs that actually work from tailnet devices.
  (External services on the internet canNOT reach these webhooks — that
  would need Tailscale Funnel, deliberately not enabled.)
- Image `n8nio/n8n` (v2.x), task runners enabled, telemetry disabled.

## Deploy

```sh
./setup.sh
OWNER_EMAIL=me@x.com OWNER_PASSWORD='MyPass123' ./setup.sh   # owner creds
LOCAL_PORT=5679 ./setup.sh                                   # HTTPS port follows
```

Owner account is seeded via n8n's setup API (`/rest/owner/setup` — requires
a `browser-id` header on 2.x, and the REST API only comes up after DB
migrations, hence the readiness wait). Password policy: ≥8 chars with at
least 1 number and 1 capital letter. Credentials live in the gitignored
`.env` (mode 600).

## Useful first workflows on this box

- Cron → check disk space → `POST http://127.0.0.1:3003/alerts` (ntfy push)
- Webhook → prompt ollama (`http://127.0.0.1:11434/api/generate`) → respond
- Schedule → hit any external API → save results into Seafile via WebDAV

## Operations

```sh
D="--project-directory <this dir>"
docker compose $D ps|logs -f|restart|down
docker compose $D pull && docker compose $D up -d   # upgrade
```

Kuma monitors `/healthz` (monitoring/seed_kuma.py). Backup = `~/services/n8n/data`
plus this directory's `.env` (encryption key!).

## Tests

```sh
./tests/run-tests.sh          # mocked suite
./tests/run-tests.sh --live   # + verify real deployment
```
