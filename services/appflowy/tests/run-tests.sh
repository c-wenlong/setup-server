#!/usr/bin/env bash
#
# Tests for services/appflowy/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other Docker services: the real script runs from a
# sandbox copy with PATH stubs for docker/tailscale/curl/sudo/id.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
# setup.sh sources ../../lib/common.sh, so every sandbox copy of the
# service sits at <root>/services/<name> with <root>/lib beside it.
copy_lib() { mkdir -p "$1/lib" && cp "$REPO_ROOT/lib/common.sh" "$1/lib/"; }
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
  SVC="$SANDBOX/repo/services/appflowy"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" \
    "$SERVICE_DIR/docker-compose.yml" "$SERVICE_DIR/nginx.conf" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT GOTRUE_ADMIN_EMAIL
  unset STATE_DIR CALLS_LOG
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
nginx_hasF()       { grep -qF -- "$1" "$SVC/nginx.conf"; }
compose_lacks()    { ! compose_has "$1"; }
nginx_lacks()      { ! grep -qE -- "$1" "$SVC/nginx.conf"; }

# Ports mappings only — in-container listen 80 is fine.
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

data_dir() { sed -n 's/^APPFLOWY_DATA=//p' "$SVC/.env"; }

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
  export LOCAL_PORT=81o2
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_missing_nginx() {
  echo "• preflight fails when nginx.conf is missing"
  setup
  rm -f "$SVC/nginx.conf"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "names nginx.conf"     out_has "nginx.conf"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, published tailnet-only, sign-up locked"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env names the admin email"         grep -qE '^GOTRUE_ADMIN_EMAIL=.+$' "$SVC/.env"
  check ".env has an admin password"         grep -qE '^GOTRUE_ADMIN_PASSWORD=.{8,}$' "$SVC/.env"
  check ".env has a JWT secret"              grep -qE '^GOTRUE_JWT_SECRET=.+$' "$SVC/.env"
  check ".env records the local port"        grep -qx 'LOCAL_PORT=8102' "$SVC/.env"
  check "pinned cloud to 0.18.8"             grep -qx 'APPFLOWY_CLOUD_VERSION=0.18.8' "$SVC/.env"
  check "sign-up is disabled"                grep -qx 'GOTRUE_DISABLE_SIGNUP=true' "$SVC/.env"
  check "AI is off"                          grep -qx 'AI_ENABLED=false' "$SVC/.env"
  check "search URL is empty"                grep -qx 'APPFLOWY_SEARCH_SERVICE_URL=' "$SVC/.env"
  check "BASE_URL is the tailnet URL"        grep -q '^APPFLOWY_BASE_URL=https://test-host\.tailfake\.ts\.net:8102$' "$SVC/.env"
  check "GoTrue public URL includes /gotrue" grep -q '^API_EXTERNAL_URL=https://test-host\.tailfake\.ts\.net:8102/gotrue$' "$SVC/.env"
  check "websocket URL is wss"               grep -q '^APPFLOWY_WEBSOCKET_BASE_URL=wss://test-host\.tailfake\.ts\.net:8102/ws/v2$' "$SVC/.env"
  check "GoTrue DB uses auth search_path"    grep -q 'search_path=auth' "$SVC/.env"
  check "compose binds nginx loopback"       compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose publishes no host wildcard" no_host_wildcard_port
  check "compose has no AI service"          compose_lacks '^[[:space:]]*ai:'
  check "compose has no search service"      compose_lacks '^[[:space:]]*appflowy_search:'
  check "nginx listens on 80 only"           nginx_hasF 'listen 80'
  check "nginx has no TLS listen"            nginx_lacks 'listen[[:space:]]+443'
  check "nginx has no ssl_certificate"       nginx_lacks 'ssl_certificate'
  check "data dir created"                   [ -d "$(data_dir)" ]
  check "compose up invoked"                 [ -f "$STATE_DIR/compose_up" ]
  check "waited on /api/health"              calls_have "127.0.0.1:8102/api/health"
  check "served :8102"                       calls_have "tailscale serve --bg --https=8102 http://127.0.0.1:8102"
  check "no sudo needed (operator set)"      no_call "^sudo "
  check "prints final URL"                   out_has "https://test-host.tailfake.ts.net:8102"
  check "checked gotrue settings"            calls_have "/gotrue/settings"
  check "says sign-up is disabled"           out_has "Public sign-up is disabled"
  teardown
}

test_open_signup_fails() {
  echo "• public sign-up still open: setup dies, does not publish"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/signup_open"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the open lock"           out_has "disable_signup=false"
  check "did not serve"                 no_call "tailscale serve --bg --https=8102"
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
  check "BASE_URL uses the new port" grep -qx 'APPFLOWY_BASE_URL=https://test-host.tailfake.ts.net:8105' "$SVC/.env"
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
  check "  and never :8102"              no_call "tailscale serve --bg --https=8102"
  check "prints the :8110 URL"           out_has "https://test-host.tailfake.ts.net:8110"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8110 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8110 http://127.0.0.1:8110"
  check "  and never :8102"                   no_call "tailscale serve --bg --https=8102"
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
  check "still published"            calls_have "tailscale serve --bg --https=8102"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(sed -n 's/^GOTRUE_ADMIN_PASSWORD=//p' "$SVC/.env")"
  jwt="$(sed -n 's/^GOTRUE_JWT_SECRET=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "password unchanged"          [ "$(sed -n 's/^GOTRUE_ADMIN_PASSWORD=//p' "$SVC/.env")" = "$pw" ]
  check "JWT unchanged"               [ "$(sed -n 's/^GOTRUE_JWT_SECRET=//p' "$SVC/.env")" = "$jwt" ]
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8102 http://127.0.0.1:8102"
  teardown
}

