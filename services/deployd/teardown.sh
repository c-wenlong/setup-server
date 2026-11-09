#!/usr/bin/env bash
#
# teardown.sh — take deployd off this box. Linux + macOS.
#
# The inverse of setup.sh's run, and nothing more:
#   1. stop the poller so it does not come back at boot or login:
#        Linux: systemctl --user disable --now deployd.timer, then stop
#               deployd.service if it is mid-tick
#        macOS: launchctl bootout + disable (setup.sh enables before it
#               bootstraps, so a disabled plist left on disk stays dead)
#   2. keep .env, the unit/plist files and the service home (state + deploy
#      logs), so ./setup.sh brings deployd back as it was
#
# A poll holding $SERVICE_HOME/.poll.lock is mid-run, possibly inside
# another service's setup.sh. Killing it there could leave that service
# half-configured, so teardown refuses while the lock is fresh and clears it
# only when it is stale (over 60 min — the same rule deployd uses).
#
# Never touched, by either mode: the setup-server checkout, other services'
# units, timers and deploys, lingering.
#
# Usage:
#   ./teardown.sh            # safe remove: .env, units and state kept
#   ./teardown.sh --purge    # ALSO delete the service home, the unit/plist
#                            # files and .env; asks you to type "deployd"
#                            # before anything changes. A SERVICE_HOME
#                            # outside ~/services/deployd (setup.sh honours
#                            # a custom one) is named but kept — teardown
#                            # cannot prove the data there is deployd's.
#
# Reads paths from .env without executing it, and refuses to guess when it
# is missing or malformed. Idempotent: re-running on a removed service
# changes nothing.

set -euo pipefail

NAME="deployd"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
UNIT_DIR="$HOME/.config/systemd/user"
TIMER_UNIT="deployd.timer"
SERVICE_UNIT="deployd.service"
PLIST_LABEL="com.setup-server.deployd"
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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (the poller is a systemd user timer)."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS (the poller is a LaunchAgent)."
fi
# .env is the authority for SERVICE_HOME once written — an operator may have
# pointed it elsewhere, and the poll lock lives under it. No .env means
# setup.sh never ran here, so there is nothing to tear down and no path to
# trust.
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."

# .env is the authority for paths. Values are read the way a sourced file
# would read them (an optional `export `, matching single or double quotes,
# an inline ` #` comment after an unquoted value) without executing the
# file — a value with $(...) or a stray line must never run.
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
       tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
       # setup.sh writes unquoted values %q-escaped (spaces and shell
       # specials get a backslash), so source-parity here means decoding
       # each \X as X. The one form %q can emit that this cannot decode is
       # the $'...' wrap (a newline or control char in the value) — refuse
       # it rather than read a path that is not what setup wrote.
       case "$value" in
         "\$'"*) die "$ENV_FILE: $1 uses an escape form teardown cannot decode — fix that value and re-run." ;;
       esac
       if [[ "$value" == *'\'* ]]; then
         local decoded="" rest="$value"
         while [[ "$rest" == *'\'* ]]; do
           decoded+="${rest%%\\*}"
           rest="${rest#*\\}"
           # A lone trailing backslash is not %q output (a real trailing
           # backslash is escaped as \\); refuse rather than guess.
           [ -n "$rest" ] || die "$ENV_FILE: $1 ends in an incomplete escape — fix that value and re-run."
           decoded+="${rest:0:1}"
           rest="${rest:1}"
         done
         value="$decoded$rest"
       fi ;;
  esac
  # setup.sh interpolates no variables itself, but a hand edit may write
  # $HOME / ${HOME} the way Compose would; that one variable is all a path
  # here may use (single quotes are literal). Anything else is left as
  # written and then fails the path checks.
  if [ "$quote" != "'" ]; then
    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
  fi
  printf '%s' "$value"
}

# Real path of a purge target WITHOUT entering it: resolve the parent,
# append the name. Refused (non-zero) unless the result is
# ~/services/$NAME itself or inside it, with ~/services a real directory
# under $HOME; a symlinked leaf, a `.`/`..` component, a newline or a colon
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
# read differently from setup.sh's own sourcing: a key set twice, a quoted
# value that does not close on its own line (multi-line values), a backslash
# escape in double quotes, or a line that is not KEY=value. Prints key names
# only.
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
  [ -z "$problem" ] || die "$ENV_FILE: $problem. Fix that line (teardown will not guess how .env reads it) and re-run."
}
env_lint

SERVICE_HOME="$(env_get SERVICE_HOME)"
# The poller falls back to the default when SERVICE_HOME is unset, so the
# same default applies here — anything else was written on purpose and gets
# checked before it is trusted as a delete target.
SERVICE_HOME="${SERVICE_HOME:-$HOME/services/$NAME}"
LOCK="$SERVICE_HOME/.poll.lock"
ok "$NAME: home $SERVICE_HOME"

# The --purge decision and the typed confirmation come before ANYTHING
# changes, so a mistyped name leaves the service exactly as it was.
PURGE_DIRS=()
KEPT_DIRS=()
if [ "$PURGE" -eq 1 ]; then
  # What may be deleted: only directories real_dir proves are the default
  # ~/services/deployd or inside it — that fixed name is the launcher's
  # install marker and setup.sh's default home. setup.sh also honours a
  # SERVICE_HOME anywhere else; a home outside the owned root is named and
  # kept with a manual command, because the .env value alone cannot prove
  # the data there is deployd's to destroy.
  for candidate in "$HOME/services/$NAME" "$SERVICE_HOME"; do
    while :; do case "$candidate" in */) candidate="${candidate%/}" ;; *) break ;; esac; done
    [ -n "$candidate" ] || continue
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    resolved="$(real_dir "$candidate")" || resolved=""
    if [ -n "$resolved" ]; then
      dup=0
      for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
        [ "$d" = "$resolved" ] && dup=1
      done
      [ "$dup" -eq 1 ] || PURGE_DIRS+=("$resolved")
    else
      dup=0
      for d in ${KEPT_DIRS[@]+"${KEPT_DIRS[@]}"}; do
        [ "$d" = "$candidate" ] && dup=1
      done
      [ "$dup" -eq 1 ] || KEPT_DIRS+=("$candidate")
    fi
  done
  if [ "${#PURGE_DIRS[@]}" -gt 0 ]; then
    warn "--purge deletes ${PURGE_DIRS[*]} (installed poller, sha state,"
    warn "deploy logs), the unit/plist files and $ENV_FILE."
  else
    warn "--purge deletes the unit/plist files and $ENV_FILE."
  fi
  for d in ${KEPT_DIRS[@]+"${KEPT_DIRS[@]}"}; do
    warn "keeps $d — not inside $HOME/services/$NAME, or not provably"
    warn "  deployd's own. Remove it by hand if it should go too:"
    warn "  rm -rf -- \"$d\""
  done
  warn "The setup-server checkout is kept. This cannot be undone."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ---------------------------------------------------------------- poller
