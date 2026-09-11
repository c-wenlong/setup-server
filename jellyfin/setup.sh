#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Jellyfin (self-hosted media server) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - a single `jellyfin` container (SQLite library DB inside /config — no
#     database sidecar)
#   - published on 127.0.0.1:LOCAL_PORT only
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - the first-run setup wizard driven to completion over the API, with the
#     admin account created from a generated password — no setup screen, ever
#   - media mounted READ-ONLY from MEDIA_DIR
#   - boot-persistent via Docker's restart policy (no systemd/launchd needed)
#
# Usage:
#   ./setup.sh                              # local 8096, HTTPS 8096
#   LOCAL_PORT=8097 HTTPS_PORT=8097 ./setup.sh
#   MEDIA_DIR=/srv/media ./setup.sh         # first run only; .env wins after
#   JELLYFIN_ADMIN_USERNAME=kai ./setup.sh  # first run only; .env wins after
#
# Version: pinned to the `12.0` tag (reports 12.0.0). Deliberately not
# `latest` — a media server that jumps a major version on its own can
# invalidate the library database and every client's saved login.
#
# Transcoding is software unless JELLYFIN_NVENC=on in .env, in which case
# docker-compose.gpu.yml is layered on and the container gets the GPU. This
# script never installs the GPU plumbing itself — that needs sudo and lives in
# ./enable-nvenc.sh, which sets the flag once the runtime is proven to work.
# A flag set without that runtime is caught below rather than left to surface
# as an unstartable container.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# An existing .env is never overwritten, and the setup wizard runs at most
# once — a re-run detects the completed wizard and leaves the server alone.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8096}"
HTTPS_PORT="${HTTPS_PORT:-8096}"
ADMIN_USERNAME="${JELLYFIN_ADMIN_USERNAME:-kai}"
CONTAINER="jellyfin"

# Captured before .env is sourced, because sourcing overwrites MEDIA_DIR with
# the file's value. On a first run this seeds the file; afterwards .env wins
# and a mismatch is warned about, so a re-run can never silently move a live
# library out from under the running server.
REQUESTED_MEDIA_DIR="${MEDIA_DIR:-}"

# Same reason, different consequence: sourcing .env would overwrite a
# JELLYFIN_NVENC passed on the command line, so `JELLYFIN_NVENC=off ./setup.sh`
# would silently keep transcoding on the GPU. Unlike MEDIA_DIR (where .env
# wins, because moving a live library by accident is unrecoverable) this flag
# follows immich's IMMICH_ML idiom: the explicit request wins and is written
# back, because flipping a transcoder is cheap and reversible.
REQUESTED_NVENC="${JELLYFIN_NVENC:-}"

# Metadata locale for the wizard. Affects which region's release dates,
# certifications and artwork Jellyfin prefers when it scrapes.
UI_CULTURE="${JELLYFIN_UI_CULTURE:-en-US}"
METADATA_COUNTRY="${JELLYFIN_METADATA_COUNTRY:-SG}"
METADATA_LANGUAGE="${JELLYFIN_METADATA_LANGUAGE:-en}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/jellyfin"
WIZARD_MARKER="$STATE/.wizard-complete"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars: [A-Za-z0-9]-safe, so it survives .env, shell quoting, JSON
# bodies and a phone's on-screen keyboard without escaping. python3 when
# present, /dev/urandom otherwise — no hard dependency on python for what is
# just random bytes.
randhex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    echo
  fi
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

# The username goes into a JSON body verbatim; keep it to characters that
# need no escaping rather than shipping a hand-rolled JSON escaper.
case "$ADMIN_USERNAME" in
  ''|*[!A-Za-z0-9._-]*) die "JELLYFIN_ADMIN_USERNAME must be [A-Za-z0-9._-] only (got: $ADMIN_USERNAME)";;
esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The tailnet name is needed *before* the container starts, not after: it goes
# into PublishedServerUrl, and Jellyfin hands that address to every client for
# streaming, remote sessions and cast targets. A wrong value produces
# working-but-useless localhost links rather than an error, so resolve it up
# front and verify it at the end.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated admin password)"
  admin_pw="$(randhex)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
# It is NOT passed to the container as env_file — the admin password below
# must not end up in the container's environment.

# Pinned exactly. Do not float to \`latest\`: a major-version jump can
# invalidate the library database and every client's saved login.
JELLYFIN_VERSION=12.0

LOCAL_PORT=$LOCAL_PORT
TZ=$tz

# Library database, users, metadata, artwork, plugins — the state directory,
# and the only thing here worth backing up. \`cache\` is regenerable.
JELLYFIN_CONFIG=$STATE/config
JELLYFIN_CACHE=$STATE/cache

# THE LIBRARY. Mounted read-only at /media inside the container. Point this at
# wherever the films/shows/music actually live — an external disk, a NAS mount,
# anything this user can read — then re-run setup.sh. The default below starts
# out empty, and Jellyfin has nothing to show until something is in it.
MEDIA_DIR=${REQUESTED_MEDIA_DIR:-$STATE/media}

# The container runs as this uid/gid so nothing in the bind mounts ends up
# root-owned. It must be able to read MEDIA_DIR.
JELLYFIN_UID=$(id -u)
JELLYFIN_GID=$(id -g)

# Public identity. Jellyfin advertises this to clients for streaming and
# remote sessions; without it they are told to fetch video from 127.0.0.1.
# If the machine is renamed or the HTTPS port moves, edit this line and re-run
# setup.sh — it warns when the value drifts from the live tailnet name.
JELLYFIN_PUBLISHED_URL=https://$TS_HOST:$HTTPS_PORT

# Admin account, created once by driving the first-run wizard over the API.
JELLYFIN_ADMIN_USERNAME=$ADMIN_USERNAME
JELLYFIN_ADMIN_PASSWORD=$admin_pw

# Hardware transcoding. Off means ffmpeg on the CPU, which handles 1080p.
# Do not set this to \`on\` by hand — Docker needs the \`nvidia\` runtime first,
# and without it the container will not start. Run ./enable-nvenc.sh instead;
# it installs the runtime, proves it works, and then flips this line.
JELLYFIN_NVENC=off
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
ADMIN_USERNAME="${JELLYFIN_ADMIN_USERNAME:?JELLYFIN_ADMIN_USERNAME missing from $ENV_FILE}"
ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:?JELLYFIN_ADMIN_PASSWORD missing from $ENV_FILE}"
CONFIG_DIR="${JELLYFIN_CONFIG:?JELLYFIN_CONFIG missing from $ENV_FILE}"
CACHE_DIR="${JELLYFIN_CACHE:?JELLYFIN_CACHE missing from $ENV_FILE}"
LIBRARY_DIR="${MEDIA_DIR:?MEDIA_DIR missing from $ENV_FILE}"
PUBLISHED_URL="${JELLYFIN_PUBLISHED_URL:?JELLYFIN_PUBLISHED_URL missing from $ENV_FILE}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
if [ -n "$REQUESTED_MEDIA_DIR" ] && [ "$LIBRARY_DIR" != "$REQUESTED_MEDIA_DIR" ]; then
  warn "MEDIA_DIR=$REQUESTED_MEDIA_DIR ignored — the existing $ENV_FILE says $LIBRARY_DIR. Edit MEDIA_DIR in .env and re-run to move the library."
fi

