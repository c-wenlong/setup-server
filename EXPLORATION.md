# Exploration — future home-server services

Ideas surveyed 2026-09-07, ranked by bang-for-effort for this box
(Ryzen 5 2600, 7.7 GB RAM, ~150 GB free disk, tailnet-only philosophy).
Already running: code-server, Seafile (Drive), ollama (local LLM).

## Network-level wins (near-zero resources, biggest daily impact)

- **AdGuard Home as tailnet DNS** — ad/tracker blocking for every device on
  the tailnet, everywhere (cellular included): point Tailscale DNS at it.
  ~50 MB RAM. Highest QoL-per-megabyte available. ← top pick for next service
- **Tailscale exit node** — not even a service: `tailscale set
  --advertise-exit-node`. Route phone/laptop traffic through home for safe
  public wifi and home IP while traveling.

## Ops for what's already built

- **Uptime Kuma** — status dashboard + HTTP/docker/cert-expiry checks for
  code-server, Seafile, etc. ✅ done (monitoring/)
- **ntfy** — self-hosted push notifications to iPhone; pairs with Kuma
  ("server tells phone when something breaks") and could carry auth links.
  ✅ done (monitoring/)

## Memories & media

- **Immich** — self-hosted Google Photos (timeline, faces, semantic search,
  iOS auto-backup). Overlaps Seafile camera upload — pick one photo system.
  Heaviest option here (~2–3 GB with ML); the trigger for a storage drive.
  ✅ done (immich/) — deployed 2026-09-10 with ML off until this box has
  more RAM.
  Surveyed against PhotoPrism (no native mobile app → no background backup,
  paywalled multi-user) and Ente (server idles at 130–500 MB because all ML
  is on-device, true E2EE — the better pick *if* E2EE outranks polish, at the
  cost of MinIO/CORS setup and a smaller community).
- **Jellyfin** — Netflix for your own media library; CPU transcoding handles
  1080p fine on this box.

## Knowledge & documents

- **Paperless-ngx** — OCR'd, searchable archive of receipts/contracts/tax
  docs. Life-admin superpower.
- **Karakeep** — bookmarks/read-later with auto-tagging + summaries via the
  local ollama.
- **Open WebUI** — ChatGPT-style UI over ollama, phone-friendly. ✅ done (open-webui/)

## Dev infra

- **Self-hosted GitHub Actions runner** — free unlimited CI minutes for
  existing GitHub repos; more practical than self-hosting git.
- **Forgejo** — full self-hosted GitHub (repos + CI). Sovereignty hobby more
  than need while GitHub works fine.

## Notes

- RAM budget is the constraint: ollama claims ~5 GB while a model is loaded;
  keep new always-on services in the tens-of-MB class (AdGuard, ntfy, Kuma)
  and treat Immich as a project, not an add-on.
- Every service follows the repo conventions (AGENTS.md): tailnet-only,
  idempotent setup.sh, mocked + live tests.
- Known loose end: ollama listens on *:11434 (all interfaces) via a systemd
  override — reachable from LAN, not just localhost/tailnet. Consider
  tightening to 127.0.0.1 if nothing on the LAN needs it.
