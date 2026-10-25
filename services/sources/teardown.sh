#!/usr/bin/env bash
#
# teardown.sh — take the sources site off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. stop the deploy poller setup.sh installed (sources-deploy.timer and
#      sources-deploy.service on Linux, the com.sources.deploy LaunchAgent on
#      macOS) so nothing rebuilds the site while it is down
#   3. `docker compose down` — the nginx container and its network go
#   4. keep .env (it holds SITE_PASSPHRASE), the built site, nginx.conf and
#      the unit files, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh            # safe remove: everything on disk kept
#   ./teardown.sh --purge    # ALSO delete what setup.sh wrote under
#                            # ~/services/sources (bin, state, www,
#                            # nginx.conf), .env and the poller unit files;
#                            # asks you to type "sources" first. Terminal
#                            # only: the launcher's Remove never passes it.
#
# Never touched, purge included: the sources repo the site is built from
# (SOURCE_REPO, default ~/dev/sources: the fetch clone, your content), any
# other unit that mentions sources (e.g. sources-trigger.service, which this
# setup.sh does not create), lingering and the Tailscale operator.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="sources"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

# What setup.sh installs, by fixed name. Nothing else is stopped or deleted.
UNIT_DIR="$HOME/.config/systemd/user"
UNITS="sources-deploy.timer sources-deploy.service"   # timer first
LAUNCHD_LABEL="com.sources.deploy"
PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
SETUP_STATE="bin state www nginx.conf"   # under SERVICE_HOME (the deploy lock: see lock_take)

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
SOURCE_REPO="$(env_get SOURCE_REPO)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
# env_get expands $HOME and ${HOME} only. A path still holding a `$` after
# that refers to some other variable, which setup.sh or deploy.sh may read
# differently, so every keep-out check below could test the wrong directory.
# Refuse rather than guess, before anything changes.
for v in SERVICE_HOME SOURCE_REPO; do
  case "${!v}" in
    *'$'*) die "$v in $ENV_FILE still refers to another variable after \$HOME is expanded (got: ${!v}), so teardown cannot be sure which directory it means. Write the path out in full and re-run. Nothing was changed." ;;
  esac
done
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, site files ${SERVICE_HOME:-(not set)}, built from ${SOURCE_REPO:-(not set)}"

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

# Units that mention sources but that setup.sh does not write (the fetch
# timers, sources-trigger.service and its backups, or a job whose contents
# name this service's directory) belong to someone else: name them, never
# stop or delete them. A read-only listing, nothing more. macOS: the same
# scan over ~/Library/LaunchAgents.
OTHER_UNITS=""
if [ "$OS" = "Linux" ]; then
  SCAN_DIR="$UNIT_DIR"; SCAN_MINE=" $UNITS "
else
  SCAN_DIR="$(dirname "$PLIST")"; SCAN_MINE=" $LAUNCHD_LABEL.plist "
fi
if [ -d "$SCAN_DIR" ]; then
  for f in "$SCAN_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    u="$(basename "$f")"
    case "$SCAN_MINE" in *" $u "*) continue ;; esac
    case "$u" in
      *sources*) ;;
      *) [ -f "$f" ] || continue
         grep -qF -e "$HOME/services/$NAME" -e "${SERVICE_HOME:-$HOME/services/$NAME}" "$f" 2>/dev/null || continue ;;
    esac
    OTHER_UNITS="$OTHER_UNITS $u"
  done
fi

