#!/usr/bin/env bash
#
# Tests for services/monitoring/setup.sh (Uptime Kuma + ntfy).
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
  SVC="$SANDBOX/repo/services/monitoring"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" \
     "$SERVICE_DIR/docker-compose.yml" "$SERVICE_DIR/seed_kuma.py" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID KUMA_PORT NTFY_PORT KUMA_HTTPS_PORT NTFY_HTTPS_PORT \
        NTFY_TOPIC STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# $1 = stdin (e.g. the --purge confirmation), $2 = flags (--purge).
run_teardown() {
  OUT="$(printf '%s\n' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${2:+"$2"} 2>&1)"
  CODE=$?
}

# A .env as a pre-existing deploy would have written it. $1 = port pair
# ("3002 3003" default).
write_env() {
  set -- ${1:-3002 3003}
  cat > "$SVC/.env" <<EOF
KUMA_VOLUME=$HOME/services/monitoring/kuma
NTFY_VOLUME=$HOME/services/monitoring/ntfy
KUMA_PORT=$1
NTFY_PORT=$2
KUMA_HTTPS_PORT=$1
NTFY_HTTPS_PORT=$2
NTFY_BASE_URL=https://test-host.tailfake.ts.net:$2
NTFY_TOPIC=alerts
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=my-custom-secret
EOF
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
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

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
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has admin password"     sh -c "grep -E '^KUMA_ADMIN_PASSWORD=.+' '$SVC/.env' >/dev/null"
  check ".env is mode 600"            sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check ".env has ntfy base url"      env_has "NTFY_BASE_URL=https://test-host.tailfake.ts.net:3003"
  check ".env pins the ntfy image"    env_has "NTFY_IMAGE=binwiederhier/ntfy:v2.14.0"
  check ".env records https ports"    env_has "KUMA_HTTPS_PORT=3002"
  check ".env has phone creds"        sh -c "grep -E '^NTFY_PHONE_USER=phone$' '$SVC/.env' && grep -E '^NTFY_PHONE_PASS=[0-9a-f]{32}$' '$SVC/.env'"
  check ".env has kuma creds"         env_has "NTFY_KUMA_USER=kuma"
  check ".env has control creds"      env_has "NTFY_CONTROL_USER=control"
  check ".env records control topic"  env_has "CONTROL_TOPIC=control"
  check "compose denies anonymous"    sh -c "grep -q 'NTFY_AUTH_DEFAULT_ACCESS=deny-all' '$SVC/docker-compose.yml'"
  check "compose sets auth file"      sh -c "grep -q 'NTFY_AUTH_FILE=/var/lib/ntfy/auth.db' '$SVC/docker-compose.yml'"
  check "compose mounts auth volume"  sh -c "grep -q 'ntfy-auth:/var/lib/ntfy' '$SVC/docker-compose.yml'"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  check "phone user created"          calls_have "ntfy user add phone"
  check "kuma user created"           calls_have "ntfy user add kuma"
  check "control user created"        calls_have "ntfy user add control"
  check "phone reads alerts"          calls_have "ntfy access phone alerts read-only"
  check "phone drives control"        calls_have "ntfy access phone control read-write"
  check "kuma writes alerts"          calls_have "ntfy access kuma alerts write-only"
  check "control reads commands"      calls_have "ntfy access control control read-write"
  check "control writes replies"      calls_have "ntfy access control alerts write-only"
  check "all three users reported"    out_has "ntfy users created: phone kuma control"
  check "seed attempted via uv"       calls_have "uv run --with uptime-kuma-api"
  check "kuma served on :3002"        calls_have "tailscale serve --bg --https=3002 http://127.0.0.1:3002"
  check "ntfy served on :3003"        calls_have "tailscale serve --bg --https=3003 http://127.0.0.1:3003"
  check "prints dashboard URL"        out_has "https://test-host.tailfake.ts.net:3002"
  check "prints phone setup hint"     out_has "install the ntfy app"
  check "hint includes credentials"   out_has "NTFY_PHONE_USER / NTFY_PHONE_PASS"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env (credentials) preserved, auth db not re-created, no sudo"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
KUMA_VOLUME=/tmp/k
NTFY_VOLUME=/tmp/n
KUMA_PORT=3002
NTFY_PORT=3003
NTFY_BASE_URL=https://x:3003
NTFY_TOPIC=alerts
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=my-custom-secret
EOF
  # a pre-auth .env: the migration appends the account block once
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-secret"
  check "migration added creds"       env_has "NTFY_CONTROL_USER=control"
  check "migration added phone creds" env_has "NTFY_PHONE_USER=phone"
  check "migration added topic"       env_has "CONTROL_TOPIC=control"
  check "users created"               calls_have "ntfy user add"
  check "never invoked sudo"          no_call "^sudo "

  # second run: creds and users both exist — nothing is regenerated or
  # re-added, but passwords are re-synced from .env and the grants still
  # run (both are upserts and repair drift)
  pass="$(sed -n 's/^NTFY_CONTROL_PASS=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "creds not regenerated"    [ "$(sed -n 's/^NTFY_CONTROL_PASS=//p' "$SVC/.env")" = "$pass" ]
  check "no user add on re-run"    no_call "ntfy user add"
  check "users + ACLs verified"    out_has "ntfy users + ACLs verified"
  check "passwords re-synced"      calls_have "ntfy user change-pass control"
  check "three change-pass calls"  sh -c "[ \$(grep -c 'user change-pass' '$CALLS_LOG') -eq 3 ]"
  check "grants re-applied"        calls_have "ntfy access phone alerts read-only"
  check "all five grants run"      sh -c "[ \$(grep -c 'ntfy access' '$CALLS_LOG') -eq 5 ]"
  teardown
}

