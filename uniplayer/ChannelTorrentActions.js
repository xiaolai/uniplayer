(() => {
  'use strict';
  if (!/^https?:$/.test(location.protocol) || !globalThis.webkit?.messageHandlers?.torrentActions) return;
  if (globalThis.uniPlayerTorrentActions) { globalThis.uniPlayerTorrentActions.enable(!!globalThis.uniPlayerTorrentEnabled); return; }
  const bridge = webkit.messageHandlers.torrentActions, records = new Map(), clusters = new WeakMap();
  const svgTemplate = new DOMParser().parseFromString(globalThis.uniPlayerTorrentIcon || '', 'image/svg+xml').documentElement;
  const wake = new MessageChannel(); let started = performance.now(), maxChunk = 0, finished = started; wake.port1.onmessage = () => work();
  let enabled = false, timer = null, queued = new Set(), sweeping = false;
  const style = document.createElement('style'); style.textContent = globalThis.uniPlayerTorrentCSS; document.head.append(style);
  const mini = /(^|\.)mini4k\.com$/i.test(location.hostname);
  const own = '.uniplayer-torrent-action';
  function source(anchor) {
    const raw = anchor.getAttribute('href') || '';
    try {
      const url = new URL(raw, document.baseURI);
      if (url.protocol === 'magnet:' && url.searchParams.getAll('xt').some(x => /^urn:(btih|btmh):/i.test(x))) return { url:url.href, kind:'magnet' };
      if (!/^https?:$/.test(url.protocol)) return null;
      if (/\.torrent$/i.test(url.pathname)) return { url:url.href, kind:'torrent' };
      if (mini && globalThis.uniPlayerTorrentMini4KPosts && /(^|\.)mini4k\.com$/i.test(url.hostname) && /^\/torrents\/\d+\/?$/.test(url.pathname)) {
        const row = anchor.closest('tr, [data-torrent-id], .resource-row');
        // Cloud-only markers are conservative; an unknown resource post is a
        // candidate to resolve, not evidence that its movie is playable.
        if (row && row.querySelector('.link-node') && !row.querySelector('.link-user')) return null;
        if (row && [...row.querySelectorAll('a[href]')].some(a => /^(pan\.(baidu|quark|xunlei)|www\.alipan)\.com$/i.test(new URL(a.href,document.baseURI).hostname)) && !row.querySelector('a[href^="magnet:"],a[href$=".torrent"],.link-user')) return null;
        return { url:url.href, kind:'resource' };
      }
    } catch {}
    return null;
  }
  function forget(anchor,record) {
    record.button.remove(); records.delete(anchor);
    if(record.cluster) { const owners=clusters.get(record.cluster); if(owners?.get(record.url)===anchor)owners.delete(record.url); if(record.cluster.isConnected)enqueue(record.cluster); }
  }
  function scanAnchor(anchor) {
    if (!(anchor instanceof HTMLAnchorElement) || anchor.closest('iframe, [contenteditable=true], pre, code') || anchor.closest(own)) return;
    const candidate = source(anchor), previous = records.get(anchor), cluster = anchor.closest('tr, [data-torrent-id], .resource-row');
    if (!candidate || !enabled || !anchor.isConnected) { if(previous)forget(anchor,previous); return; }
    if (previous?.url === candidate.url && previous.cluster === cluster && previous.button.isConnected) return;
    if(previous)forget(anchor,previous);
    if(cluster) { const owners=clusters.get(cluster) || new Map(); clusters.set(cluster,owners); const owner=owners.get(candidate.url); if(owner?.isConnected && owner !== anchor)return; owners.set(candidate.url,anchor); }
    const button = document.createElement('button'); button.type = 'button'; button.className = 'uniplayer-torrent-action';
    const title = (anchor.textContent || anchor.getAttribute('aria-label') || 'Torrent source').trim().slice(0,300);
    button.title = candidate.kind === 'resource' ? 'Check Source & Play in UniPlayer' : 'Check & Play in UniPlayer';
    button.setAttribute('aria-label', `${button.title}: ${title}`);
    if (svgTemplate.localName === 'svg') button.append(document.importNode(svgTemplate,true));
    button.addEventListener('click', event => {
      event.preventDefault(); event.stopImmediatePropagation();
      if (!event.isTrusted || !enabled || !anchor.isConnected || source(anchor)?.url !== candidate.url || button.disabled) return;
      button.disabled = true;
      bridge.postMessage({ page:location.href, version:1, action:'inspect', url:candidate.url, kind:candidate.kind, title }).catch(() => {}).finally(() => { button.disabled = false; });
    });
    button.addEventListener('pointerdown',event => event.stopPropagation());
    button.addEventListener('keydown',event => event.stopPropagation());
    anchor.after(button); records.set(anchor,{url:candidate.url,button,cluster});
  }
  function enqueue(root) {
    if (root instanceof HTMLAnchorElement) queued.add(root);
    if (root instanceof Element) for (const anchor of root.querySelectorAll('a[href]')) queued.add(anchor);
    schedule();
  }
  function schedule(force = false) {
    if (timer || !enabled || (!force && !queued.size)) return;
    timer = true; wake.port2.postMessage(0);
  }
  function work() {
    timer = null; if (!enabled) return;
    const start = performance.now(); let count = 0;
    for (const anchor of queued) {
      queued.delete(anchor); scanAnchor(anchor); count++;
      if (count >= 100 || performance.now()-start > 8) break;
    }
    for (const [anchor,record] of records) if (!anchor.isConnected || !record.button.isConnected) forget(anchor,record);
    maxChunk=Math.max(maxChunk,performance.now()-start);if(!queued.size)finished=performance.now();
    if (queued.size) schedule();
  }
  const observer = new MutationObserver(changes => {
    if (!enabled) return;
    let cleanup = false;
    for (const change of changes) {
      if ((change.target instanceof Element ? change.target : change.target.parentElement)?.closest(own)) continue;
      if (change.type === 'attributes') { const row=change.target.closest?.('tr, [data-torrent-id], .resource-row');if(row)enqueue(row);else if(change.target instanceof HTMLAnchorElement)enqueue(change.target); }
      else {
        const row=change.target.closest?.('tr, [data-torrent-id], .resource-row');if(row)enqueue(row);
        for (const node of change.addedNodes) if (node instanceof Element && !node.matches(own)) enqueue(node);
        if (change.removedNodes.length && ![...change.removedNodes].every(n=>n instanceof Element && n.matches(own))) cleanup = true;
      }
    }
    // Unrelated body/container class changes do not schedule a scan.
    if(queued.size || cleanup)schedule(cleanup);
  });
  observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['href','class']});
  globalThis.uniPlayerTorrentActions = {
    enable(value) {
      enabled = value;
      if (!enabled) { timer = null; queued.clear(); for (const [anchor,r] of records) { if(r.cluster)clusters.get(r.cluster)?.delete(r.url); r.button.remove(); } records.clear(); }
      else { started=performance.now();maxChunk=0;enqueue(document.body); }
    },
    inspect() { return {buttons:records.size,queued:queued.size,enabled,maxChunk,elapsed:finished-started}; }
  };
  bridge.postMessage({version:1,action:'probe',page:location.href}).then(reply=>{
    globalThis.uniPlayerTorrentActions.enable(reply?.enabled === true);
  }).catch(()=>{});
})();
