#!/usr/bin/env bash
#
# Tests for seafile/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed fake server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite copies setup.sh + docker-compose.yml into a sandbox and runs
# the real script there with PATH stubs for docker/tailscale/curl/sudo/id, so
# the repo never gets a test .env and the host system is never touched.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
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
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
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
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests usermod fix"   out_has "usermod -aG docker"
  else
    check "suggests Docker Desktop" out_has "Docker Desktop"
  fi
  check "wrote no .env"            [ ! -f "$SVC/.env" ]
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

test_preflight_bad_https_port() {
  echo "• preflight rejects a non-numeric HTTPS port"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "must be numeric"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has hostname with port"    env_has "SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:8443"
  check ".env has generated JWT key"     sh -c "grep -E '^JWT_PRIVATE_KEY=[0-9a-f]{64}$' '$SVC/.env' >/dev/null"
  check ".env has admin password"        sh -c "grep -E '^INIT_SEAFILE_ADMIN_PASSWORD=.+' '$SVC/.env' >/dev/null"
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]
  check "data dirs created under HOME"   [ -d "$HOME/services/seafile/data" ]
  check "served on tailscale :8443"      calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8081"
  check "prints final URL"               out_has "https://test-host.tailfake.ts.net:8443"
  check "prints admin credentials"       out_has "ADMIN_EMAIL"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env (secrets) preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:8443
INIT_SEAFILE_ADMIN_EMAIL=x@y.z
INIT_SEAFILE_ADMIN_PASSWORD=my-custom-secret
EOF
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "existing .env untouched"  env_has "my-custom-secret"
  check "says config untouched"    out_has "leaving untouched"
  check "never invoked sudo"       no_call "^sudo "
  check "compose up re-invoked"    [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT override"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9081 HTTPS_PORT=10000
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has custom local port"  env_has "LOCAL_PORT=9081"
  check "hostname carries 10000"      env_has "SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:10000"
  check "served on :10000 -> 9081"    calls_have "tailscale serve --bg --https=10000 http://127.0.0.1:9081"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published"    calls_have "tailscale serve --bg --https=8443"
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

# Portable: BSD (macOS) tools lack grep -P and ss.
no_external_listener() {
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | grep ":$port" | grep -v 127.0.0.1 | grep -q LISTEN)
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -v '^127\.0\.0\.1' | grep -q .)
  fi
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port hport url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  hport="$(sed -n 's/^SEAFILE_SERVER_HOSTNAME=.*:\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="https://$(sed -n 's/^SEAFILE_SERVER_HOSTNAME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "3 containers running"           sh -c "[ \"\$(docker compose --project-directory '$SERVICE_DIR' ps --status running -q | wc -l)\" -ge 3 ]"
  live_check "seafile container healthy"      sh -c "docker inspect -f '{{.State.Health.Status}}' seafile | grep -qx healthy"
  live_check "local web UI responds"          sh -c "curl -fsS -o /dev/null http://127.0.0.1:$port/"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$hport"   sh -c "'$ts' serve status | grep -A2 ':$hport' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"         curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_https_port
test_fresh_deploy
test_idempotent_rerun
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
