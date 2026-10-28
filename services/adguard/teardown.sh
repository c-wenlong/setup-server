#!/usr/bin/env bash
#
# teardown.sh — take AdGuard Home off this box. Linux + macOS.
#
# ---------------------------------------------------------------------------
# THIS ONE CAN TAKE DNS DOWN FOR THE WHOLE TAILNET
#
# If this node's tailnet IP is a nameserver in the Tailscale admin console
# (DNS -> Nameservers, the manual step setup.sh ends with), every device on
# the tailnet sends its DNS here. Stop AdGuard while that is still true and
# they all stop resolving, wherever they are. This script cannot change the
# admin console, so it refuses to stop anything until the tailnet no longer
# points here. Order:
#   1. https://login.tailscale.com/admin/dns -> remove this node's IP
#   2. check from another device that names still resolve
#   3. then ./teardown.sh
#
# The gate is a read-only `tailscale dns status --json`: the DNS config
# control hands this node (the same config every device gets, independent
# of this node's --accept-dns). If this node's tailnet address is in its
# Resolvers, FallbackResolvers, SplitDNSRoutes or Nameservers, teardown
# stops, flag or no flag. If the answer cannot be read (tailscaled down, no
# netmap, a CLI without `dns status --json`, a shape it does not recognise),
# teardown also stops, unless you pass --dns-removed to say you did step 1
# and 2 yourself. The launcher's Remove passes no flags, so it works only
# when the check can prove the tailnet no longer points here.
# ---------------------------------------------------------------------------
#
# Then the inverse of setup.sh's run + publish, and nothing more:
#   1. unpublish the Tailscale Serve ports that point at THIS service's web
#      UI, found from `tailscale serve status` (never `serve reset`)
#   2. `docker compose down`: the container goes, and with it the resolver
#      on <tailnet-ip>:53 (that listener is the container's port publish,
#      not a Serve mapping). conf/ and work/ stay
#   3. keep .env, conf/ and work/, so ./setup.sh brings it back as it was
#
# Usage:
#   ./teardown.sh                  # safe remove: config and .env kept
#   ./teardown.sh --dns-removed    # same, when the DNS check cannot tell and
#                                  # you have removed the nameserver yourself
#   ./teardown.sh --purge          # ALSO delete conf/ (the whole AdGuard
#                                  # configuration), work/ (query log,
#                                  # statistics, blocklists) and .env; asks
#                                  # you to type "adguard" first. Terminal
#                                  # only: the launcher never passes it.
#   (--purge and --dns-removed combine.)
#   ./teardown.sh --check-dns      # read-only: run the preflight and the DNS
#                                  # gate above, change nothing, exit 0 only
#                                  # when the tailnet provably no longer uses
#                                  # this node for DNS. The launcher and
#                                  # ntfy-control run it before Stop (it is
#                                  # adguard's `stop_guard` in app.json).
#                                  # Takes no other flag.
#
# Reads ports and paths from .env and refuses to guess when it is missing.
# Idempotent: re-running on a removed service changes nothing.

set -euo pipefail

NAME="adguard"
SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"

# shellcheck source=../../lib/common.sh
. "$SERVICE_DIR/../../lib/common.sh"

USAGE="usage: ./teardown.sh [--purge] [--dns-removed] | --check-dns"
PURGE=0
DNS_ACK=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --purge)
      [ "$PURGE" -eq 0 ] || die "--purge given twice ($USAGE)"
      PURGE=1 ;;
    --dns-removed)
      [ "$DNS_ACK" -eq 0 ] || die "--dns-removed given twice ($USAGE)"
      DNS_ACK=1 ;;
    --check-dns)
      [ "$#" -eq 1 ] || die "--check-dns takes no other option ($USAGE)"
      CHECK=1 ;;
    *) die "Unknown option: $arg ($USAGE)" ;;
  esac
done

# ---------------------------------------------------------------- preflight
detect_os
info "Preflight checks ($OS)"
refuse_root
[ -f "$ENV_FILE" ] || die "No $ENV_FILE — nothing here was deployed by setup.sh, so there is nothing to tear down (and no paths to trust)."
require_docker_compose
resolve_tailscale

