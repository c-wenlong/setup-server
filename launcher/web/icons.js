/* icons.js — icon resolution for the launcher.
 *
 * Two sources, in order:
 *
 *   1. Vendored brand marks in web/icons/ — real app logos, in their own
 *      colours, keyed by service `key` (immich -> icons/immich.svg). Returned
 *      as an <img>. Files are local; nothing here touches the network, so the
 *      page still renders with the internet down.
 *   2. Hand-authored monochrome glyphs, keyed by the semantic `icon` name from
 *      services.json (camera, folder, code, ...). Drawn on a 24x24 grid,
 *      stroke-only, 1.5 weight, round caps/joins, inheriting currentColor.
 *      Unknown names fall back to a neutral rounded-square glyph.
 *
 * Public API:
 *   window.iconFor(key, name) -> HTMLElement   (brand img, else glyph svg)
 *   window.ICONS.svg(name)    -> SVGElement    (glyph only; unchanged)
 *
 * EVERY path emitted here is RELATIVE ("icons/immich.svg"). The launcher is
 * served both at https://HOST:8093/ and at https://HOST/home/, where Tailscale
 * strips the /home prefix — an absolute "/icons/..." silently 404s on the
 * mount the user actually bookmarks. Do not "tidy" these into absolute paths.
 *
 * Dark mode: several brand marks are near-black or near-white and vanish
 * against one of the two tile backgrounds (#ffffff / #171719). Those ship a
 * `-dark.svg` companion; the choice is made from prefers-color-scheme and
 * re-made, in place, when the scheme changes.
 */
