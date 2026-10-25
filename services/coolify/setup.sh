#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Coolify (self-hosted PaaS) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - coolify + postgres + redis + soketi on a private compose network
#   - dashboard published on 127.0.0.1:LOCAL_PORT only (default 8101 —
#     OpenHands already owns :8000, Coolify's upstream default)
#   - Soketi (realtime) on 127.0.0.1:SOKETI_PORT (default 6001)
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - first admin created from ROOT_USER_* in .env (no open registration window)
#   - boot-persistent via Docker's restart policy (no systemd/launchd)
#
# Usage:
#   ./setup.sh
#   LOCAL_PORT=8102 ./setup.sh            # HTTPS follows LOCAL_PORT
#   LOCAL_PORT=8102 HTTPS_PORT=8102 ./setup.sh
#   ROOT_USERNAME=admin ./setup.sh          # first run only; .env wins after
#
# Version: pinned to Coolify 4.3.21 + coolify-realtime 1.0.19.
# Coolify's in-app auto-update is off (it would rewrite compose and undo
# the loopback binds). Bump COOLIFY_VERSION in .env, then re-run.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
# ssh-keygen is optional — without it the dashboard still works, but Coolify
# cannot SSH to this box to deploy apps onto it.
#
# Idempotent: safe to re-run; it upgrades the images and repairs the publish.
# An existing .env is never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8101}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
SOKETI_PORT="${SOKETI_PORT:-6001}"
HTTPS_SOKETI_EXPLICIT="${HTTPS_SOKETI_PORT:+yes}"
HTTPS_SOKETI_PORT="${HTTPS_SOKETI_PORT:-$SOKETI_PORT}"
ROOT_USERNAME="${ROOT_USERNAME:-admin}"
ROOT_USER_EMAIL="${ROOT_USER_EMAIL:-admin@example.com}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/coolify"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars: URL-safe, survives .env without quoting.
randhex() {
  local n="${1:-16}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_hex($n))"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# Laravel APP_KEY: "base64:" + 32 random bytes, standard encoding.
app_key() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'base64:%s\n' "$(openssl rand -base64 32 | tr -d '\n')"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,base64; print("base64:"+base64.b64encode(os.urandom(32)).decode())'
  else
    die "Need openssl or python3 to generate APP_KEY."
  fi
}

# Coolify's installer rejects passwords that are not mixed-class.
# Upper + lower + digit + a quoting-safe special, then 20 alnum.
randpass() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets,string
u=secrets.choice(string.ascii_uppercase)
l=secrets.choice(string.ascii_lowercase)
d=secrets.choice(string.digits)
s=secrets.choice("@%*+-=")
r="".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20))
print(u+l+d+s+r)'
  else
    printf 'K%s1@\n' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  fi
}

# Coolify's image runs as uid 9999. A 0700 host-owned bind mount makes
# SSH-key reads and application-dir writes fail with EACCES. Grant 9999
# write without sudo, same pattern as services/openhands/setup.sh for uid 10001.
grant_coolify_write() {
  local d uid=9999
  for d in "$@"; do
    [ -e "$d" ] || continue
    if command -v setfacl >/dev/null 2>&1 \
       && setfacl -m "u:${uid}:rwx" "$d" 2>/dev/null \
       && { [ ! -d "$d" ] || setfacl -d -m "u:${uid}:rwx" "$d" 2>/dev/null; }; then
      continue
    fi
    if [ -d "$d" ]; then
      chmod a+rwx "$d" 2>/dev/null || true
    else
      # Never world-open a private key. Directories above may fall
      # back to a+rwx; files that Coolify must read (the SSH key)
      # go through grant_coolify_key instead.
      warn "setfacl failed for $d; skipped chmod fallback (will not world-open a file)"
    fi
  done
}

