#!/usr/bin/env bash
#
# Tests for services/remote-desktop/setup.sh and teardown.sh.
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
  [ -f "$SERVICE_DIR/teardown.sh" ] && cp "$SERVICE_DIR/teardown.sh" "$SVC/"
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

# Per-connection views. The repair is scoped to the connection setup.sh
# generated, identified by the backend it dials, so "the file contains nla"
# is too weak an assertion to tell a correct repair from one that reached
# into a connection the user added. conn_block prints the one <connection>
# whose body contains the literal (a hostname param, in practice), wherever
# it sits in the file. These are functions run in the PARENT shell on
# purpose: a `sh -c "... $(helper) ..."` would call them in a child that has
# never heard of them, which is exactly how the syncthing suite grew a check
# that could never fail.
conn_block() {  # conn_block LITERAL -> the <connection>...</connection> containing it
  awk -v want="$1" '
    index($0, "<connection")   { n = 0; inb = 1 }
    inb                        { buf[n++] = $0 }
    index($0, "</connection>") { hit = 0
                                 for (i = 0; i < n; i++) if (index(buf[i], want)) hit = 1
                                 if (hit) for (i = 0; i < n; i++) print buf[i]
                                 inb = 0 }' "$(mapping_file)" 2>/dev/null
}
conn_has()   { conn_block "$1" | grep -qF -- "$2"; }
conn_lacks() { ! conn_block "$1" | grep -qF -- "$2"; }
conn_exists() { [ -n "$(conn_block "$1")" ]; }

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
  # gnome-remote-desktop is NLA-only; 'tls' fails negotiation before the
  # credentials are checked and the browser shows "Log in failed". Found on
  # the first real session -- this suite had no assertion on the mode at all.
  check "  security mode is nla (the only one the backend accepts)" \
    mapping_has '<param name="security">nla</param>'
  # FreeRDP 2.11.7 (what guacd ships) advertises AUDIO_PLAYBACK v6, which
  # gnome-remote-desktop rejects mid-session -- "Client protocol version (6)
  # too old". Audio must stay off until guacd moves to FreeRDP 3.x.
  check "  audio disabled (FreeRDP 2.x AUDIO_PLAYBACK is too old for the server)" \
    mapping_has '<param name="disable-audio">true</param>'
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

