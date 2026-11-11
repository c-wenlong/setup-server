#!/usr/bin/env bash
#
# Tests for services/t3code/setup.sh and services/t3code/teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real scripts from a sandbox copy of this directory
# (so the generated .env never lands in the repo), with a fake $HOME and PATH
# stubs for curl/tailscale/sudo/systemctl/loginctl/launchctl/id/sleep/uname.
# The curl stub answers the releases/latest redirect, writes a REAL tar.gz
# for releases/download (version + target parsed from the asset name), and
# answers health probes. The tailscale stub keeps `serve status` state in
# $STATE_DIR. Nothing touches the real system.

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
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
ARCH="$(uname -m)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# The upstream asset target setup.sh picks for this host (mirrors its case).
expect_target() {
  case "$OS/$ARCH" in
    Linux/x86_64)              echo linux-x64 ;;
    Linux/aarch64|Linux/arm64) echo linux-arm64 ;;
    Darwin/arm64)              echo darwin-arm64 ;;
    *)                         echo unknown ;;
  esac
}
TARGET="$(expect_target)"

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/t3code"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SVC/"
  UNIT="$HOME/.config/systemd/user/t3code.service"
  PLIST="$HOME/Library/LaunchAgents/com.setup-server.t3code.plist"
  INSTALL="$HOME/.local/share/t3code"
  DATA="$HOME/services/t3code"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_OS FAKE_ARCH LOCAL_PORT HTTPS_PORT T3_VERSION STATE_DIR CALLS_LOG
}

# run_deploy [stdin-string] — runs setup.sh under stubs; sets OUT and CODE
run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
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

out_has()    { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -qF -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -qF -- "$1" "$CALLS_LOG"; }
env_has()    { grep -qxF -- "$1" "$SVC/.env"; }
unit_has()   { grep -qF -- "$1" "$UNIT"; }
plist_has()  { grep -qF -- "$1" "$PLIST"; }
ver_is()     { [ "$(cat "$INSTALL/installed-ver" 2>/dev/null)" = "$1" ]; }
live_is()    { [ "$(readlink "$INSTALL/bin" 2>/dev/null)" = "releases/$1" ]; }

# A box that already ran setup.sh once on t3 0.0.1-fake: .env (latest), the
# release, linger + operator, and our own Serve mapping.
pre_deployed() {
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  printf 'LOCAL_PORT=8109\nHTTPS_PORT=8109\nT3_VERSION=latest\n# my-custom-marker\n' > "$SVC/.env"
  mkdir -p "$INSTALL/releases/0.0.1-fake"
  printf '#!/bin/sh\necho "t3 v0.0.1-fake"\n' > "$INSTALL/releases/0.0.1-fake/t3"
  chmod +x "$INSTALL/releases/0.0.1-fake/t3"
  ln -sfn "releases/0.0.1-fake" "$INSTALL/bin"
  echo "0.0.1-fake" > "$INSTALL/installed-ver"
  echo "0.0.1-fake" > "$STATE_DIR/t3_version"
  printf 'https://test-host.tailfake.ts.net:8109 (tailnet only)\n|-- / proxy http://127.0.0.1:8109\n\n' > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
}

# ----------------------------------------------------------------- tests
test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "explains the problem"      out_has "Tailscale is not up"
  check "did not download"          no_call "releases/download"
  check "wrote no .env"             [ ! -e "$SVC/.env" ]
  teardown
}

