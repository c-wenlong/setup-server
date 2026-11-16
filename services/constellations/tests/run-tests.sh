#!/usr/bin/env bash
#
# Tests for services/constellations/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite
#   ./tests/run-tests.sh --live   # also verify the real deployment

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
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
  SVC="$SANDBOX/repo/services/constellations"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SVC/"
  touch "$STATE_DIR/operator"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID STATE_DIR CALLS_LOG LOCAL_PORT HTTPS_PORT
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

run_teardown() {
  # $2 is the flag, quoted so an empty one is not dropped as a missing word
  # and a present one is not eaten by the command substitution.
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${2+"$2"} 2>&1)"
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

out_has()    { grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -qF -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -qF -- "$1" "$CALLS_LOG"; }
env_has()    { grep -qxF -- "$1" "$SVC/.env"; }

echo "1. fresh install publishes 8108 to 8845"
setup
run_deploy
check "exits 0" [ "$CODE" -eq 0 ]
check "writes LOCAL_PORT" env_has "LOCAL_PORT=8845"
check "writes HTTPS_PORT" env_has "HTTPS_PORT=8108"
check "publishes serve" calls_have "tailscale serve --bg --https=8108 http://127.0.0.1:8845"
check "probes the app" calls_have "curl -fsS -o /dev/null http://127.0.0.1:8845/"
teardown

echo "2. re-run keeps .env and does not move the port"
setup
printf 'LOCAL_PORT=8845\nHTTPS_PORT=8108\n# keep-me\n' > "$SVC/.env"
LOCAL_PORT=9999 HTTPS_PORT=9998 run_deploy
check "exits 0" [ "$CODE" -eq 0 ]
check "keeps the marker" env_has "# keep-me"
check "does not adopt the override" env_has "HTTPS_PORT=8108"
check "still publishes 8108" calls_have "tailscale serve --bg --https=8108 http://127.0.0.1:8845"
teardown

echo "3. refuses to run as root"
setup
FAKE_UID=0 run_deploy
check "exits non-zero" [ "$CODE" -ne 0 ]
check "names root" out_has "not root"
check "writes no env" [ ! -f "$SVC/.env" ]
teardown

echo "4. teardown unpublishes only this app and stops the unit"
setup
printf 'LOCAL_PORT=8845\nHTTPS_PORT=8108\n' > "$SVC/.env"
printf '%s\n' \
  'https://test-host.tailfake.ts.net:8108 (tailnet only)' \
  '|-- / proxy http://127.0.0.1:8845' \
  '' \
  'https://test-host.tailfake.ts.net:8109 (tailnet only)' \
  '|-- / proxy http://127.0.0.1:8109' \
  > "$STATE_DIR/serve_status"
touch "$STATE_DIR/active.design-research"
run_teardown ""
check "exits 0" [ "$CODE" -eq 0 ]
check "turns 8108 off" calls_have "tailscale serve --https=8108 off"
check "leaves 8109" no_call "tailscale serve --https=8109 off"
check "stops the unit" calls_have "systemctl --user disable --now design-research.service"
check "keeps .env" [ -f "$SVC/.env" ]
teardown

echo "5. purge with the wrong word deletes nothing"
setup
printf 'LOCAL_PORT=8845\nHTTPS_PORT=8108\n' > "$SVC/.env"
printf '%s\n' 'https://test-host.tailfake.ts.net:8108 (tailnet only)' '|-- / proxy http://127.0.0.1:8845' > "$STATE_DIR/serve_status"
run_teardown "nope" --purge
check "exits non-zero" [ "$CODE" -ne 0 ]
check "keeps .env" [ -f "$SVC/.env" ]
teardown

echo "6. purge with the right word deletes .env"
setup
printf 'LOCAL_PORT=8845\nHTTPS_PORT=8108\n' > "$SVC/.env"
printf '%s\n' 'https://test-host.tailfake.ts.net:8108 (tailnet only)' '|-- / proxy http://127.0.0.1:8845' > "$STATE_DIR/serve_status"
run_teardown "constellations" --purge
check "exits 0" [ "$CODE" -eq 0 ]
check "deletes .env" [ ! -f "$SVC/.env" ]
teardown

if [ "${1:-}" = "--live" ]; then
  echo "7. live"
  export HOME="$ORIG_HOME"
  check "unit active" systemctl --user is-active --quiet design-research.service
  code="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8845/ || true)"
  check "loopback answers" [ "$code" = "200" ]
  tailscale serve status | grep -q '8108' && check "serve has 8108" true || check "serve has 8108" false
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
