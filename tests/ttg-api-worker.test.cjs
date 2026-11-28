const test = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');

async function loadTtgApiWorker() {
  const workerPath = pathToFileURL(
    path.join(__dirname, '..', 'workers', 'ttg-api', 'src', 'index.js'),
  ).href;
  return import(workerPath);
}

function createFakeR2Bucket() {
  const store = new Map();
  return {
    store,
    async put(key, value, options = {}) {
      const bodyStr = typeof value === 'string' ? value : new TextDecoder().decode(value);
      store.set(key, {
        key,
        body: bodyStr,
        customMetadata: options.customMetadata || {},
      });
      return store.get(key);
    },
    async get(key) {
      const item = store.get(key);
      if (!item) return null;
      return {
        ...item,
        async text() {
          return item.body;
        },
      };
    },
    async delete(key) {
      store.delete(key);
    },
  };
}

function createFakeD1() {
  const vaultMeta = new Map(); // user_id -> row
  const vaultHistory = []; // { user_id, revision, r2_key, created_at }
  const clerkInvites = new Map(); // id -> row
  const stagedInvoices = new Map(); // id -> row
  const clerkRateLimits = new Map(); // `${invite_id}|${hour_bucket}` -> row
  const stagedPodStamps = new Map(); // docket_id -> row

  function prepare(rawSql) {
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    const stmt = {
      args: [],
      bind(...args) {
        stmt.args = args;
        return stmt;
      },
      async first() {
        const res = await stmt.all();
        return res.results[0] ?? null;
      },
      async all() {
        const a = stmt.args;

        // vault_meta
        if (sql.includes('SELECT revision, r2_key, created_at FROM')) {
          const row = vaultMeta.get(a[0]);
          return { results: row ? [{ revision: row.revision, r2_key: row.r2_key, created_at: row.updated_at }] : [] };
        }
        if (sql === 'SELECT revision FROM vault_meta WHERE user_id = ?') {
          const row = vaultMeta.get(a[0]);
          return { results: row ? [{ revision: row.revision }] : [] };
        }
        if (sql === 'SELECT revision, r2_key FROM vault_meta WHERE user_id = ?') {
          const row = vaultMeta.get(a[0]);
          return { results: row ? [{ revision: row.revision, r2_key: row.r2_key }] : [] };
        }
        if (sql.startsWith('SELECT MAX(revision) AS max_rev FROM vault_history')) {
          const revs = vaultHistory.filter((h) => h.user_id === a[0]).map((h) => h.revision);
          return { results: [{ max_rev: revs.length ? Math.max(...revs) : null }] };
        }
        if (sql.startsWith('SELECT revision, r2_key FROM vault_history WHERE user_id = ? ORDER BY revision DESC')) {
          const offset = Number(a[1] || 0);
          const sorted = vaultHistory
            .filter((h) => h.user_id === a[0])
            .sort((x, y) => y.revision - x.revision)
            .slice(offset);
          return { results: sorted.map((h) => ({ revision: h.revision, r2_key: h.r2_key })) };
        }

        // clerk_invites
        if (sql.startsWith('SELECT id, owner_user_id, owner_email, owner_name, expires_at, revoked_at FROM clerk_invites WHERE token_hash = ?')) {
          const found = [...clerkInvites.values()].find((r) => r.token_hash === a[0]);
          return { results: found ? [{ ...found }] : [] };
        }

        // staged_invoices (clerk)
        if (sql.startsWith('SELECT updated_at, created_at FROM staged_invoices WHERE submitted_by_invite_id = ?')) {
          const rows = [...stagedInvoices.values()]
            .filter((r) => r.submitted_by_invite_id === a[0])
            .sort((x, y) => String(y.updated_at).localeCompare(String(x.updated_at)))
            .slice(0, 25);
          return { results: rows.map((r) => ({ updated_at: r.updated_at, created_at: r.created_at })) };
        }
        if (sql.startsWith('SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND id = ?')) {
          const r = stagedInvoices.get(a[2]);
          return {
            results: r && r.owner_user_id === a[0] && r.submitted_by_invite_id === a[1] ? [{ ...r }] : [],
          };
        }
        if (sql.startsWith('SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND submission_key = ?')) {
          const found = [...stagedInvoices.values()].find(
            (r) => r.owner_user_id === a[0] && r.submitted_by_invite_id === a[1] && r.submission_key === a[2],
          );
          return { results: found ? [{ ...found }] : [] };
        }
        if (sql.startsWith('SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ?')) {
          const rows = [...stagedInvoices.values()]
            .filter((r) => r.owner_user_id === a[0] && r.submitted_by_invite_id === a[1])
            .sort((x, y) => String(y.created_at).localeCompare(String(x.created_at)));
          return { results: rows.map((r) => ({ ...r })) };
        }
        if (sql.startsWith('SELECT COUNT(*) AS cnt FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ?')) {
          const cnt = [...stagedInvoices.values()].filter(
            (r) =>
              r.owner_user_id === a[0] &&
              r.submitted_by_invite_id === a[1] &&
              String(r.updated_at) >= String(a[2]),
          ).length;
          return { results: [{ cnt }] };
        }
        if (sql.startsWith("SELECT id, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND submitted_by_invite_id = ? AND status IN ('pending', 'rejected')")) {
          const r = stagedInvoices.get(a[0]);
          const ok = r && r.owner_user_id === a[1] && r.submitted_by_invite_id === a[2] && ['pending', 'rejected'].includes(r.status);
          return { results: ok ? [{ id: r.id, photo_keys_json: r.photo_keys_json }] : [] };
        }
        if (sql === 'SELECT id, status, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND submitted_by_invite_id = ?') {
          const r = stagedInvoices.get(a[0]);
          const ok = r && r.owner_user_id === a[1] && r.submitted_by_invite_id === a[2];
          return { results: ok ? [{ id: r.id, status: r.status, photo_keys_json: r.photo_keys_json }] : [] };
        }
        if (sql === 'SELECT submissions FROM clerk_rate_limits WHERE invite_id = ? AND hour_bucket = ?') {
          const r = clerkRateLimits.get(`${a[0]}|${a[1]}`);
          return { results: r ? [{ submissions: r.submissions }] : [] };
        }

        // staged_invoices (owner)
        if (sql.includes('FROM staged_invoices WHERE owner_user_id = ? ORDER BY created_at DESC')) {
          const rows = [...stagedInvoices.values()]
            .filter((r) => r.owner_user_id === a[0])
            .sort((x, y) => String(y.created_at).localeCompare(String(x.created_at)));
          return { results: rows.map((r) => ({ ...r })) };
        }
        if (sql.includes("FROM staged_invoices WHERE owner_user_id = ? AND status = 'pending'")) {
          const rows = [...stagedInvoices.values()].filter(
            (r) => r.owner_user_id === a[0] && r.status === 'pending',
          );
          return { results: rows.map((r) => ({ ...r })) };
        }
        if (sql === 'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND id = ?') {
          const r = stagedInvoices.get(a[1]);
          return { results: r && r.owner_user_id === a[0] ? [{ ...r }] : [] };
        }
        if (sql === 'SELECT owner_user_id, photo_keys_json, created_at FROM staged_invoices WHERE id = ?') {
          const r = stagedInvoices.get(a[0]);
          return {
            results: r ? [{ owner_user_id: r.owner_user_id, photo_keys_json: r.photo_keys_json, created_at: r.created_at }] : [],
          };
        }
        if (sql === 'SELECT * FROM staged_invoices WHERE id = ?') {
          const r = stagedInvoices.get(a[0]);
          return { results: r ? [{ ...r }] : [] };
        }
        if (sql.startsWith("SELECT id, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND status != 'approved'")) {
          const r = stagedInvoices.get(a[0]);
          const ok = r && r.owner_user_id === a[1] && r.status !== 'approved';
          return { results: ok ? [{ id: r.id, photo_keys_json: r.photo_keys_json }] : [] };
        }

        // staged_pod_stamps
        if (sql === 'SELECT pod_r2_key, receiver_name, captured_at, sha256 FROM staged_pod_stamps WHERE docket_id = ? AND owner_user_id = ?') {
          const r = stagedPodStamps.get(a[0]);
          return {
            results: r && r.owner_user_id === a[1]
              ? [{ pod_r2_key: r.pod_r2_key, receiver_name: r.receiver_name, captured_at: r.captured_at, sha256: r.sha256 }]
              : [],
          };
        }
        if (sql === 'SELECT docket_id, receiver_name, captured_at, sha256 FROM staged_pod_stamps WHERE owner_user_id = ?') {
          const rows = [...stagedPodStamps.values()].filter((r) => r.owner_user_id === a[0]);
          return {
            results: rows.map((r) => ({
              docket_id: r.docket_id,
              receiver_name: r.receiver_name,
              captured_at: r.captured_at,
              sha256: r.sha256,
            })),
          };
        }
        if (sql === 'SELECT pod_r2_key FROM staged_pod_stamps WHERE docket_id = ? AND owner_user_id = ?') {
          const r = stagedPodStamps.get(a[0]);
          return { results: r && r.owner_user_id === a[1] ? [{ pod_r2_key: r.pod_r2_key }] : [] };
        }

        throw new Error(`Unhandled D1 ALL/FIRST query in test fake: ${sql}`);
      },
      async run() {
        const a = stmt.args;

        if (sql.startsWith('INSERT INTO vault_meta (user_id, revision, r2_key, sha256, updated_at) VALUES (?, 1, ?, ?, ?) ON CONFLICT(user_id) DO NOTHING')) {
          if (vaultMeta.has(a[0])) return { meta: { changes: 0 } };
          vaultMeta.set(a[0], { user_id: a[0], revision: 1, r2_key: a[1], sha256: a[2], updated_at: a[3] });
          return { meta: { changes: 1 } };
        }
        if (sql.startsWith('INSERT INTO vault_meta (user_id, revision, r2_key, sha256, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE')) {
          vaultMeta.set(a[0], { user_id: a[0], revision: a[1], r2_key: a[2], sha256: a[3], updated_at: a[4] });
          return { meta: { changes: 1 } };
        }
        if (sql === 'UPDATE vault_meta SET revision = ?, r2_key = ?, sha256 = ?, updated_at = ? WHERE user_id = ? AND revision = ?') {
          const existing = vaultMeta.get(a[4]);
          if (!existing || existing.revision !== a[5]) return { meta: { changes: 0 } };
          vaultMeta.set(a[4], { user_id: a[4], revision: a[0], r2_key: a[1], sha256: a[2], updated_at: a[3] });
          return { meta: { changes: 1 } };
        }
        if (sql.startsWith('INSERT INTO vault_history')) {
          if (!vaultHistory.some((h) => h.user_id === a[0] && h.revision === a[1])) {
            vaultHistory.push({ user_id: a[0], revision: a[1], r2_key: a[2], created_at: a[3] });
          }
          return { meta: { changes: 1 } };
        }
        if (sql === 'DELETE FROM vault_history WHERE user_id = ? AND revision = ?') {
          const idx = vaultHistory.findIndex((h) => h.user_id === a[0] && h.revision === a[1]);
          if (idx >= 0) vaultHistory.splice(idx, 1);
          return { meta: { changes: idx >= 0 ? 1 : 0 } };
        }
        if (sql.startsWith('INSERT INTO clerk_invites')) {
          clerkInvites.set(a[0], {
            id: a[0],
            owner_user_id: a[1],
            token_hash: a[2],
            owner_email: a[3],
            owner_name: a[4],
            expires_at: a[5],
            revoked_at: sql.includes('revoked_at') ? a[6] : null,
            created_at: sql.includes('revoked_at') ? a[7] : a[6],
          });
          return { meta: { changes: 1 } };
        }
        if (sql.startsWith('UPDATE clerk_invites SET revoked_at = ? WHERE owner_user_id = ?')) {
          let changes = 0;
          for (const inv of clerkInvites.values()) {
            if (inv.owner_user_id === a[1] && !inv.revoked_at && inv.id !== a[2]) {
              inv.revoked_at = a[0];
              changes++;
            }
          }
          return { meta: { changes } };
        }
        if (sql.startsWith('INSERT INTO staged_invoices')) {
          if (sql.includes("VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '',")) {
            stagedInvoices.set(a[0], {
              id: a[0],
              owner_user_id: a[1],
              submitted_by_invite_id: a[2],
              submission_key: a[3],
              clerk_name: a[4],
              restaurant_name: a[5],
              invoice_date: a[6],
              items_json: a[7],
              delivery_cost: a[8],
              other_cost: a[9],
              total_sell: a[10],
              total_buy: a[11],
              photo_keys_json: a[12],
              notes: a[13],
              status: 'pending',
              rejection_reason: '',
              target_user_id: a[14],
              target_user_email: a[15],
              target_user_name: a[16],
              created_at: a[17],
              updated_at: a[18],
            });
          } else {
            const cur = stagedInvoices.get(a[0]);
            if (cur && sql.includes('WHERE staged_invoices.owner_user_id = excluded.owner_user_id') && cur.owner_user_id !== a[1]) {
              return { meta: { changes: 0 } };
            }
            stagedInvoices.set(a[0], {
              id: a[0],
              owner_user_id: cur ? cur.owner_user_id : a[1],
              submitted_by_invite_id: cur ? cur.submitted_by_invite_id : a[2],
              submission_key: cur ? cur.submission_key : a[3],
              clerk_name: a[4],
              restaurant_name: a[5],
              invoice_date: a[6],
              items_json: a[7],
              delivery_cost: a[8],
              other_cost: a[9],
              total_sell: a[10],
              total_buy: a[11],
              photo_keys_json: a[12],
              notes: a[13],
              status: a[14],
              rejection_reason: a[15],
              target_user_id: cur ? cur.target_user_id : a[16],
              target_user_email: cur ? cur.target_user_email : a[17],
              target_user_name: cur ? cur.target_user_name : a[18],
              created_at: cur ? cur.created_at : a[19],
              updated_at: a[20],
            });
          }
          return { meta: { changes: 1 } };
        }
        if (sql.startsWith('INSERT INTO clerk_rate_limits')) {
          const key = `${a[0]}|${a[1]}`;
          const cur = clerkRateLimits.get(key);
          clerkRateLimits.set(key, {
            invite_id: a[0],
            hour_bucket: a[1],
            submissions: (cur?.submissions ?? 0) + 1,
            updated_at: a[2],
          });
          return { meta: { changes: 1 } };
        }
        if (sql === 'DELETE FROM clerk_rate_limits WHERE hour_bucket < ?') {
          let changes = 0;
          for (const [k, v] of clerkRateLimits.entries()) {
            if (v.hour_bucket < a[0]) {
              clerkRateLimits.delete(k);
              changes++;
            }
          }
          return { meta: { changes } };
        }
        if (sql === 'DELETE FROM staged_invoices WHERE id = ?') {
          const had = stagedInvoices.delete(a[0]);
          return { meta: { changes: had ? 1 : 0 } };
        }
        if (sql.startsWith("DELETE FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND status != 'approved'")) {
          const r = stagedInvoices.get(a[0]);
          if (r && r.owner_user_id === a[1] && r.status !== 'approved') {
            stagedInvoices.delete(a[0]);
            return { meta: { changes: 1 } };
          }
          return { meta: { changes: 0 } };
        }
        if (sql.startsWith("UPDATE staged_invoices SET status = 'rejected'")) {
          const r = stagedInvoices.get(a[2]);
          if (r && r.owner_user_id === a[3] && r.status === 'pending') {
            r.status = 'rejected';
            r.rejection_reason = a[0];
            r.updated_at = a[1];
            return { meta: { changes: 1 } };
          }
          return { meta: { changes: 0 } };
        }
        if (sql.startsWith('UPDATE staged_invoices SET')) {
          // Owner status update or clerk returned update
          const idIdx = sql.includes("status = 'rejected'") ? a.length - 3 : a.length - (sql.includes('submitted_by_invite_id = ?') ? 3 : 2);
          const id = a[idIdx];
          const r = stagedInvoices.get(id);
          if (!r) return { meta: { changes: 0 } };
          if (sql.includes("status = 'pending', rejection_reason = ''")) {
            if (r.owner_user_id !== a[idIdx + 1] || r.submitted_by_invite_id !== a[idIdx + 2] || r.status !== 'rejected') {
              return { meta: { changes: 0 } };
            }
            Object.assign(r, {
              submission_key: a[0],
              clerk_name: a[1],
              restaurant_name: a[2],
              invoice_date: a[3],
              items_json: a[4],
              delivery_cost: a[5],
              other_cost: a[6],
              total_sell: a[7],
              total_buy: a[8],
              photo_keys_json: a[9],
              notes: a[10],
              status: 'pending',
              rejection_reason: '',
              updated_at: a[11],
            });
            return { meta: { changes: 1 } };
          }
          if (r.owner_user_id !== a[a.length - 1]) return { meta: { changes: 0 } };
          r.status = a[0];
          r.updated_at = a[1];
          return { meta: { changes: 1 } };
        }
        if (sql.startsWith('INSERT INTO staged_pod_stamps')) {
          const cur = stagedPodStamps.get(a[0]);
          if (cur && cur.owner_user_id !== a[1]) return { meta: { changes: 0 } };
          stagedPodStamps.set(a[0], {
            docket_id: a[0],
            owner_user_id: a[1],
            pod_r2_key: a[2],
            receiver_name: a[3],
            captured_at: a[4],
            sha256: a[5],
          });
          return { meta: { changes: 1 } };
        }
        if (sql === 'DELETE FROM staged_pod_stamps WHERE docket_id = ? AND owner_user_id = ?') {
          const cur = stagedPodStamps.get(a[0]);
          if (cur && cur.owner_user_id === a[1]) {
            stagedPodStamps.delete(a[0]);
            return { meta: { changes: 1 } };
          }
          return { meta: { changes: 0 } };
        }

        throw new Error(`Unhandled D1 RUN query in test fake: ${sql}`);
      },
    };
    return stmt;
  }

  return { prepare, vaultMeta, vaultHistory, clerkInvites, stagedInvoices, stagedPodStamps };
}

