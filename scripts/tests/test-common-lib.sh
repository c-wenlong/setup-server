#!/usr/bin/env bash
#
# Tests for lib/common.sh: the helpers every deploy script sources.
#
#   ./scripts/tests/test-common-lib.sh
#
# Each case sources the real lib in a subshell with PATH stubs written into a
# temp dir (uname, id, docker, tailscale, curl, sudo, sleep), so nothing on the
# host is touched. The service suites exercise the same functions end to end;
# this covers the branches a happy-path deploy never reaches.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../.." && pwd)"
LIB="$REPO/lib/common.sh"
PASS=0; FAIL=0
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '    \033[1;32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '    \033[1;31m✗\033[0m %s\n' "$label"; FAIL=$((FAIL + 1))
  fi
}
out_has()    { grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -qF -- "$1" "$SB/calls.log"; }
no_call()    { ! grep -qF -- "$1" "$SB/calls.log"; }

# stub NAME BODY: a PATH stub that logs its argv, then runs BODY.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n%s\n' "$1" "$SB" "$2" > "$SB/bin/$1"
  chmod +x "$SB/bin/$1"
}

setup() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/sys"
  : > "$SB/calls.log"
  # The host may have a real docker or tailscale. The "not installed" cases
  # run on $SB/bin plus $SB/sys only: links to the few tools the lib and the
  # stubs need, and nothing else.
  local t
  for t in bash env cat grep head cut sed seq basename; do
    ln -s "$(command -v "$t")" "$SB/sys/$t"
  done
  stub uname 'echo "${FAKE_OS:-Linux}"'
  stub id 'echo "${FAKE_UID:-1000}"'
  stub sleep ':'
  stub sudo 'exit 0'
  stub tailscale 'case "$1" in
  status) printf "{\"BackendState\": \"%s\", \"Self\": {\"DNSName\": \"box.tail1.ts.net.\"}}\n" "${FAKE_TS_STATE:-Running}" ;;
  serve)  n=$(cat "'"$SB"'/serve_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "'"$SB"'/serve_n"
          [ "$n" -gt "${FAKE_SERVE_FAILS:-0}" ] ;;
esac'
  stub docker 'case "$1" in
  ps) [ -z "${FAKE_DOCKER_DOWN:-}" ] ;;
  compose) [ -z "${FAKE_NO_COMPOSE:-}" ] ;;
esac'
  stub curl 'n=$(cat "'"$SB"'/curl_n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "'"$SB"'/curl_n"
[ "$n" -gt "${FAKE_CURL_FAILS:-0}" ]'
}
teardown() { rm -rf "$SB"; unset FAKE_OS FAKE_UID FAKE_TS_STATE FAKE_SERVE_FAILS FAKE_DOCKER_DOWN FAKE_NO_COMPOSE FAKE_CURL_FAILS; }

# lib 'commands': source the lib in a fresh bash under the stubs, run the
# commands, capture stdout+stderr in OUT and the status in CODE.
lib() {
  local path="$SB/bin:$PATH"
  [ -z "${BARE:-}" ] || path="$SB/bin:$SB/sys"
  OUT="$(PATH="$path" bash -c 'set -euo pipefail; . "$1"; eval "$2"' _ "$LIB" "$1" 2>&1 </dev/null)"
  CODE=$?
}

echo "• output helpers"
setup
lib 'info a; ok b; warn c'
check "info/ok/warn print their text"      out_has "c"
lib 'die nope; echo after'
check "die exits non-zero"                 [ "$CODE" -ne 0 ]
check "die stops the script"               bash -c '! grep -q after <<<"$1"' _ "$OUT"
check "die says why"                       out_has "nope"
teardown

echo "• detect_os"
setup
lib 'detect_os; echo "os=$OS"'
check "Linux accepted"                     out_has "os=Linux"
FAKE_OS=Darwin lib 'detect_os; echo "os=$OS"'
check "macOS accepted"                     out_has "os=Darwin"
FAKE_OS=FreeBSD lib 'detect_os; echo reached'
check "anything else refused"              [ "$CODE" -ne 0 ]
check "  names the OS"                     out_has "Unsupported OS: FreeBSD"
teardown

echo "• refuse_root"
setup
lib 'refuse_root; echo reached'
check "a regular user passes"              out_has "reached"
FAKE_UID=0 lib 'refuse_root'
check "root refused"                       [ "$CODE" -ne 0 ]
check "  default message"                  out_has "Run as a regular user, not root."
FAKE_UID=0 lib 'refuse_root "custom reason"'
check "  custom message"                   out_has "custom reason"
teardown

