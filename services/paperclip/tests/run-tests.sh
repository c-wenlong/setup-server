#!/usr/bin/env bash
#
# Tests for services/paperclip/setup.sh.
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
  mkdir -p "$HOME" "$STATE_DIR" "$SVC/ui"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SVC/"
  cp "$SERVICE_DIR/ui/profile-credentials.js" "$SVC/ui/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID PAPERCLIP_PORT PAPERCLIP_HTTPS_PORT PAPERCLIP_DATA \
        AGENT_WORKSPACES PAPERCLIP_COMPANY_ID PAPERCLIP_API_KEY \
        PAPERCLIP_EMAIL PAPERCLIP_PASSWORD \
        STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

run_deploy_no_cli() {
  local nocli="$SANDBOX/nocli" filtered d s
  mkdir -p "$nocli"
  for s in tailscale curl sudo id systemctl loginctl launchctl node npx claude pkill; do
    ln -s "$STUBS/$s" "$nocli/$s"
  done
  # Drop any PATH dir that already has a real paperclipai (this box's
  # managed install lives in ~/.local/bin) so the test actually exercises
  # the npx install path instead of calling the host CLI.
  filtered="$nocli"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -x "$d/paperclipai" ] && continue
    filtered="$filtered:$d"
  done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
  OUT="$(printf '%s' "${1:-}" | PATH="$filtered" bash "$SVC/setup.sh" 2>&1)"
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

pc_cfg() {
  echo "$HOME/.paperclip/instances/default/config.json"
}

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "regular user"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "did not onboard"      [ ! -f "$STATE_DIR/onboarded" ]
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
  export PAPERCLIP_PORT=abc
  run_deploy
  check "PAPERCLIP_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "PAPERCLIP_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"                  [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_old_node() {
  echo "• preflight refuses Node.js older than 24.11"
  setup
  touch "$STATE_DIR/old_node"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "names the minimum"    out_has "24.11"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "did not call npx"     no_call "^npx "
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: authenticated loopback, published"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  mkdir -p "$HOME/.claude"
  printf 'host-cred\n' > "$HOME/.claude/.credentials.json"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check ".env generated"                     [ -f "$SVC/.env" ]
  check ".env is mode 600"                   [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records Paperclip port"        grep -qx 'PAPERCLIP_PORT=3100' "$SVC/.env"
  check "public Paperclip URL is HTTPS"      grep -q '^PAPERCLIP_PUBLIC_URL=https://test-host\.tailfake\.ts\.net:3100$' "$SVC/.env"
  check ".env has placeholder email"         grep -qx 'PAPERCLIP_EMAIL=changeme@example.com' "$SVC/.env"
  check ".env has placeholder password"      grep -qx 'PAPERCLIP_PASSWORD=changeme' "$SVC/.env"
  check "no OpenHands keys in .env"          ! grep -q '^OPENHANDS_' "$SVC/.env"
  check "workspaces created"                 [ -f "$HOME/agent-workspaces/paperclip-test/README.md" ]
  check "  and not the OpenHands one"        [ ! -f "$HOME/agent-workspaces/openhands-test/README.md" ]
  check "onboard used --bind tailnet"        calls_have "onboard --yes --bind tailnet"
  check "  and never --bind loopback"        no_call "onboard --yes --bind loopback"
  check "config rewritten to loopback"       grep -q '"bind": "loopback"' "$(pc_cfg)"
  check "  host is 127.0.0.1"                grep -q '"host": "127.0.0.1"' "$(pc_cfg)"
  check "  mode is authenticated"            grep -q '"deploymentMode": "authenticated"' "$(pc_cfg)"
  check "  not local_trusted"                ! grep -q 'local_trusted' "$(pc_cfg)"
  check "  MagicDNS is allowlisted"          grep -q 'test-host.tailfake.ts.net' "$(pc_cfg)"
  check "service installed"                  [ -f "$STATE_DIR/service_installed" ]
  check "did not invoke docker"              no_call "^docker "
  check "waited on Paperclip health"         calls_have "127.0.0.1:3100/api/health"
  check "served Paperclip :3100"             calls_have "tailscale serve --bg --https=3100 http://127.0.0.1:3100"
  check "did not serve OpenHands :8000"      no_call "https=8000"
  check "no sudo (operator + linger set)"    no_call "^sudo "
  check "CEO invite minted"                  [ -f "$HOME/services/paperclip/ceo-invite.txt" ]
  check "Profile overlay copied into ui-dist" [ -f "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/ui-dist/pc-profile-credentials.js" ]
  check "  index.html loads the overlay"     grep -q 'pc-profile-credentials.js' "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/ui-dist/index.html"
  check "  overlay has email and password"   grep -q 'pc-cred-email' "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/ui-dist/pc-profile-credentials.js"
  check "  and a password field"             grep -q 'pc-cred-new' "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/ui-dist/pc-profile-credentials.js"
  check "change-email enabled in Better Auth" grep -q 'updateEmailWithoutVerification' "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/dist/auth/better-auth.js"
  check "  verified-email check relaxed"     grep -q 'const canUpdateWithoutVerification = ctx.context.options.user.changeEmail.updateEmailWithoutVerification;' "$HOME/.paperclip/cli/current/node_modules/better-auth/dist/api/routes/update-user.mjs"
  check "prints Paperclip URL"               out_has "https://test-host.tailfake.ts.net:3100"
  check "does not print OpenHands URL :8000" out_lacks "ts.net:8000"
  check "warns to back up the secrets key"   out_has "master.key"
  check "never invoked Tailscale Funnel"     no_call "funnel"
  check "host Claude creds untouched"        grep -qx 'host-cred' "$HOME/.claude/.credentials.json"
  check "did not create ~/.codex"            [ ! -e "$HOME/.codex" ]
  teardown
}

