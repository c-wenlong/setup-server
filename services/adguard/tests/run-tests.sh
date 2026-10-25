#!/usr/bin/env bash
#
# Tests for services/adguard/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with PATH stubs for docker/tailscale/curl/dig/ss/python3/sudo/id/sleep.
#
# What makes this service's suite different from the others here.
#
# 1. A LISTENER PROVES NOTHING. A fresh AdGuard container serves only the
#    install wizard and runs NO DNS server at all — yet Docker's port mapping
#    still makes `ss` report <tailnet-ip>:53 as LISTEN. Measured in that
#    state, `dig @<ip> example.com` comes back CONNECTION REFUSED. So every
#    socket-shaped health check passes against a completely dead resolver.
#    The `dig` stub refuses every query until the install API has actually
#    succeeded, and refuses any query aimed at the wrong server, so a setup.sh
#    that skipped the install — or verified against 127.0.0.1 — cannot go
#    green. That is the single most important thing this suite does.
#
# 2. THE INSTALL BODY IS VALIDATED, NOT RUBBER-STAMPED. The `web` block must
#    name the address AdGuard is ALREADY serving on (0.0.0.0:3000,
#    container-internal). Naming anything else makes AdGuard try to bind the
#    new address to check it, and it loses that race against itself:
#      400 checking address 127.0.0.1:3000: listen tcp: address already in use
#    127.0.0.1:3000 is the natural thing to put there — it is the correct
#    value everywhere else in this repo — so the curl stub returns the real
#    400 for it rather than accepting it.
#
# 3. THE DNS PORT IS THE ONE DELIBERATE EXCEPTION to the loopback-only rule
#    (Serve proxies HTTP, not UDP; Tailscale's Nameservers setting needs a
#    real IP to point at). So the assertions are two-sided: :53 MUST be on the
#    tailnet address, and MUST NOT be on 0.0.0.0 or a LAN address. A wildcard
#    publish would put an open recursive resolver on the LAN.
#
# 4. THE TAILNET IP IS RESOLVED, NOT HARDCODED. The tailscale stub reports
#    100.77.77.77 — deliberately NOT this box's real 100.85.87.87 — so a
#    literal baked into docker-compose.yml or setup.sh cannot pass by
#    coincidence.
#
# Nothing here touches the host: no ~/services/adguard, no real .env, no DNS
# query leaves the machine, and systemd-resolved is never so much as read.
# test_sandbox_was_hermetic proves it with before/after checksums.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# The address the tailscale stub reports. Not this box's real tailnet IP, on
# purpose — see note 4 above.
FAKE_TS_IP=100.77.77.77

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
  chmod -R u+w "$SANDBOX" 2>/dev/null  # the purge tests make read-only dirs
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT ADGUARD_ADMIN_USERNAME STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# A PATH containing ONLY what we hand it — used to prove the preflight
# branches that turn on a command being absent. Appending the stub dir to the
# real PATH cannot express "dig does not exist": /usr/bin/dig would still be
# found. So build a directory holding real coreutils plus the stubs we want,
# and run with nothing else on PATH.
minimal_path() {  # minimal_path <dir> [stub-basename-to-omit ...]
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p s base omit skip
  for c in bash sh env uname mktemp rm cat head cut sed awk grep tr chmod \
           mkdir rmdir df cp mv ln ls stat od readlink dirname basename seq \
           touch sort wc test; do
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
  if "$@"; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_hasF()   { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
teardown_lacks() { ! grep -qE -- "$1" "$SERVICE_DIR/teardown.sh"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }
body_has()   { grep -qF -- "$2" "$STATE_DIR/$1" 2>/dev/null; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, comments stripped. This file
# documents at length what it deliberately does NOT do — "upstream publishes
# 53:53 and 3000:3000, i.e. 0.0.0.0", "do NOT float to `latest`", the whole
# explanation of the permcheck warning — so a naive grep would match the prose
# and conclude the exact opposite of the truth.
compose_has()   { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qE -- "$1"; }
compose_hasF()  { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }
compose_lacks() { ! compose_has "$1"; }

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
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_bad_port() {
  echo "• preflight rejects non-numeric ports"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "HTTPS_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "HTTPS_PORT: says numeric"   out_has "must be numeric"
  unset HTTPS_PORT
  export LOCAL_PORT=30o8
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_no_tailnet_ip() {
  echo "• preflight fails when this node has no tailnet IPv4"
  # Not a hypothetical and not cosmetic: the DNS ports bind to that specific
  # address. With no address there is nothing to bind, and the only "helpful"
  # fallback available — 0.0.0.0 — would publish an open resolver to the LAN.
  # Refusing is the correct behaviour.
  setup
  touch "$STATE_DIR/no_ts_ip"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the missing value" out_has "tailnet IPv4"
  check "  says why it matters"   out_has "binds to that address"
  check "wrote no .env"           [ ! -f "$SVC/.env" ]
  check "started no container"    [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_no_dns_tool() {
  echo "• preflight fails when the box has no way to ask a DNS question"
  # Without dig or python3 the deploy cannot run the one check that
  # distinguishes a working resolver from a container that merely started, so
  # it refuses rather than shipping an unverifiable deploy.
  setup
  minimal_path "$SANDBOX/nodns" dig python3
  run_deploy_path "$SANDBOX/nodns"
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says it could not verify"  out_has "verify its own resolver"
  check "  explains the trap"       out_has "refusing queries looks identical"
  if [ "$OS" = "Linux" ]; then
    check "  gives the install fix"  out_has "dnsutils"
  else
    check "  gives the macOS fix"    out_has "brew install bind"
  fi
  check "wrote no .env"             [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: installed via the API, DNS proven by a real query"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]

  # --- the tailnet IP is RESOLVED, never assumed -------------------------
  check "asked tailscale for the v4 address" calls_have "^tailscale ip -4"
  check ".env records the resolved IP"   [ "$(env_val ADGUARD_DNS_IP)" = "$FAKE_TS_IP" ]
  check "  and it is not this box's real one" \
    [ "$(env_val ADGUARD_DNS_IP)" != "100.85.87.87" ]

  # --- .env
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               [ "$(file_mode "$SVC/.env")" = "600" ]
  check "pinned to v0.107.79, not latest" grep -qx 'ADGUARD_VERSION=v0.107.79' "$SVC/.env"
  check ".env records the local port"    grep -qx 'LOCAL_PORT=3080' "$SVC/.env"
  check ".env has a hex admin password"  grep -qE '^ADGUARD_ADMIN_PASSWORD=[a-f0-9]{32}$' "$SVC/.env"
  check ".env names the admin user"      [ "$(env_val ADGUARD_ADMIN_USER)" = "kai" ]
  check ".env has ADGUARD_CONF"          grep -qE '^ADGUARD_CONF=/.+' "$SVC/.env"
  check ".env has ADGUARD_WORK"          grep -qE '^ADGUARD_WORK=/.+' "$SVC/.env"
  check ".env records the rate limit"    grep -qx 'ADGUARD_RATELIMIT=0' "$SVC/.env"

  # --- compose, statically
  check "web UI published on loopback"   compose_hasF '127.0.0.1:${LOCAL_PORT:-3080}:3000/tcp'
  check "DNS published on the tailnet IP (tcp)" compose_has '\$\{ADGUARD_DNS_IP[^}]*\}:53:53/tcp'
  check "DNS published on the tailnet IP (udp)" compose_has '\$\{ADGUARD_DNS_IP[^}]*\}:53:53/udp'
  # A wildcard DNS publish is not a style problem: it is an open recursive
  # resolver on the LAN, which is a DDoS amplifier.
  check "no wildcard bind anywhere"      compose_lacks '0\.0\.0\.0'
  # A literal tailnet IP would be wrong on any other machine and would break
  # silently if this node's address ever changed.
  check "no hardcoded tailnet literal"   compose_lacks '100\.[0-9]+\.[0-9]+\.[0-9]+'
  check "does not claim host port 3000"  compose_lacks '[:"'"'"' ]3000:3000'
  check "image pinned from .env"         compose_hasF 'image: adguard/adguardhome:${ADGUARD_VERSION'
  check "  and never :latest"            compose_lacks ':latest'
  # unless-stopped, not always, and not absent: the DNS ports bind to a
  # specific IP, and that bind fails while tailscale0 does not exist yet.
  # dockerd can start before tailscaled after a reboot.
  check "restart: unless-stopped"        compose_has 'restart: *unless-stopped'

  # --- state dirs, at 0700
  check "conf dir created"               [ -d "$(env_val ADGUARD_CONF)" ]
  check "work dir created"               [ -d "$(env_val ADGUARD_WORK)" ]
  # 0775 makes AdGuard log a permcheck warning on every single start, which
  # trains you to ignore its warnings.
  check "conf dir is 0700"               [ "$(file_mode "$(env_val ADGUARD_CONF)")" = "700" ]
  check "work dir is 0700"               [ "$(file_mode "$(env_val ADGUARD_WORK)")" = "700" ]
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]

  # --- the install API
  check "install API called"             calls_have "/control/install/configure"
  check "  web block names 0.0.0.0:3000" body_has install_body '"web":{"ip":"0.0.0.0","port":3000}'
  check "  dns block names 0.0.0.0:53"   body_has install_body '"dns":{"ip":"0.0.0.0","port":53}'
  check "  username from .env"           body_has install_body "\"username\":\"$(env_val ADGUARD_ADMIN_USER)\""
  check "  plaintext password from .env" body_has install_body "\"password\":\"$(env_val ADGUARD_ADMIN_PASSWORD)\""
  check "reported the install"           out_has "Install API accepted"
  # The rate limit is a deliberate deviation from AdGuard's shipped 20, so it
  # has to actually be applied — and said out loud.
  check "rate limit applied"             [ -f "$STATE_DIR/dns_config_body" ]
  check "  body carries the value"       body_has dns_config_body '{"ratelimit":0}'
  check "  says it deviates from 20"     out_has "AdGuard ships 20"

  # --- publish
  check "served on tailscale :3080"      calls_have "tailscale serve --bg --https=3080 http://127.0.0.1:3080"
  check "no sudo needed (operator set)"  no_call "^sudo "

  # --- VERIFICATION: the part a socket cannot fake -----------------------
  check "signed in with the generated password" out_has "Signed in as kai"
  check "  and AdGuard says DNS is running"     out_has "DNS server as running"
  check "resolved a real name"           out_has "DNS is really resolving"
  check "  queried the tailnet IP"       calls_have "^dig .*@$FAKE_TS_IP example.com"
  check "  never queried loopback"       no_call "^dig .*@127.0.0.1"
  check "  and got a real A record"      out_hasF "93.184.216.34"
  check "confirmed blocking works"       out_has "Ad blocking is live"
  check "audited the DNS listener"       out_has "DNS (:53) listens only on loopback"
  check "audited the web listener"       out_has "Web UI (:3080) listens only on loopback"

  # --- the manual step has to be impossible to miss ----------------------
  check "prints the manual step banner"  out_has "ONE MANUAL STEP LEFT"
  check "  says it filters nothing yet"  out_has "filters NOTHING"
  check "  gives the console URL"        out_hasF "login.tailscale.com/admin/dns"
  check "  gives the IP to type in"      out_hasF "$FAKE_TS_IP"
  check "  says why it is not automated" out_has "changes DNS for your phone and laptop"
  check "  and how to undo it"           out_has "remove the nameserver"
  check "flags MagicDNS as unverified"   out_has "NOT verified here"
  check "mentions the query-log privacy" out_has "query log records every"
  check "prints the final URL"           out_hasF "https://test-host.tailfake.ts.net:3080"

  # --- the host's own DNS is never touched -------------------------------
  # Disabling systemd-resolved is the standard advice and it is wrong here:
  # resolved binds only 127.0.0.53/127.0.0.54, so there is no conflict, and
  # breaking it would break name resolution for every other service on the box.
  check "never called systemctl"         no_call "systemctl"
  check "never called resolvectl"        no_call "resolvectl"
  check "never touched resolv.conf"      out_lacks "resolv.conf"
  teardown
}

test_readiness_race() {
  echo "• cold start refuses the connection: the readiness loop retries, not dies"
  # A container that is 'up' is not a server that is listening. Real curl
  # answers a refused connection with exit 7 and http_code 000 — not a tidy
  # 503 — and a deploy that treats the first 000 as fatal fails most cold
  # starts. Jellyfin's deploy in this repo was bitten by exactly this.
  setup
  touch "$STATE_DIR/operator"
  echo 3 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "polled /control/status repeatedly" [ "$(call_count '/control/status')" -ge 4 ]
  check "  waited between polls"       [ "$(call_count '^sleep ')" -ge 3 ]
  check "did not report a 000 failure" out_lacks "never accepted a connection"
  check "still ran the install"        [ -f "$STATE_DIR/install_body" ]
  check "still published"              calls_have "tailscale serve --bg --https=3080"
  check "still resolved a real name"   out_has "DNS is really resolving"
  teardown
}

test_never_ready() {
  echo "• web API never answers: dies before configuring anything"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/conn_refused_left"   # more refusals than the loop has tries
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says it never connected"   out_has "never accepted a connection"
  check "ran no install"            [ ! -f "$STATE_DIR/install_body" ]
  check "published nothing"         no_call "tailscale serve"
  teardown
}

test_install_wrong_web_block() {
  echo "• install API 400s (wrong web block): fatal, explained, nothing published"
  # The measured trap. AdGuard validates the requested web address by binding
  # it, so anything other than the address it already serves on — 0.0.0.0:3000
  # inside the container — collides with AdGuard itself. 127.0.0.1:3000 is the
  # natural guess because it is right everywhere else in this repo.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/install_400"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the 400"              out_has "HTTP 400"
  check "  quotes the server's reason" out_has "address already in use"
  check "  names the expected value" out_hasF "0.0.0.0:3000"
  check "  says nothing was changed" out_has "Nothing was changed"
  check "  warns DNS is still dead"  out_has "install wizard"
  check "published nothing"          no_call "tailscale serve"
  teardown
}

test_install_race_403_is_success() {
  echo "• install API 403 (already configured): success, not an error"
  # What a second configure returns. Reached if two runs overlap, or if the
  # box was configured between the status check and the POST. It is the
  # desired end state, so treating it as a failure would break idempotency.
  setup
  touch "$STATE_DIR/operator"
  # Configured *after* the status check would see 302: force the 403 branch by
  # letting the status endpoint report unconfigured while configure refuses.
  echo 403 > "$STATE_DIR/install_code"
  run_deploy
  check "reported it as already configured" out_has "already configured"
  check "did not call it a failure"         out_lacks "install API returned HTTP 403"
  check "still published"                   calls_have "tailscale serve --bg --https=3080"
  teardown
}

test_install_other_error() {
  echo "• install API 500: fatal, and says DNS is not running"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/install_code"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the code"          out_has "HTTP 500"
  check "says NO DNS server"      out_has "NO DNS server"
  check "published nothing"       no_call "tailscale serve"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, install NOT repeated, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  check "first run installed"           [ -f "$STATE_DIR/install_body" ]
  echo '# my-custom-marker' >> "$SVC/.env"
  pw="$(env_val ADGUARD_ADMIN_PASSWORD)"
  rm -f "$STATE_DIR/install_body" "$STATE_DIR/dns_config_body"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "existing .env untouched"       env_has "my-custom-marker"
  check "  password unchanged"          [ "$(env_val ADGUARD_ADMIN_PASSWORD)" = "$pw" ]
  check "  says it left .env alone"     out_has "leaving untouched"
  check "install NOT re-run"            [ ! -f "$STATE_DIR/install_body" ]
  check "  says it is already configured" out_has "already configured"
  # Re-applying the rate limit on every run would stomp a value changed in the
  # web UI, which the repo's idempotency rule forbids.
  check "rate limit NOT re-applied"     [ ! -f "$STATE_DIR/dns_config_body" ]
  check "never invoked sudo"            no_call "^sudo "
  check "compose up re-invoked"         [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"       calls_have "tailscale serve --bg --https=3080 http://127.0.0.1:3080"
  check "re-verified by resolving"      out_has "DNS is really resolving"
  teardown
}

test_config_wiped_reinstalls() {
  echo "• config deleted but .env kept: re-installs instead of trusting a marker"
  # There is no marker file, deliberately: the live /control/status code IS
  # the state. If someone wipes ADGUARD_CONF, a cached "already configured"
  # would make the run skip the install and hand back a box sitting on the
  # wizard — green everywhere, resolving nothing.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  rm -f "$STATE_DIR/configured" "$STATE_DIR/creds" "$STATE_DIR/install_body"
  : > "$CALLS_LOG"
  run_deploy                                   # AdGuard is back at first-run
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "noticed it is unconfigured"  out_has "UNCONFIGURED"
  check "ran the install again"       [ -f "$STATE_DIR/install_body" ]
  check "  with the .env password"    body_has install_body "\"password\":\"$(env_val ADGUARD_ADMIN_PASSWORD)\""
  check "resolver works afterwards"   out_has "DNS is really resolving"
  teardown
}

test_up_fails_bind() {
  echo "• compose up cannot bind the tailnet address: names the real cause"
  # The reboot race: the DNS ports bind to a specific IP and dockerd can start
  # before tailscaled. Compose's own message blames "userland proxy", which
  # sends you looking in the wrong place.
  setup
  touch "$STATE_DIR/operator"
  echo bind > "$STATE_DIR/up_fail"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the address"          out_hasF "$FAKE_TS_IP:53"
  check "  says the box lacks it"    out_has "does not hold that address"
  check "  offers both causes"       out_has "tailscaled is not up yet"
  check "  points at the .env key"   out_has "ADGUARD_DNS_IP"
  check "published nothing"          no_call "tailscale serve"
  teardown
}

test_up_fails_port_in_use() {
  echo "• port conflict on up: says resolved's stubs are NOT the conflict"
  # The reflex on a :53 conflict is to disable systemd-resolved, which would
  # break name resolution for every other service on this box and is not the
  # problem: resolved binds 127.0.0.53/127.0.0.54, never the tailnet address.
  setup
  touch "$STATE_DIR/operator"
  echo inuse > "$STATE_DIR/up_fail"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "says port conflict"             out_has "Port conflict"
  check "  gives the diagnostic command" out_has "ss -ltnup"
  check "  exonerates systemd-resolved"  out_has "do NOT conflict"
  teardown
}

test_dns_ip_drift() {
  echo "• the node's tailnet IP moved: warns, does not silently rewrite .env"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy at 100.77.77.77
  echo "100.66.66.66" > "$STATE_DIR/ts_ip"     # ...the node's address changes
  : > "$CALLS_LOG"
  run_deploy
  check "warns about the drift"      out_has "ADGUARD_DNS_IP in .env is"
  check "  names the new address"    out_hasF "100.66.66.66"
  check "  predicts the bind failure" out_has "cannot assign requested address"
  check "  says to update the console too" out_has "Tailscale admin console"
  check ".env left alone (user's)"   [ "$(env_val ADGUARD_DNS_IP)" = "$FAKE_TS_IP" ]
  teardown
}

test_dns_never_resolves() {
  echo "• everything up but the resolver answers nothing: FAILS the deploy"
  # The headline case. The container is running, the web UI is fine, the port
  # is published — and every query is refused. A socket check would call this
  # a success.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # deploy normally
  touch "$STATE_DIR/dns_dead"                  # ...then the resolver dies
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "says no A record came back"   out_has "did not return an A record"
  check "  says the port proves nothing" out_has "means nothing here"
  check "  gives the dig command"      out_hasF "dig @$FAKE_TS_IP"
  check "summary reports the failure"  out_has "Deploy finished with failures"
  check "  and does not say Done"      out_lacks "AdGuard Home is at"
  teardown
}

test_filter_lists_lag() {
  echo "• filter lists still downloading: a warning, not a failed deploy"
  # On a first deploy the ~178k rules land a few seconds after the resolver
  # starts working. Failing the deploy for that would make a correct run red.
  setup
  touch "$STATE_DIR/operator"
  echo 99 > "$STATE_DIR/filters_pending"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "resolver still verified"     out_has "DNS is really resolving"
  check "warns blocking is not live yet" out_has "did not come back blocked yet"
  check "  points at the filters page" out_has "DNS blocklists"
  check "  did not claim blocking works" out_lacks "Ad blocking is live"
  teardown
}

test_password_drift() {
  echo "• admin password changed in the UI: fails loudly, does NOT retry-loop"
  # AdGuard blocks an account for 15 minutes after 5 failed logins, so a
  # retry loop around a 401 turns a stale .env into a lockout. Exactly one
  # authenticated attempt is allowed.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # deploy, credentials agree
  touch "$STATE_DIR/bad_password"              # ...changed in the web UI
  : > "$CALLS_LOG"
  run_deploy
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "names the rejected login"    out_has "was rejected"
  check "  points at .env"            out_has "Mirror it back into .env"
  check "  warns about the lockout"   out_has "15 minutes"
  check "tried the login exactly once" [ "$(call_count '-u .*/control/status')" -eq 1 ]
  check "did not claim it signed in"  out_lacks "Signed in as"
  teardown
}

test_dns_reports_not_running() {
  echo "• signed in fine but AdGuard says running:false — caught, not celebrated"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/dns_not_running"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the contradiction"  out_has 'does not report'
  check "summary reports failure"  out_has "Deploy finished with failures"
  teardown
}

test_wildcard_dns_listener() {
  echo "• :53 published on 0.0.0.0: hard failure (open resolver on the LAN)"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_dns_wildcard"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the DNS port"         out_has "DNS (:53) is listening on non-tailnet"
  check "  names the bad address"    out_hasF "0.0.0.0"
  check "  points at the ports block" out_has "ports block"
  check "summary reports failure"    out_has "Deploy finished with failures"
  teardown
}

test_lan_dns_listener() {
  echo "• :53 published on a LAN address instead of the tailnet one: failure"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_dns_lan"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the LAN address"   out_hasF "192.168.1.42"
  check "  calls it outside the boundary" out_has "outside the tailnet boundary"
  teardown
}

test_lan_web_listener() {
  echo "• the web UI escaped loopback: failure"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_web_lan"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the web port"    out_has "Web UI (:3080) is listening on non-tailnet"
  teardown
}

test_resolved_stubs_are_not_a_failure() {
  echo "• systemd-resolved's 127.0.0.53/.54 stubs on :53 are accepted, not flagged"
  # They share the port number and they are supposed to be there — this deploy
  # leaves resolved completely alone, which is how the host itself (and every
  # other service on it) still resolves names. A check that flagged them would
  # push someone into disabling resolved, which is the actual disaster.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "stub listeners were present" calls_have "^ss .*sport = :53"
  check "  and did not fail the audit" out_has "DNS (:53) listens only on loopback"
  teardown
}

test_listener_audit_without_ss() {
  echo "• no ss on the box (macOS): the listener audit falls back to lsof"
  # Both halves matter. lsof exits 1 when nothing matches, and under
  # `set -o pipefail` that status is enough to kill an unguarded assignment —
  # so the fallback has to tolerate "no listeners" (a legitimate answer the
  # caller already treats as nothing-bad) while still catching a wildcard.
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/noss" ss
  run_deploy_path "$SANDBOX/noss"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used lsof, not ss"           calls_have "^lsof "
  check "  never called ss"           no_call "^ss "
  check "DNS audit still passed"      out_has "DNS (:53) listens only on loopback"
  check "web audit still passed"      out_has "Web UI (:3080) listens only on loopback"
  teardown

  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_dns_wildcard"
  minimal_path "$SANDBOX/noss" ss
  run_deploy_path "$SANDBOX/noss"
  check "wildcard still caught via lsof" [ "$CODE" -ne 0 ]
  check "  names the DNS port"        out_has "DNS (:53) is listening on non-tailnet"
  teardown
}

test_container_not_running() {
  echo "• container exited: failure, with the logs command"
  setup
  touch "$STATE_DIR/operator"
  echo exited > "$STATE_DIR/container_status"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the state"       out_has "Container is 'exited'"
  check "gives the logs command" out_has "logs adguard"
  teardown
}

test_restart_count_is_not_a_fault() {
  echo "• restarted a few times after a reboot: reported, not failed"
  # The tailscale0-after-dockerd race. `restart: unless-stopped` makes it
  # self-heal, so a non-zero RestartCount right after a boot is expected.
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/restart_count"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "mentions the restarts"      out_has "restarted 2x"
  check "  explains the boot race"   out_has "dockerd beats tailscaled"
  teardown
}

test_https_front_door_slow() {
  echo "• tailnet HTTPS not answering yet: a warning, not a failed deploy"
  # First request on a new port can take ~60s while the cert is minted.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/https_dead"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns about the cert"       out_has "cert may still be minting"
  check "  gives the retry command"  out_has "curl -o /dev/null"
  check "still verified DNS"         out_has "DNS is really resolving"
  teardown
}

test_ratelimit_option() {
  echo "• ADGUARD_RATELIMIT: applied when it deviates, skipped at AdGuard's 20"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                    # default 0
  check "default 0 applied"          body_has dns_config_body '{"ratelimit":0}'
  teardown

  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # Rewrite .env to AdGuard's shipped value and start over from an
  # unconfigured server, so JUST_INSTALLED is true again.
  sed -i.bak 's/^ADGUARD_RATELIMIT=.*/ADGUARD_RATELIMIT=20/' "$SVC/.env" 2>/dev/null \
    || sed -i '' 's/^ADGUARD_RATELIMIT=.*/ADGUARD_RATELIMIT=20/' "$SVC/.env"
  rm -f "$STATE_DIR/configured" "$STATE_DIR/creds" "$STATE_DIR/dns_config_body"
  run_deploy
  check "20 = shipped default, left alone" [ ! -f "$STATE_DIR/dns_config_body" ]
  teardown

  setup
  touch "$STATE_DIR/operator"
  run_deploy
  sed -i.bak 's/^ADGUARD_RATELIMIT=.*/ADGUARD_RATELIMIT=lots/' "$SVC/.env" 2>/dev/null \
    || sed -i '' 's/^ADGUARD_RATELIMIT=.*/ADGUARD_RATELIMIT=lots/' "$SVC/.env"
  run_deploy
  check "non-numeric is rejected"    [ "$CODE" -ne 0 ]
  check "  says what it wants"       out_has "non-negative integer"
  teardown
}

test_ratelimit_failure_is_soft() {
  echo "• the rate-limit call fails: warned about, deploy still succeeds"
  # A resolver that rate-limits is still a resolver.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/ratelimit_fails"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "warns it kept 20 qps"    out_has "keeps its default of 20"
  check "still verified DNS"      out_has "DNS is really resolving"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  echo 3081 > "$STATE_DIR/web_port"
  export LOCAL_PORT=3081 HTTPS_PORT=3081
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=3081' "$SVC/.env"
  check "polled :3081"               calls_have "127.0.0.1:3081/control/status"
  check "served :3081 -> :3081"      calls_have "tailscale serve --bg --https=3081 http://127.0.0.1:3081"
  check "prints the :3081 URL"       out_hasF "https://test-host.tailfake.ts.net:3081"
  # Never 3000: that is AdGuard's default web port and forgejo owns it here.
  check "never touched :3000"        no_call "127.0.0.1:3000/"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under its published port.
  export LOCAL_PORT=3082 HTTPS_PORT=3081
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=3082 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=3081' "$SVC/.env"
  check "re-run: never touched 3082" no_call "127.0.0.1:3082"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (3080) next to a LOCAL_PORT
  # override silently published :3080 -> 127.0.0.1:3084, i.e. the wrong port.
  setup
  touch "$STATE_DIR/operator"
  echo 3084 > "$STATE_DIR/web_port"
  export LOCAL_PORT=3084
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=3084"  grep -qx 'LOCAL_PORT=3084' "$SVC/.env"
  check "served :3084 -> 127.0.0.1:3084" calls_have "tailscale serve --bg --https=3084 http://127.0.0.1:3084"
  check "  and never :3080"             no_call "tailscale serve --bg --https=3080"
  check "prints the :3084 URL"          out_hasF "https://test-host.tailfake.ts.net:3084"
  # Re-run with no override at all: .env says 3084, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 3080.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  check "re-run kept :3084 -> 127.0.0.1:3084" calls_have "tailscale serve --bg --https=3084 http://127.0.0.1:3084"
  check "  and never :3080"             no_call "tailscale serve --bg --https=3080"
  teardown

  setup
  touch "$STATE_DIR/operator"
  echo 3084 > "$STATE_DIR/web_port"
  export LOCAL_PORT=3084 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:3084" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:3084"
  check "prints the :8443 URL"          out_hasF "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_admin_username_override() {
  echo "• ADGUARD_ADMIN_USERNAME: honoured on the first run, .env wins after"
  setup
  touch "$STATE_DIR/operator"
  export ADGUARD_ADMIN_USERNAME=kaichen
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env records the username"   [ "$(env_val ADGUARD_ADMIN_USER)" = "kaichen" ]
  check "install used it"             body_has install_body '"username":"kaichen"'
  unset ADGUARD_ADMIN_USERNAME
  export ADGUARD_ADMIN_USERNAME=someone-else
  run_deploy
  check "re-run: .env still wins"     [ "$(env_val ADGUARD_ADMIN_USER)" = "kaichen" ]
  check "re-run: signed in as kaichen" out_has "Signed in as kaichen"
  teardown
}

test_python3_dns_fallback() {
  echo "• no dig on the box (macOS 15+): verifies through the python3 fallback"
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/nodig" dig
  run_deploy_path "$SANDBOX/nodig"
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "named the fallback tool"    out_has "DNS query via python3"
  check "  never called dig"         no_call "^dig "
  check "still resolved a real name" out_has "DNS is really resolving"
  check "  through the tailnet IP"   calls_have "^python3 - $FAKE_TS_IP example.com"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=3080 http://127.0.0.1:3080"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the
  # second lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=3080 http://127.0.0.1:3080"
  teardown
}

# ------------------------------------------------- sandbox integrity proof
# Recorded before the mocked suite runs, checked after it. A mocked suite that
# quietly wrote to ~/services/adguard or to the repo's real .env would be
# worse than no suite, and on THIS service a stray run against the host could
# take the box's DNS with it.
HOST_SNAPSHOT=""
snapshot_host() {
  local f
  HOST_SNAPSHOT=""
  for f in "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" \
           "$SERVICE_DIR/SETUP.md" "$SERVICE_DIR/TROUBLESHOOT.md" \
           "$SERVICE_DIR/.env" "$ORIG_HOME/services/adguard" \
           /etc/resolv.conf /etc/systemd/resolved.conf; do
    if [ -f "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f $(cksum < "$f" 2>/dev/null || echo unreadable)"
    elif [ -d "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f dir $(ls -A "$f" 2>/dev/null | sort | cksum)"
    else
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f absent"
    fi
  done
}

test_sandbox_was_hermetic() {
  echo "• the mocked suite changed nothing on this host"
  local before="$HOST_SNAPSHOT"
  snapshot_host
  check "HOME restored"                    [ "$HOME" = "$ORIG_HOME" ]
  check "repo files + host DNS config + ~/services/adguard unchanged" \
    [ "$before" = "$HOST_SNAPSHOT" ]
  if [ "$before" != "$HOST_SNAPSHOT" ]; then
    red "      before:$before"
    red "      after: $HOST_SNAPSHOT"
  fi
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
# (3080 -> 3080), so tailscaled legitimately listens on the tailnet IP for
# that port. The other services here differ (e.g. seafile 8443 -> 8081) and never
# hit that overlap, which is why their simpler "anything not 127.0.0.1"
# check works for them and would false-positive here.
#
# On THIS service the Tailscale allowance is load-bearing rather than
# incidental: the DNS listener is deliberately published on the tailnet
# address (Serve cannot carry UDP), so it is not loopback and never will be.
# See SETUP.md -> "The loopback rule, and why :53 is an exception". The
# function body below is byte-identical to immich's, vaultwarden's and
# jellyfin's on purpose — it is the canonical implementation.
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

# The DNS port needs its own version: UDP counts (the canonical helper above
# is TCP-only, which is correct for every HTTP service in this repo and would
# miss the half of :53 that carries ordinary queries), and systemd-resolved's
# 127.0.0.53%lo / 127.0.0.54 stubs share the port number and are legitimately
# there — this deploy leaves resolved completely alone on purpose.
dns_listeners_ok() {  # -> 1 if anything but loopback / the tailnet address
  local addrs addr host ts ts4 ts6
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  ts4="$("$ts" ip -4 2>/dev/null || true)"
  ts6="$("$ts" ip -6 2>/dev/null || true)"
  if command -v ss >/dev/null; then
    addrs="$( { ss -ltnH 'sport = :53' 2>/dev/null; ss -lunH 'sport = :53' 2>/dev/null; } | awk '{print $4}')"
  else
    addrs="$( { lsof -nP -iTCP:53 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
                lsof -nP -iUDP:53 2>/dev/null | awk 'NR>1{print $9}'; } )"
  fi
  [ -n "$addrs" ] || return 1          # nothing listening at all is a failure
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
    host="${host%\%*}"                 # drop the %lo on 127.0.0.53%lo
    case "$host" in
      127.*|::1|localhost) continue ;;
    esac
    [ -n "$ts4" ] && [ "$host" = "$ts4" ] && continue
    [ -n "$ts6" ] && [ "$host" = "$ts6" ] && continue
    return 1
  done <<EOF
$addrs
EOF
  return 0
}

# Is the resolver actually answering, as opposed to merely published? dig
# where it exists, the same minimal UDP client setup.sh carries otherwise.
resolves_a_record() {  # resolves_a_record <server> <name>
  local out
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short +time=3 +tries=2 "@$1" "$2" A 2>/dev/null \
           | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')"
  else
    out="$(python3 - "$1" "$2" <<'PY' 2>/dev/null
import random, socket, struct, sys
server, name = sys.argv[1], sys.argv[2]
pkt = struct.pack('>HHHHHH', random.randint(0, 0xFFFF), 0x0100, 1, 0, 0, 0)
for label in name.split('.'):
    pkt += bytes([len(label)]) + label.encode()
pkt += b'\x00' + struct.pack('>HH', 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(4)
try:
    sock.sendto(pkt, (server, 53))
    data, _ = sock.recvfrom(4096)
except Exception:
    sys.exit(1)
i = 12
while data[i]:
    i += data[i] + 1
i += 5
for _ in range(struct.unpack('>H', data[6:8])[0]):
    if data[i] & 0xC0 == 0xC0:
        i += 2
    else:
        while data[i]:
            i += data[i] + 1
        i += 1
    rtype, _rclass, _ttl, rdlen = struct.unpack('>HHIH', data[i:i + 10])
    i += 10
    if rtype == 1 and rdlen == 4:
        print('.'.join(str(b) for b in data[i:i + 4]))
    i += rdlen
PY
)"
  fi
  out="$(printf '%s\n' "$out" | grep -v '^0\.0\.0\.0$' | grep -v '^$')"
  [ -n "$out" ]
}

blocks_a_name() {  # blocks_a_name <server> <name>
  local out
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short +time=3 +tries=2 "@$1" "$2" A 2>/dev/null)"
  else
    out="$(resolves_a_record "$1" "$2" && echo notblocked || echo '0.0.0.0')"
  fi
  case "$out" in *0.0.0.0*) return 0 ;; esac
  # NXDOMAIN / an empty answer is the other shape a block takes.
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  # Without the docker group every `docker inspect` fails and the container
  # checks report "not running" for a perfectly healthy stack. Say so, rather
  # than letting red lines imply an outage. A shell started before the user
  # was added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  if [ ! -f "$SERVICE_DIR/.env" ]; then
    red "    ! no $SERVICE_DIR/.env — this service is not deployed on this box."
    red "      Deploy first: cd $SERVICE_DIR && ./setup.sh"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url dns_ip
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${HTTPS_PORT:-$port}"
  dns_ip="$(sed -n 's/^ADGUARD_DNS_IP=//p' "$SERVICE_DIR/.env" | head -1)"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "adguard container running" \
    sh -c "docker inspect -f '{{.State.Status}}' adguard | grep -qx running"
  live_check "  image is pinned, not :latest" \
    sh -c "docker inspect -f '{{.Config.Image}}' adguard | grep -q 'adguardhome:v[0-9]'"
  # unless-stopped is what makes the dockerd-before-tailscaled reboot race
  # self-heal instead of leaving the tailnet without a resolver.
  live_check "  restart policy is unless-stopped" \
    sh -c "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' adguard | grep -qx unless-stopped"

  # --- web UI ---
  # 401 is the healthy answer: configured and asking for a login. 302 means it
  # is serving the install wizard, which also means DNS is dead.
  live_check "web UI answers on 127.0.0.1:$port (401/200)" \
    sh -c "case \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/control/status')\" in 401|200) exit 0;; *) exit 1;; esac"
  live_check "  NOT sitting on the install wizard" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/control/status')\" != 302 ]"
  live_check "not listening on non-local ifaces (:$port)" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds" \
    sh -c "case \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 '$url:$https_port/control/status')\" in 401|200) exit 0;; *) exit 1;; esac"

  # --- the check nothing else substitutes for ---------------------------
  # A fresh AdGuard publishes :53 while running no DNS server at all, so `ss`
  # says LISTEN and every query is refused. Ask a question instead.
  live_check "DNS resolves a real name through $dns_ip:53" \
    resolves_a_record "$dns_ip" "example.com"
  live_check "  and blocks a known ad domain" \
    blocks_a_name "$dns_ip" "doubleclick.net"

  # --- the DNS listener is exactly where it should be -------------------
  live_check ":53 is on the tailnet address and nowhere public" dns_listeners_ok
  live_check "  :53 is NOT on 0.0.0.0" \
    sh -c "! { ss -ltnH 'sport = :53' 2>/dev/null; ss -lunH 'sport = :53' 2>/dev/null; } | awk '{print \$4}' | grep -q '^0\\.0\\.0\\.0:'"
  live_check "  :53 IS on $dns_ip" \
    sh -c "{ ss -ltnH 'sport = :53' 2>/dev/null; ss -lunH 'sport = :53' 2>/dev/null; } | awk '{print \$4}' | grep -q '^$dns_ip:'"
  live_check "  .env's ADGUARD_DNS_IP is this node's tailnet IP" \
    sh -c "'$ts' ip -4 | grep -qx '$dns_ip'"

  # --- the host's own resolver survived ---------------------------------
  # A deploy that "fixed" the port-53 question by disabling systemd-resolved
  # would break name resolution for every other service on this box. It is
  # unnecessary here (resolved binds only 127.0.0.53/.54) and it is asserted,
  # not assumed.
  if [ "$OS" = "Linux" ]; then
    live_check "systemd-resolved is still active" \
      sh -c "systemctl is-active systemd-resolved | grep -qx active"
  fi
  live_check "the host itself still resolves names" \
    sh -c "getent hosts github.com >/dev/null || host github.com >/dev/null"

  # --- state on disk ----------------------------------------------------
  live_check "conf dir exists" \
    sh -c "test -d \"\$(sed -n 's/^ADGUARD_CONF=//p' '$SERVICE_DIR/.env')\""
  # No sudo: the file is root-owned (the container runs as root) but the
  # directory is ours, and `test -f` only needs the traversal bit. A `sudo`
  # here would block on a password prompt on a box with no cached credentials,
  # which is not something a test suite should ever do.
  live_check "  AdGuardHome.yaml is there (= configured)" \
    sh -c "test -f \"\$(sed -n 's/^ADGUARD_CONF=//p' '$SERVICE_DIR/.env')/AdGuardHome.yaml\""
  live_check "work dir exists" \
    sh -c "test -d \"\$(sed -n 's/^ADGUARD_WORK=//p' '$SERVICE_DIR/.env')\""
  # 0775 makes AdGuard log a permcheck warning on every start.
  live_check "  data dirs are 0700" \
    sh -c "[ \"\$(stat -c '%a' \"\$(sed -n 's/^ADGUARD_WORK=//p' '$SERVICE_DIR/.env')\" 2>/dev/null || stat -f '%Lp' \"\$(sed -n 's/^ADGUARD_WORK=//p' '$SERVICE_DIR/.env')\")\" = 700 ]"

  # --- the manual step, reported rather than asserted -------------------
  # Whether the tailnet points here is a setting in someone's browser, not a
  # fact this box holds, so this is a reminder and not a check.
  printf '    → resolver: %s:53 — this is the value that belongs in\n' "$dns_ip"
  printf '      https://login.tailscale.com/admin/dns under Nameservers.\n'
  printf '      Until it is there, AdGuard is running and filtering nothing.\n'
  printf '    → to back it out: remove the nameserver there FIRST, then stop\n'
  printf '      this container. The other order takes DNS down tailnet-wide.\n'
}

# ------------------------------------------------------------- teardown
# teardown.sh's mocked suite. The reference cases (Serve detection, purge
# guards, .env reading) mirror services/stirling-pdf; the DNS gate cases are
# this service's own: stopping AdGuard while the tailnet still uses it as a
# nameserver takes DNS down for every device, so the gate must refuse on
# every shape of "still listed" and on every way of "could not tell".
run_teardown() {  # run_teardown [flag] [stdin]
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

run_teardown_args() {  # run_teardown_args <stdin> <flag>...
  local input="$1"; shift
  OUT="$(printf '%s\n' "$input" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" "$@" 2>&1)"
  CODE=$?
}

conf_dir() { env_val ADGUARD_CONF; }
work_dir() { env_val ADGUARD_WORK; }

# `tailscale dns status --json` for a logged-in node, with the given extra
# top-level keys (already indented two spaces, comma-separated) after
# CurrentTailnet. Same two-space MarshalIndent shape as the real CLI, which
# always prints all four resolver keys: any the extra keys leave out are
# added as null. dns_json "" leaves them all out (a truncated or renamed
# shape).
dns_json() {
  local extra="${1:-}" k
  if [ -n "$extra" ]; then
    for k in Resolvers SplitDNSRoutes FallbackResolvers Nameservers; do
      case "$extra" in *"
  \"$k\":"*|"  \"$k\":"*) ;; *) extra="$extra,
  \"$k\": null" ;; esac
    done
  fi
  {
    echo '{'
    echo '  "TailscaleDNS": true,'
    echo '  "CurrentTailnet": {'
    echo '    "MagicDNSEnabled": true,'
    echo '    "MagicDNSSuffix": "tailfake.ts.net",'
    echo '    "SelfDNSName": "test-host.tailfake.ts.net."'
    if [ -n "$extra" ]; then
      echo '  },'
      printf '%s\n' "$extra"
    else
      echo '  }'
    fi
    echo '}'
  } > "$STATE_DIR/dns_status"
}

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# neighbours sit on other ports (one a lookalike suffix), the tailnet lists
# only Quad9 as its resolver, and the container has written config + logs.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  [ "$CODE" -eq 0 ] || red "      (deployed: setup.sh failed: $(tail -3 <<<"$OUT"))"
  echo "schema_version: 34" > "$(conf_dir)/AdGuardHome.yaml"
  mkdir -p "$(work_dir)/data"
  echo '{}' > "$(work_dir)/data/querylog.json"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3000 (tailnet only)
|-- / proxy http://127.0.0.1:3000

https://test-host.tailfake.ts.net:3080 (tailnet only)
|-- / proxy http://127.0.0.1:3080

https://test-host.tailfake.ts.net:13080 (tailnet only)
|-- / proxy http://127.0.0.1:13080
EOF
  dns_json '  "Resolvers": [
    {
      "Addr": "https://dns10.quad9.net/dns-query"
    }
  ],
  "SystemDNS": {
    "Nameservers": [
      "100.100.100.100"
    ]
  }'
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down" "$STATE_DIR/compose_cmds"
}

