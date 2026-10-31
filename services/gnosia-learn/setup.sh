#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of gnosia-learn (Gnosia study hub) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - machine-managed clone of github.com/c-wenlong/self-learn (the gnosia
#     repo) at
#     ~/services/gnosia-learn/repo (hard-reset on every deploy — not a
#     working copy; write app config via this service's .env)
#   - the catalog as one SQLite file at $CATALOG_DB under the data root
#     ($GNOSIA_HOME; SELF_LEARN_HOME names the same root in an older
#     .env) — no database server runs (upstream docs/SQLITE-MIGRATION.md)
#   - production Next.js app (`next build` + `next start`) on
#     127.0.0.1:LOCAL_PORT, under a systemd user unit (Linux) or launchd
#     LaunchAgent (macOS)
#   - catalog bootstrapped once: migrate, `import seed`, six `flip`s,
#     `blob audit --fix` to claim the blob store at $GNOSIA_HOME
#   - two schedulers: deployd (services/deployd) polls the repo's remote
#     and re-runs this script when main moves (pull -> ci -> migrate ->
#     build -> restart), and a nightly catalog export timer (03:00)
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#
# Usage:
#   ./setup.sh                              # deploy with defaults
#   LOCAL_PORT=8200 ./setup.sh              # HTTPS follows LOCAL_PORT
#   SKIP_SEED=1 ./setup.sh                  # no seed import/flips — drop the
#                                           # laptop's catalog.db in place
#                                           # instead
#   OWNER_PASSWORD=x AUTH_SECRET=y ./setup.sh   # set on first run only
#                                           # (use the laptop's AUTH_SECRET so
#                                           # provider keys stay readable)
#
# Requirements beyond the repo baseline (curl, Tailscale): git with
# non-interactive access to the private repo (gh auth setup-git, or a deploy
# key), Node.js >= 22.22.2 (engines field in upstream's package.json).
#
# Idempotent: safe to re-run. Re-running pulls new commits through the
# deploy script, repairs any missing piece (and removes the old per-service
# deploy timer if a host still has one), and never overwrites the .env. The
# seeded marker in ~/services/gnosia-learn/state means the catalog bootstrap
# runs once, ever.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8107}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
REPO_URL="${REPO_URL:-https://github.com/c-wenlong/self-learn.git}"
BRANCH="${BRANCH:-main}"
SKIP_SEED="${SKIP_SEED:-0}"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

