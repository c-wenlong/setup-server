#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Syncthing (peer-to-peer file sync) behind
# Tailscale. Linux + macOS.
#
# End state:
#   - the official syncthing binary, pinned version, in ~/.local/bin (no root)
#   - a systemd user unit (Linux) / LaunchAgent (macOS) keeping it running
#   - web GUI on 127.0.0.1:LOCAL_PORT, published tailnet-only at
#     https://<host>.<tailnet>.ts.net:HTTPS_PORT
#   - sync protocol on <this node's tailnet IP>:SYNC_PORT, tcp + quic, and
#     NOTHING else: no wildcard bind, no relays, no global discovery, no
#     local multicast, no NAT-PMP/UPnP. Devices reach this box over the
#     tailnet by its MagicDNS name, so none of that machinery is needed, and
#     every piece of it is something that talks to the internet on your behalf.
#   - usage reporting and crash reporting declined; self-upgrade off (the
#     version is pinned here and bumped deliberately)
#   - one folder, "default", at SYNCTHING_DATA, ready to share to a device
#
# Usage:
#   ./setup.sh                                    # GUI 8384, HTTPS 8384, sync 22000
#   LOCAL_PORT=8384 HTTPS_PORT=8384 SYNC_PORT=22000 ./setup.sh
#
# ---------------------------------------------------------------------------
# WHY THE SYNC PORT IS NOT ON LOOPBACK
#
# Every web service in this repo binds 127.0.0.1 and lets Tailscale Serve
# front it. Syncthing's *GUI* does exactly that. Its *sync protocol* cannot:
# Serve proxies HTTP (and raw TCP) but not the QUIC/UDP half, and more
# importantly other Syncthing devices dial this one directly by address —
# there is no "reverse proxy" concept in the protocol. So :22000 binds the
# tailnet IP (100.x.y.z), the same exception AdGuard's resolver already makes.
# tailscale0 is not the LAN and not the internet: only devices authenticated
# onto this tailnet can send a packet there. The live test suite asserts that
# :22000 answers on the tailnet address and on nothing else.
#
# WHY NO GUI PASSWORD. Syncthing nags to set one. On this box the tailnet is
# the access layer, same as code-server: nobody off the tailnet can reach the
# GUI, and the REST API is API-key-gated regardless. Set one in the GUI if you
# want it; this script neither requires nor removes it.
#
# WHY THE HOST CHECK IS RELAXED. Syncthing's GUI refuses requests whose Host
# header is not localhost when bound to loopback (a DNS-rebinding guard).
# Tailscale Serve forwards the ORIGINAL Host header (the tailnet name), so
# without insecureSkipHostcheck=true every page is a 403 "Host check error".
# Measured on this box. The guard exists for GUIs reachable by any browser
# on the machine; here the only path to :8384 that carries a foreign Host is
# Serve itself, which is tailnet-only.
# ---------------------------------------------------------------------------
#
# Requirements: Linux (systemd) or macOS, curl, python3, tar (Linux) or
# unzip (macOS), sha256sum or shasum, and Tailscale installed + logged in.
# Sudo is needed at most twice on Linux (lingering, tailscale operator),
# never on macOS.
#
# Idempotent: safe to re-run. It repairs the unit and the publish, upgrades
# the binary when SYNCTHING_VERSION in .env changes, and never rewrites an
# existing .env. config.xml is written once; after that the RUNNING config is
# read back over REST and, if the network-exposure rules above or the GUI
# binding have drifted, those specific settings are put back through the
# same API (which is how Syncthing itself edits config.xml) — every other
# setting in the file is left exactly as you made it. Preference drift
# (reporting, self-upgrade) is reported, not reverted.
#
# Where the security model depends on the answer — where the GUI and the sync
# port are ACTUALLY bound — the REST API is not the authority and is not
# trusted as one: it reports the config, so asking it right after writing
# that config just reads the write back. Those two facts are settled in the
# socket table (ss, or lsof on macOS), and a repair that cannot be confirmed
# there fails the run rather than being reported as done.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8384}"
HTTPS_PORT="${HTTPS_PORT:-8384}"
SYNC_PORT="${SYNC_PORT:-22000}"
DEFAULT_VERSION="v2.1.5"          # first run only; .env wins after that

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
STATE="$HOME/services/syncthing"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/syncthing"
OS="$(uname -s)"

# A recovery instruction is only useful if it names the service manager this
# box actually has. This script already branches on $OS in eight places and
# prints the launchd form in its closing "Manage it with" block; these two
# strings are so that the hints buried inside error messages cannot quietly
# drift back to being Linux-only. `\$(id -u)` stays literal on purpose — it
# is printed for the user to run, not expanded here.
if [ "$OS" = "Linux" ]; then
  RESTART_HINT="systemctl --user restart syncthing"
  LOGS_HINT="journalctl --user -u syncthing -n 50"
else
  RESTART_HINT="launchctl kickstart -k gui/\$(id -u)/net.syncthing.syncthing"
  LOGS_HINT="tail -n 50 ~/Library/Logs/syncthing.log"
fi

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROBLEMS=0   # non-fatal findings that still make the run exit non-zero

# ---------------------------------------------------------------- preflight
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root (sudo is invoked only where needed)."
command -v curl >/dev/null || die "curl is required."
# python3 does two jobs here: it patches the generated config.xml before the
# first start (so the wildcard listeners never go live, even briefly), and it
# reads the REST API's JSON afterwards to verify what is actually running.
python3 -c 'import xml.etree.ElementTree, json' >/dev/null 2>&1 \
  || die "python3 (stdlib only) is required: it edits config.xml before first start and reads the REST API. On Ubuntu: sudo apt-get install -y python3"
if [ "$OS" = "Linux" ]; then
  command -v systemctl >/dev/null || die "systemd is required on Linux."
  command -v tar >/dev/null || die "tar is required."
