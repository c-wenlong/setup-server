#!/usr/bin/env bash
#
# teardown.sh — take self-learn off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at the app's local port,
#      found from `tailscale serve status` (never `serve reset`). The studio
#      runner (127.0.0.1:7250) and Postgres (127.0.0.1:PG_PORT) are loopback
#      only and never published, so there is nothing of theirs to unpublish
#   2. stop what setup.sh starts, in this order, so the poller cannot bring
#      anything back mid-teardown:
#        the deploy + export timers (and any deploy/export run in flight),
#        self-learn-studio, self-learn (the app), then Postgres
#        (`docker compose down`: the self-learn-db container goes, the
#        named volume holding the catalog stays)
#      Linux: `systemctl --user disable --now`; macOS: `launchctl bootout`
#      then `launchctl disable`, so login does not reload them.
#   3. keep .env, the unit files / LaunchAgents, ~/services/self-learn and
#      the volume, so ./setup.sh brings it back as it was
#
# Never touched, purge included: ~/.self-learn (SELF_LEARN_HOME: blobs,
# vault, and the nightly exports in ~/.self-learn/archive), and anything
# sync.sh installs (self-learn-seafile.service, ~/services/self-learn/seafile).
#
# Usage:
#   ./teardown.sh            # safe remove: data and .env kept
#   ./teardown.sh --purge    # ALSO delete the Postgres volume (down -v), the
#                            # deploy clone, state and studio dirs under
#                            # ~/services/self-learn, the unit files and
#                            # .env; asks you to type "self-learn" first.
#                            # Terminal only: the launcher's Remove button
#                            # never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="self-learn"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

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
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }
command -v docker >/dev/null || die "Docker is not installed."
if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Run via: sg docker -c ./teardown.sh"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
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
SERVICE_HOME="$(env_get SERVICE_HOME)"
SELF_LEARN_HOME="$(env_get SELF_LEARN_HOME)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
[ -n "$SERVICE_HOME" ] || die "SERVICE_HOME is missing from $ENV_FILE — setup.sh always writes it, so this .env is not one teardown can trust."
# env_get expands $HOME and ${HOME} only, but setup.sh sources .env and so
# expands any other reference too (SELF_LEARN_HOME=$SERVICE_HOME/state/x).
# A path still holding a `$` here can name a different directory to setup.sh
# than to teardown, and every keep-out check below would test the wrong one.
# Refuse rather than guess, before anything changes.
for v in SERVICE_HOME SELF_LEARN_HOME; do
  case "${!v}" in
    *'$'*) die "$v in $ENV_FILE still refers to another variable after \$HOME is expanded (got: ${!v}), so teardown cannot be sure which directory it means. Write the path out in full and re-run. Nothing was changed." ;;
  esac
done
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, state $SERVICE_HOME, blobs/exports ${SELF_LEARN_HOME:-(not set)} (never touched)"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Exactly the units / LaunchAgents setup.sh writes, timers first: a timer
# left enabled could start a deploy that brings the app and Postgres back
# while they are being stopped.
UNIT_DIR="$HOME/.config/systemd/user"
AGENT_DIR="$HOME/Library/LaunchAgents"
TIMERS="self-learn-deploy.timer self-learn-export.timer"
ONESHOTS="self-learn-deploy.service self-learn-export.service"
UNIT_FILES="$TIMERS $ONESHOTS self-learn-studio.service self-learn.service"
AGENTS="com.self-learn.deploy com.self-learn.export com.self-learn.studio com.self-learn.web"

# Units that mention this service but that setup.sh does not create — on
# this box, sync.sh's self-learn-seafile.service (the blob-sync daemon, which
# runs out of ~/services/self-learn/seafile). Found by name, or by a file
# whose contents name this service's directory (a backup job, say). Read-only
# listing; they are never stopped, disabled or deleted here.
# Run again by purge_targets after the --purge prompt.
if [ "$OS" = "Linux" ]; then
  SCAN_DIR="$UNIT_DIR"; SCAN_NAME='self-learn*'; SCAN_MINE=" $UNIT_FILES "
else
  SCAN_DIR="$AGENT_DIR"; SCAN_NAME='com.self-learn.*'; SCAN_MINE=" $AGENTS "
