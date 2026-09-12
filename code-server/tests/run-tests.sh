#!/usr/bin/env bash
#
# Tests for code-server/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (simulated fresh server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real script inside a sandbox: fake $HOME, and PATH
# stubs for curl/tailscale/sudo/systemctl/loginctl/id that log every call to
# $CALLS_LOG and keep state (operator granted, lingering, forced serve
# failures) in $STATE_DIR. Nothing touches the real system.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../setup.sh"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
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
  unset FAKE_UID PORT STATE_DIR CALLS_LOG
}

# run_deploy [stdin-string] — runs the script under stubs; sets OUT and CODE
run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SCRIPT" 2>&1)"
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
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }

# ----------------------------------------------------------------- tests
test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "explains the problem"      out_has "Tailscale is not up"
  check "did not install anything"  [ ! -e "$HOME/.local/bin/code-server" ]
  teardown
}

test_preflight_refuses_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "mentions regular user" out_has "regular user"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path on a clean server"
  setup
  run_deploy
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check "installed fake code-server"        [ -x "$HOME/.local/bin/code-server" ]
  check "wrote config with default port"    grep -q "bind-addr: 127.0.0.1:8080" "$HOME/.config/code-server/config.yaml"
  check "config binds localhost only"       grep -q "bind-addr: 127.0.0.1" "$HOME/.config/code-server/config.yaml"
  if [ "$OS" = "Linux" ]; then
    check "wrote systemd unit"              [ -f "$HOME/.config/systemd/user/code-server.service" ]
    check "enabled + restarted service"     calls_have "systemctl --user restart code-server"
    check "enabled lingering via sudo"      calls_have "sudo loginctl enable-linger"
    check "granted operator via sudo"       calls_have "sudo tailscale set --operator="
  else
    check "wrote LaunchAgent plist"         [ -f "$HOME/Library/LaunchAgents/com.coder.code-server.plist" ]
    check "bootstrapped LaunchAgent"        calls_have "launchctl bootstrap"
  fi
  check "published via tailscale serve"     calls_have "tailscale serve --bg http://127.0.0.1:8080"
  check "prints final tailnet URL"          out_has "https://test-host.tailfake.ts.net"
  check "end-to-end check passed"           out_has "End-to-end check passed"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run on already-deployed server: no sudo, config preserved"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  mkdir -p "$HOME/.config/code-server"
  printf 'bind-addr: 127.0.0.1:8080\nauth: none\ncert: false\n# my-custom-marker\n' \
    > "$HOME/.config/code-server/config.yaml"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "config left untouched"         grep -q "my-custom-marker" "$HOME/.config/code-server/config.yaml"
  check "says config untouched"         out_has "leaving untouched"
  check "never invoked sudo"            no_call "^sudo "
  if [ "$OS" = "Linux" ]; then
    check "service still restarted"     calls_have "systemctl --user restart code-server"
  else
    check "LaunchAgent re-bootstrapped" calls_have "launchctl bootstrap"
  fi
  check "serve reapplied"               calls_have "tailscale serve --bg"
  teardown
}

test_port_override() {
  echo "• PORT=9000 override"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  export PORT=9000
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "config uses port 9000"    grep -q "bind-addr: 127.0.0.1:9000" "$HOME/.config/code-server/config.yaml"
  check "serve proxies port 9000"  calls_have "tailscale serve --bg http://127.0.0.1:9000"
  teardown
}

test_serve_approval_retry() {
  echo "• serve not yet enabled on tailnet: approval prompt + retry loop"
  setup
  echo 2 > "$STATE_DIR/serve_fails_left"   # fail twice, succeed on 3rd attempt
  run_deploy $'\n'                         # press Enter at the approval prompt
  check "exits zero after retry"     [ "$CODE" -eq 0 ]
  check "showed the approval prompt" out_has "one-time enablement"
  check "eventually published"       out_has "Tailscale Serve: HTTPS :443"
  [ "$OS" = "Linux" ] && check "granted operator on 1st failure" calls_have "sudo tailscale set --operator="
  teardown
}

# ------------------------------------------------------------ live suite
live_check() { # live_check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

# Portable helpers: BSD (macOS) tools lack grep -P and ss.
no_external_listener() { # fails if the port listens on a non-loopback address
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | grep ":$port" | grep -v 127.0.0.1 | grep -q LISTEN)
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -v '^127\.0\.0\.1' | grep -q .)
  fi
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^bind-addr: 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$HOME/.config/code-server/config.yaml")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  if [ "$OS" = "Linux" ]; then
    live_check "systemd service is active"      systemctl --user is-active code-server
    live_check "service is enabled at boot"     systemctl --user is-enabled code-server
    live_check "lingering is on (boot persist)" sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "LaunchAgent is loaded"          launchctl print "gui/$(id -u)/com.coder.code-server"
  fi
  live_check "local healthz responds"           curl -fsS "http://127.0.0.1:$port/healthz"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve config present"   sh -c "'$ts' serve status | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS healthz responds"   curl -fsS --max-time 30 "$url/healthz"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_tailscale_down
test_preflight_refuses_root
test_fresh_deploy
test_idempotent_rerun
test_port_override
test_serve_approval_retry

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
