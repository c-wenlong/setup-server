#!/usr/bin/env bash
#
# Mocked tests for scripts/migrate-layout.sh. Builds a fake checkout that has
# already been pulled (services/ and app/web/ exist) with the old folders still
# holding untracked files, a fake systemd/launchd dir, and a docker stub that
# reports containers bind-mounting from the old folders.
#
#   ./scripts/tests/test-migrate-layout.sh
#
# Zero changes to the host: everything lives in a temp dir, HOME included.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../migrate-layout.sh"
PASS=0; FAIL=0
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '    \033[1;32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '    \033[1;31m✗\033[0m %s\n' "$label"; FAIL=$((FAIL + 1))
  fi
}
calls_have()  { grep -qF -- "$1" "$CALLS_LOG"; }
calls_lack()  { ! grep -qF -- "$1" "$CALLS_LOG"; }
out_has()     { grep -qF -- "$1" "$OUT"; }

# ---------------------------------------------------------------- harness
setup() {
  SB="$(mktemp -d)"
  R="$SB/repo"
  export HOME="$SB/home"
  export CALLS_LOG="$SB/calls.log"
  : > "$CALLS_LOG"
  mkdir -p "$HOME" "$R/scripts" "$SB/bin"
  cp "$SCRIPT" "$R/scripts/"

  # New layout, as git left it after the pull.
  for d in services/immich services/ntfy-control services/monitoring \
           services/appflowy services/self-learn app/web; do
    mkdir -p "$R/$d"
    printf '#!/usr/bin/env bash\necho "setup %s" >> "$CALLS_LOG"\n' "$d" > "$R/$d/setup.sh"
    chmod +x "$R/$d/setup.sh"
  done
  echo "services: {}" > "$R/services/appflowy/docker-compose.yml"
  echo "services: {}" > "$R/services/appflowy/docker-compose.gpu.yml"
  echo "shared" > "$R/services/self-learn/same.txt"
  echo "new" > "$R/services/self-learn/differs.txt"

  # What git left behind in the old folders.
  mkdir -p "$R/immich" "$R/ntfy-control" "$R/launcher/__pycache__" "$R/appflowy/data" "$R/self-learn"
  echo "DB_PASSWORD=s3cret" > "$R/immich/.env"
  chmod 600 "$R/immich/.env"
  echo "KUMA_ENV_FILE=$R/monitoring/.env" > "$R/ntfy-control/.env"
  echo "x" > "$R/launcher/__pycache__/server.cpython-313.pyc"
  echo "nested" > "$R/appflowy/data/keep.txt"
  echo "shared" > "$R/self-learn/same.txt"
  echo "old" > "$R/self-learn/differs.txt"

  # deploy.sh copies a *-deploy timer runs, with paths baked in at install.
  mkdir -p "$HOME/services/self-learn/bin"
  printf 'ENV_FILE="%s/self-learn/.env"\nCOMPOSE_DIR="%s/self-learn"\nOTHER="%s/self-learner"\n' "$R" "$R" "$R" \
    > "$HOME/services/self-learn/bin/deploy.sh"
  chmod +x "$HOME/services/self-learn/bin/deploy.sh"
  cp "$HOME/services/self-learn/bin/deploy.sh" "$HOME/services/self-learn/bin/deploy.sh.bak-1"

  # Units: launcher points at the old folder; self-learn only in a comment.
  if [ "$OS" = "Linux" ]; then UD="$HOME/.config/systemd/user"; else UD="$HOME/Library/LaunchAgents"; fi
  mkdir -p "$UD"
  printf '[Service]\nExecStart=/usr/bin/env python3 %s/launcher/server.py\n' "$R" > "$UD/launcher.service"
  printf '# edit %s/self-learn/.env and re-run\n[Service]\nExecStart=/bin/true\n' "$R" > "$UD/self-learn.service"

  # docker stub: two appflowy containers mount from the old folder (one
  # running, one stopped); immich mounts only ~/services paths.
  cat > "$SB/inspect.json" <<JSON
[
 {"Config": {"Labels": {"com.docker.compose.project": "appflowy",
   "com.docker.compose.service": "nginx",
   "com.docker.compose.project.config_files": "$R/appflowy/docker-compose.yml,$R/appflowy/docker-compose.gpu.yml"}},
  "State": {"Running": true},
  "Mounts": [{"Type": "bind", "Source": "$R/appflowy/nginx.conf"}]},
 {"Config": {"Labels": {"com.docker.compose.project": "appflowy",
   "com.docker.compose.service": "worker",
   "com.docker.compose.project.config_files": "$R/appflowy/docker-compose.yml,$R/appflowy/docker-compose.gpu.yml"}},
  "State": {"Running": false},
  "Mounts": [{"Type": "bind", "Source": "$R/appflowy/data/keep.txt"}]},
 {"Config": {"Labels": {"com.docker.compose.project": "immich",
   "com.docker.compose.service": "immich-server",
   "com.docker.compose.project.config_files": "$R/immich/docker-compose.yml"}},
  "State": {"Running": true},
  "Mounts": [{"Type": "bind", "Source": "$HOME/services/immich/library"}]}
]
JSON
  cat > "$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps) echo a1; echo a2; echo i1 ;;
  inspect) [ -f "$STATE_DIR/migrated" ] && echo '[]' || cat "$STATE_DIR/inspect.json" ;;
  compose) echo "docker $*" >> "$CALLS_LOG"; touch "$STATE_DIR/migrated" ;;
