#!/usr/bin/env python3
"""launcher — app launcher + one-tap deploy for kai-home-server.

Python 3 standard library only, on purpose: this is meant to be the first
thing that comes up on the box and the thing you reach for when something
else is broken, so it must have no moving parts (no pip, no venv, no
framework).

Serves web/ as static files and a small JSON API:

    GET    api/services            registry + derived state
    POST   api/services/{key}/deploy
    POST   api/services/{key}/action   {"action": start|stop|restart}
    GET    api/services/{key}      detail: identity, meta, env var NAMES
    PATCH  api/services/{key}      {name?, description?} -> overrides.json
    POST   api/services/{key}/env/{var}/reveal   one value, deliberately POST
    PATCH  api/services/{key}/env/{var}   {"value"} -> rewrites that line in .env
    POST   api/services/{key}/touch  {"event": launched|opened} -> usage.json
    GET    api/services/{key}/notes            newest-first
    POST   api/services/{key}/notes            {title?, body} -> 201
    PATCH  api/services/{key}/notes/{id}       {title?, body?}
    DELETE api/services/{key}/notes/{id}       204
    GET    api/jobs/{id}
    GET    healthz

Env values are never in a list or detail payload, not even masked: the
detail response carries names and a `secret` flag only, and revealing one
is a separate explicit POST that is never logged. Editing one rewrites
exactly that line of the .env file, leaving every other byte alone.

Paths arrive WITHOUT any mount prefix: `tailscale serve --set-path=/home`
strips `/home` before proxying, so the backend sees `/` and `/api/services`
at both published URLs. Routing therefore works on plain paths, and both
`api/services` and `/api/services` are accepted.

Run: python3 server.py     (env: LAUNCHER_PORT, REPO_ROOT)
"""

import datetime
import grp
import http.server
import json
import mimetypes
import os
import re
import shlex
import socket
import socketserver
import stat
import subprocess
import sys
import tempfile
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

# UI edits to a service's name/description land here, never in services.json:
# that file is tracked in git and is the shipped default. Deleting this file
# restores those defaults.
OVERRIDES_PATH = os.path.expanduser("~/services/launcher/overrides.json")

# Per-service developer notes, alongside overrides.json and for the same
# reason: this is user-authored content that is NOT in git, so it must never
# be written into services.json and must survive a redeploy of the repo.
NOTES_PATH = os.path.expanduser("~/services/launcher/notes.json")

# Last-launched / last-opened timestamps per service, which the grid sorts by
# out of the box. Beside overrides.json and for the same reasons: per-box
# state that is not in git, must survive a redeploy of the repo, and is reset
# by deleting the file.
USAGE_PATH = os.path.expanduser("~/services/launcher/usage.json")

# Deploy scripts may only live under one of these roots. The repo is the
# normal case; ~/dev is needed because some services keep their code in
# their own repo (manimkc lives at ~/dev/manimkc/server/setup.sh) while
# still being deployable from here. Anything resolving outside this list is
# refused, which is what makes a hand-edited or malicious registry entry
# unable to turn this endpoint into arbitrary code execution.
ALLOWED_ROOTS = [REPO_ROOT, os.path.realpath(os.path.expanduser("~/dev"))]

PROBE_TIMEOUT = 2.0  # seconds; loopback, so anything slower is "down"
PROBE_TTL = 5.0      # cache probes so a page refresh can't stampede
MAX_JOBS = 2         # global concurrent jobs (deploys and lifecycle actions)
LOG_TAIL_BYTES = 64 * 1024

# Resource use is read from cgroup v2 in sysfs, never from `docker stats`.
# The root is an env var so the tests can point it at a fixture tree instead
# of monkeypatching open().
CGROUP_ROOT = os.environ.get("LAUNCHER_CGROUP_ROOT", "/sys/fs/cgroup")
RESOURCE_TTL = 5.0     # same reasoning as PROBE_TTL: a grid full of tiles
                       # polling every 30s must not hammer sysfs
DOCKER_MAP_TTL = 10.0  # container name -> id; at most one docker call per 10s
DOCKER_MAP_TIMEOUT = 5.0

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

MAX_NAME = 60        # characters, after cleaning
MAX_DESCRIPTION = 2000
MAX_BODY_BYTES = 64 * 1024   # nothing this API accepts is anywhere near this

# A touch body is {"event": "launched"} and nothing else, so it is capped far
# below the global limit rather than at it.
MAX_TOUCH_BYTES = 1024

# One env value. The longest line in any .env on this box is under 100
# characters; a PEM key would be the only thing near this, and those are
# multi-line, which .env cannot hold anyway.
MAX_ENV_VALUE = 4096
TOUCH_EVENTS = ("launched", "opened")

# Notes. A title is one collapsed line because the UI shows notes collapsed to
# exactly that; a body is long enough for a paste of a compose fragment or a
# stack trace but not for a log file. The per-service cap exists so a stuck
# client cannot grow notes.json without bound — 100 notes about one service is
# already well past the point where this should have become a document.
MAX_NOTE_TITLE = 120
MAX_NOTE_BODY = 8000
MAX_NOTES_PER_SERVICE = 100


def log(msg):
    print("[launcher] %s" % msg, file=sys.stderr, flush=True)


class DeployError(Exception):
    """Refusal with an HTTP status the client is allowed to see.

    Named for the endpoint it was written for; every endpoint here raises it
    now, and the message is the only thing the client ever sees of a
    failure — details go to stderr.
    """

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ------------------------------------------------------------------ registry

_registry_cache = {"mtime": None, "data": None}


