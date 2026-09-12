# syncthing — troubleshooting

Work down the layers. Each one assumes the ones above it are green.

```bash
cd ~/dev/setup-server/syncthing && ./tests/run-tests.sh --live
```
does all of this in one go and prints the device ID, folder list and
connected-device count at the end. When everything in the box is red at
once, check `tailscale serve status` first — a broken tailscaled takes every
service's tailnet URL down together.

## Layer 1 — is the service running?

```bash
systemctl --user status syncthing
journalctl --user -u syncthing -n 100 --no-pager
```

| Symptom | Cause | Fix |
|---|---|---|
| `inactive (dead)` after a reboot, never started | lingering off — user services only start at login | `sudo loginctl enable-linger $USER`, or just `./setup.sh` |
| `activating (auto-restart)` in a loop, exit code 203 or "No such file" | `~/.local/bin/syncthing` missing or not executable (interrupted upgrade) | `./setup.sh` reinstalls the pinned version |
| exits with status 3 or 4 repeatedly | a restart was requested (3) or an upgrade attempted (4); 3 once is normal after a GUI change | the unit treats both as success and restarts; a *loop* of 3s means the config is being rejected — see the log for `config` errors |
| `Failed to load config` / `config.xml: syntax error` | a hand edit broke the XML | fix it, or restore `config/` from backup, or nuke-and-pave (loses identity) |
| `database is locked` / db errors on start | a second instance is running against the same `db/` | `pgrep -af "syncthing serve"`; kill the stray, restart the unit |
| high CPU for a long time right after deploy or after adding a folder | initial hashing of every file | normal; large folders take a while. `Settings → Advanced → maxFolderConcurrency` throttles |

## Layer 2 — does it answer locally?

```bash
curl -s http://127.0.0.1:8384/rest/noauth/health          # {"status":"OK"}
KEY=$(sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' ~/services/syncthing/config/config.xml)
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/status | head -c 300
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: kai-home-server.taild6a23f.ts.net:8384' http://127.0.0.1:8384/
```

| Symptom | Cause | Fix |
|---|---|---|
| health refuses the connection but the unit is active | still starting (db open, folder scan) | wait 10 s; if it persists check the log for a GUI bind error |
| health OK, API calls 403 `Not Authorized` | wrong or regenerated API key | read it fresh from `config.xml` (above); the GUI can also show it under Settings → GUI |
| the third command prints **403** (body: *Host check error*) | `insecureSkipHostcheck` is off — the GUI rejects the tailnet Host header that Serve forwards | in `config.xml`, inside `<gui>`: `<insecureSkipHostcheck>true</insecureSkipHostcheck>`, then `systemctl --user restart syncthing`. `./setup.sh` reports this exact case |
| GUI bound somewhere other than `127.0.0.1:8384` | changed in Settings → GUI | change it back there, or in `config.xml` → `<gui><address>`, and restart; anything non-loopback is reachable off the tailnet |

## Layer 3 — is it published?

```bash
tailscale serve status                 # expect: https://…:8384 → proxy http://127.0.0.1:8384
curl -s https://kai-home-server.taild6a23f.ts.net:8384/rest/noauth/health
```

| Symptom | Cause | Fix |
|---|---|---|
| no `:8384` line in `serve status` | serve config lost (tailscale reinstall/reset) | `./setup.sh` re-publishes |
| HTTPS hangs or fails for ~a minute right after deploy | Let's Encrypt cert being minted for this port | wait, retry |
| HTTPS answers on one device, not another | that device is not on the tailnet, or its DNS is not MagicDNS | `tailscale status` on it; use the IP `https://100.85.87.87:8384` to distinguish DNS from connectivity |
| `Access denied` when `setup.sh` runs serve | operator rights lost | `sudo tailscale set --operator=$USER`; `setup.sh` does this itself |

## Layer 4 — peers cannot connect (the usual one)

This box **does not dial out** and **cannot be found by `dynamic`**. Every
connection problem starts from those two facts.

```bash
ss -ltnup 'sport = :22000'              # expect exactly: 100.85.87.87:22000 tcp AND udp
tailscale ip -4                         # must match the address above
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/status \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["connectionServiceStatus"], indent=1))'
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/connections
```

