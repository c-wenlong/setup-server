# quiver-hub: Troubleshooting

Work top-down: each layer depends on the one above it.

```
1. service running?  →  2. local /v1/status?  →  3. serve config?  →  4. tailnet HTTPS?  →  5. pairing / client
```

Quick triage (run on the hub):

```sh
systemctl --user is-active quiver-hub.service       # expect: active
curl -fsS http://127.0.0.1:8477/v1/status           # expect: {"ok": true, ...}
tailscale serve status                              # expect: :8477  / proxy http://127.0.0.1:8477
curl -fsS https://kai-home-server.taild6a23f.ts.net:8477/v1/status
```

Or just: `./tests/run-tests.sh --live`

Use the hub's own build for every `swe remote ...` command below. The `swe`
on the interactive PATH may predate `swe remote serve --public-url`
(setup.sh warns when it does):

```sh
S=~/.local/share/quiver-hub/bin/swe
```

## 1. Service won't start / keeps restarting

```sh
journalctl --user -u quiver-hub.service -e --no-pager
```

- **`cannot bind 127.0.0.1:8477`**: the port is taken. `ss -ltnp | grep 8477`.
  Stop the other process, or set another `LOCAL_PORT` (and `HTTPS_PORT`) in
  `.env` and re-run `./setup.sh`. Then re-pair satellites: their stored hub
  URL carries the old port.
- **`unknown command: remote`**, `unknown flag: --public-url`, or a Python
  traceback at import: the build is
  broken or too old. `cat ~/.local/share/quiver-hub/installed-rev`, then
  `rm ~/.local/share/quiver-hub/installed-rev && ./setup.sh` to force a clean
  reinstall of the current `QUIVER_REF`.
- **`No such file or directory` for `.../quiver-hub/bin/swe`**: the tool dir
  was deleted. Re-run `./setup.sh` (it reinstalls when the binary is missing).
- **Service dies at logout / after reboot**: lingering is off.
  `loginctl show-user $USER -p Linger`; fix: `sudo loginctl enable-linger $USER`.

## 2. Local /v1/status fails but the unit is "active"

- Just restarted? The hub starts its tailers first; give it a few seconds.
- Curling the wrong port: `grep ExecStart ~/.config/systemd/user/quiver-hub.service`.

## 3. `tailscale serve` errors

- **`Access denied: serve config denied`**: not the Tailscale operator.
  `sudo tailscale set --operator=$USER` (one time), retry.
- **`Serve is not enabled on your tailnet`**: open the printed
  `login.tailscale.com/f/serve?...` URL from a logged-in device, approve,
  retry.
- **setup.sh: `HTTPS :8477 is already published for http://127.0.0.1:NNNN`**:
  another service owns that HTTPS port. Pick a free one in `.env`
  (`HTTPS_PORT=`), re-run. Never take it over by hand.
- **Serve config missing after a tailscaled upgrade**: re-run `./setup.sh`,
  or `tailscale serve --bg --https=8477 http://127.0.0.1:8477`.
- Never `tailscale serve reset` (wipes every service on the node) and never a
  bare `--https=443` (replaces code-server's `/`). To unpublish only this
  service: `tailscale serve --https=8477 off`.

## 4. HTTPS URL doesn't load from the phone

- **First request on a new port can hang ~30-60 s** while the cert is minted.
- **Phone not on the tailnet**: Tailscale app connected? The URL resolves and
  routes only inside the tailnet.
- **MagicDNS off**: the `*.ts.net` name won't resolve. Turn it on in the
  admin console (DNS).

## 5. Pairing and client problems

- **"Pair with Tailscale" answers `not_tailnet`**: the hub is not running
  with `--public-url`, so it sees the phone as `127.0.0.1`.
  `grep ExecStart ~/.config/systemd/user/quiver-hub.service` should end in
  `--public-url=https://...:8477`; if not, re-run `./setup.sh`. If it does,
  the phone may not be on the tailnet itself (a browser on a device that only
  reaches the box some other way). Token pairing still works: `./pair.sh`.
- **The code shows, but nothing approves it**: approve on the hub,
  `$S remote devices --requests` then `$S remote devices --approve=<code>`.
  The phone can't approve its own request, five wrong codes deny it, and the
  request expires after 5 minutes.
- **`swe remote pair` (or `pair.sh`) prints an `http://` link**: the hub
  hasn't written `~/.quiver/data/remote/hub.json` with its public URL, so it
  predates `--public-url` or hasn't started since. Re-run `./setup.sh`. Also
  check you ran the hub's build (`$S`), not an older `swe` on PATH.
- **`unknown or expired pair token`**: tokens are single-use and last 5
  minutes. Run `./pair.sh` again.
- **Browser approval on the `#approve` page fails (`bad_origin`)**: the
  public URL in the unit doesn't match the address in the browser (another
  port or hostname). Re-run `./setup.sh` after changing `HTTPS_PORT`, and
  open the exact `https://<host>:<port>` it prints.
- **ntfy lock-screen Allow/Deny buttons go nowhere**: they are built from
  `--public-url`, so the same check as the first bullet applies.
- **PWA shows "pair this device first" after it worked**: the device was
  revoked, or `~/.quiver/data/remote/devices.json` was lost. `$S remote devices`
  to check; re-pair (Pair with Tailscale, or `./pair.sh`).
- **MacBook satellite never shows up**: on the Mac, `swe remote agent` must
  have been paired against the https URL:
  `swe remote agent --hub=https://kai-home-server.taild6a23f.ts.net:8477 --token=<token>`.
  `pairing failed` there means a bad or expired token, or the Mac is off the
  tailnet (`curl https://kai-home-server.taild6a23f.ts.net:8477/v1/status`
  from the Mac). On the hub, `$S remote status` lists the machines it knows.
- **Sessions from this box missing or read-only**: the hub only sees
  harnesses on the unit's `PATH` (see SETUP.md). `systemctl --user show
  quiver-hub.service -p Environment` and compare with `command -v claude codex tmux`.

## Nuke and pave

Back up first if you might want the paired devices back (`~/.quiver/data/remote/`
is Quiver's, and neither command below touches it):

```sh
tar czf ~/quiver-remote-backup.tgz -C ~/.quiver/data remote   # optional
./teardown.sh --purge     # type quiver-hub: unpublishes :8477 (this port only),
                          # disables + stops the unit, deletes .env and the unit file
rm -rf ~/.local/share/quiver-hub                               # the hub build (teardown keeps it)
./setup.sh
```

`./teardown.sh` without `--purge` (what the launcher's Remove runs) only
unpublishes and stops the hub; `.env`, the unit file and the build stay, so
`./setup.sh` brings it back as it was. Neither mode touches the `swe` on your
PATH, `~/.quiver`, lingering or the Tailscale operator, and units it did not
write are named but left alone. On macOS both modes unload the LaunchAgent
and delete its plist (it would start again at login; `setup.sh` rewrites it).

Because `~/.quiver/data/remote/` survives, paired phones and satellites keep
working once the hub is back on the same port. `--purge` deletes `.env`, so a
hub that ran on a non-default port comes back on 8477: re-pair every MacBook
satellite (`./pair.sh`, then `swe remote agent --hub=... --token=...`) and the
phones. To forget every device as well, also `rm -rf ~/.quiver/data/remote`
before `./setup.sh`, then re-pair each one.
