# home-assistant — local-first home automation

Lights, sensors, switches, media players and the automations that tie them
together, running entirely on this box, on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8123`.

Home Assistant is the one service in this repo whose *whole point* is talking
to hardware on your LAN. Everything else here is a web app that happens to be
self-hosted; this one discovers devices, speaks their protocols, and holds the
state machine that makes "sunset → lamps on" a thing that happens. That
difference drives every design decision below, most visibly the networking.

Chosen over openHAB and Domoticz for the same reason everyone chooses it: the
integration library is enormous and actively maintained, and the local-only
posture is the default rather than a mode you have to fight for. Nabu Casa's
paid cloud is optional and this deploy does not use it — remote access is the
tailnet, not a subscription.

## Architecture

One container, host networking, loopback bind:

```
  phone / laptop / tablet on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8123
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8123
            ▼
   ┌─────────────────────────────────────────────┐
   │ container: home-assistant                   │
   │   ghcr.io/home-assistant/home-assistant     │
   │   :2026.9.1     (pinned, not :stable)       │
   │                                             │
   │   network_mode: host                        │
   │   http.server_host: 127.0.0.1  ← the bind   │
   │                                             │
   │   web + API      :8123 (loopback only)      │
   │   SQLite         (in-process, recorder)     │
   │   discovery      zeroconf / ssdp / dhcp / usb│
   └────────────┬────────────────────────────────┘
                │ bind mount
                ▼
      ~/services/home-assistant/config  →  /config   (rw)
```

State lives under `~/services/home-assistant/config`:

```
~/services/home-assistant/config/
  configuration.yaml       # written by setup.sh, only if absent — yours after that
  .HA_VERSION              # the version that last opened this directory
  .storage/                # THE database of record, JSON, not hand-edited
    core.config_entries    #   every integration instance discovery created
    core.device_registry   #   every device
    core.entity_registry   #   every entity
    http                   #   THE http settings — server_host, proxy trust.
                           #   configuration.yaml has no http: block at all
    auth                   #   users
    http.auth              #   refresh tokens
  home-assistant_v2.db     # recorder: sensor history (the big file)
  home-assistant.log       # also via `docker logs`
  blueprints/  tts/
```

(That tree is what a real boot of this image produces, not a guess.
`custom_components/`, `www/` and `backups/` do not exist until you create them
or take a UI backup. `core.config` — latitude, longitude, units — appears once
you finish the location step at first login.)

Two of those deserve emphasis before anything else:

- **`.storage/` is the real configuration**, not `configuration.yaml`. Almost
  everything you do in the UI lands there as JSON, and it is created on first
  boot. This is the single fact that makes the deploy order matter — see "The
  first-boot window" below.
- **`home-assistant_v2.db` grows forever by default.** It is the recorder
  database, and on a box with no backup it is also the only copy of your
  history. Sensor history is nice; the automations and integrations in
  `.storage/` are the part that would actually hurt to lose.

## Networking: host mode *and* a loopback bind

These look like they contradict each other and the repo's core rule. They do
not, and this was measured on this box rather than reasoned about:

```
ss -ltn | grep 8123
LISTEN 0 128 127.0.0.1:8123 0.0.0.0:*      <- the ONLY listener
curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/     -> 302
curl -o /dev/null -w '%{http_code}' http://100.85.87.87:8123/  -> 000 (refused)
```

`network_mode: host` gives the container the host's network namespace, which
is what makes discovery work — zeroconf/mDNS, SSDP and DHCP sniffing are all
broadcast protocols that a bridge network silently drops. Confirmed loaded via
`/api/config`: `zeroconf`, `ssdp`, `dhcp` and `usb` all present.

`http.server_host: 127.0.0.1` in `configuration.yaml` then tells Home
Assistant's own web server to bind loopback *within* that namespace. So the
service is on the host's loopback and nowhere else, exactly like every other
service in this repo — it just gets there through HA's config instead of
through a Docker port mapping.

**The two must travel together.** Host mode without `server_host` puts 8123 on
every interface on the box, which breaks the repo's security model outright:
anything on the LAN could reach an unauthenticated-until-onboarded Home
Assistant. The mocked suite asserts both, as a pair, for that reason.

### Behind Tailscale Serve

```yaml
http:
  server_host: 127.0.0.1
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

