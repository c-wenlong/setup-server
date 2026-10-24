#!/usr/bin/env bash
#
# Tests for services/home-assistant/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services: the real script runs from a sandbox copy
# with PATH stubs for docker/tailscale/curl/sudo/id/sleep/ss/timedatectl. The
# curl stub fakes the Home Assistant onboarding surface — GET /api/onboarding
# readiness (including a real refused-connection window), POST
# /api/onboarding/users with its 403 "User step already done" re-run path, the
# single-use /auth/token exchange, and the analytics opt-out — and records every
# call so ordering can be asserted.
#
# THE CASE THIS SUITE EXISTS FOR is test_config_written_before_first_boot.
# Home Assistant turns what it finds in configuration.yaml at *its first start*
# into config entries under .storage/, and .storage wins from then on. A
# setup.sh that starts the container and then writes the config produces a
# deploy that reports success while the reverse-proxy settings and the
# Bluetooth exclusion silently never took effect. Asserting that the file
# exists when the run finishes would not catch that, so the docker stub
# snapshots the sandbox at `compose up` time and the assertions are made
# against that snapshot.
#
# Sandbox guarantee: every mocked test runs with HOME pointed at a temp dir, so
# nothing touches ~/services/home-assistant or the real .env. The suite proves
# it rather than claiming it: host_fingerprint() cksums the whole service
# directory and ~/services/home-assistant before and after the run and the last
# test compares them.
#
# ---------------------------------------------------------------------------
# MUTATION RESULTS — what this suite was proven to catch, not just to assert.
# Each mutation was applied to a throwaway copy of the service directory; the
# number is how many checks went red.
#
#   M1  configuration.yaml written AFTER `compose up`          CAUGHT (21)
#   M2  `bluetooth:` back in the component list                CAUGHT (3)
#   M3  `use_x_forwarded_for: true` removed                    CAUGHT (1)
#   M4  image tag floated to :stable                           CAUGHT (4)
#   M5  core_config auto-completed                             CAUGHT (6)
#   M6  403 "User step already done" treated as fatal          CAUGHT (3)
#   M7  readiness rejects the 404 shape                        CAUGHT (6)
#   M8  auth_code exchanged twice                              CAUGHT (9)
#   M9  network_mode: host removed from compose                CAUGHT (1)
#   M10 server_host flipped to 0.0.0.0                         CAUGHT (4)
#   M11 readiness dies on a refused connection (000)           CAUGHT (7)
#   M12 .storage/http seeded AFTER `compose up`                CAUGHT (11)
#   M13 a staged `pending` seeded instead of null              CAUGHT (11)
#   M14 yaml_migration_done seeded false                       CAUGHT (1)
#   M15 repair gate loosened to ignore an unfailed pending     CAUGHT (4)
#   M16 server_host seeded as a string, not a list             CAUGHT (15)
#   M17 the `pending` KEY omitted entirely                     CAUGHT (1)
#   M18 trusted_proxies as bare addresses, not CIDR            CAUGHT (3)
#
# M17 was NOT caught the first time it was tried: the assertion read
# `d.get("pending") is None`, which is satisfied both by a correct null and by
# the key being absent — and an absent key is `KeyError: 'pending'` inside HA,
# a total outage. The check "...but the 'pending' KEY is present" exists
# because of that miss. M15 is the regression guard for a real dead-end bug
# this suite found: when the repair gate and the final verification disagreed
# about a staged pending, the run failed and told you to re-run, forever.
#
# If you change setup.sh in a way that makes one of those stop failing, the
# suite has lost the assertion it existed for. Re-run the mutations.
# ---------------------------------------------------------------------------

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"

PASS=0; FAIL=0
ORIG_HOME="$HOME"
OS="$(uname -s)"   # the mocked suite exercises the current platform's branch
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# default_config's dependency list in the 2026.9.1 image, read out of
# default_config/manifest.json, minus TWO entries. Alphabetical, because the
# assertion sorts. If a future image adds a dependency, this line and
# configuration.yaml move together — that is the maintenance cost of not using
# `default_config:`, and it is deliberate.
#
# The two omissions, both measured against this exact image on this box:
#
#   bluetooth — the host's bluetoothd owns hci0, HA loses the fight for the
#               adapter and logs "Failed to force stop scanner" 24x/minute
#               forever. cap_add NET_ADMIN/NET_RAW + /run/dbus does NOT fix it.
#   go2rtc    — loading it starts a go2rtc process that opens tcp6 :::18555
#               (WebRTC), i.e. EVERY interface. Under network_mode: host that
#               is the host's LAN and tailnet, with no TLS and no Serve in
#               front of it. Verified twice, in a bridge-networked throwaway
#               of ghcr.io/home-assistant/home-assistant:2026.9.1:
#                 with    go2rtc: -> 127.0.0.1:18554, 127.0.0.1:8123, :::18555
#                 without go2rtc: -> 127.0.0.1:8123 and nothing else
#               `stream:` stays, so cameras still work over HLS.
#
# So 19 of 21. Note this contradicts the pre-deploy de-risking notes (not kept
# in this repo), which listed 20 — that measurement only ran
# `ss -ltn | grep 8123` and so could not have seen 18555.
WANT_COMPONENTS="assist_pipeline cloud conversation dhcp energy file history homeassistant_alerts logbook media_source mobile_app my ssdp stream sun usage_prediction usb webhook zeroconf"
WANT_COMPONENT_COUNT=19

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" \
     "$SERVICE_DIR/configuration.yaml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT HTTPS_PORT HA_ADMIN_USER STUB_TZ \
        STATE_DIR CALLS_LOG
}

run_deploy() {
  OUT="$(printf '%s' "${1:-}" | PATH="$STUBS:$PATH" bash "$SVC/setup.sh" 2>&1)"
  CODE=$?
}

