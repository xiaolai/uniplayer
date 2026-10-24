// Netflix surface inventory informed by the reviewed Lwolf12/chromeext adapter
// and FlixMonkey's Netflix fixtures. Runtime and bridge are UniPlayer's own.
(() => {
  'use strict';
  if (location.protocol !== 'https:' || !/(^|\.)netflix\.com$/.test(location.hostname)) return;
  if (globalThis.uniPlayerRatings) return;
  const bridge = globalThis.webkit?.messageHandlers?.netflixRatings;
  if (!bridge) return;
  const style = document.createElement('style'); style.textContent = globalThis.uniPlayerRatingCSS; document.head.append(style);
  const own = '.uniplayer-imdb-wrap';
  const explicitCards = '[data-uia="standard-card"], [data-uia="progress-card"], [data-uia="ranked-card"], [data-uia="episodic-card"], .title-card, [data-uia="title-card-container"], .title-card-container';
  const links = 'a[href*="/watch/"], a[href*="/title/"], a[href*="jbv="]';
  const records = new Map(), answers = new Map(), inFlight = new Map(), hints = new Map();
  let running = 0, generation = 0, timer = null, retryTimer = null, disabled = false, paused = false;
  let lastHovered = null, lastURL = location.href;
  const normalized = s => (s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  const validID = id => /^\d{1,20}$/.test(id || '');
  const key = q => JSON.stringify([q.id || '', normalized(q.title), q.year || '', q.type || '', !!q.episode]);
  const identity = q => q.id || `title:${normalized(q.title)}`;
  function idFromURL(raw) {
    try {
      const url = new URL(raw, location.href);
      if (!/(^|\.)netflix\.com$/.test(url.hostname)) return '';
      const id = url.pathname.match(/\/(?:watch|title)\/(\d+)(?:\/|$)/)?.[1] || url.searchParams.get('jbv');
      return validID(id) ? id : '';
    } catch { return ''; }
  }
  function idOf(el) {
    for (const node of [el, el.querySelector(links), el.closest('[data-videoid], [data-video-id], [data-title-id]')].filter(Boolean)) {
      for (const attr of ['data-videoid', 'data-video-id', 'data-title-id']) {
        const id = node.getAttribute(attr); if (validID(id)) return id;
      }
      const id = idFromURL(node.getAttribute('href')); if (id) return id;
    }
    return '';
  }
  function titleOf(el) {
    return (el.getAttribute('aria-label') || el.querySelector('a[aria-label]')?.getAttribute('aria-label') ||
      el.querySelector('.fallback-text, .boxart-text')?.textContent || el.querySelector('img[alt]:not([alt=""])')?.alt || '').trim();
  }
  function hintsOf(el, kind) {
    const text = selector => (el.querySelector(selector)?.textContent || '').trim();
    const format = text('[data-uia="makeover-content-type-genre"]').split('|')[0].trim();
    const metadata = text('[data-uia="makeover-metadata"]');
    const generic = text('[data-uia="videoMetadata--container"]');
    const hasEpisode = /S\d+:E\d+/.test(el.textContent || '');
    let type = /^(show|series)$/i.test(format) ? 'series' : /^(movie|film)$/i.test(format) ? 'movie' : undefined;
    if (!type && (/\d+\s*(seasons?|episodes?|parts?|volumes?)|limited series/i.test(generic) || el.querySelector('[data-uia="episode-selector"]') || hasEpisode)) type = 'series';
    // A series detail panel can display its latest season's year. Only the
    // dedicated preview metadata (without an episode context) supplies its year.
    let year = !hasEpisode ? metadata.match(/(?:^|\D)((?:19|20)\d{2})(?!\d)/)?.[1] : undefined;
    if (!year && type === 'movie') year = generic.match(/(?:^|\D)((?:19|20)\d{2})(?!\d)/)?.[1];
    if (kind === 'billboard') {
      const attrs = el.querySelector('[data-uia="attributes-elements"]');
      const values = [...(attrs?.querySelectorAll('span,li') || [])].map(n => n.textContent.trim());
      const first = values[0] || attrs?.textContent || '';
      type = /^(show|series)/i.test(first) ? 'series' : /^(movie|film)/i.test(first) ? 'movie' : type;
      year = values.find(v => /^(19|20)\d{2}$/.test(v));
    }
    return { year, type };
  }
  function surfaces() {
    const found = new Map();
    for (let el of document.querySelectorAll(explicitCards)) {
      if (el.closest('.previewModal--wrapper') || el.closest('[data-list-context="windowedComingSoon"]')) continue;
      if (el.matches('[data-uia="title-card-container"], .title-card-container') && el.querySelector('.title-card')) el = el.querySelector('.title-card');
      const title = titleOf(el); if (!title) continue;
      found.set(el, { el, host: el.querySelector('.boxart-container') || el, kind: 'card', layout: 'overlay',
        q: { id: idOf(el), title, episode: el.matches('[data-uia="episodic-card"]') } });
    }
    // Unknown markup gets a conservative fallback; known semantic cards above
    // do not depend on anchor tags, generated classes or geometry.
    for (const anchor of document.querySelectorAll(links)) {
      if (anchor.closest(explicitCards) || anchor.closest('.previewModal--wrapper') || anchor.closest(own)) continue;
      const rect = anchor.getBoundingClientRect(), title = titleOf(anchor), id = idOf(anchor);
      if (rect.width >= 100 && rect.height >= 60 && title && id) found.set(anchor,
        { el: anchor, host: anchor, kind: 'card', layout: 'overlay', q: { id, title } });
    }
    for (const el of document.querySelectorAll('.previewModal--wrapper.mini-modal, .previewModal--wrapper.detail-modal')) {
      const image = el.querySelector('img.previewModal--boxart, img.playerModel--player__storyArt, .previewModal--player_container img[alt]:not([alt=""])');
      const title = (image?.alt || el.querySelector('[data-uia="previewModal-title"], h1, h2')?.textContent || '').trim();
      if (!title) continue;
      const hovered = lastHovered && normalized(lastHovered.title) === normalized(title) ? lastHovered : null;
      const id = idOf(el) || (el.classList.contains('mini-modal') ? hovered?.id : '') || idFromURL(location.href) || hovered?.id || '';
      const host = el.querySelector('.previewModal--metadatAndControls-container, .previewModal--info') || el.querySelector('.previewModal--player_container') || el;
      const q = { id, title, ...hintsOf(el, 'detail'), episode: !!hovered?.episode };
      if (q.episode) { q.type = 'series'; delete q.year; }
      found.set(el, { el, host, kind: 'detail', layout: host.matches('.previewModal--player_container') ? 'overlay' : 'inline', q });
    }
    for (const el of document.querySelectorAll('[data-uia="billboard"]')) {
      const host = el.querySelector('[data-uia="billboard-actions"]'); if (!host) continue;
      let title = (el.getAttribute('aria-label') || '').replace(/^featured content:\s*/i, '').trim();
      let previous;
      do { previous = title; title = title.replace(/,\s*(show|series|movie|film|season\s+\d+|limited series|part\s+\d+)\s*$/i, '').trim(); } while (previous !== title);
      if (title) found.set(el, { el, host, kind: 'billboard', layout: 'inline', q: { id: idOf(el), title, ...hintsOf(el, 'billboard') } });
    }
    return found;
  }
  function remove(record) {
    record.wrap?.remove(); record.wrap = null;
    intersection.unobserve(record.el);
    if (![...records.values()].some(r => r !== record && r.host === record.host && r.wrap)) record.host.classList.remove('uniplayer-imdb-card');
  }
  function schedule(delay = 80) {
    if (paused || timer) return;
    timer = setTimeout(() => { timer = null; scan(); }, delay);
  }
  function svg(name) {
    const text = globalThis.uniPlayerRatingIcons?.[name];
    if (!text) return document.createTextNode('');
    const node = new DOMParser().parseFromString(text, 'image/svg+xml').documentElement;
    return node.localName === 'svg' ? document.importNode(node, true) : document.createTextNode('');
  }
  function render(record, result) {
    const q = record.q, numeric = typeof result?.badge === 'string' && !!result.imdbID;
    const state = numeric ? (result.verified ? 'verified' : 'unverified') : result?.state === 'notFound' ? 'unavailable' : 'loading';
    const signature = JSON.stringify([key(q), state, result?.badge || '', result?.imdbID || '', !!result?.stale, result?.reason || '']);
    if (record.wrap?.dataset.render === signature && record.wrap.isConnected) return;
    if (!record.wrap?.isConnected) {
      const wrap = document.createElement('span'); wrap.className = 'uniplayer-imdb-wrap';
      const badge = document.createElement('button'); badge.type = 'button'; badge.className = 'uniplayer-imdb-rating';
      const stop = event => event.stopPropagation();
      wrap.addEventListener('pointerdown', stop); wrap.addEventListener('keydown', stop);
      badge.addEventListener('click', event => {
        event.preventDefault(); event.stopImmediatePropagation();
        const id = badge.dataset.imdbId;
        bridge.postMessage(id ? { action: 'open', imdbID: id } : { action: 'search', title: record.q.title }).catch(() => {});
      });
      const edit = document.createElement('button'); edit.type = 'button'; edit.className = 'uniplayer-imdb-edit'; edit.append(svg('edit'));
      const correct = event => {
        event.preventDefault(); event.stopImmediatePropagation();
        if (!validID(record.q.id)) return;
        bridge.postMessage({ ...record.q, action: 'editMatch', imdbID: badge.dataset.imdbId || '' }).then(reply => {
          if (reply?.changed) globalThis.uniPlayerRatings.reset();
        }).catch(() => {});
      };
      edit.addEventListener('click', correct); badge.addEventListener('contextmenu', correct);
      wrap.append(badge, edit); record.wrap = wrap;
      if (record.layout === 'overlay' && getComputedStyle(record.host).position === 'static') record.host.classList.add('uniplayer-imdb-card');
      record.host.append(wrap);
    }
    const wrap = record.wrap, badge = wrap.querySelector('.uniplayer-imdb-rating'), edit = wrap.querySelector('.uniplayer-imdb-edit');
    wrap.dataset.render = signature; wrap.dataset.layout = record.layout; wrap.dataset.kind = record.kind;
    badge.dataset.query = key(q); badge.dataset.state = state; badge.dataset.imdbId = result?.imdbID || '';
    const parts = numeric ? result.badge.match(/^(\d+\.\d)\s+(\([^)]+\))$/) : null;
    const value = document.createElement('span'); value.className = 'rating-value'; value.textContent = parts ? parts[1] : state === 'loading' ? '…' : '—';
    const votes = document.createElement('span'); votes.className = 'rating-votes'; votes.textContent = parts?.[2] || '';
    const icon = document.createElement('span'); icon.className = 'rating-status'; icon.setAttribute('aria-hidden', 'true'); icon.append(svg(result?.verified ? 'verified' : 'unverified'));
    badge.replaceChildren(value, ...(parts ? [document.createTextNode(' '), votes] : []), icon);
    const match = result?.userConfirmed ? 'Match confirmed by you.' : result?.verified ? 'Title, year and format agree with Netflix.' : 'Unconfirmed match.';
    const offered = result?.matchedTitle ? ` Matched: ${result.matchedTitle}${result.matchedYear ? ` (${result.matchedYear})` : ''}.` : '';
    let description = numeric ? `IMDb ${result.score}/10 · ${Number(result.votes).toLocaleString()} votes. ${match}${offered}${result.stale ? ' Showing cached score while refreshing.' : ''}`
      : state === 'loading' ? `IMDb lookup ${result?.reason === 'credentials' ? 'needs an API key in Settings' : result?.reason === 'quota' ? 'is waiting for the provider limit to reset' : 'pending; temporary failures retry automatically'} for ${q.title}`
      : `IMDb rating unavailable for ${q.title}. Search on IMDb`;
    if (q.episode) description += ' Series rating.';
    if (validID(q.id)) description += ' Use the pencil or right-click to confirm or correct the match.';
    badge.title = description; badge.setAttribute('aria-label', description);
    edit.hidden = !validID(q.id); edit.title = `Confirm or correct IMDb match for ${q.title}`; edit.setAttribute('aria-label', edit.title);
  }
  function priority(record) {
    if (record.kind !== 'card') return 20;
    if (lastHovered?.id && lastHovered.id === record.q.id) return 10;
    const rect = record.el.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth ? 5 : 1;
  }
  function scan() {
    if (paused) return;
    const current = surfaces();
    for (const [el, record] of records) if (!el.isConnected || !current.has(el)) { remove(record); records.delete(el); }
    // Metadata belongs to a Netflix ID, never to every same-named film.
    for (const surface of current.values()) {
      if (surface.kind === 'card' || !validID(surface.q.id)) continue;
      const before = hints.get(surface.q.id) || {};
      if (surface.q.year || surface.q.type) hints.set(surface.q.id, { ...before, ...Object.fromEntries(Object.entries(surface.q).filter(([k,v]) => ['year','type'].includes(k) && v)) });
    }
    for (const [el, surface] of current) {
      const inherited = surface.q.id ? hints.get(surface.q.id) : null;
      const q = { ...(inherited || {}), ...surface.q };
      if (!surface.q.year && inherited?.year) q.year = inherited.year;
      if (!surface.q.type && inherited?.type) q.type = inherited.type;
      if (surface.q.episode) { q.episode = true; q.type = 'series'; delete q.year; }
      let record = records.get(el);
      if (!record || record.host !== surface.host) {
        if (record) remove(record);
        record = { ...surface, q, near: surface.kind !== 'card', wrap: null }; records.set(el, record); intersection.observe(el);
      } else { record.q = q; record.layout = surface.layout; record.kind = surface.kind; }
      if (disabled) { record.wrap?.remove(); record.wrap = null; continue; }
      const answer = answers.get(key(q));
      if (answer) render(record, answer.result);
      else if (record.near || surface.kind !== 'card') render(record, { state: 'loading' });
    }
    if (answers.size > 2000) {
      const visibleKeys = new Set([...records.values()].map(r => key(r.q)));
      for (const k of answers.keys()) if (!visibleKeys.has(k)) answers.delete(k);
    }
    pump();
  }
  function pump() {
    if (paused || disabled) return;
    clearTimeout(retryTimer); retryTimer = null;
    const now = Date.now(), candidates = new Map(); let next = Infinity;
    for (const record of records.values()) {
      if (!record.el.isConnected || (!record.near && record.kind === 'card')) continue;
      const k = key(record.q), answer = answers.get(k);
      if (answer?.retryAt > now) { next = Math.min(next, answer.retryAt); continue; }
      if (inFlight.has(k)) continue;
      const old = candidates.get(k); if (!old || priority(record) > priority(old)) candidates.set(k, record);
    }
    const ordered = [...candidates.values()].sort((a,b) => priority(b)-priority(a));
    for (const record of ordered) {
      if (running >= 2) break;
      const q = { ...record.q }, k = key(q), epoch = generation;
      running++; inFlight.set(k, epoch);
      bridge.postMessage({ ...q, priority: priority(record) }).then(reply => {
        if (generation !== epoch) return;
        if (reply?.disabled || reply?.state === 'disabled') { disabled = true; return; }
        const result = reply?.badge ? { ...reply, state: 'ready' } : reply?.state ? reply : { state: 'retry', reason: 'bridge', retryAfter: 2 };
        const seconds = result.retryAfter > 0 ? result.retryAfter : result.state === 'ready' ? 300 : result.state === 'notFound' ? 300 : 2;
        answers.set(k, { result, retryAt: Date.now() + Math.max(0.1, seconds) * 1000 });
      }).catch(() => {
        if (generation === epoch) answers.set(k, { result: { state: 'retry', reason: 'network' }, retryAt: Date.now()+2000 });
      }).finally(() => { if (inFlight.get(k) === epoch) inFlight.delete(k); running--; schedule(0); });
    }
    if (next < Infinity) retryTimer = setTimeout(() => schedule(0), Math.max(50, next-Date.now()));
  }
  const intersection = new IntersectionObserver(entries => {
    for (const entry of entries) { const record = records.get(entry.target); if (record) record.near = entry.isIntersecting; }
    schedule(0);
  }, { rootMargin: '300px 600px' }); // Operational prefetch budget, not visual spacing.
  const mutation = new MutationObserver(changes => {
    if (changes.every(change => (change.target instanceof Element ? change.target : change.target.parentElement)?.closest(own))) return;
    schedule();
  });
  mutation.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['href','aria-label','alt','data-videoid','data-video-id','data-title-id'] });
  function hover(event) {
    if (!(event.target instanceof Element) || event.target.closest('.previewModal--wrapper')) return;
    const el = event.target.closest(explicitCards) || event.target.closest(links);
    if (!el) return;
    const title = titleOf(el); if (title) { lastHovered = { id: idOf(el), title, episode: el.matches('[data-uia="episodic-card"]') }; schedule(0); }
  }
  document.addEventListener('mouseover', hover, true); document.addEventListener('focusin', hover, true);
  for (const name of ['popstate','hashchange','online']) window.addEventListener(name, () => {
    for (const answer of answers.values()) if (answer.result.state === 'retry') answer.retryAt = 0;
    schedule(0);
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) schedule(0); });
  window.addEventListener('pagehide', () => { paused = true; clearTimeout(timer); timer = null; clearTimeout(retryTimer); });
  window.addEventListener('pageshow', () => { paused = false; schedule(0); });
  setInterval(() => { if (!paused && location.href !== lastURL) { lastURL = location.href; schedule(0); } }, 1000);
  globalThis.uniPlayerRatings = {
    reset() {
      generation++; disabled = false; answers.clear(); hints.clear();
      clearTimeout(retryTimer);
      for (const record of records.values()) { record.wrap?.remove(); record.wrap = null; }
      schedule(0);
    },
    // Read-only fixture/diagnostic summary; no page content or credentials.
    inspect() { return { surfaces: records.size, inFlight: running, kinds: [...records.values()].map(r => r.kind) }; }
  };
  schedule(0);
})();
