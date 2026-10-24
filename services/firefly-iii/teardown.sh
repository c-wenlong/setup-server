#!/usr/bin/env bash
#
# teardown.sh — take Firefly III (and its Data Importer) off this box.
# Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service (the app
#      and the Data Importer), found from `tailscale serve status` (never
#      `serve reset`)
#   2. `docker compose down` — the three containers and their network go; the
#      ledger, uploads, importer config and .env stay
#   3. keep .env and the state dirs, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: ledger, uploads and .env kept
#   ./teardown.sh --purge    # ALSO delete the database dir, uploads, importer
#                            # config and .env; asks you to type "firefly-iii"
#                            # first. Terminal only: the launcher's Remove
#                            # button never passes it.
#
# --purge DESTROYS THE LEDGER and the APP_KEY that decrypts parts of any dump.
# Nothing else on this box backs it up. Dump first (see TROUBLESHOOT.md).
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="firefly-iii"
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
IMPORTER_PORT="$(env_get IMPORTER_PORT)"
if [ -z "$IMPORTER_PORT" ]; then
  # setup.sh's default; older .env files lack it. Said out loud, because a
  # Serve port pointing only at :8099 will be taken down on that assumption.
  IMPORTER_PORT=8099
  warn "IMPORTER_PORT is not in $ENV_FILE; assuming setup.sh's default 8099."
fi
DB_DATA="$(env_get FIREFLY_DB_DATA)"
UPLOAD_DIR="$(env_get FIREFLY_UPLOAD)"
IMPORTER_CONFIG="$(env_get FIREFLY_IMPORTER_CONFIG)"
POSTGRES_VERSION="$(env_get POSTGRES_VERSION)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
case "$IMPORTER_PORT" in *[!0-9]*) die "IMPORTER_PORT in $ENV_FILE is not numeric (got: $IMPORTER_PORT)";; esac
[ "$LOCAL_PORT" != "$IMPORTER_PORT" ] || die "LOCAL_PORT and IMPORTER_PORT in $ENV_FILE are both $LOCAL_PORT — refusing to guess."
TARGET_APP="http://127.0.0.1:$LOCAL_PORT"
TARGET_IMP="http://127.0.0.1:$IMPORTER_PORT"
ok "$NAME: local app :$LOCAL_PORT, importer :$IMPORTER_PORT, ledger ${DB_DATA:-(not set)}"

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIRS=""   # newline-separated real paths that exist on disk
PURGE_LABELS="" # what the user is told is being deleted
# check_purge_dir VAR VALUE — the guard every state dir goes through.
check_purge_dir() {
  local var="$1" dir="$2" root real
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    real="$(cd "$dir" && pwd -P)" || die "Cannot resolve $dir."
    case "$real" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $real, which is not a folder inside $root — refusing." ;;
    esac
    PURGE_DIRS="${PURGE_DIRS:+$PURGE_DIRS
}$real"
    PURGE_LABELS="${PURGE_LABELS:+$PURGE_LABELS, }$real"
  else
    PURGE_LABELS="${PURGE_LABELS:+$PURGE_LABELS, }(absent: $dir)"
  fi
}
if [ "$PURGE" -eq 1 ]; then
  check_purge_dir FIREFLY_DB_DATA "$DB_DATA"
  check_purge_dir FIREFLY_UPLOAD "$UPLOAD_DIR"
  check_purge_dir FIREFLY_IMPORTER_CONFIG "$IMPORTER_CONFIG"
  warn "--purge deletes the LEDGER and its APP_KEY: $PURGE_LABELS and $ENV_FILE."
  warn "Nothing else backs this up. If you have not dumped the database, stop now (TROUBLESHOOT.md, Nuke and pave)."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to one of this service's local
# ports (app or importer), and nothing else: ports are found from what Serve
# actually publishes, not from what .env says was published (a re-run can
# publish a second port). A port shared with another handler (e.g. :443 with
# the launcher's /home) is left alone with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET_APP or $TARGET_IMP"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t1="$TARGET_APP" -v t2="$TARGET_IMP" '
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
  port != "" && /\|-- / { n++; if (/ proxy / && ($NF == t1 || $NF == t2)) mine++ }
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
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET_APP or $TARGET_IMP (already off)"

# ---------------------------------------------------------------- stop
# Plain `down`, never -v: the compose file declares no named volumes (all state
# is bind-mounted from the dirs in .env), and a safe remove keeps those.
info "Stopping and removing the containers (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Containers removed; ledger in ${DB_DATA:-(not set)} kept"

# ---------------------------------------------------------------- purge
# Postgres and the Firefly container write as their own uids, so the contents
# of these dirs are usually not removable by you. Try a plain rm; if anything
# is left, empty the dir from a throwaway container that is root (using the
# postgres image the stack already pulled, never fetching anything).
if [ "$PURGE" -eq 1 ]; then
  info "Purging ledger, uploads and importer config"
  PG_IMAGE="postgres:${POSTGRES_VERSION:-16-alpine}"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rm -rf -- "$dir" 2>/dev/null || true
    if [ -e "$dir" ]; then
      info "Some files in $dir belong to another uid; clearing them from a container"
      docker run --rm --pull=never -v "$dir":/purge --entrypoint sh "$PG_IMAGE" \
        -c 'find /purge -mindepth 1 -delete' >/dev/null \
        || die "Could not empty $dir. Remove it by hand (sudo rm -rf '$dir'), then delete $ENV_FILE."
      rm -rf -- "$dir"
    fi
    ok "Deleted $dir"
  done <<EOF
$PURGE_DIRS
EOF
  rm -f -- "$ENV_FILE"
  # setup.sh's own parent dir, only if nothing else lives there.
  rmdir "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its ledger is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Ledger, uploads and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too (destroys the ledger): ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
