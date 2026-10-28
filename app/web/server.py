#!/usr/bin/env python3
"""launcher — app launcher + one-tap deploy for homeserver.

Python 3 standard library only, on purpose: this is meant to be the first
thing that comes up on the box and the thing you reach for when something
else is broken, so it must have no moving parts (no pip, no venv, no
framework).

Serves static/ as static files and a small JSON API:

    GET    api/services            registry + derived state
    POST   api/services/{key}/deploy
    POST   api/services/{key}/action   {"action": start|stop|restart}
    POST   api/services/{key}/update   202 -> pull newer images + setup.sh job
    POST   api/services/{key}/updates/check   re-check its images now
    GET    api/services/{key}      detail: identity, meta, env var NAMES
    PATCH  api/services/{key}      {name?, description?} -> overrides.json
    POST   api/services/{key}/env/{var}/reveal   one value, deliberately POST
    PATCH  api/services/{key}/env/{var}   {"value"} -> rewrites that line in .env
    POST   api/services/{key}/touch  {"event": launched|opened} -> usage.json
    GET    api/services/{key}/notes            newest-first
    POST   api/services/{key}/notes            {title?, body} -> 201
    PATCH  api/services/{key}/notes/{id}       {title?, body?}
    DELETE api/services/{key}/notes/{id}       204
    GET    api/deployd           poller list + state (what deployd polls)
    POST   api/deployd/pollers/{key}           {repo, ref?, cmd} -> upsert
    DELETE api/deployd/pollers/{key}           suppress/delete the poller
    POST   api/deployd/pollers/{key}/restore   drop its overrides row
    POST   api/deployd/pollers/{key}/pause|resume   <key>.disabled marker
    POST   api/deployd/pollers/{key}/deploy    202 -> `deployd --force` job
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
import shutil
import signal
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

import ghapp  # noqa: E402  (app/web/ghapp.py, beside this file)

# ------------------------------------------------------------------ config

HERE = os.path.dirname(os.path.abspath(__file__))

PORT = int(os.environ.get("LAUNCHER_PORT", "8093"))
BIND = "127.0.0.1"  # tailnet is the security boundary; never 0.0.0.0

# Repo root defaults to two levels above app/web/, so the checkout can live
# anywhere without editing this file.
REPO_ROOT = os.path.realpath(os.environ.get("REPO_ROOT", os.path.dirname(os.path.dirname(HERE))))

WEB_DIR = os.path.join(HERE, "static")
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

# One install receipt per service, written when a deploy from this launcher
# exits 0: which repo and revision it came from, when, and the ports and data
# dir it left behind. Per-box state like usage.json, never in git. Tile state
# still comes from the marker and the health probe, so a stale receipt can
# never make a removed service look installed.
INSTANCES_DIR = os.path.expanduser("~/services/launcher/instances")

# deployd's service home: one state/<key>.sha/.fail/.log triplet per watched
# service, which is what GET /api/deployd renders. $SERVICE_HOME in
# services/deployd/.env can move it, so the payload resolves the env file
# first and only falls back here.
DEPLOYD_HOME = os.path.expanduser("~/services/deployd")

# Last image-update check per service (see the "updates" section): which
# container images have a newer digest behind the same tag on their registry.
# Per-box state, rewritten by the background check every UPDATE_INTERVAL and
# by "Check now"; deleting it only means "not checked yet".
UPDATES_PATH = os.path.expanduser("~/services/launcher/updates.json")
UPDATE_INTERVAL = 6 * 3600.0   # seconds between background sweeps
UPDATE_FIRST_DELAY = 120.0     # let the box settle after a boot first
REGISTRY_TIMEOUT = 10.0        # one manifest HEAD or token GET
DOCKER_INSPECT_TIMEOUT = 15.0

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
    """The `services` array of services.json, plus the apps built from GitHub
    repos (ghapp_entries), which live in box state rather than the repo."""
    services = load_document().get("services")
    services = services if isinstance(services, list) else []
    taken = {s.get("key") for s in services if isinstance(s, dict)}
    return services + [e for e in ghapp_entries() if e["key"] not in taken]


def load_groups():
    """The file-level `groups` catalog: bucket id + label, in paint order.

    Missing, malformed or empty is fine — the frontend then has no headings
    and the grid is the flat list it always was. Each service's `group` is
    an id from this list; unknown ids are Other.
    """
    raw = load_document().get("groups")
    if not isinstance(raw, list):
        return []
    out = []
    seen = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        gid = item.get("id")
        label = item.get("label")
        if not isinstance(gid, str) or not gid or gid in seen:
            continue
        if not isinstance(label, str) or not label.strip():
            continue
        seen.add(gid)
        out.append({"id": gid, "label": label.strip()})
    if GHAPP_GROUP["id"] not in seen and ghapp_entries():
        out.append(dict(GHAPP_GROUP))
    return out


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
        # Compare on path components, not string prefixes: /home/admin/devil
        # must not pass a /home/admin/dev check.
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
    with _usage_lock:
        # Stamped by whichever request actually writes, not at entry: two
        # near-simultaneous clicks that take the lock in the opposite order
        # would otherwise persist the earlier stamp last, moving last_launched
        # backwards and contradicting the 200 the first caller already got.
        now = time.time()
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


def parse_env(text, literal=False):
    """.env text -> {NAME: value}, in file order. Never executes anything.

    literal=True reads Docker's --env-file format instead (a GitHub app's
    .env): everything after the first `=` is the value, quotes and all.

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
        if literal:
            out[name] = value
            continue
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


def env_path(svc):
    """Absolute .env path for a service, or raise DeployError.

    Registry entries go through the allowed-roots gate. A GitHub app's .env
    is derived from its key (shape-checked) under ~/services/apps instead:
    nothing about that path comes from the registry or a request.
    """
    if svc.get("runner") == "ghapp":
        key = svc.get("key")
        if not isinstance(key, str) or not ghapp.KEY_RE.match(key):
            raise DeployError(403, "env path is outside the allowed roots")
        return os.path.join(ghapp.app_dir(key), ".env")
    raw = svc.get("env")
    if not raw:
        raise DeployError(404, "service has no env file")
    return resolve_registry_path(raw, "env")


def read_env(svc):
    """Parsed .env for a service, or raise DeployError.

    The path comes from the registry only and goes through the same
    allowed-roots gate as a deploy script.
    """
    path = env_path(svc)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        raise DeployError(404, "env file not readable")
    return parse_env(text, literal=is_docker_env(svc))


def is_docker_env(svc):
    """True for a GitHub app: its .env feeds `docker run --env-file`, which
    keeps quotes as part of the value, so it is read and written bare."""
    return svc.get("runner") == "ghapp"


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
    # A registry is hand-edited, so `marker` is whatever JSON allowed. A
    # non-string raises TypeError out of expanduser -- uncaught, that takes
    # the whole grid down instead of nulling one tile's field. os.path.exists
    # already shrugs off a NUL inside a string; this covers the other half.
    return (isinstance(marker, str) and bool(marker)
            and os.path.exists(os.path.expanduser(marker)))


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
    # The lock is held ACROSS the docker call on purpose (single-flight):
    # two polls that miss the cache together run one `docker ps`, not two,
    # and the second gets the first's answer. Only callers that actually
    # need the map wait here; nothing else in the server shares this lock.
    with _docker_map_lock:
        if now - _docker_map_cache["at"] < DOCKER_MAP_TTL:
            return _docker_map_cache["map"]
        mapping = _read_docker_names()
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
        # Keys embed the container id, so every recreate leaves an orphan
        # behind. Drop any whose cgroup no longer exists — cheap (one stat
        # per stale key, and there are only ever a few) and bounded.
        for stale in [k for k in _cpu_samples if k != cgroup
                      and not os.path.isdir(k)]:
            _cpu_samples.pop(stale, None)
    if not previous:
        return None
    prev_wall, prev_usage = previous
    wall_usec = (now - prev_wall) * 1e6
    if wall_usec <= 0:
        return None
    pct = (usage_usec - prev_usage) / (wall_usec * (os.cpu_count() or 1)) * 100
    return max(0.0, min(100.0, pct))


def _has_container_part(svc):
    return any(p["kind"] == "container"
               for p in control_parts(control_block(svc)))


def _measure_resources(svc, now, docker_map=None, timer_states=None):
    """One sysfs pass over a service's control parts. Caller holds the lock.

    `docker_map` is the name -> id map and `timer_states` the
    name -> armed map, both fetched by the caller OUTSIDE the resources
    lock (see service_resources) because each can block on a wedged
    subprocess. Left None, they are fetched here on first use, which is
    what the tests do and what a service without such parts never
    triggers.
    """
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
            # `docker ps -a` is authoritative when it answers: a missing
            # name in a non-empty map means the container genuinely does
            # not exist (removed, or an optional part never created) —
            # provably absent. Only an EMPTY map is unknowable, because
            # that is also how 'docker could not answer' comes back.
            if part["name"] in docker_map:
                running = cgroup is not None
            else:
                running = False if docker_map else None
        elif part["name"].endswith(".timer"):
            cgroup = _unit_cgroup(part["name"])
            # A timer owns no cgroup while it is armed; systemd holds the
            # truth. Fetched outside the lock by the caller — fetched here
            # only when a test calls this directly, the same lazy contract
            # docker_map has.
            if timer_states is None:
                timer_states = _timer_states(svc)
            running = timer_states.get(part["name"])
        else:
            cgroup = _unit_cgroup(part["name"])
            running = cgroup is not None
        rss = _read_rss(cgroup) if cgroup else None
        cpu = _cpu_percent(cgroup, _read_usage_usec(cgroup), now) \
            if cgroup else None
        if rss is not None:
            total_rss = rss if total_rss is None else total_rss + rss
        if cpu is not None:
            total_cpu = cpu if total_cpu is None else total_cpu + cpu
        measured.append({"name": part["name"], "kind": part["kind"],
                         "running": running,
                         "rss_bytes": rss, "cpu_pct": cpu})
    if total_cpu is not None:
        total_cpu = max(0.0, min(100.0, total_cpu))
    return {"rss_bytes": total_rss, "cpu_pct": total_cpu,
            "sampled_at": now, "parts": measured}


