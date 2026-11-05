#!/usr/bin/env bash
#
# teardown.sh — take OpenMausBot off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish every Tailscale Serve port whose handlers all proxy to this
#      service's local port, found from `tailscale serve status` (never
#      `serve reset`). A port shared with another handler keeps the rest
#   2. stop the service and keep it from starting again (Linux: systemd user
#      unit disabled; macOS: LaunchAgent booted out and its plist removed,
#      because launchd would reload it at the next login otherwise)
#   3. keep .env, ~/services/openmausbot (bots, chats, credentials, memories)
#      and the npm package, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: data, .env and the package kept
#   ./teardown.sh --purge    # ALSO delete the unit file, .env and
#                            # ~/services/openmausbot; asks you to type
#                            # "openmausbot" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# The port comes from .env (OMB_PORT), the file the unit's EnvironmentFile
# reads on every start — a hand edit wins, and a missing .env means there is
# nothing to trust for the port, so teardown refuses rather than guess.
#
# Never touched: ~/.openmausbot (a native install upstream of this service),
# the engine CLIs and their credentials (~/.claude, ~/.codex, ...), the npm
# prefix config, other Serve ports, lingering, the Tailscale operator grant.
#
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="openmausbot"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
UNIT_NAME="openmausbot.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
PLIST_LABEL="com.openmausbot.server"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"
MARKER="$HOME/services/$NAME"

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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
fi
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — setup.sh has not deployed $NAME here, so there is nothing to tear down (and no port to trust)."
resolve_tailscale

# Shared helpers, byte-identical to services/code-server/teardown.sh.
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

# Real path of a purge target WITHOUT entering it: a container- or root-owned
# data dir may be unreadable to this user. Resolve the parent, append the
# name. Refused (non-zero) unless the result is ~/services/$NAME itself or
# inside it, with ~/services a real directory under $HOME; a symlinked leaf,
# a `.`/`..` component, a newline or a colon is never accepted.
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

LOCAL_PORT="$(env_get OMB_PORT)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "OMB_PORT in $ENV_FILE is missing or not numeric (got: ${LOCAL_PORT:-empty}) — refusing to guess $NAME's port.";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT (from $ENV_FILE)"

