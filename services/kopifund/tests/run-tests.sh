#!/usr/bin/env bash
#
# Tests for services/kopifund/{setup,sync,teardown}.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other Docker services — temp $HOME, PATH stubs — with
# one upgrade: git is NOT stubbed. kopifund-finance and kopifund-hub are
# pointed at file:// fixtures (a bare remote each), so clone/fetch/merge/
# push in setup.sh and sync.sh run for real.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
# setup.sh/teardown.sh source ../../lib/common.sh, so every sandbox copy of
# the service sits at <root>/services/<name> with <root>/lib beside it.
copy_lib() { mkdir -p "$1/lib" && cp "$REPO_ROOT/lib/common.sh" "$1/lib/"; }
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------- harness
GIT_ENV="GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t"

# A file:// "GitHub": build a work repo holding the named seed files, commit,
# then clone --bare to $1. The work repo stays for tests that push more.
# Usage: make_remote <dir> <files...>
make_remote() {
  local dir="$1"; shift
  local work
  work="$SANDBOX/work-$(basename "$dir" .git)"
  mkdir -p "$work"
  git -C "$work" init -q 2>/dev/null || git init -q "$work"
  local f
  for f in "$@"; do
    mkdir -p "$work/$(dirname "$f")"
    printf 'seed %s\n' "$f" > "$work/$f"
  done
  env $GIT_ENV git -C "$work" add -A
  env $GIT_ENV git -C "$work" commit -qm "seed" >/dev/null
  env $GIT_ENV git -C "$work" branch -M main
  git clone -q --bare "$work" "$dir"
}

setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/repo/services/kopifund"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  copy_lib "$SANDBOX/repo"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/sync.sh" "$SERVICE_DIR/analyse.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"

  # The two private repos, as local file:// remotes. UPSTREAM is the app
  # source (needs a Dockerfile for the compose build context check); HUB is
  # kopifund-hub — its clone becomes the data folder.
  make_remote "$SANDBOX/kopifund-finance.git" Dockerfile README.md
  make_remote "$SANDBOX/kopifund-hub.git" config.toml profile.json kopifund.db
  # The real hub gitignores sqlite sidecars — matching it is what makes the
  # sync script's wal checkpoint load-bearing in tests.
  printf -- '*-wal\n*-shm\n*.lock\n' > "$SANDBOX/work-kopifund-hub/.gitignore"
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" add .gitignore
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" commit -qm "ignore sqlite sidecars"
  git -C "$SANDBOX/work-kopifund-hub" push -q "$SANDBOX/kopifund-hub.git" main
  export KOPIFUND_REPO_URL="file://$SANDBOX/kopifund-finance.git"
  export KOPIFUND_HUB_URL="file://$SANDBOX/kopifund-hub.git"

  # The git-crypt key a real machine would scp over.
  mkdir -p "$HOME/.config/kopifund"
  printf 'fake-key\n' > "$HOME/.config/kopifund/gitcrypt.key"
  chmod 600 "$HOME/.config/kopifund/gitcrypt.key"

  touch "$STATE_DIR/operator" "$STATE_DIR/linger"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT STATE_DIR CALLS_LOG KOPIFUND_REPO_URL KOPIFUND_HUB_URL KOPIFUND_DATA
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

run_sync() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/kopifund/bin/sync.sh" 2>&1)"
  CODE=$?
}

