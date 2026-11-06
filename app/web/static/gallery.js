/* gallery.js — the Deploys gallery and each deployment's own page
 *
 * A self-contained module, same contract as deployd.js and notes.js: it
 * reads the route out of `location.hash`, talks to `api/deployments`
 * itself, and touches nothing app.js owns except `LauncherApp.watchJob`,
 * which streams a deploy's log in the app's own job sheet.
 *
 *   #/deploys          one card per deployment, painted into #gallery-mount
 *                      (deployd.js builds that mount between its page header
 *                      and the "Advanced: pollers" section).
 *   #/deploys/<key>    #view-deploy: Overview (state, deployed commit, URL,
 *                      Redeploy), Deployment method (pick a method, edit its
 *                      fields, Save = validate on the server + redeploy) and
 *                      Logs (deployd's tail plus recent launcher jobs).
 *
 * The server is the only judge of a definition: ghapp.validate() runs on
 * every save and its 400 message is shown inline. The METHODS table below
 * only carries labels, starting values and hints for the form; it checks
 * nothing. Relative URLs (the page is served at `/` and `/home/`), and
 * every string from the API lands through textContent.
 */
(function () {
  'use strict';

  var view = document.getElementById('view-deploy');
  var listPage = document.getElementById('view-deploys');
  if (!view && !listPage) return;

  var LIST_ROUTE = '#/deploys';
  var DETAIL_RE = /^#\/deploys\/(.+)$/;
  var TICK_MS = 30000;        // the app's own list poll
  var FETCH_TIMEOUT = 10000;

  var route = { page: null, key: null };
  var token = 0;              // stale-fetch guard
  var tick = null;
  var current = null;         // the detail payload on screen
  var form = null;            // the method form's state on the detail page
  var checkPending = false;   // a Refresh fetch is in flight on the detail
  var commitsOpen = false;    // the behind list's expanded state survives repaints
  var saveNote = '';          // shown under the rebuilt form after a save
  var lastFetch = 0;          // the tick and app.js's list poll both refresh

  /* ---------- helpers ---------- */

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }
  function text(node, s) {
    node.textContent = s == null ? '' : String(s);
    return node;
  }
  function sha7(s) { return (typeof s === 'string' && s) ? s.slice(0, 7) : ''; }
  function ago(iso) {
    var t = typeof iso === 'number' ? iso * 1000 : Date.parse(iso || '');
    if (!t) return '';
    var s = Math.max(0, (Date.now() - t) / 1000);
    if (s < 60) return 'just now';
    var m = Math.round(s / 60);
    if (m < 60) return m + ' min ago';
    var h = Math.round(m / 60);
    if (h < 48) return h + ' h ago';
    return Math.round(h / 24) + ' d ago';
  }
  function app() { return window.LauncherApp || null; }

  /* A repaint replaces nodes, which would drop keyboard focus every tick.
     Focusable nodes carry a stable data-fid; whichever one had focus gets
     it back after `paint` runs. */
  function keepFocus(container, paint) {
    var active = document.activeElement;
    var fid = (container && active && container.contains(active))
      ? active.getAttribute('data-fid') : null;
    paint();
    if (!fid || !container) return;
    var sel = '[data-fid="' + (window.CSS && CSS.escape ? CSS.escape(fid) : fid) + '"]';
    var el = container.querySelector(sel);
    if (!el) return;
    try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); }
  }
  function hostOf(url) {
    try { var u = new URL(url); return u.host + (u.pathname === '/' ? '' : u.pathname); }
    catch (e) { return url || ''; }
  }
  function ghLink(slug, tail) {
    return 'https://github.com/' + slug + (tail || '');
  }
  function extLink(href, label, cls) {
    var a = make('a', cls || 'gal-link');
    a.href = href;
    a.setAttribute('data-fid', 'link:' + href);
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    text(a, label);
    return a;
  }

  function call(method, path, body, done, timeout) {
    var xhr = new XMLHttpRequest();
    var timer = setTimeout(function () { xhr.abort(); },
                           timeout || FETCH_TIMEOUT);
    xhr.open(method, path, true);
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      clearTimeout(timer);
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (e) { /* keep null */ }
      done(data, xhr.status);
    };
    xhr.onerror = function () { clearTimeout(timer); done(null, 0); };
    xhr.onabort = function () { clearTimeout(timer); done(null, 0); };
    try {
      if (body == null) { xhr.send(); }
      else {
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.send(JSON.stringify(body));
      }
    } catch (e) { clearTimeout(timer); done(null, 0); }
  }

  /* ---------- state ---------- */

  var STATE_LABEL = {
    live: 'Live', failed: 'Failed', paused: 'Paused',
    deploying: 'Deploying', never: 'Never deployed'
  };

  /* A live deployment whose probe fails is still "live" to deployd; the
     dot says it is not answering. */
  function stateLook(item) {
    var s = item.state;
    if (s === 'live' && item.healthy === false) return ['is-down', 'Live, not answering'];
    return ['is-' + s, STATE_LABEL[s] || s];
  }

  function dot(item) {
    var look = stateLook(item);
    var d = make('span', 'gal-dot ' + look[0]);
    d.title = look[1];
    d.setAttribute('aria-hidden', 'true');
    return d;
  }

  /* ---------- the form's vocabulary (labels and hints only) ---------- */

  var PORT = { name: 'container_port', label: 'Container port', def: '3000', mono: true,
               hint: 'The port the app listens on inside the container.' };
  var METHODS = {
    dockerfile: { label: 'Dockerfile',
      blurb: 'Build the repo’s Dockerfile on this box and run the image.',
      fields: [
        { name: 'dockerfile', label: 'Dockerfile path', def: 'Dockerfile', mono: true,
          hint: 'Relative to the repo root, e.g. site/Dockerfile.' },
        { name: 'context', label: 'Build context', def: '.', mono: true,
          hint: 'The folder docker build gets, relative to the repo root.' },
        PORT] },
    image: { label: 'Docker image',
      blurb: 'Pull a published image and run it. Nothing is built.',
      fields: [
        { name: 'image', label: 'Image', def: '', mono: true,
          placeholder: 'ghcr.io/owner/app:latest', hint: 'name:tag or name@sha256:…' },
        PORT] },
    compose: { label: 'Docker Compose',
      blurb: 'docker compose up -d on the repo’s own compose file.',
      fields: [
        { name: 'compose_file', label: 'Compose file', def: 'docker-compose.yml', mono: true,
          hint: 'Relative to the repo root. It must publish the app on 127.0.0.1 at this app’s port.' },
        { name: 'service', label: 'Service', def: '', optional: true,
          hint: 'Optional: the service that answers on the port (its log shows on failure).' },
        PORT] },
    static: { label: 'Static site',
      blurb: 'Run a build, then serve its output folder from a small nginx container.',
      fields: [
        { name: 'build', label: 'Build command', def: 'npm ci && npm run build', mono: true,
          hint: 'Runs with sh -c in the checked-out repo.' },
        { name: 'output', label: 'Output directory', def: 'dist', mono: true,
          hint: 'The folder the build writes, relative to the repo root.' },
        { name: 'cache_control', label: 'Cache-Control header', def: '', mono: true,
          optional: true, placeholder: 'no-cache',
          hint: 'Optional. Sent with every file, e.g. no-cache so a new deploy shows on the next load.' },
        { name: 'frame_ancestors', label: 'Frame ancestors', def: '', mono: true,
          optional: true, placeholder: 'none',
          hint: 'Optional. none stops other sites from framing the app (sends CSP frame-ancestors and X-Frame-Options).' },
        { name: 'proxies', label: 'Proxy rules', kind: 'proxies', optional: true, max: 10,
          hint: 'Optional. Requests under a path go to that port on this box, path unchanged. ' +
                'The service there must accept connections from Docker (listen on 0.0.0.0).' }] },
    node: { label: 'Node',
      blurb: 'A Dockerfile is generated from node:<version>, then built and run.',
      fields: [
        { name: 'version', label: 'Node version', def: '22-alpine',
          hint: 'A tag of the official node image.' },
        { name: 'build', label: 'Build command', def: 'npm ci && npm run build',
          optional: true, mono: true, hint: 'Optional. Runs while the image builds.' },
        { name: 'start', label: 'Start command', def: 'npm start', mono: true,
          hint: 'What the container runs.' },
        PORT] },
    python: { label: 'Python',
      blurb: 'A Dockerfile is generated from python:<version>, then built and run.',
      fields: [
        { name: 'version', label: 'Python version', def: '3.13-slim',
          hint: 'A tag of the official python image.' },
        { name: 'build', label: 'Build command', def: 'pip install -r requirements.txt',
          optional: true, mono: true, hint: 'Optional. Runs while the image builds.' },
        { name: 'start', label: 'Start command', def: 'python app.py', mono: true,
          hint: 'What the container runs.' },
        { name: 'container_port', label: 'Container port', def: '8000', mono: true,
          hint: 'The port the app listens on inside the container.' }] },
    script: { label: 'Script',
      blurb: 'Run a shell command in the checked-out repo. No container; the command publishes itself.',
      fields: [
        { name: 'cmd', label: 'Deploy command', def: '', mono: true,
          placeholder: './deploy.sh', hint: 'Runs with sh -c as this box’s user.' }] }
  };
  var ORDER = ['dockerfile', 'image', 'compose', 'static', 'node', 'python', 'script'];
  var SOURCE = [
    { name: 'repo', label: 'GitHub repo', def: '', mono: true, hint: 'owner/name' },
    { name: 'ref', label: 'Branch', def: 'main', mono: true,
      hint: 'A push to this branch redeploys.' }
  ];
  var AFTER = [
    { name: 'health_path', label: 'Health path', def: '/', mono: true, optional: true,
      hint: 'Probed on 127.0.0.1 after each deploy; the old version stays if it never answers.' }
  ];

  /* ---------- the gallery ---------- */

  function card(item) {
    var a = make('a', 'gal-card gal-' + item.state);
    a.href = '#/deploys/' + encodeURIComponent(item.key);
    a.setAttribute('data-key', item.key);
    a.setAttribute('data-fid', 'card:' + item.key);

    var top = make('div', 'gal-top');
    top.appendChild(dot(item));
    top.appendChild(text(make('span', 'gal-name'), item.name || item.key));
    var badge = text(make('span', 'gal-badge'),
                     (METHODS[item.method] || {}).label || item.method);
    if (item.kind === 'service') badge.title = 'A service from this repo, deployed by its own script';
    top.appendChild(badge);
    a.appendChild(top);

    var commit = make('div', 'gal-line');
    if (item.deployed && item.deployed.sha) {
      commit.appendChild(text(make('span', 'gal-sha'), sha7(item.deployed.sha)));
      if (item.deployed.at) commit.appendChild(text(make('span', 'gal-when'), ago(item.deployed.at)));
    } else {
      commit.appendChild(text(make('span', 'gal-when'), 'No deploy yet'));
    }
    commit.appendChild(text(make('span', 'gal-state'), stateLook(item)[1]));
    a.appendChild(commit);

    var repo = (item.github || String(item.repo || '').replace(/^https?:\/\//, '')
                                                      .replace(/\.git$/, ''));
    a.appendChild(text(make('div', 'gal-meta'), repo + '@' + (item.ref || 'main')));
    if (item.url) a.appendChild(text(make('div', 'gal-url'), hostOf(item.url)));
    return a;
  }

  function paintList(data) {
    var mount = document.getElementById('gallery-mount');
    if (!mount) return;
    mount.textContent = '';
    if (!data || !Array.isArray(data.deployments)) {
      var bad = make('div', 'dep-empty');
      bad.appendChild(text(make('strong'), 'Could not load deployments'));
      bad.appendChild(text(make('span'),
        'The launcher did not answer api/deployments. It may be restarting.'));
      mount.appendChild(bad);
      return;
    }
    if (!data.deployments.length) {
      var none = make('div', 'dep-empty');
      none.appendChild(text(make('strong'), 'Nothing deploys from git yet'));
      none.appendChild(text(make('span'),
        'Use + New app to build a GitHub repo here and redeploy it on every push.'));
      mount.appendChild(none);
      return;
    }
    var grid = make('div', 'gal-grid');
    for (var i = 0; i < data.deployments.length; i++) grid.appendChild(card(data.deployments[i]));
    mount.appendChild(grid);
  }

  function refreshList() {
    lastFetch = Date.now();
    var t = ++token;
    call('GET', 'api/deployments', null, function (data, status) {
      if (t !== token || route.page !== 'list') return;
      keepFocus(document.getElementById('gallery-mount'), function () {
        paintList(status === 200 ? data : null);
      });
    });
  }

  /* ---------- the detail page ---------- */

  function section(title, sub) {
    var sec = make('section', 'd-sec gdp-sec');
    sec.appendChild(text(make('h3', 'd-sec-h'), title));
    if (sub) sec.appendChild(text(make('p', 'd-sec-sub gdp-sub'), sub));
    return sec;
  }

  function factRow(dl, label, node) {
    dl.appendChild(text(make('dt'), label));
    var dd = make('dd');
    if (typeof node === 'string') text(dd, node); else dd.appendChild(node);
    dl.appendChild(dd);
  }

  function watch(key, jobId, action, opener) {
    var a = app();
    if (a && typeof a.watchJob === 'function') a.watchJob(key, jobId, action || 'deploy', opener);
  }

  function paintOverview(sec, d) {
    sec.textContent = '';
    sec.appendChild(text(make('h3', 'd-sec-h'), 'Overview'));
    var dl = make('dl', 'gdp-facts');

    var st = make('span', 'gdp-state');
    st.appendChild(dot(d));
    st.appendChild(text(make('span'), stateLook(d)[1]));
    factRow(dl, 'Status', st);

    if (d.deployed && d.deployed.sha) {
      var c = make('span', 'gdp-commit');
      c.appendChild(d.github
        ? extLink(ghLink(d.github, '/commit/' + d.deployed.sha), sha7(d.deployed.sha), 'gal-link gal-sha')
        : text(make('span', 'gal-sha'), sha7(d.deployed.sha)));
      if (d.deployed.at) c.appendChild(text(make('span', 'gal-when'), ago(d.deployed.at)));
      factRow(dl, 'Deployed', c);
    } else {
      factRow(dl, 'Deployed', 'Not yet');
    }

    var repoLabel = (d.github || d.repo) + '@' + (d.ref || 'main');
    factRow(dl, 'Source', d.github
      ? extLink(ghLink(d.github, '/tree/' + encodeURIComponent(d.ref || 'main')), repoLabel)
      : text(make('span', 'gal-mono'), repoLabel));
    if (d.url) factRow(dl, 'URL', extLink(d.url, hostOf(d.url)));
    if (d.check) {
      var ck = d.check;
      var label;
      if (ck.behind > 0) {
        label = ck.behind + (ck.behind === 1 ? ' commit' : ' commits') + ' behind';
      } else if (ck.behind === 0 && ck.ahead > 0) {
        label = ck.ahead + (ck.ahead === 1 ? ' commit' : ' commits') +
                ' ahead of ' + (ck.ref || d.ref || 'main');
      } else if (ck.behind === 0) {
        label = 'Up to date';
      } else if (ck.stale_deployed) {
        label = 'Deployed commit no longer on ' + (ck.ref || 'main');
      } else if (!d.deployed || !d.deployed.sha) {
        label = 'Nothing deployed yet';
      } else {
        label = 'Could not compare';
      }
      if (ck.checked_at) label += ' · checked ' + ago(ck.checked_at);
      factRow(dl, 'Remote', ck.behind > 0
        ? text(make('span', 'gdp-warn'), label) : label);
    }
    if (d.fail) {
      var f = 'Exit ' + (d.fail.rc == null ? '?' : d.fail.rc);
      if (d.fail.sha) f += ' at ' + sha7(d.fail.sha);
      if (d.fail.at) f += ', ' + ago(d.fail.at);
      factRow(dl, 'Last failure', text(make('span', 'gdp-bad'), f + '. deployd retries with backoff.'));
    }
    if (d.paused) {
      factRow(dl, 'Auto-deploy', 'Paused: pushes do not redeploy until it is resumed under Advanced: pollers.');
    }
    sec.appendChild(dl);

    var bar = make('div', 'gdp-bar');
    var job = d.job && d.job.status === 'running' ? d.job : null;
    var btn = make('button', 'h-btn h-btn-accent');
    btn.type = 'button';
    btn.setAttribute('data-fid', 'redeploy');
    var err = make('p', 'gdp-err');
    err.hidden = true;
    if (job) {
      text(btn, 'View deploy log');
      btn.addEventListener('click', function () { watch(d.key, job.id, job.action, btn); });
    } else {
      text(btn, 'Redeploy');
      btn.title = d.kind === 'app'
        ? 'Run ghapp.py deploy: fetch the branch, build with this method, swap when healthy'
        : 'Run deployd --force: this service’s deploy command, now';
      btn.addEventListener('click', function () {
        btn.disabled = true;
        err.hidden = true;
        call('POST', 'api/deployments/' + encodeURIComponent(d.key) + '/redeploy', null,
          function (data, status) {
            btn.disabled = false;
            if (status === 202 && data && data.job_id) {
              watch(d.key, data.job_id, 'deploy', btn);
              refreshDetail();
              return;
            }
            text(err, (data && data.error) || 'Redeploy failed to start (HTTP ' + status + ').');
            err.hidden = false;
          });
      });
    }
    bar.appendChild(btn);
    var chk = make('button', 'h-btn');
    chk.type = 'button';
    chk.setAttribute('data-fid', 'check-remote');
    text(chk, checkPending ? 'Checking…' : 'Refresh');
    chk.disabled = checkPending;
    chk.title = 'Fetch ' + (d.ref || 'main') + ' and count commits the deploy is behind';
    chk.addEventListener('click', function () {
      checkPending = true;
      chk.disabled = true;
      text(chk, 'Checking…');
      err.hidden = true;
      /* The server bounds the whole check (lock wait included) to 90s;
         waiting a little past it keeps a slow-but-fine fetch from
         looking like a failure. */
      call('POST', 'api/deployments/' + encodeURIComponent(d.key) + '/check', null,
        function (data, status) {
          checkPending = false;
          chk.disabled = false;
          text(chk, 'Refresh');
          if (status === 200 && data && data.key) {
            refreshDetail();
            return;
          }
          text(err, (data && data.error) || 'Check failed (HTTP ' + status + ').');
          err.hidden = false;
        }, 100000);
    });
    bar.appendChild(chk);
    sec.appendChild(bar);
    sec.appendChild(err);

    /* The commit list the Refresh produced: one row per commit the deploy
       lacks, expandable. Rendered whenever the check has commits, whether
       they came from this click or a cached earlier one. */
    if (d.check && d.check.commits && d.check.commits.length) {
      var det = make('details', 'gdp-behind');
      /* The ticker repaints the whole section; without this, an expanded
         list collapses under the reader every poll. */
      det.open = commitsOpen;
      det.addEventListener('toggle', function () { commitsOpen = det.open; });
      var sum = make('summary');
      var n = d.check.behind != null ? d.check.behind : d.check.commits.length;
      text(sum, n + (n === 1 ? ' commit' : ' commits') +
                ' on ' + (d.check.ref || d.ref || 'main') + ' not yet deployed');
      det.appendChild(sum);
      var ul = make('ul', 'gdp-commits');
      d.check.commits.forEach(function (cm) {
        var li = make('li');
        if (d.github) {
          li.appendChild(extLink(ghLink(d.github, '/commit/' + cm.sha),
                                 sha7(cm.sha), 'gal-link gal-sha'));
        } else {
          li.appendChild(text(make('span', 'gal-sha'), sha7(cm.sha)));
        }
        li.appendChild(text(make('span', 'gdp-subject'), cm.subject));
        li.appendChild(text(make('span', 'gal-when'),
          (cm.author || '') + (cm.at ? ' · ' + ago(cm.at) : '')));
        ul.appendChild(li);
      });
      det.appendChild(ul);
      sec.appendChild(det);
    }
  }

  /* --- the method form --- */

  /* What a field starts as. A name present in `base` is a real value
     (null or absent there means empty: absent stays absent, so editing a
     branch never adds a build step or a health check). A name missing from
     it gets the starting value, which only a newly picked method needs. */
  function seedValue(base, f) {
    if (Object.prototype.hasOwnProperty.call(base, f.name)) {
      var v = base[f.name];
      return v == null ? '' : String(v);
    }
    return f.def;
  }

  /* Fields whose meaning is the same under every method, so a switch
     carries what is on screen. build/start/version mean something else per
     method and never cross over. */
  var CARRY = { container_port: true };

  function fieldNames(method) {
    var out = {};
    var fs = (METHODS[method] || {}).fields || [];
    for (var i = 0; i < fs.length; i++) out[fs[i].name] = true;
    return out;
  }

  /* The values a method's form opens with: what was typed under it earlier
     this visit; else, for the stored method, the stored definition; else a
     carried field from the screen, or a leftover the definition still holds
     from an earlier time on that method (a field the stored method does not
     use). The source fields always carry. */
  function baseFor(method) {
    var cur = form.inputs.length ? collect() : null;
    var stored = form.def;
    var storedOwn = fieldNames(form.stored);
    var draft = form.drafts[method];
    var base = {};
    var fs = (METHODS[method] || {}).fields || [];
    for (var i = 0; i < fs.length; i++) {
      var n = fs[i].name;
      if (draft && Object.prototype.hasOwnProperty.call(draft, n)) base[n] = draft[n];
      else if (method === form.stored) base[n] = stored[n];
      else if (CARRY[n] && cur && cur[n] != null && cur[n] !== '') base[n] = cur[n];
      else if (stored[n] != null && !storedOwn[n]) base[n] = stored[n];
    }
    var common = SOURCE.concat(AFTER);
    for (var j = 0; j < common.length; j++) {
      var c = common[j].name;
      var v = cur ? cur[c] : stored[c];
      /* An empty health path under Script becomes the starting "/" again
         for a method that needs one; under the stored method it stays. */
      if (v != null && v !== '') base[c] = v;
      else if (method === form.stored || !cur) base[c] = null;
    }
    return base;
  }

  function inputFor(f, value, opts) {
    opts = opts || {};
    var p = make('div', 'field gdp-field');
    var id = 'gdp-f-' + f.name;
    var lab = text(make('label', 'field-label'), f.label + (f.optional ? ' (optional)' : ''));
    lab.htmlFor = id;
    p.appendChild(lab);
    var inp = make(opts.multiline ? 'textarea' : 'input',
                   'field-input' + (f.mono ? ' gdp-mono' : '') + (opts.multiline ? ' field-area' : ''));
    inp.id = id;
    if (!opts.multiline) inp.type = 'text';
    inp.setAttribute('autocomplete', 'off');
    inp.setAttribute('autocapitalize', 'off');
    inp.setAttribute('spellcheck', 'false');
    inp.value = value;
    if (f.placeholder) inp.placeholder = f.placeholder;
    if (opts.disabled) inp.disabled = true;
    inp.setAttribute('data-field', f.name);
    p.appendChild(inp);
    if (f.hint) p.appendChild(text(make('p', 'field-hint gdp-hint'), f.hint));
    return { wrap: p, input: inp, field: f };
  }

  /* An editable list of {path, port} rows (static's proxies). Same row
     shape as inputFor's, plus read() for collect() and setDisabled() for
     the save lock. A row left fully blank is dropped; no rows reads as
     null, so an app without proxies stays without the field. A port that
     is not digits is sent as typed, and the server's 400 points here. */
  function proxiesFor(f, value) {
    var p = make('div', 'field gdp-field gdp-proxies');
    p.appendChild(text(make('div', 'field-label'), f.label + (f.optional ? ' (optional)' : '')));
    var list = make('div', 'gdp-proxy-list');
    list.setAttribute('data-field', f.name);
    list.tabIndex = -1;
    p.appendChild(list);
    var add = make('button', 'btn gdp-proxy-add');
    add.type = 'button';
    text(add, 'Add proxy rule');
    p.appendChild(add);
    if (f.hint) p.appendChild(text(make('p', 'field-hint gdp-hint'), f.hint));
    var rows = [];
    var locked = false;

    function cell(cls, val, ph, label) {
      var inp = make('input', 'field-input gdp-mono ' + cls);
      inp.type = 'text';
      inp.setAttribute('autocomplete', 'off');
      inp.setAttribute('autocapitalize', 'off');
      inp.setAttribute('spellcheck', 'false');
      inp.setAttribute('aria-label', label);
      inp.placeholder = ph;
      inp.value = val;
      inp.addEventListener('input', markDirty);
      return inp;
    }
    function sync() { add.disabled = locked || rows.length >= (f.max || 10); }
    function addRow(path, port) {
      var r = make('div', 'gdp-proxy-row');
      var row = { wrap: r,
                  path: cell('gdp-proxy-path', path, '/api/', 'Proxy path'),
                  port: cell('gdp-proxy-port', port, '8089', 'Host port') };
      row.rm = make('button', 'btn gdp-proxy-rm');
      row.rm.type = 'button';
      text(row.rm, 'Remove');
      row.rm.setAttribute('aria-label', 'Remove this proxy rule');
      row.rm.addEventListener('click', function () {
        list.removeChild(r);
        rows.splice(rows.indexOf(row), 1);
        sync();
        markDirty();
        add.focus();
      });
      r.appendChild(row.path);
      r.appendChild(row.port);
      r.appendChild(row.rm);
      list.appendChild(r);
      rows.push(row);
      sync();
      return row;
    }
    (Array.isArray(value) ? value : []).forEach(function (e) {
      e = e || {};
      addRow(e.path == null ? '' : String(e.path), e.port == null ? '' : String(e.port));
    });
    add.addEventListener('click', function () {
      addRow('', '').path.focus();
      markDirty();
    });
    function read() {
      var out = [];
      for (var i = 0; i < rows.length; i++) {
        var path = rows[i].path.value.trim();
        var port = rows[i].port.value.trim();
        if (!path && !port) continue;
        out.push({ path: path, port: /^\d+$/.test(port) ? parseInt(port, 10) : port });
      }
      return out.length ? out : null;
    }
    function setDisabled(on) {
      locked = on;
      for (var i = 0; i < rows.length; i++) {
        rows[i].path.disabled = on;
        rows[i].port.disabled = on;
        rows[i].rm.disabled = on;
      }
      sync();
    }
    return { wrap: p, input: list, field: f, read: read, setDisabled: setDisabled };
  }

  /* The body a Save sends: the chosen method, the common fields and that
     method's own. An empty optional field is sent as null (absent); a port
     that reads as digits goes as a number. Nothing else is interpreted. */
  function collect() {
    var body = { method: form.method };
    var inputs = form.inputs;
    for (var i = 0; i < inputs.length; i++) {
      var f = inputs[i].field;
      if (inputs[i].read) { body[f.name] = inputs[i].read(); continue; }
      var v = inputs[i].input.value.trim();
      if (f.name === 'container_port' && /^\d+$/.test(v)) v = parseInt(v, 10);
      else if (v === '' && f.optional) v = null;
      body[f.name] = v;
    }
    return body;
  }

  function markDirty() {
    if (!form || !form.save) return;
    var dirty = JSON.stringify(collect()) !== form.clean;
    form.save.disabled = !dirty || form.busy;
    if (form.reset) form.reset.disabled = !dirty;
    clearFieldErrors();
  }

  function clearFieldErrors() {
    var bad = view.querySelectorAll('[aria-invalid="true"]');
    for (var i = 0; i < bad.length; i++) bad[i].removeAttribute('aria-invalid');
  }

  /* ghapp.validate's messages read "bad <field> <value>": point at it. */
  function flagField(msg) {
    var m = /^bad ([a-z_]+)/.exec(msg || '');
    if (!m) return;
    var inp = view.querySelector('[data-field="' + m[1] + '"]');
    if (inp) { inp.setAttribute('aria-invalid', 'true'); inp.focus(); }
  }

  function renderFields() {
    var def = baseFor(form.method);
    form.fieldsBox.textContent = '';
    form.inputs = [];
    var spec = METHODS[form.method] || METHODS.dockerfile;
    text(form.blurb, spec.blurb);
    var groups = [SOURCE, spec.fields, AFTER];
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length; i++) {
        var f = groups[g][i];
        var row;
        if (f.kind === 'proxies') {
          /* Absent in `base` is no rows, the same as null. */
          row = proxiesFor(f, Object.prototype.hasOwnProperty.call(def, f.name) ? def[f.name] : null);
        } else {
          row = inputFor(f, seedValue(def, f), { multiline: f.name === 'cmd' });
          row.input.addEventListener('input', markDirty);
        }
        form.inputs.push(row);
        form.fieldsBox.appendChild(row.wrap);
      }
    }
  }

  function paintAppMethod(sec, d) {
    sec.textContent = '';
    sec.appendChild(text(make('h3', 'd-sec-h'), 'Deployment method'));
    sec.appendChild(text(make('p', 'd-sec-sub gdp-sub'),
      'Saving checks the definition on the server, then redeploys with it. Key ' +
      d.key + ' and port ' + (d.definition.port || '(none)') + ' stay as they are.'));
    var def = d.definition || {};
    form = { kind: 'app', def: def, method: def.method || 'dockerfile', inputs: [],
             drafts: {} };
    form.stored = form.method;

    var pick = make('div', 'field gdp-field');
    var lab = text(make('label', 'field-label'), 'Method');
    lab.htmlFor = 'gdp-method';
    pick.appendChild(lab);
    var sel = make('select', 'field-input');
    sel.id = 'gdp-method';
    var methods = (d.methods && d.methods.length) ? d.methods : ORDER;
    for (var i = 0; i < methods.length; i++) {
      var o = make('option');
      o.value = methods[i];
      text(o, (METHODS[methods[i]] || {}).label || methods[i]);
      sel.appendChild(o);
    }
    sel.value = form.method;
    pick.appendChild(sel);
    form.blurb = make('p', 'field-hint gdp-hint');
    pick.appendChild(form.blurb);
    sec.appendChild(pick);

    form.fieldsBox = make('div', 'gdp-fields');
    sec.appendChild(form.fieldsBox);
    renderFields();
    form.clean = JSON.stringify(collect());

    sel.addEventListener('change', function () {
      /* Remember what this method's form held, so switching back to it
         returns exactly that. */
      form.drafts[form.method] = collect();
      form.method = sel.value;
      renderFields();
      markDirty();
    });

    var err = make('p', 'gdp-err');
    err.setAttribute('role', 'alert');
    err.hidden = true;
    var status = make('p', 'field-status');
    status.setAttribute('role', 'status');
    var bar = make('div', 'gdp-bar');
    var save = make('button', 'btn btn-primary');
    save.type = 'button';
    text(save, 'Save and redeploy');
    save.disabled = true;
    form.save = save;
    var reset = make('button', 'btn');
    reset.type = 'button';
    text(reset, 'Discard changes');
    reset.disabled = true;
    form.reset = reset;
    reset.addEventListener('click', function () { paintAppMethod(sec, current); });
    bar.appendChild(reset);
    bar.appendChild(save);
    sec.appendChild(err);
    sec.appendChild(bar);
    sec.appendChild(status);
    text(status, saveNote);
    saveNote = '';

    var mine = form;
    /* Nothing is editable while a save is in flight: a success rebuilds
       the form from the server, which would drop anything typed since. */
    function lock(on) {
      sel.disabled = on;
      reset.disabled = on || JSON.stringify(collect()) === mine.clean;
      for (var i = 0; i < mine.inputs.length; i++) {
        if (mine.inputs[i].setDisabled) mine.inputs[i].setDisabled(on);
        else mine.inputs[i].input.disabled = on;
      }
    }
    save.addEventListener('click', function () {
      var body = collect();
      mine.busy = true;
      save.disabled = true;
      lock(true);
      err.hidden = true;
      text(status, 'Checking…');
      call('PUT', 'api/deployments/' + encodeURIComponent(d.key), body, function (data, code) {
        mine.busy = false;
        if (form !== mine) return;
        lock(false);
        if (code === 202 && data && data.job_id) {
          saveNote = 'Saved. The deploy log is open in the sheet.';
          text(status, saveNote);
          watch(d.key, data.job_id, 'deploy', save);
          refreshDetail(true);
          return;
        }
        text(status, '');
        text(err, 'Not saved: ' + ((data && data.error) || 'HTTP ' + code));
        err.hidden = false;
        save.disabled = false;
        flagField(data && data.error);
      });
    });
  }

  /* A first-party service: its method stays "script" until services move
     onto methods. Its cmd saves through the poller override path, the same
     state/pollers.json row Advanced: pollers edits. */
  function paintServiceMethod(sec, d) {
    sec.textContent = '';
    sec.appendChild(text(make('h3', 'd-sec-h'), 'Deployment method'));
    var def = d.definition || {};
    form = { kind: 'service', def: def, method: 'script', inputs: [] };

    var pick = make('div', 'field gdp-field');
    var lab = text(make('label', 'field-label'), 'Method');
    lab.htmlFor = 'gdp-method';
    pick.appendChild(lab);
    var sel = make('select', 'field-input');
    sel.id = 'gdp-method';
    sel.disabled = true;
    var o = make('option');
    o.value = 'script';
    text(o, 'Script');
    sel.appendChild(o);
    pick.appendChild(sel);
    pick.appendChild(text(make('p', 'field-hint gdp-hint'),
      'A service from this repo deploys through its own script. Moving services ' +
      'onto the other methods comes in a later change.'));
    sec.appendChild(pick);

    var src = { name: 'repo', label: 'Git repo', mono: true };
    sec.appendChild(inputFor(src, def.repo || '', { disabled: true }).wrap);
    sec.appendChild(inputFor({ name: 'ref', label: 'Branch', mono: true },
                             def.ref || 'main', { disabled: true }).wrap);
    var cmd = inputFor({ name: 'cmd', label: 'Deploy command', mono: true,
                         hint: def.source === 'manifest'
                           ? 'From services/' + d.key + '/app.json. Saving writes an override to state/pollers.json; the repo file is never edited.'
                           : 'Saved in state/pollers.json.' },
                       def.cmd || '', { multiline: true });
    sec.appendChild(cmd.wrap);

    var err = make('p', 'gdp-err');
    err.setAttribute('role', 'alert');
    err.hidden = true;
    var status = make('p', 'field-status');
    status.setAttribute('role', 'status');
    var bar = make('div', 'gdp-bar');
    var save = make('button', 'btn btn-primary');
    save.type = 'button';
    text(save, 'Save command');
    save.disabled = true;
    var clean = cmd.input.value;
    var busy = false;
    cmd.input.addEventListener('input', function () {
      save.disabled = busy || cmd.input.value === clean;
    });
    var mine = form;
    bar.appendChild(save);
    sec.appendChild(err);
    sec.appendChild(bar);
    sec.appendChild(status);
    text(status, saveNote);
    saveNote = '';

    save.addEventListener('click', function () {
      busy = true;
      save.disabled = true;
      cmd.input.disabled = true;
      err.hidden = true;
      call('POST', 'api/deployd/pollers/' + encodeURIComponent(d.key),
           { repo: def.repo, ref: def.ref || 'main', cmd: cmd.input.value },
           function (data, code) {
             busy = false;
             /* Another page (or a rebuilt form) since: not this reply's. */
             if (form !== mine || route.key !== d.key) return;
             cmd.input.disabled = false;
             if (code === 200 && data && data.watched) {
               clean = cmd.input.value;
               saveNote = 'Saved. It runs the next time ' + (def.ref || 'main') +
                          ' moves; Redeploy runs it now.';
               text(status, saveNote);
               refreshDetail(true);
               return;
             }
             save.disabled = false;
             text(err, 'Not saved: ' + ((data && data.error) || 'HTTP ' + code));
             err.hidden = false;
           });
    });
  }

  /* --- logs --- */

  function logBox(label, body, id, open) {
    var det = make('details', 'dep-log gdp-log');
    det.setAttribute('data-log', id);
    if (open) det.open = true;
    var sum = text(make('summary'), label);
    sum.setAttribute('data-fid', 'sum:' + id);
    det.appendChild(sum);
    var pre = make('pre', 'dep-log-tail gdp-pre');
    pre.setAttribute('data-fid', 'pre:' + id);
    pre.tabIndex = 0;
    text(pre, body || '(no output)');
    det.appendChild(pre);
    return det;
  }

  function paintLogs(sec, d) {
    /* The tick rebuilds this section: keep each box's open state and
       scroll position across it. */
    var keep = {};
    var olds = sec.querySelectorAll('details[data-log]');
    for (var i = 0; i < olds.length; i++) {
      var pre = olds[i].querySelector('pre');
      keep[olds[i].getAttribute('data-log')] = { open: olds[i].open, top: pre ? pre.scrollTop : 0 };
    }
    var first = !olds.length;
    sec.textContent = '';
    sec.appendChild(text(make('h3', 'd-sec-h'), 'Logs'));
    var logs = d.logs || {};
    var jobs = logs.jobs || [];
    var any = false;
    for (var j = 0; j < jobs.length; j++) {
      var job = jobs[j];
      var id = 'job-' + job.id;
      var label = (job.action === 'deploy' ? 'Deploy' : job.action) + ' from the launcher · ' +
                  job.status + (job.exit_code != null && job.exit_code !== 0 ? ' (exit ' + job.exit_code + ')' : '') +
                  (job.started ? ' · ' + ago(job.started) : '');
      sec.appendChild(logBox(label, job.log, id, keep[id] ? keep[id].open : (first && j === 0)));
      any = true;
    }
    if (logs.deployd) {
      sec.appendChild(logBox('Last deployd run (push-triggered)', logs.deployd, 'deployd',
                             keep.deployd ? keep.deployd.open : (first && !jobs.length)));
      any = true;
    }
    if (!any) {
      sec.appendChild(text(make('p', 'd-empty'),
        'No deploy output yet. A deploy started here, or one deployd runs after a push, shows up here.'));
    }
    var news = sec.querySelectorAll('details[data-log]');
    for (var n = 0; n < news.length; n++) {
      var k = keep[news[n].getAttribute('data-log')];
      var p = news[n].querySelector('pre');
      if (k && p) p.scrollTop = k.top;
    }
  }

  function paintDetail(d, rebuildForm) {
    if (!view) return;
    if (!d) {
      view.textContent = '';
      view.appendChild(backLink());
      var bad = make('div', 'dep-empty');
      bad.appendChild(text(make('strong'), 'Could not load this deployment'));
      bad.appendChild(text(make('span'), 'It may have been removed, or the launcher is restarting.'));
      view.appendChild(bad);
      form = null;
      return;
    }
    var fresh = !current || current.key !== d.key || !view.querySelector('.gdp-head');
    current = d;
    document.title = (d.name || d.key) + ' · Deploys · Launcher';
    if (fresh) {
      view.textContent = '';
      view.appendChild(backLink());
      var head = make('div', 'h-head gdp-head');
      var titles = make('div', 'h-titles');
      var h = text(make('h2', 'h-title'), d.name || d.key);
      h.id = 'gdp-title';
      titles.appendChild(h);
      titles.appendChild(make('p', 'h-sub gdp-headsub'));
      head.appendChild(titles);
      view.appendChild(head);
      view.appendChild(make('section', 'd-sec gdp-sec gdp-overview'));
      view.appendChild(make('section', 'd-sec gdp-sec gdp-method'));
      view.appendChild(make('section', 'd-sec gdp-sec gdp-logs'));
    }
    var sub = view.querySelector('.gdp-headsub');
    text(sub, ((METHODS[d.method] || {}).label || d.method) + ' · ' +
              (d.kind === 'app' ? 'App from GitHub' : 'Service from this repo') + ' · ' + d.key);
    var ov = view.querySelector('.gdp-overview');
    keepFocus(ov, function () { paintOverview(ov, d); });
    /* The form repaints only when it is new or after a save: a tick must
       never throw away what is being typed. */
    if (fresh || rebuildForm || !form) {
      var ms = view.querySelector('.gdp-method');
      if (d.kind === 'app') paintAppMethod(ms, d); else paintServiceMethod(ms, d);
    }
    var lg = view.querySelector('.gdp-logs');
    keepFocus(lg, function () { paintLogs(lg, d); });
  }

  function backLink() {
    var a = make('a', 'd-back gdp-back');
    a.href = LIST_ROUTE;
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.7');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M14.5 5.5 8 12l6.5 6.5');
    svg.appendChild(path);
    a.appendChild(svg);
    a.appendChild(text(make('span'), 'Deploys'));
    return a;
  }

  function refreshDetail(rebuildForm) {
    lastFetch = Date.now();
    var key = route.key;
    var t = ++token;
    call('GET', 'api/deployments/' + encodeURIComponent(key), null, function (data, status) {
      if (t !== token || route.page !== 'detail' || route.key !== key) return;
      if (status === 200 && data) {
        /* The list payload's method vocabulary rides along for the picker. */
        data.methods = data.methods || ORDER;
        paintDetail(data, rebuildForm);
      } else if (!current || current.key !== key) {
        paintDetail(null);
      }
    });
  }

  /* ---------- routing ---------- */

  function readRoute() {
    var h = String(location.hash || '');
    if (h === LIST_ROUTE) return { page: 'list', key: null };
    var m = DETAIL_RE.exec(h);
    if (m) {
      var k;
      try { k = decodeURIComponent(m[1]); } catch (e) { k = m[1]; }
      return { page: 'detail', key: k };
    }
    return { page: null, key: null };
  }

  function onRoute() {
    var next = readRoute();
    if (view) view.hidden = next.page !== 'detail';
    if (next.page === route.page && next.key === route.key && tick) return;
    route = next;
    token++;
    current = null;
    form = null;
    checkPending = false;
    commitsOpen = false;
    if (tick) { clearInterval(tick); tick = null; }
    if (view && next.page !== 'detail') view.textContent = '';
    if (next.page === 'list') {
      refreshList();
      tick = setInterval(function () { if (!document.hidden) refreshList(); }, TICK_MS);
    } else if (next.page === 'detail') {
      window.scrollTo(0, 0);
      view.textContent = '';
      refreshDetail(true);
      tick = setInterval(function () { if (!document.hidden) refreshDetail(false); }, TICK_MS);
    } else if (document.title.indexOf(' · Deploys · Launcher') !== -1) {
      document.title = 'Launcher';
    }
  }

  window.addEventListener('hashchange', onRoute);
  /* A job the sheet was watching ends with app.js re-polling its list:
     follow it so a card's dot and the detail's logs catch up at once. */
  document.addEventListener('launcher:services', function () {
    if (Date.now() - lastFetch < 5000) return;
    if (route.page === 'list') refreshList();
    else if (route.page === 'detail') refreshDetail(false);
  });
  onRoute();
})();