Without those last two, HA **rejects every request that arrives through
Tailscale Serve** with "received request from a reverse proxy that is not
trusted" — a 400 at the door, not a subtle degradation. Serve connects from
the host's loopback, so `127.0.0.1` and `::1` are the entire trusted set;
there is no reason to widen it.

`use_x_forwarded_for` without `trusted_proxies` is a configuration error HA
refuses to start on, so the two are genuinely inseparable.

### The honest trade-off

Host networking is a real privilege increase over bridge mode, and it should
be stated plainly rather than buried:

- The container sees and can bind **every interface on this box**, and can
  reach every service on the host's loopback — including the ones that assume
  loopback means "only me". Ollama on `:11434`, Beszel, ntfy, the lot.
- Container-level network isolation is simply gone. Docker's usual "the blast
  radius of a compromised container is its own netns" argument does not apply.
- The mitigations that remain are: the image is pinned and comes from
  upstream's own registry, HA runs no code you did not install (custom
  components are the thing to be careful with — see Security model), and the
  listener is on loopback, so nothing on the LAN can reach it even though the
  container *could* have opened a LAN port.

This is accepted because discovery is the reason to run Home Assistant at all.
A bridged HA that cannot see your devices is not a smaller version of the
service, it is a different and largely pointless one. It is also what upstream
documents as the supported configuration for the container install. If you
ever run something in HA that you do not trust — a random custom component
from a forum post — remember that it is running with the host's whole network
view.

## `default_config` is expanded by hand, minus two components

`configuration.yaml` does **not** say `default_config:`. It lists that
component's dependencies explicitly, one per line, with exactly two omissions:

```yaml
assist_pipeline:
cloud:
conversation:
dhcp:
energy:
file:
history:
homeassistant_alerts:
logbook:
media_source:
mobile_app:
my:
ssdp:
stream:
sun:
usage_prediction:
usb:
webhook:
zeroconf:
```

That is 19 of the 21 dependencies `default_config` declares in the 2026.9.1
image — the list was read out of the image's `default_config/manifest.json`,
not guessed from documentation. The two missing ones are `bluetooth` and
`go2rtc`, and both were excluded on the strength of a measurement rather than
a preference.

### `bluetooth` — the adapter fight

This box has a USB Bluetooth adapter, `hci0`
(`74:E5:F9:89:1F:4C`), and the host's own `bluetoothd` is running and owns it
(`UP RUNNING PSCAN`). Under host networking, HA's bluetooth integration
auto-discovers `hci0`, tries to take control of the scanner, and loses to
bluetoothd — forever:

```
ERROR [habluetooth.scanner] hci0 (...): Failed to force stop scanner
```

Measured: **24 errors per 60 seconds, indefinitely.** Not a startup blip.

The fix upstream suggests — `--cap-add NET_ADMIN --cap-add NET_RAW` plus a
`/run/dbus` mount — was tried and **does not work here**. It removes the
`PermissionError` line and the scanner fight continues at exactly the same
rate. Two processes cannot share one adapter, and no capability grant changes
that. Excluding the component is the only measure that produced a clean boot:
**0 `habluetooth` mentions, 0 ERROR lines.**

**If you later want Bluetooth**, the honest answer is not "add the
capabilities". It is: stop the host's `bluetoothd` so the adapter is free,
*then* add `bluetooth:` and the two capabilities. See TROUBLESHOOT.md →
Bluetooth. Sharing one adapter between host bluetoothd and HA does not work,
and there is no configuration that makes it work.

### `go2rtc` — a LAN listener the loopback rule cannot reach

`go2rtc` is Home Assistant's WebRTC camera streamer. Loading the integration
starts a separate go2rtc process alongside HA, and that process opens its own
listeners. Measured inside this exact image, by reading `/proc/net/tcp` and
`/proc/net/tcp6` from inside a throwaway container:

```
with    go2rtc:      tcp4  127.0.0.1:18554   RTSP        — loopback, fine
                     tcp4  127.0.0.1:8123    Home Assistant
                     tcp6         :::18555   WebRTC/TCP  — EVERY interface

without go2rtc:      tcp4  127.0.0.1:8123    and nothing else
```

On bridge networking that `:::18555` stays inside the container and nobody
cares. Under `network_mode: host`, which this deploy needs for discovery, it is
the host's every interface — the LAN and the tailnet, plain TCP, with no
Tailscale Serve and no TLS in front of it. It would be the one part of this
deploy reachable without Tailscale, which is exactly what the loopback rule
exists to prevent. Home Assistant offers no setting to move it: the listen
address is baked into the config HA generates for the go2rtc process.

`stream:` stays, so cameras still work — they play over HLS. What is lost is
WebRTC's sub-second latency, and any integration that specifically requires a
go2rtc provider. If you add cameras and decide you want it, the two honest
options are to add `go2rtc:` back and accept that 18555 is open on the LAN, or
to move the container to bridge networking and give up discovery. There is no
third.

⚠️ This contradicts HA-DERISK.md §5, which listed 20 components including
`go2rtc`. That measurement checked `ss -ltn | grep 8123` and so could not have
seen 18555. The finding was reproduced independently by both agents working on
this service before the list was changed.

### The maintenance cost

Expanding the list by hand pins it to 2026.9.1's dependency set. If a future
release adds a component to `default_config`, this file will not pick it up.
That is a known, cheap cost — re-read the manifest on an upgrade, see
TROUBLESHOOT.md → Upgrade problems — and it buys a log you can read and a
listener list you can defend.

## The first-boot window (why config is written before `up`)

This is the sharpest edge in the whole deploy, and it fails **silently**.

Home Assistant creates *config entries* from discovery on its first boot and
persists them in `.storage/core.config_entries`. From then on, that file — not
`configuration.yaml` — decides which integrations are loaded. Two consequences:

- Writing `configuration.yaml` **after** starting the container is too late.
  The bluetooth entry already exists; removing `bluetooth:` from the yaml
  afterwards does nothing. Measured: the errors continued.
- The same applies to `http:`. HA reads it at start; a container that came up
  without `use_x_forwarded_for` will keep rejecting proxied requests until it
  is restarted with the file in place.

So the ordering in `setup.sh` is not stylistic:

```
write configuration.yaml + .storage/http   ->   docker compose up -d   ->   onboard
```

A script that starts the container and then writes config has already failed,
and nothing in its output would say so. The mocked suite's single most
important assertion is that `configuration.yaml` exists on disk before the
first `compose up` — see Tests.

### ⚠️ On 2026.9+, `http:` is not read from YAML at all

This is the part that actually broke the first deploy of this service, and it
is worth understanding rather than trusting.

HA 2026.9 migrated the `http:` block **out of YAML and into `.storage/http`**.
The migration happens once; afterwards `yaml_migration_done: true` is set and
the YAML block is ignored permanently. And the migrated settings do not go
straight into effect — the store holds two slots:

| slot | meaning |
|---|---|
| `stable` | the config actually in use |
| `pending` | a **trial**, preferred on the next boot, auto-reverted unless *promoted* |

Promotion is a frontend confirmation — a human loads the UI and the frontend
tells HA the config worked. **An unattended deploy never does that.** So the
trial reverts, `pending.error` becomes `"not_promoted"`, and since the rule is
"prefer `pending` unless it has already failed a trial", every later boot falls
back to `stable`: the built-in defaults, meaning a **wildcard bind and no
reverse-proxy trust**. Both guarantees vanish one boot after a deploy that
reported success.

This is also why HA-DERISK.md §3's loopback measurement was real but not
durable: it was taken inside the first-boot trial window, before the revert.

`setup.sh` therefore writes `.storage/http` itself, **before the first boot**,
with the settings in `stable` and `pending` explicitly `null` — so there is no
trial to revert and nothing to promote. Verified in a throwaway container:
loopback-only listener, `/api/onboarding` 200, zero ERROR lines, and the state
survives a restart.

