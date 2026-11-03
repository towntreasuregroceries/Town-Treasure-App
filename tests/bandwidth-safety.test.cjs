const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { stripTypeScriptTypes } = require('node:module');
const root = path.join(__dirname, '..');
const source = file => fs.readFileSync(path.join(root, file), 'utf8');
const storage = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) };
};
const invoice = id => ({ id, number: `TTG-${id}`, restaurantId: 'r', restaurantName: 'Restaurant', date: '2026-11-03', status: 'pending', items: [], totalSell: 20, createdAt: '2026-11-03T08:00:00Z', updatedAt: '2026-11-03T08:00:00Z' });
const quiet = { log() {}, warn() {}, error() {} };

async function vaultFixture() {
  const calls = { fullReads: 0, metadataReads: 0, writes: 0 };
  const rows = new Map();
  const control = { uid: 'owner-a', readError: null, beforeWrite: null };
  const context = vm.createContext({
    crypto: webcrypto, TextEncoder, TextDecoder, btoa, atob, console: quiet,
    localStorage: storage(), window: {}, document: { getElementById: () => null },
    setTimeout: () => 0, clearTimeout() {}, getUserId: () => control.uid
  });
  context.supabaseClient = {
    from(table) {
      assert.equal(table, 'encrypted_vault');
      let columns, uid;
      return {
        select(value) { columns = value; return this; },
        eq(key, value) { assert.equal(key, 'user_id'); uid = value; return this; },
        async maybeSingle() {
          if (columns === 'revision') {
            calls.metadataReads++;
            if (control.readError) return { data: null, error: control.readError };
          } else { assert.equal(columns, 'data, revision'); calls.fullReads++; }
          const row = rows.get(uid);
          return { data: !row ? null : columns === 'revision' ? { revision: row.revision } : { ...row }, error: null };
        }
      };
    },
    async rpc(name, args) {
      assert.equal(name, 'save_encrypted_vault_cas');
      calls.writes++;
      if (control.beforeWrite) {
        const fn = control.beforeWrite;
        control.beforeWrite = null;
        await fn();
      }
      const current = rows.get(args.p_user_id);
      const revision = current?.revision || 0;
      if (revision !== args.p_expected_revision) return { data: { saved: false, revision }, error: null };
      rows.set(args.p_user_id, { revision: revision + 1, data: args.p_data });
      return { data: { saved: true, revision: revision + 1 }, error: null };
    }
  };
  vm.runInContext(source('data.js') + '\nglobalThis.db = DB; globalThis.cryptoHelpers = Crypto;', context);
  const key = await webcrypto.subtle.exportKey('jwk', await webcrypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']));
  context.localStorage.setItem('ttg_e2e_key', JSON.stringify(key));
  const put = async (uid, revision, vault) => rows.set(uid, { revision, data: await context.cryptoHelpers.encrypt(vault, key) });
  const read = () => context.cryptoHelpers.decrypt(rows.get(control.uid).data, key);
  return { context, db: context.db, rows, calls, control, put, read };
}

test('repeated saves read only the revision after the first download and preserve encryption', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('OLD')] });
  for (let i = 0; i < 3; i++) assert.equal(await f.db.syncNow(), true);
  assert.equal(f.calls.fullReads, 1);
  assert.equal(f.calls.metadataReads, 3);
  assert.equal((await f.read()).invoices[0].id, 'OLD');
  assert.equal(f.rows.get('owner-a').revision, 4);
});

test('a revision change fetches new server records while preserving local additions', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('OLD')] });
  await f.db.syncNow();
  f.db.invoices = [...f.db.invoices, invoice('LOCAL')];
  await f.put('owner-a', 3, { invoices: [invoice('OLD'), invoice('OTHER')] });
  assert.equal(await f.db.syncNow(), true);
  assert.equal(f.calls.fullReads, 2);
  assert.deepEqual(Array.from((await f.read()).invoices, i => i.id).sort(), ['LOCAL', 'OLD', 'OTHER']);
});

test('a write racing another device retries CAS and honors its deletion tombstone', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('OLD')] });
  await f.db.syncNow();
  f.db.invoices = [...f.db.invoices, invoice('LOCAL')];
  f.control.beforeWrite = () => f.put('owner-a', 3, {
    invoices: [invoice('OTHER')], deletedInvoiceIds: ['OLD'],
    recordActions: { invoices: { OLD: { deletedAt: Date.now(), restoredAt: 0 } } }
  });
  assert.equal(await f.db.syncNow(), true);
  const saved = await f.read();
  assert.deepEqual(Array.from(saved.invoices, i => i.id).sort(), ['LOCAL', 'OTHER']);
  assert.equal(f.rows.get('owner-a').revision, 4);
  assert.equal(f.calls.writes, 3);
  assert.equal(f.calls.fullReads, 2);
});