else
  command -v unzip >/dev/null || die "unzip is required (the macOS release is a .zip)."
fi
if command -v sha256sum >/dev/null; then
  SHA256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  SHA256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "sha256sum or shasum is required to verify the download."
fi

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi
state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

for v in LOCAL_PORT HTTPS_PORT SYNC_PORT; do
  case "${!v}" in ''|*[!0-9]*) die "$v must be numeric (got: ${!v})";; esac
done

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
# The sync listener binds this address, so without it there is nothing
# sensible to bind. `|| true` because pipefail would otherwise turn a
# non-zero exit from a stopped tailscaled into a silent abort.
TS_IP="$("$TAILSCALE" ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
case "$TS_IP" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "Could not determine this node's tailnet IPv4 from '$TAILSCALE ip -4' (got: '${TS_IP:-nothing}'). The sync port binds to it." ;;
esac
# Not fatal — nothing here binds IPv6, and not every tailnet hands one out.
# It is needed only so the socket-level check below can tell tailscaled's own
# Serve frontend apart from a GUI that has escaped loopback: Serve listens on
# this node's tailnet addresses (v4 AND v6) on the SAME port number the GUI
# binds, so both of them are legitimate rows in the socket table for
# :LOCAL_PORT, and 0.0.0.0 is not.
TS_IP6="$("$TAILSCALE" ip -6 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
ok "$OS + curl + python3 + Tailscale (running)   name: $TS_HOST   ip: $TS_IP"

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600 (there is no secret in it — the
# GUI API key lives in config.xml — but paths and ports are yours to edit).
#
# Pinned. setup.sh downloads exactly this release and verifies its sha256
# against the release's signed checksum list. Syncthing's own self-upgrade is
# OFF, so this line is the only way the version changes: bump it, re-run.
SYNCTHING_VERSION=$DEFAULT_VERSION

# Web GUI: loopback only, fronted by Tailscale Serve on HTTPS_PORT.
LOCAL_PORT=$LOCAL_PORT
HTTPS_PORT=$HTTPS_PORT

# Sync protocol (BEP): tcp + quic on this node's TAILNET address, never
# 0.0.0.0. Other devices dial tcp://$TS_HOST:$SYNC_PORT.
# If this node's tailnet IP ever changes, setup.sh warns and tells you how
# to repoint the listener; it does not rewrite config.xml behind your back.
SYNC_PORT=$SYNC_PORT
SYNCTHING_LISTEN_IP=$TS_IP

# config/  — config.xml (all settings, the GUI API key) + cert.pem/key.pem.
#            The key pair IS this device's identity (the Device ID is derived
#            from it). Back this directory up; lose it and every peer has to
#            re-add this box as a new device.
# db/      — the file index database. Rebuilt by a rescan; safe to delete
#            while the service is stopped.
# data/    — the sync root. The "default" folder is created here; add more
#            folders in the GUI at any path this user can write to.
SYNCTHING_CONFIG=$STATE/config
SYNCTHING_DB=$STATE/db
SYNCTHING_DATA=$STATE/data
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Read back: an existing .env is the source of truth, so a re-run with a
# different env override can never silently move a live deployment.
REQ_LOCAL="$LOCAL_PORT"; REQ_HTTPS="$HTTPS_PORT"; REQ_SYNC="$SYNC_PORT"
set -a; . "$ENV_FILE"; set +a
VERSION="${SYNCTHING_VERSION:?SYNCTHING_VERSION missing from $ENV_FILE}"
CONFIG_DIR="${SYNCTHING_CONFIG:?SYNCTHING_CONFIG missing from $ENV_FILE}"
DB_DIR="${SYNCTHING_DB:?SYNCTHING_DB missing from $ENV_FILE}"
DATA_DIR="${SYNCTHING_DATA:?SYNCTHING_DATA missing from $ENV_FILE}"
LISTEN_IP="${SYNCTHING_LISTEN_IP:?SYNCTHING_LISTEN_IP missing from $ENV_FILE}"
for pair in "LOCAL_PORT:$REQ_LOCAL" "HTTPS_PORT:$REQ_HTTPS" "SYNC_PORT:$REQ_SYNC"; do
  name="${pair%%:*}"; req="${pair#*:}"
  [ "${!name}" = "$req" ] || warn "$name=$req ignored — the existing $ENV_FILE says ${!name}. Edit .env and re-run to move it."
done
case "$VERSION" in v[0-9]*) ;; *) die "SYNCTHING_VERSION in .env must look like v2.1.5 (got: $VERSION)";; esac
CONFIG_FILE="$CONFIG_DIR/config.xml"

if [ "$LISTEN_IP" != "$TS_IP" ]; then
  # A config.xml that already exists is never rewritten (see below), so the
  # stale address only affects a listener that is already live: warn, and let
  # the exposure check further down report the listen addresses it finds.
  #
  # With NO config.xml the same warning would be a lie by omission. The run
  # would go on to GENERATE a fresh config pinned to $LISTEN_IP — an address
  # this host does not hold — and every later check would then agree with
  # itself: the exposure check compares the running config against the same
  # dead address, so it passes, and an empty socket table is only a warning.
  # The deploy would print "Done." over a listener that can never bind.
  # Refuse instead, and say exactly which line to edit.
  if [ ! -f "$CONFIG_FILE" ]; then
    die "SYNCTHING_LISTEN_IP in $ENV_FILE is $LISTEN_IP but this node's tailnet IP is $TS_IP, and there is no $CONFIG_FILE yet. Generating one would pin the sync listener to an address this host does not hold — it could never bind, and the checks in this script would not catch it. Fix: set SYNCTHING_LISTEN_IP=$TS_IP in $ENV_FILE and re-run."
  fi
  warn "SYNCTHING_LISTEN_IP in .env is $LISTEN_IP but this node's tailnet IP is now $TS_IP."
  warn "  The sync listener will fail to bind until they match. Fix: set SYNCTHING_LISTEN_IP=$TS_IP in $ENV_FILE, then repoint the listener (see the drift warning below) and re-run."
