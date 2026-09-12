# Seafile — self-hosted Drive, tailnet-only

File sync + web drive (Google Drive replacement) with desktop and mobile
clients, served only to your Tailscale devices at
`https://<host>.<tailnet>.ts.net:8443`.

Chosen over OpenCloud/Nextcloud for this stack because its C sync engine is
predictable under continuous sync load (iPhone photo backup) — see the
research notes in the repo history. Trade-off accepted: files are stored in
Seafile's chunked internal format, not as plain files on disk (see Backups).

## Architecture

```
Clients (web / Mac sync app / iOS app)
        │ HTTPS (tailnet only, WireGuard-encrypted)
        ▼
Tailscale Serve (:8443) ──▶ seafile container (127.0.0.1:8081)
                                 │
                     ┌───────────┴───────────┐
                     ▼                       ▼
              seafile-mysql             seafile-redis
              (MariaDB 10.11)           (cache)
```

- All containers on an internal Docker network; only the Seafile web port is
  published, and only on `127.0.0.1`.
- Tailscale Serve terminates TLS (auto-managed Let's Encrypt cert). code-server
  owns :443, so Seafile uses :8443 (modern Tailscale allows any HTTPS port).
- `restart: unless-stopped` + the system dockerd makes it boot-persistent —
  no systemd unit needed.
- Differences from the official compose: no Caddy proxy (Tailscale replaces
  it), SeaDoc/notification/AI services disabled, volumes under `~/seafile/`.

## Dependencies

| Component | Role | Managed by |
|---|---|---|
| Docker Engine + Compose v2 | Runs the stack, restarts on boot | apt (`docker.io`, `docker-compose-v2`) |
| seafileltd/seafile-mc:13.0 | Seafile server + web UI | this compose |
| mariadb:10.11 | Metadata database | this compose |
| redis:7-alpine | Cache | this compose |
| tailscaled + Serve | VPN + HTTPS termination | system service |

## Deploy

Prerequisites: Docker + Compose v2 installed, user in the `docker` group
(`sudo usermod -aG docker $USER`, then re-login), Tailscale logged in.

```sh
./setup.sh                                  # local 8081, HTTPS 8443
LOCAL_PORT=9081 HTTPS_PORT=10000 ./setup.sh # overrides
ADMIN_EMAIL=you@example.com ./setup.sh      # admin account email
```

What it does: preflight (docker daemon reachable, tailscale up, valid HTTPS
port) → generates `.env` with all secrets (mode 600, never overwritten on
re-run) → `docker compose up -d` → waits for the web UI → publishes via
`tailscale serve --https=8443` → verifies end-to-end → prints URL + admin
login.

State lives in:
- `.env` (this directory) — **all secrets**; gitignored, mode 600
- `~/services/seafile/data` — Seafile's storage (chunked libraries, config, logs)
- `~/services/seafile/mysql` — MariaDB data

## Clients

Server URL for all clients: `https://<host>.<tailnet>.ts.net:8443`

- **Web**: just open the URL, log in with the admin credentials from `.env`
- **macOS**: [Seafile Drive/Sync clients](https://www.seafile.com/en/download/)
- **iOS**: "Seafile Pro" app (App Store — free, works with CE servers);
  enable auto camera upload in settings for photo backup. The phone must be
  on the tailnet for sync to work — Tailscale iOS app handles that.

Tip: create a normal (non-admin) user in the web UI for daily use.

## Operations

```sh
D="--project-directory <this dir>"
docker compose $D ps                # status
docker compose $D logs -f seafile  # logs
docker compose $D restart          # restart stack
docker compose $D down             # stop (data persists in ~/services/seafile)
docker compose $D pull && docker compose $D up -d   # upgrade minor versions
```

Major-version upgrades (13 → 14): read Seafile's upgrade notes first, then
bump `SEAFILE_IMAGE` in `.env` and `up -d`.

## Backups — important, read once

Seafile stores file data in a chunked content-addressed format under
`~/services/seafile/data/seafile-data/storage/`. A raw copy of
`~/services/seafile/` **is** a valid backup, but it is only restorable
*through Seafile* (same version) — you cannot pluck individual files out of
it by hand.

Sound procedure (in order):
1. `docker exec seafile-mysql mysqldump -uroot -p"$INIT_SEAFILE_MYSQL_ROOT_PASSWORD" --all-databases > seafile-db.sql`
2. Snapshot `~/seafile/data` (rsync/restic to another disk or machine)
3. Keep `.env` with the backup — without its secrets the DB dump is useless

Plain-file escape hatch: `seaf-fuse` can mount libraries as a browsable
filesystem from inside the container if you ever need direct file access.

Run garbage collection occasionally to reclaim space from deleted files
(stops the server briefly):
`docker exec seafile /opt/seafile/seafile-server-latest/seaf-gc.sh`

## Tests

```sh
./tests/run-tests.sh          # mocked suite — no docker/system changes
./tests/run-tests.sh --live   # + verify the real deployment
```
