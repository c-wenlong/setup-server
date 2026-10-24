# vaultwarden — Troubleshooting

⚠️ **Before you run any command from this page that writes, deletes or
recreates anything, take the cold copy** (SETUP.md → Backups). This service
holds every password you own and has no other copy. Ten seconds of caution is
cheap here in a way it is not for the other services in this repo.

Triage in layers, outermost failure first:

```
container up?  ->  local health?     ->  publish?        ->  client?
docker ps          curl :8222/alive      serve status        extension / app
```

Quick triage:

```bash
cd ~/dev/setup-server/services/vaultwarden
docker compose --project-directory . ps          # vaultwarden up?
curl -s http://127.0.0.1:8222/alive              # an ISO timestamp
tailscale serve status                           # :8222 -> 127.0.0.1:8222
./tests/run-tests.sh --live                      # everything at once
```

If `docker` says "permission denied", you are not in the docker group in
*this shell*: `sg docker -c './tests/run-tests.sh --live'`. The live suite
detects this and says so rather than reporting a healthy container as down.

## Container won't start / keeps restarting

```bash
docker compose --project-directory . logs --tail=100 vaultwarden
```

A healthy start ends with Rocket announcing it has launched on `0.0.0.0:80`
*inside* the container — that is the container's own port, not a host bind,
and it is not a problem. The host mapping is `127.0.0.1:8222:80`.

- **`VAULTWARDEN_DATA missing from .env`, or Compose refuses with
  `variable is not set`** — `.env` is incomplete. Check with
  `docker compose --project-directory . config`. Do **not** fix this by
  deleting `.env` and re-running: on a deployed vault that regenerates
  `VAULTWARDEN_SIGNUPS_ALLOWED=true` and can leave the door open. Add the missing key.
- **Permission errors on `/data`** — the container runs as root and owns
  those files. If you have `chown`ed the directory to your user, root can
  still write it, so this usually means the path in `VAULTWARDEN_DATA` is
  wrong or on a mount that is read-only. `ls -ld ~/services/vaultwarden/data`.
- **`database is locked` / `database is malformed` in the logs** — almost
  always two containers pointed at the same `/data`.
  `docker ps -a | grep -i vaultwarden` should show exactly one. If it is
  genuinely malformed, stop everything and restore the cold copy; do not
  experiment on the live file.
- **Exit 137 (OOM-killed)** — surprising at ~50 MiB, so suspect a neighbour:
  ollama with a model loaded claims ~5 GB. `docker stats` and `free -h`.

## `/alive` fails but the container says "running"

```bash
curl -sv http://127.0.0.1:8222/alive
```

- **Connection refused for the first few seconds after a start** — normal.
  The container is up before Rocket is listening. `setup.sh` retries for this
  reason; a one-shot `curl` right after `up -d` will just miss it.
- **Never comes up** — read the logs; a failed schema migration on an upgrade
  is the usual cause (see below).
- Confirm the port really is on loopback: `ss -ltn | grep 8222` → should show
  `127.0.0.1:8222`, never `0.0.0.0`. If you see a wildcard bind on a password
  vault, treat it as an incident: `tailscale serve --https=8222 off`, take the
  container down, and find out who edited `docker-compose.yml`.

## `/admin` is reachable — treat as an incident

