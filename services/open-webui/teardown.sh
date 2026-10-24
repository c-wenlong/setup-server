#!/usr/bin/env bash
#
# teardown.sh — take Open WebUI off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — the container and its network go, the data
#      directory stays
#   3. keep .env and the data dir, so ./setup.sh brings it back as it was
#
# ollama is a separate system service and is never touched: its process and
# its models stay exactly as they are.
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the data dir and .env; asks you to
#                            # type "open-webui" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="open-webui"
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

# .env is the authority for ports and paths. Values are read the way Docker
# Compose reads them (an optional `export `, matching single or double quotes,
# an inline ` #` comment after an unquoted value) without executing the file.
env_get() {
  local line value tail
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}" ;;
  esac
  printf '%s' "$value"
}
LOCAL_PORT="$(env_get LOCAL_PORT)"
DATA_DIR="$(env_get WEBUI_VOLUME)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, data ${DATA_DIR:-(not set)}"

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""
if [ "$PURGE" -eq 1 ]; then
  [ -n "$DATA_DIR" ] || die "WEBUI_VOLUME is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "WEBUI_VOLUME=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "WEBUI_VOLUME=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ -e "$DATA_DIR" ]; then
    [ -d "$DATA_DIR" ] || die "WEBUI_VOLUME=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(cd "$DATA_DIR" && pwd -P)" || die "Cannot resolve $DATA_DIR."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "WEBUI_VOLUME=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  warn "--purge deletes ${PURGE_DIR:-nothing (no data dir on disk)} and $ENV_FILE. This cannot be undone."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's local port, and
# nothing else: ports are found from what Serve actually publishes, not from
# what .env says was published (a re-run can publish a second port). A port
# shared with another handler (e.g. :443 with the launcher's /home) is left
# alone with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" '
  function flush() {
    if (port != "") {
      if (n > 0 && mine == n) print "off " port
      else if (mine > 0) print "mixed " port
    }
    port = ""; n = 0; mine = 0
  }
  index($0, "https://") == 1 {
    flush()
    u = $1; sub(/\/$/, "", u)
    port = match(u, /:[0-9]+$/) ? substr(u, RSTART + 1) : "443"
    next
  }
  port != "" && /\|-- / { n++; if (/ proxy / && $NF == t) mine++ }
  END { flush() }')"
unpublished=0
while read -r verdict port; do
  [ -n "${verdict:-}" ] || continue
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
    unpublished=$((unpublished + 1))
  else
    warn "HTTPS :$port also serves something else, so it is left on. Drop this service's path from it by hand."
  fi
done <<EOF
$SERVE_PLAN
EOF
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET (already off)"

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; data in $DATA_DIR kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging data"
  if [ -n "$PURGE_DIR" ]; then
    # The image runs as root, so cache/, uploads/, vector_db/ and the SQLite
    # files are root-owned and a plain rm stops halfway. Try it first (a dir
    # that never booted is all yours); otherwise empty the dir with a
    # throwaway container of the app's own image, already on this box (no
    # pull, no sudo), then remove the empty directory.
    rm -rf -- "$PURGE_DIR" 2>/dev/null || true
    if [ -e "$PURGE_DIR" ]; then
      info "Some files are root-owned; clearing them with the app image"
      WEBUI_IMAGE="$(env_get WEBUI_IMAGE)"
      WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
      docker run --rm --pull never -v "$PURGE_DIR:/purge" --entrypoint sh "$WEBUI_IMAGE" \
        -c 'find /purge -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear root-owned files in $PURGE_DIR. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$PURGE_DIR" 2>/dev/null || true
      [ ! -e "$PURGE_DIR" ] || die "$PURGE_DIR is still there. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
    fi
  fi
  rm -f -- "$ENV_FILE"
  # setup.sh made ~/services/open-webui just to hold the data dir; drop it too
  # if it is now empty, so nothing is left behind that looks like an install.
  if [ -n "$PURGE_DIR" ]; then
    parent="$(dirname "$PURGE_DIR")"
    case "$parent" in "$root"/?*) rmdir -- "$parent" 2>/dev/null || true ;; esac
  fi
  ok "Deleted ${PURGE_DIR:-(no data dir)} and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  ollama and its models were not touched."
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
