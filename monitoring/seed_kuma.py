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
    ("open-webui", 3001, "/health"),
    # /rest/noauth/health ({"status":"OK"}) needs no API key; "/" is the GUI
    # and would 403 without insecureSkipHostcheck, which is a separate failure
    # this monitor should not conflate with "down". Says nothing about :22000.
    ("syncthing", 8384, "/rest/noauth/health"),
    ("n8n", 5678, "/healthz"),
    # /healthcheck, not / — the UI is a SPA and a 200 shell would stay
    # green against a down API. Official webapp health endpoint.
    ("trigger-dev", 8030, "/healthcheck"),
    ("manimkc", 8090, "/health"),
    ("kaichenpedia", 8091, "/"),
    ("beszel", 8092, "/api/health"),
    ("immich", 2283, "/api/server/ping"),
    ("launcher", 8093, "/healthz"),
    # /api/healthz, not / — it reports on the cache and database rather than
    # just proving a page renders, so a half-broken forge shows as down.
    ("forgejo", 3000, "/api/healthz"),
    ("jellyfin", 8096, "/health"),
    ("vaultwarden", 8222, "/alive"),
    # /manifest.json, not /api/onboarding: the onboarding views are only
    # registered at startup while onboarding is unfinished, so that path
    # starts 404ing the day you finish setup in the UI and the box reboots.
    ("home-assistant", 8123, "/manifest.json"),
    # "/" is correct here and returns 200: the serve mount maps / to
    # 127.0.0.1:8094/guacamole/, so the context path is already applied. A 200
    # alone is weak for this service though — Tomcat answers 200 for a default
    # ROOT app too — so the deploy's own check greps for Guacamole markup.
    ("remote-desktop", 8094, "/"),
    # /accounts/login/ (200). NOT "/" and NOT "/healthz" — measured, both are
    # 302s, and Kuma scores a 302 as down. /healthz is the trap: it looks like
    # a health endpoint and is not one. /api/remote_version/ is also a 200 but
    # it phones GitHub, so it would go red when the internet does.
    ("paperless-ngx", 8095, "/accounts/login/"),
    # /login, NOT /health. Firefly ships a /health that nginx answers with a
    # 200 "OK" even when php-fpm behind it is dead, so a monitor on it can
    # never go red. /login exercises the PHP app. ("/" is a 302 chain to it,
    # and Kuma scores a 302 as down.)
    ("firefly-iii", 8097, "/login"),
    # /api/healthcheck (200, body "up"), NOT "/". Homepage's host-validation
    # middleware only matches /api/*, so "/" answers 200 with a byte-identical
    # static shell even when every API call is being rejected — a monitor on
    # "/" would stay green against a completely broken dashboard.
    ("homepage", 8100, "/api/healthcheck"),
    # /api/health, not / — the UI is a SPA and a 200 shell would stay
    # green against a down API. Official container healthcheck.
    ("coolify", 8101, "/api/health"),
    # /api/health, not / — the UI is a SPA and a 200 shell would stay
    # green against a down API. Official cloud healthcheck.
    ("appflowy", 8102, "/api/health"),
    # /api/v1/info/status ({"status":"UP"}), not / — the UI is a SPA and a
    # 200 shell would stay green against a down API. Official healthcheck.
    # Login is off; this path is documented as always unauthenticated.
    ("stirling-pdf", 8103, "/api/v1/info/status"),
    # /api/health ({"status":"ok"}), not / — the UI is a SPA and a 200
    # shell would stay green against a down API. Official healthcheck.
    ("metabase", 8104, "/api/health"),
    # /api/instances/, not / — the UI is a SPA. Community has no
    # /api/ready; this is the documented unauthenticated instance probe.
    ("plane", 8105, "/api/instances/"),
    # /api/heartbeat, not / — the UI is a SPA. Official healthcheck.
    ("umami", 8106, "/api/heartbeat"),
    # "/" is the public landing page and the only unauthenticated 200 —
    # Gnosia has no health route. It proves the Next server answers, not
    # that Postgres does: content pages read the catalog per request, and
    # the landing page reads none, so a DB fault won't be caught here.
    ("self-learn", 8107, "/"),
    # /login.html, not / — "/" is a 302 to it and Kuma scores a 302 as down.
    # This proves the web UI is up and says nothing about DNS; the resolver
    # gets its own monitor below, because those two fail independently.
    ("adguard", 3080, "/login.html"),
    # /api/health ({"status":"ok"}), not / — the UI is a SPA and a 200
    # shell would stay green against a down API.
    ("paperclip", 3100, "/api/health"),
    # "/" is the ingress; /canvas is an alternate path on some image
    # builds. Kuma follows redirects, and a 200 here is the documented
    # "it started" check. The API key is not required for the document.
    ("openhands", 8000, "/"),
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


def self_learn_studio_enabled():
    """STUDIO_ENABLED=1 in self-learn/.env, the flag that turns the runner on.

    That file is self-learn's own switch, so it is read from there rather than
    from this service's environment. A missing file or flag means off, which
    is setup.sh's default; the last assignment wins, as when the file is
    sourced. SELF_LEARN_ENV overrides the path (the tests use it).
    """
    path = os.environ.get("SELF_LEARN_ENV") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "self-learn", ".env")
    enabled = False
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and key == "STUDIO_ENABLED":
                    enabled = value.strip().strip("\"'") == "1"
    except OSError:
        pass
    return enabled


# The self-learn studio runner is loopback-only too — the app proxies
# /studio/api/* to it, so the published :8107 monitor can never see it down.
# Seeded only while the runner is switched on: with STUDIO_ENABLED=0 (the
# default) nothing listens on :7250, and a monitor there would alert for an
# intentionally absent service. Turning Studio on later needs this seed run
# again (re-run monitoring/setup.sh) to add it. A monitor seeded earlier is
# left as it is; if the flag goes back to 0, pause it in the Kuma UI.
if self_learn_studio_enabled():
    MONITORS.append(("self-learn-studio", "http://127.0.0.1:7250/api/health"))

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

# AdGuard's HTTP monitor above only proves the admin UI renders. A fresh
# AdGuard serves that UI while running no DNS server at all, and Docker's port
# mapping still shows :53 as listening, so nothing short of a real query tells
# you the resolver works. This monitor asks it to resolve a name — the only
# check that fails when the thing AdGuard exists to do has stopped.
DNS_MONITORS = [
    ("adguard-dns", "example.com",
     os.environ.get("ADGUARD_DNS_IP", "100.85.87.87"), 53),
]

have = {m["name"]: m for m in api.get_monitors()}

for name, hostname, resolver, port in DNS_MONITORS:
    if name in have:
        continue
    api.add_monitor(
        type=MonitorType.DNS,
        name=name,
        hostname=hostname,
        dns_resolve_server=resolver,
        port=port,
        dns_resolve_type="A",
        interval=300,          # a resolver check is cheap but not free
        maxretries=2,
        retryInterval=60,
        notificationIDList=[notification_id],
    )
    print(f"added DNS monitor: {name} -> {hostname} via {resolver}:{port}")

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
