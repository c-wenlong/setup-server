# hermes-agent — Troubleshooting

Work the layers in order: container → local HTTP → Serve publish → client.
Each section names the layer it belongs to.

## Container won't start / keeps restarting

```bash
docker compose --project-directory services/hermes-agent ps
docker compose --project-directory services/hermes-agent logs gateway
```

- **`HERMES_DASHBOARD_PASSWORD missing from .env`** — `.env` is incomplete.
  Re-run `./setup.sh`; the file is only written when absent, so a
  hand-emptied value needs the key added back.
- **`HERMES_DATA` permission errors in the logs** — `HERMES_UID`/`HERMES_GID`
  in `.env` must match the owner of the data dir. `ls -ln ~/services/hermes-agent`
  shows the numbers; fix `.env` or `chown -R` the dir.
- **port 9119 or 8642 already in use** — something else claimed it
  (`sudo ss -ltnp | grep -E '9119|8642'`). Note `:9119` can collide with a
  *native* Hermes dashboard if one is running — check
  `systemctl --user status hermes-gateway.service` too.
- **image pull fails** — `docker pull nousresearch/hermes-agent:v0.22.5`
  by hand to see the real error.

## Dashboard 401s / won't accept the password

Anonymous requests getting a **401 is correct** — basic auth sits in front
of every page once the container binds non-loopback.

- The credentials are `HERMES_DASHBOARD_USERNAME` /
  `HERMES_DASHBOARD_PASSWORD` in `services/hermes-agent/.env`, not any
  account you created inside Hermes.
- Changing the password in `.env` and re-running `./setup.sh` rotates it;
  `HERMES_DASHBOARD_SECRET` invalidates old sessions at the same time.

## Dashboard up but the API won't answer on :8642

- `/health` needs no key: `curl http://127.0.0.1:8642/health`.
- Everything else needs the key:
  `curl http://127.0.0.1:8642/v1/models -H "Authorization: Bearer $API_SERVER_KEY"`.
- The API starts after the dashboard in the same container; setup warns
  rather than fails when it is slow — check `docker compose logs gateway`.

## `tailscale serve` errors during setup

- **`serve is not enabled` / permission denied** — first publish needs the
  tailnet operator (setup runs `sudo tailscale set --operator=$USER` itself
  on Linux) or an admin approval: it prints a link, approve, press Enter.
- **`https=9119 already in use`** — another service owns that Serve port.
  `tailscale serve status` shows which; pick another `HTTPS_PORT`.

## HTTPS URL doesn't load from a client

- `tailscale serve status | grep -A2 9119` should show
  `proxy http://127.0.0.1:9119`.
- The local hop must work first (authenticated):
  `curl -u admin:$PASS http://127.0.0.1:9119/` with `$PASS` from `.env`.
- Remember the browser will ask for the basic-auth credentials — a saved
  wrong password looks like the service being down.

## Two Hermes installs at once

This container and a native `~/.hermes` install are independent: different
data, config, channels and ports. If the dashboard you opened shows none of
the sessions you expected, you are probably looking at the *other* one —
the native install's own dashboard/API lives on its own ports. Stopping or
purging this container never touches `~/.hermes` or `hermes-gateway.service`.

## Nuke and pave

```bash
cd services/hermes-agent
./teardown.sh --purge     # type "hermes-agent" to confirm
./setup.sh
```

`--purge` deletes `~/services/hermes-agent/data` (config, keys, sessions,
skills, memories) and `.env`, after stopping the container and unpublishing
only the Serve ports that point at this service. Without `--purge`,
teardown stops the container and keeps everything — `./setup.sh` brings
the same deployment back.
