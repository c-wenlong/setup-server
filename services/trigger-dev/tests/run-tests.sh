#!/usr/bin/env bash
#
# Tests for services/trigger-dev/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" \
     "$SERVICE_DIR/machine-presets.json" "$SVC/"
  cp -R "$SERVICE_DIR/clickhouse" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT REGISTRY_PORT ADMIN_EMAIL STATE_DIR CALLS_LOG
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
no_wildcard_bind() { ! compose_has '0\.0\.0\.0'; }
clickhouse_unpublished() {
  # ClickHouse must not have a host ports: block (HTTP 8123 is internal only).
  awk '/^  clickhouse:/{p=1; next} p && /^  [a-z]/{exit} p && $0 ~ /^    ports:/{found=1} END{exit found}' \
    "$SVC/docker-compose.yml"
}

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
  export LOCAL_PORT=80o0
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, stack up, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check "pinned to v4.6.0"                   grep -qx 'TRIGGER_IMAGE_TAG=v4.6.0' "$SVC/.env"
  check ".env records the local port"        grep -qx 'LOCAL_PORT=8030' "$SVC/.env"
  check "APP_ORIGIN is the tailnet URL"      grep -q '^APP_ORIGIN=https://test-host\.tailfake\.ts\.net:8030$' "$SVC/.env"
  check "LOGIN_ORIGIN matches"               grep -q '^LOGIN_ORIGIN=https://test-host\.tailfake\.ts\.net:8030$' "$SVC/.env"
  check "whitelists the admin email"         grep -q 'WHITELISTED_EMAILS=' "$SVC/.env"
  check "hex session secret"                 grep -qE '^SESSION_SECRET=[a-f0-9]{32}$' "$SVC/.env"
  check "hex encryption key (32 chars)"      grep -qE '^ENCRYPTION_KEY=[a-f0-9]{32}$' "$SVC/.env"
  check "hex postgres password"              grep -qE '^POSTGRES_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check "Node heap capped at 768"            grep -qx 'NODE_MAX_OLD_SPACE_SIZE=768' "$SVC/.env"
  check "telemetry disabled in compose"      compose_has 'TRIGGER_TELEMETRY_DISABLED'
  check "events stay in postgres"            compose_has 'EVENT_REPOSITORY_DEFAULT_STORE: *postgres'
  check "clickhouse present (boot requirement)" compose_has '^[[:space:]]*clickhouse:'
  check "clickhouse unpublished"             clickhouse_unpublished
  check "hex clickhouse password"            grep -qE '^CLICKHOUSE_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check "compose binds loopback webapp"      compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose binds loopback registry"    compose_hasF '127.0.0.1:${REGISTRY_PORT'
  check "compose binds no wildcard"          no_wildcard_bind
  check "shared dir created"                 [ -d "$HOME/services/trigger-dev/shared" ]
  check "postgres dir created"               [ -d "$HOME/services/trigger-dev/postgres" ]
  check "minio dir is world-writable"        [ "$(file_mode "$HOME/services/trigger-dev/minio")" = "777" ]
  check "htpasswd written"                   [ -s "$HOME/services/trigger-dev/registry/auth.htpasswd" ]
  check "htpasswd is mode 600"               [ "$(file_mode "$HOME/services/trigger-dev/registry/auth.htpasswd")" = "600" ]
  check "compose up invoked"                 [ -f "$STATE_DIR/compose_up" ]
  check "waited on /healthcheck"             calls_have "127.0.0.1:8030/healthcheck"
  check "requested a magic link"             [ -f "$STATE_DIR/magic_posts" ]
  check "printed the magic URL"              out_has "/magic"
  check "logged the host into the registry"  [ -f "$STATE_DIR/docker_login" ]
  check "worker token on disk"               [ -s "$HOME/services/trigger-dev/shared/worker_token" ]
  check "served on tailscale :8030"          calls_have "tailscale serve --bg --https=8030 http://127.0.0.1:8030"
  check "no sudo needed (operator set)"      no_call "^sudo "
  check "prints final URL"                   out_has "https://test-host.tailfake.ts.net:8030"
  check "mentions the CLI"                   out_has "npx trigger.dev"
  check "warns there is no backup here"      out_has "nothing backs this box up"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8031 HTTPS_PORT=8031
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env records the override"   grep -qx 'LOCAL_PORT=8031' "$SVC/.env"
  check "APP_ORIGIN uses the port"    grep -q '^APP_ORIGIN=https://test-host\.tailfake\.ts\.net:8031$' "$SVC/.env"
  check "health-checked :8031"        calls_have "127.0.0.1:8031/healthcheck"
  check "served :8031 -> :8031"       calls_have "tailscale serve --bg --https=8031 http://127.0.0.1:8031"
  check "prints the :8031 URL"        out_has "https://test-host.tailfake.ts.net:8031"

  export LOCAL_PORT=8032 HTTPS_PORT=8031
  run_deploy
  check "re-run: exits zero"          [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it"  out_has "LOCAL_PORT=8032 ignored"
  check "re-run: .env unchanged"      grep -qx 'LOCAL_PORT=8031' "$SVC/.env"
  check "re-run: still serves :8031"  calls_have "tailscale serve --bg --https=8031 http://127.0.0.1:8031"
  check "re-run: never touched 8032"  no_call "127.0.0.1:8032"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8040
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=8040"    grep -qx 'LOCAL_PORT=8040' "$SVC/.env"
  check "served :8040 -> 127.0.0.1:8040"  calls_have "tailscale serve --bg --https=8040 http://127.0.0.1:8040"
  check "  and never :8030"               no_call "tailscale serve --bg --https=8030"
  check "prints the :8040 URL"            out_has "https://test-host.tailfake.ts.net:8040"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                    [ "$CODE" -eq 0 ]
  check "re-run kept :8040 -> 127.0.0.1:8040"  calls_have "tailscale serve --bg --https=8040 http://127.0.0.1:8040"
  check "  and never :8030"                    no_call "tailscale serve --bg --https=8030"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8040 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8040"  calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8040"
  check "prints the :8443 URL"            out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loop waits instead of dying"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/health_fails_left"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "polled healthcheck repeatedly" [ "$(grep -c '/healthcheck' "$CALLS_LOG")" -gt 3 ]
  check "still published"             calls_have "tailscale serve --bg --https=8030"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, magic link not re-requested"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/magic_posts"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "existing .env untouched"      env_has "my-custom-marker"
  check "password unchanged"           [ "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SVC/.env")" = "$pw" ]
  check "never invoked sudo"           no_call "^sudo "
  check "compose up re-invoked"        [ -f "$STATE_DIR/compose_up" ]
  check "magic link NOT retried"       [ ! -f "$STATE_DIR/magic_posts" ]
  check "says the link was already requested" out_has "already requested"
  check "re-applied serve config"      calls_have "tailscale serve --bg --https=8030 http://127.0.0.1:8030"
  teardown
}

test_origin_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  old="$(grep '^APP_ORIGIN=' "$SVC/.env")"
  export HTTPS_PORT=8031
  run_deploy
  check "warns about the drift"      out_has "APP_ORIGIN in .env is"
  check "spells out the fix"         out_has "APP_ORIGIN=https://test-host.tailfake.ts.net:8031"
  check ".env left alone (user's)"   [ "$(grep '^APP_ORIGIN=' "$SVC/.env")" = "$old" ]
  teardown
}

