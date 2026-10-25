#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Paperless-ngx (an OCR'd, full-text-searchable
# document archive) behind Tailscale. Linux + macOS.
#
# End state:
#   - two containers: `paperless-ngx` (the app) and `paperless-redis` (the
#     celery broker, reachable only on the compose network)
#   - SQLite, not Postgres — one less container on a RAM-tight box
#   - the app on 127.0.0.1:LOCAL_PORT, published tailnet-only at
#     https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - an admin account created on first boot from a generated password, so no
#     default credential is ever live
#   - a drop folder at ~/services/paperless-ngx/consume owned by you: copy a
#     PDF or a photo of a receipt into it and it gets OCR'd and filed
#
# Usage:
#   ./setup.sh                                # local 8095, HTTPS 8095
#   LOCAL_PORT=8096 ./setup.sh                # HTTPS follows LOCAL_PORT (8096 -> 8096)
#   LOCAL_PORT=8095 HTTPS_PORT=8095 ./setup.sh
#   PAPERLESS_ADMIN_USER=admin ./setup.sh       # first run only; .env wins after
#   ./setup.sh --stop                         # stop it, keep the data
#   ./setup.sh --down                         # remove the containers, keep the data
#
# ---------------------------------------------------------------------------
# THE TWO THINGS THAT MAKE THIS DEPLOY DIFFERENT FROM THE REST OF THE REPO
#
# 1. THE VERIFY STEP HAS TO POST, NOT GET. Django compares the browser's
#    Origin header against CSRF_TRUSTED_ORIGINS as an exact string, scheme and
#    port included. Tailscale Serve terminates TLS and proxies plain HTTP, so
#    Django's idea of the request scheme is http:// while the browser says
#    https:// — and the login POST is rejected 403 unless PAPERLESS_URL puts
#    the external https URL in the trusted list.
#
#    Measured with PAPERLESS_URL removed and nothing else changed: every GET
#    still returns exactly what it returned before (/ -> 302,
#    /accounts/login/ -> 200, /api/remote_version/ -> 200) and only the login
#    POST changes, to 403. A deploy that curls a page, sees 200 and declares
#    success hands back an archive nobody can get into. So the verify step
#    below sends a real browser-shaped POST. It needs no password to do it:
#    Django rejects a bad origin BEFORE it looks at the CSRF token, and the
#    two rejections render distinguishable pages.
#
# 2. THE MEMORY LIMIT LOSES DOCUMENTS IF YOU SIZE IT OFF IDLE. Paperless idles
#    at ~660 MB and peaks far above that while OCR'ing. At a 1 GB limit the
#    OOM killer took the celery child during an ordinary 10-page 300 dpi scan:
#    the container stayed `running`, kept reporting `(healthy)`, the web UI
#    stayed responsive, the file stayed in consume/ and no document ever
#    appeared. See the long note in docker-compose.yml; this script checks
#    .State.OOMKilled on every run because nothing else would notice.
# ---------------------------------------------------------------------------
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged
# in, ~4 GB of disk for the image, and ~700 MB of free RAM.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# An existing .env is never overwritten. The admin account is created at most
# once — measured against this image, Paperless creates the superuser only if
# it does not already exist and never touches it again, so a re-run can NOT
# stomp a password you changed in the web UI (and cannot repair one either;
# once changed, the value in .env is stale documentation).

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8095}"
# The HTTPS port follows the local port unless set explicitly (the n8n and
# kaichenpedia convention), so overriding only LOCAL_PORT cannot split the
# two. Unlike immich, .env below stores HTTPS_PORT and the read-back further
# down re-sources it unconditionally, so there is nothing left to track past
# the first deploy, no HTTPS_PORT_EXPLICIT flag needed here.
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
ADMIN_USERNAME="${PAPERLESS_ADMIN_USER:-admin}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/paperless-ngx"

