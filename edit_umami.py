p='tests/stubs/tailscale'
s=open(p).read()
old='''#   serve_fails_left    — countdown of forced serve failures (approval-link flow)
echo "tailscale $*" >> "$CALLS_LOG"
'''
assert old in s
s=s.replace(old,'''#   serve_fails_left    — countdown of forced serve failures (approval-link flow)
#   serve_status        — text `tailscale serve status` prints (teardown tests)
#   serve_status_fails  — exists => `serve status` fails like a stopped daemon
echo "tailscale $*" >> "$CALLS_LOG"

if [ "$1" = "serve" ] && [ "${2:-}" = "status" ]; then
  if [ -f "$STATE_DIR/serve_status_fails" ]; then
    echo "failed to connect to local tailscaled" >&2
    exit 1
  fi
  [ -f "$STATE_DIR/serve_status" ] && cat "$STATE_DIR/serve_status"
  exit 0
fi
case " $* " in *" off "*) [ "$1" = "serve" ] && exit 0 ;; esac
''',1)
open(p,'w').write(s)

p='tests/run-tests.sh'
s=open(p).read()
a='cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"'
assert a in s
s=s.replace(a,'cp "$SERVICE_DIR/setup.sh" "$SERVICE_DIR/teardown.sh" "$SERVICE_DIR/docker-compose.yml" "$SVC/"',1)
s=s.replace('compose_hasF() {','''data_dir() { sed -n 's/^UMAMI_DATA=//p' "$SVC/.env"; }
compose_hasF() {''',1)
T=open('/tmp/claude-1000/-home-kaichen-dev-setup-server/4ea01c66-9e37-4ef4-b0b4-c11227d68eff/scratchpad/teardown_tests.sh').read()
anchor='if [ ! -f "$SERVICE_DIR/setup.sh" ] || [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then'
assert anchor in s
s=s.replace(anchor,T+anchor,1)
m='test_serve_approval_prompt\n\nif'
assert m in s
s=s.replace(m,'''test_serve_approval_prompt
test_teardown_safe
test_teardown_not_published
test_teardown_port_owned_by_someone_else
test_teardown_preflight
test_teardown_purge
test_teardown_purge_refuses_odd_paths
test_teardown_every_port_pointing_here
test_teardown_serve_status_fails
test_teardown_quoted_env
test_teardown_purge_trailing_slashes
test_teardown_purge_missing_data_dir

if''',1)
open(p,'w').write(s)

p='TROUBLESHOOT.md'
s=open(p).read()
i=s.index('## Nuke and pave')
s=s[:i]+open('/tmp/claude-1000/-home-kaichen-dev-setup-server/4ea01c66-9e37-4ef4-b0b4-c11227d68eff/scratchpad/nuke.md').read()
open(p,'w').write(s)

p='SETUP.md'
s=open(p).read()
a='Backup target:'
assert a in s
s=s.replace(a,'''Remove: `./teardown.sh` (or Remove in the launcher) unpublishes the Serve
port(s) pointing at `LOCAL_PORT` and runs `compose down`; the `umami-postgres`
volume and `.env` stay, so `./setup.sh` brings it back. `./teardown.sh --purge`
also deletes the volume (all analytics), the marker dir and `.env`, after you
type `umami`. From a terminal, pause the `umami` monitor in Uptime Kuma first.

'''+a,1)
open(p,'w').write(s)
