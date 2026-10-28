#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of AdGuard Home (tailnet-wide DNS ad/tracker
# blocking) behind Tailscale. Linux + macOS.
#
# End state:
#   - a single `adguard` container, image pinned to v0.107.79
#   - web UI on 127.0.0.1:LOCAL_PORT, published tailnet-only at
#     https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - a working DNS resolver on <this node's tailnet IP>:53, tcp + udp
#   - configured through the install API, so no first-run wizard is ever
#     left sitting there and the admin password is generated, not chosen
#   - the host's own DNS (systemd-resolved) completely untouched
#
# Usage:
#   ./setup.sh                                  # local 3080, HTTPS 3080
#   LOCAL_PORT=3080 HTTPS_PORT=3080 ./setup.sh
#   LOCAL_PORT=3084 ./setup.sh                  # HTTPS follows LOCAL_PORT
#   ADGUARD_ADMIN_USERNAME=admin ./setup.sh       # first run only; .env wins after
#
# ---------------------------------------------------------------------------
# THE ONE STEP THIS SCRIPT WILL NOT DO FOR YOU
#
# AdGuard filters nothing until the tailnet is told to use it, in the
# Tailscale admin console: DNS -> Nameservers -> add this node's tailnet IP.
# That setting is GLOBAL — it changes DNS for your phone and your laptop,
# everywhere, immediately. Get it wrong and those devices lose name
# resolution from anywhere, including the connection you would need to undo
# it. So this script prints the instruction and stops. Do it yourself, once,
# with your eyes open, after the verification below has passed.
# ---------------------------------------------------------------------------
#
# THE PORT 53 QUESTION. The usual Ubuntu advice is "systemd-resolved owns
# :53, disable DNSStubListener first". Measured on this box: it does not.
# resolved binds only 127.0.0.53%lo and 127.0.0.54, never 0.0.0.0, so
# AdGuard takes <tailnet-ip>:53 with resolved left running and the host's own
# name resolution intact. This script therefore does NOT touch
# systemd-resolved, /etc/resolv.conf or /etc/systemd/resolved.conf, and you
# should not either — every other service on this box resolves names through
# resolved.
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged
# in, and a DNS query tool (dig, or python3 as a fallback) so the deploy can
# verify its own resolver.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# An existing .env is never overwritten, and AdGuard is configured at most
# once — a re-run against a configured instance leaves the admin account,
# the upstreams and the filter lists exactly as they are.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-3080}"
# HTTPS follows the local port unless set explicitly (the n8n/kaichenpedia
# convention), so overriding only LOCAL_PORT cannot split the two. Whether it
# was explicit is remembered for the .env read-back below.
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
ADMIN_USERNAME="${ADGUARD_ADMIN_USERNAME:-admin}"
CONTAINER="adguard"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/adguard"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

# 700. Briefly holds the JSON body containing the plaintext admin password
# on its way to the install API. Removed on every exit path.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars: [A-Za-z0-9]-safe, so it survives .env, shell quoting, JSON
# and HTTP basic auth without a single escape. python3 when present,
# /dev/urandom otherwise.
randhex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    echo
  fi
}

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
command -v curl >/dev/null || die "curl is required."
resolve_tailscale
require_docker_compose
require_tailscale_up
require_numeric LOCAL_PORT HTTPS_PORT

# A DNS query tool is a hard requirement, not a nicety. The single check that
# distinguishes a working resolver from a container that is merely running is
# "resolve a real name through it" — a fresh AdGuard has the :53 port mapped
# and published while running no DNS server at all, so every socket-level
# check passes against something that refuses every query. Without a way to
# ask a question, this script cannot tell you whether it worked.
if command -v dig >/dev/null 2>&1; then
  DNS_TOOL="dig"
elif command -v python3 >/dev/null 2>&1; then
  # Fallback for macOS 15+, which no longer ships dig/host/nslookup.
  DNS_TOOL="python3"
else
  [ "$OS" = "Linux" ] && die "No DNS query tool found, so this deploy could not verify its own resolver — and a resolver that is 'up' but refusing queries looks identical to a working one from the outside. Fix: sudo apt-get install -y dnsutils"
  die "No DNS query tool found (no dig, no python3), so this deploy could not verify its own resolver. Fix: install the Xcode command line tools (xcode-select --install) for python3, or: brew install bind"
