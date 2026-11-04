#!/usr/bin/env python3
"""ghapp.py — deploy an app from a GitHub repo, through a per-app method.

The runner behind the launcher's "New app from GitHub" and the deployments
gallery. One app is one JSON definition the launcher writes (never
hand-edited, never in this repo):

    ~/services/launcher/apps/<key>.json
        {"key", "name", "repo": "owner/name", "ref": "main",
         "method": "dockerfile" | "image" | "compose" | "static"
                 | "node" | "python" | "script",   # absent == "dockerfile"
         "container_port": 3000, "port": 8301, "health_path": "/",
         "volume": "/data" | null,
         ... the method's own fields, below ...}

and one runtime directory beside the other services:

    ~/services/apps/<key>/
        src/            the repo, checked out at the deployed commit
        .env            passed to the container with --env-file (0600;
                        not to static's nginx), and overlaid on the env of
                        host-run commands (below)
        data/           mounted at `volume`, when the app declares one
        deployed.json   {sha, image, method, ref, at, release?, definition}:
                        what is running, written last. `definition` is the
                        definition as deployed (it holds env_names, never
                        values): the next deploy reads it to stop this
                        method's runtime when the method changes
        site-*/         static method only: the live and rollback releases
        .lock           one deploy or remove per app at a time

Methods, and the fields each adds to the definition:

    dockerfile  "dockerfile" (path), "context", "container_port" — build the
                repo's Dockerfile, run the image. The default: a definition
                with no "method", or a word this file does not know, deploys
                exactly as it always has.
    image       "image" (name:tag or name@digest), "container_port" — pull
                and run; no build, no checkout contents used.
    compose     "compose_file" (repo-relative path), "service" (optional:
                which service the published port serves, used to scope the
                failure log), "container_port" — `docker compose up -d` on
                the repo's file, under project app-<key>. The compose file
                owns its own port mapping; it must publish the service on
                127.0.0.1:`port`. Rollback re-checks-out the previous
                deployed sha and `up -d`s it again.
                Volumes caveat: src/ is machine-managed — every deploy runs
                `checkout --force` + `clean -ffdxq` — so compose-managed
                volumes must live outside the checkout (absolute host paths
                or named volumes); bind mounts under src/ do not survive.
    static      "build" (shell command run in src/), "output" (repo-relative
                dir) — run the build, copy the output to a fresh per-build
                release dir outside src/ (site-<sha12>-<ms>/, recorded in
                deployed.json, so neither `git clean` nor a same-commit
                rebuild can delete what is being served), then serve it
                read-only from a small nginx container on the app's port.
                That container gets no --env-file: it only serves files,
                and the .env holds the build's secrets. Rollback mounts
                the previous release.
    node        "version" (image tag suffix, e.g. "22-alpine"), "start"
    python      (e.g. "3.13-slim"), optional "build" — a generated
                Dockerfile is rendered into the checkout, then the method
                behaves as `dockerfile`.
    script      "cmd" (shell command run in src/, no container) — the escape
                hatch. Deploy is: checkout, run cmd. No container, no
                publish of its own; the health check still runs against
                "port"+"health_path" when both are set, and both are the only
                fields a script definition may omit.

A definition's shell words (build/start/cmd) run via `sh -c` inside src/;
every other word still reaches an argv only after validate() shape-checks it.

Host-run commands (static's `build` and script's `cmd`; node/python's
`build`/`start` run inside the generated Dockerfile and get none of this)
run with the runner's own environment overlaid with the app's .env, read
with `docker run --env-file` rules because the same file feeds that flag:
`KEY=VALUE` taken literally (quotes kept, no expansion), blank and `#` lines
skipped, a bare `KEY` taking KEY from the runner's env when set there, and a
line whose name fails ENV_NAME_RE skipped with a warning naming only its
line number. PATH is the runner's with ~/.local/bin, ~/.nix-profile/bin,
/opt/homebrew/bin and /usr/local/bin put in front (each only if it exists,
each once), since deployd's systemd user unit has a minimal PATH; a PATH in
.env is ignored for host commands (one log line, no value), because in a
container it would replace the image's own. Values go into the child's
environment only, never an argv, so the echoed `$ ...` line carries none.

Method switches belong to the runner, so every way a deploy starts (the
gallery's save, a deployd poll, `ghapp.py deploy` by hand, a hand-edited
definition) gets the same handling. Under the app lock, deploy() compares
the method in the previous deployed.json with the definition's. When they
differ and the new method would not replace the old runtime on its own
(see switch_steps), the old runtime is stopped first, cleared on success,
and brought back if the deploy fails, so the port is never held by the old
method and a failed switch leaves the version that was working:

    compose -> anything   `compose down` on the old stack (the recorded
                          definition's file; by project label when an older
                          deployed.json has none); on failure, remove what
                          the new method started and `up -d` the old stack
                          at its recorded sha
    container -> script   stop app-<key>; on failure, start it again
    container -> compose  park app-<key> as app-<key>.parked (stopped);
                          remove it on success; on failure, clear the
                          project's containers and put it back
    script -> anything    nothing: a script's own processes are its own
    container -> container  nothing: swap() replaces app-<key> itself

("container" is any of CONTAINER_METHODS.)

Usage (cwd does not matter):

    ghapp.py deploy <key>     fetch the ref (or $DEPLOY_SHA, which must be on
                              origin/<ref>), switch methods if needed, run
                              the method, health-check, publish, record
    ghapp.py remove <key>     stop the container or compose stack and drop
                              its Serve port; keep src/, .env, data/ and the
                              definition

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
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")

# The deployment methods and the field shapes only they use. A command is
# not regex-gated (any shell is legitimate): the contract is one line of
# printable text, short enough to echo in a job log.
METHODS = ("dockerfile", "image", "compose", "static", "node", "python",
           "script")
CONTAINER_METHODS = ("dockerfile", "image", "static", "node", "python")
METHOD_RE = re.compile(r"^[a-z][a-z0-9-]{0,19}$")
# A docker image reference: registry/namespace/name:tag or name@digest. The
# gate is "can never be a flag or a path": starts alnum, one `:` or `@` for
# the tag/digest, no whitespace or shell words beyond the reference's own
# alphabet.
IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]{1,255}$")
# Runtime tag suffixes ("22", "22.1-alpine", "3.13-slim", "lts") and compose
# service names.
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$")
SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")

# Where the generated Dockerfile lands inside the checkout for node/python
# (untracked on purpose: `git clean` drops it, every deploy rewrites it),
# and the small web server behind the static method.
GENERATED_DOCKERFILE = ".ghapp.Dockerfile"
STATIC_IMAGE = "nginx:1.27-alpine"
STATIC_CONTAINER_PORT = 80
STATIC_DOCROOT = "/usr/share/nginx/html"

# deployd's .env (read for SERVICE_HOME, never sourced) and its default home.
DEPLOYD_ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "services", "deployd", ".env")
DEPLOYD_HOME = os.path.expanduser("~/services/deployd")

# Tool dirs put in front of the runner's PATH for host-run commands (static
# `build`, script `cmd`), each only when it exists: deployd runs the runner
# from a systemd user unit whose PATH has none of them, so `uv`, `npm` or a
# Homebrew tool would otherwise be "not found" under a poll but not by hand.
HOST_PATH_DIRS = ("~/.local/bin", "~/.nix-profile/bin", "/opt/homebrew/bin",
                  "/usr/local/bin")

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


def method_of(d):
    """The definition's deploy method. An absent, null or unrecognised word
    is `dockerfile`: definitions written before methods existed deploy
    unchanged, and a typo fails on the dockerfile fields it is then missing
    rather than passing as something new."""
    m = d.get("method")
    return m if m in METHODS else "dockerfile"


def _rel_field(d, field, allow_dot=True):
    """A required repo-relative path, or raise. REL_RE itself accepts ".",
    which is only meaningful for context/output, not for a file."""
    v = d.get(field)
    if not isinstance(v, str) or (v == "." and not allow_dot) \
            or (v != "." and not REL_RE.match(v)):
        raise AppError("bad %s %r" % (field, v))


def _port_field(d, field, required=True):
    """A TCP port; `required=False` lets the script method leave it out."""
    v = d.get(field)
    if v is None and not required:
        return
    if not isinstance(v, int) or isinstance(v, bool) or not 1 <= v <= 65535:
        raise AppError("bad %s %r" % (field, v))


def _cmd_field(d, field, required=True):
    """A shell command: one line of text, no embedded newlines (a newline
    would split a generated Dockerfile's RUN line). Not regex-gated — any
    shell is legitimate; it only ever runs via `sh -c` inside src/."""
    v = d.get(field)
    if v is None and not required:
        return
    if not isinstance(v, str) or not 0 < len(v) <= 500 \
            or "\n" in v or "\r" in v or "\0" in v:
        raise AppError("bad %s %r" % (field, v))


def validate(d):
    """A definition dict -> the same dict, or raise AppError. Every word that
    reaches an argv is shape-checked here first; which fields are required
    depends on the method (method_of: absent or unknown means dockerfile)."""
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
    method = d.get("method")
    if method and (not isinstance(method, str) or not METHOD_RE.match(method)):
        raise AppError("bad method %r" % (method,))
    m = method_of(d)
    if m == "dockerfile":
        _rel_field(d, "dockerfile")
        _rel_field(d, "context")
        _port_field(d, "container_port")
    elif m == "image":
        v = d.get("image")
        if not isinstance(v, str) or not IMAGE_RE.match(v) \
                or (":" not in v and "@" not in v):
            raise AppError("bad image %r" % (v,))
        _port_field(d, "container_port")
    elif m == "compose":
        _rel_field(d, "compose_file", allow_dot=False)
        svc = d.get("service")
        if svc is not None and (not isinstance(svc, str)
                                or not SERVICE_RE.match(svc)):
            raise AppError("bad service %r" % (svc,))
        _port_field(d, "container_port")
    elif m == "static":
        _cmd_field(d, "build")
        _rel_field(d, "output")
    elif m in ("node", "python"):
        v = d.get("version")
        if not isinstance(v, str) or not VERSION_RE.match(v):
            raise AppError("bad version %r" % (v,))
        _cmd_field(d, "build", required=False)
        _cmd_field(d, "start")
        _port_field(d, "container_port")
    else:                                   # script
        _cmd_field(d, "cmd")
    _port_field(d, "port", required=(m != "script"))
    hp = d.get("health_path")
    if hp is None:
        if m != "script":
            raise AppError("bad health_path %r" % (hp,))
    elif not isinstance(hp, str) or not HEALTH_RE.match(hp):
        raise AppError("bad health_path %r" % (hp,))
    vol = d.get("volume")
    if vol is not None and (not isinstance(vol, str) or not VOLUME_RE.match(vol)
                            or "/../" in vol + "/"):
        raise AppError("bad volume %r" % (vol,))
    names = d.get("env_names")
    if names is not None and (not isinstance(names, list) or len(names) > 100
                              or not all(isinstance(n, str) and ENV_NAME_RE.match(n)
                                         for n in names)):
        raise AppError("bad env_names %r" % (names,))
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
    has never run here. Decoded exactly like deployd's own load_env(): the
    value is shlex-split, so setup.sh's %q-escaped paths
    (SERVICE_HOME=/home/u/deploy\\ state) come back real."""
    home = DEPLOYD_HOME
    try:
        with open(DEPLOYD_ENV, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, raw = line.partition("=")
                if name.strip() != "SERVICE_HOME":
                    continue
                try:
                    parts = shlex.split(raw)
                    value = parts[0] if parts else ""
                except ValueError:
                    value = raw
                home = value or DEPLOYD_HOME
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
    commit the launcher just deployed. Like deployd's own success path, this
    drops any state/<key>.fail: a failure record left beside a matching sha
    would show the app as failed forever, since deployd never reruns it."""
    state = deployd_state_dir()
    if not state:
        return
    try:
        os.remove(os.path.join(state, key + ".fail"))
    except OSError:
        pass
    tmp = os.path.join(state, ".%s.sha.tmp" % key)
    with open(tmp, "w") as fh:
        fh.write(sha + "\n")
    os.replace(tmp, os.path.join(state, key + ".sha"))


def clone_url(repo):
    return "https://github.com/%s.git" % repo


# ------------------------------------------------------------------ argv

def build_argv(d, sha, src, dockerfile=None, context=None):
    """`docker build` for the app's own image. dockerfile/context default to
    the definition's; node/python pass their generated Dockerfile instead."""
    ctx = os.path.normpath(os.path.join(src, context or d.get("context") or "."))
    df = dockerfile or d["dockerfile"]
    return ["docker", "build",
            "--tag", "%s:%s" % (image_repo(d["key"]), sha[:12]),
            "--file", os.path.normpath(os.path.join(src, df)),
            "--label", "setup-server.app=%s" % d["key"],
            "--label", "org.opencontainers.image.revision=%s" % sha,
            "--label", "org.opencontainers.image.source=https://github.com/%s" % d["repo"],
            ctx]


def run_argv(d, image, container_port=None, mounts=(), env_file=True):
    """`docker run` for the app. 127.0.0.1 only, restart unless-stopped (a
    stopped app stays stopped across reboots, the same policy as the compose
    services). `mounts` are extra host:container[:opts] bind specs (static's
    read-only docroot). `env_file=False` leaves the app's .env out: static's
    nginx only serves files, and the .env there holds build-time secrets
    (a passphrase baked into the output) it must not carry."""
    key = d["key"]
    inner = container_port or d["container_port"]
    argv = ["docker", "run", "--detach",
            "--name", container_name(key),
            "--restart", "unless-stopped",
            "--publish", "127.0.0.1:%d:%d" % (d["port"], inner),
            "--label", "setup-server.app=%s" % key]
    env_path = os.path.join(app_dir(key), ".env")
    if env_file and os.path.isfile(env_path):
        argv += ["--env-file", env_path]
    if d.get("volume"):
        argv += ["--volume", "%s:%s" % (os.path.join(app_dir(key), "data"), d["volume"])]
    for spec in mounts:
        argv += ["--volume", spec]
    return argv + [image]


def compose_argv(d, src, tail):
    """`docker compose` against the repo's file, as project app-<key> so its
    containers never collide with the single-container methods'. The app's
    .env passes as the project env file (same file --env-file would get)."""
    argv = ["docker", "compose",
            "--project-name", container_name(d["key"]),
            "--file", os.path.normpath(os.path.join(src, d["compose_file"]))]
    env_file = os.path.join(app_dir(d["key"]), ".env")
    if os.path.isfile(env_file):
        argv += ["--env-file", env_file]
    return argv + tail


def generated_dockerfile(d, src):
    """Render a node/python definition into a Dockerfile inside the checkout
    and return its repo-relative name. Untracked on purpose: `git clean`
    drops it after every checkout, so every deploy writes it fresh."""
    lines = ["FROM %s:%s" % (method_of(d), d["version"]),
             "WORKDIR /app",
             "COPY . ."]
    if d.get("build"):
        lines.append("RUN " + d["build"])
    lines.append("EXPOSE %d" % d["container_port"])
    lines.append('CMD ["sh", "-c", %s]' % json.dumps(d["start"]))
    path = os.path.join(src, GENERATED_DOCKERFILE)
    # O_NOFOLLOW: a repo may legitimately track a file of this name, and
    # `checkout --force` would restore a tracked symlink pointing at a host
    # file (../.env) that an ordinary write would truncate through the link.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                     | os.O_NOFOLLOW, 0o644)
    except OSError:
        raise AppError("%s in the checkout is not a regular file"
                       % GENERATED_DOCKERFILE)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return GENERATED_DOCKERFILE


# ------------------------------------------------------------------ helpers

def say(msg):
    print("==> " + msg, flush=True)


def run(argv, check=True, capture=False, cwd=None, env=None):
    """Run an argv (never a shell), echoing it to the job log first. Only
    the argv is echoed, never `env`: that is where host_env()'s values go,
    so no value can reach the log through here."""
    print("$ " + " ".join(argv), flush=True)
    res = subprocess.run(argv, cwd=cwd, env=env, text=True,
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


def deployd_sha():
    """$DEPLOY_SHA when deployd set a well-formed one, else None."""
    env_sha = os.environ.get("DEPLOY_SHA", "")
    return env_sha if SHA_RE.match(env_sha) else None


def resolve_sha(d):
    env_sha = deployd_sha()
    if env_sha:
        return env_sha
    code, out = quiet(["git", "ls-remote", clone_url(d["repo"]), d["ref"]])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and SHA_RE.match(parts[0]):
            return parts[0]
    raise AppError("could not resolve %s on %s (git ls-remote exited %d)"
                   % (d["ref"], d["repo"], code))


def fetch(d, sha, src, verify=False):
    """Bring `sha` into src/ without touching the working tree, so a
    refused commit changes nothing on disk that a deploy depends on.

    `verify` is for a sha deployd handed over ($DEPLOY_SHA): fetch the
    definition's ref first and require the sha to be on it (an ancestor of
    origin/<ref>, or its tip). Otherwise a sha the fetch could not bring
    down, or one from another branch, would deploy something deployd did
    not ask for while it records the request as done. Raising instead makes
    deployd's fail/backoff retry, the same as services/kaichenpedia/deploy.sh."""
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        run(["git", "clone", "--no-checkout", "--filter=blob:none",
             clone_url(d["repo"]), src])
    # A key can be deleted and re-created for another repo while src/ stays:
    # origin always follows the current definition.
    run(["git", "-C", src, "remote", "set-url", "origin", clone_url(d["repo"])])
    if not verify:
        run(["git", "-C", src, "fetch", "--quiet", "origin", sha])
        return
    # REF_RE allows neither `+` nor `:`, so the ref cannot reshape the
    # refspec. Everything reachable from the ref comes down with it, so a
    # sha that passes the check below needs no fetch of its own.
    tracking = "refs/remotes/origin/" + d["ref"]
    run(["git", "-C", src, "fetch", "--quiet", "origin",
         "+%s:%s" % (d["ref"], tracking)])
    code, _ = quiet(["git", "-C", src, "merge-base", "--is-ancestor",
                     sha, tracking])
    if code != 0:
        _, tip = quiet(["git", "-C", src, "rev-parse", "--verify", "--quiet",
                        tracking + "^{commit}"])
        raise AppError("deployd asked for %s but origin/%s is at %s (fetch "
                       "failed or diverged); failing so it retries"
                       % (sha, d["ref"], tip.strip() or "nothing"))


def check_out(sha, src):
    """Point the working tree at a fetched sha: detached, forced, and
    cleaned, so nothing a previous deploy left behind survives."""
    run(["git", "-C", src, "checkout", "--quiet", "--force", "--detach", sha])
    run(["git", "-C", src, "clean", "-ffdxq"])


def checkout(d, sha, src, verify=False):
    fetch(d, sha, src, verify=verify)
    check_out(sha, src)


def current_image(key):
    """The image ID (sha256:...) the app's container runs, or None. The ID,
    not the tag: a redeploy of the same commit rebuilds the same tag, and
    only the ID still names the image that was working."""
    code, out = quiet(["docker", "inspect", "--format", "{{.Image}}",
                       container_name(key)])
    out = out.strip()
    return out if code == 0 and out.startswith("sha256:") else None


def deployed_record(key):
    """The last successful deploy's deployed.json as a dict, or None."""
    try:
        with open(os.path.join(app_dir(key), "deployed.json"),
                  encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) else None


def record_sha(rec):
    """A deployed.json's sha when it is well-formed, else None."""
    sha = (rec or {}).get("sha")
    return sha if isinstance(sha, str) and SHA_RE.match(sha) else None


def deployed_sha(key):
    """The sha the last successful deploy recorded, or None: the rollback
    target for the methods with no spare image ID to fall back to."""
    return record_sha(deployed_record(key))


def recorded_method(rec):
    """The method a deployed.json says is running. A record written before
    methods existed carries none, and every app was dockerfile then."""
    m = rec.get("method")
    return m if m in METHODS else "dockerfile"


def recorded_definition(key, rec):
    """The definition a deployed.json says was deployed, re-validated (its
    words reach argvs again), or None: a record from before `definition`
    was written, or one that no longer passes validate()."""
    d = rec.get("definition")
    if not isinstance(d, dict):
        return None
    try:
        d = validate(dict(d))
    except AppError:
        return None
    return d if d["key"] == key else None


def inside_checkout(d, src, field):
    """The real path of a repo input (dockerfile, compose_file, output).
    It must resolve INSIDE the checkout: a tracked symlink could otherwise
    turn a build input into a read or bind-mount of a host file."""
    rel = d[field]
    root = os.path.realpath(src)
    real = os.path.realpath(os.path.join(root, rel))
    if real != root and not real.startswith(root + os.sep):
        raise AppError("%s %r escapes the checkout" % (field, rel))
    return real


def env_file_entries(path, base):
    """[(name, value)] from an app's .env, read the way `docker run
    --env-file` reads it, since the same file feeds that flag: a leading
    UTF-8 BOM and each line's leading whitespace dropped, blank and `#`
    lines skipped, `KEY=VALUE` split at the first `=` with the value kept
    literally (quotes, spaces and `$` included, no expansion), and a bare
    `KEY` taking KEY from `base` (the runner's env) when it is set there.
    Stricter than Docker in one way: a line whose name fails ENV_NAME_RE,
    or that is not UTF-8 or holds a NUL, is skipped with a warning naming
    only its line number, since the rest of the line may be a value.
    No file is an empty list."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return []
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    out = []
    # Split on \n only and drop one trailing \r, as Go's bufio.ScanLines.
    for num, chunk in enumerate(raw.split(b"\n"), 1):
        if chunk.endswith(b"\r"):
            chunk = chunk[:-1]
        try:
            line = chunk.decode("utf-8").lstrip()
        except UnicodeDecodeError:
            line = None
        if line is not None and (not line or line.startswith("#")):
            continue
        name, has_value, value = (line or "").partition("=")
        if line is None or "\0" in line or not ENV_NAME_RE.match(name):
            say("skipping line %d of %s: not NAME=value with a valid name"
                % (num, path))
            continue
        if has_value:
            out.append((name, value))
        elif name in base:
            out.append((name, base[name]))
    return out


def host_path(path):
    """The runner's PATH with HOST_PATH_DIRS that exist in front of it,
    each directory once (first place wins) and empty entries dropped."""
    dirs = [os.path.expanduser(p) for p in HOST_PATH_DIRS]
    seen, parts = set(), []
    for p in [p for p in dirs if os.path.isdir(p)] + path.split(os.pathsep):
        if p and p not in seen:
            seen.add(p)
            parts.append(p)
    return os.pathsep.join(parts)


def host_env(key):
    """The environment for a definition's host-run command: the runner's
    own, overlaid with ~/services/apps/<key>/.env (env_file_entries), with
    PATH from host_path(). A PATH in .env is ignored here, because the same
    file goes into containers, where it does what the app wants; one log
    line says so, without the value. Values only ever go into the child's
    environment, never an argv, so the echoed argv holds none."""
    base = dict(os.environ)
    env = dict(base)
    ignored_path = False
    for name, value in env_file_entries(os.path.join(app_dir(key), ".env"),
                                        base):
        if name == "PATH":
            ignored_path = True
            continue
        env[name] = value
    if ignored_path:
        say("PATH in .env is ignored for host commands (containers still get it)")
    env["PATH"] = host_path(base.get("PATH") or os.defpath)
    return env


def run_sh(command, cwd, key):
    """A definition's shell command, run `sh -c` inside the checkout on the
    host, with host_env(key). The only place a definition's words go
    through a shell."""
    run(["sh", "-c", command], cwd=cwd, env=host_env(key))


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

def swap(d, image, previous, previous_run_kw=None, **run_kw):
    """Replace the running container with `image`. If the new one cannot
    start or does not answer in time, put `previous` (an image ID) back and
    fail: the box is never left without the version that was working.
    `previous_run_kw` overrides run_kw for the rollback run, for methods
    whose mounts differ per release (static)."""
    key = d["key"]
    quiet(["docker", "rm", "--force", container_name(key)])
    say("starting %s on 127.0.0.1:%d" % (container_name(key), d["port"]))
    try:
        run(run_argv(d, image, **run_kw))
        if not healthy(d, HEALTH_WAIT):
            run(["docker", "logs", "--tail", "40", container_name(key)], check=False)
            raise AppError("http://127.0.0.1:%d%s did not answer within %ds"
                           % (d["port"], d["health_path"], HEALTH_WAIT))
    except AppError:
        quiet(["docker", "rm", "--force", container_name(key)])
        if previous:
            say("rolling back to the image that was running (%s)" % previous[:19])
            kw = run_kw if previous_run_kw is None else previous_run_kw
            run(run_argv(d, previous, **kw), check=False)
        raise


def deploy_compose(d, src, prev_sha):
    """`docker compose up -d` on the repo's file. There is no image ID to
    roll back to (compose replaced its containers in place), so a failed
    health check re-checks-out the last deployed sha and `up -d`s it: the
    stack returns to the compose file that was working."""
    path = inside_checkout(d, src, "compose_file")
    if not os.path.isfile(path):
        raise AppError("no %s in %s" % (d["compose_file"], d["repo"]))
    # A previous method's single container may still hold the port; compose
    # names its own app-<key>-<service>-N and never reclaims it.
    quiet(["docker", "rm", "--force", container_name(d["key"])])
    # --build: a `build:` service must not keep serving the previous commit's
    # image. --remove-orphans: a renamed service must not keep its port.
    up = ["up", "--detach", "--build", "--remove-orphans"]
    say("docker compose up -d (%s)" % d["compose_file"])
    try:
        run(compose_argv(d, src, up))
        if not healthy(d, HEALTH_WAIT):
            logs = ["logs", "--tail", "40"]
            if d.get("service"):
                logs.append(d["service"])
            run(compose_argv(d, src, logs), check=False)
            raise AppError("http://127.0.0.1:%d%s did not answer within %ds"
                           % (d["port"], d["health_path"], HEALTH_WAIT))
    except AppError:
        if prev_sha:
            say("restoring the compose stack at %s" % prev_sha[:12])
            checkout(d, prev_sha, src)
            run(compose_argv(d, src, up), check=False)
        raise


RELEASE_RE = re.compile(r"^site-[0-9a-f]{12}-[0-9]{1,20}$")


def new_release_name(key, sha):
    """site-<sha12>-<ms>: one name per BUILD, not per commit, so redeploying
    the same commit never reuses (and so never deletes) the live release."""
    stamp = int(time.time() * 1000)
    while True:
        name = "site-%s-%d" % (sha[:12], stamp)
        if not os.path.exists(os.path.join(app_dir(key), name)):
            return name
        stamp += 1


def release_dir(key, name):
    """~/services/apps/<key>/<name>: one static build's output, staged
    OUTSIDE the checkout so the next deploy's `git clean -ffdxq` cannot
    delete the site the running container still serves."""
    return os.path.join(app_dir(key), name)


def deployed_release(key):
    """The release dir name the last successful static deploy recorded, or
    None: the rollback mount, and the one prune must never drop."""
    try:
        with open(os.path.join(app_dir(key), "deployed.json"),
                  encoding="utf-8") as fh:
            name = json.load(fh).get("release")
    except (OSError, ValueError, AttributeError):
        return None
    if isinstance(name, str) and RELEASE_RE.match(name) \
            and os.path.isdir(release_dir(key, name)):
        return name
    return None


def prune_releases(key, keep_names):
    """Drop static releases that are neither current nor the rollback one."""
    keep = {n for n in keep_names if n}
    try:
        names = os.listdir(app_dir(key))
    except OSError:
        return
    for name in names:
        if name.startswith("site-") and name not in keep:
            shutil.rmtree(os.path.join(app_dir(key), name), ignore_errors=True)


def deploy_static(d, src, sha, previous, prev_release):
    """Run the def's build in the checkout, copy its output to a fresh
    release dir outside it, then serve that read-only from the small nginx
    image. Returns the release name. The live release is never touched: a
    failed build, pull or swap drops only the new release, and a failed swap
    rolls back to the previous release dir, not just its image."""
    key = d["key"]
    run_sh(d["build"], src, key)
    out_dir = inside_checkout(d, src, "output")
    if not os.path.isdir(out_dir):
        raise AppError("the build produced no %s directory" % d["output"])
    name = new_release_name(key, sha)
    release = release_dir(key, name)
    tmp = release + ".tmp"
    try:
        # symlinks=True: a link inside the output is copied as a link and
        # then resolves inside the container's filesystem; dereferencing it
        # here would copy whatever HOST path it pointed at into the release.
        shutil.copytree(out_dir, tmp, symlinks=True)
        os.replace(tmp, release)
        run(["docker", "pull", STATIC_IMAGE])
        say("serving %s from %s on 127.0.0.1:%d"
            % (d["output"], STATIC_IMAGE, d["port"]))
        # The rollback run mounts the PREVIOUS release: rolling back to the
        # old image over this deploy's release would serve the failed content.
        # With no recorded release there is nothing to mount: rolling the
        # old image back over THIS release would serve content that is
        # about to be deleted, so no container rollback then.
        prev_kw = None
        if prev_release:
            prev_kw = {"container_port": STATIC_CONTAINER_PORT,
                       "env_file": False,
                       "mounts": [release_dir(key, prev_release) + ":"
                                  + STATIC_DOCROOT + ":ro"]}
        else:
            previous = None
        swap(d, STATIC_IMAGE, previous, previous_run_kw=prev_kw,
             container_port=STATIC_CONTAINER_PORT, env_file=False,
             mounts=[release + ":" + STATIC_DOCROOT + ":ro"])
    except (AppError, OSError):
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(release, ignore_errors=True)
        raise
    return name


# ------------------------------------------------------------------ switches

def compose_file_path(d, src):
    """The compose file a definition names, when it is in the checkout and
    resolves inside it; None otherwise (an escaping link cannot drive
    `down` or `up`)."""
    try:
        path = inside_checkout(d, src, "compose_file")
    except AppError:
        return None
    return path if os.path.isfile(path) else None


def compose_project_containers(key):
    """Every container of compose project app-<key>, found by the label
    compose puts on them, so no compose file is needed."""
    code, out = quiet(["docker", "ps", "--all",
                       "--filter", "label=com.docker.compose.project=%s"
                                    % container_name(key),
                       "--format", "{{.Names}}"])
    return sorted(out.split()) if code == 0 else []


def try_run(argv):
    """An optional step: echoed and run like any other, but a failure is
    noted in the log and never raised (a container already gone is fine)."""
    res = run(argv, check=False)
    if res.returncode != 0:
        say("%s exited %d; continuing" % (" ".join(argv[:3]), res.returncode))
    return res.returncode == 0


def switch_steps(key, prev, now):
    """(before, after, restore) callables for a method change the new
    method cannot make by itself, or None when there is nothing to do:
    nothing deployed, the same method, or a container method replaced by
    another (swap() removes app-<key> itself).

    `before` stops the old method's runtime ahead of the deploy, `after`
    (success only) clears what it left, and `restore` (failure only) clears
    whatever the new method started and brings the old runtime back, so the
    box keeps the version that was working. Every step prints a `==>` line
    for the job log. A script's own processes are its own business: leaving
    `script` stops nothing."""
    if not prev:
        return None
    was = recorded_method(prev)
    if was == now:
        return None
    name = container_name(key)
    src = os.path.join(app_dir(key), "src")

    def nothing():
        pass

    if was == "script":
        def note():
            say("method change script -> %s: a script's own processes are not "
                "managed here, so nothing is stopped" % now)
        return note, nothing, nothing

    if was == "compose":
        old = recorded_definition(key, prev)
        if old is not None and method_of(old) != "compose":
            old = None
        old_sha = record_sha(prev)

        def stop_stack():
            say("method change compose -> %s: taking the old compose stack "
                "down first" % now)
            # src/ is still at the old sha here: deploy() calls this before
            # its checkout.
            path = compose_file_path(old, src) if old else None
            if path:
                run(compose_argv(old, src, ["down"]))
                return
            say("%s: stopping project %s by its label"
                % ("the old compose file is gone" if old else
                   "deployed.json predates `definition`", name))
            names = compose_project_containers(key)
            if names:
                run(["docker", "rm", "--force"] + names)

        def restore_stack():
            say("the deploy failed: removing what %s started and bringing "
                "the old compose stack back" % now)
            try_run(["docker", "rm", "--force", name])
            if old is None or old_sha is None:
                say("the old compose file is not recorded (deployed.json "
                    "predates `definition`); not restoring the old stack")
                return
            try:
                # The failed deploy checked out the new sha; the old file
                # lives at the old one, which src/ already holds (it ran
                # from there). No fetch: when the switch also moved repos,
                # the old remote may be gone and the stack must still
                # come back. Fetch only if the commit really is missing.
                try:
                    check_out(old_sha, src)
                except AppError:
                    checkout(old, old_sha, src)
                if not compose_file_path(old, src):
                    raise AppError("no %s at %s" % (old["compose_file"],
                                                    old_sha[:12]))
                run(compose_argv(old, src, ["up", "--detach"]), check=False)
            except AppError as exc:
                say("the old compose stack was not restored: %s" % exc)
        return stop_stack, nothing, restore_stack

    if was not in CONTAINER_METHODS:
        return None
    if now == "script":
        def stop():
            say("method change %s -> script: stopping %s first (a script "
                "does not replace it)" % (was, name))
            try_run(["docker", "stop", name])

        def start():
            say("the deploy failed: starting %s again" % name)
            try_run(["docker", "start", name])
        return stop, nothing, start
    if now == "compose":
        # deploy_compose force-removes app-<key> before `up`, so park the
        # container under another name (stopped, so the port is free) and
        # put it back if the stack does not come up. KEY_RE allows no dot,
        # so "<name>.parked" can never be another app's container, nor a
        # compose one (compose names its containers with dashes).
        parked = name + ".parked"

        def park():
            say("method change %s -> compose: parking %s as %s until the "
                "stack is up" % (was, name, parked))
            code, out = quiet(["docker", "ps", "--all",
                               "--filter", "name=^/%s" % name,
                               "--format", "{{.Names}}"])
            names = set(out.split()) if code == 0 else set()
            if parked in names and name not in names:
                # An earlier switch was killed (a deployd timeout) before
                # it could put the container back: the parked one is still
                # the working version, and the deployed.json that brought
                # us here still says so. Keep it.
                say("%s is still parked from an interrupted switch; keeping "
                    "it" % parked)
                try_run(["docker", "stop", parked])
                return
            if parked in names:
                # A live app-<key> exists too, so this one is stale.
                try_run(["docker", "rm", "--force", parked])
            try_run(["docker", "rename", name, parked])
            try_run(["docker", "stop", parked])

        def drop():
            say("the compose stack is up: removing the parked %s" % parked)
            try_run(["docker", "rm", "--force", parked])

        def unpark():
            say("the deploy failed: clearing compose project %s and putting "
                "%s back" % (name, name))
            names = compose_project_containers(key)
            if names:
                try_run(["docker", "rm", "--force"] + names)
            try_run(["docker", "rename", parked, name])
            try_run(["docker", "start", name])
        return park, drop, unpark
    return None


def deploy_method(d, m, sha, src, prev):
    """Run method `m` for definition `d` at `sha`, checked out in src/.
    Returns (image, release, prev_release) for the record."""
    key = d["key"]
    # Taken BEFORE the build/pull: rebuilding the same commit moves the
    # tag, and the ID is then the only name left for the working image.
    previous = current_image(key)
    prev_release = deployed_release(key)
    image = release = None
    if m == "script":
        run_sh(d["cmd"], src, key)
        if d.get("port") and d.get("health_path") \
                and not healthy(d, HEALTH_WAIT):
            raise AppError("http://127.0.0.1:%d%s did not answer within %ds"
                           % (d["port"], d["health_path"], HEALTH_WAIT))
    elif m == "compose":
        # Only an earlier compose stack is something to roll back to: the
        # sha of another method's deploy holds no stack (switch_steps puts
        # that method's runtime back instead).
        was_compose = prev is not None and recorded_method(prev) == "compose"
        deploy_compose(d, src, record_sha(prev) if was_compose else None)
    elif m == "image":
        image = d["image"]
        say("pulling %s" % image)
        run(["docker", "pull", image])
        swap(d, image, previous)
    elif m == "static":
        release = deploy_static(d, src, sha, previous, prev_release)
        image = STATIC_IMAGE
    elif m in ("node", "python"):
        generated_dockerfile(d, src)
        image = "%s:%s" % (image_repo(key), sha[:12])
        say("building %s (generated %s)" % (image, GENERATED_DOCKERFILE))
        run(build_argv(d, sha, src, dockerfile=GENERATED_DOCKERFILE,
                       context="."))
        swap(d, image, previous)
    else:
        df_path = inside_checkout(d, src, "dockerfile")
        if not os.path.isfile(df_path):
            raise AppError("no %s in %s at %s"
                           % (d["dockerfile"], d["repo"], sha[:12]))
        image = "%s:%s" % (image_repo(key), sha[:12])
        say("building %s" % image)
        run(build_argv(d, sha, src))
        swap(d, image, previous)
    return image, release, prev_release


def deploy(key):
    load(key)                 # fail fast on a bad key or missing definition
    with Lock(key):
        d = load(key)         # re-read under the lock: a delete may have won
        m = method_of(d)
        sha = resolve_sha(d)
        say("deploying %s at %s (%s, %s method)"
            % (d["repo"], sha[:12], d["ref"], m))
        src = os.path.join(app_dir(key), "src")
        # Fetch, but leave the working tree alone: a refused $DEPLOY_SHA
        # stops here with nothing stopped, and a compose stack being left
        # can still be taken down with the file it was started from.
        fetch(d, sha, src, verify=deployd_sha() is not None)
        prev = deployed_record(key)
        steps = switch_steps(key, prev, m)
        try:
            if steps:
                steps[0]()
            check_out(sha, src)
            if d.get("volume") and m in CONTAINER_METHODS:
                os.makedirs(os.path.join(app_dir(key), "data"), exist_ok=True)
            image, release, prev_release = deploy_method(d, m, sha, src, prev)
            if m != "script":     # a script manages its own Serve routes
                publish(d)
            # `definition` is what the next deploy stops this runtime by
            # when the method changes; a definition holds env_names only.
            record = {"sha": sha, "image": image, "method": m, "ref": d["ref"],
                      "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "definition": d}
            if release:
                record["release"] = release
            tmp = os.path.join(app_dir(key), "deployed.json.tmp")
            with open(tmp, "w") as fh:
                json.dump(record, fh)
            os.replace(tmp, os.path.join(app_dir(key), "deployed.json"))
        except Exception:
            if steps:
                try:
                    steps[2]()
                except Exception as exc:    # never mask the deploy's error
                    say("restoring the previous method failed: %s" % exc)
            raise
        if steps:
            steps[1]()
        if m == "static":
            prune_releases(key, (release, prev_release))
        prune_images(key, image)
        record_deployd_sha(key, sha)
        set_paused(key, False)    # a removed (or new) app resumes auto-deploy
        say("deployed %s at %s" % (key, sha[:12]))


def compose_down(d):
    """Stop the app's compose stack: `down` on the checked-out file when it
    is there, project-labelled containers by name when it is not (a checkout
    may predate the file's rename or removal)."""
    src = os.path.join(app_dir(d["key"]), "src")
    if compose_file_path(d, src):
        # --remove-orphans: services the file no longer lists must go too.
        run(compose_argv(d, src, ["down", "--remove-orphans"]))
        say("compose stack %s down" % container_name(d["key"]))
        return
    names = compose_project_containers(d["key"])
    if names:
        run(["docker", "rm", "--force"] + names)
        say("compose stack %s removed by project label" % container_name(d["key"]))
    else:
        say("no compose file or labelled stack for %s; nothing to stop" % d["key"])


def remove(key):
    """Drop the container (or compose stack) and this app's Serve port.
    Nothing changes until Docker answers and (where Tailscale is installed
    and the app has a port) Serve status reads; a container or route already
    gone is fine, but one that will not go fails the job and keeps
    deployed.json, so the app still shows installed."""
    d = load(key)
    name = container_name(key)
    m = method_of(d)
    port = d.get("port")        # only a script method may leave it unset
    with Lock(key):
        ts = tailscale_bin() if port is not None else None
        ports = serve_ports() if ts else {}
        if port is not None and ports is None:
            raise AppError("cannot read `tailscale serve status`; nothing was changed")
        code, out = quiet(["docker", "ps", "--all", "--filter", "name=^/%s$" % name,
                           "--format", "{{.Names}}"])
        if code != 0:
            raise AppError("docker is not answering; nothing was changed")
        if name in out.split():
            run(["docker", "rm", "--force", name])
            say("container %s removed" % name)
        else:
            say("container %s was already gone" % name)
        if m == "compose":
            compose_down(d)
        if port is not None:
            target = "http://127.0.0.1:%d" % port
            if ports.get(str(port)) == target:
                run([ts, "serve", "--https=%d" % port, "off"])
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
