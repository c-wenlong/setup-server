#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Home Assistant (self-hosted home automation
# hub) behind Tailscale. Linux + macOS.
#
# End state:
#   - a single `home-assistant` container on the host network
#   - listening on 127.0.0.1:LOCAL_PORT and nothing else
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - the onboarding admin account created over the API from a generated
#     password — no "create your account" screen on first visit
#   - LAN discovery (zeroconf / SSDP / DHCP / USB) working
#   - Bluetooth deliberately NOT loaded (see configuration.yaml)
#   - boot-persistent via Docker's restart policy (no systemd/launchd needed)
#
# Usage:
#   ./setup.sh                             # local 8123, HTTPS 8123
#   LOCAL_PORT=8124 HTTPS_PORT=8124 ./setup.sh
#   HA_ADMIN_USER=kai ./setup.sh           # first run only; .env wins after
#
# Version: pinned to 2026.9.1. Not `:stable` — that tag moves every month and
# HA ships breaking changes in point releases.
#
# ---------------------------------------------------------------------------
# THE THREE THINGS THAT MAKE THIS SCRIPT'S ORDERING NON-NEGOTIABLE
#
# 1. configuration.yaml is written BEFORE the container has ever started.
#    Home Assistant turns what it finds at first startup into config entries
#    under .storage/, and .storage wins from then on. Removing the Bluetooth
#    integration afterwards leaves its config entry — and a 24 errors/minute
#    log storm — exactly where it was. Measured. A script that starts the
#    container and then writes config has already lost.
#
# 2. .storage/http is SEEDED before the first boot too, and it — not
#    configuration.yaml — is where the listen address and the reverse-proxy
#    settings live. As of 2026.9 an `http:` YAML block is migrated into that
#    store ONCE, and it lands in a `pending` slot that is a five-minute TRIAL:
#    unless a human loads the UI and confirms it, HA marks it
#    `error: "not_promoted"`, reverts to `stable` (the DEFAULTS — wildcard
#    bind, no proxy trust) and never applies the pending config again. So a
#    perfectly correct `http:` block yields a correct server for five minutes
#    and a 0.0.0.0-bound one forever after. This deploy learned that the hard
#    way; see the long note in configuration.yaml. Seeding `stable` directly,
#    with `pending: null` and `yaml_migration_done: true`, is the fix, and it
#    has to be in place before HA first reads the store.
#
# 3. The onboarding `core_config` step is NEVER called. Posting it — even with
#    an empty body — returns 200 and accepts its defaults: latitude 0,
#    longitude 0, time_zone UTC. The step is then marked done and the UI never
#    asks again, so sunrise/sunset is quietly wrong forever. This script
#    completes `user` and `analytics` only and leaves the location question to
#    your first login, where HA shows a map picker. The timezone is handled in
#    configuration.yaml instead (that key IS still read from YAML every boot),
#    which is why the clock is right meanwhile.
# ---------------------------------------------------------------------------
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale logged in.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# Neither .env nor configuration.yaml is ever overwritten, and the admin
# account is created at most once — a re-run detects the completed onboarding
# step and leaves the server alone.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8123}"
HTTPS_PORT="${HTTPS_PORT:-8123}"
ADMIN_USER="${HA_ADMIN_USER:-kai}"
CONTAINER="home-assistant"
SERVICE="homeassistant"          # the compose service name

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
TEMPLATE="$SERVICE_DIR/configuration.yaml"
STATE="$HOME/services/home-assistant"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# 700. Holds request/response bodies, one of which is an access token.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 32 hex chars: [A-Za-z0-9]-safe, so it survives .env, shell quoting, a JSON
# body and a phone's on-screen keyboard without escaping. python3 when
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

# The host's zone, for configuration.yaml. timedatectl is the authority on a
# systemd box; /etc/localtime is the portable fallback and is what macOS has
# (it symlinks into /var/db/timezone/zoneinfo/..., so the same sed works).
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
# script — an empty result means "nothing listening, or nothing could tell us",
# and the callers distinguish those.
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

# Listeners that would actually stop Home Assistant binding 127.0.0.1:PORT —
# i.e. something already holding loopback, or a wildcard bind that covers it.
# Deliberately NOT "anything on this port": tailscaled binds the box's tailnet
# addresses on the same number once Serve is up (see non_loopback_listeners),
# and that does not conflict with a loopback bind. Treating it as a conflict
# would make every re-run with a stopped container refuse to start.
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

have_listener_tool() {
  command -v ss >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1
}

# The subset of the above that is NOT loopback and NOT tailscaled itself —
# i.e. the ones that would mean this deploy is reachable without going through
# Tailscale.
#
# THE TAILSCALE EXCEPTION IS LOAD-BEARING, not a loosening of the rule. This
# repo publishes on the same port number it listens on (8123 -> 8123), so once
# `tailscale serve --https=8123` is running, tailscaled itself binds the box's
# tailnet addresses on 8123:
#
#   127.0.0.1:8123                      <- Home Assistant
#   100.85.87.87:8123                   <- tailscaled, terminating TLS
#   [fd7a:115c:a1e0::a83b:5758]:8123    <- tailscaled, same
#
# Without this exception every correct deploy would be reported as leaking onto
# the LAN. The case that actually matters — HA binding 0.0.0.0 or [::] because
# server_host went missing — is still caught, and cannot coexist with
# tailscaled holding the same port anyway.
#
# Address shapes handled: `ss`/lsof (127.0.0.1:8123, [::1]:8123) and BSD
# netstat (127.0.0.1.8123, ::1.8123). `[` is stripped with tr rather than
# matched as a glob, because a bracket in a case pattern is a character class.
non_loopback_listeners() {  # non_loopback_listeners PORT
  local ts4 ts6 a host
  ts4="$("$TAILSCALE" ip -4 2>/dev/null | head -1 || true)"
  ts6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 || true)"
  listeners_on_port "$1" | while IFS= read -r a; do
    [ -n "$a" ] || continue
    host="${a%:*}"                       # ss/lsof:  host:port
    [ "$host" = "$a" ] && host="${a%.*}" # netstat:  host.port
    host="$(printf '%s' "$host" | tr -d '[]')"
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

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac

