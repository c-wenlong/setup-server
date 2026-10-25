#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Firefly III (self-hosted double-entry personal
# finance) plus its Data Importer, behind Tailscale. Linux + macOS.
#
# End state:
#   - three containers: firefly-iii, firefly-iii-db (PostgreSQL 16),
#     firefly-iii-importer, all image-pinned and all memory-capped
#   - the web app on 127.0.0.1:LOCAL_PORT and nothing else, published
#     tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - the Data Importer on 127.0.0.1:IMPORTER_PORT, published the same way
#   - Postgres on the compose network only — not published anywhere, not even
#     loopback
#   - the admin account already created from a generated password, so there is
#     no "register your account" form left sitting on the tailnet
#   - registration then CLOSED automatically (Firefly's single-user mode), so
#     nobody else on the tailnet can create a second account
#   - boot-persistent via Docker's restart policy (no systemd/launchd needed)
#
# Usage:
#   ./setup.sh                                       # 8097 web, 8099 importer
#   LOCAL_PORT=8100 ./setup.sh                       # HTTPS follows LOCAL_PORT (8100 -> 8100)
#   LOCAL_PORT=8097 HTTPS_PORT=8097 ./setup.sh
#   FIREFLY_ADMIN_EMAIL=me@example.com ./setup.sh    # first run only; .env wins after
#
# ---------------------------------------------------------------------------
# THE FOUR THINGS THIS SCRIPT KNOWS THAT THE DOCS DO NOT
#
# 1. TRUSTED_PROXIES DECIDES WHETHER THE PAGE RENDERS AT ALL. Behind Tailscale
#    Serve, an instance with TRUSTED_PROXIES unset serves a perfectly cheerful
#    HTTP 200 over HTTPS whose every <link href> and <script src> is written
#    as http://. The browser blocks all of them as mixed content, and what you
#    get is an unstyled login form with no JavaScript — which reads as
#    "Firefly is broken", not as "one environment variable is empty". curl
#    cannot see the difference; only counting http:// in the HTML can. So the
#    verification at the bottom of this script does exactly that, over the
#    real tailnet URL, and requires ZERO. Measured against 6.4.2 end to end
#    through a live `tailscale serve --https` mount — including the negative
#    case, which is how we know APP_URL alone does not save you.
#
# 2. THE ADMIN ACCOUNT CAN ONLY BE MADE THROUGH THE WEB FORM. There is no
#    `firefly-iii:create-user` artisan command — the image's full command list
#    was read out and it does not exist. So this script does what a browser
#    does: GET /register, scrape the CSRF token, POST it back on the SAME
#    cookie jar. Drop the jar and you get HTTP 419 "Page Expired", not a
#    validation error.
#
# 3. THE PASSWORD MINIMUM IS 16 CHARACTERS, AND FAILING IT LOOKS LIKE SUCCESS.
#    Measured: a 15-character password is answered with a 302 back to
#    /register — the same status code a successful registration returns — with
#    the error flashed into the session and NO USER CREATED. A script that
#    trusts the status code hands you a Firefly with no account and a password
#    in .env that has never worked. This one generates 32 characters and then
#    verifies the user actually exists by checking that `/` has stopped
#    landing on /register.
#
# 4. `/` IS ALWAYS A REDIRECT, NEVER A 200. It goes to /login, which goes on
#    to /register while no user exists. Health checks and Uptime Kuma monitors
#    must target /login (200 once the account exists), not `/`.
# ---------------------------------------------------------------------------
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the images and repairs the publish.
# .env is never overwritten, the admin account is created at most once (a
# re-run detects the existing user and leaves the database alone), and no
# container is recreated unless its image or configuration actually changed.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8097}"
IMPORTER_PORT="${IMPORTER_PORT:-8099}"
# HTTPS follows the matching local port unless set explicitly (the n8n and
# kaichenpedia convention), so overriding only LOCAL_PORT or IMPORTER_PORT
# cannot split a pair. Unlike immich, .env stores both HTTPS ports and they
# are read back below, so a re-run needs no HTTPS_PORT_EXPLICIT bookkeeping ,
# it lands back on whatever .env already settled on.
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
IMPORTER_HTTPS_PORT="${IMPORTER_HTTPS_PORT:-$IMPORTER_PORT}"
ADMIN_EMAIL="${FIREFLY_ADMIN_EMAIL:-admin@example.com}"

APP_CONTAINER="firefly-iii"
DB_CONTAINER="firefly-iii-db"
IMPORTER_CONTAINER="firefly-iii-importer"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/firefly-iii"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# 700. Holds the registration POST body (the plaintext admin password) and the
# session cookie jar. Removed on every exit path.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hex, so every generated secret is [0-9a-f] and survives .env, shell quoting,
# a URL-encoded form body and a phone keyboard without a single escape.
# Firefly's own .env.example warns that a "#" in APP_KEY "may break things";
# hex sidesteps that entirely. python3 when present, /dev/urandom otherwise —
# no hard dependency on python for what is just random bytes.
randhex() {  # randhex BYTES -> 2*BYTES hex characters
  local n="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))' "$n"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# The host's zone. timedatectl is the authority on a systemd box;
# /etc/localtime is the portable fallback and is what macOS has (it symlinks
# into /var/db/timezone/zoneinfo/..., so the same sed works). Dates on
# transactions are the whole point of a ledger — getting this wrong shifts
# them by a day.
detect_tz() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' || true)"
  fi
  case "$tz" in
    ''|*[!A-Za-z0-9/_+-]*) tz="Etc/UTC" ;;
  esac
  printf '%s' "$tz"
}

# Every local address currently listening on a port, one per line. ss on
# Linux, lsof then netstat as fallbacks (macOS has no ss). Never fails the
# script — an empty result means "nothing listening, or nothing could tell
# us", and the callers distinguish those.
listeners_on_port() {  # listeners_on_port PORT
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep ":$p\$" || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep "[.:]$p\$" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | awk '/LISTEN/{print $4}' | grep "[.:]$p\$" || true
  fi
}

