/* view.js — v3 view/sort controls, usage beacons, resource figures
 *
 * A self-contained module, like notes.js and tooltip.js. It owns:
 *
 *   - the toolbar (View, Sort) and the header theme-cycle button, persisted
 *     in localStorage per device, exactly like app.js's `launcher.tab`;
 *   - the sort order applied to whatever the active tab and filter yield;
 *   - the table view, rendered into `#view-table`;
 *   - the board (kanban) view, rendered into `#view-board`, with a Group-by
 *     control for Status or Category;
 *   - the "Resources" block on a detail page, rendered into `#view-res`;
 *   - the RAM figure that rides in a tile's corner;
 *   - the `POST api/services/<key>/touch` beacons.
 *
 * app.js calls into it through `window.LauncherView` and nothing else; this
 * file never reaches into app.js. Every selector it creates is prefixed
 * `.vw-`, so it can only style nodes it made itself — the two exceptions are
 * deliberate reuse of app.css's `.d-sec`/`.d-sec-h` shells and `.dot`, so the
 * Resources block reads as part of the page rather than a second design
 * living underneath it.
 *
 * EVERY URL here is RELATIVE ("api/services/<key>/touch"). The page is served
 * at both https://HOST:8093/ and https://HOST/home/, where Tailscale strips
 * the /home prefix; an absolute "/api/..." silently 404s on the mount that is
 * actually bookmarked.
 *
 * NULL-SAFETY IS THE POINT. `usage`, `deployed_at` and `resources` are v3
 * keys. A launcher that predates them sends none of them, and every accessor
 * below has to answer `null` rather than throw — the grid must look
 * deliberate, not broken, against an old backend.
 */
