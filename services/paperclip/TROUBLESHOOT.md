# paperclip — Troubleshooting

Triage in layers, outermost failure first:

```
service up? → local /api/health → serve :3100 → tailnet HTTPS
```

Quick triage:

```bash
cd ~/dev/setup-server/services/paperclip
paperclipai service status
curl -fsS http://127.0.0.1:3100/api/health          # {"status":"ok"}
tailscale serve status
./tests/run-tests.sh --live
```

## Service will not start

```bash
paperclipai service logs --lines 200
paperclipai doctor
```

- **Node too old** — doctor fails below 24.11.0. This box's
  `~/.local/bin/node` is fine (v26); a shell that does not have
  `~/.local/bin` on `PATH` will pick up a distro 18/20 and look broken.
  `export PATH="$HOME/.local/bin:$PATH"`.
- **`local_trusted` after a hand edit** — if you re-onboarded with
  `--yes` and no `--bind`, Paperclip falls back to trusted-local. Serve
  would then expose an unauthenticated board. `setup.sh` patches this and
  dies if the string is still in `config.json`. Do not "fix" the patch
  away.
- **Port busy** — something else on 3100. `ss -ltn | grep 3100`. Move
  with `PAPERCLIP_PORT` in `.env` and a re-run. If you bounce the
  service while Serve still owns `:3100` on the tailnet IP, Paperclip
  treats that as busy and hops to **3101**. Drop Serve first:
  `tailscale serve --https=3100 off`, then `paperclipai service restart`.
- **Embedded Postgres** — first boot extracts a cluster under
  `~/.paperclip`. A killed onboard can leave a half-written `db/`.
  `doctor --repair --yes` is the official fix; do not delete the
  directory unless you are ready to lose the instance.

## `/api/health` fails but the unit is active

The service can be `active` while the server is still migrating. Wait a
minute and retry. If it stays dark:

- Confirm the listen address: `ss -ltn | grep 3100` must show
  `127.0.0.1:3100`. A tailnet-IP listener means the loopback rewrite did
  not run — re-run `./setup.sh`. `0.0.0.0:3100` is a leak; take Serve
  down (`tailscale serve --https=3100 off`) before debugging further.
- Confirm mode: `grep deploymentMode ~/.paperclip/instances/default/config.json`
  must be `authenticated`.

## Login / redirect errors on the MagicDNS name

```bash
paperclipai allowed-hostname kai-home-server.taild6a23f.ts.net
paperclipai service restart
```

`PAPERCLIP_PUBLIC_URL` in the instance `.env` must be the HTTPS Serve
URL, including the port, no trailing slash.

## Profile email is still read-only / no password field

Paperclip's own Profile page does not let you edit login credentials.
`setup.sh` injects `/pc-profile-credentials.js` into the managed UI and
enables Better Auth change-email. A `paperclipai update` overwrites
`ui-dist` and the Better Auth files; re-run `./setup.sh` to put them
back. Confirm:

```bash
curl -fsS http://127.0.0.1:3100/pc-profile-credentials.js | head
curl -fsS http://127.0.0.1:3100/ | grep pc-profile-credentials
```

Then hard-refresh Settings → Profile.

## CEO invite expired or missing

```bash
paperclipai auth bootstrap-ceo \
  --base-url https://kai-home-server.taild6a23f.ts.net:3100
```

`--force` if an admin already exists and you still need a fresh link.
The last invite is also in `~/services/paperclip/ceo-invite.txt`
(mode 600). If you still have the combined-service marker, the same
file may exist at `~/services/paperclip-openhands/ceo-invite.txt`.

## Agent will not start (Claude / Codex)

- **Claude** — `claude --version` and `claude auth status` on the host.
  Paperclip runs the host binary. setup.sh never copies `~/.claude`.
- **Codex** — not installed on this box today. Hire the adapter after
  `codex` is on `PATH`. Paperclip's per-agent `CODEX_HOME` will not
  rewrite yours.
- **cwd** — must be an absolute path the paperclip user can write.
  `~/agent-workspaces/paperclip-test` is the one setup.sh created.
- **Company / API key** — `agent create` only runs when
  `PAPERCLIP_COMPANY_ID` and `PAPERCLIP_API_KEY` are in `.env`. Until
  then, hire in the UI.

## Serve / HTTPS

```bash
tailscale serve status
# expect:
#   :3100 -> http://127.0.0.1:3100
```

- Cert still minting: wait a minute, `curl -I` the HTTPS URL.
- Operator denied: `sudo tailscale set --operator="$USER"` then re-run.
- Never `tailscale serve reset` — it wipes every service on this box.
- Never enable Funnel.

## Nuke and pave

Use [teardown.sh](teardown.sh); do not hand-run a recipe that can drift.

```bash
cd ~/dev/setup-server/services/paperclip
./teardown.sh            # Serve off, paperclipai.service disabled; everything kept
./setup.sh               # brings it back as it was
```

What it guards against:

- **Port hop.** Serve is dropped *before* the unit stops. Serve ports are
  found from `tailscale serve status`: every port whose handlers all
  proxy to `PAPERCLIP_PORT`, plus the hopped port (e.g. 3101) in
  `~/.paperclip/instances/default/runtime-info.json`, but only while that
  pid is still a running `paperclipai run`. A stale record, or a
  `config.json` port that disagrees with `.env`, is reported and left
  alone. A port shared with another handler stays on with a warning.
  Never `serve reset`.
- **The CLI.** It calls `systemctl --user` / `launchctl` directly, never
  `paperclipai uninstall` (that deletes the managed CLI store).
- **Neighbours.** OpenHands units and containers, and other
  `paperclipai-*` instances, are named and left alone.

For a fresh start, **back up the secrets key first**:
`~/.paperclip/instances/default/secrets/master.key` decrypts every stored
secret, so without it any backup of the database is useless. Copy it off
the box (Seafile `:8443`), then:

```bash
./teardown.sh --purge    # type "paperclip"; also deletes .env, the unit file,
                         # and the CEO invite + agent markers in ~/services/paperclip
```

`--purge` never deletes `~/.paperclip` (instance and managed CLI),
`~/agent-workspaces`, `~/.claude` or `~/.codex`. It refuses a `.env` whose
`PAPERCLIP_DATA` / `AGENT_WORKSPACES` points into `~/.claude`, `~/.codex`,
`$HOME` or another service's folder. It prints the exact `rm` commands for
the instance and the CLI store; run them yourself once `master.key` is safe.
Until the instance is gone, `./setup.sh` reuses it.
