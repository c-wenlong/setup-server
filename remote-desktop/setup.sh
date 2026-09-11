#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of remote-desktop: THIS host's GNOME desktop,
# operated from a browser tab on the tailnet.
#
# End state:
#   - gnome-remote-desktop's system daemon ("Remote Login") serving RDP on
#     127.0.0.1:3389 and on the Guacamole bridge, and NOWHERE else
#   - guacd + a Guacamole webapp (file auth, no database) on a private
#     docker bridge, webapp published on 127.0.0.1:8094
#   - the webapp published tailnet-only at
#     https://<host>.<tailnet>.ts.net:8094/  (tailscale serve)
#
# ---------------------------------------------------------------------------
# READ THIS FIRST — TWO WAYS THIS SERVICE DEVIATES FROM THE REPO
#
# 1. IT NEEDS SUDO, AND NOT ONLY TO INSTALL A PACKAGE. The RDP backend is a
#    *system* daemon (gnome-remote-desktop.service, already installed and
#    running on this box). Configuring it means `sudo grdctl --system`, a TLS
#    keypair under /var/lib/gnome-remote-desktop, and a packet-filter rule.
#    See AGENTS.md in this directory before "fixing" that.
#
#    Sudo is announced before every prompt and is needed only on drift: a
#    re-run against a working deployment asks for nothing.
#
# 2. THE RDP PORT IS WILDCARD-BOUND AND CANNOT BE CHANGED. Measured on this
#    box, not assumed:
#
#      - `grdctl rdp` has set-port and no bind-address subcommand;
#      - the entire org.gnome.desktop.remote-desktop.rdp GSettings schema is
#        {enable, negotiate-port, port, screen-share-mode, tls-cert, tls-key,
#        view-only} — there is no address key;
#      - /usr/libexec/gnome-remote-desktop-daemon imports exactly two GLib
#        listener helpers, g_socket_listener_add_inet_port and
#        g_socket_listener_add_any_inet_port. Neither takes an address; both
#        listen on ALL interfaces. g_socket_listener_add_address — the only
#        GLib call that binds one address — is not imported at all.
#
#    So there is no configuration, anywhere, that makes this listener
#    loopback-only. Once Remote Login is enabled, `ss -ltn` shows
#    0.0.0.0:3389 and [::]:3389, and without a filter both LAN addresses on
#    this box (192.168.88.x) would answer RDP.
#
#    That would break the repo's security model outright, so this script
#    installs a packet filter and verifies it BY BEHAVIOUR, before enabling
#    RDP: a dedicated nftables table (`inet remote_desktop`, its own systemd
#    unit, nothing else's ruleset touched) that accepts port 3389 only from
#    loopback and from the Guacamole bridge subnet, and answers everything
#    else with a TCP reset — indistinguishable from a closed port.
#
#    The socket-level check every other service in this repo uses ("is it
#    bound to 127.0.0.1?") is therefore the WRONG check here and will
#    correctly report 0.0.0.0. The right check is the one at the bottom of
#    this script: connect to the tailnet and LAN addresses and require a
#    refusal.
# ---------------------------------------------------------------------------
#
# Usage:
#   ./setup.sh                      # via `sg docker -c ./setup.sh` if needed
#   GUAC_PORT=9094 ./setup.sh       # first run only; .env wins after
#
# Requirements: Linux with GNOME (gnome-remote-desktop installed), Docker +
# Compose v2, Tailscale logged in, nftables, openssl, python3, curl, sudo.
#
# Rollback: see the bottom of SETUP.md. Short version:
#   sudo grdctl --system rdp disable && sudo systemctl restart gnome-remote-desktop
#   sudo systemctl disable --now remote-desktop-firewall.service
#   docker compose --project-directory <this dir> down
#   tailscale serve --https=8094 off

set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# 0700. Holds the RDP TLS private key on its way to /var/lib, and the probe
# helper. Removed on every exit path.
WORK="$(mktemp -d)"
chmod 700 "$WORK"
PKTTYAGENT_PID=""
cleanup() {
  [ -n "$PKTTYAGENT_PID" ] && kill "$PKTTYAGENT_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

sha256() {  # sha256 <file|-> -> bare hex digest
  openssl dgst -sha256 "$@" | sed 's/^.*= //'
}

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"

case "$OS" in
  Linux) ;;
  Darwin)
    die "macOS cannot host this service. remote-desktop publishes THIS machine's
     Linux desktop over RDP (gnome-remote-desktop) and puts a browser front
     end on it. A Mac has neither that daemon nor that desktop, and the Mac
     is the CLIENT here — open https://<server>.<tailnet>.ts.net:8094/ in a
     browser instead. There is nothing to install on this end." ;;
  *) die "Unsupported OS: $OS (Linux only for this service)." ;;
esac

[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root. This script escalates with sudo exactly where it must, and announces each escalation first."

for c in curl openssl python3 sudo systemctl; do
  have "$c" || die "$c is required but not installed."
done

have docker || die "Docker is not installed. On Ubuntu: sudo apt-get install -y docker.io docker-compose-v2"
docker ps >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER then log out/in, or run this script as: sg docker -c ./setup.sh"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."

have tailscale || die "Tailscale is not installed: https://tailscale.com/download"
ts_state="$(tailscale status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$ts_state" = "Running" ] || die "Tailscale is not up (state: ${ts_state:-unknown}). Run: sudo tailscale up"

# The RDP backend. Decided empirically (see the de-risk note in AGENTS.md):
# gnome-remote-desktop is already installed, enabled and running on this box
# at under a megabyte idle, so xrdp + a second desktop environment would cost
# ~400 MB to replace something that is already there.
have grdctl || die "gnome-remote-desktop is not installed (no grdctl), so there is no RDP backend to point Guacamole at.
     Fix (preferred, matches this deploy):  sudo apt-get install -y gnome-remote-desktop
     Fallback if GNOME's Remote Login will not work on this host: xrdp + XFCE,
     documented in TROUBLESHOOT.md. Do not run both."