test('HTTP 402 cannot turn a cached vault into a successful sync or duplicate check', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('OLD')] });
  await f.db.syncNow();
  const before = f.rows.get('owner-a');
  f.control.readError = { status: 402, message: 'exceed_egress_quota' };
  assert.equal(await f.db.syncNow(), false);
  assert.equal((await f.db.getRemoteInvoiceSnapshot()).ok, false);
  assert.equal(f.calls.writes, 1);
  assert.equal(f.rows.get('owner-a'), before);
});

test('equal revisions belonging to different accounts never reuse the other ciphertext', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('A')] });
  await f.put('owner-b', 1, { invoices: [invoice('B')] });
  assert.equal((await f.db.getRemoteInvoiceSnapshot()).invoices[0].id, 'A');
  f.control.uid = 'owner-b';
  assert.equal((await f.db.getRemoteInvoiceSnapshot()).invoices[0].id, 'B');
  assert.equal(f.calls.fullReads, 2);
});

test('clearing local data does not erase the server vault on the next sync', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('KEEP')] });
  await f.db.syncNow();
  f.db.clearLocalData();
  assert.equal(f.db.invoices.length, 0);
  assert.equal(await f.db.syncNow(), true);
  assert.equal((await f.read()).invoices[0].id, 'KEEP');
  assert.equal(f.calls.fullReads, 2);
});

test('failed decryption never writes an empty or replacement vault', async () => {
  const f = await vaultFixture();
  f.rows.set('owner-a', { revision: 1, data: 'not-an-encrypted-vault' });
  assert.equal(await f.db.syncNow(), false);
  assert.equal(f.calls.writes, 0);
});

test('a missing live row does not return previously cached ciphertext', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('OLD')] });
  await f.db.getRemoteInvoiceSnapshot();
  f.rows.delete('owner-a');
  const result = await f.db._readRemoteVault('owner-a');
  assert.equal(result.data, null);
  assert.equal(f.db._remoteVaultCache, null);
});

test('startup and a later ledger check reuse only server-verified ciphertext', async () => {
  const f = await vaultFixture();
  await f.put('owner-a', 1, { invoices: [invoice('KEEP')] });
  assert.equal(await f.db.loadFromSupabase(), true);
  assert.equal((await f.db.getRemoteInvoiceSnapshot()).invoices[0].id, 'KEEP');
  assert.equal(f.calls.fullReads, 1);
  assert.equal(f.calls.metadataReads, 2);
});

test('malformed server revisions stop writes', async () => {
  const f = await vaultFixture();
  f.rows.set('owner-a', { revision: null, data: 'unexpected' });
  assert.equal(await f.db.syncNow(), false);
  assert.equal(f.calls.writes, 0);
});

function stagingFixture() {
  const requests = [];
  const context = vm.createContext({
    console: quiet, localStorage: storage(), sessionStorage: storage(), currentUser: { id: 'owner-a' },
    getUserId: () => 'owner-a', window: { location: { pathname: '/index.html' } },
    document: { addEventListener() {} }, setInterval() {}, crypto: webcrypto
  });
  context.supabaseClient = {
    from(table) {
      const query = { table, filters: [] };
      requests.push(query);
      return {
        select(columns) { query.columns = columns; return this; },
        eq(key, value) { query.filters.push([key, value]); return this; },
        async order() { return { data: [{ id: 'mine', owner_user_id: 'owner-a', status: 'pending', items_json: [] }], error: null }; },
        async maybeSingle() { return { data: { id: 'mine', receipt_photos: ['original-image'] }, error: null }; }
      };
    }
  };
  vm.runInContext(source('staging.js') + '\nglobalThis.staging = StagingDB;', context);
  context.staging._supabaseAvailable = true;
  return { context, staging: context.staging, requests };
}

