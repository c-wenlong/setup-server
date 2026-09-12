#!/usr/bin/env bash
#
# Enforce the per-service contract from AGENTS.md.
#
#   ./scripts/check-structure.sh
#
# For every top-level directory holding a setup.sh, this asserts:
#
#   - setup.sh, SETUP.md, TROUBLESHOOT.md and tests/run-tests.sh all exist
#   - setup.sh and tests/run-tests.sh are executable
#   - tests/stubs/ exists and is non-empty (see STUBS_EXEMPT below)
#   - README.md's Services table has a row linking [<name>](<name>/)
#   - DIRECTORY.md has a table row linking [<name>](<name>/)
#
# Plus one repo-wide rule: no .env may ever be tracked by git.
#
# One line per failure, non-zero exit if anything failed. No side effects: this
# only reads the tree and asks git what it tracks.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Services allowed to ship without tests/stubs/. AGENTS.md documents beszel as
# the single exception: its default test layer is static analysis of setup.sh
# rather than a sandboxed run, so there is nothing to stub. The rationale is in
# beszel/SETUP.md. Keep this list at one entry unless AGENTS.md grows another.
STUBS_EXEMPT="beszel"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*"
  FAILURES=$((FAILURES + 1))
}

exempt_from_stubs() {
  local name="$1" e
  for e in $STUBS_EXEMPT; do
    [ "$e" = "$name" ] && return 0
  done
  return 1
}

# The link must sit in a table row (a line starting with `|`), because the
# contract is a row in the Services or Deployment table, and prose elsewhere in
# the file mentions services too. The name is matched as a literal, not a regex:
# a dash is fine, and a dot in a future name must not become a wildcard.
links_to() {
  local file="$1" name="$2"
  grep -- '^|' "$file" | grep -qF -- "[$name]($name/)"
}

# ------------------------------------------------------------- per service
SERVICES=""
for setup in */setup.sh; do
  [ -e "$setup" ] || continue
  SERVICES="$SERVICES ${setup%/setup.sh}"
done

if [ -z "$SERVICES" ]; then
  fail "no <service>/setup.sh found: is this the repo root?"
fi

for svc in $SERVICES; do
  [ -x "$svc/setup.sh" ]           || fail "$svc/setup.sh is not executable"
  [ -f "$svc/SETUP.md" ]           || fail "$svc/SETUP.md is missing"
  [ -f "$svc/TROUBLESHOOT.md" ]    || fail "$svc/TROUBLESHOOT.md is missing"

  if [ -f "$svc/tests/run-tests.sh" ]; then
    [ -x "$svc/tests/run-tests.sh" ] || fail "$svc/tests/run-tests.sh is not executable"
  else
    fail "$svc/tests/run-tests.sh is missing"
  fi

  if exempt_from_stubs "$svc"; then
    :
  elif [ ! -d "$svc/tests/stubs" ]; then
    fail "$svc/tests/stubs/ is missing (add stubs, or document an exception in AGENTS.md and add it to STUBS_EXEMPT)"
  elif [ -z "$(ls -A "$svc/tests/stubs" 2>/dev/null)" ]; then
    fail "$svc/tests/stubs/ is empty"
  fi

  links_to README.md "$svc" \
    || fail "README.md has no Services row linking [$svc]($svc/)"
  links_to DIRECTORY.md "$svc" \
    || fail "DIRECTORY.md has no table row linking [$svc]($svc/)"
done

# ------------------------------------------------------------- repo wide
# setup.sh writes real credentials into <service>/.env. Gitignored is not the
# same as untracked: a `git add -f` or a pre-gitignore commit would slip one in.
if git rev-parse --git-dir >/dev/null 2>&1; then
  tracked_env="$(git ls-files | grep -E '(^|/)\.env$' || true)"
  if [ -n "$tracked_env" ]; then
    while IFS= read -r f; do
      fail "a .env is tracked by git: $f (it holds generated credentials)"
    done <<< "$tracked_env"
  fi
else
  printf 'note: not a git checkout, skipping the tracked-.env check\n'
fi

# ------------------------------------------------------------------ result
n_services="$(printf '%s\n' $SERVICES | grep -c .)"
if [ "$FAILURES" -eq 0 ]; then
  printf 'structure OK: %s services, every contract file present\n' "$n_services"
  exit 0
fi

printf '\n%s structure check failure(s) across %s services\n' "$FAILURES" "$n_services"
exit 1
