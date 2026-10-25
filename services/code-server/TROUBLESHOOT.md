# code-server — Troubleshooting

Work top-down: each layer depends on the one above it.

```
1. service running?  →  2. local healthz?  →  3. serve config?  →  4. tailnet HTTPS?
```

Quick triage (run on the server):

```sh
systemctl --user is-active code-server        # expect: active
curl -fsS http://127.0.0.1:8080/healthz       # expect: {"status":"alive",...}
tailscale serve status                        # expect: / proxy http://127.0.0.1:8080
curl -fsS https://$(tailscale status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')/healthz
```

Or just: `./tests/run-tests.sh --live`

From a phone or another machine, the launcher at
`https://kai-home-server.taild6a23f.ts.net/home/` shows code-server's live
status and has a restart button — and it is served by a *different* backend
(:8093), so it still works when code-server itself is the thing that's down.

## :443 is shared — read this before touching Serve

`:443` carries two mounts, added by two different `setup.sh` scripts:

```
https://kai-home-server.taild6a23f.ts.net (tailnet only)
|-- /     proxy http://127.0.0.1:8080     # code-server (this service)
|-- /home proxy http://127.0.0.1:8093     # launcher
```

- **Never run a bare `tailscale serve --https=443 http://...`** for anything
  else. It replaces the `/` handler and code-server goes dark instantly, with
  no error. A second service on :443 must use
  `--set-path=/<name>`, which is additive and leaves `/` alone.
- **Never run `tailscale serve reset`.** It is one of only two removal verbs
  `tailscale serve --help` advertises, and it wipes the serve config for the
  *entire node* — every mapping on it, every published service dark at
  once, each one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=<port> off`; `off` is absent from `--help` on
  1.102.3 but is what Tailscale prints after a successful serve, and it works
  on this box.
- Re-running this service's `setup.sh` is safe: it issues the bare
  `tailscale serve --bg http://127.0.0.1:8080`, which sets only `/`.

## Service won't start / keeps restarting

```sh
journalctl --user -u code-server -e --no-pager
```

- **`EADDRINUSE`** — port taken. Find the culprit: `ss -ltnp | grep 8080`.
  Either stop it or redeploy on another port: `PORT=9000 ./setup.sh`
  (delete `~/.config/code-server/config.yaml` first — the script won't
  overwrite an existing config). `setup.sh` re-publishes for you; by hand it
  is `tailscale serve --bg http://127.0.0.1:9000` — bare, no `--https=443`.
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
- **`/` 404s or serves the wrong app, but `/home/` still works** — something
  else claimed `/` on :443 with a bare `--https=443`. Reapply the line above;
  it only touches `/`.
- **Every service on the box went dark at once, not just this one** — that is
  `tailscale serve reset`, or tailscaled itself. `tailscale status` first;
  if tailscaled is fine and `tailscale serve status` is empty, the config was
  reset and every service's `setup.sh` has to be re-run to rebuild it.

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

Use `teardown.sh`, not a hand recipe. It reads code-server's port from
`~/.config/code-server/config.yaml`, and on `:443` (shared with the
launcher's `/home`) it removes only code-server's own path with
`tailscale serve --https=443 --set-path=/ off`, so the launcher stays
published. A port that is all code-server goes off whole. It never runs
`tailscale serve reset` or `--https=443 off` on a shared port.

```bash
# 1. Backup first, if you want the editor state back later
mkdir -p ~/code-server-backup && cp -a ~/.config/code-server ~/.local/share/code-server ~/code-server-backup/

cd ~/dev/setup-server/services/code-server
./teardown.sh            # remove: config, extensions, binary kept (the launcher's Remove)
./teardown.sh --purge    # also delete the unit file; type the name; prints the rm
                         # for config, extensions and binary, which it never runs
# 2. Run the printed rm lines yourself for a truly fresh start, e.g.
#    rm -rf ~/.config/code-server ~/.local/share/code-server \
#           ~/.local/lib/code-server-* ~/.local/bin/code-server
./setup.sh               # back; a fresh config.yaml if you deleted it
```

Stopping is the script's last step. Run from code-server's own integrated
terminal, the terminal closes then, with everything else already done; run it
from SSH or the launcher to see the final lines. Your workspace folders are
never touched. From a terminal, pause the `code-server` monitor in Uptime
Kuma first, or it pages; the launcher's Remove does that.

If something else already took `:443` down whole, re-run `app/web/setup.sh`
to restore the `/home` mount. It is idempotent and touches nothing else.