def load_document():
    """The whole of services.json, re-read only when it changes on disk."""
    try:
        mtime = os.path.getmtime(REGISTRY_PATH)
    except OSError as exc:
        log("registry unreadable: %s" % exc)
        return {}
    if _registry_cache["mtime"] != mtime:
        with open(REGISTRY_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        _registry_cache["mtime"] = mtime
        _registry_cache["data"] = doc if isinstance(doc, dict) else {}
    return _registry_cache["data"] or {}


def load_registry():
    """The `services` array of services.json."""
    services = load_document().get("services")
    return services if isinstance(services, list) else []


def load_control_config():
    """The file-level `control` block: where the Kuma helper and its env live.

    Paths only — the per-service control data lives on each service entry, so
    that ntfy-control and the launcher read one map, not two.
    """
    block = load_document().get("control")
    return block if isinstance(block, dict) else {}


def find_service(key):
    for svc in load_registry():
        if svc.get("key") == key:
            return svc
    return None


def resolve_registry_path(raw, label):
    """A path *from the registry* -> a realpath inside ALLOWED_ROOTS.

    The single gate shared by the deploy endpoint (setup.sh) and the env
    reader (.env). A request never supplies a path — only a `key`, which is
    looked up first — but this resolves and re-checks anyway, so a
    hand-edited or malicious registry entry (an absolute path, a `..`, a
    symlink pointing out of the tree) still cannot reach a file it should
    not. Weakening this weakens both endpoints at once.
    """
    if raw.startswith("~") or os.path.isabs(raw):
        candidate = os.path.expanduser(raw)
    else:
        candidate = os.path.join(REPO_ROOT, raw)
    path = os.path.realpath(candidate)
    for root in ALLOWED_ROOTS:
        # Compare on path components, not string prefixes: /home/kai/devil
        # must not pass a /home/kai/dev check.
        if path == root or path.startswith(root.rstrip(os.sep) + os.sep):
            return path
    raise DeployError(403, "%s path is outside the allowed roots" % label)


# ------------------------------------------------------------------ overrides

# UI edits (name, description) layered over the shipped registry. Kept in one
# small JSON file so "reset to defaults" is `rm overrides.json`, and so a
# redeploy of the repo never clobbers them.
_overrides_lock = threading.Lock()


def load_overrides():
    """key -> {"name"?, "description"?}. Never raises.

    Missing, corrupt, unreadable, or the wrong shape all degrade to "no
    overrides" — the launcher is the thing you reach for when other things
    are broken, so a bad edit to this file must not take the whole page
    down. Only string values for known fields survive.
    """
    try:
        with open(OVERRIDES_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        log("overrides unusable (%s); serving shipped defaults" % exc)
        return {}
    if not isinstance(doc, dict):
        log("overrides is not an object; serving shipped defaults")
        return {}
    services = doc.get("services")
    if not isinstance(services, dict):
        return {}
    clean = {}
    for key, entry in services.items():
        if not isinstance(key, str) or not isinstance(entry, dict):
            continue
        kept = {f: entry[f] for f in ("name", "description")
                if isinstance(entry.get(f), str)}
        if kept:
            clean[key] = kept
    return clean


def _write_json_atomically(path, doc, prefix):
    """Replace `path` with `doc`, atomically. Caller holds the relevant lock.

    The one write discipline every piece of user-authored state here uses
    (overrides.json, notes.json): a full temp file in the *same* directory,
    flushed and fsynced so the bytes are really on disk, then a single
    os.replace. A reader sees either the whole old file or the whole new one,
    never a half-written one, and a crash mid-write cannot lose the previous
    contents. The temp file is removed if any of that fails, so a full disk
    does not leave litter behind.
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=prefix, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _write_overrides(data):
    """Atomically replace overrides.json. Caller holds _overrides_lock."""
    _write_json_atomically(OVERRIDES_PATH, {"services": data}, ".overrides-")


def effective(svc, overrides=None):
    """(name, description) for a service: registry values, override on top."""
    if overrides is None:
        overrides = load_overrides()
    entry = overrides.get(svc.get("key")) or {}
    name = entry.get("name") or svc.get("name")
    description = entry.get("description")
    if description is None:
        description = svc.get("description") or ""
    return name, description


# ------------------------------------------------------------------ usage

# When each service was last launched (its tile opened the service in a tab)
# or opened (its detail page). The default sort order on the grid, so this is
# read on every list request and written on every click — hence the same
# atomic-replace + single-lock discipline as overrides.json, and the same
# "delete the file to reset" property.
_usage_lock = threading.Lock()


def load_usage():
    """key -> {"last_launched"?, "last_opened"?}, epoch floats. Never raises.

    Degrades exactly as load_overrides() does: missing, corrupt, unreadable
    or the wrong shape all mean "nothing used yet". A scrambled sort key must
    never be able to take the grid down. Bools are numbers in Python and are
    not timestamps, so they are dropped along with everything else odd.
    """
    try:
        with open(USAGE_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        log("usage unusable (%s); starting from no history" % exc)
        return {}
    if not isinstance(doc, dict):
        log("usage is not an object; starting from no history")
        return {}
    services = doc.get("services")
    if not isinstance(services, dict):
        return {}
    clean = {}
    for key, entry in services.items():
        if not isinstance(key, str) or not isinstance(entry, dict):
            continue
        kept = {}
        for field in ("last_launched", "last_opened"):
            value = entry.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                kept[field] = float(value)
        if kept:
            clean[key] = kept
    return clean


def _write_usage(data):
    """Atomically replace usage.json. Caller holds _usage_lock."""
    _write_json_atomically(USAGE_PATH, {"services": data}, ".usage-")


def usage_entry(usage, key):
    """The `usage` block for one service; all three keys always present.

    last_used is derived rather than stored, so it cannot drift out of step
    with the two stamps it is the maximum of.
    """
    entry = usage.get(key) or {}
    launched = entry.get("last_launched")
    opened = entry.get("last_opened")
    stamps = [t for t in (launched, opened) if t is not None]
    return {"last_launched": launched, "last_opened": opened,
            "last_used": max(stamps) if stamps else None}


def record_touch(key, body):
    """POST api/services/{key}/touch -> {"usage": {...}}.

    The key is looked up in the registry first, so a stray client cannot grow
    this file with names of its own, and the event is an allowlist of exactly
    two words: nothing from the request is ever written here but a timestamp
    this process took itself.
    """
    if find_service(key) is None:
        raise DeployError(404, "unknown service")
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    event = body.get("event")
    if event not in TOUCH_EVENTS:
        raise DeployError(400, "event must be one of: %s"
                          % ", ".join(TOUCH_EVENTS))
    now = time.time()
    with _usage_lock:
        data = load_usage()
        entry = dict(data.get(key) or {})
        entry["last_" + event] = now
        data[key] = entry
        _write_usage(data)
    return {"usage": usage_entry(data, key)}


# ------------------------------------------------------------------ env files

# Secret detection is by NAME, case-insensitively, because the value is never
# examined (and must not be: a hostname containing a password is still a
# password). Over-masking is a nuisance; under-masking is a leak, so this list
# is deliberately broad — IMMICH_VERSION stays visible, JWT_PRIVATE_KEY,
# DB_PASSWORD, ELEVENLABS_API_KEY and N8N_ENCRYPTION_KEY do not.
SECRET_MARKERS = ("PASS", "SECRET", "TOKEN", "KEY", "CRED", "PRIVATE")

_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_ENV_EXPORT_RE = re.compile(r"^export\s+")

# Inside a double-quoted value, exactly the escapes that a POSIX shell, Docker
# Compose's .env reader and this parser all agree on: \\ -> \ and \" -> ".
# `\$` and \` are deliberately NOT here — the shell unescapes both and Compose
# (measured 2026-09-12 with `docker compose config`) unescapes neither — so
# quote_env_value refuses to ever write one.
_DQ_UNESCAPE_RE = re.compile(r'\\([\\"])')

# A value that can sit bare after `NAME=` and mean the same thing to a shell
# `source`, to Docker Compose and to parse_env. Deliberately narrow: no
# whitespace, no quotes, no `#` (an inline comment to Compose after a space),
# no `$` (interpolated by both), no `~` (tilde-expanded by the shell), and
# none of the shell's other metacharacters. Anything outside it is quoted.
_ENV_BARE_RE = re.compile(r"^[A-Za-z0-9_./:@%+=,-]*$")


def is_secret(name):
    upper = (name or "").upper()
    return any(marker in upper for marker in SECRET_MARKERS)


def parse_env(text):
    """.env text -> {NAME: value}, in file order. Never executes anything.

    Handles what these files actually contain: KEY=value, blank lines, whole
    line `#` comments, `export KEY=value`, values containing `=`, and values
    wrapped in matching quotes. A `#` inside a value is left alone — several
    generated passwords here contain one, and eating it would hand back a
    wrong secret, which is worse than showing a stray comment.

    Anything malformed (no `=`, a name that is not a shell identifier) is
    skipped rather than raising: one bad line must not hide the whole file.
    A repeated name takes its last value, like the shell would, and keeps
    its first position.
    """
    out = {}
    for line in text.splitlines():
        hit = _split_assignment(line)
        if hit is None:
            continue
        name, value = hit
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            quote = value[0]
            value = value[1:-1]
            if quote == '"':
                value = _DQ_UNESCAPE_RE.sub(r"\1", value)
        out[name] = value
    return out


def _split_assignment(line):
    """(name, raw value) for a line parse_env would take, else None.

    Shared by the parser and the editor so that "which line sets X" has one
    answer: the editor rewrites exactly the lines the parser would read.
    """
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    line = _ENV_EXPORT_RE.sub("", line, count=1)
    if "=" not in line:
        return None
    name, value = line.split("=", 1)   # only the FIRST = splits
    name = name.strip()
    if not _ENV_NAME_RE.match(name):
        return None
    return name, value


def read_env(svc):
    """Parsed .env for a service, or raise DeployError.

    The path comes from the registry only and goes through the same
    allowed-roots gate as a deploy script.
    """
    raw = svc.get("env")
    if not raw:
        raise DeployError(404, "service has no env file")
    path = resolve_registry_path(raw, "env")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        raise DeployError(404, "env file not readable")
    return parse_env(text)


def env_payload(svc):
    """{path, exists, vars:[{name, secret}]} — NAMES AND FLAGS ONLY.

    No value ever appears here, not even masked: a mask still leaks length,
    and this payload is fetched by every detail page view. Reading a value is
    a separate, explicit POST.
    """
    raw = svc.get("env")
    if not raw:
        return {"path": None, "exists": False, "vars": []}
    try:
        parsed = read_env(svc)
    except DeployError as exc:
        # A refused or missing env file is not a broken detail page: report
        # the path the registry claims and an empty list.
        if exc.status != 404:
            log("env for %s refused: %s" % (svc.get("key"), exc.message))
        return {"path": raw, "exists": False, "vars": []}
    return {
        "path": raw,
        "exists": True,
        "vars": [{"name": name, "secret": is_secret(name)} for name in parsed],
    }


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


# ------------------------------------------------------------------ resources
#
# RAM and CPU per service, read from cgroup v2 in sysfs — never from `docker
# stats`, which would put resource use behind the docker group and drag the
# rest of the page down with it whenever that is missing. Measured on this
# box (2026-09-12), both exposing memory.current and cpu.stat:
#
#   container   <root>/system.slice/docker-<64hex>.scope/
#   user unit   <root>/user.slice/user-<uid>.slice/user@<uid>.service/
#                   app.slice/<unit>/
#
# The ONLY docker call anywhere in this path is one cached `docker ps` to map
# container name -> id. If it fails — no group, no daemon, no docker at
# all — every container part reports null and nothing else on the page moves.
# Parts come from the same `control.parts` the start/stop buttons use, so a
# service is measured exactly where it is controlled.

_docker_map_cache = {"at": 0.0, "map": {}}
_docker_map_lock = threading.Lock()

_resources_cache = {}      # key -> (sampled_at, payload)
_resources_lock = threading.Lock()

_cpu_samples = {}          # cgroup path -> (wall seconds, usage_usec)
_cpu_lock = threading.Lock()

# Container ids as `docker ps --no-trunc` prints them. Anything else is
# dropped rather than pasted into a path this then opens — the same instinct
# as _CONTROL_NAME_RE.
_CONTAINER_ID_RE = re.compile(r"^[0-9a-f]{12,64}$")


def _null_resources(now):
    """The all-null block. Shape is identical to a measured one, always."""
    return {"rss_bytes": None, "cpu_pct": None, "sampled_at": now,
            "parts": []}


def _read_docker_names():
    """{container name: full id}, or {} when docker cannot be reached.

    Goes through sg_docker for the reason the lifecycle actions do (a systemd
    *user* unit does not reliably inherit the docker group), and through
    subprocess so the test stub catches it. Every failure — missing binary,
    missing group, dead daemon, garbage output, a hung call — is the empty
    map, which is what makes "status keeps working with no docker" true here
    as well.
    """
    argv = sg_docker(["docker", "ps", "-a", "--no-trunc",
                      "--format", "{{.Names}}\t{{.ID}}"])
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
    except Exception as exc:
        log("docker ps unusable (%s); container resources report null" % exc)
        return {}
    try:
        out, _ = proc.communicate(timeout=DOCKER_MAP_TIMEOUT)
    except Exception as exc:
        # A wedged docker (the daemon is up but not answering) must not leave
        # a process behind on every poll.
        log("docker ps unusable (%s); container resources report null" % exc)
        try:
            proc.kill()
            proc.communicate(timeout=1)
        except Exception:
            pass
        return {}
    if proc.returncode:
        return {}
    mapping = {}
    for line in (out or "").splitlines():
        name, _, cid = line.partition("\t")
        name, cid = name.strip(), cid.strip()
        if name and _CONTAINER_ID_RE.match(cid):
            mapping[name] = cid
    return mapping


def docker_name_map():
    """The cached name -> id map (TTL DOCKER_MAP_TTL).

    A failure is cached too: on a box with no docker group this must cost one
    failed call every 10s, not one per container per request.
    """
    now = time.time()
    with _docker_map_lock:
        if now - _docker_map_cache["at"] < DOCKER_MAP_TTL:
            return _docker_map_cache["map"]
    mapping = _read_docker_names()
    with _docker_map_lock:
        _docker_map_cache["at"] = time.time()
        _docker_map_cache["map"] = mapping
    return mapping


def _container_cgroup(name, docker_map):
    """The cgroup directory for a running container, or None.

    The id is re-checked here and not only where the map is built, so that
    the shape of what gets pasted into a path this opens is guaranteed at
    the point of use — the same belt-and-braces as resolve_registry_path.
    """
    cid = docker_map.get(name)
    if not cid or not _CONTAINER_ID_RE.match(cid):
        return None
    path = os.path.join(CGROUP_ROOT, "system.slice",
                        "docker-%s.scope" % cid)
    return path if os.path.isdir(path) else None


def _unit_cgroup(name):
    """The cgroup directory for a systemd --user unit, or None.

    app.slice is where every unit controlled from here actually lives; the
    other candidates cost one isdir() each and cover a unit started outside
    it, or a system unit. A stopped unit has no cgroup at all, which is the
    ordinary reason this returns None — manimkc.service, dead, is not
    missing from the tree, it simply has none.
    """
    uid = os.getuid()
    user = os.path.join(CGROUP_ROOT, "user.slice", "user-%d.slice" % uid,
                        "user@%d.service" % uid)
    for candidate in (os.path.join(user, "app.slice", name),
                      os.path.join(user, "session.slice", name),
                      os.path.join(user, name),
                      os.path.join(CGROUP_ROOT, "system.slice", name)):
        if os.path.isdir(candidate):
            return candidate
    return None


def _read_rss(cgroup):
    """memory.current in bytes, or None.

    A missing or unreadable file is the ordinary case for a stopped service,
    so this is silent: no log line and certainly no traceback, just null.
    """
    try:
        path = os.path.join(cgroup, "memory.current")
        with open(path, encoding="utf-8") as fh:
            return int(fh.read().strip())
    except Exception:
        return None


def _read_usage_usec(cgroup):
    """usage_usec out of cpu.stat, in microseconds, or None. Also silent."""
    try:
        with open(os.path.join(cgroup, "cpu.stat"), encoding="utf-8") as fh:
            for line in fh:
                field, _, value = line.partition(" ")
                if field == "usage_usec":
                    return int(value.strip())
    except Exception:
        return None
    return None


def _cpu_percent(cgroup, usage_usec, now):
    """Percent of the WHOLE MACHINE since this cgroup's previous sample.

    null until two samples exist, which is why cpu_pct only appears on the
    grid's second poll. Clamped to [0, 100]: a restarted container resets
    usage_usec (negative delta) and a clock that jumped can make the wall
    delta small enough for the ratio to be absurd. Either should read as "no
    useful number", never as a spike.
    """
    if usage_usec is None:
        # Drop the stale sample: the next reading after a restart must not be
        # differenced against a counter that no longer exists.
        with _cpu_lock:
            _cpu_samples.pop(cgroup, None)
        return None
    with _cpu_lock:
        previous = _cpu_samples.get(cgroup)
        _cpu_samples[cgroup] = (now, usage_usec)
    if not previous:
        return None
    prev_wall, prev_usage = previous
    wall_usec = (now - prev_wall) * 1e6
    if wall_usec <= 0:
        return None
    pct = (usage_usec - prev_usage) / (wall_usec * (os.cpu_count() or 1)) * 100
    return max(0.0, min(100.0, pct))


def _measure_resources(svc, now):
    """One sysfs pass over a service's control parts. Caller holds the lock."""
    docker_map = None
    measured = []
    total_rss = None
    total_cpu = None
    for part in control_parts(control_block(svc)):
        if part["kind"] == "container":
            # Fetched only when a container part actually exists, so a
            # unit-only service never goes near docker.
            if docker_map is None:
                docker_map = docker_name_map()
            cgroup = _container_cgroup(part["name"], docker_map)
        else:
            cgroup = _unit_cgroup(part["name"])
        rss = _read_rss(cgroup) if cgroup else None
        cpu = _cpu_percent(cgroup, _read_usage_usec(cgroup), now) \
            if cgroup else None
        if rss is not None:
            total_rss = rss if total_rss is None else total_rss + rss
        if cpu is not None:
            total_cpu = cpu if total_cpu is None else total_cpu + cpu
        measured.append({"name": part["name"], "kind": part["kind"],
                         "rss_bytes": rss, "cpu_pct": cpu})
    if total_cpu is not None:
        total_cpu = max(0.0, min(100.0, total_cpu))
    return {"rss_bytes": total_rss, "cpu_pct": total_cpu,
            "sampled_at": now, "parts": measured}


def service_resources(svc):
    """The `resources` block for one service. Never raises.

    Cached for RESOURCE_TTL under one lock that does double duty: a busy grid
    cannot hammer sysfs, and two concurrent polls can neither both run the
    docker call nor both take a CPU sample microseconds apart.
    """
    key = svc.get("key")
    now = time.time()
    try:
        with _resources_lock:
            hit = _resources_cache.get(key)
            if hit and now - hit[0] < RESOURCE_TTL:
                return hit[1]
            payload = _measure_resources(svc, now)
            _resources_cache[key] = (now, payload)
            return payload
    except Exception as exc:
        # Resource use is the least important thing on this page: it may
        # never be the reason a tile fails to render.
        log("resources unavailable for %s (%s)" % (key, exc))
        return _null_resources(now)


def deployed_at(marker):
    """mtime of the service's marker path, epoch float, or None.

    "When was this deployed", without docker and without a package manager:
    the marker is the state dir or generated .env that setup.sh creates, the
    same file `installed` is already derived from.
    """
    if not marker:
        return None
    try:
        return os.path.getmtime(os.path.expanduser(marker))
    except OSError:
        return None


# ------------------------------------------------------------------ payload

def services_payload():
    host = magicdns_host()
    registry = load_registry()
    health_urls = [s["health"] for s in registry if s.get("health")]
    probes = probe_all(health_urls)
    # One in-memory pass over the job registry for the whole payload; see
    # jobs_by_key() for why this stays cheap enough to poll every 30s.
    jobs = jobs_by_key()
    # One read for the whole payload; a rename must show on the grid, not
    # only on the detail page it was made from.
    overrides = load_overrides()
    # Likewise one read for the usage stamps the grid's default sort needs,
    # rather than one open() per tile.
    usage = load_usage()

    services = []
    for svc in registry:
        health = svc.get("health")
        active = bool(health) and probes.get(health, False)
        installed = active or marker_exists(svc.get("marker"))
        name, description = effective(svc, overrides)
        services.append({
            "key": svc.get("key"),
            "name": name,
            "tagline": svc.get("tagline"),
            # Carried on the list too, not just the detail page: the grid's
            # hover tooltip needs it, and without it here that module had to
            # fetch every service individually just to show one bubble.
            "description": description,
            "icon": svc.get("icon"),
            "url": substitute_host(svc.get("url"), host),
            "state": derive_state(svc.get("setup"), installed, active),
            "installed": installed,
            "active": active,
            # Lets a reopened tile reattach to a deploy it started earlier
            # instead of POSTing a fresh one and getting a 409 it can do
            # nothing with. null when there is nothing to reattach to.
            "job": jobs.get(svc.get("key")),
            # Whether this tile gets start/stop buttons at all — and when it
            # does not, the same sentence the server refuses the request with.
            "control": control_status(svc),
            # v3 sort keys and resource use. All three are always present and
            # null when unknown, never absent: the grid sorts on them, and a
            # missing key is harder to be null-safe about than a null.
            "usage": usage_entry(usage, svc.get("key")),
            "deployed_at": deployed_at(svc.get("marker")),
            "resources": service_resources(svc),
        })
    return {"host": host, "services": services}


# ------------------------------------------------------------------ detail

_PORT_RE = re.compile(r"^https?://127\.0\.0\.1:(\d+)")


def _local_port(health):
    """The loopback port a service answers on, read off its health probe."""
    match = _PORT_RE.match(health or "")
    return int(match.group(1)) if match else None


def service_detail(key):
    """Everything the detail page needs, or None if the key is unknown.

    The nine fields the grid already gets (so the page can render without a
    second request), plus the effective description, `meta`, and env variable
    names. No env value, masked or otherwise, is in here.
    """
    svc = find_service(key)
    if svc is None:
        return None
    host = magicdns_host()
    health = svc.get("health")
    probes = probe_all([health]) if health else {}
    active = bool(health) and probes.get(health, False)
    installed = active or marker_exists(svc.get("marker"))
    overrides = load_overrides()
    name, description = effective(svc, overrides)
    edited = sorted(overrides.get(key, {}))

    return {
        "key": svc.get("key"),
        "name": name,
        "tagline": svc.get("tagline"),
        "icon": svc.get("icon"),
        "url": substitute_host(svc.get("url"), host),
        "state": derive_state(svc.get("setup"), installed, active),
        "installed": installed,
        "active": active,
        "job": jobs_by_key().get(key),
        "control": control_status(svc),
        "usage": usage_entry(load_usage(), key),
        "deployed_at": deployed_at(svc.get("marker")),
        "resources": service_resources(svc),
        "description": description,
        "meta": {
            # Registry facts, verbatim: paths as written, so what is shown is
            # what you would go and edit. Nothing derived is invented here —
            # local_port is read off the health probe and is null without one.
            "setup": svc.get("setup"),
            "health": health,
            "marker": svc.get("marker"),
            "env": svc.get("env"),
            "local_port": _local_port(health),
            # Which fields differ from services.json, so the UI can offer a
            # "reset to default" on exactly those.
            "edited": edited,
        },
        "env": env_payload(svc),
    }


# ---- editing

# C0 and C1-ish control characters, minus \t and \n which a description may
# legitimately contain. Stripped rather than rejected: a paste from a phone
# keyboard should not 400.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_WHITESPACE_RUN_RE = re.compile(r"\s+")


def clean_field(field, value, limit, multiline):
    """Validate and normalise one patchable string, or raise DeployError."""
    if not isinstance(value, str):
        raise DeployError(400, "%s must be a string" % field)
    text = _CONTROL_RE.sub("", value)
    if multiline:
        text = text.replace("\r\n", "\n").replace("\r", "\n")
    else:
        text = _WHITESPACE_RUN_RE.sub(" ", text)
    text = text.strip()
    if len(text) > limit:
        raise DeployError(400, "%s is too long (max %d characters)"
                          % (field, limit))
    return text


def patch_service(key, body):
    """Apply {name?, description?} to overrides.json and return the detail.

    An override equal to the shipped default, or blanked out, is *removed*
    rather than stored: the file only ever holds real differences, so
    deleting it really does restore defaults and an unedited service leaves
    no trace.
    """
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    if body is None:
        body = {}
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")

    edits = {}
    for field, limit, multiline in (("name", MAX_NAME, False),
                                    ("description", MAX_DESCRIPTION, True)):
        if field in body:
            edits[field] = clean_field(field, body[field], limit, multiline)

    if edits:
        defaults = {"name": svc.get("name") or "",
                    "description": svc.get("description") or ""}
        # Read-modify-write under one lock so two concurrent PATCHes (two
        # phones, two tabs) cannot lose each other's edit.
        with _overrides_lock:
            data = load_overrides()
            entry = dict(data.get(key) or {})
            for field, text in edits.items():
                if not text or text == defaults[field]:
                    entry.pop(field, None)
                else:
                    entry[field] = text
            if entry:
                data[key] = entry
            else:
                data.pop(key, None)
            _write_overrides(data)
        log("patched %s: %s" % (key, ", ".join(sorted(edits))))
    return service_detail(key)


# ---- reveal

def reveal_env_var(key, var):
    """{"name", "value"} for one variable of one service, or raise.

    `var` must be a name that actually appears in that service's env file;
    anything else is a 404 and the requested string is never echoed back.
    The value is returned to the caller and to nowhere else — in particular
    it is never logged.
    """
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    parsed = read_env(svc)   # registry path, allowed-roots gate, 403/404
    for name, value in parsed.items():
        if name == var:
            log("revealed %s.%s" % (key, name))   # name only, never the value
            return {"name": name, "value": value}
    raise DeployError(404, "unknown variable")


# ---- edit

# The .env files this rewrites are read by THREE things that must all agree
# on what a line means: `set -a; . .env` in every setup.sh (a POSIX shell),
# Docker Compose (interpolation + env_file), and parse_env above. The quoting
# rules below are the intersection of the three, verified against the
# Compose .env syntax docs and dash/bash:
#
#   bare            only for _ENV_BARE_RE — every reader takes it literally
#   'single quotes' the shell and Compose both take these literally, with no
#                   interpolation, so this is the default for anything else
#   "double quotes" only when the value itself contains an apostrophe; \\ and
#                   \" are escaped, and a `$` or a backtick is REFUSED, because
#                   the shell would unescape \$ and \` and Compose would not —
#                   there is no spelling of that value all three readers agree
#                   on (measured, see _DQ_UNESCAPE_RE).
#
# One lock for every env file. Edits are rare and tiny; the lock exists so
# two saves cannot interleave a read-modify-write on the same file.
_env_lock = threading.Lock()


def quote_env_value(value):
    """`value` rendered for the right-hand side of NAME=..., or raise 400."""
    if _ENV_BARE_RE.match(value):
        return value
    if "'" not in value:
        return "'" + value + "'"
    if "$" in value or "`" in value:
        raise DeployError(
            400, "a value containing an apostrophe cannot also contain $ or `")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_env_edit(text, var, rendered):
    """`text` with every line that assigns `var` rewritten; -> (text, count).

    Every other byte survives untouched: comments, blank lines, ordering, the
    other variables, a missing final newline, CRLF endings. On a rewritten
    line the indentation and any `export ` prefix are kept too. *Every*
    assignment is rewritten, not just the last, so a file with a stale
    duplicate cannot read one way to the shell and another way here.
    """
    out = []
    count = 0
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        hit = _split_assignment(body)
        if hit is None or hit[0] != var:
            out.append(line)
            continue
        ending = line[len(body):]
        stripped = body.lstrip()
        indent = body[:len(body) - len(stripped)]
        prefix = _ENV_EXPORT_RE.match(stripped)
        out.append(indent + (prefix.group(0) if prefix else "")
                   + var + "=" + rendered + ending)
        count += 1
    return "".join(out), count


def _write_env_atomically(path, text, st):
    """Replace the env file with `text`; caller holds _env_lock.

    Same discipline as the JSON stores (temp file beside the target, fsync,
    one os.replace), plus: the original mode is copied onto the new file —
    setup.sh made these 0600 for a reason — and the group is kept where the
    process is allowed to. Bytes that were not valid UTF-8 round-trip via
    surrogateescape rather than being silently replaced.
    """
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".env-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape",
                       newline="") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        try:
            os.chown(tmp, -1, st.st_gid)
        except OSError:
            pass   # not our group any more; the mode is what protects the file
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def update_env_var(key, var, body):
    """Set one variable in one service's env file; -> {"name", "secret"}.

    `var` must already be assigned in the file — this edits, it does not
    add, so the request can never introduce a name the service's setup.sh
    did not put there. Unknown names are a 404 that never echoes the request,
    exactly like reveal. The value goes into the file and into the response
    to the caller and nowhere else: never a log line.

    A last check before writing: the rewritten text is parsed back and must
    yield the value that was sent. If the quoting rules and the parser ever
    disagree, the request fails and the file is left alone.
    """
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    value = body.get("value")
    if not isinstance(value, str):
        raise DeployError(400, "value must be a string")
    if len(value) > MAX_ENV_VALUE:
        raise DeployError(400, "value is too long (max %d characters)" % MAX_ENV_VALUE)
    if "\n" in value or "\r" in value or "\0" in value:
        raise DeployError(400, "value must be a single line")

    raw = svc.get("env")
    if not raw:
        raise DeployError(404, "service has no env file")
    path = resolve_registry_path(raw, "env")   # allowed-roots gate: 403
    rendered = quote_env_value(value)          # 400

    with _env_lock:
        try:
            st = os.stat(path)
            # newline="" both ways: a CRLF file stays a CRLF file.
            with open(path, "r", encoding="utf-8", errors="surrogateescape",
                      newline="") as fh:
                text = fh.read()
        except OSError:
            raise DeployError(404, "env file not readable")
        new_text, count = render_env_edit(text, var, rendered)
        if count == 0:
            raise DeployError(404, "unknown variable")
        if parse_env(new_text).get(var) != value:
            log("refusing to write %s.%s: quoting does not round-trip" % (key, var))
            raise DeployError(500, "could not encode that value safely")
        _write_env_atomically(path, new_text, st)
    log("updated %s.%s" % (key, var))   # name only, never the value
    return {"name": var, "secret": is_secret(var), "value": value}


# ------------------------------------------------------------------ notes

# Per-service developer notes: "why is ML off", "the admin password rotated on
# the 3rd", "restart order after a reboot". Plain text, newest first, and
# deliberately small — no markdown rendering, no tags, no attachments.
#
# They live in ~/services/launcher/notes.json for exactly the reason overrides
# do: services.json is git-tracked and shipped, and a note is user-authored
# content that exists nowhere else. Losing it is not recoverable by a git
# checkout, so every write goes through the same read-modify-write under a
# lock plus atomic replace that overrides.json uses.
#
#   {"services": {"immich": [ {id, title, body, created_at, updated_at}, ...]}}
#
# Lists are stored newest-first, which is also the order they are served in.
_notes_lock = threading.Lock()

_NOTE_FIELDS = ("id", "title", "body", "created_at", "updated_at")


def _now_iso():
    """ISO-8601 UTC with a literal Z, to milliseconds.

    Milliseconds rather than seconds so two notes written in the same second
    still sort against each other; a Z rather than +00:00 so `new Date(...)`
    in the browser needs no help.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    return "%s.%03dZ" % (now.strftime("%Y-%m-%dT%H:%M:%S"),
                         now.microsecond // 1000)


def _valid_note(entry):
    """A note is only usable if every field is a non-empty-ish string."""
    if not isinstance(entry, dict):
        return False
    for field in _NOTE_FIELDS:
        if not isinstance(entry.get(field), str):
            return False
    return bool(entry["id"])


def _order_notes(items):
    """Newest first. Stable, so same-millisecond notes keep insertion order."""
    return sorted(items, key=lambda n: n["created_at"], reverse=True)


def load_notes():
    """key -> [note, ...] newest-first, for every key on disk. Never raises.

    Missing, corrupt, unreadable, or the wrong shape all degrade to "no
    notes", exactly like load_overrides: this is the page you open when other
    things are broken, so a mangled notes.json must cost you your notes, not
    the launcher. Individual malformed entries are dropped and the rest of the
    file is kept.

    Keys that are no longer in the registry are returned as-is. Nothing serves
    them (every endpoint looks the key up first), but they stay in the dict so
    a write preserves them — a service can come back.
    """
    try:
        with open(NOTES_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        log("notes unusable (%s); serving no notes" % exc)
        return {}
    if not isinstance(doc, dict):
        log("notes is not an object; serving no notes")
        return {}
    services = doc.get("services")
    if not isinstance(services, dict):
        return {}
    clean = {}
    for key, items in services.items():
        if not isinstance(key, str) or not isinstance(items, list):
            continue
        kept = [{f: entry[f] for f in _NOTE_FIELDS}
                for entry in items if _valid_note(entry)]
        if kept:
            clean[key] = _order_notes(kept)
    return clean


def _write_notes(data):
    """Atomically replace notes.json. Caller holds _notes_lock."""
    _write_json_atomically(NOTES_PATH, {"services": data}, ".notes-")


def derive_title(body):
    """First non-blank line of a body, collapsed and truncated, or "".

    The UI collapses a note to its title line, so every note needs one and
    most will not have been given one: typing a body and hitting save is the
    whole interaction. Truncation prefers a word boundary when that does not
    cost too much of the line, and marks the cut with an ellipsis.
    """
    for line in (body or "").split("\n"):
        line = _WHITESPACE_RUN_RE.sub(" ", line).strip()
        if not line:
            continue
        if len(line) <= MAX_NOTE_TITLE:
            return line
        cut = line[:MAX_NOTE_TITLE - 1]
        space = cut.rfind(" ")
        if space >= MAX_NOTE_TITLE - 25:
            cut = cut[:space]
        return cut.rstrip() + "…"
    return ""


def _resolve_note_fields(title, body):
    """(title, body) for a note, deriving the title when it is blank.

    A note with neither is refused rather than stored: it would render as an
    untitled blank row that you cannot tell from a bug.
    """
    if not title:
        title = derive_title(body)
    if not title and not body:
        raise DeployError(400, "note is empty")
    return title, body


def _clean_note_body(value):
    return clean_field("body", value, MAX_NOTE_BODY, True)


def _clean_note_title(value):
    return clean_field("title", value, MAX_NOTE_TITLE, False)


def notes_payload(key):
    """{"notes": [...]} for one service, or raise 404."""
    if find_service(key) is None:
        raise DeployError(404, "unknown service")
    return {"notes": load_notes().get(key, [])}


def create_note(key, body):
    """{title?, body} -> the created note. Raises on anything unusable."""
    if find_service(key) is None:
        raise DeployError(404, "unknown service")
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    if "body" not in body:
        raise DeployError(400, "body is required")

    text = _clean_note_body(body["body"])
    title = _clean_note_title(body["title"]) if "title" in body else ""
    title, text = _resolve_note_fields(title, text)

    now = _now_iso()
    note = {
        # Opaque and unguessable-ish so a note id is not a number anyone can
        # walk, and stable for the life of the note so the UI can key on it.
        "id": uuid.uuid4().hex,
        "title": title,
        "body": text,
        "created_at": now,
        "updated_at": now,
    }
    with _notes_lock:
        data = load_notes()
        items = list(data.get(key) or [])
        if len(items) >= MAX_NOTES_PER_SERVICE:
            # 409, not 400: the request is perfectly well formed, it is the
            # state on disk that refuses it. Deleting a note makes the same
            # request succeed.
            raise DeployError(409, "too many notes for %s (max %d)"
                              % (key, MAX_NOTES_PER_SERVICE))
        data[key] = [note] + items
        _write_notes(data)
    log("note added to %s (%s)" % (key, note["id"]))
    return note


def update_note(key, note_id, body):
    """{title?, body?} -> the updated note.

    `updated_at` moves only on a real content change, so a save that changed
    nothing does not make the note look freshly edited.

    A title that was derived from the body follows the body when the body is
    edited; one that was typed by hand does not. That is the behaviour you
    want in both cases, and it needs no extra field on disk — a title equal to
    what the old body would derive is by definition a derived one.
    """
    if find_service(key) is None:
        raise DeployError(404, "unknown service")
    if body is None:
        body = {}
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")

    new_body = _clean_note_body(body["body"]) if "body" in body else None
    new_title = _clean_note_title(body["title"]) if "title" in body else None

    with _notes_lock:
        data = load_notes()
        # Only this service's list is ever searched, so an id from service A
        # is not reachable under service B.
        items = list(data.get(key) or [])
        index = next((i for i, n in enumerate(items) if n["id"] == note_id),
                     None)
        if index is None:
            raise DeployError(404, "unknown note")
        note = dict(items[index])

        text = note["body"] if new_body is None else new_body
        if new_title is None:
            title = note["title"]
            if new_body is not None and title == derive_title(note["body"]):
                title = ""      # was derived; re-derive from the new body
        else:
            title = new_title   # blank on purpose falls back to derived
        title, text = _resolve_note_fields(title, text)

        if title == note["title"] and text == note["body"]:
            return note         # no content change, no new updated_at

        note["title"] = title
        note["body"] = text
        note["updated_at"] = _now_iso()
        items[index] = note
        data[key] = items
        _write_notes(data)
    log("note updated on %s (%s)" % (key, note_id))
    return note


def delete_note(key, note_id):
    """Remove one note. 404 if the service or the note is unknown."""
    if find_service(key) is None:
        raise DeployError(404, "unknown service")
    with _notes_lock:
        data = load_notes()
        items = list(data.get(key) or [])
        remaining = [n for n in items if n["id"] != note_id]
        if len(remaining) == len(items):
            raise DeployError(404, "unknown note")
        if remaining:
            data[key] = remaining
        else:
            data.pop(key, None)
        _write_notes(data)
    log("note deleted from %s (%s)" % (key, note_id))


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
    """key -> {"id", "status", "action"} for the job worth showing on a tile.

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
                     j.get("finished"), j.get("action") or "deploy")
                    for j in _jobs.values()]

    best = {}
    for job_id, key, status, started, finished, action in snapshot:
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
            best[key] = (rank, {"id": job_id, "status": status,
                                "action": action})
    return {key: entry for key, (_, entry) in best.items()}


