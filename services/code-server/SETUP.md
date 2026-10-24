# code-server — VS Code in the browser, tailnet-only

Full VS Code (with integrated terminal) served from a home server, reachable
only from your Tailscale devices at `https://<host>.<tailnet>.ts.net`.

## Architecture

```
Client browser ──HTTPS──▶ Tailscale Serve (:443) ──▶ code-server (127.0.0.1:8080)
        (tailnet only, WireGuard-encrypted)             (localhost only, no password)
```

Security model:
- code-server binds to `127.0.0.1` only — unreachable from LAN or internet.
- Tailscale Serve proxies HTTPS :443 → localhost, reachable **only from tailnet
  devices**. Tailscale device auth is the access-control layer, so code-server
  runs with `auth: none`.
- TLS cert (Let's Encrypt) is provisioned and renewed automatically by
  Tailscale. Real HTTPS means clipboard, service workers, and webviews work.

## Dependencies

| Component        | Role                                        | Installed as                                  |
|------------------|---------------------------------------------|-----------------------------------------------|
| code-server      | VS Code server + web UI                     | Standalone in `~/.local` (no root)            |
| systemd (user)   | Keeps it running, starts at boot            | `~/.config/systemd/user/code-server.service`  |
| tailscaled       | WireGuard mesh VPN + Serve HTTPS proxy      | System service (prerequisite, not installed here) |
| Tailscale Serve  | HTTPS termination + tailnet-only exposure   | Config stored by tailscaled                   |

## Deploy

Prerequisites on the server: Linux, systemd, curl, Tailscale installed and
logged in (`sudo tailscale up`).

```sh
./setup.sh              # default port 8080
PORT=9000 ./setup.sh    # custom local port
```

The script is idempotent — re-run any time to upgrade or repair. It asks for
sudo at most twice, one time each:

1. `loginctl enable-linger` — user services start at boot, survive logout
2. `tailscale set --operator=$USER` — manage Tailscale without root

On a tailnet that has never used Serve, it pauses once with an approval URL
(`https://login.tailscale.com/f/serve?...`) — open it from any logged-in
device, approve, press Enter.

What it does, in order:

1. Preflight: Linux + systemd + curl + Tailscale running; refuses root
2. Installs code-server standalone into `~/.local` (official installer)
3. Writes `~/.config/code-server/config.yaml` (localhost-only, `auth: none`)
   — skipped if one already exists
4. Installs + starts the systemd user unit, waits for local `/healthz`
5. Enables lingering, grants operator (each only if needed)
6. `tailscale serve --bg http://127.0.0.1:$PORT`
7. Verifies `https://<host>.<tailnet>.ts.net/healthz` end-to-end

## Client side

Tailscale installed and logged into the same tailnet — that's it. Open the
printed URL in any browser. Optional: "Install app" (Chrome) / "Add to Dock"
(Safari) turns it into a PWA that feels like desktop VS Code.

## Operations

```sh
systemctl --user status code-server       # is it running?
systemctl --user restart code-server      # after config changes
journalctl --user -u code-server -f       # live logs
tailscale serve status                    # current proxy config
tailscale serve --https=443 off           # unpublish from tailnet
```

Upgrade in place (settings/extensions preserved): re-run `./setup.sh`.

## Tests

```sh
./tests/run-tests.sh          # mocked suite — simulated fresh server, no system changes
./tests/run-tests.sh --live   # + verify the real deployment on this machine
```

The mocked suite runs the real `setup.sh` in a sandbox (fake `$HOME`, PATH
stubs for tailscale/sudo/systemctl/loginctl/curl/id) covering the fresh-install
path, idempotent re-runs, `PORT` override, the Serve approval flow, and
preflight failures.

## Notes

- Extensions come from Open VSX, not Microsoft's marketplace (licensing).
  Most popular extensions exist there; some Microsoft-only ones don't
  (official Pylance, Remote-SSH).
- State lives in `~/.local/share/code-server`, config in `~/.config/code-server`.
- Terminal sessions persist server-side across browser disconnects.
