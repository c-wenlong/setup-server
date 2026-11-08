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

# Sets TAILSCALE to the CLI, resolved once to an absolute path: PATH first,
# then the macOS app bundle. Pinning matters — a bare `tailscale` would
# re-resolve through PATH on every call, so a shadowing binary could fake
# `serve status` (defeating ts_serve_foreign) or `status --json` (poisoning
# tailnet_host). As a sanity check the resolved binary must answer
# `version`: exit 0, and whatever it prints must look like Tailscale's —
# it mentions tailscale or starts like a version number. Empty output
# passes (the test fakes answer `version` silently); the point is refusing
# a binary that plainly is not Tailscale, not auditing the real one.
resolve_tailscale() {
  local cand ver
  cand="$(command -v tailscale 2>/dev/null || true)"
  # command -v can also name a shell function, an alias or a relative PATH
  # entry — pin only real, executable files.
  case "$cand" in
    /*) ;;
    ?*) cand="$(cd "$(dirname "$cand")" 2>/dev/null && pwd)/$(basename "$cand")" ;;
  esac
  if [ -z "$cand" ] || [ ! -x "$cand" ]; then
    if [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
      cand="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    else
      die "Tailscale is not installed: https://tailscale.com/download"
    fi
  fi
  ver="$("$cand" version 2>&1)" \
    || die "$cand: 'tailscale version' failed — refusing to run a binary that may not be Tailscale"
  case "$ver" in
    ''|*tailscale*|*Tailscale*|[0-9]*) ;;
    *) die "$cand does not look like Tailscale (version said: $ver)" ;;
  esac
  TAILSCALE="$cand"
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

# ts_serve_foreign HTTPS_PORT TARGET: 0 when `serve status` shows a /
# handler on HTTPS_PORT proxying anywhere but TARGET — a deliberate repoint
# (like the design-systems → Studio cutover on :8108) that a publish must
# not steal — and 1 otherwise. A `serve status` that cannot be read at all
# is FATAL, not "no evidence": like teardown.sh, we refuse to guess who
# owns the port, since guessing wrong means `serve --bg` overwrites another
# service's mapping. Empty output with a clean exit is fine — the node
# simply publishes nothing yet. Needs TAILSCALE.
ts_serve_foreign() {
  local https_port="$1" target="$2" status
  status="$("$TAILSCALE" serve status 2>&1)" \
    || die "Could not read Tailscale Serve status: ${status:-empty output}. Refusing to touch HTTPS :$https_port without knowing who owns the port (is tailscaled running?)"
  [ "$(printf '%s\n' "$status" | awk -v want=":$https_port" -v t="$target" '
    /^[A-Za-z][A-Za-z0-9+.-]*:\/\// {
      inport = 0
      if (index($0, "https://") == 1) {
        u = $1; sub(/\/$/, "", u)
        p = match(u, /:[0-9]+$/) ? substr(u, RSTART) : ":443"
        inport = (p == want)
      }
      next
    }
    inport && $2 == "/" { if (!(/ proxy / && $NF == t)) bad = 1 }
    END { print bad ? "foreign" : "clean" }')" = "foreign" ]
}

# ts_serve_publish HTTPS_PORT TARGET: publish TARGET (usually
# http://127.0.0.1:<port>) tailnet-only on HTTPS_PORT. Never steals the
# port: when ts_serve_foreign sees / handlers proxying elsewhere it warns
# and leaves the mapping alone; a port that is free or already ours is
# republished as before (Serve replaces the mapping); an unreadable
# `serve status` aborts the publish outright.
# On Linux a first publish failure is usually tailscaled refusing a
# non-operator, so it grants operator rights once via sudo. If Serve still
# fails it is the one-time enablement link: Tailscale prints it, we wait
# for Enter and retry — and re-check ownership before every attempt, since
# the wait is long enough for someone else to repoint the port meanwhile.
# Needs OS and TAILSCALE.
ts_serve_publish() {
  local https_port="$1" target="$2"
  if ts_serve_foreign "$https_port" "$target"; then
    warn "HTTPS :$https_port already proxies to a different target — leaving it alone. To hand the port to this service: $TAILSCALE serve --https=$https_port off, then re-run."
    return 0
  fi
  if ! "$TAILSCALE" serve --bg --https="$https_port" "$target" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Direct serve failed — trying operator grant (needs sudo, one time)"
      # The resolved absolute path, not `sudo tailscale`: sudo's secure_path
      # could otherwise resolve a different binary than the one we verified.
      sudo "$TAILSCALE" set --operator="$USER"
    fi
    while :; do
      if ts_serve_foreign "$https_port" "$target"; then
        warn "HTTPS :$https_port was repointed while we waited — leaving it alone."
        return 0
      fi
      if "$TAILSCALE" serve --bg --https="$https_port" "$target"; then
        break
      fi
      echo
      info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
      read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
    done
  fi
  ok "Tailscale Serve: HTTPS :$https_port -> $target"
}

# ------------------------------------------------------------------ .env

# env_lint FILE: die unless FILE is a .env that is safe to source
# (`set -a; . FILE`). Every non-blank, non-comment line must be KEY=value
# (KEY an identifier — an optional `export` prefix and leading whitespace
# are allowed), no key may appear twice, and no value may use command
# substitution ($() or backticks), since a sourced file runs as shell.
# Note the teardowns keep their own stricter env_lint: theirs also enforces
# how Docker Compose parses quotes and escapes, because they read .env
# without running it and must not disagree with Compose. Those copies are
# intentionally untouched — new code that sources a .env should call this
# one before `set -a; . "$ENV_FILE"; set +a`.
env_lint() {
  local env_file="$1" problem
  problem="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/\r$/, "", line)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) { print "line " NR " is not KEY=value"; exit }
      key = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1)
      if (seen[key]++) { print key " is set more than once"; exit }
      if (index(val, "$(") || index(val, "`")) { print "the value of " key " uses command substitution"; exit }
    }' "$env_file")"
  [ -z "$problem" ] || die "$env_file: $problem. Fix that line and re-run — a sourced .env runs as shell."
}
