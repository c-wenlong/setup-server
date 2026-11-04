#!/usr/bin/env bash
#
# Mocked tests for scripts/migrate-kaichenpedia-to-app.sh. Runs the real
# script against a sandbox repo (the script, lib/common.sh and the launcher's
# real server.py + ghapp.py), a temp $HOME, and PATH stubs for docker, git,
# tailscale and systemctl. A sitecustomize.py on PYTHONPATH answers ghapp's
# health probe of 127.0.0.1:8091 from stub state, so nothing on this machine
# (including a live site on that port) is ever contacted.
#
#   ./scripts/tests/test-migrate-kaichenpedia-to-app.sh
#
# Zero changes to the host: everything lives in a temp dir, HOME included.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
PASS=0; FAIL=0
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
ORIG_PYTHONPATH="${PYTHONPATH-}"
SECRET="ghp_TOPSECRETVALUE123"
SHA="9abe9d68c06293d7406a173d0b7060bf04f76b5e"
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
calls_count() { grep -cF -- "$1" "$CALLS_LOG"; }
out_has()     { grep -qF -- "$1" "$OUT"; }
out_lacks()   { ! grep -qF -- "$1" "$OUT"; }
json_get()    { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }
mode_of()     { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# ---------------------------------------------------------------- harness
setup() {
  SB="$(mktemp -d)"
  R="$SB/repo"
  export HOME="$SB/home"
  export CALLS_LOG="$SB/calls.log"
  export STATE_DIR="$SB/state"
  export SECRET SHA
  : > "$CALLS_LOG"
  mkdir -p "$HOME" "$R/scripts" "$R/lib" "$R/app/web" "$SB/bin" "$SB/py" "$STATE_DIR"
  cp "$SRC_ROOT/scripts/migrate-kaichenpedia-to-app.sh" "$R/scripts/"
  cp "$SRC_ROOT/lib/common.sh" "$R/lib/"
  cp "$SRC_ROOT/app/web/server.py" "$SRC_ROOT/app/web/ghapp.py" \
     "$SRC_ROOT/app/web/services.json" "$R/app/web/"

  # deployd installed, with the old manifest poller's state files.
  D="$HOME/services/deployd/state"
  mkdir -p "$D"
  echo "$SHA" > "$D/kaichenpedia.sha"
  echo '{"sha": "old", "at": 1, "rc": 1}' > "$D/kaichenpedia.fail"

  # The old deploy's leftovers: its clone home and deploy.sh copy, whose
  # baked-in ENV_FILE points at an old .env outside this repo.
  OLD_ENV="$SB/old-checkout/services/kaichenpedia/.env"
  mkdir -p "$HOME/services/kaichenpedia/bin" "$(dirname "$OLD_ENV")"
  printf '#!/usr/bin/env bash\nENV_FILE="%s"\nSERVICE_DIR="x"\n' "$OLD_ENV" \
    > "$HOME/services/kaichenpedia/bin/deploy.sh"
  printf 'GH_TOKEN="%s" # wiki token\nexport COPILOT_MODEL=claude\nLOCAL_PORT=8091\n' "$SECRET" > "$OLD_ENV"

  # The installed deployd binary, whose baked-in .env agrees with the
  # default state dir this checkout resolves.
  mkdir -p "$HOME/services/deployd/bin" "$SB/deployd-checkout/services/deployd"
  printf 'SETUP_REPO=%s\nSERVICE_HOME=%s\n' "$SB/deployd-checkout" "$HOME/services/deployd" \
    > "$SB/deployd-checkout/services/deployd/.env"
  printf '#!/usr/bin/env python3\nENV_BAKED = "%s"  # setup.sh rewrites this\n' \
    "$SB/deployd-checkout/services/deployd/.env" > "$HOME/services/deployd/bin/deployd"
  export SANDBOX_SCRIPT="$R/scripts/migrate-kaichenpedia-to-app.sh"

  # The running old container: its env as docker reports it.
  touch "$STATE_DIR/old-exists" "$STATE_DIR/old-running" "$STATE_DIR/network"
  cat > "$STATE_DIR/old-env.json" <<JSON
["PORT=8080","HOSTNAME=0.0.0.0","GH_TOKEN=$SECRET","COPILOT_SECRET=","COPILOT_MODEL=","OPENAI_API_KEY=sk-ALSOSECRET","PATH=/usr/local/bin","NODE_ENV=production"]
JSON

  cat > "$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS_LOG"
S="$STATE_DIR"
fmt=""; name=""
args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --format) fmt="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --filter) i=$((i + 1)) ;;
    -*) ;;
    *) name="${args[$i]}" ;;
  esac
