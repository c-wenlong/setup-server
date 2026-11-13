#!/usr/bin/env bash
#
# teardown.sh — take ntfy-control (the phone-control listener) off this
# box. Linux + macOS.
#
# The inverse of setup.sh's run, and nothing more:
#   1. Linux: stop + disable ntfy-control.service. The unit file stays
#      until --purge; lingering is left alone — every user unit on the
#      box relies on it, not just this one.
#   2. macOS: bootout + delete the com.ntfy-control.listener LaunchAgent
#      (launchd reloads a kept plist at login, so it always goes).
#   3. keep ~/services/ntfy-control (only generated copies of the
#      listener) and .env, so ./setup.sh brings it back as it was.
#
# The listener polls ntfy on loopback — setup.sh never published
# anything, so there is no Serve mapping to drop and no port to free.
#
# Usage:
#   ./teardown.sh            # safe remove: .env and SERVICE_HOME kept
#   ./teardown.sh --purge    # ALSO delete SERVICE_HOME, .env, the unit
#                            # file and the listener log; asks you to
#                            # type "ntfy-control" first. Terminal only.
#
# Reads SERVICE_HOME from .env the way a source would (never by
# executing it) and refuses to guess when .env is missing. Idempotent:
# re-running on a removed service changes nothing.
#
# Note: this removes the box's phone control — start/stop/status
# messages go unanswered until ./setup.sh puts the listener back.

set -euo pipefail

NAME="ntfy-control"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
UNIT_NAME="ntfy-control.service"
UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
PLIST_LABEL="com.ntfy-control.listener"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LISTENER_LOG="$HOME/Library/Logs/ntfy-control.log"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) die "Unknown option: $1 (usage: ./teardown.sh [--purge])" ;;
esac
[ "$#" -le 1 ] || die "Too many arguments (usage: ./teardown.sh [--purge])"

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
fi

# .env is the authority for paths. Values are read the way Docker Compose
# and `source` would read them (export prefix, quotes, inline comment,
# $HOME/${HOME}), never by executing the file. env_lint refuses anything
# the two could disagree on — a duplicated key, an unclosed quote, a
# backslash escape, a line that is not KEY=value — instead of parsing it
# differently than the deployment did.
env_lint() {
  local problem
  problem="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/\r$/, "", line)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) { print "line " NR " is not KEY=value"; exit }
      key = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1)
      if (seen[key]++) { print key " is set more than once"; exit }
      q = substr(val, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(val, 2); end = index(rest, q)
        if (end == 0) { print "the quoted value of " key " does not close on its line"; exit }
        if (q == "\"" && index(substr(rest, 1, end - 1), "\\") > 0) { print "the value of " key " uses a backslash escape"; exit }
      }
    }' "$ENV_FILE")"
  [ -z "$problem" ] || die "$ENV_FILE: $problem. Fix that line (teardown will not guess how Compose reads it) and re-run."
}

env_get() {
  local line value tail quote=""
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) quote='"'; value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) quote="'"; value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}"
       tail="${value##*[![:space:]]}"; value="${value%"$tail"}" ;;
  esac
  # Compose interpolates $HOME / ${HOME} in unquoted and double-quoted
  # values (single quotes are literal). That one variable is all a path
  # here may use; anything else is left as written and then fails the
  # path checks.
  if [ "$quote" != "'" ]; then
    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
  fi
  printf '%s' "$value"
}