fi

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running) + DNS query via $DNS_TOOL"

# Two different Tailscale facts, both needed before the container starts:
#
#   TS_HOST — the MagicDNS name, for `tailscale serve` and the final URL.
#   TS_IP   — this node's tailnet IPv4. The DNS ports bind to it directly
#             (see docker-compose.yml), and it is the value you will type
#             into the Tailscale admin console at the end.
#
# The trailing `|| true` on both is load-bearing, not noise. Under
# `set -euo pipefail` a command substitution whose pipeline fails makes the
# ASSIGNMENT fail, and errexit then kills the script on that line — BEFORE
# the emptiness check written to explain it. `grep -o` exits 1 on no match
# (MagicDNS off) and `tailscale ip -4` exits non-zero when tailscaled is
# down or has no v4 lease, so both are reachable in practice, and without
# the guard the whole run ends after the preflight tick with exit 1 and not
# one word of diagnosis. Swallow the status; the checks below are the ones
# that decide.
TS_HOST="$(tailnet_host)"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

TS_IP="$("$TAILSCALE" ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
case "$TS_IP" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "Could not determine this node's tailnet IPv4 from '$TAILSCALE ip -4' (got: '${TS_IP:-nothing}'). AdGuard's DNS listener binds to that address, so there is nothing sensible to bind without it." ;;
esac
ok "Tailnet name: $TS_HOST   tailnet IP: $TS_IP"

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

# Pinned exactly. Measured against this version: config schema_version 34.
# A newer binary rewrites AdGuardHome.yaml to its own schema on first start
# and that is NOT reversible — back up \$ADGUARD_CONF before bumping this.
ADGUARD_VERSION=v0.107.79

# Web UI, loopback side. 3000 is AdGuard's default and is taken by forgejo on
# this box, hence 3080.
LOCAL_PORT=$LOCAL_PORT
TZ=$tz

# The DNS listener address: this node's tailnet IPv4, resolved from
# \`tailscale ip -4\` at deploy time. This is the one port in this repo that
# is not on 127.0.0.1 — a resolver has to be reachable at a real address for
# Tailscale's Nameservers setting to point at it, and Serve does not proxy
# UDP. tailscale0 is not the LAN, so the tailnet boundary still holds.
#
# If this node's tailnet IP ever changes, the container will fail to start
# with "cannot assign requested address". Fix it here and re-run setup.sh.
ADGUARD_DNS_IP=$TS_IP

# AdGuard's own state, split by what it costs you to lose:
#   CONF — AdGuardHome.yaml. The whole configuration: admin password hash,
#          upstream servers, filter subscriptions, per-client rules. BACK
#          THIS UP.
#   WORK — downloaded filter lists, query log, statistics. Re-downloadable;
#          losing it costs history, not settings.
# Written by a container running as root, so the contents are root-owned on
# the host and removing them needs sudo.
ADGUARD_CONF=$STATE/conf
ADGUARD_WORK=$STATE/work

# Web UI login. AdGuard has a real login of its own (bcrypt, 5 failed
# attempts then a 15-minute block), on top of the tailnet boundary. Created
# once by setup.sh through the install API, which takes the plaintext
# password and hashes it itself.
#
# If you change this password in the web UI, mirror it back here — setup.sh
# uses it to verify the login on every run, and a mismatch will lock the
# account out for 15 minutes.
ADGUARD_ADMIN_USER=$ADMIN_USERNAME
ADGUARD_ADMIN_PASSWORD=$admin_pw