# uid 9999 must read the unencrypted SSH private key. ACL only — a
# chmod a+rw fallback would let any local account steal the key and
# SSH in as this Docker-capable user.
grant_coolify_key() {
  local f uid=9999
  for f in "$@"; do
    [ -f "$f" ] || continue
    if command -v setfacl >/dev/null 2>&1 \
       && setfacl -m "u:${uid}:r" "$f" 2>/dev/null; then
      continue
    fi
    warn "No ACL on $f — left owner-only (0600). Coolify (uid $uid) may not read this key; dashboard SSH to localhost will fail until setfacl is available. Will not world-open the private key."
  done
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
case "$SOKETI_PORT" in ''|*[!0-9]*) die "SOKETI_PORT must be numeric (got: $SOKETI_PORT)";; esac
case "$HTTPS_SOKETI_PORT" in ''|*[!0-9]*) die "HTTPS_SOKETI_PORT must be numeric (got: $HTTPS_SOKETI_PORT)";; esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# Official wants 2 GB just for Coolify. This box shares 7.7 GB with ollama.
# Warn, do not refuse — mem_limits are the backstop.
avail_mb=""
if [ -r /proc/meminfo ]; then
  avail_mb="$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' /proc/meminfo)"
  avail_mb="$(( avail_mb / 1024 ))"
fi
if [ -n "${avail_mb:-}" ] && [ "$avail_mb" -lt 800 ]; then
  warn "Only ~${avail_mb} MB RAM available. Coolify idles a few hundred MiB with the caps in docker-compose.yml; unload ollama or stop another service if the dashboard gets OOM-killed."
fi

if [ "$OS" = "Darwin" ]; then
  warn "Coolify's localhost-server SSH path is a Linux workflow. The dashboard will still publish. Deploying apps onto this Mac through Coolify is unverified."
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated APP_KEY, DB/Redis/Pusher secrets, admin password)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  elif [ -f /etc/timezone ]; then
    tz="$(cat /etc/timezone)"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose interpolates this file AND the Coolify container bind-mounts
# it at /var/www/html/.env (Laravel). First-boot ROOT_USER_* seeding needs
# that mount — do not switch this to interpolation-only.

# Pinned. Official floats \`latest\`. Coolify's in-app updater is off
# (AUTOUPDATE=false) because it rewrites compose and would undo loopback
# binds. To upgrade: bump these two, then ./setup.sh.
COOLIFY_VERSION=4.3.21
COOLIFY_REALTIME_VERSION=1.0.19
REGISTRY_URL=docker.io

LOCAL_PORT=$LOCAL_PORT
SOKETI_PORT=$SOKETI_PORT
SOKETI_METRICS_PORT=6002
TZ=$tz
APP_NAME=Coolify
APP_ENV=production
APP_DEBUG=false
AUTOUPDATE=false

# Runtime state. Moving a path means moving the directory too.
COOLIFY_DATA=$STATE
COOLIFY_SSH=$STATE/ssh
COOLIFY_APPLICATIONS=$STATE/applications
COOLIFY_DATABASES=$STATE/databases
COOLIFY_SERVICES=$STATE/services
COOLIFY_BACKUPS=$STATE/backups
COOLIFY_IMAGES=$STATE/images

# Public identity. Laravel builds redirects and notification links from
# APP_URL, so it must be the tailnet HTTPS URL, no trailing slash. If the
# machine is renamed or the HTTPS port moves, edit APP_URL and re-run —
# setup.sh warns when it drifts.
APP_URL=https://$TS_HOST:$HTTPS_PORT

# Caps for a 7.7 GB box. PHP_FPM_PM_MAX_SPARE_SERVERS is 5 here, not the
# image's 10 — 10 workers × 256M is a 2.5 GB worst case.
COOLIFY_MEM_LIMIT=768m
COOLIFY_DB_MEM_LIMIT=256m
COOLIFY_REDIS_MEM_LIMIT=128m
COOLIFY_SOKETI_MEM_LIMIT=256m
PHP_MEMORY_LIMIT=256M
PHP_FPM_PM_MAX_SPARE_SERVERS=5

# First admin. Coolify seeds this on first boot so /register is never an
# open "whoever loads the page first is root" window. Password must stay
# mixed-class (upper, lower, digit, special) — Coolify's installer rejects
# weaker ones. Changing it in the UI does not update this file.
ROOT_USERNAME=$ROOT_USERNAME
ROOT_USER_EMAIL=$ROOT_USER_EMAIL
ROOT_USER_PASSWORD=$(randpass)