check() {
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

out_has()    { grep -q "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi "$1" <<<"$OUT"; }
# A run that reports a staged pending AND tells you to re-run setup.sh is a
# dead end: the re-run reaches the same verdict. Either it repairs the store or
# it must say something that actually helps.
not_a_rerun_loop() {
  ! { grep -q "a pending config is staged" <<<"$OUT" \
      && grep -q "Re-run ./setup.sh" <<<"$OUT"; }
}
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
env_has()    { grep -q "$1" "$SVC/.env"; }
# .env values are double-quoted, so a path or zone containing a space survives
# `. "$ENV_FILE"`. Strip the quotes here rather than in every assertion.
env_val()    { sed -n "s/^$1=//p" "$SVC/.env" | sed 's/^"//; s/"$//'; }
# .env explains at length why the version is pinned and must not float to
# `stable`, so assertions about the values have to ignore the prose.
env_body()   { sed 's/#.*//' "$SVC/.env"; }

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

LIVE_CONFIG_PATH() { printf '%s' "$HOME/services/home-assistant/config/configuration.yaml"; }

# ---- assertions against the config as it stood AT THE FIRST `compose up` ----
# The docker stub copies it there. Its absence IS the failure: it means the
# container was started before the file existed.
BOOT_CFG() { printf '%s' "$STATE_DIR/config_at_compose_up.yaml"; }

boot_cfg_exists() { [ -f "$(BOOT_CFG)" ]; }

# ---- the same, for the store that ACTUALLY decides the bind on 2026.9+ -----
# `http:` in configuration.yaml is migrated into .storage/http exactly once,
# into a `pending` trial that reverts to the defaults — wildcard bind, no
# proxy trust — unless a human promotes it in the UI. Nothing in an unattended
# deploy promotes it. So these assertions moved off the YAML and onto the
# store, and the YAML deliberately carries no `http:` block at all.
BOOT_HTTP() { printf '%s' "$STATE_DIR/http_at_compose_up.json"; }

boot_http_exists() { [ -f "$(BOOT_HTTP)" ]; }

# Query the seeded store with python3 (already required by the harness).
# EXPR is evaluated against `d` = the file's "data" dict; prints True/False.
boot_http_is() {  # boot_http_is EXPR
  boot_http_exists || return 1
  python3 - "$(BOOT_HTTP)" "$1" <<'PY' 2>/dev/null | grep -qx True
import json, sys
try:
    d = json.load(open(sys.argv[1]))["data"]
except Exception:
    print("False"); raise SystemExit
s = d.get("stable") or {}
print(str(bool(eval(sys.argv[2]))))
PY
}

# Comments stripped, always. configuration.yaml documents at length what it
# deliberately does NOT do (a whole block about `bluetooth`, `default_config:`
# and cap_add), so a naive grep matches the prose instead of the config.
boot_cfg()      { sed 's/#.*//' "$(BOOT_CFG)" 2>/dev/null; }
boot_cfg_has()  { boot_cfg | grep -qE -- "$1"; }
boot_cfg_lacks(){ ! boot_cfg_has "$1"; }

# The top-level component keys the instance booted with, sorted, space-joined.
boot_components() {
  boot_cfg \
    | sed -n 's/^\([a-z_][a-z_0-9]*\):[[:space:]]*$/\1/p' \
    | grep -v -x -e homeassistant -e http \
    | sort | tr '\n' ' ' | sed 's/ $//'
}

# ---- static assertions on docker-compose.yml, comments stripped ------------
# Same reason: the compose file explains at length why it has no `ports:`
# block, no `privileged: true` and no `/run/dbus` mount.
compose()       { sed 's/#.*//' "$SVC/docker-compose.yml"; }
compose_has()   { compose | grep -qE -- "$1"; }
compose_hasF()  { compose | grep -qF -- "$1"; }
compose_lacks() { ! compose_has "$1"; }


# Write a .storage/http into the sandbox with a given `stable` override and
# `pending` value, to model an instance HA has already booted in.
#   seed_store <stable-json-overrides> <pending-json>
seed_store() {
  mkdir -p "$HOME/services/home-assistant/config/.storage"
  python3 - "$HOME/services/home-assistant/config/.storage/http" "$1" "$2" <<'SEEDPY'
import json, sys
stable = {"server_host": ["127.0.0.1"], "server_port": 8123,
          "cors_allowed_origins": ["https://cast.home-assistant.io"],
          "use_x_forwarded_for": True,
          "trusted_proxies": ["127.0.0.1/32", "::1/128"],
          "login_attempts_threshold": -1, "ip_ban_enabled": True,
          "ssl_profile": "modern", "use_x_frame_options": True,
          "created_at": "2026-09-10T18:48:23.030301+00:00",
          "error": None, "error_message": None}
stable.update(json.loads(sys.argv[2]))
json.dump({"version": 2, "minor_version": 2, "key": "http",
           "data": {"stable": stable, "pending": json.loads(sys.argv[3]),
                    "yaml_migration_done": True}},
          open(sys.argv[1], "w"), indent=2)
SEEDPY
}

# Read one field back out of the sandbox store. EXPR is evaluated with `d` =
# the data dict and `s` = data["stable"]; the repr is printed.
store_field() {  # store_field EXPR
  python3 - "$HOME/services/home-assistant/config/.storage/http" "$1" <<'FIELDPY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["data"]
s = d.get("stable") or {}
print(repr(eval(sys.argv[2])))
FIELDPY
}

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "explains the problem"     out_has "regular user"
  check "wrote no .env"            [ ! -f "$SVC/.env" ]
  check "started no container"     [ ! -f "$STATE_DIR/compose_up" ]
  check "wrote no configuration.yaml" [ ! -f "$(LIVE_CONFIG_PATH)" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when the user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests usermod fix"  out_has "usermod -aG docker"
    check "mentions sg docker"    out_has "sg docker"
  else
    check "suggests Docker Desktop" out_has "Docker Desktop"
    check "names the daemon"        out_has "Docker daemon"
  fi
  check "wrote no .env" [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Tailscale is not up"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_bad_port() {
  echo "• preflight rejects non-numeric ports"
  setup
  export HTTPS_PORT=abc
  run_deploy
  check "HTTPS_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "HTTPS_PORT: says numeric"   out_has "must be numeric"
  unset HTTPS_PORT
  export LOCAL_PORT=81o3
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "must be numeric"
  check "wrote no .env"              [ ! -f "$SVC/.env" ]
  teardown
}

test_preflight_bad_username() {
  echo "• preflight rejects an admin username that would break the JSON body"
  # The username is interpolated into {"username":"..."} with printf, not
  # escaped, and that body creates the OWNER account.
  setup
  export HA_ADMIN_USER='kai" ,"x'
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "names the allowed set" out_has "A-Za-z0-9._-"
  check "wrote no .env"         [ ! -f "$SVC/.env" ]
  check "created no account"    no_call "/api/onboarding/users"
  teardown
}

test_preflight_missing_template() {
  echo "• preflight refuses to deploy without configuration.yaml to render"
  # Starting the container without it is the silent-failure case; better to
  # die in preflight than to boot HA with no config at all.
  setup
  rm -f "$SVC/configuration.yaml"
  run_deploy
  check "exits non-zero"           [ "$CODE" -ne 0 ]
  check "names the missing file"   out_has "configuration.yaml"
  check "says why it matters"      out_has "before the container starts"
  check "started no container"     [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

# ===========================================================================
# THE ONE THAT MATTERS MOST
# ===========================================================================
test_config_written_before_first_boot() {
  echo "• configuration.yaml is on disk, fully rendered, BEFORE the first \`compose up\`"
  # Both first-boot-only decisions live in this file. HA persists the config
  # entries discovery creates into .storage/ on that first boot, so a script
  # that starts the container and then writes config has already failed — and
  # the failure is silent. This is asserted against a snapshot the docker stub
  # takes at `up` time, not against the end state of the run.
  setup
  touch "$STATE_DIR/operator"
  run_deploy

  check "configuration.yaml existed at \`compose up\`"  boot_cfg_exists
  check "  it was under the sandbox HOME"               grep -q "/services/home-assistant/config/configuration.yaml$" "$STATE_DIR/files_at_compose_up"
  check "  and the container really was started"        [ -f "$STATE_DIR/compose_up" ]

  # Fully rendered — a literal __TIMEZONE__ would make HA refuse to start.
  check "  no unsubstituted __PLACEHOLDER__ markers"    boot_cfg_lacks '__[A-Z_]+__'
  check "  timezone came from the host"                 boot_cfg_has '^ *time_zone: *Asia/Singapore *$'

  # The reverse-proxy trio. Without the last two HA answers 400 to every
  # request that arrives through Tailscale Serve. These live in .storage/http,
  # NOT in the YAML — and the store has to be right at `up` time, because
  # nothing promotes a pending trial in an unattended deploy.
  check "  .storage/http seeded before the container started" boot_http_exists
  check "  http.server_host is 127.0.0.1"               boot_http_is 's.get("server_host") == ["127.0.0.1"]'
  check "  http.server_port matches LOCAL_PORT"         boot_http_is 's.get("server_port") == 8123'
  check "  use_x_forwarded_for: true"                   boot_http_is 's.get("use_x_forwarded_for") is True'
  check "  trusted_proxies lists 127.0.0.1"             boot_http_is '"127.0.0.1/32" in (s.get("trusted_proxies") or [])'
  check "  trusted_proxies lists ::1"                   boot_http_is '"::1/128" in (s.get("trusted_proxies") or [])'
  # No pending trial to revert to the wildcard defaults five minutes later,
  # and the YAML marked migrated so a stray http: block can never re-migrate.
  check "  no pending trial waiting to revert"          boot_http_is 'd.get("pending") is None'
  # ...but the key itself MUST be present. HA does `raw[KEY_PENDING]`
  # unconditionally, so omitting it is not "no pending", it is
  # `KeyError: 'pending'` and the whole http component fails to set up — the
  # same total outage as a wildcard bind, with a different message. A
  # `.get()`-based check passes for both, which is why this one is separate.
  check "  ...but the 'pending' KEY is present"         boot_http_is '"pending" in d'
  check "  stable.server_host is a LIST, not a string"  boot_http_is 'isinstance(s.get("server_host"), list)'
  check "  trusted_proxies are CIDR"                    boot_http_is 'all("/" in x for x in s.get("trusted_proxies") or ["x"])'
  check "  yaml_migration_done is true"                 boot_http_is 'd.get("yaml_migration_done") is True'
  check "  binds nothing to 0.0.0.0"                    boot_cfg_lacks '0\.0\.0\.0'
  # And the YAML carries no http: block at all — one is ignored since 2026.9
  # and raises a yaml_still_present_after_migration repair notice in the UI.
  check "  configuration.yaml has no http: block"       boot_cfg_lacks '^http:'

  # The bluetooth exclusion, also first-boot-only.
  check "  bluetooth is NOT enabled"                    boot_cfg_lacks '^bluetooth:'
  check "  default_config: is NOT used"                 boot_cfg_lacks '^default_config:'
  # go2rtc opens tcp6 :::18555 — every interface — under host networking.
  check "  go2rtc is NOT enabled"                       boot_cfg_lacks '^go2rtc:'
  check "  but stream: still is (HLS cameras work)"     boot_cfg_has '^stream:'
  check "  the component list is default_config minus bluetooth and go2rtc" \
    [ "$(boot_components)" = "$WANT_COMPONENTS" ]
  check "  ...which is $WANT_COMPONENT_COUNT components" \
    [ "$(boot_components | wc -w)" -eq "$WANT_COMPONENT_COUNT" ]

  # Nothing rewrote it behind the container's back afterwards.
  check "  the live file is byte-identical to what booted" \
    cmp -s "$(BOOT_CFG)" "$(LIVE_CONFIG_PATH)"

  check "run announced the ordering"                    out_has "BEFORE the first boot"
  teardown
}

test_host_network_and_loopback_travel_together() {
  echo "• network_mode: host and the loopback bind are shipped as a pair"
  # Host mode is what makes discovery work; server_host is the only thing
  # stopping it from putting plain HTTP on every interface. Either alone is a
  # broken deploy — host mode without the bind is a LAN leak, the bind without
  # host mode is an HA that cannot see any of your devices.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "compose uses network_mode: host"    compose_has '^ *network_mode: *host *$'
  check "  and declares no ports: block"     compose_lacks '^ *ports: *$'
  check "  and no 0.0.0.0 anywhere"          compose_lacks '0\.0\.0\.0'
  check "config binds 127.0.0.1 at boot"     boot_http_is 's.get("server_host") == ["127.0.0.1"]'
  check "the pair is documented in the run"  out_has "127.0.0.1:8123"
  teardown
}

test_image_is_pinned() {
  echo "• the image tag is pinned, not :stable"
  # :stable moves monthly and HA ships breaking changes in point releases.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "compose interpolates HA_VERSION"  compose_hasF 'image: ghcr.io/home-assistant/home-assistant:${HA_VERSION'
  check "  with a pinned default"          compose_has 'HA_VERSION:-2026\.9\.1'
  check "  and never :stable"              compose_lacks ':stable'
  check ".env pins the version"            [ "$(env_val HA_VERSION)" = "2026.9.1" ]
  check ".env's values never say stable"   ! env_body | grep -q 'stable'
  check "no :latest either"                compose_lacks ':latest'
  teardown
}

test_compose_privilege_surface() {
  echo "• compose grants no privilege beyond host networking"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # Upstream's example sets privileged: true for USB radios and Bluetooth.
  # Nothing here needs it, and the whole point of excluding bluetooth is that
  # capabilities do not fix the adapter fight anyway.
  check "not privileged"             compose_lacks 'privileged'
  check "no NET_ADMIN/NET_RAW"       compose_lacks 'cap_add'
  check "no /run/dbus mount"         compose_lacks '/run/dbus'
  check "restart policy unless-stopped" compose_has 'restart: *unless-stopped'
  check "container name is stable"   compose_has 'container_name: *home-assistant'
  check "config dir is the only rw mount" compose_hasF ':/config'
  check "localtime mounted read-only"     compose_hasF '/etc/localtime:/etc/localtime:ro'
  teardown
}

test_fresh_deploy() {
  echo "• fresh deploy: onboarded, published tailnet-only, location left to you"
  setup
  touch "$STATE_DIR/operator"
  run_deploy

  # --- .env
  check ".env generated"                [ -f "$SVC/.env" ]
  check ".env is mode 600"              [ "$(file_mode "$SVC/.env")" = "600" ]
  check ".env has a hex admin password" \
    sh -c "printf '%s' \"\$(sed -n 's/^HA_ADMIN_PASSWORD=//p' '$SVC/.env' | tr -d '\"')\" | grep -qE '^[a-f0-9]{32}$'"
  check ".env names the admin user"     [ "$(env_val HA_ADMIN_USER)" = "kai" ]
  check ".env records the local port"   [ "$(env_val LOCAL_PORT)" = "8123" ]
  check ".env records the HTTPS port"   [ "$(env_val HTTPS_PORT)" = "8123" ]
  check ".env carries the host TZ"      [ "$(env_val TZ)" = "Asia/Singapore" ]
  check ".env points HA_CONFIG at HOME" [ "$(env_val HA_CONFIG)" = "$HOME/services/home-assistant/config" ]

  # --- state
  check "config dir created"            [ -d "$HOME/services/home-assistant/config" ]
  check "compose up invoked"            [ -f "$STATE_DIR/compose_up" ]

  # --- readiness gate
  check "polled /api/onboarding"        calls_have "127.0.0.1:8123/api/onboarding"
  check "  before creating the account" \
    [ "$(grep -n '127.0.0.1:8123/api/onboarding$' "$CALLS_LOG" | head -1 | cut -d: -f1)" \
      -lt "$(grep -n '/api/onboarding/users$' "$CALLS_LOG" | head -1 | cut -d: -f1)" ]

  # --- onboarding
  check "created the owner account"     calls_have "/api/onboarding/users"
  check "  body carries the username"   grep -qF "\"username\":\"kai\"" "$STATE_DIR/users_body"
  check "  body carries the .env password" \
    grep -qF "\"password\":\"$(env_val HA_ADMIN_PASSWORD)\"" "$STATE_DIR/users_body"
  check "  client_id is a URL"          grep -qF '"client_id":"http://127.0.0.1:8123/"' "$STATE_DIR/users_body"
  check "  exchanged the auth code"     calls_have "/auth/token"
  check "  exactly once (it is single-use)" [ "$(wc -l < "$STATE_DIR/token_exchanges")" -eq 1 ]
  check "  as an authorization_code grant"  grep -q 'grant_type=authorization_code' "$STATE_DIR/token_body"
  check "  opted out of analytics"      calls_have "/api/onboarding/analytics"
  check "reports the account created"   out_has "Admin account created"

  # --- the step it must NOT complete
  check "NEVER posted core_config"      no_call "/api/onboarding/core_config"
  check "  the stub agrees"             [ ! -f "$STATE_DIR/core_config_called" ]
  check "says core_config was left open" out_has "core_config left open"

  # --- publish
  check "served on tailscale :8123"     calls_have "tailscale serve --bg --https=8123 http://127.0.0.1:8123"
  check "no sudo needed (operator set)" no_call "^sudo "

  # --- verification
  check "verified over the tailnet URL" calls_have "https://test-host.tailfake.ts.net:8123/api/onboarding"
  check "  reported the end-to-end pass" out_has "End-to-end HTTPS check passed"
  check "checked the live timezone"     calls_have "127.0.0.1:8123/api/config"
  check "  confirmed bluetooth is off"  out_has "Bluetooth is not loaded"
  check "  confirmed discovery is live" out_has "Discovery is live"

  # This is the bug the suite found in review: with HTTPS_PORT == LOCAL_PORT,
  # tailscaled itself listens on the tailnet addresses for that same port
  # (measured on this box for immich :2283 and jellyfin :8096). A check that
  # only whitelists 127.* reports a correct deploy as a LAN leak and exits 1.
  check "does not mistake tailscaled's own serve listener for a LAN leak" \
    out_lacks "NON-LOOPBACK address"
  check "reports the bind as loopback-only" out_has "Listener is loopback-only"

  # --- final message
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "prints the tailnet URL"        out_has "https://test-host.tailfake.ts.net:8123"
  check "prints the login name"         out_has "Login:    kai"
  check "points at .env for the password" out_has "HA_ADMIN_PASSWORD"
  check "tells you to finish the location" out_has "LOCATION"
  check "  explains why it was left"    out_has "latitude 0"
  check "explains bluetooth is off"     out_has "Bluetooth is OFF"
  check "documents the companion app"   out_has "Companion app"
  check "  says enter the address by hand" out_has "Enter address manually"
  check "warns there is no backup here" out_has "nothing backs this box up"
  teardown
}

test_readiness_race() {
  echo "• readiness race: a REAL refused connection, not a tidy 503"
  # A cold Home Assistant is not listening at all for the first several
  # seconds: curl exits 7 and prints 000. Modelling this as a 503 would be a
  # lie, and it is precisely how the Jellyfin deploy in this repo failed — the
  # probe passed and the next request came back 000.
  setup
  touch "$STATE_DIR/operator"
  echo 5 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  # 5 refusals + 1 success on the deploy gate, + 1 more at verification.
  check "kept polling through the refusals" \
    [ "$(call_count '127.0.0.1:8123/api/onboarding$')" -eq 7 ]
  check "  waited between polls"      [ "$(call_count '^sleep 2$')" -eq 5 ]
  check "  onboarded nothing while refused" \
    [ "$(grep -n '/api/onboarding/users$' "$CALLS_LOG" | head -1 | cut -d: -f1)" \
      -gt "$(grep -n '^sleep 2$' "$CALLS_LOG" | tail -1 | cut -d: -f1)" ]
  check "the account really was created" out_has "Admin account created"
  check "still published"             calls_have "tailscale serve --bg --https=8123"
  teardown
}

test_never_ready() {
  echo "• server never answers: dies before touching onboarding or the publish"
  setup
  touch "$STATE_DIR/operator"
  echo 500 > "$STATE_DIR/conn_refused_left"   # more refusals than the loop has tries
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "says it never answered"    out_has "never answered"
  check "  names the log command"   out_has "logs --tail 100"
  check "gave up after 90 tries"    [ "$(call_count '127.0.0.1:8123/api/onboarding$')" -eq 90 ]
  check "created no account"        no_call "/api/onboarding/users"
  check "exchanged no token"        no_call "/auth/token"
  check "published nothing"         no_call "tailscale serve"
  teardown
}

test_403_user_step_already_done_is_success() {
  echo "• 403 {\"message\":\"User step already done\"} is SUCCESS, not a failure"
  # The idempotency signal. This is the shape a re-run sees, and also what a
  # restored .storage/ produces on an otherwise-fresh deploy. A script that
  # treats it as an error cannot be run twice, which breaks the repo's central
  # rule. Note the server here reports the step as NOT done in the readiness
  # payload but 403s the POST — the ugly interleaving a partially-completed
  # run leaves behind.
  setup
  touch "$STATE_DIR/operator"
  run_deploy > /dev/null 2>&1                     # first deploy creates the owner
  # Now model a run that died between creating the account and finishing: the
  # owner exists, but the readiness payload still reports done:false, so the
  # script POSTs and lands squarely on the 403.
  touch "$STATE_DIR/readiness_hides_user"
  rm -f "$STATE_DIR/token_exchanges"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "did POST the users step"    calls_have "/api/onboarding/users"
  check "  read the 403 as success"  out_has "already exists"
  check "  did not die on it"        out_lacks "was refused"
  check "  burned no auth code"      [ ! -f "$STATE_DIR/token_exchanges" ]
  check "  still published"          calls_have "tailscale serve --bg --https=8123"
  teardown

  # And the clean version: the readiness payload already says done: true.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/onboarding_user_done"
  run_deploy
  check "restored .storage: exits zero"     [ "$CODE" -eq 0 ]
  check "  skipped account creation"        out_has "already done"
  check "  did not POST the users step"     no_call "/api/onboarding/users"
  check "  burned no auth code"             [ ! -f "$STATE_DIR/token_exchanges" ]
  check "  still published"                 calls_have "tailscale serve --bg --https=8123"
  check "  still verified end to end"       out_has "End-to-end HTTPS check passed"
  check "  told you the account was untouched" out_has "not touched this run"
  teardown
}

test_403_that_is_not_the_idempotency_signal() {
  echo "• a 403 with a different body is a real failure, not swallowed"
  setup
  touch "$STATE_DIR/operator"
  printf '403' > "$STATE_DIR/users_fail"
  # The stub's forced-failure body is not "User step already done", so the
  # script must not read it as the idempotency signal.
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the refusal"       out_has "was refused"
  # The message quotes the whitespace-stripped body, which is also what the
  # idempotency match runs against — so this proves the match is on content,
  # not merely on the 403 status.
  check "shows the body"          out_has "stubbedusersfailure"
  check "published nothing"       no_call "tailscale serve"
  teardown
}

test_onboarding_complete_returns_404() {
  echo "• /api/onboarding 404s once every step is done: still 'up', not 'broken'"
  # HA registers the onboarding views at startup, so a fully-onboarded instance
  # that has been restarted 404s this endpoint. A readiness loop that only
  # accepts 200 would spin for 180s and then declare a perfectly healthy server
  # dead — on every re-run, forever, from the day the user finishes the
  # location step in the UI and the box reboots.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/onboarding_404"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "treated 404 as ready"          out_has "answering locally"
  check "  did not spin for 90 tries"   [ "$(call_count '127.0.0.1:8123/api/onboarding$')" -lt 5 ]
  check "  said onboarding is complete" out_has "every step is done"
  check "created no account"            no_call "/api/onboarding/users"
  check "  and burned no auth code"     [ ! -f "$STATE_DIR/token_exchanges" ]
  check "never posted core_config"      no_call "/api/onboarding/core_config"
  check "still published"               calls_have "tailscale serve --bg --https=8123"
  check "end-to-end HTTPS accepted 404" out_has "End-to-end HTTPS check passed"
  teardown
}

test_auth_code_is_single_use() {
  echo "• the auth_code is exchanged exactly once, ever"
  # Measured against 2026.9.1: a second exchange of the same code returns 200
  # with an EMPTY access_token. A script that retries the exchange gets nothing
  # and reports a confusing failure over a perfectly good account.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "first deploy exits zero"     [ "$CODE" -eq 0 ]
  check "exchanged once"              [ "$(wc -l < "$STATE_DIR/token_exchanges")" -eq 1 ]
  check "  got a usable token"        out_has "Exchanged the single-use auth code"
  check "  used it for analytics"     calls_have "/api/onboarding/analytics"

  : > "$CALLS_LOG"
  run_deploy                          # re-run: account exists
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  check "  no second exchange"        [ "$(wc -l < "$STATE_DIR/token_exchanges")" -eq 1 ]
  check "  no code was reused"        [ "$(sort "$STATE_DIR/used_codes" | uniq -d | wc -l)" -eq 0 ]
  teardown
}

test_token_exchange_fails_is_not_fatal() {
  echo "• token exchange yields no token: warned, deploy still succeeds"
  # The account exists with the password in .env, which is the part that
  # matters. Only the analytics opt-out is lost, and HA asks at first login.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/token_no_access_token"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "created the account"         out_has "Admin account created"
  check "warns about the token"       out_has "Could not exchange the auth code"
  check "  says it is harmless"       out_has "Harmless"
  check "  points at first login"     out_has "analytics at first login"
  check "did not post analytics"      no_call "/api/onboarding/analytics"
  check "still published"             calls_have "tailscale serve --bg --https=8123"
  teardown
}

test_core_config_is_never_completed() {
  echo "• core_config is never auto-completed, on any path"
  # Posting it — even with {} — returns 200 and accepts latitude 0 /
  # longitude 0 / time_zone UTC, then marks the step done so the UI never asks
  # again. Sunrise/sunset is quietly wrong forever.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                       # fresh
  check "fresh: never called"        no_call "/api/onboarding/core_config"
  : > "$CALLS_LOG"
  run_deploy                                       # re-run
  check "re-run: never called"       no_call "/api/onboarding/core_config"
  teardown

  setup
  touch "$STATE_DIR/operator"
  echo 3 > "$STATE_DIR/conn_refused_left"
  run_deploy                                       # after a readiness race
  check "after a race: never called" no_call "/api/onboarding/core_config"
  check "the stub never saw it"      [ ! -f "$STATE_DIR/core_config_called" ]
  teardown

  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/token_no_access_token"
  run_deploy                                       # with no token in hand
  check "tokenless: never called"    no_call "/api/onboarding/core_config"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env and configuration.yaml preserved, no sudo, no re-onboarding"
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy
  pw="$(env_val HA_ADMIN_PASSWORD)"
  echo '# my-custom-marker' >> "$SVC/.env"
  echo '# my-yaml-edit' >> "$(LIVE_CONFIG_PATH)"
  : > "$CALLS_LOG"
  run_deploy                                   # second deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "existing .env untouched"       env_has "my-custom-marker"
  check "  password unchanged"          [ "$(env_val HA_ADMIN_PASSWORD)" = "$pw" ]
  check "hand-edited yaml untouched"    grep -q 'my-yaml-edit' "$(LIVE_CONFIG_PATH)"
  check "  and said so"                 out_has "leaving untouched"
  check "never invoked sudo"            no_call "^sudo "
  check "compose up re-invoked"         [ -f "$STATE_DIR/compose_up" ]
  check "did NOT re-create the account" no_call "/api/onboarding/users"
  check "  said the step was done"      out_has "user step already done"
  check "re-applied the serve config"   calls_have "tailscale serve --bg --https=8123 http://127.0.0.1:8123"
  check "re-verified end to end"        out_has "End-to-end HTTPS check passed"
  teardown
}

test_storage_without_config_is_named() {
  echo "• .storage exists but configuration.yaml does not: the first-boot loss is named"
  # The nastiest recoverable state. HA has booted here with some other config,
  # so the Bluetooth config entry (and its error storm) is already baked into
  # .storage and writing the yaml now will not undo it.
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/home-assistant/config/.storage"
  echo '{}' > "$HOME/services/home-assistant/config/.storage/core.config_entries"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "names the prior boot"           out_has "booted in this directory before"
  check "  says what the yaml still fixes" out_has "reverse-proxy settings"
  check "  says what it cannot undo"     out_has "persist and keep erroring"
  check "  gives the clean fix"          out_has "rm -rf"
  check "still wrote the config"         boot_cfg_exists
  check "  before starting the container" grep -q "configuration.yaml$" "$STATE_DIR/files_at_compose_up"
  teardown
}

test_port_already_in_use() {
  echo "• port busy under host networking: refuses before starting a doomed container"
  # With network_mode: host HA binds the host's port directly. If something
  # else holds it, HA does not warn — it fails to start its HTTP server and the
  # container sits there logging a stack trace.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/port_busy"
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "names the port"          out_has "Port 8123 is already in use"
  check "  explains host mode"    out_has "host network"
  check "  offers LOCAL_PORT"     out_has "LOCAL_PORT"
  check "started no container"    [ ! -f "$STATE_DIR/compose_up" ]
  check "published nothing"       no_call "tailscale serve"
  teardown
}

test_wildcard_bind_is_caught() {
  echo "• 0.0.0.0 bind: caught and reported as the LAN leak it is"
  # host networking without http.server_host. Plain HTTP on every interface,
  # in front of an instance whose onboarding may still be open.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/wildcard_bind"
  run_deploy
  check "exits non-zero"            [ "$CODE" -ne 0 ]
  check "names the exposure"        out_has "NON-LOOPBACK address"
  check "  spells out the risk"     out_has "reachable from the LAN"
  check "  names the fix"           out_has "server_host: 127.0.0.1"
  check "  and the restart"         out_has "restart"
  check "final exit is a failure"   out_has "verification checks above failed"
  teardown
}

test_port_override() {
  echo "• LOCAL_PORT/HTTPS_PORT overrides: honoured fresh, ignored on a re-run"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8124 HTTPS_PORT=8124
  echo 8124 > "$STATE_DIR/listen_port"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env records the override"   [ "$(env_val LOCAL_PORT)" = "8124" ]
  check "config binds the new port"   boot_http_is 's.get("server_port") == 8124'
  check "  still on loopback"         boot_http_is 's.get("server_host") == ["127.0.0.1"]'
  check "polled :8124 for readiness"  calls_have "127.0.0.1:8124/api/onboarding"
  check "served :8124 -> :8124"       calls_have "tailscale serve --bg --https=8124 http://127.0.0.1:8124"
  check "prints the :8124 URL"        out_has "https://test-host.tailfake.ts.net:8124"

  # .env is the source of truth once it exists, so a re-run cannot move a live
  # deployment out from under the config file HA is actually reading.
  export LOCAL_PORT=8125
  run_deploy
  check "re-run: exits zero"          [ "$CODE" -eq 0 ]
  check "re-run: says it ignored it"  out_has "LOCAL_PORT=8125 ignored"
  check "  names both files to edit"  out_has "http.server_port"
  check "re-run: .env unchanged"      [ "$(env_val LOCAL_PORT)" = "8124" ]
  check "re-run: never touched 8125"  no_call "127.0.0.1:8125"
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves both ports; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (8123) next to a LOCAL_PORT
  # override silently published :8123 -> 127.0.0.1:8124, i.e. the wrong port.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8124
  echo 8124 > "$STATE_DIR/listen_port"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records HTTPS_PORT=8124"   [ "$(env_val HTTPS_PORT)" = "8124" ]
  check "served :8124 -> 127.0.0.1:8124" calls_have "tailscale serve --bg --https=8124 http://127.0.0.1:8124"
  check "  and never :8123"              no_call "tailscale serve --bg --https=8123"
  check "prints the :8124 URL"           out_has "https://test-host.tailfake.ts.net:8124"

  # Re-run with no override at all: .env says 8124, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 8123.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                  [ "$CODE" -eq 0 ]
  check "re-run kept :8124 -> 127.0.0.1:8124" calls_have "tailscale serve --bg --https=8124 http://127.0.0.1:8124"
  check "  and never :8123"                  no_call "tailscale serve --bg --https=8123"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8124 HTTPS_PORT=8443
  echo 8124 > "$STATE_DIR/listen_port"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:8124" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:8124"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown
}

test_timezone_from_host() {
  echo "• the timezone comes from the host, not from a hardcoded default"
  setup
  touch "$STATE_DIR/operator"
  export STUB_TZ="Europe/Berlin"
  run_deploy
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "yaml carries the host zone"  boot_cfg_has '^ *time_zone: *Europe/Berlin *$'
  check ".env carries it too"         [ "$(env_val TZ)" = "Europe/Berlin" ]
  check "never posted core_config"    no_call "/api/onboarding/core_config"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published" calls_have "tailscale serve --bg --https=8123 http://127.0.0.1:8123"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  # Two forced failures: the first trips the operator-grant branch, the second
  # lands in the until-loop that prints the approval link and waits.
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve, then press Enter"
  check "published on retry"        calls_have "tailscale serve --bg --https=8123 http://127.0.0.1:8123"
  teardown
}


test_broken_store_is_repaired() {
  echo "• a reverted .storage/http (the real outage) is detected and repaired in place"
  # This is the exact shape captured off the live box after the first deploy:
  # `stable` reverted to the defaults — no server_host, no proxy trust — and a
  # `pending` marked not_promoted. HA was binding 0.0.0.0 and nothing said so.
  setup
  touch "$STATE_DIR/operator"
  seed_store '{"server_host": null, "use_x_forwarded_for": null, "trusted_proxies": []}' \
             '{"server_host": ["127.0.0.1"], "error": "not_promoted"}'
  touch "$STATE_DIR/compose_up"    # the container is already running
  run_deploy
  check "exits zero"                       [ "$CODE" -eq 0 ]
  check "named the specific problem"       out_has "server_host=None"
  check "  and the staged trial"           out_has "pending config is staged"
  check "stopped the container first"      out_has "so the repair is not overwritten"
  check "  really invoked compose stop"    calls_have "compose .* stop"
  check "said it repaired the file"        out_has "epaired"
  check "stable.server_host fixed"         [ "$(store_field 's.get("server_host")')" = "['127.0.0.1']" ]
  check "stable.use_x_forwarded_for fixed" [ "$(store_field 's.get("use_x_forwarded_for")')" = "True" ]
  check "stable.trusted_proxies fixed"     [ "$(store_field 'bool(s.get("trusted_proxies"))')" = "True" ]
  check "pending cleared to null"          [ "$(store_field 'd.get("pending")')" = "None" ]
  check "container restarted after"        [ -f "$STATE_DIR/compose_up" ]
  check "still published"                  calls_have "tailscale serve --bg --https=8123"
  teardown
}

test_repair_preserves_unrelated_keys() {
  echo "• the repair merges — it does not clobber settings it does not own"
  # Someone may have set an ssl_profile or moved the port by hand. A repair
  # that rewrote the whole `stable` dict would silently discard those, and the
  # loss would only surface much later.
  setup
  touch "$STATE_DIR/operator"
  seed_store '{"server_host": null, "server_port": 8199, "ssl_profile": "intermediate", "login_attempts_threshold": 5}' 'null'
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "server_host repaired"           [ "$(store_field 's.get("server_host")')" = "['127.0.0.1']" ]
  check "hand-set port preserved"        [ "$(store_field 's.get("server_port")')" = "8199" ]
  check "hand-set ssl_profile preserved" [ "$(store_field 's.get("ssl_profile")')" = "'intermediate'" ]
  check "hand-set threshold preserved"   [ "$(store_field 's.get("login_attempts_threshold")')" = "5" ]
  teardown
}

test_missing_store_on_booted_dir() {
  echo "• .storage exists but the http store is gone: recreated, not ignored"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/home-assistant/config/.storage"
  echo '{}' > "$HOME/services/home-assistant/config/.storage/core.config_entries"
  run_deploy
  check "exits zero"                 [ "$CODE" -eq 0 ]
  check "store exists afterwards"    [ -f "$HOME/services/home-assistant/config/.storage/http" ]
  check "  binds loopback"           [ "$(store_field 's.get("server_host")')" = "['127.0.0.1']" ]
  check "  pending is null"          [ "$(store_field 'd.get("pending")')" = "None" ]
  check "  yaml_migration_done true" [ "$(store_field 'd.get("yaml_migration_done")')" = "True" ]
  teardown
}

test_corrupt_store_is_repaired() {
  echo "• a corrupt .storage/http is named as unreadable and rewritten"
  setup
  touch "$STATE_DIR/operator"
  mkdir -p "$HOME/services/home-assistant/config/.storage"
  printf 'not json at all' > "$HOME/services/home-assistant/config/.storage/http"
  run_deploy
  check "exits zero"             [ "$CODE" -eq 0 ]
  check "named it unparseable"   out_has "could not be parsed"
  check "rewrote a valid store"  [ "$(store_field 's.get("server_host")')" = "['127.0.0.1']" ]
  check "  with pending null"    [ "$(store_field 'd.get("pending")')" = "None" ]
  teardown
}

test_staged_pending_trial() {
  echo "• a STAGED (not yet failed) pending trial — the shape that looks healthy"
  # HA stages a `pending` whenever the http settings are changed in the UI, and
  # for the five-minute window before an unpromoted trial reverts. In that
  # window the listener is perfectly correct and the DURABLE state is not:
  # after the next restart it falls back to `stable`.
  #
  # Both halves of setup.sh must agree that ANY staged pending is bad, not only
  # one that has already errored. When they disagreed, the repair gate did
  # nothing, verification rejected the store, and the run died telling you to
  # re-run — which reached the identical verdict. That loop is what the third
  # assertion here guards against.
  setup
  touch "$STATE_DIR/operator"
  seed_store '{}' '{"server_host": ["0.0.0.0"], "server_port": 8123, "error": null}'
  run_deploy
  check "the staged trial was cleared"       [ "$(store_field 'd.get("pending")')" = "None" ]
  check "exits zero"                         [ "$CODE" -eq 0 ]
  check "did not dead-end with advice that cannot work" not_a_rerun_loop
  teardown
}

# ------------------------------------------------------------ live suite
live_check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); green "    ✓ $desc"
  else
    FAIL=$((FAIL + 1)); red "    ✗ $desc"
  fi
}

# Every listener on $port must be loopback or Tailscale's own tailnet
# address — never a wildcard or a LAN interface.
#
# Note this service publishes HTTPS on the same number as the local port
# (8123 -> 8123), so tailscaled legitimately listens on the tailnet IP for
# that port. The other services here differ (e.g. seafile 8443 -> 8081) and never
# hit that overlap, which is why their simpler "anything not 127.0.0.1"
# check works for them and would false-positive here.
no_external_listener() {
  local port="$1" addrs addr host ts ts4 ts6
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  ts4="$("$ts" ip -4 2>/dev/null || true)"
  ts6="$("$ts" ip -6 2>/dev/null || true)"

  if command -v ss >/dev/null; then
    addrs="$(ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}')"
  else
    addrs="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
  fi
  [ -n "$addrs" ] || return 0

  # read loop, not `for addr in $addrs`: that relies on word-splitting,
  # which zsh does not do for unquoted expansions.
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    host="${addr%:*}"                            # strip :port
    host="$(printf '%s' "$host" | tr -d '[]')"   # unwrap [v6] — tr, not a
                                                 # glob: '[' is an invalid
                                                 # pattern under zsh
    case "$host" in
      127.0.0.1|::1|localhost) ;;
      *) [ -n "$ts4" ] && [ "$host" = "$ts4" ] && continue
         [ -n "$ts6" ] && [ "$host" = "$ts6" ] && continue
         return 1 ;;
    esac
  done <<EOF
$addrs
EOF
  return 0
}

test_live() {
  echo "• live: verify the real deployment on this machine"
  # Without the docker group every `docker inspect` fails and the container
  # checks report "not running" for a perfectly healthy stack. Say so, rather
  # than letting red lines imply an outage. A shell started before the user
  # was added to the group hits this, which is easy to forget.
  if ! docker ps >/dev/null 2>&1; then
    red "    ! cannot reach the docker daemon — container checks would report"
    red "      false failures. Re-run as: sg docker -c './tests/run-tests.sh --live'"
    FAIL=$((FAIL + 1))
    return
  fi
  if [ ! -f "$SERVICE_DIR/.env" ]; then
    red "    ! $SERVICE_DIR/.env does not exist — nothing has been deployed here yet."
    FAIL=$((FAIL + 1))
    return
  fi
  local ts port https_port url cfg
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  # .env values are double-quoted. Strip them — an unstripped path turns every
  # file assertion below into a silent no-op (a `! grep` on an unreadable file
  # *passes*), which is exactly the kind of vacuously-green check this repo has
  # been bitten by before.
  env_of() { sed -n "s/^$1=//p" "$SERVICE_DIR/.env" | sed 's/^"//; s/"$//' | head -1; }
  port="$(env_of LOCAL_PORT)"
  case "$port" in ''|*[!0-9]*) port=8123 ;; esac
  https_port="${HTTPS_PORT:-$(env_of HTTPS_PORT)}"
  case "$https_port" in ''|*[!0-9]*) https_port="$port" ;; esac
  cfg="$(env_of HA_CONFIG)"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  live_check "container running" \
    sh -c "docker inspect -f '{{.State.Status}}' home-assistant | grep -qx running"
  live_check "  on the host network" \
    sh -c "docker inspect -f '{{.HostConfig.NetworkMode}}' home-assistant | grep -qx host"
  live_check "  running the pinned image" \
    sh -c "docker inspect -f '{{.Config.Image}}' home-assistant | grep -q 'home-assistant:2026'"
  live_check "  not :stable" \
    sh -c "! docker inspect -f '{{.Config.Image}}' home-assistant | grep -q ':stable'"

  # /api/onboarding is 200 and unauthenticated while any step is open, and 404
  # once every step is done. Both mean the server is up. `/` is a 302 — do not
  # health-check it with `curl -fsS` and expect output.
  live_check "local /api/onboarding answers" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 15 'http://127.0.0.1:$port/api/onboarding' | grep -qE '^(200|404)$'"
  live_check "local / returns 302 (not 200)" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 15 'http://127.0.0.1:$port/' | grep -qx 302"

  # A deploy that left the owner account uncreated is a failed deploy that
  # looks fine: the page loads, and /api/onboarding/users will create the owner
  # for anyone who can reach the port.
  live_check "onboarding user step is done" \
    sh -c "code=\$(curl -s -o /tmp/ha-live-onb.\$\$ -w '%{http_code}' --max-time 15 'http://127.0.0.1:$port/api/onboarding');
           if [ \"\$code\" = 404 ]; then rm -f /tmp/ha-live-onb.\$\$; exit 0; fi
           tr -d ' ' < /tmp/ha-live-onb.\$\$ | grep -q '\"step\":\"user\",\"done\":true'; rc=\$?; rm -f /tmp/ha-live-onb.\$\$; exit \$rc"

  live_check "not listening on non-local ifaces" no_external_listener "$port"

  # go2rtc's WebRTC listener. If `go2rtc:` ever comes back into the yaml, this
  # is a plain-TCP port on the host's every interface — LAN included — with no
  # Serve and no TLS in front of it. Verified in a bridge-networked throwaway
  # of this image: enabling go2rtc opens 127.0.0.1:18554 and tcp6 :::18555;
  # removing it leaves only the HA port. Under network_mode: host the second
  # one is a real LAN exposure, which is why the component is not loaded.
  live_check "no go2rtc WebRTC listener on 18555" no_external_listener 18555
  live_check "no go2rtc RTSP listener off-loopback on 18554" no_external_listener 18554
  live_check "tailscale serve maps :$https_port" \
    sh -c "'$ts' serve status | grep -A2 ':$https_port' | grep -q 'proxy http://127.0.0.1:$port'"
  # 200 or 404 both prove the chain. A 400 here is HA rejecting the request as
  # coming from an untrusted reverse proxy — i.e. use_x_forwarded_for /
  # trusted_proxies never took effect, which is a first-boot-ordering failure.
  live_check "tailnet HTTPS responds (not a 400 proxy rejection)" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 60 '$url:$https_port/api/onboarding' | grep -qE '^(200|404)$'"

  live_check "config dir exists"            sh -c "test -d '$cfg'"
  # Readability is asserted BEFORE the negative checks below. `! grep pattern
  # missing-file` succeeds, so an unreadable path would make every "does not
  # enable X" line pass for the wrong reason.
  live_check "configuration.yaml is readable" sh -c "test -r '$cfg/configuration.yaml'"
  # The YAML must NOT carry an http: block. Since 2026.9 one is ignored — the
  # settings live in .storage/http, asserted below — and its presence raises a
  # yaml_still_present_after_migration repair notice in the UI. Asserting the
  # old way round is worse than useless: it passes on a config HA isn't reading.
  live_check "  has no http: block (moved to .storage/http on 2026.9)" \
    sh -c "test -r '$cfg/configuration.yaml' && ! sed 's/#.*//' '$cfg/configuration.yaml' | grep -qE '^http:'"
  live_check "  does not enable bluetooth" \
    sh -c "test -r '$cfg/configuration.yaml' && ! sed 's/#.*//' '$cfg/configuration.yaml' | grep -qE '^bluetooth:'"
  live_check "  does not use default_config" \
    sh -c "test -r '$cfg/configuration.yaml' && ! sed 's/#.*//' '$cfg/configuration.yaml' | grep -qE '^default_config:'"
  live_check "  does not enable go2rtc" \
    sh -c "test -r '$cfg/configuration.yaml' && ! sed 's/#.*//' '$cfg/configuration.yaml' | grep -qE '^go2rtc:'"

  # ---- .storage/http: the file that ACTUALLY decides the bind on 2026.9+ ----
  # HA 2026.9 migrated `http:` out of YAML into .storage/http exactly once, and
  # from then on `yaml_migration_done: true` means the YAML above is ignored.
  # The migrated settings land in a `pending` TRIAL that auto-reverts unless
  # something promotes it — and nothing in an unattended deploy does. A reverted
  # trial leaves `stable` holding the defaults: wildcard bind, no reverse-proxy
  # trust. That is how this deploy failed the first time, and neither the YAML
  # checks above nor a glance at `docker ps` shows it.
  #
  # The container writes .storage as root, so read it through the container.
  live_check ".storage/http exists" sh -c "docker exec home-assistant test -r /config/.storage/http"
  live_check "  ACTIVE http config binds loopback (not just the yaml)" \
    sh -c "docker exec home-assistant python3 -c \"
import json,sys
d=json.load(open('/config/.storage/http'))['data']
sys.exit(0 if d['stable'].get('server_host')==['127.0.0.1'] else 1)\""
  live_check "  ACTIVE http config trusts the loopback proxy" \
    sh -c "docker exec home-assistant python3 -c \"
import json,sys
d=json.load(open('/config/.storage/http'))['data']
s=d['stable']
sys.exit(0 if s.get('use_x_forwarded_for') and s.get('trusted_proxies') else 1)\""
  # ANY staged pending fails, not just an errored one. A staged-and-unpromoted
  # trial is the shape that looks healthiest and is the most dangerous: the
  # listener is correct right now and reverts to the wildcard defaults on the
  # next restart. "Not yet failed" is not the same as "safe".
  live_check "  no pending trial staged at all" \
    sh -c "docker exec home-assistant python3 -c \"
import json,sys
d=json.load(open('/config/.storage/http'))['data']
sys.exit(1 if isinstance(d.get('pending'), dict) else 0)\""

  # THE REGRESSION GUARD. The whole reason default_config is expanded by hand.
  # The host's bluetoothd owns hci0; if HA's bluetooth integration ever comes
  # back — a yaml edit, or a config entry left in .storage from an earlier
  # boot — this box logs "Failed to force stop scanner" 24 times a minute,
  # forever. Zero is the only acceptable number.
  live_check "ZERO habluetooth lines in the last 5 minutes of log" \
    sh -c "[ \"\$(docker logs --since 5m home-assistant 2>&1 | grep -c habluetooth)\" = 0 ]"
  live_check "  and no ERROR lines from the scanner" \
    sh -c "! docker logs --since 5m home-assistant 2>&1 | grep -q 'Failed to force stop scanner'"
}

