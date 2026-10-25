#!/usr/bin/env bash
#
# Tests for services/trigger-dev/setup.sh and teardown.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" \
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

ST="services/trigger-dev"
state_dir() { printf '%s/%s' "$HOME" "$ST"; }
env_val()   { sed -n "s/^$1=//p" "$SVC/.env"; }
# Replace one KEY=... line in the sandbox .env (BSD and GNU sed both take -i.bak).
set_env()   { sed -i.bak "s#^$1=.*#$1=$2#" "$SVC/.env"; rm -f "$SVC/.env.bak"; }

# A deployed sandbox: setup.sh has run, every data dir holds a file, Serve
# maps this port to this service, and neighbours sit on other ports (one a
# lookalike suffix, one the loopback registry port someone published by hand).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local v
  for v in TRIGGER_POSTGRES TRIGGER_CLICKHOUSE TRIGGER_REDIS TRIGGER_MINIO TRIGGER_REGISTRY TRIGGER_SHARED; do
    mkdir -p "$(env_val "$v")"; echo keep > "$(env_val "$v")/keep"
  done
  # The compose project's own containers sit on its networks.
  printf 'trigger-webapp trigger-dev\ntrigger-supervisor trigger-dev\n' > "$STATE_DIR/attached_trigger-webapp"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8030 (tailnet only)
|-- / proxy http://127.0.0.1:8030

https://test-host.tailfake.ts.net:18030 (tailnet only)
|-- / proxy http://127.0.0.1:18030

https://test-host.tailfake.ts.net:5000 (tailnet only)
|-- / proxy http://127.0.0.1:5000
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

