#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Immich (self-hosted Google Photos) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - immich_server + immich_postgres + immich_redis (+ optional
#     immich_machine_learning) via Docker Compose
#   - the server published on 127.0.0.1:LOCAL_PORT only
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - admin account created and onboarding dismissed via the API — no
#     manual first-run wizard
#   - low-RAM job tuning applied on first run (this box is 7.7 GB)
#   - boot-persistent via Docker's restart policy (no systemd/launchd needed)
#
# Usage:
#   ./setup.sh                       # local 2283, HTTPS 2283, ML OFF
#   IMMICH_ML=on ./setup.sh          # turn machine learning on (needs ~8 GB RAM)
#   IMMICH_ML=off ./setup.sh         # turn it back off
#   LOCAL_PORT=2284 ./setup.sh       # HTTPS follows LOCAL_PORT (2284 -> 2284)
#   LOCAL_PORT=2284 HTTPS_PORT=8443 ./setup.sh
#
# Machine learning is OFF by default on purpose: Immich's documented minimum
# is 6 GB RAM (8 GB recommended) and the ML container is most of that. With
# ML off you keep upload, timeline, albums, sharing, phone backup and
# date/place/filename search; you lose semantic search, face grouping and
# OCR. Re-run with IMMICH_ML=on once the box has the headroom — it starts
# the container, flips the server setting, and existing photos backfill.
#
# Requirements: Linux or macOS, curl, python3, Docker + Compose v2,
# Tailscale logged in.
#
# Idempotent: safe to re-run; an existing .env is never overwritten, and
# system settings you have since changed in the web UI are left alone.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-2283}"
# The HTTPS port follows the local port unless set explicitly (the n8n and
# kaichenpedia convention), so overriding only LOCAL_PORT cannot split the
# two. Whether it was explicit is remembered for the .env read-back below.
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-admin@example.com}"
ADMIN_NAME="${IMMICH_ADMIN_NAME:-Admin}"
ML_URL="http://immich-machine-learning:3003"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/immich"
ML_MARKER="$STATE/.ml-mode"
API="http://127.0.0.1:$LOCAL_PORT/api"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required (JSON handling for the Immich API)."
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

# ML mode, most explicit signal first: the IMMICH_ML flag, then a
# hand-edited COMPOSE_PROFILES in .env, then the last deployed mode, then
# off. Whatever wins is reconciled back into both .env and the marker below,
# so the two can never drift apart silently.
if [ -n "${IMMICH_ML:-}" ]; then
  ML_MODE="$IMMICH_ML"
elif [ -f "$ENV_FILE" ] && grep -q '^COMPOSE_PROFILES=.*\bml\b' "$ENV_FILE"; then
  ML_MODE="on"
elif [ -f "$ENV_FILE" ] && grep -q '^COMPOSE_PROFILES=$' "$ENV_FILE"; then
  ML_MODE="off"
elif [ -f "$ML_MARKER" ]; then
  ML_MODE="$(cat "$ML_MARKER")"
else
  ML_MODE="off"
fi
case "$ML_MODE" in on|off) ;; *) die "IMMICH_ML must be 'on' or 'off' (got: $ML_MODE)";; esac

ok "$OS + curl + python3 + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# Immich v3's ML image needs the x86-64-v2 microarchitecture level. Only a
# hard failure when ML is actually being started.
if [ "$ML_MODE" = "on" ] && [ "$OS" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
  missing=""
  for flag in ssse3 sse4_2 popcnt cx16; do
    grep -qw "$flag" /proc/cpuinfo || missing="$missing $flag"
  done
  [ -z "$missing" ] || die "This CPU lacks x86-64-v2 features ($missing), which the Immich v3 ML image requires. Run with IMMICH_ML=off, or pin IMMICH_VERSION=v2.7.5 (unsupported)."
  ok "CPU supports x86-64-v2 (required by the v3 ML image)"
fi

# --------------------------------------------------------------- advisories
if [ "$OS" = "Linux" ]; then
  ram_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
else
  ram_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
fi
if [ "$ML_MODE" = "on" ] && [ "$ram_mb" -lt 8192 ]; then
  warn "${ram_mb} MB RAM with ML on — Immich documents 6 GB minimum / 8 GB recommended, and ollama alone claims ~5 GB while a model is loaded. Expect contention; IMMICH_ML=off is the safe mode until this box has more RAM."
elif [ "$ML_MODE" = "off" ] && [ "$ram_mb" -lt 4096 ]; then
  warn "${ram_mb} MB RAM — tight even with ML off. Add swap if imports get killed."
else
  ok "${ram_mb} MB RAM, ML $ML_MODE"
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated DB password + admin password)"
  # Immich requires a DB password of [A-Za-z0-9] only — hex satisfies that.
  db_pw="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  admin_pw="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file for both interpolation and container env.
