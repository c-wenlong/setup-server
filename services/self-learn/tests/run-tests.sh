#!/usr/bin/env bash
#
# Tests for services/self-learn/setup.sh + deploy.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/docker-compose.yml" \
    "$SERVICE_DIR/teardown.sh" \
    "$SERVICE_DIR/sync.sh" "$SVC/"
}

# A self-learn .env as a finished setup.sh would have written it — enough for
# sync.sh tests without a full mocked deploy.
mk_env() {
  mkdir -p "$HOME/services/self-learn/bin" "$HOME/services/self-learn/state" \
    "$HOME/.self-learn/blobs/local"
  cat > "$SVC/.env" <<EOF
SERVICE_HOME=$HOME/services/self-learn
SELF_LEARN_HOME=$HOME/.self-learn
MAC_SSH=tester@mac.invalid
NODE_BIN=/usr/bin
LOCAL_PORT=8107
PG_PORT=5432
POSTGRES_USER=catalog
POSTGRES_PASSWORD=pw
POSTGRES_DB=self_learn
DATABASE_URL=postgres://catalog:pw@127.0.0.1:5432/self_learn
EOF
  chmod 600 "$SVC/.env"
}

# The sibling seafile service's .env, at the default sibling path
# ($SVC/../seafile/.env).
mk_seafile_env() {
  mkdir -p "$SANDBOX/seafile"
  cat > "$SANDBOX/seafile/.env" <<EOF
LOCAL_PORT=8081
SEAFILE_SERVER_PROTOCOL=https
SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:8443
INIT_SEAFILE_ADMIN_EMAIL=admin@test
INIT_SEAFILE_ADMIN_PASSWORD=adminpw
EOF
}

# Canned snapshot query answers (name|ts_col|present meta, then union rows).
mk_psql_canned() {
  cat > "$STATE_DIR/psql_meta" <<'EOF'
asset|created_at|t
catalog_instance||t
event|at|t
review|last_reviewed|t
EOF
  cat > "$STATE_DIR/psql_rows" <<'EOF'
asset|42|2026-10-06 10:00:00
catalog_instance|1|-
event|510|2026-10-06 18:00:00
review|77|2026-10-06 12:00:00
EOF
  cat > "$STATE_DIR/mac_psql_meta" <<'EOF'
asset|created_at|t
catalog_instance||t
event|at|t
review|last_reviewed|t
EOF
  cat > "$STATE_DIR/mac_psql_rows" <<'EOF'
asset|40|2026-10-05 10:00:00
catalog_instance|1|-
event|505|2026-10-05 18:00:00
review|70|2026-10-05 12:00:00
EOF
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_UNAME LOCAL_PORT HTTPS_PORT PG_PORT REPO_URL BRANCH POLL_SECONDS \
    SKIP_SEED OWNER_PASSWORD AUTH_SECRET STATE_DIR CALLS_LOG \
    STUDIO_ENABLED ASSET_FILES_ENABLED \
    SEAFILE_ENV MAC_SSH MAC_HOME MAC_REPO MAC_PGBIN MAC_DB MAC_DB_URL \
    MAC_PGPORT MAC_SEAFILE_URL SEAFILE_URL SEAFILE_SYNC_USER \
    SEAFILE_SYNC_PASSWORD SEAFILE_SYNC_REPO
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

# sync.sh runs in place from the service copy.
run_sync() {
  OUT="$(PATH="$STUBS:$PATH" bash "$SVC/sync.sh" "$@" 2>&1)"
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
out_lacks()  { ! grep -q -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
REPO_DIR()   { printf '%s' "$HOME/services/self-learn/repo"; }
TL_DIR()     { printf '%s' "$(REPO_DIR)/tools/tldrawkc"; }
# Line of the first logged call matching $1 (empty when none), to assert order.
call_line()  { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1; }
# The studio runner's unit as setup.sh leaves it, so sync.sh sees it installed.
mk_studio_unit() {
  if [ "$OS" = "Linux" ]; then
    mkdir -p "$HOME/.config/systemd/user"
    touch "$HOME/.config/systemd/user/self-learn-studio.service"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    touch "$HOME/Library/LaunchAgents/com.self-learn.studio.plist"
  fi
}

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
  check "web env mode is 600"           sh -c "[ \"$(stat -c %a "$(REPO_DIR)/apps/web/.env.local" 2>/dev/null || stat -f %Lp "$(REPO_DIR)/apps/web/.env.local")\" = 600 ]"
  check "catalog env mode is 600"       sh -c "[ \"$(stat -c %a "$(REPO_DIR)/services/catalog/.env" 2>/dev/null || stat -f %Lp "$(REPO_DIR)/services/catalog/.env")\" = 600 ]"
  check "compose up invoked"            [ -f "$STATE_DIR/compose_up" ]
  check "catalog migrated"              calls_have "npm run catalog -- migrate"
  check "seed imported"                 calls_have "npm run catalog -- import seed"
  check "six flips run"                 sh -c '[ "$(grep -c "npm run catalog -- flip" "$CALLS_LOG")" -eq 6 ]'
  check "blob root claimed"             calls_have "npm run catalog -- blob audit --fix"
  check "bootstrap marker written"      [ -f "$HOME/services/self-learn/state/db-bootstrapped" ]
  check "built (next build)"            calls_have "npm run build"
  check "built sha recorded"            grep -qx aaa1111 "$HOME/services/self-learn/state/built-sha"
  check "tldrawkc not fetched"          no_call "submodule update"
  if [ "$OS" = "Linux" ]; then
    check "app unit written"            [ -f "$HOME/.config/systemd/user/self-learn.service" ]
    check "app binds loopback+port"     grep -q -- "-p 8107 -H 127.0.0.1" "$HOME/.config/systemd/user/self-learn.service"
    check "deploy timer written"        [ -f "$HOME/.config/systemd/user/self-learn-deploy.timer" ]
    check "export timer written"        [ -f "$HOME/.config/systemd/user/self-learn-export.timer" ]
    check "studio unit written"         [ -f "$HOME/.config/systemd/user/self-learn-studio.service" ]
    check "studio runs npm studio"      grep -q "npm run studio" "$HOME/.config/systemd/user/self-learn-studio.service"
    check "studio claude bin baked"     grep -q "STUDIO_CLAUDE_BIN=$STUBS/claude" "$HOME/.config/systemd/user/self-learn-studio.service"
    check "studio home outside repo"    grep -q "STUDIO_HOME=$HOME/services/self-learn/studio" "$HOME/.config/systemd/user/self-learn-studio.service"
    check "app restarted"               calls_have "systemctl --user restart self-learn"
    check "deploy timer enabled"        calls_have "systemctl --user enable --now self-learn-deploy.timer"
    check "export timer enabled"        calls_have "systemctl --user enable --now self-learn-export.timer"
    check "studio off by default"       calls_have "systemctl --user disable --now self-learn-studio"
    check "export unit mode is 600"     sh -c "[ \"$(stat -c %a "$HOME/.config/systemd/user/self-learn-export.service" 2>/dev/null || stat -f %Lp "$HOME/.config/systemd/user/self-learn-export.service")\" = 600 ]"
    check "lingering enabled"           calls_have "loginctl enable-linger"
  else
    check "web agent written"           [ -f "$HOME/Library/LaunchAgents/com.self-learn.web.plist" ]
    check "studio agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.studio.plist" ]
    check "deploy agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist" ]
    check "export agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.export.plist" ]
    check "deploy agent sets PATH"      grep -q "/opt/homebrew/bin" "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist"
    check "web agent loaded"            calls_have "launchctl bootstrap gui/.*/com.self-learn.web"
    check "studio agent not loaded"     no_call "launchctl bootstrap .*com.self-learn.studio"
    local a
    for a in web deploy export; do
      check "$a label enabled before bootstrap (undoes teardown's disable)" \
        before "launchctl enable gui/.*/com.self-learn.$a" "launchctl bootstrap .*com.self-learn.$a"
    done
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
  if [ "$OS" = "Linux" ]; then
    check "app stopped first"     calls_have "systemctl --user stop self-learn.service"
    check "app started again"     calls_have "systemctl --user start self-learn.service"
  else
    check "app stopped first"     calls_have "launchctl bootout gui/.*/com.self-learn.web"
    check "app started again"     calls_have "launchctl \(bootstrap\|kickstart\).*com.self-learn.web"
  fi
  check "rebuilt"                 calls_have "npm run build"
  check "catalog migrated"        calls_have "npm run catalog -- migrate"
  check "npm ci skipped"          no_call "npm ci"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/self-learn/state/built-sha"
  teardown
}

