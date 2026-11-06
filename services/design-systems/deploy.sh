#!/usr/bin/env bash
#
# deploy.sh — rebuild the design-systems docs site if the repo moved.
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
# SOURCE_REPO is the working clone at ~/dev/design-systems — the deploy only
# reads it and pulls it forward, it never commits or resets there. The build
# mirrors the repo's `make serve` (catalog build -> scorecard -> site.py):
#
#   git -C $SOURCE_REPO pull --ff-only   # best effort; a dirty or offline
#                                        # repo just builds its local HEAD
#   git -C $SOURCE_REPO lfs pull         # screenshots/fonts are LFS objects
#   python3 tools/catalog.py build       # gallery data.json + thumbs/
#   python3 tools/scorecard.py           # docs/scorecard/ pages
#   .venv/bin/python tools/site.py     # the docs site into site/
#   cp -a site -> www/next ; repoint current -> releases/<sha>
#
# Then the Next.js gallery app (web/, served by the designs-web user unit)
# is rebuilt when web/, tools/catalog.py or catalog.json changed since its
# last build, when no build is recorded, or on --force:
#
#   corepack pnpm@10.10.0 --dir web install --frozen-lockfile
#   corepack pnpm@10.10.0 --dir web build
#   systemctl --user restart designs-web   # only after a good build
#
# A box without that unit (or a macOS box, which has no systemd) skips the
# step with a log line. A failed web build leaves the docs release live and
# designs-web on its old build, and exits non-zero so deployd retries.
#
set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] || { echo "env file missing: $ENV_FILE (re-run setup.sh)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# systemd/launchd PATH won't include a brew/uv-local uv or a ~/.local/bin
# git-lfs — use the baked paths.
export PATH="$UV_BIN${GIT_LFS_BIN:+:$GIT_LFS_BIN}:$PATH"
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
  echo "design-systems repo missing at $REPO_DIR — leaving the last build up" >&2
  exit 1
fi

# Best effort: a working clone can be ahead of origin (push pending),
# behind it (pushed from elsewhere), or dirty — HEAD after this is what we
# build either way. The build reads the working tree, so uncommitted edits
# go live too — same as the repo's own `make serve`.
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

# ----------------------------------------------------------- gallery app
# The Next.js app in web/ runs from the clone as the designs-web user unit
# (`next start`), so a new commit only reaches it through a fresh
# `next build` and a restart. Its last good build is recorded apart from the
# docs site's (web-built-sha), so a failed web build is retried on the next
# run even though the docs release for that sha is already live.
WEB_UNIT="designs-web"
WEB_STATE="$BUILD_STATE/web-built-sha"
PNPM="pnpm@10.10.0"
web_needed=0
web_why=""
if [ "$(uname -s)" = "Darwin" ]; then
  web_why="macOS has no systemd user units"
elif ! systemctl --user cat "$WEB_UNIT" >/dev/null 2>&1; then
  web_why="$WEB_UNIT.service is not installed"
else
  web_built_sha="$(cat "$WEB_STATE" 2>/dev/null || echo none)"
  if [ "$FORCE" -eq 1 ]; then
    web_needed=1; web_why="--force"
  elif [ "$web_built_sha" = "none" ]; then
    web_needed=1; web_why="no previous web build recorded"
  elif ! git -C "$REPO_DIR" diff --quiet "$web_built_sha" "$local_sha" -- web tools/catalog.py catalog.json 2>/dev/null; then
    # Also true when git cannot compare (say the old sha is gone): rebuild.
    web_needed=1; web_why="web/, tools/catalog.py or catalog.json changed since $web_built_sha"
  else
    web_why="web/, tools/catalog.py and catalog.json unchanged since $web_built_sha"
  fi
fi

# Returns non-zero on a failed build; never restarts the unit then, so it
# keeps serving its previous build.
web_deploy() {
  if [ "$web_needed" -eq 0 ]; then
    echo "gallery app: skipped ($web_why)"
    return 0
  fi
  echo "gallery app: rebuilding ($web_why)"
  # node and corepack come from the Nix profile, which the systemd PATH
  # lacks. Prepended only here, so the docs build keeps its own python3.
  if ! ( cd "$REPO_DIR" \
      && export PATH="${NODE_BIN:-$HOME/.nix-profile/bin}:$PATH" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
      && corepack "$PNPM" --dir web install --frozen-lockfile \
      && corepack "$PNPM" --dir web build ); then
    echo "gallery app: BUILD FAILED at $local_sha; $WEB_UNIT not restarted (still on its previous build). The docs site deployed; failing so deployd retries." >&2
    return 1
  fi
  if ! systemctl --user restart "$WEB_UNIT"; then
    echo "gallery app: built $local_sha but 'systemctl --user restart $WEB_UNIT' failed; failing so deployd retries." >&2
    return 1
  fi
  mkdir -p "$BUILD_STATE"
  echo "$local_sha" > "$WEB_STATE"
  echo "gallery app: built and restarted $WEB_UNIT at $local_sha"
}

if [ "$local_sha" = "$built_sha" ] && [ -d "$WWW_DIR/current" ] && [ "$FORCE" -eq 0 ]; then
  if [ "$web_needed" -eq 0 ]; then
    echo "up to date at $built_sha"
    exit 0
  fi
  echo "docs site up to date at $built_sha"
  web_deploy || exit 1
  exit 0
fi

# --------------------------------------------------------------------- build
echo "deploying $local_sha (was: $built_sha)"

# Screenshots and fonts are Git LFS objects; a pointer file crashes the
# thumbnail step (Pillow can't parse ASCII). Materialise whatever new objects
# the pull brought down; a failed pull surfaces as a clear build error.
if git -C "$REPO_DIR" lfs version >/dev/null 2>&1; then
  git -C "$REPO_DIR" lfs pull 2>&1 | tail -3 || true
fi

# Deps: bootstrap .venv when it is missing, and re-sync whenever
# requirements.txt is newer than the last successful install — a changed
# pin must not leave the poller building with stale packages. The stamp is
# touched only after a successful install, so a failed one retries on the
# next run. `uv venv --allow-existing` no-ops on a venv that is already
# there (a bare `uv venv` refuses to recreate it).
VENV_STAMP="$REPO_DIR/.venv/.deploy-stamp"
if [ ! -x "$REPO_DIR/.venv/bin/python" ] || [ "$REPO_DIR/requirements.txt" -nt "$VENV_STAMP" ]; then
  echo "syncing the repo's .venv (uv)"
  ( cd "$REPO_DIR" && uv venv -q --allow-existing --python 3.13 .venv && uv pip install -q --python .venv/bin/python -r requirements.txt )
  touch "$VENV_STAMP"
fi

echo "building gallery data + docs site"
rm -rf "$WWW_DIR/next"
mkdir -p "$WWW_DIR"
( cd "$REPO_DIR" \
  && python3 tools/catalog.py build \
  && python3 tools/scorecard.py \
  && .venv/bin/python tools/site.py )
cp -a "$REPO_DIR/site" "$WWW_DIR/next"
# cp -a keeps the build's modes, and a generator writing 0600 (e.g. through
# tempfile.mkstemp) ships files the container's nginx uid cannot read —
# every request then answers 403. The release is meant to be served, so
# normalise: files readable, directories traversable, by any user.
chmod -R u+rwX,go+rX "$WWW_DIR/next"

# --------------------------------------------------------------------- swap
# nginx serves the `current` symlink inside the parent mount. Repoint it with
# one rename — moving directories in two steps would leave a gap where the
# root does not exist, and a deploy killed mid-swap would leave the site
# down. The previous release stays in releases/ for rollback.
mkdir -p "$WWW_DIR/releases"
prev_target="$(readlink "$WWW_DIR/current" 2>/dev/null || true)"
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

# After the swap: a failed web build must not hold back the docs site, but
# it must fail the run so deployd retries it.
web_deploy || exit 1
