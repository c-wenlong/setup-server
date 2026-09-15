#!/usr/bin/env bash
#
# Tests for openhands/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# The mocked suite runs the real script inside a sandbox: fake $HOME, and
# PATH stubs for every external command the script touches. Nothing
# touches the real system, and ~/.claude / ~/.codex on the host are never
# opened.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
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
  unset FAKE_UID OPENHANDS_PORT OPENHANDS_HTTPS_PORT OPENHANDS_DATA \
        AGENT_WORKSPACES STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  local ok=0
  if [ "${1:-}" = "!" ]; then
    shift
    if ! "$@"; then ok=1; fi
  elif "$@"; then
    ok=1
  fi
  if [ "$ok" -eq 1 ]; then
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

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

compose_has()      { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
no_wildcard_bind() { ! compose_has '0\.0\.0\.0'; }

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
    check "suggests usermod / sg docker" out_has "docker"
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
  export OPENHANDS_PORT=80o0
  run_deploy
  check "OPENHANDS_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "OPENHANDS_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"                  [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: loopback Canvas, published"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude"
  printf 'host-cred\n' > "$HOME/.claude/.credentials.json"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has an OpenHands API key"      grep -qE '^OPENHANDS_API_KEY=[a-f0-9]{32}$' "$SVC/.env"
  check ".env has OH_SECRET_KEY"             grep -qE '^OH_SECRET_KEY=[a-f0-9]{32}$' "$SVC/.env"
  check ".env records OpenHands port"        grep -qx 'OPENHANDS_PORT=8000' "$SVC/.env"
  check "no Paperclip keys in .env"          ! grep -q '^PAPERCLIP_' "$SVC/.env"
  check "public OpenHands URL is HTTPS"      grep -q '^OPENHANDS_PUBLIC_URL=https://test-host\.tailfake\.ts\.net:8000$' "$SVC/.env"
  check "compose binds loopback only"        compose_hasF '127.0.0.1:${OPENHANDS_PORT'
  check "compose binds no wildcard"          no_wildcard_bind
  check "compose does not request privileged" ! compose_has 'privileged'
  check "compose uses official Agent Canvas" compose_has 'ghcr.io/openhands/agent-canvas'
  check "compose project is openhands"       compose_hasF 'name: openhands'
  check "compose runs --public"              compose_hasF '--public'
  check "compose mounts /projects not /"     compose_has '/projects'
  check "  and not the host root"            ! grep -qE -- '- /:/' "$SVC/docker-compose.yml"
  check "workspaces created"                 [ -f "$HOME/agent-workspaces/openhands-test/README.md" ]
  check "  and not the Paperclip one"        [ ! -f "$HOME/agent-workspaces/paperclip-test/README.md" ]
  check "OpenHands data dir lets uid 10001 write" \
    sh -c "getfacl -p '$HOME/services/openhands/data' 2>/dev/null | grep -q 'user:10001:rwx' || python3 -c \"import os,stat,sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & stat.S_IWOTH else 1)\" '$HOME/services/openhands/data'"
  check "  workspaces too" \
    sh -c "getfacl -p '$HOME/agent-workspaces' 2>/dev/null | grep -q 'user:10001:rwx' || python3 -c \"import os,stat,sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & stat.S_IWOTH else 1)\" '$HOME/agent-workspaces'"
  check "did not call paperclipai"           no_call "paperclipai"
  check "did not call npx"                   no_call "^npx "
  check "compose up invoked"                 [ -f "$STATE_DIR/compose_up" ]
  check "waited on OpenHands"                calls_have "127.0.0.1:8000/"
  check "served OpenHands :8000"             calls_have "tailscale serve --bg --https=8000 http://127.0.0.1:8000"
  check "did not serve Paperclip :3100"      no_call "https=3100"
  check "no sudo (operator set)"             no_call "^sudo "
  check "prints OpenHands URL"               out_has "https://test-host.tailfake.ts.net:8000"
  check "does not print Paperclip :3100"     out_lacks "ts.net:3100"
  check "never invoked Tailscale Funnel"     no_call "funnel"
  check "host Claude creds untouched"        grep -qx 'host-cred' "$HOME/.claude/.credentials.json"
  check "did not create ~/.codex"            [ ! -e "$HOME/.codex" ]
  check "creds overlay mounts ~/.claude"     grep -q '.claude' "$SVC/docker-compose.creds.yml"
  check "  and not /"                        ! grep -qE -- '- /:' "$SVC/docker-compose.creds.yml"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  key="$(sed -n 's/^OPENHANDS_API_KEY=//p' "$SVC/.env")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "existing .env untouched"      env_has "my-custom-marker"
  check "API key unchanged"            [ "$(sed -n 's/^OPENHANDS_API_KEY=//p' "$SVC/.env")" = "$key" ]
  check "never invoked sudo"           no_call "^sudo "
  check "compose up re-invoked"        [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve map"         calls_have "tailscale serve --bg --https=8000"
  teardown
}

test_port_override() {
  echo "• port overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export OPENHANDS_PORT=8001
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env records OpenHands 8001"     grep -qx 'OPENHANDS_PORT=8001' "$SVC/.env"
  check "health-checked OpenHands :8001"  calls_have "127.0.0.1:8001/"
  check "served :8001"                    calls_have "tailscale serve --bg --https=8001 http://127.0.0.1:8001"
  check "prints the :8001 URL"            out_has "https://test-host.tailfake.ts.net:8001"

  export OPENHANDS_PORT=8099
  run_deploy
  check "re-run: exits zero"              [ "$CODE" -eq 0 ]
  check "re-run: OpenHands override ignored" out_has "OPENHANDS_PORT=8099 ignored"
  check "re-run: .env still 8001"         grep -qx 'OPENHANDS_PORT=8001' "$SVC/.env"
  check "re-run: never touched 8099"      no_call "127.0.0.1:8099"
  teardown
}

test_https_follows_local_port() {
  echo "• a lone OPENHANDS_PORT moves its HTTPS port too"
  setup
  touch "$STATE_DIR/operator"
  export OPENHANDS_PORT=8010
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "served :8010 -> 127.0.0.1:8010"      calls_have "tailscale serve --bg --https=8010 http://127.0.0.1:8010"
  check "  and never OpenHands :8000"         ! grep -q "tailscale serve --bg --https=8000" "$CALLS_LOG"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export OPENHANDS_PORT=8010 OPENHANDS_HTTPS_PORT=8444
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "explicit HTTPS_PORT still wins"      calls_have "tailscale serve --bg --https=8444 http://127.0.0.1:8010"
  check "prints the :8444 URL"                out_has "https://test-host.tailfake.ts.net:8444"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loop waits instead of dying"
  setup
  touch "$STATE_DIR/operator"
  echo 4 > "$STATE_DIR/health_fails_left"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "polled health repeatedly"      [ "$(grep -c '127\.0\.0\.1:8000' "$CALLS_LOG")" -gt 4 ]
  check "still published"               calls_have "tailscale serve --bg --https=8000"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published OpenHands" calls_have "tailscale serve --bg --https=8000 http://127.0.0.1:8000"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8000 http://127.0.0.1:8000"
  teardown
}

test_creds_overlay_not_overwritten() {
  echo "• existing compose creds overlay is left alone"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  printf '# user-edited overlay\n' > "$SVC/docker-compose.creds.yml"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "overlay marker kept"     grep -q 'user-edited overlay' "$SVC/docker-compose.creds.yml"
  check "says it left it"         out_has "leaving untouched"
  teardown
}

test_migrates_legacy_env() {
  echo "• paperclip-openhands/.env is split, secrets not rotated"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$SANDBOX/paperclip-openhands"
  cat > "$SANDBOX/paperclip-openhands/.env" <<'EOF'
OPENHANDS_VERSION=latest
OPENHANDS_MEM_LIMIT=2g
OPENHANDS_PORT=8000
TZ=Asia/Singapore
OPENHANDS_DATA=$HOME/services/openhands/data
AGENT_WORKSPACES=$HOME/agent-workspaces
TS_HOST=test-host.tailfake.ts.net
OPENHANDS_PUBLIC_URL=https://test-host.tailfake.ts.net:8000
OPENHANDS_API_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OH_SECRET_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PAPERCLIP_PORT=3100
PAPERCLIP_API_KEY=should-not-copy
EOF
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "says it migrated"                out_has "Migrating OpenHands keys"
  check "kept OPENHANDS_API_KEY"          grep -qx 'OPENHANDS_API_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$SVC/.env"
  check "kept OH_SECRET_KEY"              grep -qx 'OH_SECRET_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$SVC/.env"
  check "did not copy Paperclip keys"     ! grep -q 'PAPERCLIP_' "$SVC/.env"
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
    host="${addr%:*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
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
  local ts oh_port oh_https url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  oh_port="$(sed -n 's/^OPENHANDS_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  oh_https="${OPENHANDS_HTTPS_PORT:-$oh_port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "openhands container running" \
    sh -c "docker inspect -f '{{.State.Status}}' openhands-agent-canvas | grep -qx running"
  live_check "OpenHands local UI answers" \
    sh -c "curl -fsS -o /dev/null 'http://127.0.0.1:$oh_port/' || curl -fsS -o /dev/null 'http://127.0.0.1:$oh_port/canvas'"
  live_check "OpenHands agent server is up (no 502 on /health)" \
    sh -c "code=\$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:$oh_port/health'); [ \"\$code\" != 502 ]"
  live_check "OpenHands agent server is up (no 502 to :18000)" \
    sh -c "code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 'http://127.0.0.1:$oh_port/health'); [ \"\$code\" != 502 ] && [ \"\$code\" != 000 ]"
  live_check "OpenHands not listening off-loopback" no_external_listener "$oh_port"
  live_check "serve maps OpenHands :$oh_https" \
    sh -c "'$ts' serve status | grep -A2 ':$oh_https' | grep -q 'proxy http://127.0.0.1:$oh_port'"
  live_check "tailnet OpenHands HTTPS" \
    sh -c "curl -fsS -o /dev/null --max-time 30 '$url:$oh_https/' || curl -fsS -o /dev/null --max-time 30 '$url:$oh_https/canvas'"
  live_check "workspaces exist" \
    sh -c "test -d \"\$(sed -n 's/^AGENT_WORKSPACES=//p' '$SERVICE_DIR/.env')/openhands-test\""
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "openhands/setup.sh or docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_fresh_deploy
test_idempotent_rerun
test_port_override
test_https_follows_local_port
test_slow_first_boot
test_operator_escalation
test_serve_approval_prompt
test_creds_overlay_not_overwritten
test_migrates_legacy_env

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
