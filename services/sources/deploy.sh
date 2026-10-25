#!/usr/bin/env bash
#
# deploy.sh — rebuild the encrypted sources site if the fetch clone moved.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead
# deployd (services/deployd) polls the remote and re-runs setup.sh when
# main moves — this script is the rebuild half of that run, and exits fast
# when the repo's HEAD hasn't moved. Also runnable by hand:
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
#   flock .git/sources-fetch.lock        # shared with fetch_all.sh: a build
#                                        # never reads a half-fetched tree
#   git -C $SOURCE_REPO pull --ff-only     # best effort; a dirty or offline
#                                          # repo just builds its local HEAD
#   uv sync --quiet                        # in the repo, like run_web.sh
#   uv run apps/web/build/build_site.py --out www/next   # scripts/ before 2026-10
#   repoint www/current -> releases/<sha>  # atomic: one rename over the old symlink

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
  echo "another deploy is running — skipping" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# ------------------------------------------------------------- pull/compare
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "sources repo missing at $REPO_DIR — leaving the last build up" >&2
  exit 1
fi

# A running fetch writes into this same checkout. fetch_all.sh holds an
# exclusive flock on .git/sources-fetch.lock for its whole run
# (docs/FETCHING.md), so take the same lock and hold it through the build:
# the site is only ever built from a tree no fetch is mid-write on. A routine
# fetch is ~2 min; wait up to SOURCES_DEPLOY_LOCK_WAIT (default 900s), then
# skip — the next timer tick retries. No fetch timer exists off this Linux
# box, so on macOS (no flock) the race cannot happen and no lock is taken.
if [ "$(uname -s)" = "Linux" ] && command -v flock >/dev/null 2>&1; then
  FETCH_LOCK="$REPO_DIR/$(git -C "$REPO_DIR" rev-parse --git-dir)/sources-fetch.lock"
  exec 8>"$FETCH_LOCK"
  if ! flock -w "${SOURCES_DEPLOY_LOCK_WAIT:-900}" 8; then
    echo "fetch_all.sh still holds $FETCH_LOCK — skipping this deploy" >&2
    exit 1
  fi
fi

# Best effort: a weekly-fetch clone can be ahead of origin (push pending),
# behind it (pushed from elsewhere), or dirty — HEAD after this is what we
# build either way. Only a committed state is ever read.
if ! git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
  echo "note: git pull --ff-only did not apply (dirty tree, offline, or diverged) — building local HEAD"
fi

local_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
# deployd asked for a specific remote sha (DEPLOY_SHA). If the pull could
# not bring it down, building HEAD would deploy something else and deployd
# would still record the requested sha as done — fail instead so it retries.
if [ -n "${DEPLOY_SHA:-}" ] \
    && ! git -C "$REPO_DIR" merge-base --is-ancestor "$DEPLOY_SHA" "$local_sha" 2>/dev/null; then
  echo "deployd asked for $DEPLOY_SHA but the clone is at $local_sha (pull failed or diverged) — failing so it retries" >&2
  exit 1
fi
built_sha="$(cat "$BUILD_STATE/built-sha" 2>/dev/null || echo none)"

if [ "$local_sha" = "$built_sha" ] && [ -d "$WWW_DIR/current" ] && [ "$FORCE" -eq 0 ]; then
  echo "up to date at $built_sha"
  exit 0
fi

# -------------------------------------------------------------------- build
echo "deploying $local_sha (was: $built_sha)"

echo "syncing deps (uv sync)"
( cd "$REPO_DIR" && uv sync --quiet )

# The sources repo moved the build from scripts/ to apps/web/build/ (2026-10).
# Pick whichever the pulled tree has, so a deploy on either side of that
# change builds.
BUILD_SCRIPT=apps/web/build/build_site.py
[ -f "$REPO_DIR/$BUILD_SCRIPT" ] || BUILD_SCRIPT=scripts/build_site.py

echo "building site ($BUILD_SCRIPT — encrypts the corpus, takes a moment)"
rm -rf "$WWW_DIR/next"
mkdir -p "$WWW_DIR"
( cd "$REPO_DIR" && uv run "$BUILD_SCRIPT" --out "$WWW_DIR/next" )

# --------------------------------------------------------------------- swap
# nginx serves the `current` symlink inside the parent mount. Repoint it with
# one rename — moving directories in two steps would leave a gap where the
# root does not exist, and a deploy killed mid-swap would leave the site
# down. The previous release stays in releases/ for rollback.
mkdir -p "$WWW_DIR/releases"
# Migrate the original layout where `current` was the build directory
# itself: park it under releases/ first so the symlink lands cleanly.
if [ -d "$WWW_DIR/current" ] && [ ! -L "$WWW_DIR/current" ]; then
  legacy="$built_sha"; [ "$legacy" = "none" ] && legacy="legacy"
  rm -rf "$WWW_DIR/releases/$legacy"
  mv "$WWW_DIR/current" "$WWW_DIR/releases/$legacy"
  prev_target="releases/$legacy"
else
  prev_target="$(readlink "$WWW_DIR/current" 2>/dev/null || true)"
fi
target="$local_sha"
if [ "$prev_target" = "releases/$local_sha" ]; then
  # A --force rebuild of the live sha can't reuse its directory name:
  # deleting or moving the release `current` points at would leave the site
  # serving a missing root (a window where requests 404, and a kill mid-way
  # leaves `current` dangling). Build beside it under a suffixed name; the
  # old build stays on as the previous release.
  target="$local_sha.rebuild-$(date +%s)"
fi
rm -rf "$WWW_DIR/releases/$target"
mv "$WWW_DIR/next" "$WWW_DIR/releases/$target"
ln -sfn "releases/$target" "$WWW_DIR/current.new"
if [ "$(uname -s)" = "Darwin" ]; then
  mv -hf "$WWW_DIR/current.new" "$WWW_DIR/current"   # BSD mv: no -T
else
  mv -Tf "$WWW_DIR/current.new" "$WWW_DIR/current"   # one rename over the old symlink
fi

# Keep current and previous releases; drop anything older.
for d in "$WWW_DIR/releases"/*/; do
  name="$(basename "$d")"
  [ "$name" = "$target" ] || [ "releases/$name" = "$prev_target" ] || rm -rf "$d"
done

mkdir -p "$BUILD_STATE"
echo "$local_sha" > "$BUILD_STATE/built-sha"
echo "deployed $local_sha"
