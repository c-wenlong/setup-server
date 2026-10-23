#!/usr/bin/env bash
#
# pair.sh — mint a one-time pair token on the hub and print the links for a
# phone and for a satellite.
#
#   ./pair.sh              # token for an unnamed device
#   ./pair.sh iphone       # the device shows up as "iphone" in `swe remote devices`
#
# "Pair with Tailscale" in the PWA is the usual way to pair a phone. This is
# the token path: for a device Tailscale can't identify, and for satellites
# (`swe remote agent --hub=... --token=...`). It runs the hub's own build of
# `swe remote pair`, because the `swe` on PATH may be older. That command
# reads the hub's public https URL from ~/.quiver/data/remote/hub.json, which
# the running hub writes after it binds. Tokens are single-use and expire
# after 5 minutes.

set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SWE="$HOME/.local/share/quiver-hub/bin/swe"
NAME="${1:-}"

die() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$SWE" ] || die "No hub build at $SWE: deploy first with $SERVICE_DIR/setup.sh"

args=(remote pair --json)
[ -n "$NAME" ] && args+=(--name="$NAME")
json="$("$SWE" "${args[@]}")" || die "swe remote pair failed."
token="$(sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' <<<"$json" | head -1)"
link="$(sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' <<<"$json" | head -1)"
[ -n "$token" ] || die "No token in swe's output: $json"
# An http link means the hub never saved its --public-url (it predates
# setup.sh's --public-url unit, or has not started since): the phone can't
# open it.
case "$link" in
  https://*) ;;
  *) die "swe remote pair gave '$link', not the https Serve URL. Re-run $SERVICE_DIR/setup.sh so the hub starts with --public-url." ;;
esac
base="${link%%/#*}"

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