done
exists()  { case "$1" in kaichenpedia) [ -f "$S/old-exists" ] ;; app-kaichenpedia) [ -f "$S/new-exists" ] ;; *) false ;; esac; }
case "$1" in
  info) exit 0 ;;
  inspect)
    exists "$name" || exit 1
    case "$fmt" in
      *Config.Env*) cat "$S/old-env.json" ;;
      *State.Running*)
        if [ "$name" = kaichenpedia ]; then [ -f "$S/old-running" ] && echo true || echo false
        else [ -f "$S/new-stopped" ] && echo false || echo true; fi ;;
      *.Image*) echo "sha256:0123456789abcdef0123456789abcdef" ;;
    esac ;;
  ps)
    for n in kaichenpedia app-kaichenpedia; do
      exists "$n" && case "$*" in *"^/$n\$"*) echo "$n" ;; esac
    done; exit 0 ;;
  stop) rm -f "$S/old-running" ;;
  start) [ "$2" = kaichenpedia ] && touch "$S/old-running" ;;
  rm)
    for n in "${@:2}"; do
      case "$n" in
        kaichenpedia) rm -f "$S/old-exists" "$S/old-running" ;;
        app-kaichenpedia) rm -f "$S/new-exists" ;;
      esac
    done ;;
  run)
    if [ -f "$S/interrupt-run" ]; then pkill -TERM -f "$SANDBOX_SCRIPT"; sleep 1; exit 125; fi
    [ -f "$S/fail-run" ] && { echo "port is already allocated" >&2; exit 125; }
    [ -f "$S/old-running" ] && { echo "port 8091 still held by kaichenpedia" >&2; exit 125; }
    touch "$S/new-exists"; echo cid ;;
  build) [ -f "$S/fail-build" ] && exit 1; exit 0 ;;
  image) [ "$2" = ls ] && case "$*" in *" kaichenpedia "*) echo "kaichenpedia:9abe9d68c062-1" ;; esac; exit 0 ;;
  network)
    case "$2" in
      inspect) [ -f "$S/network" ] ;;
      rm) rm -f "$S/network" ;;
    esac ;;
  logs) echo "container log" ;;
esac
exit 0
STUB

  cat > "$SB/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS_LOG"
if [ "$1" = ls-remote ]; then printf '%s\trefs/heads/main\n' "$SHA"; exit 0; fi
if [ "$1" = clone ]; then dest="${*: -1}"; mkdir -p "$dest/.git"; exit 0; fi
if [ "$1" = -C ] && [ "$3" = checkout ]; then mkdir -p "$2/site"; echo "FROM node" > "$2/site/Dockerfile"; fi
exit 0
STUB

  cat > "$SB/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >> "$CALLS_LOG"
if [ "$1 $2" = "serve status" ]; then
  echo '{"Web": {"box.ts.net:8091": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8091"}}}}}'
fi
exit 0
STUB

  printf '#!/usr/bin/env bash\necho inactive\nexit 3\n' > "$SB/bin/systemctl"
  chmod +x "$SB/bin/"*

  # ghapp's health probe: answers only while the new container "runs".
  cat > "$SB/py/sitecustomize.py" <<'PY'
import os
import urllib.error
import urllib.request

_real = urllib.request.urlopen


class _Resp(object):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _urlopen(url, *a, **kw):
    target = url if isinstance(url, str) else url.get_full_url()
    if target.startswith("http://127.0.0.1:"):
        if os.path.exists(os.path.join(os.environ["STATE_DIR"], "new-exists")):
            return _Resp()
        raise urllib.error.URLError("refused")
    return _real(url, *a, **kw)


