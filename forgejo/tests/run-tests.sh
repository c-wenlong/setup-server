#!/usr/bin/env bash
#
# Tests for forgejo/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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
# that port. The other services here differ (e.g. 10000 -> 3001) and never
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

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "forgejo/setup.sh or forgejo/docker-compose.yml is missing — nothing to test."
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
