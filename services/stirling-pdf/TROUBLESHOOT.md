# stirling-pdf — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?              ->  publish?        ->  client?
docker ps          curl :8103                  serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/stirling-pdf
docker compose --project-directory . ps
curl -s http://127.0.0.1:8103/api/v1/info/status
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 stirling-pdf
```

- **`STIRLING_DATA missing from .env` / `variable is not set`** — `.env`
  is incomplete. `docker compose --project-directory . config` shows which
  `${…:?}` guard fired. Do not hand-write a partial `.env`; move it aside
  and re-run `./setup.sh`.
- **Permission errors on `/configs`** — `PUID`/`PGID` in the container
  come from `STIRLING_UID`/`STIRLING_GID` in `.env` (`id -u` / `id -g`
  on first run). Re-run `./setup.sh`, or
  `chown -R "$(id -u):$(id -g)" ~/services/stirling-pdf`.
- **Exit 137 (OOM-killed) / connection reset on :8103** — Java plus
  LibreOffice (unoserver). Cap is 1536 MiB. `docker stats` and
  `free -h`. Unload ollama, or bump `STIRLING_MEM_LIMIT` in `.env` and
  re-run. 768m is too small — the JVM starts then gets connection-reset
  in a loop.
- **Healthcheck never succeeds** — the image must ship `curl`. Pins in
  `.env` are `2.14.x` images that do. First boot can take a minute.

## Local `/api/v1/info/status` fails but the container says "running"

First boot is a Java start.

- Check the port is on loopback: `ss -ltn | grep 8103`. `127.0.0.1:8103`
  is Stirling; the tailnet address is **tailscaled's** Serve frontend.
  `0.0.0.0:8103` is the one that would be wrong.
- `{"status":"UP"}` is the healthy body. `"DOWN"` or HTML means the
  probe hit the UI instead of the API — confirm the path includes
  `/api/v1/info/status`.

## UI loads, assets are mixed-content / CORS fails

- `SYSTEM_FRONTENDURL` in `.env` must be the tailnet HTTPS URL, no
  trailing slash. Drift is warned on every `./setup.sh` run; the file
  is not rewritten.
- Serve must send `X-Forwarded-Proto: https`. Compose sets
  `SERVER_FORWARD_HEADERS_STRATEGY=native` so Spring honours it.

## `/` redirects to `/login` / default `admin`/`stirling`

**Treat this as an incident.** That pair is in Stirling's own docs.

`SECURITY_ENABLELOGIN=false` in `.env` is what this deploy uses. Confirm
the container sees it:

```bash
docker compose --project-directory . exec stirling-pdf \
  printenv SECURITY_ENABLELOGIN
```

If that is empty or `true`, the env file was edited after first boot
without a recreate: `docker compose --project-directory . up -d
--force-recreate`. If you *want* login, set a new
`SECURITY_INITIALLOGIN_PASSWORD` (not `stirling`) before turning it on.

## Conversions fail / OCR missing a language

Standard image includes English tessdata. Extra languages go in
`~/services/stirling-pdf/tessdata`. Huge Office conversions want the
`-fat` tag — bump `STIRLING_PDF_VERSION` to `2.14.3-fat` only if you
have the disk and RAM.

## Nuke and pave

Use `teardown.sh`, not a hand recipe: it unpublishes only this service's
Serve port (and only if Serve really points it here), runs `compose down`,
and refuses to delete a data dir outside `~/services/`.

```bash
cd ~/dev/setup-server/services/stirling-pdf
./teardown.sh            # remove, keep data + .env (the launcher's Remove)
./teardown.sh --purge    # also delete STIRLING_DATA and .env; type the name
./setup.sh               # back, fresh if you purged
```

There is no undo for `--purge`. From a terminal, pause the `stirling-pdf`
monitor in Uptime Kuma first, or it pages; the launcher's Remove does that.