IMMICH_VERSION=v3

# Media library and database. The DB must be on local disk — never a
# network share. Changing these means moving the data by hand too.
UPLOAD_LOCATION=$STATE/library
DB_DATA_LOCATION=$STATE/postgres

LOCAL_PORT=$LOCAL_PORT
TZ=$tz

DB_PASSWORD=$db_pw
DB_USERNAME=postgres
DB_DATABASE_NAME=immich

# Admin account, created via /api/auth/admin-sign-up on first deploy.
IMMICH_ADMIN_EMAIL=$ADMIN_EMAIL
IMMICH_ADMIN_PASSWORD=$admin_pw

# Machine learning. setup.sh owns this line — set it with IMMICH_ML=on|off.
# Empty = ML container not started.
COMPOSE_PROFILES=
ML_MEM_LIMIT=3g
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-$ADMIN_EMAIL}"
ADMIN_PASSWORD="${IMMICH_ADMIN_PASSWORD:?IMMICH_ADMIN_PASSWORD missing from $ENV_FILE}"
UPLOAD_LOCATION="${UPLOAD_LOCATION:?UPLOAD_LOCATION missing from $ENV_FILE}"
DB_DATA_LOCATION="${DB_DATA_LOCATION:?DB_DATA_LOCATION missing from $ENV_FILE}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
# .env holds no HTTPS_PORT, so a default HTTPS port keeps following the local
# port .env settled on; an explicit HTTPS_PORT is honoured as given.
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"
API="http://127.0.0.1:$LOCAL_PORT/api"

mkdir -p "$UPLOAD_LOCATION" "$DB_DATA_LOCATION"

avail_kb="$(df -Pk "$UPLOAD_LOCATION" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 20971520 ]; then
  warn "$(( avail_kb / 1048576 )) GB free at $UPLOAD_LOCATION — a Google Takeout import plus generated thumbnails and transcodes will outgrow that. Point UPLOAD_LOCATION at a dedicated disk before importing."
else
  ok "$(( avail_kb / 1048576 )) GB free at $UPLOAD_LOCATION"
fi

# COMPOSE_PROFILES is the one line in .env that setup.sh owns, and it is
# rewritten to match the resolved ML mode. Every other line is left alone.
want_profiles=""
[ "$ML_MODE" = "on" ] && want_profiles="ml"
if [ "${COMPOSE_PROFILES:-}" != "$want_profiles" ]; then
  info "Setting COMPOSE_PROFILES=$want_profiles in .env (ML $ML_MODE)"
  awk -v v="$want_profiles" '/^COMPOSE_PROFILES=/{print "COMPOSE_PROFILES=" v; next} {print}' \
    "$ENV_FILE" > "$WORK/env.new"
  grep -q '^COMPOSE_PROFILES=' "$ENV_FILE" || echo "COMPOSE_PROFILES=$want_profiles" >> "$WORK/env.new"
  cat "$WORK/env.new" > "$ENV_FILE"   # rewrite in place, preserving mode 600
fi

# ---------------------------------------------------------------- deploy
# Sourcing .env above exported its COMPOSE_PROFILES into this shell, and
# Compose prefers the environment over the file — so on an on->off flip a
# stale export would keep starting the ML container. Pin it to the mode we
# actually decided, and pass --profile too so both agree.
export COMPOSE_PROFILES="$want_profiles"
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")
[ "$ML_MODE" = "on" ] && COMPOSE+=(--profile ml)

