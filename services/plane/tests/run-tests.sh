#!/usr/bin/env bash
#
# Tests for services/plane/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT STATE_DIR CALLS_LOG PLANE_ADMIN_EMAIL
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
file_mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
compose_hasF() { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }

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

no_published_https() {
  ! grep -v '^[[:space:]]*#' "$SVC/docker-compose.yml" | grep -qE ':443|LISTEN_HTTPS_PORT'
}

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
  export LOCAL_PORT=81o5
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, admin seeded, HTTP-only proxy, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records the local port"        grep -qx 'LOCAL_PORT=8105' "$SVC/.env"
  check "pinned to v1.4.2"                   grep -qx 'APP_RELEASE=v1.4.2' "$SVC/.env"
  check "WEB_URL is the tailnet URL"         grep -q '^WEB_URL=https://test-host\.tailfake\.ts\.net:8105$' "$SVC/.env"
  check "CORS matches WEB_URL"               grep -q '^CORS_ALLOWED_ORIGINS=https://test-host\.tailfake\.ts\.net:8105$' "$SVC/.env"
  check "admin email written"                grep -qx 'PLANE_ADMIN_EMAIL=admin@example.com' "$SVC/.env"
  check "admin password written"             grep -q '^PLANE_ADMIN_PASSWORD=.' "$SVC/.env"
  check "compose binds loopback"             compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose publishes no host wildcard" no_host_wildcard_port
  check "compose publishes no :443"          no_published_https
  check "minio is quay.io"                   compose_hasF 'quay.io/minio/minio'
  check "marker dir created"                 [ -d "$(sed -n 's/^PLANE_DATA=//p' "$SVC/.env")" ]
  check "compose up invoked"                 [ -f "$STATE_DIR/compose_up" ]
  check "waited on /api/instances/"          calls_have "127.0.0.1:8105/api/instances/"
  check "posted instance admin sign-up"      calls_have "/api/instances/admins/sign-up/"
  check "seeded the admin"                   out_has "First instance admin seeded"
  check "served :8105"                       calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
  check "no sudo needed (operator set)"      no_call "^sudo "
  check "prints final URL"                   out_has "https://test-host.tailfake.ts.net:8105"
  teardown
}

test_signup_warns() {
  echo "• admin sign-up fails: warned, not silently accepted"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/signup_fail"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "warns about God Mode"  out_has "god-mode"
  check "still prints the URL"  out_has "https://test-host.tailfake.ts.net:8105"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8115 HTTPS_PORT=8115
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8115' "$SVC/.env"
  check "WEB_URL uses new port"      grep -qx 'WEB_URL=https://test-host.tailfake.ts.net:8115' "$SVC/.env"
  check "health-checked :8115"       calls_have "127.0.0.1:8115/api/instances/"
  check "served :8115 -> :8115"      calls_have "tailscale serve --bg --https=8115 http://127.0.0.1:8115"
  check "prints the :8115 URL"       out_has "https://test-host.tailfake.ts.net:8115"

  export LOCAL_PORT=8116 HTTPS_PORT=8115
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8116 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8115' "$SVC/.env"
  check "re-run: still serves :8115" calls_have "tailscale serve --bg --https=8115 http://127.0.0.1:8115"
  check "re-run: never touched 8116" no_call "127.0.0.1:8116"
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
  check "  and never :8105"              no_call "tailscale serve --bg --https=8105"
  check "prints the :8110 URL"           out_has "https://test-host.tailfake.ts.net:8110"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8110 -> 127.0.0.1:8110" calls_have "tailscale serve --bg --https=8110 http://127.0.0.1:8110"
  check "  and never :8105"                   no_call "tailscale serve --bg --https=8105"
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
  check "polled health repeatedly"   [ "$(grep -c '/api/instances/' "$CALLS_LOG")" -gt 3 ]
  check "still published"            calls_have "tailscale serve --bg --https=8105"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, sign-up skipped"
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
  check "skipped sign-up"             out_has "already has an admin"
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
  teardown
}

test_web_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  old="$(grep '^WEB_URL=' "$SVC/.env")"
  export HTTPS_PORT=8108
  run_deploy
  check "warns about the drift"     out_has "WEB_URL in .env is"
  check "spells out the fix"        out_has "WEB_URL=https://test-host.tailfake.ts.net:8108"
  check ".env left alone (user's)"  [ "$(grep '^WEB_URL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=8105 http://127.0.0.1:8105"
  teardown
}

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
  if [ ! -f "$SERVICE_DIR/.env" ]; then
    red "    ! no $SERVICE_DIR/.env — deploy first with ./setup.sh"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "plane-proxy container running"   sh -c "docker inspect -f '{{.State.Status}}' plane-proxy | grep -qx running"
  live_check "plane-api container running"     sh -c "docker inspect -f '{{.State.Status}}' plane-api | grep -qx running"
  live_check "plane-db container running"      sh -c "docker inspect -f '{{.State.Status}}' plane-db | grep -qx running"
  live_check "local /api/instances/ is up"     sh -c "curl -fsS 'http://127.0.0.1:$port/api/instances/'"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS instances is up"   sh -c "curl -fsS --max-time 30 '$url:$https_port/api/instances/'"
  live_check "marker dir exists"               sh -c "test -d \"\$(sed -n 's/^PLANE_DATA=//p' '$SERVICE_DIR/.env')\""
}

data_dir() { sed -n 's/^PLANE_DATA=//p' "$SVC/.env"; }

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
  echo keep > "$(data_dir)/keep"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8105 (tailnet only)
