#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of OpenHands Agent Canvas behind Tailscale.
# Linux + macOS.
#
# End state:
#   - OpenHands Agent Canvas (official Docker image) on
#     127.0.0.1:OPENHANDS_PORT, API-key gated (`--public`), reachable
#     tailnet-only at https://<host>.<tailnet>.ts.net:OPENHANDS_HTTPS_PORT
#   - ~/agent-workspaces is the only project tree the agent can see
#     (mounted at /projects)
#   - existing Claude / Codex credentials are never written or replaced
#
# Usage:
#   ./setup.sh
#   OPENHANDS_PORT=8001 ./setup.sh
#
# Requirements: Linux or macOS, curl, Docker + Compose v2, Tailscale
# logged in. Sudo is needed at most once on Linux (tailscale operator),
# never on macOS. Node.js / Paperclip are not required.
#
# Idempotent: safe to re-run; upgrades/repairs. An existing .env is never
# overwritten. docker-compose.creds.yml is written once if ~/.claude or
# ~/.codex already exist, and is never overwritten.

set -euo pipefail

OPENHANDS_PORT="${OPENHANDS_PORT:-8000}"
OPENHANDS_HTTPS_EXPLICIT="${OPENHANDS_HTTPS_PORT:+yes}"
OPENHANDS_HTTPS_PORT="${OPENHANDS_HTTPS_PORT:-$OPENHANDS_PORT}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
MARKER="$HOME/services/openhands"
LEGACY_DIR="$(cd "$SERVICE_DIR/.." && pwd)/paperclip-openhands"
WORKSPACES="${AGENT_WORKSPACES:-$HOME/agent-workspaces}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

randhex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    echo
  fi
}

env_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | head -1
}

# Canvas runs as uid 10001 (`openhands` in ghcr.io/openhands/agent-canvas).
# A 0700 host-owned bind mount makes the agent server die on
# conversations/ (EACCES); the ingress stays up on :8000 and 502s
# `ECONNREFUSED 127.0.0.1:18000`. Grant 10001 write without sudo.
grant_openhands_write() {
  local d uid=10001
  for d in "$@"; do
    [ -d "$d" ] || continue
    if command -v setfacl >/dev/null 2>&1 \
       && setfacl -m "u:${uid}:rwx" "$d" 2>/dev/null \
       && setfacl -d -m "u:${uid}:rwx" "$d" 2>/dev/null; then
      continue
    fi
    chmod a+rwx "$d" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."

if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$OPENHANDS_PORT" in ''|*[!0-9]*) die "OPENHANDS_PORT must be numeric (got: $OPENHANDS_PORT)";; esac
case "$OPENHANDS_HTTPS_PORT" in ''|*[!0-9]*) die "OPENHANDS_HTTPS_PORT must be numeric (got: $OPENHANDS_HTTPS_PORT)";; esac

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# --------------------------------------------- inspect existing harnesses
# Report only. Never write ~/.claude, ~/.codex, or their auth files.
info "Inspecting existing Claude / Codex installations (read-only)"
if command -v claude >/dev/null 2>&1; then
  ok "Claude CLI present: $(command -v claude) ($(claude --version 2>/dev/null | head -1 || echo unknown))"
else
  warn "Claude CLI not on PATH — Agent Canvas ACP can still use a mounted ~/.claude."
fi
if command -v codex >/dev/null 2>&1; then
  ok "Codex CLI present: $(command -v codex)"
else
  warn "Codex CLI not on PATH — Codex ACP needs credentials entered in the UI unless ~/.codex is mounted."
fi
if [ -e "$HOME/.claude" ]; then
  ok "Existing ~/.claude left untouched"
