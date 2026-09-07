# Seafile — Troubleshooting

Layered triage, top-down:

```
1. containers running?  →  2. local web UI?  →  3. serve config?  →  4. client/tailnet?
```

Quick triage (run in this directory):

```sh
docker compose --project-directory . ps          # all 3 running, seafile healthy?
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/   # expect 200/30x
tailscale serve status                           # :8443 -> 127.0.0.1:8081?
./tests/run-tests.sh --live                      # all of the above at once
```

## Containers won't start / keep restarting

```sh
docker compose --project-directory . logs --tail 100 seafile
docker compose --project-directory . logs --tail 50 db
```

- **`Variable is not set or empty`** — `.env` missing or incomplete. Re-run
  `./setup.sh` (a missing `.env` is regenerated; an existing one is never
  touched).
- **DB unhealthy / access denied** — if you deleted `~/seafile/mysql` but kept
  `.env` (or vice versa), passwords no longer match the database. Either
  restore the pair together or nuke-and-pave (below).
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
  in `~/seafile/data/seafile/conf/seahub_settings.py`, then restart.
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
  the :443 entry is code-server, :8443 must exist separately.

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
du -sh ~/seafile/data                    # what Seafile actually uses
docker exec seafile /opt/seafile/seafile-server-latest/seaf-gc.sh   # reclaim
```

Reduce per-library history retention in the web UI (library → History
Settings) if photo backup growth outpaces the disk. Server disk: check
`df -h /` — this box has ~155 GB free at deploy time.

## Nuke and pave (destroys all Seafile data)

```sh
docker compose --project-directory . down -v
rm -rf ~/seafile .env
./setup.sh
```

## Restore from backup

1. `./setup.sh` on the new machine, then `docker compose down`
2. Restore `~/seafile/data`, `~/seafile/mysql` (or replay the mysqldump into
   a fresh DB), and the backed-up `.env` — all three must be from the same
   backup set
3. `docker compose --project-directory . up -d`
