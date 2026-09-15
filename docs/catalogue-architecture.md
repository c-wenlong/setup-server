# Catalogue architecture — remotes, packages, runtime, cleanup

Design note, 2026-09-15. Not a shipped contract. `AGENTS.md` still requires
one directory, one `setup.sh`, one service. This document is the research
and the target shape for a launcher that can **fetch apps from repositories**
instead of waiting for an agent to write a new folder.

Companion: [teardown-sh.md](teardown-sh.md) already decided default-keep-data
and `--purge`. This note does not reopen that.

## Why this exists

The launcher can already deploy, start, stop, edit `.env`, and poll health.
Adding an app still means a human or an agent writes a full service directory
(setup, docs, tests, stubs), then copies ports into five places:

- `README.md`
- `DIRECTORY.md`
- `monitoring/seed_kuma.py`
- `launcher/services.json` (`control.parts` by hand)
- `homepage/config/services.yaml` (seeded once; drifts after)

That will not scale, and it cannot ingest a third-party catalogue. App
marketplaces that do scale split the problem into four layers. This repo
collapses them into “a bash program plus a hand-edited registry.”

## The four layers

| Layer | Job | What this repo has today |
|---|---|---|
| **Index** | Cheap, searchable list (id, name, version, icon, category, source) | Hand-edited `launcher/services.json` plus README, DIRECTORY, Homepage YAML, and `seed_kuma.py` |
| **Package** | Immutable recipe: compose or binary + metadata + pinned images | A full directory: `setup.sh`, compose, docs, tests, stubs |
| **Instance** | This box’s copy: `.env`, `~/services/<name>`, Serve map, receipt | Created by `setup.sh`; no stored “installed from remote @ revision” |
| **Runtime / cleanup** | Start, stop, update, uninstall, leftover data | Start/stop via `control.parts`. No uninstall API. Nuke recipes in `TROUBLESHOOT.md` |

Agents stay in the loop because the **package is a program**, not data the
launcher can apply.

## What working marketplaces actually do

Surveyed: Umbrel, CasaOS / BigBear, Cosmos, YunoHost, DietPi, Coolify,
CapRover, Cloudron, Portainer / Yacht / Dockge, TrueNAS Apps, Unraid CA,
Synology Package Center, Homebrew, Flatpak, Nix, Helm / Artifact Hub, Docker
Compose. Details below are the transferable bits, not product history.

### 1. Index — fetch a remote, do not embed the catalogue

Almost nobody stores the app list inside the control plane.

| Product | Catalogue transport | Extra sources |
|---|---|---|
| Umbrel | Git clone of `umbrel-apps`, polled | Extra git URLs; community ids must be prefixed (`sparkles-hello-world`) |
| CasaOS | Zip / `index.json` built from compose + `x-casaos` | Another store URL (e.g. BigBear) |
| CapRover | Hosted YAML one-click apps | Multiple repo URLs |
| Portainer / Yacht | JSON template list | Settings URL |
| TrueNAS | Git catalog, **trains** (`stable` / `community` / `enterprise`) | Third-party catalogs were dropped when the runtime changed — extra remotes need a migration story |
| Helm | `index.yaml` or `oci://…@sha256`; Artifact Hub is discovery only | Chart repos / OCI registries |
| YunoHost | Published `apps.json`; pin `revision` | Extra catalog base URL |
| DietPi | Numeric IDs inside one huge script | None. Anti-pattern. |

**Steal:** git remotes as stores. Official store = this repo. Extra stores =
other git URLs. Prefix foreign ids. Pin a catalog revision (YunoHost
`revision`, Nix `flake.lock`).

**Do not steal:** DietPi’s in-script ID table; TrueCharts-style unlimited
third-party catalogs with no pin.

### 2. Package — install is data, not a person

Apps that install without a human writing a script look like this:

```
<app-id>/
  manifest     # id, version, port, health, category, icon, deps
  compose      # or image + run spec
  optional hooks
```

| Product | Package shape |
|---|---|
| Umbrel | `umbrel-app.yml` + `docker-compose.yml` + `hooks/{pre,post}-{install,start,stop,update,uninstall}`. Images as `tag@sha256`. Tokens like `$APP_DATA_DIR` |
| CasaOS | Compose + top-level `x-casaos` (`id`, `main`, `port_map`, `icon`, `title`, `category`, `version`) |
| CapRover | Compose subset + `caproverOneClickApp.variables` (`$$cap_gen_random_hex(16)`). Only `image`, `environment`, `ports`, `volumes`, `depends_on`, `hostname` are honored |
| Coolify | `templates/compose/*.yaml` plus comment metadata; generator emits `service-templates.json`. Secrets: `SERVICE_PASSWORD_*` generated once and persisted |
| Cloudron | Image + `CloudronManifest.json` + platform addons (postgres, ldap). Tight, not portable to Linux+macOS Compose |
| YunoHost | `manifest.toml` + `scripts/{install,upgrade,remove,backup,restore}`. Closest to “`setup.sh` as named hooks,” but assumes nginx/SSO |

