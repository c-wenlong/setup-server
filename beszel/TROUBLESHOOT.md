# beszel — troubleshooting

Work top-down; each layer assumes the one above it is fine.

## 1. Dashboard unreachable (browser)

- `curl -s http://127.0.0.1:8092/api/health` on the box. Works → it's the
  tailnet path: `tailscale serve status` should map :8092 →
  `http://127.0.0.1:8092`; re-add with
  `tailscale serve --bg --https=8092 http://127.0.0.1:8092`.
- Fails → `docker ps -a | grep beszel`, `docker logs beszel --tail 50`.
  Container missing → rerun setup.sh.

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

## 4. Missing metric families

- **GPU**: unit needs `Environment="GPU=true"`; `nvidia-smi` must work as
  the user. `journalctl --user -u beszel-agent | grep -i gpu`.
- **Temperatures**: hwmon must be readable — `ls /sys/class/hwmon/` and
  `cat /sys/class/hwmon/hwmon*/temp1_input`.
- **Per-container stats**: user must be in the `docker` group (agent reads
  /var/run/docker.sock).

## 5. Stats stale / gaps in graphs

- Check RAM pressure (`free -h`) — this box swaps hard during video builds;
  the agent itself is tiny but the hub's writes can lag under thrash.
- Records are per-minute; PocketBase aggregates older data. Gaps aligned
  with restarts of the agent unit are expected and harmless.

## Last resort

`docker compose --project-directory . down`, move `~/services/beszel/hub`
aside, rerun setup.sh — fresh hub, agent re-registers, history lost.
