#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of launcher, the app launcher for this box.
# Linux + macOS.
#
# End state:
#   - server.py (Python 3 stdlib only, no pip, no venv) running as a systemd
#     user unit on Linux / a launchd LaunchAgent on macOS, Restart=always
#   - bound to 127.0.0.1:LAUNCHER_PORT only — never a LAN interface
#   - lingering enabled on Linux, so it survives a reboot with nobody logged in
#   - published tailnet-only, TWICE, both proxying the same backend:
#       https://<host>:HTTPS_PORT/    — its own port, like every other service
#       https://<host>/home/          — a path handler on :443, the short URL
#     you actually bookmark, living alongside code-server which keeps "/"
#
# Usage:
#   ./setup.sh                        # local 8093, HTTPS 8093, short path /home
#   LAUNCHER_PORT=8093 HTTPS_PORT=8093 SHORT_PATH=/home ./setup.sh
#   SHORT_PATH= ./setup.sh            # skip the :443 path handler entirely
#
# The :443 path handler is additive: `tailscale serve --set-path=/home` adds a
# mount point next to whatever already serves "/" on that port (code-server
# here) and leaves it alone. Verified — but it is also why this script never
# touches ":443 /" itself.
#
# Requirements: Linux or macOS, python3 >= 3.9, curl, Tailscale logged in.
# No Docker, no pip. That is the point: this is the page you load when
# something else on the box is broken, so it must have no moving parts.
#
# Idempotent: safe to re-run. The unit/plist is regenerated every time (so
# edits to this script are picked up), the service is restarted rather than
# merely started, and `tailscale serve` is declarative — re-publishing the
# same mapping is a no-op, not a duplicate.

set -euo pipefail

PORT="${LAUNCHER_PORT:-8093}"
HTTPS_PORT="${HTTPS_PORT:-8093}"
# `-` not `:-` on purpose: SHORT_PATH="" is a meaningful value (disable the
# :443 handler), only an *unset* SHORT_PATH gets the default.
SHORT_PATH="${SHORT_PATH-/home}"
SHORT_HTTPS_PORT=443

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
STATE="$HOME/services/launcher"
UNIT_NAME="launcher.service"
UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
PLIST_LABEL="com.launcher.server"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root "Run as a regular user, not root. The unit is a *user* unit and the deploy API must run as you."

command -v curl >/dev/null || die "curl is required (health checks)."
command -v python3 >/dev/null || die "python3 is required — launcher is a stdlib-only Python 3 server."
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null \
  || die "python3 >= 3.9 is required (got: $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || echo unknown))."

if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (launcher runs as a systemd user unit)."
  command -v loginctl >/dev/null  || die "loginctl is required on Linux (lingering, for boot persistence)."
fi

resolve_tailscale
require_tailscale_up