# The username goes into a JSON body verbatim; keep it to characters that need
# no escaping rather than shipping a hand-rolled JSON escaper.
case "$ADMIN_USER" in
  ''|*[!A-Za-z0-9._-]*) die "HA_ADMIN_USER must be [A-Za-z0-9._-] only (got: $ADMIN_USER)";;
esac

[ -f "$TEMPLATE" ] || die "Missing $TEMPLATE — that file is the configuration Home Assistant boots with, and it has to exist before the container starts. Re-clone the repo."

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# network_mode: host means something different on Docker Desktop: the daemon
# runs in a Linux VM, so "host" is the VM's network namespace, not the Mac's.
# Discovery will not see the Mac's LAN, and with server_host: 127.0.0.1 the
# port is on the VM's loopback where Tailscale on the Mac cannot reach it.
# Not fatal — say so plainly rather than pretending the deploy is equivalent.
if [ "$OS" = "Darwin" ]; then
  warn "On macOS, Docker Desktop/OrbStack run the daemon inside a Linux VM, so network_mode: host is the VM's network, not this Mac's."
  warn "  Expect two consequences: LAN discovery (zeroconf/SSDP/DHCP) will not see your real network, and 127.0.0.1:$LOCAL_PORT may not be reachable from the Mac at all — in which case Tailscale Serve has nothing to proxy to."
  warn "  This path has never been run on a Mac. Linux is the supported target."
fi

# The tailnet name is resolved up front because the verification at the end
# needs it, and because a box without MagicDNS cannot be published at all.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated admin password)"
  admin_pw="$(randhex)"
  tz="$(detect_tz)"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
# It is NOT passed to the container as env_file — the admin password below
# must not end up in the container's environment.

# Pinned exactly. Do not float to \`stable\`: that tag moves monthly and Home
# Assistant ships breaking changes in point releases. Back up \$HA_CONFIG,
# read that month's breaking-changes list, then bump this and re-run setup.sh.
# Downgrades are not supported once .storage has been migrated.
HA_VERSION=2026.9.1

# Where HA listens on loopback. This is a RECORD of what configuration.yaml
# says, not the source of truth — the server reads http.server_port from
# \$HA_CONFIG/configuration.yaml. Change both together, or not at all.
LOCAL_PORT="$LOCAL_PORT"

# The tailnet HTTPS port Tailscale Serve publishes on. Changing this does NOT
# remove the old mapping — undo that one by hand first:
#   tailscale serve --https=<old port> off
HTTPS_PORT="$HTTPS_PORT"

# The container's libc timezone. HA's own clock comes from
# \`homeassistant.time_zone\` in configuration.yaml; this is what subprocesses
# and log timestamps inside the container see.
TZ="$tz"

# THE INSTALLATION. configuration.yaml, .storage (config entries, the user
# registry, every device and entity you adopt), automations, the recorder
# database and the logs. This directory is the only backup target — and the
# container runs as root, so most of it ends up root-owned.
HA_CONFIG="$STATE/config"

# Admin account, created once over the onboarding API on first deploy.
# Changing these lines after that first run does nothing: change the password
# in the HA UI (your avatar -> Security) and mirror it back here by hand.
HA_ADMIN_USER="$ADMIN_USER"
HA_ADMIN_PASSWORD="$admin_pw"
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
REQUESTED_HTTPS_PORT="$HTTPS_PORT"
set -a; . "$ENV_FILE"; set +a
ADMIN_USER="${HA_ADMIN_USER:?HA_ADMIN_USER missing from $ENV_FILE}"
ADMIN_PASSWORD="${HA_ADMIN_PASSWORD:?HA_ADMIN_PASSWORD missing from $ENV_FILE}"
CONFIG_DIR="${HA_CONFIG:?HA_CONFIG missing from $ENV_FILE}"
# HTTPS_PORT was added to .env after the first releases of this script; fall
# back to the requested value rather than failing on an older file.
HTTPS_PORT="${HTTPS_PORT:-$REQUESTED_HTTPS_PORT}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. To move the port, edit LOCAL_PORT in .env AND http.server_port in $CONFIG_DIR/configuration.yaml, then re-run."
fi
if [ "$HTTPS_PORT" != "$REQUESTED_HTTPS_PORT" ]; then
  warn "HTTPS_PORT=$REQUESTED_HTTPS_PORT ignored — the existing $ENV_FILE says $HTTPS_PORT. To move the published port, first remove the old mapping (tailscale serve --https=$HTTPS_PORT off), then edit HTTPS_PORT in .env and re-run — otherwise both ports stay published."
fi

mkdir -p "$STATE" "$CONFIG_DIR"
[ -w "$CONFIG_DIR" ] || warn "$CONFIG_DIR is not writable by $USER (the container runs as root and owns most of it). That is normal after the first deploy; it only matters if configuration.yaml still has to be created."

# The recorder database is what grows here: every state change of every entity,
# kept 10 days by default. A few GB is normal for a busy install.
avail_kb="$(df -Pk "$CONFIG_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 5242880 ]; then
  warn "$(( avail_kb / 1024 )) MB free at $CONFIG_DIR — the recorder database records every state change of every entity and grows steadily. Free some space or move HA_CONFIG to a bigger disk."
else
  ok "$(( avail_kb / 1048576 )) GB free at $CONFIG_DIR"