test_admin_email_override() {
  echo "• ADMIN_EMAIL override is baked into .env on first run"
  setup
  touch "$STATE_DIR/operator"
  export ADMIN_EMAIL=kai@example.com
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the email"     grep -qx 'ADMIN_EMAIL=kai@example.com' "$SVC/.env"
  check "whitelist matches it"       grep -q 'kai@example\.com' "$SVC/.env"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8030 http://127.0.0.1:8030"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8030 http://127.0.0.1:8030"
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

# Every listener on $port must be loopback or Tailscale's own tailnet
# address — never a wildcard or a LAN interface.
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
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "webapp container running"     sh -c "docker inspect -f '{{.State.Status}}' trigger-webapp | grep -qx running"
  live_check "postgres container running"   sh -c "docker inspect -f '{{.State.Status}}' trigger-postgres | grep -qx running"
  live_check "clickhouse container running" sh -c "docker inspect -f '{{.State.Status}}' trigger-clickhouse | grep -qx running"
  live_check "supervisor container running" sh -c "docker inspect -f '{{.State.Status}}' trigger-supervisor | grep -qx running"
  live_check "local /healthcheck responds"  curl -fsS -o /dev/null "http://127.0.0.1:$port/healthcheck"
  live_check "webapp not on non-local ifaces" no_external_listener "$port"
  live_check "registry not on non-local ifaces" \
    no_external_listener "$(sed -n 's/^REGISTRY_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS /healthcheck"   curl -fsS -o /dev/null --max-time 30 "$url:$https_port/healthcheck"
  live_check "worker token file exists"     sh -c "test -s \"\$(sed -n 's/^TRIGGER_SHARED=//p' '$SERVICE_DIR/.env')/worker_token\""
  live_check "state dir exists"             sh -c "test -d \"\$(sed -n 's/^TRIGGER_POSTGRES=//p' '$SERVICE_DIR/.env')\""
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/trigger-dev/setup.sh or services/trigger-dev/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_origin_drift
test_admin_email_override
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