# First stop *future* ticks without touching a running one: disable the
# systemd timer (a running oneshot survives) or launchd-disable the label
# (the loaded job keeps running). Then the lock check; only after it clears
# do we stop a possibly-running job.
if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/$TIMER_UNIT" ]; then
    systemctl --user disable --now "$TIMER_UNIT" >/dev/null 2>&1 \
      || die "Could not disable $TIMER_UNIT (is the user systemd instance reachable?). Nothing was changed."
    ok "$TIMER_UNIT disabled and stopped"
  else
    ok "$TIMER_UNIT not installed (already gone)"
  fi
else
  target="gui/$(id -u)/$PLIST_LABEL"
  launchctl disable "$target" >/dev/null 2>&1 \
    || die "Could not disable LaunchAgent $PLIST_LABEL (launchctl disable $target), so it would load again at the next login. Nothing was changed; fix that and re-run."
  ok "LaunchAgent $PLIST_LABEL disabled (stops future starts)"
fi

if [ -d "$LOCK" ]; then
  [ -L "$LOCK" ] && die "$LOCK is a symlink, not the lock deployd makes — refusing."
  if [ -z "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    die "A poll is mid-run (it holds $LOCK) and may be inside another service's deploy — re-run once it finishes. New ticks are already disabled, so nothing new will start."
  fi
  rmdir "$LOCK" 2>/dev/null \
    || die "$LOCK is over 60 min old but not empty — look inside, remove it by hand, then re-run."
  ok "Cleared a stale poll lock (over 60 min old)"
fi

if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/$SERVICE_UNIT" ]; then
    systemctl --user stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
  fi
else
  target="gui/$(id -u)/$PLIST_LABEL"
  if launchctl print "$target" >/dev/null 2>&1 \
     && ! launchctl bootout "$target" >/dev/null 2>&1; then
    for i in 1 2 3; do
      launchctl print "$target" >/dev/null 2>&1 || break
      [ "$i" -lt 3 ] || die "Could not unload LaunchAgent $PLIST_LABEL (launchctl bootout $target failed and it is still loaded; check: launchctl print $target). Fix that and re-run."
      sleep 1
    done
  fi
  ok "LaunchAgent $PLIST_LABEL unloaded"
fi

# ------------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging"
  for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
    rm -rf -- "$d"
  done
  rm -f -- "$UNIT_DIR/$TIMER_UNIT" "$UNIT_DIR/$SERVICE_UNIT" "$PLIST" "$ENV_FILE"
  if [ "$OS" = "Linux" ]; then systemctl --user daemon-reload; fi
  ok "Purged"
else
  echo "Kept: $ENV_FILE, the unit files and $SERVICE_HOME (state + deploy logs)."
  echo "      ./setup.sh brings deployd back as it was; --purge removes them."
fi

echo
printf '\033[1;32mDone.\033[0m deployd will not poll again until setup.sh runs.\n'