fi

# ------------------------------------------- configuration.yaml (FIRST BOOT)
# This block runs BEFORE `docker compose up`. Read the header comment; the
# ordering is the single most important thing in this script.
LIVE_CONFIG="$CONFIG_DIR/configuration.yaml"
if [ -f "$LIVE_CONFIG" ]; then
  ok "configuration.yaml already exists, leaving untouched: $LIVE_CONFIG"
else
  # A .storage directory with no configuration.yaml means HA has booted here
  # before with some other config (or none). The first-boot-only settings are
  # already baked into .storage and writing the file now will not undo them.
  if [ -d "$CONFIG_DIR/.storage" ]; then
    warn "$CONFIG_DIR/.storage exists but configuration.yaml does not — Home Assistant has booted in this directory before."
    warn "  Writing the file now still fixes the reverse-proxy settings (they are read from yaml every boot), but any Bluetooth config entry discovery already created will persist and keep erroring."
    warn "  If you see 'Failed to force stop scanner' in the logs, the clean fix is: docker compose --project-directory $SERVICE_DIR down && sudo rm -rf $CONFIG_DIR && ./setup.sh"
  fi
  info "Writing configuration.yaml BEFORE the first boot (timezone + loopback bind + reverse proxy)"
  tz="$(detect_tz)"
  sed -e "s#__TIMEZONE__#$tz#g" -e "s#__SERVER_PORT__#$LOCAL_PORT#g" \
    "$TEMPLATE" > "$WORK/configuration.yaml"
  # Fail here rather than boot HA with a literal "__TIMEZONE__" in its config,
  # which it rejects at startup with a stack trace about an invalid time zone.
  if grep -q '__[A-Z_]*__' "$WORK/configuration.yaml"; then
    die "Placeholder substitution failed — $WORK/configuration.yaml still contains __PLACEHOLDER__ markers. $TEMPLATE may have been edited; expected __TIMEZONE__ and __SERVER_PORT__."
  fi
  cat "$WORK/configuration.yaml" > "$LIVE_CONFIG"
  chmod 644 "$LIVE_CONFIG"
  ok "Wrote $LIVE_CONFIG (time_zone: $tz, listening on 127.0.0.1:$LOCAL_PORT)"
fi

# Sanity-check whatever is actually there — generated or hand-edited. Warnings,
# not failures: the file is the user's to edit and HA will still start.
if grep -q '^default_config:' "$LIVE_CONFIG"; then
  warn "$LIVE_CONFIG uses 'default_config:'. That pulls in the bluetooth integration, which on this box fights the host's bluetoothd for hci0 and logs 'Failed to force stop scanner' 24 times a minute, forever. See the note at the top of $TEMPLATE for the expanded list that replaces it."
fi
if grep -q '^http:' "$LIVE_CONFIG"; then
  warn "$LIVE_CONFIG contains an 'http:' block. Since 2026.9 that block is IGNORED — the settings live in .storage/http (this script manages it). HA will also raise a 'yaml_still_present_after_migration' repair warning in the UI. Delete the block; see the long note at the top of $TEMPLATE."
fi

# ----------------------------------------- .storage/http (THE HTTP SETTINGS)
# This is where server_host / server_port / use_x_forwarded_for /
# trusted_proxies actually live as of 2026.9. Read item 2 of the header before
# touching any of it.
#
# The file is written by HA as root, mode 600, so the host user can neither
# read nor write it after the first boot. Everything below that needs to touch
# it therefore goes through the pinned image itself — which runs as root and
# ships python3 — rather than through sudo.
HTTP_STORE="$CONFIG_DIR/.storage/http"

# The exact shape HA expects: STORAGE_VERSION 2 / STORAGE_MINOR_VERSION 2, and
# a data dict with all three of stable/pending/yaml_migration_done. All three
# keys are read unconditionally (`raw[KEY_PENDING]`), so omitting `pending`
# gives `KeyError: 'pending'` and the whole http component fails to set up.
# `server_host` is a list (cv.ensure_list) and `trusted_proxies` are CIDR
# strings (_ip_network_str), not bare addresses. The remaining keys are
# HTTP_STORAGE_SCHEMA's own defaults, spelled out so the file is complete.
write_http_store() {  # write_http_store PATH
  printf '{"version":2,"minor_version":2,"key":"http","data":{"stable":{"server_host":["127.0.0.1"],"server_port":%s,"cors_allowed_origins":["https://cast.home-assistant.io"],"use_x_forwarded_for":true,"trusted_proxies":["127.0.0.1/32","::1/128"],"login_attempts_threshold":-1,"ip_ban_enabled":true,"ssl_profile":"modern","use_x_frame_options":true,"created_at":"%s","error":null,"error_message":null},"pending":null,"yaml_migration_done":true}}\n' \
    "$LOCAL_PORT" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$1"
}

# python3 as root with $CONFIG_DIR mounted, script on stdin. The image is
# already pinned and about to be run anyway, so this pulls nothing extra.
# LOCAL_PORT is passed with -e, not exported: `docker run` does not inherit the
# calling shell's environment, so a `VAR=x config_python` prefix would silently
# be invisible inside the container.
config_python() {
  docker run --rm -i -v "$CONFIG_DIR:/config" -e "HA_SEED_PORT=$LOCAL_PORT" \
    --entrypoint python3 "ghcr.io/home-assistant/home-assistant:${HA_VERSION:-2026.9.1}" - 2>/dev/null
}

