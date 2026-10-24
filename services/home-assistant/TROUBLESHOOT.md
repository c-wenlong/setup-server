# home-assistant — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local health?          ->  publish?       ->  client?
docker ps          curl :8123/api/onboarding  serve status      app / browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/home-assistant
docker compose --project-directory . ps                        # home-assistant up?
curl -s http://127.0.0.1:8123/api/onboarding                   # a JSON step list
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8123/ # 302, NOT 200
tailscale serve status                                         # :8123 -> 127.0.0.1:8123
./tests/run-tests.sh --live                                    # everything at once
```

Two response codes trip people up here, and both are healthy:

- ⚠️ **`/` returns 302** — it redirects to `/lovelace`. A
  `curl -fsS http://127.0.0.1:8123/` prints nothing and looks like a failure.
  Do not "fix" anything on the strength of that.
- ⚠️ **`/api/onboarding` returns 200 *or* 404.** 200 with a JSON list of steps
  while any step is open — this deploy's normal state, because `core_config`
  is deliberately left for your first login. **404** once every step is done
  and HA has restarted, because it decides at startup whether to register the
  onboarding views at all. Both mean the server is up. `setup.sh` and the live
  suite accept either; a **Uptime Kuma monitor pinned to 200 on that path will
  go red the day you finish the location step and the box reboots**, and stay
  red. Point monitors at `/manifest.json`, which is always 200.

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so rather than reporting a healthy container as down —
but a hand-run `docker inspect` will just lie to you.

## The bluetooth error loop

**Symptom.** The log fills at roughly 24 lines a minute, forever:

```
ERROR [habluetooth.scanner] hci0 (74:E5:F9:89:1F:4C): Failed to force stop scanner
```

Confirm it:

```bash
docker logs --since 60s home-assistant 2>&1 | grep -c habluetooth   # want 0
```

**Cause.** This box has a USB Bluetooth adapter, `hci0`, and the host's own
`bluetoothd` owns it (`hciconfig` shows `UP RUNNING PSCAN`). Under host
networking HA's `bluetooth` integration finds the adapter, tries to take the
scanner, and loses. It never stops trying. Two processes cannot share one
HCI adapter — this is not a permissions problem, however much the first error
line looks like one.

### The capabilities "fix" does not work — measured

The advice you will find upstream and in every forum thread is to grant the
container the capabilities it appears to be missing:

```yaml
cap_add: [NET_ADMIN, NET_RAW]
volumes: [/run/dbus:/run/dbus:ro]
```

This was tried on this box against 2026.9.1. **It removes the
`PermissionError` line and the scanner fight continues at exactly the same
rate.** All the capabilities do is let HA get far enough to lose the fight
more quietly. Do not ship it, and do not spend an evening on it — the missing
permission was never the problem.

### Removing `bluetooth:` from the yaml after first boot also does nothing

This is the part that wastes the most time. `configuration.yaml` is not the
database of record. On its **first** boot HA's discovery creates a *config
entry* for the bluetooth adapter and persists it in
`.storage/core.config_entries`. After that, the config entry is what loads the
integration — the yaml is not consulted for it any more.

So editing the yaml and restarting changes nothing, and you conclude the yaml
is being ignored, which is half true in a very unhelpful way.

Confirm the entry is really there:

```bash
python3 -c "import json;print([e['domain'] for e in json.load(open('$HOME/services/home-assistant/config/.storage/core.config_entries'))['data']['entries']])"
```

If `bluetooth` is in that list, remove it the way HA expects — **from the UI**,
which is the only supported way to delete a config entry:

> Settings → Devices & Services → **Bluetooth** → ⋮ → **Delete**

Then confirm `bluetooth:` is absent from `configuration.yaml` (so discovery
does not immediately recreate it), and restart:

```bash
grep -n '^bluetooth:' ~/services/home-assistant/config/configuration.yaml   # want no output
docker compose --project-directory ~/dev/setup-server/services/home-assistant restart
docker logs --since 60s home-assistant 2>&1 | grep -c habluetooth            # want 0
```

