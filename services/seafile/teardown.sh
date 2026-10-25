#!/usr/bin/env bash
#
# teardown.sh — take Seafile (the Drive) off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — seafile, seafile-mysql, seafile-redis and the
#      seafile-net network go; the data directories stay
#   3. keep .env and the data dirs, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the Seafile + MariaDB data dirs and
#                            # .env; asks you to type "seafile" first.
#                            # Terminal only: the launcher's Remove button
#                            # never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="seafile"
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

# Is a purge target there? `[ -e ]` is false both when it is gone and when a
# folder on the way (e.g. a root-owned 0700 dir) cannot be searched, and only
# the first means "nothing to delete". So walk down from ~/services: a
# component absent under a searchable parent means gone (DIR_STATE=missing);
# one that exists but cannot be searched hides the target (DIR_STATE=hidden,
# HIDDEN_DIR that folder, HIDDEN_REST the path below it). $2 must already be
# checked to sit inside ~/services/ with no `..` and no trailing slash.
DIR_STATE=""
HIDDEN_DIR=""
HIDDEN_REST=""
dir_state() {
  local var="$1" target="$2" p="$HOME/services" rest
  rest="${target#"$HOME/services/"}"
  DIR_STATE="present"; HIDDEN_DIR=""; HIDDEN_REST=""
  while :; do
    if [ ! -e "$p" ]; then
      # A symlink that does not resolve may be dangling or point into a
      # folder this user cannot search; the two look the same from here.
      [ ! -L "$p" ] || die "$p is a symlink this user cannot follow (dangling, or into a folder it cannot search), so teardown cannot tell whether $var=$target is there. Remove the link by hand if it is stale, then re-run. Nothing was changed."
      DIR_STATE="missing"; return 0
    fi
    [ -d "$p" ] || die "$p (on the way to $var=$target) is not a directory, refusing. Nothing was changed."
    if [ ! -x "$p" ]; then DIR_STATE="hidden"; HIDDEN_DIR="$p"; HIDDEN_REST="$rest"; return 0; fi
    case "$rest" in */*) ;; *) break ;; esac
    p="$p/${rest%%/*}"
    rest="${rest#*/}"
  done
  if [ ! -e "$target" ]; then
    [ ! -L "$target" ] || die "$target is a symlink this user cannot follow (dangling, or into a folder it cannot search), so teardown cannot tell whether $var=$target is there. Remove the link by hand if it is stale, then re-run. Nothing was changed."
    DIR_STATE="missing"
  fi
}

