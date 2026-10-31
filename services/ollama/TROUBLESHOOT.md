# ollama troubleshooting

Work top to bottom: service → local health → callers. The launcher tile's
status dot is the same information, one click removed.

## Service won't start / launcher shows stopped

```bash
systemctl --user status ollama
journalctl --user -u ollama -n 100 --no-pager
```

- **`Address already in use`** — something else holds :11434, most likely a
  stock system unit that got re-enabled. Check `systemctl status
  ollama.service` (no `--user`); if it is alive, retire it again:
  `sudo systemctl disable --now ollama.service`. setup.sh does this for
  you on a re-run.
- **Unit file gone or binary missing** — `ExecStart=` points at the binary
  setup.sh resolved; if it was `/usr/local/bin/ollama` and a package update
  removed it, re-run `./setup.sh` (it will download into `~/.local`).
- **Runs as the wrong user** — if `systemctl --user` says the unit is fine
  but the port answers as a different store, you are looking at two
  daemons: check `ss -tlnp | grep 11434` and who owns the process.

## Health check fails while the unit is active

```bash
curl -v http://127.0.0.1:11434/api/version
```

- Connection refused → the unit is crash-looping; read the journal above.
- Answering but not on 127.0.0.1 → `OLLAMA_HOST` in the unit was edited;
  `grep OLLAMA_HOST ~/.config/systemd/user/ollama.service` — setup.sh only
  writes loopback.
- Answering on `*:11434` → a stray `OLLAMA_HOST=0.0.0.0` override, or the
  *system* unit is running again (see above). The user unit never binds
  wide.

## Another service can't reach ollama

- Use `http://127.0.0.1:11434`, not the tailnet name — it is not published.
- A *containerised* caller (Docker with bridge networking) cannot use
  127.0.0.1 to reach the host — that caller needs `host.docker.internal`
  or host networking, exactly how open-webui's compose does it. The bind
  itself stays loopback either way.
- `ollama list` empty → models were never pulled *as this user*. The old
  system unit's models live in `/usr/share/ollama/.ollama` owned by the
  `ollama` user — they are not shared.

## Disk pressure

Models are the weight: `du -sh ~/.ollama`. Remove what you don't serve:
`ollama rm <model>`. `--purge` takes the whole store and the unit file;
the binary and any retired system unit stay.

## Nuke and pave

```bash
./teardown.sh --purge        # type "ollama" — models + unit file go
rm -f ~/.local/bin/ollama    # if we installed it (stock: sudo rm /usr/local/bin/ollama)
```

Then `./setup.sh` for a clean slate. To erase the retired stock unit too:
`sudo rm /etc/systemd/system/ollama.service /etc/systemd/system/ollama.service.d -r
&& sudo systemctl daemon-reload`.
