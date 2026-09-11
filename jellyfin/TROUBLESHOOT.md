# jellyfin — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?              ->  publish?        ->  client?
docker ps          curl :8096                  serve status        app / browser
                   + wizard actually done?
```

Quick triage:

```bash
cd ~/dev/setup-server/jellyfin
docker compose --project-directory . ps                      # jellyfin up?
curl -s http://127.0.0.1:8096/System/Info/Public             # answers?
curl -s http://127.0.0.1:8096/System/Info/Public \
  | grep -o '"StartupWizardCompleted":[a-z]*'                # must be true
tailscale serve status                                       # :8096 -> 127.0.0.1:8096
./tests/run-tests.sh --live                                  # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so rather than reporting a healthy container as down.

## Read this before you debug anything: three things that lie

Most confusing Jellyfin failures on this box are one of these two.

**1. `/System/Info/Public` returning 200 does not mean the server is ready.**
It answers while the server is still loading. `/Startup/*` returns
`503 Jellyfin Server is loading` during that same window. If you are
scripting against Jellyfin, gate on `GET /Startup/FirstUser` losing its 503 —
never on `/System/Info/Public`. See the next section for what happens when
you get this wrong.

**2. `GET /Users/Public` returning `[]` does not mean there are no users.**
It lists users *configured to appear on the login screen*, which is none of
them by default. An empty array is the correct response on a perfectly
healthy install with an admin account in it. Do not use it as a health check,
and do not "fix" a deploy until it returns something. To ask whether the
admin exists, log in:

```bash
cd ~/dev/setup-server/jellyfin
curl -sS -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
  -H 'Content-Type: application/json' \
  -H 'Authorization: MediaBrowser Client="triage", Device="cli", DeviceId="triage", Version="1.0"' \
  -d "{\"Username\":\"$(sed -n 's/^JELLYFIN_ADMIN_USERNAME=//p' .env)\",\"Pw\":\"$(sed -n 's/^JELLYFIN_ADMIN_PASSWORD=//p' .env)\"}" \
  | grep -o '"IsAdministrator":[a-z]*'
```

`"IsAdministrator":true` is the only answer that means the deploy worked.
Verified working as written on this deploy.

**3. `HTTP 000` is not a status code, and `HTTP 000000` is a bug in whatever
printed it.** `curl -w '%{http_code}'` prints `000` when it never connected —
*and* exits non-zero, which is the part that catches people. A
`code=$(curl … -w '%{http_code}' || echo 000)` fallback therefore fires on the
very case it was written for and **concatenates**, producing the nonsense
`000000` this deploy actually printed once. `setup.sh` now normalises anything
that is not three digits back to `000` for exactly this reason. If you are
scripting against Jellyfin:

```bash
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8096/…)   # no `|| echo`
```

and treat `000` as "retry, the server is not listening yet", never as a
verdict about the API.

## The wizard finished but there is no admin account

**The worst failure mode this service has**, because everything looks fine:
container running, web UI loading, `setup.sh` printed a password. But the
login page rejects it, and there is no "create your first user" screen,
because the server believes setup is complete.

Cause: something gated on `/System/Info/Public` (or a fixed `sleep`) and
started POSTing the wizard while the server was still loading. The
`/Startup/User` call — the one that creates the admin — got a 503, and the
later `/Startup/Complete` succeeded anyway.

Symptoms, in order of certainty:

```bash
curl -s http://127.0.0.1:8096/System/Info/Public | grep -o '"StartupWizardCompleted":[a-z]*'
# → "StartupWizardCompleted":true          (wizard says done)

# …but the AuthenticateByName call above returns 401.
```

There is no supported way to reopen the wizard cleanly. Since a broken deploy
has by definition no watch history worth keeping, the fix is to start over:

```bash
cd ~/dev/setup-server/jellyfin
docker compose --project-directory . down
rm -rf ~/services/jellyfin/config ~/services/jellyfin/cache
rm -f  ~/services/jellyfin/.wizard-complete    # ⚠️ or the wizard is skipped
./setup.sh
```