# Queries per second per client subnet, applied ONCE at first configure.
# AdGuard ships 20. That is aimed at a resolver on the open internet; on a
# private tailnet of your own devices it mostly serves to silently drop
# queries when a browser opens thirty tabs at once, which surfaces as "the
# page didn't load" and blames the wrong thing. 0 = no limit.
#
# Deliberate deviation from the shipped default, not a silent one. Set this
# to 20 before the first run to keep AdGuard's behaviour. Changing it later
# has no effect here — change it in the web UI (Settings -> DNS settings),
# because setup.sh will not overwrite a running configuration.
ADGUARD_RATELIMIT=0
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
ADMIN_USERNAME="${ADGUARD_ADMIN_USER:?ADGUARD_ADMIN_USER missing from $ENV_FILE}"
ADMIN_PASSWORD="${ADGUARD_ADMIN_PASSWORD:?ADGUARD_ADMIN_PASSWORD missing from $ENV_FILE}"
CONF_DIR="${ADGUARD_CONF:?ADGUARD_CONF missing from $ENV_FILE}"
WORK_DIR="${ADGUARD_WORK:?ADGUARD_WORK missing from $ENV_FILE}"
DNS_IP="${ADGUARD_DNS_IP:?ADGUARD_DNS_IP missing from $ENV_FILE}"
RATELIMIT="${ADGUARD_RATELIMIT:-0}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
# .env holds no HTTPS_PORT, so a default HTTPS port keeps following the local
# port .env settled on; an explicit HTTPS_PORT is honoured as given.
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"
case "$RATELIMIT" in ''|*[!0-9]*) die "ADGUARD_RATELIMIT must be a non-negative integer (got: $RATELIMIT)";; esac

# Drift check, not a rewrite: .env is the user's file. But a stale DNS_IP is
# not a cosmetic problem — the container simply will not start, because you
# cannot bind an address this machine no longer holds. Say so before compose
# does, in words that name the actual cause.
if [ "$DNS_IP" != "$TS_IP" ]; then
  warn "ADGUARD_DNS_IP in .env is $DNS_IP but this node's tailnet IP is now $TS_IP."
  warn "  The DNS ports bind to that address, so the container will fail to start with 'cannot assign requested address'."
  warn "  Fix: set ADGUARD_DNS_IP=$TS_IP in $ENV_FILE and re-run. Then update the nameserver entry in the Tailscale admin console to match."
fi

mkdir -p "$STATE" "$CONF_DIR" "$WORK_DIR"
# 0700, and this is not decoration: AdGuard permchecks both directories on
# every start and logs `permcheck: warning: found unexpected permissions
# ... perm=0775 want=0700` otherwise. Verified: at 0700 the warning is gone.
# chmod every run — a re-run should repair a directory someone loosened.
chmod 700 "$CONF_DIR" "$WORK_DIR" 2>/dev/null || true

# Filter lists are a few MB; the query log is the one that grows (90 days of
# every domain every device on the tailnet looked up).
# `|| true` for the same reason as TS_IP above: pipefail would otherwise turn
# a df that cannot stat the path into a silent exit 1, and the ${avail_kb:-0}
# fallback below — which exists precisely to tolerate an unknown answer —
# would never be reached.
avail_kb="$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}' || true)"
if [ "${avail_kb:-0}" -lt 1048576 ]; then
  warn "$(( avail_kb / 1024 )) MB free at $WORK_DIR — the query log keeps 90 days by default. Free some space, or shorten the retention in Settings -> General."
else
  ok "$(( avail_kb / 1048576 )) GB free at $WORK_DIR"
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

# Pulled as its own step so the ~30 MB first-run download shows progress —
# `up -d` below has its stderr captured for the error triage, and a silent
# two-minute pause is not what a one-shot deploy should look like. A failed
# pull is a warning, not a death: the pinned image may already be cached, and
# a re-run with no network should still repair the deploy.
info "Fetching the image (first run pulls ~30 MB)"
"${COMPOSE[@]}" pull 2>&1 || warn "docker compose pull failed — continuing with whatever image is already cached locally."

info "Starting AdGuard Home (docker compose up -d)"
if ! "${COMPOSE[@]}" up -d 2>"$WORK/up.err"; then
  cat "$WORK/up.err" >&2
  case "$(cat "$WORK/up.err" 2>/dev/null || true)" in
    *"cannot assign requested address"*|*"address not available"*)
      die "Could not bind $DNS_IP:53 — this machine does not hold that address right now. Either ADGUARD_DNS_IP in $ENV_FILE is stale (this node's tailnet IP is $TS_IP), or tailscaled is not up yet. Fix the value and re-run." ;;
    *"address already in use"*|*"port is already allocated"*)
      die "Port conflict. Something already holds $DNS_IP:53 or 127.0.0.1:$LOCAL_PORT. Check: ss -ltnup | grep -E ':53 |:$LOCAL_PORT ' — note that systemd-resolved's own 127.0.0.53/127.0.0.54 listeners are expected and do NOT conflict with $DNS_IP:53." ;;
    *)
      die "docker compose up failed. Logs: docker compose --project-directory $SERVICE_DIR logs adguard" ;;
  esac