# The auth volume outliving .env is the documented-reset trap: accounts
# exist with passwords nothing knows, and user-add skips them. change-pass
# puts the .env credentials back so the deploy self-heals.
test_existing_users_resynced() {
  echo "• auth db outlived .env: existing users get .env passwords re-synced"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
KUMA_VOLUME=/tmp/k
NTFY_VOLUME=/tmp/n
KUMA_PORT=3002
NTFY_PORT=3003
NTFY_BASE_URL=https://x:3003
NTFY_TOPIC=alerts
CONTROL_TOPIC=control
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=pw
NTFY_PHONE_USER=phone
NTFY_PHONE_PASS=phonepass
NTFY_KUMA_USER=kuma
NTFY_KUMA_PASS=kumapass
NTFY_CONTROL_USER=control
NTFY_CONTROL_PASS=controlpass
EOF
  printf 'phone\nkuma\ncontrol\n' > "$STATE_DIR/ntfy_users"
  run_deploy
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "no users re-added"      no_call "ntfy user add"
  check "phone pass synced"      calls_have "NTFY_PASSWORD=phonepass ntfy ntfy user change-pass phone"
  check "kuma pass synced"       calls_have "NTFY_PASSWORD=kumapass ntfy ntfy user change-pass kuma"
  check "control pass synced"    calls_have "NTFY_PASSWORD=controlpass ntfy ntfy user change-pass control"
  check "grants still applied"   calls_have "ntfy access kuma alerts write-only"
  teardown
}

# env_val reads .env the way sourcing it does: `export ` prefixes, one pair
# of surrounding quotes and unquoted trailing comments all drop, last
# assignment wins. The grants must name the same topics the seeder sees —
# a literal `NTFY_TOPIC="alerts"` used to grant on `"alerts"` instead.
test_env_quoted_values() {
  echo "• quoted/exported .env values reach the ACL grants unquoted"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<'EOF'
KUMA_VOLUME=/tmp/k
NTFY_VOLUME=/tmp/n
KUMA_PORT=3002
NTFY_PORT=3003
NTFY_BASE_URL=https://x:3003
NTFY_TOPIC="alerts"   # the alerts topic
export CONTROL_TOPIC='ops'
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=my-custom-secret
EOF
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "grant on unquoted topic"     calls_have "ntfy access phone alerts read-only"
  check "grant on exported topic"     calls_have "ntfy access phone ops read-write"
  check "no literal quotes granted"   no_call 'ntfy access .*"'
  check "user's topic not shadowed"   no_call "ntfy access phone control "
  check "topic not re-appended"       sh -c "[ \$(grep -c 'CONTROL_TOPIC=' '$SVC/.env') -eq 1 ]"
  teardown
}

