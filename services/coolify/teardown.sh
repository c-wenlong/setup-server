#!/usr/bin/env bash
#
# teardown.sh — take Coolify's own stack off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service (the
#      dashboard LOCAL_PORT and Soketi SOKETI_PORT), found from
#      `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — the compose project `coolify` (coolify,
#      coolify-db, coolify-redis, coolify-realtime) and its network go; the
#      named volumes coolify-db and coolify-redis stay, and so does
#      ~/services/coolify (SSH key, app metadata, backups)
#   3. keep .env (APP_KEY) and Coolify's key line in ~/.ssh/authorized_keys,
#      so ./setup.sh brings it back as it was
#
# Apps, databases and services YOU deployed through Coolify run as their own
# containers (label coolify.managed) outside this compose project. Teardown
# never stops or deletes them; it lists the ones it leaves alone.
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the volumes coolify-db and
#                            # coolify-redis (down -v), Coolify's dirs under
#                            # ~/services/coolify, .env (APP_KEY), and the
#                            # key line setup.sh added to authorized_keys.
#                            # Refuses while Coolify-deployed apps, databases
#                            # or services still exist. Asks you to type
#                            # "coolify" first. Terminal only: the launcher's
#                            # Remove button never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="coolify"
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
# path below it ($2). $3 is the expected kind, dir or file, checked inside
# the container before anything is deleted: the other kind is refused (exit
# 4), the way the visible-path check refuses — rm -rf on a directory that
# was meant to be a file could take far more than that file. A symlink
# anywhere on that path is refused (exit 3; it would resolve inside the
# container, not on this box); the path must be gone afterwards, and the
# folders emptied on the way go too. $4 is the image, any further arguments
# are extra `docker run` options. Returns the container's exit code.
hidden_rm() {
  local base="$1" rest="$2" kind="$3" image="$4" rc=0
  shift 4
  docker run --rm --pull never "$@" -v "$base:/x" --entrypoint sh "$image" \
    -c 'set -f; r=$1; k=$2; p=/x; IFS=/; for c in $r; do p=$p/$c; [ ! -L "$p" ] || exit 3; done; unset IFS
        if [ -e "/x/$r" ]; then
          { [ "$k" = dir ] && [ ! -d "/x/$r" ]; } && exit 4
          { [ "$k" = file ] && [ -d "/x/$r" ]; } && exit 4
        fi
        rm -rf -- "/x/$r" && [ ! -e "/x/$r" ] || exit 1
        d=$(dirname "/x/$r"); while [ "$d" != /x ]; do rmdir -- "$d" 2>/dev/null || break; d=$(dirname "$d"); done' \
    sh "$rest" "$kind" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # The emptied folder itself: removing it needs only its parent's
  # permissions, and rmdir never removes anything that is not empty.
  rmdir -- "$base" 2>/dev/null || true
}
env_lint
LOCAL_PORT="$(env_get LOCAL_PORT)"
SOKETI_PORT="$(env_get SOKETI_PORT)"
DATA_DIR="$(env_get COOLIFY_DATA)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
case "$SOKETI_PORT" in ''|*[!0-9]*) die "SOKETI_PORT in $ENV_FILE is missing or not numeric (got: $SOKETI_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
SOKETI_TARGET="http://127.0.0.1:$SOKETI_PORT"
ok "$NAME: dashboard :$LOCAL_PORT, soketi :$SOKETI_PORT, data ${DATA_DIR:-(not set)}"

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


# Containers Coolify itself started (deployed apps, databases, one-click
# services, its proxy/sentinel) carry the label coolify.managed and live
# outside this compose project. Read-only listing; this stack's own four
# containers are not in it.
OWN_CONTAINERS=" coolify coolify-db coolify-redis coolify-realtime "
managed_list() {
  local rows name state out=""
  rows="$(docker ps -a --filter label=coolify.managed --format '{{.Names}} {{.State}}')" || return 1
  while read -r name state; do
    [ -n "${name:-}" ] || continue
    case "$OWN_CONTAINERS" in *" $name "*) continue ;; esac
    out="$out, $name ($state)"
  done <<EOF
$rows
EOF
  printf '%s' "${out#, }"
}
MANAGED_OK=1
MANAGED="$(managed_list)" || { MANAGED=""; MANAGED_OK=0; }

