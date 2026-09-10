/* notes.js — per-service developer notes
 *
 * A self-contained module. It reads the service key out of `location.hash`
 * (`#/service/<key>`), renders into `#notes-mount`, and talks to the notes API
 * itself. It never calls into app.js and holds no reference to anything app.js
 * owns, so the two can be edited independently.
 *
 * Every URL here is RELATIVE ("api/services/<key>/notes"), like the rest of the
 * frontend: the page is served at both `/` and `/home/`, and Tailscale strips
 * the `/home` prefix before proxying. An absolute path would silently break the
 * bookmarked URL.
 *
 * Nothing here ever touches innerHTML. Note bodies are user text and are only
 * ever set through textContent.
 */
(function () {
  'use strict';

  /* ---------- config ---------- */

  var MAX_TITLE = 120;      // server: MAX_NOTE_TITLE
  var MAX_BODY = 8000;      // server: MAX_NOTE_BODY
  var MAX_NOTES = 100;      // server: MAX_NOTES_PER_SERVICE
  var COUNT_FROM = 7000;    // show the body counter once it is worth showing
  var FETCH_TIMEOUT = 8000;
  var TICK_MS = 60000;      // re-word "2 minutes ago" while the page is open
  var FLASH_MS = 4000;

  var mount = document.getElementById('notes-mount');
  if (!mount) return;

  /* ---------- state ---------- */

  var key = null;           // service key currently on screen, null on the grid
  var token = 0;            // guards against a stale fetch painting a new page
  var notes = [];
  var openIds = {};         // note id -> true, so a refetch keeps what was open
  var composing = false;    // the "new note" form is on screen
  var editing = 0;          // notes with an editor open — never repaint over one
  var flashTimer = null;
  var tickTimer = null;
  var uid = 0;

  /* ---------- dom helpers ---------- */

  function make(tag, cls) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
  }

  function text(node, value) {
    node.textContent = value == null ? '' : String(value);
    return node;
  }

  var SVG_NS = 'http://www.w3.org/2000/svg';

  /* Drawn here, not fetched. The launcher has to render with no route out. */
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

  var CHEVRON = ['m9.5 5.5 6.5 6.5-6.5 6.5'];
  var PLUS = ['M12 5.5v13', 'M5.5 12h13'];

  function nextId(prefix) { uid++; return 'nt-' + prefix + '-' + uid; }

  /* fetch with a timeout, so a wedged backend shows a message rather than a
     control that never comes back. Mirrors app.js deliberately — this module
     does not borrow its helper, it carries its own. */
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
        return { ok: res.ok, status: res.status, data: data };
      });
    }, function (err) {
      if (timer) clearTimeout(timer);
      throw err;
    });
  }

  function apiBase() {
    return 'api/services/' + encodeURIComponent(key) + '/notes';
  }

  function msgFrom(res, fallback) {
    var m = res && res.data && (res.data.error || res.data.message);
    return (typeof m === 'string' && m) ? m : fallback;
  }

  /* ---------- time ----------
   *
   * Timestamps arrive as ISO-8601 UTC with a Z, so Date.parse needs no help.
   * The relative form is what you read; the absolute form lives in `title`,
   * because "3 days ago" is useless once you are trying to correlate it with
   * a log line.
   */

  function relTime(iso) {
    var t = Date.parse(iso);
    if (isNaN(t)) return '';
    var diff = Date.now() - t;
    var ahead = diff < 0;               // clock skew, or a note written "now"
    var s = Math.round(Math.abs(diff) / 1000);
    var out;

    if (s < 45) return 'just now';
    if (s < 90) { out = 'a minute'; }
    else {
      var m = Math.round(s / 60);
      if (m < 45) { out = m + ' minutes'; }
      else if (m < 90) { out = 'an hour'; }
      else {
        var h = Math.round(m / 60);
        if (h < 22) { out = h + ' hours'; }
        else if (h < 36) { out = 'a day'; }
        else {
          var d = Math.round(h / 24);
          if (d < 26) { out = d + ' days'; }
          else if (d < 46) { out = 'a month'; }
          else {
            var mo = Math.round(d / 30.44);
            if (mo < 11) { out = mo + ' months'; }
            else if (mo < 18) { out = 'a year'; }
            else { out = Math.round(d / 365.25) + ' years'; }
          }
        }
      }
    }
    return ahead ? 'in ' + out : out + ' ago';
  }

  function absTime(iso) {
    var t = Date.parse(iso);
    if (isNaN(t)) return String(iso || '');
    var d = new Date(t);
    try {
      return d.toLocaleString(undefined, { dateStyle: 'full', timeStyle: 'short' });
    } catch (e) {
      return d.toLocaleString();
    }
  }

  /* A span that re-words itself on the minute tick. The ISO value rides along
     on the node so the tick needs no bookkeeping of its own. */
  function timeNode(cls, iso, prefix) {
    var span = make('span', cls);
    span.setAttribute('data-nt-iso', iso);
    if (prefix) span.setAttribute('data-nt-prefix', prefix);
    span.setAttribute('title', absTime(iso));
    text(span, (prefix || '') + relTime(iso));
    return span;
  }

  function retime() {
    var nodes = mount.querySelectorAll('[data-nt-iso]');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      text(n, (n.getAttribute('data-nt-prefix') || '') +
              relTime(n.getAttribute('data-nt-iso')));
    }
  }

  /* ---------- derived titles ----------
   *
   * The server derives a title from the first line of the body when none is
   * given. Mirroring that rule here is what lets the form *show* you the title
   * you are about to get, and lets an edit tell a derived title from a typed
   * one — a derived title is, by definition, one equal to what the body would
   * derive. Keep this in step with derive_title() in server.py.
   */
  function deriveTitle(body) {
    var lines = String(body == null ? '' : body).split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\s+/g, ' ').replace(/^ +| +$/g, '');
      if (!line) continue;
      if (line.length <= MAX_TITLE) return line;
      var cut = line.slice(0, MAX_TITLE - 1);
      var space = cut.lastIndexOf(' ');
      if (space >= MAX_TITLE - 25) cut = cut.slice(0, space);
      return cut.replace(/ +$/, '') + '…';
    }
    return '';
  }

  function isDerived(note) {
    return note.title === deriveTitle(note.body);
  }

  /* What the open note shows. When the title was derived, the collapsed row is
     already showing the body's first line, so repeating it under itself just
     looks like a bug — expanding should reveal the rest, not the same line
     twice. Only an exact match is elided: a title the server truncated with an
     ellipsis is *not* the whole first line, so that line stays. */
  function bodyBelowTitle(note) {
    if (!isDerived(note)) return note.body;
    var lines = String(note.body || '').split('\n');
    var i = 0;
    while (i < lines.length && !lines[i].replace(/\s/g, '')) i++;
    if (i >= lines.length) return note.body;
    if (lines[i].replace(/\s+/g, ' ').replace(/^ +| +$/g, '') !== note.title) {
      return note.body;
    }
    var rest = lines.slice(i + 1);
    while (rest.length && !rest[0].replace(/\s/g, '')) rest.shift();
    return rest.join('\n').replace(/\s+$/, '');
  }

  /* ---------- persistent chrome ----------
   *
   * The section, its header and the announcer are built once and kept. Only
   * the list below them is rebuilt, so opening the form or expanding a note
   * never disturbs anything else on the page.
   */

  /* No `.d-sec` here: the mount point (`.d-side` in index.html) already
     carries a section's top rule and spacing, in both the two-column and the
     stacked layout. Adding a second one draws two hairlines 47px apart. */
  var section = make('section', 'nt-sec');

  var head = make('div', 'nt-head');
  var heading = text(make('h3', 'd-sec-h nt-h'), 'Notes');
  var count = make('span', 'nt-count');
  var newBtn = make('button', 'nt-new');
  newBtn.type = 'button';
  newBtn.appendChild(glyph(PLUS, '1.9'));
  newBtn.appendChild(text(make('span'), 'New note'));
  head.appendChild(heading);
  head.appendChild(count);
  head.appendChild(newBtn);

  var sub = make('p', 'nt-sub');
  var flash = make('p', 'nt-flash');
  flash.setAttribute('role', 'status');
  flash.hidden = true;

  var composeSlot = make('div', 'nt-slot');
  var list = make('ul', 'nt-list');
  var empty = make('div', 'nt-empty');
  var failure = make('div', 'nt-fail');
  failure.hidden = true;

  var live = make('p', 'nt-sr');
  live.setAttribute('role', 'status');
  live.setAttribute('aria-live', 'polite');

  section.appendChild(head);
  section.appendChild(sub);
  section.appendChild(flash);
  section.appendChild(failure);
  section.appendChild(composeSlot);
  section.appendChild(list);
  section.appendChild(empty);
  section.appendChild(live);

  function say(message) { text(live, message); }

  function setFlash(message, cls) {
    if (flashTimer) { clearTimeout(flashTimer); flashTimer = null; }
    if (!message) { flash.hidden = true; text(flash, ''); return; }
    flash.className = 'nt-flash' + (cls ? ' ' + cls : '');
    text(flash, message);
    flash.hidden = false;
    flashTimer = setTimeout(function () { setFlash(''); }, FLASH_MS);
  }

  newBtn.addEventListener('click', function () { openComposer(); });

  /* ---------- the form ----------
   *
   * One builder for both "write a note" and "edit this note". Returns a
   * handle rather than just a node, so the caller can drive it (focus it,
   * show a server error on it, lock it while a request is out) without
   * re-rendering and losing what has been typed.
   */
  function buildForm(opts) {
    var form = make('form', 'nt-form');
    form.setAttribute('novalidate', 'novalidate');

    var titleId = nextId('title');
    var bodyId = nextId('body');

    var titleWrap = make('p', 'nt-field');
    var titleLab = text(make('label', 'nt-label'), 'Title');
    titleLab.setAttribute('for', titleId);
    var title = make('input', 'nt-input');
    title.id = titleId;
    title.type = 'text';
    title.maxLength = MAX_TITLE;
    title.autocomplete = 'off';
    title.setAttribute('autocapitalize', 'sentences');
    title.setAttribute('spellcheck', 'false');
    title.placeholder = 'Optional';
    title.value = opts.title || '';
    titleWrap.appendChild(titleLab);
    titleWrap.appendChild(title);

    var bodyWrap = make('p', 'nt-field');
    var bodyLab = text(make('label', 'nt-label'), 'Note');
    bodyLab.setAttribute('for', bodyId);
    var body = make('textarea', 'nt-input nt-area');
    body.id = bodyId;
    body.rows = 5;
    body.setAttribute('spellcheck', 'true');
    body.placeholder = opts.placeholder || '';
    body.value = opts.body || '';
    bodyWrap.appendChild(bodyLab);
    bodyWrap.appendChild(body);

    var hint = make('p', 'nt-hint');
    var counter = make('span', 'nt-counter');
    counter.hidden = true;

    var err = make('p', 'nt-err');
    err.setAttribute('role', 'alert');
    err.hidden = true;

    var actions = make('div', 'nt-actions');
    var save = make('button', 'btn btn-primary nt-act');
    save.type = 'submit';
    text(save, opts.submitLabel || 'Save note');
    var cancel = make('button', 'btn nt-act');
    cancel.type = 'button';
    text(cancel, 'Cancel');
    actions.appendChild(save);
    actions.appendChild(cancel);

    form.appendChild(titleWrap);
    form.appendChild(bodyWrap);
    var foot = make('div', 'nt-formfoot');
    foot.appendChild(hint);
    foot.appendChild(counter);
    form.appendChild(foot);
    form.appendChild(err);
    form.appendChild(actions);

    /* The title rule is the one genuinely surprising thing about this API, so
       the form states it, and then shows you the exact title you are going to
       get as you type. Nothing to discover after the fact. */
    function paintHint() {
      var t = title.value.replace(/^\s+|\s+$/g, '');
      var d = deriveTitle(body.value);
      if (t) {
        text(hint, 'Clear the title and the first line of the note becomes it again.');
        hint.className = 'nt-hint';
      } else if (d) {
        text(hint, 'Title: “' + d + '”');
        hint.className = 'nt-hint is-derived';
      } else {
        text(hint, 'Leave the title blank and the first line of the note becomes it.');
        hint.className = 'nt-hint';
      }

      var n = body.value.length;
      if (n < COUNT_FROM) {
        counter.hidden = true;
      } else {
        counter.hidden = false;
        counter.className = 'nt-counter' + (n > MAX_BODY ? ' is-over' : '');
        text(counter, n + ' / ' + MAX_BODY);
      }
    }

    function grow() {
      body.style.height = 'auto';
      var h = body.scrollHeight;
      if (h > 420) h = 420;
      if (h > 0) body.style.height = h + 'px';
    }

    title.addEventListener('input', paintHint);
    body.addEventListener('input', function () { paintHint(); grow(); });

    var ctl = {
      node: form,
      focus: function () {
        try { (opts.focusTitle ? title : body).focus({ preventScroll: true }); }
        catch (e) { (opts.focusTitle ? title : body).focus(); }
      },
      values: function () {
        return {
          title: title.value.replace(/^\s+|\s+$/g, ''),
          body: body.value.replace(/\s+$/, '')
        };
      },
      error: function (message) {
        if (!message) { err.hidden = true; text(err, ''); return; }
        text(err, message);
        err.hidden = false;
      },
      busy: function (on) {
        save.disabled = !!on;
        cancel.disabled = !!on;
        title.disabled = !!on;
        body.disabled = !!on;
        text(save, on ? 'Saving…' : (opts.submitLabel || 'Save note'));
      },
      grow: grow
    };

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var v = ctl.values();
      if (!v.title && !v.body) {
        ctl.error('A note needs something in it — a title, a body, or both.');
        try { body.focus(); } catch (e2) { /* ignore */ }
        return;
      }
      ctl.error('');
      opts.onSubmit(v, ctl);
    });

    cancel.addEventListener('click', function () { opts.onCancel(); });

    /* Escape backs out, Cmd/Ctrl-Enter saves — the same two keys the name and
       description fields above already answer to. */
    form.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' || e.key === 'Esc') {
        e.preventDefault();
        opts.onCancel();
      } else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        if (!save.disabled) form.dispatchEvent(new Event('submit', { cancelable: true }));
      } else if (e.key === 'Enter' && e.target === title) {
        e.preventDefault();
        try { body.focus(); } catch (e3) { /* ignore */ }
      }
    });

    paintHint();
    return ctl;
  }

  /* ---------- new note ---------- */

  var composer = null;

  function openComposer() {
    if (composing) { if (composer) composer.focus(); return; }
    if (notes.length >= MAX_NOTES) {
      setFlash('This service is at the limit of ' + MAX_NOTES +
               ' notes. Delete one to make room.', 'is-warn');
      return;
    }
    composing = true;
    newBtn.hidden = true;

    composer = buildForm({
      submitLabel: 'Save note',
      focusTitle: false,
      placeholder: 'Why it is set up this way, what broke, what to check first…',
      onSubmit: createNote,
      onCancel: closeComposer
    });
    composeSlot.appendChild(composer.node);
    composer.grow();
    composer.focus();
    paintEmpty();
  }

  function closeComposer() {
    composing = false;
    composer = null;
    composeSlot.textContent = '';
    newBtn.hidden = false;
    paintEmpty();
    try { newBtn.focus({ preventScroll: true }); } catch (e) { newBtn.focus(); }
  }

  function createNote(values, ctl) {
    var forKey = key;
    ctl.busy(true);

    request(apiBase(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: values.title, body: values.body })
    }).then(function (res) {
      if (forKey !== key) return;
      ctl.busy(false);

      if (res.status === 409) {
        /* Deliberately not the server's wording here: "too many notes for
           beszel (max 100)" is a log line, not something to read while you
           are holding a note you just wrote. */
        ctl.error('This service already holds ' + MAX_NOTES + ' notes, the most it can. ' +
                  'Delete one below and save again — what you typed is still here.');
        refresh();
        return;
      }
      if (res.status === 400) {
        ctl.error(explain(msgFrom(res, 'The server would not accept that note.')));
        return;
      }
      if (res.status === 404) {
        ctl.error('This service is not in the registry any more, so the note was not saved.');
        return;
      }
      if (!res.ok || !res.data || !res.data.id) {
        ctl.error(msgFrom(res, 'Could not save that note (HTTP ' + res.status + ').'));
        return;
      }

      openIds[res.data.id] = true;      // land on the note you just wrote
      closeComposer();
      say('Note saved');
      refresh();
    }, function () {
      if (forKey !== key) return;
      ctl.busy(false);
      ctl.error('Could not reach the launcher backend to save that note. Nothing was lost — try again.');
    });
  }

  /* Server messages are terse and field-shaped ("body is too long (max 8000
     characters)"). Say the same thing the way a person would. */
  function explain(message) {
    var m = String(message || '');
    if (/body is too long/i.test(m)) {
      return 'That note is longer than ' + MAX_BODY +
             ' characters. Trim it, or split it into two notes.';
    }
    if (/title is too long/i.test(m)) {
      return 'The title is longer than ' + MAX_TITLE + ' characters.';
    }
    if (/note is empty/i.test(m)) {
      return 'A note needs something in it — a title, a body, or both.';
    }
    m = m.charAt(0).toUpperCase() + m.slice(1);
    return /[.!?]$/.test(m) ? m : m + '.';
  }

  /* ---------- one note ----------
   *
   * Each item owns its own little state machine — collapsed, open, editing,
   * confirming a delete — and repaints only itself. Nothing above it moves.
   */
  function buildItem(note) {
    var li = make('li', 'nt-item');
    var panelId = nextId('panel');
    var mode = 'view';                  // view | edit | confirm
    var open = !!openIds[note.id];
    var form = null;

    var row = make('button', 'nt-row');
    row.type = 'button';
    row.id = nextId('row');
    row.setAttribute('aria-controls', panelId);

    var chev = make('span', 'nt-chev');
    chev.appendChild(glyph(CHEVRON, '1.9'));
    var line = text(make('span', 'nt-line'), note.title);
    var when = timeNode('nt-when', note.updated_at);

    row.appendChild(chev);
    row.appendChild(line);
    row.appendChild(when);

    var panel = make('div', 'nt-panel');
    panel.id = panelId;
    panel.setAttribute('role', 'region');
    panel.setAttribute('aria-labelledby', row.id);

    li.appendChild(row);
    li.appendChild(panel);

    function paintRow() {
      row.setAttribute('aria-expanded', open ? 'true' : 'false');
      li.className = 'nt-item' + (open ? ' is-open' : '');
      panel.hidden = !open;
    }

    function viewPanel() {
      panel.textContent = '';

      var shown = bodyBelowTitle(note);
      if (shown) {
        panel.appendChild(text(make('p', 'nt-text'), shown));
      } else {
        panel.appendChild(text(make('p', 'nt-text is-empty'),
          'The title line is the whole note.'));
      }

      var foot = make('div', 'nt-foot');
      var stamp = make('span', 'nt-stamp');
      stamp.appendChild(timeNode('nt-when', note.created_at, 'Added '));
      if (note.updated_at !== note.created_at) {
        stamp.appendChild(text(make('span', 'nt-dot'), '·'));
        stamp.appendChild(timeNode('nt-when', note.updated_at, 'edited '));
      }
      foot.appendChild(stamp);

      var tools = make('span', 'nt-tools');
      var edit = make('button', 'nt-tool');
      edit.type = 'button';
      text(edit, 'Edit');
      edit.addEventListener('click', function () { setMode('edit'); });

      var del = make('button', 'nt-tool nt-danger');
      del.type = 'button';
      text(del, 'Delete');
      del.addEventListener('click', function () { setMode('confirm'); });

      tools.appendChild(edit);
      tools.appendChild(del);
      foot.appendChild(tools);
      panel.appendChild(foot);
    }

    /* An inline two-step, not a modal. A note is small and local; throwing a
       dialog over the whole page to confirm one is heavier than the action. */
    function confirmPanel() {
      viewPanel();
      var foot = panel.lastChild;
      foot.textContent = '';
      foot.className = 'nt-foot is-confirm';

      var q = text(make('span', 'nt-ask'), 'Delete this note? It cannot be undone.');
      var tools = make('span', 'nt-tools');

      var yes = make('button', 'nt-tool nt-danger is-armed');
      yes.type = 'button';
      text(yes, 'Delete');
      yes.addEventListener('click', function () { doDelete(yes, no); });

      var no = make('button', 'nt-tool');
      no.type = 'button';
      text(no, 'Cancel');
      no.addEventListener('click', function () { setMode('view'); });

      tools.appendChild(yes);
      tools.appendChild(no);
      foot.appendChild(q);
      foot.appendChild(tools);

      foot.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' || e.key === 'Esc') { e.preventDefault(); setMode('view'); }
      });

      /* Focus lands on Cancel, not Delete: the second step exists to be a
         speed bump, and Enter should not sail straight through it. */
      try { no.focus({ preventScroll: true }); } catch (e) { no.focus(); }
    }

    function editPanel() {
      panel.textContent = '';
      /* A derived title is shown as what it is — absent, with the derivation
         previewed underneath — so editing the body re-derives it instead of
         silently freezing yesterday's first line into a typed title. */
      form = buildForm({
        title: isDerived(note) ? '' : note.title,
        body: note.body,
        submitLabel: 'Save changes',
        focusTitle: false,
        placeholder: 'Why it is set up this way, what broke, what to check first…',
        onSubmit: submitEdit,
        onCancel: function () { setMode('view'); }
      });
      panel.appendChild(form.node);
      form.grow();
      form.focus();
    }

    function submitEdit(values, ctl) {
      var forKey = key;
      ctl.busy(true);

      request(apiBase() + '/' + encodeURIComponent(note.id), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title: values.title, body: values.body })
      }).then(function (res) {
        if (forKey !== key) return;
        ctl.busy(false);

        if (res.status === 404) {
          /* Gone from under us — another tab, or another phone. Say so and
             show the list as it actually is now. */
          setFlash('That note is no longer there — it was deleted somewhere else. The list below is current.', 'is-warn');
          refresh();
          return;
        }
        if (res.status === 400) {
          ctl.error(explain(msgFrom(res, 'The server would not accept that note.')));
          return;
        }
        if (!res.ok || !res.data || !res.data.id) {
          ctl.error(msgFrom(res, 'Could not save that change (HTTP ' + res.status + ').'));
          return;
        }

        note = res.data;
        text(line, note.title);
        when.setAttribute('data-nt-iso', note.updated_at);
        when.setAttribute('title', absTime(note.updated_at));
        text(when, relTime(note.updated_at));
        setMode('view');
        say('Note saved');
      }, function () {
        if (forKey !== key) return;
        ctl.busy(false);
        ctl.error('Could not reach the launcher backend to save that change.');
      });
    }

    function doDelete(yes, no) {
      var forKey = key;
      yes.disabled = true;
      no.disabled = true;
      text(yes, 'Deleting…');

      request(apiBase() + '/' + encodeURIComponent(note.id), { method: 'DELETE' })
        .then(function (res) {
          if (forKey !== key) return;

          if (res.status === 404) {
            /* Already gone. That is the outcome that was asked for, so it is
               not an error — just a note that it happened elsewhere. */
            setFlash('That note had already been deleted somewhere else.', '');
            delete openIds[note.id];
            refresh();
            return;
          }
          if (!res.ok && res.status !== 204) {
            yes.disabled = false;
            no.disabled = false;
            text(yes, 'Delete');
            setFlash(msgFrom(res, 'Could not delete that note (HTTP ' + res.status + ').'), 'is-warn');
            return;
          }

          delete openIds[note.id];
          say('Note deleted');
          setFlash('Note deleted.', '');
          refresh();
        }, function () {
          if (forKey !== key) return;
          yes.disabled = false;
          no.disabled = false;
          text(yes, 'Delete');
          setFlash('Could not reach the launcher backend to delete that note.', 'is-warn');
        });
    }

    function setMode(next) {
      if (mode === 'edit' && next !== 'edit') editing--;
      if (next === 'edit' && mode !== 'edit') editing++;
      mode = next;
      if (mode === 'edit') { open = true; openIds[note.id] = true; }
      paintRow();
      if (!open) { panel.textContent = ''; return; }
      if (mode === 'edit') editPanel();
      else if (mode === 'confirm') confirmPanel();
      else viewPanel();
      if (next === 'view' && document.activeElement === document.body) {
        try { row.focus({ preventScroll: true }); } catch (e) { /* ignore */ }
      }
    }

    row.addEventListener('click', function () {
      open = !open;
      if (open) openIds[note.id] = true; else delete openIds[note.id];
      if (mode === 'edit') editing--;
      mode = 'view';
      paintRow();
      if (open) viewPanel(); else panel.textContent = '';
    });

    paintRow();
    if (open) viewPanel();
    return li;
  }

  /* ---------- list ---------- */

  function paintCount() {
    var full = notes.length >= MAX_NOTES;
    /* A disabled control with no reason next to it is a dead end, so the
       reason goes on the button and, more visibly, in the sub-line. */
    newBtn.disabled = full;
    if (full) {
      newBtn.setAttribute('title', 'At the limit of ' + MAX_NOTES +
                          ' notes — delete one to add another');
    } else {
      newBtn.removeAttribute('title');
    }
    if (!notes.length) { count.hidden = true; return; }
    count.hidden = false;
    text(count, String(notes.length));
    count.setAttribute('title', notes.length + ' of ' + MAX_NOTES + ' notes');
  }

  function paintEmpty() {
    /* The empty state has to earn the space it takes, so it says what a note
       is *for* — the section above already says what the service is. */
    empty.textContent = '';
    if (notes.length || composing) { empty.hidden = true; return; }
    empty.hidden = false;

    empty.appendChild(text(make('p', 'nt-empty-h'), 'No notes yet.'));
    empty.appendChild(text(make('p', 'nt-empty-p'),
      'The description above says what this service is. Notes are for everything ' +
      'else you would otherwise have to remember: why it is configured the way it ' +
      'is, what broke last time and what fixed it, which thing to check first when ' +
      'it starts misbehaving.'));

    var cta = make('button', 'nt-cta');
    cta.type = 'button';
    text(cta, 'Write the first note');
    cta.addEventListener('click', function () { openComposer(); });
    empty.appendChild(cta);
  }

  function paintList() {
    editing = 0;                  // every editor on screen is about to go away
    list.textContent = '';
    var frag = document.createDocumentFragment();
    for (var i = 0; i < notes.length; i++) frag.appendChild(buildItem(notes[i]));
    list.appendChild(frag);
    list.hidden = !notes.length;

    sub.hidden = !notes.length;
    text(sub, notes.length >= MAX_NOTES
      ? 'Operational context — newest first. At the limit of ' + MAX_NOTES +
        ' notes; delete one to add another.'
      : 'Operational context — newest first.');

    paintCount();
    paintEmpty();
  }

  /* ---------- loading ---------- */

  function fail(message) {
    failure.textContent = '';
    failure.hidden = false;
    failure.appendChild(text(make('span'), message));
    var retry = make('button', 'nt-tool');
    retry.type = 'button';
    text(retry, 'Retry');
    retry.addEventListener('click', function () {
      retry.disabled = true;
      text(retry, 'Retrying…');
      refresh();
    });
    failure.appendChild(retry);
  }

  function refresh() {
    if (!key) return;
    var mine = ++token;
    var forKey = key;

    return request(apiBase()).then(function (res) {
      if (mine !== token || forKey !== key) return;

      if (res.status === 404) {
        /* No such service. app.js is already saying so at the top of the
           page; a notes section for a service that does not exist would just
           be noise, so this one stands down. */
        section.hidden = true;
        return;
      }
      if (!res.ok || !res.data || !Array.isArray(res.data.notes)) {
        section.hidden = false;
        notes = [];
        list.textContent = '';
        list.hidden = true;
        sub.hidden = true;
        paintCount();
        empty.hidden = true;
        fail(res.ok
          ? 'The notes API answered with something unexpected.'
          : 'Could not load notes (HTTP ' + res.status + ').');
        return;
      }

      failure.hidden = true;
      section.hidden = false;
      notes = res.data.notes;
      paintList();
    }, function () {
      if (mine !== token || forKey !== key) return;
      section.hidden = false;
      notes = [];
      list.textContent = '';
      list.hidden = true;
      sub.hidden = true;
      empty.hidden = true;
      paintCount();
      fail('No response from the launcher backend, so notes could not be loaded.');
    });
  }

  /* ---------- routing ----------
   *
   * The hash is the only thing this module reads from the outside world.
   */
  function routeKey() {
    var m = /^#\/service\/(.+)$/.exec(String(location.hash || ''));
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  }

  function enter(next) {
    key = next;
    token++;
    notes = [];
    openIds = {};
    composing = false;
    editing = 0;
    composer = null;
    composeSlot.textContent = '';
    list.textContent = '';
    list.hidden = true;
    sub.hidden = true;
    empty.hidden = true;
    failure.hidden = true;
    newBtn.hidden = false;
    newBtn.disabled = false;
    count.hidden = true;
    setFlash('');
    text(live, '');

    /* Hidden until the first response lands: a section that flashes an empty
       state and then fills in reads as a bug. */
    section.hidden = true;
    if (!section.parentNode) mount.appendChild(section);
    refresh();

    if (!tickTimer) tickTimer = setInterval(retime, TICK_MS);
  }

  function leave() {
    key = null;
    token++;
    notes = [];
    openIds = {};
    composing = false;
    editing = 0;
    composer = null;
    if (section.parentNode) mount.removeChild(section);
    composeSlot.textContent = '';
    list.textContent = '';
    if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
    if (flashTimer) { clearTimeout(flashTimer); flashTimer = null; }
  }

  function route() {
    var next = routeKey();
    if (next === key) return;
    if (next) enter(next);
    else leave();
  }

  window.addEventListener('hashchange', route);

  /* Coming back to the tab after a while: the relative times are stale, and
     another device may have added a note. */
  document.addEventListener('visibilitychange', function () {
    if (document.hidden || !key) return;
    retime();
    /* Never repaint over something half-typed. A refetch can wait until the
       form is closed; losing a note you were writing cannot be undone. */
    if (!composing && !editing) refresh();
  });

  route();
}());
