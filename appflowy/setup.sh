#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of AppFlowy Cloud (self-hosted Notion
# alternative) behind Tailscale. Linux + macOS.
#
# End state:
#   - nginx + postgres/pgvector + redis + minio + gotrue + appflowy_cloud
#     + admin_frontend + worker + web on a private compose network
#   - nginx published on 127.0.0.1:LOCAL_PORT only (default 8102)
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - first admin seeded from GOTRUE_ADMIN_* in .env; public sign-up off
#   - AI and the search indexer left out (RAM; no OpenAI key on this box)
#   - boot-persistent via Docker's restart policy (no systemd/launchd)
#
# Usage:
#   ./setup.sh
#   LOCAL_PORT=8103 ./setup.sh            # HTTPS follows LOCAL_PORT
#   LOCAL_PORT=8103 HTTPS_PORT=8103 ./setup.sh
#   GOTRUE_ADMIN_EMAIL=you@example.com ./setup.sh   # first run only
#
# Version: cloud/gotrue/worker pinned to 0.18.8. The web image tops out
# at 0.18.4 and admin_frontend at 0.18.1 — those are the latest published
# tags on the 0.18 line, not a downgrade. Bump APPFLOWY_*_VERSION in .env,
# then re-run.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the images and repairs the publish.
# An existing .env is never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8102}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
GOTRUE_ADMIN_EMAIL="${GOTRUE_ADMIN_EMAIL:-chenwenlongofficial@gmail.com}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/appflowy"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars: URL-safe, survives .env and postgres URLs without quoting.
randhex() {
  local n="${1:-16}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_hex($n))"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# Postgres / Redis / MinIO run as their own uids and cannot write a
# host-owned bind mount without a sudo chown (same reason Coolify uses
# named volumes for its database). APPFLOWY_DATA is the launcher marker
# and a place for ad-hoc dumps; the live data is in Docker volumes
# appflowy-postgres / appflowy-redis / appflowy-minio.

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

[ -f "$SERVICE_DIR/nginx.conf" ] || die "Missing $SERVICE_DIR/nginx.conf (the HTTP-only reverse proxy). Re-clone the repo."
[ -f "$SERVICE_DIR/docker-compose.yml" ] || die "Missing $SERVICE_DIR/docker-compose.yml. Re-clone the repo."

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# Official "production" compose also pulls an AI container and a 2 GB
# search indexer. Those are off here. Nine remaining containers still
# want a few hundred MiB idle; warn under 1 GB available, do not refuse.
avail_mb=""
if [ -r /proc/meminfo ]; then
  avail_mb="$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' /proc/meminfo)"
  avail_mb="$(( avail_mb / 1024 ))"
fi
if [ -n "${avail_mb:-}" ] && [ "$avail_mb" -lt 1024 ]; then
  warn "Only ~${avail_mb} MB RAM available. AppFlowy Cloud idles several hundred MiB with the caps in docker-compose.yml; unload ollama or stop another service if a container gets OOM-killed."
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated JWT, DB, MinIO, admin password)"
  pg_user="appflowy"
  pg_db="appflowy"
  pg_pass="$(randhex 24)"
  jwt="$(randhex 32)"
  s3_key="$(randhex 10)"
  s3_secret="$(randhex 24)"
  admin_pass="$(randhex 16)"
  base="https://$TS_HOST:$HTTPS_PORT"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose interpolates this file from the project directory.

# Pinned. Official floats \`latest\`. Web and admin_frontend have no 0.18.8
# tag — 0.18.4 / 0.18.1 are the newest published on that line. To upgrade:
# bump these, then ./setup.sh.
APPFLOWY_CLOUD_VERSION=0.18.8
GOTRUE_VERSION=0.18.8
APPFLOWY_WORKER_VERSION=0.18.8
APPFLOWY_WEB_VERSION=0.18.4
APPFLOWY_ADMIN_FRONTEND_VERSION=0.18.1
NGINX_VERSION=1.27-alpine
PGVECTOR_VERSION=pg16
REDIS_VERSION=7-alpine
MINIO_VERSION=RELEASE.2024-12-18T13-15-44Z
# Docker Hub's minio/minio is frozen/source-only; the same tag lives on quay.io.

LOCAL_PORT=$LOCAL_PORT

