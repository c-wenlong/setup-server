#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Homepage (https://gethomepage.dev), a
# self-hosted service dashboard, behind Tailscale. Linux + macOS.
#
# End state:
#   - a single `homepage` container, image pinned to v1.4.5
#   - listening on 127.0.0.1:LOCAL_PORT ONLY, published tailnet-only at
#     https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - config/*.yaml seeded from this repo with the real services on this box
#     and their real tailnet URLs, so the first page load is useful rather
#     than the upstream "My First Service" placeholder
#   - live status dots driven by loopback health probes, with NO Docker
#     socket mounted
#
# Usage:
#   ./setup.sh                                   # local 8100, HTTPS 8100
#   LOCAL_PORT=8101 ./setup.sh                   # HTTPS follows LOCAL_PORT (8101 -> 8101)
#   LOCAL_PORT=8100 HTTPS_PORT=8100 ./setup.sh
#
# ---------------------------------------------------------------------------
# THE THING THAT SILENTLY BREAKS THIS SERVICE
#
# Homepage v1.4.5 validates the HTTP Host header against an allowlist and
# answers 400 to anything not on it. The allowlist defaults to
# localhost:$PORT and 127.0.0.1:$PORT — the tailnet name is NOT on it — and
# `tailscale serve` forwards the Host verbatim, PORT INCLUDED. So without
# HOMEPAGE_ALLOWED_HOSTS naming "<tailnet-host>:<https-port>" exactly, the
# dashboard is broken over the tailnet.
#
# And it breaks quietly. The validation middleware matches only /api/*, so
# GET / still returns a 200 HTML page that is BYTE-IDENTICAL to the working
# one — the group names are server-rendered into it either way. Every widget,
# every status dot and every service list then 400s in the browser. A check
# that asserts "200" or even "real Homepage markup" on / goes green against a
# completely broken dashboard. The verify step below therefore fetches
# /api/services THROUGH THE TAILNET URL, which is the only request that can
# tell the two states apart.
# ---------------------------------------------------------------------------
#
# HOST NETWORKING, deliberately. Every service on this box binds 127.0.0.1,
# and a bridge-network container cannot reach any of them (measured: container
# loopback refused, bridge gateway refused, MagicDNS NXDOMAIN). Homepage runs
# in the host namespace so its health probes work, and is pinned to
# HOSTNAME=127.0.0.1 so the socket is still loopback-only. See
# docker-compose.yml.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# An existing .env is never overwritten, and a config file you have edited is
# never touched — only files that are MISSING get seeded.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8100}"
# The HTTPS port follows the local port unless set explicitly (the n8n and
# kaichenpedia convention), so overriding only LOCAL_PORT cannot split the
# two. Whether it was explicit is remembered for the .env read-back below.
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
CONTAINER="homepage"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
TEMPLATE_DIR="$SERVICE_DIR/config"
STATE="$HOME/services/homepage"

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

# `network_mode: host` means what it says on Linux and means nothing useful on
# macOS: Docker Desktop runs containers inside a Linux VM, so the "host"
# network is the VM's, and 127.0.0.1 there is not this Mac. Every siteMonitor
# probe would fail and the published port would not appear on the Mac either.
# Say so up front rather than letting the verify step blame the config.
if [ "$OS" = "Darwin" ]; then
  warn "macOS: Docker runs containers in a Linux VM, so network_mode: host does NOT share this Mac's loopback."
  warn "  Homepage will start, but every siteMonitor probe at http://127.0.0.1:<port> will fail and the"
  warn "  listener will not appear on this Mac. Untested here. On a Mac, switch docker-compose.yml back to"
  warn "  a bridge network with 'ports: 127.0.0.1:$LOCAL_PORT:3000' and point siteMonitor at tailnet URLs."
fi

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac

[ -d "$TEMPLATE_DIR" ] || die "Config templates are missing: $TEMPLATE_DIR. This directory ships with the repo; re-clone or restore it."

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The MagicDNS name, for `tailscale serve`, for the final URL, and — the part
# that matters — for HOMEPAGE_ALLOWED_HOSTS and for the href of every tile.
#
# `|| true` is load-bearing: under `set -euo pipefail` a command substitution
# whose pipeline fails makes the ASSIGNMENT fail, and errexit kills the script
# on that line, BEFORE the emptiness check written to explain it. `grep -o`
# exits 1 when MagicDNS is off. Swallow the status; the check below decides.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?). Homepage needs it for HOMEPAGE_ALLOWED_HOSTS — without it every API call over the tailnet returns 400."
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.

