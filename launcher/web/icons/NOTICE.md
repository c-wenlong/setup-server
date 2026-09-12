# Third-party icons

These are **third-party brand marks**, vendored here and used as app icons for
the services the launcher links to. They identify each service; they do not
imply any endorsement of, or affiliation with, this project by its owners.

They are committed into the repo on purpose: the launcher must render with the
internet down, so `icons.js` references only local, relative paths and never a
CDN.

## Source

| | |
|---|---|
| Repository | [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons) |
| Path | `svg/<name>.svg` |
| Licence | Apache License 2.0 (the collection; see below on the marks themselves) |
| Fetched at commit | `c1f7e6b91c9e23317ac72b81f0ee3f9a4ac14aec` (2026-09-07) |
| Fetched on | 2026-09-10 |

The Apache-2.0 licence covers the *collection*. Each logo remains the property
of its respective project or trademark holder and is governed by that project's
own trademark and brand-usage terms.

## What was vendored

Files are named by the launcher's **service key** (`services.json`), which is
not always the upstream filename. Only the mapping below is fetched; nothing
else from that repo is included.

| File here | Upstream `svg/…` | Service |
|---|---|---|
| `immich.svg` | `immich.svg` | Immich |
| `seafile.svg` | `seafile.svg` | Seafile |
| `syncthing.svg` | `syncthing.svg` | Syncthing (fetched 2026-09-12, same commit) |
| `code-server.svg` | `vscode.svg` | code-server (no `code-server.svg` upstream; VS Code's mark is the recognisable one) |
| `open-webui.svg` | `open-webui.svg` | Open WebUI |
| `open-webui-dark.svg` | `open-webui-light.svg` | Open WebUI, dark theme |
| `n8n.svg` | `n8n.svg` | n8n |
| `beszel.svg` | `beszel.svg` | Beszel |
| `uptime-kuma.svg` | `uptime-kuma.svg` | Uptime Kuma |
| `ntfy.svg` | `ntfy.svg` | ntfy |
| `ollama.svg` | `ollama.svg` | ollama |
| `ollama-dark.svg` | `ollama-dark.svg` | ollama, dark theme |
| `adguard.svg` | `adguard-home.svg` | AdGuard Home |
| `jellyfin.svg` | `jellyfin.svg` | Jellyfin |
| `paperless-ngx.svg` | `paperless-ngx.svg` | Paperless-ngx |
| `paperless-ngx-dark.svg` | *derived* — see below | Paperless-ngx, dark theme |
| `karakeep.svg` | `karakeep-dark.svg` | Karakeep |
| `karakeep-dark.svg` | `karakeep.svg` | Karakeep, dark theme |
| `forgejo.svg` | `forgejo.svg` | Forgejo |
| `vaultwarden.svg` | `vaultwarden.svg` | Vaultwarden |
| `home-assistant.svg` | `home-assistant.svg` | Home Assistant |
| `firefly-iii.svg` | `firefly-iii.svg` | Firefly III |
| `guacamole.svg` | `guacamole.svg` | remote-desktop (Apache Guacamole is the engine; the service key is `remote-desktop`) |

`karakeep` is swapped on purpose: upstream's `karakeep.svg` is the **white**
mark and `karakeep-dark.svg` is the **black** one, so under this repo's
convention (`<key>.svg` = light theme, `<key>-dark.svg` = dark theme) they
trade places. Upstream's `-dark`/`-light` suffixes are not consistent about
whether they name the ink or the background; each file was checked by eye.

No upstream mark exists for `kaichenpedia` or `manimkc`. `kaichenpedia.png` and
`manimkc.png` in this directory are bespoke raster icons (not from the
vendored collection above, so the licence table does not cover them):
`kaichenpedia.png` is cropped from the kaichenpedia repo's own artwork, and
`manimkc.png` is that service's own logo. `favicon.png`, `apple-touch-icon.png`
and `launcher.png` are raster forms of the launcher's own icon, also original
to this repo. The launcher tile itself has no registry entry and so falls
back to the hand-drawn glyphs in `../icons.js`.

## Modifications

1. **Light minification.** XML declarations, comments, `<metadata>`,
   `xml:space`, `version`, `enable-background`, editor-generated `id="Layer_N"`
   and inter-tag whitespace removed. Geometry, gradients, masks, `viewBox` and
   every colour are untouched.
2. **`paperless-ngx-dark.svg` is a derived work**, not an upstream file. The
   mark is a single very dark green (`#17541f`) with roughly 2:1 contrast
   against the dark tile (`#171719`) — effectively invisible. The dark-theme
   copy keeps the same hue and saturation and lifts only the lightness, to
   `#5fd471`. That is the only pixel-level change made to any mark.
