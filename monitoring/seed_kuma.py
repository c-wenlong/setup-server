"""Idempotently seed Uptime Kuma: admin account, ntfy notification, monitors.

Run via: uv run --with uptime-kuma-api python3 seed_kuma.py
Env: KUMA_PORT, KUMA_ADMIN_USER, KUMA_ADMIN_PASSWORD, NTFY_PORT, NTFY_TOPIC
Requires Kuma 1.x (uptime-kuma-api does not support 2.x).
"""

import os

from uptime_kuma_api import MonitorType, NotificationType, UptimeKumaApi

HOST = os.environ.get("TAILNET_HOST", "kai-home-server.taild6a23f.ts.net")

# Monitors probe the tailnet HTTPS URL, not loopback, so that the dashboard
# shows the address you actually open and each check exercises the whole
# path: Tailscale Serve, the TLS cert, and the app behind it. A lost serve
# config or an expired cert is real downtime from a phone's point of view,
# and loopback checks are blind to both.
#
# The trade-off, accepted deliberately: if tailscaled itself breaks, every
# monitor goes red at once without singling out the app. Check
# `tailscale serve status` first when everything fails together.
#
# (name, tailnet HTTPS port or None for :443, health path)
PUBLISHED = [
    ("code-server", None, "/healthz"),
    ("seafile", 8443, "/api2/ping/"),  # trailing slash: /api2/ping 301s
    ("open-webui", 10000, "/health"),
    ("n8n", 5678, "/healthz"),
    ("manimkc", 8090, "/health"),
    ("kaichenpedia", 8091, "/"),
    ("beszel", 8092, "/api/health"),
    ("immich", 2283, "/api/server/ping"),
    ("launcher", 8093, "/healthz"),
    # /api/healthz, not / — it reports on the cache and database rather than
    # just proving a page renders, so a half-broken forge shows as down.
    ("forgejo", 3000, "/api/healthz"),
]

MONITORS = [
    (name, f"https://{HOST}" + (f":{port}" if port else "") + path)
    for name, port, path in PUBLISHED
]

# ollama is deliberately NOT published via Tailscale Serve, so it has no
# tailnet URL and stays on loopback.
MONITORS.append(
    ("ollama", f"http://127.0.0.1:{os.environ.get('OLLAMA_PORT', '11434')}/api/version")
)

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

have = {m["name"]: m for m in api.get_monitors()}
for name, url in MONITORS:
    existing = have.get(name)
    if existing is None:
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
    elif existing["url"] != url:
        # Repoint an existing monitor. Only the URL is touched, so a paused
        # monitor stays paused and any hand-tuned interval survives.
        api.edit_monitor(existing["id"], url=url)
        print(f"updated monitor: {name} -> {url}")

api.disconnect()
print("seed complete")
