#!/usr/bin/env bash
#
# Tests for services/sources/setup.sh + deploy.sh + teardown.sh.
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
  SVC="$SANDBOX/repo/services/sources"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"

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
  unset FAKE_UID FAKE_UNAME LOCAL_PORT HTTPS_PORT SOURCE_REPO BRANCH POLL_SECONDS SITE_PASSPHRASE STATE_DIR CALLS_LOG
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

out_has()    { grep -q -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }
env_lacks()  { ! grep -q "$1" "$SVC/.env"; }

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
  check ".env drops poll interval"                   env_lacks "POLL_SECONDS=86400"
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
    check "no timer written"          [ ! -f "$HOME/.config/systemd/user/sources-deploy.timer" ]
    check "no lingering touched"      no_call "loginctl enable-linger"
  else
    check "no launch agent written"   [ ! -f "$HOME/Library/LaunchAgents/com.sources.deploy.plist" ]
  fi
  check "served on tailscale :8098"   calls_have "tailscale serve --bg --https=8098 http://127.0.0.1:8098"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8098"
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
    echo x > "$HOME/.config/systemd/user/sources-deploy.timer"
    echo x > "$HOME/.config/systemd/user/sources-deploy.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    echo x > "$HOME/Library/LaunchAgents/com.sources.deploy.plist"
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
    check "timer disabled"     calls_have "disable --now sources-deploy.timer"
    check "timer unit gone"    [ ! -f "$HOME/.config/systemd/user/sources-deploy.timer" ]
    check "service unit gone"  [ ! -f "$HOME/.config/systemd/user/sources-deploy.service" ]
  else
    check "agent booted out"   calls_have "launchctl bootout gui/.*/com.sources.deploy"
    check "plist gone"         [ ! -f "$HOME/Library/LaunchAgents/com.sources.deploy.plist" ]
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
    check "timer unit kept"    [ -f "$HOME/.config/systemd/user/sources-deploy.timer" ]
    check "never disabled"     no_call "disable --now sources-deploy.timer"
  else
    check "plist kept"         [ -f "$HOME/Library/LaunchAgents/com.sources.deploy.plist" ]
    check "never booted out"   no_call "launchctl bootout gui/.*/com.sources.deploy"
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
  check "disabled flag written"   [ -f "$HOME/services/deployd/state/sources.disabled" ]
  run_deploy
  check "re-setup exits zero"     [ "$CODE" -eq 0 ]
  check "disabled flag cleared"   [ ! -f "$HOME/services/deployd/state/sources.disabled" ]
  teardown
}

