#!/usr/bin/env python3
"""ghapp.py — build and run an app straight from a GitHub repo's Dockerfile.

The runner behind the launcher's "New app from GitHub". One app is one JSON
definition the launcher writes (never hand-edited, never in this repo):

    ~/services/launcher/apps/<key>.json
        {"key", "name", "repo": "owner/name", "ref": "main",
         "dockerfile": "Dockerfile", "context": ".",
         "container_port": 3000, "port": 8301, "health_path": "/",
         "volume": "/data" | null}

and one runtime directory beside the other services:

    ~/services/apps/<key>/
        src/            the repo, checked out at the deployed commit
        .env            passed to the container with --env-file (0600)
        data/           mounted at `volume`, when the app declares one
        deployed.json   {sha, image, at}: what is running, written last
        .lock           one deploy or remove per app at a time

Usage (cwd does not matter):

    ghapp.py deploy <key>     fetch the ref (or $DEPLOY_SHA), build, swap the
                              container, health-check, publish, record
    ghapp.py remove <key>     stop the container and drop its Serve port;
                              keep src/, .env, data/ and the definition

deployd runs `deploy` from a state/pollers.json entry the launcher writes, so
a push to the watched branch redeploys with no change to deployd itself; the
launcher runs both verbs as ordinary jobs, so the log streams in its sheet.

Security model, same as every setup.sh here: the container is published on
127.0.0.1 only, and the tailnet reaches it through `tailscale serve`. Private
repos clone through git's existing credential helper (the box's `gh` login);
this file never sees a token.

Stdlib only, Linux and macOS.
"""

import errno
import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

LAUNCHER_HOME = os.path.expanduser("~/services/launcher")
DEFS_DIR = os.path.join(LAUNCHER_HOME, "apps")
APPS_HOME = os.path.expanduser("~/services/apps")

KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$")
# GitHub's own rules: owners are alphanumeric with inner dashes; names may
# also hold `.` and `_`, but never be `.` or `..`.
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/(?!\.\.?$)[A-Za-z0-9_.-]{1,100}$")
REF_RE = re.compile(r"^[A-Za-z0-9._/-]{1,128}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# A repo-relative path: no absolute paths, no `..`, nothing that could pass
# for a flag once it is on an argv.
REL_RE = re.compile(r"^(?!-)(?!/)(?!.*(^|/)\.\.(/|$))[A-Za-z0-9._/-]{1,200}$")
HEALTH_RE = re.compile(r"^/[A-Za-z0-9._~/?=&%-]{0,200}$")
VOLUME_RE = re.compile(r"^/[A-Za-z0-9._/-]{1,200}$")

# deployd's .env (read for SERVICE_HOME, never sourced) and its default home.
DEPLOYD_ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "services", "deployd", ".env")
DEPLOYD_HOME = os.path.expanduser("~/services/deployd")

HEALTH_WAIT = 90        # seconds a new container gets to answer
KEEP_IMAGES = 2         # current + one to roll back to


class AppError(Exception):
    pass


# ------------------------------------------------------------------ config

def def_path(key):
    return os.path.join(DEFS_DIR, key + ".json")


def app_dir(key):
    return os.path.join(APPS_HOME, key)


def container_name(key):
    return "app-" + key


def image_repo(key):
    return "launcher-app/" + key


def validate(d):
    """A definition dict -> the same dict, or raise AppError. Every word that
    reaches an argv is shape-checked here first."""
    if not isinstance(d, dict):
        raise AppError("definition is not an object")
    key = d.get("key")
    if not isinstance(key, str) or not KEY_RE.match(key):
        raise AppError("bad key %r" % (key,))
    if not isinstance(d.get("repo"), str) or not REPO_RE.match(d["repo"]):
        raise AppError("bad repo %r" % (d.get("repo"),))
    if not isinstance(d.get("ref"), str) or not REF_RE.match(d["ref"]) \
            or d["ref"].startswith("-"):
        raise AppError("bad ref %r" % (d.get("ref"),))
    for field in ("dockerfile", "context"):
        v = d.get(field)
        if not isinstance(v, str) or not (v == "." or REL_RE.match(v)):
            raise AppError("bad %s %r" % (field, v))
    for field in ("container_port", "port"):
        v = d.get(field)
        if not isinstance(v, int) or isinstance(v, bool) or not 1 <= v <= 65535:
            raise AppError("bad %s %r" % (field, v))
    if not isinstance(d.get("health_path"), str) or not HEALTH_RE.match(d["health_path"]):
        raise AppError("bad health_path %r" % (d.get("health_path"),))
    vol = d.get("volume")
    if vol is not None and (not isinstance(vol, str) or not VOLUME_RE.match(vol)
                            or "/../" in vol + "/"):
        raise AppError("bad volume %r" % (vol,))
    return d