test_lockfile_change_triggers_ci() {
  echo "• poller: lockfile change on the new commit -> npm ci runs"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # The new commit's fixture makes `git reset --hard` actually change the
  # checkout — proves deploy reads the lockfile it pulled, not the old tree.
  mkdir -p "$STATE_DIR/fixture/bbb2222"
  echo "fake-lockfile-v2" > "$STATE_DIR/fixture/bbb2222/package-lock.json"
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "checkout has new lockfile"  grep -qx "fake-lockfile-v2" "$(REPO_DIR)/package-lock.json"
  check "npm ci ran"                 calls_have "npm ci"
  check "rebuilt"                    calls_have "npm run build"
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
  if [ "$OS" = "Linux" ]; then
    check "no stop attempted" no_call "systemctl --user stop self-learn"
    check "not restarted"     no_call "systemctl --user start self-learn"
  else
    check "no stop attempted" no_call "launchctl bootout"
    check "not restarted"     no_call "launchctl \(bootstrap\|kickstart\).*com.self-learn.web"
  fi
  check "postgres left up"    no_call "compose --project-directory .* stop$"
  check "says it was left"    out_has "left stopped"
  teardown
}

test_stopped_stack_stays_stopped() {
  echo "• poller: app + Postgres both stopped -> updated, both left stopped"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  rm -f "$STATE_DIR/web_active" "$STATE_DIR/db_running"
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "rebuilt"                  calls_have "npm run build"
  check "catalog migrated"         calls_have "npm run catalog -- migrate"
  check "postgres put back down"   calls_have "compose --project-directory .* stop$"
  check "db marked down again"     [ ! -f "$STATE_DIR/db_running" ]
  if [ "$OS" = "Linux" ]; then
    check "app not restarted"      no_call "systemctl --user start self-learn"
  else
    check "app not restarted"      no_call "launchctl \(bootstrap\|kickstart\).*com.self-learn.web"
  fi
  teardown
}

