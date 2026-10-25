#!/usr/bin/env bash
#
# Tests for services/deployd/{setup.sh,teardown.sh,deployd}.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment on this machine
#
# The mocked suite runs the real scripts from a sandbox copy of this
# directory (so the generated .env never lands in the repo), with a fake
# $HOME, PATH stubs for git/systemctl/loginctl/launchctl/id/sudo/uname/sleep,
# and a fixture "setup-server checkout" holding toy services whose deploy
# commands just log to $CALLS_LOG. The poller runs under the real python3 —
# its only dependency. Nothing touches the real system.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

SHA_A1="aaaa111111111111111111111111111111111111"
SHA_A2="aaaa222222222222222222222222222222222222"
SHA_B1="bbbb111111111111111111111111111111111111"

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  REPO="$SANDBOX/repo"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/deployd" "$SVC/"
  BIN_DIR="$HOME/services/deployd/bin"
  DSTATE="$HOME/services/deployd/state"
  TIMER="$HOME/.config/systemd/user/deployd.timer"
  SUNIT="$HOME/.config/systemd/user/deployd.service"
  PLIST="$HOME/Library/LaunchAgents/com.setup-server.deployd.plist"
  ENVF="$SVC/.env"

  # Fixture checkout: two deployable services plus the anti-cases the
  # scanner must skip (disabled block, incomplete block, broken JSON, no
  # deploy block at all) and a stand-in services/deployd/ for self-update.
  mkdir -p "$REPO/services/svc-a" "$REPO/services/svc-b" \
           "$REPO/services/svc-off" "$REPO/services/svc-badcfg" \
           "$REPO/services/svc-broken" "$REPO/services/svc-plain" \
           "$REPO/services/deployd"
  for s in a b; do
    cat > "$REPO/services/svc-$s/app.json" <<EOF
{"key":"svc-$s","deploy":{"repo":"https://$s.invalid/repo.git","ref":"main","cmd":"services/svc-$s/deploy.sh"}}
EOF
    cat > "$REPO/services/svc-$s/deploy.sh" <<EOF
#!/usr/bin/env bash
echo "DEPLOY svc-$s sha=\$DEPLOY_SHA ref=\$DEPLOY_REF" >> "$CALLS_LOG"
[ -f "$STATE_DIR/fail_svc_$s" ] && { echo "svc-$s exploded" >&2; exit 3; }
exit 0
EOF
    chmod +x "$REPO/services/svc-$s/deploy.sh"
  done
  printf '%s\t%s\n' "$SHA_A1" "refs/heads/main" \
    > "$STATE_DIR/remote_https___a_invalid_repo_git"
  printf '%s\t%s\n' "$SHA_B1" "refs/heads/main" \
    > "$STATE_DIR/remote_https___b_invalid_repo_git"
  echo '{"key":"svc-off","deploy":{"enabled":false,"repo":"https://off.invalid/r.git","cmd":"true"}}' \
    > "$REPO/services/svc-off/app.json"
  echo '{"key":"svc-badcfg","deploy":{"repo":"https://bad.invalid/r.git"}}' \
    > "$REPO/services/svc-badcfg/app.json"
  echo '{ "key": broken json' > "$REPO/services/svc-broken/app.json"
  echo '{"key":"svc-plain"}' > "$REPO/services/svc-plain/app.json"
  cat > "$REPO/services/deployd/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "deployd-self-update" >> "$CALLS_LOG"
EOF
  echo "aaa1111111111111111111111111111111111111" > "$STATE_DIR/head"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_UNAME SETUP_REPO POLL_SECONDS STATE_DIR CALLS_LOG
}

# run_setup [stdin] — setup.sh under stubs; sets OUT and CODE
run_setup() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" SETUP_REPO="$REPO" \
         bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# run_poll [args] — the installed-less path: repo copy of the poller with a
# fixture .env; sets OUT and CODE
run_poll() {
  cat > "$SANDBOX/poll.env" <<EOF
SETUP_REPO=$REPO
SERVICE_HOME=$HOME/services/deployd
RETRY_SECONDS=900
DEPLOY_TIMEOUT=60
EOF
  OUT="$(DEPLOYD_ENV="$SANDBOX/poll.env" PATH="$STUBS:$PATH" \
         python3 "$SVC/deployd" "$@" 2>&1)"
  CODE=$?
}

