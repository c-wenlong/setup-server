#!/usr/bin/env bash
#
# Tests for remote-desktop/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with a temp $HOME and PATH stubs for every external command it touches.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT MAKES THIS SERVICE'S SUITE DIFFERENT, AND WHAT IT CANNOT DO
# ─────────────────────────────────────────────────────────────────────────────
#
# 1. THE SECURITY QUESTION DOMINATES. Every other service here satisfies the
#    repo's loopback rule trivially. This one has an RDP backend that CANNOT
#    BE TOLD WHAT ADDRESS TO BIND. Measured on this box on 2026-09-11:
#
#      grdctl --help                      -> rdp has set-port. No set-address.
#      gsettings list-recursively org.gnome.desktop.remote-desktop.rdp
#                                         -> enable, negotiate-port, port,
#                                            screen-share-mode, tls-cert,
#                                            tls-key, view-only. That is the
#                                            COMPLETE schema. No address key.
#
#    So :3389 lands on the wildcard and the LAN can reach it. The mitigation
#    has to come from a packet filter, and the live suite checks by OPENING
#    REAL TCP CONNECTIONS rather than by reading a config file. setup.sh does
#    the same, and this suite asserts that it keeps doing it — see
#    test_no_listener_audit_via_ss_at_all.
#
#    Note what this means for the canonical `no_external_listener` helper: it
#    is applied to the WEBAPP port only, NEVER to 3389. Asked about 3389 it
#    would report a violation on a correctly-secured box every single time,
#    because the wildcard bind is unavoidable. A check that is always red
#    teaches people to ignore it.
#
# 2. THE MITIGATION IS SOURCE-SCOPED, NOT INTERFACE-SCOPED, and that is what
#    makes the probes conclusive. setup.sh installs an nftables table of its
#    own that accepts tcp/3389 from loopback and the compose bridge subnet and
#    rejects it from everywhere else.
#
#    An interface-named rule would be worse twice over: this box has TWO LAN
#    addresses (enp31s0 192.168.88.11, wlp30s0 192.168.88.13) so a rule naming
#    one leaves the other open while looking fixed; and it would be
#    unverifiable from here, because Linux routes traffic aimed at the host's
#    own LAN address over lo, where an inbound interface rule never matches.
#    Matching on SOURCE means a local probe is rejected like any other, so a
#    refusal in the live suite means what it says.
#
#    Both directions are asserted. Too broad is as bad as too narrow: a
#    blanket reject on 3389 takes guacd out along with the LAN, and the
#    symptom ("remote desktop server is currently unreachable") reads like a
#    dead backend rather than a firewall. See test_filter_shape_and_ordering,
#    test_rdp_leaks_despite_filter, test_filter_too_broad_blocks_guacd.
#
#    The filter is also installed BEFORE RDP is enabled, and if it cannot be
#    installed the deploy DIES rather than proceeding — it fails closed. Both
#    are asserted, because "fails open" is the mutation that matters most.
#
# 3. guacd (4822) DOES NOT AUTHENTICATE ITS CALLERS. Anything that can open a
#    socket to it can drive an RDP session to any host with any credentials —
#    the webapp is the authenticator, and publishing guacd routes around it.
#    So the assertion is not "4822 is on loopback"; it is "4822 is not
#    listening on this host at all".
#
# 4. A 200 IS NOT A HEALTH CHECK. Tomcat happily returns 200 for a default
#    ROOT app, a stale WAR, or a proxy answering on your behalf. The curl stub
#    returns 200 with Tomcat's own boilerplate in the `tomcat_blank` scenario,
#    so a setup.sh whose health check only looks at the status code goes green
#    on a service that is not there — and test_health_check_is_not_a_200
#    catches exactly that.
#
# 5. A RE-RUN MUST NEED NO SUDO. This service is the repo's one legitimate
#    sudo deviation (it configures a system daemon), which makes the
#    idempotent path more important here than anywhere else: a deploy that
#    re-prompts forever is one nobody re-runs, and a service nobody re-runs
#    drifts. test_idempotent_rerun_needs_no_sudo asserts zero `sudo` and zero
#    package installs on the second run.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ WHAT THIS SUITE CANNOT TELL YOU — read before trusting a green run
# ─────────────────────────────────────────────────────────────────────────────
#
# `sudo` on this box requires a password, and the session that wrote this was
# non-interactive. Consequently NO sudo-gated step of this deploy has ever
# been executed, by these tests or by anyone. In particular:
#
#   - `grdctl --system status` has never been run here. The grdctl stub's
#     output is modelled on the real binary's documented interface, not on
#     observed behaviour.
#   - The container RAM figures in SETUP.md come from the deploy side and are
#     NOT reproduced here: this suite never starts a container.
#   - No RDP session has ever been established, on this backend or any other.
#     Nobody has connected. The mocked suite proves the script's CONTROL FLOW
#     around the backend, and nothing whatsoever about whether the backend
#     works.
#   - The firewall mitigation has never been installed, so the exposure
#     assertions in the live suite have never been seen to pass.
#
# MOCKED-GREEN IS MOCKED. The first real deploy is what tests this service.
#
# Nothing here touches the host: no ~/services/remote-desktop, no real .env,
# no container is started or stopped, gdm is never so much as read.
# test_sandbox_was_hermetic proves it with before/after checksums, and the
# systemctl stub HARD-FAILS any attempt to touch gdm or the graphical target.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
note()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

# The address the tailscale stub reports. Deliberately NOT this box's real
# 100.85.87.87: a literal baked into docker-compose.yml or setup.sh must not
# be able to pass by coincidence.
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
  cp "$SERVICE_DIR/setup.sh" "$SVC/"
  [ -f "$SERVICE_DIR/docker-compose.yml" ] && cp "$SERVICE_DIR/docker-compose.yml" "$SVC/"
  # GNOME's Remote Login authenticates against a real system account, so
  # setup.sh needs RDP_USER's actual login password and will not invent one.
  # On a TTY it prompts; with no TTY it refuses outright — correct for a human
  # deploy, but it means every scenario here would die before reaching what it
  # is testing. Supplying it through the environment is the same escape hatch
  # the rest of the repo uses for LOCAL_PORT and friends.
  #
  # test_no_password_and_no_tty unsets this deliberately: that refusal is
  # itself behaviour worth asserting, so it must not be masked here.
  export RDP_PASSWORD="test-rdp-password"
  return 0
}

