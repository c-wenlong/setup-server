#!/usr/bin/env bash
#
# setup.sh — run ollama as a *user* service on loopback only (Linux + macOS).
#
# End state:
#   - an `ollama` binary: an existing one is reused, otherwise the official
#     tarball lands in ~/.local (macOS: the Homebrew formula)
#   - serving on 127.0.0.1:PORT only — nothing on Tailscale Serve: other
#     services on this box call it directly, and it is a backend, not a UI
#   - kept alive + started at boot/login:
#       Linux: systemd --user unit + lingering
#       macOS: launchd LaunchAgent (starts at login)
#   - a stock SYSTEM unit (what the official install script leaves — it runs
#     as user `ollama`, and may carry an override binding OLLAMA_HOST=0.0.0.0
#     which is LAN-wide on *:11434) is stopped + disabled; needs sudo once
#
# Why a user unit: the launcher's start/stop/restart buttons work through
# systemctl --user, which has no sudo path — a system unit could never be
# controlled that way. Retiring the stock unit also drops the 0.0.0.0 bind:
# the user unit is loopback-only by construction.
#
# Usage:
#   ./setup.sh                    # deploy with defaults
#   OLLAMA_PORT=11435 ./setup.sh  # custom local port
#
# Idempotent: safe to re-run. Repairs the binary/unit and restarts the
# service, but never re-invokes sudo once the system unit is disabled, and
# never touches ~/.ollama (models are the user's, pulled by hand).
#
# Sudo: at most once, to retire a live stock system unit. Fresh installs
# and re-runs need none.

set -euo pipefail

PORT="${OLLAMA_PORT:-11434}"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS="$HOME/.ollama"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root "Run as a regular user, not root (sudo is invoked only to retire a system unit)."
command -v curl >/dev/null || die "curl is required."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }
case "$PORT" in ''|*[!0-9]*) die "OLLAMA_PORT must be a port number (got: $PORT)" ;; esac
ok "$OS + curl + user service manager"

# ------------------------------------------------- install / reuse binary
# Order: a binary we installed before, then whatever PATH finds — a stock
# /usr/local/bin/ollama is reused as-is (upgrading it is the system
# package's business, not ours). PATH, not a filesystem probe, so the
# mocked suite controls the answer like everything else.
OLLAMA_BIN=""
if [ -x "$HOME/.local/bin/ollama" ]; then
  OLLAMA_BIN="$HOME/.local/bin/ollama"
elif command -v ollama >/dev/null 2>&1; then
  OLLAMA_BIN="$(command -v ollama)"
fi

if [ -n "$OLLAMA_BIN" ]; then
  ok "Reusing existing ollama binary: $OLLAMA_BIN"
elif [ "$OS" = "Linux" ]; then
  info "Installing ollama to ~/.local (official tarball)"
  case "$(uname -m)" in
    x86_64|amd64)   OLLAMA_ARCH=amd64 ;;
    aarch64|arm64)  OLLAMA_ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://ollama.com/download/ollama-linux-$OLLAMA_ARCH.tgz" \
    -o "$tmp/ollama.tgz"
  mkdir -p "$HOME/.local"
  tar -xzf "$tmp/ollama.tgz" -C "$HOME/.local"
  rm -rf "$tmp"
  trap - EXIT
  OLLAMA_BIN="$HOME/.local/bin/ollama"
  [ -x "$OLLAMA_BIN" ] || die "The tarball did not produce $OLLAMA_BIN."
  ok "Installed $OLLAMA_BIN"
else
  # macOS has no standalone tarball — the .app or the Homebrew formula.
  if command -v brew >/dev/null 2>&1; then
    info "Installing ollama via Homebrew"
    brew install ollama
    OLLAMA_BIN="$(brew --prefix)/bin/ollama"
    [ -x "$OLLAMA_BIN" ] || die "brew installed ollama but $OLLAMA_BIN is not executable."
  else
    die "No ollama binary and no Homebrew. Install Ollama.app or \`brew install ollama\`, then re-run."
  fi
