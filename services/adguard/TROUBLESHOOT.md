# adguard — Troubleshooting

⚠️ **This service is DNS for the whole tailnet.** Stopping it, or removing its
container, takes name resolution down for every device pointed at it —
including the laptop you are reading this on, and including the Tailscale
console you would use to undo it. Before you run anything on this page that
stops, removes or recreates the container, read
[Backing it out safely](#backing-it-out-safely-order-matters).

Triage in layers, outermost failure first:

```
container up?  ->  DNS answers?              ->  web UI?        ->  publish?     ->  tailnet points here?
docker ps          dig @100.85.87.87 x.com       curl :3080        serve status     Tailscale console → DNS
```

Quick triage:

```bash
cd ~/dev/setup-server/services/adguard
docker compose --project-directory . ps                   # adguard up?
dig +short @100.85.87.87 example.com                      # a real A record
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/control/status
                                                          # 401 = healthy (see below)
tailscale serve status                                    # :3080 -> 127.0.0.1:3080
systemctl is-active systemd-resolved                      # must still be active
./tests/run-tests.sh --live                               # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so, rather than reporting a healthy container as down.

**Reading the status codes.** `GET /control/status` is the one endpoint that
answers in every state, and its code *is* the state — which is why `setup.sh`
uses it as both the readiness probe and the "is it already configured?" check,
with no marker file to go stale:

| Code | Means |
|---|---|
| `000` | not accepting connections yet (a cold start, ~0.5s) |
| `302` | up, **not configured** — serving the install wizard, and running **no DNS server** |
| `401` | up, configured, asking for the login — **this is the healthy answer** |
| `200` | up, configured, and the credentials you sent are correct |

A `302` on `/` alone is not a problem — a configured AdGuard redirects `/` to
its login page. It is a `302` on `/control/status` that means trouble.

---

## "The port is listening but DNS is refused"

The signature failure of this service, and the one that will waste the most
time if you do not know it.

```bash
ss -ltnup | grep ':53'
# 100.85.87.87:53 ... LISTEN          ← looks perfect
dig @100.85.87.87 example.com
# ;; communications error to 100.85.87.87#53: connection refused   ← isn't
```

Both of those are true at the same time, and it is not a paradox. **Docker's
port mapping exists as soon as the container starts, whether or not anything
inside the container is bound to that port.** `ss` is reporting the mapping,
not the resolver.

The usual cause is that **AdGuard was never configured** and is still sitting
on the install wizard. A fresh, unconfigured AdGuard runs *no DNS server at
all* — only the web API, redirecting everything to `/install.html`. Confirm:

```bash
docker compose --project-directory . logs --tail=30 adguard
```

If you see:

```
webapi: This is the first launch of AdGuard Home, redirecting everything to /install.html
webapi: serving url=http://127.0.0.1:3000
```

…and nothing about a DNS server starting, that is it. There is no
`AdGuardHome.yaml`:

```bash
ls -l ~/services/adguard/conf/AdGuardHome.yaml     # missing = never configured
```

**Fix:** re-run the deploy, which drives the install API.

```bash
cd ~/dev/setup-server/services/adguard && ./setup.sh
```

If that run fails on the configure step, see the HTTP 400 section below.

A healthy, configured start logs something like:

```
dnsproxy: starting dns proxy server
dnsproxy: listening to udp://[::]:53
dnsproxy: listening to tcp://[::]:53
```

**Never accept a listener check as proof this service works.** `setup.sh` and
the live suite both verify by *resolving a name* for exactly this reason.

## Container restart-loops after a reboot

Expected once or twice; a problem only if it never settles.

```bash
docker compose --project-directory . ps            # look at STATUS
docker compose --project-directory . logs --tail=30 adguard
```

The error looks like:

```
Error response from daemon: driver failed programming external connectivity on endpoint
adguard: Error starting userland proxy: listen tcp4 100.85.87.87:53: bind: cannot
assign requested address
```

**Cause:** the DNS ports bind to a *specific* IP — the tailscale one — and
that address does not exist until `tailscaled` has brought `tailscale0` up.
On a reboot, dockerd can win that race. The bind then fails against an address
the kernel does not have yet.

**Why it self-heals:** `restart: unless-stopped` in `docker-compose.yml`. The
container dies, Docker restarts it a few seconds later, and by then
`tailscale0` exists. So the correct reaction to one or two restarts right
after a boot is to wait thirty seconds and look again.

```bash
tailscale ip -4                        # 100.85.87.87 — does the address exist?
ip addr show tailscale0 2>/dev/null    # is the interface up?
docker inspect -f '{{.RestartCount}} {{.State.Status}}' adguard
```

If it is *still* looping minutes later, the address genuinely is not there
(Tailscale logged out, `tailscaled` failed) or `ADGUARD_DNS_IP` in `.env` is stale —
the tailnet IP changed and `.env` still names the old one:

```bash
grep ADGUARD_DNS_IP ~/dev/setup-server/services/adguard/.env
tailscale ip -4
```

If they disagree, fix `.env` and `./setup.sh`. Do **not** "fix" this by
changing the publish to `0.0.0.0:53` — that puts an open resolver on the LAN.

## The install API returns HTTP 400

```
{"message":"checking address 127.0.0.1:3000: listen tcp 127.0.0.1:3000: bind: address already in use"}
```

Read the message carefully: nothing else on the box has taken that port.
**AdGuard is failing against its own running listener.**

`POST /control/install/configure` validates the `web` address you ask for by
*binding it*. AdGuard is already serving the web UI on `0.0.0.0:3000` inside
the container, so any other address in that block collides with itself. The
`web` block must name the address it is already on:

```json
{"web":{"ip":"0.0.0.0","port":3000}, "dns":{"ip":"0.0.0.0","port":53}, ...}
```

The trap is that `127.0.0.1:3000` is the *correct* value everywhere else in
this repo — it is the host-side publish — so it is the natural thing to put
there. It is not the container-internal serving address.

That `0.0.0.0` is container-internal and is **not** a host exposure. What
constrains reachability is the Docker publish spec in `docker-compose.yml`
(`${ADGUARD_DNS_IP}:53:53` and `127.0.0.1:3080:3000`). Check what is actually reachable
rather than reasoning from the JSON:

```bash
ss -ltn | grep 3080     # 127.0.0.1:3080 only
ss -ltnup | grep ':53'  # 100.85.87.87:53 only — never 0.0.0.0:53
```

Other 400s from the same endpoint:

- **`Adding user: ...` / a rejected password** — the install API takes a
  *plaintext* password and hashes it itself. If something pre-hashed it, undo
  that.
- **The endpoint 404s or redirects instead of 400ing** — AdGuard is already
  configured, so the install API is gone. That is success, not failure; see
  below.

## "Already configured" is not an error

On a re-run, `/control/install/configure` is no longer the right call and
`setup.sh` skips it. That is correct behaviour and the run should still exit
zero — idempotency is non-negotiable in this repo.

Confirm which state you are in:

```bash
ls -l ~/services/adguard/conf/AdGuardHome.yaml                 # exists = configured
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/control/status
#   401 = configured (it wants a login).  302 = NOT configured.
```

If a run *does* fail with something like "install failed" on a box that is
plainly already working, that is a bug in the detection, not a reason to
delete the config. Do not "fix" it by removing `AdGuardHome.yaml` — that
throws away your blocklists, client rules and login, and drops you back to the
wizard, i.e. into the "listening but refused" state above.

## `permcheck: warning: found unexpected permissions`

```
permcheck: warning: found unexpected permissions type=directory
path=/opt/adguardhome/work perm=0775 want=0700
```

Cosmetic, logged on **every** start, and worth fixing so that log lines stay
meaningful. AdGuard wants its data directories to be `0700`; a directory
created with the default umask is `0775`.

```bash
ls -ld ~/services/adguard/work ~/services/adguard/conf
chmod 700 ~/services/adguard/work ~/services/adguard/conf
docker compose --project-directory . restart      # ⚠️ brief DNS outage, see top of page
```

`setup.sh` creates these `0700`, so seeing this means either the directories
predate that, or something re-created them. It is not a security hole on a
single-user box; it is noise that trains you to ignore warnings.

## Log lines that are NOT problems

Two appear on a perfectly healthy start, and both look alarming enough to send
you looking for a fault that is not there.

```
warning: private rdns resolution failed; disabling err="preparing resolvers: no upstream specified"
```

Benign, on **every** start. It means AdGuard has no private reverse-DNS
upstream configured — i.e. it cannot turn `192.168.1.42` back into a hostname
for the query log's client column. There is nothing here for it to ask, and
the feature it is disabling is a display nicety. Forward resolution, which is
the entire job, is unaffected.

```
[dnsproxy] listening to udp://[::]:53
```

Also fine: that is the listener **inside** the container's own network
namespace. What constrains reachability is the host publish spec
(`${ADGUARD_DNS_IP}:53:53`), which is what `ss` on the host reports. Compare
with the "0.0.0.0 inside the container is not a host exposure" note above —
same distinction.

## Web UI problems

### The UI does not load at all

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/control/status
#   401 = healthy.  302 = on the install wizard.  000 = not listening.
tailscale serve status | grep -A2 ':3080'
```

- **Connection refused on 127.0.0.1:3080 for a few seconds after a start** —
  normal. A container that is up is not a server that is listening; `curl`
  reports that as exit 7 / HTTP `000`. `setup.sh` retries for this reason.
- **It loads on loopback but not over HTTPS** — a publish problem, see the
  Serve section.
- **Port 3080 shows something that isn't AdGuard** — check nothing else
  claimed it. Note `3000` (AdGuard's own default) belongs to **forgejo** on
  this box, which is why this deploy uses 3080 at all. `ss -ltnp | grep 3080`.

### It redirects to `/install.html`

Not configured. See the first section — it also means DNS is dead.

### Locked out of the web UI

Five failed attempts triggers `block_auth_min: 15` — wait fifteen minutes
before assuming the password is wrong. The credentials are in
`~/dev/setup-server/services/adguard/.env`.

If they are genuinely lost, there is no reset button; the password lives as a
bcrypt hash in the config. Remove the user and let `setup.sh` re-run the
install:

```bash
cd ~/dev/setup-server/services/adguard
# sudo: the container runs as root, so it owns this file even though the
# directory is yours.
sudo cp ~/services/adguard/conf/AdGuardHome.yaml ~/AdGuardHome.yaml.bak   # keep your blocklists
docker compose --project-directory . stop        # ⚠️ DNS outage while stopped
sudoedit ~/services/adguard/conf/AdGuardHome.yaml   # delete the `users:` entries
docker compose --project-directory . start
```

With `users:` empty AdGuard serves the UI without a login. Set a password
again immediately (Settings → the UI will prompt), or restore the backup.

## DNS problems

### Resolves on the server but not from the phone/laptop

Almost always the tailnet is not pointed at it. That is a manual step and it
is easy to have skipped:

<https://login.tailscale.com/admin/dns> → **Nameservers** → `100.85.87.87`
should be listed. See SETUP.md → *Point the tailnet at it*.

Then, on the client device:

```bash
dig +short @100.85.87.87 example.com     # direct: does the resolver answer THIS device?
dig +short example.com                   # via the client's configured DNS
```

- **The direct query works, the plain one does not** — the client is not
  using AdGuard. Tailscale nameserver setting, or "Override local DNS" is off
  and the local network is winning.
- **Neither works, but both work on the server** — that device is not on the
  tailnet, or an ACL blocks it. `tailscale status` on that device.

### `*.ts.net` names stopped resolving after adding the nameserver

MagicDNS is supposed to resolve tailnet names itself and forward only
everything else. If it is not, check **MagicDNS is still ON** in the same
console page — adding a global nameserver does not turn it off, but people
turn it off while they are in there.

Note that SETUP.md flags this coexistence as *documented but not verified on
this box* — verifying it would have meant changing live tailnet DNS. If it is
genuinely broken, remove the nameserver from the console (that is the instant
rollback) and say so.

### Everything resolves but nothing is blocked

- Is the query even reaching AdGuard? Web UI → **Query log**. If a device does
  not appear there, it is not using this resolver.
- Is filtering paused? Settings → General → Protection.
- Is a blocklist enabled? Filters → DNS blocklists — "AdGuard DNS filter"
  should be on and show a rule count.
- Test with a domain that is definitely on the list:
  `dig +short @100.85.87.87 doubleclick.net` → `0.0.0.0` or NXDOMAIN.
- **Browser-only**: Chrome and Firefox can use their own DNS-over-HTTPS,
  bypassing the system resolver entirely. Check the browser's secure-DNS
  setting before blaming AdGuard.

### A site broke and you think AdGuard did it

```bash
# Compare against the upstream directly:
dig +short @100.85.87.87 the-broken-site.example
dig +short @9.9.9.10     the-broken-site.example
```

Different answers → AdGuard blocked it. Web UI → Query log → find the query →
**Unblock** adds an exception. Do that rather than disabling the whole list.

### Slow resolution

Upstream is DNS-over-HTTPS, which costs a TLS handshake on a cold connection.
Steady-state should be a few ms from cache. If everything is slow:

```bash
docker compose --project-directory . logs --tail=50 adguard | grep -i upstream
```

Also consider `dns.ratelimit`, which this deploy sets to `0` (unlimited) by
default, a deliberate deviation from AdGuard's own shipped default of `20`
qps per client subnet. If it was changed back to a nonzero value, a browser
opening many tabs can hit it, and the symptom is intermittent timeouts rather
than an error. SETUP.md → Configuration decisions has the detail.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` shows what has `:3080`.
  Remove just that one:

  ```bash
  tailscale serve --https=3080 off
  ```

  ⚠️ **Never `tailscale serve reset`** — that clears every mapping on the
  node, taking code-server, Seafile, Immich, forgejo and everything else down
  with it. `off` is undocumented in `--help` but is what Tailscale prints
  itself, and it is the only single-port removal.

Note that Serve carries **only the web UI**. It cannot carry DNS — Serve
proxies HTTP, and DNS is UDP — so `serve status` being empty never explains a
DNS failure, and fixing Serve never fixes one. See SETUP.md → *The loopback
rule*.

## Did this break the host's own DNS?

It should not have — this deploy leaves `systemd-resolved` completely alone
and binds a different address. Check, do not assume:

```bash
systemctl is-active systemd-resolved     # active
getent hosts github.com                  # resolves
resolvectl status | head -20             # stub listener still 127.0.0.53
```

If resolved is not active, or `/etc/resolv.conf` has been edited, **something
went outside this deploy's design** — no part of `setup.sh` touches either.
Restoring the host's resolver is the priority, because every other service on
this box reaches the internet through it:

```bash
sudo systemctl start systemd-resolved
ls -l /etc/resolv.conf     # should symlink to ../run/systemd/resolve/stub-resolv.conf
```

The live suite asserts both of these so a regression shows up as a red line
rather than as three unrelated services mysteriously failing.

## Backing it out safely (order matters)

**This is the most dangerous thing about this service.** Get the order wrong
and every device on the tailnet loses DNS — phone, laptop, wherever they are —
with no working name resolution to fix it from.

The failure mode: the Tailscale console still tells every device "your
nameserver is 100.85.87.87", but nothing is answering there any more. Devices
do not fall back to something sensible; they just stop resolving. Depending on
"Override local DNS", the device may not even have a second nameserver to try.

### Correct order

```
1. Tailscale console: REMOVE the nameserver          ← devices stop asking AdGuard
2. Confirm from another device that DNS still works
3. Only then: stop / remove / rebuild AdGuard here
```

1. <https://login.tailscale.com/admin/dns> → **Nameservers** → remove
   `100.85.87.87`. This takes effect on devices within seconds to a minute.
2. From a second device (not this server):

   ```bash
   dig +short example.com          # still resolves = it is no longer depending on AdGuard
   ```

   Do not skip this. It is the only thing that proves step 1 propagated.
3. Now do whatever you came to do. To take it off the box, use the
   teardown script: it refuses to stop anything while
   `tailscale dns status --json` still lists this node's IP as a resolver
   (Resolvers, FallbackResolvers, split DNS routes or legacy Nameservers),
   so the wrong order is blocked rather than just discouraged:

   ```bash
   cd ~/dev/setup-server/services/adguard
   ./teardown.sh                 # unpublish :3080, compose down; conf/work/.env kept
   ```

   If it says it **could not tell** (tailscaled down, logged out, a CLI
   without `dns status --json`, or JSON whose resolver fields are not the
   types it expects), and you did steps 1 and 2 yourself, re-run
   with `./teardown.sh --dns-removed`. That flag never overrides a
   nameserver the tailnet still lists. The launcher's Remove button runs the
   plain form, so it only works once the check comes back clear.

### If you already stopped it and the tailnet is broken

Do not panic-debug DNS. Get resolution back first, in whichever way is
quickest:

- **Fastest, on this box:** bring AdGuard back up.
  `cd ~/dev/setup-server/services/adguard && docker compose --project-directory . up -d`
- **From a device that still resolves**, or one where you can reach the
  Tailscale console by IP: remove the nameserver as above.
- **On the stuck device**, as a temporary bridge: turn Tailscale off entirely.
  It falls back to the local network's DNS, which gets you a browser that can
  reach `login.tailscale.com`.

Then fix it properly.

### Brief outages are still outages

`docker compose restart` and `./setup.sh` both bounce the container, and for
those few seconds the tailnet has no resolver. That is usually fine —
resolvers retry — but it is why the UI's *Protection → pause* is the better
tool for "stop filtering for a minute", and why you should not do maintenance
here while someone else is on a call.

## Nuke and pave

Destroys the AdGuard configuration: the web login, every blocklist choice,
every custom filtering rule and client setting, and the query log. It does
**not** affect anything else on this box.

**Do step 1 first.** Removing the nameserver before the resolver disappears is
the whole point of the previous section.

```bash
# 1. Tailscale console → DNS → Nameservers → remove 100.85.87.87. Verify from
#    another device that DNS still works. Do not skip this.

# 2. Confirm the paths before deleting them — a `rm -rf` of a path that never
#    existed is a silent no-op that leaves you thinking you started clean.
ls -ld ~/services/adguard ~/services/adguard/conf ~/services/adguard/work
ls -l  ~/services/adguard/conf/AdGuardHome.yaml
grep -E "^(ADGUARD_CONF|ADGUARD_WORK)=" ~/dev/setup-server/services/adguard/.env

# 3. Keep the config if you might want the blocklists back. Do this BEFORE
#    step 4, which deletes it. sudo: the container runs as root, so
#    everything under conf/ and work/ is root-owned on the host even though
#    the directories are yours.
sudo cp ~/services/adguard/conf/AdGuardHome.yaml ~/AdGuardHome-$(date +%F).yaml
sudo chown $(id -u):$(id -g) ~/AdGuardHome-$(date +%F).yaml

# 4. Tear down. Refuses while the tailnet still lists this node as a
#    nameserver (step 1), then asks you to type "adguard". Unpublishes only
#    the Serve ports that point at :3080 (never `serve reset`), runs
#    `compose down`, deletes the ADGUARD_CONF and ADGUARD_WORK dirs named in
#    .env (root-owned files cleared with the pinned image, no sudo), then
#    .env and the empty ~/services/adguard.
cd ~/dev/setup-server/services/adguard
./teardown.sh --purge             # add --dns-removed only if it says it could not tell

# 5. Redeploy, then re-add the nameserver in the Tailscale console.
./setup.sh
```

Two things that make this recipe safe rather than superstitious:

- **The `.env` paths in step 2 are the authority.** If `setup.sh` was ever run
  with `ADGUARD_CONF`/`ADGUARD_WORK` pointing elsewhere, `~/services/adguard`
  is not where the data is, and `rm -rf` on it is a silent no-op that leaves
  you convinced you started clean. Check before you delete, not after — that
  is why step 2 exists and why it prints the `.env` values next to the paths.
- **`sudo` on the `rm -rf`.** The directories are yours; their *contents* are
  root's, because the container runs as root. A plain `rm -rf` fails partway
  through with permission errors, and a half-deleted data dir is worse than
  either extreme — AdGuard comes back up on a config file that is missing
  half its state.

`./teardown.sh --purge` does both for you: it deletes exactly the `.env`
paths (and refuses any outside `~/services/adguard`), and clears root-owned
files with a throwaway container of the pinned image. If that cleanup fails
it stops, keeps `.env`, and prints the `sudo rm -rf` to run.

By hand, without sudo, delete the contents from inside a container that is
already root:

```bash
docker run --rm -v ~/services/adguard:/x --entrypoint rm alpine -rf /x/conf /x/work
```

To keep the configuration and rebuild only the container — the usual thing you
actually want — do not delete anything:

```bash
cd ~/dev/setup-server/services/adguard
docker compose --project-directory . up -d --force-recreate
```

To keep the blocklists but reset the login, see *Locked out of the web UI*
above; that is a smaller hammer than this one.
