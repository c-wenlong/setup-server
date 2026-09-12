# Bootstrap plan — remote-desktop (Apache Guacamole + xrdp)

Build spec for the agent implementing this service. Read
`COMPETITIVE-ANALYSIS.md` first (why Guacamole, why xrdp, what it costs),
then the repo's `AGENTS.md` (non-negotiable conventions), then
`code-server/setup.sh` (reference implementation) and `beszel/` (closest
Docker analogue — `.env` generation, `docker compose --project-directory`,
`tailscale serve --bg --https=`, health-poll loop).

**Goal:** operate this host's desktop from a browser tab on the tailnet.
**Not a goal:** a containerized desktop, multi-user access, LAN or public
exposure, replacing code-server for terminal work.

## Architecture

```
Mac browser
  └─ https://kai-home-server.taild6a23f.ts.net:8094   (tailscale serve, TLS)
       └─ guacamole webapp  127.0.0.1:8094 → :8080 in container (Tomcat)
            └─ guacd  :4822                (HTML5 ⇄ RDP translation)
                 └─ xrdp  :3389            (host, NOT loopback — see D1)
                      └─ XFCE session as kaichen — real host FS, docker, ~/dev
```

State: `~/services/remote-desktop/{drive,recordings}`. Code: this directory.
Nothing of value lives in the containers.

## Step 0 — preflight facts to establish before writing code

Do these on the box first; two of them can invalidate the plan.

1. **Is a desktop environment installed?** `dpkg -l | grep -E 'xfce4|ubuntu-desktop'`,
   `systemctl get-default`. Assumption is *no* (server install). If GNOME is
   already present, raise D2 before installing XFCE alongside it.
2. **Port 8094 free?** `ss -ltn`, `tailscale serve status`, and the
   DIRECTORY.md table. ⚠️ 8092 is beszel's — an earlier draft of this plan
   said 8094 was free based on the table alone; confirm on the box.
   3389 must also be unclaimed.
3. **RAM headroom.** `free -m` with a model loaded in ollama. If a
   connected session would push the box into swap, say so before building —
   the fallback is in COMPETITIVE-ANALYSIS.md and it is a scope change the
   human should approve.

## Decisions to resolve first

**D1 — how guacd reaches xrdp.** This is the one genuine design problem and
it must be settled empirically before the compose file is written. xrdp on
`127.0.0.1` is unreachable from a bridge container; putting the webapp on
host networking collides with code-server on 8080. Two viable shapes:

- **Preferred:** a compose-defined bridge with a pinned subnet; bind xrdp
  to that bridge's **gateway address** (`address=` in `xrdp.ini`); guacd +
  webapp on that bridge; webapp published `127.0.0.1:8094:8080`. The
  gateway is a host-internal interface — not LAN-reachable, not
  tailnet-reachable — so this honours the security model's intent even
  though it is not literally `127.0.0.1`. **Document that reasoning in
  SETUP.md**; a future reader will otherwise read it as a violation.
- **Fallback:** `guacd` with `network_mode: host` and `command: -b 127.0.0.1`,
  webapp likewise on host networking with Tomcat repointed off 8080.
  Verify the image actually supports rebinding Tomcat before committing —
  do not assume an env var exists.

Whichever wins, the live suite must prove 3389 and 8094 are not reachable
from the tailnet address.

**D2 — xrdp or gnome-remote-desktop as the RDP backend.** Plan assumes
xrdp + XFCE: lighter, and by far the better-trodden pairing with Guacamole.
If the box already runs GNOME, pointing guacd at GNOME's system Remote
Login (`security=nla`, `ignore-cert=true`) avoids a second DE and gives the
Mac a native RDP path off the same backend. Less well-trodden. Ask.

**D3 — session recording.** Guacamole can record sessions to
`~/services/remote-desktop/recordings`. Off by default; it is disk with no
backup job behind it. Only enable if asked.

## Deliverables

Per the repo's required-files table, plus two additions:

| File | Notes |
|---|---|
| `setup.sh` | Entrypoint. Preflight → .env → host packages → xrdp → compose → serve → verify. |
| `docker-compose.yml` | guacd + guacamole webapp. **No Postgres** — see below. |
| `SETUP.md` | Architecture, security model incl. the D1 reasoning, deps, step-by-step, Mac client setup, ops. |
| `TROUBLESHOOT.md` | Layered triage (session → xrdp → guacd → webapp → serve → client). |
| `tests/run-tests.sh` + `tests/stubs/` | Mocked default, `--live` suite. |
| `AGENTS.md` | **Warranted here.** This service installs host packages and needs sudo on every run that changes them — a real deviation from the repo's container/user-unit norm. Document it so future agents don't "fix" it. |

## setup.sh — step spec

Idempotent throughout: re-running upgrades or repairs, never overwrites a
config the user may have edited (write only if absent).

1. **Preflight.** Refuse root. Branch on `uname -s` — Linux only; **die
   with a clear message on Darwin**, since a Mac cannot host this box's
   desktop. Require `docker`, `curl`, `tailscale`, `sudo`, `apt-get`.