fi

# ------------------------------------------------ retire the stock unit
# The official install script leaves a SYSTEM unit,
# /etc/systemd/system/ollama.service, running `ollama serve` as user
# `ollama` — and on this box a drop-in that bound OLLAMA_HOST=0.0.0.0
# (*:11434, LAN-reachable). It must go down before the user unit takes the
# port, and stay down so a stray enable cannot re-open the LAN bind or
# fight us for the port. `systemctl cat` finds the unit file whether or
# not it is enabled; sudo runs only while it is still live (enabled or
# active), which keeps re-runs sudo-free.
if [ "$OS" = "Linux" ] && systemctl cat ollama.service >/dev/null 2>&1; then
  if systemctl is-enabled ollama.service >/dev/null 2>&1 \
     || systemctl is-active ollama.service >/dev/null 2>&1; then
    info "Retiring the stock system unit (needs sudo, one time)"
    sudo systemctl disable --now ollama.service
    ok "System ollama.service stopped and disabled — its *:11434 bind is gone"
  else
    ok "Stock system unit already disabled"
  fi
  # The old unit's models belonged to user `ollama`, not us — and can be
  # gigabytes. Never copy automatically; name the path and the choice.
  if [ -d /usr/share/ollama/.ollama ] \
     && [ -n "$(ls -A /usr/share/ollama/.ollama 2>/dev/null || true)" ]; then
    warn "Models under the old system unit still sit in /usr/share/ollama/.ollama"
    warn "(owned by the 'ollama' user). Re-pull with '$OLLAMA_BIN pull <model>'"
    warn "as yourself, or copy them with sudo — they are not migrated."
  fi
fi

# ------------------------------------------------------------ service
mkdir -p "$MODELS"
if [ "$OS" = "Linux" ]; then
  UNIT="$HOME/.config/systemd/user/ollama.service"
  info "Installing systemd user service (loopback only)"
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOF
[Unit]
Description=ollama (local model runtime, user service)
After=network-online.target

[Service]
Type=exec
ExecStart=$OLLAMA_BIN serve
Environment=OLLAMA_HOST=127.0.0.1:$PORT
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable ollama >/dev/null 2>&1
  systemctl --user restart ollama
  ok "Service enabled and (re)started"
else
  PLIST="$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  info "Installing launchd LaunchAgent (loopback only)"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.ollama.serve</string>
  <key>ProgramArguments</key>
  <array><string>$OLLAMA_BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>OLLAMA_HOST</key><string>127.0.0.1:$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/ollama.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ollama.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/ai.ollama.serve" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (starts at login; logs: ~/Library/Logs/ollama.log)"
fi

info "Waiting for local health check on 127.0.0.1:$PORT"
if wait_http "http://127.0.0.1:$PORT/api/version" 15 1; then
  ok "ollama is healthy locally"
else
  [ "$OS" = "Linux" ] && die "ollama did not become healthy. Logs: journalctl --user -u ollama"
  die "ollama did not become healthy. Logs: ~/Library/Logs/ollama.log"
fi

# ------------------------------------------------------------- lingering
# Linux only: makes user services start at boot and survive logout.
# macOS LaunchAgents start at login; running before login would need a
# root LaunchDaemon — out of scope for a user-local install.
if [ "$OS" = "Linux" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time)"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled — service now starts at boot"
  fi
fi

# ------------------------------------------------------------ summary
echo
printf '\033[1;32mDone.\033[0m ollama serves on \033[1m127.0.0.1:%s\033[0m for this box only — it is deliberately not on Tailscale Serve.\n' "$PORT"
echo
echo "Manage it with:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart ollama"
  echo "  journalctl --user -u ollama -f"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/ai.ollama.serve   # restart"
  echo "  tail -f ~/Library/Logs/ollama.log"
fi
echo "  $OLLAMA_BIN pull <model>      # models land in $MODELS/models"