**Steal:** a sidecar next to compose (`launcher.yml` or `x-launcher`) with
`id`, `version`, `local_port`, `health`, `data_dir`, `depends_on`,
`control.parts`. Generate secrets once. Pin image digests.

**Keep `setup.sh` as an escape hatch** for native binaries and Tailscale
exceptions (AdGuard UDP, Syncthing, code-server, Paperclip). Do not require
`SETUP.md` + seven PATH stubs to *list* an app in the store. That bar stays
for first-party escape-hatch services.

### 3. Runtime — Compose on Engine, not a PaaS box

Three models; only one fits this box.

1. **Compose project on Docker Engine** (CasaOS, Coolify, Dockge, Portainer
   stacks, TrueNAS Electric Eel). Linux + macOS. Already most of this
   catalogue.
2. **Platform box** (Cloudron addons, CapRover Swarm, CasaOS `/DATA`). Reject.
3. **Native unit** (code-server, Syncthing, Paperclip). Second package class,
   not the default.

Every PaaS then puts a **host reverse proxy on :80/:443**. Coolify warns that
compose `ports:` bypass the proxy. This repo is the inverse: bind
`127.0.0.1`, publish with `tailscale serve`, never open the firewall.

So a foreign package must declare **loopback port + Serve port**, not
`0.0.0.0`. Ingesting raw CasaOS / CapRover / Coolify templates without a
rewrite-or-refuse gate would violate `AGENTS.md`.

Dockge’s file model is the right **instance** layout:
`~/services/<app>/compose.yaml` + `.env`. Delete-the-folder-as-uninstall is
the wrong cleanup policy.

### 4. Cleanup — graded uninstall

| Product | Default remove | Opt-in wipe |
|---|---|---|
| YunoHost | keep `$data_dir` | `--purge` |
| Homebrew casks | drop the app | `uninstall --zap` |
| Flatpak | drop the ref | `--delete-data` |
| Helm | drop release resources | PVC keep via `resource-policy`; `--keep-history` is audit, not data |
| Compose | `down` keeps named volumes | `--volumes` |
| Synology | keep package data | “Delete the data” |
| TrueNAS | drop runtime | “Remove iXVolumes”; **never** host-path datasets |
| Umbrel / CasaOS / Coolify | **wipe data by default** | — |

This repo already chose the careful side in [teardown-sh.md](teardown-sh.md):
stop + un-serve, keep `~/services/<name>` and `.env`; `--purge` with typed
confirmation; never touch `~/.claude`, `~/.codex`, or a sibling Serve map.

Also steal Unraid’s **receipt**: the filled template stays on disk so
reinstall is mechanical. Helm `values.yaml`, Nix profile, and Homebrew tap
pins are the same idea. The launcher has no receipt today — only a marker
path.

## Constraints that the design must not break

From `AGENTS.md` and the live launcher:

- One logical app per install. Complementary products stay separate ids.
- Bind `127.0.0.1` only. Tailnet IP only for protocols Serve cannot carry
  (AdGuard `:53`, Syncthing `:22000`), resolved at deploy time, documented.
- Linux + macOS. Compose on Docker Engine / Desktop is the portable
  runtime. systemd user units and launchd stay for native packages.
- Idempotent apply: never overwrite a user-edited `.env` or compose.
- Sudo surgical, at most first run.
- Interactive pause only for Serve enablement.
- `control.parts` remains the single source of truth for start/stop so the
  launcher and ntfy-control cannot drift.
- Deploy allowlist: setup/hooks stay under `ALLOWED_ROOTS` (`REPO_ROOT`,
  `~/dev`).
- Tile state stays marker + loopback health, not `docker ps` as source of
  truth.

## Target shape

Keep the security model. Change the package from a script to a **declarative
app**, and the registry from one file to **remotes**.

```
remote (git URL + pin)
  └── index.json                 # ids, versions, categories
        └── apps/<id>/
              launcher.yml       # port, health, serve, control, env schema
              compose.yml        # 127.0.0.1 only, or rewritten on apply
              hooks/             # optional: native install, Serve exceptions
```

Official remote = this repo (Umbrel model — already true). A generated
`index.json` plus thin app dirs is the CasaOS/CapRover shape and is easier
for third parties; either is fine as long as the launcher speaks remotes.

### Apply (no agent)

1. Fetch / refresh remotes.
2. Allocate `LOCAL_PORT` / `HTTPS_PORT` from a reserved map (end the
   DIRECTORY.md collision dance).
3. Write `.env` only if absent; generate secrets once
   (`SERVICE_PASSWORD_*`).
4. `compose up`, or run the native hook.
5. `tailscale serve` (still the one interactive step).
6. Write a **receipt** at `~/services/launcher/instances/<id>.json`:
   remote, revision, ports, image digests, data dir.
7. Derive launcher tiles, Homepage rows, and Kuma monitors from the
   receipt — one write, three views. Stop copying ports by hand.

### Remove

