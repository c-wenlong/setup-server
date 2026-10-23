#!/usr/bin/env bash
#
# Tests for quiver-hub/setup.sh and quiver-hub/pair.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real scripts from a sandbox copy of this directory
# (so the generated .env never lands in the repo), with a fake $HOME and PATH
# stubs for curl/git/uv/tailscale/sudo/systemctl/loginctl/launchctl/id/sleep
# plus an old interactive `swe`. The uv stub "installs" a fake hub swe; the git
# stub answers ls-remote for main and a tag. Stubs log every call to $CALLS_LOG
# and keep state in $STATE_DIR. Nothing touches the real system.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

MAIN_SHA="1111111111111111111111111111111111111111"
REPO="https://github.com/c-wenlong/quiver.git"

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/pair.sh" "$SVC/"
  UNIT="$HOME/.config/systemd/user/quiver-hub.service"
  PLIST="$HOME/Library/LaunchAgents/com.setup-server.quiver-hub.plist"
  INSTALL="$HOME/.local/share/quiver-hub"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT QUIVER_REF STATE_DIR CALLS_LOG
}

# run_deploy [stdin-string] — runs setup.sh under stubs; sets OUT and CODE
run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# run_pair [name] — runs pair.sh under stubs; sets OUT and CODE
run_pair() {
  OUT="$(PATH="$STUBS:$PATH" bash "$SVC/pair.sh" "$@" 2>&1)"
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
uv_spec_is() { [ "$(cat "$STATE_DIR/uv_spec" 2>/dev/null)" = "$1" ]; }
rev_is()     { [ "$(cat "$INSTALL/installed-rev" 2>/dev/null)" = "$1" ]; }
live_is()    { [ "$(readlink "$INSTALL/bin" 2>/dev/null)" = "releases/$1/bin" ]; }

# A box that already ran setup.sh once: .env, the hub build, linger + operator.
pre_deployed() {
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  printf 'LOCAL_PORT=8477\nHTTPS_PORT=8477\nQUIVER_REF=main\n# my-custom-marker\n' > "$SVC/.env"
  UV_TOOL_BIN_DIR="$INSTALL/releases/$MAIN_SHA/bin" PATH="$STUBS:$PATH" uv tool install x >/dev/null
  ln -s "releases/$MAIN_SHA/bin" "$INSTALL/bin"
  echo "$MAIN_SHA" > "$INSTALL/installed-rev"
  printf 'https://test-host.tailfake.ts.net:8477 (tailnet only)\n|-- / proxy http://127.0.0.1:8477\n\n' > "$STATE_DIR/serve_status"
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
  check "did not install anything"  no_call "uv "
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
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env: LOCAL_PORT=8477"              env_has "LOCAL_PORT=8477"
  check ".env: HTTPS_PORT=8477"              env_has "HTTPS_PORT=8477"
  check ".env: QUIVER_REF=main"              env_has "QUIVER_REF=main"
  check "resolved main with ls-remote"       calls_have "git ls-remote $REPO refs/heads/main"
  check "uv installs the resolved commit"    uv_spec_is "quiver @ git+$REPO@$MAIN_SHA"
  check "installs into a per-commit release" [ -x "$INSTALL/releases/$MAIN_SHA/bin/swe" ]
  check "bin links to that release"          live_is "$MAIN_SHA"
  check "hub swe reachable through the link" [ -x "$INSTALL/bin/swe" ]
  check "records the installed commit"       rev_is "$MAIN_SHA"
  check "checked the build has swe remote"   calls_have "hub-swe remote"
  if [ "$OS" = "Linux" ]; then
    check "wrote systemd unit"               [ -f "$UNIT" ]
    check "unit binds 127.0.0.1:8477"        unit_has "ExecStart=$INSTALL/bin/swe remote serve --host=127.0.0.1 --port=8477 "
    check "unit passes the public https URL" unit_has "--public-url=https://test-host.tailfake.ts.net:8477"
    check "unit restarts always"             unit_has "Restart=always"
    check "unit PATH puts the hub build first" unit_has "Environment=PATH=$INSTALL/bin:"
    check "enabled the unit"                 calls_have "systemctl --user enable quiver-hub.service"
    check "restarted the unit"               calls_have "systemctl --user restart quiver-hub.service"
    check "enabled lingering via sudo"       calls_have "sudo loginctl enable-linger"
    check "granted operator via sudo"        calls_have "sudo tailscale set --operator="
  else
    check "wrote LaunchAgent plist"          [ -f "$PLIST" ]
    check "plist binds 127.0.0.1"            plist_has "<string>--host=127.0.0.1</string>"
    check "plist passes the public URL"      plist_has "<string>--public-url=https://test-host.tailfake.ts.net:8477</string>"
    check "bootstrapped LaunchAgent"         calls_have "launchctl bootstrap"
  fi
  check "health-checked /v1/status"          calls_have "http://127.0.0.1:8477/v1/status"
  check "published HTTPS :8477"              calls_have "tailscale serve --bg --https=8477 http://127.0.0.1:8477"
  check "prints the tailnet URL"             out_has "https://test-host.tailfake.ts.net:8477"
  check "end-to-end check passed"            out_has "End-to-end check passed"
  check "prints the pair.sh step"            out_has "pair.sh iphone"
  check "prints the satellite command"       out_has "swe remote agent --hub=https://test-host.tailfake.ts.net:8477 --token=<token>"
  check "warns the PATH swe is too old"      out_has "predates 'swe remote serve --public-url'"
  check "prints Pair with Tailscale steps"   out_has "tap 'Pair with Tailscale'"
  check "prints the approve command"         out_has "remote devices --approve=<code>"
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
  check "did not reinstall"             no_call "uv tool install"
  check "never invoked sudo"            no_call "sudo "
  if [ "$OS" = "Linux" ]; then
    check "unit still restarted"        calls_have "systemctl --user restart quiver-hub.service"
  else
    check "LaunchAgent re-bootstrapped" calls_have "launchctl bootstrap"
  fi
  check "serve reapplied over its own mapping" calls_have "tailscale serve --bg --https=8477"
  teardown
}

test_upgrade_when_main_moves() {
  echo "• re-run after main moved: reinstalls the new commit"
  setup
  pre_deployed
  echo "4444444444444444444444444444444444444444" > "$STATE_DIR/main_sha"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "says upgrading"        out_has "Upgrading quiver 111111111111 -> 444444444444"
  check "installs the new tip"  uv_spec_is "quiver @ git+$REPO@4444444444444444444444444444444444444444"
  check "records the new tip"   rev_is "4444444444444444444444444444444444444444"
  check "bin links the new tip" live_is "4444444444444444444444444444444444444444"
  check "keeps the previous release for rollback" [ -d "$INSTALL/releases/$MAIN_SHA" ]
  teardown
}

test_prunes_old_releases() {
  echo "• upgrade keeps only the live and the previous release"
  setup
  pre_deployed
  mkdir -p "$INSTALL/releases/9999999999999999999999999999999999999999/bin"
  echo "4444444444444444444444444444444444444444" > "$STATE_DIR/main_sha"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "older release pruned"       [ ! -e "$INSTALL/releases/9999999999999999999999999999999999999999" ]
  check "previous release kept"      [ -d "$INSTALL/releases/$MAIN_SHA" ]
  teardown
}

test_rejected_upgrade_keeps_live_build() {
  echo "• upgrade to a ref without swe remote: the live build stays in place"
  setup
  pre_deployed
  echo "4444444444444444444444444444444444444444" > "$STATE_DIR/main_sha"
  touch "$STATE_DIR/old_swe"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "says the build is unchanged" out_has "installed build is unchanged"
  check "bin still links the old build" live_is "$MAIN_SHA"
  check "installed-rev unchanged"    rev_is "$MAIN_SHA"
  check "rejected release removed"   [ ! -e "$INSTALL/releases/4444444444444444444444444444444444444444" ]
  check "live build still has swe remote" grep -q "OLD=no" "$INSTALL/bin/swe"
  check "no service restart"         no_call "restart quiver-hub"
  check "no LaunchAgent reload"      no_call "launchctl bootstrap"
  teardown
}

test_failed_upgrade_keeps_live_build() {
  echo "• uv fails during an upgrade: the live build stays in place"
  setup
  pre_deployed
  echo "4444444444444444444444444444444444444444" > "$STATE_DIR/main_sha"
  touch "$STATE_DIR/uv_fails"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "bin still links the old build" live_is "$MAIN_SHA"
  check "installed-rev unchanged"    rev_is "$MAIN_SHA"
  check "no half-installed release"  [ ! -e "$INSTALL/releases/4444444444444444444444444444444444444444" ]
  check "no service restart"         no_call "restart quiver-hub"
  teardown
}

test_forced_reinstall_failure_keeps_live_build() {
  echo "• forced reinstall of the live commit fails: the live build survives"
  setup
  pre_deployed
  rm "$INSTALL/installed-rev"
  touch "$STATE_DIR/uv_fails"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "bin still links the live build" live_is "$MAIN_SHA"
  check "live build still on disk"     [ -x "$INSTALL/bin/swe" ]
  check "no service restart"           no_call "restart quiver-hub"
  teardown
}

test_forced_reinstall_success() {
  echo "• forced reinstall of the live commit: fresh dir, then the link moves"
  setup
  pre_deployed
  rm "$INSTALL/installed-rev"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  link_is_fresh() { case "$(readlink "$INSTALL/bin")" in "releases/$MAIN_SHA."*/bin) return 0 ;; esac; return 1; }
  check "bin links a fresh dir for the same commit" link_is_fresh
  check "new build reachable"          [ -x "$INSTALL/bin/swe" ]
  check "installed-rev restored"       rev_is "$MAIN_SHA"
  check "replaced build kept"          [ -d "$INSTALL/releases/$MAIN_SHA" ]
  teardown
}