case "$PORT" in ''|*[!0-9]*) die "LAUNCHER_PORT must be numeric (got: $PORT)";; esac
require_numeric HTTPS_PORT
case "$SHORT_PATH" in
  ''|/*) ;;
  *) die "SHORT_PATH must start with '/' (got: $SHORT_PATH). Use SHORT_PATH= to disable the :$SHORT_HTTPS_PORT handler.";;
esac

# The app itself. These are the failures worth being loud about: a missing or
# broken server.py means the unit would start, crash, and restart forever.
[ -f "$SERVICE_DIR/server.py" ] \
  || die "Missing $SERVICE_DIR/server.py — the launcher backend. Is this a partial checkout? Run: git -C $REPO_ROOT status"
[ -f "$SERVICE_DIR/services.json" ] \
  || die "Missing $SERVICE_DIR/services.json — the service registry. Is this a partial checkout? Run: git -C $REPO_ROOT status"
[ -d "$SERVICE_DIR/static" ] \
  || die "Missing $SERVICE_DIR/static/ — the static frontend. Is this a partial checkout? Run: git -C $REPO_ROOT status"
[ -f "$SERVICE_DIR/static/index.html" ] \
  || warn "No $SERVICE_DIR/static/index.html — the API will work but the page will 404."

# Syntax-check the backend before installing a unit that would crash-loop on
# it. Compiled from a scratch copy so the repo never grows a __pycache__.
cp "$SERVICE_DIR/server.py" "$WORK/server.py"
if ! ( cd "$WORK" && python3 -m py_compile server.py ) 2>"$WORK/pycompile.err"; then
  echo "----- python3 -m py_compile server.py -----" >&2
  cat "$WORK/pycompile.err" >&2
  die "$SERVICE_DIR/server.py does not compile (see above). Refusing to install a unit that would crash-loop."
fi

python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$SERVICE_DIR/services.json" 2>/dev/null \
  || die "$SERVICE_DIR/services.json is not valid JSON. Fix it and re-run — the registry is the deploy allowlist, so a broken one is a hard stop."

ok "$OS + python3 $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))') + curl + Tailscale (running); server.py compiles, services.json parses"

# ------------------------------------------------------------------ state
# Job logs live here, and the directory doubles as launcher's own "installed"
# marker in the registry.
mkdir -p "$STATE/jobs"
ok "State directory: $STATE"

# ---------------------------------------------------------------- service
# Nothing is copied out of the repo: the deploy API runs setup scripts from
# REPO_ROOT, so the repo *is* the install. `git pull && ./setup.sh` upgrades.
if [ "$OS" = "Linux" ]; then
  info "Installing systemd user unit ($UNIT_NAME)"
  mkdir -p "$(dirname "$UNIT")"
  # Regenerated on every run — this file is generated, never hand-edited.
  # PATH is spelled out because a user unit inherits a minimal one, and the
  # setup scripts this service executes need docker/curl/tailscale/uv.
  cat > "$UNIT" <<EOF
[Unit]
Description=launcher — app launcher and deploy console for this box
After=network.target

[Service]
Type=exec
WorkingDirectory=$SERVICE_DIR
ExecStart=/usr/bin/env python3 $SERVICE_DIR/server.py
Environment=LAUNCHER_PORT=$PORT
Environment=REPO_ROOT=$REPO_ROOT
Environment=PYTHONUNBUFFERED=1
Environment=PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl --user restart "$UNIT_NAME"   # restart, not start: pick up unit edits
  ok "Unit installed, enabled and (re)started"

  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled (survives reboot with nobody logged in)"
  else
    info "Enabling lingering so launcher starts at boot (needs sudo, one time)"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled"
  fi
else
  info "Installing launchd LaunchAgent ($PLIST_LABEL)"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string><string>python3</string><string>$SERVICE_DIR/server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$SERVICE_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LAUNCHER_PORT</key><string>$PORT</string>
    <key>REPO_ROOT</key><string>$REPO_ROOT</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/launcher.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/launcher.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (logs: ~/Library/Logs/launcher.log)"
fi

# ------------------------------------------------------------ local health
if [ "$OS" = "Linux" ]; then
  LOGCMD="journalctl --user -u $UNIT_NAME -n 50 --no-pager"
else
  LOGCMD="tail -n 50 ~/Library/Logs/launcher.log"
fi

info "Waiting for launcher on http://127.0.0.1:$PORT/healthz"
wait_http "http://127.0.0.1:$PORT/healthz" 40 1 || die "launcher did not answer on http://127.0.0.1:$PORT/healthz. Logs: $LOGCMD"
ok "launcher is answering locally"

# ------------------------------------------------------- tailscale serve
# Published twice, both proxying the same backend. Every serve invocation goes
# through this so both get the operator-grant and approval-link fallbacks.
ts_serve() {  # ts_serve <tailscale serve args...>
  if "$TAILSCALE" serve "$@" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$OS" = "Linux" ]; then
    info "Direct serve failed — trying operator grant (needs sudo, one time)"
    sudo tailscale set --operator="$USER"
  fi
  until "$TAILSCALE" serve "$@"; do
    echo
    info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
    read -r
  done
}

info "Publishing via Tailscale Serve (tailnet only)"
ts_serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$PORT"
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$PORT"

if [ -n "$SHORT_PATH" ]; then
  # Adds a mount point on :443 next to whatever already owns "/" there
  # (code-server). --set-path is additive and does not touch the "/" handler.
  # Tailscale STRIPS the prefix before proxying, so the backend sees "/" —
  # which is why the frontend must use relative URLs only.
  ts_serve --bg --https="$SHORT_HTTPS_PORT" --set-path="$SHORT_PATH" "http://127.0.0.1:$PORT"
  ok "Tailscale Serve: HTTPS :$SHORT_HTTPS_PORT$SHORT_PATH -> http://127.0.0.1:$PORT (alongside the existing / handler)"
else
  info "SHORT_PATH is empty — skipping the :$SHORT_HTTPS_PORT path handler"
fi

host="$(tailnet_host)"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

port_url="https://$host:$HTTPS_PORT/"
short_url=""
[ -n "$SHORT_PATH" ] && short_url="https://$host$SHORT_PATH/"
main_url="${short_url:-$port_url}"

# ------------------------------------------------------------ final check
info "Verifying over HTTPS (the first request on a new port can take ~60s while the cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "${port_url}healthz"; then
  ok "End-to-end check passed: $port_url"
else
  warn "$port_url did not answer yet — cert may still be minting. Retry: curl ${port_url}healthz"
fi

if [ -n "$short_url" ]; then
  if curl -fsS -o /dev/null --max-time 90 "${short_url}healthz"; then
    ok "End-to-end check passed: $short_url"
  else
    warn "$short_url did not answer yet — cert may still be minting. Retry: curl ${short_url}healthz"
  fi
fi

# ------------------------------------------------------------------ done
echo
if [ -n "$short_url" ]; then
  printf '\033[1;32mDone.\033[0m Bookmark this:\n\n    \033[1;36m%s\033[0m\n\n' "$short_url"
  echo "  Also reachable on its own port: $port_url"
else
  printf '\033[1;32mDone.\033[0m launcher is at \033[1;36m%s\033[0m\n' "$port_url"
fi
echo "  Tailnet only — the phone or laptop must have Tailscale connected."
echo
echo "iPhone Home Screen (this is the whole point — one tap, no typing):"
echo "  1. Open $main_url in Safari (Safari specifically, not Chrome)"
echo "  2. Tap the Share button (the square with the arrow)"
echo "  3. Scroll down, tap 'Add to Home Screen', name it e.g. 'home', tap Add"
echo "  The icon then opens the launcher full-screen, like an app."
echo
echo "Tiles that are dimmed with a ↓ are services that exist in the repo but"
echo "are not installed on this box — tapping one offers to run its setup.sh."
echo
if [ "$OS" = "Linux" ]; then
  echo "Manage:  systemctl --user status|restart|stop $UNIT_NAME"
  echo "Logs:    journalctl --user -u $UNIT_NAME -f"
else
  echo "Manage:  launchctl kickstart -k gui/$(id -u)/$PLIST_LABEL"
  echo "Logs:    tail -f ~/Library/Logs/launcher.log"
fi
echo "Publish: tailscale serve status"
echo "Update:  git -C $REPO_ROOT pull && $SERVICE_DIR/setup.sh"
echo "Tests:   $SERVICE_DIR/tests/run-tests.sh [--live]"
exit 0
