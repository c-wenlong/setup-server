#!/usr/bin/env bash
#
# Tests for services/syncthing/setup.sh and teardown.sh.
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
# be reachable from, or to talk to, somewhere other than the tailnet. A
# re-run that finds those drifted REPAIRS them over REST (the exposure tests
# below); it never rewrites config.xml wholesale, and preference drift
# (reporting, self-upgrade) is reported and left alone.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"
export STUBS
# The python3 stub is a pass-through to the real interpreter, and it finds it
# on PATH. The minimal-PATH runs below (the "no ss on this box" case) leave
# the stub as the only python3 on PATH, so hand it the real one now, while
# PATH is still the caller's.
REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3

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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SVC/"
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

# A PATH holding nothing but the stubs and the handful of real utilities
# setup.sh shells out to — with named stubs left out. That is how "this box
# has no ss" is made true: with the real /usr/sbin/ss still reachable, the
# lsof branch (the ONLY socket-level check macOS has) would never run, and a
# bug in it would be invisible. Same shape as adguard's suite.
minimal_path() {  # minimal_path <dir> [stub-basename-to-omit ...]
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p s base omit skip
  for c in bash sh env uname mktemp rm cat head cut sed awk grep tr chmod \
           mkdir rmdir df cp mv ln ls stat od readlink dirname basename seq \
           touch sort wc test sleep install find tar gzip unzip zip \
           sha256sum shasum; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$dir/$c"
  done
  for s in "$STUBS"/*; do
    base="$(basename "$s")"
    skip=0
    for omit in "$@"; do [ "$base" = "$omit" ] && skip=1; done
    [ "$skip" = "1" ] || ln -sf "$s" "$dir/$base"
  done
}

run_deploy_path() {  # run_deploy_path <path> [stdin]
  OUT="$(printf '%s' "${2:-}" | PATH="$1" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); green "    ✓ $desc"
  else FAIL=$((FAIL + 1)); red "    ✗ $desc"; fi
}

out_has()    { grep -q -- "$1" <<<"$OUT"; }
# Fixed-string variant, for addresses full of regex metacharacters: the
# wildcard listener renders as `*:8384` and IPv6 rows as `[::]:8384`.
out_hasF()   { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
teardown_lacks() { ! grep -qE -- "$1" "$SERVICE_DIR/teardown.sh"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }
cfg_path()   { echo "$(env_val SYNCTHING_CONFIG)/config.xml"; }
cfg_has()    { grep -q -- "$1" "$(cfg_path)"; }
cfg_lacks()  { ! grep -q -- "$1" "$(cfg_path)"; }
file_mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
bin_version() { CALLS_LOG=/dev/null "$HOME/.local/bin/syncthing" --version 2>/dev/null | awk '{print $2}'; }

# The mocked suite runs whichever platform it is on; the service-manager
# assertions differ accordingly. RESTART_HINT is the recovery command an
# error message is expected to name — systemd here, launchd on a Mac.
# Asserting the Linux string unconditionally would pass on this box while
# the macOS branch printed an instruction nobody can run.
if [ "$OS" = "Linux" ]; then
  ASSET_HINT="syncthing-linux-"
  RESTART_HINT="systemctl --user restart syncthing"
else
  ASSET_HINT="syncthing-macos-"
  RESTART_HINT="launchctl kickstart -k gui/"
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
  check "  house rules confirmed"           out_has "matches the exposure rules"
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
  check "  and the GUI socket"              out_has "GUI port :8384 answers on loopback"
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
  check "house rules re-verified"       out_has "matches the exposure rules"
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

test_exposure_drift_repaired() {
  echo "• running config drifted back to wildcard/relays: repaired over REST, rest of config.xml untouched"
  # A listener on 0.0.0.0 with relays on is exactly the exposure this deploy
  # exists to prevent, and the repo contract is that a re-run REPAIRS. The
  # repair goes through the same REST API the GUI uses, so it is a settings
  # change, not a file overwrite: everything else in config.xml survives.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed -e 's#<listenAddress>tcp://100.100.100.100:22000</listenAddress>#<listenAddress>default</listenAddress>#' \
      -e 's#<listenAddress>quic://100.100.100.100:22000</listenAddress>##' \
      -e 's#<relaysEnabled>false</relaysEnabled>#<relaysEnabled>true</relaysEnabled>#' \
      -e 's#<natEnabled>false</natEnabled>#<natEnabled>false</natEnabled><maxSendKbps>123</maxSendKbps>#' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero (repaired, not just flagged)" [ "$CODE" -eq 0 ]
  check "warned about the drift"        out_has "drifted from the exposure rules"
  check "  named the listener"          out_has "listenAddresses="
  check "  named relays"                out_has "relaysEnabled=true"
  check "PATCHed /rest/config/options"  [ -f "$STATE_DIR/options_patched" ]
  check "  with the tailnet listeners"  sh -c "grep -q 'tcp://100.100.100.100:22000' '$STATE_DIR/options_patch_bodies' && grep -q 'quic://100.100.100.100:22000' '$STATE_DIR/options_patch_bodies'"
  check "  and relays/discovery/NAT off" sh -c "grep -q '\"relaysEnabled\": false' '$STATE_DIR/options_patch_bodies' && grep -q '\"globalAnnounceEnabled\": false' '$STATE_DIR/options_patch_bodies' && grep -q '\"natEnabled\": false' '$STATE_DIR/options_patch_bodies'"
  check "  re-read and confirmed"       out_has "Repaired: listens ONLY on 100.100.100.100:22000"
  check "config.xml now tailnet-only"   cfg_has '<listenAddress>tcp://100.100.100.100:22000</listenAddress>'
  check "  relays off again"            cfg_has '<relaysEnabled>false</relaysEnabled>'
  check "  the user's other setting survived" cfg_has '<maxSendKbps>123</maxSendKbps>'
  check "  API key untouched"           cfg_has '<apikey>STUBAPIKEY'
  check "no GUI patch (GUI was fine)"   [ ! -f "$STATE_DIR/gui_patched" ]
  check "  and no restart"              [ ! -f "$STATE_DIR/restart_posted" ]
  check "still published"               calls_have "tailscale serve --bg --https=8384"
  check "no non-zero exit banner"       out_lacks "Exiting non-zero"
  # And the fresh-deploy path must still refuse rather than repair: a patch
  # that did not take on a brand-new config is a bug, not drift.
  teardown
}

test_preference_drift_only_warns() {
  echo "• reporting / self-upgrade prefs changed by the user: reported, left alone, exit zero"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed -e 's#<urAccepted>-1</urAccepted>#<urAccepted>3</urAccepted>#' \
      -e 's#<crashReportingEnabled>false</crashReportingEnabled>#<crashReportingEnabled>true</crashReportingEnabled>#' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  cfg_before="$(cat "$cfg")"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "reports preference drift"      out_has "Preference drift"
  check "  names urAccepted"            out_has "urAccepted=3"
  check "  names crash reporting"       out_has "crashReportingEnabled=true"
  check "exposure rules still hold"     out_has "matches the exposure rules"
  check "did NOT patch anything"        [ ! -f "$STATE_DIR/options_patched" ]
  check "config.xml byte-identical"     [ "$(cat "$cfg")" = "$cfg_before" ]
  teardown
}

test_gui_drift_repaired() {
  echo "• GUI moved off loopback and host check re-enabled: repaired over REST + restart"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed -e 's#<address>127.0.0.1:8384</address>#<address>0.0.0.0:8384</address>#' \
      -e '/<insecureSkipHostcheck>true<\/insecureSkipHostcheck>/d' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warned about the GUI address"  out_has "GUI is bound to 0.0.0.0:8384"
  check "warned about the host check"   out_has "insecureSkipHostcheck is off"
  check "PATCHed /rest/config/gui"      [ -f "$STATE_DIR/gui_patched" ]
  check "  loopback + host check in the body" sh -c "grep -q '\"address\":\"127.0.0.1:8384\"' '$STATE_DIR/gui_patch_bodies' && grep -q '\"insecureSkipHostcheck\":true' '$STATE_DIR/gui_patch_bodies'"
  check "posted a restart"              [ -f "$STATE_DIR/restart_posted" ]
  check "  waited for health again"     [ "$(call_count '127.0.0.1:8384/rest/noauth/health')" -ge 2 ]
  check "  re-read and confirmed"       out_has "Repaired: GUI on 127.0.0.1:8384"
  check "config.xml back on loopback"   cfg_has '<address>127.0.0.1:8384</address>'
  check "  host check relaxed again"    cfg_has '<insecureSkipHostcheck>true</insecureSkipHostcheck>'
  check "no options patch (they were fine)" [ ! -f "$STATE_DIR/options_patched" ]
  check "  and confirmed it on the wire"  out_has "confirmed on the wire"
  teardown
}

test_gui_repair_restart_refused() {
  echo "• GUI repair: the restart is refused — dies, never claims the GUI is back on loopback"
  # The PATCH only edits the config. Syncthing reads the GUI address when the
  # API service starts, so a restart that did not happen leaves the OLD,
  # unauthenticated listener exactly where it was — on 0.0.0.0, answering the
  # LAN — while every read-back below echoes the config just written.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed 's#<address>127.0.0.1:8384</address>#<address>0.0.0.0:8384</address>#' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  touch "$STATE_DIR/restart_fails"
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the refused restart"     out_has "POST /rest/system/restart returned HTTP 500"
  check "  says the old bind is live"   out_has "still holds the old bind"
  check "  names this OS's restart"     out_hasF "$RESTART_HINT"
  check "never claimed repaired"        out_lacks "Repaired: GUI"
  check "never reached the summary"     out_lacks "This device ID:"
  teardown
}

test_gui_repair_not_on_the_wire() {
  echo "• GUI repair: config says loopback but :8384 is still on 0.0.0.0 — caught, deploy fails"
  # The failure no API call can see. GET /rest/config/gui reads back the PATCH
  # this script just sent, so it agrees with itself, and wait_health passing
  # proves nothing either — a wildcard bind answers on 127.0.0.1 too. Only the
  # socket table knows the unauthenticated GUI is still reachable from the LAN.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed 's#<address>127.0.0.1:8384</address>#<address>0.0.0.0:8384</address>#' "$cfg" > "$cfg.new" \
    && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  # The restart is accepted and the config comes back clean; the process just
  # never rebound. The sync port is where it belongs, so nothing else in the
  # run is complaining.
  printf '100.100.100.100:22000\n0.0.0.0:8384\n' > "$STATE_DIR/listeners"
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "did PATCH the GUI config"      [ -f "$STATE_DIR/gui_patched" ]
  check "  and did post a restart"      [ -f "$STATE_DIR/restart_posted" ]
  check "  and the API agreed with it"  calls_have "127.0.0.1:8384/rest/config/gui"
  check "still caught the live bind"    out_has "GUI repair did NOT take"
  check "  names the address"           out_has "0.0.0.0:8384"
  check "  says it is LAN-reachable"    out_has "reachable from the LAN"
  check "  names this OS's restart"     out_hasF "$RESTART_HINT"
  check "never claimed repaired"        out_lacks "Repaired: GUI"
  check "never reached the summary"     out_lacks "This device ID:"
  teardown
}

test_stale_listen_ip_without_config() {
  echo "• .env pins a tailnet IP this host no longer holds, config.xml gone: refuses to generate one"
  # Warning and carrying on was worse than useless here: the fresh config.xml
  # would be written against the dead address, and every later check would
  # then agree with itself — the exposure check compares the running config
  # to that same dead address, and an empty socket table is only a warning —
  # so the run ended "Done." over a listener that can never bind.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first run succeeded"           [ "$CODE" -eq 0 ]
  rm -f "$(cfg_path)"                   # .env kept, config.xml lost
  echo "100.100.100.200" > "$STATE_DIR/ts_ip"
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the stale .env value"    out_has "SYNCTHING_LISTEN_IP in $SVC/.env is 100.100.100.100"
  check "  and this node's real IP"     out_has "tailnet IP is 100.100.100.200"
  check "  gives the one-line fix"      out_has "set SYNCTHING_LISTEN_IP=100.100.100.200"
  check "generated no config"           no_call "^syncthing generate"
  check "  so none exists"              [ ! -f "$(cfg_path)" ]
  check "started no service"            sh -c "! grep -qE 'systemctl --user restart|launchctl bootstrap' '$CALLS_LOG'"
  check "published nothing"             no_call "tailscale serve"
  check ".env left alone"               grep -qx 'SYNCTHING_LISTEN_IP=100.100.100.100' "$SVC/.env"
  teardown
}

test_socket_check_without_ss() {
  echo "• no ss on this box (the macOS path): the check falls back to lsof and still catches a wildcard"
  # On macOS lsof IS the socket-level check — there is no second opinion. In
  # every other test here the `ss` stub answers, so a broken lsof branch is
  # invisible: run the whole deploy with ss taken off PATH, healthy first and
  # then with :22000 also on 0.0.0.0.
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/noss" ss
  run_deploy_path "$SANDBOX/noss"
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "used lsof"                      calls_have "^lsof "
  check "  never called ss"              no_call "^ss "
  check "  asked it about :22000 (tcp)"  calls_have "lsof -nP -iTCP:22000 -sTCP:LISTEN"
  check "  and :22000 (udp)"             calls_have "lsof -nP -iUDP:22000"
  check "  and the GUI port"             calls_have "lsof -nP -iTCP:8384"
  check "sync bind confirmed"            out_has "bound to 100.100.100.100 only"
  check "GUI bind confirmed"             out_has "GUI port :8384 answers on loopback"
  check "a peer's connection is not a listener" out_lacks "ALSO listening"

  # Same box, same tool, wildcard bind: lsof has to surface it.
  printf '100.100.100.100:22000\n0.0.0.0:22000\n100.100.100.100:8384\n' > "$STATE_DIR/listeners"
  run_deploy_path "$SANDBOX/noss"
  check "wildcard: exits non-zero"       [ "$CODE" -ne 0 ]
  check "  flags the foreign address"    out_has "ALSO listening on: 0.0.0.0:22000"
  check "  says it is off the tailnet"   out_has "off the tailnet"
  teardown
}

test_ipv6_listener_rows() {
  echo "• IPv6 rows: bracketed loopback and this node's tailnet v6 pass; [::] and *: fail the deploy"
  # Two things had no fixture at all: the bracket-stripping that turns
  # "[::1]:8384" into a host, and the tailnet IPv6 entry in the GUI
  # allow-list (tailscaled's Serve frontend listens on BOTH tailnet
  # addresses, on the same port number the GUI binds). Untested, either was
  # free to be wrong in either direction — rejecting a healthy v6 row, or
  # waving through a v6 wildcard, which is the same exposure as 0.0.0.0: an
  # unauthenticated GUI answering the LAN. Both socket tools, because on
  # macOS lsof is the only one there is.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first run succeeded"            [ "$CODE" -eq 0 ]
  local noss="$SANDBOX/noss"
  minimal_path "$noss" ss

  # --- allowed: v6 loopback and the node's own tailnet v6, both bracketed
  printf '100.100.100.100:22000\n[::1]:8384\n[fd7a:115c:a1e0::1234]:8384\n' > "$STATE_DIR/listeners"
  run_deploy
  check "ss: [::1] + tailnet v6 accepted"  [ "$CODE" -eq 0 ]
  check "  reported clean"                 out_has "GUI port :8384 answers on loopback"
  run_deploy_path "$noss"
  check "lsof: same rows accepted"         [ "$CODE" -eq 0 ]
  check "  reported clean"                 out_has "GUI port :8384 answers on loopback"

  # --- foreign: the v6 wildcard. Must FAIL, not merely be mentioned.
  printf '100.100.100.100:22000\n[::]:8384\n' > "$STATE_DIR/listeners"
  run_deploy
  check "ss: [::]:8384 fails the deploy"   [ "$CODE" -ne 0 ]
  check "  names the address"              out_hasF "[::]:8384"
  check "  says the GUI has no password"   out_has "GUI has no password"
  check "  and the non-zero banner"        out_has "Exiting non-zero"
  check "  did not call it clean"          out_lacks "answers on loopback"
  run_deploy_path "$noss"
  check "lsof: [::]:8384 fails the deploy" [ "$CODE" -ne 0 ]
  check "  names the address"              out_hasF "[::]:8384"

  # --- foreign: how ss renders a wildcard bind with no address family shown
  printf '100.100.100.100:22000\n*:8384\n' > "$STATE_DIR/listeners"
  run_deploy
  check "ss: *:8384 fails the deploy"      [ "$CODE" -ne 0 ]
  check "  names the address"              out_hasF "*:8384"
  run_deploy_path "$noss"
  check "lsof: *:8384 fails the deploy"    [ "$CODE" -ne 0 ]
  check "  names the address"              out_hasF "*:8384"
  teardown
}

test_no_socket_tool_at_all() {
  echo "• neither ss nor lsof on the box: neither bind can be verified, so the run exits non-zero"
  # Fail closed on the absence of evidence. The GUI has no password — the
  # tailnet IS the auth layer — so "where is :8384 bound" is a security fact,
  # and a deploy that cannot check one does not get to report it as fine. The
  # deploy itself still comes up; the exit status is what carries the finding.
  #
  # Deliberately NOT the same as "the tool ran and saw nothing": that stays a
  # warning, the way the sync port already treats a bind that has not
  # appeared yet (test_nothing_listening_yet asserts exit 0 for it).
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/nosock" ss lsof
  run_deploy_path "$SANDBOX/nosock"
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "says neither tool is present"   out_has "neither ss nor lsof"
  check "  gives the install fix"        out_has "iproute2"
  check "  and the non-zero banner"      out_has "Exiting non-zero"
  check "called neither tool"            sh -c "! grep -qE '^(ss|lsof) ' '$CALLS_LOG'"
  check "never claimed the bind is fine" out_lacks "answers on loopback"
  # The sync port gets the same treatment. Its empty listener table has the
  # same two causes, and the old message picked the reassuring one out loud:
  # "Syncthing retries the bind on its own" is a diagnosis of a table nothing
  # ever read, and it is the wrong one when a listener is sitting off-tailnet.
  check "  says the sync port is unchecked" out_has "Could not check what is listening on :22000"
  check "  not that a bind is still coming" out_lacks "Nothing is listening on :22000 yet"
  check "  never called it tailnet-only"    out_lacks "is bound to 100.100.100.100 only"
  check "the deploy still came up"       out_has "Device ID: STUBDEV-AAAAAAA"
  check "  and was published"            calls_have "tailscale serve --bg --https=8384"
  teardown
}

test_repair_that_does_not_take_dies() {
  echo "• the REST repair is refused: dies with the manual fix, never claims repaired"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cfg="$(cfg_path)"
  sed 's#<relaysEnabled>false</relaysEnabled>#<relaysEnabled>true</relaysEnabled>#' "$cfg" > "$cfg.new" && cat "$cfg.new" > "$cfg" && rm "$cfg.new"
  touch "$STATE_DIR/patch_fails"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the failed PATCH"        out_has "PATCH /rest/config/options returned HTTP 500"
  check "never claimed repaired"        out_lacks "Repaired:"
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
  check "  gives the fix"               out_has "Restart the service"
  check "  in this OS's terms"          out_hasF "$RESTART_HINT"
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
    # Listening sockets only — a bare -i:PORT also lists ESTABLISHED peers.
    addrs="$( { lsof -nP -iTCP:"$port" -sTCP:LISTEN; lsof -nP -iUDP:"$port"; } 2>/dev/null | awk '$1 != "COMMAND" && $9 !~ /->/ {print $9}')"
  fi
  printf '%s\n' "$addrs" | awk 'NF' | sed 's/:[0-9]*$//' | tr -d '[]' | sort -u
}

# Nothing at all should be bound to Syncthing's LAN-discovery multicast port:
# localAnnounceEnabled is false. This needs to be a predicate of its own —
# written inline as `sh -c "[ -z \"\$(listener_hosts 21027)\" ]"` it called a
# bash function the child `sh` does not have, so the substitution came back
# empty no matter what was listening and the check could never fail.
nothing_listening_on() { [ -z "$(listener_hosts "$1")" ]; }

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
  live_check "no local-discovery multicast on :21027" nothing_listening_on 21027
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

# ------------------------------------------------------------- teardown
run_teardown() {  # run_teardown [flag [flag]] — stdin answer in $ANSWER
  OUT="$(printf '%s\n' "${ANSWER:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" "$@" 2>&1)"
  CODE=$?
}
purge() {  # purge ANSWER [extra flag]
  ANSWER="$1"; shift
  run_teardown --purge "$@"
  ANSWER=""
}

# The unit file setup.sh writes on this platform, and the call that stops it.
if [ "$OS" = "Linux" ]; then
  unit_file() { echo "$HOME/.config/systemd/user/syncthing.service"; }
  STOP_CALL="systemctl --user disable --now syncthing.service"
else
  unit_file() { echo "$HOME/Library/LaunchAgents/net.syncthing.syncthing.plist"; }
  STOP_CALL="launchctl bootout gui/"
fi
stopped()     { calls_have "$STOP_CALL"; }
not_stopped() { no_call "$STOP_CALL"; }
set_env() {  # set_env KEY VALUE — replace one .env line
  local k="$1" v="$2"
  python3 - "$SVC/.env" "$k" "$v" <<'EOF_PYSET'
import sys
path, k, v = sys.argv[1:4]
lines = open(path).read().splitlines()
out = [("%s=%s" % (k, v)) if l.startswith(k + "=") else l for l in lines]
open(path, "w").write("\n".join(out) + "\n")
EOF_PYSET
}

# A deployed sandbox: setup.sh has run, Serve maps :8384 to this GUI, and
# neighbours sit on other ports (one a lookalike suffix). The sync root holds
# a real file, so "files kept" means something.
deployed() {
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  run_deploy
  CFG="$(env_val SYNCTHING_CONFIG)"; DB="$(env_val SYNCTHING_DB)"; DATA="$(env_val SYNCTHING_DATA)"
  mkdir -p "$DB" "$DATA/default"
  echo idx > "$DB/index.db"
  echo "my notes" > "$DATA/default/notes.md"
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8384 (tailnet only)
|-- / proxy http://127.0.0.1:8384

https://test-host.tailfake.ts.net:18384 (tailnet only)
|-- / proxy http://127.0.0.1:18384
EOF_SERVE
  : > "$CALLS_LOG"
}
untouched() {  # nothing on disk changed and nothing was stopped/unpublished
  [ -f "$CFG/cert.pem" ] && [ -f "$DB/index.db" ] && [ -f "$DATA/default/notes.md" ] \
    && [ -f "$SVC/.env" ] && [ -f "$(unit_file)" ] && not_stopped && no_call " off"
}

test_teardown_safe() {
  echo "• teardown: safe remove stops the unit, unpublishes only its port, keeps everything"
  deployed
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "serve off for :8384"           calls_have "tailscale serve --https=8384 off"
  check "neighbour :2283 untouched"     no_call "https=2283"
  check "lookalike :18384 untouched"    no_call "https=18384"
  check "never serve reset"             no_call "serve reset"
  check "unit stopped and disabled"     stopped
  if [ "$OS" = "Darwin" ]; then
    check "LaunchAgent disabled (no restart at login)" calls_have "launchctl disable gui/"
  fi
  check "no daemon-reload (unit kept)"  no_call "daemon-reload"
  check "identity kept"                 [ -f "$CFG/cert.pem" ]
  check "config.xml kept"               [ -f "$CFG/config.xml" ]
  check "index kept"                    [ -f "$DB/index.db" ]
  check "synced files kept"             [ -f "$DATA/default/notes.md" ]
  check ".env kept"                     [ -f "$SVC/.env" ]
  check "unit file kept"                [ -f "$(unit_file)" ]
  check "binary kept"                   [ -x "$HOME/.local/bin/syncthing" ]
  check "lingering never touched"       no_call "linger"
  check "says how to bring it back"     out_has "./setup.sh brings it back as the same device"
  run_teardown
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_override() {
  echo "• teardown: a non-default HTTPS port is found from serve status"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:8384\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "serve off for :9443"           calls_have "tailscale serve --https=9443 off"
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no serve off"                  no_call " off"
  check "says already off"              out_has "already off"
  check "still stops the unit"          stopped
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8384 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no serve off"                  no_call " off"
  check "says nothing points here"      out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE
https://test-host.tailfake.ts.net:8384 (tailnet only)
|-- / proxy http://127.0.0.1:8384

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8384

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /sync proxy http://127.0.0.1:8384
EOF_SERVE
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ":8384 off"                     calls_have "serve --https=8384 off"
  check ":8443 off"                     calls_have "serve --https=8443 off"
  check "shared :443 left on"           no_call "https=443 off"
  check "warns about the shared port"   out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished"   out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8384 (left on, see above); 2 port(s) unpublished"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says why"                      out_has "Could not read Tailscale Serve status"
  check "unit not stopped"              not_stopped
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"       [ "$CODE" -ne 0 ]
  check "no .env: explains"             out_has "nothing to tear down"
  check "no .env: touched nothing"      no_call "systemctl"
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"          [ "$CODE" -ne 0 ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  run_teardown --delete-synced-files
  check "files flag without --purge: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it needs --purge"       out_has "only makes sense with --purge"
  run_teardown --purge --purge
  check "--purge twice: exits non-zero" [ "$CODE" -ne 0 ]
  run_teardown --purge --delete-synced-files extra
  check "three args: exits non-zero"    [ "$CODE" -ne 0 ]
  check "  none of that changed anything" untouched
  if [ "$OS" = "Linux" ]; then
    minimal_path "$SANDBOX/minpath" systemctl
    OUT="$(PATH="$SANDBOX/minpath" bash "$SVC/teardown.sh" 2>&1)"; CODE=$?
    check "no systemctl: exits non-zero" [ "$CODE" -ne 0 ]
    check "  says systemd is required"  out_has "systemd is required"
  fi
  teardown
}

test_teardown_unit_file_missing() {
  echo "• teardown: no unit file, so ask systemd/launchd what still runs under the name"
  deployed
  rm -f "$(unit_file)"
  rm -f "$STATE_DIR"/active.* "$STATE_DIR"/loaded.*
  run_teardown
  check "nothing running: exits zero"   [ "$CODE" -eq 0 ]
  check "  no disable/bootout/stop call" not_stopped
  check "  no stop call"                no_call "systemctl --user stop"
  check "  says nothing to stop"        out_has "nothing to stop"
  check "  still unpublishes"           calls_have "serve --https=8384 off"
  teardown
  if [ "$OS" = "Linux" ]; then
    deployed
    rm -f "$(unit_file)"
    check "file deleted while it ran (stub agrees)" [ -f "$STATE_DIR/active.syncthing" ]
    run_teardown
    check "still running: exits zero"   [ "$CODE" -eq 0 ]
    check "  stopped by name"           calls_have "systemctl --user stop syncthing.service"
    check "  really stopped"            [ ! -f "$STATE_DIR/active.syncthing" ]
    teardown
    deployed
    rm -f "$(unit_file)"
    echo /usr/lib/systemd/user/syncthing.service > "$STATE_DIR/fragment.syncthing"
    run_teardown
    check "distro unit running: exits zero" [ "$CODE" -eq 0 ]
    check "  never stopped"             no_call "systemctl --user stop"
    check "  says it is left running"   out_has "which setup.sh did not write"
    purge "syncthing"
    check "  --purge: refused"          [ "$CODE" -ne 0 ]
    check "  --purge: identity kept"    [ -f "$CFG/cert.pem" ]
    check "  --purge: .env kept"        [ -f "$SVC/.env" ]
    teardown
    deployed
    rm -f "$(unit_file)"
    touch "$STATE_DIR/show_fails"
    run_teardown
    check "systemd cannot be asked: plain remove exits zero" [ "$CODE" -eq 0 ]
    check "  warns how to stop it"      out_has "systemctl --user stop syncthing.service"
    : > "$CALLS_LOG"
    purge "syncthing"
    check "  --purge: refused"          [ "$CODE" -ne 0 ]
    check "  --purge: says why"         out_has "could not say whether"
    check "  --purge: nothing unpublished" no_call " off"
    check "  --purge: identity kept"    [ -f "$CFG/cert.pem" ]
    teardown
    deployed
    rm -f "$(unit_file)"
    purge "syncthing"
    check "--purge with our unit still running: exits zero" [ "$CODE" -eq 0 ]
    check "  stopped before deleting"   calls_have "systemctl --user stop syncthing.service"
    check "  identity gone"             [ ! -e "$CFG" ]
    teardown
    deployed
    touch "$STATE_DIR/stop_ignored"
    purge "syncthing"
    check "unit will not stop: --purge refused" [ "$CODE" -ne 0 ]
    check "  says it is still running"  out_has "still running"
    check "  identity kept"             [ -f "$CFG/cert.pem" ]
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  else
    deployed
    rm -f "$(unit_file)"
    touch "$STATE_DIR/loaded.net.syncthing.syncthing"
    run_teardown
    check "plist gone, agent loaded: booted out" calls_have "launchctl bootout gui/"
    check "  really unloaded"           [ ! -f "$STATE_DIR/loaded.net.syncthing.syncthing" ]
    teardown
  fi
}

test_teardown_other_units_named_not_touched() {
  echo "• teardown: units setup.sh did not write are named and left alone"
  deployed
  local d; d="$(dirname "$(unit_file)")"
  printf '[Unit]\nDescription=back up the syncthing config\n' > "$d/stbackup.service"
  printf '[Timer]\nOnCalendar=daily\n' > "$d/syncthing-resume.timer"
  printf '[Unit]\nDescription=unrelated\n' > "$d/other.service"
  ANSWER="syncthing" run_teardown --purge
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "names the content match"       out_has "stbackup.service"
  check "names the name match"          out_has "syncthing-resume.timer"
  check "unrelated unit not named"      out_lacks "other.service"
  check "never stops them"              no_call "stbackup"
  check "  nor the timer"               no_call "syncthing-resume"
  check "their files survive the purge" [ -f "$d/stbackup.service" ]
  check "  the timer's too"             [ -f "$d/syncthing-resume.timer" ]
  check "only our unit file deleted"    [ ! -e "$(unit_file)" ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then identity + index + .env + unit go, files stay"
  deployed
  purge "sync"
  check "wrong name: exits non-zero"    [ "$CODE" -ne 0 ]
  check "wrong name: changed nothing"   untouched
  purge "syncthing"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns it is the Device ID"     out_has "every peer will see a NEW device"
  check "identity dir gone"             [ ! -e "$CFG" ]
  check "index dir gone"                [ ! -e "$DB" ]
  check ".env gone with it (no split state)" [ ! -f "$SVC/.env" ]
  check "unit file gone"                [ ! -e "$(unit_file)" ]
  if [ "$OS" = "Linux" ]; then
    check "daemon-reload after removing the unit" calls_have "systemctl --user daemon-reload"
  fi
  check "synced files KEPT"             [ -f "$DATA/default/notes.md" ]
  check "says the files are kept"       out_has "Synced files are NOT deleted"
  check "marker kept (it holds files)"  [ -d "$HOME/services/syncthing" ]
  check "binary kept (not service-owned)" [ -x "$HOME/.local/bin/syncthing" ]
  check "says how to remove the binary" out_has "rm $HOME/.local/bin/syncthing"
  check "serve off for :8384"           calls_have "tailscale serve --https=8384 off"
  check "unit stopped before the purge" stopped
  check "services dir itself kept"      [ -d "$HOME/services" ]
  check "lingering never touched"       no_call "linger"
  teardown
}

test_teardown_purge_empty_data_removes_marker() {
  echo "• teardown --purge: an empty sync root goes, and so does the marker"
  deployed
  rm -f "$DATA/default/notes.md"
  purge "syncthing"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "empty data dir removed"        [ ! -e "$DATA" ]
  check "marker removed"                [ ! -e "$HOME/services/syncthing" ]
  check "services dir itself kept"      [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_delete_synced_files() {
  echo "• teardown --purge --delete-synced-files: the sync root goes too"
  deployed
  purge "syncthing" --delete-synced-files
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "synced files gone"             [ ! -e "$DATA" ]
  check "identity gone"                 [ ! -e "$CFG" ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  check "marker removed"                [ ! -e "$HOME/services/syncthing" ]
  teardown
  deployed
  ANSWER="syncthing" run_teardown --delete-synced-files --purge
  check "flags in either order"         [ "$CODE" -eq 0 ]
  check "  files gone"                  [ ! -e "$DATA" ]
  teardown
  deployed
  mkdir -p "$HOME/Sync"; echo x > "$HOME/Sync/keep"
  set_env SYNCTHING_DATA "$HOME/Sync"
  purge "syncthing" --delete-synced-files
  check "files outside ~/services/syncthing: refused" [ "$CODE" -ne 0 ]
  check "  those files kept"            [ -f "$HOME/Sync/keep" ]
  check "  identity kept"               [ -f "$CFG/cert.pem" ]
  check "  nothing stopped"             not_stopped
  teardown
}

test_teardown_purge_folders_elsewhere() {
  echo "• teardown --purge: folders the GUI added elsewhere are kept and named"
  deployed
  mkdir -p "$HOME/Notes"; echo x > "$HOME/Notes/todo.md"
  # A literal ~ on purpose: Syncthing stores GUI-added paths that way.
  # shellcheck disable=SC2088
  python3 - "$CFG/config.xml" "~/Notes" <<'EOF_PYF'
import sys
p, path = sys.argv[1:3]
s = open(p).read()
s = s.replace("<options>", '<folder id="notes" label="Notes" path="%s" type="sendreceive">\n    </folder>\n    <options>' % path, 1)
open(p, "w").write(s)
EOF_PYF
  purge "syncthing" --delete-synced-files
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "names the kept folder"         out_hasF "$HOME/Notes"
  check "that folder survives"          [ -f "$HOME/Notes/todo.md" ]
  check "the sync root is gone"         [ ! -e "$DATA" ]
  teardown
}

test_teardown_purge_refuses_files_inside_state() {
  echo "• teardown --purge: refuses when identity/index dirs hold synced files"
  deployed
  python3 - "$CFG/config.xml" "$CFG/oops" <<'EOF_PYF'
import sys
p, path = sys.argv[1:3]
s = open(p).read()
s = s.replace("<options>", '<folder id="oops" label="Oops" path="%s" type="sendreceive">\n    </folder>\n    <options>' % path, 1)
open(p, "w").write(s)
EOF_PYF
  mkdir -p "$CFG/oops"; echo x > "$CFG/oops/precious"
  purge "syncthing"
  check "folder inside config/: refused" [ "$CODE" -ne 0 ]
  check "  says why"                    out_has "contains synced files"
  check "  nothing changed"             untouched
  check "  those files kept"            [ -f "$CFG/oops/precious" ]
  teardown
  deployed
  python3 - "$CFG/config.xml" "$DB/oops2" <<'EOF_PYF'
import sys
p, path = sys.argv[1:3]
s = open(p).read()
s = s.replace("<options>", '<folder path="%s" id="oops2" label="Oops2" type="sendreceive">\n    </folder>\n    <options>' % path, 1)
open(p, "w").write(s)
EOF_PYF
  mkdir -p "$DB/oops2"; echo x > "$DB/oops2/precious"
  purge "syncthing"
  check "folder inside db/ with path as the first attribute: refused" [ "$CODE" -ne 0 ]
  check "  those files kept"            [ -f "$DB/oops2/precious" ]
  check "  nothing changed"             untouched
  teardown
  deployed
  local db; db="$DB"
  set_env SYNCTHING_DATA "$db/files"
  mkdir -p "$db/files"; echo x > "$db/files/keep"
  purge "syncthing"
  check "SYNCTHING_DATA inside db/: refused" [ "$CODE" -ne 0 ]
  check "  files kept"                  [ -f "$db/files/keep" ]
  check "  nothing stopped"             not_stopped
  teardown
  deployed
  set_env SYNCTHING_DATA ""
  purge "syncthing"
  check "SYNCTHING_DATA missing: refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  teardown
}

add_folder_xml() {  # add_folder_xml RAW_XML — insert verbatim before <options>
  python3 - "$CFG/config.xml" "$1" <<'EOF_PYX'
import sys
p, xml = sys.argv[1:3]
s = open(p).read()
s = s.replace("<options>", xml + "\n    <options>", 1)
open(p, "w").write(s)
EOF_PYX
}

test_teardown_purge_folder_tags_any_layout() {
  echo "• teardown --purge: <folder> tags are read across lines, in any attribute order"
  deployed
  add_folder_xml "<folder id=\"wrapped\"
            label=\"Wrapped\"
            path=\"$DB/oops\" type=\"sendreceive\">
    </folder>"
  mkdir -p "$DB/oops"; echo x > "$DB/oops/precious"
  purge "syncthing"
  check "path= on its own line, folder inside db/: refused" [ "$CODE" -ne 0 ]
  check "  says why"                    out_has "contains synced files"
  check "  those files kept"            [ -f "$DB/oops/precious" ]
  check "  nothing changed"             untouched
  teardown
  deployed
  add_folder_xml "<folder
      type=\"sendreceive\" label=\"Late\"
      id=\"late\"
      path=\"$CFG/late\"
    ></folder>"
  mkdir -p "$CFG/late"; echo x > "$CFG/late/precious"
  purge "syncthing"
  check "'<folder' alone on a line, path last: refused" [ "$CODE" -ne 0 ]
  check "  those files kept"            [ -f "$CFG/late/precious" ]
  check "  nothing changed"             untouched
  teardown
  deployed
  add_folder_xml "<folder id='sq' path = '$DB/sq' />"
  mkdir -p "$DB/sq"; echo x > "$DB/sq/precious"
  purge "syncthing"
  check "single quotes, spaces around =, self-closing: refused" [ "$CODE" -ne 0 ]
  check "  those files kept"            [ -f "$DB/sq/precious" ]
  teardown
  deployed
  mkdir -p "$HOME/Kai's & Notes"; echo x > "$HOME/Kai's & Notes/todo.md"
  add_folder_xml "<folder id=\"n\"
      path=\"$HOME/Kai&#39;s &amp; Notes\" label=\"N\"></folder>"
  purge "syncthing" --delete-synced-files
  check "entity-escaped path elsewhere: exits zero" [ "$CODE" -eq 0 ]
  check "  named as kept, decoded"      out_hasF "$HOME/Kai's & Notes"
  check "  that folder survives"        [ -f "$HOME/Kai's & Notes/todo.md" ]
  teardown
  deployed
  add_folder_xml "<folder id=\"nopath\"
      label=\"No path\"></folder>"
  purge "syncthing"
  check "folder with no path=: refused" [ "$CODE" -ne 0 ]
  check "  says it could not be read"   out_has "could not be read for certain"
  check "  nothing changed"             untouched
  teardown
  deployed
  add_folder_xml "<folder id=\"x\" path=\"$DB/x&#xA;y\"></folder>"
  purge "syncthing"
  check "unknown character reference: refused" [ "$CODE" -ne 0 ]
  check "  nothing changed"             untouched
  teardown
  deployed
  add_folder_xml "<folder id=\"rel\" path=\"relative/dir\"></folder>"
  purge "syncthing"
  check "relative folder path: refused" [ "$CODE" -ne 0 ]
  check "  says it is not absolute"     out_has "is not absolute"
  check "  nothing changed"             untouched
  teardown
}

test_teardown_purge_failure_keeps_env() {
  echo "• teardown --purge: a delete that fails part-way keeps .env for a re-run"
  if [ "$(id -u)" = "0" ]; then echo "    (skipped as root: rm cannot fail)"; return; fi
  deployed
  mkdir -p "$CFG/locked"; echo x > "$CFG/locked/f"; chmod 500 "$CFG/locked"
  purge "syncthing"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check ".env kept"                     [ -f "$SVC/.env" ]
  check "says re-run teardown, not setup" out_has "re-run ./teardown.sh --purge"
  chmod 700 "$CFG/locked"
  purge "syncthing"
  check "re-run completes"              [ "$CODE" -eq 0 ]
  check "  identity gone"               [ ! -e "$CFG" ]
  check "  .env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_missing_dirs() {
  echo "• teardown --purge: identity/index already gone is fine"
  deployed
  rm -rf "$CFG" "$DB"
  purge "syncthing"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  check "unit gone"                     [ ! -e "$(unit_file)" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses identity/index paths outside ~/services/syncthing"
  local var
  for var in SYNCTHING_CONFIG SYNCTHING_DB; do
    deployed
    set_env "$var" "$HOME"
    purge "syncthing"
    check "$var=\$HOME: exits non-zero" [ "$CODE" -ne 0 ]
    check "  home untouched"            [ -d "$HOME" ]
    check "  nothing stopped"           not_stopped
    set_env "$var" "$HOME/services/../x"
    purge "syncthing"
    check "$var '..' refused"           [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services/"
    purge "syncthing"
    check "$var = services dir itself refused" [ "$CODE" -ne 0 ]
    mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
    for dotted in "$HOME/services/." "$HOME/services/./syncthing" "$HOME/services/syncthing/.."; do
      set_env "$var" "$dotted"
      purge "syncthing"
      check "$var '.'/'..' component refused: ${dotted#"$HOME"/}" [ "$CODE" -ne 0 ]
    done
    set_env "$var" "$HOME/services//"
    purge "syncthing"
    check "$var trailing slashes refused" [ "$CODE" -ne 0 ]
    ln -s "$HOME/services" "$HOME/services/alias"
    set_env "$var" "$HOME/services/alias"
    purge "syncthing"
    check "$var symlink to services refused" [ "$CODE" -ne 0 ]
    set_env "$var" "$HOME/services/neighbour"
    purge "syncthing"
    check "$var another service's dir refused" [ "$CODE" -ne 0 ]
    mkdir -p "$HOME/services/syncthing/a:b"
    set_env "$var" "$HOME/services/syncthing/a:b"
    purge "syncthing"
    check "$var colon in the path refused" [ "$CODE" -ne 0 ]
    check "  neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
    check "  files never touched"       [ -f "$DATA/default/notes.md" ]
    check "  .env kept throughout"      [ -f "$SVC/.env" ]
    teardown
  done
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/syncthing/config"; echo x > "$HOME/syncthing/config/keep"
  purge "syncthing"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"      [ -f "$HOME/syncthing/config/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/syncthing survives"
  deployed
  local repo="$HOME/services/syncthing/setup-server/services/syncthing"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/syncthing/setup-server/other.env"
  sed -i.bak "s#^SYNCTHING_CONFIG=.*#SYNCTHING_CONFIG=$HOME/services/syncthing#" "$repo/.env"
  OUT="$(printf '%s\n' "syncthing" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "checkout intact"               [ -f "$repo/teardown.sh" ]
  check "other services' files kept"    [ -f "$HOME/services/syncthing/setup-server/other.env" ]
  check "identity kept"                 [ -f "$CFG/cert.pem" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8384'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"        [ "$CODE" -eq 0 ]
  check ":8384 off"                     calls_have "serve --https=8384 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8384"/' "$SVC/.env"
  run_teardown
  check "double quotes"                 [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8384 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"                [ "$CODE" -eq 0 ]
  check "  :8384 off"                   calls_have "serve --https=8384 off"
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  set_env SYNCTHING_CONFIG "\"\${HOME}${CFG#"$HOME"}\""
  purge "syncthing"
  check "\${HOME} form: exits zero"     [ "$CODE" -eq 0 ]
  check "  identity gone"               [ ! -e "$CFG" ]
  teardown
  deployed
  set_env SYNCTHING_CONFIG "'\$HOME${CFG#"$HOME"}'"
  purge "syncthing"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  identity kept"               [ -f "$CFG/cert.pem" ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SYNCTHING_CONFIG=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"               out_has "SYNCTHING_CONFIG is set more than once"
  check "  touched nothing"             untouched
  teardown
  deployed
  printf 'X="first\nSYNCTHING_CONFIG=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"      out_has "does not close on its line"
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
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    purge "syncthing"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  nothing changed"           untouched
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing stopped"             not_stopped
  teardown
}

test_teardown_no_empty_array_length() {
  echo "• teardown.sh: no \${#arr[@]} on a maybe-empty array — Bash 3.2 + set -u errors there"
  # macOS ships Bash 3.2, where taking the length of an empty array is an
  # unbound-variable error under set -u, not 0. The guarded ${arr[*]+...}
  # form expands to nothing instead, so the branch is simply false.
  check "no array-length expansion" teardown_lacks '\${#[A-Za-z_]+\[@\]}'
}

# A state dir behind a folder this user cannot search (a root-owned 0700
# parent, faked with chmod 000): `[ -e ]` cannot see it, which must not read
# as "already gone" while .env is deleted. No cleanup container here, so it
# stops before anything changes and names the sudo command.
hidden_untouched() {  # hidden_untouched — nothing stopped, unpublished or deleted
  [ -f "$SVC/.env" ] && [ -f "$(unit_file)" ] && not_stopped && no_call " off" \
    && no_call "daemon-reload" && out_lacks "Deleted" && out_lacks "Type syncthing"
}
test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: state behind an unsearchable folder stops before anything changes"
  local st
  # The index behind it.
  deployed
  st="$HOME/services/syncthing/storage"
  mkdir -p "$st"; mv "$DB" "$st/db"
  set_env SYNCTHING_DB "$st/db"
  chmod 000 "$st"
  purge "syncthing"
  chmod 755 "$st"
  check "index hidden: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the folder"          out_has "$st cannot be searched"
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting it" out_lacks "sudo rm -rf $st/db"
  check "  nothing changed"           hidden_untouched
  check "  index kept"                [ -f "$st/db/index.db" ]
  check "  identity kept"             [ -f "$CFG/cert.pem" ]
  check "  synced files kept"         [ -f "$DATA/default/notes.md" ]
  teardown
  # The identity behind it: config.xml (the folder list) cannot be read.
  deployed
  st="$HOME/services/syncthing/storage"
  mkdir -p "$st"; mv "$CFG" "$st/config"
  set_env SYNCTHING_CONFIG "$st/config"
  chmod 000 "$st"
  purge "syncthing"
  chmod 755 "$st"
  check "identity hidden: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting it" out_lacks "sudo rm -rf $st/config"
  check "  nothing changed"           hidden_untouched
  check "  identity kept"             [ -f "$st/config/cert.pem" ]
  check "  index kept"                [ -f "$DB/index.db" ]
  teardown
  # The synced files behind it, with --delete-synced-files.
  deployed
  st="$HOME/services/syncthing/storage"
  mkdir -p "$st"; mv "$DATA" "$st/data"
  set_env SYNCTHING_DATA "$st/data"
  chmod 000 "$st"
  purge "syncthing" --delete-synced-files
  chmod 755 "$st"
  check "files hidden (--delete-synced-files): exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting it" out_lacks "sudo rm -rf $st/data"
  check "  nothing changed"           hidden_untouched
  check "  synced files kept"         [ -f "$st/data/default/notes.md" ]
  check "  identity kept"             [ -f "$CFG/cert.pem" ]
  teardown
  # Without the flag the synced files are kept anyway, so a hidden sync
  # root does not block the purge.
  deployed
  st="$HOME/services/syncthing/storage"
  mkdir -p "$st"; mv "$DATA" "$st/data"
  set_env SYNCTHING_DATA "$st/data"
  chmod 000 "$st"
  purge "syncthing"
  chmod 755 "$st"
  check "files hidden, kept anyway: exits zero" [ "$CODE" -eq 0 ]
  check "  synced files kept"         [ -f "$st/data/default/notes.md" ]
  check "  identity gone"             [ ! -e "$CFG" ]
  teardown
  # The identity dir itself cannot be searched: config.xml is unreadable.
  deployed
  chmod 000 "$CFG"
  purge "syncthing"
  chmod 700 "$CFG"
  check "identity dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says config.xml cannot be read" out_has "config.xml"
  check "  nothing changed"           hidden_untouched
  check "  identity kept"             [ -f "$CFG/cert.pem" ]
  check "  index kept"                [ -f "$DB/index.db" ]
  teardown
  # ~/services/syncthing itself unsearchable.
  deployed
  st="$HOME/services/syncthing"
  chmod 000 "$st"
  purge "syncthing"
  chmod 755 "$st"
  check "state root unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to restore access"    out_has "sudo chown -R .* $st"
  check "  never suggests deleting"   out_lacks "sudo rm -rf"
  check "  nothing changed"           hidden_untouched
  check "  identity kept"             [ -f "$CFG/cert.pem" ]
  check "  index kept"                [ -f "$DB/index.db" ]
  check "  synced files kept"         [ -f "$DATA/default/notes.md" ]
  teardown
  # ~/services itself unsearchable: not provably this service's folder.
  deployed
  chmod 000 "$HOME/services"
  purge "syncthing"
  chmod 755 "$HOME/services"
  check "\$HOME/services unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says to check it first"    out_has "Check what it is"
  check "  nothing changed"           hidden_untouched
  check "  identity kept"             [ -f "$CFG/cert.pem" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE
https://test-host.tailfake.ts.net (tailnet only)
|-- /     proxy http://127.0.0.1:8080
|-- /sync proxy http://127.0.0.1:8384
EOF_SERVE
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "no serve off"                  no_call " off"
  check "does not say already off"      out_lacks "already off"
  check "counts the kept port"          out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8384 (left on, see above); 0 port(s) unpublished"
  check "still stops the unit"          stopped
  teardown
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ]; then
  red "services/syncthing/setup.sh is missing — nothing to test."
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
test_exposure_drift_repaired
test_preference_drift_only_warns
test_gui_drift_repaired
test_gui_repair_restart_refused
test_gui_repair_not_on_the_wire
test_repair_that_does_not_take_dies
test_tailnet_ip_changed
test_stale_listen_ip_without_config
test_hostcheck_403
test_wildcard_socket
test_nothing_listening_yet
test_socket_check_without_ss
test_ipv6_listener_rows
test_no_socket_tool_at_all
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_https_port_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_unit_file_missing
test_teardown_other_units_named_not_touched
test_teardown_purge
test_teardown_purge_empty_data_removes_marker
test_teardown_purge_delete_synced_files
test_teardown_purge_folders_elsewhere
test_teardown_purge_refuses_files_inside_state
test_teardown_purge_folder_tags_any_layout
test_teardown_purge_failure_keeps_env
test_teardown_purge_missing_dirs
test_teardown_purge_refuses_odd_paths
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_quoted_env
test_teardown_home_variable_in_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports
test_teardown_no_empty_array_length

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