urllib.request.urlopen = _urlopen
PY
  export PYTHONPATH="$SB/py"
  export PATH="$SB/bin:$ORIG_PATH"
}

teardown() {
  rm -rf "$SB"
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_PATH"
  if [ -n "$ORIG_PYTHONPATH" ]; then export PYTHONPATH="$ORIG_PYTHONPATH"; else unset PYTHONPATH; fi
  unset CALLS_LOG STATE_DIR
}

migrate() { OUT="$SB/out.log"; "$R/scripts/migrate-kaichenpedia-to-app.sh" "$@" > "$OUT" 2>&1; CODE=$?; }

DEF() { echo "$HOME/services/launcher/apps/kaichenpedia.json"; }
ENVF() { echo "$HOME/services/apps/kaichenpedia/.env"; }
POLLERS() { echo "$HOME/services/deployd/state/pollers.json"; }
no_secrets() { out_lacks "$SECRET" && out_lacks "sk-ALSOSECRET"; }

# ------------------------------------------------------------------ tests
echo "• fresh migration"
setup
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "definition written"                  test -f "$(DEF)"
check "def: repo"                           [ "$(json_get "$(DEF)" 'd["repo"]')" = c-wenlong/kaichenpedia ]
check "def: port pinned to 8091"            [ "$(json_get "$(DEF)" 'd["port"]')" = 8091 ]
check "def: dockerfile site/Dockerfile"     [ "$(json_get "$(DEF)" 'd["dockerfile"]')" = site/Dockerfile ]
check "def: context ."                      [ "$(json_get "$(DEF)" 'd["context"]')" = . ]
check "def: container_port 8080"            [ "$(json_get "$(DEF)" 'd["container_port"]')" = 8080 ]
check "def: health_path /"                  [ "$(json_get "$(DEF)" 'd["health_path"]')" = / ]
check "def: create_app's field set"         [ "$(json_get "$(DEF)" 'sorted(d)')" = "['container_port', 'context', 'created_at', 'dockerfile', 'env_names', 'health_path', 'key', 'name', 'port', 'ref', 'repo', 'tagline', 'version', 'volume']" ]
check "def: env_names lists the keys"       [ "$(json_get "$(DEF)" '",".join(d["env_names"])')" = "GH_TOKEN,COPILOT_SECRET,COPILOT_PROVIDER,COPILOT_API_KEY,COPILOT_BASE_URL,COPILOT_MODEL,ANTHROPIC_API_KEY,OPENAI_API_KEY,GEMINI_API_KEY,MODELS_ALLOWED_HOSTS,PORT,HOSTNAME" ]
check ".env mode 600"                       [ "$(mode_of "$(ENVF)")" = 600 ]
check ".env carries the token"              grep -qx "GH_TOKEN=$SECRET" "$(ENVF)"
check ".env keeps an empty key"             grep -qx "COPILOT_SECRET=" "$(ENVF)"
check ".env PORT=8080"                      grep -qx "PORT=8080" "$(ENVF)"
check ".env HOSTNAME=0.0.0.0"               grep -qx "HOSTNAME=0.0.0.0" "$(ENVF)"
check ".env drops image vars (PATH)"        sh -c "! grep -q '^PATH=' '$(ENVF)'"
check ".env drops image vars (NODE_ENV)"    sh -c "! grep -q '^NODE_ENV=' '$(ENVF)'"
check "poller cmd is ghapp's"               [ "$(json_get "$(POLLERS)" 'd["pollers"]["kaichenpedia"]["cmd"]')" = "app/web/ghapp.py deploy kaichenpedia" ]
check "poller repo is the clone URL"        [ "$(json_get "$(POLLERS)" 'd["pollers"]["kaichenpedia"]["repo"]')" = "https://github.com/c-wenlong/kaichenpedia.git" ]
check "poller resumed after the deploy"     test ! -e "$D/kaichenpedia.disabled"
check "deployed.json recorded"              test -f "$HOME/services/apps/kaichenpedia/deployed.json"
check "deployd sha recorded"                grep -qx "$SHA" "$D/kaichenpedia.sha"
check "old .fail dropped"                   test ! -e "$D/kaichenpedia.fail"
check "warm build + deploy build"           [ "$(calls_count "docker build")" -eq 2 ]
check "build uses site/Dockerfile"          calls_have "/src/site/Dockerfile"
check "deploy pinned to the warmed sha"     out_has "deploying c-wenlong/kaichenpedia at ${SHA:0:12}"
check "old container stopped"               calls_have "docker stop kaichenpedia"
check "new container on 127.0.0.1:8091"     calls_have "--publish 127.0.0.1:8091:8080"
check "new container gets the .env"         calls_have "--env-file $HOME/services/apps/kaichenpedia/.env"
check "old container removed"               calls_have "docker rm --force kaichenpedia"
check "old network removed"                 calls_have "docker network rm kaichenpedia_default"
check "Serve left alone (already mapped)"   calls_lack "tailscale serve --bg"
check "deployd lock released"               test ! -e "$HOME/services/deployd/.poll.lock"
check "no env values printed"               no_secrets
check "lists the old home as leftover"      out_has "$HOME/services/kaichenpedia"
check "lists the old .env as leftover"      out_has "$OLD_ENV"
check "old .env not deleted"                test -f "$OLD_ENV"
check "old home not deleted"                test -d "$HOME/services/kaichenpedia"

