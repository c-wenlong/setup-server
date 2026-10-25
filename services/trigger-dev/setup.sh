#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Trigger.dev (background jobs + cron) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - combined webapp + supervisor stack (Postgres, Redis, Electric, MinIO,
#     registry, docker-socket-proxy) on a private compose network
#   - dashboard published on 127.0.0.1:LOCAL_PORT only
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - local registry on 127.0.0.1:REGISTRY_PORT for `npx trigger.dev deploy`
#   - boot-persistent via Docker's restart policy (no systemd/launchd)
#
# Usage:
#   ./setup.sh
#   LOCAL_PORT=8031 ./setup.sh            # HTTPS follows LOCAL_PORT
#   LOCAL_PORT=8031 HTTPS_PORT=8031 ./setup.sh
#   ADMIN_EMAIL=me@x.com ./setup.sh       # first run only; .env wins after
#
# Version: pinned to TRIGGER_IMAGE_TAG=v4.6.0 (webapp + supervisor).
# Keep the Trigger.dev CLI on the same line: npx trigger.dev@4.6.0 …
#
# This is a slim stack: no ClickHouse, no s2-lite. Official asks for 6 GB
# (webapp) + 8 GB (worker); this box has 7.7 GB shared. Events stay in
# Postgres and streams stay on Redis. mem_limits and a 768 MiB Node heap
# keep the idle ceiling around 2 GB.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the images and repairs the publish.
# An existing .env is never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8030}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/trigger-dev"
LOGIN_MARKER="$STATE/.magic-link-requested"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars by default (16 bytes): URL-safe, satisfies ENCRYPTION_KEY's
# exact-32-hex check, and survives .env / connection strings without quoting.
randhex() {
  local n="${1:-16}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_hex($n))"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# Escape . and + so an email can be dropped into a regex unquoted.
escape_re() {
  printf '%s' "$1" | sed 's/[.]/\\./g; s/+/\\+/g'
}

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

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac
case "$REGISTRY_PORT" in ''|*[!0-9]*) die "REGISTRY_PORT must be numeric (got: $REGISTRY_PORT)";; esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# Official webapp wants 6 GB; we cap the stack around 2 GB. Say so if the
# box is already tight — do not refuse, the mem_limits are the backstop.
avail_mb=""
if [ -r /proc/meminfo ]; then
  avail_mb="$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' /proc/meminfo)"
  avail_mb="$(( avail_mb / 1024 ))"
fi
if [ -n "${avail_mb:-}" ] && [ "$avail_mb" -lt 1500 ]; then
  warn "Only ~${avail_mb} MB RAM available. Trigger.dev idles near 1.5–2 GB with the caps in docker-compose.yml; unload ollama or stop another service if the webapp gets OOM-killed."
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated secrets + registry password)"
  email_re="$(escape_re "$ADMIN_EMAIL")"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  elif [ -f /etc/timezone ]; then
    tz="$(cat /etc/timezone)"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
# It is NOT passed to any container as env_file.

# Webapp + supervisor. Keep the CLI on the same line:
#   npx trigger.dev@4.6.0 login -a \$APP_ORIGIN
TRIGGER_IMAGE_TAG=v4.6.0

LOCAL_PORT=$LOCAL_PORT
REGISTRY_PORT=$REGISTRY_PORT
TZ=$tz

# Runtime state. Moving a path means moving the directory too.
TRIGGER_SHARED=$STATE/shared
TRIGGER_POSTGRES=$STATE/postgres
TRIGGER_REDIS=$STATE/redis
TRIGGER_MINIO=$STATE/minio
TRIGGER_CLICKHOUSE=$STATE/clickhouse
TRIGGER_REGISTRY=$STATE/registry/data
TRIGGER_REGISTRY_AUTH=$STATE/registry/auth.htpasswd

# Public identity. Magic-link emails and the dashboard's own redirects
# are built from these, so they must be the tailnet HTTPS URL, no
# trailing slash. If the machine is renamed or the HTTPS port moves,
# edit all three and re-run — setup.sh warns when they drift.
APP_ORIGIN=https://$TS_HOST:$HTTPS_PORT
LOGIN_ORIGIN=https://$TS_HOST:$HTTPS_PORT
API_ORIGIN=https://$TS_HOST:$HTTPS_PORT