systemctl list-unit-files gnome-remote-desktop.service >/dev/null 2>&1 \
  || die "gnome-remote-desktop.service is not present on this system, though grdctl is. Reinstall the package: sudo apt-get install --reinstall gnome-remote-desktop"
getent passwd gnome-remote-desktop >/dev/null \
  || die "The 'gnome-remote-desktop' system user is missing — the system daemon runs as that user and owns its TLS key. Reinstall: sudo apt-get install --reinstall gnome-remote-desktop"

# nftables is how the wildcard RDP listener is constrained (see the header).
# Without it this deploy cannot honour the repo's security model, so it is a
# hard requirement rather than a nice-to-have.
NFT=""
for p in /usr/sbin/nft /sbin/nft; do [ -x "$p" ] && NFT="$p" && break; done
[ -n "$NFT" ] || { have nft && NFT="$(command -v nft)"; }
[ -n "$NFT" ] || die "nftables (nft) is required. gnome-remote-desktop's RDP port is wildcard-bound with no way to
     restrict it in configuration, so a packet filter is the ONLY thing that keeps
     it off the LAN. Install it: sudo apt-get install -y nftables"

ok "Linux + Docker (daemon reachable) + Compose v2 + Tailscale (running) + gnome-remote-desktop + nftables"

TS_HOST="$(tailscale status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
[ -n "$TS_IP" ] || die "Could not determine this node's tailnet IPv4."
ok "Tailnet: $TS_HOST ($TS_IP)"

# ---------------------------------------------------------------- .env
GUAC_PORT="${GUAC_PORT:-8094}"

if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
else
  info "Writing .env (generated Guacamole password)"
  state_default="$HOME/services/remote-desktop"
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600. Read by both setup.sh and
# docker compose (which interpolates \${...} in docker-compose.yml from it).

# Guacamole, pinned. 1.6.0 is the release that fixed CVE-2024-35164; nothing
# at or below 1.5.5 is acceptable. Do not switch to :latest, and do not
# replace the images with a native build — 1.6.0 does not compile against the
# freerdp3-dev that current distros ship, and these images bundle FreeRDP 2.
GUACD_VERSION=1.6.0
GUACAMOLE_VERSION=1.6.0

# Webapp: loopback port, and the same number for the tailnet HTTPS front door.
GUAC_PORT=$GUAC_PORT

# State that is NOT in this repo: GUAC_HOME holds user-mapping.xml, which
# contains the RDP password in plaintext (Guacamole has no way to store it
# hashed — it has to replay it to the RDP server).
GUAC_STATE=$state_default
GUAC_HOME=$state_default/guac-home

# The webapp container runs as this uid:gid so it can read a 0600
# user-mapping.xml owned by you. The image's own user is uid 1001, which
# would force the file to be world-readable.
GUAC_UID=$(id -u)
GUAC_GID=$(id -g)

# Browser login. A Guacamole password is unavoidable — there is no supported
# anonymous mode — so this is auth BY NECESSITY, not auth as a substitute for
# the tailnet boundary. The tailnet is still the boundary that matters.
GUAC_USER=$USER
GUAC_PASSWORD=$(openssl rand -hex 16)

# The private bridge guacd and the webapp share, and the address guacd dials
# for RDP: that bridge's gateway, i.e. this host from inside the bridge. The
# packet filter installed by setup.sh allows port 3389 from this subnet and
# from loopback, and from nothing else — so these two values and
# /etc/remote-desktop/rdp-firewall.nft must always agree. Re-run setup.sh
# after changing them; it rewrites the filter.
#
# 172.17-172.27 are already taken by other services' bridges on this box.
GUAC_SUBNET=172.28.0.0/24
GUAC_RDP_HOST=172.28.0.1

# The RDP backend: gnome-remote-desktop's system daemon ("Remote Login").
RDP_PORT=3389
RDP_USER=$USER

# ⚠️ RDP_PASSWORD is left empty on purpose. setup.sh will prompt for it.
#
# GNOME's Remote Login hands the credentials you set here to GDM, which
# starts a real login session for RDP_USER — so in all likelihood this must
# be that user's actual SYSTEM LOGIN PASSWORD, not a generated string. That
# could not be verified without sudo when this was written; if a generated
# password works on your host, use one, and say so in SETUP.md.
#
# Whatever you put here is stored in this file AND, in plaintext, in
# \$GUAC_HOME/user-mapping.xml (both 0600, owner-only). If that is not an
# acceptable place for your login password, create a second account for
# remote sessions and point RDP_USER at it instead.
RDP_PASSWORD=
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# An existing .env is the source of truth: a re-run can never silently move a
# live deployment onto a different port or subnet.
REQUESTED_PORT="$GUAC_PORT"
# An RDP_PASSWORD exported into the environment wins over the (deliberately
# empty) placeholder in a freshly generated .env, so that this script can be
# driven non-interactively: `RDP_PASSWORD=... ./setup.sh`. Without this, the
# empty value in .env would clobber the exported one on the very first run and
# the only way in would be the TTY prompt below — which is unavailable to the
# test suite and to any automation. An existing .env still wins on a re-run,
# because that is the source of truth for a live deployment.
REQUESTED_RDP_PASSWORD="${RDP_PASSWORD:-}"
set -a; . "$ENV_FILE"; set +a
GUAC_PORT="${GUAC_PORT:?GUAC_PORT missing from $ENV_FILE}"
GUAC_STATE="${GUAC_STATE:?GUAC_STATE missing from $ENV_FILE}"
GUAC_HOME="${GUAC_HOME:?GUAC_HOME missing from $ENV_FILE}"
GUAC_USER="${GUAC_USER:?GUAC_USER missing from $ENV_FILE}"
GUAC_PASSWORD="${GUAC_PASSWORD:?GUAC_PASSWORD missing from $ENV_FILE}"
GUAC_SUBNET="${GUAC_SUBNET:?GUAC_SUBNET missing from $ENV_FILE}"
GUAC_RDP_HOST="${GUAC_RDP_HOST:?GUAC_RDP_HOST missing from $ENV_FILE}"
RDP_PORT="${RDP_PORT:?RDP_PORT missing from $ENV_FILE}"
RDP_USER="${RDP_USER:?RDP_USER missing from $ENV_FILE}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
# .env's value first; fall back to whatever was exported into the environment.
[ -n "$RDP_PASSWORD" ] || RDP_PASSWORD="$REQUESTED_RDP_PASSWORD"
[ "$GUAC_PORT" = "$REQUESTED_PORT" ] || warn "GUAC_PORT=$REQUESTED_PORT ignored — $ENV_FILE says $GUAC_PORT. Edit .env and re-run to move the port."
case "$GUAC_PORT" in ''|*[!0-9]*) die "GUAC_PORT must be numeric (got: $GUAC_PORT)";; esac
case "$RDP_PORT"  in ''|*[!0-9]*) die "RDP_PORT must be numeric (got: $RDP_PORT)";; esac

