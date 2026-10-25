#!/usr/bin/env bash
#
# teardown.sh — take Immich off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. stop the server and machine learning containers FIRST, then
#      `docker compose down` — Redis and Postgres only stop once nothing is
#      writing to them. The photo library and the database stay on disk.
#   3. keep .env, the library and the database, so ./setup.sh brings it back
#      as it was
#
# Usage:
#   ./teardown.sh            # safe remove: photos, database and .env kept
#   ./teardown.sh --purge    # ALSO delete the photo library, the database,
#                            # the ML model cache volume and .env; asks you to
#                            # type "immich" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#                            # Nothing backs the photos up.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="immich"
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
LIBRARY_DIR="$(env_get UPLOAD_LOCATION)"
DB_DIR="$(env_get DB_DATA_LOCATION)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
# setup.sh's "settings pass done" marker. A fixed path, not from .env: left
# behind, it makes a fresh ./setup.sh skip the low-RAM tuning.
ML_MARKER="$HOME/services/$NAME/.ml-mode"
ok "$NAME: local :$LOCAL_PORT, library ${LIBRARY_DIR:-(not set)}, database ${DB_DIR:-(not set)}"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# A purge target that dir_state found behind a folder this user cannot
# search. The cleanup container mounts that folder itself (real_dir resolves
# it without entering it) and deletes only the path below it, so the folder
# must sit strictly inside ~/services/immich: sets PT_BASE to its real path
# and PT_REST to the path below it, or dies before anything changes, naming
# the sudo command. A target outside ~/services/immich (or reached through a
# folder that is) gets $3 instead: it may be a photo folder teardown never
# deletes, so no sudo command is suggested for it.
hidden_target() {
  local var="$1" dir="$2" refusal="${3:-}" root nl='
'
  case "$dir" in
    "$HOME/services/$NAME"/?*) ;;
    *) die "$var=$dir is behind $HIDDEN_DIR, which this user cannot search, and is not inside $HOME/services/$NAME — refusing. ${refusal:-Remove it by hand if you are sure.}" ;;
  esac
  if ! PT_BASE="$(real_dir "$HIDDEN_DIR")"; then
    case "$HIDDEN_DIR" in
      "$HOME/services"|"$HOME/services/$NAME") ;;
      *) [ -z "$refusal" ] || die "$HIDDEN_DIR (on the way to $var=$dir) cannot be searched and is not a real directory inside $HOME/services/$NAME — refusing. $refusal" ;;
    esac
    die "$HIDDEN_DIR cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. Nothing was changed."
  fi
  root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
  case "$PT_BASE" in
    "$root/$NAME"/?*) ;;
    *) die "$HIDDEN_DIR cannot be searched, so teardown cannot reach $var=$dir. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. Nothing was changed." ;;
  esac
  case "$HIDDEN_REST" in *"$nl"*) die "$var=$dir contains a newline — refusing." ;; esac
  PT_REST="$HIDDEN_REST"
}