# .env is the authority for ports and paths. Values are read the way Docker
# Compose reads them (an optional `export `, matching single or double quotes,
# an inline ` #` comment after an unquoted value) without executing the file.
env_get() {
  local line value tail quote=""
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENV_FILE" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  tail="${value##*[![:space:]]}"; value="${value%"$tail"}"
  case "$value" in
    \"*) quote='"'; value="${value#\"}"; value="${value%%\"*}" ;;
    \'*) quote="'"; value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="${value%%[[:space:]]#*}"
       tail="${value##*[![:space:]]}"; value="${value%"$tail"}" ;;
  esac
  # Compose interpolates $HOME / ${HOME} in unquoted and double-quoted values
  # (single quotes are literal). That one variable is all a path here may
  # use; anything else is left as written and then fails the path checks.
  if [ "$quote" != "'" ]; then
    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
  fi
  printf '%s' "$value"
}

# Real path of a purge target WITHOUT entering it: a Postgres- or root-owned
# data dir may be unreadable to this user, which is exactly when the purge
# needs the cleanup container. Resolve the parent, append the name. Refused
# (non-zero) unless the result is ~/services/$NAME itself or inside it, with
# ~/services a real directory under $HOME; a symlinked leaf, a `.`/`..`
# component, a newline or a colon (which would split a list or a -v mount)
# is never accepted.
real_dir() {
  local d="$1" parent leaf home services own nl checkout
  nl='
'
  case "$d" in *"$nl"*|*:*) return 1 ;; esac
  case "/$d/" in */./*|*/../*) return 1 ;; esac
  leaf="$(basename "$d")"
  case "$leaf" in ''|.|..) return 1 ;; esac
  [ ! -L "$d" ] || return 1
  parent="$(cd "$(dirname "$d")" && pwd -P)" || return 1
  case "$parent" in *"$nl"*|*:*) return 1 ;; esac
  home="$(cd "$HOME" && pwd -P)" || return 1
  services="$(cd "$HOME/services" && pwd -P)" || return 1
  case "$services" in "$home"/?*) ;; *) return 1 ;; esac
  [ ! -L "$HOME/services/$NAME" ] || return 1
  own="$services/$NAME"
  case "$parent/$leaf" in "$own"|"$own"/*) ;; *) return 1 ;; esac
  # Never a directory that holds this checkout (and so every other service's
  # .env): a repo cloned inside ~/services/<name> must survive a purge.
  checkout="$(cd "$SERVICE_DIR" && pwd -P)" || return 1
  case "$checkout/" in "$parent/$leaf"/*) return 1 ;; esac
  printf '%s/%s' "$parent" "$leaf"
}

# teardown reads .env without running it, so it refuses anything it could
# read differently from Docker Compose: a key set twice, a quoted value that
# does not close on its own line (multi-line values), a backslash escape in
# double quotes, or a line that is not KEY=value. Prints key names only.
env_lint() {
  local problem
  problem="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/\r$/, "", line)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) { print "line " NR " is not KEY=value"; exit }
      key = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1)
      if (seen[key]++) { print key " is set more than once"; exit }
      q = substr(val, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(val, 2); end = index(rest, q)
        if (end == 0) { print "the quoted value of " key " does not close on its line"; exit }
        if (q == "\"" && index(substr(rest, 1, end - 1), "\\") > 0) { print "the value of " key " uses a backslash escape"; exit }
      }
    }' "$ENV_FILE")"
  [ -z "$problem" ] || die "$ENV_FILE: $problem. Fix that line (teardown will not guess how Compose reads it) and re-run."
}
env_lint
LOCAL_PORT="$(env_get LOCAL_PORT)"
CONF_DIR="$(env_get ADGUARD_CONF)"
WORK_DIR="$(env_get ADGUARD_WORK)"
DNS_IP="$(env_get ADGUARD_DNS_IP)"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT in $ENV_FILE is missing or not numeric (got: $LOCAL_PORT)";; esac
TARGET="http://127.0.0.1:$LOCAL_PORT"
ok "$NAME: local :$LOCAL_PORT, resolver ${DNS_IP:-(not set)}:53, conf ${CONF_DIR:-(not set)}, work ${WORK_DIR:-(not set)}"

# Compose reads COMPOSE_FILE / COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES from
# .env and the shell, and any of them would change which stack `down` (and,
# on --purge, `down -v`) acts on. setup.sh never sets them, so refuse rather
# than tear down something it did not start. --check-dns acts on no stack,
# so it skips this and the Serve read below: neither bears on DNS.
[ "$CHECK" -eq 1 ] || for v in COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES; do
  [ -z "$(env_get "$v")" ] && [ -z "$(printenv "$v" 2>/dev/null || true)" ] \
    || die "$v is set (in $ENV_FILE or the shell); setup.sh never sets it, so teardown will not guess which stack or volumes it means. Unset it and re-run."
done

# Read Serve before changing anything: if it cannot be read, an empty answer
# would look like "already off" and the mapping would come back with the
# daemon. Stop instead.
[ "$CHECK" -eq 1 ] || SERVE_STATUS="$("$TAILSCALE" serve status 2>&1)" \
  || die "Could not read Tailscale Serve status (is tailscaled running?): $SERVE_STATUS — nothing was changed."

# ------------------------------------------------------- the DNS gate
# Before ANY change, default and --purge alike. See the header for why.
#
# The addresses a nameserver entry could name: ADGUARD_DNS_IP from .env (the
# value setup.sh told you to type into the console) plus every address
# `tailscale ip` reports now, in case the node's address moved since.
#
# `tailscale dns status --json` is parsed as JSON, not matched as text:
# setup.sh guarantees no JSON tool (python3 is optional there, jq is never
# required), so the awk below is a small strict parser. Anything it does not
# fully understand is "unknown", never "clear":
#   - the whole output must be one valid JSON object, nothing after it, no
#     key twice in any object, no escaped key;
#   - TailscaleDNS a boolean and CurrentTailnet a non-null object (null or
#     missing when logged out);
#   - at least one of the four resolver keys present (the CLI omits empty
#     ones: a live 1.10x node prints Resolvers and SplitDNSRoutes only, and
#     an absent key means none; all four absent is "unknown", so a renamed
#     field never reads as clear), each present one with
#     the type it has in the CLI: Resolvers and FallbackResolvers null or an
#     array of objects with a string Addr, SplitDNSRoutes null or an object
#     whose values are null or such arrays, Nameservers null or an array of
#     strings; no escape sequence in any string under them.
# Then every string under those four keys is checked for this node's
# addresses. A match is a whole address (100.1.2.3 does not match inside
# 100.1.2.33), so 100.x, 100.x:53, [v6]:53, a DoH URL on the IP and a
# BootstrapResolution entry all count.
dns_verdict() {  # dns_verdict -> "listed <Key>"..., "clear", or "unknown"
  local addrs json
  case "$DNS_IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo unknown; return 0 ;;
  esac
  addrs="$DNS_IP $("$TAILSCALE" ip 2>/dev/null | tr '\n\r' '  ' || true)"
  json="$("$TAILSCALE" dns status --json 2>/dev/null)" || { echo unknown; return 0; }
  printf '%s\n' "$json" | awk -v addrs="$addrs" '
    function has_addr(str, a,   s, p, before, after, cls) {
      cls = index(a, ":") ? "[0-9a-f:]" : "[0-9.]"
      s = tolower(str)
      while ((p = index(s, a)) > 0) {
        before = (p > 1) ? substr(s, p - 1, 1) : ""
        after = substr(s, p + length(a), 1)
        if (before !~ cls && after !~ cls) return 1
        s = substr(s, p + 1)
      }
      return 0
    }
    function bad() { err = 1; return "" }
    function skipws(   c) {
      while (pos <= len) {
        c = substr(src, pos, 1)
        if (c != " " && c != "\t" && c != "\n" && c != "\r") return
        pos++
      }
    }
    # A JSON string starting at pos. Returns its raw text; esc says whether
    # it held an escape sequence.
    function pstr(   c, out) {
      esc = 0
      if (substr(src, pos, 1) != "\"") return bad()
      pos++; out = ""
      while (pos <= len) {
        c = substr(src, pos, 1)
        if (c == "\"") { pos++; return out }
        if (c == "\n" || c == "\r" || c == "\t") return bad()
        if (c == "\\") {
          esc = 1; c = substr(src, pos + 1, 1)
          if (c == "u") {
            if (substr(src, pos + 2, 4) !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) return bad()
            out = out substr(src, pos, 6); pos += 6; continue
          }
          if (index("\"\\/bfnrt", c) == 0 || c == "") return bad()
          out = out "\\" c; pos += 2; continue
        }
        out = out c; pos++
      }
      return bad()
    }
    # The JSON value at pos, recorded under path: T[path] its type, V and E
    # its text and escape flag (strings), N[path] its length (arrays,
    # objects), K[path, i] the i-th key (objects). Returns the type, or ""
    # with err set.
    function pval(path, depth,   c, k, n, child) {
      if (err) return ""
      if (depth > 32) return bad()
      skipws()
      c = substr(src, pos, 1)
      if (c == "{") {
        pos++; n = 0; skipws()
        if (substr(src, pos, 1) == "}") pos++
        else while (1) {
          skipws(); k = pstr()
          if (err || esc || index(k, SEP)) return bad()
          child = path SEP k
          if (child in T) return bad()
          T[child] = "pending"; K[path, ++n] = k
          skipws()
          if (substr(src, pos, 1) != ":") return bad()
          pos++
          if (pval(child, depth + 1) == "") return bad()
          skipws(); c = substr(src, pos, 1); pos++
          if (c == "}") break
          if (c != ",") return bad()
        }
        N[path] = n; T[path] = "object"; return "object"
      }
      if (c == "[") {
        pos++; n = 0; skipws()
        if (substr(src, pos, 1) == "]") pos++
        else while (1) {
          n++
          if (pval(path SEP n, depth + 1) == "") return bad()
          skipws(); c = substr(src, pos, 1); pos++
          if (c == "]") break
          if (c != ",") return bad()
        }
        N[path] = n; T[path] = "array"; return "array"
      }
      if (c == "\"") {
        V[path] = pstr(); E[path] = esc
        if (err) return ""
        T[path] = "string"; return "string"
      }
      if (substr(src, pos, 4) == "true" || substr(src, pos, 4) == "null") {
        T[path] = (substr(src, pos, 4) == "null") ? "null" : "bool"
        pos += 4; return T[path]
      }
      if (substr(src, pos, 5) == "false") { pos += 5; T[path] = "bool"; return "bool" }
      if (match(substr(src, pos), /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) {
        pos += RLENGTH; T[path] = "number"; return "number"
      }
      return bad()
    }
    # null, or an array of objects that each have a string Addr.
    function resolver_list(p,   i) {
      if (T[p] == "null") return 1
      if (T[p] != "array") return 0
      for (i = 1; i <= N[p]; i++) {
        if (T[p SEP i] != "object" || T[p SEP i SEP "Addr"] != "string") return 0
      }
      return 1
    }
    # An absent key is how the CLI says "none" (omitempty); at least one must be
    # there, so output whose fields were all renamed is never clear.
    function shape_ok(   p, i, seen) {
      seen = 0
      p = R SEP "Resolvers"
      if (p in T) { seen++; if (!resolver_list(p)) return 0 }
      p = R SEP "FallbackResolvers"
      if (p in T) { seen++; if (!resolver_list(p)) return 0 }
      p = R SEP "SplitDNSRoutes"
      if (p in T) {
        seen++
        if (T[p] == "object") {
          for (i = 1; i <= N[p]; i++) if (!resolver_list(p SEP K[p, i])) return 0
        } else if (T[p] != "null") return 0
      }
      p = R SEP "Nameservers"
      if (p in T) {
        seen++
        if (T[p] == "array") {
          for (i = 1; i <= N[p]; i++) if (T[p SEP i] != "string") return 0
        } else if (T[p] != "null") return 0
      }
      return (seen > 0)
    }
    BEGIN {
      SEP = "\034"; R = "$"; n = 0
      split(addrs, raw, " ")
      for (i in raw) if (raw[i] ~ /^[0-9a-fA-F:.]+$/ && raw[i] ~ /[.:]/) want[++n] = tolower(raw[i])
    }
    { src = (NR == 1) ? $0 : src "\n" $0 }
    END {
      len = length(src); pos = 1; err = 0
      if (pval(R, 0) != "object") { print "unknown"; exit }
      skipws()
      if (pos <= len || n == 0 || T[R SEP "TailscaleDNS"] != "bool" || T[R SEP "CurrentTailnet"] != "object" || !shape_ok()) { print "unknown"; exit }
      split("Resolvers FallbackResolvers SplitDNSRoutes Nameservers", keys, " ")
      h = 0
      for (j = 1; j <= 4; j++) {
        prefix = R SEP keys[j] SEP; found = 0
        for (p in T) {
          if (T[p] != "string" || index(p, prefix) != 1) continue
          if (E[p]) { print "unknown"; exit }
          for (i = 1; i <= n; i++) if (has_addr(V[p], want[i])) found = 1
        }
        if (found) order[++h] = keys[j]
      }
      if (h == 0) { print "clear"; exit }
      for (i = 1; i <= h; i++) print "listed " order[i]
    }'
}

DNS_ADMIN="https://login.tailscale.com/admin/dns"
info "Checking that the tailnet no longer uses ${DNS_IP:-this node} as its DNS nameserver"
DNS_SHOWN="${DNS_IP:-the tailnet IP in .env}"
warn "AdGuard answers DNS on $DNS_SHOWN:53. If that address is still a nameserver in"
warn "  $DNS_ADMIN, stopping it takes DNS down for EVERY device on the tailnet."
warn "  First remove $DNS_SHOWN there (DNS -> Nameservers), check another device still resolves, then re-run."
VERDICT="$(dns_verdict)"
case "$VERDICT" in
  listed*)
    where="$(printf '%s\n' "$VERDICT" | sed -n 's/^listed //p' | tr '\n' ' ' | sed 's/ $//')"
    NO_OVERRIDE=" --dns-removed does not override this: the tailnet itself still says so."
    [ "$CHECK" -eq 0 ] || NO_OVERRIDE=""
    die "The tailnet still uses ${DNS_IP} for DNS (tailscale dns status lists it under: $where). Remove it at $DNS_ADMIN -> Nameservers (and any split DNS entry for it), confirm another device resolves, then re-run.$NO_OVERRIDE Nothing was changed."
    ;;
  clear)
    ok "Not a tailnet nameserver (tailscale dns status lists ${DNS_IP} nowhere)"
    ;;
  *)
    RETRY_PURGE=""; [ "$PURGE" -eq 0 ] || RETRY_PURGE=" --purge"
    if [ "$CHECK" -eq 1 ]; then
      die "Could not tell whether the tailnet still uses ${DNS_IP:-this node} for DNS (tailscale dns status --json was unreadable: tailscaled down, logged out, or an older CLI). Nothing was changed. Remove the nameserver at $DNS_ADMIN, confirm another device resolves, then stop it from a terminal: docker stop $NAME"
    elif [ "$DNS_ACK" -eq 1 ]; then
      warn "Could not read the tailnet DNS config from this node; going ahead on your --dns-removed."
    else
      die "Could not tell whether the tailnet still uses ${DNS_IP:-this node} for DNS (tailscale dns status --json was unreadable: tailscaled down, logged out, or an older CLI). Nothing was changed. Remove the nameserver at $DNS_ADMIN, confirm another device resolves, then run: ./teardown.sh --dns-removed$RETRY_PURGE"
    fi
    ;;
esac
warn "Any device whose DNS was set to ${DNS_IP:-this IP} by hand (not through Tailscale) stops resolving too."
if [ "$CHECK" -eq 1 ]; then
  ok "DNS check passed: the tailnet does not use $NAME for DNS, so stopping it is safe. Nothing was changed."
  exit 0
fi

# Units and LaunchAgents: setup.sh installs none (Docker's restart policy
# keeps AdGuard up), so teardown never touches one. A unit that mentions
# AdGuard came from somewhere else; name it so it is not a surprise.
for unit_dir in "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents"; do
  [ -d "$unit_dir" ] || continue
  others="$( { find "$unit_dir" -iname '*adguard*' 2>/dev/null; grep -rils -- adguard "$unit_dir" 2>/dev/null; } | sort -u || true)"
  [ -z "$others" ] || warn "Not created by setup.sh, so left alone: $(printf '%s' "$others" | tr '\n' ' ')"
done

# --purge confirmation comes before anything changes, so a mistyped name
# leaves the service exactly as it was. What goes is what setup.sh made and
# the container wrote: the conf/ and work/ named in .env (the .env paths are
# the authority, not the default names), then .env.
PURGE_DIRS=()
if [ "$PURGE" -eq 1 ]; then
  root=""
  for var in ADGUARD_CONF ADGUARD_WORK; do
    dir="$(env_get "$var")"
    [ -n "$dir" ] || die "$var is missing from $ENV_FILE — refusing to guess what to delete."
    while :; do case "$dir" in */) dir="${dir%/}" ;; *) break ;; esac; done
    case "$dir" in *..*) die "$var=$dir contains '..' — refusing." ;; esac
    case "$dir" in
      "$HOME/services/"?*) ;;
      *) die "$var=$dir is not a folder inside $HOME/services/ — refusing to delete it. Remove it by hand if you are sure." ;;
    esac
    # And where it really is, symlinks and all: ~/services/adguard itself or
    # inside it, never another service's folder or anything above.
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    [ -d "$dir" ] || die "$var=$dir is not a directory — refusing."
    [ -n "$root" ] || root="$(cd "$HOME/services" && pwd -P)" || die "Cannot resolve $HOME/services."
    real="$(real_dir "$dir")" || die "$var=$dir is not a real directory inside $HOME/services/$NAME, or it holds this checkout — refusing."
    case "$real" in
      "$root"/?*) ;;
      *) die "$var=$dir resolves to $real, which is not a folder inside $root — refusing." ;;
    esac
    PURGE_DIRS+=("$real")
  done
  if [ -n "${PURGE_DIRS[*]+x}" ]; then
    warn "--purge deletes ${PURGE_DIRS[*]} and $ENV_FILE. This cannot be undone."
  else
    warn "--purge deletes nothing on disk (no conf/ or work/ there) and $ENV_FILE. This cannot be undone."
  fi
  warn "That is the whole AdGuard configuration: admin login, upstreams, blocklists, custom rules,"
  warn "  per-client settings, and the query log. To keep the config, press Ctrl-C now and run:"
  warn "  sudo cp ${CONF_DIR:-ADGUARD_CONF}/AdGuardHome.yaml ~/AdGuardHome-\$(date +%F).yaml"
  printf 'Type %s to confirm: ' "$NAME"
  answer=""
  read -r answer || true
  [ "$answer" = "$NAME" ] || die "Confirmation did not match; nothing was changed."