If you would rather start clean than pick at `.storage/`, the nuke-and-pave at
the bottom of this page is a legitimate answer while the instance is young —
it is a 20-second reinstall before you have any automations in it.

### If you actually want Bluetooth

The honest answer is that you have to give HA the adapter, not share it:

```bash
sudo systemctl stop bluetooth          # frees hci0
sudo systemctl disable bluetooth       # ...and keeps it free across reboots
```

Then add `bluetooth:` to `configuration.yaml` and give the container what the
integration needs:

```yaml
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - /run/dbus:/run/dbus:ro
```

Now the capabilities matter, because now there is nothing to fight with. Note
the cost: nothing else on this host can use Bluetooth any more — no `bluetoothctl`,
no pairing a keyboard, no host-side BLE tooling. That is the trade, and there
is no configuration that avoids it.

## Port 18555 is open on the LAN (go2rtc)

**Symptom.** `ss -ltn | grep 1855` shows something like:

```
LISTEN 0 4096   127.0.0.1:18554   0.0.0.0:*
LISTEN 0 4096        [::]:18555      [::]:*
```

That second line is every interface — the LAN and the tailnet — carrying plain
TCP with no Tailscale Serve and no TLS in front of it.

**Cause.** `go2rtc:` is in `configuration.yaml`. It is HA's WebRTC camera
streamer, and loading the integration starts a go2rtc process whose WebRTC
listener binds `::`. Under `network_mode: host` that is the host's every
interface. Measured inside this image; the RTSP port (18554) stays on loopback
and is fine, the WebRTC one does not.

**Home Assistant offers no setting to move it** — the listen address is baked
into the config HA generates for the go2rtc process. So there are exactly two
fixes, and the deploy picks the first:

```bash
# 1. Don't load it. `stream:` stays, so cameras work over HLS.
grep -n '^go2rtc:' ~/services/home-assistant/config/configuration.yaml
# delete that line, then:
docker compose --project-directory ~/dev/setup-server/services/home-assistant restart
ss -ltn | grep 1855          # want no output at all
```

```bash
# 2. Or move the container to bridge networking — and give up discovery
#    entirely (mDNS/SSDP/DHCP do not cross a bridge). Rarely the right trade
#    on a box where discovery is the point.
```

What you lose by option 1 is WebRTC's sub-second latency and any integration
that specifically requires a go2rtc provider. Cameras themselves still work.

The live suite asserts `no_external_listener 18555` and `18554`, and
`setup.sh` warns after every deploy if 18555 has a non-loopback listener — so
if someone adds the line back, you find out on the next run rather than from a
port scan.

## The yaml says `server_host: 127.0.0.1` but HA binds `0.0.0.0`

⚠️ **This is the sharpest edge on 2026.9 and later, and it is how this deploy
failed the first time it was run.** Read this before believing
`configuration.yaml`.

**Symptom.** One or both of:

```
ERROR ... Error during setup of component http: Failed to create HTTP server at
  port 8123: [Errno 98] error while attempting to bind on address ('0.0.0.0', 8123)
```

...followed by `auth`, `api`, `onboarding`, `frontend`, `websocket_api`,
`cloud`, `webhook` and `backup` all failing "Could not setup dependencies" —
or, worse, no error at all and a happily-serving Home Assistant on
`0.0.0.0:8123`, reachable from the LAN.

`docker ps` says the container is `Up`. `configuration.yaml` is correct.

**Cause. `configuration.yaml` is no longer where the `http` settings live.**
HA 2026.9 migrated the `http:` block into `.storage/http`, exactly once, and
then set `yaml_migration_done: true` — after which **the YAML block is ignored
forever**. Worse, the migrated settings do not land in the active slot. The
store holds a pair:

- **`stable`** — the config actually in use.
- **`pending`** — a *trial*. HA prefers it on the next boot, schedules a revert
  a few minutes later, and only keeps it if something **promotes** it.
  Promotion is a frontend confirmation: a human loads the UI and the frontend
  tells HA the config works.

An unattended deploy never opens the UI, so the trial is never promoted. It
reverts, `pending.error` becomes `"not_promoted"`, and because the resolution
rule is *"prefer `pending` unless it has already failed a trial"*, **every
subsequent boot uses `stable`** — which is the built-in default: wildcard bind,
no `use_x_forwarded_for`, no `trusted_proxies`.