echo "• re-run is a no-op"
: > "$CALLS_LOG"
cp "$(ENVF)" "$SB/env.before"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "says already migrated"               out_has "already migrated"
check "no build"                            calls_lack "docker build"
check "no stop"                             calls_lack "docker stop"
check "no new container"                    calls_lack "docker run"
check "poller not paused again"             test ! -e "$D/kaichenpedia.disabled"
check ".env unchanged"                      cmp -s "$SB/env.before" "$(ENVF)"
check "no env values printed"               no_secrets
teardown

echo "• already migrated but the app is stopped: nothing undone"
setup
migrate
check "first run exits zero"                [ "$CODE" -eq 0 ]
touch "$STATE_DIR/new-stopped" "$STATE_DIR/fail-run"
: > "$CALLS_LOG"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "says it is not running"              out_has "is not running"
check "definition kept"                     test -f "$(DEF)"
check "poller row kept"                     grep -q "ghapp.py deploy kaichenpedia" "$(POLLERS)"
check "deployed.json kept"                  test -f "$HOME/services/apps/kaichenpedia/deployed.json"
check "no new container attempted"          calls_lack "docker run"
check "no container removed"                calls_lack "docker rm"
teardown

echo "• deploy fails: the old site comes back"
setup
touch "$STATE_DIR/fail-run"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "old container started again"         calls_have "docker start kaichenpedia"
check "old container running"               test -f "$STATE_DIR/old-running"
check "old container not removed"           test -f "$STATE_DIR/old-exists"
check "definition removed"                  test ! -e "$(DEF)"
check "poller row dropped"                  sh -c "! grep -q kaichenpedia '$(POLLERS)'"
check "poller not left paused"              test ! -e "$D/kaichenpedia.disabled"
check "no deployed.json"                    test ! -e "$HOME/services/apps/kaichenpedia/deployed.json"
check ".env kept for the next try"          test -f "$(ENVF)"
check "network kept"                        test -f "$STATE_DIR/network"
check "deployd lock released"               test ! -e "$HOME/services/deployd/.poll.lock"
check "says the old deployment is back"     out_has "old deployment is back"
check "no env values printed"               no_secrets

echo "• then a retry succeeds"
rm -f "$STATE_DIR/fail-run"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "definition written"                  test -f "$(DEF)"
check "old container removed"               test ! -e "$STATE_DIR/old-exists"
teardown

echo "• warm-up build fails: nothing touched"
setup
touch "$STATE_DIR/fail-build"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "old container never stopped"         calls_lack "docker stop"
check "no definition"                       test ! -e "$(DEF)"
check "no poller"                           test ! -e "$(POLLERS)"
teardown

