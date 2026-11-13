"""Pause/resume an Uptime Kuma monitor by name.

Called by control_listener.py via: uv run --with uptime-kuma-api python3
kuma_toggle.py <pause|resume> <monitor-name>
Env: KUMA_PORT, KUMA_ADMIN_USER, KUMA_ADMIN_PASSWORD (from services/monitoring/.env).
"""

import os
import sys

from uptime_kuma_api import UptimeKumaApi

action, name = sys.argv[1], sys.argv[2]
# A renamed service asks for its new monitor name. Until monitoring setup
# re-keys the live monitor, the old name is what is still alerting. Try the
# current name, then the names it replaced. A missing name is success only
# when none of them exist.
aliases = {
    "hermes-studio": ("gnosia-learn", "self-learn"),
    "hermes-studio-runner": ("gnosia-learn-studio", "self-learn-studio"),
}
api = UptimeKumaApi(f"http://127.0.0.1:{os.environ['KUMA_PORT']}", timeout=15)
api.login(os.environ["KUMA_ADMIN_USER"], os.environ["KUMA_ADMIN_PASSWORD"])
monitors = api.get_monitors()
acted = []
for candidate in (name, *aliases.get(name, ())):
    monitor = next((m for m in monitors if m["name"] == candidate), None)
    if monitor is None:
        continue
    (api.pause_monitor if action == "pause" else api.resume_monitor)(monitor["id"])
    acted.append(candidate)
api.disconnect()
if not acted:
    print(f"no monitor named {name} — nothing to {action}")
    sys.exit(0)
print(f"{action}: {', '.join(acted)}")
