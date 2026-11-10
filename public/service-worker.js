const CACHE_NAME = 'roshan-static-v3';
const OFFLINE_URL = '/offline.html';
const STATIC_FILE_PATTERN = /\.(?:css|png|jpe?g|gif|webp|svg|ico|woff2?|json)$/i;
const NETWORK_ONLY_PATH_PATTERN = /^\/(?:api(?:\/|$)|admin(?:\.html)?(?:\/|$)|login(?:\/|$)|auth(?:\/|$)|checkout(?:\/|$)|orders?(?:\/|$)|payment(?:\/|$))/i;
const SUPABASE_AUTH_PATH_PATTERN = /^\/auth\/v1(?:\/|$)/i;

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.add(OFFLINE_URL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(names => Promise.all(
        names
          .filter(name => name.startsWith('roshan-static-') && name !== CACHE_NAME)
          .map(name => caches.delete(name))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (SUPABASE_AUTH_PATH_PATTERN.test(url.pathname)
      && /(^|\.)supabase\.(?:co|in)$/i.test(url.hostname)) return;
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    if (url.pathname === '/' || url.pathname === '/index.html') return;
    event.respondWith(
      fetch(request).catch(async () => {
        const offlinePage = await caches.match(OFFLINE_URL);
        return offlinePage || Response.error();
      })
    );
    return;
  }

  if (request.destination === 'script' || request.destination === 'document'
      || NETWORK_ONLY_PATH_PATTERN.test(url.pathname) || !STATIC_FILE_PATTERN.test(url.pathname)) return;

  event.respondWith(
    fetch(request).then(response => {
      if (response.ok && response.type === 'basic') {
        const copy = response.clone();
        event.waitUntil(
          caches.open(CACHE_NAME)
            .then(cache => cache.put(request, copy))
            .catch(error => console.error('Could not cache a static asset:', error))
        );
      }
      return response;
    }).catch(async () => {
      const cachedAsset = await caches.match(request);
      return cachedAsset || Response.error();
    })
  );
});
