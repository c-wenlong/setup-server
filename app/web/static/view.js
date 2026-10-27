/* view.js — theme control, the detail page's Resources block, usage beacons
 *
 * A self-contained module, like notes.js and tooltip.js. It owns:
 *
 *   - the theme-cycle button in the sidebar (#theme-btn), persisted in
 *     localStorage per device and painted onto <html data-theme>;
 *   - the "Resources" block on a detail page, rendered into `#view-res`;
 *   - the `POST api/services/<key>/touch` beacons (launched / opened).
 *
 * app.js and home.js call into it through `window.LauncherView` and nothing
 * else; this file never reaches into either. Every selector it creates is
 * prefixed `.vw-`, so it can only style nodes it made itself. The exceptions
 * are deliberate reuse of app.css's `.d-sec`/`.d-sec-h` shells, so the
 * Resources block reads as part of the page.
 *
 * EVERY URL here is RELATIVE ("api/services/<key>/touch"). The page is served
 * at both https://HOST:8093/ and https://HOST/home/, where Tailscale strips
 * the /home prefix; an absolute "/api/..." silently 404s on the mount that is
 * actually bookmarked.
 *
 * NULL-SAFETY IS THE POINT. `usage`, `deployed_at` and `resources` are v3
 * keys. A launcher that predates them sends none of them, and every accessor
 * below has to answer `null` rather than throw.
 */
