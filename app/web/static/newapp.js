/* newapp.js — "New app from GitHub", opened from the Deploys page
 *
 * A self-contained dialog in two steps:
 *   1. Pick a repo: the box's gh login lists its repos (api/github/repos);
 *      typing owner/name works too, for a repo the list does not show.
 *   2. Configure: api/github/inspect says which branches exist, whether a
 *      Dockerfile sits at the root and which port it EXPOSEs, and suggests
 *      a free key. Create POSTs api/apps, which writes the app's definition,
 *      its .env and its deploy poller, and starts the first build.
 *
 * After Create this dialog closes and hands the job id to
 * LauncherApp.watchJob, so the build log streams in app.js's own sheet the
 * way every other deploy does. Nothing else app.js owns is touched.
 *
 * Every URL is relative (the page is served at `/` and `/home/`) and every
 * string from GitHub lands through textContent.
 */
(function () {
  'use strict';

  var FETCH_TIMEOUT = 20000;   // inspect makes up to three GitHub calls
  var REPO_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
  var KEY_RE = /^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/;

  var scrim = null;
  var sheet = null;
  var card = null;
  var opener = null;
  var repos = null;            // cached list for this page load
  var token = 0;               // bumps on every step change: stale replies drop

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }
  function text(node, s) {
    node.textContent = s == null ? '' : String(s);
    return node;
  }

  function call(method, path, body, done) {
    var xhr = new XMLHttpRequest();
    var timer = setTimeout(function () { xhr.abort(); done(null, 0); }, FETCH_TIMEOUT);
    xhr.open(method, path, true);
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4 || xhr.status === 0) return;
      clearTimeout(timer);
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (e) { /* keep */ }
      done(data, xhr.status);
    };
    xhr.onerror = function () { clearTimeout(timer); done(null, 0); };
    try {
      if (body == null) { xhr.send(); }
      else {
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.send(JSON.stringify(body));
      }
    } catch (e) { clearTimeout(timer); done(null, 0); }
  }

  function errorText(data, status, what) {
    if (data && data.error) return data.error;
    if (!status) return what + ' timed out or the launcher did not answer.';
    return what + ' failed (HTTP ' + status + ').';
  }

  function ago(iso) {
    var t = Date.parse(iso || '');
    if (!t) return '';
    var m = Math.max(0, Math.round((Date.now() - t) / 60000));
    if (m < 60) return m <= 1 ? 'just now' : m + ' min ago';
    var h = Math.round(m / 60);
    if (h < 48) return h + ' h ago';
    var d = Math.round(h / 24);
    return d < 60 ? d + ' d ago' : Math.round(d / 30) + ' mo ago';
  }

  /* ---------- the dialog shell ---------- */

  function build() {
    if (sheet) return;
    scrim = make('div', 'scrim');
    scrim.hidden = true;
    sheet = make('div', 'sheet nap');
    sheet.hidden = true;
    sheet.setAttribute('role', 'dialog');
    sheet.setAttribute('aria-modal', 'true');
    sheet.setAttribute('aria-labelledby', 'nap-title');
    card = make('div', 'sheet-card nap-card');
    sheet.appendChild(card);
    document.body.appendChild(scrim);
    document.body.appendChild(sheet);
    scrim.addEventListener('click', close);
    sheet.addEventListener('click', function (e) { if (e.target === sheet) close(); });
    document.addEventListener('keydown', function (e) {
      if (sheet.hidden) return;
      if (e.key === 'Escape' || e.key === 'Esc') { e.preventDefault(); close(); return; }
      if (e.key !== 'Tab') return;
      var f = card.querySelectorAll('button:not([disabled]), input:not([disabled]), '
                                    + 'select:not([disabled]), textarea, summary');
      if (!f.length) return;
      var first = f[0];
      var last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
  }

  function open(btn) {
    build();
    opener = btn || document.activeElement;
    scrim.hidden = false;
    sheet.hidden = false;
    document.body.classList.add('is-locked');
    stepRepos('');
  }

  function close() {
    if (!sheet || sheet.hidden) return;
    token++;
    sheet.hidden = true;
    scrim.hidden = true;
    card.textContent = '';
    document.body.classList.remove('is-locked');
    if (opener && document.contains(opener) && opener.focus) opener.focus();
  }

  function head(title, sub, back) {
    var h = make('div', 'nap-head');
    if (back) {
      var b = make('button', 'nap-back');
      b.type = 'button';
      b.setAttribute('aria-label', 'Back to the repo list');
      text(b, '‹');
      b.addEventListener('click', back);
      h.appendChild(b);
    }
    var t = make('div', 'sheet-headtext');
    var h2 = text(make('h2'), title);
    h2.id = 'nap-title';
    t.appendChild(h2);
    if (sub) t.appendChild(text(make('span', 'sheet-sub'), sub));
    h.appendChild(t);
    return h;
  }

  function bar(buttons) {
    var b = make('div', 'sheet-actions');
    buttons.forEach(function (x) { b.appendChild(x); });
    return b;
  }

  function button(label, primary, fn) {
    var b = make('button', 'btn' + (primary ? ' btn-primary' : ''));
    b.type = 'button';
    text(b, label);
    b.addEventListener('click', fn);
    return b;
  }

  /* ---------- step 1: pick a repo ---------- */

  function stepRepos(query) {
    var mine = ++token;
    card.textContent = '';
    card.appendChild(head('New app from GitHub',
      'Builds a repo’s Dockerfile on this box and redeploys on every push.'));

    var search = make('input', 'dep-input nap-search');
    search.type = 'search';
    search.placeholder = 'Search your repos, or type owner/name';
    search.setAttribute('aria-label', 'Search repos');
    search.autocomplete = 'off';
    search.spellcheck = false;
    search.value = query || '';
    card.appendChild(search);

    var list = make('div', 'nap-list');
    list.setAttribute('role', 'list');
    card.appendChild(list);
    card.appendChild(bar([button('Cancel', false, close)]));

    function paint() {
      list.textContent = '';
      var q = search.value.trim();
      var ql = q.toLowerCase();
      var shown = 0;
      var exact = false;
      (repos || []).forEach(function (r) {
        if (r.archived) return;
        if (ql && r.repo.toLowerCase().indexOf(ql) < 0
            && (r.description || '').toLowerCase().indexOf(ql) < 0) return;
        if (r.repo.toLowerCase() === ql) exact = true;
        if (shown >= 60) return;
        shown++;
        list.appendChild(repoItem(r));
      });
      if (REPO_RE.test(q) && !exact) {
        list.insertBefore(repoItem({ repo: q, manual: true }), list.firstChild);
        shown++;
      }
      if (!shown && repos) {
        list.appendChild(text(make('p', 'nap-empty'),
          q ? 'No repo matches “' + q + '”. Type owner/name to use one not listed.'
            : 'No repos on this login. Type owner/name to use a public one.'));
      }
    }

    function repoItem(r) {
      var b = make('button', 'nap-repo');
      b.type = 'button';
      b.setAttribute('role', 'listitem');
      var top = make('span', 'nap-repo-top');
      top.appendChild(text(make('span', 'nap-repo-name'), r.repo));
      if (r.private) top.appendChild(text(make('span', 'nap-tag'), 'Private'));
      if (r.manual) top.appendChild(text(make('span', 'nap-tag'), 'Use this repo'));
      b.appendChild(top);
      var meta = [r.description || '', r.pushed_at ? 'pushed ' + ago(r.pushed_at) : '']
        .filter(Boolean).join(' · ');
      if (meta) b.appendChild(text(make('span', 'nap-repo-meta'), meta));
      b.addEventListener('click', function () { stepConfigure(r.repo, search.value); });
      return b;
    }

    search.addEventListener('input', paint);
    search.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') return;
      var firstItem = list.querySelector('.nap-repo');
      if (firstItem) { e.preventDefault(); firstItem.click(); }
    });
    setTimeout(function () { search.focus(); }, 0);

    if (repos) { paint(); return; }
    list.appendChild(text(make('p', 'nap-empty'), 'Loading your repos…'));
    call('GET', 'api/github/repos', null, function (data, status) {
      if (mine !== token) return;
      if (status === 200 && data && Array.isArray(data.repos)) {
        repos = data.repos;
        paint();
        return;
      }
      repos = [];
      paint();
      var err = make('p', 'nap-alert');
      text(err, errorText(data, status, 'Listing repos') + ' The list uses the '
           + 'box’s gh login (gh auth login on the server); you can still type owner/name.');
      list.insertBefore(err, list.firstChild);
    });
  }

  /* ---------- step 2: configure and create ---------- */

  function field(form, label, input, hint) {
    var lab = make('label', 'dep-field');
    lab.appendChild(text(make('span', 'dep-field-cap'), label));
    lab.appendChild(input);
    if (hint) {
      var h = text(make('span', 'nap-hint'), hint);
      lab.appendChild(h);
      input._hint = h;
    }
    form.appendChild(lab);
    return input;
  }

  function input(value, placeholder) {
    var i = make('input', 'dep-input');
    i.value = value == null ? '' : String(value);
    if (placeholder) i.placeholder = placeholder;
    i.autocomplete = 'off';
    i.spellcheck = false;
    return i;
  }

  function stepConfigure(repo, query) {
    var mine = ++token;
    var back = function () { stepRepos(query); };
    card.textContent = '';
    card.appendChild(head(repo, 'Checking the repo…', back));
    var status = make('p', 'nap-empty');
    text(status, 'Looking for branches and a Dockerfile…');
    card.appendChild(status);
    card.appendChild(bar([button('Back', false, back)]));
    call('POST', 'api/github/inspect', { repo: repo }, function (data, code) {
      if (mine !== token) return;
      if (code !== 200 || !data) {
        status.className = 'nap-alert';
        text(status, errorText(data, code, 'Reading the repo'));
        return;
      }
      configureForm(repo, query, data);
    });
  }

  function configureForm(repo, query, info) {
    var mine = token;
    var back = function () { stepRepos(query); };
    card.textContent = '';
    card.appendChild(head(repo, info.private ? 'Private repo · via the box’s gh login'
                                             : 'Public repo', back));

    var form = make('div', 'nap-form');
    card.appendChild(form);

    var short = repo.split('/')[1];
    var name = field(form, 'Name', input(short, short));
    var key = field(form, 'Key', input(info.key, 'my-app'),
      'Container app-<key>, files in ~/services/apps/<key>. Lowercase, 3 to 32 characters.');

    var branch = make('select', 'dep-input');
    var names = (info.branches && info.branches.length) ? info.branches : [info.ref];
    if (names.indexOf(info.ref) < 0) names = [info.ref].concat(names);
    names.forEach(function (n) {
      var o = make('option');
      o.value = n;
      text(o, n);
      branch.appendChild(o);
    });
    branch.value = info.ref;
    field(form, 'Branch', branch, 'Every push to this branch redeploys the app.');

    var docker = make('p', 'nap-check');
    form.appendChild(docker);

    var port = field(form, 'Container port',
      input(info.container_port || '', 'e.g. 3000'));
    port.inputMode = 'numeric';
    var portTouched = false;
    port.addEventListener('input', function () { portTouched = true; });

    var health = field(form, 'Health path', input('/', '/'),
      'Must answer (any status below 500) within 90 s, or the old version stays.');
    var env = make('textarea', 'dep-input');
    env.rows = 4;
    env.placeholder = 'DATABASE_URL=postgres://…\nSECRET_KEY=…';
    env.spellcheck = false;
    field(form, 'Environment', env,
      'KEY=value, one per line. Saved to the app’s .env (mode 0600), editable later.');

    var adv = make('details', 'nap-adv');
    adv.appendChild(text(make('summary'), 'Advanced'));
    var advBody = make('div', 'nap-form');
    adv.appendChild(advBody);
    form.appendChild(adv);
    var dockerfile = field(advBody, 'Dockerfile', input('Dockerfile', 'Dockerfile'),
      'Path inside the repo.');
    var context = field(advBody, 'Build context', input('.', '.'));
    var volume = field(advBody, 'Data volume', input('', '/data'),
      'Container path kept across deploys, stored in ~/services/apps/<key>/data.');

    var err = make('p', 'nap-alert');
    err.hidden = true;
    form.appendChild(err);

    var create = button('Create and deploy', true, submit);
    card.appendChild(bar([button('Back', false, back), create]));

    function paintDocker() {
      var custom = dockerfile.value.trim() && dockerfile.value.trim() !== 'Dockerfile';
      docker.className = 'nap-check ' + (info.dockerfile ? 'is-ok' : 'is-warn');
      if (info.dockerfile) {
        text(docker, 'Dockerfile found on ' + info.ref
             + (info.container_port ? ', EXPOSE ' + info.container_port : ', no EXPOSE line'));
      } else if (custom) {
        text(docker, 'No Dockerfile at the root of ' + info.ref
             + '; building from ' + dockerfile.value.trim() + ' instead.');
      } else {
        text(docker, 'No Dockerfile at the root of ' + info.ref
             + '. Apps build from a Dockerfile; set its path under Advanced if it lives elsewhere.');
      }
      create.disabled = !info.dockerfile && !custom;
    }
    paintDocker();
    dockerfile.addEventListener('input', paintDocker);

    /* A branch change re-reads that branch's Dockerfile and EXPOSE line,
       keeping whatever port the user has typed. */
    branch.addEventListener('change', function () {
      var ref = branch.value;
      var t = ++token;
      mine = t;
      text(docker, 'Checking ' + ref + '…');
      docker.className = 'nap-check';
      create.disabled = true;
      call('POST', 'api/github/inspect', { repo: repo, ref: ref }, function (data, code) {
        if (t !== token) return;
        if (code !== 200 || !data) {
          docker.className = 'nap-check is-warn';
          text(docker, errorText(data, code, 'Reading ' + ref));
          create.disabled = false;
          return;
        }
        info.ref = data.ref;
        info.dockerfile = data.dockerfile;
        info.container_port = data.container_port;
        if (!portTouched) port.value = data.container_port || '';
        paintDocker();
      });
    });

    function fail(msg, focus) {
      text(err, msg);
      err.hidden = false;
      if (focus) focus.focus();
    }

    function submit() {
      err.hidden = true;
      var k = key.value.trim();
      var p = port.value.trim();
      if (!KEY_RE.test(k)) return fail('Key must be 3 to 32 lowercase letters, digits or dashes, not starting or ending with a dash.', key);
      if (!/^\d+$/.test(p) || +p < 1 || +p > 65535) return fail('Container port is the port the app listens on inside the container (1 to 65535).', port);
      var body = {
        repo: repo, ref: branch.value, key: k,
        name: name.value.trim() || k,
        container_port: +p,
        health_path: health.value.trim() || '/',
        dockerfile: dockerfile.value.trim() || 'Dockerfile',
        context: context.value.trim() || '.',
        env: env.value
      };
      if (volume.value.trim()) body.volume = volume.value.trim();
      create.disabled = true;
      text(create, 'Creating…');
      call('POST', 'api/apps', body, function (data, code) {
        if (mine !== token) return;
        if ((code === 200 || code === 202) && data && data.job_id) {
          close();
          started(data);
          return;
        }
        create.disabled = false;
        text(create, 'Create and deploy');
        fail(errorText(data, code, 'Creating the app'));
      });
    }
  }

  /* The app exists now: refresh the services list so it has a row (and the
     job sheet an icon and name), then stream the first build. */
  function started(res) {
    var a = window.LauncherApp;
    if (!a) return;
    var watch = function () {
      if (typeof a.watchJob === 'function') a.watchJob(res.key, res.job_id, 'deploy', opener);
    };
    var p = typeof a.refresh === 'function' ? a.refresh() : null;
    if (p && typeof p.then === 'function') p.then(watch, watch);
    else watch();
  }

  window.LauncherNewApp = { open: open };
})();
