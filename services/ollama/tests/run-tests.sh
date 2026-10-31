#!/usr/bin/env bash
#
# Tests for services/ollama/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (simulated fresh server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real scripts inside a sandbox: fake $HOME, and
# PATH stubs for curl/systemctl/loginctl/launchctl/sudo/id/uname/brew that log
# every call to $CALLS_LOG and keep state in $STATE_DIR. PATH is pinned to
# $STUBS:/usr/bin:/bin so the real box's binaries (e.g. a real
# /usr/local/bin/ollama) can never answer `command -v`. Nothing touches the
# real system — though setup.sh does run ../../lib/common.sh in place.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../setup.sh"    # run in place, so ../../lib/common.sh is the repo's own
TEARDOWN="$TESTS_DIR/../teardown.sh"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  mkdir -p "$HOME" "$STATE_DIR"
  : > "$CALLS_LOG"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_PATH"
  unset FAKE_UID FAKE_OS FAKE_ARCH EXTRA_PATH BREW_PREFIX \
        STATE_DIR CALLS_LOG
}

# A pinned PATH: stubs first, then bare /usr/bin:/bin so the host's real
# binaries (/usr/local/bin/ollama on this box, a real brew, ...) never leak
# in. EXTRA_PATH sits between the two for tests that plant a fake binary.
run_deploy() {
  OUT="$(printf '%s' "${1:-}" \
    | PATH="$STUBS${EXTRA_PATH:+:$EXTRA_PATH}:/usr/bin:/bin" \
      bash "$SCRIPT" 2>&1)"
  CODE=$?
}

run_teardown() {
  OUT="$(printf '%s' "${2:-}" \
    | PATH="$STUBS${EXTRA_PATH:+:$EXTRA_PATH}:/usr/bin:/bin" \
      bash "$TEARDOWN" "${1:-}" 2>&1)"
  CODE=$?
}

