#!/usr/bin/env bash
#
# Tests for syncthing/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real setup.sh runs from a sandbox
# copy with a temp $HOME and PATH stubs for tailscale/sudo/systemctl/loginctl/
# launchctl/curl/ss/lsof/id/python3. Two things are specific to this suite.
#
# 1. THE DOWNLOAD IS REAL. The curl stub does not hand back a canned "binary":
#    it builds an actual .tar.gz around tests/stubs/syncthing.tmpl and a real
#    sha256 list for it, so tar, sha256sum, extract and install run unfaked
#    and the fake binary genuinely ends up at $HOME/.local/bin/syncthing in the
#    sandbox, reporting whichever version .env asked for. Checksum mismatch,
#    unlisted asset and 404 are each a separate test.
#
# 2. THE CONFIG PATCH IS REAL. python3 is a pass-through stub, so the XML
#    edit that turns Syncthing's wildcard/relay/discovery defaults into a
#    tailnet-only listener is asserted on the file it actually wrote, and the
#    curl stub's REST answers are derived from that same file. That is what
#    makes the drift test honest: edit config.xml, and the "running instance"
#    reports the edit.
#
# The property this service's suite exists to protect: :22000 on the tailnet
# address ONLY, with relays, global discovery and LAN multicast off. Every
# one of those defaults to ON upstream, and each one is a way for this box to
# be reachable from, or to talk to, somewhere other than the tailnet.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"
export STUBS

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
  cp "$SERVICE_DIR/setup.sh" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT SYNC_PORT STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); green "    ✓ $desc"
  else FAIL=$((FAIL + 1)); red "    ✗ $desc"; fi
}

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }
cfg_path()   { echo "$(env_val SYNCTHING_CONFIG)/config.xml"; }
cfg_has()    { grep -q -- "$1" "$(cfg_path)"; }
cfg_lacks()  { ! grep -q -- "$1" "$(cfg_path)"; }
file_mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
bin_version() { CALLS_LOG=/dev/null "$HOME/.local/bin/syncthing" --version 2>/dev/null | awk '{print $2}'; }

# The mocked suite runs whichever platform it is on; the service-manager
# assertions differ accordingly.
if [ "$OS" = "Linux" ]; then
  ASSET_HINT="syncthing-linux-"
else
  ASSET_HINT="syncthing-macos-"
fi

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "regular user"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "downloaded nothing"   no_call "releases/download"
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

test_preflight_no_tailnet_ip() {
  echo "• preflight fails when the node has no tailnet IPv4 (nothing to bind)"
  setup
  touch "$STATE_DIR/no_ts_ip"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the missing IP"     out_has "tailnet IPv4"
  check "wrote no .env"            [ ! -f "$SVC/.env" ]
  check "started nothing"          no_call "systemctl --user restart"
  teardown
}

