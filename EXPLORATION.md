# Exploration — future home-server services

Ideas surveyed 2026-09-07, ranked by bang-for-effort for this box
(Ryzen 5 2600, 7.7 GB RAM, ~150 GB free disk, tailnet-only philosophy).
Already running: code-server, Seafile (Drive), ollama (local LLM).

## Network-level wins (near-zero resources, biggest daily impact)

- **AdGuard Home as tailnet DNS** — ✅ done (adguard/), deployed 2026-09-11 on
  :3080, one shot. Ad/tracker blocking for every device on the tailnet,
  cellular included, ~50 MB RAM. It kept its "highest QoL-per-megabyte" billing.
  Two things the survey did not anticipate. First, the Ubuntu port-53 fight
  everyone warns about **does not apply here**: systemd-resolved binds only
  127.0.0.53/54, never the wildcard, so AdGuard took the tailnet address with
  resolved left running. Second, and the reason this could have cost a deploy:
  a fresh AdGuard serves only the install wizard and runs **no DNS server at
  all**, yet Docker's port mapping still shows :53 as LISTEN — a health check
  that watches a socket goes green against a resolver that refuses every query.
  The verify step resolves a real name instead. ⚠️ Still filtering nothing
  until `100.85.87.87` is added as a nameserver in the Tailscale admin console,
  which is deliberately left as a manual step.
- **Tailscale exit node** — not even a service: `tailscale set
  --advertise-exit-node`. Route phone/laptop traffic through home for safe
  public wifi and home IP while traveling.

## Ops for what's already built

- **Uptime Kuma** — status dashboard + HTTP/docker/cert-expiry checks for
  code-server, Seafile, etc. ✅ done (monitoring/)
- **ntfy** — self-hosted push notifications to iPhone; pairs with Kuma
  ("server tells phone when something breaks") and could carry auth links.
  ✅ done (monitoring/)

## Memories & media

- **Immich** — self-hosted Google Photos (timeline, faces, semantic search,
  iOS auto-backup). Overlaps Seafile camera upload — pick one photo system.
  Heaviest option here (~2–3 GB with ML); the trigger for a storage drive.
  ✅ done (immich/) — deployed 2026-09-10 with ML off until this box has
  more RAM.
  Surveyed against PhotoPrism (no native mobile app → no background backup,
  paywalled multi-user) and Ente (server idles at 130–500 MB because all ML
  is on-device, true E2EE — the better pick *if* E2EE outranks polish, at the
  cost of MinIO/CORS setup and a smaller community).
