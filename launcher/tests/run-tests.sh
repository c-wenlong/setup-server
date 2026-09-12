#!/usr/bin/env bash
#
# Tests for launcher/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real setup.sh runs from a sandbox
# copy with PATH stubs for tailscale/curl/sudo/id/systemctl/loginctl/launchctl.
#
# python3 is deliberately NOT stubbed. setup.sh uses it for real work —
# version gate, `python3 -m py_compile server.py`, JSON validation of
# services.json — and faking that would test nothing. Instead the sandbox gets
# a fixture server.py / services.json / web/index.html, so the mocked suite is
# hermetic: it does not depend on (or break with) the real backend, and the
# broken-server.py test can prove the compile gate actually bites.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
HOST="test-host.tailfake.ts.net"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"                 # stands in for <repo>/launcher
  mkdir -p "$HOME" "$STATE_DIR" "$SVC/web"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SVC/"

  # --- fixture backend (see the header note about not stubbing python3) ---
  cat > "$SVC/server.py" <<'PY'
#!/usr/bin/env python3
"""Fixture standing in for launcher/server.py in the mocked sandbox."""
import os

PORT = int(os.environ.get("LAUNCHER_PORT", "8093"))
REPO_ROOT = os.environ.get("REPO_ROOT", "")

if __name__ == "__main__":
    print("fixture launcher on 127.0.0.1:%d (repo=%s)" % (PORT, REPO_ROOT))
PY
  cat > "$SVC/services.json" <<'JSON'
[
  {"key": "immich", "name": "Immich", "tagline": "Photos", "icon": "camera",
   "url": "https://HOST:2283/", "health": "http://127.0.0.1:2283/api/server/ping",
   "marker": "~/services/immich", "setup": "immich/setup.sh"},
  {"key": "jellyfin", "name": "Jellyfin", "tagline": "Media", "icon": "film",
   "url": null, "health": null, "marker": null, "setup": null}
]
JSON
  echo '<!doctype html><title>launcher</title>' > "$SVC/web/index.html"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LAUNCHER_PORT HTTPS_PORT SHORT_PATH STATE_DIR CALLS_LOG
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

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -q -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
unit_has()   { grep -q -- "$1" "$HOME/.config/systemd/user/launcher.service"; }
unit_lacks() { ! grep -q -- "$1" "$HOME/.config/systemd/user/launcher.service"; }

# Published mappings, as the (declarative) tailscale stub recorded them:
# one "<https-port> <path> <target>" line per distinct mount point.
serve_lines() { [ ! -f "$STATE_DIR/serve_config" ] || cat "$STATE_DIR/serve_config"; }
serve_count() { [ "$(serve_lines | grep -c .)" = "$1" ]; }
serve_has()   { serve_lines | grep -qx -- "$1"; }
serve_lacks() { ! serve_lines | grep -qx -- "$1"; }

# Linux installs a systemd user unit, macOS a LaunchAgent. Every assertion
# about either is gated on $OS, per the repo's portability rules.
check_service_installed() {
  if [ "$OS" = "Linux" ]; then
    check "unit written"                [ -f "$HOME/.config/systemd/user/launcher.service" ]
    check "  Restart=always"            unit_has "Restart=always"
    check "  runs server.py"            unit_has "ExecStart=/usr/bin/env python3 $SVC/server.py"
    check "  WorkingDirectory is svc"   unit_has "WorkingDirectory=$SVC"
    check "  REPO_ROOT points at repo"  unit_has "Environment=REPO_ROOT=$SANDBOX"
    check "  WantedBy=default.target"   unit_has "WantedBy=default.target"
    check "daemon-reload issued"        calls_have "systemctl --user daemon-reload"
    check "unit enabled"                calls_have "systemctl --user enable launcher.service"
    check "unit RESTARTED (not start)"  calls_have "systemctl --user restart launcher.service"
  else
    check "LaunchAgent written"         [ -f "$HOME/Library/LaunchAgents/com.launcher.server.plist" ]
    check "  KeepAlive set"             grep -q "KeepAlive" "$HOME/Library/LaunchAgents/com.launcher.server.plist"
    check "  runs server.py"            grep -q "$SVC/server.py" "$HOME/Library/LaunchAgents/com.launcher.server.plist"
    check "LaunchAgent (re)bootstrapped" calls_have "launchctl bootstrap"
  fi
}

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Run as a regular user, not root"
  check "installed nothing"    [ ! -f "$HOME/.config/systemd/user/launcher.service" ]
  check "published nothing"    no_call "tailscale serve"
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Tailscale is not up"
  check "installed nothing"    [ ! -f "$HOME/.config/systemd/user/launcher.service" ]
  teardown
}

