#!/usr/bin/env bash
#
# teardown.sh — take Jellyfin off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` with the same compose files setup.sh used (the
#      GPU overlay too when JELLYFIN_NVENC=on) — the container and its network
#      go, the config, cache and media stay
#   3. keep .env, config and cache, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: everything on disk kept
#   ./teardown.sh --purge    # ALSO delete Jellyfin's own state (JELLYFIN_CONFIG,
#                            # JELLYFIN_CACHE, the wizard marker) and .env;
#                            # asks you to type "jellyfin" first. Terminal only:
#                            # the launcher's Remove button never passes it.
#
# MEDIA_DIR (your films, shows, music) is NEVER deleted, not even with --purge
# and not even when it sits inside ~/services/jellyfin. Purge removes the
# state directories one by one and refuses outright if a directory it would
# delete contains the library. Nothing enable-nvenc.sh set up on the host
# (nvidia-container-toolkit, the Docker runtime) is touched either.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="jellyfin"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/jellyfin"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) die "Unknown option: $1 (usage: ./teardown.sh [--purge])" ;;
esac
[ "$#" -le 1 ] || die "Too many arguments (usage: ./teardown.sh [--purge])"

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
command -v docker >/dev/null || die "Docker is not installed."
if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Run via: sg docker -c ./teardown.sh"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

# .env is the authority for ports and paths. Values are read the way Docker
# Compose reads them (an optional `export `, matching single or double quotes,
# an inline ` #` comment after an unquoted value) without executing the file.
env_get() {
  local line value tail quote=""
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) quote='"'; value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) quote="'"; value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}"
       tail="${value##*[![:space:]]}"; value="${value%"$tail"}" ;;
  esac
  # Compose interpolates $HOME / ${HOME} in unquoted and double-quoted values
  # (single quotes are literal). That one variable is all a path here may
  # use; anything else is left as written and then fails the path checks.
  if [ "$quote" != "'" ]; then
    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
  fi
  printf '%s' "$value"
}

