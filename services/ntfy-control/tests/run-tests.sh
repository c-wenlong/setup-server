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
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/control_listener.py" "$SERVICE_DIR/kuma_toggle.py" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID NTFY_PORT CONTROL_TOPIC REPLY_TOPIC STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the listener's one-shot handler as the subscribe loop would.
run_handle() {
  OUT="$(NTFY_BASE_URL=http://127.0.0.1:3003 CONTROL_TOPIC=control REPLY_TOPIC=alerts \
    PUBLIC_NTFY_URL=https://test-host.tailfake.ts.net:3003 \
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
locked = ("ntfy", "launcher", "ollama")
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
  check "publishes panel to phone"  calls_have '\-d panel http://127.0.0.1:3003/control'
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
  check "never invoked sudo"     no_call "^sudo "
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
  check "agent stopped before hub"   calls_in_order "systemctl --user stop beszel-agent.service" \
                                       "docker stop beszel"
  : > "$CALLS_LOG"
  run_handle "start beszel"
  check "hub started before agent"   calls_in_order "docker start beszel" \
                                       "systemctl --user start beszel-agent.service"
  teardown
}

test_handle_manimkc() {
  echo "• handler: manimkc is a systemd user unit"
  setup
  run_handle "restart manimkc"
  check "stops then starts the unit" calls_in_order "systemctl --user stop manimkc.service" \
                                       "systemctl --user start manimkc.service"
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
  check "no service touched"          no_call "docker stop\|docker start\|systemctl --user stop"
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
HARD_LOCKED = {"launcher", "ntfy", "ollama"}
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
  # The other two deliberate lock-outs, refused by the same allowlist:
  # ollama is a *system* unit (sudo), and the launcher serves the web UI you
  # would have to use to start it again.
  : > "$CALLS_LOG"
  run_handle "stop ollama"
  check "ollama not stoppable"    calls_have "unknown service 'ollama'"
  check "no systemctl stop"       no_call "systemctl --user stop"
  : > "$CALLS_LOG"
  run_handle "restart launcher"
  check "launcher not stoppable"  calls_have "unknown service 'launcher'"
  check "nothing executed"        no_call "systemctl --user stop\|systemctl --user restart"
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
  local port topic
  port="$(sed -n 's|^NTFY_BASE_URL=http://127.0.0.1:\([0-9]*\)$|\1|p' "$SERVICE_DIR/.env")"
  topic="$(sed -n 's/^CONTROL_TOPIC=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "ntfy healthy"          curl -fsS "http://127.0.0.1:$port/v1/health"
  if [ "$OS" = "Linux" ]; then
    live_check "listener active"     sh -c "systemctl --user is-active ntfy-control | grep -qx active"
    live_check "lingering enabled"   sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded" sh -c "launchctl print gui/$(id -u)/com.ntfy-control.listener"
  fi
  # end-to-end: publish `status`, expect the listener to reply on the alerts topic
  curl -fsS -o /dev/null -d "status" "http://127.0.0.1:$port/$topic" && sleep 3
  live_check "status round-trip"     sh -c "curl -fsS 'http://127.0.0.1:$port/alerts/json?poll=1&since=30s' | grep -q 'server-control'"
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

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_ntfy_down
test_preflight_docker_perms
test_fresh_install
test_fresh_install_with_phone
test_idempotent_rerun
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
test_shipped_adguard_guard

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
