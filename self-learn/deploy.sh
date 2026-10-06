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
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE and COMPOSE_DIR are
# baked in at install time — edit the copy in the setup-server repo, then
# re-run setup.sh).
#
# Update order follows docs/HOMESERVER.md step 14 in the self-learn repo:
# stop the app, pull, npm ci when the lockfile moved, catalog migrate, build,
# start again. Stopping first matters: `npm ci` replaces node_modules under a
# running `next start`, and `next build` rewrites .next/ while it is served.
# A deliberately stopped service is left stopped — the poller maintains the
# deployment, it does not override the owner's stop.

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
WEB_UNIT="self-learn.service"
WEB_LABEL="com.self-learn.web"

# --------------------------------------------------------------------- lock
# mkdir is the portable atomic lock (macOS has no flock). A lock older than
# 60 min means a previous run died hard — reclaim it.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  echo "removing stale deploy lock (>60 min old)"
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another deploy is running — skipping"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# --------------------------------------------------------------- web service
WAS_ACTIVE=0
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
die_deploy() {
  echo "deploy failed: $1" >&2
  if [ "$WAS_ACTIVE" = "1" ]; then
    echo "restarting the previous build" >&2
    web_start || true
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
built_sha="$(cat "$BUILD_STATE/built-sha" 2>/dev/null || echo none)"

if [ "$remote_sha" = "$built_sha" ] && [ -d "$NEXT_DIR" ] && [ "$FORCE" -eq 0 ]; then
  echo "up to date at $built_sha"
  exit 0
fi
echo "deploying $remote_sha (was: $built_sha)"

# ------------------------------------------------------------- stop the app
if web_is_active; then
  WAS_ACTIVE=1
  echo "stopping the web app while node_modules and .next are replaced"
  web_stop || die_deploy "stop $WEB_UNIT"
fi

git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH" || die_deploy "git reset"

# --------------------------------------------------------- checkout env files
# Regenerated on every deploy: the checkout is machine-managed (reset --hard
# above), so these are outputs, not user config. Rotation = edit the service
# .env, then run this script (or setup.sh) again. NEXT_PUBLIC_* is inlined at
# build time, which is why this step sits between reset and build.
cat > "$REPO_DIR/apps/web/.env.local" <<EOF
# Written by deploy.sh from $ENV_FILE. Do not edit here — edit that file.
DATABASE_URL=$DATABASE_URL
OWNER_PASSWORD=$OWNER_PASSWORD
AUTH_SECRET=$AUTH_SECRET
NEXT_PUBLIC_SITE_URL=$PUBLIC_URL
EOF

cat > "$REPO_DIR/services/catalog/.env" <<EOF
# Written by deploy.sh from $ENV_FILE. Do not edit here — edit that file.
DATABASE_URL=$DATABASE_URL
SELF_LEARN_HOME=$SELF_LEARN_HOME
EOF

# ------------------------------------------------------------------- npm ci
mkdir -p "$BUILD_STATE"
cd "$REPO_DIR"
lock_sum="$(cksum package-lock.json | awk '{print $1}')"
if [ ! -d node_modules ] || [ "$lock_sum" != "$(cat "$BUILD_STATE/npm-lock-cksum" 2>/dev/null || echo none)" ]; then
  echo "installing dependencies (npm ci)"
  npm ci --no-audit --no-fund || die_deploy "npm ci"
  echo "$lock_sum" > "$BUILD_STATE/npm-lock-cksum"
fi

# ------------------------------------------------------------------ database
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
echo "$remote_sha" > "$BUILD_STATE/built-sha"

# ---------------------------------------------------------------- start again
if [ "$WAS_ACTIVE" = "1" ]; then
  web_start || die_deploy "start $WEB_UNIT"
  echo "web app restarted"
else
  echo "web app was not running — left stopped (start it with setup.sh or systemctl --user start $WEB_UNIT)"
fi
echo "deployed $remote_sha"
