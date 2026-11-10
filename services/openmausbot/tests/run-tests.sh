#!/usr/bin/env bash
#
# Tests for services/openmausbot/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (simulated fresh server, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real scripts from a sandbox copy of this directory
# (so the generated .env never lands in the repo), with a fake $HOME and PATH
# stubs for node/npm/tailscale/sudo/systemctl/loginctl/launchctl/curl/id/uname.
# Stubs log every call to $CALLS_LOG and keep state in $STATE_DIR. Nothing
# touches the real system.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
# setup.sh/teardown.sh source ../../lib/common.sh, so the sandbox copy of the
# service sits at <root>/services/<name> with <root>/lib beside it.
copy_lib() { mkdir -p "$1/lib" && cp "$REPO_ROOT/lib/common.sh" "$1/lib/"; }
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
  SVC="$SANDBOX/repo/services/openmausbot"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SVC/"
  UNIT="$HOME/.config/systemd/user/openmausbot.service"
  PLIST="$HOME/Library/LaunchAgents/com.openmausbot.server.plist"
  MARKER="$HOME/services/openmausbot"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_OS OMB_PORT HTTPS_PORT OMB_VERSION STATE_DIR CALLS_LOG
}

# run_deploy [stdin-string] — runs setup.sh under stubs; sets OUT and CODE
run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# run_teardown [flag] [stdin-line] — runs teardown.sh under stubs
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
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

# ----------------------------------------------------------------- tests
test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "explains the problem"      out_has "Tailscale is not up"
  check "did not install anything"  [ ! -e "$HOME/.local/bin/openmausbot" ]
  check "no .env written"           [ ! -e "$SVC/.env" ]
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

test_preflight_old_node() {
  echo "• preflight refuses node < 24"
  setup
  echo "v22.11.0" > "$STATE_DIR/node_version"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "says >= 24"           out_has "Node.js >= 24"
  check "shows found version"  out_has "v22.11.0"
  teardown
}

test_no_tailnet_name() {
  echo "• no tailnet DNS name: stops with the reason"
  setup
  touch "$STATE_DIR/no_dns_name"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the problem"       out_has "Could not determine tailnet DNS name"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path on a clean server"
  setup
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "installed fake openmausbot"          [ -x "$HOME/.local/bin/openmausbot" ]
  check "npm -g pinned install, no npx"       calls_have "npm install -g openmausbot@0.1.149"
  check "no bare unpinned install"            no_call "npm install -g openmausbot "
  check "no prefix move under HOME"           no_call "npm config set prefix"
  check ".env records the pin"                env_has "OMB_VERSION=0.1.149"
  check ".env written mode 600"               [ "$(stat -c %a "$SVC/.env" 2>/dev/null || stat -f %Lp "$SVC/.env")" = "600" ]
  check ".env has OMB_PORT"                   env_has "OMB_PORT=8799"
  check ".env has HTTPS_PORT"                 env_has "HTTPS_PORT=8799"
  check ".env relocates data dir"             env_has "OMB_DATA_DIR=$HOME/services/openmausbot/data"
  check ".env has public URL"                 env_has "OMB_PUBLIC_URL=https://test-host.tailfake.ts.net:8799"
  check ".env pins loopback trust"            env_has "OMB_LOOPBACK_TRUST=owner"
  check "data dir created"                    [ -d "$MARKER/data" ]
  if [ "$OS" = "Linux" ]; then
    check "wrote systemd unit"                [ -f "$UNIT" ]
    check "unit sources .env"                 unit_has "EnvironmentFile=$SVC/.env"
    check "unit runs serve --no-pair"         unit_has "ExecStart=$HOME/.local/bin/openmausbot serve --no-pair"
    check "unit has no tunnel/domain"         bash -c '! grep -qE -- "--tunnel|--domain" "$1"' _ "$UNIT"
    check "enabled + restarted service"       calls_have "systemctl --user restart openmausbot"
    check "enabled lingering via sudo"        calls_have "sudo loginctl enable-linger"
    check "granted operator via sudo"         calls_have "sudo tailscale set --operator="
  else
    check "wrote LaunchAgent plist"           [ -f "$PLIST" ]
    check "plist runs --no-pair"              plist_has "<string>--no-pair</string>"
    check "bootstrapped LaunchAgent"          calls_have "launchctl bootstrap"
  fi
  check "health-checked /api/health"          calls_have "http://127.0.0.1:8799/api/health"
  check "published HTTPS :8799"               calls_have "tailscale serve --bg --https=8799 http://127.0.0.1:8799"
  check "prints final tailnet URL"            out_has "https://test-host.tailfake.ts.net:8799"
  check "end-to-end check passed"             out_has "End-to-end check passed"
  check "no pairing code in output"           out_lacks "pair#code"
  check "no tunnel/domain flags in output"    out_lacks "--tunnel"
  check "never ran pair (user's step)"        no_call "openmausbot pair"
  teardown
}