# Drift check, not a rewrite: .env is the user's file. But a published URL that
# no longer matches this machine hands clients an unreachable address, and
# playback fails with nothing useful in the logs — so say so loudly.
WANT_PUBLISHED_URL="https://$TS_HOST:$HTTPS_PORT"
if [ "$PUBLISHED_URL" != "$WANT_PUBLISHED_URL" ]; then
  warn "JELLYFIN_PUBLISHED_URL in .env is $PUBLISHED_URL but this box now answers to $WANT_PUBLISHED_URL."
  warn "  Clients will be handed the old address and playback will fail. Fix: set JELLYFIN_PUBLISHED_URL=$WANT_PUBLISHED_URL in $ENV_FILE, then re-run."
fi

mkdir -p "$STATE" "$CONFIG_DIR" "$CACHE_DIR" "$LIBRARY_DIR"
[ -w "$CONFIG_DIR" ] || die "$CONFIG_DIR is not writable by $USER. The container runs as $(id -u):$(id -g); an earlier run as root may have left it owned by root. Fix: sudo chown -R $(id -u):$(id -g) $STATE"
[ -r "$LIBRARY_DIR" ] || die "$LIBRARY_DIR is not readable by $USER — the container runs as $(id -u):$(id -g) and would see an empty library."

# Media is what fills a disk on this box: one 4K film is ~40 GB, and Jellyfin
# adds artwork and transcode temp files on top.
avail_kb="$(df -Pk "$LIBRARY_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 52428800 ]; then
  warn "$(( avail_kb / 1048576 )) GB free at $LIBRARY_DIR — a media library outgrows that fast (a single 4K film is ~40 GB, and transcode temp files land under $CONFIG_DIR). Point MEDIA_DIR at a dedicated disk before copying anything in."
else
  ok "$(( avail_kb / 1048576 )) GB free at $LIBRARY_DIR"
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

# Hardware transcoding, as an overlay rather than a commented-out block in the
# base file. Most explicit signal first: the flag on the command line, then
# whatever .env last recorded (how enable-nvenc.sh persists it), then off.
NVENC_MODE="${REQUESTED_NVENC:-${JELLYFIN_NVENC:-off}}"
case "$NVENC_MODE" in on|off) ;; *) die "JELLYFIN_NVENC must be 'on' or 'off' (got: $NVENC_MODE)";; esac

# setup.sh owns this one line in .env, so the file always describes what is
# actually deployed — otherwise `JELLYFIN_NVENC=off ./setup.sh` would fix the
# running container and leave .env claiming the GPU is in use.
#
# Compare against what the FILE says, not against $JELLYFIN_NVENC. Sourcing
# .env cannot clear a variable the file does not mention, so on an .env
# predating this flag the shell still holds the caller's own JELLYFIN_NVENC=on
# — which equals $NVENC_MODE, and the line would never be written. That is
# exactly what happened on 2026-09-11: the GPU was attached and running while
# .env carried no flag at all, so the next plain ./setup.sh would silently
# have dropped back to software transcoding. The mocked suite missed it
# because a sandbox .env is always freshly generated, and therefore always
# already has the line.
recorded_nvenc="$(sed -n 's/^JELLYFIN_NVENC=//p' "$ENV_FILE" | head -1)"
if [ "$recorded_nvenc" != "$NVENC_MODE" ]; then
  info "Recording JELLYFIN_NVENC=$NVENC_MODE in .env"
  if grep -q '^JELLYFIN_NVENC=' "$ENV_FILE"; then
    awk -v v="$NVENC_MODE" '/^JELLYFIN_NVENC=/{print "JELLYFIN_NVENC=" v; next} {print}' \
      "$ENV_FILE" > "$WORK/env.new"
    cat "$WORK/env.new" > "$ENV_FILE"   # rewrite in place: keeps mode 600
  else
    printf '\n# Hardware transcoding; owned by setup.sh. See ./enable-nvenc.sh\nJELLYFIN_NVENC=%s\n' "$NVENC_MODE" >> "$ENV_FILE"
  fi
fi

