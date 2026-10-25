#!/usr/bin/env bash
#
# teardown.sh — take Syncthing off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service's GUI,
#      found from `tailscale serve status` (never `serve reset`)
#   2. stop and disable the syncthing user unit setup.sh wrote (Linux:
#      `systemctl --user disable --now syncthing.service`; macOS: disable +
#      bootout of the net.syncthing.syncthing LaunchAgent). The sync listener
#      on <tailnet IP>:22000 goes with the process; there is no Serve mapping
#      for it.
#   3. keep .env, the unit file, config/ (the Device ID), db/ and data/, so
#      ./setup.sh brings it back as the same device
#
# Usage:
#   ./teardown.sh            # safe remove: everything on disk kept
#   ./teardown.sh --purge    # ALSO delete this device's identity and index
#                            # (SYNCTHING_CONFIG, SYNCTHING_DB), .env and the
#                            # unit file; asks you to type "syncthing" first.
#                            # Terminal only: the launcher's Remove button
#                            # never passes it.
#   ./teardown.sh --purge --delete-synced-files
#                            # ... and SYNCTHING_DATA, the synced files.
#
# THE THREE DIRECTORIES ARE THREE DIFFERENT DELETES. config/ is the Device ID
# (cert.pem/key.pem): delete it and every peer sees a NEW device and must
# re-add this box. db/ is only the index (a rescan rebuilds it). data/ is the
# synced FILES. --purge takes config/ and db/ and KEEPS data/: peers usually
# hold a copy of those files, but not always (a folder never shared, a
# receive-only peer, a peer that is off), and a "fresh start" should not
# silently be a data loss. Pass --delete-synced-files too if you mean it.
# Folders you added in the GUI at other paths are never deleted.
#
# .env goes WITH config/, never one without the other: a surviving .env with
# no config.xml pins a fresh config to a SYNCTHING_LISTEN_IP that may be stale
# (setup.sh dies on that split state).
#
# The binary in ~/.local/bin/syncthing is left in place: ~/.local/bin is not
# this service's directory. The Done line says how to remove it by hand.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="syncthing"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/syncthing"
BIN="$HOME/.local/bin/syncthing"
UNIT_NAME="syncthing.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
LABEL="net.syncthing.syncthing"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

USAGE="usage: ./teardown.sh [--purge [--delete-synced-files]]"
PURGE=0
FILES=0
[ "$#" -le 2 ] || die "Too many arguments ($USAGE)"
for a in "$@"; do
  case "$a" in
    --purge) [ "$PURGE" -eq 0 ] || die "--purge given twice ($USAGE)"; PURGE=1 ;;
    --delete-synced-files) [ "$FILES" -eq 0 ] || die "--delete-synced-files given twice ($USAGE)"; FILES=1 ;;
    *) die "Unknown option: $a ($USAGE)" ;;
  esac
done
[ "$FILES" -eq 0 ] || [ "$PURGE" -eq 1 ] || die "--delete-synced-files only makes sense with --purge ($USAGE)"

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
else
  command -v launchctl >/dev/null || die "launchctl is required on macOS."
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
CONFIG_DIR="$(env_get SYNCTHING_CONFIG)"
DB_DIR="$(env_get SYNCTHING_DB)"
DATA_DIR="$(env_get SYNCTHING_DATA)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: GUI local :$LOCAL_PORT, identity ${CONFIG_DIR:-(not set)}, index ${DB_DIR:-(not set)}, files ${DATA_DIR:-(not set)}"

# There is no Compose project here (a native binary under a user unit); the
# guard below is the shared one, kept byte-identical across services. A
# COMPOSE_* variable in this .env is still something setup.sh never writes.
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