And `configuration.yaml` carries **no `http:` block at all**. Keeping one earns
a permanent `yaml_still_present_after_migration` repair notice in the UI;
removing it makes HA clear the deprecation issues instead. In its place the
template carries a long comment explaining where the settings really live, so
`.storage/` is not somewhere you have to guess at. That is why the template has
20 top-level keys — 19 integrations plus `homeassistant` — and no `http`.

On every later run `setup.sh` re-reads the store and classifies it
`ok` / `missing` / `unreadable` / `bad:<specifics>`. Anything but `ok` is
**repaired in place**: it stops the container first (HA rewrites this file on
shutdown, so a repair under a live container is silently overwritten), then
*merges* — it overrides only `server_host`, `use_x_forwarded_for`,
`trusted_proxies` and the error fields, forces `pending: null` and
`yaml_migration_done: true`, and leaves any other key you have set alone. So
**recovery is `./setup.sh`, not a wipe.**

Nothing in this needs `sudo`. The store is `-rw------- root root` and
unreadable from the host after the first boot, so every read and repair runs
`python3` inside the pinned image, which is already root. The clean first-boot
seed needs neither — `.storage` does not exist yet, so it is a plain `printf`.

See TROUBLESHOOT.md → "The yaml says `server_host: 127.0.0.1` but HA binds
`0.0.0.0`" for how to read the store by hand.

## Onboarding: what the script does and what it deliberately leaves

Unlike Vaultwarden — where the master password derives the vault key on the
client and no script can create the account — Home Assistant's password is
server-side, so the account creation is fully scriptable. Measured flow:

```
POST /api/onboarding/users        {"client_id":"http://127.0.0.1:8123/",
                                   "name":…,"username":…,"password":…,
                                   "language":"en"}
  -> 200 {"auth_code":"…"}
  -> 403 {"message":"User step already done"}    on any later run

POST /auth/token   (form-encoded, NOT json)
  grant_type=authorization_code & code=<auth_code> & client_id=<url>
  -> 200 {"access_token":"…","refresh_token":"…","expires_in":1800,…}

POST /api/onboarding/analytics    Bearer + {}   -> 200 {}     (opt out)
```

Three things about this are load-bearing:

- **403 "User step already done" is success.** It is the idempotency signal —
  the account exists, this is a re-run, carry on. A script that treats a 403
  as an error cannot be run twice, which violates the repo's central rule.
- **The `auth_code` is single-use.** A second exchange of the same code
  returns no token (measured: empty `access_token`). The script gets exactly
  one shot per onboarding, which is why the exchange happens immediately and
  its failure is fatal rather than retried with the same code.
- **`core_config` is never called.** `POST /api/onboarding/core_config` with
  `{}` returns 200 and marks the step done — accepting the defaults, which are
  **latitude 0, longitude 0, time_zone UTC** (measured via `/api/config`
  afterwards). That silently breaks every sun-based automation, and the UI
  never asks again because the step is marked complete. Leaving it undone
  means the UI presents its map picker on your first login, which is the
  correct place to answer "where is this house".

Timezone is the exception and is handled in yaml instead
(`homeassistant.time_zone`, taken from the host), because that one *can* be
answered correctly without asking.

## First login — you must finish this

The deploy is deliberately incomplete. After `setup.sh` finishes:

1. Open `https://kai-home-server.taild6a23f.ts.net:8123` from a device on the
   tailnet and log in with the username and password from `.env`.
2. HA presents the **location step**. Set it properly:
   - Drag the map pin to your actual house, or type the address. This drives
     sunrise/sunset, weather, and every `sun.sun` trigger you will ever write.
   - Elevation, unit system (metric), currency.
   - Time zone will already read **Asia/Singapore** from the yaml — leave it.
3. HA then offers **discovered devices**. It has been sniffing your LAN since
   it started, so expect a list. Add what you want; skip is fine, you can add
   integrations any time from Settings → Devices & Services.