fi

# ------------------------------------------------------- tailscale serve
# Every HTTPS port whose handlers all proxy to this service's local port, and
# nothing else: ports are found from what Serve actually publishes, not from
# what .env says was published (a re-run can publish a second port). A port
# shared with another handler (e.g. :443 with the launcher's /home) is left
# alone with a warning. Never `serve reset`.
info "Unpublishing Tailscale Serve ports that point at $TARGET"
SERVE_PLAN="$(printf '%s\n' "$SERVE_STATUS" | awk -v t="$TARGET" '
  function flush() {
    if (port != "") {
      if (n > 0 && mine == n) print "off " port
      else if (mine > 0) print "mixed " port
    }
    port = ""; n = 0; mine = 0
  }
  index($0, "https://") == 1 {
    flush()
    u = $1; sub(/\/$/, "", u)
    port = match(u, /:[0-9]+$/) ? substr(u, RSTART + 1) : "443"
    next
  }
  port != "" && /\|-- / { n++; if (/ proxy / && $NF == t) mine++ }
  END { flush() }')"
unpublished=0
while read -r verdict port; do
  [ -n "${verdict:-}" ] || continue
  if [ "$verdict" = "off" ]; then
    "$TAILSCALE" serve --https="$port" off >/dev/null
    ok "Tailscale Serve: HTTPS :$port off"
    unpublished=$((unpublished + 1))
  else
    warn "HTTPS :$port also serves something else, so it is left on. Drop this service's path from it by hand."
  fi