if [ ! -f "$HTTP_STORE" ] && [ ! -d "$CONFIG_DIR/.storage" ]; then
  # Clean first boot: .storage does not exist yet, so it is still ours to
  # create and the seed needs no root at all.
  info "Seeding .storage/http BEFORE the first boot (loopback bind + reverse proxy)"
  mkdir -p "$CONFIG_DIR/.storage"
  write_http_store "$HTTP_STORE"
  chmod 644 "$HTTP_STORE"
  ok "Wrote $HTTP_STORE (server_host 127.0.0.1, port $LOCAL_PORT, Serve trusted as a proxy)"
else
  # .storage exists, so HA has booted here. Ask the image to read the store as
  # root and report on it. Anything other than "ok" is repaired below, because
  # the failure mode is Home Assistant on the LAN in plain HTTP.
  verdict="$(config_python <<'PY'
import json, os
p = "/config/.storage/http"
if not os.path.exists(p):
    print("missing"); raise SystemExit
try:
    d = json.load(open(p))["data"]
    s = d["stable"]
except Exception as e:
    print("unreadable:%s" % type(e).__name__); raise SystemExit
bad = []
if s.get("server_host") != ["127.0.0.1"]:
    bad.append("server_host=%r" % (s.get("server_host"),))
if s.get("use_x_forwarded_for") is not True:
    bad.append("use_x_forwarded_for=%r" % (s.get("use_x_forwarded_for"),))
if not s.get("trusted_proxies"):
    bad.append("trusted_proxies=%r" % (s.get("trusted_proxies"),))
if d.get("yaml_migration_done") is not True:
    bad.append("yaml_migration_done=%r" % (d.get("yaml_migration_done"),))
# ANY staged pending is bad, not just one that has already failed. A pending
# that has not failed yet is the more dangerous shape: it is a live trial, so
# right now the listener looks perfect, and in under five minutes HA reverts to
# `stable` and restarts. This rule has to match the one in the verification
# step at the end of the script exactly — when they disagreed, the repair did
# nothing, the verification failed, and the advice was "re-run setup.sh", which
# reached the same verdict forever.
if isinstance(d.get("pending"), dict):
    bad.append("a pending config is staged (it reverts in <=5 min unless promoted in the UI)")
print("ok" if not bad else "bad:" + ", ".join(bad))
PY
)"
  case "$verdict" in
    ok)
      ok ".storage/http is correct (loopback bind + Serve trusted as a proxy)"
      ;;
    '')
      warn "Could not read $HTTP_STORE to check the listen address (the image would not run). Skipping the check — the listener test at the end of this run is the backstop."
      ;;
    *)
      # A wrong store means HA binds 0.0.0.0 in plain HTTP under host
      # networking. Repair it rather than warn about it, and say exactly what
      # was wrong. HA rewrites this file on shutdown, so the container has to
      # be stopped first or the repair is overwritten seconds later.
      case "$verdict" in
        missing)
          warn "$HTTP_STORE does not exist, but Home Assistant has booted in $CONFIG_DIR before — so its listen address is whatever HA defaulted to, which is every interface."
          ;;
        unreadable*)
          warn "$HTTP_STORE could not be parsed (${verdict#unreadable:}). Treating it as broken rather than guessing."
          ;;
        *)
          warn "$HTTP_STORE is not what this deploy requires: ${verdict#bad:}"
          ;;
      esac
      warn "  Left alone, Home Assistant binds 0.0.0.0 under host networking — plain HTTP on the LAN — and rejects requests proxied by Tailscale Serve. Repairing it now."
      case "$verdict" in
        *"pending config is staged"*)
          warn "  Note: that staged trial is being DISCARDED. If you were part-way through changing the HTTP settings in Settings -> System -> Network, redo the change and confirm it in the UI — an unconfirmed trial reverts by itself anyway."
          ;;
      esac
      if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        info "Stopping $CONTAINER so the repair is not overwritten on shutdown"
        docker compose --project-directory "$SERVICE_DIR" stop \
          || die "Could not stop $CONTAINER to repair $HTTP_STORE. Do it by hand: docker compose --project-directory $SERVICE_DIR stop"
      fi
      # Merge rather than replace: keep any other keys already in `stable`
      # (a hand-set ssl_certificate, a changed port) and override only the
      # four this deploy is responsible for.
      repaired="$(config_python <<'PY'
import json, os, datetime
p = "/config/.storage/http"
port = int(os.environ.get("HA_SEED_PORT", "8123"))
try:
    raw = json.load(open(p))
    stable = dict(raw["data"]["stable"])
except Exception:
    raw, stable = {"version": 2, "minor_version": 2, "key": "http", "data": {}}, {}
stable.update({
    "server_host": ["127.0.0.1"],
    "use_x_forwarded_for": True,
    "trusted_proxies": ["127.0.0.1/32", "::1/128"],
    "error": None,
    "error_message": None,
})
stable.setdefault("server_port", port)
stable.setdefault("cors_allowed_origins", ["https://cast.home-assistant.io"])
stable.setdefault("login_attempts_threshold", -1)
stable.setdefault("ip_ban_enabled", True)
stable.setdefault("ssl_profile", "modern")
stable.setdefault("use_x_frame_options", True)
stable.setdefault("created_at", datetime.datetime.now(datetime.UTC).isoformat())
raw["version"], raw["minor_version"], raw["key"] = 2, 2, "http"
raw["data"] = {"stable": stable, "pending": None, "yaml_migration_done": True}
tmp = p + ".setup-tmp"
with open(tmp, "w") as fh:
    json.dump(raw, fh)
os.replace(tmp, p)
os.chmod(p, 0o600)
print("repaired")
PY
)"
      [ "$repaired" = "repaired" ] \
        || die "Could not repair $HTTP_STORE. The container is stopped. Fix it by hand — set data.stable.server_host to [\"127.0.0.1\"], data.stable.use_x_forwarded_for to true, data.stable.trusted_proxies to [\"127.0.0.1/32\",\"::1/128\"] and data.pending to null — then re-run ./setup.sh. Read it with: sudo cat $HTTP_STORE"
      ok "Repaired $HTTP_STORE — server_host is 127.0.0.1 and any pending trial is cleared"
      ;;
  esac