test_managed_install_when_missing() {
  echo "• no paperclipai on PATH: official npx install, then onboard"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy_no_cli
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "npx paperclipai install --yes" calls_have "npx paperclipai install --yes"
  check "wrote the managed shim"        [ -x "$HOME/.local/bin/paperclipai" ]
  check "still onboarded"               [ -f "$STATE_DIR/onboarded" ]
  check "still published"               calls_have "tailscale serve --bg --https=3100"
  teardown
}

test_repairs_local_trusted() {
  echo "• onboard left local_trusted: rewritten before publish"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger" "$STATE_DIR/existing_trusted"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "mode is authenticated"   grep -q '"deploymentMode": "authenticated"' "$(pc_cfg)"
  check "local_trusted is gone"   ! grep -q 'local_trusted' "$(pc_cfg)"
  check "says it is not trusted"  out_has "not in local_trusted"
  check "still published"         calls_have "tailscale serve --bg --https=3100"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, onboard does not clobber config"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  python3 - "$(pc_cfg)" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["customKeep"] = "please-keep"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "existing .env untouched"      env_has "my-custom-marker"
  check "never invoked sudo"           no_call "^sudo "
  check "did not re-install the CLI"   no_call "npx paperclipai install"
  check "did not re-run onboard"       no_call "onboard"
  check "custom config field kept"     grep -q 'please-keep' "$(pc_cfg)"
  check "re-applied serve map"         calls_have "tailscale serve --bg --https=3100"
  check "CEO invite not rotated"       out_has "already minted"
  check "overlay script injected once" [ "$(grep -c 'pc-profile-credentials.js' "$HOME/.paperclip/cli/current/node_modules/@paperclipai/server/ui-dist/index.html")" -eq 1 ]
  check "login placeholders not duplicated" [ "$(grep -c '^PAPERCLIP_EMAIL=' "$SVC/.env")" -eq 1 ]
  teardown
}

