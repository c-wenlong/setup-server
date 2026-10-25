#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Vaultwarden (self-hosted, Bitwarden-compatible
# password vault) behind Tailscale. Linux + macOS.
#
# End state:
#   - a single `vaultwarden` container (SQLite inside /data — no sidecar)
#   - published on 127.0.0.1:LOCAL_PORT only
#   - reachable tailnet-only at https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - the /admin panel disabled (no ADMIN_TOKEN is set — see below)
#   - registration open ONLY until the owner's account exists, then closed
#     automatically by the next run of this script
#
# Usage:
#   ./setup.sh                            # local 8222, HTTPS 8222
#   LOCAL_PORT=8223 ./setup.sh            # HTTPS follows LOCAL_PORT (8223 -> 8223)
#   LOCAL_PORT=8223 HTTPS_PORT=8222 ./setup.sh
#
# Version: pinned to 1.37.2 (web-vault 2026.7.0). Not `latest`. A vault that
# migrates its schema unattended is a vault you may not be able to roll back.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT CANNOT CREATE YOUR ACCOUNT
#
# Bitwarden clients derive the vault encryption key from the master password
# *in the browser*; the server only ever sees a hash of a hash. That is the
# entire security property of the product. A script that created the account
# would have to send the master password to the server, which would defeat it.
# So registration happens in the browser, once, by you.
#
# The consequence is a window where the instance accepts sign-ups. This script
# closes that window for you:
#
#   run 1  -> SIGNUPS_ALLOWED=true, and it tells you to go register NOW
#   you    -> open the URL, create your account
#   run 2  -> sees 1 user in db.sqlite3, flips SIGNUPS_ALLOWED=false in .env,
#             recreates the container, reports the door as shut
#
# Every run prints the live state, so you are never left guessing whether
# your vault is open to anyone else on the tailnet.
#
# THE ADMIN PANEL IS OFF. With no ADMIN_TOKEN, /admin serves a static
# "please configure the 'ADMIN_TOKEN' variable" notice and both /admin/users
# and POST /admin return 404 — verified against this image. Nothing in this
# deploy needs it. docker-compose.yml documents the interactive recipe for
# turning it on later; it cannot be automated because `vaultwarden hash`
# panics without a TTY.
#
# There is no generated password anywhere in this deploy. The only credential
# that matters is your master password, and nothing on this box knows it.
# ---------------------------------------------------------------------------
#
# Requirements: Linux or macOS, curl, python3, Docker + Compose v2, Tailscale.
#
# Idempotent: safe to re-run; it upgrades the image and repairs the publish.
# An existing .env is never overwritten — with exactly one exception, the
# SIGNUPS_ALLOWED line, which is this script's job to close.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8222}"
# The HTTPS port follows the local port unless set explicitly (the n8n and
# kaichenpedia convention), so overriding only LOCAL_PORT cannot split the
# two. Whether it was explicit is remembered for the .env read-back below.
HTTPS_PORT_EXPLICIT="${HTTPS_PORT:+yes}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"
CONTAINER="vaultwarden"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/vaultwarden"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# 700, and it may briefly hold a copy of the vault database (see
# count_users_via_docker_cp). Removed on every exit path.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
# Not optional here: counting the accounts in db.sqlite3 is how this script
# knows whether it is safe to close registration. Without python3 it would
# have to leave the door open and hope.
python3 -c 'import sqlite3' >/dev/null 2>&1 || die "python3 with a working sqlite3 module is required (it reads the account count out of the vault's SQLite DB, which is how registration gets closed). On Ubuntu: sudo apt-get install -y python3"
if ! command -v docker >/dev/null; then
  [ "$OS" = "Linux" ] && die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
  die "Docker is not installed. On macOS install Docker Desktop or OrbStack."
fi

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

if ! docker ps >/dev/null 2>&1; then
  [ "$OS" = "Linux" ] && die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out/in (or run via: sg docker -c ./setup.sh)"
  die "Cannot talk to the Docker daemon. Is Docker Desktop/OrbStack running?"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT must be numeric (got: $LOCAL_PORT)";; esac
