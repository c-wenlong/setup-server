#!/usr/bin/env bash
#
# teardown.sh — take Constellations off the launcher's published port.
# Linux + macOS.
#
# The inverse of setup.sh's publish, and nothing more:
#   1. unpublish every Tailscale Serve port whose handlers all proxy to
#      this app's local port, found from `tailscale serve status`
#      (never `serve reset`)
#   2. stop design-research.service so a reboot does not bring it back
#   3. keep .env and the app's data (~/services/design-research), so
#      ./setup.sh brings the publish back
#
# The app's checkout, database and update timer are owned by the
# constellations repo. This script does not delete them. --purge deletes
# only this service's .env, after you type "constellations".
#
# Usage:
#   ./teardown.sh            # unpublish and stop; data and .env kept
#   ./teardown.sh --purge    # also delete .env
#
# Reads the port from .env and refuses to guess when it is missing.

set -euo pipefail

NAME="constellations"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
UNIT_NAME="design-research.service"
PLIST_LABEL="com.setup-server.constellations"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) die "Unknown option: $1 (usage: ./teardown.sh [--purge])" ;;
esac
[ "$#" -le 1 ] || die "Too many arguments (usage: ./teardown.sh [--purge])"

detect_os
info "Preflight checks ($OS)"
refuse_root
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down."
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
fi
resolve_tailscale

env_get() {
  local line value tail quote=""
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) quote='"'; value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) quote="'"; value="${value#\'}"; value="${value%%\'*}" ;;
  esac
  if [ -z "$quote" ]; then
    value="${value%% #*}"
    tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  fi
  printf '%s' "$value"
}

env_lint "$ENV_FILE"
LOCAL_PORT="$(env_get LOCAL_PORT)"
[ -n "$LOCAL_PORT" ] || die "LOCAL_PORT missing from $ENV_FILE"
require_numeric LOCAL_PORT
TARGET="http://127.0.0.1:$LOCAL_PORT"

# Confirm before anything changes. A piped answer is consumed by the first
# read, so this cannot sit after the unpublish.
if [ "$PURGE" -eq 1 ]; then
  printf 'Type "%s" to delete .env: ' "$NAME"
  read -r typed || true
  [ "$typed" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# Every HTTPS port whose handlers all proxy to this app, and nothing else.
# Ports come from what Serve publishes, not from .env. A shared port is
# left on with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET"
SERVE_STATUS="$("$TAILSCALE" serve status)" || die "cannot read tailscale serve status; nothing was changed"
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
    warn "HTTPS :$port also serves something else, so it is left on."
  fi
done <<EOF
$SERVE_PLAN
EOF
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET (already off)"

if [ "$OS" = "Linux" ]; then
  systemctl --user disable --now "$UNIT_NAME" || true
else
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" || true
fi
ok "Stopped $UNIT_NAME"

if [ "$PURGE" -eq 1 ]; then
  rm -f "$ENV_FILE"
  ok "Deleted $ENV_FILE"
fi

ok "Constellations is unpublished. The app data in ~/services/design-research was left in place."
