#!/usr/bin/env bash
#
# teardown.sh — take Paperless-ngx off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — both containers and the network go, the
#      archive under PAPERLESS_ROOT stays
#   3. keep .env and the archive, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: archive and .env kept
#   ./teardown.sh --purge    # ALSO delete data/ (the database) and media/
#                            # (every document) and .env; asks you to type
#                            # "paperless-ngx" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# --purge keeps export/ and consume/ unless they are empty: export/ is where
# document_exporter writes (the only backup this box has), and anything left
# in consume/ is an original you dropped in that was never filed.
#
# THERE IS NO BACKUP OF THIS BOX. Before --purge, export:
#   docker exec paperless-ngx document_exporter ../export
# and copy ~/services/paperless-ngx/export somewhere else.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="paperless-ngx"
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
ROOT_DIR="$(env_get PAPERLESS_ROOT)"
CONTAINER="$(env_get CONTAINER_NAME)"; CONTAINER="${CONTAINER:-paperless-ngx}"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, archive ${ROOT_DIR:-(not set)}"

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

# Files under a directory, for the purge warning. Unreadable counts as 0; the
# directory is then simply not empty and rmdir leaves it.
count_files() { find "$1" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. What goes is only what setup.sh made
# and the container wrote: data/ and media/. export/ is the exporter's output
# (this box's only backup) and consume/ holds originals not yet filed, so
# both are removed only when empty.
PURGE_ROOT=""
PURGE_DIRS=()
# data/ and media/ behind a folder this user cannot search (see dir_state):
# that folder (real path, the same one for both), the paths below it, and
# where the archive root is when it is the root itself that is hidden.
HIDDEN_BASE=""
HIDDEN_RESTS=()
HIDDEN_ROOT=""
SHOW_DIRS=()
# The cleanup image, settled before the confirmation so the purge never has
# to work it out halfway.
PL_VERSION="$(env_get PAPERLESS_VERSION)"
PL_IMAGE="ghcr.io/paperless-ngx/paperless-ngx:${PL_VERSION:-3.1.3}"
# A purge target behind a folder this user cannot search. The cleanup
# container mounts that folder itself (real_dir resolves it without entering
# it) and deletes only the path below it, so the folder must sit strictly
# inside ~/services/paperless-ngx: sets HIDDEN_BASE, or dies before anything
# changes naming the sudo command ($3: data/ and media/, never export/).
hidden_base() {
  local var="$1" dir="$2" rmpaths="$3" base root
  base="$(real_dir "$HIDDEN_DIR")" \
    || die "$HIDDEN_DIR cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $rmpaths   then ./teardown.sh --purge again. Nothing was changed."
  root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
  case "$base" in
    "$root/$NAME"/?*) ;;
    *) die "$HIDDEN_DIR cannot be searched, so teardown cannot reach $var=$dir. Run: sudo rm -rf $rmpaths   then ./teardown.sh --purge again. Nothing was changed." ;;
  esac
  [ -z "$HIDDEN_BASE" ] || [ "$HIDDEN_BASE" = "$base" ] \
    || die "data/ and media/ under PAPERLESS_ROOT=$dir sit behind two different unsearchable folders. Run: sudo rm -rf $rmpaths   then ./teardown.sh --purge again. Nothing was changed."
  HIDDEN_BASE="$base"
}
if [ "$PURGE" -eq 1 ]; then
  [ -n "$ROOT_DIR" ] || die "PAPERLESS_ROOT is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$ROOT_DIR" in */) ROOT_DIR="${ROOT_DIR%/}" ;; *) break ;; esac; done
  case "$ROOT_DIR" in *..*) die "PAPERLESS_ROOT=$ROOT_DIR contains '..' — refusing." ;; esac
  case "$ROOT_DIR" in
    "$HOME/services/"?*) ;;
    *) die "PAPERLESS_ROOT=$ROOT_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  case "$ROOT_DIR" in *"