have_listener_tool() {
  command -v ss >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1
}

# Listeners that would stop Docker binding 127.0.0.1:PORT — something already
# holding loopback, or a wildcard bind that covers it. Deliberately NOT
# "anything on this port": once Serve is up, tailscaled binds the box's tailnet
# addresses on the same number (this repo publishes 8097 -> 8097), and that
# does not conflict with a loopback bind. Treating it as a conflict would make
# every re-run with a stopped container refuse to start.
blocking_listeners() {  # blocking_listeners PORT
  local a host
  listeners_on_port "$1" | while IFS= read -r a; do
    [ -n "$a" ] || continue
    host="${a%:*}"
    [ "$host" = "$a" ] && host="${a%.*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
    case "$host" in
      127.*|::1|localhost|0.0.0.0|::|'*') printf '%s\n' "$a" ;;
    esac
  done
}

# The subset that is NOT loopback and NOT tailscaled itself — i.e. the ones
# that would mean this deploy is reachable without going through Tailscale.
# The tailscale exception is load-bearing: this repo publishes on the same
# port number it listens on, so a correct deploy always shows tailscaled
# holding the tailnet addresses on that port. Address shapes handled:
# ss/lsof (127.0.0.1:8097, [::1]:8097) and BSD netstat (127.0.0.1.8097).
# `[` is stripped with tr rather than matched as a glob, because a bracket in
# a case pattern is a character class.
non_loopback_listeners() {  # non_loopback_listeners PORT
  local ts4 ts6 a host
  ts4="$("$TAILSCALE" ip -4 2>/dev/null | head -1 || true)"
  ts6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 || true)"
  listeners_on_port "$1" | while IFS= read -r a; do
    [ -n "$a" ] || continue
    host="${a%:*}"
    [ "$host" = "$a" ] && host="${a%.*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
    host="${host%\%*}"
    case "$host" in
      127.*|::1|localhost) continue ;;
    esac
    [ -n "$ts4" ] && [ "$host" = "$ts4" ] && continue
    [ -n "$ts6" ] && [ "$host" = "$ts6" ] && continue
    printf '%s\n' "$a"
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

for p in "$LOCAL_PORT" "$IMPORTER_PORT" "$HTTPS_PORT" "$IMPORTER_HTTPS_PORT"; do
  case "$p" in ''|*[!0-9]*) die "Ports must be numeric (got: $p)";; esac
done
[ "$LOCAL_PORT" != "$IMPORTER_PORT" ] || die "LOCAL_PORT and IMPORTER_PORT must differ (both are $LOCAL_PORT)."

# The email goes into a URL-encoded form body and becomes the login. Keep it
# to something Laravel's `email` validation rule will accept, and reject the
# characters that would need escaping, rather than discovering the problem as
# a 302 with a flashed error nobody reads.
case "$ADMIN_EMAIL" in
  *@*.*) ;;
  *) die "FIREFLY_ADMIN_EMAIL does not look like an email address (got: $ADMIN_EMAIL). It becomes your Firefly III login." ;;
esac
case "$ADMIN_EMAIL" in
  *[!A-Za-z0-9.@_+-]*) die "FIREFLY_ADMIN_EMAIL must be [A-Za-z0-9.@_+-] only (got: $ADMIN_EMAIL)." ;;
esac

[ -f "$SERVICE_DIR/docker-compose.yml" ] || die "Missing $SERVICE_DIR/docker-compose.yml — re-clone the repo."

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The tailnet name is resolved up front because APP_URL is built from it, and
# because a box without MagicDNS cannot be published at all.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

EXTERNAL_URL="https://$TS_HOST:$HTTPS_PORT"
IMPORTER_URL="https://$TS_HOST:$IMPORTER_HTTPS_PORT"

# Memory is the live constraint on this box, not disk. Three more containers
# on a host that is already swapping is the one way this deploy hurts the
# services around it, so say the number out loud before starting anything.
# Linux-only: /proc/meminfo does not exist on macOS and `free` is not shipped.
if [ "$OS" = "Linux" ] && [ -r /proc/meminfo ]; then
  avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
  if [ -n "${avail_mb:-}" ] && [ "$avail_mb" -lt 700 ]; then
    warn "Only ${avail_mb} MB of memory available. Firefly III + Postgres + the importer idle at roughly 180 MB together, but the first boot runs database migrations and wants more."
    warn "  Every container here has a mem_limit, so this deploy cannot run away — but something else on the box may get squeezed. Stop what you can spare and re-run if it struggles."
  elif [ -n "${avail_mb:-}" ]; then
    ok "${avail_mb} MB memory available (this deploy idles at ~180 MB across all three containers)"
  fi
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated APP_KEY, database password and admin password)"
  app_key="$(randhex 16)"        # exactly 32 characters
  db_pw="$(randhex 16)"
  admin_pw="$(randhex 16)"       # 32 characters; the minimum is 16
  cron_token="$(randhex 16)"     # must be exactly 32
  tz="$(detect_tz)"

  # Belt and braces. These lengths are contractual — a 31-character APP_KEY is
  # rejected at boot and a 15-character password is rejected by the
  # registration form with a 302 that looks exactly like success. If randhex
  # ever falls back to a broken od, fail here rather than three minutes later.
  [ "${#app_key}" -eq 32 ]    || die "Generated APP_KEY is ${#app_key} characters, not 32. Firefly III requires exactly 32."
  [ "${#admin_pw}" -ge 16 ]   || die "Generated admin password is ${#admin_pw} characters; Firefly III requires at least 16."
  [ "${#cron_token}" -eq 32 ] || die "Generated STATIC_CRON_TOKEN is ${#cron_token} characters, not 32."

  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
# It is NOT passed to any container as env_file — the admin password below
# must never end up in a container's environment.