fi

# ------------------------------------------------------------- API helpers
AG_CODE=""
AG_BASE="http://127.0.0.1:$LOCAL_PORT"

ag() {  # ag METHOD PATH [body-file] [curl-args...] -> body in $WORK/resp, code in $AG_CODE
  local method="$1" path="$2" bodyfile="${3:-}"
  shift 3 2>/dev/null || shift 2
  set -- -sS -X "$method" -H 'Content-Type: application/json' \
         -o "$WORK/resp" -w '%{http_code}' --max-time "${AG_TIMEOUT:-30}" "$@"
  [ -n "$bodyfile" ] && set -- "$@" --data-binary "@$bodyfile"
  # curl already prints 000 to stdout when it cannot connect, AND exits
  # non-zero. A `|| echo 000` fallback therefore CONCATENATES, turning a
  # plain connection failure into the nonsense code "000000" in the error
  # message. Take curl's own output and normalise anything unexpected.
  AG_CODE="$(curl "$@" "$AG_BASE$path" 2>/dev/null)" || true
  case "$AG_CODE" in
    [0-9][0-9][0-9]) ;;
    *) AG_CODE=000 ;;
  esac
}

# Same as ag(), but rides out a connection refusal.
#
# Measured: the container accepts connections ~0.5s after `docker run`, and
# during that window curl gets 000. Jellyfin's deploy in this repo died on
# exactly this shape of race — the readiness probe passed, the very next
# request came back 000, and the wizard ended up half-applied with no admin
# account. Retrying a 000 costs nothing when the server is genuinely down
# (the caller still fails, just later) and removes the race when it is merely
# a second behind.
#
# NOTE it retries 000 only. It must never retry a 4xx: AdGuard blocks an
# account for 15 minutes after 5 failed logins, so a wrong password that gets
# hammered turns a bad guess into a lockout.
ag_retry() {  # ag_retry METHOD PATH [body-file] [curl-args...]
  local attempt=1
  while :; do
    ag "$@"
    [ "$AG_CODE" != "000" ] && return 0
    [ "$attempt" -ge 30 ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
}

# ------------------------------------------------------------- readiness
# GET /control/status is the one endpoint that answers in every state, and
# its status code IS the state. Measured against v0.107.79:
#
#   000 — not accepting connections yet
#   302 — up, NOT configured (redirects to /control/install.html)
#   401 — up, configured (it wants the admin login)
#   200 — up, configured, and these credentials work
#
# That makes it both the readiness probe and the idempotency check, with no
# marker file to go stale. A marker would be worse here: if someone deleted
# $CONF_DIR, a marker saying "configured" would make this script skip the
# install and hand back a box sitting on the wizard, which fails much later
# and blames the password.
info "Waiting for the AdGuard web API on 127.0.0.1:$LOCAL_PORT"
ag_retry GET /control/status
case "$AG_CODE" in
  000) die "AdGuard never accepted a connection on $AG_BASE (60s). Logs: docker compose --project-directory $SERVICE_DIR logs adguard" ;;
  302) ok "AdGuard is up and reports itself UNCONFIGURED (first run)" ;;
  401|200) ok "AdGuard is up and already configured" ;;
  *) warn "AdGuard answered /control/status with an unexpected HTTP $AG_CODE — continuing, but read the logs if the checks below fail." ;;
esac

