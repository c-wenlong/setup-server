#!/usr/bin/env bash
#
# deploy.sh — pull kaichenpedia from GitHub and rebuild its container if it
# changed.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead
# deployd (services/deployd) polls the remote and re-runs setup.sh when
# BRANCH moves — this script is the rebuild half of that run, and exits
# fast when origin/BRANCH hasn't moved. Also runnable by hand:
#
#   deploy.sh            # build only if origin/BRANCH has new commits
#   deploy.sh --force    # rebuild even without new commits
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE and SERVICE_DIR
# are baked in at install time — edit the copy in the setup-server repo,
# then re-run setup.sh).
#
# Build pipeline:
#   git reset --hard origin/BRANCH
#   docker build -f site/Dockerfile -t kaichenpedia:<sha> <repo root>
#   docker compose up -d   (KAICHENPEDIA_IMAGE=kaichenpedia:<sha>)
#   health check 127.0.0.1:LOCAL_PORT
#
# A failed build leaves the running container untouched. A new container
# that never turns healthy is rolled back to the previous image. Either way
# this exits non-zero, so deployd backs off and retries the sha.

set -euo pipefail

ENV_FILE="__ENV_FILE__"
SERVICE_DIR="__SERVICE_DIR__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

export GIT_TERMINAL_PROMPT=0   # fail loudly instead of hanging on a prompt

REPO_DIR="$SERVICE_HOME/repo"
BUILD_STATE="$SERVICE_HOME/state"
LOCK="$SERVICE_HOME/.deploy.lock"
IMAGE_REPO="kaichenpedia"
HEALTH_URL="http://127.0.0.1:${LOCAL_PORT:-8091}/"

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

compose_up() {
  KAICHENPEDIA_IMAGE="$1" docker compose --project-directory "$SERVICE_DIR" \
    up -d --remove-orphans
}

healthy() {
  local i
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

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
prev_image="$(cat "$BUILD_STATE/image" 2>/dev/null || true)"

# Up to date means the sha matches AND its image still exists locally (a
# pre-Docker install recorded a built-sha for a static build, not an image).
if [ "$remote_sha" = "$built_sha" ] && [ -n "$prev_image" ] && [ "$FORCE" -eq 0 ] \
    && docker image inspect "$prev_image" >/dev/null 2>&1; then
  echo "up to date at $built_sha"
  exit 0
fi

# -------------------------------------------------------------------- build
image="$IMAGE_REPO:$(printf '%s' "$remote_sha" | cut -c1-12)"
echo "deploying $remote_sha (was: $built_sha)"
git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"

echo "building $image from site/Dockerfile"
if ! docker build --file "$REPO_DIR/site/Dockerfile" --tag "$image" "$REPO_DIR"; then
  echo "build failed — the running container was left as it was" >&2
  exit 1
fi

# --------------------------------------------------------------------- swap
mkdir -p "$BUILD_STATE"
echo "starting $image"
compose_up "$image"
if ! healthy; then
  echo "$image did not answer on $HEALTH_URL" >&2
  if [ -n "$prev_image" ] && [ "$prev_image" != "$image" ] \
      && docker image inspect "$prev_image" >/dev/null 2>&1; then
    echo "rolling back to $prev_image" >&2
    compose_up "$prev_image" || true
  fi
  exit 1
fi

echo "$image" > "$BUILD_STATE/image"
echo "$remote_sha" > "$BUILD_STATE/built-sha"

# Keep the running image and the one before it; drop older builds.
docker image ls "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
  | while read -r old; do
      [ "$old" = "$image" ] || [ "$old" = "$prev_image" ] || docker image rm "$old" >/dev/null 2>&1 || true
    done

echo "deployed $remote_sha"