# --- versions -------------------------------------------------------------
# Pinned exactly. This holds financial records; nothing here should change
# version unattended. The entrypoint runs firefly-iii:upgrade-database on
# every start and those migrations are ONE-WAY — dump the database before
# bumping FIREFLY_VERSION (see the backup recipe setup.sh prints).
FIREFLY_VERSION=version-6.4.2
IMPORTER_VERSION=version-1.9.0
POSTGRES_VERSION=16-alpine

# --- ports ----------------------------------------------------------------
# Loopback side. The web app and the Data Importer each get one.
LOCAL_PORT=$LOCAL_PORT
IMPORTER_PORT=$IMPORTER_PORT

# The tailnet HTTPS ports Tailscale Serve publishes on. Changing either does
# NOT remove the old mapping — undo that one by hand first:
#   tailscale serve --https=<old port> off
HTTPS_PORT=$HTTPS_PORT
IMPORTER_HTTPS_PORT=$IMPORTER_HTTPS_PORT

TZ=$tz

# --- identity -------------------------------------------------------------
# THE EXTERNAL URL — what the browser types, not what the container listens
# on. Firefly puts it in generated mails, and the Data Importer uses it as the
# VANITY_URL for the links it shows you. If this box's tailnet name or the
# published port ever changes, fix it here and re-run setup.sh.
#
# It is NOT what makes the CSS load — that is TRUSTED_PROXIES, which is
# hardcoded to '**' in docker-compose.yml. See the note there.
FIREFLY_APP_URL=$EXTERNAL_URL

# The contact address shown on error pages and in mails Firefly generates.
# Not a login.
FIREFLY_SITE_OWNER=$ADMIN_EMAIL

# --- secrets --------------------------------------------------------------
# EXACTLY 32 characters, no "base64:" prefix (measured: the plain form is what
# this image accepts). It encrypts sessions and some stored fields — changing
# it logs everyone out and can make encrypted data unreadable. Never rotate it
# casually, and back it up with the database.
FIREFLY_APP_KEY=$app_key

# Shared by the app and the postgres container. They must match; a mismatch
# does not produce a clean error, it hangs the migrations.
FIREFLY_DB_NAME=firefly
FIREFLY_DB_USER=firefly
FIREFLY_DB_PASSWORD=$db_pw

# The Firefly III login, created once by setup.sh through the registration
# form on first deploy. Changing these lines afterwards does nothing: change
# the password in the UI (Options -> Profile) and mirror it back here by hand,
# or just delete the line — nothing re-reads it after the account exists.
#
# 32 characters. The form's minimum is 16 and a shorter password is rejected
# with a redirect that looks like success, so do not shorten this.
FIREFLY_ADMIN_EMAIL=$ADMIN_EMAIL
FIREFLY_ADMIN_PASSWORD=$admin_pw

# Exactly 32 characters. Recurring transactions, bill reminders and the
# exchange-rate download only run when something pings
#   $EXTERNAL_URL/api/v1/cron/$cron_token
# Nothing does yet — this deploy ships no cron container. See SETUP.md.
FIREFLY_STATIC_CRON_TOKEN=$cron_token

# The Data Importer's Firefly III personal access token. EMPTY on purpose:
# minting one needs a logged-in browser session (Options -> Profile -> OAuth
# -> Personal Access Tokens), so no script can do it for you. Until it is
# filled in the importer runs and shows instructions instead of an import
# form. Paste the token here and re-run setup.sh.
FIREFLY_ACCESS_TOKEN=

# --- state ----------------------------------------------------------------
# FIREFLY_DB_DATA is the ledger — every account, transaction, rule, budget and
# user, plus the Passport keys that sign API tokens. THAT is the backup
# target. UPLOAD holds attachments; IMPORTER_CONFIG holds saved import column
# mappings. All three are written by containers running as root, so they end
# up root-owned on the host.
FIREFLY_DB_DATA=$STATE/db
FIREFLY_UPLOAD=$STATE/upload
FIREFLY_IMPORTER_CONFIG=$STATE/importer

# --- resource caps --------------------------------------------------------
# Hard ceilings, not reservations. Measured idle on this box: app ~66 MB,
# db ~29 MB, importer ~80 MB. The caps exist because this host has ~3.5 GB
# available with 2 GB of swap already in use, and an unbounded php-fpm is the
# one thing here that can OOM the services around it.
FIREFLY_MEM_LIMIT=768m
FIREFLY_DB_MEM_LIMIT=512m
FIREFLY_IMPORTER_MEM_LIMIT=512m

# --- currency -------------------------------------------------------------
# Deliberate deviation from the shipped defaults (upstream ships both off).
# true = Firefly converts between currencies and downloads real exchange rates
# from the Firefly author's Azure container. This is the only outbound call
# this deploy makes. Set it to false to stay fully offline — you then enter
# every rate by hand, and a multi-currency ledger with no rates is the silent
# 1:1 conversion this project exists to avoid.
FIREFLY_ENABLE_RATES=true
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_LOCAL_PORT="$LOCAL_PORT"
REQUESTED_IMPORTER_PORT="$IMPORTER_PORT"
REQUESTED_HTTPS_PORT="$HTTPS_PORT"
REQUESTED_IMPORTER_HTTPS_PORT="$IMPORTER_HTTPS_PORT"
set -a; . "$ENV_FILE"; set +a