function makeFakeAuthFetch(usersByToken) {
  return async (url, init = {}) => {
    assert.match(String(url), /\/auth\/v1\/user$/);
    const auth = init.headers?.Authorization || '';
    const token = auth.replace(/^Bearer\s+/i, '');
    const user = usersByToken[token];
    if (!user) {
      return new Response(JSON.stringify({ error: 'invalid_jwt' }), { status: 401 });
    }
    return new Response(JSON.stringify(user), { status: 200 });
  };
}

test('ttg-api health & fail-closed admin/seed when MIGRATION_SECRET unset', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const env = {
    DB: createFakeD1(),
    STORAGE: createFakeR2Bucket(),
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
  };
  const health = await handleApiRequest(new Request('https://api.example/health'), env, {});
  assert.equal(health.status, 200);
  const hb = await health.json();
  assert.deepEqual(hb, { ok: true, service: 'ttg-api', hasDb: true, hasStorage: true, hasGemini: false });

  const seedRes = await handleApiRequest(
    new Request('https://api.example/admin/seed', {
      method: 'POST',
      headers: { 'X-Migration-Secret': 'anything' },
      body: JSON.stringify({ type: 'vault', rows: [] }),
    }),
    env,
    {},
  );
  assert.equal(seedRes.status, 404);
});

