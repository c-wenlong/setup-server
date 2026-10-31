/* catalogue.js — the app catalogue at #/catalogue.
 *
 * Every app this repo can deploy, by category, with what it is, who makes it
 * and whether this box has it. Self-contained like notes.js: it owns the
 * #view-catalogue section and nothing else. It never fetches on its own; it
 * paints from the list app.js already polls (window.LauncherApp.services())
 * and repaints on the `launcher:services` event app.js fires after each poll.
 * Install hands off to app.js's deploy sheet (LauncherApp.deploy), Uninstall
 * to its Remove sheet (LauncherApp.remove) — the same confirm-then-log flow
 * as the detail page's buttons.
 *
 * Text only via textContent; nothing from the API is ever parsed as HTML.
 */
(function () {
  'use strict';

  var ROUTE = '#/catalogue';
  /* The Umbrel store rail: state filters first, one pill per category after.
     Group pills are appended from a.groups() at build time. */
  var FILTERS = [
    { id: 'all', label: 'All apps', glyph: 'activity' },
    { id: 'installed', label: 'Installed', glyph: 'heartbeat' },
    { id: 'available', label: 'Not installed', glyph: 'archive' }
  ];
  var GROUP_GLYPHS = {
    mine: 'home', files: 'folder', productivity: 'document',
    ai: 'chat', dev: 'code', system: 'server'
  };

  var root = document.getElementById('view-catalogue');
  if (!root) return;

  var shown = false;
  var query = '';
  var filter = 'all';
  var built = false;
  var elSummary, elSearch, elChips, elBody;

  function app() { return window.LauncherApp || null; }

  function make(tag, cls, txt) {
    var el = document.createElement(tag);
    if (cls) el.className = cls;
    if (txt != null) el.textContent = txt;
    return el;
  }

  function iconNode(svc) {
    var node = null;
    if (typeof window.iconFor === 'function') {
      try { node = window.iconFor(svc.key, svc.icon, svc.favicon); } catch (e) { node = null; }
    }
    if (!node || node.nodeType !== 1) node = make('span', 'icon-blank');
    node.setAttribute('aria-hidden', 'true');
    return node;
  }

  function isRunningJob(svc) {
    var job = svc && svc.job;
    return !!(job && typeof job === 'object' && job.id && job.status === 'running');
  }

  /* A running job may be a deploy or a start/stop/restart from elsewhere;
     say which, as the grid does. A backend with no `action` only deploys. */
  var RUNNING = {
    deploy:  { button: 'Installing…', line: 'Installing now' },
    start:   { button: 'Starting…', line: 'Starting now' },
    stop:    { button: 'Stopping…', line: 'Stopping now' },
    restart: { button: 'Restarting…', line: 'Restarting now' },
    remove:  { button: 'Removing…', line: 'Removing now' }
  };
  function running(svc) {
    var act = svc.job && svc.job.action;
    return RUNNING[Object.prototype.hasOwnProperty.call(RUNNING, act) ? act : 'deploy'];
  }

  /* Every focusable control carries "<key>:<kind>", so a repaint can put
     focus back on the very same control. */
  function tag(el, svc, kind) {
    el.setAttribute('data-act', svc.key + ':' + kind);
    return el;
  }

  /* installed | available | planned, from the same state the grid uses. */
  function bucket(svc) {
    if (svc.installed || svc.state === 'active' || svc.state === 'stopped') return 'installed';
    if (svc.state === 'available') return 'available';
    return 'planned';
  }

  function matches(svc) {
    if (filter === 'installed' && bucket(svc) !== 'installed') return false;
    if (filter === 'available' && bucket(svc) === 'installed') return false;
    /* A group pill filters by category id; the state pills behave as above. */
    if (['all', 'installed', 'available'].indexOf(filter) === -1 &&
        svc.group !== filter) return false;
    if (!query) return true;
    var hay = [svc.key, svc.name, svc.tagline, svc.description, svc.author]
      .filter(function (v) { return typeof v === 'string'; })
      .join(' ').toLowerCase();
    return hay.indexOf(query) !== -1;
  }

  /* ---------- chrome, built once ---------- */

  function pillGlyph(name) {
    if (typeof window.ICONS !== 'object' || typeof window.ICONS.svg !== 'function') return null;
    try { return window.ICONS.svg(name); } catch (e) { return null; }
  }

  function build() {
    if (built) return;
    built = true;

    var top = make('div', 'cat-top');
    var titles = make('div', 'cat-titles');
    var h = make('h2', null, 'Catalogue');
    h.id = 'cat-title';
    titles.appendChild(h);
    elSummary = make('p', 'cat-summary', '');
    titles.appendChild(elSummary);
    top.appendChild(titles);
    var back = make('a', 'iconbtn cat-back', 'Home');
    back.href = '#/';
    back.setAttribute('aria-label', 'Back to the launcher home');
    top.appendChild(back);
    root.appendChild(top);

    var bar = make('div', 'cat-bar');
    var search = make('div', 'cat-searchwrap');
    var sic = make('span', 'cat-search-ic');
    /* The glyph set has no magnifier, so the search icon is drawn inline. */
    var svg = (function () {
      var s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      s.setAttribute('viewBox', '0 0 24 24');
      s.setAttribute('fill', 'none');
      s.setAttribute('stroke', 'currentColor');
      s.setAttribute('stroke-width', '1.5');
      s.setAttribute('stroke-linecap', 'round');
      var c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      c.setAttribute('cx', '11'); c.setAttribute('cy', '11'); c.setAttribute('r', '6.4');
      var p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      p.setAttribute('d', 'm15.7 15.7 4.3 4.3');
      s.appendChild(c); s.appendChild(p);
      return s;
    }());
    sic.appendChild(svg);
    sic.setAttribute('aria-hidden', 'true');
    search.appendChild(sic);
    var label = make('label', 'sr-only', 'Search the catalogue');
    label.setAttribute('for', 'cat-search');
    search.appendChild(label);
    elSearch = make('input', 'cat-search');
    elSearch.id = 'cat-search';
    elSearch.type = 'search';
    elSearch.placeholder = 'Search';
    elSearch.autocomplete = 'off';
    elSearch.spellcheck = false;
    elSearch.addEventListener('input', function () {
      query = String(elSearch.value || '').trim().toLowerCase();
      paint();
    });
    search.appendChild(elSearch);
    bar.appendChild(search);

    /* app.js's ⌘K handler skips hidden views; this one is the catalogue's
       own, live only while this route is up and no sheet is open. */
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'k' && e.key !== 'K') return;
      if (!(e.metaKey || e.ctrlKey) || !shown) return;
      var sheet = document.getElementById('sheet');
      if (sheet && !sheet.hidden) return;
      e.preventDefault();
      elSearch.focus();
      elSearch.select();
    });

    elChips = make('div', 'cat-rail');
    elChips.setAttribute('role', 'group');
    elChips.setAttribute('aria-label', 'Categories');
    bar.appendChild(elChips);
    root.appendChild(bar);

    elBody = make('div', 'cat-body');
    elBody.setAttribute('aria-live', 'polite');
    root.appendChild(elBody);
  }

  /* The rail is rebuilt when the group list changes — the first paint often
     runs before the API lands, when a.groups() is still the defaults, and a
     renamed or added category must appear without a reload. A removed
     category drops the filter back to 'all'; a focused pill gets its focus
     back by data-filter after the rebuild. */
  var railSig = null;

  function buildRail() {
    var a = app();
    var groups = (a && typeof a.groups === 'function') ? a.groups() : [];
    var sig = groups.map(function (g) { return g.id + ':' + g.label; }).join('|');
    if (sig === railSig) return;
    railSig = sig;

    var keepFocus = null;
    var active = document.activeElement;
    if (active && elChips.contains(active)) {
      keepFocus = active.getAttribute('data-filter');
    }

    elChips.textContent = '';
    var rail = FILTERS.slice();
    groups.forEach(function (g) {
      rail.push({ id: g.id, label: g.label, glyph: GROUP_GLYPHS[g.id] || 'folder' });
    });
    var ids = {};
    rail.forEach(function (f) {
      ids[f.id] = true;
      var b = make('button', 'cat-pill');
      b.type = 'button';
      b.setAttribute('data-filter', f.id);
      var g = pillGlyph(f.glyph);
      if (g) { var gs = make('span', 'cat-pill-ic'); gs.appendChild(g); b.appendChild(gs); }
      b.appendChild(make('span', 'cat-pill-tx', f.label));
      b.addEventListener('click', function () { filter = f.id; paint(); });
      elChips.appendChild(b);
    });
    if (!ids[filter]) filter = 'all';
    if (keepFocus && ids[keepFocus]) {
      var again = elChips.querySelector('[data-filter="' + keepFocus + '"]');
      if (again) again.focus();
    }
  }

  /* ---------- one row ---------- */

  /* Compact status: the icon dot's colour and the detail link's spoken
     state. The detail page carries the long form (receipt dates, "removed,
     data kept", …). */
  function rowStatus(svc) {
    var b = bucket(svc);
    if (isRunningJob(svc)) return { cls: 'run', text: running(svc).line };
    if (b === 'installed') {
      return svc.state === 'active'
        ? { cls: 'ok', text: 'Running' }
        : { cls: 'warn', text: 'Stopped' };
    }
    if (b === 'available') {
      return svc.receipt && svc.receipt.removed_at
        ? { cls: 'muted', text: 'Removed · data kept' }
        : { cls: 'muted', text: 'Not installed' };
    }
    return { cls: 'muted', text: 'Coming soon' };
  }

  /* One verb per row: Install for what the box lacks, Uninstall for what it
     has (the same Remove sheet the detail page opens — stop_guard and all),
     and the busy button watches whichever job is already running. */
  function action(svc) {
    var b = bucket(svc);
    var wrap = make('div', 'cat-actions');

    if (isRunningJob(svc)) {
      var watch = tag(make('button', 'btn cat-btn', running(svc).button), svc, 'watch');
      watch.type = 'button';
      watch.addEventListener('click', function () { if (app()) app().deploy(svc.key, watch); });
      wrap.appendChild(watch);
    } else if (b === 'available') {
      var install = tag(make('button', 'btn btn-primary cat-btn', 'Install'), svc, 'install');
      install.type = 'button';
      install.setAttribute('aria-label', 'Install ' + (svc.name || svc.key));
      install.addEventListener('click', function () { if (app()) app().deploy(svc.key, install); });
      wrap.appendChild(install);
    } else if (b === 'installed' && svc.removable === true) {
      var rm = tag(make('button', 'btn cat-btn', 'Uninstall'), svc, 'remove');
      rm.type = 'button';
      rm.setAttribute('aria-label', 'Uninstall ' + (svc.name || svc.key));
      rm.addEventListener('click', function () { if (app()) app().remove(svc.key, rm); });
      wrap.appendChild(rm);
    }
    return wrap;
  }

  /* Umbrel store row: squircle icon (with a state dot on its top-right for
     installed services), name + tagline, then the one action. The row body
     is plain content; a stretched link covers the whole row — button zone
     included — so the entire tile opens the detail page and highlights on
     hover, while the action button floats above the link on z-index. */
  function card(svc) {
    var b = bucket(svc);
    var st = rowStatus(svc);
    var row = make('div', 'cat-row cat-row-' + b);
    row.setAttribute('data-key', svc.key);

    var body = make('div', 'cat-row-body');
    var ic = make('span', 'cat-icon');
    ic.appendChild(iconNode(svc));
    if (b === 'installed' || isRunningJob(svc)) {
      var dot = make('i', 'cat-dot cat-dot-' + st.cls);
      dot.setAttribute('aria-hidden', 'true');
      ic.appendChild(dot);
    }
    body.appendChild(ic);
    var names = make('div', 'cat-names');
    names.appendChild(make('span', 'cat-name', svc.name || svc.key));
    if (svc.tagline) names.appendChild(make('span', 'cat-tag', svc.tagline));
    body.appendChild(names);
    row.appendChild(body);
    row.appendChild(action(svc));

    var link = tag(make('a', 'cat-row-link'), svc, 'details');
    link.href = '#/service/' + encodeURIComponent(svc.key);
    link.setAttribute('aria-label',
      (svc.name || svc.key) + ', ' + st.text + ', opens details');
    link.appendChild(make('span', 'sr-only', 'Details'));
    row.appendChild(link);
    return row;
  }

  /* ---------- paint ---------- */

  function paint() {
    if (!shown) return;
    build();
    var a = app();
    buildRail();

    for (var c = 0; c < elChips.childNodes.length; c++) {
      var chip = elChips.childNodes[c];
      var on = chip.getAttribute('data-filter') === filter;
      chip.className = on ? 'cat-pill is-on' : 'cat-pill';
      chip.setAttribute('aria-pressed', on ? 'true' : 'false');
    }

    var err = a && typeof a.error === 'function' ? a.error() : null;
    if (!a || !a.loaded() || (err && !a.services().length)) {
      elSummary.textContent = '';
      elBody.textContent = '';
      if (err) {
        var box = make('div', 'cat-error');
        box.setAttribute('role', 'alert');
        box.appendChild(make('p', 'cat-error-title', 'Can\u2019t reach the launcher API'));
        box.appendChild(make('p', 'cat-error-text', err));
        var retry = make('button', 'btn', 'Retry');
        retry.type = 'button';
        retry.setAttribute('data-act', ':retry');
        retry.addEventListener('click', function () { a.refresh(); });
        box.appendChild(retry);
        elBody.appendChild(box);
      } else {
        elBody.appendChild(make('p', 'cat-empty', 'Loading the catalogue…'));
      }
      return;
    }

    /* Keep focus on the same card's button across a repaint (the poll
       replaces every node), so a keyboard user is not dumped to <body>. */
    var focusKey = null;
    var active = document.activeElement;
    if (active && root.contains(active) && active.getAttribute) {
      focusKey = active.getAttribute('data-act');
    }

    var list = a.services().filter(function (s) { return s.hidden !== true; });
    var counts = { installed: 0, available: 0, planned: 0 };
    list.forEach(function (s) { counts[bucket(s)]++; });
    elSummary.textContent = list.length + ' apps · ' + counts.installed + ' installed · ' +
      counts.available + ' ready to install' +
      (counts.planned ? ' · ' + counts.planned + ' coming soon' : '');

    var groups = a.groups();
    var sections = groups.map(function (g) { return { id: g.id, label: g.label, items: [] }; });
    var other = { id: null, label: 'Other', items: [] };
    list.forEach(function (s) {
      if (!matches(s)) return;
      var home = other;
      for (var i = 0; i < sections.length; i++) {
        if (sections[i].id === s.group) { home = sections[i]; break; }
      }
      home.items.push(s);
    });
    if (other.items.length) sections.push(other);

    elBody.textContent = '';
    var any = false;
    sections.forEach(function (sec) {
      if (!sec.items.length) return;
      any = true;
      var box = make('section', 'cat-panel');
      var head = make('div', 'cat-panel-h');
      head.appendChild(make('h3', 'cat-panel-title', sec.label));
      head.appendChild(make('span', 'cat-panel-n', String(sec.items.length)));
      box.appendChild(head);
      var rows = make('div', 'cat-rows');
      sec.items.forEach(function (s) { rows.appendChild(card(s)); });
      box.appendChild(rows);
      elBody.appendChild(box);
    });
    if (!any) elBody.appendChild(make('p', 'cat-empty', 'No app matches that.'));

    if (focusKey) {
      var again = null, all = root.querySelectorAll('[data-act]');
      for (var f = 0; f < all.length; f++) {
        if (all[f].getAttribute('data-act') === focusKey) { again = all[f]; break; }
      }
      if (again) { try { again.focus({ preventScroll: true }); } catch (e) { again.focus(); } }
    }
  }

  function route() {
    var on = String(location.hash || '') === ROUTE;
    if (on === shown) { if (on) paint(); return; }
    shown = on;
    root.hidden = !on;
    var link = document.getElementById('cat-link');
    if (link) link.setAttribute('aria-current', on ? 'page' : 'false');
    if (on) {
      document.title = 'Catalogue · Launcher';
      paint();
      window.scrollTo(0, 0);
      var a = app();
      if (a && !a.loaded()) a.refresh();
    } else if (document.title === 'Catalogue · Launcher') {
      document.title = 'Launcher';
    }
  }

  window.addEventListener('hashchange', route);
  document.addEventListener('launcher:services', function () { if (shown) paint(); });
  route();
}());
