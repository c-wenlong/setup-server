/* tooltip.js — hover-intent description bubble for the service grid.
 *
 * Rest the pointer on a tile for HOVER_INTENT_MS and a small bubble with that
 * service's description appears beside it. Sweeping across the grid arms and
 * disarms a single timer, so crossing six tiles shows nothing.
 *
 * Self-contained on purpose: it touches no app.js global, binds no listener to
 * an individual tile (app.js reconciles those nodes away), and reads only two
 * things from the page — `#grid` and the `data-key` on each tile. Everything
 * here is progressive enhancement; the description lives in full on the detail
 * page, so the bubble is aria-hidden decoration and never takes focus.
 *
 * Desktop only, and every URL relative — the page is served at `/` and
 * `/home/` both.
 */
(function () {
  'use strict';

  /* ---------------------------------------------------------------- knob --
   * The intent delay, in ms. Below ~700 it fires while the cursor is merely
   * crossing the grid; at 2000 most people have already moved on. */
  var HOVER_INTENT_MS = 1000;
  /* ---------------------------------------------------------------------- */

  var GAP = 10;      /* space between tile edge and bubble */
  var EDGE = 8;      /* keep-out margin against the viewport */
  var ARROW_INSET = 16; /* how close the caret may get to a bubble corner */
  var LIST_TTL = 30000; /* re-read api/services at most this often */

  var mq = window.matchMedia('(hover: hover) and (pointer: fine)');

  var bubble = null, textEl = null, arrowEl = null;
  var timer = 0;
  var armed = null;   /* tile the pointer is currently resting on */
  var shown = null;   /* tile the visible bubble belongs to */
  var bound = false;

  /* key -> description string ('' means "known to have none") */
  var desc = Object.create(null);
  var listAt = 0, listWait = null, keyWait = Object.create(null);
  /* Does the list payload actually carry descriptions? It is optional there.
     If one full read turns up none, stop asking it and use the detail
     endpoint, which always has them. */
  var listUseful = true;

  function noop() {}

  /* ---------- data ----------
   *
   * One cached read of api/services, refreshed lazily only when a hover finds
   * no entry. app.js already polls every 30s; this must not add to that. When
   * the list payload carries no `description` (it is optional there), fall
   * back to that service's detail endpoint, once, and cache the answer. */

  function getJSON(url) {
    return fetch(url, { headers: { Accept: 'application/json' } })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      });
  }

  function store(key, value) {
    if (typeof value === 'string') desc[key] = value.trim();
  }

  function loadList() {
    if (!listUseful) return Promise.resolve();
    if (listWait) return listWait;
    if (Date.now() - listAt < LIST_TTL) return Promise.resolve();
    listWait = getJSON('api/services').then(function (data) {
      var list = (data && data.services) || [];
      var found = 0;
      for (var i = 0; i < list.length; i++) {
        if (!list[i] || !list[i].key) continue;
        store(list[i].key, list[i].description);
        if (typeof list[i].description === 'string') found++;
      }
      listUseful = found > 0;
      listAt = Date.now();
    }, noop).then(function () { listWait = null; });
    return listWait;
  }

  function loadOne(key) {
    if (keyWait[key]) return keyWait[key];
    keyWait[key] = getJSON('api/services/' + encodeURIComponent(key))
      .then(function (d) { if (d) store(key, d.description); }, noop)
      .then(function () { delete keyWait[key]; });
    return keyWait[key];
  }

  function lookup(key) {
    if (typeof desc[key] === 'string') return Promise.resolve(desc[key]);
    return loadList().then(function () {
      if (typeof desc[key] === 'string') return desc[key];
      return loadOne(key).then(function () { return desc[key]; });
    });
  }

  /* ---------- element ---------- */

  function ensure() {
    if (bubble) return;
    bubble = document.createElement('div');
    bubble.className = 'tt';
    bubble.setAttribute('aria-hidden', 'true');
    bubble.setAttribute('role', 'presentation');
    bubble.hidden = true;

    arrowEl = document.createElement('span');
    arrowEl.className = 'tt-arrow';

    textEl = document.createElement('span');
    textEl.className = 'tt-text';

    bubble.appendChild(arrowEl);
    bubble.appendChild(textEl);
    document.body.appendChild(bubble);
  }

  /* ---------- geometry ----------
   *
   * Below the tile by preference, flipped above when the room is not there,
   * then clamped against all four viewport edges. The caret tracks the tile's
   * centre and is dropped when clamping has pulled the bubble off that line. */

  function place(tile) {
    var r = tile.getBoundingClientRect();
    var vw = document.documentElement.clientWidth;
    var vh = document.documentElement.clientHeight;

    bubble.classList.remove('tt-above', 'tt-below');
    bubble.style.left = '0px';
    bubble.style.top = '0px';

    var w = bubble.offsetWidth;
    var h = bubble.offsetHeight;

    var roomBelow = vh - EDGE - (r.bottom + GAP);
    var roomAbove = (r.top - GAP) - EDGE;
    var below = roomBelow >= h || roomBelow >= roomAbove;

    var wantTop = below ? r.bottom + GAP : r.top - GAP - h;
    var top = Math.min(Math.max(wantTop, EDGE), Math.max(EDGE, vh - EDGE - h));

    var cx = r.left + r.width / 2;
    var left = Math.round(cx - w / 2);
    left = Math.min(Math.max(left, EDGE), Math.max(EDGE, vw - EDGE - w));

    bubble.classList.add(below ? 'tt-below' : 'tt-above');
    bubble.style.left = left + 'px';
    bubble.style.top = Math.round(top) + 'px';

    var ax = Math.round(cx - left);
    var aligned = Math.abs(top - wantTop) < 1 &&
                  ax >= ARROW_INSET && ax <= w - ARROW_INSET;
    arrowEl.hidden = !aligned;
    if (aligned) arrowEl.style.left = ax + 'px';
  }

  /* ---------- show / hide ---------- */

  function clearTimer() {
    if (timer) { clearTimeout(timer); timer = 0; }
  }

  function hide() {
    clearTimer();
    armed = null;
    if (!shown) return;
    shown = null;
    document.removeEventListener('mousemove', onDrift, true);
    if (bubble) {
      bubble.classList.remove('tt-in');
      bubble.hidden = true;
    }
  }

  function show(str, tile) {
    ensure();
    textEl.textContent = str;          /* text, never markup */
    bubble.hidden = false;
    bubble.classList.remove('tt-in');
    place(tile);
    /* reflow so the fade replays for a second tile in the same session */
    void bubble.offsetWidth;
    bubble.classList.add('tt-in');
    if (!shown) document.addEventListener('mousemove', onDrift, true);
    shown = tile;
  }

  /* ---------- page state ---------- */

  function grid() { return document.getElementById('grid'); }

  function tileFrom(node) {
    if (!node || !node.closest) return null;
    var tile = node.closest('[data-key]');
    var g = grid();
    if (!tile || !g || !g.contains(tile)) return null;
    return tile;
  }

  /* A deploy sheet (or anything else that locks the body) outranks a hover. */
  function blocked() {
    if (document.body.classList.contains('is-locked')) return true;
    var sheet = document.getElementById('sheet');
    return !!(sheet && !sheet.hidden);
  }

  /* ---------- hover intent ---------- */

  function arm(tile) {
    if (armed === tile) return;        /* moving between a tile's own children */
    if (shown && shown !== tile) hide();
    clearTimer();
    var key = tile.getAttribute('data-key');
    if (!key || blocked()) { armed = null; return; }
    armed = tile;
    timer = setTimeout(function () { fire(tile, key); }, HOVER_INTENT_MS);
  }

  function fire(tile, key) {
    timer = 0;
    if (armed !== tile) return;
    lookup(key).then(function (str) {
      if (armed !== tile) return;                 /* moved on while fetching */
      if (!mq.matches || blocked()) return;
      if (!document.contains(tile)) return;       /* re-rendered underneath us */
      str = (str || '').trim();
      if (!str) return;                           /* no description, no bubble */
      show(str, tile);
    }, noop);
  }

  /* ---------- events ---------- */

  function onOver(e) {
    var tile = tileFrom(e.target);
    if (tile) arm(tile);
    else hide();
  }

  function onOut(e) {
    /* leaving the document entirely, or leaving the armed tile */
    var to = e.relatedTarget;
    if (!to || !armed) { if (!to) hide(); return; }
    if (!armed.contains(to)) hide();
  }

  /* Only while a bubble is up: catches the tile being re-rendered or scrolled
     out from under a stationary cursor, which fires no mouseout. */
  function onDrift(e) {
    if (!shown) return;
    var r = shown.getBoundingClientRect();
    if (!r.width || e.clientX < r.left || e.clientX > r.right ||
        e.clientY < r.top || e.clientY > r.bottom) hide();
  }

  function onKey(e) {
    if (e.key === 'Escape' || e.key === 'Esc') hide();
  }

  /* Leaving a detail page drops that service's cached description: the detail
     page is exactly where it gets edited, so this keeps the bubble honest
     without polling for changes that almost never happen. */
  function onHash(e) {
    hide();
    var was = /#\/service\/([^/?#]+)/.exec((e && e.oldURL) || '');
    if (was) {
      try { delete desc[decodeURIComponent(was[1])]; } catch (err) { /* ignore */ }
    }
  }

  function bind() {
    if (bound) return;
    bound = true;
    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mouseout', onOut, true);
    document.addEventListener('mousedown', hide, true);
    document.addEventListener('click', hide, true);
    document.addEventListener('keydown', onKey, true);
    window.addEventListener('scroll', hide, true);
    window.addEventListener('resize', hide);
    window.addEventListener('blur', hide);
    window.addEventListener('hashchange', onHash);
    document.addEventListener('visibilitychange', hide);
  }

  function unbind() {
    if (!bound) return;
    bound = false;
    document.removeEventListener('mouseover', onOver, true);
    document.removeEventListener('mouseout', onOut, true);
    document.removeEventListener('mousedown', hide, true);
    document.removeEventListener('click', hide, true);
    document.removeEventListener('keydown', onKey, true);
    window.removeEventListener('scroll', hide, true);
    window.removeEventListener('resize', hide);
    window.removeEventListener('blur', hide);
    window.removeEventListener('hashchange', onHash);
    document.removeEventListener('visibilitychange', hide);
  }

  /* Touch and pen get nothing: there is no hover to intend with, and a bubble
     with no mouseout to dismiss it would stick. Re-evaluated live, because a
     hybrid can gain or lose a mouse mid-session. */
  function sync() {
    hide();
    if (mq.matches) bind(); else unbind();
  }

  if (mq.addEventListener) mq.addEventListener('change', sync);
  else if (mq.addListener) mq.addListener(sync);

  sync();
}());
