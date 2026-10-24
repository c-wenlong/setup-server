#!/usr/bin/env bash
#
# Tests for services/stirling-pdf/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }

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

data_dir() { sed -n 's/^STIRLING_DATA=//p' "$SVC/.env"; }

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
  export LOCAL_PORT=81o3
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, published tailnet-only, login off"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records the local port"        grep -qx 'LOCAL_PORT=8103' "$SVC/.env"
  check "pinned to 2.14.3"                   grep -qx 'STIRLING_PDF_VERSION=2.14.3' "$SVC/.env"
  check "login is off"                       grep -qx 'SECURITY_ENABLELOGIN=false' "$SVC/.env"
  check "FRONTENDURL is the tailnet URL"     grep -q '^SYSTEM_FRONTENDURL=https://test-host\.tailfake\.ts\.net:8103$' "$SVC/.env"
  check "compose binds loopback"             compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose publishes no host wildcard" no_host_wildcard_port
  check "data dir created"                   [ -d "$(data_dir)/configs" ]
  check "compose up invoked"                 [ -f "$STATE_DIR/compose_up" ]
  check "waited on /api/v1/info/status"      calls_have "127.0.0.1:8103/api/v1/info/status"
  check "served :8103"                       calls_have "tailscale serve --bg --https=8103 http://127.0.0.1:8103"
  check "no sudo needed (operator set)"      no_call "^sudo "
  check "prints final URL"                   out_has "https://test-host.tailfake.ts.net:8103"
  check "says login is off"                  out_has "Login is off"
  teardown
}

test_login_on_warns() {
  echo "• login form still present: warned, not silently accepted"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/login_on"
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "warns about the form"     out_has "login form"
  check "still prints the URL"     out_has "https://test-host.tailfake.ts.net:8103"
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
  check "FRONTENDURL uses new port"  grep -qx 'SYSTEM_FRONTENDURL=https://test-host.tailfake.ts.net:8105' "$SVC/.env"
  check "health-checked :8105"       calls_have "127.0.0.1:8105/api/v1/info/status"
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
  check "  and never :8103"              no_call "tailscale serve --bg --https=8103"
  check "prints the :8110 URL"           out_has "https://test-host.tailfake.ts.net:8110"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8110 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8110 http://127.0.0.1:8110"
  check "  and never :8103"                   no_call "tailscale serve --bg --https=8103"
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
  check "polled health repeatedly"   [ "$(grep -c '/api/v1/info/status' "$CALLS_LOG")" -gt 3 ]
  check "still published"            calls_have "tailscale serve --bg --https=8103"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8103 http://127.0.0.1:8103"
  teardown
}

test_frontend_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  old="$(grep '^SYSTEM_FRONTENDURL=' "$SVC/.env")"
  export HTTPS_PORT=8104
  run_deploy
  check "warns about the drift"     out_has "SYSTEM_FRONTENDURL in .env is"
  check "spells out the fix"        out_has "SYSTEM_FRONTENDURL=https://test-host.tailfake.ts.net:8104"
  check ".env left alone (user's)"  [ "$(grep '^SYSTEM_FRONTENDURL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8103 http://127.0.0.1:8103"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=8103 http://127.0.0.1:8103"
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

  live_check "stirling-pdf container running"  sh -c "docker inspect -f '{{.State.Status}}' stirling-pdf | grep -qx running"
  live_check "local /api/v1/info/status is UP" sh -c "curl -fsS 'http://127.0.0.1:$port/api/v1/info/status' | grep -q '\"status\":\"UP\"'"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS status is UP"      sh -c "curl -fsS --max-time 30 '$url:$https_port/api/v1/info/status' | grep -q '\"status\":\"UP\"'"
  live_check "root does not bounce to /login"  sh -c "! curl -sS -D - -o /dev/null '$url:$https_port/' | grep -qi 'Location:.*/login'"
  live_check "state dir exists"                sh -c "test -d \"\$(sed -n 's/^STIRLING_DATA=//p' '$SERVICE_DIR/.env')\""
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
  mkdir -p "$(data_dir)/configs"
  echo keep > "$(data_dir)/configs/settings.yml"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8103 (tailnet only)
|-- / proxy http://127.0.0.1:8103

https://test-host.tailfake.ts.net:18103 (tailnet only)
|-- / proxy http://127.0.0.1:18103
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8103"         calls_have "tailscale serve --https=8103 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18103 untouched"  no_call "https=18103"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/configs/settings.yml" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_from_frontend_url() {
  echo "• teardown: HTTPS port comes from SYSTEM_FRONTENDURL"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:8103\n' \
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
  printf 'https://test-host.tailfake.ts.net:8103 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  echo "• teardown --purge: typed confirmation, then data and .env go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "stirling"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/configs/settings.yml" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "stirling-pdf"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :8103"         calls_have "tailscale serve --https=8103 off"
  check "services dir itself kept"   [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8103

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8103

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /pdf proxy http://127.0.0.1:8103
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
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
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8103'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8103 off"                   calls_have "serve --https=8103 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8103"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8103 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "stirling-pdf"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "stirling-pdf"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a $HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^STIRLING_DATA=.*#STIRLING_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "stirling-pdf"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/stirling-pdf/setup.sh or docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_login_on_warns
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_frontend_url_drift
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_https_port_from_frontend_url
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_home_variable_in_env

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
