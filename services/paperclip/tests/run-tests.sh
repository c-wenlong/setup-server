#!/usr/bin/env bash
#
# Tests for services/paperclip/setup.sh and teardown.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SVC/"
  cp "$SERVICE_DIR/ui/profile-credentials.js" "$SVC/ui/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID PAPERCLIP_PORT PAPERCLIP_HTTPS_PORT PAPERCLIP_DATA \
        AGENT_WORKSPACES PAPERCLIP_COMPANY_ID PAPERCLIP_API_KEY \
        PAPERCLIP_EMAIL PAPERCLIP_PASSWORD FAKE_OS \
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

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

unit_file() { echo "$HOME/.config/systemd/user/paperclipai.service"; }
master_key() { echo "$HOME/.paperclip/instances/default/secrets/master.key"; }

# A deployed sandbox: setup.sh has run (unit file, instance, CLI store, CEO
# invite), both agent markers exist, the host has Claude / Codex logins, an
# agent left work in the workspace, Serve maps :3100 here, and neighbours sit
# on other ports (two of them lookalikes of 3100).
deployed() {
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  touch "$HOME/services/paperclip/.agent-claude-local" "$HOME/services/paperclip/.agent-codex-local"
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  printf 'host-cred\n' > "$HOME/.claude/.credentials.json"
  printf 'codex-auth\n' > "$HOME/.codex/auth.json"
  echo work > "$HOME/agent-workspaces/paperclip-test/agent-output.md"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:3100 (tailnet only)
|-- / proxy http://127.0.0.1:3100

https://test-host.tailfake.ts.net:13100 (tailnet only)
|-- / proxy http://127.0.0.1:13100

https://test-host.tailfake.ts.net:31000 (tailnet only)
|-- / proxy http://127.0.0.1:31000
EOF
  : > "$CALLS_LOG"
}

# Nothing outside this service changed: host logins, instance, CLI, workspace.
host_state_intact() {
  grep -qx 'host-cred' "$HOME/.claude/.credentials.json" \
    && grep -qx 'codex-auth' "$HOME/.codex/auth.json" \
    && [ -f "$(master_key)" ] \
    && [ -d "$HOME/.paperclip/cli/current" ] \
    && [ -f "$HOME/agent-workspaces/paperclip-test/agent-output.md" ]
}
nothing_changed() {
  [ -f "$SVC/.env" ] && [ -f "$(unit_file)" ] \
    && [ -f "$HOME/services/paperclip/ceo-invite.txt" ] \
    && ! grep -q -- " off" "$CALLS_LOG" \
    && ! grep -q -- "^systemctl --user disable" "$CALLS_LOG"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps everything, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "serve off for :3100"          calls_have "tailscale serve --https=3100 off"
  check "neighbour :2283 untouched"    no_call "https=2283"
  check "lookalike :13100 untouched"   no_call "https=13100"
  check "lookalike :31000 untouched"   no_call "https=31000"
  check "never serve reset"            no_call "serve reset"
  check "serve off before the stop"    [ "$(grep -n -e ' off$' -e 'disable --now' "$CALLS_LOG" | head -1 | grep -c ' off$')" -eq 1 ]
  check "disable --now paperclipai"    calls_have "systemctl --user disable --now paperclipai.service"
  check "unit file kept"               [ -f "$(unit_file)" ]
  check "no daemon-reload"             no_call "daemon-reload"
  check "never calls paperclipai"      no_call "^paperclipai "
  check "  (so never 'uninstall')"     no_call "uninstall"
  check "lingering untouched"          no_call "linger"
  check "no docker beyond a listing"   ! grep -v '^docker ps' "$CALLS_LOG" | grep -q '^docker '
  check ".env kept"                    [ -f "$SVC/.env" ]
  check "CEO invite kept"              [ -f "$HOME/services/paperclip/ceo-invite.txt" ]
  check "agent markers kept"           [ -f "$HOME/services/paperclip/.agent-codex-local" ]
  check "instance, CLI, logins kept"   host_state_intact
  check "says how to bring it back"    out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"            [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_differs() {
  echo "• teardown: an explicit PAPERCLIP_HTTPS_PORT is found from Serve"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  export PAPERCLIP_PORT=3121 PAPERCLIP_HTTPS_PORT=8444
  run_deploy
  unset PAPERCLIP_PORT PAPERCLIP_HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:8444 (tailnet only)\n|-- / proxy http://127.0.0.1:3121\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "serve off for :8444"          calls_have "tailscale serve --https=8444 off"
  check "  and not :3100"              no_call "https=3100"
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "no serve off"                 no_call " off"
  check "says already off"             out_has "already off"
  check "still disables the unit"      calls_have "systemctl --user disable --now paperclipai.service"
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:3100 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "no serve off"                 no_call " off"
  check "says nothing points here"     out_has "already off"
  teardown
}