test_appends_login_placeholders() {
  echo "• existing .env without login keys: placeholders appended, rest kept"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  grep -vE '^PAPERCLIP_(EMAIL|PASSWORD)=' "$SVC/.env" > "$SVC/.env.tmp"
  mv "$SVC/.env.tmp" "$SVC/.env"
  echo '# keep-me' >> "$SVC/.env"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "rest of .env kept"             env_has "keep-me"
  check "email placeholder appended"    grep -qx 'PAPERCLIP_EMAIL=changeme@example.com' "$SVC/.env"
  check "password placeholder appended" grep -qx 'PAPERCLIP_PASSWORD=changeme' "$SVC/.env"
  teardown
}

test_port_override() {
  echo "• port overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  export PAPERCLIP_PORT=3101
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env records Paperclip 3101"     grep -qx 'PAPERCLIP_PORT=3101' "$SVC/.env"
  check "health-checked Paperclip :3101"  calls_have "127.0.0.1:3101/api/health"
  check "served :3101"                    calls_have "tailscale serve --bg --https=3101 http://127.0.0.1:3101"
  check "prints the :3101 URL"            out_has "https://test-host.tailfake.ts.net:3101"

  export PAPERCLIP_PORT=3199
  run_deploy
  check "re-run: exits zero"              [ "$CODE" -eq 0 ]
  check "re-run: Paperclip override ignored" out_has "PAPERCLIP_PORT=3199 ignored"
  check "re-run: .env still 3101"         grep -qx 'PAPERCLIP_PORT=3101' "$SVC/.env"
  check "re-run: never touched 3199"      no_call "127.0.0.1:3199"
  teardown
}

test_https_follows_local_port() {
  echo "• a lone PAPERCLIP_PORT moves its HTTPS port too"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  export PAPERCLIP_PORT=3120
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "served :3120 -> 127.0.0.1:3120"      calls_have "tailscale serve --bg --https=3120 http://127.0.0.1:3120"
  check "  and never Paperclip :3100"         ! grep -q "tailscale serve --bg --https=3100" "$CALLS_LOG"
  teardown

  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  export PAPERCLIP_PORT=3121 PAPERCLIP_HTTPS_PORT=8444
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "explicit HTTPS_PORT still wins"      calls_have "tailscale serve --bg --https=8444 http://127.0.0.1:3121"
  check "prints the :8444 URL"                out_has "https://test-host.tailfake.ts.net:8444"
  teardown
}

test_slow_first_boot() {
  echo "• first boot is slow: the health loop waits instead of dying"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  echo 4 > "$STATE_DIR/health_fails_left"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "polled health repeatedly"      [ "$(grep -c '/api/health' "$CALLS_LOG")" -gt 4 ]
  check "still published"               calls_have "tailscale serve --bg --https=3100"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  touch "$STATE_DIR/linger"
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published Paperclip" calls_have "tailscale serve --bg --https=3100 http://127.0.0.1:3100"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=3100 http://127.0.0.1:3100"
  teardown
}

test_ceo_already_exists() {
  echo "• CEO already exists: treated as success, not a failed deploy"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger" "$STATE_DIR/ceo_exists"
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "says admin exists"     out_has "already exists"
  check "still prints the URL"  out_has "https://test-host.tailfake.ts.net:3100"
  teardown
}

test_agents_when_company_set() {
  echo "• PAPERCLIP_COMPANY_ID + API key: creates both local agents"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  printf 'PAPERCLIP_COMPANY_ID=co_stub\nPAPERCLIP_API_KEY=pc_stub\n' >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "created claude_local"        grep -q 'claude_local' "$STATE_DIR/agent_create"
  check "created codex_local"         grep -q 'codex_local' "$STATE_DIR/agent_create"
  check "cwd is the test workspace"   grep -q 'paperclip-test' "$STATE_DIR/agent_create"
  check "markers written"             [ -f "$HOME/services/paperclip/.agent-claude-local" ]
  : > "$STATE_DIR/agent_create"
  run_deploy
  check "third run does not re-hire"  [ ! -s "$STATE_DIR/agent_create" ]
  teardown
}

