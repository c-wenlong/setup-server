#!/usr/bin/env bash
#
# teardown.sh — take Hermes Agent off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — the container and its network go; the agent's
#      data dir (config, keys, sessions, skills, memories) stays
#   3. keep .env and the data dir, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh             # safe remove: data and .env kept
#   ./teardown.sh --purge     # ALSO delete the data dir and .env; asks you to
#                             # type "hermes-agent" first. Terminal only: the
#                             # launcher's Remove button never passes it.
#
# A native Hermes install is never in scope: ~/.hermes and a hand-installed
# hermes-gateway systemd unit are named and left alone, not stopped.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="hermes-agent"
CONTAINER="hermes-agent"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) die "Unknown option: $1 (usage: ./teardown.sh [--purge])" ;;
esac
[ "$#" -le 1 ] || die "Too many arguments (usage: ./teardown.sh [--purge])"

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
require_docker_compose
resolve_tailscale

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

# Real path of a purge target WITHOUT entering it: a container-owned dir may
# be unreadable to this user, which is exactly when the purge needs the
# cleanup container. Resolve the parent, append the name. Refused (non-zero)
# unless the result is ~/services/$NAME itself or inside it, with ~/services
# a real directory under $HOME; a symlinked leaf, a `.`/`..` component, a
# newline or a colon (which would split a list or a -v mount) is never
# accepted.
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
env_lint
LOCAL_PORT="$(env_get LOCAL_PORT)"
DATA_DIR="$(env_get HERMES_DATA)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, data ${DATA_DIR:-(not set)}"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` acts
# on. setup.sh never sets them, so refuse rather than tear down something it
# did not start.
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
HERMES_IMAGE=""
if [ "$PURGE" -eq 1 ]; then
  [ -n "$DATA_DIR" ] || die "HERMES_DATA is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "HERMES_DATA=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "HERMES_DATA=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  dir_state HERMES_DATA "$DATA_DIR"
  [ "$DIR_STATE" != "hidden" ] \
    || die "$HIDDEN_DIR cannot be searched, so teardown cannot tell whether HERMES_DATA=$DATA_DIR is there (and will not delete .env while it might be). Run: sudo rm -rf $DATA_DIR   then ./teardown.sh --purge again. Nothing was changed."
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$DATA_DIR" ] || die "HERMES_DATA=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$DATA_DIR")" || die "DATA_DIR=$DATA_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "HERMES_DATA=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  # The cleanup container for files the container's hermes user owns is the
  # pinned image already on this box; a version tag Compose would read
  # differently is refused here, before anything changes.
  version="$(env_get HERMES_VERSION)"
  case "${version:-v0.22.5}" in
    *[!A-Za-z0-9._-]*) die "HERMES_VERSION=$version in $ENV_FILE is not a plain image tag — refusing." ;;
  esac
  HERMES_IMAGE="nousresearch/hermes-agent:${version:-v0.22.5}"
  warn "--purge deletes ${PURGE_DIR:-nothing (no data dir on disk)} and $ENV_FILE. This cannot be undone."
  warn "That is every config, API key, session, skill and memory this agent"
  warn "has accumulated in the container — nothing else has a copy."
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
    # tailscaled serializes Serve-config writes; a concurrent teardown or
    # publish fails with "etag mismatch", so retry the off a few times.
    tries=0
    until "$TAILSCALE" serve --https="$port" off >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ "$tries" -lt 5 ] || die "Tailscale Serve: could not unpublish HTTPS :$port (config busy — re-run teardown.sh)"
      sleep 2
    done
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

# setup.sh installs no systemd unit or LaunchAgent (Docker's restart policy
# does that job). A hand-installed native Hermes gateway is exactly the case
# this box has: it is named here and left exactly as it is.
for d in "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    if grep -qi hermes "$f" 2>/dev/null; then
      warn "$f mentions hermes but setup.sh did not create it, so teardown leaves it alone. Disable or remove it by hand if it should go too."
    fi
  done
done

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; data in $DATA_DIR kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging agent data"
  if [ -n "$PURGE_DIR" ]; then
    # The container runs as a remapped hermes user, so most of the tree is
    # yours but some of it can be container-owned. Try the plain rm first;
    # otherwise empty it with a throwaway container of the pinned image
    # already on this box (no pull, no sudo), then remove the now-empty
    # directory itself. A half-deleted data dir is a failure, not a warning:
    # .env is kept for the retry.
    rm -rf -- "$PURGE_DIR" 2>/dev/null || true
    if [ -e "$PURGE_DIR" ]; then
      info "Some files are owned by the container; clearing them with $HERMES_IMAGE"
      docker run --rm --pull never -v "$PURGE_DIR:/x" --entrypoint sh "$HERMES_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear container-owned files in $PURGE_DIR. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$PURGE_DIR" 2>/dev/null || true
      [ ! -e "$PURGE_DIR" ] || die "$PURGE_DIR is still there. Run: sudo rm -rf $PURGE_DIR   then ./teardown.sh --purge again. .env was kept."
    fi
  fi
  rm -f -- "$ENV_FILE"
  ok "Deleted ${PURGE_DIR:-(no data dir)} and $ENV_FILE"
  # The state dir only held the data dir; drop it when it is now empty.
  rmdir "$HOME/services/$NAME" 2>/dev/null || true
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its data is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
