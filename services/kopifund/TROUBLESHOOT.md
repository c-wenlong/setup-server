# Kopifund troubleshooting

Work the layers in order: service → local health → publish → client →
sync. Most "kopifund is weird" reports are really the data clone.

## 1. Service

```bash
docker ps -a --filter name=kopifund
docker compose --project-directory services/kopifund logs --tail=100 kopifund
docker compose --project-directory services/kopifund restart
```

| Symptom | Likely cause | Fix |
|---|---|---|
| container exits at boot | `KOPIFUND_DATA` mount unreadable, or the clone is sealed | `ls -ld ~/.kopifund`; `head -c9 ~/.kopifund/config.toml` shows `\0GITCRYPT` → `cd ~/.kopifund && git-crypt unlock ~/.config/kopifund/gitcrypt.key` |
| `docker compose up` says the Dockerfile is missing | source clone pruned or never cloned | `git -C ~/services/kopifund/repo status`; re-run `./setup.sh` |
| port 8300 already bound | the old launcher app still runs | `docker stop app-kopifund-finance`, then remove its tile in the launcher; re-run `./setup.sh` |

## 2. Local health

```bash
curl -v http://127.0.0.1:8300/api/health        # want {"ok":true} / 200
ss -ltn | grep 8300                              # must be 127.0.0.1 only
```

Nothing listening → container down (section 1). Listening on a non-loopback
address → the compose file was edited; restore `127.0.0.1:` and re-run
setup.sh.

## 3. Publish

```bash
tailscale serve status | grep -A2 8300
curl https://<host>.<tailnet>.ts.net:8300/api/health
```

| Symptom | Fix |
|---|---|
| no `:8300` block | `./setup.sh` re-publishes; a first-ever Serve publish may need the one-time enablement link it prints |
| `:8300` proxies elsewhere | deliberate repoint (Serve does not steal foreign mappings). `tailscale serve --https=8300 off`, re-run setup.sh |
| TLS/cert error only | cert still minting; wait ~60s and retry |

## 4. Client

- Phone pair QR dead or refuses: `KOPIFUND_TAILNET_URL` in `.env` must be
  this machine's current `https://<tailnet-name>:<port>` — setup.sh warns
  on drift; fix `.env` and re-run. `python3 server/finance.py link` inside
  the source clone is upstream's own checklist.
- 401 on the phone after pairing: the device row was revoked or never
  landed → Settings → Link a phone again (`devices.json` lives in the data
  folder, so a revoked phone loses access without a token round).

## 5. Sync (the layer most things actually are)

```bash
journalctl --user -u kopifund-sync --since today    # Linux
tail -50 ~/Library/Logs/kopifund-sync.log           # macOS
git -C ~/.kopifund status
git -C ~/.kopifund log --oneline -10
```

| Symptom | Cause | Fix |
|---|---|---|
| `data folder is git-crypt locked` in the log | clone sealed (fresh clone before unlock, or `git-crypt lock` ran) | `cd ~/.kopifund && git-crypt unlock ~/.config/kopifund/gitcrypt.key` |
| `fetch failed` | offline, or gh token expired | `git -C ~/.kopifund fetch` by hand; re-auth `gh auth login && gh auth setup-git` |
| `share no history` | the clone's origin is not kopifund-hub, or history was rewritten | check `git -C ~/.kopifund remote -v`; re-clone into a fresh path and reconcile |
| `*.loser-<sha>` files appear | two machines wrote the same file between ticks — expected, not an error | diff the loser against the live file, merge what matters by hand, `git rm` the loser and let the next tick push |
| The Mac never sees server changes | its sync isn't running, or it keeps losing merges | on the Mac: `launchctl list com.kopifund.sync`, check its log; remember the newer commit wins — an idle Mac's stale write can still win if stamped newer |
| `kopifund.db` looks rolled back | the other machine's newer snapshot won the merge | the losing db is beside it as `kopifund.db.loser-<sha>` — restore or re-import from it |
| Dashboard is empty though `/api/health` answers | the stat results in `cache/` are per-machine (gitignored): a fresh clone or a pulled ledger has none until `analyse` runs | `~/services/kopifund/bin/analyse.sh`, then reload — `kopifund-analyse.timer` keeps it fresh after that (`journalctl --user -u kopifund-analyse`) |
| The launcher's data "lost" after first setup | adoption kept the clone's ledger because its `txn` count was richer | the launcher's `kopifund.db` still sits in `~/services/apps/kopifund-finance/data/` — reconcile by hand; `~/services/kopifund/state/legacy-adopted` is the one-time marker |

Manual control: `~/services/kopifund/bin/sync.sh` runs one sync tick now;
`~/services/kopifund/bin/analyse.sh` rebuilds the stats cache now.
`systemctl --user stop kopifund-sync.timer kopifund-analyse.timer` pauses
both (Linux) — `launchctl bootout gui/$(id -u)/com.kopifund.{sync,analyse}`
on macOS.

## 6. Deploy loop (deployd)

`~/services/deployd/state/` holds per-service logs. Kopifund's `deploy`
block polls `kopifund-finance@main` and re-runs `services/kopifund/setup.sh`
on a new sha: fetch → hard-reset the clone → rebuild the image. A build
that fails leaves the previous container running.

## Nuke and pave

```bash
./teardown.sh            # unpublish, stop timer, compose down; keeps everything
./teardown.sh --purge    # + ~/services/kopifund and .env — NEVER the data folder
```

To truly start over including data: teardown, then
`rm -rf ~/.kopifund` — the hub repo still holds the encrypted history, so a
re-run of setup.sh re-clones and unlocks it (key file must be in place).
For a genuinely blank ledger, delete the local clone AND the
`c-wenlong/kopifund-hub` repo on GitHub, then re-create it.
