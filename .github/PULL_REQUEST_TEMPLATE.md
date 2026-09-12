## Summary

<!-- What does this PR do, and why? One or two sentences. -->

## Type of change

- [ ] New service (a new top-level directory with `setup.sh`, docs and tests)
- [ ] Fix to an existing `setup.sh` or its tests
- [ ] Documentation (README, DIRECTORY, SETUP.md, TROUBLESHOOT.md)
- [ ] CI / repo chore

## Checklist

- [ ] Mocked suite run for **every** service this PR touches (`./tests/run-tests.sh`), all green
- [ ] `./tests/run-tests.sh --live` run for each touched service that is deployed on this machine
- [ ] `setup.sh` is still idempotent: a re-run upgrades or repairs and never overwrites a user-edited config
- [ ] Services bind `127.0.0.1` and are published via `tailscale serve` (any deliberate non-loopback listener binds the node's tailnet IP, is documented, and is asserted by the live suite)
- [ ] Sudo, if any, is per command and announced before prompting
- [ ] Linux and macOS branches both handled, with test assertions gated on `$OS`
- [ ] No `.env`, credential, token or device identity in the diff (check the staged diff, not just the file list)
- [ ] README service table and `DIRECTORY.md` updated if the service list, ports or behaviour changed
- [ ] New service: added to `PUBLISHED` in `monitoring/seed_kuma.py` with a health path that actually fails when the service is broken
- [ ] Python touched: `python3 launcher/tests/test_server.py` green

## Test plan

<!-- What you ran, on what, and the counts you saw. -->

```bash
# commands you ran
```
