# teardown.sh — audit and landmines

Audited 2026-09-15 against this repo’s actual `setup.sh` files, per-service
`TROUBLESHOOT.md` nuke recipes, `app/web/services.json`, and a live
Paperclip / OpenHands split-and-redeploy on `kai-home-server`.

*Status 2026-10-25:* the contract below shipped as an optional file
(`AGENTS.md` → "teardown.sh"), with `services/stirling-pdf/teardown.sh` as
the reference and the launcher's Remove action running it without
`--purge`. Since then: firefly-iii, home-assistant, homepage, jellyfin,
metabase, n8n, open-webui, umami; then vaultwarden, immich, paperless-ngx,
seafile, appflowy, plane. Services without one keep their **Nuke
and pave** recipe as the authority.

## Recommendation

Add a **narrow** `teardown.sh` per service. Do **not** make “nuke and
pave” the default.

`setup.sh` already deploys, upgrades, and repairs. The launcher and
ntfy-control already start / stop / restart via `control` in
`app/web/services.json`. What is missing is the inverse of
**publish + run**: stop this service’s process, drop **this** Tailscale
Serve mapping, keep `.env` and data, then `./setup.sh` can bring it back
cleanly.

That is what had to be done by hand when Paperclip and OpenHands moved
out of the combined `paperclip-openhands/` folder.

Default teardown keeps data. `--purge` (typed confirmation, e.g. the
service name) is the only path that deletes `~/services/<name>`. Even
then it must refuse `~/.claude`, `~/.codex`, `~/.paperclip/cli`, and
sibling Serve maps.

A shared eight-line `compose down && rm -rf && serve off` will take down
a neighbour, leave a half-dead instance, or wipe the wrong tree. The
recipes in TROUBLESHOOT.md already disagree in dangerous ways; encoding
those disagreements is the point of the script.

Do not make `teardown.sh` required for every service on day one. Start
where the landmines are real: **Paperclip, OpenHands, Forgejo, AdGuard,
code-server** (and the launcher, because it shares `:443`). The rest of
the Docker services are almost the same compose-down + serve-off, and
can copy the first working one.

## What already exists

| Thing | Role |
|---|---|
| `services/<service>/setup.sh` | Deploy / upgrade / repair. Idempotent. Never overwrites a user-edited config. |
| `services/<service>/tests/run-tests.sh` | Mocked sandbox by default; `--live` is status + health + Serve + loopback bind. |
| `services/<service>/TROUBLESHOOT.md` | Layered triage and a **Nuke and pave** recipe. |
| Launcher + ntfy-control | Allowlisted start / stop / restart from `services.json`. |
| `services/jellyfin/enable-nvenc.sh` | One-off sudo GPU plumbing. `setup.sh` stays out of it on purpose. |
| `services/kaichenpedia/deploy.sh` | Wiki poller, not a deploy. |
| `services/monitoring/seed_kuma.py` | Central monitor seeder. |

Nuke recipes exist for every service that has a TROUBLESHOOT.md except
`beszel` (static-analysis exception) and `remote-desktop` (has a long
teardown section plus the GDM warning). They are copy-paste, not
runnable, and that is currently a feature: several of them must not be
run on autopilot.

## Scripts that would pay off

| Script | Verdict | Why |
|---|---|---|
| **`services/<service>/teardown.sh`** | Yes, narrow | Inverse of publish+run. Stop unit/container, `tailscale serve --https=$PORT off` (never `reset`), leave `.env` and data. `--purge` only after confirmation. |
| **Repo-level backup** | Yes, later | `DIRECTORY.md` already calls out no backup job. One `scripts/backup.sh` that copies named data dirs + `.env` (mode 600) to Seafile beats 22 half-baked `backup.sh` files. Vaultwarden, Immich, Paperless, Forgejo, and Paperclip `master.key` are the ones that hurt to lose. |

## Do not add per service

