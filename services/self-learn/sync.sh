#!/usr/bin/env bash
#
# sync.sh — keep the homeserver's self-learn data in step with the MacBook.
#
# Two halves, following docs/HOMESERVER.md in the self-learn repo (S1–S3):
#
#   blobs — ~/.self-learn/blobs/local rides a dedicated Seafile library
#           ("self-learn-blobs") continuously. The store is content-addressed,
#           so both sides union without conflicts. `.owner` and `.tmp` sit
#           beside local/, outside the synced tree: the marker names one
#           database, and a foreign one makes uploads and `blob audit`
#           refuse the root. Server side: seaf-cli under a systemd user
#           unit. Mac side: the installed Seafile Client.app pairs the
#           library once (no seaf-cli exists for macOS) — `mac-setup`
#           writes the ignore file and prints the pairing steps.
#
#   db    — the two Postgres catalogs are separate primaries that are meant
#           to diverge (S1). `push`/`pull` copy one over the other with
#           pg_dump -> drop -> create -> pg_restore. Never a merge: the
#           receiving side's history is replaced wholesale. The receiving
#           side's `.owner` is rewritten for the new pg_database oid, and
#           its vault/ is left stale on purpose (rebuild with `learn vault
#           pull` — it is a per-database projection). Provider keys survive
#           because both ends share AUTH_SECRET (S4). Blobs do not travel
#           with the dump; the Seafile link converges them.
#
#   sync.sh install     server side of the Seafile link (account, library,
#                       seaf-cli daemon under systemd, ignore file)
#   sync.sh mac-setup   prep the MacBook over ssh + print pairing steps
#   sync.sh status      both databases and both blob stores, side by side
#   sync.sh push        dump THIS server's catalog, restore it on the Mac
#   sync.sh pull        dump the Mac's catalog, restore it here
#
# Reads this service's .env (ports, credentials, SERVICE_HOME); Seafile
# admin credentials come from the sibling seafile service's .env. Sync
# settings written by install (SEAFILE_SYNC_*, MAC_*) live in .env too.
# Every SQL query travels on stdin, so local docker-exec and remote ssh
# transports see identical text — no quoting anywhere.
#
# Mac overrides (defaults match the MacBook): MAC_SSH, MAC_HOME, MAC_REPO,
# MAC_PGBIN, MAC_DB, MAC_DB_URL, MAC_PGPORT, MAC_SEAFILE_URL.

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

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — deploy self-learn first (./setup.sh)"
set -a; . "$ENV_FILE"; set +a
SERVICE_HOME="${SERVICE_HOME:?SERVICE_HOME missing from $ENV_FILE}"
SELF_LEARN_HOME="${SELF_LEARN_HOME:?SELF_LEARN_HOME missing from $ENV_FILE}"
NODE_BIN="${NODE_BIN:-/usr/bin}"
POSTGRES_USER="${POSTGRES_USER:-catalog}"
POSTGRES_DB="${POSTGRES_DB:-self_learn}"
PG_PORT="${PG_PORT:-5432}"
DB_CONTAINER="${DB_CONTAINER:-self-learn-db}"
REPO_DIR="$SERVICE_HOME/repo"
BUILD_STATE="$SERVICE_HOME/state"
LOCK="$SERVICE_HOME/.deploy.lock"   # shared with deploy.sh: a live sync blocks the poller
WEB_UNIT="self-learn.service"
WEB_LABEL="com.self-learn.web"
STUDIO_UNIT="self-learn-studio.service"
STUDIO_LABEL="com.self-learn.studio"
SEAF_UNIT="self-learn-seafile.service"
SEAF_DIR="$SERVICE_HOME/seafile"    # ccnet config root for the sync daemon
BLOBS_DIR="$SELF_LEARN_HOME/blobs"
# Only blobs/local is the library worktree. .owner and .tmp sit beside it at
# blobs/ root — outside the tree entirely, so a seafile-ignore miss or a
# merge conflict can never carry a foreign .owner onto this machine (the
# ignore file inside local/ is a second line of defence, not the first).
LINK_DIR="$BLOBS_DIR/local"
IGNORE_FILE="$LINK_DIR/seafile-ignore.txt"