Both guarantees this deploy exists to provide evaporate silently, one boot
after the deploy that appeared to succeed.

**Look at the file, not the yaml.** The container writes `.storage` as root, so
read it through the container:

```bash
docker exec home-assistant python3 -c "
import json; d=json.load(open('/config/.storage/http'))['data']
print('ACTIVE server_host :', d['stable'].get('server_host'))
print('ACTIVE xff         :', d['stable'].get('use_x_forwarded_for'))
print('ACTIVE proxies     :', d['stable'].get('trusted_proxies'))
p=d.get('pending')
print('pending            :', 'none' if p is None else p.get('error') or 'untried')
print('yaml_migration_done:', d.get('yaml_migration_done'))"
```

A broken instance prints `ACTIVE server_host : None` and
`pending : not_promoted`. A correct one prints `['127.0.0.1']` and
`pending : none`.

The live suite asserts all three — "ACTIVE http config binds loopback (not just
the yaml)", "ACTIVE http config trusts the loopback proxy", and "no failed
pending trial waiting to revert". Those lines exist because the YAML checks
directly above them were green on a completely broken deploy.

**Fix — re-run the deploy.** `setup.sh` seeds `.storage/http` before the first
boot so there is no trial to revert, and on every later run it classifies the
store and **repairs it in place** — stopping the container first, and merging
rather than replacing, so a hand-set port or `ssl_profile` survives:

```bash
cd ~/dev/setup-server/services/home-assistant && ./setup.sh
```

That is the recovery path; a wipe is not needed and is the wrong default once
there is anything in the instance. If you would rather do it by hand, with the
container stopped:

```bash
cd ~/dev/setup-server/services/home-assistant
docker compose --project-directory . stop
sudo python3 - <<'EOF'
import json, datetime
p = "/home/kaichen/services/home-assistant/config/.storage/http"
d = json.load(open(p))
d["data"]["stable"].update({
    "server_host": ["127.0.0.1"],
    "use_x_forwarded_for": True,
    "trusted_proxies": ["127.0.0.1/32", "::1/128"],
})
d["data"]["pending"] = None          # MUST be present, even as null
d["data"]["yaml_migration_done"] = True
json.dump(d, open(p, "w"), indent=2)
EOF
docker compose --project-directory . start
ss -ltn | grep 8123     # want 127.0.0.1:8123, plus tailscaled's tailnet addrs
```

Three details that will cost you an hour each if you get them wrong:

- **`"pending"` must exist as a key**, even when its value is `null`. Omit it
  and `http` fails at startup with `Error during setup of component http:
  'pending'` — the same total outage, with a different message.
- **`server_host` is a list**, not a string.
- **`trusted_proxies` are stored as CIDR** (`127.0.0.1/32`, `::1/128`), not as
  the bare addresses the YAML uses.

A nuke and pave (bottom of this page) also works, but `./setup.sh` is faster
and keeps your account, devices and automations.

**A staged trial is discarded, and that is deliberate.** Any `pending` is
cleared, including one that has not failed yet — an unpromoted trial reverts by
itself anyway, and "not failed yet" is the shape that looks healthiest while
being the most dangerous. The consequence: if you were part-way through
changing the HTTP settings in **Settings → System → Network** and then ran
`./setup.sh`, your unconfirmed change is gone. The run says so. Redo it in the
UI and confirm it there.

**Why it failed loudly here rather than quietly.** `tailscale serve` publishes
on the same port number HA listens on, so tailscaled already held
`100.85.87.87:8123`. HA's reverted `stable` config tried to bind `0.0.0.0:8123`,
collided, and died. Had Serve been on a *different* port, the wildcard bind
would have succeeded and put an unauthenticated-until-onboarded Home Assistant
on the LAN with nothing in the output to say so. The noisy failure was luck.

**Keeping `http:` in `configuration.yaml`** is harmless once
`yaml_migration_done` is true — HA ignores it and raises a
`yaml_still_present_after_migration` repair notice in the UI. It is kept as
documentation of intent; the notice is expected, not a fault.