fi

# --------------------------------------------------- port availability
# Host networking means HA binds the host's port directly. If something else
# already holds it, HA does not warn — it fails to start its HTTP server and
# the container sits there logging a stack trace. Catch it here, where the
# message can name the port.
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  busy="$(blocking_listeners "$LOCAL_PORT")"
  if [ -n "$busy" ]; then
    die "Port $LOCAL_PORT is already in use by something that is not the $CONTAINER container: $(printf '%s' "$busy" | tr '\n' ' '). Home Assistant runs on the host network and would fail to bind. Free the port, or set LOCAL_PORT (and http.server_port in $LIVE_CONFIG) to something else."
  fi
fi

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Starting Home Assistant (docker compose up -d) — first run pulls ~1.5 GB"
"${COMPOSE[@]}" up -d

# ------------------------------------------------------------- API helpers
HA_CODE=""
HA_TOKEN=""
HA_BASE="http://127.0.0.1:$LOCAL_PORT"

ha() {  # ha METHOD PATH [json-body-file] -> body in $WORK/resp.json, code in $HA_CODE
  local method="$1" path="$2" bodyfile="${3:-}"
  set -- -sS -X "$method" -o "$WORK/resp.json" -w '%{http_code}' --max-time 60
  [ -n "$HA_TOKEN" ] && set -- "$@" -H "Authorization: Bearer $HA_TOKEN"
  [ -n "$bodyfile" ] && set -- "$@" -H 'Content-Type: application/json' --data-binary "@$bodyfile"
  # curl already prints 000 to stdout when it cannot connect, AND exits
  # non-zero. A `|| echo 000` fallback therefore CONCATENATES, turning a plain
  # connection failure into the nonsense code "000000" in the error message.
  # Take curl's own output and normalise anything unexpected.
  HA_CODE="$(curl "$@" "$HA_BASE$path" 2>/dev/null)" || true
  case "$HA_CODE" in
    [0-9][0-9][0-9]) ;;
    *) HA_CODE=000 ;;
  esac
}

# Pull a top-level string value out of the last response.
json_str() {  # json_str KEY
  tr -d '\n\r' < "$WORK/resp.json" 2>/dev/null \
    | sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1
}
resp_compact() { tr -d ' \n\r' < "$WORK/resp.json" 2>/dev/null || true; }

# GET /api/onboarding has two healthy shapes and both mean "the server is up":
#
#   200 + a JSON list of steps  — the normal case here, and it stays the normal
#                                 case, because this script deliberately never
#                                 finishes core_config.
#   404                         — every step is done. Measured: HA decides at
#                                 startup whether to register the onboarding
#                                 views at all, so this appears only after the
#                                 FIRST RESTART following a fully-completed
#                                 onboarding. In the same process that
#                                 completed it, /api/onboarding still answers
#                                 200 with everything true. So this branch is
#                                 what a re-run hits months from now, after you
#                                 have finished setup in the UI and the box has
#                                 rebooted — not a theoretical case.
#
# Anything else (000, 502, 503) is "not ready yet".
#
# 000 is treated as not-ready rather than as failure on purpose. The Jellyfin
# deploy in this repo died on exactly that: the container was up, a readiness
# probe passed, and the very next request came back 000 because the server had
# not finished accepting connections. Retrying a 000 costs nothing when the
# service is genuinely down (this still fails, just later) and removes the race
# when it is merely a second behind.
ONBOARDING_STATUS=""   # "open" (200) or "complete" (404)
wait_ready() {  # wait_ready ATTEMPTS
  local attempts="$1" i rc=1 saved_token="$HA_TOKEN"
  # Ask unauthenticated, always. /api/onboarding needs no token, but HA's auth
  # middleware rejects a request carrying a bad one with 401 rather than
  # ignoring it — so a token that had expired (they last 30 minutes) would turn
  # a healthy server into a readiness failure. Nothing here needs the token.
  # Restored on every exit path: the /api/config check at the end does need it.
  HA_TOKEN=""
  for i in $(seq 1 "$attempts"); do
    ha GET /api/onboarding
    case "$HA_CODE" in
      200) ONBOARDING_STATUS="open";     rc=0; break ;;
      404) ONBOARDING_STATUS="complete"; rc=0; break ;;
      *)   sleep 2 ;;
    esac
  done
  HA_TOKEN="$saved_token"
  return "$rc"
}

# "done" flag for one onboarding step, from the last GET /api/onboarding body.
# The payload is a list: [{"step": "user", "done": true}, ...]
step_done() {  # step_done STEP -> prints true|false|"" (unknown)
  resp_compact | sed -n "s/.*\"step\":\"$1\",\"done\":\([a-z]*\).*/\1/p" | head -1
}

info "Waiting for Home Assistant on 127.0.0.1:$LOCAL_PORT (first boot builds .storage; ~10-30s)"
wait_ready 90 || die "Home Assistant never answered on $HA_BASE/api/onboarding (last HTTP $HA_CODE). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
ok "Home Assistant is answering locally (GET /api/onboarding -> $HA_CODE)"

# ------------------------------------------------- onboarding (at most once)
# No marker file, deliberately. The server itself is the authority here and it
# answers unauthenticated, so there is nothing a marker could tell us that
# /api/onboarding cannot — and a marker would introduce a stale-marker failure
# mode (config dir wiped, marker survives, script skips account creation, you
# find out at the login form). As written, a wiped config dir simply gets the
# account recreated from the password already in .env.
CLIENT_ID="$HA_BASE/"
ACCOUNT_ACTION=""