test_preflight_bad_port() {
  echo "• preflight rejects non-numeric ports (all three)"
  setup
  export SYNC_PORT=22ooo
  run_deploy
  check "SYNC_PORT: exits non-zero"  [ "$CODE" -ne 0 ]
  check "SYNC_PORT: says numeric"    out_has "SYNC_PORT must be numeric"
  unset SYNC_PORT
  export HTTPS_PORT=abc
  run_deploy
  check "HTTPS_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "HTTPS_PORT: says numeric"   out_has "HTTPS_PORT must be numeric"
  unset HTTPS_PORT
  export LOCAL_PORT=83x4
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_no_python3() {
  echo "• preflight fails without python3 (it patches config.xml before first start)"
  # Not a nicety: without the patch, the FIRST start would go live on
  # 0.0.0.0:22000 and register with the public relay pool. Refusing to start
  # is the only safe answer.
  setup
  touch "$STATE_DIR/python3_missing"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names python3"             out_has "python3"
  check "  and why it needs it"     out_has "config.xml before first start"
  check "wrote no .env"             [ ! -f "$SVC/.env" ]
  check "generated no config"       no_call "^syncthing generate"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: pinned download verified, config patched BEFORE first start, tailnet-only"
  setup
  run_deploy
  check "exits zero"                        [ "$CODE" -eq 0 ]

  # --- .env
  check ".env generated"                    [ -f "$SVC/.env" ]
  check ".env is mode 600"                  [ "$(file_mode "$SVC/.env")" = "600" ]
  check "pinned to v2.1.5"                  grep -qx 'SYNCTHING_VERSION=v2.1.5' "$SVC/.env"
  check ".env records the GUI port"         grep -qx 'LOCAL_PORT=8384' "$SVC/.env"
  check ".env records the sync port"        grep -qx 'SYNC_PORT=22000' "$SVC/.env"
  check ".env records the tailnet IP"       grep -qx 'SYNCTHING_LISTEN_IP=100.100.100.100' "$SVC/.env"
  check ".env has config/db/data paths"     sh -c "grep -qE '^SYNCTHING_CONFIG=/.+' '$SVC/.env' && grep -qE '^SYNCTHING_DB=/.+' '$SVC/.env' && grep -qE '^SYNCTHING_DATA=/.+' '$SVC/.env'"

  # --- download + verify + install (real tar, real sha256)
  check "downloaded the pinned asset"       calls_have "releases/download/v2.1.5/${ASSET_HINT}"
  check "  and the checksum list"           calls_have "releases/download/v2.1.5/sha256sum.txt.asc"
  check "  verified the sha256"             out_has "sha256 verified"
  check "binary installed in ~/.local/bin"  [ -x "$HOME/.local/bin/syncthing" ]
  check "  reporting v2.1.5"                [ "$(bin_version)" = "v2.1.5" ]
  check "generated identity + config"       calls_have "^syncthing generate --config="
  check "  with --no-port-probing"          calls_have "generate .*--no-port-probing"
  check "never ran serve by hand"           [ ! -f "$STATE_DIR/serve_invoked_directly" ]

  # --- config.xml: the house rules, on the file that was actually written
  check "config.xml exists"                 [ -f "$(cfg_path)" ]
  check "  mode 600"                        [ "$(file_mode "$(cfg_path)")" = "600" ]
  check "  config dir mode 700"             [ "$(file_mode "$(env_val SYNCTHING_CONFIG)")" = "700" ]
  check "  listens tcp on the tailnet IP"   cfg_has '<listenAddress>tcp://100.100.100.100:22000</listenAddress>'
  check "  listens quic on the tailnet IP"  cfg_has '<listenAddress>quic://100.100.100.100:22000</listenAddress>'
  check "  the 'default' listener is gone"  cfg_lacks '<listenAddress>default</listenAddress>'
  check "  no 0.0.0.0 anywhere"             cfg_lacks '0\.0\.0\.0'
  check "  no relays"                       cfg_has '<relaysEnabled>false</relaysEnabled>'
  check "  no global discovery"             cfg_has '<globalAnnounceEnabled>false</globalAnnounceEnabled>'
  check "  no local multicast discovery"    cfg_has '<localAnnounceEnabled>false</localAnnounceEnabled>'
  check "  no NAT traversal"                cfg_has '<natEnabled>false</natEnabled>'
  check "  no LAN address announcing"       cfg_has '<announceLANAddresses>false</announceLANAddresses>'
  check "  usage reporting declined"        cfg_has '<urAccepted>-1</urAccepted>'
  check "  crash reporting off"             cfg_has '<crashReportingEnabled>false</crashReportingEnabled>'
  check "  self-upgrade off"                cfg_has '<autoUpgradeIntervalH>0</autoUpgradeIntervalH>'
  check "  GUI on 127.0.0.1:8384"           cfg_has '<address>127.0.0.1:8384</address>'
  check "  host check relaxed for Serve"    cfg_has '<insecureSkipHostcheck>true</insecureSkipHostcheck>'
  check "  password nag dismissed"          cfg_lacks 'unackedNotificationID'
  check "  API key survived the patch"      cfg_has '<apikey>STUBAPIKEY'
  check "  device element survived"         cfg_has 'STUBDEV-AAAAAAA'
  check "  identity files written"          sh -c "test -f '$(env_val SYNCTHING_CONFIG)/cert.pem' && test -f '$(env_val SYNCTHING_CONFIG)/key.pem'"

  # --- service
  if [ "$OS" = "Linux" ]; then
    unit="$HOME/.config/systemd/user/syncthing.service"
    check "wrote systemd user unit"         [ -f "$unit" ]
    check "  serve with --config and --data" sh -c "grep -q -- '--config=$(env_val SYNCTHING_CONFIG)' '$unit' && grep -q -- '--data=$(env_val SYNCTHING_DB)' '$unit'"
    check "  --no-upgrade (pinned by .env)" grep -q -- '--no-upgrade' "$unit"
    check "  --no-restart + exit 3/4 handled" sh -c "grep -q -- '--no-restart' '$unit' && grep -q '^RestartForceExitStatus=3 4' '$unit'"
    check "  Restart=always"                grep -q '^Restart=always' "$unit"
    check "  hardened (NoNewPrivileges)"    grep -q '^NoNewPrivileges=true' "$unit"
    check "enabled + restarted service"     calls_have "systemctl --user restart syncthing"
    check "enabled lingering via sudo"      calls_have "sudo loginctl enable-linger"
  else
    check "bootstrapped LaunchAgent"        calls_have "launchctl bootstrap"
    check "  plist has --no-upgrade"        grep -q -- '--no-upgrade' "$HOME/Library/LaunchAgents/net.syncthing.syncthing.plist"
  fi

  # --- verification against the "running" instance
  check "waited on /rest/noauth/health"     calls_have "127.0.0.1:8384/rest/noauth/health"
  check "read the device ID"                calls_have "127.0.0.1:8384/rest/system/status"
  check "  and printed it"                  out_has "Device ID: STUBDEV-AAAAAAA"
  check "checked the running options"       calls_have "127.0.0.1:8384/rest/config/options"
  check "  house rules confirmed"           out_has "matches the house rules"
  check "checked the GUI config"            calls_have "127.0.0.1:8384/rest/config/gui"
  check "  reports no GUI password"         out_has "no GUI password"
  check "created the default folder"        [ -f "$STATE_DIR/folder_post" ]
  check "  at SYNCTHING_DATA/default"       sh -c "grep -q '\"path\": *\"$(env_val SYNCTHING_DATA)/default\"' '$STATE_DIR/folders.json'"
  check "  directory exists"                [ -d "$(env_val SYNCTHING_DATA)/default" ]
  check "  and said so"                     out_has "Folder 'default'"

  # --- publish + end to end
  check "served on tailscale :8384"         calls_have "tailscale serve --bg --https=8384 http://127.0.0.1:8384"
  check "verified over tailnet HTTPS"       calls_have "https://test-host.tailfake.ts.net:8384/rest/noauth/health"
  check "  and the GUI root (host check)"   out_has "GUI answers through Serve"
  check "checked the sync socket"           out_has "bound to 100.100.100.100 only"
  check "prints final URL"                  out_has "https://test-host.tailfake.ts.net:8384"
  check "prints the sync address"           out_has "tcp://test-host.tailfake.ts.net:22000"
  check "explains adding a device"          out_has "Add Remote Device"
  check "  and why not 'dynamic'"           out_has "Global discovery is OFF"
  check "says where the identity lives"     out_has "identity:"
  teardown
}

test_checksum_mismatch() {
  echo "• checksum mismatch: refuses to install, starts nothing"
  setup
  touch "$STATE_DIR/bad_checksum"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says mismatch"             out_has "Checksum mismatch"
  check "no binary installed"       [ ! -e "$HOME/.local/bin/syncthing" ]
  check "no config generated"       no_call "^syncthing generate"
  check "no service started"        sh -c "! grep -qE 'systemctl --user restart|launchctl bootstrap' '$CALLS_LOG'"
  check "nothing published"         no_call "tailscale serve"
  teardown
}

test_asset_unlisted() {
  echo "• asset missing from the checksum list: refuses (unverifiable)"
  setup
  touch "$STATE_DIR/sha_unlisted"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says not listed"           out_has "not listed"
  check "no binary installed"       [ ! -e "$HOME/.local/bin/syncthing" ]
  teardown
}

test_download_fails() {
  echo "• download 404s: dies pointing at SYNCTHING_VERSION"
  setup
  touch "$STATE_DIR/download_fails"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says download failed"      out_has "Download failed"
  check "  and names the .env key"  out_has "SYNCTHING_VERSION"
  check "no binary installed"       [ ! -e "$HOME/.local/bin/syncthing" ]
  teardown
}

test_readiness_retry() {
  echo "• cold start refuses the connection: the health loop retries, not dies"
  setup
  echo 2 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "polled health repeatedly"    [ "$(call_count '127.0.0.1:8384/rest/noauth/health')" -ge 3 ]
  check "did not report a failure"    out_lacks "did not answer"
  check "still verified the options"  calls_have "/rest/config/options"
  teardown
}

test_rerun_idempotent() {
  echo "• re-run: no download, no sudo, config.xml and .env byte-identical, no folder re-added"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  env_before="$(cat "$SVC/.env")"
  cfg_before="$(cat "$(cfg_path)")"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/folder_post"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "says .env left alone"          out_has "leaving untouched: $SVC/.env"
  check "  .env byte-identical"         [ "$(cat "$SVC/.env")" = "$env_before" ]
  check "says config.xml left alone"    out_has "config.xml already exists"
  check "  config.xml byte-identical"   [ "$(cat "$(cfg_path)")" = "$cfg_before" ]
  check "binary already installed"      out_has "already installed"
  check "  no download"                 no_call "releases/download"
  check "  no generate"                 no_call "^syncthing generate"
  check "no folder re-created"          [ ! -f "$STATE_DIR/folder_post" ]
  check "  reports 1 folder"            out_has "1 folder(s) configured"
  check "never invoked sudo"            no_call "^sudo "
  check "house rules re-verified"       out_has "matches the house rules"
  check "service restarted (repair)"    sh -c "grep -qE 'systemctl --user restart syncthing|launchctl bootstrap' '$CALLS_LOG'"
  check "re-applied serve config"       calls_have "tailscale serve --bg --https=8384 http://127.0.0.1:8384"
  teardown
}

test_version_bump() {
  echo "• SYNCTHING_VERSION bumped in .env: downloads + installs the new one, keeps config"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg_before="$(cat "$(cfg_path)")"
  sed 's/^SYNCTHING_VERSION=.*/SYNCTHING_VERSION=v2.1.6/' "$SVC/.env" > "$SVC/.env.new" && cat "$SVC/.env.new" > "$SVC/.env" && rm "$SVC/.env.new"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "downloaded v2.1.6"             calls_have "releases/download/v2.1.6/${ASSET_HINT}"
  check "  verified its checksum"       out_has "sha256 verified"
  check "binary now reports v2.1.6"     [ "$(bin_version)" = "v2.1.6" ]
  check "  says what it replaced"       out_has "was v2.1.5"
  check "config.xml untouched"          [ "$(cat "$(cfg_path)")" = "$cfg_before" ]
  check "service restarted on the new binary" sh -c "grep -qE 'systemctl --user restart syncthing|launchctl bootstrap' '$CALLS_LOG'"
  teardown
}

test_port_override() {
  echo "• port overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8385 HTTPS_PORT=8385 SYNC_PORT=22001
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env records the overrides"    sh -c "grep -qx 'LOCAL_PORT=8385' '$SVC/.env' && grep -qx 'HTTPS_PORT=8385' '$SVC/.env' && grep -qx 'SYNC_PORT=22001' '$SVC/.env'"
  check "config listens on :22001"      cfg_has '<listenAddress>tcp://100.100.100.100:22001</listenAddress>'
  check "  GUI on :8385"                cfg_has '<address>127.0.0.1:8385</address>'
  check "polled :8385"                  calls_have "127.0.0.1:8385/rest/noauth/health"
  check "served :8385 -> :8385"         calls_have "tailscale serve --bg --https=8385 http://127.0.0.1:8385"
  check "prints the :22001 sync address" out_has "tcp://test-host.tailfake.ts.net:22001"

  export LOCAL_PORT=8386 SYNC_PORT=22002
  run_deploy
  check "re-run: exits zero"            [ "$CODE" -eq 0 ]
  check "re-run: says LOCAL_PORT ignored" out_has "LOCAL_PORT=8386 ignored"
  check "re-run: says SYNC_PORT ignored"  out_has "SYNC_PORT=22002 ignored"
  check "re-run: .env unchanged"        grep -qx 'SYNC_PORT=22001' "$SVC/.env"
  check "re-run: still serves :8385"    calls_have "tailscale serve --bg --https=8385 http://127.0.0.1:8385"
  check "re-run: never touched 8386"    no_call "127.0.0.1:8386"
  unset LOCAL_PORT HTTPS_PORT SYNC_PORT
  teardown
}

test_drift_warns_not_reverts() {
  echo "• running config drifted back to wildcard/relays: warned, exit non-zero, NOT rewritten"
  # config.xml is the user's file after the first run. But a listener on
  # 0.0.0.0 with relays on is exactly the exposure this deploy exists to
  # prevent, so silence is not an option either: report it, give the fix,
  # exit non-zero.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed -e 's#<listenAddress>tcp://100.100.100.100:22000</listenAddress>#<listenAddress>default</listenAddress>#' \
      -e 's#<listenAddress>quic://100.100.100.100:22000</listenAddress>##' \
      -e 's#<relaysEnabled>false</relaysEnabled>#<relaysEnabled>true</relaysEnabled>#' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  cfg_before="$(cat "$cfg")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "warns about drift"             out_has "drifted from the house rules"
  check "  names the listener"          out_has "listenAddresses="
  check "  names relays"                out_has "relaysEnabled=true"
  check "  explains the exposure"       out_has "reachable from the LAN"
  check "  gives the GUI fix"           out_has "Sync Protocol Listen Addresses"
  check "  and the API fix"             out_has "PATCH"
  check "config.xml NOT rewritten"      [ "$(cat "$cfg")" = "$cfg_before" ]
  check "did not claim the rules hold"  out_lacks "matches the house rules"
  check "still published"               calls_have "tailscale serve --bg --https=8384"
  check "final line says why non-zero"  out_has "Exiting non-zero"
  teardown
}

test_tailnet_ip_changed() {
  echo "• node's tailnet IP changed since first run: warns, .env left alone"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "100.100.100.200" > "$STATE_DIR/ts_ip"
  run_deploy
  check "warns about the IP"            out_has "SYNCTHING_LISTEN_IP in .env is 100.100.100.100"
  check "  names the new one"           out_has "now 100.100.100.200"
  check "  gives the fix"               out_has "SYNCTHING_LISTEN_IP=100.100.100.200"
  check ".env unchanged"                grep -qx 'SYNCTHING_LISTEN_IP=100.100.100.100' "$SVC/.env"
  teardown
}

test_hostcheck_403() {
  echo "• GUI 403s through Serve (host check in force): reported with the fix, exit non-zero"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/hostcheck_403"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the host check"          out_has "host check"
  check "  gives the config fix"        out_has "insecureSkipHostcheck"
  check "health still passed"           out_has "End-to-end HTTPS check passed"
  check "did not claim GUI works"       out_lacks "GUI answers through Serve"
  teardown
}

test_wildcard_socket() {
  echo "• :22000 seen on 0.0.0.0 in the socket table: flagged, exit non-zero"
  # config.xml can be right while the wire is wrong (stale process, another
  # program on the port). The socket table is the authority.
  setup
  touch "$STATE_DIR/operator"
  printf '100.100.100.100:22000\n0.0.0.0:22000\n' > "$STATE_DIR/listeners"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "flags the foreign address"     out_has "ALSO listening on: 0.0.0.0:22000"
  check "  says it is off the tailnet"  out_has "off the tailnet"
  teardown
}

test_nothing_listening_yet() {
  echo "• :22000 not bound yet (tailscale0 late): a warning, not a failure"
  setup
  touch "$STATE_DIR/operator"
  : > "$STATE_DIR/listeners"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns nothing is listening"    out_has "Nothing is listening on :22000 yet"
  check "  says syncthing retries"      out_has "retries the bind"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8384 http://127.0.0.1:8384"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8384 http://127.0.0.1:8384"
  teardown
}

# ------------------------------------------------------------ live suite
live_check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); green "    ✓ $desc"
  else FAIL=$((FAIL + 1)); red "    ✗ $desc"; fi
}

