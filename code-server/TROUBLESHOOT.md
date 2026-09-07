# code-server — Troubleshooting

Work top-down: each layer depends on the one above it.

```
1. service running?  →  2. local healthz?  →  3. serve config?  →  4. tailnet HTTPS?
```

Quick triage (run on the server):

```sh
systemctl --user is-active code-server        # expect: active
curl -fsS http://127.0.0.1:8080/healthz       # expect: {"status":...}
tailscale serve status                        # expect: proxy http://127.0.0.1:8080
curl -fsS https://$(tailscale status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')/healthz
```

Or just: `./tests/run-tests.sh --live`

## Service won't start / keeps restarting

```sh
journalctl --user -u code-server -e --no-pager
```

- **`EADDRINUSE`** — port taken. Find the culprit: `ss -ltnp | grep 8080`.
  Either stop it or redeploy on another port: `PORT=9000 ./setup.sh`
  (delete `~/.config/code-server/config.yaml` first — the script won't
  overwrite an existing config), then re-run `tailscale serve --bg` for the
  new port.
- **`code-server: command not found` in logs** — `~/.local/bin/code-server`
  symlink broken. Re-run `./setup.sh`.
- **Service dies at logout / after reboot** — lingering is off. Check
  `loginctl show-user $USER -p Linger`; fix: `sudo loginctl enable-linger $USER`.

## Local healthz fails but service is "active"

- Config may bind a different port than you're curling:
  `grep bind-addr ~/.config/code-server/config.yaml`
- Just restarted? It needs a few seconds. `sleep 3` and retry.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — you're not the Tailscale
  operator: `sudo tailscale set --operator=$USER` (one time), retry.
- **`Serve is not enabled on your tailnet`** — one-time enablement: open the
  printed `login.tailscale.com/f/serve?...` URL from any logged-in device,
  approve, retry. Requires HTTPS certs + MagicDNS enabled on the tailnet.
- **Serve config missing after tailscaled restart/upgrade** — reapply:
  `tailscale serve --bg http://127.0.0.1:8080`

## HTTPS URL doesn't load from the client

- **First request after (re)configuring Serve can hang ~30–60 s** while the
  Let's Encrypt cert is minted. Wait, retry.
- **Client not on the tailnet** — is Tailscale up on the MacBook? Can you
  `ping <server-tailscale-ip>`? The URL only resolves/routes inside the tailnet.
- **DNS doesn't resolve** — MagicDNS must be on (tailnet admin console →
  DNS). Fallback test bypassing DNS: `curl -k https://<tailscale-ip>` (cert
  won't match the bare IP; `-k` is fine for connectivity testing only).
- **Tailnet name changed** — URL changes with it; `tailscale serve status`
  shows the current one.

## In-editor problems

- **Extension not found** — code-server uses the Open VSX registry, not
  Microsoft's marketplace. Some Microsoft-only extensions (Pylance,
  Remote-SSH) aren't available; look for open alternatives.
- **Clipboard doesn't work** — only guaranteed over HTTPS (secure context).
  If you bypassed Tailscale Serve and use plain `http://ip:8080`, that's why.
- **Webviews/preview panes blank** — same secure-context issue; use the
  HTTPS `ts.net` URL.
- **Editor state feels corrupted** — stop the service, move
  `~/.local/share/code-server` aside, restart (settings/extensions reset).

## Nuke and pave

```sh
systemctl --user disable --now code-server
tailscale serve --https=443 off
rm -rf ~/.local/lib/code-server-* ~/.local/bin/code-server \
       ~/.config/code-server ~/.config/systemd/user/code-server.service
systemctl --user daemon-reload
./setup.sh
```