test_base_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  old="$(grep '^APPFLOWY_BASE_URL=' "$SVC/.env")"
  export HTTPS_PORT=8103
  run_deploy
  check "warns about the drift"     out_has "APPFLOWY_BASE_URL in .env is"
  check "spells out the fix"        out_has "APPFLOWY_BASE_URL, APPFLOWY_WEB_URL"
  check ".env left alone (user's)"  [ "$(grep '^APPFLOWY_BASE_URL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8102 http://127.0.0.1:8102"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=8102 http://127.0.0.1:8102"
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
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "nginx container running"       sh -c "docker inspect -f '{{.State.Status}}' appflowy-nginx | grep -qx running"
  live_check "postgres container running"    sh -c "docker inspect -f '{{.State.Status}}' appflowy-postgres | grep -qx running"
  live_check "redis container running"       sh -c "docker inspect -f '{{.State.Status}}' appflowy-redis | grep -qx running"
  live_check "minio container running"       sh -c "docker inspect -f '{{.State.Status}}' appflowy-minio | grep -qx running"
  live_check "gotrue container running"      sh -c "docker inspect -f '{{.State.Status}}' appflowy-gotrue | grep -qx running"
  live_check "cloud container running"       sh -c "docker inspect -f '{{.State.Status}}' appflowy-cloud | grep -qx running"
  live_check "web container running"         sh -c "docker inspect -f '{{.State.Status}}' appflowy-web | grep -qx running"
  live_check "admin container running"       sh -c "docker inspect -f '{{.State.Status}}' appflowy-admin | grep -qx running"
  live_check "worker container running"      sh -c "docker inspect -f '{{.State.Status}}' appflowy-worker | grep -qx running"
  live_check "local /api/health responds"    curl -fsS -o /dev/null "http://127.0.0.1:$port/api/health"
  live_check "local /gotrue/health responds" curl -fsS -o /dev/null "http://127.0.0.1:$port/gotrue/health"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS health responds" curl -fsS -o /dev/null --max-time 30 "$url:$https_port/api/health"
  live_check "public sign-up is disabled"    sh -c "curl -fsS '$url:$https_port/gotrue/settings' | grep -q '\"disable_signup\":true'"
  live_check "state dir exists"              sh -c "test -d \"\$(sed -n 's/^APPFLOWY_DATA=//p' '$SERVICE_DIR/.env')\""
  live_check "AI container is not running"   sh -c "! docker inspect appflowy-ai >/dev/null 2>&1"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# and neighbours sit on other ports (one a lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)"
  echo keep > "$(data_dir)/dump.sql"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8102 (tailnet only)
|-- / proxy http://127.0.0.1:8102

https://test-host.tailfake.ts.net:18102 (tailnet only)
|-- / proxy http://127.0.0.1:18102
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps volumes, data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8102"         calls_have "tailscale serve --https=8102 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18102 untouched"  no_call "https=18102"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "same project as setup.sh"    calls_have "docker compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/dump.sql" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "nginx.conf kept"             [ -f "$SVC/nginx.conf" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_differs() {
  echo "• teardown: an HTTPS port other than LOCAL_PORT is found from Serve"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:8102\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :9443"         calls_have "tailscale serve --https=9443 off"
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
  printf 'https://test-host.tailfake.ts.net:8102 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
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
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then volumes, data and .env go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "appflow"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/dump.sql" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: no down -v"      no_call "down -v"
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "appflowy"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "down -v removes the volumes" calls_have "docker compose --project-directory $SVC down -v"
  check "marker dir gone"             [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "nginx.conf kept"             [ -f "$SVC/nginx.conf" ]
  check "compose file kept"           [ -f "$SVC/docker-compose.yml" ]
  check "serve off for :8102"         calls_have "tailscale serve --https=8102 off"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "no down -v"                  no_call "down -v"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./appflowy" "$HOME/services/appflowy/.."; do
    sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "appflowy"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "own data never touched"      [ -f "$HOME/services/appflowy/dump.sql" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8102

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8102

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /notes proxy http://127.0.0.1:8102
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8102 (left on, see above); 2 port(s) unpublished"
  teardown
}

# A data dir behind a folder this user cannot search (a root-owned 0700
# parent, faked with chmod 000): `[ -e ]` cannot see it, which must not read
# as "already gone" while .env is deleted. It must stop before anything
# changes (no `compose down`, no Serve change) and name the sudo command.
test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder stops before anything changes"
  deployed
  local st="$HOME/services/appflowy/storage"
  mkdir -p "$st/data"
  echo keep > "$st/data/marker"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "appflowy"
  chmod 755 "$st"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the folder"            out_has "$st cannot be searched"
  check "names the sudo command"      out_has "sudo rm -rf $st/data"
  check "never says deleted"          bash -c '! grep -q "Deleted" <<<"$1"' _ "$OUT"
  check "data kept"                   [ -f "$st/data/marker" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "no down of any kind"         no_call "down"
  check "serve untouched"             no_call " off"
  teardown
  deployed
  chmod 000 "$HOME/services"
  run_teardown --purge "appflowy"
  chmod 755 "$HOME/services"
  check "services dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/dump.sql" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  no down of any kind"       no_call "down"
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /notes proxy http://127.0.0.1:8102
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    bash -c '! grep -q "already off" <<<"$1"' _ "$OUT"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8102 (left on, see above); 0 port(s) unpublished"
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

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8102'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8102 off"                   calls_have "serve --https=8102 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8102"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8102 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "appflowy"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/appflowy///#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$HOME/services/appflowy" ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine; the marker still goes"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "appflowy"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "down -v still run"           calls_have "down -v"
  teardown
  deployed
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/appflowy/dumps#" "$SVC/.env"
  rm -f "$HOME/services/appflowy/dump.sql"
  run_teardown --purge "appflowy"
  check "sub-dir gone, empty marker: exits zero" [ "$CODE" -eq 0 ]
  check "  empty ~/services/appflowy removed"    [ ! -e "$HOME/services/appflowy" ]
  teardown
  deployed
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/appflowy/dumps#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "non-empty marker: exits zero"           [ "$CODE" -eq 0 ]
  check "  marker kept (rmdir only empties)"     [ -f "$HOME/services/appflowy/dump.sql" ]
  teardown
}

test_teardown_purge_marker_symlink() {
  echo "• teardown --purge: ~/services/appflowy as a symlink is never followed"
  deployed
  mkdir -p "$HOME/elsewhere"; echo x > "$HOME/elsewhere/keep"
  rm -rf "$HOME/services/appflowy"
  ln -s "$HOME/elsewhere" "$HOME/services/appflowy"
  run_teardown --purge "appflowy"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "link target kept"            [ -f "$HOME/elsewhere/keep" ]
  check "link kept"                   [ -L "$HOME/services/appflowy" ]
  check "no down -v"                  no_call "down -v"
  rm -rf "$HOME/elsewhere"
  : > "$CALLS_LOG"
  run_teardown --purge "appflowy"
  # A link that does not resolve looks the same as one into a folder this
  # user cannot search, so it is refused rather than taken as gone.
  check "dangling link: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "symlink this user cannot follow"
  check "  dangling link left alone"  [ -L "$HOME/services/appflowy" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  no down -v"                no_call "down -v"
  teardown
}

test_teardown_purge_refuses_repo_dir() {
  echo "• teardown --purge: never deletes the checkout holding nginx.conf"
  deployed
  local repo="$HOME/services/appflowy/repo"
  mkdir -p "$repo"
  cp "$SVC/setup.sh" "$SVC/teardown.sh" "$SVC/docker-compose.yml" "$SVC/nginx.conf" "$SVC/.env" "$repo/"
  copy_lib "$repo/../.."
  SVC="$repo"
  run_teardown --purge "appflowy"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "holds this checkout"
  check "nginx.conf kept"             [ -f "$repo/nginx.conf" ]
  check "no down -v"                  no_call "down -v"
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=\$HOME${dir#"$HOME"}#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "unquoted \$HOME form: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  check "  no down -v"                no_call "down -v"
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/appflowy itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/appflowy-old"; echo x > "$HOME/services/appflowy-old/keep"
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/appflowy-old#" "$SVC/.env"
  run_teardown --purge "appflowy"
  check "lookalike name refused"      [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/appflowy-old/keep" ]
  sed -i.bak "s#^APPFLOWY_DATA=.*#APPFLOWY_DATA=$HOME/services/appflowy/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/appflowy/a:b"
  run_teardown --purge "appflowy"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/appflowy"; echo x > "$HOME/appflowy/keep"
  run_teardown --purge "appflowy"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/appflowy/keep" ]
  check "no down -v"                  no_call "down -v"
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'APPFLOWY_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "APPFLOWY_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nAPPFLOWY_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  printf 'not a key value line\n' >> "$SVC/.env"
  run_teardown
  check "bad line: exits non-zero"    [ "$CODE" -ne 0 ]
  check "  says not KEY=value"        out_has "is not KEY=value"
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "appflowy"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ] \
   || [ ! -f "$SERVICE_DIR/nginx.conf" ]; then
  red "services/appflowy/setup.sh, docker-compose.yml or nginx.conf is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_missing_nginx
test_fresh_deploy
test_open_signup_fails
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_base_url_drift
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_refuses_compose_overrides
test_teardown_https_port_differs
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_purge_marker_symlink
test_teardown_purge_refuses_repo_dir
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_env_lint

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