fi

mkdir -p "$STATE" "$CONFIG_DIR" "$DB_DIR" "$DATA_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR"

avail_kb="$(df -Pk "$DATA_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 1048576 ]; then
  warn "$(( avail_kb / 1024 )) MB free at $DATA_DIR — Syncthing pauses folders when the disk is nearly full (minDiskFree 1%)."
else
  ok "$(( avail_kb / 1048576 )) GB free at $DATA_DIR"
fi

# ---------------------------------------------------- install / upgrade
installed=""
if [ -x "$BIN" ]; then
  installed="$("$BIN" --version 2>/dev/null | awk '{print $2}' || true)"
  # Anything that is not a version tag means a broken or foreign file at
  # that path (a half-finished upgrade, say): treat as not installed.
  case "$installed" in v[0-9]*) ;; *) installed="" ;; esac
fi
if [ "$installed" = "$VERSION" ]; then
  ok "syncthing $VERSION already installed at $BIN"
else
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv6l) ARCH="arm" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  if [ "$OS" = "Linux" ]; then
    ASSET="syncthing-linux-$ARCH-$VERSION.tar.gz"
  else
    ASSET="syncthing-macos-$ARCH-$VERSION.zip"
  fi
  BASE="https://github.com/syncthing/syncthing/releases/download/$VERSION"
  info "Downloading syncthing $VERSION ($ASSET) — ~12 MB"
  curl -fsSL --retry 3 -o "$WORK/$ASSET" "$BASE/$ASSET" \
    || die "Download failed: $BASE/$ASSET (does that release exist? check SYNCTHING_VERSION in $ENV_FILE)"
  # Every release ships one signed list of checksums covering all assets.
  # The PGP signature is not verified here (no gpg dependency); the sha256
  # still proves the tarball is the one GitHub is serving for that release,
  # which is what defends against a truncated or tampered-in-transit download.
  curl -fsSL --retry 3 -o "$WORK/sha256sum.txt.asc" "$BASE/sha256sum.txt.asc" \
    || die "Could not download the checksum list: $BASE/sha256sum.txt.asc"
  # `|| true`: under pipefail a no-match grep would abort the script here
  # silently, before the explanatory die below.
  want="$(grep " $ASSET\$" "$WORK/sha256sum.txt.asc" | awk '{print $1}' | head -1 || true)"
  [ -n "$want" ] || die "$ASSET is not listed in the release's sha256sum.txt.asc — refusing to install an unverifiable binary."
  got="$(SHA256 "$WORK/$ASSET")"
  [ "$got" = "$want" ] || die "Checksum mismatch for $ASSET: expected $want, got $got. Not installing. Re-run to retry the download."
  ok "sha256 verified: $want"

  mkdir -p "$WORK/x"
  if [ "$OS" = "Linux" ]; then
    tar -xzf "$WORK/$ASSET" -C "$WORK/x"
  else
    unzip -q "$WORK/$ASSET" -d "$WORK/x"
  fi
  # The release unpacks to <asset-stem>/syncthing. Do NOT `find -name
  # syncthing`: the tarball also ships etc/firewall-ufw/syncthing, a ufw
  # profile, which a naive search returns first (it did, on this box).
  stem="${ASSET%.tar.gz}"; stem="${stem%.zip}"
  extracted="$WORK/x/$stem/syncthing"
  if [ ! -f "$extracted" ]; then
    extracted="$(find "$WORK/x" -type f -name syncthing -perm -u+x | head -1 || true)"
  fi
  [ -n "$extracted" ] && [ -f "$extracted" ] || die "No 'syncthing' binary inside $ASSET (expected $stem/syncthing)"
  # A file, not a script: the binary is ELF/Mach-O and answers --version.
  "$extracted" --version >/dev/null 2>&1 || die "$extracted does not run — wrong architecture? ($(uname -m) -> $ARCH)"
  # A bump is a replace-in-place: the running service keeps its old inode
  # until the restart below, so there is no window with a half-written binary.
  install -m 755 "$extracted" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  ok "Installed $("$BIN" --version | awk '{print $1, $2}') to $BIN${installed:+ (was $installed)}"
fi

# ---------------------------------------------------------------- config
FRESH=0
if [ -f "$CONFIG_FILE" ]; then
  ok "config.xml already exists, leaving untouched: $CONFIG_FILE"
else
  FRESH=1
  info "Generating device identity + config (syncthing generate)"
  # v2.x refuses --config without --data ("either both or none"); the db
  # directory is created by the first `serve`, generate only needs the path.
  "$BIN" generate --config="$CONFIG_DIR" --data="$DB_DIR" --no-port-probing >"$WORK/generate.log" 2>&1 \
    || { cat "$WORK/generate.log" >&2; die "syncthing generate failed"; }
  [ -f "$CONFIG_FILE" ] || die "syncthing generate ran but produced no $CONFIG_FILE"

  # Patch BEFORE the first start. The generated defaults listen on 0.0.0.0,
  # register with the public relay pool and announce to the global discovery
  # servers within seconds of starting; they must never go live, not even
  # for one restart's worth of seconds. stdlib xml only, written atomically,
  # mode 600 preserved.
  info "Applying house rules to config.xml (tailnet-only listener, no relays/discovery/NAT, no reporting, no self-upgrade)"
  python3 - "$CONFIG_FILE" "127.0.0.1:$LOCAL_PORT" "$LISTEN_IP" "$SYNC_PORT" <<'PY'
import os, sys, tempfile
import xml.etree.ElementTree as ET
path, gui_addr, listen_ip, sync_port = sys.argv[1:5]
tree = ET.parse(path); root = tree.getroot()
opts = root.find("options"); gui = root.find("gui")
if opts is None or gui is None:
    sys.exit("config.xml has no <options>/<gui> block — unexpected config layout")
