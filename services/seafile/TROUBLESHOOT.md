# Seafile — Troubleshooting

Layered triage, top-down:

```
1. containers running?  →  2. local web UI?  →  3. serve config?  →  4. client/tailnet?
```

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps          # all 3 running, seafile healthy?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/        # 302
curl -s http://127.0.0.1:8081/api2/ping/                               # "pong"
tailscale serve status                           # :8443 -> 127.0.0.1:8081?
./tests/run-tests.sh --live                      # all of the above at once
```

`/api2/ping/` needs the **trailing slash** — `/api2/ping` answers 301, and `/`
answers 302. Both are healthy; neither is a useful "is the app alive" signal
on its own, which is why Kuma probes the slash form.

If `docker` says "permission denied", you are not in the docker group in
*this shell*, and every container check will report a healthy stack as down.
Re-run the whole thing as `sg docker -c './tests/run-tests.sh --live'`. Unlike
immich's and forgejo's, this live suite does **not** detect the missing group
for you — it just goes red.

**State lives in `~/services/seafile/`**: `data/` (the chunked object store
and `conf/`) and `mysql/`. `SEAFILE_VOLUME` / `SEAFILE_MYSQL_VOLUME` in `.env`
are authoritative. Older notes may still say `~/seafile/`; that path has not
existed since the 2026-09-07 layout change, so any command quoting it is a
silent no-op.

## Containers won't start / keep restarting

```sh
docker compose --project-directory . logs --tail 100 seafile
docker compose --project-directory . logs --tail 50 db
```

- **`Variable is not set or empty`** — `.env` missing or incomplete. Re-run
  `./setup.sh` (a missing `.env` is regenerated; an existing one is never
  touched).
- **DB unhealthy / access denied** — if you deleted `~/services/seafile/mysql`
  but kept `.env` (or vice versa), passwords no longer match the database.
  Either restore the pair together or nuke-and-pave (below).
- **Port already allocated** — something else owns 8081:
  `ss -ltnp | grep 8081`. Redeploy with `LOCAL_PORT=9081 ./setup.sh` after
  editing `LOCAL_PORT` in `.env`, then re-run
  `tailscale serve --bg --https=8443 http://127.0.0.1:9081`.
- **First start takes minutes** — image pull (~1 GB) + DB init are one-time;
  `docker compose logs -f seafile` shows progress. Don't interrupt the first
  boot: a killed DB init is the classic source of corrupt state.

## Web UI up locally but broken (login loops, CSRF errors, wrong links)

- Check `SEAFILE_SERVER_HOSTNAME` in `.env` — it must be exactly
  `<host>.<tailnet>.ts.net:8443` (with port) and `SEAFILE_SERVER_PROTOCOL=https`.
  If you changed hostname/port after first init, also update
  `SERVICE_URL`/`FILE_SERVER_ROOT` in the web UI (System Admin → Settings) or
  in `~/services/seafile/data/seafile/conf/seahub_settings.py`, then restart.
- Uploads/downloads failing while browsing works usually means
  `FILE_SERVER_ROOT` doesn't match the public URL.

## Tailscale layer

Same failure modes as code-server (see `../code-server/TROUBLESHOOT.md` for
the full list): operator not set → `sudo tailscale set --operator=$USER`;
first HTTPS request slow while the cert mints; client must be on the tailnet.
Specific to this service:

- Serve config for :8443 lost after tailscaled restart:
  `tailscale serve --bg --https=8443 http://127.0.0.1:8081`
- Browser says connection refused on :8443 — check `tailscale serve status`;
  the :443 entry is code-server (at `/`) plus the launcher (at `/home/`), and
  :8443 must exist separately.
- To remove just this mapping: `tailscale serve --https=8443 off`.
  ⚠️ **Never `tailscale serve reset`** — it clears every mapping on the
  *whole node*, so every service on this box goes dark at once and each
  one's `setup.sh` has to be re-run. `off` is absent from `serve --help` but
  is what Tailscale prints itself after a successful `serve`, and is the only
  single-port removal.
- Every Kuma monitor red at the same time is this, not a dozen simultaneous
  outages — Kuma probes tailnet HTTPS URLs, so tailscaled going down takes the
  whole dashboard with it. Check `tailscale serve status` before anything else.

## Login problems

- **The password in `.env` is rejected** — `INIT_SEAFILE_ADMIN_PASSWORD` is
  only read at *first init*; it is not kept in sync afterwards. A password
  changed in the web UI leaves `.env` stale, and `.env` is what every script
  and any restore reads. **This has already happened here**: DIRECTORY.md
  records (2026-09-07) that Kai's admin password drifted from `services/seafile/.env`
  and the stored copy no longer authenticates. Mirror the real one back into
  `.env`, or reset it and then mirror:

  ```sh
  docker exec -it seafile /opt/seafile/seafile-server-latest/reset-admin.sh
  ```

  Check a password without touching the browser (one attempt — Seafile freezes
  an account after repeated failures):

  ```sh
  curl -s -X POST http://127.0.0.1:8081/api2/auth-token/ \
    -d "username=$(sed -n 's/^INIT_SEAFILE_ADMIN_EMAIL=//p' .env)" \
    -d "password=$(sed -n 's/^INIT_SEAFILE_ADMIN_PASSWORD=//p' .env)"
  ```

  A `{"token": …}` means `.env` is correct; `non_field_errors` means it drifted.
- **`manimkc@kaichen.local` is a Seafile admin** — known, and deliberate only
  by accident: self-demotion via the API is rejected, so it has to be demoted
  in the web UI. Tracked in DIRECTORY.md; not a symptom of anything broken.

## Client issues

- **iOS app can't connect** — server URL must include `https://` and `:8443`;
  Tailscale must be connected on the phone (check it can open the URL in
  Safari first).
- **Camera upload not running** — iOS backgrounding: open the app
  periodically, and in app settings enable auto-upload + background refresh.
- **Sync client conflicts** — Seafile renames conflicting copies
  (`file (SFConflict ...)`); resolve manually, don't disable sync.

## Disk space

Deleted files linger in library history and unreferenced blocks:

```sh
du -sh ~/services/seafile/data           # what Seafile actually uses
docker exec seafile /opt/seafile/seafile-server-latest/seaf-gc.sh   # reclaim
```

Reduce per-library history retention in the web UI (library → History
Settings) if photo backup growth outpaces the disk. Server disk: check
`df -h /` — this box had ~155 GB free at deploy time, and Immich's library
now shares it.

Note that **Seafile camera upload was never enabled** and should stay that
way: Immich owns phone photo backup on this box. Running both stores every
photo twice.

## Nuke and pave (destroys all Seafile data)

```sh
docker compose --project-directory . down -v
rm -rf ~/services/seafile .env
tailscale serve --https=8443 off
./setup.sh
```

## Restore from backup

1. `./setup.sh` on the new machine, then `docker compose down`
2. Restore `~/services/seafile/data`, `~/services/seafile/mysql` (or replay
   the mysqldump into a fresh DB), and the backed-up `.env` — all three must
   be from the same backup set, or the generated DB password will not match
3. `docker compose --project-directory . up -d`