4. Set up your own **user profile**: Settings → People → your user. Enable
   two-factor (Profile → Security → Multi-factor authentication) if you want
   it — the tailnet is the real boundary, but HA supports TOTP and it costs
   nothing.

Until step 2 is done, `/api/config` reports latitude/longitude `0` and any
sun-based automation will fire at the wrong time. Nothing warns you.

## The mobile app

The companion app is the single most useful client — it is also how HA gets
presence detection, notifications, and your phone's sensors (battery, steps,
whether you are driving).

1. Install **Tailscale** on the phone and log in. This is not optional; the
   tailnet is the only route in.
2. Install **Home Assistant** (Android: Play Store / F-Droid, iOS: App Store).
3. On first launch it scans for local instances and will probably find
   nothing — Serve is not discoverable. Tap **Enter address manually** and
   give it the full URL *including the port*:

   ```
   https://kai-home-server.taild6a23f.ts.net:8123
   ```

4. Log in with the `.env` credentials. Grant location permission (choose
   "Always" if you want presence-based automations) and notification
   permission.

Common failures:

- **Leaving off `:8123`** — the app tries 443, which is code-server, and
  reports something unhelpful about an invalid server.
- **Using `http://`** — Serve is HTTPS-only.
- **Tailscale not connected on the phone** — the name will not resolve.
  `100.85.87.87:8123` is a useful thing to try when MagicDNS is misbehaving,
  but fix MagicDNS rather than living on the IP.
- **"Unable to connect" only when out of the house** — check Tailscale is
  actually up on the phone's mobile data, not just on wifi.

Once connected, set **Settings → Companion app → Sensors** to enable what you
want, and leave the rest off; every enabled sensor is a row in the recorder
database several times a minute.

## Security model

- **Tailnet-only.** The listener is `127.0.0.1:8123` and nothing else;
  Tailscale Serve terminates TLS. Not reachable from the LAN or the internet.
  No firewall rule opens it, and none should. Home Assistant instances are
  routinely port-forwarded to the internet and routinely turn up in scanner
  results; do not.
- **No Nabu Casa cloud.** The `cloud:` component is loaded (it is part of
  `default_config` and provides Alexa/Google hooks *if* you subscribe), but
  nothing is configured and no account exists, so nothing leaves the box.
- **Analytics are opted out** during onboarding.
- **The admin account is created by `setup.sh`** before anyone can reach the
  instance. There is no window in which someone else on the tailnet loads the
  page and claims the owner account — which is the real risk of a hand-started
  HA container, because until onboarding completes `/api/onboarding/users` will
  create the owner for *anyone* who can reach the port.
- **Secrets** are generated into the gitignored `.env` (mode 600). Mirror any
  password change you make in the UI back into `.env`.
- **Host networking is the exception to the isolation story**, discussed
  above. The practical rule that follows: treat custom components
  (HACS or otherwise) as code running with the host's network view, because
  that is what they are.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker's restart policy handles boot; no systemd unit | ✅ |
| Docker + Compose v2 | the one container | ✅ (incl. daemon reachability) |
| curl | readiness polling, onboarding POSTs, verification | ✅ |
| Tailscale, logged in, MagicDNS | publishing | ✅ (`BackendState` must be `Running`) |
| Port 8123 free | HA's default; nothing else on this box claims it | ✅ |
| Host timezone | `homeassistant.time_zone` in the yaml | — |

⚠️ **`network_mode: host` is Linux-only in any meaningful sense.** Docker
Desktop on macOS runs containers inside a VM, so "host" is the VM's network,
not the Mac's — discovery of devices on the Mac's LAN will not work and the
loopback bind lands inside the VM. The deploy will run, but the macOS path is
**unverified** and the discovery premise does not hold there.

## Deploy

