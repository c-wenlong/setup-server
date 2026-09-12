#!/usr/bin/env bash
#
# Tests for paperless-ngx/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with a temp $HOME and PATH stubs for docker/curl/tailscale/ss/sudo/id/sleep.
#
# WHAT MAKES THIS SUITE DIFFERENT FROM THE OTHERS HERE
#
# 1. THE STUBS ANSWER LIKE DJANGO, GIVEN THE ENVIRONMENT THE COMPOSE FILE
#    ACTUALLY PRODUCES. At `compose up` the docker stub expands
#    docker-compose.yml's `environment:` block against .env and writes the
#    result to $STATE_DIR/paperless_env; the curl stub then applies the real
#    ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS rules to every request. So the
#    assertions are not "does the string PAPERLESS_URL appear somewhere" —
#    they are "can a browser log in through Tailscale Serve". Delete
#    PAPERLESS_URL from the compose file and no assertion text changes; the
#    login POST simply starts coming back 403, exactly as it does in reality.
#
# 2. THE REVERSE-PROXY TRAP HAS TWO SIDES AND THEY PULL IN OPPOSITE
#    DIRECTIONS. Measured against the shipped image and Django 5.2.16:
#
#      - Serve terminates TLS and proxies plain HTTP with the Host header
#        preserved. Django therefore computes good_origin as
#        "http://<tailnet-name>:8095" while the browser sends
#        "https://<tailnet-name>:8095", and the POST is allowed only if that
#        exact string is in CSRF_TRUSTED_ORIGINS — i.e. only if PAPERLESS_URL
#        carries the scheme AND the port. Otherwise: every GET 200s, and the
#        login POST 403s. curl cannot see this by accident, because curl sends
#        no Origin header.
#
#      - ALLOWED_HOSTS defaults to ["*"], so nothing 400s until someone
#        "hardens" it. Narrow it and Django appends "localhost" but NOT
#        "127.0.0.1", so http://127.0.0.1:8095/ starts returning
#        400 Invalid HTTP_HOST header — the local health check, the Kuma
#        monitor and this suite's own live checks, all red against a healthy
#        app.
#
#    Both directions are asserted, and each has a companion test that breaks
#    the setting on purpose to prove the assertion is not vacuous.
#
# 3. ADMIN CREATION IS A NO-OP ON EVERY RUN AFTER THE FIRST, AND THAT IS THE
#    REQUIREMENT. Read out of the image
#    (src/documents/management/commands/manage_superuser.py, byte-identical in
#    2.18.4 and 3.1.3): the command returns early the moment the username is
#    taken or any superuser exists, and never calls set_password. The docker
#    stub models that exactly — it records the password the account was
#    created with and ignores .env from then on. So a setup.sh that "helpfully"
#    re-syncs the password with `docker exec ... changepassword` shows up as a
#    failed test, not as a silent reset of a password Kai changed in the UI.
#
# Nothing here touches the host: no ~/services/paperless-ngx, no real .env, no
# container is started, and the ad-hoc echosrv on :8098 is never so much as
# read. test_sandbox_was_hermetic proves it with before/after checksums.
#
# ---------------------------------------------------------------------------
# MUTATION RESULTS — see the block at the bottom of this file.
# ---------------------------------------------------------------------------

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# The node the tailscale stub reports — deliberately NOT this box's real
# kai-home-server / 100.85.87.87. On this service that matters more than
# usual: the tailnet URL is not decoration, it is the string that becomes
# CSRF_TRUSTED_ORIGINS. A hostname hardcoded in setup.sh or docker-compose.yml
# would pass against the real box and lock everyone out of any other one.
FAKE_HOST="test-host.tailfake.ts.net"
FAKE_URL="https://$FAKE_HOST"
PORT=8095

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
  unset FAKE_UID LOCAL_PORT HTTPS_PORT PAPERLESS_ADMIN_USER STATE_DIR CALLS_LOG
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

