#!/usr/bin/env bash
#
# Tests for services/code-server/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (simulated fresh server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real script inside a sandbox: fake $HOME, and PATH
# stubs for curl/tailscale/sudo/systemctl/loginctl/launchctl/id/uname that log every call to
# $CALLS_LOG and keep state (operator granted, lingering, forced serve
# failures) in $STATE_DIR. Nothing touches the real system.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../setup.sh"   # run in place, so ../../lib/common.sh is the repo's own
TEARDOWN="$TESTS_DIR/../teardown.sh"
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
  mkdir -p "$HOME" "$STATE_DIR"
  : > "$CALLS_LOG"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_OS PORT STATE_DIR CALLS_LOG
}

# run_deploy [stdin-string] — runs the script under stubs; sets OUT and CODE
run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SCRIPT" 2>&1)"
  CODE=$?
}

check() { # check <description> <condition...>
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

# ----------------------------------------------------------------- tests
test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "explains the problem"      out_has "Tailscale is not up"
  check "did not install anything"  [ ! -e "$HOME/.local/bin/code-server" ]
  teardown
}

test_preflight_refuses_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "mentions regular user" out_has "regular user"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path on a clean server"
  setup
  run_deploy
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check "installed fake code-server"        [ -x "$HOME/.local/bin/code-server" ]
  check "wrote config with default port"    grep -q "bind-addr: 127.0.0.1:8080" "$HOME/.config/code-server/config.yaml"
  check "config binds localhost only"       grep -q "bind-addr: 127.0.0.1" "$HOME/.config/code-server/config.yaml"
  if [ "$OS" = "Linux" ]; then
    check "wrote systemd unit"              [ -f "$HOME/.config/systemd/user/code-server.service" ]
    check "enabled + restarted service"     calls_have "systemctl --user restart code-server"
    check "enabled lingering via sudo"      calls_have "sudo loginctl enable-linger"
    check "granted operator via sudo"       calls_have "sudo tailscale set --operator="
  else
    check "wrote LaunchAgent plist"         [ -f "$HOME/Library/LaunchAgents/com.coder.code-server.plist" ]
    check "bootstrapped LaunchAgent"        calls_have "launchctl bootstrap"
  fi
  check "published via tailscale serve"     calls_have "tailscale serve --bg http://127.0.0.1:8080"
  check "prints final tailnet URL"          out_has "https://test-host.tailfake.ts.net"
  check "end-to-end check passed"           out_has "End-to-end check passed"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run on already-deployed server: no sudo, config preserved"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  mkdir -p "$HOME/.config/code-server"
  printf 'bind-addr: 127.0.0.1:8080\nauth: none\ncert: false\n# my-custom-marker\n' \
    > "$HOME/.config/code-server/config.yaml"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "config left untouched"         grep -q "my-custom-marker" "$HOME/.config/code-server/config.yaml"
  check "says config untouched"         out_has "leaving untouched"
  check "never invoked sudo"            no_call "^sudo "
  if [ "$OS" = "Linux" ]; then
    check "service still restarted"     calls_have "systemctl --user restart code-server"
  else
    check "LaunchAgent re-bootstrapped" calls_have "launchctl bootstrap"
  fi
  check "serve reapplied"               calls_have "tailscale serve --bg"
  teardown
}

test_port_override() {
  echo "• PORT=9000 override"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  export PORT=9000
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "config uses port 9000"    grep -q "bind-addr: 127.0.0.1:9000" "$HOME/.config/code-server/config.yaml"
  check "serve proxies port 9000"  calls_have "tailscale serve --bg http://127.0.0.1:9000"
  teardown
}

test_serve_approval_retry() {
  echo "• serve not yet enabled on tailnet: approval prompt + retry loop"
  setup
  echo 2 > "$STATE_DIR/serve_fails_left"   # fail twice, succeed on 3rd attempt
  run_deploy $'\n'                         # press Enter at the approval prompt
  check "exits zero after retry"     [ "$CODE" -eq 0 ]
  check "showed the approval prompt" out_has "one-time enablement"
  check "eventually published"       out_has "Tailscale Serve: HTTPS :443"
  [ "$OS" = "Linux" ] && check "granted operator on 1st failure" calls_have "sudo tailscale set --operator="
  teardown
}