def setopt(parent, tag, value):
    el = parent.find(tag)
    if el is None:
        el = ET.SubElement(parent, tag)
    el.text = value
for el in opts.findall("listenAddress"):
    opts.remove(el)
for i, url in enumerate(("tcp://%s:%s" % (listen_ip, sync_port),
                         "quic://%s:%s" % (listen_ip, sync_port))):
    el = ET.Element("listenAddress"); el.text = url; opts.insert(i, el)
for tag, val in (("globalAnnounceEnabled", "false"),   # no discovery.syncthing.net
                 ("localAnnounceEnabled", "false"),    # no LAN multicast on :21027
                 ("relaysEnabled", "false"),           # no relays.syncthing.net
                 ("natEnabled", "false"),              # no UPnP/NAT-PMP on the router
                 ("announceLANAddresses", "false"),
                 ("startBrowser", "false"),
                 ("urAccepted", "-1"),                 # usage reporting: declined
                 ("crashReportingEnabled", "false"),
                 ("autoUpgradeIntervalH", "0")):       # pinned by .env instead
    setopt(opts, tag, val)
# The "set a GUI user and password" nag. The tailnet is the auth layer here.
for el in opts.findall("unackedNotificationID"):
    opts.remove(el)
setopt(gui, "address", gui_addr)
setopt(gui, "insecureSkipHostcheck", "true")   # Serve forwards the tailnet Host header
ET.indent(tree, space="    ")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.xml.")
with os.fdopen(fd, "wb") as f:
    tree.write(f, encoding="utf-8", xml_declaration=False)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
  chmod 600 "$CONFIG_FILE"
  ok "Wrote $CONFIG_FILE"
fi

API_KEY="$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' "$CONFIG_FILE" | head -1)"
[ -n "$API_KEY" ] || die "No <apikey> in $CONFIG_FILE — cannot talk to the REST API."

# ------------------------------------------------------------ service
if [ "$OS" = "Linux" ]; then
  UNIT="$HOME/.config/systemd/user/syncthing.service"
  info "Installing systemd user service"
  mkdir -p "$(dirname "$UNIT")"
  # --no-restart + Restart=always: when the GUI asks for a restart Syncthing
  # exits 3 and systemd brings it back, which is the upstream unit's design.
  # --no-upgrade: the binary is pinned by .env; Syncthing must not replace it.
  # Hardening lines are upstream's. No network ordering: measured, Syncthing
  # keeps running and retries the bind on its own if tailscale0 is not up yet.
  cat > "$UNIT" <<EOF
[Unit]
Description=Syncthing (peer-to-peer file sync)
Documentation=https://docs.syncthing.net/
After=network.target

[Service]
Type=exec
ExecStart=$BIN serve --config=$CONFIG_DIR --data=$DB_DIR --no-browser --no-restart --no-upgrade
Restart=always
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4
ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable syncthing >/dev/null 2>&1
  systemctl --user restart syncthing
  ok "Service enabled and (re)started"
else
  PLIST="$HOME/Library/LaunchAgents/net.syncthing.syncthing.plist"
  info "Installing launchd LaunchAgent"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.syncthing.syncthing</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>serve</string>
    <string>--config=$CONFIG_DIR</string>
    <string>--data=$DB_DIR</string>
    <string>--no-browser</string>
    <string>--no-restart</string>
    <string>--no-upgrade</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/syncthing.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/syncthing.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/net.syncthing.syncthing" 2>/dev/null || true
  # teardown.sh disables the label (so RunAtLoad cannot restart it at the
  # next login); a disabled label refuses bootstrap. A no-op otherwise.
  launchctl enable "gui/$(id -u)/net.syncthing.syncthing"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent loaded (starts at login; logs: ~/Library/Logs/syncthing.log)"
fi

# ------------------------------------------------------------- HTTP helpers
ST_CODE=""
http() {  # http URL [extra curl args...] -> body in $WORK/resp, code in $ST_CODE
  local url="$1"; shift
  # curl prints 000 and exits non-zero on a refused connection; take its own
  # output rather than appending a fallback, which would give "000000".
  ST_CODE="$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time "${ST_TIMEOUT:-15}" "$@" "$url" 2>/dev/null)" || true
  case "$ST_CODE" in [0-9][0-9][0-9]) ;; *) ST_CODE=000 ;; esac
}
api() {  # api GET|POST|PATCH /rest/path [json-body]
  if [ "$1" = "POST" ] || [ "$1" = "PATCH" ]; then
    http "http://127.0.0.1:$LOCAL_PORT$2" -H "X-API-Key: $API_KEY" -X "$1" -H 'Content-Type: application/json' --data-binary "${3:-}"
  else
    http "http://127.0.0.1:$LOCAL_PORT$2" -H "X-API-Key: $API_KEY"
  fi
}
# /rest/noauth/health answers {"status":"OK"} with no API key. A refused
# connection (000) is "not ready yet", not failure: the process is up before
# the socket is, and a deploy that dies on the first 000 fails cold starts.
wait_health() {  # wait_health BASE_URL ATTEMPTS
  local i
  for i in $(seq 1 "$2"); do
    http "$1/rest/noauth/health"
    [ "$ST_CODE" = "200" ] && grep -q '"OK"' "$WORK/resp" && return 0
    sleep 2
  done
  return 1
}
jpy() { python3 - "$WORK/resp" "$@"; }   # run a python snippet on the last response

