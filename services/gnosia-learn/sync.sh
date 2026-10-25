#!/usr/bin/env bash
#
# sync.sh — keep the homeserver's gnosia-learn data in step with the MacBook.
#
# Two halves, following docs/HOMESERVER.md in the gnosia repo (S1–S3):
#
#   blobs — $GNOSIA_HOME/blobs/local rides a dedicated Seafile library
#           ("gnosia-learn-blobs") continuously. The store is content-addressed,
#           so both sides union without conflicts. `.owner` and `.tmp` sit
#           beside local/, outside the synced tree: the marker names one
#           database, and a foreign one makes uploads and `blob audit`
#           refuse the root. Server side: seaf-cli under a systemd user
#           unit. Mac side: the installed Seafile Client.app pairs the
#           library once (no seaf-cli exists for macOS) — `mac-setup`
#           writes the ignore file and prints the pairing steps, or pairs
#           headless when a seaf-cli is found on the Mac.
#
#   db    — the catalog is ONE SQLite file per side (upstream
#           docs/SQLITE-MIGRATION.md): $CATALOG_DB under this machine's
#           $GNOSIA_HOME, $MAC_DB_FILE under the Mac's. `push`/`pull` copy
#           that file — never a merge: the receiving side's catalog.db is
#           replaced wholesale.
#
#           The sending side is snapshotted consistently: `sqlite3 .backup`
#           while the app stays up, or — with no sqlite3 — a plain copy of
#           the db/-wal/-shm set taken while the sender's app is stopped.
#           The receiving side always stops its app first, drops its old
#           -wal/-shm (a WAL that is not the new file's own must never sit
#           beside it), then the staged file moves into place next to it.
#           `blob audit` then re-validates the store against the incoming
#           database (informational — Seafile may still be delivering).
#
#           `.owner` needs no restamp: upstream names a database by its
#           resolved file path, which a same-path replace does not change.
#           vault/ stays stale on purpose (it is a per-database projection;
#           rebuild with `learn vault pull`). Provider keys survive because
#           both ends share AUTH_SECRET (S4). Blobs do not travel with the
#           db; the Seafile link converges them.
#
#   sync.sh install     server side of the Seafile link (account, library,
#                       seaf-cli daemon under systemd, ignore file)
#   sync.sh mac-setup   prep the MacBook over ssh + print pairing steps
#   sync.sh status      both catalog.db files and both blob stores, side by side
#   sync.sh push        copy THIS server's catalog.db over the Mac's
#   sync.sh pull        copy the Mac's catalog.db over this server's
#
# Reads this service's .env (ports, paths, SERVICE_HOME, GNOSIA_HOME,
# CATALOG_DB); Seafile admin credentials come from the sibling seafile
# service's .env. Sync settings written by install (SEAFILE_SYNC_*, MAC_*)
# live in .env too. An .env written before the SQLite cut-over lacks
# GNOSIA_HOME/CATALOG_DB — both are derived below, and its DATABASE_URL /
# POSTGRES_* leftovers are simply unused now.
#
# Mac overrides (defaults match the MacBook): MAC_SSH, MAC_GNOSIA_HOME
# (the Mac's data root, ~/.gnosia), MAC_DB_FILE, MAC_REPO, MAC_SEAFILE_URL,
# MAC_PATH_PREFIX. SQLITE3 may name a sqlite3 binary for the snapshot step;
# an explicitly empty value forces the stop-and-copy fallback.

set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
REPO_ROOT="$(cd "$SERVICE_DIR/.." && pwd)"
SEAFILE_ENV="${SEAFILE_ENV:-$REPO_ROOT/seafile/.env}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

