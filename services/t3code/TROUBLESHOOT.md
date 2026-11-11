# t3code: troubleshooting

Triage in layers: is the process up → does loopback answer → is Serve
published → does the tailnet URL answer → is pairing the problem.

## Service layer

**`systemctl --user status t3code.service` shows failed / restart loop**

```bash
journalctl --user -u t3code.service -n 100 --no-pager
```

- `Exec format error` / missing binary: the `bin` symlink or release dir is
  broken. `cat ~/.local/share/t3code/installed-ver`, check
  `~/.local/share/t3code/bin/t3` exists, then re-run `./setup.sh` (it
  reinstalls when `installed-ver` and the binary disagree).
- Port already in use: something else holds `127.0.0.1:$LOCAL_PORT`.
  `ss -ltnp | grep $LOCAL_PORT`, free it or change `LOCAL_PORT` in `.env`
  and re-run.
- t3 can't find agent CLIs: the unit's `PATH` is fixed at deploy time.
  After installing a new agent CLI into a new location, re-run
  `./setup.sh` (it rewrites the unit) — or check `which claude codex`
  resolves inside the unit's `PATH`.

**Logs on macOS:** `tail -f ~/Library/Logs/t3code.log`;
restart with `launchctl kickstart -k gui/$(id -u)/com.setup-server.t3code`.

## Local health layer

```bash
curl -v http://127.0.0.1:8109/
```

- Connection refused: the unit isn't running (see above).
- Hangs or 5xx: t3 is up but unhealthy — journal will say why. First run
  after an upgrade can be slow while it migrates state in
  `~/services/t3code`.

## Publish layer

```bash
tailscale serve status
```

- No `https://<host>:8109` entry: re-run `./setup.sh` — it republishes.
  If it warns "already proxies to a different target", another service
  owns the port; pick another `HTTPS_PORT` in `.env`.
- Cert still minting: the first request on a new Serve port can take ~60s.
  Retry; `curl -v https://<host>:8109/` shows TLS errors until then.

## Client layer

- **Browser can't connect at all**: you are not on the tailnet, or the
  node is off. `tailscale status` on the client.
- **Paired before, now asked again / token rejected**: state was purged or
  the server was reinstalled fresh. Re-pair: `t3 pair --base-dir
  ~/services/t3code --tailscale --tailscale-serve-port <HTTPS_PORT>` on
  the box.
- **Pairing link is `http://127.0.0.1:...` and won't open on another
  device**: re-run `t3 pair` with `--tailscale` (and
  `--tailscale-serve-port` matching `HTTPS_PORT` in `.env`).
- **`t3 pair` says it can't reach the server**: it needs `--base-dir`
  pointing at the same `~/services/t3code` the unit uses (or
  `T3CODE_HOME`), and the server must be running.
- **Sessions/agent buttons missing**: t3 found no agent CLIs — check the
  unit's `PATH` note above.

## Nuke and pave

```bash
cd services/t3code
./teardown.sh --purge   # unpublish, stop, delete .env + unit + ~/services/t3code
./setup.sh              # fresh deploy on defaults (8109, latest release)
```

Keeps the release in `~/.local/share/t3code`; `rm -rf` that too for a
full clean. Note `--purge` deletes projects, threads and paired devices —
there is no backup.