(function () {
  'use strict';

  /* ---------- config ---------- */

  var VIEW_STORE = 'launcher.view';
  var SORT_STORE = 'launcher.sort';
  var THEME_STORE = 'launcher.theme';
  var GROUPBY_STORE = 'launcher.groupby';
  var STAR_STORE = 'launcher.stars';

  var VIEWS = [
    { id: 'grid',  label: 'Grid'  },
    { id: 'table', label: 'Table' },
    { id: 'board', label: 'Board' }
  ];

  var GROUP_BYS = [
    { id: 'state', label: 'Status'   },
    { id: 'group', label: 'Category' }
  ];

  var SORTS = [
    { id: 'used',     label: 'Last used' },
    { id: 'deployed', label: 'Deployed'  },
    { id: 'ram',      label: 'RAM'       }
  ];

  var THEMES = [
    { id: 'system', label: 'System' },
    { id: 'light',  label: 'Light'  },
    { id: 'dark',   label: 'Dark'   }
  ];

  var DASH = '—';     /* em dash: the one and only "we do not know" */
  var KB = 1024;

  /* ---------- state ---------- */

  var viewMode = 'grid';
  var sortMode = 'used';
  var themeMode = 'system';
  var groupByMode = 'state';
  var stars = {};           /* key -> true; starred services pin to the top */
  var onChange = null;

  var bar = null;          /* the toolbar element, once built */
  var groupCtl = null;     /* Group-by select; only visible on the board */
  var tableWrap = null;    /* the scroll container around the table */
  var tableBody = null;
  var rowCache = {};       /* key -> {tr, refs, shape} */

  var boardWrap = null;
  var colCache = {};       /* column id -> {col, title, count, list} */
  var cardCache = {};      /* key -> {node, refs, shape} */

  var resSec = null;       /* the detail page's Resources section */
  var resRefs = null;
  var resKey = null;       /* which service it is showing */
  var resData = null;      /* best-known {usage, deployed_at, resources} */

  var mountBar   = document.getElementById('view-toolbar');
  var mountTable = document.getElementById('view-table');
  var mountBoard = document.getElementById('view-board');
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

  var SVG_NS = 'http://www.w3.org/2000/svg';

  /* Drawn here, never fetched — the launcher has to render with no route out
     of the box. */
  function glyph(paths, width) {
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', width || '1.6');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    for (var i = 0; i < paths.length; i++) {
      var p = document.createElementNS(SVG_NS, 'path');
      p.setAttribute('d', paths[i]);
      svg.appendChild(p);
    }
    return svg;
  }

  var CHEVRON_R = ['m9.5 5.5 6.5 6.5-6.5 6.5'];
  var CHEVRON_D = ['m6 9.5 6 6 6-6'];
  var STAR_PATH = ['M12 3.4l2.15 5.05 5.45.48-4.15 3.55 1.28 5.32L12 15.3 7.27 17.8l1.28-5.32-4.15-3.55 5.45-.48z'];

  /* The icon module owns brand mark -> glyph -> fallback. If it has not
     loaded, hand back an empty box so the table still lays out. */
  function iconNode(svc) {
    var node = null;
    if (typeof window.iconFor === 'function') {
      try { node = window.iconFor(svc.key, svc.icon); } catch (e) { node = null; }
    }
    if (!node || node.nodeType !== 1) {
      node = make('span', 'icon-blank');
      node.setAttribute('aria-hidden', 'true');
    }
    return node;
  }

  function detailHref(key) {
    /* Fragment-only, so it resolves against whichever mount point the page is
       served from. Never an absolute path. */
    return '#/service/' + encodeURIComponent(key);
  }

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

  /* Theme is a page-wide paint, not a list rearrange: it does not go
     through onChange. The inline script in index.html already set
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

  /* ---------- state labels ---------- */

  function liveJob(svc) {
    var job = svc && svc.job;
    if (!job || typeof job !== 'object' || !job.id) return null;
    if (job.status && job.status !== 'running') return null;
    return typeof job.action === 'string' && job.action ? job.action : 'deploy';
  }

  var STATES = {
    active:    { label: 'Running',      dot: 'dot-ok'   },
    stopped:   { label: 'Paused',       dot: 'dot-warn' },
    available: { label: 'Not deployed', dot: 'dot-off'  },
    planned:   { label: 'Planned',      dot: 'dot-off'  }
  };

  /* app.js owns these same four verbs, and this file deliberately never
     reaches into it, so the table keeps its own copy. Spelling them out is
     the point: appending "ing" to the verb turns `stop` into "Stoping", and
     a fifth verb added server-side would concatenate just as badly, which is
     why an unknown one falls back to a word rather than to arithmetic. */
  var GERUNDS = {
    deploy:  'Deploying',
    start:   'Starting',
    stop:    'Stopping',
    restart: 'Restarting'
  };

  function stateLabel(svc) {
    var job = liveJob(svc);
    if (job) return (GERUNDS[job] || 'Working') + '…';
    var def = STATES[svc && svc.state] || STATES.planned;
    return def.label;
  }

  function stateDot(svc) {
    if (liveJob(svc)) return 'dot-job';
    var def = STATES[svc && svc.state] || STATES.planned;
    return def.dot;
  }

  /* A tile's icon+name is a launch target only when there is something to
     launch. Table rows follow exactly the same rule, so the two views never
     disagree about what a tap does. */
  function launchable(svc) {
    return !!svc && !liveJob(svc) && !!svc.url &&
           (svc.state === 'active' || svc.state === 'stopped');
  }

  /* ---------- sorting ----------
   *
   * `list` arrives already filtered by the active tab and the search box, in
   * registry order. Every sort is descending on a number, with nulls last and
   * every tie broken by that registry order — so the grid never shuffles
   * between two equal services, and an old backend (all nulls) leaves the
   * order exactly as it was.
   */

  function keyFor(mode) {
    if (mode === 'deployed') return deployedOf;
    if (mode === 'ram')      return rssOf;
    return function (svc) { return usageOf(svc, 'last_used'); };
  }

  function isStarred(key) {
    return !!(key && stars[key]);
  }

  function loadStars() {
    var raw = null;
    try { raw = window.localStorage.getItem(STAR_STORE); } catch (e) { raw = null; }
    stars = {};
    if (raw == null || raw === '') return;
    try {
      var parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return;
      for (var i = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i]) stars[parsed[i]] = true;
      }
    } catch (e) { stars = {}; }
  }

  function rememberStars() {
    var keys = [];
    for (var k in stars) {
      if (Object.prototype.hasOwnProperty.call(stars, k) && stars[k]) keys.push(k);
    }
    try {
      if (!keys.length) window.localStorage.removeItem(STAR_STORE);
      else window.localStorage.setItem(STAR_STORE, JSON.stringify(keys));
    } catch (e) { /* private mode */ }
  }

  function toggleStar(key) {
    if (!key) return;
    if (stars[key]) delete stars[key];
    else stars[key] = true;
    rememberStars();
    if (onChange) onChange();
  }

  function starGlyph(on) {
    var svg = glyph(STAR_PATH, '1.5');
    if (on) {
      svg.setAttribute('fill', 'currentColor');
      svg.setAttribute('stroke', 'none');
    }
    return svg;
  }

  function paintStar(btn, key) {
    if (!btn || btn.nodeType !== 1) return;
    var on = isStarred(key);
    btn.className = on ? 'vw-star is-on' : 'vw-star';
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    btn.setAttribute('aria-label', on ? 'Unstar' : 'Star');
    btn.title = on ? 'Starred' : 'Star';
    btn.textContent = '';
    btn.appendChild(starGlyph(on));
  }

  function starButton(key) {
    var btn = make('button', 'vw-star');
    btn.type = 'button';
    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      toggleStar(key);
    });
    paintStar(btn, key);
    return btn;
  }

  function arrange(list) {
    if (!list || list.length < 2) return list || [];
    var get = keyFor(sortMode);

    var deco = [];
    for (var i = 0; i < list.length; i++) {
      deco.push({ svc: list[i], i: i, v: get(list[i]) });
    }

    /* Starred first, then the chosen sort. Decorated rather than relying on
       a stable Array#sort: the tie-break on registry order has to be exact,
       not "whatever the engine does". */
    deco.sort(function (a, b) {
      var as = isStarred(a.svc && a.svc.key) ? 0 : 1;
      var bs = isStarred(b.svc && b.svc.key) ? 0 : 1;
      if (as !== bs) return as - bs;
      if (a.v === null && b.v === null) return a.i - b.i;
      if (a.v === null) return 1;
      if (b.v === null) return -1;
      if (a.v === b.v) return a.i - b.i;
      return b.v - a.v;
    });

    var out = [];
    for (var j = 0; j < deco.length; j++) out.push(deco[j].svc);
    return out;
  }

  /* Partition `list` into the catalog's buckets, sort each with arrange(),
     and emit {type:'h', id, label} / {type:'s', svc} so both views paint
     the same headings. Services whose group is missing or not in the
     catalog land in Other at the end. An empty catalog (old backend)
     yields a flat list of service items — no headings. */
  var groupRowCache = {};

  function grouped(list, catalog) {
    var items = list || [];
    var cats = [];
    var seen = {};
    var i, j, gid;
    if (catalog && catalog.length) {
      for (i = 0; i < catalog.length; i++) {
        gid = catalog[i] && catalog[i].id;
        if (!gid || seen[gid]) continue;
        seen[gid] = true;
        cats.push({ id: gid, label: catalog[i].label || gid });
      }
    }

    if (!cats.length) {
      var flat = arrange(items);
      var plain = [];
      for (i = 0; i < flat.length; i++) plain.push({ type: 's', svc: flat[i] });
      return plain;
    }

    var byId = {};
    var other = [];
    for (i = 0; i < items.length; i++) {
      gid = items[i] && items[i].group;
      if (gid && seen[gid]) {
        if (!byId[gid]) byId[gid] = [];
        byId[gid].push(items[i]);
      } else {
        other.push(items[i]);
      }
    }

    var out = [];
    for (i = 0; i < cats.length; i++) {
      var chunk = byId[cats[i].id];
      if (!chunk || !chunk.length) continue;
      out.push({ type: 'h', id: cats[i].id, label: cats[i].label });
      var sorted = arrange(chunk);
      for (j = 0; j < sorted.length; j++) out.push({ type: 's', svc: sorted[j] });
    }
    if (other.length) {
      out.push({ type: 'h', id: 'other', label: 'Other' });
      var rest = arrange(other);
      for (j = 0; j < rest.length; j++) out.push({ type: 's', svc: rest[j] });
    }
    return out;
  }

  function groupRow(id, label) {
    var tr = groupRowCache[id];
    if (!tr) {
      tr = make('tr', 'vw-g');
      var td = make('td', 'vw-g-cell');
      td.colSpan = 7;
      tr.appendChild(td);
      groupRowCache[id] = tr;
    }
    text(tr.firstChild, label);
    return tr;
  }

  /* ---------- toolbar ---------- */

  function select(id, label, options, current, onPick) {
    var wrap = make('span', 'vw-ctl');

    var lab = make('label', 'vw-lab');
    lab.setAttribute('for', id);
    text(lab, label);
    wrap.appendChild(lab);

    /* A real <select>, laid transparent over the value we draw ourselves.
       Native is non-negotiable — on a phone the OS picker beats anything
       drawn here, and it keeps the keyboard and the screen reader for free —
       but a native select is as wide as its widest option, which leaves a
       chevron stranded 40px from the word "RAM". Drawing the value means the
       control is exactly as wide as what it says. */
    var box = make('span', 'vw-selwrap');

    var sel = make('select', 'vw-sel');
    sel.id = id;
    var label0 = '';
    for (var i = 0; i < options.length; i++) {
      var opt = make('option');
      opt.value = options[i].id;
      text(opt, options[i].label);
      if (options[i].id === current) { opt.selected = true; label0 = options[i].label; }
      sel.appendChild(opt);
    }

    var val = text(make('span', 'vw-val'), label0);
    val.setAttribute('aria-hidden', 'true');   /* the select says it already */

    sel.addEventListener('change', function () {
      var chosen = sel.options[sel.selectedIndex];
      text(val, chosen ? chosen.textContent : '');
      onPick(sel.value);
    });

    box.appendChild(sel);
    box.appendChild(val);
    box.appendChild(glyph(CHEVRON_D, '1.8'));
    wrap.appendChild(box);

    return wrap;
  }

  function buildBar() {
    if (bar || !mountBar) return;
    bar = make('div', 'vw-bar');

    bar.appendChild(select('vw-view', 'View', VIEWS, viewMode, function (v) {
      if (v === viewMode) return;
      viewMode = v;
      remember(VIEW_STORE, v);
      paintGroupCtl();
      if (onChange) onChange();
    }));

    bar.appendChild(select('vw-sort', 'Sort', SORTS, sortMode, function (v) {
      if (v === sortMode) return;
      sortMode = v;
      remember(SORT_STORE, v);
      if (onChange) onChange();
    }));

    groupCtl = select('vw-groupby', 'Group by', GROUP_BYS, groupByMode, function (v) {
      if (v === groupByMode) return;
      groupByMode = v;
      remember(GROUPBY_STORE, v);
      if (onChange) onChange();
    });
    paintGroupCtl();
    bar.appendChild(groupCtl);

    mountBar.appendChild(bar);
  }

  function paintGroupCtl() {
    if (groupCtl) groupCtl.hidden = viewMode !== 'board';
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

  /* ---------- table ---------- */

  var COLUMNS = [
    { label: 'Service',   cls: 'vw-c-name' },
    { label: 'State',     cls: 'vw-c-state' },
    { label: 'RAM',       cls: 'vw-c-num' },
    { label: 'CPU',       cls: 'vw-c-num' },
    { label: 'Last used', cls: 'vw-c-when' },
    { label: 'Deployed',  cls: 'vw-c-when' }
  ];

  function buildTable() {
    if (tableWrap || !mountTable) return;

    /* Its own scroll container, and the only thing on the page allowed to
       scroll sideways — the body must never do it at 400px. tabindex makes
       that scroll reachable from the keyboard, which is why it needs a role
       and a name too. */
    tableWrap = make('div', 'vw-wrap');
    tableWrap.setAttribute('role', 'region');
    tableWrap.setAttribute('aria-label', 'Services');
    tableWrap.tabIndex = 0;

    var table = make('table', 'vw-table');
    var head = make('thead');
    var hrow = make('tr');
    for (var i = 0; i < COLUMNS.length; i++) {
      var th = make('th', COLUMNS[i].cls);
      th.scope = 'col';
      text(th, COLUMNS[i].label);
      hrow.appendChild(th);
    }
    var last = make('th', 'vw-c-go');
    last.scope = 'col';
    last.appendChild(text(make('span', 'sr-only'), 'Details'));
    hrow.appendChild(last);
    head.appendChild(hrow);
    table.appendChild(head);

    tableBody = make('tbody');
    table.appendChild(tableBody);
    tableWrap.appendChild(table);

    /* One delegated listener, because rows are reconciled away underneath it.
       Anything that is not the launch link (or a text selection) opens the
       detail page — the row's blank space, exactly like a tile's. */
    tableBody.addEventListener('click', function (e) {
      var node = e.target;
      while (node && node !== tableBody) {
        if (node.tagName === 'A' || node.tagName === 'BUTTON') return;
        node = node.parentNode;
      }
      var tr = e.target;
      while (tr && tr !== tableBody && tr.tagName !== 'TR') tr = tr.parentNode;
      if (!tr || tr === tableBody) return;
      var key = tr.getAttribute('data-key');
      if (!key) return;
      try {
        var sel = window.getSelection();
        if (sel && String(sel).length && !sel.isCollapsed) return;   /* selecting text */
      } catch (err) { /* no selection API */ }
      location.hash = detailHref(key);
    });

    mountTable.appendChild(tableWrap);
  }

  /* A row is built once and then updated in place, so a 30s poll never steals
     focus from the chevron or blows away the row you are pointing at. The
     only thing that forces a rebuild is the row changing shape — gaining or
     losing its launch link. */
  function buildRow(svc) {
    var tr = make('tr', 'vw-row');
    tr.setAttribute('data-key', svc.key);

    var refs = {};

    var nameTd = make('td', 'vw-c-name');
    var open;
    if (launchable(svc)) {
      open = make('a', 'vw-open');
      open.target = '_blank';
      open.rel = 'noopener noreferrer';
      open.addEventListener('click', function () { touch(svc.key, 'launched'); });
    } else {
      open = make('span', 'vw-open vw-open-flat');
    }
    refs.open = open;

    refs.icon = make('span', 'vw-icon');
    open.appendChild(refs.icon);

    var stack = make('span', 'vw-stack');
    refs.name = make('span', 'vw-name');
    refs.tag = make('span', 'vw-tag');
    stack.appendChild(refs.name);
    stack.appendChild(refs.tag);
    open.appendChild(stack);
    refs.star = starButton(svc.key);
    nameTd.appendChild(refs.star);
    nameTd.appendChild(open);
    tr.appendChild(nameTd);

    var stateTd = make('td', 'vw-c-state');
    refs.state = make('span', 'vw-state');
    refs.dot = make('i', 'dot');
    refs.stateText = make('span');
    refs.state.appendChild(refs.dot);
    refs.state.appendChild(refs.stateText);
    stateTd.appendChild(refs.state);
    tr.appendChild(stateTd);

    refs.ram = make('td', 'vw-c-num');
    refs.cpu = make('td', 'vw-c-num');
    refs.used = make('td', 'vw-c-when');
    refs.deployed = make('td', 'vw-c-when');
    tr.appendChild(refs.ram);
    tr.appendChild(refs.cpu);
    tr.appendChild(refs.used);
    tr.appendChild(refs.deployed);

    var goTd = make('td', 'vw-c-go');
    refs.go = make('a', 'vw-go');
    refs.go.appendChild(glyph(CHEVRON_R, '1.8'));
    goTd.appendChild(refs.go);
    tr.appendChild(goTd);

    return { tr: tr, refs: refs, shape: launchable(svc) };
  }

  function fillRow(entry, svc) {
    var r = entry.refs;
    var name = svc.name || svc.key;

    if (r.icon.firstChild === null || r.iconKey !== (svc.key + '|' + svc.icon)) {
      r.icon.textContent = '';
      r.icon.appendChild(iconNode(svc));
      r.iconKey = svc.key + '|' + svc.icon;
    }

    text(r.name, name);
    text(r.tag, svc.tagline || '');
    r.tag.hidden = !svc.tagline;

    if (entry.shape) {
      r.open.href = svc.url;
      r.open.setAttribute('aria-label', 'Open ' + name + ' in a new tab');
    }

    r.dot.className = 'dot ' + stateDot(svc);
    text(r.stateText, stateLabel(svc));

    text(r.ram, fmtBytes(rssOf(svc)));
    text(r.cpu, fmtPct(cpuOf(svc)));

    var used = usageOf(svc, 'last_used');
    text(r.used, fmtRel(used));
    if (used === null) r.used.removeAttribute('title'); else r.used.title = fmtAbs(used);

    var dep = deployedOf(svc);
    text(r.deployed, fmtDate(dep));
    if (dep === null) r.deployed.removeAttribute('title'); else r.deployed.title = fmtAbs(dep);

    r.go.href = detailHref(svc.key);
    r.go.setAttribute('aria-label', 'Details for ' + name);
    paintStar(r.star, svc.key);
  }

  function rowFor(svc) {
    var hit = rowCache[svc.key];
    if (!hit || hit.shape !== launchable(svc)) {
      hit = buildRow(svc);
      rowCache[svc.key] = hit;
    }
    fillRow(hit, svc);
    return hit.tr;
  }

  /* `null` unmounts the table entirely (the grid is on screen); `[]` leaves it
     hidden but mounted (nothing to show yet, or the filter matched nothing —
     app.js owns the empty message). */
  function table(list) {
    if (list === null || list === undefined) {
      if (tableWrap) tableWrap.hidden = true;
      return;
    }
    buildTable();
    if (!tableWrap) return;

    if (!list.length) { tableWrap.hidden = true; return; }

    var nodes = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (item && item.type === 'h') nodes.push(groupRow(item.id, item.label));
      else if (item && item.type === 's') nodes.push(rowFor(item.svc));
      else nodes.push(rowFor(item));
    }

    /* Keyed reconcile, same discipline as app.js's syncGrid: only touch the
       DOM where it actually differs, so scroll and focus survive a poll. */
    for (var j = 0; j < nodes.length; j++) {
      var current = tableBody.childNodes[j];
      if (current !== nodes[j]) tableBody.insertBefore(nodes[j], current || null);
    }
    while (tableBody.childNodes.length > nodes.length) {
      tableBody.removeChild(tableBody.lastChild);
    }

    tableWrap.hidden = false;
  }

  /* ---------- board ----------
   *
   * Columns are the chosen categorical field (Status or Category). Cards
   * stay the same services the grid and table would have shown; only the
   * partition changes. Empty columns stay so the field's shape is visible
   * (Other is the exception: it only appears when something lands there).
   * Cards do not drag — Status is a live probe and Category is registry
   * data, and neither is a thing a swipe should rewrite.
   */

  var STATE_COLS = [
    { id: 'active',      label: 'Active' },
    { id: 'stopped',     label: 'Paused' },
    { id: 'uninstalled', label: 'Uninstalled' }
  ];

  function flattenBoard(list) {
    var out = [];
    if (!list) return out;
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (item && item.type === 'h') continue;
      if (item && item.type === 's' && item.svc) out.push(item.svc);
      else if (item && item.key) out.push(item);
    }
    return out;
  }

  function colDefs(catalog) {
    if (groupByMode !== 'group') return STATE_COLS;
    var defs = [];
    var seen = {};
    if (catalog) {
      for (var i = 0; i < catalog.length; i++) {
        var g = catalog[i];
        if (!g || !g.id || seen[g.id]) continue;
        seen[g.id] = true;
        defs.push({ id: g.id, label: g.label || g.id });
      }
    }
    defs.push({ id: 'other', label: 'Other' });
    return defs;
  }

  function catalogIdsOf(defs) {
    var ids = {};
    for (var i = 0; i < defs.length; i++) ids[defs[i].id] = true;
    return ids;
  }

  function bucketOf(svc, known) {
    if (groupByMode === 'group') {
      var gid = svc && svc.group;
      return (gid && known[gid]) ? gid : 'other';
    }
    var st = svc && svc.state;
    if (st === 'active') return 'active';
    if (st === 'stopped') return 'stopped';
    return 'uninstalled';
  }

  function buildBoard() {
    if (boardWrap || !mountBoard) return;
    boardWrap = make('div', 'vw-board');
    boardWrap.setAttribute('role', 'region');
    boardWrap.setAttribute('aria-label', 'Board');
    boardWrap.tabIndex = 0;

    boardWrap.addEventListener('click', function (e) {
      var node = e.target;
      while (node && node !== boardWrap) {
        if (node.tagName === 'A' || node.tagName === 'BUTTON') return;
        node = node.parentNode;
      }
      var card = e.target;
      while (card && card !== boardWrap &&
             !(card.getAttribute && card.getAttribute('data-key'))) {
        card = card.parentNode;
      }
      if (!card || card === boardWrap) return;
      var key = card.getAttribute('data-key');
      if (!key) return;
      try {
        var sel = window.getSelection();
        if (sel && String(sel).length && !sel.isCollapsed) return;
      } catch (err) { /* no selection API */ }
      location.hash = detailHref(key);
    });

    mountBoard.appendChild(boardWrap);
  }

  function colFor(def) {
    var hit = colCache[def.id];
    if (!hit) {
      var col = make('section', 'vw-col');
      col.setAttribute('data-col', def.id);

      var head = make('header', 'vw-col-h');
      var title = make('h3', 'vw-col-title');
      title.id = 'vw-col-h-' + def.id;
      var count = make('span', 'vw-col-n');
      count.setAttribute('aria-hidden', 'true');
      head.appendChild(title);
      head.appendChild(count);

      var list = make('div', 'vw-col-list');
      list.setAttribute('role', 'list');
      list.setAttribute('aria-labelledby', title.id);

      col.setAttribute('aria-labelledby', title.id);
      var empty = make('p', 'vw-col-empty');
      text(empty, 'None');
      col.appendChild(head);
      col.appendChild(list);
      hit = { col: col, title: title, count: count, list: list, empty: empty };
      colCache[def.id] = hit;
    }
    text(hit.title, def.label);
    return hit;
  }

  function buildCard(svc) {
    var art = make('article', 'vw-card');
    art.setAttribute('data-key', svc.key);
    art.setAttribute('role', 'listitem');

    var refs = {};
    var top = make('div', 'vw-card-top');
    var open;
    if (launchable(svc)) {
      open = make('a', 'vw-open');
      open.target = '_blank';
      open.rel = 'noopener noreferrer';
      open.addEventListener('click', function () { touch(svc.key, 'launched'); });
    } else {
      open = make('span', 'vw-open vw-open-flat');
    }
    refs.open = open;

    refs.icon = make('span', 'vw-icon');
    open.appendChild(refs.icon);

    var stack = make('span', 'vw-stack');
    refs.name = make('span', 'vw-name');
    refs.tag = make('span', 'vw-tag');
    stack.appendChild(refs.name);
    stack.appendChild(refs.tag);
    open.appendChild(stack);
    top.appendChild(open);
    refs.star = starButton(svc.key);
    top.appendChild(refs.star);
    art.appendChild(top);

    refs.meta = make('div', 'vw-card-meta');
    refs.dot = make('i', 'dot');
    refs.stateText = make('span', 'vw-card-state');
    refs.ram = make('span', 'vw-card-ram');
    refs.meta.appendChild(refs.dot);
    refs.meta.appendChild(refs.stateText);
    refs.meta.appendChild(refs.ram);
    art.appendChild(refs.meta);

    return { node: art, refs: refs, shape: launchable(svc) };
  }

  function fillCard(entry, svc, catalog) {
    var r = entry.refs;
    var name = svc.name || svc.key;

    if (r.icon.firstChild === null || r.iconKey !== (svc.key + '|' + svc.icon)) {
      r.icon.textContent = '';
      r.icon.appendChild(iconNode(svc));
      r.iconKey = svc.key + '|' + svc.icon;
    }

    text(r.name, name);
    text(r.tag, svc.tagline || '');
    r.tag.hidden = !svc.tagline;

    if (entry.shape) {
      r.open.href = svc.url;
      r.open.setAttribute('aria-label', 'Open ' + name + ' in a new tab');
    }

    r.dot.className = 'dot ' + stateDot(svc);
    text(r.stateText, stateLabel(svc));

    var mem = ram(svc);
    text(r.ram, mem);
    r.ram.hidden = !mem;

    paintStar(r.star, svc.key);

    entry.node.className = isStarred(svc.key) ? 'vw-card is-starred' : 'vw-card';
    entry.node.setAttribute('aria-label',
      name + ', ' + stateLabel(svc) + (isStarred(svc.key) ? ', starred' : ''));
  }

  function cardFor(svc, catalog) {
    var hit = cardCache[svc.key];
    if (!hit || hit.shape !== launchable(svc)) {
      hit = buildCard(svc);
      cardCache[svc.key] = hit;
    }
    fillCard(hit, svc, catalog);
    return hit.node;
  }

  function board(list, catalog) {
    if (list === null || list === undefined) {
      if (boardWrap) boardWrap.hidden = true;
      return;
    }
    buildBoard();
    if (!boardWrap) return;

    var items = flattenBoard(list);
    if (!items.length) { boardWrap.hidden = true; return; }

    var defs = colDefs(catalog);
    var known = catalogIdsOf(defs);
    var byId = {};
    var i, id;
    for (i = 0; i < defs.length; i++) byId[defs[i].id] = [];
    for (i = 0; i < items.length; i++) {
      id = bucketOf(items[i], known);
      if (!byId[id]) byId[id] = [];
      byId[id].push(items[i]);
    }

    var cols = [];
    var live = {};
    for (i = 0; i < defs.length; i++) {
      var chunk = arrange(byId[defs[i].id] || []);
      /* Status keeps empty lanes (that is the board). Category matches
         the grid: a heading with nothing under it is omitted. */
      if (!chunk.length && groupByMode === 'group') continue;
      var hit = colFor(defs[i]);
      text(hit.count, String(chunk.length));
      var cards = [];
      if (!chunk.length) {
        cards.push(hit.empty);
      } else {
        for (var j = 0; j < chunk.length; j++) {
          var node = cardFor(chunk[j], catalog);
          live[chunk[j].key] = true;
          cards.push(node);
        }
      }
      for (var k = 0; k < cards.length; k++) {
        var cur = hit.list.childNodes[k];
        if (cur !== cards[k]) hit.list.insertBefore(cards[k], cur || null);
      }
      while (hit.list.childNodes.length > cards.length) {
        hit.list.removeChild(hit.list.lastChild);
      }
      cols.push(hit.col);
    }

    for (var c = 0; c < cols.length; c++) {
      var here = boardWrap.childNodes[c];
      if (here !== cols[c]) boardWrap.insertBefore(cols[c], here || null);
    }
    while (boardWrap.childNodes.length > cols.length) {
      boardWrap.removeChild(boardWrap.lastChild);
    }

    for (var key in cardCache) {
      if (Object.prototype.hasOwnProperty.call(cardCache, key) && !live[key]) {
        delete cardCache[key];
      }
    }

    boardWrap.hidden = false;
  }

  /* ---------- the tile's RAM figure ----------
   *
   * It rides inside the tile's corner slot, which is absolutely positioned and
   * pointer-events: none — so adding it moves nothing else on the tile, which
   * was the condition for putting it on the grid at all.
   */

  function ram(svc) {
    var n = rssOf(svc);
    if (n === null || n < 0) return '';
    if (!svc || !(svc.state === 'active' || svc.state === 'stopped')) return '';
    /* A bare em dash beside the status dot is noise, not information: on the
       grid, "we do not know" is simply nothing. */
    return fmtBytes(n);
  }

  function ramTag(corner, svc) {
    if (!corner || corner.nodeType !== 1) return;
    var label = ram(svc);
    var tag = corner.firstChild;
    if (!tag || !tag.className || String(tag.className).indexOf('vw-tileram') === -1) {
      if (!label) return;
      tag = make('span', 'vw-tileram');
      corner.insertBefore(tag, corner.firstChild);
    }
    text(tag, label);
    tag.hidden = !label;
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
    { label: 'Part', cls: 'vw-c-part' },
    { label: 'Kind', cls: 'vw-c-kind' },
    { label: 'RAM',  cls: 'vw-c-num' },
    { label: 'CPU',  cls: 'vw-c-num' }
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

  viewMode = stored(VIEW_STORE, VIEWS, 'grid');
  sortMode = stored(SORT_STORE, SORTS, 'used');
  groupByMode = stored(GROUPBY_STORE, GROUP_BYS, 'state');
  loadStars();
  themeMode = stored(THEME_STORE, THEMES, 'system');
  paintTheme();
  bindThemeButton();
  buildBar();

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
    /* Table and board need their mount points. Without one the honest
       answer is Grid, rather than telling app.js to hide the grid for a
       view that can never be drawn. */
    mode:    function () {
      if ((viewMode === 'table' && !mountTable) ||
          (viewMode === 'board' && !mountBoard)) return 'grid';
      return viewMode;
    },
    sort:    function () { return sortMode; },
    groupBy: function () { return groupByMode; },
    arrange: arrange,
    grouped: grouped,
    table:   table,
    board:   board,
    isStarred: isStarred,
    starButton: starButton,
    paintStar: paintStar,
    ram:     ram,
    ramTag:  ramTag,
    detail:  detail,
    touch:   touch,
    toolbar: function (visible) { if (mountBar) mountBar.hidden = !visible; },
    onChange: function (fn) { onChange = typeof fn === 'function' ? fn : null; }
  };
}());