ts_cli() { command -v tailscale >/dev/null && echo tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale; }

# Listener addresses on a port, tcp and udp, one per line (no port suffix).
listener_hosts() {  # listener_hosts PORT
  local port="$1" addrs
  if command -v ss >/dev/null; then
    addrs="$( { ss -ltnH "sport = :$port"; ss -lunH "sport = :$port"; } 2>/dev/null | awk '{print $4}')"
  else
    addrs="$(lsof -nP -i:"$port" 2>/dev/null | awk 'NR>1{print $9}')"
  fi
  printf '%s\n' "$addrs" | sed 's/ (LISTEN)//' | awk 'NF' | sed 's/:[0-9]*$//' | tr -d '[]' | sort -u
}

# Every listener on $port must be loopback or this node's tailnet address.
# (The GUI is published on the SAME number it binds, so tailscaled itself
# legitimately listens on the tailnet IP:8384 — that is the Serve frontend.)
no_external_listener() {
  local port="$1" host ts4 ts6
  ts4="$("$(ts_cli)" ip -4 2>/dev/null || true)"; ts6="$("$(ts_cli)" ip -6 2>/dev/null || true)"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    case "$host" in
      127.0.0.1|::1|localhost) ;;
      *) [ -n "$ts4" ] && [ "$host" = "$ts4" ] && continue
         [ -n "$ts6" ] && [ "$host" = "$ts6" ] && continue
         return 1 ;;
    esac
  done <<EOF