# Negation as a command, so `check` can assert that something does NOT hold.
# Necessary because the obvious `sh -c "! some_helper"` silently fails: the
# helpers below are bash functions and `sh -c` cannot see them, so the inner
# command is "not found", the `!` flips that to success, and the check passes
# for entirely the wrong reason. That is the vacuously-green shape this repo
# has been bitten by before.
not() { ! "$@"; }

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_hasF()   { grep -qF -- "$1" <<<"$OUT"; }
# Case-insensitive ERE. `<<<` is safe in these helpers because the harness runs
# under bash; it is NOT safe inside a `sh -c "..."` string, which is dash on
# this box and dies with "Syntax error: redirection unexpected". Two checks
# were written that way and so could never pass — use these helpers instead of
# rolling a herestring into a subshell.
out_matches() { grep -qiE -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | sed 's/^"//; s/"$//' | head -1; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ---- the effective container environment, as computed at `compose up` ------
# This is the file that makes the suite mean something: not what .env says, not
# what the compose file says, but what the web container would actually see
# after ${VAR} substitution. Every reverse-proxy assertion reads it.
penv()     { cat "$STATE_DIR/paperless_env" 2>/dev/null; }
penv_get() { sed -n "s/^$1=//p" "$STATE_DIR/paperless_env" 2>/dev/null | head -1; }
penv_has() { [ -n "$(penv_get "$1")" ]; }

# ---- static assertions on docker-compose.yml, comments stripped ------------
# Always stripped: the compose file in this repo documents at length what it
# deliberately does NOT do (Tika/Gotenberg, `:latest`, wildcard binds), so a
# naive grep matches the prose and concludes the opposite of the truth.
compose()       { sed 's/#.*//' "$SVC/docker-compose.yml"; }
compose_has()   { compose | grep -qE -- "$1"; }
compose_hasF()  { compose | grep -qF -- "$1"; }
compose_lacks() { ! compose_has "$1"; }

# One `image:` line per service, so this is also the service count.
compose_image_count() { compose | grep -cE '^[[:space:]]*image:'; }
compose_memlimit_count() { compose | grep -cE '^[[:space:]]*mem_limit:'; }
# An image reference with no `:tag` IS :latest — spelled so that a
# `grep :latest` never finds it.
any_untagged_image() {
  compose | sed -n 's/^[[:space:]]*image:[[:space:]]*//p' | grep -qv ':'
}
# Every published port must name 127.0.0.1 explicitly. `- "8095:8000"` binds
# 0.0.0.0 — the one-character edit that puts a document archive on the LAN.
# setup.sh with its comments stripped — same reason as compose().
setup_body()     { sed 's/#.*//' "$SVC/setup.sh"; }
setup_mentions() { setup_body | grep -qE -- "$1"; }

# The biggest mem_limit in the file, in MiB. A plain `sort -r` would be wrong
# here — it is a string sort, so "96m" sorts above "1g".
max_mem_limit_mb() {
  local v n max=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    n="$(printf '%s' "$v" | tr -d '"'"'"' ' | sed 's/[mMgGbB]*$//')"
    case "$v" in
      *[gG]*) n=$((n * 1024)) ;;
    esac
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max="$n"
  done <<EOF
$(compose | sed -n 's/^[[:space:]]*mem_limit:[[:space:]]*//p')
EOF
  printf '%s' "$max"
}

any_unbound_port() {
  compose | sed -n '/^[[:space:]]*ports:/,/^[[:space:]]*[a-z_]*:[[:space:]]*$/p' \
    | grep -E '^[[:space:]]*-' | grep -qvE '127\.0\.0\.1:'
}

# ---- probes that ask the stubs the questions a browser would ---------------
# These run AFTER a deploy, against the environment that deploy produced.

# A plain unauthenticated GET of the health path, over loopback.
probe_local_health() {  # -> prints the status code
  PATH="$STUBS:$PATH" curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/accounts/login/"
}

# The same over the tailnet front door.
probe_tailnet_health() {
  PATH="$STUBS:$PATH" curl -s -o /dev/null -w '%{http_code}' \
    "$FAKE_URL:$PORT/accounts/login/"
}

# /api/remote_version/ — the other unauthenticated 200, and a JSON one, which
# makes it the better Uptime Kuma target. Note this is NOT true of /api/ itself
# (302) or /api/status/ (401): "an API path" is not the same as "a health path".
probe_api_version() {
  PATH="$STUBS:$PATH" curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/api/remote_version/"
}

# THE ONE THAT MATTERS: a browser-shaped login POST through Serve. Sends the
# Origin header a browser always sends on a cross-scheme POST, which is the
# only way the CSRF rule ever fires. A 403 whose body lacks the "requires a
# CSRF cookie" prose is the bad-origin rejection; a 403 that HAS it means the
# origin was accepted and only the token was missing, which is correct for a
# request with no cookie jar.
probe_browser_login_origin_accepted() {
  local body
  body="$(PATH="$STUBS:$PATH" curl -s -X POST \
    -H "Origin: $FAKE_URL:$PORT" \
    -d 'login=kai&password=x' \
    "http://127.0.0.1:$PORT/accounts/login/")"
  printf '%s' "$body" | grep -q 'requires a CSRF cookie'
}

# A full, correct login: fetch the page for a token+cookie, then post it back
# with the browser's Origin. This is the end-to-end proof that the deployed
# credentials work through the reverse proxy.
probe_full_login() {  # probe_full_login <user> <password> -> 302 on success
  local jar="$SANDBOX/jar" code
  PATH="$STUBS:$PATH" curl -s -c "$jar" -o /dev/null \
    "http://127.0.0.1:$PORT/accounts/login/"
  code="$(PATH="$STUBS:$PATH" curl -s -b "$jar" -o /dev/null -w '%{http_code}' \
    -X POST -H "Origin: $FAKE_URL:$PORT" \
    -d "csrfmiddlewaretoken=STUBCSRFTOKEN0000000000000000000&login=$1&password=$2" \
    "http://127.0.0.1:$PORT/accounts/login/")"
  [ "$code" = "302" ]
}

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
  export LOCAL_PORT=80o5
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