# Pinned exactly; :latest drifts. Measured against this version: the host
# allowlist middleware matches /api/:path* and the default allowlist is
# built from PORT. Re-read the notes in docker-compose.yml before bumping.
HOMEPAGE_VERSION=v1.4.5

# Loopback port. Homepage binds 127.0.0.1:\$LOCAL_PORT directly (host
# networking, HOSTNAME=127.0.0.1) — there is no Docker port mapping doing it.
LOCAL_PORT=$LOCAL_PORT
TZ=$tz

# Your YAML config. setup.sh seeds any file that is MISSING from the
# templates in $TEMPLATE_DIR and never touches one that exists, so this is
# yours to edit. Homepage re-reads it per request — no restart needed
# (measured). Back this up; it is the whole dashboard.
HOMEPAGE_CONFIG=$STATE/config

# The container starts as root and drops to this uid/gid, chowning
# /app/config on the way. Your own ids, so you can edit the YAML without
# sudo. Change these and you inherit a root-owned config directory.
HOMEPAGE_UID=$(id -u)
HOMEPAGE_GID=$(id -g)

# THE HOST ALLOWLIST — see the header comment in setup.sh. Homepage answers
# HTTP 400 to any /api/* request whose Host header is not in this list, and
# \`tailscale serve\` passes the Host through verbatim INCLUDING THE PORT.
# Both forms of the tailnet name are listed so that moving Serve to :443
# (where the Host carries no port) keeps working.
#
# If you move HTTPS_PORT, this list must move with it or the dashboard breaks
# in a way that still returns HTTP 200 on /. Re-run setup.sh after editing;
# it warns when the list no longer matches the tailnet name and port.
#
# Setting this to a single "*" disables host validation entirely. Do not:
# it is the only thing stopping a DNS-rebinding page in your browser from
# driving this dashboard's API.
HOMEPAGE_ALLOWED_HOSTS=$TS_HOST:$HTTPS_PORT,$TS_HOST,127.0.0.1:$LOCAL_PORT,localhost:$LOCAL_PORT

# Measured idle: ~112 MB. The cap is a hard stop so a leak in the dashboard
# cannot push this box into swapping the services it is watching.
HOMEPAGE_MEM_LIMIT=512m
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth, so a re-run can never
# silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
CONFIG_DIR="${HOMEPAGE_CONFIG:?HOMEPAGE_CONFIG missing from $ENV_FILE}"
ALLOWED="${HOMEPAGE_ALLOWED_HOSTS:?HOMEPAGE_ALLOWED_HOSTS missing from $ENV_FILE}"
: "${HOMEPAGE_VERSION:?HOMEPAGE_VERSION missing from $ENV_FILE}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
# .env holds no HTTPS_PORT, so a default HTTPS port keeps following the local
# port .env settled on; an explicit HTTPS_PORT is honoured as given.
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"

# Drift check, not a rewrite: .env is the user's file. But a stale allowlist
# is the single failure this service has, and it does not announce itself —
# the page still returns 200. Name it here, before it turns into "the widgets
# stopped working and I don't know why".
case ",$ALLOWED," in
  *",$TS_HOST:$HTTPS_PORT,"*|*",*,"*) ;;
  *)
    warn "HOMEPAGE_ALLOWED_HOSTS in .env does not contain '$TS_HOST:$HTTPS_PORT'."
    warn "  Over the tailnet the page will still load with HTTP 200, but every /api/* call — every status"
    warn "  dot, every widget, the whole service list — will return 400 'Host validation failed'."
    warn "  Fix: add $TS_HOST:$HTTPS_PORT to HOMEPAGE_ALLOWED_HOSTS in $ENV_FILE and re-run."
    ;;
esac

# ---------------------------------------------------------------- config
mkdir -p "$STATE" "$CONFIG_DIR"

