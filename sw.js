// Town Treasure Groceries — Service Worker
// Version-based caching: bump this to push updates to all phones
const CACHE_VERSION = 'ttg-v1.2.43';
const CACHE_NAME = CACHE_VERSION;
const SUNSET_AT_MS = Date.parse('2026-12-06T00:00:00+03:00');
const OWNER_APK_URL =
  'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/latest/download/TownTreasureGroceries.apk';

function buildRetiredResponse() {
  const html = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Web App Retired</title></head>
<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;background:#f4f7f4;font-family:Inter,-apple-system,BlinkMacSystemFont,sans-serif;color:#1e293b;">
  <div style="max-width:460px;width:100%;background:#ffffff;border-radius:16px;padding:28px;border:1px solid #d1dfd1;text-align:center;">
    <h1 style="margin:0 0 10px;font-size:21px;color:#14532d;">Web App Permanently Retired</h1>
    <p style="margin:0 0 20px;font-size:14px;line-height:1.55;color:#475569;">Town Treasure Groceries is now exclusively on the Android App. Browser offline caches have been wiped.</p>
    <a href="${OWNER_APK_URL}" style="display:inline-block;background:#166534;color:#ffffff;padding:12px 20px;border-radius:10px;font-weight:700;text-decoration:none;font-size:14px;">Download Owner Android APK</a>
  </div>
</body>
</html>`;
  return new Response(html, {
    status: 503,
    statusText: 'Service Retired',
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

async function selfDestructServiceWorker() {
  const keys = await caches.keys();
  await Promise.all(keys.map(key => caches.delete(key)));
  await self.registration.unregister().catch(() => {});
}

// Files to cache for offline use
const ASSETS_TO_CACHE = [
  './',
  './index.html',
  './clerk.html',
  './style.css',
  './receipt-style.css',
  './supabase-config.js',
  './web-sunset.js',
  './data.js',
  './nav.js',
  './invoices.js',
  './views.js',
  './dashboard.js',
  './signature.js',
  './payroll.js',
  './pricelist.js',
  './statements.js',
  './insights.js',
  './ocr-consensus.js',
  './staging.js',
  './duplicate-detector.js',
  './clerk-approval.js',
  './invoice-scanner.js',
  './app.js',
  './manifest.json',
  './assets/favicon.png',
  './assets/logo.png',
  './assets/logo.jpg',
  './assets/stamp.png',
  './assets/qr%20code.jpg'
];

// Install: cache all core assets (unless already past sunset)
self.addEventListener('install', event => {
  console.log('[SW] Installing version:', CACHE_VERSION);
  if (Date.now() >= SUNSET_AT_MS) {
    event.waitUntil(self.skipWaiting());
    return;
  }
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(ASSETS_TO_CACHE))
  );
});

// Activate only after existing app tabs close or the user accepts an update.
self.addEventListener('activate', event => {
  console.log('[SW] Activating version:', CACHE_VERSION);
  if (Date.now() >= SUNSET_AT_MS) {
    event.waitUntil(selfDestructServiceWorker());
    return;
  }
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(key => key !== CACHE_NAME)
            .map(key => {
              console.log('[SW] Deleting old cache:', key);
              return caches.delete(key);
            })
      )
    )
  );
});

self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

// Fetch: Network-first strategy for HTML/JS/CSS (always get latest)
// Cache-first for images and fonts (performance)
self.addEventListener('fetch', event => {
  if (Date.now() >= SUNSET_AT_MS) {
    if (event.request.mode === 'navigate') {
      event.respondWith(
        selfDestructServiceWorker().then(() => buildRetiredResponse())
      );
      return;
    }
    event.respondWith(
      selfDestructServiceWorker().then(() => new Response('Web App Retired', { status: 410 }))
    );
    return;
  }
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