test_preflight_refuses_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "mentions regular user" out_has "regular user"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path on a clean server"
  setup
  run_deploy
  check "exits zero"                            [ "$CODE" -eq 0 ]
  check ".env: LOCAL_PORT=8109"                 env_has "LOCAL_PORT=8109"
  check ".env: HTTPS_PORT=8109"                 env_has "HTTPS_PORT=8109"
  check ".env: T3_VERSION=latest"               env_has "T3_VERSION=latest"
  check "resolved latest via redirect"          calls_have "releases/latest"
  check "downloaded the $TARGET asset"          calls_have "t3-0.0.0-fake-$TARGET.tar.gz"
  check "release extracted with t3"             [ -x "$INSTALL/releases/0.0.0-fake/t3" ]
  check "bundle siblings present"               [ -d "$INSTALL/releases/0.0.0-fake/node_modules" ]
  check "bin links the release dir"             live_is "0.0.0-fake"
  check "t3 reachable through the link"         [ -x "$INSTALL/bin/t3" ]
  check "records the installed version"         ver_is "0.0.0-fake"
  check "data dir created"                      [ -d "$DATA" ]
  if [ "$OS" = "Linux" ]; then
    check "wrote systemd unit"                  [ -f "$UNIT" ]
    check "unit runs t3 serve loopback-only"    unit_has "ExecStart=\"$INSTALL/bin/t3\" serve \"--host=127.0.0.1\" \"--port=8109\" \"--base-dir=$DATA\""
    check "unit restarts always"                unit_has "Restart=always"
    check "unit PATH puts install dirs first"   unit_has "PATH=$INSTALL/bin:"
    check "enabled the unit"                    calls_have "systemctl --user enable t3code.service"
    check "restarted the unit"                  calls_have "systemctl --user restart t3code.service"
    check "enabled lingering via sudo"          calls_have "sudo loginctl enable-linger"
  else
    check "wrote LaunchAgent plist"             [ -f "$PLIST" ]
    check "plist binds 127.0.0.1"               plist_has "<string>--host=127.0.0.1</string>"
    check "plist passes --base-dir"             plist_has "<string>--base-dir=$DATA</string>"
    check "bootstrapped LaunchAgent"            calls_have "launchctl bootstrap"
    check "no systemd on macOS"                 no_call "systemctl"
  fi
  check "health-checked loopback /"             calls_have "http://127.0.0.1:8109/"
  check "published HTTPS :8109"                 calls_have "tailscale serve --bg --https=8109 http://127.0.0.1:8109"
  check "prints the tailnet URL"                out_has "https://test-host.tailfake.ts.net:8109"
  check "end-to-end check passed"               out_has "End-to-end check passed"
  check "prints pair instructions"              out_has "t3 pair --base-dir"
  check "pair hint uses --tailscale"            out_has "--tailscale --tailscale-serve-port 8109"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run on an up-to-date box: no reinstall, no sudo, .env preserved"
  setup
  pre_deployed
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env left untouched"           grep -q "my-custom-marker" "$SVC/.env"
  check "says config untouched"         out_has "leaving untouched"
  check "says already installed"        out_has "already installed"
  check "did not download"              no_call "releases/download"
  check "never invoked sudo"            no_call "sudo "
  if [ "$OS" = "Linux" ]; then
    check "unit still restarted"        calls_have "systemctl --user restart t3code.service"
  else
    check "LaunchAgent re-bootstrapped" calls_have "launchctl bootstrap"
  fi
  check "serve reapplied over its own mapping" calls_have "tailscale serve --bg --https=8109"
  teardown
}

test_upgrade_when_latest_moves() {
  echo "• re-run after a new release: upgrades and keeps the old one"
  setup
  pre_deployed
  echo "0.0.2-fake" > "$STATE_DIR/t3_version"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "says upgrading"             out_has "Upgrading t3 0.0.1-fake -> 0.0.2-fake"
  check "records the new version"    ver_is "0.0.2-fake"
  check "bin links the new release"  live_is "0.0.2-fake"
  check "new t3 reachable"           [ -x "$INSTALL/bin/t3" ]
  check "keeps the previous release" [ -d "$INSTALL/releases/0.0.1-fake" ]
  teardown
}

test_prunes_old_releases() {
  echo "• upgrade keeps only the live and the previous release"
  setup
  pre_deployed
  mkdir -p "$INSTALL/releases/9.9.9-ancient"
  echo "0.0.2-fake" > "$STATE_DIR/t3_version"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "ancient release pruned"  [ ! -e "$INSTALL/releases/9.9.9-ancient" ]
  check "previous release kept"   [ -d "$INSTALL/releases/0.0.1-fake" ]
  teardown
}

test_failed_download_keeps_live() {
  echo "• download failure during upgrade: the live release stays in place"
  setup
  pre_deployed
  echo "0.0.2-fake" > "$STATE_DIR/t3_version"
  touch "$STATE_DIR/t3_download_fails"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "says download failed"       out_has "Download failed"
  check "bin still links the old"    live_is "0.0.1-fake"
  check "installed-ver unchanged"    ver_is "0.0.1-fake"
  check "no half-installed release"  [ ! -e "$INSTALL/releases/0.0.2-fake" ]
  check "no service restart"         no_call "restart t3code"
  teardown
}

test_tarball_without_t3() {
  echo "• tarball missing the t3 binary: refused, live release untouched"
  setup
  pre_deployed
  echo "0.0.2-fake" > "$STATE_DIR/t3_version"
  touch "$STATE_DIR/t3_no_binary"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says no runnable t3"     out_has "no runnable t3 binary"
  check "bin still links the old" live_is "0.0.1-fake"
  check "installed-ver unchanged" ver_is "0.0.1-fake"
  teardown
}

