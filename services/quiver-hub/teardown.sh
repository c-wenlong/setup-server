#!/usr/bin/env bash
#
# teardown.sh — take the Quiver hub off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS hub, found from
#      `tailscale serve status` (never `serve reset`)
#   2. stop the hub so it does not come back at boot or login:
#        Linux: systemctl --user disable --now quiver-hub.service
#        macOS: launchctl bootout, and the LaunchAgent plist goes (setup.sh
#               rewrites it on every run; a plist left in ~/Library/LaunchAgents
#               would start the hub again at the next login)
#   3. keep .env, the systemd unit file and the hub build, so ./setup.sh
#      brings it back as it was
#
# Never touched, by either mode: the `swe` on your PATH and ~/.quiver (your
# own Quiver install; the hub's devices and journals live in
# ~/.quiver/data/remote and are shared with `swe remote pair/devices`),
# lingering, and the Tailscale operator setting.
#
# Usage:
#   ./teardown.sh            # safe remove: .env, unit file and build kept
#   ./teardown.sh --purge    # ALSO delete .env, the unit file and the empty
#                            # ~/services/quiver-hub marker; asks you to type
#                            # "quiver-hub" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads the port from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="quiver-hub"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
# Fixed paths setup.sh writes (not read from .env).
INSTALL_DIR="$HOME/.local/share/quiver-hub"
UNIT_NAME="quiver-hub.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
PLIST_LABEL="com.setup-server.quiver-hub"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"
MARKER="$HOME/services/$NAME"

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
  command -v systemctl >/dev/null || die "systemd is required on Linux (the hub runs as a systemd user unit)."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS (the hub runs as a LaunchAgent)."
fi
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
ok "$NAME: local :$LOCAL_PORT"

# The hub is not a Compose stack, but the same guard runs in every teardown:
# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and setup.sh never sets them, so a .env or shell that
# does was not left by setup.sh. Refuse rather than guess.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# Units and agents on this box that mention the hub but that setup.sh did
# not write (a satellite agent, a watchdog): listed read-only, never touched.
others=""
for dir in "$UNIT_DIR" "$PLIST_DIR"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$f" in "$UNIT"|"$PLIST") continue ;; esac
    if grep -qF "quiver-hub" "$f" 2>/dev/null; then
      others="$others $(basename "$f")"
    fi
  done
done

# systemd's own view of the hub unit, whether or not its file is still on
# disk: a unit file deleted while the hub ran leaves it loaded and running.
# Sets U_ACTIVE; fails when systemd cannot be asked.
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
# leaves the service exactly as it was. setup.sh keeps no state under
# ~/services/quiver-hub, so all purge can find there is the empty marker.
PURGE_MARKER=""
if [ "$PURGE" -eq 1 ]; then
  if [ -L "$MARKER" ]; then
    warn "$MARKER is a symlink; it is left alone."
  elif [ -e "$MARKER" ]; then
    [ -d "$MARKER" ] || die "$MARKER is not a directory — refusing."
    PURGE_MARKER="$(real_dir "$MARKER")" || die "$MARKER is not a real directory inside $HOME/services, or it holds this checkout — refusing."
  fi
  # No unit file means the stop step has nothing to disable; the hub may
  # still be running from it. Purge only once systemd can say.
  if [ "$OS" = "Linux" ] && [ ! -e "$UNIT" ] && [ ! -L "$UNIT" ]; then
    unit_probe || die "No $UNIT, and systemd could not say whether $UNIT_NAME is still running (systemctl --user show failed) — refusing to purge. Nothing was changed."
  fi
  if [ "$OS" = "Linux" ]; then unit_file="$UNIT"; else unit_file="$PLIST"; fi
  warn "--purge deletes $ENV_FILE and $unit_file${PURGE_MARKER:+, and removes $PURGE_MARKER if it is empty}. This cannot be undone."
  warn "It keeps ~/.quiver (your Quiver install, where paired devices are stored) and the hub build in $INSTALL_DIR."
  warn "Without .env, ./setup.sh starts again on the default port 8477: if the hub ran on another port, every paired MacBook must re-pair (./pair.sh, then swe remote agent --hub=... --token=...), and so must phones."
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
if [ -n "$others" ]; then
  warn "Also on this box, mentioning the hub, NOT written by setup.sh and left alone:$others"
fi
if [ "$OS" = "Linux" ]; then
  if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Stopping the hub (systemctl --user disable --now $UNIT_NAME)"
    systemctl --user disable --now "$UNIT_NAME"
    ok "Hub stopped and disabled; unit file kept at $UNIT"
  elif ! unit_probe; then
    warn "No $UNIT, and systemd could not say whether $UNIT_NAME is still running. If it is: systemctl --user stop $UNIT_NAME"
  elif unit_running; then
    # The name is setup.sh's own; nothing else ships a quiver-hub user unit.
    info "$UNIT is gone but the hub is still running from it; stopping it (systemctl --user stop)"
    systemctl --user stop "$UNIT_NAME"
    ok "Hub stopped"
  else
    ok "No $UNIT and no hub running (already removed)"
  fi
else
  if launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
    info "Stopping the hub (launchctl bootout $PLIST_LABEL)"
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL"
  fi
  # A plist left behind would start the hub again at the next login, and
  # setup.sh rewrites it on every run, so it goes in both modes.
  rm -f -- "$PLIST"
  ok "LaunchAgent unloaded and removed (./setup.sh writes it again)"
fi

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  if [ "$OS" = "Linux" ]; then
    unit_probe || die "Could not ask systemd whether $UNIT_NAME stopped. Nothing was deleted and $ENV_FILE is kept; re-run ./teardown.sh --purge."
    ! unit_running || die "$UNIT_NAME is still running. Nothing was deleted and $ENV_FILE is kept: stop it (systemctl --user stop $UNIT_NAME) and re-run ./teardown.sh --purge."
  fi
  info "Purging"
  if [ "$OS" = "Linux" ] && { [ -f "$UNIT" ] || [ -L "$UNIT" ]; }; then
    rm -f -- "$UNIT"
    systemctl --user daemon-reload
    ok "Deleted $UNIT"
  fi
  rm -f -- "$ENV_FILE"
  ok "Deleted $ENV_FILE"
  if [ -n "$PURGE_MARKER" ]; then
    if rmdir -- "$PURGE_MARKER" 2>/dev/null; then
      ok "Removed the empty $PURGE_MARKER"
    else
      warn "$PURGE_MARKER is not empty (setup.sh puts nothing there), so it is left alone."
    fi
  fi
fi

# Tell deployd not to resurrect this on the next push: the flag lives in
# deployd's own state dir so it survives --purge too. Re-run ./setup.sh to
# clear it and re-enable auto-deploy.
if [ -d "$HOME/services/deployd/state" ]; then
  touch "$HOME/services/deployd/state/$NAME.disabled"
  ok "deployd will skip $NAME until its setup.sh runs again"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed, with its .env and unit file. ./setup.sh starts fresh.\n' "$NAME"
  echo "  Kept: ~/.quiver (paired devices, journals) and the hub build. To drop the build too:"
  echo "    rm -rf $INSTALL_DIR"
else
  printf '\033[1;32mDone.\033[0m %s is removed. .env, unit file and build are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete .env and the unit file too: ./teardown.sh --purge"
fi
echo "  Paired phones and satellites cannot reach the hub until it is back."
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