randhex() {
  local n="${1:-16}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_hex($n))"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — deploy gnosia-learn first (./setup.sh)"
set -a; . "$ENV_FILE"; set +a
SERVICE_HOME="${SERVICE_HOME:?SERVICE_HOME missing from $ENV_FILE}"
NODE_BIN="${NODE_BIN:-/usr/bin}"
# Upstream resolves the data root as GNOSIA_HOME and the catalog as one
# SQLite file under it (docs/SQLITE-MIGRATION.md). An .env from the Postgres
# era lacks both, and one from before the rename names the root only
# SELF_LEARN_HOME — derive the way setup.sh/deploy.sh do, either name wins.
SELF_LEARN_HOME="${SELF_LEARN_HOME:-}"
GNOSIA_HOME="${GNOSIA_HOME:-$SELF_LEARN_HOME}"
[ -n "$GNOSIA_HOME" ] || die "GNOSIA_HOME missing from $ENV_FILE (an older .env names the data root SELF_LEARN_HOME)"
CATALOG_DB="${CATALOG_DB:-$GNOSIA_HOME/catalog.db}"
REPO_DIR="$SERVICE_HOME/repo"
BUILD_STATE="$SERVICE_HOME/state"
LOCK="$SERVICE_HOME/.deploy.lock"   # shared with deploy.sh: a live sync blocks the poller
WEB_UNIT="gnosia-learn.service"
WEB_LABEL="com.gnosia-learn.web"
STUDIO_UNIT="gnosia-learn-studio.service"
STUDIO_LABEL="com.gnosia-learn.studio"
SEAF_UNIT="gnosia-learn-seafile.service"
SEAF_DIR="$SERVICE_HOME/seafile"    # ccnet config root for the sync daemon
BLOBS_DIR="$GNOSIA_HOME/blobs"
# Only blobs/local is the library worktree. .owner and .tmp sit beside it at
# blobs/ root — outside the tree entirely, so a seafile-ignore miss or a
# merge conflict can never carry a foreign .owner onto this machine (the
# ignore file inside local/ is a second line of defence, not the first).
LINK_DIR="$BLOBS_DIR/local"
IGNORE_FILE="$LINK_DIR/seafile-ignore.txt"
# Staging for a catalog.db in flight: a single directory on each side, next
# to the file it replaces, so the final mv is a same-filesystem rename — a
# cross-device mv copies instead, and an interrupted copy leaves a torn db.
STAGE_DIR="$(dirname "$CATALOG_DB")"
STAGE_LOCAL="$STAGE_DIR/.sync-stage"

# sqlite3 makes the consistent-snapshot path (`sqlite3 db ".backup out"`).
# SQLITE3 may name a binary; an explicitly empty value forces the fallback
# (stop the writer, copy the file set) — mostly so tests can reach it.
if [ -z "${SQLITE3+x}" ]; then SQLITE3="$(command -v sqlite3 2>/dev/null || true)"; fi

MAC_SSH="${MAC_SSH:-user@100.77.77.78}"
# The account ssh logs in as owns the home and the nix profile.
MAC_USER="${MAC_SSH%%@*}"
# The Mac's data root: catalog.db, blobs/ and the checkout all live under
# it. `~/.gnosia` expands on the Mac side, resolved over ssh (see
# resolve_mac_paths) so scp and remote commands always see absolute paths.
MAC_GNOSIA_HOME="${MAC_GNOSIA_HOME:-~/.gnosia}"
MAC_REPO="${MAC_REPO:-}"                  # default: $MAC_GNOSIA_HOME/checkout
MAC_DB_FILE="${MAC_DB_FILE:-}"            # default: $MAC_GNOSIA_HOME/catalog.db
# nix-installed node/npm are not on a bare ssh PATH
MAC_PATH_PREFIX="${MAC_PATH_PREFIX:-/etc/profiles/per-user/$MAC_USER/bin}"
# The Mac's app is a manually run `npm run dev`, not a launchd job — there
# is no label to boot out, so a replace stops it by process match instead.
MAC_APP_PATTERN='next.*dev|next-server'

SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
SCP="scp -o BatchMode=yes -o ConnectTimeout=10"
OS="$(uname -s)"

require_ssh() {
  $SSH "$MAC_SSH" true 2>/dev/null || die "cannot ssh $MAC_SSH — tailscale up? key installed?"
}

usage() {
  sed -n '/^#   sync.sh install/,/^#   sync.sh pull/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

# Resolve the Mac-side paths that start with `~`: expand the remote $HOME
# once, then default MAC_REPO and MAC_DB_FILE under the data root. Called by
# every command that touches the Mac (status, mac-setup, push, pull).
MAC_HOME_RESOLVED=""
resolve_mac_paths() {
  [ -n "$MAC_HOME_RESOLVED" ] && return 0
  # $HOME expands on the Mac, not here.
  MAC_HOME_RESOLVED="$($SSH "$MAC_SSH" 'printf %s "$HOME"')" \
    || die "could not resolve the Mac's home directory"
  [ -n "$MAC_HOME_RESOLVED" ] || die "could not resolve the Mac's home directory"
  case "$MAC_GNOSIA_HOME" in
    \~)   MAC_GNOSIA_HOME="$MAC_HOME_RESOLVED" ;;
    \~/*) MAC_GNOSIA_HOME="$MAC_HOME_RESOLVED/${MAC_GNOSIA_HOME#\~/}" ;;
  esac
  MAC_REPO="${MAC_REPO:-$MAC_GNOSIA_HOME/checkout}"
  MAC_DB_FILE="${MAC_DB_FILE:-$MAC_GNOSIA_HOME/catalog.db}"
  # Same rule as the local side: stage beside the file being replaced so the
  # mv is a rename, not a copy that can die halfway.
  MAC_STAGE="$(dirname "$MAC_DB_FILE")/.sync-stage"
}

# A single key from the sibling seafile service's .env — never source it
# wholesale: it carries its own LOCAL_PORT, which would shadow ours.
seafile_env() { sed -n "s/^$1=//p" "$SEAFILE_ENV" | tail -1; }

# The whole request goes to curl as a config on stdin (-K -): URLs, tokens
# and passwords stay out of the process list. The caller pipes body fields,
# one `data-urlencode "k=v"` per line — which also encodes the values.
seafile_api() {
  local method="$1" path="$2" token="${3:-}"
  {
    printf 'request = "%s"\nurl = "%s%s"\n' "$method" "$SEAFILE_URL" "$path"
    [ -n "$token" ] && printf 'header = "Authorization: Token %s"\n' "$token"
    cat
  } | curl -fsS -K -
}

# --------------------------------------------------------------------- lock
# Same mkdir+pid lock deploy.sh takes: while a sync holds it a firing poller
# sees a live owner and skips — a deploy must never migrate a database that
# is mid-replace. The holder writes its start identity, then its pid: pid +
# start uniquely names a process instance, so a dead holder, a reused pid
# or a lock whose pid was never written all reclaim — while a live holder
# is never raced, no matter how old the lock is. A lock with a pid but no
# start is a pre-start-tracking holder: identity cannot be proven, so it is
# kept only while its pid lives, with the old 60-min bound as the backstop.
pid_start() {  # the start identity of pid $1; empty when it is gone
  if [ "$OS" = "Linux" ]; then
    sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
  else
    # lstart honours the caller's TZ, so pin both or a launchd-run
    # deploy and a manual one would not recognise the same process.
    TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null
  fi
}
acquire_lock() {
  if [ -d "$LOCK" ]; then
    owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    started="$(cat "$LOCK/started" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ -n "$started" ]; then
      if ! kill -0 "$owner" 2>/dev/null; then
        warn "removing stale deploy lock (owner pid $owner is gone)"
        rm -rf "$LOCK"
      elif [ "$(pid_start "$owner")" != "$started" ]; then
        warn "removing stale deploy lock (pid $owner now belongs to another process)"
        rm -rf "$LOCK"
      fi
    elif [ -n "$owner" ]; then
      if ! kill -0 "$owner" 2>/dev/null; then
        warn "removing stale deploy lock (owner pid $owner is gone)"
        rm -rf "$LOCK"
      elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        warn "removing stale deploy lock (>60 min old, owner not verifiable)"
        rm -rf "$LOCK"
      fi
    elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      warn "removing stale deploy lock (owner never recorded)"
      rm -rf "$LOCK"
    fi
  fi
  mkdir "$LOCK" 2>/dev/null || die "a deploy or sync is running — try again after it finishes"
  pid_start $$ > "$LOCK/started"
  echo $$ > "$LOCK/pid"
  trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"' EXIT
}

# --------------------------------------------------------------- app services
web_is_active() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user is-active --quiet "$WEB_UNIT"
  else
    launchctl print "gui/$(id -u)/$WEB_LABEL" >/dev/null 2>&1
  fi
}
web_stop() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user stop "$WEB_UNIT"
  else
    launchctl bootout "gui/$(id -u)/$WEB_LABEL" 2>/dev/null || true
  fi
}
web_start() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user start "$WEB_UNIT"
  else
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$WEB_LABEL.plist" \
      2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$WEB_LABEL"
  fi
}

# The studio runner (STUDIO_ENABLED=1) shells `npm run catalog` against this
# database and is not covered by the web app's stop, so a replace has to take
# it down itself. Same service names as deploy.sh.
studio_installed() {
  [ -f "$HOME/.config/systemd/user/$STUDIO_UNIT" ] \
    || [ -f "$HOME/Library/LaunchAgents/$STUDIO_LABEL.plist" ]
}
studio_is_active() {
  studio_installed || return 1
  if [ "$OS" = "Linux" ]; then
    systemctl --user is-active --quiet "$STUDIO_UNIT"
  else
    launchctl print "gui/$(id -u)/$STUDIO_LABEL" >/dev/null 2>&1
  fi
}
studio_stop() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user stop "$STUDIO_UNIT"
  else
    launchctl bootout "gui/$(id -u)/$STUDIO_LABEL" 2>/dev/null || true
  fi
}
studio_start() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user start "$STUDIO_UNIT"
  else
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$STUDIO_LABEL.plist" \
      2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$STUDIO_LABEL"
  fi
}

# This machine's writers, stopped in dependency order (the runner shells the
# catalog, so it goes first) and restarted only if they were running — a
# deliberately stopped service stays stopped.
WAS_ACTIVE=0
STUDIO_WAS_ACTIVE=0
stop_local_writers() {
  if studio_is_active; then
    STUDIO_WAS_ACTIVE=1
    info "stopping $STUDIO_UNIT during the replace"
    studio_stop
  fi
  if web_is_active; then
    WAS_ACTIVE=1
    info "stopping $WEB_UNIT during the replace"
    web_stop
  fi
}
start_local_writers() {
  if [ "$WAS_ACTIVE" = "1" ]; then
    web_start && ok "$WEB_UNIT restarted"
  fi
  if [ "$STUDIO_WAS_ACTIVE" = "1" ]; then
    studio_start && ok "$STUDIO_UNIT restarted"
  fi
}
# What a failed pull leaves down, for its error messages.
left_stopped() {
  if [ "${STUDIO_WAS_ACTIVE:-0}" = "1" ]; then
    printf '%s and %s' "$WEB_UNIT" "$STUDIO_UNIT"
  else
    printf '%s' "$WEB_UNIT"
  fi
}

# ------------------------------------------------------------- the Mac's app
# Nothing on the Mac supervises the app (a manual `npm run dev`), so the
# only handle on it is the process table. mac_app_stop kills it before a
# replace — running `next` would keep writing the old inode, and its next
# connection would see the new file beside the old one's -wal, which reads
# as a hot WAL and can corrupt the incoming db.
# Pids running the checkout's app on the Mac, and only those: the pattern
# matches every Next.js dev/server process on the machine, so each match is
# confirmed by its cwd (under $MAC_REPO) or its command line (naming the
# checkout) before it counts — a pkill on the bare pattern would stop any
# other Next.js project the account is running.
mac_app_pids() {
  $SSH "$MAC_SSH" "
    for pid in \$(pgrep -f '$MAC_APP_PATTERN' 2>/dev/null); do
      cmd=\$(ps -o command= -p \"\$pid\" 2>/dev/null)
      case \"\$cmd\" in *'$MAC_REPO'*) echo \"\$pid\"; continue;; esac
      cwd=\$(lsof -a -p \"\$pid\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      case \"\$cwd\" in '$MAC_REPO'|'$MAC_REPO'/*) echo \"\$pid\";; esac
    done"
}
mac_app_running() { [ -n "$(mac_app_pids)" ]; }
mac_app_stop() {
  local pids
  pids="$(mac_app_pids)"
  [ -n "$pids" ] || return 1
  warn "stopping the Mac's app under $MAC_REPO so its catalog.db can be replaced:"
  $SSH "$MAC_SSH" "ps -o pid=,command= -p $(printf %s "$pids" | tr '\n' ',' | sed 's/,$//')" | sed 's/^/    /'
  $SSH "$MAC_SSH" "kill $(printf %s "$pids" | tr '\n' ' ')" \
    || die "could not stop the Mac's app — stop it there and re-run"
  # SIGTERM is a request, not an outcome: wait for the pids to actually go
  # before touching the file they still hold open.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(mac_app_pids)" ] && break
    sleep 1
  done
  [ -z "$(mac_app_pids)" ] \
    || die "the Mac's app ignored SIGTERM — stop it there and re-run"
  MAC_APP_WAS_RUNNING=1
  return 0
}

# --------------------------------------------------------------- snapshots
# A copy of a live SQLite file is only consistent taken one of two ways:
# `sqlite3 .backup` (the online-backup API — the sender's app keeps running)
# or, with no sqlite3, a plain copy of the db/-wal/-shm set taken while the
# writer is stopped. Both fill a staging directory that ships as one scp.
snapshot_local() {  # $1 = staging dir to fill
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  if [ -n "$SQLITE3" ]; then
    info "snapshotting $CATALOG_DB (sqlite3 .backup)"
    ( umask 077; "$SQLITE3" "$CATALOG_DB" ".backup '$dir/catalog.db'" ) \
      || die "sqlite3 .backup of $CATALOG_DB failed"
  else
    # No sqlite3: the only consistent copy is a stopped writer's files. The
    # -wal/-shm siblings come along so uncheckpointed commits survive.
    warn "no sqlite3 found — stopping the app briefly to copy the database files"
    stop_local_writers
    ( umask 077
      cp -p "$CATALOG_DB" "$dir/catalog.db" \
        || exit 1
      [ ! -f "$CATALOG_DB-wal" ] || cp -p "$CATALOG_DB-wal" "$dir/catalog.db-wal" || exit 1
      [ ! -f "$CATALOG_DB-shm" ] || cp -p "$CATALOG_DB-shm" "$dir/catalog.db-shm" || exit 1
    ) || { start_local_writers; die "copy of $CATALOG_DB failed"; }
    start_local_writers
  fi
}

snapshot_mac() {  # fills the remote staging dir $MAC_STAGE
  if $SSH "$MAC_SSH" "command -v sqlite3 >/dev/null 2>&1"; then
    info "snapshotting $MAC_DB_FILE on the Mac (sqlite3 .backup)"
    $SSH "$MAC_SSH" "umask 077; rm -rf '$MAC_STAGE' && mkdir -p '$MAC_STAGE' && sqlite3 '$MAC_DB_FILE' \".backup '$MAC_STAGE/catalog.db'\"" \
      || die "sqlite3 .backup on the Mac failed"
  else
    if mac_app_running; then
      die "the Mac has no sqlite3 and its app is running — a live catalog.db cannot be copied safely. Stop the app there (or install sqlite3) and re-run."
    fi
    info "no sqlite3 on the Mac — copying the stopped database files"
    $SSH "$MAC_SSH" "umask 077; rm -rf '$MAC_STAGE' && mkdir -p '$MAC_STAGE' && cp -p '$MAC_DB_FILE' '$MAC_STAGE/catalog.db' && { [ ! -f '$MAC_DB_FILE-wal' ] || cp -p '$MAC_DB_FILE-wal' '$MAC_STAGE/catalog.db-wal'; } && { [ ! -f '$MAC_DB_FILE-shm' ] || cp -p '$MAC_DB_FILE-shm' '$MAC_STAGE/catalog.db-shm'; }" \
      || die "copying $MAC_DB_FILE on the Mac failed"
  fi
}

# -------------------------------------------------------------- blob audit
# Informational: reports rows whose object Seafile has not delivered yet.
# Run with CATALOG_DB + GNOSIA_HOME (never DATABASE_URL, whose postgres-era
# value would now be refused) so the incoming database validates the store
# it just inherited. Never --fix: it deletes day-old orphans, and a delete
# on a shared store propagates to the other machine.
audit_local() {
  [ -d "$REPO_DIR" ] || { warn "no checkout at $REPO_DIR — skipping audit"; return 0; }
  info "blob audit on this server (informational)"
  if ( cd "$REPO_DIR" && PATH="$NODE_BIN:$PATH" CATALOG_DB="$CATALOG_DB" GNOSIA_HOME="$GNOSIA_HOME" \
         npm run catalog -- blob audit ); then
    ok "blob audit clean"
  else
    warn "audit reported gaps — Seafile may still be delivering; re-run: cd $REPO_DIR && npm run catalog -- blob audit"
  fi
}

audit_mac() {
  info "blob audit on the Mac (informational)"
  if $SSH "$MAC_SSH" "export PATH='$MAC_PATH_PREFIX':\$PATH; cd '$MAC_REPO' && CATALOG_DB='$MAC_DB_FILE' GNOSIA_HOME='$MAC_GNOSIA_HOME' npm run catalog -- blob audit"; then
    ok "Mac blob audit clean"
  else
    warn "Mac audit reported gaps — Seafile may still be delivering"
  fi
}

# ------------------------------------------------------------ seafile ignore
write_ignore_local() {
  mkdir -p "$LINK_DIR"
  cat > "$IGNORE_FILE" <<'EOF'
# Written by services/gnosia-learn/sync.sh — machine-local entries that must not sync.
# .owner names this machine's database for this blob root; a foreign marker
# makes uploads and `blob audit` refuse it (docs/HOMESERVER.md S3).
# .tmp is the catalog's scratch space.
/.owner
/.tmp
EOF
}

# ------------------------------------------------------------------ install
cmd_install() {
  [ "$OS" = "Linux" ] || die "install runs on the homeserver (Linux). For the Mac side: ./sync.sh mac-setup"
  [ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
  command -v curl >/dev/null || die "curl is required."
  [ -f "$SEAFILE_ENV" ] || die "no $SEAFILE_ENV — deploy the seafile service first"
  mkdir -p "$BLOBS_DIR" "$BUILD_STATE"

  if ! command -v seaf-cli >/dev/null 2>&1 || ! command -v seaf-daemon >/dev/null 2>&1; then
    info "Installing seafile-cli + seafile-daemon (sudo apt)"
    sudo apt-get install -y seafile-cli seafile-daemon || die "apt install failed"
  fi
  SEAF_CLI="$(command -v seaf-cli)"
  SEAF_DAEMON="$(command -v seaf-daemon)"
  ok "seaf-cli: $SEAF_CLI"

  # --- dedicated, non-admin Seafile account + private library ---
  local sea_port
  sea_port="$(seafile_env LOCAL_PORT)"; sea_port="${sea_port:-8081}"
  SEAFILE_URL="${SEAFILE_URL:-http://127.0.0.1:$sea_port}"
  INIT_SEAFILE_ADMIN_EMAIL="$(seafile_env INIT_SEAFILE_ADMIN_EMAIL)"
  INIT_SEAFILE_ADMIN_PASSWORD="$(seafile_env INIT_SEAFILE_ADMIN_PASSWORD)"
  if [ -z "$INIT_SEAFILE_ADMIN_EMAIL" ] || [ -z "$INIT_SEAFILE_ADMIN_PASSWORD" ]; then
    die "admin credentials missing from $SEAFILE_ENV"
  fi

  admin_token="$(printf 'data-urlencode "username=%s"\ndata-urlencode "password=%s"\n' \
      "$INIT_SEAFILE_ADMIN_EMAIL" "$INIT_SEAFILE_ADMIN_PASSWORD" \
    | seafile_api POST /api2/auth-token/ \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')"
  [ -n "$admin_token" ] || die "Seafile admin auth failed ($SEAFILE_URL/api2/auth-token/)"

  if [ -z "${SEAFILE_SYNC_USER:-}" ]; then
    # .local suffix: Seafile rejects emails whose domain has no dot (400
    # "email invalid"), and a bare hostname has none.
    SEAFILE_SYNC_USER="gnosia-learn-sync@$(hostname -s 2>/dev/null || hostname).local"
    SEAFILE_SYNC_PASSWORD="$(randhex 24)"
    info "Creating Seafile account $SEAFILE_SYNC_USER"
    printf 'data-urlencode "email=%s"\ndata-urlencode "name=gnosia-learn blob sync"\ndata-urlencode "password=%s"\n' \
        "$SEAFILE_SYNC_USER" "$SEAFILE_SYNC_PASSWORD" \
      | seafile_api POST /api/v2.1/admin/users/ "$admin_token" >/dev/null \
      || die "could not create the sync account"
    ok "Account created"
  else
    ok "Sync account already configured: $SEAFILE_SYNC_USER"
  fi

  if [ -z "${SEAFILE_SYNC_REPO:-}" ]; then
    user_token="$(printf 'data-urlencode "username=%s"\ndata-urlencode "password=%s"\n' \
        "$SEAFILE_SYNC_USER" "$SEAFILE_SYNC_PASSWORD" \
      | seafile_api POST /api2/auth-token/ \
      | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')"
    [ -n "$user_token" ] || die "could not log in as $SEAFILE_SYNC_USER"
    info "Creating library gnosia-learn-blobs"
    SEAFILE_SYNC_REPO="$(printf 'data-urlencode "name=gnosia-learn-blobs"\n' \
      | seafile_api POST /api2/repos/ "$user_token" \
      | sed -n 's/.*"repo_id": *"\([^"]*\)".*/\1/p')"
    [ -n "$SEAFILE_SYNC_REPO" ] || die "library creation returned no repo_id"
    ok "Library $SEAFILE_SYNC_REPO created"
  else
    ok "Library already configured: $SEAFILE_SYNC_REPO"
  fi

  # Persist only once — the generated block is owned by install.
  if ! grep -q '^SEAFILE_SYNC_USER=' "$ENV_FILE" 2>/dev/null; then
    info "Persisting sync settings into .env"
    ( umask 077
      cat >> "$ENV_FILE" <<EOF

# --- blob/db sync (written by sync.sh install) ---
SEAFILE_URL=$SEAFILE_URL
SEAFILE_SYNC_USER=$SEAFILE_SYNC_USER
SEAFILE_SYNC_PASSWORD=$SEAFILE_SYNC_PASSWORD
SEAFILE_SYNC_REPO=$SEAFILE_SYNC_REPO
MAC_SSH=$MAC_SSH
EOF
    )
    chmod 600 "$ENV_FILE"
  fi

  write_ignore_local
  ok "Wrote $IGNORE_FILE (.owner/.tmp stay machine-local)"

  # --- daemon + library link (idempotent) ---
  # -c is the ccnet config dir on every subcommand, init included — without
  # it init would populate the default ~/.ccnet and every other call would
  # point at an uninitialised $SEAF_DIR/ccnet. init does a single mkdir of
  # the -c dir, so its parent must already exist.
  mkdir -p "$SEAF_DIR"
  [ -d "$SEAF_DIR/ccnet" ] || "$SEAF_CLI" init -c "$SEAF_DIR/ccnet" -d "$SEAF_DIR" >/dev/null \
    || die "seaf-cli init failed"

  # The unit runs seaf-daemon itself in the foreground (no --daemon), so
  # systemd tracks the real process and Restart=always revives a dead
  # daemon. A Type=oneshot wrapper around `seaf-cli start` would keep
  # reporting active after the daemon died.
  info "Writing + starting $SEAF_UNIT"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/$SEAF_UNIT" <<EOF
# Generated by services/gnosia-learn/sync.sh — regenerated on every install.
[Unit]
Description=gnosia-learn blob sync (Seafile daemon for $BLOBS_DIR)
After=network-online.target

[Service]
Type=simple
ExecStart=$SEAF_DAEMON -c $SEAF_DIR/ccnet -d $SEAF_DIR/seafile-data -w $SEAF_DIR/seafile
ExecStop=$SEAF_CLI stop -c $SEAF_DIR/ccnet
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  # restart, not enable --now: an older unit left active (the oneshot shape
  # that predates this daemon) would survive enable --now untouched.
  systemctl --user enable "$SEAF_UNIT" >/dev/null 2>&1 || die "could not enable $SEAF_UNIT"
  systemctl --user restart "$SEAF_UNIT" || die "could not start $SEAF_UNIT"

  # list/sync talk to the daemon's rpc socket — wait until it answers.
  for _ in $(seq 1 20); do
    "$SEAF_CLI" list -c "$SEAF_DIR/ccnet" >/dev/null 2>&1 && break
    sleep 0.5
  done
  "$SEAF_CLI" list -c "$SEAF_DIR/ccnet" >/dev/null 2>&1 \
    || die "seaf-daemon is not answering — journalctl --user -u $SEAF_UNIT"

  linked_dir="$("$SEAF_CLI" list -c "$SEAF_DIR/ccnet" 2>/dev/null \
    | awk -v r="$SEAFILE_SYNC_REPO" '$2 == r {print $3}')"
  if [ -n "$linked_dir" ] && [ "$linked_dir" != "$LINK_DIR" ]; then
    die "library is synced to $linked_dir, not $LINK_DIR — desync the old mapping first: $SEAF_CLI desync -d '$linked_dir' -c '$SEAF_DIR/ccnet'"
  fi
  if [ -z "$linked_dir" ]; then
    info "Linking library -> $LINK_DIR"
    # No -p on argv: without the flag seaf-cli getpass()es, and setsid drops
    # the controlling tty so the password comes off this pipe, not the terminal.
    printf '%s\n' "$SEAFILE_SYNC_PASSWORD" | setsid "$SEAF_CLI" sync \
      -l "$SEAFILE_SYNC_REPO" -s "$SEAFILE_URL" -d "$LINK_DIR" \
      -u "$SEAFILE_SYNC_USER" -c "$SEAF_DIR/ccnet" >/dev/null 2>&1 \
      || die "seaf-cli sync failed"
  fi
  ok "Library linked to $LINK_DIR"

  echo
  ok "Server side of the blob link is live."
  echo "    Next: ./sync.sh mac-setup    (prep + pair the MacBook)"
  echo "    Then: ./sync.sh status       (verify both ends)"
}

# ---------------------------------------------------------------- mac-setup
cmd_mac_setup() {
  command -v ssh >/dev/null || die "ssh is required"
  [ -n "${SEAFILE_SYNC_USER:-}" ] || die "no SEAFILE_SYNC_* in .env — run ./sync.sh install first"
  # The Mac reaches Seafile over the tailnet URL; the loopback URL is ours.
  local proto host
  proto="$(seafile_env SEAFILE_SERVER_PROTOCOL)"; proto="${proto:-https}"
  host="$(seafile_env SEAFILE_SERVER_HOSTNAME)"
  [ -n "$host" ] || die "SEAFILE_SERVER_HOSTNAME missing from $SEAFILE_ENV"
  MAC_SEAFILE_URL="${MAC_SEAFILE_URL:-$proto://$host}"

  info "Checking ssh to $MAC_SSH"
  require_ssh
  resolve_mac_paths
  ok "ssh reachable"

  # Written before any pairing — a synced .owner/.tmp on either side would
  # poison the other machine's blob root.
  info "Writing $MAC_GNOSIA_HOME/blobs/local/seafile-ignore.txt"
  $SSH "$MAC_SSH" "mkdir -p '$MAC_GNOSIA_HOME/blobs/local' && cat > '$MAC_GNOSIA_HOME/blobs/local/seafile-ignore.txt'" <<'EOF'
# Written by services/gnosia-learn/sync.sh — machine-local entries that must not sync.
# .owner names this machine's database for this blob root; a foreign marker
# makes uploads and `blob audit` refuse it (docs/HOMESERVER.md S3).
# .tmp is the catalog's scratch space.
/.owner
/.tmp
EOF
  ok "Ignore file in place"

  SEAF_MAC="$($SSH "$MAC_SSH" 'export PATH="'"$MAC_PATH_PREFIX"':$PATH"; command -v seaf-cli' 2>/dev/null || true)"
  if [ -n "$SEAF_MAC" ]; then
    info "seaf-cli found on the Mac ($SEAF_MAC) — pairing headless"
    $SSH "$MAC_SSH" "mkdir -p '$MAC_GNOSIA_HOME/.seafile' && { [ -d '$MAC_GNOSIA_HOME/.seafile/ccnet' ] || '$SEAF_MAC' init -c '$MAC_GNOSIA_HOME/.seafile/ccnet' -d '$MAC_GNOSIA_HOME/.seafile'; }" \
      || die "seaf-cli init on the Mac failed"
    # The agent runs seaf-daemon itself (next to seaf-cli) in the foreground
    # with KeepAlive — a oneshot `seaf-cli start` wrapper would leave a dead
    # daemon looking alive, same failure the systemd unit avoids.
    SEAF_DAEMON_MAC="${SEAF_MAC%/*}/seaf-daemon"
    $SSH "$MAC_SSH" "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.gnosia-learn.seafile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/gnosia-learn/sync.sh mac-setup. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gnosia-learn.seafile</string>
  <key>ProgramArguments</key>
  <array><string>$SEAF_DAEMON_MAC</string><string>-c</string><string>$MAC_GNOSIA_HOME/.seafile/ccnet</string><string>-d</string><string>$MAC_GNOSIA_HOME/.seafile/seafile-data</string><string>-w</string><string>$MAC_GNOSIA_HOME/.seafile/seafile</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/gnosia-learn-seafile.log</string>
  <key>StandardErrorPath</key><string>/tmp/gnosia-learn-seafile.log</string>
</dict>
</plist>
EOF
    $SSH "$MAC_SSH" "launchctl bootout gui/\$(id -u)/com.gnosia-learn.seafile 2>/dev/null; launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.gnosia-learn.seafile.plist" \
      || warn "LaunchAgent load failed — start the daemon by hand: $SEAF_DAEMON_MAC -c $MAC_GNOSIA_HOME/.seafile/ccnet -d $MAC_GNOSIA_HOME/.seafile/seafile-data -w $MAC_GNOSIA_HOME/.seafile/seafile"
    # The agent owns the daemon — no `seaf-cli start` here, or two daemons
    # fight over the same ccnet dir and KeepAlive retries forever. Pairing
    # waits for the agent's daemon to answer rpc first.
    printf '%s\n' "$SEAFILE_SYNC_PASSWORD" | $SSH "$MAC_SSH" "for _ in \$(seq 1 20); do '$SEAF_MAC' list -c '$MAC_GNOSIA_HOME/.seafile/ccnet' >/dev/null 2>&1 && break; sleep 0.5; done
      '$SEAF_MAC' list -c '$MAC_GNOSIA_HOME/.seafile/ccnet' 2>/dev/null | grep -q '$SEAFILE_SYNC_REPO' || \
        '$SEAF_MAC' sync -l '$SEAFILE_SYNC_REPO' -s '$MAC_SEAFILE_URL' \
          -d '$MAC_GNOSIA_HOME/blobs/local' -u '$SEAFILE_SYNC_USER' \
          -c '$MAC_GNOSIA_HOME/.seafile/ccnet'" || die "seaf-cli pairing on the Mac failed"
    ok "seaf-cli paired on the Mac; daemon returns at login"
  else
    cat <<EOF

The Mac side pairs through Seafile Client.app (already in /Applications —
there is no seaf-cli for macOS). On the MacBook, once:

  1. Open "Seafile Client".
  2. Add the account if it isn't already there:
       server   $MAC_SEAFILE_URL
       user     $SEAFILE_SYNC_USER
       password $SEAFILE_SYNC_PASSWORD   (also in .env)
  3. Right-click the "gnosia-learn-blobs" library -> "Sync this library" ->
     "sync with an existing folder" -> pick ~/.gnosia/blobs/local.
  4. Enable auto-start on login in the client's settings if it is off.

seafile-ignore.txt is already in place, so the Mac's own .owner never
uploads and the server's never lands there.
EOF
  fi

  echo
  ok "Mac side ready. Verify with: ./sync.sh status"
}

# ------------------------------------------------------------------ status
# Modification time, GNU stat then BSD.
db_mtime() {
  stat -c %y "$1" 2>/dev/null | cut -d. -f1 \
    || stat -f '%Sm' -t '%F %R' "$1" 2>/dev/null
}

# Table counts via sqlite3 — informative only; a missing table prints '?'.
db_counts() {  # $1 = sqlite3 binary, $2 = db file
  local t
  for t in catalog_instance learner asset event review progress blob_object provider_key; do
    printf '  %-15s %s\n' "$t" "$("$1" "$2" "select count(*) from \"$t\"" 2>/dev/null || echo '?')"
  done
  "$1" "$2" "select '  instance type : '||type from catalog_instance" 2>/dev/null || true
}

