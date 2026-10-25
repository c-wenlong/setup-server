#!/usr/bin/env bash
#
# deploy.sh — pull kaichenpedia from GitHub and rebuild the wiki if it changed.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead
# deployd (services/deployd) polls the remote and re-runs setup.sh when
# BRANCH moves — this script is the rebuild half of that run, and exits
# fast when origin/BRANCH hasn't moved. Also runnable by hand:
#
#   deploy.sh            # build only if origin/BRANCH has new commits
#   deploy.sh --force    # rebuild even without new commits
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE is baked in at
# install time — edit the copy in the setup-server repo, then re-run setup.sh).
#
# Build pipeline (mirrors the repo's own Cloudflare deploy):
#   git reset --hard origin/BRANCH
#   python3 scripts/sync_wiki_to_site.py     # wiki/ -> site/content/
#   npm ci                                   # only when package-lock changes
#   npx quartz build                         # site/public/
#   swap site/public into www/current        # atomic: next -> current

set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# systemd/launchd PATH won't include a nix/nvm/brew node — use the baked path.
export PATH="$NODE_BIN:$PATH"
export GIT_TERMINAL_PROMPT=0   # fail loudly instead of hanging on a prompt

REPO_DIR="$SERVICE_HOME/repo"
WWW_DIR="$SERVICE_HOME/www"
BUILD_STATE="$SERVICE_HOME/state"
LOCK="$SERVICE_HOME/.deploy.lock"

# --------------------------------------------------------------------- lock
# mkdir is the portable atomic lock (macOS has no flock). A lock older than
# 60 min means a previous run died hard — reclaim it.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  echo "removing stale deploy lock (>60 min old)"
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another deploy is running — skipping" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# ------------------------------------------------------------- fetch/compare
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "cloning $REPO_URL (branch $BRANCH)"
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
remote_sha="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
# deployd asked for a specific remote sha (DEPLOY_SHA). If the fetch could
# not bring it down, building origin/$BRANCH would deploy something else
# and deployd would still record the requested sha as done — fail instead
# so it retries.
if [ -n "${DEPLOY_SHA:-}" ] \
    && ! git -C "$REPO_DIR" merge-base --is-ancestor "$DEPLOY_SHA" "$remote_sha" 2>/dev/null; then
  echo "deployd asked for $DEPLOY_SHA but origin/$BRANCH is at $remote_sha (fetch failed or diverged) — failing so it retries" >&2
  exit 1
fi
built_sha="$(cat "$BUILD_STATE/built-sha" 2>/dev/null || echo none)"

if [ "$remote_sha" = "$built_sha" ] && [ -d "$WWW_DIR/current" ] && [ "$FORCE" -eq 0 ]; then
  echo "up to date at $built_sha"
  exit 0
fi

# -------------------------------------------------------------------- build
echo "deploying $remote_sha (was: $built_sha)"
git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"

echo "syncing wiki/ -> site/content/"
python3 "$REPO_DIR/scripts/sync_wiki_to_site.py"

cd "$REPO_DIR/site"
mkdir -p "$BUILD_STATE"
lock_sum="$(cksum package-lock.json | awk '{print $1}')"
if [ ! -d node_modules ] || [ "$lock_sum" != "$(cat "$BUILD_STATE/npm-lock-cksum" 2>/dev/null || echo none)" ]; then
  echo "installing site dependencies (npm ci)"
  npm ci --no-audit --no-fund
  echo "$lock_sum" > "$BUILD_STATE/npm-lock-cksum"
fi

echo "building site (quartz)"
npx quartz build

# --------------------------------------------------------------------- swap
# nginx serves $WWW_DIR/current (bind mount of the parent keeps the swap
# atomic — never mv the mounted dir itself).
mkdir -p "$WWW_DIR"
rm -rf "$WWW_DIR/next" "$WWW_DIR/prev"
cp -R "$REPO_DIR/site/public" "$WWW_DIR/next"
[ -d "$WWW_DIR/current" ] && mv "$WWW_DIR/current" "$WWW_DIR/prev"
mv "$WWW_DIR/next" "$WWW_DIR/current"

echo "$remote_sha" > "$BUILD_STATE/built-sha"
echo "deployed $remote_sha"
