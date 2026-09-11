# homepage — Troubleshooting

Triage in layers, outermost failure first. **Do not stop at a status code on
this service** — the signature failure returns HTTP 200.

```
container up?   ->  config parsed?          ->  loopback API?        ->  publish?       ->  tailnet API?
docker ps           /api/services non-empty     curl 127.0.0.1:8100     serve status      curl https://…:8100/api/services
```

Quick triage, in the order that finds things fastest:

```bash
cd ~/dev/setup-server/homepage
docker compose --project-directory . ps                       # up?

# THE question. Not "does it return 200" — see the first section below.
curl -sS http://127.0.0.1:8100/api/services            | head -c 200
curl -sS https://kai-home-server.taild6a23f.ts.net:8100/api/services | head -c 200

tail -20 ~/services/homepage/config/logs/homepage.log          # YAML errors land ONLY here
docker compose --project-directory . logs --tail=30 homepage   # host-validation errors land here
tailscale serve status | grep -A2 ':8100'
ss -ltnp | grep :8100                                          # 127.0.0.1 only (+ tailscaled)
./tests/run-tests.sh --live                                    # all of it at once
```

If `docker` says "permission denied", you are not in the docker group in
*this* shell: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects that and says so rather than reporting a healthy container as down.

**Reading the answers.** Two endpoints, and the difference between them is the
whole page:

| | `GET /` | `GET /api/services` |
|---|---|---|
| Container down | curl exit 7, `000` | curl exit 7, `000` |
| Cold start (~10s) | `000` | `000` |
| Host not on the allowlist | **200, full HTML** | **400** `Host validation failed` |
| `services.yaml` failed to parse | **200, full HTML** | **200, `[]`** |
| Actually working | 200, full HTML | 200, `[{"name":"Daily",…}]` |

Three different states produce a 200 on `/`, and two of them are broken.

---

## "The page loads but there are no status dots / no services / no widgets"

The signature failure of this service. It is host validation, it is one
environment variable, and it is invisible to every check that looks at `/`.

**Confirm it in five seconds:**

```bash
curl -sS https://kai-home-server.taild6a23f.ts.net:8100/api/services
# {"error":"Host validation failed. See logs for more details."}
```

or, from the container's side:

```bash
docker logs homepage 2>&1 | grep 'Host validation failed' | tail -5
# error: Host validation failed for: kai-home-server.taild6a23f.ts.net:8100.
#   Hint: Set the HOMEPAGE_ALLOWED_HOSTS environment variable to allow
#   requests from this host / port.
```

The log line **names the exact string** that was rejected. That string is what
has to go in the list, verbatim, port included.

**Why the page still looks fine.** Homepage v1.4.5 runs the validation
middleware with the matcher `/api/:path*`. `/` is outside it and is never
checked. Measured: the HTML returned for an allowed Host and a rejected one is
**byte-identical** — 44801 bytes, `cmp` reports no difference. Then the
browser's own `/api/*` fetches 400 and the live parts of the page never
populate.

Worth knowing before you go looking at the HTML for clues: **`/` is a
build-time static shell.** It contains none of your group names and still
contains the upstream `My First Service` placeholder — on a *correct* install.
Everything real arrives client-side from `/api/*`. `<title>` is always the
literal `Homepage`, whatever `title:` says in `settings.yaml`. So `curl` on `/`
tells you nothing except that a Homepage container answered.

**Fix:**

```bash
cd ~/dev/setup-server/homepage
grep HOMEPAGE_ALLOWED_HOSTS .env
# HOMEPAGE_ALLOWED_HOSTS=kai-home-server.taild6a23f.ts.net:8100,kai-home-server.taild6a23f.ts.net,127.0.0.1:8100,localhost:8100

$EDITOR .env          # add the exact string from the log line
./setup.sh            # re-runs compose up, which re-reads .env, and re-verifies
```

`setup.sh` warns about this before it happens, too: if `.env`'s list no longer
contains `<tailnet-name>:<https-port>` it says so during the run rather than
rewriting your file.

### Things that cause it

- **You changed `HTTPS_PORT`.** The Host header carries the port. Moving Serve
  from `:8100` to `:8200` invalidates the entry; the list must move with it.
- **You published a second door** — another port, or `--set-path=/dash` on
  `:443`. On `:443` the browser sends no port at all, which is why the bare
  hostname is on the seeded list. Anything else needs adding.
