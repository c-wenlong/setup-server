#!/usr/bin/env bash
#
# migrate-kaichenpedia-to-app.sh — one-time move of the live kaichenpedia
# wiki from its old services/kaichenpedia/ deploy (a compose container named
# `kaichenpedia`, rebuilt by deployd running services/kaichenpedia/setup.sh)
# to a launcher app on the `dockerfile` method (container `app-kaichenpedia`,
# run by app/web/ghapp.py, editable in the launcher's Deploys gallery).
#
# It does not need services/kaichenpedia/: everything it knows about the old
# deploy is hardcoded below, so it still works after that folder is gone.
#
# What it leaves behind is exactly what the launcher's "New app from GitHub"
# flow (server.py create_app) writes, through the same helpers, except that
# the port stays 8091 so the URL and the Serve mapping do not move:
#
#   ~/services/launcher/apps/kaichenpedia.json   the definition
#   ~/services/apps/kaichenpedia/.env            0600, the old container's
#                                                environment (names below)
#   deployd state/pollers.json "kaichenpedia"    cmd app/web/ghapp.py deploy
#
# Steps:
#   1. preflight (regular user, docker, git, python3, tailscale) and take
#      deployd's poll lock, so no tick runs the old setup.sh mid-migration
#   2. write the app's .env from the running container's environment (or
#      the old .env file when the container is gone); never printed
#   3. warm the build: check out the target commit into the app's src/ and
#      run the very `docker build` ghapp.py will run, so the swap is seconds
#   4. write the definition and the (paused) deployd poller
#   5. stop the old container and run `ghapp.py deploy kaichenpedia`
#   6. success: remove the old container and its compose network, drop
#      deployd's old failure record. Failure: remove the new container, start
#      the old one again, undo step 4 and exit non-zero
#
# Usage, from any checkout of this repo:
#   ./scripts/migrate-kaichenpedia-to-app.sh
#
# Idempotent: a re-run after success only finishes any cleanup it finds. It
# never deletes ~/services/kaichenpedia/ (old clone and build state) or any
# .env; it prints their paths so they can be removed by hand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"

KEY="kaichenpedia"
OLD_CONTAINER="kaichenpedia"
OLD_NETWORK="kaichenpedia_default"     # compose project kaichenpedia
NEW_CONTAINER="app-$KEY"
PORT=8091
GHAPP="$REPO_ROOT/app/web/ghapp.py"
OLD_HOME="$HOME/services/kaichenpedia"
APP_DIR="$HOME/services/apps/$KEY"
DEF_FILE="$HOME/services/launcher/apps/$KEY.json"

export KEY PORT REPO_ROOT OLD_CONTAINER
# The keys the old docker-compose.yml passed in `environment:`. PORT and
# HOSTNAME are fixed values there too and are written as such.
export ENV_KEYS="GH_TOKEN COPILOT_SECRET COPILOT_PROVIDER COPILOT_API_KEY COPILOT_BASE_URL COPILOT_MODEL ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY MODELS_ALLOWED_HOSTS"
export GIT_TERMINAL_PROMPT=0
export PYTHONDONTWRITEBYTECODE=1

# helper <verb> [args]: the Python half. Imports the launcher's own server.py
# and ghapp.py, so the files it writes have exactly the launcher's shapes.
helper() {
  python3 - "$@" <<'PY'
import json, os, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "app", "web"))
import ghapp   # noqa: E402
import server  # noqa: E402

KEY = os.environ["KEY"]
PORT = int(os.environ["PORT"])
ENV_KEYS = os.environ["ENV_KEYS"].split()
ENV_FILE = os.path.join(ghapp.app_dir(KEY), ".env")


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def expected(env_names):
    # create_app's definition, field for field, with the port pinned.
    return {"version": 1, "key": KEY, "name": "kaichenpedia",
            "tagline": "Wiki", "repo": "c-wenlong/kaichenpedia",
            "ref": "main", "dockerfile": "site/Dockerfile", "context": ".",
            "container_port": 8080, "port": PORT, "health_path": "/",
            "volume": None, "env_names": env_names,
            "created_at": server._now_iso()}


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
    if d.get("repo") != "c-wenlong/kaichenpedia" or d.get("port") != PORT:
        fail("%s exists for repo %s on port %s, not this migration's "
             "c-wenlong/kaichenpedia on %d; not touching it"
             % (ghapp.def_path(KEY), d.get("repo"), d.get("port"), PORT))
    return 1


