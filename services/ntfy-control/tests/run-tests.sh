#!/usr/bin/env bash
#
# Tests for services/ntfy-control/setup.sh + control_listener.py.
#
# The listener's allowlist is NOT in the listener: it is the per-service
# `control` block in app/web/services.json, which the launcher's web UI reads
# for the same purpose. The handler tests below therefore run against the REAL
# shipped registry (found via the repo-relative candidate in
# _registry_candidates), which is what makes "the phone and the web control
# the same services" a thing this suite can actually check.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment

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
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/ntfy-control"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC" "$SANDBOX/repo/services/monitoring"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" \
     "$SERVICE_DIR/control_listener.py" "$SERVICE_DIR/kuma_toggle.py" "$SVC/"
  # The listener's credentials come out of monitoring/.env (its setup.sh
  # creates the `control` account there); this fixture stands in for it.
  cat > "$SANDBOX/repo/services/monitoring/.env" <<'EOF'
NTFY_CONTROL_USER=control
NTFY_CONTROL_PASS=testpass123
EOF
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID NTFY_PORT CONTROL_TOPIC REPLY_TOPIC STATE_DIR CALLS_LOG \
        CONTROL_APPS_DIR TEST_NTFY_USER TEST_NTFY_PASS
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# $1 is the typed --purge confirmation (empty for the plain remove).
run_teardown() {
  if [ "${2:-}" = "--purge" ]; then
    OUT="$(printf '%s\n' "$1" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"
  else
    OUT="$(PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" 2>&1)"
  fi
  CODE=$?
}

