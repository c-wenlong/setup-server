#!/usr/bin/env bash
#
# deploy.sh — pull the sources repo from GitHub and rebuild the encrypted
# site if origin/BRANCH moved.
#
# The server is tailnet-only, so GitHub webhooks can't reach it; instead
# deployd (services/deployd) polls the remote and re-runs setup.sh when
# main moves — this script is the rebuild half of that run, and exits fast
# when origin/BRANCH hasn't moved. Also runnable by hand:
#
#   deploy.sh            # build only if origin/BRANCH is new
#   deploy.sh --force    # rebuild even without new commits
#
# Installed by setup.sh into $SERVICE_HOME/bin/ (ENV_FILE is baked in at
# install time — edit the copy in the setup-server repo, then re-run setup.sh).
#
# The build runs in a machine-managed deploy clone at $SERVICE_HOME/repo,
# never in SOURCE_REPO (~/dev/sources, the fetch
# clone). A killed fetch leaves that tree dirty, and a dirty tree used to
# refuse `git pull --ff-only` and block every deploy (issue #138); here it
# cannot, because no fetch job ever writes this clone. That is also why
# this script takes no sources-fetch.lock: there is no half-fetched tree
# to protect the build against. The clone is hard-reset to origin/BRANCH
# each deploy — it is a build input, not a working copy. The one thing
# still read from the fetch clone is data/jobs/jobs.db, read-only, via the
# symlink below.
#
# Build pipeline:
#   git clone (first run only) / git fetch origin BRANCH
#   verify DEPLOY_SHA is an ancestor of origin/BRANCH (deployd retries
#     rather than deploy the wrong sha)
#   git reset --hard origin/BRANCH
#   link data/jobs/jobs.db from the fetch clone (or drop a stale link)
#   uv sync --quiet                        # in the deploy clone
#   uv run apps/web/build/build_site.py --out www/next   # scripts/ before 2026-10
#   repoint www/current -> releases/<sha>  # atomic: one rename over the old symlink

set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# systemd/launchd PATH won't include a brew/uv-local uv — use the baked path.
export PATH="$UV_BIN:$PATH"
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

# An .env written before the managed clone has no REPO_URL — take the
# fetch clone's origin (its auth already works on this box), else the
# canonical remote. BRANCH is in every .env setup.sh ever wrote.
if [ -z "${REPO_URL:-}" ] && [ -n "${SOURCE_REPO:-}" ]; then
  REPO_URL="$(git -C "$SOURCE_REPO" remote get-url origin 2>/dev/null || true)"
fi
REPO_URL="${REPO_URL:-https://github.com/c-wenlong/sources}"
BRANCH="${BRANCH:-main}"

# ------------------------------------------------------------- fetch/compare
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "cloning $REPO_URL (branch $BRANCH) -> $REPO_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# The clone keeps whichever URL it was cloned with; repoint origin at the
# resolved REPO_URL every run so editing .env actually moves the remote.
git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
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

# build_site.py ships the Jobs page only when data/jobs/jobs.db exists in
# the repo it runs in. That file is gitignored, and the daily scrape writes
# it only in the fetch clone ($SOURCE_REPO), so link it into the deploy
# clone. The build opens it read-only, so a symlink is safe. When the
# fetch clone has no jobs.db, remove any stale link so the build ships
# without Jobs rather than a stale page.
JOBS_DB="$REPO_DIR/data/jobs/jobs.db"
if [ -n "${SOURCE_REPO:-}" ] && [ -f "$SOURCE_REPO/data/jobs/jobs.db" ]; then
  # setup.sh saves SOURCE_REPO as given; a relative target would resolve
  # under data/jobs/ inside the deploy clone, so pin the absolute path.
  jobs_dir="$(cd "$SOURCE_REPO/data/jobs" && pwd)"
  mkdir -p "$REPO_DIR/data/jobs"
  ln -sfn "$jobs_dir/jobs.db" "$JOBS_DB"
  echo "jobs.db linked from the fetch clone"
else
  rm -f "$JOBS_DB"
  echo "no jobs.db in the fetch clone: building without Jobs"
fi

echo "syncing deps (uv sync)"
( cd "$REPO_DIR" && uv sync --quiet )

# The sources repo moved the build from scripts/ to apps/web/build/ (2026-10).
# Pick whichever the cloned tree has, so a deploy on either side of that
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
target="$remote_sha"
if [ "$prev_target" = "releases/$remote_sha" ]; then
  # A --force rebuild of the live sha can't reuse its directory name:
  # deleting or moving the release `current` points at would leave the site
  # serving a missing root (a window where requests 404, and a kill mid-way
  # leaves `current` dangling). Build beside it under a suffixed name; the
  # old build stays on as the previous release.
  target="$remote_sha.rebuild-$(date +%s)"
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
echo "$remote_sha" > "$BUILD_STATE/built-sha"
echo "deployed $remote_sha"
