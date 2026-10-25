#!/usr/bin/env bash
#
# teardown.sh — take OpenHands Agent Canvas off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` on the `openhands` project (the same compose
#      files setup.sh uses, creds overlay included) — the container and its
#      network go, the data directory stays
#   3. keep .env, the data dir, the creds overlay, ~/agent-workspaces and
#      every ACL setup.sh granted, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the data dir (OPENHANDS_DATA) and
#                            # .env; asks you to type "openhands" first.
#                            # Terminal only: the launcher's Remove button
#                            # never passes it.
#
# Never touched, purge or not: ~/.claude and ~/.codex (the creds overlay only
# bind-mounts them), ~/agent-workspaces (shared with Paperclip; its uid 10001
# ACLs are printed for you to drop, never changed), Paperclip's files,
# containers and units, and any container not in the `openhands` compose
# project.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="openhands"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
CREDS_FILE="$SERVICE_DIR/docker-compose.creds.yml"
PROJECT="openhands"   # `name:` in docker-compose.yml

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

# Where an absolute path really lands, symlinks and all, whether or not it
# exists yet: the deepest part that exists is resolved with `pwd -P` and the
# missing rest is appended (the parent-resolve idea of real_dir, applied
# upwards). A symlinked file leaf is followed hop by hop. Refused (non-zero)
# for a relative path, a `.`/`..` component, a newline, a path that runs
# through a file, or a symlink that points nowhere.
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
  if [ -d "$p" ]; then
    dir="$(cd "$p" && pwd -P)" || return 1
  else
    [ -z "$rest" ] || return 1
    dir="$(cd "$(dirname "$p")" && pwd -P)" || return 1
    leaf="$(basename "$p")"
    while [ -L "$dir/$leaf" ]; do
      hops=$((hops + 1)); [ "$hops" -le 40 ] || return 1
      t="$(readlink "$dir/$leaf")" || return 1
      case "$t" in /*) ;; *) t="$dir/$t" ;; esac
      dir="$(cd "$(dirname "$t")" && pwd -P)" || return 1
      leaf="$(basename "$t")"
    done
    [ -e "$dir/$leaf" ] || return 1
    rest="/$leaf"
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

# ~/ and $HOME / ${HOME} in a mount source, as Compose expands them. A
# relative source is relative to the project directory (Compose's rule).
expand_src() {
  local s="$1"
  case "$s" in \~/*) s="$HOME/${s#\~/}" ;; esac
  s="${s//\$\{HOME\}/$HOME}"; s="${s//\$HOME/$HOME}"
  case "$s" in /*) ;; *) s="$SERVICE_DIR/${s#./}" ;; esac
  printf '%s' "$s"
}

LOCAL_PORT="$(env_get OPENHANDS_PORT)"
DATA_DIR="$(env_get OPENHANDS_DATA)"
WORKSPACES="$(env_get AGENT_WORKSPACES)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "OPENHANDS_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, data ${DATA_DIR:-(not set)}"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# The compose files setup.sh starts the stack with: the base file, plus the
# creds overlay when setup.sh wrote one. `name: openhands` fixes the project,
# so `down` only ever reaches that project's container and network.
COMPOSE=(docker compose --project-directory "$SERVICE_DIR" -f "$SERVICE_DIR/docker-compose.yml")
[ ! -f "$CREDS_FILE" ] || COMPOSE+=(-f "$CREDS_FILE")

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# Containers. `compose down` removes what is in the `openhands` project and
# nothing else. setup.sh gives Canvas no docker socket and configures no
# runtime-container prefix or label, so no other container is provably
# OpenHands': anything else whose name says openhands (a container still in
# the old paperclip-openhands project, an OpenHands 0.x `openhands-runtime-*`
# sandbox, something hand-made) is listed and left alone.
CONTAINERS="$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' 2>&1)" \
  || die "Could not list Docker containers: $CONTAINERS — nothing was changed."
AMBIGUOUS="$(printf '%s\n' "$CONTAINERS" | awk -F'|' -v p="$PROJECT" '
  $1 != "" && $2 != p && tolower($1) ~ /openhands/ { print $1 " (compose project: " ($2 == "" ? "none" : $2) ")" }')"
if [ -n "$AMBIGUOUS" ]; then
  while IFS= read -r c; do
    warn "Container $c is not in the $PROJECT compose project, so teardown leaves it alone."
  done <<EOF
$AMBIGUOUS
EOF
fi

# setup.sh installs no systemd unit or LaunchAgent. One that mentions
# openhands came from somewhere else (Paperclip, a hand-made unit): name it,
# never stop, disable or delete it. Read-only listing.
for udir in "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents"; do
  [ -d "$udir" ] || continue
  for f in "$udir"/*; do
    [ -f "$f" ] || continue
    if grep -qi openhands "$f" 2>/dev/null; then
      warn "$f mentions openhands, but setup.sh did not create it, so teardown leaves it alone."
    fi
  done
done

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""
OH_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  if [ -n "$AMBIGUOUS" ]; then
    die "--purge will not run while the containers above exist: teardown cannot tell whether they hold OpenHands state. Remove them by hand once you know whose they are (docker rm -f NAME; ./setup.sh adopts one left in paperclip-openhands), then re-run. Nothing was changed."
  fi
  [ -n "$DATA_DIR" ] || die "OPENHANDS_DATA is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "OPENHANDS_DATA=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "OPENHANDS_DATA=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ -e "$DATA_DIR" ]; then
    [ -d "$DATA_DIR" ] || die "OPENHANDS_DATA=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$DATA_DIR")" || die "OPENHANDS_DATA=$DATA_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "OPENHANDS_DATA=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  if [ -n "$PURGE_DIR" ]; then
    # The project tree is the user's work and is never purged. setup.sh
    # accepts any AGENT_WORKSPACES, including one inside the data dir (or
    # one holding it), so compare where both really land, symlinks
    # resolved, before anything changes.
    ws="${WORKSPACES:-$HOME/agent-workspaces}"
    case "$ws" in \~/*) ws="$HOME/${ws#\~/}" ;; esac
    ws_real="$(phys_path "$ws")" \
      || die "AGENT_WORKSPACES=$ws in $ENV_FILE cannot be resolved to a real path (relative, a '.' or '..' part, or a broken symlink), so teardown cannot prove --purge spares your projects. Refusing; nothing was changed."
    if paths_overlap "$ws_real" "$PURGE_DIR"; then
      die "AGENT_WORKSPACES=$ws (your projects) resolves to $ws_real, which overlaps $PURGE_DIR, the data dir --purge deletes. Refusing; nothing was changed. Move the workspace or OPENHANDS_DATA so neither holds the other, then re-run."
    fi

    # Host credentials are bind-mounted, never copied. However ~/.claude,
    # ~/.codex or any other bind source is reached (a symlink, a hand-edited
    # overlay), it must not sit inside what is about to be deleted. The
    # bind list comes from `compose config` (read-only; every syntax already
    # resolved by Compose itself). Where that is unavailable, only the short
    # `- SOURCE:TARGET` lines setup.sh writes are read from the overlay, and
    # anything else in it stops the purge rather than being skipped.
    tab="$(printf '\t')"
    nl='
'
    srcs="$HOME/.claude${tab}host credentials
$HOME/.codex${tab}host credentials"
    binds=""
    cfg="$("${COMPOSE[@]}" config --format json 2>/dev/null)" || cfg=""
    if [ -n "$cfg" ]; then
      binds="$(printf '%s\n' "$cfg" | awk '
        function val(line) { sub(/^[[:space:]]*"[a-z_]+": "/, "", line); sub(/",?[[:space:]]*$/, "", line); return line }
        /^[[:space:]]*"type": "/   { type = val($0); src = ""; next }
        /^[[:space:]]*"source": "/ { src = $0; next }
        /^[[:space:]]*"target": "/ {
          if (type == "bind" && src != "") {
            s = val(src); t = val($0)
            if (index(s, "\\") || index(t, "\\") || s !~ /^\//) { print "BAD"; exit }
            print s "\t" t
          }
          type = ""; src = ""
        }')"
      # Pretty-printed JSON is what this reads. If the data mount from
      # docker-compose.yml is not in what it found, the output was some
      # other shape: fall back to the overlay rather than trust a short list.
      case "$binds" in
        BAD*|*"$nl"BAD*) die "compose config lists a bind mount whose path teardown cannot read safely (an escape or a relative path). Refusing --purge; nothing was changed." ;;
      esac
      printf '%s\n' "$binds" | grep -q "${tab}/home/openhands/\.openhands\$" || binds=""
    fi
    if [ -z "$binds" ] && [ -f "$CREDS_FILE" ]; then
      binds="$(awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*(#.*)?$/                  { next }
        /^services:[[:space:]]*$/               { next }
        /^[[:space:]]+openhands:[[:space:]]*$/  { next }
        /^[[:space:]]+volumes:[[:space:]]*$/    { next }
        /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
          v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
          q = substr(v, 1, 1)
          if (q == "\"" || q == "\047") {
            if (length(v) < 2 || substr(v, length(v), 1) != q) { print "BAD " NR; exit }
            v = substr(v, 2, length(v) - 2)
          }
          if (index(v, "\"") || index(v, "\047") || index(v, "\\") || index(v, "#") || index(v, "\t")) { print "BAD " NR; exit }
          n = split(v, part, ":")
          if (n < 2 || n > 3 || part[2] !~ /^\//) { print "BAD " NR; exit }
          if (part[1] !~ /^(\/|~\/|\.\/|\$HOME(\/|$)|\$\{HOME\}(\/|$))/) { print "BAD " NR; exit }
          print part[1] "\t" part[2]; next
        }
        { print "BAD " NR; exit }' "$CREDS_FILE")"
      case "$binds" in
        "BAD "*|*"$nl""BAD "*) die "$CREDS_FILE line ${binds##*BAD } is not a short '- SOURCE:TARGET' mount with an absolute, ~/ or \$HOME source (the only form setup.sh writes), and compose config could not list the mounts for it. teardown will not guess whether that mount reaches the data dir. Refusing --purge; nothing was changed." ;;
      esac
    fi
    [ -z "$binds" ] || srcs="$srcs
$binds"
    while IFS="$tab" read -r src target; do
      [ -n "$src" ] || continue
      src="$(expand_src "$src")"
      case "$src" in *'$'*) die "Mount source $src (at $target) uses a variable teardown does not expand. Refusing --purge; nothing was changed." ;; esac
      [ -e "$src" ] || continue
      sreal="$(phys_path "$src")" || die "Cannot resolve mount source $src (at $target). Refusing --purge; nothing was changed."
      # The data mount itself is what --purge is for.
      [ "$target" = /home/openhands/.openhands ] && [ "$sreal" = "$PURGE_DIR" ] && continue
      case "$sreal/" in
        "$PURGE_DIR"/*) die "$src (mounted into the container at $target) resolves to $sreal, inside $PURGE_DIR. Refusing to delete it; move it out first. Nothing was changed." ;;
      esac
    done <<EOF
$srcs
EOF
    # The data dir is written by the container user (uid 10001), so a plain
    # rm can fail on it. The fallback cleanup uses the image already on this
    # box; its tag comes from .env and must be a plain tag.
    OH_VERSION="$(env_get OPENHANDS_VERSION)"
    [ -n "$OH_VERSION" ] || OH_VERSION="latest"
    case "$OH_VERSION" in
      *[!A-Za-z0-9._-]*) die "OPENHANDS_VERSION=$OH_VERSION in $ENV_FILE is not a plain image tag — refusing." ;;
    esac
    OH_IMAGE="ghcr.io/openhands/agent-canvas:$OH_VERSION"
  fi
  warn "--purge deletes ${PURGE_DIR:-nothing (no data dir on disk)} and $ENV_FILE. This cannot be undone."
  warn "That is every OpenHands setting, stored secret and conversation. ${WORKSPACES:-~/agent-workspaces}, ~/.claude and ~/.codex are kept."
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
ok "Container removed; data in ${DATA_DIR:-(not set)} kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging data"
  if [ -n "$PURGE_DIR" ]; then
    # Try the plain rm first (a dir the container never wrote is all yours);
    # otherwise empty it as root inside a throwaway container of the image
    # already on this box (no pull, no sudo), then remove the empty dir.
    rm -rf -- "$PURGE_DIR" 2>/dev/null || true
    if [ -e "$PURGE_DIR" ]; then
      info "Some files belong to the container user; clearing them with $OH_IMAGE"
      docker run --rm --pull never --user 0:0 -v "$PURGE_DIR:/x" --entrypoint sh "$OH_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear the container-owned files in $PURGE_DIR. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$PURGE_DIR" 2>/dev/null || true
      [ ! -e "$PURGE_DIR" ] || die "$PURGE_DIR is still there. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
    fi
  fi
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted ${PURGE_DIR:-(no data dir)} and $ENV_FILE"

  # setup.sh granted uid 10001 write on the shared workspace tree. Those dirs
  # are kept (Paperclip and your projects live there), so their grants are
  # printed for you to drop, never changed here.
  hints=""
  if [ -n "$WORKSPACES" ]; then
    for d in "$WORKSPACES" "$WORKSPACES/openhands-test"; do
      [ -d "$d" ] || continue
      if command -v getfacl >/dev/null 2>&1 \
         && getfacl -p "$d" 2>/dev/null | grep -q '^\(default:\)\{0,1\}user:10001:'; then
        hints="$hints$(printf '    setfacl -x u:10001 %q\n    setfacl -d -x u:10001 %q' "$d" "$d")
"
      elif [ -n "$(find "$d" -maxdepth 0 -perm -0002 2>/dev/null)" ]; then
        hints="$hints$(printf '    chmod o-w %q    # setup.sh opened it up where setfacl was missing' "$d")
"
      fi
    done
  fi
  if [ -n "$hints" ]; then
    warn "Kept, with the container uid 10001 still allowed to write. Once nothing else needs that:"
    printf '%s' "$hints"
  fi
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
  echo "  Kept: ${WORKSPACES:-~/agent-workspaces} (incl. openhands-test), ~/.claude, ~/.codex."
  [ ! -f "$CREDS_FILE" ] || echo "  Kept: $CREDS_FILE (mount paths only; delete it to stop mounting ~/.claude / ~/.codex)."
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