ADMIN_EMAIL="${FIREFLY_ADMIN_EMAIL:?FIREFLY_ADMIN_EMAIL missing from $ENV_FILE}"
ADMIN_PASSWORD="${FIREFLY_ADMIN_PASSWORD:?FIREFLY_ADMIN_PASSWORD missing from $ENV_FILE}"
APP_URL="${FIREFLY_APP_URL:?FIREFLY_APP_URL missing from $ENV_FILE}"
DB_DATA="${FIREFLY_DB_DATA:?FIREFLY_DB_DATA missing from $ENV_FILE}"
UPLOAD_DIR="${FIREFLY_UPLOAD:?FIREFLY_UPLOAD missing from $ENV_FILE}"
IMPORTER_CONFIG="${FIREFLY_IMPORTER_CONFIG:?FIREFLY_IMPORTER_CONFIG missing from $ENV_FILE}"
# These four may be absent from a .env written by an older revision of this
# script; fall back to what was requested rather than failing on the file.
LOCAL_PORT="${LOCAL_PORT:-$REQUESTED_LOCAL_PORT}"
IMPORTER_PORT="${IMPORTER_PORT:-$REQUESTED_IMPORTER_PORT}"
HTTPS_PORT="${HTTPS_PORT:-$REQUESTED_HTTPS_PORT}"
IMPORTER_HTTPS_PORT="${IMPORTER_HTTPS_PORT:-$REQUESTED_IMPORTER_HTTPS_PORT}"

EXTERNAL_URL="https://$TS_HOST:$HTTPS_PORT"
IMPORTER_URL="https://$TS_HOST:$IMPORTER_HTTPS_PORT"

port_drift() {  # port_drift NAME REQUESTED ACTUAL
  [ "$2" = "$3" ] && return 0
  warn "$1=$2 ignored — the existing $ENV_FILE says $3. Edit .env and re-run to move the port."
}
port_drift LOCAL_PORT "$REQUESTED_LOCAL_PORT" "$LOCAL_PORT"
port_drift IMPORTER_PORT "$REQUESTED_IMPORTER_PORT" "$IMPORTER_PORT"
if [ "$HTTPS_PORT" != "$REQUESTED_HTTPS_PORT" ]; then
  warn "HTTPS_PORT=$REQUESTED_HTTPS_PORT ignored — the existing $ENV_FILE says $HTTPS_PORT. To move the published port, first remove the old mapping (tailscale serve --https=$HTTPS_PORT off), then edit HTTPS_PORT and FIREFLY_APP_URL in .env and re-run — otherwise both ports stay published."
fi

# THE DRIFT CHECK THAT MATTERS. FIREFLY_APP_URL is what the importer links
# back to and what Firefly puts in mails. If the tailnet name or the published
# port has moved since .env was written, those links point at nothing.
if [ "$APP_URL" != "$EXTERNAL_URL" ]; then
  warn "FIREFLY_APP_URL in .env is '$APP_URL' but this deploy publishes '$EXTERNAL_URL'."
  warn "  Firefly III will still render correctly (that is TRUSTED_PROXIES' job, and it is hardcoded), but generated mails and the Data Importer's links back to Firefly will point at the stale URL."
  warn "  Fix: set FIREFLY_APP_URL=$EXTERNAL_URL in $ENV_FILE and re-run."
fi

# Exact-length re-checks against whatever is in the file now, generated or
# hand-edited. Both are hard requirements with confusing failure modes.
case "${#FIREFLY_APP_KEY}" in
  32) ;;
  *) die "FIREFLY_APP_KEY in $ENV_FILE is ${#FIREFLY_APP_KEY} characters. Firefly III requires EXACTLY 32 (plain, no 'base64:' prefix) and refuses to boot otherwise." ;;
esac
if [ "${#ADMIN_PASSWORD}" -lt 16 ]; then
  die "FIREFLY_ADMIN_PASSWORD in $ENV_FILE is ${#ADMIN_PASSWORD} characters. Firefly III's registration form requires at least 16, and rejects a shorter one with a redirect that looks exactly like success — so this would silently create no account at all. Lengthen it (32 hex characters: openssl rand -hex 16) and re-run."
fi
case "${#FIREFLY_STATIC_CRON_TOKEN}" in
  32) ;;
  *) warn "FIREFLY_STATIC_CRON_TOKEN in $ENV_FILE is ${#FIREFLY_STATIC_CRON_TOKEN} characters, not 32. Firefly III ignores a token of any other length, so the cron endpoint will reject every call. Nothing calls it in this deploy, so this is not fatal." ;;
esac

mkdir -p "$STATE" "$DB_DATA" "$UPLOAD_DIR" "$IMPORTER_CONFIG"

# The database is the thing that grows here, and it grows slowly — a decade of
# personal transactions is tens of MB. A near-full disk still matters, because
# Postgres stops accepting writes rather than corrupting itself.
avail_kb="$(df -Pk "$DB_DATA" | awk 'NR==2{print $4}' || true)"
if [ "${avail_kb:-0}" -lt 1048576 ]; then
  warn "$(( ${avail_kb:-0} / 1024 )) MB free at $DB_DATA — PostgreSQL refuses writes when the disk fills, and this is your ledger. Free some space first."
else
  ok "$(( avail_kb / 1048576 )) GB free at $DB_DATA"
fi

# --------------------------------------------------- port availability
# Checked before compose runs, so the message can name the port instead of
# leaving you with Docker's "port is already allocated". Skipped for a port
# this deploy's own container already holds.
check_port_free() {  # check_port_free PORT CONTAINER LABEL
  docker inspect -f '{{.State.Running}}' "$2" 2>/dev/null | grep -q true && return 0
  local busy
  busy="$(blocking_listeners "$1")"
  [ -n "$busy" ] || return 0
  die "Port $1 ($3) is already in use by something that is not the $2 container: $(printf '%s' "$busy" | tr '\n' ' '). Free it, or set the port in $ENV_FILE and re-run."
}
check_port_free "$LOCAL_PORT" "$APP_CONTAINER" "Firefly III web"
check_port_free "$IMPORTER_PORT" "$IMPORTER_CONTAINER" "Data Importer"

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

# Pulled as its own step so the first-run download (~2.5 GB across three
# images) shows progress — `up -d` below has its stderr captured for error
# triage, and a silent five-minute pause is not what a one-shot deploy should
# look like. A failed pull is a warning, not a death: the pinned images may
# already be cached, and a re-run with no network should still repair a
# deploy.
info "Fetching the images (~2.5 GB on a first run; a re-run only checks the pinned digests)"
"${COMPOSE[@]}" pull 2>&1 || warn "docker compose pull failed — continuing with whatever images are already cached locally."

