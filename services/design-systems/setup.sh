#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of the design-systems browsing site (the docs
# site + gallery of the private c-wenlong/designs repo) behind Tailscale.
# Linux + macOS.
#
# End state:
#   - site built from the working clone at SOURCE_REPO (default
#     ~/dev/design-systems) — the deploy only reads it and pulls it
#     ff-only, it never commits or resets there
#   - built site served by an nginx container binding 127.0.0.1:LOCAL_PORT,
#     which also answers the repo paths (/systems/, /tools/, /example/,
#     /catalog.json, /README.md) straight from a read-only mount of the
#     checkout — the same allowlist the repo's `make serve` answers, so the
#     ~300 MB of LFS screenshots are never copied into a release
#   - auto-deploy: deployd (services/deployd) polls the repo's remote and
#     re-runs this script when main moves; new commits go live on its next
#     tick, or immediately via bin/deploy.sh --force.
#   - published tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#
# Usage:
#   ./setup.sh                                # first run and re-runs
#   LOCAL_PORT=9000 HTTPS_PORT=9000 ./setup.sh
#   SOURCE_REPO=~/elsewhere/design-systems ./setup.sh
#
# Unlike services/sources/ this site serves readable files — there is no
# SITE_PASSPHRASE. The tailnet is the access boundary (the repo is private;
# its AGENTS.md forbids publishing the gallery or systems/ publicly, which
# is exactly what a tailnet-only publish is not).
#
# Requirements beyond the repo baseline (curl, Docker, Tailscale): git,
# python3 (the gallery/scorecard generators are stdlib-only; Pillow is used
# for thumbnails when present) and uv (for the site builder's venv).
#
# Idempotent: re-running refreshes the deploy script and repairs any
# missing piece (and removes the old per-service deploy timer if a host
# still has one); an existing .env and nginx.conf are never overwritten.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8108}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
[ -n "${SOURCE_REPO:-}" ] && SOURCE_REPO_SET=1
SOURCE_REPO="${SOURCE_REPO:-$HOME/dev/design-systems}"
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
rm -f "$HOME/services/deployd/state/design-systems.disabled"

# A re-run (e.g. under deployd, whose PATH is minimal) finds tools where
# the first install recorded them in .env — put those dirs on PATH first.
if [ -f "$ENV_FILE" ]; then
  for v in UV_BIN GIT_LFS_BIN; do
    d="$(sed -n "s/^$v=\(.*\)\$/\1/p" "$ENV_FILE" | sed "s/^'//; s/'\$//")"
    [ -n "$d" ] && [ -d "$d" ] && PATH="$PATH:$d"
  done
fi

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v git >/dev/null || die "git is required."
command -v python3 >/dev/null || die "python3 is required (tools/catalog.py + tools/scorecard.py)."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

command -v uv >/dev/null || die "uv is required (installs the site builder's deps into .venv). Install: https://docs.astral.sh/uv/"

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

# The build runs inside the working clone; it must exist and look like
# design-systems. A saved .env wins over the default path on re-runs: only
# an explicit SOURCE_REPO=... overrides it.
if [ -f "$ENV_FILE" ] && [ -z "${SOURCE_REPO_SET+x}" ]; then
  saved_repo="$(sed -n 's/^SOURCE_REPO=\(.*\)$/\1/p' "$ENV_FILE")"
  [ -n "$saved_repo" ] && SOURCE_REPO="$saved_repo"
fi
[ -d "$SOURCE_REPO/.git" ] || die "design-systems repo not found at $SOURCE_REPO (set SOURCE_REPO=... or clone it first)."
[ -f "$SOURCE_REPO/tools/catalog.py" ] || die "$SOURCE_REPO does not look like the design-systems repo (no tools/catalog.py)."