def load(key):
    if not isinstance(key, str) or not KEY_RE.match(key):
        raise AppError("bad key %r" % (key,))
    try:
        with open(def_path(key), encoding="utf-8") as fh:
            return validate(json.load(fh))
    except OSError:
        raise AppError("no app called %s (no %s)" % (key, def_path(key)))
    except ValueError as exc:
        raise AppError("%s is not valid JSON: %s" % (def_path(key), exc))


def deployd_state_dir():
    """deployd's state dir: $SERVICE_HOME/state from services/deployd/.env
    (read, never sourced), else ~/services/deployd/state. None when deployd
    has never run here."""
    home = DEPLOYD_HOME
    try:
        with open(DEPLOYD_ENV, encoding="utf-8") as fh:
            for line in fh:
                name, sep, value = line.strip().partition("=")
                if sep and name.strip() in ("SERVICE_HOME", "export SERVICE_HOME"):
                    value = value.strip().strip("'\"")
                    if value:
                        home = os.path.expanduser(value.replace("$HOME", "~")
                                                  .replace("${HOME}", "~"))
    except OSError:
        pass
    state = os.path.join(home, "state")
    return state if os.path.isdir(state) else None


def set_paused(key, paused):
    """Drop or clear deployd's state/<key>.disabled, the marker every
    teardown.sh uses so a push cannot bring a removed app back."""
    state = deployd_state_dir()
    if not state:
        return
    path = os.path.join(state, key + ".disabled")
    if paused:
        with open(path, "w") as fh:
            fh.write("removed via ghapp.py\n")
    else:
        try:
            os.remove(path)
        except OSError:
            pass


def record_deployd_sha(key, sha):
    """Tell deployd this commit is live, so its next tick does not rebuild a
    commit the launcher just deployed."""
    state = deployd_state_dir()
    if not state:
        return
    tmp = os.path.join(state, ".%s.sha.tmp" % key)
    with open(tmp, "w") as fh:
        fh.write(sha + "\n")
    os.replace(tmp, os.path.join(state, key + ".sha"))


def clone_url(repo):
    return "https://github.com/%s.git" % repo


# ------------------------------------------------------------------ argv

def build_argv(d, sha, src):
    ctx = os.path.normpath(os.path.join(src, d["context"]))
    return ["docker", "build",
            "--tag", "%s:%s" % (image_repo(d["key"]), sha[:12]),
            "--file", os.path.normpath(os.path.join(src, d["dockerfile"])),
            "--label", "setup-server.app=%s" % d["key"],
            "--label", "org.opencontainers.image.revision=%s" % sha,
            "--label", "org.opencontainers.image.source=https://github.com/%s" % d["repo"],
            ctx]


def run_argv(d, image):
    """`docker run` for the app. 127.0.0.1 only, restart unless-stopped (a
    stopped app stays stopped across reboots, the same policy as the compose
    services)."""
    key = d["key"]
    argv = ["docker", "run", "--detach",
            "--name", container_name(key),
            "--restart", "unless-stopped",
            "--publish", "127.0.0.1:%d:%d" % (d["port"], d["container_port"]),
            "--label", "setup-server.app=%s" % key]
    env_file = os.path.join(app_dir(key), ".env")
    if os.path.isfile(env_file):
        argv += ["--env-file", env_file]
    if d.get("volume"):
        argv += ["--volume", "%s:%s" % (os.path.join(app_dir(key), "data"), d["volume"])]
    return argv + [image]


# ------------------------------------------------------------------ helpers

def say(msg):
    print("==> " + msg, flush=True)


def run(argv, check=True, capture=False, cwd=None):
    """Run an argv (never a shell), echoing it to the job log first."""
    print("$ " + " ".join(argv), flush=True)
    res = subprocess.run(argv, cwd=cwd, text=True,
                         stdout=subprocess.PIPE if capture else None,
                         stderr=subprocess.STDOUT if capture else None)
    if check and res.returncode != 0:
        raise AppError("%s exited %d" % (argv[0] if argv[0] != "docker" else
                                         "docker " + argv[1], res.returncode))
    return res