def resolve_script(svc):
    """Registry setup path -> absolute script path, or raise DeployError.

    The path never comes from the request: only `key` does, and that is
    looked up in the registry first. This resolves and re-checks anyway so
    a bad registry edit (or a `..` in one) still cannot escape.
    """
    setup = svc.get("setup")
    if not setup:
        raise DeployError(400, "service has no setup script (planned)")
    path = resolve_registry_path(setup, "setup")
    if not os.path.isfile(path):
        raise DeployError(404, "setup script not found")
    return path


def _have_docker_group():
    try:
        return "docker" in {grp.getgrgid(g).gr_name for g in os.getgroups()}
    except Exception:
        return False


def sg_docker(argv):
    """argv, re-entered under the docker group if this process lacks it.

    A systemd *user* unit does not reliably pick up the docker group even
    when the user is in it, so anything touching the daemon would fail on a
    permission error that never appears in an interactive shell.
    `sg docker -c ...` re-enters with the group applied. sg takes a command
    *string*, which is the one place a string is built — from
    registry-supplied words only, shlex-quoted, with no request data anywhere
    near it. If sg is missing, or the group is already present, the argv is
    returned untouched and runs with no shell at all.

    Shared by the deploy endpoint and the lifecycle actions, so there is one
    docker-group workaround on this box rather than two.
    """
    if _have_docker_group():
        return argv
    sg = _which("sg")
    if not sg:
        return argv
    return [sg, "docker", "-c", " ".join(shlex.quote(a) for a in argv)]