# Every image in the library is a Git LFS object; an unfetched object sits
# in the checkout as a ~130-byte ASCII pointer ("version https://git-lfs").
# Pointers crash the gallery's thumbnail step, so materialise them here.
# Small-file scan first: real screenshots are never under 400 bytes, so the
# content check hardly ever reads a file.
lfs_pointer() {  # echoes the first pointer file found, or nothing
  while IFS= read -r f; do
    if head -c 30 "$f" | grep -q '^version https://git-lfs'; then
      printf '%s\n' "$f"
      break
    fi
  done < <(find "$SOURCE_REPO/systems" -type f \( -name '*.png' -o -name '*.jp*g' -o -name '*.webp' -o -name '*.gif' -o -name '*.mp4' -o -name '*.mov' -o -name '*.zip' -o -name '*.gz' -o -name '*.fig' -o -name '*.woff' -o -name '*.woff2' -o -name '*.ttf' -o -name '*.otf' \) -size -400c -print 2>/dev/null)
  return 0   # callers rely on empty output; a clean miss must not trip pipefail
}
pointer="$(lfs_pointer)"
if [ -n "$pointer" ]; then
  if git -C "$SOURCE_REPO" lfs version >/dev/null 2>&1; then
    info "Git LFS pointers in the checkout — running git lfs pull"
    git -C "$SOURCE_REPO" lfs pull || warn "git lfs pull failed"
    pointer="$(lfs_pointer)"
  fi
  [ -z "$pointer" ] || die "Git LFS pointer files remain in the checkout (e.g. $pointer) — install git-lfs and run 'git -C $SOURCE_REPO lfs pull', then re-run."
fi

case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
ok "$OS + curl + git + python3 + uv + Docker + Compose v2 + Tailscale (running) + repo at $SOURCE_REPO"

