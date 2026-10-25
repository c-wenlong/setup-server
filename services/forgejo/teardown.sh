#!/usr/bin/env bash
#
# teardown.sh — take Forgejo off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`): every HTTPS port
#      proxying to its web port, and, when docker-compose.yml publishes the
#      built-in SSH server, every TCP port forwarding to that SSH port
#   2. `docker compose down` — the container and its network go; the
#      repositories, SQLite DB and LFS objects in FORGEJO_DATA stay
#   3. keep .env, the data dir and the hidden admin marker
#      (~/services/forgejo/.admin-created), so ./setup.sh brings it back as
#      it was
#
# Usage:
#   ./teardown.sh            # safe remove: repos, .env and marker kept
#   ./teardown.sh --purge    # ALSO delete every repository, issue, wiki and
#                            # account (the data dir), the admin marker and
#                            # .env; asks you to type "forgejo" first.
#                            # Terminal only: the launcher's Remove button
#                            # never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="forgejo"
CONTAINER="forgejo"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
# setup.sh writes this marker at a fixed path (not under FORGEJO_DATA) once
# the admin account exists, and skips admin creation while it is there.
ADMIN_MARKER="$HOME/services/$NAME/.admin-created"

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
DATA_DIR="$(env_get FORGEJO_DATA)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"

# The built-in SSH server is off by default and docker-compose.yml leaves its
# port line commented out. Only when that line is live (in the compose file or
# an override Compose would also load) does 127.0.0.1:<ssh port> belong to
# this container, so only then are TCP Serve forwards to it this service's to
# remove. Otherwise a forward to that port is someone else's and stays.
SSH_PORT=""
ssh_line="$(for f in "$SERVICE_DIR/docker-compose.yml" "$SERVICE_DIR/docker-compose.override.yml"; do
  [ -f "$f" ] && sed 's/#.*//' "$f"
done | grep -E "^[[:space:]]*-[[:space:]]*[\"']?[^[:space:]]+:22[\"']?[[:space:]]*$" | head -1 || true)"
if [ -n "$ssh_line" ]; then
  host_part="$(printf '%s' "$ssh_line" | sed -e "s/^[[:space:]]*-[[:space:]]*//" -e "s/[\"'[:space:]]//g" -e 's/:22$//')"
  case "$host_part" in
    *'${FORGEJO_SSH_HOST_PORT'*) SSH_PORT="$(env_get FORGEJO_SSH_HOST_PORT)"; SSH_PORT="${SSH_PORT:-2222}" ;;
    *) SSH_PORT="${host_part##*:}" ;;
  esac
  case "$SSH_PORT" in
    ''|*[!0-9]*) warn "docker-compose.yml publishes SSH, but its host port could not be read ($host_part). TCP Serve forwards are left alone; check: $TAILSCALE serve status"
                 SSH_PORT="" ;;
  esac