# ------------------------------------------------------------- teardown
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

config_dir() { env_val HA_CONFIG; }

# A deployed sandbox: setup.sh has run, Serve maps this port to this service,
# and neighbours sit on other ports (one a lookalike suffix).
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$(config_dir)/.storage"
  echo keep > "$(config_dir)/.storage/core.config_entries"
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:8123 (tailnet only)
|-- / proxy http://127.0.0.1:8123

https://test-host.tailfake.ts.net:18123 (tailnet only)
|-- / proxy http://127.0.0.1:18123
EOF
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps config and .env, unpublishes only its port"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for :8123"         calls_have "tailscale serve --https=8123 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18123 untouched"  no_call "https=18123"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "no container cleanup run"    no_call "entrypoint sh"
  check "config kept"                 [ -f "$(config_dir)/.storage/core.config_entries" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_not_published() {
  echo "• teardown: nothing published is fine"
  deployed
  : > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says already off"            out_has "already off"
  check "still compose down"          [ -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_port_owned_by_someone_else() {
  echo "• teardown: refuses to unpublish a port that points elsewhere"
  deployed
  printf 'https://test-host.tailfake.ts.net:8123 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "says nothing points here"    out_has "already off"
  teardown
}

test_teardown_preflight() {
  echo "• teardown: preflight"
  setup
  run_teardown
  check "no .env: exits non-zero"     [ "$CODE" -ne 0 ]
  check "no .env: explains"           out_has "nothing to tear down"
  check "no .env: touched nothing"    [ ! -f "$STATE_DIR/compose_down" ]
  teardown
  deployed
  export FAKE_UID=0
  run_teardown
  check "root: exits non-zero"        [ "$CODE" -ne 0 ]
  unset FAKE_UID
  run_teardown --force
  check "unknown flag: exits non-zero"  [ "$CODE" -ne 0 ]
  check "unknown flag: no compose down" [ ! -f "$STATE_DIR/compose_down" ]
  touch "$STATE_DIR/docker_no_perm"
  run_teardown
  check "no docker: exits non-zero"   [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_purge() {
  echo "• teardown --purge: typed confirmation, then the whole config dir and .env go"
  deployed
  local dir; dir="$(config_dir)"
  run_teardown --purge "home"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: config kept"     [ -f "$dir/.storage/core.config_entries" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "home-assistant"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "config dir gone"             [ ! -e "$dir" ]
  check ".storage gone (true first boot)" [ ! -e "$dir/.storage" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :8123"         calls_have "tailscale serve --https=8123 off"
  check "down only, never down -v"    no_call "down -v"
  check "services dir itself kept"    [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_root_owned() {
  echo "• teardown --purge: root-owned files are cleared by the pinned image, not sudo"
  deployed
  local dir; dir="$(config_dir)"
  # Stand-in for a root-owned file: a read-only dir the host user cannot empty.
  mkdir -p "$dir/.storage/locked"; echo x > "$dir/.storage/locked/f"
  chmod 500 "$dir/.storage/locked"
  run_teardown --purge "home-assistant"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "used the pinned image"       calls_have "ghcr.io/home-assistant/home-assistant:2026.9.1"
  check "never pulled for it"         calls_have "pull never"
  check "no sudo"                     no_call "^sudo"
  check "config dir gone"             [ ! -e "$dir" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
  deployed
  dir="$(config_dir)"
  mkdir -p "$dir/.storage/locked"; echo x > "$dir/.storage/locked/f"
  chmod 500 "$dir/.storage/locked"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "home-assistant"
  chmod -R u+rwX "$dir" 2>/dev/null
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $dir"
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a config dir outside ~/services"
  deployed
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=$HOME#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "home untouched"              [ -d "$HOME" ]
  check "nothing stopped"             [ ! -f "$STATE_DIR/compose_down" ]
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=$HOME/services/../x#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "'..' refused"                [ "$CODE" -ne 0 ]
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=$HOME/services/#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "services dir itself refused" [ "$CODE" -ne 0 ]
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<EOF
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8123

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8123

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /ha proxy http://127.0.0.1:8123
EOF
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  teardown
}

test_teardown_serve_status_fails() {
  echo "• teardown: an unreadable Serve status stops before anything changes"
  deployed
  touch "$STATE_DIR/serve_status_fails"
  run_teardown
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "says why"                    out_has "Could not read Tailscale Serve status"
  check "no compose down"             [ ! -f "$STATE_DIR/compose_down" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8123'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8123 off"                   calls_have "serve --https=8123 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8123"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT=8123 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "home-assistant"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_config_dir() {
  echo "• teardown --purge: a config dir already gone is fine"
  deployed
  rm -rf "$(config_dir)"
  run_teardown --purge "home-assistant"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

# ---------------------------------------------------- host-isolation proof
# The mocked suite must not touch the real deployment. Rather than assert that
# in a comment, fingerprint everything it could plausibly write to — this
# service directory, and ~/services/home-assistant — before and after the whole
# run, and compare.
host_fingerprint() {
  {
    find "$SERVICE_DIR" -type f ! -path '*/.git/*' -exec cksum {} \; 2>/dev/null
    find "$ORIG_HOME/services/home-assistant" -exec cksum {} \; 2>/dev/null
  } | sort
}

test_teardown_home_variable_in_env() {
  echo "• teardown --purge: a $HOME reference in .env is expanded like Compose does"
  deployed
  local dir; dir="$(config_dir)"
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG=\"\${HOME}${dir#"$HOME"}\"#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "\${HOME} form: exits zero"   [ "$CODE" -eq 0 ]
  check "  dir gone"                  [ ! -e "$dir" ]
  teardown
  deployed
  dir="$(config_dir)"
  sed -i.bak "s#^HA_CONFIG=.*#HA_CONFIG='\$HOME${dir#"$HOME"}'#" "$SVC/.env"
  run_teardown --purge "home-assistant"
  check "single-quoted \$HOME stays literal and is refused" [ "$CODE" -ne 0 ]
  check "  dir kept"                  [ -e "$dir" ]
  teardown
}

# ------------------------------------------------------------------ main
for f in setup.sh docker-compose.yml configuration.yaml; do
  [ -f "$SERVICE_DIR/$f" ] || { red "services/home-assistant/$f is missing — nothing to test."; exit 1; }
done

BEFORE_FP="$(host_fingerprint)"

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_preflight_bad_username
test_preflight_missing_template
test_config_written_before_first_boot
test_host_network_and_loopback_travel_together
test_image_is_pinned
test_compose_privilege_surface
test_fresh_deploy
test_readiness_race
test_never_ready
test_403_user_step_already_done_is_success
test_403_that_is_not_the_idempotency_signal
test_onboarding_complete_returns_404
test_auth_code_is_single_use
test_token_exchange_fails_is_not_fatal
test_core_config_is_never_completed
test_idempotent_rerun
test_storage_without_config_is_named
test_broken_store_is_repaired
test_repair_preserves_unrelated_keys
test_missing_store_on_booted_dir
test_corrupt_store_is_repaired
test_staged_pending_trial
test_port_already_in_use
test_wildcard_bind_is_caught
test_port_override
test_https_port_follows_local_port
test_timezone_from_host
test_operator_escalation
test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_root_owned
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_config_dir
test_teardown_home_variable_in_env

echo "• sandbox isolation: the mocked suite changed nothing on this host"
AFTER_FP="$(host_fingerprint)"
# On a mismatch, name the paths — otherwise a bare red is indistinguishable
# between "the sandbox leaked" (a real bug) and "another process edited
# setup.sh while the suite was running" (which happens when a second agent or
# an editor is live in this directory).
host_unchanged() {
  [ "$BEFORE_FP" = "$AFTER_FP" ] && return 0
  red "      changed paths:"
  diff <(printf '%s\n' "$BEFORE_FP") <(printf '%s\n' "$AFTER_FP") \
    | sed -n 's/^[<>] *[0-9]* *[0-9]* */        /p' | sort -u | head -10
  red "      (if these are files another process is editing, re-run on a quiet tree)"
  return 1
}
check "real service dir + ~/services/home-assistant are byte-identical" host_unchanged
# The real .env either never existed (and still does not) or was already there
# and is untouched — the fingerprint above covers the second case, this covers
# the first, which is the one a sandbox leak would break.
real_env_unchanged() {
  if grep -q "$SERVICE_DIR/.env\$" <<<"$BEFORE_FP"; then return 0; fi
  [ ! -f "$SERVICE_DIR/.env" ]
}
check "  no .env leaked into the real service dir" real_env_unchanged
check "  HOME was restored" [ "$HOME" = "$ORIG_HOME" ]

if [ "${1:-}" = "--live" ]; then
  echo
  test_live
fi

echo
if [ "$FAIL" -eq 0 ]; then
  green "All $PASS checks passed."
else
  red "$FAIL of $((PASS + FAIL)) checks failed."
  exit 1
fi
