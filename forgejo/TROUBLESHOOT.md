# forgejo — Troubleshooting

Triage in layers, outermost failure first:

```
container up?  ->  local API?        ->  publish?        ->  client?
docker ps          curl :3000            serve status        git clone / browser
```

Quick triage:

```bash
cd ~/dev/setup-server/forgejo
docker compose --project-directory . ps              # forgejo up?
curl -s http://127.0.0.1:3000/api/healthz            # {"status":"pass",...}
tailscale serve status                               # :3000 -> 127.0.0.1:3000
./tests/run-tests.sh --live                          # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so rather than reporting a healthy container as down.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 forgejo
```

- **`sed: can't create temp file '/etc/passwdXXXXXX'`** — a `user:` key was
  added to the compose service. The entrypoint must start as root to rewrite
  `/etc/passwd` and take the s6 lock; it drops to `git` on its own. Remove
  `user:` and use `USER_UID`/`USER_GID` instead (already in `.env`).
- **`FORGEJO_DATA missing from .env`, or Compose refuses to start with
  `variable is not set`** — `.env` is incomplete. `docker-compose.yml` uses
  `${...:?}` guards on `FORGEJO_DATA`, `FORGEJO_DOMAIN`, `FORGEJO_ROOT_URL`
  and `FORGEJO_SECRET_KEY` precisely so this fails at start rather than
  booting a half-configured forge. Check with
  `docker compose --project-directory . config`.
- **Permission errors on `/data`** — `USER_UID`/`USER_GID` in `.env` do not
  match the owner of `~/services/forgejo/data`. Fix the values (`id -u`,
  `id -g`) and re-run `./setup.sh`, or
  `sudo chown -R $(id -u):$(id -g) ~/services/forgejo/data`.
- **Exit 137 (OOM-killed)** — unusual for Forgejo at ~100 MiB, so suspect a
  neighbour: ollama with a model loaded claims ~5 GB. `docker stats` and
  `free -h`. Adding swap turns an OOM kill into "slow", which is the better
  failure:
  `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`.

## Local `/api/healthz` fails but the container says "running"

First boot creates the SQLite schema and can take a minute;
`docker compose --project-directory . logs -f forgejo` shows progress.
If it never finishes:

- Check the port really is on loopback: `ss -ltn | grep 3000` → should show
  `127.0.0.1:3000`, never `0.0.0.0`.
- Check what the container actually decided its config was:
  `docker exec forgejo cat /data/gitea/conf/app.ini`. Remember this file is
  **derived from the environment on every start** — if it disagrees with
  what you expect, the fix is in `docker-compose.yml` / `.env`, never in the
  file itself.
- `database is locked` in the logs — SQLite write contention. On a
  single-user forge this usually means something is looping: a runaway
  webhook, a mirror syncing every minute, or two containers pointed at the
  same `/data`. `docker ps -a | grep forgejo` should show exactly one.

## `/install` loads instead of returning 404

**Treat this as an incident, not a cosmetic bug.** Anyone who can reach the
install wizard can reconfigure the instance, including choosing a new admin.

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://kai-home-server.taild6a23f.ts.net:3000/install     # must be 404
```

If it is 200:

1. Confirm the setting is present:
   `docker exec forgejo grep -i INSTALL_LOCK /data/gitea/conf/app.ini`
   → `INSTALL_LOCK = true`.
2. If it is false or missing, `FORGEJO__security__INSTALL_LOCK: "true"` was
   removed from `docker-compose.yml`. Restore it and
   `docker compose --project-directory . up -d`.
3. Until it is fixed, take the publish down rather than leaving it exposed
   on the tailnet: `tailscale serve --https=3000 off`.

The live suite asserts this 404 for exactly this reason — a deploy that
serves the install page passes every other check.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` will show what has
  `:3000`. Reset just this one: `tailscale serve --https=3000 off`.
  ⚠️ Never `tailscale serve reset` — that clears every mapping on the node,
  taking all the other services down with it. `off` is undocumented in
  `--help` but is what Tailscale prints itself, and is the only single-port
  removal.

## HTTPS URL doesn't load from a client

- Is the client on the tailnet? This is not reachable off-tailnet, by design.
- First load after a new port can take ~60s while the cert is minted:
  `curl -v https://kai-home-server.taild6a23f.ts.net:3000/api/healthz`
- MagicDNS off → use the tailnet IP `100.85.87.87` with the same port. Note
  that `ROOT_URL` still says the DNS name, so links in the page will point
  at a name the client cannot resolve — fix MagicDNS rather than living
  with it.

## Login problems

- **The generated password in `.env` is rejected on first login, and
  `setup.sh` died with "Login as kai was rejected"** — this is the
  `--must-change-password` trap. The admin was created without
  `--must-change-password=false`, so Forgejo is demanding a password change
  the CLI never told you about. Fix:

  ```bash
  docker exec -u git forgejo forgejo admin user change-password \
    --username kai --password "$(sed -n 's/^FORGEJO_ADMIN_PASSWORD=//p' .env)" \
    --must-change-password=false
  ```

  Do not "fix" this by deleting the flag from `setup.sh`. It is there
  because of this exact failure; SETUP.md explains why.
- **`setup.sh` says the password "does not match the server"** — the admin
  password was changed in the web UI and `.env` is stale. Mirror the new
  password into `FORGEJO_ADMIN_PASSWORD`, or reset it with the command above.
  The deploy fails deliberately here rather than reporting success over an
  account you cannot log into.
