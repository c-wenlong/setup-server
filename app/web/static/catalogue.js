/* catalogue.js — the app catalogue at #/catalogue.
 *
 * Every app this repo can deploy, by category, with what it is, who makes it
 * and whether this box has it. Self-contained like notes.js: it owns the
 * #view-catalogue section and nothing else. It never fetches on its own; it
 * paints from the list app.js already polls (window.LauncherApp.services())
 * and repaints on the `launcher:services` event app.js fires after each poll.
 * Install hands off to app.js's deploy sheet (LauncherApp.deploy), so it is
 * the same confirm-then-log flow as a tap on a dimmed tile.
 *
 * Text only via textContent; nothing from the API is ever parsed as HTML.
 */
(function () {
  'use strict';

  var ROUTE = '#/catalogue';
  var FILTERS = [
    { id: 'all', label: 'All' },
    { id: 'installed', label: 'Installed' },
    { id: 'available', label: 'Not installed' }
  ];

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
      try { node = window.iconFor(svc.key, svc.icon); } catch (e) { node = null; }
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

  function shortDate(iso) {
    return typeof iso === 'string' && iso.length >= 10 ? iso.slice(0, 10) : null;
  }

  function matches(svc) {
    if (filter === 'installed' && bucket(svc) !== 'installed') return false;
    if (filter === 'available' && bucket(svc) === 'installed') return false;
    if (!query) return true;
    var hay = [svc.key, svc.name, svc.tagline, svc.description, svc.author]
      .filter(function (v) { return typeof v === 'string'; })
      .join(' ').toLowerCase();
    return hay.indexOf(query) !== -1;
  }

  /* ---------- chrome, built once ---------- */

  function build() {
    if (built) return;
    built = true;

    var top = make('div', 'cat-top');
    var back = make('a', 'iconbtn cat-back', 'All apps');
    back.href = '#/';
    top.appendChild(back);
    var titles = make('div', 'cat-titles');
    var h = make('h2', null, 'Catalogue');
    h.id = 'cat-title';
    titles.appendChild(h);
    elSummary = make('p', 'cat-summary', '');
    titles.appendChild(elSummary);
    top.appendChild(titles);
    root.appendChild(top);

    var bar = make('div', 'cat-bar');
    var label = make('label', 'sr-only', 'Search the catalogue');
    label.setAttribute('for', 'cat-search');
    bar.appendChild(label);
    elSearch = make('input', 'cat-search');
    elSearch.id = 'cat-search';
    elSearch.type = 'search';
    elSearch.placeholder = 'Search apps';
    elSearch.autocomplete = 'off';
    elSearch.spellcheck = false;
    elSearch.addEventListener('input', function () {
      query = String(elSearch.value || '').trim().toLowerCase();
      paint();
    });
    bar.appendChild(elSearch);

    elChips = make('div', 'cat-chips');
    elChips.setAttribute('role', 'group');
    elChips.setAttribute('aria-label', 'Show');
    FILTERS.forEach(function (f) {
      var b = make('button', 'cat-chip', f.label);
      b.type = 'button';
      b.setAttribute('data-filter', f.id);
      b.addEventListener('click', function () { filter = f.id; paint(); });
      elChips.appendChild(b);
    });
    bar.appendChild(elChips);
    root.appendChild(bar);

    elBody = make('div', 'cat-body');
    elBody.setAttribute('aria-live', 'polite');
    root.appendChild(elBody);
  }

  /* ---------- one card ---------- */

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
    } else if (b === 'installed' && svc.state === 'active' && typeof svc.url === 'string' && svc.url) {
      var open = tag(make('a', 'btn cat-btn', 'Open'), svc, 'open');
      open.href = svc.url;
      open.target = '_blank';
      open.rel = 'noopener noreferrer';
      wrap.appendChild(open);
    }

    if (b === 'installed' && svc.removable === true && !isRunningJob(svc)) {
      var rm = tag(make('button', 'cat-remove', 'Remove'), svc, 'remove');
      rm.type = 'button';
      rm.setAttribute('aria-label', 'Remove ' + (svc.name || svc.key));
      rm.addEventListener('click', function () { if (app()) app().remove(svc.key, rm); });
      wrap.appendChild(rm);
    }

    var more = tag(make('a', 'cat-more', 'Details'), svc, 'details');
    more.href = '#/service/' + encodeURIComponent(svc.key);
    wrap.appendChild(more);
    return wrap;
  }

  function status(svc) {
    var b = bucket(svc);
    var line = make('p', 'cat-status cat-status-' + b);
    if (isRunningJob(svc)) {
      line.className = 'cat-status cat-status-run';
      line.textContent = running(svc).line;
      return line;
    }
    if (b === 'installed') {
      var r = svc.receipt;
      var when = r && shortDate(r.installed_at);
      line.textContent = (svc.state === 'active' ? 'Installed, running' : 'Installed, stopped') +
        (when ? ' · since ' + when : '');
    } else if (b === 'available') {
      line.textContent = svc.receipt && svc.receipt.removed_at
        ? 'Removed ' + (shortDate(svc.receipt.removed_at) || '') + ' · data kept'
        : 'Not installed';
    } else {
      line.textContent = 'Coming soon';
    }
    return line;
  }

  function card(svc) {
    var art = make('article', 'cat-card cat-card-' + bucket(svc));
    art.setAttribute('data-key', svc.key);

    var head = make('div', 'cat-head');
    var ic = make('span', 'cat-icon');
    ic.appendChild(iconNode(svc));
    head.appendChild(ic);
    var names = make('div', 'cat-names');
    names.appendChild(make('h4', 'cat-name', svc.name || svc.key));
    if (svc.tagline) names.appendChild(make('span', 'cat-tag', svc.tagline));
    head.appendChild(names);
    art.appendChild(head);

    if (typeof svc.description === 'string' && svc.description) {
      art.appendChild(make('p', 'cat-desc', svc.description));
    }
    if (typeof svc.author === 'string' && svc.author) {
      art.appendChild(make('p', 'cat-author', 'by ' + svc.author));
    }
    art.appendChild(status(svc));
    art.appendChild(action(svc));
    return art;
  }

  /* ---------- paint ---------- */

  function paint() {
    if (!shown) return;
    build();
    var a = app();

    for (var c = 0; c < elChips.childNodes.length; c++) {
      var chip = elChips.childNodes[c];
      var on = chip.getAttribute('data-filter') === filter;
      chip.className = on ? 'cat-chip is-on' : 'cat-chip';
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

    var list = a.services();
    var counts = { installed: 0, available: 0, planned: 0 };
    list.forEach(function (s) { counts[bucket(s)]++; });
    elSummary.textContent = list.length + ' apps · ' + counts.installed + ' installed · ' +
      counts.available + ' ready to install' +
      (counts.planned ? ' · ' + counts.planned + ' coming soon' : '');

    var groups = a.groups();
    var known = {};
    groups.forEach(function (g) { known[g.id] = true; });
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
      var box = make('section', 'cat-group');
      box.appendChild(make('h3', 'cat-group-title', sec.label + ' · ' + sec.items.length));
      var grid = make('div', 'cat-grid');
      sec.items.forEach(function (s) { grid.appendChild(card(s)); });
      box.appendChild(grid);
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