⚠️ **That third line is not optional.** `.wizard-complete` is the marker that
makes a normal re-run leave the wizard alone. `setup.sh` cross-checks it
against the live server's `StartupWizardCompleted`, so forgetting it stops the
deploy with a `Stale marker:` error naming exactly this situation rather than
failing later at the login — but it still stops the deploy.

`setup.sh` polls `/Startup/FirstUser` until the 503s stop, so a re-run does
not reproduce it. If you have edited the readiness check, put it back — this
failure is the reason it exists, and `tests/run-tests.sh` has a case that
fails if the polling is removed.

*(If the config directory does contain something you care about, the
unsupported alternative is to stop the container, flip
`<StartupWizardCompleted>` back to `false`, start it, and re-run the wizard.
The file and element **do exist on 12.0** — confirmed on this box:*

```bash
grep -o 'StartupWizardCompleted>[a-z]*' ~/services/jellyfin/config/config/system.xml
```

*What is still unverified is whether flipping it actually reopens the wizard
on 12.0 rather than leaving a half-initialised server, so copy the directory
first (`cp -a ~/services/jellyfin/config ~/jellyfin-config.bak`) and prefer
the re-deploy above whenever you can afford it. Note that `system.xml` is
rewritten by the running server, so the edit has to happen while the
container is stopped or it will be overwritten.)*

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 jellyfin
```

- **`Unable to create directory /config/…` / permission errors** —
  `JELLYFIN_UID`/`JELLYFIN_GID` in `.env` (compose feeds them straight to the
  container's `user:`) do not match the owner of `~/services/jellyfin/config`.
  Fix the values (`id -u`, `id -g`) and re-run `./setup.sh`, or
  `sudo chown -R $(id -u):$(id -g) ~/services/jellyfin`. The same pair must
  also be able to *read* `MEDIA_DIR`.
- **`error while creating mount source path` for the media dir** — `MEDIA_DIR`
  in `.env` points at something that does not exist (a typo, or an external
  disk that is not mounted). Docker will happily create an empty directory in
  its place on some versions, which is worse than the error. Check
  `ls -ld "$(sed -n 's/^MEDIA_DIR=//p' .env)"`.
- **`variable is not set`** — `.env` is incomplete. Check what Compose
  actually resolves: `docker compose --project-directory . config`.
- **Exit 137 (OOM-killed)** — Jellyfin idles at ~211 MiB, so at idle this is
  a neighbour (ollama with a model loaded claims ~5 GB). *During a transcode*
  it can genuinely be Jellyfin. `docker stats` and `free -h`. Swap turns an
  OOM kill into "slow", which is the better failure:
  `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`.
- **Boot loop right after a version bump** — 12.x runs schema migrations and
  does **not** downgrade. Restoring `JELLYFIN_VERSION` in `.env` alone will
  not help; a `config/` opened by a newer version has to be restored from a
  backup taken before the bump, or discarded.

## The library is empty / nothing shows up

Almost always expected, not broken. In descending order of likelihood:

1. **There is no media on this box.** `MEDIA_DIR` defaults to
   `~/services/jellyfin/media`, which `setup.sh` creates empty. Check:
   `ls "$(sed -n 's/^MEDIA_DIR=//p' .env)"`. If that is empty, Jellyfin is
   correct to show nothing.
2. **No library has been added.** A mounted directory is not a library until
   you create one: Dashboard → Libraries → **Add Media Library**.
3. **The library path was typed as the host sees it.** Jellyfin only knows
   container paths. `/mnt/media/movies` on the host is `/media/movies`
   inside. Verify what the container can actually see:
   ```bash
   docker exec jellyfin ls -la /media
   ```
   If that is empty but the host directory is not, `MEDIA_DIR` is wrong —
   fix it in `.env` and `./setup.sh`.
4. **The scan has not run.** Dashboard → Libraries → **Scan All Libraries**,
   and watch Dashboard → Activity.
5. **Files scan but get no titles/posters** — the naming does not match what
   the scrapers expect. `Movies/Title (2019)/Title (2019).mkv` and
   `Shows/Title/Season 01/Title - S01E02.mkv` are the shapes that work. Fix
   the names on disk rather than identifying every item by hand.
6. **"Delete" and metadata-writeback fail** — by design. `/media` is mounted
   read-only, so Jellyfin cannot write NFO files or posters next to your
   media and cannot delete anything. Fetched metadata lives in
   `config/metadata/` instead. If you genuinely want writeback, change the
   `:ro` in `docker-compose.yml` — knowing you are handing a network-facing
   service write access to your library.

## Playback stutters / buffers / "playback error"

First: **is it transcoding?** Dashboard → Activity shows Direct Play,
Direct Stream or Transcode per session, plus the reason.

- **Direct Play, still stuttering** — that is the network, not the server.
  Check the client's Tailscale connection type: a **relayed** (DERP) link is
  slow, a direct one is not. `tailscale status` on the box shows `relay` vs
  `direct` per peer.
- **Transcoding, and the CPU is pinned** — expected while hardware
  transcoding is off. Check which mode you are in: `./enable-nvenc.sh
  --check`. The Ryzen 5 2600 does one 1080p transcode comfortably and 4K not
  at all. Options, cheapest first:
  1. Fix the client so it direct-plays (Jellyfin Media Player, Swiftfin or
     Infuse instead of the browser; the browser is the most common cause of
     an unnecessary transcode).
  2. Raise the client's quality setting — a client set to "auto" will ask for
     a lower bitrate and force a transcode of a file it could have played.
  3. Turn on the GPU: `./enable-nvenc.sh` (needs sudo, and restarts the
     Docker daemon, which bounces every other service on this box).
- **NVENC says it is enabled but transcodes still run on the CPU** — the
  classic `NVIDIA_DRIVER_CAPABILITIES` trap. `--gpus all` defaults to
  `utility,compute`, which omits `video`, so `libnvidia-encode` is never
  mounted: `nvidia-smi` works inside the container and ffmpeg still finds no
  encoder. `docker-compose.gpu.yml` sets the capability explicitly — confirm
  it is actually layered (`./enable-nvenc.sh --check` should report
  `JELLYFIN_NVENC=on`), then check the container really has it:
  `docker inspect jellyfin --format '{{json .Config.Env}}' | tr ',' '\n' | grep NVIDIA`.
  Watch `nvidia-smi dmon -s u` during a transcode; if the `enc` column stays
  0, the GPU is not being used regardless of what the dashboard claims.
- **Container will not start: `could not select device driver "nvidia"`** —
  `JELLYFIN_NVENC=on` without the runtime installed. `setup.sh` refuses this
  combination before touching the container, so seeing it means compose was
  invoked by hand with the overlay. Fix: `./enable-nvenc.sh`, or
  `JELLYFIN_NVENC=off ./setup.sh`.
- **AV1 files fail instead of falling back to the CPU** — the GTX 1070 is
  Pascal and has no AV1 decoder. Untick AV1 in Dashboard → Playback →
  Transcoding; Jellyfin does not fall back gracefully from a hardware decoder
  you told it to use.
- **"Playback failed" immediately, no transcode attempted** — usually an
  unsupported audio codec in the browser (TrueHD, DTS). Use a real client.
- **Transcodes fill the disk** — in-flight segments land in
  `~/services/jellyfin/cache/transcodes` (`/cache/transcodes` in the
  container). Verified on this deploy: `config/transcodes` does not exist, and
  `encoding.xml` leaves `TranscodingTempPath` unset, so 12.0 uses the cache
  default. Dashboard → Scheduled Tasks → **Clean Transcode Directory** clears
  them, and Dashboard → Playback → Transcoding can cap the directory size.
  `cache/` also holds the image and subtitle cache; the whole directory is
  regenerable and safe to delete with the container stopped.

## Everything loads, but playback fails on every device except this box

The web UI works, the library shows, you press play, and nothing happens —
on the phone, the TV and the laptop, but it works in a browser *on the
server*. That is `PublishedServerUrl`: Jellyfin is telling clients to fetch
the video stream from an address only this machine can reach.

```bash
cd ~/dev/setup-server/jellyfin
curl -s http://127.0.0.1:8096/System/Info/Public \
  | sed -n 's/.*"LocalAddress":"\([^"]*\)".*/\1/p'