test_migrates_flat_layout() {
  echo "• upgrade from the first layout (real bin/ and tools/ dirs) to releases/"
  setup
  pre_deployed
  rm "$INSTALL/bin"
  mkdir -p "$INSTALL/bin" "$INSTALL/tools/quiver"
  cp "$INSTALL/releases/$MAIN_SHA/bin/swe" "$INSTALL/bin/swe"
  rm -rf "$INSTALL/releases"
  echo "4444444444444444444444444444444444444444" > "$STATE_DIR/main_sha"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "bin is now a link"          live_is "4444444444444444444444444444444444444444"
  check "old tools/ dir removed"     [ ! -e "$INSTALL/tools" ]
  teardown
}

test_pin_by_sha() {
  echo "• QUIVER_REF=<sha> pins without asking GitHub"
  setup
  export QUIVER_REF="abcdefabcdefabcdefabcdefabcdefabcdefabcd"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "no ls-remote"        no_call "git ls-remote"
  check "installs that sha"   uv_spec_is "quiver @ git+$REPO@$QUIVER_REF"
  check ".env records it"     env_has "QUIVER_REF=$QUIVER_REF"
  teardown
}

test_pin_by_tag() {
  echo "• QUIVER_REF=v1.2.3 resolves the annotated tag to its commit"
  setup
  export QUIVER_REF="v1.2.3"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "installs the peeled commit" uv_spec_is "quiver @ git+$REPO@2222222222222222222222222222222222222222"
  teardown
}

