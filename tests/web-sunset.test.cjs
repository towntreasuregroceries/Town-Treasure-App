const test = require('node:test');
const assert = require('node:assert/strict');
const sunset = require('../web-sunset.js');

test('computeSunsetState reports exact countdown before sunset and retired after Day 14', () => {
  const sunsetMs = Date.parse(sunset.TTG_WEB_SUNSET_ISO);
  const fourteenDaysBefore = sunsetMs - 14 * 24 * 60 * 60 * 1000;
  const preState = sunset.computeSunsetState(fourteenDaysBefore, sunsetMs);
  assert.equal(preState.retired, false);
  assert.equal(preState.daysRemaining, 14);

  const sixHoursBefore = sunsetMs - 6 * 60 * 60 * 1000;
  const finalDay = sunset.computeSunsetState(sixHoursBefore, sunsetMs);
  assert.equal(finalDay.retired, false);
  assert.equal(finalDay.daysRemaining, 1);

  const afterSunset = sunsetMs + 1000;
  const expiredState = sunset.computeSunsetState(afterSunset, sunsetMs);
  assert.equal(expiredState.retired, true);
  assert.equal(expiredState.daysRemaining, 0);
});

test('initWebSunset renders countdown banner before Day 14 and wipes storage/SW/caches on expiry', async () => {
  const inserted = [];
  const fakeDoc = {
    location: { pathname: '/index.html' },
    readyState: 'complete',
    body: {
      firstChild: null,
      innerHTML: '<main>Active</main>',
      insertBefore(node) {
        inserted.push(node);
      },
    },
    getElementById(id) {
      return inserted.find(n => n.id === id) || null;
    },
    createElement(tag) {
      return {
        tagName: tag.toUpperCase(),
        id: '',
        style: { cssText: '' },
        children: [],
        setAttribute() {},
        appendChild(child) {
          this.children.push(child);
        },
      };
    },
  };

  let clearedLocal = false;
  let clearedSession = false;
  let swUnregistered = false;
  let cacheDeleted = false;
  const fakeWin = {
    TTG_WEB_RETIRED: false,
    DB: { syncNow: async () => true, scheduleSync: () => {} },
    supabaseClient: { auth: { signOut: async () => ({ error: null }) } },
    localStorage: { clear: () => { clearedLocal = true; } },
    sessionStorage: { clear: () => { clearedSession = true; } },
    navigator: {
      serviceWorker: {
        getRegistrations: async () => [{ unregister: async () => { swUnregistered = true; } }],
      },
    },
    caches: {
      keys: async () => ['ttg-v1.2.43'],
      delete: async () => { cacheDeleted = true; return true; },
    },
  };

  const sunsetMs = Date.parse(sunset.TTG_WEB_SUNSET_ISO);
  const pre = await sunset.initWebSunset({
    win: fakeWin,
    doc: fakeDoc,
    nowMs: sunsetMs - 5 * 24 * 60 * 60 * 1000,
    sunsetMs,
    fetchFn: async () => ({
      headers: { get: () => new Date(sunsetMs - 5 * 24 * 60 * 60 * 1000).toUTCString() },
    }),
  });
  assert.equal(pre.retired, false);
  assert.equal(pre.daysRemaining, 5);
  assert.equal(inserted.length, 1);
  assert.match(inserted[0].children[0].innerHTML, /5 days/);
  assert.equal(fakeWin.TTG_WEB_RETIRED, false);

  // Even if local clock is rolled back, authoritative Date header past sunset triggers self-destruct
  const post = await sunset.initWebSunset({
    win: fakeWin,
    doc: fakeDoc,
    nowMs: sunsetMs - 5 * 24 * 60 * 60 * 1000,
    sunsetMs,
    fetchFn: async () => ({
      headers: { get: () => new Date(sunsetMs + 60_000).toUTCString() },
    }),
  });
  assert.equal(post.retired, true);
  assert.equal(fakeWin.TTG_WEB_RETIRED, true);
  assert.equal(fakeWin.supabaseClient, null);
  assert.equal(await fakeWin.DB.syncNow(), false);
  assert.equal(clearedLocal, true);
  assert.equal(clearedSession, true);
  assert.equal(swUnregistered, true);
  assert.equal(cacheDeleted, true);
  assert.match(fakeDoc.body.innerHTML, /Web App Permanently Retired/);
});
