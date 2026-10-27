#!/usr/bin/env bash
#
# Tests for services/forgejo/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id. The docker stub
# fakes `forgejo admin user create` — including the "user already exists"
# failure — so the admin bootstrap is exercised for real, and the curl stub
# fakes /api/healthz and the locked /install wizard.

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
  SVC="$SANDBOX/repo/services/forgejo"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
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
out_lacks()  { ! grep -qi "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# The argv of every `forgejo admin user create` the script attempted.
admin_arg()   { grep -q -- "$1" "$STATE_DIR/admin_create_args"; }
admin_tries() { cat "$STATE_DIR/admin_create_count" 2>/dev/null || echo 0; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped — the file
# documents what it deliberately does NOT do ("upstream binds 0.0.0.0:3000"),
# so a naive grep would match the prose and not the config.
compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
no_wildcard_bind() { ! compose_has '0\.0\.0\.0'; }

# The data directory setup.sh chose, read back out of the .env it generated.
data_dir() { sed -n 's/^FORGEJO_DATA=//p' "$SVC/.env"; }

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
  export LOCAL_PORT=30o0
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, admin created, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env generated"                  [ -f "$SVC/.env" ]
  check ".env is mode 600"                [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has a hex admin password"   grep -qE '^FORGEJO_ADMIN_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env names the admin user"       grep -qE '^FORGEJO_ADMIN_USERNAME=.+$' "$SVC/.env"
  check ".env has a SECRET_KEY"           grep -qE '^FORGEJO_SECRET_KEY=.{16,}$' "$SVC/.env"
  check ".env records the local port"     grep -qx 'LOCAL_PORT=3000' "$SVC/.env"
  check "pinned to the v15 LTS line"      grep -qx 'FORGEJO_VERSION=15' "$SVC/.env"
  # ROOT_URL has to be the public tailnet URL: Forgejo builds every clone URL,
  # redirect and webhook payload from it, and a wrong value fails silently.
  check "ROOT_URL is the tailnet URL"     grep -q '^FORGEJO_ROOT_URL=https://test-host\.tailfake\.ts\.net:3000' "$SVC/.env"
  check "install wizard locked in config" compose_has 'INSTALL_LOCK: *"true"'
  check "open registration disabled"      compose_has 'DISABLE_REGISTRATION: *"true"'
  check "database is sqlite3"             compose_has 'DB_TYPE: *sqlite3'
  check "built-in SSH server off"         compose_has 'DISABLE_SSH'
  check "compose binds loopback only"     compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose binds no wildcard"       no_wildcard_bind
  check "data dir created"                [ -d "$(data_dir)" ]
  check "compose up invoked"              [ -f "$STATE_DIR/compose_up" ]
  check "waited on /api/healthz"          calls_have "127.0.0.1:3000/api/healthz"
  check "admin created via the CLI"       calls_have "exec -u git forgejo forgejo admin user create"
  check "  created as an admin"           admin_arg "--admin"
  # Without this flag Forgejo marks the account must-change-password, and the
  # generated password in .env does not work on first login. Load-bearing.
  check "  --must-change-password=false"  admin_arg "--must-change-password=false"
  check "  passed the .env password"      admin_arg "$(sed -n 's/^FORGEJO_ADMIN_PASSWORD=//p' "$SVC/.env")"
  check "  attempted exactly once"        [ "$(admin_tries)" -eq 1 ]
  check "admin marker written"            [ -f "$HOME/services/forgejo/.admin-created" ]
  check "served on tailscale :3000"       calls_have "tailscale serve --bg --https=3000 http://127.0.0.1:3000"
  check "no sudo needed (operator set)"   no_call "^sudo "
  # The end-to-end check is an authenticated call, not just a health ping —
  # it is what proves the generated password actually logs in.
  check "verified the admin login"        calls_have "/api/v1/user"
  check "  confirmed admin rights"        out_has "account is an admin"
  check "  confirmed ROOT_URL"            out_has "ROOT_URL is the tailnet address"
  check "prints final URL"                out_has "https://test-host.tailfake.ts.net:3000"
  check "warns there is no backup here"   out_has "backup"
  teardown
}

test_password_drift() {
  echo "• password changed in the UI: the deploy fails loudly instead of lying"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/login_rejected"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the mismatch"      out_has "does not match the server"
  check "gives the reset command" out_has "admin user change-password"
  check "published before dying"  calls_have "tailscale serve --bg --https=3000"
  teardown
}

test_wrong_root_url() {
  echo "• ROOT_URL points somewhere else: warned, not silently accepted"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/wrong_root_url"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "warns about ROOT_URL"  out_has "check FORGEJO_ROOT_URL"
  check "still prints the URL"  out_has "https://test-host.tailfake.ts.net:3000"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3010 HTTPS_PORT=3010
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=3010' "$SVC/.env"
  check "ROOT_URL uses the new port" grep -q '^FORGEJO_ROOT_URL=https://test-host\.tailfake\.ts\.net:3010/$' "$SVC/.env"
  check "health-checked :3010"       calls_have "127.0.0.1:3010/api/healthz"
  check "served :3010 -> :3010"      calls_have "tailscale serve --bg --https=3010 http://127.0.0.1:3010"
  check "prints the :3010 URL"       out_has "https://test-host.tailfake.ts.net:3010"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under its data.
  export LOCAL_PORT=3011 HTTPS_PORT=3010
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=3011 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=3010' "$SVC/.env"
  check "re-run: still serves :3010" calls_have "tailscale serve --bg --https=3010 http://127.0.0.1:3010"
  check "re-run: never touched 3011" no_call "127.0.0.1:3011"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (3000) next to a LOCAL_PORT
  # override would silently publish :3000 -> 127.0.0.1:3020, i.e. the wrong port.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3020
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=3020"   grep -qx 'LOCAL_PORT=3020' "$SVC/.env"
  check "served :3020 -> 127.0.0.1:3020" calls_have "tailscale serve --bg --https=3020 http://127.0.0.1:3020"
  check "  and never :3000"              no_call "tailscale serve --bg --https=3000"
  check "prints the :3020 URL"           out_has "https://test-host.tailfake.ts.net:3020"
  # Re-run with no override at all: .env says 3020, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 3000.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :3020 -> 127.0.0.1:3020" calls_have "tailscale serve --bg --https=3020 http://127.0.0.1:3020"
  check "  and never :3000"                   no_call "tailscale serve --bg --https=3000"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3020 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:3020" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:3020"
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
  check "polled healthz repeatedly"  [ "$(grep -c '/api/healthz' "$CALLS_LOG")" -gt 3 ]
  check "still created the admin"    calls_have "admin user create"
  check "still published"            calls_have "tailscale serve --bg --https=3000"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, admin not re-created"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(sed -n 's/^FORGEJO_ADMIN_PASSWORD=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "password unchanged"          [ "$(sed -n 's/^FORGEJO_ADMIN_PASSWORD=//p' "$SVC/.env")" = "$pw" ]
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "admin creation NOT retried"  no_call "admin user create"
  check "  still only one attempt"    [ "$(admin_tries)" -eq 1 ]
  check "says the admin is there"     out_has "already provisioned"
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=3000 http://127.0.0.1:3000"
  teardown
}

test_root_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                    # first deploy on :3000
  old="$(grep '^FORGEJO_ROOT_URL=' "$SVC/.env")"
  export HTTPS_PORT=3001                        # published somewhere else now
  run_deploy
  check "warns about the drift"     out_has "FORGEJO_ROOT_URL in .env is"
  check "spells out the fix"        out_has "FORGEJO_ROOT_URL=https://test-host.tailfake.ts.net:3001/"
  check ".env left alone (user's)"  [ "$(grep '^FORGEJO_ROOT_URL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_admin_already_exists() {
  echo "• admin exists but the marker is gone: 'already exists' is not an error"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/user_exists"   # e.g. a run that died
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "attempted the create once"  [ "$(admin_tries)" -eq 1 ]
  check "treated as normal"          out_has "already exists"
  check "did not die on the CLI"     out_lacks "Could not create the admin"
  check "marker written anyway"      [ -f "$HOME/services/forgejo/.admin-created" ]
  check "still published"            calls_have "tailscale serve --bg --https=3000"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=3000 http://127.0.0.1:3000"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the
  # second lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=3000 http://127.0.0.1:3000"
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
#
# Note this service publishes HTTPS on the same number as the local port
# (3000 -> 3000), so tailscaled legitimately listens on the tailnet IP for
# that port. The other services here differ (e.g. seafile 8443 -> 8081) and never
# hit that overlap, which is why their simpler "anything not 127.0.0.1"
# check works for them and would false-positive here.
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

  # read loop, not `for addr in $addrs`: that relies on word-splitting,
  # which zsh does not do for unquoted expansions.
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"                            # strip :port
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6] — tr, not a
                                                 # glob: '[' is an invalid
                                                 # pattern under zsh
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
  # Without the docker group every `docker inspect` fails and the container
  # checks report "not running" for a perfectly healthy stack. Say so, rather
  # than letting red lines imply an outage. A shell started before the user
  # was added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url user pass
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  user="$(sed -n 's/^FORGEJO_ADMIN_USERNAME=//p' "$SERVICE_DIR/.env")"
  pass="$(sed -n 's/^FORGEJO_ADMIN_PASSWORD=//p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "forgejo container running"   sh -c "docker inspect -f '{{.State.Status}}' forgejo | grep -qx running"
  live_check "local healthz responds"      sh -c "curl -fsS 'http://127.0.0.1:$port/api/healthz' | grep -q pass"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"      curl -fsS -o /dev/null --max-time 30 "$url:$https_port/api/healthz"

  # A deploy that still serves the install wizard is a failed deploy that
  # looks successful: anyone on the tailnet could re-run it and take the
  # instance over. INSTALL_LOCK must make /install a 404.
  live_check "install wizard is locked (404)" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 '$url:$https_port/install')\" = 404 ]"

  # The password in .env has to be the one that actually works — this is the
  # check that catches a missing --must-change-password=false.
  live_check "admin credentials in .env authenticate" \
    sh -c "curl -fsS --max-time 30 -u '$user:$pass' '$url:$https_port/api/v1/user' | grep -q '\"login\":\"$user\"'"

  live_check "repo data dir exists"        sh -c "test -d \"\$(sed -n 's/^FORGEJO_DATA=//p' '$SERVICE_DIR/.env')\""
  live_check "running the v15 LTS line"    sh -c "curl -fsS --max-time 30 'http://127.0.0.1:$port/api/v1/version' | grep -q '\"version\":\"15'"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

MARKER_REL="services/forgejo/.admin-created"

# A deployed sandbox: setup.sh has run (so .env, the data dir and the hidden
# admin marker exist), a repository sits in the data dir, Serve maps this
# port to this service, and neighbours sit on other ports (one a lookalike).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/git/repositories/admin/proj.git"
  echo 'ref: refs/heads/main' > "$(data_dir)/git/repositories/admin/proj.git/HEAD"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:3000 (tailnet only)
|-- / proxy http://127.0.0.1:3000

https://test-host.tailfake.ts.net:13000 (tailnet only)
|-- / proxy http://127.0.0.1:13000
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

repo_head() { echo "$(data_dir)/git/repositories/admin/proj.git/HEAD"; }

# Uncomment the SSH port line, as step 1 of the recipe in docker-compose.yml.
enable_ssh_port() {
  sed -i.bak "s|^      # - '127.0.0.1:\${FORGEJO_SSH_HOST_PORT:-2222}:22'|      - '127.0.0.1:\${FORGEJO_SSH_HOST_PORT:-2222}:22'|" "$SVC/docker-compose.yml"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps repos, .env and the admin marker, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :3000"         calls_have "tailscale serve --https=3000 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :13000 untouched"  no_call "https=13000"
  check "never serve reset"           no_call "serve reset"
  check "no TCP serve touched"        no_call "serve --tcp"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  in this project dir"       calls_have "compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no container cleanup run"    no_call "entrypoint sh"
  check "repository kept"             [ -f "$(repo_head)" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "admin marker kept"           [ -f "$HOME/$MARKER_REL" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  # And it does come back without re-creating the admin account.
  rm -f "$STATE_DIR/compose_up"
  run_deploy
  check "setup.sh restores it"        [ "$CODE" -eq 0 ]
  check "  admin not re-created"      [ "$(admin_tries)" -eq 1 ]
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
  printf 'https://test-host.tailfake.ts.net:3000 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: repo kept"        [ -f "$(repo_head)" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then repos, marker and .env go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "forge"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: repo kept"       [ -f "$dir/git/repositories/admin/proj.git/HEAD" ]
  check "wrong name: marker kept"     [ -f "$HOME/$MARKER_REL" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  # Repos have no other copy: the prompt has to say so and give the dump
  # command before anyone types the name.
  check "warns every repository goes" out_has "EVERY repository"
  check "  and issues and wikis"      out_has "issues, pull requests, wikis"
  check "suggests forgejo dump"       out_has "docker exec -u git -w /tmp forgejo forgejo dump -c /data/gitea/conf/app.ini --file /tmp/forgejo-dump.zip"
  check "  and how to copy it out"    out_has "docker cp forgejo:/tmp/forgejo-dump.zip"
  run_teardown --purge "forgejo"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$dir" ]
  check "hidden admin marker gone"    [ ! -e "$HOME/$MARKER_REL" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir \$HOME/services/forgejo removed"  [ ! -e "$HOME/services/forgejo" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "serve off for :3000"         calls_have "tailscale serve --https=3000 off"
  check "down only, never down -v"    no_call "down -v"
  check "no sudo"                     no_call "^sudo"
  # A fresh deploy after the purge provisions the admin account again
  # (the fake DB is empty again too).
  rm -f "$STATE_DIR/user_exists"
  run_deploy
  check "fresh setup.sh exits zero"   [ "$CODE" -eq 0 ]
  check "  admin created again"       [ "$(admin_tries)" -eq 2 ]
  check "  marker re-written"         [ -f "$HOME/$MARKER_REL" ]
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the pinned image, not sudo"
  deployed
  local dir; dir="$(data_dir)"
  # Stand-in for a root-owned file: a read-only dir the host user cannot empty.
  mkdir -p "$dir/ssh/locked"; echo x > "$dir/ssh/locked/ssh_host_ed25519_key"
  chmod 500 "$dir/ssh/locked"
  run_teardown --purge "forgejo"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image"       calls_have "codeberg.org/forgejo/forgejo:15"
  check "never pulled for it"         calls_have "pull never"
  check "mounted the data dir"        calls_have "-v $dir:/x"
  check "no sudo"                     no_call "^sudo"
  check "data dir gone"               [ ! -e "$dir" ]
  check "marker gone"                 [ ! -e "$HOME/$MARKER_REL" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(data_dir)"
  mkdir -p "$dir/ssh/locked"; echo x > "$dir/ssh/locked/f"
  chmod 500 "$dir/ssh/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "forgejo"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  check "  marker kept for the retry" [ -f "$HOME/$MARKER_REL" ]
  teardown
  deployed
  sed -i.bak 's/^FORGEJO_VERSION=.*/FORGEJO_VERSION=15;x/' "$SVC/.env"
  run_teardown --purge "forgejo"
  check "odd image tag: exits non-zero" [ "$CODE" -ne 0 ]
  check "  repo kept"                 [ -f "$(repo_head)" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_marker_guard() {
  echo "• teardown --purge: the admin marker goes only as a plain file in ~/services/forgejo"
  deployed
  echo keep > "$HOME/elsewhere"
  rm -f "$HOME/$MARKER_REL"
  ln -s "$HOME/elsewhere" "$HOME/$MARKER_REL"
  run_teardown --purge "forgejo"
  check "symlinked marker: exits non-zero" [ "$CODE" -ne 0 ]
  check "  its target kept"           [ -f "$HOME/elsewhere" ]
  check "  repo kept"                 [ -f "$(repo_head)" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  rm -f "$HOME/$MARKER_REL"
  run_teardown --purge "forgejo"
  check "no marker: exits zero"       [ "$CODE" -eq 0 ]
  check "  data dir gone"             [ ! -e "$HOME/services/forgejo/data" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "marker kept"                 [ -f "$HOME/$MARKER_REL" ]
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./forgejo" "$HOME/services/forgejo/.."; do
    sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "forgejo"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "repository never touched"    [ -f "$HOME/services/forgejo/data/git/repositories/admin/proj.git/HEAD" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3010 (tailnet only)
|-- / proxy http://127.0.0.1:3000

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:3000

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /git proxy http://127.0.0.1:3000
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":3010 off"                   calls_have "serve --https=3010 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_ssh_forward() {
  echo "• teardown: the SSH TCP forward goes too, but only when compose publishes SSH"
  deployed
  enable_ssh_port
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3000 (tailnet only)
|-- / proxy http://127.0.0.1:3000
|-- tcp://test-host.tailfake.ts.net:2222 (TLS over TCP, tailnet only)
|-- tcp://100.100.100.100:2222
|--> tcp://127.0.0.1:2222

|-- tcp://test-host.tailfake.ts.net:2022 (TLS over TCP, tailnet only)
|-- tcp://100.100.100.100:2022
|--> tcp://127.0.0.1:22022

|-- tcp://test-host.tailfake.ts.net:22 (TLS over TCP, tailnet only)
|--> tcp://127.0.0.1:2222
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "HTTPS :3000 off (TCP lines are not its handlers)" calls_have "serve --https=3000 off"
  check "TCP :2222 -> ssh off"        calls_have "serve --tcp=2222 off"
  check "TCP :22 -> ssh off"          calls_have "serve --tcp=22 off"
  check "lookalike TCP :2022 kept"    no_call "tcp=2022"
  check "names the ssh port"          out_has "ssh :2222"
  teardown
  # A moved SSH port is read from .env, as compose interpolates it.
  deployed
  enable_ssh_port
  sed -i.bak 's/^FORGEJO_SSH_HOST_PORT=.*/FORGEJO_SSH_HOST_PORT=2223/' "$SVC/.env"
  printf '|-- tcp://test-host.tailfake.ts.net:2223 (TLS over TCP, tailnet only)\n|--> tcp://127.0.0.1:2223\n\n|-- tcp://test-host.tailfake.ts.net:2222 (TLS over TCP, tailnet only)\n|--> tcp://127.0.0.1:2222\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "moved port: exits zero"      [ "$CODE" -eq 0 ]
  check "  :2223 off"                 calls_have "serve --tcp=2223 off"
  check "  :2222 (not ours now) kept" no_call "tcp=2222"
  teardown
  # SSH commented out (the default): 127.0.0.1:2222 is not this container's.
  deployed
  printf '|-- tcp://test-host.tailfake.ts.net:2222 (TLS over TCP, tailnet only)\n|--> tcp://127.0.0.1:2222\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "ssh off in compose: exits zero" [ "$CODE" -eq 0 ]
  check "  TCP :2222 left alone"      no_call "serve --tcp"
  teardown
}

test_teardown_units_left_alone() {
  echo "• teardown: units that mention forgejo but setup.sh never wrote are named, not touched"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/bin/sh -c "tar czf /backup/forgejo.tgz ~/services/forgejo/data"\n' \
    > "$HOME/.config/systemd/user/forgejo-backup.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/other.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit"              out_has "forgejo-backup.service mentions forgejo"
  check "  not the unrelated one"     out_lacks "other.service"
  check "  unit file kept"            [ -f "$HOME/.config/systemd/user/forgejo-backup.service" ]
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
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='3000'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":3000 off"                   calls_have "serve --https=3000 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="3000"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check "  :3000 off"                 calls_have "serve --https=3000 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=3000 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "  :3000 off"                 calls_have "serve --https=3000 off"
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "forgejo"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  local dir="$HOME/services/forgejo/data"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$dir///#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  data dir gone"             [ ! -e "$dir" ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine, marker and ~/services/forgejo still go"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "forgejo"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "hidden admin marker gone"    [ ! -e "$HOME/$MARKER_REL" ]
  check "state dir \$HOME/services/forgejo removed"  [ ! -e "$HOME/services/forgejo" ]
  teardown
}

# FORGEJO_DATA under a folder this user cannot search (a root-owned 0700
# storage/, faked with chmod 000): `[ -e ]` cannot see the data, which must
# not read as "already gone" while .env and the marker are deleted.
hide_data_under_storage() {
  local st="$HOME/services/forgejo/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
}
unhide_storage() { chmod -R u+rwX "$HOME/services/forgejo" 2>/dev/null; }

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder is deleted, not taken as gone"
  local st
  deployed
  st="$HOME/services/forgejo/storage"
  hide_data_under_storage
  run_teardown --purge "forgejo"
  unhide_storage
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "mounted the unsearchable folder" calls_have "-v $st:/x"
  check "used the pinned image"       calls_have "codeberg.org/forgejo/forgejo:15"
  check "no sudo"                     no_call "^sudo"
  check "data gone"                   [ ! -e "$st/data" ]
  check "emptied folder gone"         [ ! -e "$st" ]
  check "marker gone"                 [ ! -e "$HOME/$MARKER_REL" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir removed"           [ ! -e "$HOME/services/forgejo" ]
  teardown
  deployed
  st="$HOME/services/forgejo/storage"
  hide_data_under_storage
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "forgejo"
  unhide_storage
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/data"
  check "  never says done"           out_lacks "Deleted"
  check "  repo kept"                 [ -f "$st/data/git/repositories/admin/proj.git/HEAD" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  check "  marker kept for the retry" [ -f "$HOME/$MARKER_REL" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  st="$HOME/services/forgejo/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/data"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "forgejo"
  unhide_storage
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  marker kept"               [ -f "$HOME/$MARKER_REL" ]
  teardown
  # ~/services/forgejo itself unsearchable: the marker is out of reach too.
  deployed
  chmod 000 "$HOME/services/forgejo"
  run_teardown --purge "forgejo"
  unhide_storage
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  marker kept"               [ -f "$HOME/$MARKER_REL" ]
  check "  repo kept"                 [ -f "$(repo_head)" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/forgejo itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  marker kept"               [ -f "$HOME/$MARKER_REL" ]
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/forgejo/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/forgejo/a:b"
  run_teardown --purge "forgejo"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
  # FORGEJO_DATA may be the state dir itself; the marker inside goes with it.
  deployed
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/forgejo#" "$SVC/.env"
  run_teardown --purge "forgejo"
  check "the state dir itself: exits zero" [ "$CODE" -eq 0 ]
  check "  ~/services/forgejo gone"   [ ! -e "$HOME/services/forgejo" ]
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
  mkdir -p "$HOME/forgejo/data"; echo x > "$HOME/forgejo/data/keep"; echo admin > "$HOME/forgejo/.admin-created"
  run_teardown --purge "forgejo"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"   [ -f "$HOME/forgejo/data/keep" ]
  check "  marker look-alike kept"    [ -f "$HOME/forgejo/.admin-created" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'FORGEJO_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "FORGEJO_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nFORGEJO_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
    run_teardown --purge "forgejo"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    check "  repo kept"                 [ -f "$(repo_head)" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose call"           no_call "compose --project-directory"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/forgejo survives"
  deployed
  local repo="$HOME/services/forgejo/setup-server/services/forgejo"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  copy_lib "${repo%/services/*}"
  echo secret > "$HOME/services/forgejo/setup-server/other.env"
  # Pointed at the state dir that holds the checkout: refused outright.
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/forgejo#" "$repo/.env"
  OUT="$(printf '%s\n' "forgejo" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "data dir holding it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$HOME/services/forgejo/setup-server/other.env" ]
  # The default data dir beside it: data and marker go, the checkout stays.
  sed -i.bak "s#^FORGEJO_DATA=.*#FORGEJO_DATA=$HOME/services/forgejo/data#" "$repo/.env"
  OUT="$(printf '%s\n' "forgejo" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "default data dir: exits zero" [ "$CODE" -eq 0 ]
  check "  data gone"                 [ ! -e "$HOME/services/forgejo/data" ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$HOME/services/forgejo/setup-server/other.env" ]
  check "  state dir kept (not empty)" [ -d "$HOME/services/forgejo" ]
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/forgejo/setup.sh or services/forgejo/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_password_drift
test_wrong_root_url
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_root_url_drift
test_admin_already_exists
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_container_owned
test_teardown_purge_marker_guard
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_ssh_forward
test_teardown_units_left_alone
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_purge_unsearchable_parent
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
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
