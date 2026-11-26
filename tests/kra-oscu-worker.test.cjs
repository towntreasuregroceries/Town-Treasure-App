const test = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');

async function loadOscuWorker() {
  const workerPath = pathToFileURL(
    path.join(__dirname, '..', 'workers', 'kra-oscu-worker', 'src', 'index.js'),
  ).href;
  return import(workerPath);
}

function createFakeOscuD1() {
  const seq = new Map();
  const items = new Map();
  return {
    seq,
    items,
    prepare(rawSql) {
      const sql = rawSql.replace(/\s+/g, ' ').trim();
      const stmt = {
        args: [],
        bind(...args) {
          stmt.args = args;
          return stmt;
        },
        async run() {
          const a = stmt.args;
          if (sql.startsWith('INSERT INTO oscu_sequences')) {
            const key = `${a[0]}|${a[1]}`;
            if (!seq.has(key)) seq.set(key, 1);
            return { meta: { changes: 1 } };
          }
          if (sql.startsWith('INSERT INTO oscu_items')) {
            items.set(`${a[0]}|${a[1]}`, {
              tin: a[0],
              item_cd: a[1],
              item_cls_cd: a[2],
              item_nm: a[3],
              tax_ty_cd: a[4],
              synced_at: a[5],
            });
            return { meta: { changes: 1 } };
          }
          throw new Error(`Unhandled RUN SQL: ${sql}`);
        },
        async first() {
          const a = stmt.args;
          if (sql.startsWith('UPDATE oscu_sequences SET next_invc_no = next_invc_no + 1')) {
            const key = `${a[1]}|${a[2]}`;
            const cur = seq.get(key) ?? 1;
            seq.set(key, cur + 1);
            return { allocated: cur };
          }
          throw new Error(`Unhandled FIRST SQL: ${sql}`);
        },
      };
      return stmt;
    },
  };
}

test('kra-oscu worker fails closed when unauthenticated, allowlist unset, non-allowed owner, or missing KRA_CMC_KEY', async () => {
  const { handleOscuRequest } = await loadOscuWorker();
  const env = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
    ALLOWED_OWNER_EMAILS: 'veronjuguna89@gmail.com,onderegerald@gmail.com',
    SANDBOX_ONLY_EMAILS: 'onderegerald@gmail.com',
  };

  // Missing allowlist fails closed with 503
  const unsetAllowlist = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ saveTrnsSalesReq: { tin: 'P051234567X', itemList: [] } }),
    }),
    { SUPABASE_URL: 'https://example.supabase.co', SUPABASE_ANON_KEY: 'anon-key', KRA_CMC_KEY: 'k' },
    {},
    async () => new Response(JSON.stringify({ id: 'owner-1', email: 'veronjuguna89@gmail.com' }), { status: 200 }),
  );
  assert.equal(unsetAllowlist.status, 503);

  const unauth = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', { method: 'POST' }),
    env,
    {},
    async () => new Response('{}', { status: 401 }),
  );
  assert.equal(unauth.status, 401);

  const forbidden = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ saveTrnsSalesReq: { tin: 'P051234567X', itemList: [] } }),
    }),
    env,
    {},
    async () => new Response(JSON.stringify({ id: 'other-user', email: 'intruder@example.com' }), { status: 200 }),
  );
  assert.equal(forbidden.status, 403);

  const missingCmc = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ saveTrnsSalesReq: { tin: 'P051234567X', itemList: [] } }),
    }),
    env,
    {},
    async () => new Response(JSON.stringify({ id: '911aab5c-2d62-4377-b665-e9f8d65e3e2e', email: 'veronjuguna89@gmail.com' }), { status: 200 }),
  );
  assert.equal(missingCmc.status, 503);

  // Developer monitoring account (Ondere) is blocked from live production KRA but allowed in Sandbox
  const devLiveBlocked = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ sandbox: false, saveTrnsSalesReq: { tin: 'P051234567X', itemList: [] } }),
    }),
    { ...env, KRA_CMC_KEY: 'secret-cmc-key' },
    {},
    async () => new Response(JSON.stringify({ id: '25300b62-0945-4c37-8740-ff3302ff631e', email: 'onderegerald@gmail.com' }), { status: 200 }),
  );
  assert.equal(devLiveBlocked.status, 403);
});

