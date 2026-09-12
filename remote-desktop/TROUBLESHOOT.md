# remote-desktop — Troubleshooting

⚠️ **Two things on this box are not recoverable over a tailnet.** Before
you run anything from this page:

- **Do not reconfigure GDM or the graphical target.** A broken display
  manager cannot be fixed from a remote shell that depends on it, and
  Kai uses this machine physically. Nothing in this document asks you to,
  and if a Stack Overflow answer does, stop.
- **Never `tailscale serve reset`.** It clears *every* mapping on this
  node — code-server, Seafile, Immich, AdGuard, Home Assistant, all of
  them. The single-port removal is `tailscale serve --https=8094 off`.

Triage in layers, from the inside out. Work down the row that fails
first; a failure at an inner layer makes every outer symptom
uninterpretable.

```
session?          RDP backend?         guacd?          webapp?             serve?            client?
is there a         :3389 answering      can it reach    :8094 serving       mapping there?    browser/Mac
GNOME session      with TLS?            the backend?    real markup?
to attach to?
```

```bash
cd ~/dev/setup-server/remote-desktop

systemctl is-active gnome-remote-desktop                     # backend daemon
ss -ltn | grep 3389                                          # is it listening, and WHERE
docker compose --project-directory . ps                      # both containers up?
docker compose --project-directory . logs --tail=40 guacd    # guacd's view of the backend
curl -s http://127.0.0.1:8094/guacamole/ | head -5           # real markup, not a 200
tailscale serve status | grep -A2 ':8094'                    # published?
./tests/run-tests.sh --live                                  # all of the above at once
```

If `docker` says "permission denied", the shell predates your docker
group membership — that is not an outage:

```bash
sg docker -c './tests/run-tests.sh --live'
```

---

## ⚠️ First: is :3389 open to the LAN?

This is the one check to run even when nothing appears broken, because
the failure is silent. `gnome-remote-desktop` **cannot be told which
address to bind** — see `SETUP.md` → *The security model* for the
measured evidence — so it listens on the wildcard, and the only thing
constraining it is a packet-filter rule that `setup.sh` installs under
sudo. A sudo call that no-ops leaves you with a wide-open RDP port and no
error message anywhere.

```bash
ss -ltn | grep 3389
# 0.0.0.0:3389 — expected, and NOT itself the problem. The wildcard bind
# is unavoidable; what matters is what the packet filter does with it.

# The real question: can anything but guacd reach it?
nc -vz 192.168.88.11 3389     # LAN, wired      ─┐
nc -vz 192.168.88.13 3389     # LAN, wireless    ├─ all three must REFUSE
nc -vz 100.85.87.87  3389     # tailnet         ─┘
nc -vz 172.28.0.1    3389     # bridge gateway  ─── this one must SUCCEED
```

The rule `setup.sh` installs accepts :3389 **only from the compose bridge
subnet** (`GUAC_SUBNET`, default `172.28.0.0/24`) and drops it from
everywhere else. Two consequences worth internalising:

- **These probes are conclusive from this box.** A rule that instead
  dropped :3389 on the LAN interfaces *by name* would be invisible to a
  local probe — Linux routes traffic addressed to the host's own LAN
  address over `lo`, so it never hits an inbound interface rule, and the
  port would look open here while genuinely being closed from outside.
  Because this rule matches on **source address**, a local probe is
  dropped like any other and a refusal means what it says.
