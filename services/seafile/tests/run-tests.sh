#!/usr/bin/env bash
#
# Tests for services/seafile/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed fake server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite copies setup.sh + teardown.sh + docker-compose.yml into a sandbox and runs
# the real script there with PATH stubs for docker/tailscale/curl/sudo/id, so
# the repo never gets a test .env and the host system is never touched.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
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
out_lacks()  { ! grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

data_dir()  { sed -n 's/^SEAFILE_VOLUME=//p' "$SVC/.env"; }
mysql_dir() { sed -n 's/^SEAFILE_MYSQL_VOLUME=//p' "$SVC/.env"; }

# ----------------------------------------------------------------- tests
test_preflight_docker_perms() {
  echo "• preflight fails when user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests usermod fix"   out_has "usermod -aG docker"
  else
    check "suggests Docker Desktop" out_has "Docker Desktop"
  fi
  check "wrote no .env"            [ ! -f "$SVC/.env" ]
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

test_preflight_bad_https_port() {
  echo "• preflight rejects a non-numeric HTTPS port"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "must be numeric"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has hostname with port"    env_has "SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:8443"
  check ".env has generated JWT key"     sh -c "grep -E '^JWT_PRIVATE_KEY=[0-9a-f]{64}$' '$SVC/.env' >/dev/null"
  check ".env has admin password"        sh -c "grep -E '^INIT_SEAFILE_ADMIN_PASSWORD=.+' '$SVC/.env' >/dev/null"
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]
  check "data dirs created under HOME"   [ -d "$HOME/services/seafile/data" ]
  check "served on tailscale :8443"      calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8081"
  check "prints final URL"               out_has "https://test-host.tailfake.ts.net:8443"
  check "prints admin credentials"       out_has "ADMIN_EMAIL"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env (secrets) preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:8443
INIT_SEAFILE_ADMIN_EMAIL=x@y.z
INIT_SEAFILE_ADMIN_PASSWORD=my-custom-secret
EOF
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "existing .env untouched"  env_has "my-custom-secret"
  check "says config untouched"    out_has "leaving untouched"
  check "never invoked sudo"       no_call "^sudo "
  check "compose up re-invoked"    [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT override"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9081 HTTPS_PORT=10000
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has custom local port"  env_has "LOCAL_PORT=9081"
  check "hostname carries 10000"      env_has "SEAFILE_SERVER_HOSTNAME=test-host.tailfake.ts.net:10000"
  check "served on :10000 -> 9081"    calls_have "tailscale serve --bg --https=10000 http://127.0.0.1:9081"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published"    calls_have "tailscale serve --bg --https=8443"
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

# Portable: BSD (macOS) tools lack grep -P and ss.
no_external_listener() {
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | grep ":$port" | grep -v 127.0.0.1 | grep -q LISTEN)
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -v '^127\.0\.0\.1' | grep -q .)
  fi
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port hport url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  hport="$(sed -n 's/^SEAFILE_SERVER_HOSTNAME=.*:\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="https://$(sed -n 's/^SEAFILE_SERVER_HOSTNAME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "3 containers running"           sh -c "[ \"\$(docker compose --project-directory '$SERVICE_DIR' ps --status running -q | wc -l)\" -ge 3 ]"
  live_check "seafile container healthy"      sh -c "docker inspect -f '{{.State.Health.Status}}' seafile | grep -qx healthy"
  live_check "local web UI responds"          sh -c "curl -fsS -o /dev/null http://127.0.0.1:$port/"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$hport"   sh -c "'$ts' serve status | grep -A2 ':$hport' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"         curl -fsS -o /dev/null --max-time 30 "$url/"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run, both data dirs hold something, Serve
# maps :8443 to this service, and neighbours sit on other ports (one a
# lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/seafile-data/storage" "$(mysql_dir)/seafile_db"
  echo keep > "$(data_dir)/seafile-data/storage/block"
  echo keep > "$(mysql_dir)/seafile_db/repo.ibd"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8081

https://test-host.tailfake.ts.net:18443 (tailnet only)
|-- / proxy http://127.0.0.1:18081
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8443"         calls_have "tailscale serve --https=8443 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18443 untouched"  no_call "https=18443"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no container cleanup run"    no_call "entrypoint sh"
  check "seafile data kept"           [ -f "$(data_dir)/seafile-data/storage/block" ]
  check "mysql data kept"             [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  check "warns .env password may be stale" out_has "stale copy"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_port_override() {
  echo "• teardown: a custom local port is read from .env"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9081 HTTPS_PORT=10000
  run_deploy
  unset LOCAL_PORT HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:10000 (tailnet only)\n|-- / proxy http://127.0.0.1:9081\n\nhttps://test-host.tailfake.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:8081\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :10000"        calls_have "tailscale serve --https=10000 off"
  check "default :8443 not touched"   no_call "https=8443"
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
  printf 'https://test-host.tailfake.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: no serve off"     no_call " off"
  rm -f "$STATE_DIR/docker_no_perm"
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=abc/' "$SVC/.env"
  run_teardown
  check "bad LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "bad LOCAL_PORT: no serve off" no_call " off"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then data, mysql, .env and marker go"
  deployed
  local data mysql; data="$(data_dir)"; mysql="$(mysql_dir)"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "seafil"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$data/seafile-data/storage/block" ]
  check "wrong name: mysql kept"      [ -f "$mysql/seafile_db/repo.ibd" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge ""
  check "empty answer: exits non-zero" [ "$CODE" -ne 0 ]
  check "empty answer: data kept"     [ -f "$data/seafile-data/storage/block" ]
  run_teardown --purge "seafile"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns synced files go"       out_has "every synced file"
  check "warns photo backups go"      out_has "photo backups"
  check "says clients keep local copies" out_has "keep their local copies"
  check "names the services that lose it" out_has "gnosia-learn reads this .env"
  check "seafile data dir gone"       [ ! -e "$data" ]
  check "mysql data dir gone"         [ ! -e "$mysql" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker ~/services/seafile gone" [ ! -e "$HOME/services/seafile" ]
  check "serve off for :8443"         calls_have "tailscale serve --https=8443 off"
  check "down only, never down -v"    no_call "down -v"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  check "compose files kept"          [ -f "$SVC/docker-compose.yml" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "mysql kept"                  [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  sed -i.bak "/^SEAFILE_VOLUME=/d" "$SVC/.env"
  run_teardown --purge "seafile"
  check "missing SEAFILE_VOLUME refused" [ "$CODE" -ne 0 ]
  check "  says it will not guess"    out_has "refusing to guess"
  printf 'SEAFILE_VOLUME=%s/services/seafile/data\n' "$HOME" >> "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./seafile" "$HOME/services/seafile/.."; do
    sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$dotted#" "$SVC/.env"
    run_teardown --purge "seafile"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "nothing ever stopped"        [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_mysql_dir_checked_too() {
  echo "• teardown --purge: SEAFILE_MYSQL_VOLUME gets the same checks"
  deployed
  local data; data="$(data_dir)"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  seafile data kept too"     [ -f "$data/seafile-data/storage/block" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=$HOME/services/seafile/../neighbour#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "/^SEAFILE_MYSQL_VOLUME=/d" "$SVC/.env"
  run_teardown --purge "seafile"
  check "missing SEAFILE_MYSQL_VOLUME refused" [ "$CODE" -ne 0 ]
  check "  seafile data still kept"   [ -f "$data/seafile-data/storage/block" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8081

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8081

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /drive proxy http://127.0.0.1:8081
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8081 (left on, see above); 2 port(s) unpublished"
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
  run_teardown --purge "seafile"
  check "purge: exits non-zero"       [ "$CODE" -ne 0 ]
  check "purge: data kept"            [ -f "$(data_dir)/seafile-data/storage/block" ]
  check "purge: .env kept"            [ -f "$SVC/.env" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8081'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8443 off"                   calls_have "serve --https=8443 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8081"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check ":8443 off"                   calls_have "serve --https=8443 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8081 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check ":8443 off"                   calls_have "serve --https=8443 off"
  teardown
  deployed
  local data; data="$(data_dir)"
  sed -i.bak -e "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=\"$data\"   \# quoted#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "quoted data path: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$data" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "seafile"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services/neighbour" "$HOME/services/seafile/linked"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/seafile/linked#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "symlinked leaf inside seafile refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  rm -f "$HOME/services/seafile/linked"
  local data; data="$HOME/services/seafile/data"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$data///#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$data" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: data dirs already gone is fine; marker still goes"
  deployed
  rm -rf "$(data_dir)" "$(mysql_dir)"
  run_teardown --purge "seafile"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/seafile" ]
  teardown
  deployed
  echo note > "$HOME/services/seafile/README-mine"
  run_teardown --purge "seafile"
  check "non-empty marker: exits zero" [ "$CODE" -eq 0 ]
  check "  marker kept (rmdir only)"  [ -f "$HOME/services/seafile/README-mine" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(mysql_dir)"
  sed -i.bak "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=\$HOME${dir#"$HOME"}#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "unquoted \$HOME form: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/seafile itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/seafile-old"; echo x > "$HOME/services/seafile-old/keep"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/seafile-old#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "lookalike seafile-old refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/seafile-old/keep" ]
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/seafile/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/seafile/a:b"
  run_teardown --purge "seafile"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
  deployed
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$HOME/services/seafile#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "the marker dir itself: exits zero" [ "$CODE" -eq 0 ]
  check "  marker and both dirs gone" [ ! -e "$HOME/services/seafile" ]
  check "  services dir kept"         [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/seafile/data"; echo x > "$HOME/seafile/data/keep"
  run_teardown --purge "seafile"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/seafile/data/keep" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  rm -f "$HOME/services"
  teardown
  deployed
  mv "$HOME/services/seafile" "$HOME/elsewhere"
  ln -s "$HOME/elsewhere" "$HOME/services/seafile"
  run_teardown --purge "seafile"
  check "symlinked ~/services/seafile refused" [ "$CODE" -ne 0 ]
  check "  its target kept"           [ -f "$HOME/elsewhere/data/seafile-data/storage/block" ]
  teardown
}

test_teardown_purge_never_its_own_checkout() {
  echo "• teardown --purge: refuses a data dir that holds teardown.sh itself"
  deployed
  local own="$HOME/services/seafile"
  cp "$SVC/setup.sh" "$SVC/teardown.sh" "$SVC/docker-compose.yml" "$SVC/.env" "$own/"
  SVC="$own"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$own#" "$SVC/.env"
  run_teardown --purge "seafile"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "holds this checkout"
  check "  scripts kept"              [ -f "$own/teardown.sh" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SEAFILE_VOLUME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "SEAFILE_VOLUME is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nSEAFILE_VOLUME=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  check "not KEY=value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the MariaDB image, not sudo"
  deployed
  local data mysql; data="$(data_dir)"; mysql="$(mysql_dir)"
  # Stand-in for container-owned files: read-only dirs the host user cannot empty.
  mkdir -p "$data/seafile-data/locked" "$mysql/locked"
  echo x > "$data/seafile-data/locked/f"; echo x > "$mysql/locked/f"
  chmod 500 "$data/seafile-data/locked" "$mysql/locked"
  run_teardown --purge "seafile"
  chmod -R u+rwX "$data" "$mysql" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the stack's MariaDB image" calls_have "entrypoint sh mariadb:10.11"
  check "never pulled for it"         calls_have "pull never"
  check "mounted the seafile data dir" calls_have "-v $data:/x"
  check "mounted the mysql data dir"  calls_have "-v $mysql:/x"
  check "no sudo"                     no_call "^sudo"
  check "seafile data gone"           [ ! -e "$data" ]
  check "mysql data gone"             [ ! -e "$mysql" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/seafile" ]
  teardown
  deployed
  data="$(data_dir)"
  mkdir -p "$data/seafile-data/locked"; echo x > "$data/seafile-data/locked/f"
  chmod 500 "$data/seafile-data/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "seafile"
  chmod -R u+rwX "$data" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $data"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  check "  marker kept"               [ -d "$HOME/services/seafile" ]
  teardown
}

# Data behind a folder this user cannot search (a root-owned 0700 parent,
# faked with chmod 000): `[ -e ]` cannot see it, which must not read as
# "already gone" while .env is deleted. The MariaDB image mounts that folder
# and deletes only the paths below it.
unhide() { chmod -R u+rwX "$HOME/services" 2>/dev/null; }
mounts_of() { grep -c -- "-v $1:/x" "$CALLS_LOG"; }

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder is deleted, not taken as gone"
  local st
  # Both data dirs under one unsearchable folder: two mounts of the same base.
  deployed
  st="$(cd "$HOME/services/seafile" && pwd -P)/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"; mv "$(mysql_dir)" "$st/mysql"
  sed -i.bak -e "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$st/data#" \
    -e "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=$st/mysql#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "seafile"
  unhide
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns it deletes both"       out_has "deletes $st/data, $st/mysql and"
  check "mounted the unsearchable folder once per dir" [ "$(mounts_of "$st")" -eq 2 ]
  check "used the stack's MariaDB image" calls_have "entrypoint sh mariadb:10.11"
  check "never mounted a missing folder" [ ! -f "$STATE_DIR/mounted_missing" ]
  check "no sudo"                     no_call "^sudo"
  check "says data deleted"           out_has "Deleted $st/data"
  check "says mysql deleted"          out_has "Deleted $st/mysql"
  check "data gone"                   [ ! -e "$st/data" ]
  check "mysql gone"                  [ ! -e "$st/mysql" ]
  check "emptied folder gone"         [ ! -e "$st" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/seafile" ]
  teardown
  # The other dir's path behind the hidden folder is already gone: the
  # first cleanup empties and removes the folder, the second is skipped
  # rather than mounting a folder that is no longer there.
  deployed
  st="$(cd "$HOME/services/seafile" && pwd -P)/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"; rm -rf "$(mysql_dir)"
  sed -i.bak -e "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$st/data#" \
    -e "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=$st/mysql#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "seafile"
  unhide
  check "one already gone: exits zero" [ "$CODE" -eq 0 ]
  check "  mounted once"              [ "$(mounts_of "$st")" -eq 1 ]
  check "  never mounted a missing folder" [ ! -f "$STATE_DIR/mounted_missing" ]
  check "  says it is already gone"   out_has "$st/mysql is already gone"
  check "  folder gone"               [ ! -e "$st" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  teardown
  # The hidden folder sits inside the other (searchable) data dir, which the
  # first cleanup clears; the hidden one then has nothing left to mount.
  deployed
  local data; data="$(cd "$(data_dir)" && pwd -P)"
  mkdir -p "$data/locked"
  mv "$(mysql_dir)" "$data/locked/mysql"
  sed -i.bak "s#^SEAFILE_MYSQL_VOLUME=.*#SEAFILE_MYSQL_VOLUME=$data/locked/mysql#" "$SVC/.env"
  chmod 000 "$data/locked"
  run_teardown --purge "seafile"
  unhide
  check "hidden inside the other dir: exits zero" [ "$CODE" -eq 0 ]
  check "  data dir cleared by the container" [ "$(mounts_of "$data")" -eq 1 ]
  check "  hidden folder never mounted once gone" [ "$(mounts_of "$data/locked")" -eq 0 ]
  check "  never mounted a missing folder" [ ! -f "$STATE_DIR/mounted_missing" ]
  check "  data gone"                 [ ! -e "$data" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  teardown
  # The cleanup container fails: non-zero, sudo named, data and .env kept.
  deployed
  st="$(cd "$HOME/services/seafile" && pwd -P)/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "seafile"
  unhide
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/data"
  check "  never says deleted"        out_lacks "Deleted"
  check "  data kept"                 [ -f "$st/data/seafile-data/storage/block" ]
  check "  mysql kept"                [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  st="$(cd "$HOME/services/seafile" && pwd -P)/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/data"
  sed -i.bak "s#^SEAFILE_VOLUME=.*#SEAFILE_VOLUME=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "seafile"
  unhide
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  link kept"                 [ -L "$st/data" ]
  check "  mysql kept"                [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # ~/services/seafile itself unsearchable: not strictly inside it, so no
  # mount; stop before anything changes and name the sudo command.
  deployed
  chmod 000 "$HOME/services/seafile"
  run_teardown --purge "seafile"
  unhide
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $HOME/services/seafile/data"
  check "  no cleanup container"      no_call "entrypoint sh"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  serve untouched"           no_call " off"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/seafile-data/storage/block" ]
  check "  mysql kept"                [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /drive proxy http://127.0.0.1:8081
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    out_lacks "already off"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8081 (left on, see above); 0 port(s) unpublished"
  teardown
}

# `down` fails when a container outside this project (a SeaDoc or
# notification-server add-on from its own compose file) still uses the
# fixed-name seafile-net network. That alone must not stop the teardown
# halfway; anything else still does, with data and .env untouched.
test_teardown_down_network_in_use() {
  echo "• teardown: a failed down because an add-on still uses seafile-net warns and goes on"
  deployed
  touch "$STATE_DIR/compose_down_fails"
  printf 'seadoc seafile-notification-server ' > "$STATE_DIR/network_users_seafile-net"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "checked this project's containers" calls_have "ps -aq --filter label=com.docker.compose.project=svc"
  check "names who keeps the network" out_has "Docker kept the seafile-net network: still used by seadoc seafile-notification-server (not"
  check "data and .env kept"          [ -f "$(data_dir)/seafile-data/storage/block" ] && [ -f "$SVC/.env" ]
  check "says it is done"             out_has "Done."
  run_teardown --purge "seafile"
  check "purge: exits zero"           [ "$CODE" -eq 0 ]
  check "  warns about the network"   out_has "Docker kept the seafile-net network"
  check "  data gone"                 [ ! -e "$HOME/services/seafile/data" ]
  check "  mysql gone"                [ ! -e "$HOME/services/seafile/mysql" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  teardown
  # This project's own containers are still there: a real failure.
  deployed
  touch "$STATE_DIR/compose_down_fails"
  printf 'seadoc ' > "$STATE_DIR/network_users_seafile-net"
  printf 'f00dfeed\n' > "$STATE_DIR/project_left"
  run_teardown --purge "seafile"
  check "own containers left: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "own containers are still there"
  check "  data kept"                 [ -f "$(data_dir)/seafile-data/storage/block" ]
  check "  mysql kept"                [ -f "$(mysql_dir)/seafile_db/repo.ibd" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  never says done"           out_lacks "Done."
  rm -f "$STATE_DIR/project_left"
  touch "$STATE_DIR/ps_label_fails"
  run_teardown --purge "seafile"
  check "cannot list what is left: exits non-zero" [ "$CODE" -ne 0 ]
  check "  data and .env kept"        [ -f "$(data_dir)/seafile-data/storage/block" ] && [ -f "$SVC/.env" ]
  rm -f "$STATE_DIR/ps_label_fails" "$STATE_DIR/network_users_seafile-net"
  run_teardown --purge "seafile"
  check "network already gone: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it was not the network" out_has "not because of the seafile-net network"
  check "  data and .env kept"        [ -f "$(data_dir)/seafile-data/storage/block" ] && [ -f "$SVC/.env" ]
  : > "$STATE_DIR/network_users_seafile-net"
  run_teardown --purge "seafile"
  check "network empty: exits non-zero" [ "$CODE" -ne 0 ]
  check "  data and .env kept"        [ -f "$(mysql_dir)/seafile_db/repo.ibd" ] && [ -f "$SVC/.env" ]
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_https_port
test_fresh_deploy
test_idempotent_rerun
test_port_override
test_operator_escalation
test_teardown_safe
test_teardown_port_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_refuses_odd_paths
test_teardown_purge_mysql_dir_checked_too
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_purge_never_its_own_checkout
test_teardown_env_lint
test_teardown_purge_container_owned
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports
test_teardown_down_network_in_use

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
