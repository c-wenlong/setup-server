#!/usr/bin/env bash
#
# Tests for services/coolify/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other Docker services: the real script runs from a
# sandbox copy with PATH stubs for docker/tailscale/curl/sudo/id.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
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
  unset FAKE_UID LOCAL_PORT HTTPS_PORT SOKETI_PORT HTTPS_SOKETI_PORT
  unset ROOT_USERNAME ROOT_USER_EMAIL STATE_DIR CALLS_LOG
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
out_lacks()  { ! grep -qi "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }

# Ports mappings only — SOKETI_HOST=0.0.0.0 is an in-container listen.
no_host_wildcard_port() {
  ! awk '
    /^[[:space:]]*ports:[[:space:]]*$/ { p=1; next }
    p && /^[[:space:]]*-[[:space:]]*/ {
      if ($0 ~ /0\.0\.0\.0/) { found=1 }
      next
    }
    p && /^[[:space:]]*[^[:space:]#-]/ { p=0 }
    END { exit found ? 0 : 1 }
  ' "$SVC/docker-compose.yml"
}

data_dir() { sed -n 's/^COOLIFY_DATA=//p' "$SVC/.env"; }

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "regular user"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "started no container" [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when the user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests usermod fix" out_has "usermod -aG docker"
  else
    check "suggests Docker Desktop" out_has "Docker Desktop"
  fi
  check "wrote no .env" [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Tailscale is not up"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_bad_port() {
  echo "• preflight rejects non-numeric ports"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "HTTPS_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "HTTPS_PORT: says numeric"   out_has "must be numeric"
  unset HTTPS_PORT
  export LOCAL_PORT=81o1
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, published tailnet-only, admin seeded"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env generated"                  [ -f "$SVC/.env" ]
  check ".env is mode 600"                [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env names the admin user"       grep -qE '^ROOT_USERNAME=.+$' "$SVC/.env"
  check ".env has a mixed-class password" grep -qE '^ROOT_USER_PASSWORD=.{8,}$' "$SVC/.env"
  check ".env has an APP_KEY"             grep -qE '^APP_KEY=base64:' "$SVC/.env"
  check ".env records the local port"     grep -qx 'LOCAL_PORT=8101' "$SVC/.env"
  check "pinned to 4.3.21"                grep -qx 'COOLIFY_VERSION=4.3.21' "$SVC/.env"
  check "auto-update is off"              grep -qx 'AUTOUPDATE=false' "$SVC/.env"
  check "APP_URL is the tailnet URL"      grep -q '^APP_URL=https://test-host\.tailfake\.ts\.net:8101$' "$SVC/.env"
  check "compose binds dashboard loopback" compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose binds soketi loopback"    compose_hasF '127.0.0.1:${SOKETI_PORT'
  check "compose publishes no host wildcard" no_host_wildcard_port
  check "data dir created"                [ -d "$(data_dir)" ]
  check "compose up invoked"              [ -f "$STATE_DIR/compose_up" ]
  check "waited on /api/health"           calls_have "127.0.0.1:8101/api/health"
  check "served dashboard :8101"          calls_have "tailscale serve --bg --https=8101 http://127.0.0.1:8101"
  check "served soketi :6001"             calls_have "tailscale serve --bg --https=6001 http://127.0.0.1:6001"
  check "no sudo needed (operator set)"   no_call "^sudo "
  check "prints final URL"                out_has "https://test-host.tailfake.ts.net:8101"
  check "warns about Traefik :80/:443"    out_has "Traefik"
  check "SSH key written"                 [ -f "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal" ]
  check "pubkey landed in authorized_keys" grep -q coolify "$HOME/.ssh/authorized_keys"
  teardown
}

test_open_register_fails() {
  echo "• first-run registration still open: setup dies, does not publish"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/register_open"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the open form"        out_has "first-run admin form"
  check "did not serve the dashboard" no_call "tailscale serve --bg --https=8101"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8105 HTTPS_PORT=8105
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8105' "$SVC/.env"
  check "APP_URL uses the new port"  grep -qx 'APP_URL=https://test-host.tailfake.ts.net:8105' "$SVC/.env"
  check "health-checked :8105"       calls_have "127.0.0.1:8105/api/health"
  check "served :8105 -> :8105"      calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
  check "prints the :8105 URL"       out_has "https://test-host.tailfake.ts.net:8105"

  export LOCAL_PORT=8106 HTTPS_PORT=8105
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8106 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8105' "$SVC/.env"
  check "re-run: still serves :8105" calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
  check "re-run: never touched 8106" no_call "127.0.0.1:8106"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8110
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=8110"   grep -qx 'LOCAL_PORT=8110' "$SVC/.env"
  check "served :8110 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8110 http://127.0.0.1:8110"
  check "  and never :8101"              no_call "tailscale serve --bg --https=8101"
  check "prints the :8110 URL"           out_has "https://test-host.tailfake.ts.net:8110"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8110 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8110 http://127.0.0.1:8110"
  check "  and never :8101"                   no_call "tailscale serve --bg --https=8101"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8110 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8110"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loop waits instead of dying"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/health_fails_left"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "polled health repeatedly"   [ "$(grep -c '/api/health' "$CALLS_LOG")" -gt 3 ]
  check "still published"            calls_have "tailscale serve --bg --https=8101"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, SSH key not regenerated"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(sed -n 's/^ROOT_USER_PASSWORD=//p' "$SVC/.env")"
  key="$(data_dir)/ssh/keys/id.${USER}@host.docker.internal"
  key_copy="$SANDBOX/key.copy"
  cp "$key" "$key_copy"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "password unchanged"          [ "$(sed -n 's/^ROOT_USER_PASSWORD=//p' "$SVC/.env")" = "$pw" ]
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "SSH key not regenerated"     cmp -s "$key" "$key_copy"
  check "says the key is there"       out_has "SSH key already present"
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8101 http://127.0.0.1:8101"
  teardown
}

test_app_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  old="$(grep '^APP_URL=' "$SVC/.env")"
  export HTTPS_PORT=8102
  run_deploy
  check "warns about the drift"     out_has "APP_URL in .env is"
  check "spells out the fix"        out_has "APP_URL=https://test-host.tailfake.ts.net:8102"
  check ".env left alone (user's)"  [ "$(grep '^APP_URL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8101 http://127.0.0.1:8101"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n\n\n\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8101 http://127.0.0.1:8101"
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
  local port="$1" addrs addr host ts ts4 ts6
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  ts4="$("$ts" ip -4 2>/dev/null || true)"
  ts6="$("$ts" ip -6 2>/dev/null || true)"

  if command -v ss >/dev/null; then
    addrs="$(ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}')"
  else
    addrs="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
  fi
  [ -n "$addrs" ] || return 0

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
    case "$host" in
      127.0.0.1|::1|localhost) ;;
      *) [ -n "$ts4" ] && [ "$host" = "$ts4" ] && continue
         [ -n "$ts6" ] && [ "$host" = "$ts6" ] && continue
         return 1 ;;
    esac
  done <<EOF
$addrs
EOF
  return 0
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port soketi_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  soketi_port="$(sed -n 's/^SOKETI_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "coolify container running"   sh -c "docker inspect -f '{{.State.Status}}' coolify | grep -qx running"
  live_check "postgres container running"  sh -c "docker inspect -f '{{.State.Status}}' coolify-db | grep -qx running"
  live_check "redis container running"     sh -c "docker inspect -f '{{.State.Status}}' coolify-redis | grep -qx running"
  live_check "soketi container running"    sh -c "docker inspect -f '{{.State.Status}}' coolify-realtime | grep -qx running"
  live_check "local /api/health responds"  curl -fsS -o /dev/null "http://127.0.0.1:$port/api/health"
  live_check "not listening on non-local ifaces (dashboard)" no_external_listener "$port"
  live_check "not listening on non-local ifaces (soketi)"    no_external_listener "$soketi_port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS health responds" curl -fsS -o /dev/null --max-time 30 "$url:$https_port/api/health"
  live_check "state dir exists"            sh -c "test -d \"\$(sed -n 's/^COOLIFY_DATA=//p' '$SERVICE_DIR/.env')\""
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/coolify/setup.sh or services/coolify/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_open_register_fails
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_app_url_drift
test_operator_escalation
test_serve_approval_prompt

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