# setup.sh installs no systemd units. Name any that mention Coolify so the
# user knows they were deliberately left alone (read-only listing).
UNITS_SEEN=""
if [ -d "$HOME/.config/systemd/user" ]; then
  UNITS_SEEN="$(grep -l -i -- coolify "$HOME/.config/systemd/user"/* 2>/dev/null | sed 's#.*/##' | tr '\n' ' ' || true)"
fi

# One purge path from .env, checked like the reference's data dir. Sets
# RESOLVED to the real path, or "" when it is not on disk. Behind a folder
# this user cannot search it is not "gone": RES_BASE is that folder (through
# real_dir, strictly inside ~/services/coolify, so the cleanup container can
# mount it) and RES_REST the path below it. $3 is what a refusal says was
# left as it was; a 4th argument "user" marks a dir holding what the user
# deployed, which must be seen to be empty, so a hidden one is refused.
RESOLVED=""
RES_BASE=""
RES_REST=""
resolve_purge_path() {
  local var="$1" dir="$2" left="$3" kind="${4:-}" root
  RESOLVED=""; RES_BASE=""; RES_REST=""
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  dir_state "$var" "$dir"
  if [ "$DIR_STATE" = "hidden" ]; then
    [ "$kind" != "user" ] \
      || die "$HIDDEN_DIR cannot be searched, so teardown cannot tell whether $var=$dir still holds what you deployed through Coolify. Check it (sudo ls -A $dir), remove it by hand if it is empty (sudo rm -rf $dir), then re-run. $left"
    RES_BASE="$(real_dir "$HIDDEN_DIR")" \
      || die "$HIDDEN_DIR cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. $left"
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services. $left"
    case "$RES_BASE" in
      "$root/$NAME"/?*) ;;
      *) die "$HIDDEN_DIR cannot be searched, so teardown cannot reach $var=$dir. Run: sudo rm -rf $dir   then ./teardown.sh --purge again. $left" ;;
    esac
    RES_REST="$HIDDEN_REST"
  fi
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    RESOLVED="$(real_dir "$dir")" || die "$var=$dir is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$RESOLVED" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $RESOLVED, which is not a folder inside $root — refusing." ;;
    esac
  fi
}

# A dir where Coolify keeps what the USER deployed. Purge never deletes that
# content: it refuses until the dir is empty.
BUSY=""
note_if_busy() {
  local listing
  [ -n "$2" ] || return 0
  listing="$(ls -A -- "$2")" \
    || die "Cannot list $2 ($1), so teardown cannot tell whether Coolify apps keep data there — refusing to purge. $3"
  [ -z "$listing" ] || BUSY="$BUSY $1=$2"
}

AUTH="$HOME/.ssh/authorized_keys"
PUB_LINE=""
PUB_NOTE=""

