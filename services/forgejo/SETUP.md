# forgejo — self-hosted Git forge (a GitHub you own)

Repositories, issues, pull requests, releases, wikis, Actions-compatible CI
and an API, on the tailnet:
`https://homeserver.tail-name.ts.net:3000`.

Chosen over Gitea, which is the same codebase up to 2022. In 2022 a
for-profit company took control of the Gitea trademark and infrastructure;
Forgejo is the fork the community made in response, and it is stewarded by
**Codeberg e.V.**, a German nonprofit. Two practical consequences, not just
governance aesthetics:

- Migration runs **Gitea → Forgejo, and not back**. Forgejo can import a
  Gitea instance; Gitea cannot import a modern Forgejo one. So if you are
  going to pick one without having tried either, Forgejo is the choice that
  keeps a door open.
- Forgejo ships LTS releases with published end-of-support dates (below),
  which is what makes a pinned tag a deliberate decision rather than a guess.

Also considered: GitLab CE (needs ~4 GB RAM before it does anything —
a non-starter on this box), and Gogs (smaller, but effectively
single-maintainer and behind on security fixes).

## Architecture

One container. That is the whole architecture, and it is the point:

```
  phone / laptop on the tailnet
            │  https://homeserver.tail-name.ts.net:3000
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:3000
            ▼
   ┌────────────────────────────────┐
   │ container: forgejo             │
   │   codeberg.org/forgejo/forgejo │
   │   :15  (LTS)                   │
   │                                │
   │   web + API      :3000         │
   │   SQLite         (in-process)  │
   │   built-in SSH   DISABLED      │
   └────────────┬───────────────────┘
                │ bind mount
                ▼
      ~/services/forgejo/data   →  /data
```

State lives under `~/services/forgejo`:

```
~/services/forgejo/
  data/                    # FORGEJO_DATA — the entire instance
    git/repositories/      #   bare repos, one dir per owner
    git/lfs/               #   Git LFS objects
    gitea/gitea.db         #   SQLite: users, issues, PRs, settings
    gitea/conf/app.ini     #   DERIVED from env on every start — see below
    gitea/avatars/         #   user + repo avatars
  .admin-created           # marker: the admin bootstrap already ran
```

**`app.ini` is a derived file, not the source of truth.** The image's
entrypoint folds every `FORGEJO__<section>__<KEY>` environment variable into
it on *every* container start. Editing `app.ini` by hand works right up until
the next `docker compose up`, which silently reverts it. Change
`docker-compose.yml` or `.env` and re-run `./setup.sh` instead.

## Why v15 and not v16

`docker-compose.yml` pins `codeberg.org/forgejo/forgejo:15` (today: **15.0.8**).

| Line | Status | Supported until |
|---|---|---|
| **15** | **LTS** | **2027-07-15** |
| 16 | regular release | 2026-10-29 |

Newer is worse here. Forgejo's regular releases are supported until roughly
the next one lands; v16 goes out of support in about seven weeks, at which
point staying on it means chasing a release every couple of months on a box
nobody is watching. v15 is the LTS: security fixes for another year and a
half, no feature churn. Bump `FORGEJO_VERSION` in `.env` only when v18 (the
next LTS) exists — and read the release notes first, because Forgejo majors
do run database migrations.

## Why SQLite and not Postgres

The upstream Compose example runs a Postgres sidecar. This one does not.

- SQLite is **compiled into the official image** (`sqlite`,
  `sqlite_unlock_notify` build tags) — it is a supported configuration, not
  a downgrade path.
- This box has 7.7 GB of RAM shared with ollama (~5 GB with a model loaded),
  Immich, Seafile and the rest. Forgejo on SQLite measures **~100 MiB idle,
  ~120 MiB in use** (`docker stats forgejo`). A Postgres container would
  roughly double that for a forge with one user.
- SQLite's real limit is *write* concurrency, and a single-user forge has
  essentially none. The failure mode people hit ("database is locked")
  belongs to multi-user CI hammering the DB, which is not this.
- It is one file. `~/services/forgejo/data/gitea/gitea.db` copied with the
  container stopped **is** a valid backup — no `pg_dump`, no
  matching-server-version dance.

If this ever grows real concurrent users, Forgejo can migrate SQLite →
Postgres with `forgejo dump` / `forgejo restore`. That door stays open.

## Why the built-in SSH server is off

`FORGEJO__server__DISABLE_SSH: true`, and no SSH port is published.

- Host port 22 is the box's own `sshd`. Forgejo's SSH server would need a
  different host port (2222, say), which every clone URL then has to carry.
- Tailscale Serve fronts **HTTPS**; SSH would need a separate
  `tailscale serve --tcp` mount, i.e. a second publish path to maintain and
  a second thing to forget when debugging.
