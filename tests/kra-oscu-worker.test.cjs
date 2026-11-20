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

test('kra-oscu worker fails closed when unauthenticated or missing KRA_CMC_KEY', async () => {
  const { handleOscuRequest } = await loadOscuWorker();
  const env = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
  };

  const unauth = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', { method: 'POST' }),
    env,
    {},
    async () => new Response('{}', { status: 401 }),
  );
  assert.equal(unauth.status, 401);

  const missingCmc = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ saveTrnsSalesReq: { tin: 'P051234567X', itemList: [] } }),
    }),
    env,
    {},
    async () => new Response(JSON.stringify({ id: 'owner-1' }), { status: 200 }),
  );
  assert.equal(missingCmc.status, 503);
});

test('kra-oscu worker proxies saveTrnsSalesReq to KRA GavaConnect and builds official QR URL', async () => {
  const { handleOscuRequest } = await loadOscuWorker();
  const env = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
    KRA_CMC_KEY: 'secret-cmc-key',
  };

  let kraEndpoint = '';
  const res = await handleOscuRequest(
    new Request('https://oscu.example/oscu/sales', {
      method: 'POST',
      headers: { Authorization: 'Bearer valid-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sandbox: false,
        cuSerial: 'KRAMW001',
        saveTrnsSalesReq: {
          tin: 'P051234567X',
          bhfId: '00',
          invcNo: 42,
          itemList: [{ itemNm: 'Cooking Oil', taxTyCd: 'B', totAmt: 1160 }],
        },
      }),
    }),
    env,
    {},
    async (url) => {
      if (String(url).endsWith('/auth/v1/user')) {
        return new Response(JSON.stringify({ id: 'owner-1' }), { status: 200 });
      }
      kraEndpoint = String(url);
      return new Response(
        JSON.stringify({
          resultCd: '000',
          resultMsg: 'It is succeeded',
          data: {
            rcptNo: 42,
            rcptSign: 'ABCD1234EFGH5678',
            intrData: 'INTERNALDATA1',
            sdcDateTime: '20261121010000',
          },
        }),
        { status: 200 },
      );
    },
  );

  assert.equal(res.status, 200);
  assert.equal(kraEndpoint, 'https://etims-api.kra.go.ke/etims-api/saveTrnsSalesReq');
  const body = await res.json();
  assert.equal(body.cuInvoiceNumber, 'KRAMW001/42');
  assert.equal(
    body.qrCodeUrl,
    'https://etims.kra.go.ke/common/link/etims/receipt/indexEtimsInvoiceData?Data=P051234567X00ABCD1234EFGH5678',
  );
});
