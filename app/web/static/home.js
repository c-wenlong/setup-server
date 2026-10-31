/* home.js — the launcher's home page and its sidebar shell
 *
 * Owns everything inside #home: the page header, the disk alert, the box
 * health strip (memory, disk, load), and the app list grouped Running /
 * Stopped / Not installed. Also drives the sidebar around every page: the
 * active link, the collapse-to-rail toggle, the phone drawer, the monitoring
 * shortcuts and the breadcrumb.
 *
 * It paints from the list app.js already polls (window.LauncherApp) and
 * repaints on the `launcher:services` event app.js fires after each poll.
 * Every lifecycle verb goes back through LauncherApp.action(), which opens
 * app.js's own confirm-then-log sheet, so nothing here can stop, start or
 * install a service without the same confirm the detail page asks for.
 *
 * Keyboard (desktop): ↑/↓ moves the selection, ↵ runs the row's primary
 * action, ⌘K / Ctrl-K opens its action menu, / jumps to search.
 *
 * EVERY URL here is RELATIVE or a fragment. The page is served at both `/`
 * and `/home/`, where Tailscale strips the prefix; an absolute path breaks
 * the mount that is actually bookmarked.
 */
(function () {
  'use strict';

  /* ---------- config ---------- */

  var SORT_STORE  = 'launcher.home.sort';
  var GROUP_STORE = 'launcher.home.group';
  var FOLD_STORE  = 'launcher.home.fold';
  var RAIL_STORE  = 'launcher.rail';

  /* Disk is the one figure that has taken this box down before: past
     DISK_CRIT the page says so in a sentence above everything else. */
  var DISK_WARN = 0.85;
  var DISK_CRIT = 0.95;
  /* Memory is tight when less than this share is available. */
  var MEM_WARN  = 0.10;

  /* Sidebar shortcuts: opened in a new tab, shown only while running. */
  var WATCH = ['uptime-kuma', 'beszel', 'ntfy'];

  var GERUND = {
    deploy: 'Deploying', start: 'Starting', stop: 'Stopping',
    restart: 'Restarting', remove: 'Removing', update: 'Updating'
  };

  var root = document.getElementById('home');
  if (!root) return;

  var $ = function (id) { return document.getElementById(id); };
  var SVG_NS = 'http://www.w3.org/2000/svg';

  /* ---------- state ---------- */

  var state = {
    q: '',
    group: stored(GROUP_STORE, 'all'),
    sort: parseSort(stored(SORT_STORE, 'ram:-1')),
    fold: parseFold(stored(FOLD_STORE, '')),
    sel: null,
    menu: null
  };

  var built = false;
  var orderAdopted = false;
  var els = {};
  var menuEl = null;
  var menuScrim = null;
  var menuOpener = null;
  var menuHi = -1;
  var toastTimer = null;

  /* The storage sheet behind the disk cell's ⓘ. `data` survives a close
     so a reopen paints the last answer instantly while api/disk refetches. */
  var dsk = {
    el: null, scrim: null, opener: null, sub: null, body: null, foot: null,
    data: null, err: false, fetching: false, timer: null
  };
  var DISK_POLL_MS = 3000;

  /* ---------- small helpers ---------- */

  function app() { return window.LauncherApp || null; }

  /* Everything the launcher knows about, machinery included. */
  function everything() {
    var a = app();
    return (a && typeof a.services === 'function') ? a.services() : [];
  }

  /* The apps: everything except services marked hidden (deployd, which is
     the Deploys page rather than a row) and rows the user shelved under
     Hidden themselves. */
  function list() {
    return everything().filter(function (s) {
      return s.hidden !== true && s.user_hidden !== true;
    });
  }

  /* Rows the user hid, shown under their own section. Manifest-hidden
     machinery never lands here — deployd has its own page. */
  function hiddenList() {
    return everything().filter(function (s) { return s.hidden !== true && s.user_hidden === true; })
      .sort(function (a, b) {
        return String(a.name || a.key).localeCompare(String(b.name || b.key));
      });
  }

  function stored(key, fallback) {
    try {
      var v = window.localStorage.getItem(key);
      return v === null ? fallback : v;
    } catch (e) { return fallback; }
  }

  function remember(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }

  function parseSort(raw) {
    var m = /^(name|ram|cpu|used|custom):(-?1)$/.exec(String(raw));
    return m ? { key: m[1], dir: Number(m[2]) } : { key: 'ram', dir: -1 };
  }

  function parseFold(raw) {
    /* hidden starts folded every load — it's a shelf you open to peek,
       so its state is deliberately not persisted. */
    var out = { stop: false, fresh: false, hidden: true };
    String(raw).split(',').forEach(function (k) {
      if (k === 'stop' || k === 'fresh') out[k] = true;
    });
    return out;
  }

  function make(tag, cls, value) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (value !== undefined && value !== null) n.textContent = String(value);
    return n;
  }

  function svg(paths, opts) {
    var o = opts || {};
    var s = document.createElementNS(SVG_NS, 'svg');
    s.setAttribute('viewBox', o.box || '0 0 24 24');
    s.setAttribute('fill', o.fill || 'none');
    s.setAttribute('stroke', o.fill ? 'none' : 'currentColor');
    s.setAttribute('stroke-width', o.width || '1.8');
    s.setAttribute('stroke-linecap', 'round');
    s.setAttribute('stroke-linejoin', 'round');
    s.setAttribute('aria-hidden', 'true');
    s.setAttribute('focusable', 'false');
    for (var i = 0; i < paths.length; i++) {
      var p = document.createElementNS(SVG_NS, 'path');
      p.setAttribute('d', paths[i]);
      s.appendChild(p);
    }
    return s;
  }

  var ICON = {
    search:  ['M17 11a6 6 0 1 1-12 0 6 6 0 0 1 12 0Z', 'm15.6 15.6 4.4 4.4'],
    open:    ['M14 4h6v6', 'M20 4l-9 9', 'M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5'],
    restart: ['M20 11a8 8 0 1 0-2.3 5.7', 'M20 4v7h-7'],
    stop:    ['M7 6h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1Z'],
    play:    ['M8 5.5v13l10.5-6.5Z'],
    copy:    ['M9.5 9.5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-6a2 2 0 0 1-2-2Z',
              'M15.5 7.5v-1a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h1'],
    info:    ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z', 'M12 11v5', 'M12 8h.01'],
    down:    ['M12 4v11', 'M7 10l5 5 5-5', 'M5 20h14'],
    up:      ['M12 20V9', 'M7 14l5-5 5 5', 'M5 4h14'],
    trash:   ['M5 7h14', 'M10 7V5h4v2', 'M7 7l1 12h8l1-12'],
    log:     ['M5 6h14', 'M5 12h14', 'M5 18h9'],
    lock:    ['M8 10.6V8.3a4 4 0 0 1 8 0v2.3',
              'M6.4 10.6h11.2a1.4 1.4 0 0 1 1.4 1.4v6.2a1.4 1.4 0 0 1-1.4 1.4H6.4A1.4 1.4 0 0 1 5 18.2V12a1.4 1.4 0 0 1 1.4-1.4Z'],
    warn:    ['M12 3.5 2.5 20h19L12 3.5Z', 'M12 10v4', 'M12 17h.01'],
    caret:   ['m7 10 5 5 5-5'],
    cross:   ['m6.5 6.5 11 11', 'm17.5 6.5-11 11'],
    ext:     ['M14 5h5v5', 'M19 5l-8 8'],
    pin:     ['M12 17v5', 'M9 10.8a2 2 0 0 1-1.1 1.8l-1.8.9A2 2 0 0 0 5 15.3V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.7a2 2 0 0 0-1.1-1.8l-1.8-.9A2 2 0 0 1 15 10.8V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z'],
    grip:    ['M9 5.5h.01', 'M15 5.5h.01', 'M9 12h.01', 'M15 12h.01', 'M9 18.5h.01', 'M15 18.5h.01'],
    eye:     ['M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8Z', 'M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6Z'],
    eyeoff:  ['M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19',
              'm14.12 14.12a3 3 0 1 1-4.24-4.24',
              'M6.61 6.61A13.53 13.53 0 0 0 1 12s4 8 11 8a9.74 9.74 0 0 0 5.39-1.61',
              'M2 2l20 20']
  };

  /* Status glyphs: state in the SHAPE (Linear's convention), colour only on
     top. Solid check = running, half ring = partly up, X = not answering,
     empty ring = stopped, dotted ring = not installed, dashed = planned. */
  function glyph(kind) {
    var s = document.createElementNS(SVG_NS, 'svg');
    s.setAttribute('viewBox', '0 0 14 14');
    s.setAttribute('class', 'h-glyph h-g-' + kind);
    s.setAttribute('aria-hidden', 'true');
    s.setAttribute('focusable', 'false');
    var html = {
      ok:    '<circle cx="7" cy="7" r="6" class="f"/><path d="M4.3 7.2l1.8 1.8 3.6-3.8" class="k"/>',
      part:  '<circle cx="7" cy="7" r="5.6" class="s"/><path d="M7 3.4a3.6 3.6 0 0 1 0 7.2z" class="f"/>',
      bad:   '<circle cx="7" cy="7" r="6" class="f"/><path d="M5 5l4 4M9 5l-4 4" class="k"/>',
      ring:  '<circle cx="7" cy="7" r="5.6" class="s"/>',
      dots:  '<circle cx="7" cy="7" r="5.6" class="s" stroke-dasharray="0.1 2.9"/>',
      dash:  '<circle cx="7" cy="7" r="5.6" class="s" stroke-dasharray="2.4 2"/>',
      busy:  '<circle cx="7" cy="7" r="5.6" class="t"/><path d="M7 1.4a5.6 5.6 0 0 1 5.6 5.6" class="s spin"/>',
      pin:   '<path d="M4.5 2h5v.9l-1 .3v3l1.7 1.9V10H3.8V8.1l1.7-1.9v-3l-1-.3z M6.55 10h.9v2.6h-.9z" class="f"/>',
      hid:   '<path d="M1.5 7S3.8 3.5 7 3.5 12.5 7 12.5 7 10.2 10.5 7 10.5 1.5 7 1.5 7Z" class="s"/><path d="M6.2 6.2a1.2 1.2 0 0 0 1.6 1.6" class="s"/><path d="M2.5 11.5l9-9" class="s"/>'
    }[kind] || '';
    s.innerHTML = html;
    return s;
  }

  function iconNode(svc) {
    var node = null;
    if (typeof window.iconFor === 'function') {
      try { node = window.iconFor(svc.key, svc.icon, svc.favicon); } catch (e) { node = null; }
    }
    if (!node || node.nodeType !== 1) {
      node = make('span', 'icon-blank');
      node.setAttribute('aria-hidden', 'true');
    }
    return node;
  }

  function num(v) { return (typeof v === 'number' && isFinite(v)) ? v : null; }

  /* Same 1024 base and labels as view.js, so a figure here matches the
     detail page's Resources block to the digit. */
  function fmtBytes(v) {
    var n = num(v);
    if (n === null || n < 0) return '';
    var units = ['KB', 'MB', 'GB', 'TB'];
    var i = -1, x = n;
    while (x >= 1024 && i < units.length - 1) { x /= 1024; i++; }
    if (i < 0) return Math.round(n) + ' B';
    return (x < 10 ? (Math.round(x * 10) / 10) : Math.round(x)) + ' ' + units[i];
  }

  function fmtPct(v) {
    var n = num(v);
    if (n === null || n < 0) return '';
    return (n > 0 && n < 0.1 ? '<0.1' : (Math.round(n * 10) / 10)) + '%';
  }

  function ago(ts) {
    var t = num(ts);
    if (t === null) return '';
    var s = Date.now() / 1000 - t;
    if (s < 90) return 'just now';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 86400) return Math.round(s / 3600) + ' h ago';
    var d = Math.round(s / 86400);
    return d < 45 ? d + ' d ago' : Math.round(d / 30) + ' mo ago';
  }

  function fmtUptime(sec) {
    var s = num(sec);
    if (s === null) return '';
    var d = Math.floor(s / 86400);
    if (d >= 1) return 'Up ' + d + (d === 1 ? ' day' : ' days');
    var h = Math.floor(s / 3600);
    return h >= 1 ? 'Up ' + h + ' h' : 'Up ' + Math.max(1, Math.round(s / 60)) + ' min';
  }

  /* ---------- reading a service ---------- */

  function liveJob(svc) {
    var job = svc && svc.job;
    if (!job || typeof job !== 'object' || !job.id) return null;
    if (job.status && job.status !== 'running') return null;
    return job;
  }

  function jobVerb(svc) {
    var job = liveJob(svc);
    var v = job && typeof job.action === 'string' ? job.action : 'deploy';
    return GERUND[v] ? v : 'deploy';
  }

  function controllable(svc) {
    var c = svc && svc.control;
    /* An older backend sends nothing: offer the buttons and let the server's
       refusal explain, never the other way round. */
    if (!c || typeof c !== 'object') return true;
    return c.controllable === true;
  }

  function lockReason(svc) {
    var c = svc && svc.control;
    var r = c && typeof c.reason === 'string' ? c.reason : '';
    return r ? r.charAt(0).toUpperCase() + r.slice(1) : '';
  }

  function hasUpdate(svc) {
    var u = svc && svc.updates;
    return !!(u && typeof u === 'object' && u.available === true);
  }

  function updateOffered(svc) {
    return hasUpdate(svc) && svc.updates.updatable !== false && controllable(svc);
  }

  function rss(svc) {
    return num(svc && svc.resources && svc.resources.rss_bytes);
  }

  function cpu(svc) {
    return num(svc && svc.resources && svc.resources.cpu_pct);
  }

  function parts(svc) {
    var p = svc && svc.resources && svc.resources.parts;
    if (!Array.isArray(p) || !p.length) return null;
    var up = 0;
    for (var i = 0; i < p.length; i++) if (p[i] && p[i].running) up++;
    return { up: up, total: p.length };
  }

  function lastUsed(svc) {
    var u = svc && svc.usage;
    return num(u && u.last_used);
  }

  /* Which section a row lives in. A degraded service (probe fails while its
     parts still run) is up in the sense that matters, so it sits with the
     running ones, flagged, where it will be seen. */
  function bucket(svc) {
    if (svc.state === 'active' || (svc.state === 'stopped' && svc.degraded)) return 'run';
    if (svc.state === 'stopped') return 'stop';
    return 'fresh';
  }

  function glyphKind(svc) {
    if (liveJob(svc)) return 'busy';
    if (svc.state === 'stopped' && svc.degraded) return 'bad';
    if (svc.state === 'active') {
      var p = parts(svc);
      return p && p.up < p.total ? 'part' : 'ok';
    }
    if (svc.state === 'stopped') return 'ring';
    if (svc.state === 'planned') return 'dash';
    return 'dots';
  }

  /* The one visible button on a row. Everything else is in the ⋯ menu. */
  function primary(svc) {
    if (liveJob(svc)) return { id: 'watch', label: 'View log' };
    if (svc.state === 'stopped' && svc.degraded) {
      return controllable(svc) ? { id: 'restart', label: 'Restart' } : null;
    }
    if (svc.state === 'active') return svc.url ? { id: 'open', label: 'Open' } : null;
    if (svc.state === 'stopped') return controllable(svc) ? { id: 'start', label: 'Start' } : null;
    if (svc.state === 'available') return { id: 'deploy', label: 'Install' };
    return null;
  }

  function menuItems(svc) {
    var items = [];
    var up = svc.state === 'active' || (svc.state === 'stopped' && svc.degraded);
    var locked = !controllable(svc);
    var why = locked ? lockReason(svc) : '';
    if (liveJob(svc)) {
      items.push({ id: 'watch', label: 'View ' + GERUND[jobVerb(svc)].toLowerCase() + ' log', icon: 'log', key: '↵' });
      items.push('-');
      items.push({ id: 'details', label: 'Details and settings', icon: 'info', key: 'D' });
      return items;
    }
    if (up) {
      if (svc.url) {
        items.push({ id: 'open', label: 'Open in new tab', icon: 'open', key: '↵' });
        items.push({ id: 'copy', label: 'Copy address', icon: 'copy', key: 'C' });
        items.push('-');
      }
      if (hasUpdate(svc)) items.push({ id: 'update', label: 'Update', icon: 'up', key: 'U', off: !updateOffered(svc) });
      items.push({ id: 'restart', label: 'Restart', icon: 'restart', key: 'R', off: locked });
      items.push({ id: 'stop', label: 'Stop', icon: 'stop', key: 'S', danger: true, off: locked, why: why });
    } else if (svc.state === 'stopped') {
      items.push({ id: 'start', label: 'Start', icon: 'play', key: '↵', off: locked, why: why });
      if (hasUpdate(svc)) items.push({ id: 'update', label: 'Update', icon: 'up', key: 'U', off: !updateOffered(svc) });
    } else if (svc.state === 'available') {
      items.push({ id: 'deploy', label: 'Install', icon: 'down', key: '↵' });
    }
    items.push({ id: 'pin', label: svc.pinned === true ? 'Unpin from top' : 'Pin to top', icon: 'pin', key: 'P' });
    items.push({ id: 'hide', label: svc.user_hidden === true ? 'Show app' : 'Hide app',
                 icon: svc.user_hidden === true ? 'eye' : 'eyeoff', key: 'H' });
    /* Hidden is sorted by name — a manual move there is a silent no-op. */
    if (svc.user_hidden !== true) {
      items.push({ id: 'move-up', label: 'Move up', icon: 'up', key: 'K' });
      items.push({ id: 'move-down', label: 'Move down', icon: 'down', key: 'J' });
    }
    if (items.length) items.push('-');
    items.push({ id: 'details', label: svc.state === 'available' || svc.state === 'planned'
      ? 'About this app' : 'Details and settings', icon: 'info', key: 'D' });
    if (svc.removable === true && !locked) {
      items.push({ id: 'remove', label: 'Remove', icon: 'trash', key: 'X', danger: true });
    }
    return items;
  }

  /* ---------- filtering and ordering ---------- */

  function groupLabel(id) {
    var a = app();
    var gs = (a && typeof a.groups === 'function') ? a.groups() : [];
    for (var i = 0; i < gs.length; i++) if (gs[i].id === id) return gs[i].label || '';
    return '';
  }

  function matches(svc) {
    if (state.group === 'updates' && !hasUpdate(svc)) return false;
    if (state.group !== 'all' && state.group !== 'updates' && svc.group !== state.group) return false;
    var q = state.q.trim().toLowerCase();
    if (!q) return true;
    var hay = [svc.name, svc.tagline, svc.key, svc.author, groupLabel(svc.group)]
      .join(' ').toLowerCase();
    var words = q.split(/\s+/);
    for (var i = 0; i < words.length; i++) {
      if (words[i] && hay.indexOf(words[i]) === -1) return false;
    }
    return true;
  }

  /* Rank map for the user's explicit arrangement (overrides.json's order
     list, served on the payload). Keys with no rank sort to the end, so a
     newly installed app still appears after the arranged ones. */
  function ranks() {
    var out = {};
    var ord = (app() && typeof app().order === 'function') ? app().order() : [];
    for (var i = 0; i < ord.length; i++) out[ord[i]] = i;
    return out;
  }

  /* Infinity, not a missing-key NaN: `undefined - undefined` in a
     comparator is undefined behaviour the sort does not deserve. */
  function rankOf(rank, key) {
    var i = rank[key];
    return i === undefined ? Infinity : i;
  }

  function sortRun(rows, rank) {
    var k = state.sort.key, d = state.sort.dir;
    var val = {
      ram:  function (s) { var v = rss(s); return v === null ? -1 : v; },
      cpu:  function (s) { var v = cpu(s); return v === null ? -1 : v; },
      used: function (s) { var v = lastUsed(s); return v === null ? 0 : v; },
      custom: function (s) { return rankOf(rank, s.key); }
    }[k];
    return rows.sort(function (a, b) {
      if (k === 'name') return String(a.name || a.key).localeCompare(String(b.name || b.key)) * d;
      var x = val(a), y = val(b);
      if (x === y) return String(a.name || a.key).localeCompare(String(b.name || b.key));
      return (x - y) * (k === 'custom' ? 1 : d);
    });
  }

  /* The four buckets, in paint order: the explicit pinned shelf first,
     then running / stopped / not-installed by state. `filtered` applies the
     search/group filter; orderBase() wants every key for a complete stored
     permutation, so it calls this unfiltered. */
  function partition(all, filtered, rank) {
    var pinned = [], run = [], stop = [], fresh = [];
    for (var i = 0; i < all.length; i++) {
      var s = all[i];
      if (filtered && !matches(s)) continue;
      if (s.pinned === true) { pinned.push(s); continue; }
      var b = bucket(s);
      if (b === 'run') run.push(s);
      else if (b === 'stop') stop.push(s);
      else fresh.push(s);
    }
    sortRun(pinned, rank);
    sortRun(run, rank);
    if (state.sort.key === 'custom') {
      stop.sort(function (a, b) { return rankOf(rank, a.key) - rankOf(rank, b.key) ||
        String(a.name || a.key).localeCompare(String(b.name || b.key)); });
      fresh.sort(function (a, b) { return rankOf(rank, a.key) - rankOf(rank, b.key) ||
        String(a.name || a.key).localeCompare(String(b.name || b.key)); });
    } else {
      stop.sort(function (a, b) { return (lastUsed(b) || 0) - (lastUsed(a) || 0); });
      fresh.sort(function (a, b) {
        /* installable first, then planned */
        return (a.state === 'planned') - (b.state === 'planned') ||
               String(a.name || a.key).localeCompare(String(b.name || b.key));
      });
    }
    return { pinned: pinned, run: run, stop: stop, fresh: fresh };
  }

  function sections() {
    var p = partition(list(), true, ranks());
    p.hid = hiddenList().filter(matches);
    return p;
  }

  /* Every key the page would paint with no filter, in paint order — the
     base a drag edits, so keys hidden by the search box keep their place
     rather than being silently dropped from the stored order. */
  function orderBase() {
    var s = partition(list(), false, ranks());
    return s.pinned.concat(s.run, s.stop, s.fresh).map(function (x) { return x.key; });
  }

  function order() {
    var s = sections();
    return s.pinned.concat(s.run,
            state.fold.stop ? [] : s.stop,
            state.fold.fresh ? [] : s.fresh,
            state.fold.hidden ? [] : s.hid)
            .map(function (x) { return x.key; });
  }

  function find(key) {
    var all = everything();
    for (var i = 0; i < all.length; i++) if (all[i].key === key) return all[i];
    return null;
  }

  /* ---------- building the static frame ---------- */

  function build() {
    if (built) return;
    built = true;

    var head = make('div', 'h-head');
    var titles = make('div', 'h-titles');
    titles.appendChild(make('h2', 'h-title', 'Apps'));
    els.sub = make('p', 'h-sub', 'Start, stop and open everything installed on this box.');
    titles.appendChild(els.sub);
    head.appendChild(titles);
    var add = make('a', 'h-btn h-btn-accent');
    add.href = '#/catalogue';
    add.appendChild(svg(['M12 5v14', 'M5 12h14'], { width: '2.2' }));
    add.appendChild(make('span', null, 'Add app'));
    head.appendChild(add);
    root.appendChild(head);

    els.alert = make('div', 'h-alert');
    els.alert.setAttribute('role', 'status');
    els.alert.hidden = true;
    root.appendChild(els.alert);

    els.health = make('section', 'h-health');
    els.health.setAttribute('aria-label', 'Server health');
    root.appendChild(els.health);

    var panel = make('section', 'h-panel');
    panel.setAttribute('aria-label', 'Apps');

    var bar = make('label', 'h-search');
    bar.setAttribute('for', 'h-q');
    bar.appendChild(svg(ICON.search));
    var sr = make('span', 'sr-only', 'Search apps');
    bar.appendChild(sr);
    els.q = make('input');
    els.q.id = 'h-q';
    els.q.type = 'search';
    els.q.placeholder = 'Search apps';
    els.q.autocomplete = 'off';
    els.q.spellcheck = false;
    els.q.setAttribute('autocapitalize', 'off');
    els.q.setAttribute('enterkeyhint', 'go');
    els.q.addEventListener('input', function () {
      state.q = els.q.value;
      paintList();
      paintPills();
    });
    bar.appendChild(els.q);
    var kbd = make('kbd', 'h-kbd', '/');
    kbd.setAttribute('aria-hidden', 'true');
    bar.appendChild(kbd);
    panel.appendChild(bar);

    els.pills = make('div', 'h-pills');
    els.pills.setAttribute('role', 'group');
    els.pills.setAttribute('aria-label', 'Filter by category');
    panel.appendChild(els.pills);

    /* id="grid" keeps tooltip.js's description bubble working: it reads
       `#grid` and the data-key on each row, nothing else. */
    els.list = make('div', 'h-list');
    els.list.id = 'grid';
    panel.appendChild(els.list);
    bindDnd();
    root.appendChild(panel);

    root.addEventListener('click', onClick);
    root.addEventListener('dblclick', function (e) {
      var row = e.target.closest ? e.target.closest('[data-key]') : null;
      if (!row || e.target.closest('a, button')) return;
      runPrimary(row.getAttribute('data-key'), row);
    });
  }

  /* ---------- painting ---------- */

  function paint() {
    build();
    /* First contact with a saved arrangement: adopt it as the sort — the
       stored order IS the user's earlier choice, so a fresh browser
       paints it rather than the ram fallback. A click on a sort header
       stores a preference and this never fires again. */
    if (!orderAdopted && stored(SORT_STORE, null) === null) {
      var ord = (app() && typeof app().order === 'function') ? app().order() : [];
      if (ord.length) { state.sort = { key: 'custom', dir: 1 }; orderAdopted = true; }
    }
    paintAlert();
    paintHealth();
    paintPills();
    paintList();
    paintSide();
    paintBar();
  }

  function sys() {
    var a = app();
    return (a && typeof a.system === 'function') ? a.system() : null;
  }

  function diskShare(d) {
    if (!d) return null;
    var used = num(d.used), free = num(d.free);
    if (used === null || free === null || used + free <= 0) return null;
    /* df's own arithmetic: reserved blocks are in neither column. */
    return used / (used + free);
  }

  function paintAlert() {
    var d = sys() && sys().disk;
    var share = diskShare(d);
    els.alert.textContent = '';
    if (share === null || share < DISK_CRIT) { els.alert.hidden = true; return; }
    els.alert.hidden = false;
    els.alert.appendChild(svg(ICON.warn));
    var p = make('p');
    p.appendChild(make('strong', null, 'Disk is ' + Math.round(share * 100) + '% full.'));
    p.appendChild(document.createTextNode(' ' + fmtBytes(d.free) + ' left on ' + (d.mount || '/') +
      '. New deploys and image pulls may fail until you free space.'));
    els.alert.appendChild(p);
  }

  function meter(fills) {
    var m = make('div', 'h-meter');
    m.setAttribute('aria-hidden', 'true');
    for (var i = 0; i < fills.length; i++) {
      var f = make('i', fills[i].cls);
      f.style.width = Math.max(0, Math.min(100, fills[i].pct)).toFixed(1) + '%';
      m.appendChild(f);
    }
    return m;
  }

  function cell(label, flag, value, unit, extra, sub, tone, corner) {
    var c = make('div', 'h-cell' + (tone ? ' is-' + tone : ''));
    var k = make('div', 'h-k');
    k.appendChild(make('span', null, label));
    if (flag || corner) {
      var side = make('span', 'h-k-side');
      if (flag) side.appendChild(make('b', null, flag));
      if (corner) side.appendChild(corner);
      k.appendChild(side);
    }
    c.appendChild(k);
    var v = make('div', 'h-v');
    v.appendChild(document.createTextNode(value));
    if (unit) v.appendChild(make('span', null, unit));
    c.appendChild(v);
    if (extra) c.appendChild(extra);
    if (sub) c.appendChild(make('div', 'h-s', sub));
    return c;
  }

  function paintHealth() {
    var a = app();
    var ready = a && a.loaded() && !a.error();
    els.health.textContent = '';
    var all = list();
    var nRun = 0, nStop = 0, nNew = 0, appMem = 0, seen = false;
    for (var i = 0; i < all.length; i++) {
      var b = bucket(all[i]);
      if (b === 'run') nRun++;
      else if (b === 'stop') nStop++;
      else nNew++;
      if (b === 'run' && rss(all[i]) !== null) { appMem += rss(all[i]); seen = true; }
    }
    var total = all.length || 1;

    /* Apps */
    els.health.appendChild(cell('Apps', null,
      ready ? String(nRun) : '…', ready ? 'of ' + all.length + ' running' : '',
      meter([{ cls: 'ok', pct: nRun / total * 100 }, { cls: 'off', pct: nStop / total * 100 }]),
      ready ? nStop + ' stopped · ' + nNew + ' not installed' : ' '));

    var s = sys();
    /* Memory */
    var mem = s && s.memory;
    var mt = mem && num(mem.total), ma = mem && num(mem.available);
    if (mt && ma !== null) {
      var used = mt - ma;
      var tight = ma / mt < MEM_WARN;
      els.health.appendChild(cell('Memory', tight ? 'Tight' : null,
        fmtBytes(used), 'of ' + fmtBytes(mt),
        meter([{ cls: tight ? 'warn' : 'n', pct: used / mt * 100 }]),
        seen ? 'Apps use ' + fmtBytes(appMem) : fmtBytes(ma) + ' available',
        tight ? 'warn' : null));
    } else {
      els.health.appendChild(cell('Memory', null, '–', mt ? 'of ' + fmtBytes(mt) : '', null,
        seen ? 'Apps use ' + fmtBytes(appMem) : 'Not reported on this platform'));
    }

    /* Disk: the ⓘ opens the storage sheet, what is on it per app and
       per bucket, from api/disk. */
    var d = s && s.disk;
    var share = diskShare(d);
    var info = make('button', 'h-info');
    info.type = 'button';
    info.setAttribute('data-disk-info', '1');
    info.setAttribute('aria-label', 'What is using this disk');
    info.title = 'What is using this disk';
    info.appendChild(svg(ICON.info, { width: '2.2' }));
    if (share !== null) {
      var tone = share >= DISK_CRIT ? 'bad' : (share >= DISK_WARN ? 'warn' : null);
      els.health.appendChild(cell('Disk ' + (d.mount || '/'),
        tone === 'bad' ? 'Critical' : (tone === 'warn' ? 'Filling up' : null),
        Math.round(share * 100) + '%', 'full',
        meter([{ cls: tone || 'n', pct: share * 100 }]),
        fmtBytes(d.free) + ' free of ' + fmtBytes(d.total), tone, info));
    } else {
      els.health.appendChild(cell('Disk', null, '–', '', null,
        ready ? 'Not reported' : ' ', null, info));
    }

    /* CPU load */
    var load = s && Array.isArray(s.load) ? s.load : null;
    var cpus = s && num(s.cpus);
    var c = cell('CPU load', null,
      load ? String(load[0]) : '–', cpus ? 'on ' + cpus + ' cores' : '',
      null, fmtUptime(s && s.uptime_s) || (ready ? ' ' : ' '),
      load && cpus && load[0] > cpus ? 'warn' : null);
    if (load) {
      var row = make('div', 'h-loads');
      row.appendChild(make('span', null, '5 min ')).appendChild(make('b', null, String(load[1])));
      row.appendChild(make('span', null, '15 min ')).appendChild(make('b', null, String(load[2])));
      c.insertBefore(row, c.lastChild);
    }
    els.health.appendChild(c);
  }

  function paintPills() {
    var a = app();
    var gs = (a && typeof a.groups === 'function') ? a.groups() : [];
    var all = list();
    var ids = ['all'], labels = { all: 'All' };
    for (var i = 0; i < gs.length; i++) { ids.push(gs[i].id); labels[gs[i].id] = gs[i].label; }
    var nUpd = all.filter(hasUpdate).length;
    if (nUpd || state.group === 'updates') { ids.push('updates'); labels.updates = 'Updates'; }
    if (ids.indexOf(state.group) === -1) state.group = 'all';

    var keep = document.activeElement && document.activeElement.getAttribute &&
               document.activeElement.getAttribute('data-pill');
    els.pills.textContent = '';
    for (var j = 0; j < ids.length; j++) {
      var id = ids[j];
      var n = id === 'all' ? all.length
        : id === 'updates' ? nUpd
        : all.filter(function (s) { return s.group === id; }).length;
      var b = make('button', 'h-pill' + (id === 'updates' ? ' is-upd' : ''));
      b.type = 'button';
      b.setAttribute('data-pill', id);
      b.setAttribute('aria-pressed', state.group === id ? 'true' : 'false');
      b.appendChild(document.createTextNode(labels[id] + ' '));
      b.appendChild(make('span', 'h-n', n));
      els.pills.appendChild(b);
      if (keep === id) b.focus({ preventScroll: true });
    }
  }

  function focusId() {
    var el = document.activeElement;
    return el && el.getAttribute ? el.getAttribute('data-fid') : null;
  }

  function sortHead() {
    var h = make('div', 'h-cols');
    h.setAttribute('aria-hidden', 'false');
    function btn(key, label, cls) {
      var wrap = make('span', cls || '');
      var b = make('button', 'h-sort');
      b.type = 'button';
      b.setAttribute('data-sort', key);
      b.setAttribute('data-fid', 'sort:' + key);
      var on = state.sort.key === key;
      b.setAttribute('aria-label', 'Sort by ' + label.toLowerCase() +
        (on ? (state.sort.dir < 0 ? ', descending' : ', ascending') : ''));
      if (on) b.setAttribute('aria-current', 'true');
      b.appendChild(document.createTextNode(label));
      if (on) b.appendChild(svg([state.sort.dir < 0 ? 'm7 10 5 5 5-5' : 'm7 14 5-5 5 5'], { width: '2.2' }));
      wrap.appendChild(b);
      return wrap;
    }
    h.appendChild(btn('name', 'App'));
    h.appendChild(make('span', 'h-c-parts', 'Parts'));
    h.appendChild(btn('ram', 'Memory'));
    h.appendChild(btn('cpu', 'CPU', 'h-c-cpu h-r'));
    h.appendChild(btn('used', 'Last used', 'h-c-last'));
    var tail = make('span', 'h-r');
    tail.appendChild(btn('custom', 'Yours'));
    h.appendChild(tail);
    return h;
  }

  function groupHead(id, kind, label, count, note) {
    var foldable = id === 'stop' || id === 'fresh' || id === 'hidden';
    var h = make(foldable ? 'button' : 'div', 'h-group');
    if (foldable) {
      h.type = 'button';
      h.setAttribute('data-fold', id);
      h.setAttribute('data-fid', 'fold:' + id);
      h.setAttribute('aria-expanded', state.fold[id] ? 'false' : 'true');
    }
    h.appendChild(glyph(kind));
    h.appendChild(make('span', 'h-g-label', label));
    h.appendChild(make('span', 'h-g-n', count));
    if (note) h.appendChild(make('span', 'h-g-note', note));
    if (foldable) {
      var car = make('span', 'h-g-car');
      car.appendChild(svg(ICON.caret, { width: '2' }));
      h.appendChild(car);
    }
    return h;
  }

  /* A foldable section's rows, always painted inside an animated wrapper:
     folding is a class toggle, not a rebuild, so the grid-rows transition
     can run and folded content stays put for the next expand. `inert` keeps
     the collapsed rows out of the tab order and off the click path. */
  function foldBox(id, rows, maxRam) {
    var box = make('div', 'h-fold' + (state.fold[id] ? ' is-folded' : ''));
    box.setAttribute('data-foldbox', id);
    if (state.fold[id]) {
      box.setAttribute('inert', '');
      box.setAttribute('aria-hidden', 'true');
    }
    var inner = make('div', 'h-fold-in');
    rows.forEach(function (x) { inner.appendChild(row(x, maxRam)); });
    box.appendChild(inner);
    return box;
  }

  function row(svc, maxRam) {
    var key = svc.key;
    var job = liveJob(svc);
    var b = bucket(svc);
    var r = make('div', 'h-row' + (b !== 'run' || svc.user_hidden === true ? ' is-dim' : '') +
                        (job ? ' is-busy' : '') +
                        (hasUpdate(svc) ? ' has-upd' : '') + (state.sel === key ? ' is-sel' : ''));
    r.setAttribute('data-key', key);
    if (state.sel === key) r.setAttribute('aria-current', 'true');

    /* app column */
    var appc = make('div', 'h-app');
    appc.appendChild(glyph(glyphKind(svc)));
    /* The grip is the only draggable handle: making the whole row draggable
       would break text selection and the name link's own drag. Shelved rows
       get none — the Hidden section is sorted by name, so a drag would look
       like it did nothing. */
    if (svc.user_hidden !== true) {
      var grip = make('span', 'h-grip');
      grip.draggable = true;
      grip.setAttribute('data-grip', key);
      grip.title = 'Drag to reorder';
      grip.appendChild(svg(ICON.grip, { width: '2.6' }));
      appc.appendChild(grip);
    }
    var ic = make('span', 'h-ic');
    ic.appendChild(iconNode(svc));
    appc.appendChild(ic);
    var names = make('div', 'h-names');
    var name = make('a', 'h-name', svc.name || key);
    name.href = '#/service/' + encodeURIComponent(key);
    name.setAttribute('data-detail', key);
    name.setAttribute('data-fid', 'detail:' + key);
    names.appendChild(name);
    if (svc.tagline) names.appendChild(make('span', 'h-tag', svc.tagline));
    appc.appendChild(names);
    if (svc.state === 'stopped' && svc.degraded) {
      appc.appendChild(make('span', 'h-flag is-bad', 'Not responding'));
    } else if (hasUpdate(svc)) {
      var u = make('span', 'h-flag is-upd', 'Update');
      u.title = 'A newer image is published for this app’s tag';
      appc.appendChild(u);
    }
    if (!controllable(svc) && (svc.state === 'active' || svc.state === 'stopped')) {
      var lock = make('span', 'h-flag is-lock');
      lock.appendChild(svg(ICON.lock, { width: '1.8' }));
      lock.appendChild(make('span', null, 'Locked'));
      lock.title = lockReason(svc);
      appc.appendChild(lock);
    }
    var pin = make('button', 'h-pin' + (svc.pinned === true ? ' is-on' : ''));
    pin.type = 'button';
    pin.setAttribute('data-pin', key);
    pin.setAttribute('data-fid', 'pin:' + key);
    pin.setAttribute('aria-pressed', svc.pinned === true ? 'true' : 'false');
    pin.setAttribute('aria-label', (svc.pinned === true ? 'Unpin ' : 'Pin ') + (svc.name || key));
    pin.title = svc.pinned === true ? 'Unpin from top' : 'Pin to top';
    pin.appendChild(svg(ICON.pin, { width: '1.9' }));
    appc.appendChild(pin);
    var hid = svc.user_hidden === true;
    var eye = make('button', 'h-eye' + (hid ? ' is-on' : ''));
    eye.type = 'button';
    eye.setAttribute('data-hide', key);
    eye.setAttribute('data-fid', 'hide:' + key);
    eye.setAttribute('aria-pressed', hid ? 'true' : 'false');
    eye.setAttribute('aria-label', (hid ? 'Show ' : 'Hide ') + (svc.name || key));
    eye.title = hid ? 'Show in the list' : 'Hide from the list';
    eye.appendChild(svg(hid ? ICON.eyeoff : ICON.eye, { width: '1.9' }));
    appc.appendChild(eye);
    r.appendChild(appc);

    /* parts */
    var p = parts(svc);
    r.appendChild(make('div', 'h-c h-c-parts h-tn',
      b === 'run' && p ? p.up + '/' + p.total : ''));

    /* memory, or the line that stands in for it */
    var mem = make('div', 'h-c h-c-mem');
    if (job) {
      mem.appendChild(make('span', 'h-busy', GERUND[jobVerb(svc)] + '…'));
    } else if (b === 'run') {
      var n = rss(svc);
      if (n !== null) {
        var bar = make('div', 'h-bar');
        var fill = make('i');
        fill.style.width = Math.max(2, n / maxRam * 100).toFixed(1) + '%';
        bar.appendChild(fill);
        mem.appendChild(bar);
        mem.appendChild(make('span', 'h-mb h-tn', fmtBytes(n)));
      } else {
        var na = make('span', 'h-na', 'not sampled');
        na.title = 'No container or cgroup the launcher can measure';
        mem.appendChild(na);
      }
    } else if (b === 'stop') {
      var lu = lastUsed(svc);
      mem.appendChild(make('span', 'h-na', lu ? 'used ' + ago(lu) : 'never used'));
    } else if (svc.state === 'planned') {
      mem.appendChild(make('span', 'h-na', 'setup script not written yet'));
    } else {
      mem.appendChild(make('span', 'h-na', p ? p.total + (p.total === 1 ? ' container' : ' containers') : 'ready to install'));
    }
    r.appendChild(mem);

    r.appendChild(make('div', 'h-c h-c-cpu h-r h-tn', b === 'run' ? (fmtPct(cpu(svc)) || '') : ''));
    r.appendChild(make('div', 'h-c h-c-last', b === 'run' ? ago(lastUsed(svc)) || 'never' : ''));

    /* actions */
    var acts = make('div', 'h-acts');
    var pri = primary(svc);
    if (svc.state === 'planned') {
      acts.appendChild(make('span', 'h-badge', 'Planned'));
    } else {
      if (pri && pri.id === 'open') {
        var o = make('a', 'h-btn h-pri');
        o.href = svc.url;
        o.target = '_blank';
        o.rel = 'noopener noreferrer';
        o.setAttribute('data-act', 'open');
        o.setAttribute('data-k', key);
        o.setAttribute('data-fid', 'act:' + key);
        o.setAttribute('aria-label', 'Open ' + (svc.name || key) + ' in a new tab');
        o.appendChild(make('span', null, 'Open'));
        acts.appendChild(o);
      } else if (pri) {
        var pb = make('button', 'h-btn h-pri');
        pb.type = 'button';
        pb.setAttribute('data-act', pri.id);
        pb.setAttribute('data-k', key);
        pb.setAttribute('data-fid', 'act:' + key);
        pb.setAttribute('aria-label', pri.label + ' ' + (svc.name || key));
        pb.appendChild(make('span', null, pri.label));
        acts.appendChild(pb);
      } else {
        acts.appendChild(make('span', 'h-noui', svc.state === 'active' && !svc.url ? 'No web UI' : ''));
      }
      if (acts.firstChild && acts.firstChild.classList.contains('h-pri')) {
        var k = make('kbd', 'h-enter', '↵');
        k.setAttribute('aria-hidden', 'true');
        acts.firstChild.appendChild(k);
      }
      var more = make('button', 'h-btn h-more');
      more.type = 'button';
      more.setAttribute('data-menu', key);
      more.setAttribute('data-fid', 'menu:' + key);
      more.setAttribute('aria-haspopup', 'menu');
      more.setAttribute('aria-expanded', state.menu === key ? 'true' : 'false');
      more.setAttribute('aria-label', 'More actions for ' + (svc.name || key));
      more.appendChild(svg(['M6 12h.01', 'M12 12h.01', 'M18 12h.01'], { width: '3' }));
      acts.appendChild(more);
    }
    r.appendChild(acts);
    return r;
  }

  function skeletonRows() {
    var f = document.createDocumentFragment();
    for (var i = 0; i < 7; i++) {
      var r = make('div', 'h-row h-skel');
      r.setAttribute('aria-hidden', 'true');
      r.appendChild(make('span', 'sk sk-a'));
      r.appendChild(make('span', 'sk sk-b'));
      f.appendChild(r);
    }
    return f;
  }

  function paintList() {
    var a = app();
    /* A poll that rebuilt the rows mid-drag would strand the gesture and
       eat the drop; wait for the next paint instead. */
    if (dragKey) return;
    var fid = focusId();
    els.list.textContent = '';

    if (!a || !a.loaded()) {
      els.list.setAttribute('aria-busy', 'true');
      els.list.appendChild(skeletonRows());
      return;
    }
    els.list.setAttribute('aria-busy', 'false');
    /* Shelved rows count here too: with every app hidden the Hidden
       section is the only way back, so it must still paint. */
    if (!list().length && !hiddenList().length) return;   // app.js's notice explains an empty list

    var s = sections();
    var keys = order();
    if (keys.indexOf(state.sel) === -1) state.sel = keys.length ? keys[0] : null;

    if (!s.pinned.length && !s.run.length && !s.stop.length && !s.fresh.length && !s.hid.length) {
      els.list.appendChild(emptyState());
      paintBar();
      return;
    }

    var maxRam = 1;
    list().forEach(function (x) { var v = rss(x); if (v !== null && bucket(x) === 'run' && v > maxRam) maxRam = v; });

    if (s.pinned.length) {
      els.list.appendChild(groupHead('pinned', 'pin', 'Pinned', s.pinned.length));
      s.pinned.forEach(function (x) { els.list.appendChild(row(x, maxRam)); });
    }
    if (s.run.length) {
      els.list.appendChild(groupHead('run', 'ok', 'Running', s.run.length));
      els.list.appendChild(sortHead());
      s.run.forEach(function (x) { els.list.appendChild(row(x, maxRam)); });
    }
    if (s.stop.length) {
      els.list.appendChild(groupHead('stop', 'ring', 'Stopped', s.stop.length, 'Most recently used first'));
      els.list.appendChild(foldBox('stop', s.stop, maxRam));
    }
    if (s.fresh.length) {
      els.list.appendChild(groupHead('fresh', 'dots', 'Not installed', s.fresh.length));
      els.list.appendChild(foldBox('fresh', s.fresh, maxRam));
    }
    if (s.hid.length) {
      els.list.appendChild(groupHead('hidden', 'hid', 'Hidden', s.hid.length));
      els.list.appendChild(foldBox('hidden', s.hid, maxRam));
    }

    /* A poll repaints every row; put focus back where it was. */
    if (fid) {
      var back = els.list.querySelector('[data-fid="' + fid.replace(/"/g, '') + '"]');
      if (back) { try { back.focus({ preventScroll: true }); } catch (e) { back.focus(); } }
    }
    if (state.menu && menuEl) {
      var anchor = els.list.querySelector('[data-menu="' + state.menu + '"]');
      if (anchor) anchor.setAttribute('aria-expanded', 'true');
    }
    /* A search or filter can move the selection; the bar must name the same
       app the highlight does, or its button acts on the wrong one. */
    paintBar();
  }

  function emptyState() {
    var box = make('div', 'h-empty');
    var ic = make('span', 'h-empty-ic');
    ic.appendChild(svg(ICON.search));
    box.appendChild(ic);
    var q = state.q.trim();
    box.appendChild(make('strong', null, q ? 'No app matches “' + q + '”' : 'Nothing in this category'));
    box.appendChild(make('span', null, q
      ? 'Check the spelling, or look for it in the catalogue.'
      : 'Pick another category, or add an app from the catalogue.'));
    var clear = make('button', 'h-link', 'Clear search and filters');
    clear.type = 'button';
    clear.setAttribute('data-clear', '1');
    box.appendChild(clear);
    return box;
  }

  /* ---------- sidebar, breadcrumb, action bar ---------- */

  function route() {
    var h = String(location.hash || '');
    var m = /^#\/service\/(.+)$/.exec(h);
    if (m) {
      var key;
      try { key = decodeURIComponent(m[1]); } catch (e) { key = m[1]; }
      return { page: 'service', key: key };
    }
    if (h === '#/catalogue') return { page: 'catalogue' };
    if (h === '#/deploys') return { page: 'deploys' };
    return { page: 'home' };
  }

  function paintSide() {
    var a = app();
    var all = list();
    var r = route();
    var host = a && typeof a.host === 'function' ? a.host() : '';

    var links = document.querySelectorAll('.side .nav-link[data-nav]');
    for (var i = 0; i < links.length; i++) {
      var nav = links[i].getAttribute('data-nav');
      var on = (nav === 'home' && r.page === 'home') ||
               (nav === 'catalogue' && r.page === 'catalogue') ||
               (nav === 'deploys' && r.page === 'deploys');
      if (on) links[i].setAttribute('aria-current', 'page');
      else links[i].removeAttribute('aria-current');
    }

    var ctApps = $('nav-ct-apps');
    if (ctApps) ctApps.textContent = all.length ? String(all.length) : '';
    var ctCat = $('nav-ct-cat');
    if (ctCat) {
      var installable = all.filter(function (s) { return s.state === 'available'; }).length;
      ctCat.textContent = installable ? String(installable) : '';
      ctCat.title = installable ? installable + ' ready to install' : '';
    }
    var dep = $('nav-deployd');
    if (dep) dep.hidden = !find('deployd');

    var watch = $('nav-watch');
    if (watch) {
      while (watch.children.length > 1) watch.removeChild(watch.lastElementChild);
      var n = 0;
      for (var w = 0; w < WATCH.length; w++) {
        var svc = find(WATCH[w]);
        if (!svc || svc.state !== 'active' || !svc.url) continue;
        var link = make('a', 'nav-link nav-ext');
        link.href = svc.url;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.title = (svc.name || svc.key) + ' (opens in a new tab)';
        var ic = make('span', 'nav-ic');
        ic.appendChild(iconNode(svc));
        link.appendChild(ic);
        link.appendChild(make('span', 'nav-label', svc.name || svc.key));
        var ex = svg(ICON.ext, { width: '2' });
        ex.setAttribute('class', 'nav-exti');
        link.appendChild(ex);
        watch.appendChild(link);
        n++;
      }
      watch.hidden = n === 0;
    }

    var crumbHost = $('crumb-host');
    if (crumbHost) crumbHost.textContent = host || '';
    var now = $('crumb-now');
    if (now) {
      if (r.page === 'catalogue') now.textContent = 'Catalogue';
      else if (r.page === 'deploys') now.textContent = 'Deploys';
      else if (r.page === 'service') {
        var sv = find(r.key);
        now.textContent = sv ? (sv.name || sv.key) : r.key;
      } else now.textContent = 'Apps';
    }
  }

  function homeShown() {
    var g = $('view-grid');
    return !!g && !g.hidden && route().page === 'home';
  }

  function sheetOpen() {
    var s = $('sheet');
    return !!s && !s.hidden;
  }

  function paintBar() {
    var bar = $('abar');
    if (!bar) return;
    var svc = state.sel ? find(state.sel) : null;
    if (!svc || !homeShown()) { bar.hidden = true; return; }
    bar.hidden = false;
    var who = $('abar-who');
    var grp = $('abar-grp');
    var had = grp.contains(document.activeElement) ? document.activeElement.getAttribute('data-bar') : null;
    who.textContent = '';
    who.appendChild(glyph(glyphKind(svc)));
    who.appendChild(make('span', 'abar-name', svc.name || svc.key));
    if (svc.tagline) who.appendChild(make('span', 'abar-tag', svc.tagline));
    grp.textContent = '';
    var pri = primary(svc);
    if (pri) {
      var b = make('button', 'abar-btn');
      b.type = 'button';
      b.setAttribute('data-bar', 'primary');
      b.appendChild(make('span', null, pri.label));
      b.appendChild(make('kbd', null, '↵'));
      grp.appendChild(b);
      grp.appendChild(make('span', 'abar-sep'));
    }
    if (svc.state !== 'planned') {
      var m = make('button', 'abar-btn');
      m.type = 'button';
      m.setAttribute('data-bar', 'menu');
      m.appendChild(make('span', null, 'Actions'));
      m.appendChild(make('kbd', null, isMac() ? '⌘' : 'Ctrl'));
      m.appendChild(make('kbd', null, 'K'));
      grp.appendChild(m);
    }
    if (had) {
      var back = grp.querySelector('[data-bar="' + had + '"]');
      if (back) { try { back.focus({ preventScroll: true }); } catch (e) { back.focus(); } }
    }
  }

  function isMac() {
    return /Mac|iPhone|iPad/.test(String(navigator.platform || navigator.userAgent || ''));
  }

  function select(key, scroll) {
    state.sel = key;
    var rows = els.list ? els.list.querySelectorAll('.h-row[data-key]') : [];
    for (var i = 0; i < rows.length; i++) {
      var on = rows[i].getAttribute('data-key') === key;
      rows[i].classList.toggle('is-sel', on);
      if (on) {
        rows[i].setAttribute('aria-current', 'true');
        if (scroll && rows[i].scrollIntoView) rows[i].scrollIntoView({ block: 'nearest' });
      } else rows[i].removeAttribute('aria-current');
    }
    paintBar();
  }

  /* ---------- actions ---------- */

  function runPrimary(key, opener) {
    var svc = find(key);
    if (!svc) return;
    var p = primary(svc);
    if (!p) { location.hash = '#/service/' + encodeURIComponent(key); return; }
    run(p.id, key, opener);
  }

  function run(id, key, opener) {
    var svc = find(key);
    var a = app();
    if (!svc || !a) return;
    if (id === 'open') {
      if (!svc.url) return;
      if (typeof a.touch === 'function') a.touch(key);
      window.open(svc.url, '_blank', 'noopener');
      return;
    }
    if (id === 'copy') { copy(svc.url, svc.name || key); return; }
    if (id === 'details') { location.hash = '#/service/' + encodeURIComponent(key); return; }
    if (id === 'watch') {
      var job = liveJob(svc);
      if (job && typeof a.watchJob === 'function') a.watchJob(key, String(job.id), jobVerb(svc), opener);
      return;
    }
    if (id === 'pin') { togglePin(key); return; }
    if (id === 'hide') { toggleHide(key); return; }
    if (id === 'move-up') { moveBy(key, -1); return; }
    if (id === 'move-down') { moveBy(key, 1); return; }
    if (typeof a.action === 'function' && !a.action(key, id, opener)) {
      toast(lockReason(svc) || 'That is not available for ' + (svc.name || key) + ' right now.');
    }
  }

  function copy(value, name) {
    if (!value) return;
    var done = function () { toast('Copied ' + name + '’s address'); };
    var fallback = function () {
      var ta = make('textarea');
      ta.value = value;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { toast('Could not copy. The address is ' + value); }
      document.body.removeChild(ta);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(done, fallback);
    } else fallback();
  }

  function toast(message) {
    var t = $('toast');
    if (!t) return;
    t.textContent = message;
    t.classList.add('is-on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.remove('is-on'); }, 2600);
  }

  /* ---------- pin and reorder ---------- */

  function togglePin(key) {
    var svc = find(key);
    var a = app();
    if (!svc || !a || typeof a.pin !== 'function') return;
    a.pin(key, svc.pinned !== true).then(function (ok) {
      if (!ok) toast('Could not save the pin for ' + (svc.name || key) + '.');
    });
  }

  function toggleHide(key) {
    var svc = find(key);
    var a = app();
    if (!svc || !a || typeof a.hide !== 'function') return;
    var showing = svc.user_hidden === true;
    a.hide(key, !showing).then(function (ok) {
      if (ok) {
        toast(showing ? (svc.name || key) + ' is back in the list.'
                      : (svc.name || key) + ' is under Hidden now.');
      } else {
        toast('Could not save that for ' + (svc.name || key) + '.');
      }
    });
  }

  /* Commit one move: dragKey lands next to targetKey in the stored order.
     orderBase() carries every key, so rows hidden by the search box keep
     their place rather than vanishing from the stored list. Arranging once
     switches the sort to 'custom' — the mode that reads the order back —
     and any later column click takes over from it again. */
  function commitMove(dragKey, targetKey, before) {
    if (dragKey === targetKey) return;
    var a = app();
    var base = orderBase();
    /* Saved keys absent from today's catalogue keep the rank they had —
       the API preserves unknown keys for services that come back, so
       each one is re-inserted at its old position rather than silently
       dropped by this save. */
    var saved = (a && typeof a.order === 'function') ? a.order() : [];
    for (var m = 0; m < saved.length; m++) {
      if (base.indexOf(saved[m]) === -1) {
        base.splice(Math.min(m, base.length), 0, saved[m]);
      }
    }
    var i = base.indexOf(dragKey);
    if (i !== -1) base.splice(i, 1);
    var j = targetKey ? base.indexOf(targetKey) : -1;
    base.splice(j === -1 ? base.length : j + (before ? 0 : 1), 0, dragKey);
    state.sort = { key: 'custom', dir: 1 };
    remember(SORT_STORE, 'custom:1');
    if (a && typeof a.saveOrder === 'function') {
      a.saveOrder(base).then(function (ok) {
        if (!ok) toast('Could not save the new order.');
      });
    }
    paintList();
    paintBar();
  }

  /* The menu's keyboard path for a drag: move one row within ITS section.
     Sections are filtered views over one global rank, so the swap is
     against the neighbour in the section, never across a boundary. */
  function moveBy(key, d) {
    var s = sections();
    var sects = ['pinned', 'run', 'stop', 'fresh'];
    for (var i = 0; i < sects.length; i++) {
      var arr = s[sects[i]];
      for (var j = 0; j < arr.length; j++) {
        if (arr[j].key !== key) continue;
        var n = j + d;
        if (n < 0 || n >= arr.length) return;
        commitMove(key, arr[n].key, d < 0);
        return;
      }
    }
  }

  /* ---------- drag to reorder ---------- */

  var dragKey = null, dropRow = null, dropBefore = true;

  /* The section a row paints under: the pinned shelf, or its state
     bucket. A drag only ever moves a row inside its own section — the
     keyboard path (moveBy) has the same boundary, and a marker anywhere
     else would promise a move commitMove cannot do. */
  function sectionOf(key) {
    var s = find(key);
    if (!s) return null;
    if (s.user_hidden === true) return 'hidden';
    return s.pinned === true ? 'pinned' : bucket(s);
  }

  function clearDrop() {
    if (!els.list) return;
    var marked = els.list.querySelectorAll('.h-row.is-drop-above, .h-row.is-drop-below');
    for (var i = 0; i < marked.length; i++) {
      marked[i].classList.remove('is-drop-above', 'is-drop-below');
    }
    dropRow = null;
  }

  function endDrag() {
    dragKey = null;
    if (els.list) {
      var marked = els.list.querySelectorAll('.h-row.is-drag');
      for (var i = 0; i < marked.length; i++) marked[i].classList.remove('is-drag');
    }
    clearDrop();
  }

  function onDragStart(e) {
    var grip = e.target.closest ? e.target.closest('.h-grip') : null;
    var row = e.target.closest ? e.target.closest('.h-row[data-key]') : null;
    if (!grip || !row) return;
    dragKey = row.getAttribute('data-key');
    row.classList.add('is-drag');
    try {
      e.dataTransfer.setData('text/plain', dragKey);
      e.dataTransfer.effectAllowed = 'move';
    } catch (err) { /* dataTransfer absent in legacy browsers */ }
  }

  function onDragOver(e) {
    if (!dragKey) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
    var row = e.target.closest ? e.target.closest('.h-row[data-key]') : null;
    /* Folded rows are painted but invisible — dropping onto one would mark
       a row nobody can see. */
    if (!row || row.getAttribute('data-key') === dragKey ||
        (row.closest && row.closest('.h-fold.is-folded')) ||
        sectionOf(row.getAttribute('data-key')) !== sectionOf(dragKey)) {
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'none';
      clearDrop(); return;
    }
    var rect = row.getBoundingClientRect();
    var before = e.clientY < rect.top + rect.height / 2;
    if (dropRow !== row || dropBefore !== before) {
      clearDrop();
      row.classList.add(before ? 'is-drop-above' : 'is-drop-below');
      dropRow = row;
      dropBefore = before;
    }
  }

  function onDrop(e) {
    if (!dragKey) return;
    e.preventDefault();
    var target = dropRow ? dropRow.getAttribute('data-key') : null;
    var before = dropBefore;
    var key = dragKey;
    endDrag();
    if (target && sectionOf(target) === sectionOf(key)) {
      commitMove(key, target, before);
    }
  }

  function onDragEnd() {
    endDrag();
  }

  function bindDnd() {
    els.list.addEventListener('dragstart', onDragStart);
    els.list.addEventListener('dragover', onDragOver);
    els.list.addEventListener('drop', onDrop);
    els.list.addEventListener('dragend', onDragEnd);
    els.list.addEventListener('dragleave', function (e) {
      /* Leaving the list clears the drop marker only: the drag itself
         stays live so re-entering can still complete the move. dragend
         or drop does the full cleanup. */
      if (e.relatedTarget && !els.list.contains(e.relatedTarget)) {
        clearDrop();
      }
    });
  }

  /* ---------- action menu ---------- */

  function openMenu(key, anchor) {
    closeMenu(false);
    var svc = find(key);
    if (!svc || svc.state === 'planned') return;
    state.menu = key;
    select(key, false);
    menuOpener = anchor || null;

    menuScrim = make('div', 'h-menu-scrim');
    menuScrim.addEventListener('click', function () { closeMenu(true); });
    menuEl = make('div', 'h-menu');
    menuEl.setAttribute('role', 'menu');
    menuEl.setAttribute('aria-label', 'Actions for ' + (svc.name || key));
    menuEl.appendChild(make('div', 'h-menu-h', svc.name || key));

    var items = menuItems(svc);
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      if (it === '-') { menuEl.appendChild(make('hr')); continue; }
      var b = make('button', 'h-mi' + (it.danger ? ' is-danger' : ''));
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      b.setAttribute('data-mi', it.id);
      if (it.off) b.disabled = true;
      b.appendChild(svg(ICON[it.icon] || ICON.info));
      b.appendChild(make('span', null, it.label));
      b.appendChild(make('kbd', null, it.key));
      menuEl.appendChild(b);
      if (it.off && it.why) menuEl.appendChild(make('p', 'h-menu-why', 'Locked: ' + it.why));
    }
    menuEl.addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('[data-mi]') : null;
      if (!b || b.disabled) return;
      var id = b.getAttribute('data-mi');
      var opener = menuOpener;
      closeMenu(false);
      run(id, key, opener);
    });
    document.body.appendChild(menuScrim);
    document.body.appendChild(menuEl);
    placeMenu(anchor);

    var trigger = els.list.querySelector('[data-menu="' + key + '"]');
    if (trigger) trigger.setAttribute('aria-expanded', 'true');
    menuHi = -1;
    moveMenu(1);
  }

  function placeMenu(anchor) {
    if (!menuEl) return;
    if (window.matchMedia && window.matchMedia('(max-width: 560px)').matches) return;  // bottom sheet
    var target = anchor && anchor.getBoundingClientRect ? anchor
      : (els.list.querySelector('.h-row.is-sel .h-more') || $('abar-grp'));
    if (!target) return;
    var r = target.getBoundingClientRect();
    var w = menuEl.offsetWidth, h = menuEl.offsetHeight;
    var left = Math.max(8, Math.min(window.innerWidth - w - 8, r.right - w));
    var below = r.bottom + 6 + h <= window.innerHeight - 8;
    var top = below ? r.bottom + 6 : Math.max(8, r.top - 6 - h);
    menuEl.style.left = left + 'px';
    menuEl.style.top = top + 'px';
  }

  function closeMenu(restoreFocus) {
    if (menuEl && menuEl.parentNode) menuEl.parentNode.removeChild(menuEl);
    if (menuScrim && menuScrim.parentNode) menuScrim.parentNode.removeChild(menuScrim);
    var opener = menuOpener;
    menuEl = null; menuScrim = null; menuOpener = null;
    if (state.menu && els.list) {
      var trigger = els.list.querySelector('[data-menu="' + state.menu + '"]');
      if (trigger) trigger.setAttribute('aria-expanded', 'false');
    }
    state.menu = null;
    if (restoreFocus && opener && document.body.contains(opener)) {
      try { opener.focus({ preventScroll: true }); } catch (e) { opener.focus(); }
    }
  }

  function moveMenu(d) {
    if (!menuEl) return;
    var items = menuEl.querySelectorAll('.h-mi:not([disabled])');
    if (!items.length) return;
    menuHi = (menuHi + d + items.length) % items.length;
    try { items[menuHi].focus({ preventScroll: true }); } catch (e) { items[menuHi].focus(); }
  }

  /* ---------- storage sheet ---------- */

  /* The disk cell's ⓘ opens this dialog: api/disk's split of the same disk
     the cell measures, what each app owns plus the folders Docker and the
     OS put on it. The server walks the tree off the request path, so a
     cold open answers `scanning` and the real numbers land on a poll; the
     sheet fetches on open, then only while the server is still walking or
     the user asks for a rescan. */
  function openDisk(opener) {
    if (dsk.el) return;
    closeMenu(false);
    dsk.opener = opener || null;
    dsk.err = false;
    dsk.scrim = make('div', 'dsk-scrim');
    dsk.scrim.addEventListener('click', function () { closeDisk(true); });
    var el = make('div', 'dsk');
    var card = make('div', 'dsk-card');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    card.setAttribute('aria-labelledby', 'dsk-title');
    var head = make('div', 'dsk-head');
    var titles = make('div', 'dsk-tt');
    var h = make('h3', 'dsk-title', 'Storage');
    h.id = 'dsk-title';
    titles.appendChild(h);
    dsk.sub = make('p', 'dsk-sub', '');
    titles.appendChild(dsk.sub);
    head.appendChild(titles);
    var x = make('button', 'dsk-x');
    x.type = 'button';
    x.setAttribute('aria-label', 'Close storage details');
    x.title = 'Close';
    x.appendChild(svg(ICON.cross, { width: '2.2' }));
    x.addEventListener('click', function () { closeDisk(true); });
    head.appendChild(x);
    card.appendChild(head);
    dsk.body = make('div', 'dsk-body');
    card.appendChild(dsk.body);
    dsk.foot = make('div', 'dsk-foot');
    card.appendChild(dsk.foot);
    card.addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('[data-dsk-rescan], [data-dsk-retry]') : null;
      if (!b || b.disabled) return;
      fetchDisk(b.hasAttribute('data-dsk-rescan'));
    });
    el.appendChild(card);
    dsk.el = el;
    document.body.appendChild(dsk.scrim);
    document.body.appendChild(el);
    document.body.classList.add('is-locked');
    paintDisk();
    fetchDisk();
    try { x.focus({ preventScroll: true }); } catch (e) { x.focus(); }
  }

  function closeDisk(restoreFocus) {
    if (!dsk.el) return;
    if (dsk.scrim && dsk.scrim.parentNode) dsk.scrim.parentNode.removeChild(dsk.scrim);
    if (dsk.el.parentNode) dsk.el.parentNode.removeChild(dsk.el);
    if (dsk.timer) { clearTimeout(dsk.timer); dsk.timer = null; }
    dsk.el = null; dsk.scrim = null; dsk.sub = null; dsk.body = null; dsk.foot = null;
    document.body.classList.remove('is-locked');
    var opener = dsk.opener;
    dsk.opener = null;
    if (!restoreFocus) return;
    /* A poll rebuilds the health strip under the sheet, so the opener the
       click caught is often detached; find its replacement by marker. */
    var back = (opener && document.body.contains(opener)) ? opener
      : (els.health ? els.health.querySelector('[data-disk-info]') : null);
    if (back) { try { back.focus({ preventScroll: true }); } catch (e) { back.focus(); } }
  }

  /* Same fetch shape app.js's request() uses: relative path, no-store,
     a timeout so a hung box cannot park the sheet on a spinner. */
  function fetchDisk(fresh) {
    if (dsk.fetching) return;
    dsk.fetching = true;
    var opts = { cache: 'no-store', credentials: 'same-origin',
                 headers: { 'Accept': 'application/json' } };
    var timer = null;
    if (typeof AbortController === 'function') {
      var ctl = new AbortController();
      opts.signal = ctl.signal;
      timer = setTimeout(function () { ctl.abort(); }, 15000);
    }
    fetch('api/disk' + (fresh ? '?fresh=1' : ''), opts)
      .then(function (r) {
        /* A 404 JSON body is still an error: an old server answers
           "unknown endpoint" and would otherwise render as a warn line. */
        if (!r.ok) throw new Error('http ' + r.status);
        return r.json();
      })
      .then(function (j) {
        if (timer) clearTimeout(timer);
        dsk.fetching = false;
        dsk.err = false;
        dsk.data = j;
        if (dsk.el) { paintDisk(); scheduleDisk(); }
      })
      .catch(function () {
        if (timer) clearTimeout(timer);
        dsk.fetching = false;
        dsk.err = true;
        /* A dropped poll is not a dropped sheet: keep polling while the
           server is still walking, and show the retry the footer offers. */
        if (dsk.el) { paintDisk(); scheduleDisk(); }
      });
  }

  function scheduleDisk() {
    if (dsk.timer) { clearTimeout(dsk.timer); dsk.timer = null; }
    if (dsk.el && dsk.data && dsk.data.scanning === true) {
      dsk.timer = setTimeout(function () { fetchDisk(); }, DISK_POLL_MS);
    }
  }

  function sumBytes(list) {
    var n = 0, seen = false;
    for (var i = 0; i < list.length; i++) {
      var b = num(list[i] && list[i].bytes);
      if (b !== null) { n += b; seen = true; }
    }
    return seen ? n : null;
  }

  function paintDisk() {
    if (!dsk.el) return;
    var d = dsk.data || {};
    var disk = (d.disk && typeof d.disk === 'object') ? d.disk : sys() && sys().disk;
    var total = disk && num(disk.total);
    var used = disk && num(disk.used);
    var free = disk && num(disk.free);
    /* df arithmetic, same as the cell: used+free is the real basis, since
       reserved blocks sit in neither column. */
    var basis = (used !== null && free !== null && used + free > 0) ? used + free : null;
    var share = diskShare(disk);
    dsk.sub.textContent = disk
      ? fmtBytes(used) + ' used of ' + fmtBytes(total) + ' on ' + (disk.mount || '/') +
        (share !== null ? ' (' + Math.round(share * 100) + '% full)' : '')
      : 'What fills this box’s disk';

    var body = dsk.body;
    body.textContent = '';
    var scanning = d.scanning === true;

    if (dsk.err && !dsk.data) {
      var errBox = make('div', 'dsk-empty');
      errBox.appendChild(make('strong', null, 'Could not load the breakdown'));
      errBox.appendChild(make('span', null,
        'The box did not answer api/disk. The disk cell’s figure is still live.'));
      var retry = make('button', 'h-btn', 'Try again');
      retry.type = 'button';
      retry.setAttribute('data-dsk-retry', '1');
      errBox.appendChild(retry);
      body.appendChild(errBox);
      dsk.foot.textContent = '';
      return;
    }

    var apps = Array.isArray(d.apps) ? d.apps : [];
    var home = Array.isArray(d.home) ? d.home : [];
    var docker = (d.docker && typeof d.docker === 'object') ? d.docker : null;
    var other = num(d.other_bytes);
    var dockerParts = docker ? [
      { name: 'Images', bytes: num(docker.images) },
      { name: 'Containers', bytes: num(docker.containers) },
      { name: 'Volumes', bytes: num(docker.volumes) },
      { name: 'Build cache', bytes: num(docker.build_cache) }
    ] : [];

    /* One scale for everything: each figure is a slice of used+free. A
       bucket the walk could not measure takes no width, so what it shows
       never overstates. Apps uses the server's deduped target total, not
       a row sum: two apps sharing a data dir would bill it twice. */
    var appsBytes = num(d.apps_total);
    if (appsBytes === null) appsBytes = sumBytes(apps);
    var segs = [
      { cls: 'dsk-seg-a', label: 'Apps', bytes: appsBytes },
      { cls: 'dsk-seg-d', label: 'Docker', bytes: sumBytes(dockerParts) },
      { cls: 'dsk-seg-h', label: 'Files', bytes: sumBytes(home) },
      { cls: 'dsk-seg-s', label: 'System', bytes: other },
      { cls: 'dsk-seg-f', label: 'Free', bytes: free }
    ];
    if (basis) {
      var bar = make('div', 'dsk-dist');
      bar.setAttribute('aria-hidden', 'true');
      var lg = make('div', 'dsk-legend');
      for (var i = 0; i < segs.length; i++) {
        var b = segs[i].bytes;
        if (b === null) continue;
        if (b > 0) {
          var f = make('i', segs[i].cls);
          f.style.width = Math.min(100, b / basis * 100).toFixed(1) + '%';
          bar.appendChild(f);
        }
        var li = make('span', 'dsk-li');
        li.appendChild(make('i', segs[i].cls));
        li.appendChild(document.createTextNode(segs[i].label + ' ' + fmtBytes(b)));
        lg.appendChild(li);
      }
      body.appendChild(bar);
      body.appendChild(lg);
    }

    var hasRows = apps.length || dockerParts.length || home.length || other !== null;
    if (!hasRows && scanning) {
      var skel = make('div', 'dsk-empty');
      skel.appendChild(make('span', 'dsk-empty-t', 'Measuring the disk…'));
      skel.appendChild(make('span', null,
        'The first walk counts every folder, which can take a minute on a full disk.'));
      body.appendChild(skel);
    } else {
      var sApps = null;
      if (apps.length) {
        sApps = make('div', 'dsk-sect');
        sApps.appendChild(dskHead('Apps', 'data each app keeps'));
        apps.forEach(function (a) {
          sApps.appendChild(dskRow(a.name || a.key, num(a.bytes)));
        });
        body.appendChild(sApps);
      }
      if (dockerParts.length) {
        var sD = make('div', 'dsk-sect');
        sD.appendChild(dskHead('Docker', 'images, layers and volumes'));
        dockerParts.forEach(function (p) {
          sD.appendChild(dskRow(p.name, p.bytes));
        });
        body.appendChild(sD);
      }
      if (home.length) {
        var sH = make('div', 'dsk-sect');
        sH.appendChild(dskHead('Files and folders', 'the rest of your home directory'));
        home.forEach(function (rw) {
          sH.appendChild(dskRow(rw.name || rw.path, num(rw.bytes),
            rw.shared ? 'excluding apps' : null));
        });
        body.appendChild(sH);
      }
      var sO = make('div', 'dsk-sect');
      sO.appendChild(dskHead('System and other', 'outside your home directory'));
      sO.appendChild(dskRow('System files, mounts and other users', other));
      body.appendChild(sO);
      if (d.error) body.appendChild(make('p', 'dsk-warn', String(d.error)));
    }

    var foot = dsk.foot;
    foot.textContent = '';
    var st = make('span', 'dsk-status');
    if (scanning) {
      st.appendChild(glyph('busy'));
      st.appendChild(document.createTextNode(num(d.scanned_at) ? 'Rescanning…' : 'Measuring the disk…'));
    } else {
      st.appendChild(document.createTextNode(
        num(d.scanned_at) ? 'Measured ' + (ago(num(d.scanned_at)) || 'just now') : 'Not measured yet'));
    }
    if (dsk.err) st.appendChild(make('span', 'dsk-note', 'refresh failed'));
    foot.appendChild(st);
    /* After a failed fetch the button retries the poll; a fresh walk is
       only asked for when the last answer is healthy. */
    var again = make('button', 'h-btn dsk-again',
      dsk.err ? 'Try again' : 'Scan again');
    again.type = 'button';
    again.setAttribute(dsk.err ? 'data-dsk-retry' : 'data-dsk-rescan', '1');
    again.disabled = dsk.fetching || (scanning && !dsk.err);
    foot.appendChild(again);
  }

  function dskHead(title, note) {
    var h = make('div', 'dsk-sh');
    h.appendChild(make('span', 'dsk-st', title));
    if (note) h.appendChild(make('span', 'dsk-sn', note));
    return h;
  }

  function dskRow(name, bytes, tag) {
    var r = make('div', 'dsk-row');
    var n = make('span', 'dsk-name');
    n.appendChild(document.createTextNode(name));
    if (tag) n.appendChild(make('span', 'dsk-tag', tag));
    r.appendChild(n);
    r.appendChild(make('span', 'dsk-bytes' + (bytes === null ? ' is-na' : ''),
      bytes === null ? '–' : fmtBytes(bytes)));
    return r;
  }

  /* ---------- events ---------- */

  function onClick(e) {
    var t = e.target;
    if (!t.closest) return;

    var pill = t.closest('[data-pill]');
    if (pill) {
      state.group = pill.getAttribute('data-pill');
      remember(GROUP_STORE, state.group);
      paintPills();
      paintList();
      paintBar();
      return;
    }
    var fold = t.closest('[data-fold]');
    if (fold) {
      var id = fold.getAttribute('data-fold');
      state.fold[id] = !state.fold[id];
      if (id !== 'hidden') {
        remember(FOLD_STORE, ['stop', 'fresh'].filter(function (k) { return state.fold[k]; }).join(','));
      }
      /* No repaint: the rows stay painted inside their fold box, so the
         toggle is a class flip and the grid-rows transition animates it. */
      fold.setAttribute('aria-expanded', state.fold[id] ? 'false' : 'true');
      var box = els.list.querySelector('[data-foldbox="' + id + '"]');
      if (box) {
        box.classList.toggle('is-folded', state.fold[id]);
        if (state.fold[id]) {
          box.setAttribute('inert', '');
          box.setAttribute('aria-hidden', 'true');
        } else {
          box.removeAttribute('inert');
          box.removeAttribute('aria-hidden');
        }
      }
      /* A selected row inside the just-folded section is unreachable now;
         move the highlight to the first visible row, same as a repaint
         used to do. */
      if (state.fold[id] && order().indexOf(state.sel) === -1) {
        var ks = order();
        select(ks.length ? ks[0] : null, false);
      }
      paintBar();
      return;
    }
    var info = t.closest('[data-disk-info]');
    if (info) {
      openDisk(info);
      return;
    }
    var sort = t.closest('[data-sort]');
    if (sort) {
      var k = sort.getAttribute('data-sort');
      if (state.sort.key === k && k !== 'custom') state.sort.dir *= -1;
      else state.sort = { key: k, dir: (k === 'name' || k === 'custom') ? 1 : -1 };
      remember(SORT_STORE, state.sort.key + ':' + state.sort.dir);
      paintList();
      return;
    }
    if (t.closest('[data-clear]')) {
      state.q = ''; els.q.value = '';
      state.group = 'all'; remember(GROUP_STORE, 'all');
      paintPills(); paintList(); paintBar();
      els.q.focus();
      return;
    }
    var pin = t.closest('[data-pin]');
    if (pin) {
      var pk = pin.getAttribute('data-pin');
      select(pk, false);
      togglePin(pk);
      return;
    }
    var hideBtn = t.closest('[data-hide]');
    if (hideBtn) {
      var hk = hideBtn.getAttribute('data-hide');
      select(hk, false);
      toggleHide(hk);
      return;
    }
    var more = t.closest('[data-menu]');
    if (more) {
      var mk = more.getAttribute('data-menu');
      if (state.menu === mk) closeMenu(true);
      else openMenu(mk, more);
      return;
    }
    var act = t.closest('[data-act]');
    if (act) {
      var key = act.getAttribute('data-k');
      select(key, false);
      if (act.getAttribute('data-act') === 'open') {
        /* The <a> navigates on its own; only the beacon is ours. */
        var a = app();
        if (a && typeof a.touch === 'function') a.touch(key);
        return;
      }
      run(act.getAttribute('data-act'), key, act);
      return;
    }
    var r = t.closest('.h-row[data-key]');
    if (r && !t.closest('a')) select(r.getAttribute('data-key'), false);
  }

  function typingElsewhere() {
    var el = document.activeElement;
    if (!el || el === els.q) return false;
    var tag = el.tagName;
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable;
  }

  document.addEventListener('keydown', function (e) {
    if (dsk.el) {
      if (e.key === 'Escape' || e.key === 'Esc') {
        e.preventDefault(); closeDisk(true); return;
      }
      if (e.key === 'Tab') {
        /* Modal trap: cycle the sheet's own focusables, never the page's. */
        var items = dsk.el.querySelectorAll('button:not([disabled]), a[href]');
        if (!items.length) return;
        e.preventDefault();
        var at = Array.prototype.indexOf.call(items, document.activeElement);
        var next = at === -1 ? 0 : (at + (e.shiftKey ? -1 : 1) + items.length) % items.length;
        try { items[next].focus({ preventScroll: true }); } catch (err) { items[next].focus(); }
      }
      return;
    }
    if (menuEl) {
      var svc = find(state.menu);
      if (e.key === 'Escape' || e.key === 'Esc') { e.preventDefault(); closeMenu(true); return; }
      if (e.key === 'ArrowDown') { e.preventDefault(); moveMenu(1); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); moveMenu(-1); return; }
      if (e.key === 'Tab') { e.preventDefault(); moveMenu(e.shiftKey ? -1 : 1); return; }
      if ((e.key === 'k' || e.key === 'K') && (e.metaKey || e.ctrlKey)) { e.preventDefault(); closeMenu(true); return; }
      if (!svc || e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1) return;
      var items = menuItems(svc);
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (it !== '-' && !it.off && it.key.toLowerCase() === e.key.toLowerCase()) {
          e.preventDefault();
          var key = state.menu, opener = menuOpener;
          closeMenu(false);
          run(it.id, key, opener);
          return;
        }
      }
      return;
    }

    if (e.key === 'Escape' || e.key === 'Esc') {
      if (document.body.classList.contains('is-drawer')) { setDrawer(false); return; }
    }
    if (!homeShown() || sheetOpen()) return;

    if ((e.key === 'k' || e.key === 'K') && (e.metaKey || e.ctrlKey)) {
      if (!state.sel) return;
      e.preventDefault();
      openMenu(state.sel, null);
      return;
    }
    if (typingElsewhere() || e.metaKey || e.ctrlKey || e.altKey) return;

    if (e.key === '/' && document.activeElement !== els.q) {
      e.preventDefault();
      els.q.focus();
      els.q.select();
      return;
    }
    if (document.activeElement === els.q && (e.key === 'Escape' || e.key === 'Esc')) {
      if (els.q.value) { els.q.value = ''; state.q = ''; paintList(); paintPills(); }
      else els.q.blur();
      return;
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      var keys = order();
      if (!keys.length) return;
      e.preventDefault();
      var at = keys.indexOf(state.sel);
      var next = at === -1 ? 0 : Math.max(0, Math.min(keys.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)));
      select(keys[next], true);
      /* If a row's own control has focus, focus follows the highlight, so
         Enter can never fire a button on a row that is no longer selected. */
      var owner = document.activeElement;
      if (owner && owner !== els.q && els.list.contains(owner)) {
        var to = els.list.querySelector('[data-fid="act:' + keys[next] + '"]') ||
                 els.list.querySelector('[data-fid="detail:' + keys[next] + '"]');
        if (to) { try { to.focus({ preventScroll: true }); } catch (err) { to.focus(); } }
      }
      return;
    }
    if (e.key === 'Enter' && state.sel &&
        (document.activeElement === els.q || document.activeElement === document.body)) {
      e.preventDefault();
      runPrimary(state.sel, null);
    }
  });

  var abar = $('abar');
  if (abar) {
    abar.addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('[data-bar]') : null;
      if (!b || !state.sel) return;
      if (b.getAttribute('data-bar') === 'menu') openMenu(state.sel, b);
      else runPrimary(state.sel, b);
    });
  }

  /* ---------- sidebar: rail and drawer ---------- */

  function setRail(on) {
    document.body.classList.toggle('is-rail', on);
    var b = $('rail-btn');
    if (b) {
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
      b.setAttribute('aria-label', on ? 'Expand sidebar' : 'Collapse sidebar');
      b.title = on ? 'Expand sidebar' : 'Collapse sidebar';
    }
    remember(RAIL_STORE, on ? '1' : '0');
  }

  function setDrawer(on) {
    document.body.classList.toggle('is-drawer', on);
    var s = $('drawer-scrim');
    if (s) s.hidden = !on;
    var m = $('menu-btn');
    if (m) m.setAttribute('aria-expanded', on ? 'true' : 'false');
    var side = $('side');
    if (on) {
      var first = document.querySelector('.side .nav-link');
      if (first) first.focus();
    } else if (m && side && side.contains(document.activeElement) &&
               window.matchMedia && window.matchMedia('(max-width: 899px)').matches) {
      m.focus();
    }
  }

  if ($('rail-btn')) {
    $('rail-btn').addEventListener('click', function () {
      setRail(!document.body.classList.contains('is-rail'));
    });
  }
  if ($('menu-btn')) $('menu-btn').addEventListener('click', function () { setDrawer(true); });
  if ($('drawer-scrim')) $('drawer-scrim').addEventListener('click', function () { setDrawer(false); });
  var side = $('side');
  if (side) {
    side.addEventListener('click', function (e) {
      if (e.target.closest && e.target.closest('a')) setDrawer(false);
    });
  }
  if (stored(RAIL_STORE, '0') === '1') setRail(true);

  /* ---------- wiring ---------- */

  document.addEventListener('launcher:services', paint);
  window.addEventListener('hashchange', function () {
    closeMenu(false);
    closeDisk(false);
    paintSide();
    paintBar();
  });
  window.addEventListener('resize', function () { if (menuEl) placeMenu(menuOpener); });

  paint();
}());
