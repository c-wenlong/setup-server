#!/usr/bin/env bash
#
# Tests for scripts/build-registry.py: the generator that turns
# services/*/app.json + app/web/registry.json into app/web/services.json.
#
#   ./scripts/tests/test-build-registry.sh
#
# Runs the real script against a fixture repo in a temp dir, then checks the
# real repo's committed services.json is current. No host changes.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO/scripts/build-registry.py"
PASS=0; FAIL=0
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '    \033[1;32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '    \033[1;31m✗\033[0m %s\n' "$label"; FAIL=$((FAIL + 1))
  fi
}
out_has() { grep -qF -- "$1" "$OUT"; }
# jq-free JSON assertions: py <python expression over `d`, the output>
py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$R/app/web/services.json"; }

setup() {
  SB="$(mktemp -d)"; R="$SB/repo"
  mkdir -p "$R/scripts" "$R/app/web" "$R/services/alpha" "$R/services/duo" "$R/services/quiet"
  cp "$SCRIPT" "$R/scripts/"
  cat > "$R/app/web/registry.json" <<'JSON'
{
  "_comment": ["field reference"],
  "groups": [{"id": "daily", "label": "Daily"}, {"id": "infra", "label": "Infra"}],
  "control": {"kuma_toggle": "services/ntfy-control/kuma_toggle.py"},
  "order": ["duo-b", "alpha", "ext", "duo-a"],
  "external": [{"key": "ext", "name": "Ext", "group": "infra", "setup": "~/dev/ext/setup.sh", "env": "~/dev/ext/.env"}]
}
JSON
  printf '{"key": "alpha", "name": "Alpha", "group": "daily", "marker": "~/services/alpha", "env": ".env", "description": "d"}\n' \
    > "$R/services/alpha/app.json"
  printf '[{"key": "duo-a", "name": "A", "group": "infra", "env": null},\n {"key": "duo-b", "name": "B", "group": "infra"}]\n' \
    > "$R/services/duo/app.json"
  # services/quiet has no app.json: a folder with no tile is skipped.
}
teardown() { rm -rf "$SB"; }
gen() { OUT="$SB/out.log"; python3 "$R/scripts/build-registry.py" "$@" > "$OUT" 2>&1; CODE=$?; }

echo "• generates services.json"
setup
gen
check "exits zero"                          [ "$CODE" -eq 0 ]
check "follows order"                       py '[s["key"] for s in d["services"]] == ["duo-b", "alpha", "ext", "duo-a"]'
check "setup derived from the folder"       py 'd["services"][1]["setup"] == "services/alpha/setup.sh"'
check "relative env expanded"               py 'd["services"][1]["env"] == "services/alpha/.env"'
check "null env kept null"                  py 'd["services"][3]["env"] is None'
check "setup sits just before env"          py 'list(d["services"][1])[3:6] == ["marker", "setup", "env"]'
check "setup added when there is no env"    py 'd["services"][0]["setup"] == "services/duo/setup.sh"'
check "list manifest gives two tiles"       py 'd["services"][3]["setup"] == "services/duo/setup.sh"'
check "external tile kept verbatim"         py 'd["services"][2] == {"key": "ext", "name": "Ext", "group": "infra", "setup": "~/dev/ext/setup.sh", "env": "~/dev/ext/.env"}'
check "generated notice first"              py 'd["_comment"][0].startswith("GENERATED") and d["_comment"][-1] == "field reference"'
check "groups and control copied"           py 'd["groups"][0]["id"] == "daily" and "kuma_toggle" in d["control"]'
check "no order or external in output"      py '"order" not in d and "external" not in d'
gen --check
check "--check passes right after"          [ "$CODE" -eq 0 ]
gen
check "second run is a no-op"               out_has "already up to date"
check "no temp file left behind"            test ! -e "$R/app/web/services.json.tmp"

echo "• --check catches drift"
printf '{"key": "alpha", "name": "Renamed", "group": "daily"}\n' > "$R/services/alpha/app.json"
gen --check
check "exits non-zero"                      [ "$CODE" -ne 0 ]
check "says to run the script"              out_has "is out of date"
teardown

echo "• validation"
setup
printf '{"key": "beta", "name": "B", "group": "daily"}\n' > "$R/services/quiet/app.json"
gen
check "missing from order fails"            [ "$CODE" -ne 0 ]
check "names the key"                       out_has "add to \"order\""
check "nothing written"                     test ! -e "$R/app/web/services.json"
teardown

setup
printf '{"key": "alpha", "name": "A", "group": "daily", "setup": "elsewhere.sh"}\n' > "$R/services/alpha/app.json"
gen
check "setup in a manifest fails"           out_has "drop \"setup\""
teardown

setup
printf '{"key": "duo-a", "name": "A", "group": "daily"}\n' > "$R/services/alpha/app.json"
gen
check "duplicate key fails"                 out_has "duplicate key 'duo-a'"
teardown

setup
printf '{"key": "alpha", "name": "A", "group": "nope"}\n' > "$R/services/alpha/app.json"
gen
check "unknown group fails"                 out_has "group 'nope'"
teardown

setup
python3 - "$R/app/web/registry.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["order"].append("ghost"); json.dump(d, open(p, "w"))
PY
gen
check "unknown key in order fails"          out_has "names keys with no entry: ghost"
teardown

setup
python3 - "$R/app/web/registry.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["order"].append("duo-b"); json.dump(d, open(p, "w"))
PY
gen
check "repeated key in order fails"         [ "$CODE" -ne 0 ]
check "names the repeated key"              out_has '"order" in app/web/registry.json repeats: duo-b'
teardown

setup
printf '{"key": "alpha",' > "$R/services/alpha/app.json"
gen
check "invalid JSON fails"                  out_has "services/alpha/app.json is not valid JSON"
teardown

echo "• the real repo"
OUT="$(mktemp)"
python3 "$SCRIPT" --check > "$OUT" 2>&1; CODE=$?
check "committed services.json is current"  [ "$CODE" -eq 0 ]
rm -f "$OUT"

echo
if [ "$FAIL" -eq 0 ]; then green "All $PASS checks passed."; exit 0; fi
red "$FAIL of $((PASS + FAIL)) checks failed."; exit 1
