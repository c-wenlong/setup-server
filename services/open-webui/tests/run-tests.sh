#!/usr/bin/env bash
#
# Tests for services/open-webui/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id.

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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# ----------------------------------------------------------------- tests
test_preflight_docker_perms() {
  echo "• preflight fails when user cannot reach the docker daemon"
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
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "must be numeric"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env generated"                [ -f "$SVC/.env" ]
  check ".env points at local ollama"   env_has "OLLAMA_BASE_URL=http://127.0.0.1:11434"
  check "compose up invoked"            [ -f "$STATE_DIR/compose_up" ]
  check "data dir created under HOME"   [ -d "$HOME/services/open-webui/data" ]
  check "served on tailscale :3001"     calls_have "tailscale serve --bg --https=3001 http://127.0.0.1:3001"
  check "  and never the old :10000"    no_call "tailscale serve --bg --https=10000"
  check "prints final URL"              out_has "https://test-host.tailfake.ts.net:3001"
  check "warns about first signup"      out_has "first account registered becomes the admin"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  printf 'LOCAL_PORT=3001\nWEBUI_VOLUME=/tmp/x\nOLLAMA_BASE_URL=http://127.0.0.1:11434\n# my-custom-marker\n' > "$SVC/.env"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "existing .env untouched" env_has "my-custom-marker"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default next to a LOCAL_PORT override
  # publishes :<literal> -> 127.0.0.1:<moved>, i.e. the wrong backend.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3005
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=3005"   grep -qx 'LOCAL_PORT=3005' "$SVC/.env"
  check "served :3005 -> 127.0.0.1:3005" calls_have "tailscale serve --bg --https=3005 http://127.0.0.1:3005"
  check "  and never :3001"              no_call "tailscale serve --bg --https=3001"
  check "prints the :3005 URL"           out_has "https://test-host.tailfake.ts.net:3005"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3005 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:3005" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:3005"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_legacy_10000_mapping_is_withdrawn() {
  echo "• re-run on a box published on :10000: the old mapping is withdrawn"
  # Serve keeps every mapping it is given, so moving the published port only
  # ADDS one. Without the migration a re-run leaves two URLs for one service,
  # the retired one still answering.
  setup
  touch "$STATE_DIR/operator"
  printf '10000 http://127.0.0.1:3001\n' > "$STATE_DIR/served"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "published the new :3001"         calls_have "tailscale serve --bg --https=3001 http://127.0.0.1:3001"
  check "withdrew the legacy port"        calls_have "tailscale serve --https=10000 off"
  check "  and said so"                   out_has "Withdrawing the legacy :10000 mapping"
  check "  it is really gone from Serve"  bash -c "! grep -q '^10000 ' '$STATE_DIR/served'"
  check "  while :3001 remains"           grep -q '^3001 ' "$STATE_DIR/served"
  teardown

  echo "• a :10000 that belongs to something else is left alone"
  setup
  touch "$STATE_DIR/operator"
  printf '10000 http://127.0.0.1:9999\n' > "$STATE_DIR/served"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "never touched the other :10000"  no_call "tailscale serve --https=10000 off"
  check "  it is still published"         grep -q '^10000 http://127.0.0.1:9999$' "$STATE_DIR/served"
  teardown

  echo "• nothing to withdraw on a fresh box: no off call at all"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "no withdrawal attempted"         no_call "serve --https=10000 off"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=3001"
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
# address, never a wildcard or a LAN interface.
#
# The tailnet allowance became load-bearing here on 2026-09-13, when the
# published port stopped being 10000 and started following the local port:
# with 3001 -> 3001, tailscaled's own Serve proxy legitimately holds the
# tailnet address on the same number the container binds on loopback. The
# previous "anything that is not 127.0.0.1 is a leak" reading flagged that
# proxy and failed a correct deploy. Host networking makes the check matter
# more, not less: HOST=127.0.0.1 in docker-compose.yml is the only thing
# keeping the UI off the LAN, since there is no Docker publish spec.
#
# The function body below is the canonical implementation, byte-identical to
# immich's, vaultwarden's, jellyfin's, adguard's and homepage's.
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
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6]: tr, not a
                                                 # glob, because '[' is an
                                                 # invalid pattern under zsh
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
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  # Ask Serve which HTTPS port actually fronts this backend rather than
  # assuming it equals LOCAL_PORT. .env stores no HTTPS_PORT, so after a
  # deploy that passed one explicitly (HTTPS_PORT=8443 ./setup.sh) a fresh
  # shell has no other way to know, and guessing would fail a correct
  # deployment. A header with no port is :443.
  https_port="$("$ts" serve status 2>/dev/null | awk -v want="proxy http://127.0.0.1:$port" '
    /^https:\/\// { p = 443; if (match($1, /:[0-9]+$/)) p = substr($1, RSTART + 1) }
    p && index($0, want) { print p; exit }
  ')"
  [ -n "$https_port" ] || https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  live_check "container running"              sh -c "docker inspect -f '{{.State.Status}}' open-webui | grep -qx running"
  live_check "local health responds"          curl -fsS "http://127.0.0.1:$port/health"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "ollama reachable from host"     curl -fsS --max-time 3 "http://127.0.0.1:11434/api/version"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "the old :10000 mapping is gone"  sh -c "! '$ts' serve status | grep -q ':10000'"
  live_check "tailnet HTTPS responds"         curl -fsS -o /dev/null --max-time 30 "$url:$https_port/health"
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_https_port
test_fresh_deploy
test_idempotent_rerun
test_https_port_follows_local_port
test_legacy_10000_mapping_is_withdrawn
test_operator_escalation

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
