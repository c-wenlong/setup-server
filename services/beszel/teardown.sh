#!/usr/bin/env bash
#
# teardown.sh: take Beszel (hub container + native agent) off this box.
# Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at the hub, found from
#      `tailscale serve status` (never `serve reset`)
#   2. stop the agent first (it would only dial a hub that is gone):
#        Linux: systemctl --user disable --now beszel-agent.service
#        macOS: launchctl bootout + disable com.henrygd.beszel-agent
#   3. `docker compose down` for the hub: the container goes, the data stays
#   4. keep .env, the hub data dir, the agent binary and its unit/plist, so
#      ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: data, .env, agent files kept
#   ./teardown.sh --purge    # ALSO delete the hub data dir, .env, the agent
#                            # binary and the unit/plist setup.sh wrote; asks
#                            # you to type "beszel" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Never touches lingering, the docker group, the Tailscale operator, the
# hub image, or any unit setup.sh did not write. Reads the port and data
# path from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="beszel"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
# Fixed paths setup.sh writes (not configurable there, so not read from .env).
BIN="$HOME/.local/bin/beszel-agent"
UNIT_NAME="beszel-agent.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
LABEL="com.henrygd.beszel-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_LOG="$HOME/Library/Logs/beszel-agent.log"

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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (the agent is a systemd user unit)."
else
  command -v launchctl >/dev/null || die "launchctl is missing (the agent is a launchd LaunchAgent)."
fi
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
PORT="$(env_get BESZEL_PORT)"
DATA_DIR="$(env_get BESZEL_VOLUME)"
case "$PORT" in ''|*[!0-9]*) die "BESZEL_PORT in $ENV_FILE is missing or not numeric (got: $PORT)";; esac
# docker-compose.yml mounts ${BESZEL_VOLUME:?}, so `down` cannot even parse
# the project without it. Say so now instead of failing halfway.
[ -n "$DATA_DIR" ] || die "BESZEL_VOLUME is missing from $ENV_FILE (docker-compose.yml needs it) — nothing was changed."
TARGET="http://127.0.0.1:$PORT"
ok "$NAME: hub on local :$PORT, data $DATA_DIR"

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


# Other user units that mention beszel but are not the one setup.sh writes
# (a timer, a backup job, a hand-made unit): never touched, only named.
# Top-level files only, so the *.wants/ links systemctl manages are skipped.
if [ -d "$UNIT_DIR" ]; then
  others="$(find "$UNIT_DIR" -maxdepth 1 -type f ! -name "$UNIT_NAME" -exec grep -l -i beszel {} + 2>/dev/null || true)"
  if [ -n "$others" ]; then
    while IFS= read -r f; do
      warn "$(basename "$f") mentions beszel but setup.sh did not create it, so it is left alone."
    done <<EOF_OTHERS
$others
EOF_OTHERS
  fi
fi

# The agent files setup.sh writes, and only if they still look like its own:
# a unit or plist someone rewrote, or a binary that is a symlink to their own
# build, is left in place on --purge.
unit_is_ours() {
  [ -f "$UNIT" ] && [ ! -L "$UNIT" ] \
    && grep -qx 'Description=Beszel monitoring agent' "$UNIT" \
    && grep -qxF "ExecStart=$BIN" "$UNIT"
}
plist_is_ours() {
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    && grep -qF "<key>Label</key><string>$LABEL</string>" "$PLIST" \
    && grep -qF "<string>$BIN</string>" "$PLIST"
}

# systemd's own view of the agent unit, whether or not its file is still on
# disk: a unit file deleted while the agent ran leaves it loaded and
# running. Sets U_ACTIVE; fails when systemd cannot be asked.
U_ACTIVE=""
unit_probe() {
  local out
  U_ACTIVE=""
  out="$(systemctl --user show -p LoadState -p ActiveState -- "$UNIT_NAME" 2>/dev/null)" || return 1
  U_ACTIVE="$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p')"
  [ -n "$U_ACTIVE" ]
}
unit_running() { case "$U_ACTIVE" in inactive|failed) return 1 ;; *) return 0 ;; esac; }

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""
PURGE_BASE=""
PURGE_REST=""
PURGE_SHOW=""
CLEAN_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  # The hub image is FROM scratch (no sh), so any cleanup container uses a
  # small base image that is ALREADY on this box (no pull). Picked here,
  # before anything changes, so a hidden data dir can be refused up front.
  for img in alpine:3 alpine:latest busybox:latest; do
    if docker image inspect "$img" >/dev/null 2>&1; then CLEAN_IMAGE="$img"; break; fi
  done
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "BESZEL_VOLUME=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "BESZEL_VOLUME=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  dir_state BESZEL_VOLUME "$DATA_DIR"
  if [ "$DIR_STATE" = "hidden" ]; then
    # The cleanup container mounts the unsearchable folder itself (real_dir
    # resolves it without entering it) and deletes only the path below it,
    # so that folder must sit strictly inside ~/services/beszel.
    PURGE_BASE="$(real_dir "$HIDDEN_DIR")" \
      || die "$HIDDEN_DIR cannot be searched and is not a real directory inside $HOME/services/$NAME. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    case "$PURGE_BASE" in
      "$root/$NAME"/?*) ;;
      *) die "$HIDDEN_DIR cannot be searched, so teardown cannot reach BESZEL_VOLUME=$DATA_DIR. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed." ;;
    esac
    [ -n "$CLEAN_IMAGE" ] \
      || die "$HIDDEN_DIR cannot be searched and no alpine/busybox image is on this box to reach BESZEL_VOLUME=$DATA_DIR. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed."
    PURGE_REST="$HIDDEN_REST"
  fi
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$DATA_DIR" ] || die "BESZEL_VOLUME=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$DATA_DIR")" || die "BESZEL_VOLUME=$DATA_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "BESZEL_VOLUME=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  # No unit file means the stop step has nothing to disable; the agent may
  # still be running from it. Purge only once systemd can say.
  if [ "$OS" = "Linux" ] && [ ! -e "$UNIT" ] && [ ! -L "$UNIT" ]; then
    unit_probe || die "No $UNIT, and systemd could not say whether $UNIT_NAME is still running (systemctl --user show failed) — refusing to purge. Nothing was changed."
  fi
  agent_files="$BIN"
  if [ "$OS" = "Linux" ]; then agent_files="$agent_files, $UNIT"; else agent_files="$agent_files, $PLIST"; fi
  PURGE_SHOW="${PURGE_DIR:-${PURGE_BASE:+$PURGE_BASE/$PURGE_REST}}"
  warn "--purge deletes ${PURGE_SHOW:-nothing (no hub data dir on disk)}, $ENV_FILE and the agent ($agent_files). This cannot be undone."
  warn "That is all metric history, alert settings, the admin account and the hub's agent key."
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

