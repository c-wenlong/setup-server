#!/usr/bin/env bash
#
# teardown.sh — take code-server off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish what Tailscale Serve points at THIS service, found from
#      `tailscale serve status` (never `serve reset`). A port that is all
#      code-server goes off; on a shared port (:443, where the launcher hangs
#      off /home) only code-server's own paths go, the rest stays published
#   2. stop the service and keep it from starting again (Linux: systemd user
#      unit disabled; macOS: LaunchAgent booted out and its plist removed,
#      because launchd would reload it at the next login otherwise)
#   3. keep config.yaml, extensions, settings and the binary, so ./setup.sh
#      brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: config, extensions, binary kept
#   ./teardown.sh --purge    # ALSO delete the unit file setup.sh wrote; asks
#                            # you to type "code-server" first, and prints the
#                            # exact rm for everything it leaves (config,
#                            # extensions, binary). Terminal only: the
#                            # launcher's Remove button never passes it.
#
# code-server keeps no state in ~/services and has no .env: its port lives in
# ~/.config/code-server/config.yaml, and teardown refuses to guess when that
# file is missing. Your workspace folders are never touched.
#
# Stopping is the LAST step on purpose: run from code-server's own integrated
# terminal, this script is killed along with code-server, so everything else
# is done by then.
#
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="code-server"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
# setup.sh never reads or writes a .env (PORT comes from the shell once, and
# lands in config.yaml). ENV_FILE only feeds the shared helpers and the
# COMPOSE_* guard below, copied verbatim from the reference teardown, so it
# points at an empty file and that guard checks the shell alone.
ENV_FILE="/dev/null"
CONFIG="$HOME/.config/code-server/config.yaml"
UNIT_NAME="code-server.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
PLIST_LABEL="com.coder.code-server"
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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
fi
[ -f "$CONFIG" ] || die "No $CONFIG — setup.sh has not deployed code-server here, so there is nothing to tear down (and no port to trust)."
if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

# Shared helpers, byte-identical to services/stirling-pdf/teardown.sh. Here
# env_get / env_lint only ever see the empty ENV_FILE above; real_dir guards
# the one path --purge may remove under ~/services (the empty marker dir).
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

# The port: bind-addr in config.yaml, the file code-server reads on every
# start (setup.sh writes `bind-addr: 127.0.0.1:$PORT` once and never again,
# so a hand edit wins). Read without running anything: exactly one top-level
# bind-addr line, optional quotes, optional ` #` comment. Anything else is
# refused, because a guessed port could switch off another service's Serve.
bind_lines="$(grep -c -E '^bind-addr:' "$CONFIG" || true)"
[ "$bind_lines" = "1" ] || die "$CONFIG has ${bind_lines:-0} top-level bind-addr lines; teardown needs exactly one to know code-server's port. Fix it and re-run."
BIND="$(sed -n 's/^bind-addr:[[:space:]]*//p' "$CONFIG")"
BIND="${BIND%$'\r'}"
BIND="${BIND%%[[:space:]]#*}"
tail="${BIND##*[![:space:]]}"; BIND="${BIND%"$tail"}"
case "$BIND" in
  \"*\") BIND="${BIND#\"}"; BIND="${BIND%\"}" ;;
  \'*\') BIND="${BIND#\'}"; BIND="${BIND%\'}" ;;
esac
LOCAL_PORT="${BIND##*:}"
case "$BIND" in *:*) ;; *) LOCAL_PORT="" ;; esac
case "$LOCAL_PORT" in ''|*[!0-9]*) die "bind-addr in $CONFIG is not host:port (got: $BIND) — refusing to guess code-server's port.";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT (from $CONFIG)"

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