def quiet(argv, cwd=None):
    """Run without echo; (returncode, stdout)."""
    try:
        res = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    except OSError:
        return 127, ""
    return res.returncode, res.stdout


def tailscale_bin():
    found = shutil.which("tailscale")
    if found:
        return found
    mac = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return mac if os.path.isfile(mac) else None


def resolve_sha(d):
    env_sha = os.environ.get("DEPLOY_SHA", "")
    if SHA_RE.match(env_sha):
        return env_sha
    code, out = quiet(["git", "ls-remote", clone_url(d["repo"]), d["ref"]])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and SHA_RE.match(parts[0]):
            return parts[0]
    raise AppError("could not resolve %s on %s (git ls-remote exited %d)"
                   % (d["ref"], d["repo"], code))


def checkout(d, sha, src):
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        run(["git", "clone", "--no-checkout", "--filter=blob:none",
             clone_url(d["repo"]), src])
    # A key can be deleted and re-created for another repo while src/ stays:
    # origin always follows the current definition.
    run(["git", "-C", src, "remote", "set-url", "origin", clone_url(d["repo"])])
    run(["git", "-C", src, "fetch", "--quiet", "origin", sha])
    run(["git", "-C", src, "checkout", "--quiet", "--force", "--detach", sha])
    run(["git", "-C", src, "clean", "-ffdxq"])


def current_image(key):
    """The image ID (sha256:...) the app's container runs, or None. The ID,
    not the tag: a redeploy of the same commit rebuilds the same tag, and
    only the ID still names the image that was working."""
    code, out = quiet(["docker", "inspect", "--format", "{{.Image}}",
                       container_name(key)])
    out = out.strip()
    return out if code == 0 and out.startswith("sha256:") else None


def healthy(d, timeout):
    url = "http://127.0.0.1:%d%s" % (d["port"], d["health_path"])
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as res:
                if res.status < 500:
                    return True
        except urllib.error.HTTPError as exc:
            if exc.code < 500:      # a 401/404 still means the app answers
                return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(2)
    return False


def serve_ports():
    """{https_port: proxy target or None} for EVERY port this node's Serve
    config holds (a static or text handler maps to None), or None if the
    config cannot be read. Allocation treats every key as taken; ownership
    checks compare the target, which a non-proxy handler never matches."""
    ts = tailscale_bin()
    if not ts:
        return None
    code, out = quiet([ts, "serve", "status", "--json"])
    if code != 0:
        return None
    try:
        doc = json.loads(out or "{}")
    except ValueError:
        return None
    ports = {}
    for port in (doc.get("TCP") or {}):
        ports.setdefault(str(port), None)
    for hostport, conf in (doc.get("Web") or {}).items():
        port = hostport.rsplit(":", 1)[-1]
        ports.setdefault(port, None)
        for h in ((conf or {}).get("Handlers") or {}).values():
            if isinstance(h, dict) and h.get("Proxy"):
                ports[port] = h["Proxy"]
    return ports


def publish(d):
    ts = tailscale_bin()
    if not ts:
        say("tailscale not found: the app runs on 127.0.0.1:%d only" % d["port"])
        return
    target = "http://127.0.0.1:%d" % d["port"]
    ports = serve_ports() or {}
    if ports.get(str(d["port"])) == target:
        say("already published on :%d" % d["port"])
        return
    run([ts, "serve", "--bg", "--https=%d" % d["port"], target])


def prune_images(key, keep_ref):
    code, out = quiet(["docker", "image", "ls", image_repo(key),
                       "--format", "{{.Repository}}:{{.Tag}}"])
    refs = [r for r in out.split() if r and r != keep_ref]
    for ref in refs[KEEP_IMAGES - 1:]:
        quiet(["docker", "image", "rm", ref])


class Lock(object):
    def __init__(self, key):
        os.makedirs(app_dir(key), exist_ok=True)
        self.fh = open(os.path.join(app_dir(key), ".lock"), "w")

    def __enter__(self):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES):
                raise AppError("another deploy or remove of this app is running")
            raise
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