run_teardown() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" "${2:-}" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); green "    ✓ $desc"
  else FAIL=$((FAIL + 1)); red "    ✗ $desc"; fi
}

out_has()    { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -qF -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -qF -- "$1" "$CALLS_LOG"; }
env_has()    { grep -qxF -- "$1" "$ENVF"; }
deploy_count() { grep -cF "DEPLOY $1" "$CALLS_LOG" 2>/dev/null || true; }
sha_is()     { [ "$(cat "$DSTATE/$1.sha" 2>/dev/null)" = "$2" ]; }

# ----------------------------------------------------------------- tests
test_preflight_refuses_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_setup
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "mentions regular user" out_has "regular user"
  teardown
}

test_preflight_bad_repo() {
  echo "• preflight refuses a SETUP_REPO that is not a checkout"
  setup
  REPO="$SANDBOX/not-a-repo"   # no services/ inside
  mkdir -p "$REPO"
  run_setup
  check "exits non-zero"   [ "$CODE" -ne 0 ]
  check "explains"         out_has "not a setup-server checkout"
  check "no .env written"  [ ! -e "$SVC/.env" ]
  teardown
}

test_fresh_setup_linux() {
  echo "• fresh setup on Linux: env, bin, units, lingering, first tick"
  setup
  [ "$OS" = "Linux" ] || { echo "    (skipped — not Linux)"; teardown; return; }
  run_setup
  check "succeeds"                 [ "$CODE" -eq 0 ]
  check "wrote .env"               env_has "POLL_SECONDS=60"
  check ".env points at checkout"  env_has "SETUP_REPO=$REPO"
  check "poller installed"         [ -x "$BIN_DIR/deployd" ]
  check "env path baked"           grep -qF "ENV_BAKED = \"$ENVF\"" "$BIN_DIR/deployd"
  check "timer written"            [ -f "$TIMER" ]
  check "timer cadence"            grep -qF "OnUnitActiveSec=60" "$TIMER"
  check "service oneshot"          grep -qF "Type=oneshot" "$SUNIT"
  check "timer enabled"            calls_have "enable --now deployd.timer"
  check "lingering enabled"        calls_have "enable-linger"
  check "first tick ran"           calls_have "ls-remote"
  check "first-sight deploy a"     [ "$(deploy_count svc-a)" -eq 1 ]
  check "first-sight deploy b"     [ "$(deploy_count svc-b)" -eq 1 ]
  check "sha recorded"             sha_is svc-a "$SHA_A1"
  check "disabled entry skipped"   no_call "svc-off"
  check "badcfg warned"            out_has 'deploy needs both "repo" and "cmd"'
  teardown
}

test_setup_idempotent() {
  echo "• re-run keeps a hand-edited .env and reinstalls the poller"
  setup
  run_setup
  printf '# my-custom-marker\n' >> "$ENVF"
  rm -f "$BIN_DIR/deployd"
  run_setup
  check "succeeds"             [ "$CODE" -eq 0 ]
  check "env left untouched"   env_has "# my-custom-marker"
  check "poller reinstalled"   [ -x "$BIN_DIR/deployd" ]
  teardown
}

test_setup_poll_override() {
  echo "• POLL_SECONDS override lands in .env and the timer"
  setup
  OUT="$(PATH="$STUBS:$PATH" SETUP_REPO="$REPO" POLL_SECONDS=120 bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
  check "succeeds"           [ "$CODE" -eq 0 ]
  check ".env cadence"       env_has "POLL_SECONDS=120"
  if [ "$OS" = "Linux" ]; then
    check "timer cadence"    grep -qF "OnUnitActiveSec=120" "$TIMER"
  else
    check "plist cadence"    grep -qF "<key>StartInterval</key><integer>120</integer>" "$PLIST"
  fi
  teardown
}

