#!/usr/bin/env bash
#
# setup.sh — one-shot deploy of Paperclip behind Tailscale. Linux + macOS.
#
# End state:
#   - Paperclip (official managed CLI + background service) on
#     127.0.0.1:PAPERCLIP_PORT, authenticated/private — never local_trusted
#     once published — reachable tailnet-only at
#     https://<host>.<tailnet>.ts.net:PAPERCLIP_HTTPS_PORT
#   - ~/agent-workspaces/paperclip-test is the scratch cwd for claude_local
#     / codex_local
#   - existing Claude / Codex credentials are never written or replaced
#
# Usage:
#   ./setup.sh
#   PAPERCLIP_PORT=3101 ./setup.sh
#
# Requirements: Linux or macOS, curl, Node.js >= 24.11, Tailscale logged in.
# Sudo is needed at most twice on Linux (lingering, tailscale operator),
# never on macOS. Docker is not required.
#
# Idempotent: safe to re-run; upgrades/repairs. An existing .env is never
# overwritten. Paperclip's onboard preserves an existing instance config;
# we only rewrite the bind/mode pair when it would otherwise publish a
# local_trusted instance or leave the official tailnet bind (which Serve
# cannot front) in place.

set -euo pipefail

PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
PAPERCLIP_HTTPS_EXPLICIT="${PAPERCLIP_HTTPS_PORT:+yes}"
PAPERCLIP_HTTPS_PORT="${PAPERCLIP_HTTPS_PORT:-$PAPERCLIP_PORT}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
MARKER="$HOME/services/paperclip"
LEGACY_DIR="$(cd "$SERVICE_DIR/.." && pwd)/paperclip-openhands"
LEGACY_MARKER="$HOME/services/paperclip-openhands"
# Official Paperclip instance root. The managed CLI and `service` commands
# do not take --data-dir (only onboard/doctor/auth do), so we stay on the
# documented default rather than splitting the instance from the supervisor.
PAPERCLIP_DATA="${PAPERCLIP_DATA:-$HOME/.paperclip}"
WORKSPACES="${AGENT_WORKSPACES:-$HOME/agent-workspaces}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copy selected KEY=value lines from a legacy combined .env without
# rotating secrets. Missing keys are left for the caller to generate.
env_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | head -1
}

append_kv() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    return 0
  fi
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

# Login fields for the launcher / later wiring. Placeholders until you
# set real values (Settings → Profile, then mirror them here).
PAPERCLIP_EMAIL="${PAPERCLIP_EMAIL:-changeme@example.com}"
PAPERCLIP_PASSWORD="${PAPERCLIP_PASSWORD:-changeme}"

# Compare dotted versions: node_at_least 24.11.0
node_at_least() {
  local have want
  have="$(node --version 2>/dev/null | sed 's/^v//')"
  want="$1"
  [ -n "$have" ] || return 1
  python3 -c '
import sys
def parts(s):
    out = []
    for bit in s.split("."):
        n = ""
        for ch in bit:
            if ch.isdigit():
                n += ch
            else:
                break
        out.append(int(n or 0))
    return out
have, want = parts(sys.argv[1]), parts(sys.argv[2])
print("ok" if have >= want else "no")
' "$have" "$want" | grep -qx ok
}

pc() {
  # Flags that isolate state (--data-dir) are per-subcommand on this CLI,
  # and `service` does not accept them at all. Stay on the official
  # ~/.paperclip instance so onboard and the supervisor share one tree.
  PAPERCLIP_NO_BROWSER=1 "$PAPERCLIPAI" "$@"
}

find_paperclip_config() {
  local p
  for p in \
    "$PAPERCLIP_DATA/instances/default/config.json" \
    "$PAPERCLIP_DATA/config.json" \
    "$HOME/.paperclip/instances/default/config.json"
  do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- preflight
OS="$(uname -s)"
info "Preflight checks ($OS)"
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required (JSON patch + version compare)."
[ "$OS" = "Linux" ] && { command -v systemctl >/dev/null || die "systemd is required on Linux."; }

if command -v tailscale >/dev/null; then
  TAILSCALE="tailscale"
elif [ "$OS" = "Darwin" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  die "Tailscale is not installed: https://tailscale.com/download"
fi

state="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[ "$state" = "Running" ] || die "Tailscale is not up (state: ${state:-unknown}). Run: sudo tailscale up (or open the Tailscale app)"

case "$PAPERCLIP_PORT" in ''|*[!0-9]*) die "PAPERCLIP_PORT must be numeric (got: $PAPERCLIP_PORT)";; esac
case "$PAPERCLIP_HTTPS_PORT" in ''|*[!0-9]*) die "PAPERCLIP_HTTPS_PORT must be numeric (got: $PAPERCLIP_HTTPS_PORT)";; esac

