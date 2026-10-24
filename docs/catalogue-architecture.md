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
- `services/monitoring/seed_kuma.py`
- `app/web/services.json` (`control.parts` by hand)
- `services/homepage/config/services.yaml` (seeded once; drifts after)

That will not scale, and it cannot ingest a third-party catalogue. App
marketplaces that do scale split the problem into four layers. This repo
collapses them into “a bash program plus a hand-edited registry.”

## The four layers

| Layer | Job | What this repo has today |
|---|---|---|
| **Index** | Cheap, searchable list (id, name, version, icon, category, source) | Hand-edited `app/web/services.json` plus README, DIRECTORY, Homepage YAML, and `seed_kuma.py` |
| **Package** | Immutable recipe: compose or binary + metadata + pinned images | A full directory: `setup.sh`, compose, docs, tests, stubs |
| **Instance** | This box’s copy: `.env`, `~/services/<name>`, Serve map, receipt | Created by `setup.sh`; no stored “installed from remote @ revision” |
| **Runtime / cleanup** | Start, stop, update, uninstall, leftover data | Start/stop via `control.parts`. No uninstall API. Nuke recipes in `TROUBLESHOOT.md` |

Agents stay in the loop because the **package is a program**, not data the
launcher can apply.

## What working marketplaces actually do

Surveyed: Umbrel, CasaOS / BigBear, Cosmos, YunoHost, DietPi, Coolify,
CapRover, Cloudron, Portainer / Yacht / Dockge, TrueNAS Apps, Unraid CA,
Synology Package Center, Homebrew, Flatpak, Nix, Helm / Artifact Hub, Docker
Compose; plus the “one app, many runtimes” hubs Pinokio, Stability Matrix,
LynxHub, LM Studio, and Ollama (case studies below). Details are the
transferable bits, not product history.

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

## Case studies: one app, many runtimes

A second family sits next to Umbrel/CasaOS: **one local control plane that
installs and runs many apps or models**. They are closer to what the
launcher wants to become than a PaaS is — a hub, not a proxy farm. They
manage *AI UIs and weights*, not Compose services, but the four layers
still show up.

| Tool | Focus | Ease of use | Dependency isolation | Best for |
|---|---|---|---|---|
| **Pinokio** | Universal (all AI) | High (script-based) | Isolated folders (+ shared `bin/` / `drive/`) | Rapidly testing diverse open-source tools |
| **Stability Matrix** | Images and video | Very high | Per-package venv; **shared** `Models/` | Stable Diffusion, ComfyUI, LoRA training |
| **LynxHub** | Universal (all AI) | High | Per-card install dir; optional shared or per-module venv | A unified hub for multiple AI categories |
| **LM Studio** | Large language models | Very high | Embedded engines; models are files | Local text chatting and Hugging Face search |
| **Ollama** | Large language models | Medium (CLI backend) | Containerized-like engine; content-addressed blobs | Lightweight local background LLMs |

### Pinokio