test_port_override() {
  echo "• KUMA_PORT override flows through (first run, when .env is written)"
  setup
  touch "$STATE_DIR/operator"
  export KUMA_PORT=3012
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check ".env records :3012"    env_has "KUMA_PORT=3012"
  check "served on :3012"       calls_have "tailscale serve --bg --https=3012 http://127.0.0.1:3012"
  teardown
}

test_env_wins_on_rerun() {
  echo "• re-run: .env is the source of truth — a shell override warns and loses"
  setup
  touch "$STATE_DIR/operator"
  write_env                      # .env says :3002/:3003, topic alerts
  export KUMA_PORT=3012 NTFY_TOPIC=other
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns KUMA_PORT ignored"    out_has "KUMA_PORT=3012 ignored"
  check "warns NTFY_TOPIC ignored"   out_has "NTFY_TOPIC=other ignored"
  check "serves the .env port"       calls_have "tailscale serve --bg --https=3002 http://127.0.0.1:3002"
  check "readiness probed :3002"     calls_have "http://127.0.0.1:3002/"
  check "nothing ever used :3012"    no_call "3012"
  teardown
}

test_https_port_formats() {
  echo "• re-run: HTTPS port set quoted, exported or commented in .env still wins"
  setup
  touch "$STATE_DIR/operator"
  # write_env puts KUMA_HTTPS_PORT=3002 on a plain line; swap the spelling of
  # the value and the published port must still follow it, not KUMA_PORT.
  for fmt in 'KUMA_HTTPS_PORT="8443"' "KUMA_HTTPS_PORT='8443'" \
             'export KUMA_HTTPS_PORT=8443' 'KUMA_HTTPS_PORT=8443 # tls port'; do
    write_env
    sed -i.bak "s|^KUMA_HTTPS_PORT=.*|$fmt|" "$SVC/.env" && rm "$SVC/.env.bak"
    : > "$CALLS_LOG"
    run_deploy
    check "exits zero: $fmt"          [ "$CODE" -eq 0 ]
    check "serves :8443 -> :3002"     calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:3002"
    check "never fell back to :3002"  no_call "tailscale serve --bg --https=3002 "
  done
  teardown
}

test_https_port_readback() {
  echo "• re-run: old .env without HTTPS keys keeps published=local; an override warns"
  setup
  touch "$STATE_DIR/operator"
  cat > "$SVC/.env" <<EOF
KUMA_VOLUME=$HOME/services/monitoring/kuma
NTFY_VOLUME=$HOME/services/monitoring/ntfy
KUMA_PORT=3002
NTFY_PORT=3003
NTFY_BASE_URL=https://test-host.tailfake.ts.net:3003
NTFY_TOPIC=alerts
KUMA_ADMIN_USER=admin
KUMA_ADMIN_PASSWORD=x
EOF
  export KUMA_HTTPS_PORT=8443
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "warns the override lost"   out_has "KUMA_HTTPS_PORT=8443 ignored"
  check "publishes :3002"           calls_have "tailscale serve --bg --https=3002 http://127.0.0.1:3002"
  check "never touched :8443"       no_call "8443"
  teardown
}

