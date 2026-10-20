#!/usr/bin/env bash
#
# Tests for sources/setup.sh + deploy.sh.
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

  # A fake fetch clone: .git/ + scripts/build_site.py is all setup.sh checks.
  export SOURCE_REPO="$SANDBOX/repo"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/scripts"
  echo "# build stub" > "$SOURCE_REPO/scripts/build_site.py"

  # A passphrase with a space exercises the %q quoting in the written .env.
  export SITE_PASSPHRASE="test pass phrase"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT SOURCE_REPO BRANCH POLL_SECONDS SITE_PASSPHRASE STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the installed poller script directly (as the timer would).
run_poll() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/sources/bin/deploy.sh" "$@" 2>&1)"
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
  echo "• preflight fails when the sources clone is not where SOURCE_REPO points"
  setup
  export SOURCE_REPO="$SANDBOX/not-here"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "Sources repo not found"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_passphrase_missing() {
  echo "• preflight fails on first run without SITE_PASSPHRASE"
  setup
  unset SITE_PASSPHRASE
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the var"     out_has "SITE_PASSPHRASE is required"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
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
  check ".env has passphrase"         env_has "^SITE_PASSPHRASE="
  check "passphrase round-trips"      sh -c '. "$1" >/dev/null 2>&1 && [ "$SITE_PASSPHRASE" = "test pass phrase" ]' _ "$SVC/.env"
  check ".env has public URL"         env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8098/"
  check ".env is owner-only"          sh -c '[ "$(stat -c %a "$0" 2>/dev/null || stat -f %Lp "$0")" = 600 ]' "$SVC/.env"
  check "deploy script installed"     [ -x "$HOME/services/sources/bin/deploy.sh" ]
  check "env path baked into script"  grep -q "$SVC/.env" "$HOME/services/sources/bin/deploy.sh"
  check "synced deps (uv sync)"       calls_have "uv sync"
  check "built the site"              calls_have "uv run scripts/build_site.py --out"
  check "site swapped into current"   [ -f "$HOME/services/sources/www/current/index.html" ]
  check "current is a release link"   sh -c '[ "$(readlink "$1")" = releases/aaa1111 ]' _ "$HOME/services/sources/www/current"
  check "recorded built sha"          grep -qx aaa1111 "$HOME/services/sources/state/built-sha"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  if [ "$OS" = "Linux" ]; then
    check "timer unit written"        [ -f "$HOME/.config/systemd/user/sources-deploy.timer" ]
    check "timer enabled"             calls_have "systemctl --user enable --now sources-deploy.timer"
    check "lingering enabled"         calls_have "loginctl enable-linger"
  else
    check "launch agent written"      [ -f "$HOME/Library/LaunchAgents/com.sources.deploy.plist" ]
  fi
  check "served on tailscale :8098"   calls_have "tailscale serve --bg --https=8098 http://127.0.0.1:8098"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8098"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, build skipped when nothing changed, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "# CUSTOM-MARK do-not-clobber" >> "$SVC/.env"
  unset SITE_PASSPHRASE    # re-run must not need it — the .env supplies it
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "edited .env preserved"   env_has "CUSTOM-MARK"
  check "reports up to date"      out_has "up to date at aaa1111"
  check "no rebuild"              no_call "uv run scripts/build_site.py"
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
  check "rebuilt the site"        calls_have "uv run scripts/build_site.py"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/sources/state/built-sha"
  check "previous release kept"   [ -d "$HOME/services/sources/www/releases/aaa1111" ]
  check "current repointed"       sh -c '[ "$(readlink "$1")" = releases/bbb2222 ]' _ "$HOME/services/sources/www/current"
  check "current build swapped"   [ -f "$HOME/services/sources/www/current/index.html" ]
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
  check "rebuilt"                     calls_have "uv run scripts/build_site.py"
  check "current resolves"            [ -f "$HOME/services/sources/www/current/index.html" ]
  check "current is the new build"    sh -c 'readlink "$1" | grep -q "aaa1111\.rebuild-"' _ "$HOME/services/sources/www/current"
  check "two releases kept"           sh -c '[ "$(ls -d "$1"/releases/*/ | wc -l)" -eq 2 ]' _ "$HOME/services/sources/www"
  check "old build kept as previous"  [ -d "$HOME/services/sources/www/releases/aaa1111" ]
  teardown
}

test_poll_lock() {
  echo "• poller: concurrent run skips cleanly while the lock is held"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/sources/.deploy.lock"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "another deploy is running"
  check "touched no git"      no_call "git -C .* rev-parse"
  rmdir "$HOME/services/sources/.deploy.lock"
  teardown
}

test_fetch_lock() {
  echo "• poller: skips while a fetch holds the shared repo lock"
  [ "$OS" = "Linux" ] || { green "    ✓ (skipped on macOS — no flock, no fetch timer)"; PASS=$((PASS + 1)); return; }
  command -v flock >/dev/null || { green "    ✓ (skipped — no flock binary)"; PASS=$((PASS + 1)); return; }
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  export SOURCES_DEPLOY_LOCK_WAIT=1
  ( exec 9>"$SOURCE_REPO/.git/sources-fetch.lock"; flock -x 9; sleep 30 ) &
  holder=$!
  sleep 0.2   # let the holder take the lock before the poller tries
  : > "$CALLS_LOG"
  run_poll
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "still holds .*sources-fetch.lock"
  check "did not rebuild"     no_call "uv run scripts/build_site.py"
  unset SOURCES_DEPLOY_LOCK_WAIT
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
  check "eventually published" calls_have "tailscale serve --bg --https=8098"
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
  live_check "container running"        sh -c "docker inspect -f '{{.State.Status}}' sources | grep -qx running"
  live_check "local index responds"     curl -fsS "http://127.0.0.1:$port/"
  live_check "app.js responds"          curl -fsS "http://127.0.0.1:$port/app.js"
  live_check "catalog blob responds"    sh -c "curl -fsS -o /dev/null 'http://127.0.0.1:$port/d/catalog.bin'"
  live_check "no wildcard listener"     no_external_listener "$port"
  live_check "built sha matches repo"   sh -c "[ \"\$(git -C '$repo' rev-parse HEAD)\" = \"\$(cat '$svc_home/state/built-sha')\" ]"
  if [ "$OS" = "Linux" ]; then
    live_check "deploy timer active"    sh -c "systemctl --user is-active sources-deploy.timer | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded"    sh -c "launchctl print gui/$(id -u)/com.sources.deploy"
  fi
  live_check "serve maps :$port"        sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"   curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_repo_missing
test_preflight_passphrase_missing
test_fresh_deploy
test_idempotent_rerun
test_push_triggers_redeploy
test_force_rebuild_same_sha
test_poll_lock
test_fetch_lock
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