- **Something other than a browser is probing it** — a Kuma monitor, the
  launcher, a script — using an address that is not on the list. Check 5 in
  `setup.sh` catches this as a warning: log lines exist but your own page
  works. Find out which Host:
  `docker logs homepage 2>&1 | grep 'Host validation failed' | tail -5`.
- **The tailnet name changed** (re-tailnet, node rename). `.env` still names
  the old one. `tailscale status --json | grep DNSName` for the current value.

### Do NOT fix it with `*`

`HOMEPAGE_ALLOWED_HOSTS=*` disables the check completely — measured, every
Host is accepted. It makes the symptom vanish and leaves this dashboard's API
reachable by any page in your browser that resolves an attacker-chosen name to
`127.0.0.1` (DNS rebinding). The right fix is one exact string, and the log
line hands it to you.

### Note for whoever writes the next monitor

A Kuma monitor on `https://…:8100/` will be green forever, including through
this exact failure. Point it at `/api/healthcheck` instead — it is
host-validated, its Host is already on the list, and it returns the literal
body `up` with HTTP 200.

## "A group disappeared / a tile is missing / everything is gone"

Almost always a YAML syntax error, and Homepage's response to one is the
second thing on this page that looks like success:

```bash
curl -sS http://127.0.0.1:8100/api/services
# []          <- HTTP 200, empty list
```

**A parse failure returns 200 and `[]`. It does not return an error, and it
does not appear anywhere the HTTP client can see it.** The only place it is
reported is the log Homepage writes itself:

```bash
tail -20 ~/services/homepage/config/logs/homepage.log
```

```
error: Failed to load services.yaml, please check for errors
error: YAMLException: unexpected end of the stream within a flow collection (6:1)

 3 |     - Svc:
 4 |       href: http://x/
 5 |   bad indent here: [
 6 |
-----^
```

Line number, column, three lines of context and a caret. The same lines also
appear in `docker logs homepage`, but the file is the one that survives a
container recreate, and it is the one to check first.

**Fix:** correct the YAML, save, reload the browser. No restart — Homepage
re-reads config per API request (measured).

Common causes, in the order they actually happen:

- **Tabs.** YAML forbids them for indentation. Editors that insert tabs will
  produce `YAMLException: tab characters must not be used in indentation`.
- **A `:` inside an unquoted value.** `description: Photos: the good ones`
  parses as a nested mapping and fails. Quote it.
- **Inconsistent indentation** under a service — `href` and `siteMonitor` must
  sit at the same depth, one level deeper than the tile name.
- **A stray `[` or `{`** from a half-finished edit. That is the example above:
  the parser runs to end of file looking for the close.

**Sanity-check before reloading**, if you have python3 (you do):

```bash
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" \
  ~/services/homepage/config/services.yaml && echo OK
```

### A group is present but in the wrong place

Not a parse error. `layout:` in `settings.yaml` orders groups by **exact name
match** against the group keys in `services.yaml`. A renamed or re-spelled
group silently falls back to alphabetical placement rather than erroring.
Compare the two spellings character for character — a trailing space or a
different dash counts.

### A single tile shows an error status

Usually correct. `siteMonitor` reports what the service actually answered, and
several services on this box are start-on-demand or deliberately stopped. Ask
the same question by hand:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2283/api/server/ping
```

- **The dot is red and the manual curl also fails** — that service is down.
  Homepage is right. Go fix that service.
- **The dot is red and the manual curl works** — the `siteMonitor` URL is
  wrong: usually the wrong local port after a service moved, or a tailnet
  `https://` URL where a `http://127.0.0.1:<port>` one belongs. Homepage
  probes from the **host namespace over loopback**; it does not use the
  tailnet.
- **The dot is red for every tile at once** — that is not the tiles, that is
  host validation. Go back to the first section.

Ask Homepage directly what it saw, rather than guessing:

```bash
curl -sS 'http://127.0.0.1:8100/api/siteMonitor?groupName=Daily&serviceName=Immich'
# {"status":200,"latency":3}     <- up
# {"status":500,"latency":…}     <- down; note the API call itself is 200
```

Redirects are followed, so a service whose `/` is a 302 (Uptime Kuma, AdGuard)
reports `status: 200`. That is why `services.yaml` reuses
`launcher/services.json`'s health paths verbatim.

## Log noise that is NOT a problem

