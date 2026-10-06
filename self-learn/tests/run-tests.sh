#!/usr/bin/env bash
#
# Tests for self-learn/setup.sh + deploy.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Gotcha: the mocked tests override $HOME — teardown always restores it, or
# the live checks would read the deleted sandbox.

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
  unset FAKE_UID LOCAL_PORT HTTPS_PORT PG_PORT REPO_URL BRANCH POLL_SECONDS \
    SKIP_SEED OWNER_PASSWORD AUTH_SECRET STATE_DIR CALLS_LOG
}

run_deploy() {
  # %s\n so a piped Enter always reaches `read` — '%s' alone of an empty arg
  # gives read instant EOF, which dies under set -e.
  OUT="$(printf '%s\n' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the installed poller script directly (as the timer would).
run_poll() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/self-learn/bin/deploy.sh" "$@" 2>&1)"
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
REPO_DIR()   { printf '%s' "$HOME/services/self-learn/repo"; }

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
  echo "• preflight fails when node is older than 22.22.2"
  setup
  echo "v22.21.9" > "$STATE_DIR/node_version"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "Node.js >= 22.22.2"
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

test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "says why"          out_has "not root"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path (clone, ci, db, seed, units, timers, serve)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env has repo URL"             env_has "REPO_URL=https://github.com/c-wenlong/self-learn.git"
  check ".env has generated DB URL"     grep -qE '^DATABASE_URL=postgres://catalog:[0-9a-f]+@127.0.0.1:5432/self_learn$' "$SVC/.env"
  check ".env has owner password"       grep -qE '^OWNER_PASSWORD=.+$' "$SVC/.env"
  check ".env has auth secret"          grep -qE '^AUTH_SECRET=.{32,}$' "$SVC/.env"
  check ".env mode is 600"              sh -c "[ \"$(stat -c %a "$SVC/.env" 2>/dev/null || stat -f %Lp "$SVC/.env")\" = 600 ]"
  check "deploy script installed"       [ -x "$HOME/services/self-learn/bin/deploy.sh" ]
  check "env path baked into script"    grep -q "$SVC/.env" "$HOME/services/self-learn/bin/deploy.sh"
  check "cloned the repo"               calls_have "git clone --branch main"
  check "installed deps (npm ci)"       calls_have "npm ci"
  check "web env written"               grep -q "^DATABASE_URL=postgres://catalog:" "$(REPO_DIR)/apps/web/.env.local"
  check "catalog env written"           grep -q "^SELF_LEARN_HOME=" "$(REPO_DIR)/services/catalog/.env"
  check "compose up invoked"            [ -f "$STATE_DIR/compose_up" ]
  check "catalog migrated"              calls_have "npm run catalog -- migrate"
  check "seed imported"                 calls_have "npm run catalog -- import seed"
  check "six flips run"                 sh -c '[ "$(grep -c "npm run catalog -- flip" "$CALLS_LOG")" -eq 6 ]'
  check "blob root claimed"             calls_have "npm run catalog -- blob audit --fix"
  check "bootstrap marker written"      [ -f "$HOME/services/self-learn/state/db-bootstrapped" ]
  check "built (next build)"            calls_have "npm run build"
  check "built sha recorded"            grep -qx aaa1111 "$HOME/services/self-learn/state/built-sha"
  if [ "$OS" = "Linux" ]; then
    check "app unit written"            [ -f "$HOME/.config/systemd/user/self-learn.service" ]
    check "app binds loopback+port"     grep -q -- "-p 8107 -H 127.0.0.1" "$HOME/.config/systemd/user/self-learn.service"
    check "deploy timer written"        [ -f "$HOME/.config/systemd/user/self-learn-deploy.timer" ]
    check "export timer written"        [ -f "$HOME/.config/systemd/user/self-learn-export.timer" ]
    check "app restarted"               calls_have "systemctl --user restart self-learn"
    check "deploy timer enabled"        calls_have "systemctl --user enable --now self-learn-deploy.timer"
    check "export timer enabled"        calls_have "systemctl --user enable --now self-learn-export.timer"
    check "lingering enabled"           calls_have "loginctl enable-linger"
  else
    check "web agent written"           [ -f "$HOME/Library/LaunchAgents/com.self-learn.web.plist" ]
    check "deploy agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist" ]
    check "export agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.export.plist" ]
    check "web agent loaded"            calls_have "launchctl bootstrap gui/.*/com.self-learn.web"
  fi
  check "served on tailscale :8107"     calls_have "tailscale serve --bg --https=8107 http://127.0.0.1:8107"
  check "prints final URL"              out_has "https://test-host.tailfake.ts.net:8107"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no rebuild when nothing changed, no re-seed, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "# CUSTOM-MARK do-not-clobber" >> "$SVC/.env"
  owner_pass="$(sed -n 's/^OWNER_PASSWORD=\(.*\)$/\1/p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "edited .env preserved"   env_has "CUSTOM-MARK"
  check "password not rotated"    env_has "OWNER_PASSWORD=$owner_pass"
  check "reports up to date"      out_has "up to date at aaa1111"
  check "no rebuild"              no_call "npm run build"
  check "no npm ci"               no_call "npm ci"
  check "no re-seed"              no_call "npm run catalog -- import"
  check "no git clone"            no_call "git clone"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_push_triggers_redeploy() {
  echo "• poller: new commit -> stop, pull, migrate, build, start (npm ci skipped)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the new sha"     out_has "deploying bbb2222"
  check "app stopped first"       calls_have "systemctl --user stop self-learn.service"
  check "rebuilt"                 calls_have "npm run build"
  check "catalog migrated"        calls_have "npm run catalog -- migrate"
  check "npm ci skipped"          no_call "npm ci"
  check "app started again"       calls_have "systemctl --user start self-learn.service"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/self-learn/state/built-sha"
  teardown
}

