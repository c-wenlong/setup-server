# ntfy-control — troubleshooting

Layered triage: phone → ntfy server → listener → the action itself.

## Quick status

```sh
systemctl --user is-active ntfy-control            # listener up?
journalctl --user -u ntfy-control -n 20            # what it saw/did
curl -fsS http://127.0.0.1:3003/v1/health          # ntfy up?
curl -d "status" http://127.0.0.1:3003/control     # end-to-end from the box
```

## Layer 1 — nothing happens when I send a command

- **From the box**, run `curl -d "status" http://127.0.0.1:3003/control`.
  If a reply lands in the `alerts` topic, the server side is fine — the
  problem is the phone (Layer 0 below).
- No reply → is the listener running?
  `systemctl --user restart ntfy-control`, then check
  `journalctl --user -u ntfy-control -n 20` — a healthy start logs
  `listening on http://127.0.0.1:3003/control/json`.
- Repeated `subscribe error … reconnecting` → ntfy itself is down:
  `docker start ntfy` (this is why ntfy isn't remotely controllable).

## Layer 0 — phone can't reach ntfy at all

- Tailscale app installed, logged in, and **connected**? Test by opening
  `https://kai-home-server.taild6a23f.ts.net:3002` (Kuma) in the phone
  browser.
- Service URL must be exactly `https://kai-home-server.taild6a23f.ts.net:3003`
  — https, port included, no trailing path.
- Username/password: leave empty. If the app version insists on
  credentials on that screen, you're likely in "Manage users / default
  server" — add the server during **subscribe** ("Use another server")
  instead.

## Layer 2 — command runs but reports FAILED

- The reply includes the first 300 chars of the docker/systemctl error.
- `(kuma pause failed)` note → Kuma is stopped or `monitoring/.env` is
  missing; the service action itself still succeeded.
- Never got a "start" to work after `stop uptime-kuma`? Start order is
  fine — the kuma *monitor* resume fails while Kuma boots; harmless.

## Layer 3 — command executed but service still "down"

- `docker ps -a` — check the container's real state; a crash-on-start is a
  service problem, not a control problem. See that service's
  TROUBLESHOOT.md.
- Remember `restart: unless-stopped`: a service stopped via ntfy stays
  stopped across reboots until you `start` it again.

## Nuke and pave

```sh
systemctl --user disable --now ntfy-control
rm -f ~/.config/systemd/user/ntfy-control.service
systemctl --user daemon-reload
rm -rf ~/services/ntfy-control ~/dev/setup-server/ntfy-control/.env
cd ~/dev/setup-server/ntfy-control && ./setup.sh
```
Stateless — nothing is lost by re-deploying.
