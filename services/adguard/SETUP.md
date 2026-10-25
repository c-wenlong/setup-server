# adguard — tailnet-wide DNS ad & tracker blocking (AdGuard Home)

A DNS resolver for the whole tailnet that refuses to answer for ad, tracker
and malware domains. Blocking happens at the *name resolution* layer, so it
works on every device that uses this tailnet's DNS — the phone included,
inside apps, with no extension to install and nothing to jailbreak.

- Web UI: `https://homeserver.tail-name.ts.net:3080` (tailnet only)
- DNS: `100.77.77.77:53`, UDP and TCP, on the **tailscale interface only**

> ### ⚠️ Deploying it is only half the job
>
> `setup.sh` finishes with AdGuard running and **filtering nothing**, because
> nothing is sending it queries yet. The step that makes it real is a manual
> one in the Tailscale admin console, and it is deliberately not automated.
> See [Point the tailnet at it](#point-the-tailnet-at-it-the-manual-step)
> below — that section is the reason this page exists.
>
> ### ⚠️ Backing it out has a required order
>
> Remove the nameserver from the Tailscale console **first**, then stop
> AdGuard. Doing it the other way round takes DNS down for every device on
> the tailnet — including the one you would use to fix it. TROUBLESHOOT.md →
> *Backing it out safely* has the ordering.

## What this is

[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) is a single Go
binary that speaks DNS on one side and forwards to an upstream resolver on the
other, dropping anything that matches a blocklist on the way through. This
deploy pins **v0.107.79** (schema 34).

What you get, versus a browser ad blocker:

- **Every device, every app.** uBlock Origin cannot touch the ads inside a
  phone app, a smart TV, or a game. DNS-level blocking can.
- **One place to change it.** Blocklists live on the server, not on eight
  devices.
- **Encrypted upstream by default.** Queries leave this box over DNS-over-HTTPS
  to Quad9 (`https://dns10.quad9.net/dns-query`), so the ISP no longer sees a
  plaintext list of every domain anyone on the tailnet visits. Quad9's `dns10`
  endpoint is the *malware-blocking, no-EDNS-client-subnet* one, which is a
  second filter layer for free.

What it is not:

- **Not an ad blocker for in-page ads.** DNS blocking removes requests to ad
  *hosts*. An ad served from the same domain as the content (YouTube's
  pre-rolls, first-party sponsored posts) is invisible to it. Keep uBlock
  Origin in the browser; the two stack.
- **Not a firewall, not a VPN.** It answers questions about names. A device
  that hardcodes `8.8.8.8` bypasses it entirely, and several smart-TV apps do
  exactly that.
- **Not DHCP.** `dhcp.enabled: false` and it stays that way — this box is not
  the LAN's DHCP server and turning it on would fight the router.

## Architecture

```
   phone / laptop / anything on the tailnet
         │
         │  ① DNS queries, port 53 (UDP+TCP)
         │     — because the Tailscale admin console lists
         │       100.77.77.77 as a global nameserver
         ▼
   100.77.77.77:53   ← the tailscale0 interface, NOT 0.0.0.0
         │
   ┌─────┴──────────────────────────────────────────┐
   │ container: adguard                         │
   │   adguard/adguardhome:v0.107.79                │
   │                                                │
   │   DNS server        :53   udp + tcp            │
   │   web UI + API      :3000 (container-internal) │
   └─────┬───────────────────────────┬──────────────┘
         │ bind mounts               │
         ▼                           │  ② the web UI, published
   ~/services/adguard/work           │     the ordinary way
   ~/services/adguard/conf           ▼
                              127.0.0.1:3080
                                     │
                              tailscaled (Tailscale Serve, TLS)
                                     │
                     https://homeserver.tail-name.ts.net:3080
```

Two published surfaces, published two different ways, and that asymmetry is
the one genuinely unusual thing about this service. See
[the loopback exception](#the-loopback-rule-and-why-53-is-an-exception).

State lives under `~/services/adguard`:

```
~/services/adguard/
  conf/
    AdGuardHome.yaml     # the entire configuration: upstreams, blocklists,
                         # the web login (bcrypt), client rules
  work/
    data/
      stats.db           # query statistics (1 day by default)
      sessions.db        # web UI login sessions
      filters/           # the downloaded blocklists
      querylog.json      # every query, 90 days by default — see Privacy.
                         #   Only appears once queries start arriving, i.e.
                         #   after the Tailscale console step below.
```

`conf/AdGuardHome.yaml` is the whole configuration. Copy it and you can
rebuild this deploy anywhere; the rest of `work/` is a cache and logs.

Both directories are `0700` and the files **inside** them are owned by
`root` — the container runs as root, which is upstream's design and not
something this deploy changes. Reading or deleting their contents from the
host needs `sudo`; the directories themselves are yours, which is why
`ls -ld` and `test -f` work without it.

## Point the tailnet at it (the manual step)

**Until you do this, AdGuard is running and filtering nothing.** Nothing on
the tailnet sends it a query, because nothing has been told to.

1. Open <https://login.tailscale.com/admin/dns>
2. Under **Nameservers**, *Add nameserver* → **Custom…**
3. Enter this node's tailnet IPv4 — the address the deploy printed (run
   `tailscale ip -4` if you need it again)
4. Leave **Override local DNS** as you find it; see the note below.
5. Leave **MagicDNS** ON.

Then, from another tailnet device:

```bash
dig +short doubleclick.net       # should be 0.0.0.0 or NXDOMAIN — blocked
dig +short example.com           # should be a real address — working
```

### Why the script does not do this for you

`setup.sh` prints the instruction and stops. That is a deliberate choice, not
an unfinished feature.

Changing the tailnet's nameserver changes DNS **for every device on the
tailnet at once** — your phone, your laptop, wherever they are in the world.
The blast radius of getting it wrong is not "a service is down"; it is "no
device can resolve any name", including the device you would use to log in to
the Tailscale console and undo it. There is a Tailscale API that can set it,
which makes it worse rather than better: a script that can quietly take your
phone off the internet from three timezones away is a script that should not
have that capability at all.

So it stays a human action, taken in a browser, by someone who is looking at
it. Twenty seconds of clicking, in exchange for never having to debug that
particular outage.

### MagicDNS keeps working (documented, not verified here)

The obvious worry: if the tailnet's global nameserver becomes AdGuard, does
`homeserver.tail-name.ts.net` — which every other service on this box is
reached by — stop resolving?

Per Tailscale's documentation, no. With MagicDNS enabled, the Tailscale client
resolves `*.ts.net` names itself and forwards only everything *else* to the
global nameservers. The tailnet's own names never reach AdGuard.

**This was not verified on this box**, and the honest reason is that verifying
it would mean changing the user's live tailnet DNS — the exact thing the
previous section refuses to do unsupervised. Treat it as documented upstream
behaviour that is very likely correct, not as a measured fact from this
deploy. If you add the nameserver and a `.ts.net` URL stops working, that is
the case this note was hedging against; TROUBLESHOOT.md has the immediate
rollback.

The **Override local DNS** toggle interacts with this: with it on, tailnet
devices use AdGuard *instead of* whatever DNS their local network handed them,
which is what you want on a phone that roams between networks. With it off,
AdGuard is used only when the local network offers nothing. Start with
whatever the tailnet already has; changing two variables at once is how you
lose an afternoon.

## The loopback rule, and why :53 is an exception

Every other service in this repo binds `127.0.0.1` and is published by
`tailscale serve`. AdGuard's web UI does exactly that. Its **DNS listener
cannot**, and the reason is structural:

- **Tailscale Serve proxies HTTP(S). DNS is UDP** (and TCP, but not HTTP).
  There is no Serve mode that can carry it.
- Even if there were, the Tailscale nameserver setting takes an **IP address**.
  Clients must be able to send a DNS packet straight to `100.77.77.77:53`, or
  the whole design has nowhere to point.

So the compose file publishes the DNS ports to the tailscale IP specifically:

```yaml
ports:
  - "${ADGUARD_DNS_IP}:53:53/tcp"
  - "${ADGUARD_DNS_IP}:53:53/udp"
  - "127.0.0.1:${LOCAL_PORT}:3000/tcp"   # web UI: loopback + Serve, as usual
```

`ADGUARD_DNS_IP` is resolved at deploy time from `tailscale ip -4` and written into
`.env`. It is **not hardcoded** in `docker-compose.yml`, the same way no other
service hardcodes the tailnet hostname.

This satisfies the *spirit* of the loopback rule — `tailscale0` is not the
LAN, and nothing off the tailnet can send a packet to that address — but it is
not literally loopback, and it is worth saying so out loud rather than letting
a future reader assume the rule was forgotten. The repo's shared
`no_external_listener` test helper already allows loopback **plus the node's
own Tailscale addresses**; on every other service that allowance is incidental
(it exists so tailscaled's own Serve frontend doesn't false-positive), and
here it is load-bearing. The live suite asserts both halves: that `:53` is on
the tailscale IP, and that it is **not** on `0.0.0.0` or a LAN address.

A `0.0.0.0:53` publish would expose a recursive resolver to the LAN. Treat
seeing one as an incident, not a style problem.

## systemd-resolved is left completely alone

Every AdGuard-on-Ubuntu guide opens with "systemd-resolved owns port 53,
disable `DNSStubListener` first". **Measured on this box, it does not.**
resolved binds only its stub addresses:

```
127.0.0.53%lo:53   udp + tcp
127.0.0.54:53      udp + tcp
```

Nothing on `0.0.0.0:53`. AdGuard takes `100.77.77.77:53` — a different
address — and the two coexist. Verified by running both at once: resolved
stayed `active`, `getent hosts github.com` kept working, and AdGuard answered
on the tailnet IP simultaneously.

**Do not disable systemd-resolved. Do not edit `/etc/resolv.conf` or
`/etc/systemd/resolved.conf`.** Both are unnecessary here, and both would
break this host's *own* name resolution — which is how every other service on
this box reaches the internet. The live suite asserts `systemd-resolved` is
still `active` and that the host can still resolve, precisely so that a
regression here shows up as a red line rather than as a mysterious outage
three services away.

Note the host does **not** use AdGuard for its own lookups, by design. It
keeps talking to resolved. That means a broken AdGuard cannot take the box
down with it.

## Security model

- **DNS is tailnet-only.** `${ADGUARD_DNS_IP}:53`, never `0.0.0.0:53`. An open
  recursive resolver on a LAN (or worse, the internet) is a DDoS amplifier and
  gets your IP on a blocklist. The live suite checks for a wildcard bind
  explicitly.
- **The web UI is loopback + Serve**, like everything else here. TLS is
  Tailscale's.
- **The web UI has its own login**, unlike most services in this repo, which
  lean entirely on the tailnet boundary. AdGuard ships one (`users:` with a
  bcrypt hash, `auth_attempts: 5`, `block_auth_min: 15`) and there is no
  supported way to run without it, so the credentials are generated into
  `.env` rather than fought with. That is defence in depth, not a replacement
  for the tailnet.
- **Upstream is encrypted** (DoH to Quad9), so this box's ISP sees TLS to one
  host instead of a plaintext feed of every domain the tailnet resolves.
- **DNSSEC validation is on** (`enable_dnssec: true`, upstream default). Kept.
- **DHCP is off** and must stay off.
- **No firewall port is opened**, on the host or the router.

### Privacy: the query log sees everything

Once the tailnet points here, AdGuard's query log records **every domain every
device on the tailnet looks up**, with a timestamp and the client that asked,
retained for **90 days** by default (`querylog.interval: 90d`). That is a more
complete picture of what you and anyone sharing the tailnet do all day than
any single service on this box holds — browser history, but for every app on
every device, and not deletable from the device.

It is local, it goes nowhere, and it is genuinely useful for working out what
a device is chattering to. But decide on it deliberately rather than
inheriting the default. Settings → General settings in the UI lets you shorten
the retention, disable the log, or turn on "anonymize client IP"; the same
section covers the statistics database (`statistics.interval: 1d`).

## Configuration decisions

Read out of the generated `AdGuardHome.yaml` on v0.107.79 (schema 34):

| Setting | Value | Why |
|---|---|---|
| Upstream | `https://dns10.quad9.net/dns-query` (DoH) | shipped default; encrypted, malware-filtering, no ECS. Bootstrap `9.9.9.10` / `149.112.112.10` |
| `enable_dnssec` | `true` | shipped default, kept |
| Blocklists | "AdGuard DNS filter" **enabled**; "AdAway Default Blocklist" disabled | one list is a sane start. Add more in the UI once you know what breaks |
| `dhcp.enabled` | `false` | the router does DHCP |
| `querylog.interval` | `90d` | shipped default — see Privacy above |
| `dns.ratelimit` | `0` (unlimited) | deliberate deviation from AdGuard's shipped default of 20. See below |

**On `ratelimit`:** 20 queries/sec per client subnet is aimed at a resolver
exposed to strangers. On a fully-trusted tailnet it can throttle a browser
opening a lot of tabs at once, and setting it to `0` (unlimited) is defensible.
It is a change from the shipped default, so if you make it, make it
deliberately and leave a comment — do not let a future reader find an
unexplained `0` and assume it was always that way.

## Why the install API, and not a pre-seeded config

There are two ways to configure a fresh AdGuard without clicking through the
wizard, and this deploy takes the second.

1. **Pre-seed `AdGuardHome.yaml` before first start.** Correct, and how most
   guides do it — except the `users:` entry needs a **bcrypt** hash
   (`$2a$10$…`), and this host has no bcrypt tool: no `htpasswd`, and python3
   here has no `bcrypt` module. Adding one is a host dependency the rest of
   this repo does not need.
2. ✅ **Drive the install API**, which takes a *plaintext* password and hashes
   it itself. Zero host dependencies:

```
POST http://127.0.0.1:3080/control/install/configure
  {"web":{"ip":"0.0.0.0","port":3000},
   "dns":{"ip":"0.0.0.0","port":53},
   "username":"...","password":"..."}
  -> 200 "OK"
```

Two things about that body are not obvious and are both measured:

- **The `web` block must name the address AdGuard is *already* serving on** —
  `0.0.0.0:3000`, container-internal. AdGuard validates the requested web
  address by trying to bind it, and if you name anything else it fails against
  its own running listener:

  ```
  {"web":{"ip":"127.0.0.1","port":3000}, ...}
    -> 400  checking address 127.0.0.1:3000: listen tcp ... address already in use
  ```

  A script that helpfully passes `127.0.0.1:3000` here — the address that is
  correct everywhere else in this repo — gets an HTTP 400 and a failed deploy.
- **The `0.0.0.0` is container-internal and is not a host exposure.** What
  constrains reachability is the Docker publish spec (`${ADGUARD_DNS_IP}:53:53`,
  `127.0.0.1:3080:3000`), exactly as with Immich. AdGuard binds `0.0.0.0`
  inside its own network namespace and Docker decides who can reach it.

**Already-configured is a success, not an error.** On a re-run the config file
exists, `/control/install/configure` is no longer the right call, and the
script detects that (config present, or `GET /control/status` answering) and
skips it. Treating a second run as a failure would break idempotency, which is
non-negotiable in this repo.

## Ports on this box

- **3000 is taken by forgejo**, which is AdGuard's default web port. This
  deploy uses local **3080**, published `127.0.0.1:3080`, Serve on **:3080**.
  Verified free, and free of any existing `tailscale serve` claim.
- **53/tcp and 53/udp on `100.77.77.77` only.**
- The container still uses `:3000` *inside* its own namespace; only the host
  side moved.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker's restart policy handles boot; no systemd unit | ✅ |
| Docker + Compose v2 | the one container | ✅ (incl. daemon reachability) |
| curl | the readiness loop and the install API | ✅ |
| Tailscale, logged in | publishing the UI **and** the DNS bind address | ✅ (`BackendState` must be `Running`; `tailscale ip -4` must return an address) |
| A free `:53` on the tailscale IP | the resolver | ✅ |
| ~100 MB disk | image + config + 90 days of query log | — |

No bcrypt tool, no `dig` on the host for the deploy itself (the *tests* use
one), no database server.

## Deploy

```bash
cd services/adguard && ./setup.sh      # idempotent; re-run to upgrade or repair
```

Step by step:

1. **Preflight** — OS, non-root, `curl`, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports.
2. **Resolve the tailscale IP** from `tailscale ip -4`, before anything is
   written. This is the DNS bind address and it must be right at first boot;
   it is never hardcoded.
3. **`.env`** — written only if absent, mode 600: the pinned image tag,
   `LOCAL_PORT=3080`, `ADGUARD_DNS_IP`, `ADGUARD_CONF`/`ADGUARD_WORK`, and generated web-UI
   credentials. On a re-run `.env` is the source of truth and is not
   rewritten.
4. **Create the data dirs `0700`.** Not cosmetic: AdGuard runs a permission
   check at every start and logs
   `permcheck: warning: found unexpected permissions ... perm=0775 want=0700`
   against a default-mode directory. Creating them right means the warning
   never appears, so its appearance stays meaningful.
5. **`docker compose up -d`** with `restart: unless-stopped`.
6. **Wait for the web UI** on `127.0.0.1:3080` — a retry loop. A container
   that is "up" is not a server that is listening; before it is, the
   connection is *refused*, which `curl` reports as exit 7 and HTTP `000`,
   not as a tidy 503. A deploy that treats the first `000` as fatal fails most
   cold starts. Jellyfin's deploy in this repo was bitten by exactly that.
7. **Configure, or detect that it is already configured** — the install API
   above, skipped as a success on a re-run.
8. **`tailscale serve --bg --https=3080 http://127.0.0.1:3080`**, with the
   operator-grant and approval-link fallbacks the other services use.
9. **Verify by resolving a real name** — `dig @<ADGUARD_DNS_IP> example.com` must come
   back with an A record. Observing that something is listening on `:53` is
   *not* enough; see below.
10. **Print the manual Tailscale console step**, loudly, because until it is
    done nothing is being filtered.

### Why verification resolves a name instead of checking the port

On first launch AdGuard runs **no DNS server at all** — only the install
wizard:

```
webapi: This is the first launch of AdGuard Home, redirecting everything to /install.html
webapi: serving url=http://127.0.0.1:3000
```

and that is the entire startup. But the Docker port mapping for `:53` exists
regardless, so `ss` cheerfully reports `100.77.77.77:53` as LISTEN while
nothing inside the container is bound to it. Measured:

```
dig @100.77.77.77 example.com   ->  ;; communications error ... connection refused
```

A verify step that only asks "is something listening on :53" therefore passes
against a completely non-functional resolver — and it would pass on exactly
the deploy that failed. After configuration the same query returns real
answers. So the check is a query, in `setup.sh` and in the live suite both.

## Client side

**Nothing to install.** Adding the nameserver in the Tailscale console is the
entire client-side setup, and it applies to every device on the tailnet at
once — that is the whole appeal.

To check a particular device is actually going through AdGuard, look at
Settings → Client settings, or just watch the query log while you load a page
on it.

A device can opt out only by hardcoding a resolver (`8.8.8.8` in its network
settings, or an app that ships its own DoH). Several smart TVs do this
deliberately. There is no fix for that at this layer.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f adguard`
- Is it actually resolving?
  ```bash
  dig +short @100.77.77.77 example.com        # a real A record
  dig +short @100.77.77.77 doubleclick.net    # 0.0.0.0 / NXDOMAIN = blocked
  ```
- Web UI: `https://homeserver.tail-name.ts.net:3080`, credentials in
  `services/adguard/.env`.
- Config: `~/services/adguard/conf/AdGuardHome.yaml`. **Edit it through the
  web UI**, not by hand while the container is running — AdGuard rewrites the
  whole file on any UI change and will overwrite you. To hand-edit: stop the
  container, edit, start.
- Back up the config (small, and the only irreplaceable part). `sudo` because
  the container runs as root and owns the file, even though the directory is
  yours:
  ```bash
  sudo cp ~/services/adguard/conf/AdGuardHome.yaml ~/adguard-$(date +%F).yaml
  sudo chown $(id -u):$(id -g) ~/adguard-$(date +%F).yaml
  ```
- Temporarily stop filtering without touching the tailnet setting: Settings →
  General → *Protection* → pause for 10 minutes. Better than stopping the
  container, which takes DNS down for everyone.
- Upgrade: bump the version in `.env`, then
  `docker compose --project-directory . pull && ./setup.sh`.
- Remove: **first** remove this node's IP from Tailscale admin → DNS →
  Nameservers and check another device still resolves, then `./teardown.sh`
  (unpublishes :3080, `compose down`; config and `.env` kept, `./setup.sh`
  restores it). It refuses while `tailscale dns status --json` still lists
  this node as a resolver; `--dns-removed` covers only the case where it
  cannot read that. `./teardown.sh --purge` also deletes conf/, work/ and
  `.env` after you type `adguard`. See TROUBLESHOOT.md, "Backing it out
  safely".

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` in a sandbox — temp `$HOME`, a
copied service directory, PATH stubs for every external command — and touches
nothing on the host. The `curl` stub fakes AdGuard's install and status API,
including the HTTP 400 that a wrong `web` block gets and a cold start modelled
as a *refused connection* rather than a tidy 503.

The live suite is the one that proves the deploy works: container running, web
UI on loopback, tailnet HTTPS answering, the Serve mapping present, no
external listener on the web port, `:53` on the tailscale IP and **not** on a
wildcard or LAN address — and, the check none of the others substitute for, a
**real DNS query through `100.77.77.77:53` returning an A record**. It also
asserts `systemd-resolved` is still active and the host still resolves, so a
deploy that broke the box's own DNS cannot report green.

## Notes

- Pinned to `adguard/adguardhome:v0.107.79`, not `:latest`. `:latest` resolved
  to that version when this was written; a resolver that silently changes
  version under you is a resolver that changes behaviour for every device on
  the tailnet at once.
- `restart: unless-stopped` is required rather than decorative here. The DNS
  ports bind to a *specific* IP, and that bind fails if `tailscale0` does not
  exist yet — which happens on a reboot where dockerd starts before tailscaled.
  The restart policy turns that from a dead service into a couple of restarts
  and then a healthy one. A restart or two immediately after a reboot is
  expected; see TROUBLESHOOT.md before treating it as a fault.
- The web UI login is real (bcrypt, 5 attempts then a 15-minute block).
  Losing it means editing `users:` out of `AdGuardHome.yaml`, not a reset
  button — TROUBLESHOOT.md has that recipe.