test_lockfile_change_triggers_ci() {
  echo "• poller: lockfile change on the new commit -> npm ci runs"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "fake-lockfile-v2" > "$(REPO_DIR)/package-lock.json"
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "npm ci ran"          calls_have "npm ci"
  check "rebuilt"             calls_have "npm run build"
  teardown
}

test_stopped_app_stays_stopped() {
  echo "• poller: a deliberately stopped app is updated but left stopped"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  rm -f "$STATE_DIR/web_active"
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "rebuilt"             calls_have "npm run build"
  check "no stop attempted"   no_call "systemctl --user stop self-learn"
  check "not restarted"       no_call "systemctl --user start self-learn"
  check "says it was left"    out_has "left stopped"
  teardown
}

test_poll_lock() {
  echo "• poller: concurrent run skips cleanly while the lock is held"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/self-learn/.deploy.lock"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "another deploy is running"
  check "touched no git"      no_call "git fetch"
  rmdir "$HOME/services/self-learn/.deploy.lock"
  teardown
}

test_skip_seed() {
  echo "• SKIP_SEED=1: catalog left empty for a dump restore, no import/flips"
  setup
  touch "$STATE_DIR/operator"
  export SKIP_SEED=1
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "no seed import"          no_call "npm run catalog -- import"
  check "no flips"                no_call "npm run catalog -- flip"
  check "still migrated"          calls_have "npm run catalog -- migrate"
  check "marker says skipped"     grep -qx skipped "$HOME/services/self-learn/state/db-bootstrapped"
  check "warns about restore"     out_has "laptop"
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
  if [ "$OS" = "Linux" ]; then
    check "unit uses :9999"       grep -q -- "-p 9999" "$HOME/.config/systemd/user/self-learn.service"
  fi
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8107"
  teardown
}

test_serve_approval_pause() {
  echo "• serve approval URL: pauses for Enter, then retries and succeeds"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "explained the pause"   out_has "approval URL"
  check "serve retried to 3"    sh -c '[ "$(grep -c "tailscale serve" "$CALLS_LOG")" -eq 3 ]'
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
  local ts port pg_port url svc_home
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  pg_port="$(sed -n 's/^PG_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="$(sed -n 's|^PUBLIC_URL=\(.*\)$|\1|p' "$SERVICE_DIR/.env")"
  svc_home="$(sed -n 's/^SERVICE_HOME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "postgres container running"  sh -c "docker inspect -f '{{.State.Status}}' self-learn-db | grep -qx running"
  live_check "app responds locally"        curl -fsS "http://127.0.0.1:$port/"
  live_check "no wildcard app listener"    no_external_listener "$port"
  live_check "no wildcard pg listener"     no_external_listener "$pg_port"
  live_check "built sha matches origin"    sh -c "[ \"\$(git -C '$svc_home/repo' rev-parse origin/main)\" = \"\$(cat '$svc_home/state/built-sha')\" ]"
  live_check "web .env.local exists"       test -f "$svc_home/repo/apps/web/.env.local"
  live_check "catalog .env exists"         test -f "$svc_home/repo/services/catalog/.env"
  live_check "bootstrap marker exists"     test -f "$svc_home/state/db-bootstrapped"
  if [ "$OS" = "Linux" ]; then
    live_check "app unit active"           sh -c "systemctl --user is-active self-learn.service | grep -qx active"
    live_check "app unit enabled"          sh -c "systemctl --user is-enabled self-learn.service | grep -qx enabled"
    live_check "deploy timer active"       sh -c "systemctl --user is-active self-learn-deploy.timer | grep -qx active"
    live_check "export timer active"       sh -c "systemctl --user is-active self-learn-export.timer | grep -qx active"
    live_check "lingering enabled"         sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "web agent loaded"          sh -c "launchctl print gui/$(id -u)/com.self-learn.web"
    live_check "deploy agent loaded"       sh -c "launchctl print gui/$(id -u)/com.self-learn.deploy"
  fi
  live_check "serve maps :$port"           sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"      curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_old_node
test_preflight_git_auth
test_preflight_root
test_fresh_deploy
test_idempotent_rerun
test_push_triggers_redeploy
test_lockfile_change_triggers_ci
test_stopped_app_stays_stopped
test_poll_lock
test_skip_seed
test_port_override
test_operator_escalation
test_serve_approval_pause

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