info "Starting Firefly III, PostgreSQL and the Data Importer (docker compose up -d)"
if ! "${COMPOSE[@]}" up -d 2>"$WORK/up.err"; then
  cat "$WORK/up.err" >&2
  case "$(cat "$WORK/up.err" 2>/dev/null || true)" in
    *"address already in use"*|*"port is already allocated"*)
      die "Port conflict. Something already holds 127.0.0.1:$LOCAL_PORT or 127.0.0.1:$IMPORTER_PORT. Check: ss -ltn | grep -E ':$LOCAL_PORT |:$IMPORTER_PORT '" ;;
    *"permission denied"*)
      die "Docker could not write one of the state directories under $STATE. Check ownership: ls -ld $DB_DATA $UPLOAD_DIR $IMPORTER_CONFIG" ;;
    *)
      die "docker compose up failed. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100" ;;
  esac
fi
ok "Containers started"

# ------------------------------------------------------------- HTTP helpers
FF_BASE="http://127.0.0.1:$LOCAL_PORT"
FF_CODE=""

# One request. Body in $WORK/resp, status in $FF_CODE.
#
# curl already prints 000 to stdout when it cannot connect, AND exits
# non-zero. A `|| echo 000` fallback therefore CONCATENATES, turning a plain
# connection failure into the nonsense code "000000". Take curl's own output
# and normalise anything unexpected.
ff() {  # ff PATH [curl-args...]
  local path="$1"; shift
  FF_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time "${FF_TIMEOUT:-30}" "$@" "$FF_BASE$path" 2>/dev/null)" || true
  case "$FF_CODE" in
    [0-9][0-9][0-9]) ;;
    *) FF_CODE=000 ;;
  esac
}

# Where `/` actually lands after following redirects. This is the state
# machine of the whole deploy, and it answers unauthenticated:
#
#   .../register   — no user exists yet
#   .../login      — a user exists (this is success)
#   ""             — not answering
#
# Redirects are built from the REQUEST host, not from APP_URL (measured), so
# following them stays on 127.0.0.1 and never leaves the box.
landing_url() {
  curl -sS -o /dev/null -w '%{url_effective}' -L --max-redirs 5 --max-time 30 "$FF_BASE/" 2>/dev/null || true
}

# Ride out a cold start. First boot runs `firefly-iii:create-database` and
# `firefly-iii:upgrade-database` against an empty PostgreSQL and the
# entrypoint sleeps 10s on top of that; measured 21s from `up -d` to the first
# answered request, and that was with warm images and a warm page cache.
#
# 000 is treated as not-ready rather than as failure on purpose. The Jellyfin
# deploy in this repo died on exactly that shape of race — a readiness probe
# passed and the very next request came back 000 because the server had not
# finished accepting connections. Retrying a 000 costs nothing when the
# service is genuinely down (this still fails, just later) and removes the
# race when it is merely a second behind.
wait_ready() {  # wait_ready ATTEMPTS
  local i
  for i in $(seq 1 "$1"); do
    ff /login
    case "$FF_CODE" in
      200|302) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

info "Waiting for Firefly III on $FF_BASE (first boot runs database migrations; ~25s)"
if ! wait_ready 90; then
  warn "Last status from $FF_BASE/login was HTTP $FF_CODE."
  die "Firefly III never answered on $FF_BASE. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 app"
fi
ok "Firefly III is answering locally (GET $FF_BASE/login -> HTTP $FF_CODE)"

# ------------------------------------------- the admin account (at most once)
# No marker file, deliberately. The server itself is the authority and it
# answers unauthenticated, so a marker could only add a stale-marker failure
# mode: wipe the database, keep the marker, and this script would skip
# registration and hand back a box sitting on the registration form. As
# written, a wiped database simply gets the account recreated from the
# password already in .env.
ACCOUNT_ACTION=""
landing="$(landing_url)"