- HTTPS clones work fine on a tailnet, and the tailnet is already the auth
  boundary. Access tokens beat managing a second key trust store.

**To turn it on later**, `docker-compose.yml` carries the recipe next to the
commented-out port line:

1. uncomment `- '127.0.0.1:${FORGEJO_SSH_HOST_PORT:-2222}:22'`
2. in `.env`: `FORGEJO_DISABLE_SSH=false`, `FORGEJO_START_SSH_SERVER=true`,
   `FORGEJO_SSH_HOST_PORT=2222`
3. `tailscale serve --bg --tcp=2222 tcp://127.0.0.1:2222`
4. `./setup.sh` — recreates the container and re-derives `app.ini`

Then add your public key in Settings → SSH / GPG Keys. Note that existing
clone URLs do not change; SSH URLs simply start working alongside them.

## ⚠️ This box has no backup

Nothing on `homeserver` is backed up. That has been true for every
service here, but source code makes it sharper: a lost photo is a sad
memory, a lost repository is lost work with no other copy.

**GitHub stays canonical. Treat this instance as a mirror** until
`~/services/forgejo/data` is in a real backup job. Concretely:

- Push to GitHub *and* here, or set up a pull mirror (below) so Forgejo
  follows GitHub rather than the other way round.
- Do not make this the only home of anything, including private repos you
  are pushing here *because* they are private.
- The one-line cold backup, until something better exists:

  ```bash
  cd ~/dev/setup-server/services/forgejo
  docker compose --project-directory . stop
  tar czf ~/forgejo-$(date +%F).tgz -C ~/services/forgejo/data .
  docker compose --project-directory . start
  ```

  Then get that tarball **off this machine** — Seafile at `:8443` is one
  keystroke away and syncs to a device that is not this one.

## Security model

- **Tailnet-only.** The container publishes `127.0.0.1:3000` and nothing
  else; Tailscale Serve terminates TLS. Not reachable from the LAN or the
  internet. No firewall rule opens it, and none should.
- **The install wizard is locked.**
  `FORGEJO__security__INSTALL_LOCK: "true"` makes `/install` return **404**.
  This matters more than it sounds: a Forgejo with an open install page lets
  anyone who reaches it configure the instance — pick the admin account,
  point the database wherever. A deploy that serves `/install` is a failed
  deploy that looks successful, which is why `tests/run-tests.sh --live`
  asserts the 404 explicitly.
- **Registration is disabled** (`DISABLE_REGISTRATION: "true"`). Single-user
  instance; new accounts are created from the CLI, deliberately.
- **The admin account is created by `setup.sh` from the CLI**, before anyone
  can reach the instance — there is no window in which a stranger on the
  tailnet claims the admin slot by loading the page first.
- **Secrets** are generated into the gitignored `.env` (mode 600):
  `FORGEJO_ADMIN_PASSWORD` and `FORGEJO_SECRET_KEY`. `.env` is read by
  Compose for interpolation only — it is deliberately **not** passed as
  `env_file`, so the admin password never lands in the container's
  environment.
- `FORGEJO_SECRET_KEY` encrypts 2FA secrets and stored mirror/OAuth
  credentials. The image's default is empty, which falls back to a built-in
  key that is the same on every Forgejo install on earth. Changing it later
  makes everything already encrypted unreadable — generate once, leave alone.

⚠️ Same password-sync rule as every other service here: if you change the
admin password in the web UI, mirror it into `.env`. `setup.sh` finishes by
logging in with the `.env` copy, and **fails the deploy** if that login is
rejected rather than reporting success over a locked-out account.

### The `--must-change-password=false` gotcha

`setup.sh` creates the admin with:

```bash
docker exec -u git forgejo forgejo admin user create --admin \
  --username kai --password '<generated>' --email <mail> \
  --must-change-password=false
```

That last flag is **load-bearing — do not "clean it up"**. The Forgejo CLI
defaults new admin accounts to must-change-password. Without the flag the
account exists, the CLI reports success, the container is healthy, and the
generated password in `.env` is rejected at the login form: a deploy that
passes every check and locks you out. This is exactly why the final step of
`setup.sh` is an authenticated `GET /api/v1/user` with the `.env`
credentials, and why the live suite repeats it.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | systemd/launchd not used — Docker's restart policy handles boot | ✅ |
| Docker + Compose v2 | the one container | ✅ (incl. daemon reachability) |
| curl | health checks + the admin verification call | ✅ |
| Tailscale, logged in, MagicDNS | publishing, **and** `ROOT_URL` | ✅ (`BackendState` must be `Running`; DNS name must resolve) |
| python3 | password generation — optional, falls back to `/dev/urandom` | — |
| ≥ 10 GB free disk | repos, LFS objects, and repack headroom | ⚠️ warns |

