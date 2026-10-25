#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of code-server behind Tailscale (Linux + macOS).
#
# End state:
#   - code-server installed standalone in ~/.local (no root)
#   - listens on 127.0.0.1:PORT only, auth: none (tailnet is the auth layer)
#   - kept alive + started at boot/login:
#       Linux: systemd --user unit + lingering
#       macOS: launchd LaunchAgent (starts at login)
#   - published tailnet-only at https://<host>.<tailnet>.ts.net via Tailscale Serve
#
# Usage:
#   ./setup.sh            # deploy with defaults
#   PORT=9000 ./setup.sh  # custom local port
#
# Requirements: Linux (systemd) or macOS, curl, and Tailscale installed + logged in.
# Sudo is needed at most twice on Linux (lingering, tailscale operator), never on macOS.
#
# Idempotent: safe to re-run. Re-running upgrades code-server and repairs
# any missing piece; an existing config.yaml is left untouched.

set -euo pipefail

PORT="${PORT:-8080}"
CONFIG="$HOME/.config/code-server/config.yaml"
OS="$(uname -s)"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root (sudo is invoked only where needed)."
command -v curl >/dev/null || die "curl is required."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

# Tailscale CLI: on PATH, or inside the macOS app bundle.
if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed. Install it first: https://tailscale.com/download"
fi

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"
ok "$OS + curl + Tailscale (running)"

# ---------------------------------------------------- install / upgrade
info "Installing code-server (standalone, ~/.local)"
curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone
ok "code-server: $("$HOME/.local/bin/code-server" --version | head -1)"

# ---------------------------------------------------------------- config
if [ -f "$CONFIG" ]; then
  ok "Config already exists, leaving untouched: $CONFIG"
else
  info "Writing config (localhost-only, no password — tailnet is the auth layer)"
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<EOF
bind-addr: 127.0.0.1:$PORT
auth: none
cert: false
EOF
  ok "Wrote $CONFIG"
fi

# ------------------------------------------------------------ service
if [ "$OS" = "Linux" ]; then
  UNIT="$HOME/.config/systemd/user/code-server.service"
  info "Installing systemd user service"
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<'EOF'
[Unit]
Description=code-server (VS Code in the browser)
After=network.target

[Service]
Type=exec
ExecStart=%h/.local/bin/code-server
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable code-server >/dev/null 2>&1
  systemctl --user restart code-server
  ok "Service enabled and (re)started"
else
  PLIST="$HOME/Library/LaunchAgents/com.coder.code-server.plist"
  info "Installing launchd LaunchAgent"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.coder.code-server</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/bin/code-server</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/code-server.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/code-server.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.coder.code-server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (starts at login; logs: ~/Library/Logs/code-server.log)"
fi

info "Waiting for local health check on 127.0.0.1:$PORT"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
    ok "code-server is healthy locally"
    break
  fi
  if [ "$i" -eq 15 ]; then
    [ "$OS" = "Linux" ] && die "code-server did not become healthy. Logs: journalctl --user -u code-server"
    die "code-server did not become healthy. Logs: ~/Library/Logs/code-server.log"
  fi
  sleep 1
done

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

# ------------------------------------------------------- tailscale serve
if ! "$TAILSCALE" serve --bg "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
  if [ "$OS" = "Linux" ]; then
    info "Granting Tailscale operator rights to $USER (needs sudo, one time)"
    sudo tailscale set --operator="$USER"
  fi
  until "$TAILSCALE" serve --bg "http://127.0.0.1:$PORT"; do
    echo
    info "Tailscale Serve needs one-time enablement — open the URL above, approve, then press Enter to retry."
    read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
  done
fi
ok "Tailscale Serve: HTTPS :443 -> http://127.0.0.1:$PORT (tailnet only)"

# ------------------------------------------------------------ final check
host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
url="https://$host"

info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/healthz"; then
  ok "End-to-end check passed"
else
  echo "    Cert may still be minting — try again in a minute: curl $url/healthz"
fi

echo
printf '\033[1;32mDone.\033[0m Open \033[1m%s\033[0m from any device on your tailnet.\n' "$url"
echo
echo "Manage it with:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart code-server"
  echo "  journalctl --user -u code-server -f"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/com.coder.code-server   # restart"
  echo "  tail -f ~/Library/Logs/code-server.log"
fi
echo "  tailscale serve status        # or: tailscale serve --https=443 off"