if [ "$NVENC_MODE" = "on" ]; then
  GPU_OVERLAY="$SERVICE_DIR/docker-compose.gpu.yml"
  [ -f "$GPU_OVERLAY" ] || die "JELLYFIN_NVENC=on but $GPU_OVERLAY is missing."
  # Fail here, with an explanation, rather than letting compose fail with
  # "could not select device driver \"nvidia\"" — which reads like a Jellyfin
  # problem and is really a missing host package.
  if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    die "JELLYFIN_NVENC=on but dockerd has no \`nvidia\` runtime — nvidia-container-toolkit is not installed or not registered, and the container would fail to start. Fix: $SERVICE_DIR/enable-nvenc.sh (installs it, needs sudo). Or set JELLYFIN_NVENC=off in $ENV_FILE to stay on software transcoding."
  fi
  COMPOSE+=(-f "$SERVICE_DIR/docker-compose.yml" -f "$GPU_OVERLAY")
  ok "Hardware transcoding ON — layering docker-compose.gpu.yml (NVENC)"
else
  ok "Hardware transcoding off — software (ffmpeg on the CPU)"
fi

info "Starting Jellyfin (docker compose up -d) — first run pulls ~500 MB"
"${COMPOSE[@]}" up -d

# ------------------------------------------------------------- API helpers
JF_CODE=""
JF_BASE="http://127.0.0.1:$LOCAL_PORT"
# Jellyfin rejects /Users/AuthenticateByName without an identifying
# MediaBrowser authorization header. Harmless on the /Startup endpoints, so
# it is sent on every request rather than special-cased.
JF_AUTH='Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup-1", Version="1.0"'

jf() {  # jf METHOD PATH [body-file] -> body in $WORK/resp.json, code in $JF_CODE
  local method="$1" path="$2" bodyfile="${3:-}"
  set -- -sS -X "$method" -H 'Content-Type: application/json' -H "$JF_AUTH" \
         -o "$WORK/resp.json" -w '%{http_code}' --max-time 60
  [ -n "$bodyfile" ] && set -- "$@" --data-binary "@$bodyfile"
  # curl already prints 000 to stdout when it cannot connect, AND exits
  # non-zero. A `|| echo 000` fallback therefore CONCATENATES, turning a
  # plain connection failure into the nonsense code "000000" in the error
  # message. Take curl's own output and normalise anything unexpected.
  JF_CODE="$(curl "$@" "$JF_BASE$path" 2>/dev/null)" || true
  case "$JF_CODE" in
    [0-9][0-9][0-9]) ;;      # a real (or 000) code
    *) JF_CODE=000 ;;
  esac
}