# Real path of a purge target WITHOUT entering it: a Postgres- or root-owned
# data dir may be unreadable to this user, which is exactly when the purge
# needs the cleanup container. Resolve the parent, append the name. Refused
# (non-zero) unless the result is ~/services/$NAME itself or inside it, with
# ~/services a real directory under $HOME; a symlinked leaf, a `.`/`..`
# component, a newline or a colon (which would split a list or a -v mount)
# is never accepted.
real_dir() {
  local d="$1" parent leaf home services own nl
  nl='
'
  case "$d" in *"$nl"*|*:*) return 1 ;; esac
  case "/$d/" in */./*|*/../*) return 1 ;; esac
  leaf="$(basename "$d")"
  case "$leaf" in ''|.|..) return 1 ;; esac
  [ ! -L "$d" ] || return 1
  parent="$(cd "$(dirname "$d")" && pwd -P)" || return 1
  case "$parent" in *"$nl"*|*:*) return 1 ;; esac
  home="$(cd "$HOME" && pwd -P)" || return 1
  services="$(cd "$HOME/services" && pwd -P)" || return 1
  case "$services" in "$home"/?*) ;; *) return 1 ;; esac
  [ ! -L "$HOME/services/$NAME" ] || return 1
  own="$services/$NAME"
  case "$parent/$leaf" in "$own"|"$own"/*) ;; *) return 1 ;; esac
  printf '%s/%s' "$parent" "$leaf"
}

# teardown reads .env without running it, so it refuses anything it could
# read differently from Docker Compose: a key set twice, a quoted value that
# does not close on its own line (multi-line values), a backslash escape in
# double quotes, or a line that is not KEY=value. Prints key names only.
env_lint() {
  local problem
  problem="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/\r$/, "", line)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) { print "line " NR " is not KEY=value"; exit }
      key = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1)
      if (seen[key]++) { print key " is set more than once"; exit }
      q = substr(val, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(val, 2); end = index(rest, q)
        if (end == 0) { print "the quoted value of " key " does not close on its line"; exit }
        if (q == "\"" && index(substr(rest, 1, end - 1), "\\") > 0) { print "the value of " key " uses a backslash escape"; exit }
      }
    }' "$ENV_FILE")"
  [ -z "$problem" ] || die "$ENV_FILE: $problem. Fix that line (teardown will not guess how Compose reads it) and re-run."
}
env_lint
LOCAL_PORT="$(env_get LOCAL_PORT)"
CONFIG_DIR="$(env_get JELLYFIN_CONFIG)"
CACHE_DIR="$(env_get JELLYFIN_CACHE)"
LIBRARY_DIR="$(env_get MEDIA_DIR)"
NVENC="$(env_get JELLYFIN_NVENC)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, config ${CONFIG_DIR:-(not set)}, cache ${CACHE_DIR:-(not set)}, media ${LIBRARY_DIR:-(not set)}"

# Same compose file set setup.sh used, so `down` also removes a GPU-variant
# container. The overlay is only layered on when .env says NVENC is on.
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")
if [ "$NVENC" = "on" ] && [ -f "$SERVICE_DIR/docker-compose.gpu.yml" ]; then
  COMPOSE+=(-f "$SERVICE_DIR/docker-compose.yml" -f "$SERVICE_DIR/docker-compose.gpu.yml")
fi

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# One state directory to delete: strip trailing slashes, refuse '..', require
# the textual prefix ~/services/, then resolve symlinks and require a strict
# child of the real ~/services. Sets RESOLVED to the real path, or "" when the
# directory is not on disk. Dies on anything odd, before any change is made.
RESOLVED=""
guard_dir() {  # guard_dir VARNAME VALUE
  local var="$1" dir="$2" root
  RESOLVED=""
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    RESOLVED="$(real_dir "$dir")" || die "dir=$dir is not a real directory inside $HOME/services/$NAME — refusing."
    case "$RESOLVED" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $RESOLVED, which is not a folder inside $root — refusing." ;;
    esac
  fi
}

# True when path $1 is $2 or lies inside it.
is_within() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIRS=()
if [ "$PURGE" -eq 1 ]; then
  # The library is the one thing that must survive. Without knowing where it
  # is, there is no way to prove a directory is safe to delete.
  [ -n "$LIBRARY_DIR" ] || die "MEDIA_DIR is missing from $ENV_FILE — refusing to purge when the library cannot be located."
  case "$LIBRARY_DIR" in /*) ;; *) die "MEDIA_DIR=$LIBRARY_DIR is not an absolute path — refusing to purge." ;; esac
  media_text="$LIBRARY_DIR"
  while :; do case "$media_text" in */) media_text="${media_text%/}" ;; *) break ;; esac; done
  media_real="$media_text"
  [ ! -d "$media_text" ] || media_real="$(cd "$media_text" && pwd -P)" || die "Cannot resolve $media_text."

  for pair in "JELLYFIN_CONFIG:$CONFIG_DIR" "JELLYFIN_CACHE:$CACHE_DIR"; do
    guard_dir "${pair%%:*}" "${pair#*:}"
    [ -n "$RESOLVED" ] || continue
    d_text="${pair#*:}"
    while :; do case "$d_text" in */) d_text="${d_text%/}" ;; *) break ;; esac; done
    if is_within "$media_real" "$RESOLVED" || is_within "$media_text" "$d_text" || is_within "$media_real" "$d_text"; then
      die "${pair%%:*}=$d_text contains your media library (MEDIA_DIR=$LIBRARY_DIR) — refusing to purge, since that would delete it. Move MEDIA_DIR outside $d_text (or point ${pair%%:*} at its own folder) and re-run."
    fi
    PURGE_DIRS+=("$RESOLVED")
  done
  warn "--purge deletes ${PURGE_DIRS[*]:-nothing (no state dirs on disk)}, the wizard marker and $ENV_FILE. This cannot be undone."
  warn "Your media in $LIBRARY_DIR is NOT deleted."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's local port, and
# nothing else: ports are found from what Serve actually publishes, not from
# what .env says was published (a re-run can publish a second port). A port
# shared with another handler (e.g. :443 with the launcher's /home) is left
# alone with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" '
  function flush() {
    if (port != "") {
      if (n > 0 && mine == n) print "off " port
      else if (mine > 0) print "mixed " port
    }
    port = ""; n = 0; mine = 0
  }
  index($0, "https://") == 1 {
    flush()
    u = $1; sub(/\/$/, "", u)
    port = match(u, /:[0-9]+$/) ? substr(u, RSTART + 1) : "443"
    next
  }
  port != "" && /\|-- / { n++; if (/ proxy / && $NF == t) mine++ }
  END { flush() }')"
unpublished=0
while read -r verdict port; do
  [ -n "${verdict:-}" ] || continue
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
    unpublished=$((unpublished + 1))
  else
    warn "HTTPS :$port also serves something else, so it is left on. Drop this service's path from it by hand."
  fi
done <<EOF
$SERVE_PLAN
EOF
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET (already off)"

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
"${COMPOSE[@]}" down
ok "Container removed; config, cache and media kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging Jellyfin's own state (never the media library)"
  for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
    rm -rf -- "$d"
    ok "Deleted $d"
  done
  rm -f -- "$STATE/.wizard-complete"
  rm -f -- "$ENV_FILE"
  # The default library folder setup.sh makes: removed only when it is
  # empty, so the marker below can go. Anything with media in it stays.
  [ -L "$STATE/media" ] || rmdir -- "$STATE/media" 2>/dev/null || true
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted the wizard marker and $ENV_FILE; media in $LIBRARY_DIR untouched"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its state is gone (users, watch history, metadata). Your media was not touched. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Config, cache, media and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete Jellyfin's state too (never the media): ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
