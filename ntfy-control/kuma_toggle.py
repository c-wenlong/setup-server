"""Pause/resume an Uptime Kuma monitor by name.

Called by control_listener.py via: uv run --with uptime-kuma-api python3
kuma_toggle.py <pause|resume> <monitor-name>
Env: KUMA_PORT, KUMA_ADMIN_USER, KUMA_ADMIN_PASSWORD (from monitoring/.env).
"""

import os
import sys

from uptime_kuma_api import UptimeKumaApi

action, name = sys.argv[1], sys.argv[2]
api = UptimeKumaApi(f"http://127.0.0.1:{os.environ['KUMA_PORT']}", timeout=15)
api.login(os.environ["KUMA_ADMIN_USER"], os.environ["KUMA_ADMIN_PASSWORD"])
monitor = next((m for m in api.get_monitors() if m["name"] == name), None)
if monitor is None:
    print(f"no monitor named {name} — nothing to {action}")
    api.disconnect()
    sys.exit(0)
(api.pause_monitor if action == "pause" else api.resume_monitor)(monitor["id"])
api.disconnect()
print(f"{action}: {name}")