```
<httpProxy> Error calling http://127.0.0.1:3001/health
Error: connect ECONNREFUSED 127.0.0.1:3001
    at TCPConnectWrap.afterConnect …
```

**Expected on this box**, once per probe per page load, in both `docker logs
homepage` and `config/logs/homepage.log`. Several services here are
deliberately start-on-demand and are stopped right now — open-webui, n8n,
manimkc, kaichenpedia, jellyfin and forgejo among them — and Homepage is
correctly reporting each as `status: 500`. It is a stack trace for "the thing
I was told to check is not running", not a fault in Homepage.

If the noise bothers you, remove the `siteMonitor:` line from those tiles (the
link still works, the dot just goes away) or start the service. Do not silence
it by pointing `siteMonitor` at something that always answers — that turns
every dot on the page into a lie.

If you see this for a service that **is** running, that is a real finding: the
`siteMonitor` URL has the wrong local port. See the previous section.

## "It worked, then I edited something and now it won't come back"

The config directory is not sacred. Homepage rewrites any file that is
**missing** with the upstream default the next time the API asks for it, so
deleting a file you have wrecked is a valid repair:

```bash
cd ~/services/homepage/config
cp services.yaml /tmp/services.yaml.broken     # keep it to diff later
rm services.yaml
curl -sS -o /dev/null http://127.0.0.1:8100/api/services   # provokes the rewrite
ls -l services.yaml                                        # upstream default is back
```

To get **this repo's** seeded version back instead of the upstream
placeholder, delete the file and re-run `setup.sh` — the seeding step writes
any template that is missing, substituting the tailnet name:

```bash
cd ~/dev/setup-server/homepage
rm ~/services/homepage/config/services.yaml
./setup.sh                                    # re-seeds only what is absent
```

That is also the guarantee in the other direction: **`setup.sh` never
overwrites a config file that exists.** A re-run reports how many files it
kept. If a re-run ever does clobber an edit, that is a bug, not a feature —
say so rather than working around it.

## Permissions: "I can't edit my own dashboard config"

```bash
ls -ln ~/services/homepage/config
# -rw-r--r-- 1 1000 1000 ... services.yaml     <- correct: your uid
```

The container starts as **root** and drops to `PUID:PGID` via `su-exec`,
chowning `/app/config` on the way. `setup.sh` sets those to your own uid/gid,
which is what makes the files editable without sudo — and on a service whose
entire purpose is hand-edited config, that is not a nicety.

**`HOMEPAGE_GID` is not 1000 and that is probably fine.** If `setup.sh` was run
as `sg docker -c ./setup.sh` — the usual fix for a shell that predates the
docker group — then `id -g` reported the **docker** group, so `HOMEPAGE_GID` is
`124` and the files are `kaichen:docker`. That is the state on this box. You own
every file and can edit every file; nothing is wrong. Do not "correct" it to
`1000` unless you actually want the chown that follows on the next start.

If the files come back owned by `0 0` (root) or by some id that is not yours:

```bash
grep -E '^HOMEPAGE_(UID|GID)=' ~/dev/setup-server/homepage/.env
id -u; id -g
```

A `HOMEPAGE_UID` that is not your uid is the real problem; the gid rarely is.
Fix `.env` and re-run `setup.sh` — the chown happens on every container start,
so the next start repairs the ownership. To repair it immediately without
waiting:

```bash
sudo chown -R $(id -u):$(id -g) ~/services/homepage/config
```

Note this is the *opposite* of adguard and vaultwarden on this box, whose data
directories stay root-owned because those containers do not drop privileges.
Do not copy a `sudo rm -rf` recipe from those pages to this one — you do not
need sudo here, and running it as root is how a config directory ends up
root-owned in the first place.

## Widget problems

Service widgets (the ones *inside* a tile — Immich counts, Jellyfin
now-playing, AdGuard block rate) are separate from the header strip and fail
separately.

**A widget shows an error box but the rest of the page is fine.** That is the
designed behaviour; one broken widget does not take the dashboard down. The
reason is in the log:

```bash
docker logs homepage 2>&1 | grep -i -e widget -e 'api error' | tail -10
tail -30 ~/services/homepage/config/logs/homepage.log
```

Causes, most common first:

