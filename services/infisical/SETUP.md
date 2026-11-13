# infisical — self-hosted secrets manager

Env vars, API keys and certs for projects on this box, behind the tailnet:
`https://homeserver.tail-name.ts.net:8110`. The machine-side counterpart to
vaultwarden (which is passwords for humans; Infisical is secrets for apps
and pipelines).

Chosen over Infisical Cloud (secrets leave the tailnet) and over `.env`
files floating in every repo. **Not a substitute for vaultwarden** — they
store different things.

## Architecture

```
  laptop / CI on the tailnet
            │  https://homeserver.tail-name.ts.net:8110
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8110
            ▼
   ┌────────────────────────────────────────────┐
   │ container: infisical                       │
   │   infisical/infisical:v0.167.6             │
   │   Node app                  :8080          │
   └──────────────┬─────────────┬───────────────┘
                  │ compose network
          ┌───────┴───┐   ┌─────┴──────┐
          ▼           ▼   ▼            ▼
   infisical-db          infisical-redis
   postgres:16.15-alpine redis:7.4-alpine
   vol infisical-postgres vol infisical-redis
   (THE VAULT)           (cache + queue)
```

Postgres and Redis are unpublished — they only answer on the compose
network. Marker dir `~/services/infisical` (launcher "installed" +
`.bootstrapped` marker); the vault itself is the named volume
`infisical-postgres`.

`services/infisical/.env` — ports, image pins, `ENCRYPTION_KEY`,
`AUTH_SECRET`, `POSTGRES_PASSWORD`, admin credentials and the
`INFISICAL_ADMIN_TOKEN` machine identity (gitignored, mode 600).

## Security model

Loopback + Tailscale Serve. No LAN bind, no SMTP (so no email
verification, MFA codes or invites — see TROUBLESHOOT for adding it).
Accounts are Infisical's own; the tailnet only decides who can reach the
login page.

First super-admin is seeded from `.env` via `POST /api/v1/admin/bootstrap`
— the response's machine-identity token (instance-admin on the API) is
written back to `.env` as `INFISICAL_ADMIN_TOKEN`, and since `v0.162.8`
the instance closes public signup itself the moment bootstrap succeeds.
If bootstrap fails, the script warns loudly: the signup page is still
open and the first account created becomes the admin.

**The two things that are the vault:**
- `infisical-postgres` — every secret at rest, encrypted.
- `ENCRYPTION_KEY` in `.env` — the key that encrypts them. Rotating it,
  or losing it while the database survives, makes every stored secret
  unreadable. Back up BOTH.

## What the script does

1. Preflight: not root, Docker daemon, Compose v2, Tailscale Running,
   MagicDNS name, numeric ports.
2. Write `.env` if absent: generated `ENCRYPTION_KEY` (16 bytes hex),
   `AUTH_SECRET`, `POSTGRES_PASSWORD`, `INFISICAL_ADMIN_PASSWORD`,
   `SITE_URL` = the tailnet HTTPS URL. Never overwritten.
3. `docker compose up -d` (db + redis health-gated).
4. Wait on `GET /api/status`.
5. `POST /api/v1/admin/bootstrap` — super-admin + org "homeserver";
   appends `INFISICAL_ADMIN_TOKEN` to `.env` and drops the marker at
   `~/services/infisical/.bootstrapped`. Skipped on re-runs once the
   marker exists; an "already bootstrapped" answer from the API is
   treated as success.
6. `tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$LOCAL_PORT`.
7. End-to-end HTTPS check on `/api/status`.

```bash
cd services/infisical && ./setup.sh     # idempotent; rerun to upgrade/repair
INFISICAL_ADMIN_EMAIL=you@x.com ./setup.sh   # first run only; .env wins after
```

## Client

- **Browser**: the URL above, `INFISICAL_ADMIN_EMAIL` /
  `INFISICAL_ADMIN_PASSWORD` from `.env`.
- **CLI/API**: `INFISICAL_ADMIN_TOKEN` is a machine identity with
  instance-admin scope — `infisical login --method=token`, or
  `Authorization: Bearer` against `https://<host>.ts.net:8110/api/`.
  It is shown by bootstrap exactly once; it only lives in `.env`.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/infisical ps
docker compose --project-directory ~/dev/setup-server/services/infisical logs -f
docker compose --project-directory ~/dev/setup-server/services/infisical restart
```

Upgrade: bump `INFISICAL_VERSION` in `.env`, then `./setup.sh`. Dump the
database first — schema migrations are one-way.

Backup target (nothing on this box backs itself up):

```bash
docker compose --project-directory ~/dev/setup-server/services/infisical \
  exec -T db pg_dump -U infisical infisical > infisical-$(date +%F).sql
# AND keep a copy of ENCRYPTION_KEY + AUTH_SECRET from .env — the dump is
# ciphertext without them.
```

Remove: `./teardown.sh` (or Remove in the launcher) unpublishes every
Serve port pointing at `:LOCAL_PORT` and runs `compose down`; the volumes
and `.env` stay, so `./setup.sh` brings it back. `./teardown.sh --purge`
also drops both volumes (`down -v`), the `INFISICAL_DATA` dir and `.env`,
after you type `infisical`. The purge prints the backup recipe before it
asks — there is no undo.
