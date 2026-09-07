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

ntfy itself is deliberately not controllable (stopping it would cut off the
ability to start it again). Stopping a service also pauses its Uptime Kuma
monitor (via kuma_toggle.py) so intentional downtime doesn't page.

Modes:
    control_listener.py                  subscribe loop (systemd/launchd)
    control_listener.py --handle "..."   handle one message and exit (tests)

Config via env (systemd EnvironmentFile= / launchd EnvironmentVariables):
    NTFY_BASE_URL, CONTROL_TOPIC, REPLY_TOPIC, KUMA_ENV_FILE
"""

import json
import os
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

# Container names in stop order; start uses the reverse (deps first).
DOCKER_SERVICES = {
    "seafile": ["seafile", "seafile-mysql", "seafile-redis"],
    "open-webui": ["open-webui"],
    "n8n": ["n8n"],
    "kaichenpedia": ["kaichenpedia"],
    "uptime-kuma": ["uptime-kuma"],
}
SYSTEMD_SERVICES = {"code-server": "code-server"}

# service -> Uptime Kuma monitor to pause/resume alongside it
KUMA_MONITORS = {
    "seafile": "seafile",
    "open-webui": "open-webui",
    "n8n": "n8n",
    "kaichenpedia": "kaichenpedia",
    "code-server": "code-server",
}

USAGE = (
    "commands: panel (menu card) | pick start|stop|restart (service picker) | "
    "stop <svc> | start <svc> | restart <svc>\nservices: "
    + ", ".join(sorted(list(DOCKER_SERVICES) + list(SYSTEMD_SERVICES)))
)


def run(argv, env=None, timeout=300):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


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


def service_state(svc):
    if svc in DOCKER_SERVICES:
        code, out = run(["docker", "inspect", "-f", "{{.State.Status}}",
                         DOCKER_SERVICES[svc][0]], timeout=30)
        if code == 0:
            return out
        return "not found" if "No such" in out else "unknown (docker error)"
    code, out = run(["systemctl", "--user", "is-active", SYSTEMD_SERVICES[svc]], timeout=30)
    return out if out else "unknown"


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


ALL_SERVICES = sorted(list(DOCKER_SERVICES) + list(SYSTEMD_SERVICES))


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
    svcs = [s for s in ALL_SERVICES if is_up(service_state(s)) == want_up]
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


def kuma(action, service):
    """Pause/resume the service's Kuma monitor. Best-effort: returns a note
    for the reply on failure, '' on success or when not applicable."""
    monitor = KUMA_MONITORS.get(service)
    if not monitor or not KUMA_ENV_FILE or not os.path.isfile(KUMA_ENV_FILE):
        return ""
    env = dict(os.environ)
    with open(KUMA_ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    code, _ = run(
        ["uv", "run", "--with", "uptime-kuma-api", "python3",
         os.path.join(BIN_DIR, "kuma_toggle.py"), action, monitor],
        env=env, timeout=90,
    )
    return "" if code == 0 else f" (kuma {action} failed)"


def states():
    return "\n".join(
        f"{svc}: {service_state(svc)}"
        for svc in sorted(list(DOCKER_SERVICES) + list(SYSTEMD_SERVICES))
    )


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
    if cmd == "pick" and target in ("start", "stop", "restart"):
        pick(target)
        return
    if cmd not in ("start", "stop", "restart"):
        notify(USAGE)
        return

    if target in DOCKER_SERVICES:
        containers = DOCKER_SERVICES[target]
        order = containers if cmd == "stop" else list(reversed(containers))
        code, out = run(["docker", cmd] + order)
    elif target in SYSTEMD_SERVICES:
        code, out = run(["systemctl", "--user", cmd, SYSTEMD_SERVICES[target]])
    else:
        notify(f"unknown service '{target}'\n{USAGE}")
        return

    note = kuma("pause" if cmd == "stop" else "resume", target)
    _, acts = context_buttons(target)  # buttons for the state we're now in
    if code == 0:
        notify(f"{target}: {cmd} ok{note}", actions=acts)
    else:
        notify(f"{target}: {cmd} FAILED — {out[:300]}{note}", actions=acts)


def subscribe_forever():
    url = f"{NTFY}/{CONTROL_TOPIC}/json"
    print(f"listening on {url} (replies -> {REPLY_TOPIC})", flush=True)
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