APPLIED="$GUAC_STATE/.applied"
mkdir -p "$GUAC_STATE" "$GUAC_HOME" "$APPLIED"
chmod 700 "$GUAC_STATE" "$GUAC_HOME" "$APPLIED"

getent passwd "$RDP_USER" >/dev/null || die "RDP_USER=$RDP_USER is not a user on this machine. GNOME's Remote Login starts a real login session for that account, so it has to exist."

# ------------------------------------------------------- the RDP password
# Persist a password that arrived via the environment, so the NEXT run finds it
# in .env and needs neither the variable nor the prompt. Without this, a
# non-interactive first run would leave .env empty and every later re-run would
# stop to prompt — i.e. it would not be idempotent.
if [ -n "$RDP_PASSWORD" ] && ! grep -q '^RDP_PASSWORD=.' "$ENV_FILE"; then
  # Temp file + mv, and not awk/sed: a password is arbitrary bytes and both
  # would eat backslashes.
  { grep -v '^RDP_PASSWORD=' "$ENV_FILE"; printf 'RDP_PASSWORD=%s\n' "$RDP_PASSWORD"; } > "$WORK/env.new"
  chmod 600 "$WORK/env.new"; mv "$WORK/env.new" "$ENV_FILE"
  ok "RDP password taken from the environment and recorded in $ENV_FILE"
fi

if [ -z "$RDP_PASSWORD" ]; then
  echo
  warn "RDP_PASSWORD is not set in $ENV_FILE."
  echo "    GNOME's Remote Login hands these credentials to GDM to start a real"
  echo "    login session as '$RDP_USER', so this is most likely that account's"
  echo "    SYSTEM LOGIN PASSWORD. It will be written to $ENV_FILE and to"
  echo "    $GUAC_HOME/user-mapping.xml (both 0600, owner-only)."
  echo "    Prefer not to? Ctrl-C, make a second account for remote sessions,"
  echo "    and set RDP_USER to it in .env."
  echo
  [ -t 0 ] || die "No terminal to prompt on. Set RDP_PASSWORD=... in $ENV_FILE and re-run."
  printf '    Password for %s: ' "$RDP_USER"; read -rs pw1; echo
  printf '    Again:            '; read -rs pw2; echo
  [ -n "$pw1" ] || die "Empty password. Nothing was changed."
  [ "$pw1" = "$pw2" ] || die "Passwords did not match. Nothing was changed."
  # Temp file + mv so a crash cannot leave a truncated .env. Deliberately not
  # awk/sed: a password is arbitrary bytes, and both would eat backslashes.
  { grep -v '^RDP_PASSWORD=' "$ENV_FILE"; printf 'RDP_PASSWORD=%s\n' "$pw1"; } > "$WORK/env.new"
  chmod 600 "$WORK/env.new"; mv "$WORK/env.new" "$ENV_FILE"
  RDP_PASSWORD="$pw1"; unset pw1 pw2
  ok "RDP password recorded in $ENV_FILE"
fi

# ---------------------------------------------------------------- probes
# Two checks that a listening socket cannot fake, used throughout below.
cat > "$WORK/probe.py" <<'PYEOF'
import socket, struct, sys

def tcp(host, port, timeout=4.0):
    """open | refused | filtered | error:<why>"""
    try:
        s = socket.create_connection((host, port), timeout)
        s.close()
        return "open"
    except ConnectionRefusedError:
        return "refused"
    except socket.timeout:
        return "filtered"
    except OSError as e:
        # EHOSTUNREACH/ENETUNREACH also mean "cannot get there from here".
        return "filtered" if e.errno in (113, 101, 111) else "error:%s" % e

def rdp(host, port, timeout=6.0):
    """Speak the first packet of the RDP handshake and require an RDP answer.

    X.224 Connection Request carrying an RDP Negotiation Request. A real RDP
    server replies with a TPKT-framed Connection Confirm; anything else on
    the port (an SSH banner, an HTTP server, a TCP proxy to nowhere) does
    not. This is what distinguishes 'the port is open' from 'RDP works'.
    """
    cookie = b"Cookie: mstshash=setup-server\r\n"
    # type=RDP_NEG_REQ, flags=0, length=8, requestedProtocols=TLS|CredSSP
    neg = struct.pack("<BBHI", 0x01, 0x00, 8, 0x00000003)
    body = b"\xe0\x00\x00\x00\x00\x00" + cookie + neg
    pdu = b"\x03\x00" + struct.pack(">H", 5 + len(body)) + bytes([len(body)]) + body
    try:
        s = socket.create_connection((host, port), timeout)
    except ConnectionRefusedError:
        return "refused"
    except Exception as e:
        return "error:%s" % e
    try:
        s.settimeout(timeout)
        s.sendall(pdu)
        data = s.recv(64)
    except Exception as e:
        return "error:%s" % e
    finally:
        s.close()
    if len(data) >= 6 and data[0] == 0x03 and data[1] == 0x00 and data[5] == 0xd0:
        return "rdp"
    if not data:
        return "no-answer"
    return "not-rdp"