fi
ok "$NAME: local :$LOCAL_PORT${SSH_PORT:+, ssh :$SSH_PORT}, data ${DATA_DIR:-(not set)}"

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

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""
PURGE_SHOW=""
PURGE_MARKER=""
FORGEJO_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  [ -n "$DATA_DIR" ] || die "FORGEJO_DATA is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "FORGEJO_DATA=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "FORGEJO_DATA=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # Is it there? `[ -e ]` is false both when it is gone and when a folder on
  # the way (e.g. a root-owned 0700 storage/) cannot be searched, and only
  # the first is "nothing to delete". So walk down from ~/services: a
  # component that is absent under a searchable parent means gone; one that
  # exists but cannot be searched hides the data, which then has to be
  # cleared through that folder by the cleanup container.
  data_state="present"
  hidden=""
  hidden_rest=""
  p="$HOME/services"
  rest="${DATA_DIR#"$HOME/services/"}"
  { [ -d "$p" ] && [ -x "$p" ]; } \
    || die "$p cannot be searched, so teardown cannot tell whether FORGEJO_DATA=$DATA_DIR is there. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed."
  while :; do
    case "$rest" in */*) ;; *) break ;; esac
    p="$p/${rest%%/*}"
    rest="${rest#*/}"
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      data_state="missing"; break
    fi
    [ -d "$p" ] || die "$p (on the way to FORGEJO_DATA=$DATA_DIR) is not a directory — refusing."
    if [ ! -x "$p" ]; then
      data_state="hidden"; hidden="$p"; hidden_rest="$rest"; break
    fi
  done
  if [ "$data_state" = "present" ] && [ ! -e "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ]; then
    data_state="missing"
  fi
  PURGE_BASE=""
  PURGE_REST=""
  if [ "$data_state" = "hidden" ]; then
    # The container mounts the unsearchable folder itself (real_dir resolves
    # it without entering it) and deletes only the path below it. That folder
    # must sit inside ~/services/forgejo, not be it: the marker lives there.
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_BASE="$(real_dir "$hidden")" \
      || die "$hidden cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed."
    case "$PURGE_BASE" in
      "$root/$NAME"/?*) ;;
      *) die "$hidden cannot be searched, so teardown cannot reach FORGEJO_DATA=$DATA_DIR or the admin marker. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed." ;;
    esac
    PURGE_REST="$hidden_rest"
  fi
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ "$data_state" = "present" ]; then
    [ -d "$DATA_DIR" ] || die "FORGEJO_DATA=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$DATA_DIR")" || die "DATA_DIR=$DATA_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "FORGEJO_DATA=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  PURGE_SHOW="${PURGE_DIR:-${PURGE_BASE:+$PURGE_BASE/$PURGE_REST}}"
  # The hidden admin marker has to go too: left behind, a fresh ./setup.sh
  # skips admin creation and hands back a login page with no account. It is
  # a file, but it goes through the same real_dir check as the data dir.
  if [ -e "$ADMIN_MARKER" ] || [ -L "$ADMIN_MARKER" ]; then
    [ -f "$ADMIN_MARKER" ] && [ ! -L "$ADMIN_MARKER" ] \
      || die "$ADMIN_MARKER is not a plain file — refusing. Remove it by hand if you are sure."
    PURGE_MARKER="$(real_dir "$ADMIN_MARKER")" \
      || die "$ADMIN_MARKER is not a real path inside $HOME/services/$NAME — refusing."
  fi
  # The cleanup container for files the container's root or git user owns is
  # the pinned image already on this box; a version tag Compose would read
  # differently is refused here, before anything changes.
  version="$(env_get FORGEJO_VERSION)"
  case "${version:-15}" in
    *[!A-Za-z0-9._-]*) die "FORGEJO_VERSION=$version in $ENV_FILE is not a plain image tag — refusing." ;;
  esac
  FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:${version:-15}"

  warn "--purge deletes ${PURGE_SHOW:-nothing (no data dir on disk)}, ${PURGE_MARKER:-no admin marker} and $ENV_FILE. This cannot be undone."
  warn "That is EVERY repository on this Forgejo, with its issues, pull requests, wikis, releases, LFS objects, and every account. Nothing else on this box has a copy."
  warn "Back it up first (Ctrl-C now, then, while the container is running):"
  warn "  docker exec -u git -w /tmp $CONTAINER forgejo dump -c /data/gitea/conf/app.ini --file /tmp/forgejo-dump.zip"
  warn "  docker cp $CONTAINER:/tmp/forgejo-dump.zip ./forgejo-dump-\$(date +%F).zip"
  warn "  (container already down? ./setup.sh first, or copy ${DATA_DIR} as-is)"
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
# alone with a warning. Never `serve reset`. A blank line or a TCP block
# header ends an HTTPS block, so a TCP forward listed after it is not
# mistaken for one of its handlers.
info "Unpublishing Tailscale Serve ports that point at $TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" '
  function flush() {
    if (port != "") {
      if (n > 0 && mine == n) print "off " port
      else if (mine > 0) print "mixed " port
    }
    port = ""; n = 0; mine = 0
  }
  /^[[:space:]]*$/ || /^(\|-- )?tcp:\/\// { flush(); next }
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

