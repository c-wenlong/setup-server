#!/usr/bin/env bash
#
# migrate-sources-to-app.sh — one-time move of the live sources site from its
# old services/sources/ deploy (an nginx compose container named `sources`
# over ~/services/sources/www, rebuilt by deployd running
# services/sources/setup.sh and by sources-trigger running
# ~/services/sources/bin/deploy.sh) to a launcher app on the `static` method
# (container `app-sources`, run by app/web/ghapp.py, editable in the
# launcher's Deploys gallery).
#
# It does not need services/sources/: everything it knows about the old
# deploy is hardcoded below, so it still works after that folder is gone.
#
# What it leaves behind is what the launcher's "New app from GitHub" flow
# (server.py create_app) writes, through the same helpers, with the port
# kept at 8098 so the URL and both Serve mappings (:8098 and :443 `/`) stay:
#
#   ~/services/launcher/apps/sources.json   the static definition: the old
#                                           build, the /api/ proxy to the
#                                           sources-trigger on host :8089,
#                                           Cache-Control no-cache
#   ~/services/apps/sources/.env            0600, SOURCE_REPO (the fetch
#                                           clone whose jobs.db the build
#                                           links in, as deploy.sh did)
#   deployd state/pollers.json "sources"    cmd app/web/ghapp.py deploy
#   ~/.config/systemd/user/sources-trigger.service.d/deploy.conf
#                                           SOURCES_DEPLOY=<python3> <deployd's
#                                           checkout>/app/web/ghapp.py deploy
#                                           sources, so the site's
#                                           Run-now and Redeploy buttons
#                                           deploy through the runner
#
# Steps:
#   1. preflight (regular user, docker, git, python3, tailscale, and uv,
#      npm and node on the PATH ghapp.py gives the build); refuse
#      when this checkout resolves a different deployd state dir than the
#      installed deployd uses; take deployd's poll lock, so no tick runs the
#      old setup.sh mid-migration
#   2. write the app's .env from the old .env (read the way deploy.sh read
#      it, `set -a; . .env`); only the keys the build needs, values never
#      printed; dies when no old .env is found
#   3. warm up: clone and check out the target commit into the app's src/
#      with ghapp.py's own fetch, while the old site keeps serving
#   4. write the definition and the (paused) deployd poller
#   5. stop the old container and run `ghapp.py deploy sources` pinned to
#      the warmed commit (the static build runs now: the site is down for
#      its length, which is printed)
#   6. success: remove the old container and its compose network, drop
#      deployd's old failure record, then write the trigger's drop-in,
#      daemon-reload, and restart sources-trigger once no sources-manual-*
#      unit is running (if it cannot, the drop-in is put back as it was
#      and a re-run retries). Failure, or an interrupt (exit trap) anywhere
#      in steps 4-5: remove the new container, start the old one again,
#      undo only what step 4 added, and exit non-zero
#
# Usage, from the checkout deployd uses (any checkout when its deployd .env
# resolves the same state dir):
#   ./scripts/migrate-sources-to-app.sh
#
# Idempotent: once a deploy is recorded, a re-run only finishes cleanup and
# makes sure the drop-in is in place (retrying a restart that failed). It never deletes ~/services/sources/
# (old clone, releases, deploy.sh copy) or any .env; it prints their paths
# so they can be removed by hand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"

KEY="sources"
OLD_CONTAINER="sources"
OLD_NETWORK="sources_default"          # compose project sources
NEW_CONTAINER="app-$KEY"
PORT=8098
TRIGGER_PORT=8089
GHAPP="$REPO_ROOT/app/web/ghapp.py"
OLD_HOME="$HOME/services/sources"
APP_DIR="$HOME/services/apps/$KEY"
DEF_FILE="$HOME/services/launcher/apps/$KEY.json"
UNIT_DIR="$HOME/.config/systemd/user"
TRIGGER="sources-trigger"
DROPIN_DIR="$UNIT_DIR/$TRIGGER.service.d"
DROPIN="$DROPIN_DIR/deploy.conf"

export KEY PORT TRIGGER_PORT REPO_ROOT
# The keys of the old .env the build needs. build_site.py itself reads no
# env; deploy.sh used SOURCE_REPO to link the fetch clone's jobs.db (the
# Jobs page) into the deploy clone, and the definition's build does the
# same. SITE_PASSPHRASE is not carried: the site is no longer encrypted.
export ENV_KEYS="SOURCE_REPO"
export GIT_TERMINAL_PROMPT=0
export PYTHONDONTWRITEBYTECODE=1