case "$landing" in
  */register)
    info "No user exists yet — creating the admin account ($ADMIN_EMAIL)"

    # THE CSRF DANCE. GET the form with a fresh cookie jar, scrape the
    # 40-character _token out of it, POST it back on the SAME jar. Drop the
    # jar between the two and Firefly answers HTTP 419 "Page Expired", which
    # is not a validation error and does not say what is wrong.
    rm -f "$WORK/jar"
    ff /register -c "$WORK/jar"
    [ "$FF_CODE" = "200" ] || die "GET $FF_BASE/register returned HTTP $FF_CODE, so the registration form could not be read. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 app"
    cp "$WORK/resp" "$WORK/register.html"

    # sed, not grep -P: the repo targets macOS too, where grep has no -P.
    csrf="$(tr -d '\n\r' < "$WORK/register.html" | sed -n 's/.*name="_token"[^>]*value="\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$csrf" ] || die "Could not find the CSRF token (name=\"_token\") in the registration form at $FF_BASE/register. The form's markup may have changed in this Firefly III version — read $FF_BASE/register by hand and adjust the scrape in setup.sh."
    ok "Scraped the CSRF token from the registration form (${#csrf} characters)"

    # The password goes to curl through a mode-600 file, not on the command
    # line: an argument would be visible in `ps` to every user on the box for
    # the life of the request. `--data-urlencode name@file` reads the file and
    # URL-encodes its contents — written with printf '%s' so there is no
    # trailing newline to encode as %0A and turn into a wrong password.
    #
    # `verify_password` is deliberately NOT sent. The form ships that checkbox
    # ticked, and it makes Firefly check the password against the
    # haveibeenpwned API — an outbound call this deploy does not need, on a
    # password that is 32 random hex characters.
    : > "$WORK/pw"
    chmod 600 "$WORK/pw"
    printf '%s' "$ADMIN_PASSWORD" > "$WORK/pw"

    FF_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time 90 \
      -b "$WORK/jar" -c "$WORK/jar" \
      --data-urlencode "_token=$csrf" \
      --data-urlencode "invite_code=" \
      --data-urlencode "email=$ADMIN_EMAIL" \
      --data-urlencode "password@$WORK/pw" \
      --data-urlencode "password_confirmation@$WORK/pw" \
      "$FF_BASE/register" 2>/dev/null)" || true
    case "$FF_CODE" in [0-9][0-9][0-9]) ;; *) FF_CODE=000 ;; esac
    rm -f "$WORK/pw"

    case "$FF_CODE" in
      302) : ;;  # what BOTH success and a validation failure look like
      419)
        die "The registration POST was answered with HTTP 419 (\"Page Expired\"). That is the CSRF check failing, not a bad password — the cookie jar at $WORK/jar was not carried between the GET and the POST. Re-run ./setup.sh." ;;
      000)
        die "The registration POST could not connect to $FF_BASE even though the readiness probe had just succeeded. The container may have restarted mid-deploy. Re-run ./setup.sh — it resumes from wherever the server actually is." ;;
      *)
        die "The registration POST returned HTTP $FF_CODE (expected 302). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 app" ;;
    esac

    # DO NOT TRUST THE 302. A rejected password produces a 302 back to
    # /register with the error flashed into the session and no user created —
    # the same status code as success. Ask the server whether the user exists.
    landing="$(landing_url)"
    case "$landing" in
      */login)
        ACCOUNT_ACTION="created"
        ok "Admin account created and verified: $ADMIN_EMAIL"
        ;;
      *)
        # The errors are in the session, so they only surface on the next GET
        # made with the same jar. Fetch them — they are the whole diagnosis.
        # The <li> items are the flashed validation errors. Measured: on a
        # failed registration the register page contains exactly those and no
        # other list items, so this needs no cleverer parsing.
        errors="$(curl -sS -b "$WORK/jar" -c "$WORK/jar" --max-time 30 "$FF_BASE/register" 2>/dev/null \
          | grep -o '<li>[^<]*</li>' | sed -e 's/<[^>]*>//g' -e 's/^/ /' \
          | tr '\n' ' ' | head -c 400 || true)"
        [ -n "$errors" ] || errors="(none reported — the server flashed no validation errors)"
        die "The registration POST returned 302 but NO USER WAS CREATED: $FF_BASE/ still lands on ${landing:-nothing}. Firefly III said:$errors -- The most common cause is a password shorter than 16 characters, which is rejected with exactly this redirect. Check FIREFLY_ADMIN_PASSWORD in $ENV_FILE."
        ;;
    esac
    ;;
  */login)
    ACCOUNT_ACTION="existed"
    ok "An account already exists — leaving the database alone"
    ;;
  '')
    die "Could not determine whether an account exists: $FF_BASE/ did not answer. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 app" ;;
  *)
    warn "$FF_BASE/ landed somewhere unexpected: $landing. Continuing, but check the verification below."
    ACCOUNT_ACTION="unknown" ;;
esac

# ------------------------------------------------------- tailscale serve
publish() {  # publish HTTPS_PORT LOCAL_PORT LABEL
  info "Publishing $3 via Tailscale Serve (HTTPS :$1, tailnet only)"
  if ! "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Direct serve failed — trying operator grant (needs sudo, one time)"
      sudo tailscale set --operator="$USER"
    fi
    until "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2"; do
      echo
      info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
      read -r
    done
  fi
  ok "Tailscale Serve: HTTPS :$1 -> http://127.0.0.1:$2"
}
publish "$HTTPS_PORT" "$LOCAL_PORT" "Firefly III"
publish "$IMPORTER_HTTPS_PORT" "$IMPORTER_PORT" "the Data Importer"

# ============================================================== VERIFY
# A 200 from curl does not mean this service works. The mixed-content failure
# in item 1 of the header produces exactly that, and so does a Firefly with no
# user in it. Each check below is one of the ways this deploy can be quietly
# wrong.
FAILED=0
fail() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; FAILED=1; }

echo
info "Verifying the deploy"

# --- 1. all three containers are running, and not restart-looping ---------
check_container() {  # check_container CONTAINER COMPOSE_SERVICE
  local cstate crestarts chealth
  cstate="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)"
  crestarts="$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || echo 0)"
  chealth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || true)"
  if [ "$cstate" != "running" ]; then
    fail "Container $1 is '${cstate:-missing}', not running. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $2"
  elif [ "${crestarts:-0}" -gt 2 ] 2>/dev/null; then
    fail "Container $1 is running but has restarted ${crestarts} times — something is crashing it. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $2"
  elif [ "$chealth" = "unhealthy" ]; then
    fail "Container $1 is running but reports itself unhealthy. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $2"
  else
    ok "Container $1 is running${chealth:+ ($chealth)}"
  fi
}
check_container "$APP_CONTAINER" app
check_container "$DB_CONTAINER" db
check_container "$IMPORTER_CONTAINER" importer

# --- 2. `/` redirects; it is never a 200 ----------------------------------
# Worth asserting because it is the thing every health check gets wrong. A 200
# here would mean Firefly is serving something other than what this script
# thinks it is.
ff / --max-redirs 0
case "$FF_CODE" in
  302) ok "GET $FF_BASE/ redirects (HTTP 302), as it should — never health-check this path expecting 200" ;;
  200) fail "GET $FF_BASE/ returned 200. Firefly III always redirects / to /login; something else is answering on this port." ;;
  *)   fail "GET $FF_BASE/ returned HTTP $FF_CODE (expected 302)." ;;
esac

# --- 3. the admin user exists ---------------------------------------------
landing="$(landing_url)"
case "$landing" in
  */login)
    ok "An account exists — $FF_BASE/ lands on the login page, not the registration form"
    ;;
  */register)
    fail "NO ACCOUNT EXISTS: $FF_BASE/ still lands on the registration form. The registration form is sitting open on the tailnet and the password in $ENV_FILE has never worked. Re-run ./setup.sh."
    ;;
  *)
    fail "Could not tell whether an account exists — $FF_BASE/ landed on '${landing:-nothing}'."
    ;;
