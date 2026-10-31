#!/usr/bin/env bash
#
# teardown.sh — take ollama's user service off this box. Linux + macOS.
#
# The inverse of setup.sh, and nothing more:
#   1. stop + disable the systemd user unit (macOS: bootout the LaunchAgent
#      and drop its plist, because launchd would reload it at next login)
#   2. keep the binary and ~/.ollama (the models — the real disk weight),
#      so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: binary + models kept
#   ./teardown.sh --purge    # ALSO delete ~/.ollama (models) and the unit
#                            # file; asks you to type "ollama" first, and
#                            # prints the exact rm for the binary. Terminal
#                            # only: the launcher's Remove never passes it.
#
# The retired stock system unit under /etc/systemd/system is never touched
# either way — re-enabling it would re-open the old *:11434 LAN bind, and
# removing system files is the administrator's call, not this script's.
#
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="ollama"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_NAME="ollama.service"
UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
PLIST_LABEL="ai.ollama.serve"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
MODELS="$HOME/.ollama"

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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
fi

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. ~/.ollama is a fixed literal path —
# the guard is a symlink check, never a computed one.
PURGE_MODELS=0
if [ "$PURGE" -eq 1 ]; then
  if [ -L "$MODELS" ]; then
    warn "$MODELS is a symlink — it will be left alone."
  elif [ -d "$MODELS" ]; then
    PURGE_MODELS=1
  fi
  warn "--purge deletes $MODELS (pulled models) and the unit file. The binary stays; its rm prints at the end."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------- disable (and purge)
if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Disabling $UNIT_NAME"
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 \
      || die "systemctl --user disable $UNIT_NAME failed. Try it by hand and re-run."
    ok "$UNIT_NAME stopped and disabled"
  else
    ok "No $UNIT (already removed)"
  fi
  if [ "$PURGE" -eq 1 ]; then
    rm -f -- "$UNIT"
    ok "Deleted $UNIT"
    systemctl --user daemon-reload \
      || die "systemctl --user daemon-reload failed. Run it by hand."
    ok "systemd user daemon reloaded"
  fi
else
  domain="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$domain" >/dev/null 2>&1; then
    launchctl bootout "$domain" || die "launchctl bootout $domain failed. Try it by hand."
    ok "LaunchAgent $PLIST_LABEL booted out"
  else
    ok "LaunchAgent $PLIST_LABEL was not loaded"
  fi
  # launchd loads every plist in ~/Library/LaunchAgents at login, so a kept
  # plist would bring ollama back. setup.sh rewrites it on every run, so
  # removing it loses nothing.
  if [ -f "$PLIST" ] || [ -L "$PLIST" ]; then
    rm -f -- "$PLIST"
    ok "Deleted $PLIST (setup.sh rewrites it)"
  else
    ok "No $PLIST (already removed)"
  fi
fi

if [ "$PURGE_MODELS" -eq 1 ]; then
  rm -rf -- "$MODELS"
  ok "Deleted $MODELS (pulled models)"
fi

# ------------------------------------------------------------- summary
echo
if [ "$PURGE" -eq 1 ]; then
  echo "Kept, because deleting a binary you may not have installed here is"
  echo "the administrator's call:"
  kept=0
  for p in "$HOME/.local/bin/ollama" /usr/local/bin/ollama \
           "$HOME/.local/lib/ollama" "$HOME/Library/Logs/ollama.log"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    printf '  rm -rf %q\n' "$p"
    kept=$((kept + 1))
  done
  [ "$kept" -gt 0 ] || echo "  (nothing left)"
  echo "  A retired stock unit still lives at /etc/systemd/system/ollama.service*;"
  echo "  'sudo rm' it by hand only if you never want it back."
  printf '\033[1;32mDone.\033[0m %s is removed along with its models and unit file.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Binary and %s are kept; ./setup.sh brings it back.\n' "$NAME" "$MODELS"
  echo "  Also delete the models and the unit file: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."

exit 0