# The unauthenticated path that returns a real 200. Measured against this
# image: `/` is a 302, `/api/` is a 302, `/healthz` is a 302 and `/api/status/`
# is a 401. Only `/accounts/login/` and `/api/remote_version/` answer 200, and
# of those only the login page is purely local (the other reaches out to check
# for upstream releases). Uptime Kuma scores a 302 as DOWN, so which path is
# used here is not a detail.
HEALTH_PATH="/accounts/login/"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# 700. Holds captured compose stderr and HTTP response bodies. Nothing secret
# goes in here — unlike adguard, no credential is ever POSTed by this script —
# but it is cleaned up on every exit path regardless.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hex, so the value survives .env sourcing, YAML, shell quoting and a URL
# without a single escape. python3 when present, /dev/urandom otherwise.
randhex() {  # randhex <bytes>
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"
  else
    od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# --------------------------------------------------------- stop / down paths
# The workflow for this round is deploy → verify → stop, and this is the
# heaviest service on the box, so the off switch deserves to be a documented
# first-class path rather than a line in the closing banner.
#
# Neither of these touches ${PAPERLESS_ROOT}: `down` removes containers and
# the compose network, not the bind mounts. The archive survives both, and
# re-running setup.sh brings it back exactly as it was.
case "${1:-}" in
  --stop|stop)
    info "Stopping Paperless-ngx (data in $STATE is left alone)"
    docker compose --project-directory "$SERVICE_DIR" stop
    ok "Stopped. Start again with: ./setup.sh"
    exit 0
    ;;
  --down|down)
    info "Removing the Paperless-ngx containers (data in $STATE is left alone)"
    docker compose --project-directory "$SERVICE_DIR" down
    ok "Containers removed. The archive in $STATE is untouched."
    echo "  Re-deploy with: ./setup.sh"
    echo "  The tailnet publish is separate and still in place. To remove it:"
    echo "    tailscale serve --https=$HTTPS_PORT off"
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: $1 (expected nothing, --stop or --down)" ;;
esac

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root. The container remaps its internal user onto yours, so a root deploy produces an archive you cannot read."
command -v curl >/dev/null || die "curl is required."
if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi

if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The tailnet DNS name, and it is not cosmetic here. It becomes PAPERLESS_URL,
# which becomes CSRF_TRUSTED_ORIGINS, which is what decides whether anyone can
# log in. Resolved at deploy time rather than hardcoded: a literal hostname
# would be wrong on any other machine, and wrong in a way that produces a
# perfectly healthy Paperless with a login form that always says no.
#
# The trailing `|| true` is load-bearing, not noise. Under `set -euo pipefail`
# a command substitution whose pipeline fails makes the ASSIGNMENT fail, and
# errexit then kills the script on this line — before the emptiness check
# written to explain it. `grep -o` exits 1 when MagicDNS is off, which is
# exactly the case the message below exists for.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
[ -n "$TS_HOST" ] || die "Could not determine this node's tailnet DNS name (is MagicDNS enabled?). Paperless needs it: the external URL is what Django's CSRF check compares the browser's Origin header against, so without it nobody could log in."

# This node's tailnet addresses, for the listener audit only. LOCAL_PORT and
# HTTPS_PORT are the same number on this service, so tailscaled itself
# legitimately listens on the tailnet address for that port — the audit has to
# know to allow it, or a correct deploy reports itself as exposed. Non-fatal:
# unlike adguard, nothing here binds to these addresses.
TS_IP="$("$TAILSCALE" ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
TS_IP6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated secret key and admin password)"
  admin_pw="$(randhex 16)"     # 32 hex chars
  secret_key="$(randhex 32)"   # 64 hex chars
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
# It is NOT passed to the container as env_file — only the variables named
# explicitly in docker-compose.yml's \`environment:\` block reach the app.

# Pinned exactly. Everything in PAPERLESS-DERISK.md was measured against this
# version end to end. Paperless migrates the database on first start of a
# newer image and the migration is ONE-WAY: export before bumping this.
#   docker exec paperless-ngx document_exporter ../export
PAPERLESS_VERSION=3.1.3

# Loopback port for the app, and the tailnet HTTPS port Serve publishes on.
# They are the same number here, which is why the listener audit in setup.sh
# has to allow this node's own tailnet address on it.
LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT

