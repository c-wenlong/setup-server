#!/usr/bin/env bash
#
# Tests for services/kaichenpedia/setup.sh + deploy.sh + teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
# setup.sh sources ../../lib/common.sh, so every sandbox copy of the
# service sits at <root>/services/<name> with <root>/lib beside it.
copy_lib() { mkdir -p "$1/lib" && cp "$REPO_ROOT/lib/common.sh" "$1/lib/"; }
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
  SVC="$SANDBOX/repo/services/kaichenpedia"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_UNAME LOCAL_PORT HTTPS_PORT REPO_URL BRANCH POLL_SECONDS STATE_DIR CALLS_LOG
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
out_lacks()  { ! grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }
env_lacks()  { ! grep -q "$1" "$SVC/.env"; }
# Image tags are kaichenpedia:<sha>-<build time>; match on the sha.
state_img()  { grep -q "^kaichenpedia:$1-" "$HOME/services/kaichenpedia/state/image"; }
has_img()    { grep -q "^kaichenpedia:$1-" "$STATE_DIR/images"; }
lacks_img()  { ! grep -q "^kaichenpedia:$1-" "$STATE_DIR/images"; }
last_up()    { tail -1 "$STATE_DIR/compose_images" | grep -q "^kaichenpedia:$1-"; }
first_up()   { head -1 "$STATE_DIR/compose_images" | grep -q "^kaichenpedia:$1-"; }

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
  check ".env drops poll interval"                   env_lacks "POLL_SECONDS=86400"
  check ".env has public URL"         env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8091/"
  check "deploy script installed"     [ -x "$HOME/services/kaichenpedia/bin/deploy.sh" ]
  check "env path baked into script"  grep -q "$SVC/.env" "$HOME/services/kaichenpedia/bin/deploy.sh"
  check "cloned the repo"             calls_have "git clone --branch main"
  check "service dir baked in"        grep -q "SERVICE_DIR=\"$SVC\"" "$HOME/services/kaichenpedia/bin/deploy.sh"
  check "built site/Dockerfile"       calls_have "docker build --file $HOME/services/kaichenpedia/repo/site/Dockerfile --tag kaichenpedia:aaa1111-"
  check "probed before swapping"      grep -q "^kaichenpedia:aaa1111-" "$STATE_DIR/probe_runs"
  check "probe on loopback only"      calls_have "docker run -d --name kaichenpedia-probe --publish 127.0.0.1::8080"
  check "probe health checked"        calls_have "http://127.0.0.1:49153/"
  check "probe removed"               calls_have "docker rm -f kaichenpedia-probe"
  check "no quartz build"             no_call "quartz"
  check "recorded the image"          state_img aaa1111
  check "recorded built sha"          grep -qx aaa1111 "$HOME/services/kaichenpedia/state/built-sha"
  check "compose up with the image"   last_up aaa1111
  check "orphans removed"             calls_have "up -d --remove-orphans"
  check "no static build dir"         [ ! -d "$HOME/services/kaichenpedia/www" ]
  check "api probe hit the stub"      calls_have "/api/save"
  check "api probe passed"            out_has "API answering"
  check "warns about missing GH_TOKEN" out_has "GH_TOKEN not set"
  if [ "$OS" = "Linux" ]; then
    check "no timer written"          [ ! -f "$HOME/.config/systemd/user/kaichenpedia-deploy.timer" ]
    check "no lingering touched"      no_call "loginctl enable-linger"
  else
    check "no launch agent written"   [ ! -f "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
  fi
  check "served on tailscale :8091"   calls_have "tailscale serve --bg --https=8091 http://127.0.0.1:8091"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8091"
  teardown
}

fake_deployd() {
  mkdir -p "$HOME/services/deployd/bin" "$HOME/services/deployd/state"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/services/deployd/bin/deployd"
  chmod +x "$HOME/services/deployd/bin/deployd"
}

seed_legacy_poller() {
  if [ "$OS" = "Linux" ]; then
    mkdir -p "$HOME/.config/systemd/user"
    echo x > "$HOME/.config/systemd/user/kaichenpedia-deploy.timer"
    echo x > "$HOME/.config/systemd/user/kaichenpedia-deploy.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    echo x > "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist"
  fi
}