2. **`.env` if absent**, mode 600, gitignored: `GUAC_PORT=8094`,
   `GUAC_STATE=$HOME/services/remote-desktop`, `GUAC_USER=kaichen`,
   `GUAC_PASSWORD=$(openssl rand -hex 16)`, `GUAC_RDP_HOST=<from D1>`.
   ⚠️ A password is unavoidable — Guacamole has no supported anonymous
   mode, so this is auth-by-necessity, not auth-as-substitute-for-tailnet.
   Note that distinction in SETUP.md and record the credential in
   DIRECTORY.md's "Credentials & auth" section per the password-sync rule.
3. **Host packages**, only if missing: `xfce4 xfce4-goodies xrdp`.
   Announce why before the sudo prompt (conventions: sudo is surgical and
   announced). Skip entirely when already installed so re-runs need no sudo.
4. **xrdp config.** `address=` per D1; add the `xrdp` user to `ssl-cert`
   (needed to read the host key); `~/.xsession` → `startxfce4` (write only
   if absent). Enable + start `xrdp`, `xrdp-sesman`.
5. **The polkit rule** — do not skip this. Without it every session throws
   repeating "Authentication required to create color managed device"
   dialogs. Drop a rule in `/etc/polkit-1/localauthority/50-local.d/` (or
   `/etc/polkit-1/rules.d/`) allowing `org.freedesktop.color-manager.*`
   for active local sessions. This is the single most common xrdp
   papercut and it is cheap to prevent.
6. **Guacamole config**, written only if absent, under `$GUAC_STATE/guac-home`:
   - `user-mapping.xml` — one `<authorize>` for `$GUAC_USER` with a
     salted sha256 hash of `$GUAC_PASSWORD`, containing one RDP connection:
     `hostname` per D1, `port 3389`, `security=any` (xrdp does not do NLA),
     `ignore-cert=true`, `resize-method=display-update`,
     `enable-drive=true` + `drive-path=/drive` bind-mounted from
     `$GUAC_STATE/drive`, `enable-wallpaper=false` for bandwidth.
   - Mount it as `GUACAMOLE_HOME`. **No database container** — file auth
     is the whole reason this is two containers instead of four.
7. **Compose up**, pinned `guacamole/guacd:1.6.0` and
   `guacamole/guacamole:1.6.0` (never `:latest` — see the CVE and FreeRDP
   notes in the analysis). Poll until the webapp answers on 127.0.0.1:8094.
8. **Publish:** `tailscale serve --bg --https="$PORT" "http://127.0.0.1:$PORT"`,
   tolerating "already set" like beszel does.
9. **Verify, then print** the URL, the username, where the password lives,
   and the ops commands. The health check must be a real one — per
   AdGuard's lesson in EXPLORATION.md, a listening socket is not a working
   service. Fetch the login page and assert Guacamole markup, not a 200.

## Tests

**Mocked (default).** Temp `$HOME`, PATH stubs in `tests/stubs/` for every
external command touched: `docker`, `tailscale`, `sudo`, `systemctl`,
`apt-get`, `dpkg`, `curl`, `openssl`, `id`, `uname`. Log to `$CALLS_LOG`,
state in `$STATE_DIR`. Cases at minimum:

- fresh install happy path
- **idempotent re-run: no `apt-get install`, no sudo, `.env` and
  `user-mapping.xml` byte-identical**
- `GUAC_PORT` override honoured through compose *and* `tailscale serve`
- preflight failures: root, Darwin, missing docker
- polkit rule written once, not duplicated

Harness gotcha from AGENTS.md: mocked tests override `$HOME` — restore it
in teardown or the live checks read a deleted sandbox.

**Live (`--live`).** Containers up; `xrdp`/`xrdp-sesman` active + enabled;
webapp answers on 127.0.0.1:8094; **8094 and 3389 refuse connections on
100.85.87.87**; `tailscale serve status` shows the mount; end-to-end HTTPS
fetch of the login page returns Guacamole markup.

## Registration (the step that gets forgotten)

1. Row in `DIRECTORY.md` services table + the credential in "Credentials & auth".
2. Row in root `README.md` table.
3. Monitor line in `monitoring/seed_kuma.py`.
4. Tile in `launcher/services.json`, including the `control` block so it can
   be started/stopped from ntfy-control and the launcher. Guacamole is a
   good stop-when-idle candidate given the RAM note.
5. Mark it ✅ in `EXPLORATION.md`, and while there fix the stale line 47
   claim that the box has no `nvidia-container-toolkit` — it was installed
   2026-09-11.

## Acceptance

A fresh browser on the tailnet reaches the URL, logs in, and lands in an
XFCE session on **this host** where `ls ~/dev` shows the real repos and
`docker ps` lists the real containers. Re-running `./setup.sh` changes
nothing and asks for no sudo. Both test suites pass. Measured RAM delta,
idle and connected, is recorded in SETUP.md.

## Rollback

`docker compose down`, `tailscale serve --https=8094 off`,
`sudo apt-get remove xrdp` (leave XFCE — harmless), delete
`~/services/remote-desktop`. Nothing else on the box is touched, which is the
point of keeping the host changes to two packages and one polkit rule.