cmd_status() {
  echo "=== SERVER ($(hostname -s 2>/dev/null || hostname)) ==="
  if [ -f "$CATALOG_DB" ]; then
    printf 'db    : %s (%s, modified %s)\n' "$CATALOG_DB" \
      "$(du -h "$CATALOG_DB" | cut -f1)" "$(db_mtime "$CATALOG_DB")"
    if [ -n "$SQLITE3" ]; then
      db_counts "$SQLITE3" "$CATALOG_DB"
    else
      echo "  (no sqlite3 — install it for table counts)"
    fi
  else
    echo "db    : $CATALOG_DB missing"
  fi
  echo "owner : $(tr -d '\n ' < "$BLOBS_DIR/.owner" 2>/dev/null || echo missing)"
  echo "blobs : $(find "$BLOBS_DIR/local" -type f 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$BLOBS_DIR" 2>/dev/null | cut -f1)"
  if [ -d "$SEAF_DIR/ccnet" ] && command -v seaf-cli >/dev/null 2>&1; then
    seaf-cli list -c "$SEAF_DIR/ccnet" 2>/dev/null | sed 's/^/seaf  : /' \
      || echo "seaf  : daemon not answering — systemctl --user restart $SEAF_UNIT"
  else
    echo "seaf  : not installed — ./sync.sh install"
  fi

  echo
  echo "=== MAC ($MAC_SSH) ==="
  if ! $SSH "$MAC_SSH" true 2>/dev/null; then
    echo "unreachable over ssh — tailscale up on both ends?"
    return 0
  fi
  resolve_mac_paths
  $SSH "$MAC_SSH" "db='$MAC_DB_FILE'