# Every purge path, and every reason purge must refuse: user-deployed work
# first, since purge deletes APP_KEY and the database, after which nothing
# could manage (or decrypt the settings of) those apps. Run twice: before
# the confirmation prompt (nothing changed yet), and again once Coolify's
# own stack is stopped, so an app deployed while the prompt waited cannot
# slip through to `down -v`. $1 is what the refusal says was left as it was.
P_DATA=""; P_SSH=""; P_BACKUPS=""; P_IMAGES=""; P_APPS=""; P_DBS=""; P_SVCS=""; P_SSH_HIDDEN=""
# Hidden purge targets as line pairs: the base, then the path below it
# (real_dir refuses a newline in the base, env_get never returns one).
P_HIDDEN=""
note_hidden() { [ -z "$RES_BASE" ] || P_HIDDEN="$P_HIDDEN$RES_BASE
$RES_REST
"; }
purge_checks() {
  local left="$1"
  P_HIDDEN=""
  resolve_purge_path COOLIFY_DATA "$DATA_DIR" "$left";                     P_DATA="$RESOLVED"; note_hidden
  resolve_purge_path COOLIFY_SSH "$(env_get COOLIFY_SSH)" "$left";         P_SSH="$RESOLVED"; note_hidden
  P_SSH_HIDDEN="$RES_BASE"
  resolve_purge_path COOLIFY_BACKUPS "$(env_get COOLIFY_BACKUPS)" "$left"; P_BACKUPS="$RESOLVED"; note_hidden
  resolve_purge_path COOLIFY_IMAGES "$(env_get COOLIFY_IMAGES)" "$left";   P_IMAGES="$RESOLVED"; note_hidden
  resolve_purge_path COOLIFY_APPLICATIONS "$(env_get COOLIFY_APPLICATIONS)" "$left" user; P_APPS="$RESOLVED"
  resolve_purge_path COOLIFY_DATABASES "$(env_get COOLIFY_DATABASES)" "$left" user;       P_DBS="$RESOLVED"
  resolve_purge_path COOLIFY_SERVICES "$(env_get COOLIFY_SERVICES)" "$left" user;         P_SVCS="$RESOLVED"

  MANAGED_OK=1
  MANAGED="$(managed_list)" || { MANAGED=""; MANAGED_OK=0; }
  [ "$MANAGED_OK" -eq 1 ] || die "Could not list Coolify-managed containers (docker ps --filter label=coolify.managed) — refusing to purge. $left"
  BUSY=""
  note_if_busy COOLIFY_APPLICATIONS "$P_APPS" "$left"
  note_if_busy COOLIFY_DATABASES "$P_DBS" "$left"
  note_if_busy COOLIFY_SERVICES "$P_SVCS" "$left"
  [ -z "$BUSY" ] || die "Coolify still holds apps, databases or services you deployed through it:$BUSY. Delete them in the Coolify dashboard first (that also removes their containers and data), then re-run. $left"
  [ -z "$MANAGED" ] || die "Containers deployed by Coolify still exist: $MANAGED. Delete those apps in the Coolify dashboard first (coolify-proxy / coolify-sentinel: docker rm -f them), then re-run. $left"
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
if [ "$PURGE" -eq 1 ]; then
  purge_checks "Nothing was changed."

  # The key line setup.sh appended to authorized_keys is the exact content
  # of its .pub file. Read it now, before the SSH dir is deleted.
  if [ -n "$P_SSH" ]; then
    pub="$P_SSH/keys/id.${USER:-$(id -un)}@host.docker.internal.pub"
    # Only the regular file setup.sh's ssh-keygen wrote, in the real keys dir:
    # a symlinked .pub (or keys dir) could point at someone else's key line.
    if [ -f "$pub" ] && [ ! -L "$pub" ] && [ ! -L "$P_SSH/keys" ]; then
      PUB_LINE="$(cat -- "$pub" 2>/dev/null || true)"
      nl='
'
      case "$PUB_LINE" in
        *"$nl"*) PUB_LINE="" ;;
        "ssh-ed25519 "?*" coolify") ;;
        *) PUB_LINE="" ;;
      esac
      [ -n "$PUB_LINE" ] || PUB_NOTE="$pub is not the single ssh-ed25519 ... coolify line setup.sh writes, so $AUTH is left alone. Remove Coolify's line by hand if it is there."
    elif [ -L "$pub" ] || [ -L "$P_SSH/keys" ]; then
      PUB_NOTE="$pub is a symlink, not the key file setup.sh wrote, so $AUTH is left alone. Remove Coolify's line by hand if it is there."
    fi
  fi
  if [ -z "$PUB_LINE" ] && [ -z "$PUB_NOTE" ] && [ -n "$P_SSH_HIDDEN" ]; then
    PUB_NOTE="$P_SSH_HIDDEN cannot be searched, so teardown cannot read Coolify's public key and $AUTH is left alone. Remove a line ending in ' coolify' by hand if one is there."
  fi
  [ -n "$PUB_LINE" ] || [ -n "$PUB_NOTE" ] \
    || PUB_NOTE="Coolify's public key file is gone, so teardown cannot tell which line of $AUTH is Coolify's; it is left alone. Remove a line ending in ' coolify' by hand if one is there."

  targets=""
  for t in "$P_DATA" "$P_SSH" "$P_BACKUPS" "$P_IMAGES" "$P_APPS" "$P_DBS" "$P_SVCS"; do
    [ -z "$t" ] || case " $targets " in *" $t "*) ;; *) targets="$targets $t" ;; esac
  done
  while IFS= read -r hb && IFS= read -r hr; do
    [ -n "$hb" ] || continue
    case " $targets " in *" $hb/$hr "*) ;; *) targets="$targets $hb/$hr" ;; esac
  done <<EOF
