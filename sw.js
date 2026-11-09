// AUDAC Rep Portal service worker: push notifications + a fast start on slow
// mobile networks (Bart, 2026-11-09).
//
// What is kept on the phone, and how:
//  - Files whose URL carries a version: our own /assets/...?v=<hash> (stamped
//    by tools/stamp-assets.js) and exact-version CDN libraries
//    (supabase-js@2.119.0). Cache-first: a new version has a new URL, so a
//    cached copy is never stale.
//  - Google Fonts (CSS + font files): cache-first, they never change.
//  - Pages (/home, /form, ...): network-first. Only when the network takes
//    longer than PAGE_TIMEOUT_MS (or is down) is the last copy shown; the fresh
//    copy still replaces it in the background.
//  - Other files of our own (icons, logo, manifest): shown from the phone, then
//    refreshed in the background.
// Never cached: anything from Supabase (data, login), POSTs, other sites.
const VERSION = 'v2';
const STATIC_CACHE = `audac-static-${VERSION}`;
const PAGE_CACHE = `audac-pages-${VERSION}`;
const PAGE_TIMEOUT_MS = 3000;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil((async () => {
  const keep = [STATIC_CACHE, PAGE_CACHE];
  for (const k of await caches.keys()) if (k.startsWith('audac-') && !keep.includes(k)) await caches.delete(k);
  await self.clients.claim();
})()));

const isVersioned = (url) =>
  (url.origin === self.location.origin && url.pathname.startsWith('/assets/') && url.searchParams.has('v')) ||
  (url.hostname === 'cdn.jsdelivr.net' && /@\d+\.\d+\.\d+/.test(url.pathname));
const isFont = (url) => url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';

async function cacheFirst(request) {
  const cache = await caches.open(STATIC_CACHE);
  const hit = await cache.match(request);
  if (hit) return hit;
  const res = await fetch(request);
  // Older stamps stay too (they're small): a page copy kept from before an
  // update still finds the exact scripts it was built with.
  if (res.ok || res.type === 'opaque') cache.put(request, res.clone());
  return res;
}

async function staleWhileRevalidate(event, request) {
  const cache = await caches.open(STATIC_CACHE);
  const hit = await cache.match(request);
  const refresh = fetch(request).then((res) => { if (res.ok) cache.put(request, res.clone()); return res; }).catch(() => null);
  if (hit) { event.waitUntil(refresh); return hit; }
  return (await refresh) || Response.error();
}

// Pages are stored per path (/form?account=x and /form share one copy).
async function networkFirstPage(event, request, url) {
  const cache = await caches.open(PAGE_CACHE);
  const key = new Request(url.origin + url.pathname);
  const network = fetch(request).then((res) => {
    if (res.ok && res.type === 'basic' && !res.redirected) cache.put(key, res.clone());
    return res;
  });
  event.waitUntil(network.catch(() => null));
  const cached = await cache.match(key);
  if (!cached) return network;
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PAGE_TIMEOUT_MS));
  const first = await Promise.race([network.catch(() => null), timeout]);
  return first || cached;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (request.mode === 'navigate' && url.origin === self.location.origin) {
    if (url.pathname === '/sw.js' || url.pathname.startsWith('/tools/')) return;
    event.respondWith(networkFirstPage(event, request, url));
    return;
  }
  if (isVersioned(url) || isFont(url)) { event.respondWith(cacheFirst(request)); return; }
  if (url.origin === self.location.origin && url.pathname !== '/sw.js') {
    event.respondWith(staleWhileRevalidate(event, request));
  }
  // Everything else (Supabase data and login, other sites) goes straight to the network.
});

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data ? event.data.text() : '' }; }
  const title = data.title || 'AUDAC Rep Portal';
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || '',
    icon: '/icons/icon-192.png',
    badge: '/icons/icon-192.png',
    tag: data.tag || undefined,
    renotify: !!data.tag,
    data: { url: data.url || '/home' },
  }));
});

// Open (or focus) the portal on the page the notification is about.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || '/home', self.location.origin).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (new URL(w.url).origin === self.location.origin && 'focus' in w) {
        try { await w.navigate(url); } catch { /* cross-scope navigate can fail; focus anyway */ }
        return w.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
