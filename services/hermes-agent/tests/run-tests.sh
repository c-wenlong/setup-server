#!/usr/bin/env bash
#
# Tests for services/hermes-agent/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id. The curl stub
# answers the dashboard and the API health endpoint separately.

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
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/hermes-agent"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT API_PORT HTTPS_PORT STATE_DIR CALLS_LOG
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

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped — the file
# documents what it deliberately does NOT do ("network_mode: host"), so a
# naive grep would match the prose and not the config.
compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
# 0.0.0.0 is correct *inside* the container (the published loopback port
# forwards to it); only a wildcard *publish* is forbidden.
no_wildcard_bind() { ! compose_has "^[[:space:]]*-[[:space:]]*'0\\.0\\.0\\.0:"; }
no_host_net()      { ! compose_has 'network_mode: *host'; }

data_dir() { sed -n 's/^HERMES_DATA=//p' "$SVC/.env" | tr -d '"'; }

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
  export API_PORT=abc
  run_deploy
  check "API_PORT: exits non-zero"   [ "$CODE" -ne 0 ]
  check "API_PORT: says numeric"     out_has "must be numeric"
  unset API_PORT
  export LOCAL_PORT=91x9
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, both ports probed, published tailnet-only"
  setup
  # The hard case: the dashboard really is behind HTTP Basic, so anonymous
  # probes get a 401 and the script's authed waits are what get through.
  touch "$STATE_DIR/operator" "$STATE_DIR/dashboard_basic_auth"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env generated"                  [ -f "$SVC/.env" ]
  check ".env is mode 600"                [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has a hex dashboard secret" grep -qE '^HERMES_DASHBOARD_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env has a session secret"       grep -qE '^HERMES_DASHBOARD_SECRET=[a-f0-9]{32}$' "$SVC/.env"
  check ".env has a hex API key"          grep -qE '^API_SERVER_KEY=[a-f0-9]{32}$' "$SVC/.env"
  check ".env records the local port"     grep -qx 'LOCAL_PORT=9119' "$SVC/.env"
  check ".env records the API port"       grep -qx 'API_PORT=8642' "$SVC/.env"
  check "image tag pinned"                grep -qx 'HERMES_VERSION=v0.22.5' "$SVC/.env"
  check "comments survive verbatim"       grep -qxF "# Official image. 'latest'/'stable' track the stable release gate; v* tags" "$SVC/.env"
  check "compose publishes loopback only" compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "  API port too"                  compose_hasF '127.0.0.1:${API_PORT'
  check "compose binds no wildcard"       no_wildcard_bind
  check "no host networking"              no_host_net
  check "restart is unless-stopped"       compose_has 'restart: *unless-stopped'
  check "dashboard enabled"               compose_has 'HERMES_DASHBOARD: *"1"'
  check "dashboard auth is set"           compose_has 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD'
  check "API server enabled"              compose_has 'API_SERVER_ENABLED: *"true"'
  check "data dir created"                [ -d "$(data_dir)" ]
  check "compose up invoked"              [ -f "$STATE_DIR/compose_up" ]
  check "waited on the dashboard"         calls_have "127.0.0.1:9119/"
  check "  with the .env credentials"     calls_have "-u admin:"
  check "waited on the API health"        calls_have "127.0.0.1:8642/health"
  check "served on tailscale :9119"       calls_have "tailscale serve --bg --https=9119 http://127.0.0.1:9119"
  check "API port never published"        no_call "tailscale serve.*8642"
  check "no sudo needed (operator set)"   no_call "^sudo "
  check "prints final URL"                out_has "https://test-host.tailfake.ts.net:9119"
  check "prints where the login lives"    out_has "HERMES_DASHBOARD_PASSWORD"
  teardown
}