if [ "$ONBOARDING_STATUS" = "complete" ]; then
  ACCOUNT_ACTION="skipped"
  ok "Onboarding is fully complete on this instance — leaving it alone"
elif [ "$(step_done user)" = "true" ]; then
  ACCOUNT_ACTION="skipped"
  ok "Onboarding user step already done — admin account exists, skipping"
else
  info "Creating the admin account over the onboarding API ($ADMIN_USER)"
  printf '{"client_id":"%s","name":"%s","username":"%s","password":"%s","language":"en"}' \
    "$CLIENT_ID" "$ADMIN_USER" "$ADMIN_USER" "$ADMIN_PASSWORD" > "$WORK/user.json"

  ha POST /api/onboarding/users "$WORK/user.json"
  case "$HA_CODE" in
    200)
      ACCOUNT_ACTION="created"
      ok "Admin account created: $ADMIN_USER"
      ;;
    403)
      # The documented idempotency signal: {"message":"User step already done"}.
      # A run that died between creating the account and finishing lands here
      # on its retry, and this is success, not failure.
      case "$(resp_compact)" in
        *'Userstepalreadydone'*)
          ACCOUNT_ACTION="skipped"
          ok "Admin account already exists (server says the user step is done) — skipping"
          ;;
        *)
          die "POST /api/onboarding/users was refused (HTTP 403): $(resp_compact). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
          ;;
      esac
      ;;
    000)
      die "POST /api/onboarding/users could not connect to $HA_BASE even though the readiness probe had just succeeded. The container may have restarted mid-deploy. Re-run ./setup.sh — it resumes from wherever the server actually is. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
      ;;
    *)
      die "Could not create the admin account (HTTP $HA_CODE): $(resp_compact). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
      ;;
  esac

  # THE AUTH CODE IS SINGLE-USE. Measured: a second exchange of the same code
  # returns no token. So this is one shot, no retry loop — a retry here could
  # only ever burn the code and report a confusing empty token. The readiness
  # probe above plus the successful POST we just made mean the server is
  # demonstrably accepting connections, so there is no race left to lose.
  #
  # And it is not fatal if it fails: the account already exists with the
  # password in .env, which is the part that matters. Only the analytics
  # opt-out is lost, and HA will simply ask about it at first login.
  if [ "$ACCOUNT_ACTION" = "created" ]; then
    auth_code="$(json_str auth_code)"
    if [ -z "$auth_code" ]; then
      warn "The account was created but the response carried no auth_code, so the analytics step could not be completed. Harmless: Home Assistant will ask you about analytics at first login. Answer it there."
    else
      code="$(curl -sS -o "$WORK/token.json" -w '%{http_code}' --max-time 60 \
        -X POST \
        --data-urlencode 'grant_type=authorization_code' \
        --data-urlencode "code=$auth_code" \
        --data-urlencode "client_id=$CLIENT_ID" \
        "$HA_BASE/auth/token" 2>/dev/null)" || true
      HA_TOKEN="$(tr -d '\n\r' < "$WORK/token.json" 2>/dev/null | sed -n 's/.*"access_token": *"\([^"]*\)".*/\1/p' | head -1)"
      if [ -n "$HA_TOKEN" ]; then
        ok "Exchanged the single-use auth code for an access token"
        # Completing this step with an empty body records "asked and not opted
        # in" — analytics stays off, and you are not shown the question again.
        # This is the ONLY other onboarding step this script touches;
        # core_config is left alone on purpose (see the header).
        printf '{}' > "$WORK/empty.json"
        ha POST /api/onboarding/analytics "$WORK/empty.json"
        case "$HA_CODE" in
          200) ok "Analytics step completed without opting in (nothing is uploaded)" ;;
          *)   warn "Could not complete the analytics onboarding step (HTTP $HA_CODE). Harmless — Home Assistant will ask you at first login." ;;
        esac
      else
        warn "Could not exchange the auth code for a token (HTTP ${code:-000}). Harmless: the admin account exists and the password in $ENV_FILE works. Home Assistant will ask about analytics at first login."
      fi
    fi
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
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ verification
# Five things, each of which has its own way of being quietly wrong.
echo
info "Verifying the deployment"
FAILED=0

# 1. The container is actually running (and not restart-looping).
cstate="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
crestarts="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)"
if [ "$cstate" = "running" ]; then
  if [ "${crestarts:-0}" -gt 2 ] 2>/dev/null; then
    warn "Container is running but has restarted ${crestarts} times — something is crashing it. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
  else
    ok "Container $CONTAINER is running"
  fi
else
  FAILED=1
  warn "Container $CONTAINER is '${cstate:-missing}', not running. Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
fi

# 2. Local health, and 3. the onboarding user step — one request answers both.
if wait_ready 15; then
  ok "GET $HA_BASE/api/onboarding answers (HTTP $HA_CODE)"
  if [ "$ONBOARDING_STATUS" = "complete" ]; then
    ok "Onboarding: every step is done (HA no longer serves the onboarding API)"
  else
    case "$(step_done user)" in
      true)
        ok "Onboarding: user step reports done: true — the admin account exists"
        ;;
      *)
        FAILED=1
        warn "Onboarding: the user step does NOT report done: true. There is no admin account, and the first visit will show the account-creation screen. Body: $(resp_compact)"
        ;;
    esac
    if [ "$(step_done core_config)" = "true" ]; then
      warn "The core_config onboarding step is already done. If this deploy did that, latitude/longitude are 0 and the timezone is UTC — check Settings -> System -> General and fix them by hand; the UI will not prompt you."
    else
      ok "Onboarding: core_config left open, so HA will ask for your location on first login (as intended)"
    fi
  fi
