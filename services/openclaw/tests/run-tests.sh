#!/usr/bin/env bash
#
# Tests for services/openclaw/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id. The docker stub
# fakes the pre-start `config get`/`config set` calls, so the Gateway config
# sync is exercised for real.

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
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/openclaw"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
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

out_has()    { grep -q "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }
env_lacks()  { ! grep -q "$1" "$SVC/.env"; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped — the file
# documents what it deliberately does NOT do ("upstream binds 0.0.0.0:18789"),
# so a naive grep would match the prose and not the config.
compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
no_wildcard_bind() { ! compose_has '0\.0\.0\.0'; }

config_set_has()   { grep -q -- "$1" "$STATE_DIR/config_sets" 2>/dev/null; }
config_set_lacks() { ! grep -q -- "$1" "$STATE_DIR/config_sets" 2>/dev/null; }

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
  export LOCAL_PORT=18x89
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: .env generated, config synced, published tailnet-only"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env generated"                  [ -f "$SVC/.env" ]
  check ".env is mode 600"                [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has a hex gateway token"    grep -qE '^OPENCLAW_GATEWAY_TOKEN=[a-f0-9]{32}$' "$SVC/.env"
  check ".env records the local port"     grep -qx 'LOCAL_PORT=18789' "$SVC/.env"
  check "image tag pinned"                grep -qx 'OPENCLAW_VERSION=2026.10.7' "$SVC/.env"
  check "comments survive verbatim"       grep -qxF "# moving stable channel, 'extended-stable' the trailing-month line." "$SVC/.env"
  check "compose binds loopback only"     compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose binds no wildcard"       no_wildcard_bind
  check "restart is unless-stopped"       compose_has 'restart: *unless-stopped'
  check "cli behind a profile"            compose_has 'profiles: *\["cli"\]'
  check "state dirs created"              [ -d "$HOME/services/openclaw/config" ]
  check "  workspace too"                 [ -d "$HOME/services/openclaw/workspace" ]
  check "  auth-secrets too"              [ -d "$HOME/services/openclaw/auth-secrets" ]
  check "creds overlay written"           [ -f "$SVC/docker-compose.creds.yml" ]
  check "  mounts ~/.claude"              grep -q "/home/node/.claude" "$SVC/docker-compose.creds.yml"
  check "config set ran pre-start"        [ -f "$STATE_DIR/config_sets" ]
  check "  pins gateway.mode=local"       config_set_has 'gateway.mode'
  check "  pins gateway.bind=lan"         config_set_has 'gateway.bind'
  check "  seeds allowedOrigins"          config_set_has 'gateway.controlUi.allowedOrigins'
  check "  origins include the tailnet URL" config_set_has 'https://test-host\.tailfake\.ts\.net:18789'
  check "  origins include loopback"      config_set_has 'http://127.0.0.1:18789'
  check "  seeds trustedProxies"          config_set_has 'gateway.trustedProxies'
  check "  covering the pinned subnet"    config_set_has '192\.168\.144\.0/24'
  check "compose up invoked"              [ -f "$STATE_DIR/compose_up" ]
  check "waited on the local port"        calls_have "127.0.0.1:18789/"
  check "served on tailscale :18789"      calls_have "tailscale serve --bg --https=18789 http://127.0.0.1:18789"
  check "no sudo needed (operator set)"   no_call "^sudo "
  check "prints final URL"                out_has "https://test-host.tailfake.ts.net:18789"
  check "prints where the token lives"    out_has "OPENCLAW_GATEWAY_TOKEN"
  teardown
}

test_no_agent_dirs_no_overlay() {
  echo "• no ~/.claude or ~/.codex: no creds overlay, a warning instead"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "no creds overlay"          [ ! -f "$SVC/docker-compose.creds.yml" ]
  check "warns about providers"     out_has "configure a model provider"
  teardown
}

test_codex_also_mounted() {
  echo "• a ~/.codex is mounted alongside ~/.claude"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  run_deploy
  check "exits zero"           [ "$CODE" -eq 0 ]
  check "mounts ~/.codex"      grep -q "/home/node/.codex" "$SVC/docker-compose.creds.yml"
  check "mounts ~/.claude"     grep -q "/home/node/.claude" "$SVC/docker-compose.creds.yml"
  teardown
}

test_origins_already_set() {
  echo "• allowedOrigins already configured: left alone, mode/bind still pinned"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/origins_set" "$STATE_DIR/proxies_set"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no allowedOrigins in batch"    config_set_lacks 'allowedOrigins'
  check "no trustedProxies in batch"    config_set_lacks 'trustedProxies'
  check "mode still pinned"             config_set_has 'gateway.mode'
  check "says it left them alone"       out_has "leaving allowedOrigins alone"
  check "says proxies left alone too"   out_has "leaving them alone"
  teardown
}

test_origins_stale_port_warns() {
  echo "• allowedOrigins set for a different port: warns, never rewrites it"
  setup
  # User-configured origins for :18789, but the publish moved to :8443 — every
  # health check still passes, so the script has to say why browsers 403.
  touch "$STATE_DIR/operator" "$STATE_DIR/origins_stale" "$STATE_DIR/proxies_set"
  export HTTPS_PORT=8443
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no allowedOrigins in batch"    config_set_lacks 'allowedOrigins'
  check "names the missing origin"      out_has 'lacks https://test-host.tailfake.ts.net:8443'
  check "says how to fix it"            out_has 'config set'
  check "still published :8443"         calls_have "tailscale serve --bg --https=8443"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=18790 HTTPS_PORT=18790
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=18790' "$SVC/.env"
  check "origins use the new ports"  config_set_has 'https://test-host\.tailfake\.ts\.net:18790'
  check "health-checked :18790"      calls_have "127.0.0.1:18790/"
  check "served :18790 -> :18790"    calls_have "tailscale serve --bg --https=18790 http://127.0.0.1:18790"
  check "prints the :18790 URL"      out_has "https://test-host.tailfake.ts.net:18790"
  check ".env records the split"     grep -qx 'HTTPS_PORT=18790' "$SVC/.env"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under its config.
  export LOCAL_PORT=18791 HTTPS_PORT=18790
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=18791 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=18790' "$SVC/.env"
  check "re-run: still serves :18790" calls_have "tailscale serve --bg --https=18790 http://127.0.0.1:18790"
  check "re-run: never touched 18791" no_call "127.0.0.1:18791"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=18792
  run_deploy
  check "exits zero"                       [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=18792"    grep -qx 'LOCAL_PORT=18792' "$SVC/.env"
  check "served :18792 -> 127.0.0.1:18792" calls_have "tailscale serve --bg --https=18792 http://127.0.0.1:18792"
  check "  and never :18789"               no_call "tailscale serve --bg --https=18789"
  check "prints the :18792 URL"            out_has "https://test-host.tailfake.ts.net:18792"
  # Re-run with no override at all: .env says 18792, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 18789.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                     [ "$CODE" -eq 0 ]
  check "re-run kept :18792 -> 127.0.0.1:18792" calls_have "tailscale serve --bg --https=18792 http://127.0.0.1:18792"
  check "  and never :18789"                    no_call "tailscale serve --bg --https=18789"
  check "no publish split recorded"             env_lacks '^HTTPS_PORT='
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=18792 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:18792" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:18792"
  check "prints the :8443 URL"            out_has "https://test-host.tailfake.ts.net:8443"
  check ".env records the split"          grep -qx 'HTTPS_PORT=8443' "$SVC/.env"

  # A recorded publish port survives re-runs, and a different explicit one is
  # ignored with the same "edit .env" warning LOCAL_PORT gets.
  unset LOCAL_PORT HTTPS_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run keeps the :8443 split"    calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:18792"
  export HTTPS_PORT=8444
  : > "$CALLS_LOG"
  run_deploy
  check "new explicit is ignored"         out_has "HTTPS_PORT=8444 ignored"
  check "  still :8443"                   calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:18792"
  check "  .env keeps 8443"               grep -qx 'HTTPS_PORT=8443' "$SVC/.env"

  # The same saved port counts in every assignment form `source` accepts.
  sed -i.bak 's/^HTTPS_PORT=/export HTTPS_PORT=/' "$SVC/.env"
  unset HTTPS_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "export form honoured"            calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:18792"
  sed -i.bak 's/^export HTTPS_PORT=/  HTTPS_PORT=/' "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "indented form honoured"          calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:18792"
  teardown

  # A .env with no trailing newline must not swallow the appended block.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=18792
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  printf '%s' "$(cat "$SVC/.env")" > "$SVC/.env.trim" && mv "$SVC/.env.trim" "$SVC/.env"
  unset LOCAL_PORT
  export HTTPS_PORT=8444
  run_deploy
  check "re-run exits zero"               [ "$CODE" -eq 0 ]
  check "appended port recorded"          grep -qx 'HTTPS_PORT=8444' "$SVC/.env"
  check "served :8444"                    calls_have "tailscale serve --bg --https=8444 http://127.0.0.1:18792"
  unset HTTPS_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "still parseable on re-run"       [ "$CODE" -eq 0 ]
  check "still :8444"                     calls_have "tailscale serve --bg --https=8444 http://127.0.0.1:18792"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loop waits instead of dying"
  setup
  touch "$STATE_DIR/operator"
  echo 3 > "$STATE_DIR/health_fails_left"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "polled repeatedly"         [ "$(grep -c '127.0.0.1:18789/' "$CALLS_LOG")" -gt 3 ]
  check "still published"           calls_have "tailscale serve --bg --https=18789"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env and creds overlay preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude"
  run_deploy                                   # first deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  echo '# hand-tuned' >> "$SVC/docker-compose.creds.yml"
  token="$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "token unchanged"             [ "$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' "$SVC/.env")" = "$token" ]
  check "creds overlay untouched"     grep -q "hand-tuned" "$SVC/docker-compose.creds.yml"
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "config re-synced"            [ -f "$STATE_DIR/config_sets" ]
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=18789 http://127.0.0.1:18789"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=18789 http://127.0.0.1:18789"
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
  check "published on retry"        calls_have "tailscale serve --bg --https=18789 http://127.0.0.1:18789"
  teardown
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run (so .env and the state dirs exist),
# Serve maps this port to this service, and neighbours sit on other ports
# (one a lookalike).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:18789 (tailnet only)
|-- / proxy http://127.0.0.1:18789

https://test-host.tailfake.ts.net:28789 (tailnet only)
|-- / proxy http://127.0.0.1:28789
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

state_file() { echo "$HOME/services/openclaw/config/openclaw.json"; }

test_teardown_safe() {
  echo "• teardown: safe remove keeps state + .env, unpublishes only its port"
  deployed
  mkdir -p "$(dirname "$(state_file)")"; echo '{}' > "$(state_file)"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :18789"        calls_have "tailscale serve --https=18789 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :28789 untouched"  no_call "https=28789"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  in this project dir"       calls_have "compose --project-directory $SVC down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "config kept"                 [ -f "$(state_file)" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  rm -f "$STATE_DIR/compose_up"
  run_deploy
  check "setup.sh restores it"        [ "$CODE" -eq 0 ]
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
  printf 'https://test-host.tailfake.ts.net:18789 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "root: no compose down"       [ ! -f "$STATE_DIR/compose_down" ]
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
  echo "• teardown --purge: typed confirmation, then the state dir and .env go"
  deployed
  mkdir -p "$(dirname "$(state_file)")"; echo '{}' > "$(state_file)"
  run_teardown --purge "open"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: config kept"     [ -f "$(state_file)" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  check "warns the whole state goes"  out_has "whole OpenClaw state"
  run_teardown --purge "openclaw"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "state dir gone"              [ ! -e "$HOME/services/openclaw" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "serve off for :18789"        calls_have "tailscale serve --https=18789 off"
  check "down only, never down -v"    no_call "down -v"
  check "no sudo"                     no_call "^sudo"
  run_deploy
  check "fresh setup.sh exits zero"   [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the pinned image, not sudo"
  deployed
  local dir="$HOME/services/openclaw"
  # Stand-in for a container-owned file: a read-only dir the host user cannot empty.
  mkdir -p "$dir/config/locked"; echo x > "$dir/config/locked/k"
  chmod 500 "$dir/config/locked"
  run_teardown --purge "openclaw"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image"       calls_have "ghcr.io/openclaw/openclaw:2026.10.7"
  check "never pulled for it"         calls_have "pull never"
  check "runs it as root"             calls_have "--user 0"
  check "mounted the state dir"       calls_have "-v $dir:/x"
  check "no sudo"                     no_call "^sudo"
  check "state dir gone"              [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$HOME/services/openclaw"
  mkdir -p "$dir/config/locked"; echo x > "$dir/config/locked/f"
  chmod 500 "$dir/config/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "openclaw"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  deployed
  sed -i.bak 's/^OPENCLAW_VERSION=.*/OPENCLAW_VERSION=2026.10.7;x/' "$SVC/.env"
  run_teardown --purge "openclaw"
  check "odd image tag: exits non-zero" [ "$CODE" -ne 0 ]
  check "  state kept"                [ -e "$HOME/services/openclaw" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: a state dir outside ~/services is impossible, but a poisoned HOME is refused"
  deployed
  # HOME/services/openclaw is the only purge target; guard it directly.
  rm -rf "$HOME/services/openclaw"
  ln -s "$HOME" "$HOME/services/openclaw"
  run_teardown --purge "openclaw"
  check "symlinked state dir refused" [ "$CODE" -ne 0 ]
  check "  home untouched"            [ -d "$HOME" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  rm -f "$HOME/services/openclaw"
  teardown
}

test_teardown_purge_refuses_a_moved_dir() {
  echo "• teardown --purge: a state dir moved outside ~/services/openclaw refuses, .env kept"
  deployed
  sed -i.bak "s#^OPENCLAW_CONFIG_DIR=.*#OPENCLAW_CONFIG_DIR=$HOME/outside#" "$SVC/.env"
  mkdir -p "$HOME/outside"
  run_teardown --purge "openclaw"
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the moved var"      out_has "OPENCLAW_CONFIG_DIR"
  check "moved dir kept"           [ -d "$HOME/outside" ]
  check "state kept"               [ -e "$HOME/services/openclaw" ]
  check ".env kept"                [ -f "$SVC/.env" ]
  check "nothing stopped"          [ ! -f "$STATE_DIR/compose_down" ]
  rm -rf "$HOME/outside"
  sed -i.bak "s#^OPENCLAW_WORKSPACE_DIR=.*#OPENCLAW_WORKSPACE_DIR=/tmp#" "$SVC/.env"
  run_teardown --purge "openclaw"
  check "workspace move refused"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:18790 (tailnet only)
|-- / proxy http://127.0.0.1:18789

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:18789

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /claw proxy http://127.0.0.1:18789
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":18790 off"                  calls_have "serve --https=18790 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_units_left_alone() {
  echo "• teardown: units that mention openclaw but setup.sh never wrote are named, not touched"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/bin/sh -c "tar czf /backup/openclaw.tgz ~/services/openclaw"\n' \
    > "$HOME/.config/systemd/user/openclaw-backup.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/other.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit"              out_has "openclaw-backup.service mentions openclaw"
  check "  not the unrelated one"     out_lacks "other.service"
  check "  unit file kept"            [ -f "$HOME/.config/systemd/user/openclaw-backup.service" ]
  check "  no systemctl at all"       no_call "systemctl"
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
  check "no serve off"                no_call " off"
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='18789'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":18789 off"                  calls_have "serve --https=18789 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="18789"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check "  :18789 off"                calls_have "serve --https=18789 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=18789 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "  :18789 off"                calls_have "serve --https=18789 off"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'OPENCLAW_CONFIG_DIR=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "OPENCLAW_CONFIG_DIR is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nOPENCLAW_CONFIG_DIR=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "openclaw"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    check "  state kept"                [ -e "$HOME/services/openclaw" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose call"           no_call "compose --project-directory"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/openclaw is refused, not eaten"
  deployed
  local repo="$HOME/services/openclaw/setup-server/services/openclaw"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  copy_lib "${repo%/services/*}"
  # The state dir holds the checkout: refused outright.
  OUT="$(printf '%s\n' "openclaw" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "state dir holding it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
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
# address — never a wildcard or a LAN interface. This service publishes HTTPS
# on the same number as the local port (18789 -> 18789), so tailscaled
# legitimately listens on the tailnet IP for that port.
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

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"                            # strip :port
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6]
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
  https_port="$(sed -n 's/^HTTPS_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  [ -n "$https_port" ] || https_port="$port"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "openclaw-gateway container running" sh -c "docker inspect -f '{{.State.Status}}' openclaw-gateway | grep -qx running"
  live_check "container reports healthy"          sh -c "docker inspect -f '{{.State.Health.Status}}' openclaw-gateway | grep -qx healthy"
  live_check "healthz answers locally"            sh -c "curl -fsS -o /dev/null 'http://127.0.0.1:$port/healthz'"
  live_check "not listening on non-local ifaces"  no_external_listener "$port"
  live_check "tailscale serve maps :$https_port"  sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet healthz responds"           curl -fsS -o /dev/null --max-time 30 "$url:$https_port/healthz"
  live_check "tailnet Control UI responds"        curl -fsS -o /dev/null --max-time 30 "$url:$https_port/"
  live_check "state dir exists"                   sh -c "test -d \"\$(sed -n 's/^OPENCLAW_CONFIG_DIR=//p' '$SERVICE_DIR/.env' | tr -d '\"')\""
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/openclaw/setup.sh or services/openclaw/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_no_agent_dirs_no_overlay
test_codex_also_mounted
test_origins_already_set
test_origins_stale_port_warns
test_port_override
test_https_port_follows_local_port
test_slow_first_boot
test_idempotent_rerun
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_container_owned
test_teardown_purge_refuses_odd_paths
test_teardown_purge_refuses_a_moved_dir
test_teardown_every_port_pointing_here
test_teardown_units_left_alone
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge_keeps_a_checkout_inside

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