# ------------------------------------------------------ socket-level checks
# The only thing in this deploy that can tell a real bind from a config file's
# opinion of one. Every other check here talks to the REST API, and the API
# reports the CONFIG: ask it where the GUI listens right after PATCHing that
# very setting and it will read the PATCH back to you whether or not the
# process ever rebound. Same for the sync port — config.xml can name the right
# address while the bind failed (tailnet IP not held yet) or a stale process
# still holds the old one.
#
# Knowing we have NO such tool is itself a finding, not a free pass: the
# GUI-repair path below refuses to claim success it cannot verify.
if command -v ss >/dev/null; then SOCKET_TOOL="ss"
elif command -v lsof >/dev/null; then SOCKET_TOOL="lsof"
else SOCKET_TOOL=""; fi
[ -n "$SOCKET_TOOL" ] || warn "Neither ss nor lsof is installed, so this run cannot check on the wire what is actually listening. On Ubuntu: sudo apt-get install -y iproute2"

listener_addrs() {  # listener_addrs PORT -> one "addr:port" per line, tcp + udp
  local port="$1"
  case "$SOCKET_TOOL" in
    ss)
      { ss -ltnH "sport = :$port"; ss -lunH "sport = :$port"; } 2>/dev/null \
        | awk '{print $4}' | sort -u || true ;;
    lsof)
      # Listening sockets only. A bare `-i:PORT` also returns ESTABLISHED
      # connections (local:22000->peer:port), which are not listeners:
      # -sTCP:LISTEN for TCP, and for UDP (stateless) drop anything with a
      # peer half. Both `lsof` and the pipeline exit non-zero when nothing
      # matches, which under pipefail would abort the caller's assignment.
      { lsof -nP -iTCP:"$port" -sTCP:LISTEN; lsof -nP -iUDP:"$port"; } 2>/dev/null \
        | awk '$1 != "COMMAND" && $9 !~ /->/ {print $9}' | sort -u || true ;;
  esac
}

foreign_listeners() {  # foreign_listeners PORT ALLOWED_HOST... -> " a b" (empty = clean)
  # Every listener on PORT whose address is not one of the allowed hosts,
  # space-prefixed for dropping straight into a message. Empty output means
  # either "all where we want them" or "nothing bound at all", so callers
  # check listener_addrs first when that distinction matters.
  local port="$1"; shift
  local a host want allowed out=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    # "127.0.0.1:8384" -> 127.0.0.1, "[::1]:8384" -> ::1
    host="${a%:*}"; host="$(printf '%s' "$host" | tr -d '[]')"
    allowed=0
    for want in "$@"; do
      if [ -n "$want" ] && [ "$host" = "$want" ]; then allowed=1; break; fi
    done
    [ "$allowed" = "1" ] || out="$out $a"
  done <<EOF
$(listener_addrs "$port")
EOF
  printf '%s' "$out"
}

# Addresses that may legitimately answer on the GUI port. Loopback is the GUI
# itself; the tailnet addresses are tailscaled's Serve frontend, which is
# published on the SAME port number the GUI binds. 0.0.0.0, :: or a LAN
# address is none of those, and the GUI has no password.
gui_foreign() { foreign_listeners "$LOCAL_PORT" 127.0.0.1 ::1 localhost "$TS_IP" "$TS_IP6"; }

info "Waiting for Syncthing on 127.0.0.1:$LOCAL_PORT"
wait_health "http://127.0.0.1:$LOCAL_PORT" 30 \
  || { [ "$OS" = "Linux" ] && die "Syncthing did not answer /rest/noauth/health (last HTTP $ST_CODE). Logs: journalctl --user -u syncthing -n 50"
       die "Syncthing did not answer /rest/noauth/health (last HTTP $ST_CODE). Logs: ~/Library/Logs/syncthing.log"; }
ok "Syncthing is healthy locally"

# ------------------------------------------------ verify the running config
# What is RUNNING, not what config.xml says: the two differ if someone edited
# the file without a restart, or changed a setting in the GUI. On a fresh
# deploy every line must match (the patch above just wrote them); on a re-run
# a mismatch is the user's change or drift, so it is reported, not reverted.
api GET /rest/system/status
[ "$ST_CODE" = "200" ] || die "GET /rest/system/status returned HTTP $ST_CODE — is the API key in $CONFIG_FILE the one the service loaded?"
DEVICE_ID="$(jpy <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("myID", ""))
PY
)"
[ -n "$DEVICE_ID" ] || die "Could not read this device's ID from /rest/system/status"
ok "Device ID: $DEVICE_ID"

# Two tiers of house rule. EXPOSURE (what the box listens on and which
# third parties it registers with) is the security model: drift there is put
# back, through the same REST API the GUI uses, so nothing else in config.xml
# is touched. PREFERENCE (reporting, self-upgrade — inert anyway under
# --no-upgrade) is the deploy's opinion: drift there is reported, not
# reverted. Syncthing persists the API change to config.xml itself.
WANT_LISTEN_TCP="tcp://$LISTEN_IP:$SYNC_PORT"
WANT_LISTEN_QUIC="quic://$LISTEN_IP:$SYNC_PORT"
check_options() {  # -> exposure problems on stdout, preference problems on stderr
  jpy "$WANT_LISTEN_TCP" "$WANT_LISTEN_QUIC" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
want_listen = sorted(sys.argv[2:4])
have = sorted(o.get("listenAddresses") or [])
if have != want_listen:
    print("listenAddresses=%s (want %s)" % (have, want_listen))
for k in ("globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled",
          "natEnabled", "announceLANAddresses"):
    if o.get(k) is not False:
        print("%s=%s (want false)" % (k, json.dumps(o.get(k))))
if o.get("crashReportingEnabled") is not False:
    print("crashReportingEnabled=%s (want false)" % json.dumps(o.get("crashReportingEnabled")), file=sys.stderr)
if o.get("autoUpgradeIntervalH") != 0:
    print("autoUpgradeIntervalH=%s (want 0; inert under --no-upgrade)" % json.dumps(o.get("autoUpgradeIntervalH")), file=sys.stderr)
if o.get("urAccepted", 0) >= 0:
    print("urAccepted=%s (want -1: usage reporting declined)" % o.get("urAccepted"), file=sys.stderr)
PY
}