# helper <verb> [args]: the Python half. Imports the launcher's own server.py
# and ghapp.py, so the files it writes have exactly the launcher's shapes.
helper() {
  python3 - "$@" <<'PY'
import os, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "app", "web"))
import ghapp   # noqa: E402
import server  # noqa: E402

KEY = os.environ["KEY"]
PORT = int(os.environ["PORT"])
ENV_KEYS = os.environ["ENV_KEYS"].split()
ENV_FILE = os.path.join(ghapp.app_dir(KEY), ".env")
REPO = "c-wenlong/sources"
OUT = "apps/web/dist"
# deploy.sh's pipeline as one shell line: link the fetch clone's jobs.db
# (gitignored, written only there by the daily scrape; the build opens it
# read-only) or ship without Jobs, then sync and build into OUT.
BUILD = ('if [ -n "${SOURCE_REPO:-}" ] && [ -f "$SOURCE_REPO/data/jobs/jobs.db" ]; '
         'then mkdir -p data/jobs && ln -sfn "$SOURCE_REPO/data/jobs/jobs.db" '
         'data/jobs/jobs.db; fi; uv sync --quiet && '
         'uv run apps/web/build/build_site.py --out ' + OUT)


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def expected(env_names):
    # create_app's definition shape, on the static method, port pinned.
    return {"version": 1, "key": KEY, "name": "sources", "tagline": "Archive",
            "repo": REPO, "ref": "main", "method": "static",
            "build": BUILD, "output": OUT,
            "port": PORT, "health_path": "/", "volume": None,
            "proxies": [{"path": "/api/",
                         "port": int(os.environ["TRIGGER_PORT"])}],
            "cache_control": "no-cache",
            "env_names": env_names, "created_at": server._now_iso()}


def env_names():
    with open(ENV_FILE, encoding="utf-8") as fh:
        return list(server.parse_env(fh.read(), literal=True))


def check_existing_def():
    """0 none, 1 present and ours; exits on a definition that is not."""
    if not os.path.exists(ghapp.def_path(KEY)):
        return 0
    try:
        d = ghapp.load(KEY)
    except ghapp.AppError as exc:
        fail("%s exists but does not load: %s" % (ghapp.def_path(KEY), exc))
    if d.get("repo") != REPO or d.get("port") != PORT:
        fail("%s exists for repo %s on port %s, not this migration's "
             "%s on %d; not touching it"
             % (ghapp.def_path(KEY), d.get("repo"), d.get("port"), REPO, PORT))
    return 1


verb = sys.argv[1]

if verb == "state-dir":
    # deployd's state dir as this checkout resolves it, or, given a .env
    # path, as that deployd .env resolves it (same decoding either way).
    if len(sys.argv) > 2:
        ghapp.DEPLOYD_ENV = sys.argv[2]
    print(ghapp.deployd_state_dir() or "")