# Laravel + DB + Redis + Soketi secrets. Rotating APP_KEY later makes
# anything already encrypted unreadable.
APP_ID=$(randhex)
APP_KEY=$(app_key)
DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_USERNAME=coolify
DB_DATABASE=coolify
DB_PASSWORD=$(randhex 24)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(randhex 24)
PUSHER_APP_ID=$(randhex 16)
PUSHER_APP_KEY=$(randhex 16)
PUSHER_APP_SECRET=$(randhex 16)

# Browser talks to Soketi over Tailscale Serve (wss). Backend talks to
# coolify-realtime on the compose network over plain HTTP. Sharing
# PUSHER_SCHEME=https for both is a known Coolify bug (backend then TLS-
# handshakes a plaintext socket). Keep the backend on http via the
# dedicated host/port, and the browser on https via PUSHER_HOST.
PUSHER_HOST=$TS_HOST
PUSHER_PORT=$HTTPS_SOKETI_PORT
PUSHER_SCHEME=https
PUSHER_BACKEND_HOST=coolify-realtime
PUSHER_BACKEND_PORT=6001
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
REQUESTED_SOKETI="$SOKETI_PORT"
set -a; . "$ENV_FILE"; set +a
ROOT_USERNAME="${ROOT_USERNAME:?ROOT_USERNAME missing from $ENV_FILE}"
ROOT_USER_EMAIL="${ROOT_USER_EMAIL:?ROOT_USER_EMAIL missing from $ENV_FILE}"
ROOT_USER_PASSWORD="${ROOT_USER_PASSWORD:?ROOT_USER_PASSWORD missing from $ENV_FILE}"
DATA_DIR="${COOLIFY_DATA:?COOLIFY_DATA missing from $ENV_FILE}"
APP_URL="${APP_URL:?APP_URL missing from $ENV_FILE}"
COOLIFY_SSH="${COOLIFY_SSH:?COOLIFY_SSH missing from $ENV_FILE}"
COOLIFY_APPLICATIONS="${COOLIFY_APPLICATIONS:?COOLIFY_APPLICATIONS missing from $ENV_FILE}"
COOLIFY_DATABASES="${COOLIFY_DATABASES:?COOLIFY_DATABASES missing from $ENV_FILE}"
COOLIFY_SERVICES="${COOLIFY_SERVICES:?COOLIFY_SERVICES missing from $ENV_FILE}"
COOLIFY_BACKUPS="${COOLIFY_BACKUPS:?COOLIFY_BACKUPS missing from $ENV_FILE}"
COOLIFY_IMAGES="${COOLIFY_IMAGES:?COOLIFY_IMAGES missing from $ENV_FILE}"
SOKETI_PORT="${SOKETI_PORT:-6001}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
if [ "$SOKETI_PORT" != "$REQUESTED_SOKETI" ]; then
  warn "SOKETI_PORT=$REQUESTED_SOKETI ignored — the existing $ENV_FILE says $SOKETI_PORT. Edit .env and re-run to move the port."
fi
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"
[ -n "$HTTPS_SOKETI_EXPLICIT" ] || HTTPS_SOKETI_PORT="$SOKETI_PORT"

WANT_APP_URL="https://$TS_HOST:$HTTPS_PORT"
if [ "$APP_URL" != "$WANT_APP_URL" ]; then
  warn "APP_URL in .env is $APP_URL but this box now answers to $WANT_APP_URL."
  warn "  Redirects and notification links will point at the old address. Fix: set APP_URL=$WANT_APP_URL in $ENV_FILE, then re-run."
fi

mkdir -p "$DATA_DIR" "$COOLIFY_SSH/keys" \
  "$COOLIFY_APPLICATIONS" "$COOLIFY_DATABASES" "$COOLIFY_SERVICES" \
  "$COOLIFY_BACKUPS" "$COOLIFY_IMAGES"
grant_coolify_write "$DATA_DIR" "$COOLIFY_SSH" "$COOLIFY_SSH/keys" \
  "$COOLIFY_APPLICATIONS" "$COOLIFY_DATABASES" "$COOLIFY_SERVICES" \
  "$COOLIFY_BACKUPS" "$COOLIFY_IMAGES"