def build_command(script):
    """argv for running a deploy script, as a list — never a shell string."""
    if os.access(script, os.X_OK):
        direct = [script]
    else:
        direct = ["/bin/bash", script]
    return sg_docker(direct)


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def register_job(key, action):
    """Claim a job slot for `key` and return the job record, or raise.

    The one place a job is created, so a deploy and a stop compete for the
    same per-key slot and the same global cap: you cannot stop a service out
    from under a deploy of it, or run five things at once.
    """
    job_id = uuid.uuid4().hex
    os.makedirs(JOBS_DIR, exist_ok=True)
    log_path = os.path.join(JOBS_DIR, "%s.log" % job_id)

    with _jobs_lock:
        running = [j for j in _jobs.values() if j["status"] == "running"]
        if any(j["key"] == key for j in running):
            raise DeployError(409, "a job is already running for %s" % key)
        if len(running) >= MAX_JOBS:
            raise DeployError(429, "too many jobs running (max %d)" % MAX_JOBS)
        job = {
            "id": job_id,
            "key": key,
            "action": action,
            "status": "running",
            "exit_code": None,
            "log_path": log_path,
            "started": time.time(),
            "finished": None,
        }
        _jobs[job_id] = job
    return job


def _finish(job, code):
    with _jobs_lock:
        job["exit_code"] = code
        job["status"] = "done" if code == 0 else "failed"
        job["finished"] = time.time()
    log("job %s (%s %s) exited %d"
        % (job["id"], job["action"], job["key"], code))


