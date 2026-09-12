#!/usr/bin/env bash
#
# Tests for homepage/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with PATH stubs for docker/tailscale/curl/ss/lsof/sudo/id/sleep.
#
# What makes this service's suite different from the others here.
#
# 1. A 200 PROVES NOTHING, AND NEITHER DOES THE MARKUP. Homepage v1.4.5 runs a
#    Next.js middleware whose matcher is `/api/:path*`. It compares the Host
#    header against HOMEPAGE_ALLOWED_HOSTS and answers 400 to anything not on
#    the list — but `/` is outside the matcher, so with a completely wrong
#    allowlist `GET /` still returns 200 and a BYTE-IDENTICAL body (measured:
#    44801 bytes, `cmp` reports no difference). Worse, `/` is a build-time
#    static shell: on a correct install it contains the upstream
#    "My First Service" placeholder and NONE of the real group names. So a
#    status check on `/` passes against a broken dashboard, a markup check on
#    `/` passes against a broken dashboard, and an assertion that `/` contains
#    the real service names would FAIL against a working one.
#
#    The only request that separates the two states is an `/api/*` fetch
#    carrying the real Host header. The curl stub implements the real
#    middleware — exact string match, port included, default allowlist derived
#    from PORT, single "*" disables it — so an allowlist that stops naming the
#    tailnet host cannot go green. That is the single most important thing
#    this suite does.
#
# 2. THE STUBS MODEL A CONTAINER, NOT A CANNED RESPONSE. On `compose up` the
#    docker stub resolves docker-compose.yml against the generated .env
#    exactly as Compose would, and the curl/ss stubs then behave like a
#    container started with that environment. So deleting the allowlist from
#    the compose file, or flipping HOSTNAME to 0.0.0.0, or pointing PORT
#    somewhere else, breaks the run — rather than merely failing a grep that a
#    mutation could satisfy while still shipping a broken deploy.
#
# 3. HOST NETWORKING IS DELIBERATE, AND IT MOVES WHERE THE LOOPBACK RULE
#    LIVES. There is no Docker publish spec here (a bridged Homepage cannot
#    reach a single service on this box — everything binds 127.0.0.1). The only
#    thing keeping the dashboard off the LAN is `HOSTNAME=127.0.0.1`, because
#    the image ships 0.0.0.0 and server.js is `process.env.HOSTNAME ||
#    '0.0.0.0'`. The suite asserts host mode and the loopback bind travel
#    together, the way home-assistant's suite does for its own pairing.
#
# 4. A YAML SYNTAX ERROR IS INVISIBLE OVER HTTP. Homepage answers
#    `GET /api/services` with `[]` and HTTP 200 when services.yaml fails to
#    parse, logging the exception only to config/logs/homepage.log. So "is it
#    200" and "is it valid JSON" both go green on a config it could not read.
#    Every assertion here requires a NON-EMPTY list naming real services.
#
# 5. THE CONFIG IS THE PRODUCT, SO CLOBBERING IT IS THE WORST BUG. These YAML
#    files are meant to be hand-edited. test_config_not_clobbered proves a
#    re-run leaves every one of them byte-identical, and
#    test_seeding_happens_before_container_start proves the ordering that makes
#    it work — Homepage writes its own placeholder for any absent file at
#    startup, and whichever writer goes first wins permanently.
#
# Nothing here touches the host: no ~/services/homepage, no real .env, no
# container started, no port bound, no HTTP request leaves the machine.
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

# What the tailscale stub reports. Deliberately NOT this box's real tailnet
# name: an assertion that passed only because it matched the live tailnet
# would be testing nothing, and the name has to be *resolved* into the
# allowlist rather than assumed. (The stub's tailnet address, 100.77.77.77,
# matters only between the tailscale and ss stubs, which share it via
# $STATE_DIR/ts_ip; no assertion here needs it.)
FAKE_TS_HOST=test-host.tailfake.ts.net

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
  cp -R "$SERVICE_DIR/config" "$SVC/config"
  CFG="$HOME/services/homepage/config"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# A PATH containing ONLY what we hand it — used to prove the branches that turn