# ===========================================================================
# THE ONE THAT MATTERS MOST
# ===========================================================================
test_reverse_proxy_config() {
  echo "• the reverse-proxy settings are right, and a browser can actually log in"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]

  # --- PAPERLESS_URL reaches the container, and is the EXTERNAL url ---------
  check "PAPERLESS_URL is set in the container's environment" penv_has PAPERLESS_URL
  check "  it is the tailnet HTTPS url, with the port" \
    [ "$(penv_get PAPERLESS_URL)" = "$FAKE_URL:$PORT" ]
  # Each of these is a real way to get it wrong, and each produces the same
  # 403 with no clue in the page.
  check "  not http:// (scheme is compared)" \
    sh -c "! printf '%s' \"$(penv_get PAPERLESS_URL)\" | grep -q '^http://'"
  check "  not the loopback address" \
    sh -c "! printf '%s' \"$(penv_get PAPERLESS_URL)\" | grep -q '127.0.0.1'"
  check "  carries a port (CSRF compares the whole string)" \
    sh -c "printf '%s' \"$(penv_get PAPERLESS_URL)\" | grep -qE ':[0-9]+\$'"
  check "  has no trailing slash" \
    sh -c "! printf '%s' \"$(penv_get PAPERLESS_URL)\" | grep -q '/\$'"
  # The tailnet name came from `tailscale status`, not from a literal.
  check "asked tailscale for the node name" calls_have "^tailscale status"
  check "  and no real tailnet name is baked into the compose file" \
    compose_lacks 'kai-home-server|taild6a23f'
  check "  nor into setup.sh" \
    sh -c "! sed 's/#.*//' '$SVC/setup.sh' | grep -qE 'kai-home-server|taild6a23f'"

  # --- ALLOWED_HOSTS is not narrowed into breaking the loopback check -------
  check "loopback health path answers 200" [ "$(probe_local_health)" = "200" ]
  check "tailnet health path answers 200"  [ "$(probe_tailnet_health)" = "200" ]

  # --- the browser POST, which is the only thing that proves CSRF is right --
  check "a browser-origin login POST is NOT rejected as a bad origin" \
    probe_browser_login_origin_accepted
  check "  and a correct login through the proxy succeeds" \
    probe_full_login "$(penv_get PAPERLESS_ADMIN_USER)" "$(penv_get PAPERLESS_ADMIN_PASSWORD)"
  teardown
}

test_missing_paperless_url_is_caught() {
  echo "• PAPERLESS_URL removed: the login POST really does 403 (the check has teeth)"
  # A companion to the test above. If this one ever goes green-by-passing, the
  # assertions in test_reverse_proxy_config are vacuous and the suite is
  # decorative. Breaking the setting on purpose is the only way to know.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "deploy succeeded first"        [ "$CODE" -eq 0 ]
  check "  and the browser login worked" probe_browser_login_origin_accepted

  # Now take PAPERLESS_URL out of the compose file and restart the stack.
  sed 's/PAPERLESS_URL/PAPERLESS_DISABLED_URL/' "$SVC/docker-compose.yml" \
    > "$SVC/docker-compose.yml.new" && mv "$SVC/docker-compose.yml.new" "$SVC/docker-compose.yml"
  rm -f "$STATE_DIR/paperless_env"
  PATH="$STUBS:$PATH" docker compose --project-directory "$SVC" up -d >/dev/null 2>&1

  check "PAPERLESS_URL is now absent"    not penv_has PAPERLESS_URL
  # Every GET still looks perfect. That is the entire trap: measured by
  # pl-deploy with PAPERLESS_URL removed and everything else identical,
  # / -> 302, /accounts/login/ -> 200, /api/remote_version/ -> 200.
  check "every GET still returns 200"    [ "$(probe_local_health)" = "200" ]
  check "  the API version probe too"    [ "$(probe_api_version)" = "200" ]
  # ...and the only thing that changed is the one thing no GET can see.
  check "  but the browser login now 403s on the origin" \
    not probe_browser_login_origin_accepted
  check "  and a full, correct login now fails" \
    not probe_full_login "kai" "whatever"
  teardown
}

test_allowed_hosts_narrowing_breaks_loopback() {
  echo "• PAPERLESS_ALLOWED_HOSTS narrowed to the tailnet name: loopback 400s"
  # The mirror-image trap, and the reason this deploy leaves ALLOWED_HOSTS at
  # its ["*"] default. Django appends "localhost" to a narrowed list but never
  # "127.0.0.1", so the browser keeps working while every local check breaks.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "deploy succeeded"                 [ "$CODE" -eq 0 ]
  check "as shipped, ALLOWED_HOSTS is not narrowed" \
    not penv_has PAPERLESS_ALLOWED_HOSTS
  check "  so loopback health is 200"      [ "$(probe_local_health)" = "200" ]

  # Narrow it, the way a well-meaning hardening pass would.
  printf 'PAPERLESS_ALLOWED_HOSTS=%s\n' "$FAKE_HOST" >> "$STATE_DIR/paperless_env"
  check "narrowed: the tailnet URL still works" [ "$(probe_tailnet_health)" = "200" ]
  check "  but loopback now returns 400"        [ "$(probe_local_health)" = "400" ]
  teardown
}