- **The fourth probe matters as much as the first three.** If the bridge
  gateway is refused too, the rule is too broad and the mitigation has
  broken the service — see
  [Layer 3](#layer-3--guacd-cannot-reach-the-backend). "Secure" and
  "working" can trade places here without anyone noticing, which is why
  both directions are asserted.

Two LAN addresses, not one: this box has `enp31s0` 192.168.88.11 **and**
`wlp30s0` 192.168.88.13. Any interface-based reasoning has to cover both;
source-based reasoning covers them for free, which is the other argument
for the rule's shape.

`./tests/run-tests.sh --live` runs all four probes and interprets them.

**If it is reachable:** the firewall rule is missing or was applied to
the wrong interface. Re-run `./setup.sh` and watch for the sudo prompt
and its result — the script announces what it is about to change before
prompting. If the rule genuinely cannot be installed, understand your
actual posture: RDP is protected by credentials and TLS, on your LAN.
That is a defensible home-network trade; it is not "tailnet-only", and
`SETUP.md` says so.

---

## Layer 1 — the session

### Black screen, or the session closes a second after connecting

The signature failure of the GNOME backend, and the one this deployment
is most likely to hit, because **nobody has ever completed a session on
this box.** `SETUP.md` → *What was verified, and what was not* is blunt
about it: `--headless --system` is documented to spawn a new session for
the connecting user, the binary carries the flags, and that is the whole
of the evidence.

Distinguish three shapes:

| Symptom | Likely layer |
|---|---|
| Guacamole shows "connecting", then disconnects immediately | RDP handshake — layer 2, not the session |
| You get a **grey/blue screen with a cursor** and nothing else | the session started and then died, or has no shell |
| You get GDM's **login screen** rather than a desktop | the backend attached to the greeter's seat instead of starting a new session |

For the third: that is the `--headless` question. A backend configured
per-user rather than `--system`, or `--system` without headless
credentials, can end up mirroring seat0 — which currently shows the GDM
greeter, because **no user is logged in graphically on this box**. Check
what the daemon thinks it is doing:

```bash
sudo grdctl --system status --show-credentials   # ⚠️ needs a password
loginctl list-sessions                           # is there a session at all?
journalctl -u gnome-remote-desktop -n 60 --no-pager
```

⚠️ `grdctl --system status` has **never been run on this box** (it needs
polkit auth and the session that built this was non-interactive). Its
output is the first thing to look at and also the first thing nobody has
seen. Do not be surprised if it says something this document does not
predict.

For a session that starts and dies, the journal is where it says why:

```bash
journalctl -u gnome-remote-desktop -n 100 --no-pager | grep -iE 'error|fail|session'
journalctl _COMM=gnome-shell -n 60 --no-pager
```

**If the GNOME backend cannot be made to work at all**, that is a
foreseen outcome, not a dead end. Skip to
[The xrdp + XFCE fallback](#the-xrdp--xfce-fallback). It was plan A in
`PLAN.md` and lost on cost, not on capability.

### The session works but everything is desperately slow

- Check swap. The box runs with ~1.9 GB of swap already in use before
  this service exists, and a connected GNOME session is estimated at
  700 MB–1 GB. `free -m` before and after connecting — and please write
  the real number into `SETUP.md`, which currently carries an estimate.
- If ollama has a model loaded it is holding ~5 GB. Those two do not fit
  together comfortably. Stopping one is a legitimate answer.
- Wallpaper should already be off in the connection settings. Confirm
  `enable-wallpaper` is `false` in `user-mapping.xml`.

---

## Layer 2 — the RDP backend

### `ss` shows nothing on 3389

```bash
systemctl is-active gnome-remote-desktop     # active?
systemctl is-enabled gnome-remote-desktop    # enabled?
journalctl -u gnome-remote-desktop -n 40 --no-pager
```

The daemon runs as the `gnome-remote-desktop` system user with
`Restart=on-failure` and is `WantedBy=graphical.target`. Two consequences
worth knowing:

- It only comes up once the graphical target does. If the box booted to
  `multi-user.target` for any reason, there is no RDP.
- `Restart=on-failure` means a clean exit does **not** restart it. A
  daemon that decided it had nothing to do stays down silently.

If it is active but not listening, the RDP backend is probably not
*enabled* — the daemon runs with RDP switched off by default:

```bash
sudo grdctl --system status        # ⚠️ needs a password
sudo grdctl --system rdp enable    # what setup.sh does
```

⚠️ `negotiate-port` defaults to `true`, which means **if 3389 is taken
the daemon quietly listens somewhere else** rather than failing. If
`ss -ltn | grep 3389` is empty but the daemon is happy, look for it on a
neighbouring port:

```bash
ss -ltnp 2>/dev/null | grep -i gnome-remote
```

A backend on 3390 with `GUAC_RDP_HOST` pointing at 3389 fails as
"connection refused", which reads like the backend is down when it is
not.

### It listens, but the handshake fails

The Guacamole error is usually one of:

| Guacamole says | Means |
|---|---|
| "Connection error" / immediate disconnect | TCP got there, RDP negotiation failed — TLS or credentials |
| "The remote desktop server is currently unreachable" | TCP never got there — layer 3 below |
| "Authentication failure" from the *desktop*, after Guacamole logged in | the RDP credentials in `user-mapping.xml` are wrong |

Credential confusion is the common one, and it is worth stating flatly:
**there are two separate passwords.** The Guacamole login
(`GUAC_PASSWORD`) gets you to the connection. The RDP credentials get the
connection into the desktop. They are unrelated, and neither is your Unix
password.

```bash
grep -E 'GUAC_(USER|PASSWORD)|RDP' ~/dev/setup-server/remote-desktop/.env
sudo grdctl --system status --show-credentials    # what the backend expects
```

If they disagree, `.env` is the source of truth for the deploy — re-run
`./setup.sh`, or set the backend side by hand:

```bash
sudo grdctl --system set-credentials <user> <password>
sudo systemctl restart gnome-remote-desktop
```

**"Log in failed. Please reconnect and try again." in the browser, before
you ever typed an RDP password.** This is a security-mode mismatch, not a
credentials problem, and it was the very first failure of the very first
real session on this box. The two sides say it plainly:

```
docker logs guacd                      -> Security mode: TLS
                                          RDP server closed/refused connection:
                                          Security negotiation failed (wrong security type?)
journalctl -u gnome-remote-desktop     -> server supports only NLA Security
                                          Protocol security negotiation failed, disconnecting.
```

gnome-remote-desktop accepts **NLA only**. The connection in
`user-mapping.xml` must carry `security=nla` (setup.sh writes that; an
older version wrote `tls`, which is what produced the above) and
`ignore-cert=true`, because the backend presents the self-signed
certificate setup.sh generated. **A mapping from that older version is
repaired by re-running `./setup.sh`**: it rewrites exactly `security=tls`
to `nla`, adds `disable-audio=true` if the param is missing, leaves every
other line alone, and restarts the webapp (Guacamole caches connection
parameters at login, so without the restart the fix only reaches sessions
that log in afterwards). A hand-chosen mode such as `any` is not touched.
If the file is damaged beyond that, use the rm-and-rerun recipe under
[the reliable fix](#the-reliable-fix) below. `ignore-cert=false` fails at exactly the
same point as bad credentials, which is why this is worth checking before
assuming a password problem.

**The session authenticates, the desktop starts to paint, and then it drops.** Check the *handover* daemon, not the system one -- after login GNOME redirects the client to a per-user daemon and the failure lands there:

```bash
journalctl --user -u gnome-remote-desktop-handover.service -n 30
```

If it says `[RDP.AUDIO_PLAYBACK] Client protocol version (6) too old. Terminating protocol`, that is guacd's FreeRDP 2.11.7 negotiating an audio-playback version this server refuses. The connection needs `disable-audio=true` (setup.sh writes it). There is no audio over this connection until guacd ships FreeRDP 3.x; that is a known cost, not a misconfiguration.

⚠️ Editing `user-mapping.xml` is not enough on its own once someone is
logged in: Guacamole resolves the connection parameters at **login** and
caches them in the session, so the browser's automatic reconnect keeps
using the old ones. Either log out and back in, or
`docker restart guacamole`.

---

## Layer 3 — guacd cannot reach the backend

**This is the D1 failure**, and the one to expect after any change to the
compose network. The symptom in the browser is
*"The remote desktop server is currently unreachable"*; the symptom in
the logs is a connection refused or timed out from inside a container.

```bash
docker compose --project-directory . logs --tail=40 guacd
```

The cause is nearly always that `GUAC_RDP_HOST` no longer names an
address guacd can route to. Check what it says, then check that address
exists on the host:

```bash
grep GUAC_RDP_HOST ~/dev/setup-server/remote-desktop/.env
ip -4 -o addr | grep "$(sed -n 's/^GUAC_RDP_HOST=//p' ~/dev/setup-server/remote-desktop/.env)"
```

Then prove reachability **from inside the container**, which is the only
place the question is actually asked:

```bash
docker compose --project-directory . exec guacd \
  sh -c 'command -v nc >/dev/null && nc -vz '"$(sed -n 's/^GUAC_RDP_HOST=//p' .env)"' 3389 \
         || cat < /dev/null > /dev/tcp/'"$(sed -n 's/^GUAC_RDP_HOST=//p' .env)"'/3389 && echo open'
```

Things that break it:

- **`127.0.0.1` in `GUAC_RDP_HOST`.** Inside a bridge container that is
  the *container's* loopback, where nothing is listening. It is the
  natural value and it is always wrong here. This is the entire content
  of decision D1.
- **`GUAC_SUBNET` and `GUAC_RDP_HOST` disagree.** These two are a matched
  pair — the gateway must be the `.1` of the subnet, and the firewall
  rule allows that subnet and nothing else. Change one without the other
  and guacd's packets arrive from a source the rule does not permit,
  which looks exactly like a dead backend:

  ```bash
  grep -E '^GUAC_(SUBNET|RDP_HOST)=' ~/dev/setup-server/remote-desktop/.env
  docker network inspect remote-desktop -f '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}}'
  ```

- **The compose network was recreated and the gateway moved.** The subnet
  is pinned in `docker-compose.yml` (`GUAC_SUBNET`, default
  `172.28.0.0/24`) precisely so this cannot happen — if it is unpinned,
  Docker's allocator picks a different one after a `down` and `.env`
  still names the old gateway.
- **A subnet collision.** `172.17.0.0/16` through `172.27.0.0/16` are all
  already in use on this box by other services' bridges. If `compose up`
  fails with "Pool overlaps with other one on this address space", that
  is this. `172.28.0.0/24` is the default for that reason; move further
  out or to a 10.x range if it ever collides too.
- **The firewall rule was written too broadly** and is dropping the
  bridge traffic as well as everything else. This is the failure mode
  where fixing the security problem breaks the service, and it is the
  more likely of the two mistakes. The correct rule **accepts** :3389
  from `GUAC_SUBNET` and drops it otherwise; a blanket
  `tcp dport 3389 drop` takes guacd out with the LAN.

The quick discriminator, because a too-broad rule and a dead backend look
identical from the browser:

```bash
nc -vz 172.28.0.1 3389      # the bridge gateway — MUST succeed
nc -vz 192.168.88.11 3389   # the LAN — must be refused
```

Gateway refused *and* backend up (`ss -ltn | grep 3389` shows
`0.0.0.0:3389`) is conclusively the firewall, not the backend. To read
the rule itself:

```bash
sudo nft list ruleset 2>/dev/null | grep -B2 -A3 3389   # ⚠️ needs a password
sudo iptables -S | grep 3389
```

### guacd itself

```bash
docker compose --project-directory . ps guacd
docker inspect -f '{{.State.Status}} {{.Config.Image}}' <guacd container>
```

The image must be pinned at `guacamole/guacd:1.6.0`. **Never `:latest`** —
1.6.0 is the release that fixed CVE-2024-35164, and floating the tag also
risks landing on a build where RDP is compiled against FreeRDP 3, which
Guacamole only supports experimentally.

⚠️ **guacd must not be published to the host.** If `ss -ltn | grep 4822`
shows anything, remove the `ports:` entry immediately. guacd does not
authenticate its callers — anything that can reach 4822 can drive an RDP
session to any host with any credentials. The webapp is the
authenticator; exposing guacd routes around it entirely.

---

## Layer 4 — the Guacamole webapp

### Login is rejected but you are sure the password is right

Almost always a malformed `user-mapping.xml`, and Guacamole's response to
a broken file is not an error — it is **an empty user list**, i.e. every
login fails with the same "Invalid login" as a wrong password. Silent by
design, maddening in practice.

```bash
docker compose --project-directory . logs --tail=40 guacamole | grep -i 'user-mapping\|authenticat'
```

Look for `Read user mapping file` (good) versus a parse warning or
nothing at all (bad). Then check the file itself:

```bash
xmllint --noout ~/services/remote-desktop/guac-home/user-mapping.xml && echo "XML is well-formed"
grep -o 'encoding="[^"]*"' ~/services/remote-desktop/guac-home/user-mapping.xml
```

⚠️ **The hash is plain, unsalted SHA-256 of the password — there is no
salt.** `guacamole-auth-file` supports `encoding="sha256"` and
`encoding="md5"` and nothing else; there is no salt attribute to get
wrong. Advice elsewhere describing a `salt` attribute or a
`SHA256(password || salt)` scheme belongs to the *database* auth
extension, not to file auth, and following it here produces a
valid-looking hash that never matches.

So you can check the hash by hand, exactly as `setup.sh` computes it:

```bash
cd ~/dev/setup-server/remote-desktop
printf '%s' "$(sed -n 's/^GUAC_PASSWORD=//p' .env | head -1)" \
  | openssl dgst -sha256 | sed 's/^.*= //'
grep -o 'password="[a-f0-9]*"' ~/services/remote-desktop/guac-home/user-mapping.xml | head -1
```

Those two hex strings must be identical. If they are, the hash is fine and
the problem is elsewhere. The ways it actually goes wrong, in order of
likelihood:

1. **`.env` drifted from the file.** Someone rotated `GUAC_PASSWORD` and
   did not regenerate the XML, or edited the XML by hand. This is the
   common one. `setup.sh` detects it and *warns rather than overwriting*
   (it will not clobber a file you may have edited), so the warning is
   easy to scroll past: look for "does not match GUAC_PASSWORD".
2. **`encoding` attribute missing.** With a hashed password and no
   `encoding="sha256"` on the `<authorize>` element, Guacamole compares
   your plaintext against the hash string and never matches.
3. **Uppercase hex.** `openssl dgst` emits lowercase; some tools emit
   upper. Guacamole's comparison is case-sensitive.

⚠️ Note what is *not* hashed in this file: the **RDP** password, in
`<param name="password">`, is stored in plaintext and cannot be otherwise
— Guacamole has to replay it to the RDP server. That is why the file is
`0600` and its directory `0700`, and why `SETUP.md` recommends a separate
account for remote sessions if that password is also your `sudo` password.

<a name="the-reliable-fix"></a>**The reliable fix** is to let `setup.sh` regenerate the mapping rather
than hand-editing hashes:

```bash
cd ~/dev/setup-server/remote-desktop
cp ~/services/remote-desktop/guac-home/user-mapping.xml /tmp/user-mapping.xml.bak
rm ~/services/remote-desktop/guac-home/user-mapping.xml
./setup.sh                     # writes it only if absent — hence the rm
```

⚠️ That `rm` is why the deploy writes configs only-if-absent: removing
the file is the *documented* way to ask for a regeneration, so keep the
backup until the new one works. A password you set by hand in the web UI
does not exist — file auth has no UI for changing passwords.

Guacamole re-reads `user-mapping.xml` when it changes, but a restart
removes all doubt:

```bash
docker compose --project-directory . restart guacamole
```

### The webapp does not answer at all

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8094/guacamole/
```

- **`000`** — nothing listening. Container down, or Tomcat still
  starting. The JVM takes appreciably longer than the other services in
  this repo; give it 30 s before concluding anything.
- **`404`** — Tomcat is up but the app is not deployed at that path. Note
  the trailing path: the app lives under **`/guacamole/`**, and a bare
  `/` is not the same URL.
- **`200` with the wrong body** — the trap. A 200 proves Tomcat answered,
  not that Guacamole is there. `setup.sh` and the live suite both assert
  real Guacamole markup for this reason:

  ```bash
  curl -s http://127.0.0.1:8094/guacamole/ | grep -i guacamole
  ```

  If that grep is empty, treat the service as down no matter what the
  status code says.

---

## Layer 5 — publish

```bash
tailscale serve status | grep -A2 ':8094'
# expect: proxy http://127.0.0.1:8094
```

- **`Access denied: serve config denied`** — you are not the tailscaled
  operator: `sudo tailscale set --operator=$USER`.
- **An approval URL is printed** — Serve is not enabled for the tailnet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` shows by what.
  Remove just that one mapping:

  ```bash
  tailscale serve --https=8094 off
  ```

  ⚠️ **`off` is the only single-port removal.** `tailscale serve reset`
  clears every mapping on this node and would take code-server, Seafile,
  Immich, AdGuard, n8n, Home Assistant, Jellyfin and the rest down with
  it. `off` is not in `--help`; it is what Tailscale prints itself, and
  it is correct.

- **Loopback works, HTTPS does not** — on a newly-served port the first
  request can take ~60 s while the certificate is minted. Retry before
  debugging:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 90 \
    https://kai-home-server.taild6a23f.ts.net:8094/guacamole/
  ```

---

## Layer 6 — the client

- **Cannot reach the URL at all** — is the Mac on the tailnet?
  `tailscale status` there. This service is tailnet-only by design and
  there is no LAN or public path to the webapp.
- **Cannot paste** — the Guacamole menu is `Ctrl`+`Alt`+`Shift`, using
  the real `control` key, not `cmd`. The clipboard lives in that panel;
  it is not the system clipboard, and it cannot be, in a browser.
- **`cmd` does nothing useful** — it does not map to `super`. Reach for
  `ctrl`.
- **Keyboard layout is wrong** — the RDP connection has a keyboard-layout
  setting in `user-mapping.xml`; a US Mac on a non-US layout is the usual
  mismatch.
- **Mouse cursor doubled or lagging** — a rendering artefact of software
  cursor mode, cosmetic. If latency is genuinely unworkable for the task,
  the native RDP path (Microsoft Remote Desktop to `100.85.87.87:3389`
  over the tailnet, using the *RDP* credentials) skips Guacamole entirely
  and is a better tool for a long session.

---

## The xrdp + XFCE fallback

Still valid, still correct, and no longer plan A. `PLAN.md` specified
xrdp + XFCE; it lost decision D2 on measured cost — roughly 400 MB of
new packages and a second desktop environment, to replace a daemon that
is already installed, enabled, running and idling under a megabyte.

**Take this path if the GNOME backend cannot be made to spawn a
session**, which is a live possibility: nobody has ever completed a
session on this box (`SETUP.md` → *What was verified*). This is the
documented escape hatch, not a defeat.

### Packages

```bash
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11
```

`dbus-x11` is not in `PLAN.md`'s list and belongs there: without it the
XFCE session starts with no session bus, and half the desktop silently
does not work.

### Session and bind address

```bash
# Tell xrdp what to start (write only if absent — this may be yours already)
[ -f ~/.xsession ] || echo startxfce4 > ~/.xsession

# xrdp must read the host TLS key
sudo adduser xrdp ssl-cert
```

The bind address is the one place xrdp is **better** than the GNOME
backend, and it is the reason this fallback improves the security posture
rather than merely restoring it: `xrdp.ini` has an `address=` directive,
so xrdp can be pinned to the compose bridge gateway and never appear on
the LAN at all. That is the D1 "preferred" shape from `PLAN.md`, and with
xrdp it actually works:

```bash
sudo sed -i 's/^address=.*/address=<bridge-gateway>/' /etc/xrdp/xrdp.ini
grep -E '^(address|port)=' /etc/xrdp/xrdp.ini
sudo systemctl enable --now xrdp xrdp-sesman
sudo systemctl restart xrdp
ss -ltn | grep 3389        # should show ONLY the gateway address
```

If you take this path, update `SETUP.md`'s security model: the wildcard
finding and the firewall mitigation both stop applying, and the story
becomes the simple one.

### ⚠️ The polkit colour-manager rule — and a correction to PLAN.md

Without it, every XFCE session over xrdp throws repeating
*"Authentication is required to create a color managed device"* dialogs.
It is the single most common xrdp papercut and it is cheap to prevent.

**`PLAN.md` step 5 offers two locations and one of them does not work on
this box.** Measured 2026-09-11: polkit here is **124**, and
`/etc/polkit-1/localauthority/` **does not exist** — the `.pkla`
local-authority backend was removed in polkit 121. Dropping a `.pkla`
file there would create a directory nobody reads, produce no error, and
change nothing. Use the JS rules directory, which does exist:

```bash
sudo tee /etc/polkit-1/rules.d/49-color-manager.rules >/dev/null <<'EOF'
// Suppress the repeating "Authentication is required to create a color
// managed device" dialog in xrdp/XFCE sessions. Colour-managed device
// creation is a display nicety; on a single-user box the prompt is pure
// noise and it fires on every session start.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0 &&
        subject.local && subject.active && subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
EOF
sudo systemctl restart polkit
```

Verify it took, rather than assuming:

```bash
ls -l /etc/polkit-1/rules.d/49-color-manager.rules
systemctl is-active polkit
journalctl -u polkit -n 20 --no-pager | grep -i error   # a syntax error is logged here
```

A JS syntax error in a rules file makes polkit **ignore the whole file**,
again silently. If the dialogs persist, that journal line is where the
reason is.

### Repointing Guacamole at xrdp

`user-mapping.xml`'s connection needs `security=any` — xrdp does not do
NLA, and `security=nla` fails at the handshake with an error that reads
like bad credentials. Otherwise the connection block is unchanged.

```bash
cd ~/dev/setup-server/remote-desktop
docker compose --project-directory . restart guacamole guacd
```

And turn the GNOME backend's RDP off so the two do not fight over 3389:

```bash
sudo grdctl --system rdp disable
sudo systemctl restart gnome-remote-desktop
```

⚠️ `grdctl --system rdp disable` disables the RDP backend. It does **not**
stop `gnome-remote-desktop.service`, and it must not — leave the unit
alone. It was active before this service existed.

---

## Rollback and nuke-and-pave

⚠️ **Confirm every path before deleting it.** An `rm -rf` of a path that
never existed is a silent no-op that leaves you convinced you started
clean, and then debugging a stale file you thought was gone. An earlier
audit in this repo found exactly that mistake in a TROUBLESHOOT file. The
paths below were checked on 2026-09-11: `~/services` exists;
`~/services/remote-desktop` did **not** exist yet at the time of writing,
which is itself worth knowing — if it is missing, the deploy never ran,
and there is nothing to delete.

### Step 0 — see what is actually there

```bash
cd ~/dev/setup-server/remote-desktop

# Everything this deploy created, in the two places it creates things.
ls -ld ~/services/remote-desktop \
       ~/services/remote-desktop/guac-home \
       ~/services/remote-desktop/.applied
ls -l  ~/services/remote-desktop/guac-home/user-mapping.xml \
       ~/services/remote-desktop/rdp-tls.crt
ls -ld /etc/remote-desktop /etc/systemd/system/remote-desktop-firewall.service
ls -ld /var/lib/gnome-remote-desktop/certificates

grep -E '^(GUAC_(STATE|HOME|PORT|RDP_HOST|SUBNET|USER)|RDP_(PORT|USER))=' .env
```

**`GUAC_STATE` / `GUAC_HOME` in `.env` are the authority, not the paths in
this document.** If the deploy ever ran with them pointing elsewhere,
`~/services/remote-desktop` is not where the data is, and an `rm -rf` of it
is a silent no-op that leaves you convinced you started clean.

Every path above was confirmed to be what `setup.sh` actually creates by
running it in a sandbox (`tests/run-tests.sh`) and listing the result —
not read off the source. `drive/` is deliberately **not** in the list:
this backend has no drive redirection, so it is never created.

### Step 1 — stop and unpublish

```bash
cd ~/dev/setup-server/remote-desktop
docker compose --project-directory . down
tailscale serve --https=8094 off       # ⚠️ NOT `serve reset`
```

That is the whole rollback for the container half, and it is reversible:
`./setup.sh` puts it back.

### Step 2 — back the host changes out

Only if you are removing the service rather than rebuilding it.

```bash
# RDP backend: turn the backend off, do NOT stop or remove the daemon —
# it was installed, enabled and running before this service existed.
sudo grdctl --system rdp disable
sudo grdctl --system clear-credentials
sudo systemctl restart gnome-remote-desktop
ss -ltn | grep 3389        # expect nothing

# The packet filter. It is a systemd unit and a table of its own, so
# removing it is two clean commands — no rule-handle surgery, and nothing
# else's ruleset is involved.
sudo nft list table inet remote_desktop        # look before you delete
sudo systemctl disable --now remote-desktop-firewall.service
sudo rm -rf /etc/remote-desktop
sudo rm -f  /etc/systemd/system/remote-desktop-firewall.service
sudo systemctl daemon-reload

# The RDP TLS keypair (this deploy generated it; nothing else uses it).
sudo rm -f /var/lib/gnome-remote-desktop/certificates/rdp-tls.crt \
           /var/lib/gnome-remote-desktop/certificates/rdp-tls.key
```

⚠️ **Order matters, and this is the one place it really does.** Disabling
the filter while the RDP backend is still enabled puts this box's desktop
on the LAN, because the listener is wildcard-bound and the filter is the
only thing constraining it. Backend off **first**, filter second — as
written above. There is then no moment at which one protection is gone and
the other has not been applied.

Confirm you actually closed it, rather than assuming:

```bash
ss -ltn | grep 3389         # expect NOTHING at all
```

**Never** installed by this service, so never remove: `gdm`, the
graphical target, GNOME itself, or the `gnome-remote-desktop` package.

### Step 3 — delete state

```bash
# Confirm the path from step 0 first.
rm -rf ~/services/remote-desktop     # guac-home/user-mapping.xml, .applied/, the cert copy
rm -f  ~/dev/setup-server/remote-desktop/.env   # new credentials next run
```

No `sudo` needed here, and that is not an accident: unlike AdGuard or
Immich, nothing in this service's state directory is written by a
root-running container. If `rm -rf` fails on permissions, something
created files here that this deploy did not, and you should look at what
before forcing it.

`docker compose down -v` is unnecessary — this service defines no named
volumes. If you want the images gone too:

```bash
docker rmi guacamole/guacamole:1.6.0 guacamole/guacd:1.6.0   # ~1.5 GB back
```

### Step 4 — redeploy

```bash
cd ~/dev/setup-server/remote-desktop
./setup.sh
./tests/run-tests.sh --live
```

New `.env` means a **new Guacamole password and new RDP credentials**.
Record them in `DIRECTORY.md` → *Credentials & auth* per the
password-sync rule, and tell anyone who had the old ones.

### Rebuild the containers, keep everything else

The thing you usually actually want:

```bash
cd ~/dev/setup-server/remote-desktop
docker compose --project-directory . up -d --force-recreate
```

That touches no host configuration, no credentials and no state.
