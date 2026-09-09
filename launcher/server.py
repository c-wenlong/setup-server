#!/usr/bin/env python3
"""launcher — app launcher + one-tap deploy for kai-home-server.

Python 3 standard library only, on purpose: this is meant to be the first
thing that comes up on the box and the thing you reach for when something
else is broken, so it must have no moving parts (no pip, no venv, no
framework).

Serves web/ as static files and a small JSON API:

    GET  api/services            registry + derived state
    POST api/services/{key}/deploy
    GET  api/jobs/{id}
    GET  healthz

Paths arrive WITHOUT any mount prefix: `tailscale serve --set-path=/home`
strips `/home` before proxying, so the backend sees `/` and `/api/services`
at both published URLs. Routing therefore works on plain paths, and both
`api/services` and `/api/services` are accepted.

Run: python3 server.py     (env: LAUNCHER_PORT, REPO_ROOT)
"""

import grp
import http.server
import json
import mimetypes
import os
import shlex
import socket
import socketserver
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid

# ------------------------------------------------------------------ config

HERE = os.path.dirname(os.path.abspath(__file__))

PORT = int(os.environ.get("LAUNCHER_PORT", "8093"))
BIND = "127.0.0.1"  # tailnet is the security boundary; never 0.0.0.0

# Repo root defaults to the parent of launcher/, so the checkout can live
# anywhere without editing this file.
REPO_ROOT = os.path.realpath(os.environ.get("REPO_ROOT", os.path.dirname(HERE)))

WEB_DIR = os.path.join(HERE, "web")
REGISTRY_PATH = os.path.join(HERE, "services.json")
JOBS_DIR = os.path.expanduser("~/services/launcher/jobs")

# Deploy scripts may only live under one of these roots. The repo is the
# normal case; ~/dev is needed because some services keep their code in
# their own repo (manimkc lives at ~/dev/manimkc/server/setup.sh) while
# still being deployable from here. Anything resolving outside this list is
# refused, which is what makes a hand-edited or malicious registry entry
# unable to turn this endpoint into arbitrary code execution.
ALLOWED_ROOTS = [REPO_ROOT, os.path.realpath(os.path.expanduser("~/dev"))]

PROBE_TIMEOUT = 2.0  # seconds; loopback, so anything slower is "down"
PROBE_TTL = 5.0      # cache probes so a page refresh can't stampede
MAX_JOBS = 2         # global concurrent deploys
LOG_TAIL_BYTES = 64 * 1024

# How long a finished (done/failed) job keeps being reported on its tile by
# api/services. Long enough that you can lock your phone mid-deploy, come
# back, and still be told how it ended; short enough that yesterday's failure
# is not still shouting at you. Running jobs are always reported, regardless.
JOB_LINGER = 600.0
# How long a finished job stays fetchable via api/jobs/{id} before being
# dropped from the registry. Deliberately much longer than JOB_LINGER so a
# sheet that is open on a finished job never has its log yanked away.
JOB_RETENTION = 3600.0
# Hard ceiling on remembered finished jobs, so a pathological retry loop
# cannot grow the registry without bound between prunes.
MAX_JOB_HISTORY = 50