# Same as jf(), but rides out a connection refusal.
#
# Jellyfin answers /Startup/* several seconds BEFORE "Startup complete"
# appears in its log, and during that window a request can still be refused
# outright. The first real deploy died exactly there: readiness passed, then
# POST /Startup/Configuration came back 000, leaving a half-applied wizard.
# Retrying a 000 costs nothing when the server is genuinely down (the caller
# still fails, just later) and removes the race when it is merely not ready.
jf_retry() {  # jf_retry METHOD PATH [body-file]
  local attempt=1
  while :; do
    jf "$@"
    [ "$JF_CODE" != "000" ] && return 0
    [ "$attempt" -ge 10 ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
}

# Whitespace-insensitive matches against a response body.
resp_has_file() { tr -d ' \n\r' < "$1" 2>/dev/null | grep -qi -- "$2"; }
resp_has()      { resp_has_file "$WORK/resp.json" "$1"; }

wizard_completed() {
  jf GET /System/Info/Public
  [ "$JF_CODE" = "200" ] || return 1
  resp_has '"StartupWizardCompleted":true'
}

# Same shape as jf_retry, for the same reason, one endpoint later.
#
# The readiness gate above waits for /Startup/FirstUser to stop returning
# 503 — and on an already-configured server "not 503" means a 401 from the
# auth layer, which comes up SEVERAL SECONDS BEFORE the server config that
# carries StartupWizardCompleted is loaded. So /System/Info/Public transiently
# answers 200 with StartupWizardCompleted:FALSE on a perfectly healthy server.
#
# Observed for real on 2026-09-11, on a container restart to attach the GPU:
# a single sample said false, and the stale-marker branch below concluded the
# config directory had been wiped — telling the user to delete the wizard
# marker and re-run the wizard against a live server with a real library on
# it. The diagnosis was wrong and the suggested repair was worse than the
# imaginary fault, so only ever conclude "wiped" after the reading settles.
#
# Deliberately NOT used on the no-marker path: there, false is the expected
# answer on a genuine first run, and waiting 30s for it would tax every fresh
# deploy to pay for a case that cannot happen (no marker means no prior run).
wizard_completed_settled() {
  local attempt=1
  while :; do
    wizard_completed && return 0
    [ "$attempt" -ge 15 ] && return 1
    sleep 2
    attempt=$((attempt + 1))
  done
}

# -------------------------------------------------------------- readiness
# The trap: /System/Info/Public answers 200 while the server is STILL LOADING,
# and every /Startup endpoint answers 503 ("Jellyfin Server is loading. Please
# try again shortly.") during that window. Gating on /System/Info/Public wins
# the race often enough to look fine and then loses it: POST /Startup/User
# 404s while the other three steps return 204, leaving a *completed* wizard
# with NO admin account. So poll the endpoint we actually need, and wait for
# it to stop saying 503. Do not replace this with a sleep.
#
# This also works on a re-run: once the wizard is done /Startup/FirstUser
# answers 401, which is "loaded" as far as this loop is concerned.
info "Waiting for Jellyfin to finish loading on 127.0.0.1:$LOCAL_PORT"
ready=0
for i in $(seq 1 90); do
  jf GET /Startup/FirstUser
  case "$JF_CODE" in
    000) : ;;   # not listening yet
    503) : ;;   # listening, still loading — this is the race
    *)   ready=1; break ;;
  esac
  sleep 2
done
[ "$ready" = "1" ] || die "Jellyfin never finished loading (last HTTP $JF_CODE). Logs: docker compose --project-directory $SERVICE_DIR logs jellyfin"
ok "Jellyfin has finished loading"

# ------------------------------------------------- first-run wizard (once)
# Two layers of idempotency, because either one alone is wrong:
#   - the marker means a normal re-run does not touch the wizard at all
#   - StartupWizardCompleted on the live server is the authority, so a run
#     that died after completing the wizard but before writing the marker
#     recovers cleanly instead of re-running steps that would now fail
if [ -f "$WIZARD_MARKER" ]; then
  # The marker is a cache, not the truth. If it survived a wiped $CONFIG_DIR
  # the server is back at first-run with no users, and skipping the wizard
  # here would surface much later as "login rejected" — which blames the
  # password instead of the wipe. Cross-check and say exactly that.
  if wizard_completed_settled; then
    ok "Setup wizard already completed ($ADMIN_USERNAME) — skipping"
  else
    die "Stale marker: $WIZARD_MARKER says the wizard has run, but the server has reported StartupWizardCompleted=false for 30s straight — so this is not the cold-start race, and $CONFIG_DIR was probably deleted or replaced, leaving no admin account. Before believing that, check the library is really gone: ls $CONFIG_DIR/data (a healthy install has jellyfin.db in there). If it IS gone: rm $WIZARD_MARKER && ./setup.sh re-runs the wizard and recreates $ADMIN_USERNAME from $ENV_FILE. If the data is still there, do NOT delete the marker — re-running the wizard against a configured server does not help."
  fi
elif wizard_completed; then
  ok "Server reports the setup wizard is already complete — skipping (writing the marker)"
  printf '%s\n' "$ADMIN_USERNAME" > "$WIZARD_MARKER"