fi
scan_foreign() {
  FOREIGN=""
  if [ -d "$SCAN_DIR" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b="$(basename "$f")"
      [ "$OS" = "Linux" ] || b="${b%.plist}"
      case "$SCAN_MINE" in *" $b "*) continue ;; esac
      # shellcheck disable=SC2254  # SCAN_NAME is a glob on purpose
      case "$(basename "$f")" in
        $SCAN_NAME) ;;
        *) grep -qF -e "$HOME/services/$NAME" -e "$SERVICE_HOME" "$f" 2>/dev/null || continue ;;
      esac
      FOREIGN="$FOREIGN $b"
    done < <(find "$SCAN_DIR" -maxdepth 1 ! -type d 2>/dev/null | sort)
  fi
  FOREIGN="${FOREIGN# }"
}
scan_foreign

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# A deploy (poller) or a sync.sh push/pull holds this lock while it rebuilds
# or restores the database. Taking Postgres down under either would leave a
# half-migrated or half-restored catalog, so wait for it instead. A live
# owner pid always means held, however old the lock is; a lock with no pid
# yet is a run just starting unless it is over 2 min old (long past the
# pid-write window); a dead or unverifiable owner is stale. lock_check only
# looks, and runs before
# the --purge prompt so a held lock refuses up front. lock_take runs after
# the prompt (which can wait any length of time, long enough for deploy.sh
# or sync.sh to call a lock stale and take it): it checks again, clears a
# stale lock, then takes it itself (the same mkdir + started/pid scheme
# deploy.sh and sync.sh use), so neither can start until teardown is done,
# and drops it on exit. No SERVICE_HOME on disk: nothing can hold it, so
# nothing to take.
LOCK="$SERVICE_HOME/.deploy.lock"
LOCK_HELD=0
LOCK_STALE=0
owner=""
pid_start() {  # the start identity of pid $1; empty when it is gone
  if [ "$OS" = "Linux" ]; then
    sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
  else
    # lstart honours the caller's TZ, so pin both or a launchd-run
    # deploy and a manual one would not recognise the same process.
    TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null
  fi
}
release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  # Only while it is still ours, as in deploy.sh.
  [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f -- "$LOCK/pid" "$LOCK/started"
  rmdir -- "$LOCK" 2>/dev/null || true
}
lock_check() {
  LOCK_STALE=0
  if [ -L "$LOCK" ]; then
    die "$LOCK is a symlink, not the deploy lock deploy.sh makes — refusing. Nothing was changed."
  fi
  [ -d "$LOCK" ] || return 0
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  started="$(cat "$LOCK/started" 2>/dev/null || true)"
  # pid + start uniquely names a process instance: a matching pair is a live
  # holder no matter the lock's age; a live pid without a start record is a
  # pre-start-tracking holder and gets the same respect.
  if [ -n "$owner" ] && [ -n "$started" ]; then
    if kill -0 "$owner" 2>/dev/null && [ "$(pid_start "$owner")" = "$started" ]; then
      die "A deploy or sync.sh run (pid $owner) holds $LOCK — try again after it finishes. Nothing was changed."
    fi
  elif [ -n "$owner" ]; then
    if kill -0 "$owner" 2>/dev/null; then
      die "A deploy or sync.sh run (pid $owner) holds $LOCK — try again after it finishes. Nothing was changed."
    fi
  elif [ -z "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    die "A deploy or sync.sh run is just starting ($LOCK) — try again in a minute. Nothing was changed."
  fi
  [ ! -L "$LOCK/pid" ] || die "$LOCK/pid is a symlink — refusing. Nothing was changed."
  [ ! -L "$LOCK/started" ] || die "$LOCK/started is a symlink — refusing. Nothing was changed."
  LOCK_STALE=1
}
lock_take() {
  lock_check
  [ -d "$SERVICE_HOME" ] || return 0
  if [ "$LOCK_STALE" -eq 1 ]; then
    # Clear it the way deploy.sh would, but never recursively — a lock
    # holds only its pid and started files, so anything more means it is
    # not one.
    rm -f -- "$LOCK/pid" "$LOCK/started"
    rmdir -- "$LOCK" 2>/dev/null \
      || die "$LOCK holds more than a stale deploy lock's pid/started files — look inside, remove it by hand, then re-run. Nothing was changed."
    ok "Cleared a stale deploy lock (${owner:+owner pid $owner is gone, }no deploy is running)"
  fi
  trap release_lock EXIT
  mkdir -- "$LOCK" 2>/dev/null \
    || die "A deploy or sync.sh run took $LOCK just now — try again after it finishes. Nothing was changed."
  LOCK_HELD=1
  pid_start $$ > "$LOCK/started"
  echo $$ > "$LOCK/pid"
}
lock_check

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was.
PURGE_DIR=""
PURGE_PATHS=""
# Every path --purge deletes, with every refusal. Run before the prompt (so
# it shows the list) and again once lock_take holds the deploy lock: the
# prompt can wait any length of time, and a deploy, a sync.sh install or a
# hand edit in that window could add, swap or symlink a target, or install
# the blob link. The second run must match the first or nothing is deleted.
purge_targets() {
  PURGE_DIR=""
  PURGE_PATHS=""
  scan_foreign
  # sync.sh's blob link keeps its Seafile account password in .env and its
  # daemon state under ~/services/self-learn. Deleting .env under a live
  # link orphans that account, so the link is removed by hand first.
  [ -z "$FOREIGN" ] || die "--purge refused: $FOREIGN still installed (not created by setup.sh, so teardown will not remove it, and it may use ~/services/$NAME or .env). Remove it first — TROUBLESHOOT.md, 'Nuke and pave' — then re-run. Nothing was changed."
  [ -z "$(env_get SEAFILE_SYNC_USER)" ] || die "--purge refused: $ENV_FILE holds sync.sh's Seafile account (SEAFILE_SYNC_USER), and deleting .env would lose its password. Remove the blob link first — TROUBLESHOOT.md, 'Nuke and pave' — then re-run. Nothing was changed."
  DATA_DIR="$SERVICE_HOME"
  while :; do case "$DATA_DIR" in */) DATA_DIR="${DATA_DIR%/}" ;; *) break ;; esac; done
  case "$DATA_DIR" in *..*) die "SERVICE_HOME=$DATA_DIR contains '..' — refusing." ;; esac
  case "$DATA_DIR" in
    "$HOME/services/"?*) ;;
    *) die "SERVICE_HOME=$DATA_DIR is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  # And where it really is, symlinks and all: it must be a strict child of
  # the real ~/services, never ~/services itself or anything above it.
  if [ -e "$DATA_DIR" ]; then
    [ -d "$DATA_DIR" ] || die "SERVICE_HOME=$DATA_DIR is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_DIR="$(real_dir "$DATA_DIR")" || die "SERVICE_HOME=$DATA_DIR is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_DIR" in
      "$root"/?*) ;;
      *) die "SERVICE_HOME=$DATA_DIR resolves to $PURGE_DIR, which is not a folder inside $root — refusing." ;;
    esac
    # Only what setup.sh and the units it installs create there: the deploy
    # clone (disposable, GitHub is canonical), bin/deploy.sh, state/ and the
    # studio runner's STUDIO_HOME. Anything else (e.g. sync.sh's seafile/)
    # stays. Each one goes through real_dir, so a symlinked repo/ pointing at
    # a working clone in ~/dev is refused. The deploy lock is teardown's own
    # once the prompt is answered; it is released (removed) after the last
    # deletion below.
    for child in repo bin state studio; do
      [ -e "$PURGE_DIR/$child" ] || [ -L "$PURGE_DIR/$child" ] || continue
      p="$(real_dir "$PURGE_DIR/$child")" \
        || die "$PURGE_DIR/$child is a symlink or holds this checkout — refusing to delete it. Nothing was changed."
      # SELF_LEARN_HOME (blobs, vault, exports) is never purged, wherever
      # .env points it.
      if [ -n "$SELF_LEARN_HOME" ] && [ -d "$SELF_LEARN_HOME" ]; then
        keep="$(cd "$SELF_LEARN_HOME" && pwd -P)" || die "Cannot resolve SELF_LEARN_HOME=$SELF_LEARN_HOME."
        case "$keep/" in
          "$p"/*) die "SELF_LEARN_HOME=$SELF_LEARN_HOME is inside $p — refusing to delete the blob store and exports. Nothing was changed." ;;
        esac
      fi
      PURGE_PATHS="$PURGE_PATHS$p
"
    done
  fi
}
if [ "$PURGE" -eq 1 ]; then
  purge_targets
  KEEP_HOME="${SELF_LEARN_HOME:-$HOME/.self-learn}"
  warn "--purge deletes the Postgres volume (the whole catalog: courses, concepts, spaced-repetition history, sealed provider keys), the unit files, $ENV_FILE and:"
  if [ -n "$PURGE_PATHS" ]; then printf '%s' "$PURGE_PATHS" | sed 's/^/      /'; else echo "      (no state dirs on disk)"; fi
  warn "This cannot be undone. Kept: $KEEP_HOME (blobs, vault) and the nightly catalog exports in $KEEP_HOME/archive — after this they are the only copy of the catalog."
  if [ "$OS" = "Linux" ]; then
    warn "Want a fresh export first? Answer anything else, run: systemctl --user start self-learn-export.service   then re-run."
  fi
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi
lock_take
if [ "$PURGE" -eq 1 ]; then
  shown="$PURGE_DIR|$PURGE_PATHS"
  purge_targets
  [ "$PURGE_DIR|$PURGE_PATHS" = "$shown" ] \
    || die "What --purge would delete changed while the prompt waited (a deploy or a hand edit ran). Nothing was deleted; re-run to see the new list."
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

# macOS: unload one LaunchAgent now (bootout) and keep launchd from loading
# its plist again at the next login (disable; setup.sh enables it before
# bootstrapping). `launchctl print` fails for an agent that is not loaded:
# nothing to unload, so bootout is skipped. A loaded agent that bootout
# cannot unload is still running and could rebuild or write into what
# --purge deletes, so that stops the teardown before anything is deleted.
# bootout can report an error while launchd finishes the unload by itself,
# so it only counts as failed if the agent is still loaded a moment later.
agent_off() {
  local target i
  target="gui/$(id -u)/$1"
  if launchctl print "$target" >/dev/null 2>&1 \
     && ! launchctl bootout "$target" >/dev/null 2>&1; then
    for i in 1 2 3; do
      launchctl print "$target" >/dev/null 2>&1 || break
      [ "$i" -lt 3 ] || die "Could not unload LaunchAgent $1: launchctl bootout $target failed and it is still loaded (check: launchctl print $target). Nothing was deleted; fix that and re-run."
      sleep 1
    done
  fi
  launchctl disable "$target" >/dev/null 2>&1 \
    || die "Could not disable LaunchAgent $1 (launchctl disable $target), so it would load again at the next login. Nothing was deleted; fix that and re-run."
}

# ---------------------------------------------------------------- stop
# A plain teardown leaves the unit files in place, and setup.sh reads "unit
# installed but inactive" as the owner's deliberate stop and keeps it
# stopped. This marker tells the next ./setup.sh the stop was a teardown,
# so it starts the stack again (and deletes the marker). Written before
# anything stops: a teardown that dies halfway still restores cleanly.
# Only inside a state dir real_dir accepts (a real directory under
# ~/services/self-learn), and never through a symlink: SERVICE_HOME comes
# from .env, so a marker path outside it is skipped, not written.
if [ "$PURGE" -eq 0 ] && { [ -e "$SERVICE_HOME/state" ] || [ -L "$SERVICE_HOME/state" ]; }; then
  if ! state_real="$(real_dir "$SERVICE_HOME/state")" || [ ! -d "$state_real" ]; then
    warn "$SERVICE_HOME/state is not a real directory inside $HOME/services/$NAME — not writing the torn-down marker. After ./setup.sh, start the app by hand if it stays stopped."
  elif MARKER="$state_real/torn-down"; [ -L "$MARKER" ] || { [ -e "$MARKER" ] && [ ! -f "$MARKER" ]; }; then
    warn "$MARKER is a symlink or not a regular file — not writing the torn-down marker. After ./setup.sh, start the app by hand if it stays stopped."
  else
    touch -- "$MARKER"
  fi
fi

if [ "$OS" = "Linux" ]; then
  info "Disabling the deploy + export timers, then any run they started"
  for u in $TIMERS; do
    [ -f "$UNIT_DIR/$u" ] || continue
    systemctl --user disable --now "$u" >/dev/null 2>&1 || die "Could not disable $u: systemctl --user status $u"
  done
  for u in $ONESHOTS; do
    [ -f "$UNIT_DIR/$u" ] || continue
    systemctl --user stop "$u" >/dev/null 2>&1 || die "Could not stop $u: systemctl --user status $u"
  done
  info "Stopping and disabling self-learn-studio, then self-learn"
  for u in self-learn-studio.service self-learn.service; do
    [ -f "$UNIT_DIR/$u" ] || continue
    systemctl --user disable --now "$u" >/dev/null 2>&1 || die "Could not stop $u: systemctl --user status $u"
  done
  ok "Timers, studio runner and app stopped and disabled (unit files kept)"
else
  info "Unloading and disabling the LaunchAgents (deploy, export, studio, web)"
  # bootout unloads each now; disable keeps launchd from loading the plist
  # again at the next login (setup.sh enables each before bootstrapping).
  for a in $AGENTS; do agent_off "$a"; done
  ok "LaunchAgents unloaded and disabled (plists kept)"
fi

# Same project setup.sh starts: one compose file (`name: self-learn`), no
# profiles, no -f overlays. Plain `down` keeps the self-learn-postgres
# volume; `down -v` is only ever run below, after the typed confirmation.
if [ "$PURGE" -eq 1 ]; then
  info "Stopping Postgres and deleting its volume (docker compose down -v)"
  docker compose --project-directory "$SERVICE_DIR" down -v
  ok "self-learn-db and the self-learn-postgres volume removed"
else
  info "Stopping Postgres (docker compose down)"
  docker compose --project-directory "$SERVICE_DIR" down
  ok "self-learn-db removed; the catalog volume is kept"
fi

[ -z "$FOREIGN" ] || warn "Not touched (not created by setup.sh): $FOREIGN — still installed. The blob-sync daemon keeps syncing ${SELF_LEARN_HOME:-$HOME/.self-learn}/blobs; stop it yourself if you want it gone (TROUBLESHOOT.md, 'Nuke and pave')."

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging state, unit files and .env"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -rf -- "$p" || die "Could not delete $p (the volume is already gone). Delete it by hand, then ./teardown.sh --purge again. .env was kept."
  done <<EOF
$PURGE_PATHS
EOF
  if [ "$OS" = "Linux" ]; then
    for u in $UNIT_FILES; do rm -f -- "$UNIT_DIR/$u"; done
    systemctl --user daemon-reload
  else
    for a in $AGENTS; do rm -f -- "$AGENT_DIR/$a.plist"; done
  fi
  rm -f -- "$ENV_FILE"
  # Nothing left for a deploy to break, and the rmdirs below need it gone.
  release_lock
  # SERVICE_HOME, then ~/services/<name> (the launcher's install marker).
  # Tried even when the dirs were already gone, so a purged app never reads
  # as installed; rmdir only ever removes an empty directory.
  [ -z "$PURGE_DIR" ] || [ "$PURGE_DIR" = "$(cd "$HOME/services" && pwd -P)/$NAME" ] \
    || rmdir -- "$PURGE_DIR" 2>/dev/null || true
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  if [ -d "$HOME/services/$NAME" ]; then
    warn "$HOME/services/$NAME is not empty (something setup.sh did not create is still there), so it was kept."
  fi
  ok "Deleted the catalog volume, the unit files, $ENV_FILE and the state under ${PURGE_DIR:-(no SERVICE_HOME on disk)}"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its catalog is gone. ./setup.sh starts fresh.\n' "$NAME"
  echo "  Kept: ${SELF_LEARN_HOME:-$HOME/.self-learn} (blobs, vault, nightly exports in archive/)."
else
  printf '\033[1;32mDone.\033[0m %s is removed. The catalog volume, state and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the data too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
