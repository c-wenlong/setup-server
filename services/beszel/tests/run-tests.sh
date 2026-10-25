#!/usr/bin/env bash
#
# Tests for services/beszel/setup.sh and teardown.sh.
#
#   ./tests/run-tests.sh          # static checks of setup.sh + a sandboxed
#                                 # run of teardown.sh (no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Mocked mode is static analysis rather than the PATH-stub sandbox other
# services use: this setup leans on the hub's live PocketBase API, so a stub
# farm would mostly test the stubs (rationale in SETUP.md). teardown.sh has
# no API calls, so it runs for real in a temp $HOME with a handful of stubs
# generated at run time (see the teardown section).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SETUP="$SERVICE_DIR/setup.sh"
COMPOSE="$SERVICE_DIR/docker-compose.yml"

PASS=0; FAIL=0
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); green "    ✓ $desc"
  else FAIL=$((FAIL+1)); red "    ✗ $desc"; fi
}

echo "  static checks"
check "setup.sh parses (bash -n)" bash -n "$SETUP"
check "strict mode set" grep -q 'set -euo pipefail' "$SETUP"
# Portability contract (AGENTS.md): OS branch, root refusal, resolved Tailscale
# CLI, Tailscale-running preflight, gated Linux-only concepts.
check "branches on uname -s (Linux|Darwin, dies otherwise)" \
      grep -q 'case "\$OS" in Linux|Darwin) ;; \*) die' "$SETUP"
check "refuses to run as root" grep -q '\[ "\$(id -u)" -ne 0 \] || die' "$SETUP"
check "requires Tailscale to be Running before deploying" \
      grep -q 'BackendState' "$SETUP"
check "resolves the Tailscale CLI from the macOS app bundle" \
      grep -q '/Applications/Tailscale.app/Contents/MacOS/Tailscale' "$SETUP"
# Every real invocation goes through the resolved path. Comment lines and
# the management hints echoed at the end are the only places the bare word
# may appear next to a subcommand.
check "no bare 'tailscale serve|status|ip' invocations" \
      bash -c "! grep -vE '^[[:space:]]*(#|echo )' '$SETUP' | grep -qE '(^|[^A-Za-z_\"\$/-])tailscale +(serve|status|ip)\b'"
check "agent tarball picks OS + arch (not linux_amd64 literal)" \
      grep -q 'beszel-agent_\${OS_LC}_\${ARCH}\.tar\.gz' "$SETUP"
check "macOS agent runs as a launchd LaunchAgent" \
      grep -q 'Library/LaunchAgents/com.henrygd.beszel-agent.plist' "$SETUP"
check "lingering is Linux-gated" \
      bash -c "grep -B6 'loginctl enable-linger' '$SETUP' | grep -q 'OS\" = \"Linux'"
check "operator grant is Linux-gated and only on a denied serve" \
      bash -c "grep -B2 'set --operator=' '$SETUP' | grep -q 'OS\" = \"Linux\" \] && printf .%s. .\$serve_out. | grep -q .denied.'"
check "serve retries only on an approval link, dies otherwise" \
      bash -c "grep -q '\*login.tailscale.com\*) ;;' '$SETUP' && grep -A1 '\*login.tailscale.com\*) ;;' '$SETUP' | grep -q 'die'"
check "port from .env is re-validated" \
      grep -q 'BESZEL_PORT in \$ENV_FILE must be numeric' "$SETUP"
check "final URL is resolved, not hardcoded" \
      bash -c "! grep -q 'kai-home-server\.taild6a23f' '$SETUP'"
# Sudo is surgical: exactly the two one-time Linux grants the reference
# implementation (code-server) makes, and nothing else.
check "sudo only for lingering + tailscale operator" \
      bash -c "[ \"\$(grep -c '^ *sudo ' '$SETUP')\" -eq 2 ] && grep -q '^ *sudo loginctl enable-linger' '$SETUP' && grep -q '^ *sudo \"\$TAILSCALE\" set --operator=' '$SETUP'"
check "hub bound to loopback" grep -q 'serve --http "127.0.0.1' "$COMPOSE"
check "hub uses host networking (reaches agent loopback)" \
      grep -q 'network_mode: host' "$COMPOSE"
