#!/usr/bin/env bash
#
# migrate-layout.sh — one-time move of a live checkout to the services/ + app/
# layout (every <service>/ moved to services/<service>/, launcher/ to app/web/).
#
# `git pull` moves the tracked files. It cannot move what git does not track,
# and a deployed box keeps live state inside the checkout:
#
#   1. gitignored files in the old folders: every .env (generated secrets),
#      openhands/docker-compose.creds.yml, local compose overrides, .bak files
#   2. absolute paths into the old folders, written once at deploy time:
#      the launcher and ntfy-control units, ntfy-control/.env's
#      KUMA_ENV_FILE, and the deploy.sh copies the *-deploy timers run from
#      ~/services/<service>/bin/ (ENV_FILE, self-learn's COMPOSE_DIR)
#   3. containers that bind-mount a file from the old folder (appflowy's
#      nginx.conf, coolify's .env, trigger-dev's ClickHouse config). Docker
#      keeps the old source path, so the next restart mounts nothing.
#
# This script fixes all three, in that order:
#
#   1. moves every leftover file to the same relative path under the new
#      folder. Never overwrites: a file already at the new path is kept and
#      the old copy is left behind with a warning.
#   2. rewrites old paths in place: services/*/.env, app/*/.env,
#      ~/services/*/bin/* (deploy.sh copies) and every systemd user unit or
#      LaunchAgent, then restarts the units it changed. It deliberately does
#      not re-run setup.sh: that would re-apply defaults (LAUNCHER_PORT,
#      SHORT_PATH) over whatever the box was deployed with. ntfy-control's
#      verbatim bin/ copies are refreshed, since the old copy looks for
#      services.json in the old place.
#   3. recreates only the containers whose bind mounts point at an old
#      folder, from the same compose files at their new paths. A running
#      container comes back running; a stopped one is recreated stopped.
#
# Usage (from the repo root, right after pulling the commit that moved it):
#   ./scripts/migrate-layout.sh --dry-run   # print the plan, change nothing
#   ./scripts/migrate-layout.sh
#
# Idempotent: a second run finds nothing to do. Named volumes and everything
# under ~/services/<service>/ are untouched: compose names a project after its
# folder, and services/immich/ is still "immich".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"
DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- preflight
case "$OS" in Linux|Darwin) ;; *) die "Unsupported OS: $OS (Linux and macOS only)";; esac
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root."
[ -d "$ROOT/services" ] && [ -d "$ROOT/app/web" ] \
  || die "No services/ or app/web/ in $ROOT. Pull the commit that moved them first."
command -v python3 >/dev/null || die "python3 is required."
[ "$DRY_RUN" -eq 1 ] && info "Dry run: nothing will be changed"