- **No API key, or the wrong one.** Nearly every service widget authenticates.
  The tile renders `API Error: Unauthorized` or similar. Get a key from that
  service's own settings and put it in Homepage's env file —
  `~/services/homepage/config/.env`, read as `{{HOMEPAGE_VAR_NAME}}` in
  `services.yaml` — rather than inline. Homepage must be restarted for a
  change to *that* file (unlike the YAML, which is re-read per request):
  `docker compose --project-directory ~/dev/setup-server/homepage restart`.
- **The widget `url:` points at the tailnet URL.** Widgets are fetched by
  Homepage, from the host namespace, so they want
  `http://127.0.0.1:<local-port>` exactly like `siteMonitor` does. A tailnet
  URL usually works too but adds a TLS handshake and a Serve round trip to
  every page load.
- **The key is right but the widget type is wrong.** `type:` must match the
  service, and the field names differ per type. The reference is
  <https://gethomepage.dev/widgets/> — check the exact type page, not the
  index.
- **You changed the key and nothing happened.** Restart (see above). YAML is
  hot-reloaded; the env file is not.

**Remember what a widget costs here.** Homepage has no login of its own, so an
API key in its config is readable by anyone who can reach the dashboard. Use a
scoped or read-only key where the service offers one, and prefer
`siteMonitor` — which needs no credential at all — when all you wanted was
"is it up".

**The header `resources` widget shows odd numbers.** It reads `/proc` from
inside a host-namespace container, so those *are* the host's numbers.
Measured: `MemTotal` and `nproc` match the host exactly, and disk `/` reports
the overlay mount whose size and usage track `/dev/sda2`. Do not "fix" the
filesystem name.

## It won't start / nothing is listening

```bash
docker compose --project-directory ~/dev/setup-server/homepage ps
docker compose --project-directory ~/dev/setup-server/homepage logs --tail=40 homepage
ss -ltnp | grep :8100
```

- **Connection refused for ~10 seconds after a start** — normal. A container
  that is *up* is not a server that is *listening*; curl reports that as exit
  7 and HTTP `000`, not a tidy 503. `setup.sh` retries for 60s for exactly
  this reason. Do not treat the first `000` as a failure.
- **`docker ps` shows no PORTS entry** — expected. `network_mode: host` means
  there is no Docker port mapping to display. `ss` is where the listener is.
- **Restart-looping with `EADDRINUSE`** — something else on this box already
  holds `:8100`. Under host networking Docker does not arbitrate that for you:
  `up -d` succeeds and the app inside dies on bind, so the symptom is a
  restart loop rather than a compose error.

  ```bash
  ss -ltnp | grep :8100      # who has it?
  ```

  ⚠️ Note **`:8098` is an ad-hoc `python3 echosrv.py`, not part of this
  repo** — if you are hunting a port conflict, that one is not ours and is not
  Homepage's. Do not kill it. `:8093` is the launcher and `:8092` is beszel.
  If you genuinely need to move Homepage, edit `LOCAL_PORT` **and**
  `HOMEPAGE_ALLOWED_HOSTS` in `.env` together, then re-run `setup.sh`.

- **It is listening on `0.0.0.0:8100`** — that is a real problem, not cosmetic.
  With host networking, `HOSTNAME=127.0.0.1` in `docker-compose.yml` is the
  only thing keeping this dashboard — which has **no password** — off the LAN.
  The image ships `HOSTNAME=0.0.0.0`.

  ```bash
  grep HOSTNAME ~/dev/setup-server/homepage/docker-compose.yml   # must be 127.0.0.1
  docker inspect -f '{{json .Config.Env}}' homepage | tr ',' '\n' | grep HOSTNAME
  ```

  Restore the line, `./setup.sh`, and confirm with `ss -ltnp | grep :8100`.
  `setup.sh` check 6 and the live test suite both assert this.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for this tailnet yet.
  Open the link, approve, press Enter to retry.
- **The first HTTPS request takes ~60s** — the TLS certificate is being minted
  on demand for a port that has never been used. Not a fault. `setup.sh`
  allows 90s plus five retries.
- **Port already claimed by something else** — `tailscale serve status` shows
  what has `:8100`. Remove **just that one**:

  ```bash
  tailscale serve --https=8100 off
  ```

  ⚠️ **Never `tailscale serve reset`** — that clears every mapping on this
  node, taking code-server (`:443`), the launcher (`/home/`), Seafile, Immich,
  Jellyfin, forgejo, Kuma, ntfy and everything else down with it. `off` is not
  in `--help` but is what Tailscale prints itself, and it is the only
  single-port removal.

