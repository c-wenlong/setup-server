#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of kaichenpedia (personal wiki, Quartz static
# site) behind Tailscale. Linux + macOS.
#
# End state:
#   - deploy clone of github.com/c-wenlong/kaichenpedia in ~/services/kaichenpedia/repo
#     (machine-managed, hard-reset on every deploy — not a working copy)
#   - static site built with Quartz, served by an nginx container binding
#     127.0.0.1:LOCAL_PORT only
#   - auto-deploy: deployd (services/deployd) polls the repo's remote and
#     re-runs this script when BRANCH moves; new commits go live on its
#     next tick, or immediately via deploy.sh --force.
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#
# Usage:
#   ./setup.sh
#   LOCAL_PORT=9000 HTTPS_PORT=9000 ./setup.sh
#   REPO_URL=https://github.com/me/other-wiki.git ./setup.sh
#
# Requirements beyond the repo baseline (curl, Docker, Tailscale): git with
# non-interactive access to the private repo (gh auth setup-git, or a deploy
# key), Node.js >= 22, python3.
#
# Idempotent: re-running refreshes the deploy script and repairs any
# missing piece (and removes the old per-service deploy timer if a host
# still has one); an existing .env and nginx.conf are never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8091}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
REPO_URL="${REPO_URL:-https://github.com/c-wenlong/kaichenpedia.git}"
BRANCH="${BRANCH:-main}"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# A manual ./setup.sh re-installs the service: clear deployd's disabled
# flag (written by teardown.sh) so auto-deploy resumes. deployd itself
# never invokes this while the flag is set, so clearing is always manual.
rm -f "$HOME/services/deployd/state/kaichenpedia.disabled"

# A re-run (e.g. under deployd, whose PATH is minimal) finds node where
# the first install recorded it in .env — put that dir on PATH first.
if [ -f "$ENV_FILE" ]; then
  d="$(sed -n "s/^NODE_BIN=\(.*\)\$/\1/p" "$ENV_FILE" | sed "s/^'//; s/'\$//")"
  [ -n "$d" ] && [ -d "$d" ] && PATH="$PATH:$d"
fi

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v git >/dev/null || die "git is required."
command -v python3 >/dev/null || die "python3 is required (runs the repo's wiki -> site sync)."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

command -v node >/dev/null || die "Node.js >= 22 is required (Quartz build). Install node, then re-run."
node_major="$(node --version | sed -n 's/^v\([0-9]*\).*/\1/p')"
[ -n "$node_major" ] && [ "$node_major" -ge 22 ] \
  || die "Node.js >= 22 is required for Quartz (found: $(node --version))."

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

case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac
ok "$OS + curl + git (repo reachable) + node $node_major + python3 + Docker + Compose v2 + Tailscale (running)"

host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (paths + ports; no secrets — repo auth comes from git's credential helper)"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored. Edit + re-run setup.sh to apply.
REPO_URL=$REPO_URL
BRANCH=$BRANCH
LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT
SERVICE_HOME=$HOME/services/kaichenpedia
NODE_BIN=$(dirname "$(command -v node)")
PUBLIC_URL=https://$host:$HTTPS_PORT/
EOF
  ok "Wrote $ENV_FILE"
fi

# Everything below reads the .env (source of truth on re-runs).
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
  info "Writing nginx.conf (Quartz links are extensionless — try_files adds .html)"
  cat > "$NGINX_CONF" <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html/current;
    index index.html;
    error_page 404 /404.html;

    location / {
        try_files $uri $uri/ $uri.html =404;
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
info "Initial deploy (clone + npm ci + quartz build — a few minutes on first run)"
"$SERVICE_HOME/bin/deploy.sh" || die "Initial deploy failed — see output above."
ok "Site built: $SERVICE_HOME/www/current"

# ---------------------------------------------------------------- container
info "Starting nginx container (docker compose up -d)"
docker compose --project-directory "$SERVICE_DIR" up -d

info "Waiting for nginx on 127.0.0.1:$LOCAL_PORT"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null; then
    ok "Wiki is answering locally"
    break
  fi
  [ "$i" -eq 15 ] && die "nginx did not come up. Logs: docker compose --project-directory $SERVICE_DIR logs"
  sleep 1
done

# ------------------------------------------------- legacy poller removal
# deployd (services/deployd) polls the remote and re-runs this script now;
# a host installed before the migration still has the per-service timer or
# LaunchAgent — stop and remove it, but only once deployd itself is
# installed to take over scheduling. teardown.sh deletes the same files.
UNIT_DIR="$HOME/.config/systemd/user"
PLIST_LABEL="com.kaichenpedia.deploy"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
if [ ! -x "$HOME/services/deployd/bin/deployd" ]; then
  warn "deployd is not installed — keeping any old poller; auto-deploy is off until services/deployd/setup.sh runs"
elif [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/kaichenpedia-deploy.timer" ]; then
    systemctl --user disable --now kaichenpedia-deploy.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/kaichenpedia-deploy.timer" "$UNIT_DIR/kaichenpedia-deploy.service"
    systemctl --user daemon-reload
    ok "Removed kaichenpedia-deploy.timer (deployd polls now)"
  fi
else
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    ok "Removed the $PLIST_LABEL LaunchAgent (deployd polls now)"
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
    read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
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
printf '\033[1;32mDone.\033[0m Kaichenpedia is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
echo "Auto-deploy: deployd re-runs this when $REPO_URL ($BRANCH) moves"
echo "(services/deployd polls every minute; ~/services/deployd/bin/deployd --status)."
echo "Manage:"
echo "  $SERVICE_HOME/bin/deploy.sh --force        # rebuild now"
echo "  journalctl --user -u deployd -n 50         # poll + deploy logs (Linux)"
echo "  tail -f ~/Library/Logs/deployd.log         # macOS"
echo "  docker compose --project-directory $SERVICE_DIR ps|logs|restart"