# Run the listener's one-shot handler as the subscribe loop would. The
# deployed unit gets NTFY_USER/NTFY_PASS from .env; TEST_NTFY_USER="" runs
# the anonymous variant (a pre-auth ntfy deploy).
run_handle() {
  OUT="$(NTFY_BASE_URL=http://127.0.0.1:3003 CONTROL_TOPIC=control REPLY_TOPIC=alerts \
    PUBLIC_NTFY_URL=https://test-host.tailfake.ts.net:3003 \
    NTFY_USER="${TEST_NTFY_USER-control}" NTFY_PASS="${TEST_NTFY_PASS-testpass123}" \
    KUMA_ENV_FILE="$SANDBOX/kuma.env" \
    PATH="$STUBS:$PATH" python3 "$SERVICE_DIR/control_listener.py" --handle "$1" 2>&1)"
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
out_lacks()  { ! grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# Order matters for multi-container services (Immich's server has to go
# before the database it is still talking to), and one `docker stop a b c`
# would not give it: the docker CLI stops containers in parallel. So the
# listener issues one command per part, and these assert the sequence.
call_line()      { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1; }
calls_in_order() {
  local prev=0 n pat
  for pat in "$@"; do
    n="$(call_line "$pat")"
    [ -n "$n" ] || return 1
    [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
  return 0
}

# The shipped registry both front ends read.
REGISTRY="$(cd "$SERVICE_DIR/../.." && pwd)/app/web/services.json"
registry_keys() {
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
locked = ("ntfy", "launcher")
print(" ".join(sorted(
    s["key"] for s in doc["services"]
    if isinstance(s.get("control"), dict)
    and not s["control"].get("locked")
    and s["key"] not in locked)))' "$REGISTRY"
}

# ----------------------------------------------------------------- tests
test_preflight_ntfy_down() {
  echo "• preflight fails when ntfy is not reachable"
  setup
  touch "$STATE_DIR/ntfy_down"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "ntfy is not reachable"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  check "wrote no .env"  [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_install() {
  echo "• fresh install: listener deployed, unit enabled, instructions printed"
  setup
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check ".env has control topic"    env_has "CONTROL_TOPIC=control"
  check ".env has reply topic"      env_has "REPLY_TOPIC=alerts"
  check ".env has tailnet URL"      env_has "PUBLIC_NTFY_URL=https://test-host.tailfake.ts.net:3003"
  check ".env has ntfy user"        env_has "NTFY_USER=control"
  check ".env has ntfy pass"        env_has "NTFY_PASS=testpass123"
  check ".env is mode 600"          sh -c "[ \"\$(stat -c %a '$SVC/.env' 2>/dev/null || stat -f %Lp '$SVC/.env')\" = 600 ]"
  check "auth probe ran"            calls_have 'control/json?poll=1'
  check "listener installed"        [ -x "$HOME/services/ntfy-control/bin/control_listener.py" ]
  check "kuma toggle installed"     [ -f "$HOME/services/ntfy-control/bin/kuma_toggle.py" ]
  if [ "$OS" = "Linux" ]; then
    check "unit written"            [ -f "$HOME/.config/systemd/user/ntfy-control.service" ]
    check "unit loads .env"         grep -q "EnvironmentFile=$SVC/.env" "$HOME/.config/systemd/user/ntfy-control.service"
    command -v sg >/dev/null && \
    check "docker group via sg"     grep -q "sg docker -c" "$HOME/.config/systemd/user/ntfy-control.service"
    check "service restarted"       calls_have "systemctl --user restart ntfy-control"
    check "lingering enabled"       calls_have "loginctl enable-linger"
  else
    check "launch agent written"    [ -f "$HOME/Library/LaunchAgents/com.ntfy-control.listener.plist" ]
  fi
  check "prints usage"              out_has "stop seafile"
  check "panel sent with creds"     calls_have '\-u control:testpass123 -d panel http://127.0.0.1:3003/control'
  check "no phone -> onboarding"    out_has "No phone detected"
  check "onboarding has server URL" out_has "https://test-host.tailfake.ts.net:3003"
  teardown
}

test_fresh_install_with_phone() {
  echo "• fresh install with a phone on the tailnet: no onboarding lecture"
  setup
  touch "$STATE_DIR/phone_peer"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "phone detected"            out_has "Phone found on the tailnet"
  check "no onboarding walkthrough" out_lacks "No phone detected"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  run_deploy
  echo "# CUSTOM-MARK do-not-clobber" >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "edited .env preserved"  env_has "CUSTOM-MARK"
  check "creds still there"      env_has "NTFY_PASS=testpass123"
  check "never invoked sudo"     no_call "^sudo "
  teardown
}

test_auth_required() {
  echo "• ntfy requires auth: stored creds are verified then used"
  setup
  touch "$STATE_DIR/ntfy_auth"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "says auth verified"         out_has "ntfy auth verified for user 'control'"
  check "probe carried the creds"    calls_have '\-u control:testpass123 http://127.0.0.1:3003/control/json?poll=1'
  check "panel sent with creds"      calls_have '\-u control:testpass123 -d panel'
  teardown
}

test_auth_required_no_creds() {
  echo "• ntfy requires auth but .env has none: dies naming the fix"
  setup
  rm "$SANDBOX/repo/services/monitoring/.env"   # monitoring too old to have creds
  touch "$STATE_DIR/ntfy_auth"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names monitoring setup"  out_has "services/monitoring/setup.sh"
  check "no unit installed"       [ ! -f "$HOME/.config/systemd/user/ntfy-control.service" ]
  teardown
}

test_auth_rejected() {
  echo "• ntfy rejects the stored creds: dies naming the fix"
  setup
  touch "$STATE_DIR/ntfy_auth" "$STATE_DIR/ntfy_auth_reject"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says rejected"           out_has "ntfy rejected the NTFY_USER/NTFY_PASS"
  check "no unit installed"       [ ! -f "$HOME/.config/systemd/user/ntfy-control.service" ]
  teardown
}

test_env_migration_adds_creds() {
  echo "• a pre-auth .env gains NTFY_USER/NTFY_PASS pulled from monitoring/.env"
  setup
  cat > "$SVC/.env" <<'EOF'
NTFY_BASE_URL=http://127.0.0.1:3003
PUBLIC_NTFY_URL=https://test-host.tailfake.ts.net:3003
CONTROL_TOPIC=control
REPLY_TOPIC=alerts
KUMA_ENV_FILE=/tmp/monitoring.env
SERVICE_HOME=/tmp/svc
TOOL_DIR=/tmp
EOF
  touch "$STATE_DIR/ntfy_auth"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "user appended"           env_has "NTFY_USER=control"
  check "pass appended"           env_has "NTFY_PASS=testpass123"
  check "verified with them"      out_has "ntfy auth verified for user 'control'"
  teardown
}

test_plist_escapes_env_values() {
  echo "• launchd plist: XML-special characters in .env values are escaped and mode is 600"
  setup
  touch "$STATE_DIR/fake_macos"
  export CONTROL_TOPIC='a<b&c'
  PLIST="$HOME/Library/LaunchAgents/com.ntfy-control.listener.plist"
  mkdir -p "$(dirname "$PLIST")"
  : > "$PLIST"
  chmod 644 "$PLIST"
  run_deploy
  mode="$(stat -c '%a' "$PLIST" 2>/dev/null || stat -f '%Lp' "$PLIST")"
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "plist written"           [ -f "$PLIST" ]
  check "plist mode 600"          [ "$mode" = "600" ]
  check "value is escaped"        grep -q 'a&lt;b&amp;c' "$PLIST"
  check "no raw chars left"       sh -c "! grep -q 'a<b&c' '$PLIST'"
  teardown
}

test_handle_sends_credentials() {
  echo "• listener: every ntfy call and HTTP action button carries basic auth from NTFY_USER/NTFY_PASS"
  setup
  run_handle "panel"
  expected_b64="$(printf 'control:testpass123' | base64 | tr -d '\n')"
  check "reply used -u"           calls_have '\-u control:testpass123'
  check "reply hit alerts"        calls_have 'http://127.0.0.1:3003/alerts$'
  check "buttons carry auth hdr"  calls_have "X-Actions.*\"Authorization\": \"Basic $expected_b64\""
  teardown
}

test_handle_anonymous() {
  echo "• listener without creds sends no -u and no action auth header (pre-auth ntfy keeps working)"
  setup
  TEST_NTFY_USER="" TEST_NTFY_PASS="" run_handle "panel"
  check "still replies"           calls_have 'pick start'
  check "no -u sent"              no_call ' -u '
  check "no action auth header"   no_call '"Authorization"'
  teardown
}

test_handle_stop() {
  echo "• handler: 'stop seafile' stops the stack in order and pauses Kuma"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  run_handle "stop seafile"
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "one command per container"  calls_have "docker stop seafile$"
  check "stops app before deps"      calls_in_order "docker stop seafile$" \
                                       "docker stop seafile-mysql" \
                                       "docker stop seafile-redis"
  check "pauses BEFORE stopping"     calls_in_order "kuma_toggle.py pause seafile" \
                                       "docker stop seafile$"
  check "pauses kuma monitor"        calls_have "uv run --with uptime-kuma-api python3 .*kuma_toggle.py pause seafile"
  check "replies ok to alerts"       calls_have "seafile: stop ok.*http://127.0.0.1:3003/alerts"
  check "reply offers start (now stopped)"  calls_have 'seafile: stop ok.*X-Actions.*start seafile'
  check "reply does not offer stop"         no_call 'seafile: stop ok.*"body": "stop seafile"'
  check "buttons use tailnet URL"           calls_have 'X-Actions.*test-host.tailfake.ts.net:3003/control'
  teardown
}

test_handle_immich() {
  echo "• handler: immich stops server->ml->datastores, starts in reverse"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  run_handle "stop immich"
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "server before datastores"   calls_in_order "docker stop immich_server" \
                                       "docker stop immich_machine_learning" \
                                       "docker stop immich_redis" \
                                       "docker stop immich_postgres"
  check "pauses the immich monitor"  calls_have "kuma_toggle.py pause immich"
  : > "$CALLS_LOG"
  run_handle "start immich"
  check "datastores before server"   calls_in_order "docker start immich_postgres" \
                                       "docker start immich_redis" \
                                       "docker start immich_machine_learning" \
                                       "docker start immich_server"
  check "resumes the monitor"        calls_have "kuma_toggle.py resume immich"
  teardown
}

test_handle_immich_without_ml() {
  echo "• handler: immich with the ml profile off — optional part is skipped"
  setup
  touch "$STATE_DIR/missing_immich_machine_learning"
  run_handle "stop immich"
  check "still reports ok"           calls_have "immich: stop ok"
  check "tried the ml container"     calls_have "docker stop immich_machine_learning"
  check "datastores still stopped"   calls_in_order "docker stop immich_server" \
                                       "docker stop immich_redis" \
                                       "docker stop immich_postgres"
  teardown
}

test_handle_immich_required_failure_stops_there() {
  echo "• handler: a REQUIRED container failing aborts the rest of the stop"
  setup
  touch "$STATE_DIR/missing_immich_server"
  run_handle "stop immich"
  check "reports failure"            calls_have "immich: stop FAILED"
  check "never touched the database" no_call "docker stop immich_postgres"
  teardown
}

test_handle_beszel() {
  echo "• handler: beszel moves hub and agent together"
  setup
  run_handle "stop beszel"
  check "agent stopped before hub"   calls_in_order "systemctl --user disable --now beszel-agent.service" \
                                       "docker stop beszel"
  : > "$CALLS_LOG"
  run_handle "start beszel"
  check "hub started before agent"   calls_in_order "docker start beszel" \
                                       "systemctl --user enable --now beszel-agent.service"
  teardown
}

test_handle_manimkc() {
  echo "• handler: manimkc is a systemd user unit"
  setup
  run_handle "restart manimkc"
  check "stops then starts the unit" calls_in_order "systemctl --user disable --now manimkc.service" \
                                       "systemctl --user enable --now manimkc.service"
  check "no docker involved"         no_call "docker stop manimkc\|docker start manimkc"
  teardown
}

test_shared_allowlist() {
  echo "• allowlist: the listener controls exactly what app/web/services.json says"
  setup
  run_handle "status"
  local key
  for key in $(registry_keys); do
    check "lists $key"               calls_have "$key: "
  done
  check "immich is covered"          calls_have "immich: "
  check "beszel is covered"          calls_have "beszel: "
  check "manimkc is covered"         calls_have "manimkc: "
  teardown
}

test_missing_registry_controls_nothing() {
  echo "• allowlist: no registry file => nothing is controllable, and it says so"
  setup
  OUT="$(NTFY_BASE_URL=http://127.0.0.1:3003 CONTROL_TOPIC=control REPLY_TOPIC=alerts \
    CONTROL_REGISTRY="$SANDBOX/does-not-exist.json" \
    KUMA_ENV_FILE="$SANDBOX/kuma.env" \
    PATH="$STUBS:$PATH" python3 "$SERVICE_DIR/control_listener.py" --handle "stop seafile" 2>&1)"
  check "refuses the service"     calls_have "unknown service 'seafile'"
  check "says the list is empty"  calls_have "control registry not found"
  check "nothing executed"        no_call "docker stop"
  teardown
}

test_handle_panel() {
  echo "• handler: 'panel' sends the menu card — live list as body, verb buttons"
  setup
  touch "$STATE_DIR/stopped_n8n"
  run_handle "panel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "body lists running svc"      calls_have 'seafile: running'
  check "body lists stopped svc"      calls_have 'n8n: exited'
  check "start button -> picker"      calls_have '"body": "pick start"'
  check "stop button -> picker"       calls_have '"body": "pick stop"'
  check "restart button -> picker"    calls_have '"body": "pick restart"'
  check "no service touched"          no_call "docker stop\|docker start\|systemctl --user stop\|systemctl --user disable"
  teardown
}

test_handle_pick() {
  echo "• handler: pickers are state-filtered — stop shows active, start shows stopped"
  setup
  touch "$STATE_DIR/stopped_n8n"
  run_handle "pick stop"
  check "header says active"          calls_have 'stop which? active:'
  check "running svc offered"         calls_have '"body": "stop seafile"'
  check "stopped svc not offered"     no_call '"body": "stop n8n"'
  : > "$CALLS_LOG"
  run_handle "pick start"
  check "header says stopped"         calls_have 'start which? stopped:'
  check "stopped svc offered"         calls_have '"body": "start n8n"'
  check "running svc not offered"     no_call '"body": "start seafile"'
  check "picker links back to menu"   calls_have '"label": "menu"'
  teardown
}

test_handle_pick_empty() {
  echo "• handler: empty picker explains itself instead of showing nothing"
  setup
  # Every controllable service's parts, down. Derived from the shared
  # registry rather than hardcoded: this list used to be a literal, and it
  # silently went stale the moment services were added to
  # app/web/services.json (forgejo, jellyfin, vaultwarden), leaving the
  # picker non-empty and this test asserting the wrong thing.
  while IFS= read -r part; do
    [ -n "$part" ] && touch "$STATE_DIR/stopped_$part"
  done <<EOF
$(python3 - "$SERVICE_DIR/../../app/web/services.json" <<'PYEOF'
import json, sys
HARD_LOCKED = {"launcher", "ntfy"}
doc = json.load(open(sys.argv[1]))
for svc in doc.get("services") or []:
    key, block = svc.get("key"), svc.get("control")
    if key in HARD_LOCKED or not isinstance(block, dict) or block.get("locked"):
        continue
    for part in block.get("parts") or []:
        name = part.get("container") or part.get("unit")
        if name:
            print(name)
PYEOF
)
EOF
  run_handle "pick stop"
  check "explains nothing to stop"    calls_have "nothing to stop"
  check "offers menu"                 calls_have '"body": "panel"'
  teardown
}

test_handle_start() {
  echo "• handler: 'start seafile' starts deps first and resumes Kuma"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  run_handle "start seafile"
  check "starts deps before app"     calls_in_order "docker start seafile-redis" \
                                       "docker start seafile-mysql" \
                                       "docker start seafile$"
  check "resumes AFTER starting"     calls_in_order "docker start seafile$" \
                                       "kuma_toggle.py resume seafile"
  check "resumes kuma monitor"       calls_have "kuma_toggle.py resume seafile"
  check "replies ok"                 calls_have "seafile: start ok"
  check "reply offers stop (now up)" calls_have 'seafile: start ok.*"body": "stop seafile"'
  teardown
}

test_handle_status() {
  echo "• handler: 'status' reports every service"
  setup
  run_handle "status"
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "reply includes n8n state"   calls_have "n8n: running"
  check "no start/stop invoked"      no_call "docker stop\|docker start"
  teardown
}

test_handle_rejects_unknown() {
  echo "• handler: allowlist — unknown services and commands are rejected"
  setup
  run_handle "stop ntfy"
  check "ntfy not stoppable"      calls_have "unknown service 'ntfy'"
  check "no docker stop"          no_call "docker stop"
  # The other deliberate lock-out: the launcher serves the web UI you would
  # have to use to start it again. (ollama used to sit on this list as a
  # system unit needing sudo; it is a user unit now, so "stop ollama" is
  # honoured like any other service.)
  : > "$CALLS_LOG"
  run_handle "stop ollama"
  check "ollama IS stoppable now"  calls_have "ollama: stop ok"
  check "systemctl stop ran"       calls_have "systemctl --user disable --now ollama.service"
  : > "$CALLS_LOG"
  run_handle "restart launcher"
  check "launcher not stoppable"  calls_have "unknown service 'launcher'"
  check "nothing executed"        no_call "systemctl --user stop\|systemctl --user restart\|systemctl --user disable"
  : > "$CALLS_LOG"
  : > "$CALLS_LOG"
  run_handle "rm -rf /"
  check "junk gets usage reply"   calls_have "commands: panel"
  check "nothing executed"        no_call "docker "
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

test_live() {
  echo "• live: verify the real deployment on this machine"
  local port topic user pass cred read_user read_pass read_cred mon_env
  port="$(sed -n 's|^NTFY_BASE_URL=http://127.0.0.1:\([0-9]*\)$|\1|p' "$SERVICE_DIR/.env")"
  topic="$(sed -n 's/^CONTROL_TOPIC=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  user="$(sed -n 's/^NTFY_USER=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  pass="$(sed -n 's/^NTFY_PASS=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  cred=""; [ -n "$user" ] && cred="-u $user:$pass"
  # The control account has write-only access on alerts; read the reply back
  # using the phone account (read-only on alerts) from monitoring/.env.
  mon_env="$SERVICE_DIR/../monitoring/.env"
  read_user="$(sed -n 's/^NTFY_PHONE_USER=\(.*\)$/\1/p' "$mon_env" 2>/dev/null || true)"
  read_pass="$(sed -n 's/^NTFY_PHONE_PASS=\(.*\)$/\1/p' "$mon_env" 2>/dev/null || true)"
  read_cred="$cred"
  [ -n "$read_user" ] && [ -n "$read_pass" ] && read_cred="-u $read_user:$read_pass"
  live_check "ntfy healthy"          curl -fsS "http://127.0.0.1:$port/v1/health"
  if [ "$OS" = "Linux" ]; then
    live_check "listener active"     sh -c "systemctl --user is-active ntfy-control | grep -qx active"
    live_check "lingering enabled"   sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded" sh -c "launchctl print gui/$(id -u)/com.ntfy-control.listener"
  fi
  # end-to-end: publish `status`, expect the listener to reply on the alerts
  # topic — authenticated, since the server is deny-all.
  curl -fsS -o /dev/null $cred -d "status" "http://127.0.0.1:$port/$topic" && sleep 3
  live_check "status round-trip"     sh -c "curl -fsS $read_cred 'http://127.0.0.1:$port/alerts/json?poll=1&since=30s' | grep -q 'server-control'"
}

# A stop_guard is a script in the repo, so these run against a fixture repo
# rather than the shipped registry: the real one would run the real
# services/adguard/teardown.sh. The guard here is a stub that records its
# argv and passes or fails on $STATE_DIR/guard_says_no.
guard_repo() {  # guard_repo <stop_guard JSON>
  GREPO="$SANDBOX/repo"
  mkdir -p "$GREPO/app/web" "$GREPO/services/adguard"
  cat > "$GREPO/services/adguard/guard.sh" <<'SH'
#!/usr/bin/env bash
echo "guard $*" >> "$CALLS_LOG"
echo "checking things on stdout"
if [ -f "$STATE_DIR/guard_says_no" ]; then
  printf '\033[1;31m \342\234\227 \033[0m%s\n' "The tailnet still uses 100.77.77.77 for DNS. Nothing was changed." >&2
  exit 1
fi
exit 0
SH
  chmod +x "$GREPO/services/adguard/guard.sh"
  cat > "$GREPO/app/web/services.json" <<JSON
{"services": [
  {"key": "adguard", "control": {"parts": [{"container": "adguard"}],
   "kuma": ["adguard", "adguard-dns"], "stop_guard": $1}},
  {"key": "n8n", "control": {"parts": [{"container": "n8n"}], "kuma": "n8n"}}
]}
JSON
}

run_handle_fixture() {
  OUT="$(NTFY_BASE_URL=http://127.0.0.1:3003 CONTROL_TOPIC=control REPLY_TOPIC=alerts \
    CONTROL_REGISTRY="$GREPO/app/web/services.json" \
    KUMA_ENV_FILE="$SANDBOX/kuma.env" \
    PATH="$STUBS:$PATH" python3 "$SERVICE_DIR/control_listener.py" --handle "$1" 2>&1)"
  CODE=$?
}

test_handle_stop_guard() {
  echo "• handler: a stop_guard runs before stop, and a failing one refuses it"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  guard_repo '["services/adguard/guard.sh", "--check-dns"]'
  touch "$STATE_DIR/guard_says_no"
  run_handle_fixture "stop adguard"
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "ran the guard with its flag"  calls_have "^guard --check-dns$"
  check "container not stopped"        no_call "docker stop"
  check "kuma never paused"            no_call "kuma_toggle.py pause"
  check "replies refused"              calls_have "adguard: stop refused, nothing was changed"
  check "  with the guard's reason"    calls_have "still uses 100.77.77.77 for DNS. Nothing was changed."
  check "  without colour codes"       no_call $'\033\\['
  check "  and without the cross"      no_call $'\342\234\227'
  check "  and not its stdout chatter" no_call "checking things on stdout"
  check "reply still offers stop (it is running)" calls_have 'stop refused.*X-Actions.*"body": "stop adguard"'
  teardown

  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  guard_repo '["services/adguard/guard.sh", "--check-dns"]'
  run_handle_fixture "stop adguard"
  check "passing guard: ran first"     calls_in_order "^guard --check-dns$" "kuma_toggle.py pause adguard" "docker stop adguard"
  check "passing guard: stop ok"       calls_have "adguard: stop ok"
  teardown

  setup
  guard_repo '["services/adguard/guard.sh", "--check-dns"]'
  touch "$STATE_DIR/guard_says_no"
  run_handle_fixture "restart adguard"
  check "restart is not guarded"       no_call "^guard"
  check "  and restarts"               calls_in_order "docker stop adguard" "docker start adguard"
  run_handle_fixture "start adguard"
  check "start is not guarded"         no_call "^guard"
  run_handle_fixture "stop n8n"
  check "a service with no guard stops as before" calls_have "docker stop n8n"
  teardown

  local bad
  for bad in '["services/adguard/missing.sh"]' '["../outside.sh"]' '"services/adguard/guard.sh"' \
      '["services/adguard/guard.sh", "--x;rm"]' '[]'; do
    setup
    guard_repo "$bad"
    touch "$SANDBOX/outside.sh"; chmod +x "$SANDBOX/outside.sh"
    run_handle_fixture "stop adguard"
    check "unusable guard $bad: refused"  calls_have "adguard: stop refused"
    check "  container not stopped"       no_call "docker stop"
    check "  guard never ran"             no_call "^guard"
    teardown
  done
}

# One listener process handling several messages, as the subscribe loop
# does, so the registry cache is live between them. $1 is Python run with
# the module imported as `cl`.
run_py_fixture() {
  OUT="$(NTFY_BASE_URL=http://127.0.0.1:3003 CONTROL_TOPIC=control REPLY_TOPIC=alerts \
    CONTROL_REGISTRY="$GREPO/app/web/services.json" \
    KUMA_ENV_FILE="$SANDBOX/kuma.env" \
    PATH="$STUBS:$PATH" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cl", sys.argv[1])
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)
exec(sys.argv[2])' "$SERVICE_DIR/control_listener.py" "$1" 2>&1)"
  CODE=$?
}

test_handle_stop_guard_resolved_at_stop_time() {
  echo "• handler: a guard file restored after a refused stop counts at once"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  guard_repo '["services/adguard/guard.sh", "--check-dns"]'
  mv "$GREPO/services/adguard/guard.sh" "$SANDBOX/guard.sh.away"
  export SANDBOX_AWAY="$SANDBOX/guard.sh.away" GUARD_HOME="$GREPO/services/adguard/guard.sh"
  run_py_fixture '
import os, shutil
cl.handle("stop adguard")
with open(os.environ["CALLS_LOG"], "a") as fh:
    fh.write("--- restored ---\n")
shutil.move(os.environ["SANDBOX_AWAY"], os.environ["GUARD_HOME"])
cl.handle("stop adguard")'
  unset SANDBOX_AWAY GUARD_HOME
  check "first stop refused (guard missing)" calls_in_order "adguard: stop refused" "--- restored ---"
  check "second stop ran the restored guard"  calls_in_order "--- restored ---" "^guard --check-dns$" "docker stop adguard"
  check "  and reported ok"                   calls_have "adguard: stop ok"
  teardown
}

test_handle_stop_guard_timeout() {
  echo "• handler: a hung guard is killed with its children and the stop refused"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  guard_repo '["services/adguard/guard.sh", "--check-dns"]'
  cat > "$GREPO/services/adguard/guard.sh" <<'SH'
#!/usr/bin/env bash
echo "guard $*" >> "$CALLS_LOG"
sleep 60 &
echo $! > "$STATE_DIR/child.pid"
wait
SH
  chmod +x "$GREPO/services/adguard/guard.sh"
  local started=$SECONDS
  run_py_fixture 'cl.GUARD_TIMEOUT = 1
cl.handle("stop adguard")'
  check "returned within a few seconds"   [ $((SECONDS - started)) -lt 10 ]
  check "guard ran"                       calls_have "^guard --check-dns$"
  check "replies refused"                 calls_have "adguard: stop refused, nothing was changed"
  check "  and says why"                  calls_have "ran past 1s"
  check "container not stopped"           no_call "docker stop"
  check "kuma never paused"               no_call "kuma_toggle.py pause"
  local child; child="$(cat "$STATE_DIR/child.pid" 2>/dev/null)"
  check "the guard's child was killed too" sh -c "[ -n '$child' ] && ! kill -0 '$child' 2>/dev/null"
  [ -n "$child" ] && kill "$child" 2>/dev/null
  teardown
}

# A launcher app's allowlist entry comes from its definition file in the
# apps dir (CONTROL_APPS_DIR overrides ~/services/launcher/apps), not from
# services.json: container app-<key>, kuma from the definition. These run
# against a fixture repo so the shipped services.json stays out of it.
apps_repo() {
  GREPO="$SANDBOX/repo"
  APPS_DIR="$SANDBOX/apps"
  export CONTROL_APPS_DIR="$APPS_DIR"
  mkdir -p "$GREPO/app/web" "$APPS_DIR"
  cat > "$GREPO/app/web/services.json" <<'JSON'
{"services": [
  {"key": "n8n", "control": {"parts": [{"container": "n8n"}], "kuma": "n8n"}},
  {"key": "locked-svc"}
]}
JSON
}

test_handle_launcher_apps() {
  echo "• apps dir: launcher app defs join the allowlist, kuma and all"
  setup
  echo "KUMA_PORT=3002" > "$SANDBOX/kuma.env"
  apps_repo
  cat > "$APPS_DIR/kaichenpedia.json" <<'JSON'
{"key": "kaichenpedia", "name": "kaichenpedia", "repo": "o/kaichenpedia",
 "ref": "main", "method": "dockerfile", "dockerfile": "Dockerfile",
 "context": ".", "container_port": 8000, "port": 8091,
 "health_path": "/", "volume": null, "kuma": "kaichenpedia"}
JSON
  # Neighbours that must not break or shadow the good entries.
  echo "{ not json" > "$APPS_DIR/broken.json"
  cat > "$APPS_DIR/launcher.json" <<'JSON'
{"key": "launcher", "name": "not the launcher"}
JSON
  cat > "$APPS_DIR/n8n.json" <<'JSON'
{"key": "n8n", "name": "n8n as an app"}
JSON
  cat > "$APPS_DIR/locked-svc.json" <<'JSON'
{"key": "locked-svc", "name": "shadows a registry key"}
JSON
  cat > "$APPS_DIR/compose-app.json" <<'JSON'
{"key": "compose-app", "method": "compose",
 "compose_file": "docker-compose.yml", "kuma": "k1"}
JSON
  cat > "$APPS_DIR/script-app.json" <<'JSON'
{"key": "script-app", "method": "script", "cmd": "./run.sh", "kuma": "k2"}
JSON
  cat > "$APPS_DIR/nomethod-app.json" <<'JSON'
{"key": "nomethod-app", "name": "no method = dockerfile"}
JSON
  ln -s "$SANDBOX/gone.json" "$APPS_DIR/dangling.json"
  run_handle_fixture "stop kaichenpedia"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "app works past bad neighbours" calls_have "kaichenpedia: stop ok"
  check "kuma paused before stop"     calls_in_order "kuma_toggle.py pause kaichenpedia" \
                                        "docker stop app-kaichenpedia"
  : > "$CALLS_LOG"
  run_handle_fixture "start kaichenpedia"
  check "container then resume"       calls_in_order "docker start app-kaichenpedia" \
                                        "kuma_toggle.py resume kaichenpedia"
  : > "$CALLS_LOG"
  run_handle_fixture "stop launcher"
  check "hard-locked app key ignored" calls_have "unknown service 'launcher'"
  check "nothing executed"            no_call "docker stop"
  : > "$CALLS_LOG"
  run_handle_fixture "stop n8n"
  check "services.json wins the key"  calls_have "docker stop n8n$"
  check "  not the app container"     no_call "docker stop app-n8n"
  : > "$CALLS_LOG"
  run_handle_fixture "stop locked-svc"
  check "uncontrollable key still wins" calls_have "unknown service 'locked-svc'"
  check "  not the app container"      no_call "docker stop app-locked-svc"
  : > "$CALLS_LOG"
  run_handle_fixture "stop compose-app"
  check "compose app not controllable" calls_have "unknown service 'compose-app'"
  run_handle_fixture "stop script-app"
  check "script app not controllable"  calls_have "unknown service 'script-app'"
  : > "$CALLS_LOG"
  run_handle_fixture "stop nomethod-app"
  check "no method means dockerfile"   calls_have "docker stop app-nomethod-app"
  teardown
}

test_apps_dir_live_reload() {
  echo "• apps dir: a new definition is controllable without a restart"
  setup
  apps_repo
  run_py_fixture '
import os
cl.handle("stop n8n")
with open(os.environ["CALLS_LOG"], "a") as fh:
    fh.write("--- app added ---\n")
with open(os.path.join(os.environ["CONTROL_APPS_DIR"], "wiki-app.json"), "w") as fh:
    fh.write("{\"key\": \"wiki-app\", \"name\": \"wiki\"}")
cl.handle("stop wiki-app")'
  check "picks up the new def"        calls_in_order "--- app added ---" \
                                        "docker stop app-wiki-app"
  check "  and reports ok"            calls_have "wiki-app: stop ok"
  teardown
}

test_shipped_adguard_guard() {
  echo "• allowlist: the shipped registry guards adguard's stop with teardown.sh --check-dns"
  check "registry carries the guard" python3 -c '
import json, os, sys
doc = json.load(open(sys.argv[1]))
svc = {s["key"]: s for s in doc["services"]}["adguard"]
g = svc["control"]["stop_guard"]
repo = os.path.dirname(os.path.dirname(os.path.dirname(sys.argv[1])))
sys.exit(0 if g == ["services/adguard/teardown.sh", "--check-dns"]
         and os.path.isfile(os.path.join(repo, g[0])) else 1)' "$REGISTRY"
}

# ------------------------------------------------------------ teardown
test_teardown_default() {
  echo "• teardown: stops + disables the listener, keeps .env and state"
  setup
  run_deploy
  check "deploy ok"                [ "$CODE" -eq 0 ]
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"               [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "unit stopped"           calls_in_order "systemctl --user stop ntfy-control" \
                                                  "systemctl --user disable ntfy-control"
    check "unit file kept"         [ -f "$HOME/.config/systemd/user/ntfy-control.service" ]
    check "no daemon-reload"       no_call "daemon-reload"
  else
    check "agent booted out"       calls_have "launchctl bootout"
    check "plist deleted"          [ ! -f "$HOME/Library/LaunchAgents/com.ntfy-control.listener.plist" ]
  fi
  check ".env kept"                [ -f "$SVC/.env" ]
  check "state dir kept"           [ -d "$HOME/services/ntfy-control" ]
  check "offers re-deploy"         out_has "brings it back"
  check "offers purge"             out_has "teardown.sh --purge"
  teardown
}

test_teardown_idempotent() {
  echo "• teardown: a second run on a removed service changes nothing"
  setup
  run_deploy
  run_teardown
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"               [ "$CODE" -eq 0 ]
  # The unit file survives a plain remove, so the second run stops +
  # disables again — a no-op on an already-inactive unit, not a repair.
  check ".env kept"                [ -f "$SVC/.env" ]
  check "state dir kept"           [ -d "$HOME/services/ntfy-control" ]
  if [ "$OS" = "Linux" ]; then
    check "unit file still kept"   [ -f "$HOME/.config/systemd/user/ntfy-control.service" ]
  else
    check "plist stays gone"       [ ! -f "$HOME/Library/LaunchAgents/com.ntfy-control.listener.plist" ]
  fi
  teardown
}

test_teardown_no_env() {
  echo "• teardown: refuses when .env is missing rather than guessing paths"
  setup
  run_teardown
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "explains"                 out_has "nothing here was deployed\|no paths to trust"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: deletes state, .env, and the unit file"
  setup
  run_deploy
  run_teardown "ntfy-control" --purge
  check "exits zero"               [ "$CODE" -eq 0 ]
  check ".env gone"                [ ! -f "$SVC/.env" ]
  check "state dir gone"           [ ! -d "$HOME/services/ntfy-control" ]
  if [ "$OS" = "Linux" ]; then
    check "unit file gone"         [ ! -f "$HOME/.config/systemd/user/ntfy-control.service" ]
    check "daemon reloaded"        calls_have "systemctl --user daemon-reload"
  fi
  teardown
}

test_teardown_purge_wrong_name() {
  echo "• teardown --purge: a wrong confirmation changes nothing"
  setup
  run_deploy
  run_teardown "wrong" --purge
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "confirmation refused"     out_has "did not match"
  check ".env kept"                [ -f "$SVC/.env" ]
  check "state dir kept"           [ -d "$HOME/services/ntfy-control" ]
  check "no stop attempted"        no_call "systemctl --user stop\|launchctl bootout"
  teardown
}

test_teardown_purge_bad_state_dir() {
  echo "• teardown --purge: odd SERVICE_HOME values are refused"
  setup
  run_deploy
  # A symlinked leaf: never rm -rf through a symlink.
  mv "$HOME/services/ntfy-control" "$HOME/services/ntfy-control-real"
  ln -s "$HOME/services/ntfy-control-real" "$HOME/services/ntfy-control"
  run_teardown "ntfy-control" --purge
  check "symlink refused"          [ "$CODE" -ne 0 ]
  check "target survives"          [ -d "$HOME/services/ntfy-control-real" ]
  check ".env kept on refusal"     [ -f "$SVC/.env" ]
  teardown

  setup
  run_deploy
  # A path outside ~/services/<name>: outside the only tree teardown owns.
  mkdir -p "$HOME/other-state"
  sed -i "s|SERVICE_HOME=.*|SERVICE_HOME=$HOME/other-state|" "$SVC/.env"
  run_teardown "ntfy-control" --purge
  check "outside path refused"     [ "$CODE" -ne 0 ]
  check "outside dir survives"     [ -d "$HOME/other-state" ]
  check "state dir untouched"      [ -d "$HOME/services/ntfy-control" ]
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_ntfy_down
test_preflight_docker_perms
test_fresh_install
test_fresh_install_with_phone
test_idempotent_rerun
test_auth_required
test_auth_required_no_creds
test_auth_rejected
test_env_migration_adds_creds
test_plist_escapes_env_values
test_handle_sends_credentials
test_handle_anonymous
test_handle_stop
test_handle_start
test_handle_immich
test_handle_immich_without_ml
test_handle_immich_required_failure_stops_there
test_handle_beszel
test_handle_manimkc
test_shared_allowlist
test_missing_registry_controls_nothing
test_handle_panel
test_handle_pick
test_handle_pick_empty
test_handle_status
test_handle_rejects_unknown
test_handle_stop_guard
test_handle_stop_guard_resolved_at_stop_time
test_handle_stop_guard_timeout
test_handle_launcher_apps
test_apps_dir_live_reload
test_shipped_adguard_guard
test_teardown_default
test_teardown_idempotent
test_teardown_no_env
test_teardown_purge
test_teardown_purge_wrong_name
test_teardown_purge_bad_state_dir

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