elif verb == "setup-repo":
    # SETUP_REPO from a deployd .env (the checkout deployd pulls and runs
    # pollers from), decoded like deployd's own load_env; "" when unset.
    import shlex
    value = ""
    try:
        with open(sys.argv[2], encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, raw = line.partition("=")
                if name.strip() != "SETUP_REPO":
                    continue
                try:
                    parts = shlex.split(raw)
                    value = parts[0] if parts else ""
                except ValueError:
                    value = raw
    except OSError:
        pass
    print(value)

elif verb == "tools":
    # The build needs uv, npm and node on the PATH ghapp.py gives a host
    # build. Checked against a bare system PATH, the one deployd's timer
    # and the trigger's transient units start from, so a tool found only
    # through this shell's PATH (the old .env's UV_BIN, say) fails here,
    # before the old site is stopped, rather than in the deploy.
    import shutil
    path = ghapp.host_path("/usr/local/bin:/usr/bin:/bin")
    missing = [t for t in ("uv", "npm", "node") if not shutil.which(t, path=path)]
    if missing:
        fail("%s not found on the PATH ghapp.py gives the build (%s); install "
             "them in one of %s, or link them there, and re-run"
             % (", ".join(missing), path, ", ".join(ghapp.HOST_PATH_DIRS)))

elif verb == "env":
    # Build the app's .env from the old .env file.
    if os.path.exists(ENV_FILE):
        print("kept the existing %s (%d keys)" % (ENV_FILE, len(env_names())))
        sys.exit(0)
    values, source = None, None
    for path in sys.argv[2:]:
        if path and os.path.isfile(path):
            # The old deploy.sh read this file with `set -a; . .env`, so
            # source it the same way (quotes, inline comments, escapes all
            # mean what they meant then) in a clean shell, and hand back
            # only the wanted keys, NUL-separated, never printed.
            res = subprocess.run(
                ["bash", "-c", 'set -a; . "$1" >/dev/null 2>&1 || exit 3; shift; '
                 'for k in "$@"; do printf "%s=%s\\0" "$k" "${!k-}"; done',
                 "_", path] + ENV_KEYS,
                capture_output=True, text=True,
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                     "HOME": os.environ.get("HOME", "")})
            if res.returncode != 0:
                fail("could not read %s as a shell file (exit %d); fix it "
                     "or write %s by hand" % (path, res.returncode, ENV_FILE))
            values = {}
            for pair in res.stdout.split("\0"):
                if pair:
                    name, _, value = pair.partition("=")
                    values[name] = value
            source = path
            break
    if values is None:
        fail("no old .env was found (looked in: %s); write %s by hand "
             "(keys: %s, e.g. SOURCE_REPO=/path/to/the/fetch/clone) and re-run"
             % (", ".join(p for p in sys.argv[2:] if p) or "nowhere",
                ENV_FILE, " ".join(ENV_KEYS)))
    lines = []
    for name in ENV_KEYS:
        value = values.get(name, "")
        if "\n" in value or "\r" in value or "\0" in value:
            fail("%s holds a multi-line value, which --env-file cannot carry; "
                 "not writing %s" % (name, ENV_FILE))
        lines.append("%s=%s" % (name, value))
    src = values.get("SOURCE_REPO", "")
    if src and not os.path.isabs(src):
        fail("SOURCE_REPO in %s is not an absolute path; write %s by hand "
             "with the fetch clone's absolute path and re-run" % (source, ENV_FILE))
    if not src:
        print("SOURCE_REPO is empty in %s: the site will build without its "
              "Jobs page" % source, file=sys.stderr)
    os.makedirs(ghapp.app_dir(KEY), exist_ok=True)
    fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote %s from %s: %d keys, %d set (values not shown)"
          % (ENV_FILE, source, len(lines),
             sum(1 for n in ENV_KEYS if values.get(n))))

elif verb == "warm":
    # The exact fetch + checkout ghapp.py deploy runs, done while the old
    # site still serves: a first clone of this repo is large, and the
    # deploy then only re-verifies the sha it is handed.
    d = ghapp.validate(expected(env_names()))
    sha = ghapp.resolve_sha(d)
    src = os.path.join(ghapp.app_dir(KEY), "src")
    ghapp.checkout(d, sha, src)
    with open(sys.argv[2], "w") as fh:
        fh.write(sha + "\n")

elif verb == "wire":
    # Definition (unless ours already) and the paused deployd poller, the
    # way create_app writes them.
    try:
        with server._ghapp_lock:
            server._check_poller_free(KEY)
            if not check_existing_def():
                d = ghapp.validate(expected(env_names()))
                server._write_app_files(d, "")    # .env exists: kept as is
            d = ghapp.load(KEY)
    except server.DeployError as exc:
        fail(exc.message)
    if not server._wire_poller(d):
        print("deployd took no poller: the app deploys by hand only",
              file=sys.stderr)
    print("definition %s, poller app/web/ghapp.py deploy %s"
          % (ghapp.def_path(KEY), KEY))

elif verb == "snapshot":
    # "<def> <poller row> <paused> <deploy record>" as 0/1 before `wire`,
    # so `unwire` can undo only what this run added and keep whatever was
    # already there. An existing poller row is saved whole to argv[2]:
    # `wire` may rewrite its repo/ref, and a rollback puts it back as it was.
    import json
    state = ghapp.deployd_state_dir()
    rows = server._deployd_overrides(state) if state else {}
    if KEY in rows:
        with open(sys.argv[2], "w", encoding="utf-8") as fh:
            json.dump(rows[KEY], fh)
    print("%d %d %d %d" % (os.path.exists(ghapp.def_path(KEY)), KEY in rows,
                           bool(state) and os.path.exists(
                               os.path.join(state, KEY + ".disabled")),
                           os.path.exists(os.path.join(ghapp.app_dir(KEY),
                                                       "deployed.json"))))

