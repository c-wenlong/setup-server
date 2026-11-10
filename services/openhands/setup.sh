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

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

randhex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    echo
  fi
}

# Values are read from .env the way Docker Compose reads them (an optional
# `export `, matching single or double quotes, an inline ` #` comment after
# an unquoted value, $HOME / ${HOME} expanded where Compose expands them)
# without executing the file — a hand edit must not become a command.
env_get() {
  local file="$1" key="$2" depth="${3:-0}" line value tail quote="" ref_name ref_val
  [ -f "$file" ] && [ "$depth" -lt 5 ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) quote='"'; value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) quote="'"; value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}"
       tail="${value##*[![:space:]]}"; value="${value%"$tail"}" ;;
  esac
  if [ "$quote" != "'" ]; then
    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
    while [ "$depth" -lt 5 ]; do
      if [[ "$value" =~ ^([^\$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
        ref_name="${BASH_REMATCH[2]}"
        ref_val="$(env_get "$file" "$ref_name" "$((depth + 1))")"
        value="${BASH_REMATCH[1]}${ref_val}${BASH_REMATCH[3]}"
      elif [[ "$value" =~ ^([^\$]*)\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
        ref_name="${BASH_REMATCH[2]}"
        ref_val="$(env_get "$file" "$ref_name" "$((depth + 1))")"
        value="${BASH_REMATCH[1]}${ref_val}${BASH_REMATCH[3]}"
      else
        break
      fi
      depth=$((depth + 1))
    done
  fi
  printf '%s' "$value"
}

# phys_path and paths_overlap are copied verbatim from teardown.sh: the same
# proof a --purge asks for is the proof a bind mount deserves before it is
# composed. Where an absolute path really lands, symlinks and all, whether or
# not it exists yet, WITHOUT entering it; refuses (non-zero) a relative
# path, a `.`/`..` component, a newline, a path through a file, or a symlink
# that points nowhere.
phys_path() {
  local p="$1" rest="" dir leaf t hops=0 nl
  nl='
'
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p" in *"$nl"*) return 1 ;; esac
  case "/$p/" in */./*|*/../*) return 1 ;; esac
  while [ ! -e "$p" ] && [ ! -L "$p" ]; do
    rest="/$(basename "$p")$rest"
    p="$(dirname "$p")"
  done
  [ -z "$rest" ] || [ -d "$p" ] || return 1
  if [ "$p" = / ]; then
    dir=/
  else
    dir="$(cd "$(dirname "$p")" && pwd -P)" || return 1
    leaf="$(basename "$p")"
    while [ -L "$dir/$leaf" ]; do
      hops=$((hops + 1)); [ "$hops" -le 40 ] || return 1
      t="$(readlink "$dir/$leaf")" || return 1
      case "$t" in /*) ;; *) t="$dir/$t" ;; esac
      dir="$(cd "$(dirname "$t")" && pwd -P)" || return 1
      leaf="$(basename "$t")"
      case "$leaf" in .|..) return 1 ;; esac
    done
    [ -e "$dir/$leaf" ] || return 1
    rest="/$leaf$rest"
  fi
  case "$dir$rest" in *"$nl"*) return 1 ;; esac
  if [ "$dir" = / ]; then printf '%s' "${rest:-/}"; else printf '%s%s' "$dir" "$rest"; fi
}

# True when one physical path is the other or sits inside it.
paths_overlap() {
  [ "$1" = / ] || [ "$2" = / ] && return 0
  case "$1/" in "$2"/*) return 0 ;; esac
  case "$2/" in "$1"/*) return 0 ;; esac
  return 1
}

# AGENT_WORKSPACES is bind-mounted into the container at /projects and the
# agent reads and writes it freely, so it has to be a dedicated tree under
# $HOME: absolute, free of `.`/`..` parts, not a symlinked leaf, and —
# symlinks resolved — strictly inside $HOME without touching ~/services
# (service state, including other services' .env secrets), ~/.claude or
# ~/.codex (host agent credentials, mounted by the creds overlay on their
# own paths, never through the workspace). Dies before anything is created
# or mounted; prints the resolved path on success.
validate_workspaces() {
  local ws="$1" ws_real home_real services_real p preal
  case "$ws" in
    /*) ;;
    *) die "AGENT_WORKSPACES=$ws is not an absolute path. Point it at a directory under your home (e.g. ~/agent-workspaces), or unset it for the default." ;;
  esac
  case "/$ws/" in
    */./*|*/../*) die "AGENT_WORKSPACES=$ws contains a '.' or '..' segment — give the real path instead." ;;
  esac
  [ ! -L "$ws" ] || die "AGENT_WORKSPACES=$ws is a symlink — point it at the real directory instead."
  ws_real="$(phys_path "$ws")" \
    || die "AGENT_WORKSPACES=$ws cannot be resolved to a real path (a path through a file, or a broken symlink). Fix it or unset it for the default."
  home_real="$(phys_path "$HOME")" || die "Cannot resolve HOME=$HOME."
  case "$ws_real" in
    "$home_real"/?*) ;;
    *) die "AGENT_WORKSPACES=$ws resolves to $ws_real, which is not inside your home directory ($home_real). The workspace tree must live under \$HOME." ;;
  esac
  services_real="$(phys_path "$HOME/services" 2>/dev/null || true)"
  if [ -n "$services_real" ] && paths_overlap "$ws_real" "$services_real"; then
    die "AGENT_WORKSPACES=$ws resolves to $ws_real, overlapping $HOME/services — the tree every service keeps its state (and .env secrets) in. Pick a separate one like ~/agent-workspaces."
  fi
  for p in "$HOME/.claude" "$HOME/.codex"; do
    preal="$(phys_path "$p" 2>/dev/null || true)"
    [ -n "$preal" ] || continue
    if paths_overlap "$ws_real" "$preal"; then
      die "AGENT_WORKSPACES=$ws resolves to $ws_real, overlapping $p — host agent credentials the creds overlay mounts separately. Pick a separate tree like ~/agent-workspaces."
    fi
  done
  printf '%s' "$ws_real"
}

# Canvas runs as uid 10001 (`openhands` in ghcr.io/openhands/agent-canvas).
# A 0700 host-owned bind mount makes the agent server die on
# conversations/ (EACCES); the ingress stays up on :8000 and 502s
# `ECONNREFUSED 127.0.0.1:18000`. Grant 10001 write: an ACL where the tool
# exists, otherwise the directory's ownership itself — never world-writable.
grant_openhands_write() {
  local d uid=10001 mode owner
  for d in "$@"; do
    [ -d "$d" ] || continue
    # Clear any legacy group/world-write bits left by the old chmod a+rwx fallback.
    mode="$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null || true)"
    case "$mode" in
      *[2367]|*[2367]?)
        chmod go-w "$d" 2>/dev/null || sudo chmod go-w "$d" \
          || die "Could not clear group/world-write permissions on $d"
        ;;
    esac
    if command -v setfacl >/dev/null 2>&1 \
       && setfacl -m "u:${uid}:rwx" "$d" 2>/dev/null \
       && setfacl -d -m "u:${uid}:rwx" "$d" 2>/dev/null; then
      continue
    fi
    # No usable ACL tool (macOS, minimal installs): give the directory to
    # the container uid. Skip sudo on reruns if already owned by $uid.
    owner="$(stat -c %u "$d" 2>/dev/null || stat -f %u "$d" 2>/dev/null || true)"
    if [ "$owner" = "$uid" ]; then
      continue
    fi
    info "setfacl is unavailable or failed on $d — the container runs as uid $uid, so the directory itself is chowned (one sudo prompt)"
    sudo chown "$uid:$uid" "$d" \
      || die "Could not grant OpenHands write access to $d: no usable setfacl and 'sudo chown $uid:$uid $d' failed. Run that chown by hand, then re-run."
  done
}

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
command -v curl >/dev/null || die "curl is required."

resolve_tailscale
require_docker_compose
require_tailscale_up
require_numeric OPENHANDS_PORT OPENHANDS_HTTPS_PORT

ok "$OS + curl + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

TS_HOST="$(tailnet_host)"
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
# .env is the authority for ports and paths, read the way Compose reads
# them — never by executing it (env_get above; a hand edit is not code).
env_port="$(env_get "$ENV_FILE" OPENHANDS_PORT)"
[ -z "$env_port" ] || OPENHANDS_PORT="$env_port"
WORKSPACES="$(env_get "$ENV_FILE" AGENT_WORKSPACES)"
[ -n "$WORKSPACES" ] || die "AGENT_WORKSPACES missing from $ENV_FILE"
OPENHANDS_DATA="$(env_get "$ENV_FILE" OPENHANDS_DATA)"
[ -n "$OPENHANDS_DATA" ] || die "OPENHANDS_DATA missing from $ENV_FILE"
if [ "$OPENHANDS_PORT" != "$REQUESTED_OH_PORT" ]; then
  warn "OPENHANDS_PORT=$REQUESTED_OH_PORT ignored — the existing $ENV_FILE says $OPENHANDS_PORT. Edit .env and re-run to move the port."
fi
[ -n "$OPENHANDS_HTTPS_EXPLICIT" ] || OPENHANDS_HTTPS_PORT="$OPENHANDS_PORT"

# The workspace becomes the agent's /projects. Prove it is a dedicated tree
# under $HOME before anything is created, granted or bind-mounted. Export the
# validated values so Docker Compose cannot inherit an unvalidated shell
# AGENT_WORKSPACES override over what .env and validate_workspaces settled on.
WORKSPACES="$(validate_workspaces "$WORKSPACES")"
AGENT_WORKSPACES="$WORKSPACES"
export AGENT_WORKSPACES OPENHANDS_DATA OPENHANDS_PORT

mkdir -p "$MARKER" "$OPENHANDS_DATA" "$WORKSPACES/openhands-test"
chmod 700 "$MARKER" "$OPENHANDS_DATA" 2>/dev/null || true

# Seed README.md BEFORE grant_openhands_write: when setfacl is unavailable,
# the fallback chowns openhands-test to uid 10001, after which this user
# could no longer create a file inside a 0755 directory.
if [ ! -f "$WORKSPACES/openhands-test/README.md" ]; then
  cat > "$WORKSPACES/openhands-test/README.md" <<'EOF'
# openhands-test

Scratch workspace mounted into Agent Canvas as `/projects/openhands-test`.
Safe to edit. Created by services/openhands/setup.sh.
EOF
fi

grant_openhands_write "$OPENHANDS_DATA" "$WORKSPACES" "$WORKSPACES/openhands-test"
ok "OpenHands data + workspaces writable by container uid 10001"
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
  ts_serve_publish "$1" "http://127.0.0.1:$2"
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
