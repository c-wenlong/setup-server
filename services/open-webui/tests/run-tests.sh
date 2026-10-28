#!/usr/bin/env bash
#
# Tests for services/open-webui/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/sudo/id.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
# setup.sh sources ../../lib/common.sh, so every sandbox copy of the
# service sits at <root>/services/<name> with <root>/lib beside it.
copy_lib() { mkdir -p "$1/lib" && cp "$REPO_ROOT/lib/common.sh" "$1/lib/"; }
STUBS="$TESTS_DIR/stubs"

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
  SVC="$SANDBOX/repo/services/open-webui"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
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

check() {
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

out_has()    { grep -q "$1" <<<"$OUT"; }
calls_have() { grep -q "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }

# ----------------------------------------------------------------- tests
test_preflight_docker_perms() {
  echo "• preflight fails when user cannot reach the docker daemon"
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
  teardown
}

test_preflight_bad_https_port() {
  echo "• preflight rejects a non-numeric HTTPS port"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "must be numeric"
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check ".env generated"                [ -f "$SVC/.env" ]
  check ".env points at local ollama"   env_has "OLLAMA_BASE_URL=http://127.0.0.1:11434"
  check "compose up invoked"            [ -f "$STATE_DIR/compose_up" ]
  check "data dir created under HOME"   [ -d "$HOME/services/open-webui/data" ]
  check "served on tailscale :3001"     calls_have "tailscale serve --bg --https=3001 http://127.0.0.1:3001"
  check "  and never the old :10000"    no_call "tailscale serve --bg --https=10000"
  check "prints final URL"              out_has "https://test-host.tailfake.ts.net:3001"
  check "warns about first signup"      out_has "first account registered becomes the admin"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo"
  setup
  touch "$STATE_DIR/operator"
  printf 'LOCAL_PORT=3001\nWEBUI_VOLUME=/tmp/x\nOLLAMA_BASE_URL=http://127.0.0.1:11434\n# my-custom-marker\n' > "$SVC/.env"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "existing .env untouched" env_has "my-custom-marker"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default next to a LOCAL_PORT override
  # publishes :<literal> -> 127.0.0.1:<moved>, i.e. the wrong backend.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3005
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=3005"   grep -qx 'LOCAL_PORT=3005' "$SVC/.env"
  check "served :3005 -> 127.0.0.1:3005" calls_have "tailscale serve --bg --https=3005 http://127.0.0.1:3005"
  check "  and never :3001"              no_call "tailscale serve --bg --https=3001"
  check "prints the :3005 URL"           out_has "https://test-host.tailfake.ts.net:3005"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3005 HTTPS_PORT=8443
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:3005" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:3005"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_legacy_10000_mapping_is_withdrawn() {
  echo "• re-run on a box published on :10000: the old mapping is withdrawn"
  # Serve keeps every mapping it is given, so moving the published port only
  # ADDS one. Without the migration a re-run leaves two URLs for one service,
  # the retired one still answering.
  setup
  touch "$STATE_DIR/operator"
  printf '10000 http://127.0.0.1:3001\n' > "$STATE_DIR/served"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "published the new :3001"         calls_have "tailscale serve --bg --https=3001 http://127.0.0.1:3001"
  check "withdrew the legacy port"        calls_have "tailscale serve --https=10000 off"
  check "  and said so"                   out_has "Withdrawing the legacy :10000 mapping"
  check "  it is really gone from Serve"  bash -c "! grep -q '^10000 ' '$STATE_DIR/served'"
  check "  while :3001 remains"           grep -q '^3001 ' "$STATE_DIR/served"
  teardown

  echo "• a :10000 that belongs to something else is left alone"
  setup
  touch "$STATE_DIR/operator"
  printf '10000 http://127.0.0.1:9999\n' > "$STATE_DIR/served"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "never touched the other :10000"  no_call "tailscale serve --https=10000 off"
  check "  it is still published"         grep -q '^10000 http://127.0.0.1:9999$' "$STATE_DIR/served"
  teardown

  echo "• nothing to withdraw on a fresh box: no off call at all"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check "no withdrawal attempted"         no_call "serve --https=10000 off"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=3001"
  teardown
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

data_dir() { sed -n 's/^WEBUI_VOLUME=//p' "$SVC/.env"; }

# A deployed sandbox: setup.sh has run, Serve maps :3001 (current) and
# :10000 (legacy) to this service, and neighbours sit on other ports, one a
# lookalike suffix. ollama's state is faked so "never touched" is checkable.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(data_dir)/uploads"
  echo keep > "$(data_dir)/webui.db"
  mkdir -p "$HOME/.ollama/models"; echo model > "$HOME/.ollama/models/m"
  cat > "$STATE_DIR/served" <<EOF
3001 http://127.0.0.1:3001
10000 http://127.0.0.1:3001
5678 http://127.0.0.1:5678
13001 http://127.0.0.1:13001
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data and .env, unpublishes current + legacy port only"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :3001"         calls_have "tailscale serve --https=3001 off"
  check "legacy :10000 off too"       calls_have "tailscale serve --https=10000 off"
  check "neighbour :5678 untouched"   no_call "https=5678"
  check "lookalike :13001 untouched"  no_call "https=13001"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data kept"                   [ -f "$(data_dir)/webui.db" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "ollama never touched"        no_call "ollama"
  check "ollama models kept"          [ -f "$HOME/.ollama/models/m" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_moved_port() {
  echo "• teardown: a moved HTTPS port comes from Serve, not from guessing"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=3005 HTTPS_PORT=8443
  run_deploy
  unset LOCAL_PORT HTTPS_PORT
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8443"         calls_have "tailscale serve --https=8443 off"
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/served"
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
  printf '3001 http://127.0.0.1:9999\n10000 http://127.0.0.1:9999\n' > "$STATE_DIR/served"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
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
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then data and .env go"
  deployed
  local dir; dir="$(data_dir)"
  run_teardown --purge "open-web"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/webui.db" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "open-webui"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$dir" ]
  check "empty ~/services/open-webui gone" [ ! -e "$HOME/services/open-webui" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :3001"         calls_have "tailscale serve --https=3001 off"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "ollama models kept"          [ -f "$HOME/.ollama/models/m" ]
  check "ollama never touched"        no_call "ollama"
  teardown
}

test_teardown_purge_keeps_unknown_siblings() {
  echo "• teardown --purge: other files next to the data dir survive"
  deployed
  echo mine > "$HOME/services/open-webui/notes.txt"
  run_teardown --purge "open-webui"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "data dir gone"               [ ! -e "$HOME/services/open-webui/data" ]
  check "sibling file kept"           [ -f "$HOME/services/open-webui/notes.txt" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a data dir outside ~/services"
  deployed
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$HOME#" "$SVC/.env"
  run_teardown --purge "open-webui"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "open-webui"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "open-webui"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./open-webui" "$HOME/services/open-webui/.."; do
    sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$dotted#" "$SVC/.env"
    run_teardown --purge "open-webui"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=#" "$SVC/.env"
  run_teardown --purge "open-webui"
  check "empty value refused"         [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; others stay"
  deployed
  cat > "$STATE_DIR/served" <<EOF
3001 http://127.0.0.1:3001
8443 http://127.0.0.1:3001
EOF
  # a port that belongs to another service
  cat >> "$STATE_DIR/served" <<EOF
443 http://127.0.0.1:8080
EOF
  # and one shared with it: this service on a path next to another handler
  cat >> "$STATE_DIR/served" <<EOF
4443 http://127.0.0.1:8080
4443 http://127.0.0.1:3001 /webui
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":3001 off"                   calls_have "serve --https=3001 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "other :443 untouched"        no_call "https=443 off"
  check "shared :4443 left on"        no_call "https=4443 off"
  check "warns about the shared port" out_has "HTTPS :4443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:3001 (left on, see above); 2 port(s) unpublished"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='3001'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":3001 off"                   calls_have "serve --https=3001 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="3001"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check "double quotes: :3001 off"    calls_have "serve --https=3001 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=3001 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check "inline comment: :3001 off"   calls_have "serve --https=3001 off"
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "open-webui"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "open-webui"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_data_dir() {
  echo "• teardown --purge: a data dir already gone is fine"
  deployed
  rm -rf "$(data_dir)"
  run_teardown --purge "open-webui"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
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
# address, never a wildcard or a LAN interface.
#
# The tailnet allowance became load-bearing here on 2026-09-13, when the
# published port stopped being 10000 and started following the local port:
# with 3001 -> 3001, tailscaled's own Serve proxy legitimately holds the
# tailnet address on the same number the container binds on loopback. The
# previous "anything that is not 127.0.0.1 is a leak" reading flagged that
# proxy and failed a correct deploy. Host networking makes the check matter
# more, not less: HOST=127.0.0.1 in docker-compose.yml is the only thing
# keeping the UI off the LAN, since there is no Docker publish spec.
#
# The function body below is the canonical implementation, byte-identical to
# immich's, vaultwarden's, jellyfin's, adguard's and homepage's.
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
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6]: tr, not a
                                                 # glob, because '[' is an
                                                 # invalid pattern under zsh
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
  local ts port https_port url
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  # Ask Serve which HTTPS port actually fronts this backend rather than
  # assuming it equals LOCAL_PORT. .env stores no HTTPS_PORT, so after a
  # deploy that passed one explicitly (HTTPS_PORT=8443 ./setup.sh) a fresh
  # shell has no other way to know, and guessing would fail a correct
  # deployment. A header with no port is :443.
  https_port="$("$ts" serve status 2>/dev/null | awk -v want="proxy http://127.0.0.1:$port" '
    /^https:\/\// { p = 443; if (match($1, /:[0-9]+$/)) p = substr($1, RSTART + 1) }
    p && index($0, want) { print p; exit }
  ')"
  [ -n "$https_port" ] || https_port="${HTTPS_PORT:-$port}"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
  live_check "container running"              sh -c "docker inspect -f '{{.State.Status}}' open-webui | grep -qx running"
  live_check "local health responds"          curl -fsS "http://127.0.0.1:$port/health"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "ollama reachable from host"     curl -fsS --max-time 3 "http://127.0.0.1:11434/api/version"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "the old :10000 mapping is gone"  sh -c "! '$ts' serve status | grep -q ':10000'"
  live_check "tailnet HTTPS responds"         curl -fsS -o /dev/null --max-time 30 "$url:$https_port/health"
}

test_teardown_purge_root_owned() {
  echo "• teardown --purge: root-owned files are cleared by the image, not sudo"
  deployed
  local dir; dir="$(sed -n 's/^WEBUI_VOLUME=//p' "$SVC/.env")"
  # Stand-in for root-owned files: a read-only dir the host user cannot empty.
  mkdir -p "$dir/vector_db/locked"; echo x > "$dir/vector_db/locked/chroma.sqlite3"
  chmod 500 "$dir/vector_db/locked"
  run_teardown --purge "open-webui"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the app image"          calls_have "ghcr.io/open-webui/open-webui"
  check "never pulled for it"         calls_have "pull never"
  check "no sudo"                     no_call "^sudo"
  check "data dir gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(sed -n 's/^WEBUI_VOLUME=//p' "$SVC/.env")"
  mkdir -p "$dir/vector_db/locked"; echo x > "$dir/vector_db/locked/chroma.sqlite3"
  chmod 500 "$dir/vector_db/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "open-webui"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
}

# WEBUI_VOLUME under a folder this user cannot search (a root-owned 0700
# storage/, faked with chmod 000): `[ -e ]` cannot see the data, which must
# not read as "already gone" while .env is deleted. The app image mounts
# that folder and deletes only the path below it.
hide_data_under_storage() {
  local st="$HOME/services/open-webui/storage"
  mkdir -p "$st"
  mv "$(data_dir)" "$st/data"
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$st/data#" "$SVC/.env"
  chmod 000 "$st"
}
unhide_storage() {
  chmod u+rwx "$HOME/services" 2>/dev/null
  chmod -R u+rwX "$HOME/services/open-webui" 2>/dev/null
}

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: data behind an unsearchable folder is deleted, not taken as gone"
  local st
  deployed
  st="$HOME/services/open-webui/storage"
  hide_data_under_storage
  run_teardown --purge "open-webui"
  unhide_storage
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "mounted the unsearchable folder" grep -q -- "-v $st:/x" "$STATE_DIR/cleanup_run"
  check "used the app image"          grep -q "ghcr.io/open-webui/open-webui:main" "$STATE_DIR/cleanup_run"
  check "never pulled for it"         grep -q "pull never" "$STATE_DIR/cleanup_run"
  check "no sudo"                     no_call "^sudo"
  check "data gone"                   [ ! -e "$st/data" ]
  check "emptied folder gone"         [ ! -e "$st" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir removed"           [ ! -e "$HOME/services/open-webui" ]
  check "ollama models kept"          [ -f "$HOME/.ollama/models/m" ]
  teardown
  deployed
  st="$HOME/services/open-webui/storage"
  hide_data_under_storage
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "open-webui"
  unhide_storage
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/data"
  check "  never says deleted"        bash -c '! grep -q "Deleted" <<<"$1"' _ "$OUT"
  check "  data kept"                 [ -f "$st/data/webui.db" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  st="$HOME/services/open-webui/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/data"
  sed -i.bak "s#^WEBUI_VOLUME=.*#WEBUI_VOLUME=$st/data#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "open-webui"
  unhide_storage
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # ~/services/open-webui itself unsearchable: not strictly inside it, so
  # no mount; stop before anything changes and name the sudo command.
  deployed
  chmod 000 "$HOME/services/open-webui"
  run_teardown --purge "open-webui"
  unhide_storage
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $(data_dir)"
  check "  no cleanup container"      [ ! -f "$STATE_DIR/cleanup_run" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  serve untouched"           no_call " off"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/webui.db" ]
  teardown
  # ~/services itself unsearchable: same, nothing changes.
  deployed
  chmod 000 "$HOME/services"
  run_teardown --purge "open-webui"
  unhide_storage
  check "\$HOME/services unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  data kept"                 [ -f "$(data_dir)/webui.db" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/served" <<EOF
443 http://127.0.0.1:8080
443 http://127.0.0.1:3001 /webui
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    bash -c '! grep -q "already off" <<<"$1"' _ "$OUT"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:3001 (left on, see above); 0 port(s) unpublished"
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_https_port
test_fresh_deploy
test_idempotent_rerun
test_https_port_follows_local_port
test_legacy_10000_mapping_is_withdrawn
test_operator_escalation
test_teardown_safe
test_teardown_moved_port
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_root_owned
test_teardown_purge_keeps_unknown_siblings
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports

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
