#!/usr/bin/env bash
#
# teardown.sh — take T3 Code off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS t3, found from
#      `tailscale serve status` (never `serve reset`)
#   2. stop the service so it does not come back at boot or login:
#        Linux: systemctl --user disable --now t3code.service
#        macOS: launchctl bootout, and the LaunchAgent plist goes (setup.sh
#               rewrites it on every run; a plist left in ~/Library/LaunchAgents
#               would start t3 again at the next login)
#   3. keep .env, the systemd unit file, the t3 release and ~/services/t3code
#      (projects, threads, paired devices), so ./setup.sh brings it back as
#      it was
#
# Never touched, by either mode: the `t3` on your PATH if you installed one
# yourself (setup.sh runs its own copy under ~/.local/share/t3code), lingering,
# and the Tailscale operator setting.
#
# Usage:
#   ./teardown.sh            # safe remove: .env, unit file, data and build kept
#   ./teardown.sh --purge    # ALSO delete .env, the unit file AND
#                            # ~/services/t3code (projects, threads, paired
#                            # devices — this cannot be undone); asks you to
#                            # type "t3code" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads the port from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="t3code"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
# Fixed paths setup.sh writes (not read from .env).
INSTALL_DIR="$HOME/.local/share/t3code"
DATA_DIR="$HOME/services/t3code"
UNIT_NAME="t3code.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
PLIST_LABEL="com.setup-server.t3code"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$PLIST_LABEL.plist"

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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (t3 runs as a systemd user unit)."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS (t3 runs as a LaunchAgent)."
fi
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

# Real path of a purge target WITHOUT entering it: a user-owned dir may be
# unreadable to this user. Resolve the parent, append the name. Refused
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

# setup.sh records the HTTPS/local pair it last published in serve-map. A
# LOCAL_PORT change since then leaves a stale mapping proxying to the OLD
# loopback port — which .env no longer names — so that target counts as
# ours below too. Only used when it actually differs.
OLD_TARGET=""
if [ -f "$INSTALL_DIR/serve-map" ]; then
  old_https=""; old_local=""
  read -r old_https old_local < "$INSTALL_DIR/serve-map" || true
  case "$old_local" in
    ''|*[!0-9]*) ;;
    *) [ "$old_local" != "$LOCAL_PORT" ] && OLD_TARGET="http://127.0.0.1:$old_local" ;;
  esac
fi
ok "$NAME: local :$LOCAL_PORT"

# The service is not a Compose stack, but the same guard runs in every
# teardown: Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME /
# COMPOSE_ENV_FILES from .env and the shell, and setup.sh never sets them,
# so a .env or shell that does was not left by setup.sh. Refuse rather than
# guess.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# Units and agents on this box that mention t3code but that setup.sh did
# not write (a hand-rolled unit, a watchdog): listed read-only, never touched.
others=""
for dir in "$UNIT_DIR" "$PLIST_DIR"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$f" in "$UNIT"|"$PLIST") continue ;; esac
    if grep -qF "t3code" "$f" 2>/dev/null; then
      others="$others $(basename "$f")"
    fi
  done
done

# systemd's own view of the t3code unit, whether or not its file is still on
# disk: a unit file deleted while the service ran leaves it loaded and
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
# leaves the service exactly as it was. Unlike quiver-hub, ~/services/t3code
# is this service's own state (projects, threads, paired devices), so purge
# deletes it — loudly.
PURGE_DATA=""
if [ "$PURGE" -eq 1 ]; then
  if [ -L "$DATA_DIR" ]; then
    warn "$DATA_DIR is a symlink; it is left alone."
  elif [ -e "$DATA_DIR" ]; then
    [ -d "$DATA_DIR" ] || die "$DATA_DIR is not a directory — refusing."
    PURGE_DATA="$(real_dir "$DATA_DIR")" || die "$DATA_DIR is not a real directory inside $HOME/services, or it holds this checkout — refusing."
  else
    ok "No $DATA_DIR — nothing to purge there"
  fi
  # No unit file means the stop step has nothing to disable; the service may
  # still be running from it. Purge only once systemd can say.
  if [ "$OS" = "Linux" ] && [ ! -e "$UNIT" ] && [ ! -L "$UNIT" ]; then
    unit_probe || die "No $UNIT, and systemd could not say whether $UNIT_NAME is still running (systemctl --user show failed) — refusing to purge. Nothing was changed."
  fi
  if [ "$OS" = "Linux" ]; then unit_file="$UNIT"; else unit_file="$PLIST"; fi
  warn "--purge deletes $ENV_FILE, $unit_file, $PURGE_DATA (projects, threads, paired devices) and the t3 release is kept. This cannot be undone."
  warn "Paired browsers/devices lose access until you ./setup.sh and pair again."
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
info "Unpublishing Tailscale Serve ports that point at $TARGET${OLD_TARGET:+ or its previous $OLD_TARGET}"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" -v t2="$OLD_TARGET" '
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
  port != "" && /\|-- / { n++; if (/ proxy / && ($NF == t || $NF == t2)) mine++ }
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
  warn "Also on this box, mentioning t3code, NOT written by setup.sh and left alone:$others"
fi
if [ "$OS" = "Linux" ]; then
  if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Stopping t3 (systemctl --user disable --now $UNIT_NAME)"
    systemctl --user disable --now "$UNIT_NAME"
    ok "t3 stopped and disabled; unit file kept at $UNIT"
  elif ! unit_probe; then
    warn "No $UNIT, and systemd could not say whether $UNIT_NAME is still running. If it is: systemctl --user stop $UNIT_NAME"
  elif unit_running; then
    # The name is setup.sh's own; nothing else ships a t3code user unit.
    info "$UNIT is gone but t3 is still running from it; stopping it (systemctl --user stop)"
    systemctl --user stop "$UNIT_NAME"
    ok "t3 stopped"
  else
    ok "No $UNIT and no t3 running (already removed)"
  fi
else
  if launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
    info "Stopping t3 (launchctl bootout $PLIST_LABEL)"
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL"
  fi
  # A plist left behind would start t3 again at the next login, and
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
  if [ -n "$PURGE_DATA" ]; then
    rm -rf -- "$PURGE_DATA"
    ok "Deleted $PURGE_DATA (projects, threads, paired devices)"
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
  printf '\033[1;32mDone.\033[0m %s is removed, with its .env, unit file and data. ./setup.sh starts fresh.\n' "$NAME"
  echo "  Kept: the t3 release in $INSTALL_DIR. To drop it too:"
  echo "    rm -rf $INSTALL_DIR"
else
  printf '\033[1;32mDone.\033[0m %s is removed. .env, unit file, data and build are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete .env, the unit file and ~/services/$NAME too: ./teardown.sh --purge"
fi
echo "  Paired browsers lose access until it is back and you pair again."
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