def start_deploy(key):
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    script = resolve_script(svc)

    job = register_job(key, "deploy")
    job_id, log_path = job["id"], job["log_path"]

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
    _finish(job, code)


# ------------------------------------------------------------------ control
#
# Start/stop/restart, driven by the SAME per-service `control` block in
# services.json that ntfy-control reads off the repo at runtime. One map, two
# front ends: a service controllable from the phone is controllable from the
# web and vice versa, and neither can pause a Kuma monitor the other forgets
# about. See the `_comment` in services.json for the schema:
#
#   "control": {
#     "parts": [{"container": "immich_server"},
#               {"container": "immich_machine_learning", "optional": true},
#               {"container": "immich_redis"}],   # STOP order; start reverses
#     "primary": "immich_server",   # which part reports state (default: first)
#     "kuma": "immich",             # monitor paused on stop, resumed on start
#     "locked": "why this one is deliberately not controllable"
#   }

CONTROL_ACTIONS = ("start", "stop", "restart")

# Container and unit names, as they may appear in the registry. Everything
# outside this shape is dropped rather than executed — the same instinct as
# resolve_registry_path: a hand-edited or malicious registry must not be able
# to smuggle a word into an argv (and, via sg, into a shell string).
_CONTROL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$")

# The second lock. services.json already marks these `locked`, and this is
# here so that an edit to that file cannot undo it: a config mistake must not
# be able to hand the web UI a button that turns off the thing serving the web
# UI, the thing you would use to turn it back on, or something needing sudo.
HARD_LOCKED = {
    "launcher": "the launcher cannot stop itself — there would be no UI left "
                "to start it from",
    "ntfy": "stopping ntfy would remove the only way to start anything again "
            "from the phone",
    "ollama": "ollama is a system unit, so controlling it needs sudo — this "
              "endpoint deliberately has no sudo path",
}