# Runtime state marker (launcher "installed" check). Postgres / Redis /
# MinIO data live in named volumes — the images run as their own uids
# and cannot write a host-owned bind mount without a sudo chown.
APPFLOWY_DATA=$STATE

# Public identity. GoTrue, the web client and presigned MinIO URLs all
# build links from these, so they must be the tailnet HTTPS URL with the
# port and no trailing slash. If the machine is renamed or the HTTPS port
# moves, edit them and re-run — setup.sh warns when they drift.
APPFLOWY_BASE_URL=$base
APPFLOWY_WEB_URL=$base
API_EXTERNAL_URL=$base/gotrue
APPFLOWY_WEBSOCKET_BASE_URL=wss://$TS_HOST:$HTTPS_PORT/ws/v2
APPFLOWY_S3_PRESIGNED_URL_ENDPOINT=$base/minio-api

# Caps for a 7.7 GB box. Official compose has none. AI and the search
# indexer are not in this stack at all.
APPFLOWY_NGINX_MEM_LIMIT=64m
APPFLOWY_DB_MEM_LIMIT=512m
APPFLOWY_REDIS_MEM_LIMIT=64m
APPFLOWY_MINIO_MEM_LIMIT=256m
APPFLOWY_GOTRUE_MEM_LIMIT=128m
APPFLOWY_CLOUD_MEM_LIMIT=512m
APPFLOWY_ADMIN_MEM_LIMIT=128m
APPFLOWY_WORKER_MEM_LIMIT=256m
APPFLOWY_WEB_MEM_LIMIT=128m
APPFLOWY_DATABASE_MAX_CONNECTIONS=10
AI_ENABLED=false
# Empty: do not point at the omitted search container.
APPFLOWY_SEARCH_SERVICE_URL=

# First admin. GoTrue seeds this on first boot so the web UI is never an
# open "whoever signs up first owns the workspace" window. Public sign-up
# stays off. Changing the password in the UI does not update this file.
GOTRUE_ADMIN_EMAIL=$GOTRUE_ADMIN_EMAIL
GOTRUE_ADMIN_PASSWORD=$admin_pass
GOTRUE_DISABLE_SIGNUP=true
GOTRUE_MAILER_AUTOCONFIRM=true

# Postgres + GoTrue JWT + MinIO. Hex so the postgres:// URL needs no
# percent-encoding. Rotating GOTRUE_JWT_SECRET later invalidates every
# session; rotating POSTGRES_PASSWORD against an existing data dir
# auth-fails forever.
POSTGRES_USER=$pg_user
POSTGRES_DB=$pg_db
POSTGRES_PASSWORD=$pg_pass
GOTRUE_JWT_SECRET=$jwt
GOTRUE_DATABASE_URL=postgres://$pg_user:$pg_pass@postgres:5432/$pg_db?search_path=auth
APPFLOWY_DATABASE_URL=postgres://$pg_user:$pg_pass@postgres:5432/$pg_db
APPFLOWY_WORKER_DATABASE_URL=postgres://$pg_user:$pg_pass@postgres:5432/$pg_db
APPFLOWY_REDIS_URI=redis://redis:6379
APPFLOWY_WORKER_REDIS_URL=redis://redis:6379
APPFLOWY_GOTRUE_BASE_URL=http://gotrue:9999
APPFLOWY_S3_ACCESS_KEY=$s3_key
APPFLOWY_S3_SECRET_KEY=$s3_secret
APPFLOWY_S3_BUCKET=appflowy
APPFLOWY_S3_USE_MINIO=true
APPFLOWY_S3_MINIO_URL=http://minio:9000
APPFLOWY_S3_CREATE_BUCKET=true
APPFLOWY_S3_REGION=us-east-1
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
GOTRUE_ADMIN_EMAIL="${GOTRUE_ADMIN_EMAIL:?GOTRUE_ADMIN_EMAIL missing from $ENV_FILE}"
GOTRUE_ADMIN_PASSWORD="${GOTRUE_ADMIN_PASSWORD:?GOTRUE_ADMIN_PASSWORD missing from $ENV_FILE}"
DATA_DIR="${APPFLOWY_DATA:?APPFLOWY_DATA missing from $ENV_FILE}"
APPFLOWY_BASE_URL="${APPFLOWY_BASE_URL:?APPFLOWY_BASE_URL missing from $ENV_FILE}"
API_EXTERNAL_URL="${API_EXTERNAL_URL:?API_EXTERNAL_URL missing from $ENV_FILE}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"