verb = sys.argv[1]

if verb == "state-dir":
    print(ghapp.deployd_state_dir() or "")

elif verb == "env":
    # Build the app's .env from the old container, else the old .env file.
    if os.path.exists(ENV_FILE):
        print("kept the existing %s (%d keys)" % (ENV_FILE, len(env_names())))
        sys.exit(0)
    values, source = None, None
    res = subprocess.run(["docker", "inspect", os.environ["OLD_CONTAINER"],
                          "--format", "{{json .Config.Env}}"],
                         capture_output=True, text=True)
    if res.returncode == 0:
        try:
            pairs = json.loads(res.stdout)
        except ValueError:
            fail("docker inspect %s did not return JSON" % os.environ["OLD_CONTAINER"])
        values = {}
        for pair in pairs or []:
            name, _, value = pair.partition("=")
            values[name] = value
        source = "container %s" % os.environ["OLD_CONTAINER"]
    else:
        for path in sys.argv[2:]:
            if path and os.path.isfile(path):
                with open(path, encoding="utf-8") as fh:
                    values = server.parse_env(fh.read())   # compose/shell style
                source = path
                break
    if values is None:
        fail("container %s is gone and no old .env was found (looked in: %s); "
             "write %s by hand (keys: %s) and re-run"
             % (os.environ["OLD_CONTAINER"], ", ".join(p for p in sys.argv[2:] if p)
                or "nowhere", ENV_FILE, " ".join(ENV_KEYS)))
    lines = []
    for name in ENV_KEYS:
        value = values.get(name, "")
        if "\n" in value or "\r" in value or "\0" in value:
            fail("%s holds a multi-line value, which --env-file cannot carry; "
                 "not writing %s" % (name, ENV_FILE))
        lines.append("%s=%s" % (name, value))
    lines += ["PORT=8080", "HOSTNAME=0.0.0.0"]
    os.makedirs(ghapp.app_dir(KEY), exist_ok=True)
    fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote %s from %s: %d keys, %d set (values not shown)"
          % (ENV_FILE, source, len(lines),
             sum(1 for n in ENV_KEYS if values.get(n)) + 2))

elif verb == "warm":
    # The exact checkout + build ghapp.py deploy runs, so its build is cached.
    d = ghapp.validate(expected(env_names()))
    sha = ghapp.resolve_sha(d)
    src = os.path.join(ghapp.app_dir(KEY), "src")
    ghapp.checkout(d, sha, src)
    if not os.path.isfile(ghapp.inside_checkout(d, src, "dockerfile")):
        fail("no %s in %s at %s" % (d["dockerfile"], d["repo"], sha[:12]))
    ghapp.run(ghapp.build_argv(d, sha, src))
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

elif verb == "unwire":
    # Undo `wire` after a failed deploy. argv[2] == "1": deployd's
    # .disabled marker was already there before this run, so keep it.
    try:
        os.remove(ghapp.def_path(KEY))
    except OSError:
        pass
    try:
        server.deployd_restore_poller(KEY)
    except Exception as exc:          # deployd absent: nothing to restore
        print("could not drop the poller row: %s" % exc, file=sys.stderr)
    if sys.argv[2] != "1":
        ghapp.set_paused(KEY, False)

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