The admin panel deletes accounts, invites users and rewrites the server
config, from one password, over the same URL as the vault.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8222/admin/users   # must be 404
curl -s http://127.0.0.1:8222/admin | head -c 200   # "admin panel is disabled..."
```

`/admin` answering **200 with the "admin panel is disabled" text is correct** —
that is what off looks like. The check that matters is `/admin/users`
returning **404**. If it returns anything else:

1. `docker exec vaultwarden printenv ADMIN_TOKEN` — if this prints anything,
   the panel is on.
2. Turn it off. It takes **two** edits, because it took two to turn on: the
   shipped `docker-compose.yml` has no `ADMIN_TOKEN` key at all, so removing
   only the `.env` line leaves a compose file that will fail to start (or
   silently re-enable the panel the next time someone repopulates `.env`).
   ```bash
   cd ~/dev/setup-server/services/vaultwarden
   sed -i '/^VAULTWARDEN_ADMIN_TOKEN=/d' .env
   # then delete or re-comment the `ADMIN_TOKEN: ${VAULTWARDEN_ADMIN_TOKEN...}`
   # line in the environment: block of docker-compose.yml
   ./setup.sh
   docker exec vaultwarden printenv ADMIN_TOKEN     # must print nothing
   ```
3. Until it is fixed, take the publish down rather than leaving a vault admin
   console on the tailnet: `tailscale serve --https=8222 off`.
4. Then work out how it got set. If it was you, ten minutes ago, following the
   enable recipe in SETUP.md — fine, that recipe ends with turning it back off.

The live suite asserts this 404 for exactly this reason.

## Signup problems

### "Create account" fails — signups are closed

The client shows something along the lines of *"Registration not allowed or
user already exists"*. That is the intended end state: `setup.sh` closed
signups once it saw your account. To add a second person, either invite them
from the admin panel (SETUP.md → Enabling it), or re-open temporarily:

```bash
cd ~/dev/setup-server/services/vaultwarden
sed -i 's/^VAULTWARDEN_SIGNUPS_ALLOWED=.*/VAULTWARDEN_SIGNUPS_ALLOWED=true/' .env
./setup.sh                    # opens it, recreates the container
# ...they register...
./setup.sh                    # counts the new account, closes it again
```

Note that org invitations are a *separate* door and are also off
(`VAULTWARDEN_INVITATIONS_ALLOWED=false`). An invite bypasses
`SIGNUPS_ALLOWED` entirely, so turning invitations on is not a way to "safely"
add someone while signups stay closed — it is the same hole with a different
name. Prefer the open-register-close cycle above.

### Signups are *still* open after I registered

`setup.sh` closes them on its **next** run — the deploy is a two-step
handshake on purpose (SETUP.md → The signup lifecycle). Run it:

```bash
cd ~/dev/setup-server/services/vaultwarden && ./setup.sh
```

**What a correct closure looks like.** This run is the security-critical half
of the deploy, so it is worth knowing its output by sight. In order:

```
 ==>  N account(s) exist and registration is still open — closing it
  ✓   Set VAULTWARDEN_SIGNUPS_ALLOWED=false in .../.env
 ==>  Recreating the container so the change takes effect
  ✓   Signups are now CLOSED — confirmed on the running container
```

The last line is the one that matters: it means the script re-read the
*running container's* environment after recreating it, rather than trusting
the file it had just written.

⚠️ If the run instead dies with **"still reports SIGNUPS_ALLOWED=true"**, the
door is still open. That is a real failure, not a cosmetic one — the `.env`
edit landed but never reached the container. The error text carries the repair
command; run it and re-check:

```bash
docker compose --project-directory . up -d --force-recreate
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden | grep SIGNUPS_ALLOWED
```

If it still says `true` after a forced recreate, something is overriding the
interpolation — check `docker compose --project-directory . config` for what
Compose actually resolved, and that no stray `SIGNUPS_ALLOWED` was hardcoded
into `docker-compose.yml`.

If instead it reports signups open because it counted zero accounts, check
what it is reading:

```bash
ls -l ~/services/vaultwarden/data/db.sqlite3
python3 -c "import sqlite3;print(sqlite3.connect('file:$HOME/services/vaultwarden/data/db.sqlite3?mode=ro',uri=True).execute('select count(*) from users').fetchone()[0])"
```

- `0` — you registered against a *different* server. This is the common one:
  the Bitwarden client defaults to bitwarden.com, and if you did not set the
  self-hosted server URL **before** creating the account, the account is on
  bitwarden.com and this vault is empty. Set the server URL on the login
  screen and register again here.
- Permission denied / no such file — `VAULTWARDEN_DATA` in `.env` does not
  point where the container is actually writing. Compare with
  `docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{end}}' vaultwarden`.

### `.env` says closed but registration still works

`.env` is read at container start. Someone edited it without recreating:

```bash
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden | grep SIGNUPS_ALLOWED
cd ~/dev/setup-server/services/vaultwarden && ./setup.sh    # reconciles the two
```

This is why `setup.sh` reads the signup state off the **container** rather
than off `.env`, and why the run that closes the door re-checks the container
afterwards and dies if it still says `true`.

### `setup.sh` exits 1 with "could NOT read ... db.sqlite3"

The account count could not be obtained — neither a read-only open from the
host nor a `docker cp` of the live database through the daemon worked. The
deploy is up and published; what it could not do is decide whether it is safe
to close registration, and it refuses to guess (assuming 0 would leave the
vault open to the tailnet, assuming 1 would lock you out of registering). The
signup state is whatever it already was, which the banner above the error
tells you.

```bash
sudo ls -l ~/services/vaultwarden/data/db.sqlite3   # exists? readable?
docker ps -a | grep -i vaultwarden                  # is the container there at all?
```

Usual causes: the container is not running (so `docker cp` has nothing to copy
from), `VAULTWARDEN_DATA` points at the wrong directory, or the file's mode
excludes your user *and* the daemon call failed. Once you can read it, re-run
`./setup.sh`. If you cannot, close the door by hand rather than leaving it:

```bash
cd ~/dev/setup-server/services/vaultwarden
sed -i 's/^VAULTWARDEN_SIGNUPS_ALLOWED=.*/VAULTWARDEN_SIGNUPS_ALLOWED=false/' .env
./setup.sh
```

Do that only once your own account exists — closing signups before you have
registered locks you out permanently, and nothing can create the account for
you.

## `tailscale serve` errors

- **`Access denied: serve config denied`** — the user is not the tailscaled
  operator. `sudo tailscale set --operator=$USER` (setup.sh tries this).
- **An approval URL is printed** — Serve is not enabled for the tailnet yet.
  Open the link, approve, re-run `./setup.sh`.
- **Port already claimed** — `tailscale serve status` will show what has
  `:8222`. Reset just this one: `tailscale serve --https=8222 off`.
  ⚠️ Never `tailscale serve reset` — that clears every mapping on the node,
  taking all the other services down with it. `off` is undocumented in
  `--help` but is what Tailscale prints itself, and is the only single-port
  removal.

## HTTPS URL doesn't load from a client

- **Is the client on the tailnet?** This is not reachable off-tailnet, by
  design, and there is no fallback. Check Tailscale is connected on *that*
  device, not on the server.
- First load after a new port can take ~60s while the cert is minted:
  `curl -v https://kai-home-server.taild6a23f.ts.net:8222/alive`
- MagicDNS off → the tailnet IP `100.85.87.87:8222` works, but `DOMAIN` still
  says the DNS name, so attachment links and WebAuthn will disagree with the
  address you are on. Fix MagicDNS rather than living with it.
- **The web vault loads but shows a crypto/"secure context" error** — you
  reached it over plain HTTP from another machine. The web vault needs a
  secure context to decrypt anything. Use the `https://` tailnet URL;
  `http://<lan-ip>:8222` is not it (and nothing should be listening there).

## Login problems

- **"Username or password is incorrect" on a brand-new account** — you are
  almost certainly logging in to **bitwarden.com**, not this server. The
  server URL has to be set on the login screen *before* you log in, on every
  client, and it does not carry across from another device. Check the login
  screen says "Logging in on: kai-home-server…".
- **Logged out of everything at once** — `rsa_key.pem` in the data dir was
  regenerated or lost; it signs the clients' tokens. Not data loss: log in
  again. If you did not touch it, find out what did.
- **Forgot the master password.** There is no reset, by design — it never
  reached the server, and nothing on this box can decrypt the vault without
  it. Before doing anything destructive, check every device that is still
  *unlocked*: an unlocked client can still export the vault (SETUP.md →
  Client-side encrypted export), and that is the only recovery path there is.
  If nothing is unlocked anywhere, the vault contents are unrecoverable and
  the only way forward is to delete the account and start over.
- **Locked out by 2FA.** In order:
  1. **Use the recovery code.** Bitwarden gives you one when you enable
     two-step login (Settings → Two-step login → View recovery code, from any
     still-logged-in client). Entering it disables all 2FA on the account.
  2. If the recovery code is gone, the TOTP/WebAuthn rows have to come out of
     the database by hand. Stop the container and copy the file first:

     ```bash
     cd ~/dev/setup-server/services/vaultwarden
     docker compose --project-directory . stop
     sudo cp ~/services/vaultwarden/data/db.sqlite3 ~/db.sqlite3.bak
     # LOOK before you delete — confirm the table and column names on your version:
     sudo sqlite3 ~/services/vaultwarden/data/db.sqlite3 ".tables"
     sudo sqlite3 ~/services/vaultwarden/data/db.sqlite3 \
       "select uuid, email from users;"
     sudo sqlite3 ~/services/vaultwarden/data/db.sqlite3 \
       "delete from twofactor where user_uuid = '<uuid from above>';"
     docker compose --project-directory . start
     ```

     This removes the second factor only. It does not touch the vault
     contents, which are encrypted with your master password and stay that
     way. Re-enrol 2FA immediately afterwards.

## 2FA / WebAuthn / passkeys misbehaving

**Check `DOMAIN` first.** Vaultwarden bakes it into the relying-party ID when
a security key or passkey is registered, so a wrong value produces failures
that look like a broken key, a broken browser, or a broken client — never
like a server misconfiguration.

```bash
docker exec vaultwarden printenv DOMAIN
# must be exactly, scheme and port included, no trailing slash:
#   https://kai-home-server.taild6a23f.ts.net:8222
grep VAULTWARDEN_DOMAIN ~/dev/setup-server/services/vaultwarden/.env
```

If it is wrong: fix `VAULTWARDEN_DOMAIN` in `.env`, `./setup.sh`, then
**re-register every security key and passkey** — credentials enrolled under
the old domain will not validate under the new one. Keep a TOTP method or the
recovery code available while you do it, or you will lock yourself out
mid-repair.