test_preflight_bad_ports() {
  echo "• preflight rejects non-numeric ports"
  setup
  export LAUNCHER_PORT=eighty-ninety-three
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names LAUNCHER_PORT"      out_has "LAUNCHER_PORT must be numeric"
  unset LAUNCHER_PORT
  export HTTPS_PORT=abc
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names HTTPS_PORT"         out_has "HTTPS_PORT must be numeric"
  check "published nothing"        no_call "tailscale serve"
  teardown
}

test_preflight_bad_short_path() {
  echo "• preflight rejects a SHORT_PATH that is not rooted at /"
  setup
  export SHORT_PATH=home
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "SHORT_PATH must start with"
  teardown
}

test_preflight_missing_server() {
  echo "• preflight fails loudly when server.py is missing"
  setup
  rm -f "$SVC/server.py"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the missing file" out_has "Missing $SVC/server.py"
  check "installed nothing"      [ ! -f "$HOME/.config/systemd/user/launcher.service" ]
  check "published nothing"      no_call "tailscale serve"
  teardown
}

test_preflight_missing_registry() {
  echo "• preflight fails when services.json or web/ is missing"
  setup
  rm -f "$SVC/services.json"
  run_deploy
  check "exits non-zero (no registry)"  [ "$CODE" -ne 0 ]
  check "names services.json"           out_has "Missing $SVC/services.json"
  teardown

  setup
  rm -rf "$SVC/web"
  run_deploy
  check "exits non-zero (no web/)"      [ "$CODE" -ne 0 ]
  check "names web/"                    out_has "Missing $SVC/web/"
  teardown
}

test_preflight_broken_python() {
  echo "• preflight refuses to install a unit that would crash-loop"
  setup
  printf 'def broken(:\n' > "$SVC/server.py"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says it does not compile"  out_has "does not compile"
  check "shows the compiler error"  out_has "py_compile"
  check "installed nothing"         [ ! -f "$HOME/.config/systemd/user/launcher.service" ]
  check "published nothing"         no_call "tailscale serve"
  teardown

  setup
  echo '{ this is not json' > "$SVC/services.json"
  run_deploy
  check "exits non-zero (bad JSON)" [ "$CODE" -ne 0 ]
  check "says registry is bad"      out_has "not valid JSON"
  teardown
}