grep JELLYFIN_PUBLISHED_URL .env
```

Both should read `https://kai-home-server.taild6a23f.ts.net:8096`. If
`LocalAddress` says `127.0.0.1`, `localhost` or an old hostname/port:

```bash
sed -i 's|^JELLYFIN_PUBLISHED_URL=.*|JELLYFIN_PUBLISHED_URL=https://kai-home-server.taild6a23f.ts.net:8096|' .env
./setup.sh
```

`setup.sh` warns about this on every run where `.env` disagrees with the live
tailnet name, and again if the running server is advertising something else —
it does not rewrite `.env` for you, because that file is yours. The failure
is silent from Jellyfin's side: nothing in the logs says "I handed the client
an unreachable address".

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` will show what has
  `:8096`. Reset just this one: `tailscale serve --https=8096 off`.
  ⚠️ Never `tailscale serve reset` — that clears every mapping on the node,
  taking all the other services down with it, and every service's `setup.sh`
  then has to be re-run. `off` is absent from `serve --help` (which lists only
  `reset` and `clear`) but is what Tailscale prints itself after a successful
  `serve`, and is the only single-port removal.

  `:8096` is safe to `off` on its own. `:443` is not — it hosts two mounts,
  code-server at `/` and the launcher at `/home/` — so never reach for a bare
  `--https=443` here.

## HTTPS URL doesn't load from a client

- **Is the client on the tailnet?** Not reachable off-tailnet, by design.
  Check the Tailscale app on the phone/TV says "Connected" before anything
  else. A TV that worked yesterday and does not today has usually dropped off
  after a reboot.
- **Did you include `:8096`?** Without the port the client tries 443, which is
  code-server, and reports something unhelpful. The full address is
  `https://kai-home-server.taild6a23f.ts.net:8096`.
