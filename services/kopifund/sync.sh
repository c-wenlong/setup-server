#!/usr/bin/env bash
#
# sync.sh — snapshot ~/.kopifund into kopifund-hub and merge the other
# machines' snapshots back. Installed by services/kopifund/setup.sh to
# ~/services/kopifund/bin/sync.sh with __ENV_FILE__ baked in; run by the
# kopifund-sync timer (systemd user timer on Linux, LaunchAgent on macOS).
#
# Each run, in order:
#   1. commit every local change as "snapshot: <host> <time>" — local state
#      is always committed FIRST, so a merge can never lose uncommitted work
#   2. fetch the hub; fast-forward if we are simply behind
#   3. on divergence, merge deterministically: BOTH sides compute the same
#      winner (the tip with the newer committer date; a tie breaks on the
#      lower sha), which is what lets two machines converge instead of
#      re-conflicting every cycle. Conflicted files keep the winner's bytes
#      and the loser's land beside them as <name>.loser-<sha> — identical
#      names on both machines, so the copies themselves never re-conflict.
#   4. push; a raced push retries the fetch+merge once.
#
# Quiet unless something happens or goes wrong; output lands in the journal
# / ~/Library/Logs/kopifund-sync.log.

set -euo pipefail

ENV_FILE="__ENV_FILE__"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
DATA="${KOPIFUND_DATA:-$HOME/.kopifund}"
REMOTE="origin"
BRANCH="${KOPIFUND_HUB_BRANCH:-main}"

say() { printf 'kopifund-sync: %s\n' "$*"; }

[ -d "$DATA/.git" ] || exit 0   # not provisioned yet — setup.sh has not run
cd "$DATA" || exit 0

# A locked clone holds ciphertext; committing it would push garbage over the
# plaintext history. Never sync a sealed checkout.
for f in config.toml profile.json kopifund.db; do
  [ -f "$f" ] || continue
  if [ "$(od -An -c -N9 "$f" | tr -d ' ')" = '\0GITCRYPT' ]; then
    say "data folder is git-crypt locked — run git-crypt unlock first; skipping"
    exit 1
  fi
done

# mkdir is the portable atomic lock (no flock on macOS); inside .git so the
# lock itself is never committed.
lockdir=".git/kopifund-sync.lock.d"
if ! mkdir "$lockdir" 2>/dev/null; then
  exit 0   # another run is in flight — next tick catches up
fi
trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT

HOST="$(hostname -s 2>/dev/null || hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"
GIT=(git -c "user.name=kopifund-sync" -c "user.email=kopifund-sync@$HOST")

# ------------------------------------------------------- 1. local snapshot
"${GIT[@]}" add -A
if ! "${GIT[@]}" diff --cached --quiet; then
  "${GIT[@]}" commit -qm "snapshot: $HOST $NOW"
  say "committed local snapshot"
fi

# ------------------------------------------------- 2+3. fetch and integrate
integrate() {
  local ltip rtip base lct rct winner loser wside lshort f both
  "${GIT[@]}" fetch -q "$REMOTE" "$BRANCH" || { say "fetch failed (offline?)"; return 1; }
  ltip="$("${GIT[@]}" rev-parse HEAD)"
  rtip="$("${GIT[@]}" rev-parse "$REMOTE/$BRANCH")"
  [ "$ltip" = "$rtip" ] && return 0
  base="$("${GIT[@]}" merge-base HEAD "$REMOTE/$BRANCH" 2>/dev/null)" \
    || { say "local clone and $REMOTE/$BRANCH share no history — reconcile by hand"; return 1; }
  if [ "$base" = "$rtip" ]; then
    return 0   # strictly ahead — nothing to merge
  fi
  if [ "$base" = "$ltip" ]; then
    "${GIT[@]}" merge -q --ff-only "$REMOTE/$BRANCH" && say "fast-forwarded to $REMOTE/$BRANCH"
    return 0
  fi

  # Diverged. Winner = newer committer date; tie -> lower sha. Both machines
  # run the same comparison on the same two commits, so both pick the same
  # winner and the trees converge.
  lct="$("${GIT[@]}" show -s --format=%ct "$ltip")"
  rct="$("${GIT[@]}" show -s --format=%ct "$rtip")"
  if [ "$rct" -gt "$lct" ] || { [ "$rct" -eq "$lct" ] && [ "$rtip" '<' "$ltip" ]; }; then
    winner="$rtip"; loser="$ltip"; wside="theirs"
  else
    winner="$ltip"; loser="$rtip"; wside="ours"
  fi
  lshort="$(printf '%s' "$loser" | cut -c1-8)"

  # Preserve the losing side of every file BOTH tips touched since the base.
  # Text files may have merged cleanly — the copy is belt and braces, and a
  # stale <name>.loser-<sha> is deleted the next time its sha is the winner.
  both="$(comm -12 \
    <("${GIT[@]}" diff --name-only "$base" "$ltip" | sort) \
    <("${GIT[@]}" diff --name-only "$base" "$rtip" | sort))"
  printf '%s\n' "$both" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    "${GIT[@]}" show "$loser:$f" > "$f.loser-$lshort" 2>/dev/null || true
  done

  if ! "${GIT[@]}" merge -q --no-commit -X "$wside" "$REMOTE/$BRANCH"; then
    # -X settles content conflicts; modify/delete still needs a hand.
    "${GIT[@]}" diff --name-only --diff-filter=U | while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ "$wside" = "ours" ]; then
        "${GIT[@]}" checkout --ours -- "$f" 2>/dev/null && "${GIT[@]}" add -- "$f" \
          || "${GIT[@]}" rm -qf -- "$f"
      else
        "${GIT[@]}" checkout --theirs -- "$f" 2>/dev/null && "${GIT[@]}" add -- "$f" \
          || "${GIT[@]}" rm -qf -- "$f"
      fi
    done
  fi
  "${GIT[@]}" add -A
  "${GIT[@]}" commit -qm "merge $REMOTE/$BRANCH (winner: $wside; loser files kept as *.loser-$lshort)"
  say "merged $REMOTE/$BRANCH — $wside won; loser's versions kept as *.loser-$lshort"
}

# ------------------------------------------------------------------ 4. push
attempt=0
while [ "$attempt" -lt 2 ]; do
  attempt=$((attempt + 1))
  integrate || exit 1
  if "${GIT[@]}" diff --quiet "HEAD" "$REMOTE/$BRANCH" \
     && [ "$("${GIT[@]}" rev-parse HEAD)" = "$("${GIT[@]}" rev-parse "$REMOTE/$BRANCH")" ]; then
    exit 0   # nothing to push
  fi
  if "${GIT[@]}" push -q "$REMOTE" "HEAD:$BRANCH" 2>/dev/null; then
    say "pushed to $REMOTE/$BRANCH"
    exit 0
  fi
  say "push raced — fetching again"
done
say "still behind $REMOTE/$BRANCH after two rounds — next tick retries"
exit 1
