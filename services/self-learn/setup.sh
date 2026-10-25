#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of self-learn (Gnosia study hub) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - machine-managed clone of github.com/c-wenlong/self-learn at
#     ~/services/self-learn/repo (hard-reset on every deploy — not a
#     working copy; write app config via this service's .env)
#   - Postgres 17 container (docker-compose.yml) on 127.0.0.1:PG_PORT only —
#     published because the catalog CLI runs on the host
#   - production Next.js app (`next build` + `next start`) on
#     127.0.0.1:LOCAL_PORT, under a systemd user unit (Linux) or launchd
#     LaunchAgent (macOS)
#   - catalog bootstrapped once: migrate, `import seed`, six `flip`s,
#     `blob audit --fix` to claim the blob store at SELF_LEARN_HOME
#   - two schedulers: a deploy poller (pull -> ci -> migrate -> build ->
#     restart, every POLL_SECONDS) and a nightly catalog export (03:00)
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#
# Usage:
#   ./setup.sh                              # deploy with defaults
#   LOCAL_PORT=8200 ./setup.sh              # HTTPS follows LOCAL_PORT
#   SKIP_SEED=1 ./setup.sh                  # no seed import/flips — restore a
#                                           # pg_dump from the laptop instead
#   OWNER_PASSWORD=x AUTH_SECRET=y ./setup.sh   # set on first run only
#                                           # (use the laptop's AUTH_SECRET so
#                                           # provider keys stay readable)
#
# Requirements beyond the repo baseline (curl, Docker, Tailscale): git with
# non-interactive access to the private repo (gh auth setup-git, or a deploy
# key), Node.js >= 22.22.2 (engines field in upstream's package.json).
#
# Idempotent: safe to re-run. Re-running pulls new commits through the poller
# script, repairs any missing piece, and never overwrites the .env. The
# seeded marker in ~/services/self-learn/state means the catalog bootstrap
# runs once, ever.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8107}"
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
PG_PORT="${PG_PORT:-5432}"
REPO_URL="${REPO_URL:-https://github.com/c-wenlong/self-learn.git}"
BRANCH="${BRANCH:-main}"
POLL_SECONDS="${POLL_SECONDS:-86400}"   # daily; deploy.sh --force deploys now
SKIP_SEED="${SKIP_SEED:-0}"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# Hex is URL-safe and survives .env + postgres URLs without quoting.
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
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v git >/dev/null || die "git is required."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

command -v node >/dev/null || die "Node.js >= 22.22.2 is required (upstream engines field). Install node, then re-run."
node_at_least "22.22.2" \
  || die "Node.js >= 22.22.2 is required (found: $(node --version)). Upgrade node and re-run."

if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi
if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi
state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

# The poller must fetch the (private) repo unattended — verify that works now.
if ! GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REPO_URL" >/dev/null 2>&1; then
  die "Cannot read $REPO_URL non-interactively. Fix auth first: gh auth login && gh auth setup-git (or use an SSH deploy key and set REPO_URL accordingly)."
fi

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac
case "$PG_PORT" in ''|*[!0-9]*) die "PG_PORT must be numeric (got: $PG_PORT)";; esac
ok "$OS + curl + git (repo reachable) + node $(node --version) + Docker + Compose v2 + Tailscale (running)"

