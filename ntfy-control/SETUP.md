# ntfy-control — start/stop services from the ntfy phone app

A small listener that turns the existing tailnet-only ntfy server into a
remote control: publish `stop seafile` to the `control` topic from the ntfy
app, and the box stops the Seafile stack and pauses its Uptime Kuma monitor
so the intentional downtime doesn't page you. Replies arrive on the `alerts`
topic you're already subscribed to.

## Architecture

```
ntfy app (phone, on the tailnet)
      │ publish "stop seafile" -> topic `control`
      ▼
ntfy server (tailnet-only, :3003)
      ▲ loopback subscribe (curl -sN …/control/json)
      │
control_listener.py  (systemd user unit / launchd, Restart=always)
      │ allowlist match — message text is NEVER executed
      ├── docker stop|start|restart <containers>   (order-aware for seafile)
      ├── systemctl --user <cmd> code-server
      ├── uv run … kuma_toggle.py pause|resume     (best-effort)
      └── reply -> topic `alerts`
```

## Security model

- No new ports, nothing published — the listener subscribes over loopback;
  the only way to reach the control topic is via the tailnet-only ntfy.
- Commands are a **strict allowlist**: the message is matched against fixed
  verbs (`status`/`stop`/`start`/`restart`) and a fixed service map, each
  resolving to a hard-coded `docker`/`systemctl` invocation. Arbitrary text
  gets a usage reply, nothing more.
- `ntfy` itself (and the monitoring stack's availability to restart it) is
  deliberately *not* controllable — stopping ntfy remotely would cut off
  the ability to undo it.
- `.env` holds no secrets; Kuma credentials are read at call time from
  `monitoring/.env`.

## Controllable services

| Command target | What it maps to |
|---|---|
| `seafile` | containers `seafile`, `seafile-mysql`, `seafile-redis` (stop: app first; start: deps first) |
| `open-webui`, `n8n`, `kaichenpedia`, `uptime-kuma` | their containers |
| `code-server` | `systemctl --user` unit |

Stopping/starting also pauses/resumes the matching Kuma monitor (skipped
with a note in the reply if Kuma is unreachable — e.g. after
`stop uptime-kuma`).

## What setup.sh does

1. Preflight: docker daemon, python3, curl, and ntfy healthy on
   `127.0.0.1:3003` (deploy `monitoring/` first).
2. Writes `.env` if absent (topics, ntfy URL, path to `monitoring/.env`,
   tool path for `uv`).
3. Installs `control_listener.py` + `kuma_toggle.py` into
   `~/services/ntfy-control/bin/` (refreshed every run).
4. Installs and (re)starts the listener: systemd user unit with
   `Restart=always` + lingering on Linux; a KeepAlive LaunchAgent on macOS.

## Deploy

```sh
cd ntfy-control && ./setup.sh
```

Overrides: `CONTROL_TOPIC` (default `control`), `REPLY_TOPIC` (`alerts`),
`NTFY_PORT` (3003).

## Phone setup

1. Install Tailscale on the phone and log in (the ntfy server is
   tailnet-only — without this nothing connects).
2. ntfy app → add subscription → topic `alerts` → "Use another server" →
   `https://kai-home-server.taild6a23f.ts.net:3003`. Leave
   username/password **empty** — the server has no accounts; Tailscale is
   the auth layer.
3. Sending commands — depends on platform:
   - **iOS (primary): notification buttons.** The iOS ntfy app is
     receive-only (no compose box), so the listener puts the controls *in*
     the notifications, navigated verb-first (ntfy caps buttons at 3 per
     notification, hence the shape):
     - `panel` → one **menu card**: body is the live service list,
       buttons `[start] [stop] [restart]`.
     - Tap a verb → a **picker** showing only applicable services
       (`stop`/`restart` list active ones, `start` lists stopped ones),
       one button per service, split across cards of 3.
     - Tap a service → it runs; the reply carries buttons for the state
       the service is *now* in, plus `[menu]` back to a fresh menu card.
     Everything goes through the same allowlist as typed commands.
     `setup.sh` publishes the menu automatically at the end of every run
     (and warns with a full onboarding walkthrough if no phone is found
     on the tailnet — ntfy has no subscriber API and iOS delivery rides
     the ntfy.sh push relay, so the tailnet peer list is the best
     available "can a phone even connect?" signal). Re-pop the menu any
     time: the `[menu]` buttons, re-running setup.sh, opening
     `https://<host>:3003/control/publish?message=panel` in Safari, or
     `curl -d panel http://127.0.0.1:3003/control` from the box.
   - **ntfy web app (no-install fallback).** The server hosts ntfy's full
     web UI at `https://<host>:3003` — it *does* have a compose box.
     Subscribe to `control` there and type commands; "Add to Home Screen"
     makes it app-like.
   - **Android**: subscribe to `control` in the app, tap the pen icon,
     type commands directly.
4. Send `status` — the reply appears as an `alerts` notification within a
   couple of seconds.

## Ops

```sh
systemctl --user status ntfy-control
journalctl --user -u ntfy-control -f          # every command is logged
curl -d "status" http://127.0.0.1:3003/control   # test from the box
```