WANT_BASE="https://$TS_HOST:$HTTPS_PORT"
if [ "$APPFLOWY_BASE_URL" != "$WANT_BASE" ]; then
  warn "APPFLOWY_BASE_URL in .env is $APPFLOWY_BASE_URL but this box now answers to $WANT_BASE."
  warn "  The web client, GoTrue redirects and MinIO presigned URLs will point at the old address. Fix: set APPFLOWY_BASE_URL, APPFLOWY_WEB_URL, API_EXTERNAL_URL, APPFLOWY_WEBSOCKET_BASE_URL and APPFLOWY_S3_PRESIGNED_URL_ENDPOINT to match $WANT_BASE in $ENV_FILE, then re-run."
fi

mkdir -p "$DATA_DIR"

avail_kb="$(df -Pk "$DATA_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 5242880 ]; then
  warn "$(( avail_kb / 1048576 )) GB free at $DATA_DIR — AppFlowy wants a few GB for Postgres + MinIO blobs."
else
  ok "$(( avail_kb / 1048576 )) GB free at $DATA_DIR"
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Starting AppFlowy Cloud (docker compose up -d) — first run pulls ~1 GB of images"
"${COMPOSE[@]}" up -d

info "Waiting for AppFlowy on 127.0.0.1:$LOCAL_PORT (first boot runs migrations)"
for i in $(seq 1 120); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/api/health" 2>/dev/null; then
    ok "AppFlowy Cloud is answering locally"
    break
  fi
  [ "$i" -eq 120 ] && die "AppFlowy did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs"
  sleep 3
done

# ------------------------------------------------------- tailscale serve
info "Publishing via Tailscale Serve (HTTPS :$HTTPS_PORT -> 127.0.0.1:$LOCAL_PORT)"
if ! "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null 2>&1; then
  if [ "$OS" = "Linux" ]; then
    info "Direct serve failed — trying operator grant (needs sudo, one time)"
    sudo tailscale set --operator="$USER"
  fi
  until "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT"; do
    echo
    info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ final check
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url/api/health (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/api/health"; then
  ok "End-to-end HTTPS check passed"
else
  warn "No answer on $url/api/health yet — the cert may still be minting. Retry in a minute: curl $url/api/health"
fi

# A 200 on /api/health does not prove sign-up is locked. GoTrue's
# /settings reports disable_signup; if that is false, anyone on the
# tailnet can create an account and own a workspace.
settings_code="$(curl -sS -o "$WORK/settings.json" -w '%{http_code}' --max-time 30 \
  "$url/gotrue/settings" 2>/dev/null || echo 000)"
settings_body="$(cat "$WORK/settings.json" 2>/dev/null || true)"
case "$settings_code" in
  200)
    case "$settings_body" in
      *'"disable_signup":true'*|*'\"disable_signup\":true'*)
        ok "Public sign-up is disabled"
        ;;
      *'"disable_signup":false'*|*'\"disable_signup\":false'*)
        warn "GET /gotrue/settings says disable_signup=false. GOTRUE_DISABLE_SIGNUP in $ENV_FILE is not taking effect. Anyone on the tailnet can create an account until you fix it."
        ;;
      *)
        warn "Could not read disable_signup from /gotrue/settings. Confirm sign-up is off in the web UI: $url"
        ;;
    esac
    ;;
  *)
    warn "Could not check /gotrue/settings (HTTP $settings_code). Confirm sign-up is off in the web UI: $url"
    ;;
esac

echo
printf '\033[1;32mDone.\033[0m AppFlowy is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "  Login:    $GOTRUE_ADMIN_EMAIL"
echo "  Password: see GOTRUE_ADMIN_PASSWORD in $ENV_FILE"
echo "  Admin:    $url/console"
echo
echo "  Desktop/mobile apps: set the cloud URL to $url"
echo "  AI chat and full-text search are off (no OpenAI key; search wants 2 GB)."
echo "  Upgrade: bump APPFLOWY_CLOUD_VERSION (and siblings) in $ENV_FILE then ./setup.sh"
echo
echo "Backups: nothing backs this box up. Keep $ENV_FILE off-box with the volumes:"
echo "    docker volume inspect appflowy-postgres appflowy-redis appflowy-minio"
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: edit APPFLOWY_*_VERSION in .env, then ./setup.sh"
exit 0