case "$HTTPS_PORT" in ''|*[!0-9]*) die "HTTPS_PORT must be numeric (got: $HTTPS_PORT)";; esac

ok "$OS + curl + python3 + Docker (daemon reachable) + Compose v2 + Tailscale (running)"

# The tailnet name is needed *before* the container starts, not after: it goes
# into DOMAIN, and Vaultwarden derives the WebAuthn/passkey relying-party ID,
# the U2F app-id, attachment URLs and every emailed link from it. A wrong
# DOMAIN does not error — 2FA registration simply fails later in the browser,
# blaming the security key. So resolve it up front and verify it at the end.
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (no secrets to generate — see the note inside)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Docker Compose reads this file from the project directory for interpolation.
#
# There is deliberately NO admin password / admin token / secret key in here.
# Vaultwarden has no server-side account to log into: your master password is
# derived into the vault key by the *client*, and the server never sees it.
# Inventing a secret here would only be a secret nobody needs.

# Pinned exactly. Ships web-vault 2026.7.0. Back up VAULTWARDEN_DATA before
# changing this line — a schema migration is not reversible.
VAULTWARDEN_VERSION=1.37.2

LOCAL_PORT=$LOCAL_PORT
TZ=$tz

# THE VAULT. db.sqlite3 (accounts + encrypted ciphers), rsa_key.pem (signs
# login tokens), attachments/ and sends/. This directory IS your passwords.
# Written by a container running as root, so it is root-owned on the host.
VAULTWARDEN_DATA=$STATE/data

# Public identity — the full tailnet HTTPS URL, scheme and port included,
# exactly as the browser sees it. WebAuthn/passkey 2FA binds to it. If this
# machine is renamed or the HTTPS port moves, edit this line and re-run
# setup.sh (it warns when the value drifts from the live tailnet name), then
# re-register any security keys.
VAULTWARDEN_DOMAIN=https://$TS_HOST:$HTTPS_PORT

# Registration. setup.sh manages this line and only this line:
#   true  -> anyone who can reach the tailnet URL can create an account
#   false -> the door is shut
# It starts open so you can register (nothing else can create your account),
# and the next run of setup.sh flips it to false as soon as it sees an
# account in the database. Re-open it by hand only to add another person,
# and re-run setup.sh afterwards to close it again.
VAULTWARDEN_SIGNUPS_ALLOWED=true

# Organisation invitations bypass SIGNUPS_ALLOWED — an invited address can
# create an account even when signups are closed. Off: this is a single-owner
# vault, and this is the only other way in.
VAULTWARDEN_INVITATIONS_ALLOWED=false
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth for ports and paths, so a
# re-run can never silently move a live deployment.
REQUESTED_PORT="$LOCAL_PORT"
set -a; . "$ENV_FILE"; set +a
DATA_DIR="${VAULTWARDEN_DATA:?VAULTWARDEN_DATA missing from $ENV_FILE}"
DOMAIN="${VAULTWARDEN_DOMAIN:?VAULTWARDEN_DOMAIN missing from $ENV_FILE}"
SIGNUPS="${VAULTWARDEN_SIGNUPS_ALLOWED:-false}"
if [ "$LOCAL_PORT" != "$REQUESTED_PORT" ]; then
  warn "LOCAL_PORT=$REQUESTED_PORT ignored — the existing $ENV_FILE says $LOCAL_PORT. Edit .env and re-run to move the port."
fi
# .env holds no HTTPS_PORT of its own (only the derived VAULTWARDEN_DOMAIN), so
# a default HTTPS port keeps following the local port .env settled on; an
# explicit HTTPS_PORT is honoured as given.
[ -n "$HTTPS_PORT_EXPLICIT" ] || HTTPS_PORT="$LOCAL_PORT"

# Drift check, not a rewrite: .env is the user's file. But a DOMAIN that no
# longer matches this machine silently breaks WebAuthn/passkey 2FA — the
# browser refuses a credential registered against a different origin — so say
# so loudly.
WANT_DOMAIN="https://$TS_HOST:$HTTPS_PORT"
if [ "$DOMAIN" != "$WANT_DOMAIN" ]; then
  warn "VAULTWARDEN_DOMAIN in .env is $DOMAIN but this box now answers to $WANT_DOMAIN."
  warn "  2FA/passkey registration and attachment links will be wrong until it matches. Fix: set VAULTWARDEN_DOMAIN=$WANT_DOMAIN in $ENV_FILE, re-run setup.sh, and re-register any security keys."
