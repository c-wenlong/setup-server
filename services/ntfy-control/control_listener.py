#!/usr/bin/env python3
"""ntfy-control listener: start/stop services from the ntfy phone app.

Subscribes to the CONTROL_TOPIC on the local ntfy server and executes a
strict allowlist of commands; replies land on REPLY_TOPIC (the `alerts`
topic the phone is already subscribed to).

Commands (message text, case-insensitive):
    status                       state of every controllable service
    stop|start|restart <svc>     e.g. `stop seafile`

Security model: the tailnet is the auth layer (only Kai's devices can reach
ntfy), and on top of that message text is only ever *matched* against the
allowlist below — it is never executed. Worst case for a bogus message is a
"usage" reply.

THE ALLOWLIST IS NOT IN THIS FILE. It is the per-service `control` block in
`app/web/services.json`, which the launcher's web UI reads for exactly the
same purpose. Two hand-maintained service->command maps would drift — a
service controllable from the phone but not the web, or a Kuma monitor
paused on only one of the two paths — so there is one map and both front
ends read it. This listener is deployed as a copy under
~/services/ntfy-control/bin (see setup.sh), so it locates the repo copy of
that file at runtime; see _registry_candidates(). If it cannot find one,
nothing is controllable and it says so, rather than falling back to a stale
second copy of the list.

ntfy itself is deliberately not controllable (stopping it would cut off the
ability to start it again), and so are the launcher (it serves the web UI
that would start it) and ollama (a *system* unit, so it would need sudo).
Those are marked `locked` in the shared file and hard-locked here as well.
Stopping a service also pauses its Uptime Kuma monitor (via kuma_toggle.py)
so intentional downtime doesn't page; that step is best-effort and never
fails the action itself.

Modes:
    control_listener.py                  subscribe loop (systemd/launchd)
    control_listener.py --handle "..."   handle one message and exit (tests)

Config via env (systemd EnvironmentFile= / launchd EnvironmentVariables):
    NTFY_BASE_URL, CONTROL_TOPIC, REPLY_TOPIC, KUMA_ENV_FILE,
    CONTROL_REGISTRY (optional explicit path to app/web/services.json)
"""

import json
import os
import re
import subprocess
import sys
import time

NTFY = os.environ.get("NTFY_BASE_URL", "http://127.0.0.1:3003")
# Tailnet URL used in notification action buttons — the phone tapping a
# button must be able to reach it (loopback fallback keeps replies working).
PUBLIC_NTFY = os.environ.get("PUBLIC_NTFY_URL", "") or os.environ.get("NTFY_BASE_URL", "http://127.0.0.1:3003")
CONTROL_TOPIC = os.environ.get("CONTROL_TOPIC", "control")
REPLY_TOPIC = os.environ.get("REPLY_TOPIC", "alerts")
KUMA_ENV_FILE = os.environ.get("KUMA_ENV_FILE", "")
BIN_DIR = os.path.dirname(os.path.abspath(__file__))

VERBS = ("start", "stop", "restart")

# Same shape gate as the launcher's: container and unit names out of the
# registry are matched against this before they can become an argv word.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$")

# The second lock, mirroring app/web/server.py: the shared file already
# marks these `locked`, and this is here so an edit to that file cannot
# hand the phone a button that stops the thing you would start things with.
HARD_LOCKED = ("ntfy", "launcher", "ollama")


def run(argv, env=None, timeout=300):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


# ------------------------------------------------------- shared allowlist

_registry = {"path": None, "mtime": None, "services": {}}


def _registry_candidates():
    """Where app/web/services.json might be, best first.

    setup.sh copies this script (and kuma_toggle.py, and nothing else) into
    ~/services/ntfy-control/bin, so a plain sibling lookup does not work in
    the deployed case. What the deployed case does have is KUMA_ENV_FILE,
    an absolute path to <repo>/services/monitoring/.env written by setup.sh — so the
    repo root is derivable from the config that already exists. The other
    candidates cover running straight from a checkout (the tests do) and the
    conventional location.
    """
    explicit = os.environ.get("CONTROL_REGISTRY", "").strip()
    if explicit:
        return [explicit]
    paths = []
    if KUMA_ENV_FILE:
        repo = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(KUMA_ENV_FILE))))
        paths.append(os.path.join(repo, "app", "web", "services.json"))
    paths.append(os.path.join(os.path.dirname(os.path.dirname(BIN_DIR)),
                              "app", "web", "services.json"))
    paths.append(os.path.expanduser("~/dev/setup-server/app/web/services.json"))
    return paths


def _parts(block):
    """`parts` of a control block, in STOP order. Malformed entries dropped."""
    out = []
    for entry in block.get("parts") or []:
        if not isinstance(entry, dict):
            continue
        kind = "container" if "container" in entry else "unit"
        name = entry.get(kind)
        if not isinstance(name, str) or not NAME_RE.match(name):
            continue
        out.append({"kind": kind, "name": name,
                    "optional": bool(entry.get("optional"))})
    return out