api GET /rest/config/options
[ "$ST_CODE" = "200" ] || die "GET /rest/config/options returned HTTP $ST_CODE"
EXPOSURE="$(check_options 2>"$WORK/prefs")"
PREFS="$(cat "$WORK/prefs")"
if [ -n "$EXPOSURE" ] && [ "$FRESH" = "1" ]; then
  printf '%s\n' "$EXPOSURE" >&2
  die "Fresh config.xml was patched but the running instance disagrees (above). Check $CONFIG_FILE and the service log."
elif [ -n "$EXPOSURE" ]; then
  warn "The running config has drifted from the exposure rules — repairing these settings (nothing else in config.xml is touched):"
  printf '%s\n' "$EXPOSURE" | sed 's/^/      /'
  body="$(python3 -c 'import json,sys; print(json.dumps({"listenAddresses":[sys.argv[1],sys.argv[2]],"globalAnnounceEnabled":False,"localAnnounceEnabled":False,"relaysEnabled":False,"natEnabled":False,"announceLANAddresses":False}))' "$WANT_LISTEN_TCP" "$WANT_LISTEN_QUIC")"
  api PATCH /rest/config/options "$body"
  [ "$ST_CODE" = "200" ] || die "PATCH /rest/config/options returned HTTP $ST_CODE: $(head -c 200 "$WORK/resp")"
  api GET /rest/config/options
  [ "$ST_CODE" = "200" ] || die "GET /rest/config/options returned HTTP $ST_CODE after the repair"
  still="$(check_options 2>/dev/null)"
  [ -z "$still" ] || { printf '%s\n' "$still" >&2; die "Repaired the options over REST but the running instance still disagrees (above). Fix by hand: Settings -> Connections, listen addresses $WANT_LISTEN_TCP, $WANT_LISTEN_QUIC; relays, discovery and NAT off."; }
  ok "Repaired: listens ONLY on $LISTEN_IP:$SYNC_PORT (tcp+quic); relays, global + local discovery, NAT traversal off. Syncthing rebinds live; the socket check below confirms."
else
  ok "Running config matches the exposure rules: listens ONLY on $LISTEN_IP:$SYNC_PORT (tcp+quic); relays, global + local discovery, NAT traversal off"
fi
if [ -n "$PREFS" ]; then
  warn "Preference drift (left as you set it): $(printf '%s' "$PREFS" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
else
  ok "Reporting declined and self-upgrade off, as deployed"
fi

api GET /rest/config/gui
[ "$ST_CODE" = "200" ] || die "GET /rest/config/gui returned HTTP $ST_CODE"
check_gui() {  # -> "BAD_ADDRESS <addr>" / "HOSTCHECK" lines, plus "user=<name|->"
  jpy "127.0.0.1:$LOCAL_PORT" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
print("user=%s" % (g.get("user") or "-"))
if g.get("address") != sys.argv[2]:
    print("BAD_ADDRESS %s" % g.get("address"))
if not g.get("insecureSkipHostcheck"):
    print("HOSTCHECK")
PY
}
GUI_STATE="$(check_gui)"
case "$GUI_STATE" in
  *BAD_ADDRESS*|*HOSTCHECK*)
    if [ "$FRESH" = "1" ]; then
      printf '%s\n' "$GUI_STATE" >&2
      die "Fresh config.xml was patched but the running GUI config disagrees (above). Check $CONFIG_FILE."
    fi
    case "$GUI_STATE" in
      *BAD_ADDRESS*) warn "GUI is bound to $(printf '%s\n' "$GUI_STATE" | sed -n 's/^BAD_ADDRESS //p'), not 127.0.0.1:$LOCAL_PORT — a non-loopback address is reachable off the tailnet. Repairing." ;;
    esac
    case "$GUI_STATE" in
      *HOSTCHECK*) warn "insecureSkipHostcheck is off — every page through Tailscale Serve would be a 403 'Host check error'. Repairing." ;;
    esac
    # Address and host check are read when the API service starts, so a
    # restart is required for either. --no-restart makes that exit 3, and
    # the unit brings it back.
    api PATCH /rest/config/gui "{\"address\":\"127.0.0.1:$LOCAL_PORT\",\"insecureSkipHostcheck\":true}"
    [ "$ST_CODE" = "200" ] || die "PATCH /rest/config/gui returned HTTP $ST_CODE: $(head -c 200 "$WORK/resp")"
    info "Restarting Syncthing so the GUI change takes effect"
    api POST /rest/system/restart
    # An unchecked restart is how this repair used to lie. The PATCH above
    # only edits the config; the address is read when the API service starts,
    # so a restart that never happened leaves the OLD listener in place —
    # while every read-back below happily echoes the config we just wrote.
    [ "$ST_CODE" = "200" ] || die "POST /rest/system/restart returned HTTP $ST_CODE: $(head -c 200 "$WORK/resp"). The GUI address was changed in the config but the running process still holds the old bind — it may still be reachable off loopback. Restart by hand ($RESTART_HINT) and re-run."
    sleep 2
    wait_health "http://127.0.0.1:$LOCAL_PORT" 30 || die "Syncthing did not come back after the GUI repair (last HTTP $ST_CODE). Logs: $LOGS_HINT"
    api GET /rest/config/gui
    [ "$ST_CODE" = "200" ] || die "GET /rest/config/gui returned HTTP $ST_CODE after the repair"
    GUI_STATE="$(check_gui)"
    case "$GUI_STATE" in
      *BAD_ADDRESS*|*HOSTCHECK*) die "Repaired the GUI config over REST but it still disagrees after restart: $GUI_STATE. Fix by hand in $CONFIG_FILE (<gui><address>127.0.0.1:$LOCAL_PORT</address><insecureSkipHostcheck>true</insecureSkipHostcheck>) and restart." ;;
    esac
    # Neither of the two checks above proves anything about the wire. The GET
    # reads back the config this script just PATCHed, and wait_health passing
    # proves nothing either: a wildcard bind answers on 127.0.0.1 too. The
    # thing being repaired is an unauthenticated GUI listening on 0.0.0.0 and
    # reachable from the LAN, so confirm on the socket table or do not claim
    # the repair at all — fail closed, in both directions.
    [ -n "$SOCKET_TOOL" ] || die "Repaired the GUI config over REST, but this box has neither ss nor lsof, so where the GUI is actually bound cannot be checked. Refusing to report it as loopback-only while it may still be on 0.0.0.0:$LOCAL_PORT. Install iproute2 (Linux), or verify by hand, then re-run."
    [ -n "$(listener_addrs "$LOCAL_PORT")" ] || die "Repaired the GUI config over REST and Syncthing answered on 127.0.0.1:$LOCAL_PORT, but $SOCKET_TOOL shows nothing listening on :$LOCAL_PORT — the new bind cannot be confirmed, so the repair is not proven. Check by hand and re-run."
    gui_off_loopback="$(gui_foreign)"
    [ -z "$gui_off_loopback" ] || die "The GUI repair did NOT take: :$LOCAL_PORT is still listening on$gui_off_loopback — off loopback and off this node's tailnet addresses, i.e. reachable from the LAN, with no GUI password. The config now says 127.0.0.1:$LOCAL_PORT, so the process never rebound. Restart it ($RESTART_HINT) and re-run; if it comes back on the same address, something other than Syncthing holds :$LOCAL_PORT."
    ok "Repaired: GUI on 127.0.0.1:$LOCAL_PORT with the host check relaxed for Serve (confirmed on the wire, not just in the config)"
    ;;
