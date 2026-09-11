# vaultwarden — self-hosted password vault (Bitwarden-compatible)

Every password, passkey, TOTP seed and secure note you own, on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8222`.

Read the two warnings below before you put anything in it. They are not
boilerplate; they are the two ways this service ruins your week.

> ### ⚠️ 1. Nothing on this box is backed up
>
> If `~/services/vaultwarden` is lost — disk failure, a stray `rm -rf`, a
> nuke-and-pave — **every password in it is gone**, and there is no copy
> anywhere else. A password vault with no backup is a bad idea. See
> [Backups](#backups-read-this-one) for the two things to do about it, one of
> which takes 30 seconds and works even if this machine never boots again.
>
> ### ⚠️ 2. There is no password reset
>
> Your master password is never sent to the server — it derives the key that
> decrypts the vault, in the browser. Nobody, including you with root on this
> box, can recover the contents without it. Forgetting it is equivalent to
> deleting the vault. That is the design working correctly.

## What this is, and what it isn't

Vaultwarden is an independent **reimplementation of the Bitwarden server
API in Rust**. It is not Bitwarden, and it is not written by Bitwarden.

What that buys you: the **official Bitwarden clients** — browser extension,
desktop app, iOS and Android apps, CLI — all work against it unmodified, by
pointing them at a custom server URL. You are not trusting some third-party
client with your vault; you are running the official client against a
different server.

Why not the real Bitwarden self-hosted stack: it is roughly a dozen
containers plus MSSQL, and it wants several GB of RAM. This box has 7.7 GB
shared with ollama, Immich, Seafile and everything else. Vaultwarden is one
container that idles around 50–100 MiB.

The cost of that trade, stated plainly:

- **It is a compatible reimplementation, not the same code.** Bugs, upstream
  API changes, and security fixes are on a different project's schedule.
  Pinning the version (below) is therefore a real decision, not tidiness.
- Some organization/enterprise features are approximations or absent. For a
  single-person vault this does not come up.
- Conversely, several things Bitwarden charges for — built-in TOTP codes,
  file attachments, emergency access — are simply on here.

## Architecture

One container, one SQLite file. That is all of it:

```
  browser extension / phone / desktop app, on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8222
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8222
            ▼
   ┌──────────────────────────────────────┐
   │ container: vaultwarden               │
   │   vaultwarden/server:1.37.2          │
   │   web-vault 2026.7.0                 │
   │                                      │
   │   API + web vault      :80           │
   │   notifications hub    (same :80)    │
   │   SQLite               (in-process)  │
   │   /admin               DISABLED      │
   └────────────┬─────────────────────────┘
                │ bind mount
                ▼
      ~/services/vaultwarden/data   →  /data
```

No Postgres, no Redis, no separate WebSocket port. Older Vaultwarden guides
tell you to publish `:3012` for the notifications hub; that has not been true
for years — it is served on the main port now, and this deploy publishes one
port only.

State lives under `~/services/vaultwarden`:

```
~/services/vaultwarden/
  data/                  # VAULTWARDEN_DATA — the entire vault
    db.sqlite3           #   everything: users, ciphers, folders, org data
    rsa_key.pem          #   signs the JWTs the clients hold
    attachments/         #   file attachments (NOT in a client export — see below)
    sends/               #   Bitwarden Send payloads
    icon_cache/          #   site favicons; safe to delete, regenerates
```

**`db.sqlite3` is the whole vault.** Copy that directory and you have
everything; lose it and you have nothing. The vault *contents* inside it are
encrypted with a key derived from your master password, so the file is not
plaintext — but it is also not recoverable from anywhere else.

## The signup lifecycle

This is the part of the deploy that behaves differently from every other
service in this repo, so it is worth understanding before you run it.

**`setup.sh` cannot create your account, and must not try.** Your master
password never reaches the server: the client stretches it into an encryption
key and an auth hash locally, and the server only ever sees the hash. A
script that "created your account for you" would have to invent your master
password and know it — which is precisely the property that makes the vault
worth having. So registration happens in a browser, by you, once.

That leaves a window: a freshly deployed Vaultwarden with signups open is an
instance where **anyone who can reach it can claim an account**. On a
tailnet-only service the blast radius is your own devices, but it is still a
window, and it should not stay open.

So the deploy is a two-step handshake:

```
  ./setup.sh   ──▶  signups OPEN     "go register now, then re-run me"
                          │
                     you register in the browser
                          │
                          ▼
  ./setup.sh   ──▶  sees 1 user  ──▶  SIGNUPS_ALLOWED=false, recreates
                                       the container. Window closed.
