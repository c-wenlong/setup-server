#!/usr/bin/env bash
#
# Tests for services/jellyfin/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with PATH stubs for docker/tailscale/curl/sudo/id/sleep. The curl stub fakes
# the whole Jellyfin surface — /System/Info/Public, the four /Startup/* wizard
# steps (recording their order and bodies), /Users/Public returning [] the way
# the real server does, and /Users/AuthenticateByName — so the wizard is driven
# for real rather than mocked out.
#
# The case this suite exists for is `test_readiness_race`. Jellyfin answers
# /System/Info/Public with 200 while it is still loading and 503s /Startup/*
# for that same window; a deploy that gates on the wrong endpoint POSTs the
# wizard into those 503s and finishes with StartupWizardCompleted=true and NO
# admin account — a deploy that looks perfect and cannot be logged into.

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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" \
     "$SERVICE_DIR/docker-compose.gpu.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT JELLYFIN_ADMIN_USERNAME JELLYFIN_NVENC MEDIA_DIR \
        STATE_DIR CALLS_LOG
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
calls_lack() { ! grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env"; }

# 1-based line number of the first matching call, for ordering assertions.
first_call() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1; }

# The wizard steps the script POSTed, in order, space-separated.
wizard_order() { tr '\n' ' ' < "$STATE_DIR/wizard_steps" 2>/dev/null; }
# The JSON body of one wizard step, e.g. body_has User '"Name":"admin"'.
body_has()     { grep -qF -- "$2" "$STATE_DIR/body_$1" 2>/dev/null; }
auth_body_has(){ grep -qF -- "$1" "$STATE_DIR/auth_body" 2>/dev/null; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped — the file
# documents at length what it deliberately does NOT do ("upstream binds
# 0.0.0.0:8096", the commented-out NVENC block, the DLNA ports it omits), so a
# naive grep would match the prose instead of the config.
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
  export LOCAL_PORT=80o6
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_bad_username() {
  echo "• preflight rejects an admin username that would break the JSON body"
  # The username is interpolated into {"Name":"..."} with printf, not escaped.
  setup
  export JELLYFIN_ADMIN_USERNAME='admin" ,"x'
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "names the allowed set"  out_has "A-Za-z0-9._-"
  check "wrote no .env"          [ ! -f "$SVC/.env" ]
  check "ran no wizard step"     [ ! -f "$STATE_DIR/wizard_steps" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: wizard driven end to end, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]

  # --- .env
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has a hex admin password"  grep -qE '^JELLYFIN_ADMIN_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env names the admin user"      grep -qE '^JELLYFIN_ADMIN_USERNAME=.+$' "$SVC/.env"
  check ".env records the local port"    grep -qx 'LOCAL_PORT=8096' "$SVC/.env"
  check "pinned to 12.0, not latest"     grep -qx 'JELLYFIN_VERSION=12.0' "$SVC/.env"
  check ".env has JELLYFIN_CONFIG"       grep -qE '^JELLYFIN_CONFIG=/.+' "$SVC/.env"
  check ".env has JELLYFIN_CACHE"        grep -qE '^JELLYFIN_CACHE=/.+' "$SVC/.env"
  check ".env has MEDIA_DIR"             grep -qE '^MEDIA_DIR=/.+' "$SVC/.env"
  check ".env has UID/GID for the mount" grep -qE '^JELLYFIN_UID=[0-9]+$' "$SVC/.env"
  # PublishedServerUrl is what Jellyfin hands clients to stream from; a wrong
  # value produces working-but-unusable localhost links, not an error.
  check "published URL is the tailnet URL" \
    grep -qx 'JELLYFIN_PUBLISHED_URL=https://test-host.tailfake.ts.net:8096' "$SVC/.env"

  # --- compose, statically
  check "compose binds loopback only"    compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose binds no wildcard"      no_wildcard_bind
  check "media mounted read-only"        compose_hasF ':/media:ro'
  check "image pinned from .env"         compose_hasF 'image: jellyfin/jellyfin:${JELLYFIN_VERSION'
  check "restart policy unless-stopped"  compose_has 'restart: *unless-stopped'
  check "advertises PublishedServerUrl"  compose_has 'JELLYFIN_PublishedServerUrl'
  check "no DLNA discovery port 1900"    compose_lacks '1900'
  check "no client-discovery port 7359"  compose_lacks '7359'
  check "no network_mode: host"          compose_lacks 'network_mode'
  # The GPU reservation belongs in docker-compose.gpu.yml, never the base file.
  # It is only valid once dockerd has the nvidia runtime; in the base file it
  # would make the container unstartable on every box that lacks one.
  check "no GPU reservation in base"     compose_lacks 'driver: *nvidia'
  check "  no GPU overlay by default"    calls_lack "docker-compose.gpu.yml"

  # --- state + deploy
  check "config dir created"             [ -d "$(env_val JELLYFIN_CONFIG)" ]
  check "cache dir created"              [ -d "$(env_val JELLYFIN_CACHE)" ]
  check "media dir created"              [ -d "$(env_val MEDIA_DIR)" ]
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]

  # --- readiness: the gate is /Startup/FirstUser, and it comes FIRST
  check "polled /Startup/FirstUser"      calls_have "/Startup/FirstUser"
  check "  before POSTing the wizard"    [ "$(first_call '/Startup/FirstUser')" -lt "$(first_call '/Startup/Configuration')" ]

  # --- the wizard itself
  check "ran all four wizard steps in order" \
    [ "$(wizard_order)" = "Configuration User RemoteAccess Complete " ]
  check "  Configuration set the locale" body_has Configuration '"UICulture"'
  check "  User body carries the name"   body_has User "\"Name\":\"$(env_val JELLYFIN_ADMIN_USERNAME)\""
  check "  User body carries the .env password" \
    body_has User "\"Password\":\"$(env_val JELLYFIN_ADMIN_PASSWORD)\""
  # UPnP would ask the router to punch a hole to 8096 from the internet,
  # silently undoing the entire tailnet boundary. It must be off.
  check "  RemoteAccess disables UPnP"   body_has RemoteAccess '"EnableAutomaticPortMapping":false'
  check "  wizard marked complete"       body_has Complete '{}'
  check "wizard marker written"          [ -f "$HOME/services/jellyfin/.wizard-complete" ]
  check "  marker names the admin"       grep -qx "$(env_val JELLYFIN_ADMIN_USERNAME)" "$HOME/services/jellyfin/.wizard-complete"

  # /Users/Public returns [] even on a fully successful setup — it lists only
  # login-screen-visible users. Anything that treats it as a success check
  # reports a working deploy as broken.
  check "never used /Users/Public as a check" no_call "/Users/Public"

  # --- publish
  check "served on tailscale :8096"      calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  check "no sudo needed (operator set)"  no_call "^sudo "

  # --- verification is a real login, not a health ping
  check "authenticated to verify"        calls_have "/Users/AuthenticateByName"
  check "  over the tailnet HTTPS URL"   calls_have "https://test-host.tailfake.ts.net:8096/Users/AuthenticateByName"
  check "  sent the MediaBrowser header" calls_have "MediaBrowser Client="
  check "  used the .env password"       auth_body_has "\"Pw\":\"$(env_val JELLYFIN_ADMIN_PASSWORD)\""
  check "  confirmed admin rights"       out_has "account is an administrator"
  check "  confirmed the advertised URL" out_has "told to stream from https://test-host.tailfake.ts.net:8096"

  # --- final message
  check "prints final URL"               out_has "https://test-host.tailfake.ts.net:8096"
  check "warns the library is empty"     out_has "library is EMPTY"
  check "  says where media goes"        out_has "MEDIA_DIR"
  check "  explains the /media mount"    out_has "/media"
  check "says transcoding is software"   out_has "software"
  check "  points at the GPU opt-in"     out_has "enable-nvenc.sh"
  check "  defaults the flag to off"     [ "$(env_val JELLYFIN_NVENC)" = "off" ]
  check "warns there is no backup here"  out_has "backup"
  teardown
}