"*) die "PAPERLESS_ROOT=$ROOT_DIR contains a newline — refusing." ;; esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  dir_state PAPERLESS_ROOT "$ROOT_DIR"
  if [ "$DIR_STATE" = "hidden" ]; then
    # The whole archive is out of sight: delete data/ and media/ below the
    # hidden folder; export/ and consume/ cannot be checked, so they stay.
    hidden_base PAPERLESS_ROOT "$ROOT_DIR" "$ROOT_DIR/data $ROOT_DIR/media"
    HIDDEN_ROOT="$HIDDEN_BASE/$HIDDEN_REST"
    HIDDEN_RESTS=("$HIDDEN_REST/data" "$HIDDEN_REST/media")
    SHOW_DIRS=("$HIDDEN_ROOT/data" "$HIDDEN_ROOT/media")
  elif [ "$DIR_STATE" = "present" ]; then
    [ -d "$ROOT_DIR" ] || die "PAPERLESS_ROOT=$ROOT_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_ROOT="$(real_dir "$ROOT_DIR")" || die "PAPERLESS_ROOT=$ROOT_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_ROOT" in
      "$root"/?*) ;;
      *) die "PAPERLESS_ROOT=$ROOT_DIR resolves to $PURGE_ROOT, which is not a folder inside $root — refusing." ;;
    esac
    for sub in data media; do
      # The root itself may be unsearchable (a root-owned 0700 dir), and then
      # `[ -e ]` cannot see data/ or media/ at all; that is not "gone".
      dir_state "$sub" "$ROOT_DIR/$sub"
      [ "$DIR_STATE" != "missing" ] || continue
      if [ "$DIR_STATE" = "hidden" ]; then
        hidden_base PAPERLESS_ROOT "$ROOT_DIR" "$ROOT_DIR/data $ROOT_DIR/media"
        HIDDEN_RESTS+=("$HIDDEN_REST")
        SHOW_DIRS+=("$HIDDEN_BASE/$HIDDEN_REST")
        continue
      fi
      [ -d "$PURGE_ROOT/$sub" ] && [ ! -L "$PURGE_ROOT/$sub" ] \
        || die "$PURGE_ROOT/$sub is not a plain directory (a symlink or a file) — refusing."
      d="$(real_dir "$PURGE_ROOT/$sub")" || die "$PURGE_ROOT/$sub is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
      PURGE_DIRS+=("$d")
      SHOW_DIRS+=("$d")
    done
  fi
  if [ "${#SHOW_DIRS[@]}" -gt 0 ]; then
    warn "--purge deletes ${SHOW_DIRS[*]} and $ENV_FILE. This cannot be undone."
    warn "That is the whole document archive: every original and OCR'd PDF (media/), and the"
    warn "  database of tags, correspondents, titles and users (data/). THERE IS NO BACKUP OF THIS BOX."
  else
    warn "--purge deletes nothing on disk (no data/ or media/ under ${ROOT_DIR}) and $ENV_FILE. This cannot be undone."
  fi
  warn "Export first if you may ever want these documents back: press Ctrl-C now, then"
  warn "  docker exec $CONTAINER document_exporter ../export    (needs the container running: ./setup.sh)"
  warn "  and copy ${PURGE_ROOT:-$ROOT_DIR}/export off this box."
  if [ -n "$HIDDEN_ROOT" ] || { [ -n "$PURGE_ROOT" ] && [ ! -x "$PURGE_ROOT" ]; }; then
    warn "Kept: ${PURGE_ROOT:-$HIDDEN_ROOT}/export (the exporter's output) and ${PURGE_ROOT:-$HIDDEN_ROOT}/consume (files never filed),"
    warn "  whatever they hold: this user cannot see into them to count or empty them."
  elif [ -n "$PURGE_ROOT" ]; then
    warn "Kept: $PURGE_ROOT/export ($(count_files "$PURGE_ROOT/export") files, the exporter's output) and"
    warn "  $PURGE_ROOT/consume ($(count_files "$PURGE_ROOT/consume") files you dropped in that were never filed). Each is removed only if empty."
  fi
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
# Plain `down` keeps everything. `down -v` (only on the purge path) also drops
# the anonymous volume the redis image declares; persistence is off, so it
# never holds anything but is otherwise left behind forever.
if [ "$PURGE" -eq 1 ]; then
  info "Stopping and removing the containers and their volumes (docker compose down -v)"
  docker compose --project-directory "$SERVICE_DIR" down -v
  ok "Containers removed"