# Other units that mention Syncthing but that setup.sh never writes (a
# distro-packaged syncthing@.service you copied here, a backup timer that
# reads the config dir, ...). Read-only listing: they are named, never
# stopped, disabled or deleted.
if [ "$OS" = "Linux" ]; then own_dir="$UNIT_DIR"; own_file="$UNIT_NAME"
else own_dir="$AGENT_DIR"; own_file="$LABEL.plist"; fi
OTHER_UNITS=""
if [ -d "$own_dir" ]; then
  for f in "$own_dir"/*; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" != "$own_file" ] || continue
    case "$b" in
      *[Ss]yncthing*) OTHER_UNITS="$OTHER_UNITS $b"; continue ;;
    esac
    if [ -f "$f" ] && grep -qi syncthing "$f" 2>/dev/null; then OTHER_UNITS="$OTHER_UNITS $b"; fi
  done
fi

# One state directory to delete: strip trailing slashes, refuse '..', require
# the textual prefix ~/services/, then resolve symlinks and require a strict
# child of the real ~/services. Sets RESOLVED to the real path, or "" when the
# directory is not on disk. Dies on anything odd, before any change is made.
RESOLVED=""
guard_dir() {  # guard_dir VARNAME VALUE
  local var="$1" dir="$2" root
  RESOLVED=""
  [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
  while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
  case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
  case "$dir" in
    "$HOME/services/"?*) ;;
    *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    RESOLVED="$(real_dir "$dir")" || die "$var=$dir is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$RESOLVED" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $RESOLVED, which is not a folder inside $root — refusing." ;;
    esac
  fi
}

# True when path $1 is $2 or lies inside it.
is_within() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }
strip_slashes() {
  local p="$1"
  while :; do case "$p" in ?*/) p="${p%/}" ;; *) break ;; esac; done
  printf '%s' "$p"
}
# The real path of an existing directory, or the text as given.
real_or_text() { if [ -d "$1" ]; then (cd "$1" && pwd -P) || printf '%s' "$1"; else printf '%s' "$1"; fi; }

