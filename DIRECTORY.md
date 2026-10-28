# Deployment directory — homeserver

What's actually running on `homeserver` (Ubuntu 24.04, Ryzen 5 2600,
7.7 GB RAM), audited 2026-09-12. All web services are tailnet-only:
`https://homeserver.tail-name.ts.net[:port]`, TLS terminated by
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
| :443 | [code-server](services/code-server/) | VS Code + terminal in the browser | 8080 | systemd user unit |
| :8443 | [seafile](services/seafile/) | Drive: file sync, web UI, iPhone photo backup | 8081 | Docker (+ MariaDB, Redis on internal network) |
| :8384 | [syncthing](services/syncthing/) | Peer-to-peer folder sync (dotfiles, notes vault, project dirs) with this box as the always-on hub; deployed 2026-09-12. **Native binary** (v2.1.5 pinned, sha256-verified) in `~/.local/bin`, not Docker, so synced files are plain user-owned files at any path. GUI loopback-only behind Serve. **Its sync listener is the second non-loopback listener on this box** (after AdGuard's DNS): `100.77.77.77:22000` tcp+quic, because peers dial it directly and QUIC is UDP — still tailnet-only. Relays, global discovery, LAN multicast, NAT-PMP, usage/crash reporting and self-upgrade all **off**, so it contacts no third party at all; the cost is that peers must be added with the explicit address `tcp://homeserver.tail-name.ts.net:22000` (`dynamic` never resolves it). This box never dials out. Role split: **Seafile is the Drive** (web UI, share links); Syncthing keeps folders identical device-to-device. Photos stay Immich-only | 8384 + 22000 | systemd user unit |
| :3001 | [open-webui](services/open-webui/) | ChatGPT-style UI over local ollama. Published on :3001 since 2026-09-13; it was :10000, a number picked when Tailscale Serve only allowed 443/8443/10000 | 3001 | Docker (host net) |
| :3002 | [monitoring](services/monitoring/) — Uptime Kuma | Status dashboard; probes everything below every 60s | 3002 | Docker (host net) |
| :3003 | [monitoring](services/monitoring/) — ntfy | Push notifications (topic `alerts`) to phone/web | 3003 | Docker (host net) |
| :5678 | [n8n](services/n8n/) | Workflow automation; workflows can call all local services | 5678 | Docker (host net) |
| :8030 | [trigger-dev](services/trigger-dev/) | Trigger.dev v4: TypeScript background jobs and cron, dashboard + supervisor. Slim stack (no s2-lite — streams on Redis; events stay in Postgres). ClickHouse still runs because v4.6.0 refuses to boot without `CLICKHOUSE_URL`, unpublished, replication off. Official wants 6+8 GB; this box has 7.7 GB. Webapp loopback-only behind Serve. **Local registry on 127.0.0.1:5000** (not Serve-published) so `npx trigger.dev@4.6.0 deploy` from this box can push task images. Magic-link login, no SMTP — links in `docker logs trigger-webapp`. Sign-ups locked to `WHITELISTED_EMAILS`. Deployed 2026-09-15 | 8030 + 5000 | Docker (webapp + postgres + redis + electric + minio + clickhouse + registry + supervisor + docker-proxy; only webapp and registry published, both loopback) |
| :8091 | [kaichenpedia](services/kaichenpedia/) | Personal wiki (Quartz static build of the private kaichenpedia repo); polls GitHub daily and redeploys on new commits (`bin/deploy.sh --force` deploys now) | 8091 | Docker (nginx) + systemd user timer |
| :8090 | manimkc (`~/dev/manimkc/server/`) | Video-gen job server: JSON brief → narrated ManimGL video → Seafile `manimkc` library | 8090 | systemd user unit |
| :8092 | [beszel](services/beszel/) | Resource monitoring: CPU/RAM/GPU/disk/net/temps, history + ntfy-able alerts (complements Kuma's uptime checks) | 8092 | Docker (host net, loopback-bound) + native agent on 127.0.0.1:45876 (systemd user unit) |
| :443**/home/** + :8093 | [launcher](app/web/) | One-tap app launcher: a sidebar shell around an ops home page (box health strip for memory, disk and load, with a disk-full alert; every service in a list grouped Running / Stopped / Not installed, with Open / Start / Install on the row and Restart / Stop / Update in a ⌘K action menu); services not installed yet get an Install that runs their `setup.sh`; detail pages reveal and **edit** a service's `.env` values in place (pencil per row — the fix for a password reset that left the file stale); flags services whose image tag moved upstream (6-hourly registry digest check) and offers a one-tap **Update** (pull + re-run setup.sh). **The short URL to bookmark on the phone.** Shares :443 with code-server via a `--set-path=/home` handler, which leaves `/` untouched | 8093 | systemd user unit (Python 3 stdlib, no deps) |
| :3000 | [forgejo](services/forgejo/) | Self-hosted git forge: repos, pull requests, issues. v15 **LTS** (to 2027-07-15) not v16 (EOL 2026-10-29); SQLite not Postgres, so one container at ~100 MB. Built-in SSH off — port 22 is the box's own sshd — so clone over HTTPS. Sign-ups disabled | 3000 | Docker (single container, loopback-published) |
| :8096 | [jellyfin](services/jellyfin/) | Media server: films/shows/music to browser, phone and TV. Single container, SQLite library DB, ~200 MB. Pinned to 12.0 (the .NET rewrite) because the library started empty — no plugins to break, no DB to migrate. **NVENC hardware transcoding ON** since 2026-09-11 (`JELLYFIN_NVENC=on` in `.env`, which makes setup.sh layer `docker-compose.gpu.yml`). `services/jellyfin/enable-nvenc.sh` installed nvidia-container-toolkit 1.20.0 and registered the `nvidia` runtime with dockerd; `./enable-nvenc.sh --check` reports status, `JELLYFIN_NVENC=off ./setup.sh` reverts. GTX 1070 is Pascal: H.264/HEVC encode+decode, **no AV1 either way** — leave AV1 unticked in the dashboard even though `ffmpeg -encoders` lists `av1_nvenc` (that is the ffmpeg build, not the card). Media mounted READ-ONLY from `MEDIA_DIR`, which starts empty | 8096 | Docker (single container, loopback-published) |
| :8222 | [vaultwarden](services/vaultwarden/) | Password manager, Bitwarden-compatible — use the official Bitwarden apps and point them here. Rust reimplementation, so SQLite and **~12 MB RAM**, not the 2 GB the official server wants. The `/admin` panel is deliberately **off** (no `ADMIN_TOKEN`): there is nothing on it this box needs, and it is the one page that could hand out the whole vault. `setup.sh` cannot create your account — the master password derives the vault key in the browser — so signups open on first deploy and the *next* run counts accounts and closes them | 8222 | Docker (single container, loopback-published) |
| :8094 | [remote-desktop](services/remote-desktop/) | This box's own GNOME desktop in a browser tab: Guacamole (HTML5⇄RDP) + guacd, file auth, no database, backed by **gnome-remote-desktop's system daemon**. Deployed 2026-09-11. **The repo's one legitimate sudo deviation** — it configures a system daemon, so `setup.sh` escalates; a re-run against a working deploy asks for nothing. It also needs a **real system login password** (Remote Login hands credentials to GDM), stored 0600 in `.env` and `user-mapping.xml` — consider a dedicated account. ⚠️ **`:3389` is wildcard-bound and cannot be changed**: the daemon imports only GLib listener helpers that take no address, so no config makes it loopback-only. An nftables table (`inet remote_desktop`, own unit, enabled) is the *only* mitigation — **verified by behaviour, not config**: measured on this box, :3389 refuses on both LAN addresses (192.168.88.11 **and** .13) and on the tailnet, accepts on loopback, and accepts from the Guacamole bridge (172.28.0.0/24), which is the one route guacd needs. guacd's 4822 is published nowhere. Guacamole's login is auth-by-necessity — it has no anonymous mode — not a substitute for the tailnet. **No file transfer**: this backend has no rdpdr channel, whatever PLAN.md says. Hash in `user-mapping.xml` is **unsalted** (the salted scheme belongs to the JDBC extension and never matches) | 8094 + 3389 | Docker (guacd + webapp on a private bridge, webapp loopback-published) + system daemon |
| :8095 | [paperless-ngx](services/paperless-ngx/) | OCR'd, searchable archive of receipts, contracts and tax docs. Webserver + redis; **SQLite, not Postgres**, and Tika/Gotenberg left out as a commented opt-in — the webserver alone idles at **654 MiB**, the heaviest service on this box after immich. Redis is published nowhere (an unauthenticated task queue). Health-check **`/accounts/login/` (200)** — `/` is a 302 and `/healthz` is *also* a 302, which makes it look like a health endpoint when it is not; Kuma scores either as down. `PAPERLESS_URL` must be the external tailnet https URL **with the port and no trailing slash** — it feeds both ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS, and getting it wrong gives a site that loads but 403s every login, with the reason only in the container log. Admin is created on first boot and **never touched again** (measured), so a password changed in the UI survives and `.env`'s copy going stale is normal. OCR is CPU-only on this Ryzen — slow is expected | 8095 | Docker (webserver + redis, web tier loopback-published) |
| :8097 + :8099 | [firefly-iii](services/firefly-iii/) | Personal finance: accounts, budgets, categories, reports. Three containers at ~180 MB measured idle (app ~66 / Postgres ~29 / importer ~80), each with a `mem_limit` ceiling (768m / 512m / 512m), **Postgres published nowhere at all**. Health-check **`/login`, never `/health`** — nginx answers `/health` with 200 even when the PHP behind it is dead, so that monitor could never go red. The asset-scheme fix behind Serve is `TRUSTED_PROXIES`, not `APP_URL` (measured both ways); without it the login page renders with no CSS or JS while curl still sees 200. `PHP_FPM_PM_MAX_CHILDREN` cut 20→5 because 20 × 256M is a 5 GB worst case here. ⚠️ **Data Importer on :8099 is idle** until a personal access token is minted from a logged-in session, and **only EUR is enabled** until you turn on SGD/USD at first login | 8097 + 8099 | Docker (app + Postgres + importer, web tiers loopback-published) |
| :8098 | [sources](services/sources/) | Encrypted browser for the private [sources](https://github.com/c-wenlong/sources) archive (YouTube transcripts, blogs, newsletters, papers, personas): categories, creators, authors, personas and a reader — the same AES-256-GCM build as the GitHub Pages site, unlocked with the same `SITE_PASSPHRASE`. Builds from the **fetch clone at `~/dev/sources`** (shared with `sources-fetch.timer`, which is why no deploy clone exists — the poller only reads it and pulls it ff-only, never commits). Daily poller rebuilds when HEAD moves, so the weekly fetch commit goes live the same day. `SITE_PASSPHRASE` required on first run and lives in `.env` (0600); rotating it logs out every visitor, Pages included — the salt is fixed in `build_site.py`. `~/services/sources/bin/deploy.sh --force` rebuilds now | 8098 | Docker (single container, loopback-published) + systemd user timer |
| :8100 | [homepage](services/homepage/) | YAML-configured dashboard of every service — tiles, live status dots, header widgets; edit `~/services/homepage/config/*.yaml` and reload, no restart. ~89 MB. Overlaps the launcher deliberately: Homepage is the read-only front door, the launcher is the only one that can deploy/start/stop or edit `.env` values. They share no code, so **a service added to one will not appear in the other**. Runs on **host networking** — from a bridge network its probes reach nothing, since every service here binds 127.0.0.1 — while its own socket stays loopback-only via `HOSTNAME=127.0.0.1`. Docker socket deliberately **not** mounted (root-equivalent control for a web app; `siteMonitor` probes are better information anyway). Health-check **`/api/healthcheck`, never `/`** — host validation only guards `/api/*`, so `/` returns a byte-identical 200 shell even when every API call is being rejected | 8100 | Docker (single container, host net, loopback-bound) |
| :8101 + :6001 | [coolify](services/coolify/) | Self-hosted PaaS: dashboard + Postgres + Redis + Soketi. Pinned to 4.3.21. **Not on :8000** — OpenHands already owns that. Dashboard and Soketi loopback-only behind Serve. Admin seeded from `.env` so `/register` is never an open first-run form. Coolify's Traefik proxy is **off** (upstream binds :80/:443 on every interface). In-app auto-update off — it would rewrite compose and undo the loopback binds. Named volumes `coolify-db` / `coolify-redis`; app files in `~/services/coolify`. SSH to localhost as the deploying user, not root. Deployed 2026-09-15 | 8101 + 6001 | Docker (coolify + postgres + redis + soketi; only dashboard and Soketi published, both loopback) |
| :8102 | [appflowy](services/appflowy/) | Self-hosted Notion: docs, databases, wiki. AppFlowy Cloud behind nginx (HTTP-only — Serve terminates TLS). Pinned cloud/gotrue/worker `0.18.8`, web `0.18.4`, admin `0.18.1` (those are the newest tags on the 0.18 line). Loopback-only behind Serve. Admin seeded from `.env`, `GOTRUE_DISABLE_SIGNUP=true`. **No AI container, no search indexer** (OpenAI key + 2 GB mmap). No pgadmin, no MinIO console. Named volumes `appflowy-postgres` / `appflowy-redis` / `appflowy-minio`; marker dir `~/services/appflowy`. Deployed 2026-09-15 | 8102 | Docker (nginx + postgres/pgvector + redis + minio + gotrue + cloud + admin + worker + web; only nginx published, loopback) |
| :8103 | [stirling-pdf](services/stirling-pdf/) | PDF toolbox: merge, split, compress, OCR, convert. Pinned to `2.14.3` (standard, not `-fat` / `-ultra-lite`). **Not on :8080** — code-server already owns that. Loopback-only behind Serve. **Login off** — upstream defaults to a well-known `admin`/`stirling` pair; the tailnet is the access boundary. Data in `~/services/stirling-pdf`. Deployed 2026-09-15 | 8103 | Docker (single container, loopback-published) |
| :8104 | [metabase](services/metabase/) | BI: dashboards and SQL over databases on this box. Pinned OSS `v0.63.17.3` + Postgres 16. **Not on :3000** — forgejo already owns that. Loopback-only behind Serve. First admin seeded from `.env` via `POST /api/setup`. Anonymous tracking off. Named volume `metabase-postgres`; marker dir `~/services/metabase`. Script written, not yet deployed | 8104 | Docker (metabase + postgres; only metabase published, loopback) |
| :8105 | [plane](services/plane/) | Project management (Linear/Jira-shaped). Plane **Community** `v1.4.2` — our compose, not their interactive setup.sh. HTTP-only proxy on loopback (no :443). First instance admin seeded from `.env`. MinIO from quay.io. Eleven long-running containers; RAM-heavy. Named volumes for postgres/valkey/minio/rabbitmq; marker dir `~/services/plane`. Script written, not yet deployed | 8105 | Docker (proxy + web/space/admin/live/api/worker/beat + postgres + valkey + rabbitmq + minio; only proxy published, loopback) |
| :8106 | [umami](services/umami/) | Web analytics. Pinned `3.3.1` + Postgres 16. **Not on :3000** — forgejo already owns that. Loopback-only behind Serve. Upstream `admin`/`umami` is rotated on first boot. Named volume `umami-postgres`; marker dir `~/services/umami`. Script written, not yet deployed | 8106 | Docker (umami + postgres; only umami published, loopback) |
| :8108 | [design-systems](services/design-systems/) | Browsable library of the private [designs](https://github.com/c-wenlong/designs) repo: the gallery (every captured design system's tokens, screenshots, components), docs site and scorecard — the same build as the repo's `make serve`, **deliberately unencrypted and including the gallery + `systems/`** (the repo's public Pages deploy strips and encrypts them; tailnet-only is what makes serving them consistent with the repo's never-publish rule). Builds from the **working clone at `~/dev/design-systems`** (read + ff-only pull only, never committed to). nginx serves the Zensical build and also answers the repo paths `/systems/ /tools/ /example/ /catalog.json /README.md` straight from a read-only mount of the checkout — the same allowlist `tools/catalog.py`'s dev server answers — so the ~300 MB of LFS screenshots aren't copied per release. Refero media (`/refero-media/`) is a second read-only mount onto `~/services/design-systems/media/refero/`, populated by `tools/refero/mirror_media.py` — kept outside the repo because the scroll videos are ~1–2 GB. **git-lfs is a real dependency**: an unfetched screenshot sits in the checkout as an ASCII pointer and crashes the thumbnail build, so setup.sh scans for pointers and runs `git lfs pull` itself. No `SITE_PASSPHRASE`. Daily poller rebuilds on new HEAD; `~/services/design-systems/bin/deploy.sh --force` rebuilds now | 8108 | Docker (single container, loopback-published) + systemd user timer |
| :8107 | [gnosia-learn](services/gnosia-learn/) | Gnosia study hub (the private `c-wenlong/self-learn` repo): Next.js roadmap + Claude tutoring loop over a SQLite catalog — courses, concept notes, spaced-repetition reviews, indexed videos/diagrams. App is a native `next start` under a systemd user unit (upstream ships no Dockerfile and the build is a four-workspace npm tree); since upstream's Postgres→SQLite migration the catalog is one file under the data root (`~/.gnosia` on a fresh install, `~/.self-learn` on installs that predate the rename), so **no container runs at all**. Machine-managed clone at `~/services/gnosia-learn/repo`, hard-reset per deploy — a working clone belongs in `~/dev`. deployd (services/deployd) drives upstream's update order — stop app → pull → `npm ci` → `catalog migrate` → `next build` → start; a deliberately stopped app is left stopped. Nightly 03:00 timer runs `catalog export` into the data root's `archive/`. **The data root is the second filesystem-layout exception** (after code-server): catalog.db + blobs/vault/archive live there because upstream's rsync instructions assume it. Catalog seeded once from `seed/`; `SKIP_SEED=1` deploys empty for dropping the laptop's `catalog.db` in place — see services/gnosia-learn/SETUP.md. **Studio job runner deployed** (`gnosia-learn-studio.service`, `npm run studio`, gated on `STUDIO_ENABLED=1` in `.env`): diagram jobs spawn the box's `claude` CLI (login creds in `~/.claude`), answer on loopback `127.0.0.1:7250`, and are reached only through the app's `/studio/api/*` proxy — never Serve-published; the deploy stops/starts it with the app. Video tools (`tools/manimkc` etc.) still stay on the Mac (upstream S5). Deployed 2026-10-07, studio added 2026-10-08 | 8107 + 7250 (studio, loopback) | systemd user unit (next start) + studio unit + nightly export timer (deploys come from deployd) |
| :3080 | [adguard](services/adguard/) | Tailnet-wide DNS ad/tracker blocking; ~50 MB. Web UI on 3080 because AdGuard's default 3000 is forgejo. **Its resolver is the one listener on this box that is not loopback** — Serve proxies HTTP, not UDP, so DNS binds `100.77.77.77:53` tcp+udp directly (still tailnet-only; `tailscale0` is not the LAN). ⚠️ Deploying it filters nothing until `100.77.77.77` is added as a nameserver at login.tailscale.com/admin/dns — **not yet done**, deliberately manual because it changes DNS for every device at once. Reverse in that order too: remove the nameserver *before* stopping AdGuard. Upstream Quad9 over DoH, DNSSEC on. `systemd-resolved` is untouched and still owns 127.0.0.53 | 3080 + 53 | Docker (single container, loopback web + tailnet-IP DNS) |
| :8123 | [home-assistant](services/home-assistant/) | Local-first home automation: lights, plugs, sensors, media players. Runs on **host networking** so zeroconf/SSDP/DHCP/USB discovery can see the LAN, while the web UI still binds 127.0.0.1 via `http.server_host` — measured, both hold at once. `default_config:` is replaced by its 21 dependencies **minus `bluetooth`** (host bluetoothd owns hci0; letting HA fight it logged an error every 2.5s forever) **and minus `go2rtc`** (its WebRTC listener binds `:::18555` on every interface under host net, with no setting to move it — cameras still work over HLS). Both exclusions are first-boot-only in effect: HA persists config entries, so `configuration.yaml` must exist before the container ever starts. Location/units left for the UI on purpose — auto-completing that step pins lat/long to 0 and TZ to UTC permanently | 8123 | Docker (single container, host net, loopback-bound) |
| :2283 | [immich](services/immich/) | Self-hosted Google Photos: timeline, albums, phone background backup; ML (faces/semantic search) behind a flag, **off by default** on this box's 7.7 GB | 2283 | Docker (bridge; server loopback-published, postgres+redis unpublished) |
| :3100 | [paperclip](services/paperclip/) | Paperclip control plane (`claude_local` / `codex_local` on the host CLIs). Loopback-only behind Serve. **authenticated/private**, never `local_trusted`. Existing `~/.claude` is not rewritten; Codex is not installed on this box yet. CEO invite is a browser step; secrets master key at `~/.paperclip/instances/default/secrets/master.key` must be backed up off-box | 3100 | official managed CLI + systemd user unit |
| :8000 | [openhands](services/openhands/) | OpenHands Agent Canvas (official image, `--public` + API key). Loopback-only behind Serve. Sees only `~/agent-workspaces` (as `/projects`). Existing `~/.claude` is not rewritten | 8000 | Docker (loopback-published) |
| :8477 | [quiver-hub](services/quiver-hub/) | Quiver's remote-control hub (`swe remote serve`): the phone PWA (sessions, inbox, Usage tab) and the endpoint MacBook satellites dial (`swe remote agent --hub=https://homeserver.tail-name.ts.net:8477`). quiver installed as a **pinned uv tool in `~/.local/share/quiver-hub/`** (commit in `installed-rev`; `QUIVER_REF=main` in `.env`, so a re-run of setup.sh upgrades to the current tip), separate from the interactive `swe`, which here is the older home-manager build from `~/dotfiles` with no `swe remote`. Loopback-only behind Serve, although quiver's design binds the tailnet IP (AGENTS.md allows that only for protocols Serve can't carry). The unit passes **`--public-url=https://homeserver.tail-name.ts.net:8477`** (quiver 6c70755+, setup.sh refuses older builds), so the hub trusts Serve's X-Forwarded-For/-Proto from loopback peers only: **"Pair with Tailscale" works** (approve the code with `~/.local/share/quiver-hub/bin/swe remote devices --approve=<code>`), `swe remote pair` and ntfy buttons use the https URL, and `#approve` works in a browser. `services/quiver-hub/pair.sh` stays for token pairing and satellites. State stays in quiver's default `~/.quiver/data/remote/` (devices, journals), not `~/services/`, because the hub-side `swe remote pair/devices` share it. Deployed 2026-10-23 | 8477 | systemd user unit |

Supporting services (no Tailscale Serve entry):

| Port | Service | Notes |
|---|---|---|
| 22 | OpenSSH | LAN + tailnet; primary access is Tailscale SSH |
| 11434 | ollama | ⚠️ binds `*` (LAN-exposed) via systemd override; models: qwen3:8b, qwen3:4b, nomic-embed-text. Loose end: tighten to 127.0.0.1 (Open WebUI + n8n only need loopback) |
| 22000 | syncthing (BEP sync, tcp+udp) | Bound to `100.77.77.77` only (tailnet IP, not loopback, not LAN) — peers dial it directly. See the :8384 row above |
| 7250 | gnosia-learn-studio | Loopback only, deliberately — the app proxies `/studio/api/*` to it and stamps the signed-in owner itself, so it has no Serve entry and no auth of its own beyond that boundary. Spawns `claude` per diagram job; `STUDIO_DAILY_USD` in `services/gnosia-learn/.env` caps spend when set |
| — | [deployd](services/deployd/) | systemd user timer + oneshot, polls every 60s. Managed from the launcher's **Deploys** page (`#/deploys`), not an app row. The tailnet-only answer to GitHub webhooks: pulls this checkout ff-only (deploy config self-updates), scans `services/*/app.json` for `deploy` blocks (`repo`/`ref`/`cmd`), `git ls-remote`s each watched ref and runs the cmd when the sha moves. State + per-service output tails in `~/services/deployd/state/`; a failed cmd backs off 15 min per sha. Replaces per-service deploy timers — quiver-hub is registered first; design-systems/sources/kaichenpedia/gnosia-learn migrated onto it |
| — | seafile-mysql, seafile-redis | Docker-internal network only, no host ports |
| — | [ntfy-control](services/ntfy-control/) | systemd user unit. Listens on ntfy topic `control` (loopback subscribe, no port of its own); allowlisted start/stop of services from the phone app, replies + Kuma pause included. Shares one allowlist with the launcher: the `control` block per service in `app/web/services.json` |

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
  a monitor line in `services/monitoring/seed_kuma.py`, and a row in README.md.

## Credentials & auth

- code-server: no password — tailnet is the auth layer
- Syncthing: no GUI password (tailnet is the auth layer; the nag is dismissed);
  REST API key in `~/services/syncthing/config/config.xml` (mode 600). That
  directory is also the device identity — `cert.pem` is the Device ID
- Seafile / Kuma / n8n: admin credentials in each service's gitignored `.env`
- Open WebUI: first-registered account is admin (registered by Kai)
- ntfy: open on the tailnet (anyone on the tailnet can pub/sub)
- Immich: admin `admin@example.com`, password generated into
  `services/immich/.env` (`IMMICH_ADMIN_PASSWORD`); DB password there too. Same
  password-sync rule — a UI change must be mirrored back into `.env`, or
  setup.sh warns and skips the settings step on the next run.
- manimkc: uploads as service account `manimkc@macbook.local` (API token in
  `~/dev/manimkc/.env`, no password stored); library `manimkc` shared rw to
  Kai's account. ⚠️ service account is a Seafile admin (self-demotion via API
  rejected) — demote in Seafile web UI when convenient. NOTE: Kai's own
  Seafile admin password drifted from `services/seafile/.env` (UI change?) — the
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
  ntfy-control: the `control` block per service in `app/web/services.json`,
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
  or the GUI, address `tcp://homeserver.tail-name.ts.net:22000`), then
  pick which folders live here. Do not share the phone camera roll — Immich
  owns photos. `~/services/syncthing/config` is the identity: back it up.
- **Seafile vs Immich camera upload** — pick one, not both, or every photo is
  stored twice. Seafile camera upload was never enabled, so Immich takes the
  role and Seafile stays Drive-only.
- **Phone apps** — ntfy app connected (2026-09-08, subscribed `alerts`;
  service control via [ntfy-control](services/ntfy-control/) buttons — send `panel`
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
  step is adding `100.77.77.77` as a nameserver in the Tailscale admin
  console, which is what makes it filter anything.
- **macOS script paths** — portable by construction, still unverified on a
  real Mac (`tests/run-tests.sh` mocked suite would confirm).
- **Password sync rule** — service `.env` files are read once at seeding;
  UI password changes must be manually mirrored into `.env` or re-seeding
  breaks (bit us once with Kuma). n8n's password differs from Kuma's by a
  capital K (n8n policy).
- **WhatsApp via Composio** — broken upstream (Graph API error 100);
  Telegram is the working personal channel.
- **quiver-hub** (2026-10-23): runs with `--public-url` since quiver
  6c70755, so whois pairing works behind Serve. The interactive `swe` here
  (home-manager, `~/dotfiles` `flake.lock`) predates `swe remote`; use
  `~/.local/share/quiver-hub/bin/swe` for hub commands until that input is
  bumped. No phone paired yet.
- **Trigger.dev RAM** — deployed 2026-09-15, **stopped the same day**.
  Slimmer than official (no s2-lite, 768 MiB Node heap, ClickHouse only
  because v4.6.0 requires `CLICKHOUSE_URL` at boot) and it still idled
  at **~1.9 GB** across nine containers — too much on 7.7 GB. Leave it
  down; n8n covers cron. Warning is in `services/trigger-dev/SETUP.md`. The
  registry is loopback-only (`127.0.0.1:5000`) if it is ever started
  again — deploy from this box, not from a laptop.

## Quick health check

Dashboard: https://homeserver.tail-name.ts.net:3002 — or from the box:
each service's `./tests/run-tests.sh --live`.