if ! command -v node >/dev/null; then
  die "Node.js >= 24.11.0 is required for Paperclip (official managed install). Install it user-locally and re-run."
fi
if ! node_at_least "24.11.0"; then
  die "Paperclip requires Node.js 24.11.0+ (found $(node --version)). Upgrade node and re-run; do not use an npx fallback on 22/23 — that is unsupported."
fi

ok "$OS + curl + python3 + Node $(node --version) + Tailscale (running)"

TS_HOST="$("$TAILSCALE" status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[ -n "$TS_HOST" ] || die "Could not determine tailnet DNS name (is MagicDNS enabled?)"
ok "Tailnet name: $TS_HOST"

# --------------------------------------------- inspect existing harnesses
# Report only. Never write ~/.claude, ~/.codex, or their auth files.
info "Inspecting existing Claude / Codex installations (read-only)"
CLAUDE_BIN=""
CODEX_BIN=""
if command -v claude >/dev/null 2>&1; then
  CLAUDE_BIN="$(command -v claude)"
  ok "Claude CLI present: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo unknown))"
else
  warn "Claude CLI not on PATH — Paperclip's claude_local agent will not run until it is."
fi
if command -v codex >/dev/null 2>&1; then
  CODEX_BIN="$(command -v codex)"
  ok "Codex CLI present: $CODEX_BIN ($("$CODEX_BIN" --version 2>/dev/null | head -1 || echo unknown))"
else
  warn "Codex CLI not on PATH — Paperclip's codex_local agent will not run until it is installed. Existing Codex config (if any) is left alone."
fi
if [ -e "$HOME/.claude" ]; then
  ok "Existing ~/.claude left untouched"
fi
if [ -e "$HOME/.codex" ]; then
  ok "Existing ~/.codex left untouched (Paperclip pins each agent to its own CODEX_HOME)"
fi

# ---------------------------------------------------------------- .env
if [ -f "$ENV_FILE" ]; then
  ok "Config already exists, leaving untouched: $ENV_FILE"