esac

# --- 4. registration is CLOSED --------------------------------------------
# Firefly's single_user_mode defaults to on, which closes registration once
# the first user exists. Verified rather than assumed, because if it were ever
# off, anyone who can reach the tailnet could create their own account inside
# this ledger.
ff /register
case "$FF_CODE" in
  200)
    if grep -qi 'not available\|not allowed\|disabled' "$WORK/resp" 2>/dev/null; then
      ok "Registration is closed — a second person on the tailnet cannot create an account"
    else
      warn "$FF_BASE/register is still serving a usable registration form. Firefly III's single-user mode should have closed it. Check Administration -> Configuration in the UI and turn 'Single user mode' on."
    fi
    ;;
  *) warn "GET $FF_BASE/register returned HTTP $FF_CODE; could not confirm registration is closed." ;;
esac

# --- 5. nothing is listening where it should not be -----------------------
audit_port() {  # audit_port PORT LABEL
  local bound exposed
  bound="$(listeners_on_port "$1" | tr '\n' ' ')"
  exposed="$(non_loopback_listeners "$1" | tr '\n' ' ')"
  if [ -n "$exposed" ]; then
    fail "$2 (:$1) is listening on a NON-LOOPBACK, non-tailnet address: $exposed — that is plain HTTP outside the tailnet boundary. Check the ports block in $SERVICE_DIR/docker-compose.yml; it must read '127.0.0.1:PORT:8080'."
  elif [ -n "$bound" ]; then
    ok "$2 (:$1) listens only on loopback and this node's tailnet address: $bound"
  else
    warn "Nothing appears to be listening on port $1, yet the HTTP checks above passed. Odd — check by hand: ss -ltn | grep $1"
  fi
}
if have_listener_tool; then
  audit_port "$LOCAL_PORT" "Firefly III web"
  audit_port "$IMPORTER_PORT" "Data Importer"
else
  warn "Neither ss, lsof nor netstat is available, so the loopback-only bind could not be verified. Check by hand that nothing but 127.0.0.1 listens on $LOCAL_PORT and $IMPORTER_PORT."
fi

# The database must not be published AT ALL — not to the LAN, not to loopback.
# Asking Docker is exact, where a port scan would only tell us about whatever
# port we thought to look at.
db_ports="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$DB_CONTAINER" 2>/dev/null | tr -d ' ' || true)"
case "$db_ports" in
  ''|'{}'|*'"5432/tcp":null'*)
    ok "PostgreSQL is not published on the host at all — it is reachable only from the other containers"
    ;;
  *)
    fail "PostgreSQL has host port bindings: $db_ports. It should have none; remove the ports block from the db service in $SERVICE_DIR/docker-compose.yml and re-run."
    ;;
esac

# --- 6. THE ONE THAT MATTERS: the page a browser actually gets ------------
# Everything above passes against an instance that renders as unstyled HTML
# with no JavaScript. Fetch the login page the way a browser would — over the
# tailnet, over TLS — and count the asset URLs that came back as http://.
# Anything above zero is a page the browser will refuse to load.
info "Fetching $EXTERNAL_URL/login over the tailnet (first request can take ~60s while the TLS cert is minted)"
https_code=""
for attempt in 1 2 3 4 5 6; do
  https_code="$(curl -sS -o "$WORK/login.html" -w '%{http_code}' --max-time 90 "$EXTERNAL_URL/login" 2>/dev/null)" || true
  case "$https_code" in
    [0-9][0-9][0-9]) ;;
    *) https_code=000 ;;
  esac
  [ "$https_code" = "200" ] && break
  sleep 5
done

if [ "$https_code" = "200" ]; then
  ok "Tailnet HTTPS login page answering: $EXTERNAL_URL/login (HTTP 200)"
  # grep -c counts LINES; this HTML is nearly one long line, so count
  # OCCURRENCES with grep -o | wc -l instead.
  #
  # THE `|| true` IS THE WHOLE CHECK. grep exits 1 when it matches nothing —
  # which here is the SUCCESS case — and under `set -o pipefail` that failure
  # propagates out of the command substitution and errexit kills the script
  # silently, one line before it would have told you the deploy is fine.
  # Measured: without it, a perfect deploy ends with no summary and exit 1.
  http_refs="$(grep -o 'src="http://\|href="http://' "$WORK/login.html" 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [ "${http_refs:-0}" -eq 0 ]; then
    ok "Zero http:// asset URLs in that page — the CSS and JavaScript will load in a browser"
  else
    fail "$http_refs asset URL(s) on the login page are http:// while the page itself is https://. A browser blocks those as mixed content, so you will get an unstyled login form with no JavaScript — while curl reports a perfectly healthy 200."
    fail "  Cause: TRUSTED_PROXIES is not reaching the container. It must be '**' (quoted) in the app service of $SERVICE_DIR/docker-compose.yml. Check with: docker exec $APP_CONTAINER printenv TRUSTED_PROXIES"
    printf '     first offenders: %s\n' "$(grep -o '\(src\|href\)="http://[^"]*"' "$WORK/login.html" 2>/dev/null | head -3 | tr '\n' ' ' || true)" >&2
  fi
else
  fail "No answer from $EXTERNAL_URL/login (HTTP $https_code) after 6 attempts. If this is the first publish on this port the TLS certificate may still be minting — retry by hand: curl -o /dev/null -w '%{http_code}\\n' $EXTERNAL_URL/login"
fi

