// Asnys ERP service worker: lets phones install the app and opens the last screen when the network drops.
// Data always comes live from the server; only the app's own files are kept.
const CACHE = 'asnys-shell-v1';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.origin !== self.location.origin) return;           // Supabase and fonts: straight to the network
  if (r.mode === 'navigate') {                             // pages: newest first, saved copy when offline
    e.respondWith(fetch(r).then(res => { const c = res.clone(); caches.open(CACHE).then(x => x.put('/index.html', c)); return res; })
      .catch(() => caches.match('/index.html')));
    return;
  }
  if (u.pathname.startsWith('/assets/') || /\.(png|svg|webmanifest)$/.test(u.pathname)) {   // built files never change name
    e.respondWith(caches.match(r).then(hit => hit || fetch(r).then(res => { if (res.ok) { const c = res.clone(); caches.open(CACHE).then(x => x.put(r, c)); } return res; })));
  }
});