check() { # check <description> <condition...>
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

out_has()    { grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
eff_os()     { echo "${FAKE_OS:-$OS}"; }   # FAKE_OS=Darwin exercises the macOS branch from Linux

fake_binary() { # an "already installed" binary, findable on PATH or in ~/.local
  local dir="${1:-$SANDBOX/fakebin}"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho "ollama fake 8.8.8 (pre-existing)"\n' > "$dir/ollama"
  chmod +x "$dir/ollama"
}

# ----------------------------------------------------------------- tests
test_preflight_refuses_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "mentions regular user" out_has "regular user"
  teardown
}

test_fresh_install_downloads() {
  echo "• fresh install: official tarball -> ~/.local, user unit, loopback"
  setup
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  if [ "$(eff_os)" = "Linux" ]; then
    check "downloaded the tarball"  calls_have "curl.*ollama-linux-amd64.tgz\|curl.*ollama-linux-arm64.tgz"
    check "binary landed"           [ -x "$HOME/.local/bin/ollama" ]
  else
    check "brew installed it"       calls_have "brew install"
  fi
  check "models dir"            [ -d "$HOME/.ollama" ]
  check "installed sentinel"    [ -f "$HOME/.ollama/.managed" ]
  if [ "$(eff_os)" = "Linux" ]; then
    check "user unit written"       [ -f "$HOME/.config/systemd/user/ollama.service" ]
    check "unit runs our binary"    grep -q "ExecStart=$HOME/.local/bin/ollama serve" "$HOME/.config/systemd/user/ollama.service"
    check "unit binds loopback"     grep -q "OLLAMA_HOST=127.0.0.1:11434" "$HOME/.config/systemd/user/ollama.service"
    check "service restarted"       calls_have "systemctl --user restart ollama"
    check "lingering via sudo"      calls_have "sudo loginctl enable-linger"
  else
    check "plist written"           [ -f "$HOME/Library/LaunchAgents/ai.ollama.serve.plist" ]
    check "plist binds loopback"    grep -q "127.0.0.1:11434" "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
    check "LaunchAgent loaded"      calls_have "launchctl bootstrap"
  fi
  check "never published"         no_call "tailscale"
  check "healthy locally"         out_has "healthy locally"
  check "prints loopback-only"    out_has "deliberately not on Tailscale Serve"
  teardown
}

test_existing_binary_reused() {
  echo "• a binary already on PATH is reused, no download"
  setup
  fake_binary "$SANDBOX/fakebin"
  export EXTRA_PATH="$SANDBOX/fakebin"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "no download"           no_call "ollama-linux"
  if [ "$(eff_os)" = "Linux" ]; then
    check "unit runs that binary" grep -q "ExecStart=$SANDBOX/fakebin/ollama serve" \
                                   "$HOME/.config/systemd/user/ollama.service"
  else
    check "plist runs that binary" grep -q "$SANDBOX/fakebin/ollama" \
                                   "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  fi
  teardown
}

test_our_own_binary_wins() {
  echo "• ~/.local/bin/ollama beats a PATH one"
  setup
  fake_binary "$HOME/.local/bin"
  fake_binary "$SANDBOX/fakebin"
  export EXTRA_PATH="$SANDBOX/fakebin"
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  if [ "$(eff_os)" = "Linux" ]; then
    check "ours wins"  grep -q "ExecStart=$HOME/.local/bin/ollama serve" \
                        "$HOME/.config/systemd/user/ollama.service"
  else
    check "ours wins"  grep -q "$HOME/.local/bin/ollama" \
                        "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  fi
  teardown
}

test_retires_live_system_unit() {
  echo "• a live stock system unit is retired with sudo, once"
  setup
  fake_binary "$HOME/.local/bin"
  touch "$STATE_DIR/system_unit" "$STATE_DIR/system_enabled" "$STATE_DIR/system_active"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "sudo disable --now"      calls_have "sudo systemctl disable --now ollama.service"
  check "mentions the LAN bind"   out_has '\*:11434'
  check "user unit still started" calls_have "systemctl --user restart ollama"
  teardown
}

test_disabled_system_unit_needs_no_sudo() {
  echo "• an already-disabled system unit: no sudo, no second retirement"
  setup
  fake_binary "$HOME/.local/bin"
  touch "$STATE_DIR/system_unit"   # exists but neither enabled nor active
  touch "$STATE_DIR/linger"
  run_deploy
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "no sudo at all"         no_call "^sudo "
  check "reports already done"   out_has "already disabled"
  teardown
}

test_no_system_unit_is_clean_install() {
  echo "• no stock unit at all: migration block skipped entirely"
  setup
  fake_binary "$HOME/.local/bin"
  touch "$STATE_DIR/linger"
  run_deploy
  check "exits zero"         [ "$CODE" -eq 0 ]
  check "no sudo"            no_call "^sudo "
  check "no disable --now"   no_call "disable --now"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run for real: second run needs no sudo and no re-migration"
  setup
  fake_binary "$HOME/.local/bin"
  touch "$STATE_DIR/system_unit" "$STATE_DIR/system_enabled" "$STATE_DIR/system_active"
  run_deploy
  check "first run exits zero"  [ "$CODE" -eq 0 ]
  check "first run retired it"  calls_have "sudo systemctl disable --now ollama.service"
  : > "$CALLS_LOG"
  run_deploy
  check "second run exits zero" [ "$CODE" -eq 0 ]
  check "no sudo second time"   no_call "^sudo "
  check "no re-migration"       no_call "disable --now"
  check "no download"           no_call "ollama-linux"
  check "unit still restarted"  calls_have "systemctl --user restart ollama"
  teardown
}

test_health_timeout_dies() {
  echo "• health never comes up: exits non-zero with the log hint"
  setup
  fake_binary "$HOME/.local/bin"
  touch "$STATE_DIR/health_down"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "names the failure"    out_has "did not become healthy"
  teardown
}

# ---------------------------------------------------------------- macOS
test_darwin_fresh_install() {
  echo "• macOS (FAKE_OS=Darwin): brew install, LaunchAgent, loopback"
  setup
  export FAKE_OS=Darwin
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "brew installed it"     calls_have "brew install ollama"
  check "no tarball"            no_call "ollama-linux"
  check "plist written"         [ -f "$HOME/Library/LaunchAgents/ai.ollama.serve.plist" ]
  check "plist binds loopback"  grep -q "127.0.0.1:11434" "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  check "LaunchAgent loaded"    calls_have "launchctl bootstrap"
  check "no systemctl"          no_call "systemctl --user"
  check "healthy locally"       out_has "healthy locally"
  teardown
}

test_darwin_foreign_daemon_refuses() {
  echo "• macOS: a foreign daemon on :11434 fails the install, no false healthy"
  setup
  export FAKE_OS=Darwin
  touch "$STATE_DIR/launchd_not_loaded"   # our agent is not loaded; still /api/version answers
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "names the squatter" out_has "already served by another ollama"
  teardown
}

test_darwin_teardown() {
  echo "• macOS: teardown boots out the agent and deletes the plist"
  setup
  export FAKE_OS=Darwin
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.ollama/models"
  touch "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  run_teardown
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "agent booted out"    calls_have "launchctl bootout"
  check "plist deleted"       [ ! -e "$HOME/Library/LaunchAgents/ai.ollama.serve.plist" ]
  check "models kept"         [ -d "$HOME/.ollama/models" ]
  check "no systemctl"        no_call "systemctl"
  teardown
}

# --------------------------------------------------------------- teardown
test_teardown_stops_and_keeps() {
  echo "• teardown: unit disabled, models + binary kept"
  setup
  [ "$(eff_os)" = "Linux" ] || { teardown; return; }
  fake_binary "$HOME/.local/bin"
  mkdir -p "$HOME/.ollama/models" "$HOME/.config/systemd/user"
  touch "$HOME/.ollama/.managed"
  cat > "$HOME/.config/systemd/user/ollama.service" <<'EOF'
[Service]
ExecStart=fake
EOF
  run_teardown
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "unit stopped"          calls_have "systemctl --user stop ollama.service"
  check "unit disabled"         calls_have "systemctl --user disable ollama.service"
  check "unit file KEPT"        [ -f "$HOME/.config/systemd/user/ollama.service" ]
  check "models kept"           [ -d "$HOME/.ollama/models" ]
  check "installed marker gone" [ ! -e "$HOME/.ollama/.managed" ]
  check "binary kept"           [ -x "$HOME/.local/bin/ollama" ]
  check "points at --purge"     out_has "teardown.sh --purge"
  teardown
}

test_teardown_nothing_deployed() {
  echo "• teardown on a box with nothing: exits clean, changes nothing"
  setup
  run_teardown
  check "exits zero"        [ "$CODE" -eq 0 ]
  check "reports absence"   out_has "already removed\|not loaded"
  teardown
}

test_purge_wrong_confirmation() {
  echo "• --purge with a wrong name changes nothing"
  setup
  fake_binary "$HOME/.local/bin"
  mkdir -p "$HOME/.ollama/models" "$HOME/.config/systemd/user"
  touch "$HOME/.config/systemd/user/ollama.service"
  run_teardown --purge $'not-ollama\n'
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "says why"           out_has "Confirmation did not match"
  check "models kept"        [ -d "$HOME/.ollama/models" ]
  check "unit file kept"     [ -f "$HOME/.config/systemd/user/ollama.service" ]
  check "nothing stopped"    no_call "systemctl --user stop"
  teardown
}

test_teardown_stop_failure_dies() {
  echo "• teardown: a unit that will not stop fails the run, nothing purged"
  setup
  [ "$(eff_os)" = "Linux" ] || { teardown; return; }
  fake_binary "$HOME/.local/bin"
  mkdir -p "$HOME/.ollama/models" "$HOME/.config/systemd/user"
  touch "$HOME/.config/systemd/user/ollama.service" "$STATE_DIR/stop_fails"
  run_teardown
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "names the live unit" out_has "did not stop"
  check "unit file kept"      [ -f "$HOME/.config/systemd/user/ollama.service" ]
  check "models kept"         [ -d "$HOME/.ollama/models" ]
  check "never disabled"      no_call "systemctl --user disable"
  teardown
}

test_teardown_refuses_live_stock_unit() {
  echo "• teardown: no user unit but a live stock unit -> refuse, do not 'remove'"
  setup
  [ "$(eff_os)" = "Linux" ] || { teardown; return; }
  touch "$STATE_DIR/system_unit" "$STATE_DIR/system_active"
  run_teardown
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "points at setup"    out_has "run ./setup.sh to migrate"
  teardown
}

test_purge_deletes_models_and_unit() {
  echo "• --purge 'ollama': models + unit file gone, binary stays"
  setup
  [ "$(eff_os)" = "Linux" ] || { teardown; return; }
  fake_binary "$HOME/.local/bin"
  mkdir -p "$HOME/.ollama/models" "$HOME/.config/systemd/user"
  touch "$HOME/.config/systemd/user/ollama.service"
  run_teardown --purge $'ollama\n'
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "models deleted"      [ ! -e "$HOME/.ollama" ]
  check "unit file deleted"   [ ! -e "$HOME/.config/systemd/user/ollama.service" ]
  check "daemon reloaded"     calls_have "systemctl --user daemon-reload"
  check "binary kept + told"  out_has "rm -rf $HOME/.local/bin/ollama"
  teardown
}

test_purge_leaves_symlinked_models() {
  echo "• --purge: a symlinked ~/.ollama is never followed"
  setup
  fake_binary "$HOME/.local/bin"
  mkdir -p "$SANDBOX/real-models" "$HOME/.config/systemd/user"
  ln -s "$SANDBOX/real-models" "$HOME/.ollama"
  touch "$HOME/.config/systemd/user/ollama.service"
  run_teardown --purge $'ollama\n'
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "target untouched"    [ -d "$SANDBOX/real-models" ]
  check "symlink kept"        [ -L "$HOME/.ollama" ]
  check "said so"             out_has "symlink"
  teardown
}

# ------------------------------------------------------------------ live
live_check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

if [ "${1:-}" = "--live" ]; then
  echo
  echo "== live checks (real deployment on this machine)"
  if [ "$OS" = "Linux" ]; then
    live_check "user unit active"     sh -c "systemctl --user is-active ollama | grep -qx active"
    live_check "user unit enabled"    sh -c "systemctl --user is-enabled ollama | grep -qx enabled"
    live_check "lingering on"         sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
    live_check "stock unit retired"   sh -c "! systemctl is-active ollama.service 2>/dev/null | grep -qx active"
    live_check "stock unit disabled"  sh -c "! systemctl is-enabled ollama.service 2>/dev/null | grep -qx enabled"
    live_check "loopback only"        sh -c "ss -tln | grep -E '127\.0\.0\.1:11434' && ! ss -tln | grep -E '(\*|0\.0\.0\.0|\[::\]):11434'"
  else
    live_check "LaunchAgent loaded"   sh -c "launchctl print gui/$(id -u)/ai.ollama.serve"
  fi
  live_check "health endpoint"        curl -fsS "http://127.0.0.1:11434/api/version" -o /dev/null
  if [ "$OS" = "Linux" ]; then
    live_check "marker (unit file)"   test -f "$HOME/.config/systemd/user/ollama.service"
  else
    live_check "marker (plist)"       test -f "$HOME/Library/LaunchAgents/ai.ollama.serve.plist"
  fi
fi

# ----------------------------------------------------------------- driver
for t in $(declare -F | sed -n 's/^declare -f \(test_.*\)/\1/p' | sort); do "$t"; done

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL check(s) failed ($PASS passed)."
  exit 1
fi
