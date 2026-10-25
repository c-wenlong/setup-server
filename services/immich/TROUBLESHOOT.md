# immich — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?  ->  publish?  ->  client?
docker ps          curl :2283      serve status   phone/browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/immich
docker compose --project-directory . ps            # three up (four with ML on)
curl -s http://127.0.0.1:2283/api/server/ping      # {"res":"pong"}
tailscale serve status                             # :2283 -> 127.0.0.1:2283
./tests/run-tests.sh --live                        # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
checks for this up front and says so, rather than reporting three healthy
containers as down — but a hand-run `docker inspect` will just lie to you.

## Containers won't start / keep restarting

```bash
docker compose --project-directory . logs --tail=100 immich-server
docker compose --project-directory . logs --tail=50 database
```

- **`database` exits immediately, or the server logs extension errors** —
  almost always a wrong Postgres image. Immich needs its own build with
  `vectorchord` + `pgvectors`; a stock `postgres` image cannot work. Check
  the digest in `docker-compose.yml` is intact.
- **`could not resize shared memory segment`** during an import — Postgres
  `shm_size` is too small. This compose sets 1 GB; if it was edited back
  down, restore it and `docker compose up -d database`.
- **Server OOM-killed (exit code 137)** — with ML on, this box does not have
  the RAM for both Immich and a loaded ollama model. Either
  `IMMICH_ML=off ./setup.sh`, or stop ollama while importing, or add swap:
  `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`.
  Swap turns an OOM kill into "slow", which is the better failure.
- **`immich_machine_learning` is missing** — expected when ML is off.
  Check `cat ~/services/immich/.ml-mode`.
- **ML container killed at exactly 3 GB** — that is `ML_MEM_LIMIT` doing its
  job. Raise it in `.env` only if the box actually has the headroom.

## Local ping fails but the container says "running"

First boot runs DB migrations and can take minutes; `docker logs -f` shows
progress. If it never finishes:

- Check the DB is actually reachable from the server container:
  `docker exec immich_server pg_isready -h database -p 5432`
  → `database:5432 - accepting connections`. (There is no `nc` in that image;
  `pg_isready` is the tool it does ship.)
- Check the port really is on loopback: `ss -ltn | grep 2283`. Three lines are
  expected and correct — `127.0.0.1:2283` is Immich, and `100.85.87.87:2283`
  plus the `fd7a:…` v6 address are **tailscaled's** own serve frontend, not a
  leak. HTTPS port == local port here, which is why they collide on one number.
  `0.0.0.0:2283` would be the real problem.
- A half-migrated database after an interrupted upgrade usually needs the
  version pinned back: set `IMMICH_VERSION` in `.env` to the version you
  were on, `docker compose up -d`, let it settle, then upgrade forward.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` will show what has
  `:2283`. Reset just this one: `tailscale serve --https=2283 off`.
  ⚠️ Never `tailscale serve reset` — that clears every mapping on the node,
  taking all the other services down with it (including code-server on `:443`,
  which is how you were reading this). Every service's `setup.sh` then has to
  be re-run. `off` is absent from `--help` but is what Tailscale prints itself
  after a successful `serve`, and is the only single-port removal.

## `setup.sh` runs but the settings never change

These are the three ways this deploy actually went wrong. Each has a
regression test in `tests/run-tests.sh`, so if you hit one again, the test
should have caught it — start by running the mocked suite.

- **`GET /api/admin/config returned HTTP 404`, or the ML toggle stays wrong** —
  the admin config endpoint is `/system-config` on v3.1.0, which is what this
  box runs. `/admin/config` is the post-v3.1.0 rename and does not exist yet.
  `setup.sh` probes `/admin/config`, sees the 404 and falls back, printing
  `Using the pre-rename config endpoint (/system-config)` — that line is
  normal, not a warning. Confirm which one your server has:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2283/api/admin/config    # 404 here
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2283/api/system-config   # 401 = exists
  ```

  `401` means the path exists and just wants a token — that is the one in use.
- **A run died partway and the re-run says "Settings unchanged"** — the
  completion sentinel is `~/services/immich/.ml-mode`, *not* the admin
  account. If the marker is missing, the low-RAM tuning is (re)applied even
  though the admin already exists; if it is present and matches `IMMICH_ML`,
  nothing is written. So `cat ~/services/immich/.ml-mode` answers "has a
  settings pass ever completed?" — and deleting it is how you force the
  tuning to be re-applied on the next run.
