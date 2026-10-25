#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Beszel (resource monitoring) behind Tailscale.
# Linux + macOS.
#
# End state:
#   - hub (henrygd/beszel Docker image, host networking) on 127.0.0.1:PORT
#   - native agent binary in ~/.local/bin, kept alive + started at boot/login:
#       Linux: systemd --user unit + lingering
#       macOS: launchd LaunchAgent (starts at login)
#     The agent is native rather than containerised so it can read nvidia-smi,
#     hwmon temperatures and the docker socket. It listens on 127.0.0.1:45876.
#   - admin account, UI user, agent key exchange and system registration all
#     done through the hub's PocketBase API: zero manual UI steps
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:PORT
#
# Usage:
#   ./setup.sh                          # hub on 127.0.0.1:8092, HTTPS :8092
#   BESZEL_PORT=8093 ./setup.sh         # first run only; .env wins after
#   BESZEL_ADMIN_EMAIL=me@x.y ./setup.sh
#
# Requirements: Linux (systemd) or macOS, curl, python3, Docker + Compose v2,
# Tailscale installed + logged in.
# Sudo is needed at most twice on Linux (lingering, tailscale operator), only
# on the first run, and never on macOS.
#
# Idempotent: safe to re-run. It upgrades the hub image, rewrites the agent
# unit and restarts the agent; an existing .env is never overwritten.

set -euo pipefail
cd "$(dirname "$0")"
SERVICE_DIR="$PWD"

PORT="${BESZEL_PORT:-8092}"
ADMIN_EMAIL="${BESZEL_ADMIN_EMAIL:-admin@example.com}"
AGENT_PORT=45876
SYSTEM_NAME="${BESZEL_SYSTEM_NAME:-$(hostname -s 2>/dev/null || hostname)}"
STATE="$HOME/services/beszel"
ENV_FILE="$SERVICE_DIR/.env"
BIN="$HOME/.local/bin/beszel-agent"

ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
info() { printf '\033[36m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m  %s\n' "$*"; }
die()  { printf '\033[31m  !!\033[0m %s\n' "$*" >&2; exit 1; }

# 32 hex chars, so the password survives .env, shell quoting and the JSON
# body of the PocketBase auth call without escaping.
randhex() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root (sudo is invoked only where needed)."
command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required (it drives the hub's API)."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }
if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi

# Tailscale CLI: on PATH, or inside the macOS app bundle. Kept as an absolute
# path so the one sudo call below finds it regardless of sudo's secure_path.
if command -v tailscale >/dev/null; then
  TAILSCALE="$(command -v tailscale)"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed. Install it first: https://tailscale.com/download"
fi

if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$PORT" in ''|*[!0-9]*) die "BESZEL_PORT must be numeric (got: $PORT)";; esac

# The agent's CPU architecture decides which release tarball to fetch.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $ARCH (amd64 and arm64 only)" ;;
esac
OS_LC="$(printf '%s' "$OS" | tr '[:upper:]' '[:lower:]')"   # linux | darwin

if [ "$OS" = "Darwin" ]; then
  # docker-compose.yml runs the hub with network_mode: host so it can dial the
  # agent on 127.0.0.1. Docker Desktop only honours that with host networking
  # switched on (4.34+, Settings > Resources > Network); OrbStack supports it
  # out of the box. Without it the hub comes up but the system stays "down".
  warn "The hub uses host networking. On Docker Desktop enable Settings > Resources > Network > 'Enable host networking' first."
fi
ok "$OS/$ARCH + curl + python3 + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The tailnet name goes into the final URL. Resolve it, never hardcode it.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated admin credentials)"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
BESZEL_PORT=$PORT
BESZEL_VOLUME=$STATE/hub
BESZEL_ADMIN_EMAIL=$ADMIN_EMAIL
BESZEL_ADMIN_PASSWORD=$(randhex)
SYSTEM_NAME=$SYSTEM_NAME
EOF
  chmod 600 "$ENV_FILE"
fi

# Read back: an existing .env is the source of truth for the port and the
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$PORT"
set -a; . "$ENV_FILE"; set +a
PORT="${BESZEL_PORT:-$PORT}"
case "$PORT" in ''|*[!0-9]*) die "BESZEL_PORT in $ENV_FILE must be numeric (got: $PORT)";; esac
BESZEL_ADMIN_EMAIL="${BESZEL_ADMIN_EMAIL:?BESZEL_ADMIN_EMAIL missing from $ENV_FILE}"
BESZEL_ADMIN_PASSWORD="${BESZEL_ADMIN_PASSWORD:?BESZEL_ADMIN_PASSWORD missing from $ENV_FILE}"
if [ "$PORT" != "$REQUESTED_PORT" ]; then
  warn "BESZEL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $PORT. Edit .env and re-run to move the port."
