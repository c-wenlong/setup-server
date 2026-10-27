# shellcheck shell=bash
#
# lib/common.sh: the pieces every deploy script repeats word for word.
#
# Sourced, never run. A script under services/<service>/ or app/<surface>/
# loads it by path relative to itself, so it works from any checkout and from
# the test sandboxes (which mirror that layout):
#
#   SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=../../lib/common.sh
#   . "$SERVICE_DIR/../../lib/common.sh"
#
# What belongs here: logic that at least ~5 scripts share unchanged. Anything
# a service does its own way (AdGuard and Syncthing binding the tailnet IP,
# native systemd/launchd units, a service-specific health probe) stays in that
# service's script.
#
# Portability: Linux + macOS, bash 3.2 (the macOS /bin/bash). No GNU-only
# flags. Every external command here (uname, id, docker, tailscale, curl,
# sudo) is one the mocked suites already stub on PATH.

# ------------------------------------------------------------------ output
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight

# Sets OS to `uname -s` and dies on anything but Linux or macOS.
detect_os() {
  OS="$(uname -s)"
  case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
}

# refuse_root [message]: the scripts escalate per command with sudo, so a
# root run would put user units, state and file ownership in the wrong place.
refuse_root() {
  [ "$(id -u)" -ne 0 ] || die "${1:-Run as a regular user, not root.}"
}

# Sets TAILSCALE to the CLI: PATH first, then the macOS app bundle.
resolve_tailscale() {
  if command -v tailscale >/dev/null; then
    TAILSCALE="tailscale"
  elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  else
    die "Tailscale is not installed: https://tailscale.com/download"
  fi
}

# Dies unless tailscaled reports BackendState "Running". Needs TAILSCALE.
require_tailscale_up() {
  local state
  state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  [ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"
}

# Prints this node's MagicDNS name without the trailing dot, or nothing when
# tailscaled has none. The caller decides whether empty is fatal.
tailnet_host() {
  "$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true
}

# Docker installed, daemon reachable by this user, Compose v2 present.
require_docker_compose() {
  if ! command -v docker >/dev/null; then
    [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
    die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
  fi
  if ! docker ps >/dev/null 2>&1; then
    [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./$(basename "$0"))"
    die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
}

# require_numeric NAME...: dies unless each named variable holds digits only.
require_numeric() {
  local name value
  for name in "$@"; do
    value="${!name-}"
    case "$value" in ''|*[!0-9]*) die "$name must be numeric (got: $value)";; esac
  done
}

# ------------------------------------------------------------------ deploy

# wait_http URL TRIES SLEEP: polls URL until it answers 2xx/3xx. Returns 0 as
# soon as it does, 1 after TRIES attempts; the caller words the ok/die.
wait_http() {
  local url="$1" tries="$2" pause="$3" i
  for i in $(seq 1 "$tries"); do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    [ "$i" -eq "$tries" ] || sleep "$pause"
  done
  return 1
}

# ts_serve_publish HTTPS_PORT TARGET: publish TARGET (usually
# http://127.0.0.1:<port>) tailnet-only on HTTPS_PORT. Idempotent: Serve
# replaces an existing mapping on that port. On Linux a first failure is
# usually tailscaled refusing a non-operator, so it grants operator rights
# once via sudo. If Serve still fails it is the one-time enablement link:
# Tailscale prints it, we wait for Enter and retry. Needs OS and TAILSCALE.
ts_serve_publish() {
  local https_port="$1" target="$2"
  if ! "$TAILSCALE" serve --bg --https="$https_port" "$target" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Direct serve failed — trying operator grant (needs sudo, one time)"
      sudo tailscale set --operator="$USER"
    fi
    until "$TAILSCALE" serve --bg --https="$https_port" "$target"; do
      echo
      info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
      read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
    done
  fi
  ok "Tailscale Serve: HTTPS :$https_port -> $target"
}