esac
gui_user="$(printf '%s\n' "$GUI_STATE" | sed -n 's/^user=//p' | head -1)"
if [ "$gui_user" = "-" ]; then
  ok "GUI: 127.0.0.1:$LOCAL_PORT, no GUI password (the tailnet is the auth layer); REST API key-gated"
else
  ok "GUI: 127.0.0.1:$LOCAL_PORT, GUI login set (user: $gui_user)"
fi

# ---------------------------------------------------------- default folder
# Only on the run that generated the config. A later run with zero folders is
# the user having removed them, not a repair opportunity.
api GET /rest/config/folders
[ "$ST_CODE" = "200" ] || die "GET /rest/config/folders returned HTTP $ST_CODE"
NFOLDERS="$(jpy <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1]))))
PY
)"
if [ "$FRESH" = "1" ] && [ "$NFOLDERS" = "0" ]; then
  info "Creating the 'default' folder at $DATA_DIR/default"
  mkdir -p "$DATA_DIR/default"
  # Minimal body; the server fills every other field from its defaults
  # (measured: rescan 3600s, fsWatcher on, .stfolder marker created).
  body="$(python3 -c 'import json,sys; print(json.dumps({"id":"default","label":"Default","path":sys.argv[1],"type":"sendreceive"}))' "$DATA_DIR/default")"
  api POST /rest/config/folders "$body"
  [ "$ST_CODE" = "200" ] || die "POST /rest/config/folders returned HTTP $ST_CODE: $(head -c 200 "$WORK/resp")"
  NFOLDERS=1
  ok "Folder 'default' -> $DATA_DIR/default (shared with no device yet)"
else
  ok "$NFOLDERS folder(s) configured"
fi

# ------------------------------------------------------------- lingering
if [ "$OS" = "Linux" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time)"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled — service now starts at boot"
  fi
fi

# ------------------------------------------------------- tailscale serve
info "Publishing the GUI via Tailscale Serve (HTTPS :$HTTPS_PORT, tailnet only)"
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

# ------------------------------------------------------------ final checks
url="https://$TS_HOST:$HTTPS_PORT"
info "Verifying $url (first request can take ~60s while the TLS cert is minted)"
ST_TIMEOUT=90 http "$url/rest/noauth/health"
if [ "$ST_CODE" = "200" ] || wait_health "$url" 15; then
  ok "End-to-end HTTPS check passed"
  # The health endpoint skips the host check; the GUI root does not. This is
  # the request a browser makes, with the Host header Serve actually forwards.
  http "$url/"
  case "$ST_CODE" in
    200) ok "GUI answers through Serve (host check passed)" ;;
    403) PROBLEMS=1; warn "GUI root is a 403 through Serve — Syncthing's host check is rejecting the tailnet Host header even though the running config says insecureSkipHostcheck=true. Restart the service ($RESTART_HINT) and re-run; if it persists, check <gui> in $CONFIG_FILE." ;;
    *)   warn "GUI root returned HTTP $ST_CODE through Serve (expected 200)." ;;
  esac
else
  warn "No answer on $url/rest/noauth/health yet (HTTP $ST_CODE) — the cert may still be minting. Retry in a minute: curl $url/rest/noauth/health"
fi

# The sync listener, checked on the wire (see the helpers above for why the
# REST API cannot answer this question).
sync_addrs="$(listener_addrs "$SYNC_PORT")"
if [ -z "$SOCKET_TOOL" ]; then
  # The same split the GUI check below makes, for the same reason: with no ss
  # and no lsof, `sync_addrs` is empty because nothing ever looked, not
  # because nothing is bound. Reporting that as "not listening yet, Syncthing
  # retries" is a confident, specific diagnosis of a table that was never
  # read, and it points the reader at a self-healing state when the truth may
  # be a listener sitting on an address it should not be on.
  #
  # PROBLEMS is set here rather than left to the GUI check: today both fire on
  # exactly this condition, but that is a coincidence of ordering, and a check
  # that depends on another one's side effect breaks quietly when either moves.
  PROBLEMS=1
  warn "Could not check what is listening on :$SYNC_PORT: this box has neither ss nor lsof, so whether the sync port is on $LISTEN_IP only is unverified. Install iproute2 (Linux) or use a box with lsof (macOS ships it), then re-run."