# ------------------------------------------------------------------ verbs

def swap(d, image, previous):
    """Replace the running container with `image`. If the new one cannot
    start or does not answer in time, put `previous` (an image ID) back and
    fail: the box is never left without the version that was working."""
    key = d["key"]
    quiet(["docker", "rm", "--force", container_name(key)])
    say("starting %s on 127.0.0.1:%d" % (container_name(key), d["port"]))
    try:
        run(run_argv(d, image))
        if not healthy(d, HEALTH_WAIT):
            run(["docker", "logs", "--tail", "40", container_name(key)], check=False)
            raise AppError("http://127.0.0.1:%d%s did not answer within %ds"
                           % (d["port"], d["health_path"], HEALTH_WAIT))
    except AppError:
        quiet(["docker", "rm", "--force", container_name(key)])
        if previous:
            say("rolling back to the image that was running (%s)" % previous[:19])
            run(run_argv(d, previous), check=False)
        raise


def deploy(key):
    load(key)                 # fail fast on a bad key or missing definition
    with Lock(key):
        d = load(key)         # re-read under the lock: a delete may have won
        sha = resolve_sha(d)
        say("deploying %s at %s (%s)" % (d["repo"], sha[:12], d["ref"]))
        src = os.path.join(app_dir(key), "src")
        checkout(d, sha, src)
        if not os.path.isfile(os.path.join(src, d["dockerfile"])):
            raise AppError("no %s in %s at %s" % (d["dockerfile"], d["repo"], sha[:12]))
        if d.get("volume"):
            os.makedirs(os.path.join(app_dir(key), "data"), exist_ok=True)

        image = "%s:%s" % (image_repo(key), sha[:12])
        # Taken BEFORE the build: rebuilding the same commit moves the tag,
        # and the ID is then the only name left for the working image.
        previous = current_image(key)
        say("building %s" % image)
        run(build_argv(d, sha, src))
        swap(d, image, previous)

        publish(d)
        with open(os.path.join(app_dir(key), "deployed.json.tmp"), "w") as fh:
            json.dump({"sha": sha, "image": image, "ref": d["ref"],
                       "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, fh)
        os.replace(os.path.join(app_dir(key), "deployed.json.tmp"),
                   os.path.join(app_dir(key), "deployed.json"))
        prune_images(key, image)
        record_deployd_sha(key, sha)
        set_paused(key, False)    # a removed (or new) app resumes auto-deploy
        say("deployed %s at %s" % (key, sha[:12]))


def remove(key):
    d = load(key)
    with Lock(key):
        quiet(["docker", "rm", "--force", container_name(key)])
        say("container %s removed" % container_name(key))
        ts = tailscale_bin()
        ports = serve_ports()
        target = "http://127.0.0.1:%d" % d["port"]
        if ts and ports and ports.get(str(d["port"])) == target:
            run([ts, "serve", "--https=%d" % d["port"], "off"], check=False)
        try:
            os.remove(os.path.join(app_dir(key), "deployed.json"))
        except OSError:
            pass
        set_paused(key, True)     # a push must not bring it back
        say("removed %s; src, .env and data stay in %s" % (key, app_dir(key)))


def docker_reachable():
    code, _ = quiet(["docker", "info", "--format", "{{.ID}}"])
    return code == 0


def reexec_with_docker_group(argv):
    """A systemd user unit (deployd's timer) does not reliably carry the
    docker group even when the user is in it. Re-enter once under
    `sg docker`, the same workaround the launcher's sg_docker() applies;
    GHAPP_SG marks the second pass so it can never loop."""
    if os.environ.get("GHAPP_SG") or docker_reachable():
        return
    sg = shutil.which("sg")
    if not sg:
        return
    os.environ["GHAPP_SG"] = "1"
    cmd = " ".join(shlex.quote(a) for a in
                   [sys.executable, os.path.abspath(__file__)] + argv[1:])
    os.execv(sg, [sg, "docker", "-c", cmd])


def main(argv):
    if len(argv) != 3 or argv[1] not in ("deploy", "remove"):
        print("usage: ghapp.py deploy|remove <key>", file=sys.stderr)
        return 2
    reexec_with_docker_group(argv)
    try:
        (deploy if argv[1] == "deploy" else remove)(argv[2])
    except AppError as exc:
        print("error: %s" % exc, file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
