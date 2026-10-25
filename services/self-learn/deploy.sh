#!/usr/bin/env bash
#
# deploy.sh — pull c-wenlong/self-learn from GitHub and redeploy if it changed.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead this
# script runs every POLL_SECONDS (systemd user timer on Linux, launchd on
# macOS) and exits fast when origin/BRANCH hasn't moved. Also runnable by hand:
#
#   deploy.sh            # redeploy only if origin/BRANCH has new commits
#   deploy.sh --force    # redeploy even without new commits
#   deploy.sh --sha <r>  # redeploy a specific commit (rollback — pause the
#                        # timer first, or the next poll redeploys BRANCH)
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE and COMPOSE_DIR are
# baked in at install time — edit the copy in the setup-server repo, then
# re-run setup.sh).
#
# Update order follows docs/HOMESERVER.md step 14 in the self-learn repo:
# stop the app, pull, npm ci when the lockfile moved, catalog migrate, build,
# start again. Stopping first matters: `npm ci` replaces node_modules under a
# running `next start`, and `next build` rewrites .next/ while it is served.
# Before those steps the previous node_modules/.next are renamed aside, so a
# failed step restores and restarts the previous build instead of a
# half-written tree. A deliberately stopped service is left stopped — the
# poller maintains the deployment (Postgres included, which is returned to
# the state it was found in), it does not override the owner's stop.

set -euo pipefail

ENV_FILE="__ENV_FILE__"
COMPOSE_DIR="__COMPOSE_DIR__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# systemd/launchd PATH won't include a nix/nvm/brew node — use the baked path.
export PATH="$NODE_BIN:$PATH"
export GIT_TERMINAL_PROMPT=0   # fail loudly instead of hanging on a prompt

OS="$(uname -s)"
REPO_DIR="$SERVICE_HOME/repo"
BUILD_STATE="$SERVICE_HOME/state"
LOCK="$SERVICE_HOME/.deploy.lock"
NEXT_DIR="$REPO_DIR/apps/web/.next"
SNAP="$BUILD_STATE/rollback"
TL_DIR="$REPO_DIR/tools/tldrawkc"
TL_SNAP="$BUILD_STATE/rollback-tldrawkc"
WEB_UNIT="self-learn.service"
WEB_LABEL="com.self-learn.web"
STUDIO_UNIT="self-learn-studio.service"
STUDIO_LABEL="com.self-learn.studio"

# --------------------------------------------------------------------- lock
# mkdir is the portable atomic lock (macOS has no flock). The holder writes
# its start identity, then its pid: pid + start uniquely names a process
# instance, so a dead holder, a reused pid or a lock whose pid was never
# written all reclaim — while a live holder is never raced, no matter how
# old the lock is. A lock with a pid but no start is a pre-start-tracking
# holder: identity cannot be proven, so it is kept only while its pid
# lives, with the old 60-min bound as the backstop.
pid_start() {  # the start identity of pid $1; empty when it is gone
  if [ "$OS" = "Linux" ]; then
    sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
  else
    ps -o lstart= -p "$1" 2>/dev/null
  fi
}
if [ -d "$LOCK" ]; then
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  started="$(cat "$LOCK/started" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ -n "$started" ]; then
    if ! kill -0 "$owner" 2>/dev/null; then
      echo "removing stale deploy lock (owner pid $owner is gone)"
      rm -rf "$LOCK"
    elif [ "$(pid_start "$owner")" != "$started" ]; then
      echo "removing stale deploy lock (pid $owner now belongs to another process)"
      rm -rf "$LOCK"
    fi
  elif [ -n "$owner" ]; then
    if ! kill -0 "$owner" 2>/dev/null; then
      echo "removing stale deploy lock (owner pid $owner is gone)"
      rm -rf "$LOCK"
    elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      echo "removing stale deploy lock (>60 min old, owner not verifiable)"
      rm -rf "$LOCK"
    fi
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    echo "removing stale deploy lock (owner never recorded)"
    rm -rf "$LOCK"
  fi
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another deploy is running — skipping"
  exit 0
