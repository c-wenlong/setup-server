#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of OpenMausBot (milind-soni/OpenMausBot, the
# open-source Grok Bot alternative) behind Tailscale. Linux + macOS.
#
# End state:
#   - `openmausbot` installed as a global npm package under a user-owned
#     prefix (no sudo; a system prefix like /usr or /opt/homebrew is replaced
#     by ~/.local via `npm config set prefix`)
#   - the server + its self-served web UI on 127.0.0.1:OMB_PORT only — the
#     server hard-binds loopback (upstream: "never expose that port
#     directly"), so there is nothing to configure for the bind
#   - kept alive + started at boot/login:
#       Linux: systemd --user unit + lingering
#       macOS: launchd LaunchAgent (starts at login)
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#     via Tailscale Serve — never --tunnel (Cloudflare/vendor account) or
#     --domain (opens 80/443)
#   - state in ~/services/openmausbot (OMB_DATA_DIR), config in .env here
#
# Usage:
#   ./setup.sh                    # deploy with defaults (8799 in and out)
#   OMB_PORT=9800 ./setup.sh      # custom local port (HTTPS follows it)
#   OMB_PORT=9800 HTTPS_PORT=443 ./setup.sh
#
# Requirements: Linux (systemd) or macOS, curl, Node.js >= 24, npm, and
# Tailscale installed + logged in. Sudo is needed at most twice on Linux
# (lingering, tailscale operator), never on macOS.
#
# After deploy: pair a browser with `openmausbot pair --label "MacBook"` and
# sign engine CLIs in as this user (`claude`, `codex login`, ...). Neither is
# scripted: a pairing code is a secret the terminal should show once, and the
# engines take your own credentials.
#
# Idempotent: safe to re-run. Re-running upgrades the npm package and repairs
# any missing piece; an existing .env is left untouched and is the source of
# truth for ports and paths.

set -euo pipefail

OMB_PORT="${OMB_PORT:-8799}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$OMB_PORT}"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

# A re-run finds node and the global bin dir where the first install recorded
# them in .env — an ssh-triggered run's PATH often misses a user-level node
# (nvm, ~/.local) or the prefix set below.
if [ -f "$ENV_FILE" ]; then
  for k in NODE_BIN NPM_BIN; do
    d="$(sed -n "s/^$k=\(.*\)\$/\1/p" "$ENV_FILE" | tail -1 | sed "s/^'//; s/'\$//; s/^\"//; s/\"\$//")"
    [ -n "$d" ] && [ -d "$d" ] && PATH="$d:$PATH"
  done
fi

# Compare dotted versions without GNU sort: node_at_least 24
node_at_least() {
  local have
  have="$(node --version 2>/dev/null | sed 's/^v//')"
  [ -n "$have" ] || return 1
  awk -v have="$have" -v want="$1" 'BEGIN{
    split(have, h, "."); split(want, w, ".");
    for (i = 1; i <= 3; i++) {
      hv = h[i] + 0; wv = w[i] + 0;
      if (hv > wv) exit 0;
      if (hv < wv) exit 1;
    }
    exit 0
  }'
}

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
command -v curl >/dev/null || die "curl is required."
command -v node >/dev/null || die "Node.js >= 24 is required (upstream engines field). Install node, then re-run."
node_at_least "24" \
  || die "Node.js >= 24 is required (found: $(node --version)). Upgrade node and re-run."
command -v npm >/dev/null || die "npm is required (it ships with Node.js)."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

resolve_tailscale
require_tailscale_up
require_numeric OMB_PORT HTTPS_PORT
ok "$OS + curl + node $(node --version) + npm + Tailscale (running)"