test_readiness_race() {
  echo "• readiness race: /Startup/* 503s while loading — must keep polling"
  # This is the whole reason the readiness gate is /Startup/FirstUser and not
  # /System/Info/Public. The stub refuses the connection twice (container not
  # listening), then 503s the next four /Startup/* calls (listening, still
  # loading). A script that proceeded on the first HTTP answer would POST
  # /Startup/User into a 503 and end up with a completed wizard and no admin.
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/conn_refused_left"
  echo 4 > "$STATE_DIR/startup_503_left"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  # 2 refusals + 4 x 503 + 1 success = 7 polls of the readiness endpoint.
  check "polled FirstUser until it stopped 503ing" \
    [ "$(call_count '/Startup/FirstUser')" -eq 7 ]
  check "  waited between polls"         [ "$(call_count '^sleep ')" -eq 6 ]
  # The critical assertion: no wizard step was POSTed during the 503 window.
  check "POSTed no wizard step while loading" \
    [ "$(wizard_order)" = "Configuration User RemoteAccess Complete " ]
  check "  the admin step really ran"    body_has User '"Password"'
  check "still published"                calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  check "still verified the login"       out_has "account is an administrator"
  teardown
}

test_never_ready() {
  echo "• server never finishes loading: dies before touching the wizard"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/startup_503_left"   # more 503s than the loop has tries
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "says it never loaded"     out_has "never finished loading"
  check "gave up after 90 tries"   [ "$(call_count '/Startup/FirstUser')" -eq 90 ]
  check "POSTed no wizard step"    [ ! -f "$STATE_DIR/wizard_steps" ]
  check "wrote no wizard marker"   [ ! -f "$HOME/services/jellyfin/.wizard-complete" ]
  check "published nothing"        no_call "tailscale serve"
  teardown
}