test_health_path_is_a_real_200() {
  echo "• the health path is an unauthenticated 200 — not a 302 Kuma scores as down"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local code_root code_api code_login code_ver
  code_login="$(probe_local_health)"
  code_ver="$(probe_api_version)"
  code_root="$(PATH="$STUBS:$PATH" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
  code_api="$(PATH="$STUBS:$PATH" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/")"
  check "/accounts/login/ is 200 unauthenticated"     [ "$code_login" = "200" ]
  check "/api/remote_version/ is 200 unauthenticated" [ "$code_ver" = "200" ]
  # The near misses, all of which look like reasonable health paths and are not.
  check "  / is a 302 (so it is NOT the health path)" [ "$code_root" = "302" ]
  check "  /api/ is a 302 too, despite being an API path" [ "$code_api" = "302" ]
  # Whatever setup.sh verifies with, it must not be one of the redirecting
  # paths — that is a monitor that reads as permanently down.
  check "setup.sh health-checks the login path" calls_have "127.0.0.1:$PORT/accounts/login/"
  teardown
}

# ===========================================================================
# admin creation
# ===========================================================================
test_admin_created_once_and_never_reset() {
  echo "• the admin account is created once and a re-run NEVER resets its password"
  # The requirement, and the measured behaviour it rests on: manage_superuser
  # returns early once the user (or any superuser) exists and never calls
  # set_password. A second run must therefore be a no-op — and setup.sh must
  # not paper over that with an explicit `changepassword`, which would silently
  # overwrite a password changed in the UI.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                       [ "$CODE" -eq 0 ]
  check "an admin account was created"     [ -f "$STATE_DIR/superuser" ]
  check "  exactly once"                   [ "$(wc -l < "$STATE_DIR/superuser_created_runs")" -eq 1 ]
  check "  with the username from .env"    [ "$(cut -d: -f1 "$STATE_DIR/superuser")" = "$(penv_get PAPERLESS_ADMIN_USER)" ]
  check "  and the password from .env"     [ "$(cut -d: -f2 "$STATE_DIR/superuser")" = "$(penv_get PAPERLESS_ADMIN_PASSWORD)" ]
  local first_pw; first_pw="$(cut -d: -f2 "$STATE_DIR/superuser")"

  # An ordinary re-run — nothing changed — is a clean no-op and must succeed.
  # Measured by pl-deploy on the real image, second boot:
  #   [init-superuser] Creating superuser...
  #   Did not create superuser, a user kai already exists
  #   [init-superuser] Superuser creation done
  : > "$CALLS_LOG"
  run_deploy
  check "a plain re-run exits zero"        [ "$CODE" -eq 0 ]
  check "  created no second account"      [ "$(wc -l < "$STATE_DIR/superuser_created_runs")" -eq 1 ]
  check "  password untouched"             [ "$(cut -d: -f2 "$STATE_DIR/superuser")" = "$first_pw" ]
  check "  and it still logs in"           probe_full_login "$(penv_get PAPERLESS_ADMIN_USER)" "$first_pw"
  teardown
}

test_password_changed_in_ui_is_not_stomped() {
  echo "• password changed in the UI: setup.sh must NOT put .env's back"
  # The requirement Kai actually cares about. manage_superuser physically
  # cannot reset it — it returns early once the user exists — so the only way a
  # password gets stomped is if setup.sh reaches for `changepassword` to
  # "repair" the mismatch it detects. That would silently undo a deliberate
  # change, and there is no undo. Detecting and reporting the drift is right;
  # repairing it is not.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local user first_pw
  user="$(penv_get PAPERLESS_ADMIN_USER)"
  first_pw="$(cut -d: -f2 "$STATE_DIR/superuser")"

  # The user changes their password in the UI. .env still holds the old one.
  printf '%s:%s' "$user" "changed-in-the-ui" > "$STATE_DIR/superuser"
  : > "$CALLS_LOG"
  run_deploy

  check "the UI password survived the run" \
    [ "$(cut -d: -f2 "$STATE_DIR/superuser")" = "changed-in-the-ui" ]
  check "  no changepassword was forced"     [ ! -f "$STATE_DIR/changepassword_called" ]
  check "  no createsuperuser either"        [ "$(wc -l < "$STATE_DIR/superuser_created_runs")" -eq 1 ]
  check "  and the UI password still logs in" probe_full_login "$user" "changed-in-the-ui"
  check "  while .env's stale one does not"  not probe_full_login "$user" "$first_pw"
  # Silent is the one thing it must not be: .env is now wrong, and the next
  # person to read it will be misled. Whether setup.sh exits non-zero or warns,
  # it has to SAY so.
  # Second instance of the `<<<`-under-`sh` bug (see test_sandbox_was_hermetic):
  # a bash herestring in a `sh -c` string is a dash syntax error here, so this
  # reported a silent deploy on every run. Use the harness's own helper.
  check "the run reports the mismatch rather than hiding it" \
    out_matches 'password|credential'
  teardown
}