avail_kb="$(df -Pk "$DATA_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 10485760 ]; then
  warn "$(( avail_kb / 1048576 )) GB free at $DATA_DIR — Coolify wants ~10 GB plus whatever you later deploy through it."
else
  ok "$(( avail_kb / 1048576 )) GB free at $DATA_DIR"
fi

# -------------------------------------------------------- localhost SSH key
# Coolify SSHes to host.docker.internal as this user to run docker on the
# box (deploy an app, start a database). Official install.sh does this as
# root into /data/coolify and root's authorized_keys. We stay in $HOME.
KEY_BASE="$COOLIFY_SSH/keys/id.${USER}@host.docker.internal"
if [ -f "$KEY_BASE" ]; then
  ok "SSH key already present: $KEY_BASE"
else
  if command -v ssh-keygen >/dev/null 2>&1; then
    info "Generating an ed25519 key so Coolify can SSH to this box as $USER"
    ssh-keygen -t ed25519 -a 100 -f "$KEY_BASE" -q -N "" -C "coolify"
    ok "Wrote $KEY_BASE"
  else
    warn "ssh-keygen not on PATH — Coolify cannot SSH to this box. The dashboard will still work. Install openssh-client and re-run to add the key."
  fi
fi
if [ -f "$KEY_BASE" ]; then
  grant_coolify_key "$KEY_BASE"
  chmod 0644 "${KEY_BASE}.pub" 2>/dev/null || true
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  auth="$HOME/.ssh/authorized_keys"
  touch "$auth"
  chmod 600 "$auth"
  pub_line="$(cat "${KEY_BASE}.pub" 2>/dev/null || true)"
  if [ -n "$pub_line" ]; then
    # Present = an active (uncommented) entry carrying the same key data,
    # whatever its comment or from=/command= options, so a re-run never
    # appends an unrestricted copy next to an entry the operator locked down.
    key_blob="$(printf '%s\n' "$pub_line" | awk '{ print $2; exit }')"
    if [ -n "$key_blob" ] && awk -v b="$key_blob" '
        /^[[:space:]]*(#|$)/ { next }
        { for (i = 1; i <= NF; i++) if ($i == b) { found = 1; exit } }
        END { exit found ? 0 : 1 }' "$auth" 2>/dev/null; then
      ok "Coolify pubkey already in $auth"
    else
      # A last line without a newline would get the key glued onto it,
      # breaking both keys. $(...) strips a trailing newline, so a
      # non-empty last byte means the file does not end in one.
      if [ -s "$auth" ] && [ -n "$(tail -c 1 "$auth")" ]; then
        printf '\n' >> "$auth"
      fi
      printf '%s\n' "$pub_line" >> "$auth"
      ok "Added Coolify pubkey to $auth (SSH as $USER, not root)"
    fi
  fi
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Starting Coolify (docker compose up -d) — first run pulls several hundred MB"
"${COMPOSE[@]}" up -d

info "Waiting for Coolify on 127.0.0.1:$LOCAL_PORT (first boot runs migrations)"
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/api/health" 2>/dev/null; then
    ok "Coolify is answering locally"
    break
  fi
  [ "$i" -eq 90 ] && die "Coolify did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs coolify"
  sleep 3
done

# ------------------------------------------------------- tailscale serve
serve_https() {
  local https_port="$1" local_port="$2" required="$3"
  info "Publishing via Tailscale Serve (HTTPS :$https_port -> 127.0.0.1:$local_port)"
  if ! "$TAILSCALE" serve --bg --https="$https_port" "http://127.0.0.1:$local_port" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Direct serve failed — trying operator grant (needs sudo, one time)"
      sudo tailscale set --operator="$USER"
    fi
    if [ "$required" = "yes" ]; then
      until "$TAILSCALE" serve --bg --https="$https_port" "http://127.0.0.1:$local_port"; do
        echo
        info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
        read -r
      done
    else
      if ! "$TAILSCALE" serve --bg --https="$https_port" "http://127.0.0.1:$local_port"; then
        warn "Could not publish :$https_port (Soketi). Live logs in the dashboard may not stream until this works: tailscale serve --bg --https=$https_port http://127.0.0.1:$local_port"
        return 0
      fi
    fi
  fi
  ok "Tailscale Serve: HTTPS :$https_port -> http://127.0.0.1:$local_port"
}

# Do not publish until the first-run admin form is gone. Whoever
# submits /register owns the instance.
assert_register_closed() {
  local base="$1" code body
  code="$(curl -sS -o "$WORK/register.html" -w '%{http_code}' --max-time 30 \
    -L "$base/register" 2>/dev/null || echo 000)"
  body="$(cat "$WORK/register.html" 2>/dev/null || true)"
  case "$code" in
    200)
      case "$body" in
        *[Cc]reate*[Aa]ccount*|*"Root User"*|*"root user"*)
          die "GET $base/register still looks like the first-run admin form (HTTP $code). ROOT_USER_* in $ENV_FILE did not seed. Not publishing — whoever submits that form owns the instance."
          ;;
      esac
      ;;
  esac
}