test_mapping_migration() {
  echo "• re-run against a mapping from an older deploy: tls->nla and disable-audio repaired, then left alone"
  # A user-mapping.xml written by the first version of this script says
  # security=tls (the backend rejects it before checking credentials) and has
  # no disable-audio (the session drops when audio starts). "Written only if
  # absent" would leave both broken forever; the repair must be surgical --
  # those two values, nothing else in the user's file -- and Guacamole caches
  # parameters at login, so the webapp must be restarted for it to matter.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy, current template
  check "first run succeeded"           [ "$CODE" -eq 0 ]
  local m; m="$(mapping_file)"
  sed -e 's#<param name="security">nla</param>#<param name="security">tls</param>#' \
      -e '/<param name="disable-audio">/d' "$m" > "$m.old" && cat "$m.old" > "$m" && rm -f "$m.old"
  echo '<!-- my-custom-marker -->' >> "$m"
  check "setup: mapping now says tls"   mapping_has '<param name="security">tls</param>'
  check "setup: and has no disable-audio" sh -c "! grep -qF 'disable-audio' '$m'"
  : > "$CALLS_LOG"

  run_deploy                                   # second deploy: the repair
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "security repaired to nla"      mapping_has '<param name="security">nla</param>'
  check "  tls gone"                    sh -c "! grep -qF 'name=\"security\">tls' '$m'"
  check "  said so"                     out_has "Repaired security=tls"
  check "disable-audio added"           mapping_has '<param name="disable-audio">true</param>'
  check "  said so"                     out_has "Added disable-audio"
  check "  anchored inside the connection (after ignore-cert)" \
    sh -c "grep -A1 'ignore-cert' '$m' | grep -qF 'disable-audio'"
  check "user's other content kept"     mapping_has 'my-custom-marker'
  check "  still 0600"                  [ "$(file_mode "$m")" = "600" ]
  check "  hash still matches .env"     out_has "matches GUAC_PASSWORD"
  check "webapp restarted to pick it up" calls_have "docker compose .*restart guacamole"
  check "no sudo for a mapping repair"  no_call "^sudo "

  local after; after="$(cksum < "$m")"
  : > "$CALLS_LOG"
  run_deploy                                   # third deploy: nothing to repair
  check "third run: exits zero"         [ "$CODE" -eq 0 ]
  check "third run: mapping byte-identical" [ "$(cksum < "$m")" = "$after" ]
  check "third run: no restart"         no_call "restart guacamole"
  no_repair_msg() { ! grep -qiE 'Repaired security|Added disable-audio' <<<"$OUT"; }
  check "third run: no repair message"  no_repair_msg

  # A hand-chosen mode is the user's, not this script's: `any` is left alone.
  sed 's#<param name="security">nla</param>#<param name="security">any</param>#' "$m" > "$m.new" && cat "$m.new" > "$m" && rm -f "$m.new"
  run_deploy
  check "security=any (hand-chosen) untouched" mapping_has '<param name="security">any</param>'

  # A connection YOU added is not this script's to repair. The file's own
  # header invites extra connections, and one pointing at a Windows host
  # legitimately wants security=tls -- rewriting it to nla would break a
  # connection setup.sh never wrote, to reach a server that never asked for
  # NLA. Put the generated connection back on tls, strip its disable-audio,
  # then add two connections that want tls: one ABOVE the generated one and
  # one below. The one above is the case that breaks any repair keyed on
  # position -- it would be rewritten while the generated one stayed broken.
  local ours; ours="<param name=\"hostname\">$(env_val GUAC_RDP_HOST)</param>"
  sed -e 's#<param name="security">any</param>#<param name="security">tls</param>#' \
      -e '/<param name="disable-audio">/d' "$m" > "$m.new" && cat "$m.new" > "$m" && rm -f "$m.new"
  awk '/<authorize / && !top {
         print
         print "        <connection name=\"prepended box\">"
         print "            <protocol>rdp</protocol>"
         print "            <param name=\"hostname\">10.0.0.5</param>"
         print "            <param name=\"port\">3389</param>"
         print "            <param name=\"security\">tls</param>"
         print "            <param name=\"ignore-cert\">true</param>"
         print "        </connection>"
         top = 1; next
       }
       /<\/authorize>/ && !bottom {
         print "        <connection name=\"windows box\">"
         print "            <protocol>rdp</protocol>"
         print "            <param name=\"hostname\">10.0.0.6</param>"
         print "            <param name=\"port\">3389</param>"
         print "            <param name=\"security\">tls</param>"
         print "            <param name=\"ignore-cert\">true</param>"
         print "        </connection>"
         bottom = 1
       }
       { print }' "$m" > "$m.new" && cat "$m.new" > "$m" && rm -f "$m.new"
  check "setup: a user connection sits above the generated one" \
    sh -c "grep -n 'hostname\">10.0.0.5' '$m' | cut -d: -f1 | head -1 | xargs -I{} test {} -lt \$(grep -n 'hostname\">$(env_val GUAC_RDP_HOST)' '$m' | cut -d: -f1 | head -1)"

  run_deploy
  check "second run repairs only the generated connection" [ "$CODE" -eq 0 ]
  check "  generated connection is nla"      conn_has "$ours" '<param name="security">nla</param>'
  check "  and got disable-audio"            conn_has "$ours" '<param name="disable-audio">true</param>'
  check "  the one ABOVE it keeps tls"       conn_has 'hostname">10.0.0.5' '<param name="security">tls</param>'
  check "    and was NOT given nla"          conn_lacks 'hostname">10.0.0.5' '<param name="security">nla</param>'
  check "    and got no disable-audio"       conn_lacks 'hostname">10.0.0.5' 'disable-audio'
  check "  the one BELOW it keeps tls"       conn_has 'hostname">10.0.0.6' '<param name="security">tls</param>'
  check "    and was NOT given nla"          conn_lacks 'hostname">10.0.0.6' '<param name="security">nla</param>'
  check "    and got no disable-audio"       conn_lacks 'hostname">10.0.0.6' 'disable-audio'
  check "  both are still there"             conn_exists 'name="prepended box"'
  check "    (and the other)"                conn_exists 'name="windows box"'
  check "  said which connection it fixed"   out_has "connection to $(env_val GUAC_RDP_HOST):3389"

  # And the run after that must not come back for it: with the generated
  # connection already on nla, the only tls left in the file is the user's.
  local settled; settled="$(cksum < "$m")"
  : > "$CALLS_LOG"
  run_deploy
  check "third run leaves the file alone" [ "$(cksum < "$m")" = "$settled" ]
  check "  and says nothing about tls"    no_repair_msg
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
  check "  and the tailnet address"   out_hasF "$FAKE_TS_IP"
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
  check "probed 3389 on the tailnet"   calls_have "probe tcp $FAKE_TS_IP 3389"
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
# ═══════════════════════════════════════════════════════════════ teardown
# teardown.sh, default path = what the launcher's Remove runs: no terminal,
# no sudo. It must take down Serve + the two containers and leave EVERY
# system-level piece alone, the packet filter above all (the RDP listener is
# still up and wildcard-bound). --system is the terminal-only path that backs
# the system half out, listener first; it needs a tty, so those cases run
# under a pty from the REAL python3's pty module (resolved before any stub
# is on PATH). util-linux `script` was tried first and hung now and then
# when the child exited under load; pty.spawn returns on the child's EIO.
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+$1} 2>&1)"
  CODE=$?
}

