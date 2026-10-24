# umami — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?              ->  publish?        ->  client?
docker ps          curl :8106                  serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/umami
docker compose --project-directory . ps
curl -s http://127.0.0.1:8106/api/heartbeat
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 umami
```

- **`UMAMI_DB_PASSWORD missing from .env`** — `.env` is incomplete. Move
  it aside and re-run `./setup.sh`.
- **Prisma migrations hang** — Postgres not healthy. `docker compose
  logs db`. First boot can take a minute.
- **`TWO_FACTOR_ENCRYPTION_KEY` invalid** — must be 64 hex chars.
  Regenerating it disables existing 2FA enrollments.

## Local `/api/heartbeat` fails but the container says "running"

- Check the port is on loopback: `ss -ltn | grep 8106`. `127.0.0.1:8106`
  is Umami; `0.0.0.0:8106` is the one that would be wrong.
- Heartbeat body is a short `ok`. HTML means the probe hit the UI.

## Still `admin` / `umami`

**Treat this as an incident.** That pair is in Umami's own docs.

setup.sh rotates it on first boot. If the rotation POST failed, the
script warned. Change the password in Settings immediately. Changing
`UMAMI_ADMIN_PASSWORD` in `.env` after first boot does not rotate the
live password.

## Tracker snippet 404 / CORS from a public site

This deploy is tailnet-only. A page on the public internet cannot POST
to `https://…ts.net:8106`. That is the security model, not a bug. To
count public traffic you would need a different publish path — do not
bind `0.0.0.0` as a shortcut.

## Nuke and pave

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, runs `compose down`, and refuses to delete a
marker dir that is not really inside `~/services/`. Postgres lives in the
named volume `umami-postgres`, not under `~/services/umami`, so only
`--purge` (which runs `down -v`) removes the analytics data.

```bash
cd ~/dev/setup-server/services/umami
./teardown.sh            # remove, keep volume + .env (the launcher's Remove)
./teardown.sh --purge    # also delete the Postgres volume, marker dir and .env; type the name
./setup.sh               # back, fresh if you purged (new admin password)
```

There is no undo for `--purge`. Dump first if you want the data:
`docker compose --project-directory . exec -T db pg_dump -U umami umami > umami.sql`.