# TCP forwards to the SSH port (the `tailscale serve --tcp` step of the SSH
# recipe in docker-compose.yml). A TCP block opens with a `tcp://<name>:<port>
# (...)` line and its target is the `|-->` line; one forward per port, so
# there is no sharing to weigh.
if [ -n "$SSH_PORT" ]; then
  info "Unpublishing Tailscale Serve TCP ports that forward to 127.0.0.1:$SSH_PORT (SSH)"
  TCP_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="127.0.0.1:$SSH_PORT" '
    /^[[:space:]]*$/ { port = ""; next }
    { line = $0; sub(/^\|-- /, "", line) }
    line ~ /^tcp:\/\/[^ ]+ \(/ {
      split(line, a, " "); u = a[1]
      port = match(u, /:[0-9]+$/) ? substr(u, RSTART + 1) : ""
      next
    }
    port != "" && /^\|-->/ { f = $NF; sub(/^tcp:\/\//, "", f); if (f == t) print port; port = "" }')"
  tcp_off=0
  while read -r port; do
    [ -n "${port:-}" ] || continue
    "$TAILSCALE" serve --tcp="$port" off >/dev/null
    ok "Tailscale Serve: TCP :$port off"
    tcp_off=$((tcp_off + 1))
  done <<EOF
$TCP_PLAN
EOF
  [ "$tcp_off" -gt 0 ] || ok "No Tailscale Serve TCP forward points at 127.0.0.1:$SSH_PORT (already off)"
fi

# setup.sh installs no systemd unit or LaunchAgent (Docker's restart policy
# does that job). Anything on this box that mentions forgejo was added by
# hand, e.g. a backup timer, so it is named here and left exactly as it is.
for d in "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    if grep -qi forgejo "$f" 2>/dev/null; then
      warn "$f mentions forgejo but setup.sh did not create it, so teardown leaves it alone. Disable or remove it by hand if it should go too."
    fi
  done
done

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; repositories in $DATA_DIR kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging repositories and data"
  if [ -n "$PURGE_DIR" ]; then
    # The container starts as root and drops to its git user (remapped to
    # this user's uid by USER_UID), so most of the tree is yours but some of
    # it can be root-owned. Try the plain rm first; otherwise empty it with a
    # throwaway container of the pinned image already on this box (no pull,
    # no sudo), then remove the now-empty directory itself. A half-deleted
    # data dir is a failure, not a warning: .env is kept for the retry.
    rm -rf -- "$PURGE_DIR" 2>/dev/null || true
    if [ -e "$PURGE_DIR" ]; then
      info "Some files are owned by the container; clearing them with $FORGEJO_IMAGE"
      docker run --rm --pull never -v "$PURGE_DIR:/x" --entrypoint sh "$FORGEJO_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear container-owned files in $PURGE_DIR. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$PURGE_DIR" 2>/dev/null || true
      [ ! -e "$PURGE_DIR" ] || die "$PURGE_DIR is still there. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
    fi
  elif [ -n "$PURGE_BASE" ]; then
    # A folder on the way to the data cannot be searched by this user, so
    # the host cannot even see the data. The pinned image mounts that folder
    # and deletes only the path below it, refusing a symlink anywhere on that
    # path (it would resolve inside the container, not on this box), then
    # proves the path is gone and drops the emptied folders it went through.
    info "$PURGE_BASE cannot be searched by this user; deleting $PURGE_SHOW with $FORGEJO_IMAGE"
    docker run --rm --pull never -v "$PURGE_BASE:/x" --entrypoint sh "$FORGEJO_IMAGE" \
      -c 'set -f; r=$1; p=/x; IFS=/; for c in $r; do p=$p/$c; [ ! -L "$p" ] || exit 3; done; unset IFS
          rm -rf -- "/x/$r" && [ ! -e "/x/$r" ] || exit 1
          d=$(dirname "/x/$r"); while [ "$d" != /x ]; do rmdir -- "$d" 2>/dev/null || break; d=$(dirname "$d"); done' \
      sh "$PURGE_REST" >/dev/null 2>&1 \
      || die "Could not delete $PURGE_SHOW through $PURGE_BASE. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. .env and the admin marker were kept."
    # The emptied folder itself: removing it needs only the parent's
    # permissions, and rmdir never removes anything that is not empty.
    rmdir -- "$PURGE_BASE" 2>/dev/null || true
  fi
  [ -z "$PURGE_MARKER" ] || rm -f -- "$PURGE_MARKER"
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted ${PURGE_SHOW:-(no data dir)}, ${PURGE_MARKER:-(no admin marker)} and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its repositories are gone. ./setup.sh starts fresh (new admin account, new password).\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Repositories, .env and the admin marker are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete every repository too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