else
  info "Driving the first-run wizard (admin account: $ADMIN_USERNAME)"

  step() {  # step PATH BODY-FILE DESCRIPTION
    jf_retry POST "$1" "$2"
    case "$JF_CODE" in
      2*) ok "  $3" ;;
      503) die "$3 got HTTP 503 — the server went back to loading mid-wizard. Re-run setup.sh; it resumes from where the server actually is." ;;
      *)  die "$3 failed (HTTP $JF_CODE). The wizard is half-applied; the safest repair is to stop the container, delete $CONFIG_DIR, and re-run setup.sh. Logs: docker compose --project-directory $SERVICE_DIR logs jellyfin" ;;
    esac
  }

  printf '{"UICulture":"%s","MetadataCountryCode":"%s","PreferredMetadataLanguage":"%s"}' \
    "$UI_CULTURE" "$METADATA_COUNTRY" "$METADATA_LANGUAGE" > "$WORK/config.json"
  printf '{"Name":"%s","Password":"%s"}' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" > "$WORK/user.json"
  # Remote access on, automatic port mapping off: UPnP would try to punch a
  # hole in the router, and this server is reachable over the tailnet only.
  printf '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' > "$WORK/remote.json"
  printf '{}' > "$WORK/complete.json"

  step /Startup/Configuration "$WORK/config.json" "Locale ($UI_CULTURE, $METADATA_COUNTRY, $METADATA_LANGUAGE)"
  step /Startup/User          "$WORK/user.json"   "Admin account created: $ADMIN_USERNAME"
  step /Startup/RemoteAccess  "$WORK/remote.json" "Remote access on, UPnP port mapping off"
  step /Startup/Complete      "$WORK/complete.json" "Wizard marked complete"

  wizard_completed || die "The wizard steps all succeeded but the server still reports StartupWizardCompleted=false. Logs: docker compose --project-directory $SERVICE_DIR logs jellyfin"
  printf '%s\n' "$ADMIN_USERNAME" > "$WIZARD_MARKER"
  ok "Setup wizard complete — no first-run screen"
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
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ final check
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o "$WORK/public.json" --max-time 90 "$url/System/Info/Public"; then
  ok "End-to-end HTTPS check passed"
  # LocalAddress on /System/Info/Public is exactly what PublishedServerUrl was
  # set to — it is the address handed to clients, so if it says localhost,
  # playback on every other device would fail with nothing useful in the logs.
  if resp_has_file "$WORK/public.json" "\"LocalAddress\":\"$url\""; then
    ok "Clients will be told to stream from $url"
  else
    warn "Jellyfin is advertising an address that is not $url — check JELLYFIN_PUBLISHED_URL in $ENV_FILE (live value: $(tr -d ' \n' < "$WORK/public.json" | sed -n 's/.*"LocalAddress":"\([^"]*\)".*/\1/p'))"
  fi
else
  warn "No answer on $url/System/Info/Public yet — the cert may still be minting. Retry in a minute: curl $url/System/Info/Public"
fi

# One authenticated request over HTTPS proves the whole chain: Serve routes,
# the generated password actually logs in, and the account is an administrator.
#
# Do NOT be tempted to check GET /Users/Public instead — it lists only users
# marked visible on the login screen and returns [] on a perfectly healthy
# server, which makes a working deploy look broken.
JF_BASE="$url"
printf '{"Username":"%s","Pw":"%s"}' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" > "$WORK/auth.json"
jf POST /Users/AuthenticateByName "$WORK/auth.json"
case "$JF_CODE" in
  401|403)
    die "Login as $ADMIN_USERNAME was rejected (HTTP $JF_CODE). The password in $ENV_FILE does not match the server — changed in the web UI? Mirror it back into .env, or reset it from Dashboard -> Users -> $ADMIN_USERNAME -> Password."
    ;;
  200)
    if resp_has '"IsAdministrator":true'; then
      ok "Signed in as $ADMIN_USERNAME over HTTPS; account is an administrator"
    else
      die "Signed in as $ADMIN_USERNAME over HTTPS, but the account is not an administrator. Grant it in Dashboard -> Users -> $ADMIN_USERNAME -> Allow this user to manage the server."
    fi
    ;;
  *)
    die "Could not authenticate over HTTPS (HTTP $JF_CODE). Check by hand: curl -X POST -H 'Content-Type: application/json' -H '$JF_AUTH' -d '{\"Username\":\"$ADMIN_USERNAME\",\"Pw\":\"<password from .env>\"}' $url/Users/AuthenticateByName"
    ;;