- **Forgot the password entirely** — same `change-password` command; the CLI
  does not need the old one.
- **Locked out with 2FA** — there is no CLI command to disable it; the TOTP
  row has to come out of the database. Stop the container first, and copy the
  DB file before touching it:

  ```bash
  docker compose --project-directory . stop
  cp ~/services/forgejo/data/gitea/gitea.db /tmp/gitea.db.bak
  sqlite3 ~/services/forgejo/data/gitea/gitea.db \
    "delete from two_factor where uid = (select id from user where lower_name='kai');"
  docker compose --project-directory . start
  ```
- **"user already exists" when creating a second account** — it does; pick
  another username. Existing accounts:
  `docker exec -u git forgejo forgejo admin user list`.

## Clone / push problems

- **Clone URLs in the web UI say `localhost` (or the wrong host/port)** —
  `ROOT_URL` is wrong. Forgejo derives every clone URL, redirect, webhook
  payload and API `html_url` from it, and a wrong value produces no error at
  all, just unusable links. Check and fix:

  ```bash
  docker exec forgejo grep ROOT_URL /data/gitea/conf/app.ini
  # then in .env:
  #   FORGEJO_DOMAIN=kai-home-server.taild6a23f.ts.net
  #   FORGEJO_ROOT_URL=https://kai-home-server.taild6a23f.ts.net:3000/
  ./setup.sh
  ```

  `setup.sh` warns about this on every run where `.env` disagrees with the
  live tailnet name — it does not rewrite `.env` for you, because that file
  is yours.
- **`git push` asks for a password and rejects the account password** —
  once 2FA is on, only an access token works. Settings → Applications →
  Generate New Token (scope `repo`), and use the token as the password.
- **`git@...: Permission denied (publickey)` / SSH clone hangs** — the
  built-in SSH server is off on purpose. Clone over HTTPS. To turn SSH on,
  follow the four steps in the ports block of `docker-compose.yml`.
- **`remote: LFS support not enabled`** — `LFS_START_SERVER` was turned off.
  It is on in this compose; check
  `docker exec forgejo grep -A2 '\[server\]' /data/gitea/conf/app.ini`.
- **Push rejected on a mirrored repo** — pull mirrors are read-only on this
  side, by design. Push to the upstream (GitHub) and let the mirror follow,
  or convert the repo: Settings → Mirror Settings → remove the mirror.
- **`error: RPC failed; HTTP 413`** — a push larger than the proxy will
  accept. Tailscale Serve does not cap this, so it is Forgejo's
  `MAX_SIZE`/LFS limits; for a genuinely huge history, push over a local
  clone path instead, or raise
  `FORGEJO__repository__upload__FILE_MAX_SIZE` in `docker-compose.yml`.

## Mirror problems

- **A pull mirror stopped syncing** — check Repo → Settings → Mirror
  Settings for the last sync and error. Force one now with the "Synchronize
  Now" button, or `docker compose --project-directory . logs forgejo | grep -i mirror`.
- **Mirror auth fails after `FORGEJO_SECRET_KEY` changed** — stored mirror
  credentials are encrypted with that key, so rotating it makes every one of
  them unreadable. Re-enter the tokens, and do not rotate the key again.
- **Nothing syncs at all, all mirrors** — the box lost outbound internet
  (mirrors are the only part of this service that needs it):
  `curl -sI https://github.com | head -1`.

## Disk

- `du -sh ~/services/forgejo/data/*` to find the weight; it is almost always
  `git/repositories` or `git/lfs`.
- Garbage-collect the repos: Site Administration → Dashboard → maintenance
  operations → **"Run 'git gc' on all repositories"**. By hand, one repo:
  `docker exec -u git forgejo git -C /data/git/repositories/kai/my-repo.git gc --aggressive --prune=now`
- LFS objects no repository references any more are only reclaimed by Site
  Administration → Dashboard → **"Garbage collect LFS meta objects"**.
- Moving the data: stop the stack, move the directory, update `FORGEJO_DATA`
  in `.env`, `./setup.sh`.

## Upgrade problems

- **Bumped to `16` and now it will not start / behaves oddly** — 16 is a
  non-LTS line and its migrations do not run backwards. Restore
  `FORGEJO_VERSION=15` in `.env`, then restore
  `~/services/forgejo/data` from a backup taken *before* the upgrade: a
  database that has already run v16 migrations cannot be opened by v15.
  This is the argument for taking a `forgejo dump` before any version bump:

  ```bash
  docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini \
    -f /data/forgejo-dump-$(date +%F).zip
  ```
- **Upgrade hangs on "migrating database"** — let it finish; SQLite
  migrations on a large instance are slow and interrupting one is how you
  get a half-migrated database. Watch `docker logs -f forgejo`.

## Nuke and pave

Destroys every repository, issue, PR and user on this instance. Anything
that only exists here is gone — which, until there is a backup job, is the
whole argument for keeping GitHub canonical.

```bash
cd ~/dev/setup-server/forgejo
docker compose --project-directory . down -v
rm -rf ~/services/forgejo          # repos AND database AND the admin marker
rm -f .env                         # forces new generated credentials
tailscale serve --https=3000 off
./setup.sh
```

To keep the repositories and rebuild only the account/settings layer, there
is no shortcut — the SQLite DB *is* the metadata. Take a `forgejo dump`,
restore it into a fresh instance, and edit from there.