# ------------------------------------------------------- configure (once)
JUST_INSTALLED=0
if [ "$AG_CODE" = "302" ]; then
  info "Running the install API (admin account: $ADMIN_USERNAME)"

  # The `web` block MUST name the address AdGuard is ALREADY serving on:
  # 0.0.0.0:3000, container-internal. AdGuard validates the block by trying
  # to bind it, and any other value fails against AdGuard itself —
  # {"web":{"ip":"127.0.0.1","port":3000}} returns, verified:
  #   400 checking address 127.0.0.1:3000: listen tcp: address already in use
  # The 0.0.0.0 here is inside the container and is not a host exposure; the
  # publish spec in docker-compose.yml is what constrains reachability, the
  # same way immich does it.
  #
  # Password goes over loopback in plaintext because that is what this API
  # takes — and that is the point: AdGuard bcrypts it itself, so nothing on
  # this host needs a bcrypt tool (there isn't one: no htpasswd, and python3
  # has no bcrypt module).
  printf '{"web":{"ip":"0.0.0.0","port":3000},"dns":{"ip":"0.0.0.0","port":53},"username":"%s","password":"%s"}' \
    "$ADMIN_USERNAME" "$ADMIN_PASSWORD" > "$WORK/install.json"
  chmod 600 "$WORK/install.json"

  ag_retry POST /control/install/configure "$WORK/install.json"
  body="$(head -c 400 "$WORK/resp" 2>/dev/null || true)"
  case "$AG_CODE" in
    200)
      JUST_INSTALLED=1
      ok "Install API accepted — admin account created and the DNS server started"
      ;;
    403)
      # What a *second* configure returns. Reached if two runs overlap, or if
      # the container was configured between the status check and this call.
      # That is the desired end state, so it is success, not an error.
      ok "AdGuard was already configured — leaving the existing admin account and settings alone"
      ;;
    400)
      die "The install API rejected the request (HTTP 400): $body — if that mentions 'address already in use', the web block in this script no longer matches the address AdGuard serves on inside the container (expected 0.0.0.0:3000). Nothing was changed; AdGuard is still sitting on the install wizard at $AG_BASE."
      ;;
    *)
      die "The install API returned HTTP $AG_CODE: $body. AdGuard is still unconfigured — it is serving the wizard and running NO DNS server. Logs: docker compose --project-directory $SERVICE_DIR logs adguard"
      ;;
  esac
else
  ok "AdGuard is already configured — leaving the existing admin account and settings alone"
fi

# Rate limit: first configure only. Applying it on every run would stomp a
# value the user changed in the web UI, which the repo's idempotency rule
# forbids. Non-fatal: a resolver that rate-limits is still a resolver.
# Verified against v0.107.79 that a partial body leaves upstreams, DNSSEC and
# cache settings untouched.
if [ "$JUST_INSTALLED" = "1" ] && [ "$RATELIMIT" != "20" ]; then
  info "Setting the per-client rate limit to $RATELIMIT qps (AdGuard ships 20; see ADGUARD_RATELIMIT in .env)"
  printf '{"ratelimit":%s}' "$RATELIMIT" > "$WORK/ratelimit.json"
  ag_retry POST /control/dns_config "$WORK/ratelimit.json" -u "$ADMIN_USERNAME:$ADMIN_PASSWORD"
  if [ "$AG_CODE" = "200" ]; then
    ok "Rate limit set to $RATELIMIT"
  else
    warn "Could not set the rate limit (HTTP $AG_CODE) — AdGuard keeps its default of 20 qps per client subnet. Harmless; change it in Settings -> DNS settings if queries get dropped under load."
  fi
fi

# ------------------------------------------------------- tailscale serve
info "Publishing the web UI via Tailscale Serve (HTTPS :$HTTPS_PORT, tailnet only)"
ts_serve_publish "$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT"

# ============================================================== VERIFY
# The part that matters. Everything above can succeed against a container
# that resolves nothing.
FAILED=0
fail() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; FAILED=1; }

echo
info "Verifying the deploy"

# --- 1. the container is actually running ---------------------------------
run_state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
if [ "$run_state" = "running" ]; then
  restarts="$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo 0)"
  if [ "${restarts:-0}" -gt 0 ]; then
    ok "Container is running (restarted ${restarts}x — normal right after a reboot, when dockerd beats tailscaled to the tailnet address)"
  else
    ok "Container is running"
  fi
else
  fail "Container is '${run_state:-missing}', not running. Logs: docker compose --project-directory $SERVICE_DIR logs adguard"