test_admin_user_is_always_passed() {
  echo "• PAPERLESS_ADMIN_USER reaches the container — without it NO account is made"
  # The init script skips the superuser command entirely when the variable is
  # unset, logs "Not creating superuser", and carries on. The result is a
  # perfectly healthy Paperless that nobody can log into, and nothing in the
  # deploy output says so.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "PAPERLESS_ADMIN_USER is in the container env"     penv_has PAPERLESS_ADMIN_USER
  check "PAPERLESS_ADMIN_PASSWORD is in the container env" penv_has PAPERLESS_ADMIN_PASSWORD
  check "  the password is not a placeholder" \
    sh -c "! printf '%s' \"$(penv_get PAPERLESS_ADMIN_PASSWORD)\" | grep -qiE '^(admin|password|changeme|change-me)\$'"
  check "  and is long enough to be generated, not typed" \
    sh -c "[ \${#1} -ge 16 ]" _ "$(penv_get PAPERLESS_ADMIN_PASSWORD)"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, still published and verified"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local pw; pw="$(env_val PAPERLESS_ADMIN_PASSWORD)"
  echo '# my-custom-marker' >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "existing .env untouched"   env_has "my-custom-marker"
  check "  password unchanged"      [ "$(env_val PAPERLESS_ADMIN_PASSWORD)" = "$pw" ]
  check "  secret key unchanged"    [ -n "$(env_val PAPERLESS_SECRET_KEY)" ]
  check "never invoked sudo"        no_call "^sudo "
  check "compose up re-invoked"     [ -f "$STATE_DIR/compose_up" ]
  check "re-applied the serve config" \
    calls_have "tailscale serve --bg --https=$PORT http://127.0.0.1:$PORT"
  teardown
}

# ===========================================================================
# readiness
# ===========================================================================
test_readiness_race() {
  echo "• cold start refuses the connection: the readiness loop retries, not dies"
  # A container that is 'up' is not a server that is listening. On a first boot
  # Paperless runs migrations before gunicorn binds anything, so curl answers
  # with exit 7 and http_code 000 — NOT a tidy 503 — and a deploy that treats
  # the first 000 as fatal fails nearly every first boot. Jellyfin's deploy in
  # this repo was bitten by exactly this.
  setup
  touch "$STATE_DIR/operator"
  echo 5 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "polled the health path repeatedly" \
    [ "$(call_count "127.0.0.1:$PORT/accounts/login/")" -ge 6 ]
  check "  waited between polls"       [ "$(call_count '^sleep ')" -ge 5 ]
  check "still published"              calls_have "tailscale serve --bg --https=$PORT"
  check "the admin account still exists" [ -f "$STATE_DIR/superuser" ]
  teardown
}

test_never_ready() {
  echo "• server never answers: dies, and publishes nothing"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/conn_refused_left"   # more refusals than the loop has tries
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "published nothing"    no_call "tailscale serve --bg"
  teardown
}

test_secret_key_refusal() {
  echo "• no PAPERLESS_SECRET_KEY: the container refuses to start, and setup.sh says so"
  # settings.py raises ImproperlyConfigured for an unset key and for the
  # literal "change-me". The container exits immediately; a deploy that does
  # not notice hands back a dead stack.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/no_secret_key"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "the container refused"   [ -f "$STATE_DIR/secret_key_refused" ]
  check "published nothing"       no_call "tailscale serve --bg"
  teardown
}

test_secret_key_is_generated() {
  echo "• the secret key is generated, long, and stable across runs"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local k; k="$(penv_get PAPERLESS_SECRET_KEY)"
  check "a secret key reached the container" [ -n "$k" ]
  check "  it is not 'change-me'"            [ "$k" != "change-me" ]
  check "  and is at least 32 chars"         sh -c "[ \${#1} -ge 32 ]" _ "$k"
  run_deploy
  check "unchanged on a re-run"              [ "$(penv_get PAPERLESS_SECRET_KEY)" = "$k" ]
  teardown
}

# ===========================================================================
# compose hygiene: the box is RAM-constrained and loopback-only
# ===========================================================================
test_images_are_pinned() {
  echo "• every image tag is pinned — never :latest"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "no :latest anywhere"       compose_lacks ':latest'
  # Every `image:` line must carry a tag. An untagged image IS :latest, just
  # spelled in a way a `grep :latest` never finds.
  check "  and every image line has a tag" not any_untagged_image
  check "paperless image is pinned to a version" \
    compose_has 'image: *(ghcr.io/)?paperless-ngx/paperless-ngx:[^ ]*[0-9]'
  check "redis image is pinned"     compose_has 'image: *redis:[0-9]'
  # The tag reaches the container rather than being decoration in a comment.
  check "the running tag is a real version" \
    sh -c "printf '%s' \"\$1\" | grep -qE '[0-9]+\\.[0-9]+'" _ "$(compose | sed -n 's/.*paperless-ngx:\([^ ]*\).*/\1/p' | head -1)"
  teardown
}

test_mem_limits_on_every_container() {
  echo "• mem_limit is set on EVERY container (7.7 GB box, already swapping)"
  # Not a style rule. An OCR worker on a large scan is the most plausible thing
  # on this box to run away with memory, and without a limit it takes the whole
  # machine — immich, seafile, home-assistant — with it rather than just itself.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local services limits
  services="$(compose_image_count)"
  limits="$(compose_memlimit_count)"
  check "at least two services defined"     [ "$services" -ge 2 ]
  check "every service has a mem_limit"     [ "$limits" -ge "$services" ]
  check "  and none of them is unbounded"   compose_lacks 'mem_limit: *0'
  # Sized off the OCR PEAK, not off idle. Measured by pl-deploy on 3.1.3:
  # ~680 MiB idle, 784 MiB peak OCR'ing one small image, and a 10-page 300 dpi
  # scan costs more than that. A limit set from the idle figure OOM-kills the
  # worker mid-document, which surfaces as "the document silently never
  # appeared" — not as an error anyone would connect to memory.
  check "  the largest limit clears the measured OCR peak" \
    [ "$(max_mem_limit_mb)" -ge 1024 ]
  teardown
}