```

On every run, `setup.sh` counts the rows in `users` in
`~/services/vaultwarden/data/db.sqlite3` — read-only, with python3's stdlib
`sqlite3`, no extra dependency and no write lock taken against the running
container. Then:

| Signups | Accounts in the DB | What the run does |
|---|---|---|
| open | 0 | Leaves it open. Repeats the "register now, then re-run" instruction. |
| open | ≥ 1 | **Flips `.env` to `false` and recreates the container**, then re-reads the container's environment to confirm the door really did shut. |
| closed | anything | No-op. Nothing rewritten, nothing recreated. |
| either | **unknown** | Touches nothing, says so in three lines, and **exits non-zero.** |

The flip is the one and only edit `setup.sh` ever makes to an existing
`.env`: it rewrites the `VAULTWARDEN_SIGNUPS_ALLOWED` line and leaves every
other line — including anything you added yourself, and the file's mode and
inode — untouched.

Two details worth knowing:

- **"Signups are open" is read off the running container, not off `.env`.**
  Those can disagree — `.env` is read once, at container start — and when they
  do, the container is what the world is actually enforcing.
- **An unreadable account count is never guessed at.** The container runs as
  root, so `db.sqlite3` can end up unreadable from the host; `setup.sh` then
  falls back to `docker cp`-ing the database (and its `-wal`) out through the
  daemon. If *both* fail it refuses to pick a default — assuming 0 would leave
  the vault open to the tailnet, assuming 1 would lock you out of ever
  registering — so it leaves registration exactly as it was, finishes the
  deploy, prints the state, and exits 1 telling you what it could not verify.

### The other door: org invitations

`VAULTWARDEN_INVITATIONS_ALLOWED=false`, and this matters more than it looks.
Organization invitations **bypass `SIGNUPS_ALLOWED` entirely**: with
invitations on, an invited address can create an account on an instance whose
signups are firmly closed. Closing one door and leaving the other open would
make the whole lifecycle above decorative. The live suite asserts this one
too.

### Is it open right now?

Two answers, and when they disagree the second one is the truth:

```bash
# What the next deploy thinks:
grep VAULTWARDEN_SIGNUPS_ALLOWED ~/dev/setup-server/vaultwarden/.env

# What the RUNNING container is actually enforcing:
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden \
  | grep -E 'SIGNUPS_ALLOWED|INVITATIONS_ALLOWED'
