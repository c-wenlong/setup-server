# Kopifund

Personal finance tracker from the private
[lagom-studio/kopifund-finance](https://github.com/lagom-studio/kopifund-finance)
repo: bank, wallet, brokerage and CPF PDF statements parsed into one
categorised ledger, with a web UI and an iOS phone link.

This service replaces the launcher's From-GitHub `kopifund-finance` app with
the standard repo shape — and moves state onto the scheme kopifund-hub's
README already documents: the data folder **is** a git repository.

## Architecture

```
tailnet HTTPS :8300
      │  tailscale serve (TLS ends at the daemon)
      ▼
127.0.0.1:8300 ──► kopifund container (built from ~/services/kopifund/repo,
                   upstream's own Dockerfile; KOPIFUND_DATA=/data)
                          │ mount
                          ▼
                  ~/.kopifund  ◄─── unlocked git-crypt clone of
                  (the data     c-wenlong/kopifund-hub — GitHub holds
                   folder)      ciphertext only
                          ▲
              kopifund-sync user timer, every SYNC_SECONDS:
              commit local changes → fetch → merge → push
                          │
                          ▼
              MacBook does the same dance on its own ~/.kopifund

              kopifund-analyse user timer, every ANALYSE_SECONDS:
              rebuild ~/.kopifund/cache (stat results are per-machine,
              gitignored — the dashboard reads them)
```

Two repos, two jobs:

| Repo | Role on this box |
|---|---|
| `lagom-studio/kopifund-finance` | App source. Machine-managed clone at `~/services/kopifund/repo`, hard-reset every run; deployd polls `main` and re-runs setup.sh, which rebuilds the image. |
| `c-wenlong/kopifund-hub` | Data remote. `~/.kopifund` is a clone of it; git-crypt encrypts every file except `.gitattributes`, `.gitignore`, `README.md` before it leaves the machine, so GitHub stores ciphertext. Version history = rollback; push/pull = Mac sync. |

## Security model

- The container binds `127.0.0.1:8300` only; `tailscale serve` publishes
  `https://<host>.<tailnet>.ts.net:8300` tailnet-only. There is no login —
  the tailnet is the boundary, and the app's own device pairing guards
  non-loopback API reads on top of that.
- Data at rest on GitHub is git-crypt ciphertext. The symmetric key lives
  at `~/.config/kopifund/gitcrypt.key` (mode 600), is transferred by hand
  (`scp`), and is never committed anywhere. Losing it makes the hub repo
  unreadable permanently — keep a second copy in a password manager.
- `secrets/` inside the data folder travels through the hub repo like
  everything else — encrypted. `.env` (machine-specific) is gitignored by
  the hub repo and never leaves the box.
- `devices.json` (paired-phone bearer hashes) rides the same encrypted
  sync; it is mode 600 locally and never backed up anywhere else.

## Dependencies

| Requirement | Why |
|---|---|
| Linux or macOS, regular user | Conventions; root refused |
| Docker + Compose v2 | The image is built from upstream's Dockerfile (Python 3.14 inside; the host needs no Python) |
| git + non-interactive access to BOTH private repos | `gh auth setup-git`, or ssh deploy key + `KOPIFUND_*_URL` in ssh form |
| git-crypt 0.7+ | `apt install git-crypt` / `brew install git-crypt`. Without it the data clone stays ciphertext |
| The hub key at `~/.config/kopifund/gitcrypt.key` | Only for first provisioning on a machine (see below) |
| Tailscale up, MagicDNS on | Publish + the phone-link URL |

## What setup.sh does

1. Preflight: OS, non-root, curl, git, git-crypt, Docker, Tailscale, numeric
   ports, `git ls-remote` on **both** repos.
2. Writes `.env` (mode 600) if absent: ports, repo URLs,
   `SERVICE_HOME=~/services/kopifund`, `KOPIFUND_DATA=~/.kopifund`,
   `KOPIFUND_HOSTS`/`KOPIFUND_TAILNET_URL` from `tailscale status`,
   `SYNC_SECONDS=300`, `ANALYSE_SECONDS=86400`. Never overwrites.
3. Clones or hard-resets `~/services/kopifund/repo` to `origin/$KOPIFUND_REF`.
4. Provisions the data folder:
   - absent → clone kopifund-hub, `git-crypt unlock` with the key file
     (dies with the `scp` recipe when the key is missing);
   - present and sealed → unlock with the same key;
   - present and unlocked → kept, fast-forwarded when clean;
   - present but **not a clone** → refuses (never converts a populated
     folder in place).
5. Stops the old `app-kopifund-finance` container if it still runs (same
   app, same port; it is the old writer, so it goes down before the copy,
   and deleting its launcher tile is a manual last step).
6. Merges `~/services/apps/kopifund-finance/data` in once (the launcher
   app's data): files the clone lacks are filled in without clobbering
   anything already there; `kopifund.db` is overwritten only when the
   launcher's record is measurably richer — the `txn` row count decides,
   because a live app's db always *looks* newest by mtime even when it
   holds an empty record. When a side can't be counted it falls back to
   snapshot age (the clone's last `kopifund.db` commit vs the legacy
   db's own mtime, never clone checkout time). Marked done at
   `~/services/kopifund/state/legacy-adopted`.
7. Installs `~/services/kopifund/bin/{sync,analyse}.sh` and two timers —
   systemd user `kopifund-sync.timer` + `kopifund-analyse.timer` on Linux
   (plus `loginctl enable-linger`, sudo at most once), `com.kopifund.sync`
   + `com.kopifund.analyse` LaunchAgents on macOS.
8. `docker compose up -d --build`, waits on `/api/health`, publishes via
   Serve, verifies end-to-end HTTPS, then runs a first stats rebuild — a
   fresh clone's `cache/` is empty, and an empty cache is an empty
   dashboard.

## First deploy on this box (the checklist that actually ran)

```bash
sudo apt-get install -y git-crypt          # once
mkdir -p ~/.config/kopifund
scp mac:~/.config/kopifund/gitcrypt.key ~/.config/kopifund/gitcrypt.key
chmod 600 ~/.config/kopifund/gitcrypt.key
cd services/kopifund && ./setup.sh
```

Then, in the launcher: remove the `kopifund-finance` app tile (Remove keeps
its data — already adopted), **then re-run `./setup.sh` once**: the
launcher's Remove unpublishes any Serve port proxying to
`http://127.0.0.1:8300`, which is the same target this service owns, so the
publish has to be re-applied or the service goes dark. The box's
`~/.kopifund` now holds the launcher's data on top of the hub snapshot,
lands in the next sync snapshot, and the Mac pulls it on its next tick.

## Client-side setup

- **Browser**: `https://<host>.<tailnet>.ts.net:8300` from any tailnet
  device. On the MacBook this is the same data as a local `~/.kopifund`
  once the sync ticks — pick one writer at a time per file in practice.
- **iOS app**: Settings → Link a phone → scan the QR (SPEC, "Phone link").
  The QR carries `KOPIFUND_TAILNET_URL`, which is why it lives in `.env`:
  a container cannot ask tailscaled for the machine's name.
- **Another machine**: install git-crypt, place the key,
  `git clone <hub> ~/.kopifund && git-crypt unlock` — or run this same
  `setup.sh` there (it does all of that plus the app).

## The sync rules (what to expect)

- Every `SYNC_SECONDS` the timer commits local changes as
  `snapshot: <host> <time>`, fetches, fast-forwards or merges, and pushes.
- Both sides write → divergence is normal. The merge is deterministic: the
  tip with the **newer committer date** wins each conflicted file (a tie
  breaks on the lower sha), so two machines always pick the same winner
  and converge — no re-conflict every cycle.
- The loser's version of a both-changed file is kept beside it as
  `<name>.loser-<sha>` (identical name on both machines, so the copies
  themselves never conflict). Reconcile by hand, then delete the loser
  file; it rides the next snapshot out.
- `cache/`, `exports/`, `backups/`, `*.lock`, `*-wal`, `*-shm`, `.env` are
  gitignored upstream — they never sync. Rows committed into
  `kopifund.db-wal` would be stranded by that rule, so each tick first runs
  a passive SQLite checkpoint to fold them into the `.db` that does sync.
- `cache/` being per-machine means the stat results never travel: the
  app rebuilds them itself only after an in-app write, and a sync pull is
  no such write. `kopifund-analyse` exists for exactly this — every
  `ANALYSE_SECONDS` it runs `server/finance.py analyse --no-publish`
  inside the container (`--no-publish`: the machine that runs
  `make analyse` owns the Notion hub page; a second writer pushing the
  same metrics is redundant). Manual refresh anytime:
  `~/services/kopifund/bin/analyse.sh`.
- A **sealed** clone (files still `\0GITCRYPT…`) is never committed:
  `sync.sh` refuses until `git-crypt unlock <key>` runs.
- Manual snapshot anytime: `cd ~/.kopifund && git add -A && git commit &&
  git push`. `~/services/kopifund/bin/sync.sh` is the same thing plus the
  merge.

## Ops commands

```bash
# app
docker compose --project-directory services/kopifund ps|logs|restart
curl http://127.0.0.1:8300/api/health

# sync + stats
systemctl --user status kopifund-sync.timer kopifund-analyse.timer
journalctl --user -u kopifund-sync -u kopifund-analyse -f
                                           # macOS: ~/Library/Logs/kopifund-{sync,analyse}.log
~/services/kopifund/bin/sync.sh              # run a sync tick now
~/services/kopifund/bin/analyse.sh           # rebuild the stats cache now
git -C ~/.kopifund status

# re-deploy / upgrade — deployd does this on upstream commits
./setup.sh

# remove (keeps data + service home) / purge (keeps ONLY the data folder)
./teardown.sh [--purge]
```

`teardown.sh --purge` never deletes `~/.kopifund`: it is the shared hub
clone — the backup, not a leftover. Deleting it is a separate deliberate
act (`rm -rf ~/.kopifund` + `git-crypt` key kept, or the hub repo itself
still holds everything).