test_binds_loopback_only() {
  echo "• published on 127.0.0.1:8095 only — never a wildcard, never :8098"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "publishes on loopback"        compose_has '127\.0\.0\.1:\$\{?LOCAL_PORT'
  check "  no 0.0.0.0 bind"            compose_lacks '0\.0\.0\.0:'
  # Every `ports:` entry must carry an explicit 127.0.0.1 prefix. A published
  # port with no host address is 0.0.0.0 — the one-character edit that puts a
  # document archive on the LAN.
  check "  no port published without a host address" not any_unbound_port
  # 8098 is an ad-hoc python3 echosrv (pid 1781019) that predates this repo and
  # belongs to nobody here. Claiming it would not be a port conflict — it would
  # be killing someone else's process.
  check "  never claims 8098"          compose_lacks '8098'
  check "  nor does setup.sh"          not setup_mentions '8098'
  check "default local port is $PORT"  [ "$(env_val LOCAL_PORT)" = "$PORT" ]
  check "  and the HTTPS port matches" [ "$(env_val HTTPS_PORT)" = "$PORT" ]
  # Redis is reachable only on the compose network. A published broker port
  # would be an unauthenticated Redis on the host.
  check "redis publishes no host port" [ "$(compose | grep -c '127\.0\.0\.1:')" -le 1 ]
  teardown
}

test_wildcard_listener_is_caught() {
  echo "• the app port escaped loopback: caught and reported"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_wildcard"
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "names the exposure" out_has "0.0.0.0"
  teardown

  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_lan"
  run_deploy
  check "a LAN address is caught too" [ "$CODE" -ne 0 ]
  check "  names the LAN address"     out_hasF "192.168.1.42"
  teardown
}

test_port_already_in_use() {
  echo "• port 8095 already taken: fails with the real cause"
  setup
  touch "$STATE_DIR/operator"
  echo inuse > "$STATE_DIR/up_fail"
  run_deploy
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "names the port"      out_hasF "$PORT"
  check "published nothing"   no_call "tailscale serve --bg"
  teardown
}

test_data_dirs_created() {
  echo "• the data directories exist before the container mounts them"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local root; root="$HOME/services/paperless-ngx"
  check "data/ created"    [ -d "$root/data" ]
  check "media/ created"   [ -d "$root/media" ]
  check "consume/ created" [ -d "$root/consume" ]
  check "export/ created"  [ -d "$root/export" ]
  # Docker creates a missing bind-mount source as a ROOT-owned directory. If
  # setup.sh does not make them first, the consume folder is one you cannot
  # drop a file into without sudo — and Paperless silently ingests nothing.
  check "consume/ is writable by this user" [ -w "$root/consume" ]
  teardown
}

test_env_file_permissions() {
  echo "• .env holds the admin password and the secret key — mode 600"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check ".env generated"   [ -f "$SVC/.env" ]
  check "  mode 600"       [ "$(file_mode "$SVC/.env")" = "600" ]
  teardown
}

# ===========================================================================
# publish
# ===========================================================================
test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" \
    calls_have "tailscale serve --bg --https=$PORT http://127.0.0.1:$PORT"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the second
  # lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry" \
    calls_have "tailscale serve --bg --https=$PORT http://127.0.0.1:$PORT"
  teardown
}

test_https_front_door_slow() {
  echo "• tailnet HTTPS not answering yet: a warning, not a failed deploy"
  # The first request on a brand-new Serve port can take ~60s while the cert is
  # minted. Failing the deploy for that would make a correct run red.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/https_dead"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "still published"     calls_have "tailscale serve --bg --https=$PORT"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  echo 8096 > "$STATE_DIR/web_port"
  export LOCAL_PORT=8096 HTTPS_PORT=8096
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  [ "$(env_val LOCAL_PORT)" = "8096" ]
  # The URL that becomes CSRF_TRUSTED_ORIGINS has to move with the port, or the
  # login breaks on a non-default deployment and nowhere else.
  check "PAPERLESS_URL carries the new port" \
    [ "$(penv_get PAPERLESS_URL)" = "$FAKE_URL:8096" ]
  check "served :8096 -> :8096" \
    calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"

  export LOCAL_PORT=8097
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: .env unchanged"     [ "$(env_val LOCAL_PORT)" = "8096" ]
  check "re-run: never touched 8097" no_call "127.0.0.1:8097"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (8095) sitting next to a
  # LOCAL_PORT override would write a mismatched .env on first deploy, HTTPS
  # stuck at 8095 while LOCAL_PORT moved to 8096, so Tailscale Serve maps the
  # wrong pair and PAPERLESS_URL (hence CSRF_TRUSTED_ORIGINS) points at the
  # wrong port.
  setup
  touch "$STATE_DIR/operator"
  echo 8096 > "$STATE_DIR/web_port"
  export LOCAL_PORT=8096
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=8096"  [ "$(env_val LOCAL_PORT)" = "8096" ]
  check "  and HTTPS_PORT=8096"         [ "$(env_val HTTPS_PORT)" = "8096" ]
  check "served :8096 -> 127.0.0.1:8096" \
    calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  check "  and never :8095"           no_call "tailscale serve --bg --https=8095"
  check "PAPERLESS_URL carries :8096" [ "$(penv_get PAPERLESS_URL)" = "$FAKE_URL:8096" ]
  check "prints the :8096 URL"        out_hasF "$FAKE_URL:8096"

  # Re-run with no override at all: .env already settled on 8096, and the
  # read-back has to keep it rather than snapping HTTPS back to the 8095
  # literal.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero" [ "$CODE" -eq 0 ]
  check "re-run kept :8096 -> 127.0.0.1:8096" \
    calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  check "  and never :8095" no_call "tailscale serve --bg --https=8095"
  teardown

  setup
  touch "$STATE_DIR/operator"
  echo 8096 > "$STATE_DIR/web_port"
  export LOCAL_PORT=8096 HTTPS_PORT=8443
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8096" \
    calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8096"
  check "PAPERLESS_URL carries :8443" \
    [ "$(penv_get PAPERLESS_URL)" = "$FAKE_URL:8443" ]
  teardown
}