host="$("$TAILSCALE" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$host" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (paths + ports; mode 0600)"
  # deploy.sh sources this file as shell, so every value is written
  # %q-escaped — a path containing spaces or metacharacters must not
  # corrupt the file (values that need no escaping write bare).
  SERVICE_HOME="$HOME/services/design-systems"
  UV_BIN="$(dirname "$(command -v uv)")"
  # git-lfs resolves on PATH for git lfs pull; under systemd/launchd the
  # PATH is minimal, so bake the directory it lives in now (like UV_BIN).
  GIT_LFS_BIN="$(dirname "$(command -v git-lfs 2>/dev/null || echo /usr/bin/git-lfs)")"
  {
    printf '# Generated by setup.sh. Gitignored. Edit + re-run setup.sh to apply.\n'
    printf 'SOURCE_REPO=%q\n' "$SOURCE_REPO"
    printf 'BRANCH=%q\n' "$BRANCH"
    printf 'LOCAL_PORT=%q\n' "$LOCAL_PORT"
    printf 'HTTPS_PORT=%q\n' "$HTTPS_PORT"
    printf 'SERVICE_HOME=%q\n' "$SERVICE_HOME"
    printf 'UV_BIN=%q\n' "$UV_BIN"
    printf 'GIT_LFS_BIN=%q\n' "$GIT_LFS_BIN"
    printf 'PUBLIC_URL=%q\n' "https://$host:$HTTPS_PORT/"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Everything below reads the .env (source of truth on re-runs). It is
# sourced as shell — the same format deploy.sh reads — so %q-escaped
# values come back unescaped.
set -a; . "$ENV_FILE"; set +a

mkdir -p "$SERVICE_HOME/bin" "$SERVICE_HOME/state" "$SERVICE_HOME/www" "$SERVICE_HOME/media/refero"

# ---------------------------------------------------------------- nginx.conf
NGINX_CONF="$SERVICE_HOME/nginx.conf"
if [ -f "$NGINX_CONF" ]; then
  ok "nginx.conf already exists, leaving untouched: $NGINX_CONF"
  if ! grep -q "refero-media" "$NGINX_CONF"; then
    warn "nginx.conf predates the refero media mount. Add beside the other location blocks:
      location /refero-media/ { alias /srv/media/refero/; }
  then restart the container: docker compose --project-directory $SERVICE_DIR restart"
  fi
  if ! grep -q "gzip on" "$NGINX_CONF" || ! grep -q "Cache-Control" "$NGINX_CONF"; then
    warn "nginx.conf predates the gzip/Cache-Control config — it serves ~2 MB
  uncompressed per page load and nothing carries a caching policy. Diff it
  against the template in $SERVICE_DIR/setup.sh, then restart the container:
  docker compose --project-directory $SERVICE_DIR restart"
  fi
else
  info "Writing nginx.conf (docs site + the repo paths the gallery links to)"
  cat > "$NGINX_CONF" <<'EOF'
server {
    listen 80;
    server_name _;

    # mime.types maps no .md type, and the gallery's Files section links raw
    # package READMEs — serve them as text so they display, not download.
    include /etc/nginx/mime.types;
    types { text/markdown md; }

    # The payload is mostly text — data.json alone is ~1.5 MB (~120 KB
    # gzipped). Images and video are already compressed formats, so they stay
    # out of gzip_types; text/html compresses implicitly.
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types text/css application/javascript text/javascript application/json image/svg+xml text/markdown;

    root /usr/share/nginx/html/current;
    index index.html;

    # Build internals live under the same mount as `current` — not part of
    # the site, so hide them rather than serve partial or duplicate trees.
    location ~ ^/(releases|next)(/|$) { return 404; }

    # Gallery thumbnails are named after the source path
    # (systems__<slug>__screenshots__<name>.jpg), not a content hash — a
    # recaptured screenshot reuses the name. A day bounds how stale a cached
    # thumb can go while keeping repeat gallery visits off the wire.
    location /gallery/thumbs/ {
        add_header Cache-Control "public, max-age=86400";
    }

    # Repository paths, answered straight from the checkout — the same
    # allowlist the repo's `make serve` answers (tools/catalog.py
    # REPO_PATHS). The gallery's full-size screenshots and package files
    # live here; they are never part of the built site (LFS, ~300 MB), so
    # the checkout is bind-mounted read-only instead of copied per release.
    # They are name-stable but can be recaptured or edited in place, so
    # revalidate every load — an unchanged file answers a cheap 304.
    location /systems/ { alias /srv/repo/systems/; autoindex on; add_header Cache-Control "no-cache"; }
    location /tools/   { alias /srv/repo/tools/;   autoindex on; add_header Cache-Control "no-cache"; }
    location /example/ { alias /srv/repo/example/; autoindex on; add_header Cache-Control "no-cache"; }
    location = /catalog.json { alias /srv/repo/catalog.json; add_header Cache-Control "no-cache"; }
    location = /README.md    { alias /srv/repo/README.md; add_header Cache-Control "no-cache"; }

    # Mirrored refero media (~/services/design-systems/media/refero/, filled
    # by tools/refero/mirror_media.py): screenshots, scroll videos, favicons.
    # The mirror writes each slug-keyed file once and skips it after that,
    # so a month of caching is safe.
    location /refero-media/ {
        alias /srv/media/refero/;
        add_header Cache-Control "public, max-age=2592000";
    }

    # Everything else: HTML pages, the unhashed app.js/style.css and the
    # gallery JSON the app fetches with cache:'no-cache'. Revalidate every
    # load so a deploy shows at once; unchanged files answer 304 via ETag.
    location / {
        try_files $uri $uri/ =404;
        add_header Cache-Control "no-cache";
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
info "Initial deploy (gallery + docs site build — a minute or two on first run)"
"$SERVICE_HOME/bin/deploy.sh" || die "Initial deploy failed — see output above."
ok "Site built: $SERVICE_HOME/www/current"

# ---------------------------------------------------------------- container
info "Starting nginx container (docker compose up -d)"
docker compose --project-directory "$SERVICE_DIR" up -d

info "Waiting for nginx on 127.0.0.1:$LOCAL_PORT"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$LOCAL_PORT/gallery/" 2>/dev/null; then
    ok "Site is answering locally"
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
PLIST_LABEL="com.design-systems.deploy"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
if [ ! -x "$HOME/services/deployd/bin/deployd" ]; then
  warn "deployd is not installed — keeping any old poller; auto-deploy is off until services/deployd/setup.sh runs"
elif [ "$OS" = "Linux" ]; then
  if [ -f "$UNIT_DIR/design-systems-deploy.timer" ]; then
    systemctl --user disable --now design-systems-deploy.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/design-systems-deploy.timer" "$UNIT_DIR/design-systems-deploy.service"
    systemctl --user daemon-reload
    ok "Removed design-systems-deploy.timer (deployd polls now)"
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
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$HTTPS_PORT -> http://127.0.0.1:$LOCAL_PORT"

# ------------------------------------------------------------ final check
url="https://$host:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
if curl -fsS -o /dev/null --max-time 90 "$url/gallery/"; then
  ok "End-to-end check passed"
else
  echo "    Cert may still be minting — try again in a minute: curl $url/gallery/"
fi

echo
printf '\033[1;32mDone.\033[0m The design-systems gallery is at \033[1m%s/gallery/\033[0m (tailnet only).\n' "$url"
echo
echo "Auto-deploy: deployd re-runs this when $SOURCE_REPO ($BRANCH) moves"
echo "(services/deployd polls every minute; ~/services/deployd/bin/deployd --status)."
echo "Manage:"
echo "  $SERVICE_HOME/bin/deploy.sh --force        # rebuild now"
echo "  journalctl --user -u deployd -n 50         # poll + deploy logs (Linux)"
echo "  tail -f ~/Library/Logs/deployd.log         # macOS"
echo "  docker compose --project-directory $SERVICE_DIR ps|logs|restart"