# THE REVERSE-PROXY SETTING, and the one most likely to break a login.
#
# Django compares the browser's Origin header against CSRF_TRUSTED_ORIGINS as
# an EXACT string — scheme, host and port. Tailscale Serve terminates TLS and
# proxies plain HTTP, so Django computes http://<host>:$HTTPS_PORT while the
# browser sends https://<host>:$HTTPS_PORT. The POST is only allowed because
# this variable puts the https form in the trusted list.
#
# If you move HTTPS_PORT above, you MUST change this to match, or every GET
# will keep returning 200 and the login POST will start returning 403 with
# nothing useful in the page. setup.sh recomputes the expected value on every
# run and warns if this has drifted; its verify step then fails outright.
PAPERLESS_URL=https://$TS_HOST:$HTTPS_PORT

# Container names, so the test suite and the ops commands agree with reality.
CONTAINER_NAME=paperless-ngx
REDIS_CONTAINER_NAME=paperless-redis

# Where the archive lives. Four subdirectories, created by setup.sh:
#   data/    db.sqlite3 (all metadata, tags, correspondents, users) and the
#            full-text index. The index rebuilds; the database does not.
#   media/   the original files plus the OCR'd PDF/A archive copies. THIS IS
#            THE ARCHIVE.
#   consume/ the drop folder — copy a PDF or a photo here and it gets filed.
#   export/  where \`document_exporter\` writes.
#
# THERE IS NO BACKUP OF THIS BOX. data/ and media/ together are the whole
# archive and they exist in exactly one place. The portable way to copy them
# off is the exporter, which writes documents plus a manifest:
#   docker exec paperless-ngx document_exporter ../export
#   tar czf paperless-\$(date +%F).tgz -C $STATE export
PAPERLESS_ROOT=$STATE

# The admin account, created on FIRST BOOT ONLY.
#
# Measured against this image: Paperless runs its superuser command on every
# start, and that command returns early the moment this username is taken or
# any superuser exists. It never calls set_password. So:
#   * a re-run of setup.sh cannot overwrite a password you changed in the UI
#   * and cannot repair one either — once you change it in the web UI, the
#     value below is stale documentation, not a live credential
# Change it in the UI if you want something memorable, then either update the
# line below or delete it to avoid being misled later.
PAPERLESS_ADMIN_USER=$ADMIN_USERNAME
PAPERLESS_ADMIN_PASSWORD=$admin_pw

# Django's signing key: sessions, password-reset tokens, document share links.
# Changing it logs everyone out and invalidates every outstanding share link.
# The container refuses to start if this is empty or the literal "change-me".
PAPERLESS_SECRET_KEY=$secret_key

# Dates are filed and rendered in this zone (and log timestamps use it too).
# Taken from this host's /etc/localtime at first run.
PAPERLESS_TIME_ZONE=$tz

# Tesseract language packs. \`eng\` keeps OCR fast and the footprint small;
# "eng+deu" style lists work and are downloaded on the next start. Each extra
# language costs OCR time and memory on a box that has little of either.
PAPERLESS_OCR_LANGUAGE=eng

# The container's internal \`paperless\` user is remapped onto these, so
# everything under PAPERLESS_ROOT stays owned by you — you can drop files into
# consume/ and tar up media/ without sudo. Resolved from the deploying user.
PAPERLESS_UID=$(id -u)
PAPERLESS_GID=$(id -g)
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE (mode 600 — it holds the secret key and the admin password)"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_LOCAL="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
LOCAL_PORT="${LOCAL_PORT:?LOCAL_PORT missing from $ENV_FILE}"
HTTPS_PORT="${HTTPS_PORT:?HTTPS_PORT missing from $ENV_FILE}"
ADMIN_USERNAME="${PAPERLESS_ADMIN_USER:?PAPERLESS_ADMIN_USER missing from $ENV_FILE}"
PAPERLESS_ROOT="${PAPERLESS_ROOT:?PAPERLESS_ROOT missing from $ENV_FILE}"
CONTAINER="${CONTAINER_NAME:-paperless-ngx}"
REDIS_CONTAINER="${REDIS_CONTAINER_NAME:-paperless-redis}"
: "${PAPERLESS_SECRET_KEY:?PAPERLESS_SECRET_KEY missing from $ENV_FILE — the container will not start without it}"
: "${PAPERLESS_ADMIN_PASSWORD:?PAPERLESS_ADMIN_PASSWORD missing from $ENV_FILE — without it no admin account is created and nobody can log in}"

