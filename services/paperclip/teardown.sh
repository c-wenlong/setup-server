#!/usr/bin/env bash
#
# teardown.sh — take Paperclip off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`). Paperclip hops to
#      the next port when its own is busy (3100 -> 3101), so the live port in
#      its runtime-info.json counts too, while that process is still running
#   2. stop and disable the background service setup.sh had the official CLI
#      install (systemd user unit paperclipai.service on Linux, LaunchAgent
#      ing.paperclip.paperclipai on macOS); the unit file stays
#   3. keep .env, ~/services/paperclip and the whole Paperclip instance, so
#      ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: everything kept
#   ./teardown.sh --purge    # ALSO delete what setup.sh wrote: the CEO invite
#                            # and agent markers in ~/services/paperclip, the
#                            # unit file, and .env. Asks you to type
#                            # "paperclip" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Never deleted, in any mode: the Paperclip instance and managed CLI under
# PAPERCLIP_DATA (~/.paperclip: database, config, secrets master.key, CLI
# store; --purge prints the commands instead), ~/agent-workspaces, ~/.claude,
# ~/.codex, OpenHands (a separate service), lingering, the Tailscale
# operator. Never runs `paperclipai uninstall`: that deletes the CLI store.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="paperclip"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
MARKER="$HOME/services/$NAME"
# Names the official CLI gives the default instance's service
# (systemdServiceName / launchdServiceName in paperclipai's service manager).
UNIT="paperclipai.service"
LAUNCHD_LABEL="ing.paperclip.paperclipai"
# The only files setup.sh writes into ~/services/paperclip.
MARKER_FILES="ceo-invite.txt .ceo-bootstrapped .agent-claude-local .agent-codex-local"

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
command -v python3 >/dev/null || die "python3 is required (reads Paperclip's JSON config)."
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
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
LOCAL_PORT="$(env_get PAPERCLIP_PORT)"
PAPERCLIP_DATA="$(env_get PAPERCLIP_DATA)"
WORKSPACES="$(env_get AGENT_WORKSPACES)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "PAPERCLIP_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
[ -n "$PAPERCLIP_DATA" ] || die "PAPERCLIP_DATA is missing from $ENV_FILE — refusing to guess where the Paperclip instance is."
while :; do case "$PAPERCLIP_DATA" in ?*/) PAPERCLIP_DATA="${PAPERCLIP_DATA%/}" ;; *) break ;; esac; done
while :; do case "$WORKSPACES" in ?*/) WORKSPACES="${WORKSPACES%/}" ;; *) break ;; esac; done
ok "$NAME: local :$LOCAL_PORT, instance $PAPERCLIP_DATA, workspaces ${WORKSPACES:-(not set)}"

# Paperclip runs no Compose stack, but the guard is the one every teardown
# shares: a shell or .env carrying these was meant for some other teardown.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# json_get <file> <key|server.port>: an integer a Paperclip JSON file records,
# or nothing. Read-only; a missing or malformed file is just "nothing".
json_get() {
  python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
    for k in sys.argv[2].split("."):
        d = d.get(k) if isinstance(d, dict) else None
    if isinstance(d, int) and not isinstance(d, bool) and d > 0:
        print(d)
except Exception:
    pass
' "$1" "$2" 2>/dev/null || true
}

# ------------------------------------------------- which local ports are ours
# .env is the authority: setup.sh publishes HTTPS -> 127.0.0.1:PAPERCLIP_PORT.
# A restart while Serve still held the HTTPS port makes Paperclip hop to the
# next free port and record it in runtime-info.json. That port counts only
# while the recorded process is still a running `paperclipai run`: then no
# other service can be listening there. A stale record, or a config.json /
# instance .env port that disagrees with .env, is reported, never acted on,
# because by now another service may own that port.
PORTS="$LOCAL_PORT"
has_port() { case " $PORTS " in *" $1 "*) return 0 ;; esac; return 1; }
CFG=""
for p in \
  "$PAPERCLIP_DATA/instances/default/config.json" \
  "$PAPERCLIP_DATA/config.json" \
  "$HOME/.paperclip/instances/default/config.json"
