# Deployment directory — kai-home-server

What's actually running on `kai-home-server` (Ubuntu 24.04, Ryzen 5 2600,
7.7 GB RAM), audited 2026-09-12. All web services are tailnet-only:
`https://kai-home-server.taild6a23f.ts.net[:port]`, TLS terminated by
Tailscale Serve, apps bound to `127.0.0.1`.

## Filesystem layout (since 2026-09-07)

Code and state are separated; `~` root stays flat no matter how many
services are added:

- `~/dev/<repo>` — git clones (this repo lives at `~/dev/setup-server`;
  service code like `~/dev/manimkc` too)
- `~/services/<name>` — runtime state only: Docker bind mounts, data
  dirs, job workdirs. Never in git; this is the backup target.

A new service claims one dir in each. Volume paths are set in each
service's `setup.sh` (defaults) and baked into its gitignored `.env`
on first run — a path change must edit both. code-server is the
exception: its state is in `~/.config/code-server` (systemd user unit,
no Docker).

## Services & ports

| HTTPS (tailnet) | Service | What it does | Local port | Runs as |
|---|---|---|---|---|
| :443 | [code-server](code-server/) | VS Code + terminal in the browser | 8080 | systemd user unit |
| :8443 | [seafile](seafile/) | Drive: file sync, web UI, iPhone photo backup | 8081 | Docker (+ MariaDB, Redis on internal network) |
| :8384 | [syncthing](syncthing/) | Peer-to-peer folder sync (dotfiles, notes vault, project dirs) with this box as the always-on hub; deployed 2026-09-12. **Native binary** (v2.1.5 pinned, sha256-verified) in `~/.local/bin`, not Docker, so synced files are plain user-owned files at any path. GUI loopback-only behind Serve. **Its sync listener is the second non-loopback listener on this box** (after AdGuard's DNS): `100.85.87.87:22000` tcp+quic, because peers dial it directly and QUIC is UDP — still tailnet-only. Relays, global discovery, LAN multicast, NAT-PMP, usage/crash reporting and self-upgrade all **off**, so it contacts no third party at all; the cost is that peers must be added with the explicit address `tcp://kai-home-server.taild6a23f.ts.net:22000` (`dynamic` never resolves it). This box never dials out. Role split: **Seafile is the Drive** (web UI, share links); Syncthing keeps folders identical device-to-device. Photos stay Immich-only | 8384 + 22000 | systemd user unit |
| :10000 | [open-webui](open-webui/) | ChatGPT-style UI over local ollama | 3001 | Docker (host net) |
| :3002 | [monitoring](monitoring/) — Uptime Kuma | Status dashboard; probes everything below every 60s | 3002 | Docker (host net) |
| :3003 | [monitoring](monitoring/) — ntfy | Push notifications (topic `alerts`) to phone/web | 3003 | Docker (host net) |
| :5678 | [n8n](n8n/) | Workflow automation; workflows can call all local services | 5678 | Docker (host net) |
| :8091 | [kaichenpedia](kaichenpedia/) | Personal wiki (Quartz static build of the private kaichenpedia repo); polls GitHub daily and redeploys on new commits (`bin/deploy.sh --force` deploys now) | 8091 | Docker (nginx) + systemd user timer |
| :8090 | manimkc (`~/dev/manimkc/server/`) | Video-gen job server: JSON brief → narrated ManimGL video → Seafile `manimkc` library | 8090 | systemd user unit |
| :8092 | [beszel](beszel/) | Resource monitoring: CPU/RAM/GPU/disk/net/temps, history + ntfy-able alerts (complements Kuma's uptime checks) | 8092 | Docker (host net, loopback-bound) + native agent on 127.0.0.1:45876 (systemd user unit) |
| :443**/home/** + :8093 | [launcher](launcher/) | One-tap app launcher: tile grid of every service with live status; dimmed tiles for services not installed yet, with a Deploy button that runs their `setup.sh`; detail pages reveal and **edit** a service's `.env` values in place (pencil per row — the fix for a password reset that left the file stale). **The short URL to bookmark on the phone.** Shares :443 with code-server via a `--set-path=/home` handler, which leaves `/` untouched | 8093 | systemd user unit (Python 3 stdlib, no deps) |
| :3000 | [forgejo](forgejo/) | Self-hosted git forge: repos, pull requests, issues. v15 **LTS** (to 2027-07-15) not v16 (EOL 2026-10-29); SQLite not Postgres, so one container at ~100 MB. Built-in SSH off — port 22 is the box's own sshd — so clone over HTTPS. Sign-ups disabled | 3000 | Docker (single container, loopback-published) |
| :8096 | [jellyfin](jellyfin/) | Media server: films/shows/music to browser, phone and TV. Single container, SQLite library DB, ~200 MB. Pinned to 12.0 (the .NET rewrite) because the library started empty — no plugins to break, no DB to migrate. **NVENC hardware transcoding ON** since 2026-09-11 (`JELLYFIN_NVENC=on` in `.env`, which makes setup.sh layer `docker-compose.gpu.yml`). `jellyfin/enable-nvenc.sh` installed nvidia-container-toolkit 1.20.0 and registered the `nvidia` runtime with dockerd; `./enable-nvenc.sh --check` reports status, `JELLYFIN_NVENC=off ./setup.sh` reverts. GTX 1070 is Pascal: H.264/HEVC encode+decode, **no AV1 either way** — leave AV1 unticked in the dashboard even though `ffmpeg -encoders` lists `av1_nvenc` (that is the ffmpeg build, not the card). Media mounted READ-ONLY from `MEDIA_DIR`, which starts empty | 8096 | Docker (single container, loopback-published) |
| :8222 | [vaultwarden](vaultwarden/) | Password manager, Bitwarden-compatible — use the official Bitwarden apps and point them here. Rust reimplementation, so SQLite and **~12 MB RAM**, not the 2 GB the official server wants. The `/admin` panel is deliberately **off** (no `ADMIN_TOKEN`): there is nothing on it this box needs, and it is the one page that could hand out the whole vault. `setup.sh` cannot create your account — the master password derives the vault key in the browser — so signups open on first deploy and the *next* run counts accounts and closes them | 8222 | Docker (single container, loopback-published) |
| :8094 | [remote-desktop](remote-desktop/) | This box's own GNOME desktop in a browser tab: Guacamole (HTML5⇄RDP) + guacd, file auth, no database, backed by **gnome-remote-desktop's system daemon**. Deployed 2026-09-11. **The repo's one legitimate sudo deviation** — it configures a system daemon, so `setup.sh` escalates; a re-run against a working deploy asks for nothing. It also needs a **real system login password** (Remote Login hands credentials to GDM), stored 0600 in `.env` and `user-mapping.xml` — consider a dedicated account. ⚠️ **`:3389` is wildcard-bound and cannot be changed**: the daemon imports only GLib listener helpers that take no address, so no config makes it loopback-only. An nftables table (`inet remote_desktop`, own unit, enabled) is the *only* mitigation — **verified by behaviour, not config**: measured on this box, :3389 refuses on both LAN addresses (192.168.88.11 **and** .13) and on the tailnet, accepts on loopback, and accepts from the Guacamole bridge (172.28.0.0/24), which is the one route guacd needs. guacd's 4822 is published nowhere. Guacamole's login is auth-by-necessity — it has no anonymous mode — not a substitute for the tailnet. **No file transfer**: this backend has no rdpdr channel, whatever PLAN.md says. Hash in `user-mapping.xml` is **unsalted** (the salted scheme belongs to the JDBC extension and never matches) | 8094 + 3389 | Docker (guacd + webapp on a private bridge, webapp loopback-published) + system daemon |
| :8095 | [paperless-ngx](paperless-ngx/) | OCR'd, searchable archive of receipts, contracts and tax docs. Webserver + redis; **SQLite, not Postgres**, and Tika/Gotenberg left out as a commented opt-in — the webserver alone idles at **654 MiB**, the heaviest service on this box after immich. Redis is published nowhere (an unauthenticated task queue). Health-check **`/accounts/login/` (200)** — `/` is a 302 and `/healthz` is *also* a 302, which makes it look like a health endpoint when it is not; Kuma scores either as down. `PAPERLESS_URL` must be the external tailnet https URL **with the port and no trailing slash** — it feeds both ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS, and getting it wrong gives a site that loads but 403s every login, with the reason only in the container log. Admin is created on first boot and **never touched again** (measured), so a password changed in the UI survives and `.env`'s copy going stale is normal. OCR is CPU-only on this Ryzen — slow is expected | 8095 | Docker (webserver + redis, web tier loopback-published) |
| :8097 + :8099 | [firefly-iii](firefly-iii/) | Personal finance: accounts, budgets, categories, reports. Three containers at ~180 MB measured idle (app ~66 / Postgres ~29 / importer ~80), each with a `mem_limit` ceiling (768m / 512m / 512m), **Postgres published nowhere at all**. Health-check **`/login`, never `/health`** — nginx answers `/health` with 200 even when the PHP behind it is dead, so that monitor could never go red. The asset-scheme fix behind Serve is `TRUSTED_PROXIES`, not `APP_URL` (measured both ways); without it the login page renders with no CSS or JS while curl still sees 200. `PHP_FPM_PM_MAX_CHILDREN` cut 20→5 because 20 × 256M is a 5 GB worst case here. ⚠️ **Data Importer on :8099 is idle** until a personal access token is minted from a logged-in session, and **only EUR is enabled** until you turn on SGD/USD at first login | 8097 + 8099 | Docker (app + Postgres + importer, web tiers loopback-published) |
| :8100 | [homepage](homepage/) | YAML-configured dashboard of every service — tiles, live status dots, header widgets; edit `~/services/homepage/config/*.yaml` and reload, no restart. ~89 MB. Overlaps the launcher deliberately: Homepage is the read-only front door, the launcher is the only one that can deploy/start/stop or edit `.env` values. They share no code, so **a service added to one will not appear in the other**. Runs on **host networking** — from a bridge network its probes reach nothing, since every service here binds 127.0.0.1 — while its own socket stays loopback-only via `HOSTNAME=127.0.0.1`. Docker socket deliberately **not** mounted (root-equivalent control for a web app; `siteMonitor` probes are better information anyway). Health-check **`/api/healthcheck`, never `/`** — host validation only guards `/api/*`, so `/` returns a byte-identical 200 shell even when every API call is being rejected | 8100 | Docker (single container, host net, loopback-bound) |
| :3080 | [adguard](adguard/) | Tailnet-wide DNS ad/tracker blocking; ~50 MB. Web UI on 3080 because AdGuard's default 3000 is forgejo. **Its resolver is the one listener on this box that is not loopback** — Serve proxies HTTP, not UDP, so DNS binds `100.85.87.87:53` tcp+udp directly (still tailnet-only; `tailscale0` is not the LAN). ⚠️ Deploying it filters nothing until `100.85.87.87` is added as a nameserver at login.tailscale.com/admin/dns — **not yet done**, deliberately manual because it changes DNS for every device at once. Reverse in that order too: remove the nameserver *before* stopping AdGuard. Upstream Quad9 over DoH, DNSSEC on. `systemd-resolved` is untouched and still owns 127.0.0.53 | 3080 + 53 | Docker (single container, loopback web + tailnet-IP DNS) |
| :8123 | [home-assistant](home-assistant/) | Local-first home automation: lights, plugs, sensors, media players. Runs on **host networking** so zeroconf/SSDP/DHCP/USB discovery can see the LAN, while the web UI still binds 127.0.0.1 via `http.server_host` — measured, both hold at once. `default_config:` is replaced by its 21 dependencies **minus `bluetooth`** (host bluetoothd owns hci0; letting HA fight it logged an error every 2.5s forever) **and minus `go2rtc`** (its WebRTC listener binds `:::18555` on every interface under host net, with no setting to move it — cameras still work over HLS). Both exclusions are first-boot-only in effect: HA persists config entries, so `configuration.yaml` must exist before the container ever starts. Location/units left for the UI on purpose — auto-completing that step pins lat/long to 0 and TZ to UTC permanently | 8123 | Docker (single container, host net, loopback-bound) |
| :2283 | [immich](immich/) | Self-hosted Google Photos: timeline, albums, phone background backup; ML (faces/semantic search) behind a flag, **off by default** on this box's 7.7 GB | 2283 | Docker (bridge; server loopback-published, postgres+redis unpublished) |

Supporting services (no Tailscale Serve entry):

| Port | Service | Notes |
|---|---|---|
| 22 | OpenSSH | LAN + tailnet; primary access is Tailscale SSH |
| 11434 | ollama | ⚠️ binds `*` (LAN-exposed) via systemd override; models: qwen3:8b, qwen3:4b, nomic-embed-text. Loose end: tighten to 127.0.0.1 (Open WebUI + n8n only need loopback) |
| 22000 | syncthing (BEP sync, tcp+udp) | Bound to `100.85.87.87` only (tailnet IP, not loopback, not LAN) — peers dial it directly. See the :8384 row above |
| — | seafile-mysql, seafile-redis | Docker-internal network only, no host ports |
| — | [ntfy-control](ntfy-control/) | systemd user unit. Listens on ntfy topic `control` (loopback subscribe, no port of its own); allowlisted start/stop of services from the phone app, replies + Kuma pause included. Shares one allowlist with the launcher: the `control` block per service in `launcher/services.json` |

## Port allocation rules

- Modern Tailscale (>= ~1.90) serves HTTPS on **any** port — the old
  443/8443/10000 limit is gone.
- A port can host **several** mounts: `tailscale serve --set-path=/foo` adds a
  handler next to whatever already owns `/`, so :443 serves code-server at `/`
  and the launcher at `/home/`. Tailscale **strips** the prefix before
  proxying (the backend sees `/`), so anything published this way must use
  relative URLs. Never issue a bare `--https=443` — it replaces the `/`
  handler and takes code-server down.
- Convention: monitoring-class services use HTTPS port == local port
  (3002/3003); earlier services predate that and differ.
- Before claiming a port for a new service: check this table, then
  `ss -ltn` and `tailscale serve status` on the box, then add rows here,
  a monitor line in `monitoring/seed_kuma.py`, and a row in README.md.

## Credentials & auth

- code-server: no password — tailnet is the auth layer
- Syncthing: no GUI password (tailnet is the auth layer; the nag is dismissed);
  REST API key in `~/services/syncthing/config/config.xml` (mode 600). That
  directory is also the device identity — `cert.pem` is the Device ID
- Seafile / Kuma / n8n: admin credentials in each service's gitignored `.env`
- Open WebUI: first-registered account is admin (registered by Kai)
- ntfy: open on the tailnet (anyone on the tailnet can pub/sub)
- Immich: admin `chenwenlongofficial@gmail.com`, password generated into
  `immich/.env` (`IMMICH_ADMIN_PASSWORD`); DB password there too. Same
  password-sync rule — a UI change must be mirrored back into `.env`, or
  setup.sh warns and skips the settings step on the next run.
- manimkc: uploads as service account `manimkc@kaichen.local` (API token in
  `~/dev/manimkc/.env`, no password stored); library `manimkc` shared rw to
  Kai's account. ⚠️ service account is a Seafile admin (self-demotion via API
  rejected) — demote in Seafile web UI when convenient. NOTE: Kai's own
  Seafile admin password drifted from `seafile/.env` (UI change?) — the
  `.env` copy no longer authenticates; fix per the password-sync rule below.

## Loose ends / TODO (as of 2026-09-12)

- **ollama on `*:11434`** — LAN-exposed via systemd override; tighten to
  127.0.0.1 (Open WebUI + n8n only need loopback). Needs sudo.
- **Tailscale exit node** — not yet advertised (`tailscale set
  --advertise-exit-node` + one-time admin-console approval).
- **Launcher state is not in git and not backed up** —
  `~/services/launcher/overrides.json` (per-service name/description edits)
  and `~/services/launcher/notes.json` (developer notes) are user-authored
  content living only on this disk. `services.json` in the repo is the
  shipped default; overrides layer on top, and deleting either file falls
  back cleanly. If notes accumulate real operational knowledge, they need to
  be in the backup job alongside the Immich library and database.
- **Launcher can start/stop/restart services**, sharing one allowlist with
  ntfy-control: the `control` block per service in `launcher/services.json`,
  read by both. `ntfy`, `ollama` and `launcher` are locked out server-side
  (checked before the registry, so editing services.json cannot re-enable
  them) — stopping ntfy or the launcher removes the only way to start them
  again, and ollama is a system unit that would need sudo.
- **Immich RAM ceiling** — deployed 2026-09-10 with machine learning OFF
  (`IMMICH_ML=off`, the default): 7.7 GB total, and ollama claims ~5 GB with a
  model loaded, against Immich's documented 6 GB minimum / 8 GB recommended.
  Semantic search, face grouping and OCR stay dark until then. This box is
  AM4/DDR4, so 32 GB is a ~$50–90 upgrade; after it lands run
  `IMMICH_ML=on ./setup.sh` and the existing library backfills. The ~150 GB
  free disk is the other gate — a Takeout import wants a dedicated drive.
- **Syncthing folders** — deployed 2026-09-12 with one empty `default`
  folder at `~/services/syncthing/data/default` shared with no device yet.
  Next: add the laptop (paste this box's Device ID from `./setup.sh` output
  or the GUI, address `tcp://kai-home-server.taild6a23f.ts.net:22000`), then
  pick which folders live here. Do not share the phone camera roll — Immich
  owns photos. `~/services/syncthing/config` is the identity: back it up.
- **Seafile vs Immich camera upload** — pick one, not both, or every photo is
  stored twice. Seafile camera upload was never enabled, so Immich takes the
  role and Seafile stays Drive-only.
- **Phone apps** — ntfy app connected (2026-09-08, subscribed `alerts`;
  service control via [ntfy-control](ntfy-control/) buttons — send `panel`
  to re-pop the menu). Seafile app (camera upload) still pending.
- **n8n intentionally stopped** (2026-09-08, via ntfy-control; Kuma monitor
  paused). Start it from the panel or `docker start n8n` when needed —
  scheduled workflows don't run while it's down.
- **kaichenpedia intentionally stopped** (2026-09-08, via ntfy-control; Kuma
  monitor paused, container `Exited (0)`). Not needed up right now. Start it
  from the ntfy panel or `docker start kaichenpedia`.
  ⚠️ Correction: an earlier note here claimed the daily poller only redeploys
  while the container is running. That is false — measured 2026-09-11, the
  timer built a fresh commit at 23:58 with the container stopped for two
  days. So a recent `built-sha` says nothing about what is being *served*;
  only the container's state does. Both this and n8n show as
  amber "Paused" tiles in the launcher, which is accurate, not a fault.
- **kaichenpedia baseUrl** — `site/quartz.config.ts` in the wiki repo still
  points at the old Cloudflare domain (cosmetic: og/sitemap links only).
- **AdGuard Home**: shipped 2026-09-11 (see the :3080 row); the remaining
  step is adding `100.85.87.87` as a nameserver in the Tailscale admin
  console, which is what makes it filter anything.
- **macOS script paths** — portable by construction, still unverified on a
  real Mac (`tests/run-tests.sh` mocked suite would confirm).
- **Password sync rule** — service `.env` files are read once at seeding;
  UI password changes must be manually mirrored into `.env` or re-seeding
  breaks (bit us once with Kuma). n8n's password differs from Kuma's by a
  capital K (n8n policy).
- **WhatsApp via Composio** — broken upstream (Graph API error 100);
  Telegram is the working personal channel.

## Quick health check

Dashboard: https://kai-home-server.taild6a23f.ts.net:3002 — or from the box:
each service's `./tests/run-tests.sh --live`.