test('kra-oscu worker allocates atomic D1 sequence, calls /saveTrnsSalesOsdc, supports /oscu/credit-note and /oscu/items/sync', async () => {
  const { handleOscuRequest } = await loadOscuWorker();
  const db = createFakeOscuD1();
  const env = {
    DB: db,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
    KRA_CMC_KEY: 'secret-cmc-key',
    ALLOWED_OWNER_EMAILS: 'veronjuguna89@gmail.com,onderegerald@gmail.com',
  };

  const calls = [];
  const fakeFetch = async (url, init = {}) => {
    if (String(url).endsWith('/auth/v1/user')) {
      return new Response(JSON.stringify({ id: '911aab5c-2d62-4377-b665-e9f8d65e3e2e', email: 'veronjuguna89@gmail.com' }), { status: 200 });
    }
    const payload = init.body ? JSON.parse(init.body) : {};
    calls.push({ url: String(url), payload });
    if (String(url).endsWith('/saveItem')) {
      return new Response(JSON.stringify({ resultCd: '000', resultMsg: 'OK' }), { status: 200 });
    }
    if (String(url).endsWith('/selectInitOsdcInfo')) {
      return new Response(
        JSON.stringify({ resultCd: '000', data: { sdcId: 'SDC001', mrcNo: 'MRC001' } }),
        { status: 200 },
      );
    }
    return new Response(
      JSON.stringify({
        resultCd: '000',
        resultMsg: 'It is succeeded',
        data: {
          rcptNo: payload.invcNo,
          rcptSign: 'ABCD1234EFGH5678',
          intrData: 'INTERNALDATA1',
          sdcDateTime: '20261121010000',
        },
      }),
      { status: 200 },
    );
  };

  // 1. Device Init
  const initRes = await handleOscuRequest(
    new Request('https://oscu.example/oscu/init', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ tin: 'P051234567X', bhfId: '00', dvcSrlNo: 'DVC999' }),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(initRes.status, 200);
  assert.equal(calls[0].url, 'https://etims-api.kra.go.ke/etims-api/selectInitOsdcInfo');

  // 2. Sync produce category item
  const syncRes = await handleOscuRequest(
    new Request('https://oscu.example/oscu/items/sync', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tin: 'P051234567X',
        bhfId: '00',
        items: [{ itemCd: 'TTG-PROD-VEG', itemClsCd: '50400000', itemNm: 'Fresh Vegetables', taxTyCd: 'E' }],
      }),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(syncRes.status, 200);
  assert.equal(db.items.size, 1);

  // 3. Sales invoice without invcNo allocates #1 from D1 atomically
  const res1 = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sandbox: false,
        cuSerial: 'KRAMW001',
        saveTrnsSalesReq: {
          tin: 'P051234567X',
          bhfId: '00',
          itemList: [{ itemNm: 'Cooking Oil', taxTyCd: 'B', totAmt: 1160 }],
        },
      }),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(res1.status, 200);
  const body1 = await res1.json();
  assert.equal(body1.invcNo, 1);
  assert.equal(body1.cuInvoiceNumber, 'KRAMW001/1');
  assert.equal(
    calls[2].url,
    'https://etims-api.kra.go.ke/etims-api/saveTrnsSalesOsdc',
  );
  assert.equal(
    body1.qrCodeUrl,
    'https://etims.kra.go.ke/common/link/etims/receipt/indexEtimsInvoiceData?Data=P051234567X00ABCD1234EFGH5678',
  );

  // 4. Credit note referencing orgInvcNo=1 allocates #2 and sets rcptTyCd='R'
  const crRes = await handleOscuRequest(
    new Request('https://oscu.example/oscu/credit-note', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        cuSerial: 'KRAMW001',
        originalInvcNo: 1,
        saveTrnsSalesReq: {
          tin: 'P051234567X',
          bhfId: '00',
          itemList: [{ itemNm: 'Cooking Oil', taxTyCd: 'B', totAmt: 1160 }],
        },
      }),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(crRes.status, 200);
  const crJson = await crRes.json();
  assert.equal(crJson.invcNo, 2);
  assert.equal(calls[3].payload.rcptTyCd, 'R');
  assert.equal(calls[3].payload.orgInvcNo, 1);
});