if [ "$LOCAL_PORT" != "$REQUESTED_LOCAL" ]; then
  warn "LOCAL_PORT=$REQUESTED_LOCAL ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi

# Drift check, not a rewrite: .env is the user's file. But a stale
# PAPERLESS_URL is the one piece of drift with a genuinely confusing symptom —
# everything looks healthy and the login POST 403s — so it gets named out loud
# here as well as failing the verify step at the end.
WANT_URL="https://$TS_HOST:$HTTPS_PORT"
if [ "${PAPERLESS_URL:-}" != "$WANT_URL" ]; then
  warn "PAPERLESS_URL in .env is '${PAPERLESS_URL:-unset}' but this node + port say '$WANT_URL'."
  warn "  Django compares the browser's Origin header against that string exactly, so while they"
  warn "  disagree every page will load fine over HTTPS and the login POST will return 403."
  warn "  Fix: set PAPERLESS_URL=$WANT_URL in $ENV_FILE and re-run."
fi

# ---------------------------------------------------------------- state dirs
# Created here, before the container mounts them, and that ordering matters:
# Docker creates a missing bind-mount source as a ROOT-owned directory. Get it
# wrong and consume/ is a folder you cannot drop a file into without sudo,
# which surfaces as "I copied a PDF in and nothing happened" rather than as a
# permission error.
info "Preparing $PAPERLESS_ROOT"
mkdir -p "$PAPERLESS_ROOT/data" "$PAPERLESS_ROOT/media" \
         "$PAPERLESS_ROOT/consume" "$PAPERLESS_ROOT/export"
# 0700 on the root: the archive is scans of your bank statements and passport.
# Not applied recursively — the container manages what is inside.
chmod 700 "$PAPERLESS_ROOT" 2>/dev/null || true
[ -w "$PAPERLESS_ROOT/consume" ] || die "$PAPERLESS_ROOT/consume is not writable by you. If it is root-owned, Docker created it before this script did: sudo chown -R $(id -u):$(id -g) $PAPERLESS_ROOT"

# The image is ~3.5 GB on disk and the archive grows with every scan. `|| true`
# for the same reason as TS_HOST above: pipefail would turn a df that cannot
# stat the path into a silent exit 1, and the ${avail_kb:-0} fallback written
# to tolerate exactly that would never be reached.
avail_kb="$(df -Pk "$PAPERLESS_ROOT" | awk 'NR==2{print $4}' || true)"
if [ "${avail_kb:-0}" -lt 5242880 ]; then
  warn "$(( ${avail_kb:-0} / 1024 )) MB free at $PAPERLESS_ROOT — the image alone needs ~3.5 GB, plus the archive."
else
  ok "$(( avail_kb / 1048576 )) GB free at $PAPERLESS_ROOT"
fi

# A word about RAM, because this is the heaviest service in the repo and the
# box is small. Measured idle: ~660 MB for the app, 4 MB for redis.
avail_mb=""
if [ -r /proc/meminfo ]; then
  avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo || true)"
fi
if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 900 ]; then
  warn "Only ${avail_mb} MB of RAM available. Paperless idles at ~660 MB and peaks above 1 GB while OCR'ing; this deploy may swap. Consider stopping something first (./setup.sh --stop turns this back off)."
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

# Pulled as its own step so the ~800 MB first-run download shows progress —
# `up -d` below has its stderr captured for the error triage, and a silent
# five-minute pause is not what a one-shot deploy should look like. A failed
# pull is a warning, not a death: the pinned image may already be cached, and
# a re-run with no network should still repair the deploy.
info "Fetching images (first run pulls ~800 MB — the OCR stack is large)"
"${COMPOSE[@]}" pull 2>&1 || warn "docker compose pull failed — continuing with whatever images are already cached locally."