# old folder name -> new folder, relative to ROOT
PAIRS=""
for d in "$ROOT"/services/*/; do
  name="$(basename "$d")"
  PAIRS="$PAIRS $name:services/$name"
done
PAIRS="$PAIRS launcher:app/web"
# A box that never ran the paperclip/openhands split still has the combined
# folder; both setup.sh files read it as $SERVICE_DIR/../paperclip-openhands.
[ -d "$ROOT/paperclip-openhands" ] && PAIRS="$PAIRS paperclip-openhands:services/paperclip-openhands"

# ------------------------------------------------- 1. leftover untracked files
info "Moving untracked files out of the old folders"
moved=0; kept=0
for pair in $PAIRS; do
  old="${pair%%:*}"; new="${pair#*:}"
  [ -d "$ROOT/$old" ] || continue
  while IFS= read -r -d '' src; do
    rel="${src#"$ROOT/$old/"}"
    dst="$ROOT/$new/$rel"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      if cmp -s "$src" "$dst"; then
        run rm -f "$src"
      else
        warn "kept both: $new/$rel already exists, left $old/$rel in place (diff them by hand)"
        kept=$((kept + 1))
      fi
      continue
    fi
    printf '    %s -> %s\n' "$old/$rel" "$new/$rel"
    run mkdir -p "$(dirname "$dst")"
    run mv "$src" "$dst"
    moved=$((moved + 1))
  # Bytecode is regenerated on the next run, so it is deleted, never moved.
  done < <(find "$ROOT/$old" -name __pycache__ -prune -o \( -type f -o -type l \) -print0)
  if [ "$DRY_RUN" -eq 0 ]; then
    find "$ROOT/$old" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$ROOT/$old" -depth -type d -empty -delete 2>/dev/null || true
  fi
done
ok "$moved file(s) moved, $kept left in place"

# ------------------------------------------------ 2a. absolute paths in .env
info "Rewriting old absolute paths in .env files and deployed scripts"
# "$ROOT/<old>" -> "$ROOT/<new>" when followed by /, a quote, <, whitespace or
# end of line (self-learn's COMPOSE_DIR has no trailing slash), so only whole
# folder names match. Done in Python so GNU and BSD behave the same.
# Prints each changed file, one per line.
rewrite_paths() {
  python3 - "$ROOT" "$DRY_RUN" "$PAIRS" "$@" <<'PY'
import re, sys
root, dry, files = sys.argv[1], sys.argv[2] == "1", sys.argv[4:]
pairs = [p.split(":", 1) for p in sys.argv[3].split()]
for f in files:
    try:
        text = open(f, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    new = text
    for old, target in pairs:
        rx = re.compile(re.escape("%s/%s" % (root, old)) + r"(?=[/\"'<\s]|$)", re.M)
        new = rx.sub("%s/%s" % (root, target), new)
    if new != text:
        print(f)
        if not dry:
            open(f, "w", encoding="utf-8").write(new)
PY
}
envs=()
for f in "$ROOT"/services/*/.env "$ROOT"/app/*/.env "$HOME"/services/*/bin/*; do
  case "$f" in *.bak*) continue ;; esac
  [ -f "$f" ] && envs+=("$f")
done
if [ "${#envs[@]}" -gt 0 ]; then
  rewrite_paths "${envs[@]}" | sed 's/^/    /'
fi
ok "paths checked"

# --------------------------------------- 2b. units / LaunchAgents with old paths
info "Repointing units and LaunchAgents at the new folders"
failed=""
restart_failed() { warn "$1 did not restart; check it by hand"; failed="$failed $1"; }
if [ "$OS" = "Linux" ]; then
  UNIT_DIR="$HOME/.config/systemd/user"; UNIT_GLOB="*.service"
else
  UNIT_DIR="$HOME/Library/LaunchAgents"; UNIT_GLOB="*.plist"
fi
# True when a non-comment line names an old folder. A unit whose only mention
# is a comment (self-learn's names its .env) is rewritten but not restarted.
live_mention() {
  local f="$1" pair
  for pair in $PAIRS; do
    awk -v p="$ROOT/${pair%%:*}" '
      !/^[[:space:]]*#/ { i = index($0, p)
        if (i) { c = substr($0, i + length(p), 1)
          if (c == "" || c == "/" || c == "\"" || c == "<" || c == " ") hit = 1 } }
      END { exit !hit }' "$f" && return 0
  done
  return 1
}
changed_units=""
if [ -d "$UNIT_DIR" ]; then
  units=()
  for f in "$UNIT_DIR"/$UNIT_GLOB; do [ -f "$f" ] && units+=("$f"); done
  restart=""
  for f in "${units[@]+"${units[@]}"}"; do
    live_mention "$f" && restart="$restart $(basename "$f")"
  done
  if [ "${#units[@]}" -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '    %s\n' "$f"
    done < <(rewrite_paths "${units[@]}")
  fi
  changed_units="$restart"
fi

# ntfy-control's setup.sh copies these two files verbatim into bin/. The old
# copy looks for app/web/services.json under the old name, so phone controls
# would stop at its next restart. Copying is what a re-run would do.
NC_BIN="$HOME/services/ntfy-control/bin"
nc_refreshed=0
if [ -d "$NC_BIN" ]; then
  for f in control_listener.py kuma_toggle.py; do
    [ -f "$ROOT/services/ntfy-control/$f" ] || continue
    cmp -s "$ROOT/services/ntfy-control/$f" "$NC_BIN/$f" && continue
    printf '    refresh %s\n' "$NC_BIN/$f"
    run cp "$ROOT/services/ntfy-control/$f" "$NC_BIN/$f"
    nc_refreshed=1
  done
fi
if [ "$nc_refreshed" -eq 1 ]; then
  if [ "$OS" = "Linux" ]; then nc_unit="ntfy-control.service"; else nc_unit="com.ntfy-control.listener.plist"; fi
  case " $changed_units " in *" $nc_unit "*) ;; *) changed_units="$changed_units $nc_unit" ;; esac
fi

# Restart only what changed. try-restart leaves a stopped unit stopped.
if [ -n "$changed_units" ]; then
  if [ "$OS" = "Linux" ]; then
    run systemctl --user daemon-reload || restart_failed "daemon-reload"
    for u in $changed_units; do
      run systemctl --user try-restart "$u" || restart_failed "$u"
    done
  else
    for u in $changed_units; do
      label="${u%.plist}"
      # Reload only agents that are loaded now; an unloaded one stays off,
      # as try-restart does on Linux (these plists set RunAtLoad).
      launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || continue
      run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      run launchctl bootstrap "gui/$(id -u)" "$UNIT_DIR/$u" || restart_failed "$u"
    done
  fi
fi
ok "units checked"

# --------------------------------------------- 3. containers with old mounts
info "Recreating containers that bind-mount from an old folder"
if ! command -v docker >/dev/null 2>&1; then
  ok "no docker on this box, nothing to recreate"
elif ! docker info >/dev/null 2>&1; then
  warn "docker is installed but not reachable (docker group?). Re-run once it is."
else
  # One line per compose container:
  #   project | config files (comma-separated) | running (1/0) | services
  # "|" rather than a tab: read collapses empty tab-separated fields.
  plan="$(python3 - "$ROOT" "$PAIRS" <<'PY'
import json, subprocess, sys
root, pairs = sys.argv[1], [p.split(":", 1) for p in sys.argv[2].split()]
ids = subprocess.run(["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project"],
                     capture_output=True, text=True, check=True).stdout.split()
if not ids:
    sys.exit(0)
info = json.loads(subprocess.run(["docker", "inspect"] + ids, capture_output=True,
                                 text=True, check=True).stdout)
groups = {}
for c in info:
    labels = c.get("Config", {}).get("Labels") or {}
    sources = [m.get("Source", "") for m in c.get("Mounts") or [] if m.get("Type") == "bind"]
    stale = [s for s in sources for old, _ in pairs if s.startswith("%s/%s/" % (root, old))]
    if not stale:
        continue
    files = labels.get("com.docker.compose.project.config_files", "")
    for old, new in pairs:
        files = files.replace("%s/%s/" % (root, old), "%s/%s/" % (root, new))
    key = (labels.get("com.docker.compose.project"), files,
           bool(c.get("State", {}).get("Running")))
    groups.setdefault(key, []).append(labels.get("com.docker.compose.service"))
for (project, files, running), svcs in sorted(groups.items()):
    print("|".join([project, files, "1" if running else "0", " ".join(sorted(svcs))]))
PY
)"
  if [ -z "$plan" ]; then
    ok "no container mounts an old folder"
  else
    while IFS='|' read -r project files running svcs; do
      args=()
      first="${files%%,*}"
      [ -n "$first" ] && [ -f "$first" ] \
        || { warn "$project: compose file ${first:-?} not found, skipped"; continue; }
      IFS=',' read -r -a cfgs <<< "$files"
      for cfg in "${cfgs[@]}"; do args+=(-f "$cfg"); done
      dir="$(dirname "$first")"
      # shellcheck disable=SC2086  # svcs is a space-separated list of names
      if [ "$running" = "1" ]; then
        printf '    %s: recreate and start %s\n' "$project" "$svcs"
        run docker compose --project-directory "$dir" -p "$project" "${args[@]}" up -d --no-deps $svcs </dev/null
      else
        printf '    %s: recreate stopped %s\n' "$project" "$svcs"
        run docker compose --project-directory "$dir" -p "$project" "${args[@]}" up --no-start --no-deps $svcs </dev/null
      fi
    done <<< "$plan"
    ok "containers recreated"
  fi
fi

# ------------------------------------------------------------------ leftovers
left=""
for pair in $PAIRS; do
  old="${pair%%:*}"
  [ -d "$ROOT/$old" ] && left="$left $old/"
done
if [ -n "$left" ]; then
  warn "still present (see warnings above):$left"
else
  ok "no old folders left"
fi
[ "$DRY_RUN" -eq 1 ] && info "Dry run finished; run without --dry-run to apply."
if [ -n "$failed" ]; then
  warn "did not restart:$failed"
  exit 1
fi
exit 0
