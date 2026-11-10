#!/usr/bin/env bash
#
# analyse.sh — rebuild the stat results the app reads
# (~/.kopifund/cache/results/). Installed by services/kopifund/setup.sh to
# ~/services/kopifund/bin/analyse.sh with __ENV_FILE__ baked in; run by the
# kopifund-analyse timer (systemd user timer on Linux, LaunchAgent on
# macOS), every ANALYSE_SECONDS.
#
# cache/ is per-machine: the data repo's .gitignore covers it, so a pull
# never brings the other machine's results. The app rebuilds them itself
# after an in-app write, but a sync landing a newer kopifund.db is no such
# write — without this timer the dashboard answers from the last local
# results forever.
#
# --no-publish: the Notion hub page is published by the owner's analyse on
# the machine that runs `make analyse`; a second writer pushing the same
# metrics is redundant, and the container need not hold a working Notion
# token for it.
#
# Quiet: exits 0 without a word when the container is not running (this
# machine may serve the app natively, the way the Mac does — its own
# writes rebuild the stats).

set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
CONTAINER="${KOPIFUND_CONTAINER:-kopifund}"

# setup.sh bakes `command -v docker` in: launchd and systemd run this with
# a bare PATH, so a docker CLI outside it (Docker Desktop on the Mac) must
# still resolve. KOPIFUND_DOCKER overrides for odd installs.
DOCKER="${KOPIFUND_DOCKER:-__DOCKER__}"

say() { printf 'kopifund-analyse: %s\n' "$*"; }

# A missing docker is real breakage, not a stopped container — say so.
if [ ! -x "$DOCKER" ]; then
  say "docker is not runnable at $DOCKER — re-run setup.sh"
  exit 1
fi
# The image carries the Python the pipeline needs (3.14); the host's may
# not. `docker inspect` fails outright when there is no such container.
if [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]; then
  exit 0
fi
if "$DOCKER" exec -w /app "$CONTAINER" python3 server/finance.py analyse --no-publish >/dev/null; then
  say "stats refreshed"
else
  say "analyse failed — the dashboard keeps the last results; next tick retries"
  exit 1
fi