fi

# --- 2. web UI answers on loopback ----------------------------------------
ag GET /control/status
case "$AG_CODE" in
  401|200) ok "Web UI answering on 127.0.0.1:$LOCAL_PORT (HTTP $AG_CODE — configured, asking for a login)" ;;
  302)     fail "Web UI is answering but reports itself UNCONFIGURED — it is serving the install wizard and running no DNS server. Re-run ./setup.sh." ;;
  *)       fail "Web UI on 127.0.0.1:$LOCAL_PORT returned HTTP $AG_CODE" ;;
esac

# --- 3. the generated password actually logs in ---------------------------
# One attempt, retried only on a connection failure. Never loop on a 401:
# AdGuard blocks the account for 15 minutes after 5 failed logins, so a
# retry loop would turn "the password drifted" into "you are locked out".
ag_retry GET /control/status "" -u "$ADMIN_USERNAME:$ADMIN_PASSWORD"
case "$AG_CODE" in
  200)
    case "$(tr -d ' \n\r' < "$WORK/resp" 2>/dev/null || true)" in
      *'"running":true'*) ok "Signed in as $ADMIN_USERNAME; AdGuard reports its DNS server as running" ;;
      *)                  fail "Signed in as $ADMIN_USERNAME, but AdGuard does not report \"running\":true. Logs: docker compose --project-directory $SERVICE_DIR logs adguard" ;;
    esac
    ;;
  401|403)
    fail "Login as $ADMIN_USERNAME was rejected (HTTP $AG_CODE). The password in $ENV_FILE does not match the server — changed in the web UI? Mirror it back into .env. NOTE: 5 failed attempts block the account for 15 minutes, so do not retry in a loop."
    ;;
  *)
    fail "Could not verify the admin login (HTTP $AG_CODE)."
    ;;
esac

# --- 4. the tailnet HTTPS front door --------------------------------------
url="https://$TS_HOST:$HTTPS_PORT"
info "Checking $url (first request can take ~60s while the TLS cert is minted)"
https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 90 "$url/control/status" 2>/dev/null)" || true
case "$https_code" in
  401|200) ok "Tailnet HTTPS answering: $url (HTTP $https_code)" ;;
  *)
    # Cert minting is slow, not broken — give it a couple more goes.
    for i in 1 2 3 4 5; do
      sleep 3
      https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$url/control/status" 2>/dev/null)" || true
      case "$https_code" in 401|200) break ;; esac
    done
    case "$https_code" in
      401|200) ok "Tailnet HTTPS answering: $url (HTTP $https_code)" ;;
      *) warn "No answer on $url yet (HTTP ${https_code:-000}) — the cert may still be minting. Retry in a minute: curl -o /dev/null -w '%{http_code}\\n' $url/control/status" ;;
    esac
    ;;
esac

# --- 5. THE ONE THAT MATTERS: resolve a real name through it --------------
#
# A fresh AdGuard runs NO DNS server, but Docker's port mapping still makes
# `ss` show $DNS_IP:53 as LISTEN. Measured in that state:
#   dig @<ip> example.com  ->  communications error ... connection refused
# So a check that observes the socket goes green against a resolver that
# answers nothing. Ask it a question instead, and require a real A record.
resolve_a() {  # resolve_a SERVER NAME -> prints IPv4 answers, one per line
  case "$DNS_TOOL" in
    dig)
      # +short can emit CNAME lines too; keep only bare IPv4 literals.
      dig +short +time=3 +tries=1 "@$1" "$2" A 2>/dev/null \
        | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p'
      ;;
    python3)
      # Minimal DNS/UDP client for hosts with no dig (macOS 15+ dropped it).
      python3 - "$1" "$2" <<'PY' 2>/dev/null
import random, socket, struct, sys
server, name = sys.argv[1], sys.argv[2]
pkt = struct.pack('>HHHHHH', random.randint(0, 0xFFFF), 0x0100, 1, 0, 0, 0)
for label in name.split('.'):
    pkt += bytes([len(label)]) + label.encode()