## "not a trusted reverse proxy"

**Symptom.** The tailnet URL returns a 400 and the log says something close to:

```
Received X-Forwarded-For header from an untrusted proxy 127.0.0.1
```
or
```
A request from a reverse proxy was received from 127.0.0.1, but your
HTTP integration is not set-up for reverse proxies
```

`http://127.0.0.1:8123/` works fine from the box itself. Everything through
Serve is rejected.

**Cause.** `configuration.yaml` is missing `use_x_forwarded_for` and/or
`trusted_proxies`. Tailscale Serve is a reverse proxy connecting from the
host's loopback, and HA refuses to honour `X-Forwarded-For` from a proxy it
has not been told to trust.

**Fix.** The `http:` block must have all three keys:

```bash
sed -n '/^http:/,/^[^ ]/p' ~/services/home-assistant/config/configuration.yaml
```

```yaml
http:
  server_host: 127.0.0.1
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

Then restart — this is read at start, not reloaded:

```bash
docker compose --project-directory ~/dev/setup-server/services/home-assistant restart
```

Two adjacent traps:

- **`use_x_forwarded_for` without `trusted_proxies` is a startup error**, not
  a warning. If the container is crash-looping right after a yaml edit, this
  is the first thing to check: `docker logs home-assistant | tail -30`.
- **A fresh deploy should never hit this**, because `setup.sh` writes the file
  before the container's first start. If you *are* hitting it on a fresh
  deploy, the ordering is wrong in the script — see the next section, and run
  the mocked suite, which asserts exactly that ordering.

## The config file was written after the container started

**Symptom.** A deploy that reports success, but: the bluetooth errors are
there anyway, or proxied requests are rejected, or both — and
`configuration.yaml` on disk looks completely correct.

**Cause.** HA read (or did not read) the file at *its* start. Anything written
afterwards is invisible until a restart, and the config entries discovery
created on that first boot persist regardless.

**Check the ordering actually happened:**

```bash
stat -c '%y %n' ~/services/home-assistant/config/configuration.yaml 2>/dev/null || \
  stat -f '%Sm %N' ~/services/home-assistant/config/configuration.yaml   # macOS
docker inspect -f '{{.State.StartedAt}}' home-assistant
```

If the file is newer than the container's *first* start (note `StartedAt`
moves on every restart, so this is only conclusive on a container that has
never been restarted), the first boot ran without it.

**Fix.** A restart picks up the yaml. It does **not** undo config entries that
discovery already created — those need the UI deletion above, or a wipe of
`.storage/` (nuke and pave).

This is the failure mode the mocked suite's most important assertion exists
for: `configuration.yaml` must be on disk before the first `docker compose
up`. If you have edited `setup.sh`, run `./tests/run-tests.sh` before running
it against the box.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 homeassistant
```

- **`Invalid config for [http]` / `Component error: ...`** — a yaml mistake.
  Check it without restarting into a loop:

  ```bash
  docker exec home-assistant python -m homeassistant --script check_config -c /config
  ```

  If the container is not up long enough to `exec` into, run the checker as a
  throwaway container against the same directory:

  ```bash
  docker run --rm -v ~/services/home-assistant/config:/config \
    ghcr.io/home-assistant/home-assistant:2026.9.1 \
    python -m homeassistant --script check_config -c /config
  ```

- **`Address already in use`** — something else took 8123. `ss -ltnp | grep 8123`.
  On this box nothing should; if a second HA container is running,
  `docker ps -a | grep -i home` will show it.
- **Permission errors on `/config`** — the official image runs as root, so
  this usually means the host path in `.env` is wrong or on a read-only mount,
  not a mode problem. `ls -ld ~/services/home-assistant/config`.
- **Exit 137 (OOM-killed)** — HA idles around 400–500 MB, so suspect a
  neighbour: ollama with a model loaded claims ~5 GB. `docker stats`, `free -h`.
