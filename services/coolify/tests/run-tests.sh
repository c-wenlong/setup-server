#!/usr/bin/env bash
#
# Tests for services/coolify/setup.sh and teardown.sh.
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
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
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

test_authorized_keys_append() {
  echo "• authorized_keys: key goes on its own line, exact match only"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAAuserkey me@laptop' > "$HOME/.ssh/authorized_keys"
  run_deploy
  pub="$(cat "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub")"
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "user's key line kept intact"     grep -qx 'ssh-ed25519 AAAAuserkey me@laptop' "$HOME/.ssh/authorized_keys"
  check "coolify key on its own line"     grep -qxF "$pub" "$HOME/.ssh/authorized_keys"
  check "file is exactly two lines"       [ "$(wc -l < "$HOME/.ssh/authorized_keys" | tr -d ' ')" = 2 ]
  # A commented-out copy of the key must not count as present.
  printf '# %s\n' "$pub" > "$HOME/.ssh/authorized_keys"
  run_deploy
  check "commented copy not treated as present" grep -qxF "$pub" "$HOME/.ssh/authorized_keys"
  run_deploy
  check "re-run adds no duplicate"        [ "$(grep -cxF "$pub" "$HOME/.ssh/authorized_keys")" = 1 ]
  # An operator-restricted entry (options prefix, other comment) is the key.
  blob="$(printf '%s\n' "$pub" | awk '{ print $2 }')"
  printf 'from="100.64.0.0/10",no-pty ssh-ed25519 %s locked\n' "$blob" > "$HOME/.ssh/authorized_keys"
  run_deploy
  check "restricted entry counts as present" [ "$(wc -l < "$HOME/.ssh/authorized_keys" | tr -d ' ')" = 1 ]
  check "says the key is already there"   out_has "Coolify pubkey already in"
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

key_line() { cat "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"; }
auth_file() { printf '%s' "$HOME/.ssh/authorized_keys"; }
lacks_line() { ! grep -qxF -- "$1" "$2"; }

# A deployed sandbox: setup.sh has run (so Coolify's key line is in
# authorized_keys next to the user's own keys), Serve maps the dashboard and
# Soketi ports here, and neighbours sit on other ports (lookalike suffixes).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/backups/coolify"
  echo keep > "$(data_dir)/backups/coolify/dump.sql"
  local auth; auth="$(auth_file)"
  {
    echo "ssh-ed25519 AAAAuserkey me@laptop"
    cat "$auth"
    echo "ssh-ed25519 AAAAotherkey coolify"
    echo "# trailing comment"
  } > "$auth.new"
  cat "$auth.new" > "$auth"; rm -f "$auth.new"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8101 (tailnet only)
|-- / proxy http://127.0.0.1:8101

https://test-host.tailfake.ts.net:6001 (tailnet only)
|-- / proxy http://127.0.0.1:6001

https://test-host.tailfake.ts.net:18101 (tailnet only)
|-- / proxy http://127.0.0.1:18101

https://test-host.tailfake.ts.net:16001 (tailnet only)
|-- / proxy http://127.0.0.1:16001
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down" "$STATE_DIR/compose_down_v"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data, .env and the SSH key; unpublishes only its ports"
  deployed
  local before; before="$(cat "$(auth_file)")"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8101"         calls_have "tailscale serve --https=8101 off"
  check "serve off for soketi :6001"  calls_have "tailscale serve --https=6001 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18101 untouched"  no_call "https=18101"
  check "lookalike :16001 untouched"  no_call "https=16001"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                calls_have "compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/backups/coolify/dump.sql" ]
  check "SSH key kept"                [ -f "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal" ]
  check "authorized_keys unchanged"   [ "$(cat "$(auth_file)")" = "$before" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "never runs a cleanup container" no_call "docker run"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_leaves_coolify_apps() {
  echo "• teardown: apps Coolify deployed keep running and are named"
  deployed
  printf '%s\n' "coolify running" "my-app-x1 running" "pg-y2 exited" > "$STATE_DIR/managed_containers"
  mkdir -p "$(data_dir)/applications/x1"; echo app > "$(data_dir)/applications/x1/compose.yml"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "lists the app it left"       out_has "Left alone.*my-app-x1 (running)"
  check "lists the stopped one too"   out_has "pg-y2 (exited)"
  check "does not list its own stack" out_lacks ": coolify (running)"
  check "never stops or removes them" no_call "docker stop\|docker rm\|docker kill"
  check "app data kept"               [ -f "$(data_dir)/applications/x1/compose.yml" ]
  teardown
  deployed
  touch "$STATE_DIR/managed_ps_fails"
  run_teardown
  check "listing fails: still exits zero" [ "$CODE" -eq 0 ]
  check "  and says so"               out_has "Could not list Coolify-deployed containers"
  check "  and still compose down"    [ -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_units_not_touched() {
  echo "• teardown: systemd units setup.sh never wrote are named, not touched"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/usr/bin/docker exec coolify-db pg_dump\n' > "$HOME/.config/systemd/user/coolify-backup.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/other.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit"              out_has "coolify-backup.service"
  check "does not name unrelated units" out_lacks "other.service"
  check "never calls systemctl"       no_call "systemctl"
  check "unit file kept"              [ -f "$HOME/.config/systemd/user/coolify-backup.service" ]
  run_teardown --purge "coolify"
  check "purge also keeps it"         [ -f "$HOME/.config/systemd/user/coolify-backup.service" ]
  teardown
}

test_teardown_https_port_from_override() {
  echo "• teardown: a non-default HTTPS port pointing here goes off"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:8101\n' \
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
  printf 'https://test-host.tailfake.ts.net:8101 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: no compose down"  [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then Coolify's state, .env and its key line go"
  deployed
  local dir key auth before
  dir="$(data_dir)"; key="$(key_line)"; auth="$(auth_file)"
  before="$(cat "$auth")"
  run_teardown --purge "Coolify"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/backups/coolify/dump.sql" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  check "wrong name: authorized_keys unchanged" [ "$(cat "$auth")" = "$before" ]
  run_teardown --purge "coolify"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "down -v (volumes go)"        calls_have "compose --project-directory $SVC down -v"
  check "data dir gone"               [ ! -e "$dir" ]
  check "marker ~/services/coolify gone" [ ! -e "$HOME/services/coolify" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :8101"         calls_have "tailscale serve --https=8101 off"
  check "serve off for :6001"         calls_have "tailscale serve --https=6001 off"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "Coolify's key line gone"     lacks_line "$key" "$auth"
  check "user's own key kept"         grep -qx "ssh-ed25519 AAAAuserkey me@laptop" "$auth"
  check "lookalike ' coolify' key kept" grep -qx "ssh-ed25519 AAAAotherkey coolify" "$auth"
  check "comment kept"                grep -qx "# trailing comment" "$auth"
  check "exactly one line removed"    [ "$(grep -c '' "$auth")" -eq "$(( $(printf '%s\n' "$before" | grep -c '') - 1 ))" ]
  check "authorized_keys still 600"   [ "$(file_mode "$auth")" = "600" ]
  check "says it removed the key"     out_has "Removed Coolify's key line"
  teardown
}

test_teardown_purge_refuses_user_apps() {
  echo "• teardown --purge: refuses while Coolify-deployed apps, databases or services exist"
  local sub
  for sub in applications databases services; do
    deployed
    mkdir -p "$(data_dir)/$sub/u1"; echo mine > "$(data_dir)/$sub/u1/data"
    run_teardown --purge "coolify"
    check "$sub non-empty: exits non-zero" [ "$CODE" -ne 0 ]
    check "  tells you to remove them in Coolify" out_has "Coolify dashboard first"
    check "  user data kept"            [ -f "$(data_dir)/$sub/u1/data" ]
    check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    check "  key line kept"             grep -qxF "$(key_line)" "$(auth_file)"
    teardown
  done
  deployed
  printf '%s\n' "my-app-x1 running" > "$STATE_DIR/managed_containers"
  run_teardown --purge "coolify"
  check "deployed container: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names it"                  out_has "my-app-x1 (running)"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  data kept"                 [ -f "$(data_dir)/backups/coolify/dump.sql" ]
  teardown
  deployed
  touch "$STATE_DIR/managed_ps_fails"
  run_teardown --purge "coolify"
  check "container listing fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf '%s\n' "coolify running" "coolify-db running" "coolify-redis running" "coolify-realtime running" \
    > "$STATE_DIR/managed_containers"
  run_teardown --purge "coolify"
  check "only its own four containers: purge goes ahead" [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_rechecks_after_stop() {
  echo "• teardown --purge: stops Coolify, then re-checks for apps deployed during the prompt"
  deployed
  run_teardown --purge "coolify"
  check "clean purge: stack stopped before down -v" \
    [ "$(grep -n 'compose .* stop$' "$CALLS_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'down -v' "$CALLS_LOG" | head -1 | cut -d: -f1)" ]
  teardown
  deployed
  printf '%s\n' "late-app-z9 running" > "$STATE_DIR/managed_after_stop"
  run_teardown --purge "coolify"
  check "app deployed during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  passed the first check (stack was stopped)" [ -f "$STATE_DIR/compose_stop" ]
  check "  names it"                  out_has "late-app-z9 (running)"
  check "  says the stack is stopped and setup.sh restores it" out_has "./setup.sh brings it back"
  check "  no down -v (volumes intact)" no_call "down -v"
  check "  data kept"                 [ -f "$(data_dir)/backups/coolify/dump.sql" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  key line kept"             grep -qxF "$(key_line)" "$(auth_file)"
  teardown
  deployed
  rm -rf "$(data_dir)/applications"
  printf '%s' "$(data_dir)/applications/late" > "$STATE_DIR/busy_after_stop"
  run_teardown --purge "coolify"
  check "app dir created during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names COOLIFY_APPLICATIONS" out_has "COOLIFY_APPLICATIONS="
  check "  no down -v (volumes intact)" no_call "down -v"
  check "  the new app's files kept"  [ -f "$(data_dir)/applications/late/app.yml" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  touch "$STATE_DIR/stop_fails"
  run_teardown --purge "coolify"
  check "compose stop fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no down -v"                no_call "down -v"
  check "  data kept"                 [ -f "$(data_dir)/backups/coolify/dump.sql" ]
  teardown
}

test_teardown_purge_key_line_edge_cases() {
  echo "• teardown --purge: authorized_keys is only edited for setup.sh's exact key line"
  deployed
  local before; before="$(cat "$(auth_file)")"
  rm -f "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"
  run_teardown --purge "coolify"
  check "pubkey gone: exits zero"     [ "$CODE" -eq 0 ]
  check "  authorized_keys unchanged" [ "$(cat "$HOME/.ssh/authorized_keys")" = "$before" ]
  check "  says to check by hand"     out_has "left alone"
  teardown
  deployed
  before="$(cat "$(auth_file)")"
  printf 'ssh-ed25519 AAAAuserkey me@laptop\n' > "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"
  run_teardown --purge "coolify"
  check "pubkey not Coolify's shape: exits zero" [ "$CODE" -eq 0 ]
  check "  user's key not removed"    [ "$(cat "$HOME/.ssh/authorized_keys")" = "$before" ]
  teardown
  deployed
  : > "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"
  before="$(cat "$(auth_file)")"
  run_teardown --purge "coolify"
  check "empty pubkey: authorized_keys unchanged" [ "$(cat "$HOME/.ssh/authorized_keys")" = "$before" ]
  teardown
  deployed
  rm -f "$(auth_file)"
  run_teardown --purge "coolify"
  check "no authorized_keys: exits zero" [ "$CODE" -eq 0 ]
  check "  and does not create one"   [ ! -e "$HOME/.ssh/authorized_keys" ]
  teardown
}

test_teardown_purge_container_owned_files() {
  echo "• teardown --purge: files the Coolify container owns are cleared with its image"
  deployed
  local dir; dir="$(data_dir)"
  mkdir -p "$dir/ssh/mux"; echo x > "$dir/ssh/mux/sock"; chmod 0500 "$dir/ssh/mux"
  run_teardown --purge "coolify"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image, no pull" calls_have "docker run --rm --pull never --user 0:0 -v $dir/ssh:/x --entrypoint sh docker.io/coollabsio/coolify:4.3.21"
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(data_dir)"
  mkdir -p "$dir/ssh/mux"; echo x > "$dir/ssh/mux/sock"; chmod 0500 "$dir/ssh/mux"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "coolify"
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names sudo rm -rf"         out_has "sudo rm -rf $dir/ssh"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./coolify" "$HOME/services/coolify/.."; do
    sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "coolify"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  sed -i.bak "s#^COOLIFY_SSH=.*#COOLIFY_SSH=$HOME/.ssh#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "COOLIFY_SSH=~/.ssh refused"  [ "$CODE" -ne 0 ]
  check "  ~/.ssh kept"               [ -f "$HOME/.ssh/authorized_keys" ]
  teardown
  deployed
  sed -i.bak "/^COOLIFY_BACKUPS=/d" "$SVC/.env"
  run_teardown --purge "coolify"
  check "COOLIFY_BACKUPS missing: refused" [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8101

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8101
|-- /app proxy http://127.0.0.1:6001

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /coolify proxy http://127.0.0.1:8101
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 (dashboard + soketi) off" calls_have "serve --https=8443 off"
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
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8101'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8101 off"                   calls_have "serve --https=8101 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8101"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^SOKETI_PORT=.*/SOKETI_PORT=6001 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check ":6001 off"                   calls_have "serve --https=6001 off"
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "coolify"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/coolify///#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$HOME/services/coolify" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "coolify"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a $HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/coolify itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^COOLIFY_DATA=.*#COOLIFY_DATA=$HOME/services/coolify#" "$SVC/.env"
  sed -i.bak "s#^COOLIFY_IMAGES=.*#COOLIFY_IMAGES=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "coolify"
  check "COOLIFY_IMAGES in another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  sed -i.bak "s#^COOLIFY_IMAGES=.*#COOLIFY_IMAGES=$HOME/services/coolify/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/coolify/a:b"
  run_teardown --purge "coolify"
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
  mkdir -p "$HOME/coolify"; echo x > "$HOME/coolify/keep"
  run_teardown --purge "coolify"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/coolify/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'COOLIFY_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "COOLIFY_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nCOOLIFY_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_PROFILES in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "coolify"
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

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/coolify survives"
  deployed
  local repo="$HOME/services/coolify/setup-server/services/coolify"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/coolify/setup-server/other.env"
  OUT="$(printf '%s\n' "coolify" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/coolify/setup-server/other.env" ]
  teardown
}

test_teardown_network_still_in_use() {
  echo "• teardown: a coolify network still used by deployed apps is kept, not fatal"
  deployed
  printf '%s\n' "my-app-x1 running" > "$STATE_DIR/managed_containers"
  touch "$STATE_DIR/down_network_busy"
  printf 'my-app-x1 coolify-proxy ' > "$STATE_DIR/network_users"
  run_teardown
  check "down exits 1 (older Compose): still exits zero" [ "$CODE" -eq 0 ]
  check "  names who keeps the network" out_has "Docker kept the 'coolify' network: still used by my-app-x1 coolify-proxy\."
  check "  still lists the apps left alone" out_has "Left alone.*my-app-x1"
  check "  data and .env kept"        [ -f "$(data_dir)/backups/coolify/dump.sql" ] && [ -f "$SVC/.env" ]
  check "  finishes"                  out_has "./setup.sh brings it back"
  teardown
  deployed
  touch "$STATE_DIR/down_network_busy"
  printf 'my-app-x1 ' > "$STATE_DIR/network_users"
  echo "c0ffee" > "$STATE_DIR/own_left"
  run_teardown
  check "own containers still there: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                   out_has "Coolify's own containers are still there"
  teardown
  deployed
  touch "$STATE_DIR/down_network_busy"
  run_teardown
  check "down failed, network already gone: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it was not the network" out_has "not because of the coolify network"
  teardown
  deployed
  touch "$STATE_DIR/down_network_busy"
  printf 'hand-attached ' > "$STATE_DIR/network_users"
  local gone; gone="$(data_dir)"
  run_teardown --purge "coolify"
  check "purge, network in use: exits zero" [ "$CODE" -eq 0 ]
  check "  data dir gone"             [ ! -e "$gone" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  check "  names the container"       out_has "still used by hand-attached\."
  teardown
  deployed
  local dir key; dir="$(data_dir)"; key="$(key_line)"
  touch "$STATE_DIR/down_network_busy"
  printf 'hand-attached ' > "$STATE_DIR/network_users"
  printf '%s\n' "other-volume" "coolify-db" > "$STATE_DIR/volumes_left"
  run_teardown --purge "coolify"
  check "purge, a volume survived: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says which"                out_has "coolify-db / coolify-redis volume is still there"
  check "  data dir kept"             [ -f "$dir/backups/coolify/dump.sql" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  key line kept"             grep -qxF -- "$key" "$(auth_file)"
  teardown
}

test_teardown_purge_key_line_lookalikes() {
  echo "• teardown --purge: lookalike, CRLF and unterminated key lines; symlinked or multi-line .pub"
  deployed
  local key auth cr before
  key="$(key_line)"; auth="$(auth_file)"; cr="$(printf '\r')"
  {
    echo "ssh-ed25519 AAAAuserkey me@laptop"
    printf '%s\n' "$key extra" " $key" "# $key" "$key$cr"
    printf '%s' "$key"
  } > "$auth"
  run_teardown --purge "coolify"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "unterminated last line (Coolify's) removed" lacks_line "$key" "$auth"
  check "user key kept"               grep -qxF -- "ssh-ed25519 AAAAuserkey me@laptop" "$auth"
  check "'<key> extra' kept"          grep -qxF -- "$key extra" "$auth"
  check "' <key>' kept"               grep -qxF -- " $key" "$auth"
  check "'# <key>' kept"              grep -qxF -- "# $key" "$auth"
  check "'<key>\\r' kept"             grep -qxF -- "$key$cr" "$auth"
  check "exactly five lines left"     [ "$(grep -c '' "$auth")" -eq 5 ]
  teardown
  deployed
  key="$(key_line)"; auth="$(auth_file)"
  printf 'ssh-ed25519 AAAAuserkey me@laptop\r\n%s\r\n' "$key" > "$auth"
  cp "$auth" "$SANDBOX/auth.before"
  run_teardown --purge "coolify"
  check "CRLF file: exits zero"       [ "$CODE" -eq 0 ]
  check "  left byte-for-byte alone"  cmp -s "$auth" "$SANDBOX/auth.before"
  teardown
  deployed
  auth="$(auth_file)"
  local pub; pub="$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"
  printf 'ssh-ed25519 AAAAuserkey coolify\n' > "$HOME/mine.pub"
  printf 'ssh-ed25519 AAAAuserkey coolify\n' >> "$auth"
  cp "$auth" "$SANDBOX/auth.before"
  rm -f "$pub"; ln -s "$HOME/mine.pub" "$pub"
  run_teardown --purge "coolify"
  check "symlinked .pub: exits zero"  [ "$CODE" -eq 0 ]
  check "  authorized_keys unchanged" cmp -s "$auth" "$SANDBOX/auth.before"
  check "  says it is a symlink"      out_has "is a symlink"
  check "  the link's target kept"    [ -f "$HOME/mine.pub" ]
  teardown
  deployed
  key="$(key_line)"; auth="$(auth_file)"
  printf '%s\n%s\n' "$key" "ssh-ed25519 AAAAuserkey me@laptop" > "$(data_dir)/ssh/keys/id.${USER}@host.docker.internal.pub"
  cp "$auth" "$SANDBOX/auth.before"
  run_teardown --purge "coolify"
  check "two-line .pub: authorized_keys unchanged" cmp -s "$auth" "$SANDBOX/auth.before"
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/teardown.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/coolify/setup.sh, teardown.sh or docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_authorized_keys_append
test_open_register_fails
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_app_url_drift
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_leaves_coolify_apps
test_teardown_units_not_touched
test_teardown_https_port_from_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_refuses_user_apps
test_teardown_purge_rechecks_after_stop
test_teardown_purge_key_line_edge_cases
test_teardown_purge_container_owned_files
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge_keeps_a_checkout_inside
test_teardown_network_still_in_use
test_teardown_purge_key_line_lookalikes

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
