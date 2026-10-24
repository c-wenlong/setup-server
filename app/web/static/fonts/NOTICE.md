# Vendored fonts

## Inter — `inter-latin.woff2`

Variable weight 400–700, **latin subset only** (~`U+0000-00FF` plus common
punctuation), fetched from Google Fonts (`fonts.gstatic.com`, Inter v20).

Vendored rather than linked because the launcher must render with no
internet: it is the page you open when something else on the box is broken,
and a webfont fetched from a CDN would simply not load on an offline tailnet.

**Licence:** SIL Open Font License 1.1 — free to use, embed and
redistribute, including in this repo. Copyright (c) 2016 The Inter Project
Authors (https://github.com/rsms/inter).

## Why Inter, and not Cursor's own typeface

The design brief was "use Cursor's fonts". Cursor's identity is built on
**CursorGothic**, a custom face commissioned from the foundry Kimera, with
`jjannon` (serif) and `berkeleyMono` (mono) alongside. All three are
proprietary and are not licensed for redistribution, so they cannot be
vendored here.

Inter is the closest freely-licensed match to what makes CursorGothic read
the way it does: a neutral gothic grotesque with a tall x-height, designed
for screens. The Cursor *characteristics* we do copy are the ones that are
technique rather than typeface — notably tight negative letter-spacing at
display sizes. Cursor's own CSS falls back to
`system-ui, "Helvetica Neue", Helvetica, Arial, sans-serif`, which is
exactly the stack listed after Inter here.
