#!/usr/bin/env bash
#
# Tests for services/n8n/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment

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

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/n8n"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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

# A PATH holding nothing but the stubs and the real utilities setup.sh
# shells out to — with named commands left out. That is how "this box has
# no openssl" is made true: with the real one still reachable, the
# preflight check would never fire. Same shape as syncthing's suite.
minimal_path() {  # minimal_path <dir> [command-to-omit ...]
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p s base omit skip
  for c in bash sh env uname mktemp rm cat head tail cut sed awk grep tr \
           chmod mkdir rmdir df cp mv ln ls stat od readlink dirname \
           basename seq touch sort wc sleep hostname openssl python3; do
    skip=0
    for omit in "$@"; do [ "$c" = "$omit" ] && skip=1; done
    p="$(command -v "$c" 2>/dev/null)" && [ "$skip" = "0" ] && ln -sf "$p" "$dir/$c"
  done
  for s in "$STUBS"/*; do
    base="$(basename "$s")"
    skip=0
    for omit in "$@"; do [ "$base" = "$omit" ] && skip=1; done
    [ "$skip" = "1" ] || ln -sf "$s" "$dir/$base"
  done
}

run_deploy_path() {  # run_deploy_path <path> [stdin]
  OUT="$(printf '%s' "${2:-}" | PATH="$1" bash "$SVC/setup.sh" 2>&1)"
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
calls_have_f() { grep -qF -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

data_dir() { sed -n 's/^N8N_VOLUME=//p' "$SVC/.env"; }

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
  export OWNER_EMAIL=admin@example.com OWNER_PASSWORD='Testpass123'
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check ".env has encryption key"      sh -c "grep -E '^N8N_ENCRYPTION_KEY=[0-9a-f]{64}$' '$SVC/.env' >/dev/null"
  check ".env is mode 600"             sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has owner creds"         env_has "OWNER_EMAIL=admin@example.com"
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
N8N_VOLUME=$HOME/services/n8n/data
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

test_env_wins_on_rerun() {
  echo "• re-run with a port override: .env wins, the override is warned"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  export LOCAL_PORT=5679
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "warns LOCAL_PORT ignored"   out_has "LOCAL_PORT=5679 ignored"
  check "serves .env's port"         calls_have "tailscale serve --bg --https=5678 http://127.0.0.1:5678"
  check "never the override port"    no_call "https=5679"
  check ".env keeps its port"        env_has "LOCAL_PORT=5678"
  check "PUBLIC_URL still :5678"     env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:5678/"
  check "no PUBLIC_URL drift warn"   bash -c '! grep -q "PUBLIC_URL in .env" <<<"$1"' _ "$OUT"
  teardown
}

test_env_explicit_https_drift() {
  echo "• re-run with an explicit HTTPS_PORT: honoured, but the stale PUBLIC_URL is warned"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  export HTTPS_PORT=9999
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "served on :9999 -> 5678"     calls_have "tailscale serve --bg --https=9999 http://127.0.0.1:5678"
  check "warns PUBLIC_URL is stale"   out_has "PUBLIC_URL in .env is https://test-host.tailfake.ts.net:5678/"
  check "gives the fix"               out_has "set PUBLIC_URL=https://test-host.tailfake.ts.net:9999/"
  teardown
}

test_preflight_bad_local_port() {
  echo "• preflight rejects a non-numeric LOCAL_PORT — in env and in .env"
  setup
  export LOCAL_PORT=abc
  run_deploy
  check "override: exits non-zero"   [ "$CODE" -ne 0 ]
  check "override: says numeric"     out_has "LOCAL_PORT must be numeric"
  unset LOCAL_PORT
  teardown
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
N8N_VOLUME=$HOME/services/n8n/data
LOCAL_PORT=abc
PUBLIC_HOST=test-host.tailfake.ts.net
PUBLIC_URL=https://test-host.tailfake.ts.net:5678/
N8N_ENCRYPTION_KEY=k
OWNER_EMAIL=x@y.z
OWNER_PASSWORD=Custom123
EOF
  run_deploy
  check ".env: exits non-zero"       [ "$CODE" -ne 0 ]
  check ".env: says numeric"         out_has "LOCAL_PORT must be numeric"
  check "started no container"       [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_no_openssl() {
  echo "• preflight fails early without openssl (it generates the secrets)"
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/nossl" openssl
  run_deploy_path "$SANDBOX/nossl"
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names openssl"            out_has "openssl is required"
  check "names the install fix"    out_has "apt-get install"
  check "wrote no .env"            [ ! -f "$SVC/.env" ]
  teardown
}

test_env_volume_used() {
  echo "• the data dir created is .env's N8N_VOLUME, not the hardcoded default"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
N8N_VOLUME=$HOME/services/n8n/custom-data
LOCAL_PORT=5678
PUBLIC_HOST=test-host.tailfake.ts.net
PUBLIC_URL=https://test-host.tailfake.ts.net:5678/
N8N_ENCRYPTION_KEY=k
OWNER_EMAIL=x@y.z
OWNER_PASSWORD=Custom123
EOF
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "custom data dir created"  [ -d "$HOME/services/n8n/custom-data" ]
  check "default dir not created"  [ ! -d "$HOME/services/n8n/data" ]
  teardown
}

test_seed_json_escapes_password() {
  echo "• owner seed: quotes and backslashes in .env values are JSON-escaped"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
N8N_VOLUME=$HOME/services/n8n/data
LOCAL_PORT=5678
PUBLIC_HOST=test-host.tailfake.ts.net
PUBLIC_URL=https://test-host.tailfake.ts.net:5678/
N8N_ENCRYPTION_KEY=k
OWNER_EMAIL=x@y.z
OWNER_PASSWORD='P"ss\Word'
EOF
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "seed body is escaped"     calls_have_f 'P\"ss\\Word'
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
  mkdir -p "$(data_dir)/nodes"
  echo keep > "$(data_dir)/config"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:5678 (tailnet only)
|-- / proxy http://127.0.0.1:5678

https://test-host.tailfake.ts.net:15678 (tailnet only)
|-- / proxy http://127.0.0.1:15678
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :5678"         calls_have "tailscale serve --https=5678 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :15678 untouched"  no_call "https=15678"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/config" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "encryption key kept"         env_has "^N8N_ENCRYPTION_KEY="
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_custom_https_port() {
  echo "• teardown: HTTPS port differs from the local port"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:5678\n' \
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
  printf 'https://test-host.tailfake.ts.net:5678 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  run_teardown --purge "n8"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/config" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "n8n"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns credentials are lost"  out_has "unrecoverable"
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env (with key) gone"        [ ! -f "$SVC/.env" ]
  check "serve off for :5678"         calls_have "tailscale serve --https=5678 off"
  check "services dir itself kept"   [ -d "$HOME/services" ]
  check "empty marker dir removed"    [ ! -e "$(dirname "$dir")" ]
  teardown
  deployed
  dir="$(data_dir)"
  echo mine > "$(dirname "$dir")/notes.txt"
  run_teardown --purge "n8n"
  check "non-empty marker dir kept"   [ -f "$(dirname "$dir")/notes.txt" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$HOME#" "$SVC/.env"
  run_teardown --purge "n8n"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "n8n"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "n8n"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:5678

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:5678

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /n8n proxy http://127.0.0.1:5678
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:5678 (left on, see above); 2 port(s) unpublished"
  teardown
}

# A data dir behind a folder this user cannot search (a root-owned 0700
# parent, faked with chmod 000): `[ -e ]` cannot see it, which must not read
# as "already gone" while .env is deleted. It must stop before anything
# changes (no `compose down`, no Serve change) and name the sudo command.
test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder stops before anything changes"
  deployed
  local st="$HOME/services/n8n/storage"
  mkdir -p "$st/data"
  echo keep > "$st/data/marker"
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "n8n"
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
  run_teardown --purge "n8n"
  chmod 755 "$HOME/services"
  check "services dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/config" ]
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
|-- /n8n proxy http://127.0.0.1:5678
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    bash -c '! grep -q "already off" <<<"$1"' _ "$OUT"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:5678 (left on, see above); 0 port(s) unpublished"
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
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='5678'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":5678 off"                   calls_have "serve --https=5678 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="5678"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=5678 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "n8n"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^N8N_VOLUME=.*#N8N_VOLUME=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "n8n"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "n8n"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "empty marker dir still removed" [ ! -e "$HOME/services/n8n" ]
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_fresh_deploy
test_idempotent_rerun
test_port_override
test_env_wins_on_rerun
test_env_explicit_https_drift
test_preflight_bad_local_port
test_preflight_no_openssl
test_env_volume_used
test_seed_json_escapes_password
test_operator_escalation
test_teardown_safe
test_teardown_custom_https_port
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
