#!/usr/bin/env bash
#
# Tests for n8n/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT OWNER_EMAIL OWNER_PASSWORD STATE_DIR CALLS_LOG
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
  export OWNER_EMAIL=kai@example.com OWNER_PASSWORD='Testpass123'
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check ".env has encryption key"      sh -c "grep -E '^N8N_ENCRYPTION_KEY=[0-9a-f]{64}$' '$SVC/.env' >/dev/null"
  check ".env is mode 600"             sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has owner creds"         env_has "OWNER_EMAIL=kai@example.com"
  check ".env has public URL"          env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:5678/"
  check "compose up invoked"           [ -f "$STATE_DIR/compose_up" ]
  check "owner setup API called"       calls_have "rest/owner/setup"
  check "served on tailscale :5678"    calls_have "tailscale serve --bg --https=5678 http://127.0.0.1:5678"
  check "prints final URL"             out_has "https://test-host.tailfake.ts.net:5678"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env (encryption key!) preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
N8N_VOLUME=/tmp/x
LOCAL_PORT=5678
PUBLIC_HOST=test-host.tailfake.ts.net
PUBLIC_URL=https://test-host.tailfake.ts.net:5678/
N8N_ENCRYPTION_KEY=my-precious-key
OWNER_EMAIL=x@y.z
OWNER_PASSWORD=Custom123
EOF
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "encryption key preserved"   env_has "my-precious-key"
  check "never invoked sudo"         no_call "^sudo "
  check "compose up re-invoked"      [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT override (HTTPS follows local by default)"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=5679
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "served on :5679 -> 5679" calls_have "tailscale serve --bg --https=5679 http://127.0.0.1:5679"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=5678"
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
  local ts port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="$(sed -n 's|^PUBLIC_URL=\(.*\)/$|\1|p' "$SERVICE_DIR/.env")"
  live_check "container running"       sh -c "docker inspect -f '{{.State.Status}}' n8n | grep -qx running"
  live_check "local healthz responds"  curl -fsS "http://127.0.0.1:$port/healthz"
  live_check "no wildcard listener"    no_external_listener "$port"
  live_check "owner is set up"         sh -c "curl -fsS http://127.0.0.1:$port/rest/settings | grep -o '\"showSetupOnFirstLoad\":[a-z]*' | grep -q false"
  live_check "serve maps :$port"       sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"  curl -fsS -o /dev/null --max-time 30 "$url/healthz"
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