# systemd's own view of $UNIT_NAME, whether or not the file is still on disk:
# a unit file deleted while the service ran leaves it loaded and running.
# Sets U_ACTIVE and U_FRAG (the file it was loaded from, "" once systemd has
# forgotten it); fails when systemd cannot be asked.
U_ACTIVE=""; U_FRAG=""
unit_probe() {
  local out
  U_ACTIVE=""; U_FRAG=""
  out="$(systemctl --user show -p LoadState -p ActiveState -p FragmentPath -- "$UNIT_NAME" 2>/dev/null)" || return 1
  U_ACTIVE="$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p')"
  U_FRAG="$(printf '%s\n' "$out" | sed -n 's/^FragmentPath=//p')"
  [ -n "$U_ACTIVE" ]
}
unit_running() { case "$U_ACTIVE" in inactive|failed) return 1 ;; *) return 0 ;; esac; }
# Running from setup.sh's unit (its path, or no file at all any more), as
# opposed to a distro package's /usr/lib/systemd/user/syncthing.service.
unit_is_ours() { [ -z "$U_FRAG" ] || [ "$U_FRAG" = "$UNIT" ]; }
agent_loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIRS=()
KEPT=()
if [ "$PURGE" -eq 1 ]; then
  # The synced files are the one thing a plain --purge must not take. Without
  # knowing where they are, nothing proves the identity/index dirs are safe.
  [ -n "$DATA_DIR" ] || die "SYNCTHING_DATA is missing from $ENV_FILE — refusing to purge when the synced files cannot be located."
  data_text="$(strip_slashes "$DATA_DIR")"
  case "$data_text" in /*) ;; *) die "SYNCTHING_DATA=$DATA_DIR is not an absolute path — refusing to purge." ;; esac
  data_real="$(real_or_text "$data_text")"

  # Every folder the running config syncs, not just the 'default' one setup.sh
  # made: the user may have added folders at any path, including (by mistake)
  # inside config/ or db/. Read from config.xml as XML, not line by line: the
  # file is split at every '<' (which XML never allows raw inside a value), so
  # a <folder> start tag is found with its attributes spread over any number
  # of lines, in any order, single- or double-quoted. <defaults> holds a
  # template folder (skipped). Prints P<path> per folder, E for a folder tag
  # this reader cannot be sure of, and T<count> of all folder tags seen; any
  # E, or a '<folder' in the file with no tag counted, refuses the purge.
  FOLDERS=()
  cfg_xml="$(strip_slashes "${CONFIG_DIR:-}")/config.xml"
  if [ -n "$CONFIG_DIR" ] && [ -f "$cfg_xml" ]; then
    [ -r "$cfg_xml" ] || die "Cannot read $cfg_xml, so the synced folders cannot be located — refusing to purge."
    folder_scan="$(awk '
      # Entity references as Syncthing (Go encoding/xml) writes them, plus the
      # named ones a hand edit might use. Anything else: not sure, so bad.
      function decode(v,   out, i, j, ent) {
        out = ""
        while ((i = index(v, "&")) > 0) {
          out = out substr(v, 1, i - 1); v = substr(v, i)
          j = index(v, ";")
          if (j == 0) { bad = 1; return "" }
          ent = substr(v, 2, j - 2)
          if (ent == "lt" || ent == "#60" || ent == "#x3C" || ent == "#x3c") out = out "<"
          else if (ent == "gt" || ent == "#62" || ent == "#x3E" || ent == "#x3e") out = out ">"
          else if (ent == "quot" || ent == "#34" || ent == "#x22") out = out "\""
          else if (ent == "apos" || ent == "#39" || ent == "#x27") out = out "\047"
          else if (ent == "amp" || ent == "#38" || ent == "#x26") out = out "&"
          else { bad = 1; return "" }
          v = substr(v, j + 1)
        }
        return out v
      }
      { buf = buf $0 "\n" }
      END {
        n = split(buf, rec, "<"); tags = 0; indef = 0
        for (k = 2; k <= n; k++) {
          r = rec[k]
          if (r ~ /^\/defaults([ \t\r\n>]|$)/) { indef = 0; continue }
          if (r ~ /^defaults([ \t\r\n\/>]|$)/) {
            t = r; e = index(t, ">"); if (e > 0) t = substr(t, 1, e - 1)
            if (t !~ /\/[ \t\r\n]*$/) indef = 1
            continue
          }
          if (r !~ /^folder([ \t\r\n\/>]|$)/) continue
          tags++
          if (indef) continue
          s = substr(r, 7); bad = 0; found = 0; path = ""
          while (1) {
            sub(/^[ \t\r\n]+/, "", s)
            c = substr(s, 1, 1)
            if (c == ">" || c == "/") break
            if (c == "" || !match(s, /^[^ \t\r\n=\/>"\047]+/)) { bad = 1; break }
            name = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
            sub(/^[ \t\r\n]+/, "", s)
            if (substr(s, 1, 1) != "=") { bad = 1; break }
            s = substr(s, 2); sub(/^[ \t\r\n]+/, "", s)
            q = substr(s, 1, 1)
            if (q != "\"" && q != "\047") { bad = 1; break }
            s = substr(s, 2); e = index(s, q)
            if (e == 0) { bad = 1; break }
            v = substr(s, 1, e - 1); s = substr(s, e + 1)
            if (name == "path") {
              if (found) { bad = 1; break }
              found = 1; path = decode(v)
            }
          }
          # A raw tab or line break inside the value: Syncthing and this list
          # could disagree on what it is.
          if (bad || !found || path ~ /[\t\r\n]/) { print "E"; continue }
          print "P" path
        }
        print "T" tags
      }' "$cfg_xml")" || die "Could not parse $cfg_xml, so the synced folders cannot be located — refusing to purge. Nothing was changed."
    folder_tags=""
    while IFS= read -r line; do
      case "$line" in
        T*) folder_tags="${line#T}" ;;
        E*) die "A <folder> entry in $cfg_xml could not be read for certain (no single, quoted path= attribute, or an unknown &...; reference), so teardown cannot tell whether purge would delete synced files — refusing to purge. Nothing was changed." ;;
        P*)
          p="${line#P}"
          [ -n "$p" ] || continue
          case "$p" in \~) p="$HOME" ;; \~/*) p="$HOME/${p#\~/}" ;; esac
          case "$p" in /*) ;; *) die "Folder path \"$p\" in $cfg_xml is not absolute, so teardown cannot tell where those synced files are — refusing to purge. Nothing was changed." ;; esac
          FOLDERS+=("$(strip_slashes "$p")")
          ;;
      esac
    done <<EOF_FOLDERS
$folder_scan
EOF_FOLDERS
    if [ "${folder_tags:-0}" -eq 0 ] && grep -Eq '<folder([[:space:]/>]|$)' "$cfg_xml"; then
      die "$cfg_xml mentions <folder but no folder entry could be read from it, so teardown cannot tell where the synced files are — refusing to purge. Nothing was changed."
    fi
  fi

  # Identity and index: each guarded, and refused outright if it would take
  # the synced files (SYNCTHING_DATA, unless those go too) or any folder with
  # it. The index dir goes before the identity dir, which goes right before
  # .env (see the purge step).
  for pair in "SYNCTHING_DB:$DB_DIR" "SYNCTHING_CONFIG:$CONFIG_DIR"; do
    guard_dir "${pair%%:*}" "${pair#*:}"
    [ -n "$RESOLVED" ] || continue
    d_text="$(strip_slashes "${pair#*:}")"
    protect=()
    [ "$FILES" -eq 1 ] || protect+=("$data_text")
    protect+=(${FOLDERS[@]+"${FOLDERS[@]}"})
    for p in ${protect[@]+"${protect[@]}"}; do
      p_real="$(real_or_text "$p")"
      if is_within "$p_real" "$RESOLVED" || is_within "$p" "$d_text" || is_within "$p_real" "$d_text"; then
        die "${pair%%:*}=$d_text contains synced files ($p) — refusing to purge, since that would delete them. Move that folder out of $d_text (or point ${pair%%:*} at its own directory) and re-run."
      fi
    done
    PURGE_DIRS+=("$RESOLVED")
  done

  # The synced files: only with the second flag, and only from inside
  # ~/services/syncthing (the same guard). Folders elsewhere are kept.
  DATA_PURGE=""
  if [ "$FILES" -eq 1 ]; then
    guard_dir "SYNCTHING_DATA" "$DATA_DIR"
    DATA_PURGE="$RESOLVED"
    [ -z "$DATA_PURGE" ] || PURGE_DIRS=("$DATA_PURGE" "${PURGE_DIRS[@]}")
  else
    KEPT+=("$data_text")
  fi
  for p in ${FOLDERS[@]+"${FOLDERS[@]}"}; do
    p_real="$(real_or_text "$p")"
    # Inside SYNCTHING_DATA: already counted (kept as part of it, or deleted).
    if is_within "$p" "$data_text" || is_within "$p_real" "$data_real"; then continue; fi
    KEPT+=("$p")
  done

  # With the unit file gone the stop step below has nothing to disable, but
  # Syncthing may still be running from it. Purge only once systemd can say
  # what runs under the name, and only when that is (or was) our unit.
  if [ "$OS" = "Linux" ] && [ ! -e "$UNIT" ] && [ ! -L "$UNIT" ]; then
    unit_probe || die "No $UNIT, and systemd could not say whether $UNIT_NAME is still running (systemctl --user show failed) — refusing to purge. Nothing was changed."
    if unit_running && ! unit_is_ours; then
      die "$UNIT_NAME is running from $U_FRAG, which setup.sh did not write, so teardown will not stop it or delete state it may be using — refusing to purge. Nothing was changed. If it is this deploy's Syncthing, stop it (systemctl --user stop $UNIT_NAME) and re-run."
    fi
  fi

  warn "--purge deletes ${PURGE_DIRS[*]:-nothing (no state dirs on disk)}, $ENV_FILE and the $NAME unit file. This cannot be undone."
  warn "  This is the Device ID: every peer will see a NEW device and must re-add this box. Back up ${CONFIG_DIR} first if you may want it back."
  if [ "${#KEPT[@]}" -gt 0 ]; then
    warn "  Synced files are NOT deleted: ${KEPT[*]}"
  fi
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
# Disable + stop through the unit file setup.sh wrote. With that file gone,
# systemd (or launchd) is asked what is still loaded under the name: a unit
# deleted while it ran keeps running until stopped. It is stopped only when
# it is ours; `syncthing.service` may also resolve to a distro package's
# /usr/lib/systemd/user unit, which is not this deploy's to stop.
if [ "$OS" = "Linux" ]; then
  if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
    info "Stopping and disabling $UNIT_NAME (systemctl --user disable --now)"
    systemctl --user disable --now "$UNIT_NAME"
    ok "$UNIT_NAME stopped and disabled; the sync listener on :22000 is closed"
  elif ! unit_probe; then
    warn "No $UNIT, and systemd could not say whether $UNIT_NAME is still running. If it is: systemctl --user stop $UNIT_NAME"
  elif ! unit_running; then
    ok "No $UNIT and nothing running as $UNIT_NAME; nothing to stop"
  elif unit_is_ours; then
    info "$UNIT is gone but $UNIT_NAME is still running from it; stopping it (systemctl --user stop)"
    systemctl --user stop "$UNIT_NAME"
    ok "$UNIT_NAME stopped; the sync listener on :22000 is closed"
  else
    warn "$UNIT_NAME is running from $U_FRAG, which setup.sh did not write, so it is left running."
  fi
else
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    info "Stopping the $LABEL LaunchAgent (launchctl disable + bootout)"
    # disable first: the plist stays (so ./setup.sh can restore it), and with
    # RunAtLoad it would otherwise start again at the next login. setup.sh
    # re-enables the label before it bootstraps.
    launchctl disable "gui/$(id -u)/$LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    ok "$LABEL stopped and disabled; the sync listener on :22000 is closed"
  elif agent_loaded; then
    info "$PLIST is gone but $LABEL is still loaded; unloading it (launchctl bootout)"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    ok "$LABEL unloaded; the sync listener on :22000 is closed"
  else
    ok "No $PLIST and nothing loaded as $LABEL; nothing to stop"
  fi
fi
if [ -n "$OTHER_UNITS" ]; then
  warn "Also in $own_dir and mentioning Syncthing, but not written by setup.sh, so left exactly as they are:$OTHER_UNITS"
fi

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  # Never delete the identity or index under a Syncthing that is still up.
  if [ "$OS" = "Linux" ]; then
    unit_probe || die "Could not ask systemd whether $UNIT_NAME stopped. Nothing was deleted and $ENV_FILE is kept; re-run ./teardown.sh --purge."
    ! unit_running || die "$UNIT_NAME is still running (${U_FRAG:-no unit file}). Nothing was deleted and $ENV_FILE is kept: stop it (systemctl --user stop $UNIT_NAME) and re-run ./teardown.sh --purge."
  else
    ! agent_loaded || die "$LABEL is still loaded. Nothing was deleted and $ENV_FILE is kept: launchctl bootout gui/$(id -u)/$LABEL, then re-run ./teardown.sh --purge."
  fi
  info "Purging this device's identity and index${DATA_PURGE:+ and the synced files}"
  # Files first, index next, identity last, then .env straight after it: a
  # failure part-way keeps .env, so ./teardown.sh --purge can simply be re-run.
  for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
    rm -rf -- "$d" || die "Could not delete $d. $ENV_FILE is kept: fix the permissions and re-run ./teardown.sh --purge (do not run ./setup.sh in between)."
    ok "Deleted $d"
  done
  rm -f -- "$ENV_FILE"
  if [ "$OS" = "Linux" ]; then
    if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
      rm -f -- "$UNIT"
      systemctl --user daemon-reload
      ok "Deleted $UNIT"
    fi
  else
    if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
      rm -f -- "$PLIST"
      ok "Deleted $PLIST"
    fi
    # Clear the disable override set above; the label has no plist any more.
    launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
  fi
  # The default sync root setup.sh makes: removed only when empty, so the
  # marker below can go. Anything with files in it stays.
  if [ "$FILES" -eq 0 ] && is_within "$data_text" "$STATE"; then
    [ -L "$data_text/default" ] || rmdir -- "$data_text/default" 2>/dev/null || true
    [ -L "$data_text" ] || rmdir -- "$data_text" 2>/dev/null || true
  fi
  # ~/services/<name> is the launcher's install marker. Try it even when the
  # data dir was already gone, so a purged app never reads as installed;
  # rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  ok "Deleted $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and this device identity is gone. ./setup.sh starts fresh as a NEW device: re-add it on every peer with the new Device ID.\n' "$NAME"
  if [ "${#KEPT[@]}" -gt 0 ]; then
    echo "  Synced files kept: ${KEPT[*]}"
    echo "  They are ordinary files; delete them by hand (rm -rf <path>) if you mean it."
  fi
  if [ -e "$BIN" ]; then
    echo "  The binary is still at $BIN (~/.local/bin is not this service's folder)."
    echo "  Remove it if nothing else uses it: rm $BIN"
  fi
else
  printf '\033[1;32mDone.\033[0m %s is removed. Identity, index, synced files, .env and the unit file are kept; ./setup.sh brings it back as the same device.\n' "$NAME"
  echo "  Delete identity + index too (keeps the synced files): ./teardown.sh --purge"
  echo "  ... and the synced files in SYNCTHING_DATA: ./teardown.sh --purge --delete-synced-files"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
