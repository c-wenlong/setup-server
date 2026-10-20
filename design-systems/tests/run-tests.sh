#!/usr/bin/env bash
#
# Tests for design-systems/setup.sh + deploy.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"

  # A fake working clone: .git/ + tools/catalog.py is what setup.sh checks;
  # systems/ exists so the LFS pointer scan has somewhere to look, and the
  # stub uv/zensical/python3 fill in .venv, docs/ and site/ at build time.
  export SOURCE_REPO="$SANDBOX/repo"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/tools" "$SOURCE_REPO/systems"
  echo "# catalog stub" > "$SOURCE_REPO/tools/catalog.py"
  echo "zensical==0.0.0" > "$SOURCE_REPO/requirements.txt"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT SOURCE_REPO BRANCH POLL_SECONDS STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the installed poller script directly (as the timer would).
run_poll() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/design-systems/bin/deploy.sh" "$@" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

out_has()    { grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# ----------------------------------------------------------------- tests
test_preflight_docker_perms() {
  echo "• preflight fails when user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  check "wrote no .env"  [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Tailscale is not up"
  teardown
}

test_preflight_repo_missing() {
  echo "• preflight fails when the clone is not where SOURCE_REPO points"
  setup
  export SOURCE_REPO="$SANDBOX/not-here"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "design-systems repo not found"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_wrong_repo() {
  echo "• preflight fails when the clone is not design-systems"
  setup
  mkdir -p "$SANDBOX/other/.git"
  export SOURCE_REPO="$SANDBOX/other"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "does not look like the design-systems repo"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_lfs_pointers_fixed() {
  echo "• preflight materialises LFS pointers via git lfs pull"
  setup
  mkdir -p "$SOURCE_REPO/systems/foo/screenshots"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:deadbeef\nsize 12345\n' \
    > "$SOURCE_REPO/systems/foo/screenshots/p.png"
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "ran git lfs pull"    calls_have "git -C .* lfs pull"
  check "pointer replaced"    sh -c '! head -c 9 "$0" | grep -q "version h"' "$SOURCE_REPO/systems/foo/screenshots/p.png"
  teardown
}

test_lfs_pointers_unfixable() {
  echo "• preflight fails when LFS pointers cannot be materialised"
  setup
  mkdir -p "$SOURCE_REPO/systems/foo/screenshots"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:deadbeef\nsize 12345\n' \
    > "$SOURCE_REPO/systems/foo/screenshots/p.png"
  touch "$STATE_DIR/lfs_broken"
  run_deploy
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "names the problem"   out_has "Git LFS pointer files remain"
  check "wrote no .env"       [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path (build, container, poller, serve)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has repo path"          env_has "SOURCE_REPO=$SOURCE_REPO"
  check ".env has poll interval"      env_has "POLL_SECONDS=86400"
  check ".env has public URL"         env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8108/"
  check ".env is owner-only"          sh -c '[ "$(stat -c %a "$0" 2>/dev/null || stat -f %Lp "$0")" = 600 ]' "$SVC/.env"
  check "deploy script installed"     [ -x "$HOME/services/design-systems/bin/deploy.sh" ]
  check "env path baked into script"  grep -q "$SVC/.env" "$HOME/services/design-systems/bin/deploy.sh"
  check "venv created (uv venv)"      calls_have "uv venv"
  check "deps installed (uv pip)"     calls_have "uv pip install"
  check "gallery data built"          calls_have "python3 tools/catalog.py build"
  check "scorecard built"             calls_have "python3 tools/scorecard.py"
  check "docs site built"             calls_have "zensical build"
  check "site swapped into current"   [ -f "$HOME/services/design-systems/www/current/index.html" ]
  check "gallery page in release"     [ -f "$HOME/services/design-systems/www/current/gallery/index.html" ]
  check "current is a release link"   sh -c '[ "$(readlink "$1")" = releases/aaa1111 ]' _ "$HOME/services/design-systems/www/current"
  check "recorded built sha"          grep -qx aaa1111 "$HOME/services/design-systems/state/built-sha"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  if [ "$OS" = "Linux" ]; then
    check "timer unit written"        [ -f "$HOME/.config/systemd/user/design-systems-deploy.timer" ]
    check "timer enabled"             calls_have "systemctl --user enable --now design-systems-deploy.timer"
    check "lingering enabled"         calls_have "loginctl enable-linger"
  else
    check "launch agent written"      [ -f "$HOME/Library/LaunchAgents/com.design-systems.deploy.plist" ]
  fi
  check "served on tailscale :8108"   calls_have "tailscale serve --bg --https=8108 http://127.0.0.1:8108"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8108/gallery/"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, build skipped when nothing changed, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "# CUSTOM-MARK do-not-clobber" >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "edited .env preserved"   env_has "CUSTOM-MARK"
  check "reports up to date"      out_has "up to date at aaa1111"
  check "no rebuild"              no_call "zensical build"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_push_triggers_redeploy() {
  echo "• poller: new commit on the repo -> rebuild and swap"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/local_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the new sha"     out_has "deploying bbb2222"
  check "rebuilt the site"        calls_have "zensical build"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/design-systems/state/built-sha"
  check "previous release kept"   [ -d "$HOME/services/design-systems/www/releases/aaa1111" ]
  check "current repointed"       sh -c '[ "$(readlink "$1")" = releases/bbb2222 ]' _ "$HOME/services/design-systems/www/current"
  check "current build swapped"   [ -f "$HOME/services/design-systems/www/current/index.html" ]
  teardown
}

test_force_rebuild_same_sha() {
  echo "• --force rebuild of the live sha: current never dangles, old build stays previous"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  run_poll --force
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "rebuilt"                     calls_have "zensical build"
  check "current resolves"            [ -f "$HOME/services/design-systems/www/current/index.html" ]
  check "current is the new build"    sh -c 'readlink "$1" | grep -q "aaa1111\.rebuild-"' _ "$HOME/services/design-systems/www/current"
  check "two releases kept"           sh -c '[ "$(ls -d "$1"/releases/*/ | wc -l)" -eq 2 ]' _ "$HOME/services/design-systems/www"
  check "old build kept as previous"  [ -d "$HOME/services/design-systems/www/releases/aaa1111" ]
  teardown
}

test_deps_resync_on_requirements_change() {
  echo "• poller re-syncs .venv when requirements.txt is newer than the last install"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "deps installed once"   calls_have "uv pip install"
  : > "$CALLS_LOG"
  # requirements.txt newer than .venv/.deploy-stamp -> reinstall on a rebuild
  touch -t 209901010000 "$SOURCE_REPO/requirements.txt"
  run_poll --force
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "deps re-installed"   calls_have "uv pip install"
  teardown
}

test_spaced_repo_path() {
  echo "• SOURCE_REPO with spaces: .env stays shell-parseable end to end"
  setup
  touch "$STATE_DIR/operator"
  export SOURCE_REPO="$SANDBOX/repo with space"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/tools" "$SOURCE_REPO/systems"
  echo "# catalog stub" > "$SOURCE_REPO/tools/catalog.py"
  echo "x" > "$SOURCE_REPO/requirements.txt"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "path in .env"        env_has "SOURCE_REPO="
  check "built the site"      calls_have "zensical build"
  check "site swapped in"     [ -f "$HOME/services/design-systems/www/current/index.html" ]
  teardown
}

test_poll_lock() {
  echo "• poller: concurrent run skips cleanly while the lock is held"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/design-systems/.deploy.lock"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "another deploy is running"
  check "touched no git"      no_call "git -C .* rev-parse"
  rmdir "$HOME/services/design-systems/.deploy.lock"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT override (HTTPS follows local by default)"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9999
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "served on :9999 -> 9999" calls_have "tailscale serve --bg --https=9999 http://127.0.0.1:9999"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8108"
  teardown
}

# ------------------------------------------------------------ live suite
live_check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

no_external_listener() {
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | awk -v p=":$port" '$4 ~ p"$" {print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):')
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):')
  fi
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port url svc_home repo
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="$(sed -n 's|^PUBLIC_URL=\(.*\)/$|\1|p' "$SERVICE_DIR/.env")"
  svc_home="$(sed -n 's/^SERVICE_HOME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  repo="$(sed -n 's/^SOURCE_REPO=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "container running"        sh -c "docker inspect -f '{{.State.Status}}' design-systems | grep -qx running"
  live_check "gallery responds"         curl -fsS "http://127.0.0.1:$port/gallery/"
  live_check "gallery data responds"    sh -c "curl -fsS 'http://127.0.0.1:$port/gallery/data.json' | grep -q systems"
  live_check "repo path responds"       sh -c "curl -fsS 'http://127.0.0.1:$port/catalog.json' | grep -q systems"
  live_check "no wildcard listener"     no_external_listener "$port"
  live_check "built sha matches repo"   sh -c "[ \"\$(git -C '$repo' rev-parse HEAD)\" = \"\$(cat '$svc_home/state/built-sha')\" ]"
  if [ "$OS" = "Linux" ]; then
    live_check "deploy timer active"    sh -c "systemctl --user is-active design-systems-deploy.timer | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded"    sh -c "launchctl print gui/$(id -u)/com.design-systems.deploy"
  fi
  live_check "serve maps :$port"        sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"   curl -fsS -o /dev/null --max-time 30 "$url/gallery/"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_repo_missing
test_preflight_wrong_repo
test_lfs_pointers_fixed
test_lfs_pointers_unfixable
test_fresh_deploy
test_idempotent_rerun
test_push_triggers_redeploy
test_force_rebuild_same_sha
test_deps_resync_on_requirements_change
test_spaced_repo_path
test_poll_lock
test_port_override
test_operator_escalation

if [ "${1:-}" = "--live" ]; then
  echo
  test_live
fi

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL of $((PASS + FAIL)) checks failed."
  exit 1
fi