def control_block(svc):
    block = svc.get("control")
    return block if isinstance(block, dict) else {}


def control_parts(block):
    """The usable `parts` of a control block, in STOP order.

    Anything malformed is dropped, so a half-edited registry entry degrades
    to "fewer parts" (and, if none survive, to "not controllable") rather
    than to a surprising argv.
    """
    raw = block.get("parts")
    if not isinstance(raw, list):
        return []
    parts = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        kind = "container" if "container" in entry else "unit"
        name = entry.get(kind)
        if not isinstance(name, str) or not _CONTROL_NAME_RE.match(name):
            continue
        parts.append({"kind": kind, "name": name,
                      "optional": bool(entry.get("optional"))})
    return parts


def control_monitor(block):
    """The Kuma monitor name for a service, or None."""
    name = block.get("kuma")
    if isinstance(name, str) and _CONTROL_NAME_RE.match(name):
        return name
    return None


def control_status(svc):
    """{"controllable", "reason"} — what the UI needs to draw the buttons.

    The reason is also the message a refused request gets back, so what the
    UI explains and what the server enforces are the same sentence.
    """
    key = svc.get("key")
    if key in HARD_LOCKED:
        return {"controllable": False, "reason": HARD_LOCKED[key]}
    block = control_block(svc)
    locked = block.get("locked")
    if isinstance(locked, str) and locked:
        return {"controllable": False, "reason": locked}
    if not control_parts(block):
        return {"controllable": False,
                "reason": "this service has no start/stop configuration"}
    return {"controllable": True, "reason": None}