print({"tcp": tcp, "rdp": rdp}[sys.argv[1]](sys.argv[2], int(sys.argv[3])))
PYEOF
probe() { python3 "$WORK/probe.py" "$@"; }

# Every address this host answers on that is NOT loopback and NOT a docker
# bridge (the bridges are allowed by design). The RDP port must refuse on all
# of them, and the deploy checks that rather than trusting the filter.
EXPOSED_ADDRS=""
if have ip; then
  EXPOSED_ADDRS="$(ip -o -4 addr show 2>/dev/null | awk '{print $2, $4}' \
    | grep -v '^lo ' | grep -v '^docker0 ' | grep -v '^br-' | grep -v '^veth' \
    | awk '{split($2,a,"/"); print a[1]}' | sort -u || true)"
fi
[ -n "$EXPOSED_ADDRS" ] || warn "Could not enumerate this host's non-loopback addresses; the exposure check below will be weaker than it should be."

# ============================================================ 1. THE FILTER
# Installed BEFORE RDP is enabled, so there is never a window in which 3389
# answers the LAN.
FW_RULES="/etc/remote-desktop/rdp-firewall.nft"
FW_UNIT="/etc/systemd/system/remote-desktop-firewall.service"

cat > "$WORK/rdp-firewall.nft" <<EOF
#!/usr/sbin/nft -f
#
# Managed by setup-server/remote-desktop/setup.sh — regenerated on re-run.
#
# gnome-remote-desktop binds RDP to the wildcard address and offers no way to
# change that (no grdctl subcommand, no GSettings key, and the daemon only
# imports GLib listener helpers that take no address). This table is the ONLY
# thing keeping port $RDP_PORT off this machine's LAN and tailnet addresses.
#
# It is a table of its own: docker's and ufw's rulesets are untouched, and a
# DROP or REJECT here wins regardless of what they allow.
#
# 'reject with tcp reset' rather than 'drop' on purpose: a reset is exactly
# what a closed port sends, so a scanner cannot tell RDP is running, and the
# deploy's own checks see a clean "connection refused" instead of a hang.

table inet remote_desktop
delete table inet remote_desktop

table inet remote_desktop {
	chain input {
		type filter hook input priority filter - 10; policy accept;

		# The host itself (Guacamole's health checks, native clients over
		# an SSH tunnel).
		tcp dport $RDP_PORT ip  saddr 127.0.0.0/8 accept
		tcp dport $RDP_PORT ip6 saddr ::1         accept

		# guacd, on the remote-desktop bridge. Nothing else on this box's
		# other docker bridges is in this subnet.
		tcp dport $RDP_PORT ip  saddr $GUAC_SUBNET accept

		# Everyone else: LAN, tailnet, anything routed here.
		tcp dport $RDP_PORT reject with tcp reset
		udp dport $RDP_PORT drop
	}
}
EOF

cat > "$WORK/remote-desktop-firewall.service" <<EOF
[Unit]
Description=remote-desktop: restrict RDP (tcp/$RDP_PORT) to loopback and the Guacamole bridge
Documentation=file://$SERVICE_DIR/SETUP.md
After=network-pre.target
Wants=network-pre.target
# The filter must exist before anything can listen on the port.
Before=gnome-remote-desktop.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f $FW_RULES
ExecReload=$NFT -f $FW_RULES
ExecStop=$NFT delete table inet remote_desktop

[Install]
WantedBy=multi-user.target
EOF

fw_current() {  # everything that must be true for the filter to need no sudo
  systemctl is-enabled --quiet remote-desktop-firewall.service 2>/dev/null &&
  systemctl is-active  --quiet remote-desktop-firewall.service 2>/dev/null &&
  cmp -s "$WORK/rdp-firewall.nft" "$FW_RULES" &&
  cmp -s "$WORK/remote-desktop-firewall.service" "$FW_UNIT"
}

if fw_current; then
  ok "RDP packet filter already installed and active (no sudo needed)"
else
  echo
  info "The RDP port needs a packet filter, and installing it needs sudo. Exactly what will change:"
  echo "     write  $FW_RULES   (0644 — accept tcp/$RDP_PORT from 127.0.0.0/8 and $GUAC_SUBNET, reject the rest)"
  echo "     write  $FW_UNIT"
  echo "     run    systemctl daemon-reload"
  echo "     run    systemctl enable --now remote-desktop-firewall.service"
  echo "   Nothing else on this machine is touched: this is a private nftables"
  echo "   table, not a change to docker's rules, and not 'ufw enable'."
  echo
  sudo install -d -m 0755 /etc/remote-desktop || die "Could not create /etc/remote-desktop."
  sudo install -m 0644 "$WORK/rdp-firewall.nft" "$FW_RULES" || die "Could not write $FW_RULES."
  sudo install -m 0644 "$WORK/remote-desktop-firewall.service" "$FW_UNIT" || die "Could not write $FW_UNIT."
  sudo systemctl daemon-reload || die "systemctl daemon-reload failed."
  sudo systemctl enable --now remote-desktop-firewall.service \
    || die "Could not start remote-desktop-firewall.service. Check: sudo nft -f $FW_RULES ; systemctl status remote-desktop-firewall
     RDP has NOT been enabled, so nothing is exposed — but nothing works yet either."
  systemctl is-active --quiet remote-desktop-firewall.service \
    || die "remote-desktop-firewall.service did not stay active. RDP was not enabled. journalctl -u remote-desktop-firewall"
  ok "RDP packet filter installed and active"
fi

