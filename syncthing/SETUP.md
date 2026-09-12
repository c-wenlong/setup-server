# syncthing — peer-to-peer folder sync across your devices

Continuous, two-way sync of chosen folders between this box and your laptop
and phone, with no third party in the path. GUI on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8384`.

## What this is, and how it differs from Seafile

Seafile (`:8443`) is **the Drive**: files live on the server, you browse them
in a web UI, share links, and the clients sync selected libraries down.
Syncthing has no server in that sense. Every device holds a full copy of
each shared folder and they keep each other current directly, device to
device. There is no web file browser, no share links, no accounts.

What Syncthing is for on this box:

- **Folders that should simply be identical everywhere** — dotfiles, an
  Obsidian or notes vault, a KeePass database, `~/projects/<thing>` — with
  the change appearing on the other machine seconds after you save.
- **This box as the always-on hub.** A laptop and a phone are rarely on at
  the same time; this box is. Share a folder to it and the two others sync
  through it whenever each comes online. Since the hub keeps a full copy,
  it is also an incidental backup of those folders (enable *file
  versioning* on the server side and it keeps old versions too).
- **Anything you'd rather not upload into a server application at all.**
  Syncthing writes plain files into a plain directory; nothing is stored in a
  database, and every device can read its copy with the service down.

What it is not for: browsing files from a browser (Seafile), photos (Immich
owns the camera roll — do not also sync it here, or every photo lands twice),
or sharing with people outside the tailnet.

## Architecture

One static binary, one user service, two ports published two different ways:

```
  laptop / phone Syncthing app                  browser, on the tailnet
  (each holds its own copy)                      │  https://kai-home-server…:8384
            │                                    ▼
            │  dials tcp://kai-home-server.taild6a23f.ts.net:22000   tailscaled — Tailscale Serve
            │  (also quic://, same port)                              terminates TLS, tailnet only
            │                                    │  http://127.0.0.1:8384
            ▼                                    ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ syncthing serve   (systemd user unit: syncthing.service)       │
   │   BEP sync listener   100.85.87.87:22000  tcp + quic(udp)      │  ← tailnet IP,
   │   GUI + REST API      127.0.0.1:8384      no GUI password,     │    NOT loopback,
   │                                           REST key-gated       │    NOT 0.0.0.0
   │   relays / global discovery / LAN multicast / NAT-PMP:  OFF    │
   │   usage + crash reporting: OFF     self-upgrade: OFF (pinned)  │
   └──────────────┬────────────────────┬──────────────────┬─────────┘
                  ▼                    ▼                  ▼
   ~/services/syncthing/config   …/syncthing/db    …/syncthing/data
   config.xml + cert/key         index database    the sync root
   (= this device's identity)    (rebuildable)     ("default" folder here)
```

State lives under `~/services/syncthing` and the binary in `~/.local/bin`:

```
~/.local/bin/syncthing           # v2.1.5, pinned; setup.sh replaces it on a version bump
~/services/syncthing/
  config/                        # SYNCTHING_CONFIG — back this up
    config.xml                   #   every setting + the REST API key (mode 600)
    cert.pem, key.pem            #   the device key pair; the Device ID is derived from it
  db/                            # SYNCTHING_DB — the file index. Rebuilt by a rescan.
  data/                          # SYNCTHING_DATA — the sync root
    default/                     #   the one folder setup.sh creates (id: default)
      .stfolder/                 #   Syncthing's marker; if it vanishes the folder stops
```

**`config/` is the identity.** The Device ID that every peer has accepted is
a hash of `cert.pem`. Lose that directory and this box becomes a *new*
device to every peer, which all have to re-add it. Copy it somewhere off
this machine.

## Why the sync port is on the tailnet IP and not on loopback

Every web service in this repo binds `127.0.0.1` and is fronted by Tailscale
Serve. Syncthing's GUI does exactly that. Its **sync protocol cannot**: other
devices dial this one directly by address — the protocol has no notion of a
reverse proxy in front of it — and half of it is QUIC over UDP, which Serve
does not carry. So `:22000` binds `100.85.87.87`, this node's tailnet IPv4,
the same deliberate exception AdGuard's resolver already makes.

It still meets the spirit of the rule. `tailscale0` is not the LAN and not
the internet: only a device already authenticated onto this tailnet can send
a packet to that address. `tests/run-tests.sh --live` asserts that `:22000`
is bound to the tailnet address and to nothing else, tcp and udp both, and
`setup.sh` checks the socket table after every run and exits non-zero if
anything else holds the port.

Measured on this box: if the service starts before `tailscale0` is up (dockerd
and tailscaled race at boot; so can a user service), Syncthing logs
`bind: cannot assign requested address`, **keeps running with the GUI
healthy, and retries the bind on its own**. No unit ordering is needed and
none is configured.

## Security model

- **Tailnet-only, both ports.** GUI on loopback behind Serve; sync on the
  tailnet address. Nothing on `0.0.0.0`, nothing on the LAN, no firewall
  rule opened.
- **No third-party infrastructure is contacted, at all.** Upstream defaults
  register this device with the public relay pool, announce it to the global
  discovery servers, broadcast on the LAN, ask the router for a port mapping,
  and phone home with usage and crash reports. Every one of those is off.
  On a tailnet none of them is needed: peers have stable MagicDNS names and a
  direct route. The trade: **devices must be added with an explicit
  address** (below). `dynamic` never resolves here.
- **No GUI password, on purpose.** Same reasoning as code-server: the tailnet
  is the access layer, and nobody off it can reach `:8384`. Syncthing nags
  about this; the nag is dismissed. Set a user/password in Settings → GUI if
  you want one; `setup.sh` neither requires nor removes it and reports which
  it found. The REST API is API-key-gated regardless (key in `config.xml`).
- **The GUI host check is relaxed** (`insecureSkipHostcheck=true`). Syncthing
  refuses requests whose `Host` header is not localhost when it is bound to
  loopback — a DNS-rebinding guard. Serve forwards the original tailnet Host
  header, so without this every page is a 403 "Host check error" (measured).
  The guard protects GUIs any browser on the machine can reach; here the only
  path to `:8384` carrying a foreign Host is Serve, which is tailnet-only.
- **Version pinned, self-upgrade off.** `SYNCTHING_VERSION` in `.env` is the
  only way the binary changes; the download is verified against the
  release's sha256 list. Syncthing's own updater (`--no-upgrade`,
  `autoUpgradeIntervalH=0`) is disabled so it cannot replace the binary
  behind the pin.
- **The unit is hardened** with upstream's own lines: `ProtectSystem=full`,
  `PrivateTmp`, `NoNewPrivileges`, `MemoryDenyWriteExecute`. Consequence:
  Syncthing can sync folders anywhere under your home and `~/services`, but
  **not** under `/etc`, `/usr` or `/boot`.
- **Peers are authenticated by key**, not by network position. A device that
  reaches `:22000` still cannot exchange a byte until you accept its Device
  ID in the GUI, and it sees only the folders you share with it. For a peer
  you do not fully trust (a friend's machine holding a copy), share the
  folder as **Receive Encrypted** — it stores ciphertext and never sees
  filenames or contents.
- **Files are plain files, owned by you**, at whatever path you chose. There
  is no container, no root, no volume: `ls` shows them, `rsync` backs them up.

## Dependencies

| Dependency | Why | Installed by |
|---|---|---|
| Tailscale, logged in | tailnet address, MagicDNS name, Serve for the GUI | you, beforehand |
| curl | download + REST | preinstalled |
| python3 (stdlib) | patches `config.xml` before the first start; parses REST JSON | preinstalled on Ubuntu/macOS |
| tar (Linux) / unzip (macOS) | extract the release | preinstalled |
| sha256sum or shasum | verify the download | preinstalled |
| systemd user session (Linux) / launchd (macOS) | keep it running, start at boot | OS |

No Docker, no root. Sudo is asked at most twice on Linux, once each, for
`loginctl enable-linger` and `tailscale set --operator`, and never again.

## What `setup.sh` does

1. **Preflight.** Not root; curl + python3 + tar/unzip + sha256; Tailscale
   running; resolves the MagicDNS name and the tailnet IPv4 (dies without
   one — there is nothing to bind).
2. **`.env`** — written only if absent, mode 600: version, the three ports,
   the tailnet IP, the three directories. Read back as the source of truth;
   env-var overrides are ignored on a re-run with a warning.
3. **Install / upgrade.** If `~/.local/bin/syncthing --version` already
   reports the pinned version, skip. Otherwise download the release asset for
   this OS/arch and the release's `sha256sum.txt.asc`, verify the digest
   (dies on mismatch or if the asset is not listed), extract, and
   replace-in-place. The running service keeps its old inode until restart.
4. **Identity + config**, first run only. `syncthing generate` creates the
   key pair and a default `config.xml`; then a stdlib-python patch rewrites
   it **before the first start**: listeners → `tcp://<ts-ip>:22000` and
   `quic://…`, relays/global/local discovery/NAT/LAN-announce off, usage +
   crash reporting declined, auto-upgrade off, GUI address
   `127.0.0.1:8384`, host check relaxed, password nag dismissed. The
   generated defaults would otherwise go live on `0.0.0.0` and register with
   the relay pool within seconds of the first start; that window never opens.
   An existing `config.xml` is never touched.
5. **Service.** Writes `~/.config/systemd/user/syncthing.service` (or the
   LaunchAgent), enables it, restarts it. `--no-restart` + `Restart=always`
   is upstream's design: a GUI-requested restart exits 3 and systemd brings
   it back.
6. **Waits for `/rest/noauth/health`** — treating a refused connection as
   "not yet", not failure.
7. **Verifies the running instance over REST**, not the file: device ID,
   the options above, the GUI address and host-check setting. On a fresh
   deploy a mismatch is fatal (the patch did not take). On a re-run,
   **exposure drift is repaired** — listeners, relays, global and local
   discovery, NAT traversal, the GUI address and the host-check bypass are
   put back through `PATCH /rest/config/…`, the same call the GUI makes,
   so every other setting in `config.xml` is left as you made it; a GUI
   repair restarts the service — and then **checks the socket table**, not
   the API, before it says the GUI is back on loopback. The API would only
   read back the change just written to it, and health passing proves
   nothing (a wildcard bind answers on `127.0.0.1` too), so if the restart
   is refused, or `:8384` is still on `0.0.0.0` afterwards, the run dies
   rather than claim a repair. **Preference drift** (usage or crash
   reporting turned on, self-upgrade interval) is reported and left alone:
   it is your choice, and self-upgrade is inert under `--no-upgrade` anyway.
8. **Default folder**, first run only: `POST /rest/config/folders` creates
   `default` at `SYNCTHING_DATA/default`, shared with nobody.
9. **Lingering** (Linux) so the service starts at boot.
10. **Tailscale Serve**: HTTPS `:8384` → `http://127.0.0.1:8384`, with the
    operator-grant and approval-link loop.
11. **End-to-end**: health over the tailnet URL, then the GUI root (the
    request a browser makes, with the Host header Serve actually forwards —
    a 403 here is the host check and is reported with the fix). Then the
    socket table: `:22000` must be bound to the tailnet IP and nothing else,
    and `:8384` must answer only on loopback plus this node's tailnet
    addresses (that row is tailscaled's Serve frontend, on the same port
    number the GUI binds).
12. Prints the Device ID, the sync address, and how to add a device.

Exit status is non-zero only if step 11 still finds a sync listener off the
tailnet, a GUI answering off loopback, or a GUI that 403s after the repairs
above; if a repair itself was refused by the API; or if the box has neither
`ss` nor `lsof`, so the GUI's bind could not be checked at all — the deploy
is up in those cases, but not as designed, or not shown to be. (A socket
tool that runs and simply sees nothing bound yet is a warning, not a
failure: that is the normal, self-healing state while `tailscale0` comes
up.)

## Adding your devices

Two facts shape every step: **this box never dials out** (discovery and
relays are off, so it waits for peers to connect to it), and **`dynamic`
never resolves it** (that needs global discovery). So each device is told
this box's address explicitly, and it is the device that connects.

### Laptop (macOS / Linux / Windows)

1. Install Syncthing (`brew install syncthing`, your distro's package, or the
   Windows installer) and open its GUI (`http://127.0.0.1:8384` locally).
2. **Add Remote Device** → paste this box's Device ID (printed by `setup.sh`;
   also on this box's GUI under Actions → Show ID). Under **Advanced →
   Addresses** replace `dynamic` with:
   ```
   tcp://kai-home-server.taild6a23f.ts.net:22000
   ```
   Save. Within a minute the laptop connects; this box's GUI shows a
   "new device" banner.
3. On this box's GUI, **Add Device** from that banner. Tick the `default`
   folder to share it (or share nothing yet and add a folder below).
4. Back on the laptop, accept the folder offer and pick a local path.

The laptop can keep its own defaults (relays, discovery) if you like — those
only govern how *it* is found. This box is found by the address you typed.

### Android

The official app is *Syncthing-Fork* (F-Droid or Play). Add device → paste
ID → expand → Addresses → the same `tcp://…:22000` line. Accept on this box.
Sharing the camera folder here is possible but redundant with Immich.

### iPhone / iPad

There is no official iOS app. **Möbius Sync** and **Synctrain** on the App
Store are third-party ports; both accept a Device ID and a static address the
same way. iOS background limits mean sync happens while the app is open or
briefly after; do not expect it to keep a folder current all day.

### Adding a folder on this box

GUI → **Add Folder** → any path this user can write to (`~/…` or
`~/services/syncthing/data/…`; the unit's `ProtectSystem=full` makes `/etc`,
`/usr`, `/boot` read-only). Under **Sharing** tick the devices. On each
device, accept and choose where it lands. For an important folder, turn on
**File Versioning** (Staggered is a good default) on this box so the hub
keeps history.

### Device names

Syncthing shows the name the *other* side declares. Rename any device from
its edit dialog on this box; the name is local to this box's config.

## Ops

```bash
# status / logs
systemctl --user status syncthing
journalctl --user -u syncthing -f
# restart / stop / start
systemctl --user restart syncthing
# what it is doing, from the API (key is in config.xml)
KEY=$(sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' ~/services/syncthing/config/config.xml)
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/status | head -c 400
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/connections
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/config/folders
# the publish
tailscale serve status
# verify everything (service, sockets, house rules, HTTPS)
./tests/run-tests.sh --live
```

**Upgrade.** Pick a release at github.com/syncthing/syncthing/releases, set
`SYNCTHING_VERSION=vX.Y.Z` in `.env`, `./setup.sh`. It downloads, verifies,
replaces the binary and restarts. Config is never touched; Syncthing
migrates its own config version forward on start (one-way — keep a copy of
`config/` before a major bump).

**Backup.** `~/services/syncthing/config` is the identity and every setting;
copy it off this box. The synced folders are ordinary directories — back
them up like any other. `db/` is rebuildable and not worth backing up.

**Move the sync root.** Folders reference absolute paths; moving `data/`
means editing each folder's path in the GUI (or `config.xml`, service
stopped). `SYNCTHING_DATA` in `.env` only sets where `setup.sh` created
`default`.

**Change a port.** Edit `.env`, then `./setup.sh`: it sees the running
listener (or GUI address) disagree with `.env`, repairs it over REST, and
re-publishes. You can equally change it in the GUI first; the next run
aligns the publish.

**Tailnet IP changed** (re-joined the tailnet, new node key). The listener is
bound to the old address and fails to bind. Set `SYNCTHING_LISTEN_IP` in
`.env` to the new address and `./setup.sh` — it repoints the listener over
REST. Peers using the MagicDNS name need no change. If `config.xml` does not
exist yet (restored `.env`, wiped config directory) the run **refuses** to
generate one instead: a fresh config pinned to an address this host does not
hold could never bind, and every later check in the script would agree with
itself and miss it.

**Turn it off.** `systemctl --user disable --now syncthing` and
`tailscale serve --https=8384 off`. The files stay where they are.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | the deploy, idempotent |
| `.env` | generated, gitignored: version, ports, tailnet IP, directories |
| `tests/run-tests.sh` | mocked suite (real tar/sha256/XML patch in a sandbox) + `--live` |
| `tests/stubs/syncthing.tmpl` | the fake binary the curl stub packages into the mocked release tarball |