test_migrates_legacy_env() {
  echo "• paperclip-openhands/.env is split, not regenerated"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  mkdir -p "$SANDBOX/paperclip-openhands"
  # setup.sh looks at $SERVICE_DIR/../paperclip-openhands/.env — SVC is
  # $SANDBOX/svc, so sibling is $SANDBOX/paperclip-openhands.
  cat > "$SANDBOX/paperclip-openhands/.env" <<'EOF'
PAPERCLIP_PORT=3100
TZ=Asia/Singapore
AGENT_WORKSPACES=$HOME/agent-workspaces
PAPERCLIP_DATA=$HOME/.paperclip
TS_HOST=test-host.tailfake.ts.net
PAPERCLIP_PUBLIC_URL=https://test-host.tailfake.ts.net:3100
PAPERCLIP_COMPANY_ID=co_legacy
PAPERCLIP_API_KEY=pc_legacy
OPENHANDS_API_KEY=should-not-copy
OH_SECRET_KEY=should-not-copy
EOF
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "says it migrated"                out_has "Migrating Paperclip keys"
  check "kept company id"                 grep -qx 'PAPERCLIP_COMPANY_ID=co_legacy' "$SVC/.env"
  check "kept paperclip API key"          grep -qx 'PAPERCLIP_API_KEY=pc_legacy' "$SVC/.env"
  check "did not copy OpenHands secrets"  ! grep -q 'OPENHANDS_API_KEY' "$SVC/.env"
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
  local ts pc_port pc_https url cfg
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  pc_port="$(sed -n 's/^PAPERCLIP_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  pc_https="${PAPERCLIP_HTTPS_PORT:-$pc_port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  cfg="$HOME/.paperclip/instances/default/config.json"
  [ -f "$cfg" ] || cfg="$HOME/services/paperclip/instances/default/config.json"

  live_check "Paperclip local /api/health" \
    sh -c "curl -fsS 'http://127.0.0.1:$pc_port/api/health' | grep -q ok"
  live_check "Paperclip not listening off-loopback" no_external_listener "$pc_port"
  live_check "serve maps Paperclip :$pc_https" \
    sh -c "'$ts' serve status | grep -A2 ':$pc_https' | grep -q 'proxy http://127.0.0.1:$pc_port'"
  live_check "tailnet Paperclip HTTPS" \
    curl -fsS -o /dev/null --max-time 30 "$url:$pc_https/api/health"
  live_check "workspaces exist" \
    sh -c "test -d \"\$(sed -n 's/^AGENT_WORKSPACES=//p' '$SERVICE_DIR/.env')/paperclip-test\""
  if [ -f "$cfg" ]; then
    live_check "Paperclip is authenticated, not local_trusted" \
      sh -c "grep -q 'authenticated' '$cfg' && ! grep -q 'local_trusted' '$cfg'"
  fi
  if [ "$OS" = "Linux" ]; then
    live_check "lingering is on" \
      sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  fi
  live_check "Profile overlay is served" \
    sh -c "curl -fsS 'http://127.0.0.1:$pc_port/pc-profile-credentials.js' | grep -q pc-cred-email"
  live_check "index.html loads the overlay" \
    sh -c "curl -fsS 'http://127.0.0.1:$pc_port/' | grep -q pc-profile-credentials.js"
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ]; then
  red "services/paperclip/setup.sh is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_old_node
test_fresh_deploy
test_managed_install_when_missing
test_repairs_local_trusted
test_idempotent_rerun
test_appends_login_placeholders
test_port_override
test_https_follows_local_port
test_slow_first_boot
test_operator_escalation
test_serve_approval_prompt
test_ceo_already_exists
test_agents_when_company_set
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
