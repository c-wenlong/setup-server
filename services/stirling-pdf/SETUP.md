# stirling-pdf — locally hosted PDF toolbox

Merge, split, compress, OCR, convert, rotate, watermark — 60+ PDF tools
in the browser, on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8103`.

Chosen over a SaaS PDF site (files leave the tailnet) and over a pile of
CLI tools. Stirling PDF is the documented self-host for this job
([docs.stirlingpdf.com](https://docs.stirlingpdf.com/Installation/Docker%20Install/)).

Official wants login **on**, with a well-known `admin` / `stirling` pair.
This deploy opts out: `SECURITY_ENABLELOGIN=false`. The tailnet is the
access boundary. Do not flip login on without changing that password.

Standard image (`2.14.3`), not `-fat` (extra fonts, much larger) and not
`-ultra-lite` (drops OCR). Java, so RAM spikes on a conversion; compose
caps the container at 1536 MiB.

**`:8080` is taken.** code-server already publishes VS Code there.
Stirling's upstream default is 8080; this deploy uses **8103**.

## Architecture

```
  phone / laptop on the tailnet
            │  https://kai-home-server.taild6a23f.ts.net:8103
            ▼
     tailscaled  (Tailscale Serve — terminates TLS, tailnet only)
            │  http://127.0.0.1:8103
            ▼
   ┌────────────────────────────────────────────┐
   │ container: stirling-pdf                    │
   │   docker.stirlingpdf.com/…:2.14.3          │
   │   web + API                 :8080          │
   └──────────────────┬─────────────────────────┘
                      │ bind mounts
                      ▼
            ~/services/stirling-pdf/
```

State lives under `~/services/stirling-pdf`:

```
~/services/stirling-pdf/
  configs/             # settings + SQLite (if login is later turned on)
  logs/
  tessdata/            # extra OCR languages
  pipeline/            # automation configs
  customFiles/
services/stirling-pdf/.env      # ports + pin (gitignored, 600)
```

## Security model

- **Tailnet-only.** `127.0.0.1:8103`. Nothing on LAN or `0.0.0.0`.
- **Login off.** Upstream's default `admin`/`stirling` is a well-known
  pair. `setup.sh` checks that `/` does not bounce to `/login`.
- **No Google visibility, no survey, metrics off.**
- **Serve terminates TLS.** `SERVER_FORWARD_HEADERS_STRATEGY=native` so
  Stirling honours `X-Forwarded-Proto`.

## Dependencies

| Needs | Why | Checked by preflight |
|---|---|---|
| Linux or macOS | Docker restart policy handles boot | ✅ |
| Docker + Compose v2 | one container | ✅ |
| curl | health checks | ✅ |
| Tailscale, logged in, MagicDNS | publishing, **and** `SYSTEM_FRONTENDURL` | ✅ |

## Deploy

```bash
cd services/stirling-pdf && ./setup.sh     # idempotent; rerun to upgrade/repair
```

Step by step:

1. **Preflight** — OS, non-root, curl, Docker, Compose v2, Tailscale
   `Running`, numeric ports.
2. **Resolve the tailnet name** before writing `.env` —
   `SYSTEM_FRONTENDURL` is baked in at creation time.
3. **`.env`** — written only if absent, mode 600.
4. **`SYSTEM_FRONTENDURL` drift check** — warns, does not rewrite `.env`.
5. **Data dirs** under `~/services/stirling-pdf`.
6. **`docker compose up -d`**, wait for `/api/v1/info/status` (up to
   ~4.5 min; first boot is a Java start).
7. **`tailscale serve`**.
8. **Verify** HTTPS `/api/v1/info/status`, then a `/login` check so an
   accidental default-password login page cannot look like a successful
   deploy.

## Client side

Any browser on the tailnet:
`https://kai-home-server.taild6a23f.ts.net:8103`. No account. Files stay
on this box for the conversion and are not kept afterwards unless you
download them.

## Ops

```bash
docker compose --project-directory ~/dev/setup-server/services/stirling-pdf ps
docker compose --project-directory ~/dev/setup-server/services/stirling-pdf logs -f
docker compose --project-directory ~/dev/setup-server/services/stirling-pdf restart
```

Upgrade: bump `STIRLING_PDF_VERSION` in `.env`, then `./setup.sh`.

To turn login on later: set `SECURITY_ENABLELOGIN=true` and
`SECURITY_INITIALLOGIN_USERNAME` / `SECURITY_INITIALLOGIN_PASSWORD` in
`.env` (not the upstream `stirling` default), then `./setup.sh`.
