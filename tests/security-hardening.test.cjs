const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { stripTypeScriptTypes } = require('node:module');

const root = path.join(__dirname, '..');
const source = file => fs.readFileSync(path.join(root, file), 'utf8');
const quiet = { log() {}, warn() {}, error() {} };

test('escapeHtml escapes HTML tags, double quotes, and single quotes', () => {
  const ctx = vm.createContext({
    crypto: webcrypto, TextEncoder, TextDecoder, btoa, atob, console: quiet,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    window: {}, document: { getElementById: () => null },
    setTimeout: () => 0, clearTimeout() {}, getUserId: () => null
  });
  vm.runInContext(source('data.js') + '\nglobalThis.escapeHtml = escapeHtml; globalThis.sanitizeImageDataUrl = sanitizeImageDataUrl;', ctx);

  const payload = `<img src=x onerror="alert('xss')"> & "test" 'single'`;
  const escaped = ctx.escapeHtml(payload);
  assert.equal(escaped.includes('<'), false);
  assert.equal(escaped.includes('>'), false);
  assert.equal(escaped.includes('"'), false);
  assert.equal(escaped.includes("'"), false);
  assert.ok(escaped.includes('&quot;') && escaped.includes('&#39;'));

  assert.equal(ctx.sanitizeImageDataUrl('javascript:alert(1)'), '');
  assert.equal(ctx.sanitizeImageDataUrl('data:text/html,<script>alert(1)</script>'), '');
  assert.equal(ctx.sanitizeImageDataUrl('data:image/png;base64,iVBORw0KGgo='), 'data:image/png;base64,iVBORw0KGgo=');
});

test('saveInvoice rejects negative quantities, negative prices, and negative delivery costs', async () => {
  const toasts = [];
  const row = {
    querySelector(sel) {
      if (sel === '.item-desc') return { value: 'Tomatoes' };
      if (sel === '.item-qty') return { value: '-2' };
      if (sel === '.item-unit') return { value: 'kgs' };
      if (sel === '.item-buy') return { value: '50' };
      if (sel === '.item-sell') return { value: '80' };
    },
    querySelectorAll: () => []
  };
  const ctx = vm.createContext({
    console: quiet,
    toast: (msg, type) => toasts.push({ msg, type }),
    DB: { invoices: [], deletedInvoices: [], restaurants: [{ id: 'r1', name: 'Test Rest' }], expenses: [] },
    document: {
      addEventListener() {},
      getElementById: id => ({ invRestaurant: { value: 'r1' }, invDate: { value: '2026-11-17' }, editInvoiceId: { value: '' }, invDeliveryCost: { value: '0' }, invOtherCost: { value: '0' }, invDueDate: { value: '' }, invNotes: { value: '' } }[id] || null),
      querySelectorAll: sel => sel === '#lineItemsBody tr' ? [row] : []
    }
  });
  vm.runInContext(source('invoices.js') + '\nglobalThis.saveInvoice = saveInvoice;', ctx);
  await ctx.saveInvoice(true);
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].type, 'error');
  assert.match(toasts[0].msg, /greater than zero/i);
});

