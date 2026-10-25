#!/usr/bin/env bash
#
# Tests for services/vaultwarden/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with PATH stubs for docker/tailscale/curl/sudo/id/python3.
#
# Two things make this service's suite different from the others here.
#
# 1. THE SIGNUP LIFECYCLE. Nothing can create the owner's account — the master
#    password derives the vault key in the browser and must never reach the
#    server — so a fresh deploy has to leave registration OPEN and ask the
#    owner to go register. The next run counts the accounts in db.sqlite3 and
#    shuts the door. That is a stateful, three-branch handshake, and each
#    branch is a separate test below. The failure it guards against is silent:
#    a vault left accepting new accounts from anyone on the tailnet, on a
#    deploy that printed "Done."
#
# 2. THE ADMIN PANEL. It ships off, and `--live` asserts /admin/users is a 404.
#    An accidentally-enabled admin console on a password vault is the worst
#    regression in this repo, and it is exactly the kind that leaves every
#    other check green.
#
# The python3 stub fakes the account count so all three branches can be driven
# deterministically; the docker stub models a container environment that is
# rebuilt from .env on every `up` (so "edited .env but never recreated" is a
# state the suite can reach); the curl stub models a cold start as a real
# refused connection (exit 7, http_code 000) rather than a tidy 503.

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

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
env_lacks()  { ! grep -qi -- "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }

# How many `docker compose ... up` invocations carried --force-recreate.
# The flip is the one step in this deploy that must not be a no-op: a .env
# rewritten to SIGNUPS_ALLOWED=false that never reaches the container leaves
# the vault open while reporting it shut.
recreates() { cat "$STATE_DIR/recreate_count" 2>/dev/null || echo 0; }

# The account count the script was allowed to see, per test.
set_users() { echo "$1" > "$STATE_DIR/user_count"; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped — the file
# documents at length what it deliberately does NOT do ("upstream binds
# 0.0.0.0:80", the whole commented-out ADMIN_TOKEN recipe), so a naive grep
# would match the prose and conclude the exact opposite of the truth.
compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
compose_lacks()    { ! compose_has "$1"; }
no_wildcard_bind() { compose_lacks '0\.0\.0\.0'; }

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
  export LOCAL_PORT=82o2
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_no_python3() {
  echo "• preflight fails when python3 cannot import sqlite3"
  # python3 is not a convenience here. Counting the accounts in db.sqlite3 is
  # the ONLY way this script knows whether it is safe to close registration —
  # there is no API for it, because the script deliberately holds no
  # credentials. Without python3 the deploy would have to leave the door open
  # and hope, so it refuses to start instead.
  setup
  touch "$STATE_DIR/python3_missing"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names python3"           out_has "python3"
  check "  and the sqlite3 module" out_has "sqlite3 module"
  check "  and says why it needs it" out_has "account count"
  check "wrote no .env"           [ ! -f "$SVC/.env" ]
  check "started no container"    [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: signups left OPEN, said so loudly, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]

  # --- .env
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records the local port"    grep -qx 'LOCAL_PORT=8222' "$SVC/.env"
  check "pinned to 1.37.2, not latest"   grep -qx 'VAULTWARDEN_VERSION=1.37.2' "$SVC/.env"
  check ".env has VAULTWARDEN_DATA"      grep -qE '^VAULTWARDEN_DATA=/.+' "$SVC/.env"
  # DOMAIN is the full tailnet HTTPS URL, scheme and port included. Vaultwarden
  # derives the WebAuthn/passkey relying-party ID from it, so a wrong value
  # does not error — it breaks 2FA registration later, in the browser, with a
  # message that blames the security key.
  check "DOMAIN is the tailnet URL" \
    grep -qx 'VAULTWARDEN_DOMAIN=https://test-host.tailfake.ts.net:8222' "$SVC/.env"
  check "signups start OPEN in .env"     grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=true' "$SVC/.env"
  check "org invitations start off"      grep -qx 'VAULTWARDEN_INVITATIONS_ALLOWED=false' "$SVC/.env"
  # There is no server-side credential in this deploy at all, and inventing one
  # would only be a secret nobody needs. An ADMIN_TOKEN in particular would put
  # a user-deleting web console on the same URL as the vault.
  check ".env contains NO admin token"   env_lacks 'ADMIN_TOKEN'
  check ".env contains no password"      env_lacks 'PASSWORD='

  # --- compose, statically
  check "compose binds loopback only"    compose_hasF "127.0.0.1:\${LOCAL_PORT"
  check "compose binds no wildcard"      no_wildcard_bind
  check "container port is 80"           compose_hasF ':80'
  check "image pinned from .env"         compose_hasF 'image: vaultwarden/server:${VAULTWARDEN_VERSION'
  check "restart policy unless-stopped"  compose_has 'restart: *unless-stopped'
  check "no ADMIN_TOKEN key in compose"  compose_lacks 'ADMIN_TOKEN'
  # Fail CLOSED if .env is ever lost: a truncated .env must not reopen
  # registration to the whole tailnet.
  check "signups default to false"       compose_hasF 'SIGNUPS_ALLOWED: ${VAULTWARDEN_SIGNUPS_ALLOWED:-false}'
  # Org invitations bypass SIGNUPS_ALLOWED — the only other door into a closed
  # instance.
  check "invitations default to false"   compose_hasF 'INVITATIONS_ALLOWED: ${VAULTWARDEN_INVITATIONS_ALLOWED:-false}'
  # No SMTP on this box: signup verification would hand out a "check your
  # email" wall for a mail that can never arrive.
  check "signup email verify off"        compose_has 'SIGNUPS_VERIFY: *"false"'
  # A password hint is served unauthenticated to anyone who knows the address.
  check "password hints off"             compose_has 'SHOW_PASSWORD_HINT: *"false"'
  check "no user: override"              compose_lacks '^ *user:'

  # --- state + deploy
  check "data dir created"               [ -d "$(env_val VAULTWARDEN_DATA)" ]
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]
  check "waited on /alive locally"       calls_have "127.0.0.1:8222/alive"
  check "counted the accounts"           calls_have "^python3 "
  check "  did not force-recreate"       [ "$(recreates)" -eq 0 ]
  check "  left .env open"               grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=true' "$SVC/.env"
  # The script must never try to create the account itself, and must never try
  # to hash an admin token — `vaultwarden hash` panics without a TTY, which is
  # exactly why the admin panel is a documented manual recipe and not a step.
  check "ran no docker run (no TTY hash)" [ ! -f "$STATE_DIR/docker_run" ]

  # --- the headline: an open vault has to be impossible to miss
  check "says signups are OPEN"          out_has "Signups are OPEN"
  check "  warns anyone on the tailnet"  out_has "anyone on this tailnet can create an account"
  check "  tells you to register now"    out_has "Create account"
  check "  and to re-run to shut it"     out_has "re-run ./setup.sh"
  check "  warns the password is unrecoverable" out_has "forget it, the vault is gone"
  check "confirms the admin panel is off" out_has "No ADMIN_TOKEN"

  # --- publish
  check "served on tailscale :8222"      calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  check "no sudo needed (operator set)"  no_call "^sudo "

  # --- verification + final message
  check "verified over tailnet HTTPS"    calls_have "https://test-host.tailfake.ts.net:8222/alive"
  check "confirmed DOMAIN from the server" out_has "DOMAIN confirmed"
  check "prints final URL"               out_has "https://test-host.tailfake.ts.net:8222"
  check "tells clients to set a server URL" out_has "Server URL"
  check "warns there is no backup here"  out_has "backup"
  check "  gives the cold-copy command"  out_has "tar czf"
  check "  and the client-side export"   out_has "Password protected"
  teardown
}

test_readiness_retry() {
  echo "• cold start refuses the connection: the /alive loop retries, not dies"
  # A container that is 'up' is not a server that is listening. Real curl
  # answers a refused connection with exit 7 and http_code 000 — not a tidy
  # 503 — and a deploy that treats the first 000 as fatal fails most cold
  # starts. jellyfin's deploy in this repo was bitten by exactly this.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  echo 2 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "polled /alive repeatedly"    [ "$(call_count '127.0.0.1:8222/alive')" -ge 3 ]
  check "did not report a 000 failure" out_lacks "did not answer /alive"
  check "still counted the accounts"  calls_have "^python3 "
  check "still published"             calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  check "still says signups are OPEN" out_has "Signups are OPEN"
  teardown
}

test_rerun_zero_users_stays_open() {
  echo "• re-run with nobody registered: signups stay OPEN, instruction repeated"
  # The trap this guards: a re-run that "tidied up" by closing signups before
  # the owner has an account would lock the vault permanently — there is no
  # other way in, and no script can create the account.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy                                    # first deploy
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"
  run_deploy                                    # second deploy, still 0 users
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "reports the empty vault"      out_has "0 accounts in the vault"
  check ".env still says true"         grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=true' "$SVC/.env"
  check "did NOT force-recreate"       [ "$(recreates)" -eq 0 ]
  check "still says signups are OPEN"  out_has "Signups are OPEN"
  check "repeats the register-now step" out_has "re-run ./setup.sh"
  check "re-applied serve config"      calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  check "never invoked sudo"           no_call "^sudo "
  teardown
}

test_rerun_locks_signups() {
  echo "• re-run with an account present: flips SIGNUPS_ALLOWED and recreates"
  # The core of the design. Registration is open only for the window between
  # the first deploy and the owner registering; this run is what closes it.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy                                    # first deploy: door open
  check "setup: first run left it open" grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=true' "$SVC/.env"

  echo '# my-custom-marker' >> "$SVC/.env"      # the user edits their file
  domain_before="$(env_val VAULTWARDEN_DOMAIN)"
  data_before="$(env_val VAULTWARDEN_DATA)"
  other_before="$(grep -v '^VAULTWARDEN_SIGNUPS_ALLOWED=' "$SVC/.env")"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"

  set_users 1                                   # ...the owner registers...
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "noticed the account"           out_has "1 account(s) exist"
  check ".env flipped to false"         grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=false' "$SVC/.env"
  check "  and nothing else changed"    [ "$(grep -v '^VAULTWARDEN_SIGNUPS_ALLOWED=' "$SVC/.env")" = "$other_before" ]
  check "  user's marker preserved"     env_has "my-custom-marker"
  check "  DOMAIN untouched"            [ "$(env_val VAULTWARDEN_DOMAIN)" = "$domain_before" ]
  check "  data path untouched"         [ "$(env_val VAULTWARDEN_DATA)" = "$data_before" ]
  check "  still mode 600"              [ "$(file_mode "$SVC/.env")" = "600" ]
  # A rewritten .env that never reaches the container is the worst outcome
  # here: the deploy reports the door shut while it is still open.
  check "forced a container recreate"   [ "$(recreates)" -ge 1 ]
  check "  re-waited for /alive after"  [ "$(call_count '127.0.0.1:8222/alive')" -ge 2 ]
  check "confirmed against the container" out_has "Signups are now CLOSED"
  check "  says it checked the container" out_has "confirmed on the running container"
  check "final state says CLOSED"       out_has "Signups are CLOSED"
  check "  no longer says OPEN"         out_lacks "Signups are OPEN"
  check "explains how to add a person"  out_has "VAULTWARDEN_SIGNUPS_ALLOWED=true"
  check "still published"               calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  teardown
}

test_rerun_already_closed_is_noop() {
  echo "• re-run once signups are closed: a no-op, no rewrite, no recreate"
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy                                    # deploy
  set_users 1
  run_deploy                                    # closes the door
  env_before="$(cat "$SVC/.env")"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"
  run_deploy                                    # third run: nothing to do
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "says it is already closed"   out_has "already closed"
  check ".env byte-identical"         [ "$(cat "$SVC/.env")" = "$env_before" ]
  check "did NOT force-recreate"      [ "$(recreates)" -eq 0 ]
  check "still ran a plain up -d"     [ -f "$STATE_DIR/compose_up" ]
  check "final state says CLOSED"     out_has "Signups are CLOSED"
  check "never invoked sudo"          no_call "^sudo "
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  teardown
}

test_env_never_overwritten() {
  echo "• re-run never overwrites .env (the SIGNUPS line is the sole exception)"
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy
  printf '# my-custom-marker\nVAULTWARDEN_EXTRA=keepme\n' >> "$SVC/.env"
  env_before="$(cat "$SVC/.env")"
  run_deploy                                    # still 0 users: no exception applies
  check "exits zero"              [ "$CODE" -eq 0 ]
  check ".env byte-identical"     [ "$(cat "$SVC/.env")" = "$env_before" ]
  check "says it left it alone"   out_has "leaving untouched"
  check "custom key survived"     env_has "VAULTWARDEN_EXTRA=keepme"
  teardown
}

test_count_unknown() {
  echo "• account count unreadable: refuses to guess, exits non-zero"
  # Both count paths fail (unreadable db.sqlite3 AND a failed docker cp).
  # Neither default is acceptable: assuming 0 leaves registration open to the
  # tailnet, assuming 1 slams the door before the owner has an account. So the
  # script touches nothing, completes the publish, and fails loudly.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy                                    # deploy while it can still count
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"
  touch "$STATE_DIR/count_broken"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says the count failed"         out_has "Could not read the account count"
  check "  names both attempts"         out_has "docker cp"
  check "  says it changed nothing"     out_has "left exactly as it is"
  check "  gives the manual fix"        out_has "VAULTWARDEN_SIGNUPS_ALLOWED=false"
  check "did NOT touch .env"            grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=true' "$SVC/.env"
  check "did NOT force-recreate"        [ "$(recreates)" -eq 0 ]
  # Failing must not skip the publish repair or the state report — the deploy
  # is up either way, and the operator needs to know what it is doing.
  check "still published"               calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  check "still reported the state"      out_has "Signups are OPEN"
  teardown
}

test_count_falls_back_to_docker_cp() {
  echo "• db.sqlite3 unreadable by this user: falls back to docker cp, still closes"
  # The container runs as root, so a restrictive daemon umask can leave the
  # vault DB unreadable from the host. Going through the daemon is the only
  # way to count, and it must still be enough to shut the door.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"
  touch "$STATE_DIR/ro_count_fails"             # host read-only open fails
  set_users 1
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "used the docker cp path"    calls_have "^docker cp vaultwarden:/data/db.sqlite3"
  check "  copied the -wal too"      calls_have "db.sqlite3-wal"
  check "closed signups anyway"      grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=false' "$SVC/.env"
  check "  and recreated"            [ "$(recreates)" -ge 1 ]
  check "final state says CLOSED"    out_has "Signups are CLOSED"
  teardown
}

test_admin_token_on_container() {
  echo "• an ADMIN_TOKEN reached the container: warned about, not ignored"
  # The shipped compose has no ADMIN_TOKEN key at all, so this can only happen
  # if someone wired one in. On a password vault that is a user-deleting web
  # console on the same URL as the vault, so a run must not pass over it in
  # silence.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/admin_enabled"
  set_users 1
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "warns /admin is reachable"    out_has "ADMIN_TOKEN is set on the running container"
  check "  says what the panel can do" out_has "delete users"
  # And the closing summary must not then flatly contradict that warning. On
  # this service the summary saying "the /admin panel is disabled" while a
  # live admin console is answering on the vault's own URL is worse than
  # saying nothing: it is the line an operator scrolls to and believes.
  check "  summary does not claim it is off" out_lacks "panel is disabled"
  teardown
}

test_inspect_blind() {
  echo "• docker inspect tells us nothing: degrades honestly, never over-claims"
  # The script treats the running container's environment as the authority on
  # whether the door is open. When the daemon will not say (older daemon, the
  # container gone), the honest answer is "unconfirmed" — not a cheerful
  # summary. On a password vault, "the /admin panel is disabled" printed
  # without having checked is worse than printing nothing.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/inspect_blind"
  set_users 1
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "still closed .env"             grep -qx 'VAULTWARDEN_SIGNUPS_ALLOWED=false' "$SVC/.env"
  check "  and recreated"               [ "$(recreates)" -ge 1 ]
  check "says it could not confirm"     out_has "could not be confirmed"
  check "  gives the check to run"      out_has "docker inspect"
  check "did not claim confirmation"    out_lacks "confirmed on the running container"
  # The admin-panel line must hedge rather than guarantee.
  check "hedges on the admin panel"     out_has "should"
  check "  no flat 'is disabled' claim" out_lacks "panel is disabled"
  teardown
}

test_domain_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  # A stale DOMAIN is the quiet failure for this service. Vaultwarden binds
  # WebAuthn credentials to it, so the symptom is a security key that stops
  # working, reported by the browser, blaming the key.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  run_deploy                                    # first deploy on :8222
  old="$(env_val VAULTWARDEN_DOMAIN)"
  export HTTPS_PORT=8223                        # published somewhere else now
  run_deploy
  check "warns about the drift"    out_has "VAULTWARDEN_DOMAIN in .env is"
  check "  names the new address"  out_has "https://test-host.tailfake.ts.net:8223"
  check "  says 2FA will break"    out_has "2FA/passkey registration"
  check "  says to re-register keys" out_has "re-register any security keys"
  check ".env left alone (user's)" [ "$(env_val VAULTWARDEN_DOMAIN)" = "$old" ]
  unset HTTPS_PORT
  teardown
}