| Symptom | Cause | Fix |
|---|---|---|
| peer shows this box as *Disconnected* forever; this box's GUI never showed a "new device" banner | the peer's entry for this box says `dynamic` | on the **peer**, edit this device → Advanced → Addresses → `tcp://kai-home-server.taild6a23f.ts.net:22000` |
| banner appeared, you clicked Add Device, still not syncing | folder not shared to that device, or the peer has not accepted the folder | on this box, edit the device → Sharing; on the peer, accept the folder offer |
| `connectionServiceStatus` shows `"error": "… cannot assign requested address"` | the tailnet IP changed; the listener still names the old one | Settings → Connections → Sync Protocol Listen Addresses → `tcp://<new ip>:22000, quic://<new ip>:22000`; set `SYNCTHING_LISTEN_IP` in `.env`; `./setup.sh` |
| `ss` shows nothing on `:22000` | same as above, or tailscaled not up | `tailscale status`; Syncthing retries the bind by itself once the address exists |
| `ss` shows `0.0.0.0:22000` or a LAN address | listen address changed to `default`/`0.0.0.0` in the GUI | put the tailnet address back (above). `./setup.sh` flags this and exits 1 |
| peer connects, then drops with a TLS / certificate error | clock skew on one side, or the peer holds a stale Device ID for a rebuilt box | fix the clock; or remove and re-add the device on the peer with the new ID |
| connects over TCP only, never QUIC (or vice versa) | one protocol blocked by the peer's network | harmless; either one syncs fully. `connections` shows which |
| MagicDNS name does not resolve on the peer | MagicDNS off for that device, or a corporate DNS override | use `tcp://100.85.87.87:22000` instead — it is also stable unless the node re-joins the tailnet |
| peer on the same LAN connects only slowly | local discovery is off here, so the peer cannot short-cut over the LAN | expected; traffic goes over the tailnet (which is direct WireGuard on a shared LAN anyway) |

## Folders

| Symptom | Cause | Fix |
|---|---|---|
| folder shows **Stopped**, log says `folder marker missing` | `.stfolder` deleted, or the path unmounted / not yet created | recreate: `mkdir <folder>/.stfolder`; or fix the mount |
| folder shows **Stopped**, `insufficient space` | `minDiskFree` (1 %) tripped | free space; the check protects against half-written files |
| `permission denied` on files | Syncthing runs as this user; files owned by someone else (a Docker container wrote them, say) | `chown -R $USER` the folder, or choose a path this user owns |
| conflicts: `name.sync-conflict-2026…` files | both sides edited between syncs | keep the one you want; delete the other. Versioning on this box keeps history |
| `Out of Sync` with items that never clear | an item that cannot be written: too-long name, a file where a directory is expected, an ignored parent | click the count in the GUI; the per-item reason is listed |
| a folder you added on the laptop never appears here | the offer must be **accepted on this box** (banner on this box's GUI) | accept it; set `autoAcceptFolders` on that device's entry if you want this automatic |
| `Unexpected Items` after nuke-and-pave | files present in the folder that the fresh index has not indexed | Override / Revert per the GUI prompt, or rescan |

## Upgrade problems

| Symptom | Cause | Fix |
|---|---|---|
| `Checksum mismatch` | corrupted download, or a tampered mirror | re-run; if it persists, do not install — fetch the checksum list yourself and compare |
| `… is not listed in the release's sha256sum.txt.asc` | version tag exists but has no asset for this OS/arch (rare), or a pre-release | pick a release that ships `syncthing-linux-amd64-<ver>.tar.gz` |
| `Download failed` | typo in `SYNCTHING_VERSION` (needs the leading `v`), or GitHub unreachable | check the tag on github.com/syncthing/syncthing/releases |
| after a major bump the service loops or refuses the config | config migration failed | restore `config/` from your backup and go back to the previous version in `.env` |

## Nuke and pave

This destroys the device identity: every peer will see a **new** device and
must re-add it. The synced files under `data/` are left alone unless you
delete them too.

```bash
systemctl --user disable --now syncthing
rm -f ~/.config/systemd/user/syncthing.service && systemctl --user daemon-reload
tailscale serve --https=8384 off
rm -rf ~/services/syncthing/config ~/services/syncthing/db      # identity + index
# rm -rf ~/services/syncthing/data                              # the files — only if you mean it
rm -f ~/dev/setup-server/syncthing/.env
cd ~/dev/setup-server/syncthing && ./setup.sh
```

To keep the identity and only reset the index (a "make it rescan
everything" reset), stop the service, delete `db/` only, start it.
