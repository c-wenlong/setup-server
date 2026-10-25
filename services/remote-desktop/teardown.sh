#!/usr/bin/env bash
#
# teardown.sh — take remote-desktop (Guacamole in front of this box's GNOME
# Remote Login) off this box. Linux only, like setup.sh.
#
# The inverse of setup.sh's run + publish, and nothing more by default:
#   1. unpublish the Tailscale Serve ports that point at THIS service's
#      webapp, found from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down` — guacd, the webapp and the remote-desktop bridge
#      go; GUAC_STATE (user-mapping.xml, the cert copy) stays
#   3. keep .env and GUAC_STATE, so ./setup.sh brings it back as it was
#
# What the default does NOT touch, on purpose: the SYSTEM-level half setup.sh
# configured with sudo. gnome-remote-desktop's Remote Login (RDP on :3389,
# wildcard-bound and impossible to rebind), the nftables table
# `inet remote_desktop` that keeps that listener off the LAN, and the RDP TLS
# keypair. The launcher's Remove has no terminal and must never prompt for
# sudo, and the filter must never go while the listener is still up. So the
# default leaves the filter guarding the listener and prints exactly what is
# left and how to back it out. Your desktop is not exposed afterwards.
#
# Usage:
#   ./teardown.sh                    # safe remove: containers + Serve; state,
#                                    # .env and every system change kept
#   ./teardown.sh --system           # ALSO back out the system half with sudo,
#                                    # in the safe order: RDP off, verify :3389
#                                    # closed, THEN the filter. Terminal only.
#   ./teardown.sh --purge            # ALSO delete GUAC_STATE and .env; asks you
#                                    # to type "remote-desktop" first. Terminal
#                                    # only: the launcher's Remove button never
#                                    # passes it (or --system).
#   ./teardown.sh --system --purge   # both; the system half runs first, while
#                                    # .env still says which port to check
#
# Never touched by any mode: gdm, the graphical target, the
# gnome-remote-desktop package or its unit (it was enabled and running before
# this service existed), any other nftables table, `tailscale set --operator`.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="remote-desktop"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# The exact system paths and names setup.sh creates. Fixed there, fixed here.
FW_RULES="/etc/remote-desktop/rdp-firewall.nft"
FW_DIR="/etc/remote-desktop"
FW_UNIT_NAME="remote-desktop-firewall.service"
FW_UNIT="/etc/systemd/system/$FW_UNIT_NAME"
NFT_TABLE="inet remote_desktop"
CERT_DIR="/var/lib/gnome-remote-desktop/certificates"
CERT_PATH="$CERT_DIR/rdp-tls.crt"
KEY_PATH="$CERT_DIR/rdp-tls.key"

PURGE=0; SYSTEM=0
USAGE="usage: ./teardown.sh [--system] [--purge]"
[ "$#" -le 2 ] || die "Too many arguments ($USAGE)"
for arg in "$@"; do
  case "$arg" in
    --purge)  PURGE=1 ;;
    --system) SYSTEM=1 ;;
    *) die "Unknown option: $arg ($USAGE)" ;;
  esac
done

WORK=""
PKTTYAGENT_PID=""
cleanup() {
  [ -n "$PKTTYAGENT_PID" ] && kill "$PKTTYAGENT_PID" 2>/dev/null || true
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in
  Linux) ;;
  Darwin) die "macOS never hosts remote-desktop (setup.sh refuses it: the Mac is the client), so there is nothing to tear down here." ;;
  *) die "Unsupported OS: $OS (Linux only for this service)" ;;
esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root. --system escalates with sudo exactly where it must, and announces it first."
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
command -v docker >/dev/null || die "Docker is not installed."
docker ps >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Run via: sg docker -c ./teardown.sh"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
command -v tailscale >/dev/null || die "Tailscale is not installed: https://tailscale.com/download"
TAILSCALE="tailscale"

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
GUAC_PORT="$(env_get GUAC_PORT)"
RDP_PORT="$(env_get RDP_PORT)"
RDP_USER="$(env_get RDP_USER)"
GUAC_STATE="$(env_get GUAC_STATE)"
GUAC_HOME="$(env_get GUAC_HOME)"
case "$GUAC_PORT" in ''|*[!0-9]*) die "GUAC_PORT in $ENV_FILE is missing or not numeric (got: $GUAC_PORT)";; esac
case "$RDP_PORT"  in ''|*[!0-9]*) die "RDP_PORT in $ENV_FILE is missing or not numeric (got: $RDP_PORT)";; esac
TARGET="http://127.0.0.1:$GUAC_PORT"
ok "$NAME: webapp :$GUAC_PORT, RDP :$RDP_PORT, state ${GUAC_STATE:-(not set)}"

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