REAL_PY="$(command -v python3 2>/dev/null || true)"
have_pty() { [ -n "$REAL_PY" ] && "$REAL_PY" -c 'import pty, os; os.waitstatus_to_exitcode' 2>/dev/null; }

run_teardown_tty() {  # run_teardown_tty "<args>" [stdin]
  # shellcheck disable=SC2086  # $1 is a deliberate word list of flags
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" timeout 120 "$REAL_PY" -c '
import os, pty, sys
sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash "$SVC/teardown.sh" $1 2>&1)"
  CODE=$?
}

state_dir() { env_val GUAC_STATE; }
rootfs()    { printf '%s/rootfs%s' "$STATE_DIR" "$1"; }
line_of()   { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1; }

# A deployed sandbox: setup.sh has run (filter installed, RDP enabled, cert
# in the shadow /var/lib), Serve maps this port to this service's /guacamole/
# path, and neighbours sit on other ports (one a lookalike suffix, one a
# lookalike PREFIX: 127.0.0.1:80940 starts with 127.0.0.1:8094).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8094 (tailnet only)
|-- / proxy http://127.0.0.1:8094/guacamole/

https://test-host.tailfake.ts.net:18094 (tailnet only)
|-- / proxy http://127.0.0.1:18094/guacamole/

https://test-host.tailfake.ts.net:9094 (tailnet only)
|-- / proxy http://127.0.0.1:80940/guacamole/
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

system_half_intact() {
  [ -f "$STATE_DIR/fw_installed" ] && [ -f "$STATE_DIR/fw_unit_enabled" ] &&
  [ -f "$STATE_DIR/grd_rdp_enabled" ] &&
  [ -f "$(rootfs /etc/remote-desktop/rdp-firewall.nft)" ] &&
  [ -f "$(rootfs /etc/systemd/system/remote-desktop-firewall.service)" ] &&
  [ -f "$(rootfs /var/lib/gnome-remote-desktop/certificates/rdp-tls.key)" ]
}

