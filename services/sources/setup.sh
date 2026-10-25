#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of the sources browsing site (the encrypted
# static build of the private c-wenlong/sources archive) behind Tailscale.
# Linux + macOS.
#
# End state:
#   - site built from the existing fetch clone at SOURCE_REPO (default
#     ~/dev/sources) — the same clone the fetch timers own; the deploy only
#     reads it and pulls it forward, it never commits there
#   - encrypted build served by an nginx container binding 127.0.0.1:LOCAL_PORT
#   - auto-deploy: a poller (systemd user timer / launchd) runs
#     bin/deploy.sh every POLL_SECONDS (default daily); new commits on the
#     fetch clone's main go live on the next poll, or immediately via
#     deploy.sh --force. (GitHub webhooks can't reach a tailnet-only box —
#     polling is the outbound-only equivalent. The weekly fetch also commits
#     locally, which the poller picks up the same way.)
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#
# Usage:
#   SITE_PASSPHRASE='the site passphrase' ./setup.sh     # first run
#   ./setup.sh                                          # re-run: .env is kept
#   LOCAL_PORT=9000 HTTPS_PORT=9000 ./setup.sh
#   SOURCE_REPO=~/elsewhere/sources ./setup.sh
#
# SITE_PASSPHRASE is required on first run and is the same passphrase the
# repo's GitHub "site" workflow uses (repo secret of the same name). With it
# the same key unlocks both the Pages site and this one. It lands in the
# gitignored .env (0600); later runs read it from there.
#
# Requirements beyond the repo baseline (curl, Docker, Tailscale): git and
# uv (the build is `uv run apps/web/build/build_site.py`).
#
# Idempotent: re-running refreshes the deploy script + poller and repairs any
# missing piece; an existing .env and nginx.conf are never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8098}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
[ -n "${SOURCE_REPO:-}" ] && SOURCE_REPO_SET=1
SOURCE_REPO="${SOURCE_REPO:-$HOME/dev/sources}"
BRANCH="${BRANCH:-main}"
POLL_SECONDS="${POLL_SECONDS:-86400}"   # daily; deploy.sh --force deploys now
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v git >/dev/null || die "git is required."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

command -v uv >/dev/null || die "uv is required (the site builds with 'uv run apps/web/build/build_site.py'). Install: https://docs.astral.sh/uv/"

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

# The build runs inside the fetch clone; it must exist and look like sources.
# A saved .env wins over the default path on re-runs: only an explicit
# SOURCE_REPO=... overrides it.
if [ -f "$ENV_FILE" ] && [ -z "${SOURCE_REPO_SET+x}" ]; then
  saved_repo="$(sed -n 's/^SOURCE_REPO=\(.*\)$/\1/p' "$ENV_FILE")"
  [ -n "$saved_repo" ] && SOURCE_REPO="$saved_repo"
fi
[ -d "$SOURCE_REPO/.git" ] || die "Sources repo not found at $SOURCE_REPO (set SOURCE_REPO=... or clone it first)."
[ -f "$SOURCE_REPO/apps/web/build/build_site.py" ] || [ -f "$SOURCE_REPO/scripts/build_site.py" ] \
  || die "$SOURCE_REPO does not look like the sources repo (no apps/web/build/build_site.py or scripts/build_site.py)."

# First run needs the passphrase up front (it is written into .env below);
# on re-runs the existing .env supplies it.
if [ ! -f "$ENV_FILE" ] && [ -z "${SITE_PASSPHRASE:-}" ]; then
  die "SITE_PASSPHRASE is required on first run: SITE_PASSPHRASE='...' ./setup.sh (same value as the sources repo's GitHub secret)."
fi

case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
ok "$OS + curl + git + uv + Docker + Compose v2 + Tailscale (running) + repo at $SOURCE_REPO"

host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (paths + ports + SITE_PASSPHRASE; mode 0600)"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored. Edit + re-run setup.sh to apply.
SOURCE_REPO=$SOURCE_REPO
BRANCH=$BRANCH
LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT
POLL_SECONDS=$POLL_SECONDS
SERVICE_HOME=$HOME/services/sources
UV_BIN=$(dirname "$(command -v uv)")
PUBLIC_URL=https://$host:$HTTPS_PORT/
EOF
  # deploy.sh sources this file as shell code, so the passphrase must be
  # written shell-quoted (%q): spaces or metachars in it would otherwise
  # break or change the saved value.
  printf 'SITE_PASSPHRASE=%q\n' "$SITE_PASSPHRASE" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Everything below reads the .env (source of truth on re-runs).