# --- 7. the importer answers too ------------------------------------------
imp_code="$(curl -sS -o "$WORK/importer.html" -w '%{http_code}' --max-time 90 "$IMPORTER_URL/token" 2>/dev/null)" || true
case "$imp_code" in [0-9][0-9][0-9]) ;; *) imp_code=000 ;; esac
if [ "$imp_code" = "200" ]; then
  # Scoped to /build/assets/ deliberately. The importer's own asset URLs must
  # be https, but the page ALSO prints two informational links to
  # FIREFLY_III_URL (http://app:8080, the container-to-container address). Those
  # are upstream behaviour, are not assets, and are shown next to a working
  # link to the vanity URL — so a blanket http:// count would fail forever on
  # a correct deploy.
  # `|| true` for the same reason as above: no match is the success case.
  imp_refs="$(grep -o '\(src\|href\)="http://[^"]*build/assets/' "$WORK/importer.html" 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [ "${imp_refs:-0}" -eq 0 ]; then
    ok "Data Importer answering with https asset URLs: $IMPORTER_URL (HTTP 200)"
  else
    fail "The Data Importer's own asset URLs are http:// — check TRUSTED_PROXIES on the importer service in $SERVICE_DIR/docker-compose.yml."
  fi
else
  fail "No answer from $IMPORTER_URL/token (HTTP $imp_code). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 importer"
fi

# --- 8. what it actually costs in RAM -------------------------------------
# Reported, not asserted. The number belongs in SETUP.md and in the decision
# about what else this box can host.
mem_report="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' \
  "$APP_CONTAINER" "$DB_CONTAINER" "$IMPORTER_CONTAINER" 2>/dev/null || true)"
if [ -n "$mem_report" ]; then
  info "Memory in use (limit shown is the cap from .env, not a reservation):"
  printf '%s\n' "$mem_report" | sed 's/^/     /'
fi

# ============================================================== SUMMARY
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mDone.\033[0m Firefly III is at \033[1m%s\033[0m (tailnet only).\n' "$EXTERNAL_URL"
else
  printf '\033[1;31mDeploy finished with failures.\033[0m Read the ✗ lines above before putting any real money data in this.\n'
fi
echo
if [ "$ACCOUNT_ACTION" = "created" ]; then
  echo "  Login:    $ADMIN_EMAIL"
  echo "  Password: see FIREFLY_ADMIN_PASSWORD in $ENV_FILE"
  echo "    (32 random hex characters. Change it under Options -> Profile if you"
  echo "     like — then mirror it back into .env, or just delete that line;"
  echo "     nothing re-reads it once the account exists.)"
else
  echo "  Login:    $ADMIN_EMAIL  (account already existed; not touched this run)"
  echo "  Password: whatever it currently is — see FIREFLY_ADMIN_PASSWORD in"
  echo "            $ENV_FILE if it has never been changed in the UI."
fi
echo
echo "  Registration is CLOSED now that an account exists (Firefly III's"
echo "  single-user mode). Nobody else on the tailnet can create an account"
echo "  inside your ledger. To add one deliberately: Administration ->"
echo "  Configuration -> Single user mode, off, register, then turn it back on."
echo
printf '\033[1;33m┌──────────────────────────────────────────────────────────────────────┐\033[0m\n'
printf '\033[1;33m│  THE DATA IMPORTER IS DEPLOYED BUT IDLE — one manual step needed     │\033[0m\n'
printf '\033[1;33m└──────────────────────────────────────────────────────────────────────┘\033[0m\n'
echo
echo "  $IMPORTER_URL is running and will stay useless"
echo "  until you give it a Firefly III personal access token. That token can"
echo "  only be minted from a logged-in browser session, so no script can do"
echo "  it for you — this one deliberately does not try."
echo
echo "    1. open  $EXTERNAL_URL  and log in"
echo "    2. Options -> Profile -> OAuth tab -> Personal Access Tokens"
echo "    3. 'Create token', name it 'data-importer', copy the whole string"
echo "       (it is shown ONCE and is very long)"
echo "    4. put it in $ENV_FILE as"
echo "         FIREFLY_ACCESS_TOKEN=<the token>"
echo "    5. re-run ./setup.sh"
echo
echo "  Until then the importer shows you those instructions instead of an"
echo "  import form. That is the expected state after this deploy, not a bug."
echo
echo "FIRST LOGIN — two things this script deliberately left to you:"
echo
echo "  CURRENCY. Firefly III starts with EUR as the default. Set yours under"
echo "  Options -> Currencies: make SGD the default and enable USD, EUR and"
echo "  anything else your multi-currency wallets hold. Getting this wrong"
echo "  later means re-entering transactions, not flipping a setting."
echo
echo "  EXCHANGE RATES are enabled (FIREFLY_ENABLE_RATES in .env), but nothing"
echo "  downloads them on a schedule yet — this deploy ships no cron container."
echo "  Rates refresh when something pings:"
echo "    $EXTERNAL_URL/api/v1/cron/<FIREFLY_STATIC_CRON_TOKEN from .env>"
echo "  That same endpoint drives recurring transactions and bill reminders."
echo "  A systemd user timer or an n8n schedule (already on :5678) can do it;"
echo "  it is one HTTP GET a day. Nothing in this repo does it for you yet."
echo
echo "Backups: $DB_DATA is the ledger — every account, transaction,"
echo "  rule and budget, plus the keys that sign API tokens. Nothing backs"
echo "  this box up. The dump is small and does not need the container"
echo "  stopped:"
echo "    docker compose --project-directory $SERVICE_DIR exec -T db \\"
echo "      pg_dump -U ${FIREFLY_DB_USER:-firefly} ${FIREFLY_DB_NAME:-firefly} \\"
echo "      | gzip > ~/firefly-\$(date +%F).sql.gz"
echo "  Keep $ENV_FILE with it — FIREFLY_APP_KEY is needed to read"
echo "  back anything the database stores encrypted. Attachments live in"
echo "  $UPLOAD_DIR (root-owned; needs sudo to copy)."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: dump the database FIRST (the migrations the entrypoint runs are"
echo "         one-way), then bump FIREFLY_VERSION in $ENV_FILE and re-run"
echo "         ./setup.sh"
echo
echo "Uptime Kuma: monitor $EXTERNAL_URL/login and expect 200."
echo "  Do NOT monitor / — it answers 302 and Kuma scores that as down."

[ "$FAILED" = "0" ] || exit 1
exit 0
