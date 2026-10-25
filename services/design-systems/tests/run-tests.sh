#!/usr/bin/env bash
#
# Tests for services/design-systems/setup.sh + deploy.sh + teardown.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/deploy.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"

  # A fake working clone: .git/ + tools/catalog.py is what setup.sh checks;
  # systems/ exists so the LFS pointer scan has somewhere to look, and the
  # stub uv/venv-python/python3 fill in .venv, docs/ and site/ at build time.
  export SOURCE_REPO="$SANDBOX/repo"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/tools" "$SOURCE_REPO/systems"
  echo "# catalog stub" > "$SOURCE_REPO/tools/catalog.py"
  echo "markdown==0.0.0" > "$SOURCE_REPO/requirements.txt"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID FAKE_UNAME LOCAL_PORT HTTPS_PORT SOURCE_REPO BRANCH POLL_SECONDS STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

# Run the installed poller script directly (as the timer would).
run_poll() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/design-systems/bin/deploy.sh" "$@" 2>&1)"
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
out_lacks()  { ! grep -q "$1" <<<"$OUT"; }
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
  check "wrote no .env"  [ ! -f "$SVC/.env" ]
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

test_preflight_repo_missing() {
  echo "• preflight fails when the clone is not where SOURCE_REPO points"
  setup
  export SOURCE_REPO="$SANDBOX/not-here"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "design-systems repo not found"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_wrong_repo() {
  echo "• preflight fails when the clone is not design-systems"
  setup
  mkdir -p "$SANDBOX/other/.git"
  export SOURCE_REPO="$SANDBOX/other"
  run_deploy
  check "exits non-zero"    [ "$CODE" -ne 0 ]
  check "names the problem" out_has "does not look like the design-systems repo"
  check "wrote no .env"     [ ! -f "$SVC/.env" ]
  teardown
}

test_lfs_pointers_fixed() {
  echo "• preflight materialises LFS pointers via git lfs pull"
  setup
  mkdir -p "$SOURCE_REPO/systems/foo/screenshots"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:deadbeef\nsize 12345\n' \
    > "$SOURCE_REPO/systems/foo/screenshots/p.png"
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "ran git lfs pull"    calls_have "git -C .* lfs pull"
  check "pointer replaced"    sh -c '! head -c 9 "$0" | grep -q "version h"' "$SOURCE_REPO/systems/foo/screenshots/p.png"
  teardown
}

test_lfs_pointers_unfixable() {
  echo "• preflight fails when LFS pointers cannot be materialised"
  setup
  mkdir -p "$SOURCE_REPO/systems/foo/screenshots"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:deadbeef\nsize 12345\n' \
    > "$SOURCE_REPO/systems/foo/screenshots/p.png"
  touch "$STATE_DIR/lfs_broken"
  run_deploy
  check "exits non-zero"      [ "$CODE" -ne 0 ]
  check "names the problem"   out_has "Git LFS pointer files remain"
  check "wrote no .env"       [ ! -f "$SVC/.env" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: full happy path (build, container, poller, serve)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env has repo path"          env_has "SOURCE_REPO=$SOURCE_REPO"
  check ".env has poll interval"      env_has "POLL_SECONDS=86400"
  check ".env has public URL"         env_has "PUBLIC_URL=https://test-host.tailfake.ts.net:8108/"
  check ".env is owner-only"          sh -c '[ "$(stat -c %a "$0" 2>/dev/null || stat -f %Lp "$0")" = 600 ]' "$SVC/.env"
  check "deploy script installed"     [ -x "$HOME/services/design-systems/bin/deploy.sh" ]
  check "media dir created"           [ -d "$HOME/services/design-systems/media/refero" ]
  check "nginx conf has media alias"  grep -q "refero-media" "$HOME/services/design-systems/nginx.conf"
  check "nginx conf gzips"            grep -q "gzip on" "$HOME/services/design-systems/nginx.conf"
  check "nginx conf gzips json"       grep -q "gzip_types .*application/json" "$HOME/services/design-systems/nginx.conf"
  check "thumbs cache a day"          sh -c 'grep -A2 "gallery/thumbs" "$1" | grep -q "max-age=86400"' _ "$HOME/services/design-systems/nginx.conf"
  check "media caches a month"        sh -c 'grep -A2 "refero-media" "$1" | grep -q "max-age=2592000"' _ "$HOME/services/design-systems/nginx.conf"
  check "repo paths revalidate"       grep -q "srv/repo/systems/.*no-cache" "$HOME/services/design-systems/nginx.conf"
  check "default is no-cache"         sh -c 'grep -A2 "try_files" "$1" | grep -q "Cache-Control .no-cache"' _ "$HOME/services/design-systems/nginx.conf"
  check "compose mounts media"        grep -q "srv/media" "$SERVICE_DIR/docker-compose.yml"
  check "env path baked into script"  grep -q "$SVC/.env" "$HOME/services/design-systems/bin/deploy.sh"
  check "venv created (uv venv)"      calls_have "uv venv"
  check "deps installed (uv pip)"     calls_have "uv pip install"
  check "gallery data built"          calls_have "python3 tools/catalog.py build"
  check "scorecard built"             calls_have "python3 tools/scorecard.py"
  check "docs site built"             calls_have "python tools/site.py"
  check "site swapped into current"   [ -f "$HOME/services/design-systems/www/current/index.html" ]
  check "gallery page in release"     [ -f "$HOME/services/design-systems/www/current/gallery/index.html" ]
  check "current is a release link"   sh -c '[ "$(readlink "$1")" = releases/aaa1111 ]' _ "$HOME/services/design-systems/www/current"
  check "recorded built sha"          grep -qx aaa1111 "$HOME/services/design-systems/state/built-sha"
  check "compose up invoked"          [ -f "$STATE_DIR/compose_up" ]
  if [ "$OS" = "Linux" ]; then
    check "timer unit written"        [ -f "$HOME/.config/systemd/user/design-systems-deploy.timer" ]
    check "timer enabled"             calls_have "systemctl --user enable --now design-systems-deploy.timer"
    check "lingering enabled"         calls_have "loginctl enable-linger"
  else
    check "launch agent written"      [ -f "$HOME/Library/LaunchAgents/com.design-systems.deploy.plist" ]
    check "label enabled (undoes teardown's disable)" calls_have "launchctl enable gui/.*/com.design-systems.deploy"
    check "enabled before bootstrap"  [ "$(call_line "launchctl enable")" -lt "$(call_line "launchctl bootstrap")" ]
  fi
  check "served on tailscale :8108"   calls_have "tailscale serve --bg --https=8108 http://127.0.0.1:8108"
  check "prints final URL"            out_has "https://test-host.tailfake.ts.net:8108/gallery/"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, build skipped when nothing changed, no sudo"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "# CUSTOM-MARK do-not-clobber" >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "edited .env preserved"   env_has "CUSTOM-MARK"
  check "reports up to date"      out_has "up to date at aaa1111"
  check "no rebuild"              no_call "python tools/site.py"
  check "never invoked sudo"      no_call "^sudo "
  check "compose up re-invoked"   [ -f "$STATE_DIR/compose_up" ]
  teardown
}

test_nginx_conf_stale_warns() {
  echo "• pre-existing nginx.conf without the gzip/Cache-Control block: kept, but warns"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/design-systems"
  cat > "$HOME/services/design-systems/nginx.conf" <<'NGX'
server {
    listen 80;
    location /refero-media/ { alias /srv/media/refero/; }
    location / { try_files $uri $uri/ =404; }
}
NGX
  cp "$HOME/services/design-systems/nginx.conf" "$SANDBOX/nginx.orig"
  run_deploy
  check "exits zero"               [ "$CODE" -eq 0 ]
  check "conf left untouched"      cmp -s "$SANDBOX/nginx.orig" "$HOME/services/design-systems/nginx.conf"
  check "warns to update"          out_has "predates the gzip/Cache-Control config"
  check "no media-mount warning"   out_lacks "predates the refero media mount"
  teardown
}

test_push_triggers_redeploy() {
  echo "• poller: new commit on the repo -> rebuild and swap"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  echo "bbb2222" > "$STATE_DIR/local_sha"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "deploys the new sha"     out_has "deploying bbb2222"
  check "rebuilt the site"        calls_have "python tools/site.py"
  check "built sha updated"       grep -qx bbb2222 "$HOME/services/design-systems/state/built-sha"
  check "previous release kept"   [ -d "$HOME/services/design-systems/www/releases/aaa1111" ]
  check "current repointed"       sh -c '[ "$(readlink "$1")" = releases/bbb2222 ]' _ "$HOME/services/design-systems/www/current"
  check "current build swapped"   [ -f "$HOME/services/design-systems/www/current/index.html" ]
  teardown
}

test_force_rebuild_same_sha() {
  echo "• --force rebuild of the live sha: current never dangles, old build stays previous"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  : > "$CALLS_LOG"
  run_poll --force
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "rebuilt"                     calls_have "python tools/site.py"
  check "current resolves"            [ -f "$HOME/services/design-systems/www/current/index.html" ]
  check "current is the new build"    sh -c 'readlink "$1" | grep -q "aaa1111\.rebuild-"' _ "$HOME/services/design-systems/www/current"
  check "two releases kept"           sh -c '[ "$(ls -d "$1"/releases/*/ | wc -l)" -eq 2 ]' _ "$HOME/services/design-systems/www"
  check "old build kept as previous"  [ -d "$HOME/services/design-systems/www/releases/aaa1111" ]
  teardown
}

test_deps_resync_on_requirements_change() {
  echo "• poller re-syncs .venv when requirements.txt is newer than the last install"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "deps installed once"   calls_have "uv pip install"
  : > "$CALLS_LOG"
  # requirements.txt newer than .venv/.deploy-stamp -> reinstall on a rebuild
  touch -t 209901010000 "$SOURCE_REPO/requirements.txt"
  run_poll --force
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "deps re-installed"   calls_have "uv pip install"
  teardown
}

test_spaced_repo_path() {
  echo "• SOURCE_REPO with spaces: .env stays shell-parseable end to end"
  setup
  touch "$STATE_DIR/operator"
  export SOURCE_REPO="$SANDBOX/repo with space"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/tools" "$SOURCE_REPO/systems"
  echo "# catalog stub" > "$SOURCE_REPO/tools/catalog.py"
  echo "x" > "$SOURCE_REPO/requirements.txt"
  run_deploy
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "path in .env"        env_has "SOURCE_REPO="
  check "built the site"      calls_have "python tools/site.py"
  check "site swapped in"     [ -f "$HOME/services/design-systems/www/current/index.html" ]
  teardown
}

test_poll_lock() {
  echo "• poller: concurrent run skips cleanly while the lock is held"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir "$HOME/services/design-systems/.deploy.lock"
  : > "$CALLS_LOG"
  run_poll
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "reports the skip"    out_has "another deploy is running"
  check "touched no git"      no_call "git -C .* rev-parse"
  rmdir "$HOME/services/design-systems/.deploy.lock"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT override (HTTPS follows local by default)"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=9999
  run_deploy
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "served on :9999 -> 9999" calls_have "tailscale serve --bg --https=9999 http://127.0.0.1:9999"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8108"
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

no_external_listener() {
  local port="$1"
  if command -v ss >/dev/null; then
    ! (ss -ltn | awk -v p=":$port" '$4 ~ p"$" {print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):')
  else
    ! (lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):')
  fi
}

# A bare request to /refero-media/ can't tell "autoindex off" apart from
# "nginx can't read the dir". Drop a sentinel file and fetch it back through
# the alias — only a working mount returns the contents.
media_alias_serves_file() {
  local port="$1" svc_home="$2" dir sent body
  dir="$svc_home/media/refero"
  [ -d "$dir" ] || return 1
  sent="$dir/.live-check-$$"
  # chmod: under a 077 umask the sentinel would land 0600 and the nginx
  # worker could not read it even when the alias is wired right.
  echo "live-check" > "$sent" && chmod 644 "$sent" || return 1
  body="$(curl -fsS "http://127.0.0.1:$port/refero-media/.live-check-$$" 2>/dev/null)"
  rm -f "$sent"
  [ "$body" = "live-check" ]
}

# Same sentinel trick for the Cache-Control policy: the long max-age is what
# lets a month of refero media stay off the wire.
media_serves_cache_header() {
  local port="$1" svc_home="$2" dir sent headers
  dir="$svc_home/media/refero"
  [ -d "$dir" ] || return 1
  sent="$dir/.live-check-$$"
  echo "live-check" > "$sent" && chmod 644 "$sent" || return 1
  headers="$(curl -fsSI "http://127.0.0.1:$port/refero-media/.live-check-$$" 2>/dev/null)"
  rm -f "$sent"
  grep -qi 'cache-control: public, max-age=2592000' <<<"$headers"
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  local ts port url svc_home repo
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  url="$(sed -n 's|^PUBLIC_URL=\(.*\)/$|\1|p' "$SERVICE_DIR/.env")"
  svc_home="$(sed -n 's/^SERVICE_HOME=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  repo="$(sed -n 's/^SOURCE_REPO=\(.*\)$/\1/p' "$SERVICE_DIR/.env")"
  live_check "container running"        sh -c "docker inspect -f '{{.State.Status}}' design-systems | grep -qx running"
  live_check "gallery responds"         curl -fsS "http://127.0.0.1:$port/gallery/"
  live_check "gallery data responds"    sh -c "curl -fsS 'http://127.0.0.1:$port/gallery/data.json' | grep -q systems"
  live_check "repo path responds"       sh -c "curl -fsS 'http://127.0.0.1:$port/catalog.json' | grep -q systems"
  live_check "media alias wired"        media_alias_serves_file "$port" "$svc_home"
  live_check "data.json gzips"          sh -c "curl -fsS -o /dev/null -D - -H 'Accept-Encoding: gzip' 'http://127.0.0.1:$port/gallery/data.json' | grep -qi 'content-encoding: gzip'"
  live_check "data.json revalidates"    sh -c "curl -fsSI 'http://127.0.0.1:$port/gallery/data.json' | grep -qi 'cache-control: no-cache'"
  live_check "media caches long"        media_serves_cache_header "$port" "$svc_home"
  live_check "no wildcard listener"     no_external_listener "$port"
  live_check "built sha matches repo"   sh -c "[ \"\$(git -C '$repo' rev-parse HEAD)\" = \"\$(cat '$svc_home/state/built-sha')\" ]"
  if [ "$OS" = "Linux" ]; then
    live_check "deploy timer active"    sh -c "systemctl --user is-active design-systems-deploy.timer | grep -qx active"
    live_check "lingering enabled"      sh -c "loginctl show-user $USER -p Linger --value | grep -qx yes"
  else
    live_check "launch agent loaded"    sh -c "launchctl print gui/$(id -u)/com.design-systems.deploy"
  fi
  live_check "serve maps :$port"        sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS responds"   curl -fsS -o /dev/null --max-time 30 "$url/gallery/"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: the clone lives where it does on the real box
# (~/dev/design-systems) with a file of the user's own in it, setup.sh has
# run, the media mirror holds a shot, designs-trigger.service (which
# setup.sh does NOT create) sits beside the poller's units, and Serve maps
# this port while neighbours sit on other ports (one a lookalike suffix).
deployed() {
  setup
  export SOURCE_REPO="$HOME/dev/design-systems"
  mkdir -p "$SOURCE_REPO/.git" "$SOURCE_REPO/tools" "$SOURCE_REPO/systems" "$SOURCE_REPO/scripts"
  echo "# catalog stub" > "$SOURCE_REPO/tools/catalog.py"
  echo "markdown==0.0.0" > "$SOURCE_REPO/requirements.txt"
  echo "my notes" > "$SOURCE_REPO/systems/NOTES.md"
  echo "ref: refs/heads/main" > "$SOURCE_REPO/.git/HEAD"
  touch "$STATE_DIR/operator"
  run_deploy
  unset SOURCE_REPO
  REPO="$HOME/dev/design-systems"
  SH="$HOME/services/design-systems"
  UNITS="$HOME/.config/systemd/user"
  echo shot > "$SH/media/refero/a.jpg"
  mkdir -p "$UNITS"
  printf '[Service]\nExecStart=/usr/bin/python3 %s/scripts/deploy_trigger.py\n' "$REPO" \
    > "$UNITS/designs-trigger.service"
  printf '[Service]\nExecStart=/bin/true\n' > "$UNITS/unrelated.service"
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8108 (tailnet only)
|-- / proxy http://127.0.0.1:8108

https://test-host.tailfake.ts.net:18108 (tailnet only)
|-- / proxy http://127.0.0.1:18108
EOF_SERVE
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

# Line number of the first call matching $1 (0 when absent).
call_line() { grep -n -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }

repo_intact() {
  [ -f "$REPO/systems/NOTES.md" ] && [ -f "$REPO/.git/HEAD" ] && [ -f "$REPO/tools/catalog.py" ]
}

nothing_changed() {
  [ ! -f "$STATE_DIR/compose_down" ] && no_call " off" && no_call "systemctl" && no_call "launchctl" \
    && [ -f "$SVC/.env" ] && [ -f "$SH/www/current/index.html" ] && repo_intact
}

# Back-date a deploy lock past deploy.sh's 60-minute stale mark.
age_lock() { touch -t 202001010000 "$1"; }

# teardown.sh --purge, with a hook run while the confirmation prompt waits:
# $1 is the answer, $2 a snippet run once the prompt is on screen (before
# the answer is sent). Sets OUT and CODE like run_teardown.
run_purge_at_prompt() {
  local out="$SANDBOX/teardown.out"
  : > "$out"
  { for _ in $(seq 1 100); do grep -q "to confirm" "$out" && break; sleep 0.1; done
    eval "$2"
    printf '%s\n' "$1"; } | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge > "$out" 2>&1
  CODE=$?
  OUT="$(cat "$out")"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps state and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8108"         calls_have "tailscale serve --https=8108 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18108 untouched"  no_call "https=18108"
  check "never serve reset"           no_call "serve reset"
  if [ "$OS" = "Linux" ]; then
    check "timer disabled + stopped"  calls_have "systemctl --user disable --now design-systems-deploy.timer"
    check "deploy service stopped"    calls_have "systemctl --user stop design-systems-deploy.service"
    check "timer before its service"  [ "$(call_line "disable --now design-systems-deploy.timer")" -lt "$(call_line "stop design-systems-deploy.service")" ]
    check "poller stopped before down" [ "$(call_line "design-systems-deploy.timer")" -lt "$(call_line "compose --project-directory")" ]
    check "timer unit file kept"      [ -f "$UNITS/design-systems-deploy.timer" ]
    check "service unit file kept"    [ -f "$UNITS/design-systems-deploy.service" ]
    check "no daemon-reload"          no_call "daemon-reload"
  else
    check "launch agent booted out"   calls_have "launchctl bootout gui/.*/com.design-systems.deploy"
    check "launch agent disabled (no reload at login)" calls_have "launchctl disable gui/.*/com.design-systems.deploy"
  fi
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "built site kept"             [ -f "$SH/www/current/index.html" ]
  check "media mirror kept"           [ -f "$SH/media/refero/a.jpg" ]
  check "nginx.conf kept"             [ -f "$SH/nginx.conf" ]
  check "deploy script kept"          [ -x "$SH/bin/deploy.sh" ]
  check "built sha kept"              [ -f "$SH/state/built-sha" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "clone untouched"             repo_intact
  check "lingering untouched"         no_call "loginctl"
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_foreign_units() {
  echo "• teardown: units setup.sh did not create are named, never touched"
  deployed
  printf '[Service]\nExecStart=/bin/sh -c "ls %s/services/design-systems"\n' "$HOME" \
    > "$UNITS/notes-sync.service"
  run_teardown --purge "design-systems"
  check "exits zero"                    [ "$CODE" -eq 0 ]
  if [ "$OS" = "Linux" ]; then
    check "warns about designs-trigger" out_has "designs-trigger.service .*setup.sh did not create it"
    check "warns about a unit that mentions it" out_has "notes-sync.service .*setup.sh did not create it"
    check "no warning for an unrelated unit"    out_lacks "unrelated.service"
  fi
  check "no call names designs-trigger" no_call "designs-trigger"
  check "no call names notes-sync"      no_call "notes-sync"
  check "designs-trigger file kept"     [ -f "$UNITS/designs-trigger.service" ]
  check "notes-sync file kept"          [ -f "$UNITS/notes-sync.service" ]
  check "unrelated unit kept"           [ -f "$UNITS/unrelated.service" ]
  teardown
}

test_teardown_same_compose_files_as_up() {
  echo "• teardown: down uses the file set up used (no -f; a local override auto-loads)"
  deployed
  printf 'services:\n  design-systems:\n    extra_hosts:\n      - "host.docker.internal:host-gateway"\n' \
    > "$SVC/docker-compose.override.yml"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "down is the up call's twin"  grep -qx "docker compose --project-directory $SVC down" "$CALLS_LOG"
  check "no -f passed"                no_call "compose .* -f "
  check "setup.sh up passes no -f either" grep -qF 'docker compose --project-directory "$SERVICE_DIR" up -d' "$SVC/setup.sh"
  check "override left in place"      [ -f "$SVC/docker-compose.override.yml" ]
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
  printf 'https://test-host.tailfake.ts.net:8108 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
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
  cat > "$STATE_DIR/serve_status" <<EOF_SERVE
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8108

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8108

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /design proxy http://127.0.0.1:8108

https://test-host.tailfake.ts.net:8108 (tailnet only)
|-- / proxy http://127.0.0.1:8108
|-- /api proxy http://127.0.0.1:8765
EOF_SERVE
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check ":8108 with a foreign /api left on" no_call "https=8108 off"
  check "warns about :8108"           out_has "HTTPS :8108 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "nothing changed"             nothing_changed
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
  check "root: nothing changed"       nothing_changed
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: nothing changed" nothing_changed
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  check "no docker: nothing changed"  nothing_changed
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then exactly setup.sh's state goes"
  deployed
  mkdir "$SH/.deploy.lock"; age_lock "$SH/.deploy.lock"   # stale: a live one refuses (see below)
  run_teardown --purge "design"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: nothing changed" nothing_changed
  check "wrong name: units kept"      [ -f "$UNITS/design-systems-deploy.timer" ]
  check "wrong name: media kept"      [ -f "$SH/media/refero/a.jpg" ]
  run_teardown --purge ""
  check "empty answer: exits non-zero" [ "$CODE" -ne 0 ]
  check "empty answer: nothing changed" nothing_changed
  run_teardown --purge "design-systems"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8108"         calls_have "tailscale serve --https=8108 off"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "  without -v"                no_call "down -v"
  check "bin/ gone"                   [ ! -e "$SH/bin" ]
  check "state/ gone"                 [ ! -e "$SH/state" ]
  check "www/ gone"                   [ ! -e "$SH/www" ]
  check "media/ gone"                 [ ! -e "$SH/media" ]
  check "nginx.conf gone"             [ ! -e "$SH/nginx.conf" ]
  check "stale deploy lock gone"      [ ! -e "$SH/.deploy.lock" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "marker dir gone"             [ ! -e "$SH" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  if [ "$OS" = "Linux" ]; then
    check "timer unit gone"           [ ! -e "$UNITS/design-systems-deploy.timer" ]
    check "service unit gone"         [ ! -e "$UNITS/design-systems-deploy.service" ]
    check "daemon-reload after"       [ "$(call_line "daemon-reload")" -gt "$(call_line "disable --now design-systems-deploy.timer")" ]
    check "designs-trigger unit kept" [ -f "$UNITS/designs-trigger.service" ]
  fi
  check "clone survives --purge"      repo_intact
  check "clone's own scripts dir kept" [ -d "$REPO/scripts" ]
  check "lingering untouched"         no_call "loginctl"
  run_teardown --purge "design-systems"
  check "re-run after purge: no .env, refuses" [ "$CODE" -ne 0 ]
  check "  and still the clone"       repo_intact
  teardown
}

test_teardown_purge_keeps_other_files() {
  echo "• teardown --purge: files setup.sh did not create keep the marker dir"
  deployed
  echo mine > "$SH/notes.txt"
  run_teardown --purge "design-systems"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "www/ gone"                   [ ! -e "$SH/www" ]
  check "media/ gone"                 [ ! -e "$SH/media" ]
  check "the user's file kept"        [ -f "$SH/notes.txt" ]
  check "says the dir is kept"        out_has "still holds files setup.sh did not create"
  teardown
}

test_teardown_purge_missing_state_dir() {
  echo "• teardown --purge: a service dir already gone is fine"
  deployed
  rm -rf "${SH:?}"
  run_teardown --purge "design-systems"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  [ "$OS" = "Linux" ] && check "unit files gone" [ ! -e "$UNITS/design-systems-deploy.timer" ]
  check "clone untouched"             repo_intact
  teardown
}

test_teardown_purge_refuses_repo_overlap() {
  echo "• teardown --purge: a SOURCE_REPO inside (or holding) the service dir is refused"
  deployed
  mkdir -p "$SH/www/clone/.git"; echo mine > "$SH/www/clone/precious"
  sed -i.bak "s#^SOURCE_REPO=.*#SOURCE_REPO=$SH/www/clone#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "clone inside: exits non-zero" [ "$CODE" -ne 0 ]
  check "  clone kept"                [ -f "$SH/www/clone/precious" ]
  check "  nothing changed"           nothing_changed
  sed -i.bak "s#^SOURCE_REPO=.*#SOURCE_REPO=$HOME/services#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "clone holding it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  sed -i.bak "s#^SOURCE_REPO=.*#SOURCE_REPO=$SH#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "clone is the dir: exits non-zero" [ "$CODE" -ne 0 ]
  # Relative (or ~, which Compose does not expand): resolved against the
  # caller's cwd, so the overlap check cannot be trusted. Run from inside
  # the service dir, where "www/clone" is the clone under the purge.
  # shellcheck disable=SC2088  # a literal ~ is the point: Compose does not expand it
  for rel in "www/clone" "dev/design-systems" "~/dev/design-systems"; do
    sed -i.bak "s#^SOURCE_REPO=.*#SOURCE_REPO=$rel#" "$SVC/.env"
    OUT="$(cd "$SH" && printf '%s\n' design-systems | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" --purge 2>&1)"; CODE=$?
    check "relative SOURCE_REPO=$rel: exits non-zero" [ "$CODE" -ne 0 ]
    check "  says it is not absolute"   out_has "is not an absolute path"
    check "  clone kept"                [ -f "$SH/www/clone/precious" ]
    check "  nothing changed"           nothing_changed
  done
  sed -i.bak "/^SOURCE_REPO=/d" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "SOURCE_REPO missing: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "SOURCE_REPO is missing"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_refuses_symlinked_child() {
  echo "• teardown --purge: a symlinked www/ or media/ is refused, its target kept"
  deployed
  mkdir -p "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/keep"
  rm -rf "${SH:?}/media"; ln -s "$HOME/elsewhere" "$SH/media"
  run_teardown --purge "design-systems"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "target kept"                 [ -f "$HOME/elsewhere/keep" ]
  check "nothing changed"             nothing_changed
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a SERVICE_HOME outside ~/services/design-systems"
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "clone untouched"             repo_intact
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  for dotted in "$HOME/services/." "$HOME/services/./design-systems" "$HOME/services/design-systems/.."; do
    sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$dotted#" "$SVC/.env"
    run_teardown --purge "design-systems"
    check "'.' / '..' component refused: $dotted" [ "$CODE" -ne 0 ]
  done
  check "neighbour data never touched" [ -f "$HOME/services/neighbour/keep" ]
  check "own state never touched"     [ -f "$SH/www/current/index.html" ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "design-systems"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$SH///#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "own dir with trailing slashes: exits zero" [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$SH" ]
  check "  clone untouched"           repo_intact
  teardown
}

test_teardown_purge_own_dir_only() {
  echo "• teardown --purge: only ~/services/design-systems itself or inside it"
  deployed
  mkdir -p "$HOME/services/neighbour/www"; echo x > "$HOME/services/neighbour/www/keep"
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$HOME/services/neighbour#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "another service's dir refused" [ "$CODE" -ne 0 ]
  check "  its data kept"             [ -f "$HOME/services/neighbour/www/keep" ]
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=$SH/a:b#" "$SVC/.env"
  mkdir -p "$SH/a:b"
  run_teardown --purge "design-systems"
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
  mkdir -p "$HOME/design-systems/www"; echo x > "$HOME/design-systems/www/keep"
  run_teardown --purge "design-systems"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "nothing in \$HOME deleted"    [ -f "$HOME/design-systems/www/keep" ]
  check "clone untouched"             repo_intact
  rm -f "$HOME/services"
  teardown
}

test_teardown_purge_keeps_a_checkout_inside() {
  echo "• teardown --purge: a checkout living inside ~/services/design-systems survives"
  deployed
  local repo="$SH/setup-server/services/design-systems"
  mkdir -p "$repo"
  cp -R "$SVC/." "$repo/"
  echo secret > "$SH/setup-server/other.env"
  OUT="$(printf '%s\n' "design-systems" | PATH="$STUBS:$PATH" bash "$repo/teardown.sh" --purge 2>&1)"; CODE=$?
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "checkout intact"             [ -f "$repo/teardown.sh" ]
  check "other services' files kept"  [ -f "$SH/setup-server/other.env" ]
  check "state kept"                  [ -f "$SH/www/current/index.html" ]
  teardown
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a \$HOME reference in .env is expanded like Compose does"
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=\"\${HOME}/services/design-systems\"#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$SH" ]
  teardown
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME='\$HOME/services/design-systems'#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  state kept"                [ -f "$SH/www/current/index.html" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8108'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8108 off"                   calls_have "serve --https=8108 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8108"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8108 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_env_lint() {
  echo "• teardown: .env that Compose could read differently is refused"
  deployed
  printf 'SERVICE_HOME=%s/elsewhere\n' "$HOME" >> "$SVC/.env"
  run_teardown
  check "duplicate key: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the key"             out_has "SERVICE_HOME is set more than once"
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  printf 'X="first\nSERVICE_HOME=%s/elsewhere\n"\n' "$HOME" >> "$SVC/.env"
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
    run_teardown --purge "design-systems"
    check "$v in .env: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  no compose call"           no_call "compose --project-directory"
    check "  nothing unpublished"       no_call " off"
    check "  .env kept"                 [ -f "$SVC/.env" ]
    teardown
  done
  deployed
  COMPOSE_PROJECT_NAME=other run_teardown
  check "COMPOSE_PROJECT_NAME in the shell: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_unresolved_variable() {
  echo "• teardown: a path in .env that still names another variable is refused before anything changes"
  deployed
  # setup.sh sources .env, so to it this is the clone inside www/; to a
  # teardown that left it literal, the overlap check would test nothing.
  mkdir -p "$SH/www/clone/.git"; echo mine > "$SH/www/clone/precious"
  sed -i.bak "s#^SOURCE_REPO=.*#SOURCE_REPO=\$SERVICE_HOME/www/clone#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "SOURCE_REPO=\$SERVICE_HOME/...: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says why"                  out_has "SOURCE_REPO .*still refers to another variable"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  clone kept"                [ -f "$SH/www/clone/precious" ]
  check "  nothing changed"           nothing_changed
  run_teardown
  check "plain run: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  sed -i.bak "s#^SERVICE_HOME=.*#SERVICE_HOME=\$HOME/services/\${NAME}#" "$SVC/.env"
  run_teardown --purge "design-systems"
  check "SERVICE_HOME=...\${NAME}: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  teardown
}

test_teardown_purge_deploy_lock() {
  echo "• teardown --purge: a live deploy lock refuses up front; a stale one is cleared; teardown holds it through the purge"
  local lock
  deployed
  lock="$SH/.deploy.lock"
  mkdir "$lock"
  run_teardown --purge "design-systems"
  check "live lock: exits non-zero"   [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  refused before the prompt" out_lacks "to confirm"
  check "  nothing changed"           nothing_changed
  check "  lock left to its owner"    [ -d "$lock" ]
  run_teardown
  check "plain teardown (deletes nothing) still runs" [ "$CODE" -eq 0 ]
  teardown
  deployed
  lock="$SH/.deploy.lock"
  run_purge_at_prompt "design-systems" "mkdir '$lock'"
  check "deploy started during the prompt: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says a deploy is running"  out_has "A deploy is running"
  check "  nothing changed"           nothing_changed
  teardown
  deployed
  lock="$SH/.deploy.lock"
  run_purge_at_prompt "design-systems" "[ -e '$lock' ] && echo held > '$STATE_DIR/lock_at_prompt' || echo free > '$STATE_DIR/lock_at_prompt'"
  check "no lock: exits zero"         [ "$CODE" -eq 0 ]
  check "  not taken while the prompt waits" grep -qx free "$STATE_DIR/lock_at_prompt"
  teardown
  deployed
  lock="$SH/.deploy.lock"
  mkdir "$lock"; age_lock "$lock"
  printf '%s' "$lock" > "$STATE_DIR/lock_probe"
  run_teardown --purge "design-systems"
  check "stale lock: exits zero"      [ "$CODE" -eq 0 ]
  check "  says it cleared it"        out_has "Cleared a stale deploy lock"
  check "  teardown holds it during down" grep -qx held "$STATE_DIR/lock_at_down"
  check "  gone after the purge"      [ ! -e "$lock" ]
  check "  marker dir gone"           [ ! -e "$SH" ]
  teardown
  deployed
  lock="$SH/.deploy.lock"
  mkdir "$lock"; echo mine > "$lock/notes"; age_lock "$lock"
  run_teardown --purge "design-systems"
  check "old lock holding files: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  its files kept"            [ -f "$lock/notes" ]
  teardown
  deployed
  lock="$SH/.deploy.lock"
  mkdir -p "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$lock"
  run_teardown --purge "design-systems"
  check "symlinked lock: exits non-zero" [ "$CODE" -ne 0 ]
  check "  nothing changed"           nothing_changed
  check "  link left as it was"       [ -L "$lock" ] && [ -d "$HOME/elsewhere" ]
  teardown
}

# macOS branch on any box: FAKE_UNAME=Darwin makes teardown.sh take it.
test_teardown_macos_launch_agent() {
  echo "• teardown (macOS branch): only a loaded agent is booted out; a failed unload stops before --purge deletes anything"
  deployed
  export FAKE_UNAME=Darwin
  run_teardown
  check "loaded agent: exits zero"    [ "$CODE" -eq 0 ]
  check "  checked with print first"  [ "$(call_line "launchctl print gui/.*/com.design-systems.deploy")" -gt 0 ] && [ "$(call_line "launchctl print")" -lt "$(call_line "launchctl bootout")" ]
  check "  booted out"                calls_have "launchctl bootout gui/.*/com.design-systems.deploy"
  check "  disabled"                  calls_have "launchctl disable gui/.*/com.design-systems.deploy"
  check "  no systemctl"              no_call "systemctl"
  : > "$CALLS_LOG"
  touch "$STATE_DIR/launchd_not_loaded"
  run_teardown
  check "agent not loaded: exits zero" [ "$CODE" -eq 0 ]
  check "  no bootout attempted"      no_call "launchctl bootout"
  check "  still disabled"            calls_have "launchctl disable gui/.*/com.design-systems.deploy"
  teardown
  deployed
  export FAKE_UNAME=Darwin
  touch "$STATE_DIR/launchd_bootout_fails"
  run_teardown --purge "design-systems"
  check "bootout fails, agent still loaded: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says so"                   out_has "Could not unload LaunchAgent com.design-systems.deploy"
  check "  no compose down"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  state kept"                [ -f "$SH/www/current/index.html" ]
  check "  media kept"                [ -f "$SH/media/refero/a.jpg" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  echo async > "$STATE_DIR/launchd_bootout_fails"
  run_teardown
  check "bootout errors but the agent unloads: exits zero" [ "$CODE" -eq 0 ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  touch "$STATE_DIR/launchd_disable_fails"
  run_teardown --purge "design-systems"
  check "disable fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  says it would reload"      out_has "would load again at the next login"
  check "  state kept"                [ -f "$SH/www/current/index.html" ]
  check "  media kept"                [ -f "$SH/media/refero/a.jpg" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  deployed
  export FAKE_UNAME=Darwin
  run_teardown --purge "design-systems"
  check "purge on macOS: exits zero"  [ "$CODE" -eq 0 ]
  check "  state gone"                [ ! -e "$SH/www" ]
  check "  no daemon-reload"          no_call "daemon-reload"
  teardown
}

# ------------------------------------------------------------------ main
echo "Mocked suite (sandboxed, no system changes):"
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_repo_missing
test_preflight_wrong_repo
test_lfs_pointers_fixed
test_lfs_pointers_unfixable
test_fresh_deploy
test_idempotent_rerun
test_nginx_conf_stale_warns
test_push_triggers_redeploy
test_force_rebuild_same_sha
test_deps_resync_on_requirements_change
test_spaced_repo_path
test_poll_lock
test_port_override
test_operator_escalation
test_teardown_safe
test_teardown_foreign_units
test_teardown_same_compose_files_as_up
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_purge
test_teardown_purge_keeps_other_files
test_teardown_purge_missing_state_dir
test_teardown_purge_refuses_repo_overlap
test_teardown_purge_refuses_symlinked_child
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_purge_own_dir_only
test_teardown_purge_services_root_is_a_link
test_teardown_purge_keeps_a_checkout_inside
test_teardown_home_variable_in_env
test_teardown_quoted_env
test_teardown_env_lint
test_teardown_refuses_compose_overrides
test_teardown_unresolved_variable
test_teardown_purge_deploy_lock
test_teardown_macos_launch_agent

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