# Seed ONLY what is missing. Homepage itself writes an upstream default for
# any file that is absent when the API first asks for it, so this has to run
# BEFORE the container starts or the placeholder "My First Service" config
# wins the race and this repo's version never lands.
#
# __TS_HOST__ in the templates becomes this node's MagicDNS name, so the
# checked-in files stay tailnet-agnostic and survive a re-tailnet.
info "Seeding config into $CONFIG_DIR (existing files are left alone)"
seeded=0; kept=0
for tpl in "$TEMPLATE_DIR"/*.yaml; do
  [ -f "$tpl" ] || continue
  name="$(basename "$tpl")"
  if [ -f "$CONFIG_DIR/$name" ]; then
    kept=$((kept + 1))
    continue
  fi
  sed "s#__TS_HOST__#$TS_HOST#g" "$tpl" > "$CONFIG_DIR/$name"
  seeded=$((seeded + 1))
done
if [ "$seeded" -gt 0 ]; then ok "Seeded $seeded config file(s)"; fi
if [ "$kept" -gt 0 ];   then ok "Kept $kept existing config file(s) untouched"; fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

# Pulled as its own step so the ~85 MB first-run download shows progress —
# `up -d` below has its stderr captured for error triage, and a silent
# two-minute pause is not what a one-shot deploy should look like. A failed
# pull is a warning, not a death: the pinned image may already be cached.
info "Fetching the image (first run pulls ~85 MB)"
"${COMPOSE[@]}" pull 2>&1 || warn "docker compose pull failed — continuing with whatever image is already cached locally."

info "Starting Homepage (docker compose up -d)"
if ! "${COMPOSE[@]}" up -d 2>"$WORK/up.err"; then
  cat "$WORK/up.err" >&2
  case "$(cat "$WORK/up.err" 2>/dev/null || true)" in
    *"address already in use"*|*"port is already allocated"*)
      die "Port conflict on $LOCAL_PORT. With host networking there is no Docker port mapping to blame — something else on this box already holds it. Check: ss -ltnp | grep :$LOCAL_PORT" ;;
    *)
      die "docker compose up failed. Logs: docker compose --project-directory $SERVICE_DIR logs homepage" ;;
  esac
fi

# ------------------------------------------------------------- HTTP helper
HP_CODE=""
hp() {  # hp URL [curl-args...] -> body in $WORK/resp, code in $HP_CODE
  local url="$1"; shift
  # curl prints 000 to stdout AND exits non-zero when it cannot connect, so a
  # `|| echo 000` fallback would CONCATENATE into "000000". Take curl's own
  # output and normalise anything unexpected.
  HP_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time "${HP_TIMEOUT:-30}" "$@" "$url" 2>/dev/null)" || true
  case "$HP_CODE" in
    [0-9][0-9][0-9]) ;;
    *) HP_CODE=000 ;;
  esac
}

hp_retry() {  # same, but rides out a connection refusal (container warm-up)
  local attempt=1
  while :; do
    hp "$@"
    [ "$HP_CODE" != "000" ] && return 0
    [ "$attempt" -ge 30 ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
}

# A non-empty JSON array of objects that each have a "name". This is doing
# real work, not decoration: a YAML syntax error in services.yaml makes
# Homepage return `[]` with HTTP 200 and log the parse failure nowhere the
# HTTP client can see it. "Is it 200" and "is it valid JSON" both go green on
# a config Homepage failed to read.
json_has_names() {  # json_has_names FILE
  head -c 1 "$1" 2>/dev/null | grep -q '\[' || return 1
  grep -q '"name"' "$1" 2>/dev/null || return 1
  return 0
}

BASE="http://127.0.0.1:$LOCAL_PORT"

info "Waiting for Homepage on 127.0.0.1:$LOCAL_PORT"
hp_retry "$BASE/api/healthcheck"
case "$HP_CODE" in
  200) ok "Homepage is answering (GET /api/healthcheck -> 200)" ;;
  000) die "Homepage never accepted a connection on $BASE (60s). Logs: docker compose --project-directory $SERVICE_DIR logs homepage" ;;
  400) die "Homepage answered 400 to a LOOPBACK health check. That is the host allowlist: HOMEPAGE_ALLOWED_HOSTS must contain '127.0.0.1:$LOCAL_PORT'. Current value: $ALLOWED" ;;
  *)   warn "Homepage answered /api/healthcheck with HTTP $HP_CODE — continuing, but read the checks below." ;;
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
FAILED=0
fail() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; FAILED=1; }

echo
info "Verifying the deploy"

# --- 1. the container is actually running ---------------------------------
run_state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
if [ "$run_state" = "running" ]; then
  ok "Container is running"
else
  fail "Container is '${run_state:-missing}', not running. Logs: docker compose --project-directory $SERVICE_DIR logs homepage"
fi

# --- 2. the page renders real Homepage markup -----------------------------
# Necessary and NOWHERE NEAR sufficient. Measured: GET / is a build-time
# static shell — 44801 bytes, byte-identical whatever the Host header and
# whatever is in services.yaml, with the upstream "My First Service"
# placeholder still baked into its __NEXT_DATA__. Every real value arrives
# later from /api/*. So this check proves only "a Homepage container answered
# here". Checks 3 and 4 are the ones that prove anything.
#
# Match the favicon link, not the <title>: `title:` in settings.yaml does NOT
# change the served <title> (it is prerendered), but a future version that
# starts server-rendering it would break a title assertion for no reason.
hp "$BASE/"
if [ "$HP_CODE" = "200" ] && grep -q 'homepage\.ico' "$WORK/resp" 2>/dev/null; then
  ok "Dashboard HTML renders on $BASE (real Homepage markup, not an error page)"
elif [ "$HP_CODE" = "200" ]; then
  fail "$BASE/ returned 200 but the body is not a Homepage page. First 200 bytes: $(head -c 200 "$WORK/resp" 2>/dev/null | tr -d '\n')"
else
  fail "$BASE/ returned HTTP $HP_CODE"
fi

# --- 3. the config actually parsed ----------------------------------------
hp "$BASE/api/services"
if [ "$HP_CODE" = "200" ] && json_has_names "$WORK/resp"; then
  # grep -o | wc -l, not grep -c: the response is a single line of JSON, so a
  # line count would always say 1. `|| true` guards the pipeline against
  # pipefail; wc has already printed by then either way.
  ok "services.yaml parsed and served ($(grep -o '"name"' "$WORK/resp" 2>/dev/null | wc -l | tr -d ' ' || true) named entries)"
elif [ "$HP_CODE" = "200" ]; then
  fail "GET /api/services returned 200 but an EMPTY list. Homepage answers exactly this — 200 and [] — when services.yaml fails to parse; the YAML error goes only to the log. Check: docker compose --project-directory $SERVICE_DIR logs homepage | grep -i -e yaml -e 'failed to load'"
else
  fail "GET /api/services on loopback returned HTTP $HP_CODE"
fi

# --- 4. THE ONE THAT MATTERS: an API call with the REAL tailnet Host ------
#
# GET / over the tailnet proves nothing: with a wrong allowlist it returns a
# byte-identical 200 HTML page (verified with cmp). Only an /api/* request
# carrying the tailnet Host header separates a working dashboard from one
# whose every fetch is 400ing.
url="https://$TS_HOST:$HTTPS_PORT"
info "Checking $url/api/services with the real Host header (first request can take ~60s while the TLS cert is minted)"
HP_TIMEOUT=90 hp "$url/api/services"
if [ "$HP_CODE" != "200" ]; then
  # Cert minting is slow, not broken — give it a few more goes.
  for i in 1 2 3 4 5; do
    sleep 3
    HP_TIMEOUT=30 hp "$url/api/services"
    [ "$HP_CODE" = "200" ] && break
  done
fi
case "$HP_CODE" in
  200)
    if json_has_names "$WORK/resp"; then
      ok "Tailnet HTTPS is fully working: $url serves the real service list"
    else
      fail "$url/api/services returned 200 but an empty list — see check 3."
    fi
    ;;
  400)
    fail "HOST VALIDATION FAILED over the tailnet. Homepage rejected Host '$TS_HOST:$HTTPS_PORT'. The page at $url will still load with HTTP 200 and look almost right, but every status dot and widget on it is broken. Fix: make sure HOMEPAGE_ALLOWED_HOSTS in $ENV_FILE contains exactly '$TS_HOST:$HTTPS_PORT' (current: $ALLOWED), then re-run. Body: $(head -c 200 "$WORK/resp" 2>/dev/null | tr -d '\n')"
    ;;
  *)
    warn "No usable answer on $url yet (HTTP ${HP_CODE:-000}) — the cert may still be minting. Retry in a minute: curl -sS -o /dev/null -w '%{http_code}\\n' $url/api/services"
    ;;
esac

# --- 5. no host-validation errors anywhere in the log ---------------------
# Catches the case where the page itself is fine but some other Host reaches
# it — e.g. a Kuma monitor or the launcher probing a port that is not on the
# allowlist. Those tiles would be silently blank.
# Scoped to the last 10 minutes so that stale lines from a previously
# misconfigured run do not warn forever, while still catching the periodic
# Kuma / launcher probes (60s interval) on an idempotent re-run.
hv="$(docker logs --since 10m "$CONTAINER" 2>&1 | grep -c 'Host validation failed' || true)"
if [ "${hv:-0}" -eq 0 ]; then
  ok "No 'Host validation failed' errors in the container log"
else
  warn "$hv 'Host validation failed' line(s) in the container log. Something is reaching Homepage with a Host that is not on the allowlist. See which: docker logs $CONTAINER 2>&1 | grep 'Host validation failed' | tail -5"
fi

# --- 6. nothing is listening where it should not be -----------------------
# With host networking there is no Docker port publish spec to constrain this
# — HOSTNAME=127.0.0.1 in docker-compose.yml is the only thing keeping the
# dashboard off the LAN, so check it rather than trusting it.
#
# Note the tailnet IP legitimately appears on this port: that listener is
# tailscaled's own Serve proxy, not Homepage.
TS_IP="$("$TAILSCALE" ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
TS_IP6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 | tr -d '[:space:]' || true)"

listen_addrs() {  # listen_addrs PORT -> "host:port" per line
  local port="$1"
  # `|| true`: no listeners at all is a legitimate answer, and lsof exits 1
  # when nothing matches; without it pipefail would end the run here.
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}' || true
  else
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' || true
  fi
}

bad=""
# A read loop, not `for addr in $addrs`: that relies on word-splitting, which
# zsh does not do for unquoted expansions.
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  host="${addr%:*}"                             # strip the :port
  host="$(printf '%s' "$host" | tr -d '[]')"    # unwrap [v6] — tr, not a glob:
                                                # '[' is an invalid zsh pattern
  host="${host%\%*}"                            # drop %lo etc
  case "$host" in
    127.*|::1|localhost) continue ;;
  esac
  [ -n "$TS_IP" ]  && [ "$host" = "$TS_IP" ]  && continue
  [ -n "$TS_IP6" ] && [ "$host" = "$TS_IP6" ] && continue
  bad="$bad $host"
done <<EOF
$(listen_addrs "$LOCAL_PORT")
EOF
if [ -n "$bad" ]; then
  fail "Port $LOCAL_PORT is listening on non-tailnet address(es):$bad — that is outside the tailnet boundary. With host networking the only thing constraining this is HOSTNAME=127.0.0.1 in $SERVICE_DIR/docker-compose.yml; check it has not been changed."
else
  ok "Port $LOCAL_PORT listens only on loopback and the tailnet address (Serve's own proxy)"
fi

# --- 7. the Docker socket is NOT mounted ----------------------------------
# Off by default on purpose. Assert it, so that turning it on is always a
# visible, deliberate act rather than something a copied compose file did.
if docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$CONTAINER" 2>/dev/null | grep -q 'docker\.sock'; then
  warn "/var/run/docker.sock IS mounted into $CONTAINER. That gives this unauthenticated web app root-equivalent control of the box. If you did not mean to enable it, comment the mount out in $SERVICE_DIR/docker-compose.yml and re-run."
else
  ok "Docker socket is not mounted (status comes from loopback health probes instead)"
fi

# ============================================================== SUMMARY
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mDone.\033[0m Homepage is at \033[1m%s\033[0m (tailnet only).\n' "$url"
else
  printf '\033[1;31mDeploy finished with failures.\033[0m Read the ✗ lines above.\n'
fi
echo
echo "  Config:  $CONFIG_DIR/*.yaml — edit and reload the page, no restart needed"
echo "           services.yaml   the tiles and their loopback health probes"
echo "           settings.yaml   title, layout, theme"
echo "           widgets.yaml    the header strip"
echo "           bookmarks.yaml  plain links"
echo "  Log:     $CONFIG_DIR/logs/homepage.log (YAML parse errors land here and NOWHERE else)"
echo "  Auth:    none. Homepage has no login of its own — the tailnet is the"
echo "           entire access-control layer, same as code-server."
echo
echo "  Note this box already has a dashboard: the launcher at"
echo "  https://$TS_HOST/home/. Homepage is read-mostly — links, status dots"
echo "  and widgets. The launcher is the one that can start, stop and deploy"
echo "  services. They are not wired together; both read the same box."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: bump HOMEPAGE_VERSION in $ENV_FILE, then"
echo "         docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"
echo "         (re-read the allowlist notes in docker-compose.yml first — the"
echo "          host-validation middleware is where upstream changes bite.)"

[ "$FAILED" = "0" ] || exit 1
exit 0
