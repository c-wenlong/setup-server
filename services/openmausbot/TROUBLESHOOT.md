# OpenMausBot troubleshooting

Work from the service outward: process → local health → Serve publish →
browser/pairing.

## Service won't start / keeps restarting

```sh
systemctl --user status openmausbot        # Linux
journalctl --user -u openmausbot -e        # recent logs
launchctl print gui/$UID/com.openmausbot.server   # macOS
tail ~/Library/Logs/openmausbot*.log       # macOS logs
```

- **`openmausbot: command not found`** in the unit: `.env`'s `OMB_BIN`/
  `NODE_BIN` are stale (node/npm moved since first deploy). Fix the paths in
  `services/openmausbot/.env`, or delete `.env` and re-run `./setup.sh`.
- **Node < 24**: upstream requires Node 24+. Install a newer Node, delete
  `.env` (so `NODE_BIN`/`OMB_BIN` get rewritten), re-run.
- **Port already in use**: something else owns `127.0.0.1:$OMB_PORT`
  (`ss -tlnp 'sport = :8799'`). Change `OMB_PORT`/`HTTPS_PORT` in `.env`
  and update `OMB_PUBLIC_URL` to the new HTTPS port too (setup preserves
  the existing `.env`, so it does not recompute it). Re-run `./setup.sh`.

## Local health fails but the unit is running

```sh
curl -fsS http://127.0.0.1:8799/api/health
```

A non-zero exit with the unit active usually means the server is still
starting (first boot does browser/engine discovery) — give it a few seconds,
then check the journal for a bind or data-dir error. `OMB_DATA_DIR` under
`~/services/openmausbot/data` must be writable by this user.

## Tailnet URL doesn't load

```sh
tailscale serve status      # is :8799 → http://127.0.0.1:8799 listed?
tailscale status            # is tailscaled up?
```

- Serve entry missing → re-run `./setup.sh` (it re-publishes).
- First-ever Serve use needs a one-time approval in the tailnet admin
  console; `setup.sh` prints the link and retries until you approve it.
- `sudo tailscale set --operator=$USER` was applied on Linux so `serve`
  works without sudo; if it got revoked, re-run setup.

## Browser says "unpaired" / pairing doesn't stick

Browsers never inherit loopback trust — that is upstream's design on every
server, and why `OMB_LOOPBACK_TRUST=service` (which would also break
`openmausbot pair` on the box) is not used. Mint a code on the box:

```sh
openmausbot pair --label "my laptop"
```

Open the printed `/pair#code=...` link in the browser once. If codes keep
expiring, check `journalctl --user -u openmausbot` while minting — codes are
short-lived and single-use. Never echo them into logs or chat.

## Bot can't run its engine

Engines are separate CLIs signed in **as this user** on the box — the unit
inherits only `PATH`, not your SSH session's agent. `claude auth` /
`codex auth` (or the engine's own login) on the box, then the bot works.
Cursor and Devin-ACP adapters were not verified upstream at deploy time —
check upstream docs before counting on them.

## Devin engine shows only "Agent default"

`POST /api/instances/devin/refresh-models` silently fails for Devin: the
discovery calls `session/set_config_option` once per advertised model under
a 60s global budget, and Devin advertises ~130. Run the seeder shipped in
`contrib/devin-seed-models` — it pulls the full list from `session/new` in
one shot and writes the startup cache:

```sh
install -m 755 contrib/devin-seed-models ~/.local/bin/
devin-seed-models && systemctl --user restart openmausbot
```

If the engine itself reports `unavailable`, `devin acp --version` exit code
2 is usually the cause — the instance `cli` must point at the `devin-acp`
shim, not `devin acp` directly (see SETUP.md → Devin over ACP).

## Nuke and pave

```sh
./teardown.sh            # stops + disables the unit, unpublishes Serve,
                         # keeps .env and ~/services/openmausbot (data)
./teardown.sh --purge    # after typing "openmausbot": also deletes the unit
                         # file, .env, and the data dir
```

`--purge` is destructive and unrecoverable — bots, chats, memories and the
paired-browser list are gone. The npm package stays (`npm uninstall -g
openmausbot` to remove it), and `~/.openmausbot` (a native install's data,
never this service's) and engine credentials (`~/.claude`, `~/.codex`) are
untouched either way.