# on a command being absent. Appending the stub dir to the real PATH cannot
# express "ss does not exist": /usr/bin/ss would still be found.
minimal_path() {  # minimal_path <dir> [stub-basename-to-omit ...]
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p s base omit skip
  for c in bash sh env uname mktemp rm cat head cut sed awk grep tr chmod \
           mkdir rmdir df cp mv ln ls stat od readlink dirname basename seq \
           touch sort wc test printf; do
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

# Every "    - Name:" line must be followed by a "        - " list item, never a
# bare "        key:" mapping -- see the bookmarks check for why.
bookmarks_well_formed() {
  awk '/^    - .+:[[:space:]]*$/{want=1;next} want&&/^        - /{want=0;next} want&&/^        [^ -]/{bad=1} END{exit bad}' "$1"
}

out_has()    { grep -q -- "$1" <<<"$OUT"; }
out_hasF()   { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
out_lacksF() { ! grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }
file_has()   { grep -q -- "$2" "$1"; }
file_lacks() { ! grep -q -- "$2" "$1"; }

# What the container was actually started with, as resolved from
# docker-compose.yml + .env by the docker stub. This is the assertion surface
# that a compose-file mutation cannot dodge.
cenv()     { sed -n "s/^$1=//p" "$STATE_DIR/container_env" 2>/dev/null | head -1; }
cenv_is()  { [ "$(cenv "$1")" = "$2" ]; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# In-place edit that works on GNU and BSD sed alike. Sandbox files only.
subst() {  # subst <file> <sed-expression>
  sed "$2" "$1" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# Static assertions on docker-compose.yml, comments stripped. That file
# documents at length what it deliberately does NOT do — the whole argument
# against mounting the Docker socket sits in a comment, complete with the
# mount line itself — so a naive grep would match the prose and conclude the
# exact opposite of the truth.
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
  check "seeded no config"     [ ! -d "$CFG" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when the user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests usermod fix"  out_has "usermod -aG docker"
    check "  mentions sg docker"  out_has "sg docker"
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
  export LOCAL_PORT=81o0
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_no_magicdns() {
  echo "• preflight fails when MagicDNS gives no tailnet name"
  # Not cosmetic on this service, and that is the point of the message. The
  # MagicDNS name is what goes into HOMEPAGE_ALLOWED_HOSTS; without it the
  # deploy would come up and answer 200 on / while every tailnet API call
  # returned 400 — i.e. it would look successful and be useless.
  setup
  touch "$STATE_DIR/no_dnsname"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names MagicDNS"            out_has "MagicDNS"
  check "  says why it matters"     out_has "HOMEPAGE_ALLOWED_HOSTS"
  check "  predicts the 400"        out_has "400"
  check "wrote no .env"             [ ! -f "$SVC/.env" ]
  check "started no container"      [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_no_templates() {
  echo "• preflight fails when the shipped config templates are missing"
  # Without them the container would start and Homepage would seed its own
  # "My First Service" placeholder, which then wins forever: both writers skip
  # files that already exist, so a later repair does nothing.
  setup
  rm -rf "$SVC/config"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the directory"   out_hasF "$SVC/config"
  check "  says it ships here"  out_has "ships with the repo"
  check "started no container"  [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: seeded, published, and verified through the tailnet Host"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]

  # --- the tailnet name is RESOLVED, never assumed ------------------------
  check "asked tailscale for its name"   calls_have "^tailscale status --json"
  check ".env names no literal from this box" file_lacks "$SVC/.env" 'kai-home-server'

  # --- .env
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               [ "$(file_mode "$SVC/.env")" = "600" ]
  check "pinned to v1.4.5, not latest"   grep -qx 'HOMEPAGE_VERSION=v1.4.5' "$SVC/.env"
  check ".env records the local port"    grep -qx 'LOCAL_PORT=8100' "$SVC/.env"
  check ".env never names 8098"          [ -z "$(sed -n '/^#/d;/8098/p' "$SVC/.env")" ]
  check ".env has HOMEPAGE_CONFIG"       grep -qE '^HOMEPAGE_CONFIG=/.+' "$SVC/.env"
  check ".env has a uid and gid"         grep -qE '^HOMEPAGE_UID=[0-9]+' "$SVC/.env"
  check "  and a gid"                    grep -qE '^HOMEPAGE_GID=[0-9]+' "$SVC/.env"
  check ".env caps memory"               grep -qx 'HOMEPAGE_MEM_LIMIT=512m' "$SVC/.env"

  # --- the allowlist: four entries, each earning its place ---------------
  # The tailnet name WITH the Serve port is what a browser sends. The bare
  # name covers a future move to :443, where the Host carries no port. The two
  # loopback forms are what setup.sh, Kuma and the launcher use.
  allowed="$(env_val HOMEPAGE_ALLOWED_HOSTS)"
  check "allowlist names <host>:<https-port>" \
    grep -qF "$FAKE_TS_HOST:8100" <<<"$allowed"
  check "  and the bare host (for :443)" \
    grep -qE "(^|,)$FAKE_TS_HOST(,|$)" <<<"$allowed"
  check "  and 127.0.0.1:8100"           grep -qF "127.0.0.1:8100" <<<"$allowed"
  check "  and localhost:8100"           grep -qF "localhost:8100" <<<"$allowed"
  # A single "*" turns host validation off entirely. It makes every symptom
  # vanish and leaves the API open to a DNS-rebinding page in the browser.
  check "  and is NOT the wildcard"      [ "$allowed" != "*" ]
  check "  no wildcard entry at all"     [ -z "$(tr ',' '\n' <<<"$allowed" | grep -x '\*')" ]

  # --- compose, statically ----------------------------------------------
  check "image pinned from .env"         compose_hasF 'image: ghcr.io/gethomepage/homepage:${HOMEPAGE_VERSION'
  check "  and never :latest"            compose_lacks ':latest'
  check "  nor a floating v1 tag"        compose_lacks 'homepage:v1$'
  check "network_mode: host"             compose_has '^ *network_mode: *host *$'
  check "binds loopback via HOSTNAME"    compose_hasF 'HOSTNAME=127.0.0.1'
  check "  never 0.0.0.0"                compose_lacks '0\.0\.0\.0'
  check "mem_limit present"              compose_has '^ *mem_limit:'
  check "restart: unless-stopped"        compose_has 'restart: *unless-stopped'
  # Not a style point: mounting the socket hands an unauthenticated web app
  # root-equivalent control of this box.
  check "docker.sock NOT mounted"        compose_lacks 'docker\.sock'
  check "caps docker-side logs"          compose_has 'max-size:'

  # --- what the container was ACTUALLY started with ----------------------
  check "container got HOSTNAME=127.0.0.1" cenv_is HOSTNAME 127.0.0.1
  check "container got PORT=8100"          cenv_is PORT 8100
  check "container got the allowlist"      [ "$(cenv HOMEPAGE_ALLOWED_HOSTS)" = "$allowed" ]
  # The id stub reports uid 1000 unless FAKE_UID is set, whatever the real
  # uid is (1001 on a GitHub runner), so compare against the stub's value.
  check "container got PUID=1000"          cenv_is PUID 1000
  check "container got PGID=$(id -g)"      cenv_is PGID "$(id -g)"
  check "config bind is the only mount" \
    [ "$(grep -c . "$STATE_DIR/container_mounts")" -eq 1 ]
  check "  and it is HOMEPAGE_CONFIG"      grep -qx "$(env_val HOMEPAGE_CONFIG)" "$STATE_DIR/container_mounts"

  # --- seeding ------------------------------------------------------------
  check "config dir created"             [ -d "$CFG" ]
  check "seeded services.yaml"           [ -f "$CFG/services.yaml" ]
  check "seeded settings.yaml"           [ -f "$CFG/settings.yaml" ]
  check "seeded widgets.yaml"            [ -f "$CFG/widgets.yaml" ]
  check "seeded bookmarks.yaml"          [ -f "$CFG/bookmarks.yaml" ]
  # Homepage's bookmark format is double-nested: each name maps to a LIST holding
  # one {abbr, href} object. Written as a plain mapping, the loader drops href,
  # the frontend does new URL(undefined), and every bookmark group renders
  # "Something went wrong: Failed to construct URL". That shipped once.
  check "  every bookmark is a single-item list (name: -> '- abbr:')" \
    bookmarks_well_formed "$CFG/bookmarks.yaml"
  check "reported the seeding"           out_has "Seeded 5 config file"
  # The templates are tailnet-agnostic on purpose, so the substitution has to
  # actually happen — an unsubstituted href is a dead tile on every device.
  check "__TS_HOST__ substituted"        [ -z "$(grep -l '__TS_HOST__' "$CFG"/*.yaml 2>/dev/null)" ]
  check "  with the resolved name"       grep -q "$FAKE_TS_HOST" "$CFG/services.yaml"
  check "  and no literal from this box" file_lacks "$CFG/services.yaml" 'kai-home-server'
  check "no config file mentions 8098"   [ -z "$(grep -l '8098' "$CFG"/*.yaml 2>/dev/null)" ]
  # Kai edits these by hand; root-owned config would need sudo for that.
  check "config files are writable by us" [ -w "$CFG/services.yaml" ]

  # --- publish ------------------------------------------------------------
  check "served on tailscale :8100" \
    calls_have "tailscale serve --bg --https=8100 http://127.0.0.1:8100"
  check "no sudo needed (operator set)"  no_call "^sudo "

  # --- VERIFICATION: the part a status code cannot fake -------------------
  check "polled /api/healthcheck"        calls_have "127.0.0.1:8100/api/healthcheck"
  check "  reported it up"               out_has "GET /api/healthcheck -> 200"
  check "checked /api/services on loopback" calls_have "http://127.0.0.1:8100/api/services"
  check "  and required a NON-empty list"   out_has "named entries"
  # THE headline assertion. An /api/* fetch through the tailnet URL, whose Host
  # header is what the allowlist has to match.
  check "fetched the TAILNET /api/services" \
    calls_have "https://$FAKE_TS_HOST:8100/api/services"
  check "  and called it fully working"  out_has "Tailnet HTTPS is fully working"
  check "no host-validation errors"      out_has "No 'Host validation failed'"
  check "audited the listener"           out_has "listens only on loopback"
  check "asserted no docker socket"      out_has "Docker socket is not mounted"
  check "summary says Done"              out_has "Done."
  check "prints the tailnet URL"         out_hasF "https://$FAKE_TS_HOST:8100"

  # --- it says the honest thing about the launcher ------------------------
  check "names the existing launcher"    out_hasF "/home/"
  check "  says which one can start/stop" out_has "start, stop and deploy"

  # --- and it never went near the host's own services --------------------
  check "never called systemctl"         no_call "systemctl"
  check "never touched port 8098"        no_call "8098"
  teardown
}

# =========================================================================
# The allowlist. This block is the reason the suite exists.
# =========================================================================

test_allowlist_missing_tailnet_host_fails() {
  echo "• allowlist loses '<host>:8100': deploy FAILS, even though / is still 200"
  # The exact shape of the real failure. Note what stays green: the container
  # runs, the loopback checks pass (the default allowlist is built from PORT,
  # so 127.0.0.1:8100 is covered for free), and GET / returns 200 with a
  # byte-identical body. Only the tailnet /api/* call can tell.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first, correct deploy
  check "first run succeeded"            [ "$CODE" -eq 0 ]
  # Drop ONLY the ":8100" form, keeping the bare name — the near-miss someone
  # actually makes, and the one that proves the port is part of the match.
  subst "$SVC/.env" "s/^HOMEPAGE_ALLOWED_HOSTS=$FAKE_TS_HOST:8100,/HOMEPAGE_ALLOWED_HOSTS=/"
  : > "$CALLS_LOG"; rm -f "$STATE_DIR/hv_log"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "warns during the run"           out_has "does not contain"
  check "  predicts the 200"             out_has "HTTP 200"
  check "names HOST VALIDATION FAILED"   out_has "HOST VALIDATION FAILED"
  check "  quotes the rejected Host"     out_hasF "$FAKE_TS_HOST:8100"
  check "  says the page still loads"    out_has "look almost right"
  check "  prints the current value"     out_hasF "127.0.0.1:8100"
  check "summary reports the failure"    out_has "Deploy finished with failures"
  check "  and does NOT say Done"        out_lacksF "Done."
  # The things that stayed green, which is the whole trap:
  check "loopback /api/services still passed" out_has "named entries"
  check "GET / still returned 200"       out_has "Dashboard HTML renders"
  teardown
}

test_allowlist_bare_host_is_load_bearing() {
  echo "• Serve on :443 works via the bare-host entry, and fails without it"
  # Why the seeded list has FOUR entries. On :443 the browser sends no port at
  # all, so the '<host>:8100' entry cannot match and the bare one carries it.
  setup
  touch "$STATE_DIR/operator"
  export HTTPS_PORT=443
  run_deploy
  check "exits zero on :443"             [ "$CODE" -eq 0 ]
  check "  verified through the tailnet" out_has "Tailnet HTTPS is fully working"
  check "  Host header carried no port"  calls_have "https://$FAKE_TS_HOST:443/api/services"
  # Now remove just the bare entry.
  subst "$SVC/.env" "s/,$FAKE_TS_HOST,/,/"
  : > "$CALLS_LOG"
  run_deploy
  check "without it: exits non-zero"     [ "$CODE" -ne 0 ]
  check "  names host validation"        out_has "HOST VALIDATION FAILED"
  unset HTTPS_PORT
  teardown
}

test_allowlist_removed_from_compose_fails() {
  echo "• HOMEPAGE_ALLOWED_HOSTS deleted from docker-compose.yml: caught"
  # A .env-only assertion would not notice this: the value is written
  # correctly and simply never reaches the container. The stub resolves the
  # compose file, so the fallback to Homepage's PORT-derived default allowlist
  # happens for real and the tailnet check 400s.
  setup
  touch "$STATE_DIR/operator"
  subst "$SVC/docker-compose.yml" '/- HOMEPAGE_ALLOWED_HOSTS=/d'
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "names host validation"        out_has "HOST VALIDATION FAILED"
  check "container never got the var"  [ -z "$(cenv HOMEPAGE_ALLOWED_HOSTS)" ]
  check "loopback still worked"        out_has "named entries"
  teardown
}

test_allowlist_wildcard_is_honoured_but_not_shipped() {
  echo "• a hand-set '*' allowlist is tolerated, never generated"
  # It is the user's file, so setup.sh must not fight it — but the shipped
  # value is four exact strings, and the suite asserts that separately above.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  subst "$SVC/.env" 's/^HOMEPAGE_ALLOWED_HOSTS=.*/HOMEPAGE_ALLOWED_HOSTS=*/'
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "did not warn about drift"     out_lacks "does not contain"
  check "container got the wildcard"   cenv_is HOMEPAGE_ALLOWED_HOSTS '*'
  check "tailnet check still passed"   out_has "Tailnet HTTPS is fully working"
  teardown
}

test_port_env_must_follow_local_port() {
  echo "• compose PORT left at the image default: nothing answers, deploy dies"
  # PORT does double duty — it is the listening port AND the source of
  # Homepage's default allowlist. Pinning it to 3000 while publishing 8100
  # leaves the published port empty, which is a refused connection rather than
  # an error page.
  setup
  touch "$STATE_DIR/operator"
  subst "$SVC/docker-compose.yml" 's/- PORT=${LOCAL_PORT.*}/- PORT=3000/'
  run_deploy
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says it never connected"     out_has "never accepted a connection"
  check "published nothing"           no_call "tailscale serve"
  teardown
}

# =========================================================================

test_yaml_error_fails_the_deploy() {
  echo "• services.yaml does not parse: 200 and [] — caught as a failure"
  # The second thing on this service that looks like success. Homepage returns
  # an EMPTY array with HTTP 200 and logs the YAMLException nowhere the HTTP
  # client can see it.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/yaml_broken"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "names the empty list"         out_has "EMPTY list"
  check "  says 200 is what you get"   out_has "200 and \[\]"
  check "  points at the log"          out_has "failed to load"
  check "summary reports the failure"  out_has "Deploy finished with failures"
  teardown
}

test_config_not_clobbered() {
  echo "• re-run leaves every hand-edited config file BYTE-IDENTICAL"
  # The idempotency contract that matters most here: these files ARE the
  # product. Hashes, not timestamps — a rewrite with identical content would
  # still be a bug, but a rewrite with different content is the disaster.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first run succeeded"            [ "$CODE" -eq 0 ]

  # Edit all four the way Kai would, plus add a fifth file of his own.
  echo "# kai's own note" >> "$CFG/services.yaml"
  subst "$CFG/settings.yaml" 's/^title:.*/title: MY BOX/'
  echo "- openmeteo: {}" >> "$CFG/widgets.yaml"
  echo "# my links" >> "$CFG/bookmarks.yaml"
  echo "custom: true" > "$CFG/custom-of-mine.yaml"
  echo '# my-custom-marker' >> "$SVC/.env"

  before="$(cd "$CFG" && ls | sort | while read -r f; do
              [ -f "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"; done)"
  : > "$CALLS_LOG"
  run_deploy
  after="$(cd "$CFG" && ls | sort | while read -r f; do
             [ -f "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"; done)"

  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "every config file unchanged"    [ "$before" = "$after" ]
  if [ "$before" != "$after" ]; then
    red "      before:"; red "$before"
    red "      after: "; red "$after"
  fi
  check "  said it kept them"            out_has "Kept 5 existing config file"
  check "  seeded nothing new"           out_lacks "Seeded"
  check "kai's own extra file survived"  [ -f "$CFG/custom-of-mine.yaml" ]
  check ".env untouched"                 env_has "my-custom-marker"
  check "  says it left .env alone"      out_has "leaving untouched"
  check "never invoked sudo"             no_call "^sudo "
  check "compose up re-invoked"          [ -f "$STATE_DIR/compose_up" ]
  check "re-applied the serve config" \
    calls_have "tailscale serve --bg --https=8100 http://127.0.0.1:8100"
  check "re-verified through the tailnet" out_has "Tailnet HTTPS is fully working"
  # And the edited title is what the container serves back — proving the
  # re-run did not quietly restore a template.
  check "the edited settings.yaml is still the live one" \
    grep -q 'title: MY BOX' "$CFG/settings.yaml"
  teardown
}

test_one_deleted_file_is_reseeded() {
  echo "• one config file deleted: re-seeded from the repo, others left alone"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "# edited" >> "$CFG/settings.yaml"
  sum="$(cksum < "$CFG/settings.yaml")"
  rm -f "$CFG/widgets.yaml"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "widgets.yaml is back"         [ -f "$CFG/widgets.yaml" ]
  check "  from the repo template"     grep -q 'resources' "$CFG/widgets.yaml"
  check "  not Homepage's placeholder" [ "$(cksum < "$CFG/widgets.yaml")" != "$(printf -- '---\n' | cksum)" ]
  check "reported seeding exactly 1"   out_has "Seeded 1 config file"
  check "  and keeping 4"              out_has "Kept 4 existing config file"
  check "settings.yaml still edited"   [ "$(cksum < "$CFG/settings.yaml")" = "$sum" ]
  teardown
}

test_seeding_happens_before_container_start() {
  echo "• seeding runs BEFORE compose up, so Homepage's placeholder never wins"
  # Homepage writes an upstream default for any config file that is absent
  # when the container starts, and both writers skip files that already exist
  # — so whichever goes first wins PERMANENTLY. A later re-run cannot repair
  # it. The docker stub models that write, so the ordering is testable.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "the repo's services.yaml won"    grep -q "$FAKE_TS_HOST" "$CFG/services.yaml"
  check "  no 'My First Service'"         [ -z "$(grep -l 'My First Service' "$CFG"/*.yaml 2>/dev/null)" ]
  check "  and the API serves real names" out_has "named entries"
  teardown

  # Now prove the assertion has teeth: reorder setup.sh so `up` happens first.
  echo "  (and with the order reversed, the placeholder wins — assertion has teeth)"
  setup
  touch "$STATE_DIR/operator"
  # Make the seeding loop a no-op, which is what 'seed after start' amounts to
  # for the file Homepage has already created.
  mkdir -p "$CFG"
  cat > "$CFG/services.yaml" <<'YAML'
---
- My First Group:
    - My First Service:
        href: http://localhost/
YAML
  run_deploy
  check "placeholder is what gets served" grep -q 'My First Group' "$CFG/services.yaml"
  check "  setup.sh did NOT overwrite it" out_has "Kept 1 existing config file"
  check "  and it says so rather than silently fixing it" out_has "left alone"
  teardown
}

test_docker_socket_mounted_is_caught() {
  echo "• docker.sock uncommented: flagged loudly, not silently accepted"
  # Root-equivalent escalation for an app with no login of its own. It is off
  # by default; the point of this test is that turning it on can never be
  # invisible.
  setup
  touch "$STATE_DIR/operator"
  subst "$SVC/docker-compose.yml" \
    's|^\( *\)# - /var/run/docker.sock|\1- /var/run/docker.sock|'
  check "the mutation took"            compose_hasF '/var/run/docker.sock'
  run_deploy
  check "container really got it"      grep -q 'docker\.sock' "$STATE_DIR/container_mounts"
  check "warned about it"              out_has "docker.sock IS mounted"
  check "  names the escalation"       out_has "root-equivalent"
  check "  says how to undo it"        out_has "comment the mount out"
  check "  did NOT claim it is absent" out_lacks "socket is not mounted"
  teardown
}

test_listener_escaped_loopback() {
  echo "• HOSTNAME flipped to 0.0.0.0 in compose: listener audit FAILS"
  # With host networking there is no Docker publish spec, so this one line is
  # the entire loopback guarantee, and the image ships 0.0.0.0. The ss stub
  # reports what the resolved HOSTNAME says, so the failure is real rather
  # than simulated.
  setup
  touch "$STATE_DIR/operator"
  subst "$SVC/docker-compose.yml" 's/- HOSTNAME=127\.0\.0\.1/- HOSTNAME=0.0.0.0/'
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the bad address"         out_hasF "0.0.0.0"
  check "  calls it outside the tailnet" out_has "outside the tailnet boundary"
  check "  points at HOSTNAME"          out_has "HOSTNAME=127.0.0.1"
  check "  names the compose file"      out_hasF "docker-compose.yml"
  check "summary reports the failure"   out_has "Deploy finished with failures"
  teardown
}

test_listener_on_lan_is_caught() {
  echo "• something moved the listener to a LAN address: caught"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_lan"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the LAN address"   out_hasF "192.168.1.42"
  teardown
}

test_tailnet_listener_is_not_a_failure() {
  echo "• tailscaled's own proxy on the same port is ACCEPTED, not flagged"
  # HTTPS port == local port on this service, so tailscaled legitimately holds
  # the tailnet address on :8100. A check that flagged it would make every
  # correct deploy red.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "the tailnet listener was seen" calls_have "^ss .*sport = :8100"
  check "  and the audit passed"        out_has "listens only on loopback"
  check "  and it names Serve's proxy"  out_has "Serve's own proxy"
  teardown
}

test_listener_audit_without_ss() {
  echo "• no ss on the box (macOS): the listener audit falls back to lsof"
  # Both halves matter. lsof exits 1 when nothing matches, and under
  # `set -o pipefail` that status is enough to kill an unguarded assignment —
  # so the fallback has to tolerate "no listeners" while still catching a
  # wildcard.
  setup
  touch "$STATE_DIR/operator"
  minimal_path "$SANDBOX/noss" ss
  run_deploy_path "$SANDBOX/noss"
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "used lsof, not ss"      calls_have "^lsof "
  check "  never called ss"      no_call "^ss "
  check "audit still passed"     out_has "listens only on loopback"
  teardown

  setup
  touch "$STATE_DIR/operator"
  subst "$SVC/docker-compose.yml" 's/- HOSTNAME=127\.0\.0\.1/- HOSTNAME=0.0.0.0/'
  minimal_path "$SANDBOX/noss" ss
  run_deploy_path "$SANDBOX/noss"
  check "wildcard still caught via lsof" [ "$CODE" -ne 0 ]
  check "  names the address"            out_hasF "0.0.0.0"
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
  echo 4 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "polled /api/healthcheck repeatedly" \
    [ "$(call_count '/api/healthcheck')" -ge 5 ]
  check "  waited between polls"          [ "$(call_count '^sleep ')" -ge 4 ]
  check "did not report a 000 failure"    out_lacks "never accepted a connection"
  check "still published"                 calls_have "tailscale serve --bg --https=8100"
  check "still verified through the tailnet" out_has "Tailnet HTTPS is fully working"
  teardown
}

test_never_ready() {
  echo "• Homepage never answers on loopback: dies before publishing"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/conn_refused_left"   # more refusals than the loop has tries
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says it never connected"   out_has "never accepted a connection"
  check "  gives the logs command"  out_has "logs homepage"
  check "published nothing"         no_call "tailscale serve"
  teardown
}

test_container_not_running() {
  echo "• container exited: failure, with the logs command"
  setup
  touch "$STATE_DIR/operator"
  echo exited > "$STATE_DIR/container_status"
  run_deploy
  check "exits non-zero"         [ "$CODE" -ne 0 ]
  check "names the state"        out_has "never accepted a connection"
  check "gives the logs command" out_has "logs homepage"
  teardown
}

test_up_fails() {
  echo "• compose up fails: named, and nothing is published"
  setup
  touch "$STATE_DIR/operator"
  echo inuse > "$STATE_DIR/up_fail"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "says port conflict"             out_has "Port conflict"
  check "  explains host networking"     out_has "no Docker port mapping"
  check "  gives the diagnostic command" out_has "ss -ltnp"
  check "published nothing"              no_call "tailscale serve"
  teardown

  setup
  touch "$STATE_DIR/operator"
  echo other > "$STATE_DIR/up_fail"
  run_deploy
  check "generic failure: exits non-zero" [ "$CODE" -ne 0 ]
  check "  gives the logs command"        out_has "logs homepage"
  teardown
}

test_pull_failure_is_soft() {
  echo "• image pull fails: a warning, deploy continues on the cached image"
  # A pinned tag that is already cached is a perfectly good deploy, and a
  # transient registry failure should not take the dashboard down on a re-run.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/pull_fail"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "warns about the pull"       out_has "pull failed"
  check "  says it used the cache"   out_has "already cached"
  check "still verified the tailnet" out_has "Tailnet HTTPS is fully working"
  teardown
}

test_https_front_door_slow() {
  echo "• tailnet HTTPS not answering yet: a warning, not a failed deploy"
  # First request on a new port can take ~60s while the cert is minted.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/https_dead"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "warns about the cert"          out_has "cert may still be minting"
  check "  gives the retry command"     out_has "curl -sS -o /dev/null"
  check "  retried before giving up"    [ "$(call_count "https://$FAKE_TS_HOST")" -ge 5 ]
  check "did not claim it works"        out_lacks "fully working"
  check "loopback checks still passed"  out_has "named entries"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8101 HTTPS_PORT=8101
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8101' "$SVC/.env"
  check "allowlist moved with it"    env_has "$FAKE_TS_HOST:8101"
  check "  and 127.0.0.1:8101"       env_has "127.0.0.1:8101"
  check "container got PORT=8101"    cenv_is PORT 8101
  check "polled :8101"               calls_have "127.0.0.1:8101/api/healthcheck"
  check "served :8101 -> :8101"      calls_have "tailscale serve --bg --https=8101 http://127.0.0.1:8101"
  check "prints the :8101 URL"       out_hasF "https://$FAKE_TS_HOST:8101"
  check "never touched :8100"        no_call "127.0.0.1:8100"
  # Never 8098: that is an unrelated ad-hoc listener on this box.
  check "never touched :8098"        no_call "8098"

  # .env is the source of truth once it exists, so a re-run cannot silently
  # move a live deployment out from under its published port — or, worse,
  # out from under its allowlist.
  export LOCAL_PORT=8102 HTTPS_PORT=8101
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8102 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8101' "$SVC/.env"
  check "re-run: never touched 8102" no_call "127.0.0.1:8102"
  unset LOCAL_PORT HTTPS_PORT
  teardown
}

test_allowlist_drift_warns_without_rewriting() {
  echo "• HTTPS_PORT moved but .env's allowlist did not: warns, does not rewrite"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # deployed on 8100
  before="$(cksum < "$SVC/.env")"
  export HTTPS_PORT=8200                       # ...Serve is moved by hand
  : > "$CALLS_LOG"
  run_deploy
  check "warns about the allowlist"  out_has "does not contain"
  check "  names the missing entry"  out_hasF "$FAKE_TS_HOST:8200"
  check "  says / will still be 200" out_has "HTTP 200"
  check "  gives the fix"            out_has "and re-run"
  check ".env left alone (user's)"   [ "$(cksum < "$SVC/.env")" = "$before" ]
  check "and the deploy FAILS"       [ "$CODE" -ne 0 ]
  unset HTTPS_PORT
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8100 http://127.0.0.1:8100"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the second
  # lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8100 http://127.0.0.1:8100"
  teardown
}

test_macos_warning() {
  echo "• macOS: warns that host networking does not share the Mac's loopback"
  # Docker Desktop runs containers in a Linux VM, so network_mode: host shares
  # the VM's loopback. Every siteMonitor probe would fail and the listener
  # would not appear on the Mac. Only assertable on a Mac; on Linux, assert
  # the warning is NOT printed, so the gate itself is tested.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  if [ "$OS" = "Darwin" ]; then
    check "warns about the VM"       out_has "Linux VM"
    check "  names the consequence"  out_has "siteMonitor"
    check "  says what to change"    out_has "bridge network"
  else
    check "no macOS warning on Linux" out_lacks "Linux VM"
  fi
  teardown
}

# ------------------------------------------------- sandbox integrity proof
# Recorded before the mocked suite runs, checked after it. A mocked suite that
# quietly wrote to ~/services/homepage or to the repo's real .env would be
# worse than no suite: on this service it would mean overwriting the very
# hand-edited YAML the whole design exists to protect.
HOST_SNAPSHOT=""
snapshot_host() {
  local f
  HOST_SNAPSHOT=""
  for f in "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" \
           "$SERVICE_DIR/SETUP.md" "$SERVICE_DIR/TROUBLESHOOT.md" \
           "$SERVICE_DIR/.env" "$SERVICE_DIR/config" \
           "$ORIG_HOME/services/homepage" \
           "$ORIG_HOME/services/homepage/config"; do
    if [ -f "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f $(cksum < "$f" 2>/dev/null || echo unreadable)"
    elif [ -d "$f" ]; then
      HOST_SNAPSHOT="$HOST_SNAPSHOT
$f dir $(ls -A "$f" 2>/dev/null | sort | cksum) $(cat "$f"/*.yaml 2>/dev/null | cksum)"
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
  check "repo files + ~/services/homepage/config unchanged" \
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
# On THIS service the Tailscale allowance is load-bearing rather than
# incidental, for two reasons: HTTPS port == local port (8100 -> 8100), so
# tailscaled's Serve proxy legitimately holds the tailnet address on the same
# number; and there is no Docker publish spec confining the app at all — see
# SETUP.md -> "Why host networking, and why that is still loopback-only".
#
# The function body below is byte-identical to immich's, vaultwarden's,
# jellyfin's and adguard's on purpose — it is the canonical implementation.
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

# A non-empty JSON array of objects that each carry a "name". Neither "is it
# 200" nor "is it valid JSON" is enough: a YAML syntax error returns `[]` with
# HTTP 200 and logs the exception nowhere the HTTP client can see it.
json_has_names() {  # json_has_names <file> [minimum-count]
  local min="${2:-1}" n
  head -c 1 "$1" 2>/dev/null | grep -q '\[' || return 1
  n="$(grep -o '"name"' "$1" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -ge "$min" ]
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

  # This service gets deployed, tested and undeployed. A stopped container
  # would otherwise produce ~20 red lines that all say the same thing, and
  # someone would read that as a broken deploy rather than an absent one.
  local st
  # tr, not `|| echo missing`: `docker inspect` on a missing container still
  # prints a newline to STDOUT, so the fallback would produce "\nmissing" and
  # the message below would wrap mid-sentence.
  st="$(docker inspect -f '{{.State.Status}}' homepage 2>/dev/null | tr -d '[:space:]')"
  [ -n "$st" ] || st=missing
  if [ "$st" != "running" ]; then
    red "    ! the 'homepage' container is '$st', not running."
    red "      Nothing below can be checked against a service that is not up."
    red "      Start it:  docker compose --project-directory $SERVICE_DIR up -d"
    red "      (or, if it was deliberately undeployed, that is the expected"
    red "       state and --live simply does not apply right now.)"
    FAIL=$((FAIL + 1))
    return
  fi

  local ts port https_port host url cfg tmp
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env" | head -1)"
  https_port="${HTTPS_PORT:-$port}"
  cfg="$(sed -n 's/^HOMEPAGE_CONFIG=//p' "$SERVICE_DIR/.env" | head -1)"
  host="$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  url="https://$host:$https_port"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN 2>/dev/null || true

  # --- the container ----------------------------------------------------
  live_check "homepage container running" \
    sh -c "docker inspect -f '{{.State.Status}}' homepage | grep -qx running"
  live_check "  image is pinned, not :latest" \
    sh -c "docker inspect -f '{{.Config.Image}}' homepage | grep -qE 'homepage:v[0-9]+\.[0-9]+\.[0-9]+$'"
  live_check "  restart policy is unless-stopped" \
    sh -c "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' homepage | grep -qx unless-stopped"
  live_check "  mem_limit is set (not unbounded)" \
    sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' homepage)\" -gt 0 ]"
  # Root-equivalent escalation for a web app with no login. Off by default.
  live_check "  Docker socket is NOT mounted" \
    sh -c "! docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' homepage | grep -q 'docker\\.sock'"

  # --- host networking and the loopback bind, as a PAIR -----------------
  # Host mode is what makes the siteMonitor probes work; HOSTNAME is the only
  # thing that keeps the socket off the LAN once there is no publish spec.
  # Either one alone is wrong, so they are asserted together.
  live_check "network_mode is host (deliberate)" \
    sh -c "docker inspect -f '{{.HostConfig.NetworkMode}}' homepage | grep -qx host"
  live_check "  HOSTNAME=127.0.0.1 keeps it on loopback" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' homepage | grep -qx 'HOSTNAME=127.0.0.1'"
  live_check "  PORT matches LOCAL_PORT ($port)" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' homepage | grep -qx 'PORT=$port'"
  live_check "not listening on non-local ifaces (:$port)" no_external_listener "$port"
  live_check "  and IS listening on 127.0.0.1:$port" \
    sh -c "ss -ltnH 'sport = :$port' 2>/dev/null | awk '{print \$4}' | grep -qx '127.0.0.1:$port' || lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | grep -q '127.0.0.1:$port'"
  live_check "  never on 0.0.0.0" \
    sh -c "! ss -ltnH 'sport = :$port' 2>/dev/null | awk '{print \$4}' | grep -q '^0\\.0\\.0\\.0:'"

  # --- the allowlist ----------------------------------------------------
  live_check "container's allowlist names $host:$https_port" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' homepage | grep '^HOMEPAGE_ALLOWED_HOSTS=' | grep -qF '$host:$https_port'"
  live_check "  and 127.0.0.1:$port (what Kuma and setup.sh use)" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' homepage | grep '^HOMEPAGE_ALLOWED_HOSTS=' | grep -qF '127.0.0.1:$port'"
  live_check "  and is not the wildcard '*'" \
    sh -c "! docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' homepage | grep -qx 'HOMEPAGE_ALLOWED_HOSTS=\\*'"

  # --- loopback health --------------------------------------------------
  live_check "GET /api/healthcheck on loopback is 200 'up'" \
    sh -c "curl -sS --max-time 20 'http://127.0.0.1:$port/api/healthcheck' | grep -qx up"
  # /healthz does not exist; asserted so nobody re-points a monitor at it.
  live_check "  /healthz is 404 (do not monitor it)" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/healthz')\" = 404 ]"
  curl -sS --max-time 20 -o "$tmp" "http://127.0.0.1:$port/api/services" 2>/dev/null
  live_check "GET /api/services on loopback is a NON-EMPTY list" \
    json_has_names "$tmp" 2
  live_check "  and no href still says __TS_HOST__" \
    sh -c "! grep -q '__TS_HOST__' '$tmp'"

  # --- THE ONE THAT MATTERS --------------------------------------------
  # An /api/* fetch over tailnet HTTPS, so the Host header is the real
  # '<host>:<port>' the allowlist has to match. A 200 on / proves nothing:
  # see the demonstration immediately below.
  curl -sS --max-time 60 -o "$tmp" "$url/api/services" 2>/dev/null
  live_check "TAILNET HTTPS $url/api/services is a NON-EMPTY list" \
    json_has_names "$tmp" 2
  live_check "  it is not the host-validation error" \
    sh -c "! grep -q 'Host validation failed' '$tmp'"
  live_check "  and it names a group from the live services.yaml" \
    sh -c "g=\$(sed -n 's/^- \\(.*\\):\$/\\1/p' '$cfg/services.yaml' | head -1); [ -n \"\$g\" ] && grep -qF \"\\\"\$g\\\"\" '$tmp'"
  live_check "tailnet HTTPS /api/healthcheck is 200 'up' (the Kuma path)" \
    sh -c "curl -sS --max-time 30 '$url/api/healthcheck' | grep -qx up"

  # --- the trap itself, asserted rather than described ------------------
  # Proves on THIS deployment, right now, that a status check on / cannot
  # detect a host-validation failure — so nobody "simplifies" the check above.
  live_check "a disallowed Host still gets 200 on / (why / is worthless)" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Host: not-allowed.invalid:$port' 'http://127.0.0.1:$port/')\" = 200 ]"
  live_check "  while the same Host gets 400 on /api/services" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Host: not-allowed.invalid:$port' 'http://127.0.0.1:$port/api/services')\" = 400 ]"

  # --- publish ----------------------------------------------------------
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"

  # --- config on disk ---------------------------------------------------
  live_check "config dir exists: $cfg" sh -c "test -d '$cfg'"
  live_check "  services.yaml present"  sh -c "test -f '$cfg/services.yaml'"
  live_check "  settings.yaml present"  sh -c "test -f '$cfg/settings.yaml'"
  live_check "  widgets.yaml present"   sh -c "test -f '$cfg/widgets.yaml'"
  live_check "  bookmarks.yaml present" sh -c "test -f '$cfg/bookmarks.yaml'"
  live_check "  every bookmark the frontend receives carries an href" \
    sh -c "curl -s --max-time 10 http://127.0.0.1:$port/api/bookmarks | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d and all(b.get(\"href\") for g in d for b in g[\"bookmarks\"]) else 1)'"
  # The whole point of the service is editing these by hand. PUID/PGID exist
  # so that does not need sudo.
  live_check "  and they are writable without sudo" sh -c "test -w '$cfg/services.yaml'"
  live_check "  Homepage's own log is there (YAML errors land ONLY here)" \
    sh -c "test -f '$cfg/logs/homepage.log'"
  live_check "  no unsubstituted __TS_HOST__ on disk" \
    sh -c "! grep -rq '__TS_HOST__' '$cfg'"

  # --- log hygiene, reported not asserted -------------------------------
  # Host-validation lines from a since-fixed allowlist stay in the log until
  # the container is recreated, so this is information rather than a verdict.
  local hv down
  hv="$(docker logs homepage 2>&1 | grep -c 'Host validation failed' || true)"
  down="$(docker logs --tail 400 homepage 2>&1 | grep -c 'Error calling http://127.0.0.1' || true)"
  printf '    → %s "Host validation failed" line(s) in the container log.\n' "${hv:-0}"
  printf '      At least one is THIS SUITE: the two checks above deliberately\n'
  printf '      send Host: not-allowed.invalid to prove / cannot detect the\n'
  printf '      failure. Any others mean something real is reaching Homepage\n'
  printf '      with an unlisted Host — a Kuma monitor or the launcher on a\n'
  printf '      port that is not on the allowlist. See which:\n'
  printf '        docker logs homepage 2>&1 | grep "Host validation failed" | tail -5\n'
  printf '      The count does not reset on a fix; it clears when the\n'
  printf '      container is recreated.\n'
  printf '    → %s recent "Error calling http://127.0.0.1..." line(s).\n' "${down:-0}"
  printf '      EXPECTED on this box: several services are deliberately\n'
  printf '      start-on-demand, and Homepage correctly reports them down.\n'
  rm -f "$tmp"
}

# ------------------------------------------------------------------ main
if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "homepage/setup.sh or homepage/docker-compose.yml is missing — nothing to test."
  exit 1
fi
if [ ! -d "$SERVICE_DIR/config" ]; then
  red "homepage/config/ (the shipped YAML templates) is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
snapshot_host
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_no_magicdns
test_preflight_no_templates
test_fresh_deploy
test_allowlist_missing_tailnet_host_fails
test_allowlist_bare_host_is_load_bearing
test_allowlist_removed_from_compose_fails
test_allowlist_wildcard_is_honoured_but_not_shipped
test_port_env_must_follow_local_port
test_yaml_error_fails_the_deploy
test_config_not_clobbered
test_one_deleted_file_is_reseeded
test_seeding_happens_before_container_start
test_docker_socket_mounted_is_caught
test_listener_escaped_loopback
test_listener_on_lan_is_caught
test_tailnet_listener_is_not_a_failure
test_listener_audit_without_ss
test_readiness_race
test_never_ready
test_container_not_running
test_up_fails
test_pull_failure_is_soft
test_https_front_door_slow
test_port_override
test_allowlist_drift_warns_without_rewriting
test_operator_escalation
test_serve_approval_prompt
test_macos_warning
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