esac
STUB
  chmod +x "$SB/bin/docker"
  export STATE_DIR="$SB"
  export PATH="$SB/bin:$ORIG_PATH"
}

teardown() {
  rm -rf "$SB"
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_PATH"
  unset CALLS_LOG STATE_DIR
}

migrate() { OUT="$SB/out.log"; "$R/scripts/migrate-layout.sh" "$@" > "$OUT" 2>&1; CODE=$?; }

# ------------------------------------------------------------------ tests
echo "• fresh migration"
setup
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check ".env moved"                          grep -q "DB_PASSWORD=s3cret" "$R/services/immich/.env"
check ".env keeps mode 600"                 sh -c "[ \"\$(stat -c %a '$R/services/immich/.env' 2>/dev/null || stat -f %Lp '$R/services/immich/.env')\" = 600 ]"
check "nested file moved"                   test -f "$R/services/appflowy/data/keep.txt"
check "old immich/ removed"                 test ! -e "$R/immich"
check "old launcher/ removed (bytecode)"    test ! -e "$R/launcher"
check "bytecode not moved"                  test ! -e "$R/app/web/__pycache__"
check "KUMA_ENV_FILE rewritten"             grep -qx "KUMA_ENV_FILE=$R/services/monitoring/.env" "$R/services/ntfy-control/.env"
check "deploy.sh ENV_FILE rewritten"        grep -qx "ENV_FILE=\"$R/services/self-learn/.env\"" "$HOME/services/self-learn/bin/deploy.sh"
check "deploy.sh COMPOSE_DIR rewritten"     grep -qx "COMPOSE_DIR=\"$R/services/self-learn\"" "$HOME/services/self-learn/bin/deploy.sh"
check "a longer folder name is not matched" grep -qx "OTHER=\"$R/self-learner\"" "$HOME/services/self-learn/bin/deploy.sh"
check "deploy.sh stays executable"          test -x "$HOME/services/self-learn/bin/deploy.sh"
check ".bak copies left alone"              grep -qx "COMPOSE_DIR=\"$R/self-learn\"" "$HOME/services/self-learn/bin/deploy.sh.bak-1"
check "identical duplicate dropped"         test ! -e "$R/self-learn/same.txt"
check "differing file not overwritten"      grep -qx new "$R/services/self-learn/differs.txt"
check "differing old copy left in place"    grep -qx old "$R/self-learn/differs.txt"
check "warns about the conflict"            out_has "kept both: services/self-learn/differs.txt"
check "launcher re-deployed"                calls_have "setup app/web"
check "comment-only unit ignored"           calls_lack "setup services/self-learn"
check "running container started"           calls_have "up -d --no-deps nginx"
check "stopped container left stopped"      calls_have "up --no-start --no-deps worker"
check "compose files at new paths"          calls_have "-f $R/services/appflowy/docker-compose.yml -f $R/services/appflowy/docker-compose.gpu.yml"
check "project name kept"                   calls_have "-p appflowy"
check "unaffected project untouched"        calls_lack "immich"

echo "• re-run is a no-op"
: > "$CALLS_LOG"
printf '[Service]\nExecStart=/usr/bin/env python3 %s/app/web/server.py\n' "$R" > "$UD/launcher.service"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "nothing moved"                       out_has "0 file(s) moved"
check "no setup re-run"                     calls_lack "setup "
check "no compose call"                     calls_lack "docker compose"
teardown

echo "• a failing setup.sh does not stop the container step"
setup
printf '#!/usr/bin/env bash\nexit 3\n' > "$R/app/web/setup.sh"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "names the failed setup"              out_has "setup.sh failed for: app/web"
check "containers still recreated"          calls_have "up -d --no-deps nginx"
teardown

echo "• --dry-run changes nothing"
setup
migrate --dry-run
check "exits zero"                          [ "$CODE" -eq 0 ]
check ".env not moved"                      test -f "$R/immich/.env"
check "nothing at the new path"             test ! -e "$R/services/immich/.env"
check "KUMA_ENV_FILE untouched"             grep -qx "KUMA_ENV_FILE=$R/monitoring/.env" "$R/ntfy-control/.env"
check "deploy.sh untouched"                 grep -qx "COMPOSE_DIR=\"$R/self-learn\"" "$HOME/services/self-learn/bin/deploy.sh"
check "no setup run"                        calls_lack "setup "
check "no compose call"                     calls_lack "docker compose"
check "bytecode still there"                test -f "$R/launcher/__pycache__/server.cpython-313.pyc"
check "prints the planned move"             out_has "immich/.env -> services/immich/.env"
check "prints the planned compose call"     out_has "would run: docker compose"
teardown

echo "• docker installed but not reachable"
setup
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin/docker"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "files still moved"                   test -f "$R/services/immich/.env"
check "warns to re-run later"               out_has "not reachable"
teardown

echo "• preflight: not pulled yet"
setup
rm -rf "$R/services"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says to pull first"                  out_has "Pull the commit that moved them first"
check "old files untouched"                 test -f "$R/immich/.env"
teardown

echo "• preflight: bad flag"
setup
migrate --force
check "exits 2"                             [ "$CODE" -eq 2 ]
teardown

echo
if [ "$FAIL" -eq 0 ]; then green "All $PASS checks passed."; exit 0; fi
red "$FAIL of $((PASS + FAIL)) checks failed."; exit 1