def service_resources(svc):
    """The `resources` block for one service. Never raises.

    Cached for RESOURCE_TTL under one lock, so a busy grid cannot hammer
    sysfs and two concurrent polls cannot take a CPU sample microseconds
    apart. The one slow thing in the path -- `docker ps`, up to
    DOCKER_MAP_TIMEOUT when the daemon is wedged -- runs OUTSIDE that lock:
    it has its own single-flight cache, and holding the shared lock across
    it would stall every other service's sample and every concurrent list
    request for those seconds. Measurements themselves are sysfs reads and
    take microseconds under the lock.
    """
    key = svc.get("key")
    now = time.time()
    try:
        with _resources_lock:
            hit = _resources_cache.get(key)
            if hit and now - hit[0] < RESOURCE_TTL:
                return hit[1]
        docker_map = docker_name_map() if _has_container_part(svc) else {}
        # Timer probes share the lock-free side of the door with docker:
        # each is-active is a subprocess that can sit on its timeout against
        # a stalled user bus, which must not stall every other service's
        # sample behind _resources_lock.
        timer_states = _timer_states(svc)
        # That call may have blocked for seconds against a wedged daemon. The
        # sample's clock is the moment the cgroups are actually read, never
        # the moment the request arrived: a stale stamp shrinks the wall delta
        # _cpu_percent divides by, which inflates every percentage (a service
        # at 40% reads 100% after a 2s block), and it would stamp the cache
        # entry already-expired whenever the block outlasts RESOURCE_TTL.
        now = time.time()
        with _resources_lock:
            # Re-check: another request may have sampled this service while
            # this one was waiting on docker.
            hit = _resources_cache.get(key)
            if hit and now - hit[0] < RESOURCE_TTL:
                return hit[1]
            payload = _measure_resources(svc, now, docker_map, timer_states)
            _resources_cache[key] = (now, payload)
            return payload
    except Exception as exc:
        # Resource use is the least important thing on this page: it may
        # never be the reason a tile fails to render.
        log("resources unavailable for %s (%s)" % (key, exc))
        return _null_resources(now)


def _timer_active(name):
    """systemctl is-active for a .timer control part: True/False/None.

    A timer owns no cgroup while it is armed, so the resources pass can
    never see one; ActiveState is the only honest signal, and 'active' for
    a polling service IS 'running'. None is 'unknowable' (macOS, no
    systemd, a dead user bus) — the same contract as deployd_timer()."""
    if sys.platform == "darwin":
        return None
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", name],
            capture_output=True, text=True, timeout=5, check=False)
        state = out.stdout.strip()
        if state == "active":
            return True
        if state in ("inactive", "failed"):
            return False
        return None
    except (OSError, subprocess.SubprocessError):
        return None


def _timer_states(svc):
    """{timer_name: True/False/None} for a service's .timer control parts.

    One is-active subprocess per timer — a service with none costs a dict
    scan and returns {}. Meant to run outside the resources lock, like
    docker_name_map.
    """
    return {p["name"]: _timer_active(p["name"])
            for p in control_parts(control_block(svc))
            if p["kind"] == "unit" and p["name"].endswith(".timer")}


def control_running(svc, resources):
    """True/False/None — is any of the service's control parts alive?

    Services and containers answer through the resources pass: a cgroup
    exists only while its part runs. A .timer owns no cgroup while armed,
    so timers ask systemctl directly. A container part that is absent from
    `docker ps -a` is NOT 'stopped' — stopped containers still appear
    there — it means docker could not answer, which is unknowable, same
    as a timer systemctl cannot read. None means nothing could say, so a
    caller can keep a warning it cannot disprove rather than declaring
    'paused'."""
    parts = control_parts(control_block(svc))
    measured = {p["name"]: p for p in resources.get("parts") or []}
    if parts and not measured:
        return None
    docker_map = None
    unknowable = False
    for part in parts:
        if part["kind"] == "unit" and part["name"].endswith(".timer"):
            state = _timer_active(part["name"])
            if state:
                return True
            if state is None:
                unknowable = True
            continue
        if part["kind"] == "container":
            if docker_map is None:
                docker_map = docker_name_map()
            if part["name"] not in docker_map:
                # Absent from an ANSWERED ps -a means the container truly
                # does not exist (an optional part never created, or one
                # docker rm'd) — provably absent, same as a missing
                # cgroup. Absent from an EMPTY map means docker never
                # answered at all, which is unknowable.
                if not docker_map:
                    unknowable = True
                continue
        entry = measured.get(part["name"])
        if entry and entry.get("running"):
            return True
    if unknowable or not parts:
        return None
    return False


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
    except (OSError, TypeError, ValueError):
        # A registry is hand-edited, so `marker` is whatever JSON allowed: a
        # number raises TypeError out of expanduser and a string with a NUL
        # raises ValueError, and either one uncaught here 500s the whole grid
        # rather than nulling one field. marker_exists() already shrugs both
        # off via genericpath; this is the same shrug.
        return None



# ------------------------------------------------------------------ box health

# The home page's health strip: memory, the disk ~/services lives on, load
# and uptime. Every reader answers None rather than raising, because the
# strip is the least important thing on the page and must never 500 the
# payload the app list depends on. /proc is Linux-only; macOS gets total
# memory (sysconf works there), disk, load and CPU count, and nulls for the
# rest, which the page shows as "not available".
MEMINFO_PATH = "/proc/meminfo"
UPTIME_PATH = "/proc/uptime"
SYSTEM_DISK_PATH = os.path.expanduser("~")


def _meminfo():
    """{"total", "available"} in bytes from /proc/meminfo, or None.

    MemAvailable is the kernel's own estimate of what can be handed out
    without swapping, which is what "how full is this box" means; MemFree
    leaves out reclaimable cache and makes every Linux box look full."""
    try:
        fields = {}
        with open(MEMINFO_PATH, encoding="ascii", errors="replace") as fh:
            for line in fh:
                name, _, rest = line.partition(":")
                parts = rest.split()
                if parts and parts[0].isdigit():
                    fields[name.strip()] = int(parts[0]) * 1024
        total, avail = fields.get("MemTotal"), fields.get("MemAvailable")
        if total and avail is not None:
            return {"total": total, "available": min(avail, total)}
    except OSError:
        pass
    try:
        total = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        if total > 0:
            return {"total": total, "available": None}
    except (AttributeError, OSError, ValueError):
        pass
    return None


def _mount_of(path):
    """The mount point holding `path` (walked up, never entered)."""
    path = os.path.realpath(path)
    while not os.path.ismount(path):
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return path


def _disk(path):
    """{"mount", "total", "used", "free"} for the filesystem under `path`."""
    try:
        usage = shutil.disk_usage(path)
    except (OSError, ValueError):
        return None
    if usage.total <= 0:
        return None
    return {"mount": _mount_of(path), "total": usage.total,
            "used": usage.used, "free": usage.free}


def _loadavg():
    try:
        return [round(v, 2) for v in os.getloadavg()]
    except (AttributeError, OSError):
        return None