No Postgres, no Redis, no reverse proxy of our own.

## Deploy

```bash
cd services/forgejo && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, `curl`, Docker daemon reachable, Compose v2,
   Tailscale `Running`, numeric ports.
2. **Resolve the tailnet name** — from `tailscale status --json`, *before*
   anything is written. `ROOT_URL` has to be baked into `.env` at creation
   time, because Forgejo builds every clone URL, redirect, webhook payload
   and API `html_url` from it. A wrong `ROOT_URL` does not error; it just
   hands out `localhost` links that nobody else can use.
3. **`.env`** — written only if absent, mode 600: generated
   `FORGEJO_ADMIN_PASSWORD` and `FORGEJO_SECRET_KEY` (32 hex each),
   `FORGEJO_DATA`, `FORGEJO_UID`/`GID` (so the bind mount stays writable
   from the host), `TZ` from `readlink /etc/localtime`, `FORGEJO_VERSION=15`,
   `FORGEJO_DOMAIN`/`FORGEJO_ROOT_URL`, and the SSH-off trio.
   On a re-run `.env` is the source of truth — an existing file is never
   rewritten, and a `LOCAL_PORT=` on the command line that disagrees with it
   is ignored with a warning rather than silently moving a live deployment.
4. **ROOT_URL drift check** — if the live tailnet name or HTTPS port no
   longer matches what `.env` says, it warns and prints the exact fix. It
   does **not** rewrite `.env`; that file belongs to you.
5. **Free-disk advisory**, then `docker compose up -d` (first run pulls
   ~130 MB).
6. **Wait for `/api/healthz`** — up to 3 minutes; first boot creates the
   SQLite schema.
7. **Admin account**, at most once, with two independent guards: the
   `.admin-created` marker means a normal re-run never even shells into the
   container, and if the marker is missing but the user is there, the CLI's
   `user already exists` is treated as success. (A run that died between
   creating the user and writing the marker recovers cleanly; a run that
   fails for any *other* reason still dies.)
8. **`tailscale serve --bg --https=3000 http://127.0.0.1:3000`**, with the
   operator-grant (`sudo tailscale set --operator=$USER`, first run only) and
   approval-link fallbacks.
9. **Verify** — HTTPS `/api/healthz`, then an authenticated
   `GET /api/v1/user` with the `.env` credentials. That one call proves three
   things at once: the generated password logs in, the account really is an
   admin, and `html_url` in the response is the tailnet address, i.e.
   `ROOT_URL` is right. Then it prints the URL, credentials, the push recipe
   and the backup caveat.

## Client side

The tailnet is the boundary, so a client is anything on the tailnet with git.

### Create a repository

Web UI → **+ → New Repository**. Or from the CLI:

```bash
# Get a token first: Settings → Applications → Generate New Token (scope: repo)
curl -u kai:<token> -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-repo","private":true,"auto_init":false}' \
  https://homeserver.tail-name.ts.net:3000/api/v1/user/repos
```

### Push an existing project here

```bash
cd ~/dev/my-project
git remote add forgejo https://homeserver.tail-name.ts.net:3000/kai/my-repo.git
git push -u forgejo --all
git push forgejo --tags        # tags are NOT included in --all
```

Keeping GitHub as `origin` and Forgejo as a second remote named `forgejo` is
the arrangement that matches the "GitHub is canonical, this is a mirror"
rule above. To push both at once, give `origin` a second push URL:

```bash
git remote set-url --add --push origin git@github.com:you/my-project.git
git remote set-url --add --push origin https://homeserver.tail-name.ts.net:3000/kai/my-repo.git
git push origin main           # goes to both
```

### Clone

```bash
git clone https://homeserver.tail-name.ts.net:3000/kai/my-repo.git
```

Username is your Forgejo username; **password is an access token**, not the
account password (Settings → Applications → Generate New Token). The account
password works too, but a token is scoped and revocable, and it is the only
thing that works once 2FA is on.

To stop retyping it:

```bash
git config --global credential.helper store    # plaintext in ~/.git-credentials
# or, better, on a machine with a keyring:
git config --global credential.helper libsecret
```

SSH clone URLs do not work — see "Why the built-in SSH server is off".

### Mirror a GitHub repository

Two directions, both useful; pick by what you want to be authoritative.

**Pull mirror (GitHub → Forgejo).** Forgejo fetches on a schedule. This is
the one that fits the backup story: GitHub stays canonical and this instance
follows it.

Web UI → **+ → New Migration → GitHub**, tick **This repository will be a
mirror**, and set the interval (default `8h`). For a private repo, supply a
GitHub PAT with `repo` scope as the access token; it is stored encrypted
under `FORGEJO_SECRET_KEY`, which is one more reason not to regenerate that
key. Needs outbound internet from the box, which it has.