info "Starting Paperless-ngx and redis (docker compose up -d)"
if ! "${COMPOSE[@]}" up -d 2>"$WORK/up.err"; then
  cat "$WORK/up.err" >&2
  case "$(cat "$WORK/up.err" 2>/dev/null || true)" in
    *"address already in use"*|*"port is already allocated"*|*"Bind for"*)
      die "Port conflict: something already holds 127.0.0.1:$LOCAL_PORT. Check with: ss -ltnp | grep ':$LOCAL_PORT ' — then either stop that service or set LOCAL_PORT and HTTPS_PORT in $ENV_FILE (remember PAPERLESS_URL has to move with HTTPS_PORT) and re-run." ;;
    *ImproperlyConfigured*|*SECRET_KEY*)
      die "The container refused to start because PAPERLESS_SECRET_KEY is unset or still the default. Check that line in $ENV_FILE — it must be a long random string. Delete $ENV_FILE and re-run to regenerate everything." ;;
    *"manifest unknown"*|*"not found"*)
      die "Image tag not found. PAPERLESS_VERSION in $ENV_FILE is '${PAPERLESS_VERSION:-unset}'; check it against the releases at github.com/paperless-ngx/paperless-ngx/releases." ;;
    *"no space left"*)
      die "Out of disk. The image needs ~3.5 GB. Free some space and re-run." ;;
    *)
      die "docker compose up failed. Logs: docker compose --project-directory $SERVICE_DIR logs" ;;
  esac
fi

# ------------------------------------------------------------- HTTP helpers
PL_CODE=""

pl() {  # pl URL [curl-args...] -> body in $WORK/resp, code in $PL_CODE
  local url="$1"; shift
  # curl already prints 000 to stdout when it cannot connect AND exits
  # non-zero, so a `|| echo 000` fallback CONCATENATES and turns a plain
  # connection failure into the nonsense code "000000" in the error message.
  # Take curl's own output and normalise anything unexpected.
  PL_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' \
             --max-time "${PL_TIMEOUT:-25}" "$@" "$url" 2>/dev/null)" || true
  case "$PL_CODE" in
    [0-9][0-9][0-9]) ;;
    *) PL_CODE=000 ;;
  esac
}

BASE="http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------- readiness
# A container that is `up` is not a server that is listening. On a first boot
# Paperless applies database migrations, builds the search index and creates
# the superuser before the web server binds anything, and during that window
# curl gets a genuine connection refusal — exit 7, http_code 000 — NOT a tidy
# 503. Measured cold on this box: 39-48 s. Jellyfin's deploy in this repo died
# on exactly this shape of race, so retry the 000 and only the 000.
info "Waiting for Paperless on 127.0.0.1:$LOCAL_PORT (a first boot runs migrations — measured 39-48 s)"
READY=0
attempt=1
while [ "$attempt" -le 60 ]; do
  pl "$BASE$HEALTH_PATH"
  case "$PL_CODE" in
    000) : ;;                   # not listening yet — migrations still running
    *)   READY=1; break ;;      # it answered; the verify step judges the code
  esac
  sleep 3
  attempt=$((attempt + 1))
done
if [ "$READY" = "1" ]; then
  ok "Paperless answered on 127.0.0.1:$LOCAL_PORT (HTTP $PL_CODE)"
else
  die "Paperless never accepted a connection on $BASE after 3 minutes. That is longer than a cold first boot takes, so something is wrong rather than slow. Logs: docker compose --project-directory $SERVICE_DIR logs webserver | tail -40"
fi

# --------------------------------------------------- the admin account
# Read out of the init log rather than guessed. The three possible lines are
# all meaningful, and one of them is a silent disaster: with no admin username
# in the environment Paperless skips account creation entirely, logs "Not
# creating superuser" and carries on serving a login page that nobody on earth
# can get past. Nothing else in this script or in `docker ps` would notice.
su_log="$("${COMPOSE[@]}" logs webserver 2>/dev/null | grep -i 'superuser' | tail -5 || true)"
case "$su_log" in
  *"Not creating superuser"*)
    die "Paperless started but created NO admin account — PAPERLESS_ADMIN_USER did not reach the container. You would get a working login page with no way in. Check that PAPERLESS_ADMIN_USER and PAPERLESS_ADMIN_PASSWORD are set in $ENV_FILE and named in docker-compose.yml's environment block." ;;
  *"Created superuser"*)
    ok "Admin account '$ADMIN_USERNAME' created (password: see PAPERLESS_ADMIN_PASSWORD in $ENV_FILE)" ;;
  *"already exists"*|*"already contains superusers"*)
    ok "Admin account already existed — left exactly as it is, password included" ;;
  *"has been set in the environment"*)
    die "Paperless refused to create the admin account because PAPERLESS_ADMIN_PASSWORD was empty. Set it in $ENV_FILE and re-run." ;;
  *)
    warn "Could not find the superuser line in the container log (it may have scrolled). Check you can sign in; if not: docker compose --project-directory $SERVICE_DIR logs webserver | grep -i superuser" ;;