pkt += b'\x00' + struct.pack('>HH', 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
try:
    sock.sendto(pkt, (server, 53))
    data, _ = sock.recvfrom(4096)
except Exception:
    sys.exit(1)
i = 12                                    # skip the header
while data[i]:                            # skip the question's name
    i += data[i] + 1
i += 5                                    # the 0 byte + qtype + qclass
for _ in range(struct.unpack('>H', data[6:8])[0]):
    if data[i] & 0xC0 == 0xC0:            # compressed name pointer
        i += 2
    else:
        while data[i]:
            i += data[i] + 1
        i += 1
    rtype, _rclass, _ttl, rdlen = struct.unpack('>HHIH', data[i:i + 10])
    i += 10
    if rtype == 1 and rdlen == 4:
        print('.'.join(str(b) for b in data[i:i + 4]))
    i += rdlen
PY
      ;;
  esac
}

# Retried, because the DNS server starts a beat after the install API
# returns 200 (measured: dnsproxy binds ~150ms later), and the first upstream
# query has to complete a DoH handshake with Quad9.
info "Resolving a real name through $DNS_IP:53 (the check that a socket cannot fake)"
answers=""
for i in $(seq 1 20); do
  answers="$(resolve_a "$DNS_IP" example.com || true)"
  # 0.0.0.0 is what AdGuard returns for a BLOCKED name — never a real answer.
  answers="$(printf '%s\n' "$answers" | grep -v '^0\.0\.0\.0$' || true)"
  [ -n "$answers" ] && break
  sleep 2
done
if [ -n "$answers" ]; then
  ok "DNS is really resolving through $DNS_IP:53 — example.com -> $(printf '%s' "$answers" | tr '\n' ' ')"
else
  fail "$DNS_IP:53 did not return an A record for example.com after 40s. The port is published either way, so 'it is listening' means nothing here — the resolver is not working. Check: docker compose --project-directory $SERVICE_DIR logs adguard | tail -40, then: dig @$DNS_IP example.com"
fi

# Blocking, checked separately and softly: the filter lists download a few
# seconds after the first configure (~178k rules), so on a fresh deploy this
# can legitimately lag the working-resolver check above.
blocked=""; is_blocked=0
for i in $(seq 1 8); do
  blocked="$(resolve_a "$DNS_IP" doubleclick.net || true)"
  if printf '%s\n' "$blocked" | grep -q '^0\.0\.0\.0$'; then is_blocked=1; break; fi
  sleep 3
done
if [ "$is_blocked" = "1" ]; then
  ok "Ad blocking is live (doubleclick.net -> 0.0.0.0)"
else
  warn "doubleclick.net did not come back blocked yet (got: $(printf '%s' "${blocked:-no answer}" | tr '\n' ' ')). The filter lists download in the background on a first deploy (~178k rules); check Filters -> DNS blocklists in the web UI in a minute. The resolver itself is fine."
fi

# --- 6. nothing is listening where it should not be -----------------------
# Loopback and this node's own Tailscale addresses are the only acceptable
# answers. Note :53 legitimately shows systemd-resolved's 127.0.0.53 and
# 127.0.0.54 stubs — loopback, so they pass, and they are why this box still
# resolves names for every other service on it.
TS_IP6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 | tr -d '[:space:]' || true)"

listen_addrs() {  # listen_addrs PORT -> "host" per line, tcp and udp
  local port="$1"
  # `|| true` on both branches: no listeners at all is a legitimate answer
  # (the caller treats an empty list as "nothing bad"), and lsof in
  # particular exits 1 when nothing matches. Without it, pipefail would end
  # the run here instead of printing the audit line.
  if command -v ss >/dev/null 2>&1; then
    { ss -ltnH "sport = :$port" 2>/dev/null; ss -lunH "sport = :$port" 2>/dev/null; } | awk '{print $4}' || true
  else
    { lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' || true
      lsof -nP -iUDP:"$port" 2>/dev/null | awk 'NR>1{print $9}' || true; }
  fi
}

