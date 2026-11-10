# deployd: Troubleshooting

Work top-down: the timer, then the tick, then the entry.

```
1. timer running?  →  2. ticks succeeding?  →  3. entry discovered?  →  4. remote resolved?  →  5. cmd succeeded?
```

Quick triage (on the box):

```sh
systemctl --user list-timers deployd.timer      # expect a NEXT time
journalctl --user -u deployd -n 100 --no-pager  # last ticks
~/services/deployd/bin/deployd --status         # what it thinks it deployed
ls ~/services/deployd/state/                    # <key>.sha / .fail / .log
```

Or just: `./tests/run-tests.sh --live`

## "Pushed to main, nothing deployed"

1. Did the tick even run? `journalctl --user -u deployd --since -10m`
   should show a `deployd:` line per cycle. Silence means the timer is off:
   `systemctl --user list-timers deployd.timer`, and on a headless box check
   lingering — `loginctl show-user $USER -p Linger` must say `yes`, or the
   user units die with your session.
2. Did the checkout pull? deployd reads config from the checkout at
   `SETUP_REPO` (see `.env`); if `git pull --ff-only` failed (dirty tree,
   diverged), the new `deploy` block was never seen. The journal warns
   `setup-server pull did not apply` — fix the checkout by hand.
3. Is the block well-formed? `deployd --status` lists what was discovered;
   a missing entry means a malformed `app.json` (`deploy` needs `repo` +
   `cmd`; `"enabled": false` also skips it) — the journal names the file.
4. Did the remote resolve? `git ls-remote <repo> refs/heads/<ref>` must
   print a sha. Private repos need working git credentials for this user —
   the poll runs non-interactive (`GIT_TERMINAL_PROMPT=0`), so an auth
   prompt shows up as an `ls-remote` failure, not a hang.
5. Did the cmd run and fail? The tick exits non-zero and
   `state/<key>.fail` appears; the cmd's output tail is in
   `state/<key>.log` (full output in the journal). The same sha is not
   retried for `RETRY_SECONDS` — remove the `.fail` file or
   `deployd --force <key>` to retry now.

## "Deploy ran but the service didn't change"

The `cmd` did run — deployd only triggers; what happens next is the
service's own script. Read `state/<key>.log`, then that service's
TROUBLESHOOT.md. For quiver-hub remember `QUIVER_REF=$DEPLOY_SHA` pins the
install to the polled sha — an unpinned `cmd` re-resolves the ref and can
install something newer than the recorded sha (self-corrects next tick).

## "journalctl shows ticks failing every minute"

One entry is failing every poll. `--status` shows which and how long ago
the last attempt failed. Fix the cmd or the repo; deployd recovers alone.

## "another poll is running" forever

A killed poll left `~/services/deployd/.poll.lock` behind. deployd reclaims
it once it is 60 min old; to clear it sooner, `rmdir` it when no `deployd`
process is actually running.

## "teardown refused: a poll is mid-run"

Deliberate — the running tick may be inside another service's setup.sh and
killing it could leave that service half-configured. The timer is already
disabled, so nothing new starts; re-run teardown when the lock clears.

## "teardown --purge kept my SERVICE_HOME"

`--purge` only deletes directories it can prove live at or inside
`~/services/deployd` — a `.env` pointing `SERVICE_HOME` anywhere else
(a custom state dir, a typo, a symlink) is kept on purpose, because the
value alone cannot prove the data is deployd's. The units and `.env` are
still removed; teardown prints the `rm -rf -- <path>` line for the kept
directory so you can finish the job by hand.

## "teardown refused: no .env / malformed .env"

teardown reads `.env` to find `SERVICE_HOME` and never executes it. No file
means setup.sh never ran here — nothing to tear down. A file it cannot
read the way setup.sh would (a line that is not `KEY=value`, a key set
twice, an unclosed quote, a backslash escape) is refused rather than
guessed: fix the named line and re-run.

## "I edited a deploy block but the old one still runs"

Check which checkout `SETUP_REPO` in `.env` names — `app.json` is read from
*that* working tree, committed or not, so uncommitted edits there already
apply on the next tick. If you edited a *different* clone, commit + push
and let the tick pull it in. One caveat: uncommitted local changes leave
that tree dirty, so `git pull --ff-only` stops applying until they are
committed or stashed. Same for `POLL_SECONDS`: it is baked into the timer;
edit `.env` and re-run `setup.sh`.

## macOS: nothing runs at all

```sh
launchctl print gui/$(id -u)/com.setup-server.deployd   # loaded?
tail -50 ~/Library/Logs/deployd.log
```

A `bootstrap` that fails usually means the plist was left `disabled` —
`launchctl enable gui/$(id -u)/com.setup-server.deployd`, then re-run
`setup.sh` (it enables before bootstrapping, so a plain re-run fixes it).