(function (global) {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var DIR = 'icons/';   /* relative on purpose — see header */

  /* ---------------------------------------------------------------- brands */

  /* service key -> vendored file basename. `dark: true` means a companion
     "<base>-dark.<ext>" exists and is used under prefers-color-scheme: dark.
     `ext` defaults to 'svg'.
     Provenance and licence: web/icons/NOTICE.md */
  var BRANDS = {
    'immich':        { file: 'immich' },
    /* Bespoke mark, not from the icon set: circular-cropped from the original
       artwork in the kaichenpedia repo, so it needs no plate on either theme.
       Raster because no vector original exists. */
    'kaichenpedia':  { file: 'kaichenpedia', ext: 'png' },
    'manimkc':       { file: 'manimkc',      ext: 'png' },
    'seafile':       { file: 'seafile' },
    'code-server':   { file: 'code-server' },
    'open-webui':    { file: 'open-webui',    dark: true },  /* black disc  */
    'n8n':           { file: 'n8n' },
    'beszel':        { file: 'beszel' },
    'uptime-kuma':   { file: 'uptime-kuma' },
    'ntfy':          { file: 'ntfy' },
    'ollama':        { file: 'ollama',        dark: true },  /* black ink   */
    'adguard':       { file: 'adguard' },
    'jellyfin':      { file: 'jellyfin' },
    'paperless-ngx': { file: 'paperless-ngx', dark: true },  /* #17541f     */
    'karakeep':      { file: 'karakeep',      dark: true },  /* black ink   */
    'forgejo':       { file: 'forgejo' }
  };

  /* Spellings the registry might plausibly use for the same service. */
  var BRAND_ALIAS = {
    'adguard-home': 'adguard',
    'adguardhome': 'adguard',
    'openwebui': 'open-webui',
    'open-web-ui': 'open-webui',
    'codeserver': 'code-server',
    'vscode': 'code-server',
    'kuma': 'uptime-kuma',
    'uptimekuma': 'uptime-kuma',
    'paperless': 'paperless-ngx',
    'paperlessngx': 'paperless-ngx'
  };

  /* --------------------------------------------------------------- glyphs */

  /* Each entry is a list of [tag, attrs]. Solid dots opt out of the stroke
     by setting fill/stroke explicitly. */
  var GLYPHS = {
    camera: [
      ['path', { d: 'M3.5 8.8A1.8 1.8 0 0 1 5.3 7h1.9a1 1 0 0 0 .83-.45l1.1-1.65A1 1 0 0 1 9.96 4.5h4.08a1 1 0 0 1 .83.45l1.1 1.65A1 1 0 0 0 16.8 7h1.9a1.8 1.8 0 0 1 1.8 1.8v7.9a1.8 1.8 0 0 1-1.8 1.8H5.3a1.8 1.8 0 0 1-1.8-1.8Z' }],
      ['circle', { cx: 12, cy: 12.6, r: 3.4 }]
    ],
    folder: [
      ['path', { d: 'M3.5 7.3A1.8 1.8 0 0 1 5.3 5.5h3.9a1 1 0 0 1 .8.4l1.2 1.6a1 1 0 0 0 .8.4h6.7a1.8 1.8 0 0 1 1.8 1.8v7.6a1.8 1.8 0 0 1-1.8 1.8H5.3a1.8 1.8 0 0 1-1.8-1.8Z' }]
    ],
    code: [
      ['path', { d: 'm8.5 8-4.2 4 4.2 4' }],
      ['path', { d: 'm15.5 8 4.2 4-4.2 4' }],
      ['path', { d: 'M13.4 5.2 10.6 18.8' }]
    ],
    terminal: [
      ['rect', { x: 3.5, y: 4.5, width: 17, height: 15, rx: 2.6 }],
      ['path', { d: 'm7.6 10 2.6 2.4-2.6 2.4' }],
      ['path', { d: 'M12.6 14.8h4' }]
    ],
    chat: [
      ['path', { d: 'M20.5 11.9c0 4.1-3.8 7.4-8.5 7.4-1 0-1.9-.15-2.8-.42L4.2 20.4l1.3-3.9c-1.3-1.25-2-2.85-2-4.6 0-4.1 3.8-7.4 8.5-7.4s8.5 3.3 8.5 7.4Z' }]
    ],
    book: [
      ['path', { d: 'M12 7.4C10.5 6.15 8.7 5.5 6.6 5.5c-.85 0-1.7.1-2.5.32a.6.6 0 0 0-.45.58v10.5c0 .4.37.68.76.6a9.4 9.4 0 0 1 2.19-.25c2.1 0 3.9.65 5.4 1.9' }],
      ['path', { d: 'M12 7.4c1.5-1.25 3.3-1.9 5.4-1.9.85 0 1.7.1 2.5.32a.6.6 0 0 1 .45.58v10.5c0 .4-.37.68-.76.6a9.4 9.4 0 0 0-2.19-.25c-2.1 0-3.9.65-5.4 1.9' }],
      ['path', { d: 'M12 7.4v11.75' }]
    ],
    workflow: [
      ['circle', { cx: 5.8, cy: 6.8, r: 2.5 }],
      ['circle', { cx: 5.8, cy: 17.2, r: 2.5 }],
      ['circle', { cx: 18.2, cy: 12, r: 2.5 }],
      ['path', { d: 'M8.3 6.8h2.9a1.8 1.8 0 0 1 1.8 1.8v6.8a1.8 1.8 0 0 1-1.8 1.8H8.3' }],
      ['path', { d: 'M13 12h2.7' }]
    ],
    activity: [
      ['path', { d: 'M3.2 12.4h3.6l2.4-6.6 4.1 12.4 2.3-5.8h5.2' }]
    ],
    heartbeat: [
      ['circle', { cx: 12, cy: 12, r: 8.4 }],
      ['path', { d: 'm8.4 12.3 2.5 2.5 4.7-5.1' }]
    ],
    bell: [
      ['path', { d: 'M18 10.2a6 6 0 1 0-12 0c0 4.6-1.9 6-1.9 6h15.8s-1.9-1.4-1.9-6Z' }],
      ['path', { d: 'M10.3 19.1a2 2 0 0 0 3.4 0' }]
    ],
    video: [
      ['rect', { x: 3.3, y: 6.2, width: 12.6, height: 11.6, rx: 2.4 }],
      ['path', { d: 'm15.9 13.1 3.9 2.5a.7.7 0 0 0 1.08-.59V9a.7.7 0 0 0-1.08-.59l-3.9 2.5Z' }]
    ],
    film: [
      ['rect', { x: 3.4, y: 5.2, width: 17.2, height: 13.6, rx: 2.6 }],
      ['path', { d: 'M8.3 5.2v13.6M15.7 5.2v13.6' }],
      ['path', { d: 'M3.4 12h4.9M15.7 12h4.9' }]
    ],
    cpu: [
      ['rect', { x: 5.2, y: 5.2, width: 13.6, height: 13.6, rx: 2.6 }],
      ['rect', { x: 9.3, y: 9.3, width: 5.4, height: 5.4, rx: 1.2 }],
      ['path', { d: 'M9.4 2.6v2.6M14.6 2.6v2.6M9.4 18.8v2.6M14.6 18.8v2.6M2.6 9.4h2.6M2.6 14.6h2.6M18.8 9.4h2.6M18.8 14.6h2.6' }]
    ],
    shield: [
      ['path', { d: 'M12 3.4 5.2 6v5.4c0 4.2 2.85 7.5 6.8 8.9 3.95-1.4 6.8-4.7 6.8-8.9V6Z' }]
    ],
    lock: [
      ['rect', { x: 4.6, y: 10.2, width: 14.8, height: 10.2, rx: 2.6 }],
      ['path', { d: 'M8.1 10.2V7.8a3.9 3.9 0 0 1 7.8 0v2.4' }]
    ],
    document: [
      ['path', { d: 'M13.7 3H6.7A1.7 1.7 0 0 0 5 4.7v14.6A1.7 1.7 0 0 0 6.7 21h10.6a1.7 1.7 0 0 0 1.7-1.7V8.2Z' }],
      ['path', { d: 'M13.5 3.2v4.1a1 1 0 0 0 1 1h4.2' }],
      ['path', { d: 'M8.4 13.2h7.2M8.4 16.6h4.6' }]
    ],
    bookmark: [
      ['path', { d: 'M6.6 5.2A2 2 0 0 1 8.6 3.2h6.8a2 2 0 0 1 2 2v15.6l-5.4-3.9-5.4 3.9Z' }]
    ],
    git: [
      ['circle', { cx: 7, cy: 6, r: 2.5 }],
      ['circle', { cx: 7, cy: 18, r: 2.5 }],
      ['circle', { cx: 17, cy: 9.6, r: 2.5 }],
      ['path', { d: 'M7 8.5v7' }],
      ['path', { d: 'M17 12.1c0 2.6-2.1 3.9-4.6 4.3-1.1.2-2 .5-2.9 1' }]
    ],
    globe: [
      ['circle', { cx: 12, cy: 12, r: 8.4 }],
      ['path', { d: 'M3.6 12h16.8' }],
      ['path', { d: 'M12 3.6a13 13 0 0 1 0 16.8 13 13 0 0 1 0-16.8Z' }]
    ],
    server: [
      ['rect', { x: 3.5, y: 4.4, width: 17, height: 6.4, rx: 2.1 }],
      ['rect', { x: 3.5, y: 13.2, width: 17, height: 6.4, rx: 2.1 }],
      ['circle', { cx: 7.3, cy: 7.6, r: 0.85, fill: 'currentColor', stroke: 'none' }],
      ['circle', { cx: 7.3, cy: 16.4, r: 0.85, fill: 'currentColor', stroke: 'none' }]
    ],
    database: [
      ['ellipse', { cx: 12, cy: 6.4, rx: 7.4, ry: 2.9 }],
      ['path', { d: 'M4.6 6.4v11.2c0 1.6 3.3 2.9 7.4 2.9s7.4-1.3 7.4-2.9V6.4' }],
      ['path', { d: 'M4.6 12c0 1.6 3.3 2.9 7.4 2.9s7.4-1.3 7.4-2.9' }]
    ],
    home: [
      ['path', { d: 'M3.6 10.6 12 4.1l8.4 6.5' }],
      ['path', { d: 'M5.7 9.4v9A1.6 1.6 0 0 0 7.3 20h9.4a1.6 1.6 0 0 0 1.6-1.6v-9' }]
    ],
    search: [
      ['circle', { cx: 11, cy: 11, r: 6.4 }],
      ['path', { d: 'm15.7 15.7 4.3 4.3' }]
    ],
    key: [
      ['circle', { cx: 8, cy: 15.2, r: 3.9 }],
      ['path', { d: 'm10.9 12.4 7.9-7.9' }],
      ['path', { d: 'm16.4 6.9 2 2' }],
      ['path', { d: 'm13.9 9.4 2 2' }]
    ],
    cloud: [
      ['path', { d: 'M7.4 18.4h9.2a4.1 4.1 0 0 0 .55-8.16 5.6 5.6 0 0 0-10.6-.9 4.1 4.1 0 0 0 .85 9.06Z' }]
    ],
    download: [
      ['path', { d: 'M12 4.2v10.2' }],
      ['path', { d: 'm7.7 10.4 4.3 4.3 4.3-4.3' }],
      ['path', { d: 'M4.8 19.4h14.4' }]
    ],
    power: [
      ['path', { d: 'M12 3.4v8.2' }],
      ['path', { d: 'M17.3 6.7a7.5 7.5 0 1 1-10.6 0' }]
    ],
    box: [
      ['rect', { x: 4.4, y: 4.4, width: 15.2, height: 15.2, rx: 4.2 }],
      ['circle', { cx: 12, cy: 12, r: 2.2 }]
    ]
  };

  /* Semantic aliases, so the registry can use whatever word reads best. */
  var ALIAS = {
    photo: 'camera', photos: 'camera', image: 'camera', images: 'camera', gallery: 'camera',
    files: 'folder', file: 'document', drive: 'folder', storage: 'folder', archive: 'document',
    vscode: 'code', editor: 'code', ide: 'code', dev: 'code',
    console: 'terminal', shell: 'terminal', cli: 'terminal',
    ai: 'chat', llm: 'chat', message: 'chat', messages: 'chat', assistant: 'chat',
    wiki: 'book', notes: 'book', notebook: 'book', knowledge: 'book', docs: 'book',
    automation: 'workflow', flow: 'workflow', nodes: 'workflow', pipeline: 'workflow', workflows: 'workflow',
    metrics: 'activity', chart: 'activity', graph: 'activity', stats: 'activity', monitor: 'activity', pulse: 'activity',
    status: 'heartbeat', uptime: 'heartbeat', check: 'heartbeat', health: 'heartbeat', heart: 'heartbeat',
    alert: 'bell', alerts: 'bell', notification: 'bell', notifications: 'bell', push: 'bell', ntfy: 'bell',
    render: 'video', camcorder: 'video', animation: 'video',
    media: 'film', movie: 'film', movies: 'film', tv: 'film', play: 'film',
    brain: 'cpu', model: 'cpu', models: 'cpu', chip: 'cpu', hardware: 'cpu',
    dns: 'shield', adblock: 'shield', security: 'shield', firewall: 'shield',
    vault: 'lock', private: 'lock', secure: 'lock',
    paper: 'document', scan: 'document', documents: 'document', pdf: 'document', text: 'document',
    link: 'bookmark', links: 'bookmark', bookmarks: 'bookmark', 'read-later': 'bookmark', save: 'bookmark',
    repo: 'git', repos: 'git', branch: 'git', forge: 'git', vcs: 'git', source: 'git',
    web: 'globe', www: 'globe', network: 'globe', internet: 'globe', site: 'globe',
    host: 'server', machine: 'server', rack: 'server', node: 'server', infra: 'server',
    db: 'database', disk: 'database', data: 'database',
    house: 'home', launcher: 'home', dashboard: 'home',
    find: 'search', magnifier: 'search',
    auth: 'key', secret: 'key', credentials: 'key', password: 'key',
    backup: 'cloud', sync: 'cloud',
    install: 'download', deploy: 'download', arrow_down: 'download',
    restart: 'power', onoff: 'power', service: 'power',
    generic: 'box', unknown: 'box', app: 'box'
  };

  function normalise(name) {
    return String(name == null ? '' : name)
      .trim()
      .toLowerCase()
      .replace(/[\s_]+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  function resolve(name) {
    var key = normalise(name);
    if (GLYPHS[key]) return key;
    if (ALIAS[key]) return ALIAS[key];
    var flat = key.replace(/-/g, '');
    if (GLYPHS[flat]) return flat;
    if (ALIAS[flat]) return ALIAS[flat];
    return 'box';
  }

  function svg(name) {
    var node = document.createElementNS(NS, 'svg');
    node.setAttribute('viewBox', '0 0 24 24');
    node.setAttribute('fill', 'none');
    node.setAttribute('stroke', 'currentColor');
    node.setAttribute('stroke-width', '1.5');
    node.setAttribute('stroke-linecap', 'round');
    node.setAttribute('stroke-linejoin', 'round');
    node.setAttribute('aria-hidden', 'true');
    node.setAttribute('focusable', 'false');

    var parts = GLYPHS[resolve(name)];
    for (var i = 0; i < parts.length; i++) {
      var tag = parts[i][0];
      var attrs = parts[i][1];
      var child = document.createElementNS(NS, tag);
      for (var a in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, a)) {
          child.setAttribute(a, String(attrs[a]));
        }
      }
      node.appendChild(child);
    }
    return node;
  }

  /* ------------------------------------------------------- theme plumbing */

  var mq = null;
  if (global.matchMedia) {
    try { mq = global.matchMedia('(prefers-color-scheme: dark)'); } catch (e) { mq = null; }
  }

  function prefersDark() { return !!(mq && mq.matches); }

  /* Live <img>s that have a per-theme variant, so a scheme flip can be
     applied in place rather than needing a re-render. Detached nodes are
     pruned on each pass, so a grid re-render cannot grow this without bound. */
  var themed = [];

  function fileFor(entry) {
    /* `ext` defaults to svg — every vendored brand mark is vector except the
       bespoke kaichenpedia logo, which only exists as a raster original. */
    var ext = entry.ext || 'svg';
    return DIR + entry.file + (entry.dark && prefersDark() ? '-dark' : '') + '.' + ext;
  }

  function repaint() {
    var keep = [];
    for (var i = 0; i < themed.length; i++) {
      var rec = themed[i];
      if (!rec.el.isConnected) continue;      /* dropped by a re-render */
      var want = fileFor(rec.entry);
      if (rec.el.getAttribute('src') !== want) rec.el.setAttribute('src', want);
      keep.push(rec);
    }
    themed = keep;
  }

  if (mq) {
    if (mq.addEventListener) mq.addEventListener('change', repaint);
    else if (mq.addListener) mq.addListener(repaint);   /* Safari < 14 */
  }

  /* ------------------------------------------------------------- iconFor */

  function brandEntry(key) {
    var k = normalise(key);
    if (BRANDS[k]) return BRANDS[k];
    if (BRAND_ALIAS[k]) return BRANDS[BRAND_ALIAS[k]];
    var flat = k.replace(/-/g, '');
    if (BRAND_ALIAS[flat]) return BRANDS[BRAND_ALIAS[flat]];
    return null;
  }

  function brandImg(entry) {
    var img = document.createElement('img');
    img.setAttribute('src', fileFor(entry));
    img.setAttribute('alt', '');
    img.setAttribute('loading', 'lazy');
    img.setAttribute('decoding', 'async');
    img.setAttribute('width', '24');
    img.setAttribute('height', '24');
    img.setAttribute('aria-hidden', 'true');
    /* Brand marks keep their own colours, so they must not inherit the
       tile's stroke/fill treatment. Belt and braces, since app.css is
       owned by another module. */
    img.style.objectFit = 'contain';
    if (entry.dark) themed.push({ el: img, entry: entry });
    return img;
  }

  /* Resolution order: vendored brand mark for `key`, else the hand-drawn
     glyph for the semantic `name`, else the `box` glyph. */
  function iconFor(key, name) {
    var entry = brandEntry(key);
    if (entry) return brandImg(entry);
    return svg(name);
  }

  /* ---------------------------------------------------------------- export */

  global.iconFor = iconFor;

  global.ICONS = {
    svg: svg,                                   /* glyph only, unchanged */
    for: iconFor,
    resolve: resolve,
    names: function () { return Object.keys(GLYPHS); },
    aliases: function () { return Object.keys(ALIAS); },
    brands: function () { return Object.keys(BRANDS); },
    /* Relative path of the file iconFor() would use, or null. Test hook. */
    brandFile: function (key) {
      var entry = brandEntry(key);
      return entry ? fileFor(entry) : null;
    }
  };
}(window));
