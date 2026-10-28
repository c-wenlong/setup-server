/* ghsource.js — the Source section on a GitHub app's detail page
 *
 * A self-contained module, same contract as notes.js: it reads the service
 * key out of `location.hash` (`#/service/<key>`), renders into
 * `#ghsource-mount`, and talks to the server itself. It draws only for an
 * app built from GitHub (its payload carries a `github` object) and
 * nothing at all for anything else.
 *
 * What it shows: the repo and branch the app builds from, and whether this
 * repo (setup-server) holds a copy of its definition. Export to repo asks
 * the server to open a pull request adding app/web/apps/<key>.json, so a
 * rebuilt box can bring the app back. The .env never leaves the box.
 *
 * Every URL is relative (the page is served at `/` and `/home/`); all text
 * lands through textContent.
 */
(function () {
  'use strict';

  var mount = document.getElementById('ghsource-mount');
  if (!mount) return;
  var FETCH_TIMEOUT = 60000;   // a branch, a file and a PR on GitHub
  var busy = null;             // key being exported: repaints keep the button off
  var last = {};               // key -> {url, error}: url only until the next payload

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }
  function text(node, s) {
    node.textContent = s == null ? '' : String(s);
    return node;
  }

  function routeKey() {
    var m = /^#\/service\/(.+)$/.exec(String(location.hash || ''));
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  }

  function service(key) {
    var a = window.LauncherApp;
    var list = (a && typeof a.services === 'function') ? a.services() : [];
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i];
    return null;
  }

  function link(href, label) {
    var a = text(make('a'), label);
    a.href = href;
    a.target = '_blank';
    a.rel = 'noopener';
    return a;
  }

  var STATUS = {
    same: ['is-ok', 'Saved in this repo as '],
    differs: ['is-warn', 'This repo has an older copy at '],
    absent: ['', 'Only on this box. Export it so a rebuilt box can bring it back from ']
  };

  function paint() {
    var key = routeKey();
    var svc = key ? service(key) : null;
    var gh = svc && svc.github;
    /* The 30 s poll repaints this; keep a keyboard user's focus on the button. */
    var refocus = mount.contains(document.activeElement);
    mount.textContent = '';
    if (!gh || typeof gh.repo !== 'string') return;

    var sec = make('section', 'd-sec ghs');
    sec.appendChild(text(make('h3', 'd-sec-h'), 'Source'));

    var from = make('p', 'ghs-line');
    from.appendChild(document.createTextNode('Builds from '));
    from.appendChild(link('https://github.com/' + gh.repo + '/tree/' + encodeURIComponent(gh.ref),
                          gh.repo));
    from.appendChild(document.createTextNode(' on '));
    from.appendChild(text(make('code'), gh.ref));
    from.appendChild(document.createTextNode(', redeployed on every push.'));
    sec.appendChild(from);

    var st = STATUS[gh.in_repo] || STATUS.absent;
    var status = make('p', 'ghs-status ' + st[0]);
    status.appendChild(document.createTextNode(st[1]));
    status.appendChild(text(make('code'), 'app/web/apps/' + key + '.json'));
    status.appendChild(document.createTextNode('.'));
    sec.appendChild(status);

    var mine = last[key] || {};
    var pr = mine.url || gh.export_pr;
    if (pr && gh.in_repo !== 'same') {
      var open = make('p', 'ghs-line');
      open.appendChild(document.createTextNode('Export pull request: '));
      open.appendChild(link(pr, pr.replace(/^https:\/\/github\.com\//, '')));
      open.appendChild(document.createTextNode('. Merge it to save this version.'));
      sec.appendChild(open);
    }

    if (gh.in_repo !== 'same') {
      var btn = make('button', 'd-ctl-btn');
      btn.type = 'button';
      text(btn, busy === key ? 'Opening a pull request…'
                : pr ? 'Export again'
                : gh.in_repo === 'differs' ? 'Export changes' : 'Export to repo');
      btn.disabled = busy === key;
      btn.title = 'Open a pull request on setup-server adding this app’s definition (no secrets)';
      btn.addEventListener('click', function () { exportApp(key); });
      sec.appendChild(btn);
    }
    if (refocus) setTimeout(function () {
      var b = mount.querySelector('button');
      if (b && !b.disabled) b.focus();
    }, 0);

    if (mine.error) {
      sec.appendChild(text(make('p', 'ghs-err'), mine.error));
    }
    mount.appendChild(sec);
  }

  function exportApp(key) {
    if (busy) return;
    busy = key;
    last[key] = {};
    paint();
    var xhr = new XMLHttpRequest();
    var timer = setTimeout(function () { xhr.abort(); }, FETCH_TIMEOUT);
    xhr.open('POST', 'api/apps/' + encodeURIComponent(key) + '/export', true);
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.onloadend = function () {
      clearTimeout(timer);
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (e) { /* keep */ }
      busy = null;
      if (xhr.status === 200 && data && data.url) {
        last[key] = { url: data.url };
        var a = window.LauncherApp;
        if (a && typeof a.refresh === 'function') a.refresh();
      } else {
        last[key] = { error: (data && data.error) || (xhr.status
          ? 'Export failed (HTTP ' + xhr.status + ').'
          : 'Export timed out or the launcher did not answer. Check GitHub before retrying.') };
      }
      paint();
    };
    xhr.send('{}');
  }

  window.addEventListener('hashchange', paint);
  /* A fresh payload carries the server's own export_pr, which knows when the
     definition has changed since that PR; the url held here is only for
     the moment between the export reply and that payload. */
  document.addEventListener('launcher:services', function () {
    Object.keys(last).forEach(function (k) { delete last[k].url; });
    paint();
  });
  paint();
})();