test_fresh_install() {
  echo "• fresh install: unit + lingering + BOTH serve mappings + verification"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "job log dir created"            [ -d "$HOME/services/launcher/jobs" ]
  check_service_installed
  if [ "$OS" = "Linux" ]; then
    check "lingering enabled via sudo"   calls_have "sudo loginctl enable-linger"
  fi
  check "waited for local healthz"       calls_have "http://127.0.0.1:8093/healthz"
  # The two publishes. Exact argv, because argument order is the contract.
  check "serve: own port :8093"          calls_have "tailscale serve --bg --https=8093 http://127.0.0.1:8093"
  check "serve: /home on :443"           calls_have "tailscale serve --bg --https=443 --set-path=/home http://127.0.0.1:8093"
  check "  both mappings landed"         serve_count 2
  check "  :8093 / -> backend"           serve_has "8093 / http://127.0.0.1:8093"
  check "  :443 /home -> backend"        serve_has "443 /home http://127.0.0.1:8093"
  check "  never touched :443 /"         serve_lacks "443 / http://127.0.0.1:8093"
  check "verified https on :8093"        calls_have "https://$HOST:8093/healthz"
  check "verified https on /home"        calls_have "https://$HOST/home/healthz"
  check "prints the short URL"           out_has "https://$HOST/home/"
  check "prints the port URL too"        out_has "https://$HOST:8093/"
  check "explains Add to Home Screen"    out_has "Add to Home Screen"
  check "says Safari specifically"       out_has "Safari"
  if [ "$OS" = "Linux" ]; then
    check "prints management commands"   out_has "systemctl --user status|restart|stop launcher.service"
    check "prints the log command"       out_has "journalctl --user -u launcher.service -f"
  fi
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: unit regenerated, no duplicate serve config, no sudo"
  setup
  run_deploy                                   # first run escalates as needed
  check "first run exits zero"          [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    echo "# STALE-LINE-FROM-AN-OLD-VERSION" >> "$HOME/.config/systemd/user/launcher.service"
  fi
  : > "$CALLS_LOG"
  run_deploy                                   # second run
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "never invoked sudo"            no_call "^sudo "
  if [ "$OS" = "Linux" ]; then
    check "unit regenerated"            unit_lacks "STALE-LINE-FROM-AN-OLD-VERSION"
    check "still Restart=always"        unit_has "Restart=always"
    check "restarted again"             calls_have "systemctl --user restart launcher.service"
    check "lingering already on"        out_has "Lingering already enabled"
  fi
  check "still publishes both"          serve_count 2
  check "  :8093 / -> backend"          serve_has "8093 / http://127.0.0.1:8093"
  check "  :443 /home -> backend"       serve_has "443 /home http://127.0.0.1:8093"
  check "still prints the short URL"    out_has "https://$HOST/home/"
  teardown
}

test_short_path_disabled() {
  echo "• SHORT_PATH= disables only the :443 handler"
  setup
  touch "$STATE_DIR/operator"
  export SHORT_PATH=""
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "own port still published"      calls_have "tailscale serve --bg --https=8093 http://127.0.0.1:8093"
  check "no path handler published"     no_call "set-path"
  check "exactly one mapping"           serve_count 1
  check "says it skipped it"            out_has "skipping the :443 path handler"
  check "no /home verification"         no_call "https://$HOST/home"
  check "prints the port URL"           out_has "https://$HOST:8093/"
  check "Home Screen hint uses it"      out_has "Open https://$HOST:8093/ in Safari"
  teardown
}

test_option_overrides() {
  echo "• option overrides: custom local port, HTTPS port and short path"
  setup
  touch "$STATE_DIR/operator"
  export LAUNCHER_PORT=9099 HTTPS_PORT=8443 SHORT_PATH=/apps
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "serve: :8443 -> :9099"         calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:9099"
  check "serve: /apps on :443"          calls_have "tailscale serve --bg --https=443 --set-path=/apps http://127.0.0.1:9099"
  check "  both mappings landed"        serve_count 2
  check "  :443 /apps -> backend"       serve_has "443 /apps http://127.0.0.1:9099"
  check "health probed on 9099"         calls_have "http://127.0.0.1:9099/healthz"
  if [ "$OS" = "Linux" ]; then
    check "unit carries the port"       unit_has "Environment=LAUNCHER_PORT=9099"
  fi
  check "prints the short URL"          out_has "https://$HOST/apps/"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo once, then publishes both"
  setup
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "granted operator"            calls_have "sudo tailscale set --operator="
    check "granted it exactly once"     [ "$(grep -c 'sudo tailscale set --operator=' "$CALLS_LOG")" -eq 1 ]
  fi
  check "both mappings still landed"    serve_count 2
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: prints the hint and retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the second
  # lands in the until-loop that prints the approval link and waits on Enter.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "printed the approval hint"     out_has "approve, then press Enter"
  check "published on retry"            calls_have "tailscale serve --bg --https=8093 http://127.0.0.1:8093"
  check "both mappings still landed"    serve_count 2
  teardown
}

test_https_not_ready() {
  echo "• HTTPS not answering yet: warns about the cert, still succeeds"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/https_down"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns about cert minting"      out_has "cert may still be minting"
  check "still prints the short URL"    out_has "https://$HOST/home/"
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
# address — never a wildcard or a LAN interface.
#
# Note this service publishes HTTPS on the same number as the local port
# (8093 -> 8093), so tailscaled legitimately listens on the tailnet IP for
# that port. The other services here differ (e.g. seafile 8443 -> 8081) and never
# hit that overlap, which is why their simpler "anything not 127.0.0.1"
# check works for them and would false-positive here.
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

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port https_port short_path unit host
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  unit="$HOME/.config/systemd/user/launcher.service"
  port="${LAUNCHER_PORT:-8093}"
  if [ -f "$unit" ]; then
    port="$(sed -n 's/^Environment=LAUNCHER_PORT=\([0-9]*\)$/\1/p' "$unit" | head -1)"
    [ -n "$port" ] || port="${LAUNCHER_PORT:-8093}"
  fi
  https_port="${HTTPS_PORT:-8093}"
  short_path="${SHORT_PATH-/home}"
  host="$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  if [ "$OS" = "Linux" ]; then
    live_check "unit active"                sh -c "systemctl --user is-active launcher.service | grep -qx active"
    live_check "unit enabled"               sh -c "systemctl --user is-enabled launcher.service | grep -qx enabled"
    live_check "lingering enabled"          sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "LaunchAgent loaded"         sh -c "launchctl print gui/$(id -u)/com.launcher.server"
  fi

  live_check "local healthz responds"       sh -c "curl -fsS 'http://127.0.0.1:$port/healthz' >/dev/null"
  live_check "api/services responds"        sh -c "curl -fsS 'http://127.0.0.1:$port/api/services' | grep -q '\"services\"'"
  live_check "not listening on non-local ifaces" no_external_listener "$port"

  # Match the node URL header line, not a bare ':8093' — the /home handler's
  # own line also contains the port, which would make this pass vacuously.
  live_check "serve maps :$https_port"      sh -c "'$ts' serve status | grep -A2 '$host:$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  if [ -n "$short_path" ]; then
    live_check "serve maps $short_path on :443" sh -c "'$ts' serve status | grep -- '$short_path' | grep -q 'proxy http://127.0.0.1:$port'"
    # The :443 "/" handler belongs to code-server; publishing the path handler
    # must not have evicted it.
    live_check "code-server still owns :443 /" sh -c "'$ts' serve status | grep -q 'proxy http://127.0.0.1:8080'"
    live_check "short URL responds"         curl -fsS -o /dev/null --max-time 30 "https://$host$short_path/healthz"
  fi
  live_check "port URL responds"            curl -fsS -o /dev/null --max-time 30 "https://$host:$https_port/healthz"

  # The backend ships its own unit tests; run them here so --live is a single
  # "is this service healthy" command rather than two.
  if ls "$SERVICE_DIR"/tests/test_*.py >/dev/null 2>&1; then
    echo "  backend unit tests:"
    live_check "python unit tests pass" \
      sh -c "cd '$SERVICE_DIR' && python3 -m unittest discover -s tests -p 'test_*.py'"
  fi
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_tailscale_down
test_preflight_bad_ports
test_preflight_bad_short_path
test_preflight_missing_server
test_preflight_missing_registry
test_preflight_broken_python
test_fresh_install
test_idempotent_rerun
test_short_path_disabled
test_option_overrides
test_operator_escalation
test_serve_approval_prompt
test_https_not_ready

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
