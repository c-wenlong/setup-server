#!/usr/bin/env bash
#
# Tests for beszel/setup.sh.
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
check "no sudo anywhere" bash -c "! grep -q 'sudo ' '$SETUP'"
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
      grep -q '\[ ! -f "\$ENV_FILE" \]' "$SETUP"
check "tailscale serve published" grep -q 'tailscale serve --bg --https=' "$SETUP"
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
