#!/usr/bin/env bash
#
# Tests for kaichenpedia/setup.sh + deploy.sh.
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
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT REPO_URL BRANCH POLL_SECONDS STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the installed poller script directly (as the timer would).
run_poll() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/kaichenpedia/bin/deploy.sh" "$@" 2>&1)"
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

test_preflight_old_node() {
  echo "• preflight fails when node is older than 22"
  setup
  echo "v18.17.0" > "$STATE_DIR/node_version"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "Node.js >= 22"
  teardown
}

test_preflight_git_auth() {
  echo "• preflight fails when the private repo is not readable non-interactively"
  setup
  touch "$STATE_DIR/git_auth_fail"
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "points at gh auth"  out_has "gh auth"
  check "wrote no .env"      [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path (clone, build, container, poller, serve)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has repo URL"           env_has "REPO_URL=https://github.com/c-wenlong/kaichenpedia.git"
  check ".env has poll interval"      env_has "POLL_SECONDS=86400"
  check ".env has public URL"         env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8091/"
  check "deploy script installed"     [ -x "$HOME/services/kaichenpedia/bin/deploy.sh" ]
  check "env path baked into script"  grep -q "$SVC/.env" "$HOME/services/kaichenpedia/bin/deploy.sh"
  check "cloned the repo"             calls_have "git clone --branch main"
  check "synced wiki -> site"         calls_have "sync_wiki_to_site.py"
  check "installed deps (npm ci)"     calls_have "npm ci"
  check "built with quartz"           calls_have "npx quartz build"
  check "site swapped into current"   [ -f "$HOME/services/kaichenpedia/www/current/index.html" ]
  check "recorded built sha"          grep -qx aaa1111 "$HOME/services/kaichenpedia/state/built-sha"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  if [ "$OS" = "Linux" ]; then
    check "timer unit written"        [ -f "$HOME/.config/systemd/user/kaichenpedia-deploy.timer" ]
    check "timer enabled"             calls_have "systemctl --user enable --now kaichenpedia-deploy.timer"
    check "lingering enabled"         calls_have "loginctl enable-linger"
  else
    check "launch agent written"      [ -f "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
  fi
  check "served on tailscale :8091"   calls_have "tailscale serve --bg --https=8091 http://127.0.0.1:8091"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8091"
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
  check "no rebuild"              no_call "npx quartz build"
  check "no npm ci"               no_call "npm ci"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_push_triggers_redeploy() {
  echo "• poller: new commit on origin -> rebuild and swap (npm ci skipped)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the new sha"     out_has "deploying bbb2222"
  check "rebuilt with quartz"     calls_have "npx quartz build"
  check "npm ci skipped"          no_call "npm ci"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/kaichenpedia/state/built-sha"
  check "previous build kept"     [ -f "$HOME/services/kaichenpedia/www/prev/index.html" ]
  check "current build swapped"   [ -f "$HOME/services/kaichenpedia/www/current/index.html" ]
  teardown
}

test_poll_lock() {
  echo "• poller: concurrent run skips cleanly while the lock is held"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/kaichenpedia/.deploy.lock"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "another deploy is running"
  check "touched no git"      no_call "git fetch"
  rmdir "$HOME/services/kaichenpedia/.deploy.lock"
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
  check "eventually published" calls_have "tailscale serve --bg --https=8091"
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
  local ts port url svc_home
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="$(sed -n 's|^PUBLIC_URL=\(.*\)/$|\1|p' "$SERVICE_DIR/.env")"
  svc_home="$(sed -n 's/^SERVICE_HOME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "container running"        sh -c "docker inspect -f '{{.State.Status}}' kaichenpedia | grep -qx running"
  live_check "local index responds"     curl -fsS "http://127.0.0.1:$port/"
  live_check "extensionless URLs work"  curl -fsS "http://127.0.0.1:$port/index"
  live_check "no wildcard listener"     no_external_listener "$port"
  live_check "built sha matches origin" sh -c "[ \"\$(git -C '$svc_home/repo' rev-parse origin/main)\" = \"\$(cat '$svc_home/state/built-sha')\" ]"
  if [ "$OS" = "Linux" ]; then
    live_check "deploy timer active"    sh -c "systemctl --user is-active kaichenpedia-deploy.timer | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded"    sh -c "launchctl print gui/$(id -u)/com.kaichenpedia.deploy"
  fi
  live_check "serve maps :$port"        sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"   curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_old_node
test_preflight_git_auth
test_fresh_deploy
test_idempotent_rerun
test_push_triggers_redeploy
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
