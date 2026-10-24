#!/usr/bin/env bash
#
# Tests for services/immich/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id. The curl stub
# fakes the Immich REST API, so admin creation and the settings PUT are
# exercised for real (python3 does the JSON work in both cases).

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
  unset FAKE_UID LOCAL_PORT HTTPS_PORT IMMICH_ML STATE_DIR CALLS_LOG
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
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# Read a dotted key out of the config JSON the script PUT to /admin/config.
put_cfg() {  # put_cfg <dotted.key> <expected>
  local got
  got="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(json.dumps(d))
' "$STATE_DIR/config_put.json" "$1" 2>/dev/null)"
  [ "$got" = "$2" ]
}

# ----------------------------------------------------------------- tests
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
  teardown
}

test_preflight_bad_https_port() {
  echo "• preflight rejects a non-numeric HTTPS port"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "must be numeric"
  teardown
}

test_preflight_bad_ml_flag() {
  echo "• preflight rejects an invalid IMMICH_ML value"
  setup
  export IMMICH_ML=yes
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "IMMICH_ML must be 'on' or 'off'"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy_ml_off() {
  echo "• fresh deploy (default): ML off, admin created, tuning applied"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env has a hex DB password"     grep -qE '^DB_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env has an admin password"     grep -qE '^IMMICH_ADMIN_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env pins the v3 line"          env_has "IMMICH_VERSION=v3"
  check ".env has empty profiles"        grep -qx 'COMPOSE_PROFILES=' "$SVC/.env"
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]
  check "ML profile NOT started"         [ ! -f "$STATE_DIR/compose_up_ml" ]
  check "library dir created"            [ -d "$HOME/services/immich/library" ]
  check "postgres dir created"           [ -d "$HOME/services/immich/postgres" ]
  check "admin sign-up called"           calls_have "/api/auth/admin-sign-up"
  check "onboarding dismissed"           calls_have "/api/system-metadata/admin-onboarding"
  check "config PUT happened"            [ -f "$STATE_DIR/config_put.json" ]
  check "  machineLearning disabled"     put_cfg machineLearning.enabled false
  check "  smartSearch concurrency 1"    put_cfg job.smartSearch.concurrency 1
  check "  faceDetection concurrency 1"  put_cfg job.faceDetection.concurrency 1
  check "  thumbnails concurrency 1"     put_cfg job.thumbnailGeneration.concurrency 1
  check "  ffmpeg threads 2"             put_cfg ffmpeg.threads 2
  check "  small face model"             put_cfg machineLearning.facialRecognition.modelName '"buffalo_s"'
  check "  untouched keys preserved"     put_cfg job.metadataExtraction.concurrency 5
  check "ml mode marker written"         grep -qx off "$HOME/services/immich/.ml-mode"
  check "served on tailscale :2283"      calls_have "tailscale serve --bg --https=2283 http://127.0.0.1:2283"
  check "prints final URL"               out_has "https://test-host.tailfake.ts.net:2283"
  check "explains what ML off costs"     out_has "no semantic search"
  check "tells you how to enable ML"     out_has "IMMICH_ML=on ./setup.sh"
  check "warns about double backup"      out_has "Turn OFF Seafile camera upload"
  teardown
}

test_fresh_deploy_ml_on() {
  echo "• fresh deploy with IMMICH_ML=on: profile started, ML enabled"
  setup
  touch "$STATE_DIR/operator"
  export IMMICH_ML=on
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "ML profile started"          [ -f "$STATE_DIR/compose_up_ml" ]
  check ".env records the profile"    grep -qx 'COMPOSE_PROFILES=ml' "$SVC/.env"
  check "machineLearning enabled"     put_cfg machineLearning.enabled true
  check "ML url points at container"  put_cfg machineLearning.urls '["http://immich-machine-learning:3003"]'
  check "tuning still applied"        put_cfg job.smartSearch.concurrency 1
  check "ml mode marker written"      grep -qx on "$HOME/services/immich/.ml-mode"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, settings left alone"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  rm -f "$STATE_DIR/config_put.json"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "existing .env untouched"       env_has "my-custom-marker"
  check "never invoked sudo"            no_call "^sudo "
  check "compose up re-invoked"         [ -f "$STATE_DIR/compose_up" ]
  check "kept the existing admin"       out_has "Admin account already exists"
  check "did NOT rewrite settings"      [ ! -f "$STATE_DIR/config_put.json" ]
  check "says settings unchanged"       out_has "Settings unchanged"
  teardown
}

test_ml_toggle_on_then_off() {
  echo "• IMMICH_ML flip: on -> off stops the container and disables ML"
  setup
  touch "$STATE_DIR/operator"
  IMMICH_ML=on run_deploy
  check "ML container present after on"  [ -f "$STATE_DIR/ml_container" ]
  rm -f "$STATE_DIR/config_put.json" "$STATE_DIR/compose_up_ml"
  : > "$CALLS_LOG"
  export IMMICH_ML=off
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "ML profile not started"         [ ! -f "$STATE_DIR/compose_up_ml" ]
  check "stale ML container removed"     [ -f "$STATE_DIR/compose_rm_ml" ]
  check "settings rewritten for flip"    [ -f "$STATE_DIR/config_put.json" ]
  check "machineLearning disabled"       put_cfg machineLearning.enabled false
  check "tuning NOT re-applied"          put_cfg job.thumbnailGeneration.concurrency 3
  check ".env profiles cleared"          grep -qx 'COMPOSE_PROFILES=' "$SVC/.env"
  check "marker flipped to off"          grep -qx off "$HOME/services/immich/.ml-mode"
  teardown
}