1. Stop via existing `control.parts`.
2. Drop **this** Serve map only.
3. Keep data. `--purge` deletes `~/services/<id>` and the receipt.

### Foreign repositories

Umbrel-community rules: prefix ids, never auto-trust, rewrite any
`0.0.0.0` bind to loopback **or refuse the package**. Do not ingest raw
CasaOS / CapRover templates without that gate.

### What stays human

Reviewing the official remote, Serve enablement, and the few apps that are
not Compose (code-server, Syncthing, AdGuard, Paperclip). Everything else
should be `install <id>` from an index.

## Manifest sketch (`launcher.yml`)

Not a schema freeze. The fields the apply path needs that
`services.json` already almost has:

```yaml
id: immich
name: Immich
tagline: Photos
group: daily
version: "1.2.0"          # catalog entry version, not necessarily upstream
app_version: "v1.133.0"   # upstream / image tag
icon: camera
local_port: 2283          # or "auto" from the reserved map
https_port: 2283
health: /api/server/ping
data_dir: ~/services/immich
env:
  - name: DB_PASSWORD
    generate: hex
    persist: true
control:
  parts:
    - container: immich_server
    - container: immich_machine_learning
      optional: true
    - container: immich_redis
    - container: immich_postgres
  kuma: immich
images:
  - digest: sha256:…
bind: 127.0.0.1           # required; apply refuses anything else
serve: https              # or "tailnet-ip" for the two documented exceptions
```

`services.json` can become a **generated view** of receipts + the official
index, or stay as the first-party overlay. It should stop being the only
place an app exists.

## What not to copy

- Coolify / CasaOS / Umbrel **wipe-on-delete**
- CapRover Swarm, Cloudron addons, CasaOS `/DATA`
- TrueCharts-style unlimited third-party catalogs with no pin
- Nextcloud’s in-process PKI (overkill for compose this repo already reviews)
- Homarr (dashboard only) or DietPi (catalogue-in-a-script)
- Requiring `SETUP.md` + mocked stubs for every catalog app
- A long-running PaaS control plane. The launcher is already the control
  plane. It needs remotes and receipts, not Traefik.

## Open decisions

1. **Official store format** — keep this git repo as the store (clone +
   per-app dir), or emit `index.json` for third-party clients.
2. **When `setup.sh` is required** — Compose-only catalog apps vs today’s
   full service contract. Recommendation: full contract for first-party
   escape hatches only.
3. **Port allocator** — reserved range vs continue hand-picking. Required
   before foreign apps can install unattended.
4. **Homepage and Kuma** — generate from receipts, or keep them manual
   until the receipt path exists. Dual registry is already documented as
   a drift source in `homepage/SETUP.md`.
5. **Uninstall API** — `launcher/SPEC.md` currently lists uninstall as
   out of scope. A catalogue without remove is half a marketplace.
   Align with [teardown-sh.md](teardown-sh.md).

## Sources (survey)

- Umbrel apps format and `umbreld` store clone:
  [getumbrel/umbrel-apps](https://github.com/getumbrel/umbrel-apps),
  [umbrel.com/support/apps](https://umbrel.com/support/apps/how-to-uninstall-an-app)
- CasaOS compose + `x-casaos`:
  [IceWhaleTech/CasaOS-AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore),
  [appstore-dev-docs.zimaos.com](https://appstore-dev-docs.zimaos.com/specs/compose-and-x-casaos)
- Cosmos marketplace:
  [azukaar/cosmos-servapps-official](https://github.com/azukaar/cosmos-servapps-official),
  [cosmos-cloud.io/docs/cosmos-compose](https://cosmos-cloud.io/docs/cosmos-compose/)
- YunoHost catalog + helpers:
  [YunoHost/apps](https://github.com/YunoHost/apps),
  [doc.yunohost.org packaging](https://doc.yunohost.org/en/dev/packaging/scripts/helpers_v2.1)
- Coolify templates and delete API:
  [coolify.io/docs/contribute/service](https://coolify.io/docs/contribute/service),
  [coolify.io/docs/api-reference](https://coolify.io/docs/api-reference/api/services/delete-service-by-uuid)
- CapRover one-click apps:
  [caprover/one-click-apps](https://github.com/caprover/one-click-apps),
  [caprover.com/docs/one-click-apps](https://caprover.com/docs/one-click-apps)
- Cloudron packaging:
  [docs.cloudron.io/packaging/manifest](https://docs.cloudron.io/packaging/manifest/)
- Portainer App Templates:
  [docs.portainer.io/advanced/app-templates/format](https://docs.portainer.io/advanced/app-templates/format)
- TrueNAS Apps catalogs / trains:
  [apps.truenas.com/managing-apps/discovering-apps](https://apps.truenas.com/managing-apps/discovering-apps/),
  [truenas/apps](https://github.com/truenas/apps)
- Unraid Community Applications:
  [docs.unraid.net CA](https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/)
- Homebrew taps / zap, Flatpak `--delete-data`, Helm uninstall / OCI, Compose `down --volumes` — official docs for each