fi

mkdir -p "$STATE" "$DATA_DIR"

# The vault itself is small (a few MB), but attachments and Sends land here
# too, and a full disk corrupts SQLite writes.
avail_kb="$(df -Pk "$DATA_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 1048576 ]; then
  warn "$(( avail_kb / 1024 )) MB free at $DATA_DIR — a vault is small, but a disk that fills mid-write is how SQLite databases get corrupted. Free some space."
else
  ok "$(( avail_kb / 1048576 )) GB free at $DATA_DIR"
fi

DB_FILE="$DATA_DIR/db.sqlite3"

# ------------------------------------------------------------- HTTP helpers
VW_CODE=""
vw() {  # vw URL -> body in $WORK/resp, code in $VW_CODE
  # curl prints 000 on stdout when it cannot connect AND exits non-zero. A
  # `|| echo 000` fallback would CONCATENATE, producing the nonsense code
  # "000000" in error messages. Take curl's own output; normalise the rest.
  VW_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time "${VW_TIMEOUT:-15}" "$1" 2>/dev/null)" || true
  case "$VW_CODE" in [0-9][0-9][0-9]) ;; *) VW_CODE=000 ;; esac
}

# Poll GET /alive (200, body is an ISO timestamp) until the server answers.
#
# 000 — a refused connection — is treated as "not ready yet", not as failure.
# Jellyfin's deploy in this repo died on exactly that: the container was up,
# the readiness probe passed, and the very next request came back 000 because
# the server had not finished binding. Retrying a 000 costs nothing when the
# service is genuinely down (this still fails, just later) and removes the
# race when it is merely a second behind.
wait_alive() {  # wait_alive BASE_URL ATTEMPTS
  local base="$1" attempts="$2" i
  for i in $(seq 1 "$attempts"); do
    vw "$base/alive"
    [ "$VW_CODE" = "200" ] && return 0
    sleep 2
  done
  return 1
}

# ---------------------------------------------------- account counting
# Reads the account count straight out of the vault's SQLite DB, read-only.
# The `users` table exists from first boot (verified: 0 rows on a fresh
# instance), so "0" is a real answer, not a missing-table error.
#
# There is no API for this: every endpoint that could report it needs an
# authenticated session, and the whole point is that this script has no
# credentials — nor should it.
count_users_ro() {  # count_users_ro PATH -> prints an integer, or fails
  python3 - "$1" <<'PY' 2>/dev/null
import os, sys, sqlite3, urllib.request
path = sys.argv[1]
# No database file yet = no accounts yet. That is an answer, not an error:
# it is the state between `compose up` and the container's first write.
if not os.path.exists(path):
    print(0)
    sys.exit(0)
try:
    uri = "file:" + urllib.request.pathname2url(path) + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=5)
    print(con.execute("select count(*) from users").fetchone()[0])
    con.close()
except Exception:
    sys.exit(1)
PY
}