- **Did you use `http://`?** Serve is HTTPS-only.
- First load after a new port can take ~60s while the cert is minted:
  `curl -v https://kai-home-server.taild6a23f.ts.net:8096/System/Info/Public`
- MagicDNS off → use the tailnet IP `100.85.87.87:8096`. Jellyfin builds URLs
  relative to the request, so unlike Forgejo nothing breaks by using the IP.
- **Roku, or an old smart TV** — Tailscale does not run on Roku at all. That
  needs a Tailscale subnet router on the LAN, which is a different project.

## Login problems

- **The password in `.env` is rejected, and `setup.sh` failed on the
  verification step** — see "The wizard finished but there is no admin
  account" above; that is the usual cause on a first deploy. On an
  established install it means the password was changed in the web UI and
  `.env` is stale: mirror the new one into `JELLYFIN_ADMIN_PASSWORD`, or
  reset it from Dashboard → Users.
- **`AuthenticateByName` returns 400, not 401** — the request is missing the
  `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…",
  Version="…"` header. Jellyfin requires client identity on that endpoint;
  the values are arbitrary, their presence is not.
- **Locked out of the only admin account** — there is no CLI reset, and while
  the library is empty the honest answer is: **don't fight it, re-deploy.**
  It costs nothing here and is the only path anyone has verified on this box:

  ```bash
  cd ~/dev/setup-server/jellyfin
  docker compose --project-directory . down
  rm -rf ~/services/jellyfin/config ~/services/jellyfin/cache
  rm -f  ~/services/jellyfin/.wizard-complete
  rm -f .env                       # new generated password
  ./setup.sh
  ```

  Once there *is* watch history worth keeping, the usual community fix is to
  stop the container and clear the password hash directly in
  `~/services/jellyfin/config/data/jellyfin.db`, then log in with an empty
  password and set a new one.

  ⚠️ **There is no `sqlite3` on this host, and none in the Jellyfin image
  either.** Borrow one from the Forgejo image, which does ship it:

  ```bash
  cp -a ~/services/jellyfin/config ~/jellyfin-config.bak    # first, always
  docker compose --project-directory . down
  docker run --rm --entrypoint sqlite3 \
    -v ~/services/jellyfin/config/data:/db codeberg.org/forgejo/forgejo:15 \
    /db/jellyfin.db '.schema Users'
  ```

  On 12.0 the table is `Users` (verified on this box, via that exact command
  against a copy). What is **not** verified is which column to blank and
  whether Jellyfin then accepts an empty password — 12.0's schema is a
  rewrite, so 10.x guides naming `Password`/`EasyPassword` may not apply. Read
  the schema, expect to iterate, and never write to that DB with the container
  running. Whatever you end up with, mirror the new password into `.env` or
  the next `./setup.sh` fails its verification login.