host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (ports, paths, generated secrets — mode 600)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  elif [ -f /etc/timezone ]; then
    tz="$(cat /etc/timezone)"
  fi
  db_pass="$(randhex 16)"
  owner_pass="${OWNER_PASSWORD:-$(randhex 12)}"
  auth_secret="${AUTH_SECRET:-$(randhex 32)}"
  ( umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600. Edit + re-run to apply.
REPO_URL=$REPO_URL
BRANCH=$BRANCH

LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT
PG_PORT=$PG_PORT
POLL_SECONDS=$POLL_SECONDS

SERVICE_HOME=$HOME/services/self-learn
# Upstream's own layout (docs/HOMESERVER.md): blobs/, vault/ and archive/
# live under SELF_LEARN_HOME, outside ~/services — it is the rsync target
# when the laptop's blob store is copied over.
SELF_LEARN_HOME=$HOME/.self-learn
NODE_BIN=$(dirname "$(command -v node)")
PUBLIC_URL=https://$host:$HTTPS_PORT

# Upstream feature flags (apps/web/.env.local). STUDIO_ENABLED=1 turns on the
# diagram-studio UI and runs the studio job-runner service, which spawns the
# claude CLI per job — flip to 1 only on a machine with the CLI installed and
# its credentials logged in.
STUDIO_ENABLED=${STUDIO_ENABLED:-0}
ASSET_FILES_ENABLED=${ASSET_FILES_ENABLED:-1}

POSTGRES_VERSION=17-alpine
POSTGRES_USER=catalog
POSTGRES_PASSWORD=$db_pass
POSTGRES_DB=self_learn
POSTGRES_MEM_LIMIT=512m
TZ=$tz
DATABASE_URL=postgres://catalog:$db_pass@127.0.0.1:$PG_PORT/self_learn

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
SELF_LEARN_HOME="${SELF_LEARN_HOME:?SELF_LEARN_HOME missing from $ENV_FILE}"
DATABASE_URL="${DATABASE_URL:?DATABASE_URL missing from $ENV_FILE}"
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
WEB_PLIST="$HOME/Library/LaunchAgents/com.self-learn.web.plist"
STUDIO_PLIST="$HOME/Library/LaunchAgents/com.self-learn.studio.plist"
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

mkdir -p "$SERVICE_HOME/bin" "$SERVICE_HOME/state" "$SELF_LEARN_HOME/blobs"

# ------------------------------------------- existing deployment state
# Captured before anything is touched: a previously deployed app that is
# stopped stays stopped across a re-run — the launcher's stop must survive
# setup the same way it survives the poller. state/built-sha proves an
# earlier run finished a first deploy; without it the install was
# interrupted and the start below repairs rather than overrides. A *failed*
# unit is restarted too (that's the repair), so only clean-inactive counts.
# state/torn-down is teardown.sh's note that the stop was a removal, not the
# owner's stop: setup after a teardown brings the stack back up. Any start of
# the app — launcher, phone or service manager — consumes it (the unit and the
# LaunchAgent delete it before the app comes up), so a later stop reads as the
# owner's again.
APP_SHOULD_RUN=1
TORN_DOWN="$SERVICE_HOME/state/torn-down"
if [ -f "$SERVICE_HOME/state/built-sha" ] && [ ! -f "$TORN_DOWN" ]; then
  if [ "$OS" = "Linux" ]; then
    if [ -f "$UNIT_DIR/self-learn.service" ] \
       && ! systemctl --user is-active --quiet self-learn \
       && ! systemctl --user is-failed --quiet self-learn; then
      APP_SHOULD_RUN=0
    fi
  else
    if [ -f "$WEB_PLIST" ] \
       && ! launchctl print "gui/$(id -u)/com.self-learn.web" >/dev/null 2>&1; then
      APP_SHOULD_RUN=0
    fi
  fi
fi
# Same for Postgres: remember whether it was running so the end of setup can
# leave a deliberately stopped stack fully stopped.
DB_WAS_UP=0
if docker compose --project-directory "$SERVICE_DIR" ps --status running -q db 2>/dev/null | grep -q .; then
  DB_WAS_UP=1
fi

# ------------------------------------------------------------ deploy script
# Code, not config: refreshed on every run (edit the repo copy, re-run setup).
info "Installing deploy script -> $SERVICE_HOME/bin/deploy.sh"
sed -e "s|__ENV_FILE__|$ENV_FILE|" -e "s|__COMPOSE_DIR__|$SERVICE_DIR|" \
  "$SERVICE_DIR/deploy.sh" > "$SERVICE_HOME/bin/deploy.sh"
chmod +x "$SERVICE_HOME/bin/deploy.sh"
ok "Deploy script installed"

# ------------------------------------------------------------- unit files
if [ "$OS" = "Linux" ]; then
  info "Writing systemd user units (app, deploy poller, nightly export)"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/self-learn.service" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run, so edit
# $ENV_FILE and re-run instead of editing here.
[Unit]
Description=self-learn (Gnosia study hub, next start)
After=network-online.target docker.service
Wants=network-online.target

[Service]
WorkingDirectory=$REPO_DIR/apps/web
Environment=NODE_ENV=production
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
  cat > "$UNIT_DIR/self-learn-deploy.service" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=self-learn deploy (pull from GitHub, rebuild + migrate if changed)

[Service]
Type=oneshot
ExecStart=$SERVICE_HOME/bin/deploy.sh
EOF
  cat > "$UNIT_DIR/self-learn-deploy.timer" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=self-learn deploy poller (push-to-deploy for a tailnet-only box)

[Timer]
OnBootSec=90
OnUnitActiveSec=${POLL_SECONDS}
AccuracySec=15

[Install]
WantedBy=timers.target
EOF
  cat > "$UNIT_DIR/self-learn-export.service" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=self-learn nightly catalog export

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=SELF_LEARN_HOME=$SELF_LEARN_HOME
Environment=DATABASE_URL=$DATABASE_URL
Environment=PATH=$NODE_BIN:/usr/local/bin:/usr/bin:/bin
ExecStart=$NODE_BIN/node scripts/nightly-export.mjs
EOF
  chmod 600 "$UNIT_DIR/self-learn-export.service"   # embeds DATABASE_URL
  cat > "$UNIT_DIR/self-learn-export.timer" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=self-learn nightly export at 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat > "$UNIT_DIR/self-learn-studio.service" <<EOF
# Generated by services/self-learn/setup.sh — regenerated on every re-run.
[Unit]
Description=self-learn studio (diagram job runner, loopback API on 127.0.0.1:7250)
After=network-online.target docker.service self-learn.service
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
  info "Writing launchd LaunchAgents (app, deploy poller, nightly export)"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$WEB_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/self-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.self-learn.web</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>rm -f "\$1"; exec "\$2" run start -- -p "\$3" -H 127.0.0.1</string>
    <string>self-learn-web</string>
    <string>$SERVICE_HOME/state/torn-down</string>
    <string>$NODE_BIN/npm</string>
    <string>$LOCAL_PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR/apps/web</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NODE_ENV</key><string>production</string>
    <key>PATH</key><string>$NODE_BIN:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/self-learn.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/self-learn.log</string>
</dict>
</plist>
EOF
  cat > "$STUDIO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/self-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.self-learn.studio</string>
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
  <key>StandardOutPath</key><string>$HOME/Library/Logs/self-learn-studio.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/self-learn-studio.log</string>
</dict>
</plist>
EOF
  cat > "$HOME/Library/LaunchAgents/com.self-learn.deploy.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/self-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.self-learn.deploy</string>
  <key>ProgramArguments</key>
  <array><string>$SERVICE_HOME/bin/deploy.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$NODE_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>$POLL_SECONDS</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/self-learn-deploy.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/self-learn-deploy.log</string>
</dict>
</plist>
EOF
  cat > "$HOME/Library/LaunchAgents/com.self-learn.export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by services/self-learn/setup.sh — regenerated on every re-run. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.self-learn.export</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN/node</string>
    <string>$REPO_DIR/scripts/nightly-export.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SELF_LEARN_HOME</key><string>$SELF_LEARN_HOME</string>
    <key>DATABASE_URL</key><string>$DATABASE_URL</string>
    <key>PATH</key><string>$NODE_BIN:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/self-learn-export.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/self-learn-export.log</string>
</dict>
</plist>
EOF
  chmod 600 "$HOME/Library/LaunchAgents/com.self-learn.export.plist"  # embeds DATABASE_URL
fi

# ------------------------------------------------------------ initial deploy
info "Deploy (clone + npm ci + catalog migrate + next build — several minutes on first run)"
"$SERVICE_HOME/bin/deploy.sh" || die "Initial deploy failed — see output above."
ok "Built: $REPO_DIR"

# deploy.sh only runs `compose up` when it has work to do; on an up-to-date
# re-run this is the line that repairs a stopped Postgres.
info "Ensuring Postgres is up (docker compose up -d)"
docker compose --project-directory "$SERVICE_DIR" up -d

# ---------------------------------------------------------- catalog bootstrap
# Once, ever: seed + six flips + claim the blob root. SKIP_SEED=1 leaves the
# database empty for a pg_restore of the laptop's dump (docs/HOMESERVER.md
# steps 3-6 upstream). The app reads content per request, so flipping after
# the app is already up needs no restart.
BOOTSTRAP_MARK="$SERVICE_HOME/state/db-bootstrapped"
if [ -f "$BOOTSTRAP_MARK" ]; then
  ok "Catalog already bootstrapped, leaving untouched"
elif [ "$SKIP_SEED" = "1" ]; then
  echo "skipped" > "$BOOTSTRAP_MARK"
  warn "SKIP_SEED=1 — catalog left empty for pg_restore of the laptop's dump."
  warn "  Restoring later? See SETUP.md, 'Bringing the laptop's data over'."
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
    info "Enabling and (re)starting self-learn.service"
    systemctl --user enable self-learn >/dev/null 2>&1
    systemctl --user restart self-learn
  else
    warn "self-learn.service is stopped — leaving it stopped (start: systemctl --user start self-learn)"
  fi
  if [ "$STUDIO_ENABLED" = "1" ]; then
    # The runner follows the app's run state: it lives off the same checkout
    # and node_modules, and an owner who stopped the app meant the stack.
    systemctl --user enable self-learn-studio >/dev/null 2>&1
    if [ "$APP_SHOULD_RUN" = "1" ]; then
      systemctl --user restart self-learn-studio
    else
      warn "self-learn-studio.service is stopped — leaving it stopped (start: systemctl --user start self-learn-studio)"
    fi
  else
    # Flipping STUDIO_ENABLED to 0 must actually stop the runner, not just
    # skip a start — disable --now covers a unit left running by an older
    # install or a manual start.
    systemctl --user disable --now self-learn-studio >/dev/null 2>&1 || true
  fi
  systemctl --user enable --now self-learn-deploy.timer >/dev/null 2>&1
  systemctl --user enable --now self-learn-export.timer >/dev/null 2>&1
  ok "Deploy/export timers active"
else
  info "Loading LaunchAgents"
  if [ "$APP_SHOULD_RUN" = "1" ]; then
    launchctl bootout "gui/$(id -u)/com.self-learn.web" 2>/dev/null || true
    # teardown.sh disables each label so login does not reload it; undo that.
    launchctl enable "gui/$(id -u)/com.self-learn.web" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WEB_PLIST"
    if [ "$STUDIO_ENABLED" = "1" ]; then
      launchctl bootout "gui/$(id -u)/com.self-learn.studio" 2>/dev/null || true
      launchctl enable "gui/$(id -u)/com.self-learn.studio" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$STUDIO_PLIST"
    fi
  else
    # Left stopped, but not disabled: the start command below must work.
    launchctl enable "gui/$(id -u)/com.self-learn.web" 2>/dev/null || true
    warn "com.self-learn.web is unloaded — leaving it stopped (start: launchctl bootstrap gui/$(id -u) $WEB_PLIST)"
  fi
  if [ "$STUDIO_ENABLED" != "1" ]; then
    # Same as the Linux disable --now: a studio left loaded by an older run
    # goes away when the flag is off, regardless of the app's run state.
    launchctl bootout "gui/$(id -u)/com.self-learn.studio" 2>/dev/null || true
  fi
  for agent in com.self-learn.deploy com.self-learn.export; do
    launchctl bootout "gui/$(id -u)/$agent" 2>/dev/null || true
    launchctl enable "gui/$(id -u)/$agent" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$agent.plist"
  done
  ok "LaunchAgents loaded (logs: ~/Library/Logs/self-learn*.log)"
fi
rm -f "$TORN_DOWN"   # the stack is enabled again; a later stop is the owner's

# The `compose up -d` above was needed by the deploy and any bootstrap — if
# Postgres was stopped along with the app, put it back the way it was found.
if [ "$APP_SHOULD_RUN" = "0" ] && [ "$DB_WAS_UP" = "0" ]; then
  docker compose --project-directory "$SERVICE_DIR" stop >/dev/null 2>&1 || true
  ok "Postgres left stopped, matching how it was found"
fi

if [ "$APP_SHOULD_RUN" = "1" ]; then
  info "Waiting for the app on 127.0.0.1:$LOCAL_PORT"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null; then
      ok "App is answering locally"
      break
    fi
    if [ "$i" -eq 60 ]; then
      [ "$OS" = "Linux" ] && die "App did not come up. Logs: journalctl --user -u self-learn"
      die "App did not come up. Logs: ~/Library/Logs/self-learn.log"
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
          warn "Studio runner not answering yet. Logs: journalctl --user -u self-learn-studio"
        else
          warn "Studio runner not answering yet. Logs: ~/Library/Logs/self-learn-studio.log"
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
if ! "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null 2>&1; then
  if [ "$OS" = "Linux" ]; then
    info "Direct serve failed — trying operator grant (needs sudo, one time)"
    sudo tailscale set --operator="$USER"
  fi
  until "$TAILSCALE" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT"; do
    echo
    info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

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
  printf '\033[1;32mDone.\033[0m self-learn was updated but left stopped (deliberate stop respected). Start it when ready.\n'
else
  printf '\033[1;32mDone.\033[0m self-learn is at \033[1m%s\033[0m (tailnet only).\n' "$PUBLIC_URL"
fi
echo
echo "  Sign in at $PUBLIC_URL/sign-in with OWNER_PASSWORD from $ENV_FILE"
echo "  Auto-deploy: pushes to $BRANCH are picked up every ${POLL_SECONDS}s; $SERVICE_HOME/bin/deploy.sh --force does it now."
echo "  Database: 'docker compose --project-directory $SERVICE_DIR exec db psql -U $POSTGRES_USER $POSTGRES_DB' (password in .env)"
echo "  Restoring the laptop's dump instead of the seed: SETUP.md, 'Bringing the laptop's data over'."
echo
echo "Manage:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart self-learn"
  echo "  journalctl --user -u self-learn -f                       # app logs"
  echo "  systemctl --user list-timers self-learn-*                # poller + export"
  echo "  journalctl --user -u self-learn-deploy -n 50             # deploy logs"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/com.self-learn.web  # restart"
  echo "  tail -f ~/Library/Logs/self-learn.log"
fi
echo "  docker compose --project-directory $SERVICE_DIR ps|logs  # Postgres"
echo "  tailscale serve status        # or: tailscale serve --https=$HTTPS_PORT off"