test_explicit_ref_beats_env() {
  echo "• an explicit QUIVER_REF overrides .env for one run, .env unchanged"
  setup
  pre_deployed
  export QUIVER_REF="v1.2.3"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "installs the tag's commit"  uv_spec_is "quiver @ git+$REPO@2222222222222222222222222222222222222222"
  check ".env still says main"       env_has "QUIVER_REF=main"
  teardown
}

test_unknown_ref() {
  echo "• unknown QUIVER_REF: clear failure, nothing installed"
  setup
  export QUIVER_REF="no-such-branch"
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "names the ref"      out_has "No branch or tag named 'no-such-branch'"
  check "did not install"    no_call "uv tool install"
  teardown
}

test_github_unreachable() {
  echo "• ls-remote fails: clear failure, nothing installed"
  setup
  touch "$STATE_DIR/git_fails"
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "explains"           out_has "git ls-remote $REPO failed"
  check "did not install"    no_call "uv tool install"
  teardown
}

test_uv_failure() {
  echo "• uv install fails: stops before touching the service"
  setup
  touch "$STATE_DIR/uv_fails"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "explains"               out_has "uv tool install failed"
  check "no installed-rev"       [ ! -e "$INSTALL/installed-rev" ]
  check "no service restart"     no_call "restart quiver-hub"
  teardown
}