def _find_uv():
    """uv, which kuma_toggle.py runs under. None if it isn't on this box.

    The launcher's unit PATH is deliberately minimal and need not contain uv
    (it is a nix/uv-installed tool), so the usual install locations are tried
    too. Missing uv is not an error: the Kuma step is best-effort.
    """
    found = _which("uv")
    if found:
        return found
    for candidate in ("~/.local/bin/uv", "~/.nix-profile/bin/uv"):
        path = os.path.expanduser(candidate)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def kuma_step(action, monitor):
    """A step that pauses/resumes one Kuma monitor, or None if it can't run.

    Calls the EXISTING ntfy-control/kuma_toggle.py — the launcher does not
    talk to Kuma itself, so there is one implementation of "pause a monitor"
    on this box. Everything about this is best-effort: no uv, no toggle
    script, no monitoring/.env, or a non-zero exit all leave the lifecycle
    action itself untouched. Deliberate downtime not paging is a nicety;
    being unable to stop a service because the monitoring stack is unhappy
    would be a bug.
    """
    cfg = load_control_config()
    uv = _find_uv()
    if not uv:
        return None
    try:
        toggle = resolve_registry_path(
            cfg.get("kuma_toggle") or "ntfy-control/kuma_toggle.py",
            "kuma_toggle")
        env_path = resolve_registry_path(
            cfg.get("kuma_env") or "monitoring/.env", "kuma env")
    except DeployError as exc:
        log("kuma %s skipped: %s" % (action, exc.message))
        return None
    if not os.path.isfile(toggle):
        return None
    try:
        with open(env_path, "r", encoding="utf-8", errors="replace") as fh:
            credentials = parse_env(fh.read())
    except OSError:
        return None
    if not credentials.get("KUMA_PORT"):
        return None
    # The credentials go to the child process only. They are never written to
    # the job log, which is served over HTTP by api/jobs/{id}.
    env = dict(os.environ)
    env.update(credentials)
    return {
        "argv": [uv, "run", "--with", "uptime-kuma-api", "python3",
                 toggle, action, monitor],
        "optional": True,
        # A resume runs even after an earlier step failed: a service that
        # would not come back up is real downtime and should be allowed to
        # page. A pause has nothing after it to be skipped by.
        "always": action == "resume",
        "env": env,
    }


