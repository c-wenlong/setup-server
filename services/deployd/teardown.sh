#!/usr/bin/env bash
#
# teardown.sh — take deployd off this box. Linux + macOS.
#
# The inverse of setup.sh's run, and nothing more:
#   1. stop the poller so it does not come back at boot or login:
#        Linux: systemctl --user disable --now deployd.timer, then stop
#               deployd.service if it is mid-tick
#        macOS: launchctl bootout + disable (setup.sh enables before it
#               bootstraps, so a disabled plist left on disk stays dead)
#   2. keep .env, the unit/plist files and ~/services/deployd (state + deploy
#      logs), so ./setup.sh brings deployd back as it was
#
# A poll holding ~/services/deployd/.poll.lock is mid-run, possibly inside
# another service's setup.sh. Killing it there could leave that service
# half-configured, so teardown refuses while the lock is fresh and clears it
# only when it is stale (over 60 min — the same rule deployd uses).
#
# Never touched, by either mode: the setup-server checkout, other services'
# units, timers and deploys, lingering.
#
# Usage:
#   ./teardown.sh            # safe remove: .env, units and state kept
#   ./teardown.sh --purge    # ALSO delete ~/services/deployd and .env;
#                            # asks you to type "deployd" first
#
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="deployd"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
SERVICE_HOME="$HOME/services/$NAME"
UNIT_DIR="$HOME/.config/systemd/user"
TIMER_UNIT="deployd.timer"
SERVICE_UNIT="deployd.service"
PLIST_LABEL="com.setup-server.deployd"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"
LOCK="$SERVICE_HOME/.poll.lock"

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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (the poller is a systemd user timer)."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS (the poller is a LaunchAgent)."
fi

# ---------------------------------------------------------------- poller
# The timer goes first so no new tick can start; then the lock — a held,
# fresh lock means a poll is inside a deploy right now and teardown waits
# for the operator rather than killing it.
if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/$TIMER_UNIT" ]; then
    systemctl --user disable --now "$TIMER_UNIT" >/dev/null 2>&1 \
      || die "Could not disable $TIMER_UNIT (is the user systemd instance reachable?). Nothing was changed."
    ok "$TIMER_UNIT disabled and stopped"
  else
    ok "$TIMER_UNIT not installed (already gone)"
  fi
else
  target="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$target" >/dev/null 2>&1 \
     && ! launchctl bootout "$target" >/dev/null 2>&1; then
    for i in 1 2 3; do
      launchctl print "$target" >/dev/null 2>&1 || break
      [ "$i" -lt 3 ] || die "Could not unload LaunchAgent $PLIST_LABEL (launchctl bootout $target failed and it is still loaded; check: launchctl print $target). Nothing was changed; fix that and re-run."
      sleep 1
    done
  fi
  launchctl disable "$target" >/dev/null 2>&1 \
    || die "Could not disable LaunchAgent $PLIST_LABEL (launchctl disable $target), so it would load again at the next login. Nothing was changed; fix that and re-run."
  ok "LaunchAgent $PLIST_LABEL unloaded and disabled"
fi

if [ -d "$LOCK" ]; then
  [ -L "$LOCK" ] && die "$LOCK is a symlink, not the lock deployd makes — refusing."
  if [ -z "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    die "A poll is mid-run (it holds $LOCK) and may be inside another service's deploy — re-run once it finishes. The timer is already off, so nothing new will start."
  fi
  rmdir "$LOCK" 2>/dev/null \
    || die "$LOCK is over 60 min old but not empty — look inside, remove it by hand, then re-run."
  ok "Cleared a stale poll lock (over 60 min old)"
fi

if [ "$OS" = "Linux" ] && [ -f "$UNIT_DIR/$SERVICE_UNIT" ]; then
  systemctl --user stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  warn "--purge deletes $SERVICE_HOME (installed poller, sha state, deploy"
  warn "logs), the unit/plist files and $ENV_FILE. The setup-server checkout"
  warn "is kept. This cannot be undone."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
  info "Purging"
  rm -rf "$SERVICE_HOME"
  rm -f "$UNIT_DIR/$TIMER_UNIT" "$UNIT_DIR/$SERVICE_UNIT" "$PLIST" "$ENV_FILE"
  if [ "$OS" = "Linux" ]; then systemctl --user daemon-reload; fi
  ok "Purged"
else
  echo "Kept: $ENV_FILE, the unit files and $SERVICE_HOME (state + deploy logs)."
  echo "      ./setup.sh brings deployd back as it was; --purge removes them."
fi

echo
printf '\033[1;32mDone.\033[0m deployd will not poll again until setup.sh runs.\n'
