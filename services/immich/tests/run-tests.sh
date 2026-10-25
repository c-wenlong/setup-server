#!/usr/bin/env bash
#
# Tests for services/immich/setup.sh and teardown.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

lib_dir() { sed -n 's/^UPLOAD_LOCATION=//p' "$SVC/.env"; }
db_dir()  { sed -n 's/^DB_DATA_LOCATION=//p' "$SVC/.env"; }

# Line number of the first call matching $1 in the calls log (0 if none).
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
before()    { [ "$1" -gt 0 ] && [ "$1" -lt "$2" ]; }  # call line $1 came before $2

# Point one .env key at a new value (sed with '#' delimiters, like the
# reference suite; .bak keeps it portable to BSD sed).
set_env() { sed -i.bak "s#^$1=.*#$1=$2#" "$SVC/.env"; }

# A deployed sandbox: setup.sh has run, there are photos and a database on
# disk, Serve maps this port to this service, and neighbours sit on other
# ports (one a lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(lib_dir)/upload/u1" "$(db_dir)/base"
  echo jpeg > "$(lib_dir)/upload/u1/IMG_0001.jpg"
  echo pg > "$(db_dir)/base/1"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8103 (tailnet only)
|-- / proxy http://127.0.0.1:8103

https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:12283 (tailnet only)
|-- / proxy http://127.0.0.1:12283
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down" "$STATE_DIR/compose_down_v" "$STATE_DIR/compose_stop"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps photos, database and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :2283"         calls_have "tailscale serve --https=2283 off"
  check "neighbour :8103 untouched"   no_call "https=8103"
  check "lookalike :12283 untouched"  no_call "https=12283"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  [ ! -f "$STATE_DIR/compose_down_v" ]
  check "  and never 'down -v'"       no_call "down -v"
  check "photos kept"                 [ -f "$(lib_dir)/upload/u1/IMG_0001.jpg" ]
  check "database kept"               [ -f "$(db_dir)/base/1" ]
  check "ML marker kept"              [ -f "$HOME/services/immich/.ml-mode" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "no cleanup container"        no_call "docker run"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_stop_order() {
  echo "• teardown: server and ML stop before Redis and Postgres go"
  deployed
  run_teardown
  local stop down
  stop="$(call_line "compose .* stop immich-server immich-machine-learning")"
  down="$(call_line "compose .* down")"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "server + ML stopped explicitly" [ "$stop" -gt 0 ]
  check "  before compose down"       before "$stop" "$down"
  check "  database never stopped on its own" no_call "stop.* database"
  check "  redis never stopped on its own"    no_call "stop.* redis"
  check "no parallel 'docker stop'"   no_call "^docker stop"
  teardown
}

test_teardown_ml_profile() {
  echo "• teardown: the ML container goes too, whatever .env says now"
  setup
  touch "$STATE_DIR/operator"
  IMMICH_ML=on run_deploy
  check "ML container present after deploy" [ -f "$STATE_DIR/ml_container" ]
  : > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "stop uses the ml profile"    calls_have "--profile ml stop immich-server immich-machine-learning"
  check "down uses the ml profile"    calls_have "--profile ml down"
  check "ML container removed"        [ ! -f "$STATE_DIR/ml_container" ]
  teardown
  deployed                            # ML off in .env, but a stale container
  touch "$STATE_DIR/ml_container"
  check ".env says ML off"            grep -qx 'COMPOSE_PROFILES=' "$SVC/.env"
  run_teardown
  check "stale ML container removed"  [ ! -f "$STATE_DIR/ml_container" ]
  teardown
}

test_teardown_https_port_override() {
  echo "• teardown: an explicit HTTPS_PORT is found from Serve, not .env"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:2283\n' \
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
  printf 'https://test-host.tailfake.ts.net:2283 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: nothing stopped"  [ ! -f "$STATE_DIR/compose_stop" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then photos, database, marker and .env go"
  deployed
  local lib db
  lib="$(lib_dir)"; db="$(db_dir)"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "immic"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: photos kept"     [ -f "$lib/upload/u1/IMG_0001.jpg" ]
  check "wrong name: database kept"   [ -f "$db/base/1" ]
  check "wrong name: marker kept"     [ -f "$HOME/services/immich/.ml-mode" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_stop" ]
  check "wrong name: not down"        [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  check "warns the photos are deleted" out_has "Every photo and video uploaded to Immich is deleted"
  check "warns nothing backs them up" out_has "Nothing backs them up"
  run_teardown --purge ""
  check "empty answer: exits non-zero" [ "$CODE" -ne 0 ]
  check "empty answer: photos kept"   [ -f "$lib/upload/u1/IMG_0001.jpg" ]
  run_teardown --purge "immich"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "server + ML stopped first"   calls_have "stop immich-server immich-machine-learning"
  check "down -v (model-cache volume)" [ -f "$STATE_DIR/compose_down_v" ]
  check "library gone"                [ ! -e "$lib" ]
  check "database gone"               [ ! -e "$db" ]
  check "ML marker gone"              [ ! -e "$HOME/services/immich/.ml-mode" ]
  check "services/immich install marker gone" [ ! -e "$HOME/services/immich" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :2283"         calls_have "tailscale serve --https=2283 off"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  check "compose file kept"           [ -f "$SVC/docker-compose.yml" ]
  check "no sudo"                     no_call "^sudo"
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the pinned Postgres image, not sudo"
  deployed
  local db lib img
  db="$(db_dir)"; lib="$(lib_dir)"
  img="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(ghcr\.io\/immich-app\/postgres:[^[:space:]]*\).*/\1/p' "$SVC/docker-compose.yml")"
  # Stand-ins for postgres-uid and root-owned files: read-only dirs the host
  # user cannot empty.
  mkdir -p "$db/base/locked" "$lib/thumbs/locked"
  echo x > "$db/base/locked/f"; echo x > "$lib/thumbs/locked/f"
  chmod 500 "$db/base/locked" "$lib/thumbs/locked"
  run_teardown --purge "immich"
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image"       calls_have "$img"
  check "  image is digest-pinned"    grep -q '@sha256:' <<<"$img"
  check "never pulled for it"         calls_have "pull never"
  check "mounted the database dir"    calls_have "-v $db:/x"
  check "mounted the library dir"     calls_have "-v $lib:/x"
  check "no sudo"                     no_call "^sudo"
  check "database gone"               [ ! -e "$db" ]
  check "library gone"                [ ! -e "$lib" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  db="$(db_dir)"
  mkdir -p "$db/base/locked"; echo x > "$db/base/locked/f"
  chmod 500 "$db/base/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "immich"
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $db"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a library or database outside ~/services"
  local var dotted
  for var in UPLOAD_LOCATION DB_DATA_LOCATION; do
    deployed
    mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
    set_env "$var" "$HOME"
    run_teardown --purge "immich"
    check "$var=\$HOME: exits non-zero" [ "$CODE" -ne 0 ]
    check "  home untouched"          [ -d "$HOME" ]
    check "  nothing stopped"         [ ! -f "$STATE_DIR/compose_stop" ]
    set_env "$var" "$HOME/services/../x"
    run_teardown --purge "immich"
    check "  '..' refused"            [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services/"
    run_teardown --purge "immich"
    check "  services dir itself refused" [ "$CODE" -ne 0 ]
    for dotted in "$HOME/services/." "$HOME/services/./immich" "$HOME/services/immich/.."; do
      set_env "$var" "$dotted"
      run_teardown --purge "immich"
      check "  '.' / '..' component refused: ${dotted#"$HOME"}" [ "$CODE" -ne 0 ]
    done
    check "  neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
    check "  nothing ever stopped"    [ ! -f "$STATE_DIR/compose_down" ]
    teardown
  done
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /photos proxy http://127.0.0.1:2283
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":2283 off"                   calls_have "serve --https=2283 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_stop" ]
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='2283'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":2283 off"                   calls_have "serve --https=2283 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="2283"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=2283 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
  deployed
  local lib; lib="$(lib_dir)"
  sed -i.bak -e "s|^UPLOAD_LOCATION=.*|export UPLOAD_LOCATION=\"$lib\"  # photos|" "$SVC/.env"
  check "  .env really edited"        grep -q '^export UPLOAD_LOCATION="' "$SVC/.env"
  run_teardown --purge "immich"
  check "quoted + exported library path: exits zero" [ "$CODE" -eq 0 ]
  check "  library gone"              [ ! -e "$lib" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  set_env UPLOAD_LOCATION "$HOME/services//"
  run_teardown --purge "immich"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  set_env UPLOAD_LOCATION "$HOME/services/alias"
  run_teardown --purge "immich"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  ln -s "$HOME/services/neighbour" "$HOME/services/immich/library-link"
  set_env UPLOAD_LOCATION "$HOME/services/immich/library-link"
  run_teardown --purge "immich"
  check "symlinked leaf inside immich refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  local lib db; lib="$(lib_dir)"; db="$(db_dir)"
  set_env UPLOAD_LOCATION "$lib///"
  set_env DB_DATA_LOCATION "$db/"
  run_teardown --purge "immich"
  check "trailing slashes on its own dirs: purged" [ "$CODE" -eq 0 ]
  check "  library gone"              [ ! -e "$lib" ]
  check "  database gone"             [ ! -e "$db" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: data already gone is fine, the marker dir still goes"
  deployed
  rm -rf "$(lib_dir)" "$(db_dir)"
  run_teardown --purge "immich"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "ML marker gone"              [ ! -e "$HOME/services/immich/.ml-mode" ]
  check "services/immich install marker gone" [ ! -e "$HOME/services/immich" ]
  teardown
  deployed
  echo keep > "$HOME/services/immich/notes.txt"
  rm -rf "$(lib_dir)" "$(db_dir)"
  run_teardown --purge "immich"
  check "non-empty marker dir: exits zero" [ "$CODE" -eq 0 ]
  check "  unknown file kept"         [ -f "$HOME/services/immich/notes.txt" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local lib; lib="$(lib_dir)"
  set_env UPLOAD_LOCATION "\"\${HOME}${lib#"$HOME"}\""
  run_teardown --purge "immich"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  library gone"              [ ! -e "$lib" ]
  teardown
  deployed
  lib="$(lib_dir)"
  set_env UPLOAD_LOCATION "\$HOME${lib#"$HOME"}"
  run_teardown --purge "immich"
  check "bare \$HOME form: exits zero" [ "$CODE" -eq 0 ]
  check "  library gone"              [ ! -e "$lib" ]
  teardown
  deployed
  lib="$(lib_dir)"
  set_env UPLOAD_LOCATION "'\$HOME${lib#"$HOME"}'"
  run_teardown --purge "immich"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  library kept"              [ -f "$lib/upload/u1/IMG_0001.jpg" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/immich itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  set_env DB_DATA_LOCATION "$HOME/services/neighbour"
  run_teardown --purge "immich"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_stop" ]
  teardown
  deployed
  set_env UPLOAD_LOCATION "$HOME/services/immich/a:b"
  mkdir -p "$HOME/services/immich/a:b"
  run_teardown --purge "immich"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
  # The library is the path a user is told to move to a bigger disk, so an
  # existing photo folder elsewhere is the likely case: refused, and said why.
  deployed
  mkdir -p "$HOME/Pictures/2019"; echo jpeg > "$HOME/Pictures/2019/beach.jpg"
  set_env UPLOAD_LOCATION "$HOME/Pictures"
  run_teardown --purge "immich"
  check "library outside ~/services refused" [ "$CODE" -ne 0 ]
  check "  says it is the photo library" out_has "UPLOAD_LOCATION is your photo library"
  check "  says teardown never deletes those" out_has "teardown never deletes those"
  check "  says how to proceed"       out_has "set UPLOAD_LOCATION=$HOME/services/immich/library"
  check "  photos kept"               [ -f "$HOME/Pictures/2019/beach.jpg" ]
  check "  database kept"             [ -f "$(db_dir)/base/1" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_stop" ]
  teardown
  deployed
  mkdir -p "$HOME/services/photos"; echo jpeg > "$HOME/services/photos/a.jpg"
  set_env UPLOAD_LOCATION "$HOME/services/photos"
  run_teardown --purge "immich"
  check "library in another ~/services dir refused" [ "$CODE" -ne 0 ]
  check "  explains why"              out_has "teardown never deletes those"
  check "  photos kept"               [ -f "$HOME/services/photos/a.jpg" ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/immich/library"; echo x > "$HOME/immich/library/keep"
  run_teardown --purge "immich"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/immich/library/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'UPLOAD_LOCATION=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "UPLOAD_LOCATION is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nUPLOAD_LOCATION=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
test_teardown_safe
test_teardown_stop_order
test_teardown_ml_profile
test_teardown_https_port_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_container_owned
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