Desktop “AI browser.” Featured Discover apps are frozen under
[pinokiofactory](https://github.com/pinokiofactory) after review; “Latest”
is GitHub `topic:pinokio`. Extra remote: paste any public git URL
([docs](https://program.pinokio.computer),
[repo](https://github.com/pinokiocomputer/pinokio)).

**Package:** a git repo with `pinokio.js` (UI), `install.js` /
`install.json`, `start.js` / `start.json`, optional `update.js`,
`reset.js`. Generator: [Gepeto](https://gepeto.pinokio.computer).

**Runtime:** git clone into `$PINOKIO_HOME/api/<app>`. JSON-RPC scripts
run `pip` / `uv` / `conda` / `npm`. **Not Docker.** Bundled tools live in
`bin/`. Per-app `venv`; bulky weights can `fs.link` into a shared
`drive/`. Scripts can escape `$PINOKIO_HOME` — filesystem isolation, not
a sandbox.

**Cleanup:** Update / Reinstall / Factory Reset (`reset.js` wipes the app,
keeps the launcher) / Delete (remove `api/<app>`). Uninstalling Pinokio
itself **leaves the home tree**. `cache/` is disposable.

**Steal:** named lifecycle files (`install` / `start` / `update` /
`reset`); extra git URL; shared cache vs per-app state. **Do not steal:**
Caddy / wifi / Cloudflare “share” as a publish path — that is the
opposite of `tailscale serve`.

### Stability Matrix

Package manager for Stable Diffusion WebUIs
([docs](https://docs.lykos.ai/stability-matrix/),
[GitHub](https://github.com/LykosAI/StabilityMatrix)). Two indexes:
**packages** (curated GitHub UIs, pin to tag/commit) and **models**
(CivitAI + Hugging Face) dropped into `Models/{StableDiffusion,Lora,VAE,…}/`.

**Runtime:** bundles Git, `uv`, and Python into `Assets/`. Clones each UI
to `Packages/<name>/` with its own venv. Models are shared once via
symlink (default), or isolated per package.

**Cleanup:** delete a package drops that clone+venv; `Models/` and
`Images/` stay. Receipt is root `settings.json`. Portable `Data/` +
`.sm-portable` is the recommended unit.

**Steal:** two-index split (apps vs blobs); shared library with an
explicit “isolate this one” switch; pin the UI commit *and* the Python
backend. Relocate must copy files, not flip a pointer.

### LynxHub

Electron workspace that clones, **locates**, and launches existing AI
WebUIs as cards. Explicitly not a magic one-click installer
([docs](https://docs.lynxhub.app),
[repo](https://github.com/TheLynxHub/LynxHub)).

**Catalogue:** official `plugins.json` on
[LynxHub-Statics](https://raw.githubusercontent.com/KindaBrazy/LynxHub-Statics/source/plugins.json).
Submit via PR. Plugin = compiled `scripts/main.mjs` + `metadata` branch
(`metadata.json`, `versioning.json`). No user remotes; extras = drop into
`Plugins/` or **Locate** an already-installed folder.

**Runtime:** `git clone` or attach. Runs native commands in a PTY (often
`python … --host 127.0.0.1`). Not Docker. Python Toolkit can share one
venv across cards or isolate per module.

**Cleanup:** card `uninstall()` typically `trashDir(installDir)`. Settings
**Reset** unlinks cards and **does not delete** cloned WebUIs. Leftovers:
clone tree, venvs, models.

**Steal:** **Locate vs clone** (adopt an existing `~/services/<name>`
instead of always fetching). Launch on `127.0.0.1`. Reset ≠ purge.

### LM Studio

Desktop (and headless `llmster`) app to download and serve local LLMs
([docs](https://lmstudio.ai/docs/app), CLI
[lms](https://github.com/lmstudio-ai/lms)).

**Catalogue:** Hugging Face GGUF/MLX via in-app search, “Use this model”,
or `lms get`. Layout keeps `publisher/model/file.gguf`.

**Runtime:** closed app; engines are **LM Runtimes** (llama.cpp, Apple
MLX) that hot-swap without a full app bump (`lms runtime
{ls,get,select,update,remove}`). No per-model Python. Load/unload is
memory, not disk.

**Cleanup:** app, runtime, and model are three knobs. Deleting the app
leaves `~/.lmstudio`. `lms runtime remove` does not delete weights.
Weakest official graded-uninstall story of the five.

**Steal:** separate **engine** from **weights** (our analog: compose
runtime vs named volume). `lms unload` = stop; `lms runtime remove` =
teardown keep data. **Do not steal:** leaving leftovers undocumented.

### Ollama

Single Go binary that pulls, tags, and serves models
([GitHub](https://github.com/ollama/ollama),
[docs](https://docs.ollama.com/)). Vendors llama.cpp; optional Docker
`ollama/ollama`. Already on this box, hard-locked in the launcher.

**Catalogue:** [ollama.com/library](https://ollama.com/library)
(`llama3.2:1b`). Import via [Modelfile](https://docs.ollama.com/modelfile)
+ `ollama create`. Registry is OCI-shaped: name/tag → manifest → layers.

**Runtime:** daemon on `127.0.0.1:11434`. One binary is CLI, daemon, and
per-model runner. Disk isolation is **content-addressed**:
`manifests/<host>/<ns>/<model>/<tag>` points at `blobs/sha256-<digest>`.
Two tags that share weights store one blob.

**Cleanup:** `ollama rm` drops the manifest; unreferenced blobs go. App
uninstall and `~/.ollama` (or `/usr/share/ollama`) are documented as
separate steps. Pin the binary with `OLLAMA_VERSION`.

**Steal:** the cleanest **index vs blob** and **tag pin** of the five.
Receipt = manifest. `rm` name ≠ wipe the blob store. Loopback bind is
already correct.

### What this family adds to the target shape

| Pattern | From | Service analog here |
|---|---|---|
| Index vs blob | Ollama manifests / SM `Models/` | Catalogue row ≠ image layers or `~/services/<name>` |
| Shared library + optional isolate | SM symlinks; Pinokio `fs.link` | Shared media/model dirs; never clone a 20 GB volume per UI |
| Engine ≠ payload | LM Studio runtimes vs GGUF | Compose/unit vs named volume |
| Locate vs clone | LynxHub | Adopt an existing marker dir; do not always re-fetch |
| Named lifecycle files | Pinokio `install` / `start` / `reset` | `hooks/` plus today’s `setup.sh` escape hatch |
| Graded uninstall | All five, Ollama clearest | stop → un-serve → keep data → `--purge` |
| Extra git URL | Pinokio Discover | Foreign remotes, prefixed ids |
| Reset keeps the hub | Pinokio Factory Reset; LynxHub Reset | Uninstalling Immich must not uninstall the launcher |

These hubs are **not** a security sandbox and **not** a Tailscale publish
story. Steal catalogue + isolation + cleanup semantics. Keep Compose (or
a native unit) as the runtime, and `tailscale serve` as the only publish
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
- A catalogue **page** over today’s hand-edited `services.json`. The grid
  already is that: available / planned tiles plus Deploy.

## Build order

Agreed 2026-09-15. Planning only; no implementation in the session that
wrote this. A catalogue page is the next *surface*, not the next *slice*.

The launcher grid is already a storefront over a hand-edited registry.
Shipping another browse/install page before the apply path exists would
duplicate that list and lock the UI to `services.json`.

Build in this order:

1. **Index** — `launcher.yml` / `index.json` so an app is data, not a new
   `setup.sh` folder. *Started 2026-10-25:* the tile half landed as
   `services/<id>/app.json` (JSON, not YAML, to stay stdlib-only) plus
   `app/web/registry.json`, merged by `scripts/build-registry.py` into the
   `services.json` the launcher already reads. Ports, env schema and images
   are not in the manifest yet. Official remote = this repo. Port allocator can
   land here or with apply.
2. **Receipt** — write `~/services/launcher/instances/<id>.json` on
   install (remote, revision, ports, image digests, data dir). *Landed
   2026-10-25* for launcher deploys (repo, revision, ports, data dir; no
   image digests yet), see `app/web/SPEC.md` v5. Derive
   tiles (and later Homepage / Kuma) from receipts plus the index.
3. **Apply** — fetch → allocate ports → write `.env` if absent →
   `compose up` or native hook → Serve (still the one interactive step)
   → receipt. This is `install <id>` with no agent in the loop.
4. **Catalogue page** — browse the *index*, install through apply, show
   receipt state (installed / available / planned). *Landed 2026-10-25* at
   `#/catalogue` (`app/web/SPEC.md` v6). Decided the same day: "apply" is
   the existing deploy of the app's `setup.sh`, so catalogue apps keep the
   full service contract and there is no compose-only installer (step 3
   reduces to the receipt that deploy now writes). Only now does a
   dedicated page earn its keep.
5. **Remove** — stop + un-serve, keep data; `--purge` deletes
   `~/services/<id>` and the receipt. *Landed 2026-10-25* as the launcher
   Remove action over per-service `teardown.sh` (`app/web/SPEC.md` v7);
   `--purge` stays terminal-only, and the receipt records `removed_at`
   instead of being deleted. Align with
   [teardown-sh.md](teardown-sh.md). `app/web/SPEC.md` still lists
   uninstall as out of scope until this lands.
6. **Foreign remotes** — extra git URLs, prefixed ids, rewrite-or-refuse
   `0.0.0.0`. After first-party apply is boring.

Do not start (4) until (1)–(3) can install one Compose app from the
index. Do not start (6) until (5) can take it back off.

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
   a drift source in `services/homepage/SETUP.md`.
5. **Uninstall API** — `app/web/SPEC.md` currently lists uninstall as
   out of scope. A catalogue without remove is half a marketplace.
   Align with [teardown-sh.md](teardown-sh.md). Sequence is decided:
   after apply, with the catalogue page; see **Build order**.
6. **Catalogue page chrome** — board vs a new route, how foreign remotes
   appear. *When* to build it is not open (after index + receipt +
   apply). Only the UI shape is.

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
- Pinokio scripts and home tree:
  [program.pinokio.computer](https://program.pinokio.computer),
  [github.com/pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio)
- Stability Matrix packages vs `Models/`:
  [docs.lykos.ai/stability-matrix](https://docs.lykos.ai/stability-matrix/),
  [github.com/LykosAI/StabilityMatrix](https://github.com/LykosAI/StabilityMatrix)
- LynxHub plugins and locate-vs-clone:
  [docs.lynxhub.app](https://docs.lynxhub.app),
  [LynxHub-Statics `plugins.json`](https://raw.githubusercontent.com/KindaBrazy/LynxHub-Statics/source/plugins.json)
- LM Studio runtimes vs weights:
  [lmstudio.ai/docs/app](https://lmstudio.ai/docs/app),
  [github.com/lmstudio-ai/lms](https://github.com/lmstudio-ai/lms)
- Ollama library, Modelfile, blob store:
  [docs.ollama.com](https://docs.ollama.com/),
  [github.com/ollama/ollama](https://github.com/ollama/ollama)