# A purge target from .env, checked the way the reference teardown checks its
# data dir: inside ~/services/, no '..', a real directory, and (through
# real_dir) ~/services/remote-desktop itself or inside it. Sets PT to the
# resolved path, or to "" when the directory is already gone. Dies, in this
# shell, on anything else.
PT=""
purge_target() {  # purge_target <KEY> <value>
  local key="$1" d="$2" root
  PT=""
  [ -n "$d" ] || die "$key is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$d" in */) d="${d%/}" ;; *) break ;; esac; done
  case "$d" in *..*) die "$key=$d contains '..' — refusing." ;; esac
  case "$d" in
    "$HOME/services/"?*) ;;
    *) die "$key=$d is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  [ -e "$d" ] || return 0
  [ -d "$d" ] || die "$key=$d is not a directory — refusing."
  root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
  PT="$(real_dir "$d")" || die "$key=$d is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
  case "$PT" in
    "$root"/?*) ;;
    *) die "$key=$d resolves to $PT, which is not a folder inside $root — refusing." ;;
  esac
}

# --system: everything it needs is checked here, before anything changes.
STATE_REAL=""
if [ "$SYSTEM" -eq 1 ]; then
  [ -t 0 ] || die "--system needs a terminal: it prompts for sudo. Run it yourself from SSH or the console (the launcher never passes it). Nothing was changed."
  for c in sudo systemctl grdctl python3; do
    command -v "$c" >/dev/null || die "--system needs $c, which is not installed. Nothing was changed."
  done
  # The markers setup.sh keeps about the system half (the cert copy and the
  # applied fingerprints) are cleared along with it, or the next ./setup.sh
  # would trust a keypair that is gone. Same path rules as a purge.
  purge_target GUAC_STATE "$GUAC_STATE"; STATE_REAL="$PT"
fi

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""; PURGE_HOME=""
if [ "$PURGE" -eq 1 ]; then
  purge_target GUAC_STATE "$GUAC_STATE"; PURGE_DIR="$PT"
  # GUAC_HOME sits inside GUAC_STATE as setup.sh writes it; a hand-moved one
  # gets the same checks and goes too, but only if it is not already inside.
  purge_target GUAC_HOME "$GUAC_HOME"; PURGE_HOME="$PT"
  case "$PURGE_HOME" in "$PURGE_DIR"|"$PURGE_DIR"/*) [ -z "$PURGE_DIR" ] || PURGE_HOME="" ;; esac
  warn "--purge deletes ${PURGE_DIR:-nothing (no state dir on disk)}${PURGE_HOME:+ and $PURGE_HOME} and $ENV_FILE. This cannot be undone."
  warn "That is user-mapping.xml (the browser login and the RDP password), the cert copy, and the generated Guacamole password."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# User units are not something setup.sh creates. If any on this box mention
# this service, someone else made them: name them, leave them alone.
UNIT_DIR="$HOME/.config/systemd/user"
if [ -d "$UNIT_DIR" ]; then
  others="$(find "$UNIT_DIR" -maxdepth 1 -type f -exec grep -lE 'remote-desktop|guacamole|guacd' {} + 2>/dev/null || true)"
  if [ -n "$others" ]; then
    warn "User units that mention $NAME, NOT created by setup.sh and so left alone:"
    printf '%s\n' "$others" | sed 's#^.*/#     #'
  fi
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's webapp, and
# nothing else: ports are found from what Serve actually publishes, not from
# what .env says was published (a re-run can publish a second port). setup.sh
# publishes the /guacamole/ context path, so a handler matches on the exact
# origin or the origin followed by a path, never a longer port number. A port
# shared with another handler is left alone with a warning. Never `serve reset`.
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
  port != "" && /\|-- / { n++; if (/ proxy / && ($NF == t || index($NF, t "/") == 1)) mine++ }
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
# No named volumes in this compose file, and no -v either way: GUAC_HOME is a
# bind mount. An open browser session to this desktop ends here.
info "Stopping and removing guacd + guacamole (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Containers and the remote-desktop bridge removed; state in ${GUAC_STATE:-(not set)} kept"