test_config_endpoint_rename() {
  echo "• config endpoint: falls back on v3.1.0, uses the new path after the rename"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # stub defaults to v3.1.0
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "says it fell back"             out_has "pre-rename config endpoint"
  check "settings still written"        [ -f "$STATE_DIR/config_put.json" ]
  check "wrote via /system-config"      calls_have "/api/system-config"
  teardown

  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/new_config_api"
  run_deploy                                   # post-rename server
  check "exits zero (new API)"          [ "$CODE" -eq 0 ]
  check "no fallback message"           [ "$(grep -c 'pre-rename' <<<"$OUT")" -eq 0 ]
  check "wrote via /admin/config"       calls_have "/api/admin/config"
  check "settings still written"        [ -f "$STATE_DIR/config_put.json" ]
  teardown
}

test_resume_after_partial_failure() {
  echo "• resume: admin exists but settings never landed -> tuning still applies"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/admin_exists"   # admin from a died run
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "kept the existing admin"       out_has "Admin account already exists"
  check "tuning applied anyway"         out_has "Applied low-RAM job tuning"
  check "  smartSearch concurrency 1"   put_cfg job.smartSearch.concurrency 1
  check "  ffmpeg threads 2"            put_cfg ffmpeg.threads 2
  check "marker now written"            grep -qx off "$HOME/services/immich/.ml-mode"
  teardown
}

test_hand_edited_profiles() {
  echo "• COMPOSE_PROFILES hand-edited in .env: honoured, marker follows"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy: ML off
  check "marker starts off"             grep -qx off "$HOME/services/immich/.ml-mode"
  awk '/^COMPOSE_PROFILES=/{print "COMPOSE_PROFILES=ml"; next} {print}' \
    "$SVC/.env" > "$SVC/.env.new" && mv "$SVC/.env.new" "$SVC/.env"
  rm -f "$STATE_DIR/config_put.json" "$STATE_DIR/compose_up_ml"
  : > "$CALLS_LOG"
  run_deploy                                   # no IMMICH_ML: .env wins
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "ML profile started"            [ -f "$STATE_DIR/compose_up_ml" ]
  check "machineLearning enabled"       put_cfg machineLearning.enabled true
  check "marker caught up to .env"      grep -qx on "$HOME/services/immich/.ml-mode"
  teardown
}

test_password_drift() {
  echo "• password changed in the UI: warns, still publishes"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/admin_exists" "$STATE_DIR/login_fails"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "warns about the drift"   out_has "no longer matches the server"
  check "wrote no settings"       [ ! -f "$STATE_DIR/config_put.json" ]
  check "still published"         calls_have "tailscale serve --bg --https=2283"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=2283"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (2283) next to a LOCAL_PORT
  # override silently published :2283 -> 127.0.0.1:2284, i.e. the wrong port.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=2284
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=2284"  grep -qx 'LOCAL_PORT=2284' "$SVC/.env"
  check "served :2284 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=2284 http://127.0.0.1:2284"
  check "  and never :2283"             no_call "tailscale serve --bg --https=2283"
  check "prints the :2284 URL"          out_has "https://test-host.tailfake.ts.net:2284"
  # Re-run with no override at all: .env says 2284, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 2283.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  check "re-run kept :2284 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=2284 http://127.0.0.1:2284"
  check "  and never :2283"             no_call "tailscale serve --bg --https=2283"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=2284 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:2284"
  check "prints the :8443 URL"          out_has "https://test-host.tailfake.ts.net:8443"
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
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"     calls_have "tailscale serve --bg --https=2283"
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
# (2283 -> 2283), so tailscaled legitimately listens on the tailnet IP for
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
  # than letting three red lines imply an outage. A shell started before the
  # user was added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "server container running"    sh -c "docker inspect -f '{{.State.Status}}' immich_server | grep -qx running"
  live_check "postgres container running"  sh -c "docker inspect -f '{{.State.Status}}' immich_postgres | grep -qx running"
  live_check "redis container running"     sh -c "docker inspect -f '{{.State.Status}}' immich_redis | grep -qx running"
  live_check "local ping responds"         sh -c "curl -fsS 'http://127.0.0.1:$port/api/server/ping' | grep -q pong"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "postgres port not published" no_external_listener 5432
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"      curl -fsS -o /dev/null --max-time 30 "$url:$https_port/api/server/ping"
  live_check "library dir exists"          sh -c "test -d \"\$(sed -n 's/^UPLOAD_LOCATION=//p' '$SERVICE_DIR/.env')\""

  # ML container should exist iff the deployed mode says so.
  if [ "$(cat "$HOME/services/immich/.ml-mode" 2>/dev/null || echo off)" = "on" ]; then
    live_check "ML container running"      sh -c "docker inspect -f '{{.State.Status}}' immich_machine_learning | grep -qx running"
  else
    live_check "ML container absent"       sh -c "! docker ps -a --format '{{.Names}}' | grep -qx immich_machine_learning"
  fi
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_https_port
test_preflight_bad_ml_flag
test_fresh_deploy_ml_off
test_fresh_deploy_ml_on
test_idempotent_rerun
test_ml_toggle_on_then_off
test_config_endpoint_rename
test_resume_after_partial_failure
test_hand_edited_profiles
test_password_drift
test_operator_escalation
test_https_port_follows_local_port
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