test_teardown_safe() {
  echo "• teardown: safe remove = Serve + containers only; the filter keeps guarding :3389"
  deployed
  check "deploy left the system half in place" system_half_intact
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "serve off for :8094"           calls_have "tailscale serve --https=8094 off"
  check "neighbour :2283 untouched"     no_call "https=2283"
  check "suffix lookalike :18094 untouched" no_call "https=18094"
  check "prefix lookalike :9094 untouched"  no_call "https=9094"
  check "never serve reset"             no_call "serve reset"
  check "compose down"                  [ -f "$STATE_DIR/compose_down" ]
  check "  in this service's project dir" grep -q -- "--project-directory $SVC down" "$STATE_DIR/compose_cmds"
  check "down keeps volumes (no -v)"    no_call "down -v"
  check "NO sudo at all"                no_call "^sudo"
  check "backend untouched (no grdctl)" no_call "^grdctl"
  check "nftables untouched"            no_call "^nft"
  check "firewall unit not disabled"    no_call "disable"
  check "system half all still there"   system_half_intact
  check "user-mapping.xml kept"         [ -f "$(mapping_file)" ]
  check "cert copy kept"                [ -f "$(state_dir)/rdp-tls.crt" ]
  check ".env kept"                     [ -f "$SVC/.env" ]
  check "lists what is left"            out_has "still in place"
  check "  names the nft table"         out_hasF "inet remote_desktop"
  check "  names the RDP listener"      out_has "Remote Login"
  check "  points at --system"          out_hasF "./teardown.sh --system"
  check "  says it is not exposed"      out_has "Nothing is exposed"
  check "  hand order: RDP off before the filter" \
    ordered_lines "$(grep -n 'rdp disable' <<<"$OUT" | head -1 | cut -d: -f1)" \
                  "$(grep -n 'disable --now remote-desktop-firewall' <<<"$OUT" | head -1 | cut -d: -f1)"
  check "says how to bring it back"     out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  : > "$CALLS_LOG"
  run_deploy
  check "./setup.sh brings it back"     [ "$CODE" -eq 0 ]
  check "  with no sudo (system half was kept)" no_call "^sudo"
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
  check "still compose down"            [ -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8094 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8094/guacamole/

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8094

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /desktop proxy http://127.0.0.1:8094/guacamole/
EOF
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ":8110 off"                     calls_have "serve --https=8110 off"
  check ":8443 off"                     calls_have "serve --https=8443 off"
  check "shared :443 left on"           no_call "https=443 off"
  check "warns about the shared port"   out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: when every match is on a shared port, it does not claim 'already off'"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /desktop proxy http://127.0.0.1:8094/guacamole/
EOF
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "shared :443 left on"           no_call " off"
  check "does not say already off"      out_lacks "already off"
  check "says a shared port still routes here" out_hasF "1 shared HTTPS port(s) still route to http://127.0.0.1:8094"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says why"                      out_has "Could not read Tailscale Serve status"
  check "no compose down"               [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"       [ "$CODE" -ne 0 ]
  check "no .env: explains"             out_has "nothing to tear down"
  check "no .env: touched nothing"      [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"          [ "$CODE" -ne 0 ]
  check "root: explains"                out_has "regular user"
  unset FAKE_UID
  export FAKE_UNAME=Darwin
  run_teardown
  check "macOS: exits non-zero"         [ "$CODE" -ne 0 ]
  check "macOS: explains"               out_has "macOS never hosts"
  unset FAKE_UNAME
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  run_teardown "--purge --system --purge"
  check "too many args: exits non-zero" [ "$CODE" -ne 0 ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"     [ "$CODE" -ne 0 ]
  check "nothing ever stopped"          [ ! -f "$STATE_DIR/compose_down" ]
  check "nothing ever unpublished"      no_call " off"
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then GUAC_STATE, .env and the marker go"
  deployed
  local dir; dir="$(state_dir)"
  run_teardown --purge "remote"
  check "wrong name: exits non-zero"    [ "$CODE" -ne 0 ]
  check "wrong name: state kept"        [ -f "$(mapping_file)" ]
  check "wrong name: .env kept"         [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped"   [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched"   no_call " off"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "remote-desktop"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "state dir (= the marker) gone" [ ! -e "$dir" ]
  check "marker ~/services/remote-desktop gone" [ ! -e "$HOME/services/remote-desktop" ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  check "serve off for :8094"           calls_have "tailscale serve --https=8094 off"
  check "compose down"                  [ -f "$STATE_DIR/compose_down" ]
  check "services dir itself kept"      [ -d "$HOME/services" ]
  check "neighbour kept"                [ -f "$HOME/services/neighbour/keep" ]
  check "still NO sudo"                 no_call "^sudo"
  check "system half untouched"         system_half_intact
  check "says --system now needs the hand commands" out_has "which --purge just deleted"
  teardown
}

test_teardown_purge_split_dirs() {
  echo "• teardown --purge: a GUAC_HOME outside GUAC_STATE goes too, if it is ours"
  deployed
  local own="$HOME/services/remote-desktop"
  mkdir -p "$own/state" "$own/guac-home2"; echo x > "$own/guac-home2/user-mapping.xml"
  sed -i.bak -e "s#^GUAC_STATE=.*#GUAC_STATE=$own/state#" -e "s#^GUAC_HOME=.*#GUAC_HOME=$own/guac-home2#" "$SVC/.env"
  rm -rf "$own/guac-home" "$own/.applied" "$own/rdp-tls.crt"
  run_teardown --purge "remote-desktop"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "GUAC_STATE gone"               [ ! -e "$own/state" ]
  check "GUAC_HOME gone"                [ ! -e "$own/guac-home2" ]
  check "marker gone once empty"        [ ! -e "$own" ]
  teardown
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak -e "s#^GUAC_HOME=.*#GUAC_HOME=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "GUAC_HOME in another service's dir: refused" [ "$CODE" -ne 0 ]
  check "  its data kept"               [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "  our state kept"              [ -d "$(state_dir)" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a state dir outside ~/services/remote-desktop"
  deployed
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "\$HOME: exits non-zero"        [ "$CODE" -ne 0 ]
  check "home untouched"                [ -d "$HOME" ]
  check "nothing stopped"               [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "'..' refused"                  [ "$CODE" -ne 0 ]
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "services dir itself refused"   [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  local dotted
  for dotted in "$HOME/services/." "$HOME/services/./remote-desktop" "$HOME/services/remote-desktop/.."; do
    sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$dotted#" "$SVC/.env"
    run_teardown --purge "remote-desktop"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched"  [ -f "$HOME/services/neighbour/keep" ]
  check "our state never touched"       [ -f "$(mapping_file)" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "remote-desktop"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "neighbour data kept"           [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "symlink to services refused"   [ "$CODE" -ne 0 ]
  check "neighbour still kept"          [ -f "$HOME/services/neighbour/keep" ]
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/remote-desktop///#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  and it is gone"              [ ! -e "$HOME/services/remote-desktop" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a state dir already gone is fine"
  deployed
  rm -rf "$(state_dir)"
  run_teardown --purge "remote-desktop"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  teardown
  deployed
  # The marker outlives a hand-deleted state subdir: still removed when empty.
  local own="$HOME/services/remote-desktop"
  sed -i.bak -e "s#^GUAC_STATE=.*#GUAC_STATE=$own/state#" -e "s#^GUAC_HOME=.*#GUAC_HOME=$own/state/guac-home#" "$SVC/.env"
  rm -rf "${own:?}/"* "$own/.applied"
  run_teardown --purge "remote-desktop"
  check "empty marker still removed"    [ ! -e "$own" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(state_dir)"
  sed -i.bak -e "s#^GUAC_STATE=.*#GUAC_STATE=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "\${HOME} form: exits zero"     [ "$CODE" -eq 0 ]
  check "  dir gone"                    [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(state_dir)"
  sed -i.bak -e "s#^GUAC_STATE=.*#GUAC_STATE='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                    [ -e "$dir" ]
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/remote-desktop itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"               [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/remote-desktop/a:b"
  sed -i.bak "s#^GUAC_STATE=.*#GUAC_STATE=$HOME/services/remote-desktop/a:b#" "$SVC/.env"
  run_teardown --purge "remote-desktop"
  check "a colon in the path refused"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "• teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/remote-desktop"; echo x > "$HOME/remote-desktop/keep"
  run_teardown --purge "remote-desktop"
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"     [ -f "$HOME/remote-desktop/keep" ]
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/remote-desktop survives"
  deployed
  local repo="$HOME/services/remote-desktop/setup-server/services/remote-desktop"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$HOME/services/remote-desktop/setup-server/other.env"
  OUT="$(printf '%s\n' "remote-desktop" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "checkout intact"               [ -f "$repo/teardown.sh" ]
  check "other services' files kept"    [ -f "$HOME/services/remote-desktop/setup-server/other.env" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^GUAC_PORT=.*/export GUAC_PORT='8094'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"        [ "$CODE" -eq 0 ]
  check ":8094 off"                     calls_have "serve --https=8094 off"
  teardown
  deployed
  sed -i.bak -e 's/^GUAC_PORT=.*/GUAC_PORT="8094"/' "$SVC/.env"
  run_teardown
  check "double quotes"                 [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^GUAC_PORT=.*/GUAC_PORT=8094 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"                [ "$CODE" -eq 0 ]
  check "  :8094 off"                   calls_have "serve --https=8094 off"
  teardown
  deployed
  sed -i.bak -e 's/^GUAC_PORT=.*/GUAC_PORT=abc/' "$SVC/.env"
  run_teardown
  check "non-numeric port refused"      [ "$CODE" -ne 0 ]
  check "  nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'GUAC_STATE=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"               out_has "GUAC_STATE is set more than once"
  check "  touched nothing"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  printf 'X="first\nGUAC_STATE=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
  echo "• teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_PROFILES; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "remote-desktop"
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

test_teardown_foreign_user_units() {
  echo "• teardown: user units mentioning this service are named, never touched"
  deployed
  local ud="$HOME/.config/systemd/user"
  mkdir -p "$ud"
  printf '[Service]\nExecStart=/usr/bin/ssh -L 4822:guacd:4822 box\n' > "$ud/guac-tunnel.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$ud/unrelated.service"
  run_teardown
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "names the foreign unit"        out_hasF "guac-tunnel.service"
  check "  not the unrelated one"       out_lacks "unrelated.service"
  check "  no systemctl --user call"    no_call "systemctl --user"
  check "  unit file kept"              [ -f "$ud/guac-tunnel.service" ]
  teardown
}

# ----------------------------------------------------- teardown --system
test_teardown_system_needs_a_terminal() {
  echo "• teardown --system: no terminal (the launcher's situation) changes nothing"
  deployed
  run_teardown --system
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says it needs a terminal"      out_has "needs a terminal"
  check "no sudo"                       no_call "^sudo"
  check "nothing unpublished"           no_call " off"
  check "nothing stopped"               [ ! -f "$STATE_DIR/compose_down" ]
  check "system half intact"            system_half_intact
  teardown
}

test_teardown_system() {
  echo "• teardown --system (tty): RDP off and verified closed BEFORE the filter goes"
  if ! have_pty; then note "    (skipped: no python3 pty module for a terminal)"; return 0; fi
  deployed
  run_teardown_tty --system
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "announces the sudo steps first" \
    ordered_lines "$(grep -n 'needs sudo' <<<"$OUT" | head -1 | cut -d: -f1)" \
                  "$(grep -n 'RDP is off' <<<"$OUT" | head -1 | cut -d: -f1)"
  check "serve off + compose down first" [ -f "$STATE_DIR/compose_down" ]
  check "RDP disabled"                  [ ! -f "$STATE_DIR/grd_rdp_enabled" ]
  check "credentials cleared"           calls_have "sudo grdctl --system rdp clear-credentials"
  check "daemon restarted, not stopped" calls_have "sudo systemctl restart gnome-remote-desktop.service"
  check "  never stopped or disabled"   no_call "systemctl \(stop\|disable\|mask\).*gnome-remote-desktop"
  check "probed :3389 after the restart" ordered_lines \
    "$(line_of 'restart gnome-remote-desktop')" "$(line_of 'python3 probe tcp 127.0.0.1 3389')"
  check "ORDER: rdp disable < restart < probe < filter off" ordered_lines \
    "$(line_of 'sudo grdctl --system rdp disable')" \
    "$(line_of 'sudo systemctl restart gnome-remote-desktop')" \
    "$(line_of 'python3 probe tcp 127.0.0.1 3389')" \
    "$(line_of 'sudo systemctl disable --now remote-desktop-firewall.service')"
  check "filter unit disabled"          [ ! -f "$STATE_DIR/fw_unit_enabled" ]
  check "nft table gone"                [ ! -f "$STATE_DIR/fw_installed" ]
  check "never a ruleset flush"         no_call "flush"
  check "rules file removed"            [ ! -e "$(rootfs /etc/remote-desktop/rdp-firewall.nft)" ]
  check "/etc/remote-desktop removed"   [ ! -e "$(rootfs /etc/remote-desktop)" ]
  check "unit file removed"             [ ! -e "$(rootfs /etc/systemd/system/remote-desktop-firewall.service)" ]
  check "daemon-reload"                 calls_have "sudo systemctl daemon-reload"
  check "TLS key removed"               [ ! -e "$(rootfs /var/lib/gnome-remote-desktop/certificates/rdp-tls.key)" ]
  check "TLS cert removed"              [ ! -e "$(rootfs /var/lib/gnome-remote-desktop/certificates/rdp-tls.crt)" ]
  check "  and the markers claiming it" [ ! -e "$(state_dir)/.applied/rdp-cert" ]
  check "user-mapping.xml kept"         [ -f "$(mapping_file)" ]
  check ".env kept"                     [ -f "$SVC/.env" ]
  check "no leftover warning"           out_lacks "still in place"
  run_teardown_tty --system
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  rm -f "$STATE_DIR/install_owners"; : > "$CALLS_LOG"
  run_deploy
  check "./setup.sh rebuilds it"        [ "$CODE" -eq 0 ]
  check "  with a NEW keypair"          grep -q 'rdp-tls.key' "$STATE_DIR/install_owners"
  check "  and the filter back"         system_half_intact
  teardown
}

test_teardown_system_listener_survives() {
  echo "• teardown --system: if :3389 still answers, the filter STAYS"
  if ! have_pty; then note "    (skipped: no python3 pty module for a terminal)"; return 0; fi
  deployed
  touch "$STATE_DIR/grd_disable_noop"
  run_teardown_tty --system
  check "exits non-zero"                [ "$CODE" -ne 0 ]
  check "says the filter is left"       out_has "LEFT IN PLACE"
  check "filter unit never disabled"    no_call "disable --now remote-desktop-firewall"
  check "nft never touched"             no_call "^nft"
  check "table still there"             [ -f "$STATE_DIR/fw_installed" ]
  check "rules file kept"               [ -f "$(rootfs /etc/remote-desktop/rdp-firewall.nft)" ]
  teardown
  deployed
  touch "$STATE_DIR/grd_disable_fails"
  run_teardown_tty --system
  check "grdctl disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  no restart"                  no_call "restart gnome-remote-desktop"
  check "  filter intact"               system_half_intact
  teardown
  deployed
  touch "$STATE_DIR/restart_grd_fails"
  run_teardown_tty --system
  check "restart fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  filter never disabled"       no_call "disable --now remote-desktop-firewall"
  teardown
}

test_teardown_system_interrupted_after_keypair() {
  echo "• teardown --system: interrupted right after the keypair goes, setup.sh still regenerates it"
  if ! have_pty; then note "    (skipped: no python3 pty module for a terminal)"; return 0; fi
  deployed
  touch "$STATE_DIR/rm_keypair_interrupts"
  run_teardown_tty --system
  rm -f "$STATE_DIR/rm_keypair_interrupts"
  check "interrupted: exits non-zero"   [ "$CODE" -ne 0 ]
  check "TLS key removed"               [ ! -e "$(rootfs /var/lib/gnome-remote-desktop/certificates/rdp-tls.key)" ]
  check "cert marker already cleared"   [ ! -e "$(state_dir)/.applied/rdp-cert" ]
  check "cert copy already cleared"     [ ! -e "$(state_dir)/rdp-tls.crt" ]
  rm -f "$STATE_DIR/install_owners"; : > "$CALLS_LOG"
  run_deploy
  check "./setup.sh rebuilds it"        [ "$CODE" -eq 0 ]
  check "  with a NEW keypair"          grep -q 'rdp-tls.key' "$STATE_DIR/install_owners"
  teardown
}

test_teardown_system_table_outlives_unit() {
  echo "• teardown --system: a table left after its unit stops is deleted by name"
  if ! have_pty; then note "    (skipped: no python3 pty module for a terminal)"; return 0; fi
  deployed
  touch "$STATE_DIR/fw_table_lingers"
  run_teardown_tty --system
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "deleted exactly that table"    calls_have "^nft delete table inet remote_desktop$"
  check "table gone"                    [ ! -f "$STATE_DIR/fw_installed" ]
  teardown
}

test_teardown_system_and_purge() {
  echo "• teardown --system --purge (tty): system half first, then state"
  if ! have_pty; then note "    (skipped: no python3 pty module for a terminal)"; return 0; fi
  deployed
  run_teardown_tty "--system --purge" "wrong"
  check "wrong name: exits non-zero"    [ "$CODE" -ne 0 ]
  check "  no sudo"                     no_call "^sudo"
  check "  system half intact"          system_half_intact
  run_teardown_tty "--purge --system" "remote-desktop"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "RDP off"                       [ ! -f "$STATE_DIR/grd_rdp_enabled" ]
  check "filter gone"                   [ ! -f "$STATE_DIR/fw_installed" ]
  check "state + marker gone"           [ ! -e "$HOME/services/remote-desktop" ]
  check ".env gone"                     [ ! -f "$SVC/.env" ]
  teardown
}

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
           "$SERVICE_DIR/teardown.sh" \
           "$SERVICE_DIR/SETUP.md" "$SERVICE_DIR/TROUBLESHOOT.md" \
           "$SERVICE_DIR/.env" "$ORIG_HOME/services/remote-desktop" \
           /etc/remote-desktop /etc/remote-desktop/rdp-firewall.nft \
           /etc/systemd/system/remote-desktop-firewall.service \
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
# services that map across numbers (e.g. seafile 8443 -> 8081, code-server
# 443 -> 8080)
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

  local ts port url ts4 rdp_host addr any_open=0
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
  red "services/remote-desktop/setup.sh is missing — nothing to test."
  red "It is owned by the deploy side; this suite tests it, it does not write it."
  exit 1
fi
if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  red "services/remote-desktop/docker-compose.yml is missing — nothing to test."
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
test_mapping_migration
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
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_only_shared_ports
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_purge
test_teardown_purge_split_dirs
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
test_teardown_foreign_user_units
test_teardown_system_needs_a_terminal
test_teardown_system
test_teardown_system_listener_survives
test_teardown_system_interrupted_after_keypair
test_teardown_system_table_outlives_unit
test_teardown_system_and_purge
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