- **`IMMICH_ML=off ./setup.sh` keeps starting the ML container anyway** — this
  was a real bug. `setup.sh` sources `.env`, which *exports* its
  `COMPOSE_PROFILES`, and Compose prefers the environment over the file, so a
  stale `COMPOSE_PROFILES=ml` in the shell beat the freshly-rewritten `.env`.
  The script now pins `export COMPOSE_PROFILES=` to the mode it resolved and
  passes `--profile` too. If you drive Compose by hand, the same trap applies
  to you: `COMPOSE_PROFILES= docker compose --project-directory . up -d`, or
  the profile you sourced earlier comes back.

## HTTPS URL doesn't load from a client

- Is the client on the tailnet? This is not reachable off-tailnet, by design.
- First load after a new port can take ~60s while the cert is minted.
  `curl -v https://kai-home-server.taild6a23f.ts.net:2283/api/server/ping`
- MagicDNS off → use the tailnet IP `100.85.87.87` with the same port.

## Login problems

- **`setup.sh` warns "no longer matches the server"** — the admin password
  in `.env` is stale because it was changed in the web UI. Mirror the new
  password into `IMMICH_ADMIN_PASSWORD` in `.env`. The deploy still succeeds;
  only the automated settings step is skipped.
- **Forgot the admin password entirely** — reset it from inside the server
  container: `docker exec -it immich_server immich-admin reset-admin-password`,
  then write the new one into `.env`.
- **Phone says "server unreachable"** — the endpoint must include `/api`:
  `https://kai-home-server.taild6a23f.ts.net:2283/api`. And Tailscale must be
  connected on the phone.

## Machine learning problems

- **Smart search returns nothing / no people appear** — expected with ML off.
  `IMMICH_ML=on ./setup.sh`, then Administration → Jobs → run Smart Search
  and Face Detection over the existing library.
- **Jobs fail with connection errors to `immich-machine-learning:3003`** —
  the setting is on but the container is not running (someone flipped the
  toggle in the UI instead of using the flag). Fix:
  `IMMICH_ML=on ./setup.sh`.
- **The server balloons in RAM and OOMs after ML is unreachable** — known
  upstream bug when the configured ML URL is offline. Do not leave ML
  *enabled in settings* with the container down; that combination is the
  trigger. `IMMICH_ML=off ./setup.sh` sets both consistently.
- **ML is extremely slow** — it is CPU inference at concurrency 1 by design
  on this box. Let it run overnight; the queue draining slowly is not a
  fault.
- **The marker and reality disagree** — three things must agree: the
  `.ml-mode` marker, `COMPOSE_PROFILES` in `.env`, and whether the container
  exists. `./tests/run-tests.sh --live` asserts exactly that pairing
  ("ML container absent" / "ML container running"), so a red line there is
  the fastest way to see the drift. `IMMICH_ML=on|off ./setup.sh` reconciles
  all three; nothing else does.

## Import problems

- **Web-uploaded Takeout files lost albums and dates** — the web uploader
  ignores Google's JSON sidecars. Delete and re-import with `immich-go`
  (see SETUP.md); it is the only import path that preserves them.
- **Disk filled mid-import** — Immich stores originals *plus* thumbnails and
  transcodes. Check `df -h ~/services/immich`. Moving the library means
  stopping the stack, moving `library/`, updating `UPLOAD_LOCATION` in
  `.env`, and `docker compose up -d`.

## Nuke and pave

Destroys the library and database. Nothing on this box backs them up, so
**copy the photos out first** (and take a database dump if you want albums,
people and shared links back):

```bash
cp -a ~/services/immich/library /path/on/another/disk/immich-library
docker exec immich_postgres pg_dumpall -U postgres > ~/immich-db.sql   # while it is still running
```

Then use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, stops the server and ML container before Redis
and Postgres, and refuses to delete a library or database that is not really
inside `~/services/immich` (a photo folder you pointed `UPLOAD_LOCATION` at
elsewhere is never deleted). Postgres and the server own most of those files,
so `--purge` empties them with a throwaway container of the pinned Postgres
image (already on this box, no pull) instead of `sudo`; if that fails it
stops, keeps `.env`, and prints the `sudo rm -rf` to run.

```bash
cd ~/dev/setup-server/services/immich
./teardown.sh            # remove, keep photos + database + .env (the launcher's Remove)
./teardown.sh --purge    # also delete the library, database, model-cache volume,
                         # .ml-mode and .env; type "immich" to confirm
./setup.sh               # back, fresh (new credentials) if you purged
```

To keep the photos and rebuild only the database, delete
`~/services/immich/postgres` instead of the whole directory — but note that
Immich cannot fully reconstruct its metadata (albums, people, shared links)
from the files alone, so this loses organisation, not originals.