- **It starts, then exits cleanly after a few seconds with no error** —
  usually a `configuration.yaml` that is valid YAML but empty of the
  `homeassistant:`/`http:` blocks, i.e. the file was truncated by a failed
  edit. Compare against SETUP.md → "`default_config` is expanded by hand".

## `/api/onboarding` fails but the container says "running"

```bash
curl -sv http://127.0.0.1:8123/api/onboarding
```

- **Connection refused for the first ~8 seconds after a start** — normal, and
  measured: cold start to first HTTP answer on this box is 7–8 s. `setup.sh`
  retries for exactly this reason, treating curl's exit 7 / `%{http_code}` of
  `000` as "not yet" rather than as a failure. A one-shot `curl` right after
  `up -d` will just miss it.
- **Refused indefinitely, container healthy** — the most likely cause is that
  `http.server_host` is set to something that is not `127.0.0.1`, so HA is
  listening somewhere you are not looking. `ss -ltn | grep 8123`.
- **Confirm the bind is loopback-only.** Under host networking there is no
  Docker port mapping to inspect, so this check is the only thing standing
  between the repo's security model and an HA on every interface:

  ```bash
  ss -ltn | grep 8123
  ```

  Expected: `127.0.0.1:8123` for HA, plus `100.85.87.87:8123` and the `fd7a:…`
  v6 address, which are **tailscaled's** own serve frontend (HTTPS port equals
  local port here, so they collide on one number). **`0.0.0.0:8123` is the
  real problem** — it means `server_host` is missing from `configuration.yaml`
  while `network_mode: host` is in effect, which puts an
  unauthenticated-until-onboarded Home Assistant on the LAN. Treat it as an
  incident: `tailscale serve --https=8123 off`, stop the container, fix the
  yaml, and find out who edited it.

## Onboarding problems

- **`setup.sh` prints `403 User step already done` and continues** — that is
  correct and is the idempotency signal. The owner account already exists;
  this is a re-run. A script that treated it as an error could not be run
  twice.
- **`setup.sh` says the token exchange returned no token** — the `auth_code`
  is **single-use**, and something consumed it. Almost always two runs racing,
  or a re-run after a partial failure that got a fresh code and then died. The
  account exists either way; the deploy just could not get a token to opt out
  of analytics. Re-running is safe (the 403 path handles it), but a re-run
  cannot obtain a new code for an already-onboarded instance — do the
  analytics opt-out in the UI instead: Settings → System → General →
  **Analytics**, untick everything.
- **The login page shows "create your smart home" / asks to create an
  account** — onboarding did *not* complete, and until it does, anyone who can
  reach the port can claim the owner account. On a tailnet-only bind that is
  a small window, but close it: log in and finish, or nuke and pave.
- **Sunrise/sunset automations fire at the wrong time; the weather card is
  wrong; `sun.sun` attributes look like UTC.** Latitude and longitude are `0`
  — the location step was never completed. `setup.sh` leaves it on purpose
  (auto-completing it pins lat/long to 0 and TZ to UTC permanently, and the UI
  then never asks again). Fix it in Settings → System → General → set the
  location on the map. Verify:

  ```bash
  # Developer Tools -> Template:
  #   {{ state_attr('sun.sun','next_dawn') }}
  # should be a plausible local time, not something 8 hours off.
  ```

- **Timezone is right but location is not** — expected. Timezone comes from
  `homeassistant.time_zone` in the yaml (set from the host at deploy time);
  latitude/longitude only ever come from you.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` will show what has
  `:8123`. Remove just that one:

  ```bash
  tailscale serve --https=8123 off
  ```

  ⚠️ **Never `tailscale serve reset`.** That clears every mapping on the node
  — currently ten of them, including code-server on `:443`, which is very
  likely how you are reading this — and every service's `setup.sh` then has to
  be re-run. `off` is absent from `--help` but is what Tailscale prints itself
  after a successful `serve`, and is the only single-port removal.

## HTTPS URL doesn't load from a client

- **Is the client on the tailnet?** Not reachable off-tailnet, by design.
  Check Tailscale is connected on *that* device, not on the server.
- First load after a new port can take ~60 s while the cert is minted:
  `curl -v https://kai-home-server.taild6a23f.ts.net:8123/api/onboarding`