fi
if [ -e "$HOME/.codex" ]; then
  ok "Existing ~/.codex left untouched"
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
elif [ -f "$LEGACY_DIR/.env" ]; then
  info "Migrating OpenHands keys from paperclip-openhands/.env (not rotating secrets)"
  tz="$(env_get "$LEGACY_DIR/.env" TZ)"
  [ -n "$tz" ] || tz="Etc/UTC"
  oh_ver="$(env_get "$LEGACY_DIR/.env" OPENHANDS_VERSION)"
  [ -n "$oh_ver" ] || oh_ver="latest"
  oh_mem="$(env_get "$LEGACY_DIR/.env" OPENHANDS_MEM_LIMIT)"
  [ -n "$oh_mem" ] || oh_mem="2g"
  oh_port="$(env_get "$LEGACY_DIR/.env" OPENHANDS_PORT)"
  [ -n "$oh_port" ] || oh_port="$OPENHANDS_PORT"
  oh_data="$(env_get "$LEGACY_DIR/.env" OPENHANDS_DATA)"
  [ -n "$oh_data" ] || oh_data="$HOME/services/openhands/data"
  oh_ws="$(env_get "$LEGACY_DIR/.env" AGENT_WORKSPACES)"
  [ -n "$oh_ws" ] || oh_ws="$WORKSPACES"
  oh_host="$(env_get "$LEGACY_DIR/.env" TS_HOST)"
  [ -n "$oh_host" ] || oh_host="$TS_HOST"
  oh_url="$(env_get "$LEGACY_DIR/.env" OPENHANDS_PUBLIC_URL)"
  [ -n "$oh_url" ] || oh_url="https://$oh_host:$OPENHANDS_HTTPS_PORT"
  oh_key="$(env_get "$LEGACY_DIR/.env" OPENHANDS_API_KEY)"
  [ -n "$oh_key" ] || oh_key="$(randhex)"
  oh_secret="$(env_get "$LEGACY_DIR/.env" OH_SECRET_KEY)"
  [ -n "$oh_secret" ] || oh_secret="$(randhex)"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Secrets are interpolated into docker-compose.yml.
# Migrated from paperclip-openhands/.env — API keys were not rotated.

OPENHANDS_VERSION=$oh_ver
OPENHANDS_MEM_LIMIT=$oh_mem
OPENHANDS_PORT=$oh_port
TZ=$tz

OPENHANDS_DATA=$oh_data
AGENT_WORKSPACES=$oh_ws

TS_HOST=$oh_host
OPENHANDS_PUBLIC_URL=$oh_url

# Agent Canvas --public mode. Anyone who has this key can drive the
# backend; Tailscale is still the network boundary.
OPENHANDS_API_KEY=$oh_key
OH_SECRET_KEY=$oh_secret
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE from the combined-service .env"
else
  info "Writing .env (generated API keys + ports + paths)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Secrets are interpolated into docker-compose.yml.

OPENHANDS_VERSION=latest
OPENHANDS_MEM_LIMIT=2g
OPENHANDS_PORT=$OPENHANDS_PORT
TZ=$tz

OPENHANDS_DATA=$HOME/services/openhands/data
AGENT_WORKSPACES=$WORKSPACES

TS_HOST=$TS_HOST
OPENHANDS_PUBLIC_URL=https://$TS_HOST:$OPENHANDS_HTTPS_PORT

# Agent Canvas --public mode. Anyone who has this key can drive the
# backend; Tailscale is still the network boundary.
OPENHANDS_API_KEY=$(randhex)
OH_SECRET_KEY=$(randhex)
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

REQUESTED_OH_PORT="$OPENHANDS_PORT"
set -a; . "$ENV_FILE"; set +a
WORKSPACES="${AGENT_WORKSPACES:?AGENT_WORKSPACES missing from $ENV_FILE}"
OPENHANDS_DATA="${OPENHANDS_DATA:?OPENHANDS_DATA missing from $ENV_FILE}"
if [ "$OPENHANDS_PORT" != "$REQUESTED_OH_PORT" ]; then
  warn "OPENHANDS_PORT=$REQUESTED_OH_PORT ignored — the existing $ENV_FILE says $OPENHANDS_PORT. Edit .env and re-run to move the port."
fi
[ -n "$OPENHANDS_HTTPS_EXPLICIT" ] || OPENHANDS_HTTPS_PORT="$OPENHANDS_PORT"

mkdir -p "$MARKER" "$OPENHANDS_DATA" "$WORKSPACES/openhands-test"
chmod 700 "$MARKER" "$OPENHANDS_DATA" 2>/dev/null || true
grant_openhands_write "$OPENHANDS_DATA" "$WORKSPACES" "$WORKSPACES/openhands-test"
ok "OpenHands data + workspaces writable by container uid 10001"

if [ ! -f "$WORKSPACES/openhands-test/README.md" ]; then
  cat > "$WORKSPACES/openhands-test/README.md" <<'EOF'
# openhands-test

Scratch workspace mounted into Agent Canvas as `/projects/openhands-test`.
Safe to edit. Created by openhands/setup.sh.
EOF
fi
ok "Workspace: $WORKSPACES/openhands-test"

# --------------------------------------------- optional Claude/Codex mounts
# Generated once, never overwritten. Read-write so ACP can persist a
# session; setup.sh itself never writes inside ~/.claude or ~/.codex.
CREDS_FILE="$SERVICE_DIR/docker-compose.creds.yml"
LEGACY_CREDS="$LEGACY_DIR/docker-compose.creds.yml"
if [ -f "$CREDS_FILE" ]; then
  ok "Compose creds overlay already exists, leaving untouched: $CREDS_FILE"