check "agent listens loopback only" grep -q 'LISTEN=127.0.0.1' "$SETUP"
check "agent KEY env is quoted (contains a space)" \
      grep -q 'Environment="KEY=' "$SETUP"
check "agent unit always restarted after rewrite" \
      grep -q 'systemctl --user restart beszel-agent' "$SETUP"
check ".env created mode 600" grep -q 'chmod 600 "\$ENV_FILE"' "$SETUP"
check ".env is gitignored" git -C "$SERVICE_DIR" check-ignore -q "$SERVICE_DIR/.env"
check "idempotency guard on .env (never clobbered)" \
      grep -q 'if \[ -f "\$ENV_FILE" \]; then' "$SETUP"
check "tailscale serve published via the resolved CLI" \
      grep -q '"\$TAILSCALE" serve --bg --https="\$PORT" "http://127.0.0.1:\$PORT"' "$SETUP"
check "GPU stats enabled" grep -q 'GPU=true' "$SETUP"
check "Kuma monitor row exists" \
      grep -q 'beszel' "$SERVICE_DIR/../monitoring/seed_kuma.py"

# ------------------------------------------------------------- teardown
# teardown.sh, unlike setup.sh, never talks to the hub's API, so it CAN run
# for real in a sandbox: temp $HOME, and small PATH stubs that this file
# writes into the sandbox at run time (so the service still has no
# tests/stubs/ farm; see SETUP.md). The deployed state is built from the
# exact .env / unit / plist heredocs in setup.sh, so teardown's "is this the
# file setup.sh wrote?" checks are tested against the real thing.
ORIG_HOME="$HOME"
REAL_UNAME="$(command -v uname)"
REAL_ID="$(command -v id)"

out_has()    { grep -qF -- "$1" <<<"$OUT"; }
calls_have() { grep -qF -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -qF -- "$1" "$CALLS_LOG"; }
call_before() {
  local a b
  a="$(grep -nF -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" "$CALLS_LOG" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

write_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF_STUB_D7q'
#!/usr/bin/env bash
# docker stub. $STATE_DIR: docker_no_perm, images (one name per line, what
# `image inspect` finds), docker_run_fails; compose_down is touched by down.
echo "docker $*" >> "$CALLS_LOG"
case "$1" in
  ps) [ ! -f "$STATE_DIR/docker_no_perm" ] || { echo "permission denied" >&2; exit 1; } ;;
  image) [ "$2" = inspect ] || exit 0
         grep -qxF -- "$3" "$STATE_DIR/images" 2>/dev/null; exit $? ;;
  compose)
    if [ "$2" = version ]; then echo "Docker Compose version v2.99-stub"; exit 0; fi
    for a in "$@"; do [ "$a" = down ] && touch "$STATE_DIR/compose_down"; done ;;
  run)
    # The purge cleanup container. Real one is root and empties the mount;
    # model that, but never outside the sandbox.
    [ ! -f "$STATE_DIR/docker_run_fails" ] || exit 1
    host=""; entry=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -v) host="${2%%:*}"; shift 2 ;;
        --entrypoint) entry="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$entry" = sh ] && [ -n "$host" ] || exit 1
    case "$host" in "$SANDBOX"/?*) ;; *) echo "stub: mount outside sandbox: $host" >&2; exit 97 ;; esac
    chmod -R u+rwX "$host" && find "$host" -mindepth 1 -delete ;;
esac
exit 0
EOF_STUB_D7q
  cat > "$bin/tailscale" <<'EOF_STUB_T4m'
#!/usr/bin/env bash
# tailscale stub. $STATE_DIR: serve_status (text printed), serve_status_fails.
echo "tailscale $*" >> "$CALLS_LOG"
if [ "$1" = serve ] && [ "${2:-}" = status ]; then
  if [ -f "$STATE_DIR/serve_status_fails" ]; then
    echo "failed to connect to local tailscaled" >&2; exit 1
  fi
  [ -f "$STATE_DIR/serve_status" ] && cat "$STATE_DIR/serve_status"