host="$(tailnet_host)"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------- npm user prefix
# `npm install -g` into a system prefix (/usr, /opt/homebrew) needs sudo,
# which would also root-own the package. Point the global prefix at ~/.local
# for this user when it is not already under $HOME — a one-line ~/.npmrc
# edit, the documented unprivileged-install path.
NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
case "$NPM_PREFIX" in
  "$HOME"/*) ;;
  *)
    info "npm global prefix is ${NPM_PREFIX:-unset} — moving it to $HOME/.local (user-owned, no sudo)"
    npm config set prefix "$HOME/.local" >/dev/null
    NPM_PREFIX="$HOME/.local"
    ;;
esac
NPM_BIN="$NPM_PREFIX/bin"
NODE_BIN="$(dirname "$(command -v node)")"

# ------------------------------------------------------- install / upgrade
info "Installing openmausbot (npm -g, user prefix $NPM_PREFIX)"
npm install -g openmausbot >/dev/null
OMB_BIN="$NPM_BIN/openmausbot"
[ -x "$OMB_BIN" ] || die "npm install -g openmausbot did not produce $OMB_BIN"
ok "openmausbot: $("$OMB_BIN" --version 2>/dev/null | head -1 || echo installed)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (ports, data dir, trust mode — mode 600)"
  ( umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600. Edit + re-run to apply.
# Read by the systemd unit (EnvironmentFile) and baked into the LaunchAgent.

# The one upstream port: web UI and API share it, loopback-bound by the
# server itself.
OMB_PORT=$OMB_PORT
HTTPS_PORT=$HTTPS_PORT

# Repo layout: state under ~/services, not upstream's default ~/.openmausbot.
OMB_DATA_DIR=$HOME/services/openmausbot/data

# Pairing links are printed with the public address. The webhook receiver is
# a separate loopback listener on OMB_PORT+1 (upstream default); it is not
# published, so OMB_WEBHOOK_PUBLIC_URL stays unset.
OMB_PUBLIC_URL=https://$host:$HTTPS_PORT

# Loopback trust governs local non-browser callers only — a browser never
# gets it on any trust level (upstream: "a browser never gets loopback
# trust"), so tailnet users still pair. owner is the documented default
# for a self-hosted single-user box; service is for shared hosted
# workspaces and would refuse the pair command from this machine.
OMB_LOOPBACK_TRUST=owner

# Deploy bookkeeping (not read by upstream).
SERVICE_HOME=$HOME/services/openmausbot
NODE_BIN=$NODE_BIN
NPM_BIN=$NPM_BIN
OMB_BIN=$OMB_BIN
EOF
  )
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and the
# toolchain, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$OMB_PORT"
REQUESTED_HTTPS="$HTTPS_PORT"
set -a; . "$ENV_FILE"; set +a
: "${OMB_PORT:?OMB_PORT missing from $ENV_FILE}"
: "${OMB_DATA_DIR:?OMB_DATA_DIR missing from $ENV_FILE}"
: "${OMB_PUBLIC_URL:?OMB_PUBLIC_URL missing from $ENV_FILE}"
: "${NODE_BIN:?NODE_BIN missing from $ENV_FILE}"
: "${NPM_BIN:?NPM_BIN missing from $ENV_FILE}"
: "${OMB_BIN:?OMB_BIN missing from $ENV_FILE}"
SERVICE_HOME="${SERVICE_HOME:-$HOME/services/openmausbot}"
require_numeric OMB_PORT HTTPS_PORT
# The package just installed to the CURRENT npm prefix; if .env was written
# against an older toolchain the unit would point at a binary that is gone.
[ -x "$OMB_BIN" ] || die "$OMB_BIN is not executable — .env was written for a different node/npm layout. Fix NODE_BIN/NPM_BIN/OMB_BIN in $ENV_FILE (or delete the file) and re-run."
if [ "$OMB_PORT" != "$REQUESTED_PORT" ]; then
  warn "OMB_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $OMB_PORT. Edit .env and re-run to move the port."
fi
if [ -n "$HTTPS_PORT_EXPLICIT" ] && [ "$HTTPS_PORT" != "$REQUESTED_HTTPS" ]; then
  warn "HTTPS_PORT=$REQUESTED_HTTPS ignored — the existing $ENV_FILE says $HTTPS_PORT. Edit .env and re-run to move the port."
fi

mkdir -p "$OMB_DATA_DIR"

# ------------------------------------------------------------ service
# `serve --no-pair`: the pairing link the bare `serve` prints at startup is a
# credential, and under a service manager it would sit in journald/the log
# file for the life of the box. Pairing is a deliberate `openmausbot pair`
# afterwards instead.
if [ "$OS" = "Linux" ]; then
  UNIT="$HOME/.config/systemd/user/openmausbot.service"
  info "Installing systemd user service"
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOF
# Generated by services/openmausbot/setup.sh — regenerated on every re-run,
# so edit $ENV_FILE and re-run instead of editing here.
[Unit]
Description=OpenMausBot (persistent AI bots + self-served web UI)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ENV_FILE
Environment=PATH=$NODE_BIN:$NPM_BIN:/usr/local/bin:/usr/bin:/bin
ExecStart=$OMB_BIN serve --no-pair
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  chmod 600 "$UNIT"   # names .env-derived paths
  systemctl --user daemon-reload
  systemctl --user enable openmausbot >/dev/null 2>&1
  systemctl --user restart openmausbot
  ok "Service enabled and (re)started"
else
  PLIST="$HOME/Library/LaunchAgents/com.openmausbot.server.plist"
  info "Installing launchd LaunchAgent"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/openmausbot/setup.sh — regenerated on every re-run,
     so edit $ENV_FILE and re-run instead of editing here. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.openmausbot.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>$OMB_BIN</string>
    <string>serve</string>
    <string>--no-pair</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$NODE_BIN:$NPM_BIN:/usr/local/bin:/usr/bin:/bin</string>
    <key>OMB_PORT</key><string>$OMB_PORT</string>
    <key>OMB_DATA_DIR</key><string>$OMB_DATA_DIR</string>
    <key>OMB_PUBLIC_URL</key><string>$OMB_PUBLIC_URL</string>
    <key>OMB_LOOPBACK_TRUST</key><string>${OMB_LOOPBACK_TRUST:-owner}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/openmausbot.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/openmausbot.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.openmausbot.server" 2>/dev/null || true
  launchctl enable "gui/$(id -u)/com.openmausbot.server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (starts at login; logs: ~/Library/Logs/openmausbot.log)"
fi

info "Waiting for the server on 127.0.0.1:$OMB_PORT"
if wait_http "http://127.0.0.1:$OMB_PORT/api/health" 30 2; then
  ok "OpenMausBot is healthy locally"
else
  [ "$OS" = "Linux" ] && die "OpenMausBot did not become healthy. Logs: journalctl --user -u openmausbot"
  die "OpenMausBot did not become healthy. Logs: ~/Library/Logs/openmausbot.log"
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

# ------------------------------------------------------- tailscale serve
# Serve is one mapping per port: publishing over another service's HTTPS
# port would silently take it down. Our own mapping (a re-run) is fine.
SERVE_TARGET="http://127.0.0.1:$OMB_PORT"
existing="$("$TAILSCALE" serve status 2>/dev/null | awk -v hdr="https://$host:$HTTPS_PORT " '
  index($0, hdr) == 1 { inblk = 1; next }
  /^https?:\/\// { inblk = 0 }
  inblk && $2 == "/" && $3 == "proxy" { print $4; exit }' || true)"
if [ -n "$existing" ] && [ "$existing" != "$SERVE_TARGET" ]; then
  die "HTTPS :$HTTPS_PORT is already published for $existing. Set another HTTPS_PORT in $ENV_FILE (see tailscale serve status)."
fi
info "Publishing via Tailscale Serve (HTTPS :$HTTPS_PORT, tailnet only)"
ts_serve_publish "$HTTPS_PORT" "http://127.0.0.1:$OMB_PORT"

# ------------------------------------------------------------ final check
# /api/health answers unauthenticated even through the proxy, so it proves
# the whole loopback -> Serve -> tailnet path without holding a session.
info "Verifying $OMB_PUBLIC_URL (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$OMB_PUBLIC_URL/api/health"; then
  ok "End-to-end check passed"
else
  echo "    Cert may still be minting — try again in a minute: curl $OMB_PUBLIC_URL/api/health"
fi

echo
printf '\033[1;32mDone.\033[0m OpenMausBot is at \033[1m%s\033[0m (tailnet only).\n' "$OMB_PUBLIC_URL"
echo
echo "Next, once, by hand (neither is scripted — they hold your credentials):"
echo "  $OMB_BIN pair --label \"MacBook\"   # print a pairing link, open it in the browser"
echo "  $OMB_BIN sessions                 # list or revoke paired devices"
echo "  Sign in the engines you want as THIS user over SSH: claude, codex login, grok, ..."
echo "  Optional per-bot browser: $OMB_BIN browser install (Linux deps: sudo $OMB_BIN browser install --with-deps)"
echo
echo "Manage it with:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart openmausbot"
  echo "  journalctl --user -u openmausbot -f"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/com.openmausbot.server   # restart"
  echo "  tail -f ~/Library/Logs/openmausbot.log"
fi
echo "  tailscale serve status        # or: tailscale serve --https=$HTTPS_PORT off"
