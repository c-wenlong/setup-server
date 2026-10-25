#!/usr/bin/env bash
#
# Tests for services/openhands/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

data_dir() { sed -n 's/^OPENHANDS_DATA=//p' "$SVC/.env"; }

# uid 10001 can still write $1: an ACL entry, or the a+rwx fallback.
grant_kept() {
  getfacl -p "$1" 2>/dev/null | grep -q 'user:10001:rwx' \
    || [ -n "$(find "$1" -maxdepth 0 -perm -0002 2>/dev/null)" ]
}

# A deployed sandbox: setup.sh has run (with ~/.claude, so the creds overlay
# exists), Serve maps this port to this service, neighbours sit on other
# ports (one a lookalike suffix), and Docker lists this project's container
# plus unrelated ones.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/.claude"
  printf 'host-cred\n' > "$HOME/.claude/.credentials.json"
  run_deploy
  mkdir -p "$(data_dir)/conversations"
  echo keep > "$(data_dir)/settings.json"
  echo mine > "$HOME/agent-workspaces/openhands-test/work.txt"
  mkdir -p "$HOME/agent-workspaces/paperclip-test"
  echo pc > "$HOME/agent-workspaces/paperclip-test/keep"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3100 (tailnet only)
|-- / proxy http://127.0.0.1:3100

https://test-host.tailfake.ts.net:8000 (tailnet only)
|-- / proxy http://127.0.0.1:8000