# Checks setup.sh's default paths, so it still means something after a test
# has pointed a .env path somewhere odd.
all_data_kept() {
  local d
  for d in postgres clickhouse redis minio registry/data shared; do
    [ -f "$HOME/$ST/$d/keep" ] || return 1
  done
  [ -s "$HOME/$ST/registry/auth.htpasswd" ] && [ -f "$HOME/$ST/.magic-link-requested" ]
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8030"         calls_have "tailscale serve --https=8030 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18030 untouched"  no_call "https=18030"
  check "registry port :5000 untouched (setup.sh never publishes it)" no_call "https=5000"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  in the service dir"        calls_have "docker compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no container killed"         no_call "docker rm"
  check "no cleanup container"        no_call "docker run"
  check "data kept"                   all_data_kept
  check "magic-link marker kept"      [ -f "$HOME/$ST/.magic-link-requested" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_custom_port() {
  echo "• teardown: the port comes from .env (LOCAL_PORT=8040, HTTPS 8443)"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8040 HTTPS_PORT=8443
  run_deploy
  unset LOCAL_PORT HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:8040\n\nhttps://test-host.tailfake.ts.net:8030 (tailnet only)\n|-- / proxy http://127.0.0.1:8030\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8443"         calls_have "tailscale serve --https=8443 off"
  check "default :8030 untouched"     no_call "https=8030"
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
  printf 'https://test-host.tailfake.ts.net:8030 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8030 (tailnet only)
|-- / proxy http://127.0.0.1:8030

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8030

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /trigger proxy http://127.0.0.1:8030
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8030 off"                   calls_have "serve --https=8030 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8030 (left on, see above); 2 port(s) unpublished"
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /trigger proxy http://127.0.0.1:8030
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    out_lacks "already off"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8030 (left on, see above); 0 port(s) unpublished"
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
  check "root: no compose down"       [ ! -f "$STATE_DIR/compose_down" ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "no docker: no serve off"     no_call " off"
  teardown
}

test_teardown_task_runners_left_alone() {
  echo "• teardown: task-runner containers outside the compose project are named, never killed"
  deployed
  printf 'trigger-webapp trigger-dev\nrun_cm5abc-attempt-1 \n' > "$STATE_DIR/attached_trigger-webapp"
  printf 'run_cm5abc-attempt-1 \nother-app other\n' > "$STATE_DIR/attached_trigger-supervisor"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the runner"            out_has "run_cm5abc-attempt-1"
  check "names a foreign container"   out_has "other-app"
  check "own containers not listed as leftovers" [ "$(grep -c '^ *trigger-webapp$' <<<"$OUT")" -eq 0 ]
  check "gives the docker rm command" out_has "docker rm -f"
  check "killed nothing"              no_call "docker rm"
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  check "nothing unpublished"         no_call " off"
  check "data and .env kept"          all_data_kept
  run_teardown --purge "trigger-dev"
  check "purge: also stops first"     [ "$CODE" -ne 0 ]
  check "purge: data kept"            all_data_kept
  check "purge: .env kept"            [ -f "$SVC/.env" ]
  rm -f "$STATE_DIR/attached_trigger-supervisor"
  printf 'trigger-webapp trigger-dev\n' > "$STATE_DIR/attached_trigger-webapp"
  run_teardown
  check "runs gone: exits zero"       [ "$CODE" -eq 0 ]
  teardown
  deployed
  touch "$STATE_DIR/ps_filter_fails"
  run_teardown
  check "listing fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose down"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  nothing unpublished"       no_call " off"
  teardown
}

# A task run started after the pre-check keeps a trigger-* network in use, so
# `down` exits non-zero once it has removed the stack. That alone must not
# stop the teardown halfway; anything else still does, data and .env kept.
test_teardown_down_fails() {
  echo "• teardown: a failed down because a task run still uses a trigger-* network warns and goes on"
  deployed
  touch "$STATE_DIR/compose_down_fails"
  printf 'run_cm9late-attempt-1 ' > "$STATE_DIR/network_users_trigger-webapp"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "checked this project's containers" calls_have "ps -aq --filter label=com.docker.compose.project=trigger-dev"
  check "names the network and who keeps it" out_has "trigger-webapp (run_cm9late-attempt-1)"
  check "points at the attached runner" out_has "network=trigger-webapp"
  check "does not claim they went"    out_lacks "networks removed"
  check "says they stay"              out_has "networks still in use stay"
  check "killed nothing"              no_call "docker rm"
  check "data kept"                   all_data_kept
  check ".env kept"                   [ -f "$SVC/.env" ]
  run_teardown --purge "trigger-dev"
  check "purge: exits zero"           [ "$CODE" -eq 0 ]
  check "  warns about the network"   out_has "trigger-webapp (run_cm9late-attempt-1)"
  check "  postgres gone"             [ ! -e "$(state_dir)/postgres" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  check "  marker gone"               [ ! -e "$(state_dir)" ]
  teardown
  # This project's own containers are still there: a real failure.
  deployed
  touch "$STATE_DIR/compose_down_fails"
  printf 'run_cm9late-attempt-1 ' > "$STATE_DIR/network_users_trigger-webapp"
  printf 'f00dfeed\n' > "$STATE_DIR/project_left"
  run_teardown --purge "trigger-dev"
  check "own containers left: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "own containers are still there"
  check "  data kept"                 all_data_kept
  check "  .env kept"                 [ -f "$SVC/.env" ]
  rm -f "$STATE_DIR/project_left"
  touch "$STATE_DIR/ps_label_fails"
  run_teardown --purge "trigger-dev"
  check "cannot list what is left: exits non-zero" [ "$CODE" -ne 0 ]
  check "  data and .env kept"        all_data_kept && [ -f "$SVC/.env" ]
  rm -f "$STATE_DIR/ps_label_fails" "$STATE_DIR/network_users_trigger-webapp"
  run_teardown --purge "trigger-dev"
  check "networks already gone: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it was not a network" out_has "not because a trigger-\* network is still in use"
  check "  data and .env kept"        all_data_kept && [ -f "$SVC/.env" ]
  : > "$STATE_DIR/network_users_trigger-supervisor"
  run_teardown --purge "trigger-dev"
  check "network empty: exits non-zero" [ "$CODE" -ne 0 ]
  check "  data and .env kept"        all_data_kept && [ -f "$SVC/.env" ]
  teardown
}

test_teardown_units_not_touched() {
  echo "• teardown: a user unit mentioning trigger-dev is named, not touched"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=%s/services/trigger-dev/backup.sh\n' "$HOME" > "$HOME/.config/systemd/user/trigger-backup.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/unrelated.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit"              out_has "trigger-backup.service"
  check "does not name unrelated"     out_lacks "unrelated.service"
  check "no systemctl call"           no_call "systemctl"
  check "unit file kept"              [ -f "$HOME/.config/systemd/user/trigger-backup.service" ]
  run_teardown --purge "trigger-dev"
  check "purge: unit file still kept" [ -f "$HOME/.config/systemd/user/trigger-backup.service" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then exactly setup.sh's state and .env go"
  deployed
  local st; st="$(state_dir)"
  run_teardown --purge "trigger"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       all_data_kept
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "trigger-dev"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8030"         calls_have "tailscale serve --https=8030 off"
  check "compose down (no -v: no named volumes)" no_call "down -v"
  local d
  for d in postgres clickhouse redis minio registry/data shared; do
    check "$d gone"                   [ ! -e "$st/$d" ]
  done
  check "registry htpasswd gone"      [ ! -e "$st/registry/auth.htpasswd" ]
  check "registry dir gone"           [ ! -e "$st/registry" ]
  check "magic-link marker gone"      [ ! -e "$st/.magic-link-requested" ]
  check "\$HOME/services/trigger-dev marker gone" [ ! -e "$st" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "tracked compose file kept"   [ -f "$SVC/docker-compose.yml" ]
  check "tracked machine-presets.json kept" [ -f "$SVC/machine-presets.json" ]
  check "tracked clickhouse/*.xml kept" [ -f "$SVC/clickhouse/data-paths.xml" ] && [ -f "$SVC/clickhouse/override.xml" ] && [ -f "$SVC/clickhouse/users-override.xml" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "no sudo"                     no_call "^sudo"
  teardown
}

test_teardown_purge_keeps_other_files() {
  echo "• teardown --purge: files setup.sh did not make under ~/services/trigger-dev stay"
  deployed
  local st; st="$(state_dir)"
  echo backup > "$st/trigger-dev-2026-10-01.tgz"
  run_teardown --purge "trigger-dev"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "user's backup kept"          [ -f "$st/trigger-dev-2026-10-01.tgz" ]
  check "postgres gone"               [ ! -e "$st/postgres" ]
  check "says the dir was left"       out_has "did not create; left alone"
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the Postgres image, not sudo"
  deployed
  local pg ch
  pg="$(env_val TRIGGER_POSTGRES)"; ch="$(env_val TRIGGER_CLICKHOUSE)"
  mkdir -p "$pg/base/locked" "$ch/store/locked"
  echo x > "$pg/base/locked/f"; echo x > "$ch/store/locked/f"
  chmod 500 "$pg/base/locked" "$ch/store/locked"
  run_teardown --purge "trigger-dev"
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the compose Postgres image" calls_have "postgres:14"
  check "never pulled for it"         calls_have "pull never"
  check "mounted the postgres dir"    calls_have "-v $pg:/x"
  check "mounted the clickhouse dir"  calls_have "-v $ch:/x"
  check "no sudo"                     no_call "^sudo"
  check "postgres gone"               [ ! -e "$pg" ]
  check "clickhouse gone"             [ ! -e "$ch" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  pg="$(env_val TRIGGER_POSTGRES)"
  mkdir -p "$pg/base/locked"; echo x > "$pg/base/locked/f"
  chmod 500 "$pg/base/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "trigger-dev"
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $pg"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  deployed
  printf 'POSTGRES_IMAGE_TAG=16;rm\n' >> "$SVC/.env"
  run_teardown --purge "trigger-dev"
  check "odd image tag refused"       [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_missing_data() {
  echo "• teardown --purge: data already gone is fine, marker still removed"
  deployed
  local st; st="$(state_dir)"
  rm -rf "${st:?}"/*
  run_teardown --purge "trigger-dev"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "empty marker dir removed"    [ ! -e "$(state_dir)" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses odd data paths before anything changes"
  local var dotted
  for var in TRIGGER_POSTGRES TRIGGER_SHARED TRIGGER_REGISTRY TRIGGER_REGISTRY_AUTH; do
    deployed
    mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
    set_env "$var" "$HOME"
    run_teardown --purge "trigger-dev"
    check "$var=\$HOME refused"        [ "$CODE" -ne 0 ]
    check "  nothing stopped"         [ ! -f "$STATE_DIR/compose_down" ]
    check "  data kept"               all_data_kept
    set_env "$var" "$HOME/services/../x"
    run_teardown --purge "trigger-dev"
    check "$var '..' refused"         [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services/"
    run_teardown --purge "trigger-dev"
    check "$var services dir itself refused" [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services//"
    run_teardown --purge "trigger-dev"
    check "$var trailing slashes refused" [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services/neighbour"
    run_teardown --purge "trigger-dev"
    check "$var another service's dir refused" [ "$CODE" -ne 0 ]
    for dotted in "$HOME/services/." "$HOME/services/./trigger-dev" "$HOME/services/trigger-dev/.."; do
      set_env "$var" "$dotted"
      run_teardown --purge "trigger-dev"
      check "$var '.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
    done
    mkdir -p "$HOME/services/trigger-dev/a:b"
    set_env "$var" "$HOME/services/trigger-dev/a:b"
    run_teardown --purge "trigger-dev"
    check "$var colon refused"        [ "$CODE" -ne 0 ]
    check "  neighbour never touched" [ -f "$HOME/services/neighbour/keep" ]
    check "  .env kept"               [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  ln -s "$HOME/services" "$HOME/services/trigger-dev/alias"
  set_env TRIGGER_REDIS "$HOME/services/trigger-dev/alias"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "trigger-dev"
  check "symlinked data dir refused"  [ "$CODE" -ne 0 ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  set_env TRIGGER_POSTGRES ""
  run_teardown --purge "trigger-dev"
  check "missing path refused"        [ "$CODE" -ne 0 ]
  check "  says it will not guess"    out_has "refusing to guess"
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/trigger-dev/postgres"; echo x > "$HOME/trigger-dev/postgres/keep"
  run_teardown --purge "trigger-dev"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/trigger-dev/postgres/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/trigger-dev survives"
  deployed
  local repo="$HOME/$ST/setup-server/services/trigger-dev"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/$ST/setup-server/other.env"
  set_env TRIGGER_SHARED "$HOME/$ST"
  cp "$SVC/.env" "$repo/.env"
  OUT="$(printf '%s\n' "trigger-dev" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/$ST/setup-server/other.env" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8030'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8030 off"                   calls_have "serve --https=8030 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8030"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8030 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "  :8030 off"                 calls_have "serve --https=8030 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=80x0/' "$SVC/.env"
  run_teardown
  check "non-numeric port refused"    [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(env_val TRIGGER_POSTGRES)"
  set_env TRIGGER_POSTGRES "\"\${HOME}${dir#"$HOME"}\""
  run_teardown --purge "trigger-dev"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(env_val TRIGGER_POSTGRES)"
  set_env TRIGGER_POSTGRES "'\$HOME${dir#"$HOME"}'"
  run_teardown --purge "trigger-dev"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir/keep" ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'TRIGGER_POSTGRES=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "TRIGGER_POSTGRES is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nTRIGGER_POSTGRES=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  printf 'just some words\n' >> "$SVC/.env"
  run_teardown
  check "not KEY=value: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "other" >> "$SVC/.env"
    run_teardown --purge "trigger-dev"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose call"           no_call "compose --project-directory"
  teardown
}

test_teardown_purge_refuses_linked_files() {
  echo "• teardown --purge: a symlinked auth file or a lookalike sibling dir is refused"
  deployed
  local auth; auth="$(env_val TRIGGER_REGISTRY_AUTH)"
  echo secret > "$HOME/secret"
  rm -f "$auth"; ln -s "$HOME/secret" "$auth"
  run_teardown --purge "trigger-dev"
  check "symlinked TRIGGER_REGISTRY_AUTH: exits non-zero" [ "$CODE" -ne 0 ]
  check "  link target kept"          [ -f "$HOME/secret" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  mkdir -p "$HOME/services/trigger-dev-old"; echo x > "$HOME/services/trigger-dev-old/keep"
  set_env TRIGGER_MINIO "$HOME/services/trigger-dev-old"
  run_teardown --purge "trigger-dev"
  check "sibling ~/services/trigger-dev-old: exits non-zero" [ "$CODE" -ne 0 ]
  check "  its files kept"            [ -f "$HOME/services/trigger-dev-old/keep" ]
  check "  data kept"                 all_data_kept
  teardown
}

# State behind a folder this user cannot search (a root-owned 0700 parent,
# faked with chmod 000): `[ -e ]` cannot see it, which must not read as
# "already gone" while .env is deleted. The Postgres image (as root) mounts
# that folder and deletes only the paths below it.
unhide()    { chmod -R u+rwX "$HOME/services" 2>/dev/null; }
mounts_of() { grep -c -- "-v $1:/x" "$CALLS_LOG"; }

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: state behind an unsearchable folder is deleted, not taken as gone"
  local st reg
  # registry/ holds both the registry data dir and auth.htpasswd: two
  # targets, one unsearchable folder, two mounts of it.
  deployed
  reg="$(cd "$(state_dir)" && pwd -P)/registry"
  chmod 000 "$reg"
  run_teardown --purge "trigger-dev"
  unhide
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "lists both behind the folder" out_has "$reg/data   (behind a folder"
  check "  and the auth file"         out_has "$reg/auth.htpasswd   (behind a folder"
  check "mounted the unsearchable folder once per target" [ "$(mounts_of "$reg")" -eq 2 ]
  check "as root in the Postgres image" calls_have "pull never --user 0 -v $reg:/x --entrypoint sh postgres:14"
  check "never mounted a missing folder" [ ! -f "$STATE_DIR/mounted_missing" ]
  check "no sudo"                     no_call "^sudo"
  check "says the data dir went"      out_has "Deleted $reg/data"
  check "says the auth file went"     out_has "Deleted $reg/auth.htpasswd"
  check "registry folder gone"        [ ! -e "$reg" ]
  check "postgres gone too"           [ ! -e "$(state_dir)/postgres" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$(state_dir)" ]
  teardown
  # The hidden folder sits inside another (searchable) data dir, which is
  # cleared first; the hidden target is then gone and nothing is mounted.
  deployed
  local shared; shared="$(cd "$(env_val TRIGGER_SHARED)" && pwd -P)"
  mkdir -p "$shared/locked"
  mv "$(env_val TRIGGER_REDIS)" "$shared/locked/redis"
  set_env TRIGGER_REDIS "$shared/locked/redis"
  chmod 000 "$shared/locked"
  run_teardown --purge "trigger-dev"
  unhide
  check "hidden inside another dir: exits zero" [ "$CODE" -eq 0 ]
  check "  that dir cleared by the container" [ "$(mounts_of "$shared")" -eq 1 ]
  check "  hidden folder never mounted once gone" [ "$(mounts_of "$shared/locked")" -eq 0 ]
  check "  never mounted a missing folder" [ ! -f "$STATE_DIR/mounted_missing" ]
  check "  says it is already gone"   out_has "$shared/locked/redis is already gone"
  check "  shared gone"               [ ! -e "$shared" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  teardown
  # The cleanup container fails: non-zero, sudo named, data and .env kept.
  deployed
  st="$(cd "$(state_dir)" && pwd -P)/storage"
  mkdir -p "$st"
  mv "$(env_val TRIGGER_POSTGRES)" "$st/postgres"
  set_env TRIGGER_POSTGRES "$st/postgres"
  chmod 000 "$st"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "trigger-dev"
  unhide
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/postgres"
  check "  never says deleted"        out_lacks "Deleted"
  check "  postgres kept"             [ -f "$st/postgres/keep" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  st="$(cd "$(state_dir)" && pwd -P)/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/minio"
  set_env TRIGGER_MINIO "$st/minio"
  chmod 000 "$st"
  run_teardown --purge "trigger-dev"
  unhide
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  link kept"                 [ -L "$st/minio" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # A file-kind target that is a directory behind the unsearchable folder:
  # never rm -rf'd (it could hold anything), and no sudo rm is offered.
  deployed
  st="$(cd "$(state_dir)" && pwd -P)/storage"
  mkdir -p "$st/auth.htpasswd"; echo keep > "$st/auth.htpasswd/keep"
  set_env TRIGGER_REGISTRY_AUTH "$st/auth.htpasswd"
  chmod 000 "$st"
  run_teardown --purge "trigger-dev"
  unhide
  check "file-kind hidden dir: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it is a directory"    out_has "is a directory, not the file"
  check "  offers no rm -rf on it"    out_lacks "sudo rm -rf $st/auth.htpasswd"
  check "  dir kept"                  [ -f "$st/auth.htpasswd/keep" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # And the mirror image: a dir-kind target that is a plain file.
  deployed
  st="$(cd "$(state_dir)" && pwd -P)/storage"
  mkdir -p "$st"; echo keep > "$st/redis"
  set_env TRIGGER_REDIS "$st/redis"
  chmod 000 "$st"
  run_teardown --purge "trigger-dev"
  unhide
  check "dir-kind hidden file: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it is not a directory" out_has "is not a directory"
  check "  file kept"                 [ -f "$st/redis" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # ~/services/trigger-dev itself unsearchable: not strictly inside it, so
  # no mount; stop before anything changes and name the sudo command.
  deployed
  chmod 000 "$(state_dir)"
  run_teardown --purge "trigger-dev"
  unhide
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $(state_dir)/"
  check "  no cleanup container"      no_call "entrypoint sh"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  serve untouched"           no_call " off"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 all_data_kept
  teardown
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
test_teardown_safe
test_teardown_custom_port
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_task_runners_left_alone
test_teardown_down_fails
test_teardown_units_not_touched
test_teardown_purge
test_teardown_purge_keeps_other_files
test_teardown_purge_container_owned
test_teardown_purge_missing_data
test_teardown_purge_refuses_odd_paths
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_purge_refuses_linked_files
test_teardown_quoted_env
test_teardown_home_variable_in_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_only_shared_ports
test_teardown_purge_unsearchable_parent

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
