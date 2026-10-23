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
on the interactive PATH may predate `swe remote` (setup.sh warns when it
does):

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
- **`unknown command: remote`** or a Python traceback at import: the build is
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

- **"Pair with Tailscale" says the device can't be identified (`not_tailnet`)**:
  expected on this deploy. Behind Serve the hub sees every client as
  `127.0.0.1`, and `tailscale whois 127.0.0.1` finds no node. Pair by token:
  `./pair.sh iphone` and open the `https://...#pair=` link it prints.
- **The link from `swe remote pair` doesn't open on the phone**: that command
  prints `http://127.0.0.1:8477/#pair=...`, the bind address. Use `./pair.sh`,
  which prints the `https://` Serve URL. Same token format, so the raw token
  from either works in the **Have a pair token?** field.
- **`unknown or expired pair token`**: tokens are single-use and last 5
  minutes. Run `./pair.sh` again.
- **Approving a pending pair request in a browser fails (`bad_origin`)**: the
  approval routes compare `Origin` with `http://<Host>` and the browser sends
  `https://...`. Approve from the hub instead:
  `$S remote devices --requests`, then `$S remote devices --approve=<code>`.
  (Only reachable once whois pairing works, see the first bullet.)
- **ntfy lock-screen Allow/Deny buttons do nothing**: the hub builds those
  links from its bind address, `http://127.0.0.1:8477`, which the phone
  can't reach. Notifications themselves arrive; answer approvals in the PWA.
- **PWA shows "pair this device first" after it worked**: the device was
  revoked, or `~/.quiver/data/remote/devices.json` was lost. `$S remote devices`
  to check; re-pair with `./pair.sh`.
- **MacBook satellite never shows up**: on the Mac, `swe remote agent` must
  have been paired against the https URL:
  `swe remote agent --hub=https://kai-home-server.taild6a23f.ts.net:8477 --token=<token>`.
  `pairing failed` there means a bad or expired token, or the Mac is off the
  tailnet (`curl https://kai-home-server.taild6a23f.ts.net:8477/v1/status`
  from the Mac). On the hub, `$S remote status --host=127.0.0.1 --port=8477`
  lists the machines it knows.
- **Sessions from this box missing or read-only**: the hub only sees
  harnesses on the unit's `PATH` (see SETUP.md). `systemctl --user show
  quiver-hub.service -p Environment` and compare with `command -v claude codex tmux`.

## Nuke and pave

```sh
systemctl --user disable --now quiver-hub.service
tailscale serve --https=8477 off                     # this port only
rm -rf ~/.local/share/quiver-hub ~/.config/systemd/user/quiver-hub.service
systemctl --user daemon-reload
./setup.sh
```

This keeps `~/.quiver/data/remote/`, so paired phones and satellites keep
working. To forget every device as well, also
`rm -rf ~/.quiver/data/remote` before `./setup.sh`, then re-pair each one.
`.env` survives too; delete it to start from the default ports.