def log(msg):
    print("[launcher] %s" % msg, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ registry

_registry_cache = {"mtime": None, "data": None}


def load_registry():
    """Read services.json, re-reading only when the file changes on disk."""
    try:
        mtime = os.path.getmtime(REGISTRY_PATH)
    except OSError as exc:
        log("registry unreadable: %s" % exc)
        return []
    if _registry_cache["mtime"] != mtime:
        with open(REGISTRY_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        _registry_cache["mtime"] = mtime
        _registry_cache["data"] = doc.get("services", [])
    return _registry_cache["data"]


def find_service(key):
    for svc in load_registry():
        if svc.get("key") == key:
            return svc
    return None


# ------------------------------------------------------------------ host

_host_cache = {"value": None}


def magicdns_host():
    """This node's MagicDNS name, for substituting HOST in registry urls.

    Asking tailscaled keeps the registry tailnet-agnostic. If tailscale is
    missing or down the launcher must still render (that is precisely when
    you need it), so fall back to the plain hostname.
    """
    if _host_cache["value"]:
        return _host_cache["value"]
    host = None
    try:
        out = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if out.returncode == 0:
            name = json.loads(out.stdout).get("Self", {}).get("DNSName", "")
            host = name.rstrip(".") or None
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log("tailscale status failed (%s); falling back to hostname" % exc)
    if not host:
        host = socket.gethostname()
    _host_cache["value"] = host
    return host


def substitute_host(url, host):
    """Replace the literal token HOST in a registry url."""
    if not url:
        return None
    return url.replace("HOST", host)


# ------------------------------------------------------------------ probes

_probe_cache = {}          # url -> (checked_at, ok)
_probe_lock = threading.Lock()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Don't follow redirects: a 3xx already proves something is listening,
    and following it can wander off the loopback endpoint we meant to test."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def probe(url):
    """True if the endpoint answers 2xx or 3xx within PROBE_TIMEOUT."""
    try:
        with _opener.open(url, timeout=PROBE_TIMEOUT) as resp:
            return 200 <= resp.status < 400
    except urllib.error.HTTPError as exc:
        # A 3xx surfaces here because redirects are disabled above.
        return 200 <= exc.code < 400
    except Exception:
        return False


def probe_all(urls):
    """Probe every url concurrently, honouring the ~5s cache."""
    now = time.time()
    results = {}
    stale = []
    with _probe_lock:
        for url in urls:
            hit = _probe_cache.get(url)
            if hit and now - hit[0] < PROBE_TTL:
                results[url] = hit[1]
            else:
                stale.append(url)

    if stale:
        fresh = {}
        threads = []

        def run(u):
            fresh[u] = probe(u)

        for url in stale:
            t = threading.Thread(target=run, args=(url,), daemon=True)
            t.start()
            threads.append(t)
        # Slightly more than the probe timeout so a wedged socket can't pin
        # the request thread forever.
        for t in threads:
            t.join(timeout=PROBE_TIMEOUT + 1.0)
        done = time.time()
        with _probe_lock:
            for url in stale:
                ok = fresh.get(url, False)
                _probe_cache[url] = (done, ok)
                results[url] = ok
    return results


def marker_exists(marker):
    return bool(marker) and os.path.exists(os.path.expanduser(marker))


def derive_state(setup, installed, active):
    """Map (setup, installed, active) onto the four tile states.

    Deliberate ordering note: the spec's table says `planned` means "no
    setup in repo", but it also requires ollama — which has no setup.sh here
    and yet answers on :11434 — to show live status rather than look
    unbuilt. Evidence of being deployed therefore wins over the absence of a
    setup script: `planned` only applies when nothing is installed or
    answering. Every other row of the table is unchanged.
    """
    if active:
        return "active"
    if installed:
        return "stopped"
    if not setup:
        return "planned"
    return "available"


def services_payload():
    host = magicdns_host()
    registry = load_registry()
    health_urls = [s["health"] for s in registry if s.get("health")]
    probes = probe_all(health_urls)
    # One in-memory pass over the job registry for the whole payload; see
    # jobs_by_key() for why this stays cheap enough to poll every 30s.
    jobs = jobs_by_key()

    services = []
    for svc in registry:
        health = svc.get("health")
        active = bool(health) and probes.get(health, False)
        installed = active or marker_exists(svc.get("marker"))
        services.append({
            "key": svc.get("key"),
            "name": svc.get("name"),
            "tagline": svc.get("tagline"),
            "icon": svc.get("icon"),
            "url": substitute_host(svc.get("url"), host),
            "state": derive_state(svc.get("setup"), installed, active),
            "installed": installed,
            "active": active,
            # Lets a reopened tile reattach to a deploy it started earlier
            # instead of POSTing a fresh one and getting a 409 it can do
            # nothing with. null when there is nothing to reattach to.
            "job": jobs.get(svc.get("key")),
        })
    return {"host": host, "services": services}


# ------------------------------------------------------------------ deploy

# job_id -> job dict. Process-local and deliberately not persisted: after a
# restart there are no child processes left to attach to, so an empty
# registry is the truthful answer and every tile correctly reports job null
# rather than pointing the UI at a job whose process is gone. The log files
# under JOBS_DIR survive, but nothing ever enumerates them.
_jobs = {}
_jobs_lock = threading.Lock()


def _prune_jobs(now):
    """Drop finished jobs nobody can still be watching. Caller holds the lock.

    Running jobs are never evicted. This is what keeps _jobs bounded over a
    long-lived process: without it the registry would grow by one dict per
    deploy forever.
    """
    for job in list(_jobs.values()):
        if job["status"] == "running":
            continue
        if now - (job.get("finished") or job["started"]) > JOB_RETENTION:
            _jobs.pop(job["id"], None)
    finished = sorted(
        (j for j in _jobs.values() if j["status"] != "running"),
        key=lambda j: j.get("finished") or j["started"])
    for job in finished[:max(0, len(finished) - MAX_JOB_HISTORY)]:
        _jobs.pop(job["id"], None)


def jobs_by_key(now=None):
    """key -> {"id", "status"} for the job worth showing on that tile.

    Reports the running job for a key if there is one, otherwise the most
    recently finished one while it is still within JOB_LINGER — so closing
    the sheet and reopening it can pick the deploy back up, and a deploy that
    ended while you were away still gets to report how it went.

    O(number of jobs), memory only: no filesystem access and no probing, so
    api/services stays cheap enough for every open tab to poll it.
    """
    now = time.time() if now is None else now
    with _jobs_lock:
        _prune_jobs(now)
        snapshot = [(j["id"], j["key"], j["status"], j["started"],
                     j.get("finished"))
                    for j in _jobs.values()]

    best = {}
    for job_id, key, status, started, finished in snapshot:
        if status == "running":
            # Running always outranks finished; ties (which shouldn't happen,
            # one job per key) break towards the newer one.
            rank = (1, started)
        else:
            when = finished or started
            if now - when > JOB_LINGER:
                continue
            rank = (0, when)
        if key not in best or rank > best[key][0]:
            best[key] = (rank, {"id": job_id, "status": status})
    return {key: entry for key, (_, entry) in best.items()}


class DeployError(Exception):
    """Refusal with an HTTP status the client is allowed to see."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def resolve_script(svc):
    """Registry setup path -> absolute script path, or raise DeployError.

    The path never comes from the request: only `key` does, and that is
    looked up in the registry first. This resolves and re-checks anyway so
    a bad registry edit (or a `..` in one) still cannot escape.
    """
    setup = svc.get("setup")
    if not setup:
        raise DeployError(400, "service has no setup script (planned)")
    if setup.startswith("~") or os.path.isabs(setup):
        candidate = os.path.expanduser(setup)
    else:
        candidate = os.path.join(REPO_ROOT, setup)
    path = os.path.realpath(candidate)
    for root in ALLOWED_ROOTS:
        # Compare on path components, not string prefixes: /home/kai/devil
        # must not pass a /home/kai/dev check.
        if path == root or path.startswith(root.rstrip(os.sep) + os.sep):
            break
    else:
        raise DeployError(403, "setup path is outside the allowed roots")
    if not os.path.isfile(path):
        raise DeployError(404, "setup script not found")
    return path


def _have_docker_group():
    try:
        return "docker" in {grp.getgrgid(g).gr_name for g in os.getgroups()}
    except Exception:
        return False


def build_command(script):
    """argv for running a deploy script, as a list — never a shell string.

    Deploy scripts drive docker, and a systemd *user* unit does not
    reliably pick up the docker group even when the user is in it, so the
    script would fail on a permission error that never appears in an
    interactive shell. `sg docker -c ...` re-enters with the group applied.
    sg takes a command *string*, which is the one place a string is built —
    from the registry-supplied script path only, shlex-quoted, with no
    request data anywhere near it. If sg is missing, or the group is already
    present, run the script directly with no shell at all.
    """
    if os.access(script, os.X_OK):
        direct = [script]
    else:
        direct = ["/bin/bash", script]
    if _have_docker_group():
        return direct
    sg = _which("sg")
    if not sg:
        return direct
    return [sg, "docker", "-c", " ".join(shlex.quote(a) for a in direct)]


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def start_deploy(key):
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    script = resolve_script(svc)

    job_id = uuid.uuid4().hex
    os.makedirs(JOBS_DIR, exist_ok=True)
    log_path = os.path.join(JOBS_DIR, "%s.log" % job_id)

    with _jobs_lock:
        running = [j for j in _jobs.values() if j["status"] == "running"]
        if any(j["key"] == key for j in running):
            raise DeployError(409, "a deploy is already running for %s" % key)
        if len(running) >= MAX_JOBS:
            raise DeployError(429, "too many deploys running (max %d)" % MAX_JOBS)
        job = {
            "id": job_id,
            "key": key,
            "status": "running",
            "exit_code": None,
            "log_path": log_path,
            "started": time.time(),
            "finished": None,
        }
        _jobs[job_id] = job

    argv = build_command(script)
    cwd = os.path.dirname(script)
    try:
        # Combined stdout+stderr straight into the job log: the UI polls the
        # file's contents rather than streaming, which survives a phone
        # locking its screen mid-deploy.
        logfile = open(log_path, "wb", buffering=0)
        logfile.write(("$ %s\n" % " ".join(argv)).encode())
        proc = subprocess.Popen(
            argv, cwd=cwd, stdout=logfile, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, shell=False,
        )
    except Exception as exc:
        with _jobs_lock:
            job["status"] = "failed"
            job["exit_code"] = -1
            job["finished"] = time.time()
        log("deploy %s (%s) failed to start: %s" % (job_id, key, exc))
        raise DeployError(500, "could not start deploy")

    log("deploy %s started: %s (cwd %s)" % (job_id, key, cwd))
    threading.Thread(target=_reap, args=(job, proc, logfile), daemon=True).start()
    return job_id


def _reap(job, proc, logfile):
    code = proc.wait()
    try:
        logfile.close()
    except Exception:
        pass
    with _jobs_lock:
        job["exit_code"] = code
        job["status"] = "done" if code == 0 else "failed"
        job["finished"] = time.time()
    log("deploy %s (%s) exited %d" % (job["id"], job["key"], code))


def job_payload(job_id):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is None:
            return None
        snapshot = dict(job)
    # The path comes from the job record, never from the request.
    text = ""
    try:
        with open(snapshot["log_path"], "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - LOG_TAIL_BYTES))
            text = fh.read().decode("utf-8", "replace")
    except OSError:
        pass
    return {
        "key": snapshot["key"],
        "status": snapshot["status"],
        "exit_code": snapshot["exit_code"],
        "log": text,
    }


# ------------------------------------------------------------------ http

def normalize(path):
    """Request path -> a clean relative path.

    Tailscale strips the /home prefix before proxying, so the backend
    normally sees plain paths; the extra `home/` strip is belt-and-braces in
    case the serve config is ever changed to forward the prefix.
    """
    path = path.split("?", 1)[0].split("#", 1)[0]
    path = urllib.parse.unquote(path)
    path = path.lstrip("/")
    if path == "home" or path.startswith("home/"):
        rest = path[5:]
        if rest.startswith("api/") or rest in ("healthz", ""):
            path = rest
    return path


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "launcher"
    protocol_version = "HTTP/1.1"

    # ---- plumbing

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    def _send(self, status, body, ctype, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj) + "\n",
                   "application/json; charset=utf-8",
                   {"Cache-Control": "no-store"})

    def _error(self, status, message):
        self._json(status, {"error": message})

    # ---- routing

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        try:
            path = normalize(self.path)
            if method == "GET":
                self._route_get(path)
            else:
                self._route_post(path)
        except DeployError as exc:
            self._error(exc.status, exc.message)
        except BrokenPipeError:
            pass
        except Exception:
            # Never leak a traceback to the client; stderr gets the detail.
            log("unhandled error on %s %s\n%s"
                % (method, self.path, traceback.format_exc()))
            try:
                self._error(500, "internal error")
            except Exception:
                pass

    def _route_get(self, path):
        if path == "healthz":
            self._send(200, "ok\n", "text/plain; charset=utf-8",
                       {"Cache-Control": "no-store"})
            return
        if path == "api/services":
            self._json(200, services_payload())
            return
        if path.startswith("api/jobs/"):
            job_id = path[len("api/jobs/"):].strip("/")
            payload = job_payload(job_id)
            if payload is None:
                self._error(404, "unknown job")
            else:
                self._json(200, payload)
            return
        if path.startswith("api/"):
            self._error(404, "unknown endpoint")
            return
        self._serve_static(path)

    def _route_post(self, path):
        # Read and discard/parse any body first so the connection stays sane.
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if raw.strip():
            try:
                json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._error(400, "malformed JSON body")
                return

        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "deploy":
            job_id = start_deploy(parts[2])
            self._json(202, {"job_id": job_id})
            return
        self._error(404, "unknown endpoint")

    # ---- static

    def _serve_static(self, path):
        if not os.path.isdir(WEB_DIR):
            # The frontend may not be written yet. Stay up and keep the API
            # usable rather than refusing to start.
            if path in ("", "index.html"):
                self._send(503, "launcher: web/ not built yet\n",
                           "text/plain; charset=utf-8")
            else:
                self._error(404, "not found")
            return

        rel = "index.html" if path in ("", "/") else path
        target = os.path.realpath(os.path.join(WEB_DIR, rel))
        root = os.path.realpath(WEB_DIR)
        if not (target == root or target.startswith(root + os.sep)):
            self._error(404, "not found")
            return
        if os.path.isdir(target):
            target = os.path.join(target, "index.html")
        if not os.path.isfile(target):
            self._error(404, "not found")
            return

        ctype, _ = mimetypes.guess_type(target)
        ctype = ctype or "application/octet-stream"
        if ctype.startswith("text/") or ctype in (
            "application/javascript", "application/json",
            "image/svg+xml", "application/manifest+json",
        ):
            ctype += "; charset=utf-8"
        try:
            with open(target, "rb") as fh:
                body = fh.read()
        except OSError:
            self._error(404, "not found")
            return
        # No caching: the whole point is that editing web/ is the deploy.
        self._send(200, body, ctype, {"Cache-Control": "no-cache"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("application/manifest+json", ".webmanifest")
    srv = Server((BIND, PORT), Handler)
    log("listening on http://%s:%d (repo %s, web %s)"
        % (BIND, PORT, REPO_ROOT, WEB_DIR if os.path.isdir(WEB_DIR) else "MISSING"))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
