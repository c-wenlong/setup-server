/* deployd.js — deployment activity + poller management on the detail page
 *
 * A self-contained module, same contract as notes.js: it reads the service
 * key out of `location.hash` (`#/service/<key>`), renders into
 * `#deployd-mount`, and talks to `api/deployd` itself. Nothing app.js owns
 * is touched except `LauncherApp.watchJob`, which hands a force-deploy job
 * id to the app's own sheet so its live log streams the way a deploy does.
 *
 * What it draws depends on which page is open:
 *   #/deploys          — its own top-level page (#view-deploys): header with
 *                         the engine's state and Pause/Resume, then the whole
 *                         watched table plus the poller controls:
 *                         add/edit/delete via state/pollers.json (never the
 *                         checkout deployd ff-pulls), pause/resume via the
 *                         <key>.disabled marker, Deploy-now via
 *                         `deployd --force`, and the suppressed list
 *                         (launcher removals + manifest enabled:false).
 *   #/service/<other>  — just that service's row, when deployd watches it.
 *                         Nothing at all when it does not.
 *
 * Every URL is relative ("api/deployd") because the page is served at both
 * `/` and `/home/`. All text lands through textContent — log tails are
 * arbitrary command output. A `cmd` is arbitrary shell too: this UI is
 * tailnet-only and carries the same trust as pushing to the repo.
 */