```

They diverge only if someone edited `.env` without recreating the container.
`./setup.sh` reconciles them. Do not try to read this off the web vault: the
"Create account" link stays visible in the UI either way, and only the
submit fails.

To deliberately re-open signups (adding a second person, say):

```bash
cd ~/dev/setup-server/vaultwarden
sed -i 's/^VAULTWARDEN_SIGNUPS_ALLOWED=.*/VAULTWARDEN_SIGNUPS_ALLOWED=true/' .env
./setup.sh                      # opens it and recreates the container
# ... they register ...
./setup.sh                      # counts 2 accounts, closes it again
```

The second `./setup.sh` is the one that matters. Until it runs, the vault
accepts accounts from anyone on the tailnet.

Or leave signups closed and use an **invitation** instead, which is the
better route for a second person — it needs the admin panel, see below.

## Why the admin panel ships OFF

No admin token is set anywhere: not in `.env`, and — more to the point — there
is no `ADMIN_TOKEN` key in `docker-compose.yml` for one to be passed through.
With none set, the container reports:

- `GET /admin` → 200, with the body *"admin panel is disabled, please
  configure the 'ADMIN_TOKEN' variable to enable it"*
- `GET /admin/users` → **404**
- `POST /admin` → **404**

The admin panel is a single-password web console that lists every user,
deletes accounts, invites users, and edits the server config live. On a
password vault, a second credential that grants that — reachable over the
same URL as the vault itself — is a bigger surface than the feature is
worth. Nothing in normal single-user operation needs it.

`tests/run-tests.sh --live` asserts the `/admin/users` 404 explicitly. An
accidentally-enabled admin panel on this service is the worst regression in
this repo, and it is exactly the kind that leaves everything else green.

### Enabling it, when you actually need it

You need it for exactly two things: **inviting a user while signups are
closed**, and **deleting an account**. Turn it on, do the thing, turn it off.

The token must be an Argon2 PHC hash, and generating one **requires an
interactive terminal** — `vaultwarden hash` panics without a TTY, which is
precisely why `setup.sh` cannot do this for you:

```bash
# 1. Generate the hash. The -it is load-bearing; without a TTY this panics.
docker run -it --rm vaultwarden/server:1.37.2 /vaultwarden hash --preset owasp
# prompts for a password twice, prints:
#   $argon2id$v=19$m=19456,t=2,p=1$c2FsdA...$aGFzaA...
```

Step 2 is `.env`, and step 3 is `docker-compose.yml` — the compose file
deliberately carries **no `ADMIN_TOKEN` key at all**, so pasting a token into
`.env` on its own does nothing. Both edits are required, which is the point:
enabling the panel cannot happen by accident.

```bash
# 2. Add the hash to .env, single-quoted, as VAULTWARDEN_ADMIN_TOKEN.
cd ~/dev/setup-server/vaultwarden
echo "VAULTWARDEN_ADMIN_TOKEN='<paste the whole \$argon2id\$... string>'" >> .env
chmod 600 .env
```

```yaml
# 3. Add this one line to the `environment:` block in docker-compose.yml,
#    where the commented-out recipe already sits:
      ADMIN_TOKEN: ${VAULTWARDEN_ADMIN_TOKEN:?}
```

```bash
# 4. Apply, then VERIFY what the container actually received:
./setup.sh
docker exec vaultwarden printenv ADMIN_TOKEN
```

That verification step is not optional. `$` is Compose's variable-reference
character, and an Argon2 PHC string is nothing but `$`-delimited fields, so it
is the kind of value that gets quietly mangled in transit. What `printenv`
prints must be **byte-identical to what `vaultwarden hash` printed** — one `$`
per separator.

- If Compose warned about undefined variables, or the value came out with
  segments missing, double every `$` to `$$` in the `.env` line and re-run.
- If it came out with `$$` in it, the doubling was applied where it was not
  needed; go back to the single-`$` form.
- If it printed nothing, the compose key in step 3 is missing.

Then open `https://kai-home-server.taild6a23f.ts.net:8222/admin` and enter
the **password you typed at the prompt** (not the hash).

**When you are done, take it back off** — both edits, in reverse:

```bash
sed -i '/^VAULTWARDEN_ADMIN_TOKEN=/d' .env
# remove (or re-comment) the ADMIN_TOKEN line in docker-compose.yml
./setup.sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8222/admin/users   # must be 404
```

A plain (unhashed) string also works as an `ADMIN_TOKEN` — Vaultwarden
accepts it and compares in constant time. Do not use one: it sits in `.env`
in cleartext, and the argon2 form costs you one extra command.

## `DOMAIN` must be exactly right

`.env` carries `VAULTWARDEN_DOMAIN=https://kai-home-server.taild6a23f.ts.net:8222`
— the **full URL, scheme and port included**, no trailing slash. `setup.sh`
resolves it from `tailscale status --json` at first run and bakes it in.

This is the setting that breaks confusingly rather than obviously. Vaultwarden
uses `DOMAIN` for:

- **WebAuthn / passkey 2FA.** The domain is baked into the credential's
  relying-party ID at registration time. Wrong `DOMAIN` and the *registration*
  of a security key or passkey fails, or worse, succeeds and then never
  validates — with a client-side error that says nothing about the server
  config. If 2FA registration is misbehaving, check `DOMAIN` first, not last.
- **Attachment and Send download URLs**, which are absolute.
- **Email links** (invitations, verification) — inert here, since no SMTP is
  configured.

Change the tailnet name or the published port and `DOMAIN` has to change with
it. `setup.sh` warns when `.env` disagrees with the live tailnet address; it
does not rewrite `.env` for you, because that file is yours.

**Already-registered WebAuthn credentials do not survive a `DOMAIN` change.**
If you move this service to a different hostname or port, re-register your
security keys and passkeys afterwards, and keep a TOTP method or the recovery
code to hand while you do it.

## Security model

- **Tailnet-only.** The container publishes `127.0.0.1:8222` and nothing else;
  Tailscale Serve terminates TLS. Not reachable from the LAN, not from the
  internet, no firewall rule opens it, and none should. The live suite asserts
  no non-loopback, non-tailnet listener exists on 8222.
- **HTTPS is not optional for this service, and you get it for free.** Web
  Crypto — which the web vault needs to decrypt anything — is unavailable on
  a plain-HTTP origin that isn't localhost. Tailscale Serve is what makes the
  vault work at all from another device, not just what makes it tidy.
- **The admin panel is off** (above), and the live suite proves it.
- **Signups close after you register**, and **org invitations are off**
  (above) — both doors, not just the obvious one. In `docker-compose.yml` the
  *defaults* for both are `false`, so a lost or truncated `.env` fails closed
  rather than reopening registration to the whole tailnet.
- **Password hints are off** (`SHOW_PASSWORD_HINT: "false"`). Vaultwarden
  serves a hint to *unauthenticated* callers who know an email address. A hint
  is a free clue about the one password that protects everything else.
- **Signup email verification is off** (`SIGNUPS_VERIFY: "false"`) — not
  laziness: with no SMTP on this box, verification would put a "check your
  email" wall in front of a mail that can never arrive, locking you out of the
  account you just created.
- **Zero-knowledge is the client's property, not the server's.** Item
  contents, TOTP seeds and notes are encrypted before they leave the client.
  Metadata is not: the server knows how many items you have, when they
  changed, and — because favicons are fetched for them — which sites they are
  for. That is Bitwarden's model too, not a Vaultwarden shortcut.
- **`rsa_key.pem` signs client JWTs.** Delete it and every device is logged
  out (recoverable — you log back in). It is in the data dir; it is covered by
  the backup command below.
- **The container runs as root**, which is upstream's design and not something
  this deploy changes. Consequence: files under `~/services/vaultwarden/data`
  are root-owned, so removing that directory needs `sudo`. See the
  nuke-and-pave recipe in TROUBLESHOOT.md.
- **No SMTP is configured.** Email-based flows are therefore inert: no
  verification mails, no invitation mails, no "new device logged in" alerts,
  and **emergency access invitations cannot be delivered**. Two-factor via
  email is not available either; use TOTP or WebAuthn.

## Backups (read this one)

`~/services/vaultwarden` is not backed up by anything on this box. Neither is
anything else here, but for a password vault the consequence is different in
kind: a lost photo is a sad memory, a lost vault is every account you own.

**Say it plainly: running a password vault with no backup job is a bad idea.**
Until one exists, do both of the following. They fail in different ways, which
is the entire point of doing both.

### 1. Cold copy of the server data

Complete — vault, attachments, Sends, the JWT key — and restorable onto a new
box by dropping it back in place. Useless if this machine is the thing that
died and the tarball was only ever on it.

```bash
cd ~/dev/setup-server/vaultwarden
docker compose --project-directory . stop
sudo tar czf ~/vaultwarden-$(date +%F).tgz -C ~/services/vaultwarden/data .
sudo chown $(id -u):$(id -g) ~/vaultwarden-$(date +%F).tgz
docker compose --project-directory . start
```

`stop` first: copying a live SQLite database can capture a torn write. The
`sudo` is because the container runs as root and owns those files.

