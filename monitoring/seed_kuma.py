"""Idempotently seed Uptime Kuma: admin account, ntfy notification, monitors.

Run via: uv run --with uptime-kuma-api python3 seed_kuma.py
Env: KUMA_PORT, KUMA_ADMIN_USER, KUMA_ADMIN_PASSWORD, NTFY_PORT, NTFY_TOPIC
Requires Kuma 1.x (uptime-kuma-api does not support 2.x).
"""

import os

from uptime_kuma_api import MonitorType, NotificationType, UptimeKumaApi

MONITORS = [
    ("code-server", f"http://127.0.0.1:{os.environ.get('CODE_SERVER_PORT', '8080')}/healthz"),
    ("seafile", f"http://127.0.0.1:{os.environ.get('SEAFILE_PORT', '8081')}/api2/ping"),
    ("open-webui", f"http://127.0.0.1:{os.environ.get('OPEN_WEBUI_PORT', '3001')}/health"),
    ("ollama", f"http://127.0.0.1:{os.environ.get('OLLAMA_PORT', '11434')}/api/version"),
    ("n8n", f"http://127.0.0.1:{os.environ.get('N8N_PORT', '5678')}/healthz"),
]

api = UptimeKumaApi(f"http://127.0.0.1:{os.environ['KUMA_PORT']}", timeout=30)
user = os.environ["KUMA_ADMIN_USER"]
password = os.environ["KUMA_ADMIN_PASSWORD"]

if api.need_setup():
    api.setup(user, password)
    print("created admin account")
api.login(user, password)

notification_name = "ntfy-alerts"
existing = next((n for n in api.get_notifications() if n["name"] == notification_name), None)
if existing:
    notification_id = existing["id"]
else:
    result = api.add_notification(
        name=notification_name,
        type=NotificationType.NTFY,
        isDefault=True,
        applyExisting=True,
        ntfyserverurl=f"http://127.0.0.1:{os.environ['NTFY_PORT']}",
        ntfytopic=os.environ.get("NTFY_TOPIC", "alerts"),
        ntfyPriority=5,
        ntfyAuthenticationMethod="none",
    )
    notification_id = result["id"]
    print("created ntfy notification")

have = {m["name"] for m in api.get_monitors()}
for name, url in MONITORS:
    if name in have:
        continue
    api.add_monitor(
        type=MonitorType.HTTP,
        name=name,
        url=url,
        interval=60,
        maxretries=2,
        retryInterval=30,
        notificationIDList=[notification_id],
    )
    print(f"added monitor: {name} -> {url}")

api.disconnect()
print("seed complete")