done <<EOF
$SERVE_PLAN
EOF
[ "$unpublished" -gt 0 ] || ok "Nothing on Tailscale Serve points at $TARGET (already off)"

# ---------------------------------------------------------------- stop
# Plain `down` on both paths: the compose file uses bind mounts only, so
# there is no named or anonymous volume for `-v` to reach.
info "Stopping and removing the container (docker compose down); the resolver on ${DNS_IP:-the tailnet IP}:53 goes with it"
docker compose --project-directory "$SERVICE_DIR" down
ok "Container removed; config in ${CONF_DIR:-ADGUARD_CONF} and ${WORK_DIR:-ADGUARD_WORK} kept"

# ---------------------------------------------------------------- purge
if [ "$PURGE" -eq 1 ]; then
  info "Purging config and data"
  for d in ${PURGE_DIRS[@]+"${PURGE_DIRS[@]}"}; do
    [ -e "$d" ] || continue        # conf/ and work/ may nest or coincide
    # The container runs as root, so the files inside are root-owned and a
    # plain rm fails on them. Try it first (a dir that never booted is all
    # yours); otherwise empty it with a throwaway container of the pinned
    # image already on this box (no pull, no sudo), then remove the empty
    # dir. A half-deleted conf/ is a failure, not a warning: AdGuard would
    # come back up on half a config.
    rm -rf -- "$d" 2>/dev/null || true
    if [ -e "$d" ]; then
      info "Some files in $d are root-owned; clearing them with the pinned image"
      AG_VERSION="$(env_get ADGUARD_VERSION)"
      AG_IMAGE="adguard/adguardhome:${AG_VERSION:-v0.107.79}"
      docker run --rm --pull never -v "$d:/x" --entrypoint sh "$AG_IMAGE" \
        -c 'find /x -mindepth 1 -delete' >/dev/null 2>&1 \
        || die "Could not clear root-owned files in $d. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
      rm -rf -- "$d" 2>/dev/null || true
      [ ! -e "$d" ] || die "$d is still there. Run: sudo rm -rf $d   then ./teardown.sh --purge again. .env was kept."
    fi
    ok "Deleted $d"
  done
  rm -f -- "$ENV_FILE"
  # ~/services/<name> is the launcher's install marker (and setup.sh's
  # $STATE). Try it even when the data was already gone, so a purged app
  # never reads as installed; rmdir only ever removes an empty directory.
  [ -L "$HOME/services/$NAME" ] || rmdir -- "$HOME/services/$NAME" 2>/dev/null || true
  [ ! -e "$HOME/services/$NAME" ] || warn "Kept $HOME/services/$NAME (not empty, or a symlink): remove by hand if nothing in it is yours."
  ok "Deleted $ENV_FILE"
fi

echo
if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;32mDone.\033[0m %s is removed and its config is gone. ./setup.sh starts fresh.\n' "$NAME"
else
  printf '\033[1;32mDone.\033[0m %s is removed. Config and .env are kept; ./setup.sh brings it back.\n' "$NAME"
  echo "  Delete the config too: ./teardown.sh --purge"
fi
echo "  Uptime Kuma will now report it down. The launcher's Remove pauses the web UI"
echo "  monitor for you, not the adguard-dns one; pause that in Kuma."
exit 0
