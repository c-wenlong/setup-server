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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/docker-compose.yml" \
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
  unset FAKE_UID LOCAL_PORT HTTPS_PORT PG_PORT REPO_URL BRANCH POLL_SECONDS \
    SKIP_SEED OWNER_PASSWORD AUTH_SECRET STATE_DIR CALLS_LOG \
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
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
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
  if [ "$OS" = "Linux" ]; then
    check "app unit written"            [ -f "$HOME/.config/systemd/user/self-learn.service" ]
    check "app binds loopback+port"     grep -q -- "-p 8107 -H 127.0.0.1" "$HOME/.config/systemd/user/self-learn.service"
    check "deploy timer written"        [ -f "$HOME/.config/systemd/user/self-learn-deploy.timer" ]
    check "export timer written"        [ -f "$HOME/.config/systemd/user/self-learn-export.timer" ]
    check "app restarted"               calls_have "systemctl --user restart self-learn"
    check "deploy timer enabled"        calls_have "systemctl --user enable --now self-learn-deploy.timer"
    check "export timer enabled"        calls_have "systemctl --user enable --now self-learn-export.timer"
    check "export unit mode is 600"     sh -c "[ \"$(stat -c %a "$HOME/.config/systemd/user/self-learn-export.service" 2>/dev/null || stat -f %Lp "$HOME/.config/systemd/user/self-learn-export.service")\" = 600 ]"
    check "lingering enabled"           calls_have "loginctl enable-linger"
  else
    check "web agent written"           [ -f "$HOME/Library/LaunchAgents/com.self-learn.web.plist" ]
    check "deploy agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist" ]
    check "export agent written"        [ -f "$HOME/Library/LaunchAgents/com.self-learn.export.plist" ]
    check "deploy agent sets PATH"      grep -q "/opt/homebrew/bin" "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist"
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
  check "ignore has .owner"     grep -q '^/.owner$' "$HOME/.self-learn/blobs/seafile-ignore.txt"
  check "ignore has .tmp"       grep -q '^/.tmp$' "$HOME/.self-learn/blobs/seafile-ignore.txt"
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
# A stub that isn't executable is skipped by PATH lookup and the REAL command
# runs — for ssh/scp that means the real Mac. Refuse to run rather than risk it.
for f in "$STUBS"/*; do
  [ -x "$f" ] || { red "stub not executable: $f — chmod +x it"; exit 1; }
done

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
test_deploy_pinned_sha
test_failed_build_restores
test_operator_escalation
test_serve_approval_pause
test_sync_install
test_sync_install_idempotent
test_sync_mac_setup_gui
test_sync_mac_setup_headless
test_sync_push
test_sync_pull
test_sync_pull_stopped_app
test_sync_push_locked
test_sync_push_pg_fails
test_sync_status
test_sync_status_unreachable

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