# Fallback for when the host cannot read db.sqlite3 directly — the container
# runs as root, so a restrictive umask on the daemon can leave the file
# unreadable to this user. `docker cp` goes through the daemon, which can.
#
# The copy is a real vault database (ciphers are still encrypted with a key
# this box does not have, but password hashes are in there): it lands in the
# 700 temp dir and is deleted by the EXIT trap. The -wal is copied too, or a
# registration made seconds ago could be missing from the snapshot — and a
# false "0 users" here is the one wrong answer that matters, because it would
# leave signups open.
count_users_via_docker_cp() {
  # umask 077 around the copy, not just a chmod after it: `docker cp` creates
  # the host-side file with the calling process's umask, so a chmod alone
  # would leave a real vault database briefly world-readable. The 700 temp
  # dir already covers this; belt and braces, because of what the file is.
  ( umask 077
    docker cp "$CONTAINER:/data/db.sqlite3" "$WORK/db.sqlite3" >/dev/null 2>&1 || exit 1
    docker cp "$CONTAINER:/data/db.sqlite3-wal" "$WORK/db.sqlite3-wal" >/dev/null 2>&1 || true
    docker cp "$CONTAINER:/data/db.sqlite3-shm" "$WORK/db.sqlite3-shm" >/dev/null 2>&1 || true
  ) || return 1
  chmod 600 "$WORK"/db.sqlite3* 2>/dev/null || true
  # Opened read-write on purpose: it is a throwaway copy, and only a writable
  # connection can replay the -wal it was copied with.
  python3 - "$WORK/db.sqlite3" <<'PY' 2>/dev/null
import sys, sqlite3
try:
    con = sqlite3.connect(sys.argv[1], timeout=5)
    print(con.execute("select count(*) from users").fetchone()[0])
    con.close()
except Exception:
    sys.exit(1)
PY
}

user_count() {  # prints an integer, or nothing if it could not be determined
  # Nothing is guessed here. A missing DB file counts as 0 (handled inside
  # count_users_ro); "unknown" is reserved for a database that exists and
  # cannot be read, and the caller refuses to touch registration in that case.
  local n
  n="$(count_users_ro "$DB_FILE" || true)"
  case "$n" in ''|*[!0-9]*) n="$(count_users_via_docker_cp || true)" ;; esac
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$n"
}

# The RUNNING container's environment — the authority on what the server is
# actually doing, as opposed to what .env says it should be doing. Read once
# per deploy state; empty means docker could not tell us (older daemon, odd
# stub, container gone), which the callers below treat as "unconfirmed"
# rather than "wrong".
CONTAINER_ENV=""
read_container_env() {
  CONTAINER_ENV="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
}
container_env() {  # container_env NAME -> prints the value, or nothing
  printf '%s\n' "$CONTAINER_ENV" | sed -n "s/^$1=//p" | head -1
}

# ---------------------------------------------------------------- deploy
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Starting Vaultwarden (docker compose up -d) — first run pulls ~60 MB"
"${COMPOSE[@]}" up -d

info "Waiting for Vaultwarden on 127.0.0.1:$LOCAL_PORT (first boot creates the SQLite schema)"
wait_alive "http://127.0.0.1:$LOCAL_PORT" 60 \
  || die "Vaultwarden did not answer /alive (last HTTP $VW_CODE). Logs: docker compose --project-directory $SERVICE_DIR logs vaultwarden"
ok "Vaultwarden is answering locally (GET /alive)"

# --------------------------------------------- registration lifecycle
# The self-closing door:
#   0 accounts -> leave signups open and tell the owner to register NOW
#   1+ accounts and signups still open -> close them, recreate, confirm
#   1+ accounts and signups already closed -> nothing to do
#
# The live container env is the authority for "are signups open", not .env:
# .env could have been edited without a re-run.
read_container_env
LIVE_SIGNUPS="$(container_env SIGNUPS_ALLOWED)"
[ -n "$LIVE_SIGNUPS" ] || LIVE_SIGNUPS="$SIGNUPS"

USERS="$(user_count)"

COUNT_UNKNOWN=0
if [ -z "$USERS" ]; then
  # Deliberately not a default. Guessing 0 would leave registration open;
  # guessing 1 would slam the door before the owner has an account. The run
  # continues (so the publish is still repaired and the state is still
  # reported), but it ends non-zero and says exactly what is unverified.
  COUNT_UNKNOWN=1
  warn "Could not read the account count from $DB_FILE (tried a read-only open and a docker cp of the live DB)."
  warn "  Registration is being left exactly as it is (SIGNUPS_ALLOWED=$LIVE_SIGNUPS) rather than guessed at."
  warn "  Once your account exists, close the door by hand:"
  warn "    set VAULTWARDEN_SIGNUPS_ALLOWED=false in $ENV_FILE && ./setup.sh"
elif [ "$USERS" -eq 0 ]; then
  ok "0 accounts in the vault — this is the expected first-run state"