nothing_changed() {  # nothing_changed <label>
  check "$1: exits non-zero"           [ "$CODE" -ne 0 ]
  check "$1: nothing unpublished"      no_call " off"
  check "$1: container not stopped"    [ ! -f "$STATE_DIR/compose_down" ]
  check "$1: config kept"              [ -f "$(conf_dir)/AdGuardHome.yaml" ]
  check "$1: .env kept"                [ -f "$SVC/.env" ]
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps config and .env, unpublishes only its port"
  deployed
  OUT="$(PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" </dev/null 2>&1)"; CODE=$?
  check "launcher-shaped run (no args, no stdin) exits zero" [ "$CODE" -eq 0 ]
  check "read the tailnet DNS config"  calls_have "^tailscale dns status --json"
  check "warns about the admin console first" out_has "login.tailscale.com/admin/dns"
  check "says it is not a nameserver"  out_has "Not a tailnet nameserver"
  check "serve off for :3080"         calls_have "tailscale serve --https=3080 off"
  check "neighbour :3000 untouched"   no_call "https=3000 "
  check "lookalike :13080 untouched"  no_call "https=13080"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  in the service directory"  grep -q -- "compose --project-directory $SVC down" "$STATE_DIR/compose_cmds"
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no cleanup container"        [ ! -f "$STATE_DIR/cleanup_ran" ]
  check "conf kept"                   [ -f "$(conf_dir)/AdGuardHome.yaml" ]
  check "work kept"                   [ -f "$(work_dir)/data/querylog.json" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  check "names the unpaused DNS monitor" out_has "adguard-dns"
  check "no systemctl / launchctl"    no_call "^systemctl\|^launchctl"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_https_port_override() {
  echo "• teardown: an HTTPS port other than LOCAL_PORT is found from Serve"
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=9443
  run_deploy
  unset HTTPS_PORT
  printf 'https://test-host.tailfake.ts.net:9443 (tailnet only)\n|-- / proxy http://127.0.0.1:3080\n' \
    > "$STATE_DIR/serve_status"
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :9443"         calls_have "tailscale serve --https=9443 off"
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
  printf 'https://test-host.tailfake.ts.net:3080 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:3081 (tailnet only)
|-- / proxy http://127.0.0.1:3080

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:3080

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /adguard proxy http://127.0.0.1:3080
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":3081 off"                   calls_have "serve --https=3081 off"
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
  check "says why"                    out_has "Could not read Tailscale Serve status"
  nothing_changed "serve status down"
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
  run_teardown_args "" --dns-removed --dns-removed
  check "flag given twice: exits non-zero" [ "$CODE" -ne 0 ]
  check "flag given twice: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "no docker: nothing unpublished" no_call " off"
  teardown
}

# ---- the DNS gate ----------------------------------------------------
test_teardown_dns_gate_listed() {
  echo "• teardown: refuses while the tailnet still lists this node as a resolver"
  local shape json
  for shape in Resolvers FallbackResolvers SplitDNSRoutes Nameservers port doh v6 bootstrap; do
    deployed
    case "$shape" in
      Resolvers|FallbackResolvers)
        json="  \"$shape\": [
    {
      \"Addr\": \"https://dns10.quad9.net/dns-query\"
    },
    {
      \"Addr\": \"$FAKE_TS_IP\"
    }
  ]" ;;
      SplitDNSRoutes)
        json='  "SplitDNSRoutes": {
    "lan.example": [
      {
        "Addr": "'"$FAKE_TS_IP"'"
      }
    ]
  }' ;;
      Nameservers)
        json='  "Nameservers": [
    "'"$FAKE_TS_IP"'"
  ]' ;;
      port)
        json='  "Resolvers": [
    {
      "Addr": "'"$FAKE_TS_IP"':53"
    }
  ]' ;;
      doh)
        json='  "FallbackResolvers": [
    {
      "Addr": "https://'"$FAKE_TS_IP"'/dns-query"
    }
  ]' ;;
      v6)
        json='  "Resolvers": [
    {
      "Addr": "FD7A:115C:A1E0::1111:2222"
    }
  ]' ;;
      bootstrap)
        json='  "Resolvers": [
    {
      "Addr": "https://adguard.example/dns-query",
      "BootstrapResolution": [
        "'"$FAKE_TS_IP"'"
      ]
    }
  ]' ;;
    esac
    dns_json "$json"
    run_teardown
    nothing_changed "$shape"
    check "$shape: says the tailnet still uses it" out_has "still uses $FAKE_TS_IP for DNS"
    check "$shape: points at the admin console" out_has "login.tailscale.com/admin/dns"
    teardown
  done

  deployed
  dns_json '  "Resolvers": [
    {
      "Addr": "'"$FAKE_TS_IP"'"
    }
  ]'
  run_teardown --dns-removed
  nothing_changed "listed + --dns-removed"
  check "  says the flag does not override it" out_has "does not override"
  run_teardown --purge "adguard"
  nothing_changed "listed + --purge"
  check "  never got to the purge prompt" out_lacks "Type adguard to confirm"
  check "  work kept"                 [ -f "$(work_dir)/data/querylog.json" ]
  teardown
}