Then get the tarball **off this machine** — Seafile at `:8443` is one
keystroke away and syncs to a device that is not this one. A backup that only
exists on the box it is backing up is not a backup.

⚠️ That tarball contains your entire vault, encrypted under your master
password and nothing else. Treat it like the vault: do not park it somewhere
casually shared.

### 2. Client-side encrypted export

This is the honest mitigation, and the one to actually do. It is produced by
the *client*, from the decrypted vault in front of you, so it **does not
depend on this server existing** — which is exactly the scenario the cold
copy cannot cover.

In any Bitwarden client: **Tools → Export vault**.

- File format: **`.json (Encrypted)`**
- Then choose **Password protected** — *not* "Account restricted".

That distinction is the whole thing. An **account-restricted** export is
encrypted with your account's key: if this server is gone and you have made a
fresh account elsewhere, that file is undecryptable and you have backed up
nothing. A **password-protected** export is encrypted under a passphrase you
type, and can be imported into any Bitwarden or Vaultwarden account, ever.

Store the file somewhere durable that is not this box, and store the
passphrase somewhere that is not the vault you just exported.

What the export does and does not carry:

- ✅ Logins, passwords, TOTP seeds, notes, custom fields, folders, card and
  identity items.
- ❌ **File attachments.** They are not included in any Bitwarden export, and
  no warning is shown. Only the cold copy above has them.
- ❌ Sends, and your 2FA *configuration* (you re-enrol on the new server).

Do this now, and again after any bulk change. A calendar reminder is a
reasonable substitute for a backup job; nothing is not.

### Restoring

- From the **cold copy**: stop the container, `sudo rm -rf` the data dir,
  untar the archive into `~/services/vaultwarden/data`, `./setup.sh`. Your
  accounts, devices and 2FA come back as they were.
- From the **encrypted export**: deploy a fresh Vaultwarden, register (same
  or a new master password — it does not have to match), then Tools → Import
  data → Bitwarden (json), supply the export passphrase. Re-enrol 2FA
  afterwards.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker's restart policy handles boot; no systemd unit | ✅ |
| Docker + Compose v2 | the one container | ✅ (incl. daemon reachability) |
| curl | the `/alive` readiness loop | ✅ |
| Tailscale, logged in, MagicDNS | publishing, **and** `DOMAIN` | ✅ (`BackendState` must be `Running`; DNS name must resolve) |
| python3 | counts users in `db.sqlite3` for the signup lifecycle — stdlib `sqlite3`, no pip | ✅ (**required**, not optional) |
| ~200 MB disk | image + a vault that will not realistically reach 1 GB | — |

No database server, no Redis, no reverse proxy of our own, no `sqlite3` CLI
binary needed on the host.

## Deploy

```bash
cd vaultwarden && ./setup.sh     # idempotent; rerun to upgrade/repair/lock
```

Step by step:

1. **Preflight** — OS, non-root, `curl`, `python3`, Docker daemon reachable,
   Compose v2, Tailscale `Running`, numeric ports.
2. **Resolve the tailnet name** from `tailscale status --json`, before
   anything is written — `DOMAIN` has to be correct at first boot for WebAuthn
   to enrol correctly later.
3. **`.env`** — written only if absent, mode 600: `VAULTWARDEN_VERSION=1.37.2`,
   `LOCAL_PORT=8222`, `TZ`, `VAULTWARDEN_DATA`, `VAULTWARDEN_DOMAIN`,
   `VAULTWARDEN_SIGNUPS_ALLOWED=true`, `VAULTWARDEN_INVITATIONS_ALLOWED=false`.
   **No admin token, no generated password, no secret key — none of the three
   exists in this deploy**, because Vaultwarden has no server-side account to
   log into. On a re-run `.env` is the source of truth: an existing file is
   never rewritten (the one exception being the `VAULTWARDEN_SIGNUPS_ALLOWED`
   line), and a `LOCAL_PORT=` on the command line that disagrees with it is
   ignored with a warning rather than silently moving a live vault out from
   under its data.
