# infisical — Troubleshooting

Triage in layers, outermost failure first:

```
containers up?  ->  local API?              ->  publish?        ->  client?
docker ps          curl :8110                  serve status        browser
```

Quick triage:

```bash
cd ~/dev/setup-server/services/infisical
docker compose --project-directory . ps
curl -s http://127.0.0.1:8110/api/status
tailscale serve status
./tests/run-tests.sh --live
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`.

## A container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 infisical
docker compose --project-directory . logs --tail=100 db
```

- **`ENCRYPTION_KEY missing from .env`** (or `AUTH_SECRET`,
  `POSTGRES_PASSWORD`, `SITE_URL`) — `.env` is incomplete. These use
  `${VAR:?}` so Compose refuses rather than boot half-configured. Fix by
  **restoring the missing line**, not by moving `.env` aside: a fresh
  `.env` would generate a *new* `POSTGRES_PASSWORD` (app can no longer
  reach the existing volume) and a *new* `ENCRYPTION_KEY` (every stored
  secret becomes unreadable). Recover the original values from your
  backup of `.env`; only move `.env` aside when the database is still
  empty anyway.
- **`ENCRYPTION_KEY must be 16 bytes`** on app boot — it must be exactly
  32 hex chars. Regenerate: `openssl rand -hex 16`. ⚠️ If the database
  already has secrets, a new key makes them unreadable — restore the old
  key instead.
- **db unhealthy** — `docker logs infisical-db`. A corrupt
  `infisical-postgres` volume from an interrupted first init is fixed by
  `compose down -v` + `./setup.sh` **only while the vault is still
  empty** — that deletes everything otherwise.

## Local `/api/status` fails but the container says "running"

First boot runs schema migrations before the HTTP listener comes up —
the loop waits ~10 min for it. Past that:

- Check the port is on loopback: `ss -ltn | grep 8110`. `127.0.0.1:8110`
  is Infisical; the tailnet address is **tailscaled's** Serve frontend.
  `0.0.0.0:8110` is the one that would be wrong.
- `{"message":"Infisical is up and running"}` is the healthy body.

## Signup page is open / cannot log in

`POST /api/v1/admin/bootstrap` is what seeds `INFISICAL_ADMIN_*` and
closes signup. If it failed, setup.sh warned and left no
`~/services/infisical/.bootstrapped` marker — fix by hand:

```bash
curl -s -X POST http://127.0.0.1:8110/api/v1/admin/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@x.com","password":"…","organization":"homeserver"}'
```

The first account created becomes the super-admin either way — creating
one through the signup UI also closes the window. If the marker is
missing but the instance is bootstrapped, re-running `./setup.sh` writes
the marker without touching the admin.

Changing `INFISICAL_ADMIN_PASSWORD` in `.env` after bootstrap does not
rotate the live password — do that in the UI. Lost it entirely? There is
no reset without SMTP; the recovery path is a new admin identity from a
still-logged-in session, or `--purge` and start over (which deletes the
vault too).

## Invites / MFA emails never arrive

No SMTP is configured — email-dependent features are off by design. To
enable: add `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
`SMTP_FROM_ADDRESS`, `SMTP_FROM_NAME` to `.env`, add the same keys to the
`environment:` block in `docker-compose.yml`, re-run `./setup.sh`.

## SITE_URL drift / links point at the wrong URL

`SITE_URL` is baked into `.env` at first deploy and every login redirect
is built from it. If the tailnet name or port changed, setup.sh warns
with the correct value but does not rewrite the file — fix the line and
re-run.

## Nuke and pave

Use `teardown.sh`, not a hand recipe: it unpublishes only the Serve ports
that point at this service, runs `compose down`, and refuses to delete a
marker dir that is not really inside `~/services/`.

```bash
cd ~/dev/setup-server/services/infisical
./teardown.sh            # remove, keep the volumes + .env (the launcher's Remove)
./teardown.sh --purge    # also drop BOTH volumes, INFISICAL_DATA and .env; type the name
./setup.sh               # back, fresh if you purged
```

⚠️ `--purge` on Infisical is harsher than on most services: it deletes
`infisical-postgres` (every secret, user and org) **and** `.env` (the
`ENCRYPTION_KEY` that decrypts them) — there is nothing left to recover.
`pg_dump` first, and copy `ENCRYPTION_KEY`/`AUTH_SECRET` out of `.env`;
the script prints that recipe before it asks for the name. From a
terminal, pause the `infisical` monitor in Uptime Kuma first, or it
pages; the launcher's Remove does that.