elif verb == "unwire":
    # Undo `wire` after a failed or interrupted deploy. argv[2] is the saved
    # poller row, argv[3:7] the snapshot: a 1 means that piece predates this
    # run, so it stays (a saved row goes back exactly as it was).
    import json
    had_def, had_row, had_paused, had_record = (a == "1" for a in sys.argv[3:7])
    if not had_def:
        try:
            os.remove(ghapp.def_path(KEY))
        except OSError:
            pass
    try:
        if not had_row:
            server.deployd_restore_poller(KEY)
        else:
            with open(sys.argv[2], encoding="utf-8") as fh:
                saved = json.load(fh)
            state = ghapp.deployd_state_dir()
            with server._deployd_pollers_lock:
                rows = server._deployd_overrides(state)
                if rows.get(KEY) != saved:
                    rows[KEY] = saved
                    server._deployd_write_overrides(state, rows)
    except Exception as exc:          # deployd absent: nothing to restore
        print("could not restore the poller row: %s" % exc, file=sys.stderr)
    if not had_paused:
        ghapp.set_paused(KEY, False)
    if not had_record:
        # A deploy killed after writing deployed.json must not read as a
        # finished move on the next run.
        try:
            os.remove(os.path.join(ghapp.app_dir(KEY), "deployed.json"))
        except OSError:
            pass

elif verb == "check-def":
    check_existing_def()

else:
    fail("unknown helper verb %s" % verb)
PY
}

# --------------------------------------------------------------- preflight
refuse_root
detect_os
command -v git >/dev/null || die "git is not installed"
command -v python3 >/dev/null || die "python3 is not installed"
command -v docker >/dev/null || die "docker is not installed"
docker info --format '{{.ID}}' >/dev/null 2>&1 \
  || die "cannot talk to the Docker daemon as $(id -un) (docker group? try: sg docker -c $0)"
resolve_tailscale
[ -f "$GHAPP" ] || die "no $GHAPP in this checkout"
helper check-def || die "refusing to overwrite another app's definition"
helper tools || die "the static build would not find its tools; nothing was changed"
HAVE_TRIGGER=0
if [ "$OS" = Linux ] && command -v systemctl >/dev/null && [ -f "$UNIT_DIR/$TRIGGER.service" ]; then
  HAVE_TRIGGER=1
else
  warn "no $UNIT_DIR/$TRIGGER.service here: the trigger drop-in is skipped"
fi

# ------------------------------------------------- which deployd, its lock
# The deployd that actually runs here: its installed binary has its .env
# path baked in (ENV_BAKED), and that .env names its SERVICE_HOME. This
# checkout must resolve the same state dir, or the poller row and lock
# would land somewhere the real deployd never reads.
installed_deployd_env() {
  local f bin
  # The binary the installed unit runs comes first; the default location
  # is only a fallback, since a stale copy can outlive a moved deployd.
  {
    for f in "$HOME/.config/systemd/user/deployd.service" "$HOME"/Library/LaunchAgents/*deployd*.plist; do
      [ -f "$f" ] && sed -n 's#.*[=> ]\(/[^ <]*/bin/deployd\)\([ <].*\)\{0,1\}$#\1#p' "$f"
    done
    echo "$HOME/services/deployd/bin/deployd"
  } | while IFS= read -r bin; do
    [ -f "$bin" ] && sed -n 's/^ENV_BAKED = "\(\/[^"]*\)".*/\1/p' "$bin" | head -1
  done | head -1
}
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

DEPLOYD_STATE="$(helper state-dir)"
INSTALLED_ENV="$(installed_deployd_env || true)"
if [ -n "$INSTALLED_ENV" ] && [ -f "$INSTALLED_ENV" ]; then
  installed_state="$(helper state-dir "$INSTALLED_ENV")"
  if [ -n "$installed_state" ] \
      && [ "$(real_dir "$installed_state")" != "$(real_dir "${DEPLOYD_STATE:-/nonexistent}")" ]; then
    die "deployd here keeps its state in $installed_state (config $INSTALLED_ENV), but this checkout resolves ${DEPLOYD_STATE:-none}. Run the script from the checkout deployd uses: ${INSTALLED_ENV%/services/deployd/.env}"
  fi