info "Starting containers (docker compose up -d) — first run pulls ~2 GB of images"
"${COMPOSE[@]}" up -d

# Switching ML off: stop and remove the container the profile no longer covers.
if [ "$ML_MODE" = "off" ] && docker ps -a --format '{{.Names}}' | grep -qx immich_machine_learning; then
  info "ML is off — removing the immich_machine_learning container"
  docker compose --project-directory "$SERVICE_DIR" --profile ml rm -sf immich-machine-learning >/dev/null 2>&1 \
    || docker rm -f immich_machine_learning >/dev/null 2>&1 || true
fi

info "Waiting for Immich on 127.0.0.1:$LOCAL_PORT (first boot runs DB migrations)"
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "$API/server/ping" 2>/dev/null; then
    ok "Immich is answering locally"
    break
  fi
  [ "$i" -eq 90 ] && die "Immich did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs immich-server"
  sleep 3
done

# ------------------------------------------------------------- API helpers
API_CODE=""
TOKEN=""
api() {  # api METHOD PATH [body-file] -> body on stdout, code in $API_CODE
  local method="$1" path="$2" bodyfile="${3:-}"
  local out="$WORK/resp.json"
  set -- -sS -X "$method" -H "Content-Type: application/json" -o "$out" -w '%{http_code}'
  [ -n "$TOKEN" ] && set -- "$@" -H "Authorization: Bearer $TOKEN"
  [ -n "$bodyfile" ] && set -- "$@" --data-binary "@$bodyfile"
  API_CODE="$(curl "$@" "$API$path" 2>/dev/null || echo 000)"
  cat "$out" 2>/dev/null || true
}

jget() { python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(d)
' "$1" 2>/dev/null; }

# --------------------------------------------------- admin account (once)
FIRST_RUN=0
python3 -c '
import json, sys
print(json.dumps({"email": sys.argv[1], "name": sys.argv[2], "password": sys.argv[3]}))
' "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_PASSWORD" > "$WORK/signup.json"

api POST /auth/admin-sign-up "$WORK/signup.json" >/dev/null
case "$API_CODE" in
  200|201) FIRST_RUN=1; ok "Admin account created: $ADMIN_EMAIL" ;;
  400)     ok "Admin account already exists — leaving it alone" ;;
  *)       die "admin-sign-up returned HTTP $API_CODE. Logs: docker compose --project-directory $SERVICE_DIR logs immich-server" ;;
esac

python3 -c '
import json, sys
print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))
' "$ADMIN_EMAIL" "$ADMIN_PASSWORD" > "$WORK/login.json"

TOKEN="$(api POST /auth/login "$WORK/login.json" | jget accessToken || true)"
if [ -z "$TOKEN" ]; then
  warn "Could not log in as $ADMIN_EMAIL — the password in .env no longer matches the server (changed in the web UI?). Skipping settings; mirror the new password into $ENV_FILE to re-enable automated tuning."
fi

# The admin config endpoint was renamed from /system-config to /admin/config
# after v3.1.0. Probe for the new one and fall back, so this works across the
# rename in both directions.
CONFIG_PATH="/admin/config"
if [ -n "$TOKEN" ]; then
  api GET "$CONFIG_PATH" >/dev/null
  if [ "$API_CODE" = "404" ]; then
    CONFIG_PATH="/system-config"
    info "Using the pre-rename config endpoint ($CONFIG_PATH)"
  fi
fi