(function () {
  'use strict';

  /* ---------- config ---------- */

  var THEME_STORE = 'launcher.theme';

  var THEMES = [
    { id: 'system', label: 'System' },
    { id: 'light',  label: 'Light'  },
    { id: 'dark',   label: 'Dark'   }
  ];

  var DASH = '—';     /* em dash: the one and only "we do not know" */
  var KB = 1024;

  /* ---------- state ---------- */

  var themeMode = 'system';

  var resSec = null;       /* the detail page's Resources section */
  var resRefs = null;
  var resKey = null;       /* which service it is showing */
  var resData = null;      /* best-known {usage, deployed_at, resources} */

  var mountRes   = document.getElementById('view-res');

  /* ---------- dom helpers ---------- */

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }

  function text(node, value) {
    node.textContent = value == null ? '' : String(value);
    return node;
  }

  function noop() {}

  /* ---------- storage ---------- */

  function stored(store, table, fallback) {
    var raw = null;
    try { raw = window.localStorage.getItem(store); } catch (e) { raw = null; }
    for (var i = 0; i < table.length; i++) if (table[i].id === raw) return raw;
    return fallback;
  }

  function remember(store, value) {
    try { window.localStorage.setItem(store, value); } catch (e) { /* private mode */ }
  }

  /* Theme is a page-wide paint. The inline script in index.html already set
     data-theme for the first frame; this keeps the attribute, the
     theme-color meta and the brand icons in step after that. */
  function resolvedDark() {
    if (themeMode === 'dark') return true;
    if (themeMode === 'light') return false;
    try {
      return !!(window.matchMedia &&
                window.matchMedia('(prefers-color-scheme: dark)').matches);
    } catch (e) { return false; }
  }

  function themeLabel(id) {
    for (var i = 0; i < THEMES.length; i++) {
      if (THEMES[i].id === id) return THEMES[i].label;
    }
    return 'System';
  }

  function nextTheme(id) {
    if (id === 'system') return 'light';
    if (id === 'light') return 'dark';
    return 'system';
  }

  /* Stroke icons, same 24 grid as the rest of the page. System is a
     half-filled circle (follows the OS); Light a sun; Dark a moon. */
  var THEME_ICON = {
    system: ['<circle cx="12" cy="12" r="8"/>',
             '<path d="M12 4v16a8 8 0 0 0 0-16z" fill="currentColor" stroke="none"/>'],
    light:  ['<circle cx="12" cy="12" r="4"/>',
             '<path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/>'],
    dark:   ['<path d="M16.6 14.3A7 7 0 0 1 9.7 7.4 6.2 6.2 0 1 0 16.6 14.3z"/>']
  };

  function paintThemeButton() {
    var btn = document.getElementById('theme-btn');
    if (!btn) return;
    var next = nextTheme(themeMode);
    var label = themeLabel(themeMode);
    btn.setAttribute('aria-label', 'Theme: ' + label + '. Click for ' + themeLabel(next));
    btn.title = label;
    btn.setAttribute('data-theme-mode', themeMode);
    var parts = THEME_ICON[themeMode] || THEME_ICON.system;
    var svg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
              parts.join('') + '</svg>';
    if (btn.innerHTML !== svg) btn.innerHTML = svg;
  }

  function paintTheme() {
    /* The attribute carries the resolved scheme, never 'system', so CSS
       needs no media query: [data-theme="light"] is the whole override.
       System mode keeps following the OS because the mq listener below
       re-runs this on a scheme flip. */
    var dark = resolvedDark();
    try {
      document.documentElement.setAttribute('data-theme',
        dark ? 'dark' : 'light');
    } catch (e) { /* nothing to paint onto */ }
    var meta = document.getElementById('theme-color');
    if (meta) meta.setAttribute('content', dark ? '#000000' : '#f5f5f6');
    paintThemeButton();
    if (window.ICONS && typeof window.ICONS.repaint === 'function') {
      try { window.ICONS.repaint(); } catch (e) { /* icons stay as they are */ }
    }
  }

  /* ---------- payload accessors ----------
   *
   * Every one of these answers `null` on a backend that predates v3, on a
   * malformed value, and on a service the server could not measure. Nothing
   * below this line may assume a key exists.
   */

  function num(v) {
    return (typeof v === 'number' && isFinite(v)) ? v : null;
  }

  function resources(svc) {
    var r = svc && svc.resources;
    return (r && typeof r === 'object' && !Array.isArray(r)) ? r : null;
  }

  function rssOf(svc)  { var r = resources(svc); return r ? num(r.rss_bytes) : null; }
  function cpuOf(svc)  { var r = resources(svc); return r ? num(r.cpu_pct)   : null; }

  function partsOf(svc) {
    var r = resources(svc);
    return (r && Array.isArray(r.parts)) ? r.parts : [];
  }

  function usageOf(svc, field) {
    var u = svc && svc.usage;
    if (!u || typeof u !== 'object' || Array.isArray(u)) return null;
    return num(u[field]);
  }

  function deployedOf(svc) { return svc ? num(svc.deployed_at) : null; }

  /* ---------- formatting ---------- */

  function round1(x) {
    return (Math.round(x * 10) / 10).toFixed(1);
  }

  /* 1024-based, because this is cgroup `memory.current` and every other tool
     that reads it (docker stats, systemd-cgtop, beszel) counts the same way.
     Coarse on purpose: a figure that re-words on every 30s poll would rebuild
     a tile under the pointer. */
  function fmtBytes(v) {
    var n = num(v);
    if (n === null || n < 0) return DASH;
    if (n < KB) return Math.round(n) + ' B';
    var units = ['KB', 'MB', 'GB', 'TB'];
    var i = -1, x = n;
    while (x >= KB && i < units.length - 1) { x /= KB; i++; }
    return (x < 10 ? round1(x) : String(Math.round(x))) + ' ' + units[i];
  }

  /* A negative percentage is a server bug, not a reading. Say "unknown"
     rather than inventing a plausible 0.0 %. */
  function fmtPct(v) {
    var n = num(v);
    if (n === null || n < 0) return DASH;
    return round1(n) + ' %';
  }

  /* Compact on purpose — this has to fit a table column at 400px. notes.js
     spells its ages out ("3 hours ago"); the v3 spec asks for "3 h ago" here,
     and a column is not a sentence. */
  function fmtRel(v) {
    var n = num(v);
    if (n === null) return DASH;
    var s = Math.round(Date.now() / 1000 - n);
    if (s < 0) s = 0;                       /* clock skew, or a touch just now */
    if (s < 60) return 'just now';
    var m = Math.floor(s / 60);
    if (m < 60) return m + ' min ago';
    var h = Math.floor(m / 60);
    if (h < 24) return h + ' h ago';
    var d = Math.floor(h / 24);
    if (d < 30) return d + ' d ago';
    var mo = Math.floor(d / 30.44);
    if (mo < 12) return mo + ' mo ago';
    return Math.floor(d / 365.25) + ' y ago';
  }

  function dateOf(v) {
    var n = num(v);
    if (n === null) return null;
    var d = new Date(n * 1000);
    return isNaN(d.getTime()) ? null : d;
  }

  function fmtDate(v) {
    var d = dateOf(v);
    if (!d) return DASH;
    var opts = { day: 'numeric', month: 'short' };
    if (d.getFullYear() !== new Date().getFullYear()) opts.year = 'numeric';
    try { return d.toLocaleDateString(undefined, opts); } catch (e) { return d.toDateString(); }
  }

  /* The absolute form rides in `title`: "3 h ago" is useless the moment you
     are trying to line it up with a log line. */
  function fmtAbs(v) {
    var d = dateOf(v);
    if (!d) return '';
    try { return d.toLocaleString(undefined, { dateStyle: 'full', timeStyle: 'short' }); }
    catch (e) { return d.toLocaleString(); }
  }

  function bindThemeButton() {
    var btn = document.getElementById('theme-btn');
    if (!btn) return;
    btn.addEventListener('click', function () {
      themeMode = nextTheme(themeMode);
      remember(THEME_STORE, themeMode);
      paintTheme();
    });
  }

  /* ---------- detail: Resources ---------- */

  var SUMMARY = [
    { id: 'ram',      label: 'RAM' },
    { id: 'cpu',      label: 'CPU' },
    { id: 'deployed', label: 'Deployed' },
    { id: 'launched', label: 'Last launched' },
    { id: 'opened',   label: 'Last opened' }
  ];

  var PART_COLS = [
    { label: 'Part',  cls: 'vw-c-part' },
    { label: 'Kind',  cls: 'vw-c-kind' },
    { label: 'State', cls: 'vw-c-state' },
    { label: 'RAM',   cls: 'vw-c-num' },
    { label: 'CPU',   cls: 'vw-c-num' }
  ];

  function buildRes() {
    if (resSec || !mountRes) return;

    resSec = make('section', 'd-sec vw-res');
    resSec.appendChild(text(make('h3', 'd-sec-h'), 'Resources'));

    resRefs = { sum: {} };

    var dl = make('dl', 'vw-sum');
    for (var i = 0; i < SUMMARY.length; i++) {
      var pair = make('div', 'vw-pair');
      pair.appendChild(text(make('dt'), SUMMARY[i].label));
      var dd = text(make('dd'), DASH);
      pair.appendChild(dd);
      dl.appendChild(pair);
      resRefs.sum[SUMMARY[i].id] = dd;
    }
    resSec.appendChild(dl);

    var wrap = make('div', 'vw-wrap vw-partwrap');
    wrap.setAttribute('role', 'region');
    wrap.setAttribute('aria-label', 'Parts');
    wrap.tabIndex = 0;

    var tbl = make('table', 'vw-table vw-parts');
    var head = make('thead');
    var hrow = make('tr');
    for (var c = 0; c < PART_COLS.length; c++) {
      var th = make('th', PART_COLS[c].cls);
      th.scope = 'col';
      text(th, PART_COLS[c].label);
      hrow.appendChild(th);
    }
    head.appendChild(hrow);
    tbl.appendChild(head);
    resRefs.parts = make('tbody');
    tbl.appendChild(resRefs.parts);
    wrap.appendChild(tbl);
    resRefs.wrap = wrap;
    resSec.appendChild(wrap);

    resRefs.none = text(make('p', 'd-empty'), 'No parts are registered for this service.');
    resSec.appendChild(resRefs.none);

    mountRes.appendChild(resSec);
  }

  function paintRes() {
    if (!resSec) return;
    var svc = resData || {};
    var s = resRefs.sum;

    text(s.ram, fmtBytes(rssOf(svc)));
    text(s.cpu, fmtPct(cpuOf(svc)));

    var dep = deployedOf(svc);
    text(s.deployed, fmtDate(dep));
    if (dep === null) s.deployed.removeAttribute('title'); else s.deployed.title = fmtAbs(dep);

    var la = usageOf(svc, 'last_launched');
    text(s.launched, fmtRel(la));
    if (la === null) s.launched.removeAttribute('title'); else s.launched.title = fmtAbs(la);

    var op = usageOf(svc, 'last_opened');
    text(s.opened, fmtRel(op));
    if (op === null) s.opened.removeAttribute('title'); else s.opened.title = fmtAbs(op);

    var parts = partsOf(svc);
    resRefs.parts.textContent = '';
    for (var i = 0; i < parts.length; i++) {
      var p = (parts[i] && typeof parts[i] === 'object') ? parts[i] : {};
      var tr = make('tr');
      tr.appendChild(text(make('td', 'vw-c-part'), p.name == null ? DASH : String(p.name)));
      tr.appendChild(text(make('td', 'vw-c-kind'), p.kind == null ? DASH : String(p.kind)));
      tr.appendChild(text(make('td', 'vw-c-state'),
        p.running === true ? 'running' : p.running === false ? 'stopped' : DASH));
      tr.appendChild(text(make('td', 'vw-c-num'), fmtBytes(p.rss_bytes)));
      tr.appendChild(text(make('td', 'vw-c-num'), fmtPct(p.cpu_pct)));
      resRefs.parts.appendChild(tr);
    }
    resRefs.wrap.hidden = !parts.length;
    resRefs.none.hidden = !!parts.length;
    /* An empty list has two causes that read identically in the payload but
       not to a reader: this service really has no parts to measure, or the
       server never sent a `resources` key at all (the pre-v3 case this whole
       file is null-safe for). Claiming the first when it is the second tells
       the reader a service is unmeasurable when the server is simply old. */
    if (!parts.length) {
      text(resRefs.none, resources(svc)
        ? 'No parts are registered for this service.'
        : 'Resource use is not available from this server.');
    }
  }

  /* app.js feeds this from three places — the grid's list entry when the page
     opens, the detail payload when it lands, and the 30s poll (which is where
     cpu_pct shows up, on the second sample). Each one may carry only some of
     the three keys, so they merge rather than replace: a detail response that
     predates v3 must not wipe what the list already knew. */
  function detail(key, data) {
    if (!key) {
      resKey = null;
      resData = null;
      if (resSec) resSec.hidden = true;
      return;
    }
    buildRes();
    if (!resSec) return;

    if (key !== resKey) {
      resKey = key;
      resData = {};
    }
    if (data && typeof data === 'object') {
      if (data.usage !== undefined)       resData.usage = data.usage;
      if (data.deployed_at !== undefined) resData.deployed_at = data.deployed_at;
      if (data.resources !== undefined)   resData.resources = data.resources;
    }
    resSec.hidden = false;
    paintRes();
  }

  /* ---------- touch beacons ----------
   *
   * Fire and forget, and deliberately silent: a launch click is navigating the
   * tab away, and a failed beacon (an old backend answers 404) must never
   * block it or put noise in the console.
   */

  function touch(key, event) {
    if (!key) return;
    if (event !== 'launched' && event !== 'opened') return;
    if (typeof window.fetch !== 'function') return;
    try {
      var p = window.fetch('api/services/' + encodeURIComponent(key) + '/touch', {
        method: 'POST',
        keepalive: true,
        cache: 'no-store',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ event: event })
      });
      if (p && typeof p.then === 'function') p.then(noop, noop);
    } catch (e) { /* nothing here is worth interrupting a click for */ }
  }

  /* ---------- api ---------- */

  themeMode = stored(THEME_STORE, THEMES, 'system');
  paintTheme();
  bindThemeButton();

  /* System mode has to follow the OS after load, not only at first paint. */
  if (window.matchMedia) {
    var themeMq = null;
    try { themeMq = window.matchMedia('(prefers-color-scheme: dark)'); }
    catch (e) { themeMq = null; }
    if (themeMq) {
      var onScheme = function () { if (themeMode === 'system') paintTheme(); };
      if (themeMq.addEventListener) themeMq.addEventListener('change', onScheme);
      else if (themeMq.addListener) themeMq.addListener(onScheme);
    }
  }

  window.LauncherView = {
    detail: detail,
    touch:  touch
  };
}());