$P_HIDDEN
EOF
  key_msg="leaves $AUTH alone"
  if [ -n "$PUB_LINE" ] && [ -f "$AUTH" ] && grep -qxF -- "$PUB_LINE" "$AUTH"; then
    key_msg="removes Coolify's key line (only that line) from $AUTH"
  fi
  warn "--purge deletes the volumes coolify-db and coolify-redis (Coolify's database: every server, project and setting),${targets:- nothing on disk} and $ENV_FILE (APP_KEY), and $key_msg. This cannot be undone."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's dashboard or
# Soketi port, and nothing else: ports are found from what Serve actually
# publishes, not from what .env says was published (a re-run can publish a
# second port). A port shared with another handler (e.g. :443 with the
# launcher's /home) is left alone with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET or $SOKETI_TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" -v s="$SOKETI_TARGET" '
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
  port != "" && /\|-- / { n++; if (/ proxy / && ($NF == t || $NF == s)) mine++ }
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
  warn "$kept shared HTTPS port(s) still route to $TARGET or $SOKETI_TARGET (left on, see above); $unpublished port(s) unpublished."
elif [ "$unpublished" -eq 0 ]; then
  ok "Nothing on Tailscale Serve points at $TARGET or $SOKETI_TARGET (already off)"
fi

# ---------------------------------------------------------------- stop
# docker-compose.yml pins `name: coolify` and gives both volumes a fixed
# `name:`, so `down -v` (purge only) can only ever remove coolify-db and
# coolify-redis. Containers Coolify deployed are not in this project, so
# neither form touches them.
#
# `down` removes the containers first and the `coolify` network last. Apps
# Coolify deployed (and its proxy) join that network, so while any of them
# exists Docker refuses to remove it: recent Compose only warns, older
# releases exit non-zero. Judge the result by what is left, not the exit
# code: this stack's containers (and, with -v, both volumes) must be gone; a
# network still in use is reported and kept.
stack_down() {
  local left vols users
  docker compose --project-directory "$SERVICE_DIR" down "$@" && return 0
  left="$(docker ps -aq --filter label=com.docker.compose.project=coolify)" \
    || die "docker compose down failed and Docker cannot list what is left. Data and .env are untouched; re-run ./teardown.sh."
  [ -z "$left" ] || die "docker compose down failed and Coolify's own containers are still there. Data and .env are untouched; re-run ./teardown.sh."
  if [ "$#" -gt 0 ]; then
    vols="$(docker volume ls -q)" \
      || die "docker compose down -v failed and Docker cannot list volumes. Nothing under $HOME/services/$NAME was deleted and .env is kept; re-run ./teardown.sh --purge."
    if printf '%s\n' "$vols" | grep -qx -e coolify-db -e coolify-redis; then
      die "docker compose down -v failed and a coolify-db / coolify-redis volume is still there. Nothing under $HOME/services/$NAME was deleted and .env is kept; re-run ./teardown.sh --purge."
    fi
  fi
  users="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' coolify 2>/dev/null)" \
    || die "docker compose down failed (not because of the coolify network). Data and .env are untouched; re-run ./teardown.sh."
  users="${users% }"
  warn "Docker kept the 'coolify' network: still used by ${users:-other containers}. It goes when they do (docker network rm coolify)."
}
if [ "$PURGE" -eq 1 ]; then
  # The checks above ran while Coolify was still up and the prompt waited:
  # an app deployed in that window would be missed, and `down -v` takes the
  # database that is the only record of it. Stop Coolify's own stack first
  # (no -v: volumes stay), so nothing new can be deployed, then check again.
  info "Stopping Coolify's own containers (docker compose stop) before the final purge checks"
  docker compose --project-directory "$SERVICE_DIR" stop \
    || die "docker compose stop failed. Nothing was deleted (volumes, data and .env are intact); re-run ./teardown.sh --purge, or ./setup.sh to bring Coolify back."
  purge_checks "Nothing was deleted: Coolify's stack is stopped, its volumes, data and .env are intact, and ./setup.sh brings it back."
  info "Stopping and removing Coolify's containers and volumes (docker compose down -v)"
  stack_down -v
  ok "Containers and volumes coolify-db, coolify-redis removed"
else
  info "Stopping and removing Coolify's own containers (docker compose down)"
  stack_down
  ok "Containers removed; volumes coolify-db, coolify-redis and ${DATA_DIR:-the data dir} kept"
fi