test_teardown_dns_gate_address_moved() {
  echo "• teardown: checks both the .env address and the node's current one"
  deployed
  echo 100.77.77.78 > "$STATE_DIR/ts_ip"
  dns_json '  "Resolvers": [
    {
      "Addr": "100.77.77.78"
    }
  ]'
  run_teardown
  nothing_changed "current address listed"
  teardown
  deployed
  echo 100.77.77.78 > "$STATE_DIR/ts_ip"
  dns_json '  "Resolvers": [
    {
      "Addr": "'"$FAKE_TS_IP"'"
    }
  ]'
  run_teardown
  nothing_changed ".env address listed"
  teardown
}

test_teardown_dns_gate_clear() {
  echo "• teardown: lookalike addresses and non-resolver fields do not block"
  deployed
  dns_json '  "Resolvers": [
    {
      "Addr": "100.77.77.7"
    },
    {
      "Addr": "100.77.77.770"
    },
    {
      "Addr": "1100.77.77.77"
    },
    {
      "Addr": "100.77.77.77.example"
    }
  ],
  "SearchDomains": [
    "tailfake.ts.net"
  ],
  "ExtraRecords": [
    {
      "Name": "adguard.tailfake.ts.net.",
      "Value": "'"$FAKE_TS_IP"'"
    }
  ],
  "SystemDNS": {
    "Nameservers": [
      "'"$FAKE_TS_IP"'"
    ]
  }'
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  rm -f "$STATE_DIR/dns_status"        # logged in, no resolvers at all
  run_teardown
  check "no resolvers configured: exits zero" [ "$CODE" -eq 0 ]
  teardown
  # The shape a real node printed (on one line here: a parser, not an
  # indent match), with other addresses in every slot.
  deployed
  printf '{"TailscaleDNS":true,"CurrentTailnet":{"MagicDNSEnabled":true,"MagicDNSSuffix":"tailfake.ts.net","SelfDNSName":"test-host.tailfake.ts.net."},"Resolvers":[{"Addr":"1.1.1.1"},{"Addr":"9.9.9.9"}],"FallbackResolvers":null,"SplitDNSRoutes":{"ts.net.":[{"Addr":"199.247.155.53"}],"empty.example.":null},"Nameservers":["8.8.8.8"],"CertDomains":null,"SearchDomains":["tailfake.ts.net"]}\n' > "$STATE_DIR/dns_status"
  run_teardown
  check "real-box shape, compact: exits zero" [ "$CODE" -eq 0 ]
  check "  compose down"              [ -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf '{"TailscaleDNS":true,"CurrentTailnet":{"MagicDNSSuffix":"tailfake.ts.net"},"Resolvers":[{"Addr":"1.1.1.1"},{"Addr":"%s"}],"FallbackResolvers":null,"SplitDNSRoutes":null,"Nameservers":null}\n' "$FAKE_TS_IP" > "$STATE_DIR/dns_status"
  run_teardown
  nothing_changed "real-box shape, compact, listed"
  check "  says the tailnet still uses it" out_has "still uses $FAKE_TS_IP for DNS"
  teardown
  # Verbatim from kai-home-server (tailscale 1.10x, 2026-10-25), addresses
  # swapped: the CLI omits empty resolver keys (no FallbackResolvers, no
  # Nameservers here) and adds fields of its own. Omitted means none.
  deployed
  cat > "$STATE_DIR/dns_status" <<'EOF_REAL'
{
  "TailscaleDNS": true,
  "CurrentTailnet": {
    "MagicDNSEnabled": true,
    "MagicDNSSuffix": "tailfake.ts.net",
    "SelfDNSName": "test-host.tailfake.ts.net."
  },
  "Resolvers": [
    {
      "Addr": "1.1.1.1"
    },
    {
      "Addr": "2606:4700:4700::1111"
    }
  ],
  "SplitDNSRoutes": {
    "ts.net.": [
      {
        "Addr": "199.247.155.53"
      }
    ]
  },
  "SearchDomains": [
    "tailfake.ts.net"
  ],
  "CertDomains": [
    "test-host.tailfake.ts.net"
  ],
  "ExitNodeFilteredSet": [
    ".ts.net",
    ".tailscale.net"
  ],
  "SystemDNSError": "not supported on this platform"
}
EOF_REAL
  run_teardown
  check "real CLI output, keys omitted: exits zero" [ "$CODE" -eq 0 ]
  check "  says it is not a nameserver" out_has "Not a tailnet nameserver"
  check "  compose down"              [ -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf '{"TailscaleDNS":true,"CurrentTailnet":{"MagicDNSSuffix":"tailfake.ts.net"},"SplitDNSRoutes":{"corp.example.":[{"Addr":"%s"}]},"SystemDNSError":"not supported on this platform"}\n' "$FAKE_TS_IP" > "$STATE_DIR/dns_status"
  run_teardown
  nothing_changed "real CLI output, keys omitted, listed in split DNS"
  check "  says the tailnet still uses it" out_has "still uses $FAKE_TS_IP for DNS"
  teardown
}

test_teardown_dns_gate_unknown() {
  echo "• teardown: an unreadable DNS config stops, unless --dns-removed"
  local shape
  # Every shape below has the right key names but not the right types, or
  # is not quite JSON: none of them may read as "not listed".
  local all_null='"Resolvers": null, "SplitDNSRoutes": null, "FallbackResolvers": null, "Nameservers": null'
  local tailnet='"TailscaleDNS": true, "CurrentTailnet": {"MagicDNSSuffix": "tailfake.ts.net"}'
  for shape in fails logged-out text truncated no-ip \
      tailnet-null tailnet-string no-tailscaledns keys-missing \
      resolvers-string resolvers-of-strings resolver-no-addr resolver-addr-number \
      fallback-object split-array split-route-string split-route-of-strings \
      nameservers-objects nameservers-string duplicate-key escaped-addr \
      trailing-garbage two-objects bad-literal; do
    deployed
    case "$shape" in
      fails)      touch "$STATE_DIR/dns_status_fails" ;;
      logged-out) printf '{\n  "TailscaleDNS": true\n}\n' > "$STATE_DIR/dns_status" ;;
      text)       printf '\n=== MagicDNS configuration ===\n\nResolvers (in preference order):\n  - 9.9.9.9\n' > "$STATE_DIR/dns_status" ;;
      truncated)  dns_json ""; sed -i.bak '$d' "$STATE_DIR/dns_status" ;;
      no-ip)      sed -i.bak '/^ADGUARD_DNS_IP=/d' "$SVC/.env" ;;
      tailnet-null)
        printf '{"TailscaleDNS": true, "CurrentTailnet": null, "Resolvers": "unavailable", "SplitDNSRoutes": null, "FallbackResolvers": "unavailable", "Nameservers": null}\n' > "$STATE_DIR/dns_status" ;;
      tailnet-string)
        printf '{"TailscaleDNS": true, "CurrentTailnet": "tailfake.ts.net", %s}\n' "$all_null" > "$STATE_DIR/dns_status" ;;
      no-tailscaledns)
        printf '{"CurrentTailnet": {"MagicDNSSuffix": "tailfake.ts.net"}, %s}\n' "$all_null" > "$STATE_DIR/dns_status" ;;
      keys-missing)
        # All four resolver keys absent: a renamed field must not read as clear.
        printf '{%s, "SearchDomains": ["tailfake.ts.net"]}\n' "$tailnet" > "$STATE_DIR/dns_status" ;;
      resolvers-string)     dns_json '  "Resolvers": "unavailable"' ;;
      resolvers-of-strings) dns_json '  "Resolvers": ["9.9.9.9"]' ;;
      resolver-no-addr)     dns_json '  "Resolvers": [{"Address": "9.9.9.9"}]' ;;
      resolver-addr-number) dns_json '  "Resolvers": [{"Addr": 9}]' ;;
      fallback-object)      dns_json '  "FallbackResolvers": {"Addr": "9.9.9.9"}' ;;
      split-array)          dns_json '  "SplitDNSRoutes": [{"Addr": "9.9.9.9"}]' ;;
      split-route-string)   dns_json '  "SplitDNSRoutes": {"lan.example.": "9.9.9.9"}' ;;
      split-route-of-strings) dns_json '  "SplitDNSRoutes": {"lan.example.": ["9.9.9.9"]}' ;;
      nameservers-objects)  dns_json '  "Nameservers": [{"Addr": "9.9.9.9"}]' ;;
      nameservers-string)   dns_json '  "Nameservers": "9.9.9.9"' ;;
      duplicate-key)
        printf '{%s, %s, "Resolvers": [{"Addr": "%s"}]}\n' "$tailnet" "$all_null" "$FAKE_TS_IP" > "$STATE_DIR/dns_status" ;;
      escaped-addr)
        # \u0031 is "1": decoded, this is the node's own address.
        dns_json '  "Resolvers": [{"Addr": "\u0031'"${FAKE_TS_IP#1}"'"}]' ;;
      trailing-garbage)     dns_json '  "Resolvers": null'; echo 'x' >> "$STATE_DIR/dns_status" ;;
      two-objects)          dns_json '  "Resolvers": null'; echo '{}' >> "$STATE_DIR/dns_status" ;;
      bad-literal)          dns_json '  "Resolvers": nul' ;;
    esac
    run_teardown
    nothing_changed "$shape"
    check "$shape: says it could not tell" out_has "Could not tell whether"
    check "$shape: names the override"  out_has "teardown.sh --dns-removed"
    teardown
  done

  deployed
  touch "$STATE_DIR/dns_status_fails"
  run_teardown --dns-removed
  check "--dns-removed: exits zero"   [ "$CODE" -eq 0 ]
  check "  says it went ahead on the flag" out_has "going ahead on your --dns-removed"
  check "  serve off"                 calls_have "serve --https=3080 off"
  check "  compose down"              [ -f "$STATE_DIR/compose_down" ]
  teardown

  deployed
  touch "$STATE_DIR/dns_status_fails"
  run_teardown --purge "adguard"
  nothing_changed "unknown + --purge"
  check "  suggests the purge retry"  out_has "--dns-removed --purge"
  run_teardown_args "adguard" --purge --dns-removed
  check "--purge --dns-removed: exits zero" [ "$CODE" -eq 0 ]
  check "  conf gone"                 [ ! -e "$HOME/services/adguard/conf" ]
  teardown
}