test_pin_by_version() {
  echo "• T3_VERSION=0.1.8 pins without asking for latest"
  setup
  export T3_VERSION="0.1.8"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no releases/latest lookup"     no_call "releases/latest"
  check "downloaded the pinned asset"   calls_have "t3-0.1.8-$TARGET.tar.gz"
  check "records the pin"               ver_is "0.1.8"
  check ".env records the pin"          env_has "T3_VERSION=0.1.8"
  teardown
}

test_explicit_version_beats_env() {
  echo "• an explicit T3_VERSION overrides .env for one run, .env unchanged"
  setup
  pre_deployed
  export T3_VERSION="0.0.2-fake"
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "installed the pinned ver" ver_is "0.0.2-fake"
  check ".env still tracks latest" env_has "T3_VERSION=latest"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT override on first run"
  setup
  export LOCAL_PORT=8200
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env: LOCAL_PORT=8200"         env_has "LOCAL_PORT=8200"
  check ".env: HTTPS_PORT follows"      env_has "HTTPS_PORT=8200"
  if [ "$OS" = "Linux" ]; then
    check "unit uses the override"       unit_has "--port=8200"
  else
    check "plist uses the override"      plist_has "<string>--port=8200</string>"
  fi
  check "published on :8200"            calls_have "tailscale serve --bg --https=8200 http://127.0.0.1:8200"
  teardown
}

test_pair_hint_uses_https_port() {
  echo "• pair hint uses HTTPS_PORT when it differs from LOCAL_PORT"
  setup
  export LOCAL_PORT=8200 HTTPS_PORT=8300
  run_deploy
  check "exits zero"                       [ "$CODE" -eq 0 ]
  check "published :8300 -> :8200"         calls_have "tailscale serve --bg --https=8300 http://127.0.0.1:8200"
  check "hint passes the https port"       out_has "--tailscale --tailscale-serve-port 8300"
  check "hint does not use the local port" out_lacks "--tailscale-serve-port 8200"
  teardown
}

test_env_wins_over_port() {
  echo "• .env wins over environment variables on a re-run"
  setup
  pre_deployed
  export LOCAL_PORT=9999 HTTPS_PORT=9998
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns the override ignored" out_has "ignored"
  if [ "$OS" = "Linux" ]; then
    check "unit still on :8109"       unit_has "--port=8109"
  fi
  check "published :8109 not :9998"  calls_have "tailscale serve --bg --https=8109"
  check "never touched :9998"        no_call "https=9998"
  teardown
}

test_local_port_change_cleans_stale_mapping() {
  echo "• LOCAL_PORT change: the stale Serve mapping is removed, not treated as foreign"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  sed -i 's/^LOCAL_PORT=8109/LOCAL_PORT=8200/' "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "stale :8109 mapping removed"    calls_have "tailscale serve --https=8109 off"
  check "republished :8109 -> :8200"     calls_have "tailscale serve --bg --https=8109 http://127.0.0.1:8200"
  check "serve-map records the new pair" [ "$(cat "$INSTALL/serve-map" 2>/dev/null)" = "8109 8200" ]
  teardown
}

test_refuses_443() {
  echo "• HTTPS_PORT=443 is refused (code-server owns / there)"
  setup
  export HTTPS_PORT=443
  run_deploy
  check "exits non-zero"   [ "$CODE" -ne 0 ]
  check "explains why"     out_has "HTTPS_PORT=443"
  check "did not download" no_call "releases/download"
  teardown
}

test_serve_port_taken() {
  echo "• refuses to publish over a Serve port owned by another target"
  setup
  printf 'https://test-host.tailfake.ts.net:8109 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "says who owns it"       out_has "already published"
  check "did not download"       no_call "releases/download"
  check "did not publish"        no_call "serve --bg"
  teardown
}

test_never_healthy() {
  echo "• t3 never answers on loopback: deploy fails after the retries"
  setup
  touch "$STATE_DIR/t3_down"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "says it did not answer" out_has "did not answer"
  teardown
}

test_serve_approval_retry() {
  echo "• first publish denied: grants operator via sudo, retries, succeeds"
  setup
  echo "1" > "$STATE_DIR/serve_fails_left"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "granted operator via sudo"   calls_have "sudo tailscale set --operator="
  fi
  check "serve retried and published"  calls_have "tailscale serve --bg --https=8109"
  teardown
}

