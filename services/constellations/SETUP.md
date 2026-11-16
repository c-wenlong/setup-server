# Constellations

The private design-research app, published on the tailnet so the launcher
can open, start and stop it.

## What this script does

The app is already installed by the constellations repo
(`scripts/studio-deploy.sh`, `design-research.service` on
`127.0.0.1:8845`). `setup.sh` does not clone, build or migrate. It writes
`.env`, grants the Tailscale operator if needed, and publishes
`https://<host>:8108` to that listener.

```
browser on the tailnet
        |
        v
https://<host>.ts.net:8108
        |
        v
tailscale serve
        |
        v
127.0.0.1:8845   design-research.service
```

## Security

The listener stays on loopback. Serve is tailnet-only. The app itself
rejects any Host that is not loopback or the origin in
`DESIGN_RESEARCH_PRIVATE_ORIGIN`, so the published port has to stay 8108
unless that origin is changed in `~/services/design-research/runtime.env`.

## What a re-run does

An existing `.env` is left alone. Serve is republished. The app is not
restarted.

## Ops

```sh
systemctl --user status design-research.service
systemctl --user restart design-research.service
cd services/constellations && ./teardown.sh
```

`teardown.sh` unpublishes the Serve port and stops the unit. It does not
delete `~/services/design-research`. `--purge` deletes only this
service's `.env`.