test('ttg-api vault CAS create, conflict detection, read, and history archive', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const db = createFakeD1();
  const storage = createFakeR2Bucket();
  const env = {
    DB: db,
    STORAGE: storage,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
  };
  const authFetch = makeFakeAuthFetch({
    'jwt-vero': { id: 'owner-1', email: 'vero@example.com', user_metadata: { full_name: 'Veronica' } },
  });

  // Initial revision -> exists: false
  const rev0 = await handleApiRequest(
    new Request('https://api.example/vault/revision', {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await rev0.json(), { exists: false, revision: null });

  // Stale expectedRevision=1 on empty vault fails closed
  const staleCreate = await handleApiRequest(
    new Request('https://api.example/vault/cas', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expectedRevision: 1, data: 'enc-v1' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await staleCreate.json(), { saved: false, revision: 0 });

  // Create rev=1
  const createRes = await handleApiRequest(
    new Request('https://api.example/vault/cas', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expectedRevision: 0, data: 'enc-v1' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await createRes.json(), { saved: true, revision: 1 });

  // Update rev 1 -> 2 and archive rev 1 in vault_history
  const updRes = await handleApiRequest(
    new Request('https://api.example/vault/cas', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expectedRevision: 1, data: 'enc-v2' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await updRes.json(), { saved: true, revision: 2 });
  assert.equal(db.vaultHistory.length, 1);

  // Conflict when writing with stale expectedRevision=1
  const conflictRes = await handleApiRequest(
    new Request('https://api.example/vault/cas', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expectedRevision: 1, data: 'enc-stale' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await conflictRes.json(), { saved: false, revision: 2 });

  // Read live vault returns latest encrypted payload from R2
  const readRes = await handleApiRequest(
    new Request('https://api.example/vault', {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await readRes.json(), { exists: true, revision: 2, data: 'enc-v2' });
});

test('ttg-api /clerk create_invite -> submit -> idempotency -> owner approve & reject', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const db = createFakeD1();
  const storage = createFakeR2Bucket();
  const env = {
    DB: db,
    STORAGE: storage,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
  };
  const authFetch = makeFakeAuthFetch({
    'jwt-vero': { id: 'owner-1', email: 'vero@example.com', user_metadata: { full_name: 'Veronica' } },
  });

  // 1. Owner generates clerk invite
  const invRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'create_invite' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(invRes.status, 200);
  const invBody = await invRes.json();
  assert.ok(invBody.token && invBody.token.length >= 40);

  // 2. Clerk submits docket with 1 receipt photo (base64 data URL -> offloaded to R2)
  const submitBody = {
    action: 'submit',
    invite_token: invBody.token,
    submission_key: 'sub_1234567890abcdef',
    docker_unused: true,
    docket: {
      clerk_name: 'John Clerk',
      restaurant_name: 'Acacia Grill',
      invoice_date: '2026-11-21',
      items_json: [{ desc: 'Tomatoes', qty: 5, unit: 'kgs', sellPrice: 120, buyPrice: 80 }],
      delivery_cost: 200,
      receipt_photos: ['data:image/jpeg;base64,/9j/4AAQSkZJRg=='],
      notes: 'Morning drop',
    },
  };
  const sub1 = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(submitBody),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(sub1.status, 200);
  const sub1Json = await sub1.json();
  assert.equal(sub1Json.replayed, false);
  assert.equal(sub1Json.submission.total_sell, 800);
  assert.equal(sub1Json.submission.total_buy, undefined); // stripped for clerk!

  // 3. Duplicate submission_key replays cleanly without duplicating D1 rows
  const subReplay = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(submitBody),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal((await subReplay.json()).replayed, true);
  assert.equal(db.stagedInvoices.size, 1);

  // 4. Owner fetches list & full record (with hydrated R2 photo!)
  const listRes = await handleApiRequest(
    new Request('https://api.example/staged', {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  const listJson = await listRes.json();
  assert.equal(listJson.rows.length, 1);
  assert.equal(listJson.rows[0].total_buy, 400);

  const detailRes = await handleApiRequest(
    new Request(`https://api.example/staged/${encodeURIComponent(sub1Json.submission.id)}`, {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  const detailJson = await detailRes.json();
  assert.deepEqual(detailJson.row.receipt_photos, ['data:image/jpeg;base64,/9j/4AAQSkZJRg==']);

  // 5. Owner approves staged docket
  const approveRes = await handleApiRequest(
    new Request(`https://api.example/staged/${encodeURIComponent(sub1Json.submission.id)}/status`, {
      method: 'PATCH',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'approved' }),
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await approveRes.json(), { updated: true });
});

test('ttg-api security: blocks cross-tenant PUT /staged/:id, hides owner email on clerk list, enforces persistent 30/hr rate limit across submit+delete, and cleans orphaned R2 photos', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const db = createFakeD1();
  const storage = createFakeR2Bucket();
  const env = {
    DB: db,
    STORAGE: storage,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
    ALLOWED_OWNER_IDS: '911aab5c-2d62-4377-b665-e9f8d65e3e2e,25300b62-0945-4c37-8740-ff3302ff631e',
    ALLOWED_OWNER_EMAILS: 'veronjuguna89@gmail.com,onderegerald@gmail.com',
  };
  const authFetch = makeFakeAuthFetch({
    'jwt-vero': {
      id: '911aab5c-2d62-4377-b665-e9f8d65e3e2e',
      email: 'veronjuguna89@gmail.com',
      user_metadata: { full_name: 'Veronicah' },
    },
    'jwt-ondere': {
      id: '25300b62-0945-4c37-8740-ff3302ff631e',
      email: 'onderegerald@gmail.com',
      user_metadata: { full_name: 'Ondere' },
    },
    'jwt-intruder': {
      id: '00000000-0000-0000-0000-000000000999',
      email: 'intruder@example.com',
    },
  });

  // Unlisted Supabase user is blocked by owner allowlist
  const intruderRes = await handleApiRequest(
    new Request('https://api.example/vault', {
      headers: { Authorization: 'Bearer jwt-intruder' },
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(intruderRes.status, 403);

  // Veronicah creates a staged docket
  const veroPut = await handleApiRequest(
    new Request('https://api.example/staged/stg_vero_1', {
      method: 'PUT',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clerk_name: 'Mary',
        restaurant_name: 'Java House',
        invoice_date: '2026-11-26',
        items_json: [{ desc: 'Carrots', qty: 10, unit: 'kgs', sellPrice: 100 }],
        total_sell: 1000,
      }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(veroPut.status, 200);

  // Cross-tenant PUT /staged/stg_vero_1 by another account returns 403 and preserves Veronicah's data
  const crossPut = await handleApiRequest(
    new Request('https://api.example/staged/stg_vero_1', {
      method: 'PUT',
      headers: { Authorization: 'Bearer jwt-ondere', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clerk_name: 'Tampered',
        restaurant_name: 'Tampered',
        invoice_date: '2026-11-26',
        items_json: [],
        total_sell: 0,
      }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(crossPut.status, 403);
  assert.equal(db.stagedInvoices.get('stg_vero_1').restaurant_name, 'Java House');

  // Clerk invite list hides Veronicah's login email while keeping her display name
  const invRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'create_invite' }),
    }),
    env,
    {},
    authFetch,
  );
  const { token } = await invRes.json();

  const clerkListRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'list', invite_token: token }),
    }),
    env,
    {},
    authFetch,
  );
  const clerkListJson = await clerkListRes.json();
  assert.equal(clerkListJson.owner.name, 'Veronicah');
  assert.equal(clerkListJson.owner.email, undefined);

  // Returned docket resubmission with fewer photos deletes orphaned page-1.txt from R2
  const twoPhotoSub = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'submit',
        invite_token: token,
        submission_key: 'sub_orphan_test_0001',
        docket: {
          clerk_name: 'Mary',
          restaurant_name: 'Artcaffe',
          invoice_date: '2026-11-26',
          items_json: [{ desc: 'Onions', qty: 2, unit: 'kgs', sellPrice: 90 }],
          receipt_photos: [
            'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
            'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
          ],
        },
      }),
    }),
    env,
    {},
    authFetch,
  );
  const twoPhotoId = (await twoPhotoSub.json()).submission.id;
  assert.equal(storage.store.has(`staged/911aab5c-2d62-4377-b665-e9f8d65e3e2e/${twoPhotoId}/page-1.txt`), true);

  await handleApiRequest(
    new Request(`https://api.example/staged/${encodeURIComponent(twoPhotoId)}/reject`, {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ reason: 'Remove blurry page 2' }),
    }),
    env,
    {},
    authFetch,
  );

  const correctedSub = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'submit',
        invite_token: token,
        submission_key: 'sub_orphan_test_0002',
        docket: {
          id: twoPhotoId,
          clerk_name: 'Mary',
          restaurant_name: 'Artcaffe',
          invoice_date: '2026-11-26',
          items_json: [{ desc: 'Onions', qty: 2, unit: 'kgs', sellPrice: 90 }],
          receipt_photos: ['data:image/jpeg;base64,/9j/4AAQSkZJRg=='],
        },
      }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(correctedSub.status, 200);
  assert.equal(storage.store.has(`staged/911aab5c-2d62-4377-b665-e9f8d65e3e2e/${twoPhotoId}/page-1.txt`), false);

  // Submit + delete loop still hits 429 after 30 total submissions in the hour
  for (let i = 3; i <= 30; i++) {
    const sRes = await handleApiRequest(
      new Request('https://api.example/clerk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'submit',
          invite_token: token,
          submission_key: `sub_loop_rate_limit_${String(i).padStart(4, '0')}`,
          docket: {
            clerk_name: 'Mary',
            restaurant_name: 'Artcaffe',
            invoice_date: '2026-11-26',
            items_json: [{ desc: 'Peas', qty: 1, unit: 'kgs', sellPrice: 50 }],
          },
        }),
      }),
      env,
      {},
      authFetch,
    );
    assert.equal(sRes.status, 200);
    const createdId = (await sRes.json()).submission.id;
    const delRes = await handleApiRequest(
      new Request('https://api.example/clerk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'delete', invite_token: token, id: createdId }),
      }),
      env,
      {},
      authFetch,
    );
    assert.equal(delRes.status, 200);
  }

  const blocked31 = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'submit',
        invite_token: token,
        submission_key: 'sub_loop_rate_limit_0031',
        docket: {
          clerk_name: 'Mary',
          restaurant_name: 'Artcaffe',
          invoice_date: '2026-11-26',
          items_json: [{ desc: 'Peas', qty: 1, unit: 'kgs', sellPrice: 50 }],
        },
      }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(blocked31.status, 429);

  // Declared oversized Content-Length fails closed with 413
  const oversized = await handleApiRequest(
    new Request('https://api.example/vault/cas', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer jwt-vero',
        'Content-Type': 'application/json',
        'Content-Length': String(30 * 1024 * 1024),
      },
      body: '{}',
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(oversized.status, 413);
});