elif [ -f "$LEGACY_DIR/.env" ]; then
  info "Migrating Paperclip keys from paperclip-openhands/.env (not rotating)"
  tz="$(env_get "$LEGACY_DIR/.env" TZ)"
  [ -n "$tz" ] || tz="Etc/UTC"
  migrated_port="$(env_get "$LEGACY_DIR/.env" PAPERCLIP_PORT)"
  [ -n "$migrated_port" ] || migrated_port="$PAPERCLIP_PORT"
  migrated_data="$(env_get "$LEGACY_DIR/.env" PAPERCLIP_DATA)"
  [ -n "$migrated_data" ] || migrated_data="$PAPERCLIP_DATA"
  migrated_ws="$(env_get "$LEGACY_DIR/.env" AGENT_WORKSPACES)"
  [ -n "$migrated_ws" ] || migrated_ws="$WORKSPACES"
  migrated_host="$(env_get "$LEGACY_DIR/.env" TS_HOST)"
  [ -n "$migrated_host" ] || migrated_host="$TS_HOST"
  migrated_url="$(env_get "$LEGACY_DIR/.env" PAPERCLIP_PUBLIC_URL)"
  [ -n "$migrated_url" ] || migrated_url="https://$migrated_host:$PAPERCLIP_HTTPS_PORT"
  {
    echo "# Generated by setup.sh. Gitignored; mode 600."
    echo "# Migrated from paperclip-openhands/.env — secrets were not rotated."
    echo
    echo "PAPERCLIP_PORT=$migrated_port"
    echo "TZ=$tz"
    echo
    echo "AGENT_WORKSPACES=$migrated_ws"
    echo "PAPERCLIP_DATA=$migrated_data"
    echo
    echo "TS_HOST=$migrated_host"
    echo "PAPERCLIP_PUBLIC_URL=$migrated_url"
    echo
    echo "# Placeholders — not applied to the instance yet. Edit in place."
    echo "PAPERCLIP_EMAIL=${PAPERCLIP_EMAIL}"
    echo "PAPERCLIP_PASSWORD=${PAPERCLIP_PASSWORD}"
    company="$(env_get "$LEGACY_DIR/.env" PAPERCLIP_COMPANY_ID)"
    apikey="$(env_get "$LEGACY_DIR/.env" PAPERCLIP_API_KEY)"
    if [ -n "$company" ]; then
      echo "PAPERCLIP_COMPANY_ID=$company"
    fi
    if [ -n "$apikey" ]; then
      echo "PAPERCLIP_API_KEY=$apikey"
    fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE from the combined-service .env"
else
  info "Writing .env (ports + paths)"
  tz="Etc/UTC"
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  fi
  cat > "$ENV_FILE" <<EOF
# Generated by setup.sh. Gitignored; mode 600.
# Paperclip secrets live under PAPERCLIP_DATA (official instance dir).

PAPERCLIP_PORT=$PAPERCLIP_PORT
TZ=$tz

AGENT_WORKSPACES=$WORKSPACES
PAPERCLIP_DATA=$PAPERCLIP_DATA

# Public identity. The UI and auth redirects use this.
TS_HOST=$TS_HOST
PAPERCLIP_PUBLIC_URL=https://$TS_HOST:$PAPERCLIP_HTTPS_PORT

# Placeholders — not applied to the instance yet. Edit in place.
PAPERCLIP_EMAIL=$PAPERCLIP_EMAIL
PAPERCLIP_PASSWORD=$PAPERCLIP_PASSWORD
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
fi

# Existing .env is never overwritten; missing login keys are appended.
append_kv "$ENV_FILE" "PAPERCLIP_EMAIL" "$PAPERCLIP_EMAIL"
append_kv "$ENV_FILE" "PAPERCLIP_PASSWORD" "$PAPERCLIP_PASSWORD"

REQUESTED_PC_PORT="$PAPERCLIP_PORT"
set -a; . "$ENV_FILE"; set +a
PAPERCLIP_DATA="${PAPERCLIP_DATA:?PAPERCLIP_DATA missing from $ENV_FILE}"
WORKSPACES="${AGENT_WORKSPACES:?AGENT_WORKSPACES missing from $ENV_FILE}"
if [ "$PAPERCLIP_PORT" != "$REQUESTED_PC_PORT" ]; then
  warn "PAPERCLIP_PORT=$REQUESTED_PC_PORT ignored — the existing $ENV_FILE says $PAPERCLIP_PORT. Edit .env and re-run to move the port."
fi
[ -n "$PAPERCLIP_HTTPS_EXPLICIT" ] || PAPERCLIP_HTTPS_PORT="$PAPERCLIP_PORT"

mkdir -p "$MARKER" "$PAPERCLIP_DATA" "$WORKSPACES/paperclip-test"
chmod 700 "$MARKER" "$PAPERCLIP_DATA" 2>/dev/null || true

# Combined-service marker lived at ~/services/paperclip-openhands. Copy
# the CEO invite and agent markers once; leave the old dir in place.
if [ -d "$LEGACY_MARKER" ]; then
  for f in ceo-invite.txt .ceo-bootstrapped .agent-claude-local .agent-codex-local; do
    if [ -e "$LEGACY_MARKER/$f" ] && [ ! -e "$MARKER/$f" ]; then
      cp -a "$LEGACY_MARKER/$f" "$MARKER/"
    fi
  done
  ok "Migrated Paperclip markers from $LEGACY_MARKER"
fi

if [ ! -f "$WORKSPACES/paperclip-test/README.md" ]; then
  cat > "$WORKSPACES/paperclip-test/README.md" <<'EOF'
# paperclip-test

Scratch workspace for the Paperclip `claude_local` / `codex_local` agents.
Safe to edit. Created by services/paperclip/setup.sh.
EOF
fi
ok "Workspace: $WORKSPACES/paperclip-test"

# ---------------------------------------------------------- Paperclip CLI
export PATH="$HOME/.local/bin:$PATH"
if [ -x "$HOME/.local/bin/paperclipai" ]; then
  PAPERCLIPAI="$HOME/.local/bin/paperclipai"
  ok "Paperclip managed CLI already at $PAPERCLIPAI"
elif command -v paperclipai >/dev/null; then
  PAPERCLIPAI="$(command -v paperclipai)"
  ok "Paperclip CLI already on PATH: $PAPERCLIPAI"
else
  info "Installing Paperclip managed CLI (official, user-local, no sudo)"
  npx paperclipai install --yes
  PAPERCLIPAI="$HOME/.local/bin/paperclipai"
  [ -x "$PAPERCLIPAI" ] || die "paperclipai install did not produce $PAPERCLIPAI"
  ok "Installed $PAPERCLIPAI"
fi

# Official non-interactive authenticated path is --bind tailnet (loopback
# + --yes would force local_trusted, which we must not publish).
#
# `--yes` also starts a foreground `paperclipai run` and never returns —
# measured against paperclipai 2026.831.1. We only want the config file;
# the official service manager is what keeps it up. So: skip onboard when
# a config already exists, otherwise start it in the background, wait for
# config.json, then stop that foreground server.
export PAPERCLIP_NO_BROWSER=1
CFG="$(find_paperclip_config || true)"
if [ -n "$CFG" ]; then
  ok "Paperclip already onboarded, leaving config for the bind repair step"
else
  info "Onboarding Paperclip (authenticated / private, official --bind tailnet)"
  pc onboard --yes --bind tailnet --no-install-service >"$WORK/onboard.log" 2>&1 &
  onboard_pid=$!
  for i in $(seq 1 90); do
    CFG="$(find_paperclip_config || true)"
    if [ -n "$CFG" ]; then
      ok "Paperclip onboard wrote $CFG"
      kill "$onboard_pid" 2>/dev/null || true
      wait "$onboard_pid" 2>/dev/null || true
      break
    fi
    if ! kill -0 "$onboard_pid" 2>/dev/null; then
      wait "$onboard_pid" || true
      [ -f "$WORK/onboard.log" ] && cat "$WORK/onboard.log" >&2
      die "paperclipai onboard exited before writing a config (or: paperclipai doctor)"
    fi
    sleep 2
  done
  [ -n "$CFG" ] || {
    kill "$onboard_pid" 2>/dev/null || true
    wait "$onboard_pid" 2>/dev/null || true
    die "paperclipai onboard did not write a config in time"
  }
fi
ok "Paperclip config: $CFG"
# A leftover `paperclipai run` from `--yes` (or a previous interrupted
# deploy) would hold the port on the tailnet bind. Drop it before we
# rewrite bind and hand the instance to the service manager.
pkill -f '[p]aperclipai run' 2>/dev/null || true

# Serve proxies 127.0.0.1, so the official tailnet bind cannot sit behind
# it. authenticated + loopback is the documented reverse-proxy pairing
# (DEPLOYMENT-MODES.md) and is what keeps us off local_trusted.
info "Pinning Paperclip to authenticated + loopback (Serve is the tailnet front)"
if python3 - "$CFG" "$TS_HOST" "$PAPERCLIP_PORT" <<'PY'
import json, sys
path, host, port = sys.argv[1], sys.argv[2].lower().rstrip("."), sys.argv[3]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
server = cfg.setdefault("server", {})
changed = False
if server.get("deploymentMode") != "authenticated":
    server["deploymentMode"] = "authenticated"
    changed = True
if server.get("exposure") != "private":
    server["exposure"] = "private"
    changed = True
if server.get("bind") != "loopback" or server.get("host") != "127.0.0.1":
    server["bind"] = "loopback"
    server["host"] = "127.0.0.1"
    server.pop("customBindHost", None)
    changed = True
try:
    want_port = int(port)
except ValueError:
    want_port = None
if want_port and server.get("port") != want_port:
    server["port"] = want_port
    changed = True
hosts = server.setdefault("allowedHostnames", [])
if host and host not in [h.lower() for h in hosts]:
    hosts.append(host)
    changed = True
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print("changed")
else:
    print("ok")
PY
then
  :
else
  die "Could not patch $CFG"
fi
# allowed-hostname is the official command; the JSON patch above already
# added the host so a re-run is a no-op. Still call it so doctor agrees.
pc allowed-hostname "$TS_HOST" >/dev/null 2>&1 || true
ok "Paperclip is authenticated/private, bound to 127.0.0.1:$PAPERCLIP_PORT, host $TS_HOST allowed"

# Instance env: public URL + bind overrides. Append missing keys only.
PC_ENV="$(dirname "$CFG")/.env"
if [ ! -f "$PC_ENV" ]; then
  : > "$PC_ENV"
  chmod 600 "$PC_ENV"
fi
append_kv "$PC_ENV" "PAPERCLIP_PUBLIC_URL" "https://$TS_HOST:$PAPERCLIP_HTTPS_PORT"
append_kv "$PC_ENV" "PAPERCLIP_BIND" "loopback"
append_kv "$PC_ENV" "PAPERCLIP_DEPLOYMENT_MODE" "authenticated"
append_kv "$PC_ENV" "PAPERCLIP_DEPLOYMENT_EXPOSURE" "private"
append_kv "$PC_ENV" "PORT" "$PAPERCLIP_PORT"

info "Installing Paperclip background service (official service manager)"
if [ "$OS" = "Linux" ]; then
  pc service install --enable-linger || die "paperclipai service install failed"
else
  pc service install || die "paperclipai service install failed"
fi
ok "Paperclip service installed"

if [ "$OS" = "Linux" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "Lingering already enabled"
  else
    info "Enabling lingering (needs sudo, one time)"
    sudo loginctl enable-linger "$USER"
    ok "Lingering enabled"
  fi
fi

# Paperclip's Profile page ships email as a disabled input and has no
# password field. Enable Better Auth change-email (no SMTP on this box)
# and inject editable fields onto Settings → Profile.
install_profile_credentials_ui() {
  local cli_root ui_dist src dest html auth_js update_js need_restart auth_rc update_rc
  src="$SERVICE_DIR/ui/profile-credentials.js"
  cli_root="$PAPERCLIP_DATA/cli/current/node_modules"
  ui_dist="$cli_root/@paperclipai/server/ui-dist"
  auth_js="$cli_root/@paperclipai/server/dist/auth/better-auth.js"
  update_js="$cli_root/better-auth/dist/api/routes/update-user.mjs"
  need_restart=0

  if [ ! -f "$src" ]; then
    warn "Profile credentials overlay missing at $src"
    return 0
  fi
  if [ ! -f "$ui_dist/index.html" ]; then
    warn "Paperclip ui-dist not found — Profile email/password fields not injected"
    return 0
  fi

  dest="$ui_dist/pc-profile-credentials.js"
  cp "$src" "$dest"
  html="$ui_dist/index.html"
  python3 - "$html" <<'PY'
import sys
from pathlib import Path
html = Path(sys.argv[1])
text = html.read_text(encoding="utf-8")
marker = "pc-profile-credentials.js"
if marker in text:
    sys.exit(0)
snippet = '    <script defer src="/pc-profile-credentials.js"></script>\n'
if "</body>" in text:
    text = text.replace("</body>", snippet + "  </body>", 1)
else:
    text += snippet
html.write_text(text, encoding="utf-8")
print("injected")
PY
  if [ ! -f "$html" ] || ! grep -q "pc-profile-credentials.js" "$html"; then
    warn "Could not inject Profile email/password script into $html"
  else
    ok "Paperclip Profile has editable email/password fields"
  fi

  if [ -f "$auth_js" ] && ! grep -q "updateEmailWithoutVerification" "$auth_js"; then
    auth_rc=0
    python3 - "$auth_js" <<'PY' || auth_rc=$?
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
needle = """        emailAndPassword: {
            enabled: true,
            requireEmailVerification: false,
            disableSignUp: config.authDisableSignUp,
        },
"""
insert = needle + """        user: {
            changeEmail: {
                enabled: true,
                updateEmailWithoutVerification: true,
            },
        },
"""
if needle not in text:
    sys.exit(2)
p.write_text(text.replace(needle, insert, 1), encoding="utf-8")
print("patched-auth")
PY
    if [ "$auth_rc" -eq 0 ]; then
      need_restart=1
    else
      warn "Could not enable Paperclip change-email (Better Auth config shape changed)"
    fi
  fi

  if [ -f "$update_js" ] && grep -q "emailVerified !== true && ctx.context.options.user.changeEmail.updateEmailWithoutVerification" "$update_js"; then
    update_rc=0
    python3 - "$update_js" <<'PY' || update_rc=$?
from pathlib import Path
import sys
p = Path(sys.argv[1])
old = "const canUpdateWithoutVerification = ctx.context.session.user.emailVerified !== true && ctx.context.options.user.changeEmail.updateEmailWithoutVerification;"
new = "const canUpdateWithoutVerification = ctx.context.options.user.changeEmail.updateEmailWithoutVerification;"
text = p.read_text(encoding="utf-8")
if old not in text:
    sys.exit(2)
p.write_text(text.replace(old, new, 1), encoding="utf-8")
print("patched-update")
PY
    if [ "$update_rc" -eq 0 ]; then
      need_restart=1
    else
      warn "Could not relax Better Auth emailVerified check for change-email"
    fi
  fi

  if [ "$need_restart" -eq 1 ]; then
    info "Restarting Paperclip so email/password changes take effect"
    # Serve occupies the same HTTPS port on the tailnet IP; Paperclip
    # treats that as "port busy" and hops (3100 -> 3101). Drop Serve for
    # the bounce. The later publish step puts it back.
    "$TAILSCALE" serve --https="$PAPERCLIP_HTTPS_PORT" off >/dev/null 2>&1 || true
    pc service restart >/dev/null 2>&1 || warn "paperclipai service restart failed — run it by hand"
    for i in $(seq 1 30); do
      if curl -fsS -o /dev/null "http://127.0.0.1:$PAPERCLIP_PORT/api/health" 2>/dev/null; then
        break
      fi
      sleep 1
    done
  fi
}
install_profile_credentials_ui

# ------------------------------------------------------- wait
info "Waiting for Paperclip (:$PAPERCLIP_PORT)"
pc_ok=0
for i in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PAPERCLIP_PORT/api/health" 2>/dev/null; then
    ok "Paperclip is answering locally"
    pc_ok=1
    break
  fi
  [ "$i" -eq 90 ] && die "Paperclip did not come up. paperclipai service logs"
  sleep 3
done

# ------------------------------------------------------- tailscale serve
publish() { # publish <https_port> <local_port>
  if ! "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null 2>&1; then
    if [ "$OS" = "Linux" ]; then
      info "Serve failed — trying operator grant (needs sudo, one time)"
      sudo tailscale set --operator="$USER"
    fi
    until "$TAILSCALE" serve --bg --https="$1" "http://127.0.0.1:$2"; do
      echo
      info "If Tailscale printed an approval URL above, open it, approve, then press Enter to retry."
      read -r || die "cannot read approval confirmation (stdin closed or no TTY) — re-run setup.sh in a terminal to approve Tailscale Serve"
    done
  fi
  ok "Tailscale Serve: HTTPS :$1 -> http://127.0.0.1:$2"
}
info "Publishing via Tailscale Serve (tailnet only, no Funnel)"
publish "$PAPERCLIP_HTTPS_PORT" "$PAPERCLIP_PORT"

# ------------------------------------------------------------ verify
pc_url="https://$TS_HOST:$PAPERCLIP_HTTPS_PORT"
info "Verifying end-to-end (first request can take ~60s while certs mint)"
if curl -fsS -o /dev/null --max-time 90 "$pc_url/api/health"; then
  ok "Paperclip reachable at $pc_url/api/health"
else
  warn "No answer on $pc_url/api/health yet — cert may still be minting: curl $pc_url/api/health"
fi

# Confirm we did not leave Paperclip in local_trusted after publishing.
if [ -n "$CFG" ] && grep -q '"local_trusted"' "$CFG"; then
  die "Paperclip config still contains local_trusted after publish. That would expose an unauthenticated board to the tailnet. Fix $CFG and re-run."
fi
ok "Paperclip is not in local_trusted mode"

# ---------------------------------------------------- bootstrap + agents
info "Minting the Paperclip CEO invite (headless; you accept it in the browser)"
invite_file="$MARKER/ceo-invite.txt"
if [ -f "$MARKER/.ceo-bootstrapped" ]; then
  ok "CEO invite already minted — not rotating it"
else
  if out="$(pc auth bootstrap-ceo --base-url "$pc_url" 2>&1)"; then
    printf '%s\n' "$out" > "$invite_file"
    chmod 600 "$invite_file"
    touch "$MARKER/.ceo-bootstrapped"
    ok "CEO invite written to $invite_file"
  else
    case "$out" in
      *"already exists"*|*"admin already"*|*"instance admin"*)
        ok "Instance admin already exists — leaving the invite alone"
        touch "$MARKER/.ceo-bootstrapped"
        ;;
      *)
        warn "Could not mint a CEO invite yet (server may still be applying migrations): $out"
        warn "  Retry: paperclipai auth bootstrap-ceo --base-url $pc_url"
        ;;
    esac
  fi