test_deploy_sha_mismatch() {
  echo "• deployd-requested sha: verified against the pulled clone"
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

test_path_restored_from_env() {
  echo "• re-run under a minimal PATH finds uv via the dir saved in .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first run ok"            [ "$CODE" -eq 0 ]
  nouv="$STATE_DIR/no-uv-stubs"; mkdir -p "$nouv"
  for s in "$STUBS"/*; do [ "${s##*/}" = uv ] || ln -s "$s" "$nouv/${s##*/}"; done
  uvbin="$STATE_DIR/saved-uv-bin"; mkdir -p "$uvbin"
  printf '#!/bin/sh\nexec "%s/uv" "$@"\n' "$STUBS" > "$uvbin/uv"; chmod +x "$uvbin/uv"
  grep -v '^UV_BIN=' "$SVC/.env" > "$SVC/.env.tmp" && mv "$SVC/.env.tmp" "$SVC/.env"
  printf "UV_BIN='%s'\n" "$uvbin" >> "$SVC/.env"
  OUT="$(printf '\n' | PATH="$nouv:/usr/bin:/bin" bash "$SVC/setup.sh" 2>&1)"; CODE=$?
  check "exits zero without stub uv" [ "$CODE" -eq 0 ]
  check "found uv via .env"          out_has "Preflight checks"
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
  echo "• --force rebuild of the live sha: builds beside it, old build stays previous"
  # The gap this guards is microseconds inside the swap, so post-hoc checks
  # can't observe it directly; what they pin is the fix's shape — the new
  # build lands under a <sha>.rebuild-* name while `current` still resolves,
  # and the old directory is kept rather than deleted under the live name.
  # A revert to rm -rf'ing the live release would fail the name and
  # keep checks below.
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

test_new_layout_build_path() {
  echo "• repo with the apps/web layout: setup accepts it, deploy builds from apps/web/build/"
  setup
  rm -rf "$SOURCE_REPO/scripts"
  mkdir -p "$SOURCE_REPO/apps/web/build"
  echo "# build stub" > "$SOURCE_REPO/apps/web/build/build_site.py"
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "built from apps/web"     calls_have "uv run apps/web/build/build_site.py --out"
  check "no old-path build"       no_call "uv run scripts/build_site.py"
  check "site swapped into current" [ -f "$HOME/services/sources/www/current/index.html" ]
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
  check "exits non-zero"      [ "$CODE" -ne 0 ]
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
  check "exits non-zero"      [ "$CODE" -ne 0 ]
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

site_home() { echo "$HOME/services/sources"; }
unit_dir()  { echo "$HOME/.config/systemd/user"; }
set_env()   { sed -i.bak "s#^$1=.*#$1=$2#" "$SVC/.env"; }

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# neighbours sit on other ports (one a lookalike suffix), and units this
# setup.sh never writes (sources-trigger.service and its backup) exist.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(unit_dir)"
  if [ "$OS" = "Linux" ]; then
    # Pre-migration installs ran the per-service poller; setup.sh removes it
    # on its next run, but a box that has not re-run setup yet still has it.
    printf '[Timer]\n' > "$(unit_dir)/sources-deploy.timer"
    printf '[Service]\n' > "$(unit_dir)/sources-deploy.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    echo x > "$HOME/Library/LaunchAgents/com.sources.deploy.plist"
  fi
  echo "[Service]" > "$(unit_dir)/sources-trigger.service"
  echo "[Service]" > "$(unit_dir)/sources-trigger.service.bak-2026-10-24"
  echo "stub content" > "$SOURCE_REPO/keep.md"
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE_FIXTURE
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8098 (tailnet only)
|-- / proxy http://127.0.0.1:8098

https://test-host.tailfake.ts.net:18098 (tailnet only)
|-- / proxy http://127.0.0.1:18098
EOF_SERVE_FIXTURE
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
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

# Nothing a teardown changes happened.
nothing_changed() {
  [ ! -f "$STATE_DIR/compose_down" ] && no_call " off" && no_call "systemctl" && no_call "launchctl" \
    && [ -f "$SVC/.env" ] && [ -f "$(site_home)/www/current/index.html" ] && [ -d "$(site_home)/state" ]
}
# Line number of the first call matching $1 (0 when absent).
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
out_lacks() { ! grep -q -- "$1" <<<"$OUT"; }

test_teardown_safe() {
  echo "• teardown: safe remove keeps files and .env, unpublishes only its port, stops the poller"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8098"         calls_have "tailscale serve --https=8098 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18098 untouched"  no_call "https=18098"
  check "never serve reset"           no_call "serve reset"
  check "timer disabled + stopped"    calls_have "systemctl --user disable --now sources-deploy.timer"
  check "deploy service stopped"      calls_have "systemctl --user stop sources-deploy.service"
  check "timer before service"        sh -c 'grep -n "systemctl --user" "$1" | head -1 | grep -q sources-deploy.timer' _ "$CALLS_LOG"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down via project dir"        calls_have "docker compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "site files kept"             [ -f "$(site_home)/www/current/index.html" ]
  check "nginx.conf kept"             [ -f "$(site_home)/nginx.conf" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "unit files kept"             [ -f "$(unit_dir)/sources-deploy.timer" ]
  check "no daemon-reload"            no_call "daemon-reload"
  check "trigger unit never touched"  no_call "sources-trigger"
  check "  but named in a warning"    out_has "sources-trigger.service mentions sources but setup.sh does not create it"
  check "  backup named too"          out_has "sources-trigger.service.bak-2026-10-24"
  check "trigger unit kept"           [ -f "$(unit_dir)/sources-trigger.service" ]
  check "lingering untouched"         no_call "linger"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_units_already_gone() {
  echo "• teardown: missing unit files are fine (nothing to stop)"
  deployed
  rm -f "$(unit_dir)/sources-deploy.timer" "$(unit_dir)/sources-deploy.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no disable call"             no_call "disable"
  check "says already gone"           out_has "sources-deploy.timer not installed"
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
  printf 'https://test-host.tailfake.ts.net:8098 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE_FIXTURE
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8098

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8098

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /sources proxy http://127.0.0.1:8098
EOF_SERVE_FIXTURE
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
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
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  check "poller left running"         no_call "systemctl"
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
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "nothing stopped"             no_call "systemctl"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then setup.sh's files, .env and units go"
  deployed
  local home; home="$(site_home)"
  run_teardown --purge "source"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: site kept"       [ -f "$home/www/current/index.html" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: poller running"  no_call "systemctl"
  check "wrong name: serve untouched" no_call " off"
  check "warns the passphrase goes"   out_has "holds SITE_PASSPHRASE"
  check "lists what it deletes"       out_has "$home/www"
  run_teardown --purge "sources"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "bin gone"                    [ ! -e "$home/bin" ]
  check "state gone"                  [ ! -e "$home/state" ]
  check "www gone"                    [ ! -e "$home/www" ]
  check "nginx.conf gone"             [ ! -e "$home/nginx.conf" ]
  check "marker dir gone"             [ ! -e "$home" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "timer unit file gone"        [ ! -e "$(unit_dir)/sources-deploy.timer" ]
  check "service unit file gone"      [ ! -e "$(unit_dir)/sources-deploy.service" ]
  check "daemon-reload after"         calls_have "systemctl --user daemon-reload"
  check "serve off for :8098"         calls_have "tailscale serve --https=8098 off"
  check "down without -v"             no_call "down -v"
  check "sources repo kept"           [ -f "$SOURCE_REPO/keep.md" ]
  check "repo .git kept"              [ -d "$SOURCE_REPO/.git" ]
  check "trigger unit kept"           [ -f "$(unit_dir)/sources-trigger.service" ]
  check "trigger backup kept"         [ -f "$(unit_dir)/sources-trigger.service.bak-2026-10-24" ]
  check "trigger never touched"       no_call "sources-trigger"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "says starts fresh"           out_has "starts fresh"
  teardown
}

test_teardown_purge_keeps_foreign_files() {
  echo "• teardown --purge: files setup.sh did not write stay, and so does the marker"
  deployed
  local home; home="$(site_home)"
  echo old > "$home/nginx.conf.bak"
  run_teardown --purge "sources"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "setup's files gone"          [ ! -e "$home/www" ]
  check "foreign backup kept"         [ -f "$home/nginx.conf.bak" ]
  check "marker kept (not empty)"     [ -d "$home" ]
  check "warns what is left"          out_has "nginx.conf.bak"
  teardown
}

test_teardown_purge_missing_site_files() {
  echo "• teardown --purge: site files already gone is fine; marker still removed"
  deployed
  local home; home="$(site_home)"
  rm -rf "${home:?}/bin" "${home:?}/state" "${home:?}/www" "${home:?}/nginx.conf"
  run_teardown --purge "sources"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "empty marker removed"        [ ! -e "$(site_home)" ]
  teardown
  deployed
  rm -rf "$(site_home)"
  run_teardown --purge "sources"
  check "no site home at all: exits zero" [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_marker_symlink() {
  echo "• teardown --purge: a symlinked ~/services/sources is refused"
  deployed
  mv "$(site_home)" "$HOME/real-sources"
  ln -s "$HOME/real-sources" "$(site_home)"
  run_teardown --purge "sources"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "real dir kept"               [ -f "$HOME/real-sources/www/current/index.html" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_symlinked_leaf() {
  echo "• teardown --purge: a symlinked www is refused, its target kept"
  deployed
  mv "$(site_home)/www" "$HOME/elsewhere-www"
  ln -s "$HOME/elsewhere-www" "$(site_home)/www"
  run_teardown --purge "sources"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "link target kept"            [ -f "$HOME/elsewhere-www/current/index.html" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_repo_inside() {
  echo "• teardown --purge: the sources repo is never deleted, wherever it lives"
  deployed
  local home; home="$(site_home)"
  mkdir -p "$home/www/repo/.git"; echo mine > "$home/www/repo/notes.md"
  set_env SOURCE_REPO "$home/www/repo"
  run_teardown --purge "sources"
  check "repo inside www: exits non-zero" [ "$CODE" -ne 0 ]
  check "  repo kept"                 [ -f "$home/www/repo/notes.md" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  home="$(site_home)"
  cp -R "$SOURCE_REPO" "$home/clone"
  set_env SOURCE_REPO "$home/clone"
  run_teardown --purge "sources"
  check "clone beside setup's files: exits zero" [ "$CODE" -eq 0 ]
  check "  clone kept"                [ -f "$home/clone/keep.md" ]
  check "  www gone"                  [ ! -e "$home/www" ]
  check "  marker kept (holds the clone)" [ -d "$home" ]
  teardown
  deployed
  home="$(site_home)"
  mkdir -p "$home/.git"
  set_env SOURCE_REPO "$home"
  run_teardown --purge "sources"
  check "repo is the marker itself: exits non-zero" [ "$CODE" -ne 0 ]
  check "  www kept"                  [ -d "$home/www" ]
  teardown
  # Relative (or ~, which Compose does not expand): resolved against the
  # caller's cwd, so the overlap check cannot be trusted. Run from inside
  # the marker dir, where "www/repo" is a repo under the purge.
  local rel
  # shellcheck disable=SC2088  # a literal ~ is the point: Compose does not expand it
  for rel in "www/repo" "dev/sources" "~/dev/sources"; do
    deployed
    home="$(site_home)"
    mkdir -p "$home/www/repo/.git"; echo mine > "$home/www/repo/notes.md"
    set_env SOURCE_REPO "$rel"
    OUT="$(cd "$home" && printf '%s\n' sources | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"; CODE=$?
    check "relative SOURCE_REPO=$rel: exits non-zero" [ "$CODE" -ne 0 ]
    check "  says it is not absolute"   out_has "is not an absolute path"
    check "  repo kept"                 [ -f "$home/www/repo/notes.md" ]
    check "  nothing unpublished"       no_call " off"
    check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a SERVICE_HOME outside ~/services/sources"
  deployed
  set_env SERVICE_HOME "$HOME"
  run_teardown --purge "sources"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  set_env SERVICE_HOME "$HOME/services/../x"
  run_teardown --purge "sources"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  set_env SERVICE_HOME "$HOME/services/"
  run_teardown --purge "sources"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  mkdir -p "$HOME/services/neighbour/www"; echo x > "$HOME/services/neighbour/www/keep"
  local dotted
  for dotted in "$HOME/services/." "$HOME/services/./sources" "$HOME/services/sources/.."; do
    set_env SERVICE_HOME "$dotted"
    run_teardown --purge "sources"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  set_env SERVICE_HOME "$HOME/services/neighbour"
  run_teardown --purge "sources"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/www/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/sources/a:b"
  set_env SERVICE_HOME "$HOME/services/sources/a:b"
  run_teardown --purge "sources"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  check "site still there"            [ -f "$(site_home)/www/current/index.html" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  mkdir -p "$HOME/services/neighbour/www"; echo x > "$HOME/services/neighbour/www/keep"
  set_env SERVICE_HOME "$HOME/services//"
  run_teardown --purge "sources"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/www/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  set_env SERVICE_HOME "$HOME/services/alias"
  run_teardown --purge "sources"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/www/keep" ]
  set_env SERVICE_HOME "$HOME/services/sources///"
  run_teardown --purge "sources"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  www gone"                  [ ! -e "$(site_home)/www" ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/sources/www"; echo x > "$HOME/sources/www/keep"
  run_teardown --purge "sources"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"   [ -f "$HOME/sources/www/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/sources survives"
  deployed
  local repo="$HOME/services/sources/setup-server/services/sources"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  copy_lib "${repo%/services/*}"
  echo secret > "$HOME/services/sources/setup-server/other.env"
  OUT="$(printf '%s\n' "sources" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/sources/setup-server/other.env" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  set_env SERVICE_HOME "\"\${HOME}/services/sources\""
  run_teardown --purge "sources"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  www gone"                  [ ! -e "$(site_home)/www" ]
  teardown
  deployed
  set_env SERVICE_HOME "'\$HOME/services/sources'"
  run_teardown --purge "sources"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  www kept"                  [ -d "$(site_home)/www" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8098'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8098 off"                   calls_have "serve --https=8098 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8098"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8098 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SERVICE_HOME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "SERVICE_HOME is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
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
  deployed
  run_teardown
  check "setup's %q passphrase line passes lint" [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "sources"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  poller untouched"          no_call "systemctl"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_compose_override_file() {
  echo "• teardown: a local docker-compose.override.yml rides along like setup.sh's up"
  deployed
  printf 'services:\n  sources:\n    extra_hosts: ["host.docker.internal:host-gateway"]\n' \
    > "$SVC/docker-compose.override.yml"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "same down as setup's up (no -f)" calls_have "docker compose --project-directory $SVC down"
  check "no explicit -f"              no_call "compose -f"
  check "override file kept"          [ -f "$SVC/docker-compose.override.yml" ]
  teardown
}

test_teardown_unresolved_variable() {
  echo "• teardown: a path in .env that still names another variable is refused before anything changes"
  deployed
  local home; home="$(site_home)"
  # To a reader that expands it, this is a repo inside www/; left literal,
  # the overlap check would test a path that does not exist.
  mkdir -p "$home/www/repo/.git"; echo mine > "$home/www/repo/notes.md"
  set_env SOURCE_REPO "\$SERVICE_HOME/www/repo"
  run_teardown --purge "sources"
  check "SOURCE_REPO=\$SERVICE_HOME/...: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "SOURCE_REPO .*still refers to another variable"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  repo kept"                 [ -f "$home/www/repo/notes.md" ]
  check "  nothing changed"           nothing_changed
  run_teardown
  check "plain run: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  set_env SERVICE_HOME "\$HOME/services/\${NAME}"
  run_teardown --purge "sources"
  check "SERVICE_HOME=...\${NAME}: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_foreign_units_by_content() {
  echo "• teardown: a unit or agent whose contents name ~/services/sources is listed, never touched"
  deployed
  printf '[Service]\nExecStart=/usr/bin/rsync -a %s/services/sources/www/ /backup/\n' "$HOME" \
    > "$(unit_dir)/nightly-mirror.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$(unit_dir)/unrelated.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit by its contents" out_has "nightly-mirror.service mentions sources but setup.sh does not create it"
  check "unrelated unit not named"    out_lacks "unrelated.service"
  check "never addressed"             no_call "nightly-mirror"
  run_teardown --purge "sources"
  check "purge: exits zero"           [ "$CODE" -eq 0 ]
  check "  unit kept"                 [ -f "$(unit_dir)/nightly-mirror.service" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<string>%s/services/sources/bin/deploy.sh</string>\n' "$HOME" \
    > "$HOME/Library/LaunchAgents/com.me.mirror.plist"
  echo other > "$HOME/Library/LaunchAgents/com.me.unrelated.plist"
  echo own > "$HOME/Library/LaunchAgents/com.sources.deploy.plist"
  run_teardown
  check "macOS: exits zero"           [ "$CODE" -eq 0 ]
  check "  names the agent by its contents" out_has "com.me.mirror.plist mentions sources"
  check "  unrelated agent not named" out_lacks "com.me.unrelated.plist"
  check "  its own plist not named"   out_lacks "com.sources.deploy.plist mentions"
  check "  agent never addressed"     no_call "com.me.mirror"
  check "  agent kept"                [ -f "$HOME/Library/LaunchAgents/com.me.mirror.plist" ]
  teardown
}

test_teardown_purge_deploy_lock() {
  echo "• teardown --purge: a live deploy lock refuses up front; a stale one is cleared; teardown holds it through the purge"
  local lock
  deployed
  lock="$(site_home)/.deploy.lock"
  mkdir "$lock"
  run_teardown --purge "sources"
  check "live lock: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  nothing changed"           nothing_changed
  check "  lock left to its owner"    [ -d "$lock" ]
  run_teardown
  check "plain teardown (deletes nothing) still runs" [ "$CODE" -eq 0 ]
  teardown
  deployed
  lock="$(site_home)/.deploy.lock"
  run_purge_at_prompt "sources" "mkdir '$lock'"
  check "deploy started during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  lock="$(site_home)/.deploy.lock"
  run_purge_at_prompt "sources" "[ -e '$lock' ] && echo held > '$STATE_DIR/lock_at_prompt' || echo free > '$STATE_DIR/lock_at_prompt'"
  check "no lock: exits zero"         [ "$CODE" -eq 0 ]
  check "  not taken while the prompt waits" grep -qx free "$STATE_DIR/lock_at_prompt"
  teardown
  deployed
  lock="$(site_home)/.deploy.lock"
  mkdir "$lock"; age_lock "$lock"
  printf '%s' "$lock" > "$STATE_DIR/lock_probe"
  run_teardown --purge "sources"
  check "stale lock: exits zero"      [ "$CODE" -eq 0 ]
  check "  says it cleared it"        out_has "Cleared a stale deploy lock"
  check "  teardown holds it during down" grep -qx held "$STATE_DIR/lock_at_down"
  check "  gone after the purge"      [ ! -e "$lock" ]
  check "  marker dir gone"           [ ! -e "$(site_home)" ]
  teardown
  deployed
  lock="$(site_home)/.deploy.lock"
  mkdir "$lock"; echo mine > "$lock/notes"; age_lock "$lock"
  run_teardown --purge "sources"
  check "old lock holding files: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  its files kept"            [ -f "$lock/notes" ]
  teardown
  deployed
  lock="$(site_home)/.deploy.lock"
  mkdir -p "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$lock"
  run_teardown --purge "sources"
  check "symlinked lock: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  link left as it was"       [ -L "$lock" ] && [ -d "$HOME/elsewhere" ]
  teardown
}

test_teardown_purge_rechecked_after_lock() {
  echo "• teardown --purge: targets are worked out again once the lock is held; a change during the prompt deletes nothing"
  deployed
  mv "$(site_home)/bin" "$SANDBOX/bin.saved"
  run_purge_at_prompt "sources" "mv '$SANDBOX/bin.saved' '$(site_home)/bin'"
  check "bin/ recreated during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says the list changed"     out_has "changed while the prompt waited"
  check "  nothing changed"           nothing_changed
  check "  bin kept"                  [ -d "$(site_home)/bin" ]
  check "  lock dropped"              [ ! -e "$(site_home)/.deploy.lock" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"; echo precious > "$HOME/elsewhere/keep"
  run_purge_at_prompt "sources" "mv '$(site_home)/www' '$SANDBOX/www.saved' && ln -s '$HOME/elsewhere' '$(site_home)/www'"
  check "www/ swapped for a symlink: exits non-zero" [ "$CODE" -ne 0 ]
  check "  refuses the link"          out_has "www is a symlink"
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
  check "  checked with print first"  [ "$(call_line "launchctl print gui/.*/com.sources.deploy")" -gt 0 ] && [ "$(call_line "launchctl print")" -lt "$(call_line "launchctl bootout")" ]
  check "  booted out"                calls_have "launchctl bootout gui/.*/com.sources.deploy"
  check "  disabled"                  calls_have "launchctl disable gui/.*/com.sources.deploy"
  check "  no systemctl"              no_call "systemctl"
  : > "$CALLS_LOG"
  touch "$STATE_DIR/launchd_not_loaded"
  run_teardown
  check "agent not loaded: exits zero" [ "$CODE" -eq 0 ]
  check "  no bootout attempted"      no_call "launchctl bootout"
  check "  still disabled"            calls_have "launchctl disable gui/.*/com.sources.deploy"
  teardown
  deployed
  export FAKE_UNAME=Darwin
  touch "$STATE_DIR/launchd_bootout_fails"
  run_teardown --purge "sources"
  check "bootout fails, agent still loaded: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                   out_has "Could not unload LaunchAgent com.sources.deploy"
  check "  no compose down"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  state kept"                [ -f "$(site_home)/www/current/index.html" ]
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
  run_teardown --purge "sources"
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it would reload"      out_has "would load again at the next login"
  check "  state kept"                [ -f "$(site_home)/www/current/index.html" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  run_teardown --purge "sources"
  check "purge on macOS: exits zero"  [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$(site_home)/www" ]
  check "  no daemon-reload"          no_call "daemon-reload"
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
    live_check "no legacy timer"        sh -c "! systemctl --user is-active sources-deploy.timer 2>/dev/null | grep -qx active"
    live_check "deployd timer active"   sh -c "systemctl --user is-active deployd.timer 2>/dev/null | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -qx 'Linger=yes'"
    live_check "deployd watches it"     sh -c "$HOME/services/deployd/bin/deployd --status | grep -q sources"
  else
    live_check "no legacy agent"        sh -c "! launchctl print gui/$(id -u)/com.sources.deploy >/dev/null 2>&1"
    live_check "deployd agent loaded"   sh -c "launchctl print gui/$(id -u)/com.setup-server.deployd >/dev/null 2>&1"
    live_check "deployd watches it"     sh -c "$HOME/services/deployd/bin/deployd --status | grep -q sources"
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
test_legacy_poller_removed
test_legacy_poller_kept_without_deployd
test_deployd_disabled_flag
test_deploy_sha_mismatch
test_path_restored_from_env
test_idempotent_rerun
test_push_triggers_redeploy
test_force_rebuild_same_sha
test_new_layout_build_path
test_poll_lock
test_fetch_lock
test_port_override
test_operator_escalation
# teardown tests assert the systemd poller path; the launchd path is not
# exercised by this suite (verify it on a real Mac).
if [ "$OS" = "Linux" ]; then
  test_teardown_safe
  test_teardown_units_already_gone
  test_teardown_not_published
  test_teardown_port_owned_by_someone_else
  test_teardown_every_port_pointing_here
  test_teardown_serve_status_fails
  test_teardown_preflight
  test_teardown_purge
  test_teardown_purge_keeps_foreign_files
  test_teardown_purge_missing_site_files
  test_teardown_purge_marker_symlink
  test_teardown_purge_symlinked_leaf
  test_teardown_purge_repo_inside
  test_teardown_purge_refuses_odd_paths
  test_teardown_purge_trailing_slashes
  test_teardown_purge_services_root_is_a_link
  test_teardown_purge_keeps_a_checkout_inside
  test_teardown_home_variable_in_env
  test_teardown_quoted_env
  test_teardown_env_lint
  test_teardown_refuses_compose_overrides
  test_teardown_compose_override_file
test_teardown_unresolved_variable
test_teardown_foreign_units_by_content
test_teardown_purge_deploy_lock
test_teardown_purge_rechecked_after_lock
test_teardown_macos_launch_agent
else
  green "    ✓ (teardown tests skipped on macOS — they assert the systemd poller)"; PASS=$((PASS + 1))
fi

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
