// Town Treasure Groceries — Service Worker
// Version-based caching: bump this to push updates to all phones
const CACHE_VERSION = 'ttg-v1.0.9';
const CACHE_NAME = CACHE_VERSION;

// Files to cache for offline use
const ASSETS_TO_CACHE = [
  './',
  './index.html',
  './style.css',
  './receipt-style.css',
  './supabase-config.js',
  './data.js',
  './nav.js',
  './invoices.js',
  './views.js',
  './dashboard.js',
  './app.js',
  './manifest.json',
  './assets/favicon.png',
  './assets/logo.png',
  './assets/logo.jpg',
  './assets/qr%20code.jpg'
];

// Install: cache all core assets
self.addEventListener('install', event => {
  console.log('[SW] Installing version:', CACHE_VERSION);
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(ASSETS_TO_CACHE))
      .then(() => self.skipWaiting()) // Activate immediately
  );
});

// Activate: delete old caches so phone gets fresh code
self.addEventListener('activate', event => {
  console.log('[SW] Activating version:', CACHE_VERSION);
  event.waitUntil(
    caches.keys().then(keys => 
      Promise.all(
        keys.filter(key => key !== CACHE_NAME)
            .map(key => {
              console.log('[SW] Deleting old cache:', key);
              return caches.delete(key);
            })
      )
    ).then(() => self.clients.claim()) // Take control of all tabs
  );
});

// Fetch: Network-first strategy for HTML/JS/CSS (always get latest)
// Cache-first for images and fonts (performance)
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  
  // Skip non-GET requests and external API calls (Supabase)
  if (event.request.method !== 'GET') return;
  if (url.hostname.includes('supabase.co')) return;
  if (url.hostname.includes('cdn.jsdelivr.net') || url.hostname.includes('cdnjs.cloudflare.com')) {
    // CDN resources: cache-first
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          return response;
        });
      })
    );
    return;
  }

  // App files: Network-first (so updates come through immediately)
  event.respondWith(
    fetch(event.request)
      .then(response => {
        // Cache the fresh response
        const clone = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
        return response;
      })
      .catch(() => {
        // Offline: fall back to cache
        return caches.match(event.request);
      })
  );
});