esac

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

# ============================================================== VERIFY
# The part that matters. Everything above can succeed against an archive
# nobody can log into.
FAILED=0
fail() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; FAILED=1; }

echo
info "Verifying the deploy"

# --- 1. both containers are running ---------------------------------------
for c in "$CONTAINER" "$REDIS_CONTAINER"; do
  run_state="$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || true)"
  if [ "$run_state" = "running" ]; then
    ok "Container '$c' is running"
  else
    fail "Container '$c' is '${run_state:-missing}', not running. Logs: docker compose --project-directory $SERVICE_DIR logs"
  fi
done

# --- 2. was anything OOM-killed? ------------------------------------------
# Checked explicitly because it is the one failure here that hides completely.
# Docker's OOM killer takes a celery child, not PID 1, so the container stays
# `running`, keeps reporting `(healthy)`, the web UI stays responsive — and
# documents dropped into consume/ silently never appear. Measured: this is
# exactly what a 1 GB mem_limit does to an ordinary 10-page 300 dpi scan.
oom="$(docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || true)"
if [ "$oom" = "true" ]; then
  warn "Docker reports this container has been OOM-killed. The OCR worker is the"
  warn "  usual victim, and the symptom is documents that never appear while"
  warn "  everything looks healthy. Raise mem_limit for the webserver in"
  warn "  $SERVICE_DIR/docker-compose.yml (currently sized for a 10-page 300 dpi"
  warn "  scan), then: docker compose --project-directory $SERVICE_DIR up -d"
fi

# --- 3. the health path really is an unauthenticated 200 ------------------
pl "$BASE$HEALTH_PATH"
case "$PL_CODE" in
  200) ok "Local health: $BASE$HEALTH_PATH returns 200" ;;
  400) fail "$BASE$HEALTH_PATH returns 400 — Django is rejecting the Host header. Something has narrowed PAPERLESS_ALLOWED_HOSTS: Django appends 'localhost' to a narrowed list but never '127.0.0.1', so the browser keeps working while every local check breaks. Remove PAPERLESS_ALLOWED_HOSTS and let it default to [\"*\"]; the tailnet is the boundary here, not a host list." ;;
  *)   fail "$BASE$HEALTH_PATH returned HTTP $PL_CODE (expected 200). Logs: docker compose --project-directory $SERVICE_DIR logs webserver | tail -40" ;;
esac

# Recorded, not judged: `/` is a 302 to the login page. It is here so that the
# Uptime Kuma monitor is never pointed at it by mistake — Kuma scores a 302 as
# DOWN, which reads as an outage on a perfectly healthy service.
pl "$BASE/"
[ "$PL_CODE" = "302" ] && ok "  / is a 302 to the login page, as expected — monitor $HEALTH_PATH, not /" \
  || warn "  / returned HTTP $PL_CODE (a 302 was expected). Harmless, but point any monitor at $HEALTH_PATH regardless."

# --- 4. THE ONE THAT MATTERS: can a browser actually log in? --------------
#
# Every check above passes identically whether or not the reverse-proxy
# settings are right. Measured with PAPERLESS_URL removed: / still 302,
# $HEALTH_PATH still 200, /api/remote_version/ still 200, and only a POST
# changes — to 403. curl never sends an Origin header on its own, so it cannot
# stumble into this; the header has to be set deliberately.
#
# No password is needed, which is the trick that makes this safe to run on
# every deploy. Django checks the origin BEFORE the CSRF token, and renders a
# distinguishable page for each:
#
#   origin trusted, no cookie -> 403 ... "requires a CSRF cookie"   GOOD
#   origin not trusted        -> 403 without that sentence          BAD
#
# Both were measured against this image through a real Serve mount. Sending a
# throwaway username also means a failure here can never lock an account or
# count against a rate limit.
info "Checking that a browser-shaped login POST is accepted through Serve"
pl "$BASE$HEALTH_PATH" -X POST \
  -H "Origin: $WANT_URL" \
  -H "Referer: $WANT_URL$HEALTH_PATH" \
  -d 'login=deploy-probe&password=deploy-probe'