fi
pid_start $$ > "$LOCK/started"
echo $$ > "$LOCK/pid"
# Only remove the lock while it is still ours — a reclaimed-out process must
# not delete the next owner's lock on exit.
trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"' EXIT

FORCE=0
PIN_SHA=""
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  --sha) PIN_SHA="${2:?usage: deploy.sh [--force | --sha <commit>]}" ;;
  *) echo "usage: deploy.sh [--force | --sha <commit>]" >&2; exit 2 ;;
esac

# --------------------------------------------------------------- app services
# The studio runner is managed with the app: it shells `npm run catalog` out
# of the same node_modules, so it goes down for the npm ci window and comes
# back only if it was running — a deliberately stopped runner stays stopped.
WAS_ACTIVE=0
STUDIO_WAS_ACTIVE=0
if [ "$OS" = "Linux" ]; then
  WEB_SVC="$WEB_UNIT"; STUDIO_SVC="$STUDIO_UNIT"
else
  WEB_SVC="$WEB_LABEL"; STUDIO_SVC="$STUDIO_LABEL"
fi
svc_is_active() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user is-active --quiet "$1"
  else
    launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1
  fi
}
svc_stop() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user stop "$1"
  else
    launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  fi
}
svc_start() {
  if [ "$OS" = "Linux" ]; then
    systemctl --user start "$1"
  else
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$1.plist" \
      2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$1"
  fi
}
studio_installed() {
  [ -f "$HOME/.config/systemd/user/$STUDIO_UNIT" ] \
    || [ -f "$HOME/Library/LaunchAgents/$STUDIO_LABEL.plist" ]
}
# Postgres is started below for the migrate; if it was not running before and
# the app is staying stopped, the operator's stop covered it — put it back.
DB_WAS_UP=1
db_as_found() {
  if [ "$DB_WAS_UP" = "0" ] && [ "$WAS_ACTIVE" = "0" ]; then
    docker compose --project-directory "$COMPOSE_DIR" stop >/dev/null 2>&1 || true
  fi
}
die_deploy() {
  echo "deploy failed: $1" >&2
  # Restore the rename-aside snapshot: restarting a half-ci'd node_modules or
  # a half-written .next would serve a broken app, not "the previous build".
  if [ -d "$SNAP/node_modules" ] || [ -d "$SNAP/.next" ]; then
    echo "restoring the pre-deploy snapshot" >&2
    if [ -d "$SNAP/node_modules" ]; then
      rm -rf "$REPO_DIR/node_modules"; mv "$SNAP/node_modules" "$REPO_DIR/node_modules"
    fi
    if [ -d "$SNAP/.next" ]; then
      rm -rf "$NEXT_DIR"; mv "$SNAP/.next" "$NEXT_DIR"
    fi
    rm -rf "$SNAP"
  fi
  # tldrawkc's own node_modules and dist/ are renamed aside before its build
  # (below). The runner executes dist/, so a half-written one would restart
  # the studio unable to queue diagram jobs; the checkout itself may sit at
  # the new revision, which is harmless while the old build output is back.
  if [ -d "$TL_SNAP/node_modules" ] || [ -d "$TL_SNAP/dist" ]; then
    echo "restoring the previous tldrawkc build" >&2
    if [ -d "$TL_SNAP/node_modules" ]; then
      rm -rf "$TL_DIR/node_modules"; mv "$TL_SNAP/node_modules" "$TL_DIR/node_modules"
    fi
    if [ -d "$TL_SNAP/dist" ]; then
      rm -rf "$TL_DIR/dist"; mv "$TL_SNAP/dist" "$TL_DIR/dist"
    fi
    rm -rf "$TL_SNAP"
  fi
  db_as_found
  if [ "$WAS_ACTIVE" = "1" ]; then
    echo "restarting the previous build" >&2
    svc_start "$WEB_SVC" || true
  fi
  if [ "$STUDIO_WAS_ACTIVE" = "1" ]; then
    svc_start "$STUDIO_SVC" || true
  fi
  exit 1
}