if [ "$PURGE" -eq 0 ]; then
  if [ "$MANAGED_OK" -eq 0 ]; then
    warn "Could not list Coolify-deployed containers; whatever Coolify deployed was not touched."
  elif [ -n "$MANAGED" ]; then
    warn "Left alone (deployed by Coolify, not part of its own stack): $MANAGED. They keep running; Docker may keep the 'coolify' network while they use it."
  fi
fi
[ -z "$UNITS_SEEN" ] || warn "systemd user units mention coolify but setup.sh did not create them, so they were not touched: $UNITS_SEEN"

# ---------------------------------------------------------------- purge
# A dir the Coolify container (uid 9999) wrote into may hold files this user
# cannot delete. Try a plain rm; otherwise empty it with a throwaway
# container of the pinned image already on this box (no pull, no sudo).
COOLIFY_IMAGE="$(env_get REGISTRY_URL)"
COOLIFY_IMAGE="${COOLIFY_IMAGE:-docker.io}/coollabsio/coolify:$(env_get COOLIFY_VERSION)"
case "$COOLIFY_IMAGE" in *:) COOLIFY_IMAGE="${COOLIFY_IMAGE}4.3.21" ;; esac
purge_dir() {
  local d="$1"
  [ -n "$d" ] && [ -e "$d" ] || return 0
  rm -rf -- "$d" 2>/dev/null || true
  [ -e "$d" ] || return 0
  info "Some files in $d belong to the Coolify container; clearing them with $COOLIFY_IMAGE"
  docker run --rm --pull never --user 0:0 -v "$d:/x" --entrypoint sh "$COOLIFY_IMAGE" \
    -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
    || die "Could not clear container-owned files in $d. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
  rm -rf -- "$d" 2>/dev/null || true
  [ ! -e "$d" ] || die "$d is still there. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
}

if [ "$PURGE" -eq 1 ]; then
  info "Purging Coolify's data"
  # The key line first: once the SSH dir is gone there is no way left to
  # tell which line was Coolify's. Exact whole-line match, nothing else.
  if [ -n "$PUB_LINE" ] && [ -f "$AUTH" ] && grep -qxF -- "$PUB_LINE" "$AUTH"; then
    tmp="$(mktemp "$HOME/.ssh/.authorized_keys.XXXXXX")" \
      || die "Could not write a temp file in $HOME/.ssh. The volumes are gone, but Coolify's dirs, its key line and .env are kept: re-run ./teardown.sh --purge."
    rc=0
    grep -vxF -- "$PUB_LINE" "$AUTH" > "$tmp" || rc=$?
    [ "$rc" -le 1 ] || { rm -f -- "$tmp"; die "Could not rewrite $AUTH. The volumes are gone, but Coolify's dirs, its key line and .env are kept: re-run ./teardown.sh --purge."; }
    cat -- "$tmp" > "$AUTH"
    rm -f -- "$tmp"
    ok "Removed Coolify's key line from $AUTH (no other line changed)"
  elif [ -n "$PUB_NOTE" ]; then
    warn "$PUB_NOTE"
  else
    ok "Coolify's key is not in $AUTH (nothing to remove)"
  fi
  # User-deployed dirs were checked empty: rmdir, which never removes content.
  for d in "$P_APPS" "$P_DBS" "$P_SVCS"; do
    [ -n "$d" ] && [ -e "$d" ] || continue
    rmdir -- "$d" || die "$d is no longer empty — something deployed into it. Nothing else was deleted. .env was kept."
  done
  # Targets behind a folder this user cannot search: through the cleanup
  # container. A base already emptied and removed with an earlier target
  # is skipped (docker would create a missing mount source as root).
  while IFS= read -r hb && IFS= read -r hr; do
    [ -n "$hb" ] || continue
    [ -e "$hb" ] || [ -L "$hb" ] || continue
    info "$hb cannot be searched by this user; deleting $hb/$hr with $COOLIFY_IMAGE"
    hidden_rm "$hb" "$hr" dir "$COOLIFY_IMAGE" --user 0:0 </dev/null \
      || die "Could not delete $hb/$hr through $hb. Run: sudo rm -rf $hb/$hr   then ./teardown.sh --purge again. .env was kept."
  done <<EOF
$P_HIDDEN
EOF
  for d in "$P_SSH" "$P_BACKUPS" "$P_IMAGES" "$P_DATA"; do
    purge_dir "$d"
  done
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted${targets:- (no data dirs)} and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge (after deleting your apps in Coolify)"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
