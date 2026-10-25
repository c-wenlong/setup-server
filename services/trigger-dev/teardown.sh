#!/usr/bin/env bash
#
# teardown.sh — take Trigger.dev off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service's
#      dashboard, found from `tailscale serve status` (never `serve reset`).
#      The registry is loopback-only and setup.sh never publishes it.
#   2. `docker compose down` — the nine containers and the three trigger-*
#      networks go; every data directory stays. Task-runner containers the
#      supervisor started are not part of the compose project: if any are
#      still attached to a trigger-* network, teardown names them and stops
#      before changing anything rather than killing them.
#   3. keep .env and ~/services/trigger-dev, so ./setup.sh brings it back
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the state setup.sh made under
#                            # ~/services/trigger-dev and .env; asks you to
#                            # type "trigger-dev" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="trigger-dev"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

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
  local d="$1" parent leaf home services own nl checkout
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
  # Never a directory that holds this checkout (and so every other service's
  # .env): a repo cloned inside ~/services/<name> must survive a purge.
  checkout="$(cd "$SERVICE_DIR" && pwd -P)" || return 1
  case "$checkout/" in "$parent/$leaf"/*) return 1 ;; esac
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
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
# setup.sh's "magic link already sent" marker. A fixed path, not from .env:
# left behind, a fresh ./setup.sh would skip sending the first login link.
LOGIN_MARKER="$HOME/services/$NAME/.magic-link-requested"
ok "$NAME: local :$LOCAL_PORT, state under $HOME/services/$NAME"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."


# The supervisor starts one container per task run through the docker socket
# proxy and attaches it to trigger-webapp / trigger-supervisor. Those runners
# are not compose services, so `down` does not stop them, and while one is
# attached `down` cannot remove the networks. Anything on these networks that
# is not this compose project's own is reported, never killed: stop here,
# before anything changes.
NETWORKS="trigger-webapp trigger-supervisor trigger-docker-proxy"
attached_others() {
  local net
  for net in $NETWORKS; do
    docker ps -a --filter "network=$net" \
      --format '{{.Names}} {{.Label "com.docker.compose.project"}}' \
      || return 1
  done | awk -v p="$NAME" '$2 != p { print $1 }' | sort -u
}
LEFTOVERS="$(attached_others)" \
  || die "Could not list containers on the trigger-* networks — nothing was changed."
if [ -n "$LEFTOVERS" ]; then
  warn "These containers are attached to a trigger-* network but are not part of the $NAME compose project"
  warn "(task runs the supervisor started, or something you attached by hand):"
  printf '%s\n' "$LEFTOVERS" | sed 's/^/     /'
  die "Teardown does not stop containers it did not start. Let the runs finish, or remove them: docker rm -f $(printf '%s' "$LEFTOVERS" | tr '\n' ' ')— then re-run. Nothing was changed."
fi

# Units are not part of this service: setup.sh relies on Docker's restart
# policy and writes none. A unit someone added that mentions it is named, not
# touched (a read-only listing).
UNIT_DIR="$HOME/.config/systemd/user"
if [ -d "$UNIT_DIR" ]; then
  others="$(grep -l -e "$NAME" -e "trigger-webapp" "$UNIT_DIR"/*.service "$UNIT_DIR"/*.timer 2>/dev/null || true)"
  [ -z "$others" ] || warn "Left alone (setup.sh did not create them): $(printf '%s' "$others" | tr '\n' ' ')"
fi

# One purge target from .env. Sets PT to its real path, or to "" when it is
# not on disk. Dies before anything changes unless it is
# ~/services/trigger-dev itself or inside it. $3 is "dir" or "file".
purge_target() {
  local var="$1" p="$2" kind="$3" root
  PT=""
  [ -n "$p" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$p" in */) p="${p%/}" ;; *) break ;; esac; done
  case "$p" in *..*) die "$var=$p contains '..' — refusing." ;; esac
  case "$p" in
    "$HOME/services/"?*) ;;
    *) die "$var=$p is not inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be ~/services/trigger-dev
  # or inside it, never ~/services itself, another service, or anything above.
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ "$kind" = "dir" ]; then
      [ -d "$p" ] || die "$var=$p is not a directory — refusing."
    else
      [ ! -d "$p" ] || die "$var=$p is a directory, not a file — refusing."
    fi
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PT="$(real_dir "$p")" || die "$var=$p is not a real path inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PT" in
      "$root"/?*) ;;
      *) die "$var=$p resolves to $PT, which is not inside $root — refusing." ;;
    esac
  fi
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
DATA_VARS="TRIGGER_POSTGRES TRIGGER_CLICKHOUSE TRIGGER_REDIS TRIGGER_MINIO TRIGGER_REGISTRY TRIGGER_SHARED"
PURGE_DIRS=""
PURGE_FILES=""
PG_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  for var in $DATA_VARS; do
    purge_target "$var" "$(env_get "$var")" dir
    [ -z "$PT" ] || PURGE_DIRS="$PURGE_DIRS$PT