fi
API="http://127.0.0.1:$PORT/api"
mkdir -p "$STATE/hub"

# ---------------------------------------------------------------- hub
info "Starting hub (docker compose up -d)"
docker compose --project-directory "$SERVICE_DIR" up -d
for i in $(seq 1 30); do
  curl -fsS -o /dev/null "$API/health" && break
  [ "$i" -eq 30 ] && die "hub did not come up; docker logs beszel"
  sleep 2
done
ok "hub answering on 127.0.0.1:$PORT"

# ------------------------------------------------- superuser + UI user + key
info "Ensuring superuser"
docker exec beszel /beszel superuser upsert \
  "$BESZEL_ADMIN_EMAIL" "$BESZEL_ADMIN_PASSWORD" >/dev/null
ok "superuser $BESZEL_ADMIN_EMAIL"

WIRE_OUT=$(python3 - "$API" "$BESZEL_ADMIN_EMAIL" "$BESZEL_ADMIN_PASSWORD" "$AGENT_PORT" "$SYSTEM_NAME" <<'PYEOF'
import json, sys, urllib.request

api, email, pw, agent_port, system_name = sys.argv[1:6]

def req(path, data=None, token=None, method=None):
    r = urllib.request.Request(api + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json",
                 **({"Authorization": token} if token else {})},
        method=method or ("POST" if data is not None else "GET"))
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.load(resp)

tok = req("/collections/_superusers/auth-with-password",
          {"identity": email, "password": pw})["token"]

# UI user (same email/password as superuser; role admin)
users = req(f"/collections/users/records?filter=(email='{email}')", token=tok)
if users["totalItems"]:
    uid = users["items"][0]["id"]
else:
    uid = req("/collections/users/records",
              {"email": email, "password": pw, "passwordConfirm": pw,
               "role": "admin", "verified": True}, token=tok)["id"]

key = req("/beszel/getkey", token=tok)["key"]

# register this box as a system (idempotent by name)
systems = req(f"/collections/systems/records?filter=(name='{system_name}')",
              token=tok)
if not systems["totalItems"]:
    req("/collections/systems/records",
        {"name": system_name, "host": "127.0.0.1",
         "port": agent_port, "users": [uid]}, token=tok)

