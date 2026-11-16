# Constellations

## The tile is down

1. `systemctl --user status design-research.service`
2. `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8845/`
3. `tailscale serve status | grep 8108`

A 200 on loopback and a missing Serve line means re-run `./setup.sh`.
A connection refusal means the unit is stopped. Start it from the
launcher, or `systemctl --user start design-research.service`.

## The page says the host is not allowed

The app only accepts loopback and the origin in
`DESIGN_RESEARCH_PRIVATE_ORIGIN`. A Serve port other than 8108 is refused
until that origin is updated and the unit restarted.

## Nuke and pave

```sh
cd services/constellations && ./teardown.sh
```

That unpublishes and stops. The database and releases under
`~/services/design-research` stay. `--purge` deletes only `.env`.