# ---------------------------------------------------------------- agent
# Stopped before the hub, as the launcher does: the agent only waits for the
# hub to dial it, so nothing is lost by stopping it first.
if [ "$OS" = "Linux" ]; then
  if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Stopping and disabling the agent ($UNIT_NAME)"
    systemctl --user disable --now "$UNIT_NAME" >/dev/null
    ok "Agent stopped and disabled; unit file and binary kept"
  elif ! unit_probe; then
    warn "No $UNIT, and systemd could not say whether $UNIT_NAME is still running. If it is: systemctl --user stop $UNIT_NAME"
  elif unit_running; then
    # The name is setup.sh's own (no package ships a beszel-agent user unit).
    info "$UNIT is gone but the agent is still running from it; stopping it (systemctl --user stop)"
    systemctl --user stop "$UNIT_NAME"
    ok "Agent stopped"
  else
    ok "No $UNIT and no agent running (already removed)"
  fi
else
  info "Unloading the agent LaunchAgent ($LABEL)"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # bootout alone would come back at the next login (RunAtLoad); disable is
  # the launchd twin of `systemctl disable`. setup.sh re-enables it.
  launchctl disable "gui/$(id -u)/$LABEL"
  ok "Agent unloaded and disabled; plist and binary kept"
fi

# ---------------------------------------------------------------- hub
info "Stopping and removing the hub container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Hub removed; data in $DATA_DIR kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  if [ "$OS" = "Linux" ]; then
    unit_probe || die "Could not ask systemd whether $UNIT_NAME stopped. Nothing was deleted and $ENV_FILE is kept; re-run ./teardown.sh --purge."
    ! unit_running || die "$UNIT_NAME is still running. Nothing was deleted and $ENV_FILE is kept: stop it (systemctl --user stop $UNIT_NAME) and re-run ./teardown.sh --purge."
  fi
  info "Purging hub data"
  if [ -n "$PURGE_DIR" ]; then
    # The hub runs as root, so its database files are root-owned and a plain
    # rm cannot clear them all. Try the plain rm first; otherwise empty the
    # dir with a throwaway container of CLEAN_IMAGE (picked before the
    # confirmation; no pull, no sudo), then remove the now-empty directory.
    rm -rf -- "$PURGE_DIR" 2>/dev/null || true
    if [ -e "$PURGE_DIR" ]; then
      [ -n "$CLEAN_IMAGE" ] || die "Some files in $PURGE_DIR are root-owned and no alpine/busybox image is on this box to clear them. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      info "Some files are root-owned; clearing them with $CLEAN_IMAGE"
      docker run --rm --pull never -v "$PURGE_DIR:/x" --entrypoint sh "$CLEAN_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear root-owned files in $PURGE_DIR. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$PURGE_DIR" 2>/dev/null || true
      [ ! -e "$PURGE_DIR" ] || die "$PURGE_DIR is still there. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
    fi
    # Drop an emptied parent left between ~/services/beszel and the data dir.
    # Only ever a strict child of ~/services; rmdir never removes a non-empty
    # directory.
    parent="$(dirname "$PURGE_DIR")"
    case "$parent" in
      "$(cd "$HOME/services" && pwd -P)"/?*) rmdir -- "$parent" 2>/dev/null || true ;;
    esac
  elif [ -n "$PURGE_BASE" ]; then
    info "$PURGE_BASE cannot be searched by this user; deleting $PURGE_SHOW with $CLEAN_IMAGE"
    hidden_rm "$PURGE_BASE" "$PURGE_REST" "$CLEAN_IMAGE" \
      || die "Could not delete $PURGE_SHOW through $PURGE_BASE. Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. .env was kept."
  fi

  info "Purging the agent"
  if [ "$OS" = "Linux" ]; then
    if unit_is_ours; then
      rm -f -- "$UNIT"
      systemctl --user daemon-reload
      ok "Deleted $UNIT"
    elif [ -e "$UNIT" ]; then
      warn "$UNIT was not written by setup.sh (or was edited), so it is kept."
    fi
  else
    if plist_is_ours; then
      rm -f -- "$PLIST" "$AGENT_LOG"
      ok "Deleted $PLIST and $AGENT_LOG"
    elif [ -e "$PLIST" ]; then
      warn "$PLIST was not written by setup.sh (or was edited), so it is kept."
    fi
  fi
  if [ -L "$BIN" ]; then
    warn "$BIN is a symlink, not the binary setup.sh downloaded, so it is kept."
  elif [ -f "$BIN" ]; then
    rm -f -- "$BIN"
    ok "Deleted $BIN"
  fi

  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted ${PURGE_SHOW:-(no hub data dir)} and $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data, .env and the agent files are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