- **`setup.sh` dies with `Stale marker: … says the wizard has run, but the
  server reports StartupWizardCompleted=false`** — `~/services/jellyfin/config`
  was deleted (or replaced, or pointed somewhere else) while
  `~/services/jellyfin/.wizard-complete` survived, so the server is back at
  first-run with no users. The script refuses to skip the wizard on a stale
  marker rather than failing later with a misleading "password rejected".
  The fix is the one it prints:
  ```bash
  rm ~/services/jellyfin/.wizard-complete && ./setup.sh
  ```
  That re-runs the wizard and recreates the admin from the credentials
  already in `.env`, so the password you have keeps working.
- **A user sees fewer libraries than expected** — that is the per-user
  library permission, Dashboard → Users → the user → Access, not a scan
  problem.

## Version / upgrade problems

- **Was pinning 12.0 a mistake?** Possibly, and while the library is empty it
  costs nothing to reverse — SETUP.md has the exact four commands. Once there
  is watch history in `config/data/`, it stops being free: 12.x rewrites the
  schema and 10.11 cannot open the result. Decide early.
- **A plugin will not install / a plugin disappeared** — no third-party
  plugin built for 10.x loads on 12.0; the ABI changed. This is expected, not
  a broken install.
- **An old client or script gets 404s on everything** — `/emby/` and
  `/mediabrowser/` API prefixes were removed in 12.0. Update the client, or
  the script's base path.
- **Upgrade hangs on a migration** — let it finish. Interrupting a schema
  migration is how you get a database no version can open. Watch
  `docker compose --project-directory . logs -f jellyfin`.

## Disk

- `du -sh ~/services/jellyfin/*` — expect `media` to dominate; if `cache` is
  large, that is transcode scratch and is safe to delete with the container
  stopped.
- `config/metadata` grows with the library (posters, fanart). Dashboard →
  Scheduled Tasks → **Clean up old metadata** trims it.
- Moving the state: stop the stack, move `~/services/jellyfin`, update
  `MEDIA_DIR` (and any path in `.env`), `./setup.sh`.

## Nuke and pave

Destroys every user, library definition and all watch state. **It does not
touch your media** — `MEDIA_DIR` is a read-only mount and is not deleted
here — but everything about *who watched what, and how far in* is gone, and
on this box there is no backup of it.

```bash
cd ~/dev/setup-server/jellyfin
docker compose --project-directory . down -v
rm -rf ~/services/jellyfin/config ~/services/jellyfin/cache
rm -f  ~/services/jellyfin/.wizard-complete   # or the wizard is skipped
rm -f .env                         # forces new generated credentials
tailscale serve --https=8096 off
./setup.sh
```

Deliberately **not** in that list: `rm -rf ~/services/jellyfin/media`. Add it
only if you are certain, and only after remembering that this machine has no
backup of it.

To keep watch state and rebuild only the container, `docker compose down`
without `-v` and `./setup.sh` — `config/` survives and the wizard is skipped
because `StartupWizardCompleted` is already true.