Mirrors are read-only on this side: pushing to a pull-mirrored repo is
rejected, by design.

**Push mirror (Forgejo → GitHub).** Repo → Settings → Mirror Settings → add
a push mirror with a GitHub PAT. Use this only if you decide Forgejo is
where you actually work — and until there is a backup job, that decision is
the risky one.

**Manual, no credentials stored anywhere:**

```bash
git clone --mirror git@github.com:you/repo.git
cd repo.git
git push --mirror https://homeserver.tail-name.ts.net:3000/kai/repo.git
```

`--mirror` copies every ref including branches, tags and notes. It does not
copy issues, PRs or releases — only the migration importer does that.

### Phone / browser

Any browser on the tailnet: `https://homeserver.tail-name.ts.net:3000`.
The web UI is usable on a phone for issues and code review. There is no
mobile app worth installing.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f forgejo`
- Restart: `docker compose --project-directory . restart`
- Upgrade within the LTS line:
  `docker compose --project-directory . pull && ./setup.sh`
  (setup.sh re-applies the serve config and re-verifies the admin login)
- New user account:
  ```bash
  docker exec -u git forgejo forgejo admin user create \
    --username <name> --email <mail> --password '<pw>' \
    --must-change-password=false
  ```
- Reset a password:
  ```bash
  docker exec -u git forgejo forgejo admin user change-password \
    --username kai --password '<new>' --must-change-password=false
  ```
  …then mirror it into `.env`.
- Official backup (consistent, includes the DB, repos and config):
  ```bash
  docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini \
    -f /data/forgejo-dump-$(date +%F).zip
  ```
  The zip lands in `~/services/forgejo/data/`. Move it off the box.
- Effective config, as the container actually sees it:
  `docker exec forgejo cat /data/gitea/conf/app.ini`
- Disk usage: `du -sh ~/services/forgejo/data/git/repositories`
- Remove: `./teardown.sh` (or Remove in the launcher) unpublishes every
  Serve port that points at this service (plus the SSH `--tcp` forward, if
  you turned SSH on in `docker-compose.yml`) and runs `compose down`.
  Repositories, `.env` and the hidden `.admin-created` marker stay, so
  `./setup.sh` brings it back as it was. `./teardown.sh --purge` also
  deletes the data dir, the marker and `.env`, after you type `forgejo`.
  That is every repository with no other copy: take a dump first (see Nuke
  and pave in TROUBLESHOOT.md).

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` against a sandboxed `$HOME` with
PATH stubs for `docker`, `tailscale`, `curl`, `sudo` and `id`. The `docker`
stub fakes `forgejo admin user create` — including the real CLI's
`user already exists` failure — and the `curl` stub fakes `/api/healthz`, the
locked `/install`, and the authenticated `/api/v1/user` check. Covered:
preflight failures (root, docker unreachable, Tailscale down, non-numeric
ports), fresh install, a slow first boot, idempotent re-run, ROOT_URL drift,
a password changed in the UI, admin-already-exists recovery, operator
escalation and the serve-approval prompt — plus static assertions that the
compose file binds loopback only, locks the installer, disables registration
and stays on SQLite.

`teardown.sh` runs in the same sandbox: only this service's Serve ports go
off (neighbours, a lookalike port and a shared `:443` stay), the SSH TCP
forward goes only when compose publishes SSH, the safe remove keeps repos,
`.env` and the admin marker, a wrong purge confirmation changes nothing, the
purge removes the data dir, marker and `.env` (and a fresh `setup.sh`
re-creates the admin), container-owned files are cleared with the pinned
image, and odd data paths, symlinks, `COMPOSE_*` overrides and ambiguous
`.env` lines are refused.

The live suite additionally proves the two things a green deploy can still
get wrong: that `/install` really is a 404, and that the password in `.env`
really does authenticate.

## Notes

- Port 3000 is Forgejo's default, and the HTTPS port matches the local port,
  following the newer convention in this repo.
- No `user:` key in the compose service. The entrypoint has to start as root
  to rewrite `/etc/passwd` and take the s6 supervision lock, then drops to
  `git` itself; setting `user:` kills it with
  `sed: can't create temp file '/etc/passwdXXXXXX'`. `USER_UID`/`USER_GID`
  are the supported way to line the container's `git` user up with the host
  user that owns the bind mount.
- Git LFS is on (`LFS_START_SERVER`), off in the stock image. A forge that
  silently rejects LFS pushes is a bad surprise; objects live in
  `data/git/lfs`.
- Forgejo Actions (the CI) is available but **no runner is deployed**. Until
  one is, workflow files are inert — which is the right default on a box with
  this much RAM headroom.