test_server_reports_wrong_domain() {
  echo "• the server itself reports a different domain: caught over HTTPS"
  # .env agreeing with itself proves nothing — this check asks the running
  # server what it will actually hand to WebAuthn.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/wrong_domain"
  set_users 0
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns about the mismatch"   out_has "reports its domain as"
  check "  explains the 2FA impact"  out_has "WebAuthn"
  check "  did not claim confirmed"  out_lacks "DOMAIN confirmed"
  check "still prints the URL"       out_has "https://test-host.tailfake.ts.net:8222"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  export LOCAL_PORT=8223 HTTPS_PORT=8223
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8223' "$SVC/.env"
  check "DOMAIN uses the new port"   grep -qx 'VAULTWARDEN_DOMAIN=https://test-host.tailfake.ts.net:8223' "$SVC/.env"
  check "polled :8223 for /alive"    calls_have "127.0.0.1:8223/alive"
  check "served :8223 -> :8223"      calls_have "tailscale serve --bg --https=8223 http://127.0.0.1:8223"
  check "prints the :8223 URL"       out_has "https://test-host.tailfake.ts.net:8223"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under the vault it is serving.
  export LOCAL_PORT=8224 HTTPS_PORT=8223
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8224 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8223' "$SVC/.env"
  check "re-run: still serves :8223" calls_have "tailscale serve --bg --https=8223 http://127.0.0.1:8223"
  check "re-run: never touched 8224" no_call "127.0.0.1:8224"
  unset LOCAL_PORT HTTPS_PORT
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (8222) next to a LOCAL_PORT
  # override would silently publish :8222 -> 127.0.0.1:8223, i.e. the wrong
  # port, and .env stores no HTTPS_PORT of its own to read back on a re-run.
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  export LOCAL_PORT=8223
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=8223"   grep -qx 'LOCAL_PORT=8223' "$SVC/.env"
  check "served :8223 -> 127.0.0.1:8223" calls_have "tailscale serve --bg --https=8223 http://127.0.0.1:8223"
  check "  and never :8222"              no_call "tailscale serve --bg --https=8222"
  check "prints the :8223 URL"           out_has "https://test-host.tailfake.ts.net:8223"
  # Re-run with no override at all: .env says 8223, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 8222.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/recreate_count"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8223 -> 127.0.0.1:8223" calls_have "tailscale serve --bg --https=8223 http://127.0.0.1:8223"
  check "  and never :8222"                   no_call "tailscale serve --bg --https=8222"
  teardown

  setup
  touch "$STATE_DIR/operator"
  set_users 0
  export LOCAL_PORT=8223 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8223" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8223"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  set_users 0
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  set_users 0
  # Two forced failures: the first trips the operator-grant branch, the
  # second lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8222 http://127.0.0.1:8222"
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
# (8222 -> 8222), so tailscaled legitimately listens on the tailnet IP for
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

# Does the running server agree that its DOMAIN is the address clients use?
#
# Two independent sources, because each can be unavailable on its own and
# neither alone is worth a false red. `/api/config` is the better answer — it
# is what the SERVER will hand to WebAuthn, asked over the same HTTPS origin a
# client uses — but the exact JSON shape is version-dependent, so a miss there
# falls back to the environment the container was actually started with.
# Only if BOTH disagree with $want is this a real failure.
domain_matches() {
  local want="$1" cfg
  cfg="$(curl -fsS --max-time 30 "$want/api/config" 2>/dev/null | tr -d ' ' || true)"
  case "$cfg" in
    *"\"vault\":\"$want\""*) return 0 ;;
  esac
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden 2>/dev/null \
    | grep -qx "DOMAIN=$want"
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
  local ts port https_port url want cenv signups
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  want="$url:$https_port"

  live_check "vaultwarden container running" \
    sh -c "docker inspect -f '{{.State.Status}}' vaultwarden | grep -qx running"

  # /alive answers 200 with an ISO timestamp as a JSON string — quotes
  # included: "2026-09-10T18:27:23.763911Z". Measured on 1.37.2, after this
  # check was first written against a bare timestamp and failed on the quote.
  live_check "local /alive responds" \
    sh -c "curl -fsS --max-time 30 'http://127.0.0.1:$port/alive' | grep -qE '^\"?[0-9]{4}-[0-9]{2}-[0-9]{2}T'"

  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds" \
    curl -fsS -o /dev/null --max-time 60 "$want/alive"

  # ---- the one that matters most on this service ----
  # An enabled admin panel is a web console that lists and deletes every
  # account, reachable on the same URL as the vault, behind one password. With
  # no ADMIN_TOKEN, /admin serves a static "disabled" notice (200) while
  # /admin/users and POST /admin are 404 — so the 200 on /admin is expected
  # and /admin/users is the assertion that actually means anything.
  live_check "admin panel is OFF: /admin/users is 404" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 '$want/admin/users')\" = 404 ]"
  live_check "  POST /admin is 404 too" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST '$want/admin')\" = 404 ]"
  live_check "  no ADMIN_TOKEN in the container env" \
    sh -c "! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden | grep -q '^ADMIN_TOKEN=.'"

  # DOMAIN, asked of the server rather than of .env. Wrong here and WebAuthn
  # /passkey enrolment fails in the browser, blaming the security key.
  live_check "server's DOMAIN is $want" domain_matches "$want"
  live_check "  and .env agrees" \
    sh -c "grep -qx 'VAULTWARDEN_DOMAIN=$want' '$SERVICE_DIR/.env'"

  live_check "vault data dir exists" \
    sh -c "test -d \"\$(sed -n 's/^VAULTWARDEN_DATA=//p' '$SERVICE_DIR/.env')\""

  # Org invitations bypass SIGNUPS_ALLOWED entirely — closing signups without
  # closing this leaves the other door open.
  live_check "org invitations are off" \
    sh -c "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden | grep -qx 'INVITATIONS_ALLOWED=false'"

  # ---- signup state, reported rather than assumed ----
  # Open signups are legitimate between the first deploy and the owner
  # registering, so this is a loud report, not a failure. It reads the running
  # container, not .env: .env can have been edited without a recreate.
  cenv="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden 2>/dev/null || true)"
  signups="$(printf '%s\n' "$cenv" | sed -n 's/^SIGNUPS_ALLOWED=//p' | head -1)"
  live_check "signup state is determinable" \
    sh -c "case '$signups' in true|false) exit 0;; *) exit 1;; esac"
  case "$signups" in
    false)
      green "    → signups are CLOSED on the running container (no new accounts)"
      ;;
    true)
      red   "    → signups are OPEN on the running container: anyone on this"
      red   "      tailnet can create an account. Expected only between the"
      red   "      first deploy and your registration. If you have registered:"
      red   "      cd $SERVICE_DIR && ./setup.sh"
      ;;
    *)
      red   "    → could not read SIGNUPS_ALLOWED from the container"
      ;;
  esac
  printf '    → .env says: %s\n' "$(grep '^VAULTWARDEN_SIGNUPS_ALLOWED=' "$SERVICE_DIR/.env" 2>/dev/null || echo '(missing)')"
  printf '    → backups: this box has none. %s is the only copy of every\n' \
    "$(sed -n 's/^VAULTWARDEN_DATA=//p' "$SERVICE_DIR/.env" 2>/dev/null)"
  printf '      password you own. See SETUP.md → Backups.\n'
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