"
  done
  purge_target TRIGGER_REGISTRY_AUTH "$(env_get TRIGGER_REGISTRY_AUTH)" file
  [ -z "$PT" ] || PURGE_FILES="$PURGE_FILES$PT
"
  purge_target LOGIN_MARKER "$LOGIN_MARKER" file
  [ -z "$PT" ] || PURGE_FILES="$PURGE_FILES$PT
"
  # Postgres, ClickHouse, Redis, MinIO and the registry write their files as
  # container users, so a plain rm usually cannot empty those dirs. The
  # cleanup runs as root in the Postgres image compose already pulled (never a
  # pull, never sudo). Same tag rule as docker-compose.yml.
  pg_tag="$(env_get POSTGRES_IMAGE_TAG)"
  pg_tag="${pg_tag:-14}"
  case "$pg_tag" in *[!A-Za-z0-9._-]*) die "POSTGRES_IMAGE_TAG=$pg_tag in $ENV_FILE is not a plain image tag — refusing." ;; esac
  PG_IMAGE="postgres:$pg_tag"
  warn "--purge deletes the database, ClickHouse, Redis, MinIO (task payloads), the registry"
  warn "  (every deployed task image) and the worker token. Nothing backs them up. On disk:"
  if [ -n "$PURGE_DIRS$PURGE_FILES" ]; then
    printf '%s%s' "$PURGE_DIRS" "$PURGE_FILES" | sed 's/^/     /'
  else
    warn "  (nothing: the data is already gone)"
  fi
  warn "It also deletes $ENV_FILE (origins and secrets). This cannot be undone."
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
# One plain `down` for every part: docker-compose.yml has no profiles and no
# named volumes (all state is bind-mounted), so the purge path needs no -v.
info "Stopping and removing the containers (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down \
  || die "docker compose down failed. If it could not remove a trigger-* network, a task run started since the check is attached: docker ps -a --filter network=trigger-webapp — remove it and re-run ./teardown.sh. Data and .env are untouched."
ok "Containers and trigger-* networks removed; data under $HOME/services/$NAME kept"

# ---------------------------------------------------------------- purge
# Empty one checked purge dir. A plain rm first (a dir that never booted is
# all yours); whatever is left is container-owned, so a throwaway container of
# the Postgres image empties it as root, then the empty dir goes. Any leftover
# is a failure: .env stays so the purge can be re-run.
clear_dir() {
  local d="$1"
  [ -e "$d" ] || return 0
  rm -rf -- "$d" 2>/dev/null || true
  [ -e "$d" ] || return 0
  info "Some files in $d are owned by a container user; clearing them with $PG_IMAGE"
  docker run --rm --pull never --user 0 -v "$d:/x" --entrypoint sh "$PG_IMAGE" \
    -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
    || die "Could not clear container-owned files in $d. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
  rm -rf -- "$d" 2>/dev/null || true
  [ ! -e "$d" ] || die "$d is still there. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
}

if [ "$PURGE" -eq 1 ]; then
  info "Purging Trigger.dev state and .env"
  own="$(cd "$HOME/services" 2>/dev/null && pwd -P || true)/$NAME"
  while IFS= read -r d; do
    [ -z "$d" ] || clear_dir "$d"
  done <<EOF_PURGE_DIRS
$PURGE_DIRS
EOF_PURGE_DIRS
  while IFS= read -r f; do
    [ -z "$f" ] || rm -f -- "$f"
  done <<EOF_PURGE_FILES
$PURGE_FILES
EOF_PURGE_FILES
  # setup.sh makes the parent of registry/data and of auth.htpasswd
  # (~/services/trigger-dev/registry). rmdir only removes an empty one, and
  # only below ~/services/trigger-dev.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    parent="$(dirname "$p")"
    case "$parent" in "$own"/?*) [ -L "$parent" ] || rmdir -- "$parent" 2>/dev/null || true ;; esac
  done <<EOF_PURGE_PARENTS
$PURGE_DIRS$PURGE_FILES
EOF_PURGE_PARENTS
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data was already gone, so a purged app never reads as installed; rmdir
  # only ever removes an empty directory, and a symlink is left alone.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  [ ! -d "$HOME/services/$NAME" ] || warn "$HOME/services/$NAME still holds files setup.sh did not create; left alone."
  ok "Deleted the Trigger.dev state and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
  echo "  Kept: task images already pulled into this Docker (docker images 'localhost:*/trigger/*')"
  echo "  and this box's docker login for the registry (docker logout localhost:<REGISTRY_PORT>)."
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