test_bad_tarball() {
  echo "• a corrupt download is refused before touching the install"
  setup
  touch "$STATE_DIR/t3_bad_tarball"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "no release installed" [ ! -e "$INSTALL/releases" ]
  teardown
}

test_darwin_arm64() {
  echo "• macOS arm64 branch: LaunchAgent instead of systemd"
  if [ "$OS" != "Darwin" ]; then
    echo "    (skipped on Linux — test_fake_darwin_arm64 covers the branch)"
    return
  fi
  setup
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "wrote plist"               [ -f "$PLIST" ]
  check "plist has RunAtLoad"       plist_has "<key>RunAtLoad</key>"
  teardown
}

test_fake_darwin_arm64() {
  echo "• FAKE_OS=Darwin FAKE_ARCH=arm64: plist branch works on any host"
  setup
  export FAKE_OS=Darwin FAKE_ARCH=arm64
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "wrote LaunchAgent plist"        [ -f "$PLIST" ]
  check "plist runs t3 serve"            plist_has "<string>serve</string>"
  check "plist binds 127.0.0.1"          plist_has "<string>--host=127.0.0.1</string>"
  check "plist has --base-dir"           plist_has "<string>--base-dir=$DATA</string>"
  check "plist PATH includes nix dirs"   plist_has ".nix-profile/bin"
  check "bootstrapped LaunchAgent"       calls_have "launchctl bootstrap"
  check "bootout attempted first"        calls_have "launchctl bootout"
  check "no systemctl on Darwin"          no_call "systemctl"
  check "no lingering on Darwin"          no_call "loginctl"
  check "downloaded darwin-arm64 asset"  calls_have "t3-0.0.0-fake-darwin-arm64.tar.gz"
  check "published HTTPS :8109"           calls_have "tailscale serve --bg --https=8109 http://127.0.0.1:8109"
  check "end-to-end check passed"         out_has "End-to-end check passed"
  teardown
}

test_fake_darwin_x86_64_refused() {
  echo "• FAKE_OS=Darwin on x86_64: refused (no upstream Intel-Mac build)"
  setup
  export FAKE_OS=Darwin   # FAKE_ARCH unset -> real arch (x86_64 on CI/dev boxes)
  [ "$ARCH" = "arm64" ] && export FAKE_ARCH=x86_64
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "explains no build"       out_has "No upstream t3 build"
  check "wrote no .env"           [ ! -e "$SVC/.env" ]
  teardown
}

# ------------------------------------------------------------- teardown
# run_teardown [flag] [stdin line] — runs teardown.sh under stubs; sets OUT and CODE
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run, Serve maps :8109 to t3, and
# neighbours sit on other ports (one a lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8109 (tailnet only)
|-- / proxy http://127.0.0.1:8109

https://test-host.tailfake.ts.net:18109 (tailnet only)
|-- / proxy http://127.0.0.1:18109
EOF
  mkdir -p "$DATA/userdata"
  echo '{"projects":[]}' > "$DATA/userdata/state.json"
  : > "$CALLS_LOG"
}

# The file setup.sh wrote to supervise t3 on this platform.
unit_file() { if [ "$OS" = "Linux" ]; then echo "$UNIT"; else echo "$PLIST"; fi; }
stopped()     { if [ "$OS" = "Linux" ]; then calls_have "systemctl --user disable --now t3code.service"; else calls_have "launchctl bootout"; fi; }
not_stopped() { no_call "disable --now" && no_call "bootout"; }
data_kept()   { [ -f "$DATA/userdata/state.json" ]; }

