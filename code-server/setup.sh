#!/usr/bin/env bash
#
# deploy-code-server.sh — one-shot deploy of code-server behind Tailscale.
#
# End state:
#   - code-server installed standalone in ~/.local (no root)
#   - listens on 127.0.0.1:PORT only, auth: none (tailnet is the auth layer)
#   - systemd --user service, boot-persistent via lingering
#   - published tailnet-only at https://<host>.<tailnet>.ts.net via Tailscale Serve
#
# Usage:
#   ./deploy-code-server.sh            # deploy with defaults
#   PORT=9000 ./deploy-code-server.sh  # custom local port
#
# Requirements: Linux with systemd, curl, and Tailscale installed + logged in.
# Sudo is needed at most twice (lingering, tailscale operator), then never again.
#
# Idempotent: safe to re-run. Re-running upgrades code-server and repairs
# any missing piece; an existing config.yaml is left untouched.

set -euo pipefail

PORT="${PORT:-8080}"
CONFIG="$HOME/.config/code-server/config.yaml"
UNIT="$HOME/.config/systemd/user/code-server.service"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
info "Preflight checks"
[ "$(uname -s)" = "Linux" ] || die "This script targets Linux."
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root (sudo is invoked only where needed)."
command -v curl >/dev/null || die "curl is required."
command -v systemctl >/dev/null || die "systemd is required."
command -v tailscale >/dev/null || die "Tailscale is not installed. Install it first: https://tailscale.com/download"

state="$(tailscale status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up"
ok "Linux + systemd + curl + Tailscale (running)"

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

# --------------------------------------------------------- systemd service
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

info "Waiting for local health check on 127.0.0.1:$PORT"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
    ok "code-server is healthy locally"
    break
  fi
  [ "$i" -eq 15 ] && die "code-server did not become healthy. Logs: journalctl --user -u code-server"
  sleep 1
done

# ------------------------------------------------------------- lingering
# Lingering makes user services start at boot and survive logout.
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
  ok "Lingering already enabled"
else
  info "Enabling lingering (needs sudo, one time)"
  sudo loginctl enable-linger "$USER"
  ok "Lingering enabled — service now starts at boot"
fi

# ------------------------------------------------------- tailscale serve
# Let this user manage Tailscale without root, then publish.
if ! tailscale serve --bg "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
  info "Granting Tailscale operator rights to $USER (needs sudo, one time)"
  sudo tailscale set --operator="$USER"

  # Retry; if Serve isn't enabled on the tailnet yet, tailscale prints an
  # approval URL — surface it and wait for the user to click it.
  until tailscale serve --bg "http://127.0.0.1:$PORT"; do
    echo
    info "Tailscale Serve needs one-time enablement — open the URL above, approve, then press Enter to retry."
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :443 -> http://127.0.0.1:$PORT (tailnet only)"

# ------------------------------------------------------------ final check
host="$(tailscale status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
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
echo "  systemctl --user status|restart code-server"
echo "  journalctl --user -u code-server -f"
echo "  tailscale serve status        # or: tailscale serve --https=443 off"