print(json.dumps({"key": key, "user": uid}))
PYEOF
) || die "hub API wiring failed"
KEY=$(echo "$WIRE_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
ok "UI user + system record + agent key"

# ---------------------------------------------------------------- agent
if [ ! -x "$BIN" ]; then
  info "Downloading beszel-agent ($OS_LC/$ARCH)"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "https://github.com/henrygd/beszel/releases/latest/download/beszel-agent_${OS_LC}_${ARCH}.tar.gz" \
    | tar -xz -C "$HOME/.local/bin" beszel-agent
  chmod +x "$BIN"
fi
ok "agent binary: $("$BIN" --version 2>/dev/null || echo present)"

if [ "$OS" = "Linux" ]; then
  UNIT="$HOME/.config/systemd/user/beszel-agent.service"
  info "Installing systemd user service"
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOF
[Unit]
Description=Beszel monitoring agent
After=network.target

[Service]
ExecStart=$BIN
Environment="KEY=$KEY"
Environment="LISTEN=127.0.0.1:$AGENT_PORT"
Environment="GPU=true"
# AGENTS.md mandates Restart=always for long-running user units: with
# on-failure, a *clean* agent exit (code 0) is never restarted and beszel
# goes silently blind — no alert, because the thing that would alert is the
# thing that stopped.
Restart=always

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable beszel-agent.service >/dev/null 2>&1 || true
  systemctl --user restart beszel-agent.service   # always pick up unit changes
  ok "agent unit running (port $AGENT_PORT)"
else
  PLIST="$HOME/Library/LaunchAgents/com.henrygd.beszel-agent.plist"
  info "Installing launchd LaunchAgent"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  # Docker Desktop keeps its socket under ~/.docker; point the agent at it so
  # per-container stats work there too. No GPU=true: that flag is nvidia-smi.
  DOCKER_HOST_LINE=""
  if [ ! -S /var/run/docker.sock ] && [ -S "$HOME/.docker/run/docker.sock" ]; then
    DOCKER_HOST_LINE="    <key>DOCKER_HOST</key><string>unix://$HOME/.docker/run/docker.sock</string>"
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.henrygd.beszel-agent</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>KEY</key><string>$KEY</string>
    <key>LISTEN</key><string>127.0.0.1:$AGENT_PORT</string>
$DOCKER_HOST_LINE
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/beszel-agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/beszel-agent.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.henrygd.beszel-agent" 2>/dev/null || true
  # teardown.sh disables the label so it stays off across logins; undo that.
  launchctl enable "gui/$(id -u)/com.henrygd.beszel-agent"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (port $AGENT_PORT; logs: ~/Library/Logs/beszel-agent.log)"
fi

# ------------------------------------------------------------- lingering
# Linux only: makes the agent unit start at boot and survive logout.
# macOS LaunchAgents start at login; running before login would need a
# root LaunchDaemon — out of scope for a user-local install.
if [ "$OS" = "Linux" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time)"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled — agent now starts at boot"
  fi
fi

# ------------------------------------------------------- tailscale serve
if ! serve_out="$("$TAILSCALE" serve --bg --https="$PORT" "http://127.0.0.1:$PORT" 2>&1)"; then
  # The operator grant is for exactly one failure, "Access denied: serve
  # config denied" (Linux tailscaled without an operator). Anything else
  # falls through to the loop below, which never escalates.
  if [ "$OS" = "Linux" ] && printf '%s' "$serve_out" | grep -q 'denied'; then
    info "Granting Tailscale operator rights to $USER (needs sudo, one time)"
    sudo "$TAILSCALE" set --operator="$USER"
  fi
  # Only the one-time enablement (Tailscale prints an approval link) earns a
  # wait-and-retry; any other Serve error is reported and fatal, so a bad
  # config cannot loop forever behind an Enter prompt.
  until serve_out="$("$TAILSCALE" serve --bg --https="$PORT" "http://127.0.0.1:$PORT" 2>&1)"; do
    printf '%s\n' "$serve_out"
    case "$serve_out" in
      *login.tailscale.com*) ;;
      *) die "tailscale serve failed (see above)" ;;
    esac
    echo
    info "Tailscale Serve needs one-time enablement — open the URL above, approve, then press Enter to retry."
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$PORT -> http://127.0.0.1:$PORT (tailnet only)"

# ---------------------------------------------------------------- verify
info "Waiting for agent to report stats"
UP=$(python3 - "$API" "$BESZEL_ADMIN_EMAIL" "$BESZEL_ADMIN_PASSWORD" "$SYSTEM_NAME" <<'PYEOF'
import json, sys, time, urllib.request
api, email, pw, system_name = sys.argv[1:5]
def req(path, data=None, token=None):
    r = urllib.request.Request(api + path,
        data=json.dumps(data).encode() if data else None,
        headers={"Content-Type": "application/json",
                 **({"Authorization": token} if token else {})})
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.load(resp)
tok = req("/collections/_superusers/auth-with-password",
          {"identity": email, "password": pw})["token"]
for _ in range(30):
    s = req(f"/collections/systems/records?filter=(name='{system_name}')",
            token=tok)["items"][0]
    if s["status"] == "up":
        print("up"); break
    time.sleep(2)
else:
    print(s["status"])
PYEOF
)
if [ "$UP" != "up" ]; then
  [ "$OS" = "Linux" ] && die "agent did not connect (system status: $UP); journalctl --user -u beszel-agent"
  die "agent did not connect (system status: $UP); tail ~/Library/Logs/beszel-agent.log"
fi
ok "system '$SYSTEM_NAME' is UP and reporting"

url="https://$TS_HOST:$PORT"
echo
printf '\033[1;32mDone.\033[0m Dashboard: \033[1m%s\033[0m (login: %s / password in .env)\n' "$url" "$BESZEL_ADMIN_EMAIL"
echo
echo "Manage it with:"
echo "  docker logs beszel                       # hub"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart beszel-agent"
  echo "  journalctl --user -u beszel-agent -f"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/com.henrygd.beszel-agent   # restart agent"
  echo "  tail -f ~/Library/Logs/beszel-agent.log"
fi
echo "  tailscale serve status                   # or: tailscale serve --https=$PORT off"