# ============================================================ 2. TLS KEYPAIR
# gnome-remote-desktop will not start an RDP server without one, and the
# system daemon runs as the 'gnome-remote-desktop' user, so the key has to be
# readable by that user and by nobody else. A copy of the CERTIFICATE (public,
# harmless) is kept in $GUAC_STATE so re-runs can check its expiry without sudo.
CERT_DIR="/var/lib/gnome-remote-desktop/certificates"
CERT_PATH="$CERT_DIR/rdp-tls.crt"
KEY_PATH="$CERT_DIR/rdp-tls.key"
CERT_COPY="$GUAC_STATE/rdp-tls.crt"

cert_ok() {
  [ -f "$CERT_COPY" ] || return 1
  [ -f "$APPLIED/rdp-cert" ] || return 1
  # 30 days of slack: a cert that dies next week should be replaced during a
  # deploy, not during a support call.
  openssl x509 -in "$CERT_COPY" -noout -checkend 2592000 >/dev/null 2>&1
}

CERT_NEW=0
if cert_ok; then
  ok "RDP TLS certificate present and valid until $(openssl x509 -in "$CERT_COPY" -noout -enddate | cut -d= -f2)"
else
  info "Generating a self-signed RDP TLS certificate (2 years)"
  openssl req -new -newkey rsa:4096 -days 720 -nodes -x509 \
    -subj "/CN=$(hostname)/O=setup-server/OU=remote-desktop" \
    -keyout "$WORK/rdp-tls.key" -out "$WORK/rdp-tls.crt" >/dev/null 2>&1 \
    || die "openssl could not generate the RDP TLS keypair."
  chmod 600 "$WORK/rdp-tls.key"
  CERT_NEW=1
  ok "Keypair generated (self-signed: the client cannot verify it, which is why the Guacamole connection sets ignore-cert — the tailnet is the trust boundary, not this certificate)"
fi
if [ "$CERT_NEW" = "1" ]; then
  CERT_FPR="$(openssl x509 -in "$WORK/rdp-tls.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
else
  CERT_FPR="$(openssl x509 -in "$CERT_COPY" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)"
fi

# ============================================================ 3. THE BACKEND
# Drift is detected without sudo: a fingerprint of everything we would set,
# plus a real RDP handshake on loopback. If both agree, this whole block is
# skipped and the re-run needs no sudo at all.
WANT="$(printf '%s\n%s\n%s\n%s\n' "$RDP_USER" "$RDP_PASSWORD" "$RDP_PORT" "$CERT_FPR" | sha256)"
HAVE="$(cat "$APPLIED/rdp-config" 2>/dev/null || true)"

rdp_loopback_ok() { [ "$(probe rdp 127.0.0.1 "$RDP_PORT")" = "rdp" ]; }

if [ "$WANT" = "$HAVE" ] && [ "$CERT_NEW" = "0" ] && rdp_loopback_ok; then
  ok "gnome-remote-desktop already serving RDP on 127.0.0.1:$RDP_PORT with the configuration this script wants (no sudo needed)"
else
  echo
  info "Configuring gnome-remote-desktop's SYSTEM daemon. This needs sudo. Exactly what will change:"
  if [ "$CERT_NEW" = "1" ]; then
    echo "     install the new TLS keypair into $CERT_DIR (owner: gnome-remote-desktop, key 0600)"
  fi
  echo "     grdctl --system rdp set-tls-cert / set-tls-key   -> $CERT_DIR/rdp-tls.*"
  echo "     grdctl --system rdp set-port $RDP_PORT"
  echo "     grdctl --system rdp disable-port-negotiation      (so it cannot wander to another port the filter does not cover)"
  echo "     grdctl --system rdp disable-view-only             (the schema default is view-only=true)"
  echo "     grdctl --system rdp set-credentials $RDP_USER <password>"
  echo "     grdctl --system rdp enable"
  echo "     systemctl enable --now / restart gnome-remote-desktop.service"
  echo
  warn "The password is passed to grdctl as an argument, so it will appear in sudo's"
  echo "   audit log (/var/log/auth.log, root-only) and briefly in 'ps'. grdctl offers"
  echo "   no other way to set it. See AGENTS.md."
  echo "   GDM, the graphical session and the desktop you are using are NOT touched."
  echo

  # A text-mode polkit agent, if one is available: grdctl --system goes
  # through polkit (org.gnome.remotedesktop.configure-system-daemon,
  # allow_active=auth_admin_keep) and can fail with "Authorization not
  # available" when nothing can prompt. Harmless if it turns out to be
  # unnecessary; killed by the EXIT trap.
  if have pkttyagent && [ -t 0 ]; then
    pkttyagent --process $$ >/dev/null 2>&1 & PKTTYAGENT_PID=$!
    sleep 1
  fi

  grd() {  # grd <subcommand...> — announce nothing, fail loudly
    sudo grdctl --system rdp "$@" || die "\`sudo grdctl --system rdp $1 ...\` failed.

     If it said 'Authorization not available' or 'Authentication is required',
     that is polkit with nowhere to ask. Retry from a terminal with an agent:
         pkttyagent --process \$\$ &   # then re-run ./setup.sh
     or run the grdctl commands listed above yourself from a graphical session.

     If it failed some other way, gnome-remote-desktop's Remote Login may not
     work on this host at all. The documented fallback is xrdp + XFCE — see
     TROUBLESHOOT.md. Do not leave both configured.

     Nothing has been enabled; the packet filter is in place either way."
  }

  if [ "$CERT_NEW" = "1" ]; then
    sudo install -d -o gnome-remote-desktop -g gnome-remote-desktop -m 0700 "$CERT_DIR" \
      || die "Could not create $CERT_DIR."
    sudo install -o gnome-remote-desktop -g gnome-remote-desktop -m 0644 "$WORK/rdp-tls.crt" "$CERT_PATH" \
      || die "Could not install the RDP certificate."
    sudo install -o gnome-remote-desktop -g gnome-remote-desktop -m 0600 "$WORK/rdp-tls.key" "$KEY_PATH" \
      || die "Could not install the RDP private key."
    install -m 0644 "$WORK/rdp-tls.crt" "$CERT_COPY"
    printf '%s\n' "$CERT_FPR" > "$APPLIED/rdp-cert"
    ok "TLS keypair installed for the gnome-remote-desktop user"
  fi

  grd set-tls-cert "$CERT_PATH"
  grd set-tls-key  "$KEY_PATH"
  grd set-port     "$RDP_PORT"
  grd disable-port-negotiation
  grd disable-view-only
  grd set-credentials "$RDP_USER" "$RDP_PASSWORD"
  grd enable
  ok "grdctl --system applied"

  systemctl is-enabled --quiet gnome-remote-desktop.service 2>/dev/null \
    || sudo systemctl enable gnome-remote-desktop.service \
    || die "Could not enable gnome-remote-desktop.service."
  # Restarted, not reloaded: the system daemon reads its RDP settings at
  # startup. Only ever reached on drift, so a live remote session is not cut
  # off by a no-op re-run.
  sudo systemctl restart gnome-remote-desktop.service \
    || die "Could not restart gnome-remote-desktop.service. journalctl -u gnome-remote-desktop -n 50"

  info "Waiting for the RDP handshake on 127.0.0.1:$RDP_PORT"
  rdp_state=""
  for _ in $(seq 1 20); do
    rdp_state="$(probe rdp 127.0.0.1 "$RDP_PORT")"
    [ "$rdp_state" = "rdp" ] && break
    sleep 2
  done
  [ "$rdp_state" = "rdp" ] || die "gnome-remote-desktop is not speaking RDP on 127.0.0.1:$RDP_PORT after 40s (probe said: $rdp_state).

     This is the step the de-risk work could not test without sudo, so treat it
     as the real unknown it is. Read: journalctl -u gnome-remote-desktop -n 80
     Common causes: the TLS key is unreadable by the gnome-remote-desktop user;
     GDM is not running; this build's Remote Login needs a graphical target it
     does not have.
     If it cannot be made to work, the documented fallback is xrdp + XFCE —
     see TROUBLESHOOT.md — and you should first undo this one:
         sudo grdctl --system rdp disable && sudo systemctl restart gnome-remote-desktop

     Nothing is exposed meanwhile: the packet filter is installed and active."

  printf '%s' "$WANT" > "$APPLIED/rdp-config"; chmod 600 "$APPLIED/rdp-config"
  ok "gnome-remote-desktop is serving RDP on 127.0.0.1:$RDP_PORT"