test_existing_native_install_warned_not_touched() {
  echo "• a native ~/.hermes + hermes-gateway unit is reported and left alone"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.hermes" "$HOME/.config/systemd/user"
  echo '[Service]' > "$HOME/.config/systemd/user/hermes-gateway.service"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns about the native install" out_has "native Hermes install"
  check "warns about the unit"          out_has "hermes-gateway.service exists and is left alone"
  check "native dir untouched"          [ -d "$HOME/.hermes" ]
  check "deploys its own data dir"      [ -d "$(data_dir)" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/API_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9120 API_PORT=8643 HTTPS_PORT=9120
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=9120' "$SVC/.env"
  check ".env records the API move"  grep -qx 'API_PORT=8643' "$SVC/.env"
  check "health-checked :9120"       calls_have "127.0.0.1:9120/"
  check "health-checked API :8643"   calls_have "127.0.0.1:8643/health"
  check "served :9120 -> :9120"      calls_have "tailscale serve --bg --https=9120 http://127.0.0.1:9120"
  check "prints the :9120 URL"       out_has "https://test-host.tailfake.ts.net:9120"

  export LOCAL_PORT=9121 API_PORT=8644 HTTPS_PORT=9120
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored LOCAL_PORT" out_has "LOCAL_PORT=9121 ignored"
  check "re-run: says it ignored API_PORT"   out_has "API_PORT=8644 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=9120' "$SVC/.env"
  check "re-run: API port unchanged" grep -qx 'API_PORT=8643' "$SVC/.env"
  check "re-run: still serves :9120" calls_have "tailscale serve --bg --https=9120 http://127.0.0.1:9120"
  check "re-run: never touched 9121" no_call "127.0.0.1:9121"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9122
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=9122"   grep -qx 'LOCAL_PORT=9122' "$SVC/.env"
  check "served :9122 -> 127.0.0.1:9122" calls_have "tailscale serve --bg --https=9122 http://127.0.0.1:9122"
  check "  and never :9119"              no_call "tailscale serve --bg --https=9119"
  check "prints the :9122 URL"           out_has "https://test-host.tailfake.ts.net:9122"
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                    [ "$CODE" -eq 0 ]
  check "re-run kept :9122 -> 127.0.0.1:9122"  calls_have "tailscale serve --bg --https=9122 http://127.0.0.1:9122"
  check "  and never :9119"                    no_call "tailscale serve --bg --https=9119"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9122 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:9122" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:9122"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loops wait instead of dying"
  setup
  touch "$STATE_DIR/operator"
  echo 3 > "$STATE_DIR/health_fails_left"
  echo 1 > "$STATE_DIR/api_fails_left"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "polled dashboard repeatedly" [ "$(grep -c '127.0.0.1:9119/' "$CALLS_LOG")" -gt 3 ]
  check "polled API too"            [ "$(grep -c '8642/health' "$CALLS_LOG")" -gt 1 ]
  check "still published"           calls_have "tailscale serve --bg --https=9119"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, secrets unchanged, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(sed -n 's/^HERMES_DASHBOARD_PASSWORD=//p' "$SVC/.env")"
  key="$(sed -n 's/^API_SERVER_KEY=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "password unchanged"          [ "$(sed -n 's/^HERMES_DASHBOARD_PASSWORD=//p' "$SVC/.env")" = "$pw" ]
  check "API key unchanged"           [ "$(sed -n 's/^API_SERVER_KEY=//p' "$SVC/.env")" = "$key" ]
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=9119 http://127.0.0.1:9119"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=9119 http://127.0.0.1:9119"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=9119 http://127.0.0.1:9119"
  teardown
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run (so .env and the data dir exist),
# Serve maps this port to this service, and neighbours sit on other ports
# (one a lookalike).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/sessions"
  echo '{}' > "$(data_dir)/config.yaml"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:9119 (tailnet only)
|-- / proxy http://127.0.0.1:9119

https://test-host.tailfake.ts.net:19119 (tailnet only)
|-- / proxy http://127.0.0.1:19119
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data + .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :9119"         calls_have "tailscale serve --https=9119 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :19119 untouched"  no_call "https=19119"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  in this project dir"       calls_have "compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "config kept"                 [ -f "$(data_dir)/config.yaml" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  rm -f "$STATE_DIR/compose_up"
  run_deploy
  check "setup.sh restores it"        [ "$CODE" -eq 0 ]
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
  printf 'https://test-host.tailfake.ts.net:9119 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "root: no compose down"       [ ! -f "$STATE_DIR/compose_down" ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "config kept"                 [ -f "$(data_dir)/config.yaml" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then the data dir and .env go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "hermes"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/config.yaml" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  check "warns what is lost"          out_has "session, skill and memory"
  run_teardown --purge "hermes-agent"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir \$HOME/services/hermes-agent removed" [ ! -e "$HOME/services/hermes-agent" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "serve off for :9119"         calls_have "tailscale serve --https=9119 off"
  check "down only, never down -v"    no_call "down -v"
  check "no sudo"                     no_call "^sudo"
  run_deploy
  check "fresh setup.sh exits zero"   [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the pinned image, not sudo"
  deployed
  local dir; dir="$(data_dir)"
  mkdir -p "$dir/locked"; echo x > "$dir/locked/k"
  chmod 500 "$dir/locked"
  run_teardown --purge "hermes-agent"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image"       calls_have "nousresearch/hermes-agent:v0.22.5"
  check "never pulled for it"         calls_have "pull never"
  check "runs it as root"             calls_have "--user 0"
  check "mounted the data dir"        calls_have "-v $dir:/x"
  check "no sudo"                     no_call "^sudo"
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(data_dir)"
  mkdir -p "$dir/locked"; echo x > "$dir/locked/f"
  chmod 500 "$dir/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "hermes-agent"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  check "  data kept for the retry"   [ -e "$dir" ]
  teardown
  deployed
  sed -i.bak 's/^HERMES_VERSION=.*/HERMES_VERSION=v0.22.5;x/' "$SVC/.env"
  run_teardown --purge "hermes-agent"
  check "odd image tag: exits non-zero" [ "$CODE" -ne 0 ]
  check "  data kept"                 [ -f "$(data_dir)/config.yaml" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "hermes-agent"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "hermes-agent"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "hermes-agent"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./hermes-agent" "$HOME/services/hermes-agent/.."; do
    sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "hermes-agent"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "config never touched"        [ -f "$HOME/services/hermes-agent/data/config.yaml" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:9120 (tailnet only)
|-- / proxy http://127.0.0.1:9119

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:9119

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /hermes proxy http://127.0.0.1:9119
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":9120 off"                   calls_have "serve --https=9120 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_units_left_alone() {
  echo "• teardown: a native hermes-gateway unit is named, never stopped"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/home/u/.hermes/venv/bin/python -m hermes_cli.main gateway run\n' \
    > "$HOME/.config/systemd/user/hermes-gateway.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/other.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the native unit"       out_has "hermes-gateway.service mentions hermes"
  check "  not the unrelated one"     out_lacks "other.service"
  check "  unit file kept"            [ -f "$HOME/.config/systemd/user/hermes-gateway.service" ]
  check "  no systemctl at all"       no_call "systemctl"
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
  check "no serve off"                no_call " off"
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='9119'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":9119 off"                   calls_have "serve --https=9119 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="9119"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check "  :9119 off"                 calls_have "serve --https=9119 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=9119 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "  :9119 off"                 calls_have "serve --https=9119 off"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'HERMES_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "HERMES_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nHERMES_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  echo "• teardown: COMPOSE_* in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "hermes-agent"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    check "  config kept"               [ -f "$(data_dir)/config.yaml" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose call"           no_call "compose --project-directory"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/hermes-agent survives"
  deployed
  local repo="$HOME/services/hermes-agent/setup-server/services/hermes-agent"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  copy_lib "${repo%/services/*}"
  echo secret > "$HOME/services/hermes-agent/setup-server/other.env"
  # Pointed at the state dir that holds the checkout: refused outright.
  sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$HOME/services/hermes-agent#" "$repo/.env"
  OUT="$(printf '%s\n' "hermes-agent" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "data dir holding it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$HOME/services/hermes-agent/setup-server/other.env" ]
  # The default data dir beside it: data goes, the checkout stays.
  sed -i.bak "s#^HERMES_DATA=.*#HERMES_DATA=$HOME/services/hermes-agent/data#" "$repo/.env"
  OUT="$(printf '%s\n' "hermes-agent" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "default data dir: exits zero" [ "$CODE" -eq 0 ]
  check "  data gone"                 [ ! -e "$HOME/services/hermes-agent/data" ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$HOME/services/hermes-agent/setup-server/other.env" ]
  check "  state dir kept (not empty)" [ -d "$HOME/services/hermes-agent" ]
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
# address — never a wildcard or a LAN interface. This service publishes HTTPS
# on the same number as the local port (9119 -> 9119), so tailscaled
# legitimately listens on the tailnet IP for that port. The API port has no
# Serve entry at all, so anything non-loopback there is a real failure.
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
    host="${addr%:*}"                            # strip :port
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6]
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
  local ts port https_port api_port url user pass api_key
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  api_port="$(sed -n 's/^API_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  user="$(sed -n 's/^HERMES_DASHBOARD_USERNAME=//p' "$SERVICE_DIR/.env")"
  pass="$(sed -n 's/^HERMES_DASHBOARD_PASSWORD=//p' "$SERVICE_DIR/.env")"
  api_key="$(sed -n 's/^API_SERVER_KEY=//p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "hermes-agent container running"    sh -c "docker inspect -f '{{.State.Status}}' hermes-agent | grep -qx running"
  live_check "dashboard answers locally"         sh -c "curl -fsS -o /dev/null -u '$user:$pass' 'http://127.0.0.1:$port/'"
  live_check "API health answers locally"        sh -c "curl -fsS -o /dev/null 'http://127.0.0.1:$api_port/health'"
  live_check "dashboard not on non-local ifaces" no_external_listener "$port"
  live_check "API port loopback only"            no_external_listener "$api_port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"            sh -c "curl -fsS -o /dev/null --max-time 30 -u '$user:$pass' '$url:$https_port/'"

  # The dashboard's basic-auth gate must actually be on: anonymous requests
  # bounce to login or get a 401/403, and the .env credentials get through.
  live_check "dashboard rejects anonymous" \
    sh -c "code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 '$url:$https_port/'); [ \"\$code\" != 200 ]"
  live_check "dashboard rejects a wrong password" \
    sh -c "code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -u '$user:wrong-password' '$url:$https_port/'); [ \"\$code\" != 200 ]"
  live_check "dashboard credentials in .env authenticate" \
    sh -c "curl -fsS -o /dev/null --max-time 30 -u '$user:$pass' '$url:$https_port/'"

  # The API is key-gated: /v1/models answers 401 without a Bearer key and
  # 200 with the one in .env. (Verified against the running container.)
  live_check "API rejects a request without the key" \
    sh -c "code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 'http://127.0.0.1:$api_port/v1/models'); [ \"\$code\" = 401 ] || [ \"\$code\" = 403 ]"
  live_check "API accepts the .env key" \
    sh -c "curl -fsS -o /dev/null --max-time 30 -H 'Authorization: Bearer $api_key' 'http://127.0.0.1:$api_port/v1/models'"

  live_check "data dir exists"                   sh -c "test -d \"\$(sed -n 's/^HERMES_DATA=//p' '$SERVICE_DIR/.env' | tr -d '\"')\""

  # The native gateway, when present, must still be up — this deploy shares
  # nothing with it and must not have stopped it.
  if [ -f "$HOME/.config/systemd/user/hermes-gateway.service" ] && command -v systemctl >/dev/null 2>&1; then
    live_check "native hermes-gateway unit still running" \
      sh -c "systemctl --user is-active hermes-gateway.service | grep -qx active"
  fi
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/hermes-agent/setup.sh or services/hermes-agent/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_existing_native_install_warned_not_touched
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_container_owned
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_units_left_alone
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge_keeps_a_checkout_inside

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