elif [ -z "$sync_addrs" ]; then
  warn "Nothing is listening on :$SYNC_PORT yet. Syncthing retries the bind on its own; if this persists, is $LISTEN_IP still this node's tailnet IP? (tailscale ip -4)"
else
  foreign="$(foreign_listeners "$SYNC_PORT" "$LISTEN_IP")"
  if [ -z "$foreign" ]; then
    ok "Sync port :$SYNC_PORT is bound to $LISTEN_IP only (tcp + udp/quic)"
  else
    PROBLEMS=1
    warn "Sync port :$SYNC_PORT is ALSO listening on:$foreign — that is off the tailnet. Fix the listen addresses (see above) or stop whatever else holds that port."
  fi
fi

# And the GUI port, on the wire too — every run, not only the repair path.
# The GUI has no password: the tailnet IS the auth layer, so a GUI that
# answers on 0.0.0.0 or a LAN address is the whole security model gone, and
# nothing that reads config.xml or the REST API can see that happen.
gui_addrs="$(listener_addrs "$LOCAL_PORT")"
if [ -z "$SOCKET_TOOL" ]; then
  # No ss and no lsof: where the GUI is bound — the single fact the
  # tailnet-as-the-auth-layer model rests on — cannot be established on this
  # box by any means. That is not "probably fine". The deploy stays up (it
  # may well be correct) but the run carries the finding out in its exit
  # status, the same way every other unverifiable security fact in this repo
  # does. Distinct from the case below on purpose: "the tool looked and saw
  # nothing" is evidence, "there is no tool" is the absence of evidence.
  PROBLEMS=1
  warn "Could not verify where the GUI is bound: this box has neither ss nor lsof. The GUI has no password, so a bind that escaped loopback would be reachable from the LAN and nothing in this run would see it. Install iproute2 (Linux) or use a box with lsof (macOS ships it), then re-run."
elif [ -z "$gui_addrs" ]; then
  # The tool ran and found no rows. Same treatment the sync port gets a few
  # lines up: a bind that has not appeared yet is a normal, self-healing
  # state, not a finding.
  warn "$SOCKET_TOOL showed nothing listening on :$LOCAL_PORT even though Syncthing answered there — this run could not confirm on the wire that the GUI is loopback-only."
else
  gui_off_loopback="$(gui_foreign)"
  if [ -z "$gui_off_loopback" ]; then
    ok "GUI port :$LOCAL_PORT answers on loopback and this node's tailnet address (Serve) only"
  else
    PROBLEMS=1
    warn "GUI port :$LOCAL_PORT is listening on$gui_off_loopback — off loopback and off the tailnet, and the GUI has no password. Expected 127.0.0.1:$LOCAL_PORT (plus tailscaled's Serve frontend on $TS_IP). Check <gui><address> in $CONFIG_FILE and restart, or stop whatever else holds that port."
  fi
fi

echo
printf '\033[1;32mDone.\033[0m Syncthing GUI: \033[1m%s\033[0m (tailnet only)\n' "$url"
echo
printf '  This device ID:  \033[1m%s\033[0m\n' "$DEVICE_ID"
echo "  Sync address:    tcp://$TS_HOST:$SYNC_PORT   (tailnet only — also quic://)"
echo
echo "Add this box from another device (laptop/phone, on the tailnet):"
echo "  1. In that device's Syncthing: Add Remote Device -> paste the Device ID above."
echo "     Under Advanced -> Addresses, replace 'dynamic' with"
echo "       tcp://$TS_HOST:$SYNC_PORT"
echo "     Global discovery is OFF on this box on purpose, so 'dynamic' would"
echo "     never resolve it. The MagicDNS name is stable; the IP may not be."
echo "  2. Open $url -> accept the incoming device"
echo "     (a banner appears within a minute) -> share the 'default' folder,"
echo "     or add a folder at any path this user can write to."
echo "  3. On the other device, accept the folder and pick a local path."
echo "  This box never dials out: with discovery and relays off it waits for"
echo "  peers to connect to it, which is the right shape for an always-on server."
echo
echo "Where things are:"
echo "  sync root:  $DATA_DIR   ('default' folder lives at $DATA_DIR/default)"
echo "  identity:   $CONFIG_DIR   (cert.pem/key.pem = this Device ID; config.xml = every setting + the API key)"
echo "  index db:   $DB_DIR   (rebuildable; delete while stopped to force a full rescan)"
echo "  binary:     $BIN   ($VERSION, pinned in $ENV_FILE; self-upgrade is off)"
echo
echo "Manage it with:"
if [ "$OS" = "Linux" ]; then
  echo "  systemctl --user status|restart|stop syncthing"
  echo "  journalctl --user -u syncthing -f"
else
  echo "  launchctl kickstart -k gui/\$(id -u)/net.syncthing.syncthing   # restart"
  echo "  tail -f ~/Library/Logs/syncthing.log"
fi
echo "  tailscale serve status        # or: tailscale serve --https=$HTTPS_PORT off"
echo "  curl -H 'X-API-Key: \$(sed -n \"s/.*<apikey>\\(.*\\)<\\/apikey>.*/\\1/p\" $CONFIG_FILE)' http://127.0.0.1:$LOCAL_PORT/rest/system/status"
echo "Upgrade: bump SYNCTHING_VERSION in $ENV_FILE (releases: github.com/syncthing/syncthing/releases) and re-run ./setup.sh"
echo "Backup:  $CONFIG_DIR is the identity — copy it somewhere off this box."

if [ "$PROBLEMS" = "1" ]; then
  echo
  printf '\033[1;31m ✗ \033[0m %s\n' "Exiting non-zero: the deploy is up, but at least one warning above is a security-model or usability break (a sync listener off the tailnet, a GUI answering off loopback, or a GUI that 403s through Serve). Fix it and re-run."
  exit 1
fi
exit 0