if grep -q 'requires a CSRF cookie' "$WORK/resp" 2>/dev/null; then
  ok "CSRF origin '$WANT_URL' is trusted — a real browser can log in (HTTP $PL_CODE, rejected only for the missing cookie, which is correct for this probe)"
elif [ "$PL_CODE" = "403" ]; then
  fail "A browser-origin login POST was rejected as a BAD ORIGIN (HTTP 403). Every page on this deployment loads fine and NOBODY CAN LOG IN."
  fail "  Cause: PAPERLESS_URL must be exactly the external tailnet HTTPS URL, scheme and port included. Expected: $WANT_URL"
  fail "  In .env it is:   ${PAPERLESS_URL:-unset}"
  fail "  In the container: $(docker exec "$CONTAINER" printenv PAPERLESS_URL 2>/dev/null || echo '(could not read)')"
  fail "  Fix that line in $ENV_FILE and re-run. Confirm with: docker compose --project-directory $SERVICE_DIR logs webserver | grep -i 'Origin checking failed'"
elif [ "$PL_CODE" = "000" ]; then
  fail "The login POST got no answer at all (connection failed), though a GET succeeded a moment ago. Re-run; if it persists, read the logs."
else
  warn "The login POST returned HTTP $PL_CODE instead of the expected 403-for-missing-cookie. Not necessarily broken — but sign in through the browser before trusting this deploy."
fi

# --- 5. the tailnet front door --------------------------------------------
url="https://$TS_HOST:$HTTPS_PORT"
info "Checking $url (the first request can take ~60s while the TLS cert is minted)"
PL_TIMEOUT=90 pl "$url$HEALTH_PATH"
if [ "$PL_CODE" = "200" ]; then
  ok "Tailnet HTTPS answering: $url$HEALTH_PATH (HTTP 200)"
else
  for i in 1 2 3 4 5; do
    sleep 3
    PL_TIMEOUT=30 pl "$url$HEALTH_PATH"
    [ "$PL_CODE" = "200" ] && break
  done
  if [ "$PL_CODE" = "200" ]; then
    ok "Tailnet HTTPS answering: $url$HEALTH_PATH (HTTP 200)"
  else
    warn "No answer on $url yet (HTTP $PL_CODE) — the cert may still be minting. Retry in a minute: curl -o /dev/null -w '%{http_code}\\n' $url$HEALTH_PATH"
  fi
fi

# --- 6. nothing is listening where it should not be -----------------------
# Loopback and this node's own Tailscale addresses are the only acceptable
# answers. The Tailscale ones are legitimate here and not a loophole: this
# service publishes HTTPS on the SAME number as its local port, so tailscaled
# itself holds a listener on the tailnet address for it. Anything else — a
# wildcard, a LAN address — means the publish spec in docker-compose.yml lost
# its 127.0.0.1 prefix and a document archive is on the LAN.
listen_addrs() {  # listen_addrs PORT -> "host:port" per line
  local port="$1"
  # `|| true` on both branches: no listeners at all is a legitimate answer,
  # and lsof in particular exits 1 when nothing matches. Without it, pipefail
  # would end the run here instead of printing the audit line.
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}' || true
  else
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' || true
  fi
}

audit_port() {  # audit_port PORT LABEL
  local port="$1" label="$2" addr host bad=""
  # A read loop, not `for addr in $addrs`: that relies on word-splitting,
  # which zsh does not do for unquoted expansions.
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"                              # strip the :port
    host="$(printf '%s' "$host" | tr -d '[]')"     # unwrap [v6] — tr, not a
                                                   # glob: '[' is an invalid
                                                   # pattern under zsh
    host="${host%\%*}"                             # drop %lo etc
    case "$host" in
      127.*|::1|localhost|'*') continue ;;
    esac
    [ -n "$TS_IP" ]  && [ "$host" = "$TS_IP" ]  && continue
    [ -n "$TS_IP6" ] && [ "$host" = "$TS_IP6" ] && continue
    bad="$bad $host"
  done <<EOF