elif [ "$LIVE_SIGNUPS" = "true" ]; then
  info "$USERS account(s) exist and registration is still open — closing it"
  # The one line in .env this script is allowed to rewrite. Truncate in place
  # (`cat >`) rather than mv, so the file keeps its inode and 600 mode.
  if grep -q '^VAULTWARDEN_SIGNUPS_ALLOWED=' "$ENV_FILE"; then
    sed 's/^VAULTWARDEN_SIGNUPS_ALLOWED=.*/VAULTWARDEN_SIGNUPS_ALLOWED=false/' "$ENV_FILE" > "$WORK/env.new"
  else
    # Hand-edited away: re-add it rather than silently relying on the
    # compose default.
    #
    # DEFENSIVE, AND NOT REACHED BY THE NORMAL FLOW — do not read it as
    # exercised code. `up -d` runs before this count, and with the key
    # missing Compose already started the container on the `:-false`
    # default, so LIVE_SIGNUPS reads false and control lands in the
    # "already closed" branch below instead. This exists for the case
    # where that is somehow not true; the outcome either way is a shut
    # door, and this branch also puts the decision back in writing.
    cat "$ENV_FILE" > "$WORK/env.new"
    printf '\nVAULTWARDEN_SIGNUPS_ALLOWED=false\n' >> "$WORK/env.new"
  fi
  grep -q '^VAULTWARDEN_SIGNUPS_ALLOWED=false$' "$WORK/env.new" \
    || die "Refusing to write $ENV_FILE: the edited copy does not contain VAULTWARDEN_SIGNUPS_ALLOWED=false. Set it by hand and re-run."
  cat "$WORK/env.new" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Set VAULTWARDEN_SIGNUPS_ALLOWED=false in $ENV_FILE"

  # --force-recreate rather than a plain `up -d`: changing an interpolated
  # value does make compose recreate the container, but this is the one step
  # that must not be a no-op, so do not rely on the config-hash comparison.
  info "Recreating the container so the change takes effect"
  "${COMPOSE[@]}" up -d --force-recreate
  wait_alive "http://127.0.0.1:$LOCAL_PORT" 60 \
    || die "Vaultwarden did not come back after closing registration (last HTTP $VW_CODE). Logs: docker compose --project-directory $SERVICE_DIR logs vaultwarden"

  read_container_env
  LIVE_SIGNUPS="$(container_env SIGNUPS_ALLOWED)"
  if [ -n "$CONTAINER_ENV" ]; then
    [ "$LIVE_SIGNUPS" = "false" ] \
      || die "Closed registration in .env, but the running container still reports SIGNUPS_ALLOWED=${LIVE_SIGNUPS:-unset}. Do not leave it like this: docker compose --project-directory $SERVICE_DIR up -d --force-recreate, then check: docker inspect $CONTAINER | grep SIGNUPS_ALLOWED"
    ok "Signups are now CLOSED — confirmed on the running container ($USERS account(s) exist)"
  else
    LIVE_SIGNUPS="false"
    warn "Signups are now CLOSED in $ENV_FILE and the container was recreated, but docker inspect returned nothing so this could not be confirmed against the running container. Check: docker inspect $CONTAINER | grep SIGNUPS_ALLOWED"
  fi
else
  ok "$USERS account(s) exist and registration is already closed"
fi

# The other door into a closed instance, and the panel that could open one.
# Skipped, not guessed at, when docker inspect told us nothing.
if [ -n "$CONTAINER_ENV" ]; then
  [ "$(container_env INVITATIONS_ALLOWED)" = "false" ] \
    || warn "INVITATIONS_ALLOWED is not false on the running container — an org invite can create an account even when signups are closed. Set VAULTWARDEN_INVITATIONS_ALLOWED=false in $ENV_FILE and re-run."
  if [ -n "$(container_env ADMIN_TOKEN)" ]; then
    warn "ADMIN_TOKEN is set on the running container, so /admin is reachable. That panel can delete users and read instance settings — remove it from the compose environment unless you are actively using it."
  else
    ok "No ADMIN_TOKEN — the /admin panel is disabled"
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
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
VW_TIMEOUT=90 vw "$url/alive"
if [ "$VW_CODE" = "200" ]; then
  ok "End-to-end HTTPS check passed (GET /alive)"
