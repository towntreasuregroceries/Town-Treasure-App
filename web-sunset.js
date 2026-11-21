// Town Treasure Groceries — 14-Day Web App Sunset & Automatic Shutdown
(function (root) {
  'use strict';

  var TTG_WEB_SUNSET_ISO = '2026-12-06T00:00:00+03:00';
  var TTG_OWNER_APK_URL =
    'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/latest/download/TownTreasureGroceries.apk';
  var TTG_CLERK_APK_URL =
    'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/latest/download/TownTreasureClerk.apk';

  function computeSunsetState(nowMs, sunsetMs) {
    var effectiveNow = Number.isFinite(nowMs) ? nowMs : Date.now();
    var target = Number.isFinite(sunsetMs) ? sunsetMs : Date.parse(TTG_WEB_SUNSET_ISO);
    var remainingMs = target - effectiveNow;
    if (remainingMs <= 0) {
      return {
        retired: true,
        daysRemaining: 0,
        hoursRemaining: 0,
        sunsetIso: TTG_WEB_SUNSET_ISO,
      };
    }
    var hoursRemaining = Math.ceil(remainingMs / (60 * 60 * 1000));
    var daysRemaining = Math.max(1, Math.ceil(remainingMs / (24 * 60 * 60 * 1000)));
    return {
      retired: false,
      daysRemaining: daysRemaining,
      hoursRemaining: hoursRemaining,
      sunsetIso: TTG_WEB_SUNSET_ISO,
    };
  }

  function isClerkPage(doc) {
    try {
      var loc = doc && doc.location ? String(doc.location.pathname || '') : '';
      return loc.toLowerCase().indexOf('clerk') !== -1;
    } catch (_) {
      return false;
    }
  }

  function getDownloadTarget(doc) {
    if (isClerkPage(doc)) {
      return {
        label: 'Download Clerk Android APK',
        url: TTG_CLERK_APK_URL,
        appName: 'Town Treasure Clerk',
      };
    }
    return {
      label: 'Download Owner Android APK',
      url: TTG_OWNER_APK_URL,
      appName: 'Town Treasure Groceries',
    };
  }

  function renderCountdownBanner(doc, state) {
    if (!doc || !doc.body || state.retired) return null;
    var existing = doc.getElementById('ttgSunsetBanner');
    if (existing) return existing;

    var target = getDownloadTarget(doc);
    var dayWord = state.daysRemaining === 1 ? '1 day' : state.daysRemaining + ' days';
    var banner = doc.createElement('div');
    banner.id = 'ttgSunsetBanner';
    banner.setAttribute('role', 'region');
    banner.setAttribute('aria-label', 'Web app retirement notice');
    banner.style.cssText = [
      'position:sticky',
      'top:0',
      'z-index:99999',
      'width:100%',
      'box-sizing:border-box',
      'background:linear-gradient(90deg,#92400e,#b45309)',
      'color:#fff',
      'padding:10px 16px',
      'font-family:Inter,-apple-system,BlinkMacSystemFont,sans-serif',
      'font-size:13px',
      'line-height:1.4',
      'display:flex',
      'flex-wrap:wrap',
      'align-items:center',
      'justify-content:space-between',
      'gap:10px',
      'box-shadow:0 2px 8px rgba(0,0,0,0.2)',
    ].join(';');

    var textSpan = doc.createElement('span');
    textSpan.innerHTML =
      '<strong>Notice:</strong> The Town Treasure Web App is shutting down in <strong>' +
      dayWord +
      '</strong> (5 Dec 2026) and will stop syncing. Please switch to the Android App now.';

    var link = doc.createElement('a');
    link.href = target.url;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = target.label;
    link.style.cssText = [
      'background:#fff',
      'color:#78350f',
      'padding:6px 12px',
      'border-radius:6px',
      'font-weight:700',
      'text-decoration:none',
      'white-space:nowrap',
      'font-size:12.5px',
    ].join(';');

    banner.appendChild(textSpan);
    banner.appendChild(link);
    doc.body.insertBefore(banner, doc.body.firstChild);
    return banner;
  }

  function neutralizeLegacyClient(win) {
    if (!win) return;
    win.TTG_WEB_RETIRED = true;
    try {
      if (win.DB) {
        win.DB.syncNow = async function () {
          return false;
        };
        win.DB.scheduleSync = function () {};
      }
    } catch (_) {}
    try {
      if (win.supabaseClient && win.supabaseClient.auth) {
        win.supabaseClient.auth.signOut = async function () {
          return { error: null };
        };
      }
      win.supabaseClient = null;
    } catch (_) {}
    try {
      win.signIn = async function () {
        throw new Error('The Town Treasure Web App is permanently retired. Use the Android App.');
      };
    } catch (_) {}
  }

  async function purgeBrowserStateAndSelfDestruct(win, doc) {
    neutralizeLegacyClient(win);

    try {
      if (win && win.localStorage) win.localStorage.clear();
    } catch (_) {}
    try {
      if (win && win.sessionStorage) win.sessionStorage.clear();
    } catch (_) {}

    try {
      if (win && win.navigator && win.navigator.serviceWorker && win.navigator.serviceWorker.getRegistrations) {
        var regs = await win.navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map(function (reg) { return reg.unregister(); }));
      }
    } catch (_) {}

    try {
      if (win && win.caches && win.caches.keys) {
        var keys = await win.caches.keys();
        await Promise.all(keys.map(function (k) { return win.caches.delete(k); }));
      }
    } catch (_) {}

    if (doc && doc.body) {
      var target = getDownloadTarget(doc);
      doc.body.innerHTML =
        '<div id="ttgSunsetRetiredScreen" style="min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;background:#f4f7f4;font-family:Inter,-apple-system,BlinkMacSystemFont,sans-serif;color:#1e293b;">' +
          '<div style="max-width:460px;width:100%;background:#ffffff;border-radius:16px;padding:28px;border:1px solid #d1dfd1;box-shadow:0 10px 28px rgba(0,0,0,0.08);text-align:center;">' +
            '<div style="display:inline-block;padding:6px 12px;border-radius:999px;background:#fef2f2;color:#b91c1c;font-weight:700;font-size:12px;margin-bottom:14px;">WEB APP RETIRED</div>' +
            '<h1 style="margin:0 0 10px;font-size:21px;font-weight:800;color:#14532d;">Web App Permanently Retired</h1>' +
            '<p style="margin:0 0 20px;font-size:14px;line-height:1.55;color:#475569;">Town Treasure Groceries is now exclusively on the Android App. Local web caches have been cleared to prevent stale data sync.</p>' +
            '<a href="' + target.url + '" target="_blank" rel="noopener noreferrer" style="display:inline-block;background:#166534;color:#ffffff;padding:12px 20px;border-radius:10px;font-weight:700;text-decoration:none;font-size:14px;">' + target.label + '</a>' +
          '</div>' +
        '</div>';
    }
  }

  async function initWebSunset(options) {
    var opts = options || {};
    var win = opts.win || (typeof window !== 'undefined' ? window : null);
    var doc = opts.doc || (typeof document !== 'undefined' ? document : null);
    var sunsetMs = Number.isFinite(opts.sunsetMs) ? opts.sunsetMs : Date.parse(TTG_WEB_SUNSET_ISO);
    var nowMs = Number.isFinite(opts.nowMs) ? opts.nowMs : Date.now();
    var fetchFn = opts.fetchFn || (win && typeof win.fetch === 'function' ? win.fetch.bind(win) : null);

    var state = computeSunsetState(nowMs, sunsetMs);
    if (state.retired) {
      await purgeBrowserStateAndSelfDestruct(win, doc);
      return state;
    }

    var applyBanner = function () {
      renderCountdownBanner(doc, state);
    };
    if (doc && doc.readyState === 'loading' && typeof doc.addEventListener === 'function') {
      doc.addEventListener('DOMContentLoaded', applyBanner);
    } else {
      applyBanner();
    }

    // Online anti-clock-tamper check via server Date header
    if (fetchFn) {
      try {
        var res = await fetchFn('./app-update.json?ts=' + nowMs, {
          method: 'HEAD',
          cache: 'no-store',
        });
        var dateHdr = res && res.headers && typeof res.headers.get === 'function'
          ? res.headers.get('Date')
          : null;
        if (dateHdr) {
          var serverNowMs = Date.parse(dateHdr);
          if (Number.isFinite(serverNowMs)) {
            var serverState = computeSunsetState(serverNowMs, sunsetMs);
            if (serverState.retired) {
              await purgeBrowserStateAndSelfDestruct(win, doc);
              return serverState;
            }
          }
        }
      } catch (_) {
        // Offline or network blocked — rely on local clock check above.
      }
    }

    return state;
  }

  var api = {
    TTG_WEB_SUNSET_ISO: TTG_WEB_SUNSET_ISO,
    TTG_OWNER_APK_URL: TTG_OWNER_APK_URL,
    TTG_CLERK_APK_URL: TTG_CLERK_APK_URL,
    computeSunsetState: computeSunsetState,
    renderCountdownBanner: renderCountdownBanner,
    purgeBrowserStateAndSelfDestruct: purgeBrowserStateAndSelfDestruct,
    initWebSunset: initWebSunset,
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }
  if (root && typeof root === 'object') {
    root.TtgWebSunset = api;
    if (typeof window !== 'undefined' && root === window) {
      initWebSunset();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