# ------------------------------------------------------------- fetch/compare
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "cloning $REPO_URL (branch $BRANCH)"
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR" || die_deploy "git clone"
fi

git -C "$REPO_DIR" fetch --quiet origin "$BRANCH" || die_deploy "git fetch"
remote_sha="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
target_sha="${PIN_SHA:-$remote_sha}"
built_sha="$(cat "$BUILD_STATE/built-sha" 2>/dev/null || echo none)"

# The two feature flags are written into apps/web/.env.local below, and the
# runner is set up from the same flags, so a flag change in $ENV_FILE is
# something to deploy even when origin has not moved. Without this a setup.sh
# re-run after flipping STUDIO_ENABLED exits "up to date" here, and the web
# app keeps hiding (or exposing) Studio against the runner's new state.
env_sig="STUDIO_ENABLED=${STUDIO_ENABLED:-0} ASSET_FILES_ENABLED=${ASSET_FILES_ENABLED:-0}"
built_env_sig="$(cat "$BUILD_STATE/env-sig" 2>/dev/null || echo none)"

if [ "$target_sha" = "$built_sha" ] && [ "$env_sig" = "$built_env_sig" ] \
    && [ -d "$NEXT_DIR" ] && [ "$FORCE" -eq 0 ]; then
  echo "up to date at $built_sha"
  exit 0
fi
echo "deploying $target_sha (was: $built_sha)"

# ------------------------------------------------------------- stop the app
if svc_is_active "$WEB_SVC"; then
  WAS_ACTIVE=1
  echo "stopping the web app while node_modules and .next are replaced"
  svc_stop "$WEB_SVC" || die_deploy "stop $WEB_UNIT"
fi
if studio_installed && svc_is_active "$STUDIO_SVC"; then
  STUDIO_WAS_ACTIVE=1
  echo "stopping the studio runner while node_modules is replaced"
  svc_stop "$STUDIO_SVC" || die_deploy "stop $STUDIO_UNIT"
fi

git -C "$REPO_DIR" reset --hard --quiet "$target_sha" || die_deploy "git reset"

# --------------------------------------------------------- checkout env files
# Regenerated on every deploy: the checkout is machine-managed (reset --hard
# above), so these are outputs, not user config. Rotation = edit the service
# .env, then run this script (or setup.sh) again. NEXT_PUBLIC_* is inlined at
# build time, which is why this step sits between reset and build.
# umask 077 for creation; the chmod covers rewrites too (cat > keeps an
# existing file's mode). These carry OWNER_PASSWORD/AUTH_SECRET/DATABASE_URL.
( umask 077
cat > "$REPO_DIR/apps/web/.env.local" <<EOF
# Written by deploy.sh from $ENV_FILE. Do not edit here — edit that file.
DATABASE_URL=$DATABASE_URL
OWNER_PASSWORD=$OWNER_PASSWORD
AUTH_SECRET=$AUTH_SECRET
NEXT_PUBLIC_SITE_URL=$PUBLIC_URL
STUDIO_ENABLED=${STUDIO_ENABLED:-0}
ASSET_FILES_ENABLED=${ASSET_FILES_ENABLED:-0}
EOF

cat > "$REPO_DIR/services/catalog/.env" <<EOF
# Written by deploy.sh from $ENV_FILE. Do not edit here — edit that file.
DATABASE_URL=$DATABASE_URL
SELF_LEARN_HOME=$SELF_LEARN_HOME
EOF
)
chmod 600 "$REPO_DIR/apps/web/.env.local" "$REPO_DIR/services/catalog/.env"

# ------------------------------------------------------------------- npm ci
mkdir -p "$BUILD_STATE"
cd "$REPO_DIR"
lock_sum="$(cksum package-lock.json | awk '{print $1}')"
need_ci=0
if [ ! -d node_modules ] || [ "$lock_sum" != "$(cat "$BUILD_STATE/npm-lock-cksum" 2>/dev/null || echo none)" ]; then
  need_ci=1
fi