elif [ -f "$LEGACY_CREDS" ]; then
  cp -a "$LEGACY_CREDS" "$CREDS_FILE"
  ok "Migrated compose creds overlay from paperclip-openhands/"
elif [ -d "$HOME/.claude" ] || [ -d "$HOME/.codex" ]; then
  info "Writing compose overlay to mount existing Claude/Codex dirs (not created, not copied)"
  {
    echo "services:"
    echo "  openhands:"
    echo "    volumes:"
    if [ -d "$HOME/.claude" ]; then
      echo "      - $HOME/.claude:/home/openhands/.claude"
    fi
    if [ -d "$HOME/.codex" ]; then
      echo "      - $HOME/.codex:/home/openhands/.codex"
    fi
  } > "$CREDS_FILE"
  ok "Wrote $CREDS_FILE"
else
  warn "No ~/.claude or ~/.codex to mount — OpenHands ACP will need credentials entered in the UI."
fi

# ---------------------------------------------------------- OpenHands
# The combined service used compose project name `paperclip-openhands` and
# the same container_name. Drop that container once so this project can
# recreate it; bind-mount data is unchanged.
if docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' openhands-agent-canvas >/dev/null 2>&1; then
  old_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' openhands-agent-canvas 2>/dev/null || true)"
  if [ "$old_project" = "paperclip-openhands" ]; then
    info "Adopting the container from the combined paperclip-openhands compose project"
    docker rm -f openhands-agent-canvas >/dev/null 2>&1 || true
  fi
fi

COMPOSE=(docker compose --project-directory "$SERVICE_DIR" -f docker-compose.yml)
if [ -f "$CREDS_FILE" ]; then
  COMPOSE+=(-f docker-compose.creds.yml)
fi

info "Starting OpenHands Agent Canvas (docker compose up -d) — first pull is large"
"${COMPOSE[@]}" up -d

# ------------------------------------------------------- wait
info "Waiting for OpenHands (:$OPENHANDS_PORT)"
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$OPENHANDS_PORT/" 2>/dev/null \
     || curl -fsS -o /dev/null "http://127.0.0.1:$OPENHANDS_PORT/canvas" 2>/dev/null; then
    ok "OpenHands is answering locally"
    break
  fi
  [ "$i" -eq 90 ] && die "OpenHands did not come up. docker compose --project-directory $SERVICE_DIR logs"
  sleep 3
done

# ------------------------------------------------------- tailscale serve
publish() { # publish <https_port> <local_port>
  if ! "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Serve failed — trying operator grant (needs sudo, one time)"
      sudo tailscale set --operator="$USER"
    fi
    until "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2"; do
      echo
      info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
      read -r
    done
  fi
  ok "Tailscale Serve: HTTPS :$1 -> http://127.0.0.1:$2"
}
info "Publishing via Tailscale Serve (tailnet only, no Funnel)"
publish "$OPENHANDS_HTTPS_PORT" "$OPENHANDS_PORT"

# ------------------------------------------------------------ verify
oh_url="https://$TS_HOST:$OPENHANDS_HTTPS_PORT"
info "Verifying end-to-end (first request can take ~60s while certs mint)"
if curl -fsS -o /dev/null --max-time 90 "$oh_url/" \
   || curl -fsS -o /dev/null --max-time 90 "$oh_url/canvas"; then
  ok "OpenHands reachable at $oh_url"
else
  warn "No answer on $oh_url yet — cert may still be minting: curl $oh_url/"
fi

echo
printf '\033[1;32mDone.\033[0m OpenHands Agent Canvas is on your tailnet only.\n'
echo
echo "  OpenHands:  $oh_url"
echo "              API key: OPENHANDS_API_KEY in $ENV_FILE"
echo "  Workspaces: $WORKSPACES   (OpenHands sees this as /projects)"
echo
echo "Paste OPENHANDS_API_KEY into the Canvas UI when asked. Pick Claude"
echo "Code or Codex under Settings → Agent, then open /projects/openhands-test."
echo
echo "OpenHands ACP: Settings → Agent → Claude Code / Codex. Concurrent"
echo "same-provider ACP conversations in one container may race on a shared HOME."
echo
echo "Manage:"
echo "  docker compose --project-directory $SERVICE_DIR ps|logs|restart"
echo "  tailscale serve status"
echo
echo "This is not on the public internet. Do not enable Tailscale Funnel."
echo "Paperclip is a separate service: cd ../paperclip && ./setup.sh"
exit 0