test_npm_system_prefix_moved() {
  echo "• system npm prefix (/usr): moved to ~/.local, no sudo"
  setup
  echo "/usr" > "$STATE_DIR/npm_prefix"
  run_deploy
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check "prefix moved"                      calls_have "npm config set prefix $HOME/.local"
  check "installed under new prefix"        [ -x "$HOME/.local/bin/openmausbot" ]
  check "no sudo for install"               no_call "sudo npm"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run on already-deployed server: no sudo, .env preserved"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  printf '# my-custom-marker\n' >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env left untouched"           grep -q "my-custom-marker" "$SVC/.env"
  check "says config untouched"         out_has "leaving untouched"
  check "still reinstalls the pinned package" calls_have "npm install -g openmausbot@0.1.149"
  check "never invoked sudo"            no_call "sudo "
  if [ "$OS" = "Linux" ]; then
    check "service still restarted"     calls_have "systemctl --user restart openmausbot"
  else
    check "LaunchAgent re-bootstrapped" calls_have "launchctl bootstrap"
  fi
  check "serve reapplied"               calls_have "tailscale serve --bg"
  teardown
}

test_port_override() {
  echo "• OMB_PORT=9900 override (HTTPS follows)"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  export OMB_PORT=9900
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check ".env uses port 9900"      env_has "OMB_PORT=9900"
  check "https follows"            env_has "HTTPS_PORT=9900"
  check "public URL uses 9900"     env_has "OMB_PUBLIC_URL=https://test-host.tailfake.ts.net:9900"
  check "serve proxies 9900"       calls_have "tailscale serve --bg --https=9900 http://127.0.0.1:9900"
  teardown
}

