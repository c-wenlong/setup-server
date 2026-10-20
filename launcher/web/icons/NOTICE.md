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

No upstream mark exists for `kaichenpedia`, `manimkc`, `self-learn` or
`sources`. `kaichenpedia.png`, `manimkc.png` and `self-learn.png` in this
directory are bespoke raster icons (not from the vendored collection above,
so the licence table does not cover them):
`kaichenpedia.png` is cropped from the kaichenpedia repo's own artwork,
`manimkc.png` is that service's own logo, `self-learn.png` is the Gnosia
mark (`apps/web/public/brand/mark.png`) from the self-learn repo, and
`sources.svg` is the sources repo's own `site/favicon.svg` copied unchanged —
each service's own artwork, the repo owner's in each case. `favicon.png`, `apple-touch-icon.png`
and `launcher.png` are raster forms of the launcher's own icon, also original
to this repo. The launcher tile itself has no registry entry and so falls
back to the hand-drawn glyphs in `../icons.js`.

`homepage.png` is also outside the collection above: dashboard-icons has no
mark for gethomepage.dev (its `homarr` is a different dashboard). It is the
project's own `public/android-chrome-512x512.png` from
[gethomepage/homepage](https://github.com/gethomepage/homepage), fetched
unmodified at commit `541b2fe9f13de9b4efbbc4d1e5fbc4c8d637734b` (2026-09-12).
That repository is GPL-3.0; the logo remains the Homepage project's brand mark
and is used here only to identify the service.

dashboard-icons also has no marks for Paperclip, OpenHands or Trigger.dev.
Those three are vendored from the sources below (same light minification as
the dashboard-icons set; geometry and colour unchanged).

| File here | Upstream | Service |
|---|---|---|
| `paperclip.svg` | [selfhst/icons](https://github.com/selfhst/icons) `svg/paperclip-ai.svg` (`#18181b`) | Paperclip |
| `paperclip-dark.svg` | same repo, `svg/paperclip-ai-light.svg` (`#fff`) | Paperclip, dark theme |
| `openhands.svg` | same repo, `svg/openhands.svg` (`#ffe165`) | OpenHands |
| `trigger-dev.svg` | [Trigger.dev brand kit](https://trigger.dev/brand) `triggerdev-logo--light.svg` (lime gradient) | Trigger.dev |
| `coolify.svg` | [selfhst/icons](https://github.com/selfhst/icons) `svg/coolify.svg` (`#8c52ff`) | Coolify |
| `appflowy.svg` | [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons) `svg/appflowy.svg` (`#9327ff`) | AppFlowy |
| `stirling-pdf.svg` | same repo, `svg/stirling-pdf.svg` (`#8e3131`) | Stirling PDF |
| `metabase.svg` | same repo, `svg/metabase.svg` (`#509ee3`) | Metabase |
| `plane.svg` | same repo, `svg/plane.svg` (`#5275fc`) | Plane |
| `umami.svg` | same repo, `svg/umami.svg` (black stroke) | Umami |
| `umami-dark.svg` | derived: stroke lifted `#000` → `#fff` so it reads on `#171719` | Umami, dark theme |

selfh.st/icons fetched at commit `14d558ec3d62848ec428113bcc46bd636f3cb47c`
(2026-09-15). The collection is CC-BY-4.0; each logo remains its project's
brand mark. Official `triggerdev-logo--dark.svg` is `#121317` and would vanish
on the dark tile (`#171719`), so only the lime mark is kept and used on both
themes.

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