test_setup_macos() {
  echo "• setup on macOS installs the LaunchAgent instead"
  setup
  export FAKE_UNAME=Darwin
  run_setup
  check "succeeds"           [ "$CODE" -eq 0 ]
  check "plist written"      [ -f "$PLIST" ]
  check "plist interval"     grep -qF "<key>StartInterval</key><integer>60</integer>" "$PLIST"
  check "agent bootstrapped" calls_have "bootstrap"
  check "no systemd touch"   no_call "systemctl"
  teardown
}

test_poll_deploys_on_change_only() {
  echo "• poll: deploys first-sight, then only on a moved ref"
  setup
  run_poll
  check "clean tick"              [ "$CODE" -eq 0 ]
  check "svc-a deployed"          [ "$(deploy_count svc-a)" -eq 1 ]
  check "svc-b deployed"          [ "$(deploy_count svc-b)" -eq 1 ]
  check "env passed to cmd"       calls_have "DEPLOY svc-a sha=$SHA_A1 ref=main"
  : > "$CALLS_LOG"
  run_poll
  check "second tick clean"       [ "$CODE" -eq 0 ]
  check "nothing redeployed"      no_call "DEPLOY svc-"
  printf '%s\t%s\n' "$SHA_A2" "refs/heads/main" \
    > "$STATE_DIR/remote_https___a_invalid_repo_git"
  run_poll
  check "the mover deploys"       [ "$(deploy_count svc-a)" -eq 1 ]
  check "the quiet one does not"  [ "$(deploy_count svc-b)" -eq 0 ]
  check "new sha recorded"        sha_is svc-a "$SHA_A2"
  teardown
}

test_poll_failure_backoff() {
  echo "• poll: a failed deploy backs off the same sha, isolates the other"
  setup
  run_poll   # seed baselines
  : > "$CALLS_LOG"
  touch "$STATE_DIR/fail_svc_b"
  printf '%s\t%s\n' "bbbb9999999999999999999999999999999999999" "refs/heads/main" \
    > "$STATE_DIR/remote_https___b_invalid_repo_git"
  run_poll
  check "tick reports failure"    [ "$CODE" -eq 1 ]
  check "warns"                   out_has "deploy failed"
  check "fail state written"      [ -f "$DSTATE/svc-b.fail" ]
  : > "$CALLS_LOG"
  run_poll
  check "same sha not retried"    no_call "DEPLOY svc-b"
  check "backoff explained"       out_has "retrying in"
  check "tick still exits 0"      [ "$CODE" -eq 0 ]
  rm -f "$DSTATE/svc-b.fail"   # operator cleared it / backoff elapsed
  run_poll
  check "retry fires"             calls_have "DEPLOY svc-b"
  teardown
}

test_poll_remote_down() {
  echo "• poll: an unreachable remote keeps last-known state"
  setup
  run_poll
  check "baseline recorded"       sha_is svc-a "$SHA_A1"
  touch "$STATE_DIR/git_fails"
  run_poll
  check "tick fails"              [ "$CODE" -eq 1 ]
  check "warns about ls-remote"   out_has "ls-remote"
  check "state preserved"         sha_is svc-a "$SHA_A1"
  teardown
}

test_poll_checkout_pull_and_self_update() {
  echo "• poll: checkout pull refreshes config; services/deployd/ change re-runs setup.sh"
  setup
  run_poll
  : > "$CALLS_LOG"
  echo "ccc9999999999999999999999999999999999999" > "$STATE_DIR/head_next"
  echo "services/deployd/deployd" > "$STATE_DIR/pull_diff"
  run_poll
  check "checkout pulled"         calls_have "pull"
  check "self-update ran"         calls_have "deployd-self-update"
  check "tick clean"              [ "$CODE" -eq 0 ]
  teardown
}

test_poll_pull_failure_keeps_going() {
  echo "• poll: a failed checkout pull still polls remotes on stale config"
  setup
  touch "$STATE_DIR/pull_fails"
  run_poll
  check "warns about pull"        out_has "pull did not apply"
  check "still deploys"           [ "$(deploy_count svc-a)" -eq 1 ]
  check "tick clean"              [ "$CODE" -eq 0 ]
  teardown
}