# deployd's runtime home is SERVICE_HOME in services/deployd/.env —
# overridable there; the conventional path is the fallback.
DEPLOYD_HOME="$HOME/services/deployd"
if [ -f "$SERVICE_DIR/../deployd/.env" ]; then
  d="$(sed -n "s/^SERVICE_HOME=\(.*\)\$/\1/p" "$SERVICE_DIR/../deployd/.env" \
       | tail -1 | sed "s/^'//; s/'\$//; s/^\"//; s/\"\$//")"
  case "$d" in \~/*) d="$HOME/${d#\~/}" ;; \$HOME/*) d="$HOME/${d#\$HOME/}" ;; esac
  [ -n "$d" ] && DEPLOYD_HOME="$d"
fi

# A manual ./setup.sh re-installs the service: clear deployd's disabled
# flag (written by teardown.sh) so auto-deploy resumes. deployd itself
# never invokes this while the flag is set, so clearing is always manual.
rm -f "$DEPLOYD_HOME/state/gnosia-learn.disabled"

# A re-run (e.g. under deployd, whose PATH is minimal) finds node where the
# first install recorded it in .env — put that dir on PATH ahead of any
# older system node so the version check sees the saved one.
if [ -f "$ENV_FILE" ]; then
  d="$(sed -n "s/^NODE_BIN=\(.*\)\$/\1/p" "$ENV_FILE" | sed "s/^'//; s/'\$//")"
  [ -n "$d" ] && [ -d "$d" ] && PATH="$d:$PATH"
fi

# Hex is URL-safe and survives .env without quoting.
randhex() {
  local n="${1:-16}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_hex($n))"
  else
    od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
    echo
  fi
}

# Compare dotted versions without GNU sort: node_at_least 22.22.2
node_at_least() {
  local have
  have="$(node --version 2>/dev/null | sed 's/^v//')"
  [ -n "$have" ] || return 1
  awk -v have="$have" -v want="$1" 'BEGIN{
    split(have, h, "."); split(want, w, ".");
    for (i = 1; i <= 3; i++) {
      hv = h[i] + 0; wv = w[i] + 0;
      if (hv > wv) exit 0;
      if (hv < wv) exit 1;
    }
    exit 0
  }'
}

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
command -v curl >/dev/null || die "curl is required."
command -v git >/dev/null || die "git is required."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

command -v node >/dev/null || die "Node.js >= 22.22.2 is required (upstream engines field). Install node, then re-run."
node_at_least "22.22.2" \
  || die "Node.js >= 22.22.2 is required (found: $(node --version)). Upgrade node and re-run."

resolve_tailscale
require_tailscale_up

# deployd polls and the deploy fetches the (private) repo unattended — verify that works now.
if ! GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REPO_URL" >/dev/null 2>&1; then
  die "Cannot read $REPO_URL non-interactively. Fix auth first: gh auth login && gh auth setup-git (or use an SSH deploy key and set REPO_URL accordingly)."
fi

require_numeric LOCAL_PORT HTTPS_PORT
ok "$OS + curl + git (repo reachable) + node $(node --version) + Tailscale (running)"

host="$(tailnet_host)"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (ports, paths, generated secrets — mode 600)"
  owner_pass="${OWNER_PASSWORD:-$(randhex 12)}"
  auth_secret="${AUTH_SECRET:-$(randhex 32)}"
  ( umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600. Edit + re-run to apply.
REPO_URL=$REPO_URL
BRANCH=$BRANCH

LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT

SERVICE_HOME=$HOME/services/gnosia-learn
# Upstream's own layout (docs/HOMESERVER.md): blobs/, vault/ and archive/
# live under GNOSIA_HOME, outside ~/services — it is the rsync target when
# the laptop's blob store is copied over. Upstream reads GNOSIA_HOME as its
# data root (default ~/.gnosia) and keeps the catalog as one SQLite file
# under it (docs/SQLITE-MIGRATION.md) — no database server runs. An .env
# written before the rename may hold only SELF_LEARN_HOME; it names the
# same root and is still honoured (below), so an older install's
# ~/.self-learn data root stays put.
GNOSIA_HOME=$HOME/.gnosia
CATALOG_DB=$HOME/.gnosia/catalog.db
NODE_BIN=$(dirname "$(command -v node)")
PUBLIC_URL=https://$host:$HTTPS_PORT

# Upstream feature flags (apps/web/.env.local). STUDIO_ENABLED=1 turns on the
# diagram-studio UI and runs the studio job-runner service, which spawns the
# claude CLI per job — flip to 1 only on a machine with the CLI installed and
# its credentials logged in.
STUDIO_ENABLED=${STUDIO_ENABLED:-0}
ASSET_FILES_ENABLED=${ASSET_FILES_ENABLED:-1}

# What is typed on /sign-in, and the key sealing the session cookie and any
# provider keys saved in Settings. Set AUTH_SECRET to the LAPTOP's value on
# first run to keep saved keys readable across machines (upstream S4);
# rotating it later signs every browser out and unseals saved keys.
OWNER_PASSWORD=$owner_pass
AUTH_SECRET=$auth_secret
EOF
  )
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports, paths and
# credentials, so a re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
REQUESTED_HTTPS="$HTTPS_PORT"   # only meaningful when HTTPS_PORT_EXPLICIT is set
set -a; . "$ENV_FILE"; set +a
SERVICE_HOME="${SERVICE_HOME:?SERVICE_HOME missing from $ENV_FILE}"
# An .env written before the SQLite cut-over holds a postgres DATABASE_URL
# and POSTGRES_* keys instead of the two below; the URL is simply unused now
# and the leftovers are harmless, so neither is read or required here. The
# data root and catalog file are derived the way upstream resolves them
# (docs/SQLITE-MIGRATION.md): CATALOG_DB under GNOSIA_HOME. SELF_LEARN_HOME
# is the pre-rename name for the same root — an older .env may hold only it
# — so it still works as the fallback. Exported so host-side
# `npm run catalog` calls below (the bootstrap) reach the same file.
SELF_LEARN_HOME="${SELF_LEARN_HOME:-}"
GNOSIA_HOME="${GNOSIA_HOME:-$SELF_LEARN_HOME}"
[ -n "$GNOSIA_HOME" ] || die "GNOSIA_HOME missing from $ENV_FILE (an older .env names the data root SELF_LEARN_HOME)"
CATALOG_DB="${CATALOG_DB:-$GNOSIA_HOME/catalog.db}"
export GNOSIA_HOME CATALOG_DB
NODE_BIN="${NODE_BIN:?NODE_BIN missing from $ENV_FILE}"
PUBLIC_URL="${PUBLIC_URL:?PUBLIC_URL missing from $ENV_FILE}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
if [ -n "$HTTPS_PORT_EXPLICIT" ] && [ "$HTTPS_PORT" != "$REQUESTED_HTTPS" ]; then
  warn "HTTPS_PORT=$REQUESTED_HTTPS ignored — the existing $ENV_FILE says $HTTPS_PORT. Edit .env and re-run to move the port."
fi
REPO_DIR="$SERVICE_HOME/repo"
UNIT_DIR="$HOME/.config/systemd/user"
WEB_PLIST="$HOME/Library/LaunchAgents/com.gnosia-learn.web.plist"
STUDIO_PLIST="$HOME/Library/LaunchAgents/com.gnosia-learn.studio.plist"
STUDIO_ENABLED="${STUDIO_ENABLED:-0}"

# The studio runner spawns the Claude CLI once per job. `command -v` covers an
# interactive PATH; the fallbacks cover ssh-triggered runs, where a headless
# login shell often misses ~/.nix-profile and /opt/homebrew.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ]; then
  for c in "$HOME/.nix-profile/bin/claude" "$HOME/.claude/local/claude" \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
fi
CLAUDE_PATH=""
[ -n "$CLAUDE_BIN" ] && CLAUDE_PATH="$(dirname "$CLAUDE_BIN"):"
if [ "$STUDIO_ENABLED" = "1" ] && [ -z "$CLAUDE_BIN" ]; then
  warn "STUDIO_ENABLED=1 but no claude CLI found — studio jobs will fail until it is installed."
fi

# The blob root upstream derives is $GNOSIA_HOME/blobs, and better-sqlite3
# will not create a missing parent for $CATALOG_DB.
mkdir -p "$SERVICE_HOME/bin" "$SERVICE_HOME/state" "$GNOSIA_HOME/blobs" \
  "$(dirname "$CATALOG_DB")"

# ------------------------------------------- existing deployment state
# Captured before anything is touched: a previously deployed app that is
# stopped stays stopped across a re-run — the launcher's stop must survive
# setup the same way it survives a deploy. state/built-sha proves an
# earlier run finished a first deploy; without it the install was
# interrupted and the start below repairs rather than overrides. A *failed*
# unit is restarted too (that's the repair), so only clean-inactive counts.
# state/torn-down is teardown.sh's note that the stop was a removal, not the
# owner's stop: setup after a teardown brings the stack back up. Any start of
# the app — launcher, phone or service manager — consumes it (the unit and the
# LaunchAgent delete it before the app comes up), so a later stop reads as the
# owner's again.
APP_SHOULD_RUN=1
STUDIO_SHOULD_RUN=1
TORN_DOWN="$SERVICE_HOME/state/torn-down"
if [ -f "$SERVICE_HOME/state/built-sha" ] && [ ! -f "$TORN_DOWN" ]; then
  if [ "$OS" = "Linux" ]; then
    if [ -f "$UNIT_DIR/gnosia-learn.service" ] \
       && ! systemctl --user is-active --quiet gnosia-learn \
       && ! systemctl --user is-failed --quiet gnosia-learn; then
      APP_SHOULD_RUN=0
    fi
    # A studio that is cleanly stopped was stopped deliberately, however it
    # got there: a manual `systemctl --user stop` leaves it enabled but
    # inactive, and the panels' Stop is `disable --now`. The flag-off
    # branch below also produces disabled+inactive, so it leaves
    # state/studio-flag-off behind — same marker launchd uses — to keep
    # "off because the flag says so" apart from an owner's stop. Deployd's
    # re-runs must not bring an owner's stop back while the flag stays on.
    if [ -f "$UNIT_DIR/gnosia-learn-studio.service" ] \
       && ! systemctl --user is-active --quiet gnosia-learn-studio \
       && ! systemctl --user is-failed --quiet gnosia-learn-studio \
       && [ ! -f "$SERVICE_HOME/state/studio-flag-off" ]; then
      STUDIO_SHOULD_RUN=0
    fi
  else
    if [ -f "$WEB_PLIST" ] \
       && ! launchctl print "gui/$(id -u)/com.gnosia-learn.web" >/dev/null 2>&1; then
      APP_SHOULD_RUN=0
    fi
    # launchd has no disabled-but-plist-installed state to read, so a flag
    # off run leaves state/studio-flag-off instead: unloaded without the
    # marker means the owner booted the runner out themselves.
    if [ -f "$STUDIO_PLIST" ] \
       && ! launchctl print "gui/$(id -u)/com.gnosia-learn.studio" >/dev/null 2>&1 \
       && [ ! -f "$SERVICE_HOME/state/studio-flag-off" ]; then
      STUDIO_SHOULD_RUN=0
    fi
  fi
fi
# ------------------------------------------------------------ deploy script
# Code, not config: refreshed on every run (edit the repo copy, re-run setup).
info "Installing deploy script -> $SERVICE_HOME/bin/deploy.sh"
sed -e "s|__ENV_FILE__|$ENV_FILE|" \
  "$SERVICE_DIR/deploy.sh" > "$SERVICE_HOME/bin/deploy.sh"
chmod +x "$SERVICE_HOME/bin/deploy.sh"
ok "Deploy script installed"

# ------------------------------------------------------------- unit files
if [ "$OS" = "Linux" ]; then
  info "Writing systemd user units (app, nightly export)"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/gnosia-learn.service" <<EOF
# Generated by services/gnosia-learn/setup.sh — regenerated on every re-run, so edit
# $ENV_FILE and re-run instead of editing here.
[Unit]
Description=gnosia-learn (Gnosia study hub, next start)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$REPO_DIR/apps/web
Environment=NODE_ENV=production
Environment=GNOSIA_HOME=$GNOSIA_HOME
Environment=CATALOG_DB=$CATALOG_DB
Environment=PATH=$NODE_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Any start — launcher, phone, systemctl — clears teardown's torn-down marker:
# a stopped app after an owner start must read as the owner's stop, not the
# removal's, on the next ./setup.sh.
ExecStartPre=-/bin/rm -f $SERVICE_HOME/state/torn-down
ExecStart=$NODE_BIN/npm run start -- -p $LOCAL_PORT -H 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  cat > "$UNIT_DIR/gnosia-learn-export.service" <<EOF
# Generated by services/gnosia-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=gnosia-learn nightly catalog export

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=GNOSIA_HOME=$GNOSIA_HOME
Environment=CATALOG_DB=$CATALOG_DB
Environment=PATH=$NODE_BIN:/usr/local/bin:/usr/bin:/bin
ExecStart=$NODE_BIN/node scripts/nightly-export.mjs
EOF
  chmod 600 "$UNIT_DIR/gnosia-learn-export.service"   # names .env-derived paths
  cat > "$UNIT_DIR/gnosia-learn-export.timer" <<EOF
# Generated by services/gnosia-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=gnosia-learn nightly export at 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat > "$UNIT_DIR/gnosia-learn-studio.service" <<EOF
# Generated by services/gnosia-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=gnosia-learn studio (diagram job runner, loopback API on 127.0.0.1:7250)
After=network-online.target gnosia-learn.service
Wants=network-online.target

[Service]
WorkingDirectory=$REPO_DIR
Environment=PATH=$NODE_BIN:${CLAUDE_PATH}/usr/local/bin:/usr/bin:/bin
Environment=STUDIO_HOME=$SERVICE_HOME/studio
Environment=STUDIO_CLAUDE_BIN=${CLAUDE_BIN:-claude}
Environment=STUDIO_DAILY_USD=${STUDIO_DAILY_USD:-}
ExecStart=$NODE_BIN/npm run studio
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
else
  info "Writing launchd LaunchAgents (app, nightly export)"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$WEB_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/gnosia-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gnosia-learn.web</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>rm -f "\$1"; exec "\$2" run start -- -p "\$3" -H 127.0.0.1</string>
    <string>gnosia-learn-web</string>
    <string>$SERVICE_HOME/state/torn-down</string>
    <string>$NODE_BIN/npm</string>
    <string>$LOCAL_PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR/apps/web</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NODE_ENV</key><string>production</string>
    <key>GNOSIA_HOME</key><string>$GNOSIA_HOME</string>
    <key>CATALOG_DB</key><string>$CATALOG_DB</string>
    <key>PATH</key><string>$NODE_BIN:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gnosia-learn.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gnosia-learn.log</string>
</dict>
</plist>
EOF
  cat > "$STUDIO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/gnosia-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gnosia-learn.studio</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN/npm</string>
    <string>run</string><string>studio</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$NODE_BIN:${CLAUDE_PATH}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>STUDIO_HOME</key><string>$SERVICE_HOME/studio</string>
    <key>STUDIO_CLAUDE_BIN</key><string>${CLAUDE_BIN:-claude}</string>
    <key>STUDIO_DAILY_USD</key><string>${STUDIO_DAILY_USD:-}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gnosia-learn-studio.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gnosia-learn-studio.log</string>
</dict>
</plist>
EOF
  cat > "$HOME/Library/LaunchAgents/com.gnosia-learn.export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/gnosia-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gnosia-learn.export</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN/node</string>
    <string>$REPO_DIR/scripts/nightly-export.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GNOSIA_HOME</key><string>$GNOSIA_HOME</string>
    <key>CATALOG_DB</key><string>$CATALOG_DB</string>
    <key>PATH</key><string>$NODE_BIN:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gnosia-learn-export.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gnosia-learn-export.log</string>
</dict>
</plist>
EOF
  chmod 600 "$HOME/Library/LaunchAgents/com.gnosia-learn.export.plist"  # names .env-derived paths
fi

# ------------------------------------------------- legacy poller removal
# deployd (services/deployd) polls the remote and re-runs this script now;
# a host installed before the migration still has the per-service deploy
# timer or LaunchAgent — under either name (the service was self-learn
# before the rename) — so stop and remove it, but only once deployd itself
# is installed to take over scheduling. teardown.sh deletes the same
# files. The nightly export timer/LaunchAgent is unrelated and stays.
if [ ! -x "$DEPLOYD_HOME/bin/deployd" ]; then
  warn "deployd is not installed — keeping any old deploy poller; auto-deploy is off until services/deployd/setup.sh runs"
elif [ "$OS" = "Linux" ]; then
  removed=0
  for n in self-learn gnosia-learn; do
    if [ -f "$UNIT_DIR/$n-deploy.timer" ]; then
      systemctl --user disable --now "$n-deploy.timer" >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/$n-deploy.timer" "$UNIT_DIR/$n-deploy.service"
      removed=1
    fi
  done
  if [ "$removed" = "1" ]; then
    systemctl --user daemon-reload
    ok "Removed the per-service deploy timer (deployd polls now)"
  fi
else
  for label in com.self-learn.deploy com.gnosia-learn.deploy; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    if [ -f "$HOME/Library/LaunchAgents/$label.plist" ]; then
      rm -f "$HOME/Library/LaunchAgents/$label.plist"
      ok "Removed the $label LaunchAgent (deployd polls now)"
    fi
  done
fi

# ------------------------------------------------------------ initial deploy
info "Deploy (clone + npm ci + catalog migrate + next build — several minutes on first run)"
# deployd passes the remote sha it polled; build exactly that so its record
# of "what is deployed" matches what is built.
if [ -n "${DEPLOY_SHA:-}" ]; then
  "$SERVICE_HOME/bin/deploy.sh" --sha "$DEPLOY_SHA" || die "Initial deploy failed — see output above."
else
  "$SERVICE_HOME/bin/deploy.sh" || die "Initial deploy failed — see output above."
fi
ok "Built: $REPO_DIR"

# ---------------------------------------------------------- catalog bootstrap
# Once, ever: seed + six flips + claim the blob root. SKIP_SEED=1 leaves the
# catalog file empty so the laptop's catalog.db can be dropped in its place
# (SETUP.md, 'Bringing the laptop's data over'). The app reads content per
# request, so flipping after the app is already up needs no restart.
BOOTSTRAP_MARK="$SERVICE_HOME/state/db-bootstrapped"
if [ -f "$BOOTSTRAP_MARK" ]; then
  ok "Catalog already bootstrapped, leaving untouched"
elif [ "$SKIP_SEED" = "1" ]; then
  echo "skipped" > "$BOOTSTRAP_MARK"
  warn "SKIP_SEED=1 — catalog left empty for the laptop's catalog.db."
  warn "  Bringing it over? See SETUP.md, 'Bringing the laptop's data over'."
else
  info "Bootstrapping the catalog: import seed + flips + claim blob root"
  (
    cd "$REPO_DIR"
    export PATH="$NODE_BIN:$PATH"
    MANIMKC_ROOT=/nonexistent REMOTIONKC_ROOT=/nonexistent REVIDEOKC_ROOT=/nonexistent \
      npm run catalog -- import seed
    for t in topics tags concepts sessions courses diagrams; do
      npm run catalog -- flip "$t"
    done
    npm run catalog -- blob audit --fix
  ) || die "Catalog bootstrap failed — see output above."
  echo "seeded" > "$BOOTSTRAP_MARK"
  ok "Catalog seeded, six types flipped to database-owned, blob root claimed"
fi

# ------------------------------------------------------------------ service
if [ "$OS" = "Linux" ]; then
  if [ "$APP_SHOULD_RUN" = "1" ]; then
    info "Enabling and (re)starting gnosia-learn.service"
    systemctl --user enable gnosia-learn >/dev/null 2>&1
    systemctl --user restart gnosia-learn
  else
    warn "gnosia-learn.service is stopped — leaving it stopped (start: systemctl --user start gnosia-learn)"
  fi
  if [ "$STUDIO_ENABLED" = "1" ]; then
    rm -f "$SERVICE_HOME/state/studio-flag-off"
    # The runner follows the app's run state: it lives off the same checkout
    # and node_modules, and an owner who stopped the app meant the stack. A
    # studio-only stop is the owner's too — deployd re-runs leave it down,
    # and must not re-enable either: the panels stop with `disable --now`,
    # so enabling here would resurrect the runner at the next boot. A manual
    # `systemctl --user stop` keeps its enable bit, so skipping enable when
    # stopped leaves a manual stop armed and a panel stop disarmed.
    if [ "$APP_SHOULD_RUN" = "1" ] && [ "$STUDIO_SHOULD_RUN" = "1" ]; then
      systemctl --user enable gnosia-learn-studio >/dev/null 2>&1
      systemctl --user restart gnosia-learn-studio
    else
      warn "gnosia-learn-studio.service is stopped — leaving it stopped (start: systemctl --user start gnosia-learn-studio)"
    fi
  else
    # Flipping STUDIO_ENABLED to 0 must actually stop the runner, not just
    # skip a start — disable --now covers a unit left running by an older
    # install or a manual start. The marker is what tells the next flag-on
    # run this disabled+inactive state was the flag's doing, not an owner's
    # `disable --now` from a panel — launchd writes the same note.
    systemctl --user disable --now gnosia-learn-studio >/dev/null 2>&1 || true
    touch "$SERVICE_HOME/state/studio-flag-off"
  fi
  systemctl --user enable --now gnosia-learn-export.timer >/dev/null 2>&1
  ok "Export timer active"
else
  info "Loading LaunchAgents"
  if [ "$APP_SHOULD_RUN" = "1" ]; then
    launchctl bootout "gui/$(id -u)/com.gnosia-learn.web" 2>/dev/null || true
    # teardown.sh disables each label so login does not reload it; undo that.
    launchctl enable "gui/$(id -u)/com.gnosia-learn.web" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WEB_PLIST"
    if [ "$STUDIO_ENABLED" = "1" ]; then
      launchctl enable "gui/$(id -u)/com.gnosia-learn.studio" 2>/dev/null || true
      if [ "$STUDIO_SHOULD_RUN" = "1" ]; then
        launchctl bootout "gui/$(id -u)/com.gnosia-learn.studio" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$STUDIO_PLIST"
      else
        warn "com.gnosia-learn.studio is unloaded — leaving it stopped (start: launchctl bootstrap gui/$(id -u) $STUDIO_PLIST)"
      fi
    fi
  else
    # Left stopped, but not disabled: the start command below must work.
    launchctl enable "gui/$(id -u)/com.gnosia-learn.web" 2>/dev/null || true
    warn "com.gnosia-learn.web is unloaded — leaving it stopped (start: launchctl bootstrap gui/$(id -u) $WEB_PLIST)"
  fi
  if [ "$STUDIO_ENABLED" = "1" ]; then
    rm -f "$SERVICE_HOME/state/studio-flag-off"
  else
    # Same as the Linux disable --now: a studio left loaded by an older run
    # goes away when the flag is off, regardless of the app's run state. The
    # marker distinguishes "off because the flag says so" from an owner's
    # bootout the next time the flag is on.
    launchctl bootout "gui/$(id -u)/com.gnosia-learn.studio" 2>/dev/null || true
    touch "$SERVICE_HOME/state/studio-flag-off"
  fi
  launchctl bootout "gui/$(id -u)/com.gnosia-learn.export" 2>/dev/null || true
  launchctl enable "gui/$(id -u)/com.gnosia-learn.export" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.gnosia-learn.export.plist"
  ok "LaunchAgents loaded (logs: ~/Library/Logs/gnosia-learn*.log)"
fi
rm -f "$TORN_DOWN"   # the stack is enabled again; a later stop is the owner's

if [ "$APP_SHOULD_RUN" = "1" ]; then
  info "Waiting for the app on 127.0.0.1:$LOCAL_PORT"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null; then
      ok "App is answering locally"
      break
    fi
    if [ "$i" -eq 60 ]; then
      [ "$OS" = "Linux" ] && die "App did not come up. Logs: journalctl --user -u gnosia-learn"
      die "App did not come up. Logs: ~/Library/Logs/gnosia-learn.log"
    fi
    sleep 2
  done

  # The runner is secondary to the app — a missed health check warns rather
  # than fails the install (a job can only be enqueued through the app anyway).
  if [ "$STUDIO_ENABLED" = "1" ]; then
    info "Waiting for the studio runner on 127.0.0.1:7250"
    for i in $(seq 1 15); do
      if curl -fsS -o /dev/null "http://127.0.0.1:7250/api/health" 2>/dev/null; then
        ok "Studio runner is answering locally"
        break
      fi
      if [ "$i" -eq 15 ]; then
        if [ "$OS" = "Linux" ]; then
          warn "Studio runner not answering yet. Logs: journalctl --user -u gnosia-learn-studio"
        else
          warn "Studio runner not answering yet. Logs: ~/Library/Logs/gnosia-learn-studio.log"
        fi
      fi
      sleep 2
    done
  fi
fi

# ------------------------------------------------------------- lingering
# Linux only: makes user units + timers start at boot and survive logout.
if [ "$OS" = "Linux" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time) so the app and timers run at boot"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled"
  fi
fi

# ------------------------------------------------------- tailscale serve
info "Publishing via Tailscale Serve (HTTPS :$HTTPS_PORT, tailnet only)"
ts_serve_publish "$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ final check
if [ "$APP_SHOULD_RUN" = "1" ]; then
  info "Verifying $PUBLIC_URL (first request can take ~60s while the TLS cert is minted)"
  if curl -fsS -o /dev/null --max-time 90 "$PUBLIC_URL/"; then
    ok "End-to-end check passed"
  else
    echo "    Cert may still be minting — try again in a minute: curl $PUBLIC_URL/"
  fi
fi

echo
if [ "$APP_SHOULD_RUN" = "0" ]; then
  printf '\033[1;32mDone.\033[0m gnosia-learn was updated but left stopped (deliberate stop respected). Start it when ready.\n'
else
  printf '\033[1;32mDone.\033[0m gnosia-learn is at \033[1m%s\033[0m (tailnet only).\n' "$PUBLIC_URL"
fi
echo
echo "  Sign in at $PUBLIC_URL/sign-in with OWNER_PASSWORD from $ENV_FILE"
echo "  Auto-deploy: deployd re-runs setup.sh when $REPO_URL ($BRANCH) moves"
echo "    (services/deployd polls every minute; ~/services/deployd/bin/deployd --status)."
echo "  $SERVICE_HOME/bin/deploy.sh --force redeploys now."
echo "  Catalog: one SQLite file at $CATALOG_DB — 'cd $REPO_DIR && npm run catalog -- status'"
echo "  Bringing the laptop's catalog.db over instead of the seed: SETUP.md, 'Bringing the laptop's data over'."
echo
echo "Manage:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart gnosia-learn"
  echo "  journalctl --user -u gnosia-learn -f                       # app logs"
  echo "  systemctl --user list-timers gnosia-learn-export.timer     # nightly export"
  echo "  journalctl --user -u deployd -n 50                       # deploy logs"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/com.gnosia-learn.web  # restart"
  echo "  tail -f ~/Library/Logs/gnosia-learn.log"
fi
echo "  tailscale serve status        # or: tailscale serve --https=$HTTPS_PORT off"