if [ -f \"\$db\" ]; then
  s=\$(stat -f%z \"\$db\" 2>/dev/null)
  m=\$(stat -f '%Sm' -t '%F %R' \"\$db\" 2>/dev/null)
  printf 'db    : %s (%s bytes, modified %s)\n' \"\$db\" \"\$s\" \"\$m\"
  if command -v sqlite3 >/dev/null 2>&1; then
    for t in catalog_instance learner asset event review progress blob_object provider_key; do
      printf '  %-15s %s\n' \"\$t\" \"\$(sqlite3 \"\$db\" \"select count(*) from \$t\" 2>/dev/null || echo '?')\"
    done
    sqlite3 \"\$db\" \"select '  instance type : '||type from catalog_instance\" 2>/dev/null || true
  fi
else
  printf 'db    : %s missing\n' \"\$db\"
fi
printf 'owner : %s\n' \"\$(tr -d '\n ' < '$MAC_GNOSIA_HOME/blobs/.owner' 2>/dev/null || echo missing)\"
printf 'blobs : %s files, %s\n' \"\$(find '$MAC_GNOSIA_HOME/blobs/local' -type f 2>/dev/null | wc -l | tr -d ' ')\" \"\$(du -sh '$MAC_GNOSIA_HOME/blobs' 2>/dev/null | cut -f1)\"
if pgrep -fl 'Seafile Client|seafile-applet|seaf-daemon' >/dev/null 2>&1; then echo 'seaf  : client running'; else echo 'seaf  : NO client running'; fi"
}

# ----------------------------------------------------------------- push/pull
cmd_push() {
  info "push: this server's catalog.db -> the MacBook (replaces the Mac's)"
  acquire_lock
  require_ssh
  resolve_mac_paths
  mkdir -p "$BUILD_STATE"
  [ -f "$CATALOG_DB" ] || die "no catalog at $CATALOG_DB — nothing to push"

  # The receiving side's app goes down first: a running `next` would keep
  # writing the old inode, and its next fresh connection would read the new
  # file beside the old one's -wal as a hot WAL — a corruption vector.
  MAC_APP_WAS_RUNNING=0
  mac_app_stop || true

  snapshot_local "$STAGE_LOCAL"
  ok "Snapshotted $(du -h "$STAGE_LOCAL/catalog.db" | cut -f1)"

  info "copying to the Mac"
  MAC_STAGE_PARENT="$(dirname "$MAC_DB_FILE")"
  $SSH "$MAC_SSH" "mkdir -p '$MAC_STAGE_PARENT' && rm -rf '$MAC_STAGE'" || die "could not prep the Mac's staging dir"
  $SCP -pr "$STAGE_LOCAL" "$MAC_SSH:$MAC_STAGE_PARENT/" >/dev/null || die "scp failed"
  rm -rf "$STAGE_LOCAL"

  info "placing catalog.db on the Mac"
  # Old -wal/-shm first — a WAL that is not the new file's own must never
  # sit beside it — then the staged files rename in next to it.
  $SSH "$MAC_SSH" "[ -f '$MAC_STAGE/catalog.db' ] && rm -f '$MAC_DB_FILE-wal' '$MAC_DB_FILE-shm' && mv '$MAC_STAGE/catalog.db' '$MAC_DB_FILE' && { [ ! -f '$MAC_STAGE/catalog.db-wal' ] || mv '$MAC_STAGE/catalog.db-wal' '$MAC_DB_FILE-wal'; } && { [ ! -f '$MAC_STAGE/catalog.db-shm' ] || mv '$MAC_STAGE/catalog.db-shm' '$MAC_DB_FILE-shm'; } && rm -rf '$MAC_STAGE'" \
    || die "placing the new catalog.db on the Mac failed — its app was stopped; check $MAC_DB_FILE there and re-run"

  audit_mac
  echo
  ok "Push complete — the Mac's catalog is now this server's copy."
  if [ "$MAC_APP_WAS_RUNNING" = "1" ]; then
    warn "the Mac's app was stopped for the replace — start it again there (cd $MAC_REPO && npm run dev)"
  fi
  warn "Mac vault is stale (a per-database projection): rebuild with \`learn vault pull\` on the Mac."
}

cmd_pull() {
  info "pull: the MacBook's catalog.db -> this server (replaces this server's)"
  acquire_lock
  require_ssh
  resolve_mac_paths
  mkdir -p "$BUILD_STATE"
  $SSH "$MAC_SSH" "[ -f '$MAC_DB_FILE' ]" || die "no $MAC_DB_FILE on the Mac — nothing to pull"

  snapshot_mac

  info "copying back"
  mkdir -p "$STAGE_DIR"   # a first pull may find no local catalog.db yet
  rm -rf "$STAGE_LOCAL"   # scp -r recreates it from the remote dir's basename
  $SCP -pr "$MAC_SSH:$MAC_STAGE" "$STAGE_DIR/" >/dev/null || die "scp failed"
  $SSH "$MAC_SSH" "rm -rf '$MAC_STAGE'" || true
  [ -f "$STAGE_LOCAL/catalog.db" ] || die "the pull staged no catalog.db — scp failed?"
  ok "Pulled $(du -h "$STAGE_LOCAL/catalog.db" | cut -f1)"

  # The receiving side's writers go down while the file is swapped; what
  # was running comes back at the end (a stopped app stays stopped).
  stop_local_writers

  info "placing catalog.db"
  # Same rule as the Mac side: the old -wal/-shm are not the new file's
  # own, so they go first; then the staged files rename in.
  rm -f "$CATALOG_DB-wal" "$CATALOG_DB-shm"
  mv "$STAGE_LOCAL/catalog.db" "$CATALOG_DB" \
    || { start_local_writers; die "could not place $CATALOG_DB — $(left_stopped) left stopped"; }
  # The db is already replaced from here on, so a failed companion move
  # reports with the writers back up rather than leaving them stopped.
  if [ -f "$STAGE_LOCAL/catalog.db-wal" ]; then
    mv "$STAGE_LOCAL/catalog.db-wal" "$CATALOG_DB-wal" \
      || { start_local_writers; die "could not place $CATALOG_DB-wal (the db itself was replaced; $(left_stopped) restarted)"; }
  fi
  if [ -f "$STAGE_LOCAL/catalog.db-shm" ]; then
    mv "$STAGE_LOCAL/catalog.db-shm" "$CATALOG_DB-shm" \
      || { start_local_writers; die "could not place $CATALOG_DB-shm (the db itself was replaced; $(left_stopped) restarted)"; }
  fi
  rm -rf "$STAGE_LOCAL"

  audit_local
  start_local_writers
  echo
  ok "Pull complete — this server's catalog is now the Mac's copy."
  warn "This server's vault is stale (a per-database projection): rebuild with \`learn vault pull\` in $REPO_DIR."
}

# --------------------------------------------------------------------- main
case "${1:-}" in
  install)   cmd_install ;;
  mac-setup) cmd_mac_setup ;;
  status)    cmd_status ;;
  push)      cmd_push ;;
  pull)      cmd_pull ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