# ----------------------------------------------------- deployd's poll lock
# Held for the whole run: a tick in the middle would run the old setup.sh
# (recreating the old container on the port) or the new poller early.
DEPLOYD_STATE="$(helper state-dir)"
LOCK=""
release_lock() { [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null || true; }
trap release_lock EXIT
if [ -n "$DEPLOYD_STATE" ]; then
  lock="$(dirname "$DEPLOYD_STATE")/.poll.lock"
  waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      warn "reclaiming a stale deployd poll lock (>60 min old)"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    [ "$waited" -eq 0 ] && info "waiting for the running deployd tick to finish"
    [ "$waited" -ge "${KPEDIA_LOCK_WAIT:-1800}" ] && die "deployd's poll lock $lock is still held after ${waited}s"
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
  echo "$REPO_ROOT/services/kaichenpedia/.env"
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

summary() {
  echo
  info "kaichenpedia now runs as launcher app $KEY ($NEW_CONTAINER on 127.0.0.1:$PORT)"
  echo "    definition: $DEF_FILE"
  echo "    runtime:    $APP_DIR (.env, src/, deployed.json)"
  echo "    redeploy:   the launcher's Deploys page, or app/web/ghapp.py deploy $KEY from a checkout"
  echo
  info "Old leftovers, safe to delete by hand once you are happy:"
  [ -d "$OLD_HOME" ] && echo "    $OLD_HOME  (old clone, build state, deploy.sh copy)"
  local f seen=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    echo "    $f  (old .env: holds secrets, delete it yourself)"
  done < <(old_env_candidates)
  local images
  images="$(docker image ls kaichenpedia --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)"
  [ -n "$images" ] && echo "    old images: $(echo "$images" | tr '\n' ' ')(docker image rm ...)"
  return 0
}

# --------------------------------------------------------- already migrated
if [ -f "$DEF_FILE" ] && [ -f "$APP_DIR/deployed.json" ] && container_running "$NEW_CONTAINER"; then
  ok "already migrated: $NEW_CONTAINER is running from $DEF_FILE"
  cleanup_old
  summary
  exit 0
fi

# ------------------------------------------------------------ env + warm-up
info "Writing $APP_DIR/.env"
candidates=()
while IFS= read -r f; do candidates+=("$f"); done < <(old_env_candidates)
helper env "${candidates[@]}" || die "could not build the app's .env; nothing else was changed"

info "Warming the build cache (the old site keeps serving meanwhile)"
SHA_FILE="$(mktemp)"
release_all() { rm -f "$SHA_FILE"; release_lock; }
trap release_all EXIT
helper warm "$SHA_FILE" || die "warm-up build failed; the old site was not touched"
SHA="$(cat "$SHA_FILE")"
ok "image for ${SHA:0:12} built"

# --------------------------------------------------------- def + poller
had_disabled=0
[ -n "$DEPLOYD_STATE" ] && [ -e "$DEPLOYD_STATE/$KEY.disabled" ] && had_disabled=1
info "Writing the launcher definition and deployd poller"
helper wire || die "could not write the definition or poller; the old site was not touched"

# ---------------------------------------------------------------- swap
was_running=0
if container_running "$OLD_CONTAINER"; then
  was_running=1
  info "Stopping $OLD_CONTAINER (frees 127.0.0.1:$PORT; kept until the new one answers)"
  docker stop "$OLD_CONTAINER" >/dev/null || die "could not stop $OLD_CONTAINER"
elif container_exists "$OLD_CONTAINER"; then
  warn "$OLD_CONTAINER exists but is stopped; it will stay stopped if the deploy fails"
fi

started="$(date +%s)"
info "Deploying with ghapp.py at ${SHA:0:12}"
if ! DEPLOY_SHA="$SHA" python3 "$GHAPP" deploy "$KEY"; then
  warn "ghapp.py deploy failed: restoring the old deployment"
  docker rm --force "$NEW_CONTAINER" >/dev/null 2>&1 || true
  if [ "$was_running" -eq 1 ]; then
    docker start "$OLD_CONTAINER" >/dev/null && ok "started $OLD_CONTAINER again" \
      || warn "could not start $OLD_CONTAINER: run docker start $OLD_CONTAINER"
  fi
  helper unwire "$had_disabled" || warn "could not undo the definition/poller: see $DEF_FILE and deployd's pollers.json"
  die "migration failed; the old deployment is back. $APP_DIR (.env, src/) was kept for the next try"
fi
ok "$NEW_CONTAINER answered after $(( $(date +%s) - started ))s of downtime"

cleanup_old
summary
