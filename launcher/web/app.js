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

  /* Tabs. `state` comes straight from the API:
       active   -> running
       stopped  -> deployed, health probe fails  (shown as "Paused")
       available/planned -> not on the box       (shown as "Uninstalled")
     `empty` is what we say when the tab legitimately has nothing in it —
     never a blank void. */
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
      empty: 'Everything in the repo is deployed.' }
  ];

  /* ---------- state ---------- */

  var services = [];
  var host = '';
  var filterText = '';
  var activeTab = 'all';
  var tileCache = {};   // key -> {sig, node}, so a refresh reuses unchanged tiles
  var loaded = false;
  var lastFetchAt = 0;
  var inflight = false;
  var refreshTimer = null;

  var sheetService = null;
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
  var elCount   = $('foot-count');
  var elLive    = $('live');

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

  /* One local glyph, for the "not deployed" corner. Kept here rather than in
     the icon module because it is UI chrome, not a service mark. */
  function downloadGlyph() {
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.6');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    var paths = ['M12 4.4v10.4', 'm7.8 10.8 4.2 4.2 4.2-4.2', 'M4.6 19.3h14.8'];
    for (var i = 0; i < paths.length; i++) {
      var p = document.createElementNS(SVG_NS, 'path');
      p.setAttribute('d', paths[i]);
      svg.appendChild(p);
    }
    var span = make('span', 'tile-dl');
    span.appendChild(svg);
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
     deploy that is running for this service right now, or null. */
  function liveJob(svc) {
    var job = svc && svc.job;
    if (!job || typeof job !== 'object') return null;
    if (!job.id) return null;
    if (job.status && job.status !== 'running') return null;
    return String(job.id);
  }

  function tagline(svc) {
    var p = make('span', 'tile-tag');
    if (svc.tagline) p.appendChild(document.createTextNode(svc.tagline));

    var note = null;
    if (liveJob(svc)) {
      note = make('span', 'tile-note-run');
      text(note, 'deploying…');
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
      if (svc.tagline) p.appendChild(document.createTextNode(' · '));
      p.appendChild(note);
    }
    return p;
  }

  function buildTile(svc) {
    var state = svc.state || 'planned';
    var job = liveJob(svc);
    var openable = (state === 'active' || state === 'stopped') && !!svc.url && !job;

    var node;
    if (job) {
      /* A deploy is already running server-side. Tapping reattaches to it
         instead of POSTing a second deploy the backend would 409. */
      node = make('button', 'tile');
      node.type = 'button';
      node.addEventListener('click', function () { openSheet(svc, node, job); });
    } else if (openable) {
      node = make('a', 'tile');
      node.href = svc.url;
      node.target = '_blank';
      node.rel = 'noopener noreferrer';
    } else if (state === 'available') {
      node = make('button', 'tile');
      node.type = 'button';
      node.addEventListener('click', function () { openSheet(svc, node); });
    } else {
      node = make('div', 'tile');
      if (state !== 'planned') node.className += ' tile-static';
    }

    node.className += ' tile-' + state;
    node.setAttribute('role', 'listitem');
    node.setAttribute('data-key', svc.key);

    node.appendChild(icon(svc));

    if (job) {
      node.appendChild(cornerDot('dot-job', 'Deploy running'));
    } else if (state === 'active') {
      node.appendChild(cornerDot('dot-ok', 'Running'));
    } else if (state === 'stopped') {
      node.appendChild(cornerDot('dot-warn', 'Installed but not responding'));
    } else if (state === 'available') {
      var slot = make('span', 'tile-corner');
      slot.appendChild(downloadGlyph());
      slot.setAttribute('title', 'Not deployed — tap to install');
      node.appendChild(slot);
    } else {
      var pslot = make('span', 'tile-corner');
      pslot.appendChild(text(make('span', 'badge'), 'planned'));
      node.appendChild(pslot);
    }

    node.appendChild(text(make('span', 'tile-name'), svc.name || svc.key));
    node.appendChild(tagline(svc));

    var label = (svc.name || svc.key) + ', ' + (svc.tagline || '') + ', ' + describe(svc);
    node.setAttribute('aria-label', label.replace(/, ,/g, ','));

    return node;
  }

  function describe(svc) {
    if (liveJob(svc)) return 'deploy running, activate to watch the log';
    switch (svc.state) {
      case 'active':    return svc.url ? 'running, opens in a new tab' : 'running, no web interface';
      case 'stopped':   return 'installed but not responding';
      case 'available': return 'not deployed, activate to install';
      default:          return 'planned, not built yet';
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

  function find(key) {
    for (var i = 0; i < services.length; i++) {
      if (services[i].key === key) return services[i];
    }
    return null;
  }

  function matches(svc, q) {
    if (!q) return true;
    var hay = [svc.name, svc.tagline, svc.key].join(' ').toLowerCase();
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
    var sig = [svc.state, svc.url, svc.name, svc.tagline, svc.icon, liveJob(svc)].join('');
    var hit = tileCache[svc.key];
    if (hit && hit.sig === sig) return hit.node;
    var node = buildTile(svc);
    tileCache[svc.key] = { sig: sig, node: node };
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
      var frag = document.createDocumentFragment();
      for (var s = 0; s < 8; s++) frag.appendChild(skeleton());
      elGrid.textContent = '';
      elGrid.appendChild(frag);
      elGrid.setAttribute('aria-busy', 'true');
      elEmpty.hidden = true;
      elTabs.hidden = false;
      paintTabs(null);
      return;
    }

    var q = filterText.trim().toLowerCase();
    var tab = tabDef(activeTab);

    /* Counts are per tab and honour the type-to-filter, so the tab strip
       tells you where a search term lives. */
    var counts = {};
    for (var t = 0; t < TABS.length; t++) counts[TABS[t].id] = 0;

    var nodes = [];
    for (var i = 0; i < services.length; i++) {
      var svc = services[i];
      if (!matches(svc, q)) continue;
      for (var c = 0; c < TABS.length; c++) {
        if (TABS[c].match(svc)) counts[TABS[c].id]++;
      }
      if (tab.match(svc)) nodes.push(tileFor(svc));
    }

    syncGrid(nodes);
    elGrid.setAttribute('aria-busy', 'false');

    elTabs.hidden = services.length === 0;
    paintTabs(counts);

    if (nodes.length || services.length === 0) {
      elEmpty.hidden = true;
      elPanel.removeAttribute('tabindex');
    } else {
      text(elEmpty, q
        ? (tab.id === 'all'
            ? 'No service matches “' + filterText.trim() + '”.'
            : 'Nothing in ' + tab.label + ' matches “' + filterText.trim() + '”.')
        : tab.empty);
      elEmpty.hidden = false;
      elPanel.setAttribute('tabindex', '0');   // the panel has no focusable child
    }

    var running = 0, installed = 0;
    for (var j = 0; j < services.length; j++) {
      if (services[j].state === 'active') running++;
      if (services[j].installed) installed++;
    }
    text(elCount, services.length
      ? running + ' of ' + installed + ' deployed services running · ' + services.length + ' total'
      : '');
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
      loaded = true;
      hideNotice();
      text(elHost, host || ' ');
      render();
    }, function () {
      inflight = false;
      lastFetchAt = Date.now();
      failed('No response from the launcher backend. It may not be running: check `systemctl --user status launcher` on the box.');
    });
  }

  function failed(message) {
    showNotice("Can't reach the launcher API", message);
    if (!loaded) {
      loaded = true;      // stop the skeletons; the notice explains why
      services = [];
      render();
      text(elCount, '');
    }
  }

  /* ---------- deploy sheet ---------- */

  function openSheet(svc, opener, attachId) {
    sheetService = svc;
    lastFocused = opener || document.activeElement;
    jobId = null;
    jobFails = 0;

    elSIcon.textContent = '';
    elSIcon.appendChild(iconNode(svc));
    text(elSTitle, (attachId ? 'Deploying ' : 'Deploy ') + (svc.name || svc.key));
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
    text(elCancel, 'Cancel');
    text(elConfirm, 'Deploy');

    elScrim.hidden = false;
    elSheet.hidden = false;
    document.body.classList.add('is-locked');

    if (attachId) attachJob(attachId, svc);

    // Focus the safe button, not the destructive one.
    setTimeout(function () { elCancel.focus(); }, 0);
  }

  /* Reattach to a deploy that is already running on the server: show the log
     view straight away and resume polling, instead of POSTing a deploy the
     backend would reject with 409. */
  function attachJob(id, svc) {
    jobId = id;
    jobFails = 0;

    elSBody.textContent = '';
    elSBody.appendChild(document.createTextNode(
      'A deploy for this service is already running on the server. This is that job’s live log — you can close this and come back to it.'));

    elActions.hidden = false;
    elConfirm.hidden = true;
    elCancel.disabled = false;
    text(elCancel, 'Close');

    elSRun.hidden = false;
    setPill('pill-run', 'Running');
    text(elRunExit, '');
    text(elLog, 'Attaching to job ' + id + '…\n');
    say('Reattached to the running deploy for ' + ((svc && (svc.name || svc.key)) || 'this service'));
    pollJob();
  }

  function closeSheet() {
    stopJobPolling();
    elSheet.hidden = true;
    elScrim.hidden = true;
    document.body.classList.remove('is-locked');
    sheetService = null;
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
      if (job.status === 'done') {
        setPill('pill-done', 'Done');
        text(elRunExit, 'exit ' + code);
        say('Deploy finished, exit code ' + code);
      } else {
        setPill('pill-fail', 'Failed');
        text(elRunExit, 'exit ' + code);
        alertSheet('The setup script exited with code ' + code + '. The log above has the details; nothing was rolled back.');
        say('Deploy failed, exit code ' + code);
      }
      elLog.scrollTop = elLog.scrollHeight;
      jobId = null;
      load(true);
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

  /* ---------- wiring ---------- */

  elFilter.addEventListener('input', function () {
    filterText = elFilter.value;
    if (loaded) render();
  });

  elFilter.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' || e.key === 'Esc') {
      elFilter.value = '';
      filterText = '';
      render();
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
  elConfirm.addEventListener('click', confirmDeploy);
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
  render();
  load(true).then(function () {
    if (isPointerDevice()) {
      try { elFilter.focus({ preventScroll: true }); } catch (e) { elFilter.focus(); }
    }
  });
  scheduleRefresh();
}());