# deploy.sh (bin/deploy.sh: the timer's poll, or by hand with --force) holds
# a mkdir lock at SERVICE_HOME/.deploy.lock while it builds into www/ and
# state/. A purge under a live deploy would race a rebuild that recreates
# what it just deleted, so it waits for that deploy instead. The lock holds
# no pid; deploy.sh itself calls it stale only once it is over 60 min old,
# so teardown uses the same rule. lock_check only looks: it runs before the
# prompt, so a held lock refuses with nothing changed. lock_take runs after
# the prompt: it checks again (a deploy may have started while the prompt
# waited), clears a stale lock and takes the lock itself, so deploy.sh
# skips until the purge is done. Dropped on exit.
LOCK=""
LOCK_HELD=0
release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  rmdir -- "$LOCK" 2>/dev/null || true
}
lock_check() {
  [ -n "$LOCK" ] || return 0
  [ ! -L "$LOCK" ] || die "$LOCK is a symlink, not the lock deploy.sh makes — refusing. Nothing was changed."
  [ -e "$LOCK" ] || return 0
  [ -d "$LOCK" ] || die "$LOCK is not a directory, so it is not the lock deploy.sh makes — refusing. Nothing was changed."
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ] \
    || die "A deploy is running (it holds $LOCK) — try again after it finishes. Nothing was changed."
}
lock_take() {
  [ -n "$LOCK" ] || return 0
  lock_check
  if [ -d "$LOCK" ]; then
    rmdir -- "$LOCK" 2>/dev/null \
      || die "$LOCK is over 60 min old but not empty, so it is not a stale deploy lock — look inside, remove it by hand, then re-run. Nothing was changed."
    ok "Cleared a stale deploy lock (over 60 min old)"
  fi
  trap release_lock EXIT
  mkdir -- "$LOCK" 2>/dev/null \
    || die "A deploy took $LOCK just now — try again after it finishes. Nothing was changed."
  LOCK_HELD=1
}

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. Only the paths setup.sh writes under
# SERVICE_HOME are deleted, each through real_dir; the marker dir itself is
# only ever rmdir'd (empty-only), so anything else in it survives.
PURGE_PATHS=""
if [ "$PURGE" -eq 1 ]; then
  [ -n "$SERVICE_HOME" ] || die "SERVICE_HOME is missing from $ENV_FILE — refusing to guess what to delete."
  # A relative path would be resolved against wherever teardown was run
  # from, so the overlap check below could pass on the wrong directory.
  case "$SOURCE_REPO" in
    ''|/*) ;;
    *) die "SOURCE_REPO=$SOURCE_REPO in $ENV_FILE is not an absolute path — teardown cannot prove the purge stays clear of the sources repo, so it refuses. Nothing was changed." ;;
  esac
  while :; do case "$SERVICE_HOME" in */) SERVICE_HOME="${SERVICE_HOME%/}" ;; *) break ;; esac; done
  case "$SERVICE_HOME" in *..*) die "SERVICE_HOME=$SERVICE_HOME contains '..' — refusing." ;; esac
  case "$SERVICE_HOME" in
    "$HOME/services/"?*) ;;
    *) die "SERVICE_HOME=$SERVICE_HOME is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  if [ -e "$SERVICE_HOME" ] || [ -L "$SERVICE_HOME" ]; then
    [ -d "$SERVICE_HOME" ] || die "SERVICE_HOME=$SERVICE_HOME is not a directory — refusing."
    home_real="$(real_dir "$SERVICE_HOME")" || die "SERVICE_HOME=$SERVICE_HOME is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    LOCK="$home_real/.deploy.lock"
    # The repo the site is built from is the user's (default ~/dev/sources)
    # and must survive: refuse if any purge path is it, holds it or is in it.
    repo_real=""
    if [ -n "$SOURCE_REPO" ] && [ -d "$SOURCE_REPO" ]; then
      repo_real="$(cd "$SOURCE_REPO" && pwd -P)" || die "Cannot resolve SOURCE_REPO=$SOURCE_REPO."
    fi
    for leaf in $SETUP_STATE; do
      p="$SERVICE_HOME/$leaf"
      [ -e "$p" ] || [ -L "$p" ] || continue
      r="$(real_dir "$p")" || die "$p is a symlink or resolves outside $HOME/services/$NAME — refusing."
      if [ -n "$repo_real" ]; then
        case "$repo_real/" in "$r"/*) die "$r holds the sources repo $SOURCE_REPO — refusing to delete it." ;; esac
        case "$r/" in "$repo_real"/*) die "$r is inside the sources repo $SOURCE_REPO — refusing to delete it." ;; esac
      fi
      PURGE_PATHS="$PURGE_PATHS$r
"
    done
  fi
  lock_check
  warn "--purge deletes, and this cannot be undone:"
  if [ -n "$PURGE_PATHS" ]; then
    printf '%s' "$PURGE_PATHS" | sed 's/^/      /'
  else
    echo "      (no site files on disk)"
  fi
  echo "      $ENV_FILE"
  if [ "$OS" = "Linux" ]; then
    for u in $UNITS; do echo "      $UNIT_DIR/$u"; done
  else
    echo "      $PLIST"
  fi
  warn "$ENV_FILE holds SITE_PASSPHRASE (the key that unlocks the site, same as the sources repo's GitHub secret). If you have no other copy, save it first."
  [ -z "$SOURCE_REPO" ] || ok "Kept: the sources repo at $SOURCE_REPO is never touched."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
  lock_take
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's local port, and
# nothing else: ports are found from what Serve actually publishes, not from
# what .env says was published (a re-run can publish a second port). A port
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
done <<EOF_SERVE_PLAN
$SERVE_PLAN
EOF_SERVE_PLAN
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

# ---------------------------------------------------------------- poller
# Stopped before the container so no deploy rebuilds the site mid-teardown.
# Unit files stay on the default path: ./setup.sh re-enables them.
info "Stopping the deploy poller"
if [ "$OS" = "Linux" ]; then
  for u in $UNITS; do
    if [ -f "$UNIT_DIR/$u" ]; then
      case "$u" in
        *.timer) systemctl --user disable --now "$u" >/dev/null 2>&1 \
                   || die "Could not disable $u (systemctl --user disable --now $u)." ;;
        # The service is static (no [Install]): stopping it ends a running
        # deploy; there is nothing to disable.
        *) systemctl --user stop "$u" >/dev/null 2>&1 \
             || die "Could not stop $u (systemctl --user stop $u)." ;;
      esac
      ok "Stopped $u"
    else
      ok "$u not installed (already gone)"
    fi
  done
else
  agent_off "$LAUNCHD_LABEL"
  ok "LaunchAgent $LAUNCHD_LABEL unloaded and disabled"
fi
for u in $OTHER_UNITS; do
  warn "$SCAN_DIR/$u mentions sources but setup.sh does not create it, so it is left as is."
done

# ---------------------------------------------------------------- stop
# Same compose file set as setup.sh's `up`: docker-compose.yml plus a local
# docker-compose.override.yml if one exists (Compose picks it up by itself).
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; site files in ${SERVICE_HOME:-(not set)} kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging site files, .env and the poller units"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -rf -- "$p" 2>/dev/null \
      || die "Could not delete $p. Remove it with: sudo rm -rf $p, then re-run ./teardown.sh --purge ($ENV_FILE is kept until then)."
    ok "Deleted $p"
  done <<EOF_PURGE_PATHS
$PURGE_PATHS
EOF_PURGE_PATHS
  rm -f -- "$ENV_FILE"
  ok "Deleted $ENV_FILE"
  if [ "$OS" = "Linux" ]; then
    for u in $UNITS; do rm -f -- "${UNIT_DIR:?}/$u"; done
    systemctl --user daemon-reload
    ok "Removed $UNITS"
  else
    rm -f -- "$PLIST"
    ok "Removed $PLIST (log kept: ~/Library/Logs/sources-deploy.log)"
  fi
  # Nothing left for a deploy to rebuild, and the rmdirs below need it gone.
  release_lock
  # Empty-only: anything setup.sh did not write (a backup, a clone) stays.
  for d in "$SERVICE_HOME" "$HOME/services/$NAME"; do
    [ -n "$d" ] && [ -d "$d" ] && [ ! -L "$d" ] || continue
    if rmdir -- "$d" 2>/dev/null; then
      ok "Removed empty $d"
    else
      warn "$d still holds files setup.sh did not write, so it is kept: $(ls -A "$d" | tr '\n' ' ')"
    fi
  done
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its files are gone. ./setup.sh starts fresh (it needs SITE_PASSPHRASE again).\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Site files and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the files too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