MAC_SSH="${MAC_SSH:-user@100.77.77.78}"
MAC_HOME="${MAC_HOME:-/Users/kaichen/.self-learn}"
MAC_REPO="${MAC_REPO:-$MAC_HOME/checkout}"
MAC_PGBIN="${MAC_PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
MAC_DB="${MAC_DB:-self_learn}"
MAC_PGPORT="${MAC_PGPORT:-5432}"
MAC_DB_URL="${MAC_DB_URL:-postgres://user@127.0.0.1:$MAC_PGPORT/$MAC_DB}"
MAC_DUMP="$MAC_HOME/self_learn-sync.dump"   # staging path on the Mac (not shared /tmp)
# nix-installed node/npm are not on a bare ssh PATH
MAC_PATH_PREFIX="${MAC_PATH_PREFIX:-/etc/profiles/per-user/kaichen/bin}"

SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
SCP="scp -o BatchMode=yes -o ConnectTimeout=10"
OS="$(uname -s)"

# ------------------------------------------------------------- transports
# Local psql runs inside the Postgres container (the image's local socket is
# trust); the Mac's Homebrew postgres trusts the owner over loopback. Both
# take the database as the only argument and read the query on stdin.
lpsql() { docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1" -tA; }
mpsql() { $SSH "$MAC_SSH" "$MAC_PGBIN/psql -v ON_ERROR_STOP=1 -d $1 -tA"; }
psql_on() { local side="$1"; shift; if [ "$side" = local ]; then lpsql "$@"; else mpsql "$@"; fi; }

require_ssh() {
  $SSH "$MAC_SSH" true 2>/dev/null || die "cannot ssh $MAC_SSH — tailscale up? key installed?"
}

usage() {
  sed -n '27,41p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
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
# is mid-restore.
acquire_lock() {
  if [ -d "$LOCK" ]; then
    owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      warn "removing stale deploy lock (owner pid $owner is gone)"
      rm -rf "$LOCK"
    elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      warn "removing stale deploy lock (>60 min old)"
      rm -rf "$LOCK"
    fi
  fi
  mkdir "$LOCK" 2>/dev/null || die "a deploy or sync is running — try again after it finishes"
  echo $$ > "$LOCK/pid"
  trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"' EXIT
}

# --------------------------------------------------------------- web service
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
# database and is not covered by the web app's stop, so a restore has to take
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
# What a failed pull leaves down, for its error messages.
left_stopped() {
  if [ "${STUDIO_WAS_ACTIVE:-0}" = "1" ]; then
    printf '%s and %s' "$WEB_UNIT" "$STUDIO_UNIT"
  else
    printf '%s' "$WEB_UNIT"
  fi
}

wait_pg() {
  for _ in $(seq 1 30); do
    docker exec -i "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Postgres did not become ready"
}

# ------------------------------------------------------------------ snapshot
# `status` table: for each catalog table, row count and its newest timestamp
# where the schema has one (schema drift between checkouts makes a fixed
# column list fragile). Same SQL on stdin on both ends; only the psql
# transport differs.
SNAP_META_SQL='
SELECT t.name,
       (SELECT c.column_name FROM information_schema.columns c
         WHERE c.table_schema = '"'"'public'"'"' AND c.table_name = t.name
           AND c.data_type LIKE '"'"'timestamp%'"'"'
           AND c.column_name IN ('"'"'at'"'"','"'"'last_reviewed'"'"','"'"'created_at'"'"','"'"'updated_at'"'"','"'"'due'"'"')
         ORDER BY CASE c.column_name WHEN '"'"'at'"'"' THEN 0
                                     WHEN '"'"'last_reviewed'"'"' THEN 1
                                     WHEN '"'"'created_at'"'"' THEN 2
                                     ELSE 3 END
         LIMIT 1) AS ts_col,
       to_regclass('"'"'public.'"'"' || t.name) IS NOT NULL AS present
FROM (VALUES ('"'"'catalog_instance'"'"'),('"'"'learner'"'"'),('"'"'asset'"'"'),
             ('"'"'collection'"'"'),('"'"'collection_item'"'"'),('"'"'concept'"'"'),
             ('"'"'curriculum_item'"'"'),('"'"'content_revision'"'"'),('"'"'event'"'"'),
             ('"'"'mastery'"'"'),('"'"'review'"'"'),('"'"'progress'"'"'),('"'"'recap'"'"'),
             ('"'"'job'"'"'),('"'"'session'"'"'),('"'"'draft'"'"'),('"'"'blob_object'"'"'),
             ('"'"'provider_key'"'"'),('"'"'content_source'"'"')) AS t(name)
ORDER BY t.name;'

db_snapshot() {  # $1 = local|mac, $2 = database name
  local side="$1" db="$2"
  local meta name ts present sql=""
  meta="$(psql_on "$side" "$db" <<<"$SNAP_META_SQL")" || return 1
  while IFS='|' read -r name ts present; do
    [ -n "$name" ] || continue
    if [ "$present" != "t" ]; then
      printf '%-22s %8s %s\n' "$name" "absent" "-"
      continue
    fi
    if [ -n "$ts" ]; then
      sql="${sql}SELECT '${name}' AS t, count(*)::text AS n, COALESCE(max(\"${ts}\")::text,'-') AS newest FROM \"${name}\" UNION ALL "
    else
      sql="${sql}SELECT '${name}' AS t, count(*)::text AS n, '-' AS newest FROM \"${name}\" UNION ALL "
    fi
  done <<<"$meta"
  sql="${sql% UNION ALL } ORDER BY t"
  psql_on "$side" "$db" <<<"$sql" 2>/dev/null | awk -F'|' '{printf "%-22s %8s %s\n", $1, $2, $3}'
  # catalog_instance's row (primary/copy + oid) matters on its own
  psql_on "$side" "$db" <<<'SELECT '"'"'instance'"'"' AS t, row_to_json(catalog_instance)::text FROM catalog_instance;' 2>/dev/null \
    | awk -F'|' '{printf "%-22s %s\n", $1, $2}'
}

# --------------------------------------------------------------------- owner
# The blob root's .owner names <db>:<pg_database oid> + port; a drop+create
# changes the oid, so the receiver's marker must be rewritten for the new
# database or uploads and `blob audit` refuse the root (S3). Written
# directly, never via `blob audit --fix`: --fix also deletes day-old
# orphans, and a delete on a shared store propagates to the other machine.
write_owner_local() {
  local oid
  oid="$(lpsql postgres <<EOF
select oid from pg_database where datname='$POSTGRES_DB';
EOF
)" || die "could not read pg_database oid for $POSTGRES_DB"
  [ -n "$oid" ] || die "empty pg_database oid for $POSTGRES_DB"
  mkdir -p "$BLOBS_DIR"
  printf '{\n  "database": "%s:%s",\n  "port": "%s",\n  "claimed": "%s"\n}\n' \
    "$POSTGRES_DB" "$oid" "$PG_PORT" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    > "$BLOBS_DIR/.owner"
  ok "blob .owner rewritten for $POSTGRES_DB:$oid"
}

write_owner_mac() {
  local oid
  oid="$(mpsql postgres <<EOF
select oid from pg_database where datname='$MAC_DB';
EOF
)" || die "could not read pg_database oid on the Mac"
  [ -n "$oid" ] || die "empty pg_database oid on the Mac"
  $SSH "$MAC_SSH" "cat > '$MAC_HOME/blobs/.owner'" <<EOF
{
  "database": "$MAC_DB:$oid",
  "port": "$MAC_PGPORT",
  "claimed": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
EOF
  ok "Mac blob .owner rewritten for $MAC_DB:$oid"
}

# -------------------------------------------------------------- blob audit
# Informational: reports rows whose object Seafile has not delivered yet.
audit_local() {
  [ -d "$REPO_DIR" ] || { warn "no checkout at $REPO_DIR — skipping audit"; return 0; }
  info "blob audit on this server (informational)"
  if ( cd "$REPO_DIR" && PATH="$NODE_BIN:$PATH" npm run catalog -- blob audit ); then
    ok "blob audit clean"
  else
    warn "audit reported gaps — Seafile may still be delivering; re-run: cd $REPO_DIR && npm run catalog -- blob audit"
  fi
}

audit_mac() {
  info "blob audit on the Mac (informational)"
  if $SSH "$MAC_SSH" "export PATH='$MAC_PATH_PREFIX':\$PATH; cd '$MAC_REPO' && DATABASE_URL='$MAC_DB_URL' SELF_LEARN_HOME='$MAC_HOME' npm run catalog -- blob audit"; then
    ok "Mac blob audit clean"
  else
    warn "Mac audit reported gaps — Seafile may still be delivering"
  fi
}

# ------------------------------------------------------------ seafile ignore
write_ignore_local() {
  mkdir -p "$LINK_DIR"
  cat > "$IGNORE_FILE" <<'EOF'
# Written by services/self-learn/sync.sh — machine-local entries that must not sync.
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
  [ -n "$INIT_SEAFILE_ADMIN_EMAIL" ] && [ -n "$INIT_SEAFILE_ADMIN_PASSWORD" ] \
    || die "admin credentials missing from $SEAFILE_ENV"

  admin_token="$(printf 'data-urlencode "username=%s"\ndata-urlencode "password=%s"\n' \
      "$INIT_SEAFILE_ADMIN_EMAIL" "$INIT_SEAFILE_ADMIN_PASSWORD" \
    | seafile_api POST /api2/auth-token/ \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')"
  [ -n "$admin_token" ] || die "Seafile admin auth failed ($SEAFILE_URL/api2/auth-token/)"

  if [ -z "${SEAFILE_SYNC_USER:-}" ]; then
    # .local suffix: Seafile rejects emails whose domain has no dot (400
    # "email invalid"), and a bare hostname has none.
    SEAFILE_SYNC_USER="self-learn-sync@$(hostname -s 2>/dev/null || hostname).local"
    SEAFILE_SYNC_PASSWORD="$(randhex 24)"
    info "Creating Seafile account $SEAFILE_SYNC_USER"
    printf 'data-urlencode "email=%s"\ndata-urlencode "name=self-learn blob sync"\ndata-urlencode "password=%s"\n' \
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
    info "Creating library self-learn-blobs"
    SEAFILE_SYNC_REPO="$(printf 'data-urlencode "name=self-learn-blobs"\n' \
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
# Generated by services/self-learn/sync.sh — regenerated on every install.
[Unit]
Description=self-learn blob sync (Seafile daemon for ~/.self-learn/blobs)
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
  ok "ssh reachable"

  # Written before any pairing — a synced .owner/.tmp on either side would
  # poison the other machine's blob root.
  info "Writing $MAC_HOME/blobs/local/seafile-ignore.txt"
  $SSH "$MAC_SSH" "mkdir -p '$MAC_HOME/blobs/local' && cat > '$MAC_HOME/blobs/local/seafile-ignore.txt'" <<'EOF'
# Written by services/self-learn/sync.sh — machine-local entries that must not sync.
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
    $SSH "$MAC_SSH" "mkdir -p '$MAC_HOME/.seafile' && { [ -d '$MAC_HOME/.seafile/ccnet' ] || '$SEAF_MAC' init -c '$MAC_HOME/.seafile/ccnet' -d '$MAC_HOME/.seafile'; }" \
      || die "seaf-cli init on the Mac failed"
    # The agent runs seaf-daemon itself (next to seaf-cli) in the foreground
    # with KeepAlive — a oneshot `seaf-cli start` wrapper would leave a dead
    # daemon looking alive, same failure the systemd unit avoids.
    SEAF_DAEMON_MAC="${SEAF_MAC%/*}/seaf-daemon"
    $SSH "$MAC_SSH" "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.self-learn.seafile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/self-learn/sync.sh mac-setup. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.self-learn.seafile</string>
  <key>ProgramArguments</key>
  <array><string>$SEAF_DAEMON_MAC</string><string>-c</string><string>$MAC_HOME/.seafile/ccnet</string><string>-d</string><string>$MAC_HOME/.seafile/seafile-data</string><string>-w</string><string>$MAC_HOME/.seafile/seafile</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/self-learn-seafile.log</string>
  <key>StandardErrorPath</key><string>/tmp/self-learn-seafile.log</string>
</dict>
</plist>
EOF
    $SSH "$MAC_SSH" "launchctl bootout gui/\$(id -u)/com.self-learn.seafile 2>/dev/null; launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.self-learn.seafile.plist" \
      || warn "LaunchAgent load failed — start the daemon by hand: $SEAF_DAEMON_MAC -c $MAC_HOME/.seafile/ccnet -d $MAC_HOME/.seafile/seafile-data -w $MAC_HOME/.seafile/seafile"
    # The agent owns the daemon — no `seaf-cli start` here, or two daemons
    # fight over the same ccnet dir and KeepAlive retries forever. Pairing
    # waits for the agent's daemon to answer rpc first.
    printf '%s\n' "$SEAFILE_SYNC_PASSWORD" | $SSH "$MAC_SSH" "for _ in \$(seq 1 20); do '$SEAF_MAC' list -c '$MAC_HOME/.seafile/ccnet' >/dev/null 2>&1 && break; sleep 0.5; done
      '$SEAF_MAC' list -c '$MAC_HOME/.seafile/ccnet' 2>/dev/null | grep -q '$SEAFILE_SYNC_REPO' || \
        '$SEAF_MAC' sync -l '$SEAFILE_SYNC_REPO' -s '$MAC_SEAFILE_URL' \
          -d '$MAC_HOME/blobs/local' -u '$SEAFILE_SYNC_USER' \
          -c '$MAC_HOME/.seafile/ccnet'" || die "seaf-cli pairing on the Mac failed"
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
  3. Right-click the "self-learn-blobs" library -> "Sync this library" ->
     "sync with an existing folder" -> pick ~/.self-learn/blobs/local.
  4. Enable auto-start on login in the client's settings if it is off.

seafile-ignore.txt is already in place, so the Mac's own .owner never
uploads and the server's never lands there.
EOF
  fi

  echo
  ok "Mac side ready. Verify with: ./sync.sh status"
}

# ------------------------------------------------------------------ status
cmd_status() {
  echo "=== SERVER ($(hostname -s 2>/dev/null || hostname)) ==="
  db_snapshot local "$POSTGRES_DB" || echo "  (database query failed — is $DB_CONTAINER up?)"
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
  db_snapshot mac "$MAC_DB" || echo "  (database query failed)"
  $SSH "$MAC_SSH" "printf 'owner : %s\n' \"\$(tr -d '\n ' < '$MAC_HOME/blobs/.owner' 2>/dev/null || echo missing)\"
printf 'blobs : %s files, %s\n' \"\$(find '$MAC_HOME/blobs/local' -type f 2>/dev/null | wc -l | tr -d ' ')\" \"\$(du -sh '$MAC_HOME/blobs' 2>/dev/null | cut -f1)\"
if pgrep -fl 'Seafile Client|seafile-applet|seaf-daemon' >/dev/null 2>&1; then echo 'seaf  : client running'; else echo 'seaf  : NO client running'; fi"
}

# ----------------------------------------------------------------- push/pull
cmd_push() {
  info "push: this server's database -> the MacBook (replaces the Mac's)"
  acquire_lock
  require_ssh
  mkdir -p "$BUILD_STATE"
  local dump="$BUILD_STATE/self_learn-push.dump"

  info "pg_dump $POSTGRES_DB (docker exec $DB_CONTAINER)"
  # Full-catalog dump = secrets-bearing file: 0600 on both ends, staged
  # under the Mac's private ~ (scp -p carries the mode), never /tmp.
  ( umask 077; docker exec -i "$DB_CONTAINER" pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB" \
      > "$dump" ) || die "pg_dump failed"
  ok "Dumped $(du -h "$dump" | cut -f1)"

  if $SSH "$MAC_SSH" "pgrep -fl 'next.*dev|next-server' 2>/dev/null | grep -q ."; then
    warn "a Next dev/server process is running on the Mac — its connections will be force-dropped"
  fi

  info "copying dump to the Mac"
  $SCP -p "$dump" "$MAC_SSH:$MAC_DUMP" >/dev/null || die "scp failed"

  info "restoring on the Mac: drop + create + pg_restore"
  mpsql postgres <<EOF || die "drop failed on the Mac"
DROP DATABASE IF EXISTS "$MAC_DB" WITH (FORCE);
EOF
  $SSH "$MAC_SSH" "$MAC_PGBIN/createdb \"$MAC_DB\"" || die "createdb failed on the Mac"
  $SSH "$MAC_SSH" "$MAC_PGBIN/pg_restore --no-owner -d \"$MAC_DB\" '$MAC_DUMP'" \
    || die "pg_restore failed on the Mac — its database may be empty/partial; fix and re-run"
  $SSH "$MAC_SSH" "rm -f '$MAC_DUMP'" || true
  rm -f "$dump"

  write_owner_mac
  audit_mac
  echo
  ok "Push complete — the Mac's catalog is now this server's copy."
  warn "Mac vault is stale (a per-database projection): rebuild with \`learn vault pull\` on the Mac."
}

cmd_pull() {
  info "pull: the MacBook's database -> this server (replaces this server's)"
  acquire_lock
  require_ssh
  mkdir -p "$BUILD_STATE"
  local dump="$BUILD_STATE/self_learn-pull.dump"

  info "pg_dump on the Mac"
  $SSH "$MAC_SSH" "umask 077; $MAC_PGBIN/pg_dump -Fc \"$MAC_DB\" > '$MAC_DUMP'" \
    || die "pg_dump failed on the Mac"
  $SCP -p "$MAC_SSH:$MAC_DUMP" "$dump" >/dev/null || die "scp failed"
  $SSH "$MAC_SSH" "rm -f '$MAC_DUMP'" || true
  ok "Pulled $(du -h "$dump" | cut -f1)"

  # The runner first: it depends on the app's node_modules and on this
  # database, and must not run catalog-backed jobs while it is dropped.
  STUDIO_WAS_ACTIVE=0
  if studio_is_active; then
    STUDIO_WAS_ACTIVE=1
    info "stopping $STUDIO_UNIT during the restore"
    studio_stop
  fi
  WAS_ACTIVE=0
  if web_is_active; then
    WAS_ACTIVE=1
    info "stopping $WEB_UNIT during the restore"
    web_stop
  fi
  # Same contract as deploy.sh: Postgres is needed for the restore, but if
  # the operator deliberately stopped it (launcher stop covers both), put
  # it back down afterwards — a pull must not undo their stop.
  DB_WAS_UP=0
  if docker compose --project-directory "$SERVICE_DIR" ps --status running -q db 2>/dev/null | grep -q .; then
    DB_WAS_UP=1
  fi
  docker compose --project-directory "$SERVICE_DIR" up -d >/dev/null
  wait_pg

  info "restoring: drop + create + pg_restore"
  lpsql postgres <<EOF || { warn "drop failed — $(left_stopped) left stopped"; exit 1; }
DROP DATABASE IF EXISTS "$POSTGRES_DB" WITH (FORCE);
EOF
  lpsql postgres <<EOF || { warn "create failed — database is missing, $(left_stopped) left stopped"; exit 1; }
CREATE DATABASE "$POSTGRES_DB";
EOF
  docker exec -i "$DB_CONTAINER" pg_restore --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < "$dump" || die "pg_restore failed — database may be empty/partial; fix and re-run ($(left_stopped) left stopped)"
  rm -f "$dump"

  write_owner_local
  audit_local
  if [ "$DB_WAS_UP" = "0" ] && [ "$WAS_ACTIVE" = "0" ]; then
    docker compose --project-directory "$SERVICE_DIR" stop >/dev/null 2>&1 || true
    info "Postgres put back down (it was stopped before the pull)"
  fi
  if [ "$WAS_ACTIVE" = "1" ]; then
    web_start && ok "$WEB_UNIT restarted"
  fi
  if [ "$STUDIO_WAS_ACTIVE" = "1" ]; then
    studio_start && ok "$STUDIO_UNIT restarted"
  fi
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