fi

# The trigger's deploy command runs the ghapp.py of the checkout deployd
# keeps pulled (SETUP_REPO in its .env), so it outlives the checkout this
# script runs from (a worktree, say). Then the checkout holding that .env,
# then this one when deployd is not here.
DEPLOY_ROOT="$REPO_ROOT"
if [ -n "$INSTALLED_ENV" ] && [ -f "$INSTALLED_ENV" ]; then
  setup_repo="$(helper setup-repo "$INSTALLED_ENV")"
  if [ -n "$setup_repo" ] && [ -f "$setup_repo/app/web/ghapp.py" ]; then
    DEPLOY_ROOT="$setup_repo"
  elif [ -f "${INSTALLED_ENV%/services/deployd/.env}/app/web/ghapp.py" ]; then
    DEPLOY_ROOT="${INSTALLED_ENV%/services/deployd/.env}"
  fi
fi
PYTHON3="$(command -v python3)"
# The trigger interpolates SOURCES_DEPLOY into `sh -c`, so the command is
# written into a systemd Environment= line inside double quotes: refuse a
# path that would need quoting in either place.
case "$PYTHON3:$DEPLOY_ROOT" in
  *[!A-Za-z0-9/._:-]*) die "the python3 or checkout path ($PYTHON3 $DEPLOY_ROOT) holds characters the trigger's shell command cannot carry unquoted" ;;
esac
DEPLOY_CMD="$PYTHON3 $DEPLOY_ROOT/app/web/ghapp.py deploy $KEY"