test('clerk-api strips wholesale buy costs from list responses and enforces hourly submission cap', async () => {
  let recentCount = 0;
  const admin = {
    from(table) {
      return {
        select() { return this; },
        eq() { return this; },
        gte() { return Promise.resolve({ count: recentCount, error: null }); },
        async maybeSingle() {
          if (table === 'clerk_invites') {
            return { data: { id: 'inv-1', owner_user_id: 'owner-1', owner_name: 'Owner', owner_email: 'o@example.com', expires_at: '2100-01-01', revoked_at: null }, error: null };
          }
          return { data: null, error: null };
        },
        async order() {
          return {
            data: [{
              id: 'stg_1',
              total_sell: 500,
              total_buy: 300,
              items_json: [{ desc: 'Onions', qty: 5, sellPrice: 100, buyPrice: 60 }]
            }],
            error: null
          };
        }
      };
    }
  };
  let handler;
  const ctx = vm.createContext({
    createClient: () => admin, crypto: webcrypto, TextEncoder, Response, Request, console: quiet, btoa,
    Deno: { env: { get: () => 'configured' }, serve: fn => { handler = fn; } }
  });
  const code = source('supabase/functions/clerk-api/index.ts').replace(/^import .*;\r?\n/, '');
  vm.runInContext(stripTypeScriptTypes(code), ctx);

  const listRes = await handler(new Request('https://example.test', {
    method: 'POST',
    body: JSON.stringify({ action: 'list', invite_token: 'x'.repeat(45), include_photos: false })
  }));
  const listJson = await listRes.json();
  assert.equal(listRes.status, 200);
  assert.equal('total_buy' in listJson.submissions[0], false);
  assert.equal('buyPrice' in listJson.submissions[0].items_json[0], false);

  recentCount = 30;
  const rateRes = await handler(new Request('https://example.test', {
    method: 'POST',
    body: JSON.stringify({
      action: 'submit',
      invite_token: 'x'.repeat(45),
      submission_key: 'a'.repeat(24),
      docket: {
        clerk_name: 'Clerk',
        restaurant_name: 'Cafe',
        invoice_date: '2026-11-17',
        delivery_cost: 0,
        other_cost: 0,
        items_json: [{ desc: 'Tomatoes', qty: 2, sellPrice: 100 }]
      }
    })
  }));
  assert.equal(rateRes.status, 429);
});

test('clerk-api enforces both 7-day idle expiry and 30-day maximum lifetime', async () => {
  const dayMs = 24 * 60 * 60 * 1000;
  const issuedAtMs = Date.now() - 10 * dayMs; // Created 10 days ago -> 30d expiresAt still +20d away
  let latestSubmissionAt = null;
  let expiresAt = new Date(issuedAtMs + 30 * dayMs).toISOString();

  const admin = {
    from(table) {
      return {
        select() { return this; },
        eq() { return this; },
        gte() { return Promise.resolve({ count: 0, error: null }); },
        async maybeSingle() {
          if (table === 'clerk_invites') {
            return {
              data: {
                id: 'inv-1',
                owner_user_id: 'owner-1',
                owner_name: 'Owner',
                owner_email: 'o@example.com',
                expires_at: expiresAt,
                revoked_at: null
              },
              error: null
            };
          }
          return { data: null, error: null };
        },
        async order() {
          return {
            data: latestSubmissionAt ? [{ updated_at: latestSubmissionAt, created_at: latestSubmissionAt }] : [],
            error: null
          };
        }
      };
    }
  };
  let handler;
  const ctx = vm.createContext({
    createClient: () => admin, crypto: webcrypto, TextEncoder, Response, Request, console: quiet, btoa,
    Deno: { env: { get: () => 'configured' }, serve: fn => { handler = fn; } }
  });
  const code = source('supabase/functions/clerk-api/index.ts').replace(/^import .*;\r?\n/, '');
  vm.runInContext(stripTypeScriptTypes(code), ctx);

  // 1. Created 10 days ago with 0 submissions -> idle > 7 days -> REJECTED (401)
  const idleRes = await handler(new Request('https://example.test', {
    method: 'POST',
    body: JSON.stringify({ action: 'list', invite_token: 'y'.repeat(45), include_photos: false })
  }));
  assert.equal(idleRes.status, 401);
  assert.match((await idleRes.json()).error, /7 days of inactivity/i);

  // 2. Same 10-day-old token, but clerk submitted 3 days ago -> ALLOWED (200)
  latestSubmissionAt = new Date(Date.now() - 3 * dayMs).toISOString();
  const activeRes = await handler(new Request('https://example.test', {
    method: 'POST',
    body: JSON.stringify({ action: 'list', invite_token: 'y'.repeat(45), include_photos: false })
  }));
  assert.equal(activeRes.status, 200);
  const activeJson = await activeRes.json();
  assert.ok(activeJson.invite.idle_expires_at);
  assert.ok(activeJson.invite.effective_expires_at);

  // 3. Even if active yesterday, once 30-day expires_at passes -> REJECTED (401)
  expiresAt = new Date(Date.now() - 1000).toISOString();
  latestSubmissionAt = new Date(Date.now() - dayMs).toISOString();
  const maxAgeRes = await handler(new Request('https://example.test', {
    method: 'POST',
    body: JSON.stringify({ action: 'list', invite_token: 'y'.repeat(45), include_photos: false })
  }));
  assert.equal(maxAgeRes.status, 401);
  assert.match((await maxAgeRes.json()).error, /30-day/i);
});