test_legacy_poller_removed() {
  echo "• migration: a leftover per-service deploy timer/plist is removed once deployd is installed"
  setup
  touch "$STATE_DIR/operator"
  fake_deployd
  seed_legacy_poller
  run_deploy
  check "exits zero"           [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "timer disabled"     calls_have "disable --now kaichenpedia-deploy.timer"
    check "timer unit gone"    [ ! -f "$HOME/.config/systemd/user/kaichenpedia-deploy.timer" ]
    check "service unit gone"  [ ! -f "$HOME/.config/systemd/user/kaichenpedia-deploy.service" ]
  else
    check "agent booted out"   calls_have "launchctl bootout gui/.*/com.kaichenpedia.deploy"
    check "plist gone"         [ ! -f "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
  fi
  teardown
}

test_legacy_poller_kept_without_deployd() {
  echo "• migration: without deployd the old poller is kept, with a warning"
  setup
  touch "$STATE_DIR/operator"
  seed_legacy_poller
  run_deploy
  check "exits zero"           [ "$CODE" -eq 0 ]
  check "warns about deployd"  out_has "deployd is not installed"
  if [ "$OS" = "Linux" ]; then
    check "timer unit kept"    [ -f "$HOME/.config/systemd/user/kaichenpedia-deploy.timer" ]
    check "never disabled"     no_call "disable --now kaichenpedia-deploy.timer"
  else
    check "plist kept"         [ -f "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
    check "never booted out"   no_call "launchctl bootout gui/.*/com.kaichenpedia.deploy"
  fi
  teardown
}

test_deployd_disabled_flag() {
  echo "• teardown marks deployd disabled; a manual setup clears the flag"
  setup
  touch "$STATE_DIR/operator"
  fake_deployd
  run_deploy
  run_teardown
  check "teardown exits zero"     [ "$CODE" -eq 0 ]
  check "disabled flag written"   [ -f "$HOME/services/deployd/state/kaichenpedia.disabled" ]
  run_deploy
  check "re-setup exits zero"     [ "$CODE" -eq 0 ]
  check "disabled flag cleared"   [ ! -f "$HOME/services/deployd/state/kaichenpedia.disabled" ]
  teardown
}

test_deploy_sha_mismatch() {
  echo "• deployd-requested sha: verified against the fetched ref"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  DEPLOY_SHA=aaa1111 run_poll
  check "matching sha deploys"    [ "$CODE" -eq 0 ]
  DEPLOY_SHA=zzz9999 run_poll
  check "mismatch exits non-zero" [ "$CODE" -ne 0 ]
  check "says why"                out_has "deployd asked for zzz9999"
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
  check "no rebuild"              no_call "docker build"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_push_triggers_redeploy() {
  echo "• poller: new commit on origin -> new image, container swapped, old builds pruned"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the new sha"     out_has "deploying bbb2222"
  check "built the new image"     calls_have "docker build .*--tag kaichenpedia:bbb2222-"
  check "swapped to it"           last_up bbb2222
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/kaichenpedia/state/built-sha"
  check "image updated"           state_img bbb2222
  check "previous image kept"     has_img aaa1111
  echo "ccc3333" > "$STATE_DIR/remote_sha"
  run_poll
  check "third deploy ok"         [ "$CODE" -eq 0 ]
  check "oldest image pruned"     lacks_img aaa1111
  check "previous image kept"     has_img bbb2222
  teardown
}

test_build_failure_keeps_running() {
  echo "• poller: a failed docker build leaves the running container alone"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  touch "$STATE_DIR/build_fail"
  : > "$STATE_DIR/compose_images"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says the build failed"   out_has "build failed"
  check "container not touched"   [ ! -s "$STATE_DIR/compose_images" ]
  check "built sha unchanged"     grep -qx aaa1111 "$HOME/services/kaichenpedia/state/built-sha"
  check "image unchanged"         state_img aaa1111
  teardown
}

test_unhealthy_rolls_back() {
  echo "• poller: a new image that never answers as a probe never touches the live container"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  echo 49153 > "$STATE_DIR/fail_ports"
  : > "$STATE_DIR/compose_images"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says the probe failed"   out_has "did not answer as a probe"
  check "prints the probe logs"   out_has "stub log line from logs --tail 80 kaichenpedia-probe"
  check "live container untouched" [ ! -s "$STATE_DIR/compose_images" ]
  check "probe removed"           calls_have "docker rm -f kaichenpedia-probe"
  check "built sha unchanged"     grep -qx aaa1111 "$HOME/services/kaichenpedia/state/built-sha"
  check "image unchanged"         state_img aaa1111
  teardown
}

test_image_will_not_start() {
  echo "• poller: an image that will not start at all leaves the live container alone"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  touch "$STATE_DIR/run_fail"
  : > "$STATE_DIR/compose_images"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says it would not start" out_has "would not start"
  check "live container untouched" [ ! -s "$STATE_DIR/compose_images" ]
  teardown
}

test_swap_failure_rolls_back() {
  echo "• poller: probe passes but the swap fails -> logs printed, previous image restored"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  touch "$STATE_DIR/compose_fail"
  : > "$STATE_DIR/compose_images"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says it did not take over" out_has "did not take over"
  check "prints container logs"   out_has "stub log line from logs --tail 80 kaichenpedia"
  check "names the rollback"      out_has "rolling back to kaichenpedia:aaa1111-"
  check "tried the new image"     first_up bbb2222
  check "restored the old one"    last_up aaa1111
  check "image unchanged"         state_img aaa1111
  teardown
}

test_unhealthy_after_swap_rolls_back() {
  echo "• poller: swapped container never answers on the live port -> rolled back"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  echo 8091 > "$STATE_DIR/fail_ports"
  : > "$STATE_DIR/compose_images"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "restored the old one"    last_up aaa1111
  check "built sha unchanged"     grep -qx aaa1111 "$HOME/services/kaichenpedia/state/built-sha"
  teardown
}

test_force_rebuild_same_commit() {
  echo "• deploy.sh --force at an unchanged commit: new tag, old image kept for rollback"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  first="$(cat "$HOME/services/kaichenpedia/state/image")"
  sleep_until_next_second() { local s; s="$(date -u +%S)"; while [ "$(date -u +%S)" = "$s" ]; do /bin/sleep 0.2; done; }
  sleep_until_next_second
  run_poll --force
  second="$(cat "$HOME/services/kaichenpedia/state/image")"
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "rebuilt"                 [ "$(grep -c '^docker build' "$CALLS_LOG")" -ge 2 ]
  check "new tag"                 [ "$first" != "$second" ]
  check "same commit"             state_img aaa1111
  check "old image kept"          grep -qx "$first" "$STATE_DIR/images"
  teardown
}

test_up_to_date_repairs_container() {
  echo "• deploy.sh with nothing new: no build, but the recorded image is brought up (under the lock)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$STATE_DIR/compose_images"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "reports up to date"      out_has "up to date at aaa1111"
  check "no build"                no_call "docker build"
  check "compose up with recorded image" last_up aaa1111
  check "orphans removed"         calls_have "up -d --remove-orphans"
  teardown
}

test_migrates_static_install() {
  echo "• migration: a pre-Docker install (static build, same sha) gets an image and loses www/"
  setup
  touch "$STATE_DIR/operator"
  KP_HOME="$HOME/services/kaichenpedia"
  mkdir -p "$KP_HOME/www/current" "$KP_HOME/state"
  echo "<html>old</html>" > "$KP_HOME/www/current/index.html"
  echo aaa1111 > "$KP_HOME/state/built-sha"
  echo "server { listen 80; }" > "$KP_HOME/nginx.conf"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "built despite same sha"  calls_have "docker build"
  check "image recorded"          state_img aaa1111
  check "static build removed"    [ ! -d "$KP_HOME/www" ]
  check "says so"                 out_has "Removed the old static build"
  check "nginx.conf left alone"   grep -q "listen 80" "$KP_HOME/nginx.conf"
  teardown
}

test_migration_probe_failure_keeps_legacy() {
  echo "• migration: if the first image fails its probe, the old nginx stack keeps serving"
  setup
  touch "$STATE_DIR/operator"
  KP_HOME="$HOME/services/kaichenpedia"
  mkdir -p "$KP_HOME/www/current" "$KP_HOME/state"
  echo "<html>old</html>" > "$KP_HOME/www/current/index.html"
  echo 60258b3 > "$KP_HOME/state/built-sha"
  echo 49153 > "$STATE_DIR/fail_ports"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "compose never ran"       [ ! -f "$STATE_DIR/compose_up" ]
  check "static build kept"       [ -f "$KP_HOME/www/current/index.html" ]
  check "no image recorded"       [ ! -f "$KP_HOME/state/image" ]
  check "built sha unchanged"     grep -qx 60258b3 "$KP_HOME/state/built-sha"
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
  check "exits non-zero"      [ "$CODE" -ne 0 ]
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
    live_check "no legacy timer"        sh -c "! systemctl --user is-active kaichenpedia-deploy.timer 2>/dev/null | grep -qx active"
    live_check "deployd timer active"   sh -c "systemctl --user is-active deployd.timer 2>/dev/null | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -qx 'Linger=yes'"
    live_check "deployd watches it"     sh -c "$HOME/services/deployd/bin/deployd --status | grep -q kaichenpedia"
  else
    live_check "no legacy agent"        sh -c "! launchctl print gui/$(id -u)/com.kaichenpedia.deploy >/dev/null 2>&1"
    live_check "deployd agent loaded"   sh -c "launchctl print gui/$(id -u)/com.setup-server.deployd >/dev/null 2>&1"
    live_check "deployd watches it"     sh -c "$HOME/services/deployd/bin/deployd --status | grep -q kaichenpedia"
  fi
  live_check "serve maps :$port"        sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"   curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

KP() { printf '%s' "$HOME/services/kaichenpedia"; }
UDIR() { printf '%s' "$HOME/.config/systemd/user"; }
set_home() { sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$1#" "$SVC/.env"; }
# Line number of the first call matching $1 (0 when absent).
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }

# A deployed sandbox: setup.sh has run (clone, build, units), Serve maps this
# port to this service, and neighbours sit on other ports (one a lookalike).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  if [ "$OS" = "Linux" ]; then
    # Pre-migration installs ran the per-service poller; setup.sh removes it
    # on its next run, but a box that has not re-run setup yet still has it.
    mkdir -p "$(UDIR)"
    printf '[Timer]\n' > "$(UDIR)/kaichenpedia-deploy.timer"
    printf '[Service]\n' > "$(UDIR)/kaichenpedia-deploy.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    echo x > "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist"
  fi
  echo "my edit" >> "$(KP)/nginx.conf"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8091 (tailnet only)
|-- / proxy http://127.0.0.1:8091

https://test-host.tailfake.ts.net:18091 (tailnet only)
|-- / proxy http://127.0.0.1:18091
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

state_all_there() {
  [ -d "$(KP)/repo/.git" ] && [ -f "$(KP)/state/image" ] && [ -x "$(KP)/bin/deploy.sh" ] \
    && [ -f "$(KP)/state/built-sha" ] && grep -q "my edit" "$(KP)/nginx.conf"
}
units_there() {
  if [ "$OS" = "Linux" ]; then
    [ -f "$(UDIR)/kaichenpedia-deploy.timer" ] && [ -f "$(UDIR)/kaichenpedia-deploy.service" ]
  else
    [ -f "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
  fi
}
units_gone() {
  if [ "$OS" = "Linux" ]; then
    [ ! -e "$(UDIR)/kaichenpedia-deploy.timer" ] && [ ! -e "$(UDIR)/kaichenpedia-deploy.service" ]
  else
    [ ! -e "$HOME/Library/LaunchAgents/com.kaichenpedia.deploy.plist" ]
  fi
}
nothing_changed() {
  no_call " off" && no_call "disable --now" && no_call "--user stop" \
    && no_call "launchctl bootout" && no_call "launchctl disable" \
    && [ ! -f "$STATE_DIR/compose_down" ] && [ -f "$SVC/.env" ] && state_all_there && units_there
}

# Back-date a deploy lock past deploy.sh's 60-minute stale mark.
age_lock() { touch -t 202001010000 "$1"; }

# teardown.sh --purge, with a hook run while the confirmation prompt waits:
# $1 is the answer, $2 a snippet run once the prompt is on screen (before
# the answer is sent). Sets OUT and CODE like run_teardown.
run_purge_at_prompt() {
  local out="$SANDBOX/teardown.out"
  : > "$out"
  { for _ in $(seq 1 100); do grep -q "to confirm" "$out" && break; sleep 0.1; done
    eval "$2"
    printf '%s\n' "$1"; } | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge > "$out" 2>&1
  CODE=$?
  OUT="$(cat "$out")"
}

test_teardown_safe() {
  echo "• teardown: safe remove stops poller + container, keeps everything on disk"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8091"         calls_have "tailscale serve --https=8091 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18091 untouched"  no_call "https=18091"
  check "never serve reset"           no_call "serve reset"
  if [ "$OS" = "Linux" ]; then
    check "timer disabled + stopped"  calls_have "systemctl --user disable --now kaichenpedia-deploy.timer"
    check "static service stopped"    calls_have "systemctl --user stop kaichenpedia-deploy.service"
    check "static service not disabled" no_call "disable --now kaichenpedia-deploy.service"
    check "timer before service"      [ "$(call_line "disable --now kaichenpedia-deploy.timer")" -lt "$(call_line "stop kaichenpedia-deploy.service")" ]
    check "no daemon-reload"          no_call "daemon-reload"
  else
    check "launch agent booted out"   calls_have "launchctl bootout gui/.*/com.kaichenpedia.deploy"
    check "launch agent disabled (no reload at login)" calls_have "launchctl disable gui/.*/com.kaichenpedia.deploy"
  fi
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down without -v"             no_call "down -v"
  check "compose down on this dir"    calls_have "docker compose --project-directory $SVC down"
  check "clone, site, bin, state, nginx.conf kept" state_all_there
  check "unit files kept"             units_there
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_other_units_left_alone() {
  echo "• teardown: units that mention kaichenpedia but setup.sh did not make are named, not touched"
  deployed
  if [ "$OS" = "Linux" ]; then
    printf '[Service]\nExecStart=/bin/true\n' > "$(UDIR)/kaichenpedia-backup.service"
    printf '[Service]\nExecStart=%s/services/kaichenpedia/bin/deploy.sh --force\n' "$HOME" > "$(UDIR)/wiki-nightly.service"
    printf '[Service]\nExecStart=/bin/true\n' > "$(UDIR)/unrelated.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    echo kaichenpedia > "$HOME/Library/LaunchAgents/com.me.wiki-nightly.plist"
  fi
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "warns naming the lookalike" out_has "kaichenpedia-backup.service"
    check "warns naming the mention"  out_has "wiki-nightly.service"
    check "unrelated not named"       out_lacks "unrelated.service"
    check "no systemctl on them"      no_call "systemctl.*\(kaichenpedia-backup\|wiki-nightly\|unrelated\)"
  else
    check "warns naming the mention"  out_has "com.me.wiki-nightly.plist"
  fi
  run_teardown --purge "kaichenpedia"
  check "purge exits zero"            [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "purge keeps the lookalike" [ -f "$(UDIR)/kaichenpedia-backup.service" ]
    check "purge keeps the mention"   [ -f "$(UDIR)/wiki-nightly.service" ]
    check "purge keeps unrelated"     [ -f "$(UDIR)/unrelated.service" ]
  else
    check "purge keeps the mention"   [ -f "$HOME/Library/LaunchAgents/com.me.wiki-nightly.plist" ]
  fi
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says already off"            out_has "already off"
  check "still compose down"          [ -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8091 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8092 (tailnet only)
|-- / proxy http://127.0.0.1:8091

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8091

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /wiki proxy http://127.0.0.1:8091
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8092 off"                   calls_have "serve --https=8092 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "nothing changed"             nothing_changed
  teardown
}

test_teardown_systemctl_fails() {
  [ "$OS" = "Linux" ] || return 0
  echo "• teardown: a failing systemctl disable stops instead of claiming success"
  deployed
  touch "$STATE_DIR/systemctl_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the unit"              out_has "disable --now kaichenpedia-deploy.timer failed"
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"     [ "$CODE" -ne 0 ]
  check "no .env: explains"           out_has "nothing to tear down"
  check "no .env: touched nothing"    [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"        [ "$CODE" -ne 0 ]
  check "root: nothing changed"       nothing_changed
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: nothing changed" nothing_changed
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "no docker: nothing changed"  nothing_changed
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then exactly setup.sh's state goes"
  deployed
  mkdir "$(KP)/.deploy.lock"; age_lock "$(KP)/.deploy.lock"   # stale: a live one refuses (see below)
  run_teardown --purge "kaichenpedia-deploy"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: nothing changed" nothing_changed
  run_teardown --purge "kaichenpedia"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warned GitHub is canonical"  out_has "GitHub is canonical"
  check "serve off for :8091"         calls_have "tailscale serve --https=8091 off"
  check "compose down without -v"     no_call "down -v"
  check "repo clone gone"             [ ! -e "$(KP)/repo" ]
  check "www gone"                    [ ! -e "$(KP)/www" ]
  check "bin gone"                    [ ! -e "$(KP)/bin" ]
  check "state gone"                  [ ! -e "$(KP)/state" ]
  check "nginx.conf gone"             [ ! -e "$(KP)/nginx.conf" ]
  check "stale deploy lock gone"      [ ! -e "$(KP)/.deploy.lock" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "unit files gone"             units_gone
  [ "$OS" = "Linux" ] && check "daemon-reload after removing units" calls_have "systemctl --user daemon-reload"
  check "marker dir gone"             [ ! -e "$(KP)" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  if [ "$OS" = "Linux" ]; then
    check "timers.target.wants untouched" [ -d "$(UDIR)" ]
  else
    check "LaunchAgents dir kept"       [ -d "$HOME/Library/LaunchAgents" ]
  fi
  teardown
}

test_teardown_purge_rm_fails() {
  echo "• teardown --purge: a path rm cannot delete stops with the sudo command, .env kept"
  deployed
  mkdir -p "$(KP)/www/locked"; echo x > "$(KP)/www/locked/f"; chmod 555 "$(KP)/www/locked"
  run_teardown --purge "kaichenpedia"
  chmod 755 "$(KP)/www/locked" 2>/dev/null
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names sudo rm -rf and the path" out_has "sudo rm -rf .*/kaichenpedia/www"
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "unit files kept"             units_there
  teardown
}

test_teardown_purge_keeps_user_files() {
  echo "• teardown --purge: a file you put in SERVICE_HOME survives (and keeps the dir)"
  deployed
  echo mine > "$(KP)/notes.txt"
  run_teardown --purge "kaichenpedia"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "your file kept"              [ -f "$(KP)/notes.txt" ]
  check "warns the dir was left"      out_has "still holds files setup.sh did not make"
  check "owned repo gone"             [ ! -e "$(KP)/repo" ]
  check "owned www gone"              [ ! -e "$(KP)/www" ]
  teardown
}

test_teardown_purge_symlinked_child() {
  echo "• teardown --purge: a symlinked www/ is refused before anything changes"
  deployed
  mkdir -p "$HOME/elsewhere"; echo x > "$HOME/elsewhere/keep"
  mv "$(KP)/www" "$HOME/www-real"
  ln -s "$HOME/elsewhere" "$(KP)/www"
  run_teardown --purge "kaichenpedia"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "link target kept"            [ -f "$HOME/elsewhere/keep" ]
  check "repo kept"                   [ -d "$(KP)/repo/.git" ]
  check "units kept"                  units_there
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_missing_state() {
  echo "• teardown --purge: SERVICE_HOME already gone is fine"
  deployed
  rm -rf "$(KP)"
  run_teardown --purge "kaichenpedia"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "unit files gone"             units_gone
  teardown
  deployed
  sed -i.bak '/^SERVICE_HOME=/d' "$SVC/.env"
  run_teardown --purge "kaichenpedia"
  check "SERVICE_HOME unset: refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a SERVICE_HOME outside ~/services/kaichenpedia"
  deployed
  set_home "$HOME"
  run_teardown --purge "kaichenpedia"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing changed"             nothing_changed
  set_home "$HOME/services/../x"
  run_teardown --purge "kaichenpedia"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  set_home "$HOME/services/"
  run_teardown --purge "kaichenpedia"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./kaichenpedia" "$HOME/services/kaichenpedia/.."; do
    set_home "$dotted"
    run_teardown --purge "kaichenpedia"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "still nothing changed"       nothing_changed
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  set_home "$HOME/services//"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "kaichenpedia"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  set_home "$HOME/services/alias"
  run_teardown --purge "kaichenpedia"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  set_home "$(KP)/"
  run_teardown --purge "kaichenpedia"
  check "one trailing slash on its own dir is fine" [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$(KP)/repo" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/kaichenpedia itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour/repo"; echo x > "$HOME/services/neighbour/repo/keep"
  set_home "$HOME/services/neighbour"
  run_teardown --purge "kaichenpedia"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/repo/keep" ]
  check "  nothing changed"           nothing_changed
  mkdir -p "$(KP)/a:b"
  set_home "$(KP)/a:b"
  run_teardown --purge "kaichenpedia"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/kaichenpedia/repo"; echo x > "$HOME/kaichenpedia/repo/keep"
  run_teardown --purge "kaichenpedia"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"   [ -f "$HOME/kaichenpedia/repo/keep" ]
  check "units kept"                  units_there
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/kaichenpedia survives"
  deployed
  local repo
  repo="$(KP)/setup-server/services/kaichenpedia"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  copy_lib "${repo%/services/*}"
  echo secret > "$(KP)/setup-server/other.env"
  OUT="$(printf '%s\n' "kaichenpedia" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$(KP)/setup-server/other.env" ]
  check "state kept"                  state_all_there
  check "units kept"                  units_there
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8091'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8091 off"                   calls_have "serve --https=8091 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8091"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check "  :8091 off"                 calls_have "serve --https=8091 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8091 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "  :8091 off"                 calls_have "serve --https=8091 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=80x1/' "$SVC/.env"
  run_teardown
  check "non-numeric port refused"    [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  set_home "\"\${HOME}/services/kaichenpedia\""
  run_teardown --purge "kaichenpedia"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$(KP)/repo" ]
  teardown
  deployed
  set_home "'\$HOME/services/kaichenpedia'"
  run_teardown --purge "kaichenpedia"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  state kept"                state_all_there
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SERVICE_HOME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "SERVICE_HOME is set more than once"
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  printf 'X="first\nSERVICE_HOME=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"    out_has "does not close on its line"
  teardown
  deployed
  printf 'Y="a\\"b"\n' >> "$SVC/.env"
  run_teardown
  check "backslash escape: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "kaichenpedia"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing changed"           nothing_changed
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_unresolved_variable() {
  echo "• teardown: a path in .env that still names another variable is refused before anything changes"
  deployed
  set_home "\$HOME/services/\${NAME}"
  run_teardown --purge "kaichenpedia"
  check "purge: exits non-zero"       [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "SERVICE_HOME .*still refers to another variable"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  nothing changed"           nothing_changed
  run_teardown
  check "plain run: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_purge_deploy_lock() {
  echo "• teardown --purge: a live deploy lock refuses up front; a stale one is cleared; teardown holds it through the purge"
  local lock
  deployed
  lock="$(KP)/.deploy.lock"
  mkdir "$lock"
  run_teardown --purge "kaichenpedia"
  check "live lock: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  nothing changed"           nothing_changed
  check "  lock left to its owner"    [ -d "$lock" ]
  run_teardown
  check "plain teardown (deletes nothing) still runs" [ "$CODE" -eq 0 ]
  teardown
  deployed
  lock="$(KP)/.deploy.lock"
  run_purge_at_prompt "kaichenpedia" "mkdir '$lock'"
  check "deploy started during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  lock="$(KP)/.deploy.lock"
  run_purge_at_prompt "kaichenpedia" "[ -e '$lock' ] && echo held > '$STATE_DIR/lock_at_prompt' || echo free > '$STATE_DIR/lock_at_prompt'"
  check "no lock: exits zero"         [ "$CODE" -eq 0 ]
  check "  not taken while the prompt waits" grep -qx free "$STATE_DIR/lock_at_prompt"
  teardown
  deployed
  lock="$(KP)/.deploy.lock"
  mkdir "$lock"; age_lock "$lock"
  printf '%s' "$lock" > "$STATE_DIR/lock_probe"
  run_teardown --purge "kaichenpedia"
  check "stale lock: exits zero"      [ "$CODE" -eq 0 ]
  check "  says it cleared it"        out_has "Cleared a stale deploy lock"
  check "  teardown holds it during down" grep -qx held "$STATE_DIR/lock_at_down"
  check "  gone after the purge"      [ ! -e "$lock" ]
  check "  marker dir gone"           [ ! -e "$(KP)" ]
  teardown
  deployed
  lock="$(KP)/.deploy.lock"
  mkdir "$lock"; echo mine > "$lock/notes"; age_lock "$lock"
  run_teardown --purge "kaichenpedia"
  check "old lock holding files: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  its files kept"            [ -f "$lock/notes" ]
  teardown
  deployed
  lock="$(KP)/.deploy.lock"
  mkdir -p "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$lock"
  run_teardown --purge "kaichenpedia"
  check "symlinked lock: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  link left as it was"       [ -L "$lock" ] && [ -d "$HOME/elsewhere" ]
  teardown
}

test_teardown_purge_rechecked_after_lock() {
  echo "• teardown --purge: targets are worked out again once the lock is held; a change during the prompt deletes nothing"
  deployed
  mv "$(KP)/repo" "$SANDBOX/repo.saved"
  run_purge_at_prompt "kaichenpedia" "mv '$SANDBOX/repo.saved' '$(KP)/repo'"
  check "repo/ recreated during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says the list changed"     out_has "changed while the prompt waited"
  check "  nothing changed"           nothing_changed
  check "  lock dropped"              [ ! -e "$(KP)/.deploy.lock" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"; echo precious > "$HOME/elsewhere/keep"
  run_purge_at_prompt "kaichenpedia" "mv '$(KP)/state' '$SANDBOX/state.saved' && ln -s '$HOME/elsewhere' '$(KP)/state'"
  check "state/ swapped for a symlink: exits non-zero" [ "$CODE" -ne 0 ]
  check "  refuses the link"          out_has "state is a symlink"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ] && no_call " off"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  link target kept"          [ -f "$HOME/elsewhere/keep" ]
  teardown
}

# macOS branch on any box: FAKE_UNAME=Darwin makes teardown.sh take it.
test_teardown_macos_launch_agent() {
  echo "• teardown (macOS branch): only a loaded agent is booted out; a failed unload stops before --purge deletes anything"
  deployed
  export FAKE_UNAME=Darwin
  run_teardown
  check "loaded agent: exits zero"    [ "$CODE" -eq 0 ]
  check "  checked with print first"  [ "$(call_line "launchctl print gui/.*/com.kaichenpedia.deploy")" -gt 0 ] && [ "$(call_line "launchctl print")" -lt "$(call_line "launchctl bootout")" ]
  check "  booted out"                calls_have "launchctl bootout gui/.*/com.kaichenpedia.deploy"
  check "  disabled"                  calls_have "launchctl disable gui/.*/com.kaichenpedia.deploy"
  check "  no systemctl"              no_call "systemctl"
  : > "$CALLS_LOG"
  touch "$STATE_DIR/launchd_not_loaded"
  run_teardown
  check "agent not loaded: exits zero" [ "$CODE" -eq 0 ]
  check "  no bootout attempted"      no_call "launchctl bootout"
  check "  still disabled"            calls_have "launchctl disable gui/.*/com.kaichenpedia.deploy"
  teardown
  deployed
  export FAKE_UNAME=Darwin
  touch "$STATE_DIR/launchd_bootout_fails"
  run_teardown --purge "kaichenpedia"
  check "bootout fails, agent still loaded: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                   out_has "Could not unload LaunchAgent com.kaichenpedia.deploy"
  check "  no compose down"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  state kept"                state_all_there
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  echo async > "$STATE_DIR/launchd_bootout_fails"
  run_teardown
  check "bootout errors but the agent unloads: exits zero" [ "$CODE" -eq 0 ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  touch "$STATE_DIR/launchd_disable_fails"
  run_teardown --purge "kaichenpedia"
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it would reload"      out_has "would load again at the next login"
  check "  state kept"                state_all_there
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  run_teardown --purge "kaichenpedia"
  check "purge on macOS: exits zero"  [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$(KP)/www" ]
  check "  no daemon-reload"          no_call "daemon-reload"
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_git_auth
test_fresh_deploy
test_legacy_poller_removed
test_legacy_poller_kept_without_deployd
test_deployd_disabled_flag
test_deploy_sha_mismatch
test_idempotent_rerun
test_push_triggers_redeploy
test_build_failure_keeps_running
test_unhealthy_rolls_back
test_image_will_not_start
test_swap_failure_rolls_back
test_unhealthy_after_swap_rolls_back
test_force_rebuild_same_commit
test_up_to_date_repairs_container
test_migrates_static_install
test_migration_probe_failure_keeps_legacy
test_poll_lock
test_port_override
test_operator_escalation
test_teardown_safe
test_teardown_other_units_left_alone
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_systemctl_fails
test_teardown_preflight
test_teardown_purge
test_teardown_purge_rm_fails
test_teardown_purge_keeps_user_files
test_teardown_purge_symlinked_child
test_teardown_purge_missing_state
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_quoted_env
test_teardown_home_variable_in_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_unresolved_variable
test_teardown_purge_deploy_lock
test_teardown_purge_rechecked_after_lock
test_teardown_macos_launch_agent

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