test_too_old_quiver() {
  echo "• a ref without swe remote: refuses to install a crash-looping unit"
  setup
  touch "$STATE_DIR/old_swe"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "says too old"           out_has "too old"
  check "no live build linked"   [ ! -e "$INSTALL/bin" ]
  check "no installed-rev"       [ ! -e "$INSTALL/installed-rev" ]
  check "no unit written"        [ ! -e "$UNIT" ]
  check "no LaunchAgent written" [ ! -e "$PLIST" ]
  teardown
}

test_quiver_without_public_url() {
  echo "• a ref with swe remote but no --public-url: refused (the unit needs it)"
  setup
  touch "$STATE_DIR/no_public_url"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "names the missing flag" out_has "needs 6c70755 or later"
  check "no live build linked"   [ ! -e "$INSTALL/bin" ]
  check "no unit written"        [ ! -e "$UNIT" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT=9000 on first run: HTTPS follows, both recorded"
  setup
  export LOCAL_PORT=9000
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check ".env LOCAL_PORT=9000"    env_has "LOCAL_PORT=9000"
  check ".env HTTPS_PORT=9000"    env_has "HTTPS_PORT=9000"
  check "serve publishes :9000"   calls_have "tailscale serve --bg --https=9000 http://127.0.0.1:9000"
  [ "$OS" = "Linux" ] && check "unit binds :9000" unit_has "--host=127.0.0.1 --port=9000"
  [ "$OS" = "Linux" ] && check "public URL follows :9000" unit_has "--public-url=https://test-host.tailfake.ts.net:9000"
  teardown
}

test_env_wins_over_port() {
  echo "• re-run with a different LOCAL_PORT: .env wins, with a warning"
  setup
  pre_deployed
  export LOCAL_PORT=9000
  run_deploy
  check "exits zero"           [ "$CODE" -eq 0 ]
  check "warns it is ignored"  out_has "LOCAL_PORT=9000 ignored"
  check "still serves :8477"   calls_have "tailscale serve --bg --https=8477 http://127.0.0.1:8477"
  no_call_9000() { no_call "--https=9000"; }
  check "never published :9000" no_call_9000
  teardown
}

test_refuses_443() {
  echo "• HTTPS_PORT=443 refused (would replace code-server's / handler)"
  setup
  export HTTPS_PORT=443
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "explains"           out_has "HTTPS_PORT=443"
  check "never served"       no_call "tailscale serve --bg"
  teardown
}

test_serve_port_taken() {
  echo "• HTTPS port already published for another backend: refuses"
  setup
  printf 'https://test-host.tailfake.ts.net:8477 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n\n' > "$STATE_DIR/serve_status"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "names the other target" out_has "already published for http://127.0.0.1:9999"
  check "never served"           no_call "tailscale serve --bg"
  check "installed nothing"      no_call "uv tool install"
  teardown
}

test_hub_never_healthy() {
  echo "• hub never answers /v1/status: fails with the log command"
  setup
  touch "$STATE_DIR/hub_down"
  run_deploy
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "says it did not answer" out_has "did not answer"
  if [ "$OS" = "Linux" ]; then
    check "points at journalctl" out_has "journalctl --user -u quiver-hub.service"
  fi
  check "did not publish"    no_call "tailscale serve --bg"
  teardown
}

test_serve_approval_retry() {
  echo "• serve not yet enabled on tailnet: approval prompt + retry loop"
  setup
  echo 2 > "$STATE_DIR/serve_fails_left"   # fail twice, succeed on 3rd attempt
  run_deploy $'\n'                         # press Enter at the approval prompt
  check "exits zero after retry"     [ "$CODE" -eq 0 ]
  check "showed the approval prompt" out_has "one-time enablement"
  check "eventually published"       out_has "Tailscale Serve: HTTPS :8477"
  [ "$OS" = "Linux" ] && check "granted operator on 1st failure" calls_have "sudo tailscale set --operator="
  teardown
}

test_pair_before_deploy() {
  echo "• pair.sh before setup.sh: points at setup.sh"
  setup
  run_pair
  check "exits non-zero"     [ "$CODE" -ne 0 ]
  check "says deploy first"  out_has "deploy first"
  teardown
}

test_pair_prints_https_links() {
  echo "• pair.sh: mints a token and prints the https Serve links"
  setup
  pre_deployed
  run_pair iphone
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "minted via the hub build"  calls_have "hub-swe remote pair --json --name=iphone"
  check "lets swe pick the address" no_call "remote pair --json --host"
  check "phone link is https Serve" out_has "https://test-host.tailfake.ts.net:8477/#pair=FAKETOKEN123&name=iphone"
  check "never the http bind link"  out_lacks "http://127.0.0.1:8477/#pair"
  check "satellite command"         out_has "swe remote agent --hub=https://test-host.tailfake.ts.net:8477 --token=FAKETOKEN123"
  check "raw token for typing in"   out_has "token:   FAKETOKEN123"
  teardown
}

test_pair_refuses_http_link() {
  echo "• pair.sh: an http link (hub without --public-url) is refused"
  setup
  pre_deployed
  echo "http://127.0.0.1:8477/#pair=FAKETOKEN123" > "$STATE_DIR/pair_url"
  run_pair
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "says to re-run setup"  out_has "Re-run"
  check "never prints the link as the phone link" out_lacks "Phone:"
  teardown
}

test_pair_custom_https_port() {
  echo "• pair.sh uses whatever https address swe reports"
  setup
  pre_deployed
  echo "https://test-host.tailfake.ts.net:9443/#pair=FAKETOKEN123" > "$STATE_DIR/pair_url"
  run_pair
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "link uses :9443"       out_has "https://test-host.tailfake.ts.net:9443/#pair=FAKETOKEN123"
  check "satellite uses :9443"  out_has "--hub=https://test-host.tailfake.ts.net:9443 --token"
  check "no name without arg"   no_call "--name="
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

# Every listener on $port must be loopback or Tailscale's own tailnet
# address, never a wildcard or a LAN interface. HTTPS is published on the
# same number as the local port (8477 -> 8477), so tailscaled legitimately
# listens on the tailnet IP for it; same helper as launcher/tests.
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

pair_link_is() { # pair_link_is <swe> <prefix>: `swe remote pair --json` url starts with prefix
  local j; j="$("$1" remote pair --json --name=live-test)" || return 1
  grep -qF "\"url\": \"$2" <<<"$j"
}
status_ok() { local b; b="$(curl -fsS --max-time "$2" "$1")" || return 1; grep -q '"ok": *true' <<<"$b"; }
body_has()  { local b; b="$(curl -fsS --max-time 30 "$1")" || return 1; grep -qF -- "$2" <<<"$b"; }
http_code_is() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$1")" = "$2" ]; }
serve_maps() { # serve_maps <https url> <target>: that port's / proxies target
  "$TS" serve status 2>/dev/null | awk -v hdr="$1 " -v want="$2" '
    index($0, hdr) == 1 { inblk = 1; next }
    /^https?:\/\// { inblk = 0 }
    inblk && $2 == "/" && $3 == "proxy" && $4 == want { found = 1 }
    END { exit !found }'
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local local_port https_port host url swe
  TS="tailscale"
  command -v tailscale >/dev/null || TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  local_port="$(sed -n 's/^LOCAL_PORT=//p' "$SERVICE_DIR/.env" 2>/dev/null)"
  https_port="$(sed -n 's/^HTTPS_PORT=//p' "$SERVICE_DIR/.env" 2>/dev/null)"
  https_port="${https_port:-$local_port}"
  host="$("$TS" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  url="https://$host:$https_port"
  swe="$HOME/.local/share/quiver-hub/bin/swe"
  live_check ".env present with LOCAL_PORT"       [ -n "$local_port" ]
  live_check "hub build installed with a commit"  [ -s "$HOME/.local/share/quiver-hub/installed-rev" ]
  live_check "live build links that commit's release" sh -c "case \"\$(readlink '$HOME/.local/share/quiver-hub/bin')\" in releases/\$(cat '$HOME/.local/share/quiver-hub/installed-rev')*/bin) exit 0;; esac; exit 1"
  live_check "hub build has swe remote --public-url" sh -c "'$swe' remote 2>&1 | grep -q -- '--public-url'"
  if [ "$OS" = "Linux" ]; then
    live_check "systemd service is active"        systemctl --user is-active quiver-hub.service
    live_check "service is enabled at boot"       systemctl --user is-enabled quiver-hub.service
    live_check "lingering is on (boot persist)"   sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
    live_check "unit binds 127.0.0.1"             grep -q -- "--host=127.0.0.1 --port=$local_port" "$HOME/.config/systemd/user/quiver-hub.service"
    live_check "unit passes --public-url"         grep -q -- "--public-url=$url\$" "$HOME/.config/systemd/user/quiver-hub.service"
  else
    live_check "LaunchAgent is loaded"            launchctl print "gui/$(id -u)/com.setup-server.quiver-hub"
  fi
  live_check "local /v1/status is ok"             status_ok "http://127.0.0.1:$local_port/v1/status" 5
  live_check "not listening on non-local ifaces"  no_external_listener "$local_port"
  live_check "tailscale serve maps the port"      serve_maps "$url" "http://127.0.0.1:$local_port"
  live_check "tailnet HTTPS /v1/status is ok"     status_ok "$url/v1/status" 30
  live_check "tailnet HTTPS serves the PWA"       body_has "$url/" "Have a pair token?"
  live_check "API needs a device credential"      http_code_is "$url/v1/sessions" 401
  live_check "hub saved its public URL"           grep -qF "\"public_url\": \"$url\"" "$HOME/.quiver/data/remote/hub.json"
  # Mints a real (unused) token; it expires on its own after 5 minutes.
  live_check "swe remote pair gives the https link" pair_link_is "$swe" "$url/#pair="
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_tailscale_down
test_preflight_refuses_root
test_fresh_deploy
test_idempotent_rerun
test_upgrade_when_main_moves
test_prunes_old_releases
test_rejected_upgrade_keeps_live_build
test_failed_upgrade_keeps_live_build
test_forced_reinstall_failure_keeps_live_build
test_forced_reinstall_success
test_migrates_flat_layout
test_pin_by_sha
test_pin_by_tag
test_explicit_ref_beats_env
test_unknown_ref
test_github_unreachable
test_uv_failure
test_too_old_quiver
test_quiver_without_public_url
test_port_override
test_env_wins_over_port
test_refuses_443
test_serve_port_taken
test_hub_never_healthy
test_serve_approval_retry
test_pair_before_deploy
test_pair_prints_https_links
test_pair_refuses_http_link
test_pair_custom_https_port

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