# Units / agents on this box that mention code-server but that setup.sh did
# not write: never touched, only named. Read-only listing.
OTHER_UNITS=""
if [ "$OS" = "Linux" ]; then scan_dir="$UNIT_DIR"; own="$UNIT"; else scan_dir="$PLIST_DIR"; own="$PLIST"; fi
if [ -d "$scan_dir" ]; then
  for f in "$scan_dir"/*; do
    [ -f "$f" ] && [ "$f" != "$own" ] || continue
    if grep -q -- "code-server" "$f" 2>/dev/null; then
      OTHER_UNITS="$OTHER_UNITS $(basename "$f")"
    fi
  done
fi

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. setup.sh never creates
# ~/services/code-server; if one exists it is removed only when empty, and
# only when real_dir accepts it (a symlink there is skipped, never followed).
MARKER_DIR=""
if [ "$PURGE" -eq 1 ]; then
  if [ -L "$MARKER" ]; then
    warn "$MARKER is a symlink — it will be left alone."
  elif [ -d "$MARKER" ]; then
    MARKER_DIR="$(real_dir "$MARKER")" || die "$MARKER is not a real directory inside $HOME/services, or it holds this checkout — refusing."
  elif [ -e "$MARKER" ]; then
    warn "$MARKER is not a directory — it will be left alone."
  fi
  if [ "$OS" = "Linux" ]; then unit_file="$UNIT"; else unit_file="$PLIST"; fi
  warn "--purge deletes $unit_file${MARKER_DIR:+ and $MARKER_DIR (only if empty)}. Config, extensions and the binary are kept; the exact rm for each is printed at the end."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Plan per HTTPS port, from what Serve actually publishes (a re-run with
# another PORT, or a hand-made mapping, can add a port setup.sh never chose):
#   off  <port>          every handler proxies to code-server: the port goes
#   path <port> <path>   the port is shared (:443 also carries the launcher's
#                        /home): only code-server's own path goes, so
#                        `--set-path=<path> off` and nothing wider
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
while read -r verdict port path; do
  [ -n "${verdict:-}" ] || continue
  case "$port" in ''|*[!0-9]*) warn "Unexpected Serve port '$port' — left alone."; continue ;; esac
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
  else
    case "$path" in /*) ;; *) warn "Unexpected Serve path '$path' on :$port — left alone."; continue ;; esac
    "$TAILSCALE" serve --https="$port" --set-path="$path" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port$path off; the other handlers on :$port (e.g. the launcher's /home) stay published"
  fi
  unpublished=$((unpublished + 1))
done <<EOF
$SERVE_PLAN
EOF
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET (already off)"

[ -z "$OTHER_UNITS" ] || warn "Also mention code-server, but setup.sh did not create them, so they are left alone:$OTHER_UNITS (in $scan_dir)"

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
  fi
else
  # launchd loads every plist in ~/Library/LaunchAgents at login, so a kept
  # plist would bring code-server back. setup.sh rewrites it on every run, so
  # removing it loses nothing.
  if [ -f "$PLIST" ] || [ -L "$PLIST" ]; then
    rm -f -- "$PLIST"
    ok "Deleted $PLIST (setup.sh rewrites it)"
  else
    ok "No $PLIST (already removed)"
  fi
fi

if [ -n "$MARKER_DIR" ]; then
  if rmdir -- "$MARKER_DIR" 2>/dev/null; then
    ok "Removed the empty $MARKER_DIR"
  else
    warn "$MARKER_DIR is not empty — left alone (setup.sh never puts anything there)."
  fi
fi

# ------------------------------------------------------------- summary
echo
if [ "$PURGE" -eq 1 ]; then
  echo "Kept, because they live outside ~/services/$NAME. Delete by hand if you are sure:"
  kept=0
  for p in "$HOME/.config/code-server" "$HOME/.local/share/code-server" \
           "$HOME/.local/bin/code-server" "$HOME"/.local/lib/code-server-* \
           "$UNIT.d" "$HOME/Library/Logs/code-server.log"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    case "$p" in
      "$HOME/.config/code-server") note="config.yaml (and the password, if you set one)" ;;
      "$HOME/.local/share/code-server") note="extensions, settings, workspace state" ;;
      "$UNIT.d") note="your own drop-ins for the unit" ;;
      "$HOME/Library/Logs/code-server.log") note="log" ;;
      *) note="the standalone binary" ;;
    esac
    printf '  rm -rf %q   # %s\n' "$p" "$note"
    kept=$((kept + 1))
  done
  [ "$kept" -gt 0 ] || echo "  (nothing left)"
  echo "  Your workspace folders are never touched."
fi

# ---------------------------------------------------------------- stop
# Last, so a terminal inside code-server that dies with it has nothing left
# undone. The unit file may be gone by now (purge) but systemd still holds
# the loaded unit until the daemon-reload after.
info "Stopping code-server (a terminal opened inside code-server closes now)"
if [ "$OS" = "Linux" ]; then
  if ! systemctl --user stop "$UNIT_NAME" 2>/dev/null; then
    state="$(systemctl --user show -p ActiveState --value "$UNIT_NAME" 2>/dev/null || true)"
    case "$state" in
      ""|inactive|failed) ;;
      *) die "Could not stop $UNIT_NAME (state: $state). Try: systemctl --user stop $UNIT_NAME" ;;
    esac
  fi
  ok "$UNIT_NAME stopped"
  if [ "$PURGE" -eq 1 ]; then
    systemctl --user daemon-reload
    ok "systemd user daemon reloaded"
  fi
else
  domain="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$domain" >/dev/null 2>&1; then
    launchctl bootout "$domain" || die "launchctl bootout $domain failed. Try it by hand."
    ok "LaunchAgent $PLIST_LABEL booted out"
  else
    ok "LaunchAgent $PLIST_LABEL was not loaded"
  fi
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed along with its unit file. ./setup.sh starts it again with the kept config.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Config, extensions and the binary are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Also delete the unit file and list what is left: ./teardown.sh --purge"
fi
echo "  The launcher at https://<host>/home/ is not affected."
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