test_port_not_numeric() {
  echo "• non-numeric ports die before .env write or compose — shell and .env"
  setup
  export KUMA_PORT=abc
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the bad value"       out_has "KUMA_PORT must be numeric (got: abc)"
  check "no .env written"           [ ! -f "$SVC/.env" ]
  check "compose up never ran"      no_call " up -d"
  # a hand-corrupted .env on re-run dies the same way
  unset KUMA_PORT
  write_env
  sed -i.bak 's/^KUMA_PORT=.*/KUMA_PORT=oops/' "$SVC/.env" && rm "$SVC/.env.bak"
  run_deploy
  check "poisoned .env dies"        out_has "KUMA_PORT must be numeric (got: oops)"
  check "compose up still not run"  no_call " up -d"
  teardown
}

test_missing_openssl() {
  echo "• preflight: missing openssl dies early naming the install fix"
  setup
  # openssl lives in /usr/bin on real boxes, so hiding it needs a PATH with
  # only what the script uses before the check: bash/uname/dirname + stubs.
  mini="$STATE_DIR/mini-bin"; mkdir -p "$mini"
  for t in bash uname dirname; do ln -s "$(command -v "$t")" "$mini/$t"; done
  OUT="$(printf '' | PATH="$STUBS:$mini" bash "$SVC/setup.sh" 2>&1)"; CODE=$?
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the fix"           out_has "apt install openssl"
  check "wrote no .env"           [ ! -f "$SVC/.env" ]
  teardown
}

test_missing_uv() {
  echo "• preflight: missing uv dies early naming the install fix"
  setup
  nouv="$STATE_DIR/no-uv"; mkdir -p "$nouv"
  for s in "$STUBS"/*; do [ "${s##*/}" = uv ] || ln -s "$s" "$nouv/${s##*/}"; done
  OUT="$(printf '' | PATH="$nouv:/usr/bin:/bin" bash "$SVC/setup.sh" 2>&1)"; CODE=$?
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the fix"           out_has "astral.sh/uv/install.sh"
  check "wrote no .env"           [ ! -f "$SVC/.env" ]
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "both eventually published" sh -c "grep -c 'tailscale serve --bg --https=' '$CALLS_LOG' | grep -qv '^[01]$'"
  teardown
}

# ------------------------------------------------------- teardown tests
test_teardown() {
  echo "• teardown: unpublishes its two Serve ports, compose down, keeps .env + data"
  setup
  write_env
  mkdir -p "$HOME/services/monitoring/kuma" "$HOME/services/monitoring/ntfy"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3002 (tailnet only)
|-- / proxy http://127.0.0.1:3002

https://test-host.tailfake.ts.net:3003 (tailnet only)
|-- / proxy http://127.0.0.1:3003

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8081
EOF
  run_teardown
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "kuma port off"           calls_have "serve --https=3002 off"
  check "ntfy port off"           calls_have "serve --https=3003 off"
  check "neighbour port kept"     no_call "serve --https=8443 off"
  check "compose down"            calls_have "compose --project-directory .* down"
  check "no volume nuke"          no_call "down -v"
  check ".env kept"               [ -f "$SVC/.env" ]
  check "kuma data kept"          [ -d "$HOME/services/monitoring/kuma" ]
  check "ntfy data kept"          [ -d "$HOME/services/monitoring/ntfy" ]
  teardown
}

test_teardown_shared_port() {
  echo "• teardown: a Serve port shared with another service is left on with a warning"
  setup
  write_env
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /mon proxy http://127.0.0.1:3002
EOF
  run_teardown
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "warns it stayed"         out_has "also serves something else"
  check "never turned :443 off"   no_call "serve --https=443 off"
  check "still did compose down"  calls_have "compose --project-directory .* down"
  teardown
}

test_teardown_needs_env() {
  echo "• teardown: no .env means nothing to tear down"
  setup
  run_teardown
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says nothing deployed"   out_has "nothing here was deployed"
  teardown
}