# Rename-aside snapshot of the pieces npm ci / next build are about to
# replace; die_deploy puts them back on any failure below.
rm -rf "$SNAP"; mkdir -p "$SNAP"
[ ! -d "$NEXT_DIR" ] || mv "$NEXT_DIR" "$SNAP/.next"
if [ "$need_ci" = "1" ]; then
  [ ! -d node_modules ] || mv node_modules "$SNAP/node_modules"
  echo "installing dependencies (npm ci)"
  npm ci --no-audit --no-fund || die_deploy "npm ci"
fi

# -------------------------------------------------------------- tldrawkc
# The studio runner refuses to queue jobs without a built tldrawkc. Only
# fetched while the flag is on (it is a second private repo and a full npm
# build). Rebuilt when the recorded gitlink moved, when no build ever
# completed, or when the build output is gone: the stamp under $BUILD_STATE
# outlives a lost checkout, so it cannot be the only evidence of a build.
# Its node_modules and dist/ are renamed aside first so a failed build puts
# the previous one back (die_deploy) instead of leaving a half-written dist/.
if [ "${STUDIO_ENABLED:-0}" = "1" ]; then
  git -C "$REPO_DIR" submodule update --init tools/tldrawkc || die_deploy "tldrawkc submodule update"
  tl_sha="$(git -C "$TL_DIR" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$tl_sha" != "$(cat "$BUILD_STATE/tldrawkc-sha" 2>/dev/null || echo none)" ] \
      || [ ! -d "$TL_DIR/dist" ] || [ ! -d "$TL_DIR/node_modules" ]; then
    echo "building tldrawkc ($tl_sha)"
    rm -rf "$TL_SNAP"; mkdir -p "$TL_SNAP"
    [ ! -d "$TL_DIR/dist" ] || mv "$TL_DIR/dist" "$TL_SNAP/dist"
    [ ! -d "$TL_DIR/node_modules" ] || mv "$TL_DIR/node_modules" "$TL_SNAP/node_modules"
    (cd "$TL_DIR" && npm ci --no-audit --no-fund && npm run build) \
      || die_deploy "tldrawkc build"
    rm -rf "$TL_SNAP"
    echo "$tl_sha" > "$BUILD_STATE/tldrawkc-sha"
  fi
fi

# ------------------------------------------------------------------ database
# A stopped app may mean a stopped Postgres too (launcher stop covers both) —
# record which it was so db_as_found can leave it that way again.
DB_WAS_UP=0
if docker compose --project-directory "$COMPOSE_DIR" ps --status running -q db 2>/dev/null | grep -q .; then
  DB_WAS_UP=1
fi
docker compose --project-directory "$COMPOSE_DIR" up -d || die_deploy "docker compose up"
echo "waiting for Postgres on 127.0.0.1:$PG_PORT"
ready=0
for _ in $(seq 1 30); do
  if docker compose --project-directory "$COMPOSE_DIR" exec -T db \
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = "1" ] || die_deploy "Postgres did not become ready"

npm run catalog -- migrate || die_deploy "catalog migrate"

# --------------------------------------------------------------------- build
npm run build || die_deploy "next build"
rm -rf "$SNAP"
# Mark state only now: on a failure the snapshot restore rolled node_modules
# back, so the lockfile cksum must still describe the OLD tree — writing it
# here keeps the next retry honest.
echo "$lock_sum" > "$BUILD_STATE/npm-lock-cksum"
echo "$target_sha" > "$BUILD_STATE/built-sha"
echo "$env_sig" > "$BUILD_STATE/env-sig"

# ---------------------------------------------------------------- start again
db_as_found
if [ "$WAS_ACTIVE" = "1" ]; then
  svc_start "$WEB_SVC" || die_deploy "start $WEB_UNIT"
  echo "web app restarted"
else
  echo "web app was not running — left stopped (start it with setup.sh or systemctl --user start $WEB_UNIT)"
fi
if [ "$STUDIO_WAS_ACTIVE" = "1" ]; then
  svc_start "$STUDIO_SVC" || die_deploy "start $STUDIO_UNIT"
  echo "studio runner restarted"
fi
echo "deployed $target_sha"
