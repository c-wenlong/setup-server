#!/usr/bin/env bash
#
# deploy.sh — rebuild the encrypted sources site if the fetch clone moved.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead this
# script runs every POLL_SECONDS (systemd user timer on Linux, launchd on
# macOS) and exits fast when the repo's HEAD hasn't moved. Also runnable by
# hand:
#
#   deploy.sh            # build only if HEAD is new
#   deploy.sh --force    # rebuild even without new commits
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE is baked in at
# install time — edit the copy in the setup-server repo, then re-run setup.sh).
#
# Unlike kaichenpedia there is no deploy clone: SOURCE_REPO is the fetch
# clone the fetch timers already pull and commit on, so the poller shares it.
# It is pulled forward (ff-only) but never reset or committed here.
#
# Build pipeline:
#   git -C $SOURCE_REPO pull --ff-only     # best effort; a dirty or offline
#                                          # repo just builds its local HEAD
#   uv sync --quiet                        # in the repo, like run_web.sh
#   uv run scripts/build_site.py --out www/next
#   swap www/next into www/current         # atomic: next -> current

set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# systemd/launchd PATH won't include a brew/uv-local uv — use the baked path.
export PATH="$UV_BIN:$PATH"
export GIT_TERMINAL_PROMPT=0   # fail loudly instead of hanging on a prompt

REPO_DIR="$SOURCE_REPO"
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
  echo "another deploy is running — skipping"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# ------------------------------------------------------------- pull/compare
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "sources repo missing at $REPO_DIR — leaving the last build up" >&2
  exit 1
fi

# Best effort: a weekly-fetch clone can be ahead of origin (push pending),
# behind it (pushed from elsewhere), or dirty — HEAD after this is what we
# build either way. Only a committed state is ever read.
if ! git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
  echo "note: git pull --ff-only did not apply (dirty tree, offline, or diverged) — building local HEAD"
fi

local_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
built_sha="$(cat "$BUILD_STATE/built-sha" 2>/dev/null || echo none)"

if [ "$local_sha" = "$built_sha" ] && [ -d "$WWW_DIR/current" ] && [ "$FORCE" -eq 0 ]; then
  echo "up to date at $built_sha"
  exit 0
fi

# -------------------------------------------------------------------- build
echo "deploying $local_sha (was: $built_sha)"

echo "syncing deps (uv sync)"
( cd "$REPO_DIR" && uv sync --quiet )

echo "building site (build_site.py — encrypts the corpus, takes a moment)"
rm -rf "$WWW_DIR/next"
mkdir -p "$WWW_DIR"
( cd "$REPO_DIR" && uv run scripts/build_site.py --out "$WWW_DIR/next" )

# --------------------------------------------------------------------- swap
# nginx serves $WWW_DIR/current (bind mount of the parent keeps the swap
# atomic — never mv the mounted dir itself).
rm -rf "$WWW_DIR/prev"
[ -d "$WWW_DIR/current" ] && mv "$WWW_DIR/current" "$WWW_DIR/prev"
mv "$WWW_DIR/next" "$WWW_DIR/current"

mkdir -p "$BUILD_STATE"
echo "$local_sha" > "$BUILD_STATE/built-sha"
echo "deployed $local_sha"