test('signUp fails closed when public registration is disabled', async () => {
  const ctx = vm.createContext({
    window: {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    console: quiet
  });
  vm.runInContext(source('supabase-config.js') + '\nglobalThis.signUp = signUp;', ctx);
  await assert.rejects(() => ctx.signUp('stranger@example.com', 'secret123'), /Public sign-up is disabled/i);
});

test('KRA PIN helpers validate 11-character Kenyan PINs and reject malformed input', () => {
  const ctx = vm.createContext({
    console: quiet,
    document: { querySelectorAll: () => [] }
  });
  vm.runInContext(source('nav.js') + '\nglobalThis.normalizeKraPin = normalizeKraPin; globalThis.isValidKraPin = isValidKraPin;', ctx);

  assert.equal(ctx.normalizeKraPin(' p051234567x '), 'P051234567X');
  assert.equal(ctx.isValidKraPin('P051234567X'), true);
  assert.equal(ctx.isValidKraPin('A012345678Z'), true);
  assert.equal(ctx.isValidKraPin('X051234567X'), false);
  assert.equal(ctx.isValidKraPin('P0512345'), false);
  assert.equal(ctx.isValidKraPin('P051234567<'), false);
});

test('UI inspection guard blocks contextmenu and DevTools shortcuts without affecting normal keys', () => {
  const listeners = {};
  const ctx = vm.createContext({
    window: {},
    document: {
      addEventListener(type, fn) {
        listeners[type] = listeners[type] || [];
        listeners[type].push(fn);
      }
    },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    console: quiet
  });
  vm.runInContext(
    source('supabase-config.js') + '\nglobalThis.installUiInspectionGuard = installUiInspectionGuard; globalThis.isBlockedInspectionShortcut = isBlockedInspectionShortcut;',
    ctx
  );

  // Calling installUiInspectionGuard again must remain idempotent
  ctx.installUiInspectionGuard();
  assert.equal(listeners.contextmenu.length, 1);
  assert.equal(listeners.keydown.length, 1);

  let contextPrevented = false;
  listeners.contextmenu[0]({ preventDefault() { contextPrevented = true; } });
  assert.equal(contextPrevented, true);

  const shouldBlock = [
    { key: 'F12' },
    { ctrlKey: true, shiftKey: true, key: 'I' },
    { ctrlKey: true, shiftKey: true, key: 'j' },
    { ctrlKey: true, shiftKey: true, key: 'C' },
    { ctrlKey: true, key: 'u' },
    { metaKey: true, altKey: true, key: 'I' }
  ];
  for (const evt of shouldBlock) {
    let blocked = false;
    listeners.keydown[0]({ ...evt, preventDefault() { blocked = true; } });
    assert.equal(blocked, true, `expected shortcut to be blocked: ${JSON.stringify(evt)}`);
  }

  const shouldAllow = [
    { key: 'i' },
    { ctrlKey: true, key: 'c' },
    { ctrlKey: true, key: 'v' },
    { ctrlKey: true, key: 'p' },
    { ctrlKey: true, key: 'f' },
    { key: 'Enter' }
  ];
  for (const evt of shouldAllow) {
    let blocked = false;
    listeners.keydown[0]({ ...evt, preventDefault() { blocked = true; } });
    assert.equal(blocked, false, `expected shortcut to remain allowed: ${JSON.stringify(evt)}`);
  }
});