# real_dir DIR → canonical path, but only when DIR is a real directory
# (not a symlinked leaf, no dot components, no colon or newline) inside
# ~/services/ntfy-control — and never a directory that holds this
# checkout (a repo cloned inside ~/services/ntfy-control must survive a
# purge). Resolves the PARENT by path, so a missing or unreadable leaf
# never sends a cd into a directory we are about to delete.
real_dir() {
  local d="$1" parent leaf home services own nl checkout
  nl='
'
  case "$d" in *"$nl"*|*:*) return 1 ;; esac
  case "/$d/" in */./*|*/../*) return 1 ;; esac
  leaf="$(basename "$d")"
  case "$leaf" in ''|.|..) return 1 ;; esac
  [ ! -L "$d" ] || return 1
  parent="$(cd "$(dirname "$d")" && pwd -P)" || return 1
  case "$parent" in *"$nl"*|*:*) return 1 ;; esac
  home="$(cd "$HOME" && pwd -P)" || return 1
  services="$(cd "$HOME/services" && pwd -P)" || return 1
  case "$services" in "$home"/?*) ;; *) return 1 ;; esac
  [ ! -L "$HOME/services/$NAME" ] || return 1
  own="$services/$NAME"
  case "$parent/$leaf" in "$own"|"$own"/*) ;; *) return 1 ;; esac
  # Never a directory that holds this checkout (and so every other
  # service's .env): a repo cloned inside ~/services/ntfy-control must
  # survive a purge.
  checkout="$(cd "$SERVICE_DIR" && pwd -P)" || return 1
  case "$checkout/" in "$parent/$leaf"/*) return 1 ;; esac
  printf '%s/%s' "$parent" "$leaf"
}

env_lint
SERVICE_HOME="$(env_get SERVICE_HOME)"
SERVICE_HOME="${SERVICE_HOME:-$HOME/services/$NAME}"

# No reachable user manager (a bare SSH shell with no user bus) means
# nothing can be verified: stop/disable would fail silently, and a unit
# whose file was deleted could still be loaded with the listener running
# while teardown reports removal.
if [ "$OS" = "Linux" ] && ! systemctl --user list-units >/dev/null 2>&1; then
  die "The user systemd manager is unreachable (over SSH: export DBUS_SESSION_BUS_ADDRESS=/run/user/$(id -u)/bus). Nothing was changed."
fi

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
if [ "$PURGE" -eq 1 ]; then
  warn "--purge deletes $SERVICE_HOME (the installed listener copies),"
  warn "  $ENV_FILE (the credential copy — the source of truth is"
  warn "  monitoring/.env and stays), the unit file, and the listener log."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""; read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------- disable (and purge)
if [ "$OS" = "Linux" ]; then
  unit_file=0
  { [ -f "$UNIT" ] || [ -L "$UNIT" ]; } && unit_file=1
  # A deleted unit file does not unload the service systemd already
  # loaded — check the manager too, or a fileless listener would survive
  # teardown (and a purge) still answering phone commands.
  unit_loaded=0
  systemctl --user cat "$UNIT_NAME" >/dev/null 2>&1 && unit_loaded=1
  if [ "$unit_file" -eq 1 ] || [ "$unit_loaded" -eq 1 ]; then
    info "Stopping and disabling $UNIT_NAME"
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    # A failed stop must not read as removed: verify the unit is actually
    # inactive before disabling or purging anything.
    if [ "$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)" = "active" ]; then
      die "$UNIT_NAME did not stop — check 'systemctl --user status $UNIT_NAME' and re-run."
    fi
    if [ "$unit_file" -eq 1 ]; then
      systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 \
        || die "systemctl --user disable $UNIT_NAME failed. Try it by hand and re-run."
      ok "$UNIT_NAME stopped and disabled"
    else
      # No file means it cannot be enabled — stopping it is enough.
      ok "$UNIT_NAME stopped (the unit file was already gone)"
    fi
    if [ "$PURGE" -eq 1 ]; then
      if [ -f "$UNIT" ] || [ -L "$UNIT" ]; then
        rm -f -- "$UNIT"
        ok "Deleted $UNIT"
      fi
      systemctl --user daemon-reload \
        || die "systemctl --user daemon-reload failed. Run it by hand."
      systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
      ok "systemd user daemon reloaded"
    fi
  else
    ok "No $UNIT (already removed)"
  fi
else
  domain="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$domain" >/dev/null 2>&1; then
    launchctl bootout "$domain" || die "launchctl bootout $domain failed. Try it by hand."
    ok "LaunchAgent $PLIST_LABEL booted out"
  else
    ok "LaunchAgent $PLIST_LABEL was not loaded"
  fi
  # launchd loads every plist in ~/Library/LaunchAgents at login, so a
  # kept plist would bring the listener back. setup.sh rewrites it on
  # every run, so removing it loses nothing.
  if [ -f "$PLIST" ] || [ -L "$PLIST" ]; then
    rm -f -- "$PLIST"
    ok "Deleted $PLIST (setup.sh rewrites it)"
  else
    ok "No $PLIST (already removed)"
  fi
fi

if [ "$PURGE" -eq 1 ]; then
  if [ -e "$SERVICE_HOME" ] || [ -L "$SERVICE_HOME" ]; then
    resolved="$(real_dir "$SERVICE_HOME")" \
      || die "$SERVICE_HOME is not a real directory inside $HOME/services/$NAME — refusing to delete it."
    rm -rf -- "$resolved"
    ok "Deleted $resolved"
    # SERVICE_HOME may be a child (a moved install root); the marker
    # parent stays behind. Drop it only when it is empty.
    rmdir "$HOME/services/$NAME" 2>/dev/null || true
  else
    ok "No $SERVICE_HOME (already gone)"
  fi
  if [ -f "$LISTENER_LOG" ] || [ -L "$LISTENER_LOG" ]; then
    rm -f -- "$LISTENER_LOG"
    ok "Deleted $LISTENER_LOG"
  fi
  rm -f -- "$ENV_FILE"
  ok "Deleted $ENV_FILE"
fi

# ------------------------------------------------------------- summary
echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed along with its state and .env.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. %s and .env are kept; ./setup.sh brings it back.\n' "$NAME" "$SERVICE_HOME"
  echo "  Also delete the state dir and .env: ./teardown.sh --purge"
fi
echo "  Phone control is down until it is re-deployed (monitoring and the"
echo "  launcher are unaffected)."