$(listener_hosts "$port")
EOF
  return 0
}

# The sync port: bound, and bound to the tailnet IPv4 and NOTHING else.
sync_port_tailnet_only() {
  local port="$1" ts4 hosts host
  ts4="$("$(ts_cli)" ip -4 2>/dev/null || true)"
  hosts="$(listener_hosts "$port")"
  [ -n "$hosts" ] || return 1
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    [ "$host" = "$ts4" ] || return 1
  done <<EOF
$hosts
EOF
  return 0
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local port https_port sync_port cfg_dir key url want ver bin_ver
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="$(sed -n 's/^HTTPS_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  sync_port="$(sed -n 's/^SYNC_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  cfg_dir="$(sed -n 's/^SYNCTHING_CONFIG=//p' "$SERVICE_DIR/.env")"
  ver="$(sed -n 's/^SYNCTHING_VERSION=//p' "$SERVICE_DIR/.env")"
  key="$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' "$cfg_dir/config.xml" 2>/dev/null | head -1)"
  url="https://$("$(ts_cli)" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  want="$url:$https_port"

  if [ "$OS" = "Linux" ]; then
    live_check "systemd service is active"        systemctl --user is-active syncthing
    live_check "service is enabled at boot"       systemctl --user is-enabled syncthing
    live_check "lingering is on (boot persist)"   sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "LaunchAgent is loaded"            launchctl print "gui/$(id -u)/net.syncthing.syncthing"
  fi
  bin_ver="$(CALLS_LOG=/dev/null "$HOME/.local/bin/syncthing" --version 2>/dev/null | awk '{print $2}')"
  live_check "binary is the pinned $ver"          [ "$bin_ver" = "$ver" ]
  live_check "config.xml is mode 600"             [ "$(file_mode "$cfg_dir/config.xml")" = "600" ]
  live_check "local health responds OK"           sh -c "curl -fsS --max-time 30 'http://127.0.0.1:$port/rest/noauth/health' | grep -q '\"OK\"'"
  live_check "GUI not on non-local ifaces"        no_external_listener "$port"
  live_check "sync :$sync_port on the tailnet IP ONLY (tcp+udp)" sync_port_tailnet_only "$sync_port"
  live_check "no local-discovery multicast on :21027" sh -c "[ -z \"\$(listener_hosts 21027)\" ]"
  live_check "tailscale serve maps :$https_port"  sh -c "'$(ts_cli)' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS health responds"      sh -c "curl -fsS --max-time 60 '$want/rest/noauth/health' | grep -q '\"OK\"'"
  live_check "GUI root is 200 through Serve (host check)" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 '$want/')\" = 200 ]"

  # The running options, asked of the API rather than read off config.xml.
  live_check "API key works"                      sh -c "curl -fsS --max-time 30 -H 'X-API-Key: $key' 'http://127.0.0.1:$port/rest/system/status' | grep -q myID"
  live_check "running options match the house rules" sh -c "curl -fsS --max-time 30 -H 'X-API-Key: $key' 'http://127.0.0.1:$port/rest/config/options' | python3 -c '
import json, sys
o = json.load(sys.stdin)
ts = sys.argv[1]; p = sys.argv[2]
assert sorted(o[\"listenAddresses\"]) == sorted([\"tcp://%s:%s\" % (ts, p), \"quic://%s:%s\" % (ts, p)]), o[\"listenAddresses\"]
for k in (\"globalAnnounceEnabled\", \"localAnnounceEnabled\", \"relaysEnabled\", \"natEnabled\", \"crashReportingEnabled\"):
    assert o[k] is False, k
assert o[\"urAccepted\"] < 0 and o[\"autoUpgradeIntervalH\"] == 0
' \"\$('$(ts_cli)' ip -4)\" '$sync_port'"
  live_check "GUI host check relaxed, bound to loopback" sh -c "curl -fsS --max-time 30 -H 'X-API-Key: $key' 'http://127.0.0.1:$port/rest/config/gui' | python3 -c '
import json, sys; g = json.load(sys.stdin)
assert g[\"insecureSkipHostcheck\"] is True and g[\"address\"] == \"127.0.0.1:$port\"'"

  printf '    → device ID: %s\n' "$(curl -fsS --max-time 30 -H "X-API-Key: $key" "http://127.0.0.1:$port/rest/system/status" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["myID"])' 2>/dev/null || echo '?')"
  printf '    → folders: %s   connected devices: %s\n' \
    "$(curl -fsS --max-time 30 -H "X-API-Key: $key" "http://127.0.0.1:$port/rest/config/folders" 2>/dev/null | python3 -c 'import json,sys; print(", ".join(f["id"]+" -> "+f["path"] for f in json.load(sys.stdin)) or "none")' 2>/dev/null || echo '?')" \
    "$(curl -fsS --max-time 30 -H "X-API-Key: $key" "http://127.0.0.1:$port/rest/system/connections" 2>/dev/null | python3 -c 'import json,sys; c=json.load(sys.stdin)["connections"]; print(sum(1 for v in c.values() if v.get("connected")), "of", len(c))' 2>/dev/null || echo '?')"
  printf '    → backups: %s holds this device'"'"'s identity and every setting.\n' "$cfg_dir"
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ]; then
  red "syncthing/setup.sh is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_tailscale_down
test_preflight_no_tailnet_ip
test_preflight_bad_port
test_preflight_no_python3
test_fresh_deploy
test_checksum_mismatch
test_asset_unlisted
test_download_fails
test_readiness_retry
test_rerun_idempotent
test_version_bump
test_port_override
test_drift_warns_not_reverts
test_tailnet_ip_changed
test_hostcheck_403
test_wildcard_socket
test_nothing_listening_yet
test_operator_escalation
test_serve_approval_prompt

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