fi

# ================================================= 4. GUACAMOLE CONFIG
# Written only if absent — this is a file the user may reasonably edit (extra
# connections, tuned RDP parameters). Drift is reported, never overwritten.
GUAC_HASH="$(printf '%s' "$GUAC_PASSWORD" | sha256)"
UM="$GUAC_HOME/user-mapping.xml"

if [ -f "$UM" ]; then
  if grep -q "$GUAC_HASH" "$UM" 2>/dev/null; then
    ok "user-mapping.xml already present and matches GUAC_PASSWORD"
  else
    warn "$UM does not match GUAC_PASSWORD in $ENV_FILE — leaving your file alone."
    echo "   Either the password was rotated in .env, or you edited the XML."
    echo "   To regenerate from .env:  rm $UM && ./setup.sh"
  fi
else
  info "Writing user-mapping.xml (file authentication — no database)"
  cat > "$UM" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Guacamole file authentication. Written once by setup.sh; yours to edit.
  setup.sh will not overwrite it — it only warns when the password no longer
  matches .env.

  ⚠️ The <param name="password"> below is the RDP password IN PLAINTEXT.
  Guacamole has to replay it to the RDP server, so it cannot be hashed. This
  file is 0600 and the directory is 0700; the webapp container runs as your
  uid so it can still read it. Keep it that way.

  The browser-login password above it IS hashed (sha256, no salt — that is
  all guacamole-auth-file supports).
-->
<user-mapping>
    <authorize username="$GUAC_USER" password="$GUAC_HASH" encoding="sha256">
        <connection name="$(hostname) desktop">
            <protocol>rdp</protocol>

            <!-- The remote-desktop bridge gateway: this host, seen from
                 inside the bridge. Not the LAN, not the tailnet. -->
            <param name="hostname">$GUAC_RDP_HOST</param>
            <param name="port">$RDP_PORT</param>

            <param name="username">$RDP_USER</param>
            <param name="password">$RDP_PASSWORD</param>

            <!-- gnome-remote-desktop accepts NLA and NOTHING ELSE. Measured on
                 the first real session, 2026-09-12: with 'tls' the daemon
                 logged "server supports only NLA Security" and guacd logged
                 "Security negotiation failed (wrong security type?)", and
                 Guacamole rendered that as "Log in failed" -- before the
                 credentials were ever examined. NLA carries the credentials
                 inside the security handshake, which is exactly why grdctl
                 has set-credentials. 'any' would also negotiate to NLA; 'nla'
                 is the precise value. ignore-cert because the certificate is
                 self-signed by setup.sh; the tailnet is the trust boundary. -->
            <param name="security">nla</param>
            <param name="ignore-cert">true</param>

            <!-- Audio OFF, and not merely as a bandwidth choice. guacd
                 ships FreeRDP 2.11.7, whose AUDIO_PLAYBACK protocol is
                 version 6; gnome-remote-desktop's newer server rejects it
                 with "Client protocol version (6) too old. Terminating
                 protocol" and tears the channel down mid-session. Measured
                 on the first real session, 2026-09-12. Leave this true
                 until guacd ships FreeRDP 3.x. -->
            <param name="disable-audio">true</param>

            <!-- Resize the remote desktop to the browser window. -->
            <param name="resize-method">display-update</param>

            <!-- Bandwidth. Turn back on if you want the wallpaper. -->
            <param name="enable-wallpaper">false</param>
            <param name="enable-theming">true</param>
            <param name="enable-font-smoothing">true</param>

            <!-- NOT enabled: drive redirection (enable-drive). Guacamole
                 supports it, gnome-remote-desktop does not implement the
                 rdpdr channel, so it would be a switch that does nothing.
                 Move files with Seafile, code-server or scp instead.
                 Session recording is off on purpose: disk with no backup
                 job behind it. -->
        </connection>
    </authorize>