https://test-host.tailfake.ts.net:18000 (tailnet only)
|-- / proxy http://127.0.0.1:18000
EOF
  printf '%s\n' 'openhands-agent-canvas|openhands' 'paperclip-db|paperclip' 'stirling-pdf|stirling-pdf' \
    > "$STATE_DIR/containers"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data, .env, workspaces and ACLs; unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8000"         calls_have "tailscale serve --https=8000 off"
  check "neighbour :3100 untouched"   no_call "https=3100"
  check "lookalike :18000 untouched"  no_call "https=18000"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  on the openhands dir + base file" calls_have "compose --project-directory $SVC -f $SVC/docker-compose.yml"
  check "  with the creds overlay setup.sh uses" calls_have "-f $SVC/docker-compose.creds.yml down"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no other container touched"  no_call "docker rm\|docker stop\|docker kill"
  check "no unit touched"             no_call "systemctl\|launchctl"
  check "data kept"                   [ -f "$(data_dir)/settings.json" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "creds overlay kept"          [ -f "$SVC/docker-compose.creds.yml" ]
  check "host Claude creds untouched" grep -qx 'host-cred' "$HOME/.claude/.credentials.json"
  check "workspaces kept"             [ -f "$HOME/agent-workspaces/openhands-test/work.txt" ]
  check "  Paperclip's workspace kept" [ -f "$HOME/agent-workspaces/paperclip-test/keep" ]
  check "data dir grant left alone"   grant_kept "$(data_dir)"
  check "workspace grant left alone"  grant_kept "$HOME/agent-workspaces"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_no_overlay() {
  echo "• teardown: no creds overlay means compose down on the base file only"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  printf 'https://test-host.tailfake.ts.net:8000 (tailnet only)\n|-- / proxy http://127.0.0.1:8000\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no overlay on disk"          [ ! -f "$SVC/docker-compose.creds.yml" ]
  check "down without an overlay -f"  calls_have "-f $SVC/docker-compose.yml down"
  teardown
}

test_teardown_https_port_override() {
  echo "• teardown: a separate HTTPS port is found from serve status"
  setup
  touch "$STATE_DIR/operator"
  export OPENHANDS_HTTPS_PORT=8444
  run_deploy
  unset OPENHANDS_HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:8444 (tailnet only)\n|-- / proxy http://127.0.0.1:8000\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8444"         calls_have "tailscale serve --https=8444 off"
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
  printf 'https://test-host.tailfake.ts.net:8000 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  check "no docker: nothing unpublished" no_call " off"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then data, .env and marker go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "open-hands"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/settings.json" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "openhands"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker ~/services/openhands gone" [ ! -e "$HOME/services/openhands" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "serve off for :8000"         calls_have "tailscale serve --https=8000 off"
  check "down only, never down -v"    no_call "down -v"
  check "no cleanup container needed" no_call "entrypoint sh"
  check "creds overlay kept"          [ -f "$SVC/docker-compose.creds.yml" ]
  check "host Claude creds untouched" grep -qx 'host-cred' "$HOME/.claude/.credentials.json"
  check "workspaces kept"             [ -f "$HOME/agent-workspaces/openhands-test/work.txt" ]
  check "  openhands-test README kept" [ -f "$HOME/agent-workspaces/openhands-test/README.md" ]
  check "  Paperclip's workspace kept" [ -f "$HOME/agent-workspaces/paperclip-test/keep" ]
  check "workspace grant NOT removed" grant_kept "$HOME/agent-workspaces"
  check "  openhands-test grant NOT removed" grant_kept "$HOME/agent-workspaces/openhands-test"
  if getfacl -p "$HOME/agent-workspaces" 2>/dev/null | grep -q 'user:10001:'; then
    check "prints the exact setfacl -x" out_has "setfacl -x u:10001 $HOME/agent-workspaces$"
    check "  and the default-ACL one"   out_has "setfacl -d -x u:10001 $HOME/agent-workspaces/openhands-test$"
  else
    check "prints the chmod o-w"        out_has "chmod o-w $HOME/agent-workspaces "
  fi
  check "no unit touched"             no_call "systemctl\|launchctl"
  teardown
}

test_teardown_purge_container_owned() {
  echo "• teardown --purge: container-owned files are cleared by the image on the box, not sudo"
  deployed
  local dir; dir="$(data_dir)"
  # Stand-in for uid-10001 files: a read-only dir the host user cannot empty.
  mkdir -p "$dir/conversations/locked"; echo x > "$dir/conversations/locked/f"
  chmod 500 "$dir/conversations/locked"
  run_teardown --purge "openhands"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the image from .env"    calls_have "ghcr.io/openhands/agent-canvas:latest"
  check "never pulled for it"         calls_have "pull never"
  check "mounted only the data dir"   calls_have "-v $dir:/x"
  check "no sudo"                     no_call "^sudo"
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(data_dir)"
  mkdir -p "$dir/conversations/locked"; echo x > "$dir/conversations/locked/f"
  chmod 500 "$dir/conversations/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "openhands"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  deployed
  sed -i.bak 's/^OPENHANDS_VERSION=.*/OPENHANDS_VERSION=latest@evil/' "$SVC/.env"
  run_teardown --purge "openhands"
  check "odd image tag: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  data kept"                 [ -f "$(data_dir)/settings.json" ]
  teardown
}

test_teardown_ambiguous_containers() {
  echo "• teardown: openhands-looking containers outside the project are listed and left"
  deployed
  printf '%s\n' 'openhands-agent-canvas|openhands' 'openhands-runtime-abc123|' \
    'paperclip-db|paperclip' >> "$STATE_DIR/containers"
  run_teardown
  check "default: exits zero"         [ "$CODE" -eq 0 ]
  check "  names the runtime container" out_has "openhands-runtime-abc123 (compose project: none)"
  check "  does not stop or remove it" no_call "docker rm\|docker stop\|docker kill"
  check "  does not name Paperclip's"  out_lacks "paperclip-db"
  check "  own project still down"    [ -f "$STATE_DIR/compose_down" ]
  rm -f "$STATE_DIR/compose_down"; : > "$CALLS_LOG"
  run_teardown --purge "openhands"
  check "purge: exits non-zero"       [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "will not run while the containers above exist"
  check "  data kept"                 [ -f "$(data_dir)/settings.json" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  nothing unpublished"       no_call " off"
  teardown
  deployed
  printf '%s\n' 'openhands-agent-canvas|paperclip-openhands' > "$STATE_DIR/containers"
  run_teardown
  check "legacy-project container: exits zero" [ "$CODE" -eq 0 ]
  check "  named, not removed"        out_has "openhands-agent-canvas (compose project: paperclip-openhands)"
  check "  no docker rm"              no_call "docker rm"
  teardown
  deployed
  touch "$STATE_DIR/ps_list_fails"
  run_teardown
  check "unlistable containers: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing unpublished"       no_call " off"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_foreign_units() {
  echo "• teardown: units that mention openhands but setup.sh did not create are named, not touched"
  deployed
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/usr/bin/paperclipai run --openhands-url http://127.0.0.1:8000\n' \
    > "$HOME/.config/systemd/user/paperclip.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/other.service"
  run_teardown --purge "openhands"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns naming the unit"       out_has "paperclip.service mentions openhands"
  check "  does not name the unrelated one" out_lacks "other.service"
  check "  unit file kept"            [ -f "$HOME/.config/systemd/user/paperclip.service" ]
  check "  no systemctl call"         no_call "systemctl"
  teardown
}

test_teardown_purge_protects_creds() {
  echo "• teardown --purge: host credentials reached through the data dir are refused"
  deployed
  local dir; dir="$(data_dir)"
  mkdir -p "$dir/claude-real"; echo secret > "$dir/claude-real/.credentials.json"
  rm -rf "$HOME/.claude"; ln -s "$dir/claude-real" "$HOME/.claude"
  run_teardown --purge "openhands"
  check ".claude inside data: exits non-zero" [ "$CODE" -ne 0 ]
  check "  creds kept"                [ -f "$dir/claude-real/.credentials.json" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  rm -f "$HOME/.claude"; mkdir -p "$HOME/.claude"
  mkdir -p "$dir/codex-copy"; echo tok > "$dir/codex-copy/auth.json"
  printf 'services:\n  openhands:\n    volumes:\n      - %s:/home/openhands/.codex\n' "$dir/codex-copy" \
    > "$SVC/docker-compose.creds.yml"
  run_teardown --purge "openhands"
  check "overlay mount inside data: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it is mounted as credentials" out_has "mounted into the container as credentials"
  check "  mounted file kept"         [ -f "$dir/codex-copy/auth.json" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/agent-workspaces#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "workspaces refused"          [ "$CODE" -ne 0 ]
  check "  workspaces kept"           [ -f "$HOME/agent-workspaces/openhands-test/work.txt" ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./openhands" "$HOME/services/openhands/.."; do
    sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$dotted#" "$SVC/.env"
    run_teardown --purge "openhands"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "own data never touched"      [ -f "$HOME/services/openhands/data/settings.json" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8010 (tailnet only)
|-- / proxy http://127.0.0.1:8000

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8000

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /oh proxy http://127.0.0.1:8000
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8010 off"                   calls_have "serve --https=8010 off"
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
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^OPENHANDS_PORT=.*/export OPENHANDS_PORT='8000'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8000 off"                   calls_have "serve --https=8000 off"
  teardown
  deployed
  sed -i.bak -e 's/^OPENHANDS_PORT=.*/OPENHANDS_PORT="8000"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check ":8000 off"                   calls_have "serve --https=8000 off"
  teardown
  deployed
  sed -i.bak -e 's/^OPENHANDS_PORT=.*/OPENHANDS_PORT=8000 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check ":8000 off"                   calls_have "serve --https=8000 off"
  teardown
  deployed
  sed -i.bak -e 's/^OPENHANDS_PORT=.*/OPENHANDS_PORT=80o0/' "$SVC/.env"
  run_teardown
  check "non-numeric port refused"    [ "$CODE" -ne 0 ]
  check "  nothing unpublished"       no_call " off"
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "openhands"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services/neighbour" "$HOME/services/openhands/link"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/openhands/link/#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "symlinked leaf with trailing slash refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$dir///#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine, marker still goes"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "openhands"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "empty marker removed"        [ ! -e "$HOME/services/openhands" ]
  teardown
  deployed
  rm -rf "$(data_dir)"
  echo note > "$HOME/services/openhands/README"
  run_teardown --purge "openhands"
  check "non-empty marker: exits zero" [ "$CODE" -eq 0 ]
  check "  marker kept (rmdir only)"  [ -f "$HOME/services/openhands/README" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(data_dir)"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=\$HOME${dir#"$HOME"}#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "\$HOME form: exits zero"     [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(data_dir)"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "openhands"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/openhands itself or inside it"
  deployed
  local d
  for d in neighbour paperclip paperclip-openhands; do
    mkdir -p "$HOME/services/$d"; echo x > "$HOME/services/$d/keep"
    sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/$d#" "$SVC/.env"
    run_teardown --purge "openhands"
    check "$d dir refused"            [ "$CODE" -ne 0 ]
    check "  its data kept"           [ -f "$HOME/services/$d/keep" ]
    check "  nothing stopped"         [ ! -f "$STATE_DIR/compose_down" ]
  done
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/openhands/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/openhands/a:b"
  run_teardown --purge "openhands"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/openhands/data"; echo x > "$HOME/openhands/data/keep"
  run_teardown --purge "openhands"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/openhands/data/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'OPENHANDS_DATA=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "OPENHANDS_DATA is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nOPENHANDS_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
    run_teardown --purge "openhands"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no compose call"           no_call "compose --project-directory"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/openhands survives"
  deployed
  local repo="$HOME/services/openhands/setup-server/services/openhands"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/openhands/setup-server/other.env"
  sed -i.bak "s#^OPENHANDS_DATA=.*#OPENHANDS_DATA=$HOME/services/openhands#" "$repo/.env"
  OUT="$(printf '%s\n' "openhands" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/openhands/setup-server/other.env" ]
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/openhands/setup.sh or docker-compose.yml is missing — nothing to test."
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
test_teardown_safe
test_teardown_no_overlay
test_teardown_https_port_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_container_owned
test_teardown_ambiguous_containers
test_teardown_foreign_units
test_teardown_purge_protects_creds
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