echo "• old container gone: falls back to the old .env"
setup
rm -f "$STATE_DIR/old-exists" "$STATE_DIR/old-running"
migrate
check "exits zero"                          [ "$CODE" -eq 0 ]
check "token read as the shell read it"    grep -qx "GH_TOKEN=$SECRET" "$(ENVF)"
check "export prefix handled"               grep -qx "COPILOT_MODEL=claude" "$(ENVF)"
check "LOCAL_PORT not carried over"         sh -c "! grep -q '^LOCAL_PORT=' '$(ENVF)'"
check "no stop of a missing container"      calls_lack "docker stop"
check "no env values printed"               no_secrets
teardown

echo "• no container and no old .env: dies before changing anything"
setup
rm -f "$STATE_DIR/old-exists" "$STATE_DIR/old-running" "$OLD_ENV"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says what to do"                     out_has "write $HOME/services/apps/kaichenpedia/.env by hand"
check "no .env"                             test ! -e "$(ENVF)"
check "no definition"                       test ! -e "$(DEF)"
check "no build"                            calls_lack "docker build"
teardown

echo "• another app's definition under the key: refused"
setup
mkdir -p "$HOME/services/launcher/apps"
cat > "$(DEF)" <<JSON
{"key": "kaichenpedia", "repo": "someone/else", "ref": "main", "dockerfile": "Dockerfile",
 "context": ".", "container_port": 80, "port": 8301, "health_path": "/"}
JSON
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "names the conflict"                  out_has "someone/else"
check "definition untouched"                grep -q someone/else "$(DEF)"
check "old container never stopped"         calls_lack "docker stop"
teardown

echo "• deployd mid-tick: waits for its lock, gives up at the limit"
setup
mkdir "$HOME/services/deployd/.poll.lock"
KPEDIA_LOCK_WAIT=0 migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "names the lock"                      out_has ".poll.lock is still held"
check "deployd's lock left in place"        test -d "$HOME/services/deployd/.poll.lock"
check "nothing written"                     test ! -e "$(ENVF)"
teardown

echo "• interrupted mid-swap: the exit trap restores the old site"
setup
touch "$STATE_DIR/interrupt-run"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says it was interrupted"             out_has "interrupted before the new container answered"
check "old container running again"         test -f "$STATE_DIR/old-running"
check "definition removed"                  test ! -e "$(DEF)"
check "poller row dropped"                  sh -c "! grep -q kaichenpedia '$(POLLERS)'"
check "poller not left paused"              test ! -e "$D/kaichenpedia.disabled"
check "deployd lock released"               test ! -e "$HOME/services/deployd/.poll.lock"
teardown

echo "• a stale lock that will not go: dies instead of spinning"
setup
mkdir -p "$HOME/services/deployd/.poll.lock"
touch "$HOME/services/deployd/.poll.lock/x"
touch -t 202001010000 "$HOME/services/deployd/.poll.lock"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says to remove it by hand"           out_has "remove it by hand"
check "nothing written"                     test ! -e "$(ENVF)"
teardown

echo "• deployd configured elsewhere: refuses before changing anything"
setup
mkdir -p "$SB/custom-deployd/state"
printf 'SETUP_REPO=%s\nSERVICE_HOME=%s\n' "$SB/deployd-checkout" "$SB/custom-deployd" \
  > "$SB/deployd-checkout/services/deployd/.env"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "names deployd's real state dir"      out_has "$SB/custom-deployd/state"
check "names the checkout to run from"      out_has "Run the script from the checkout deployd uses: $SB/deployd-checkout"
check "nothing written"                     test ! -e "$(ENVF)"
check "no lock taken anywhere"              test ! -e "$SB/custom-deployd/.poll.lock"
teardown

echo "• refuses root"
setup
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0 || echo root\n' > "$SB/bin/id"
chmod +x "$SB/bin/id"
migrate
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says regular user"                   out_has "regular user"
teardown

echo
if [ "$FAIL" -eq 0 ]; then green "all $PASS checks passed"; exit 0; fi
red "$FAIL of $((PASS + FAIL)) checks failed"; exit 1