## Did Homepage break something else?

It should not have. It mounts one directory, opens one port, and makes
outbound loopback requests. Two things worth knowing:

- **`siteMonitor` probes every service on every page load.** That is a handful
  of loopback GETs, and every path in the seeded `services.yaml` is a health
  or ping endpoint. If a service's log is suddenly full of requests, this is
  probably where they come from — remove or repoint that tile's `siteMonitor`.
- **It is in the host network namespace.** It does not add routes, iptables
  rules or interfaces, and it binds exactly one port. If you are debugging a
  network problem, `ss -ltnp | grep :8100` is the entire footprint.

The Docker socket is **not** mounted, so Homepage cannot affect any other
container even in principle:

```bash
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' homepage
# only ~/services/homepage/config -> /app/config
```

If that command ever shows `/var/run/docker.sock`, someone uncommented the
mount. See SETUP.md → Security model before deciding that is fine.

## Nuke and pave

Destroys the dashboard configuration: your service tiles, layout, theme,
bookmarks and Homepage's own log. It does **not** affect any other service on
this box — nothing else reads this directory, and Homepage holds no data of
its own.

There is no ordering hazard here (unlike adguard, whose removal order matters).
Nothing depends on Homepage being up.

```bash
# 1. Confirm the paths before deleting them. A `rm -rf` of a path that never
#    existed is a silent no-op that leaves you thinking you started clean.
#    .env is the authority — HOMEPAGE_CONFIG is where the data actually is,
#    and it need not be the default.
grep -E '^(HOMEPAGE_CONFIG|LOCAL_PORT)=' ~/dev/setup-server/homepage/.env
ls -ld  ~/services/homepage ~/services/homepage/config
ls -l   ~/services/homepage/config/services.yaml

# 2. Keep the config if you have edited it. This is a plain text directory and
#    it is small; there is no reason not to.
cp -a ~/services/homepage/config ~/homepage-config-$(date +%F).bak

# 3. Tear down.
cd ~/dev/setup-server/homepage
docker compose --project-directory . down

#    No sudo: PUID/PGID make everything under config/ owned by you. If this
#    fails with "Permission denied", the ownership drifted — see the
#    Permissions section above rather than reaching for sudo.
rm -rf ~/services/homepage

rm -f .env                        # regenerates with a fresh allowlist
tailscale serve --https=8100 off  # NOT `serve reset` — that clears every port

# 4. Redeploy.
./setup.sh
```

Verified against this deploy's actual layout, which is:

```
~/services/homepage/
  config/
    services.yaml        seeded from this repo by setup.sh
    settings.yaml        seeded from this repo by setup.sh
    widgets.yaml         seeded from this repo by setup.sh
    bookmarks.yaml       seeded from this repo by setup.sh
    docker.yaml          seeded from this repo by setup.sh (deliberately empty)
    kubernetes.yaml      written by Homepage itself on first run
    custom.css           written by Homepage itself on first run (empty)
    custom.js            written by Homepage itself on first run (empty)
    logs/homepage.log    written by Homepage itself
~/dev/setup-server/homepage/.env      generated, mode 600, gitignored
```

Verified against the live deployment: `ls` in that directory shows exactly
`bookmarks.yaml docker.yaml kubernetes.yaml logs/ services.yaml settings.yaml
widgets.yaml`, all owned by you. (`custom.css` and `custom.js` appear the first
time a browser loads the page, not at container start.)

Two things that make this recipe safe rather than superstitious:

- **The `.env` path in step 1 is the authority.** If `setup.sh` was ever run
  with `HOMEPAGE_CONFIG` pointing elsewhere, `~/services/homepage` is not
  where the data is, and deleting it is a no-op that convinces you you started
  clean. Check before you delete.
- **No `sudo` anywhere.** Unlike adguard, vaultwarden and immich, this
  container drops to your uid, so the files are yours. Running any of this
  under sudo is how the directory ends up root-owned and uneditable next time.

To rebuild the container while keeping everything — the usual thing you
actually want:

```bash
cd ~/dev/setup-server/homepage
docker compose --project-directory . up -d --force-recreate
```

To reset **one** config file to this repo's seeded version, delete just that
file and re-run `./setup.sh`. That is a much smaller hammer than this section.
