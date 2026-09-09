# immich — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?  ->  publish?  ->  client?
docker ps          curl :2283      serve status   phone/browser
```

Quick triage:

```bash
cd ~/dev/setup-server/immich
docker compose --project-directory . ps            # all four (or three) up?
curl -s http://127.0.0.1:2283/api/server/ping      # {"res":"pong"}
tailscale serve status                             # :2283 -> 127.0.0.1:2283
./tests/run-tests.sh --live                        # everything at once
```

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
  `docker exec immich_server sh -c 'nc -z database 5432 && echo ok'`
- Check the port really is on loopback:
  `ss -ltn | grep 2283` → should show `127.0.0.1:2283`, never `0.0.0.0`.
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
  taking all the other services down with it. `off` is undocumented in
  `--help` but is what Tailscale prints itself, and is the only single-port
  removal.

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

## Import problems

- **Web-uploaded Takeout files lost albums and dates** — the web uploader
  ignores Google's JSON sidecars. Delete and re-import with `immich-go`
  (see SETUP.md); it is the only import path that preserves them.
- **Disk filled mid-import** — Immich stores originals *plus* thumbnails and
  transcodes. Check `df -h ~/services/immich`. Moving the library means
  stopping the stack, moving `library/`, updating `UPLOAD_LOCATION` in
  `.env`, and `docker compose up -d`.

## Nuke and pave

Destroys the library and database — export anything you care about first.

```bash
cd ~/dev/setup-server/immich
docker compose --project-directory . --profile ml down -v
rm -rf ~/services/immich          # photos AND database
rm -f .env                        # forces new generated credentials
tailscale serve --https=2283 off
./setup.sh
```

To keep the photos and rebuild only the database, delete
`~/services/immich/postgres` instead of the whole directory — but note that
Immich cannot fully reconstruct its metadata (albums, people, shared links)
from the files alone, so this loses organisation, not originals.