- **`start.sh` / `stop.sh` / `restart.sh`** — duplicate of launcher +
  ntfy-control. Two allowlists will drift.
- **`status.sh` / `health.sh` / `logs.sh`** — `--live`, `docker compose
  logs`, `journalctl --user -u …`, `paperclipai service logs` already
  cover this.
- **`upgrade.sh`** — that is `./setup.sh`.
- **`purge.sh` as a second file** — keep wipe as a flag on teardown so
  tab-complete cannot pick the destructive name by accident.
- **An uninstall that also drops lingering, the docker group, or
  `tailscale set --operator`** — those are box-wide, not per-service.

Keep as one-offs, do not generalize: `services/jellyfin/enable-nvenc.sh`,
`services/kaichenpedia/deploy.sh`, `services/monitoring/seed_kuma.py`.

## Contract if `teardown.sh` ships

Treat it like `setup.sh`:

- Regular user, root-refused, Linux + macOS (`uname -s`).
- Reads ports and data paths from the existing `.env`. If `.env` is
  missing, die rather than guessing `~/services/<name>`.
- Default: stop this service, unpublish **this** HTTPS port (and any
  extra Serve path this service owns, e.g. launcher `/home` on `:443`).
  Data dir, `.env`, host Claude/Codex dirs, and every other Serve map
  stay.
- `--purge`: typed confirmation. Deletes the service data dir named in
  `.env`. Still does not touch `~/.claude`, `~/.codex`,
  `~/.paperclip/cli`, or another service’s Serve port.
- Never `tailscale serve reset`.
- Never `tailscale serve --https=443 off` from a script that is not
  code-server’s teardown — and code-server’s teardown must restore or
  call out the launcher `/home` mount.
- Mocked tests: Serve-off called for the right port; data dir still
  there unless `--purge`; neighbour ports not touched.
- Document the service-specific guards below in that service’s
  TROUBLESHOOT.md (point at the script, do not duplicate a second
  recipe that can drift).

# Landmines

A naive “stop, `rm -rf`, serve off, re-run” looks symmetric with
`setup.sh` and is not. These are the steps that take down a neighbour,
leave a half-dead instance, or wipe the wrong data.

## Box-wide

**`tailscale serve reset`** clears every mapping on this node, not one
port. The only safe unpublish is `tailscale serve --https=$PORT off`
(plus `--set-path=…` when this service owns a path on a shared port).

**A shell that predates the docker group** makes `docker` look down when
it is not. `sg docker -c …` before believing an outage. The launcher
already re-enters via `sg docker`; a teardown script must do the same.

**`.env` is never regenerated** by a working `setup.sh`. Deleting data
but keeping `.env` (or the reverse) is how you get a new instance whose
password authenticates nothing. UI password changes also drift from
`.env` on Paperless, Kuma, Seafile, Immich — the file is a stale copy
after first boot.

**Lingering, docker group, and `tailscale set --operator=$USER` are
box-wide.** Tearing down one service must not disable them.

## code-server and the launcher share `:443`

`tailscale serve --https=443 off` removes **both** code-server at `/`
and the launcher at `/home/`. To drop only the launcher:

```bash
tailscale serve --https=443 --set-path=/home off
```

That leaves code-server’s `/` alone. If you really take `:443` down,
re-run `app/web/setup.sh` afterwards. It is idempotent.

`~/services/launcher` is not just job logs. It holds `overrides.json`
(edited tile names) and `notes.json` (per-service notes). Neither is in
git, neither is backed up. `rm -rf ~/services/launcher` is the only way
to lose them.

code-server’s own nuke also deletes `~/.local/lib/code-server-*` and
`~/.config/code-server`. That is editor state, not the launcher.

## AdGuard is tailnet DNS

Stopping AdGuard while `100.85.87.87` is still a nameserver in the
Tailscale admin console takes DNS down for every device. Order is:

1. Remove the nameserver at login.tailscale.com/admin/dns.
2. Verify another device still resolves.
3. Then stop the container / unpublish `:3080`.

Reverse of deploy: the nameserver is deliberately **manual** because it
changes DNS for the whole tailnet at once.

The container runs as **root**, so host files under `conf/` and `work/`
are root-owned. `rm -rf ~/services/adguard` without sudo fails halfway
and leaves a worse tree than either extreme. Paths in `.env`
(`ADGUARD_CONF`, `ADGUARD_WORK`) are the authority, not the default
directory name — a `rm` of a path that was never used is a silent no-op
that looks like a clean slate.

A bounce (`compose restart` / `setup.sh`) also drops the resolver for a
few seconds. Fine for retries; not fine during a call. The UI’s
Protection → pause is the right “stop filtering for a minute.”

## Forgejo hides `.admin-created`

`ls` does not show it. Delete `~/services/forgejo/data` but leave that
marker and `setup.sh` skips admin creation. You get a login page, a
password in `.env`, and no account.

`--purge` has to delete the whole `~/services/forgejo` (or the marker
too). There is no “keep the repos, rebuild only the account layer”: the
SQLite DB *is* the metadata. Until there is a backup job, GitHub stays
canonical.

## Paperclip hops ports and owns credentials teardown must not touch

If Serve still holds `:3100` on the tailnet IP, a restart looks like
“port busy” and the process moves to **3101**. Drop Serve first
(`tailscale serve --https=3100 off`), then stop or restart the unit.

Do not delete:

- `~/.paperclip/cli` — the managed CLI store
- `~/.paperclip/instances/default/secrets/master.key` — losing it makes
  stored credentials unreadable
- `~/.claude` / `~/.codex` — host logins, never created by setup

`onboard --yes` starts a foreground `paperclipai run` that never
returns (measured on `paperclipai` 2026.831.1). That is why `setup.sh`
backgrounds it and kills the leftover. A teardown that re-runs onboard
is the wrong tool; default teardown is `paperclipai service uninstall`
plus Serve off.

Never leave `"local_trusted"` in `config.json` after the instance has
been published. Serve would then expose an unauthenticated board to the
tailnet. `setup.sh` and the live suite die if that string is still
there.

CEO invite + agent markers live under `~/services/paperclip/` (migrated
from `~/services/paperclip-openhands/`). Rotating the invite is a
`--force` on `auth bootstrap-ceo`, not a side effect of teardown.

## OpenHands 502s if the data dir is host-only `0700`

The UI on `:8000` is ingress. `/api` is proxied to the agent server on
`:18000` *inside* the container, running as uid **10001**. If
`~/services/openhands/data` is `0700` and host-owned, it cannot mkdir
`conversations/`, exits, and every Canvas call 502s
`ECONNREFUSED 127.0.0.1:18000`. `setup.sh` grants `u:10001:rwx` via ACL
(or `a+rwx` where `setfacl` is missing). Do not chmod a `~/.claude`
mount to “fix” that.

`container_name` is `openhands-agent-canvas`. Recreating it under a new
compose project (`paperclip-openhands` → `openhands`) collides unless
the old container is removed first. Bind-mount data is unchanged.

Rotating `OPENHANDS_API_KEY` in `.env` without matching the UI locks
`--public` mode out. Teardown must not rewrite `.env`. The creds overlay
`docker-compose.creds.yml` is written once and never overwritten;
deleting it drops the `~/.claude` / `~/.codex` mounts on the next up.

Do not mount `/` or `$HOME` into the container.

## Syncthing: identity vs files vs listener

`~/services/syncthing/config` is the Device ID. Deleting it makes every
peer see a **new** device; they must re-add this box. `data/` is the
synced files — a different delete. `db/` only is “rescan everything.”