# ------------------------------------------------- settings (surgical PUT)
# Fetch the live config, change only the keys we own, put it back. On a
# re-run this touches the ML toggle only, so anything tuned in the web UI
# since the first deploy survives.
if [ -n "$TOKEN" ]; then
  # The marker — not the admin account — records that a settings pass has
  # actually completed. If an earlier run died between creating the admin and
  # writing settings, this still applies the tuning on the next run.
  if [ -f "$ML_MARKER" ]; then TUNE=no; else TUNE=yes; fi
  need_config_write=0
  [ "$TUNE" = "yes" ] && need_config_write=1
  [ "$(cat "$ML_MARKER" 2>/dev/null || echo none)" != "$ML_MODE" ] && need_config_write=1

  if [ "$need_config_write" = "1" ]; then
    api GET "$CONFIG_PATH" > "$WORK/config.json"
    [ "$API_CODE" = "200" ] || die "GET /api$CONFIG_PATH returned HTTP $API_CODE"

    TUNE="$TUNE" ML_MODE="$ML_MODE" ML_URL="$ML_URL" \
    python3 - "$WORK/config.json" "$WORK/config.new.json" <<'PY'
import json, os, sys

src, dst = sys.argv[1], sys.argv[2]
cfg = json.load(open(src))
ml_on = os.environ["ML_MODE"] == "on"

ml = cfg.setdefault("machineLearning", {})
ml["enabled"] = ml_on
if ml_on or not ml.get("urls"):
    ml["urls"] = [os.environ["ML_URL"]]

# First deploy only: settings sized for a small, shared box. The Immich FAQ's
# own advice for an overloaded host — concurrency 1 on the CPU-heavy jobs,
# few ffmpeg threads, and the small face model.
if os.environ["TUNE"] == "yes":
    for job in ("smartSearch", "faceDetection", "thumbnailGeneration", "videoConversion", "ocr"):
        if job in cfg.get("job", {}):
            cfg["job"][job]["concurrency"] = 1
    if "ffmpeg" in cfg:
        cfg["ffmpeg"]["threads"] = 2
    fr = ml.get("facialRecognition")
    if isinstance(fr, dict):
        fr["modelName"] = "buffalo_s"

json.dump(cfg, open(dst, "w"))
PY

    api PUT "$CONFIG_PATH" "$WORK/config.new.json" >/dev/null
    if [ "$API_CODE" = "200" ]; then
      [ "$TUNE" = "yes" ] && ok "Applied low-RAM job tuning (concurrency 1, ffmpeg threads 2, buffalo_s)"
      ok "Machine learning set to: $ML_MODE"
      printf '%s' "$ML_MODE" > "$ML_MARKER"
    else
      warn "PUT /api$CONFIG_PATH returned HTTP $API_CODE — set Machine Learning manually in Administration → Settings."
    fi
  else
    ok "Settings unchanged (ML already $ML_MODE)"
  fi

  # Dismiss the first-run onboarding wizard.
  if [ "$TUNE" = "yes" ] || [ "$FIRST_RUN" = "1" ]; then
    echo '{"isOnboarded":true}' > "$WORK/onboard.json"
    api POST /system-metadata/admin-onboarding "$WORK/onboard.json" >/dev/null || true
  fi
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

host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ------------------------------------------------------------ final check
url="https://$host:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/api/server/ping"; then
  ok "End-to-end check passed"
else
  echo "    Cert may still be minting — try again in a minute: curl $url/api/server/ping"
fi

echo
printf '\033[1;32mDone.\033[0m Immich is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "  Login:   $ADMIN_EMAIL"
echo "  Password: see IMMICH_ADMIN_PASSWORD in $ENV_FILE"
echo "  Machine learning: $ML_MODE$([ "$ML_MODE" = off ] && echo '  (no semantic search / face grouping / OCR)')"
echo
echo "Phone app: install Immich from the App Store, choose 'Server Endpoint',"
echo "  enter $url/api — the phone must be on the tailnet."
echo "  Turn OFF Seafile camera upload first; running two backups doubles storage."
echo
echo "Google Takeout import (preserves albums + original dates, which the web"
echo "  uploader loses):  immich-go upload from-google-photos --server=$url \\"
echo "                      --api-key=<key from Account Settings> takeout-*.zip"
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"
[ "$ML_MODE" = "off" ] && echo "Enable ML later (after a RAM upgrade): IMMICH_ML=on ./setup.sh"
exit 0