test_teardown_foreign_units_left_alone() {
  echo "• teardown: units setup.sh did not create are named, never touched"
  deployed
  local ud="$HOME/.config/systemd/user"
  mkdir -p "$ud/default.target.wants"
  printf '[Service]\nExecStart=/bin/true\n' > "$ud/adguard-backup.service"
  printf '[Service]\nExecStart=/usr/bin/tar czf /tmp/x -C /home/x/services/AdGuard .\n' > "$ud/nightly-tar.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$ud/unrelated.service"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "names the unit by file name" out_has "adguard-backup.service"
  check "names the unit by content"   out_has "nightly-tar.service"
  check "does not name the unrelated one" out_lacks "unrelated.service"
  check "units kept"                  [ -f "$ud/adguard-backup.service" ] && [ -f "$ud/nightly-tar.service" ]
  check "no systemctl"                no_call "^systemctl"
  teardown
}

# ---- purge -----------------------------------------------------------
test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then conf/, work/, .env and the marker go"
  deployed
  local conf work; conf="$(conf_dir)"; work="$(work_dir)"
  echo keep > "$HOME/services/neighbour-file"
  run_teardown --purge "adguar"
  nothing_changed "wrong name"
  check "wrong name: work kept"       [ -f "$work/data/querylog.json" ]
  run_teardown --purge "adguard"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "offers the backup before the prompt" out_has "sudo cp $conf/AdGuardHome.yaml"
  check "conf gone"                   [ ! -e "$conf" ]
  check "work gone"                   [ ! -e "$work" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker ~/services/adguard gone" [ ! -e "$HOME/services/adguard" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "  and its other contents"    [ -f "$HOME/services/neighbour-file" ]
  check "serve off for :3080"         calls_have "tailscale serve --https=3080 off"
  check "down without -v"             no_call "down -v"
  check "docker-compose.yml kept"     [ -f "$SVC/docker-compose.yml" ]
  teardown
}