test_wizard_step_fails() {
  echo "• a wizard step fails: fatal, marker withheld, nothing published"
  setup
  touch "$STATE_DIR/operator"
  echo "User 500" > "$STATE_DIR/fail_step"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the failing step"     out_has "Admin account created"
  check "says the wizard is half-applied" out_has "half-applied"
  check "stopped at the failed step" [ "$(wizard_order)" = "Configuration User " ]
  check "wrote no wizard marker"     [ ! -f "$HOME/services/jellyfin/.wizard-complete" ]
  check "published nothing"          no_call "tailscale serve"
  teardown
}

test_wizard_step_503() {
  echo "• server drops back to loading mid-wizard: a distinct, resumable error"
  setup
  touch "$STATE_DIR/operator"
  echo "RemoteAccess 503" > "$STATE_DIR/fail_step"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "calls out the 503"         out_has "went back to loading mid-wizard"
  check "tells you to re-run"       out_has "Re-run setup.sh"
  check "wrote no wizard marker"    [ ! -f "$HOME/services/jellyfin/.wizard-complete" ]
  teardown
}

test_wizard_says_incomplete() {
  echo "• all four steps 204 but the flag never flips: caught, not celebrated"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/wizard_never_completes"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the contradiction"  out_has "StartupWizardCompleted=false"
  check "ran all four steps first" [ "$(wizard_order)" = "Configuration User RemoteAccess Complete " ]
  check "wrote no wizard marker"   [ ! -f "$HOME/services/jellyfin/.wizard-complete" ]
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, wizard not re-run"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(env_val JELLYFIN_ADMIN_PASSWORD)"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "password unchanged"          [ "$(env_val JELLYFIN_ADMIN_PASSWORD)" = "$pw" ]
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "wizard NOT re-run"           no_call "/Startup/Configuration"
  check "  still exactly four steps"  [ "$(wizard_order)" = "Configuration User RemoteAccess Complete " ]
  check "says the wizard is done"     out_has "already completed"
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  check "re-verified the login"       out_has "account is an administrator"
  teardown
}

test_marker_lost_but_wizard_done() {
  echo "• marker lost, server already set up: recovers instead of re-wizarding"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                          # first deploy
  rm -f "$HOME/services/jellyfin/.wizard-complete"    # e.g. a run that died
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "asked the server"           calls_have "/System/Info/Public"
  check "trusted StartupWizardCompleted" out_has "already complete"
  check "wizard NOT re-run"          no_call "/Startup/Configuration"
  check "  still exactly four steps" [ "$(wizard_order)" = "Configuration User RemoteAccess Complete " ]
  check "marker rewritten"           [ -f "$HOME/services/jellyfin/.wizard-complete" ]
  check "still published"            calls_have "tailscale serve --bg --https=8096"
  teardown
}

test_stale_marker() {
  echo "• stale marker over a wiped config: named, not misdiagnosed"
  # The hazard: someone deletes ~/services/jellyfin/config to start over but
  # leaves .wizard-complete behind. The server is back at first-run with no
  # users, so trusting the marker would surface much later as "login
  # rejected" — blaming the password instead of the wipe. The marker is a
  # cache, and the live StartupWizardCompleted flag is the truth.
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/jellyfin"
  echo admin > "$HOME/services/jellyfin/.wizard-complete"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "cross-checked the server"   calls_have "/System/Info/Public"
  check "names the stale marker"     out_has "Stale marker"
  check "  explains the real cause"  out_has "deleted or replaced"
  check "  gives the exact fix"      out_has "rm $HOME/services/jellyfin/.wizard-complete"
  check "did not blame the password" out_lacks "was rejected"
  check "ran no wizard step"         [ ! -f "$STATE_DIR/wizard_steps" ]
  check "published nothing"          no_call "tailscale serve"
  teardown
}

test_password_drift() {
  echo "• password changed in the UI: the deploy fails loudly instead of lying"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/login_rejected"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the rejected login" out_has "was rejected"
  check "names the mismatch"       out_has "does not match the server"
  check "says how to fix it"       out_has "Dashboard"
  check "published before dying"   calls_have "tailscale serve --bg --https=8096"
  teardown
}

test_not_an_admin() {
  echo "• the account authenticates but is not an admin: also fatal"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/not_admin"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the problem"       out_has "not an administrator"
  check "did not claim success"   out_lacks "account is an administrator"
  teardown
}

