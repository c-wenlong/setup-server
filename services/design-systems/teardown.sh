#!/usr/bin/env bash
#
# teardown.sh — take the design-systems site off this box. Linux + macOS.
#
# The inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service, found
#      from `tailscale serve status` (never `serve reset`)
#   2. stop the deploy poller setup.sh installed (systemd user timer +
#      oneshot service on Linux, the com.design-systems.deploy LaunchAgent on
#      macOS); the unit files stay
#   3. `docker compose down` — the nginx container and its network go
#   4. keep .env and everything in ~/services/design-systems, so ./setup.sh
#      brings it back as it was
#
# The site is built from YOUR working clone (SOURCE_REPO, default
# ~/dev/design-systems). teardown never deletes or changes it, with or
# without --purge, and refuses to purge when it overlaps the service dir.
#
# Usage:
#   ./teardown.sh            # safe remove: built site, media and .env kept
#   ./teardown.sh --purge    # ALSO delete what setup.sh made in
#                            # ~/services/design-systems (bin, state, www,
#                            # media mirror, nginx.conf), the poller's unit
#                            # files and .env; asks you to type
#                            # "design-systems" first. Terminal only: the
#                            # launcher's Remove button never passes it.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="design-systems"
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
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux (the deploy poller is a systemd user timer)."
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
ok "$NAME: local :$LOCAL_PORT, state ${SERVICE_HOME:-(not set)}, clone ${SOURCE_REPO:-(not set)} (never touched)"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start.
for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# The poller setup.sh installs, and only that. Any other unit or agent on
# this box that mentions design-systems (designs-trigger.service, the
# repo's manual-redeploy endpoint, is one) was not created by setup.sh:
# it is listed here, read-only, and never stopped, disabled or deleted.
UNIT_DIR="$HOME/.config/systemd/user"
TIMER_UNIT="design-systems-deploy.timer"
DEPLOY_UNIT="design-systems-deploy.service"
PLIST_LABEL="com.design-systems.deploy"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
if [ "$OS" = "Linux" ]; then scan_dir="$UNIT_DIR"; else scan_dir="$(dirname "$PLIST")"; fi
FOREIGN_UNITS=""
if [ -d "$scan_dir" ]; then
  for f in "$scan_dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in "$TIMER_UNIT"|"$DEPLOY_UNIT"|"$PLIST_LABEL.plist") continue ;; esac
    case "$base" in
      *design*) ;;
      *) grep -qF "$NAME" "$f" 2>/dev/null || continue ;;
    esac
    FOREIGN_UNITS="$FOREIGN_UNITS $base"
  done