test_teardown_purge_root_owned() {
  echo "• teardown --purge: root-owned files are cleared with the pinned image"
  deployed
  local conf; conf="$(conf_dir)"
  mkdir -p "$conf/locked"; echo x > "$conf/locked/file"; chmod 500 "$conf/locked"
  run_teardown --purge "adguard"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the cleanup container"  calls_have "^docker run --rm --pull never -v $conf:/x --entrypoint sh adguard/adguardhome:v0.107.79 -c find /x -mindepth 1 -delete"
  check "conf gone"                   [ ! -e "$conf" ]
  check "marker gone"                 [ ! -e "$HOME/services/adguard" ]
  teardown
  deployed
  conf="$(conf_dir)"
  mkdir -p "$conf/locked"; echo x > "$conf/locked/file"; chmod 500 "$conf/locked"
  touch "$STATE_DIR/cleanup_fails"
  run_teardown --purge "adguard"
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names sudo rm -rf"         out_hasF "sudo rm -rf $conf"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a conf/work dir outside ~/services/adguard"
  deployed
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./adguard" "$HOME/services/adguard/.."; do
    sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$dotted#" "$SVC/.env"
    run_teardown --purge "adguard"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/adguard/conf#" "$SVC/.env"
  sed -i.bak "s#^ADGUARD_WORK=.*#ADGUARD_WORK=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "ADGUARD_WORK checked too"    [ "$CODE" -ne 0 ]
  check "  conf kept (refused before deleting anything)" [ -f "$HOME/services/adguard/conf/AdGuardHome.yaml" ]
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "adguard"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/adguard/alias"
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/adguard/alias#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/adguard/conf///#" "$SVC/.env"
  rm -f "$HOME/services/adguard/alias"
  run_teardown --purge "adguard"
  check "trailing slashes on its own dir: exits zero" [ "$CODE" -eq 0 ]
  check "  conf gone"                 [ ! -e "$HOME/services/adguard/conf" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: data already gone is fine, and the marker still goes"
  deployed
  rm -rf "$(conf_dir)" "$(work_dir)"
  run_teardown --purge "adguard"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker gone"                 [ ! -e "$HOME/services/adguard" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(conf_dir)"
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(conf_dir)"
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/adguard itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "adguard"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^ADGUARD_CONF=.*#ADGUARD_CONF=$HOME/services/adguard/a:b#" "$SVC/.env"
  mkdir -p "$HOME/services/adguard/a:b"
  run_teardown --purge "adguard"
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
  mkdir -p "$HOME/adguard/conf"; echo x > "$HOME/adguard/conf/keep"
  run_teardown --purge "adguard"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/adguard/conf/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/adguard survives"
  deployed
  local repo="$HOME/services/adguard/conf/setup-server/services/adguard"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/adguard/conf/setup-server/other.env"
  OUT="$(printf '%s\n' "adguard" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$HOME/services/adguard/conf/setup-server/other.env" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='3080'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":3080 off"                   calls_have "serve --https=3080 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="3080"/' -e "s/^ADGUARD_DNS_IP=.*/ADGUARD_DNS_IP=\"$FAKE_TS_IP\"  # resolver/" "$SVC/.env"
  dns_json '  "Resolvers": [
    {
      "Addr": "'"$FAKE_TS_IP"'"
    }
  ]'
  run_teardown
  check "double-quoted DNS IP still gates" [ "$CODE" -ne 0 ]
  check "  named the address"         out_has "still uses $FAKE_TS_IP for DNS"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=3080 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'ADGUARD_CONF=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "ADGUARD_CONF is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nADGUARD_CONF=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "adguard"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  teardown
}

