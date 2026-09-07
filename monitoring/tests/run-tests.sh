#!/usr/bin/env bash
#
# Tests for monitoring/setup.sh (Uptime Kuma + ntfy).
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SERVICE_DIR/seed_kuma.py" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID KUMA_PORT NTFY_PORT KUMA_HTTPS_PORT NTFY_HTTPS_PORT STATE_DIR CALLS_LOG
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

test_fresh_deploy() {
  echo "• fresh deploy: full happy path"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has admin password"     sh -c "grep -E '^KUMA_ADMIN_PASSWORD=.+' '$SVC/.env' >/dev/null"
  check ".env is mode 600"            sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has ntfy base url"      env_has "NTFY_BASE_URL=https://test-host.tailfake.ts.net:3003"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  check "seed attempted via uv"       calls_have "uv run --with uptime-kuma-api"
  check "kuma served on :3002"        calls_have "tailscale serve --bg --https=3002 http://127.0.0.1:3002"
  check "ntfy served on :3003"        calls_have "tailscale serve --bg --https=3003 http://127.0.0.1:3003"
  check "prints dashboard URL"        out_has "https://test-host.tailfake.ts.net:3002"
  check "prints phone setup hint"     out_has "install the ntfy app"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env (credentials) preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
KUMA_VOLUME=/tmp/k
NTFY_VOLUME=/tmp/n
KUMA_PORT=3002
NTFY_PORT=3003
NTFY_BASE_URL=https://x:3003
NTFY_TOPIC=alerts
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=my-custom-secret
EOF
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "existing .env untouched" env_has "my-custom-secret"
  check "never invoked sudo"      no_call "^sudo "
  teardown
}

test_port_override() {
  echo "• KUMA_PORT override flows through"
  setup
  touch "$STATE_DIR/operator"
  export KUMA_PORT=3012
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "served on :3012"       calls_have "tailscale serve --bg --https=3012 http://127.0.0.1:3012"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "both eventually published" sh -c "grep -c 'tailscale serve --bg --https=' '$CALLS_LOG' | grep -qv '^[01]$'"
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

# Fails only on wildcard binds (0.0.0.0 / [::] / *) = real LAN exposure.
# Tailscaled's own serve listener sits on the tailnet IP at the same port
# (local port == HTTPS port here) and is expected.
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
  local ts kport nport url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  kport="$(sed -n 's/^KUMA_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  nport="$(sed -n 's/^NTFY_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  live_check "kuma container running"     sh -c "docker inspect -f '{{.State.Status}}' uptime-kuma | grep -qx running"
  live_check "ntfy container running"     sh -c "docker inspect -f '{{.State.Status}}' ntfy | grep -qx running"
  live_check "kuma local responds"        curl -fsS "http://127.0.0.1:$kport/"
  live_check "ntfy local health"          sh -c "curl -fsS http://127.0.0.1:$nport/v1/health | grep -q healthy"
  live_check "kuma loopback-only"         no_external_listener "$kport"
  live_check "ntfy loopback-only"         no_external_listener "$nport"
  live_check "serve maps kuma :$kport"    sh -c "'$ts' serve status | grep -A2 ':$kport' | grep -q 'proxy http://127.0.0.1:$kport'"
  live_check "serve maps ntfy :$nport"    sh -c "'$ts' serve status | grep -A2 ':$nport' | grep -q 'proxy http://127.0.0.1:$nport'"
  live_check "kuma tailnet HTTPS"         curl -fsS -o /dev/null --max-time 30 "$url:$kport/"
  live_check "ntfy tailnet HTTPS"         curl -fsS -o /dev/null --max-time 30 "$url:$nport/v1/health"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
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