fi
exit 0
EOF_STUB_T4m
  cat > "$bin/systemctl" <<'EOF_STUB_S8x'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_LOG"
exit 0
EOF_STUB_S8x
  cat > "$bin/sudo" <<'EOF_STUB_Q9n'
#!/usr/bin/env bash
# teardown must never escalate; record it and refuse.
echo "sudo $*" >> "$CALLS_LOG"
exit 1
EOF_STUB_Q9n
  cat > "$bin/launchctl" <<'EOF_STUB_L2w'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS_LOG"
exit 0
EOF_STUB_L2w
  cat > "$bin/id" <<EOF_STUB_I5r
#!/usr/bin/env bash
if [ "\${1:-}" = -u ]; then echo "\${FAKE_UID:-1000}"; else exec "$REAL_ID" "\$@"; fi
EOF_STUB_I5r
  cat > "$bin/uname" <<EOF_STUB_U3z
#!/usr/bin/env bash
if [ "\${1:-}" = -s ] && [ -n "\${FAKE_OS:-}" ]; then echo "\$FAKE_OS"; else exec "$REAL_UNAME" "\$@"; fi
EOF_STUB_U3z
  chmod +x "$bin"/*
}

td_setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export SANDBOX
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  STUB_BIN="$SANDBOX/bin"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  write_stubs "$STUB_BIN"
  cp "$SETUP" "$SERVICE_DIR/teardown.sh" "$COMPOSE" "$SVC/"
}

td_teardown() {
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_OS STATE_DIR CALLS_LOG SANDBOX
}

# The body of one `cat > "<file>" <<EOF` heredoc in setup.sh, with its
# variables filled in the way setup.sh would on this sandbox.
from_setup() {
  sed -n "/^ *cat > \"\\\$$1\" <<EOF\$/,/^EOF\$/p" "$SETUP" | sed '1d;$d' \
    | sed -e "s#\\\$BIN#$HOME/.local/bin/beszel-agent#g" \
          -e "s#\\\$STATE#$HOME/services/beszel#g" \
          -e "s#\\\$HOME#$HOME#g" \
          -e 's#\$PORT#8092#g; s#\$AGENT_PORT#45876#g; s#\$KEY#ssh-ed25519 AAAAtestkey#g' \
          -e 's#\$ADMIN_EMAIL#me@example.com#g; s#\$(randhex)#0123456789abcdef0123456789abcdef#g' \
          -e 's#\$DOCKER_HOST_LINE##g'
}

hub_dir() { sed -n 's/^BESZEL_VOLUME=//p' "$SVC/.env"; }
set_env() { sed -i.bak "s#^$1=.*#$1=$2#" "$SVC/.env"; }

# A deployed sandbox: what setup.sh leaves behind (.env, hub data with a
# root-ish subdir, agent binary, unit + its wants link, or the plist on
# macOS), Serve mapping this port, and neighbours on other ports (one a
# lookalike suffix).
deployed() {
  td_setup
  from_setup ENV_FILE > "$SVC/.env"; chmod 600 "$SVC/.env"
  mkdir -p "$(hub_dir)/.notify"
  echo db > "$(hub_dir)/data.db"
  mkdir -p "$HOME/.local/bin"
  echo agent > "$HOME/.local/bin/beszel-agent"; chmod +x "$HOME/.local/bin/beszel-agent"
  if [ "${FAKE_OS:-$(uname -s)}" = Darwin ]; then
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    from_setup PLIST > "$HOME/Library/LaunchAgents/com.henrygd.beszel-agent.plist"
    echo log > "$HOME/Library/Logs/beszel-agent.log"
  else
    mkdir -p "$HOME/.config/systemd/user/default.target.wants"
    from_setup UNIT > "$HOME/.config/systemd/user/beszel-agent.service"
    ln -s ../beszel-agent.service "$HOME/.config/systemd/user/default.target.wants/beszel-agent.service"
  fi
  echo alpine:3 > "$STATE_DIR/images"
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE_K1p
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8092 (tailnet only)
|-- / proxy http://127.0.0.1:8092

https://test-host.tailfake.ts.net:18092 (tailnet only)
|-- / proxy http://127.0.0.1:18092
EOF_SERVE_K1p
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUB_BIN:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

UNIT_F() { printf '%s' "$HOME/.config/systemd/user/beszel-agent.service"; }
AGENT_BIN() { printf '%s' "$HOME/.local/bin/beszel-agent"; }

test_teardown_fixture() {
  echo "  teardown: sandbox fixture matches what setup.sh writes"
  deployed
  check ".env from setup.sh has BESZEL_PORT" grep -qx 'BESZEL_PORT=8092' "$SVC/.env"
  check ".env from setup.sh has BESZEL_VOLUME" grep -qx "BESZEL_VOLUME=$HOME/services/beszel/hub" "$SVC/.env"
  check "unit from setup.sh has the Description teardown looks for" \
        grep -qx 'Description=Beszel monitoring agent' "$(UNIT_F)"
  check "unit from setup.sh runs the fixed binary path" grep -qxF "ExecStart=$(AGENT_BIN)" "$(UNIT_F)"
  check "setup.sh re-enables the LaunchAgent teardown disables" \
        grep -q 'launchctl enable "gui/\$(id -u)/com.henrygd.beszel-agent"' "$SETUP"
  td_teardown
}

test_teardown_safe() {
  echo "  teardown: safe remove keeps data, .env and agent files; unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8092"         calls_have "tailscale serve --https=8092 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18092 untouched"  no_call "https=18092"
  check "never serve reset"           no_call "serve reset"
  check "agent disabled + stopped"    calls_have "systemctl --user disable --now beszel-agent.service"
  check "agent stopped before hub"    call_before "disable --now beszel-agent" "compose --project-directory"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no daemon-reload (unit kept)" no_call "daemon-reload"
  check "hub data kept"               [ -f "$(hub_dir)/data.db" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "unit file kept"              [ -f "$(UNIT_F)" ]
  check "agent binary kept"           [ -f "$(AGENT_BIN)" ]
  check "no cleanup container"        no_call "docker run"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  td_teardown
}

test_teardown_every_port_pointing_here() {
  echo "  teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE_R6v
https://test-host.tailfake.ts.net:8093 (tailnet only)
|-- / proxy http://127.0.0.1:8092

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8092

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /beszel proxy http://127.0.0.1:8092
EOF_SERVE_R6v
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8093 off"                   calls_have "serve --https=8093 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "agent port never served/off" no_call "45876"
  td_teardown
}

test_teardown_not_published() {
  echo "  teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says already off"            out_has "already off"
  check "still compose down"          [ -f "$STATE_DIR/compose_down" ]
  td_teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "  teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8092 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
  td_teardown
}

test_teardown_preflight() {
  echo "  teardown: preflight"
  td_setup
  run_teardown
  check "no .env: exits non-zero"     [ "$CODE" -ne 0 ]
  check "no .env: explains"           out_has "nothing to tear down"
  check "no .env: no compose call"   no_call "compose --project-directory"
  check "no .env: no serve off"      no_call " off"
  check "no .env: agent untouched"   no_call "systemctl"
  td_teardown
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
  check "no docker: agent untouched"  no_call "systemctl"
  rm -f "$STATE_DIR/docker_no_perm"
  sed -i.bak '/^BESZEL_VOLUME=/d' "$SVC/.env"
  run_teardown
  check "no BESZEL_VOLUME: exits non-zero" [ "$CODE" -ne 0 ]
  check "  touched nothing"           no_call " off"
  td_teardown
}

test_teardown_serve_status_fails() {
  echo "  teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  check "agent untouched"             no_call "systemctl"
  td_teardown
}

test_teardown_other_units_not_touched() {
  echo "  teardown: units that mention beszel but setup.sh did not write are named, not touched"
  deployed
  local u="$HOME/.config/systemd/user"
  printf '[Service]\nExecStart=/usr/bin/rsync -a %s/services/beszel/hub /backup\n' "$HOME" > "$u/beszel-backup.service"
  printf '[Timer]\nOnCalendar=daily\nUnit=beszel-backup.service\n' > "$u/beszel-backup.timer"
  printf '[Service]\nExecStart=/bin/true\n' > "$u/unrelated.service"
  run_teardown --purge "beszel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "warns about the backup service" out_has "beszel-backup.service mentions beszel"
  check "warns about the timer"       out_has "beszel-backup.timer mentions beszel"
  check "says nothing of unrelated"   bash -c "! grep -q unrelated <<<\"\$1\"" _ "$OUT"
  check "no systemctl call names them" no_call "beszel-backup"
  check "backup service kept"         [ -f "$u/beszel-backup.service" ]
  check "timer kept"                  [ -f "$u/beszel-backup.timer" ]
  check "own unit gone"               [ ! -e "$(UNIT_F)" ]
  td_teardown
}

test_teardown_purge() {
  echo "  teardown --purge: typed confirmation, then hub data, .env, agent and marker go"
  deployed
  local dir; dir="$(hub_dir)"
  run_teardown --purge "beszel-hub"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: data kept"       [ -f "$dir/data.db" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: unit kept"       [ -f "$(UNIT_F)" ]
  check "wrong name: binary kept"     [ -f "$(AGENT_BIN)" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: agent running"   no_call "systemctl"
  check "wrong name: serve untouched" no_call " off"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  mkdir -p "$HOME/.local/bin"; echo x > "$HOME/.local/bin/other-tool"
  run_teardown --purge "beszel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8092"         calls_have "tailscale serve --https=8092 off"
  check "agent disabled + stopped"    calls_have "systemctl --user disable --now beszel-agent.service"
  check "down only, never down -v"    no_call "down -v"
  check "hub data gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "unit file gone"              [ ! -e "$(UNIT_F)" ]
  check "daemon-reload after removing it" calls_have "systemctl --user daemon-reload"
  check "agent binary gone"           [ ! -e "$(AGENT_BIN)" ]
  check "marker ~/services/beszel gone" [ ! -e "$HOME/services/beszel" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  check "neighbour kept"              [ -f "$HOME/services/neighbour/keep" ]
  check "other ~/.local/bin files kept" [ -f "$HOME/.local/bin/other-tool" ]
  check "systemd user dir kept"       [ -d "$HOME/.config/systemd/user" ]
  check "no sudo"                     no_call "sudo"
  td_teardown
}

test_teardown_purge_root_owned() {
  echo "  teardown --purge: root-owned hub files are cleared by a local image, not sudo"
  deployed
  local dir; dir="$(hub_dir)"
  # Stand-in for the hub's root-owned .notify dir: one the user cannot empty.
  echo x > "$dir/.notify/f"; chmod 500 "$dir/.notify"
  run_teardown --purge "beszel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used an image already here"  calls_have "docker run --rm --pull never -v $dir:/x --entrypoint sh alpine:3"
  check "  that only empties the mount" calls_have "find /x -mindepth 1 -delete"
  check "never the scratch hub image" no_call "entrypoint sh henrygd"
  check "hub data gone"               [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  td_teardown
  deployed
  dir="$(hub_dir)"
  echo x > "$dir/.notify/f"; chmod 500 "$dir/.notify"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "beszel"
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  td_teardown
  deployed
  dir="$(hub_dir)"
  echo x > "$dir/.notify/f"; chmod 500 "$dir/.notify"
  printf '%s\n' alpine:edge busybox:latest > "$STATE_DIR/images"
  run_teardown --purge "beszel"
  check "only busybox:latest here: exits zero" [ "$CODE" -eq 0 ]
  check "  uses it, never pulling"    calls_have "docker run --rm --pull never -v $dir:/x --entrypoint sh busybox:latest"
  check "  hub data gone"             [ ! -e "$dir" ]
  td_teardown
  deployed
  dir="$(hub_dir)"
  echo x > "$dir/.notify/f"; chmod 500 "$dir/.notify"
  printf '%s\n' busybox:latest alpine:latest > "$STATE_DIR/images"
  run_teardown --purge "beszel"
  check "alpine:latest preferred over busybox" calls_have "docker run --rm --pull never -v $dir:/x --entrypoint sh alpine:latest"
  td_teardown
  deployed
  dir="$(hub_dir)"
  echo x > "$dir/.notify/f"; chmod 500 "$dir/.notify"
  : > "$STATE_DIR/images"
  run_teardown --purge "beszel"
  check "no local image: exits non-zero" [ "$CODE" -ne 0 ]
  check "  never pulls one"           no_call "docker run"
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  td_teardown
}

test_teardown_purge_agent_files_not_ours() {
  echo "  teardown --purge: an edited unit or a symlinked binary is kept"
  deployed
  printf '[Unit]\nDescription=My own beszel agent\n[Service]\nExecStart=/opt/beszel-agent\n' > "$(UNIT_F)"
  rm -f "$(AGENT_BIN)"; echo mine > "$HOME/my-build"; ln -s "$HOME/my-build" "$(AGENT_BIN)"
  run_teardown --purge "beszel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "edited unit kept"            [ -f "$(UNIT_F)" ]
  check "  and says why"              out_has "was not written by setup.sh"
  check "symlinked binary kept"       [ -L "$(AGENT_BIN)" ]
  check "  its target kept"           [ -f "$HOME/my-build" ]
  check "hub data still gone"         [ ! -e "$HOME/services/beszel/hub" ]
  td_teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "  teardown --purge: refuses a data dir outside ~/services/beszel"
  deployed
  set_env BESZEL_VOLUME "$HOME"
  run_teardown --purge "beszel"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  check "agent untouched"             no_call "systemctl"
  set_env BESZEL_VOLUME "$HOME/services/../x"
  run_teardown --purge "beszel"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  set_env BESZEL_VOLUME "$HOME/services/"
  run_teardown --purge "beszel"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./beszel" "$HOME/services/beszel/.." "$HOME/services/beszel/hub/."; do
    set_env BESZEL_VOLUME "$dotted"
    run_teardown --purge "beszel"
    check "'.' / '..' component refused: ${dotted#"$HOME"/}" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "hub data never touched"      [ -f "$HOME/services/beszel/hub/data.db" ]
  check "binary never touched"        [ -f "$(AGENT_BIN)" ]
  td_teardown
}

test_teardown_purge_trailing_slashes() {
  echo "  teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  set_env BESZEL_VOLUME "$HOME/services//"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "beszel"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/beszel/alias"
  set_env BESZEL_VOLUME "$HOME/services/beszel/alias"
  run_teardown --purge "beszel"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  set_env BESZEL_VOLUME "$HOME/services/beszel/hub///"
  run_teardown --purge "beszel"
  check "trailing slashes on the real dir: exits zero" [ "$CODE" -eq 0 ]
  check "  hub data gone"             [ ! -e "$HOME/services/beszel/hub" ]
  check "  neighbour kept"            [ -f "$HOME/services/neighbour/keep" ]
  td_teardown
}

test_teardown_purge_own_dir_only() {
  echo "  teardown --purge: only ~/services/beszel itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  set_env BESZEL_VOLUME "$HOME/services/neighbour"
  run_teardown --purge "beszel"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  mkdir -p "$HOME/services/beszel-old"; echo x > "$HOME/services/beszel-old/keep"
  set_env BESZEL_VOLUME "$HOME/services/beszel-old"
  run_teardown --purge "beszel"
  check "lookalike name refused"      [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/beszel-old/keep" ]
  mkdir -p "$HOME/services/beszel/a:b"
  set_env BESZEL_VOLUME "$HOME/services/beszel/a:b"
  run_teardown --purge "beszel"
  check "a colon in the path refused" [ "$CODE" -ne 0 ]
  td_teardown
}

test_teardown_purge_missing_data_dir() {
  echo "  teardown --purge: a hub dir already gone is fine; the marker still goes"
  deployed
  rm -rf "$(hub_dir)"
  run_teardown --purge "beszel"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "unit gone"                   [ ! -e "$(UNIT_F)" ]
  check "marker gone"                 [ ! -e "$HOME/services/beszel" ]
  td_teardown
}

test_teardown_purge_services_root_is_a_link() {
  echo "  teardown --purge: ~/services that is really \$HOME is refused"
  deployed
  mkdir -p "$HOME/real-services"
  mv "$HOME/services/"* "$HOME/real-services/" 2>/dev/null
  rmdir "$HOME/services"
  ln -s "$HOME" "$HOME/services"
  mkdir -p "$HOME/beszel/hub"; echo x > "$HOME/beszel/hub/keep"
  run_teardown --purge "beszel"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"   [ -f "$HOME/beszel/hub/keep" ]
  check "binary kept"                 [ -f "$(AGENT_BIN)" ]
  rm -f "$HOME/services"
  td_teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "  teardown --purge: a checkout living inside ~/services/beszel survives"
  deployed
  local top="$HOME/services/beszel/setup-server" repo
  repo="$top/services/beszel"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$top/other.env"
  sed -i.bak "s#^BESZEL_VOLUME=.*#BESZEL_VOLUME=$HOME/services/beszel#" "$repo/.env"
  OUT="$(printf '%s\n' "beszel" | PATH="$STUB_BIN:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "data dir holding the checkout: exits non-zero" [ "$CODE" -ne 0 ]
  check "  checkout intact"           [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$top/other.env" ]
  sed -i.bak "s#^BESZEL_VOLUME=.*#BESZEL_VOLUME=$HOME/services/beszel/hub#" "$repo/.env"
  OUT="$(printf '%s\n' "beszel" | PATH="$STUB_BIN:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "hub dir next to the checkout: exits zero" [ "$CODE" -eq 0 ]
  check "  checkout still intact"     [ -f "$repo/teardown.sh" ]
  check "  other services' files kept" [ -f "$top/other.env" ]
  check "  non-empty marker kept"     [ -d "$HOME/services/beszel" ]
  td_teardown
}

test_teardown_quoted_env() {
  echo "  teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^BESZEL_PORT=.*/export BESZEL_PORT='8092'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8092 off"                   calls_have "serve --https=8092 off"
  td_teardown
  deployed
  sed -i.bak -e 's/^BESZEL_PORT=.*/BESZEL_PORT="8092"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  td_teardown
  deployed
  sed -i.bak -e 's/^BESZEL_PORT=.*/BESZEL_PORT=8092 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  td_teardown
  deployed
  sed -i.bak -e 's/^BESZEL_PORT=.*/BESZEL_PORT=80x2/' "$SVC/.env"
  run_teardown
  check "non-numeric port refused"    [ "$CODE" -ne 0 ]
  check "  touched nothing"           no_call " off"
  td_teardown
}

