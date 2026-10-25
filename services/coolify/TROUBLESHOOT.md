# coolify — Troubleshooting

Triage in layers, outermost failure first:

```
containers up?  ->  local API?         ->  publish?        ->  client?
docker ps           curl :8101             serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/coolify
docker compose --project-directory . ps
curl -s http://127.0.0.1:8101/api/health
curl -s http://127.0.0.1:6001/ready
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## Containers won't start / keep restarting

```bash
docker compose --project-directory . logs --tail=100
```

- **`COOLIFY_SSH missing from .env` / `variable is not set`** — `.env` is
  incomplete. `docker compose --project-directory . config` shows which
  `${…:?}` guard fired. Do not hand-write a partial `.env`; move it aside
  and re-run `./setup.sh` (that writes a new one — existing passwords
  would be lost, so copy secrets out first).
- **Postgres `pg_isready` never succeeds** — `DB_USERNAME` /
  `DB_PASSWORD` in `.env` must match the volume. A regenerated `.env`
  against an old `coolify-db` volume will auth-fail forever. Either put
  the old password back or `docker volume rm coolify-db` (destroys the
  database).
- **Redis healthcheck failing** — the image requires a password
  (`--requirepass`). Compose sets `REDISCLI_AUTH` from `REDIS_PASSWORD`
  so `redis-cli ping` authenticates. If you removed that env, the probe
  is `NOAUTH` and Coolify never becomes healthy.
- **Permission errors on `/var/www/html/storage/app/ssh`** — uid 9999
  inside the container cannot read `~/services/coolify/ssh`. `setup.sh`
  grants that with `setfacl` (or `chmod a+rwx` where ACL is missing).
  Re-run `./setup.sh`.
- **Exit 137 (OOM-killed)** — ollama with a model loaded claims ~5 GB.
  `docker stats` and `free -h`. Caps in compose are 768/256/128/256 MiB;
  if the dashboard is still the victim, stop another service first.

## Local `/api/health` fails but `coolify` says "running"

First boot runs Laravel migrations and can take a few minutes.
`docker compose --project-directory . logs -f coolify` shows progress.

- Check the port is on loopback: `ss -ltn | grep 8101`. `127.0.0.1:8101`
  is Coolify; the tailnet address is **tailscaled's** Serve frontend
  (HTTPS port == local port here). `0.0.0.0:8101` is the one that would
  be wrong.
- `APP_KEY` missing or truncated is a 500, not a startup failure. The
  container looks healthy and every page is broken. `grep ^APP_KEY=
  .env` must start with `base64:`.

## Dashboard loads, assets / login cookies are wrong

Coolify already trusts every proxy (`TrustProxies` `$proxies = '*'`), so
Tailscale Serve's `X-Forwarded-Proto: https` should mark cookies Secure
and keep asset URLs on https. If the page is mixed-content:

- `APP_URL` in `.env` must be the tailnet HTTPS URL, no trailing slash.
  Drift is warned on every `./setup.sh` run; the file is not rewritten.
- Hard-refresh. Laravel caches config in the container.

## `/register` is still the "create root user" form

**Treat this as an incident.** Whoever submits that form owns the
instance, and on a Coolify box that is root-equivalent over Docker.

`ROOT_USERNAME` / `ROOT_USER_EMAIL` / `ROOT_USER_PASSWORD` in `.env` are
what the first boot seeds. Password policy is mixed-class (upper, lower,
digit, special) — a hex-only password is rejected and the form stays
open. Create the account immediately, then mirror the password back into
`.env`.

## Live logs / realtime do not stream

Soketi is on `127.0.0.1:6001` and should be Serve-published on the same
number. `curl -s http://127.0.0.1:6001/ready` and
`tailscale serve status` for `:6001`.

`.env` should have `PUSHER_HOST=<tailnet DNS>`, `PUSHER_PORT=6001`,
`PUSHER_SCHEME=https`, and `PUSHER_BACKEND_HOST=coolify-realtime` so the
PHP backend does not TLS-handshake the plaintext Soketi socket (Coolify
issue #10637).

## Coolify cannot SSH to this box / localhost server is red

- Key at `~/services/coolify/ssh/keys/id.$USER@host.docker.internal`
- Matching line in `~/.ssh/authorized_keys` (comment `coolify`)
- SSH user in the UI is **your username, not root**
- `ssh -o BatchMode=yes localhost true` from this box works
- You can `docker ps` without sudo (`sg docker -c docker ps`)

`setup.sh` generates the key and appends the pubkey; it does not enable
root SSH and does not create `/data/coolify`.

## "I started the Coolify Proxy and now :80/:443 are on the LAN"

Stop it. Upstream Traefik binds every interface. This deploy does not
start that proxy and must not:

```bash
docker ps --filter name=coolify-proxy
docker stop coolify-proxy
```

Then confirm with `ss -ltn | grep -E ':80|:443'` that only tailscaled
owns the tailnet address, not `0.0.0.0`.

## Client can open the tailnet URL but login fails

Mirror the UI password back into `ROOT_USER_PASSWORD` in `.env` if you
changed it. There is no CLI password-reset in this wrap; use Coolify's
own "forgot password" only if SMTP is configured (it is not).

## Nuke and pave

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at the dashboard or Soketi, runs `compose down` on Coolify's own
four containers, and leaves every app Coolify deployed alone (it names
them). `--purge` refuses while Coolify still holds apps, databases or
services you deployed through it; delete those in the dashboard first.
While those apps (or coolify-proxy) run, Docker cannot remove the `coolify`
network: teardown says "Docker kept the 'coolify' network" and carries on.
`docker network rm coolify` once they are gone.

Back up before a purge. It deletes the `coolify-db` volume and `.env`
(`APP_KEY`), and one without the other is useless:

```bash
cd ~/dev/setup-server/services/coolify
docker compose --project-directory . exec -T postgres \
  pg_dump -U coolify coolify > ~/coolify-$(date +%F).sql
cp .env ~/coolify-$(date +%F).env
```

Then:

```bash
./teardown.sh            # remove, keep volumes, ~/services/coolify, .env and the SSH key
./teardown.sh --purge    # also delete coolify-db, coolify-redis, Coolify's dirs under
                         # ~/services/coolify, .env, and exactly the key line setup.sh
                         # added to ~/.ssh/authorized_keys; type "coolify"
./setup.sh               # back, fresh if you purged
```

Deleting `.env` rotates `APP_KEY`. A restored `coolify-db` volume then
contains ciphertext that will not decrypt — that is not a repair, it is
a new instance.