# ---------------------------------------------------------------- system
if [ "$SYSTEM" -eq 1 ]; then
  WORK="$(mktemp -d)"
  chmod 700 "$WORK"
  cat > "$WORK/probe.py" <<'PYEOF_7c1d'
import socket, sys

def tcp(host, port, timeout=4.0):
    """open | refused | filtered | error:<why>"""
    try:
        s = socket.create_connection((host, port), timeout)
        s.close()
        return "open"
    except ConnectionRefusedError:
        return "refused"
    except socket.timeout:
        return "filtered"
    except OSError as e:
        return "filtered" if e.errno in (113, 101) else "error:%s" % e

print({"tcp": tcp}[sys.argv[1]](sys.argv[2], int(sys.argv[3])))
PYEOF_7c1d
  probe() { python3 "$WORK/probe.py" "$@"; }

  echo
  info "Backing out the system half. This needs sudo. Exactly what will change, in this order:"
  echo "     grdctl --system rdp disable / clear-credentials   (Remote Login off, $RDP_USER's password forgotten)"
  echo "     systemctl restart gnome-remote-desktop.service    (restart, NOT stop: it predates this service)"
  echo "     wait until 127.0.0.1:$RDP_PORT refuses            (stops here, filter kept, if it does not)"
  echo "     systemctl disable --now $FW_UNIT_NAME  (drops nftables table '$NFT_TABLE', and only that)"
  echo "     rm $FW_RULES $FW_UNIT; systemctl daemon-reload"
  echo "     rm $CERT_PATH $KEY_PATH"
  echo "   gdm, the graphical session and every other firewall rule are NOT touched."
  echo "   If you are typing this inside a remote-desktop session, that session ends."
  echo

  # grdctl --system goes through polkit; give it a text agent, as setup.sh does.
  if command -v pkttyagent >/dev/null 2>&1; then
    pkttyagent --process $$ >/dev/null 2>&1 & PKTTYAGENT_PID=$!
    sleep 1
  fi

  # 1. The listener first. The filter is still up, so nothing is exposed at
  #    any point in this block, whichever step fails.
  sudo grdctl --system rdp disable \
    || die "\`sudo grdctl --system rdp disable\` failed. Nothing else was changed: the packet filter is still in place, so :$RDP_PORT is still off the LAN."
  sudo grdctl --system rdp clear-credentials \
    || warn "\`sudo grdctl --system rdp clear-credentials\` failed; the stored RDP credentials for $RDP_USER remain. RDP itself is disabled."
  sudo systemctl restart gnome-remote-desktop.service \
    || die "Could not restart gnome-remote-desktop.service, so RDP may still be listening. The packet filter is left in place. journalctl -u gnome-remote-desktop -n 50"

  info "Waiting for 127.0.0.1:$RDP_PORT to refuse connections"
  state=""
  for _ in $(seq 1 15); do
    state="$(probe tcp 127.0.0.1 "$RDP_PORT")"
    [ "$state" = "refused" ] && break
    sleep 2
  done
  [ "$state" = "refused" ] || die "Something still answers on 127.0.0.1:$RDP_PORT after the backend was disabled (probe said: $state).
     The packet filter is LEFT IN PLACE on purpose: removing it now would put
     that listener on the LAN. Find out what it is (ss -ltnp | grep :$RDP_PORT;
     journalctl -u gnome-remote-desktop -n 50), then re-run ./teardown.sh --system."
  ok "RDP is off: 127.0.0.1:$RDP_PORT refuses"

  # 2. Only now the filter. Its ExecStop deletes the one table by name; the
  #    explicit delete below is for a table that outlived its unit. Never a
  #    flush: other tables on this box belong to docker, tailscale, ufw.
  if systemctl is-enabled --quiet "$FW_UNIT_NAME" 2>/dev/null \
     || systemctl is-active --quiet "$FW_UNIT_NAME" 2>/dev/null; then
    sudo systemctl disable --now "$FW_UNIT_NAME" \
      || die "Could not stop $FW_UNIT_NAME. RDP is already off, so nothing is exposed. systemctl status $FW_UNIT_NAME"
    ok "$FW_UNIT_NAME stopped and disabled"
  else
    ok "$FW_UNIT_NAME is not enabled (already removed)"
  fi
  if sudo nft list table $NFT_TABLE >/dev/null 2>&1; then
    sudo nft delete table $NFT_TABLE || die "Could not delete nftables table '$NFT_TABLE'. RDP is off, so nothing is exposed."
    ok "nftables table '$NFT_TABLE' deleted"
  fi
  sudo rm -f -- "$FW_UNIT" "$FW_RULES"
  sudo rmdir -- "$FW_DIR" 2>/dev/null || true
  sudo systemctl daemon-reload || warn "systemctl daemon-reload failed; run it by hand."
  ok "Removed $FW_UNIT and $FW_RULES"

  # 3. The keypair setup.sh generated, and the markers that claim it exists.
  sudo rm -f -- "$CERT_PATH" "$KEY_PATH"
  if [ -n "$STATE_REAL" ]; then
    rm -f -- "$STATE_REAL/rdp-tls.crt" "$STATE_REAL/.applied/rdp-cert" "$STATE_REAL/.applied/rdp-config"
  fi
  ok "Removed the RDP TLS keypair; the next ./setup.sh generates a new one"
