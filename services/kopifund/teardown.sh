#!/usr/bin/env bash
#
# teardown.sh — take Kopifund off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish + timer, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. stop the sync timer and remove its unit/LaunchAgent
#   3. `docker compose down` — the container and its network go
#   4. keep .env, ~/services/kopifund and the data folder, so ./setup.sh
#      brings it back as it was
#
# The data folder ~/.kopifund is NEVER deleted, not even by --purge: it is
# an unlocked git-crypt clone of kopifund-hub shared with the Mac — the
# upstream remote IS the backup. --purge deletes only ~/services/kopifund
# (the source clone, sync script, state) and .env. If the data folder must
# go too, that is a separate, deliberate `rm -rf ~/.kopifund`.
#
# Usage:
#   ./teardown.sh            # safe remove: everything restorable kept
#   ./teardown.sh --purge    # ALSO delete ~/services/kopifund and .env;
#                            # asks you to type "kopifund" first
#
# Reads ports and paths from .env and refuses to guess when it is missing.

set -euo pipefail

NAME="kopifund"
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

# Real path of a purge target WITHOUT entering it: a root-owned dir may be
# unreadable to this user, which is exactly when the purge needs the cleanup
# container. Resolve the parent, append the name. Refused (non-zero) unless
# the result is ~/services/$NAME itself or inside it, with ~/services a real
# directory under $HOME; a symlinked leaf, a `.`/`..` component, a newline or
# a colon is never accepted.
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
# folder on the way cannot be searched, and only the first means "nothing to
# delete". So walk down from ~/services: a component absent under a
# searchable parent means gone (DIR_STATE=missing); one that exists but
# cannot be searched hides the target (DIR_STATE=hidden).
DIR_STATE=""
HIDDEN_DIR=""
HIDDEN_REST=""
dir_state() {
  local var="$1" target="$2" p="$HOME/services" rest
  rest="${target#"$HOME/services/"}"
  DIR_STATE="present"; HIDDEN_DIR=""; HIDDEN_REST=""
  while :; do
    if [ ! -e "$p" ]; then
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
SVC_HOME="$(env_get SERVICE_HOME)"
DATA_DIR="$(env_get KOPIFUND_DATA)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, home ${SVC_HOME:-(not set)}, data ${DATA_DIR:-(not set)}"

# Compose reads COMPOSE_* from .env and the shell; any of them would change
# which stack `down` acts on. setup.sh never sets them, so refuse rather
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
if [ "$PURGE" -eq 1 ]; then
  [ -n "$SVC_HOME" ] || die "SERVICE_HOME is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$SVC_HOME" in */) SVC_HOME="${SVC_HOME%/}" ;; *) break ;; esac; done
  case "$SVC_HOME" in *..*) die "SERVICE_HOME=$SVC_HOME contains '..' — refusing." ;; esac
  case "$SVC_HOME" in
    "$HOME/services/"?*) ;;
    *) die "SERVICE_HOME=$SVC_HOME is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # The synced data folder must never sit inside the purge target.
  case "${DATA_DIR:-}/" in
    "$SVC_HOME"/*) die "KOPIFUND_DATA=$DATA_DIR sits inside the purge target — that data folder is the shared kopifund-hub clone and is never deleted by teardown. Move it out, then re-run." ;;
  esac
  dir_state SERVICE_HOME "$SVC_HOME"
  [ "$DIR_STATE" != "hidden" ] \
    || die "$HIDDEN_DIR cannot be searched, so teardown cannot tell whether SERVICE_HOME=$SVC_HOME is there (and will not delete .env while it might be). Run: sudo rm -rf $SVC_HOME   then ./teardown.sh --purge again. Nothing was changed."
  if [ "$DIR_STATE" = "present" ]; then
    [ -d "$SVC_HOME" ] || die "SERVICE_HOME=$SVC_HOME is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$SVC_HOME")" || die "SERVICE_HOME=$SVC_HOME is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "SERVICE_HOME=$SVC_HOME resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
  fi
  warn "--purge deletes ${PURGE_DIR:-nothing (service home absent)} and $ENV_FILE. The data folder ${DATA_DIR:-~/.kopifund} is KEPT — always."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's local port,
# and nothing else: ports are found from what Serve actually publishes, not
# from what .env says was published. A port shared with another handler is
# left alone with a warning. Never `serve reset`.
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
if [ "$kept" -gt 0 ]; then
  warn "$kept shared HTTPS port(s) still route to $TARGET (left on, see above); $unpublished port(s) unpublished."
elif [ "$unpublished" -eq 0 ]; then
  ok "Nothing on Tailscale Serve points at $TARGET (already off)"
fi

# ------------------------------------------------------------- sync timer
info "Stopping the sync timer"
if [ "$OS" = "Linux" ]; then
  systemctl --user disable --now kopifund-sync.timer >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/kopifund-sync.timer" \
        "$HOME/.config/systemd/user/kopifund-sync.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  ok "Timer removed (systemd user)"
else
  launchctl bootout "gui/$(id -u)/com.kopifund.sync" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/com.kopifund.sync.plist"
  ok "LaunchAgent removed (com.kopifund.sync)"
fi

# ---------------------------------------------------------------- stop
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; data in ${DATA_DIR:-~/.kopifund} kept (it is the hub clone — the backup, not a leftover)"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging service home"
  [ -z "$PURGE_DIR" ] || rm -rf -- "$PURGE_DIR"
  rm -f -- "$ENV_FILE"
  ok "Deleted ${PURGE_DIR:-(service home was absent)} and $ENV_FILE"
  # The empty ~/services/<name> marker the launcher keys on.
  rmdir "$HOME/services/$NAME" 2>/dev/null || true
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed. The data folder %s is KEPT — it is the shared kopifund-hub clone; delete it by hand only if the Mac should lose sync too.\n' "$NAME" "${DATA_DIR:-~/.kopifund}"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data folder, service home and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the service home too: ./teardown.sh --purge  (the data folder is never deleted)"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