else
  info "Stopping and removing the containers (docker compose down)"
  docker compose --project-directory "$SERVICE_DIR" down
  ok "Containers removed; archive in ${ROOT_DIR:-PAPERLESS_ROOT} kept"
fi

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging the archive"
  for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
    # setup.sh maps the container's user onto yours, so a plain rm normally
    # works. If the container ever ran as another uid, some files are not
    # yours: empty the dir with a throwaway container of the pinned image
    # already on this box (no pull, no sudo), then remove it. A half-deleted
    # data/ is a failure, not a warning: Paperless would start on it.
    rm -rf -- "$d" 2>/dev/null || true
    if [ -e "$d" ]; then
      info "Some files in $d are not yours; clearing them with the pinned image"
      docker run --rm --pull never -v "$d:/x" --entrypoint sh "$PL_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear the files in $d. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$d" 2>/dev/null || true
      [ ! -e "$d" ] || die "$d is still there. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
    fi
    ok "Deleted $d"
  done
  # data/ and media/ the host cannot see: a throwaway container mounts the
  # folder that hides them and deletes only those paths. hidden_rm removes
  # that folder once it is empty, so a folder already gone means the path
  # below it went too. Never mount a missing folder: dockerd would create
  # it, as root.
  for rest in ${HIDDEN_RESTS[@]+"${HIDDEN_RESTS[@]}"}; do
    if [ ! -e "$HIDDEN_BASE" ] && [ ! -L "$HIDDEN_BASE" ]; then
      ok "$HIDDEN_BASE/$rest is already gone (its folder went with an earlier delete)"
      continue
    fi
    info "$HIDDEN_BASE cannot be searched by this user; deleting $HIDDEN_BASE/$rest with $PL_IMAGE"
    hidden_rm "$HIDDEN_BASE" "$rest" "$PL_IMAGE" \
      || die "Could not delete $HIDDEN_BASE/$rest through $HIDDEN_BASE. Run: sudo rm -rf $ROOT_DIR/data $ROOT_DIR/media   then ./teardown.sh --purge again. .env was kept."
    ok "Deleted $HIDDEN_BASE/$rest"
  done
  if [ -n "$PURGE_ROOT" ]; then
    # rmdir only ever removes an empty directory: an export or an unfiled
    # scan keeps its folder, and so its parent.
    for sub in consume export; do
      [ -L "$PURGE_ROOT/$sub" ] || rmdir -- "$PURGE_ROOT/$sub" 2>/dev/null || true
      [ ! -e "$PURGE_ROOT/$sub" ] || warn "Kept $PURGE_ROOT/$sub (not empty)"
    done
    rmdir -- "$PURGE_ROOT" 2>/dev/null || true
  fi
  # Only now, with data/ and media/ gone, the secrets.
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # archive was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its archive is gone. ./setup.sh starts fresh.\n' "$NAME"
  if [ -n "$PURGE_ROOT" ] && [ -e "$PURGE_ROOT" ]; then
    echo "  Left in place: $PURGE_ROOT (export/ or consume/ still has files). Remove by hand when done."
  elif [ -n "$HIDDEN_ROOT" ] && [ -e "$HIDDEN_BASE" ]; then
    echo "  Left in place: $HIDDEN_ROOT/export and consume/, if they were there (this user cannot see into $HIDDEN_BASE). Check with sudo ls."
  fi
else
  printf '\033[1;32mDone.\033[0m %s is removed. Archive and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the archive too (export first): ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