data_dir() { sed -n 's/^VAULTWARDEN_DATA=//p' "$SVC/.env"; }

# A deployed sandbox: setup.sh has run, there is a vault on disk, Serve maps
# this port to this service, and neighbours sit on other ports (one a
# lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/attachments"
  echo vault > "$(data_dir)/db.sqlite3"
  echo key > "$(data_dir)/rsa_key.pem"
  echo blob > "$(data_dir)/attachments/a1"
  cat > "$STATE_DIR/serve_status" <<EOT
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8222 (tailnet only)
|-- / proxy http://127.0.0.1:8222

https://test-host.tailfake.ts.net:18222 (tailnet only)
|-- / proxy http://127.0.0.1:18222
EOT
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down" "$STATE_DIR/cleanup_run"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps the vault and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8222"         calls_have "tailscale serve --https=8222 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18222 untouched"  no_call "https=18222"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "down uses --project-directory" grep -q -- "--project-directory $SVC down" "$STATE_DIR/compose_cmds"
  check "vault kept"                  [ -f "$(data_dir)/db.sqlite3" ]
  check "rsa key kept"                [ -f "$(data_dir)/rsa_key.pem" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "signup state kept in .env"   env_has "^VAULTWARDEN_SIGNUPS_ALLOWED="
  check "no cleanup container"        [ ! -f "$STATE_DIR/cleanup_run" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
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
  printf 'https://test-host.tailfake.ts.net:8222 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: vault kept"       [ -f "$(data_dir)/db.sqlite3" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then the vault, .env and marker go"
  deployed
  local dir; dir="$(data_dir)"
  echo x > "$HOME/services/neighbour-keep"
  run_teardown --purge "Vaultwarden"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: vault kept"      [ -f "$dir/db.sqlite3" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge ""
  check "empty answer: exits non-zero" [ "$CODE" -ne 0 ]
  check "  vault kept"                [ -f "$dir/db.sqlite3" ]
  run_teardown --purge "vaultwarden"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warned there is no backup"   out_has "NOTHING BACKS THIS BOX UP"
  check "suggested an encrypted export" out_has "Export vault"
  check "vault data dir gone"         [ ! -e "$dir" ]
  check ".env gone (signup door resets)" [ ! -f "$SVC/.env" ]
  check "services/vaultwarden marker gone" [ ! -e "$HOME/services/vaultwarden" ]
  check "serve off for :8222"         calls_have "tailscale serve --https=8222 off"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "sibling file kept"           [ -f "$HOME/services/neighbour-keep" ]
  check "compose file kept"           [ -f "$SVC/docker-compose.yml" ]
  run_teardown --purge "vaultwarden"
  check "re-run with no .env refuses" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_marker_kept_if_not_empty() {
  echo "• teardown --purge: the marker is only rmdir'd when empty, never followed if a link"
  deployed
  echo mine > "$HOME/services/vaultwarden/cold-backup.tgz"
  run_teardown --purge "vaultwarden"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$HOME/services/vaultwarden/data" ]
  check "user file beside it kept"    [ -f "$HOME/services/vaultwarden/cold-backup.tgz" ]
  teardown
  deployed
  mkdir -p "$HOME/elsewhere"
  mv "$HOME/services/vaultwarden" "$HOME/elsewhere/vaultwarden"
  ln -s "$HOME/elsewhere/vaultwarden" "$HOME/services/vaultwarden"
  run_teardown --purge "vaultwarden"
  check "symlinked marker: purge refused" [ "$CODE" -ne 0 ]
  check "  link kept"                 [ -L "$HOME/services/vaultwarden" ]
  check "  vault behind it kept"      [ -f "$HOME/elsewhere/vaultwarden/data/db.sqlite3" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  rm -f "$HOME/services/vaultwarden"
  teardown
}

test_teardown_purge_root_owned() {
  echo "• teardown --purge: root-owned vault files are cleared by the pinned image, not sudo"
  deployed
  local dir; dir="$(data_dir)"
  # Stand-in for a root-owned file: a read-only dir the host user cannot empty.
  mkdir -p "$dir/sends/locked"; echo x > "$dir/sends/locked/f"
  chmod 500 "$dir/sends/locked"
  run_teardown --purge "vaultwarden"
  chmod -R u+rwX "$dir" 2>/dev/null
  if [ "$(id -u)" -ne 0 ]; then
    check "used the pinned image"     grep -q "vaultwarden/server:1.37.2" "$STATE_DIR/cleanup_run"
    check "never pulled for it"       grep -q -- "--pull never" "$STATE_DIR/cleanup_run"
    check "mounted the real data dir" grep -q -- "-v $dir:/data" "$STATE_DIR/cleanup_run"
  fi
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no sudo"                     no_call "^sudo"
  check "vault dir gone"              [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/vaultwarden" ]
  teardown
  if [ "$(id -u)" -ne 0 ]; then
    deployed
    dir="$(data_dir)"
    mkdir -p "$dir/sends/locked"; echo x > "$dir/sends/locked/f"
    chmod 500 "$dir/sends/locked"
    touch "$STATE_DIR/docker_run_fails"
    run_teardown --purge "vaultwarden"
    chmod -R u+rwX "$dir" 2>/dev/null
    check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
    check "  names the sudo command"  out_has "sudo rm -rf $dir"
    check "  .env kept for the retry" [ -f "$SVC/.env" ]
    teardown
  fi
  deployed
  sed -i.bak "s#^VAULTWARDEN_VERSION=.*#VAULTWARDEN_VERSION=1.36.0#" "$SVC/.env"
  dir="$(data_dir)"
  mkdir -p "$dir/sends/locked"; echo x > "$dir/sends/locked/f"
  chmod 500 "$dir/sends/locked"
  run_teardown --purge "vaultwarden"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "image tag follows VAULTWARDEN_VERSION" [ "$CODE" -eq 0 ]
  if [ "$(id -u)" -ne 0 ]; then
    check "  cleanup used :1.36.0"    grep -q "vaultwarden/server:1.36.0" "$STATE_DIR/cleanup_run"
  fi
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./vaultwarden" "$HOME/services/vaultwarden/.." "$HOME/services/vaultwarden/data/.."; do
    sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "vaultwarden"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "vault never touched"         [ -f "$HOME/services/vaultwarden/data/db.sqlite3" ]
  check "never stopped"               [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOT
https://test-host.tailfake.ts.net:8223 (tailnet only)
|-- / proxy http://127.0.0.1:8222

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8222

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /vault proxy http://127.0.0.1:8222
EOT
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8223 off"                   calls_have "serve --https=8223 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8222 (left on, see above); 2 port(s) unpublished"
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
  run_teardown --purge "vaultwarden"
  check "purge: exits non-zero"       [ "$CODE" -ne 0 ]
  check "purge: vault kept"           [ -f "$(data_dir)/db.sqlite3" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8222'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8222 off"                   calls_have "serve --https=8222 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8222"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check ":8222 off"                   calls_have "serve --https=8222 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8222 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
  deployed
  # The documented admin-panel recipe: a single-quoted argon2 PHC string full
  # of '$'. It must not trip the lint, and it goes with .env on --purge.
  printf "VAULTWARDEN_ADMIN_TOKEN='\$argon2id\$v=19\$m=65540,t=3,p=4\$c2FsdA\$aGFzaA'\n" >> "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "admin token line accepted"   [ "$CODE" -eq 0 ]
  check "  and deleted with .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "vaultwarden"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  ln -s "$HOME/services/neighbour" "$HOME/services/vaultwarden/linked"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/vaultwarden/linked#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "symlinked leaf inside own dir refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  rm -f "$HOME/services/vaultwarden/linked"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/vaultwarden/data///#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  vault gone"                [ ! -e "$HOME/services/vaultwarden/data" ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine, marker still goes"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "vaultwarden"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/vaultwarden" ]
  check "no cleanup container"        [ ! -f "$STATE_DIR/cleanup_run" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=\$HOME${dir#"$HOME"}#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "unquoted \$HOME form: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -f "$dir/db.sqlite3" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/vaultwarden itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/vaultwarden-old"; echo x > "$HOME/services/vaultwarden-old/keep"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/vaultwarden-old#" "$SVC/.env"
  run_teardown --purge "vaultwarden"
  check "prefix lookalike dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/vaultwarden-old/keep" ]
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/vaultwarden/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/vaultwarden/a:b"
  run_teardown --purge "vaultwarden"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  check "vault never touched"         [ -f "$HOME/services/vaultwarden/data/db.sqlite3" ]
  teardown
  deployed
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$HOME/services/vaultwarden#" "$SVC/.env"
  echo x > "$HOME/services/vaultwarden/extra"
  run_teardown --purge "vaultwarden"
  check "services/vaultwarden itself accepted" [ "$CODE" -eq 0 ]
  check "  it is gone"                [ ! -e "$HOME/services/vaultwarden" ]
  check "  ~/services kept"           [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/vaultwarden/data"; echo x > "$HOME/vaultwarden/data/keep"
  run_teardown --purge "vaultwarden"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/vaultwarden/data/keep" ]
  check "moved vault untouched"       [ -f "$HOME/real-services/vaultwarden/data/db.sqlite3" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'VAULTWARDEN_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "VAULTWARDEN_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nVAULTWARDEN_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  run_teardown --purge "vaultwarden"
  check "garbage line: exits non-zero" [ "$CODE" -ne 0 ]
  check "  vault kept"                [ -f "$(data_dir)/db.sqlite3" ]
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/vaultwarden/setup.sh or services/vaultwarden/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"

# VAULTWARDEN_DATA under a folder this user cannot search (a root-owned 0700
# storage/, faked with chmod 000): `[ -e ]` cannot see the vault, which must
# not read as "already gone" while .env is deleted. The pinned image mounts
# that folder and deletes only the path below it.
hide_vault_under_storage() {
  local st="$HOME/services/vaultwarden/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
}
unhide_storage() { chmod -R u+rwX "$HOME/services/vaultwarden" 2>/dev/null; }

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: a vault behind an unsearchable folder is deleted, not taken as gone"
  local st
  deployed
  st="$HOME/services/vaultwarden/storage"
  hide_vault_under_storage
  run_teardown --purge "vaultwarden"
  unhide_storage
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "mounted the unsearchable folder" grep -q -- "-v $st:/x" "$STATE_DIR/cleanup_run"
  check "used the pinned image"       grep -q "vaultwarden/server:1.37.2" "$STATE_DIR/cleanup_run"
  check "no sudo"                     no_call "^sudo"
  check "vault gone"                  [ ! -e "$st/data" ]
  check "emptied folder gone"         [ ! -e "$st" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir removed"           [ ! -e "$HOME/services/vaultwarden" ]
  teardown
  deployed
  st="$HOME/services/vaultwarden/storage"
  hide_vault_under_storage
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "vaultwarden"
  unhide_storage
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/data"
  check "  never says deleted"        out_lacks "Deleted"
  check "  vault kept"                [ -f "$st/data/db.sqlite3" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  st="$HOME/services/vaultwarden/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/data"
  sed -i.bak "s#^VAULTWARDEN_DATA=.*#VAULTWARDEN_DATA=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "vaultwarden"
  unhide_storage
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # ~/services/vaultwarden itself unsearchable: not strictly inside it, so
  # no mount; stop before anything changes and name the sudo command.
  deployed
  chmod 000 "$HOME/services/vaultwarden"
  run_teardown --purge "vaultwarden"
  unhide_storage
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  no cleanup container"      [ ! -f "$STATE_DIR/cleanup_run" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  vault kept"                [ -f "$(data_dir)/db.sqlite3" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOT
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /vault proxy http://127.0.0.1:8222
EOT
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    out_lacks "already off"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8222 (left on, see above); 0 port(s) unpublished"
  teardown
}

test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_no_python3
test_fresh_deploy
test_readiness_retry
test_rerun_zero_users_stays_open
test_rerun_locks_signups
test_rerun_already_closed_is_noop
test_env_never_overwritten
test_count_unknown
test_count_falls_back_to_docker_cp
test_admin_token_on_container
test_inspect_blind
test_domain_drift
test_server_reports_wrong_domain
test_port_override
test_https_port_follows_local_port
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_marker_kept_if_not_empty
test_teardown_purge_root_owned
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
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports

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