else
  FAILED=1
  warn "No answer from $HA_BASE/api/onboarding (last HTTP $HA_CODE). Logs: docker compose --project-directory $SERVICE_DIR logs --tail 100 $SERVICE"
fi

# 4. THE LOOPBACK RULE. host networking + server_host: 127.0.0.1 is the whole
# reason this deploy is safe; if the pair ever comes apart, plain HTTP is on
# the LAN. Assert it against the kernel, not against the config file.
if have_listener_tool; then
  bound="$(listeners_on_port "$LOCAL_PORT" | tr '\n' ' ')"
  exposed="$(non_loopback_listeners "$LOCAL_PORT" | tr '\n' ' ')"
  if [ -n "$exposed" ]; then
    FAILED=1
    warn "Port $LOCAL_PORT is listening on a NON-LOOPBACK address: $exposed"
    warn "  With host networking that means plain HTTP is reachable from the LAN. Fix: ensure 'server_host: 127.0.0.1' is under http: in $LIVE_CONFIG, then: docker compose --project-directory $SERVICE_DIR restart"
  elif [ -n "$bound" ]; then
    ok "Listener is loopback-only: $bound"
  else
    warn "Nothing appears to be listening on port $LOCAL_PORT, yet the HTTP check above passed. Odd — check by hand: ss -ltn | grep $LOCAL_PORT"
  fi

  # 4b. Home Assistant's subprocesses get the host network too, and go2rtc's
  # WebRTC listener binds every interface (:::18555) with no way to move it.
  # This deploy leaves go2rtc out of configuration.yaml precisely so that port
  # never appears; check rather than assume, because someone reading about
  # camera latency will eventually add `go2rtc:` back.
  g2rtc_exposed="$(non_loopback_listeners 18555 | tr '\n' ' ')"
  if [ -n "$g2rtc_exposed" ]; then
    warn "Port 18555 is listening on a non-loopback address: $g2rtc_exposed"
    warn "  That is go2rtc's WebRTC listener, reachable from the LAN without TLS. It appears when 'go2rtc:' is in $LIVE_CONFIG. Remove that line and restart, or accept the exposure deliberately — see the note in $TEMPLATE."
  fi

  # 4c. The listener check above is a snapshot, and a snapshot is not enough
  # here. A `pending` HTTP config is a five-minute trial: it produces a
  # perfectly correct loopback listener right now and then reverts to the
  # wildcard-bound defaults and restarts. That is exactly how this deploy
  # failed the first time, and a port scan taken in the trial window says
  # everything is fine. So assert the durable state too.
  store_verdict="$(config_python <<'PY'
import json, os
p = "/config/.storage/http"
if not os.path.exists(p):
    print("missing"); raise SystemExit
try:
    d = json.load(open(p))["data"]
    s = d["stable"]
except Exception as e:
    print("unreadable:%s" % type(e).__name__); raise SystemExit
bad = []
if s.get("server_host") != ["127.0.0.1"]:
    bad.append("stable.server_host=%r" % (s.get("server_host"),))
if s.get("use_x_forwarded_for") is not True:
    bad.append("stable.use_x_forwarded_for=%r" % (s.get("use_x_forwarded_for"),))
if not s.get("trusted_proxies"):
    bad.append("stable.trusted_proxies=%r" % (s.get("trusted_proxies"),))
if isinstance(d.get("pending"), dict):
    bad.append("a pending config is staged (it will revert in <=5 min unless promoted in the UI)")
print("ok" if not bad else "bad:" + ", ".join(bad))
PY
)"
  case "$store_verdict" in
    ok)  ok ".storage/http: the loopback bind and proxy trust are in the durable 'stable' slot" ;;
    '')  warn "Could not re-read $HTTP_STORE to confirm the listen address is durable." ;;
    *)   FAILED=1
         warn ".storage/http is wrong even though the listener looks right: ${store_verdict#bad:}"
         warn "  This is the dangerous shape: correct now, wildcard-bound after the next restart. Re-run ./setup.sh — it repairs the file with the container stopped."
         ;;
  esac
else
  warn "Neither ss, lsof nor netstat is available, so the loopback-only bind could not be verified. Check by hand that nothing but 127.0.0.1 listens on $LOCAL_PORT."
fi

# 5. End to end over the tailnet. This also proves the trusted-proxy settings:
# without them HA answers a proxied request with 400 rather than 200, which
# looks like a Serve or certificate problem and is neither.
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
https_code="$(curl -sS -o "$WORK/https.json" -w '%{http_code}' --max-time 90 "$url/api/onboarding" 2>/dev/null)" || true
case "$https_code" in
  200|404)
    ok "End-to-end HTTPS check passed (GET $url/api/onboarding -> $https_code)"
    ;;
  400)
    FAILED=1
    warn "$url/api/onboarding returned 400. That is Home Assistant rejecting a request that came through a reverse proxy it does not trust. Fix: ensure use_x_forwarded_for: true and 127.0.0.1 under trusted_proxies in $LIVE_CONFIG, then: docker compose --project-directory $SERVICE_DIR restart"
    ;;
  *)
    warn "No usable answer on $url/api/onboarding yet (HTTP ${https_code:-000}) — the TLS certificate may still be minting on first publish. Retry in a minute: curl -o /dev/null -w '%{http_code}\\n' $url/api/onboarding"
    ;;
esac