audit_port() {  # audit_port PORT LABEL
  local port="$1" label="$2" addr host bad=""
  # A read loop, not `for addr in $addrs`: that relies on word-splitting,
  # which zsh does not do for unquoted expansions.
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"                             # strip the :port
    host="$(printf '%s' "$host" | tr -d '[]')"    # unwrap [v6] — tr, not a
                                                  # glob: '[' is an invalid
                                                  # pattern under zsh
    host="${host%\%*}"                            # drop %lo etc (127.0.0.53%lo)
    case "$host" in
      127.*|::1|localhost) continue ;;
      "$TS_IP") continue ;;
    esac
    if [ -n "$TS_IP6" ] && [ "$host" = "$TS_IP6" ]; then continue; fi
    bad="$bad $host"
  done <<EOF
$(listen_addrs "$port")
EOF
  if [ -n "$bad" ]; then
    fail "$label (:$port) is listening on non-tailnet address(es):$bad — that is outside the tailnet boundary. Check the ports block in $SERVICE_DIR/docker-compose.yml."
  else
    ok "$label (:$port) listens only on loopback and the tailnet address"
  fi
}
audit_port 53 "DNS"
audit_port "$LOCAL_PORT" "Web UI"

# ============================================================== SUMMARY
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mDone.\033[0m AdGuard Home is at \033[1m%s\033[0m (tailnet only).\n' "$url"
else
  printf '\033[1;31mDeploy finished with failures.\033[0m Read the ✗ lines above before using this as your resolver.\n'
fi
echo
echo "  Login:    $ADMIN_USERNAME"
echo "  Password: see ADGUARD_ADMIN_PASSWORD in $ENV_FILE"
echo "  Resolver: $DNS_IP:53 (tcp + udp) — reachable from the tailnet only"
echo "  Upstream: Quad9 over DoH (https://dns10.quad9.net/dns-query), DNSSEC on"
echo

printf '\033[1;33m┌──────────────────────────────────────────────────────────────────────┐\033[0m\n'
printf '\033[1;33m│  ONE MANUAL STEP LEFT — until you do it, AdGuard filters NOTHING     │\033[0m\n'
printf '\033[1;33m└──────────────────────────────────────────────────────────────────────┘\033[0m\n'
echo
echo "  Nothing on your tailnet is using this resolver yet. Point it here:"
echo
echo "    1. open  https://login.tailscale.com/admin/dns"
echo "    2. Nameservers -> Add nameserver -> Custom"
echo "    3. enter   $DNS_IP"
echo "    4. leave 'Override local DNS' OFF to start with — that makes this"
echo "       the default resolver for tailnet devices without forcing it on"
echo "       networks that hand out their own."
echo
echo "  This script does NOT do it for you, on purpose. That setting is"
echo "  global: it changes DNS for your phone and laptop everywhere, the"
echo "  moment you save it. If this box is off, or its resolver is broken,"
echo "  those devices lose name resolution from anywhere — including the"
echo "  connection you would need to undo it. Do it once, deliberately, now"
echo "  that the checks above have passed, and test one device before you"
echo "  walk away."
echo
echo "  MagicDNS keeps working alongside it: Tailscale answers *.ts.net"
echo "  itself and forwards everything else to this nameserver, so the"
echo "  https://$TS_HOST:... URLs for your other services are unaffected."
echo "  (Documented Tailscale behaviour — NOT verified here, because"
echo "  verifying it would mean changing your live tailnet DNS. Check one"
echo "  device after step 4.)"
echo
echo "  To undo: same page, remove the nameserver. Takes effect immediately."
echo
echo "Privacy, since it is your own household: the query log records every"
echo "  domain every tailnet device looks up, kept 90 days by default. That"
echo "  is the price of seeing what is being blocked. Shorten or disable it"
echo "  in Settings -> General settings if you would rather not have it."
echo
echo "Backups: $CONF_DIR/AdGuardHome.yaml is the whole configuration"
echo "  (admin hash, upstreams, filter subscriptions, per-client rules)."
echo "  $WORK_DIR is filter lists + logs and is re-downloadable."
echo "  The container runs as root, so these need sudo to read:"
echo "    sudo tar czf adguard-\$(date +%F).tgz -C $CONF_DIR ."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: back up $CONF_DIR first (the config schema migration is"
echo "         one-way), bump ADGUARD_VERSION in $ENV_FILE, then"
echo "         docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"

[ "$FAILED" = "0" ] || exit 1
exit 0
