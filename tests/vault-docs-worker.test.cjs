const test = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');

async function loadWorker() {
  const workerPath = pathToFileURL(
    path.join(__dirname, '..', 'workers', 'vault-docs-worker', 'src', 'index.js'),
  ).href;
  return import(workerPath);
}

function createFakeR2Bucket() {
  const store = new Map();
  return {
    store,
    async put(key, value, options = {}) {
      const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
      store.set(key, {
        key,
        body: bytes,
        size: bytes.byteLength,
        etag: `etag-${bytes.byteLength}`,
        uploaded: new Date('2026-11-20T12:00:00Z'),
        customMetadata: options.customMetadata || {},
      });
      return store.get(key);
    },
    async get(key) {
      const item = store.get(key);
      if (!item) return null;
      return {
        ...item,
        body: new Blob([item.body]).stream(),
      };
    },
    async delete(key) {
      store.delete(key);
    },
    async list({ prefix = '' } = {}) {
      const objects = [];
      for (const item of store.values()) {
        if (item.key.startsWith(prefix)) objects.push(item);
      }
      return { objects, truncated: false, cursor: null };
    },
  };
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
    return new Response(JSON.stringify({ id: user }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };
}

test('vault-docs worker rejects unauthenticated requests and path traversal IDs', async () => {
  const { handleVaultRequest } = await loadWorker();
  const bucket = createFakeR2Bucket();
  const env = {
    VAULT_DOCS_BUCKET: bucket,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
  };
  const fakeFetch = makeFakeAuthFetch({
    'token-owner': '11111111-2222-3333-4444-555555555555',
  });

  const noAuth = await handleVaultRequest(
    new Request('https://vault.example/docs/doc_1', { method: 'GET' }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(noAuth.status, 401);

  const badId = await handleVaultRequest(
    new Request('https://vault.example/docs/..%2Fsecret', {
      method: 'GET',
      headers: { Authorization: 'Bearer token-owner' },
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(badId.status, 400);
});

test('vault-docs worker rejects undersized ciphertext and oversized payloads', async () => {
  const { handleVaultRequest } = await loadWorker();
  const bucket = createFakeR2Bucket();
  const env = {
    VAULT_DOCS_BUCKET: bucket,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
  };
  const fakeFetch = makeFakeAuthFetch({
    'token-owner': '11111111-2222-3333-4444-555555555555',
  });

  const tooSmall = await handleVaultRequest(
    new Request('https://vault.example/docs/kra_tcc_2026', {
      method: 'PUT',
      headers: { Authorization: 'Bearer token-owner' },
      body: new Uint8Array([1, 2, 3, 4]),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(tooSmall.status, 400);

  const tooLarge = await handleVaultRequest(
    new Request('https://vault.example/docs/kra_tcc_2026', {
      method: 'PUT',
      headers: {
        Authorization: 'Bearer token-owner',
        'Content-Length': String(26 * 1024 * 1024),
      },
      body: new Uint8Array(64),
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(tooLarge.status, 413);
});

test('vault-docs worker isolates users and completes PUT -> GET -> LIST -> DELETE round-trip', async () => {
  const { handleVaultRequest } = await loadWorker();
  const bucket = createFakeR2Bucket();
  const env = {
    VAULT_DOCS_BUCKET: bucket,
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key',
  };
  const ownerA = '11111111-2222-3333-4444-555555555555';
  const ownerB = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const fakeFetch = makeFakeAuthFetch({
    'token-a': ownerA,
    'token-b': ownerB,
  });

  const encryptedSample = new Uint8Array(48);
  encryptedSample.fill(7);

  const putRes = await handleVaultRequest(
    new Request('https://vault.example/docs/tcc_cert_2026', {
      method: 'PUT',
      headers: {
        Authorization: 'Bearer token-a',
        'X-Doc-Sha256': 'abc123',
      },
      body: encryptedSample,
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(putRes.status, 200);
  assert.ok(bucket.store.has(`users/${ownerA}/docs/tcc_cert_2026.enc`));

  // Owner B cannot read Owner A's document
  const forbiddenRead = await handleVaultRequest(
    new Request('https://vault.example/docs/tcc_cert_2026', {
      method: 'GET',
      headers: { Authorization: 'Bearer token-b' },
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(forbiddenRead.status, 404);

  // Owner A reads exact bytes back
  const getRes = await handleVaultRequest(
    new Request('https://vault.example/docs/tcc_cert_2026', {
      method: 'GET',
      headers: { Authorization: 'Bearer token-a' },
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(getRes.status, 200);
  const returned = new Uint8Array(await getRes.arrayBuffer());
  assert.deepEqual(returned, encryptedSample);

  // List returns only Owner A's doc metadata
  const listRes = await handleVaultRequest(
    new Request('https://vault.example/docs', {
      method: 'GET',
      headers: { Authorization: 'Bearer token-a' },
    }),
    env,
    {},
    fakeFetch,
  );
  const listed = await listRes.json();
  assert.equal(listed.docs.length, 1);
  assert.equal(listed.docs[0].docId, 'tcc_cert_2026');

  // Delete removes object
  const delRes = await handleVaultRequest(
    new Request('https://vault.example/docs/tcc_cert_2026', {
      method: 'DELETE',
      headers: { Authorization: 'Bearer token-a' },
    }),
    env,
    {},
    fakeFetch,
  );
  assert.equal(delRes.status, 200);
  assert.equal(bucket.store.size, 0);
});