test_teardown_safe() {
  echo "• teardown: safe remove stops t3, unpublishes only its port, keeps everything"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8109"         calls_have "tailscale serve --https=8109 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18109 untouched"  no_call "https=18109"
  check "never serve reset"           no_call "serve reset"
  check "t3 stopped and disabled"     stopped
  if [ "$OS" = "Linux" ]; then
    check "unit file kept"            [ -f "$UNIT" ]
    check "no daemon-reload (unit kept)" no_call "daemon-reload"
  else
    check "plist removed (would restart at login)" [ ! -e "$PLIST" ]
  fi
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "data kept"                   data_kept
  check "release kept"                [ -x "$INSTALL/bin/t3" ]
  check "lingering untouched"         no_call "loginctl"
  check "operator untouched"          no_call "tailscale set"
  check "no sudo"                     no_call "sudo"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  check "its own unit is not listed as foreign" out_lacks "NOT written by setup.sh"
  : > "$CALLS_LOG"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  check "re-run: nothing left to unpublish" out_has "already off"
  run_deploy
  check "./setup.sh brings it back"   [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_unpublishes_previous_port() {
  echo "• teardown: a stale mapping on the previous local port also goes off"
  deployed
  sed -i 's/^LOCAL_PORT=8109/LOCAL_PORT=8200/' "$SVC/.env"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "stale :8109 unpublished"   calls_have "tailscale serve --https=8109 off"
  check "neighbour :2283 untouched" no_call "https=2283"
  check "lookalike :18109 untouched" no_call "https=18109"
  teardown
}

test_teardown_custom_https_port() {
  echo "• teardown: an HTTPS port other than LOCAL_PORT is found from serve status"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "serve off for :9443"     calls_have "tailscale serve --https=9443 off"
  check "no :8109 off"            no_call "https=8109"
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"           [ "$CODE" -eq 0 ]
  check "no serve off"         no_call " off"
  check "says already off"     out_has "already off"
  check "still stops t3"       stopped
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: leaves a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8109 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"           [ "$CODE" -eq 0 ]
  check "no serve off"         no_call " off"
  check "says nothing points here" out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8108 (tailnet only)
|-- / proxy http://127.0.0.1:8109

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8109

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /t3 proxy http://127.0.0.1:8109
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8108 off"                   calls_have "serve --https=8108 off"
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
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "says why"             out_has "Could not read Tailscale Serve status"
  check "t3 not stopped"       not_stopped
  check "nothing unpublished"  no_call " off"
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"  [ "$CODE" -ne 0 ]
  check "no .env: explains"        out_has "nothing to tear down"
  check "no .env: touched nothing" not_stopped
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"     [ "$CODE" -ne 0 ]
  check "root: t3 not stopped"     not_stopped
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: t3 not stopped"  not_stopped
  OUT="$(printf '\n' | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge extra 2>&1)"; CODE=$?
  check "too many args: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: a malformed .env line is refused, not guessed"
  deployed
  printf 'this is not KEY=value\n' >> "$SVC/.env"
  run_teardown
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "says which line"      out_has "is not KEY=value"
  check "t3 not stopped"       not_stopped
  check ".env kept"            [ -f "$SVC/.env" ]
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "t3code"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  nothing stopped"           not_stopped
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: deletes .env, unit and ~/services/t3code after confirmation"
  deployed
  run_teardown --purge "t3code"
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "serve unpublished first"  calls_have "tailscale serve --https=8109 off"
  check ".env deleted"             [ ! -e "$SVC/.env" ]
  check "data dir deleted"         [ ! -e "$DATA" ]
  if [ "$OS" = "Linux" ]; then
    check "unit file deleted"      [ ! -e "$UNIT" ]
    check "daemon-reload after rm" calls_have "daemon-reload"
  else
    check "plist deleted"          [ ! -e "$PLIST" ]
  fi
  check "release kept"             [ -x "$INSTALL/bin/t3" ]
  check "says release is kept"     out_has "release in $INSTALL"
  teardown
}

test_teardown_purge_wrong_confirmation() {
  echo "• teardown --purge: a wrong confirmation changes nothing"
  deployed
  run_teardown --purge "wrong-name"
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "says nothing changed"  out_has "nothing was changed"
  check ".env kept"             [ -f "$SVC/.env" ]
  check "data kept"             data_kept
  check "unit kept"             [ -f "$(unit_file)" ]
  check "not stopped"           not_stopped
  check "nothing unpublished"   no_call " off"
  teardown
}

test_teardown_purge_symlinked_data() {
  echo "• teardown --purge: a symlinked data dir is left alone, rest still purged"
  deployed
  mv "$DATA" "$DATA.real"
  ln -s "$DATA.real" "$DATA"
  run_teardown --purge "t3code"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns the symlink is kept"   out_has "is a symlink; it is left alone"
  check "symlink target survives"     [ -f "$DATA.real/userdata/state.json" ]
  check ".env deleted"                [ ! -e "$SVC/.env" ]
  teardown
}

test_teardown_purge_data_is_file() {
  echo "• teardown --purge: data path that is not a directory is refused"
  deployed
  rm -rf "$DATA"
  echo x > "$DATA"
  run_teardown --purge "t3code"
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "says refusing"        out_has "not a directory"
  check ".env kept"            [ -f "$SVC/.env" ]
  check "file kept"            [ -f "$DATA" ]
  teardown
}

# ------------------------------------------------------------------ live
live_check() { # live_check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

# Every listener on $port must be loopback or Tailscale's own tailnet
# address, never a wildcard or a LAN interface. HTTPS is published on the
# same number as the local port (8109 -> 8109), so tailscaled legitimately
# listens on the tailnet IP for it; same helper as app/web/tests.
no_external_listener() {
  local port="$1" addrs addr host ts ts4 ts6
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  ts4="$("$ts" ip -4 2>/dev/null || true)"
  ts6="$("$ts" ip -6 2>/dev/null || true)"

  if command -v ss >/dev/null; then
    addrs="$(ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}')"
  elif command -v lsof >/dev/null; then
    addrs="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
  else
    return 1   # cannot inspect listeners — fail loudly, not vacuously
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
    host="${host%%\%*}"                          # drop the %tailscale0 zone id
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

serve_maps() { # serve_maps <https url> <target>: that port's / proxies target
  local ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  "$ts" serve status 2>/dev/null | awk -v hdr="$1 " -v want="$2" '
    index($0, hdr) == 1 { inblk = 1; next }
    /^https?:\/\// { inblk = 0 }
    inblk && $2 == "/" && $3 == "proxy" && $4 == want { found = 1 }
    END { exit !found }'
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local local_port https_port host url ts
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  local_port="$(sed -n 's/^LOCAL_PORT=//p' "$SERVICE_DIR/.env" 2>/dev/null)"
  https_port="$(sed -n 's/^HTTPS_PORT=//p' "$SERVICE_DIR/.env" 2>/dev/null)"
  https_port="${https_port:-$local_port}"
  host="$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  url="https://$host:$https_port"
  live_check ".env present with LOCAL_PORT"       [ -n "$local_port" ]
  live_check "t3 release recorded"                [ -s "$HOME/.local/share/t3code/installed-ver" ]
  live_check "bin links the recorded release"     sh -c "case \"\$(readlink '$HOME/.local/share/t3code/bin')\" in releases/\$(cat '$HOME/.local/share/t3code/installed-ver')) exit 0;; esac; exit 1"
  live_check "t3 binary runs"                     "$HOME/.local/share/t3code/bin/t3" --version
  if [ "$OS" = "Linux" ]; then
    live_check "systemd service is active"        systemctl --user is-active t3code.service
    live_check "service is enabled at boot"       systemctl --user is-enabled t3code.service
    live_check "lingering is on (boot persist)"   sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
    live_check "unit binds 127.0.0.1"             grep -q -- '"--host=127.0.0.1"' "$HOME/.config/systemd/user/t3code.service"
    live_check "unit uses the local port"         grep -q -- "\"--port=$local_port\"" "$HOME/.config/systemd/user/t3code.service"
    live_check "unit passes --base-dir"           grep -q -- "\"--base-dir=$HOME/services/t3code\"" "$HOME/.config/systemd/user/t3code.service"
  else
    live_check "LaunchAgent is loaded"            launchctl print "gui/$(id -u)/com.setup-server.t3code"
  fi
  live_check "local / answers"                    curl -fsS -o /dev/null --max-time 10 "http://127.0.0.1:$local_port/"
  live_check "not listening on non-local ifaces"  no_external_listener "$local_port"
  live_check "tailscale serve maps the port"      serve_maps "$url" "http://127.0.0.1:$local_port"
  live_check "tailnet HTTPS / answers"            curl -fsS -o /dev/null --max-time 30 "$url/"
  live_check "data dir exists"                    [ -d "$HOME/services/t3code" ]
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_tailscale_down
test_preflight_refuses_root
test_fresh_deploy
test_idempotent_rerun
test_upgrade_when_latest_moves
test_prunes_old_releases
test_failed_download_keeps_live
test_tarball_without_t3
test_pin_by_version
test_explicit_version_beats_env
test_port_override
test_pair_hint_uses_https_port
test_env_wins_over_port
test_local_port_change_cleans_stale_mapping
test_refuses_443
test_serve_port_taken
test_never_healthy
test_serve_approval_retry
test_bad_tarball
test_darwin_arm64
test_fake_darwin_arm64
test_fake_darwin_x86_64_refused
test_teardown_safe
test_teardown_unpublishes_previous_port
test_teardown_custom_https_port
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge
test_teardown_purge_wrong_confirmation
test_teardown_purge_symlinked_data
test_teardown_purge_data_is_file

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