teardown() {
  rm -rf "$SANDBOX"
  # AGENTS.md's harness gotcha: restore $HOME or the live checks below read a
  # deleted sandbox and report nonsense.
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_UNAME GUAC_PORT GUAC_USER GUAC_RDP_HOST STATE_DIR CALLS_LOG \
        RDP_PASSWORD
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# A PATH containing ONLY what we hand it — used to prove the preflight
# branches that turn on a command being ABSENT. Appending the stub dir to the
# real PATH cannot express "docker does not exist": /usr/bin/docker would
# still be found.
minimal_path() {  # minimal_path <dir> [stub-basename-to-omit ...]
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p s base omit skip
  # openssl and hostname are NOT optional here even though they look like
  # incidental tools: setup.sh's preflight loop checks openssl before it
  # checks docker, so omitting it made "preflight fails when docker is
  # absent" die on the wrong message and pass for the wrong reason.
  for c in bash sh env mktemp rm cat head cut sed awk grep tr chmod \
           mkdir rmdir cp mv ln ls stat od readlink dirname basename seq \
           touch sort wc test printf date xxd openssl hostname cksum \
           xargs tee comm join expr sleep; do
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

out_has()    { grep -qi -- "$1" <<<"$OUT"; }
out_hasF()   { grep -qF -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q -- "$1" "$SVC/.env"; }
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | head -1; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Static assertions on docker-compose.yml, COMMENTS STRIPPED. That file
# documents at length what it deliberately does not do — "guacd is never
# published", "never :latest", the whole D1 explanation — so a naive grep
# matches the prose and concludes the exact opposite of the truth.
compose_file() { echo "$SVC/docker-compose.yml"; }
compose_has()   { sed 's/#.*//' "$(compose_file)" | grep -qE -- "$1"; }
compose_hasF()  { sed 's/#.*//' "$(compose_file)" | grep -qF -- "$1"; }
compose_lacks() { ! compose_has "$1"; }

# The Guacamole config the deploy writes. Located via .env (GUAC_HOME is its
# own key, not derived) rather than assumed, so a relocated state dir cannot
# make these assertions silently vacuous — a grep against a path that does not
# exist passes every "must NOT contain" test for free.
mapping_file() { printf '%s/user-mapping.xml' "$(env_val GUAC_HOME)"; }
mapping_has()  { grep -qF -- "$1" "$(mapping_file)" 2>/dev/null; }

# XML comments stripped. The file explains at length what it deliberately does
# NOT do — "Session recording is off on purpose", "NOT enabled: drive
# redirection" — so a naive grep for `recording` or `drive` matches the prose
# and concludes the exact opposite of the truth. Same trap as compose_has.
mapping_body()       { sed 's/<!--/\n&/g; s/-->/&\n/g' "$(mapping_file)" 2>/dev/null \
                         | sed '/<!--/,/-->/d'; }
mapping_body_lacks() { ! mapping_body | grep -qi -- "$1"; }

# `check` takes a COMMAND, so `check "x" [ -f a ] || ! grep b` does not do what
# it looks like: the `||` binds to the check call itself and the second half is
# never asserted. These wrappers keep such conditions inside one command.
mapping_lacks_literal() { ! grep -qF -- "$1" "$(mapping_file)" 2>/dev/null; }
file_absent()           { [ ! -e "$1" ]; }
env_lacks()             { ! grep -qi -- "$1" "$SVC/.env"; }
# All arguments must be non-empty and strictly increasing. Used for call-order
# assertions, where `check "x" [ -n "$a" ] && [ "$a" -lt "$b" ]` would assert
# only the first clause and quietly pass on a wrong ordering.
ordered_lines()         {
  local prev="" n
  for n in "$@"; do
    [ -n "$n" ] || return 1
    [ -z "$prev" ] || [ "$prev" -lt "$n" ] || return 1
    prev="$n"
  done
  return 0
}

# ═════════════════════════════════════════════════════════════════ mocked
# NOTE: the mocked cases below are written against the interface agreed with
# the deploy side (.env keys, container names, the health-check assertion).
# Where setup.sh has not settled a detail, the test asserts the BEHAVIOUR the
# spec requires rather than a specific string, so that it fails for a real
# reason and not for a cosmetic one.

test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "regular user"
  check "wrote no .env"         [ ! -f "$SVC/.env" ]
  check "started no container"  [ ! -f "$STATE_DIR/compose_up" ]
  check "touched the backend not at all" no_call "^grdctl"
  teardown
}

test_preflight_darwin() {
  echo "• preflight DIES on Darwin — a Mac cannot host this box's desktop"
  # Not a portability gap: a correctness one. Every other service in this repo
  # branches on uname and supports both platforms. This one operates THIS
  # HOST'S graphical session, which a Mac does not have and cannot proxy. A
  # macOS branch here would be a lie that half-works, so the only honest
  # behaviour is to refuse.
  setup
  export FAKE_UNAME=Darwin
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "names the platform"         out_has "darwin\|macos\|mac"
  check "  says why, not just that"  out_has "desktop\|host\|linux"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  check "started no container"       [ ! -f "$STATE_DIR/compose_up" ]
  check "never called grdctl"        no_call "^grdctl"
  teardown
}

test_preflight_no_docker() {
  echo "• preflight fails when docker is absent"
  setup
  minimal_path "$SANDBOX/nodocker" docker
  run_deploy_path "$SANDBOX/nodocker"
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names docker"      out_has "docker"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when the user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  check "suggests the group fix" out_has "docker group\|usermod -aG docker\|sg docker"
  check "wrote no .env"  [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "tailscale"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: backend configured, containers up, health proven by markup"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]

  # --- .env ---------------------------------------------------------------
  check ".env generated"                 [ -f "$SVC/.env" ]
  check ".env is mode 600"               [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records the port"          grep -qx 'GUAC_PORT=8094' "$SVC/.env"
  check ".env has a generated password"  grep -qE '^GUAC_PASSWORD=.{16,}$' "$SVC/.env"
  check ".env names the user"            [ -n "$(env_val GUAC_USER)" ]
  check ".env has GUAC_STATE"            grep -qE '^GUAC_STATE=/.+' "$SVC/.env"
  check ".env has GUAC_RDP_HOST"         [ -n "$(env_val GUAC_RDP_HOST)" ]
  # The whole of decision D1: inside a bridge container 127.0.0.1 is the
  # CONTAINER's loopback, where nothing is listening. It is the natural value
  # and it is always wrong here.
  check "  and it is NOT 127.0.0.1"      [ "$(env_val GUAC_RDP_HOST)" != "127.0.0.1" ]
  check "  and it is NOT localhost"      [ "$(env_val GUAC_RDP_HOST)" != "localhost" ]

  # --- compose, statically ------------------------------------------------
  check "webapp published on loopback"   compose_has '127\.0\.0\.1:.*:8080'
  check "  never on the wildcard"        compose_lacks '0\.0\.0\.0:'
  # guacd does not authenticate its callers. A ports: entry here is not a
  # style problem; it is an unauthenticated RDP proxy on the host.
  check "guacd is NEVER published"       compose_lacks '[:"'"'"' ]4822:'
  # The pin is a PAIR: compose references ${GUACD_VERSION:-1.6.0} and .env
  # records the value. Asserting only the compose literal would miss a .env
  # that says GUACD_VERSION=latest, and asserting only .env would miss a
  # compose file that ignores it. Both halves, or neither means anything.
  check "guacd image from a pinned var"  compose_hasF 'image: guacamole/guacd:${GUACD_VERSION'
  check "  compose default is 1.6.0"     compose_hasF 'GUACD_VERSION:-1.6.0'
  check "  .env pins guacd 1.6.0"        grep -qx 'GUACD_VERSION=1.6.0' "$SVC/.env"
  check "webapp image from a pinned var" compose_hasF 'image: guacamole/guacamole:${GUACAMOLE_VERSION'
  check "  compose default is 1.6.0"     compose_hasF 'GUACAMOLE_VERSION:-1.6.0'
  check "  .env pins webapp 1.6.0"       grep -qx 'GUACAMOLE_VERSION=1.6.0' "$SVC/.env"
  # 1.6.0 is the release that fixed CVE-2024-35164. Floating the tag also
  # risks a build compiled against FreeRDP 3, which Guacamole supports only
  # experimentally.
  check "  and never :latest"            compose_lacks ':latest'
  check "  .env never says latest"       env_lacks 'VERSION=latest'
  # 7.7 GB total, ~2.6 GB available, 1.9 GB of swap already in use.
  check "mem_limit on guacd"             compose_has 'mem_limit'
  check "  mem_limit appears twice"      [ "$(sed 's/#.*//' "$(compose_file)" | grep -c 'mem_limit')" -ge 2 ]
  # File auth is the entire reason this is two containers rather than four.
  check "no database container"          compose_lacks 'postgres|mysql|mariadb|POSTGRES_|MYSQL_'
  # Session recording is disk with no backup job behind it.
  check "session recording is off"       compose_lacks 'recording-path|RECORDING'
  # A literal tailnet IP would be wrong on any other machine and would break
  # silently if this node's address ever changed.
  check "no hardcoded tailnet literal"   compose_lacks '100\.[0-9]+\.[0-9]+\.[0-9]+'
  # 172.17-172.27 are ALL already allocated to other services' bridges here.
  check "compose subnet is pinned"       compose_has 'subnet'
  check "  outside 172.17-172.27"        compose_lacks 'subnet: *172\.(1[7-9]|2[0-7])\.'

  # --- the RDP backend ----------------------------------------------------
  check "enabled the RDP backend"        calls_have "grdctl.*rdp enable"
  # --system, and NOT --headless. They select different credential stores:
  # --system writes the system daemon's store (what Remote Login reads),
  # --headless writes a per-user headless store. Passing both asks for two
  # different things at once, so the absence of --headless is as much the
  # assertion as the presence of --system.
  check "  as the SYSTEM daemon"         calls_have "grdctl --system"
  check "  not mixed with --headless"    no_call "grdctl.*--headless"
  check "  set credentials"              calls_have "grdctl.*set-credentials"
  check "  pinned the port"              calls_have "grdctl.*set-port 3389"
  # negotiate-port defaults to TRUE, meaning the daemon quietly listens on a
  # DIFFERENT port when 3389 is taken. That would wander straight out from
  # under the packet filter, which only covers 3389 — the listener would be
  # unfiltered and the deploy would still look fine.
  check "  disabled port negotiation"    calls_have "grdctl.*disable-port-negotiation"
  # The schema default is view-only=true, i.e. look-but-don't-touch. Easy to
  # miss, and the symptom is a desktop that renders and ignores the mouse.
  check "  disabled view-only"           calls_have "grdctl.*disable-view-only"
  check "  set the TLS cert and key"     calls_have "grdctl.*set-tls-key"
  # The RDP private key must belong to the daemon's own system user and be
  # readable by nobody else. The install stub records requested ownership.
  check "  TLS key installed 0600 to the grd user" \
    grep -q 'gnome-remote-desktop gnome-remote-desktop 0600 .*rdp-tls.key' "$STATE_DIR/install_owners"
  # The listen address cannot be set from here. A deploy that thinks it can
  # is wrong, and the grdctl stub refuses the subcommand as the real one does.
  check "did NOT pretend to bind an address" no_call "set-bind-address\|set-address\|set-listen-address"
  # gdm and the graphical target are not recoverable over a tailnet. The
  # systemctl stub exits 99 on any attempt; this proves none was made.
  check "never touched gdm"              no_call "systemctl.*gdm"
  check "never touched graphical.target" no_call "graphical.target"
  check "never STOPPED gnome-remote-desktop" no_call "systemctl.*stop.*gnome-remote-desktop"
  check "  (the stub would have refused)" out_lacks "STUB REFUSED"

  # --- no host packages ---------------------------------------------------
  # D2 was resolved to gnome-remote-desktop precisely so this deploy installs
  # nothing: xfce4 + xrdp is ~400 MB and a second desktop environment.
  check "never ran apt-get at all"       no_call "apt-get"

  # --- Guacamole config ---------------------------------------------------
  check "wrote user-mapping.xml"         [ -f "$(mapping_file)" ]
  check "  is 0600"                      [ "$(file_mode "$(mapping_file)")" = "600" ]
  # The BROWSER password is hashed. The RDP password in the same file is NOT
  # and cannot be — Guacamole has to replay it to the RDP server — which is
  # exactly why the file is 0600 and its directory 0700.
  check "  browser password is hashed"   mapping_lacks_literal "$(env_val GUAC_PASSWORD)"
  check "  declares the hash encoding"   mapping_has 'encoding="sha256"'
  check "  the hash is the sha256 of GUAC_PASSWORD" \
    mapping_has "$(printf '%s' "$(env_val GUAC_PASSWORD)" | openssl dgst -sha256 | sed 's/^.*= //')"
  check "  RDP connection on port 3389"  mapping_has '<param name="port">3389</param>'
  check "  points at GUAC_RDP_HOST"      mapping_has "<param name=\"hostname\">$(env_val GUAC_RDP_HOST)</param>"
  check "  ignores the self-signed cert" mapping_has '<param name="ignore-cert">true</param>'
  check "  wallpaper off (bandwidth)"    mapping_has '<param name="enable-wallpaper">false</param>'
  # Comments stripped: the file EXPLAINS that recording is off and that drive
  # redirection is not enabled, so an unstripped grep matches the prose and
  # concludes the opposite.
  check "  no recording path param"      mapping_body_lacks 'recording'
  check "state dir created"              [ -d "$(env_val GUAC_STATE)" ]
  # Session recording is off, so the directory should not exist at all — an
  # empty recordings/ is an invitation to turn it on without a retention
  # story, and there is no backup job behind that disk.
  check "recordings dir NOT created"     file_absent "$(env_val GUAC_STATE)/recordings"
  # ⚠️ NO drive/ EITHER, and this corrects PLAN.md. PLAN.md step 6 specifies
  # enable-drive + a bind-mounted drive-path, which is correct for xrdp and
  # WRONG for this backend: gnome-remote-desktop does not implement the rdpdr
  # channel, so the switch would be a setting that does nothing and the
  # directory would be a promise the service cannot keep. Asserting its
  # ABSENCE is what stops a future author "restoring" it from the plan.
  check "drive dir NOT created (no rdpdr in this backend)" \
    file_absent "$(env_val GUAC_STATE)/drive"
  check "  and no enable-drive param"    mapping_body_lacks 'enable-drive'

  # --- containers + health ------------------------------------------------
  check "compose up invoked"             [ -f "$STATE_DIR/compose_up" ]
  check "health check hit /guacamole/"   calls_have "curl.*127.0.0.1:8094"
  check "  reported real markup"         out_has "guacamole"

  # --- publish ------------------------------------------------------------
  # The TARGET matters as much as the port. Guacamole is deployed under the
  # /guacamole context path, so serving http://127.0.0.1:8094 alone puts a 404
  # at the tailnet URL — published, and broken. Tailscale rewrites the prefix,
  # which is what keeps the public URL a clean https://host:8094/ .
  check "served on tailscale :8094"      calls_have "tailscale serve --bg --https=8094 http://127.0.0.1:8094/guacamole/$"
  check "  front door returns markup, not 404" out_has "serves the Guacamole client over the tailnet"
  check "prints the final URL"           out_hasF "https://test-host.tailfake.ts.net:8094"
  check "tells you where the password is" out_has "\.env"

  # --- the exposure is DISCLOSED, not hidden ------------------------------
  # The one thing this deploy must never do is finish quietly. :3389 is on the
  # wildcard because gnome-remote-desktop cannot be told otherwise, and an
  # operator who is not told that cannot make a decision about it.
  check "says something about :3389"     out_hasF "3389"
  teardown
}

test_health_check_is_not_a_200() {
  echo "• Tomcat answers 200 with its own boilerplate: FAILS, not celebrated"
  # THE trap for this service. A running Tomcat returns 200 for a default ROOT
  # app or a stale WAR. Only the BODY distinguishes a working Guacamole from a
  # JVM that happened to bind the port. A setup.sh checking `%{http_code}`
  # goes green here, which is the whole point of the test.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/tomcat_blank"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "does not claim success"       out_lacks "Guacamole is at\|Done\."
  check "says the response was wrong"  out_has "guacamole\|markup\|unexpected\|not.*respond"
  teardown
}

test_health_check_404() {
  echo "• Tomcat up but the app is not deployed at /guacamole/: FAILS"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/guac_404"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the code"    out_hasF "404"
  teardown
}

test_readiness_race() {
  echo "• cold start refuses the connection: the readiness loop retries, not dies"
  # A container that is 'up' is not a server that is listening, and the JVM in
  # this one takes appreciably longer to answer than any other service here.
  # Real curl reports a refused connection as exit 7 / http_code 000 — not a
  # tidy 503 — and a deploy that treats the first 000 as fatal fails most cold
  # starts. Jellyfin in this repo was bitten by exactly this.
  setup
  touch "$STATE_DIR/operator"
  echo 4 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "polled repeatedly"           [ "$(call_count '127.0.0.1:8094')" -ge 4 ]
  check "  waited between polls"      [ "$(call_count '^sleep ')" -ge 3 ]
  check "still published"             calls_have "tailscale serve"
  teardown
}

test_never_ready() {
  echo "• webapp never answers: dies, and does not publish a dead service"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/conn_refused_left"   # more refusals than the loop has tries
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "says it never answered" out_has "never\|timed out\|did not\|failed"
  check "published nothing"     no_call "tailscale serve --bg"
  teardown
}

test_idempotent_rerun_needs_no_sudo() {
  echo "• re-run: config preserved, and ZERO sudo, ZERO package installs"
  # The single most important behavioural test for this service. It is the
  # repo's one legitimate sudo deviation, which makes a well-behaved
  # idempotent path the thing that keeps that deviation acceptable: a deploy
  # that re-prompts for a password on every run is one nobody re-runs, and a
  # service nobody re-runs drifts out of its own documentation.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  check "first run succeeded"           [ "$CODE" -eq 0 ]
  check "  first run DID use sudo"      calls_have "^sudo "

  local pw mapping_before env_before
  pw="$(env_val GUAC_PASSWORD)"
  mapping_before="$(cksum < "$(mapping_file)" 2>/dev/null)"
  echo '# my-custom-marker' >> "$SVC/.env"
  env_before="$(cksum < "$SVC/.env")"
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/apt_install"

  run_deploy                                   # second deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  # ── the assertions this test exists for ──────────────────────────────
  check "NEVER invoked sudo"            no_call "^sudo "
  check "NEVER ran apt-get"             no_call "^apt-get"
  # Not one grdctl call, read or write. This script deliberately detects drift
  # WITHOUT asking grdctl — a fingerprint file under $APPLIED plus a real RDP
  # handshake on loopback — because `grdctl --system status` itself needs
  # polkit auth. Checking state via a sudo-gated read would defeat the purpose.
  check "did not touch grdctl at all"   no_call "^grdctl"
  check "  did not re-enable the backend" no_call "grdctl.*rdp enable"
  check "  did not re-set credentials"  no_call "grdctl.*set-credentials"
  # The filter is verified by comparing the installed files, not reinstalled.
  check "did not reinstall the filter"  no_call "^install .*rdp-firewall"
  check "  said so out loud"            out_has "no sudo needed"
  # It DID still re-verify the backend by connecting, rather than trusting the
  # fingerprint alone — a stale marker plus a dead daemon must not pass.
  check "still probed RDP on loopback"  calls_have "probe rdp 127.0.0.1 3389"
  # ─────────────────────────────────────────────────────────────────────
  check "existing .env untouched"       env_has "my-custom-marker"
  check "  password unchanged"          [ "$(env_val GUAC_PASSWORD)" = "$pw" ]
  check "  .env byte-identical"         [ "$(cksum < "$SVC/.env")" = "$env_before" ]
  check "user-mapping.xml byte-identical" \
    [ "$(cksum < "$(mapping_file)" 2>/dev/null)" = "$mapping_before" ]
  check "compose up re-invoked"         [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"       calls_have "tailscale serve --bg --https=8094 http://127.0.0.1:8094/guacamole/$"
  check "re-verified by markup"         out_has "guacamole"
  teardown
}

test_stale_marker_dead_backend() {
  echo "• fingerprint says configured but RDP is dead: reconfigures anyway"
  # The failure a marker file invites. setup.sh skips the sudo block when its
  # $APPLIED fingerprint matches — but a matching fingerprint only records what
  # a PREVIOUS run asked for, and says nothing about whether the daemon is
  # still serving. If someone ran `grdctl --system rdp disable`, or the daemon
  # is wedged, a marker-only check hands back a green deploy with no desktop
  # behind it. The live RDP handshake is what makes the marker safe to keep.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy: marker written
  check "first run succeeded"       [ "$CODE" -eq 0 ]
  # ...now the backend goes away behind the script's back, marker intact.
  rm -f "$STATE_DIR/grd_rdp_enabled"
  : > "$CALLS_LOG"
  run_deploy
  check "noticed despite the marker" calls_have "grdctl.*rdp enable"
  check "  re-applied credentials"   calls_have "grdctl.*set-credentials"
  check "  and needed sudo to do it" calls_have "^sudo "
  check "exits zero once repaired"   [ "$CODE" -eq 0 ]
  teardown
}

test_grdctl_denied() {
  echo "• grdctl denied by polkit: fails LOUDLY and names the xrdp fallback"
  # This is not a hypothetical. It is exactly the wall the de-risking session
  # hit — sudo needs a password, the session was non-interactive — and it is
  # the most likely first-deploy failure. The requirement from the de-risk
  # doc is explicit: a failure here must be loud and must name the fallback,
  # rather than leaving a half-configured host.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/grd_enable_fails"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "names the backend"              out_has "gnome-remote-desktop\|grdctl\|rdp"
  check "does not claim success"         out_lacks "Done\."
  check "names the xrdp fallback"        out_has "xrdp"
  check "  points at TROUBLESHOOT.md"    out_has "troubleshoot"
  check "published nothing"              no_call "tailscale serve --bg"
  teardown
}

test_guacd_never_published() {
  echo "• guacd found listening on the host: hard failure"
  # guacd does not authenticate its callers. Anything that can reach 4822 can
  # ask it to proxy RDP to an arbitrary host with arbitrary credentials — the
  # webapp is the authenticator, and publishing guacd routes around it
  # completely. This is a worse exposure than the :3389 one and it is
  # entirely self-inflicted.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_guacd"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the guacd port"    out_hasF "4822"
  check "  explains the risk"     out_has "authenticat\|unauthenticated\|internal"
  teardown
}

test_webapp_escaped_loopback() {
  echo "• the webapp escaped loopback onto a LAN address: hard failure"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/listen_web_lan"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the port"        out_hasF "8094"
  check "  names the address"   out_hasF "192.168.88.11"
  teardown
}

# The nft ruleset setup.sh generates, as it was actually installed. Read from
# the `install` stub's shadow root — the real path is /etc/remote-desktop, and
# a mocked suite that wrote there would be changing what Kai's live box lets
# through, which is the exact opposite of hermetic.
fw_rules()      { sed 's/#.*//' "$STATE_DIR/rootfs/etc/remote-desktop/rdp-firewall.nft" 2>/dev/null; }
fw_rules_have() { fw_rules | grep -qE -- "$1"; }
fw_rules_lack() { ! fw_rules_have "$1"; }

test_rdp_wildcard_is_disclosed() {
  echo "• :3389 on the wildcard: DISCLOSED loudly, and mitigated"
  # The finding that shapes this whole service. gnome-remote-desktop 46 has no
  # bind-address control — verified exhaustively against grdctl --help and the
  # complete GSettings schema — so the wildcard is not something the deploy can
  # fix at the source. What it MUST do is (a) say so out loud, and (b) install
  # the packet filter. Proceeding quietly is the failure this catches: an
  # operator who is not told cannot make a decision about it.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check "mentions :3389"                     out_hasF "3389"
  check "  says the listener is wildcard"    out_has "0\.0\.0\.0"
  check "  says it cannot be changed"        out_has "no way to change\|cannot\|offers no way"
  check "  names the file that protects it"  out_hasF "rdp-firewall.nft"
  check "  warns what happens if disabled"   out_has "exposed to your whole LAN\|is exposed"
  check "a filter was installed"             [ -s "$STATE_DIR/rootfs/etc/remote-desktop/rdp-firewall.nft" ]
  teardown
}

test_filter_shape_and_ordering() {
  echo "• the :3389 filter: source-scoped, own table, installed BEFORE enable"
  # The mitigation is source-based (accept from loopback + the compose bridge,
  # reject everything else) rather than interface-based, and that is the better
  # shape for two concrete reasons this test pins down:
  #
  #   * An interface-named rule must enumerate every interface. This box has
  #     TWO LAN addresses (enp31s0 192.168.88.11, wlp30s0 192.168.88.13) and
  #     adding a third silently re-opens the hole.
  #   * An interface rule is unverifiable from this machine: Linux routes
  #     traffic aimed at the host's own LAN address over lo, so it never hits
  #     an inbound interface rule and the port looks open even when it is shut.
  #     Matching on SOURCE makes the deploy's own probes conclusive.
  #
  # And the opposite mistake matters as much: a blanket `tcp dport 3389 drop`
  # with no source exception takes guacd out along with the LAN, so the
  # mitigation breaks the service and the symptom ("remote desktop server is
  # currently unreachable") points at D1 rather than at the firewall.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "loopback is accepted"            fw_rules_have 'tcp dport 3389 ip +saddr 127\.0\.0\.0/8 accept'
  check "  IPv6 loopback too"             fw_rules_have 'ip6 +saddr ::1 +accept'
  check "the compose bridge is accepted"  fw_rules_have 'tcp dport 3389 ip +saddr 172\.28\.0\.0/24 accept'
  check "  and it matches GUAC_SUBNET"    fw_rules_have "saddr $(env_val GUAC_SUBNET | sed 's/\./\\./g') accept"
  check "everything else is rejected"     fw_rules_have 'tcp dport 3389 reject with tcp reset'
  # UDP/3389 carries RDP's UDP transport. Leaving it open would be a hole that
  # a TCP-only check never notices.
  check "UDP 3389 is dropped too"         fw_rules_have 'udp dport 3389 drop'
  # reject-with-reset rather than drop: a reset is what a CLOSED port sends, so
  # a scanner cannot tell RDP is running, and the deploy's own probes get a
  # clean refusal instead of hanging until timeout.
  check "rejects with a reset, not a bare drop on tcp" fw_rules_lack 'tcp dport 3389 drop'
  # Its OWN table: docker's and ufw's rulesets are untouched, so this cannot
  # break container networking or be wiped by `ufw reload`.
  check "lives in its own table"          fw_rules_have 'table inet remote_desktop'
  check "  idempotent (delete then add)"  fw_rules_have 'delete table inet remote_desktop'
  check "  never flushes the whole ruleset" fw_rules_lack 'flush ruleset'
  # NOT interface-scoped, deliberately — see the comment above.
  check "not interface-scoped"            fw_rules_lack 'iifname|oifname'
  # Enabled as a unit so it survives a reboot. A rule applied only by hand
  # vanishes on the next boot, and the exposure comes back silently.
  check "installed as a systemd unit"     [ -s "$STATE_DIR/rootfs/etc/systemd/system/remote-desktop-firewall.service" ]
  check "  enabled, not just started"     calls_have "systemctl enable --now remote-desktop-firewall"
  check "  ordered before the RDP daemon" \
    grep -q 'Before=gnome-remote-desktop.service' "$STATE_DIR/rootfs/etc/systemd/system/remote-desktop-firewall.service"

  # ── ORDERING: the filter must exist before anything can listen ──────────
  # If RDP were enabled first there would be a window, however short, in which
  # :3389 answered the whole LAN. Assert the order in the call log rather than
  # trusting the source to stay in this order.
  local fw_line enable_line
  fw_line="$(grep -n 'systemctl enable --now remote-desktop-firewall' "$CALLS_LOG" | head -1 | cut -d: -f1)"
  enable_line="$(grep -n 'grdctl --system rdp enable' "$CALLS_LOG" | head -1 | cut -d: -f1)"
  check "filter installed BEFORE rdp enable" \
    ordered_lines "$fw_line" "$enable_line"
  teardown
}

test_mitigation_failure_is_loud() {
  echo "• the filter unit will not start: DIES, and never enables RDP"
  # A sudo call that silently no-ops is exactly how a mitigation becomes a
  # comment in a file. The requirement here is stronger than "warn": if the
  # filter did not take, RDP must NOT be enabled, because enabling it would
  # put this box's desktop on the LAN. Failing closed is the whole point.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/fw_enable_fails"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "names the unit"                 out_has "remote-desktop-firewall"
  check "  RDP was NOT enabled"          no_call "grdctl.*rdp enable"
  check "  says nothing is exposed"      out_has "nothing is exposed"
  check "  does not claim success"       out_lacks "^Done\."
  check "published nothing"              no_call "tailscale serve --bg"
  teardown
}

test_filter_enables_but_dies() {
  echo "• the filter unit enables then falls over: still refuses to enable RDP"
  # The subtler half of the same requirement. `systemctl enable --now` can
  # return 0 while the oneshot unit fails immediately afterwards, which is why
  # setup.sh re-checks is-active rather than trusting the exit code.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/fw_dies"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "noticed it did not stay active" out_has "did not stay active\|not active"
  check "  RDP was NOT enabled"     no_call "grdctl.*rdp enable"
  teardown
}

test_rdp_leaks_despite_filter() {
  echo "• filter installed but :3389 STILL answers the LAN: hard failure"
  # The catastrophic case, and the one every other check would miss: the unit
  # is active, the rules file is on disk, the containers are up, the webapp
  # logs in — and the LAN can still open an RDP session. Only connecting from
  # the outside finds it. This is why setup.sh probes instead of reading `ss`.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/rdp_leaks"
  run_deploy
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says RDP is REACHABLE"       out_has "REACHABLE"
  check "  names a LAN address"       out_hasF "192.168.88.11"
  check "  names the other one too"   out_hasF "192.168.88.13"
  check "  and the tailnet address"   out_hasF "100.77.77.77"
  check "  blames the filter"         out_has "packet filter is not doing its job"
  check "  gives the diagnostic"      out_has "nft list table inet remote_desktop"
  check "summary reports failure"     out_has "Deploy finished with failures"
  teardown
}

test_filter_too_broad_blocks_guacd() {
  echo "• filter too broad — the bridge is blocked: caught, not shipped"
  # The opposite mistake from the leak above, and the more likely one. A
  # blanket drop on 3389 satisfies every security check and breaks the service:
  # guacd cannot reach the backend, so every session fails as "the remote
  # desktop server is currently unreachable" — a symptom that reads like a
  # dead backend and sends you debugging D1 instead of the firewall.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/bridge_blocked"
  run_deploy
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "names the bridge gateway"      out_hasF "172.28.0.1"
  check "  says guacd cannot connect"   out_has "guacd will not be able to connect\|not able to connect"
  check "  points at the subnet/gateway pair" out_has "GUAC_RDP_HOST\|GUAC_SUBNET"
  teardown
}

test_port_override() {
  echo "• GUAC_PORT override: honoured through compose, health check and serve"
  setup
  touch "$STATE_DIR/operator"
  echo 8095 > "$STATE_DIR/guac_port"
  export GUAC_PORT=8095
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check ".env records the override" grep -qx 'GUAC_PORT=8095' "$SVC/.env"
  check "health-checked :8095"      calls_have "127.0.0.1:8095"
  check "served :8095 -> :8095"     calls_have "tailscale serve --bg --https=8095 http://127.0.0.1:8095/guacamole/$"
  check "prints the :8095 URL"      out_hasF "test-host.tailfake.ts.net:8095"
  check "never touched :8094"       no_call "127.0.0.1:8094"
  teardown
}

test_compose_pool_overlap() {
  echo "• compose subnet collides with an existing bridge: names the real cause"
  # 172.17.0.0/16 through 172.27.0.0/16 are ALL already allocated on this box
  # (immich, seafile, home-assistant, forgejo, jellyfin and friends, measured
  # 2026-09-11). Docker's message — "Pool overlaps with other one on this
  # address space" — does not say which pool or whose, so a deploy that just
  # echoes it sends you looking in the wrong place.
  setup
  touch "$STATE_DIR/operator"
  echo pool > "$STATE_DIR/up_fail"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the collision"       out_has "overlap\|subnet\|pool"
  check "  suggests moving it"      out_has "subnet\|172\.\|10\."
  check "published nothing"         no_call "tailscale serve --bg"
  teardown
}

test_serve_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero"            [ "$CODE" -eq 0 ]
  check "granted operator"      calls_have "tailscale set --operator="
  check "eventually published"  calls_have "tailscale serve --bg --https=8094 http://127.0.0.1:8094/guacamole/$"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: prints the link, retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval link" out_hasF "login.tailscale.com"
  check "  waited for the human"    out_has "enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8094 http://127.0.0.1:8094/guacamole/$"
  teardown
}

test_https_front_door_slow() {
  echo "• tailnet HTTPS not answering yet: a warning, not a failed deploy"
  # First request on a newly-served port can take ~60s while the cert is
  # minted. Failing the deploy for that makes a correct run red.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/https_dead"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "warns about the cert"      out_has "cert\|minting\|retry"
  check "still verified locally"    out_has "guacamole"
  teardown
}

test_no_listener_audit_via_ss_at_all() {
  echo "• the audit never uses ss or lsof: it CONNECTS (and must keep doing so)"
  # Deliberate, and worth locking in. Every other service in this repo audits
  # its listeners by parsing `ss` output. That check is meaningless here: the
  # RDP port is wildcard-bound and cannot be otherwise, so `ss` will report
  # 0.0.0.0:3389 on a correctly-secured box forever. The only question with a
  # useful answer is "does anything answer from out there?", which means
  # opening a socket.
  #
  # This also removes the AGENTS.md portability trap (`ss` is GNU-only, and the
  # lsof fallback is fiddly) — not by adding a fallback, but by needing neither.
  # A future author "restoring consistency" with the other services would be
  # making this suite unable to see the one exposure that matters.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                   [ "$CODE" -eq 0 ]
  check "never called ss"              no_call "^ss "
  check "never called lsof"            no_call "^lsof "
  # ...and it really did ask the question, on every non-loopback address.
  check "probed 3389 on LAN (wired)"   calls_have "probe tcp 192.168.88.11 3389"
  check "probed 3389 on LAN (wifi)"    calls_have "probe tcp 192.168.88.13 3389"
  check "probed 3389 on the tailnet"   calls_have "probe tcp 100.77.77.77 3389"
  check "probed the webapp port too"   calls_have "probe tcp 192.168.88.11 8094"
  check "probed guacd's 4822"          calls_have "probe tcp 127.0.0.1 4822"
  # A real RDP handshake, not merely an open socket: a TCP proxy to nowhere
  # answers "open" and is not a desktop.
  check "spoke real RDP on loopback"   calls_have "probe rdp 127.0.0.1 3389"
  check "  and on the bridge gateway"  calls_have "probe rdp 172.28.0.1 3389"
  teardown
}

test_no_password_and_no_tty() {
  echo "• no RDP password and no TTY: refuses rather than inventing one"
  # GNOME's Remote Login hands these credentials to GDM to start a REAL login
  # session, so the password has to be one the system already accepts — most
  # likely RDP_USER's actual login password. setup.sh cannot generate one, and
  # a generated string would produce a deploy that passes every check here and
  # fails at the only moment that matters: when somebody tries to log in.
  #
  # So refusing is correct. This case exists because the harness sets
  # RDP_PASSWORD by default (there is no TTY in a test run), which masks the
  # refusal everywhere else.
  setup
  unset RDP_PASSWORD
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "names the variable"           out_hasF "RDP_PASSWORD"
  check "  says there is no terminal"  out_has "no terminal to prompt on"
  check "  tells you how to fix it"    out_has "and re-run"
  # It got far enough to write .env — that is the point of the message, since
  # the fix is to edit the file it just created.
  check ".env was still written"       [ -f "$SVC/.env" ]
  check "  with an empty RDP_PASSWORD" grep -qx 'RDP_PASSWORD=' "$SVC/.env"
  # Nothing was configured or exposed.
  check "never enabled RDP"            no_call "grdctl.*rdp enable"
  check "published nothing"            no_call "tailscale serve --bg"
  export RDP_PASSWORD=test-rdp-password
  teardown
}

test_rdp_never_comes_up() {
  echo "• the backend never speaks RDP: dies loudly, names the xrdp fallback"
  # THE unknown of this whole service. Nobody has ever established an RDP
  # session on this box — not these tests, not anyone — so "GNOME's headless
  # Remote Login does not work on this host" is a live possibility rather than
  # a hypothetical. The de-risk note's requirement is explicit: a failure here
  # must be loud and must name the fallback, rather than leaving a
  # half-configured host behind.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/rdp_never_ready"
  run_deploy
  check "exits non-zero"                 [ "$CODE" -ne 0 ]
  check "says it is not speaking RDP"    out_has "not speaking RDP"
  check "  admits this was untested"     out_has "could not test\|real unknown"
  check "  gives the journal command"    out_has "journalctl -u gnome-remote-desktop"
  check "  names the xrdp fallback"      out_has "xrdp"
  check "  points at TROUBLESHOOT.md"    out_has "TROUBLESHOOT.md"
  check "  says how to undo this one"    out_has "rdp disable"
  check "  confirms nothing is exposed"  out_has "nothing is exposed\|filter is installed"
  check "published nothing"              no_call "tailscale serve --bg"
  teardown
}

test_something_else_on_3389() {
  echo "• something answers 3389 but is not RDP: not mistaken for success"
  # An open socket is not an RDP server. A TCP proxy, a stray container
  # publish, or a different service on the port all answer "open" — which is
  # why setup.sh speaks the first packet of the X.224 handshake and requires an
  # RDP Connection Confirm back. Without that, the deploy would hand over a
  # green result and a connection that fails in the browser.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/rdp_not_rdp"
  run_deploy
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "reports the probe verdict"   out_hasF "not-rdp"
  check "  did not call it healthy"   out_lacks "^Done\."
  teardown
}

test_guacamole_login_rejected() {
  echo "• user-mapping hash disagrees with .env: caught, and no retry loop"
  # A webapp that renders perfectly and rejects the only credentials anybody
  # has is the deploy most likely to be called "working". setup.sh POSTs to
  # /api/tokens with the generated password for exactly this reason.
  #
  # Exactly ONE attempt: Guacamole bans an address for 300s after 5 failures,
  # so a retry loop around a rejection turns a stale .env into a lockout.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/guac_login_fails"
  run_deploy
  check "exits non-zero"               [ "$CODE" -ne 0 ]
  check "says the login was rejected"  out_has "rejected"
  check "  names the file to fix"      out_hasF "user-mapping.xml"
  check "  gives the regenerate recipe" out_has "rm.*user-mapping.xml"
  check "  warns about the 5-try ban"  out_has "300s\|do not retry"
  check "tried the token endpoint once" [ "$(call_count '/api/tokens')" -eq 1 ]
  teardown
}

test_connection_missing_from_list() {
  echo "• login works but no RDP connection is listed: caught"
  # Authentication succeeding proves the <authorize> block parsed. It says
  # nothing about whether the <connection> inside it did — and a user-mapping
  # with a valid login and a malformed connection logs you into an empty
  # Guacamole with nothing to click.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/guac_no_connection"
  run_deploy
  check "exits non-zero"             [ "$CODE" -ne 0 ]
  check "says the login DID work"    out_has "Browser login"
  check "  but no connection shows"  out_has "no RDP connection"
  check "  points at the file"       out_hasF "user-mapping.xml"
  teardown
}

test_container_not_running() {
  echo "• a container exited: failure, with the logs command"
  setup
  touch "$STATE_DIR/operator"
  echo exited > "$STATE_DIR/guacd_status"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the state"         out_has "exited"
  check "gives the logs command"  out_has "logs"
  teardown
}

# ------------------------------------------------- sandbox integrity proof
# Recorded before the mocked suite runs, checked after. A mocked suite that
# quietly wrote to ~/services/remote-desktop, or reconfigured the RDP backend
# on the real box, would be worse than no suite at all — and on THIS service a
# stray run could take the display manager with it, which is not recoverable
# over a tailnet.
HOST_SNAPSHOT=""
snapshot_host() {
  local f
  HOST_SNAPSHOT=""
  for f in "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" \
           "$SERVICE_DIR/SETUP.md" "$SERVICE_DIR/TROUBLESHOOT.md" \
           "$SERVICE_DIR/.env" "$ORIG_HOME/services/remote-desktop" \
           /etc/polkit-1/rules.d /etc/xrdp; do
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
  check "HOME restored"  [ "$HOME" = "$ORIG_HOME" ]
  check "repo files, ~/services/remote-desktop, polkit and xrdp config unchanged" \
    [ "$before" = "$HOST_SNAPSHOT" ]
  if [ "$before" != "$HOST_SNAPSHOT" ]; then
    red "      before:$before"
    red "      after: $HOST_SNAPSHOT"
  fi
}

# ═══════════════════════════════════════════════════════════════════ live
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
# ⚠️ The Tailscale allowance is load-bearing here for a boring reason: this
# service publishes HTTPS on the SAME number as the local port (8094 -> 8094),
# so tailscaled itself legitimately listens on the tailnet IP for :8094. The
# services that map across numbers (e.g. immich 2283, open-webui 10000 -> 3001)
# never hit that overlap, which is why their simpler "anything not 127.0.0.1"
# reading of this function would false-positive here.
#
# The function body below is byte-identical to immich's, vaultwarden's,
# jellyfin's and adguard's on purpose — it is the canonical implementation and
# `diff` between any two of them should be empty. Do not "improve" it in one
# service only.
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

# This host's LAN addresses — DISCOVERED, never hardcoded. This box has two
# (enp31s0 and wlp30s0) and a mitigation written for one leaves the other
# open, so a suite that assumed a single address would report "secure" while
# half the exposure was untested.
#
# Excludes loopback, the tailnet address and every docker bridge: those are
# host-internal or inside the trust boundary, and flagging them would train
# you to ignore this check.
lan_addresses() {
  local ts4 addr
  ts4="$(tailscale ip -4 2>/dev/null || true)"
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '{print $2" "$4}' \
      | sed 's#/[0-9]*##' \
      | awk '$1 !~ /^(lo|tailscale|docker|br-|veth)/ {print $2}'
  else
    # macOS / BSD
    ifconfig 2>/dev/null | awk '/^[a-z]/{ifc=$1} /inet /{print ifc" "$2}' \
      | awk '$1 !~ /^(lo|utun|bridge|tailscale)/ {print $2}'
  fi | while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    [ "$addr" = "127.0.0.1" ] && continue
    [ -n "$ts4" ] && [ "$addr" = "$ts4" ] && continue
    printf '%s\n' "$addr"
  done
}

# Can a TCP connection to <host>:<port> be ESTABLISHED from this box?
# Returns 0 when it CANNOT (refused, filtered, timed out) — i.e. 0 means
# "closed", which is the answer the security checks want.
#
# ⚠️ READ THIS CAVEAT. A probe originating on this host is not the same
# experiment as a probe from the LAN. Linux routes traffic addressed to the
# box's own LAN IP over `lo`, so a mitigation written as
# `iptables -A INPUT -i enp31s0 ...` never matches a local probe and the port
# will appear OPEN here even when it is genuinely blocked from outside.
# The converse does not hold: if the local probe is REFUSED, the port really
# is unreachable. So a pass is conclusive and a failure is a prompt to check
# from another machine, not a verdict. test_live prints that instruction
# whenever a probe connects.
tcp_closed() {  # tcp_closed <host> <port>
  local host="$1" port="$2" pid i rc
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && return 1
    return 0
  fi
  # No nc: bash's /dev/tcp with a watchdog, since a DROPped port hangs
  # indefinitely rather than answering — and a test that hangs is a test
  # nobody runs.
  ( exec 3<>"/dev/tcp/$host/$port" ) >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 0                       # still hanging => filtered => closed
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 1      # connected => open
  return 0                         # refused => closed
}

# Does the URL return actual Guacamole markup, as opposed to merely a 200?
serves_guacamole_markup() {  # serves_guacamole_markup <url>
  # The same two markers setup.sh asserts, and for the same reason: a 200 is
  # not a health check. Tomcat returns 200 for its default ROOT app, a stale
  # WAR, or a proxy answering on your behalf.
  #
  # Both markers were verified against the SHIPPED artifact — index.html
  # extracted from guacamole.war inside guacamole/guacamole:1.6.0 (2811
  # bytes) — not from memory. They sit on the opening <html> tag:
  #
  #   <!doctype html><html ng-app="index" ng-controller="indexController">
  #
  # Things that are NOT in that file and must not be asserted: the string
  # "guacamole.min.js", and a populated <title> (the real title is empty and
  # ng-bind-filled, so any title-based check is unfixable).
  local body
  body="$(curl -s --max-time 30 "$1" 2>/dev/null)" || return 1
  printf '%s' "$body" | grep -qF 'ng-app="index"' || return 1
  printf '%s' "$body" | grep -qF 'indexController' || return 1
  # Tomcat's own pages say "Apache Tomcat/<version>" and nothing else does.
  printf '%s' "$body" | grep -qF 'Apache Tomcat/' && return 1
  return 0
}

test_live() {
  echo "• live: verify the real deployment on this machine"

  # Without the docker group every `docker inspect` fails and the container
  # checks report "not running" for a perfectly healthy stack. Say so, rather
  # than letting red lines imply an outage. A shell started before the user
  # was added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run under: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  if [ ! -f "$SERVICE_DIR/.env" ]; then
    red "    ! no $SERVICE_DIR/.env — this service is not deployed on this box."
    red "      Deploy first: cd $SERVICE_DIR && ./setup.sh"
    FAIL=$((FAIL + 1))
    return
  fi

  local ts port url ts4 rdp_host lan addr any_open=0
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^GUAC_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env" | head -1)"
  port="${port:-8094}"
  rdp_host="$(sed -n 's/^GUAC_RDP_HOST=//p' "$SERVICE_DIR/.env" | head -1)"
  ts4="$("$ts" ip -4 2>/dev/null | head -1)"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  # ── containers ───────────────────────────────────────────────────────
  live_check "guacd container running" \
    sh -c "docker inspect -f '{{.State.Status}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacd) | grep -qx running"
  live_check "guacamole container running" \
    sh -c "docker inspect -f '{{.State.Status}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacamole) | grep -qx running"
  live_check "  guacd image pinned to 1.6.0, not :latest" \
    sh -c "docker inspect -f '{{.Config.Image}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacd) | grep -qx 'guacamole/guacd:1.6.0'"
  live_check "  webapp image pinned to 1.6.0, not :latest" \
    sh -c "docker inspect -f '{{.Config.Image}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacamole) | grep -qx 'guacamole/guacamole:1.6.0'"
  # 7.7 GB total with 1.9 GB of swap already in use: an unbounded JVM here is
  # not a theoretical concern.
  live_check "  guacd has a memory limit" \
    sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacd))\" != 0 ]"
  live_check "  webapp has a memory limit" \
    sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' \$(docker compose --project-directory '$SERVICE_DIR' ps -q guacamole))\" != 0 ]"
  # File auth is the whole reason this is two containers and not four.
  live_check "no database container in the project" \
    sh -c "! docker compose --project-directory '$SERVICE_DIR' ps --format '{{.Image}}' | grep -qiE 'postgres|mysql|mariadb'"

  # ── local health: MARKUP, not a status code ──────────────────────────
  live_check "webapp serves real Guacamole markup on 127.0.0.1:$port" \
    serves_guacamole_markup "http://127.0.0.1:$port/guacamole/"
  live_check "not listening on non-local ifaces (:$port)" no_external_listener "$port"
  # ⚠️ no_external_listener is applied to the WEBAPP port only, and never to
  # 3389. That is deliberate. The canonical helper answers "is this socket
  # bound to loopback or the tailnet address?", and for the RDP port the answer
  # is permanently "no": gnome-remote-desktop binds the wildcard and cannot be
  # told otherwise. Running it against 3389 would produce a red line on a
  # correctly-secured box, every time, which is how a suite teaches people to
  # ignore it. The exposure probes below ask the question that has a useful
  # answer instead.

  # ── guacd is invisible ───────────────────────────────────────────────
  # Not "guacd is on loopback" — guacd does not authenticate its callers at
  # all, so the requirement is that it is not on the host in any form. Asked
  # as a CONNECTION rather than by parsing `ss`, matching setup.sh: a port
  # mapping that ss renders in an unexpected shape cannot fool a socket.
  live_check "guacd (:4822) refuses on loopback (container-internal)" \
    tcp_closed 127.0.0.1 4822

  # ── publish ──────────────────────────────────────────────────────────
  live_check "tailscale serve maps :$port" \
    sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  # NOTE the bare path. setup.sh serves http://127.0.0.1:$port/guacamole/ as
  # the target, and Tailscale rewrites the prefix, so the tailnet URL is a
  # clean https://host:PORT/ . Asking for /guacamole/ here would 404 and look
  # like an outage.
  live_check "tailnet HTTPS serves Guacamole markup at /" \
    serves_guacamole_markup "$url:$port/"

  # ── the exposure question ────────────────────────────────────────────
  # The part of this suite that exists because of a measured finding rather
  # than a convention. gnome-remote-desktop 46 has NO bind-address control
  # (grdctl --help + the complete gsettings schema, checked on this box), so
  # :3389 is on the wildcard and only a packet filter keeps it off the LAN.
  # Read a config file and you learn what someone intended. Open a socket and
  # you learn what is true.
  echo "    — exposure probes (real TCP connections):"

  for addr in $(lan_addresses); do
    live_check "  :3389 refuses on LAN $addr"      tcp_closed "$addr" 3389
    tcp_closed "$addr" 3389 || any_open=1
    live_check "  :$port refuses on LAN $addr"     tcp_closed "$addr" "$port"
    tcp_closed "$addr" "$port" || any_open=1
    live_check "  :4822 refuses on LAN $addr"      tcp_closed "$addr" 4822
  done

  if [ -n "$ts4" ]; then
    # 3389 on the tailnet address is still wrong: the design routes tailnet
    # peers through Guacamole on :$port, and guacd reaches the backend over
    # the host-internal bridge gateway. Nothing else should be able to open a
    # raw RDP socket, tailnet or not — a second, weaker front door is not a
    # feature.
    live_check "  :3389 refuses on the tailnet address $ts4" tcp_closed "$ts4" 3389
    tcp_closed "$ts4" 3389 || any_open=1
    live_check "  :4822 refuses on the tailnet address $ts4" tcp_closed "$ts4" 4822
    # :$port on the tailnet address is EXPECTED to accept — that is
    # tailscaled's TLS front door, since serve maps 8094 -> 8094 and the
    # numbers overlap. What must NOT be true is that the raw Tomcat is there:
    # plain HTTP to it must fail, because tailscaled is speaking TLS.
    live_check "  :$port on $ts4 is the TLS front door, not raw Tomcat" \
      sh -c "! curl -s --max-time 10 'http://$ts4:$port/guacamole/' | grep -qi guacamole"
  fi

  if [ -n "$rdp_host" ] && [ "$rdp_host" != "127.0.0.1" ]; then
    # The D1 hop. It MUST be probed from a container on the guacamole bridge,
    # not from the host: a host-originated connection to this box's own bridge
    # gateway is routed over `lo` and carries a loopback source, so it never
    # matches the rule's `ip saddr $GUAC_SUBNET` exception and is rejected —
    # on a perfectly correct deploy. Probing from the host reported "guacd's
    # route is CLOSED" against a filter that was in fact working, which is the
    # same cry-wolf failure as a check that can never pass.
    #
    # Verified on the real deploy: from the host, 172.28.0.1:3389 is refused;
    # from a container on the bridge (source 172.28.0.4), it is OPEN.
    bridge_net="$(docker inspect guacd \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)"
    rdp_from_bridge() {  # answers the question guacd would ask
      [ -n "$bridge_net" ] || return 2
      docker run --rm --network "$bridge_net" alpine \
        nc -w 3 -z "$rdp_host" 3389 >/dev/null 2>&1
    }
    # The bridge gateway must answer, or guacd cannot reach the backend and
    # every session fails as "the remote desktop server is currently
    # unreachable".
    #
    # This is the check that catches the OPPOSITE mistake from the ones above:
    # a filter written too broadly (a blanket `tcp dport 3389 reject` with no
    # source exception) drops the bridge traffic as well as the LAN traffic, so
    # the mitigation silently breaks the service it was added to protect. Both
    # directions have to be asserted, or "secure" and "working" trade places
    # without anyone noticing.
    if rdp_from_bridge; then
      PASS=$((PASS + 1))
      green "    ✓   guacd's route to the backend ($rdp_host:3389) is open (probed from the bridge)"
    elif [ $? -eq 2 ]; then
      note  "    →   could not determine guacd's bridge network; skipping the D1 probe"
    else
      FAIL=$((FAIL + 1))
      red   "    ✗   guacd's route to the backend ($rdp_host:3389) is CLOSED"
      red   "        Likely a filter with no source exception for the bridge:"
      red   "        it is rejecting guacd along with the LAN. /etc/remote-desktop/"
      red   "        rdp-firewall.nft must accept ip saddr \$GUAC_SUBNET, and"
      red   "        GUAC_RDP_HOST must be that subnet's .1 gateway."
    fi
  fi

  # ── the RDP backend, reported rather than asserted ───────────────────
  if [ "$OS" = "Linux" ]; then
    live_check "gnome-remote-desktop unit is active" \
      sh -c "systemctl is-active gnome-remote-desktop | grep -qx active"
    live_check "  and enabled" \
      sh -c "systemctl is-enabled gnome-remote-desktop | grep -qx enabled"
  fi

  # ── state on disk ────────────────────────────────────────────────────
  local state home mapping
  state="$(sed -n 's/^GUAC_STATE=//p' "$SERVICE_DIR/.env" | head -1)"
  home="$(sed -n 's/^GUAC_HOME=//p' "$SERVICE_DIR/.env" | head -1)"
  mapping="$home/user-mapping.xml"
  live_check "state dir exists"            test -d "$state"
  live_check "  GUAC_HOME exists"          test -d "$home"
  # 0700/0600 are load-bearing, not hygiene: user-mapping.xml holds the RDP
  # password in PLAINTEXT (Guacamole has to replay it to the RDP server, so it
  # cannot be hashed). World-readable here means the login password is too.
  live_check "  GUAC_HOME is 0700"         sh -c "[ \"\$(stat -c '%a' '$home' 2>/dev/null || stat -f '%Lp' '$home')\" = 700 ]"
  live_check "  user-mapping.xml is there" test -f "$mapping"
  live_check "  and is 0600"               sh -c "[ \"\$(stat -c '%a' '$mapping' 2>/dev/null || stat -f '%Lp' '$mapping')\" = 600 ]"
  live_check "  browser password is hashed, not plaintext" \
    sh -c "! grep -qF \"\$(sed -n 's/^GUAC_PASSWORD=//p' '$SERVICE_DIR/.env' | head -1)\" '$mapping'"
  # Session recording is off: disk with no backup job behind it.
  live_check "  no recordings directory (recording stays off)" \
    test ! -d "$state/recordings"
  # No drive/ either. gnome-remote-desktop does not implement the rdpdr
  # channel, so drive redirection is not available with this backend at all —
  # PLAN.md's enable-drive step applies to xrdp and would be a switch that
  # does nothing here. The directory's absence is the honest state.
  live_check "  no drive directory (no rdpdr in this backend)" \
    test ! -d "$state/drive"

  # ── the packet filter, as a unit ─────────────────────────────────────
  # The nft ruleset itself cannot be read without sudo, so this asserts the
  # unit that applies it and leaves the ruleset to the probes above — which is
  # the better evidence anyway: behaviour over configuration.
  if [ "$OS" = "Linux" ]; then
    live_check "remote-desktop-firewall.service is active" \
      sh -c "systemctl is-active remote-desktop-firewall.service | grep -qx active"
    live_check "  and enabled (survives a reboot)" \
      sh -c "systemctl is-enabled remote-desktop-firewall.service | grep -qx enabled"
    live_check "  its ruleset file is present" test -f /etc/remote-desktop/rdp-firewall.nft
  fi

  # ── things this suite CANNOT tell you ────────────────────────────────
  echo
  note "    ⚠️  What a green run here does NOT prove:"
  note "       • That anyone can actually get a desktop. No RDP session has"
  note "         ever been established on this box — not by these tests, not"
  note "         by anyone. Every check above is about plumbing."
  note "       • That the RDP backend is configured as intended. Reading that"
  note "         needs 'sudo grdctl --system status', which needs a password,"
  note "         so the suite does not run it. Run it yourself."
  note "       • That :3389 is closed FROM THE LAN. A probe from this box"
  note "         cannot see through an interface-scoped rule: traffic to this"
  note "         host's own LAN address is routed over lo and never hits the"
  note "         inbound rule. A refusal above is conclusive; a connection is"
  note "         not necessarily an exposure."
  if [ "$any_open" = "1" ]; then
    echo
    red  "    ⚠️  At least one exposure probe CONNECTED. Settle it from another"
    red  "        machine on 192.168.88.0/24 — this is the definitive test:"
    for addr in $(lan_addresses); do
      red "          nc -vz $addr 3389"
    done
    red  "        'Connection refused' or a timeout on every one = mitigated."
    red  "        'succeeded' on any one = your desktop is reachable from the LAN."
  fi
}

# ══════════════════════════════════════════════════════════════════ main
if [ ! -f "$SERVICE_DIR/setup.sh" ]; then
  red "remote-desktop/setup.sh is missing — nothing to test."
  red "It is owned by the deploy side; this suite tests it, it does not write it."
  exit 1
fi
if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "remote-desktop/docker-compose.yml is missing — nothing to test."
  exit 1
fi

echo "Mocked suite (sandboxed, no system changes):"
snapshot_host
test_preflight_root
test_preflight_darwin
test_preflight_no_docker
test_preflight_docker_perms
test_preflight_tailscale_down
test_no_password_and_no_tty
test_fresh_deploy
test_health_check_is_not_a_200
test_health_check_404
test_readiness_race
test_never_ready
test_guacamole_login_rejected
test_connection_missing_from_list
test_idempotent_rerun_needs_no_sudo
test_stale_marker_dead_backend
test_grdctl_denied
test_rdp_never_comes_up
test_something_else_on_3389
test_guacd_never_published
test_webapp_escaped_loopback
test_rdp_wildcard_is_disclosed
test_filter_shape_and_ordering
test_mitigation_failure_is_loud
test_filter_enables_but_dies
test_rdp_leaks_despite_filter
test_filter_too_broad_blocks_guacd
test_port_override
test_compose_pool_overlap
test_serve_operator_escalation
test_serve_approval_prompt
test_https_front_door_slow
test_no_listener_audit_via_ss_at_all
test_container_not_running
test_sandbox_was_hermetic

if [ "${1:-}" = "--live" ]; then
  echo
  test_live
fi

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
  note  "Mocked-green is mocked: no sudo-gated step of this deploy has ever"
  note  "been executed, and nobody has ever completed an RDP session on this"
  note  "box. See the header of this file for the full list."
else
  red "$FAIL of $((PASS + FAIL)) checks failed."
  exit 1
fi