```bash
cd home-assistant && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Broad shape, in the order it matters:

1. **Preflight** — OS, non-root, `curl`, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports.
2. **`.env`** — written only if absent, mode 600. Carries `HA_VERSION` (the
   pinned tag), `LOCAL_PORT`, `HTTPS_PORT`, `TZ`, `HA_CONFIG`, `HA_ADMIN_USER`
   and a generated `HA_ADMIN_PASSWORD` (32 hex chars — deliberately `[a-f0-9]`
   so it survives `.env`, shell quoting, a JSON body and a phone keyboard
   unescaped). Values are double-quoted so a path containing a space survives
   being sourced. Never rewritten on a re-run: `.env` is the source of truth
   once it exists, and a `LOCAL_PORT=` on the command line that disagrees with
   it is ignored with a warning rather than silently moving a live deployment
   away from the port its `configuration.yaml` is bound to.
3. **`configuration.yaml`** — written **before the container is ever
   started**, and only if absent (it is yours to edit afterwards). This
   ordering is the whole ballgame; see "The first-boot window".
4. **`docker compose up -d`** — first run pulls ~1.5 GB.
5. **Wait for readiness** by polling `GET /api/onboarding` — 90 attempts,
   2 s apart. That endpoint has **two** healthy answers and both mean the
   server is up: **200** with a JSON list of steps while any step is open
   (this deploy's normal state, since `core_config` is deliberately left
   open), and **404** once every step is done, because HA stops registering
   the onboarding views at startup. Anything else — `000`, 5xx — is "not yet".
   Cold start on this box is **7–8 seconds**, but the loop must survive a
   genuine connection refusal (curl exit 7, `%{http_code}` = `000`) rather
   than assuming a tidy 503 — that is precisely how the Jellyfin deploy failed.
6. **Onboard** — `POST /api/onboarding/users` (403 "User step already done" is
   the success path on a re-run), exchange the single-use `auth_code` at
   `/auth/token`, then `POST /api/onboarding/analytics` to opt out.
   `core_config` is *not* touched.
7. **`tailscale serve --bg --https=8123 http://127.0.0.1:8123`**, with the
   operator-grant (`sudo tailscale set --operator=$USER`, first run only) and
   approval-link fallbacks.
8. **Verify** over the tailnet URL, then print the URL, the credentials, and
   the reminder that you must finish the location step in the UI.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f homeassistant`
  (also in the UI: Settings → System → Logs)
- Restart HA only: `docker compose --project-directory . restart`
  (or Developer Tools → **Restart** in the UI, which is faster)
- Check the config before restarting after a yaml edit:
  `docker exec home-assistant python -m homeassistant --script check_config -c /config`
- Upgrade: bump the pinned tag in `.env`, then
  `docker compose --project-directory . pull && ./setup.sh`.
  ⚠️ Read the release notes. HA ships breaking changes in *point* releases and
  the `.storage/` schema migrates forward only — which is why the tag is
  pinned rather than `:stable`.
- What version is really running:
  `docker exec home-assistant python -c 'import homeassistant.const as c; print(c.__version__)'`
- Is the timezone/location actually set (needs a token):
  Developer Tools → Template → `{{ state_attr('sun.sun','next_dawn') }}` —
  a plausible local time means the location step was done.
- Recorder size: `du -h ~/services/home-assistant/config/home-assistant_v2.db`
- Prune history: add a `recorder:` block with `purge_keep_days` to
  `configuration.yaml`, then Developer Tools → Actions →
  `recorder.purge` with `repack: true`.

## Backups

⚠️ **Nothing on this box is backed up.** Home Assistant's irreplaceable half
is small and easy to copy — there is no excuse for not having a copy of it:

```bash
cd ~/dev/setup-server/home-assistant
docker compose --project-directory . stop
tar czf ~/home-assistant-$(date +%F).tgz \
    -C ~/services/home-assistant/config \
    .storage configuration.yaml blueprints custom_components www