# ---- --check-dns: the launcher's and ntfy-control's stop guard -----------
# Read-only: the preflight and the DNS gate, nothing else. Docker is only
# asked whether it answers; Serve is never read or changed.
check_dns_read_only() {  # check_dns_read_only <label>
  check "$1: no docker call past the preflight" \
    [ -z "$(grep '^docker ' "$CALLS_LOG" | grep -v '^docker ps$' | grep -v '^docker compose version$' || true)" ]
  check "$1: no serve call at all"     no_call "^tailscale serve"
  check "$1: container not stopped"    [ ! -f "$STATE_DIR/compose_down" ]
  check "$1: config kept"              [ -f "$(conf_dir)/AdGuardHome.yaml" ]
  check "$1: .env kept"                [ -f "$SVC/.env" ]
}

test_teardown_check_dns() {
  echo "• teardown --check-dns: clear, listed and unreadable, changing nothing"
  deployed
  run_teardown --check-dns
  check "clear: exits zero"            [ "$CODE" -eq 0 ]
  check "clear: read the tailnet DNS config" calls_have "^tailscale dns status --json"
  check "clear: says the check passed" out_has "DNS check passed"
  check "clear: no Done banner"        out_lacks "is removed"
  check_dns_read_only "clear"
  teardown

  deployed
  dns_json '  "Nameservers": [
    "'"$FAKE_TS_IP"'"
  ]'
  run_teardown --check-dns
  check "listed: exits non-zero"       [ "$CODE" -ne 0 ]
  check "listed: same message as teardown" out_has "The tailnet still uses $FAKE_TS_IP for DNS"
  check "listed: names the key"        out_has "lists it under: Nameservers"
  check "listed: no --dns-removed talk" out_lacks "dns-removed"
  check "listed: last line is the reason" grep -q "Nothing was changed" <<<"$(tail -1 <<<"$OUT")"
  check_dns_read_only "listed"
  teardown

  deployed
  touch "$STATE_DIR/dns_status_fails"
  run_teardown --check-dns
  check "unreadable: exits non-zero"   [ "$CODE" -ne 0 ]
  check "unreadable: says it could not tell" out_has "Could not tell whether"
  check "unreadable: points at a terminal stop" out_has "docker stop adguard"
  check "unreadable: no --dns-removed advice" out_lacks "dns-removed"
  check_dns_read_only "unreadable"
  teardown

  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown --check-dns
  check "Serve unreadable: still answers the DNS question" [ "$CODE" -eq 0 ]
  check_dns_read_only "Serve unreadable"
  teardown

  deployed
  local combo
  for combo in "--check-dns --dns-removed" "--dns-removed --check-dns" "--check-dns --purge" "--check-dns --check-dns"; do
    # shellcheck disable=SC2086
    run_teardown_args "adguard" $combo
    check "$combo: refused"            [ "$CODE" -ne 0 ]
    check "$combo: says it stands alone" out_has "takes no other option"
    check "$combo: DNS never read"     no_call "^tailscale dns"
  done
  check_dns_read_only "flag combos"
  teardown

  setup
  run_teardown --check-dns
  check "no .env: exits non-zero"      [ "$CODE" -ne 0 ]
  check "no .env: explains"            out_has "nothing to tear down"
  teardown
}