|-- / proxy http://127.0.0.1:8105

https://test-host.tailfake.ts.net:18105 (tailnet only)
|-- / proxy http://127.0.0.1:18105
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8105"         calls_have "tailscale serve --https=8105 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18105 untouched"  no_call "https=18105"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/keep" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_detected() {
  echo "• teardown: a custom HTTPS port is found from serve status"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:8105\n' \
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
  printf 'https://test-host.tailfake.ts.net:8105 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  run_teardown --purge "plan"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/keep" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  check "wrong name: no down -v"      no_call "down -v"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "plane"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "down -v removes the volumes" calls_have "compose --project-directory $SVC down -v"
  check "  exactly one compose down"  [ "$(grep -c 'compose .*down' "$CALLS_LOG")" -eq 1 ]
  check "marker dir gone"             [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "setup.sh + compose kept"     [ -f "$SVC/setup.sh" ] && [ -f "$SVC/docker-compose.yml" ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  check "serve off for :8105"         calls_have "tailscale serve --https=8105 off"
  check "services dir itself kept"   [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "plane"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "plane"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "plane"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./plane" "$HOME/services/plane/.."; do
    sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "plane"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8105

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8105

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /pdf proxy http://127.0.0.1:8105
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8105 (left on, see above); 2 port(s) unpublished"
  teardown
}

# A data dir behind a folder this user cannot search (a root-owned 0700
# parent, faked with chmod 000): `[ -e ]` cannot see it, which must not read
# as "already gone" while .env is deleted. It must stop before anything
# changes (no `compose down`, no Serve change) and name the sudo command.
test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder stops before anything changes"
  deployed
  local st="$HOME/services/plane/storage"
  mkdir -p "$st/data"
  echo keep > "$st/data/marker"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "plane"
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
  run_teardown --purge "plane"
  chmod 755 "$HOME/services"
  check "services dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/keep" ]
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
|-- /pdf proxy http://127.0.0.1:8105
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    bash -c '! grep -q "already off" <<<"$1"' _ "$OUT"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8105 (left on, see above); 0 port(s) unpublished"
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
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8105'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8105 off"                   calls_have "serve --https=8105 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8105"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8105 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "plane"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "plane"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "plane"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "still down -v"               calls_have "down -v"
  teardown
}

test_teardown_purge_removes_empty_marker() {
  echo "• teardown --purge: the ~/services/plane marker goes even if PLANE_DATA was a subdir"
  deployed
  rm -f "$(data_dir)/keep"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/plane/state#" "$SVC/.env"
  run_teardown --purge "plane"
  check "subdir gone: exits zero"     [ "$CODE" -eq 0 ]
  check "  empty marker removed"      [ ! -e "$HOME/services/plane" ]
  teardown
  deployed
  mkdir -p "$HOME/services/plane/state"; echo x > "$HOME/services/plane/state/keep"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/plane/state#" "$SVC/.env"
  echo y > "$HOME/services/plane/other"
  run_teardown --purge "plane"
  check "subdir present: exits zero"  [ "$CODE" -eq 0 ]
  check "  subdir deleted"            [ ! -e "$HOME/services/plane/state" ]
  check "  non-empty marker kept"     [ -f "$HOME/services/plane/other" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"
  rm -rf "$HOME/services/plane"; ln -s "$HOME/elsewhere" "$HOME/services/plane"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/plane/state#" "$SVC/.env"
  run_teardown --purge "plane"
  check "symlinked marker: exits zero" [ "$CODE" -eq 0 ]
  check "  link left alone"           [ -L "$HOME/services/plane" ] && [ -d "$HOME/elsewhere" ]
  teardown
}

test_teardown_compose_overrides_refused() {
  echo "• teardown: COMPOSE_PROJECT_NAME / COMPOSE_FILE would point down -v elsewhere"
  deployed
  echo 'COMPOSE_PROJECT_NAME=other' >> "$SVC/.env"
  run_teardown --purge "plane"
  check ".env project name: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "COMPOSE_PROJECT_NAME is set"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  data kept"                 [ -f "$(data_dir)/keep" ]
  teardown
  deployed
  OUT="$(printf 'plane\n' | COMPOSE_FILE=/tmp/x.yml PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"; CODE=$?
  check "shell COMPOSE_FILE: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a $HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "plane"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "plane"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/plane itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "plane"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^PLANE_DATA=.*#PLANE_DATA=$HOME/services/plane/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/plane/a:b"
  run_teardown --purge "plane"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  local dir; dir="$(data_dir)"
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/plane"; echo x > "$HOME/plane/keep"
  run_teardown --purge "plane"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/plane/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'PLANE_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "PLANE_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nPLANE_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"    out_has "does not close on its line"
  teardown
  deployed
  printf 'Y="a\\"b"\n' >> "$SVC/.env"
  run_teardown
  check "backslash escape: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}


if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/plane/setup.sh or docker-compose.yml is missing — nothing to test."
  exit 1
fi

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/plane survives"
  deployed
  local repo="$HOME/services/plane/setup-server/services/plane"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/plane/setup-server/other.env"
  OUT="$(printf '%s\n' "plane" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/plane/setup-server/other.env" ]
  teardown
}

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_signup_warns
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_web_url_drift
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_purge_keeps_a_checkout_inside
test_teardown_https_port_detected
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
test_teardown_purge_removes_empty_marker
test_teardown_compose_overrides_refused
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