- **Registration of a key fails silently, or the key works on one device and
  not another** — same cause. Compare the address in the browser's URL bar
  with `DOMAIN`; they must match character for character, port included.
- **`setup.sh` or the live suite says it "could not confirm DOMAIN", but
  `docker inspect` shows the right value** — this is very likely *not* a
  DOMAIN problem. Both check `GET /api/config` first, which is unauthenticated
  and echoes the server's own domain back, and fall back to the container's
  environment. The JSON shape of that endpoint is version-dependent, so a
  web-vault upgrade can move or rename the `environment.vault` field and break
  the first check while the actual configuration is fine. Confirm the way a
  client would — load the vault over the tailnet URL and register a passkey —
  before changing anything. If a version bump did move the field, the check is
  what needs updating, not `.env`.
- **Email 2FA is not offered** — correct, no SMTP is configured on this
  deploy. Use TOTP or WebAuthn.

## Sync and client problems

- **Client stuck offline / "last sync: never"** — Tailscale on that device,
  first. Then the server URL on the login screen. Then `/alive`.
- **A change on the phone doesn't appear on the laptop immediately** — live
  push comes from the notifications hub, served on the same port and proxied
  by Tailscale Serve. If push is not getting through, a manual sync (pull down
  on mobile, "Sync vault now" on desktop) still works; nothing is lost, it is
  just not instantaneous.
- **Attachments won't download** — `DOMAIN`, again: attachment URLs are
  absolute and built from it.
- **Emergency access invitation never arrives** — no SMTP is configured, so
  it never will. That feature is inert on this deploy.
- **`bw` CLI talks to the wrong server** — `bw config server <url>`, then
  `bw logout && bw login`. The CLI stores the server per-profile and does not
  pick it up from anywhere else.

## Import / export problems

- **An encrypted export won't import anywhere** — it was an
  **account-restricted** export, encrypted with that account's key, and the
  account it belongs to is gone. There is no way to decrypt it. This is why
  SETUP.md insists on **password protected** exports; account-restricted ones
  are backups in appearance only.
- **The export is missing my attachments** — expected. No Bitwarden export
  includes file attachments, and nothing warns you. They only exist in
  `~/services/vaultwarden/data/attachments` and in the cold copy.
- **Import created duplicates** — Bitwarden imports are additive, never
  merging. Delete the folder/collection you imported into and retry, rather
  than de-duplicating by hand.

## Disk

- `sudo du -sh ~/services/vaultwarden/data/*` — it will be `attachments` or
  `icon_cache`; the vault database itself stays small.
- `sudo rm -rf ~/services/vaultwarden/data/icon_cache` is safe; it is a cache
  of site favicons and regenerates.
- Moving the data: stop the stack, `sudo mv` the directory (root owns it),
  update `VAULTWARDEN_DATA` in `.env`, `./setup.sh`.

## Upgrade problems

Vaultwarden runs schema migrations on start and **they do not run backwards**.
A database that has been opened by a newer version cannot be opened by the old
one, so rolling back the image tag alone does not roll back the problem.

- **Always take the cold copy before bumping `VAULTWARDEN_VERSION`.** That
  tarball is the only rollback that exists.
- **Bumped the version and it will not start** — read the logs for the
  migration error, then restore: pin `VAULTWARDEN_VERSION` back in `.env`,
  stop the container, `sudo rm -rf ~/services/vaultwarden/data`, untar the
  pre-upgrade copy back into place, `./setup.sh`.
- **Clients complain after an upgrade** — the bundled web vault moved with it.
  Hard-refresh the browser; update the extension and apps, which are versioned
  independently of the server.

## Nuke and pave

**This destroys every password, note, TOTP seed and attachment in the vault,
and there is no undo.** Unless you have a client-side encrypted export or a
cold copy in hand, do not run this — read the Backups section of SETUP.md
first and make one.

`sudo` is needed because the container runs as root and owns the data files.

```bash
cd ~/dev/setup-server/services/vaultwarden
docker compose --project-directory . down -v
sudo rm -rf ~/services/vaultwarden      # THE VAULT. Every password.
rm -f .env                              # fresh DOMAIN + VAULTWARDEN_SIGNUPS_ALLOWED=true
tailscale serve --https=8222 off
./setup.sh
```

Then register again in the browser, and run `./setup.sh` once more to close
signups. If you are restoring, do it between the `rm -rf` and the `setup.sh`:

```bash
sudo mkdir -p ~/services/vaultwarden/data
sudo tar xzf ~/vaultwarden-<date>.tgz -C ~/services/vaultwarden/data
./setup.sh
```

A restored data directory already contains your user, so that `setup.sh` run
will count ≥ 1 user and close signups by itself.