# ------------------------------------------------- sandbox integrity proof
# Recorded before the mocked suite runs, checked after it. A mocked suite that
# quietly wrote to ~/services/paperless-ngx or to the repo's real .env would be
# worse than no suite at all — on THIS service a stray run against the host
# could touch a document archive.
HOST_SNAPSHOT=""
snapshot_host() {
  local f
  HOST_SNAPSHOT=""
  for f in "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" \
           "$SERVICE_DIR/SETUP.md" "$SERVICE_DIR/TROUBLESHOOT.md" \
           "$SERVICE_DIR/.env" "$ORIG_HOME/services/paperless-ngx"; do
    if [ -f "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f $(cksum < "$f" 2>/dev/null || echo unreadable)"
    elif [ -d "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f dir $(ls -A "$f" 2>/dev/null | sort | cksum)"
    else
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f absent"
    fi
  done
}

test_sandbox_was_hermetic() {
  echo "• the mocked suite changed nothing on this host"
  local before="$HOST_SNAPSHOT"
  snapshot_host
  check "HOME restored" [ "$HOME" = "$ORIG_HOME" ]
  check "repo files + ~/services/paperless-ngx unchanged" \
    [ "$before" = "$HOST_SNAPSHOT" ]
  if [ "$before" != "$HOST_SNAPSHOT" ]; then
    red "      before:$before"
    red "      after: $HOST_SNAPSHOT"
  fi
  # A real .env leaking into the service dir is the specific failure a HOME
  # mistake produces, and the snapshot above cannot see it if it did not exist
  # before.
  # `<<<` is a bash herestring and this ran under `sh -c` — dash on this box —
  # so the check died with "Syntax error: redirection unexpected" and reported
  # a leak on every run whether or not one had happened. A hermeticity check
  # that cannot pass is worse than none: it trains you to ignore a red line
  # that is the only warning you would get for a real $HOME mistake.
  # printf | grep is portable and says the same thing.
  check "no .env leaked into the real service dir" \
    sh -c "printf '%s\n' '$before' | grep -q '$SERVICE_DIR/.env [0-9]' || [ ! -f '$SERVICE_DIR/.env' ]"
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
# (8095 -> 8095), so tailscaled legitimately listens on the tailnet IP for
# that port. The other services here differ (e.g. 10000 -> 3001) and never
# hit that overlap, which is why their simpler "anything not 127.0.0.1"
# check works for them and would false-positive here.
#
# This function body is byte-identical to immich's, adguard's, vaultwarden's
# and jellyfin's on purpose — it is the canonical implementation.
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
  # than letting red lines imply an outage. A shell started before the user was
  # added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  if [ ! -f "$SERVICE_DIR/.env" ]; then
    red "    ! no $SERVICE_DIR/.env — this service is not deployed on this box."
    red "      Deploy first: cd $SERVICE_DIR && ./setup.sh"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url web redis
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  env_of() { sed -n "s/^$1=//p" "$SERVICE_DIR/.env" | sed 's/^"//; s/"$//' | head -1; }
  port="$(env_of LOCAL_PORT)";  case "$port" in ''|*[!0-9]*) port=8095 ;; esac
  https_port="$(env_of HTTPS_PORT)"; case "$https_port" in ''|*[!0-9]*) https_port="$port" ;; esac
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  web="$(env_of CONTAINER_NAME)"; [ -n "$web" ] || web="paperless-ngx"
  redis="$(env_of REDIS_CONTAINER_NAME)"; [ -n "$redis" ] || redis="paperless-redis"

  # --- containers -------------------------------------------------------
  live_check "$web container running" \
    sh -c "docker inspect -f '{{.State.Status}}' '$web' | grep -qx running"
  live_check "$redis container running" \
    sh -c "docker inspect -f '{{.State.Status}}' '$redis' | grep -qx running"
  live_check "  paperless image is pinned, not :latest" \
    sh -c "! docker inspect -f '{{.Config.Image}}' '$web' | grep -q ':latest'"
  live_check "  redis image is pinned, not :latest" \
    sh -c "! docker inspect -f '{{.Config.Image}}' '$redis' | grep -q ':latest'"
  # The box is RAM-constrained and already swapping; an unlimited OCR worker
  # takes the machine down, not just itself.
  live_check "  $web has a memory limit" \
    sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' '$web')\" -gt 0 ]"
  live_check "  $redis has a memory limit" \
    sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' '$redis')\" -gt 0 ]"

  # --- local health -----------------------------------------------------
  # /accounts/login/ is the only unauthenticated 200. `/` and `/api/` are both
  # 302s, which Uptime Kuma scores as DOWN.
  live_check "local /accounts/login/ returns 200" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/accounts/login/' | grep -qx 200"
  live_check "  / is a 302 (confirming it is NOT the health path)" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/' | grep -qx 302"
  # A 400 here is ALLOWED_HOSTS narrowed without 127.0.0.1 — the app is fine
  # and every local check is broken.
  live_check "  loopback is NOT rejected by ALLOWED_HOSTS (no 400)" \
    sh -c "! curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/accounts/login/' | grep -qx 400"

  live_check "not listening on non-local ifaces (:$port)" no_external_listener "$port"
  # 8098 is somebody else's ad-hoc echosrv. If this deploy ever claims it, that
  # is a process kill, not a port conflict.
  live_check "  has not claimed :8098" \
    sh -c "! docker inspect -f '{{json .HostConfig.PortBindings}}' '$web' | grep -q 8098"

  # --- publish ----------------------------------------------------------
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS returns 200" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 60 '$url:$https_port/accounts/login/' | grep -qx 200"

  # --- THE REVERSE-PROXY ASSERTION -------------------------------------
  # A 200 over HTTPS proves nothing about whether anyone can log in: the CSRF
  # origin rule only fires on a POST carrying an Origin header, which curl
  # never sends unless told to. Send one.
  #
  # Reading the result: Django renders the SAME 403 page for "bad origin" and
  # for "no CSRF cookie" (the reason is only printed when DEBUG is on, and it
  # is not). They are distinguishable by the extra prose the no-cookie branch
  # renders. So — a 403 mentioning the CSRF cookie means the origin was
  # ACCEPTED and only the token was missing, which is correct for a request
  # with no cookie jar. A 403 without it is the real failure.
  live_check "a browser-origin login POST is not rejected as a bad origin" \
    sh -c "curl -s --max-time 20 -X POST -H 'Origin: $url:$https_port' \
             -d 'login=probe&password=probe' \
             'http://127.0.0.1:$port/accounts/login/' \
           | grep -q 'requires a CSRF cookie'"
  live_check "  PAPERLESS_URL in the container is the external https URL" \
    sh -c "docker exec '$web' printenv PAPERLESS_URL | grep -qx '$url:$https_port'"

  # --- the admin account really exists ----------------------------------
  # A deploy that never created one leaves a working login page nobody can get
  # past, and nothing else on this page would notice.
  live_check "a superuser exists in the database" \
    sh -c "docker exec '$web' python3 manage.py shell -c \
      'from django.contrib.auth.models import User; import sys; sys.exit(0 if User.objects.filter(is_superuser=True).exists() else 1)'"
  live_check "  and it is the username from .env" \
    sh -c "docker exec '$web' python3 manage.py shell -c \
      \"from django.contrib.auth.models import User; import sys; sys.exit(0 if User.objects.filter(username='\$(sed -n 's/^PAPERLESS_ADMIN_USER=//p' '$SERVICE_DIR/.env' | tr -d '\\\"' | head -1)').exists() else 1)\""

  # --- data on disk -----------------------------------------------------
  live_check "media/ exists (the documents)" \
    sh -c "test -d \"\$(sed -n 's/^PAPERLESS_ROOT=//p' '$SERVICE_DIR/.env' | tr -d '\"' | head -1)/media\" \
        || test -d \"\$HOME/services/paperless-ngx/media\""
  live_check "consume/ exists and is writable by you" \
    sh -c "test -w \"\$HOME/services/paperless-ngx/consume\""

  # --- the queue is actually attached -----------------------------------
  # Redis down means the web UI works perfectly and NOTHING is ever OCR'd.
  live_check "redis answers PING" \
    sh -c "docker exec '$redis' redis-cli ping | grep -qx PONG"

  printf '    → this archive has no backup. Export it and copy it off the box:\n'
  printf '      docker exec %s document_exporter ../export\n' "$web"
}

# ------------------------------------------------------------------ main
for f in setup.sh docker-compose.yml; do
  [ -f "$SERVICE_DIR/$f" ] || { red "paperless-ngx/$f is missing — nothing to test."; exit 1; }
done

echo "Mocked suite (sandboxed, no system changes):"
snapshot_host
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_reverse_proxy_config
test_missing_paperless_url_is_caught
test_allowed_hosts_narrowing_breaks_loopback
test_health_path_is_a_real_200
test_admin_created_once_and_never_reset
test_password_changed_in_ui_is_not_stomped
test_admin_user_is_always_passed
test_idempotent_rerun
test_readiness_race
test_never_ready
test_secret_key_refusal
test_secret_key_is_generated
test_images_are_pinned
test_mem_limits_on_every_container
test_binds_loopback_only
test_wildcard_listener_is_caught
test_port_already_in_use
test_data_dirs_created
test_env_file_permissions
test_operator_escalation
test_serve_approval_prompt
test_https_front_door_slow
test_port_override
test_https_port_follows_local_port
test_sandbox_was_hermetic

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