# First account. WHITELISTED_EMAILS / ADMIN_EMAILS are regexes; only
# this address can sign up, and it is promoted to admin on first login.
ADMIN_EMAIL=$ADMIN_EMAIL
WHITELISTED_EMAILS=^${email_re}$
ADMIN_EMAILS=^${email_re}$

# Application + control-plane secrets. Rotating ENCRYPTION_KEY or
# SESSION_SECRET later logs everyone out and orphans encrypted data.
SESSION_SECRET=$(randhex)
MAGIC_LINK_SECRET=$(randhex)
ENCRYPTION_KEY=$(randhex)
PROVIDER_SECRET=$(randhex)
COORDINATOR_SECRET=$(randhex)
MANAGED_WORKER_SECRET=$(randhex)

POSTGRES_PASSWORD=$(randhex)
CLICKHOUSE_PASSWORD=$(randhex)
OBJECT_STORE_ACCESS_KEY_ID=admin
OBJECT_STORE_SECRET_ACCESS_KEY=$(randhex)

# Local registry. setup.sh writes the matching bcrypt htpasswd next to
# the data dir and docker-logins this box so \`npx trigger.dev deploy\` works.
DOCKER_REGISTRY_URL=localhost:$REGISTRY_PORT
DOCKER_REGISTRY_NAMESPACE=trigger
DOCKER_REGISTRY_USERNAME=registry-user
DOCKER_REGISTRY_PASSWORD=$(randhex)

