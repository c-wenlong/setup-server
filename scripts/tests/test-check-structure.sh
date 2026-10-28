#!/usr/bin/env bash
#
# Tests for scripts/check-structure.sh, the lib/common.sh rules:
#
#   ./scripts/tests/test-check-structure.sh
#
# Copies the tracked tree into a temp dir once, runs the real check there,
# then breaks one file per case (and puts it back). The copy is not a git
# checkout, so the tracked-.env rule prints a note and skips; that rule is not
# what this suite covers. No host changes.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../.." && pwd)"
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
out_has()  { grep -qF -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
R="$SB/repo"
mkdir -p "$R"
# Tracked files only, as they are in the working tree.
(cd "$REPO" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$R"

run() { OUT="$("$R/scripts/check-structure.sh" 2>&1)"; CODE=$?; }

# break FILE: keep a pristine copy so restore puts it back.
break_file() { cp "$R/$1" "$SB/pristine"; }
restore()    { cp "$SB/pristine" "$R/$1"; }
drop_source() { grep -v '^\. "\$SERVICE_DIR/\.\./\.\./lib/common\.sh"$' "$SB/pristine" > "$R/$1"; }

echo "• the tree as committed"
run
check "passes"                                  [ "$CODE" -eq 0 ]
check "beszel's setup.sh is exempt"             out_lacks "services/beszel/setup.sh"

echo "• a setup.sh that does not source the lib"
f=services/n8n/setup.sh; break_file "$f"; drop_source "$f"
run
check "fails"                                   [ "$CODE" -ne 0 ]
check "  names the script"                      out_has "FAIL: $f does not source lib/common.sh"
restore "$f"

echo "• a teardown.sh that does not source the lib"
f=services/n8n/teardown.sh; break_file "$f"; drop_source "$f"
run
check "fails"                                   [ "$CODE" -ne 0 ]
check "  names the script"                      out_has "FAIL: $f does not source lib/common.sh"
restore "$f"

echo "• the exemption covers beszel's setup.sh only"
f=services/beszel/teardown.sh; break_file "$f"; drop_source "$f"
run
check "beszel's teardown.sh still must source it" out_has "FAIL: $f does not source lib/common.sh"
restore "$f"

echo "• a migrated script that redefines a helper"
f=services/n8n/setup.sh; break_file "$f"
printf "die() { echo local; exit 1; }\n" >> "$R/$f"
run
check "fails"                                   [ "$CODE" -ne 0 ]
check "  names the helper"                      out_has "FAIL: $f sources lib/common.sh but redefines: die"
restore "$f"

echo "• a suite that never copies the lib into its sandbox"
f=services/n8n/tests/run-tests.sh; break_file "$f"
grep -v 'lib/common\.sh' "$SB/pristine" > "$R/$f"
run
check "fails"                                   [ "$CODE" -ne 0 ]
check "  names the suite"                       out_has "FAIL: services/n8n/tests/run-tests.sh never copies lib/common.sh"
restore "$f"

echo "• everything restored"
run
check "passes again"                            [ "$CODE" -eq 0 ]

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL of $((PASS + FAIL)) checks failed."
  exit 1
fi