# A purge target behind a folder this user cannot search: the host cannot
# even see it, so a throwaway container mounts that folder ($1, already
# through real_dir and strictly inside ~/services/$NAME) and deletes only the
# path below it ($2). A symlink anywhere on that path is refused (it would
# resolve inside the container, not on this box); the path must be gone
# afterwards, and the folders emptied on the way go too. $3 is the image,
# any further arguments are extra `docker run` options. Non-zero on failure.
hidden_rm() {
  local base="$1" rest="$2" image="$3"
  shift 3
  docker run --rm --pull never "$@" -v "$base:/x" --entrypoint sh "$image" \
    -c 'set -f; r=$1; p=/x; IFS=/; for c in $r; do p=$p/$c; [ ! -L "$p" ] || exit 3; done; unset IFS
        rm -rf -- "/x/$r" && [ ! -e "/x/$r" ] || exit 1
        d=$(dirname "/x/$r"); while [ "$d" != /x ]; do rmdir -- "$d" 2>/dev/null || break; d=$(dirname "$d"); done' \
    sh "$rest" >/dev/null 2>&1 || return 1
  # The emptied folder itself: removing it needs only its parent's
  # permissions, and rmdir never removes anything that is not empty.
  rmdir -- "$base" 2>/dev/null || true
}
env_lint
LOCAL_PORT="$(env_get LOCAL_PORT)"
DATA_DIR="$(env_get SEAFILE_VOLUME)"
MYSQL_DIR="$(env_get SEAFILE_MYSQL_VOLUME)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, data ${DATA_DIR:-(not set)}, mysql ${MYSQL_DIR:-(not set)}"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# The compose project name, the way Compose derives it: a top-level `name:`
# in docker-compose.yml, else this directory's name, lowercased with anything
# but [a-z0-9_-] dropped. Used only to check what a failed `down` left.
PROJECT="$(sed -n 's/^name:[[:space:]]*//p' "$SERVICE_DIR/docker-compose.yml" | head -1)"
PROJECT="${PROJECT%%#*}"
PROJECT="$(printf '%s' "${PROJECT:-$(basename "$SERVICE_DIR")}" | tr -d "\"' " | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-' | sed 's/^[-_]*//')"
[ -n "$PROJECT" ] || die "Cannot tell the compose project name for $SERVICE_DIR. Nothing was changed."

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# Check one purge target from .env ($1 = its variable name, $2 = its value)
# and set CHECKED to its real path, or to "" when it is not on disk. A target
# behind a folder this user cannot search sets CHECKED_BASE (that folder,
# resolved, strictly inside ~/services/seafile) and CHECKED_REST (the path
# below it) instead, for the cleanup container. Every refusal dies here,
# before the confirmation prompt and before any change.
CHECKED=""
CHECKED_BASE=""
CHECKED_REST=""
check_purge_dir() {
  local var="$1" dir="$2" root svc_real
  CHECKED=""; CHECKED_BASE=""; CHECKED_REST=""
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # `[ -e ]` alone would take a dir behind an unsearchable folder for gone.
  dir_state "$var" "$dir"
  if [ "$DIR_STATE" = "hidden" ]; then
    # The cleanup container mounts the unsearchable folder itself (real_dir
    # resolves it without entering it) and deletes only the path below it,
    # so that folder must sit strictly inside ~/services/seafile.
    CHECKED_BASE="$(real_dir "$HIDDEN_DIR")" \
      || die "$HIDDEN_DIR cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. Nothing was changed."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    case "$CHECKED_BASE" in
      "$root/$NAME"/?*) ;;
      *) die "$HIDDEN_DIR cannot be searched, so teardown cannot reach $var=$dir. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. Nothing was changed." ;;
    esac
    CHECKED_REST="$HIDDEN_REST"
  fi
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    CHECKED="$(real_dir "$dir")" || die "$var=$dir is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$CHECKED" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $CHECKED, which is not a folder inside $root — refusing." ;;
    esac
    # Never this checkout itself (a repo cloned so that ~/services/seafile is
    # this very directory would otherwise delete the scripts).
    svc_real="$(cd "$SERVICE_DIR" && pwd -P)"
    case "$svc_real" in
      "$CHECKED"|"$CHECKED"/*) die "$var=$dir contains this script's own directory ($svc_real) — refusing." ;;
    esac
  fi
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DATA=""; DATA_BASE=""; DATA_REST=""; DATA_SHOW=""
PURGE_MYSQL=""; MYSQL_BASE=""; MYSQL_REST=""; MYSQL_SHOW=""
DB_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  check_purge_dir SEAFILE_VOLUME "$DATA_DIR"
  PURGE_DATA="$CHECKED"; DATA_BASE="$CHECKED_BASE"; DATA_REST="$CHECKED_REST"
  check_purge_dir SEAFILE_MYSQL_VOLUME "$MYSQL_DIR"
  PURGE_MYSQL="$CHECKED"; MYSQL_BASE="$CHECKED_BASE"; MYSQL_REST="$CHECKED_REST"
  DATA_SHOW="${PURGE_DATA:-${DATA_BASE:+$DATA_BASE/$DATA_REST}}"
  MYSQL_SHOW="${PURGE_MYSQL:-${MYSQL_BASE:+$MYSQL_BASE/$MYSQL_REST}}"
  # Seafile runs as root in its container and MariaDB as the image's mysql
  # uid, so most files are not this user's and a plain rm fails on them. The
  # cleanup is a throwaway container of the MariaDB image this stack already
  # pulled (no pull, no sudo); it is checked here, before anything changes.
  DB_IMAGE="$(env_get SEAFILE_DB_IMAGE)"
  [ -n "$DB_IMAGE" ] || DB_IMAGE="mariadb:10.11"
  # It lands in a `docker run` argv: an image reference, never an option.
  case "$DB_IMAGE" in
    [a-z0-9]*) ;;
    *) die "SEAFILE_DB_IMAGE=$DB_IMAGE does not look like an image name — refusing. Nothing was changed." ;;
  esac
  case "$DB_IMAGE" in *[[:space:]]*) die "SEAFILE_DB_IMAGE contains whitespace — refusing. Nothing was changed." ;; esac
  warn "--purge deletes ${DATA_SHOW:-nothing for SEAFILE_VOLUME (not on disk)}, ${MYSQL_SHOW:-nothing for SEAFILE_MYSQL_VOLUME (not on disk)} and $ENV_FILE. This cannot be undone."
  warn "That is the whole Drive on this server: every library, every synced file and any phone photo backups stored here, their history, and all accounts."
  warn "Desktop and phone clients keep their local copies, but they will have nothing to sync with."
  warn "Other services pointing at Seafile lose it: self-learn reads this .env at install time and syncs into a Seafile library; manimkc uploads its videos to a Seafile library."
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
kept=0
while read -r verdict port; do
  [ -n "${verdict:-}" ] || continue
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
    unpublished=$((unpublished + 1))
  else
    warn "HTTPS :$port also serves something else, so it is left on. Drop this service's path from it by hand."
    kept=$((kept + 1))
  fi
done <<EOT
$SERVE_PLAN
EOT
# A shared port left on still routes here, so "already off" would be wrong.
if [ "$kept" -gt 0 ]; then
  warn "$kept shared HTTPS port(s) still route to $TARGET (left on, see above); $unpublished port(s) unpublished."
elif [ "$unpublished" -eq 0 ]; then
  ok "Nothing on Tailscale Serve points at $TARGET (already off)"
fi

# ---------------------------------------------------------------- stop
# `down` also fails when a container outside this project still uses the
# fixed-name seafile-net network (Seafile's official add-ons, SeaDoc and the
# notification server, join it from their own compose files). That alone is
# no reason to stop halfway: check this project's own containers are gone and
# the network really is held by someone else, warn naming them, and go on.
# Anything else dies as before, with data and .env untouched.
stack_down() {
  local left users
  docker compose --project-directory "$SERVICE_DIR" down && return 0
  left="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" \
    || die "docker compose down failed and Docker cannot list what is left. Data and .env are untouched; re-run ./teardown.sh."
  [ -z "$left" ] || die "docker compose down failed and Seafile's own containers are still there. Data and .env are untouched; re-run ./teardown.sh."
  users="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' seafile-net 2>/dev/null)" \
    || die "docker compose down failed (not because of the seafile-net network). Data and .env are untouched; re-run ./teardown.sh."
  users="${users% }"
  [ -n "$users" ] || die "docker compose down failed and nothing is left on the seafile-net network, so that is not why. Data and .env are untouched; re-run ./teardown.sh."
  warn "Docker kept the seafile-net network: still used by $users (not part of this stack, e.g. a SeaDoc or notification-server add-on). It goes when they do (docker network rm seafile-net)."
}
info "Stopping and removing the containers (docker compose down)"
stack_down
ok "Containers removed; data in ${DATA_DIR:-(not set)} and ${MYSQL_DIR:-(not set)} kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging data"
  # A plain rm first (a stack that never booted is all yours); otherwise
  # empty the dir with the MariaDB image checked above, then remove the
  # now-empty directory itself. A target behind a folder this user cannot
  # search goes through that folder, mounted, instead. A half-deleted store
  # is a failure, not a warning, and .env stays so the retry still knows what
  # to delete: .env goes only once every data path is gone.
  purge_one() {
    local dir="$1" base="$2" rest="$3"
    if [ -n "$base" ]; then
      # Gone already (it went with the other dir): never mount a missing
      # source, Docker would create it as root. Its parent is searchable, so
      # this test is reliable.
      if [ ! -e "$base" ] && [ ! -L "$base" ]; then
        ok "$base/$rest is already gone"
        return 0
      fi
      info "$base cannot be searched by this user; deleting $base/$rest with $DB_IMAGE"
      hidden_rm "$base" "$rest" "$DB_IMAGE" \
        || die "Could not delete $base/$rest through $base. Run: sudo rm -rf $base/$rest   then ./teardown.sh --purge again. .env was kept."
      ok "Deleted $base/$rest"
      return 0
    fi
    [ -n "$dir" ] || return 0
    [ -e "$dir" ] || return 0   # already gone (e.g. inside the other one)
    rm -rf -- "$dir" 2>/dev/null || true
    if [ -e "$dir" ]; then
      info "Some files in $dir are container-owned; clearing them with $DB_IMAGE"
      docker run --rm --pull never -v "$dir:/x" --entrypoint sh "$DB_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear container-owned files in $dir. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$dir" 2>/dev/null || true
      [ ! -e "$dir" ] || die "$dir is still there. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. .env was kept."
    fi
    ok "Deleted $dir"
  }
  purge_one "$PURGE_DATA" "$DATA_BASE" "$DATA_REST"
  purge_one "$PURGE_MYSQL" "$MYSQL_BASE" "$MYSQL_REST"
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dirs were already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  If the admin password was changed in the web UI, .env holds a stale copy;"
  echo "  the data keeps the real one (see TROUBLESHOOT.md, Login problems)."
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