fi

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

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
# leaves the service exactly as it was. What goes: the paths setup.sh and
# deploy.sh create inside SERVICE_HOME, each through real_dir, and nothing
# else in there. The clone at SOURCE_REPO is never on the list, and a purge
# whose SERVICE_HOME overlaps it is refused outright.
PURGE_HOME=""
PURGE_PATHS=""
nl='
'
# Every path --purge deletes, with every refusal. Run before the prompt (so
# it shows the list) and again once lock_take holds the deploy lock: the
# prompt can wait any length of time, and a deploy (or a hand edit) in that
# window could add, swap or symlink a target. The second run must match
# the first or nothing is deleted.
purge_targets() {
  PURGE_PATHS=""
  PURGE_HOME=""
  [ -n "$SERVICE_HOME" ] || die "SERVICE_HOME is missing from $ENV_FILE — refusing to guess what to delete."
  [ -n "$SOURCE_REPO" ] || die "SOURCE_REPO is missing from $ENV_FILE — teardown cannot prove the purge stays clear of your clone, so it refuses."
  # A relative path would be resolved against wherever teardown was run
  # from, so the overlap check below could pass on the wrong directory.
  case "${SOURCE_REPO//\\/}" in
    /*) ;;
    *) die "SOURCE_REPO=$SOURCE_REPO in $ENV_FILE is not an absolute path — teardown cannot prove the purge stays clear of your clone, so it refuses. Nothing was changed." ;;
  esac
  while :; do case "$SERVICE_HOME" in */) SERVICE_HOME="${SERVICE_HOME%/}" ;; *) break ;; esac; done
  case "$SERVICE_HOME" in *..*) die "SERVICE_HOME=$SERVICE_HOME contains '..' — refusing." ;; esac
  case "$SERVICE_HOME" in
    "$HOME/services/"?*) ;;
    *) die "SERVICE_HOME=$SERVICE_HOME is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
  esac
  if [ -e "$SERVICE_HOME" ] || [ -L "$SERVICE_HOME" ]; then
    [ -d "$SERVICE_HOME" ] || die "SERVICE_HOME=$SERVICE_HOME is not a directory — refusing."
    root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    PURGE_HOME="$(real_dir "$SERVICE_HOME")" || die "SERVICE_HOME=$SERVICE_HOME is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$PURGE_HOME" in
      "$root"/?*) ;;
      *) die "SERVICE_HOME=$SERVICE_HOME resolves to $PURGE_HOME, which is not a folder inside $root — refusing." ;;
    esac
    # The clone, where it really is (setup.sh writes .env with printf %q,
    # so a path with spaces carries backslashes; drop them for this check).
    repo="${SOURCE_REPO//\\/}"
    while :; do case "$repo" in */) repo="${repo%/}" ;; *) break ;; esac; done
    repo_real=""
    if [ -n "$repo" ]; then
      repo_real="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_real="$repo"
    fi
    case "$repo_real/" in
      "$PURGE_HOME"/*) die "SOURCE_REPO=$SOURCE_REPO is inside $PURGE_HOME — a purge could delete your clone, so it refuses. Move the clone out first." ;;
    esac
    case "$PURGE_HOME/" in
      "$repo_real"/*) die "SOURCE_REPO=$SOURCE_REPO holds $PURGE_HOME — a purge would delete inside your clone, so it refuses." ;;
    esac
    [ "$LOCK_HELD" -eq 1 ] || LOCK="$PURGE_HOME/.deploy.lock"
    for c in bin state www media nginx.conf; do
      p="$PURGE_HOME/$c"
      [ -e "$p" ] || [ -L "$p" ] || continue
      rp="$(real_dir "$p")" || die "$p is a symlink or otherwise not a real path inside $PURGE_HOME — refusing. Remove it by hand if you are sure."
      PURGE_PATHS="$PURGE_PATHS$rp$nl"
    done
  fi
}
if [ "$PURGE" -eq 1 ]; then
  purge_targets
  lock_check
  warn "--purge deletes, inside ${PURGE_HOME:-(no service dir on disk)}: bin/ (installed deploy.sh), state/, www/ (every built release), media/ (the refero mirror: re-mirroring takes a while), nginx.conf (your edits to it) and the deploy lock; plus the poller's unit files and $ENV_FILE. This cannot be undone."
  warn "Kept: your clone at $SOURCE_REPO, and anything else in the service dir."
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
  lock_take
  shown="$PURGE_HOME|$PURGE_PATHS"
  purge_targets
  [ "$PURGE_HOME|$PURGE_PATHS" = "$shown" ] \
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

# ---------------------------------------------------------------- poller
# Before the container, so a poll cannot start a rebuild mid-teardown. The
# timer goes first (it is what triggers the service), then the oneshot
# service itself (it has no [Install], so stop, not disable). Unit files and
# lingering stay.
info "Stopping the deploy poller"
if [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/$TIMER_UNIT" ]; then
    systemctl --user disable --now "$TIMER_UNIT" >/dev/null 2>&1 \
      || die "Could not disable $TIMER_UNIT (is the user systemd instance reachable?). Serve is already off; fix that and re-run."
    ok "$TIMER_UNIT disabled and stopped"
  else
    ok "$TIMER_UNIT not installed (already gone)"
  fi
  if [ -f "$UNIT_DIR/$DEPLOY_UNIT" ]; then
    systemctl --user stop "$DEPLOY_UNIT" >/dev/null 2>&1 \
      || die "Could not stop $DEPLOY_UNIT. Serve is already off; fix that and re-run."
    ok "$DEPLOY_UNIT stopped"
  fi
else
  agent_off "$PLIST_LABEL"
  ok "LaunchAgent $PLIST_LABEL unloaded and disabled"
fi
for u in $FOREIGN_UNITS; do
  if [ "$OS" = "Linux" ]; then
    warn "$u (in $scan_dir) mentions $NAME but setup.sh did not create it, so it is left exactly as it was. Stop it yourself if you want: systemctl --user disable --now $u"
  else
    warn "$u (in $scan_dir) mentions $NAME but setup.sh did not create it, so it is left exactly as it was."
  fi
done

# ---------------------------------------------------------------- stop
# The same invocation setup.sh's `up` uses: no -f, so Compose picks up
# docker-compose.yml plus a local docker-compose.override.yml when one
# exists, exactly as it did on the way up.
info "Stopping and removing the container (docker compose down)"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; ${SERVICE_HOME:-the service dir} and your clone kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging setup.sh's state"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -rf -- "${p:?}" || die "Could not delete $p. Remove it with: sudo rm -rf $p, then re-run ./teardown.sh --purge ($ENV_FILE is kept)."
    ok "Deleted $p"
  done <<EOF
$PURGE_PATHS
EOF
  if [ "$OS" = "Linux" ]; then
    rm -f -- "${UNIT_DIR:?}/${TIMER_UNIT:?}" "${UNIT_DIR:?}/${DEPLOY_UNIT:?}"
    wants="${UNIT_DIR:?}/timers.target.wants/${TIMER_UNIT:?}"
    [ ! -L "$wants" ] || rm -f -- "${wants:?}"
    systemctl --user daemon-reload
    ok "Deleted $TIMER_UNIT and $DEPLOY_UNIT"
  else
    rm -f -- "${PLIST:?}"
    ok "Deleted $PLIST (the log in ~/Library/Logs/design-systems-deploy.log is kept)"
  fi
  rm -f -- "${ENV_FILE:?}"
  ok "Deleted $ENV_FILE"
  # Nothing left for a deploy to rebuild, and the rmdir below needs it gone.
  release_lock
  # ~/services/<name> is the launcher's install marker (and SERVICE_HOME
  # itself). Try it even when the state was already gone, so a purged app
  # never reads as installed; rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  if [ -d "$HOME/services/$NAME" ]; then
    warn "$HOME/services/$NAME still holds files setup.sh did not create, so it is kept. Look inside before removing it by hand."
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
  printf '\033[1;32mDone.\033[0m %s is removed and its state is gone. Your clone at %s is untouched; ./setup.sh starts fresh.\n' "$NAME" "$SOURCE_REPO"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Built site, media, unit files and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete that state too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses that"
echo "  monitor for you; from a terminal, pause it in Kuma."
exit 0