</user-mapping>
EOF
  chmod 600 "$UM"
  ok "Wrote $UM (0600)"
fi

# ================================================= 5. THE CONTAINERS
COMPOSE=(docker compose --project-directory "$SERVICE_DIR")

info "Fetching images (first run pulls ~1.5 GB)"
"${COMPOSE[@]}" pull 2>&1 | tail -3 || warn "docker compose pull failed — continuing with whatever is cached locally."

info "Starting guacd + guacamole (docker compose up -d)"
if ! "${COMPOSE[@]}" up -d 2>"$WORK/up.err"; then
  cat "$WORK/up.err" >&2
  case "$(cat "$WORK/up.err" 2>/dev/null || true)" in
    *"Pool overlaps"*|*"overlaps with other one"*)
      die "The pinned bridge subnet $GUAC_SUBNET collides with an existing docker network.
     Pick a free one (172.17-172.27 are taken on this box), then set BOTH
     GUAC_SUBNET and GUAC_RDP_HOST (its .1 gateway) in $ENV_FILE and re-run —
     the packet filter is rewritten from those values." ;;
    *"address already in use"*|*"port is already allocated"*)
      die "127.0.0.1:$GUAC_PORT is already taken. Check: ss -ltn | grep :$GUAC_PORT" ;;
    *) die "docker compose up failed. Logs: ${COMPOSE[*]} logs" ;;
  esac
fi

BASE="http://127.0.0.1:$GUAC_PORT/guacamole"
info "Waiting for the Guacamole webapp on $BASE/ (Tomcat takes ~20s to deploy the war)"
code=""
for _ in $(seq 1 45); do
  code="$(curl -sS -o "$WORK/login.html" -w '%{http_code}' --max-time 10 "$BASE/" 2>/dev/null || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || die "The webapp never answered on $BASE/ (last HTTP ${code:-000}). Logs: ${COMPOSE[*]} logs guacamole"

# ================================================= 6. PUBLISH
# Note the /guacamole path on the target: the webapp is deployed under that
# context path, so serving http://127.0.0.1:$GUAC_PORT alone would put a 404
# at the front door. Verified: Tailscale rewrites the prefix, so the tailnet
# URL is a clean https://host:PORT/ .
info "Publishing via Tailscale Serve (HTTPS :$GUAC_PORT, tailnet only)"
if ! tailscale serve --bg --https="$GUAC_PORT" "$BASE/" >/dev/null 2>&1; then
  info "Direct serve failed — trying the operator grant (needs sudo, one time)"
  sudo tailscale set --operator="$USER" || true
  until tailscale serve --bg --https="$GUAC_PORT" "$BASE/"; do
    echo
    info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
    read -r
  done
fi
ok "Tailscale Serve: HTTPS :$GUAC_PORT -> $BASE/"

# ============================================================== VERIFY
# Everything above can succeed against a deployment that cannot open a single
# session, or one that is answering the whole LAN. These are the checks that
# would notice.
FAILED=0
fail() { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; FAILED=1; }

echo
info "Verifying the deploy"

# --- containers ------------------------------------------------------------
for c in guacd guacamole; do
  st="$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || true)"
  [ "$st" = "running" ] && ok "Container '$c' is running" \
                        || fail "Container '$c' is '${st:-missing}'. Logs: ${COMPOSE[*]} logs $c"
done

# --- the login page is really Guacamole ------------------------------------
# A 200 is not enough: Tomcat's own error pages, a stale proxy and a default
# war all return 200. Require the AngularJS bootstrap the Guacamole client
# actually ships.
if grep -q 'ng-app="index"' "$WORK/login.html" && grep -q 'indexController' "$WORK/login.html"; then
  ok "Webapp on 127.0.0.1:$GUAC_PORT is serving the Guacamole client"
else
  fail "127.0.0.1:$GUAC_PORT answered 200 but the body is not the Guacamole client. Logs: ${COMPOSE[*]} logs guacamole"
fi