# Held for the whole run: a tick in the middle would run the old setup.sh
# (recreating the old container on the port) or the new poller early.
LOCK=""
SHA_FILE=""
ROLLBACK=0
release_lock() { [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null || true; }
on_exit() {
  local rc=$?
  if [ "$ROLLBACK" -eq 1 ]; then
    warn "interrupted before the new container answered: restoring the old deployment"
    restore
  fi
  [ -n "${DROPIN_SAVED:-}" ] && rm -f "$DROPIN_SAVED"
  [ -n "${SHA_FILE:-}" ] && rm -f "$SHA_FILE"
  [ -n "${ROW_FILE:-}" ] && rm -f "$ROW_FILE"
  release_lock
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$DEPLOYD_STATE" ]; then
  lock="$(dirname "$DEPLOYD_STATE")/.poll.lock"
  waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      warn "reclaiming a stale deployd poll lock (>60 min old)"
      rmdir "$lock" 2>/dev/null \
        || die "could not remove the stale lock $lock: check no deployd is running, then remove it by hand"
      continue
    fi
    [ "$waited" -eq 0 ] && info "waiting for the running deployd tick to finish"
    [ "$waited" -ge "${SOURCES_LOCK_WAIT:-1800}" ] && die "deployd's poll lock $lock is still held after ${waited}s"
    sleep 5; waited=$((waited + 5))
  done
  LOCK="$lock"
  ok "holding deployd's poll lock"
else
  warn "deployd is not installed here: no poller will be wired"
fi

container_exists()  { docker ps --all --filter "name=^/$1\$" --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
container_running() { [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

old_env_candidates() {
  # The ENV_FILE the old deploy.sh had baked in, then this checkout's copy.
  if [ -f "$OLD_HOME/bin/deploy.sh" ]; then
    sed -n 's/^ENV_FILE="\(.*\)"$/\1/p' "$OLD_HOME/bin/deploy.sh" | head -1
  fi
  echo "$REPO_ROOT/services/sources/.env"
}

# ------------------------------------------------------- trigger drop-in
# sources-trigger runs SOURCES_DEPLOY after every manual fetch and, with
# --force appended, for the site's Redeploy button. The drop-in points it
# at the runner; ghapp.py accepts and ignores --force.
dropin_text() {
  printf '# Written by setup-server scripts/migrate-sources-to-app.sh: the\n'
  printf "# site's Run-now and Redeploy buttons deploy through the launcher's\n"
  printf '# runner. Delete this file (then daemon-reload and restart\n'
  printf '# sources-trigger) to fall back to the trigger'"'"'s built-in default.\n'
  printf '[Service]\n'
  printf 'Environment="SOURCES_DEPLOY=%s"\n' "$DEPLOY_CMD"
}

manual_units_busy() {
  systemctl --user list-units --no-legend --plain --state=active,activating,reloading \
    'sources-manual-*' 2>/dev/null | grep -q .
}

# restart_trigger <max-wait-seconds>: restart sources-trigger once no
# sources-manual-* unit is running (a restart would drop a request the
# trigger is still serving). 0 on restart, 1 when it gave up waiting, 2
# when systemctl refused the restart.
restart_trigger() {
  local limit="$1" waited=0
  while manual_units_busy; do
    [ "$waited" -eq 0 ] && info "waiting for the running sources-manual-* unit to finish before restarting $TRIGGER"
    [ "$waited" -ge "$limit" ] && return 1
    sleep 5; waited=$((waited + 5))
  done
  systemctl --user restart "$TRIGGER" || return 2
}

# install_dropin: write the drop-in, daemon-reload, restart the trigger.
# 0 when the trigger runs with it (or there is no trigger here). On any
# failure the file goes back to what it was, so a matching file always
# means a restart picked it up and a re-run retries a failed one.
DROPIN_SAVED=""
install_dropin() {
  [ "$HAVE_TRIGGER" -eq 1 ] || return 0
  if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$(dropin_text)" ]; then
    ok "$TRIGGER drop-in already points at ghapp.py"
    return 0
  fi
  local had=0 rc=0
  if [ -f "$DROPIN" ]; then
    had=1
    DROPIN_SAVED="$(mktemp)"
    cp "$DROPIN" "$DROPIN_SAVED"
  fi
  mkdir -p "$DROPIN_DIR"
  dropin_text > "$DROPIN.tmp"
  mv "$DROPIN.tmp" "$DROPIN"
  systemctl --user daemon-reload && restart_trigger "${SOURCES_TRIGGER_WAIT:-1800}" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$TRIGGER now deploys with: ghapp.py deploy $KEY"
    return 0
  fi
  case "$rc" in
    1) warn "a sources-manual-* unit is still running after ${SOURCES_TRIGGER_WAIT:-1800}s; not restarting $TRIGGER" ;;
    *) warn "systemctl --user restart $TRIGGER failed" ;;
  esac
  if [ "$had" -eq 1 ]; then
    cp "$DROPIN_SAVED" "$DROPIN"
  else
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
  fi
  systemctl --user daemon-reload || true
  warn "put $DROPIN back as it was; $TRIGGER keeps its previous deploy command"
  return 1
}

cleanup_old() {
  if container_exists "$OLD_CONTAINER"; then
    docker rm --force "$OLD_CONTAINER" >/dev/null && ok "removed the old container $OLD_CONTAINER"
  fi
  if docker network inspect "$OLD_NETWORK" >/dev/null 2>&1; then
    if docker network rm "$OLD_NETWORK" >/dev/null 2>&1; then
      ok "removed the old compose network $OLD_NETWORK"
    else
      warn "could not remove the network $OLD_NETWORK (still in use?)"
    fi
  fi
  if [ -n "$DEPLOYD_STATE" ] && [ -f "$DEPLOYD_STATE/$KEY.fail" ]; then
    rm -f "$DEPLOYD_STATE/$KEY.fail" && ok "dropped deployd's old $KEY.fail"
  fi
}

# Put the box back the way this run found it: no new container, the old one
# running again if it was, and only the definition/poller pieces this run
# added taken back out. Safe to call twice. (The trigger drop-in is only
# written after the new site answers, so there is none to undo here.)
SNAPSHOT="1 1 1 1"
ROW_FILE=""
was_running=0
restore() {
  ROLLBACK=0
  docker rm --force "$NEW_CONTAINER" >/dev/null 2>&1 || true
  if [ "$was_running" -eq 1 ] && ! container_running "$OLD_CONTAINER"; then
    if docker start "$OLD_CONTAINER" >/dev/null; then
      ok "started $OLD_CONTAINER again"
    else
      warn "could not start $OLD_CONTAINER: run docker start $OLD_CONTAINER"
    fi
  fi
  # shellcheck disable=SC2086  # four 0/1 words, split on purpose
  helper unwire "$ROW_FILE" $SNAPSHOT \
    || warn "could not undo the definition/poller: see $DEF_FILE and deployd's pollers.json"
}

summary() {
  echo
  info "sources now runs as launcher app $KEY ($NEW_CONTAINER on 127.0.0.1:$PORT)"
  echo "    definition: $DEF_FILE"
  echo "    runtime:    $APP_DIR (.env, src/, site-*/ releases, deployed.json)"
  echo "    redeploy:   the launcher's Deploys page, the site's Redeploy button, or"
  echo "                $DEPLOY_CMD"
  [ "$HAVE_TRIGGER" -eq 1 ] && echo "    trigger:    $DROPIN"
  echo
  info "Old leftovers, safe to delete by hand once you are happy:"
  [ -d "$OLD_HOME" ] && echo "    $OLD_HOME  (old deploy clone, www/ releases, nginx.conf, deploy.sh copy)"
  local f seen=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    echo "    $f  (old .env: holds the old SITE_PASSPHRASE, delete it yourself)"
  done < <(old_env_candidates)
  for f in "$REPO_ROOT" "$DEPLOY_ROOT"; do
    [ -f "$f/services/sources/docker-compose.override.yml" ] || continue
    case " $seen " in *" $f/o "*) continue ;; esac
    seen="$seen $f/o"
    echo "    $f/services/sources/docker-compose.override.yml  (gitignored, old compose override)"
  done
  return 0
}

# --------------------------------------------------------- already migrated
# A recorded deploy means the move already happened, whether or not the app
# runs right now: never redo it, and never undo a saved app.
if [ -f "$DEF_FILE" ] && [ -f "$APP_DIR/deployed.json" ]; then
  if container_running "$NEW_CONTAINER"; then
    ok "already migrated: $NEW_CONTAINER is running from $DEF_FILE"
    cleanup_old
    install_dropin || die "the site is migrated, but $TRIGGER was not switched to ghapp.py: re-run this script once no sources-manual-* unit runs"
  else
    warn "already migrated, but $NEW_CONTAINER is not running: start or redeploy it from the launcher"
    warn "left any old $OLD_CONTAINER container and the $TRIGGER drop-in as they are"
  fi
  summary
  exit 0
fi

# ------------------------------------------------------------------- env
info "Writing $APP_DIR/.env"
candidates=()
while IFS= read -r f; do candidates+=("$f"); done < <(old_env_candidates)
helper env "${candidates[@]}" || die "could not build the app's .env; nothing else was changed"

info "Checking out the site's repo into $APP_DIR/src (the old site keeps serving meanwhile)"
SHA_FILE="$(mktemp)"
helper warm "$SHA_FILE" || die "warm-up checkout failed; the old site was not touched"
SHA="$(cat "$SHA_FILE")"
ok "checked out ${SHA:0:12}"

# ----------------------------------------------------------- def + poller
ROW_FILE="$(mktemp)"
SNAPSHOT="$(helper snapshot "$ROW_FILE")" || die "could not read the current definition/poller state"
info "Writing the launcher definition and deployd poller"
ROLLBACK=1      # from here until the new container answers, exit = restore
helper wire || die "could not write the definition or poller; the old site was not touched"

# ---------------------------------------------------------------- swap
if container_running "$OLD_CONTAINER"; then
  was_running=1
  info "Stopping $OLD_CONTAINER (frees 127.0.0.1:$PORT; kept until the new one answers)"
  docker stop "$OLD_CONTAINER" >/dev/null || die "could not stop $OLD_CONTAINER"
elif container_exists "$OLD_CONTAINER"; then
  warn "$OLD_CONTAINER exists but is stopped; it will stay stopped if the deploy fails"
fi

started="$(date +%s)"
info "Deploying ${SHA:0:12} with ghapp.py (the static build runs now; the site is down until it answers)"
if ! DEPLOY_SHA="$SHA" python3 "$GHAPP" deploy "$KEY"; then
  warn "ghapp.py deploy failed: restoring the old deployment"
  restore
  die "migration failed; the old deployment is back after $(( $(date +%s) - started ))s of downtime. $APP_DIR (.env, src/) was kept for the next try"
fi
ROLLBACK=0
ok "$NEW_CONTAINER answered after $(( $(date +%s) - started ))s of downtime"

cleanup_old
# Only now: until the new site answered, a Redeploy through the trigger
# would have run ghapp.py against this migration's own deploy (and its
# lock). Until the restart below, the trigger keeps calling the old
# deploy.sh, which only rebuilds ~/services/sources/www and touches no
# container.
info "Pointing $TRIGGER at ghapp.py"
install_dropin || die "the site is migrated, but $TRIGGER was not switched to ghapp.py: re-run this script once no sources-manual-* unit runs"
summary