(function () {
  'use strict';

  var detailMount = document.getElementById('deployd-mount');
  var page = document.getElementById('view-deploys');
  if (!detailMount && !page) return;
  var PAGE_ROUTE = '#/deploys';
  var pageBody = null;       // the page's list mount, built once
  var pageSub = null;
  var pageEngine = null;
  var mount = detailMount;   // where paint() draws: detail section or page body

  var TICK_MS = 60000;       // deploys are slow; the app's own poll is 30s
  var FETCH_TIMEOUT = 8000;

  var key = null;            // service key on screen, null on the grid
  var token = 0;             // stale-fetch guard
  var tick = null;
  var editing = null;        // open add/edit form: {key|null} — repaints wait
  var pendingData = null;    // newest payload while the form is open

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }
  function text(node, s) {
    node.textContent = s == null ? '' : String(s);
    return node;
  }

  /* ---------- transport ---------- */

  function callDeployd(method, path, body, done) {
    var xhr = new XMLHttpRequest();
    var timer = setTimeout(function () { xhr.abort(); }, FETCH_TIMEOUT);
    xhr.open(method, path, true);
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      clearTimeout(timer);
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (e) { /* keep */ }
      done(data, xhr.status);
    };
    xhr.onerror = function () { clearTimeout(timer); done(null, 0); };
    xhr.onabort = function () { clearTimeout(timer); };
    try {
      if (body == null) { xhr.send(); }
      else {
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.send(JSON.stringify(body));
      }
    } catch (e) { clearTimeout(timer); done(null, 0); }
  }

  function fetchDeployd(done) {
    callDeployd('GET', 'api/deployd', null,
                function (data, status) {
                  done(status === 200 ? data : null);
                });
  }

  /* ---------- paint ---------- */

  var STATE_LABEL = {
    deployed: 'Deployed', failed: 'Failing', disabled: 'Disabled',
    pending: 'Never deployed'
  };

  function sha7(s) {
    return (typeof s === 'string' && s) ? s.slice(0, 7) : null;
  }

  function ago(ts) {
    if (!ts) return '';
    var s = Math.max(0, (Date.now() - ts * 1000) / 1000);
    if (s < 60) return 'just now';
    var m = Math.round(s / 60);
    if (m < 60) return m + ' min ago';
    var h = Math.round(m / 60);
    if (h < 48) return h + ' h ago';
    return Math.round(h / 24) + ' d ago';
  }

  function chip(state) {
    var c = make('span', 'dep-state dep-state-' + state);
    text(c, STATE_LABEL[state] || state);
    return c;
  }

  function act(label, title, fn, danger) {
    var b = make('button', 'dep-act' + (danger ? ' dep-act-danger' : ''));
    b.type = 'button';
    text(b, label);
    if (title) b.title = title;
    b.addEventListener('click', fn);
    return b;
  }

  /* ---------- row actions: one ⋯ button, a menu on tap ----------
   *
   * Four pills per row read as chrome, not information, so the actions live
   * in an overflow menu. One menu is open at a time; tap-outside or Esc
   * closes it, and the next repaint drops whatever was open anyway. */
  var openMenu = null;

  /* Esc returns focus to the row's ⋯ button — removing the focused item
     would otherwise dump a keyboard user at document top. */
  function closeMenu(restoreFocus) {
    if (!openMenu) return;
    var btn = openMenu._btn;
    if (btn) btn.setAttribute('aria-expanded', 'false');
    openMenu.remove();
    openMenu = null;
    if (restoreFocus && btn) btn.focus();
  }

  document.addEventListener('click', function (ev) {
    if (openMenu && !openMenu.contains(ev.target)) closeMenu();
  });
  document.addEventListener('keydown', function (ev) {
    if (ev.key === 'Escape') closeMenu(true);
  });

  function menuItem(label, title, fn) {
    var b = make('button', 'dep-menu-item');
    b.type = 'button';
    b.setAttribute('role', 'menuitem');
    text(b, label);
    if (title) b.title = title;
    b.addEventListener('click', function () { closeMenu(); fn(); });
    return b;
  }

  /* The two-tap arm/disarm the inline Remove had, inside the menu: first
     tap relabels, second runs, closing the menu disarms. */
  function confirmItem(label, fn) {
    var b = make('button', 'dep-menu-item dep-menu-danger');
    b.type = 'button';
    b.setAttribute('role', 'menuitem');
    text(b, label);
    var armed = false;
    var timer = null;
    b.addEventListener('click', function (ev) {
      ev.stopPropagation();
      if (!armed) {
        armed = true;
        text(b, 'Really ' + label.toLowerCase() + '?');
        timer = setTimeout(function () {
          armed = false;
          text(b, label);
        }, 4000);
        return;
      }
      clearTimeout(timer);
      b.disabled = true;
      closeMenu();
      fn();
    });
    return b;
  }

  function buildMenu(entry, errHost) {
    var k = entry.key;
    var menu = make('span', 'dep-menu');
    menu.setAttribute('role', 'menu');

    menu.appendChild(menuItem('Deploy now', 'Run its deploy cmd immediately',
      function () {
        clearRowError(errHost);
        callDeployd('POST', 'api/deployd/pollers/' +
                    encodeURIComponent(k) + '/deploy', null,
          function (data, status) {
            if (status === 202 && data && data.job_id &&
                window.LauncherApp && LauncherApp.watchJob) {
              LauncherApp.watchJob(k, data.job_id, 'deploy');
            } else if (data && data.error) {
              rowError(errHost, data.error);
            } else {
              rowError(errHost, 'Deploy failed to start (HTTP ' + status + ')');
            }
          });
      }));
    menu.appendChild(entry.disabled
      ? menuItem('Resume', 'Clear the .disabled marker — deployd polls it again',
                 function () { clearRowError(errHost);
                               post('api/deployd/pollers/' +
                                    encodeURIComponent(k) + '/resume', null, errHost); })
      : menuItem('Pause', 'Drop a .disabled marker — deployd skips it',
                 function () { clearRowError(errHost);
                               post('api/deployd/pollers/' +
                                    encodeURIComponent(k) + '/pause', null, errHost); }));
    menu.appendChild(menuItem(entry.source === 'manifest' ? 'Override…' : 'Edit…',
      entry.source === 'manifest'
        ? 'Repo, ref and cmd come from app.json — this writes an override row'
        : 'Edit the state/pollers.json entry',
      function () {
        if (editing) return;
        var form = openEditor(k, entry);
        /* errHost sits inside the row — the menu itself is already
           detached here, so it cannot find the row to anchor the form. */
        var rowEl = errHost.closest('.dep-row');
        if (rowEl && rowEl.parentNode) rowEl.parentNode.insertBefore(form, rowEl.nextSibling);
        var first = form.querySelector('.dep-input');
        if (first) first.focus();
      }));
    menu.appendChild(make('span', 'dep-menu-sep'));
    menu.appendChild(confirmItem('Remove', function () {
      clearRowError(errHost);
      callDeployd('DELETE', 'api/deployd/pollers/' + encodeURIComponent(k),
                  null, function (data, status) {
        if (data && data.watched) { repaint(data); return; }
        rowError(errHost, (data && data.error) ||
                 'Remove failed (HTTP ' + status + ')');
      });
    }));
    return menu;
  }

  /* The ⋯ toggle: a second tap on the same button closes, a tap on another
     row's closes that one and opens this one. `errHost` is the row's top
     line — the place action failures land. */
  function rowActions(entry, errHost) {
    var wrap = make('span', 'dep-menu-wrap');
    var btn = make('button', 'dep-menu-btn');
    btn.type = 'button';
    btn.setAttribute('aria-haspopup', 'menu');
    btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('aria-label', 'Actions for ' + entry.key);
    text(btn, '…');
    wrap.appendChild(btn);
    btn.addEventListener('click', function (ev) {
      ev.stopPropagation();
      if (openMenu && openMenu.parentNode === wrap) { closeMenu(); return; }
      closeMenu();
      var menu = buildMenu(entry, errHost);
      menu._btn = btn;
      wrap.appendChild(menu);
      openMenu = menu;
      btn.setAttribute('aria-expanded', 'true');
    });
    return wrap;
  }

  function repaint(data) {
    /* The mutation endpoints answer with the full payload — repaint from it
       directly. An error body or an open edit form both defer to the next
       full refresh rather than painting a half-shape. */
    if (data && data.watched) {
      if (editing) { pendingData = data; return; }
      paint(data);
    } else {
      refresh();
    }
  }

  /* Show an action's failure inline, next to the buttons that raised it —
     a swallowed 409 looks identical to success otherwise. */
  function rowError(host, msg) {
    var e = host.querySelector('.dep-err');
    if (!e) { e = make('span', 'dep-err'); host.appendChild(e); }
    text(e, msg);
  }
  function clearRowError(host) {
    var e = host.querySelector('.dep-err');
    if (e) e.remove();
  }

  function post(path, body, errHost) {
    callDeployd('POST', path, body, function (data, status) {
      if (data && data.watched) { repaint(data); return; }
      if (errHost) {
        rowError(errHost, (data && data.error) ||
                 'Request failed (HTTP ' + status + ')');
      } else {
        repaint(data);
      }
    });
  }

  function openEditor(pollerKey, seed) {
    editing = { key: pollerKey || null };
    var form = make('div', 'dep-form');
    form.setAttribute('data-editor', '1');

    var title = make('p', 'dep-form-title');
    text(title, pollerKey
         ? 'Edit “' + pollerKey + '” — saved as an override in '
           + 'state/pollers.json; the repo manifest stays untouched.'
         : 'New poller — a state/pollers.json entry deployd polls like any '
           + 'manifest one.');
    form.appendChild(title);

    function field(labelText, value, opts) {
      opts = opts || {};
      var lab = make('label', 'dep-field');
      var cap = make('span', 'dep-field-cap');
      text(cap, labelText);
      lab.appendChild(cap);
      var inp = make(opts.multiline ? 'textarea' : 'input', 'dep-input');
      if (opts.multiline) inp.rows = 3;
      inp.value = value || '';
      if (opts.placeholder) inp.placeholder = opts.placeholder;
      if (opts.disabled) inp.disabled = true;
      lab.appendChild(inp);
      form.appendChild(lab);
      return inp;
    }

    var keyIn = field('Key', pollerKey || (seed && seed.key) || '',
                      { disabled: !!pollerKey, placeholder: 'my-service' });
    var repoIn = field('Git repo', (seed && seed.repo) || '',
                       { placeholder: 'https://github.com/you/repo.git' });
    var refIn = field('Ref', (seed && seed.ref) || 'main',
                      { placeholder: 'main' });
    var cmdIn = field('Deploy command', (seed && seed.cmd) || '',
                      { multiline: true,
                        placeholder: 'services/mine/setup.sh' });

    var note = make('p', 'dep-form-note');
    text(note, 'Runs via bash -c as this box’s user when the ref moves. '
              + 'Same trust as pushing to the setup-server repo.');
    form.appendChild(note);

    var err = make('p', 'dep-form-err');
    err.hidden = true;
    form.appendChild(err);

    var bar = make('div', 'dep-form-bar');
    var save = make('button', 'btn btn-primary');
    save.type = 'button';
    text(save, pollerKey ? 'Save override' : 'Add poller');
    var cancel = make('button', 'dep-act');
    cancel.type = 'button';
    text(cancel, 'Cancel');
    bar.appendChild(cancel);
    bar.appendChild(save);
    form.appendChild(bar);

    cancel.addEventListener('click', function () {
      editing = null;
      var d = pendingData;
      pendingData = null;
      if (d) paint(d); else refresh();
    });
    /* Captured so a slow save of THIS editor can never clear a newer one:
       save A, cancel it, open B — A's late response must not close B. */
    var mine = editing;
    save.addEventListener('click', function () {
      var body = { repo: repoIn.value.trim(),
                   ref: refIn.value.trim() || 'main',
                   cmd: cmdIn.value };
      var k = keyIn.value.trim();
      err.hidden = true;
      if (!k) { text(err, 'Key is required.'); err.hidden = false; return; }
      if (!body.repo || !body.cmd.trim()) {
        text(err, 'Repo and command are required.');
        err.hidden = false;
        return;
      }
      save.disabled = true;
      text(save, 'Saving…');
      callDeployd('POST', 'api/deployd/pollers/' + encodeURIComponent(k),
                  body, function (data, status) {
        save.disabled = false;
        text(save, pollerKey ? 'Save override' : 'Add poller');
        if (status === 200 && data && data.watched) {
          if (editing === mine) {
            editing = null;
            pendingData = null;
            paint(data);
          } else {
            repaint(data);
          }
          return;
        }
        if (editing === mine) {
          text(err, (data && data.error) ||
                    'Save failed (HTTP ' + status + ').');
          err.hidden = false;
        }
      });
    });
    return form;
  }

  /* One watched service: key, ref -> sha, state chip, and its log tail in a
     disclosure when there is one. `full` adds repo, the cmd, failure record,
     and the actions menu. */
  function row(entry, full) {
    var wrap = make('div', 'dep-row dep-' + entry.state);
    var top = make('div', 'dep-row-top');

    var name = make('span', 'dep-key');
    text(name, entry.key);
    top.appendChild(name);

    var track = make('span', 'dep-track');
    var bits = [];
    if (full && entry.repo) {
      bits.push(entry.repo.replace(/^https?:\/\//, '').replace(/\.git$/, '')
                          .replace(/^github\.com\//, ''));
    }
    bits.push(entry.ref || 'main');
    bits.push('→');
    bits.push(sha7(entry.sha) || '—');
    text(track, bits.join(' '));
    top.appendChild(track);

    if (full && entry.source && entry.source !== 'manifest') {
      var src = make('span', 'dep-src dep-src-' + entry.source);
      text(src, entry.source === 'override' ? 'override' : 'state-only');
      src.title = entry.source === 'override'
        ? 'Defined by state/pollers.json on top of the repo manifest'
        : 'Defined only in state/pollers.json — no repo manifest';
      top.appendChild(src);
    }

    top.appendChild(chip(entry.state));

    if (entry.state === 'failed' && entry.fail && entry.fail.at) {
      var f = make('span', 'dep-when');
      text(f, 'rc ' + (entry.fail.rc == null ? '?' : entry.fail.rc) +
              ' · ' + ago(entry.fail.at));
      top.appendChild(f);
    } else if (entry.log_mtime) {
      var w = make('span', 'dep-when');
      text(w, ago(entry.log_mtime));
      top.appendChild(w);
    }
    /* The menu is last in the top line; `top` is also the error host, so a
       failed action lands a .dep-err under it on the next wrapped line. */
    if (full) top.appendChild(rowActions(entry, top));
    wrap.appendChild(top);

    if (full && entry.cmd) {
      var cmd = make('div', 'dep-cmd');
      text(cmd, '$ ' + entry.cmd);
      cmd.title = entry.cmd;
      wrap.appendChild(cmd);
    }

    if (entry.log) {
      var det = make('details', 'dep-log');
      det.setAttribute('data-key', entry.key);
      var sum = make('summary');
      text(sum, 'Last deploy output');
      det.appendChild(sum);
      var pre = make('pre', 'dep-log-tail');
      pre.tabIndex = 0;
      text(pre, entry.log);
      det.appendChild(pre);
      wrap.appendChild(det);
    }
    return wrap;
  }

  function suppressedRow(s) {
    var wrap = make('div', 'dep-row dep-sup-row');
    var top = make('div', 'dep-row-top');
    var name = make('span', 'dep-key');
    text(name, s.key);
    top.appendChild(name);
    var track = make('span', 'dep-track');
    var bits = [];
    if (s.repo) bits.push(String(s.repo).replace(/^https?:\/\//, '')
                                   .replace(/\.git$/, '')
                                   .replace(/^github\.com\//, ''));
    bits.push(s.ref || 'main');
    text(track, bits.join(' '));
    top.appendChild(track);
    var why = make('span', 'dep-state');
    text(why, s.by === 'manifest' ? 'Disabled in app.json' : 'Removed here');
    top.appendChild(why);
    wrap.appendChild(top);
    if (s.by === 'override') {
      var acts = make('div', 'dep-actions');
      acts.appendChild(act('Restore',
        'Drop the tombstone — the repo manifest definition applies again',
        function () {
          clearRowError(acts);
          post('api/deployd/pollers/' + encodeURIComponent(s.key) +
               '/restore', null, acts);
        }));
      wrap.appendChild(acts);
    }
    return wrap;
  }

  /* The tick rebuilds the whole panel from scratch, which would slam shut
     any log the user opened and drop their scroll position and focus. Take
     a snapshot before the rebuild and restore it after. */
  function snapshot() {
    var open = {};
    var focusKey = null;
    var focusSel = null;
    var dets = mount.querySelectorAll('details.dep-log');
    for (var i = 0; i < dets.length; i++) {
      var k = dets[i].getAttribute('data-key');
      if (!k || !dets[i].open) continue;
      var pre = dets[i].querySelector('.dep-log-tail');
      open[k] = pre ? pre.scrollTop : 0;
      if (document.activeElement && dets[i].contains(document.activeElement)) {
        focusKey = k;
        var el = document.activeElement;
        focusSel = el.tagName === 'PRE' ? '.dep-log-tail'
               : el.tagName === 'SUMMARY' ? 'summary' : null;
      }
    }
    return { open: open, focusKey: focusKey, focusSel: focusSel };
  }

  function restore(snap) {
    var dets = mount.querySelectorAll('details.dep-log');
    for (var i = 0; i < dets.length; i++) {
      var k = dets[i].getAttribute('data-key');
      if (!k || !Object.prototype.hasOwnProperty.call(snap.open, k)) continue;
      dets[i].open = true;
      var pre = dets[i].querySelector('.dep-log-tail');
      if (pre) pre.scrollTop = snap.open[k];
      if (k === snap.focusKey && snap.focusSel) {
        var el = dets[i].querySelector(snap.focusSel);
        if (el) el.focus();
      }
    }
  }

  function paint(data) {
    var snap = snapshot();
    mount.textContent = '';
    if (!data || typeof data !== 'object') return;

    var sec = make('section', 'd-sec dep');
    var h = make('h3', 'd-sec-h');
    var rows;

    if (key === PAGE_ROUTE) {
      sec = make('section', 'dep dep-page');
      paintHeader(data);

      if (data.self_update_pending) {
        var su = make('p', 'dep-note');
        text(su, 'A deployd self-update failed last tick and will be retried.');
        sec.appendChild(su);
      }
      if (data.launcher_restart_pending) {
        var lr = make('p', 'dep-note');
        text(lr, 'A launcher restart failed last tick and will be retried.');
        sec.appendChild(lr);
      }
      if (!data.installed) {
        var ni = make('p', 'dep-note');
        text(ni, 'No state yet — deployd has not run on this box.');
        sec.appendChild(ni);
      }
      if (data.orphans && data.orphans.length) {
        var orph = make('p', 'dep-note');
        text(orph, 'Stale state for keys no longer in the registry: ' +
                  data.orphans.join(', '));
        sec.appendChild(orph);
      }
      rows = data.watched || [];
    } else {
      var mine = null;
      var watched = data.watched || [];
      for (var i = 0; i < watched.length; i++) {
        if (watched[i].key === key) { mine = watched[i]; break; }
      }
      if (!mine) return;   // deployd does not watch this service — no section
      text(h, 'Deploys');
      sec.appendChild(h);
      var sub = make('p', 'd-sec-sub');
      text(sub, 'Pushed to ' + (mine.ref || 'main') +
              ' — deployed by deployd when the remote moves.');
      sec.appendChild(sub);
      rows = [mine];
    }

    var list = make('div', 'dep-list');
    var full = (key === PAGE_ROUTE);
    if (full && !rows.length) {
      var none = make('div', 'dep-empty');
      none.appendChild(text(make('strong'), 'Nothing is watched yet'));
      none.appendChild(text(make('span'),
        'Add a poller to redeploy an app whenever a branch on GitHub moves.'));
      sec.appendChild(none);
    }
    for (var j = 0; j < rows.length; j++) {
      list.appendChild(row(rows[j], full));
    }
    sec.appendChild(list);

    if (full && data.suppressed && data.suppressed.length) {
      var supH = make('h4', 'dep-sup-h');
      text(supH, 'Not polled');
      sec.appendChild(supH);
      var supList = make('div', 'dep-list');
      for (var m = 0; m < data.suppressed.length; m++) {
        supList.appendChild(suppressedRow(data.suppressed[m]));
      }
      sec.appendChild(supList);
    }

    mount.appendChild(sec);
    restore(snap);
  }

  /* ---------- routing ---------- */

  /* The page's key is the route itself, so `key` stays a single "what is on
     screen" value: PAGE_ROUTE, a service key, or null. */
  function routeKey() {
    var h = String(location.hash || '');
    if (h === PAGE_ROUTE) return page ? PAGE_ROUTE : null;
    var m = /^#\/service\/(.+)$/.exec(h);
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  }

  /* ---------- the Deploys page ---------- */

  function app() { return window.LauncherApp || null; }

  function buildPage() {
    if (pageBody || !page) return;
    var head = make('div', 'h-head');
    var titles = make('div', 'h-titles');
    var h = text(make('h2', 'h-title'), 'Deploys');
    h.id = 'dps-title';
    titles.appendChild(h);
    pageSub = text(make('p', 'h-sub'),
      'Redeploys an app whenever its branch on GitHub moves.');
    titles.appendChild(pageSub);
    head.appendChild(titles);
    pageEngine = make('div', 'dep-engine');
    head.appendChild(pageEngine);
    var add = make('button', 'h-btn h-btn-accent');
    add.type = 'button';
    add.appendChild(text(make('span'), '+ Add poller'));
    add.addEventListener('click', function () {
      if (editing || !mount) return;
      var sec = mount.querySelector('.dep-page');
      if (!sec) return;
      var form = openEditor(null, null);
      var list = sec.querySelector('.dep-list');
      if (list) sec.insertBefore(form, list);
      else sec.appendChild(form);
      var first = form.querySelector('.dep-input');
      if (first) first.focus();
    });
    head.appendChild(add);
    page.appendChild(head);
    pageBody = make('div', 'dep-pagebody');
    page.appendChild(pageBody);
  }

  /* Engine state lives in the page header: a pill for the timer and the
     one control that matters, Pause (stop the timer) or Resume. Both go
     through app.js's confirm sheet as the deployd service's stop/start. */
  function paintHeader(data) {
    if (!pageEngine) return;
    var n = (data.watched || []).length;
    text(pageSub, 'Watching ' + n + (n === 1 ? ' repo' : ' repos') +
      '. Each one redeploys when its branch on GitHub moves; checked every minute.');
    pageEngine.textContent = '';
    var t = data.timer;
    var pill = make('span', 'dep-pill ' + (t === 'active' ? 'is-ok' : 'is-warn'));
    text(pill, t === 'active' ? 'Polling' : t ? 'Paused' : 'Engine not installed');
    pill.title = t ? 'deployd.timer reports “' + t + '”' : 'No systemd timer found on this box';
    pageEngine.appendChild(pill);
    var a = app();
    if (t && a && typeof a.action === 'function') {
      var verb = t === 'active' ? 'stop' : 'start';
      var b = make('button', 'h-btn');
      b.type = 'button';
      text(b, t === 'active' ? 'Pause' : 'Resume');
      b.title = t === 'active' ? 'Stop polling: nothing redeploys until you resume'
                               : 'Start polling again';
      b.addEventListener('click', function () {
        if (!a.action('deployd', verb, b)) {
          text(b, 'Not available here');
          b.disabled = true;
        }
      });
      pageEngine.appendChild(b);
    }
  }

  function refresh() {
    var t = ++token;
    fetchDeployd(function (data) {
      if (t !== token) return;
      if (editing) { pendingData = data; return; }
      paint(data);
    });
  }

  function route() {
    var next = routeKey();
    var onPage = next === PAGE_ROUTE;
    if (page) page.hidden = !onPage;
    if (onPage) { buildPage(); document.title = 'Deploys · Launcher'; }
    if (next === key && tick) return;
    if (mount) mount.textContent = '';
    mount = onPage ? pageBody : detailMount;
    key = mount ? next : null;
    token++;
    editing = null;
    pendingData = null;
    if (mount) mount.textContent = '';
    if (tick) { clearInterval(tick); tick = null; }
    if (key !== null) {
      refresh();
      tick = setInterval(refresh, TICK_MS);
    }
  }

  window.addEventListener('hashchange', route);
  route();
})();
