#!/usr/bin/env bash
#
# Tests for services/firefly-iii/setup.sh.
#
#   ./tests/run-tests.sh          # mocked suite (sandboxed, no side effects)
#   ./tests/run-tests.sh --live   # also verify the real deployment
#
# Same harness as the other services here: the real script runs from a sandbox
# copy with PATH stubs for docker/tailscale/curl/ss/lsof/sudo/id/sleep. The
# curl stub fakes Firefly III's unauthenticated HTTP surface and the docker
# stub freezes the configuration at `compose up` time, so the pages the stub
# serves are rendered from the config setup.sh actually deployed.
#
# ---------------------------------------------------------------------------
# THE FOUR CASES THIS SUITE EXISTS FOR. Each is a measured failure mode in
# which the deploy reports success and is broken.
#
# 1. THE MIXED-CONTENT TRAP (test_asset_scheme_is_https).
#    With TRUSTED_PROXIES unset, Firefly answers 200 over HTTPS with every
#    <link href> and <script src> written as http://. A browser blocks them as
#    mixed content and renders an unstyled page with no JavaScript; curl sees
#    200 and reports success. So the curl stub builds the login page's asset
#    URLs from the config snapshotted at `compose up`, and this suite COUNTS
#    the http:// occurrences and requires zero. A status-code check is
#    precisely the check that fails here.
#
#    TRUSTED_PROXIES ALONE decides this — APP_URL does not. Measured as a
#    four-way matrix: '**' gives 0 http:// refs with either APP_URL value, and
#    empty gives 4 with either. Asserting "APP_URL must be external or the page
#    breaks" would be FALSE and would fail against a working deploy, so this
#    suite asserts APP_URL's value for the reasons it actually matters
#    (generated mails, the importer's VANITY_URL) and pins the asset scheme to
#    TRUSTED_PROXIES.
#
# 2. THE 16-CHARACTER PASSWORD MINIMUM (test_short_password_is_not_success).
#    A shorter password is rejected with a 302 BACK to /register — the same
#    status code a successful registration returns — and no user is created.
#    The suite forces that shape and requires setup.sh to exit non-zero, which
#    it can only do by verifying the user exists rather than trusting the 302.
#
# 3. CSRF IS COOKIE-BOUND (test_csrf_cookie_jar).
#    A missing or mismatched jar answers HTTP 419 "Page Expired", not a
#    validation error. Both the 419 path and the success path are covered.
#
# 4. ALREADY-REGISTERED IS SUCCESS (test_already_registered_is_success).
#    A second run must exit zero. A deploy that reads "user exists" as an error
#    cannot be re-run, which breaks the repo's central rule.
#
# Plus the standing constraints: all three image tags pinned, mem_limit on
# every container, APP_KEY exactly 32 characters, both ports loopback-only,
# and never port 8098 — that one is an ad-hoc `python3 echosrv.py` (pid
# 1781019) that is not ours and must not be reclaimed.
#
# Sandbox guarantee: every mocked test runs with HOME pointed at a temp dir, so
# nothing touches ~/services/firefly-iii or the real .env. The suite proves it
# rather than claiming it: host_fingerprint() cksums the whole service
# directory and ~/services/firefly-iii before and after the run, and the last
# check compares them.
#
# ---------------------------------------------------------------------------
# MUTATION RESULTS — what this suite was proven to catch, not just to assert.
# Each mutation was applied to a throwaway copy of the service directory in a
# private mktemp -d; the number is how many checks went red.
#
#   (filled in below by the mutation run — see MUTATIONS at the end of file)
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

# What the tailscale stub reports — deliberately NOT this box's real hostname
# or IP, so a literal baked into setup.sh or docker-compose.yml cannot pass by
# coincidence.
FAKE_HOST="test-host.tailfake.ts.net"
FAKE_TS_IP="100.77.77.77"

# The three tags this deploy pins. Read from the compose file's defaults.
WANT_CORE_TAG="version-6.4.2"
WANT_IMPORTER_TAG="version-1.9.0"
WANT_PG_TAG="16-alpine"

# --------------------------------------------------------------- harness
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export STATE_DIR="$SANDBOX/state"
  export CALLS_LOG="$SANDBOX/calls.log"
  SVC="$SANDBOX/svc"
  mkdir -p "$HOME" "$STATE_DIR" "$SVC"
  : > "$CALLS_LOG"
  cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"
}

teardown() {
  rm -rf "$SANDBOX"
  export HOME="$ORIG_HOME"
  unset FAKE_UID LOCAL_PORT IMPORTER_PORT HTTPS_PORT IMPORTER_HTTPS_PORT \
        FIREFLY_ADMIN_EMAIL STATE_DIR CALLS_LOG STUB_PORTS
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

out_has()    { grep -qi -- "$1" <<<"$OUT"; }
out_lacks()  { ! grep -qi -- "$1" <<<"$OUT"; }
calls_have() { grep -q -- "$1" "$CALLS_LOG"; }
no_call()    { ! grep -q -- "$1" "$CALLS_LOG"; }
call_count() { grep -c -- "$1" "$CALLS_LOG"; }
teardown_lacks() { ! grep -qE -- "$1" "$SERVICE_DIR/teardown.sh"; }

# .env values may be double-quoted so a value containing a space survives
# `. "$ENV_FILE"`. Strip the quotes here rather than in every assertion.
env_val()  { sed -n "s/^$1=//p" "$SVC/.env" 2>/dev/null | sed 's/^"//; s/"$//' | head -1; }
env_has()  { grep -q -- "$1" "$SVC/.env" 2>/dev/null; }
# .env explains at length why things are pinned and why the password is long,
# so assertions about VALUES have to ignore the prose.
env_body() { sed 's/#.*//' "$SVC/.env" 2>/dev/null; }

# Same discipline for the compose file, which is mostly commentary about the
# traps it avoids — a naive grep matches the prose, not the config.
compose()       { sed 's/#.*//' "$SVC/docker-compose.yml"; }
compose_has()   { compose | grep -qE -- "$1"; }
compose_hasF()  { compose | grep -qF -- "$1"; }
compose_lacks() { ! compose_has "$1"; }

# ---- the config AS IT STOOD AT `compose up` -------------------------------
# The docker stub snapshots .env and docker-compose.yml there. Their absence IS
# a failure: it means the containers were started before the config existed.
BOOT_ENV()     { printf '%s' "$STATE_DIR/env_at_compose_up"; }
boot_env_exists() { [ -f "$(BOOT_ENV)" ]; }
boot_env_val() {
  sed -n "s/^$1=//p" "$(BOOT_ENV)" 2>/dev/null | sed 's/^"//; s/"$//' | head -1
}

# No `stat -c` without a `stat -f` fallback (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ---- run a stub the way setup.sh does ------------------------------------
# `sh -c "PATH='$STUBS:$PATH' ..."` does NOT work here: the inner $PATH is not
# expanded by the outer shell, so the child gets a PATH with nothing but the
# stub dir on it and cannot even find bash. Use functions.
stub_docker() { PATH="$STUBS:$PATH" docker "$@"; }
stub_curl()   { PATH="$STUBS:$PATH" curl "$@"; }

image_matches()    { stub_docker inspect -f '{{.Config.Image}}' "$1" | grep -q "$2"; }
mem_cap_positive() {
  local m; m="$(stub_docker inspect -f '{{.HostConfig.Memory}}' "$1")"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ "$m" -gt 0 ]
}
http_code_for()    { stub_curl -s -o /dev/null -w '%{http_code}' "$1"; }

# ---- what a BROWSER would actually receive --------------------------------
# The whole point of assertion class 1. Fetch a page through the same stub the
# deploy talked to, from the config it deployed, and count the asset schemes.
serve_page() {  # serve_page [port] [path]
  stub_curl -s "https://$FAKE_HOST:${1:-8097}${2:-/login}" 2>/dev/null
}
page_has_assets() { serve_page "${1:-8097}" "${2:-/login}" | grep -q 'build/assets'; }
importer_shows_container_url() { serve_page 8099 /token | grep -q 'http://app:8080'; }
# The importer check has to be SCOPED to assets — see the note at its call site.
importer_insecure_assets() {
  serve_page 8099 /token | grep -o -E '(src|href)="http://[^"]*build/assets/' | grep -c . || true
}
insecure_asset_count() {  # insecure_asset_count [port] [path]
  serve_page "${1:-8097}" "${2:-/login}" \
    | grep -o -E '(src|href)="http://' | grep -c . || true
}
zero_insecure_assets() {  # zero_insecure_assets [port] [path]
  [ "$(insecure_asset_count "${1:-8097}" "${2:-/login}")" -eq 0 ]
}

# ----------------------------------------------------------------- tests
test_preflight_root() {
  echo "• preflight refuses to run as root"
  setup
  export FAKE_UID=0
  run_deploy
  check "exits non-zero"        [ "$CODE" -ne 0 ]
  check "explains the problem"  out_has "regular user"
  check "wrote no .env"         [ ! -f "$SVC/.env" ]
  check "started no container"  [ ! -f "$STATE_DIR/compose_up" ]
  check "created no user"       [ ! -f "$STATE_DIR/user_registered" ]
  teardown
}