# Compose is not involved here; the guard is the shared one, kept so every
# teardown refuses the same shell state.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# Units / agents on this box that mention openmausbot but that setup.sh did
# not write: never touched, only named. Read-only listing.
OTHER_UNITS=""
if [ "$OS" = "Linux" ]; then scan_dir="$UNIT_DIR"; own="$UNIT"; else scan_dir="$PLIST_DIR"; own="$PLIST"; fi
if [ -d "$scan_dir" ]; then
  for f in "$scan_dir"/*; do
    [ -f "$f" ] && [ "$f" != "$own" ] || continue
    if grep -q -- "openmausbot" "$f" 2>/dev/null; then
      OTHER_UNITS="$OTHER_UNITS $(basename "$f")"
    fi
  done
fi

# What --purge would remove, resolved and confirmed before anything changes:
# the unit file, .env, and the data dir named by OMB_DATA_DIR — accepted only
# when real_dir places it at or inside ~/services/openmausbot.
DATA_DIR="$(env_get OMB_DATA_DIR)"
PURGE_DIRS=""
if [ "$PURGE" -eq 1 ]; then
  if [ -L "$MARKER" ]; then
    warn "$MARKER is a symlink — it will be left alone."
  elif [ -d "$MARKER" ]; then
    :
  elif [ -e "$MARKER" ]; then
    warn "$MARKER is not a directory — it will be left alone."
  fi
  if [ -n "$DATA_DIR" ]; then
    if [ -d "$DATA_DIR" ]; then
      DATA_DIR_REAL="$(real_dir "$DATA_DIR")" \
        || die "OMB_DATA_DIR=$DATA_DIR is not a real directory at or inside $MARKER (or $MARKER is a symlink) — refusing to purge it. Fix .env and re-run."
      PURGE_DIRS="$DATA_DIR_REAL"
    fi
  else
    warn "OMB_DATA_DIR is not set in $ENV_FILE — only $MARKER (if empty) will be removed."
  fi
  if [ "$OS" = "Linux" ]; then unit_file="$UNIT"; else unit_file="$PLIST"; fi
  warn "--purge deletes $unit_file, $ENV_FILE${PURGE_DIRS:+, and data dir $PURGE_DIRS}. The npm package and ~/.openmausbot are kept; the exact rm for each is printed at the end."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Plan per HTTPS port, from what Serve actually publishes (a re-run with
# another OMB_PORT, or a hand-made mapping, can add a port setup.sh never
# chose):
#   off  <port>          every handler proxies to openmausbot: the port goes
#   path <port> <path>   the port is shared: only openmausbot's own paths go,
#                        so `--set-path=<path> off` and nothing wider
# A block whose header is not https:// (http://, tcp://) is never acted on
# and never borrows another port's handlers. Never `serve reset`.
info "Unpublishing Tailscale Serve handlers that point at $TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" '
  function flush(   i) {
    if (port != "" && mine > 0) {
      if (mine == n) print "off " port
      else for (i = 1; i <= mine; i++) print "path " port " " paths[i]
    }
    port = ""; n = 0; mine = 0
  }
  /^[A-Za-z][A-Za-z0-9+.-]*:\/\// {
    flush()
    if (index($0, "https://") == 1) {
      u = $1; sub(/\/$/, "", u)
      port = match(u, /:[0-9]+$/) ? substr(u, RSTART + 1) : "443"
    }
    next
  }
  port != "" && /\|-- / { n++; if ($3 == "proxy" && $NF == t) { mine++; paths[mine] = $2 } }
  END { flush() }')"
unpublished=0
kept=0
while read -r verdict port path; do
  [ -n "${verdict:-}" ] || continue
  case "$port" in ''|*[!0-9]*) warn "Unexpected Serve port '$port' — left alone."; kept=$((kept + 1)); continue ;; esac
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
  else
    case "$path" in /*) ;; *) warn "Unexpected Serve path '$path' on :$port — left alone."; kept=$((kept + 1)); continue ;; esac
    "$TAILSCALE" serve --https="$port" --set-path="$path" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port$path off; the other handlers on :$port stay published"
  fi
  unpublished=$((unpublished + 1))
done <<EOF
$SERVE_PLAN
EOF
# A route left on still points here, so "already off" would be wrong.
if [ "$kept" -gt 0 ]; then
  warn "$kept Serve route(s) still point at $TARGET (left on, see above); $unpublished route(s) unpublished."
elif [ "$unpublished" -eq 0 ]; then
  ok "Nothing on Tailscale Serve points at $TARGET (already off)"
fi

[ -z "$OTHER_UNITS" ] || warn "Also mention openmausbot, but setup.sh did not create them, so they are left alone:$OTHER_UNITS (in $scan_dir)"

# ------------------------------------------- disable (and purge) the unit
if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Disabling $UNIT_NAME (no start at boot)"
    systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 \
      || die "systemctl --user disable $UNIT_NAME failed. Try it by hand and re-run."
    ok "$UNIT_NAME disabled"
  else
    ok "No $UNIT (already removed)"
  fi
  if [ "$PURGE" -eq 1 ]; then
    rm -f -- "$UNIT"
    ok "Deleted $UNIT"
    # Safe while openmausbot still runs: systemd keeps a loaded unit until it
    # stops, even with its file gone, so the stop below still works.
    systemctl --user daemon-reload \
      || die "systemctl --user daemon-reload failed. Run it by hand, then: systemctl --user stop $UNIT_NAME"
    ok "systemd user daemon reloaded"
  fi
else
  # launchd loads every plist in ~/Library/LaunchAgents at login, so a kept
  # plist would bring the server back. setup.sh rewrites it on every run, so
  # removing it loses nothing.
  if [ -f "$PLIST" ] || [ -L "$PLIST" ]; then
    rm -f -- "$PLIST"
    ok "Deleted $PLIST (setup.sh rewrites it)"
  else
    ok "No $PLIST (already removed)"
  fi
fi

if [ "$PURGE" -eq 1 ]; then
  [ -z "$PURGE_DIRS" ] || { rm -rf -- "$PURGE_DIRS"; ok "Deleted $PURGE_DIRS"; }
  NPM_BIN_KEPT="$(env_get NPM_BIN)"
  rm -f -- "$ENV_FILE"
  ok "Deleted $ENV_FILE"
  # The marker holds the data dir on a stock deploy; remove it only empty.
  if [ -d "$MARKER" ] && [ ! -L "$MARKER" ]; then
    if rmdir -- "$MARKER" 2>/dev/null; then
      ok "Removed the empty $MARKER"
    else
      warn "$MARKER is not empty — left alone."
    fi
  fi
fi

# ------------------------------------------------------------- summary
echo
if [ "$PURGE" -eq 1 ]; then
  echo "Kept, because they live outside ~/services/$NAME or this service did not make them. Delete by hand if you are sure:"
  kept=0
  for p in "${NPM_BIN_KEPT:-/nonexistent}/openmausbot" \
           "$HOME/.openmausbot" \
           "$UNIT.d" "$HOME/Library/Logs/openmausbot.log"; do
    [ -n "$p" ] && { [ -e "$p" ] || [ -L "$p" ]; } || continue
    case "$p" in
      */openmausbot) note="the npm package (or: npm uninstall -g openmausbot)" ;;
      "$HOME/.openmausbot") note="a native install's data — never this service's" ;;
      "$UNIT.d") note="your own drop-ins for the unit" ;;
      *) note="log" ;;
    esac
    printf '  rm -rf %q   # %s\n' "$p" "$note"
    kept=$((kept + 1))
  done
  [ "$kept" -gt 0 ] || echo "  (nothing left)"
  echo "  Engine CLIs and their credentials (~/.claude, ~/.codex, ...) are untouched."
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed along with its unit, .env and data dir.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Data, .env and the package are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Also delete the unit, .env and data: ./teardown.sh --purge"
fi
echo "  The launcher at https://<host>/home/ is not affected."
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."

# ------------------------------------------------------------------ stop
# The very last action: Serve is off and the unit disabled (or gone) by now,
# so a teardown run that kills its own terminal still leaves a clean box.
info "Stopping $NAME"
if [ "$OS" = "Linux" ]; then
  if ! systemctl --user stop "$UNIT_NAME" 2>/dev/null; then
    state="$(systemctl --user show -p ActiveState --value "$UNIT_NAME" 2>/dev/null || true)"
    case "$state" in
      ""|inactive|failed) ;;
      *) die "Could not stop $UNIT_NAME (state: $state). Try: systemctl --user stop $UNIT_NAME" ;;
    esac
  fi
  ok "$UNIT_NAME stopped"
else
  domain="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$domain" >/dev/null 2>&1; then
    launchctl bootout "$domain" || die "launchctl bootout $domain failed. Try it by hand."
    ok "LaunchAgent $PLIST_LABEL booted out"
  else
    ok "LaunchAgent $PLIST_LABEL was not loaded"
  fi
fi

exit 0