else
  # Same 000 lesson as above: the cert mint is slow, not broken.
  if wait_alive "$url" 15; then
    ok "End-to-end HTTPS check passed (GET /alive)"
  else
    warn "No answer on $url/alive yet (HTTP $VW_CODE) — the cert may still be minting. Retry in a minute: curl $url/alive"
  fi
fi

# DOMAIN, verified from the outside. /api/config is unauthenticated and echoes
# the configured domain back in its `environment` block, so this proves the
# value the *server* will hand to WebAuthn — not just what .env says.
VW_TIMEOUT=60 vw "$url/api/config"
cfg="$(tr -d ' \n\r' < "$WORK/resp" 2>/dev/null || true)"
case "$cfg" in
  *"\"vault\":\"$WANT_DOMAIN\""*)
    ok "DOMAIN confirmed over HTTPS: the server reports $WANT_DOMAIN"
    ;;
  *'"vault":"'*)
    live_vault="$(printf '%s' "$cfg" | sed -n 's/.*"vault":"\([^"]*\)".*/\1/p')"
    warn "Vaultwarden reports its domain as $live_vault, not $WANT_DOMAIN. WebAuthn/passkey 2FA registered against one origin will not work on the other. Fix VAULTWARDEN_DOMAIN in $ENV_FILE and re-run."
    ;;
  *)
    # /api/config did not expose it (or did not answer) — fall back to the
    # container's own environment, which is what Vaultwarden was started with.
    live_domain="$(container_env DOMAIN)"
    if [ "$live_domain" = "$WANT_DOMAIN" ]; then
      ok "DOMAIN confirmed on the running container: $live_domain"
    else
      warn "Could not confirm DOMAIN (HTTP $VW_CODE from /api/config; container env says ${live_domain:-unset}, expected $WANT_DOMAIN). Check: docker inspect $CONTAINER | grep DOMAIN"
    fi
    ;;
esac

# Re-read rather than trust the earlier value: the state printed at the end
# must be the state of the container that is running right now.
read_container_env
live_now="$(container_env SIGNUPS_ALLOWED)"
[ -n "$live_now" ] && LIVE_SIGNUPS="$live_now"

echo
printf '\033[1;32mDone.\033[0m Vaultwarden is at \033[1m%s\033[0m (tailnet only).\n' "$url"
echo
if [ "$LIVE_SIGNUPS" = "true" ]; then
  printf '\033[1;33m┌─────────────────────────────────────────────────────────────────┐\033[0m\n'
  printf '\033[1;33m│  Signups are OPEN — anyone on this tailnet can create an account │\033[0m\n'
  printf '\033[1;33m└─────────────────────────────────────────────────────────────────┘\033[0m\n'
  echo
  echo "  Go create your account NOW, before anything else:"
  echo "    1. open $url"
  echo "    2. Create account — use a LONG, unique master password."
  echo "       It is never sent to this server: it derives your vault key in"
  echo "       the browser. Nobody, including this box, can reset it. If you"
  echo "       forget it, the vault is gone. Write it down somewhere physical."
  echo "    3. re-run ./setup.sh — it will see the account and shut the door."
  echo
  echo "  Until you do step 3, this instance accepts new accounts from anyone"
  echo "  who can reach the tailnet."
else
  printf '\033[1;32m  Signups are CLOSED\033[0m — no new accounts can be created.\n'
  echo "  Org invitations are off too, so that path is shut as well."
  echo "  To add another person: set VAULTWARDEN_SIGNUPS_ALLOWED=true in"
  echo "    $ENV_FILE, ./setup.sh, have them register, then ./setup.sh again"
  echo "    to close it. The second run is the important one."
fi
echo
echo "Clients (each device must be on the tailnet). Point them at the SERVER"
echo "  URL — this is not bitwarden.com, and the apps default to it:"
echo "  Browser:   just open $url"
echo "  Extension/mobile/desktop: on the login screen tap the settings gear /"
echo "    'Self-hosted', set Server URL = $url, then log in."
echo "  The apps keep a local encrypted copy, so a vault you have already"
echo "  unlocked on a device keeps working even when this box is off."
echo
# Three states, never a flat claim. /admin can enumerate and delete every
# account on the same URL as the vault, behind one password — this is the
# last line an operator scrolls to, so it must not assert "disabled" when a
# token is live, nor when nothing confirmed it either way.
if [ -n "$CONTAINER_ENV" ] && [ -n "$(container_env ADMIN_TOKEN)" ]; then
  printf '\033[1;33m ! \033[0m %s\n' "The /admin panel is ENABLED — ADMIN_TOKEN is set on the running container."
  echo "  It can enumerate and delete every account, on the same URL as your"
  echo "  vault, behind that one token. Unless you are actively using it,"
  echo "  remove the ADMIN_TOKEN key from the environment block in"
  echo "  $SERVICE_DIR/docker-compose.yml and re-run ./setup.sh."
elif [ -n "$CONTAINER_ENV" ]; then
  echo "The /admin panel is disabled (no ADMIN_TOKEN on the running container)."
  echo "  You do not need it for normal use. To turn it on later, see the recipe"
  echo "  in docker-compose.yml (it needs an interactive TTY — 'vaultwarden"
  echo "  hash' panics without one). Turn it back off when you are done."
else
  echo "No ADMIN_TOKEN was found in this deploy's configuration, so /admin should"
  echo "  be disabled — but docker inspect returned nothing this run, so that was"
  echo "  NOT confirmed against the running container. Confirm it yourself:"
  echo "    docker inspect $CONTAINER | grep ADMIN_TOKEN     # expect no match"
fi
echo
printf '\033[1;31m'
echo "BACKUPS — read this one. Nothing backs this box up."
printf '\033[0m'
echo "  Every password you own now lives in one directory on one disk:"
echo "    $DATA_DIR"
echo "  db.sqlite3 (accounts + encrypted ciphers), rsa_key.pem (without it,"
echo "  every session token is invalid), attachments/, sends/. If that disk"
echo "  dies and you have no copy, the passwords are gone. Not recoverable."
echo "  Not resettable. Gone."
echo
echo "  Keep two kinds of backup. Do BOTH — they fail in different ways:"
echo
echo "  1) Cold copy of the server state (restores this exact instance)."
echo "     The container runs as root, so the files are root-owned — sudo:"
echo "       docker compose --project-directory $SERVICE_DIR stop &&"
echo "       sudo tar czf ~/vaultwarden-\$(date +%F).tgz -C $DATA_DIR . &&"
echo "       sudo chown \$USER ~/vaultwarden-\$(date +%F).tgz &&"
echo "       docker compose --project-directory $SERVICE_DIR start"
echo "     That tarball is the whole vault. Treat it like the vault: keep it"
echo "     off this box, encrypted, somewhere you can still reach if this"
echo "     machine is a brick."
echo
echo "  2) Client-side encrypted export (works even if this box never boots"
echo "     again, and can be imported into bitwarden.com or a fresh install):"
echo "       any Bitwarden client -> Settings -> Vault -> Export vault"
echo "       -> File format: .json (Encrypted)"
echo "       -> choose 'Password protected', NOT 'Account restricted'."
echo "     Account-restricted exports can only ever be imported back into the"
echo "     same account on the same instance — useless if that is what died."
echo "     A password-protected export restores anywhere with its password."
echo "     Note: exports do NOT include file attachments; download those"
echo "     separately if you use them."
echo
echo "Manage:  docker compose --project-directory $SERVICE_DIR ps|logs|restart|down"
echo "Upgrade: back up first, then bump VAULTWARDEN_VERSION in $ENV_FILE and"
echo "         docker compose --project-directory $SERVICE_DIR pull && ./setup.sh"

if [ "$COUNT_UNKNOWN" = "1" ]; then
  echo
  printf '\033[1;31m ✗ \033[0m %s\n' "Exiting non-zero: the deploy is up, but this run could NOT read $DB_FILE, so it could not verify how many accounts exist or decide whether to close registration. The signup state above is whatever it already was. Sort that out before trusting this vault: sudo ls -l $DATA_DIR"
  exit 1
fi
exit 0