def load_registry():
    """key -> {parts, primary, kuma} for every controllable service.

    Re-read only when the file changes, so editing services.json takes
    effect without restarting the listener — the same live-reload the
    launcher gets from the same file.
    """
    for path in _registry_candidates():
        if not os.path.isfile(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if _registry["path"] == path and _registry["mtime"] == mtime:
            return _registry["services"]
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as e:
            print(f"control registry unreadable ({path}): {e}", flush=True)
            continue
        services = {}
        for svc in doc.get("services") or []:
            key = svc.get("key")
            block = svc.get("control")
            if not isinstance(key, str) or key in HARD_LOCKED:
                continue
            if not isinstance(block, dict) or block.get("locked"):
                continue
            parts = _parts(block)
            if not parts:
                continue
            services[key] = {"parts": parts, "kuma": _monitors(block),
                             "primary": block.get("primary")}
        _registry.update(path=path, mtime=mtime, services=services)
        print(f"control registry: {len(services)} services from {path}",
              flush=True)
        return services
    # Nothing parsed this time. If a registry loaded successfully earlier in
    # this process, keep serving it rather than emptying the panel: one bad
    # character in services.json (a hand-edit, a half-written file caught
    # mid-save) would otherwise make every service uncontrollable from the
    # phone, which is exactly when you are least able to fix it. Stale but
    # working beats correct but empty. A restart still starts from scratch,
    # so this can never mask a permanently broken file.
    if _registry["services"]:
        print("control registry unreadable — keeping the %d services last "
              "loaded from %s" % (len(_registry["services"]), _registry["path"]),
              flush=True)
        return _registry["services"]
    print("no control registry found — nothing is controllable", flush=True)
    return {}


def all_services():
    return sorted(load_registry())


def usage():
    names = all_services()
    listed = ", ".join(names) if names else "(none — control registry not found)"
    return (
        "commands: panel (menu card) | pick start|stop|restart (service picker) | "
        "stop <svc> | start <svc> | restart <svc>\nservices: " + listed
    )


# ------------------------------------------------------------------ ntfy

def notify(text, actions=None):
    cmd = ["curl", "-fsS", "-o", "/dev/null", "-H", "Title: server-control", "-d", text]
    if actions:
        cmd += ["-H", "X-Actions: " + json.dumps(actions)]
    cmd.append(f"{NTFY}/{REPLY_TOPIC}")
    run(cmd, timeout=30)


def action(label, message):
    """A tappable button: the phone POSTs the command back to the control
    topic — same path as a typed message, same allowlist."""
    return {"action": "http", "label": label, "method": "POST",
            "url": f"{PUBLIC_NTFY}/{CONTROL_TOPIC}", "body": message}


# ----------------------------------------------------------------- state

def primary_part(control):
    """The part whose state stands for the service's state.

    Defaults to the first part, which is the front-most thing in stop order
    and so usually the user-facing one. beszel is the exception — its agent
    is stopped first but the hub is what has a URL — so the shared file names
    it explicitly.
    """
    for part in control["parts"]:
        if part["name"] == control.get("primary"):
            return part
    return control["parts"][0]


def part_state(part):
    if part["kind"] == "container":
        code, out = run(["docker", "inspect", "-f", "{{.State.Status}}",
                         part["name"]], timeout=30)
        if code == 0:
            return out
        return "not found" if "No such" in out else "unknown (docker error)"
    code, out = run(["systemctl", "--user", "is-active", part["name"]],
                    timeout=30)
    return out if out else "unknown"


def service_state(svc):
    control = load_registry().get(svc)
    if not control:
        return "unknown"
    return part_state(primary_part(control))


def is_up(state):
    return state in ("running", "active")


def context_buttons(svc):
    """Buttons that match the service's *current* state: running services
    offer stop/restart, stopped ones offer start."""
    state = service_state(svc)
    if is_up(state):
        acts = [action("stop", f"stop {svc}"), action("restart", f"restart {svc}")]
    else:
        acts = [action("start", f"start {svc}")]
    acts.append(action("menu", "panel"))
    return state, acts


def master_card():
    """The menu: body is the live service list, buttons are the verbs.
    (ntfy caps actions at 3 per notification, so 'list' is the body itself.)"""
    notify(states(), actions=[action("start", "pick start"),
                              action("stop", "pick stop"),
                              action("restart", "pick restart")])


def pick(verb):
    """Verb-first picker: show only the services the verb applies to —
    stop/restart list running services, start lists stopped ones. One
    button per service, chunked 3 per notification (ntfy's action limit)."""
    want_up = verb in ("stop", "restart")
    svcs = [s for s in all_services() if is_up(service_state(s)) == want_up]
    header = "active" if want_up else "stopped"
    if not svcs:
        notify(f"nothing to {verb} — no {header} services",
               actions=[action("menu", "panel")])
        return
    for i in range(0, len(svcs), 3):
        chunk = svcs[i:i + 3]
        acts = [action(s, f"{verb} {s}") for s in chunk]
        if len(acts) < 3 and i + 3 >= len(svcs):
            acts.append(action("menu", "panel"))
        notify(f"{verb} which? {header}: " + ", ".join(chunk), actions=acts)


def states():
    registry = load_registry()
    if not registry:
        return "control registry not found — nothing is controllable"
    return "\n".join(f"{svc}: {service_state(svc)}" for svc in sorted(registry))


# ------------------------------------------------------------------ kuma

def _monitors(block):
    """`kuma` as a list of valid monitor names: one name or a list of them."""
    raw = block.get("kuma")
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    names = []
    for name in raw:
        if isinstance(name, str) and NAME_RE.match(name) and name not in names:
            names.append(name)
    return names


def kuma(action, control):
    """Pause/resume each of the service's Kuma monitors. Best-effort: returns
    a note for the reply naming any that failed, '' otherwise.

    Deliberately never contributes to the command's own exit status —
    stopping a service must not depend on the monitoring stack being up.
    """
    monitors = control.get("kuma") or []
    if not monitors or not KUMA_ENV_FILE or not os.path.isfile(KUMA_ENV_FILE):
        return ""
    env = dict(os.environ)
    with open(KUMA_ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    failed = []
    for monitor in monitors:
        code, _ = run(
            ["uv", "run", "--with", "uptime-kuma-api", "python3",
             os.path.join(BIN_DIR, "kuma_toggle.py"), action, monitor],
            env=env, timeout=90,
        )
        if code != 0:
            failed.append(monitor)
    return f" (kuma {action} failed: {', '.join(failed)})" if failed else ""


# --------------------------------------------------------------- lifecycle

def part_argv(part, verb):
    if part["kind"] == "container":
        return ["docker", verb, part["name"]]
    return ["systemctl", "--user", verb, part["name"]]


def plan(control, verb):
    """The ordered (argv, optional) steps for one verb.

    One command per part rather than one `docker stop a b c`: the docker CLI
    stops multiple containers in parallel, and for Immich the order is the
    whole point — the server has to go before the database it is still
    talking to. Start is the exact reverse, so dependencies come up first.
    Restart is a stop pass followed by a start pass, for the same reason.
    """
    parts = control["parts"]
    steps = []
    if verb in ("stop", "restart"):
        steps += [(part_argv(p, "stop"), p["optional"]) for p in parts]
    if verb in ("start", "restart"):
        steps += [(part_argv(p, "start"), p["optional"]) for p in reversed(parts)]
    return steps


def run_plan(steps):
    """Run steps in order. First required failure stops the run.

    A part marked optional (Immich's machine-learning container, which only
    exists when the `ml` compose profile is on) is allowed to fail.
    """
    output = []
    for argv, optional in steps:
        code, out = run(argv)
        if out:
            output.append(out)
        if code != 0 and not optional:
            return code, "\n".join(output)
    return 0, "\n".join(output)


def handle(text):
    parts = text.strip().lower().split()
    if not parts:
        return
    print(f"command: {text.strip()}", flush=True)
    cmd = parts[0]
    target = parts[1] if len(parts) > 1 else ""

    if cmd in ("panel", "menu", "status", "list"):
        master_card()
        return
    if cmd == "pick" and target in VERBS:
        pick(target)
        return
    if cmd not in VERBS:
        notify(usage())
        return

    control = load_registry().get(target)
    if control is None:
        notify(f"unknown service '{target}'\n{usage()}")
        return

    # Pause before stopping, resume after starting: a paused monitor cannot
    # page about downtime you asked for. Both are best-effort — `note` is the
    # only trace a failure leaves, and it never changes the outcome below.
    note = ""
    if cmd in ("stop", "restart"):
        note += kuma("pause", control)
    code, out = run_plan(plan(control, cmd))
    if cmd in ("start", "restart"):
        # Resumed even when the command failed: a service that would not come
        # back up is real downtime and should be allowed to page.
        note += kuma("resume", control)

    _, acts = context_buttons(target)  # buttons for the state we're now in
    if code == 0:
        notify(f"{target}: {cmd} ok{note}", actions=acts)
    else:
        notify(f"{target}: {cmd} FAILED — {out[:300]}{note}", actions=acts)


def subscribe_forever():
    url = f"{NTFY}/{CONTROL_TOPIC}/json"
    print(f"listening on {url} (replies -> {REPLY_TOPIC})", flush=True)
    load_registry()   # log which allowlist file is in force, at startup
    while True:
        try:
            proc = subprocess.Popen(["curl", "-sN", url], stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("event") == "message":
                    handle(msg.get("message", ""))
            proc.wait()
            print("subscription dropped — reconnecting in 5s", flush=True)
        except Exception as e:  # noqa: BLE001 — keep the listener alive no matter what
            print(f"subscribe error: {e} — reconnecting in 5s", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--handle":
        handle(sys.argv[2])
        sys.exit(0)
    subscribe_forever()