- **Jellyfin** — Netflix for your own media library. ✅ done (jellyfin/),
  deployed 2026-09-11 on :8096. CPU transcoding does handle 1080p, and it is
  the only option: the box has a GTX 1070 but no `nvidia-container-toolkit`,
  so Docker has no GPU runtime — installing it is the upgrade path. Took two
  attempts, not one: Jellyfin answers /Startup/* several seconds before it
  accepts connections, so the first run completed the wizard with no admin
  account. The library is still empty — MEDIA_DIR in jellyfin/.env points at
  ~/services/jellyfin/media and nothing shows up until media lands there.

## Knowledge & documents

- **Paperless-ngx** — ✅ done (paperless-ngx/), built 2026-09-11 on :8095.
  OCR'd, searchable archive of receipts/contracts/tax docs; still the
  life-admin superpower it was billed as. Deployed as webserver + redis on
  **SQLite**, with Tika/Gotenberg (Office formats) left as a commented opt-in:
  the webserver alone idles at **654 MiB**, which makes it the heaviest thing
  here after immich, and a fourth container buys nothing at this document
  count. Two measured traps worth remembering: `/healthz` returns a **302**, so
  it looks like a health endpoint and is not (Kuma scores a 302 as down —
  `/accounts/login/` is the 200); and the admin account is created on first
  boot and **never touched again**, verified by changing the password inside
  the container and restarting, so `.env`'s copy going stale is the normal
  state rather than a fault.
- **Karakeep** — bookmarks/read-later with auto-tagging + summaries via the
  local ollama.
- **Open WebUI** — ChatGPT-style UI over ollama, phone-friendly. ✅ done (open-webui/)

## Dev infra

- **Self-hosted GitHub Actions runner** — free unlimited CI minutes for
  existing GitHub repos; more practical than self-hosting git.
- **Forgejo** — full self-hosted GitHub (repos + CI). ✅ done (forgejo/),
  deployed 2026-09-11 on :3000. Chosen over Gitea on governance: Codeberg
  e.V., a nonprofit, versus the for-profit that took Gitea's trademark in
  2022 — and migration runs Gitea → Forgejo but not back, so it is the
  direction that keeps a door open. GitLab was disqualified by RAM (4 GB
  minimum against this box's 7.7 GB total). The original note here — that
  this is sovereignty more than need while GitHub works — still stands:
  GitHub remains canonical, and this is a mirror until the box has backups.
  The cheaper half of the idea, a self-hosted Actions runner, is still
  unbuilt and still the better value.

## Remote access

- **remote-desktop (Guacamole + gnome-remote-desktop)** — ✅ done
  (remote-desktop/), deployed 2026-09-11 on :8094. This box's GNOME desktop in
  a browser tab on the tailnet. Never surveyed here first; requested directly.
  The backend decision went to gnome-remote-desktop over the more commonly
  paired xrdp + XFCE purely on cost: it was already installed, enabled and
  running at under a megabyte idle, so xrdp would have meant ~400 MB of
  packages and a second desktop environment to replace something already
  there. GNOME 46's headless `--system` Remote Login does work here —
  confirmed by a real X.224 handshake, which nobody had ever established on
  this box. The finding that shapes the whole service: **`:3389` cannot be
  bound to one address.** Not a guess — the daemon imports only
  `g_socket_listener_add_inet_port` and `add_any_inet_port`, neither of which
  takes an address, and `add_address` is absent entirely. So a packet filter is
  the only thing between the desktop and the LAN, and it is verified by
  connecting rather than by reading config. Also the repo's one legitimate
  sudo deviation, and the one service whose password is a real system login
  password.

## Home & security

- **Home Assistant** — ✅ done (home-assistant/), deployed 2026-09-11 on :8123,
  one shot. Local-first home automation; automations keep running when the
  internet does not, which is the whole argument for self-hosting it. Never
  surveyed before being built — it was requested directly. The interesting
  part was that host networking (needed for LAN device discovery) looked like
  it contradicted this repo's loopback-only rule, and does not:
  `http.server_host: 127.0.0.1` constrains the bind while discovery still
  works, both measured. Two integrations are switched off for concrete,
  measured reasons rather than taste — `bluetooth` (the host's own bluetoothd
  owns hci0 and the two fight, 24 errors a minute) and `go2rtc` (binds
  `:::18555` on every interface, the one thing here that would have been
  LAN-reachable without TLS). Nothing is connected to it yet; it is
  infrastructure waiting for devices.
- **Vaultwarden** — ✅ done (vaultwarden/), deployed 2026-09-11 on :8222, one
  shot. Bitwarden-compatible password vault in ~12 MB. Also not surveyed here
  first. It is the service that makes the missing backup job urgent rather
  than theoretical: losing `~/services/vaultwarden` loses every password, and
  nothing on this box is backed up.

## Ranked queue — surveyed 2026-09-11 against a homelab tour

Second survey, sourced from a "everything I self-host in 2026" homelab
video (TechnoTim). Useful because it is someone else's *complete* list
rather than a wishlist, so it surfaces gaps by contrast. Most of it does
not transfer: that lab is six Proxmox nodes, TrueNAS/ZFS, three RKE
clusters and a co-location, where this is one Ubuntu box. What survives
the filter is below, ranked for this box, not that one.

The ranking constraint is RAM, not effort. Items 1–8 together cost less
than item 10 alone.

| # | Service | What it gets you | Rough cost | Why this rank |
|---|---|---|---|---|
| 1 | **Backup job** (their PBS + ZFS replication + a DB backup UI) | restic/borg of `~/services` + `pg_dump`/`mysqldump` of Immich and Seafile, pushed off-box | ~0 RAM, half a day | Not a nicety any more. Vaultwarden holds every password and Immich holds photos, both on one unbacked disk — see the Vaultwarden note above. Their whole storage story is snapshot + replicate; this box has neither. Everything below is worthless if this disk dies. |
| 2 | **Uptime Robot** (external) | Off-site check against the tailnet edge or a public canary | 10 min, free tier | Fixes the blind spot they call out explicitly: Kuma runs *on* the box it monitors, so if kai-home-server dies, nothing tells anyone. Pairs with the existing ntfy topic. |
| 3 | **Dozzle** | Live tail + search of all container logs in a browser | ~10 MB | Highest bang-per-megabyte on the list. ~15 containers here, currently read with `docker logs` over SSH. One container, no config. |
| 4 | **Paperless-ngx** + Tika + Gotenberg + Paperless-AI | OCR'd searchable archive of receipts, contracts, tax docs | ~800 MB–1.2 GB | Already listed under "Knowledge & documents" above; this survey independently put it top of the life-admin tier. Paperless-AI does the extraction the built-in OCR does poorly, and it points at the ollama already running. Watch RAM against ollama. |
| 5 | **Scrutiny** | SMART health and failure trending per disk | ~50 MB | Beszel reports disk *usage*, not disk *dying*. Cheap early warning, and it makes #1 actionable before a drive goes rather than after. |
| 6 | **IT Tools** | JWT decode, base64, hashes, cron parsing, ~80 more | ~30 MB | Trivial deploy; replaces pasting secrets into whatever site ranks first. |
| 7 | **Excalidraw** and/or **Draw.io** | Self-hosted diagramming | ~50 MB each | Architecture here lives in markdown. Excalidraw for thinking out loud, Draw.io when the diagram has real structure (network maps). |
| 8 | **Forgejo Actions runner** | CI on repos already hosted on :3000 | ~100 MB | The "cheaper half" flagged under Dev infra above, still unbuilt. kaichenpedia, manimkc and this repo's own test suite all want it. |
| 9 | **Loki + Alloy** | Searchable log *history*, not just live tail | ~600 MB–1 GB | The real gap Dozzle does not fill. But Dozzle covers most of the need at 2% of the RAM — do #3 first, and come here only after actually wanting last week's logs. |
| 10 | **Prometheus + Grafana + exporters** | Dashboards, retention, alerting rules | ~1–1.5 GB | Beszel and Kuma already cover metrics and uptime for a single box. This is the "I want to build dashboards" upgrade, not a missing capability, and it competes with ollama for RAM directly. |
| 11 | **Renovate** | Auto-PRs for container tag and dependency bumps | ~0 (runs as a job) | Versions here are pinned deliberately (Forgejo 15 LTS, Jellyfin 12). Renovate tracks them, but the surface is small enough to bump by hand. |
| 12 | **Adminer** | Web SQL client | ~20 MB | Immich's Postgres and Seafile's MariaDB are both here. Chosen over phpMyAdmin (configuration pain) and DBGate (missing features like user management) on their reporting. Rarely needed directly. |
| 13 | **Netboot.xyz** | PXE-boot OS installers over the network | ~200 MB | Useful the day a machine gets rebuilt, worthless the other 364. |
| 14 | **Mosquitto + Zigbee2MQTT** | Zigbee devices into Home Assistant | ~50 MB + a USB coordinator | Blocked on hardware, not effort. HA is deployed with nothing connected; this is the unlock, once a coordinator and some devices exist. |
| 15 | **Open Speed Test** | LAN bandwidth testing | ~30 MB | Occasionally diagnostic across links/APs, no ongoing value. |
| 16 | **Postiz** | Social cross-posting scheduler | ~500 MB | Their own verdict: good for a marketing team, not for an individual creator. Only if posting becomes scheduled work. |
| 17 | **Shlink** | Link shortener | ~300 MB | Needs a *public* domain to mean anything, which fights the tailnet-only rule. Noted as the best-architected option in its class if that ever changes. |
| 18 | **MinIO / RustFS** | S3-compatible object storage | ~500 MB | Nothing here wants S3 yet; revisit if a backup target or app demands it. MinIO has stopped developing the OSS version — RustFS is the live successor on licensing and activity. |
| 19 | **Traefik** | Reverse proxy with ACME certs | ~100 MB | Tailscale Serve already terminates TLS and routes, with less config and no cert lifecycle. Adding Traefik would be a downgrade here. |

Already covered by something running: Pi-hole + Unbound (→ AdGuard),
Uptime Kuma, Jellyfin and Plex (→ Jellyfin), Home Assistant, code-server,
n8n, ollama + Open WebUI, GitLab/Forgejo (→ Forgejo), Jekyll (→ Quartz),
Homepage and Little Link Server (→ launcher), Postgres/MariaDB/Valkey
(embedded in Immich and Seafile), nvtop and parts of Scrutiny/Grafana
(→ Beszel).

Not applicable, and why: Proxmox, PBS, LXC, TrueNAS, ZFS, RKE/Kubernetes,
Rancher, Flux, Keepalived, HAProxy, Nebula Sync, Patroni, MongoDB all
assume multiple nodes or a different storage layer. NUT, PeaNUT and
InfluxDB need a UPS. Scrypted and UniFi Protect need cameras. Rackula
needs a rack. Tautulli, Kometa, HandBrake, ErsatzTV, Dispatcharr and
HDHomeRun are all downstream of a populated media library — revisit once
Jellyfin has content.

## Travel, trails & location logging — surveyed 2026-09-11

Entry point was [AdventureLog](https://adventurelog.app/) (GPL-3.0, Django +
SvelteKit + PostGIS), asked about directly. The survey widened because the
obvious framing — "which travel app wins" — is wrong. The three candidates
answer different questions and **integrate rather than compete**; AdventureLog
ships connectors to the other two.

| | Question it answers | Model | Mobile tracker? |
|---|---|---|---|
| **[Dawarich](https://github.com/Freika/dawarich)** (AGPL-3.0, Rails 8 + PostGIS + Redis + Sidekiq) | "Where was I?" — Google Timeline replacement | Passive, automatic | ✅ **official iOS + Android**, background, offline queue |
| **[wanderer](https://wanderer.to/)** (AGPL-3.0) | "What are my GPX trails?" — self-hosted AllTrails | Trail catalogue | ❌ PWA only |
| **AdventureLog** (GPL-3.0) | "What trips did I take / am I planning?" | Manual journaling + itineraries | ❌ PWA only |

**The deciding question turned out to be mobile capture**, and it splits the
field cleanly. Only Dawarich records actual movement: its apps log on-device and
queue when there is no signal — planes, underground, off-grid, abroad without
data — then upload on reconnect. wanderer expects you to record in something
else (GPX Tracker on iOS; OpenTracks, GPSLogger or Trail Sense on Android) and
import GPX/FIT/KML/TCX, or sync from Strava/Komoot. AdventureLog does not track
at all — it imports finished activities from Strava/Endurain/wanderer, i.e.
secondhand. Its native apps were targeted for late 2024 and slipped; the
third-party KMM client is a journal client, not a tracker.

Three things the survey did not anticipate.

First, **the Immich integration — the main reason this box would pick
AdventureLog — is currently broken here.** Issue #1205: since Immich v3.0.1 the
API changed, and photo import by album and by date both fail
(`immich.no_assets_found`); only Smart Search still works. A PR is open awaiting
maintainer review. This box runs `IMMICH_VERSION=v3` (compose derived from
v3.1.0), so it is affected today. Dawarich's Immich integration is both working
and deeper — it reads EXIF GPS to place photos on the map, and is *bidirectional*,
able to write coordinates back to Immich assets that lack geodata. Also worth
trying before deploying anything: **Immich already has a map view** over EXIF,
which may cover the "where have I been" itch for zero additional RAM.

Second, **Dawarich's official apps are proprietary even though the server is
not.** Published by ZeitFlow UG, closed-source, with in-app purchases, a Sentry
tracker and a Play Services dependency — reportedly why they would not be
accepted into F-Droid as-is. FOSS paths: *Dawarich (Community)* by Sunstep
(GPL-3.0, Flutter, F-Droid + Play, unaffiliated, can record points), or point
OwnTracks / GPSLogger / Overland / Traccar / Home Assistant at the instance —
all supported, and HA is already deployed here. Related signal: Dawarich now
sells a hosted tier (Lite €59.99/yr, Pro €17.99/mo, Family €299.99/yr). Docs say
self-hosting stays free with all features and there is no evidence of features
being withheld, but it is an open-core shape that did not exist before. Watch it.

Third, **Dawarich explicitly tells you not to auto-update** — breaking changes
between releases, backups mandatory before upgrading. That collides with this
repo's rule that re-running `setup.sh` upgrades or repairs. It would need a
pinned-tag, opt-in-upgrade path documented as a deliberate deviation in its own
service-level `AGENTS.md`.

**Verdict for this box.** Nothing here is urgent, and RAM says do at most one.
Measured 2026-09-11: **2.1 GB available of 7.7 GB with 2.0 GB of swap already in
use** — the box is under pressure before Firefly III (queued, see
`firefly-iii/PLAN.md`) or any of these. AdventureLog wants 2 GB at *first boot*
(the world-geodata import is the spike, and OOM there is its most commonly
reported failure) settling to ~1 GB; Dawarich is the heaviest of the three at
four moving parts; wanderer is the lightest and the most on-point if trails
rather than travel narrative are the real interest. Each also brings another
PostGIS Postgres — with Immich and a proposed Firefly III that would be a third.

Ranked, if picking one: **wanderer** for trails, **Dawarich** for automatic
history, **AdventureLog** last — it is the most featureful and the least useful
here until #1205 lands, because its differentiator on this box is the Immich link.

**Do now, costs nothing:** install GPSLogger or OwnTracks and start capturing.
Both feed Dawarich later and both export GPX for wanderer, so the choice stays
open — and location history is the one thing that cannot be backfilled. Every
week unrecorded is gone.

## Notes

- RAM budget is the constraint: ollama claims ~5 GB while a model is loaded;
  keep new always-on services in the tens-of-MB class (AdGuard, ntfy, Kuma)
  and treat Immich as a project, not an add-on.
- Every service follows the repo conventions (AGENTS.md): tailnet-only,
  idempotent setup.sh, mocked + live tests.
- Known loose end: ollama listens on *:11434 (all interfaces) via a systemd
  override — reachable from LAN, not just localhost/tailnet. Consider
  tightening to 127.0.0.1 if nothing on the LAN needs it.