- **The page loads but is blank / spins forever** — usually the browser
  holding a cached frontend from a different HA version after an upgrade.
  Hard-refresh (Ctrl-Shift-R).
- **The mobile app can't connect but the browser can** — the app needs the
  port in the URL (`:8123`) and `https://`. See SETUP.md → The mobile app.
- MagicDNS off → `100.85.87.87:8123` works. Fix MagicDNS rather than living
  on the IP; HA builds some absolute URLs from the address you arrived on.

## Login and account problems

- **Password from `.env` rejected** — you changed it in the UI and did not
  mirror it back. `.env` is not authoritative for HA once the account exists;
  the account is. Update `.env` to match.
- **Locked out entirely.** HA has an offline owner-password reset, run inside
  the container:

  ```bash
  docker exec -it home-assistant \
    python -m homeassistant --script auth -c /config change_password <username> <newpassword>
  ```

  Then restart, and mirror the new password into `.env`. List the users first
  if you are not sure of the name:

  ```bash
  python3 -c "import json;print([u['username'] for u in json.load(open('$HOME/services/home-assistant/config/.storage/auth'))['data']['credentials']])"
  ```

- **Locked out by 2FA** — the same `auth` script cannot remove MFA. The MFA
  rows live in `.storage/auth` under `mfa_modules`; stop the container, copy
  the file, and remove your user's entry by hand. Look before you edit; that
  file also holds every refresh token, and corrupting it logs out every device.

## Devices aren't discovered

- **Confirm host networking is actually in effect**:

  ```bash
  docker inspect -f '{{.HostConfig.NetworkMode}}' home-assistant     # host
  ```

  If it says `bridge` or a compose network name, discovery is dead by
  construction — mDNS and SSDP are broadcast and do not cross a bridge.
- **Confirm the discovery components loaded.** With a long-lived token from
  Profile → Security → Long-lived access tokens:

  ```bash
  curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8123/api/config \
    | python3 -c "import json,sys;c=json.load(sys.stdin)['components'];print([x for x in ('zeroconf','ssdp','dhcp','usb') if x in c])"
  ```

  All four should be listed. If they are not, `configuration.yaml` lost lines
  — compare against SETUP.md.
- **A device on a different VLAN/subnet will never be discovered.** Broadcast
  does not route. Add those integrations by IP instead.
- **Zigbee/Z-Wave dongle not showing up** — no USB device is passed into the
  container. `usb:` lets HA enumerate for discovery; a serial dongle still
  needs an explicit `devices:` entry in `docker-compose.yml`
  (`/dev/serial/by-id/...`, never `/dev/ttyUSB0`, which renumbers on reboot).

## Disk

The recorder database grows without limit by default.

```bash
du -sh ~/services/home-assistant/config/*
du -h  ~/services/home-assistant/config/home-assistant_v2.db
```

To cap it, add to `configuration.yaml` and restart:

```yaml
recorder:
  purge_keep_days: 30
```

then reclaim the space once: Developer Tools → Actions → `recorder.purge`
with `repack: true`. A purge without a repack marks rows free inside the
SQLite file without shrinking it, which looks like the purge did nothing.

`~/services/home-assistant/config/backups` is where the UI's own backups land
— on this same disk. The directory does not exist until you take the first
one. Safe to delete once you have copied them off.

## Upgrade problems

`.storage/` migrates **forward only**. A config directory opened by a newer
Home Assistant cannot be handed back to the old version, so pinning the tag
back in `.env` does not roll back the problem.

- **Take the tarball before bumping the tag** (SETUP.md → Backups). It is the
  only rollback that exists.
- **Bumped the tag and it will not start** — read the log for the migration or
  config error. HA ships breaking changes in point releases; the release notes
  list them under "Backward-incompatible changes" and they are usually a yaml
  key that moved.
- **After an upgrade, `default_config` gained a component.** The yaml lists
  `default_config`'s dependencies by hand (minus `bluetooth` and `go2rtc` —
  19 of 21), so a new one will not appear by itself. Re-read the manifest from
  the new image and add it, minus those two:

  ```bash
  docker run --rm ghcr.io/home-assistant/home-assistant:<tag> \
    python -c "import json;print(json.load(open('/usr/src/homeassistant/homeassistant/components/default_config/manifest.json'))['dependencies'])"
  ```