fi

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging state"
  # Everything here is written by this user (the webapp runs as your uid and
  # mounts GUAC_HOME read-only), so a plain rm is enough. If it is not,
  # something else wrote files here: look before forcing it. .env is kept so
  # nothing pretends to be fresh.
  for d in "$PURGE_DIR" "$PURGE_HOME"; do
    [ -n "$d" ] || continue
    rm -rf -- "$d" 2>/dev/null || true
    [ ! -e "$d" ] || die "$d is still there (files this deploy did not write?). Look at it, then: sudo rm -rf $d   and ./teardown.sh --purge again. .env was kept."
  done
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted ${PURGE_DIR:-(no state dir)}${PURGE_HOME:+, $PURGE_HOME} and $ENV_FILE"
fi

# ---------------------------------------------------------------- report
if [ "$SYSTEM" -eq 0 ]; then
  echo
  warn "The system half setup.sh configured with sudo is still in place (the launcher never uses sudo):"
  echo "     - gnome-remote-desktop Remote Login: RDP enabled on :$RDP_PORT (all interfaces),"
  echo "       with stored credentials for ${RDP_USER:-the RDP user}"
  echo "     - nftables table '$NFT_TABLE' via $FW_UNIT_NAME"
  echo "       ($FW_UNIT, $FW_RULES)"
  echo "     - the RDP TLS keypair $CERT_PATH and .key"
  echo "   Nothing is exposed: the filter still holds :$RDP_PORT to loopback. Leave it on"
  echo "   while RDP is enabled. To back all of it out, from a terminal:"
  echo "       ./teardown.sh --system$([ "$PURGE" -eq 1 ] && echo '   (needs .env, which --purge just deleted: use the commands below)')"
  echo "   or by hand, IN THIS ORDER (RDP off and verified closed BEFORE the filter goes):"
  echo "       sudo grdctl --system rdp disable && sudo grdctl --system rdp clear-credentials"
  echo "       sudo systemctl restart gnome-remote-desktop.service"
  echo "       ss -ltn | grep ':$RDP_PORT '     # expect nothing before going on"
  echo "       sudo systemctl disable --now $FW_UNIT_NAME"
  echo "       sudo rm -f $FW_UNIT $FW_RULES && sudo rmdir $FW_DIR"
  echo "       sudo systemctl daemon-reload"
  echo "       sudo rm -f $CERT_PATH $KEY_PATH"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its state is gone. ./setup.sh starts fresh (new passwords).\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. State and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the state too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
