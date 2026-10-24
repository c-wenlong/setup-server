#!/usr/bin/env bash
#
# teardown.sh — take Stirling PDF off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish THIS service's Tailscale Serve port (never `serve reset`,
#      and only if that port really points at this service)
#   2. `docker compose down` — the container and its network go, the data
#      directory stays
#   3. keep .env and the data dir, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the data dir and .env; asks you to
#                            # type "stirling-pdf" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="stirling-pdf"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) die "Unknown option: $1 (usage: ./teardown.sh [--purge])" ;;
esac
[ "$#" -le 1 ] || die "Too many arguments (usage: ./teardown.sh [--purge])"

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
command -v docker >/dev/null || die "Docker is not installed."
if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Run via: sg docker -c ./teardown.sh"
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

# .env is the authority for ports and paths. Read the values we need without
# sourcing it into this shell's environment wholesale.
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
LOCAL_PORT="$(env_get LOCAL_PORT)"
DATA_DIR="$(env_get STIRLING_DATA)"
FRONTEND="$(env_get SYSTEM_FRONTENDURL)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric";; esac
# setup.sh does not store HTTPS_PORT; it is the port in SYSTEM_FRONTENDURL,
# and follows LOCAL_PORT when that is absent.
HTTPS_PORT="${HTTPS_PORT:-$(printf '%s' "$FRONTEND" | sed -n 's#^https://[^/:]*:\([0-9][0-9]*\)/*$#\1#p')}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
case "$HTTPS_PORT" in *[!0-9]*) die "Could not work out the HTTPS port (got: $HTTPS_PORT)";; esac
ok "$NAME: local :$LOCAL_PORT, published :$HTTPS_PORT, data $DATA_DIR"

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
if [ "$PURGE" -eq 1 ]; then
  [ -n "$DATA_DIR" ] || die "STIRLING_DATA is missing from $ENV_FILE — refusing to guess what to delete."
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "STIRLING_DATA=$DATA_DIR is not under $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  case "$DATA_DIR" in *..*) die "STIRLING_DATA=$DATA_DIR contains '..' — refusing." ;; esac
  warn "--purge deletes $DATA_DIR and $ENV_FILE. This cannot be undone."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Only this port, and only if Serve really sends it to this service: a stale
# or hand-edited .env must never unpublish a neighbour.
info "Unpublishing Tailscale Serve HTTPS :$HTTPS_PORT"
serve_target="$("$TAILSCALE" serve status 2>/dev/null \
  | awk -v p=":$HTTPS_PORT" '
      index($0, "https://") == 1 { split($1, a, " "); cur = (substr(a[1], length(a[1]) - length(p) + 1) == p); next }
      cur && /proxy / { print $NF; exit }' || true)"
if [ -z "$serve_target" ]; then
  ok "HTTPS :$HTTPS_PORT is not published (already off)"
elif [ "$serve_target" = "http://127.0.0.1:$LOCAL_PORT" ]; then
  "$TAILSCALE" serve --https="$HTTPS_PORT" off >/dev/null
  ok "Tailscale Serve: HTTPS :$HTTPS_PORT off"
else
  warn "HTTPS :$HTTPS_PORT points at $serve_target, not this service (127.0.0.1:$LOCAL_PORT) — leaving it alone."
fi

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; data in $DATA_DIR kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging data"
  rm -rf -- "$DATA_DIR"
  rm -f -- "$ENV_FILE"
  ok "Deleted $DATA_DIR and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
