# remote-desktop — this host's GNOME desktop in a browser tab

Apache Guacamole, an HTML5 remote-desktop gateway, in front of the RDP
backend that Ubuntu 24.04 already ships (`gnome-remote-desktop`). Open
`https://homeserver.tail-name.ts.net:8094` from any browser on the
tailnet and you are driving **this machine's** desktop — the real
filesystem, the real `~/dev`, the real Docker socket. No client to
install, on the Mac or anywhere else.

Read `COMPETITIVE-ANALYSIS.md` for why Guacamole and not KasmVNC,
RustDesk, MeshCentral or NoMachine. Read this file for how it is wired
and, more importantly, for **the security model — which is the part of
this service that does not fit the repo's usual shape.** If you read
nothing else here, read [The security model](#the-security-model).

## Architecture

```
Mac browser
 └─ https://homeserver.tail-name.ts.net:8094      TLS, tailnet-only
      │                                                 (tailscale serve)
      └─ guacamole webapp        127.0.0.1:8094 → :8080 in container (Tomcat)
           │                     file auth via user-mapping.xml — NO database
           └─ guacd              :4822, container-internal only, never published
                │
                └─ RDP           <bridge-gateway>:3389   ⚠️ see the security model
                     │
                     └─ gnome-remote-desktop (host, systemd system daemon)
                          └─ a GNOME session as kaichen — real host, real FS
```

Two containers. Not four: file-based authentication removes the Postgres
+ initdb pair that a stock Guacamole deployment carries, and on a 7.7 GB
box that is the difference between "a service" and "a project".

Nothing of value lives in the containers. State on disk:

```
~/services/remote-desktop/
  guac-home/
    user-mapping.xml    # the single Guacamole user + the one RDP connection
```

Neither `recordings/` nor `drive/` is created. Session recording is off (see
[Session recording is off](#session-recording-is-off)), and **drive
redirection is not available with this backend at all** — see
[No file transfer](#no-file-transfer). `PLAN.md` step 6 specifies
`enable-drive` + a bind-mounted `drive-path`; that is correct for xrdp and
wrong here, and the test suite asserts the directory's absence so nobody
"restores" it from the plan.

## The security model

Every other service in this repo satisfies the repo rule the same easy
way: bind `127.0.0.1`, publish with `tailscale serve`, done. This one has
three hops and they do **not** all clear the bar. Here is each of them,
honestly.

### :8094 — the Guacamole webapp. Compliant.

Published `127.0.0.1:8094:8080`. Loopback only. `tailscale serve
--bg --https=8094 http://127.0.0.1:8094` terminates TLS in front of it
and admits tailnet peers only. This is the ordinary repo pattern and
there is nothing special about it.

### :4822 — guacd. Compliant, and deliberately invisible.

guacd speaks an unauthenticated wire protocol. Anything that can open a
TCP connection to 4822 can ask it to proxy an RDP session to an arbitrary
host with arbitrary credentials — guacd does not authenticate its
callers, because in its design the webapp *is* the authenticator.

So **4822 is never published to the host.** It has no `ports:` entry at
all; it is reachable only over the compose bridge, only by the webapp
container. If you ever find `4822` in `ss -ltn` output on this box,
something has gone wrong and it is not cosmetic. The live suite asserts
this and it is one of the checks worth keeping red until fixed.

### :3389 — the RDP backend. ⚠️ NOT compliant. Read this section.

**Measured on this box, 2026-09-11:** `gnome-remote-desktop` 46.3 has no
way to constrain which address it listens on. Not "we did not find one" —
the configuration surface is small enough to enumerate exhaustively, and
we did:

```console
$ grdctl --help          # every rdp subcommand:
  set-port  enable  disable  set-tls-cert  set-tls-key
  set-credentials  clear-credentials  enable-view-only
  disable-view-only  enable-port-negotiation  disable-port-negotiation

$ gsettings list-recursively org.gnome.desktop.remote-desktop.rdp
  enable  negotiate-port  port  screen-share-mode
  tls-cert  tls-key  view-only
```

`set-port` exists. `set-bind-address` does not, and neither does any
gsettings key for it — that list is the complete schema from
`/usr/share/glib-2.0/schemas/org.gnome.desktop.remote-desktop.gschema.xml`.
The daemon binds the wildcard.

A wildcard bind on this box means **:3389 is reachable from the LAN**, on
both of its LAN addresses:

| Interface | Address |
|---|---|
| `enp31s0` | `192.168.88.11` |
| `wlp30s0` | `192.168.88.13` |

That is a genuine deviation from `AGENTS.md`'s "services bind to
`127.0.0.1` only", and it is written here in full rather than buried
because a future reader who finds `:3389` on `0.0.0.0` deserves to know
it was seen, understood, and handled — not missed.

**What stands between the LAN and a session:**

- **The packet filter below.** This is the real answer, and `setup.sh`
  installs it *before* it enables RDP, so there is never a window in which
  the port answers the LAN. If the filter cannot be installed, the deploy
  **dies without enabling RDP** rather than proceeding — it fails closed.
- TLS on the RDP connection itself (a self-signed cert this deploy
  generates).
- RDP credentials, set via `grdctl --system rdp set-credentials`.
  ⚠️ These are **almost certainly `RDP_USER`'s real system login
  password**, not a separate generated secret — GNOME's Remote Login hands
  them to GDM to start a genuine session. See
  [Where the credential lives](#why-there-is-a-password-at-all). Treat
  that as a reason to rely on the filter, not on the password.

**What does not:** the tailnet. The tailnet boundary is doing no work
whatsoever on port 3389.

**The mitigation, and how to check it is real.** A wildcard listener
cannot be un-wildcarded from GNOME's side, so the constraint has to come
from the packet filter. `setup.sh` installs a host rule that **accepts
:3389 only from loopback and the compose bridge subnet** (`GUAC_SUBNET`,
default `172.28.0.0/24`) and answers everything else with a TCP reset.

It lives in an nftables table of its own (`inet remote_desktop`), applied
by its own systemd unit (`remote-desktop-firewall.service`) ordered
`Before=gnome-remote-desktop.service`. Three consequences worth knowing:
docker's and ufw's rulesets are never touched; the filter is re-applied on
every boot before anything can listen; and removing it is two clean
commands rather than rule-handle surgery.

A reset rather than a silent drop is also deliberate — a reset is exactly
what a *closed* port sends, so a scanner cannot tell RDP is running, and
the deploy's own probes get a clean refusal instead of hanging until they
time out.

That shape — allow-one-source, deny-the-rest — is the right one, and
notably better than the obvious alternative of dropping :3389 on the two
LAN interfaces by name:

- an interface-named rule has to enumerate every interface, and this box
  has two LAN addresses; adding a third (a USB dock, a VPN, a bridge)
  silently re-opens the hole;
- it also cannot be verified from this machine, because Linux routes
  traffic addressed to the host's own LAN IP over `lo`, so a local probe
  never hits an inbound interface rule and always appears open.

The subnet-allow rule has neither problem: a probe from this box to any
address other than the bridge is genuinely dropped, so **the live suite's
probes are conclusive** rather than merely suggestive.

The rule is sudo-gated, and a sudo call that silently no-ops is exactly
how a mitigation becomes a comment. **Verify it rather than trusting
it:**

```bash
cd ~/dev/setup-server/services/remote-desktop && ./tests/run-tests.sh --live
```

The live suite opens a real TCP connection to `:3389` on `100.77.77.77`,
`192.168.88.11` and `192.168.88.13` and requires all three to be refused.
It does the same for `:8094`, and it separately requires that the bridge
gateway `172.28.0.1:3389` *does* answer — because a filter written too
broadly blocks guacd along with the LAN, and that failure reads like a
dead backend rather than a firewall. A red line in either direction is not
a test being fussy.

⚠️ **None of this has ever been observed.** Installing the filter needs
`sudo`, which needs a password, and the session that built this service
was non-interactive — so the mitigation has never been applied and the
probes above have never been seen to pass. `setup.sh` verifies them itself
on the first real deploy and fails the run if any of them is wrong. Until
someone runs it, the correct mental model is "designed to be closed, not
yet demonstrated closed".

### D1: why guacd talking to the bridge gateway is *not* a fourth violation

`PLAN.md`'s decision D1 worried at length about how a bridge-networked
`guacd` reaches an RDP daemon on the host. A future reader will look at
`GUAC_RDP_HOST` in `.env`, see something like `172.28.0.1` rather than
`127.0.0.1`, and reasonably suspect a violation. It is not one, and here
is the reasoning, because a comment saying "this is fine" convinces
nobody:

- A compose bridge's gateway address is an address **on the host**,
  created by the Docker daemon on a `br-*` interface, existing only in
  this machine's own routing table.
- Nothing off-box routes to it. It is not advertised to the LAN, not on
  the tailnet, and not in any peer's routing table. A packet from
  `192.168.88.x` addressed to `172.28.0.1` has nowhere to go.
- Reaching it requires already being either on this host or in a
  container attached to that specific bridge.

So the bridge gateway is host-internal in exactly the way `127.0.0.1` is
host-internal, and pointing guacd at it honours the *intent* of the
loopback rule even though it is not literally loopback. The compose
subnet is pinned rather than left to Docker's allocator so that the
address in `.env` stays true across restarts.

⚠️ Note the ordering of the two facts above. The bridge-gateway hop is
safe **on its own terms**. It is not what makes :3389 exposed — the
wildcard bind is, and that is a separate problem with a separate
mitigation. Do not let "the gateway is fine" quietly stand in for "3389
is fine".

⚠️ Subnet choice: `172.17.0.0/16` through `172.27.0.0/16` are **all
already allocated** to existing Docker bridges on this box (measured
2026-09-11 — immich, seafile, home-assistant and friends). Pick outside
that range or compose will fail to create the network.

### Why there is a password at all

Guacamole has **no supported anonymous mode.** Not "we chose to add
auth" — there is no configuration in which the webapp serves a session
without a login. Every other service in this repo that has a password
has one because the software insists; `code-server` has none precisely
because it does not insist, and the tailnet is the auth layer.

So: this is **auth-by-necessity, not auth-as-a-substitute-for-the
tailnet.** The distinction matters because the repo rule says not to add
password auth as a substitute for the tailnet boundary *without being
asked*, and a future reader should not read this login prompt as a
precedent for adding one elsewhere.

Practically it is also not nothing: the webapp is the only thing standing
between a tailnet peer and an unauthenticated guacd, so a credential in
front of it is load-bearing regardless of the philosophy.

**Where the credential lives:**

| Secret | Where |
|---|---|
| Guacamole browser login (`GUAC_USER` / `GUAC_PASSWORD`) | `services/remote-desktop/.env`, mode 600, gitignored. Generated. |
| ...as stored by Guacamole | an **unsalted** SHA-256 hash in `~/services/remote-desktop/guac-home/user-mapping.xml` |
| RDP credentials (`RDP_USER` / `RDP_PASSWORD`) | `services/remote-desktop/.env`, **in plaintext** in `user-mapping.xml`, and in the system daemon's store via `grdctl --system rdp set-credentials` |

Both are recorded in `DIRECTORY.md` → *Credentials & auth*. The
password-sync rule applies: if you change the Guacamole password by
hand-editing `user-mapping.xml`, mirror it back into `.env`, or the next
`setup.sh` run and the tests will disagree with reality.

Three things about that table deserve saying plainly rather than being
left to be discovered.

**The browser hash is unsalted.** Not a shortcut — `guacamole-auth-file`
supports `encoding="sha256"` and `encoding="md5"` and nothing else. There
is no salt attribute to set. So the hash is offline-crackable by anyone who
can read the file, which is one more reason the file is `0600` and its
directory `0700`, and a reason not to reuse `GUAC_PASSWORD` anywhere else.
It is generated by `openssl rand -hex 16`, so it is not in any wordlist.

⚠️ **The RDP password is stored in plaintext, and it is probably your
login password.** Two unavoidable facts collide here:

- Guacamole cannot hash it. It has to *replay* the password to the RDP
  server to authenticate on your behalf, so it must hold the original.
- GNOME's Remote Login hands the credentials to **GDM**, which starts a
  real login session. So the password that works is one the system already
  accepts — in all likelihood `RDP_USER`'s actual account password.

That means a plaintext copy of a system login password sits in two
owner-only files (`.env` and `user-mapping.xml`). `setup.sh` will not
invent one, and says so before prompting. **If that is not acceptable to
you — and it is a reasonable thing to refuse — make a second account for
remote sessions and point `RDP_USER` at it.** That account still gets a
real desktop; it just is not the account whose password also unlocks
`sudo`.

⚠️ Whether a *generated* password can work instead was **not verified** —
it needs `sudo grdctl --system`, which needs a password this session never
had. If you find that Remote Login accepts an arbitrary credential pair
independent of the system account, that is a better answer than the above
and this file should be corrected to say so.

### Session recording is off

Guacamole can record every session to disk. It is off, and
`recordings/` is not created.

The reason is not privacy, it is operational: recordings are large,
they grow without bound, and **there is no backup job behind that
directory** — nothing on this box would notice it filling the disk until
something else failed. A feature that silently consumes an unbounded
resource with no monitor on it is a liability, not a feature. Turn it on
deliberately, with a retention story, or not at all.

## What was verified, and what was not

This service was specified and built in a session where **`sudo`
required a password and the session was non-interactive.** That is not a
footnote; it means a large part of the design below is reasoned rather
than observed. Read the second table before trusting anything in it.

**Verified — measured on this box:**

| Fact | Evidence |
|---|---|
| GNOME Shell 46.0, Ubuntu 24.04.4, `graphical.target` | `gnome-shell --version`, `systemctl get-default` |
| `gnome-remote-desktop` 46.3-0ubuntu1.2 installed | `dpkg-query -W` |
| its service active + enabled, up ~1 week, PID 922 | `systemctl is-active` / `is-enabled` |
| its idle cost: **812 KB** current, 12.8 MB peak | `systemctl show -p MemoryCurrent -p MemoryPeak` |
| `grdctl` supports `--system` and `--headless` | `grdctl --help` |
| **no bind-address knob exists** (the finding above) | `grdctl --help` + the full gsettings schema |
| resident GNOME/gdm stack: ~174 MB (login screen only) | `ps -eo rss,comm` |
| 8094, 3389, 4822 all free; 8094 unclaimed by serve | `ss -ltn`, `tailscale serve status` |
| `172.17`–`172.27` all taken by existing docker bridges | `ip -4 -o addr` |
| both image tags already pulled locally | `docker images` — guacd 377 MB, guacamole 1.12 GB |
| two LAN addresses, not one | `ip -4 -o addr` |

**NOT verified — do not repeat these as facts:**

| Claim | Status |
|---|---|
| `grdctl --system status` output | **never run** — needs polkit auth |
| `/var/lib/gnome-remote-desktop/` contents | **never read** — root-only |
| that headless `--system` Remote Login actually spawns a session as `kaichen` on *this* box | **unproven.** It is the documented purpose of those flags and the binary carries them. That is the strength of the evidence and no more. |
| that any RDP session was ever established | **no.** None was. |
| RAM cost of a *connected* session | **an estimate** (~700 MB–1 GB for GNOME), not a measurement |
| that the :3389 firewall mitigation installs cleanly | **unproven** — sudo-gated |
| that a Mac browser completes the handshake end to end | **unproven** — nobody has connected |
| any macOS-side path in this document | portable by construction; **not run on a Mac** |

The first real deploy is what tests all of this. If the GNOME backend
does not come up, that is a foreseen outcome and the fallback is
documented: `TROUBLESHOOT.md` → *The xrdp + XFCE fallback*, with the
exact package list and the polkit rule.

## Why gnome-remote-desktop and not xrdp

`PLAN.md` assumed xrdp + XFCE and deferred the choice (D2) to a human.
The human said to decide it empirically. The measurements above decided
it:

- xrdp + XFCE is ~400 MB of new packages and a **second** desktop
  environment on a box with 2.6 GB available and 1.9 GB of swap already
  in use.
- It would replace a daemon that is already installed, already enabled,
  already running, and idling at **under a megabyte**.
- `--headless` and `--system` — the capability the whole question turned
  on — both exist in this build.

The cost argument holds regardless of whether the GNOME backend proves
out in practice, which is why the fallback stays documented rather than
deleted.

## RAM

This service breaks `EXPLORATION.md`'s "keep new always-on services in
the tens-of-MB class" rule, and it is worth being precise about by how
much.

| Component | Cost | `mem_limit` | Provenance |
|---|---|---|---|
| `gnome-remote-desktop` daemon, idle | **812 KB** | n/a (host daemon) | measured here, from the cgroup |
| ...its peak since boot | 12.8 MB | n/a | measured here |
| `guacd` container, idle | ~11 MiB | 512m | reported by the deploy side; **not reproduced in this suite** |
| `guacamole` webapp (Tomcat JVM), idle | ~164 MiB | 1g | reported by the deploy side; **not reproduced in this suite** |
| **both containers, idle** | **~175 MiB** | — | as above |
| **a connected GNOME session** | **~700 MB – 1 GB** | none | ⚠️ **ESTIMATE. Nobody has ever connected. Not a measurement.** |

Two different confidence levels in that table, deliberately separated. The
daemon rows were measured on this box with
`systemctl show gnome-remote-desktop -p MemoryCurrent -p MemoryPeak`. The
container rows come from the deploy side and **were not reproduced by the
test suite**, which never starts a container — verifying them would mean
running the deploy, which has not happened. Treat them as good-faith
figures pending a real `docker stats`.

Both containers carry `mem_limit` (512m / 1g), so the container half cannot
run away even if a leak appears. The limits are a blast radius, not a
target. The session half is bounded by nothing except GNOME's own
appetite, and that figure is inference from what GNOME sessions usually
cost — **replace it with a real number the first time somebody connects
and runs `free -m` before and after.**

Box context, measured 2026-09-11: 7.7 GB total, ~2.6 GB available, 1.9 GB
of swap already in use, and ollama claims ~5 GB the moment a model loads.
Kai has said explicitly that services **do not have to stay running**.
This is a good candidate to stop when idle:

```bash
cd ~/dev/setup-server/services/remote-desktop
docker compose --project-directory . stop     # frees the container half
docker compose --project-directory . start
```

## Dependencies

| Needs | Why | Notes |
|---|---|---|
| Linux | this service operates *this host's* desktop | **Dies on Darwin.** A Mac cannot host this box's session; the preflight refuses rather than half-working. |
| `docker` + compose v2 | the two containers | user must be in the `docker` group |
| `tailscale` | publishing | must be `Running` |
| `sudo` | `grdctl --system`, and the :3389 firewall rule | **first run only** — see below |
| `gnome-remote-desktop` | the RDP backend | already installed on this box |
| `curl`, `openssl` | health check, password + hash generation | |

### The sudo deviation

Every other service here is a container or a user unit that touches
nothing outside `$HOME`. This one configures a **system** daemon, so it
needs `sudo` on a run that changes backend state. That is a real
deviation and it is documented in this service's `AGENTS.md` so a future
agent does not "fix" it.

The rule it must still obey: **a re-run with everything already
configured needs no sudo at all.** The script checks state first and acts
only on drift; if you find yourself typing a password on every run,
that is a bug, not the design. The mocked suite asserts it — an
idempotent re-run must invoke zero `sudo` and zero package installs.

## Using it from a Mac

No client to install. That is the entire point of choosing Guacamole.

1. The Mac must be on the tailnet. `tailscale status` should list
   `homeserver`.
2. Open **`https://homeserver.tail-name.ts.net:8094`** in any
   browser. The certificate is a real one, minted by Tailscale — no
   warning to click through. On a brand-new port the first request can
   take up to ~60 s while the cert is issued; that is not a failure.
3. Log in with `GUAC_USER` / `GUAC_PASSWORD` from
   `services/remote-desktop/.env`.
4. You land in the session directly — one connection is defined, so
   Guacamole opens it rather than showing a chooser.

Things worth knowing once you are in:

- **The Guacamole menu is `Ctrl` + `Alt` + `Shift`.** On a Mac that is
  the actual `control` key, not `cmd`. This opens the side panel with
  the clipboard, zoom, keyboard settings and the disconnect button.
  Without it you cannot paste, and it is the single most common "how do I…".
- **Clipboard** is not the system clipboard. Text goes through the panel's
  clipboard box in both directions. This is a browser sandbox limitation,
  not a Guacamole one.
- ⚠️ **There is no file transfer.** See below.
- **Keyboard**: `cmd` does not map to `super`. Expect to reach for
  `ctrl` where macOS muscle memory wants `cmd`.
- **Wallpaper is disabled** in the connection settings, on purpose —
  it is pure bandwidth for zero information.

⚠️ **Do not expect a native RDP client to work, and do not "fix" it so it
does.** Microsoft Remote Desktop pointed at `100.77.77.77:3389` is the
obvious thing to reach for, and the packet filter deliberately refuses
it: :3389 accepts connections **only from the compose bridge subnet**,
i.e. only from guacd. That is what turns an un-constrainable wildcard
listener back into something with one door.

Opening 3389 to the tailnet would mean a second, weaker front door —
guarded by the RDP credentials alone, bypassing Guacamole entirely — and
it re-opens the LAN exposure unless the rule is written very carefully.
The live suite asserts :3389 refuses on the tailnet address for exactly
this reason. If you genuinely want a native client, that is a design
change to make deliberately and document here, not a rule to loosen in
passing.

### No file transfer

Guacamole's side panel normally offers a file browser, backed by RDP drive
redirection. **It does not work here, and the deploy does not pretend to
offer it.**

`gnome-remote-desktop` does not implement the `rdpdr` channel. Guacamole's
`enable-drive` parameter would be accepted, the directory would be
created, and nothing would ever appear in it — a switch that does
nothing, which is worse than an absent feature because it wastes an
afternoon.

This is a genuine cost of decision D2, and the one place where the xrdp
path was better: xrdp does implement `rdpdr`. It was not worth ~400 MB and
a second desktop environment, but it is worth knowing you traded it away.
⚠️ Note that `PLAN.md` step 6 specifies `enable-drive` and a bind-mounted
`drive-path` — written for the xrdp assumption, and now wrong. The test
suite asserts both the parameter and the `drive/` directory stay absent,
so this cannot be quietly "fixed" back in.

Move files by some other route, all of which already exist on this box:

| Want | Use |
|---|---|
| Edit code on the server | code-server at `:443` |
| Sync a folder both ways | Seafile at `:8443` |
| One-off copy | `scp` / `rsync` over the tailnet |

**Clipboard does work** (via the `Ctrl`+`Alt`+`Shift` panel), which covers
most of what people actually reach for file transfer to do.

## Ops

```bash
cd ~/dev/setup-server/services/remote-desktop

# state
docker compose --project-directory . ps
docker compose --project-directory . logs --tail=50 guacd
docker compose --project-directory . logs --tail=50 guacamole

# the health check that means something (markup, not a 200). These are the
# two markers setup.sh asserts; both are on the opening <html> tag of the
# index.html shipped inside guacamole/guacamole:1.6.0.
curl -s http://127.0.0.1:8094/guacamole/ | grep -c 'ng-app="index"'
#   1 = Guacamole is really there.  0 = something else answered with a 200.

# the backend
systemctl is-active gnome-remote-desktop
sudo grdctl --system status              # ⚠️ needs a password; never run here

# the packet filter that keeps :3389 off the LAN — see the security model
systemctl is-active remote-desktop-firewall.service
sudo nft list table inet remote_desktop
ss -ltn | grep 3389                      # 0.0.0.0:3389 is EXPECTED, see below

# publish
tailscale serve status | grep -A2 ':8094'

# stop / start (this is a fine thing to leave stopped)
docker compose --project-directory . stop
docker compose --project-directory . start

# everything at once
./tests/run-tests.sh            # mocked, touches nothing
./tests/run-tests.sh --live     # the real deployment, incl. the :3389 probes
```

If `docker` says "permission denied", the shell predates your docker
group membership:

```bash
sg docker -c './tests/run-tests.sh --live'
```

## Removal

```bash
cd ~/dev/setup-server/services/remote-desktop
./teardown.sh                    # Remove: Serve :8094 off + compose down; state, .env and the system half kept
./teardown.sh --system           # from a terminal: ALSO RDP off, verify :3389 closed, THEN the filter + keypair (sudo)
./teardown.sh --purge            # ALSO delete GUAC_STATE and .env (asks you to type remote-desktop)
```

The launcher's Remove runs `./teardown.sh` with no flags: no sudo, so the
gnome-remote-desktop Remote Login config, the `inet remote_desktop` nftables
table and the RDP keypair stay, and the script prints exactly that list
with the commands to back it out. Nothing is exposed meanwhile: the filter
keeps guarding the wildcard listener. `--system` is the terminal-only way
to remove that half, and it never drops the filter while :3389 still
answers. By hand, the equivalent of the default is:

```bash
docker compose --project-directory . down
tailscale serve --https=8094 off      # ⚠️ NOT `tailscale serve reset`
```

⚠️ `tailscale serve reset` clears **every** mapping on this node —
code-server, Seafile, Immich, AdGuard, Home Assistant and the rest. `off`
on the single port is the only correct removal. See `TROUBLESHOOT.md` →
*Rollback and nuke-and-pave* for the full recipe, including backing the
RDP backend and the firewall rule out.

Note that `gnome-remote-desktop` was **already installed and running**
before this service existed — removing this service should not remove it,
only undo the configuration `setup.sh` applied.