def _uptime():
    try:
        with open(UPTIME_PATH, encoding="ascii") as fh:
            return float(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def system_stats():
    """The health strip's numbers. Keys are always present, null when the
    platform cannot say, the same contract as the per-service v3 keys."""
    return {
        "memory": _meminfo(),
        "disk": _disk(SYSTEM_DISK_PATH),
        "load": _loadavg(),
        "cpus": os.cpu_count(),
        "uptime_s": _uptime(),
    }

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
    updates = load_updates()

    services = []
    for svc in registry:
        health = svc.get("health")
        resources = service_resources(svc)
        if health:
            active = bool(probes.get(health, False))
            # A failed probe is only alarming while the thing still runs:
            # live parts mean "up but not answering". None (nothing to
            # check with — ntfy, ollama) keeps the warning it cannot
            # disprove rather than muting a real outage.
            degraded = (not active
                        and control_running(svc, resources) is not False)
        else:
            # No probe at all: a live control part is the only "alive"
            # signal. An armed timer counts, so deployd stops reading as
            # down for doing its job.
            active = control_running(svc, resources) is True
            degraded = False
        receipt = load_receipt(svc.get("key"))
        installed = ((active or marker_exists(svc.get("marker")))
                     and not is_removed(receipt, active))
        name, description = effective(svc, overrides)
        gid = svc.get("group")
        services.append({
            "key": svc.get("key"),
            "name": name,
            "tagline": svc.get("tagline"),
            # Bucket id from the file-level `groups` list. Always present,
            # null when the registry row has none — same null-safety as the
            # v3 keys, so an older services.json still paints a flat grid.
            "group": gid if isinstance(gid, str) and gid else None,
            # Carried on the list too, not just the detail page: the grid's
            # hover tooltip needs it, and without it here that module had to
            # fetch every service individually just to show one bubble.
            "description": description,
            # Owner of the service's remote repo — drives the 'c-wenlong'
            # tab. Always present, null when the registry row has none.
            "author": svc.get("author"),
            "icon": svc.get("icon"),
            "url": substitute_host(svc.get("url"), host),
            "state": derive_state(svc.get("setup"), installed, active),
            "installed": installed,
            "active": active,
            # Whether a stopped-looking tile is actually in trouble — a
            # health probe failed while parts are provably (or unknowably)
            # alive. The UI paints "down" only for this; an installed but
            # stopped service is a muted "paused" instead.
            "degraded": degraded,
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
            "resources": resources,
            # The install receipt (see write_receipt), for the catalogue
            # page's "installed on" line. null when there is none, which is
            # normal for anything deployed from a terminal.
            "receipt": receipt,
            # Whether the Remove action is on offer (a teardown.sh exists and
            # the service is controllable). Never offers --purge.
            "removable": removable(svc),
            # {available, checked_at} from the last image check, or null
            # when it has not been checked (or is not installed).
            "updates": (update_summary(updates.get(svc.get("key")))
                        if installed else None),
            # true for machinery with a page of its own rather than a row in
            # the app list (deployd: the Deploys page). Always present; only
            # a JSON true hides. Appended last, like every key after v1.
            "hidden": svc.get("hidden") is True,
        })
    return {"host": host, "groups": load_groups(), "services": services,
            "system": system_stats()}


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
    resources = service_resources(svc)
    # Same derivation as the grid: a probe decides when one exists, a live
    # control part decides when it does not, and `degraded` tells a stopped
    # service that is still running from one that is just off.
    if health:
        active = bool(probes.get(health, False))
        degraded = (not active
                    and control_running(svc, resources) is not False)
    else:
        active = control_running(svc, resources) is True
        degraded = False
    receipt = load_receipt(key)
    installed = ((active or marker_exists(svc.get("marker")))
                 and not is_removed(receipt, active))
    overrides = load_overrides()
    name, description = effective(svc, overrides)
    edited = sorted(overrides.get(key, {}))

    return {
        "key": svc.get("key"),
        "name": name,
        "tagline": svc.get("tagline"),
        "group": (svc.get("group") if isinstance(svc.get("group"), str)
                  and svc.get("group") else None),
        "icon": svc.get("icon"),
        "url": substitute_host(svc.get("url"), host),
        "state": derive_state(svc.get("setup"), installed, active),
        "installed": installed,
        "active": active,
        "degraded": degraded,
        "job": jobs_by_key().get(key),
        "control": control_status(svc),
        "usage": usage_entry(load_usage(), key),
        "deployed_at": deployed_at(svc.get("marker")),
        "resources": resources,
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
        "receipt": receipt,
        "removable": removable(svc),
        "updates": update_detail(svc, installed),
    }


# ------------------------------------------------------------------ github apps
#
# Apps built straight from a GitHub repo's Dockerfile (app/web/ghapp.py does
# the building). Each is one definition in ~/services/launcher/apps/<key>.json,
# written here and never by hand, merged into the registry by load_registry()
# so the list, detail page, start/stop, Remove and the .env editor all work
# through the same code as a service from this repo. A push to the watched
# branch redeploys through deployd: creating an app also writes a custom
# state/pollers.json entry whose cmd is `app/web/ghapp.py deploy <key>`.
#
#   GET    api/github/repos           the box's `gh` login's repos
#   POST   api/github/inspect         {repo, ref?} -> branches, Dockerfile, port
#   POST   api/apps                   create + first deploy (202, job id)
#   DELETE api/apps/{key}             forget a removed app (keeps its data)

GHAPP_SCRIPT = os.path.join(HERE, "ghapp.py")
GHAPP_GROUP = {"id": "github", "label": "From GitHub"}
# Local port == HTTPS (Serve) port, one per app, from this block. Nothing in
# DIRECTORY.md lives here; the allocator still checks what is actually taken.
GHAPP_PORTS = range(8300, 8400)
GH_CACHE_TTL = 120.0
_EXPOSE_RE = re.compile(r"^\s*EXPOSE\s+(\d{1,5})", re.I | re.M)
_ghapp_lock = threading.Lock()
_gh_cache = {}


def _ghapp_defs():
    """Valid definitions from the apps dir, sorted by key. A bad file is
    logged and skipped: one broken definition must not empty the list."""
    try:
        names = sorted(n for n in os.listdir(ghapp.DEFS_DIR) if n.endswith(".json"))
    except OSError:
        return []
    out = []
    for name in names:
        try:
            out.append(ghapp.load(name[:-5]))
        except ghapp.AppError as exc:
            log("github app %s skipped: %s" % (name, exc))
    return out


def ghapp_entries():
    """Registry-shaped entries for the GitHub apps. The URL keeps the HOST
    placeholder services.json uses, so substitute_host fills it in."""
    entries = []
    for d in _ghapp_defs():
        key = d["key"]
        owner = d["repo"].split("/", 1)[0]
        entries.append({
            "key": key,
            "name": d.get("name") or key,
            "tagline": d.get("tagline") or "From GitHub",
            "group": GHAPP_GROUP["id"],
            "description": "Built on this box from github.com/%s (%s) with its "
                           "%s, redeployed when that branch moves."
                           % (d["repo"], d["ref"], d["dockerfile"]),
            "author": owner,
            "icon": "code",
            "url": "https://HOST:%d/" % d["port"],
            "health": "http://127.0.0.1:%d%s" % (d["port"], d["health_path"]),
            "marker": os.path.join(ghapp.app_dir(key), "deployed.json"),
            # Shown by the detail page's env editor; every read and write
            # goes through env_path(), which derives it from the key.
            "env": "~/services/apps/%s/.env" % key,
            "runner": "ghapp",
            "setup": "app/web/ghapp.py",
            "github": {"repo": d["repo"], "ref": d["ref"]},
            "control": {"parts": [{"container": ghapp.container_name(key)}]},
        })
    return entries


def runner_args(svc, verb):
    """Extra argv words for a service's deploy/remove script: [] for a
    setup.sh, [verb, key] for a GitHub app. Registry words only."""
    if svc.get("runner") != "ghapp":
        return []
    key = svc.get("key")
    if not isinstance(key, str) or not ghapp.KEY_RE.match(key):
        raise DeployError(400, "bad app key")
    return [verb, key]


def _port_free(port):
    """True if nothing on this box listens on 127.0.0.1:port right now."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def _registry_ports():
    """Every port number a registry URL or health probe mentions."""
    ports = set()
    for svc in load_registry():
        for field in ("url", "health"):
            m = re.search(r":(\d{2,5})(?:/|$)", str(svc.get(field) or ""))
            if m:
                ports.add(int(m.group(1)))
    return ports


def allocate_port():
    """First port in GHAPP_PORTS no service, app, Serve handler or listener
    already has. 409 when the block is full."""
    taken = _registry_ports()
    serve = ghapp.serve_ports() or {}
    taken.update(int(p) for p in serve if str(p).isdigit())
    for port in GHAPP_PORTS:
        if port not in taken and _port_free(port):
            return port
    raise DeployError(409, "no free port left in %d-%d"
                      % (GHAPP_PORTS[0], GHAPP_PORTS[-1]))


def _gh_bin():
    found = _which("gh")
    if found:
        return found
    for candidate in ("~/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        path = os.path.expanduser(candidate)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def gh_api(path, cache=True):
    """`gh api <path>` -> parsed JSON, or raise DeployError. Path words are
    built here from shape-checked values only."""
    gh = _gh_bin()
    if not gh:
        raise DeployError(503, "the gh CLI is not installed on this box")
    now = time.monotonic()
    hit = _gh_cache.get(path)
    if cache and hit and now - hit[0] < GH_CACHE_TTL:
        return hit[1]
    try:
        res = subprocess.run([gh, "api", path], capture_output=True, text=True,
                             timeout=20, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise DeployError(502, "gh api failed: %s" % exc)
    if res.returncode != 0:
        msg = (res.stderr or res.stdout or "").strip().splitlines()
        msg = msg[-1] if msg else "exit %d" % res.returncode
        if "404" in msg or "Not Found" in msg:
            raise DeployError(404, "not found on GitHub: %s" % path.split("?")[0])
        if "auth" in msg.lower() or "401" in msg:
            raise DeployError(503, "gh is not logged in on this box (run `gh auth login`)")
        raise DeployError(502, "gh api: %s" % msg[:200])
    try:
        data = json.loads(res.stdout or "null")
    except ValueError:
        raise DeployError(502, "gh api returned something that is not JSON")
    _gh_cache[path] = (now, data)
    return data


def github_repos():
    """The login's repos, most recently pushed first."""
    data = gh_api("user/repos?per_page=100&sort=pushed"
                  "&affiliation=owner,collaborator,organization_member")
    out = []
    for r in data if isinstance(data, list) else []:
        name = r.get("full_name")
        if not isinstance(name, str) or not ghapp.REPO_RE.match(name):
            continue
        out.append({"repo": name, "private": bool(r.get("private")),
                    "default_branch": r.get("default_branch") or "main",
                    "description": (r.get("description") or "")[:200],
                    "pushed_at": r.get("pushed_at"),
                    "archived": bool(r.get("archived"))})
    return {"repos": out}


def _check_repo(repo):
    if not isinstance(repo, str) or not ghapp.REPO_RE.match(repo):
        raise DeployError(400, "repo must look like owner/name")
    return repo


def _check_ref(ref):
    if not isinstance(ref, str) or not ghapp.REF_RE.match(ref) or ref.startswith("-"):
        raise DeployError(400, "branch name is not valid")
    return ref


def suggest_key(repo):
    base = re.sub(r"[^a-z0-9-]+", "-", repo.split("/", 1)[1].lower()).strip("-")
    base = (base or "app")[:28].strip("-")
    if len(base) < 3:
        base = (base + "-app")[:28]
    taken = {s.get("key") for s in load_registry()}
    key, n = base, 2
    while key in taken:
        key = "%s-%d" % (base, n)
        n += 1
    return key


def github_inspect(body):
    """{repo, ref?} -> branches, whether the Dockerfile exists at that ref,
    the port its first EXPOSE names, and a free key to suggest."""
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    repo = _check_repo(body.get("repo"))
    meta = gh_api("repos/%s" % repo)
    ref = body.get("ref") or meta.get("default_branch") or "main"
    _check_ref(ref)
    branches = gh_api("repos/%s/branches?per_page=100" % repo)
    names = [b.get("name") for b in branches if isinstance(b, dict)
             and isinstance(b.get("name"), str)] if isinstance(branches, list) else []
    dockerfile, port = False, None
    try:
        f = gh_api("repos/%s/contents/Dockerfile?ref=%s"
                   % (repo, urllib.parse.quote(ref, safe="")), cache=False)
        dockerfile = isinstance(f, dict) and f.get("type") == "file"
        if dockerfile and f.get("encoding") == "base64":
            import base64
            text = base64.b64decode(f.get("content") or "").decode("utf-8", "replace")
            m = _EXPOSE_RE.search(text)
            port = int(m.group(1)) if m and 0 < int(m.group(1)) < 65536 else None
    except DeployError as exc:
        if exc.status != 404:
            raise
    return {"repo": repo, "ref": ref, "branches": names[:100],
            "default_branch": meta.get("default_branch") or "main",
            "private": bool(meta.get("private")),
            "dockerfile": dockerfile, "container_port": port,
            "key": suggest_key(repo)}


def _int_field(body, field, default=None):
    v = body.get(field, default)
    if isinstance(v, str) and v.strip().isdigit():
        v = int(v.strip())
    if not isinstance(v, int) or isinstance(v, bool) or not 1 <= v <= 65535:
        raise DeployError(400, "%s must be a port number" % field)
    return v


def _env_text(raw):
    """The create form's KEY=value lines -> .env text, or raise 400."""
    if raw in (None, ""):
        return ""
    if not isinstance(raw, str) or len(raw) > 16384:
        raise DeployError(400, "env must be text (max 16 KB)")
    lines = []
    for n, line in enumerate(raw.replace("\r\n", "\n").split("\n"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        name, sep, value = s.partition("=")
        if not sep or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name.strip()):
            raise DeployError(400, "env line %d is not KEY=value" % n)
        lines.append("%s=%s" % (name.strip(), value.strip()))
    return "\n".join(lines) + ("\n" if lines else "")


def create_app(body):
    """Write a definition, its .env and its deploy poller, then start the
    first deploy. Returns {key, job_id}."""
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    repo = _check_repo(body.get("repo"))
    ref = _check_ref(body.get("ref") or "main")
    key = body.get("key")
    if not isinstance(key, str) or not ghapp.KEY_RE.match(key):
        raise DeployError(400, "key must be 3-32 lowercase letters, digits or dashes")
    name = clean_field("name", body.get("name") or key, 60, False) or key
    tagline = clean_field("tagline", body.get("tagline") or "From GitHub", 40, False)
    health = body.get("health_path") or "/"
    volume = body.get("volume") or None
    env_text = _env_text(body.get("env"))
    with _ghapp_lock:
        if find_service(key) is not None:
            raise DeployError(409, "%s already exists" % key)
        d = {"version": 1, "key": key, "name": name, "tagline": tagline,
             "repo": repo, "ref": ref,
             "dockerfile": body.get("dockerfile") or "Dockerfile",
             "context": body.get("context") or ".",
             "container_port": _int_field(body, "container_port"),
             "port": allocate_port(),
             "health_path": health, "volume": volume,
             "created_at": _now_iso()}
        try:
            ghapp.validate(d)
        except ghapp.AppError as exc:
            raise DeployError(400, str(exc))
        os.makedirs(ghapp.app_dir(key), exist_ok=True)
        env_file = os.path.join(ghapp.app_dir(key), ".env")
        if not os.path.exists(env_file):
            fd = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(env_text)
        os.makedirs(ghapp.DEFS_DIR, exist_ok=True)
        _write_json_atomically(ghapp.def_path(key), d, ".app.")
    auto = True
    # Paused until the first deploy succeeds (ghapp clears the marker and
    # records the sha), so deployd never races the launcher's own first run.
    try:
        ghapp.set_paused(key, True)
    except OSError as exc:
        log("github app %s: could not pause its poller: %s" % (key, exc))
    try:
        deployd_upsert_poller(key, {"repo": ghapp.clone_url(repo), "ref": ref,
                                    "cmd": "app/web/ghapp.py deploy %s" % key})
    except Exception as exc:          # deployd not installed: still deployable
        log("github app %s: no deploy poller (%s)" % (key, exc))
        auto = False
    return {"key": key, "port": d["port"], "auto_deploy": auto,
            "job_id": start_deploy(key)}


def delete_app(key):
    """Forget a GitHub app: its definition and its poller. Refused while it
    is installed (Remove it first, which stops it and drops its Serve port).
    ~/services/apps/<key> stays, as every Remove here keeps data."""
    svc = find_service(key)
    if svc is None or svc.get("runner") != "ghapp":
        raise DeployError(404, "no GitHub app called %s" % key)
    if marker_exists(svc.get("marker")):
        raise DeployError(409, "%s is still installed: Remove it first" % key)
    if jobs_by_key().get(key, {}).get("status") == "running":
        raise DeployError(409, "a job is running for %s" % key)
    # The runner's own per-app lock covers a deploy deployd started too; held
    # while the definition goes, a deploy that starts after re-reads it under
    # the same lock and stops.
    with _ghapp_lock:
        try:
            with ghapp.Lock(key):
                os.remove(ghapp.def_path(key))
        except ghapp.AppError:
            raise DeployError(409, "a deploy of %s is running: try again when it ends" % key)
        except OSError as exc:
            raise DeployError(500, "could not delete the definition: %s" % exc)
    try:
        deployd_remove_poller(key)
    except DeployError:
        pass
    return {"key": key, "kept": ghapp.app_dir(key)}

# ---- deployd

# deployd writes ANSI-coloured setup.sh output into <key>.log; the detail
# page shows the tail as plain text.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
DEPLOYD_LOG_TAIL = 40      # lines shown per watched service
DEPLOYD_LOG_BYTES = 65536  # never read a whole deploy log into the payload


def _deployd_env():
    """deployd's .env, decoded the way its own load_env() decodes it:
    KEY=value lines, values shlex-split so setup.sh's %q-escaped paths
    (SERVICE_HOME=/home/u/deploy\\ state) come back real."""
    env = {}
    try:
        with open(os.path.join(REPO_ROOT, "services", "deployd", ".env"),
                  encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                try:
                    parts = shlex.split(raw)
                    env[key.strip()] = parts[0] if parts else ""
                except ValueError:
                    env[key.strip()] = raw
    except OSError:
        pass
    return env


def _deployd_state_dir(env):
    """deployd's state dir: $SERVICE_HOME/state when its .env sets one."""
    return os.path.join(env.get("SERVICE_HOME") or DEPLOYD_HOME, "state")


_POLLER_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


def _deployd_overrides(state_dir):
    """Raw {key: spec} from state/pollers.json — the UI's edit layer.
    Anything unreadable or malformed comes back empty: deployd applies the
    same fail-closed rule, so what this returns is what it would run."""
    path = os.path.join(state_dir, "pollers.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    pollers = data.get("pollers") if isinstance(data, dict) else None
    if not isinstance(pollers, dict):
        return {}
    return {k: v for k, v in pollers.items()
            if isinstance(k, str) and _POLLER_KEY_RE.match(k)
            and isinstance(v, dict)}


def _deployd_scan(setup_repo, state_dir):
    """Mirror of deployd's scan_entries(): ([entries], [suppressed]).

    Kept as a line-faithful copy rather than an import — server.py must not
    exec the poller for a read, and this repo ships both so they cannot
    drift in a deploy. test_server.py's parity check compares the two
    implementations on the same fixtures.

    Each entry carries `source`: 'manifest', 'override' (a pollers.json
    definition over a manifest key) or 'custom' (no manifest). A manifest
    enabled:false is a hard off: the key lands in `suppressed` with
    by='manifest' and overrides for it lose."""
    entries = []
    suppressed = []
    seen = {}
    hard_off = set()
    svc_root = os.path.join(setup_repo, "services")
    try:
        names = sorted(os.listdir(svc_root))
    except OSError:
        names = []
    for name in names:
        path = os.path.join(svc_root, name, "app.json")
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        deploy = data.get("deploy") if isinstance(data, dict) else None
        if not isinstance(deploy, dict):
            continue
        key = data.get("key")
        key = key if isinstance(key, str) and key else name
        if deploy.get("enabled") is False:
            hard_off.add(key)
            suppressed.append({
                "key": key, "by": "manifest",
                "repo": deploy.get("repo"),
                "ref": deploy.get("ref") or "main",
                "cmd": deploy.get("cmd"),
            })
            continue
        repo, cmd = deploy.get("repo"), deploy.get("cmd")
        ref = deploy.get("ref") or "main"
        if not isinstance(repo, str) or not repo \
                or not isinstance(cmd, str) or not cmd \
                or not isinstance(ref, str):
            continue
        seen[key] = len(entries)
        entries.append({"key": key, "repo": repo, "ref": ref, "cmd": cmd,
                        "source": "manifest"})
    for key, spec in _deployd_overrides(state_dir).items():
        if key in hard_off:
            continue
        if spec.get("enabled") is False:
            if key in seen:
                old = entries.pop(seen[key])
                suppressed.append({"key": key, "by": "override",
                                   "repo": old["repo"], "ref": old["ref"],
                                   "cmd": old["cmd"]})
                seen = {e["key"]: i for i, e in enumerate(entries)}
            continue
        repo, cmd = spec.get("repo"), spec.get("cmd")
        ref = spec.get("ref") or "main"
        if not isinstance(repo, str) or not repo \
                or not isinstance(cmd, str) or not cmd \
                or not isinstance(ref, str):
            continue
        entry = {"key": key, "repo": repo, "ref": ref, "cmd": cmd,
                 "source": "override" if key in seen else "custom"}
        if key in seen:
            entries[seen[key]] = entry
        else:
            seen[key] = len(entries)
            entries.append(entry)
    return entries, suppressed


def deployd_timer():
    """`systemctl --user is-active deployd.timer` verbatim, or None.

    None means unknowable from here — no systemd (macOS), no unit, dbus
    down — and the UI shows a muted "unknown" rather than pretending the
    poller is off. Never raises: this runs on every detail-page poll.
    """
    if sys.platform == "darwin":
        return None
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", "deployd.timer"],
            capture_output=True, text=True, timeout=5, check=False)
        state = out.stdout.strip()
        return state or None
    except (OSError, subprocess.SubprocessError):
        return None


def _deployd_log_tail(path):
    """Last DEPLOYD_LOG_TAIL lines of a <key>.log, ANSI stripped."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > DEPLOYD_LOG_BYTES:
                fh.seek(-DEPLOYD_LOG_BYTES, os.SEEK_END)
            raw = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    lines = _ANSI_RE.sub("", raw).splitlines()
    return "\n".join(lines[-DEPLOYD_LOG_TAIL:])


def _deployd_entry(state_dir, watched):
    """One watched service's row for the payload, from its state triplet.

    `sha` None means never deployed, `fail` is the backoff record
    verbatim."""
    key = watched["key"]
    base = os.path.join(state_dir, re.sub(r"[^A-Za-z0-9._-]", "_", key))
    sha = fail = None
    try:
        with open(base + ".sha", encoding="utf-8") as fh:
            sha = fh.read().strip() or None
    except OSError:
        pass
    try:
        with open(base + ".fail", encoding="utf-8") as fh:
            data = json.load(fh)
        fail = ({"sha": data.get("sha"), "at": data.get("at"),
                 "rc": data.get("rc")} if isinstance(data, dict) else {})
    except ValueError:
        fail = {}  # present but unreadable: still a failure state
    except OSError:
        pass  # absent: no recorded failure
    disabled = os.path.exists(base + ".disabled")
    log_tail = _deployd_log_tail(base + ".log")
    try:
        log_mtime = os.path.getmtime(base + ".log")
    except OSError:
        log_mtime = None
    if disabled:
        state = "disabled"
    elif fail is not None:
        state = "failed"
    elif sha:
        state = "deployed"
    else:
        state = "pending"  # watched, never deployed
    return {
        "key": key,
        "repo": watched["repo"],
        "ref": watched["ref"],
        "cmd": watched.get("cmd"),
        "source": watched.get("source") or "manifest",
        "sha": sha,
        "fail": fail,
        "disabled": disabled,
        "state": state,
        "log": log_tail,
        "log_mtime": log_mtime,
    }


def deployd_payload():
    """Everything the deployd detail page shows.

    `watched` comes from the same manifests deployd scans — the checkout
    its .env names, not necessarily the one this launcher serves — so the
    table is what the poller actually polls. A state file for a key that
    left the manifests is reported under `orphans` so it can be cleaned
    up."""
    env = _deployd_env()
    state_dir = _deployd_state_dir(env)
    watched, suppressed = _deployd_scan(
        env.get("SETUP_REPO") or REPO_ROOT, state_dir)
    known = {w["key"] for w in watched} | {s["key"] for s in suppressed}
    orphans = []
    try:
        for name in sorted(os.listdir(state_dir)):
            key, dot, ext = name.rpartition(".")
            if dot and ext == "sha" and key not in known:
                orphans.append(key)
    except OSError:
        pass
    return {
        "installed": os.path.isdir(state_dir),
        "timer": deployd_timer(),
        "self_update_pending": os.path.exists(
            os.path.join(state_dir, "self-update.pending")),
        "launcher_restart_pending": os.path.exists(
            os.path.join(state_dir, "launcher-restart.pending")),
        "state_dir": state_dir,
        "watched": [_deployd_entry(state_dir, w) for w in watched],
        "suppressed": suppressed,
        "orphans": orphans,
    }


# ---- deployd poller management
#
# CRUD never writes services/*/app.json: that checkout is ff-pulled by
# deployd every tick, so an uncommitted edit would wedge the pull and the
# UI would break the thing it manages. Everything lands in
# state/pollers.json, which deployd's own scan_entries() merges over the
# manifests (manifest enabled:false always wins). `cmd` is arbitrary shell
# run as this user — same trust as the deploy blocks already in the repo,
# which is why this is tailnet-only with no narrower auth.

_deployd_pollers_lock = threading.Lock()


def _deployd_check_key(key):
    if not isinstance(key, str) or not _POLLER_KEY_RE.match(key):
        raise DeployError(400, "bad poller key")


def _deployd_lookup(key):
    """(env, state_dir, entry|None, suppressed|None) for one key."""
    env = _deployd_env()
    state_dir = _deployd_state_dir(env)
    entries, suppressed = _deployd_scan(
        env.get("SETUP_REPO") or REPO_ROOT, state_dir)
    entry = next((e for e in entries if e["key"] == key), None)
    sup = next((s for s in suppressed if s["key"] == key), None)
    return env, state_dir, entry, sup


def _deployd_write_overrides(state_dir, pollers):
    _write_json_atomically(os.path.join(state_dir, "pollers.json"),
                           {"version": 1, "pollers": pollers},
                           ".pollers.")


def deployd_upsert_poller(key, body):
    """Create a custom poller or lay an override over a manifest one."""
    _deployd_check_key(key)
    if not isinstance(body, dict):
        raise DeployError(400, "body must be a JSON object")
    env, state_dir, entry, sup = _deployd_lookup(key)
    if sup and sup["by"] == "manifest":
        raise DeployError(409, "%s is disabled in app.json" % key)
    repo = clean_field("repo", body.get("repo"), 512, False)
    ref = clean_field("ref", body.get("ref") or "main", 128, False)
    cmd = clean_field("cmd", body.get("cmd"), 2048, True)
    if not repo or not cmd:
        raise DeployError(400, "repo and cmd are required")
    with _deployd_pollers_lock:
        pollers = _deployd_overrides(state_dir)
        pollers[key] = {"repo": repo, "ref": ref, "cmd": cmd}
        _deployd_write_overrides(state_dir, pollers)
    return deployd_payload()


def deployd_remove_poller(key):
    """Take a poller off the watch list: a tombstone over a manifest-backed
    one (the repo stays the source of truth and can be restored to), or a
    plain row-delete for a custom one, which has nothing to fall back to."""
    _deployd_check_key(key)
    env, state_dir, entry, sup = _deployd_lookup(key)
    if sup and sup["by"] == "manifest":
        raise DeployError(409, "%s is disabled in app.json" % key)
    if entry is None:
        raise DeployError(404, "unknown poller")
    with _deployd_pollers_lock:
        pollers = _deployd_overrides(state_dir)
        if entry["source"] == "custom":
            pollers.pop(key, None)
        else:
            pollers[key] = {"enabled": False}
        _deployd_write_overrides(state_dir, pollers)
    return deployd_payload()


def deployd_restore_poller(key):
    """Drop the pollers.json row entirely: a manifest definition resurfaces,
    a custom poller simply disappears."""
    _deployd_check_key(key)
    _, state_dir, _, _ = _deployd_lookup(key)
    with _deployd_pollers_lock:
        pollers = _deployd_overrides(state_dir)
        pollers.pop(key, None)
        _deployd_write_overrides(state_dir, pollers)
    return deployd_payload()


def deployd_pause_poller(key, paused):
    """The <key>.disabled marker — teardown.sh's knob, now also the UI's."""
    _deployd_check_key(key)
    _, state_dir, entry, _ = _deployd_lookup(key)
    if entry is None:
        raise DeployError(404, "unknown poller")
    path = os.path.join(
        state_dir, re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".disabled")
    if paused:
        try:
            os.makedirs(state_dir, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("paused via launcher\n")
        except OSError as exc:
            raise DeployError(500, "could not pause: %s" % exc)
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise DeployError(500, "could not resume: %s" % exc)
    return deployd_payload()


def start_deployd_force(key):
    """`deployd --force <key>` as a tracked job — the poller's own code
    path, so the same lock serialises it against a running tick."""
    _deployd_check_key(key)
    env = _deployd_env()
    service_home = env.get("SERVICE_HOME") or DEPLOYD_HOME
    state_dir = os.path.join(service_home, "state")
    entries, _ = _deployd_scan(env.get("SETUP_REPO") or REPO_ROOT, state_dir)
    if not any(e["key"] == key for e in entries):
        raise DeployError(404, "unknown poller")
    bin_path = os.path.join(service_home, "bin", "deployd")
    if not os.path.isfile(bin_path):
        raise DeployError(404, "deployd is not installed on this box")
    job = register_job(key, "deploy")
    job_id, log_path = job["id"], job["log_path"]
    # No frozen job["source"]: _reap's receipt write must take the real
    # source (repo, revision, setup) itself or a successful force would
    # overwrite the service's receipt with nulls.
    argv = [bin_path, "--force", key]
    try:
        logfile = open(log_path, "wb", buffering=0)
        logfile.write(("$ %s\n" % " ".join(argv)).encode())
        proc = subprocess.Popen(
            argv, stdout=logfile, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, shell=False)
    except Exception as exc:
        with _jobs_lock:
            job["status"] = "failed"
            job["exit_code"] = -1
            job["finished"] = time.time()
        log("deployd force %s (%s) failed to start: %s" % (job_id, key, exc))
        raise DeployError(500, "could not start deployd")
    log("deployd force %s started: %s" % (job_id, key))
    threading.Thread(target=_reap, args=(job, proc, logfile),
                     daemon=True).start()
    return job_id


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

    path = env_path(svc)                       # allowed-roots gate: 403
    literal = is_docker_env(svc)
    if literal and value != value.strip():
        raise DeployError(400, "value cannot start or end with whitespace")
    rendered = value if literal else quote_env_value(value)   # 400

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
        if parse_env(new_text, literal=literal).get(var) != value:
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
    if svc.get("runner") == "ghapp":
        if not os.path.isfile(GHAPP_SCRIPT):
            raise DeployError(404, "ghapp.py not found")
        return GHAPP_SCRIPT
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


def build_command(script, args=()):
    """argv for running a deploy script, as a list — never a shell string.

    `args` are registry words only (a stop_guard's flags), never request data.
    """
    if os.access(script, os.X_OK):
        direct = [script]
    else:
        direct = ["/bin/bash", script]
    return sg_docker(direct + list(args))


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
    # What is about to run, frozen now: a pull or a registry edit while the
    # deploy runs must not change which revision and script the receipt names.
    job["source"] = deploy_source(svc, script)

    argv = build_command(script, runner_args(svc, "deploy"))
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
    if code == 0:
        # Best effort: a receipt that cannot be written must not turn a
        # successful deploy into a failed job.
        previous = load_receipt(job["key"])
        try:
            write_receipt(job["key"], job["id"], job.get("source"))
        except Exception as exc:
            log("receipt for %s not written: %s" % (job["key"], exc))
        if previous and previous.get("removed_at"):
            _resume_after_reinstall(job)
    _finish(job, code)


# ------------------------------------------------------------------ receipts
#
# ~/services/launcher/instances/<key>.json, the "instance" layer of
# docs/catalogue-architecture.md. Written on every successful deploy:
#
#   {"version": 1, "key": "immich", "repo": "~/dev/setup-server",
#    "revision": "<40-hex commit or null>", "setup": "services/immich/setup.sh",
#    "data_dir": "~/services/immich", "ports": {"LOCAL_PORT": 2283},
#    "installed_at": first success, "deployed_at": latest success,
#    "deploys": count, "last_job": job id}
#
# The revision is read straight from .git rather than by running git: no
# subprocess, and nothing to put on the unit's PATH.

RECEIPT_VERSION = 1
_RECEIPT_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_receipts_lock = threading.Lock()


def _read_text(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def _git_root(path):
    """The nearest directory at or above `path` that holds a .git, or None."""
    current = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def git_revision(root):
    """HEAD of the checkout at `root` as a 40-hex sha, or None.

    Handles a normal checkout, a worktree (.git is a "gitdir:" file whose refs
    live in the common dir), a detached HEAD, and refs only in packed-refs.
    """
    try:
        dot_git = os.path.join(root, ".git")
        gitdir = dot_git
        if os.path.isfile(dot_git):
            line = _read_text(dot_git)
            if not line.startswith("gitdir:"):
                return None
            gitdir = os.path.normpath(os.path.join(root, line[len("gitdir:"):].strip()))
        common = gitdir
        if os.path.isfile(os.path.join(gitdir, "commondir")):
            common = os.path.normpath(os.path.join(
                gitdir, _read_text(os.path.join(gitdir, "commondir"))))
        head = _read_text(os.path.join(gitdir, "HEAD"))
        if not head.startswith("ref:"):
            return head if _SHA_RE.match(head) else None
        ref = head[len("ref:"):].strip()
        for base in (gitdir, common):
            path = os.path.join(base, ref)
            if os.path.isfile(path):
                sha = _read_text(path)
                return sha if _SHA_RE.match(sha) else None
        packed = os.path.join(common, "packed-refs")
        if os.path.isfile(packed):
            with open(packed, "r", encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) == 2 and parts[1] == ref and _SHA_RE.match(parts[0]):
                        return parts[0]
    except (OSError, UnicodeDecodeError):
        return None
    return None


def _collapse_home(path):
    home = os.path.expanduser("~")
    if path == home or path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def _receipt_ports(svc):
    """{NAME: int} for every *_PORT variable in the service's .env.

    Names come off the same parser the detail page uses; a variable that
    looks secret is skipped even if it ends in _PORT, and only whole numbers
    in the TCP range are kept, so nothing sensitive can reach the receipt.
    """
    try:
        env = read_env(svc)
    except DeployError:
        return {}
    ports = {}
    for name, value in env.items():
        if not name.endswith("_PORT") or is_secret(name):
            continue
        text = str(value).strip()
        if text.isdigit() and 0 < int(text) < 65536:
            ports[name] = int(text)
    return ports


def receipt_path(key):
    if not isinstance(key, str) or not _RECEIPT_KEY_RE.match(key):
        return None
    return os.path.join(INSTANCES_DIR, "%s.json" % key)


def load_receipt(key):
    """The service's receipt as a dict, or None if absent or unreadable."""
    path = receipt_path(key)
    if path is None:
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get("key") != key:
        return None
    return doc


def deploy_source(svc, script):
    """Repo, revision, setup and data dir of a deploy, taken as it starts."""
    root = _git_root(os.path.dirname(script))
    return {
        "repo": _collapse_home(root) if root else None,
        "revision": git_revision(root) if root else None,
        "setup": svc.get("setup"),
        "data_dir": svc.get("marker"),
    }


def mark_removed(key):
    """Record that a launcher Remove succeeded: the service is off the box
    but its data is kept. The tile then reads as not installed until a deploy
    writes a fresh receipt (which carries no removed_at)."""
    path = receipt_path(key)
    if path is None:
        raise DeployError(404, "unknown service")
    with _receipts_lock:
        doc = load_receipt(key) or {"version": RECEIPT_VERSION, "key": key}
        doc["removed_at"] = _now_iso()
        _write_json_atomically(path, doc, ".%s." % key)
    return doc


def is_removed(receipt, active):
    """True when a launcher Remove is the latest thing that happened.

    A health probe that answers wins: something brought it back from a
    terminal, and calling a running service "not installed" would be a lie.
    """
    return bool(isinstance(receipt, dict) and receipt.get("removed_at")
                and not active)


def _resume_after_reinstall(job):
    """A Remove paused the service's Kuma monitors; a reinstall resumes them.

    Best effort, but never silent: each monitor's outcome is appended to the
    deploy's job log, so a monitor left paused shows up where the deploy is
    read. One failed resume does not skip the others.
    """
    key = job["key"]
    svc = find_service(key)
    monitors = control_monitors(control_block(svc)) if svc else []
    for monitor in monitors:
        step = kuma_step("resume", monitor)
        if not step:
            continue
        try:
            with open(job["log_path"], "ab", buffering=0) as logfile:
                logfile.write(("$ %s\n" % " ".join(step["argv"])).encode())
                try:
                    proc = subprocess.Popen(step["argv"], stdout=logfile,
                                            stderr=subprocess.STDOUT,
                                            stdin=subprocess.DEVNULL,
                                            env=step["env"])
                    code = proc.wait()
                except Exception as exc:
                    code = -1
                    logfile.write(("could not run: %s\n" % exc).encode())
                if code != 0:
                    logfile.write(("[warning: Kuma monitor %s is still paused "
                                   "(exited %d); resume it in Uptime Kuma]\n"
                                   % (monitor, code)).encode())
                    log("kuma resume of %s for %s exited %d"
                        % (monitor, key, code))
        except OSError as exc:
            log("kuma resume of %s for %s not run: %s" % (monitor, key, exc))


def write_receipt(key, job_id, source=None):
    """Record a successful deploy of `key`. Returns the receipt written.

    `source` is the deploy_source() captured when the job started; without
    one (a caller outside the deploy path) it is taken now. Ports are read
    after the deploy on purpose: setup.sh is what writes them.
    """
    svc = find_service(key)
    path = receipt_path(key)
    if svc is None or path is None:
        raise DeployError(404, "unknown service")
    if source is None:
        source = deploy_source(svc, resolve_script(svc))
    with _receipts_lock:
        previous = load_receipt(key) or {}
        now = _now_iso()
        deploys = previous.get("deploys")
        doc = {
            "version": RECEIPT_VERSION,
            "key": key,
            "repo": source.get("repo"),
            "revision": source.get("revision"),
            "setup": source.get("setup"),
            "data_dir": source.get("data_dir"),
            "ports": _receipt_ports(svc),
            "installed_at": previous.get("installed_at") or now,
            "deployed_at": now,
            "deploys": (deploys if isinstance(deploys, int) and deploys > 0 else 0) + 1,
            "last_job": job_id,
        }
        _write_json_atomically(path, doc, ".%s." % key)
    return doc


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
#     "primary": "immich_server",   # ntfy-control only: which part reports
#                                   # state on the phone panel (default: first);
#                                   # this server never reads it
#     "kuma": "immich",             # monitor paused on stop, resumed on start;
#                                   # a list (["adguard", "adguard-dns"]) when
#                                   # the service has several monitors
#     "stop_guard": ["services/adguard/teardown.sh", "--check-dns"],
#                                   # run before stop (and remove, unless it is
#                                   # the teardown.sh remove runs anyway);
#                                   # non-zero refuses before anything changes
#     "locked": "why this one is deliberately not controllable"
#   }

CONTROL_ACTIONS = ("start", "stop", "restart", "remove")

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


def control_monitors(block):
    """The Kuma monitor names for a service, in order. [] when it has none.

    `kuma` is one name or a list of names (a service with more than one
    monitor, like AdGuard's web UI and its DNS check). Malformed names are
    dropped, the same as malformed parts, and duplicates are kept once.
    """
    raw = block.get("kuma")
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    names = []
    for name in raw:
        if (isinstance(name, str) and _CONTROL_NAME_RE.match(name)
                and name not in names):
            names.append(name)
    return names


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


# A stop_guard's flags go into an argv (and, through sg, a shlex-quoted
# string), so they get the same shape gate as part names. The same pattern
# and the same check live in scripts/build-registry.py and ntfy-control's
# control_listener.py; app/web/tests asserts all three agree on a table.
_GUARD_ARG_RE = re.compile(r"^[A-Za-z0-9._=:/@+-]{1,128}$")

# Seconds a stop_guard may run. It is a read-only check (AdGuard's asks
# `tailscale dns status`), so anything slower is hung: its whole process
# group is killed and the stop refused, rather than the job (and with it
# every later action on the service) waiting forever.
GUARD_TIMEOUT = 30.0


def guard_shape_ok(raw):
    """True when a stop_guard is a non-empty list of non-empty strings whose
    flags (every item after the script) match _GUARD_ARG_RE."""
    return (isinstance(raw, list) and bool(raw)
            and all(isinstance(a, str) and a for a in raw)
            and all(_GUARD_ARG_RE.fullmatch(a) for a in raw[1:]))


def stop_guard(svc):
    """(script, args) of the service's stop_guard, None when it has none.

    The guard is a read-only check that must pass before anything is
    stopped: AdGuard's is `teardown.sh --check-dns`, which fails while the
    tailnet still uses this node as its DNS server. A guard that is present
    but cannot run (malformed, outside the allowed roots, missing) refuses
    the action: skipping it would stop the service it exists to protect.
    """
    block = control_block(svc)
    if "stop_guard" not in block:
        return None
    raw = block.get("stop_guard")
    if not guard_shape_ok(raw):
        raise DeployError(403, "this service's stop_guard is malformed, so "
                               "it cannot be stopped from here")
    script = resolve_registry_path(raw[0], "stop_guard")
    if not os.path.isfile(script):
        raise DeployError(403, "this service's stop_guard (%s) is missing, so "
                               "it cannot be stopped from here" % raw[0])
    return script, raw[1:]


def _guard_step(guard):
    """The guard as the first step of a plan. `guard` marks it so a failure
    skips every later step, even the `always` ones: nothing ran, so there is
    nothing to undo."""
    script, args = guard
    return {"argv": build_command(script, args), "optional": False,
            "always": False, "env": None, "guard": True}


def teardown_script(svc):
    """Absolute path of the teardown.sh beside the service's setup.sh, or None.

    Derived from the registry's setup path only (the same allowed-roots gate
    as a deploy), so nothing about it can come from a request.
    """
    try:
        script = resolve_script(svc)
    except DeployError:
        return None
    if svc.get("runner") == "ghapp":
        return script            # `ghapp.py remove <key>` is its teardown
    path = os.path.join(os.path.dirname(script), "teardown.sh")
    return path if os.path.isfile(path) else None


def removable(svc):
    return bool(control_status(svc)["controllable"] and teardown_script(svc))


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

    A service with several monitors gets one step per monitor (see
    _kuma_steps), so each has its own line in the job log and its own exit
    code.

    Calls the EXISTING services/ntfy-control/kuma_toggle.py — the launcher does not
    talk to Kuma itself, so there is one implementation of "pause a monitor"
    on this box. Everything about this is best-effort: no uv, no toggle
    script, no services/monitoring/.env, or a non-zero exit all leave the lifecycle
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
            cfg.get("kuma_toggle") or "services/ntfy-control/kuma_toggle.py",
            "kuma_toggle")
        env_path = resolve_registry_path(
            cfg.get("kuma_env") or "services/monitoring/.env", "kuma env")
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


def _kuma_steps(action, monitors, on_failure=False):
    """One kuma_step per monitor, skipping any that cannot run."""
    steps = []
    for monitor in monitors:
        step = kuma_step(action, monitor)
        if step:
            if on_failure:
                step["on_failure"] = True
            steps.append(step)
    return steps


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

    Stop runs the service's stop_guard first, before even the Kuma pause.
    Restart does not: it is the usual fix for a stuck service, and for
    AdGuard it costs a few seconds of DNS rather than an outage. Remove runs
    it too, unless the guard is the same teardown.sh that Remove runs (that
    script checks before it changes anything, so a second run adds nothing).
    """
    block = control_block(svc)
    parts = control_parts(block)
    monitors = control_monitors(block)
    guard = stop_guard(svc) if action in ("stop", "remove") else None
    steps = []

    if action == "remove":
        # Pause first, so taking it off the box does not page the phone; a
        # reinstall resumes it (_resume_after_reinstall). Then the service's
        # own teardown.sh, with no arguments: the safe remove that keeps data.
        # --purge is never sent from here; it is terminal-only on purpose.
        teardown = teardown_script(svc)
        if not teardown:
            return []
        if guard and os.path.realpath(guard[0]) != os.path.realpath(teardown):
            steps.append(_guard_step(guard))
        steps.extend(_kuma_steps("pause", monitors))
        steps.append({"argv": build_command(teardown, runner_args(svc, "remove")),
                      "optional": False, "always": False, "env": None})
        # A teardown that fails leaves the service up, so its monitors must
        # not stay paused. Runs only after a failure (see _run_steps).
        steps.extend(_kuma_steps("resume", monitors, on_failure=True))
        return steps

    if guard:
        steps.append(_guard_step(guard))
    if action in ("stop", "restart"):
        steps.extend(_kuma_steps("pause", monitors))
        steps.extend(_part_step(p, "stop") for p in parts)
    if action in ("start", "restart"):
        steps.extend(_part_step(p, "start") for p in reversed(parts))
        steps.extend(_kuma_steps("resume", monitors))
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
        guard = bool(step.get("guard"))
        try:
            # A guard gets its own session so a timeout can kill everything
            # it started (sg, bash, tailscale), not just the first process.
            proc = subprocess.Popen(
                step["argv"], stdout=logfile, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, shell=False, env=step.get("env"),
                cwd=step.get("cwd"),
                **({"start_new_session": True} if guard else {}),
            )
            if not guard:
                return proc.wait()
            try:
                return proc.wait(timeout=GUARD_TIMEOUT)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                proc.wait()
                logfile.write(("[the stop guard ran past %ds and was killed]\n"
                               % GUARD_TIMEOUT).encode())
                return 124
        except Exception as exc:
            logfile.write(("could not run: %s\n" % exc).encode())
            return -1

    try:
        for index, step in enumerate(steps):
            if step.get("on_failure"):
                continue
            result = run_one(step)
            if result == 0:
                continue
            if step.get("optional"):
                logfile.write(
                    ("[skipped: exited %d, continuing]\n" % result).encode())
                continue
            code = result
            if step.get("guard"):
                logfile.write(("[refused by the stop guard: exited %d; "
                               "nothing was changed]\n" % result).encode())
                with _jobs_lock:
                    job["refused"] = True
                break
            logfile.write(("[failed: exited %d]\n" % result).encode())
            for tail in steps[index + 1:]:
                if tail.get("always") or tail.get("on_failure"):
                    run_one(tail)
            break
    finally:
        try:
            logfile.close()
        except Exception:
            pass
    if code == 0 and job.get("action") == "remove":
        try:
            mark_removed(job["key"])
        except Exception as exc:
            log("removal of %s not recorded: %s" % (job["key"], exc))
    if code == 0 and job.get("action") == "update":
        _after_update(job)
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
    if action == "remove":
        if not teardown_script(svc):
            raise DeployError(403, "this service has no teardown.sh yet, so "
                                   "it can only be removed by hand (see its "
                                   "TROUBLESHOOT.md)")
        health = svc.get("health")
        active = bool(health) and probe_all([health]).get(health, False)
        if not ((active or marker_exists(svc.get("marker")))
                and not is_removed(load_receipt(key), active)):
            raise DeployError(409, "this service is not installed")

    steps = plan_action(svc, action)
    if not steps:
        raise DeployError(403, "this service has no start/stop configuration")

    job = register_job(key, action)
    log("%s %s started: %s (%d steps)"
        % (action, key, job["id"], len(steps)))
    threading.Thread(target=_run_steps, args=(job, steps),
                     daemon=True).start()
    return job["id"]


# ------------------------------------------------------------------ updates
#
# "Is there a newer image for what this service runs?" For each container
# part, the ref the container was created from (`.Config.Image`, such as
# ghcr.io/openhands/agent-canvas:latest) is looked up on its registry with one
# manifest HEAD, and the digest that comes back is compared with the
# RepoDigests of the image the container is actually running. A different
# digest means the tag has moved since this container was made: exactly what
# `docker pull <ref>` plus a re-run of setup.sh (the upgrade recipe in every
# service's SETUP.md) picks up.
#
# That covers floating tags (latest, release, main, 13.0-latest) and a pinned
# tag upstream rebuilt. It deliberately does not go looking for newer version
# tags: a version pinned in .env is a choice, bumped by hand with the .env
# editor and a redeploy.
#
#   {"openhands": {"checked_at": "...Z", "available": true,
#                  "images": [{"container": "openhands-agent-canvas",
#                              "image": "ghcr.io/openhands/agent-canvas:latest",
#                              "status": "update", "error": null}]}}
#
# status: current | update | pinned (by digest, cannot move) | local (built on
# this box, nothing to pull) | error (the registry did not answer).

_updates_lock = threading.Lock()
# key -> monotonic start of the check whose result is stored (record_updates).
_update_started = {}

_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
# What an image ref may look like before any word of it reaches an argv.
# Leading alphanumeric, so nothing can pass for a docker flag.
_IMAGE_REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$")
_MANIFEST_ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
))
_CHALLENGE_RE = re.compile(r'(\w+)="([^"]*)"')
UPDATE_STATUSES = ("current", "update", "pinned", "local", "error")


def parse_image_ref(ref):
    """'ghcr.io/x/y:tag' -> (registry host, repository, tag), or None.

    None for anything that cannot move or that this does not understand,
    including a ref pinned by digest. Docker's own rule picks the registry:
    the first path component is a host only when it has a '.' or ':' or is
    'localhost'; anything else is on Docker Hub, where one-word names live
    under library/.
    """
    if not isinstance(ref, str) or not _IMAGE_REF_RE.match(ref) or "@" in ref:
        return None
    name, tag = ref, "latest"
    colon = ref.rfind(":")
    if colon > ref.rfind("/"):
        name, tag = ref[:colon], ref[colon + 1:]
    if not name or not tag:
        return None
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, repo = first, rest
    else:
        host, repo = "docker.io", name
    if host in ("docker.io", "index.docker.io", "registry-1.docker.io"):
        host = "registry-1.docker.io"
        if "/" not in repo:
            repo = "library/" + repo
    return host, repo, tag


def _registry_token(challenge, repo):
    """An anonymous pull token for the Bearer challenge a registry sent.

    Docker Hub, ghcr.io and quay.io all answer an unauthenticated manifest
    request with 401 plus a realm to fetch a token from; public images get
    one for free. The realm comes from the registry, so it must at least be
    HTTPS before this follows it.
    """
    if not challenge.lower().startswith("bearer "):
        return None
    params = dict(_CHALLENGE_RE.findall(challenge))
    realm = params.get("realm") or ""
    if not realm.startswith("https://"):
        return None
    query = {"scope": params.get("scope") or "repository:%s:pull" % repo}
    if params.get("service"):
        query["service"] = params["service"]
    url = realm + ("&" if "?" in realm else "?") + urllib.parse.urlencode(query)
    with urllib.request.urlopen(url, timeout=REGISTRY_TIMEOUT) as resp:
        doc = json.loads(resp.read(65536).decode("utf-8"))
    token = doc.get("token") or doc.get("access_token")
    return token if isinstance(token, str) and token else None


def remote_digest(host, repo, tag):
    """The digest host/repo:tag points at right now. Raises on any failure.

    A HEAD, never a GET: Docker Hub does not count a HEAD against its
    anonymous pull limit, and the digest is in a header anyway.
    """
    url = "https://%s/v2/%s/manifests/%s" % (
        host, urllib.parse.quote(repo), urllib.parse.quote(tag))
    headers = {"Accept": _MANIFEST_ACCEPT}
    for attempt in (0, 1):
        req = urllib.request.Request(url, headers=headers, method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=REGISTRY_TIMEOUT) as resp:
                digest = resp.headers.get("Docker-Content-Digest")
        except urllib.error.HTTPError as exc:
            if exc.code == 401 and attempt == 0:
                token = _registry_token(
                    exc.headers.get("WWW-Authenticate") or "", repo)
                if token:
                    headers["Authorization"] = "Bearer " + token
                    continue
            raise
        if isinstance(digest, str) and _DIGEST_RE.match(digest.strip()):
            return digest.strip()
        raise ValueError("the registry sent no digest")
    raise ValueError("the registry refused an anonymous token")


def _registry_error(exc):
    """A short, safe sentence for the UI. Never a URL or a token."""
    if isinstance(exc, urllib.error.HTTPError):
        return "registry answered HTTP %d" % exc.code
    if isinstance(exc, urllib.error.URLError):
        return "registry unreachable"
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return "registry timed out"
    if isinstance(exc, ValueError):
        return str(exc)[:120]
    return "check failed"


class DockerUnavailable(Exception):
    """docker did not answer, which is not the same as "nothing running"."""


def _docker_lines(args):
    """stdout lines of one docker call. Raises DockerUnavailable.

    `docker inspect` exits 1 when ANY name is missing and still prints the
    rest, so a non-zero exit is only a failure when stderr says something
    other than "No such ...". A daemon that is down, a missing binary or a
    hung call raise instead of reading as an empty answer: an empty answer
    would drop a stored result, or call every image "built on this box".
    """
    argv = sg_docker(["docker"] + list(args))
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
    except Exception as exc:
        raise DockerUnavailable(str(exc))
    try:
        out, err = proc.communicate(timeout=DOCKER_INSPECT_TIMEOUT)
    except Exception as exc:
        try:
            proc.kill()
            proc.communicate(timeout=1)
        except Exception:
            pass
        raise DockerUnavailable(str(exc) or "docker timed out")
    if proc.returncode:
        other = [line for line in (err or "").splitlines()
                 if line.strip() and "No such" not in line]
        if other:
            raise DockerUnavailable(other[0][:200])
    return (out or "").splitlines()


def _container_names(svc):
    return [p["name"] for p in control_parts(control_block(svc))
            if p["kind"] == "container"]


def running_images(svc):
    """[{container, image, digests}] for each of the service's containers.

    Raises DockerUnavailable when docker cannot answer either question.

    Two docker calls for the whole service, whatever its size: one inspect of
    the containers for the ref and image id they run, one inspect of those
    images for the digests they were pulled as. A container that does not
    exist (an optional part, or a service that is not installed) is simply
    absent from the answer.
    """
    names = _container_names(svc)
    if not names:
        return []
    rows = []
    for line in _docker_lines(
            ["inspect", "--type", "container", "--format",
             "{{.Name}}\t{{.Config.Image}}\t{{.Image}}"] + names):
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        name, ref, image_id = (f.strip() for f in fields)
        rows.append({"container": name.lstrip("/"), "image": ref,
                     "image_id": image_id if _DIGEST_RE.match(image_id) else None})
    ids = sorted({r["image_id"] for r in rows if r["image_id"]})
    digests = {}
    if ids:
        for line in _docker_lines(
                ["image", "inspect", "--format",
                 "{{.Id}}\t{{json .RepoDigests}}"] + ids):
            image_id, _, raw = line.partition("\t")
            try:
                values = json.loads(raw)
            except ValueError:
                continue
            if isinstance(values, list):
                digests[image_id.strip()] = [
                    v.rpartition("@")[2] for v in values
                    if isinstance(v, str) and "@" in v]
    return [{"container": r["container"], "image": r["image"],
             "digests": digests.get(r["image_id"], [])} for r in rows]


def check_service_updates(svc):
    """A fresh updates entry for one service, or None with nothing to check.

    Raises DockerUnavailable rather than guessing; callers keep whatever was
    stored before.

    One registry call per distinct ref, not per container: Plane runs six
    containers off one release tag.
    """
    rows = running_images(svc)
    if not rows:
        return None
    answers = {}
    images = []
    for row in rows:
        entry = {"container": row["container"], "image": row["image"],
                 "status": "current", "error": None}
        parsed = parse_image_ref(row["image"])
        if parsed is None:
            entry["status"] = "pinned"
        elif not row["digests"]:
            entry["status"] = "local"
        else:
            if row["image"] not in answers:
                try:
                    answers[row["image"]] = (remote_digest(*parsed), None)
                except Exception as exc:
                    answers[row["image"]] = (None, _registry_error(exc))
            digest, error = answers[row["image"]]
            if digest is None:
                entry["status"], entry["error"] = "error", error
            elif digest not in row["digests"]:
                entry["status"] = "update"
        images.append(entry)
    return {"checked_at": _now_iso(),
            "available": any(i["status"] == "update" for i in images),
            "images": images}


def _valid_update_entry(entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("images"), list):
        return None
    images = []
    for image in entry["images"]:
        if (isinstance(image, dict) and isinstance(image.get("image"), str)
                and image.get("status") in UPDATE_STATUSES):
            images.append({
                "container": image.get("container")
                if isinstance(image.get("container"), str) else None,
                "image": image["image"],
                "status": image["status"],
                "error": image.get("error")
                if isinstance(image.get("error"), str) else None,
            })
    checked = entry.get("checked_at")
    return {"checked_at": checked if isinstance(checked, str) else None,
            "available": any(i["status"] == "update" for i in images),
            "images": images}


def load_updates():
    """key -> updates entry. Never raises; a bad file reads as "not checked"."""
    try:
        with open(UPDATES_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        log("updates.json unusable (%s); treating as unchecked" % exc)
        return {}
    if not isinstance(doc, dict):
        return {}
    clean = {}
    for key, entry in doc.items():
        valid = _valid_update_entry(entry)
        if isinstance(key, str) and valid is not None:
            clean[key] = valid
    return clean


def record_updates(key, entry, started=None):
    """Store one service's result; None drops it (nothing left to check).

    `started` is the time.monotonic() its check began. A result from a check
    that began before the stored one is discarded: a sweep that read the old
    containers and then waited on a registry must not land after an update's
    own re-check and put the badge back.
    """
    with _updates_lock:
        if started is not None:
            if started < _update_started.get(key, float("-inf")):
                log("update check for %s superseded; result dropped" % key)
                return False
            _update_started[key] = started
        data = load_updates()
        if entry is None:
            if key not in data:
                return True
            data.pop(key, None)
        else:
            data[key] = entry
        _write_json_atomically(UPDATES_PATH, data, ".updates.")
        return True


def check_and_record(svc):
    """Check one service and store the result, unless a newer check won."""
    started = time.monotonic()
    return record_updates(svc["key"], check_service_updates(svc), started)


def update_summary(entry):
    """The grid's slice of an entry: enough for a badge, nothing more."""
    if not isinstance(entry, dict):
        return None
    return {"available": bool(entry.get("available")),
            "checked_at": entry.get("checked_at")}


def updatable(svc):
    """Whether an Update could run for this service at all: it is
    controllable from here, has containers, and has a setup.sh to re-run."""
    if not control_status(svc)["controllable"] or not _container_names(svc):
        return False
    try:
        resolve_script(svc)
    except DeployError:
        return False
    return True


def update_detail(svc, installed):
    """The detail page's block: the stored entry plus whether to offer one."""
    entry = load_updates().get(svc.get("key")) if installed else None
    out = {"checkable": bool(installed and _container_names(svc)),
           "updatable": bool(installed and updatable(svc)),
           "checked_at": None, "available": False, "images": []}
    if entry:
        out.update(entry)
    return out


def check_updates_now(key):
    """POST .../updates/check: re-check one service and return its block."""
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    if not _container_names(svc):
        raise DeployError(400, "this service runs no containers to check")
    try:
        check_and_record(svc)
    except DockerUnavailable as exc:
        log("update check for %s: docker unavailable (%s)" % (key, exc))
        raise DeployError(503, "docker did not answer, so nothing was "
                               "checked; the last result is kept")
    return update_detail(svc, True)


def check_all_updates():
    """One sweep over every service with containers. Never raises.

    A service with a job running is skipped: its containers may be half way
    through being recreated, and an update re-checks on its own when done.
    """
    try:
        registry = load_registry()
        busy = {k for k, j in jobs_by_key().items()
                if j.get("status") == "running"}
    except Exception as exc:
        log("update sweep skipped: %s" % exc)
        return
    for svc in registry:
        key = svc.get("key")
        if not isinstance(key, str) or not _container_names(svc) or key in busy:
            continue
        try:
            check_and_record(svc)
        except Exception as exc:
            log("update check for %s failed: %s" % (key, exc))


def _update_loop():
    time.sleep(UPDATE_FIRST_DELAY)
    while True:
        # The only thread that runs the sweep: nothing may end it, or the
        # badges silently stop until the launcher restarts.
        try:
            check_all_updates()
        except Exception as exc:
            log("update sweep failed: %s" % exc)
        time.sleep(UPDATE_INTERVAL)


def plan_update(svc, script, refs):
    """Pause Kuma, pull each moved ref, re-run setup.sh, resume Kuma.

    setup.sh's own `docker compose up -d` is what recreates the containers
    on the freshly pulled images, so the update goes through the same path a
    first install does and cannot drift from it. A pull that fails stops the
    job before anything was recreated; the resume still runs (it is
    `always`), so the monitor never stays paused.
    """
    monitors = control_monitors(control_block(svc))
    steps = _kuma_steps("pause", monitors)
    for ref in refs:
        steps.append({"argv": sg_docker(["docker", "pull", ref]),
                      "optional": False, "always": False, "env": None})
    steps.append({"argv": build_command(script, runner_args(svc, "deploy")),
                  "optional": False, "always": False, "env": None,
                  "cwd": os.path.dirname(script)})
    steps.extend(_kuma_steps("resume", monitors))
    return steps


def start_update(key):
    """POST .../update: queue pull-and-redeploy for the refs that moved.

    Only refs the last check marked `update` are pulled, and each is
    re-validated before it goes near an argv: the request carries the key and
    nothing else.
    """
    svc = find_service(key)
    if svc is None:
        raise DeployError(404, "unknown service")
    status = control_status(svc)
    if not status["controllable"]:
        raise DeployError(403, status["reason"])
    script = resolve_script(svc)
    entry = load_updates().get(key) or {}
    refs = []
    for image in entry.get("images") or []:
        ref = image.get("image")
        if (image.get("status") == "update" and parse_image_ref(ref)
                and ref not in refs):
            refs.append(ref)
    if not refs:
        raise DeployError(409, "no update is waiting for this service; "
                               "check again first")
    steps = plan_update(svc, script, refs)
    job = register_job(key, "update")
    job["source"] = deploy_source(svc, script)
    log("update %s started: %s (%s)" % (key, job["id"], ", ".join(refs)))
    threading.Thread(target=_run_steps, args=(job, steps),
                     daemon=True).start()
    return job["id"]


def _after_update(job):
    """A successful update is a deploy: receipt, then a re-check so the
    badge clears. Both best effort; neither can fail the job."""
    try:
        write_receipt(job["key"], job["id"], job.get("source"))
    except Exception as exc:
        log("receipt for %s not written: %s" % (job["key"], exc))
    svc = find_service(job["key"])
    if svc is not None:
        try:
            check_and_record(svc)
        except Exception as exc:
            log("post-update check for %s failed: %s" % (job["key"], exc))


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
        # True when the stop guard said no: the job failed before it changed
        # anything, so the UI must not say "part way between states".
        "refused": bool(snapshot.get("refused")),
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
        if path == "api/deployd":
            self._json(200, deployd_payload())
            return
        if path == "api/github/repos":
            self._json(200, github_repos())
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

        if parts == ["api", "github", "inspect"]:
            self._json(200, github_inspect(body))
            return
        if parts == ["api", "apps"]:
            self._json(202, create_app(body))
            return
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
                and parts[3] == "update":
            self._json(202, {"job_id": start_update(parts[2])})
            return
        if len(parts) == 5 and parts[0] == "api" and parts[1] == "services" \
                and parts[3] == "updates" and parts[4] == "check":
            self._json(200, check_updates_now(parts[2]))
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
        # deployd poller CRUD + ops. Writes land in state/pollers.json —
        # never in the checkout, which the poller ff-pulls.
        if len(parts) >= 4 and parts[0] == "api" and parts[1] == "deployd" \
                and parts[2] == "pollers":
            if len(parts) == 4:
                self._json(200, deployd_upsert_poller(parts[3], body))
                return
            if len(parts) == 5:
                op = parts[4]
                if op == "restore":
                    self._json(200, deployd_restore_poller(parts[3]))
                elif op == "pause":
                    self._json(200, deployd_pause_poller(parts[3], True))
                elif op == "resume":
                    self._json(200, deployd_pause_poller(parts[3], False))
                elif op == "deploy":
                    self._json(202,
                               {"job_id": start_deployd_force(parts[3])})
                else:
                    self._error(404, "unknown endpoint")
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
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "deployd" \
                and parts[2] == "pollers":
            self._json(200, deployd_remove_poller(parts[3]))
            return
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "apps":
            self._json(200, delete_app(parts[2]))
            return
        self._error(404, "unknown endpoint")

    # ---- static

    def _serve_static(self, path):
        if not os.path.isdir(WEB_DIR):
            # The frontend may not be written yet. Stay up and keep the API
            # usable rather than refusing to start.
            if path in ("", "index.html"):
                self._send(503, "launcher: static/ not built yet\n",
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
        # No caching: the whole point is that editing static/ is the deploy.
        self._send(200, body, ctype, {"Cache-Control": "no-cache"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("application/manifest+json", ".webmanifest")
    srv = Server((BIND, PORT), Handler)
    threading.Thread(target=_update_loop, daemon=True).start()
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