def _part_step(part, verb):
    """One container or one unit, one verb. Argument list, never a string."""
    if part["kind"] == "container":
        # docker needs the group; systemctl --user does not, so only this
        # branch goes through the sg wrapper.
        argv = sg_docker(["docker", verb, part["name"]])
    else:
        argv = ["systemctl", "--user", verb, part["name"]]
    return {"argv": argv, "optional": part["optional"], "always": False,
            "env": None}


def plan_action(svc, action):
    """The ordered list of steps for one lifecycle action.

    Sequential, one command per part, rather than one `docker stop a b c`:
    the docker CLI stops multiple containers in parallel, and for Immich the
    order is the whole point — the server has to go before the database it is
    still talking to. Start is the exact reverse, so dependencies come up
    first.

    Kuma is paused before anything stops and resumed after everything starts,
    which is also what makes `restart` silent rather than a guaranteed page.
    """
    block = control_block(svc)
    parts = control_parts(block)
    monitor = control_monitor(block)
    steps = []

    if action in ("stop", "restart"):
        if monitor:
            step = kuma_step("pause", monitor)
            if step:
                steps.append(step)
        steps.extend(_part_step(p, "stop") for p in parts)
    if action in ("start", "restart"):
        steps.extend(_part_step(p, "start") for p in reversed(parts))
        if monitor:
            step = kuma_step("resume", monitor)
            if step:
                steps.append(step)
    return steps


def _run_steps(job, steps):
    """Run a plan in order, tee'd to the job log. Runs on its own thread.

    A required step that fails ends the job there — a failed `docker stop
    immich_server` must not be followed by stopping the database out from
    under it. An optional step that fails is noted and skipped: that is
    Immich's machine-learning container, which only exists when the `ml`
    compose profile is active, and the Kuma steps. Steps marked `always`
    still run after that abort, so a restart that dies half way still
    un-pauses the monitor it paused.
    """
    code = 0
    try:
        logfile = open(job["log_path"], "wb", buffering=0)
    except OSError as exc:
        log("job %s could not open its log: %s" % (job["id"], exc))
        _finish(job, -1)
        return

    def run_one(step):
        # The argv, and only the argv: `env` may carry Kuma credentials.
        logfile.write(("$ %s\n" % " ".join(step["argv"])).encode())
        try:
            proc = subprocess.Popen(
                step["argv"], stdout=logfile, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, shell=False, env=step.get("env"),
            )
            return proc.wait()
        except Exception as exc:
            logfile.write(("could not run: %s\n" % exc).encode())
            return -1

    try:
        for index, step in enumerate(steps):
            result = run_one(step)
            if result == 0:
                continue
            if step.get("optional"):
                logfile.write(
                    ("[skipped: exited %d, continuing]\n" % result).encode())
                continue
            logfile.write(("[failed: exited %d]\n" % result).encode())
            code = result
            for tail in steps[index + 1:]:
                if tail.get("always"):
                    run_one(tail)
            break
    finally:
        try:
            logfile.close()
        except Exception:
            pass
    _finish(job, code)


def start_action(key, action):
    """Queue a lifecycle action for one service and return its job id.

    Same allowlist discipline as deploy: only `key` and `action` come from
    the request, both are matched against fixed sets, and every word in every
    argv comes from the registry or is a constant.
    """
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    if action not in CONTROL_ACTIONS:
        raise DeployError(400, "unknown action")
    status = control_status(svc)
    if not status["controllable"]:
        raise DeployError(403, status["reason"])

    steps = plan_action(svc, action)
    if not steps:
        raise DeployError(403, "this service has no start/stop configuration")

    job = register_job(key, action)
    log("%s %s started: %s (%d steps)"
        % (action, key, job["id"], len(steps)))
    threading.Thread(target=_run_steps, args=(job, steps),
                     daemon=True).start()
    return job["id"]


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
        # Which verb this job is running, so a sheet reattaching to a job can
        # say "Stopping…" rather than always "Deploying…".
        "action": snapshot.get("action") or "deploy",
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

    def _no_content(self):
        """204: no body at all, and deliberately no Content-Length with it."""
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _error(self, status, message):
        self._json(status, {"error": message})

    # ---- routing

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def _read_json_body(self, limit=MAX_BODY_BYTES):
        """Parsed JSON body, or None when empty. Raises DeployError on junk.

        Always drains the body first so the connection stays usable for the
        next keep-alive request — except over the limit, where the body is
        deliberately not read at all and the connection is closed instead.
        """
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise DeployError(400, "bad Content-Length")
        if length < 0:
            raise DeployError(400, "bad Content-Length")
        if length > limit:
            self.close_connection = True
            raise DeployError(413, "body too large")
        raw = self.rfile.read(length) if length else b""
        if not raw.strip():
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise DeployError(400, "malformed JSON body")

    def _dispatch(self, method):
        try:
            path = normalize(self.path)
            if method == "GET":
                self._route_get(path)
            elif method == "PATCH":
                self._route_patch(path)
            elif method == "DELETE":
                self._route_delete(path)
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
        if path.startswith("api/services/"):
            rest = path[len("api/services/"):].strip("/")
            if rest and "/" not in rest:
                detail = service_detail(rest)
                if detail is None:
                    self._error(404, "unknown service")
                else:
                    self._json(200, detail)
                return
            parts = path.strip("/").split("/")
            if len(parts) == 4 and parts[3] == "notes":
                self._json(200, notes_payload(parts[2]))
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
        parts = path.strip("/").split("/")
        # Read (and, for deploy, discard) any body first so the connection
        # stays sane. `touch` is the one endpoint with a tighter cap: its
        # whole body is {"event": "launched"}, so 1 KB is already generous
        # and there is no reason to read 64 KB from a click handler.
        is_touch = (len(parts) == 4 and parts[0] == "api"
                    and parts[1] == "services" and parts[3] == "touch")
        limit = MAX_TOUCH_BYTES if is_touch else MAX_BODY_BYTES
        body = self._read_json_body(limit)

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "deploy":
            job_id = start_deploy(parts[2])
            self._json(202, {"job_id": job_id})
            return
        # start/stop/restart. Same 202 + job id as a deploy, on purpose: the
        # UI streams progress from api/jobs/{id} with the code it already has.
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "action":
            if not isinstance(body, dict):
                raise DeployError(400, "body must be a JSON object")
            action = body.get("action")
            if not isinstance(action, str):
                raise DeployError(400, "action must be a string")
            self._json(202, {"job_id": start_action(parts[2], action)})
            return
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "notes":
            self._json(201, create_note(parts[2], body))
            return
        # One click, one timestamp. Fired with keepalive:true on launch,
        # because that click is navigating the tab away as it goes.
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "touch":
            self._json(200, record_touch(parts[2], body))
            return
        # Revealing one secret is a POST on purpose: a GET could be
        # prefetched, link-previewed, or left sitting in browser history.
        if len(parts) == 6 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "env" and parts[5] == "reveal":
            self._json(200, reveal_env_var(parts[2], parts[4]))
            return
        self._error(404, "unknown endpoint")

    def _route_patch(self, path):
        body = self._read_json_body()
        parts = path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "services":
            self._json(200, patch_service(parts[2], body))
            return
        if len(parts) == 5 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "notes":
            self._json(200, update_note(parts[2], parts[4], body))
            return
        # Editing one env value. PATCH, not POST: the reveal endpoint next to
        # it is a POST, and the two must never be confusable.
        if len(parts) == 5 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "env":
            self._json(200, update_env_var(parts[2], parts[4], body))
            return
        self._error(404, "unknown endpoint")

    def _route_delete(self, path):
        # Drain any body first, as every other method does, so a client that
        # sends one on a DELETE does not wedge the keep-alive connection.
        self._read_json_body()
        parts = path.strip("/").split("/")
        if len(parts) == 5 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "notes":
            delete_note(parts[2], parts[4])
            self._no_content()
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