test_teardown_port_hop() {
  echo "• teardown: Paperclip hopped to :3101 — the live port counts, a stale one does not"
  deployed
  local inst="$HOME/.paperclip/instances/default"
  printf '{"schemaVersion":1,"pid":4242,"host":"127.0.0.1","port":3101}\n' > "$inst/runtime-info.json"
  echo 4242 > "$STATE_DIR/ps_pid"
  echo "/usr/bin/node $HOME/.paperclip/cli/current/node_modules/paperclipai/dist/index.js run --instance default" \
    > "$STATE_DIR/ps_args"
  cat >> "$STATE_DIR/serve_status" <<EOF

https://test-host.tailfake.ts.net:3101 (tailnet only)
|-- / proxy http://127.0.0.1:3101
EOF
  run_teardown
  check "live hop: exits zero"         [ "$CODE" -eq 0 ]
  check "  :3100 off"                  calls_have "serve --https=3100 off"
  check "  :3101 (live port) off"      calls_have "serve --https=3101 off"
  check "  says it hopped"             out_has "hopped"
  check "  neighbour :2283 untouched"  no_call "https=2283"
  teardown

  deployed
  inst="$HOME/.paperclip/instances/default"
  printf '{"schemaVersion":1,"pid":4242,"host":"127.0.0.1","port":3101}\n' > "$inst/runtime-info.json"
  echo 4242 > "$STATE_DIR/ps_pid"
  echo "/usr/bin/python3 -m http.server 3101" > "$STATE_DIR/ps_args"
  cat >> "$STATE_DIR/serve_status" <<EOF

https://test-host.tailfake.ts.net:3101 (tailnet only)
|-- / proxy http://127.0.0.1:3101
EOF
  run_teardown
  check "pid reused by another program: exits zero" [ "$CODE" -eq 0 ]
  check "  :3101 left on"              no_call "https=3101"
  check "  warns about the stale record" out_has "that process is gone"
  check "  :3100 still off"            calls_have "serve --https=3100 off"
  rm -f "$STATE_DIR/ps_pid"
  : > "$CALLS_LOG"
  run_teardown
  check "dead pid: :3101 left on"      no_call "https=3101"
  teardown

  deployed
  python3 - "$HOME/.paperclip/instances/default/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["server"]["port"] = 3150
json.dump(c, open(p, "w"))
PY
  printf 'https://test-host.tailfake.ts.net:3150 (tailnet only)\n|-- / proxy http://127.0.0.1:3150\n' \
    >> "$STATE_DIR/serve_status"
  run_teardown
  check "config.json drift: exits zero" [ "$CODE" -eq 0 ]
  check "  warns about :3150"          out_has "says port 3150"
  check "  :3150 left on"              no_call "https=3150"
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"      [ "$CODE" -ne 0 ]
  check "no .env: explains"            out_has "nothing to tear down"
  check "no .env: touched nothing"     no_call "^systemctl "
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"         [ "$CODE" -ne 0 ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero" [ "$CODE" -ne 0 ]
  OUT="$(PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge extra 2>&1 </dev/null)"; CODE=$?
  check "two args: exits non-zero"     [ "$CODE" -ne 0 ]
  check "nothing changed"              nothing_changed
  sed -i.bak 's/^PAPERCLIP_PORT=.*/PAPERCLIP_PORT=abc/' "$SVC/.env"
  run_teardown
  check "bad port: exits non-zero"     [ "$CODE" -ne 0 ]
  sed -i.bak '/^PAPERCLIP_PORT=/d' "$SVC/.env"
  run_teardown
  check "no port: exits non-zero"      [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
  deployed
  sed -i.bak '/^PAPERCLIP_DATA=/d' "$SVC/.env"
  run_teardown
  check "no PAPERCLIP_DATA: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then exactly setup.sh's files go"
  deployed
  run_teardown --purge "paperclip-openhands"
  check "wrong name: exits non-zero"   [ "$CODE" -ne 0 ]
  check "wrong name: nothing changed"  nothing_changed
  check "wrong name: agent markers kept" [ -f "$HOME/services/paperclip/.agent-claude-local" ]
  run_teardown --purge ""
  check "empty answer: exits non-zero" [ "$CODE" -ne 0 ]
  check "empty answer: nothing changed" nothing_changed
  run_teardown --purge "paperclip"
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "serve off for :3100"          calls_have "tailscale serve --https=3100 off"
  check "neighbour :2283 untouched"    no_call "https=2283"
  check "unit disabled"                calls_have "systemctl --user disable --now paperclipai.service"
  check "unit file gone"               [ ! -e "$(unit_file)" ]
  check "daemon-reload after"          calls_have "systemctl --user daemon-reload"
  check "CEO invite + markers gone"    [ ! -e "$HOME/services/paperclip/ceo-invite.txt" ]
  check "marker dir gone"              [ ! -e "$HOME/services/paperclip" ]
  check "services dir itself kept"     [ -d "$HOME/services" ]
  check ".env gone"                    [ ! -f "$SVC/.env" ]
  check "master.key, CLI, workspace, logins kept" host_state_intact
  check "whole instance kept"          [ -f "$(pc_cfg)" ]
  check "never calls paperclipai"      no_call "^paperclipai "
  check "warns what master.key does"   out_has "master.key decrypts every secret"
  check "  says a DB backup is useless without it" out_has "any backup of the database is useless"
  check "prints the instance rm"       out_has "rm -rf -- '$HOME/.paperclip/instances/default'"
  check "prints the CLI store rm"      out_has "rm -rf -- '$HOME/.paperclip/cli'"
  check "prints a master.key copy"     out_has "cp -p '$(master_key)'"
  check "names the kept workspace"     out_has "$HOME/agent-workspaces/paperclip-test"
  : > "$CALLS_LOG"
  printf 'PAPERCLIP_PORT=3100\nPAPERCLIP_DATA=%s/.paperclip\n' "$HOME" > "$SVC/.env"
  run_teardown --purge "paperclip"
  check "re-run on a purged box: exits zero" [ "$CODE" -eq 0 ]
  check "  instance still kept"        [ -f "$(master_key)" ]
  teardown
}

test_teardown_purge_keeps_foreign_files() {
  echo "• teardown --purge: files setup.sh did not write in ~/services/paperclip stay"
  deployed
  echo mine > "$HOME/services/paperclip/notes.txt"
  run_teardown --purge "paperclip"
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "invite gone"                  [ ! -e "$HOME/services/paperclip/ceo-invite.txt" ]
  check "user file kept"               grep -qx mine "$HOME/services/paperclip/notes.txt"
  check "says the dir is kept"         out_has "still holds files setup.sh did not write"
  teardown
}

test_teardown_purge_missing_marker() {
  echo "• teardown --purge: a marker dir already gone is fine"
  deployed
  rm -rf "$HOME/services/paperclip"
  run_teardown --purge "paperclip"
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check ".env gone"                    [ ! -f "$SVC/.env" ]
  check "instance kept"                host_state_intact
  teardown
}

test_teardown_never_claude_codex() {
  echo "• teardown: a .env pointing a data var at ~/.claude or ~/.codex is refused"
  # @H@ stands for the sandbox $HOME, which only exists after deployed().
  local v val
  for v in PAPERCLIP_DATA AGENT_WORKSPACES; do
    for val in "@H@/.claude" "@H@/.claude/" "@H@/.claude/paperclip" "@H@/.codex" '${HOME}/.codex'; do
      deployed
      val="${val//@H@/$HOME}"
      sed -i.bak "s#^$v=.*#$v=$val#" "$SVC/.env"
      ls -la "$HOME/.claude" "$HOME/.codex" > "$SANDBOX/before"
      run_teardown --purge "paperclip"
      check "$v=$val: purge exits non-zero" [ "$CODE" -ne 0 ]
      check "  nothing changed"        nothing_changed
      check "  logins byte-identical"  host_state_intact
      ls -la "$HOME/.claude" "$HOME/.codex" > "$SANDBOX/after"
      check "  no file added or removed there" cmp -s "$SANDBOX/before" "$SANDBOX/after"
      teardown
    done
  done
  deployed
  ln -s "$HOME/.claude" "$HOME/pc-link"
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/pc-link#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "symlink into ~/.claude: refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
  deployed
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "PAPERCLIP_DATA=\$HOME (holds ~/.claude): refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
  # real_dir is what every deleted path goes through; it must refuse a marker
  # dir or marker file that leads into ~/.claude.
  deployed
  mv "$HOME/services/paperclip" "$SANDBOX/marker-real"
  cp "$SANDBOX/marker-real/ceo-invite.txt" "$HOME/.claude/ceo-invite.txt"
  ln -s "$HOME/.claude" "$HOME/services/paperclip"
  run_teardown --purge "paperclip"
  check "marker dir -> ~/.claude: refused" [ "$CODE" -ne 0 ]
  check "  ~/.claude/ceo-invite.txt kept" [ -f "$HOME/.claude/ceo-invite.txt" ]
  check "  logins kept"                host_state_intact
  check "  .env kept"                  [ -f "$SVC/.env" ]
  rm -f "$HOME/services/paperclip"
  teardown
  deployed
  rm -f "$HOME/services/paperclip/ceo-invite.txt"
  ln -s "$HOME/.claude/.credentials.json" "$HOME/services/paperclip/ceo-invite.txt"
  run_teardown --purge "paperclip"
  check "marker file -> ~/.claude creds: refused" [ "$CODE" -ne 0 ]
  check "  creds kept"                 host_state_intact
  check "  the link itself kept"       [ -L "$HOME/services/paperclip/ceo-invite.txt" ]
  teardown
  deployed
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/.claude#" "$SVC/.env"
  run_teardown
  check "default mode with PAPERCLIP_DATA=~/.claude: exits zero" [ "$CODE" -eq 0 ]
  check "  logins kept"                host_state_intact
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: odd PAPERCLIP_DATA / AGENT_WORKSPACES values are refused"
  # @H@ stands for the sandbox $HOME, which only exists after deployed().
  local val
  mkdir_neighbour() { mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"; }
  for val in "relative/.paperclip" "@H@/services/../.paperclip" "@H@/./.paperclip" \
             "@H@/.paperclip/." "@H@/.paperclip/.." "@H@/services/neighbour" \
             "@H@/services" "@H@/services/" "@H@/services/paperclip/a:b" "/" "@H@/.."; do
    deployed
    val="${val//@H@/$HOME}"
    mkdir_neighbour
    sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$val#" "$SVC/.env"
    run_teardown --purge "paperclip"
    check "PAPERCLIP_DATA=$val: refused" [ "$CODE" -ne 0 ]
    check "  nothing changed"          nothing_changed
    check "  neighbour kept"           [ -f "$HOME/services/neighbour/keep" ]
    teardown
  done
  deployed
  mkdir_neighbour
  sed -i.bak "s#^AGENT_WORKSPACES=.*#AGENT_WORKSPACES=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "AGENT_WORKSPACES in another service's dir: refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
  deployed
  ln -s "$HOME/services/neighbour" "$HOME/nb-link"
  mkdir_neighbour
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/nb-link#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "symlink into another service's dir: refused" [ "$CODE" -ne 0 ]
  teardown
  deployed
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/.paperclip//#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "trailing slashes on the real path: accepted" [ "$CODE" -eq 0 ]
  check "  printed path has no trailing slash" out_has "rm -rf -- '$HOME/.paperclip/instances/default'"
  check "  instance kept"              [ -f "$(master_key)" ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/paperclip"; echo x > "$HOME/paperclip/ceo-invite.txt"
  run_teardown --purge "paperclip"
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"     [ -f "$HOME/paperclip/ceo-invite.txt" ]
  check "nothing changed"              [ -f "$SVC/.env" ] && no_call " off"
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/paperclip survives"
  deployed
  local repo="$HOME/services/paperclip/setup-server/services/paperclip"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/paperclip/setup-server/other.env"
  OUT="$(printf '%s\n' "paperclip" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "checkout intact"              [ -f "$repo/teardown.sh" ] && [ -f "$repo/setup.sh" ]
  check "other services' files kept"   [ -f "$HOME/services/paperclip/setup-server/other.env" ]
  check "marker dir kept (not empty)"  [ -d "$HOME/services/paperclip" ]
  check "the other checkout's .env untouched" [ -f "$SVC/.env" ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3100 (tailnet only)
|-- / proxy http://127.0.0.1:3100

https://test-host.tailfake.ts.net:8444 (tailnet only)
|-- / proxy http://127.0.0.1:3100

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /pc proxy http://127.0.0.1:3100
EOF
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check ":3100 off"                    calls_have "serve --https=3100 off"
  check ":8444 off"                    calls_have "serve --https=8444 off"
  check "shared :443 left on"          no_call "https=443 off"
  check "warns about the shared port"  out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "says why"                     out_has "Could not read Tailscale Serve status"
  check "nothing changed"              nothing_changed
  run_teardown --purge "paperclip"
  check "purge: exits non-zero"        [ "$CODE" -ne 0 ]
  check "purge: nothing changed"       nothing_changed
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^PAPERCLIP_PORT=.*/export PAPERCLIP_PORT='3100'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"       [ "$CODE" -eq 0 ]
  check ":3100 off"                    calls_have "serve --https=3100 off"
  teardown
  deployed
  sed -i.bak -e 's/^PAPERCLIP_PORT=.*/PAPERCLIP_PORT="3100"/' "$SVC/.env"
  run_teardown
  check "double quotes"                [ "$CODE" -eq 0 ]
  check ":3100 off"                    calls_have "serve --https=3100 off"
  teardown
  deployed
  sed -i.bak -e 's/^PAPERCLIP_PORT=.*/PAPERCLIP_PORT=3100 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"               [ "$CODE" -eq 0 ]
  check ":3100 off"                    calls_have "serve --https=3100 off"
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=\"\${HOME}/.paperclip\"#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "\${HOME} form: exits zero"    [ "$CODE" -eq 0 ]
  check "  prints the expanded path"   out_has "rm -rf -- '$HOME/.paperclip/instances/default'"
  teardown
  deployed
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA='\$HOME/.paperclip'#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'PAPERCLIP_PORT=9999\n' >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"              out_has "PAPERCLIP_PORT is set more than once"
  check "  nothing changed"            nothing_changed
  teardown
  deployed
  printf 'X="first\nPAPERCLIP_DATA=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"     out_has "does not close on its line"
  teardown
  deployed
  printf 'Y="a\\"b"\n' >> "$SVC/.env"
  run_teardown
  check "backslash escape: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
}

test_teardown_refuses_compose_overrides() {
  echo "• teardown: COMPOSE_* in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "x" >> "$SVC/.env"
    run_teardown --purge "paperclip"
    check "$v in .env: exits non-zero" [ "$CODE" -ne 0 ]
    check "  nothing changed"          nothing_changed
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"            nothing_changed
  teardown
}

test_teardown_leaves_neighbours_alone() {
  echo "• teardown: OpenHands and other Paperclip-ish units / containers are named, not touched"
  deployed
  local ud="$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/usr/bin/docker start openhands-agent-canvas\n' > "$ud/agent-canvas.service"
  : > "$ud/paperclipai-staging.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$ud/unrelated.service"
  mkdir -p "$ud/default.target.wants"
  ln -s "$(unit_file)" "$ud/default.target.wants/paperclipai.service"
  printf 'openhands-agent-canvas\n' > "$STATE_DIR/docker_ps"
  run_teardown --purge "paperclip"
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "names the OpenHands unit"     out_has "Left alone (not created by this setup.sh): $ud/agent-canvas.service"
  check "names the other instance"     out_has "Left alone (not created by this setup.sh): $ud/paperclipai-staging.service"
  check "  not the unrelated unit"     out_lacks "unrelated.service"
  check "names the OpenHands container" out_has "openhands-agent-canvas"
  check "no systemctl call for them"   ! grep -E '^systemctl .*(agent-canvas|staging)' "$CALLS_LOG"
  check "their files kept"             [ -f "$ud/agent-canvas.service" ] && [ -f "$ud/paperclipai-staging.service" ]
  check "no docker stop / rm / compose" ! grep -E '^docker (stop|rm|kill|compose|container)' "$CALLS_LOG"
  check "lingering untouched"          no_call "linger"
  teardown
}

test_teardown_macos() {
  echo "• teardown on macOS: launchd bootout + disable, plist removed only on --purge"
  deployed
  local plist="$HOME/Library/LaunchAgents/ing.paperclip.paperclipai.plist"
  mkdir -p "$(dirname "$plist")"; echo '<plist/>' > "$plist"
  export FAKE_OS=Darwin
  touch "$STATE_DIR/launchd_loaded"
  run_teardown
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "asks launchd first"           calls_have "launchctl print gui/1000/ing.paperclip.paperclipai"
  check "bootout gui/<uid>/label"      calls_have "launchctl bootout gui/1000/ing.paperclip.paperclipai"
  check "disable gui/<uid>/label"      calls_have "launchctl disable gui/1000/ing.paperclip.paperclipai"
  check "no systemctl on macOS"        no_call "^systemctl "
  check "plist kept"                   [ -f "$plist" ]
  check "serve off for :3100"          calls_have "serve --https=3100 off"
  run_teardown --purge "paperclip"
  check "purge: exits zero"            [ "$CODE" -eq 0 ]
  check "purge: plist gone"            [ ! -e "$plist" ]
  check "purge: Linux unit file untouched" [ -f "$(unit_file)" ]
  check "purge: instance kept"         host_state_intact
  unset FAKE_OS
  teardown
}

test_teardown_macos_launchctl_failures() {
  echo "• teardown on macOS: a job launchd will not stop or disable stops the purge"
  local plist
  deployed
  plist="$HOME/Library/LaunchAgents/ing.paperclip.paperclipai.plist"
  mkdir -p "$(dirname "$plist")"; echo '<plist/>' > "$plist"
  export FAKE_OS=Darwin
  touch "$STATE_DIR/launchd_loaded" "$STATE_DIR/launchd_bootout_fails"
  run_teardown --purge "paperclip"
  check "bootout fails, still loaded: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                   out_has "bootout gui/1000/ing.paperclip.paperclipai failed"
  check "  .env kept"                  [ -f "$SVC/.env" ]
  check "  plist kept"                 [ -f "$plist" ]
  check "  markers kept"               [ -f "$HOME/services/paperclip/ceo-invite.txt" ]
  check "  no disable after it"        no_call "launchctl disable"
  rm -f "$STATE_DIR/launchd_bootout_fails"
  touch "$STATE_DIR/launchd_disable_fails"
  : > "$CALLS_LOG"
  run_teardown --purge "paperclip"
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                   out_has "disable gui/1000/ing.paperclip.paperclipai failed"
  check "  .env, plist, markers kept"  [ -f "$SVC/.env" ] && [ -f "$plist" ] && [ -f "$HOME/services/paperclip/ceo-invite.txt" ]
  rm -f "$STATE_DIR/launchd_disable_fails"
  touch "$STATE_DIR/launchd_loaded" "$STATE_DIR/launchd_bootout_fails_gone"
  : > "$CALLS_LOG"
  run_teardown
  check "bootout fails but job gone: exits zero" [ "$CODE" -eq 0 ]
  check "  still disables"             calls_have "launchctl disable gui/1000/ing.paperclip.paperclipai"
  rm -f "$STATE_DIR/launchd_bootout_fails_gone" "$plist"
  : > "$CALLS_LOG"
  run_teardown
  check "not loaded, no plist: exits zero" [ "$CODE" -eq 0 ]
  check "  no bootout"                 no_call "launchctl bootout"
  check "  no disable"                 no_call "launchctl disable"
  unset FAKE_OS
  teardown
}

test_teardown_purge_instance_layouts() {
  echo "• teardown --purge: the printed instance rm follows the config it found"
  deployed
  mkdir -p "$HOME/pcflat/secrets"
  echo '{}' > "$HOME/pcflat/config.json"; echo k > "$HOME/pcflat/secrets/master.key"
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/pcflat#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "flat instance: exits zero"    [ "$CODE" -eq 0 ]
  check "  prints its rm"              out_has "rm -rf -- '$HOME/pcflat'$"
  check "  prints its master.key"      out_has "cp -p '$HOME/pcflat/secrets/master.key'"
  check "  no nested path"             out_lacks "pcflat/instances/default"
  check "  instance kept"              [ -f "$HOME/pcflat/secrets/master.key" ]
  teardown
  deployed
  mkdir -p "$HOME/pcempty"
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/pcempty#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "home .paperclip fallback: exits zero" [ "$CODE" -eq 0 ]
  check "  prints its rm"              out_has "rm -rf -- '$HOME/.paperclip/instances/default'"
  check "  prints its master.key"      out_has "cp -p '$(master_key)'"
  check "  no rm for the empty data dir" out_lacks "pcempty/instances"
  check "  instance kept"              [ -f "$(pc_cfg)" ] && [ -f "$(master_key)" ]
  teardown
  deployed
  rm -f "$(pc_cfg)"
  mkdir -p "$HOME/pcnone/instances/default/secrets"
  echo k > "$HOME/pcnone/instances/default/secrets/master.key"
  sed -i.bak "s#^PAPERCLIP_DATA=.*#PAPERCLIP_DATA=$HOME/pcnone#" "$SVC/.env"
  run_teardown --purge "paperclip"
  check "no config anywhere: exits zero" [ "$CODE" -eq 0 ]
  check "  falls back to the nested default" out_has "rm -rf -- '$HOME/pcnone/instances/default'"
  check "  prints its master.key"      out_has "cp -p '$HOME/pcnone/instances/default/secrets/master.key'"
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
test_teardown_safe
test_teardown_https_port_differs
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_port_hop
test_teardown_preflight
test_teardown_purge
test_teardown_purge_keeps_foreign_files
test_teardown_purge_missing_marker
test_teardown_never_claude_codex
test_teardown_purge_refuses_odd_paths
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_home_variable_in_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_leaves_neighbours_alone
test_teardown_macos
test_teardown_macos_launchctl_failures
test_teardown_purge_instance_layouts

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
