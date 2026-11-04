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
#   docker build -f site/Dockerfile -t kaichenpedia:<sha>-<build time> <repo root>
#   probe: run the new image on a spare loopback port and health-check it
#   docker compose up -d   (KAICHENPEDIA_IMAGE=<that tag>), health check again
#
# The live container is only replaced by an image that already answered as
# a probe, so a broken build or a crashing image never takes the site down
# (including the first run on a pre-Docker install, which has nothing to
# roll back to). If the swap itself fails, the previous image is restored.
# Every failure exits non-zero, so deployd backs off and retries the sha.

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

# healthy URL: poll for up to ~a minute.
healthy() {
  local i
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 5 "$1" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

PROBE="kaichenpedia-probe"
drop_probe() { docker rm -f "$PROBE" >/dev/null 2>&1 || true; }

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
  # Still under the lock: make sure the recorded image is what runs. That
  # repairs a stopped or removed container, and --remove-orphans drops the
  # pre-Docker kaichenpedia-api sidecar.
  compose_up "$prev_image"
  exit 0
fi

# -------------------------------------------------------------------- build
# Unique per build: a --force rebuild of the same commit must not move the
# tag the running (and rollback) image is known by.
image="$IMAGE_REPO:$(printf '%s' "$remote_sha" | cut -c1-12)-$(date -u +%Y%m%d%H%M%S)"
echo "deploying $remote_sha (was: $built_sha)"
git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"

echo "building $image from site/Dockerfile"
if ! docker build --file "$REPO_DIR/site/Dockerfile" --tag "$image" "$REPO_DIR"; then
  echo "build failed — the running container was left as it was" >&2
  exit 1
fi

# -------------------------------------------------------------------- probe
# Prove the new image starts and answers before the live container is
# touched. Its port is picked by Docker on loopback; its logs are printed
# here on failure, so the deploy log keeps the startup error.
drop_probe
trap 'drop_probe; rmdir "$LOCK" 2>/dev/null || true' EXIT
echo "probing $image"
if ! docker run -d --name "$PROBE" --publish 127.0.0.1::8080 \
    -e PORT=8080 -e HOSTNAME=0.0.0.0 "$image" >/dev/null; then
  echo "$image would not start — the running container was left as it was" >&2
  exit 1
fi
probe_port="$(docker port "$PROBE" 8080/tcp 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1)"
if [ -z "$probe_port" ] || ! healthy "http://127.0.0.1:$probe_port/"; then
  echo "$image did not answer as a probe — the running container was left as it was" >&2
  echo "--- probe logs ---" >&2
  docker logs --tail 80 "$PROBE" >&2 2>&1 || true
  exit 1
fi
drop_probe

# --------------------------------------------------------------------- swap
mkdir -p "$BUILD_STATE"
echo "starting $image"
if ! compose_up "$image" || ! healthy "$HEALTH_URL"; then
  echo "$image did not take over on $HEALTH_URL" >&2
  echo "--- container logs ---" >&2
  docker logs --tail 80 kaichenpedia >&2 2>&1 || true
  if [ -n "$prev_image" ] && docker image inspect "$prev_image" >/dev/null 2>&1; then
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