4. **`DOMAIN` drift check** — if the live tailnet name or HTTPS port no longer
   matches `.env`, it warns, spells out the fix, and reminds you that security
   keys will need re-registering. It does not rewrite `.env`.
5. **Free-disk advisory** (a disk that fills mid-write is how SQLite databases
   get corrupted), then **`docker compose up -d`** (first run pulls ~60 MB).
6. **Wait for `/alive`** — a retry loop, not a single shot. The endpoint
   answers 200 with an ISO timestamp once the server is up; before that the
   connection is simply *refused*, which `curl` reports as HTTP `000`. A script
   that treated the first `000` as fatal would fail roughly every cold start,
   so `000` is explicitly "not ready yet" here.
7. **Count the accounts** in `db.sqlite3` (read-only; `docker cp` fallback) and
   apply the signup lifecycle table above — including recreating the container
   when it flips the flag, and re-checking the container's environment
   afterwards to confirm the change actually landed.
8. **Check the other doors** on the running container: `INVITATIONS_ALLOWED`
   must be `false`, and any `ADMIN_TOKEN` is reported.
9. **`tailscale serve --bg --https=8222 http://127.0.0.1:8222`**, with the
   operator-grant (`sudo tailscale set --operator=$USER`, first run only) and
   approval-link fallbacks.
10. **Verify and report** — HTTPS `/alive` over the tailnet, then `GET
    /api/config`, which is unauthenticated and echoes back the domain the
    *server* will hand to WebAuthn. That is a stronger check than re-reading
    `.env`, which can only ever agree with itself. Then it prints the URL, the
    current signup state, the client setup, and the backup warning.

## Client side

Every client is an **official Bitwarden client**, pointed at this server.
There is nothing Vaultwarden-specific to install, and no third-party app to
trust.

**The server URL must be set before you log in**, on every client. It is on
the login screen, not in the app's settings, and it is easy to walk past.

`https://kai-home-server.taild6a23f.ts.net:8222`

### Register (once, first)

Open the URL in a browser on the tailnet → **Create account**. Pick a master
password you will not forget — there is no reset — and save the emergency
recovery code the client offers you. Then come back and run `./setup.sh`
again to close signups.

### Browser extension

Install **Bitwarden Password Manager** from your browser's store. On the
login screen, before entering anything: the **region / server selector** (a
gear or a "Logging in on:" dropdown) → **Self-hosted** → put the URL in
**Server URL** → Save. Then log in.

### Desktop app

Bitwarden desktop, same flow: gear icon on the login screen → Self-hosted →
Server URL → Save → log in.

### iOS / Android

Bitwarden app, login screen → the region selector at the top → **Self-hosted**
→ Server URL → Save → log in. Then turn on **autofill** in the OS settings, or
the app is a manual copy-paste tool.

### CLI

```bash
bw config server https://kai-home-server.taild6a23f.ts.net:8222
bw login
```

### Every client needs Tailscale connected

The server is unreachable off-tailnet **by design**. That is the security
boundary, so the requirement is not negotiable, and it has real consequences:

- Install Tailscale on every device that holds the vault — including the
  phone. The tailnet works over any internet connection, so this is not a
  "same network" requirement; it is a "Tailscale is running" requirement.
- **A borrowed or locked-down machine cannot reach your vault.** A hotel
  business-centre PC, a work laptop with an MDM that blocks VPN clients — no
  Tailscale, no vault. There is no web fallback.
- **Travelling:** the clients keep an encrypted local copy, so if Tailscale is
  down or blocked you can still **unlock and read** the vault offline in the
  extension and the mobile app. What fails is *sync* — new items and edits
  stay on that device until it reaches the server again, and a device that has
  never logged in cannot be set up at all. Log in to any device you plan to
  travel with **before** you leave.
- Corporate and some hotel networks block WireGuard's UDP; Tailscale usually
  falls back to a DERP relay, but "usually" is the operative word. If the vault
  needs to be reachable from somewhere hostile, carry the client-side export
  instead of hoping.

## Ops