assert_register_closed "http://127.0.0.1:$LOCAL_PORT"

serve_https "$HTTPS_PORT" "$LOCAL_PORT" yes
serve_https "$HTTPS_SOKETI_PORT" "$SOKETI_PORT" no

# ------------------------------------------------------------ final check
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url/api/health (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/api/health"; then
  ok "End-to-end HTTPS check passed"
else
  warn "No answer on $url/api/health yet — the cert may still be minting. Retry in a minute: curl $url/api/health"
fi

# A 200 on /api/health does not prove the first-admin seed ran. The open
# registration page is how a stranger on the tailnet becomes root. If we
# still see that form, say so loudly.
reg_code="$(curl -sS -o "$WORK/register.html" -w '%{http_code}' --max-time 30 \
  -L "$url/register" 2>/dev/null || echo 000)"
reg_body="$(cat "$WORK/register.html" 2>/dev/null || true)"
case "$reg_code" in
  200)
    case "$reg_body" in
      *[Cc]reate*[Aa]ccount*|*"Root User"*|*"root user"*)
        die "GET /register still looks like the first-run admin form after Serve (HTTP $reg_code). ROOT_USER_* in $ENV_FILE did not seed. Drop the mapping: tailscale serve --https=$HTTPS_PORT off"
        ;;
      *)
        ok "Registration page is not the open first-run form"
        ;;
    esac
    ;;
  302|301|303|307|308|401|403|404)
    ok "Registration is not an open first-run form (HTTP $reg_code)"
    ;;
  *)
    warn "Could not check /register (HTTP $reg_code). Confirm the first login yourself: $url"
    ;;
esac

echo
printf '\033[1;32mDone.\033[0m Coolify is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "  Login:    $ROOT_USERNAME  ($ROOT_USER_EMAIL)"
echo "  Password: see ROOT_USER_PASSWORD in $ENV_FILE"
echo "  Realtime: wss://$TS_HOST:$HTTPS_SOKETI_PORT  (Soketi, also Serve-published)"
echo
echo "  Do not start Coolify's Traefik proxy on :80/:443. Upstream binds those"
echo "  on every interface, which would publish this box to the LAN. Deployed"
echo "  apps should publish a loopback port and get their own"
echo "  \`tailscale serve --bg --https=<port> http://127.0.0.1:<port>\`."
echo
echo "  Localhost server in the UI: SSH user is $USER (not root), key is"
echo "  $KEY_BASE"
echo "  Coolify's in-app updater is off. Upgrade: bump COOLIFY_VERSION in"
echo "  $ENV_FILE then ./setup.sh"
echo
echo "Backups: nothing backs this box up. APP_KEY in $ENV_FILE encrypts the"
echo "  database — keep a copy off-box with the Postgres volume:"
echo "    docker compose --project-directory $SERVICE_DIR exec -T postgres \\"
echo "      pg_dump -U coolify coolify > coolify-\$(date +%F).sql"
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: edit COOLIFY_VERSION in .env, then ./setup.sh"
exit 0