run_analyse() {
  OUT="$(PATH="$STUBS:$PATH" bash "$HOME/services/kopifund/bin/analyse.sh" 2>&1)"
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
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
not()        { ! "$@"; }
before() {   # before <patA> <patB>: A's first $OUT line precedes B's
  local a b
  a="$(grep -n -- "$1" <<<"$OUT" | head -1 | cut -d: -f1)"
  b="$(grep -n -- "$2" <<<"$OUT" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
env_has()    { grep -q "$1" "$SVC/.env"; }
file_mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

compose_hasF()     { sed 's/#.*//' "$SVC/docker-compose.yml" | grep -qF -- "$1"; }

no_host_wildcard_port() {
  ! awk '
    /^[[:space:]]*ports:[[:space:]]*$/ { p=1; next }
    p && /^[[:space:]]*-[[:space:]0-9]/ {
      if ($0 ~ /0\.0\.0\.0/) { found=1 }
      next
    }
    p && /^[[:space:]]*[^[:space:]#-]/ { p=0 }
    END { exit found ? 0 : 1 }
  ' "$SVC/docker-compose.yml"
}

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
  export LOCAL_PORT=81o3
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_repo_unreachable() {
  echo "• preflight fails when a private repo cannot be read"
  setup
  export KOPIFUND_REPO_URL="file://$SANDBOX/does-not-exist.git"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "explains the auth fix"   out_has "Cannot read"
  check "wrote no .env"           [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_no_gitcrypt() {
  echo "• preflight fails without git-crypt"
  setup
  # "Not installed" can't come from removing the stub — the real binary
  # would still answer (this box needs it for the deploy). So the PATH is
  # stubs + a farm of symlinks to every real binary EXCEPT git-crypt:
  # command -v then fails for it on any machine, wherever it is installed.
  local stubs2="$SANDBOX/stubs2" binfarm="$SANDBOX/binfarm"
  mkdir -p "$stubs2" "$binfarm"; cp "$STUBS"/* "$stubs2/"; rm "$stubs2/git-crypt"
  local d f n
  local OLDIFS="$IFS"; IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      n="${f##*/}"
      case "$n" in git-crypt) continue ;; esac
      [ -e "$STUBS/$n" ] && continue     # stubbed names stay stubbed
      [ -e "$binfarm/$n" ] || ln -s "$f" "$binfarm/$n" 2>/dev/null || true
    done
  done
  IFS="$OLDIFS"
  OUT="$(PATH="$stubs2:$binfarm" bash "$SVC/setup.sh" 2>&1)"; CODE=$?
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the install"         out_has "git-crypt is required"
  check "wrote no .env"             [ ! -f "$SVC/.env" ]
  teardown
}

test_no_key_no_data() {
  echo "• data provisioning: no key + no ~/.kopifund dies with the scp recipe"
  setup
  rm "$HOME/.config/kopifund/gitcrypt.key"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "prints the scp fix"    out_has "scp"
  check "data dir not created"  [ ! -e "$HOME/.kopifund" ]
  check "container not started" [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_data_dir_not_a_clone() {
  echo "• data provisioning: a non-clone ~/.kopifund is never converted"
  setup
  mkdir -p "$HOME/.kopifund/statements"
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "says reconcile"        out_has "not a kopifund-hub clone"
  check "folder untouched"      [ -d "$HOME/.kopifund/statements" ] && [ ! -d "$HOME/.kopifund/.git" ]
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: clone, unlock, timer, container, publish"
  setup
  run_deploy
  check "exits zero"                      [ "$CODE" -eq 0 ]
  check ".env generated mode 600"         [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env records the local port"     grep -qx 'LOCAL_PORT=8300' "$SVC/.env"
  check ".env records the data root"      grep -qx "KOPIFUND_DATA=$HOME/.kopifund" "$SVC/.env"
  check "tailnet URL is the host's"       grep -qx 'KOPIFUND_TAILNET_URL=https://test-host\.tailfake\.ts\.net:8300' "$SVC/.env"
  check "source cloned (Dockerfile)"      [ -f "$HOME/services/kopifund/repo/Dockerfile" ]
  check "data dir is the hub clone"       [ -d "$HOME/.kopifund/.git" ] && [ -f "$HOME/.kopifund/config.toml" ]
  check "git-crypt unlock ran"            calls_have "git-crypt unlock"
  check "sync.sh installed + executable"  [ -x "$HOME/services/kopifund/bin/sync.sh" ]
  check "sync.sh baked the .env path"     grep -qF "ENV_FILE=\"$SVC/.env\"" "$HOME/services/kopifund/bin/sync.sh"
  check "analyse.sh installed + exec"     [ -x "$HOME/services/kopifund/bin/analyse.sh" ]
  check "analyse.sh baked the .env path"  grep -qF "ENV_FILE=\"$SVC/.env\"" "$HOME/services/kopifund/bin/analyse.sh"
  check ".env records analyse cadence"    grep -qx 'ANALYSE_SECONDS=86400' "$SVC/.env"
  check "compose binds loopback"          compose_hasF '127.0.0.1:${LOCAL_PORT'
  check "compose mounts the data clone"   compose_hasF '${KOPIFUND_DATA'
  check "compose publishes no wildcard"   no_host_wildcard_port
  check "compose up --build invoked"      calls_have "up -d --build"
  check "waited on /api/health"           calls_have "127.0.0.1:8300/api/health"
  check "served :8300 tailnet-only"       calls_have "tailscale serve --bg --https=8300 http://127.0.0.1:8300"
  check "prints final URL"                out_has "https://test-host.tailfake.ts.net:8300"
  if [ "$OS" = "Linux" ]; then
    check "timer unit written"            [ -f "$HOME/.config/systemd/user/kopifund-sync.timer" ]
    check "timer enabled"                 [ -f "$STATE_DIR/kopifund-sync_enabled" ]
    check "analyse units written"         [ -f "$HOME/.config/systemd/user/kopifund-analyse.timer" ] && [ -f "$HOME/.config/systemd/user/kopifund-analyse.service" ]
    check "analyse timer enabled"         [ -f "$STATE_DIR/kopifund-analyse_enabled" ]
    check "analyse cadence in unit"       grep -q 'OnUnitActiveSec=86400s' "$HOME/.config/systemd/user/kopifund-analyse.timer"
    check "no sudo (linger already on)"   no_call "^sudo "
  else
    check "LaunchAgent written"           [ -f "$HOME/Library/LaunchAgents/com.kopifund.sync.plist" ]
    check "plist carries the interval"    grep -q '<integer>300</integer>' "$HOME/Library/LaunchAgents/com.kopifund.sync.plist"
    check "analyse LaunchAgent written"   [ -f "$HOME/Library/LaunchAgents/com.kopifund.analyse.plist" ]
    check "analyse plist interval"        grep -q '<integer>86400</integer>' "$HOME/Library/LaunchAgents/com.kopifund.analyse.plist"
  fi
  teardown
}

test_analyse_script() {
  echo "• analyse: quiet skip when the container is down, runs inside it when up"
  setup
  run_deploy
  check "deploy ok"                    [ "$CODE" -eq 0 ]
  check "deploy ran no exec (down)"    no_call "docker exec"
  : > "$CALLS_LOG"
  run_analyse
  check "container down: exits zero"   [ "$CODE" -eq 0 ]
  check "container down: no exec call" no_call "docker exec"
  touch "$STATE_DIR/running_kopifund"
  run_analyse
  check "container up: exits zero"     [ "$CODE" -eq 0 ]
  check "analyse ran in the container" calls_have "docker exec -w /app kopifund python3 server/finance.py analyse --no-publish"
  check "says refreshed"               out_has "stats refreshed"
  touch "$STATE_DIR/exec_fails"
  run_analyse
  check "analyse fails: non-zero"      [ "$CODE" -ne 0 ]
  check "analyse fails: says so"       out_has "analyse failed"
  teardown
}

test_linger_escalation() {
  echo "• Linux: lingering off grants it via sudo once"
  [ "$OS" != "Linux" ] && { echo "    (skipped — Linux only)"; return; }
  setup
  rm -f "$STATE_DIR/linger"
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "enabled via sudo"          calls_have "sudo loginctl enable-linger"
  check "linger now on"             [ -f "$STATE_DIR/linger" ]
  teardown
}

test_legacy_adoption() {
  echo "• legacy launcher data is adopted once, into the data clone"
  setup
  # The honest case: the Mac's last hub snapshot is OLD (backdate the hub's
  # last kopifund.db commit) while the launcher's live data is new (mtimes
  # of now). A fresh clone's checkout-time mtimes would win an mtime race —
  # the comparison must use the commit's snapshot age instead.
  echo "stale-db" > "$SANDBOX/work-kopifund-hub/kopifund.db"
  env $GIT_ENV GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$SANDBOX/work-kopifund-hub" commit -qam "old snapshot"
  git -C "$SANDBOX/work-kopifund-hub" push -q "$SANDBOX/kopifund-hub.git" main
  legacy="$HOME/services/apps/kopifund-finance/data"
  mkdir -p "$legacy/statements/dbs-multiplier"
  echo "live-db" > "$legacy/kopifund.db"
  echo "stmt" > "$legacy/statements/dbs-multiplier/s.pdf"
  echo "app-kopifund-finance" > "$STATE_DIR/docker_containers"
  mkdir -p "$HOME/services/launcher/apps"
  : > "$HOME/services/launcher/apps/kopifund-finance.json"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "writer stopped before copy"    before "Stopping the launcher" "Adopting launcher app data"
  check "legacy db adopted"             grep -qx "live-db" "$HOME/.kopifund/kopifund.db"
  check "statements adopted"            [ -f "$HOME/.kopifund/statements/dbs-multiplier/s.pdf" ]
  check "adopt marker written"          [ -f "$HOME/services/kopifund/state/legacy-adopted" ]
  check "old container stopped"         calls_have "docker stop app-kopifund-finance"
  check "says remove the tile"          out_has "launcher tile"
  check "warns Remove unpublishes"      out_has "unpublishes"
  # re-run: marker means no second adoption even if legacy dir stays
  echo "still-live" > "$legacy/kopifund.db"
  rm -f "$HOME/.kopifund/kopifund.db"
  run_deploy
  check "re-run exits zero"             [ "$CODE" -eq 0 ]
  check "no second adoption"            [ ! -f "$HOME/.kopifund/kopifund.db" ]
  teardown
}

test_legacy_not_adopted_when_hub_newer() {
  echo "• the clone's ledger is kept when the launcher's is older"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  legacy="$HOME/services/apps/kopifund-finance/data"
  mkdir -p "$legacy/notes"
  echo "old-db" > "$legacy/kopifund.db"
  touch -d '1970-01-01' "$legacy/kopifund.db" 2>/dev/null \
    || touch -t 197001010000 "$legacy/kopifund.db"
  echo "legacy-only" > "$legacy/notes/extra.txt"
  rm -f "$HOME/services/kopifund/state/legacy-adopted"
  run_deploy
  check "re-run exits zero"         [ "$CODE" -eq 0 ]
  check "hub db not regressed"      not grep -qx "old-db" "$HOME/.kopifund/kopifund.db"
  check "warned it kept the clone's" out_has "Kept the clone's ledger"
  check "files still merge"         grep -qx "legacy-only" "$HOME/.kopifund/notes/extra.txt"
  teardown
}

test_legacy_adoption_richer_db() {
  echo "• adoption: a richer legacy ledger wins by txn count, files still don't clobber"
  command -v python3 >/dev/null || { echo "    (skipped — no python3)"; return; }
  setup
  # Both sides real records: the clone's has 2 transactions, the launcher
  # app's 5 — time alone would never say which to keep; the count does.
  mk_txn_db "$SANDBOX/work-kopifund-hub/kopifund.db" 2
  printf 'hub-config\n' > "$SANDBOX/work-kopifund-hub/config.toml"
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" commit -qam "hub snapshot"
  git -C "$SANDBOX/work-kopifund-hub" push -q "$SANDBOX/kopifund-hub.git" main
  legacy="$HOME/services/apps/kopifund-finance/data"
  mkdir -p "$legacy/notes"
  mk_txn_db "$legacy/kopifund.db" 5
  printf 'wal-bytes\n' > "$legacy/kopifund.db-wal"
  printf 'legacy-config\n' > "$legacy/config.toml"
  printf 'legacy-only\n' > "$legacy/notes/extra.txt"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "richer db adopted"             [ "$(txns_in "$HOME/.kopifund/kopifund.db")" = "5" ]
  check "its -wal came along"           grep -qx "wal-bytes" "$HOME/.kopifund/kopifund.db-wal"
  check "says why it took the db"       out_has "5 transactions vs the clone's 2"
  check "clone's config kept"           grep -qx "hub-config" "$HOME/.kopifund/config.toml"
  check "legacy-only file merged"       grep -qx "legacy-only" "$HOME/.kopifund/notes/extra.txt"
  teardown
}

test_legacy_adoption_poorer_db() {
  echo "• adoption: the clone's richer ledger is never overwritten"
  command -v python3 >/dev/null || { echo "    (skipped — no python3)"; return; }
  setup
  # The real regression: the launcher's near-empty record looked newer by
  # mtime but held nothing — the count is what must keep it out.
  mk_txn_db "$SANDBOX/work-kopifund-hub/kopifund.db" 5
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" commit -qam "hub snapshot"
  git -C "$SANDBOX/work-kopifund-hub" push -q "$SANDBOX/kopifund-hub.git" main
  legacy="$HOME/services/apps/kopifund-finance/data"
  mkdir -p "$legacy/notes"
  mk_txn_db "$legacy/kopifund.db" 2
  printf 'stray-wal\n' > "$legacy/kopifund.db-wal"
  printf 'legacy-only\n' > "$legacy/notes/extra.txt"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "clone's db kept"               [ "$(txns_in "$HOME/.kopifund/kopifund.db")" = "5" ]
  check "warned it kept the clone's"    out_has "Kept the clone's ledger"
  check "legacy files still merge"      grep -qx "legacy-only" "$HOME/.kopifund/notes/extra.txt"
  check "stray -wal not left beside db" [ ! -f "$HOME/.kopifund/kopifund.db-wal" ]
  teardown
}

test_locked_clone_unlocks() {
  echo "• a sealed data clone is unlocked, not re-cloned"
  setup
  run_deploy
  check "first deploy ok" [ "$CODE" -eq 0 ]
  # re-seal: write the magic back, as a locked checkout would hold
  printf '\0GITCRYPTciphertext' > "$HOME/.kopifund/config.toml"
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"        [ "$CODE" -eq 0 ]
  check "unlock ran again"         calls_have "git-crypt unlock"
  check "file decrypted by stub"   grep -qx "ciphertext" "$HOME/.kopifund/config.toml"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, clone hard-reset, no sudo"
  setup
  run_deploy
  echo '# my-custom-marker' >> "$SVC/.env"
  echo "local edit" >> "$HOME/services/kopifund/repo/README.md"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "existing .env untouched"     env_has "my-custom-marker"
  check "clone reset hard"            not grep -q "local edit" "$HOME/services/kopifund/repo/README.md"
  check "warned about the reset"      out_has "uncommitted changes"
  check "never invoked sudo"          no_call "^sudo "
  check "compose up re-invoked"       [ -f "$STATE_DIR/compose_up" ]
  check "re-applied serve config"     calls_have "tailscale serve --bg --https=8300 http://127.0.0.1:8300"
  teardown
}

test_upstream_moves() {
  echo "• upstream moved: re-deploy fast-forwards the clone"
  setup
  run_deploy
  before="$(git -C "$HOME/services/kopifund/repo" rev-parse HEAD)"
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-finance" commit -q --allow-empty -m "v2"
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-finance" push -q "$SANDBOX/kopifund-finance.git" main
  run_deploy
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "clone moved"               [ "$(git -C "$HOME/services/kopifund/repo" rev-parse HEAD)" != "$before" ]
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  export LOCAL_PORT=8400 HTTPS_PORT=8400
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check ".env records the override"  grep -qx 'LOCAL_PORT=8400' "$SVC/.env"
  check "served :8400 -> :8400"      calls_have "tailscale serve --bg --https=8400 http://127.0.0.1:8400"
  check "prints the :8400 URL"       out_has "https://test-host.tailfake.ts.net:8400"

  export LOCAL_PORT=8401 HTTPS_PORT=8400
  run_deploy
  check "re-run: exits zero"         [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it" out_has "LOCAL_PORT=8401 ignored"
  check "re-run: .env unchanged"     grep -qx 'LOCAL_PORT=8400' "$SVC/.env"
  check "re-run: never touched 8401" no_call "127.0.0.1:8401"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n\n\n\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8300 http://127.0.0.1:8300"
  teardown
}

# ----------------------------------------------------------------- sync.sh
# These exercise real git against the file:// hub remote.
test_sync_snapshots_and_pushes() {
  echo "• sync: local changes land in the hub remote"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  echo "new note" > "$HOME/.kopifund/notes.txt"
  run_sync
  check "exits zero"              [ "$CODE" -eq 0 ]
  check "says pushed"             out_has "pushed"
  check "remote has the file"     sh -c "git -C '$SANDBOX/kopifund-hub.git' show HEAD:notes.txt | grep -qx 'new note'"
  check "snapshot commit message" sh -c "git -C '$HOME/.kopifund' log -1 --format=%s | grep -q 'snapshot:'"
  teardown
}

test_sync_fastforwards() {
  echo "• sync: a remote-only change fast-forwards the clone"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  other="$SANDBOX/other-mac"
  git clone -q "$SANDBOX/kopifund-hub.git" "$other"
  echo "from-mac" > "$other/mac-note.txt"
  env $GIT_ENV git -C "$other" add -A
  env $GIT_ENV git -C "$other" commit -qm "mac snapshot"
  env $GIT_ENV git -C "$other" push -q origin main
  run_sync
  check "exits zero"          [ "$CODE" -eq 0 ]
  check "mac file pulled"     [ -f "$HOME/.kopifund/mac-note.txt" ]
  check "says fast-forward"   out_has "fast-forwarded"
  teardown
}

test_sync_diverged_binary_conflict() {
  echo "• sync: diverged tips merge deterministically; loser kept as copy"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  # The "mac" writes a different kopifund.db and pushes FIRST, stamped older.
  other="$SANDBOX/other-mac"
  git clone -q "$SANDBOX/kopifund-hub.git" "$other"
  echo "mac-db" > "$other/kopifund.db"
  env $GIT_ENV GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" add -A
  env $GIT_ENV GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" commit -qm "mac db"
  env $GIT_ENV git -C "$other" push -q origin main
  # This box writes its own kopifund.db, stamped newer => ours wins.
  echo "server-db" > "$HOME/.kopifund/kopifund.db"
  env $GIT_ENV GIT_COMMITTER_DATE='2021-01-01T00:00:00Z' git -C "$HOME/.kopifund" add -A
  env $GIT_ENV GIT_COMMITTER_DATE='2021-01-01T00:00:00Z' git -C "$HOME/.kopifund" commit -qm "server db"
  run_sync
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "ours won the db"             grep -qx "server-db" "$HOME/.kopifund/kopifund.db"
  check "loser copy exists"           sh -c 'ls "$0"/kopifund.db.loser-* >/dev/null 2>&1' "$HOME/.kopifund"
  check "loser copy holds mac's db"   sh -c 'cat "$0"/kopifund.db.loser-* | grep -qx "mac-db"' "$HOME/.kopifund"
  check "remote got the merge"        sh -c "git -C '$SANDBOX/kopifund-hub.git' show HEAD:kopifund.db | grep -qx 'server-db'"
  # The mac pulls the merge: converged, and no re-conflict next cycle.
  env $GIT_ENV git -C "$other" pull -q --no-edit origin main >/dev/null 2>&1
  check "mac converged to winner"     grep -qx "server-db" "$other/kopifund.db"
  check "mac holds its own loser"     sh -c 'ls "$0"/kopifund.db.loser-* >/dev/null 2>&1' "$other"
  echo "another" > "$HOME/.kopifund/again.txt"
  run_sync
  check "second sync still clean"     [ "$CODE" -eq 0 ]
  check "no conflict-loop copies"     sh -c 'ls "$0"/kopifund.db.loser-*.loser-* >/dev/null 2>&1; [ $? -ne 0 ]' "$HOME/.kopifund"
  teardown
}

test_sync_diverged_gitcrypt() {
  echo "• sync: loser copies decrypt through the git-crypt smudge filter"
  setup
  # Make the fixture hub git-crypt-shaped: .gitattributes marks everything
  # filtered, and the stub's clean adds the \0GITCRYPT magic to stored blobs
  # while smudge strips it on the way out — the real filter pipeline.
  printf '* filter=git-crypt\n' > "$SANDBOX/work-kopifund-hub/.gitattributes"
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" add .gitattributes
  env $GIT_ENV git -C "$SANDBOX/work-kopifund-hub" commit -qm "encrypt everything"
  git -C "$SANDBOX/work-kopifund-hub" push -q "$SANDBOX/kopifund-hub.git" main
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  d="$HOME/.kopifund"
  git -C "$d" config filter.git-crypt.smudge 'git-crypt smudge'
  git -C "$d" config filter.git-crypt.clean 'git-crypt clean'
  git -C "$d" config filter.git-crypt.required true
  other="$SANDBOX/other-mac"
  git clone -q "$SANDBOX/kopifund-hub.git" "$other"
  git -C "$other" config filter.git-crypt.smudge 'git-crypt smudge'
  git -C "$other" config filter.git-crypt.clean 'git-crypt clean'
  git -C "$other" config filter.git-crypt.required true
  # Mac writes its db, commits (clean encrypts the blob), pushes, stamped old.
  echo "mac-db" > "$other/kopifund.db"
  PATH="$STUBS:$PATH" env $GIT_ENV GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" add -A
  PATH="$STUBS:$PATH" env $GIT_ENV GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" commit -qm "mac db"
  git -C "$other" push -q origin main
  # This box writes its own, stamped newer => ours wins.
  echo "server-db" > "$d/kopifund.db"
  PATH="$STUBS:$PATH" env $GIT_ENV GIT_AUTHOR_DATE='2021-01-01T00:00:00Z' GIT_COMMITTER_DATE='2021-01-01T00:00:00Z' git -C "$d" add -A
  PATH="$STUBS:$PATH" env $GIT_ENV GIT_AUTHOR_DATE='2021-01-01T00:00:00Z' GIT_COMMITTER_DATE='2021-01-01T00:00:00Z' git -C "$d" commit -qm "server db"
  run_sync
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "winner db is plaintext"     grep -qx "server-db" "$d/kopifund.db"
  check "loser copy is PLAINTEXT"    sh -c 'cat "$0"/kopifund.db.loser-* | grep -qx "mac-db"' "$d"
  check "loser copy has no magic"    sh -c '! od -An -c -N9 "$0"/kopifund.db.loser-* | tr -d " " | grep -qx "\\0GITCRYPT"' "$d"
  check "remote stores ciphertext"   sh -c "git -C '$SANDBOX/kopifund-hub.git' show HEAD:kopifund.db | od -An -c -N9 | tr -d ' ' | grep -qx '\\\\0GITCRYPT'"
  teardown
}

# A real SQLite fixture for the db conflict case: WAL mode, and the writer
# exits without closing so committed rows stay in the -wal file — the state
# the live app leaves behind. The sync-side checkpoint is what puts them in
# the committed .db blob.
mk_db() {
  rm -f "$1" "$1-wal" "$1-shm"
  DB_PATH="$1" DB_VAL="$2" python3 - <<'PY'
import os, sqlite3
con = sqlite3.connect(os.environ["DB_PATH"])
con.execute("PRAGMA journal_mode=WAL")
con.execute("CREATE TABLE ledger (v TEXT)")
con.execute("INSERT INTO ledger VALUES (?)", (os.environ["DB_VAL"],))
con.commit()
os._exit(0)   # skip interpreter cleanup so the -wal file outlives the writer
PY
}
read_db() {  # prints the single ledger row; fails on any integrity problem
  DB_PATH="$1" python3 - <<'PY'
import os, sqlite3
con = sqlite3.connect(os.environ["DB_PATH"])
assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print(con.execute("SELECT v FROM ledger").fetchone()[0])
PY
}

# A kopifund-shaped record: the real txn table with $2 rows — what the
# adoption check counts (plain journal mode; no sidecars). rm first: the
# path may hold a seed's plain text, which is not a db at all.
mk_txn_db() {
  rm -f "$1"
  DB_PATH="$1" DB_N="$2" python3 - <<'PY'
import os, sqlite3
con = sqlite3.connect(os.environ["DB_PATH"])
con.execute("CREATE TABLE txn (v INTEGER)")
con.executemany("INSERT INTO txn VALUES (?)", [(i,) for i in range(int(os.environ["DB_N"]))])
con.commit(); con.close()
PY
}
txns_in() {  # prints the txn row count of a real record; read-only so the
             # probe does not checkpoint away a stray -wal the next check wants
  python3 - "$1" <<'PY'
import sqlite3, sys
from urllib.parse import quote
db = sqlite3.connect("file:%s?mode=ro" % quote(sys.argv[1]), uri=True)
print(db.execute("SELECT count(*) FROM txn").fetchone()[0])
db.close()
PY
}

test_sync_diverged_sqlite() {
  echo "• sync: real sqlite dbs (WAL, live-writer state) merge intact"
  command -v python3 >/dev/null || { echo "    (skipped — no python3)"; return; }
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  other="$SANDBOX/other-mac"
  git clone -q "$SANDBOX/kopifund-hub.git" "$other"
  mk_db "$other/kopifund.db" mac
  [ -f "$other/kopifund.db-wal" ] || echo "    (note: no -wal left behind; coverage is weaker)"
  env $GIT_ENV GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" add -A
  env $GIT_ENV GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$other" commit -qm "mac db"
  git -C "$other" push -q origin main
  # This box: live-writer state, committed rows still in -wal. sync.sh's
  # own snapshot path is what must checkpoint them into the .db blob.
  mk_db "$HOME/.kopifund/kopifund.db" server
  run_sync
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "local db intact, rows kept"    test "$(read_db "$HOME/.kopifund/kopifund.db")" = "server"
  tmp="$SANDBOX/remote.db"
  git -C "$SANDBOX/kopifund-hub.git" show HEAD:kopifund.db > "$tmp"
  check "pushed .db blob is a valid db" read_db "$tmp" >/dev/null
  check "pushed .db holds server rows"  [ "$(read_db "$tmp")" = "server" ]
  check "-wal was never committed"      sh -c "! git -C '$SANDBOX/kopifund-hub.git' ls-tree -r --name-only HEAD | grep -q 'kopifund.db-wal'"
  teardown
}

test_sync_stale_lock() {
  echo "• sync: a stale lock is reclaimed; a live owner's lock is honoured"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  d="$HOME/.kopifund"
  # A dead owner + an old start: a SIGKILLed run, which must not block
  # syncing forever. The pid is beyond every platform's pid_max.
  mkdir "$d/.git/kopifund-sync.lock.d"
  printf '9876543 %s\n' "$(( $(date +%s) - 1000 ))" > "$d/.git/kopifund-sync.lock.d/pid"
  echo "note" > "$d/notes.txt"
  run_sync
  check "reclaims and exits zero"   [ "$CODE" -eq 0 ]
  check "says it reclaimed"         out_has "reclaiming"
  check "synced anyway"             sh -c "git -C '$SANDBOX/kopifund-hub.git' show HEAD:notes.txt >/dev/null"
  # A live owner (this shell's pid, fresh start) defers quietly instead.
  mkdir "$d/.git/kopifund-sync.lock.d"
  printf '%s %s\n' "$$" "$(date +%s)" > "$d/.git/kopifund-sync.lock.d/pid"
  echo "note2" > "$d/notes2.txt"
  run_sync
  check "live owner: exits zero"    [ "$CODE" -eq 0 ]
  check "live owner: did not sync"  sh -c "! git -C '$SANDBOX/kopifund-hub.git' show HEAD:notes2.txt >/dev/null 2>&1"
  rm -rf "$d/.git/kopifund-sync.lock.d"
  teardown
}

test_sync_locked_refuses() {
  echo "• sync: a sealed data folder is never committed over"
  setup
  run_deploy
  check "deploy ok" [ "$CODE" -eq 0 ]
  printf '\0GITCRYPTciphertext' > "$HOME/.kopifund/config.toml"
  run_sync
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "says locked"           out_has "locked"
  check "no snapshot commit"    sh -c "! git -C '$HOME/.kopifund' log -1 --format=%s | grep -q snapshot:"
  teardown
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

deployed() {
  setup
  mkdir -p "$HOME/services/deployd/state"
  run_deploy
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8300 (tailnet only)
|-- / proxy http://127.0.0.1:8300

https://test-host.tailfake.ts.net:18300 (tailnet only)
|-- / proxy http://127.0.0.1:18300
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps data, service home and .env"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8300"         calls_have "tailscale serve --https=8300 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18300 untouched"  no_call "https=18300"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "data clone kept"             [ -d "$HOME/.kopifund/.git" ]
  check "service home kept"           [ -d "$HOME/services/kopifund/repo" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "timer disabled"              [ ! -f "$STATE_DIR/kopifund-sync_enabled" ] || [ "$OS" != "Linux" ]
  check "analyse timer disabled"      [ ! -f "$STATE_DIR/kopifund-analyse_enabled" ] || [ "$OS" != "Linux" ]
  check "analyse units removed"       [ ! -f "$HOME/.config/systemd/user/kopifund-analyse.timer" ] || [ "$OS" != "Linux" ]
  check "analyse plist removed"       [ ! -f "$HOME/Library/LaunchAgents/com.kopifund.analyse.plist" ] || [ "$OS" = "Linux" ]
  check "deployd skip marker written" [ -f "$HOME/services/deployd/state/kopifund.disabled" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_deploy
  check "manual setup clears it"      [ ! -f "$HOME/services/deployd/state/kopifund.disabled" ]
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
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

test_teardown_foreign_port() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8300 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
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
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"        [ "$CODE" -ne 0 ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation; service home goes, data stays"
  deployed
  run_teardown --purge "kop"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: home kept"       [ -d "$HOME/services/kopifund" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  run_teardown --purge "kopifund"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "service home gone"           [ ! -e "$HOME/services/kopifund" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "data clone KEPT"             [ -d "$HOME/.kopifund/.git" ]
  check "says data is kept"           out_has "KEPT"
  check "serve off for :8300"         calls_have "tailscale serve --https=8300 off"
  teardown
}

test_teardown_purge_never_deletes_data() {
  echo "• teardown --purge: KOPIFUND_DATA inside the service home is refused"
  deployed
  sed -i.bak "s#^KOPIFUND_DATA=.*#KOPIFUND_DATA=$HOME/services/kopifund/data#" "$SVC/.env"
  run_teardown --purge "kopifund"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says data is never deleted"  out_has "never deleted"
  check "service home kept"           [ -d "$HOME/services/kopifund" ]
  teardown
}

test_teardown_serve_status_unreadable() {
  echo "• teardown: unreadable serve status stops everything"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "no compose down"           [ ! -f "$STATE_DIR/compose_down" ]
  check "no serve off attempted"    no_call " off"
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

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"
    host="$(printf '%s' "$host" | tr -d '[]')"
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
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url data_dir
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  port="$(sed -n 's/^LOCAL_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="$(sed -n 's/^HTTPS_PORT=\([0-9]*\)$/\1/p' "$SERVICE_DIR/.env")"
  https_port="${https_port:-$port}"
  data_dir="$(sed -n 's/^KOPIFUND_DATA=//p' "$SERVICE_DIR/.env")"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "kopifund container running"    sh -c "docker inspect -f '{{.State.Status}}' kopifund | grep -qx running"
  live_check "local /api/health answers"     sh -c "curl -fsS 'http://127.0.0.1:$port/api/health' | grep -q ok"
  live_check "not listening on non-local ifaces" no_external_listener "$port"
  live_check "tailscale serve maps :$https_port" sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailnet HTTPS health answers"  sh -c "curl -fsS --max-time 30 '$url:$https_port/api/health' | grep -q ok"
  live_check "data dir is the hub clone"     sh -c "test -d '$data_dir/.git'"
  live_check "data dir is unlocked"          sh -c "! od -An -c -N9 '$data_dir/config.toml' | tr -d ' ' | grep -qx '\\\\0GITCRYPT'"
  live_check "source clone present"          sh -c "test -f '$HOME/services/kopifund/repo/Dockerfile'"
  if [ "$OS" = "Linux" ]; then
    live_check "sync timer enabled"          sh -c "systemctl --user is-enabled kopifund-sync.timer"
    live_check "analyse timer enabled"       sh -c "systemctl --user is-enabled kopifund-analyse.timer"
    live_check "sync script installed"       sh -c "test -x '$HOME/services/kopifund/bin/sync.sh'"
    live_check "analyse script installed"    sh -c "test -x '$HOME/services/kopifund/bin/analyse.sh'"
    live_check "lingering keeps timer alive" sh -c "loginctl show-user '$USER' -p Linger | grep -qx 'Linger=yes'"
  else
    live_check "LaunchAgent installed"       sh -c "test -f '$HOME/Library/LaunchAgents/com.kopifund.sync.plist'"
    live_check "analyse LaunchAgent present" sh -c "test -f '$HOME/Library/LaunchAgents/com.kopifund.analyse.plist'"
  fi
}

# ------------------------------------------------------------------ run
if [ "${1:-}" = "--live" ]; then
  test_live
else
  test_preflight_root
  test_preflight_docker_perms
  test_preflight_tailscale_down
  test_preflight_bad_port
  test_preflight_repo_unreachable
  test_preflight_no_gitcrypt
  test_no_key_no_data
  test_data_dir_not_a_clone
  test_fresh_deploy
  test_analyse_script
  test_linger_escalation
  test_legacy_adoption
  test_legacy_not_adopted_when_hub_newer
  test_legacy_adoption_richer_db
  test_legacy_adoption_poorer_db
  test_locked_clone_unlocks
  test_idempotent_rerun
  test_upstream_moves
  test_port_override
  test_serve_approval_prompt
  test_sync_snapshots_and_pushes
  test_sync_fastforwards
  test_sync_diverged_binary_conflict
  test_sync_diverged_gitcrypt
  test_sync_diverged_sqlite
  test_sync_stale_lock
  test_sync_locked_refuses
  test_teardown_safe
  test_teardown_not_published
  test_teardown_foreign_port
  test_teardown_preflight
  test_teardown_purge
  test_teardown_purge_never_deletes_data
  test_teardown_serve_status_unreadable
fi

echo
if [ "$FAIL" -eq 0 ]; then
  green "all $PASS checks passed"
else
  red "$FAIL check(s) failed, $PASS passed"
  exit 1
fi
