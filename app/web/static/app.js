/* app.js — launcher
 *
 * Plain ES5-ish vanilla JS, no build step, no modules, no network beyond the
 * launcher's own API. Every URL here is RELATIVE ("api/services") because the
 * page is served at both `/` and `/home/` and Tailscale strips the prefix.
 * An absolute path would silently break the `/home/` mount.
 */
(function () {
  'use strict';

  /* ---------- config ---------- */

  var API_SERVICES  = 'api/services';
  var REFRESH_MS    = 30000;   // background status refresh
  var MIN_REFETCH_MS = 5000;   // floor between refreshes, so focus can't hammer
  var JOB_POLL_MS   = 1000;    // deploy log polling
  var FETCH_TIMEOUT = 8000;
  var MAX_POLL_FAILS = 6;
  var TAB_STORE     = 'launcher.tab';
  var GROUP_STORE   = 'launcher.groups';

  /* Tabs. `state` comes straight from the API:
       active   -> running
       stopped  -> deployed, health probe fails  (shown as "Paused")
       available/planned -> not on the box       (shown as "Uninstalled")
     `empty` is what we say when the tab legitimately has nothing in it —
     never a blank void. */
  /* Every job the server can run for a service, in one table. `deploy` is the
     original one (POST .../deploy); start/stop/restart are lifecycle actions
     (POST .../action) and go through the SAME job machinery — one job id, one
     poll loop, one log pane — so everything below is shared between them. */
  var ACTIONS = {
    deploy:  { label: 'Deploy',  busy: 'Starting…',    gerund: 'Deploying'   },
    start:   { label: 'Start',   busy: 'Starting…',    gerund: 'Starting'    },
    stop:    { label: 'Stop',    busy: 'Stopping…',    gerund: 'Stopping'    },
    restart: { label: 'Restart', busy: 'Restarting…',  gerund: 'Restarting'  },
    remove:  { label: 'Remove',  busy: 'Removing…',    gerund: 'Removing'    }
  };

  function actionDef(name) {
    return Object.prototype.hasOwnProperty.call(ACTIONS, name) ? ACTIONS[name] : null;
  }

  var TABS = [
    { id: 'all', label: 'All',
      match: function () { return true; },
      empty: 'Nothing in the registry yet.' },
    { id: 'active', label: 'Active',
      match: function (s) { return s.state === 'active'; },
      empty: 'Nothing is running right now.' },
    { id: 'paused', label: 'Paused',
      match: function (s) { return s.state === 'stopped'; },
      empty: 'Nothing is down — every deployed service is answering.' },
    { id: 'uninstalled', label: 'Uninstalled',
      match: function (s) { return s.state === 'available' || s.state === 'planned'; },
      empty: 'Everything in the repo is deployed.' },
    { id: 'c-wenlong', label: 'c-wenlong',
      match: function (s) { return s.author === 'c-wenlong'; },
      empty: 'No services here are authored by c-wenlong.' }
  ];

  /* v3 view/sort/usage module (view.js), loaded just before this file. Every
     call into it goes through here. It is optional on purpose: if that script
     is missing or threw, the grid is exactly what it was in v2 — registry
     order, tiles, no beacons — rather than a blank page. */
  var VIEW = window.LauncherView || {
    mode:     function () { return 'grid'; },
    arrange:  function (list) { return list; },
    grouped:  function (list) {
      var out = [];
      for (var i = 0; i < (list || []).length; i++) {
        out.push({ type: 's', svc: list[i] });
      }
      return out;
    },
    table:    function () {},
    board:    function () {},
    groupBy:  function () { return 'state'; },
    isStarred: function () { return false; },
    starButton: function () { return document.createElement('button'); },
    paintStar: function () {},
    ram:      function () { return ''; },
    ramTag:   function () {},
    detail:   function () {},
    touch:    function () {},
    toolbar:  function () {},
    onChange: function () {}
  };

  /* ---------- state ---------- */

  /* Same ids/labels as services.json. Used until the API catalog arrives, and
     kept if an older launcher process has not been restarted yet — otherwise
     the Categories menu opens as an empty box. */
  var DEFAULT_GROUPS = [
    { id: 'daily',     label: 'Daily' },
    { id: 'ai',        label: 'AI & automation' },
    { id: 'knowledge', label: 'Knowledge & media' },
    { id: 'infra',     label: 'Infrastructure' }
  ];

  var services = [];
  var groups = DEFAULT_GROUPS.slice();
  var host = '';
  var filterText = '';
  /* null = no category restriction (every box checked). An array is the
     ids that are on; empty array means the user unchecked everything. */
  var groupFilter = null;
  var headingCache = {};   // group id -> h2, so a refresh does not rebuild headings
  var activeTab = 'all';
  var tileCache = {};   // key -> {sig, node}, so a refresh reuses unchanged tiles
  var loaded = false;
  var lastFetchAt = 0;
  var inflight = false;
  var refreshTimer = null;

  /* detail view */
  var detailKey = null;      // key of the service on screen, null on the grid
  var detailReq = 0;         // guards against a stale fetch painting over a new page
  var detailSvc = null;      // best-known service object for the open detail
  var revealed = {};         // '=' + var name -> value. In memory, this page view only.
  var savedName = '';
  var savedDesc = '';
  var savedFlash = null;
  var gridScroll = 0;
  var navDepth = 0;          // in-app hash pushes, so Back knows where to go

  var sheetService = null;
  var sheetAction = 'deploy';   // which of ACTIONS the open sheet is running
  var actionBusy = false;       // a POST is in flight; no second tap gets through
  var settleTimer = null;       // one late refetch, after the health cache expires
  var jobId = null;
  var jobTimer = null;
  var jobFails = 0;
  var lastFocused = null;

  /* ---------- dom ---------- */

  var $ = function (id) { return document.getElementById(id); };

  var elGrid    = $('grid');
  var elPanel   = $('panel');
  var elTabs    = $('tabs');
  var elEmpty   = $('empty');
  var elHost    = $('host');
  var elNotice  = $('notice');
  var elNoticeTitle = $('notice-title');
  var elNoticeText  = $('notice-text');
  var elRetry   = $('notice-retry');
  var elFilter  = $('filter');
  var elLive    = $('live');

  var elSearch    = $('search');
  var elSearchRow = $('searchrow');
  var elGFilter   = $('gfilter');
  var elGBtn      = $('gfilter-btn');
  var elGLabel    = $('gfilter-label');
  var elGMenu     = $('gfilter-menu');
  /* The whole site header (brand mark, title, hostname, filter) belongs to
     the grid only. On a detail page the breadcrumb is the top of the page —
     repeating the brand above it just pushes the content down. */
  var elHead    = $('head');
  var elVGrid   = $('view-grid');
  var elVDetail = $('view-detail');
  var elDBack   = $('d-back');
  var elDNote   = $('d-note');
  var elDIcon   = $('d-icon');
  var elDStrip  = $('d-strip');
  var elDTitle  = $('d-title');
  var elDSub    = $('d-sub');
  var elDName   = $('d-name');
  var elDDesc   = $('d-desc');
  var elDSave   = $('d-save');
  var elEnvSec  = $('d-env-sec');
  var elEnvPath = $('d-env-path');
  var elEnv     = $('d-env');
  var elEnvEmpty = $('d-env-empty');
  var elMetaSec = $('d-meta-sec');
  var elMeta    = $('d-meta');

  var elScrim   = $('scrim');
  var elSheet   = $('sheet');
  var elCard    = $('sheet-card');
  var elSIcon   = $('sheet-icon');
  var elSTitle  = $('sheet-title');
  var elSSub    = $('sheet-sub');
  var elSBody   = $('sheet-body');
  var elSAlert  = $('sheet-alert');
  var elSRun    = $('sheet-run');
  var elRunPill = $('run-pill');
  var elRunExit = $('run-exit');
  var elLog     = $('run-log');
  var elActions = $('sheet-actions');
  var elCancel  = $('btn-cancel');
  var elConfirm = $('btn-confirm');

  /* ---------- small helpers ---------- */

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }

  function text(node, value) {
    node.textContent = value == null ? '' : String(value);
    return node;
  }

  function say(message) { text(elLive, message); }

  /* The icon module owns brand logo -> hand-drawn glyph -> fallback. We only
     ever call window.iconFor(key, name). If it has not loaded (or throws),
     drop in an empty box so the grid still lays out. */
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

  function icon(svc) {
    var span = make('span', 'tile-icon');
    span.appendChild(iconNode(svc));
    return span;
  }

  var SVG_NS = 'http://www.w3.org/2000/svg';

  /* Local UI chrome glyphs — drawn here rather than in the icon module,
     which owns service marks only. Nothing is fetched. */
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

  var GLYPHS = {
    download: ['M12 4.4v10.4', 'm7.8 10.8 4.2 4.2 4.2-4.2', 'M4.6 19.3h14.8'],
    chevron:  ['m9.5 5.5 6.5 6.5-6.5 6.5'],
    eye:      ['M2.4 12S6 5.8 12 5.8 21.6 12 21.6 12 18 18.2 12 18.2 2.4 12 2.4 12Z',
               'M14.9 12a2.9 2.9 0 1 1-5.8 0 2.9 2.9 0 0 1 5.8 0Z'],
    eyeOff:   ['M4.2 4.2 19.8 19.8',
               'M9.9 6.1A9.6 9.6 0 0 1 12 5.8c6 0 9.6 6.2 9.6 6.2a17.7 17.7 0 0 1-3.2 4',
               'M6.5 8A17.4 17.4 0 0 0 2.4 12S6 18.2 12 18.2a9.5 9.5 0 0 0 3.7-.7',
               'M10 10a2.9 2.9 0 0 0 4 4'],
    copy:     ['M9.5 9.5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-6a2 2 0 0 1-2-2Z',
               'M15.5 7.5v-1a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h1'],
    check:    ['m5.5 12.5 4 4 9-9'],
    pencil:   ['M4.5 19.5h3.6L18.6 9a2.5 2.5 0 0 0-3.6-3.6L4.5 15.9v3.6Z', 'm13.4 6.9 3.6 3.6'],
    cross:    ['m6.5 6.5 11 11', 'm17.5 6.5-11 11'],
    lock:     ['M8 10.6V8.3a4 4 0 0 1 8 0v2.3',
               'M6.4 10.6h11.2a1.4 1.4 0 0 1 1.4 1.4v6.2a1.4 1.4 0 0 1-1.4 1.4H6.4A1.4 1.4 0 0 1 5 18.2V12a1.4 1.4 0 0 1 1.4-1.4Z']
  };

  function downloadGlyph() {
    var span = make('span', 'tile-dl');
    span.appendChild(glyph(GLYPHS.download));
    return span;
  }

  /* fetch with a timeout, so a hung box shows an error instead of a spinner
     that never resolves. AbortController is available in every Safari that
     supports fetch at all (12.1+). */
  function request(path, options) {
    var opts = options || {};
    var controller = null;
    var timer = null;

    if (typeof AbortController === 'function') {
      controller = new AbortController();
      opts.signal = controller.signal;
      timer = setTimeout(function () { controller.abort(); }, FETCH_TIMEOUT);
    }
    opts.cache = 'no-store';
    opts.credentials = 'same-origin';

    return fetch(path, opts).then(function (res) {
      if (timer) clearTimeout(timer);
      return res.text().then(function (body) {
        var data = null;
        try { data = body ? JSON.parse(body) : null; } catch (e) { data = null; }
        return { ok: res.ok, status: res.status, data: data, raw: body };
      });
    }, function (err) {
      if (timer) clearTimeout(timer);
      throw err;
    });
  }

  /* ---------- tiles ---------- */

  function cornerDot(cls, label) {
    var slot = make('span', 'tile-corner');
    var dot = make('i', 'dot ' + cls);
    dot.setAttribute('role', 'img');
    dot.setAttribute('aria-label', label);
    slot.appendChild(dot);
    return slot;
  }

  /* `job` is optional — older backends do not send it. Returns the id of a
     job that is running for this service right now, or null. */
  function liveJob(svc) {
    var job = svc && svc.job;
    if (!job || typeof job !== 'object') return null;
    if (!job.id) return null;
    if (job.status && job.status !== 'running') return null;
    return String(job.id);
  }

  /* Which verb that job is running. A backend that predates lifecycle actions
     sends no `action`, and everything it can run is a deploy. */
  function jobAction(svc) {
    var job = svc && svc.job;
    var name = (job && typeof job.action === 'string') ? job.action : 'deploy';
    return actionDef(name) ? name : 'deploy';
  }

  /* "deploying…", "stopping…" — the tile's live note. */
  function jobNote(svc) {
    return ACTIONS[jobAction(svc)].gerund.toLowerCase() + '…';
  }

  /* The same thing as a status label: "Deploy running", "Stopping…". */
  function jobLabel(svc) {
    var name = jobAction(svc);
    return name === 'deploy' ? 'Deploy running' : ACTIONS[name].gerund + '…';
  }

  function tagline(svc) {
    var p = make('span', 'tile-tag');
    if (svc.tagline) p.appendChild(document.createTextNode(svc.tagline));

    var note = null;
    if (liveJob(svc)) {
      note = make('span', 'tile-note-run');
      text(note, jobNote(svc));
    } else if (svc.state === 'stopped') {
      note = make('span', 'tile-note');
      text(note, 'down');
    } else if (svc.state === 'active' && !svc.url) {
      note = make('span', 'tile-note-muted');
      text(note, 'no web UI');
    } else if (svc.state === 'available') {
      note = make('span', 'tile-note-muted');
      text(note, 'not deployed');
    }

    if (note) {
      /* The separator travels with the note, so a narrow tile wraps as
         "Automation / · down" rather than leaving a dangling "·". */
      if (svc.tagline) {
        p.appendChild(document.createTextNode(' '));
        var tail = make('span', 'tile-tail');
        tail.appendChild(text(make('span', 'tile-sep'), '· '));
        tail.appendChild(note);
        p.appendChild(tail);
      } else {
        p.appendChild(note);
      }
    }
    return p;
  }

  function detailHref(key) {
    /* Fragment-only, so it resolves against whichever mount point the page is
       served from. Never an absolute path. */
    return '#/service/' + encodeURIComponent(key);
  }

  /* The corner slot is absolutely positioned and inert, which makes it the
     one place a RAM figure can go without moving a single pixel of the tile's
     own layout — the condition for putting it on the grid at all. view.js
     fills it; with no resources in the payload it stays empty. */
  function cornerFor(svc, job) {
    var slot = cornerSlot(svc, job);
    VIEW.ramTag(slot, svc);
    return slot;
  }

  function cornerSlot(svc, job) {
    var state = svc.state || 'planned';
    if (job)                  return cornerDot('dot-job', jobLabel(svc));
    if (state === 'active')   return cornerDot('dot-ok', 'Running');
    if (state === 'stopped')  return cornerDot('dot-warn', 'Installed but not responding');
    if (state === 'available') {
      var slot = make('span', 'tile-corner');
      slot.appendChild(downloadGlyph());
      /* No "tap to install" any more: this corner is inert now, and the
         install target is the icon+name link. */
      slot.setAttribute('title', 'Not deployed yet');
      return slot;
    }
    var pslot = make('span', 'tile-corner');
    pslot.appendChild(text(make('span', 'badge'), 'planned'));
    return pslot;
  }

  /* Fills a target with the tile's contents: icon, name, tagline. */
  function fillTile(node, svc) {
    node.appendChild(icon(svc));
    node.appendChild(text(make('span', 'tile-name'), svc.name || svc.key));
    node.appendChild(tagline(svc));
    var label = (svc.name || svc.key) + ', ' + (svc.tagline || '') + ', ' + describe(svc);
    node.setAttribute('aria-label', label.replace(/, ,/g, ','));
    return node;
  }

  /* A tile is a container holding two SIBLING targets — an <a> cannot be
     nested inside a <button>:
       left  .tile-open : opens the service (or the deploy sheet / running job)
       right .tile-more : blank strip, opens the detail page
     When there is nothing to open (no URL, or planned) the whole tile becomes
     the detail link instead, so no tap lands on dead space. */
  function buildTile(svc) {
    var state = svc.state || 'planned';
    var job = liveJob(svc);
    var openable = (state === 'active' || state === 'stopped') && !!svc.url && !job;

    var tile = make('div', 'tile tile-' + state);
    tile.setAttribute('role', 'listitem');
    tile.setAttribute('data-key', svc.key);

    var left = null;
    if (job) {
      /* A job is already running server-side — a deploy, or a start/stop from
         the detail page. Tapping reattaches to it instead of POSTing a second
         one the backend would 409. */
      left = make('button', 'tile-open');
      left.type = 'button';
      left.addEventListener('click', function () {
        openSheet(svc, left, job, jobAction(svc));
      });
    } else if (openable) {
      left = make('a', 'tile-open');
      left.href = svc.url;
      left.target = '_blank';
      left.rel = 'noopener noreferrer';
      /* Fire and forget: this click is navigating a tab away, so the beacon
         uses keepalive and can never block it or fail loudly. */
      left.addEventListener('click', function () { VIEW.touch(svc.key, 'launched'); });
    } else if (state === 'available') {
      left = make('button', 'tile-open');
      left.type = 'button';
      left.addEventListener('click', function () { openSheet(svc, left); });
    }

    if (left) {
      tile.appendChild(fillTile(left, svc));
      tile.appendChild(cornerFor(svc, job));
      if (typeof VIEW.starButton === 'function') tile.appendChild(VIEW.starButton(svc.key));

      var more = make('a', 'tile-more');
      more.href = detailHref(svc.key);
      more.setAttribute('data-more', svc.key);
      more.setAttribute('aria-label', 'Details for ' + (svc.name || svc.key));
      more.appendChild(glyph(GLYPHS.chevron, '1.8'));
      tile.appendChild(more);
    } else {
      /* nothing to launch — the whole tile is the detail link */
      var solo = make('a', 'tile-solo');
      solo.href = detailHref(svc.key);
      solo.setAttribute('data-more', svc.key);
      tile.appendChild(fillTile(solo, svc));
      tile.appendChild(cornerFor(svc, job));
      if (typeof VIEW.starButton === 'function') tile.appendChild(VIEW.starButton(svc.key));
    }

    return tile;
  }

  function describe(svc) {
    if (liveJob(svc)) return jobLabel(svc).toLowerCase().replace(/…$/, '') +
                             ', activate to watch the log';
    switch (svc.state) {
      case 'active':    return svc.url ? 'running, opens in a new tab' : 'running, no web interface, opens details';
      case 'stopped':   return svc.url ? 'installed but not responding' : 'installed but not responding, opens details';
      case 'available': return 'not deployed, activate to install';
      default:          return 'planned, not built yet, opens details';
    }
  }

  function skeleton() {
    var node = make('div', 'tile tile-skel');
    node.setAttribute('aria-hidden', 'true');
    node.appendChild(make('span', 'sk sk-i'));
    node.appendChild(make('span', 'sk sk-a'));
    node.appendChild(make('span', 'sk sk-b'));
    return node;
  }

  /* ---------- rendering ---------- */

  function groupLabel(id) {
    if (!id) return '';
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].id === id) return groups[i].label || '';
    }
    return '';
  }

  function groupsFromServices(list) {
    var seen = {};
    var out = [];
    var i, id, label;
    for (i = 0; i < DEFAULT_GROUPS.length; i++) {
      seen[DEFAULT_GROUPS[i].id] = true;
    }
    if (list) {
      for (i = 0; i < list.length; i++) {
        id = list[i] && list[i].group;
        if (!id || seen[id]) continue;
        seen[id] = true;
        label = (list[i].group_label || id);
        out.push({ id: id, label: label });
      }
    }
    return DEFAULT_GROUPS.concat(out);
  }

  function resolveGroups(data) {
    if (data && Array.isArray(data.groups) && data.groups.length) {
      return data.groups;
    }
    return groupsFromServices(data && data.services);
  }

  function loadGroupFilter() {
    var raw = null;
    try { raw = window.localStorage.getItem(GROUP_STORE); } catch (e) { raw = null; }
    if (raw == null || raw === '') { groupFilter = null; return; }
    try {
      var parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) { groupFilter = null; return; }
      var out = [];
      for (var i = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i]) out.push(parsed[i]);
      }
      groupFilter = out;
    } catch (e) { groupFilter = null; }
  }

  function rememberGroups() {
    try {
      if (groupFilter === null) window.localStorage.removeItem(GROUP_STORE);
      else window.localStorage.setItem(GROUP_STORE, JSON.stringify(groupFilter));
    } catch (e) { /* private mode */ }
  }

  function groupIsOn(id) {
    if (groupFilter === null) return true;
    for (var i = 0; i < groupFilter.length; i++) {
      if (groupFilter[i] === id) return true;
    }
    return false;
  }

  function inSelectedGroup(svc) {
    if (groupFilter === null) return true;
    return groupIsOn(svc.group);
  }

  function groupFilterActive() {
    if (groupFilter === null || !groups.length) return false;
    var on = 0;
    for (var i = 0; i < groups.length; i++) {
      if (groupIsOn(groups[i].id)) on++;
    }
    return on !== groups.length;
  }

  function paintGroupBtn() {
    if (!elGBtn || !elGLabel) return;
    var active = groupFilterActive();
    elGBtn.className = active ? 'iconbtn gfilter-btn is-on' : 'iconbtn gfilter-btn';
    if (!active) {
      text(elGLabel, 'Categories');
      return;
    }
    if (groupFilter && groupFilter.length === 1) {
      text(elGLabel, groupLabel(groupFilter[0]) || groupFilter[0]);
      return;
    }
    text(elGLabel, (groupFilter ? groupFilter.length : 0) + ' categories');
  }

  function pruneGroupFilter() {
    if (groupFilter === null || !groups.length) return;
    var keep = [];
    for (var i = 0; i < groupFilter.length; i++) {
      if (groupLabel(groupFilter[i])) keep.push(groupFilter[i]);
    }
    groupFilter = (keep.length === groups.length) ? null : keep;
  }

  function paintGroupMenu() {
    if (!elGMenu) return;
    pruneGroupFilter();
    elGMenu.textContent = '';
    if (!groups.length) {
      paintGroupBtn();
      return;
    }
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i];
      var lab = document.createElement('label');
      lab.className = 'gfilter-opt';
      var box = document.createElement('input');
      box.type = 'checkbox';
      box.value = g.id;
      box.checked = groupIsOn(g.id);
      lab.appendChild(box);
      lab.appendChild(document.createTextNode(g.label));
      elGMenu.appendChild(lab);
    }
    paintGroupBtn();
  }

  function setGroupOpen(open) {
    if (!elGBtn || !elGMenu) return;
    elGMenu.hidden = !open;
    elGBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  function applyGroupChecks() {
    if (!elGMenu) return;
    var boxes = elGMenu.querySelectorAll('input[type="checkbox"]');
    var on = [];
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].checked) on.push(boxes[i].value);
    }
    if (on.length === boxes.length) groupFilter = null;
    else groupFilter = on;
    rememberGroups();
    paintGroupBtn();
    if (loaded) render();
  }

  function find(key) {
    for (var i = 0; i < services.length; i++) {
      if (services[i].key === key) return services[i];
    }
    return null;
  }

  function matches(svc, q) {
    if (!q) return true;
    var hay = [svc.name, svc.tagline, svc.key, svc.group, svc.author,
               groupLabel(svc.group)].join(' ').toLowerCase();
    var words = q.split(/\s+/);
    for (var i = 0; i < words.length; i++) {
      if (words[i] && hay.indexOf(words[i]) === -1) return false;
    }
    return true;
  }

  function tabDef(id) {
    for (var i = 0; i < TABS.length; i++) if (TABS[i].id === id) return TABS[i];
    return TABS[0];
  }

  /* Reuse the existing node when nothing about the service changed, so the
     30s refresh does not blow away focus, hover, or the scroll position. */
  function tileFor(svc) {
    var sig = [svc.state, svc.url, svc.name, svc.tagline, svc.icon, liveJob(svc), jobAction(svc)].join('');
    var hit = tileCache[svc.key];
    var node = (hit && hit.sig === sig) ? hit.node : null;
    if (!node) {
      node = buildTile(svc);
      tileCache[svc.key] = { sig: sig, node: node };
    }
    /* RAM moves on every poll, so it is deliberately NOT part of the
       signature: it is rewritten in place instead, and a 30s refresh still
       never rebuilds the tile you happen to be hovering. */
    VIEW.ramTag(node.querySelector('.tile-corner'), svc);
    if (typeof VIEW.paintStar === 'function') {
      VIEW.paintStar(node.querySelector('.vw-star'), svc.key);
    }
    return node;
  }

  function headingFor(id, label) {
    var node = headingCache[id];
    if (!node) {
      node = document.createElement('h2');
      node.className = 'grid-h';
      headingCache[id] = node;
    }
    if (node.textContent !== label) node.textContent = label;
    return node;
  }

  /* Minimal keyed reconcile: only touch the DOM where it actually differs. */
  function syncGrid(nodes) {
    for (var i = 0; i < nodes.length; i++) {
      var current = elGrid.childNodes[i];
      if (current !== nodes[i]) elGrid.insertBefore(nodes[i], current || null);
    }
    while (elGrid.childNodes.length > nodes.length) {
      elGrid.removeChild(elGrid.lastChild);
    }
  }

  function render() {
    if (!loaded) {
      /* Skeleton tiles are the grid's loading state. Table and board would
         be a flash of the wrong thing, so those views simply wait. */
      var pending = VIEW.mode() === 'table' || VIEW.mode() === 'board';
      elGrid.textContent = '';
      elGrid.hidden = pending;
      VIEW.table(VIEW.mode() === 'table' ? [] : null);
      if (typeof VIEW.board === 'function') {
        VIEW.board(VIEW.mode() === 'board' ? [] : null, groups);
      }
      if (!pending) {
        var frag = document.createDocumentFragment();
        for (var s = 0; s < 8; s++) frag.appendChild(skeleton());
        elGrid.appendChild(frag);
      }
      elGrid.setAttribute('aria-busy', 'true');
      elEmpty.hidden = true;
      setBoardChrome(VIEW.mode() === 'board');
      elTabs.hidden = VIEW.mode() === 'board' &&
                      typeof VIEW.groupBy === 'function' &&
                      VIEW.groupBy() === 'state';
      VIEW.toolbar(true);
      paintTabs(null);
      return;
    }

    var q = filterText.trim().toLowerCase();
    /* Board grouped by Status already has a column per state, so the tab
       strip would collapse the board to a single column. Treat that as All. */
    var boardByState = VIEW.mode() === 'board' &&
                       typeof VIEW.groupBy === 'function' &&
                       VIEW.groupBy() === 'state';
    var tab = tabDef(boardByState ? 'all' : activeTab);

    /* Counts are per tab and honour the type-to-filter, so the tab strip
       tells you where a search term lives. */
    var counts = {};
    for (var t = 0; t < TABS.length; t++) counts[TABS[t].id] = 0;

    var shown = [];
    for (var i = 0; i < services.length; i++) {
      var svc = services[i];
      if (!matches(svc, q) || !inSelectedGroup(svc)) continue;
      for (var c = 0; c < TABS.length; c++) {
        if (TABS[c].match(svc)) counts[TABS[c].id]++;
      }
      if (tab.match(svc)) shown.push(svc);
    }

    /* Sort (and starring) live in view.js. Grouping is board-only — grid
       and table stay a flat list so a heading never appears in those views. */
    var ordered = VIEW.arrange(shown);

    if (VIEW.mode() === 'table') {
      elGrid.hidden = true;
      syncGrid([]);
      VIEW.table(ordered);
      if (typeof VIEW.board === 'function') VIEW.board(null);
    } else if (VIEW.mode() === 'board') {
      elGrid.hidden = true;
      syncGrid([]);
      VIEW.table(null);
      if (typeof VIEW.board === 'function') VIEW.board(shown, groups);
    } else {
      VIEW.table(null);
      if (typeof VIEW.board === 'function') VIEW.board(null);
      elGrid.hidden = false;
      var nodes = [];
      for (var n = 0; n < ordered.length; n++) nodes.push(tileFor(ordered[n]));
      syncGrid(nodes);
    }
    elGrid.setAttribute('aria-busy', 'false');
    setBoardChrome(VIEW.mode() === 'board' && detailKey === null);

    elTabs.hidden = services.length === 0 || boardByState;
    VIEW.toolbar(services.length !== 0);
    paintTabs(counts);

    if (shown.length || services.length === 0) {
      elEmpty.hidden = true;
      elPanel.removeAttribute('tabindex');
    } else {
      text(elEmpty, q
        ? (tab.id === 'all'
            ? 'No service matches “' + filterText.trim() + '”.'
            : 'Nothing in ' + tab.label + ' matches “' + filterText.trim() + '”.')
        : (groupFilterActive()
            ? (tab.id === 'all'
                ? 'No service in those categories.'
                : 'Nothing in ' + tab.label + ' is in those categories.')
            : tab.empty));
      elEmpty.hidden = false;
      elPanel.setAttribute('tabindex', '0');   // the panel has no focusable child
    }
  }

  function setBoardChrome(on) {
    /* Board chrome locks page scrolling. Never on the catalogue: render()
       re-applies it after every poll, and that page has to scroll. */
    if (isCatalogueRoute()) on = false;
    try { document.body.classList.toggle('is-board', !!on); }
    catch (e) { /* nothing to paint onto */ }
  }

  function showNotice(title, message) {
    text(elNoticeTitle, title);
    text(elNoticeText, message);
    elNotice.hidden = false;
  }

  function hideNotice() { elNotice.hidden = true; }

  /* ---------- tabs ---------- */

  function tabEl(id) { return $('tab-' + id); }

  function paintTabs(counts) {
    for (var i = 0; i < TABS.length; i++) {
      var def = TABS[i];
      var el = tabEl(def.id);
      if (!el) continue;

      var selected = def.id === activeTab;
      el.setAttribute('aria-selected', selected ? 'true' : 'false');
      el.tabIndex = selected ? 0 : -1;   // roving tabindex: one stop for the strip
      if (selected) elPanel.setAttribute('aria-labelledby', el.id);

      var n = counts ? counts[def.id] : null;
      text($('tab-n-' + def.id), n === null ? '' : n);
      /* Zero stays clickable, just quieter — "Paused 0" is information. */
      el.className = (n === 0) ? 'tab tab-zero' : 'tab';
    }
  }

  function storedTab() {
    var raw = null;
    try { raw = window.localStorage.getItem(TAB_STORE); } catch (e) { raw = null; }
    for (var i = 0; i < TABS.length; i++) if (TABS[i].id === raw) return raw;
    return 'all';
  }

  function rememberTab(id) {
    try { window.localStorage.setItem(TAB_STORE, id); } catch (e) { /* private mode */ }
  }

  function selectTab(id, moveFocus) {
    var el = tabEl(id);
    if (!el) return;
    if (id !== activeTab) {
      activeTab = id;
      rememberTab(id);
      render();
      say(tabDef(id).label + ', ' + ($('tab-n-' + id).textContent || '0') + ' services');
    }
    if (moveFocus) el.focus();
  }

  elTabs.addEventListener('click', function (e) {
    var node = e.target;
    while (node && node !== elTabs && !node.getAttribute('data-tab')) node = node.parentNode;
    if (node && node !== elTabs) selectTab(node.getAttribute('data-tab'), false);
  });

  elTabs.addEventListener('keydown', function (e) {
    var index = -1;
    for (var i = 0; i < TABS.length; i++) if (TABS[i].id === activeTab) index = i;
    if (index < 0) return;

    var next = null;
    if (e.key === 'ArrowRight' || e.key === 'Right')     next = (index + 1) % TABS.length;
    else if (e.key === 'ArrowLeft' || e.key === 'Left')  next = (index - 1 + TABS.length) % TABS.length;
    else if (e.key === 'Home')                           next = 0;
    else if (e.key === 'End')                            next = TABS.length - 1;
    else return;

    e.preventDefault();
    selectTab(TABS[next].id, true);
    var el = tabEl(TABS[next].id);
    if (el.scrollIntoView) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  });

  /* ---------- loading ---------- */

  /* catalogue.js paints from this same list rather than polling twice, so it
     hears about every poll: a fresh list, or a failure (LauncherApp.error). */
  var lastError = null;
  function notifyServices() {
    try {
      document.dispatchEvent(new CustomEvent('launcher:services'));
    } catch (e) { /* very old browser: the catalogue repaints on its own route */ }
  }

  function load(force) {
    var now = Date.now();
    if (inflight) return Promise.resolve();
    if (!force && now - lastFetchAt < MIN_REFETCH_MS) return Promise.resolve();

    inflight = true;
    return request(API_SERVICES).then(function (res) {
      inflight = false;
      lastFetchAt = Date.now();

      if (!res.ok || !res.data || !Array.isArray(res.data.services)) {
        failed(res.ok
          ? 'The API answered but the response was not the expected shape.'
          : 'The API answered with HTTP ' + res.status + '.');
        return;
      }

      host = res.data.host || '';
      services = res.data.services;
      groups = resolveGroups(res.data);
      paintGroupMenu();
      loaded = true;
      hideNotice();
      text(elHost, host || ' ');
      render();
      lastError = null;
      notifyServices();

      /* Keep an open detail page's status line live too, without refetching
         the detail itself — that would fight whatever is being typed. */
      if (detailKey && detailSvc) {
        var fresh = find(detailKey);
        if (fresh) {
          detailSvc.state = fresh.state;
          detailSvc.job = fresh.job;
          if (fresh.control !== undefined) detailSvc.control = fresh.control;
          if (fresh.removable !== undefined) detailSvc.removable = fresh.removable;
          if (detailSvc.url == null) detailSvc.url = fresh.url;
          paintHead(detailSvc);
          /* Resources ride the same poll — cpu_pct is null until the server
             has two samples, so it appears on the second one. */
          VIEW.detail(detailKey, fresh);
        }
      }
    }, function () {
      inflight = false;
      lastFetchAt = Date.now();
      failed('No response from the launcher backend. It may not be running: check `systemctl --user status launcher` on the box.');
    });
  }

  function failed(message) {
    lastError = message;
    showNotice("Can't reach the launcher API", message);
    /* The notice lives in the grid, which the catalogue route hides. */
    notifyServices();
    if (!loaded) {
      loaded = true;      // stop the skeletons; the notice explains why
      services = [];
      groups = DEFAULT_GROUPS.slice();
      paintGroupMenu();
      render();
    }
  }

  /* ---------- deploy sheet ---------- */

  function openSheet(svc, opener, attachId, attachAction) {
    var verb = (attachId && actionDef(attachAction)) ? attachAction : 'deploy';
    sheetService = svc;
    sheetAction = verb;
    lastFocused = opener || document.activeElement;
    jobId = null;
    jobFails = 0;

    elSIcon.textContent = '';
    elSIcon.appendChild(iconNode(svc));
    text(elSTitle, (attachId ? ACTIONS[verb].gerund + ' ' : 'Deploy ') + (svc.name || svc.key));
    text(elSSub, svc.key + (host ? ' · ' + host : ''));

    elSBody.textContent = '';
    elSBody.appendChild(document.createTextNode('This runs this service’s '));
    elSBody.appendChild(text(make('code'), 'setup.sh'));
    elSBody.appendChild(document.createTextNode(
      ' on the server. It installs packages, writes config, and starts a systemd unit — it can take several minutes and it changes the machine. Nothing happens until you confirm.'));

    elSAlert.hidden = true;
    elSAlert.textContent = '';
    elSRun.hidden = true;
    elLog.textContent = '';
    elActions.hidden = false;

    elCancel.disabled = false;
    elConfirm.disabled = false;
    elConfirm.hidden = false;
    elConfirm.className = 'btn btn-primary';
    text(elCancel, 'Cancel');
    text(elConfirm, 'Deploy');

    elScrim.hidden = false;
    elSheet.hidden = false;
    document.body.classList.add('is-locked');

    if (attachId) attachJob(attachId, svc, verb);

    // Focus the safe button, not the destructive one.
    setTimeout(function () { elCancel.focus(); }, 0);
  }

  /* Reattach to a job that is already running on the server — a deploy, or a
     start/stop someone kicked off from the detail page: show the log view
     straight away and resume polling, instead of POSTing a second one the
     backend would reject with 409. */
  function attachJob(id, svc, action) {
    var verb = actionDef(action) ? action : 'deploy';
    jobId = id;
    jobFails = 0;
    sheetAction = verb;

    elSBody.textContent = '';
    elSBody.appendChild(document.createTextNode(
      'A ' + verb + ' for this service is already running on the server. This is that job’s live log — you can close this and come back to it.'));

    elActions.hidden = false;
    elConfirm.hidden = true;
    elCancel.disabled = false;
    text(elCancel, 'Close');

    elSRun.hidden = false;
    setPill('pill-run', 'Running');
    text(elRunExit, '');
    text(elLog, 'Attaching to job ' + id + '…\n');
    say('Reattached to the running ' + verb + ' for ' + ((svc && (svc.name || svc.key)) || 'this service'));
    pollJob();
  }

  function closeSheet() {
    stopJobPolling();
    elSheet.hidden = true;
    elScrim.hidden = true;
    document.body.classList.remove('is-locked');
    sheetService = null;
    sheetAction = 'deploy';
    /* The job may still be running; from here on the grid's own `job` field is
       what keeps the detail buttons out of the way, so this flag is done. */
    actionBusy = false;
    jobId = null;
    if (lastFocused && document.contains(lastFocused) && lastFocused.focus) {
      lastFocused.focus();
    }
    lastFocused = null;
    load(true);
  }

  function alertSheet(message) {
    text(elSAlert, message);
    elSAlert.hidden = false;
  }

  function setPill(cls, label) {
    elRunPill.className = 'pill ' + cls;
    text(elRunPill, label);
  }

  function confirmDeploy() {
    if (!sheetService) return;
    var key = sheetService.key;

    elConfirm.disabled = true;
    elCancel.disabled = true;
    elSAlert.hidden = true;
    text(elConfirm, 'Starting…');

    request('api/services/' + encodeURIComponent(key) + '/deploy', { method: 'POST' })
      .then(function (res) {
        if (res.status === 409) {
          /* Someone (or another tab) already started this. If the API can
             tell us which job, attach to it; otherwise say so plainly. */
          var known = res.data && (res.data.job_id || (res.data.job && res.data.job.id));
          if (known) { attachJob(String(known), sheetService); return; }
          load(true).then(function () {
            var live = sheetService ? liveJob(find(sheetService.key)) : null;
            if (live && sheetService) attachJob(live, sheetService);
            else resetAfterError('A deploy for this service is already running. Wait for it to finish, then try again.');
          });
          return;
        }
        if (res.status === 429) {
          resetAfterError('Too many deploys are running right now. Wait for one to finish, then try again.');
          return;
        }
        if (!res.ok || !res.data || !res.data.job_id) {
          var detail = (res.data && (res.data.error || res.data.message)) || ('HTTP ' + res.status);
          resetAfterError('The server refused to start the deploy: ' + detail);
          return;
        }

        jobId = res.data.job_id;
        jobFails = 0;
        elActions.hidden = false;
        text(elCancel, 'Close');
        elCancel.disabled = false;
        elConfirm.hidden = true;
        elSRun.hidden = false;
        setPill('pill-run', 'Running');
        text(elRunExit, '');
        text(elLog, 'Starting ' + key + '…\n');
        say('Deploying ' + key);
        pollJob();
      }, function () {
        resetAfterError('Could not reach the server to start the deploy.');
      });
  }

  function resetAfterError(message) {
    alertSheet(message);
    elConfirm.disabled = false;
    elCancel.disabled = false;
    text(elConfirm, 'Deploy');
  }

  /* ---------- start / stop / restart ----------
   *
   * A lifecycle action is a job like any other: POST once, get a job id back,
   * then hand it to the same poll loop, the same log pane and the same exit
   * pill the deploy uses. The only things new here are the confirm copy and
   * the refusals (403 for a service the server will not control at all).
   */

  function nameOf(svc) { return (svc && (svc.name || svc.key)) || 'this service'; }

  function actionBlurb(action, svc) {
    var name = nameOf(svc);
    if (action === 'start') {
      return 'This brings ' + name + ' back up on the server, its parts in the ' +
             'order they need. Starting something that is already down cannot ' +
             'lose anything, so it is running already — the log below is live.';
    }
    if (action === 'restart') {
      return 'This stops ' + name + ' and starts it again. It is offline for ' +
             'the seconds in between, and anything mid-request is dropped. ' +
             'Nothing happens until you confirm.';
    }
    if (action === 'remove') {
      return 'This takes ' + name + ' off the box: its uptime monitor is paused, ' +
             'then its teardown.sh stops it and takes its address off the tailnet. ' +
             'Its data and .env stay where they are, so Install brings it back as ' +
             'it was. Deleting the data is deliberately not here: run ' +
             'teardown.sh --purge in a terminal for that. Nothing happens until ' +
             'you confirm.';
    }
    return 'This stops ' + name + ' on the server. Its containers and units go ' +
           'down in order; nothing is deleted, and Start brings it back. Until ' +
           'then anything pointed at it — a phone app, a backup, another ' +
           'service — fails. Nothing happens until you confirm.';
  }

  /* Is this page being served by the very thing you are about to stop?
     Same-origin is the certain case. code-server is the hard-coded one: it is
     the browser IDE on this box, so it is plausibly the window you are reading
     this in even when the launcher is on its own port, and it is the one
     service whose stop takes your view of it with it. */
  function selfServed(svc) {
    if (!svc) return false;
    if (svc.key === 'code-server') return true;
    if (!svc.url) return false;
    var probe = document.createElement('a');
    probe.href = svc.url;
    return probe.protocol === location.protocol && probe.host === location.host;
  }

  function actionWarning(action, svc) {
    if (action === 'start' || !selfServed(svc)) return null;
    var name = nameOf(svc);
    return 'You may be reading this inside ' + name + '. ' +
           (action === 'stop'
             ? 'Stopping it closes that window. The launcher is its own service and stays up, so you can start ' + name + ' again from here — reach it on the launcher’s own port if you have to.'
             : 'Restarting it drops that window for a few seconds; it should come back on its own.');
  }

  /* Opens the sheet for one lifecycle action. `stop` and `restart` wait for an
     explicit confirm, exactly as a deploy does. `start` does not: it is the
     recovery action, and putting a "are you sure you want it back" in front of
     it would be theatre. */
  function openActionSheet(svc, action, opener) {
    var def = actionDef(action);
    if (!def || action === 'deploy' || actionBusy) return;

    sheetService = svc;
    sheetAction = action;
    lastFocused = opener || document.activeElement;
    jobId = null;
    jobFails = 0;

    elSIcon.textContent = '';
    elSIcon.appendChild(iconNode(svc));
    text(elSTitle, def.label + ' ' + nameOf(svc));
    text(elSSub, svc.key + (host ? ' · ' + host : ''));

    elSBody.textContent = '';
    elSBody.appendChild(document.createTextNode(actionBlurb(action, svc)));

    elSAlert.hidden = true;
    elSAlert.textContent = '';
    elSRun.hidden = true;
    elLog.textContent = '';
    elActions.hidden = false;

    elCancel.disabled = false;
    elConfirm.disabled = false;
    elConfirm.hidden = false;
    /* The one confirm that takes something down is not the accent colour. */
    elConfirm.className = 'btn btn-primary' +
      (action === 'stop' || action === 'remove' ? ' is-danger' : '');
    text(elCancel, 'Cancel');
    text(elConfirm, def.label);

    elScrim.hidden = false;
    elSheet.hidden = false;
    document.body.classList.add('is-locked');

    var warn = actionWarning(action, svc);
    if (warn) alertSheet(warn);

    if (action === 'start') runAction();

    // Focus the safe button, never the one that takes the service down.
    setTimeout(function () { elCancel.focus(); }, 0);
  }

  /* Permanent refusal: this will not work by trying again, so the confirm
     button goes away and the sheet becomes a message with a Close. */
  function actionRefused(message) {
    actionBusy = false;
    alertSheet(message);
    elConfirm.hidden = true;
    elCancel.disabled = false;
    text(elCancel, 'Close');
    load(true);
  }

  /* Transient refusal: something else is going on right now. Leave the button
     armed so the same tap works once it clears. */
  function actionRetry(message) {
    actionBusy = false;
    alertSheet(message);
    elConfirm.disabled = false;
    elCancel.disabled = false;
    text(elConfirm, ACTIONS[actionDef(sheetAction) ? sheetAction : 'deploy'].label);
    if (detailSvc) paintControls(detailSvc);
  }

  function runAction() {
    if (!sheetService) return;
    var key = sheetService.key;
    var action = sheetAction;
    var def = actionDef(action);
    if (!def) return;

    actionBusy = true;
    elConfirm.disabled = true;
    elCancel.disabled = true;
    elSAlert.hidden = true;
    text(elConfirm, def.busy);
    if (detailSvc) paintControls(detailSvc);

    request('api/services/' + encodeURIComponent(key) + '/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: action })
    }).then(function (res) {
      /* The sheet can be dismissed while this is in flight (scrim, Escape).
         The job is the server's now; leave it alone and let the grid pick it
         up on the next refresh. */
      if (!sheetService || sheetService.key !== key) { actionBusy = false; return; }

      if (res.ok && res.data && res.data.job_id) {
        jobId = String(res.data.job_id);
        jobFails = 0;
        elActions.hidden = false;
        text(elCancel, 'Close');
        elCancel.disabled = false;
        elConfirm.hidden = true;
        elSRun.hidden = false;
        setPill('pill-run', 'Running');
        text(elRunExit, '');
        text(elLog, def.gerund + ' ' + key + '…\n');
        say(def.gerund + ' ' + key);
        pollJob();
        return;
      }

      if (res.status === 403) {
        /* The server's own sentence for why this one is off limits — the same
           text the buttons would have shown, so the two never disagree. */
        actionRefused(msgFrom(res, 'The server will not ' + action + ' this service.'));
        return;
      }
      if (res.status === 404) {
        /* Either the key is gone, or this launcher predates the endpoint. */
        actionRefused(loaded && !find(key)
          ? 'There is no service called “' + key + '” in the registry any more.'
          : 'This launcher’s API cannot start or stop services yet — that endpoint is not in the version running on the box.');
        return;
      }
      if (res.status === 409) {
        /* Something else already holds this service's one job slot. Attach to
           it rather than telling the user to come back later. */
        load(true).then(function () {
          var fresh = find(key);
          var live = liveJob(fresh);
          if (live && sheetService && sheetService.key === key) {
            actionBusy = false;
            attachJob(live, fresh, jobAction(fresh));
            return;
          }
          /* No job holds the slot, so the 409 is the server refusing for a
             reason that will not clear by retrying (e.g. already removed
             from another tab). Say its sentence and stop offering. */
          actionRefused(msgFrom(res, 'The server will not ' + action + ' this service right now.'));
        });
        return;
      }
      if (res.status === 429) {
        actionRetry('Too many jobs are running right now. Wait for one to finish, then try again.');
        return;
      }
      actionRefused('The server refused to ' + action + ' this service: ' +
                    msgFrom(res, 'HTTP ' + res.status) + '.');
    }, function () {
      if (!sheetService || sheetService.key !== key) { actionBusy = false; return; }
      actionRetry('Could not reach the server to ' + action + ' this service.');
    });
  }

  function atBottom(node) {
    return node.scrollTop + node.clientHeight >= node.scrollHeight - 24;
  }

  function pollJob() {
    if (!jobId) return;
    var id = jobId;

    request('api/jobs/' + encodeURIComponent(id)).then(function (res) {
      if (jobId !== id) return;   // sheet moved on

      if (!res.ok || !res.data) {
        jobFails++;
        if (jobFails >= MAX_POLL_FAILS) {
          setPill('pill-fail', 'Unknown');
          alertSheet('Lost contact with the job while it was running. It may still be going — reopen this later or check the server.');
          return;
        }
        jobTimer = setTimeout(pollJob, JOB_POLL_MS);
        return;
      }

      jobFails = 0;
      var job = res.data;
      /* The job record knows which verb it is running; trust it over whatever
         the sheet assumed when it attached. */
      if (actionDef(job.action)) sheetAction = job.action;
      var stick = atBottom(elLog);
      var log = typeof job.log === 'string' ? job.log : '';
      if (log !== elLog.textContent) {
        text(elLog, log);
        if (stick) elLog.scrollTop = elLog.scrollHeight;
      }

      if (job.status === 'running') {
        jobTimer = setTimeout(pollJob, JOB_POLL_MS);
        return;
      }

      var code = (job.exit_code === null || job.exit_code === undefined) ? '?' : job.exit_code;
      var verb = ACTIONS[actionDef(sheetAction) ? sheetAction : 'deploy'];
      if (job.status === 'done') {
        setPill('pill-done', 'Done');
        text(elRunExit, 'exit ' + code);
        say(verb.label + ' finished, exit code ' + code);
      } else {
        setPill('pill-fail', 'Failed');
        text(elRunExit, 'exit ' + code);
        alertSheet(job.refused
          ? 'The ' + sheetAction + ' was refused by this service\'s safety check, so nothing was changed. The last lines of the log above say why.'
          : sheetAction === 'deploy'
          ? 'The setup script exited with code ' + code + '. The log above has the details; nothing was rolled back.'
          : 'The ' + sheetAction + ' exited with code ' + code + '. The log above has the details, and the service may be part way between states.');
        say(verb.label + ' failed, exit code ' + code);
      }
      elLog.scrollTop = elLog.scrollHeight;
      jobId = null;
      actionBusy = false;
      load(true);
      /* Health probes are cached for a few seconds on the server, so the
         refresh above can still be looking at the world as it was before the
         action. One late refetch settles the dot and the buttons. */
      if (sheetAction !== 'deploy') settle();
    }, function () {
      if (jobId !== id) return;
      jobFails++;
      if (jobFails >= MAX_POLL_FAILS) {
        setPill('pill-fail', 'Unknown');
        alertSheet('Lost contact with the job while it was running. It may still be going — reopen this later or check the server.');
        return;
      }
      jobTimer = setTimeout(pollJob, JOB_POLL_MS);
    });
  }

  function stopJobPolling() {
    if (jobTimer) { clearTimeout(jobTimer); jobTimer = null; }
    jobId = null;
    elConfirm.hidden = false;
  }

  /* One forced refetch a few seconds out, for the case where the truth has
     changed but the server's health cache has not caught up yet. */
  function settle() {
    if (settleTimer) clearTimeout(settleTimer);
    settleTimer = setTimeout(function () {
      settleTimer = null;
      load(true);
    }, 6500);
  }

  /* ---------- detail page ----------
   *
   * Same document, hash-routed. The grid is hidden rather than torn down, so
   * the tab, the filter text and the scroll position are all still there when
   * you come back.
   */

  function msgFrom(res, fallback) {
    var m = res && res.data && (res.data.error || res.data.message || res.data.detail);
    return (typeof m === 'string' && m) ? m : fallback;
  }

  function statusOf(svc) {
    if (liveJob(svc)) return { cls: 'dot-job', label: jobLabel(svc) };
    switch (svc && svc.state) {
      case 'active':    return { cls: 'dot-ok',   label: 'Running' };
      case 'stopped':   return { cls: 'dot-warn', label: 'Not responding' };
      case 'available': return { cls: 'dot-off',  label: 'Not deployed' };
      default:          return { cls: 'dot-off',  label: 'Planned' };
    }
  }

  function chip(cls, value) {
    elDSub.appendChild(text(make('span', 'd-sep'), '·'));
    elDSub.appendChild(text(make('span', cls), value));
  }

  function paintHead(svc) {
    elDIcon.textContent = '';
    elDIcon.appendChild(iconNode(svc));

    text(elDTitle, svc.name || svc.key);
    document.title = (svc.name || svc.key) + ' · Launcher';

    var st = statusOf(svc);
    elDSub.textContent = '';
    var dot = make('i', 'dot ' + st.cls);
    dot.setAttribute('aria-hidden', 'true');
    elDSub.appendChild(dot);
    elDSub.appendChild(text(make('span'), st.label));
    if (svc.tagline) chip('', svc.tagline);
    if (!svc.url && (svc.state === 'active' || svc.state === 'stopped')) chip('', 'no web interface');
    chip('d-key', svc.key);

    paintControls(svc);
    paintStrip(svc);
  }

  /* The Umbrel app-page strip: the handful of facts you scan before touching
     anything — what kind of thing this is, whether it is up, where it lives,
     whose it is, when it last deployed. Cells render only when they have a
     value; an all-empty strip hides itself. */
  function stripDate(v) {
    /* epoch float (marker mtime) or an ISO string, -> yyyy-mm-dd */
    var t = typeof v === 'number' ? v * 1000 : Date.parse(v || '');
    if (!t || isNaN(t)) return null;
    var d = new Date(t);
    var p = function (n) { return String(n).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  function paintStrip(svc) {
    if (!elDStrip) return;
    elDStrip.textContent = '';
    var st = statusOf(svc);
    var host = null;
    if (svc.url) {
      try { host = new URL(svc.url).host; } catch (e) { host = svc.url; }
    }
    var deploy = svc.receipt && svc.receipt.deployed_at
      ? stripDate(svc.receipt.deployed_at) : stripDate(svc.deployed_at);
    var cells = [
      ['Category', groupLabel(svc.group) || svc.group || null],
      ['Status', st.label, st.cls],
      ['Address', host],
      ['Author', svc.author || null],
      ['Last deploy', deploy]
    ];
    var shown = 0;
    for (var i = 0; i < cells.length; i++) {
      if (cells[i][1] === null || cells[i][1] === undefined || cells[i][1] === '') continue;
      var cell = make('div', 'd-strip-cell');
      cell.appendChild(text(make('dt', 'd-strip-k'), cells[i][0]));
      var dd = make('dd', 'd-strip-v');
      if (cells[i][2]) {
        var d2 = make('i', 'dot ' + cells[i][2]);
        d2.setAttribute('aria-hidden', 'true');
        dd.appendChild(d2);
      }
      dd.appendChild(document.createTextNode(cells[i][1]));
      cell.appendChild(dd);
      elDStrip.appendChild(cell);
      shown++;
    }
    elDStrip.hidden = shown === 0;
  }

  /* --- start / stop / restart, on the head row ----------------------------
   *
   * The controls live on the same line as the icon and the title, hard right,
   * and are built here rather than in index.html because this module owns
   * every one of their states. What is offered follows the service, and
   * matches the ntfy panel on the phone: something running offers Restart and
   * Stop, something down offers Start, and a service the server will not
   * control offers nothing at all — with the server's own sentence for why.
   */

  var elDHead = elVDetail ? elVDetail.querySelector('.d-head') : null;
  var elCtl = null;       // the button group
  var elCtlWhy = null;    // full-width line under it, for a locked service
  var ctlSig = null;      // don't rebuild the buttons under the user's finger

  function ctlMount() {
    if (elCtl || !elDHead) return elCtl;
    elCtl = make('div', 'd-ctl');
    elCtlWhy = make('p', 'd-ctl-why');
    elCtlWhy.hidden = true;
    elDHead.appendChild(elCtl);
    elDHead.appendChild(elCtlWhy);
    return elCtl;
  }

  function clearControls() {
    ctlSig = null;
    if (!elCtl) return;
    elCtl.textContent = '';
    text(elCtlWhy, '');
    elCtlWhy.hidden = true;
  }

  function ctlButton(label, cls, onClick) {
    var b = make('button', 'd-ctl-btn' + (cls ? ' ' + cls : ''));
    b.type = 'button';
    text(b, label);
    b.addEventListener('click', function () {
      if (b.disabled) return;
      onClick(b);
    });
    return b;
  }

  function actionButton(svc, action) {
    var def = ACTIONS[action];
    var b = ctlButton(def.label,
      action === 'start' ? 'is-primary'
        : (action === 'stop' || action === 'remove' ? 'is-danger' : ''),
      function (node) { openActionSheet(svc, action, node); });
    b.setAttribute('aria-label', def.label + ' ' + nameOf(svc));
    return b;
  }

  /* What the payload says about controlling this one. `control` is
     {controllable, reason}; a backend that predates it sends nothing, and then
     we cannot tell — so we offer the buttons to installed services anyway and
     let the 403 explain itself. Never the other way round: guessing
     "controllable: false" would hide a button that does work. */
  function controlState(svc) {
    var c = svc && svc.control;
    if (!c || typeof c !== 'object') return { known: false, on: true, reason: '' };
    return {
      known: true,
      on: c.controllable === true,
      reason: typeof c.reason === 'string' ? c.reason : ''
    };
  }

  /* The server's reason, as a sentence. Capitalised — except when it opens on
     the service's own name: this box runs things called ntfy and ollama, and
     "Ollama is a system unit" would be wrong in a way the reader would
     notice. */
  function sentence(s, key) {
    if (!s) return '';
    var lead = (key && s.split(/\s/)[0] === key)
      ? s : s.charAt(0).toUpperCase() + s.slice(1);
    return lead + (/[.!?]$/.test(s) ? '' : '.');
  }

  function paintControls(svc) {
    if (!ctlMount()) return;

    var state = svc && svc.state;
    var installed = state === 'active' || state === 'stopped';
    var ctl = controlState(svc);
    var job = liveJob(svc);
    var sig = [state, svc && svc.url, ctl.on, ctl.reason, job, jobAction(svc),
               actionBusy, svc && svc.removable === true].join('|');
    if (sig === ctlSig) return;
    ctlSig = sig;

    elCtl.textContent = '';
    text(elCtlWhy, '');
    elCtlWhy.hidden = true;

    /* Umbrel app-page CTA first: the one thing you most likely came to do —
       open a running service, or install one that is not on the box yet. It
       precedes even the lifecycle buttons, so it sits where the store puts
       its own primary action: top right of the hero. */
    if (state === 'active' && svc.url) {
      elCtl.appendChild(ctlButton('Open', 'is-primary', function () {
        VIEW.touch(svc.key, 'launched');
        window.open(svc.url, '_blank', 'noopener');
      }));
    } else if (state === 'available') {
      elCtl.appendChild(ctlButton('Install', 'is-primary', function (node) {
        openSheet(svc, node);
      }));
    }

    /* Not on the box: there is nothing to start or stop beyond the Install
       above. */
    if (!installed) return;

    if (!ctl.on) {
      var lock = make('span', 'd-ctl-lock');
      lock.appendChild(glyph(GLYPHS.lock, '1.5'));
      lock.appendChild(text(make('span'), 'Locked'));
      elCtl.appendChild(lock);
      if (ctl.reason) {
        text(elCtlWhy, sentence(ctl.reason, svc && svc.key));
        elCtlWhy.hidden = false;
      }
      return;
    }

    if (job) {
      /* One job at a time per service, server-side. So while one is running
         there is nothing to offer but a way back into its log. */
      var watch = ctlButton('View log', '', function (node) {
        openSheet(svc, node, job, jobAction(svc));
      });
      watch.setAttribute('aria-label', jobLabel(svc) + ' — view the log');
      elCtl.appendChild(watch);
      return;
    }

    var buttons = state === 'active'
      ? [actionButton(svc, 'restart'), actionButton(svc, 'stop')]
      : [actionButton(svc, 'start')];
    /* Only when the service ships a teardown.sh: the server says so. */
    if (svc.removable === true) buttons.push(actionButton(svc, 'remove'));

    for (var i = 0; i < buttons.length; i++) {
      if (actionBusy) buttons[i].disabled = true;   // a POST is already out
      elCtl.appendChild(buttons[i]);
    }
  }

  /* --- registry meta --- */

  var META_LABELS = {
    setup: 'Setup script', health: 'Health probe', marker: 'Marker path',
    url: 'URL', port: 'Port', ports: 'Ports', icon: 'Icon', key: 'Key',
    env: 'Env file', unit: 'systemd unit', dir: 'Directory', log: 'Log',
    installed: 'Installed', last_deploy: 'Last deploy', revision: 'Revision'
  };

  /* The install receipt (written by the server on each successful deploy
     from here) as extra meta rows. Absent receipt: no rows, which is the
     normal case for anything deployed from a terminal. */
  function shortDate(iso) {
    return typeof iso === 'string' && iso.length >= 10 ? iso.slice(0, 10) : null;
  }

  function withReceipt(meta, r) {
    var out = {}, k;
    if (meta && typeof meta === 'object' && !Array.isArray(meta)) {
      for (k in meta) if (Object.prototype.hasOwnProperty.call(meta, k)) out[k] = meta[k];
    }
    if (!r || typeof r !== 'object' || Array.isArray(r)) return out;
    out.installed = shortDate(r.installed_at);
    var last = shortDate(r.deployed_at);
    if (last) {
      out.last_deploy = last + (typeof r.deploys === 'number'
        ? ' (' + r.deploys + (r.deploys === 1 ? ' deploy)' : ' deploys)') : '');
    }
    if (typeof r.revision === 'string' && r.revision) {
      out.revision = r.revision.slice(0, 7) + (r.repo ? ' in ' + r.repo : '');
    }
    var ports = [], p = r.ports;
    if (p && typeof p === 'object' && !Array.isArray(p)) {
      for (k in p) if (Object.prototype.hasOwnProperty.call(p, k)) ports.push(k + ' ' + p[k]);
    }
    if (ports.length) out.ports = ports.join(', ');
    return out;
  }

  function humanize(k) {
    if (Object.prototype.hasOwnProperty.call(META_LABELS, k)) return META_LABELS[k];
    var s = String(k).replace(/[_-]+/g, ' ');
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function metaValue(v) {
    if (v === null || v === undefined || v === '') return null;
    if (typeof v === 'boolean') return v ? 'yes' : 'no';
    if (Array.isArray(v)) {
      var parts = [];
      for (var i = 0; i < v.length; i++) {
        var one = metaValue(v[i]);
        if (one !== null) parts.push(one);
      }
      return parts.length ? parts.join(', ') : null;
    }
    if (typeof v === 'object') {
      try { return JSON.stringify(v); } catch (e) { return null; }
    }
    return String(v);
  }

  function paintMeta(meta) {
    elMeta.textContent = '';
    if (!meta || typeof meta !== 'object' || Array.isArray(meta)) {
      elMetaSec.hidden = true;
      return;
    }
    var keys = [], k;
    for (k in meta) if (Object.prototype.hasOwnProperty.call(meta, k)) keys.push(k);
    if (!keys.length) { elMetaSec.hidden = true; return; }

    for (var i = 0; i < keys.length; i++) {
      var value = metaValue(meta[keys[i]]);
      elMeta.appendChild(text(make('dt'), humanize(keys[i])));
      elMeta.appendChild(value === null
        ? text(make('dd', 'is-none'), 'none')
        : text(make('dd'), value));
    }
    elMetaSec.hidden = false;
  }

  /* --- environment variables --- */

  var MASK = '••••••••••';

  /* In-memory only, for this page view. Keys are prefixed so a variable
     called __proto__ cannot reach Object.prototype. */
  function cached(name) {
    return Object.prototype.hasOwnProperty.call(revealed, '=' + name) ? revealed['=' + name] : null;
  }

  /* One explicit POST per variable, on demand. Never a GET: a reveal must not
     be prefetchable, linkable or left in history. */
  function reveal(key, name) {
    var hit = cached(name);
    if (hit !== null) return Promise.resolve(hit);

    return request('api/services/' + encodeURIComponent(key) +
                   '/env/' + encodeURIComponent(name) + '/reveal', { method: 'POST' })
      .then(function (res) {
        if (detailKey !== key) throw new Error('cancelled');
        if (res.status === 404) throw new Error('That variable is not in the env file any more.');
        if (!res.ok || !res.data || typeof res.data.value !== 'string') {
          throw new Error(msgFrom(res, 'Could not read that value (HTTP ' + res.status + ').'));
        }
        revealed['=' + name] = res.data.value;
        return res.data.value;
      }, function (err) {
        if (err && err.message) throw err;
        throw new Error('Could not reach the server to read that value.');
      });
  }

  function copyText(value) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(value);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = value;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-1000px';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);      // gone again immediately
      if (ok) resolve(); else reject(new Error('This browser would not copy it.'));
    });
  }

  function setEye(btn, on, name) {
    btn.textContent = '';
    btn.appendChild(glyph(on ? GLYPHS.eyeOff : GLYPHS.eye, '1.5'));
    btn.className = 'env-btn' + (on ? ' is-on' : '');
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    btn.setAttribute('aria-label', (on ? 'Hide ' : 'Show ') + name);
    btn.setAttribute('title', (on ? 'Hide ' : 'Show ') + name);
  }

  function envRow(key, v) {
    var name = String((v && v.name) || '');
    var secret = !(v && v.secret === false);   // unknown flag ⇒ treat as secret
    var inline = (v && typeof v.value === 'string') ? v.value : null;
    if (inline !== null) revealed['=' + name] = inline;

    var dd = make('dd');
    var field = make('div', 'env-field');
    var val = make('span', 'env-value');
    var err = make('p', 'env-err');
    err.hidden = true;
    var shown = false;

    function showValue(value) {
      shown = true;
      val.className = 'env-value' + (value === '' ? ' is-empty' : '');
      text(val, value === '' ? 'empty' : value);
    }
    function showMask() {
      shown = false;
      val.className = 'env-value is-masked';
      text(val, MASK);
    }
    function note(message, ok) {
      text(err, message);
      err.className = 'env-err' + (ok ? ' is-ok' : '');
      err.hidden = false;
    }

    field.appendChild(val);

    var copy = make('button', 'env-btn');
    copy.type = 'button';
    copy.appendChild(glyph(GLYPHS.copy, '1.5'));
    copy.setAttribute('aria-label', 'Copy ' + name);
    copy.setAttribute('title', 'Copy ' + name);
    copy.addEventListener('click', function () {
      err.hidden = true;
      copy.disabled = true;
      reveal(key, name).then(copyText).then(function () {
        copy.disabled = false;
        copy.className = 'env-btn is-done';
        copy.textContent = '';
        copy.appendChild(glyph(GLYPHS.check, '1.8'));
        say(name + ' copied');
        setTimeout(function () {
          copy.className = 'env-btn';
          copy.textContent = '';
          copy.appendChild(glyph(GLYPHS.copy, '1.5'));
        }, 1400);
      }, function (e) {
        copy.disabled = false;
        if (e && e.message === 'cancelled') return;
        note((e && e.message) || 'Could not copy that value.');
      });
    });
    field.appendChild(copy);

    /* --- edit: the value becomes an input and the buttons become save /
       cancel. The current value is fetched (revealed) first so the box
       starts full — you are usually changing one character of a URL, or
       pasting a password you just reset inside the app itself. */
    var eye = null;
    var editing = false;
    var input = null, save = null, cancel = null;

    var edit = make('button', 'env-btn');
    edit.type = 'button';
    edit.appendChild(glyph(GLYPHS.pencil, '1.5'));
    edit.setAttribute('aria-label', 'Edit ' + name);
    edit.setAttribute('title', 'Edit ' + name);

    function setBusy(busy) {
      if (input) input.disabled = busy;
      if (save) save.disabled = busy;
      if (cancel) cancel.disabled = busy;
    }

    function leaveEdit() {
      editing = false;
      if (input && input.parentNode) field.removeChild(input);
      if (save && save.parentNode) field.removeChild(save);
      if (cancel && cancel.parentNode) field.removeChild(cancel);
      input = save = cancel = null;
      val.hidden = false;
      copy.hidden = false;
      edit.hidden = false;
      if (eye) eye.hidden = false;
      field.className = 'env-field';
    }

    function restartHint() {
      var who = (detailSvc && detailSvc.name) || 'the service';
      return 'Saved to the env file. ' + who + ' reads it again on its next restart.';
    }

    function commitEdit() {
      if (!input || input.disabled) return;
      var value = input.value;
      if (value === cached(name)) { leaveEdit(); edit.focus(); return; }
      err.hidden = true;
      setBusy(true);
      request('api/services/' + encodeURIComponent(key) +
              '/env/' + encodeURIComponent(name), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value: value })
      }).then(function (res) {
        if (detailKey !== key) return;
        if (!res.ok) {
          setBusy(false);
          if (input) input.focus();
          note(res.status === 404
            ? 'That variable is not in the env file any more.'
            : msgFrom(res, res.status === 400
                ? 'The server would not accept that value.'
                : 'Could not save that (HTTP ' + res.status + ').'));
          return;
        }
        revealed['=' + name] = value;
        leaveEdit();
        if (secret) { showMask(); if (eye) setEye(eye, false, name); }
        else { showValue(value); }
        note(restartHint(), true);
        say(name + ' saved');
        edit.focus();
      }, function () {
        if (detailKey !== key) return;
        setBusy(false);
        if (input) input.focus();
        note('Could not reach the server to save that.');
      });
    }

    function enterEdit(current) {
      editing = true;
      err.hidden = true;

      input = make('input', 'env-input');
      input.type = 'text';
      input.value = current;
      input.setAttribute('aria-label', name);
      input.setAttribute('autocomplete', 'off');
      input.setAttribute('autocapitalize', 'off');
      input.setAttribute('autocorrect', 'off');
      input.setAttribute('spellcheck', 'false');
      input.setAttribute('enterkeyhint', 'done');

      save = make('button', 'env-btn is-on');
      save.type = 'button';
      save.appendChild(glyph(GLYPHS.check, '1.8'));
      save.setAttribute('aria-label', 'Save ' + name);
      save.setAttribute('title', 'Save (Enter)');

      cancel = make('button', 'env-btn');
      cancel.type = 'button';
      cancel.appendChild(glyph(GLYPHS.cross, '1.6'));
      cancel.setAttribute('aria-label', 'Cancel editing ' + name);
      cancel.setAttribute('title', 'Cancel (Esc)');

      val.hidden = true;
      copy.hidden = true;
      edit.hidden = true;
      if (eye) eye.hidden = true;
      field.className = 'env-field is-editing';
      field.insertBefore(input, val);
      field.appendChild(save);
      field.appendChild(cancel);

      save.addEventListener('click', commitEdit);
      cancel.addEventListener('click', function () {
        leaveEdit();
        say('Edit cancelled');
        edit.focus();
      });
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); commitEdit(); }
        else if (e.key === 'Escape' || e.key === 'Esc') {
          e.preventDefault();
          leaveEdit();
          say('Edit cancelled');
          edit.focus();
        }
      });

      input.focus();
      input.select();     /* a replaced password is typed over, not appended to */
    }

    edit.addEventListener('click', function () {
      if (editing) return;
      err.hidden = true;
      edit.disabled = true;
      reveal(key, name).then(function (value) {
        edit.disabled = false;
        if (detailKey !== key) return;
        enterEdit(value);
      }, function (e) {
        edit.disabled = false;
        if (e && e.message === 'cancelled') return;
        note((e && e.message) || 'Could not read the current value to edit it.');
      });
    });
    field.appendChild(edit);

    if (secret) {
      showMask();
      eye = make('button', 'env-btn');
      eye.type = 'button';
      setEye(eye, false, name);
      eye.addEventListener('click', function () {
        err.hidden = true;
        if (shown) { showMask(); setEye(eye, false, name); say(name + ' hidden'); return; }
        eye.disabled = true;
        reveal(key, name).then(function (value) {
          eye.disabled = false;
          if (detailKey !== key) return;
          showValue(value);
          setEye(eye, true, name);
          say(name + ' revealed');
        }, function (e) {
          eye.disabled = false;
          if (e && e.message === 'cancelled') return;
          showMask();
          setEye(eye, false, name);
          note((e && e.message) || 'Could not read that value.');
        });
      });
      field.appendChild(eye);        /* eye last: at the end of the field */
    } else if (inline !== null) {
      showValue(inline);
    } else {
      /* Not a secret, so it is shown outright — but the value still is not in
         the list payload, so it is fetched the same way, once, on render. */
      val.className = 'env-value is-empty';
      text(val, 'loading…');
      reveal(key, name).then(function (value) {
        if (detailKey !== key) return;
        showValue(value);
      }, function (e) {
        if (e && e.message === 'cancelled') return;
        val.className = 'env-value is-empty';
        text(val, 'unavailable');
        note((e && e.message) || 'Could not read that value.');
      });
    }

    dd.appendChild(field);
    dd.appendChild(err);

    elEnv.appendChild(text(make('dt'), name));
    elEnv.appendChild(dd);
  }

  function paintEnv(env, key) {
    elEnv.textContent = '';
    if (!env || typeof env !== 'object') { elEnvSec.hidden = true; return; }

    elEnvSec.hidden = false;
    var path = typeof env.path === 'string' ? env.path : '';
    text(elEnvPath, path);
    elEnvPath.hidden = !path;

    var vars = Array.isArray(env.vars) ? env.vars : [];
    if (!vars.length) {
      elEnvEmpty.hidden = false;
      text(elEnvEmpty, env.exists === false
        ? (path
            ? 'Nothing there yet — this service has no env file at that path. Its configuration lives in its unit file or its own data directory.'
            : 'This service has no env file. Its configuration lives in its unit file or its own data directory.')
        : 'The env file is there, but it sets no variables.');
      return;
    }
    elEnvEmpty.hidden = true;
    for (var i = 0; i < vars.length; i++) envRow(key, vars[i]);
  }

  /* --- editing --- */

  /* Descriptions are paragraphs, not one-liners: grow the box to the text
     rather than making the reader scroll a four-row window. */
  function autoGrow(el) {
    el.style.height = 'auto';
    var h = el.scrollHeight;
    if (!h) {
      /* Called before the view was unhidden, so nothing is laid out yet and
         scrollHeight is 0. Fall back to the CSS height and measure again once
         the browser has painted. */
      el.style.height = '';
      if (typeof requestAnimationFrame === 'function') {
        requestAnimationFrame(function () { autoGrow(el); });
      }
      return;
    }
    /* `height` is a BORDER-box height here (box-sizing: border-box), and
       scrollHeight measures the padding box. Assigning one to the other loses
       exactly the borders — two pixels off the bottom of the text, for good,
       with a scrollbar that never goes away. Measured, not guessed:
       offsetHeight - clientHeight is that difference. */
    h += el.offsetHeight - el.clientHeight;
    if (h > 340) h = 340;
    el.style.height = h + 'px';
  }

  function saveStatus(message, cls) {
    if (savedFlash) { clearTimeout(savedFlash); savedFlash = null; }
    elDSave.className = 'field-status' + (cls ? ' ' + cls : '');
    text(elDSave, message);
  }

  function patchField(field, value, input) {
    var key = detailKey;
    var body = {};
    body[field] = value;

    input.setAttribute('aria-invalid', 'false');
    saveStatus('Saving…', '');

    request('api/services/' + encodeURIComponent(key), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (res) {
      var live = detailKey === key;      // still on this page?

      if (res.status === 400) {
        if (!live) return;
        input.setAttribute('aria-invalid', 'true');
        saveStatus(msgFrom(res, 'The server would not accept that value.'), 'is-error');
        return;
      }
      if (!res.ok || !res.data || typeof res.data !== 'object') {
        if (!live) return;
        saveStatus(msgFrom(res, 'Could not save that (HTTP ' + res.status + ').'), 'is-error');
        return;
      }

      var d = res.data;
      if (typeof d.name === 'string') savedName = d.name;
      if (typeof d.description === 'string') savedDesc = d.description;

      /* keep the grid honest even if the edit landed as we navigated away */
      var listed = find(key);
      if (listed && savedName) { listed.name = savedName; }
      if (listed && typeof d.description === 'string') listed.description = savedDesc;
      if (loaded) render();

      if (!live) return;

      if (document.activeElement !== elDName) elDName.value = savedName;
      if (document.activeElement !== elDDesc) { elDDesc.value = savedDesc; autoGrow(elDDesc); }
      if (detailSvc) { detailSvc.name = savedName || detailSvc.name; paintHead(detailSvc); }

      var restored = value === '';
      saveStatus(restored ? 'Cleared — back to the shipped default.' : 'Saved.', 'is-saved');
      say(restored ? 'Restored the shipped default' : 'Saved');
      savedFlash = setTimeout(function () { saveStatus('', ''); }, 3200);
    }, function () {
      if (detailKey !== key) return;
      saveStatus('Could not reach the server to save that.', 'is-error');
    });
  }

  function commit(field, input, saved) {
    if (!detailKey || input.disabled) return;
    var value = input.value.replace(/^\s+|\s+$/g, '');
    if (value !== input.value) input.value = value;
    if (value === saved) return;
    patchField(field, value, input);
  }

  elDName.addEventListener('change', function () { commit('name', elDName, savedName); });
  elDDesc.addEventListener('change', function () { commit('description', elDDesc, savedDesc); });
  elDDesc.addEventListener('input', function () { autoGrow(elDDesc); });

  elDName.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); elDName.blur(); }
    else if (e.key === 'Escape' || e.key === 'Esc') { elDName.value = savedName; elDName.blur(); }
  });

  elDDesc.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' || e.key === 'Esc') { elDDesc.value = savedDesc; elDDesc.blur(); }
    else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); elDDesc.blur(); }
  });

  /* --- loading a detail --- */

  function resetDetail() {
    elDNote.hidden = true;
    text(elDNote, '');
    clearControls();
    if (elDStrip) { elDStrip.textContent = ''; elDStrip.hidden = true; }
    elEnv.textContent = '';
    elEnvSec.hidden = true;
    elEnvEmpty.hidden = true;
    elEnvPath.hidden = true;
    elMeta.textContent = '';
    elMetaSec.hidden = true;
    savedName = '';
    savedDesc = '';
    elDName.value = '';
    elDDesc.value = '';
    elDDesc.style.height = '';
    elDName.disabled = true;
    elDDesc.disabled = true;
    elDName.setAttribute('aria-invalid', 'false');
    elDDesc.setAttribute('aria-invalid', 'false');
    saveStatus('', '');
  }

  function detailNote(message) {
    text(elDNote, message);
    elDNote.hidden = false;
  }

  function fetchDetail(key, token) {
    request('api/services/' + encodeURIComponent(key)).then(function (res) {
      if (token !== detailReq) return;

      if (res.status === 404) {
        if (loaded && !find(key)) {
          text(elDTitle, 'Not found');
          document.title = 'Not found · Launcher';
          elDSub.textContent = '';
          detailNote('There is no service called “' + key + '” in the registry.');
        } else {
          detailNote('This launcher’s API does not serve service details yet, so this page shows only what the grid knows.');
        }
        return;
      }
      if (!res.ok || !res.data || typeof res.data !== 'object') {
        detailNote('Could not load the details for this service (HTTP ' + res.status + '). Showing what the grid knows.');
        return;
      }
      paintDetail(res.data, key);
    }, function () {
      if (token !== detailReq) return;
      detailNote('No response from the launcher backend, so this page shows only what the grid knows.');
    });
  }

  function paintDetail(d, key) {
    var known = find(d.key || key) || {};
    var view = {
      key:     d.key || key,
      name:    d.name || known.name || key,
      tagline: d.tagline != null ? d.tagline : known.tagline,
      icon:    d.icon || known.icon,
      url:     d.url !== undefined ? d.url : known.url,
      state:   d.state || known.state,
      job:     d.job !== undefined ? d.job : known.job,
      /* {controllable, reason} — whether this service gets start/stop buttons
         at all. Undefined on a backend that has no lifecycle endpoint. */
      control: d.control !== undefined ? d.control : known.control,
      removable: d.removable !== undefined ? d.removable : known.removable,
      /* Strip cells — the detail payload carries none of author/receipt, so
         they fall back to what the grid already knew. */
      group: d.group || known.group,
      author: known.author,
      deployed_at: d.deployed_at !== undefined ? d.deployed_at : known.deployed_at,
      receipt: d.receipt !== undefined ? d.receipt : known.receipt
    };
    detailSvc = view;
    paintHead(view);

    savedName = typeof d.name === 'string' ? d.name : '';
    savedDesc = typeof d.description === 'string' ? d.description : '';
    elDName.value = savedName;
    elDDesc.value = savedDesc;
    elDName.disabled = false;
    elDDesc.disabled = false;
    autoGrow(elDDesc);

    paintEnv(d.env, view.key);
    paintMeta(withReceipt(d.meta, d.receipt));
    VIEW.detail(view.key, d);
  }

  /* --- routing --- */

  function routeKey() {
    var m = /^#\/service\/(.+)$/.exec(String(location.hash || ''));
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  }

  function openDetail(key) {
    if (detailKey === key) return;
    if (detailKey === null) {
      gridScroll = window.pageYOffset || document.documentElement.scrollTop || 0;
    }

    detailKey = key;
    detailSvc = null;
    revealed = {};
    var token = ++detailReq;

    setBoardChrome(false);
    elVGrid.hidden = true;
    elSearch.hidden = true;
    if (elSearchRow) elSearchRow.hidden = true;
    elHead.hidden = true;
    elVDetail.hidden = false;
    resetDetail();

    /* Opening the page is a "use" in its own right; the launch click is the
       other one. Fire and forget, like that one. */
    VIEW.touch(key, 'opened');

    var known = find(key);
    VIEW.detail(key, known);
    if (known) {
      detailSvc = known;
      paintHead(known);
    } else {
      elDIcon.textContent = '';
      text(elDTitle, key);
      document.title = key + ' · Launcher';
      elDSub.textContent = '';
    }

    window.scrollTo(0, 0);
    try { elDBack.focus({ preventScroll: true }); } catch (e) { elDBack.focus(); }

    if (!loaded && !inflight) load(true);
    fetchDetail(key, token);
  }

  function closeDetail() {
    if (detailKey === null) return;
    var key = detailKey;

    detailKey = null;
    detailReq++;              // any in-flight paint is now stale
    detailSvc = null;
    revealed = {};            // revealed secrets do not survive leaving the page
    elEnv.textContent = '';   // and none of them stay in the DOM either
    VIEW.detail(null, null);
    document.title = 'Launcher';

    elVDetail.hidden = true;
    elVGrid.hidden = false;
    setBoardChrome(VIEW.mode() === 'board');
    elSearch.hidden = false;
    if (elSearchRow) elSearchRow.hidden = false;
    elHead.hidden = false;

    var target = null;
    for (var i = 0; i < elGrid.childNodes.length; i++) {
      var tile = elGrid.childNodes[i];
      if (tile.getAttribute && tile.getAttribute('data-key') === key) {
        target = tile.querySelector ? tile.querySelector('[data-more]') : null;
      }
    }
    if (target) {
      try { target.focus({ preventScroll: true }); } catch (e) { /* older Safari */ }
    }
    window.scrollTo(0, gridScroll);
  }

  /* #/catalogue is painted by catalogue.js; this side only gets the grid
     out of its way and back again. */
  function isCatalogueRoute() {
    return String(location.hash || '') === '#/catalogue';
  }

  function showGrid(on) {
    elVGrid.hidden = !on;
    elSearch.hidden = !on;
    if (elSearchRow) elSearchRow.hidden = !on;
    setBoardChrome(on && VIEW.mode() === 'board');
  }

  function route() {
    var key = routeKey();
    if (key) { openDetail(key); return; }
    closeDetail();
    showGrid(!isCatalogueRoute());
  }

  /* The small surface catalogue.js needs: the list the grid already polls,
     and the grid's own deploy sheet, so an install from the catalogue is the
     same confirm-then-log flow as a tap on a dimmed tile. */
  window.LauncherApp = {
    loaded: function () { return loaded; },
    error: function () { return lastError; },
    services: function () { return services.slice(); },
    groups: function () { return groups.slice(); },
    refresh: function () { return load(true); },
    deploy: function (key, opener) {
      var svc = find(key);
      if (!svc) return false;
      var job = liveJob(svc);
      if (job) { openSheet(svc, opener, job, jobAction(svc)); return true; }
      if (svc.state !== 'available') return false;
      openSheet(svc, opener);
      return true;
    },
    remove: function (key, opener) {
      var svc = find(key);
      if (!svc || svc.removable !== true) return false;
      var job = liveJob(svc);
      if (job) { openSheet(svc, opener, job, jobAction(svc)); return true; }
      openActionSheet(svc, 'remove', opener);
      return true;
    }
  };

  window.addEventListener('hashchange', function () {
    if (routeKey() && detailKey === null) navDepth++;
    route();
  });

  elDBack.addEventListener('click', function () {
    if (navDepth > 0) { navDepth--; history.back(); return; }
    /* landed here directly: replace rather than push, so Back still leaves */
    if (window.history && history.replaceState) {
      history.replaceState(null, '', '#/');
      route();
    } else {
      location.hash = '#/';
    }
  });

  /* ---------- wiring ---------- */

  elFilter.addEventListener('input', function () {
    filterText = elFilter.value;
    if (loaded) render();
  });

  if (elGBtn && elGMenu) {
    elGBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      setGroupOpen(elGMenu.hidden);
    });
    elGMenu.addEventListener('click', function (e) { e.stopPropagation(); });
    elGMenu.addEventListener('change', applyGroupChecks);
    document.addEventListener('click', function () { setGroupOpen(false); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' || e.key === 'Esc') setGroupOpen(false);
    });
  }

  elFilter.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' || e.key === 'Esc') {
      elFilter.value = '';
      filterText = '';
      render();
    }
  });

  /* ⌘K / Ctrl-K jumps to the search pill from anywhere on the page — the
     browser's own find is left alone (it lives on ⌘F). */
  document.addEventListener('keydown', function (e) {
    if ((e.key === 'k' || e.key === 'K') && (e.metaKey || e.ctrlKey)) {
      /* Not while a sheet owns the modal layer (focus would land behind
         it), and not on routes where the field is hidden — the detail page
         has no search at all, and the catalogue focuses its own. */
      if (!elSheet.hidden || elSearch.hidden) return;
      e.preventDefault();
      elFilter.focus();
      elFilter.select();
    }
  });

  elRetry.addEventListener('click', function () {
    text(elRetry, 'Retrying…');
    elRetry.disabled = true;
    load(true).then(function () {
      text(elRetry, 'Retry');
      elRetry.disabled = false;
    });
  });

  elCancel.addEventListener('click', closeSheet);
  /* One confirm button, four verbs: whichever job the sheet was opened for. */
  elConfirm.addEventListener('click', function () {
    if (sheetAction && sheetAction !== 'deploy') runAction();
    else confirmDeploy();
  });
  elScrim.addEventListener('click', closeSheet);

  elSheet.addEventListener('click', function (e) {
    if (e.target === elSheet) closeSheet();
  });

  document.addEventListener('keydown', function (e) {
    if (elSheet.hidden) return;

    if (e.key === 'Escape' || e.key === 'Esc') {
      e.preventDefault();
      closeSheet();
      return;
    }

    if (e.key !== 'Tab') return;
    // Minimal focus trap: keep Tab inside the dialog.
    var focusables = elCard.querySelectorAll('button:not([disabled]):not([hidden]), [href], [tabindex="0"]');
    if (!focusables.length) return;
    var first = focusables[0];
    var last = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault(); first.focus();
    }
  });

  function scheduleRefresh() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(function () {
      if (document.hidden) return;
      if (jobId) return;           // the job poll already keeps things warm
      load(false);
    }, REFRESH_MS);
  }

  window.addEventListener('focus', function () { if (!jobId) load(false); });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && !jobId) load(false);
  });

  /* Desktop only: autofocusing the filter on a phone pops the keyboard. */
  function isPointerDevice() {
    return !!(window.matchMedia && window.matchMedia('(hover: hover) and (pointer: fine)').matches);
  }

  activeTab = storedTab();   // survives a reload
  loadGroupFilter();
  paintGroupMenu();
  VIEW.onChange(render);     // the View/Sort selects repaint through here
  render();
  route();                   // a deep link to #/service/<key> opens straight there
  load(true).then(function () {
    /* Desktop only, and never while a detail page is open — stealing focus
       out of a page you linked to is rude. */
    if (isPointerDevice() && detailKey === null) {
      try { elFilter.focus({ preventScroll: true }); } catch (e) { elFilter.focus(); }
    }
  });
  scheduleRefresh();
}());