test_poll_lock() {
  echo "• poller: a live owner's lock skips; a dead owner's lock is reclaimed"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/self-learn/.deploy.lock"
  echo $$ > "$HOME/services/self-learn/.deploy.lock/pid"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "reports the skip"       out_has "another deploy is running"
  check "touched no git"         no_call "fetch --quiet"
  rm -rf "$HOME/services/self-learn/.deploy.lock"
  mkdir "$HOME/services/self-learn/.deploy.lock"
  ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null || true
  echo "$dead" > "$HOME/services/self-learn/.deploy.lock/pid"
  : > "$CALLS_LOG"
  run_poll
  check "reclaims a dead lock"   out_has "owner pid $dead is gone"
  check "deploy proceeds"        calls_have "fetch --quiet"
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

test_persisted_https_port() {
  echo "• re-run: a persisted HTTPS_PORT != LOCAL_PORT is not clobbered"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=8443
  run_deploy
  check "served on :8443"        calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8107"
  check "PUBLIC_URL says :8443"  env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8443"
  unset HTTPS_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "still served on :8443"  calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8107"
  check "not regressed to :8107" no_call "tailscale serve --bg --https=8107"
  teardown
}

test_setup_leaves_stopped() {
  echo "• re-run: a deliberately stopped app is updated but not restarted"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  rm -f "$STATE_DIR/web_active" "$STATE_DIR/db_running"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "says it left it stopped" out_has "leaving it stopped"
  check "postgres put back down"  calls_have "compose --project-directory .* stop$"
  check "serve still configured"  calls_have "tailscale serve --bg --https=8107"
  check "no health checks"        no_call "^curl "
  if [ "$OS" = "Linux" ]; then
    check "app not restarted"     no_call "systemctl --user restart self-learn"
    check "app not enabled"       no_call "systemctl --user enable self-learn$"
  else
    check "agent not loaded"      no_call "launchctl bootstrap .*com.self-learn.web.plist"
  fi
  teardown
}

test_studio_enabled() {
  echo "• STUDIO_ENABLED=1: runner unit enabled+started, health-probed; flip to 0 stops it"
  setup
  touch "$STATE_DIR/operator"
  export STUDIO_ENABLED=1
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check ".env keeps the flag"     env_has "STUDIO_ENABLED=1"
  check "web env has the flag"    grep -qx "STUDIO_ENABLED=1" "$(REPO_DIR)/apps/web/.env.local"
  check "tldrawkc fetched"        calls_have "submodule update --init tools/tldrawkc"
  check "tldrawkc built+stamped"  [ -f "$HOME/services/self-learn/state/tldrawkc-sha" ]
  if [ "$OS" = "Linux" ]; then
    check "studio enabled"        calls_have "systemctl --user enable self-learn-studio"
    check "studio restarted"      calls_have "systemctl --user restart self-learn-studio"
    check "no disable call"       no_call "systemctl --user disable --now self-learn-studio"
  else
    check "studio agent loaded"   calls_have "launchctl bootstrap gui/.*/com.self-learn.studio"
    check "plist has claude bin"  grep -q "STUDIO_CLAUDE_BIN" "$HOME/Library/LaunchAgents/com.self-learn.studio.plist"
  fi
  check "studio health probed"  calls_have "curl .*127.0.0.1:7250/api/health"

  sed -i.bak 's/^STUDIO_ENABLED=1/STUDIO_ENABLED=0/' "$SVC/.env" && rm -f "$SVC/.env.bak"
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"       [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "studio disabled+stopped" calls_have "systemctl --user disable --now self-learn-studio"
  else
    check "studio agent booted out" calls_have "launchctl bootout gui/.*/com.self-learn.studio"
  fi
  teardown
}

test_deploy_bounces_studio() {
  echo "• poller: a running studio runner is stopped+restarted with the app"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # The unit is written on every install; simulate a runner that came up after
  # setup (flag flipped on, or a manual start) and must survive the deploy.
  touch "$STATE_DIR/studio_active"
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "studio stopped"        calls_have "systemctl --user stop self-learn-studio.service"
    check "studio started again"  calls_have "systemctl --user start self-learn-studio.service"
  else
    check "studio stopped"        calls_have "launchctl bootout gui/.*/com.self-learn.studio"
    check "studio started again"  calls_have "launchctl \(bootstrap\|kickstart\).*com.self-learn.studio"
  fi
  teardown
}

test_flag_change_redeploys() {
  echo "• poller: a feature-flag change redeploys even with no new commit"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  run_poll
  check "unchanged flags: up to date" out_has "up to date"
  check "unchanged flags: no build"   no_call "npm run build"
  echo "STUDIO_ENABLED=1" >> "$SVC/.env"   # sourced last, so it wins
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "redeploys the same commit"   out_has "deploying aaa1111"
  check "web env has the new flag"    grep -qx "STUDIO_ENABLED=1" "$(REPO_DIR)/apps/web/.env.local"
  check "tldrawkc built for it"       [ -f "$(TL_DIR)/dist/marker" ]
  : > "$CALLS_LOG"
  run_poll
  check "settled: up to date again"   out_has "up to date"
  teardown
}

test_tldrawkc_failed_build_restores() {
  echo "• poller: a failed tldrawkc build puts the previous build back"
  setup
  touch "$STATE_DIR/operator"
  export STUDIO_ENABLED=1
  run_deploy
  echo "old" > "$(TL_DIR)/dist/marker"
  touch "$STATE_DIR/studio_active"
  echo "bbb2222" > "$STATE_DIR/remote_sha"     # the stub answers tldrawkc's rev-parse from this too
  touch "$STATE_DIR/tldrawkc_build_fails"
  : > "$CALLS_LOG"
  run_poll
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says it restored"            out_has "restoring the previous tldrawkc build"
  check "previous dist/ is back"      grep -qx old "$(TL_DIR)/dist/marker"
  check "no half-written dist/"       test ! -e "$(TL_DIR)/dist/partial"
  check "node_modules is back"        [ -d "$(TL_DIR)/node_modules" ]
  check "stamp still the old build"   grep -qx aaa1111 "$HOME/services/self-learn/state/tldrawkc-sha"
  check "snapshot cleaned up"         test ! -e "$HOME/services/self-learn/state/rollback-tldrawkc"
  if [ "$OS" = "Linux" ]; then
    check "studio restarted"          calls_have "systemctl --user start self-learn-studio.service"
  else
    check "studio restarted"          calls_have "launchctl \(bootstrap\|kickstart\).*com.self-learn.studio"
  fi
  teardown
}

test_tldrawkc_rebuilt_when_output_is_gone() {
  echo "• poller: tldrawkc is rebuilt when dist/ is gone, even if the stamp matches"
  setup
  touch "$STATE_DIR/operator"
  export STUDIO_ENABLED=1
  run_deploy
  check "stamped after the first build" grep -qx aaa1111 "$HOME/services/self-learn/state/tldrawkc-sha"
  rm -rf "$(TL_DIR)/dist" "$(TL_DIR)/node_modules"
  : > "$CALLS_LOG"
  run_poll --force
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "dist/ rebuilt"               [ -f "$(TL_DIR)/dist/marker" ]
  check "node_modules reinstalled"    [ -d "$(TL_DIR)/node_modules" ]
  teardown
}

test_deploy_leaves_stopped_studio() {
  echo "• poller: a stopped studio runner is updated but left stopped"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "rebuilt"                 calls_have "npm run build"
  if [ "$OS" = "Linux" ]; then
    check "studio not stopped"    no_call "stop self-learn-studio"
    check "studio not started"    no_call "start self-learn-studio"
  else
    check "studio untouched"      no_call "launchctl \(bootout\|bootstrap\|kickstart\).*com.self-learn.studio"
  fi
  teardown
}

test_deploy_pinned_sha() {
  echo "• rollback: deploy.sh --sha pins the build to an older commit"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  run_poll --sha ccc0000
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the pinned sha"  out_has "deploying ccc0000"
  check "resets to the pin"       calls_have "reset --hard --quiet ccc0000"
  check "built sha is the pin"    grep -qx ccc0000 "$HOME/services/self-learn/state/built-sha"
  teardown
}

test_failed_build_restores() {
  echo "• poller: failed build restores the snapshot and restarts the old build"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/remote_sha"
  touch "$STATE_DIR/build_fails"
  : > "$CALLS_LOG"
  run_poll
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says it restored"        out_has "restoring the pre-deploy snapshot"
  check ".next put back"          [ -d "$(REPO_DIR)/apps/web/.next" ]
  check "built sha unchanged"     grep -qx aaa1111 "$HOME/services/self-learn/state/built-sha"
  if [ "$OS" = "Linux" ]; then
    check "old build restarted"   calls_have "systemctl --user start self-learn.service"
  else
    check "old build restarted"   calls_have "launchctl \(bootstrap\|kickstart\).*com.self-learn.web"
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

test_sync_install() {
  echo "• sync install: account, library, ignore file, daemon unit"
  setup; mk_env; mk_seafile_env
  run_sync install
  if [ "$OS" != "Linux" ]; then
    check "refuses off-Linux" [ "$CODE" -ne 0 ]
    check "points at mac-setup" out_has "mac-setup"
    teardown; return
  fi
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "created the account"   calls_have "api/v2.1/admin/users"
  check "created the library"   calls_have "api2/repos"
  check "linked library"        calls_have "seaf-cli sync -l stub-repo-777"
  check "links blobs/local"     calls_have " -d $HOME/.self-learn/blobs/local"
  check "ignore has .owner"     grep -q '^/.owner$' "$HOME/.self-learn/blobs/local/seafile-ignore.txt"
  check "ignore has .tmp"       grep -q '^/.tmp$' "$HOME/.self-learn/blobs/local/seafile-ignore.txt"
  check "creds persisted"       env_has "SEAFILE_SYNC_REPO=stub-repo-777"
  check "env stays 600"         test "$(stat -c %a "$SVC/.env" 2>/dev/null || stat -f %Lp "$SVC/.env")" = 600
  check "unit written"          test -f "$HOME/.config/systemd/user/self-learn-seafile.service"
  check "unit enabled"          calls_have "systemctl --user enable self-learn-seafile.service"
  check "unit restarted"        calls_have "systemctl --user restart self-learn-seafile.service"
  check "daemon is the process" grep -q "ExecStart=.*seaf-daemon" "$HOME/.config/systemd/user/self-learn-seafile.service"
  check "unit restarts"         grep -q "Restart=always" "$HOME/.config/systemd/user/self-learn-seafile.service"
  check "admin pw not in argv"  no_call "adminpw"
  check "sync pw not in argv"   no_call " -p "
  teardown
}

test_sync_install_idempotent() {
  echo "• sync install re-run: existing account/library untouched"
  [ "$OS" = "Linux" ] || return 0
  setup; mk_env; mk_seafile_env
  cat >> "$SVC/.env" <<EOF
SEAFILE_URL=http://127.0.0.1:8081
SEAFILE_SYNC_USER=self-learn-sync@test
SEAFILE_SYNC_PASSWORD=pw
SEAFILE_SYNC_REPO=stub-repo-777
EOF
  run_sync install
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "no account create"   no_call "api/v2.1/admin/users"
  check "no repo create"      no_call "api2/repos"
  check "still links library" calls_have "seaf-cli sync -l stub-repo-777"
  teardown
}

test_sync_install_old_layout() {
  echo "• sync install: library synced to blobs/ root refuses, names the fix"
  [ "$OS" = "Linux" ] || return 0
  setup; mk_env; mk_seafile_env
  cat >> "$SVC/.env" <<EOF
SEAFILE_URL=http://127.0.0.1:8081
SEAFILE_SYNC_USER=self-learn-sync@test
SEAFILE_SYNC_PASSWORD=pw
SEAFILE_SYNC_REPO=stub-repo-777
EOF
  touch "$STATE_DIR/seaf_synced_stub-repo-777"
  echo "$HOME/.self-learn/blobs" > "$STATE_DIR/seaf_path_stub-repo-777"
  run_sync install
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "says desync"         out_has "desync"
  check "no new link"         no_call "seaf-cli sync -l stub-repo-777"
  teardown
}

test_sync_install_already_linked() {
  echo "• sync install: repo already on blobs/local is left alone"
  [ "$OS" = "Linux" ] || return 0
  setup; mk_env; mk_seafile_env
  cat >> "$SVC/.env" <<EOF
SEAFILE_URL=http://127.0.0.1:8081
SEAFILE_SYNC_USER=self-learn-sync@test
SEAFILE_SYNC_PASSWORD=pw
SEAFILE_SYNC_REPO=stub-repo-777
EOF
  touch "$STATE_DIR/seaf_synced_stub-repo-777"
  echo "$HOME/.self-learn/blobs/local" > "$STATE_DIR/seaf_path_stub-repo-777"
  run_sync install
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "no relink"           no_call "seaf-cli sync -l stub-repo-777"
  teardown
}

test_sync_mac_setup_gui() {
  echo "• sync mac-setup: ignore file lands first, GUI steps printed"
  setup; mk_env; mk_seafile_env
  cat >> "$SVC/.env" <<EOF
SEAFILE_SYNC_USER=self-learn-sync@test
SEAFILE_SYNC_PASSWORD=pw
SEAFILE_SYNC_REPO=stub-repo-777
EOF
  run_sync mac-setup
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "remote ignore written"   grep -q '^/.owner$' "$STATE_DIR/mac_ignore.txt"
  check "ignore covers .tmp"      grep -q '^/.tmp$' "$STATE_DIR/mac_ignore.txt"
  check "prints GUI steps"        out_has "Seafile Client"
  check "prints the account"      out_has "self-learn-sync@test"
  check "prints tailnet URL"      out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_sync_mac_setup_headless() {
  echo "• sync mac-setup: seaf-cli on the Mac pairs headless + LaunchAgent"
  setup; mk_env; mk_seafile_env
  cat >> "$SVC/.env" <<EOF
SEAFILE_SYNC_USER=self-learn-sync@test
SEAFILE_SYNC_PASSWORD=pw
SEAFILE_SYNC_REPO=stub-repo-777
EOF
  echo "/nix/store/seafile/bin/seaf-cli" > "$STATE_DIR/mac_seaf_cli"
  run_sync mac-setup
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "remote seaf-cli sync"  calls_have "seaf-cli' sync -l 'stub-repo-777'"
  check "remote links blobs/local" calls_have "-d '/Users/kaichen/.self-learn/blobs/local'"
  check "creates LaunchAgents first" calls_have "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.self-learn.seafile.plist"
  check "plist runs daemon"     grep -q "seaf-daemon" "$STATE_DIR/mac_plist.xml"
  check "agent keeps it alive"  grep -q "KeepAlive" "$STATE_DIR/mac_plist.xml"
  check "agent bootstrapped"    calls_have "launchctl bootstrap"
  teardown
}

test_sync_push() {
  echo "• sync push: dump server db, restore it on the Mac"
  setup; mk_env; mk_psql_canned
  mkdir -p "$HOME/services/self-learn/repo"
  run_sync push
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "dumped locally"      calls_have "docker exec -i self-learn-db pg_dump -Fc -U catalog self_learn"
  check "scp to mac"          calls_have "scp .*-p .*self_learn-sync.dump"
  check "not staged in /tmp"  no_call ":/tmp/"
  check "drop sent"           grep -q "DROP DATABASE" "$STATE_DIR/mac_sql.log"
  check "createdb on mac"     calls_have "createdb"
  check "restore on mac"      calls_have "pg_restore --no-owner"
  check "owner rewritten"     grep -q '"self_learn:33692"' "$STATE_DIR/mac_owner.txt"
  check "mac audit ran"       calls_have "npm run catalog -- blob audit"
  check "vault warned"        out_has "vault"
  check "dump cleaned"        test ! -f "$HOME/services/self-learn/state/self_learn-push.dump"
  teardown
}

test_sync_pull() {
  echo "• sync pull: dump Mac db, restore here, app restarted"
  setup; mk_env; mk_psql_canned
  mkdir -p "$HOME/services/self-learn/repo"
  touch "$STATE_DIR/web_active" "$STATE_DIR/db_running"
  run_sync pull
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "remote dump"         calls_have "pg_dump -Fc"
  check "scp back"            calls_have "scp .*-p .*self_learn-sync.dump"
  check "app stopped"         calls_have "systemctl --user stop self-learn.service"
  check "compose up"          calls_have "compose --project-directory .* up -d"
  check "drop sent locally"   grep -q "DROP DATABASE" "$STATE_DIR/local_sql.log"
  check "local restore"       calls_have "pg_restore --no-owner"
  check "owner rewritten"     grep -q '"self_learn:16384"' "$HOME/.self-learn/blobs/.owner"
  check "audit ran"           calls_have "npm run catalog -- blob audit"
  check "app restarted"       calls_have "systemctl --user start self-learn.service"
  check "postgres left up"    no_call "compose --project-directory .* stop$"
  teardown
}

test_sync_pull_studio() {
  echo "• sync pull: a running studio runner is stopped before the restore and restarted after"
  setup; mk_env; mk_psql_canned; mk_studio_unit
  mkdir -p "$HOME/services/self-learn/repo"
  touch "$STATE_DIR/web_active" "$STATE_DIR/db_running" "$STATE_DIR/studio_active"
  run_sync pull
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "restore ran"                 calls_have "pg_restore --no-owner"
  if [ "$OS" = "Linux" ]; then
    check "studio stopped"            calls_have "systemctl --user stop self-learn-studio.service"
    check "studio started again"      calls_have "systemctl --user start self-learn-studio.service"
    check "studio stops before the app" \
      [ "$(call_line 'stop self-learn-studio.service')" -lt "$(call_line 'stop self-learn.service')" ]
    check "studio starts after the app" \
      [ "$(call_line 'start self-learn.service')" -lt "$(call_line 'start self-learn-studio.service')" ]
  else
    check "studio stopped"            calls_have "launchctl bootout gui/.*/com.self-learn.studio"
    check "studio started again"      calls_have "launchctl \(bootstrap\|kickstart\).*com.self-learn.studio"
  fi
  check "studio is up at the end"     test -f "$STATE_DIR/studio_active"
  teardown
}

test_sync_pull_stopped_studio() {
  echo "• sync pull: a stopped studio runner is left stopped"
  setup; mk_env; mk_psql_canned; mk_studio_unit
  mkdir -p "$HOME/services/self-learn/repo"
  touch "$STATE_DIR/web_active" "$STATE_DIR/db_running"
  run_sync pull
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "restore ran"                 calls_have "pg_restore --no-owner"
  check "studio never stopped"        no_call "stop self-learn-studio"
  check "studio never started"        no_call "start self-learn-studio"
  teardown
}

test_sync_pull_stopped_app() {
  echo "• sync pull: a stopped app is restored without being started"
  setup; mk_env; mk_psql_canned
  mkdir -p "$HOME/services/self-learn/repo"
  run_sync pull
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "restore ran"         calls_have "pg_restore --no-owner"
  check "no stop call"        no_call "systemctl --user stop self-learn.service"
  check "no start call"       no_call "systemctl --user start self-learn.service"
  check "postgres back down"  calls_have "compose --project-directory .* stop$"
  check "db marker gone"      test ! -f "$STATE_DIR/db_running"
  teardown
}

test_sync_push_locked() {
  echo "• sync push: a live deploy/sync lock refuses to run"
  setup; mk_env; mk_psql_canned
  mkdir "$HOME/services/self-learn/.deploy.lock"
  echo $$ > "$HOME/services/self-learn/.deploy.lock/pid"
  run_sync push
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "says why"            out_has "deploy or sync is running"
  check "no dump taken"       no_call "pg_dump"
  teardown
}

test_sync_push_pg_fails() {
  echo "• sync push: a failed local dump ships nothing"
  setup; mk_env; mk_psql_canned
  touch "$STATE_DIR/pg_fails"
  run_sync push
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "says why"            out_has "pg_dump failed"
  check "nothing shipped"     no_call "scp"
  teardown
}

test_sync_status() {
  echo "• sync status: both sides tabled; unreachable Mac degrades"
  setup; mk_env; mk_psql_canned
  run_sync status
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "server section"      out_has "SERVER"
  check "mac section"         out_has "MAC"
  check "server rows"         out_has "asset.*42"
  check "mac rows"            out_has "asset.*40"
  check "mac client noted"    out_has "seaf"
  teardown
}

test_sync_status_unreachable() {
  echo "• sync status: unreachable Mac reports cleanly"
  setup; mk_env; mk_psql_canned
  touch "$STATE_DIR/mac_unreachable"
  run_sync status
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "server still shown"  out_has "SERVER"
  check "says unreachable"    out_has "unreachable"
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
  live_check "web .env.local is 600"       test "$(stat -c %a "$svc_home/repo/apps/web/.env.local" 2>/dev/null || stat -f %Lp "$svc_home/repo/apps/web/.env.local")" = 600
  live_check "catalog .env is 600"         test "$(stat -c %a "$svc_home/repo/services/catalog/.env" 2>/dev/null || stat -f %Lp "$svc_home/repo/services/catalog/.env")" = 600
  live_check "bootstrap marker exists"     test -f "$svc_home/state/db-bootstrapped"
  # The runner is only expected up when the flag is on — an enabled-but-dead
  # studio is a finding, a disabled one is not.
  local studio_flag
  studio_flag="$(sed -n 's/^STUDIO_ENABLED=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  if [ "$studio_flag" = "1" ]; then
    live_check "studio health answers"     curl -fsS "http://127.0.0.1:7250/api/health"
    live_check "no wildcard studio listener" no_external_listener 7250
    if [ "$OS" = "Linux" ]; then
      live_check "studio unit active"      sh -c "systemctl --user is-active self-learn-studio.service | grep -qx active"
      live_check "studio unit enabled"     sh -c "systemctl --user is-enabled self-learn-studio.service | grep -qx enabled"
    else
      live_check "studio agent loaded"     sh -c "launchctl print gui/$(id -u)/com.self-learn.studio"
    fi
  fi
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

SVC_HOME() { printf '%s' "$HOME/services/self-learn"; }
UNIT_DIR() { printf '%s' "$HOME/.config/systemd/user"; }
# Point SERVICE_HOME in .env somewhere else (odd-path tests).
set_service_home() { sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$1#" "$SVC/.env"; }
# Two call lines in order (both present, first before second).
before() {
  local a b; a="$(call_line "$1")"; b="$(call_line "$2")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
# Nothing a teardown changes happened.
untouched() {
  [ ! -f "$STATE_DIR/compose_down" ] && no_call " off" \
    && no_call "systemctl --user disable" && no_call "launchctl bootout" \
    && no_call "launchctl disable" \
    && [ -f "$SVC/.env" ]
}

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# neighbours sit on other ports (one a lookalike suffix), the studio has
# state and a nightly export has landed.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(SVC_HOME)/studio/jobs" "$HOME/.self-learn/archive/latest" "$HOME/.self-learn/vault"
  echo wal > "$(SVC_HOME)/studio/jobs/wal"
  echo export > "$HOME/.self-learn/archive/latest/catalog.json"
  echo blob > "$HOME/.self-learn/blobs/b1"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8107 (tailnet only)
|-- / proxy http://127.0.0.1:8107

https://test-host.tailfake.ts.net:18107 (tailnet only)
|-- / proxy http://127.0.0.1:18107
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove stops timers, studio, app, then Postgres; keeps data"
  deployed
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "serve off for :8107"           calls_have "tailscale serve --https=8107 off"
  check "neighbour :2283 untouched"     no_call "https=2283"
  check "lookalike :18107 untouched"    no_call "https=18107"
  check "never serve reset"             no_call "serve reset"
  check "compose down"                  [ -f "$STATE_DIR/compose_down" ]
  check "down keeps the volume (no -v)" [ -z "$(cat "$STATE_DIR/compose_down" 2>/dev/null)" ]
  if [ "$OS" = "Linux" ]; then
    check "deploy timer disabled"       calls_have "systemctl --user disable --now self-learn-deploy.timer"
    check "export timer disabled"       calls_have "systemctl --user disable --now self-learn-export.timer"
    check "in-flight deploy stopped"    calls_have "systemctl --user stop self-learn-deploy.service"
    check "in-flight export stopped"    calls_have "systemctl --user stop self-learn-export.service"
    check "studio disabled"             calls_have "systemctl --user disable --now self-learn-studio.service"
    check "app disabled"                calls_have "systemctl --user disable --now self-learn.service"
    check "timers before studio"        before "disable --now self-learn-export.timer" "disable --now self-learn-studio.service"
    check "studio before app"           before "disable --now self-learn-studio.service" "disable --now self-learn.service"
    check "app before Postgres"         before "disable --now self-learn.service" "compose --project-directory .* down"
    check "app inactive"                [ ! -f "$STATE_DIR/web_active" ]
    check "unit files kept"             [ -f "$(UNIT_DIR)/self-learn.service" ] && [ -f "$(UNIT_DIR)/self-learn-deploy.timer" ]
    check "no daemon-reload"            no_call "daemon-reload"
  else
    check "web agent unloaded"          calls_have "launchctl bootout gui/.*/com.self-learn.web"
    check "deploy before web"           before "bootout gui/.*/com.self-learn.deploy" "bootout gui/.*/com.self-learn.web"
    local a
    for a in deploy export studio web; do
      check "$a agent disabled (no reload at login)" calls_have "launchctl disable gui/.*/com.self-learn.$a"
    done
  fi
  check "clone kept"                    [ -d "$(REPO_DIR)/.git" ]
  check "state kept"                    [ -f "$(SVC_HOME)/state/built-sha" ]
  check "studio state kept"             [ -f "$(SVC_HOME)/studio/jobs/wal" ]
  check "exports kept"                  [ -f "$HOME/.self-learn/archive/latest/catalog.json" ]
  check ".env kept"                     [ -f "$SVC/.env" ]
  check "torn-down marker written"      [ -f "$(SVC_HOME)/state/torn-down" ]
  check "says how to bring it back"     out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_then_setup_restores() {
  echo "• teardown then ./setup.sh: the stack comes back up (not read as a deliberate stop)"
  deployed
  run_teardown
  : > "$CALLS_LOG"
  run_deploy
  check "setup exits zero"              [ "$CODE" -eq 0 ]
  check "not left stopped"              out_lacks "leaving it stopped"
  check "marker consumed"               [ ! -f "$(SVC_HOME)/state/torn-down" ]
  check "postgres up again"             [ -f "$STATE_DIR/db_running" ]
  if [ "$OS" = "Linux" ]; then
    check "app restarted"               calls_have "systemctl --user restart self-learn"
    check "timers re-enabled"           calls_have "systemctl --user enable --now self-learn-deploy.timer"
  fi
  check "serve republished"             calls_have "tailscale serve --bg --https=8107"
  # A later plain stop is the owner's again.
  rm -f "$STATE_DIR/web_active" "$STATE_DIR/db_running"
  : > "$CALLS_LOG"
  run_deploy
  check "next stop respected again"     out_has "leaving it stopped"
  teardown
}

test_teardown_then_start_and_stop() {
  echo "• teardown, then Start+Stop (launcher/phone/manual): the stop reads as the owner's again"
  deployed
  run_teardown
  check "marker written"                [ -f "$(SVC_HOME)/state/torn-down" ]
  # What the launcher's Start button does: the stubs run the unit's
  # ExecStartPre / the agent's ProgramArguments, which clear the marker.
  if [ "$OS" = "Linux" ]; then
    check "unit clears marker on start" grep -q '^ExecStartPre=-/bin/rm -f .*/state/torn-down' "$(UNIT_DIR)/self-learn.service"
    PATH="$STUBS:$PATH" systemctl --user start self-learn.service >/dev/null
    check "start consumed the marker"   [ ! -f "$(SVC_HOME)/state/torn-down" ]
    PATH="$STUBS:$PATH" systemctl --user stop self-learn.service >/dev/null
  else
    check "agent clears marker on load" grep -qF 'rm -f "$1"; exec "$2" run start' "$HOME/Library/LaunchAgents/com.self-learn.web.plist"
    check "agent passes marker path"    grep -q '<string>.*/state/torn-down</string>' "$HOME/Library/LaunchAgents/com.self-learn.web.plist"
    PATH="$STUBS:$PATH" launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.self-learn.web.plist" >/dev/null
    check "load consumed the marker"    [ ! -f "$(SVC_HOME)/state/torn-down" ]
    PATH="$STUBS:$PATH" launchctl bootout "gui/$(id -u)/com.self-learn.web" >/dev/null
  fi
  : > "$CALLS_LOG"
  run_deploy
  check "setup exits zero"              [ "$CODE" -eq 0 ]
  check "stop stays stopped"            out_has "leaving it stopped"
  check "marker stays gone"             [ ! -f "$(SVC_HOME)/state/torn-down" ]
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no serve off"                  no_call " off"
  check "says already off"              out_has "already off"
  check "still compose down"            [ -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8107 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no serve off"                  no_call " off"
  check "says nothing points here"      out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay; studio/pg never"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8107

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8107

https://test-host.tailfake.ts.net:7250 (tailnet only)
|-- / proxy http://127.0.0.1:7250

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /learn proxy http://127.0.0.1:8107
EOF
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ":8110 off"                     calls_have "serve --https=8110 off"
  check ":8443 off"                     calls_have "serve --https=8443 off"
  check "unrelated :7250 left alone"    no_call "https=7250"
  check "shared :443 left on"           no_call "https=443 off"
  check "warns about the shared port"   out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says why"                      out_has "Could not read Tailscale Serve status"
  check "nothing changed"               untouched
  check "no torn-down marker"           [ ! -f "$(SVC_HOME)/state/torn-down" ]
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"       [ "$CODE" -ne 0 ]
  check "no .env: explains"             out_has "nothing to tear down"
  check "no .env: touched nothing"      [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"          [ "$CODE" -ne 0 ]
  check "root: touched nothing"         untouched
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: touched nothing" untouched
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"     [ "$CODE" -ne 0 ]
  check "no docker: touched nothing"    untouched
  rm -f "$STATE_DIR/docker_no_perm"
  sed -i.bak '/^SERVICE_HOME=/d' "$SVC/.env"
  run_teardown
  check "no SERVICE_HOME: exits non-zero" [ "$CODE" -ne 0 ]
  check "no SERVICE_HOME: touched nothing" untouched
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8107'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"        [ "$CODE" -eq 0 ]
  check ":8107 off"                     calls_have "serve --https=8107 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8107"/' "$SVC/.env"
  run_teardown
  check "double quotes"                 [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8107 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"                [ "$CODE" -eq 0 ]
  check "  :8107 off"                   calls_have "serve --https=8107 off"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SERVICE_HOME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"               out_has "SERVICE_HOME is set more than once"
  check "  touched nothing"             untouched
  teardown
  deployed
  printf 'X="first\nSERVICE_HOME=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"      out_has "does not close on its line"
  teardown
  deployed
  printf 'Y="a\\"b"\n' >> "$SVC/.env"
  run_teardown
  check "backslash escape: exits non-zero" [ "$CODE" -ne 0 ]
  check "  touched nothing"             untouched
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME / ... in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "self-learn"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  touched nothing"           untouched
    check "  state kept"                [ -d "$(SVC_HOME)/state" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  touched nothing"             untouched
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then volume, state, units, .env and marker go"
  deployed
  mkdir -p "$(UNIT_DIR)"; echo keep > "$(UNIT_DIR)/neighbour.service"
  run_teardown --purge "self-lear"
  check "wrong name: exits non-zero"    [ "$CODE" -ne 0 ]
  check "wrong name: nothing changed"   untouched
  check "wrong name: state kept"        [ -f "$(SVC_HOME)/state/built-sha" ]
  check "wrong name: no marker written" [ ! -f "$(SVC_HOME)/state/torn-down" ]
  run_teardown --purge "self-learn"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns where the exports are"   out_has "$HOME/.self-learn/archive"
  check "serve off for :8107"           calls_have "tailscale serve --https=8107 off"
  check "down -v (volume dropped)"      [ "$(cat "$STATE_DIR/compose_down" 2>/dev/null)" = "-v" ]
  check "clone gone"                    [ ! -e "$(REPO_DIR)" ]
  check "bin gone"                      [ ! -e "$(SVC_HOME)/bin" ]
  check "state gone"                    [ ! -e "$(SVC_HOME)/state" ]
  check "studio state gone"             [ ! -e "$(SVC_HOME)/studio" ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  check "marker dir gone"               [ ! -e "$(SVC_HOME)" ]
  check "services dir itself kept"      [ -d "$HOME/services" ]
  check "exports kept"                  [ -f "$HOME/.self-learn/archive/latest/catalog.json" ]
  check "blobs kept"                    [ -f "$HOME/.self-learn/blobs/b1" ]
  check "vault kept"                    [ -d "$HOME/.self-learn/vault" ]
  check "repo files kept"               [ -f "$SVC/docker-compose.yml" ] && [ -f "$SVC/setup.sh" ]
  if [ "$OS" = "Linux" ]; then
    local u
    for u in self-learn.service self-learn-studio.service self-learn-deploy.service \
             self-learn-deploy.timer self-learn-export.service self-learn-export.timer; do
      check "unit $u gone"              [ ! -e "$(UNIT_DIR)/$u" ]
    done
    check "neighbour unit kept"         [ -f "$(UNIT_DIR)/neighbour.service" ]
    check "daemon-reload after"         before "compose --project-directory .* down" "systemctl --user daemon-reload"
  fi
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: state already gone is fine"
  deployed
  rm -rf "$(SVC_HOME)"
  run_teardown --purge "self-learn"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  check "down -v"                       [ "$(cat "$STATE_DIR/compose_down" 2>/dev/null)" = "-v" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a SERVICE_HOME outside ~/services/self-learn"
  deployed
  set_service_home "$HOME"
  run_teardown --purge "self-learn"
  check "\$HOME: exits non-zero"        [ "$CODE" -ne 0 ]
  check "  home untouched"              [ -d "$HOME/.self-learn" ]
  check "  nothing changed"             untouched
  set_service_home "$HOME/services/../x"
  run_teardown --purge "self-learn"
  check "'..' refused"                  [ "$CODE" -ne 0 ]
  set_service_home "$HOME/services/"
  run_teardown --purge "self-learn"
  check "services dir itself refused"   [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  local dotted
  for dotted in "$HOME/services/." "$HOME/services/./self-learn" "$HOME/services/self-learn/.."; do
    set_service_home "$dotted"
    run_teardown --purge "self-learn"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched"  [ -f "$HOME/services/neighbour/keep" ]
  check "state still there"             [ -f "$(SVC_HOME)/state/built-sha" ]
  check "nothing changed at all"        untouched
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  set_service_home "$HOME/services//"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "self-learn"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "neighbour data kept"           [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  set_service_home "$HOME/services/alias"
  run_teardown --purge "self-learn"
  check "symlink to services refused"   [ "$CODE" -ne 0 ]
  check "neighbour still kept"          [ -f "$HOME/services/neighbour/keep" ]
  check "nothing changed"               untouched
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  sed -i.bak 's#^SERVICE_HOME=.*#SERVICE_HOME="${HOME}/services/self-learn"#' "$SVC/.env"
  run_teardown --purge "self-learn"
  check "\${HOME} form: exits zero"     [ "$CODE" -eq 0 ]
  check "  state gone"                  [ ! -e "$(SVC_HOME)" ]
  teardown
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME='\$HOME/services/self-learn'#" "$SVC/.env"
  run_teardown --purge "self-learn"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  state kept"                  [ -f "$(SVC_HOME)/state/built-sha" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/self-learn itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour/state"; echo x > "$HOME/services/neighbour/state/keep"
  set_service_home "$HOME/services/neighbour"
  run_teardown --purge "self-learn"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"               [ -f "$HOME/services/neighbour/state/keep" ]
  check "  nothing changed"             untouched
  mkdir -p "$HOME/services/self-learn/a:b"
  set_service_home "$HOME/services/self-learn/a:b"
  run_teardown --purge "self-learn"
  check "a colon in the path refused"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/self-learn/state"; echo x > "$HOME/self-learn/state/keep"
  run_teardown --purge "self-learn"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"      [ -f "$HOME/self-learn/state/keep" ]
  check "nothing changed"               untouched
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/self-learn survives"
  deployed
  local repo="$HOME/services/self-learn/setup-server/services/self-learn"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/self-learn/setup-server/other.env"
  OUT="$(printf '%s\n' "self-learn" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "checkout intact"               [ -f "$repo/teardown.sh" ]
  check "other services' files kept"    [ -f "$HOME/services/self-learn/setup-server/other.env" ]
  check "state kept"                    [ -f "$(SVC_HOME)/state/built-sha" ]
  teardown
}

test_teardown_purge_symlinked_clone() {
  echo "• teardown --purge: a repo/ symlinked to a working clone in ~/dev is refused"
  deployed
  mkdir -p "$HOME/dev/self-learn"; echo mine > "$HOME/dev/self-learn/WORK"
  rm -rf "$(REPO_DIR)"; ln -s "$HOME/dev/self-learn" "$(REPO_DIR)"
  run_teardown --purge "self-learn"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "working clone intact"          [ -f "$HOME/dev/self-learn/WORK" ]
  check "nothing changed"               untouched
  check "state kept"                    [ -f "$(SVC_HOME)/state/built-sha" ]
  teardown
}

test_teardown_purge_keeps_self_learn_home() {
  echo "• teardown --purge: a SELF_LEARN_HOME inside a purged dir is refused"
  deployed
  mkdir -p "$(SVC_HOME)/state/blobs"
  sed -i.bak "s#^SELF_LEARN_HOME=.*#SELF_LEARN_HOME=$(SVC_HOME)/state/blobs#" "$SVC/.env"
  run_teardown --purge "self-learn"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says why"                      out_has "refusing to delete the blob store"
  check "nothing changed"               untouched
  teardown
}

test_teardown_foreign_sync_unit() {
  echo "• teardown: sync.sh's self-learn-seafile unit is never touched; purge refused while it exists"
  deployed
  mkdir -p "$(UNIT_DIR)" "$(SVC_HOME)/seafile/ccnet"
  echo unit > "$(UNIT_DIR)/self-learn-seafile.service"
  if [ "$OS" != "Linux" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    echo agent > "$HOME/Library/LaunchAgents/com.self-learn.seafile.plist"
  fi
  run_teardown --purge "self-learn"
  check "purge: exits non-zero"         [ "$CODE" -ne 0 ]
  check "purge: names the unit"         out_has "self-learn-seafile.service\|com.self-learn.seafile"
  check "purge: nothing changed"        untouched
  run_teardown
  check "default: exits zero"           [ "$CODE" -eq 0 ]
  check "default: warns, naming it"     out_has "Not touched (not created by setup.sh): .*seafile"
  check "unit never addressed"          no_call "seafile"
  check "unit file kept"                [ -f "$(UNIT_DIR)/self-learn-seafile.service" ]
  check "daemon state kept"             [ -d "$(SVC_HOME)/seafile/ccnet" ]
  teardown
}

test_teardown_purge_sync_credentials() {
  echo "• teardown --purge: refused while .env holds sync.sh's Seafile account"
  deployed
  printf '\n# --- blob/db sync (written by sync.sh install) ---\nSEAFILE_SYNC_USER=sync@x.local\nSEAFILE_SYNC_PASSWORD=pw\n' >> "$SVC/.env"
  run_teardown --purge "self-learn"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says why"                      out_has "SEAFILE_SYNC_USER"
  check "nothing changed"               untouched
  teardown
}

test_teardown_purge_keeps_unknown_entries() {
  echo "• teardown --purge: entries setup.sh did not create stay, and so does the marker"
  deployed
  mkdir -p "$(SVC_HOME)/seafile"; echo x > "$(SVC_HOME)/seafile/left"
  run_teardown --purge "self-learn"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "foreign entry kept"            [ -f "$(SVC_HOME)/seafile/left" ]
  check "state gone"                    [ ! -e "$(SVC_HOME)/state" ]
  check "warns the marker stayed"       out_has "is not empty"
  teardown
}

test_teardown_waits_for_lock() {
  echo "• teardown: a live deploy/sync lock stops it before anything changes; a stale one does not"
  deployed
  mkdir -p "$(SVC_HOME)/.deploy.lock"; echo $$ > "$(SVC_HOME)/.deploy.lock/pid"
  run_teardown
  check "live lock: exits non-zero"     [ "$CODE" -ne 0 ]
  check "  says why"                    out_has "holds .*deploy.lock"
  check "  nothing changed"             untouched
  check "  lock left to its owner"      [ "$(cat "$(SVC_HOME)/.deploy.lock/pid")" = "$$" ]
  rm -f "$(SVC_HOME)/.deploy.lock/pid"
  run_teardown
  check "fresh lock, no pid yet: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it is starting"         out_has "just starting"
  check "  nothing changed"             untouched
  echo 999999 > "$(SVC_HOME)/.deploy.lock/pid"
  run_teardown --purge "self-learn"
  check "stale lock: exits zero"        [ "$CODE" -eq 0 ]
  check "  lock purged with the rest"   [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  teardown
}

test_teardown_holds_lock() {
  echo "• teardown: takes the deploy lock for the run (mkdir + pid) and drops it on exit"
  deployed
  printf '%s' "$(SVC_HOME)/.deploy.lock" > "$STATE_DIR/lock_probe"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "lock held by a live pid during down" grep -q "^live " "$STATE_DIR/lock_at_down"
  check "lock gone after the run"       [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  mkdir -p "$(SVC_HOME)/.deploy.lock"; echo 999999 > "$(SVC_HOME)/.deploy.lock/pid"
  rm -f "$STATE_DIR/lock_at_down"
  run_teardown
  check "stale lock (dead pid), plain run: exits zero" [ "$CODE" -eq 0 ]
  check "  says it cleared it"          out_has "stale deploy lock"
  check "  taken over during down"      grep -q "^live " "$STATE_DIR/lock_at_down"
  check "  gone after the run"          [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  run_teardown --purge "self-lear"
  check "a run that dies (wrong name) exits non-zero" [ "$CODE" -ne 0 ]
  check "  still drops the lock"        [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  rm -f "$STATE_DIR/lock_at_down"
  run_teardown --purge "self-learn"
  check "purge: exits zero"             [ "$CODE" -eq 0 ]
  check "  lock held during down -v"    grep -q "^live " "$STATE_DIR/lock_at_down"
  check "  lock gone"                   [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  check "  marker dir gone (lock did not keep it)" [ ! -e "$(SVC_HOME)" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"
  ln -s "$HOME/elsewhere" "$(SVC_HOME)/.deploy.lock"
  run_teardown
  check "symlinked lock: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  check "  link left as it was"         [ -L "$(SVC_HOME)/.deploy.lock" ] && [ -d "$HOME/elsewhere" ]
  rm -f "$(SVC_HOME)/.deploy.lock"
  mkdir -p "$(SVC_HOME)/.deploy.lock"; echo 999999 > "$(SVC_HOME)/.deploy.lock/pid"
  echo mine > "$(SVC_HOME)/.deploy.lock/notes"
  run_teardown
  check "stale lock with other files: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  check "  its files kept"              [ -f "$(SVC_HOME)/.deploy.lock/notes" ]
  teardown
}

test_teardown_marker_refusals() {
  echo "• teardown: the torn-down marker is only written inside a real state dir, never through a link"
  deployed
  mkdir -p "$HOME/elsewhere"; echo precious > "$HOME/elsewhere/torn-down"
  rm -rf "$(SVC_HOME)/state"; ln -s "$HOME/elsewhere" "$(SVC_HOME)/state"
  run_teardown
  check "symlinked state/: exits zero"  [ "$CODE" -eq 0 ]
  check "  warns, no marker"            out_has "not writing the torn-down marker"
  check "  file behind the link intact" [ "$(cat "$HOME/elsewhere/torn-down")" = precious ]
  check "  still stopped Postgres"      [ -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"; echo precious > "$HOME/elsewhere/file"
  ln -s "$HOME/elsewhere/file" "$(SVC_HOME)/state/torn-down"
  run_teardown
  check "symlinked marker: exits zero"  [ "$CODE" -eq 0 ]
  check "  warns, no marker"            out_has "not writing the torn-down marker"
  check "  link target not truncated"   [ "$(cat "$HOME/elsewhere/file")" = precious ]
  check "  link left as it was"         [ -L "$(SVC_HOME)/state/torn-down" ]
  teardown
  deployed
  mkdir -p "$HOME/outside/state"; echo precious > "$HOME/outside/state/torn-down"
  set_service_home "$HOME/outside"
  run_teardown
  check "SERVICE_HOME outside ~/services/self-learn: exits zero" [ "$CODE" -eq 0 ]
  check "  warns, no marker"            out_has "not writing the torn-down marker"
  check "  file there not truncated"    [ "$(cat "$HOME/outside/state/torn-down")" = precious ]
  check "  no marker in the real state" [ ! -e "$(SVC_HOME)/state/torn-down" ]
  teardown
}

# ------------------------------------------------------------------ main
# A stub that isn't executable is skipped by PATH lookup and the REAL command
# runs — for ssh/scp that means the real Mac. Refuse to run rather than risk it.
for f in "$STUBS"/*; do
  [ -x "$f" ] || { red "stub not executable: $f — chmod +x it"; exit 1; }
done


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

test_teardown_unresolved_variable() {
  echo "• teardown: a path in .env that still names another variable is refused before anything changes"
  deployed
  # setup.sh sources .env, so to it this is state/content, inside a dir the
  # purge deletes; left literal, the keep-SELF_LEARN_HOME check tests nothing.
  mkdir -p "$(SVC_HOME)/state/content"; echo blob > "$(SVC_HOME)/state/content/b1"
  sed -i.bak 's#^SELF_LEARN_HOME=.*#SELF_LEARN_HOME=$SERVICE_HOME/state/content#' "$SVC/.env"
  run_teardown --purge "self-learn"
  check "SELF_LEARN_HOME=\$SERVICE_HOME/...: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                    out_has "SELF_LEARN_HOME .*still refers to another variable"
  check "  refused before the prompt"   out_lacks "to confirm"
  check "  content kept"                [ -f "$(SVC_HOME)/state/content/b1" ]
  check "  nothing changed"             untouched
  run_teardown
  check "plain run: exits non-zero"     [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  check "  no lock left behind"         [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  teardown
  deployed
  sed -i.bak 's#^SERVICE_HOME=.*#SERVICE_HOME="${HOME}/services/${NAME}"#' "$SVC/.env"
  run_teardown --purge "self-learn"
  check "SERVICE_HOME=...\${NAME}: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  teardown
}

test_teardown_lock_after_prompt() {
  echo "• teardown --purge: the deploy lock is taken after the typed confirmation, and re-checked then"
  local lock
  deployed
  lock="$(SVC_HOME)/.deploy.lock"
  printf '%s' "$lock" > "$STATE_DIR/lock_probe"
  run_purge_at_prompt "self-learn" "[ -e '$lock' ] && echo held > '$STATE_DIR/lock_at_prompt' || echo free > '$STATE_DIR/lock_at_prompt'"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "  lock not held while the prompt waits" grep -qx free "$STATE_DIR/lock_at_prompt"
  check "  held by a live pid during down -v" grep -q "^live " "$STATE_DIR/lock_at_down"
  teardown
  deployed
  lock="$(SVC_HOME)/.deploy.lock"
  run_purge_at_prompt "self-learn" "mkdir '$lock' && echo \$\$ > '$lock/pid'"
  check "a deploy/sync that starts during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says who holds it"           out_has "holds .*deploy.lock"
  check "  nothing changed"             untouched
  check "  lock left to its owner"      [ -f "$lock/pid" ]
  teardown
  deployed
  lock="$(SVC_HOME)/.deploy.lock"
  mkdir -p "$lock"; echo 999999 > "$lock/pid"
  run_purge_at_prompt "self-learn" "[ -f '$lock/pid' ] && echo kept > '$STATE_DIR/lock_at_prompt' || echo cleared > '$STATE_DIR/lock_at_prompt'"
  check "stale lock: exits zero"        [ "$CODE" -eq 0 ]
  check "  not cleared before the answer" grep -qx kept "$STATE_DIR/lock_at_prompt"
  check "  cleared after it"            out_has "Cleared a stale deploy lock"
  teardown
  deployed
  lock="$(SVC_HOME)/.deploy.lock"
  mkdir -p "$lock"; echo 999999 > "$lock/pid"
  run_teardown --purge "self-lear"
  check "wrong name with a stale lock: exits non-zero" [ "$CODE" -ne 0 ]
  check "  stale lock not touched (nothing changed)" [ "$(cat "$lock/pid")" = 999999 ]
  teardown
}

test_teardown_foreign_units_by_content() {
  echo "• teardown: a unit/agent whose contents name ~/services/self-learn is listed, never touched; purge refused"
  # teardown scans the unit dir on Linux and ~/Library/LaunchAgents on
  # macOS, so the fixture goes where this OS's branch looks.
  local dir job other ext=""
  deployed
  if [ "$OS" = "Linux" ]; then
    dir="$(UNIT_DIR)"; job="nightly-backup.service"; other="unrelated.service"
  else
    dir="$HOME/Library/LaunchAgents"; job="com.me.nightly-backup"; other="com.me.unrelated"; ext=".plist"
  fi
  mkdir -p "$dir"
  printf '[Service]\nExecStart=/usr/bin/rsync -a %s/services/self-learn/studio/ /backup/\n' "$HOME" \
    > "$dir/$job$ext"
  printf '[Service]\nExecStart=/bin/true\n' > "$dir/$other$ext"
  run_teardown --purge "self-learn"
  check "purge: exits non-zero"         [ "$CODE" -ne 0 ]
  check "  names it"                    out_has "$job"
  check "  nothing changed"             untouched
  run_teardown
  check "default: exits zero"           [ "$CODE" -eq 0 ]
  check "  warns, naming it"            out_has "Not touched (not created by setup.sh): $job"
  check "  unrelated not named"         out_lacks "$other"
  check "  never addressed"             no_call "nightly-backup"
  check "  unit kept"                   [ -f "$dir/$job$ext" ]
  teardown
}

test_teardown_purge_rechecked_after_lock() {
  echo "• teardown --purge: targets are worked out again once the lock is held; a change during the prompt deletes nothing"
  local dir job ext=""
  deployed
  rm -rf "$(REPO_DIR)"
  run_purge_at_prompt "self-learn" "mkdir -p '$(REPO_DIR)/.git'"
  check "repo/ recreated during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says the list changed"       out_has "changed while the prompt waited"
  check "  nothing changed"             untouched
  check "  state kept"                  [ -f "$(SVC_HOME)/state/built-sha" ]
  check "  lock dropped"                [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"; echo precious > "$HOME/elsewhere/keep"
  run_purge_at_prompt "self-learn" "rm -rf '$(SVC_HOME)/studio' && ln -s '$HOME/elsewhere' '$(SVC_HOME)/studio'"
  check "studio/ swapped for a symlink: exits non-zero" [ "$CODE" -ne 0 ]
  check "  refuses the link"            out_has "studio is a symlink"
  check "  nothing changed"             untouched
  check "  link target kept"            [ -f "$HOME/elsewhere/keep" ]
  teardown
  deployed
  if [ "$OS" = "Linux" ]; then
    dir="$(UNIT_DIR)"; job="self-learn-seafile.service"
  else
    dir="$HOME/Library/LaunchAgents"; job="com.self-learn.seafile"; ext=".plist"
  fi
  run_purge_at_prompt "self-learn" "mkdir -p '$dir' && echo unit > '$dir/$job$ext'"
  check "blob link installed during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names it"                    out_has "--purge refused: $job"
  check "  nothing changed"             untouched
  check "  state kept"                  [ -f "$(SVC_HOME)/state/built-sha" ]
  teardown
}

# macOS branch on any box: FAKE_UNAME=Darwin makes teardown.sh take it, and
# $STATE_DIR/launchd/ gives the launchctl stub one loaded marker per label.
test_teardown_macos_agents() {
  echo "• teardown (macOS branch): only loaded agents are booted out; a failed unload stops before --purge deletes anything"
  local a
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$STATE_DIR/launchd"
  for a in deploy export web; do touch "$STATE_DIR/launchd/com.self-learn.$a"; done
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<string>%s/services/self-learn/bin/deploy.sh</string>\n' "$HOME" \
    > "$HOME/Library/LaunchAgents/com.me.backup.plist"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  for a in deploy export web; do
    check "loaded $a agent booted out"  calls_have "launchctl bootout gui/.*/com.self-learn.$a"
  done
  check "studio (not loaded) not booted out" no_call "launchctl bootout gui/.*/com.self-learn.studio"
  for a in deploy export studio web; do
    check "$a agent disabled"           calls_have "launchctl disable gui/.*/com.self-learn.$a"
  done
  check "deploy before web"             before "bootout gui/.*/com.self-learn.deploy" "bootout gui/.*/com.self-learn.web"
  check "no systemctl"                  no_call "systemctl"
  check "agent named by contents"       out_has "Not touched (not created by setup.sh): com.me.backup"
  teardown
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$STATE_DIR/launchd"; touch "$STATE_DIR/launchd/com.self-learn.web"
  touch "$STATE_DIR/launchd_bootout_fails"
  run_teardown --purge "self-learn"
  check "bootout fails, agent still loaded: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                     out_has "Could not unload LaunchAgent com.self-learn.web"
  check "  Postgres left up (no down -v)" [ ! -f "$STATE_DIR/compose_down" ]
  check "  state kept"                  [ -f "$(SVC_HOME)/state/built-sha" ]
  check "  .env kept"                   [ -f "$SVC/.env" ]
  check "  lock dropped"                [ ! -e "$(SVC_HOME)/.deploy.lock" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$STATE_DIR/launchd"; touch "$STATE_DIR/launchd/com.self-learn.web"
  echo async > "$STATE_DIR/launchd_bootout_fails"
  run_teardown
  check "bootout errors but the agent unloads: exits zero" [ "$CODE" -eq 0 ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$STATE_DIR/launchd"
  touch "$STATE_DIR/launchd_disable_fails"
  run_teardown --purge "self-learn"
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it would reload"        out_has "would load again at the next login"
  check "  state kept"                  [ -f "$(SVC_HOME)/state/built-sha" ]
  check "  .env kept"                   [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  mkdir -p "$STATE_DIR/launchd"
  run_teardown --purge "self-learn"
  check "purge on macOS: exits zero"    [ "$CODE" -eq 0 ]
  check "  state gone"                  [ ! -e "$(SVC_HOME)/state" ]
  check "  no daemon-reload"            no_call "daemon-reload"
  teardown
}

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
test_stopped_stack_stays_stopped
test_poll_lock
test_skip_seed
test_port_override
test_persisted_https_port
test_setup_leaves_stopped
test_studio_enabled
test_deploy_bounces_studio
test_deploy_leaves_stopped_studio
test_flag_change_redeploys
test_tldrawkc_failed_build_restores
test_tldrawkc_rebuilt_when_output_is_gone
test_deploy_pinned_sha
test_failed_build_restores
test_operator_escalation
test_serve_approval_pause
test_sync_install
test_sync_install_idempotent
test_sync_install_old_layout
test_sync_install_already_linked
test_sync_mac_setup_gui
test_sync_mac_setup_headless
test_sync_push
test_sync_pull
test_sync_pull_studio
test_sync_pull_stopped_studio
test_sync_pull_stopped_app
test_sync_push_locked
test_sync_push_pg_fails
test_sync_status
test_sync_status_unreachable
test_teardown_safe
test_teardown_then_setup_restores
test_teardown_then_start_and_stop
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_quoted_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge
test_teardown_purge_missing_data_dir
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_purge_symlinked_clone
test_teardown_purge_keeps_self_learn_home
test_teardown_foreign_sync_unit
test_teardown_purge_sync_credentials
test_teardown_purge_keeps_unknown_entries
test_teardown_waits_for_lock
test_teardown_holds_lock
test_teardown_marker_refusals
test_teardown_unresolved_variable
test_teardown_lock_after_prompt
test_teardown_foreign_units_by_content
test_teardown_purge_rechecked_after_lock
test_teardown_macos_agents

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