# Bonus, best-effort: if this run minted a token, ask the server what it thinks
# its own timezone is and whether bluetooth got loaded. Both are things
# configuration.yaml is supposed to have settled before the first boot, and
# both are invisible until something goes wrong months later.
if [ -n "$HA_TOKEN" ]; then
  ha GET /api/config
  if [ "$HA_CODE" = "200" ]; then
    live_tz="$(json_str time_zone)"
    want_tz="$(detect_tz)"
    if [ "$live_tz" = "$want_tz" ]; then
      ok "Home Assistant's timezone is $live_tz (matches this host)"
    else
      warn "Home Assistant reports timezone '$live_tz' but this host is '$want_tz'. Sunrise/sunset and every time-based automation will be off. Fix time_zone in $LIVE_CONFIG and restart."
    fi
    case "$(resp_compact)" in
      *'"bluetooth"'*)
        warn "The bluetooth integration is loaded. On this box the host's bluetoothd owns hci0, so HA will lose the fight for the adapter and log 'Failed to force stop scanner' ~24 times a minute. See the note at the top of $TEMPLATE."
        ;;
      *) ok "Bluetooth is not loaded (no fight with the host's bluetoothd over hci0)" ;;
    esac
    case "$(resp_compact)" in
      *'"zeroconf"'*) ok "Discovery is live (zeroconf loaded — host networking is doing its job)" ;;
      *) warn "The zeroconf integration is not loaded, so device discovery is not running. Check the logs for a startup error." ;;
    esac
  fi
fi

# ------------------------------------------------------------ summary
echo
printf '\033[1;32mDone.\033[0m Home Assistant is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
if [ "$ACCOUNT_ACTION" = "created" ]; then
  echo "  Login:    $ADMIN_USER"
  echo "  Password: see HA_ADMIN_PASSWORD in $ENV_FILE"
  echo "    (32 random hex characters. Change it in the UI under your avatar ->"
  echo "     Security if you like — then mirror the new one back into .env, or"
  echo "     just delete that line; nothing re-reads it after this run.)"
else
  echo "  Login:    $ADMIN_USER  (account already existed; not touched this run)"
  echo "  Password: whatever it currently is — see HA_ADMIN_PASSWORD in $ENV_FILE"
  echo "    if it has never been changed in the UI."
fi
echo
echo "FIRST LOGIN — one thing is deliberately left for you:"
echo "  Home Assistant will ask for your home's LOCATION on a map, and for"
echo "  units and currency. That is on purpose. This script could have posted"
echo "  that step over the API, but doing so accepts latitude 0 / longitude 0 /"
echo "  timezone UTC and marks it answered, so the UI never asks again and"
echo "  sunrise/sunset — the most-used thing in HA — is quietly wrong forever."
echo "  Drag the pin to your actual house. The timezone is already correct."
echo
echo "  It will also offer to set up discovered devices. Everything on your LAN"
echo "  that speaks mDNS/SSDP should already be listed: the container runs on"
echo "  the host network so discovery can see broadcast traffic."
echo
echo "Bluetooth is OFF in this deploy, on purpose. This box has a USB adapter"
echo "  (hci0) that the host's own bluetoothd already owns; loading HA's"
echo "  bluetooth integration makes the two fight over it and floods the log"
echo "  with 'Failed to force stop scanner' 24 times a minute. To use BLE"
echo "  devices you have to give HA the adapter outright — see the recipe at"
echo "  the top of $TEMPLATE."
echo
echo "Cameras: go2rtc is OFF too, for the same class of reason. Under host"
echo "  networking its WebRTC listener binds every interface (:::18555) and HA"
echo "  gives no setting to move it, so it would be the one thing in this deploy"
echo "  reachable from the LAN without TLS. Cameras still work — 'stream:' is"
echo "  loaded and they play over HLS; you lose sub-second WebRTC latency."
echo
echo "Companion app (phone presence, notifications, sensors):"
echo "  Install Home Assistant Companion (iOS/Android), make sure the phone is"
echo "  on the tailnet, then choose 'Enter address manually' and give it"
echo "    $url"
echo "  The app will not find this server by scanning — it is not on your LAN"
echo "  from the phone's point of view, it is behind Tailscale."
echo
echo "Config: $LIVE_CONFIG  (yours to edit; setup.sh never overwrites it)"
echo "  After editing: Developer tools -> YAML -> Check configuration, then"
echo "  Restart. Or from here: docker compose --project-directory $SERVICE_DIR restart"
echo
echo "  BUT the listen address and the reverse-proxy settings are NOT in that"
echo "  file. Since 2026.9 they live in $HTTP_STORE"
echo "  (root-owned, mode 600). An 'http:' block in configuration.yaml is"
echo "  ignored and only earns you a repair warning in the UI. This script"
echo "  seeds that store before the first boot and re-checks it every run —"
echo "  it is the reason Home Assistant binds 127.0.0.1 and not 0.0.0.0."
echo "  To change the port: stop the container, edit both server_port there"
echo "  and LOCAL_PORT in .env, then re-run ./setup.sh."
echo
echo "Backups: nothing backs this box up. The whole installation — .storage"
echo "  (config entries, users, every device and entity), automations, the"
echo "  recorder database — lives in $CONFIG_DIR. The container runs as root,"
echo "  so that directory is root-owned and a copy needs sudo:"
echo "    docker compose --project-directory $SERVICE_DIR stop &&"
echo "    sudo tar czf ~/home-assistant-\$(date +%F).tgz -C $CONFIG_DIR . &&"
echo "    sudo chown \$USER ~/home-assistant-\$(date +%F).tgz &&"
echo "    docker compose --project-directory $SERVICE_DIR start"
echo "  HA also has its own backups (Settings -> System -> Backups), which land"
echo "  inside that same directory — useful for restores, useless if the disk dies."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: back up first, read the month's breaking changes, then bump"
echo "         HA_VERSION in $ENV_FILE and re-run ./setup.sh"

if [ "$FAILED" = "1" ]; then
  echo
  die "One or more verification checks above failed — the deploy is up but not in the state this script promises. Fix what is flagged, then re-run ./setup.sh."
fi
exit 0