test('owner list downloads metadata and receipt opening selects one owner-scoped row', async () => {
  const f = stagingFixture();
  assert.equal((await f.staging.getAllSubmissions()).length, 1);
  assert.equal(f.requests[0].columns.includes('receipt_photo'), false);
  assert.deepEqual(f.requests[0].filters, [['owner_user_id', 'owner-a']]);
  const docket = await f.staging.getSubmission('mine');
  assert.equal(docket.receipt_photos[0], 'original-image');
  assert.deepEqual(f.requests[1].filters, [['owner_user_id', 'owner-a'], ['id', 'mine']]);
});

test('clerk list asks for metadata and correction fetches the requested original receipt', async () => {
  const f = stagingFixture();
  f.context.sessionStorage.setItem('ttg_clerk_invite_token', 'test-invite');
  const calls = [];
  f.staging.callClerkApi = async body => {
    calls.push(body);
    return { owner: { name: 'Owner' }, submissions: [{ id: 'mine', receipt_photos: ['original-image'] }, { id: 'another' }] };
  };
  await f.staging.getAllSubmissions();
  const docket = await f.staging.getSubmission('mine');
  assert.equal(calls[0].include_photos, false);
  assert.equal(calls[1].submission_id, 'mine');
  assert.equal(calls[1].include_photos, true);
  assert.equal(docket.receipt_photos[0], 'original-image');
});

function clerkApiFixture() {
  const docketRows = [
    { id: 'mine', owner_user_id: 'owner', submitted_by_invite_id: 'invite', receipt_photo: 'photo', receipt_photos: ['photo'], status: 'rejected', items_json: [{ desc: 'Onion' }] },
    { id: 'other-invite', owner_user_id: 'owner', submitted_by_invite_id: 'different', receipt_photo: 'private' },
    { id: 'other-owner', owner_user_id: 'someone-else', submitted_by_invite_id: 'invite', receipt_photo: 'private' }
  ];
  const calls = [];
  const admin = {
    from(table) {
      const call = { table, filters: [], columns: '' };
      calls.push(call);
      return {
        select(columns) { call.columns = columns; return this; },
        eq(key, value) { call.filters.push([key, value]); return this; },
        async maybeSingle() {
          assert.equal(table, 'clerk_invites');
          return { data: { id: 'invite', owner_user_id: 'owner', owner_name: 'Owner', expires_at: '2100-01-01', revoked_at: null }, error: null };
        },
        async order() {
          const selected = docketRows.filter(row => call.filters.every(([key, value]) => row[key] === value));
          return { data: selected.map(row => call.columns === '*' ? row : Object.fromEntries(call.columns.split(',').filter(key => key in row).map(key => [key, row[key]]))), error: null };
        }
      };
    }
  };
  let handler;
  const context = vm.createContext({ createClient: () => admin, crypto: webcrypto, TextEncoder, Response, Request, console: quiet, btoa,
    Deno: { env: { get: () => 'configured' }, serve: fn => { handler = fn; } } });
  const code = source('supabase/functions/clerk-api/index.ts').replace(/^import .*;\r?\n/, '');
  vm.runInContext(stripTypeScriptTypes(code), context);
  const request = async body => {
    const response = await handler(new Request('https://example.test/clerk-api', { method: 'POST', body: JSON.stringify({ invite_token: 'a'.repeat(43), action: 'list', ...body }) }));
    return { status: response.status, body: await response.json() };
  };
  return { request, calls };
}

test('clerk metadata listing returns only this invite and excludes receipt bytes', async () => {
  const f = clerkApiFixture();
  const result = await f.request({ include_photos: false });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.submissions.map(row => row.id), ['mine']);
  assert.equal('receipt_photo' in result.body.submissions[0], false);
  assert.equal('receipt_photos' in result.body.submissions[0], false);
  assert.equal(f.calls.find(call => call.table === 'staged_invoices').columns.includes('receipt_photo'), false);
});

test('receipt detail retains photos and cannot access a different owner or invite', async () => {
  const f = clerkApiFixture();
  const mine = await f.request({ submission_id: 'mine', include_photos: true });
  assert.deepEqual(mine.body.submissions[0].receipt_photos, ['photo']);
  for (const id of ['other-invite', 'other-owner']) {
    assert.deepEqual((await f.request({ submission_id: id, include_photos: true })).body.submissions, []);
  }
  assert.deepEqual((await f.request({})).body.submissions[0].receipt_photos, ['photo']);
});

test('invalid detail ID is rejected instead of fetching all photos', async () => {
  const f = clerkApiFixture();
  assert.equal((await f.request({ submission_id: '' })).status, 400);
});