fi

# Agent create needs a board token and a company id, which only exist
# after the CEO invite is accepted. Do not invent those. If the operator
# has already logged in and exported them into .env, honour that.
if [ -n "${PAPERCLIP_COMPANY_ID:-}" ] && [ -n "${PAPERCLIP_API_KEY:-}" ]; then
  info "Provisioning claude_local + codex_local agents (company $PAPERCLIP_COMPANY_ID)"
  create_agent() {
    local name="$1" adapter="$2" cwd="$3"
    local marker="$MARKER/.agent-$name"
    if [ -f "$marker" ]; then
      ok "Agent $name already provisioned — skipping"
      return 0
    fi
    if PAPERCLIP_API_KEY="$PAPERCLIP_API_KEY" pc agent create \
        --company-id "$PAPERCLIP_COMPANY_ID" \
        --payload-json "{\"name\":\"$name\",\"role\":\"engineer\",\"adapterType\":\"$adapter\",\"adapterConfig\":{\"cwd\":\"$cwd\"}}"; then
      touch "$marker"
      ok "Created agent $name ($adapter) cwd=$cwd"
    else
      warn "Could not create agent $name — create it in the Paperclip UI"
    fi
  }
  create_agent "claude-local" "claude_local" "$WORKSPACES/paperclip-test"
  create_agent "codex-local" "codex_local" "$WORKSPACES/paperclip-test"