test_poll_lock() {
  echo "• poll: a held lock skips the tick cleanly"
  setup
  mkdir -p "$HOME/services/deployd/.poll.lock"
  run_poll
  check "exits 0"          [ "$CODE" -eq 0 ]
  check "says why"         out_has "another poll is running"
  check "nothing ran"      no_call "ls-remote"
  teardown
}

test_poll_force_and_status() {
  echo "• poll: --force redeploys an unchanged sha, --status lists entries"
  setup
  run_poll
  : > "$CALLS_LOG"
  run_poll --force svc-a
  check "force exits 0"     [ "$CODE" -eq 0 ]
  check "force deployed"    calls_have "DEPLOY svc-a"
  run_poll --status
  check "status exits 0"    [ "$CODE" -eq 0 ]
  check "lists svc-a"       out_has "svc-a"
  check "shows its sha"     out_has "${SHA_A1:0:12}"
  teardown
}

test_teardown() {
  echo "• teardown stops the poller and keeps state + unit files"
  setup
  run_setup
  run_teardown
  check "succeeds"             [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "timer disabled"     calls_have "disable --now deployd.timer"
    check "unit file kept"     [ -f "$TIMER" ]
  else
    check "agent unloaded"     calls_have "bootout"
    check "agent disabled"     calls_have "disable"
    check "plist kept"         [ -f "$PLIST" ]
  fi
  check "state kept"           [ -d "$DSTATE" ]
  check ".env kept"            [ -f "$ENVF" ]
  teardown
}

test_teardown_lock_refusal() {
  echo "• teardown refuses while a poll holds the lock"
  setup
  run_setup
  mkdir -p "$HOME/services/deployd/.poll.lock"
  run_teardown
  check "fails"            [ "$CODE" -ne 0 ]
  check "says mid-run"     out_has "mid-run"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge removes state, units and .env after confirm"
  setup
  run_setup
  run_teardown "" --purge
  check "aborts without the name"  [ "$CODE" -ne 0 ]
  check "nothing deleted yet"      [ -d "$HOME/services/deployd" ]
  OUT="$(printf 'deployd\n' | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"
  CODE=$?
  check "purge succeeds"        [ "$CODE" -eq 0 ]
  check "service home gone"     [ ! -d "$HOME/services/deployd" ]
  check "unit files gone"       [ ! -f "$TIMER" ]
  check "plist gone"            [ ! -f "$PLIST" ]
  check ".env gone"             [ ! -f "$ENVF" ]
  teardown
}

# ------------------------------------------------------------------- run
cd "$TESTS_DIR" || exit 1
for t in \
  test_preflight_refuses_root \
  test_preflight_bad_repo \
  test_fresh_setup_linux \
  test_setup_idempotent \
  test_setup_poll_override \
  test_setup_macos \
  test_poll_deploys_on_change_only \
  test_poll_failure_backoff \
  test_poll_remote_down \
  test_poll_checkout_pull_and_self_update \
  test_poll_pull_failure_keeps_going \
  test_poll_lock \
  test_poll_force_and_status \
  test_teardown \
  test_teardown_lock_refusal \
  test_teardown_purge; do
  "$t"
done

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL check(s) failed ($PASS passed)."
fi

# ------------------------------------------------------------------- live
if [ "${1:-}" = "--live" ]; then
  echo
  echo "• live: verify deployd on this machine"
  LFAIL=0
  if [ "$OS" = "Linux" ]; then
    systemctl --user list-timers deployd.timer 2>/dev/null | grep -q deployd \
      && green "    ✓ deployd.timer is active" \
      || { red "    ✗ deployd.timer not active"; LFAIL=1; }
    "$HOME/services/deployd/bin/deployd" --status >/dev/null 2>&1 \
      && green "    ✓ deployd --status runs" \
      || { red "    ✗ deployd --status failed"; LFAIL=1; }
  else
    launchctl print "gui/$(id -u)/com.setup-server.deployd" >/dev/null 2>&1 \
      && green "    ✓ LaunchAgent loaded" \
      || { red "    ✗ LaunchAgent not loaded"; LFAIL=1; }
  fi
  [ "$LFAIL" -eq 0 ] || FAIL=$((FAIL + LFAIL))
fi

[ "$FAIL" -eq 0 ]