test_wrong_published_url() {
  echo "• server advertises the wrong address: warned, not silently accepted"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/wrong_published_url"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns about the address"    out_has "advertising an address that is not"
  check "points at the .env key"     out_has "JELLYFIN_PUBLISHED_URL"
  check "still prints the URL"       out_has "https://test-host.tailfake.ts.net:8096"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8097 HTTPS_PORT=8097
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8097' "$SVC/.env"
  check "published URL uses it"      grep -qx 'JELLYFIN_PUBLISHED_URL=https://test-host.tailfake.ts.net:8097' "$SVC/.env"
  check "polled :8097 for readiness" calls_have "127.0.0.1:8097/Startup/FirstUser"
  check "served :8097 -> :8097"      calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "prints the :8097 URL"       out_has "https://test-host.tailfake.ts.net:8097"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under its library database.
  export LOCAL_PORT=8098 HTTPS_PORT=8097
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8098 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8097' "$SVC/.env"
  check "re-run: still serves :8097" calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "re-run: never touched 8098" no_call "127.0.0.1:8098"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (8096) next to a LOCAL_PORT
  # override silently published :8096 -> 127.0.0.1:8097, i.e. the wrong port.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8097
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=8097"   grep -qx 'LOCAL_PORT=8097' "$SVC/.env"
  check "served :8097 -> 127.0.0.1:8097" calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "  and never :8096"              no_call "tailscale serve --bg --https=8096"
  check "prints the :8097 URL"           out_has "https://test-host.tailfake.ts.net:8097"
  # Re-run with no override at all: .env says 8097, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 8096.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8097 -> 127.0.0.1:8097" calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "  and never :8096"                   no_call "tailscale serve --bg --https=8096"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8097 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8097" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8097"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_published_url_drift() {
  echo "• the tailnet URL moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                    # first deploy on :8096
  old="$(grep '^JELLYFIN_PUBLISHED_URL=' "$SVC/.env")"
  export HTTPS_PORT=8097                        # published somewhere else now
  run_deploy
  check "warns about the drift"     out_has "JELLYFIN_PUBLISHED_URL in .env is"
  check "spells out the fix"        out_has "JELLYFIN_PUBLISHED_URL=https://test-host.tailfake.ts.net:8097"
  check ".env left alone (user's)"  [ "$(grep '^JELLYFIN_PUBLISHED_URL=' "$SVC/.env")" = "$old" ]
  teardown
}