# ------------------------------------------------------------- teardown
# run_teardown [flag] [stdin-line] — runs teardown.sh under stubs; sets OUT and CODE
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$TEARDOWN" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# line number of the first call matching $1 (0 if none) — for ordering checks
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
# true when the last logged call matches $1 — the stop must be the final change
last_call_is() { tail -n 1 "$CALLS_LOG" | grep -q -- "$1"; }

# A deployed sandbox, shaped like the real box: setup.sh has run; :443 carries
# code-server at / and the launcher at /home; the launcher has its own :8093;
# a lookalike port proxies to 18080; user data and a workspace exist.
deployed() {
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  mkdir -p "$HOME/.local/share/code-server/extensions/some.ext" "$HOME/.local/lib/code-server-9.9.9" \
           "$HOME/dev/my-repo"
  echo keep > "$HOME/.local/share/code-server/User-settings.json"
  echo mine > "$HOME/dev/my-repo/README"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /home proxy http://127.0.0.1:8093

https://test-host.tailfake.ts.net:8093 (tailnet only)
|-- / proxy http://127.0.0.1:8093

https://test-host.tailfake.ts.net:18080 (tailnet only)
|-- / proxy http://127.0.0.1:18080
EOF
  : > "$CALLS_LOG"
}

test_teardown_safe() {
  echo "• teardown: safe remove drops only code-server's / on shared :443, keeps everything"
  deployed
  run_teardown
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ":443 / off via --set-path"      calls_have "tailscale serve --https=443 --set-path=/ off"
  check "whole :443 NOT off"             no_call "serve --https=443 off"
  check "launcher /home untouched"       no_call "set-path=/home"
  check "launcher :8093 untouched"       no_call "https=8093"
  check "lookalike :18080 untouched"     no_call "https=18080"
  check "never serve reset"              no_call "serve reset"
  check "says the rest of :443 stays"    out_has "stay published"
  check "unit disabled"                  calls_have "systemctl --user disable code-server.service"
  check "unit stopped"                   calls_have "systemctl --user stop code-server.service"
  check "serve off before disable"       [ "$(call_line 'set-path=/ off')" -lt "$(call_line 'disable code-server')" ]
  check "disable before stop"            [ "$(call_line 'disable code-server')" -lt "$(call_line 'stop code-server')" ]
  check "stop is the last call"          last_call_is "stop code-server"
  check "no daemon-reload without purge" no_call "daemon-reload"
  check "unit file kept"                 [ -f "$HOME/.config/systemd/user/code-server.service" ]
  check "config kept"                    [ -f "$HOME/.config/code-server/config.yaml" ]
  check "extensions kept"                [ -d "$HOME/.local/share/code-server/extensions/some.ext" ]
  check "binary kept"                    [ -x "$HOME/.local/bin/code-server" ]
  check "workspace untouched"            [ -f "$HOME/dev/my-repo/README" ]
  check "says how to bring it back"      out_has "./setup.sh brings it back"
  check "says the launcher is fine"      out_has "launcher at https://<host>/home/ is not affected"
  : > "$CALLS_LOG"
  run_teardown
  check "re-run exits zero"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_port_shapes() {
  echo "• teardown: an all-code-server port goes off whole; shared ports lose only code-server's paths"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080

https://test-host.tailfake.ts.net:8445 (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /code proxy http://127.0.0.1:8080

https://test-host.tailfake.ts.net:9443 (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /code proxy http://127.0.0.1:8080
|-- /home proxy http://127.0.0.1:8093

https://test-host.tailfake.ts.net:8093 (tailnet only)
|-- / proxy http://127.0.0.1:8093

http://test-host.tailfake.ts.net:80 (tailnet only)
|-- / proxy http://127.0.0.1:8080

https://test-host.tailfake.ts.net:8446 (tailnet only)
|-- / proxy http://127.0.0.1:80800
|-- /x proxy http://127.0.0.1:18080
|-- /t text http://127.0.0.1:8080
EOF
  run_teardown
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check ":443 (all code-server) off whole"  calls_have "serve --https=443 off"
  check ":8445 (all code-server) off whole" calls_have "serve --https=8445 off"
  check ":9443 / off"                       calls_have "serve --https=9443 --set-path=/ off"
  check ":9443 /code off"                   calls_have "serve --https=9443 --set-path=/code off"
  check ":9443 not off whole"               no_call "serve --https=9443 off"
  check ":9443 /home kept"                  no_call "set-path=/home"
  check "launcher :8093 untouched (http block not merged in)" no_call "https=8093"
  check "plain-http block never acted on"   no_call "=80 "
  check "lookalikes and text handler untouched" no_call "https=8446"
  check "never serve reset"                 no_call "serve reset"
  teardown
}

test_teardown_unexpected_path_left_on() {
  echo "• teardown: a route left alone (odd path) is counted, not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8445 (tailnet only)
|-- code proxy http://127.0.0.1:8080
|-- /home proxy http://127.0.0.1:8093
EOF
  run_teardown
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "warns about the odd path"       out_has "Unexpected Serve path 'code' on :8445"
  check "no serve off"                   no_call " off"
  check "does not say already off"       bash -c '! grep -q "already off" <<<"$1"' _ "$OUT"
  check "counts the kept route"          out_has "1 Serve route(s) still point at http://127.0.0.1:8080 (left on, see above); 0 route(s) unpublished"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /home proxy http://127.0.0.1:8093

https://test-host.tailfake.ts.net:8445 (tailnet only)
|-- code proxy http://127.0.0.1:8080
|-- /home proxy http://127.0.0.1:8093
EOF
  : > "$CALLS_LOG"
  run_teardown
  check "mixed: exits zero"              [ "$CODE" -eq 0 ]
  check "mixed: :443 / off"              calls_have "serve --https=443 --set-path=/ off"
  check "mixed: odd path not turned off" no_call "https=8445"
  check "mixed: counts kept and unpublished" out_has "1 Serve route(s) still point at http://127.0.0.1:8080 (left on, see above); 1 route(s) unpublished"
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published (or only lookalikes) is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says already off"            out_has "already off"
  check "still stops"                 calls_have "systemctl --user stop code-server.service"
  teardown
  deployed
  printf 'https://test-host.tailfake.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:18080\n|-- /a proxy http://127.0.0.1:80800\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "lookalike-only: exits zero"  [ "$CODE" -eq 0 ]
  check "lookalike-only: no serve off" no_call " off"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "no disable / stop"           no_call "systemctl"
  check "no serve off"                no_call " off"
  teardown
}

test_teardown_port_from_config() {
  echo "• teardown: the port comes from config.yaml bind-addr (hand edits win)"
  local form
  for form in "bind-addr: 127.0.0.1:9000" "bind-addr: \"127.0.0.1:9000\"   # moved" \
              "bind-addr: '127.0.0.1:9000'" "bind-addr: localhost:9000" $'bind-addr: 127.0.0.1:9000\r'; do
    deployed
    printf '%s\nauth: none\ncert: false\n' "$form" > "$HOME/.config/code-server/config.yaml"
    printf 'https://test-host.tailfake.ts.net:9001 (tailnet only)\n|-- / proxy http://127.0.0.1:9000\n|-- /x proxy http://127.0.0.1:8080\n' \
      > "$STATE_DIR/serve_status"
    run_teardown
    check "[$form] exits zero"        [ "$CODE" -eq 0 ]
    check "  :9001 / off (port 9000)" calls_have "serve --https=9001 --set-path=/ off"
    check "  /x on 8080 kept (8080 is no longer code-server's)" no_call "set-path=/x"
    teardown
  done
}

test_teardown_config_refused() {
  echo "• teardown: a config.yaml it cannot read for sure changes nothing"
  local bad
  for bad in $'bind-addr: 127.0.0.1:8080\nbind-addr: 127.0.0.1:9000' "auth: none" \
             "bind-addr: 127.0.0.1:abc" "bind-addr: 8080" "bind-addr: 127.0.0.1:" ; do
    deployed
    printf '%s\n' "$bad" > "$HOME/.config/code-server/config.yaml"
    run_teardown
    check "[${bad//$'\n'/ | }] exits non-zero" [ "$CODE" -ne 0 ]
    check "  nothing unpublished"     no_call " off"
    check "  nothing stopped"         no_call "systemctl"
    teardown
  done
  deployed
  rm -f "$HOME/.config/code-server/config.yaml"
  run_teardown
  check "no config.yaml: exits non-zero" [ "$CODE" -ne 0 ]
  check "  explains"                  out_has "nothing to tear down"
  check "  touched nothing"           no_call "systemctl"
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"        [ "$CODE" -ne 0 ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero" [ "$CODE" -ne 0 ]
  OUT="$(PATH="$STUBS:$PATH" bash "$TEARDOWN" --purge extra 2>&1 </dev/null)"; CODE=$?
  check "too many args: exits non-zero" [ "$CODE" -ne 0 ]
  check "nothing changed"             no_call "systemctl"
  export FAKE_OS=FreeBSD
  run_teardown
  check "unsupported OS: exits non-zero" [ "$CODE" -ne 0 ]
  unset FAKE_OS
  check "still nothing changed"       no_call " off"
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in the shell is refused (shared guard)"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    OUT="$(printf 'code-server\n' | env "$v=x" PATH="$STUBS:$PATH" bash "$TEARDOWN" --purge 2>&1)"; CODE=$?
    check "$v: exits non-zero"        [ "$CODE" -ne 0 ]
    check "  nothing unpublished"     no_call " off"
    check "  nothing stopped"         no_call "systemctl"
    check "  unit file kept"          [ -f "$HOME/.config/systemd/user/code-server.service" ]
    teardown
  done
}

test_teardown_stop_failures() {
  echo "• teardown: stop that fails on a running unit is an error; on a stopped one it is fine"
  deployed
  touch "$STATE_DIR/stop_fails"
  echo active > "$STATE_DIR/active_state"
  run_teardown
  check "running + stop fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                   out_has "Could not stop code-server.service"
  echo inactive > "$STATE_DIR/active_state"
  run_teardown
  check "not loaded: exits zero"      [ "$CODE" -eq 0 ]
  rm -f "$STATE_DIR/stop_fails"
  touch "$STATE_DIR/disable_fails"
  : > "$CALLS_LOG"
  run_teardown
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  never stopped"             no_call "stop code-server"
  teardown
}

test_teardown_other_units() {
  echo "• teardown: units that mention code-server but setup.sh did not write are named, not touched"
  deployed
  local d="$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=%%h/bin/backup-code-server-settings\n' > "$d/cs-backup.service"
  printf '[Timer]\nUnit=cs-backup.service\n' > "$d/cs-backup.timer"
  printf '[Service]\nExecStart=/usr/bin/env python3 server.py\n' > "$d/launcher.service"
  mkdir -p "$d/code-server.service.d"; printf '[Service]\nEnvironment=X=1\n' > "$d/code-server.service.d/override.conf"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns naming cs-backup.service" out_has "cs-backup.service"
  check "unrelated launcher not named" bash -c '! grep -q "launcher.service" <<<"$1"' _ "$OUT"
  check "cs-backup never touched"     no_call "cs-backup"
  check "launcher never touched"      no_call "launcher"
  check "files all kept"              [ -f "$d/cs-backup.service" ] && [ -f "$d/cs-backup.timer" ]
  run_teardown --purge "code-server"
  check "purge: exits zero"           [ "$CODE" -eq 0 ]
  check "purge: their files kept"     [ -f "$d/cs-backup.service" ] && [ -f "$d/launcher.service" ]
  check "purge: user drop-ins kept"   [ -f "$d/code-server.service.d/override.conf" ]
  check "purge: drop-in rm printed"   out_has "code-server.service.d"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then only the unit file (and empty marker) go"
  deployed
  mkdir -p "$HOME/services/code-server"
  run_teardown --purge "code"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: unit kept"       [ -f "$HOME/.config/systemd/user/code-server.service" ]
  check "wrong name: nothing stopped" no_call "systemctl"
  check "wrong name: serve untouched" no_call " off"
  check "wrong name: marker kept"     [ -d "$HOME/services/code-server" ]
  run_teardown --purge "code-server"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":443 / off via --set-path"   calls_have "serve --https=443 --set-path=/ off"
  check "launcher /home untouched"    no_call "set-path=/home"
  check "unit file gone"              [ ! -e "$HOME/.config/systemd/user/code-server.service" ]
  check "daemon-reload before stop"   [ "$(call_line 'daemon-reload')" -lt "$(call_line 'stop code-server')" ]
  check "stop is the last call"       last_call_is "stop code-server"
  check "empty marker removed"        [ ! -e "$HOME/services/code-server" ]
  check "services dir itself kept" [ -d "$HOME/services" ]
  check "config kept"                 [ -f "$HOME/.config/code-server/config.yaml" ]
  check "extensions kept"             [ -f "$HOME/.local/share/code-server/User-settings.json" ]
  check "binary kept"                 [ -x "$HOME/.local/bin/code-server" ] && [ -d "$HOME/.local/lib/code-server-9.9.9" ]
  check "workspace untouched"         [ -f "$HOME/dev/my-repo/README" ]
  check "prints rm for config"        out_has "rm -rf $HOME/.config/code-server "
  check "prints rm for user data"     out_has "rm -rf $HOME/.local/share/code-server "
  check "prints rm for the binary"    out_has "rm -rf $HOME/.local/lib/code-server-9.9.9 "
  check "prints rm for the bin link"  out_has "rm -rf $HOME/.local/bin/code-server "
  check "never sudo"                  no_call "^sudo "
  check "never touches lingering"     no_call "linger"
  : > "$CALLS_LOG"
  run_teardown --purge "code-server"
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  check "re-run: no disable (no unit)" no_call "disable"
  run_teardown
  check "safe re-run after purge: exits zero" [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_marker_shapes() {
  echo "• teardown --purge: the ~/services/code-server marker is only ever rmdir'd, and only when real"
  deployed
  mkdir -p "$HOME/services/code-server"; echo x > "$HOME/services/code-server/keep"
  run_teardown --purge "code-server"
  check "non-empty marker: exits zero" [ "$CODE" -eq 0 ]
  check "  contents kept"             [ -f "$HOME/services/code-server/keep" ]
  teardown
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  ln -s "$HOME/services/neighbour" "$HOME/services/code-server"
  run_teardown --purge "code-server"
  check "symlinked marker: exits zero" [ "$CODE" -eq 0 ]
  check "  link kept"                 [ -L "$HOME/services/code-server" ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  mkdir -p "$HOME/services"; echo x > "$HOME/services/code-server"
  run_teardown --purge "code-server"
  check "marker is a file: exits zero" [ "$CODE" -eq 0 ]
  check "  file kept"                 [ -f "$HOME/services/code-server" ]
  teardown
  deployed
  rm -rf "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/code-server"
  run_teardown --purge "code-server"
  check "services dir -> \$HOME: exits non-zero" [ "$CODE" -ne 0 ]
  check "  \$HOME/code-server kept"   [ -d "$HOME/code-server" ]
  check "  nothing changed"           no_call "systemctl"
  check "  unit kept"                 [ -f "$HOME/.config/systemd/user/code-server.service" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/code-server survives"
  deployed
  local repo="$HOME/services/code-server/setup-server/services/code-server"
  mkdir -p "$repo"
  cp "$TEARDOWN" "$repo/teardown.sh"
  echo secret > "$HOME/services/code-server/setup-server/other.env"
  OUT="$(printf '%s\n' "code-server" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/code-server/setup-server/other.env" ]
  check "nothing changed"             no_call "systemctl"
  teardown
}

# Run from code-server's integrated terminal, the stop kills teardown.sh
# itself. Every change and the whole summary must already be done by then.
test_teardown_killed_by_stop() {
  echo "• teardown killed by its own stop (run inside code-server): nothing left undone"
  deployed
  mkdir -p "$HOME/services/code-server"
  touch "$STATE_DIR/stop_kills"
  run_teardown --purge "code-server"
  check "purge: really was killed"     [ "$CODE" -ne 0 ]
  check "  :443 / already off"         calls_have "serve --https=443 --set-path=/ off"
  check "  unit already disabled"      calls_have "disable code-server"
  check "  unit file already gone"     [ ! -e "$HOME/.config/systemd/user/code-server.service" ]
  check "  daemon already reloaded"    calls_have "daemon-reload"
  check "  marker already removed"     [ ! -e "$HOME/services/code-server" ]
  check "  rm hints already printed"   out_has "rm -rf $HOME/.config/code-server "
  check "  summary already printed"    out_has "Done."
  check "  stop was the last call"     last_call_is "stop code-server"
  teardown
  deployed
  touch "$STATE_DIR/stop_kills"
  run_teardown
  check "safe: really was killed"      [ "$CODE" -ne 0 ]
  check "  :443 / already off"         calls_have "serve --https=443 --set-path=/ off"
  check "  unit already disabled"      calls_have "disable code-server"
  check "  summary already printed"    out_has "./setup.sh brings it back"
  check "  stop was the last call"     last_call_is "stop code-server"
  teardown
  setup
  export FAKE_OS=Darwin
  run_deploy
  printf 'https://test-host.tailfake.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:8080\n' > "$STATE_DIR/serve_status"
  touch "$STATE_DIR/stop_kills"
  : > "$CALLS_LOG"
  run_teardown
  check "macOS: really was killed"     [ "$CODE" -ne 0 ]
  check "  :443 already off"           calls_have "serve --https=443 off"
  check "  plist already removed"      [ ! -e "$HOME/Library/LaunchAgents/com.coder.code-server.plist" ]
  check "  summary already printed"    out_has "./setup.sh brings it back"
  check "  bootout was the last call"  last_call_is "launchctl bootout"
  teardown
}

test_teardown_macos() {
  echo "• teardown on macOS (FAKE_OS=Darwin): LaunchAgent booted out, plist removed, no systemctl"
  setup
  export FAKE_OS=Darwin
  run_deploy
  check "setup (Darwin) wrote the plist" [ -f "$HOME/Library/LaunchAgents/com.coder.code-server.plist" ]
  printf 'https://test-host.tailfake.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:8080\n|-- /home proxy http://127.0.0.1:8093\n' \
    > "$STATE_DIR/serve_status"
  printf '<plist><string>%s/.local/bin/code-server</string></plist>\n' "$HOME" > "$HOME/Library/LaunchAgents/com.example.cs-helper.plist"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":443 / off via --set-path"   calls_have "serve --https=443 --set-path=/ off"
  check "booted out the agent"        calls_have "launchctl bootout gui/1000/com.coder.code-server"
  check "bootout is the last call"    last_call_is "launchctl bootout"
  check "plist removed (no relaunch at login)" [ ! -e "$HOME/Library/LaunchAgents/com.coder.code-server.plist" ]
  check "other agent named, kept"     out_has "com.example.cs-helper.plist"
  check "  and never touched"         [ -f "$HOME/Library/LaunchAgents/com.example.cs-helper.plist" ]
  check "no systemctl"                no_call "systemctl"
  check "config kept"                 [ -f "$HOME/.config/code-server/config.yaml" ]
  echo log > "$HOME/Library/Logs/code-server.log"
  touch "$STATE_DIR/launchd_not_loaded"
  : > "$CALLS_LOG"
  run_teardown --purge "code-server"
  check "purge re-run: exits zero"    [ "$CODE" -eq 0 ]
  check "  no bootout when not loaded" no_call "bootout"
  check "  prints rm for the log"     out_has "Library/Logs/code-server.log"
  teardown
}

# ------------------------------------------------------------ live suite
live_check() { # live_check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

# Portable helpers: BSD (macOS) tools lack grep -P and ss.
no_external_listener() { # fails if the port listens on a non-loopback address
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | grep ":$port" | grep -v 127.0.0.1 | grep -q LISTEN)
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -v '^127\.0\.0\.1' | grep -q .)
  fi
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^bind-addr: 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$HOME/.config/code-server/config.yaml")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  if [ "$OS" = "Linux" ]; then
    live_check "systemd service is active"      systemctl --user is-active code-server
    live_check "service is enabled at boot"     systemctl --user is-enabled code-server
    live_check "lingering is on (boot persist)" sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "LaunchAgent is loaded"          launchctl print "gui/$(id -u)/com.coder.code-server"
  fi
  live_check "local healthz responds"           curl -fsS "http://127.0.0.1:$port/healthz"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve config present"   sh -c "'$ts' serve status | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS healthz responds"   curl -fsS --max-time 30 "$url/healthz"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_tailscale_down
test_preflight_refuses_root
test_fresh_deploy
test_idempotent_rerun
test_port_override
test_serve_approval_retry
test_teardown_safe
test_teardown_port_shapes
test_teardown_unexpected_path_left_on
test_teardown_not_published
test_teardown_serve_status_fails
test_teardown_port_from_config
test_teardown_config_refused
test_teardown_preflight
test_teardown_refuses_compose_overrides
test_teardown_stop_failures
test_teardown_other_units
test_teardown_purge
test_teardown_purge_marker_shapes
test_teardown_purge_keeps_a_checkout_inside
test_teardown_killed_by_stop
test_teardown_macos

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