- **An integration disappeared after an upgrade** — check the log for
  `Setup failed for` lines; a custom component that has not been updated for
  the new HA version is the usual cause, and it will not load until it is.

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere, no system changes
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` in a temp sandbox with a temp
`$HOME`, so it never touches `~/services/home-assistant` or the real `.env`.
Run it before committing any change to `setup.sh`.

What a red line means, for the ones that are easy to misread:

- **"configuration.yaml exists before compose up"** — the ordering broke.
  This is the assertion that matters most; see the section above.
- **"bluetooth not in the component list"** — someone re-added it, or replaced
  the hand-expanded list with `default_config:`. The box's log will start
  filling within a minute of the next deploy.
- **"go2rtc is NOT enabled"** / **"no go2rtc WebRTC listener on 18555"** — same
  class of regression, but the symptom is a LAN-facing port rather than a
  noisy log. See the go2rtc section above.
- **"the component list is default_config minus bluetooth and go2rtc"** — the
  assertion is exact set equality against 19 names, so this also fires when an
  upgrade *adds* a dependency you have not yet mirrored into the yaml. That is
  intentional: see Upgrade problems.
- **"no habluetooth lines in the log"** (live only) — the regression actually
  happened. Even if the yaml looks right, check `.storage/core.config_entries`;
  a config entry from an earlier boot survives a yaml fix.
- **"not listening on non-local ifaces"** (live only) — treat as an incident,
  not a test bug. See "Confirm the bind is loopback-only" above.
- **"cannot reach the docker daemon"** — not a failure of the deploy. Re-run
  as `sg docker -c './tests/run-tests.sh --live'`.

## Nuke and pave

Destroys the Home Assistant instance: the owner account, every integration and
device you have added, all automations, and the entire recorder history. There
is no undo. While the instance is young this is genuinely the cheapest fix for
a wedged `.storage/`; once you have automations in it, it is not.

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, runs `compose down`, and refuses to delete a
config dir that is not really inside `~/services/`. The container runs as root
and owns most of `config/`, so `--purge` empties it with a throwaway container
of the pinned image (already on this box, no pull) instead of `sudo`; if that
fails it stops, keeps `.env`, and prints the `sudo rm -rf` to run.

```bash
cd ~/dev/setup-server/services/home-assistant
./teardown.sh            # remove, keep config/ + .env (the launcher's Remove)
./teardown.sh --purge    # also delete the whole HA_CONFIG dir and .env; type the name
./setup.sh               # back; a true first boot if you purged
```

`--purge` removes `.storage/` with everything else, which is the point: HA
persists config entries there, so only a full wipe gives the next `setup.sh` a
real first boot. It also removes `config/backups`, so copy any backup off the
box first. There is no undo. Pause the `home-assistant` monitor in Uptime Kuma
first from a terminal, or it pages; the launcher's Remove does that.

Then log in with the freshly printed credentials and finish the location step
in the UI (SETUP.md → First login).

To keep the instance and drop only the history — for a database that has grown
absurd or gone corrupt — stop the container and delete just the recorder:

```bash
cd ~/dev/setup-server/services/home-assistant
docker compose --project-directory . stop
sudo rm -f ~/services/home-assistant/config/home-assistant_v2.db*
docker compose --project-directory . start
```

That loses every graph and long-term statistic, and keeps your account,
integrations and automations. HA recreates the database on start.

To restore from a tarball, do it between the `rm -rf` and the `setup.sh`:

```bash
sudo mkdir -p ~/services/home-assistant/config
sudo tar xzf ~/home-assistant-<date>.tgz -C ~/services/home-assistant/config
./setup.sh
```

A restored `.storage/` already contains the owner account, so the run's
`POST /api/onboarding/users` takes the **403 "User step already done"** path
and the deploy finishes without creating a second account. Restore the
`configuration.yaml` from the tarball too, or the run writes a fresh one — it
only writes the file when it is absent.