test_media_dir_override() {
  echo "• MEDIA_DIR override: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export MEDIA_DIR="$SANDBOX/library"
  mkdir -p "$MEDIA_DIR"
  touch "$MEDIA_DIR/Blade Runner (1982).mkv"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env records the override"   [ "$(env_val MEDIA_DIR)" = "$SANDBOX/library" ]
  check "did not create the default"  [ ! -d "$HOME/services/jellyfin/media" ]
  check "found the media there"       out_has "1 entries under $SANDBOX/library"

  # .env is the source of truth once it exists: a re-run must not repoint a
  # live library at a different directory and silently "lose" everything.
  export MEDIA_DIR="$SANDBOX/elsewhere"
  run_deploy
  check "re-run: exits zero"          [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it"  out_has "MEDIA_DIR=$SANDBOX/elsewhere ignored"
  check "re-run: .env unchanged"      [ "$(env_val MEDIA_DIR)" = "$SANDBOX/library" ]
  check "re-run: created nothing new" [ ! -d "$SANDBOX/elsewhere" ]
  unset MEDIA_DIR
  teardown
}

test_media_present() {
  echo "• media already in place: reports the count instead of the empty note"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/jellyfin/media"
  touch "$HOME/services/jellyfin/media/Blade Runner (1982).mkv"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "counts what is there"        out_has "1 entries under"
  check "no empty-library warning"    out_lacks "library is EMPTY"
  check "still explains /media"       out_has "/media"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=8096 http://127.0.0.1:8096"
  teardown
}

test_nvenc_without_runtime() {
  echo "• JELLYFIN_NVENC=on with no nvidia runtime: refuses, does not start a doomed container"
  # The whole point of the guard. Compose would fail here with 'could not
  # select device driver "nvidia" with capabilities: [[gpu]]', which reads
  # like a Jellyfin fault and is really a missing host package — and it would
  # take the running container down on the way. Catch it before `up`.
  setup
  touch "$STATE_DIR/operator"
  export JELLYFIN_NVENC=on
  run_deploy
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the real cause"        out_has "nvidia-container-toolkit"
  check "points at enable-nvenc.sh"   out_has "enable-nvenc.sh"
  check "offers the off switch"       out_has "JELLYFIN_NVENC=off"
  check "started no container"        [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_nvenc_on() {
  echo "• JELLYFIN_NVENC=on with the runtime present: layers the GPU overlay"
  setup
  touch "$STATE_DIR/operator"
  touch "$STATE_DIR/nvidia_runtime"
  export JELLYFIN_NVENC=on
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "layered the GPU overlay"     calls_have "docker-compose.gpu.yml"
  check "kept the base compose too"   calls_have "-f $SVC/docker-compose.yml"
  check "started the container"       [ -f "$STATE_DIR/compose_up" ]
  check "persisted the flag to .env"  [ "$(env_val JELLYFIN_NVENC)" = "on" ]
  check "says the GPU is in use"      out_has "NVENC"
  check "reminds to enable in the UI" out_has "Dashboard -> Playback"
  teardown
}

test_nvenc_off_overrides_env() {
  echo "• JELLYFIN_NVENC=off overrides an .env that says on (the reversal path)"
  # Regression guard: .env is sourced after the flag is read, so a naive
  # implementation lets the file win and the 'off' request does nothing.
  setup
  touch "$STATE_DIR/operator"
  touch "$STATE_DIR/nvidia_runtime"
  export JELLYFIN_NVENC=on
  run_deploy
  check "first run: on"               [ "$(env_val JELLYFIN_NVENC)" = "on" ]
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_up"
  export JELLYFIN_NVENC=off
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "flag flipped back in .env"   [ "$(env_val JELLYFIN_NVENC)" = "off" ]
  check "overlay no longer layered"   calls_lack "docker-compose.gpu.yml"
  check "restarted without the GPU"   [ -f "$STATE_DIR/compose_up" ]
  check "admin password preserved"    [ -n "$(env_val JELLYFIN_ADMIN_PASSWORD)" ]
  teardown
}

test_wizard_race_on_restart() {
  echo "• restart race: StartupWizardCompleted reads false for a while — must not cry 'wiped'"
  # Observed for real on 2026-09-11 while restarting the container to attach
  # the GPU. The auth layer 401s /Startup/FirstUser (so the readiness gate
  # passes) seconds before the config carrying StartupWizardCompleted loads,
  # so a healthy server briefly reports false. Believing one sample made
  # setup.sh announce the config directory was wiped and advise deleting the
  # wizard marker — against a live server with a real library on it.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first deploy ok"           [ "$CODE" -eq 0 ]
  echo 3 > "$STATE_DIR/wizard_false_left"
  rm -f "$STATE_DIR/compose_up"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "did not claim a wipe"      out_lacks "Stale marker"
  check "treated it as complete"    out_has "already completed"
  check "restarted the container"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_wizard_genuinely_wiped() {
  echo "• config really wiped: still fails, but without the reckless advice"
  # The other side of the retry: a reading that never settles must still be
  # reported, and the message must not send the user to delete a marker on a
  # server whose data is actually fine.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first deploy ok"           [ "$CODE" -eq 0 ]
  echo 999 > "$STATE_DIR/wizard_false_left"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the stale marker"    out_has "Stale marker"
  check "says it waited it out"     out_has "30s"
  check "says how to confirm first" out_has "jellyfin.db"
  check "warns against a blind rm"  out_has "do NOT delete the marker"
  teardown
}

test_nvenc_env_predates_flag() {
  echo "• .env written before JELLYFIN_NVENC existed: the flag must still be recorded"
  # The real box's .env was generated before this flag was added, so sourcing
  # it could not clear the caller's own JELLYFIN_NVENC=on — the value matched
  # $NVENC_MODE and the line was never written. Result on 2026-09-11: the GPU
  # was attached and running while .env carried no flag at all, so the next
  # plain ./setup.sh would have quietly reverted to software transcoding.
  setup
  touch "$STATE_DIR/operator"
  touch "$STATE_DIR/nvidia_runtime"
  run_deploy
  check "first deploy ok"           [ "$CODE" -eq 0 ]

  # Strip the line the way history did. Rewrite in place to keep mode 600.
  grep -v '^JELLYFIN_NVENC=' "$SVC/.env" > "$SANDBOX/env.strip"
  cat "$SANDBOX/env.strip" > "$SVC/.env"
  check "flag really absent now"    [ -z "$(env_val JELLYFIN_NVENC)" ]

  export JELLYFIN_NVENC=on
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "appended the flag as on"   [ "$(env_val JELLYFIN_NVENC)" = "on" ]
  check "layered the GPU overlay"   calls_have "docker-compose.gpu.yml"

  # The consequence that matters: a later run with no flag in the environment
  # must stay on the GPU rather than silently dropping to software.
  unset JELLYFIN_NVENC
  : > "$CALLS_LOG"
  run_deploy
  check "plain re-run stays on"     [ "$(env_val JELLYFIN_NVENC)" = "on" ]
  check "  overlay still layered"   calls_have "docker-compose.gpu.yml"
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
# (8096 -> 8096), so tailscaled legitimately listens on the tailnet IP for
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
  local ts port https_port url user pass auth
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  user="$(sed -n 's/^JELLYFIN_ADMIN_USERNAME=//p' "$SERVICE_DIR/.env")"
  pass="$(sed -n 's/^JELLYFIN_ADMIN_PASSWORD=//p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  # Jellyfin rejects /Users/AuthenticateByName without a client identity.
  auth='Authorization: MediaBrowser Client="tests", Device="tests", DeviceId="run-tests", Version="1.0"'

  live_check "jellyfin container running" sh -c "docker inspect -f '{{.State.Status}}' jellyfin | grep -qx running"
  live_check "local /System/Info/Public responds" \
    sh -c "curl -fsS 'http://127.0.0.1:$port/System/Info/Public' | grep -q '\"ProductName\"'"

  # A deploy that left the wizard unfinished is a failed deploy that looks
  # fine: the container is healthy, the page loads, and /Startup/* still
  # accepts unauthenticated writes from anyone on the tailnet — including
  # "create the first user".
  live_check "startup wizard is completed" \
    sh -c "curl -fsS 'http://127.0.0.1:$port/System/Info/Public' | tr -d ' ' | grep -qi '\"StartupWizardCompleted\":true'"

  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds" \
    curl -fsS -o /dev/null --max-time 30 "$url:$https_port/System/Info/Public"

  # PublishedServerUrl is what clients are told to stream from. Wrong, and
  # playback fails on every device except this box, with nothing in the logs.
  live_check "advertises the tailnet URL to clients" \
    sh -c "curl -fsS --max-time 30 '$url:$https_port/System/Info/Public' \
           | tr -d ' ' | grep -qF '\"LocalAddress\":\"$url:$https_port\"'"

  # The credentials in .env have to be the ones that actually work, and the
  # account has to be an admin. This is the check that catches the readiness
  # race: a completed wizard whose /Startup/User call was swallowed by a 503
  # passes everything above and fails here.
  live_check "admin credentials in .env authenticate" \
    sh -c "curl -fsS --max-time 30 -X POST '$url:$https_port/Users/AuthenticateByName' \
             -H 'Content-Type: application/json' -H '$auth' \
             -d '{\"Username\":\"$user\",\"Pw\":\"$pass\"}' \
           | tr -d ' ' | grep -qi '\"IsAdministrator\":true'"

  live_check "media dir exists" \
    sh -c "test -d \"\$(sed -n 's/^MEDIA_DIR=//p' '$SERVICE_DIR/.env')\""
  live_check "running the pinned 12.x line" \
    sh -c "curl -fsS --max-time 30 'http://127.0.0.1:$port/System/Info/Public' | grep -q '\"Version\":\"12'"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# and neighbours sit on other ports (one a lookalike suffix). State files are
# planted in config, cache and the wizard marker's directory.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  seed_state
}

seed_state() {
  local st="$HOME/services/jellyfin"
  mkdir -p "$st/config/data" "$st/cache" "$(env_val MEDIA_DIR)"
  echo keep > "$st/config/data/jellyfin.db"
  echo keep > "$st/cache/img.jpg"
  echo film > "$(env_val MEDIA_DIR)/film.mkv"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8096 (tailnet only)
|-- / proxy http://127.0.0.1:8096

https://test-host.tailfake.ts.net:8103 (tailnet only)
|-- / proxy http://127.0.0.1:8103

https://test-host.tailfake.ts.net:18096 (tailnet only)
|-- / proxy http://127.0.0.1:18096
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps everything on disk, unpublishes only its port"
  deployed
  local st="$HOME/services/jellyfin"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8096"         calls_have "tailscale serve --https=8096 off"
  check "neighbour :8103 untouched"   no_call "https=8103"
  check "lookalike :18096 untouched"  no_call "https=18096"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no GPU overlay when off"     no_call "docker-compose.gpu.yml"
  check "config kept"                 [ -f "$st/config/data/jellyfin.db" ]
  check "cache kept"                  [ -f "$st/cache/img.jpg" ]
  check "wizard marker kept"          [ -f "$st/.wizard-complete" ]
  check "media kept"                  [ -f "$(env_val MEDIA_DIR)/film.mkv" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
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
  printf 'https://test-host.tailfake.ts.net:8096 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8096

https://test-host.tailfake.ts.net (tailnet only)
|-- /      proxy http://127.0.0.1:8080
|-- /jelly proxy http://127.0.0.1:8096

https://test-host.tailfake.ts.net:8096 (tailnet only)
|-- / proxy http://127.0.0.1:8096
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "second port :8110 off"       calls_have "tailscale serve --https=8110 off"
  check "own port :8096 off"          calls_have "tailscale serve --https=8096 off"
  check "shared :443 left alone"      no_call "https=443"
  check "warns about shared port"     out_has "also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8096 (left on, see above); 2 port(s) unpublished"
  teardown
}

test_teardown_serve_unreadable() {
  echo "• teardown: unreadable Serve status stops before changing anything"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "explains"                    out_has "Could not read Tailscale Serve status"
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "no serve off"                no_call " off"
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
  echo "• teardown --purge: typed confirmation, then state and .env go, media stays"
  deployed
  local st="$HOME/services/jellyfin" media; media="$(env_val MEDIA_DIR)"
  run_teardown --purge "jelly"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: config kept"     [ -f "$st/config/data/jellyfin.db" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "jellyfin"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "config gone"                 [ ! -e "$st/config" ]
  check "cache gone"                  [ ! -e "$st/cache" ]
  check "wizard marker gone"          [ ! -e "$st/.wizard-complete" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "media survives (inside state root)" [ -f "$media/film.mkv" ]
  check "marker kept while media is in it" [ -d "$st" ]
  check "serve off for :8096"         calls_have "tailscale serve --https=8096 off"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_media_outside() {
  echo "• teardown --purge: media outside ~/services survives"
  setup
  touch "$STATE_DIR/operator"
  export MEDIA_DIR="$SANDBOX/disk/media"
  mkdir -p "$MEDIA_DIR"
  run_deploy
  seed_state
  run_teardown --purge "jellyfin"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "config gone"                 [ ! -e "$HOME/services/jellyfin/config" ]
  check "media survives"              [ -f "$SANDBOX/disk/media/film.mkv" ]
  check "empty marker dir removed"    [ ! -e "$HOME/services/jellyfin" ]
  teardown
}

test_teardown_purge_media_beside_state() {
  echo "• teardown --purge: MEDIA_DIR is the state root itself; only config/cache go"
  setup
  touch "$STATE_DIR/operator"
  export MEDIA_DIR="$HOME/services/jellyfin"
  run_deploy
  seed_state
  run_teardown --purge "jellyfin"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "config gone"                 [ ! -e "$HOME/services/jellyfin/config" ]
  check "cache gone"                  [ ! -e "$HOME/services/jellyfin/cache" ]
  check "media root kept"             [ -d "$HOME/services/jellyfin" ]
  check "media file kept"             [ -f "$HOME/services/jellyfin/film.mkv" ]
  teardown
}

test_teardown_purge_refuses_parent_of_media() {
  echo "• teardown --purge: refuses a state dir that contains the media"
  deployed
  local st="$HOME/services/jellyfin" media; media="$(env_val MEDIA_DIR)"
  sed -i.bak "s#^JELLYFIN_CONFIG=.*#JELLYFIN_CONFIG=$st#" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "explains the library rule"   out_has "contains your media library"
  check "media untouched"             [ -f "$media/film.mkv" ]
  check "config untouched"            [ -f "$st/config/data/jellyfin.db" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "serve untouched"             no_call " off"
  check ".env kept"                   [ -f "$SVC/.env" ]
  # A symlink to a parent of the media is caught by the real-path comparison.
  ln -s "$st" "$HOME/services/link"
  sed -i.bak "s#^JELLYFIN_CONFIG=.*#JELLYFIN_CONFIG=$HOME/services/link#" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "symlinked parent refused"    [ "$CODE" -ne 0 ]
  check "media still untouched"       [ -f "$media/film.mkv" ]
  # No MEDIA_DIR in .env: no way to prove anything is safe.
  sed -i.bak "s#^JELLYFIN_CONFIG=.*#JELLYFIN_CONFIG=$st/config#; /^MEDIA_DIR=/d" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "missing MEDIA_DIR refused"   [ "$CODE" -ne 0 ]
  check "config untouched again"      [ -f "$st/config/data/jellyfin.db" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses state dirs outside ~/services"
  deployed
  sed -i.bak "s#^JELLYFIN_CACHE=.*#JELLYFIN_CACHE=$HOME#" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^JELLYFIN_CACHE=.*#JELLYFIN_CACHE=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^JELLYFIN_CACHE=.*#JELLYFIN_CACHE=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "jellyfin"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  check "config untouched"            [ -f "$HOME/services/jellyfin/config/data/jellyfin.db" ]
  teardown
}

test_teardown_gpu_overlay() {
  echo "• teardown: GPU overlay is used for down when setup used it"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/nvidia_runtime"
  export JELLYFIN_NVENC=on
  run_deploy
  unset JELLYFIN_NVENC
  seed_state
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "down with the overlay"       calls_have "docker-compose.gpu.yml.* down"
  check "down with the base file"     calls_have "-f $SVC/docker-compose.yml"
  check "compose down ran"            [ -f "$STATE_DIR/compose_down" ]
  check "no host GPU plumbing touched" no_call "nvidia-ctk"
  teardown
}

# A state dir behind a folder this user cannot search (a root-owned 0700
# parent, faked with chmod 000): `[ -e ]` cannot see it, which must not read
# as "already gone" while .env is deleted. No cleanup container here, so it
# stops before anything changes and names the sudo command.
test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: state behind an unsearchable folder stops before anything changes"
  local st media
  deployed
  st="$HOME/services/jellyfin/storage"; media="$(env_val MEDIA_DIR)"
  mkdir -p "$st/config/data"
  echo keep > "$st/config/data/jellyfin.db"
  sed -i.bak "s#^JELLYFIN_CONFIG=.*#JELLYFIN_CONFIG=$st/config#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "jellyfin"
  chmod 755 "$st"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the folder"            out_has "$st cannot be searched"
  check "says to restore access"      out_has "sudo chown -R .* $st"
  check "never suggests deleting it"  out_lacks "sudo rm -rf $st/config"
  check "never says deleted"          out_lacks "Deleted"
  check "never asks to confirm"       out_lacks "Type jellyfin"
  check "state kept"                  [ -f "$st/config/data/jellyfin.db" ]
  check "cache kept"                  [ -f "$HOME/services/jellyfin/cache/img.jpg" ]
  check "wizard marker kept"          [ -f "$HOME/services/jellyfin/.wizard-complete" ]
  check "media kept"                  [ -f "$media/film.mkv" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "serve untouched"             no_call " off"
  teardown
  # JELLYFIN_CACHE behind it: the same guard.
  deployed
  st="$HOME/services/jellyfin/storage"
  mkdir -p "$st/cache"; echo keep > "$st/cache/img.jpg"
  sed -i.bak "s#^JELLYFIN_CACHE=.*#JELLYFIN_CACHE=$st/cache#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "jellyfin"
  chmod 755 "$st"
  check "cache hidden: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting it" out_lacks "sudo rm -rf $st/cache"
  check "  config kept"               [ -f "$HOME/services/jellyfin/config/data/jellyfin.db" ]
  check "  cache kept"                [ -f "$st/cache/img.jpg" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  # ~/services/jellyfin itself unsearchable.
  deployed
  st="$HOME/services/jellyfin"; media="$(env_val MEDIA_DIR)"
  chmod 000 "$st"
  run_teardown --purge "jellyfin"
  chmod 755 "$st"
  check "state root unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting"   out_lacks "sudo rm -rf"
  check "  config kept"               [ -f "$st/config/data/jellyfin.db" ]
  check "  media kept"                [ -f "$media/film.mkv" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  serve untouched"           no_call " off"
  teardown
  # Config and cache pointed somewhere already gone, ~/services/jellyfin
  # unsearchable: the wizard marker (and the media in there) cannot be seen,
  # so no sudo rm -rf is offered at all.
  deployed
  st="$HOME/services/jellyfin"; media="$(env_val MEDIA_DIR)"
  sed -i.bak "s#^JELLYFIN_CONFIG=.*#JELLYFIN_CONFIG=$HOME/services/gone/config#; s#^JELLYFIN_CACHE=.*#JELLYFIN_CACHE=$HOME/services/gone/cache#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "jellyfin"
  chmod 755 "$st"
  check "marker hidden: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the marker"          out_has "wizard marker"
  check "  offers no sudo rm"         out_lacks "sudo rm"
  check "  marker kept"               [ -f "$st/.wizard-complete" ]
  check "  media kept"                [ -f "$media/film.mkv" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  # ~/services itself unsearchable: not provably this service's folder, so
  # it says to check first, still before anything changes.
  deployed
  chmod 000 "$HOME/services"
  run_teardown --purge "jellyfin"
  chmod 755 "$HOME/services"
  check "\$HOME/services unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to check it first"    out_has "Check what it is"
  check "  says to restore access"    out_has "sudo chown -R"
  check "  never suggests deleting"   out_lacks "sudo rm -rf"
  check "  config kept"               [ -f "$HOME/services/jellyfin/config/data/jellyfin.db" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- /       proxy http://127.0.0.1:8080
|-- /jelly  proxy http://127.0.0.1:8096
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    out_lacks "already off"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8096 (left on, see above); 0 port(s) unpublished"
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/jellyfin/setup.sh or services/jellyfin/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_bad_username
test_fresh_deploy
test_readiness_race
test_never_ready
test_wizard_step_fails
test_wizard_step_503
test_wizard_says_incomplete
test_idempotent_rerun
test_marker_lost_but_wizard_done
test_stale_marker
test_password_drift
test_not_an_admin
test_wrong_published_url
test_port_override
test_https_port_follows_local_port
test_published_url_drift
test_media_dir_override
test_media_present
test_operator_escalation
test_serve_approval_prompt
test_nvenc_without_runtime
test_nvenc_on
test_nvenc_off_overrides_env
test_wizard_race_on_restart
test_wizard_genuinely_wiped
test_nvenc_env_predates_flag
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_unreadable
test_teardown_preflight
test_teardown_purge
test_teardown_purge_media_outside
test_teardown_purge_media_beside_state
test_teardown_purge_refuses_parent_of_media
test_teardown_purge_refuses_odd_paths
test_teardown_gpu_overlay
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