test_teardown_home_variable_in_env() {
  echo "  teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(hub_dir)"
  sed -i.bak "s#^BESZEL_VOLUME=.*#BESZEL_VOLUME=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "beszel"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  td_teardown
  deployed
  dir="$(hub_dir)"
  sed -i.bak "s#^BESZEL_VOLUME=.*#BESZEL_VOLUME=\$HOME${dir#"$HOME"}#" "$SVC/.env"
  run_teardown --purge "beszel"
  check "bare \$HOME form: exits zero" [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  td_teardown
  deployed
  dir="$(hub_dir)"
  sed -i.bak "s#^BESZEL_VOLUME=.*#BESZEL_VOLUME='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "beszel"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  td_teardown
}

test_teardown_env_lint() {
  echo "  teardown: .env that Compose could read differently is refused"
  deployed
  printf 'BESZEL_VOLUME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "BESZEL_VOLUME is set more than once"
  check "  touched nothing"           [ ! -f "$STATE_DIR/compose_down" ]
  td_teardown
  deployed
  printf 'X="first\nBESZEL_VOLUME=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "multi-line value: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it does not close"    out_has "does not close on its line"
  td_teardown
  deployed
  printf 'Y="a\\"b"\n' >> "$SVC/.env"
  run_teardown
  check "backslash escape: exits non-zero" [ "$CODE" -ne 0 ]
  td_teardown
}

test_teardown_refuses_compose_overrides() {
  echo "  teardown: COMPOSE_FILE / COMPOSE_PROJECT_NAME in .env or the shell are refused"
  local v
  for v in COMPOSE_FILE COMPOSE_PROJECT_NAME; do
    deployed
    printf '%s=%s\n' "$v" "$HOME/services/neighbour/docker-compose.yml" >> "$SVC/.env"
    run_teardown --purge "beszel"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  agent untouched"           no_call "systemctl"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    td_teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  td_teardown
}

test_teardown_macos() {
  echo "  teardown (macOS path): launchd bootout + disable, plist kept; --purge removes it"
  export FAKE_OS=Darwin
  deployed
  local plist="$HOME/Library/LaunchAgents/com.henrygd.beszel-agent.plist"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "agent booted out"            calls_have "launchctl bootout gui/1000/com.henrygd.beszel-agent"
  check "agent disabled across logins" calls_have "launchctl disable gui/1000/com.henrygd.beszel-agent"
  check "no systemctl on macOS"       no_call "systemctl"
  check "plist kept"                  [ -f "$plist" ]
  check "binary kept"                 [ -f "$(AGENT_BIN)" ]
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  run_teardown --purge "beszel"
  check "purge: exits zero"           [ "$CODE" -eq 0 ]
  check "purge: plist gone"           [ ! -e "$plist" ]
  check "purge: agent log gone"       [ ! -e "$HOME/Library/Logs/beszel-agent.log" ]
  check "purge: LaunchAgents dir kept" [ -d "$HOME/Library/LaunchAgents" ]
  check "purge: binary gone"          [ ! -e "$(AGENT_BIN)" ]
  check "purge: hub data gone"        [ ! -e "$HOME/services/beszel" ]
  td_teardown
}

echo "  teardown sandbox (temp \$HOME, generated PATH stubs)"
test_teardown_fixture
test_teardown_safe
test_teardown_every_port_pointing_here
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_serve_status_fails
test_teardown_other_units_not_touched
test_teardown_purge
test_teardown_purge_root_owned
test_teardown_purge_agent_files_not_ours
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_purge_own_dir_only
test_teardown_purge_missing_data_dir
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_quoted_env
test_teardown_home_variable_in_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_macos

if [ "${1:-}" = "--live" ]; then
  echo "  live checks"
  PORT="$(grep '^BESZEL_PORT=' "$SERVICE_DIR/.env" 2>/dev/null | cut -d= -f2)"
  PORT="${PORT:-8092}"
  check "hub healthy" curl -fsS "http://127.0.0.1:$PORT/api/health"
  check "hub container running" \
      bash -c "docker inspect -f '{{.State.Running}}' beszel | grep -q true"
  check "agent unit active" systemctl --user is-active beszel-agent.service
  check "agent on loopback:45876" \
      bash -c "ss -ltn | grep -q '127.0.0.1:45876'"
  check "agent NOT on all interfaces" \
      bash -c "! ss -ltn | grep -E '(\*|0\.0\.0\.0):45876' -q"
  check "tailscale serve maps :$PORT" \
      bash -c "tailscale serve status | grep -q ':$PORT'"
  check "stats are fresh (<3 min old)" python3 - "$SERVICE_DIR" "$PORT" <<'PYEOF'
import json, sys, time, urllib.request
from datetime import datetime, timezone
svc, port = sys.argv[1], sys.argv[2]
env = dict(l.strip().split("=", 1) for l in open(f"{svc}/.env")
           if "=" in l and not l.startswith("#"))
api = f"http://127.0.0.1:{port}/api"
def req(p, d=None, t=None):
    r = urllib.request.Request(api+p,
        data=json.dumps(d).encode() if d else None,
        headers={"Content-Type": "application/json",
                 **({"Authorization": t} if t else {})})
    return json.load(urllib.request.urlopen(r, timeout=10))
tok = req("/collections/_superusers/auth-with-password",
          {"identity": env["BESZEL_ADMIN_EMAIL"],
           "password": env["BESZEL_ADMIN_PASSWORD"]})["token"]
rec = req("/collections/system_stats/records?sort=-created&perPage=1",
          t=tok)["items"][0]
age = time.time() - datetime.strptime(
    rec["created"], "%Y-%m-%d %H:%M:%S.%fZ"
).replace(tzinfo=timezone.utc).timestamp()
sys.exit(0 if age < 180 else 1)
PYEOF
fi

echo
[ "$FAIL" -eq 0 ] && green "  $PASS passed" || { red "  $FAIL failed, $PASS passed"; exit 1; }
