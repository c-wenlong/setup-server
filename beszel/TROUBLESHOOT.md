# beszel — troubleshooting

Work top-down; each layer assumes the one above it is fine.

If any `docker` command below says "permission denied while trying to connect
to the docker API", you are not in the `docker` group *in this shell* — a
shell opened before the group was granted never picks it up, and
`docker inspect` will report a perfectly healthy container as not running.
Re-run under `sg docker -c '...'`. The beszel-agent unit is unaffected by
this — it opens the socket itself and has been running since before you
opened the shell.

## 1. Dashboard unreachable (browser)

- `curl -s http://127.0.0.1:8092/api/health` on the box — expect
  `{"message":"API is healthy.","code":200,...}`. Works → it's the tailnet
  path: `tailscale serve status` should map :8092 →
  `http://127.0.0.1:8092`; re-add with
  `tailscale serve --bg --https=8092 http://127.0.0.1:8092`.
  ⚠️ Never `tailscale serve reset` to "clean up" a bad mapping — it clears
  every mapping on the node, taking every published service down at once and
  requiring each one's `setup.sh` to be re-run. The single-port removal is
  `tailscale serve --https=8092 off`; `off` is missing from
  `tailscale serve --help` on 1.102.3 (which only advertises `reset` and
  `clear`) but is what Tailscale prints after a successful serve, and is
  verified working here.
- Fails → `sg docker -c 'docker ps -a | grep beszel'`,
  `sg docker -c 'docker logs beszel --tail 50'`.
  Container missing → rerun setup.sh.
- Faster than either from a phone: the launcher at
  `https://kai-home-server.taild6a23f.ts.net/home/` shows beszel's live
  status and has start/stop/restart buttons (they move the hub container and
  the agent unit together, in the right order).

## 2. Can't log in

- Credentials are in `.env` here (`BESZEL_ADMIN_EMAIL` / `_PASSWORD`).
- If the password was changed in the UI, the `.env` copy is stale (same
  password-sync rule as Kuma/n8n — see DIRECTORY.md). Reset:
  `docker exec beszel /beszel superuser upsert <email> <newpass>` then
  mirror into `.env`.

## 3. System shows "down" / no data points

- Agent alive? `systemctl --user status beszel-agent`;
  `journalctl --user -u beszel-agent -n 30`.
- Crash loop with a key error → the unit's `Environment="KEY=..."` lost its
  quoting (the key contains a space — must stay quoted). Rerun setup.sh,
  which rewrites the unit and always restarts the agent.
- Agent fine but hub can't reach it: `ss -ltn | grep 45876` must show
  `127.0.0.1:45876`, and the hub MUST be `network_mode: host` — a
  bridge-network hub dialing 127.0.0.1 reaches itself, not the agent
  (the original deploy bug, twice over).
- Beszel's own Kuma monitor red while the dashboard loads fine → the monitor
  probes the *tailnet* URL (`https://…:8092/api/health`), not loopback, so it
  goes red for a publishing failure too. Curl `http://127.0.0.1:8092/api/health`
  first: if that answers, the fault is Tailscale Serve or the cert, not the
  hub. Everything red at once is tailscaled, not every service failing at the
  same moment.

## 4. Missing metric families

- **GPU**: unit needs `Environment="GPU=true"`; `nvidia-smi` must work as
  the user. `journalctl --user -u beszel-agent | grep -i gpu`.
- **Temperatures**: hwmon must be readable — `ls /sys/class/hwmon/` and
  `cat /sys/class/hwmon/hwmon*/temp1_input`.
- **Per-container stats**: user must be in the `docker` group (agent reads
  /var/run/docker.sock). If the group was granted *after* the agent's session
  started, `systemctl --user restart beszel-agent` picks it up.
- **Containers that vanish from the list**: kaichenpedia and n8n are
  deliberately stopped on this box, so they have no stats. Not a fault.

## 5. Stats stale / gaps in graphs

- Check RAM pressure (`free -h`) — this box swaps hard during video builds;
  the agent itself is tiny but the hub's writes can lag under thrash.
- Records are per-minute; PocketBase aggregates older data. Gaps aligned
  with restarts of the agent unit are expected and harmless.

## Last resort

`docker compose --project-directory . down`, move `~/services/beszel/hub`
aside, rerun setup.sh — fresh hub, agent re-registers, history lost.