else
  warn "No PAPERCLIP_COMPANY_ID + PAPERCLIP_API_KEY in .env yet — agents are created after you accept the CEO invite. Re-run ./setup.sh once those are set, or hire them in the UI (claude_local + codex_local, cwd $WORKSPACES/paperclip-test)."
fi

# Secrets key reminder — losing it locks stored credentials.
secrets_key=""
for p in \
  "$PAPERCLIP_DATA/instances/default/secrets/master.key" \
  "$PAPERCLIP_DATA/secrets/master.key"
do
  [ -f "$p" ] && secrets_key="$p" && break
done

echo
printf '\033[1;32mDone.\033[0m Paperclip is on your tailnet only.\n'
echo
echo "  Paperclip:  $pc_url"
echo "  Workspace:  $WORKSPACES/paperclip-test"
echo
if [ -f "$invite_file" ]; then
  echo "  First login: open the CEO invite (also in $invite_file)"
  echo "    Then hire agents: claude_local and (when Codex is installed) codex_local"
  echo "    cwd: $WORKSPACES/paperclip-test"
fi
if [ -n "$secrets_key" ]; then
  echo
  echo "  BACK UP $secrets_key  (mode 600; losing it makes stored"
  echo "  Paperclip credentials unreadable). Copy it off this box — Seafile"
  echo "  at :8443 is one hop away. Do not commit it."
fi
echo
echo "Claude / Codex:"
echo "  Paperclip talks to the host CLIs (claude_local / codex_local)."
if [ -n "$CLAUDE_BIN" ]; then
  echo "  Claude: $CLAUDE_BIN — existing login reused, credentials not copied."
else
  echo "  Claude: not on PATH. Install it, then hire the agent in the UI."
fi
if [ -n "$CODEX_BIN" ]; then
  echo "  Codex:  $CODEX_BIN — Paperclip uses a per-agent CODEX_HOME, not yours."
else
  echo "  Codex:  not on PATH. Install it when you want that adapter; ~/.codex was not created."
fi
echo
echo "Manage:"
echo "  paperclipai service status|restart|logs"
echo "  tailscale serve status"
echo
echo "This is not on the public internet. Do not enable Tailscale Funnel."
echo "OpenHands Agent Canvas is a separate service: cd ../openhands && ./setup.sh"
exit 0
