/* deployd.js — deployment activity on the detail page
 *
 * A self-contained module, same contract as notes.js: it reads the service
 * key out of `location.hash` (`#/service/<key>`), renders into
 * `#deployd-mount`, and talks to `api/deployd` itself. Nothing app.js owns
 * is touched, and nothing here is called from app.js.
 *
 * What it draws depends on which page is open:
 *   #/service/deployd  — the whole watched table: timer state, per-service
 *                         ref → deployed sha → state, expandable log tails,
 *                         orphaned state files.
 *   #/service/<other>  — just that service's row, when deployd watches it.
 *                         Nothing at all when it does not: the mount stays
 *                         empty rather than showing a hollow section.
 *
 * Every URL is relative ("api/deployd") for the same reason as the rest of
 * the frontend: the page is served at both `/` and `/home/`. All text lands
 * through textContent — log tails are arbitrary command output.
 */
(function () {
  'use strict';

  var mount = document.getElementById('deployd-mount');
  if (!mount) return;

  var TICK_MS = 60000;       // deploys are slow; the app's own poll is 30s
  var FETCH_TIMEOUT = 8000;

  var key = null;            // service key on screen, null on the grid
  var token = 0;             // stale-fetch guard
  var tick = null;

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

  function fetchDeployd(done) {
    var xhr = new XMLHttpRequest();
    var timer = setTimeout(function () { xhr.abort(); }, FETCH_TIMEOUT);
    xhr.open('GET', 'api/deployd', true);
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      clearTimeout(timer);
      var data = null;
      if (xhr.status >= 200 && xhr.status < 300) {
        try { data = JSON.parse(xhr.responseText); } catch (e) { data = null; }
      }
      done(data);
    };
    xhr.onerror = function () { clearTimeout(timer); done(null); };
    xhr.onabort = function () { clearTimeout(timer); };
    try { xhr.send(); } catch (e) { clearTimeout(timer); done(null); }
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

  /* One watched service: key, ref -> sha, state chip, and its log tail in a
     disclosure when there is one. `full` adds repo and the failure record. */
  function row(entry, full) {
    var wrap = make('div', 'dep-row dep-' + entry.state);
    var top = make('div', 'dep-row-top');

    var name = make('span', 'dep-key');
    text(name, entry.key);
    top.appendChild(name);

    var track = make('span', 'dep-track');
    var bits = [];
    if (full && entry.repo) {
      bits.push(entry.repo.replace(/^https?:\/\//, ''));
    }
    bits.push(entry.ref || 'main');
    bits.push('→');
    bits.push(sha7(entry.sha) || '—');
    text(track, bits.join(' '));
    top.appendChild(track);

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
    wrap.appendChild(top);

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

    if (key === 'deployd') {
      text(h, 'Deployment activity');
      sec.appendChild(h);

      var status = make('p', 'dep-status');
      var t = data.timer;
      text(status, t === 'active' ? 'Timer active — polling each tick.'
                 : t ? 'Timer reports “' + t + '”.'
                 : 'Timer state unknown (no systemd, or not installed).');
      status.classList.add(t === 'active' ? 'is-ok' : 'is-warn');
      sec.appendChild(status);

      if (data.self_update_pending) {
        var su = make('p', 'dep-note');
        text(su, 'A deployd self-update failed last tick and will be retried.');
        sec.appendChild(su);
      }
      if (!data.installed) {
        var ni = make('p', 'dep-note');
        text(ni, 'No state yet — deployd has not run on this box.');
        sec.appendChild(ni);
      }
      rows = data.watched || [];
      if (data.orphans && data.orphans.length) {
        var orph = make('p', 'dep-note');
        text(orph, 'Stale state for keys no longer in the registry: ' +
                  data.orphans.join(', '));
        sec.appendChild(orph);
      }
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
    for (var j = 0; j < rows.length; j++) {
      list.appendChild(row(rows[j], key === 'deployd'));
    }
    sec.appendChild(list);
    mount.appendChild(sec);
    restore(snap);
  }

  /* ---------- routing ---------- */

  function routeKey() {
    var m = /^#\/service\/(.+)$/.exec(String(location.hash || ''));
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  }

  function refresh() {
    var t = ++token;
    fetchDeployd(function (data) {
      if (t !== token) return;
      paint(data);
    });
  }

  function route() {
    var next = routeKey();
    if (next === key && tick) return;
    key = next;
    token++;
    mount.textContent = '';
    if (tick) { clearInterval(tick); tick = null; }
    if (key !== null) {
      refresh();
      tick = setInterval(refresh, TICK_MS);
    }
  }

  window.addEventListener('hashchange', route);
  route();
})();