echo "• resolve_tailscale / require_tailscale_up / tailnet_host"
setup
lib 'detect_os; resolve_tailscale; echo "ts=$TAILSCALE"; require_tailscale_up; echo "host=$(tailnet_host)"'
check "CLI found on PATH"                  out_has "ts=tailscale"
check "MagicDNS name, trailing dot gone"   out_has "host=box.tail1.ts.net"
FAKE_TS_STATE=Stopped lib 'detect_os; resolve_tailscale; require_tailscale_up'
check "a stopped tailscaled is fatal"      [ "$CODE" -ne 0 ]
check "  shows the state"                  out_has "state: Stopped"
rm "$SB/bin/tailscale"
BARE=1 lib 'detect_os; resolve_tailscale'
check "no CLI at all is fatal"             out_has "Tailscale is not installed"
teardown

echo "• require_docker_compose"
setup
lib 'detect_os; require_docker_compose; echo reached'
check "docker + daemon + compose pass"     out_has "reached"
FAKE_DOCKER_DOWN=1 lib 'detect_os; require_docker_compose'
check "daemon unreachable is fatal"        out_has "Cannot talk to the Docker daemon"
check "  Linux hint names the docker group" out_has "usermod -aG docker"
FAKE_DOCKER_DOWN=1 FAKE_OS=Darwin lib 'detect_os; require_docker_compose'
check "  macOS hint names Docker Desktop"  out_has "Docker Desktop/OrbStack running"
FAKE_NO_COMPOSE=1 lib 'detect_os; require_docker_compose'
check "no Compose v2 is fatal"             out_has "Docker Compose v2 is required"
rm "$SB/bin/docker"
BARE=1 lib 'detect_os; require_docker_compose'
check "no docker is fatal"                 out_has "Docker is not installed"
teardown

echo "• require_numeric"
setup
lib 'A=8080 B=443; require_numeric A B; echo reached'
check "digits pass"                        out_has "reached"
lib 'A=80x; require_numeric A'
check "a non-digit is fatal"               out_has "A must be numeric (got: 80x)"
lib 'A=; require_numeric A'
check "empty is fatal"                     [ "$CODE" -ne 0 ]
lib 'require_numeric UNSET_VAR'
check "unset is fatal, not an unbound-variable crash" out_has "UNSET_VAR must be numeric"
teardown

echo "• wait_http"
setup
FAKE_CURL_FAILS=2 lib 'wait_http http://127.0.0.1:1/ 5 1 && echo up'
check "returns 0 once the URL answers"     out_has "up"
check "  after retrying"                   [ "$(cat "$SB/curl_n")" -eq 3 ]
teardown
setup
FAKE_CURL_FAILS=99 lib 'wait_http http://127.0.0.1:1/ 4 1 || echo gave-up'
check "returns 1 after TRIES attempts"     out_has "gave-up"
check "  exactly TRIES curls"              [ "$(cat "$SB/curl_n")" -eq 4 ]
check "  no sleep after the last try"      [ "$(grep -c '^sleep' "$SB/calls.log")" -eq 3 ]
teardown

echo "• ts_serve_publish"
setup
lib 'detect_os; resolve_tailscale; ts_serve_publish 8443 http://127.0.0.1:8081'
check "first try works: exits zero"        [ "$CODE" -eq 0 ]
check "  publishes the port and target"    calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8081"
check "  no sudo"                          no_call "sudo"
check "  confirms the mapping"             out_has "Tailscale Serve: HTTPS :8443 -> http://127.0.0.1:8081"
teardown
setup
FAKE_SERVE_FAILS=1 lib 'detect_os; resolve_tailscale; ts_serve_publish 8443 http://127.0.0.1:8081'
check "Linux, first try denied: operator grant via sudo" calls_have "sudo tailscale set --operator="
check "  then succeeds"                    [ "$CODE" -eq 0 ]
teardown
setup
FAKE_OS=Darwin FAKE_SERVE_FAILS=1 lib 'detect_os; resolve_tailscale; ts_serve_publish 8443 http://127.0.0.1:8081'
check "macOS never asks for sudo"          no_call "sudo"
teardown
setup
FAKE_SERVE_FAILS=2 lib 'detect_os; resolve_tailscale; ts_serve_publish 8443 http://127.0.0.1:8081'
check "needs approval, no TTY: fatal"      [ "$CODE" -ne 0 ]
check "  says how to approve"              out_has "re-run setup.sh in a terminal"
teardown
setup
OUT="$(printf '\n' | FAKE_SERVE_FAILS=2 PATH="$SB/bin:$PATH" bash -c 'set -euo pipefail; . "$1"; detect_os; resolve_tailscale; ts_serve_publish 8443 http://127.0.0.1:8081' _ "$LIB" 2>&1)"; CODE=$?
check "needs approval, Enter pressed: retries and succeeds" [ "$CODE" -eq 0 ]
check "  prompts for the approval URL"     out_has "approval URL"
teardown

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL of $((PASS + FAIL)) checks failed."
  exit 1
fi