The GUI is loopback behind Serve on `:8384`. The sync listener is this
node’s tailnet IP on `:22000` (tcp+quic), because peers dial it directly
and QUIC is UDP. Relays and global discovery are off, so
`dynamic` on a peer never finds this box — the address has to be
`tcp://kai-home-server.taild6a23f.ts.net:22000`.

If `.env` survives but `config.xml` does not, a stale
`SYNCTHING_LISTEN_IP` will generate a listener that cannot bind.
`setup.sh` dies on that; a purge must not leave that split state.

## Vaultwarden, Paperless, Immich — no backup

This box has no backup job. A purge is the only copy of:

- the password vault (`~/services/vaultwarden`)
- the tax/document archive (Paperless)
- the photo library (Immich)

Paperless TROUBLESHOOT.md says to export before nuke. Vaultwarden’s
`/admin` panel is deliberately off. Losing the Vaultwarden data dir
loses every password unless a client-side encrypted export exists
somewhere else.

## Immich stop order

Server (and ML, if on) **before** Redis and Postgres. `docker stop a b
c` stops in parallel and will yank the DB out first. The launcher
already sequences one container per command; teardown must too.

`IMMICH_ML` defaults off on this 7.7 GB box. A purge does not need to
touch that flag.

## remote-desktop

Do not reconfigure GDM or the graphical target from SSH. A broken
display manager cannot be fixed from a remote session that depends on
it, and this machine is used physically.

`:3389` is wildcard-bound and cannot be changed (GLib helpers take no
address). nftables (`inet remote_desktop`) is the only LAN lock. Do not
delete that table as a “cleanup” unless the daemon is also going away.

Unpublish is `tailscale serve --https=8094 off` only. Same `serve reset`
ban as everywhere else.

## ntfy and the launcher are not “just another service”

Stopping ntfy removes the phone control topic. Stopping the launcher
removes the UI that can start anything else. Both are locked in
`services.json` (`locked` / in-code backstop). A teardown.sh for those
two should refuse to run without an explicit override, or not exist.

Kuma pause/resume is wired into start/stop so a bounce does not page
the phone. A teardown that kills the container without pausing the
monitor will.

## Home Assistant first-boot config

`configuration.yaml` exclusions (`bluetooth`, `go2rtc`) only bite
**before** the container’s first start. HA persists config entries in
`.storage/`. Nuke-and-pave after that does not undo them by rewriting
the YAML. Location/units left for the UI on purpose — auto-completing
that step pins lat/long to 0 and TZ to UTC permanently.

## Firefly III has two Serve ports

App `:8097` and Data Importer `:8099`. Teardown must drop both. Postgres
is unpublished on purpose; `compose down -v` is what destroys it.

## Paperclip / OpenHands leftover from the split

The combined folder is gone. Live leftover that a Paperclip/OpenHands
teardown might still see:

- compose project label `paperclip-openhands` on an old container (adopt
  by `docker rm -f openhands-agent-canvas` if the label matches, then
  up from `services/openhands/`)
- `~/services/paperclip-openhands/` marker (CEO invite already copied to
  `~/services/paperclip/`)

Default teardown of either service must not stop the other. They share
`~/agent-workspaces` but not a process.

## What `--purge` must never delete

| Path | Why |
|---|---|
| `~/.claude`, `~/.codex` | Host agent logins. No service creates or replaces them. |
| `~/.paperclip/cli` | Managed CLI store. Instance data is `instances/default`. |
| `~/.paperclip/instances/default/secrets/master.key` | Unless the operator is ready to lose stored Paperclip credentials. Copy it off-box first (Seafile `:8443`). |
| Another service’s Serve port | Especially `:443` from anyone but code-server, and AdGuard’s nameserver in the admin console. |
| `~/services/launcher/{overrides,notes}.json` | User-authored, not in git. |
| Syncthing `data/` when the operator meant `config/` | Identity vs files. |
| Lingering / docker group / tailscale operator | Box-wide. |