esac

# ------------------------------------------------------------- media note
media_count="$(ls -A "$LIBRARY_DIR" 2>/dev/null | wc -l | tr -d ' ')"

echo
printf '\033[1;32mDone.\033[0m Jellyfin is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "  Login:    $ADMIN_USERNAME"
echo "  Password: see JELLYFIN_ADMIN_PASSWORD in $ENV_FILE"
echo "  No setup wizard: it was completed over the API, so the first screen is"
echo "    the login form, not a first-run questionnaire."
echo
if [ "$media_count" = "0" ]; then
  printf '\033[1;33m ! \033[0m %s\n' "The library is EMPTY — this is the expected first-run state, not a failure."
  echo "    Jellyfin has nothing to show until there is media at:"
  echo "      $LIBRARY_DIR"
  echo "    Two ways forward:"
  echo "      a) copy files in:  cp -r /path/to/films/* $LIBRARY_DIR/"
  echo "      b) repoint it:     set MEDIA_DIR=/where/the/media/lives in $ENV_FILE"
  echo "                         then re-run ./setup.sh"
  echo "    Then in the web UI: Dashboard -> Libraries -> Add Media Library,"
  echo "      pick the content type, and add the folder /media (that is where"
  echo "      MEDIA_DIR is mounted inside the container — read-only)."
else
  echo "Library: $media_count entries under $LIBRARY_DIR (mounted read-only at /media)."
  echo "  Add it in the web UI: Dashboard -> Libraries -> Add Media Library ->"
  echo "  choose the content type and point it at /media."
fi
echo "  Name files so the scrapers can match them:"
echo "    Films/Blade Runner (1982)/Blade Runner (1982).mkv"
echo "    Shows/Severance/Season 01/Severance S01E01.mkv"
echo
echo "Client apps (each device must be on the tailnet, then use $url):"
echo "  Desktop:  Jellyfin Media Player   Phone/tablet: Jellyfin for Android / Swiftfin (iOS)"
echo "  TV:       Jellyfin for Android TV, Fire TV, Roku, Kodi (Jellyfin add-on)"
echo "  Browser:  just open $url"
echo
if [ "$NVENC_MODE" = "on" ]; then
  echo "Transcoding: NVENC (GPU). Jellyfin still has to be told to use it in"
  echo "  Dashboard -> Playback -> Transcoding. Confirm with: nvidia-smi dmon -s u"
else
  echo "Transcoding is software (ffmpeg on the CPU) — fine for 1080p. To put the"
  echo "  GPU to work: ./enable-nvenc.sh (one time, needs sudo)."
fi
echo "  Prefer direct play either way: a file the client can render as-is never"
echo "  transcodes at all, on the CPU or the GPU."
echo
echo "Backups: nothing backs this box up. The library database, users, watch"
echo "  state and artwork live in $CONFIG_DIR — that is the backup target;"
echo "  $CACHE_DIR is regenerable and the media itself is not written to."
echo "  Cold copy:  docker compose --project-directory $SERVICE_DIR stop &&"
echo "              tar czf jellyfin-\$(date +%F).tgz -C $CONFIG_DIR . &&"
echo "              docker compose --project-directory $SERVICE_DIR start"
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: edit JELLYFIN_VERSION in $ENV_FILE, then"
echo "         docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"
exit 0