test_teardown_no_empty_array_length() {
  echo "• teardown.sh: no \${#arr[@]} on a maybe-empty array — Bash 3.2 + set -u errors there"
  # macOS ships Bash 3.2, where taking the length of an empty array is an
  # unbound-variable error under set -u, not 0. The guarded ${arr[*]+...}
  # form expands to nothing instead, so the branch is simply false.
  check "no array-length expansion" teardown_lacks '\${#[A-Za-z_]+\[@\]}'
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/adguard/setup.sh or services/adguard/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
snapshot_host
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_no_tailnet_ip
test_preflight_no_dns_tool
test_fresh_deploy
test_readiness_race
test_never_ready
test_install_wrong_web_block
test_install_race_403_is_success
test_install_other_error
test_idempotent_rerun
test_config_wiped_reinstalls
test_up_fails_bind
test_up_fails_port_in_use
test_dns_ip_drift
test_dns_never_resolves
test_filter_lists_lag
test_password_drift
test_dns_reports_not_running
test_wildcard_dns_listener
test_lan_dns_listener
test_lan_web_listener
test_resolved_stubs_are_not_a_failure
test_listener_audit_without_ss
test_container_not_running
test_restart_count_is_not_a_fault
test_https_front_door_slow
test_ratelimit_option
test_ratelimit_failure_is_soft
test_port_override
test_https_port_follows_local_port
test_admin_username_override
test_python3_dns_fallback
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_https_port_override
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_dns_gate_listed
test_teardown_dns_gate_address_moved
test_teardown_dns_gate_clear
test_teardown_dns_gate_unknown
test_teardown_check_dns
test_teardown_foreign_units_left_alone
test_teardown_purge
test_teardown_purge_root_owned
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_home_variable_in_env
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_quoted_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_no_empty_array_length
test_sandbox_was_hermetic

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