test('ttg-api POD stamp: clerk submits client_pod_stamp -> owner list shows metadata -> owner detail hydrates R2 stamp -> delete cleans R2 & D1', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const db = createFakeD1();
  const storage = createFakeR2Bucket();
  const env = {
    DB: db,
    STORAGE: storage,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
  };
  const authFetch = makeFakeAuthFetch({
    'jwt-vero': { id: 'owner-1', email: 'vero@example.com', user_metadata: { full_name: 'Veronicah' } },
  });

  const invRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'create_invite' }),
    }),
    env,
    {},
    authFetch,
  );
  const { token } = await invRes.json();

  const samplePngDataUri = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  const sampleSha = 'a'.repeat(64);
  const subRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'submit',
        invite_token: token,
        submission_key: 'sub_pod_stamp_000001',
        docket: {
          clerk_name: 'John Clerk',
          restaurant_name: 'Sankara Nairobi',
          invoice_date: '2026-11-27',
          items_json: [{ desc: 'Avocados', qty: 12, unit: 'kgs', sellPrice: 150, buyPrice: 90 }],
          client_pod_stamp: samplePngDataUri,
          client_pod_receiver: 'Chef Musa',
          client_pod_at: '2026-11-27T10:15:00.000Z',
          client_pod_sha256: sampleSha,
        },
      }),
    }),
    env,
    {},
    authFetch,
  );
  assert.equal(subRes.status, 200);
  const subJson = await subRes.json();
  const docketId = subJson.submission.id;
  assert.equal(subJson.submission.client_pod_receiver, 'Chef Musa');
  assert.equal(subJson.submission.client_pod_stamp, samplePngDataUri);
  assert.equal(storage.store.has(`staged/owner-1/${docketId}/pod-stamp.txt`), true);

  // Owner GET /staged returns lightweight POD metadata without transferring heavy R2 stamp bytes
  const listRes = await handleApiRequest(
    new Request('https://api.example/staged', {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  const listJson = await listRes.json();
  assert.equal(listJson.rows.length, 1);
  assert.equal(listJson.rows[0].client_pod_receiver, 'Chef Musa');
  assert.equal(listJson.rows[0].client_pod_sha256, sampleSha);
  assert.equal(listJson.rows[0].client_pod_stamp, undefined);

  // Owner GET /staged/:id hydrates full transparent PNG stamp from R2
  const detailRes = await handleApiRequest(
    new Request(`https://api.example/staged/${encodeURIComponent(docketId)}`, {
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  const detailJson = await detailRes.json();
  assert.equal(detailJson.row.client_pod_stamp, samplePngDataUri);
  assert.equal(detailJson.row.client_pod_receiver, 'Chef Musa');

  // Deleting pending docket cleans up both R2 pod-stamp.txt and D1 staged_pod_stamps row
  const delRes = await handleApiRequest(
    new Request(`https://api.example/staged/${encodeURIComponent(docketId)}`, {
      method: 'DELETE',
      headers: { Authorization: 'Bearer jwt-vero' },
    }),
    env,
    {},
    authFetch,
  );
  assert.deepEqual(await delRes.json(), { deleted: true });
  assert.equal(storage.store.has(`staged/owner-1/${docketId}/pod-stamp.txt`), false);
  assert.equal(db.stagedPodStamps.size, 0);
});

test('ttg-api POST /stamp/locate: supports Owner Bearer and Clerk invite_token, validates payload, and sanitizes Gemini JSON', async () => {
  const { handleApiRequest } = await loadTtgApiWorker();
  const db = createFakeD1();
  const storage = createFakeR2Bucket();
  const env = {
    DB: db,
    STORAGE: storage,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon',
    GEMINI_API_KEY: 'fake-gemini-secret-key',
  };

  let geminiCalls = 0;
  let lastGeminiUrl = '';
  const combinedFetch = async (url, init) => {
    const s = String(url);
    if (s.includes('/auth/v1/user')) {
      const auth = init?.headers?.Authorization || init?.headers?.authorization || '';
      if (auth === 'Bearer jwt-vero') {
        return new Response(
          JSON.stringify({ id: 'owner-1', email: 'vero@example.com', user_metadata: { full_name: 'Veronicah' } }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        );
      }
      return new Response(JSON.stringify({ error: 'Invalid' }), { status: 401 });
    }
    if (s.includes('generativelanguage.googleapis.com')) {
      geminiCalls++;
      lastGeminiUrl = s;
      return new Response(
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      box_2d: [260, 210, 524, 778],
                      shape: 'oval',
                      upright_clockwise_rotation_deg: 9.5,
                      stamp_organization: 'CO-OPERATIVE BANK UTAWALA',
                      stamp_date: '02 JUL 2026',
                      receiver_or_user: 'USER FSN',
                      stamp_ink_color: 'violet',
                      has_printed_form_underneath: true,
                    }),
                  },
                ],
              },
            },
          ],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }
    throw new Error(`Unexpected fetch URL: ${s}`);
  };

  // Health reports hasGemini boolean without exposing secret
  const healthRes = await handleApiRequest(new Request('https://api.example/health'), env, {}, combinedFetch);
  const healthJson = await healthRes.json();
  assert.equal(healthJson.hasGemini, true);

  // Missing auth -> 401
  const sampleB64 = 'A'.repeat(64);
  const unauthRes = await handleApiRequest(
    new Request('https://api.example/stamp/locate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ image_base64: sampleB64 }),
    }),
    env,
    {},
    combinedFetch,
  );
  assert.equal(unauthRes.status, 401);

  // Owner Bearer succeeds
  const ownerRes = await handleApiRequest(
    new Request('https://api.example/stamp/locate', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ image_base64: `data:image/jpeg;base64,${sampleB64}` }),
    }),
    env,
    {},
    combinedFetch,
  );
  assert.equal(ownerRes.status, 200);
  const ownerJson = await ownerRes.json();
  assert.equal(ownerJson.ok, true);
  assert.equal(ownerJson.model, 'gemini-3.5-flash-lite');
  assert.deepEqual(ownerJson.box_2d, [260, 210, 524, 778]);
  assert.equal(ownerJson.shape, 'oval');
  assert.equal(ownerJson.receiver_or_user, 'USER FSN');
  assert.equal(ownerJson.has_printed_form_underneath, true);
  assert.match(lastGeminiUrl, /gemini-3\.5-flash-lite:generateContent/);

  // Create valid Clerk invite and call /stamp/locate with invite_token (no Bearer header)
  const invRes = await handleApiRequest(
    new Request('https://api.example/clerk', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'create_invite' }),
    }),
    env,
    {},
    combinedFetch,
  );
  const { token: clerkToken } = await invRes.json();

  const clerkRes = await handleApiRequest(
    new Request('https://api.example/stamp/locate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ invite_token: clerkToken, image_base64: sampleB64 }),
    }),
    env,
    {},
    combinedFetch,
  );
  assert.equal(clerkRes.status, 200);
  assert.equal(geminiCalls, 2);

  // Missing GEMINI_API_KEY returns 503 cleanly
  const noKeyRes = await handleApiRequest(
    new Request('https://api.example/stamp/locate', {
      method: 'POST',
      headers: { Authorization: 'Bearer jwt-vero', 'Content-Type': 'application/json' },
      body: JSON.stringify({ image_base64: sampleB64 }),
    }),
    { ...env, GEMINI_API_KEY: '' },
    {},
    combinedFetch,
  );
  assert.equal(noKeyRes.status, 503);
});