# Caps for a 7.7 GB box. Do not raise NODE_MAX_OLD_SPACE_SIZE above the
# webapp mem_limit (1g) — the image default is 8192 and will OOM the host.
NODE_MAX_OLD_SPACE_SIZE=768
DEFAULT_ENV_CONCURRENCY=2
DEFAULT_ORG_CONCURRENCY=6
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Keys added after the first ship (v4.6.0 requires CLICKHOUSE_URL at boot
# even when events stay in Postgres). Append, never rewrite the file.
if ! grep -q '^CLICKHOUSE_PASSWORD=' "$ENV_FILE"; then
  printf 'CLICKHOUSE_PASSWORD=%s\n' "$(randhex)" >> "$ENV_FILE"
fi
if ! grep -q '^TRIGGER_CLICKHOUSE=' "$ENV_FILE"; then
  printf 'TRIGGER_CLICKHOUSE=%s\n' "$STATE/clickhouse" >> "$ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL missing from $ENV_FILE}"
DATA_SHARED="${TRIGGER_SHARED:?TRIGGER_SHARED missing from $ENV_FILE}"
DATA_POSTGRES="${TRIGGER_POSTGRES:?TRIGGER_POSTGRES missing from .env}"
DATA_REDIS="${TRIGGER_REDIS:?TRIGGER_REDIS missing from .env}"
DATA_MINIO="${TRIGGER_MINIO:?TRIGGER_MINIO missing from .env}"
DATA_CLICKHOUSE="${TRIGGER_CLICKHOUSE:?TRIGGER_CLICKHOUSE missing from .env}"
DATA_REGISTRY="${TRIGGER_REGISTRY:?TRIGGER_REGISTRY missing from .env}"
AUTH_FILE="${TRIGGER_REGISTRY_AUTH:?TRIGGER_REGISTRY_AUTH missing from .env}"
APP_ORIGIN="${APP_ORIGIN:?APP_ORIGIN missing from $ENV_FILE}"
REGISTRY_USER="${DOCKER_REGISTRY_USERNAME:-registry-user}"
REGISTRY_PASS="${DOCKER_REGISTRY_PASSWORD:?DOCKER_REGISTRY_PASSWORD missing from $ENV_FILE}"
REGISTRY_URL="${DOCKER_REGISTRY_URL:-localhost:${REGISTRY_PORT:-5000}}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"

WANT_ORIGIN="https://$TS_HOST:$HTTPS_PORT"
if [ "$APP_ORIGIN" != "$WANT_ORIGIN" ]; then
  warn "APP_ORIGIN in .env is $APP_ORIGIN but this box now answers to $WANT_ORIGIN."
  warn "  Magic links and dashboard redirects will point at the old address. Fix: set APP_ORIGIN=$WANT_ORIGIN, LOGIN_ORIGIN=$WANT_ORIGIN and API_ORIGIN=$WANT_ORIGIN in $ENV_FILE, then re-run."
fi

mkdir -p "$DATA_SHARED" "$DATA_POSTGRES" "$DATA_REDIS" "$DATA_MINIO" "$DATA_CLICKHOUSE" "$DATA_REGISTRY" "$(dirname "$AUTH_FILE")" "$STATE"

# Bitnami MinIO runs as uid 1001 and will not start as root to chown a
# bind mount the way the official postgres/redis images do. Without sudo
# we cannot chown to 1001, so the directory has to be world-writable.
# Named volumes would hide this; they are also not in ~/services for backup.
chmod 0777 "$DATA_MINIO"

avail_kb="$(df -Pk "$STATE" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 5242880 ]; then
  warn "$(( avail_kb / 1048576 )) GB free at $STATE — task images and run logs only grow. Move the TRIGGER_* paths in .env to a bigger disk before deploying large jobs."
else
  ok "$(( avail_kb / 1048576 )) GB free at $STATE"
fi

# ---------------------------------------------------------- registry auth
# bcrypt htpasswd is the only hash the Docker registry accepts. openssl
# cannot produce it; httpd's htpasswd can, via PATH or a one-shot container.
write_htpasswd() {
  local user="$1" pass="$2" dest="$3"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -Bbn "$user" "$pass" > "$dest"
    return
  fi
  docker run --rm httpd:2 htpasswd -Bbn "$user" "$pass" > "$dest"
}

if [ ! -s "$AUTH_FILE" ]; then
  info "Writing registry htpasswd for $REGISTRY_USER"
  write_htpasswd "$REGISTRY_USER" "$REGISTRY_PASS" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
  ok "Wrote $AUTH_FILE"
else
  ok "Registry htpasswd already present, leaving untouched"
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Starting Trigger.dev (docker compose up -d) — first run pulls several images"
"${COMPOSE[@]}" up -d

info "Waiting for Trigger.dev on 127.0.0.1:$LOCAL_PORT (first boot runs migrations)"
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/healthcheck" 2>/dev/null; then
    ok "Trigger.dev is answering locally"
    break
  fi
  [ "$i" -eq 90 ] && die "Trigger.dev did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs webapp"
  sleep 3
done

info "Waiting for the bootstrap worker token"
for i in $(seq 1 40); do
  if [ -s "$DATA_SHARED/worker_token" ]; then
    ok "Worker token written to $DATA_SHARED/worker_token"
    break
  fi
  [ "$i" -eq 40 ] && warn "Worker token not on disk yet — supervisor will retry. Check: docker logs trigger-webapp"
  sleep 3
done

# The host docker daemon (and therefore `npx trigger.dev deploy` on this
# box) has to be logged into the loopback registry. Safe to re-run.
info "Logging the host Docker daemon into $REGISTRY_URL"
if printf '%s' "$REGISTRY_PASS" | docker login -u "$REGISTRY_USER" --password-stdin "$REGISTRY_URL" >/dev/null 2>&1; then
  ok "docker login $REGISTRY_URL succeeded"
else
  warn "docker login $REGISTRY_URL failed — \`npx trigger.dev deploy\` will not push until you: docker login -u $REGISTRY_USER $REGISTRY_URL"
fi

# ------------------------------------------------------- tailscale serve
info "Publishing via Tailscale Serve (HTTPS :$HTTPS_PORT, tailnet only)"
if ! "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null 2>&1; then
  if [ "$OS" = "Linux" ]; then
    info "Direct serve failed — trying operator grant (needs sudo, one time)"
    sudo tailscale set --operator="$USER"
  fi
  until "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT"; do
    echo
    info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
    read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ final check
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url/healthcheck (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/healthcheck"; then
  ok "End-to-end HTTPS check passed"
else
  warn "No answer on $url/healthcheck yet — the cert may still be minting. Retry in a minute: curl $url/healthcheck"
fi

# ------------------------------------------------------- magic link (once)
# After Serve, so the webapp mints a tailnet HTTPS link rather than
# http://127.0.0.1. No SMTP: the link is printed to webapp logs.
if [ -f "$LOGIN_MARKER" ]; then
  ok "Magic link already requested for $ADMIN_EMAIL — skipping"
else
  info "Requesting a magic-link login for $ADMIN_EMAIL (printed to webapp logs; no SMTP)"
  curl -sS -c "$WORK/cookies" -o /dev/null --max-time 30 \
    "$url/login" 2>/dev/null || \
  curl -sS -c "$WORK/cookies" -o /dev/null --max-time 20 \
    "http://127.0.0.1:$LOCAL_PORT/login" 2>/dev/null || true
  curl -sS -b "$WORK/cookies" -c "$WORK/cookies" -o /dev/null --max-time 30 \
    -X POST "$url/login/magic" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "action=send" \
    --data-urlencode "email=$ADMIN_EMAIL" 2>/dev/null || \
  curl -sS -b "$WORK/cookies" -c "$WORK/cookies" -o /dev/null --max-time 20 \
    -X POST "http://127.0.0.1:$LOCAL_PORT/login/magic" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "action=send" \
    --data-urlencode "email=$ADMIN_EMAIL" 2>/dev/null || true
  magic=""
  for i in $(seq 1 15); do
    magic="$(docker logs trigger-webapp 2>&1 | sed -n 's/.*\(https\{0,1\}:\/\/[^[:space:]]*\/magic[^[:space:]]*\).*/\1/p' | tail -1 || true)"
    [ -n "$magic" ] && break
    sleep 2
  done
  # remix-auth-email-link copies the request host. A loopback POST would
  # mint http://127.0.0.1 — rewrite that to the tailnet URL we just published.
  if [ -n "$magic" ]; then
    magic="$(printf '%s' "$magic" | sed "s#https\\{0,1\\}://127\\.0\\.0\\.1:$LOCAL_PORT#$url#")"
  fi
  mkdir -p "$STATE"
  printf '%s\n' "$ADMIN_EMAIL" > "$LOGIN_MARKER"
  if [ -n "$magic" ]; then
    ok "Magic link is in the webapp logs"
    MAGIC_LINK="$magic"
  else
    warn "Could not parse a magic link from docker logs yet. After the dashboard is up: docker logs trigger-webapp 2>&1 | grep magic"
  fi
fi

echo
printf '\033[1;32mDone.\033[0m Trigger.dev is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "  Login:    $ADMIN_EMAIL"
if [ -n "${MAGIC_LINK:-}" ]; then
  echo "  Magic:    $MAGIC_LINK"
  echo "            (also in: docker logs trigger-webapp)"
else
  echo "  Magic:    open $url/login, enter $ADMIN_EMAIL, then:"
  echo "              docker logs trigger-webapp 2>&1 | grep magic"
fi
echo "  Sign-ups are locked to WHITELISTED_EMAILS in $ENV_FILE."
echo
echo "Deploy a TypeScript cron / job from this box:"
echo "  npx trigger.dev@4.6.0 login -a $url"
echo "  npx trigger.dev@4.6.0 init"
echo "  npx trigger.dev@4.6.0 deploy"
echo "  (Host docker is already logged into $REGISTRY_URL.)"
echo
echo "Backups: nothing backs this box up. State lives under $STATE"
echo "  (Postgres + Redis + MinIO + registry + the worker token)."
echo "  Cold copy:  docker compose --project-directory $SERVICE_DIR stop &&"
echo "              tar czf trigger-dev-\$(date +%F).tgz -C $STATE . &&"
echo "              docker compose --project-directory $SERVICE_DIR start"
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: bump TRIGGER_IMAGE_TAG in .env, then"
echo "         docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"
exit 0