- Status: `docker compose --project-directory . ps`
- Logs: `docker compose --project-directory . logs -f vaultwarden`
- Restart: `docker compose --project-directory . restart`
- Health: `curl -s http://127.0.0.1:8222/alive` → an ISO timestamp
- Signup state (authoritative — the running container, not `.env`):
  ```bash
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden \
    | grep -E 'SIGNUPS_ALLOWED|INVITATIONS_ALLOWED|ADMIN_TOKEN'
  ```
  Both flags should read `false` on a settled deploy, and `ADMIN_TOKEN` should
  not appear at all.
- User count, without stopping anything:
  ```bash
  python3 -c "import sqlite3;print(sqlite3.connect('file:$HOME/services/vaultwarden/data/db.sqlite3?mode=ro',uri=True).execute('select count(*) from users').fetchone()[0])"
  ```
- Upgrade: bump `VAULTWARDEN_VERSION` in `.env`, then
  `docker compose --project-directory . pull && ./setup.sh`.
  **Take a cold copy first** (above) — Vaultwarden runs schema migrations on
  start and they do not run backwards.
- Vault size: `sudo du -sh ~/services/vaultwarden/data/*`
- Purge the favicon cache (safe, regenerates):
  `sudo rm -rf ~/services/vaultwarden/data/icon_cache`

## Tests

```bash
./tests/run-tests.sh          # mocked, safe anywhere
./tests/run-tests.sh --live   # verify this machine's real deployment
```

The mocked suite runs the real `setup.sh` against a sandboxed `$HOME` and a
copied service directory, with PATH stubs for `docker`, `tailscale`, `curl`,
`sudo`, `id` and `python3`. Three of those stubs carry the weight:

- **`python3`** fakes the account count, so all four outcomes of the signup
  lifecycle can be driven deterministically — including the `docker cp`
  fallback and the count that cannot be read at all.
- **`docker`** models a container environment that is rebuilt from `.env` on
  every `up`. That makes "someone edited `.env` and never recreated" a state
  the suite can actually reach, which is the disagreement the whole design
  turns on.
- **`curl`** models a cold start as a *refused connection* (exit 7, HTTP
  `000`), not a tidy 503, because that is what one really looks like.

Covered: the five preflight failures (root, docker unreachable, Tailscale
down, non-numeric ports, python3 without `sqlite3`); a fresh deploy that
leaves signups **open** and says so unmissably; the re-run that **closes**
them once an account exists and confirms it against the container; the re-run
that correctly leaves them open when nobody has registered; the already-closed
no-op; an unreadable account count refusing to guess and exiting non-zero; the
`docker cp` fallback still closing the door; an `ADMIN_TOKEN` that reached the
container being warned about *and not contradicted by the closing summary*; a
blind `docker inspect` degrading to "unconfirmed" rather than over-claiming;
the readiness retry; `DOMAIN` drift and a server that reports a different
domain; port overrides; `.env` never overwritten; operator escalation; and the
serve-approval prompt. Plus static assertions that the compose file binds
loopback only, has no `ADMIN_TOKEN` key, and defaults both signups and
invitations to `false`.

The live suite proves the things a green deploy can still get wrong: that
`/admin/users` and `POST /admin` really are 404s and no `ADMIN_TOKEN` reached
the container, that nothing outside loopback and the tailnet address is
listening on 8222, that org invitations are off, that `DOMAIN` matches the
address clients are actually told to use — and it reports the current signup
state in plain language, loudly if the door is still open.

## Notes

- Port 8222 is Vaultwarden's community-convention host port; the HTTPS port
  matches the local port, following the newer convention in this repo. The
  container itself listens on **80**, which is why the compose mapping reads
  `127.0.0.1:8222:80`.
- The image is pinned to `vaultwarden/server:1.37.2` (web-vault 2026.7.0,
  released 2026-08-22), not `latest`. For a service where an upgrade runs
  irreversible migrations against the only copy of your passwords, an
  unattended `latest` is not a convenience.
- `db.sqlite3` is the *only* thing with no second copy anywhere. Everything
  else in this directory is regenerable from git.