do
  if [ -f "$p" ]; then CFG="$p"; break; fi
done
if [ -n "$CFG" ]; then
  inst="$(dirname "$CFG")"
  if [ -f "$inst/runtime-info.json" ]; then
    rport="$(json_get "$inst/runtime-info.json" port)"
    rpid="$(json_get "$inst/runtime-info.json" pid)"
    rargs=""
    [ -z "$rpid" ] || rargs="$(ps -p "$rpid" -o args= 2>/dev/null || true)"
    if [ -n "$rport" ] && ! has_port "$rport"; then
      case "$rargs" in
        *paperclipai*" run"*)
          PORTS="$PORTS $rport"
          warn "Paperclip is running on :$rport, not :$LOCAL_PORT (it hopped while the port was busy); Serve ports pointing at either are unpublished." ;;
        *)
          warn "runtime-info.json says Paperclip last ran on :$rport, but that process is gone. A Serve port pointing at 127.0.0.1:$rport is left alone: check tailscale serve status." ;;
      esac
    fi
  fi
  cport="$(json_get "$CFG" server.port)"
  if [ -n "$cport" ] && ! has_port "$cport"; then
    warn "$CFG says port $cport but $ENV_FILE says $LOCAL_PORT. Only :$LOCAL_PORT is treated as Paperclip's; check tailscale serve status for :$cport."
  fi
  iport=""
  [ ! -f "$inst/.env" ] || iport="$(sed -n 's/^PORT=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$inst/.env" | tail -1)"
  if [ -n "$iport" ] && ! has_port "$iport" && [ "$iport" != "$cport" ]; then
    warn "$inst/.env says PORT=$iport but $ENV_FILE says $LOCAL_PORT. Only :$LOCAL_PORT is treated as Paperclip's; check tailscale serve status for :$iport."
  fi
fi
TARGETS=""
for p in $PORTS; do TARGETS="$TARGETS http://127.0.0.1:$p"; done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

if [ "$OS" = "Linux" ]; then
  UNIT_FILE="$HOME/.config/systemd/user/$UNIT"
else
  UNIT_FILE="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
fi