# --- the generated password actually logs in, and sees the connection ------
if curl -sS -o "$WORK/token.json" -w '' --max-time 15 \
      --data-urlencode "username=$GUAC_USER" --data-urlencode "password=$GUAC_PASSWORD" \
      "$BASE/api/tokens" 2>/dev/null && grep -q '"authToken"' "$WORK/token.json"; then
  ok "Browser login as '$GUAC_USER' works (file authentication is live)"
  TOKEN="$(sed -n 's/.*"authToken":"\([^"]*\)".*/\1/p' "$WORK/token.json")"
  if curl -sS --max-time 15 "$BASE/api/session/data/default/connections?token=$TOKEN" 2>/dev/null | grep -q '"protocol":"rdp"'; then
    ok "The RDP connection is present in the connection list"
  else
    fail "Logged in, but no RDP connection is visible — check $UM."
  fi
else
  fail "Login as '$GUAC_USER' was rejected. GUAC_PASSWORD in $ENV_FILE does not match the hash in $UM. Fix: rm $UM && ./setup.sh
     (Guacamole bans an address for 300s after 5 failed attempts — do not retry in a loop.)"
fi

# --- RDP: reachable where it must be, refused everywhere else --------------
if [ "$(probe rdp 127.0.0.1 "$RDP_PORT")" = "rdp" ]; then
  ok "RDP answers a real handshake on 127.0.0.1:$RDP_PORT"
else
  fail "RDP is not answering on 127.0.0.1:$RDP_PORT. journalctl -u gnome-remote-desktop -n 50"
fi

if [ "$(probe rdp "$GUAC_RDP_HOST" "$RDP_PORT")" = "rdp" ]; then
  ok "RDP answers on the bridge gateway $GUAC_RDP_HOST:$RDP_PORT (the address guacd dials)"
else
  fail "RDP does not answer on $GUAC_RDP_HOST:$RDP_PORT — guacd will not be able to connect. Is $GUAC_SUBNET allowed in $FW_RULES, and does GUAC_RDP_HOST match that subnet's .1 gateway?"
fi

# And the same question asked from where it actually matters: inside a
# container on the bridge, through the filter, the way guacd will ask it.
# bash's /dev/tcp, so it needs nothing installed in the image.
if docker exec guacamole bash -c "exec 3<>/dev/tcp/$GUAC_RDP_HOST/$RDP_PORT" >/dev/null 2>&1; then
  ok "A container on the remote-desktop bridge can open $GUAC_RDP_HOST:$RDP_PORT"
else
  fail "A container on the remote-desktop bridge CANNOT reach $GUAC_RDP_HOST:$RDP_PORT, so no session will ever start. Check the accept rule for $GUAC_SUBNET in $FW_RULES."
fi

# THE check for this service. 3389 is wildcard-bound and cannot be made
# otherwise, so 'is it bound to 127.0.0.1' is meaningless here — what matters
# is whether anything answers on the addresses other machines can reach.
for addr in $EXPOSED_ADDRS; do
  r="$(probe tcp "$addr" "$RDP_PORT")"
  case "$r" in
    refused|filtered) ok "RDP refuses connections on $addr:$RDP_PORT ($r)" ;;
    open) fail "RDP is REACHABLE on $addr:$RDP_PORT. The packet filter is not doing its job, and this box's desktop is exposed to everything that can route to that address. Check: systemctl status remote-desktop-firewall; sudo nft list table inet remote_desktop" ;;
    *) fail "Could not determine whether $addr:$RDP_PORT is reachable ($r)." ;;
  esac
  r="$(probe tcp "$addr" "$GUAC_PORT")"
  case "$r" in
    refused|filtered) ok "Webapp refuses connections on $addr:$GUAC_PORT ($r)" ;;
    open) fail "The webapp is REACHABLE on $addr:$GUAC_PORT — it should be published on 127.0.0.1 only. Check the ports: block in $SERVICE_DIR/docker-compose.yml" ;;
    *) fail "Could not determine whether $addr:$GUAC_PORT is reachable ($r)." ;;
  esac
done

# guacd speaks an unauthenticated protocol; it must not be on the host at all.
# Asked as a connection rather than by reading `ss`, so it needs no GNU-only
# tool and cannot be fooled by a mapping that ss renders unexpectedly.
if [ "$(probe tcp 127.0.0.1 4822)" = "open" ]; then
  fail "Something is answering on the host's 127.0.0.1:4822. guacd must stay container-internal — anything that reaches it can open an RDP session to anywhere it can route, with no credentials. Check the compose file for a published 4822."
else
  ok "guacd's port 4822 is not published to the host"
fi

# --- the tailnet front door ------------------------------------------------
URL="https://$TS_HOST:$GUAC_PORT"
tailscale serve status 2>/dev/null | grep -q ":$GUAC_PORT" \
  && ok "tailscale serve shows the :$GUAC_PORT mount" \
  || fail "tailscale serve status does not show a :$GUAC_PORT mount."

info "Checking $URL/ (the first request can take ~60s while the TLS cert is minted)"
https_body="$WORK/https.html"
https_code=""
for _ in 1 2 3 4 5; do
  https_code="$(curl -sS -o "$https_body" -w '%{http_code}' --max-time 90 "$URL/" 2>/dev/null || true)"
  [ "$https_code" = "200" ] && break
  sleep 3
done
if [ "$https_code" = "200" ] && grep -q 'ng-app="index"' "$https_body"; then
  ok "End-to-end: $URL/ serves the Guacamole client over the tailnet"
elif [ "$https_code" = "200" ]; then
  fail "$URL/ returned 200 but not the Guacamole client — is the serve target the /guacamole path?"
else
  warn "No answer yet on $URL/ (HTTP ${https_code:-000}) — the cert may still be minting. Retry: curl -o /dev/null -w '%{http_code}\\n' $URL/"
fi

# ============================================================== SUMMARY
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mDone.\033[0m Your desktop is at \033[1m%s/\033[0m (tailnet only).\n' "$URL"
else
  printf '\033[1;31mDeploy finished with failures.\033[0m Read the ✗ lines above before trusting this.\n'
fi
echo
echo "  Browser login: $GUAC_USER  /  see GUAC_PASSWORD in $ENV_FILE"
echo "  Then click the '$(hostname) desktop' connection. Ctrl+Alt+Shift opens"
echo "  Guacamole's side panel (clipboard, zoom, keyboard)."
echo
echo "  RDP:      127.0.0.1:$RDP_PORT and $GUAC_RDP_HOST:$RDP_PORT only."
echo "            The listener itself is on 0.0.0.0 — gnome-remote-desktop"
echo "            offers no way to change that — so $FW_RULES"
echo "            is what keeps it off the LAN and the tailnet. If you ever"
echo "            disable remote-desktop-firewall.service, this box's desktop"
echo "            is exposed to your whole LAN."
echo "  No file transfer: gnome-remote-desktop does not implement drive"
echo "            redirection. Clipboard works. Use Seafile or code-server for files."
echo
echo "  RAM:      measured idle ~175 MB for the two containers (webapp ~164,"
echo "            guacd ~11). A CONNECTED GNOME session is the expensive part"
echo "            and is only paid while a browser tab is open."
echo "  Stop it:  ${COMPOSE[*]} down     (the desktop keeps working; only the"
echo "            browser front end goes away)"
echo "  Manage:   ${COMPOSE[*]} ps|logs|restart"
echo "  Rollback: see SETUP.md"
echo

[ "$FAILED" = "0" ] || exit 1
exit 0