# One purge target from .env, checked the same way for both directories. Sets
# PT to its real path, or to "" when it is not on disk; when it sits behind a
# folder this user cannot search, PT is "" and PT_BASE/PT_REST say where it
# is (see hidden_target). Dies before anything changes unless it is
# ~/services/immich itself or inside it. $3 is what to say after the refusal.
purge_target() {
  local var="$1" dir="$2" refusal="$3" root
  PT=""; PT_BASE=""; PT_REST=""
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. $refusal" ;;
  esac
  # And where it really is, symlinks and all: it must be ~/services/immich
  # or inside it, never ~/services itself, another service, or anything above.
  dir_state "$var" "$dir"
  [ "$DIR_STATE" != "hidden" ] || hidden_target "$var" "$dir" "$refusal"
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PT="$(real_dir "$dir")" || die "$var=$dir is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing. $refusal"
    case "$PT" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $PT, which is not a folder inside $root — refusing." ;;
    esac
  fi
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DB=""
PURGE_LIBRARY=""
PURGE_MARKER=""
# The same three behind a folder this user cannot search: the folder (real
# path) and the path below it, plus what the user is told is deleted.
DB_BASE=""; DB_REST=""; DB_SHOW=""
LIB_BASE=""; LIB_REST=""; LIB_SHOW=""
MARKER_BASE=""; MARKER_REST=""; MARKER_SHOW=""
PG_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  # The library is the one path users are told to move (to a bigger disk), so
  # it is the one most likely to be a folder of photos that lives somewhere
  # else too. Outside ~/services/immich it is never deleted here.
  purge_target UPLOAD_LOCATION "$LIBRARY_DIR" \
    "UPLOAD_LOCATION is your photo library. Outside $HOME/services/$NAME it may be a photo folder you already had or a separate disk, and teardown never deletes those. Delete it by hand if you mean to, then set UPLOAD_LOCATION=$HOME/services/$NAME/library in .env and re-run ./teardown.sh --purge."
  PURGE_LIBRARY="$PT"; LIB_BASE="$PT_BASE"; LIB_REST="$PT_REST"
  LIB_SHOW="${PT:-${PT_BASE:+$PT_BASE/$PT_REST}}"
  purge_target DB_DATA_LOCATION "$DB_DIR" "Remove it by hand if you are sure."
  PURGE_DB="$PT"; DB_BASE="$PT_BASE"; DB_REST="$PT_REST"
  DB_SHOW="${PT:-${PT_BASE:+$PT_BASE/$PT_REST}}"
  dir_state ML_MARKER "$ML_MARKER"
  if [ "$DIR_STATE" = "hidden" ]; then
    hidden_target ML_MARKER "$ML_MARKER"
    MARKER_BASE="$PT_BASE"; MARKER_REST="$PT_REST"; MARKER_SHOW="$PT_BASE/$PT_REST"
  elif [ "$DIR_STATE" = "present" ]; then
    PURGE_MARKER="$(real_dir "$ML_MARKER")" || die "$ML_MARKER is not a plain file inside $HOME/services/$NAME — refusing."
    [ ! -d "$PURGE_MARKER" ] || die "$ML_MARKER is a directory — refusing."
    MARKER_SHOW="$PURGE_MARKER"
  fi
  # Postgres writes its files as the container's postgres user and the server
  # writes the library as root, so a plain rm usually cannot empty either. The
  # cleanup runs in the pinned Postgres image compose already pulled (never a
  # pull, never sudo). Read it from the compose file now, so a missing line
  # fails before anything changes.
  PG_IMAGE="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(ghcr\.io\/immich-app\/postgres:[^[:space:]]*\)[[:space:]]*$/\1/p' "$SERVICE_DIR/docker-compose.yml" | head -1)"
  [ -n "$PG_IMAGE" ] || die "Could not find the Postgres image in $SERVICE_DIR/docker-compose.yml — nothing was changed."
  warn "--purge deletes your Immich photo library: ${LIB_SHOW:-nothing (no library dir on disk)}"
  warn "  Every photo and video uploaded to Immich is deleted, with its thumbnails."
  warn "  Nothing backs them up: this box has no backup job. Copy out anything you want first."
  warn "It also deletes the database ${DB_SHOW:-(no database dir on disk)} (albums, people, users),"
  warn "  the ML model-cache volume, ${MARKER_SHOW:-(no ML marker)} and $ENV_FILE. This cannot be undone."
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
done <<EOF
$SERVE_PLAN
EOF
# A shared port left on still routes here, so "already off" would be wrong.
if [ "$kept" -gt 0 ]; then
  warn "$kept shared HTTPS port(s) still route to $TARGET (left on, see above); $unpublished port(s) unpublished."
elif [ "$unpublished" -eq 0 ]; then
  ok "Nothing on Tailscale Serve points at $TARGET (already off)"
fi

# ---------------------------------------------------------------- stop
# --profile ml always: the ML container exists only under that profile, and
# one left from an earlier IMMICH_ML=on run must go too even if .env now says
# off. Compose's `down` stops dependents first (the server depends_on redis +
# database), but the ML container has no depends_on at all, so nothing orders
# it against Postgres. Stop both clients explicitly; only then does `down`
# take Redis and Postgres.
COMPOSE=(docker compose --project-directory "$SERVICE_DIR" --profile ml)
info "Stopping the Immich server and machine learning before the database"
"${COMPOSE[@]}" stop immich-server immich-machine-learning
# Plain `down` keeps the named model-cache volume. `down -v` is only ever run
# on the purge path, after the typed confirmation.
if [ "$PURGE" -eq 1 ]; then
  info "Removing the containers and the model-cache volume (docker compose down -v)"
  "${COMPOSE[@]}" down -v
  ok "Containers and the model-cache volume removed"
else
  info "Removing the containers (docker compose down)"
  "${COMPOSE[@]}" down
  ok "Containers removed; photos in $LIBRARY_DIR and database in $DB_DIR kept"
fi

# ---------------------------------------------------------------- purge
# Empty one checked purge target. A plain rm first (a dir that never booted is
# all yours); whatever is left is container-owned, so a throwaway container of
# the pinned Postgres image empties it as root, then the empty dir goes. Any
# leftover is a failure: .env stays so the purge can be re-run.
clear_dir() {
  local d="$1"
  [ -e "$d" ] || return 0
  rm -rf -- "$d" 2>/dev/null || true
  [ -e "$d" ] || return 0
  info "Some files in $d are owned by a container user; clearing them with the pinned Postgres image"
  docker run --rm --pull never --user 0 -v "$d:/x" --entrypoint sh "$PG_IMAGE" \
    -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
    || die "Could not clear container-owned files in $d. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
  rm -rf -- "$d" 2>/dev/null || true
  [ ! -e "$d" ] || die "$d is still there. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
}

# Delete one target behind a folder this user cannot search ($1 that folder,
# $2 the path below it, $3 the path as in .env), as root from the pinned
# Postgres image. Two targets can share that folder, and hidden_rm removes it
# once it is empty, so a folder that is already gone means its target went
# with it. Never mount a missing folder: dockerd would create it, as root.
clear_hidden() {
  local base="$1" rest="$2" dir="$3"
  if [ ! -e "$base" ] && [ ! -L "$base" ]; then
    ok "$base/$rest is already gone (its folder went with an earlier delete)"
    return 0
  fi
  info "$base cannot be searched by this user; deleting $base/$rest with $PG_IMAGE"
  hidden_rm "$base" "$rest" "$PG_IMAGE" --user 0 \
    || die "Could not delete $base/$rest through $base. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. .env was kept."
}

if [ "$PURGE" -eq 1 ]; then
  info "Purging the database, the photo library and .env"
  [ -z "$PURGE_DB" ] || clear_dir "$PURGE_DB"
  [ -z "$DB_BASE" ] || clear_hidden "$DB_BASE" "$DB_REST" "$DB_DIR"
  [ -z "$PURGE_LIBRARY" ] || clear_dir "$PURGE_LIBRARY"
  [ -z "$LIB_BASE" ] || clear_hidden "$LIB_BASE" "$LIB_REST" "$LIBRARY_DIR"
  [ -z "$PURGE_MARKER" ] || rm -f -- "$PURGE_MARKER"
  [ -z "$MARKER_BASE" ] || clear_hidden "$MARKER_BASE" "$MARKER_REST" "$ML_MARKER"
  # Only now, with every data path gone, the secrets.
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data was already gone, so a purged app never reads as installed; rmdir
  # only ever removes an empty directory, and a symlink is left alone.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted ${DB_SHOW:-(no database dir)}, ${LIB_SHOW:-(no library dir)} and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its photos and database are gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Photos, database and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the photos and database too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
