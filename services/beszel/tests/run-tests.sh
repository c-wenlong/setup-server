#!/usr/bin/env bash
#
# Tests for services/beszel/setup.sh.
#
#   ./tests/run-tests.sh          # static structural checks (no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Mocked mode is static analysis rather than the PATH-stub sandbox other
# services use: this setup leans on the hub's live PocketBase API, so a stub
# farm would mostly test the stubs (rationale in SETUP.md).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SETUP="$SERVICE_DIR/setup.sh"
COMPOSE="$SERVICE_DIR/docker-compose.yml"

PASS=0; FAIL=0
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); green "    ✓ $desc"
  else FAIL=$((FAIL+1)); red "    ✗ $desc"; fi
}

echo "  static checks"
check "setup.sh parses (bash -n)" bash -n "$SETUP"
check "strict mode set" grep -q 'set -euo pipefail' "$SETUP"
# Portability contract (AGENTS.md): OS branch, root refusal, resolved Tailscale
# CLI, Tailscale-running preflight, gated Linux-only concepts.
check "branches on uname -s (Linux|Darwin, dies otherwise)" \
      grep -q 'case "\$OS" in Linux|Darwin) ;; \*) die' "$SETUP"
check "refuses to run as root" grep -q '\[ "\$(id -u)" -ne 0 \] || die' "$SETUP"
check "requires Tailscale to be Running before deploying" \
      grep -q 'BackendState' "$SETUP"
check "resolves the Tailscale CLI from the macOS app bundle" \
      grep -q '/Applications/Tailscale.app/Contents/MacOS/Tailscale' "$SETUP"
# Every real invocation goes through the resolved path. Comment lines and
# the management hints echoed at the end are the only places the bare word
# may appear next to a subcommand.
check "no bare 'tailscale serve|status|ip' invocations" \
      bash -c "! grep -vE '^[[:space:]]*(#|echo )' '$SETUP' | grep -qE '(^|[^A-Za-z_\"\$/-])tailscale +(serve|status|ip)\b'"
check "agent tarball picks OS + arch (not linux_amd64 literal)" \
      grep -q 'beszel-agent_\${OS_LC}_\${ARCH}\.tar\.gz' "$SETUP"
check "macOS agent runs as a launchd LaunchAgent" \
      grep -q 'Library/LaunchAgents/com.henrygd.beszel-agent.plist' "$SETUP"
check "lingering is Linux-gated" \
      bash -c "grep -B6 'loginctl enable-linger' '$SETUP' | grep -q 'OS\" = \"Linux'"
check "operator grant is Linux-gated and only on a denied serve" \
      bash -c "grep -B2 'set --operator=' '$SETUP' | grep -q 'OS\" = \"Linux\" \] && printf .%s. .\$serve_out. | grep -q .denied.'"
check "serve retries only on an approval link, dies otherwise" \
      bash -c "grep -q '\*login.tailscale.com\*) ;;' '$SETUP' && grep -A1 '\*login.tailscale.com\*) ;;' '$SETUP' | grep -q 'die'"
check "port from .env is re-validated" \
      grep -q 'BESZEL_PORT in \$ENV_FILE must be numeric' "$SETUP"
check "final URL is resolved, not hardcoded" \
      bash -c "! grep -q 'kai-home-server\.taild6a23f' '$SETUP'"
# Sudo is surgical: exactly the two one-time Linux grants the reference
# implementation (code-server) makes, and nothing else.
check "sudo only for lingering + tailscale operator" \
      bash -c "[ \"\$(grep -c '^ *sudo ' '$SETUP')\" -eq 2 ] && grep -q '^ *sudo loginctl enable-linger' '$SETUP' && grep -q '^ *sudo \"\$TAILSCALE\" set --operator=' '$SETUP'"
check "hub bound to loopback" grep -q 'serve --http "127.0.0.1' "$COMPOSE"
check "hub uses host networking (reaches agent loopback)" \
      grep -q 'network_mode: host' "$COMPOSE"
check "agent listens loopback only" grep -q 'LISTEN=127.0.0.1' "$SETUP"
check "agent KEY env is quoted (contains a space)" \
      grep -q 'Environment="KEY=' "$SETUP"
check "agent unit always restarted after rewrite" \
      grep -q 'systemctl --user restart beszel-agent' "$SETUP"
check ".env created mode 600" grep -q 'chmod 600 "\$ENV_FILE"' "$SETUP"
check ".env is gitignored" git -C "$SERVICE_DIR" check-ignore -q "$SERVICE_DIR/.env"
check "idempotency guard on .env (never clobbered)" \
      grep -q 'if \[ -f "\$ENV_FILE" \]; then' "$SETUP"
check "tailscale serve published via the resolved CLI" \
      grep -q '"\$TAILSCALE" serve --bg --https="\$PORT" "http://127.0.0.1:\$PORT"' "$SETUP"
check "GPU stats enabled" grep -q 'GPU=true' "$SETUP"
check "Kuma monitor row exists" \
      grep -q 'beszel' "$SERVICE_DIR/../monitoring/seed_kuma.py"

if [ "${1:-}" = "--live" ]; then
  echo "  live checks"
  PORT="$(grep '^BESZEL_PORT=' "$SERVICE_DIR/.env" 2>/dev/null | cut -d= -f2)"
  PORT="${PORT:-8092}"
  check "hub healthy" curl -fsS "http://127.0.0.1:$PORT/api/health"
  check "hub container running" \
      bash -c "docker inspect -f '{{.State.Running}}' beszel | grep -q true"
  check "agent unit active" systemctl --user is-active beszel-agent.service
  check "agent on loopback:45876" \
      bash -c "ss -ltn | grep -q '127.0.0.1:45876'"
  check "agent NOT on all interfaces" \
      bash -c "! ss -ltn | grep -E '(\*|0\.0\.0\.0):45876' -q"
  check "tailscale serve maps :$PORT" \
      bash -c "tailscale serve status | grep -q ':$PORT'"
  check "stats are fresh (<3 min old)" python3 - "$SERVICE_DIR" "$PORT" <<'PYEOF'
import json, sys, time, urllib.request
from datetime import datetime, timezone
svc, port = sys.argv[1], sys.argv[2]
env = dict(l.strip().split("=", 1) for l in open(f"{svc}/.env")
           if "=" in l and not l.startswith("#"))
api = f"http://127.0.0.1:{port}/api"
def req(p, d=None, t=None):
    r = urllib.request.Request(api+p,
        data=json.dumps(d).encode() if d else None,
        headers={"Content-Type": "application/json",
                 **({"Authorization": t} if t else {})})
    return json.load(urllib.request.urlopen(r, timeout=10))
tok = req("/collections/_superusers/auth-with-password",
          {"identity": env["BESZEL_ADMIN_EMAIL"],
           "password": env["BESZEL_ADMIN_PASSWORD"]})["token"]
rec = req("/collections/system_stats/records?sort=-created&perPage=1",
          t=tok)["items"][0]
age = time.time() - datetime.strptime(
    rec["created"], "%Y-%m-%d %H:%M:%S.%fZ"
).replace(tzinfo=timezone.utc).timestamp()
sys.exit(0 if age < 180 else 1)
PYEOF
fi

echo
[ "$FAIL" -eq 0 ] && green "  $PASS passed" || { red "  $FAIL failed, $PASS passed"; exit 1; }