test_teardown_serve_unreadable() {
  echo "• teardown: unreadable serve status aborts before touching anything"
  setup
  write_env
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "explains"                out_has "Could not read Tailscale Serve status"
  check "never ran compose down"  no_call "compose --project-directory .* down"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: confirms the name, deletes data dirs + .env only then"
  setup
  write_env
  mkdir -p "$HOME/services/monitoring/kuma/data" "$HOME/services/monitoring/ntfy/cache"
  run_teardown "nope" "--purge"
  check "wrong name: refused"     [ "$CODE" -ne 0 ]
  check ".env survived"           [ -f "$SVC/.env" ]
  check "data survived"           [ -d "$HOME/services/monitoring/kuma/data" ]
  run_teardown "monitoring" "--purge"
  check "confirmed: exits zero"   [ "$CODE" -eq 0 ]
  check "kuma dir gone"           [ ! -e "$HOME/services/monitoring/kuma" ]
  check "ntfy dir gone"           [ ! -e "$HOME/services/monitoring/ntfy" ]
  check ".env gone"               [ ! -f "$SVC/.env" ]
  check "service root rmdir'd"    [ ! -e "$HOME/services/monitoring" ]
  teardown
}

test_teardown_purge_unsafe_paths() {
  echo "• teardown --purge: unsafe data paths refuse before anything changes"
  setup
  mkdir -p "$HOME/services/monitoring/kuma" "$HOME/services/monitoring/ntfy" \
          "$HOME/services/other-svc"

  # a sibling service's directory is never a purge target
  write_env
  sed -i.bak "s|^KUMA_VOLUME=.*|KUMA_VOLUME=$HOME/services/other-svc|" "$SVC/.env" && rm "$SVC/.env.bak"
  run_teardown "monitoring" "--purge"
  check "sibling dir: refused"          [ "$CODE" -ne 0 ]
  check "sibling dir survives"          [ -d "$HOME/services/other-svc" ]
  check "no serve port turned off"      no_call "serve --https="
  check "compose never ran down"        no_call "compose --project-directory"
  check ".env kept"                     [ -f "$SVC/.env" ]

  # a symlinked leaf pointing at a sibling — same refusal
  write_env
  rm -rf "$HOME/services/monitoring/kuma"
  ln -s "$HOME/services/other-svc" "$HOME/services/monitoring/kuma"
  : > "$CALLS_LOG"
  run_teardown "monitoring" "--purge"
  check "symlink leaf: refused"         [ "$CODE" -ne 0 ]
  check "link itself survives"          [ -L "$HOME/services/monitoring/kuma" ]
  check "link target survives"          [ -d "$HOME/services/other-svc" ]
  check "no serve port turned off"      no_call "serve --https="
  check "compose never ran down"        no_call "compose --project-directory"
  check ".env kept"                     [ -f "$SVC/.env" ]

  # a '..' component escaping ~/services/monitoring — same refusal
  write_env
  rm -f "$HOME/services/monitoring/kuma" && mkdir -p "$HOME/services/monitoring/kuma"
  sed -i.bak "s|^KUMA_VOLUME=.*|KUMA_VOLUME=$HOME/services/monitoring/../other-svc|" "$SVC/.env" && rm "$SVC/.env.bak"
  : > "$CALLS_LOG"
  run_teardown "monitoring" "--purge"
  check ".. path: refused"              [ "$CODE" -ne 0 ]
  check "explains"                      out_has "\.\."
  check "sibling dir survives"          [ -d "$HOME/services/other-svc" ]
  check "own data dir survives"         [ -d "$HOME/services/monitoring/kuma" ]
  check "no serve port turned off"      no_call "serve --https="
  check "compose never ran down"        no_call "compose --project-directory"
  check ".env kept"                     [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_path_boundaries() {
  echo "• teardown --purge: a path with a space or a glob char deletes itself only"
  setup
  write_env
  mkdir -p "$HOME/services/monitoring/kuma" \
          "$HOME/services/monitoring/kuma data" \
          "$HOME/services/monitoring/ntfy*" \
          "$HOME/services/monitoring/ntfy-other"
  # 'kuma data' must be deleted whole; a word-split sibling 'kuma' and the
  # 'ntfy*' glob matches must survive — the purge list keeps path boundaries.
  sed -i.bak \
    -e "s|^KUMA_VOLUME=.*|KUMA_VOLUME=$HOME/services/monitoring/kuma data|" \
    -e "s|^NTFY_VOLUME=.*|NTFY_VOLUME=$HOME/services/monitoring/ntfy*|" \
    "$SVC/.env" && rm "$SVC/.env.bak"
  run_teardown "monitoring" "--purge"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "spaced dir deleted"            [ ! -e "$HOME/services/monitoring/kuma data" ]
  check "split-off sibling survives"    [ -d "$HOME/services/monitoring/kuma" ]
  check "literal glob dir deleted"      [ ! -e "$HOME/services/monitoring/ntfy*" ]
  check "glob match survives"           [ -d "$HOME/services/monitoring/ntfy-other" ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
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

# Fails only on wildcard binds (0.0.0.0 / [::] / *) = real LAN exposure.
# Tailscaled's own serve listener sits on the tailnet IP at the same port
# (local port == HTTPS port here) and is expected.
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
  local ts kport nport url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  kport="$(sed -n 's/^KUMA_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  nport="$(sed -n 's/^NTFY_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  live_check "kuma container running"     sh -c "docker inspect -f '{{.State.Status}}' uptime-kuma | grep -qx running"
  live_check "ntfy container running"     sh -c "docker inspect -f '{{.State.Status}}' ntfy | grep -qx running"
  live_check "kuma local responds"        curl -fsS "http://127.0.0.1:$kport/"
  live_check "ntfy local health"          sh -c "curl -fsS http://127.0.0.1:$nport/v1/health | grep -q healthy"
  live_check "kuma loopback-only"         no_external_listener "$kport"
  live_check "ntfy loopback-only"         no_external_listener "$nport"
  live_check "serve maps kuma :$kport"    sh -c "'$ts' serve status | grep -A2 ':$kport' | grep -q 'proxy http://127.0.0.1:$kport'"
  live_check "serve maps ntfy :$nport"    sh -c "'$ts' serve status | grep -A2 ':$nport' | grep -q 'proxy http://127.0.0.1:$nport'"
  live_check "kuma tailnet HTTPS"         curl -fsS -o /dev/null --max-time 30 "$url:$kport/"
  live_check "ntfy tailnet HTTPS"         curl -fsS -o /dev/null --max-time 30 "$url:$nport/v1/health"
}

# Runs the real seed_kuma.py against a fake uptime_kuma_api that records the
# monitors it is asked to add, so what is seeded is asserted, not assumed.
run_seed() {
  mkdir -p "$SANDBOX/fakelib"
  cat > "$SANDBOX/fakelib/uptime_kuma_api.py" <<'PYEOF'
import os


class MonitorType:
    HTTP = "http"
    DNS = "dns"


class NotificationType:
    NTFY = "ntfy"


class UptimeKumaApi:
    def __init__(self, url, timeout=30): pass
    def need_setup(self): return False
    def setup(self, *a): pass
    def login(self, *a): pass
    def get_notifications(self):
        # one canned notification per line of $FAKE_KUMA_NOTIFS:
        # "id name auth-method [username [password]]"
        path = os.environ.get("FAKE_KUMA_NOTIFS", "")
        out = []
        try:
            with open(path) as fh:
                for line in fh:
                    parts = line.split()
                    d = {"id": int(parts[0]), "name": parts[1],
                         "ntfyAuthenticationMethod": parts[2]}
                    if len(parts) > 3:
                        d["ntfyusername"] = parts[3]
                    if len(parts) > 4:
                        d["ntfypassword"] = parts[4]
                    out.append(d)
        except OSError:
            pass
        return out
    def delete_notification(self, nid):
        with open(os.environ["FAKE_KUMA_LOG"], "a") as fh:
            fh.write("delnotif:%d\n" % nid)
    def add_notification(self, **kw):
        with open(os.environ["FAKE_KUMA_LOG"], "a") as fh:
            fh.write("notif:%s:%s:%s:%s\n" % (kw["name"], kw.get("ntfyAuthenticationMethod"),
                                            kw.get("ntfyusername", ""),
                                            kw.get("ntfypassword", "")))
        return {"id": 1}
    def get_monitors(self):
        # one canned monitor per line of $FAKE_KUMA_HAVE: "id name url"
        path = os.environ.get("FAKE_KUMA_HAVE", "")
        out = []
        try:
            with open(path) as fh:
                for line in fh:
                    mid, name, url = line.split(None, 2)
                    out.append({"id": int(mid), "name": name, "url": url.strip()})
        except OSError:
            pass
        return out
    def edit_monitor(self, mid, **kw):
        with open(os.environ["FAKE_KUMA_LOG"], "a") as fh:
            fh.write("edit:%d:%s\n" % (mid, kw.get("name") or kw.get("url", "")))
    def disconnect(self): pass

    def add_monitor(self, **kw):
        with open(os.environ["FAKE_KUMA_LOG"], "a") as fh:
            fh.write(kw["name"] + "\n")
PYEOF
  : > "$SANDBOX/kuma.log"
  OUT="$(PYTHONPATH="$SANDBOX/fakelib" FAKE_KUMA_LOG="$SANDBOX/kuma.log" \
    KUMA_PORT=3001 KUMA_ADMIN_USER=u KUMA_ADMIN_PASSWORD=p NTFY_PORT=8080 \
    ADGUARD_DNS_IP=100.77.77.77 \
    HERMES_ENV="$1" python3 "$SERVICE_DIR/seed_kuma.py" 2>&1)"
  CODE=$?
}

seeded()     { grep -qx -- "$1" "$SANDBOX/kuma.log"; }
not_seeded() { ! seeded "$1"; }
no_edit()    { ! grep -q -- "edit:$1:" "$SANDBOX/kuma.log"; }

test_seed_studio_monitor() {
  echo "• seed: the studio monitor exists only while STUDIO_ENABLED=1 in services/hermes-studio/.env"
  setup
  printf 'STUDIO_ENABLED=0\n' > "$SANDBOX/sl.env"
  run_seed "$SANDBOX/sl.env"
  check "flag off: seed exits zero"        [ "$CODE" -eq 0 ]
  check "flag off: app monitor still added" seeded hermes-studio
  check "flag off: dns monitor still added" seeded adguard-dns
  check "flag off: no studio monitor"      not_seeded hermes-studio-runner
  run_seed "$SANDBOX/absent.env"
  check "no env file: no studio monitor"   not_seeded hermes-studio-runner
  printf 'STUDIO_ENABLED=0\nSTUDIO_ENABLED=1\n' > "$SANDBOX/sl.env"
  run_seed "$SANDBOX/sl.env"
  check "flag on: seed exits zero"         [ "$CODE" -eq 0 ]
  check "flag on: studio monitor added"    seeded hermes-studio-runner
  teardown
}

test_seed_ntfy_auth() {
  echo "• seed: the ntfy channel uses the kuma account; stale 'none' or rotated password is replaced"
  setup
  # creds in env => channel created with username-password auth
  NTFY_KUMA_USER=kuma NTFY_KUMA_PASS=sekrit run_seed "$SANDBOX/absent.env"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "created with user+pass auth" grep -qx 'notif:ntfy-alerts:username-password:kuma:sekrit' "$SANDBOX/kuma.log"

  # an existing unauthenticated channel gets replaced, not kept failing
  printf '7 ntfy-alerts none\n' > "$SANDBOX/notifs"
  : > "$SANDBOX/kuma.log"
  FAKE_KUMA_NOTIFS="$SANDBOX/notifs" NTFY_KUMA_USER=kuma NTFY_KUMA_PASS=sekrit run_seed "$SANDBOX/absent.env"
  check "old channel deleted"         grep -qx 'delnotif:7' "$SANDBOX/kuma.log"
  check "recreated with auth"         grep -qx 'notif:ntfy-alerts:username-password:kuma:sekrit' "$SANDBOX/kuma.log"

  # a rotated password in .env replaces the stored channel with the new password
  printf '7 ntfy-alerts username-password kuma oldpass\n' > "$SANDBOX/notifs"
  : > "$SANDBOX/kuma.log"
  FAKE_KUMA_NOTIFS="$SANDBOX/notifs" NTFY_KUMA_USER=kuma NTFY_KUMA_PASS=sekrit run_seed "$SANDBOX/absent.env"
  check "rotated: old channel deleted" grep -qx 'delnotif:7' "$SANDBOX/kuma.log"
  check "rotated: new password saved"  grep -qx 'notif:ntfy-alerts:username-password:kuma:sekrit' "$SANDBOX/kuma.log"

  # a channel already on the right account and password is left alone
  printf '7 ntfy-alerts username-password kuma sekrit\n' > "$SANDBOX/notifs"
  : > "$SANDBOX/kuma.log"
  FAKE_KUMA_NOTIFS="$SANDBOX/notifs" NTFY_KUMA_USER=kuma NTFY_KUMA_PASS=sekrit run_seed "$SANDBOX/absent.env"
  check "matching channel kept"       sh -c "! grep -q 'delnotif' '$SANDBOX/kuma.log' && ! grep -q 'notif:' '$SANDBOX/kuma.log'"

  # no creds (pre-auth env) => the old anonymous behaviour is unchanged
  : > "$SANDBOX/kuma.log"
  run_seed "$SANDBOX/absent.env"
  check "no creds -> method none"     grep -qx 'notif:ntfy-alerts:none::' "$SANDBOX/kuma.log"
  teardown
}

test_seed_renamed_monitors() {
  echo "• seed: a pre-rename self-learn monitor is re-keyed, not duplicated"
  setup
  printf '7 self-learn https://old-host:8107/\n' > "$SANDBOX/have"
  FAKE_KUMA_HAVE="$SANDBOX/have" run_seed "$SANDBOX/absent.env"
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "old monitor re-keyed"           grep -qx 'edit:7:hermes-studio' "$SANDBOX/kuma.log"
  check "url repointed too"              grep -qx 'edit:7:https://homeserver.tail-name.ts.net:8107/' "$SANDBOX/kuma.log"
  check "not duplicated"                 not_seeded hermes-studio
  # both names already present: the operator split them, leave both alone
  printf '7 self-learn https://a/\n8 hermes-studio https://b/\n' > "$SANDBOX/have"
  FAKE_KUMA_HAVE="$SANDBOX/have" run_seed "$SANDBOX/absent.env"
  check "both kept: monitor 7 untouched" no_edit 7
  check "both kept: new one repointed"   grep -q 'edit:8:' "$SANDBOX/kuma.log"
  # the Gnosia-era monitor name re-keys the same way
  printf '9 gnosia-learn https://old-host:8107/\n' > "$SANDBOX/have"
  FAKE_KUMA_HAVE="$SANDBOX/have" run_seed "$SANDBOX/absent.env"
  check "gnosia-learn re-keyed"          grep -qx 'edit:9:hermes-studio' "$SANDBOX/kuma.log"
  printf '9 gnosia-learn-studio https://old-host:7250/\n' > "$SANDBOX/have"
  FAKE_KUMA_HAVE="$SANDBOX/have" run_seed "$SANDBOX/absent.env"
  check "gnosia-learn-studio re-keyed"   grep -qx 'edit:9:hermes-studio-runner' "$SANDBOX/kuma.log"
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_fresh_deploy
test_idempotent_rerun
test_existing_users_resynced
test_env_quoted_values
test_port_override
test_env_wins_on_rerun
test_https_port_formats
test_https_port_readback
test_port_not_numeric
test_missing_openssl
test_missing_uv
test_operator_escalation
test_teardown
test_teardown_shared_port
test_teardown_needs_env
test_teardown_serve_unreadable
test_teardown_purge
test_teardown_purge_unsafe_paths
test_teardown_purge_path_boundaries
test_seed_studio_monitor
test_seed_ntfy_auth
test_seed_renamed_monitors

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