docker compose --project-directory . start
```

That excludes `home-assistant_v2.db` deliberately — it is the large,
regenerating part (sensor history), and including it turns a 2 MB tarball into
a multi-GB one. If you want history too, add it.

Then get the tarball **off this machine** — Seafile at `:8443` syncs to a
device that is not this one.

The UI's own Settings → System → Backups makes an equivalent archive and is
the better route if you want it scheduled; it writes into
`~/services/home-assistant/config/backups`, which is still on this disk, so
it is only half a backup until something copies it off.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

See the "Tests" section of TROUBLESHOOT.md for what a red line means. The
mocked suite runs the real `setup.sh` in a sandbox with a temp `$HOME` and
PATH stubs for `docker`, `tailscale`, `curl`, `sudo`, `id` and `sleep`; the
`curl` stub fakes the onboarding surface — `/api/onboarding` readiness (with a
real connection-refusal window), `/api/onboarding/users` including the 403
re-run path, the single-use `/auth/token` exchange, and
`/api/onboarding/analytics` — and records every call so ordering can be
asserted.

The assertions that exist because they were measured to be dangerous:

- **`configuration.yaml` is on disk before the first `compose up`.** The
  silent failure described above.
- **`bluetooth` and `go2rtc` are not in the component list**, and the list
  otherwise matches `default_config`'s 21 dependencies from the image — 19 of
  them, asserted by exact set equality, not by a spot-check.
- **`http.server_host: 127.0.0.1`, `use_x_forwarded_for: true` and
  `trusted_proxies`**, paired with `network_mode: host`.
- **403 "User step already done" is treated as success**, so a second run
  finishes cleanly.
- **`core_config` is never POSTed.**
- **The `auth_code` is exchanged exactly once.**
- **The readiness loop survives a real refused connection** (exit 7, `000`),
  and accepts the 404 shape as ready rather than spinning for 180 s.
- **`.storage/http` is seeded before the first `compose up` too**, with
  `pending: null` and `yaml_migration_done: true` — asserted against the same
  at-`compose up` snapshot as the YAML.
- **A reverted, missing or corrupt store is repaired**, the repair *merges*
  rather than clobbers, and the container is stopped first.
- **The image tag is pinned**, not `:stable`.

**253 mocked checks**, all green, in about a minute — plus 25 in `--live`.

The `docker` stub has a `run --entrypoint python3` branch that rewrites the
bind-mount path and executes `setup.sh`'s real store-classification and repair
heredocs through the host's `python3`, so the repair logic is genuinely
exercised rather than mocked away.

The live suite additionally asserts **zero `habluetooth` lines in the
container log** and **no non-loopback listener on 18555 or 18554**. Those are
the two regressions that would otherwise creep back in the next time someone
edits the yaml — and neither shows up as an error, only as a log that fills
or a port that quietly opens.

Every mutation tried against this suite was caught; the list is in the tests
file's header comments.

## Notes

- Port 8123 is Home Assistant's default and the HTTPS port matches the local
  port, following the newer convention in this repo. That overlap is why the
  live suite's `no_external_listener` check allows Tailscale's own tailnet
  listener on the same number.
- `/` returns **302** (it redirects to `/lovelace`), not 200. Health checks
  that use `curl -fsS` and expect output will look like failures. Assert the
  302, or use `/api/onboarding` — but read the next note first.
- ⚠️ **`/api/onboarding` will start returning 404** the day you finish the
  location step in the UI and the box next restarts: HA decides at startup
  whether to register the onboarding views at all. Both 200 and 404 mean
  "up", and `setup.sh` and the live suite accept either. Anything else that
  monitors this service must too — a **Uptime Kuma** monitor pinned to
  `200 on /api/onboarding` would go red on a perfectly healthy instance and
  stay red. `/manifest.json` (always 200) is the stable choice for a
  monitor.
- There is no supervisor here, so **Add-ons do not exist** on this install.
  That is the difference between "Home Assistant Container" (this) and "Home
  Assistant OS". Anything a guide tells you to install as an add-on — Mosquitto,
  Zigbee2MQTT, ESPHome — is a separate container on this box instead.
- HACS (the community store for custom components) is not installed. If you
  add it, re-read the host-networking paragraph first.
- No USB device is passed through. Zigbee/Z-Wave dongles would need an
  explicit `devices:` entry in `docker-compose.yml`; `usb:` being loaded means
  HA can *see* the host's USB bus for discovery, not that a serial dongle is
  wired into the container.