test_version_override() {
  echo "• OMB_VERSION override wins over default and saved .env value"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  export OMB_VERSION=0.9.9-test
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "installs the override"         calls_have "npm install -g openmausbot@0.9.9-test"
  check "saved .env pin kept"           env_has "OMB_VERSION=0.1.149"
  teardown
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  sed -i.bak 's/^OMB_VERSION=.*/OMB_VERSION=0.2.0/' "$SVC/.env" && rm -f "$SVC/.env.bak"
  : > "$CALLS_LOG"
  run_deploy
  check "saved .env version wins"       calls_have "npm install -g openmausbot@0.2.0"
  check "no default install this run"   no_call "openmausbot@0.1.149"

  # inline comment and export prefix are parsed the same way sourcing does
  sed -i.bak 's/^OMB_VERSION=0\.2\.0$/export OMB_VERSION=0.3.0 # tested pin/' "$SVC/.env" && rm -f "$SVC/.env.bak"
  : > "$CALLS_LOG"
  run_deploy
  check "exported+commented pin exits zero" [ "$CODE" -eq 0 ]
  check "installs exported+commented pin"   calls_have "npm install -g openmausbot@0.3.0"
  check "does not duplicate OMB_VERSION"    [ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?OMB_VERSION=' "$SVC/.env")" -eq 1 ]
  teardown
}

test_env_port_wins_over_cli() {
  echo "• re-run with existing .env: CLI port ignored with a warning"
  setup
  touch "$STATE_DIR/linger" "$STATE_DIR/operator"
  run_deploy
  export OMB_PORT=7777
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "warns about the ignore"   out_has "OMB_PORT=7777 ignored"
  check ".env still 8799"          env_has "OMB_PORT=8799"
  check "serves 8799"              calls_have "tailscale serve --bg --https=8799 http://127.0.0.1:8799"
  teardown
}

test_serve_approval_retry() {
  echo "• serve not yet enabled on tailnet: approval prompt + retry loop"
  setup
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero after retry"     [ "$CODE" -eq 0 ]
  check "showed the approval prompt" out_has "approval URL"
  check "eventually published"       out_has "Tailscale Serve: HTTPS :8799"
  [ "$OS" = "Linux" ] && check "granted operator on 1st failure" calls_have "sudo tailscale set --operator="
  teardown
}

test_serve_port_owned_by_another() {
  echo "• :8799 already published for another app: refuses to take it over"
  setup
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8799 (tailnet only)
|-- / proxy http://127.0.0.1:8093
EOF
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the other target"    out_has "already published for http://127.0.0.1:8093"
  check "did not publish"           no_call "serve --bg"
  teardown
}

# ------------------------------------------------------------- teardown
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
last_call_is() { tail -n 1 "$CALLS_LOG" | grep -q -- "$1"; }

# A deployed sandbox: setup.sh has run; :8799 carries openmausbot, plus a
# neighbour port serving something else.
deployed() {
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8799 (tailnet only)
|-- / proxy http://127.0.0.1:8799

https://test-host.tailfake.ts.net:8093 (tailnet only)
|-- / proxy http://127.0.0.1:8093
EOF
  : > "$CALLS_LOG"
}

test_teardown_safe() {
  echo "• teardown: safe remove drops the :8799 publish, keeps everything"
  deployed
  run_teardown
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ":8799 off whole"                calls_have "tailscale serve --https=8799 off"
  check "neighbour :8093 untouched"      no_call "https=8093"
  check "never serve reset"              no_call "serve reset"
  if [ "$OS" = "Linux" ]; then
    check "unit disabled"                calls_have "systemctl --user disable openmausbot.service"
    check "unit stopped"                 calls_have "systemctl --user stop openmausbot.service"
    check "serve off before disable"     [ "$(call_line 'https=8799 off')" -lt "$(call_line 'disable openmausbot')" ]
    check "disable before stop"          [ "$(call_line 'disable openmausbot')" -lt "$(call_line 'stop openmausbot')" ]
    check "stop is the last call"        last_call_is "stop openmausbot"
    check "unit file kept"               [ -f "$UNIT" ]
  else
    check "plist removed"                [ ! -f "$PLIST" ]
    check "booted out"                   calls_have "launchctl bootout"
  fi
  check ".env kept"                      [ -f "$SVC/.env" ]
  check "data kept"                      [ -d "$MARKER/data" ]
  check "package kept"                   [ -x "$HOME/.local/bin/openmausbot" ]
  check "says how to bring it back"      out_has "./setup.sh brings it back"
  : > "$CALLS_LOG"
  run_teardown
  check "re-run exits zero"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_port_shapes() {
  echo "• teardown: an all-openmausbot port goes off whole; shared ports lose only its paths"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8799 (tailnet only)
|-- / proxy http://127.0.0.1:8799

https://test-host.tailfake.ts.net:8445 (tailnet only)
|-- / proxy http://127.0.0.1:8799
|-- /home proxy http://127.0.0.1:8093

https://test-host.tailfake.ts.net:8446 (tailnet only)
|-- / proxy http://127.0.0.1:18799
EOF
  run_teardown
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check ":8799 (all ours) off whole"        calls_have "serve --https=8799 off"
  check ":8445 / off"                       calls_have "serve --https=8445 --set-path=/ off"
  check ":8445 not off whole"               no_call "serve --https=8445 off"
  check ":8445 /home kept"                  no_call "set-path=/home"
  check "lookalike :18799 untouched"        no_call "https=8446"
  check "never serve reset"                 no_call "serve reset"
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
  if [ "$OS" = "Linux" ]; then
    check "still stops"               calls_have "stop openmausbot"
  else
    check "still boots out"           calls_have "launchctl bootout"
  fi
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

test_teardown_missing_env() {
  echo "• teardown: no .env means nothing to tear down"
  setup
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "explains"                    out_has "nothing to tear down"
  check "touched nothing"             no_call "systemctl"
  teardown
}

test_teardown_bad_env() {
  echo "• teardown: a .env it cannot read for sure changes nothing"
  deployed
  printf 'OMB_PORT=8799\nOMB_PORT=9900\n' >> "$SVC/.env"
  run_teardown
  check "dup key: exits non-zero"     [ "$CODE" -ne 0 ]
  check "nothing unpublished"         no_call " off"
  check "nothing stopped"             no_call "systemctl"
  teardown
  deployed
  printf 'OMB_PORT=abc\n' > "$SVC/.env"
  run_teardown
  check "bad port: exits non-zero"    [ "$CODE" -ne 0 ]
  check "still nothing unpublished"   no_call " off"
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
  OUT="$(PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge extra 2>&1 </dev/null)"; CODE=$?
  check "too many args: exits non-zero" [ "$CODE" -ne 0 ]
  check "nothing changed"             no_call "systemctl"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then unit + .env + data go"
  deployed
  run_teardown --purge "openmaus"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "wrong name: unit kept"     [ -f "$UNIT" ]
  else
    check "wrong name: plist kept"    [ -f "$PLIST" ]
  fi
  check "wrong name: nothing stopped" no_call "stop openmausbot"
  check "wrong name: nothing booted"  no_call "bootout"
  check "wrong name: serve untouched" no_call " off"
  check "wrong name: data kept"       [ -d "$MARKER/data" ]
  run_teardown --purge "openmausbot"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "unit/plist file gone"        [ ! -f "$UNIT" ] && [ ! -f "$PLIST" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "data dir gone"               [ ! -d "$MARKER/data" ]
  check "marker removed"              [ ! -d "$MARKER" ]
  check "package kept + rm printed"   out_has "npm uninstall -g openmausbot"
  check "native-install dir never deleted"  out_lacks "rm -rf $HOME/.openmausbot "
  teardown
}

test_teardown_purge_odd_data_dir() {
  echo "• teardown --purge: a data dir outside ~/services/openmausbot is refused"
  deployed
  sed -i.bak "s|^OMB_DATA_DIR=.*|OMB_DATA_DIR=$HOME/other/data|" "$SVC/.env" 2>/dev/null \
    || sed -i '' "s|^OMB_DATA_DIR=.*|OMB_DATA_DIR=$HOME/other/data|" "$SVC/.env"
  mkdir -p "$HOME/other/data"
  run_teardown --purge "openmausbot"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "refuses"                     out_has "refusing to purge"
  check "data kept"                   [ -d "$HOME/other/data" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "nothing unpublished"         no_call " off"
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in the shell is refused (shared guard)"
  deployed
  OUT="$(printf 'openmausbot\n' | env COMPOSE_PROJECT_NAME=x PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing unpublished"         no_call " off"
  check "nothing stopped"             no_call "systemctl"
  teardown
}

# ------------------------------------------------------- contrib/devin-acp
# The shim's behavior is exercised end-to-end against tests/devin-acp-child,
# a fake `devin` speaking ndjson JSON-RPC and logging every inbound line.
# Real node is required; the PATH stubs are for the deploy scripts, not this.
test_devin_acp_shim() {
  echo "• contrib/devin-acp shim (Devin ACP engine helper)"
  command -v node >/dev/null 2>&1 || { echo "    (node not found — skipping)"; return 0; }

  local SHIM CHILD SHIM_HOME
  SHIM="$REPO_ROOT/services/openmausbot/contrib/devin-acp"
  CHILD="$REPO_ROOT/services/openmausbot/tests/devin-acp-child"
  SHIM_HOME="$(mktemp -d)"
  mkdir -p "$SHIM_HOME/.local/share/devin"

  shim_run() { # stdin: ndjson requests; env: DEVIN_STUB_LOG, DEVIN_STUB_AUTH_FAIL
    env -i PATH="$PATH" HOME="$SHIM_HOME" \
      DEVIN_CLI="$CHILD" DEVIN_STUB_LOG="$DEVIN_STUB_LOG" \
      DEVIN_STUB_AUTH_FAIL="${DEVIN_STUB_AUTH_FAIL:-}" \
      timeout 20 node "$SHIM" 2>/dev/null
  }

  # --version routes to `devin --version`, not `devin acp --version`.
  OUT="$(env -i PATH="$PATH" DEVIN_CLI="$CHILD" node "$SHIM" --version 2>/dev/null)"
  check "--version forwards to devin" out_has "devin 3000.0.0"

  # Full flow: the shim injects authenticate after initialize and holds the
  # next client message until auth settles; its own traffic never reaches us.
  printf 'windsurf_api_key = "stub-key"\n' > "$SHIM_HOME/.local/share/devin/credentials.toml"
  DEVIN_STUB_LOG="$SHIM_HOME/child.log"; : > "$DEVIN_STUB_LOG"
  OUT="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
    | shim_run)"
  check "initialize response forwarded"    out_has '"id":1'
  check "session/new answered"             out_has 'stub-session'
  check "shim auth response swallowed"     out_lacks '__devin_acp_shim__'
  check "child saw authenticate"           bash -c "grep -q '\"method\":\"authenticate\"' '$DEVIN_STUB_LOG'"
  check "authenticate carries the key"     bash -c "grep -q 'stub-key' '$DEVIN_STUB_LOG'"
  check "auth precedes session/new"        bash -c \
    "[ \$(grep -n authenticate '$DEVIN_STUB_LOG' | head -1 | cut -d: -f1) -lt \$(grep -n 'session/new' '$DEVIN_STUB_LOG' | head -1 | cut -d: -f1) ]"

  # No credentials file: nothing is injected or held; traffic passes through.
  rm -f "$SHIM_HOME/.local/share/devin/credentials.toml"
  DEVIN_STUB_LOG="$SHIM_HOME/child2.log"; : > "$DEVIN_STUB_LOG"
  OUT="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
    | shim_run)"
  # Like real `devin acp`, the stub refuses unauthenticated sessions — seeing
  # that refusal proves the message passed straight through with no injection.
  check "no key: refusal forwarded"        out_has 'not authenticated'
  check "no key: no authenticate injected" bash -c "! grep -q authenticate '$DEVIN_STUB_LOG'"

  # Auth failure: the shim still flushes held traffic and reports the child.
  printf 'windsurf_api_key = "stub-key"\n' > "$SHIM_HOME/.local/share/devin/credentials.toml"
  DEVIN_STUB_LOG="$SHIM_HOME/child3.log"; : > "$DEVIN_STUB_LOG"
  DEVIN_STUB_AUTH_FAIL=1
  OUT="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
    | shim_run)"
  unset DEVIN_STUB_AUTH_FAIL
  check "auth fails: held traffic flushed" out_has '"id":2'
  check "auth fails: refusal forwarded"    out_has 'not authenticated'
  check "auth fails: response swallowed"   out_lacks '__devin_acp_shim__'

  rm -rf "$SHIM_HOME"
}

# ------------------------------------------------- contrib/devin-seed-models
# The seeder drives the shim end-to-end: session/new through auth injection,
# then writes providers/engine-models/<instance>.json in the shape
# OpenMausBot's own discovery would have produced.
test_devin_seed_models() {
  echo "• contrib/devin-seed-models (model catalog seeder)"
  command -v node >/dev/null 2>&1 || { echo "    (node not found — skipping)"; return 0; }

  local SHIM CHILD SEED SEED_HOME DATA
  SHIM="$REPO_ROOT/services/openmausbot/contrib/devin-acp"
  CHILD="$REPO_ROOT/services/openmausbot/tests/devin-acp-child"
  SEED="$REPO_ROOT/services/openmausbot/contrib/devin-seed-models"
  SEED_HOME="$(mktemp -d)"
  DATA="$SEED_HOME/data"
  mkdir -p "$SEED_HOME/.local/share/devin" "$DATA/providers/engine-models"
  printf 'windsurf_api_key = "stub-key"\n' > "$SEED_HOME/.local/share/devin/credentials.toml"
  printf '{"default":"agent-default","options":[{"id":"agent-default","label":"Agent default","custom":true}],"checkedAt":0,"build":"9.9.9"}\n' \
    > "$DATA/providers/engine-models/devin.json"

  seed_run() { # env: DEVIN_STUB_CATALOG
    env -i PATH="$PATH" HOME="$SEED_HOME" \
      DEVIN_CLI="$CHILD" DEVIN_ACP="$SHIM" OMB_DATA_DIR="$DATA" \
      DEVIN_STUB_LOG="$SEED_HOME/child.log" \
      DEVIN_STUB_CATALOG="${DEVIN_STUB_CATALOG:-}" \
      timeout 20 node "$SEED" "${1:-devin}" 2>&1
  }

  # Happy path: catalog comes back from session/new through the shim's auth.
  DEVIN_STUB_CATALOG=1
  OUT="$(seed_run)"
  check "seed reports count"        out_has 'seeded 4 models'
  check "seed writes cache"         bash -c \
    "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$DATA/providers/engine-models/devin.json\",\"utf8\"));if(j.options.length!==4)process.exit(1)'"
  check "passthrough stays first"   bash -c \
    "grep -q '\"id\":\"agent-default\"' '$DATA/providers/engine-models/devin.json'"
  check "models marked custom"      bash -c \
    "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$DATA/providers/engine-models/devin.json\",\"utf8\"));if(!j.options.every(o=>o.custom===true))process.exit(1)'"
  check "duplicates deduped"        bash -c \
    "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$DATA/providers/engine-models/devin.json\",\"utf8\"));if(j.options.filter(o=>o.id===\"swe-2-high\").length!==1)process.exit(1)'"
  check "variants attached"         bash -c \
    "grep -q '\"id\":\"medium\"' '$DATA/providers/engine-models/devin.json' && grep -q '\"id\":\"high\"' '$DATA/providers/engine-models/devin.json'"
  check "build stamp preserved"     bash -c \
    "grep -q '\"build\":\"9.9.9\"' '$DATA/providers/engine-models/devin.json'"
  check "checkedAt stamped"         bash -c \
    "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$DATA/providers/engine-models/devin.json\",\"utf8\"));if(!(j.checkedAt>0))process.exit(1)'"
  check "session was authenticated" bash -c \
    "grep -q '\"method\":\"authenticate\"' '$SEED_HOME/child.log'"
  unset DEVIN_STUB_CATALOG

  # No model configOptions: exits non-zero, catalog file left untouched.
  OUT="$(seed_run; echo "rc=$?")"
  check "no catalog: exits non-zero" out_has 'rc=1'
  check "no catalog: explains"       out_has 'no model configOptions'
  check "no catalog: file kept"      bash -c \
    "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$DATA/providers/engine-models/devin.json\",\"utf8\"));if(j.options.length!==4)process.exit(1)'"

  # Unsafe instance id is refused before touching anything.
  OUT="$(seed_run 'a;b')"
  check "bad instance id refused"    out_has 'refusing unsafe instance id'

  rm -rf "$SEED_HOME"
}

# ------------------------------------------------------------- live suite
live() {
  echo
  echo "== live: verifying the real deployment on this machine"
  local rc=0

  check_live() { local d="$1"; shift; if "$@"; then green "    ✓ $d"; else red "    ✗ $d"; rc=1; fi; }

  [ -f "$SERVICE_DIR/.env" ] || { echo "    (no .env — not deployed here, skipping)"; return 0; }
  local port https ts tsip
  port="$(sed -n 's/^OMB_PORT=\(.*\)$/\1/p' "$SERVICE_DIR/.env" | tail -1 | tr -d "\"'")"
  : "${port:=8799}"
  https="$(sed -n 's/^HTTPS_PORT=\(.*\)$/\1/p' "$SERVICE_DIR/.env" | tail -1 | tr -d "\"'")"
  : "${https:=$port}"
  # Same resolution as lib's resolve_tailscale: PATH first, then the macOS
  # app bundle — a Mac may have the app without the CLI on PATH.
  ts="$(command -v tailscale || true)"
  [ -n "$ts" ] || { [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"; }
  [ -n "$ts" ] || { red "    ✗ tailscale CLI not found"; return 1; }
  tsip="$("$ts" ip -4 2>/dev/null | head -1)"
  local tsip6
  tsip6="$("$ts" ip -6 2>/dev/null | head -1)"

  if [ "$OS" = "Linux" ]; then
    check_live "unit is active"      systemctl --user is-active --quiet openmausbot
    check_live "unit is enabled"     systemctl --user is-enabled --quiet openmausbot
    check_live "lingering on"        bash -c '[ "$(loginctl show-user "$USER" -p Linger --value)" = yes ]'
  else
    check_live "LaunchAgent loaded"  launchctl print "gui/$(id -u)/com.openmausbot.server"
  fi
  # A listener on loopback or this node's tailnet IPs is fine — the latter
  # are Serve's own proxies when the HTTPS port equals the app port (Serve
  # binds both the v4 and the v6 tailnet address). Anything else (LAN,
  # wildcard) is a leak. lsof's header line is skipped so it can never
  # read as a stray listener. Colons need no escaping in an ERE.
  live_listener_audit() {
    local keep="127\.0\.0\.1|localhost|\[::1\]|::1"
    [ -n "$tsip" ] && keep="$keep|${tsip//./\\.}"
    [ -n "$tsip6" ] && keep="$keep|$tsip6"
    if command -v ss >/dev/null 2>&1; then
      ! ss -tlnH "sport = :$port" | grep -vE "$keep" | grep -q .
    else
      ! lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | tail -n +2 | grep -vE "$keep" | grep -q .
    fi
  }
  live_serve_published() { "$ts" serve status | grep -q "proxy http://127.0.0.1:$port"; }
  live_https_ok() {
    local dns
    dns="$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
    [ -n "$dns" ] && curl -fsS -o /dev/null --max-time 30 "https://$dns:$https/api/health"
  }
  check_live "nothing off-loopback/off-tailnet ($port)" live_listener_audit
  check_live "local /api/health"     curl -fsS -o /dev/null "http://127.0.0.1:$port/api/health"
  check_live "published via Serve"   live_serve_published
  check_live "end-to-end HTTPS"      live_https_ok
  return "$rc"
}

# ------------------------------------------------------------------- run
for t in \
  test_preflight_tailscale_down \
  test_preflight_refuses_root \
  test_preflight_old_node \
  test_no_tailnet_name \
  test_fresh_deploy \
  test_npm_system_prefix_moved \
  test_idempotent_rerun \
  test_port_override \
  test_version_override \
  test_env_port_wins_over_cli \
  test_serve_approval_retry \
  test_serve_port_owned_by_another \
  test_teardown_safe \
  test_teardown_port_shapes \
  test_teardown_not_published \
  test_teardown_serve_status_fails \
  test_teardown_missing_env \
  test_teardown_bad_env \
  test_teardown_preflight \
  test_teardown_purge \
  test_teardown_purge_odd_data_dir \
  test_teardown_refuses_compose_overrides \
  test_devin_acp_shim \
  test_devin_seed_models; do
  "$t"
done

echo
printf 'mocked: %d passed, %d failed\n' "$PASS" "$FAIL"

RC=0
[ "$FAIL" -eq 0 ] || RC=1
if [ "${1:-}" = "--live" ]; then
  export HOME="$ORIG_HOME"
  live || RC=1
fi
exit "$RC"
