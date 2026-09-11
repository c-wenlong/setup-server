#!/usr/bin/env bash
#
# Tests for adguard/setup.sh.
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
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
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
# that port. The other services here differ (e.g. 10000 -> 3001) and never
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

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "adguard/setup.sh or adguard/docker-compose.yml is missing — nothing to test."
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
test_admin_username_override
test_python3_dns_fallback
test_operator_escalation
test_serve_approval_prompt
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