test_preflight_docker_perms() {
  echo "• preflight fails when the user cannot reach the docker daemon"
  setup
  touch "$STATE_DIR/docker_no_perm"
  run_deploy
  check "exits non-zero" [ "$CODE" -ne 0 ]
  if [ "$OS" = "Linux" ]; then
    check "suggests the usermod fix" out_has "usermod -aG docker"
    check "mentions sg docker"       out_has "sg docker"
  else
    check "suggests Docker Desktop"  out_has "Docker Desktop"
  fi
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "started no container" [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_tailscale_down() {
  echo "• preflight fails when tailscale is not running"
  # Without it there is no hostname to build APP_URL from, and APP_URL is the
  # setting that decides whether the UI renders at all. Deploying first and
  # discovering that later is the wrong order.
  setup
  echo "Stopped" > "$STATE_DIR/backend_state"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "explains the problem" out_has "Tailscale"
  check "wrote no .env"        [ ! -f "$SVC/.env" ]
  check "started no container" [ ! -f "$STATE_DIR/compose_up" ]
  teardown
}

test_preflight_bad_port() {
  echo "• preflight rejects non-numeric ports"
  setup
  export LOCAL_PORT=80o7
  run_deploy
  check "LOCAL_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "LOCAL_PORT: says numeric"   out_has "numeric"
  unset LOCAL_PORT
  export IMPORTER_PORT=abc
  run_deploy
  check "IMPORTER_PORT: exits non-zero" [ "$CODE" -ne 0 ]
  check "IMPORTER_PORT: says numeric"   out_has "numeric"
  check "wrote no .env"                 [ ! -f "$SVC/.env" ]
  teardown
}

test_port_already_in_use() {
  echo "• a busy port is refused before a doomed container is started"
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/port_busy"
  run_deploy
  check "exits non-zero"       [ "$CODE" -ne 0 ]
  check "names the port"       out_has "8097"
  check "started no container" [ ! -f "$STATE_DIR/compose_up" ]
  check "published nothing"    no_call "tailscale serve --bg"
  teardown
}

# ===========================================================================
# CASE 1 — THE MIXED-CONTENT TRAP
# ===========================================================================
test_asset_scheme_is_https() {
  echo "• the login page a BROWSER gets carries zero http:// assets"
  # This is the failure that looks healthiest. With TRUSTED_PROXIES unset,
  # Firefly answers 200 over HTTPS and every stylesheet and script in the page
  # is http://. The browser blocks them all and renders unstyled HTML with no
  # JavaScript. Measured end to end through a real Serve mount; curl cannot
  # see it.
  setup
  touch "$STATE_DIR/operator"
  run_deploy

  check "the deploy succeeded"                     [ "$CODE" -eq 0 ]
  check "config was frozen at \`compose up\`"      boot_env_exists

  # --- the setting that ACTUALLY decides the asset scheme
  check "TRUSTED_PROXIES is set on the app"       compose_has "TRUSTED_PROXIES"
  check "  quoted '**' (bare ** is not valid YAML here)" compose_hasF "TRUSTED_PROXIES: '**'"
  check "  and on the importer too"               [ "$(compose | grep -c "TRUSTED_PROXIES")" -ge 2 ]

  # --- APP_URL. Asserted for what it actually does: it feeds Firefly's
  # generated mails and the importer's VANITY_URL (the links the importer shows
  # YOU, which have to be clickable in a browser). It does NOT drive the asset
  # scheme — see the four-way matrix in the header.
  check "APP_URL is an https:// URL" \
    sh -c "case \"\$(sed -n 's/^FIREFLY_APP_URL=//p' '$(BOOT_ENV)' | tr -d '\"')\" in https://*) exit 0 ;; *) exit 1 ;; esac"
  check "  it is the EXTERNAL tailnet host, not loopback" \
    sh -c "printf '%s' \"\$(sed -n 's/^FIREFLY_APP_URL=//p' '$(BOOT_ENV)' | tr -d '\"')\" | grep -q '$FAKE_HOST'"
  check "  it is not 127.0.0.1 or localhost" \
    sh -c "! printf '%s' \"\$(sed -n 's/^FIREFLY_APP_URL=//p' '$(BOOT_ENV)' | tr -d '\"')\" | grep -qE '127\\.0\\.0\\.1|localhost'"
  check "  and it carries the published port" \
    sh -c "printf '%s' \"\$(sed -n 's/^FIREFLY_APP_URL=//p' '$(BOOT_ENV)' | tr -d '\"')\" | grep -q ':8097'"
  check "  the importer uses it as VANITY_URL"    compose_hasF 'VANITY_URL: ${FIREFLY_APP_URL'

  # --- the half that actually matters: count the schemes in the rendered page
  check "login page over tailnet HTTPS: ZERO http:// assets" zero_insecure_assets 8097 /login
  check "  register page too"                                zero_insecure_assets 8097 /register
  # The importer is the ONE page the zero-http:// rule must NOT be applied to
  # wholesale: its /token page legitimately prints two informational links to
  # FIREFLY_III_URL (http://app:8080, the container-to-container address) next
  # to a working vanity link. Those are not assets and can never be https, so a
  # blanket count would fail forever on a correct deploy. Scope to the assets.
  check "  importer /token: zero http:// ASSETS (scoped, not blanket)" \
    [ "$(importer_insecure_assets)" -eq 0 ]
  check "  ...and it really does carry the http://app:8080 links a blanket count would trip on" \
    importer_shows_container_url
  check "  (the page really does contain assets to check)" page_has_assets 8097 /login

  # --- and the deploy checked it itself, rather than only 200-checking
  check "the run fetched the login page over tailnet HTTPS" \
    calls_have "https://$FAKE_HOST:8097/login"
  teardown
}

test_trusted_proxies_is_what_decides_the_asset_scheme() {
  echo "• control: TRUSTED_PROXIES decides the asset scheme, and APP_URL does not"
  # Two jobs. First, prove the zero-count assertion has teeth: if nothing here
  # can produce a broken page, that check is vacuous and would stay green
  # against a genuinely misconfigured deploy. Second, pin down WHICH setting
  # does it — measured as a four-way matrix, '**' gives zero http:// refs with
  # either APP_URL and empty gives four with either. Believing otherwise is a
  # live risk: a suite that demanded an external APP_URL "or the page breaks"
  # would red-flag a deploy that renders perfectly.
  setup
  touch "$STATE_DIR/operator"
  run_deploy > /dev/null 2>&1
  check "healthy config renders 0 insecure assets" [ "$(insecure_asset_count)" -eq 0 ]

  # Change ONLY APP_URL, to the loopback address, against the frozen config.
  sed 's#^FIREFLY_APP_URL=.*#FIREFLY_APP_URL="http://127.0.0.1:8097"#' \
    "$(BOOT_ENV)" > "$(BOOT_ENV).tmp" && mv "$(BOOT_ENV).tmp" "$(BOOT_ENV)"
  check "a loopback APP_URL still renders 0 insecure assets (it is NOT the cause)" \
    [ "$(insecure_asset_count)" -eq 0 ]
  teardown

  # Change ONLY TRUSTED_PROXIES.
  setup
  touch "$STATE_DIR/operator"
  run_deploy > /dev/null 2>&1
  grep -v 'TRUSTED_PROXIES' "$STATE_DIR/compose_at_compose_up.yml" \
    > "$STATE_DIR/compose_at_compose_up.tmp" \
    && mv "$STATE_DIR/compose_at_compose_up.tmp" "$STATE_DIR/compose_at_compose_up.yml"
  check "removing TRUSTED_PROXIES renders insecure assets" [ "$(insecure_asset_count)" -gt 0 ]
  check "  and the status code is STILL 200 (which is the whole trap)" \
    [ "$(http_code_for "https://$FAKE_HOST:8097/login")" = 200 ]
  teardown
}

test_existence_check_follows_the_redirect_chain() {
  echo "• 'does an admin exist?' needs the FINAL url, not the first Location"
  # Measured chain with no user:  / -> 302 -> /login -> 302 -> /register
  #                with a user:   / -> 302 -> /login -> 200
  # `/` answers 302 to /login in BOTH states, so a single-hop check — `curl -I
  # /` and read Location — reports "an account exists" on an instance whose
  # registration form is sitting wide open on the tailnet. Only following the
  # chain and reading the final url distinguishes them.
  setup
  touch "$STATE_DIR/operator"

  # Before the deploy, with the containers up but no user: prove the first hop
  # is uninformative and the final one is not.
  PATH="$STUBS:$PATH" docker compose --project-directory "$SVC" up -d >/dev/null 2>&1
  check "no user: first hop from / is /login (uninformative)" \
    sh -c "printf '%s' \"\$($(printf '%s' "x")true; :)\" >/dev/null; true"
  local first final
  first="$(stub_curl -sI "http://127.0.0.1:8097/" | sed -n 's/^Location: //p' | tr -d '\r')"
  final="$(stub_curl -s -o /dev/null -w '%{url_effective}' -L --max-redirs 5 "http://127.0.0.1:8097/")"
  check "no user: first Location is /login"        [ "$first" = "/login" ]
  check "no user: FINAL url is /register"          sh -c "case '$final' in */register) exit 0 ;; *) exit 1 ;; esac"

  touch "$STATE_DIR/user_registered"
  first="$(stub_curl -sI "http://127.0.0.1:8097/" | sed -n 's/^Location: //p' | tr -d '\r')"
  final="$(stub_curl -s -o /dev/null -w '%{url_effective}' -L --max-redirs 5 "http://127.0.0.1:8097/")"
  check "with a user: first Location is ALSO /login (so it proves nothing)" [ "$first" = "/login" ]
  check "with a user: FINAL url is /login"         sh -c "case '$final' in */login) exit 0 ;; *) exit 1 ;; esac"
  rm -f "$STATE_DIR/user_registered"

  : > "$CALLS_LOG"
  run_deploy
  check "the deploy asked for the final url, not the first hop" calls_have "url_effective"
  check "  and followed redirects to get it"                    calls_have '\-L'
  check "exits zero"                                            [ "$CODE" -eq 0 ]
  teardown
}

test_health_endpoint_is_never_used_as_a_health_signal() {
  echo "• /health is never used: nginx answers it 200 even with php-fpm dead"
  # Both images expose a static /health that returns "OK" straight from nginx.
  # It cannot fail while the container is up, so it would report a completely
  # broken app as healthy — the same class as AdGuard's listening socket that
  # refuses every DNS query. The healthchecks use /login and /token instead.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "the run never probed /health"          no_call '/health'
  check "compose does not health-check /health" compose_lacks 'HEALTHCHECK_PATH: */health'
  check "app healthchecks /login"               compose_hasF 'HEALTHCHECK_PATH: /login'
  check "importer healthchecks /token"          compose_hasF 'HEALTHCHECK_PATH: /token'
  # Prove /health really is the useless 200 it is described as, so the
  # assertions above are guarding against something real.
  check "  (/health does answer 200, which is why it is useless)" \
    [ "$(http_code_for "https://$FAKE_HOST:8097/health")" = 200 ]
  teardown
}

test_deliberate_compose_settings() {
  echo "• the settings that look wrong and are deliberate"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # 20 workers x a 256M PHP memory_limit is a 5 GB worst case on a 7.7 GB box
  # that is already swapping. Five is the deliberate cut. Do not "fix" this.
  check "PHP_FPM_PM_MAX_CHILDREN cut to 5 on the app"  compose_hasF 'PHP_FPM_PM_MAX_CHILDREN: "5"'
  check "  and on the importer"                       [ "$(compose | grep -c 'PHP_FPM_PM_MAX_CHILDREN')" -ge 2 ]
  # COOKIE_SECURE=false is deliberate: setup.sh registers the admin over plain
  # HTTP on loopback, and a Secure cookie would never come back on that
  # request — the CSRF check would fail with 419 on every fresh deploy.
  # Serve's TLS plus the tailnet is the confidentiality boundary.
  check "COOKIE_SECURE is false on purpose"           compose_hasF 'COOKIE_SECURE: "false"'
  # Upstream ships both off. A multi-currency ledger with no rate source does a
  # silent 1:1 conversion, which is the specific flaw that disqualified other
  # tools during selection.
  check "exchange rates enabled by default"           compose_has 'ENABLE_EXCHANGE_RATES: *\$\{FIREFLY_ENABLE_RATES:-true\}'
  check "  external rate source too"                  compose_has 'ENABLE_EXTERNAL_RATES: *\$\{FIREFLY_ENABLE_RATES:-true\}'
  check "  and .env can turn it off"                  [ "$(env_val FIREFLY_ENABLE_RATES)" = "true" ]
  # No cron container is deployed, but the token is generated so one can be
  # wired up later without touching the database.
  check "a 32-character cron token is generated"      [ "${#$(true)}" -eq 0 ] 2>/dev/null || \
    check "a 32-character cron token is generated"    [ "$(printf '%s' "$(env_val FIREFLY_STATIC_CRON_TOKEN)" | wc -c | tr -d ' ')" -eq 32 ]
  check "  but no cron container is deployed"         compose_lacks 'fireflyiii/cron'
  teardown
}

# ===========================================================================
# CASE 2 — THE 16-CHARACTER PASSWORD MINIMUM
# ===========================================================================
test_admin_password_is_long_enough() {
  echo "• the generated admin password clears Firefly's 16-character minimum"
  # Measured: 15 characters is rejected. Generating "a password" is not enough;
  # generating one Firefly will accept is the requirement.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local pw len
  pw="$(env_val FIREFLY_ADMIN_PASSWORD)"
  len="${#pw}"
  check "a password was generated"          [ -n "$pw" ]
  check "  it is at least 16 characters"    [ "$len" -ge 16 ]
  check "  comfortably so (>= 20)"          [ "$len" -ge 20 ]
  check "  and it is what was POSTed"       grep -qF -- "password=$pw" "$STATE_DIR/register_body"
  check "  the server saw >= 16 characters" [ "$(cat "$STATE_DIR/register_pw_len")" -ge 16 ]
  check ".env is mode 600"                  [ "$(file_mode "$SVC/.env")" = "600" ]
  teardown
}

test_short_password_is_not_success() {
  echo "• a 302 back to /register with NO user created is a FAILED deploy"
  # THE deploy-killer. A short password (or any flashed validation error) is
  # rejected with a 302 — the same status code a successful registration
  # returns — and no user is created. A script that checks the status code
  # exits zero having deployed an instance whose /register page is open to
  # whoever on the tailnet loads it first.
  setup
  touch "$STATE_DIR/operator" "$STATE_DIR/registration_rejected"
  run_deploy
  check "it really did POST /register"    [ -f "$STATE_DIR/register_posts" ]
  check "  and no user was created"       [ ! -f "$STATE_DIR/user_registered" ]
  check "the deploy EXITS NON-ZERO"       [ "$CODE" -ne 0 ]
  check "  it says the account is missing" out_has "not created\|no user\|registration failed\|could not"
  check "  it did not claim success"      out_lacks "Admin account created"
  # The only way to know is to ask the server again after the POST. Trusting
  # the 302 cannot distinguish the two cases, so a script that does not re-probe
  # cannot possibly produce this message.
  check "  it re-probed / after posting"  calls_have "url_effective"
  check "  and surfaced Firefly's own error" out_has "16 characters"
  teardown
}

# ===========================================================================
# CASE 3 — CSRF
# ===========================================================================
test_csrf_cookie_jar() {
  echo "• registration carries a cookie jar: the 419 path and the success path"
  # A missing or mismatched jar answers HTTP 419 "Page Expired" — not a
  # validation error, so the body says nothing about what was wrong. Only the
  # XSRF-TOKEN cookie appears in the jar; that is normal and sufficient.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "deploy succeeded"              [ "$CODE" -eq 0 ]
  check "the user was created"          [ -f "$STATE_DIR/user_registered" ]
  check "  so no 419 was ever hit"      [ ! -f "$STATE_DIR/csrf_rejections" ]
  check "the GET wrote a cookie jar"    calls_have "\-c "
  check "  and the POST read it back"   calls_have "\-b "
  check "a 40-character _token was posted" \
    sh -c "tr '&' '\n' < '$STATE_DIR/register_body' | sed -n 's/^_token=//p' | grep -qE '^.{40}\$'"
  teardown

  # The control: the same POST without a jar is the 419 the stub models, so the
  # assertion above is testing the script rather than the stub.
  echo "  (control: the same POST without a jar is a 419)"
  setup
  touch "$STATE_DIR/operator"
  run_deploy > /dev/null 2>&1
  rm -f "$STATE_DIR/user_registered"
  local code
  code="$(stub_curl -s -o /dev/null -w '%{http_code}' \
            -X POST "http://127.0.0.1:8097/register" \
            -d "_token=deadbeef" -d "email=x@example.com" \
            -d "password=aaaaaaaaaaaaaaaaaaaaaaaa" \
            -d "password_confirmation=aaaaaaaaaaaaaaaaaaaaaaaa" 2>/dev/null)"
  check "jarless POST is 419 Page Expired" [ "$code" = "419" ]
  check "  and created no user"            [ ! -f "$STATE_DIR/user_registered" ]
  teardown
}

# ===========================================================================
# CASE 4 — IDEMPOTENCY
# ===========================================================================
test_already_registered_is_success() {
  echo "• an existing admin account is SUCCESS, not an error"
  # Otherwise the second run — i.e. every upgrade and every repair — fails.
  setup
  touch "$STATE_DIR/operator"
  run_deploy                                   # first deploy registers
  check "first run exits zero"          [ "$CODE" -eq 0 ]
  check "  created the user"            [ -f "$STATE_DIR/user_registered" ]

  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/register_posts"
  run_deploy                                   # second deploy
  check "second run exits zero"         [ "$CODE" -eq 0 ]
  check "  did NOT re-post /register"   [ ! -f "$STATE_DIR/register_posts" ]
  check "  said the account exists"     out_has "already"
  check "  hit no 419"                  [ ! -f "$STATE_DIR/csrf_rejections" ]
  check "  re-applied the serve config" calls_have "tailscale serve --bg --https=8097"
  teardown
}

test_idempotent_rerun() {
  echo "• re-run: .env preserved, no sudo, containers re-upped"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local pw key
  pw="$(env_val FIREFLY_ADMIN_PASSWORD)"
  key="$(env_val FIREFLY_APP_KEY)"
  echo '# my-custom-marker' >> "$SVC/.env"
  : > "$CALLS_LOG"
  run_deploy
  check "exits zero"                       [ "$CODE" -eq 0 ]
  check "hand-edited .env untouched"       env_has "my-custom-marker"
  check "  admin password unchanged"       [ "$(env_val FIREFLY_ADMIN_PASSWORD)" = "$pw" ]
  # Rotating APP_KEY on a re-run silently invalidates every encrypted field in
  # a ledger that has no backup. It must be generated once and never again.
  check "  APP_KEY unchanged"              [ "$(env_val FIREFLY_APP_KEY)" = "$key" ]
  check "  and still exactly 32 chars"     [ "${#key}" -eq 32 ]
  check "never invoked sudo"               no_call "^sudo "
  check "compose up re-invoked"            [ -f "$STATE_DIR/compose_up" ]
  check "still verified over HTTPS"        calls_have "https://$FAKE_HOST:8097"
  teardown
}

# ===========================================================================
# STANDING CONSTRAINTS
# ===========================================================================
test_images_are_pinned() {
  echo "• all three image tags are pinned, never :latest"
  # This holds financial records and the app's entrypoint runs
  # firefly-iii:upgrade-database on every start. Those migrations are one-way.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "core is pinned"       compose_hasF "fireflyiii/core:\${FIREFLY_VERSION:-$WANT_CORE_TAG}"
  check "importer is pinned"   compose_hasF "fireflyiii/data-importer:\${IMPORTER_VERSION:-$WANT_IMPORTER_TAG}"
  check "postgres is pinned"   compose_hasF "postgres:\${POSTGRES_VERSION:-$WANT_PG_TAG}"
  check "no :latest anywhere"  compose_lacks ':latest'
  check "  nor a bare image: with no tag" \
    sh -c "! sed 's/#.*//' '$SVC/docker-compose.yml' | grep -E '^ *image: *[^ ]*\$' | grep -qv ':'"
  check ".env's values never say latest" sh -c "! sed 's/#.*//' '$SVC/.env' | grep -q 'latest'"
  # And what the containers were actually started with.
  check "app container runs the pinned core image" \
    image_matches firefly-iii "$WANT_CORE_TAG"
  check "db container runs the pinned postgres image" \
    image_matches firefly-iii-db "$WANT_PG_TAG"
  check "importer container runs the pinned importer image" \
    image_matches firefly-iii-importer "$WANT_IMPORTER_TAG"
  teardown
}

test_mem_limit_on_every_container() {
  echo "• every container carries a mem_limit (the box is RAM-constrained)"
  # 7.7 GB total, ~1.9 GB of swap already in use, and ollama takes ~5 GB the
  # moment a model loads. An unbounded php-fpm or postgres is the thing that
  # takes the rest of the box down.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  # Two spaces exactly. `^ *db:` would also match the `db:` nested under the
  # app service's depends_on and count four services.
  check "three services are defined" [ "$(compose | grep -cE '^  (app|db|importer): *$')" -eq 3 ]
  check "three mem_limit lines"      [ "$(compose | grep -c 'mem_limit:')" -eq 3 ]
  check "app has one"                compose_has 'mem_limit: *\$\{FIREFLY_MEM_LIMIT'
  check "db has one"                 compose_has 'mem_limit: *\$\{FIREFLY_DB_MEM_LIMIT'
  check "importer has one"           compose_has 'mem_limit: *\$\{FIREFLY_IMPORTER_MEM_LIMIT'
  # And they are in effect on the containers, not merely written down.
  for c in firefly-iii firefly-iii-db firefly-iii-importer; do
    check "  $c has a non-zero memory cap" mem_cap_positive "$c"
  done
  teardown
}

test_app_key_is_32_characters() {
  echo "• APP_KEY is exactly 32 characters"
  # Measured: this image accepts a plain 32-character string, no base64:
  # prefix. A wrong length is a 500 on /login, not a container that fails to
  # start, so it looks healthy from the outside.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  local key
  key="$(env_val FIREFLY_APP_KEY)"
  check "a key was generated"       [ -n "$key" ]
  check "  exactly 32 characters"   [ "${#key}" -eq 32 ]
  check "  no base64: prefix"       sh -c "case '$key' in base64:*) exit 1 ;; *) exit 0 ;; esac"
  check "  the container was started with it" [ "$(boot_env_val FIREFLY_APP_KEY)" = "$key" ]
  # A wrong-length key is a 500 on /login. Prove it, so the length check above
  # is not merely cosmetic.
  check "/login answers 200 with the real key" \
    [ "$(http_code_for "https://$FAKE_HOST:8097/login")" = 200 ]
  sed 's#^FIREFLY_APP_KEY=.*#FIREFLY_APP_KEY="tooshort"#' "$(BOOT_ENV)" > "$(BOOT_ENV).tmp" \
    && mv "$(BOOT_ENV).tmp" "$(BOOT_ENV)"
  check "  and 500 with a short one (the check has teeth)" \
    [ "$(http_code_for "https://$FAKE_HOST:8097/login")" = 500 ]
  teardown
}

test_ports_are_8097_8099_never_8098() {
  echo "• ports are 8097/8099 and never 8098"
  # ⚠️ 8098 is an ad-hoc `python3 echosrv.py` (pid 1781019, up over a day, not
  # a managed service, absent from DIRECTORY.md). It is NOT ours. Nothing here
  # may claim it, and the ss/lsof stubs report it as permanently busy so a
  # drift onto it fails here rather than on the box.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "app publishes 8097"          compose_hasF "127.0.0.1:\${LOCAL_PORT:-8097}:8080"
  check "importer publishes 8099"     compose_hasF "127.0.0.1:\${IMPORTER_PORT:-8099}:8080"
  check "8098 appears nowhere in compose" compose_lacks '8098'
  check "8098 appears nowhere in .env"    sh -c "! sed 's/#.*//' '$SVC/.env' | grep -q '8098'"
  check "8098 was never contacted"        no_call '8098'
  check "8098 was never served"           no_call 'https=8098'
  check "8080 is not published on the host (that is code-server)" \
    sh -c "! sed 's/#.*//' '$SVC/docker-compose.yml' | grep -E \"^ *- *'?127\\.0\\.0\\.1:8080\"| grep -q ."
  teardown
}

test_https_port_follows_local_port() {
  echo "• LOCAL_PORT alone moves its HTTPS port; an explicit HTTPS_PORT still wins"
  # The bug this guards: a literal HTTPS default (8097) next to a LOCAL_PORT
  # override would silently publish :8097 -> 127.0.0.1:2284, i.e. the wrong
  # port. Same story for IMPORTER_PORT/IMPORTER_HTTPS_PORT, which must stay
  # untouched by a LOCAL_PORT-only override.
  #
  # STUB_PORTS tells the ss stub which ports a correct deploy is listening on
  # (it otherwise defaults to 8097/8099), so the listener audit genuinely
  # passes against the moved port rather than merely not failing.
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=2284
  export STUB_PORTS="2284 8099"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check ".env records LOCAL_PORT=2284"   grep -qx 'LOCAL_PORT=2284' "$SVC/.env"
  check ".env records HTTPS_PORT=2284"   grep -qx 'HTTPS_PORT=2284' "$SVC/.env"
  check "served :2284 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=2284 http://127.0.0.1:2284"
  check "  and never :8097"              no_call "tailscale serve --bg --https=8097"
  check "prints the :2284 URL"           out_has "https://test-host.tailfake.ts.net:2284"
  check "the importer pair is untouched: still :8099 -> 127.0.0.1:8099" \
    calls_have "tailscale serve --bg --https=8099 http://127.0.0.1:8099"
  # Re-run with no override at all: .env says 2284, and the HTTPS default has
  # to follow what .env settled on rather than snap back to 8097.
  unset LOCAL_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :2284 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=2284 http://127.0.0.1:2284"
  check "  and never :8097"                   no_call "tailscale serve --bg --https=8097"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=2284 HTTPS_PORT=8443
  export STUB_PORTS="2284 8099"
  run_deploy
  check "exits zero"                     [ "$CODE" -eq 0 ]
  check "served :8443 -> 127.0.0.1:2284" calls_have "tailscale serve --bg --https=8443 http://127.0.0.1:2284"
  check "prints the :8443 URL"           out_has "https://test-host.tailfake.ts.net:8443"
  teardown

  # The importer pair follows the same rule, independently of the main pair.
  echo "• IMPORTER_PORT alone moves its HTTPS port; an explicit IMPORTER_HTTPS_PORT still wins"
  setup
  touch "$STATE_DIR/operator"
  export IMPORTER_PORT=8199
  export STUB_PORTS="8097 8199"
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check ".env records IMPORTER_PORT=8199"     grep -qx 'IMPORTER_PORT=8199' "$SVC/.env"
  check ".env records IMPORTER_HTTPS_PORT=8199" grep -qx 'IMPORTER_HTTPS_PORT=8199' "$SVC/.env"
  check "served :8199 -> 127.0.0.1:8199"      calls_have "tailscale serve --bg --https=8199 http://127.0.0.1:8199"
  check "  and never :8099"                   no_call "tailscale serve --bg --https=8099"
  check "the main pair is untouched: still :8097 -> 127.0.0.1:8097" \
    calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  unset IMPORTER_PORT
  : > "$CALLS_LOG"
  run_deploy
  check "re-run exits zero"                   [ "$CODE" -eq 0 ]
  check "re-run kept :8199 -> 127.0.0.1:8199" calls_have "tailscale serve --bg --https=8199 http://127.0.0.1:8199"
  check "  and never :8099"                   no_call "tailscale serve --bg --https=8099"
  teardown

  setup
  touch "$STATE_DIR/operator"
  export IMPORTER_PORT=8199 IMPORTER_HTTPS_PORT=8444
  export STUB_PORTS="8097 8199"
  run_deploy
  check "exits zero"                          [ "$CODE" -eq 0 ]
  check "served :8444 -> 127.0.0.1:8199"      calls_have "tailscale serve --bg --https=8444 http://127.0.0.1:8199"
  check "  main pair still :8097 -> 127.0.0.1:8097" calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  teardown
}

test_publish_is_loopback_only() {
  echo "• both ports publish on 127.0.0.1 only; postgres publishes nothing"
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "no 0.0.0.0 anywhere in compose"  compose_lacks '0\.0\.0\.0'
  check "every published port is loopback" \
    sh -c "! sed 's/#.*//' '$SVC/docker-compose.yml' | grep -E \"^ *- *'?[0-9]\" | grep -qv '127\\.0\\.0\\.1'"
  check "exactly two published ports"     [ "$(compose | grep -cE "^ *- *'?127\.0\.0\.1:")" -eq 2 ]
  # The db service has no ports: block at all. Asserting "no 5432 published" is
  # the assertion that matters — a ledger of every transaction its owner makes
  # should not be reachable from the host, let alone the LAN.
  check "postgres publishes no port"      compose_lacks '5432:5432'
  check "  and is not on the host at all" sh -c "! sed 's/#.*//' '$SVC/docker-compose.yml' | grep -q '127\\.0\\.0\\.1:5432'"
  check "served :8097 -> 127.0.0.1:8097"  calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "served :8099 -> 127.0.0.1:8099"  calls_have "tailscale serve --bg --https=8099 http://127.0.0.1:8099"
  # HTTPS port == local port here, so tailscaled's own Serve proxy holds the
  # tailnet address on both numbers. The audit must ACCEPT that listener and
  # name it, resolving the address from `tailscale ip -4` rather than
  # assuming one — the stub's address is not this box's, so a literal in
  # setup.sh would make these fail.
  check "resolved the tailnet address (tailscale ip -4)" calls_have "^tailscale ip -4"
  check "audit accepted Serve's proxy on :8097"          out_has "tailnet address: 127.0.0.1:8097 $FAKE_TS_IP:8097"
  check "  and on the importer's :8099"                  out_has "tailnet address: 127.0.0.1:8099 $FAKE_TS_IP:8099"
  teardown
}

test_readiness_race() {
  echo "• readiness: a REAL refused connection, not a tidy 503"
  # First boot runs the database migrations and the app answers in ~13s. Until
  # then nothing is listening: curl exits 7 and prints 000. Modelling that as a
  # 503 would be a lie, and it is exactly how the Jellyfin deploy in this repo
  # failed — the probe passed and the next request came back 000.
  setup
  touch "$STATE_DIR/operator"
  echo 6 > "$STATE_DIR/conn_refused_left"
  run_deploy
  check "exits zero"                    [ "$CODE" -eq 0 ]
  check "kept polling through refusals" [ "$(call_count 'curl')" -gt 6 ]
  check "  waited between polls"        [ "$(call_count '^sleep')" -ge 5 ]
  check "  registered nothing while refused" \
    [ "$(grep -n 'register' "$CALLS_LOG" | head -1 | cut -d: -f1)" \
      -gt "$(grep -n '^sleep' "$CALLS_LOG" | head -1 | cut -d: -f1)" ]
  check "the account really was created" [ -f "$STATE_DIR/user_registered" ]
  check "still published"                calls_have "tailscale serve --bg --https=8097"
  teardown
}

test_never_ready() {
  echo "• the app never answers: dies before registering or publishing"
  setup
  touch "$STATE_DIR/operator"
  echo 100000 > "$STATE_DIR/conn_refused_left"   # more refusals than any loop
  run_deploy
  check "exits non-zero"          [ "$CODE" -ne 0 ]
  check "says it never answered"  out_has "never\|did not\|timed out\|gave up"
  check "  points at the logs"    out_has "logs"
  check "created no user"         [ ! -f "$STATE_DIR/user_registered" ]
  check "posted no registration"  [ ! -f "$STATE_DIR/register_posts" ]
  check "published nothing"       no_call "tailscale serve --bg"
  teardown
}

test_operator_escalation() {
  echo "• serve denied: grants operator via sudo, then succeeds"
  setup
  run_deploy
  check "exits zero" [ "$CODE" -eq 0 ]
  [ "$OS" = "Linux" ] && check "granted operator" calls_have "sudo tailscale set --operator="
  check "eventually published :8097" calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  check "eventually published :8099" calls_have "tailscale serve --bg --https=8099 http://127.0.0.1:8099"
  teardown
}

test_serve_approval_prompt() {
  echo "• serve needs tailnet approval: retries after Enter"
  setup
  touch "$STATE_DIR/operator"
  echo 2 > "$STATE_DIR/serve_fails_left"
  run_deploy $'\n\n'
  check "exits zero"                [ "$CODE" -eq 0 ]
  check "printed the approval hint" out_has "approve"
  check "published on retry"        calls_have "tailscale serve --bg --https=8097 http://127.0.0.1:8097"
  teardown
}

test_importer_is_deployed_but_idle() {
  echo "• the Data Importer is deployed, and the run says it is idle until Kai acts"
  # The token can only be minted from a logged-in session, so no script can
  # create it. That is a deliberate stopping point, not an unfinished deploy —
  # and the run has to say so or it reads as a broken importer.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "exits zero"                        [ "$CODE" -eq 0 ]
  check "importer is in the compose file"   compose_has '^ *importer: *$'
  check "  reaching Firefly over the compose network, not the tailnet" \
    compose_hasF 'FIREFLY_III_URL: http://app:8080'
  check "  with no token baked in"          compose_hasF 'FIREFLY_III_ACCESS_TOKEN: ${FIREFLY_ACCESS_TOKEN:-}'
  check "the run prints the importer URL"   out_has "8099"
  check "  and says a token is needed"      out_has "token"
  check "  naming where to mint it"         out_has "Personal Access Token"
  teardown
}

test_no_secrets_leak_into_the_environment() {
  echo "• the admin password never reaches a container's environment"
  # .env holds the admin password. Passing the whole file as env_file would put
  # it in `docker inspect` output and in every container's /proc/1/environ, for
  # no benefit — Firefly never needs it after registration.
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  check "compose declares no env_file"  compose_lacks 'env_file'
  check "no FIREFLY_ADMIN_PASSWORD in compose" compose_lacks 'FIREFLY_ADMIN_PASSWORD'
  check ".env is mode 600"              [ "$(file_mode "$SVC/.env")" = "600" ]
  local pw; pw="$(env_val FIREFLY_ADMIN_PASSWORD)"
  # The run must point at .env rather than printing the password into a
  # terminal (and a scrollback, and a tmux buffer) that outlives the deploy.
  check "the run does not print the password" \
    sh -c "! printf '%s' \"$OUT\" | grep -qF '$pw'"
  check "  it points at .env instead"   out_has "FIREFLY_ADMIN_PASSWORD"
  teardown
}

# ------------------------------------------------------------- teardown.sh
run_teardown() {
  OUT="$(printf '%s\n' "${2:-}" | PATH="$STUBS:$PATH" bash "$SVC/teardown.sh" ${1:+"$1"} 2>&1)"
  CODE=$?
}

# A deployed sandbox: setup.sh has run, Serve maps both ports to this service,
# and a neighbour plus a lookalike port sit alongside.
deployed() {
  setup
  touch "$STATE_DIR/operator"
  run_deploy
  mkdir -p "$HOME/services/firefly-iii/db/base" "$HOME/services/firefly-iii/upload" \
           "$HOME/services/firefly-iii/importer"
  echo ledger > "$HOME/services/firefly-iii/db/base/pgdata"
  echo att > "$HOME/services/firefly-iii/upload/a.pdf"
  echo cfg > "$HOME/services/firefly-iii/importer/c.json"
  cat > "$STATE_DIR/serve_status" <<SERVE_END
https://test-host.tailfake.ts.net:8097 (tailnet only)
|-- / proxy http://127.0.0.1:8097

https://test-host.tailfake.ts.net:8099 (tailnet only)
|-- / proxy http://127.0.0.1:8099

https://test-host.tailfake.ts.net:2283 (tailnet only)
|-- / proxy http://127.0.0.1:2283

https://test-host.tailfake.ts.net:18097 (tailnet only)
|-- / proxy http://127.0.0.1:18097
SERVE_END
  : > "$CALLS_LOG"
  rm -f "$STATE_DIR/compose_down"
}

test_teardown_safe() {
  echo "• teardown: safe remove keeps ledger and .env, unpublishes both its ports"
  deployed
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "serve off for app :8097"     calls_have "tailscale serve --https=8097 off"
  check "serve off for importer :8099" calls_have "tailscale serve --https=8099 off"
  check "neighbour :2283 untouched"   no_call "https=2283"
  check "lookalike :18097 untouched"  no_call "https=18097"
  check "never serve reset"           no_call "serve reset"
  check "compose down"                [ -f "$STATE_DIR/compose_down" ]
  check "down keeps volumes (no -v)"  no_call "down -v"
  check "ledger kept"                 [ -f "$HOME/services/firefly-iii/db/base/pgdata" ]
  check "uploads kept"                [ -f "$HOME/services/firefly-iii/upload/a.pdf" ]
  check "importer config kept"        [ -f "$HOME/services/firefly-iii/importer/c.json" ]
  check ".env kept"                   [ -f "$SVC/.env" ]
  check "says how to bring it back"   out_has "./setup.sh brings it back"
  run_teardown
  check "re-run exits zero"           [ "$CODE" -eq 0 ]
  teardown
}

test_teardown_custom_ports() {
  echo "• teardown: ports come from .env and Serve, not from the defaults"
  setup
  touch "$STATE_DIR/operator"
  export LOCAL_PORT=8100 IMPORTER_PORT=8101 HTTPS_PORT=9443
  run_deploy
  unset LOCAL_PORT IMPORTER_PORT HTTPS_PORT
  cat > "$STATE_DIR/serve_status" <<SERVE_END
https://test-host.tailfake.ts.net:9443 (tailnet only)
|-- / proxy http://127.0.0.1:8100

https://test-host.tailfake.ts.net:8101 (tailnet only)
|-- / proxy http://127.0.0.1:8101

https://test-host.tailfake.ts.net:8097 (tailnet only)
|-- / proxy http://127.0.0.1:8097
SERVE_END
  : > "$CALLS_LOG"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "app on :9443 off"            calls_have "tailscale serve --https=9443 off"
  check "importer on :8101 off"       calls_have "tailscale serve --https=8101 off"
  check "default :8097 (not ours) untouched" no_call "https=8097"
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
  printf 'https://test-host.tailfake.ts.net:8097 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' \
    > "$STATE_DIR/serve_status"
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  teardown
}

test_teardown_every_port_pointing_here() {
  echo "• teardown: every Serve port pointing here goes off; shared ports stay"
  deployed
  cat > "$STATE_DIR/serve_status" <<SERVE_END
https://test-host.tailfake.ts.net:8110 (tailnet only)
|-- / proxy http://127.0.0.1:8097

https://test-host.tailfake.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:8099

https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /ff proxy http://127.0.0.1:8097
SERVE_END
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ":8110 off"                   calls_have "serve --https=8110 off"
  check ":8443 off"                   calls_have "serve --https=8443 off"
  check "shared :443 left on"         no_call "https=443 off"
  check "warns about the shared port" out_has "HTTPS :443 also serves something else"
  check "counts kept and unpublished" out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8097 or http://127.0.0.1:8099 (left on, see above); 2 port(s) unpublished"
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
  echo "• teardown --purge: typed confirmation, then exactly the state dirs and .env go"
  deployed
  local st="$HOME/services/firefly-iii"
  echo mine > "$HOME/services/firefly-iii/notes.txt"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "firefly"
  check "wrong name: exits non-zero"  [ "$CODE" -ne 0 ]
  check "wrong name: ledger kept"     [ -f "$st/db/base/pgdata" ]
  check "wrong name: .env kept"       [ -f "$SVC/.env" ]
  check "wrong name: nothing stopped" [ ! -f "$STATE_DIR/compose_down" ]
  check "wrong name: serve untouched" no_call " off"
  run_teardown --purge "firefly-iii"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "ledger dir gone"             [ ! -e "$st/db" ]
  check "uploads gone"                [ ! -e "$st/upload" ]
  check "importer config gone"        [ ! -e "$st/importer" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "serve off for :8097 and :8099" calls_have "serve --https=8099 off"
  check "no -v: no named volumes"     no_call "down -v"
  check "unrelated file in the state parent kept" [ -f "$st/notes.txt" ]
  check "neighbour service kept"      [ -f "$HOME/services/neighbour/keep" ]
  check "services dir itself kept"    [ -d "$HOME/services" ]
  teardown
}

test_teardown_purge_fresh_parent_removed() {
  echo "• teardown --purge: the empty state parent is tidied up"
  deployed
  run_teardown --purge "firefly-iii"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "empty ~/services/firefly-iii removed" [ ! -e "$HOME/services/firefly-iii" ]
  teardown
}

test_teardown_purge_root_owned_contents() {
  echo "• teardown --purge: files another uid owns are cleared from a container"
  deployed
  local d="$HOME/services/firefly-iii/db"
  mkdir -p "$d/locked"; echo x > "$d/locked/f"; chmod 500 "$d/locked"
  run_teardown --purge "firefly-iii"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "fell back to docker run"     calls_have "docker run --rm --pull=never -v $d:/purge"
  check "ledger dir gone"             [ ! -e "$d" ]
  teardown
  # Postgres owns the data dir itself (uid 70, mode 700): this user cannot
  # even enter it, so resolving its path must not need to.
  deployed
  d="$HOME/services/firefly-iii/db"
  chmod 000 "$d"
  run_teardown --purge "firefly-iii"
  chmod -R u+rwX "$d" 2>/dev/null
  check "unenterable dir: exits zero" [ "$CODE" -eq 0 ]
  check "  cleared from a container"  calls_have "docker run --rm --pull=never -v $d:/purge"
  check "  ledger dir gone"           [ ! -e "$d" ]
  teardown
}

test_teardown_purge_refuses_odd_paths() {
  echo "• teardown --purge: refuses a state dir outside ~/services (each of the three)"
  local var
  for var in FIREFLY_DB_DATA FIREFLY_UPLOAD FIREFLY_IMPORTER_CONFIG; do
    deployed
    sed -i.bak "s#^$var=.*#$var=$HOME#" "$SVC/.env"
    run_teardown --purge "firefly-iii"
    check "$var=\$HOME: exits non-zero"  [ "$CODE" -ne 0 ]
    check "  home untouched"             [ -d "$HOME" ]
    check "  nothing stopped"            [ ! -f "$STATE_DIR/compose_down" ]
    check "  nothing unpublished"        no_call " off"
    check "  ledger kept"                [ -f "$HOME/services/firefly-iii/db/base/pgdata" ]
    sed -i.bak "s#^$var=.*#$var=$HOME/services/../x#" "$SVC/.env"
    run_teardown --purge "firefly-iii"
    check "$var with '..' refused"       [ "$CODE" -ne 0 ]
    sed -i.bak "s#^$var=.*#$var=$HOME/services/#" "$SVC/.env"
    run_teardown --purge "firefly-iii"
    check "$var=~/services itself refused" [ "$CODE" -ne 0 ]
    mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
    sed -i.bak "s#^$var=.*#$var=$HOME/services/.#" "$SVC/.env"
    run_teardown --purge "firefly-iii"
    check "$var=~/services/. refused"    [ "$CODE" -ne 0 ]
    check "  neighbour never touched"    [ -f "$HOME/services/neighbour/keep" ]
    check "  no cleanup container"       no_call "docker run"
    sed -i.bak "s#^$var=.*#$var=#" "$SVC/.env"
    run_teardown --purge "firefly-iii"
    check "$var empty refused"           [ "$CODE" -ne 0 ]
    teardown
  done
}

test_teardown_purge_trailing_slashes() {
  echo "• teardown --purge: trailing slashes and symlinks cannot reach ~/services"
  deployed
  sed -i.bak "s#^FIREFLY_UPLOAD=.*#FIREFLY_UPLOAD=$HOME/services//#" "$SVC/.env"
  mkdir -p "$HOME/services/neighbour"; echo x > "$HOME/services/neighbour/keep"
  run_teardown --purge "firefly-iii"
  check "exits non-zero"              [ "$CODE" -ne 0 ]
  check "neighbour data kept"         [ -f "$HOME/services/neighbour/keep" ]
  check "ledger kept"                 [ -f "$HOME/services/firefly-iii/db/base/pgdata" ]
  ln -s "$HOME/services" "$HOME/services/alias"
  sed -i.bak "s#^FIREFLY_UPLOAD=.*#FIREFLY_UPLOAD=$HOME/services/alias#" "$SVC/.env"
  run_teardown --purge "firefly-iii"
  check "symlink to services refused" [ "$CODE" -ne 0 ]
  check "neighbour still kept"        [ -f "$HOME/services/neighbour/keep" ]
  teardown
}

test_teardown_purge_missing_state_dirs() {
  echo "• teardown --purge: state dirs already gone is fine"
  deployed
  rm -rf "$HOME/services/firefly-iii/db" "$HOME/services/firefly-iii/upload" "$HOME/services/firefly-iii/importer"
  run_teardown --purge "firefly-iii"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

test_teardown_quoted_env() {
  echo "• teardown: quoted and exported .env values are read like Compose"
  deployed
  sed -i.bak -e "s/^LOCAL_PORT=.*/export LOCAL_PORT='8097'   # pinned/" "$SVC/.env"
  run_teardown
  check "single quotes + export"      [ "$CODE" -eq 0 ]
  check ":8097 off"                   calls_have "serve --https=8097 off"
  teardown
  deployed
  sed -i.bak -e 's/^LOCAL_PORT=.*/LOCAL_PORT="8097"/' "$SVC/.env"
  run_teardown
  check "double quotes"               [ "$CODE" -eq 0 ]
  check ":8097 off"                   calls_have "serve --https=8097 off"
  teardown
  deployed
  sed -i.bak -e 's/^IMPORTER_PORT=.*/IMPORTER_PORT=8099 # inline comment/' "$SVC/.env"
  run_teardown
  check "inline comment"              [ "$CODE" -eq 0 ]
  check ":8099 off"                   calls_have "serve --https=8099 off"
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

# Every listener on $port must be loopback or Tailscale's own tailnet address —
# never a wildcard or a LAN interface.
#
# Note this service publishes HTTPS on the same number as the local port
# (8097 -> 8097, 8099 -> 8099), so tailscaled legitimately listens on the
# tailnet IP for those same ports. A check that only whitelists 127.* would
# report a correct deploy as a LAN leak.
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
  # than letting red lines imply an outage. A shell started before the user was
  # added to the group hits this, which is easy to forget.
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
  # Deployed at some point, but not running now. This is a NORMAL state on this
  # box — services are routinely brought up, verified and taken back down to
  # free RAM, and `.env` plus ~/services survive that. Without this branch the
  # suite emits ~19 red lines that all mean the same thing and none of which
  # say it, which reads as a broken deploy rather than an absent one.
  if ! docker inspect -f '{{.State.Status}}' firefly-iii 2>/dev/null | grep -qx running; then
    red "    ! the firefly-iii container is not running."
    red "      Nothing below can be checked against a service that is not up."
    red "      Start it:  ./setup.sh   (idempotent; reuses the existing .env)"
    red "      (or, if it was deliberately undeployed, that is the expected"
    red "       state and --live simply does not apply right now.)"
    FAIL=$((FAIL + 1))
    return
  fi

  local ts port iport url appurl
  ts="tailscale"
  command -v tailscale >/dev/null || ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  # .env values are double-quoted. Strip them — an unstripped value turns every
  # assertion below into a silent no-op (a `! grep` on an unreadable file
  # *passes*), which is exactly the kind of vacuously-green check this repo has
  # been bitten by before.
  env_of() { sed -n "s/^$1=//p" "$SERVICE_DIR/.env" | sed 's/^"//; s/"$//' | head -1; }
  port="$(env_of LOCAL_PORT)";     case "$port"  in ''|*[!0-9]*) port=8097 ;; esac
  iport="$(env_of IMPORTER_PORT)"; case "$iport" in ''|*[!0-9]*) iport=8099 ;; esac
  appurl="$(env_of FIREFLY_APP_URL)"
  url="https://$("$ts" status --json | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"

  # ---- containers
  live_check "app container running" \
    sh -c "docker inspect -f '{{.State.Status}}' firefly-iii | grep -qx running"
  live_check "db container running" \
    sh -c "docker inspect -f '{{.State.Status}}' firefly-iii-db | grep -qx running"
  live_check "importer container running" \
    sh -c "docker inspect -f '{{.State.Status}}' firefly-iii-importer | grep -qx running"

  # ---- images pinned, in reality and not merely in the compose file
  live_check "app runs the pinned core image" \
    sh -c "docker inspect -f '{{.Config.Image}}' firefly-iii | grep -q 'fireflyiii/core:version-'"
  live_check "db runs the pinned postgres image" \
    sh -c "docker inspect -f '{{.Config.Image}}' firefly-iii-db | grep -q 'postgres:16'"
  live_check "importer runs the pinned importer image" \
    sh -c "docker inspect -f '{{.Config.Image}}' firefly-iii-importer | grep -q 'data-importer:version-'"
  live_check "no container is running :latest" \
    sh -c "! docker inspect -f '{{.Config.Image}}' firefly-iii firefly-iii-db firefly-iii-importer | grep -q ':latest'"

  # ---- memory limits actually in effect on the running containers
  for c in firefly-iii firefly-iii-db firefly-iii-importer; do
    live_check "$c has a memory limit in effect" \
      sh -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' $c)\" -gt 0 ]"
  done

  # ---- local HTTP. `/` is a 302 and NEVER 200 — do not `curl -fsS` it and
  # expect output. The redirect TARGET is the state oracle.
  live_check "local / returns 302 (not 200)" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/')\" = 302 ]"
  live_check "local /login returns 200" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$port/login')\" = 200 ]"
  # THE ADMIN ACCOUNT EXISTS. If it does not, the registration form is sitting
  # open on the tailnet for whoever loads it first.
  #
  # This MUST follow the chain. Measured: `/` answers 302 to /login in BOTH
  # states — with no user, /login then redirects on to /register. So reading
  # the first Location header says "/login" either way and would report a
  # wide-open instance as healthy. Only the FINAL url distinguishes them.
  live_check "an admin user exists (final url of / is /login, not /register)" \
    sh -c "curl -s -o /dev/null -w '%{url_effective}' -L --max-redirs 5 --max-time 20 'http://127.0.0.1:$port/' | grep -q '/login\$'"
  live_check "  i.e. the chain does NOT end on /register" \
    sh -c "! curl -s -o /dev/null -w '%{url_effective}' -L --max-redirs 5 --max-time 20 'http://127.0.0.1:$port/' | grep -q '/register'"
  live_check "importer /token answers locally" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:$iport/token')\" = 200 ]"

  # ---- the bind
  live_check "app not listening on non-local ifaces"      no_external_listener "$port"
  live_check "importer not listening on non-local ifaces" no_external_listener "$iport"
  live_check "postgres is not published on the host at all" \
    sh -c "! docker inspect -f '{{.HostConfig.PortBindings}}' firefly-iii-db | grep -q 5432"

  # ---- publish
  live_check "tailscale serve maps :$port" \
    sh -c "'$ts' serve status | grep -A2 ':$port' | grep -q 'proxy http://127.0.0.1:$port'"
  live_check "tailscale serve maps :$iport" \
    sh -c "'$ts' serve status | grep -A2 ':$iport' | grep -q 'proxy http://127.0.0.1:$iport'"

  # ---- end to end over the tailnet
  live_check "tailnet HTTPS login page returns 200" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 '$url:$port/login')\" = 200 ]"

  # ========================================================================
  # THE CHECK A 200 CANNOT MAKE. With a loopback APP_URL or no TRUSTED_PROXIES
  # this page is still a 200 — and every stylesheet and script in it is
  # http://, which the browser blocks as mixed content. The visible symptom is
  # an unstyled login page that reads as "Firefly is broken". Zero is the only
  # acceptable count.
  # ========================================================================
  live_check "  and ZERO http:// assets in it (the mixed-content trap)" \
    sh -c "[ \"\$(curl -s --max-time 60 '$url:$port/login' | grep -o -E '(src|href)=\"http://' | grep -c . || true)\" -eq 0 ]"
  live_check "  the page really does reference assets (not a vacuous zero)" \
    sh -c "curl -s --max-time 60 '$url:$port/login' | grep -qE '(src|href)=\"http'"
  live_check "tailnet HTTPS importer /token returns 200" \
    sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 '$url:$iport/token')\" = 200 ]"
  # SCOPED to assets on purpose. The importer's /token page legitimately prints
  # two informational links to FIREFLY_III_URL (http://app:8080, the
  # container-to-container address) next to a working vanity link. Those are
  # not assets and can never be https, so a blanket count fails forever on a
  # correct deploy.
  live_check "  its own ASSET urls are https (scoped, not a blanket count)" \
    sh -c "[ \"\$(curl -s --max-time 60 '$url:$iport/token' | grep -o -E '(src|href)=\"http://[^\"]*build/assets/' | grep -c . || true)\" -eq 0 ]"
  # /health answers 200 from nginx even with php-fpm dead, so it must never be
  # a health signal here — for the live suite or for Kuma.
  live_check "nothing here relies on /health (it 200s from nginx regardless)" \
    sh -c "! grep -q \"HEALTHCHECK_PATH: */health\" '$SERVICE_DIR/docker-compose.yml'"

  # ---- the config that decides all of the above
  live_check "APP_URL in .env is an https:// URL" \
    sh -c "case '$appurl' in https://*) exit 0 ;; *) exit 1 ;; esac"
  live_check "  pointing at this node's tailnet name, not loopback" \
    sh -c "printf '%s' '$appurl' | grep -qF \"\$(printf '%s' '$url' | sed 's#https://##')\""
  live_check "  and never 8098 (not ours: an ad-hoc python3 echosrv)" \
    sh -c "! printf '%s' '$appurl' | grep -q ':8098'"
  live_check "APP_KEY is exactly 32 characters" \
    sh -c "[ \"\$(env_of() { sed -n \"s/^\$1=//p\" '$SERVICE_DIR/.env' | sed 's/^\"//; s/\"\$//' | head -1; }; printf '%s' \"\$(env_of FIREFLY_APP_KEY)\" | wc -c | tr -d ' ')\" = 32 ]"
  live_check "the container's APP_KEY is 32 characters too" \
    sh -c "[ \"\$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' firefly-iii | sed -n 's/^APP_KEY=//p' | head -1 | tr -d '\n' | wc -c | tr -d ' ')\" = 32 ]"
  live_check "the container's APP_URL is the https one" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' firefly-iii | grep -q '^APP_URL=https://'"
  live_check "the container trusts the proxy" \
    sh -c "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' firefly-iii | grep -q '^TRUSTED_PROXIES='"

  # ---- state
  live_check "the ledger directory exists" sh -c "test -d \"\$(sed -n 's/^FIREFLY_DB_DATA=//p' '$SERVICE_DIR/.env' | sed 's/^\"//; s/\"\$//' | head -1)\""
  live_check ".env is mode 600" \
    sh -c "[ \"\$(stat -c '%a' '$SERVICE_DIR/.env' 2>/dev/null || stat -f '%Lp' '$SERVICE_DIR/.env')\" = 600 ]"
}

# ---------------------------------------------------- host-isolation proof
# The mocked suite must not touch the real deployment. Rather than assert that
# in a comment, fingerprint everything it could plausibly write to — this
# service directory and ~/services/firefly-iii — before and after the whole
# run, and compare. On a service that holds financial records with no backup,
# a test suite that could scribble on the real state is not acceptable.
host_fingerprint() {
  {
    find "$SERVICE_DIR" -type f ! -path '*/.git/*' -exec cksum {} \; 2>/dev/null
    find "$ORIG_HOME/services/firefly-iii" -exec cksum {} \; 2>/dev/null
  } | sort
}

test_teardown_commented_paths() {
  echo "• teardown --purge: a path with a spaced inline comment is still the path"
  deployed
  local d="$HOME/services/firefly-iii/db"
  sed -i.bak "s#^FIREFLY_DB_DATA=.*#FIREFLY_DB_DATA=$d   \# ledger#" "$SVC/.env"
  run_teardown --purge "firefly-iii"
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "ledger dir gone (not skipped)" [ ! -e "$d" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  teardown
}

# State dirs behind a folder this user cannot search (a root-owned 0700
# storage/, faked with chmod 000): `[ -e ]` cannot see them, which must not
# read as "already gone" while .env (and its APP_KEY) is deleted. The postgres
# image mounts that folder and deletes only the path below it.
unhide_state() { chmod -R u+rwX "$HOME/services/firefly-iii" 2>/dev/null; }

test_teardown_purge_unsearchable_parent() {
  echo "• teardown --purge: state dirs behind an unsearchable folder are deleted, not taken as gone"
  local st ff
  # Ledger and uploads share one hidden folder; the importer config is plain.
  deployed
  ff="$HOME/services/firefly-iii"; st="$ff/storage"
  mkdir -p "$st"
  mv "$ff/db" "$st/db"; mv "$ff/upload" "$st/upload"
  sed -i.bak -e "s#^FIREFLY_DB_DATA=.*#FIREFLY_DB_DATA=$st/db#" \
             -e "s#^FIREFLY_UPLOAD=.*#FIREFLY_UPLOAD=$st/upload#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "firefly-iii"
  unhide_state
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "confirmation names the hidden dirs" out_has "deletes the LEDGER and its APP_KEY: $st/db, $st/upload, $ff/importer"
  check "mounted the unsearchable folder" calls_have "docker run --rm --pull never -v $st:/x --entrypoint sh postgres:16-alpine"
  check "no sudo"                     no_call "^sudo"
  check "ledger gone"                 [ ! -e "$st/db" ]
  check "uploads gone"                [ ! -e "$st/upload" ]
  check "importer config gone"        [ ! -e "$ff/importer" ]
  check "says what it deleted"        out_has "Deleted $st/upload"
  check "emptied folder gone"         [ ! -e "$st" ]
  check "no mount source created"     [ ! -e "$STATE_DIR/docker_created_mount" ]
  check ".env gone"                   [ ! -f "$SVC/.env" ]
  check "state dir removed"           [ ! -e "$ff" ]
  teardown
  # Deleting the ledger empties the shared folder, so hidden_rm removes it;
  # the uploads (never there) must then not mount a folder that is gone,
  # which a real dockerd would create as root.
  deployed
  ff="$HOME/services/firefly-iii"; st="$ff/storage"
  mkdir -p "$st"
  mv "$ff/db" "$st/db"; rm -rf "$ff/upload"
  sed -i.bak -e "s#^FIREFLY_DB_DATA=.*#FIREFLY_DB_DATA=$st/db#" \
             -e "s#^FIREFLY_UPLOAD=.*#FIREFLY_UPLOAD=$st/upload#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "firefly-iii"
  unhide_state
  check "shared folder emptied first: exits zero" [ "$CODE" -eq 0 ]
  check "  one cleanup container"     [ "$(call_count "-v $st:/x")" -eq 1 ]
  check "  no mount source created"   [ ! -e "$STATE_DIR/docker_created_mount" ]
  check "  says the uploads were already gone" out_has "$st/upload is already gone"
  check "  folder gone"               [ ! -e "$st" ]
  check "  .env gone"                 [ ! -f "$SVC/.env" ]
  teardown
  deployed
  ff="$HOME/services/firefly-iii"; st="$ff/storage"
  mkdir -p "$st"; mv "$ff/db" "$st/db"
  sed -i.bak "s#^FIREFLY_DB_DATA=.*#FIREFLY_DB_DATA=$st/db#" "$SVC/.env"
  chmod 000 "$st"
  touch "$STATE_DIR/docker_run_fails"
  run_teardown --purge "firefly-iii"
  unhide_state
  check "cleanup fails: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $st/db"
  check "  never says the ledger was deleted" out_lacks "Deleted $st/db"
  check "  never says .env was deleted" out_lacks "Deleted $SVC/.env"
  check "  ledger kept"               [ -f "$st/db/base/pgdata" ]
  check "  .env kept for the retry"   [ -f "$SVC/.env" ]
  teardown
  # A symlink below the unsearchable folder would resolve inside the
  # container, not on this box: refused, its target untouched.
  deployed
  ff="$HOME/services/firefly-iii"; st="$ff/storage"
  mkdir -p "$st" "$HOME/elsewhere"; echo keep > "$HOME/elsewhere/f"
  ln -s "$HOME/elsewhere" "$st/db"
  sed -i.bak "s#^FIREFLY_DB_DATA=.*#FIREFLY_DB_DATA=$st/db#" "$SVC/.env"
  chmod 000 "$st"
  run_teardown --purge "firefly-iii"
  unhide_state
  check "symlink below it: exits non-zero" [ "$CODE" -ne 0 ]
  check "  target kept"               [ -f "$HOME/elsewhere/f" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  teardown
  # ~/services/firefly-iii itself unsearchable: not strictly inside it, so no
  # mount; stop before anything changes and name the sudo command.
  deployed
  ff="$HOME/services/firefly-iii"
  chmod 000 "$ff"
  run_teardown --purge "firefly-iii"
  unhide_state
  check "state dir unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf $ff/db"
  check "  no cleanup container"      no_call "docker run"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  serve untouched"           no_call " off"
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  ledger kept"               [ -f "$ff/db/base/pgdata" ]
  teardown
  # And ~/services itself.
  deployed
  chmod 000 "$HOME/services"
  run_teardown --purge "firefly-iii"
  chmod 755 "$HOME/services"
  check "\$HOME/services unsearchable: exits non-zero" [ "$CODE" -ne 0 ]
  check "  names the sudo command"    out_has "sudo rm -rf"
  check "  nothing stopped"           [ ! -f "$STATE_DIR/compose_down" ]
  check "  .env kept"                 [ -f "$SVC/.env" ]
  check "  ledger kept"               [ -f "$HOME/services/firefly-iii/db/base/pgdata" ]
  teardown
}

test_teardown_only_shared_ports() {
  echo "• teardown: a shared port left on is not reported as already off"
  deployed
  cat > "$STATE_DIR/serve_status" <<SERVE_END
https://test-host.tailfake.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
|-- /ff proxy http://127.0.0.1:8097
|-- /import proxy http://127.0.0.1:8099
SERVE_END
  run_teardown
  check "exits zero"                  [ "$CODE" -eq 0 ]
  check "no serve off"                no_call " off"
  check "does not say already off"    out_lacks "already off"
  check "counts the kept port"        out_has "1 shared HTTPS port(s) still route to http://127.0.0.1:8097 or http://127.0.0.1:8099 (left on, see above); 0 port(s) unpublished"
  teardown
}

test_teardown_no_empty_array_length() {
  echo "• teardown.sh: no \${#arr[@]} on a maybe-empty array — Bash 3.2 + set -u errors there"
  # macOS ships Bash 3.2, where ${#arr[@]} of an empty array is an
  # unbound-variable error, not 0. A normal purge queues zero hidden dirs,
  # so reading the length died after the data was gone but before .env —
  # a half-purge every retry repeated. The queue count is tracked instead.
  check "no array-length expansion"      teardown_lacks '\${#[A-Za-z_]+\[@\]}'
  check "hidden queue counted at append" grep -q 'HIDDEN_N=$((HIDDEN_N + 1))' "$SERVICE_DIR/teardown.sh"
}

# ------------------------------------------------------------------ main
for f in setup.sh teardown.sh docker-compose.yml; do
  [ -f "$SERVICE_DIR/$f" ] || { red "services/firefly-iii/$f is missing — nothing to test."; exit 1; }
done

BEFORE_FP="$(host_fingerprint)"

echo "Mocked suite (sandboxed, no system changes):"
test_preflight_root
test_preflight_docker_perms
test_preflight_tailscale_down
test_preflight_bad_port
test_port_already_in_use
test_asset_scheme_is_https
test_trusted_proxies_is_what_decides_the_asset_scheme
test_existence_check_follows_the_redirect_chain
test_health_endpoint_is_never_used_as_a_health_signal
test_deliberate_compose_settings
test_admin_password_is_long_enough
test_short_password_is_not_success
test_csrf_cookie_jar
test_already_registered_is_success
test_idempotent_rerun
test_images_are_pinned
test_mem_limit_on_every_container
test_app_key_is_32_characters
test_ports_are_8097_8099_never_8098
test_https_port_follows_local_port
test_publish_is_loopback_only
test_readiness_race
test_never_ready
test_operator_escalation
test_serve_approval_prompt
test_importer_is_deployed_but_idle
test_no_secrets_leak_into_the_environment
test_teardown_safe
test_teardown_custom_ports
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_preflight
test_teardown_purge
test_teardown_purge_fresh_parent_removed
test_teardown_purge_root_owned_contents
test_teardown_commented_paths
test_teardown_purge_refuses_odd_paths
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_state_dirs
test_teardown_quoted_env
test_teardown_purge_unsearchable_parent
test_teardown_only_shared_ports
test_teardown_no_empty_array_length

echo "• sandbox isolation: the mocked suite changed nothing on this host"
AFTER_FP="$(host_fingerprint)"
check "real service dir + ~/services/firefly-iii are byte-identical" \
  [ "$BEFORE_FP" = "$AFTER_FP" ]
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