# kept_path <VAR> <path>: a path --purge leaves on disk but prints a delete
# command for. It never reaches rm here, but that printed command must not
# point anyone at host logins (~/.claude, ~/.codex), at $HOME or above it, or
# at another service's folder. Refuses (dies) rather than print one.
kept_path() {
  local var="$1" d="$2" nl phys home b c
  nl='
'
  case "$d" in /*) ;; *) die "$var=$d is not an absolute path — refusing." ;; esac
  case "$d" in *"$nl"*|*:*|*"'"*) die "$var=$d contains a newline, colon or quote — refusing." ;; esac
  case "/$d/" in */./*|*/../*) die "$var=$d has a '.' or '..' component — refusing." ;; esac
  home="$(cd "$HOME" && pwd -P)" || die "Cannot resolve $HOME."
  phys="$d"
  if [ -d "$d" ]; then phys="$(cd "$d" && pwd -P)" || die "Cannot resolve $var=$d."; fi
  for b in "$HOME/.claude" "$HOME/.codex"; do
    for c in "$b" "$(cd "$b" 2>/dev/null && pwd -P || true)"; do
      [ -n "$c" ] || continue
      case "$d/" in "$c"/*) die "$var=$d is inside $b (host agent login) — refusing." ;; esac
      case "$phys/" in "$c"/*) die "$var=$d resolves into $b (host agent login) — refusing." ;; esac
    done
  done
  case "$d" in /) die "$var=/ is a folder above \$HOME — refusing." ;; esac
  case "$phys" in /) die "$var=$d resolves to / — refusing." ;; esac
  case "$home/" in "$phys"/*) die "$var=$d is \$HOME or a folder above it — refusing." ;; esac
  case "$HOME/" in "$d"/*) die "$var=$d is \$HOME or a folder above it — refusing." ;; esac
  case "$d/" in
    "$HOME/services"/*)
      real_dir "$d" >/dev/null || die "$var=$d is inside $HOME/services but not a real folder inside $HOME/services/$NAME — refusing." ;;
  esac
  if [ -d "$HOME/services" ]; then
    case "$phys/" in
      "$(cd "$HOME/services" && pwd -P)"/*)
        real_dir "$d" >/dev/null || die "$var=$d resolves inside $HOME/services but not to a real folder inside $HOME/services/$NAME — refusing." ;;
    esac
  fi
  printf '%s' "$d"
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. Every check that can refuse runs
# first, too.
PURGE_FILES=""
if [ "$PURGE" -eq 1 ]; then
  PAPERCLIP_DATA="$(kept_path PAPERCLIP_DATA "$PAPERCLIP_DATA")" || exit 1
  [ -z "$WORKSPACES" ] || { WORKSPACES="$(kept_path AGENT_WORKSPACES "$WORKSPACES")" || exit 1; }
  # Only the files setup.sh writes there, each through real_dir: a symlinked
  # ~/services, ~/services/paperclip or marker file is refused, so nothing
  # outside the real ~/services/paperclip (~/.claude above all) is reachable.
  nl='
'
  for f in $MARKER_FILES; do
    p="$MARKER/$f"
    [ -e "$p" ] || [ -L "$p" ] || continue
    r="$(real_dir "$p")" || die "$p is a symlink, or not inside the real $HOME/services/$NAME — refusing. Nothing was changed."
    [ -f "$r" ] || die "$p is not a regular file — refusing. Nothing was changed."
    PURGE_FILES="$PURGE_FILES$r$nl"
  done
  if [ -L "$UNIT_FILE" ] || { [ -e "$UNIT_FILE" ] && [ ! -f "$UNIT_FILE" ]; }; then
    die "$UNIT_FILE is a symlink or not a regular file; the Paperclip CLI writes a plain file there. Refusing. Nothing was changed."
  fi
  warn "--purge deletes: $(printf '%s' "$PURGE_FILES" | tr '\n' ' ')$( [ -e "$UNIT_FILE" ] && printf '%s ' "$UNIT_FILE")$ENV_FILE. This cannot be undone."
  warn "It keeps the Paperclip instance and CLI under $PAPERCLIP_DATA (database, secrets master.key) and ${WORKSPACES:-the agent workspaces}; it prints how to delete those."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to one of this service's local
# ports, and nothing else: ports are found from what Serve actually
# publishes, not from what .env says was published (a re-run can publish a
# second port, and PAPERCLIP_HTTPS_PORT can differ from the local port). A
# port shared with another handler is left alone with a warning. Never
# `serve reset`. This runs before the service stops: while Serve holds the
# port, a Paperclip restart hops to the next one.
info "Unpublishing Tailscale Serve ports that point at${TARGETS}"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v targets="$TARGETS" '
  BEGIN { nt = split(targets, tl, " "); for (i = 1; i <= nt; i++) want[tl[i]] = 1 }
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
  port != "" && /\|-- / { n++; if (/ proxy / && ($NF in want)) mine++ }
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
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at${TARGETS} (already off)"

# ---------------------------------------------------------------- stop
# Straight to the service manager rather than `paperclipai service
# uninstall`, so the unit file stays for ./setup.sh and the CLI is not needed.
if [ "$OS" = "Linux" ]; then
  if [ -e "$UNIT_FILE" ]; then
    info "Stopping and disabling $UNIT (systemd user unit)"
    systemctl --user disable --now "$UNIT" \
      || die "systemctl --user disable --now $UNIT failed (is the user bus reachable? try from a login shell). Serve is already off; re-run once fixed."
    ok "$UNIT stopped and disabled; unit file kept"
  else
    systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
    ok "No $UNIT_FILE (service not installed)"
  fi
else
  domain="gui/$(id -u)"
  info "Stopping and disabling $LAUNCHD_LABEL (launchd)"
  launchctl bootout "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  launchctl disable "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  ok "$LAUNCHD_LABEL booted out and disabled; ${UNIT_FILE} kept"
fi

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging what setup.sh wrote"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rm -f -- "$r"
  done <<EOF
$PURGE_FILES
EOF
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # files were already gone; skip a symlink (never follow it out of
  # ~/services); rmdir only ever removes an empty directory.
  if [ -d "$MARKER" ] && [ ! -L "$MARKER" ]; then
    rmdir -- "$MARKER" 2>/dev/null \
      || warn "$MARKER still holds files setup.sh did not write, so it is kept."
  fi
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    rm -f -- "$UNIT_FILE"
    [ "$OS" != "Linux" ] || systemctl --user daemon-reload
    ok "Deleted $UNIT_FILE"
  fi
  rm -f -- "$ENV_FILE"
  ok "Deleted the CEO invite and agent markers and $ENV_FILE"
fi

# ----------------------------------------------- neighbours, never touched
# Read-only: units, LaunchAgents and containers that mention Paperclip or
# OpenHands but that this setup.sh does not create (OpenHands is its own
# service; another Paperclip instance is not ours) are named, not touched.
if [ "$OS" = "Linux" ]; then units_dir="$HOME/.config/systemd/user"; else units_dir="$HOME/Library/LaunchAgents"; fi
if [ -d "$units_dir" ]; then
  for f in "$units_dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$f" != "$UNIT_FILE" ] || continue
    case "$(basename "$f")" in
      *[Pp]aperclip*|*[Oo]pen[Hh]ands*) ;;
      *) grep -qi -e paperclip -e openhands "$f" 2>/dev/null || continue ;;
    esac
    warn "Left alone (not created by this setup.sh): $f"
  done
fi
if command -v docker >/dev/null; then
  oh="$(docker ps -a --filter name=openhands --format '{{.Names}}' 2>/dev/null || true)"
  [ -z "$oh" ] || warn "Left alone: OpenHands container(s) $(printf '%s' "$oh" | tr '\n' ' ')— a separate service (services/openhands/teardown.sh or its TROUBLESHOOT.md)."
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed, with its .env, unit file and markers.\n' "$NAME"
  echo
  echo "Kept on purpose (outside ~/services; this script never deletes them):"
  inst="$PAPERCLIP_DATA/instances/default"
  key=""
  for p in "$inst/secrets/master.key" "$PAPERCLIP_DATA/secrets/master.key"; do
    if [ -f "$p" ]; then key="$p"; break; fi
  done
  if [ -n "$key" ]; then
    warn "$key decrypts every secret Paperclip stores. Lose it and any backup of the database is useless."
    echo "  Copy it off this box first (Seafile at :8443), e.g.:"
    echo "    cp -p '$key' <somewhere off-box>"
  fi
  if [ -e "$inst" ]; then
    echo "  Paperclip instance (database, config, secrets incl. master.key):"
    echo "    rm -rf -- '$inst'"
  fi
  if [ -e "$PAPERCLIP_DATA/cli" ]; then
    echo "  Managed Paperclip CLI store:"
    echo "    rm -rf -- '$PAPERCLIP_DATA/cli'"
  fi
  if [ -f "$HOME/.local/bin/paperclipai" ] && grep -q 'paperclipai managed install shim' "$HOME/.local/bin/paperclipai" 2>/dev/null; then
    echo "    rm -f -- '$HOME/.local/bin/paperclipai'"
  fi
  [ -z "$WORKSPACES" ] || [ ! -e "$WORKSPACES/paperclip-test" ] \
    || echo "  Agent workspace (your agents' files): $WORKSPACES/paperclip-test"
  echo "  Until the instance is deleted, ./setup.sh writes a new .env but reuses it."
else
  printf '\033[1;32mDone.\033[0m %s is removed. .env, markers and the Paperclip instance are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete what setup.sh wrote too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
