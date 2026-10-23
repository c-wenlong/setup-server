#!/usr/bin/env bash
#
# pair.sh — mint a one-time pair token on the hub and print the links that
# work behind Tailscale Serve.
#
#   ./pair.sh              # token for an unnamed device
#   ./pair.sh iphone       # the device shows up as "iphone" in `swe remote devices`
#
# Why this exists: `swe remote pair` prints http://<bind host>:<port>/#pair=...,
# and the hub binds 127.0.0.1 here, so that link only works on this box. The
# phone has to open the https Serve address instead, which this prints. The
# same token pairs a satellite (`swe remote agent --hub=... --token=...`).
# Tokens are single-use and expire after 5 minutes.

set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
SWE="$HOME/.local/share/quiver-hub/bin/swe"
NAME="${1:-}"

die() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "No $ENV_FILE: deploy first with $SERVICE_DIR/setup.sh"
[ -x "$SWE" ]      || die "No hub build at $SWE: deploy first with $SERVICE_DIR/setup.sh"
set -a; . "$ENV_FILE"; set +a
LOCAL_PORT="${LOCAL_PORT:?LOCAL_PORT missing from $ENV_FILE}"
HTTPS_PORT="${HTTPS_PORT:-$LOCAL_PORT}"

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed."
fi
TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is Tailscale up?)"

# --host/--port only shape the http link swe prints, which is discarded; the
# token itself goes into ~/.quiver/data/remote/, where the running hub reads it.
args=(remote pair --json --host=127.0.0.1 --port="$LOCAL_PORT")
[ -n "$NAME" ] && args+=(--name="$NAME")
json="$("$SWE" "${args[@]}")" || die "swe remote pair failed."
token="$(sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' <<<"$json" | head -1)"
[ -n "$token" ] || die "No token in swe's output: $json"

base="https://$TS_HOST:$HTTPS_PORT"
link="$base/#pair=$token"
# Same shape as swe's own link: the name rides along as &name=, URL-encoded.
if [ -n "$NAME" ]; then
  enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$NAME" 2>/dev/null || printf '%s' "$NAME")"
  link="$link&name=$enc"
fi

echo "Pair a device (single use, 5 min):"
echo
printf '  Phone:   \033[1;36m%s\033[0m\n' "$link"
echo "           (or open $base/ and type the token under 'Have a pair token?')"
printf '  Mac:     swe remote agent --hub=%s --token=%s\n' "$base" "$token"
echo
echo "  token:   $token"
if command -v qrencode >/dev/null; then
  echo
  qrencode -t ANSIUTF8 "$link" || true
fi