$(listen_addrs "$port")
EOF
  if [ -n "$bad" ]; then
    fail "$label (:$port) is listening on non-tailnet address(es):$bad — that is outside the tailnet boundary, and this service is a searchable archive of your documents. Check the ports block in $SERVICE_DIR/docker-compose.yml: it must read 127.0.0.1:\${LOCAL_PORT}:8000, not \${LOCAL_PORT}:8000."
  else
    ok "$label (:$port) listens only on loopback and this node's tailnet address"
  fi
}
audit_port "$LOCAL_PORT" "Paperless"

# --- 7. the queue is attached --------------------------------------------
# Soft, because a broker that cannot be reached by `docker exec` is not
# necessarily a broker the app cannot reach. Worth saying anyway: with redis
# unreachable the web UI works perfectly and NOTHING is ever OCR'd — files sit
# in consume/ and no error appears in the browser.
if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -qx PONG; then
  ok "Redis answers PING — the OCR queue is attached"
else
  warn "Could not confirm redis with 'redis-cli ping'. If documents dropped into consume/ never appear, check: docker compose --project-directory $SERVICE_DIR logs redis"
fi

# ============================================================== SUMMARY
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mDone.\033[0m Paperless-ngx is at \033[1m%s\033[0m (tailnet only).\n' "$url"
else
  printf '\033[1;31mDeploy finished with failures.\033[0m Read the ✗ lines above before filing anything here.\n'
fi
echo
echo "  Login:    $ADMIN_USERNAME"
echo "  Password: see PAPERLESS_ADMIN_PASSWORD in $ENV_FILE"
echo "            (change it in the UI if you like — but note that setup.sh"
echo "             can then neither overwrite nor repair it, so the value in"
echo "             .env becomes stale documentation from that moment on)"
echo "  Database: SQLite at $PAPERLESS_ROOT/data/db.sqlite3 (no Postgres container)"
echo
echo "To file a document, copy it into the drop folder — no UI needed:"
echo "    cp ~/Downloads/statement.pdf $PAPERLESS_ROOT/consume/"
echo "  It is OCR'd and filed within a minute or two. Measured: a 10-page"
echo "  300 dpi scan takes ~97 s on this box, which has no GPU and runs OCR"
echo "  single-threaded on purpose (see PAPERLESS_THREADS_PER_WORKER in"
echo "  docker-compose.yml — the default of one-thread-per-core OOM-killed the"
echo "  worker here). Slow is expected; silent is not."
echo
printf '\033[1;33mTHERE IS NO BACKUP OF THIS BOX.\033[0m %s/{data,media} is the whole\n' "$PAPERLESS_ROOT"
echo "  archive and it exists in exactly one place. Export it and copy it off:"
echo "    docker exec $CONTAINER document_exporter ../export"
echo "    tar czf paperless-\$(date +%F).tgz -C $PAPERLESS_ROOT export"
echo "  The exporter writes the documents plus a manifest, so the result can be"
echo "  re-imported into a fresh install — a raw copy of db.sqlite3 cannot."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart"
echo "Stop:    ./setup.sh --stop     (keeps the containers and the data)"
echo "Remove:  ./setup.sh --down     (removes the containers, keeps the data)"
echo "         tailscale serve --https=$HTTPS_PORT off    (removes the publish)"
echo "Upgrade: export first (above), bump PAPERLESS_VERSION in $ENV_FILE,"
echo "         then re-run ./setup.sh. Database migrations are ONE-WAY."
echo
echo "RAM: measured ~660 MB idle for the app plus 4 MB for redis, and this is"
echo "  the heaviest service in this repo. It is capped at 1536 MB, sized off a"
echo "  measured OCR peak rather than off idle. If the box gets tight, this is"
echo "  a reasonable one to stop between uses — ./setup.sh --stop, then"
echo "  ./setup.sh when you next have something to file."

[ "$FAILED" = "0" ] || exit 1
exit 0