SOURCE_REPO="$(sed -n 's/^SOURCE_REPO=\(.*\)$/\1/p' "$ENV_FILE")"
BRANCH="$(sed -n 's/^BRANCH=\(.*\)$/\1/p' "$ENV_FILE")"
LOCAL_PORT="$(sed -n 's/^LOCAL_PORT=\(.*\)$/\1/p' "$ENV_FILE")"
HTTPS_PORT="$(sed -n 's/^HTTPS_PORT=\(.*\)$/\1/p' "$ENV_FILE")"
POLL_SECONDS="$(sed -n 's/^POLL_SECONDS=\(.*\)$/\1/p' "$ENV_FILE")"
SERVICE_HOME="$(sed -n 's/^SERVICE_HOME=\(.*\)$/\1/p' "$ENV_FILE")"

mkdir -p "$SERVICE_HOME/bin" "$SERVICE_HOME/state" "$SERVICE_HOME/www"

# ---------------------------------------------------------------- nginx.conf
NGINX_CONF="$SERVICE_HOME/nginx.conf"
if [ -f "$NGINX_CONF" ]; then
  ok "nginx.conf already exists, leaving untouched: $NGINX_CONF"
else
  info "Writing nginx.conf (all routing is client-side hash routes — plain static serving)"
  cat > "$NGINX_CONF" <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html/current;
    index index.html;

    # Build internals live under the same mount as `current` — not part of
    # the site, so hide them rather than serve partial or duplicate trees.
    location ~ ^/(releases|next)(/|$) { return 404; }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
  ok "Wrote $NGINX_CONF"
fi

# ------------------------------------------------------------ deploy script
# Code, not config: refreshed on every run (edit the repo copy, re-run setup).
info "Installing deploy script -> $SERVICE_HOME/bin/deploy.sh"
sed "s|__ENV_FILE__|$ENV_FILE|" "$SERVICE_DIR/deploy.sh" > "$SERVICE_HOME/bin/deploy.sh"
chmod +x "$SERVICE_HOME/bin/deploy.sh"
ok "Deploy script installed"

# ------------------------------------------------------------ initial build
info "Initial deploy (build_site.py encrypts the whole corpus — a few minutes on first run)"
"$SERVICE_HOME/bin/deploy.sh" || die "Initial deploy failed — see output above."
ok "Site built: $SERVICE_HOME/www/current"

# ---------------------------------------------------------------- container
info "Starting nginx container (docker compose up -d)"
docker compose --project-directory "$SERVICE_DIR" up -d

info "Waiting for nginx on 127.0.0.1:$LOCAL_PORT"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null; then
    ok "Site is answering locally"
    break
  fi
  [ "$i" -eq 15 ] && die "nginx did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs"
  sleep 1
done

# ------------------------------------------------------------------ poller
if [ "$OS" = "Linux" ]; then
  info "Installing systemd user timer (poll every ${POLL_SECONDS}s)"
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/sources-deploy.service" <<EOF
[Unit]
Description=sources site deploy (rebuild the encrypted site if the repo moved)

[Service]
Type=oneshot
ExecStart=$SERVICE_HOME/bin/deploy.sh
EOF
  cat > "$UNIT_DIR/sources-deploy.timer" <<EOF
[Unit]
Description=sources site deploy poller (push-to-deploy for a tailnet-only box)

[Timer]
OnBootSec=90
OnUnitActiveSec=${POLL_SECONDS}
AccuracySec=15

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now sources-deploy.timer >/dev/null 2>&1
  ok "Timer active: sources-deploy.timer"

  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time) so the poller runs at boot"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled"
  fi
else
  PLIST="$HOME/Library/LaunchAgents/com.sources.deploy.plist"
  info "Installing launchd poller (every ${POLL_SECONDS}s)"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.sources.deploy</string>
  <key>ProgramArguments</key>
  <array><string>$SERVICE_HOME/bin/deploy.sh</string></array>
  <key>StartInterval</key><integer>$POLL_SECONDS</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/sources-deploy.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/sources-deploy.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.sources.deploy" 2>/dev/null || true
  # teardown.sh disables the label so login does not reload it; undo that.
  launchctl enable "gui/$(id -u)/com.sources.deploy" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (logs: ~/Library/Logs/sources-deploy.log)"
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
url="https://$host:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/"; then
  ok "End-to-end check passed"
else
  echo "    Cert may still be minting — try again in a minute: curl $url/"
fi

echo
printf '\033[1;32mDone.\033[0m The sources site is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo "Unlock it with the same passphrase as the GitHub Pages site."
echo
echo "Auto-deploy: commits on $SOURCE_REPO ($BRANCH) are picked up by the poller"
echo "(every ${POLL_SECONDS}s) — including the weekly fetch commit."
echo "Manage:"
echo "  $SERVICE_HOME/bin/deploy.sh --force        # rebuild now"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user list-timers sources-deploy.timer"
  echo "  journalctl --user -u sources-deploy -n 50   # deploy logs"
else
  echo "  tail -f ~/Library/Logs/sources-deploy.log"
fi
echo "  docker compose --project-directory $SERVICE_DIR ps|logs|restart"
