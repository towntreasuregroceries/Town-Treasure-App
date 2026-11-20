const MAX_DOC_BYTES = 25 * 1024 * 1024; // 25 MiB encrypted payload cap
const MIN_AES_GCM_BYTES = 29; // [12B IV] + [>=1B ciphertext] + [16B auth tag]
const DOC_ID_PATTERN = /^[A-Za-z0-9_-]{4,80}$/;

function corsHeaders(extra = {}) {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-doc-sha256, x-doc-mime',
    'Access-Control-Allow-Methods': 'GET, PUT, DELETE, OPTIONS',
    'Cache-Control': 'no-store',
    ...extra,
  };
}

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders({ 'Content-Type': 'application/json; charset=utf-8' }),
  });
}

function logEvent(level, event, details = {}) {
  console.log(
    JSON.stringify({
      level,
      event,
      ts: new Date().toISOString(),
      ...details,
    }),
  );
}

/**
 * Verifies a Supabase Auth access token against `/auth/v1/user` and returns the
 * verified user id. Rejects missing or invalid tokens cleanly with 401.
 */
async function authenticateSupabaseUser(request, env, fetchImpl = fetch) {
  const authHeader = request.headers.get('Authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  const token = match ? match[1].trim() : '';
  if (!token) {
    return { error: jsonResponse(401, { error: 'Missing Bearer token.' }) };
  }

  const supabaseUrl = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const anonKey = (env.SUPABASE_ANON_KEY || '').trim();
  if (!supabaseUrl || !anonKey) {
    logEvent('error', 'missing_supabase_config');
    return { error: jsonResponse(500, { error: 'Worker Supabase configuration is missing.' }) };
  }

  let authRes;
  try {
    authRes = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: anonKey,
      },
    });
  } catch (err) {
    logEvent('error', 'supabase_auth_unreachable', { message: String(err) });
    return { error: jsonResponse(502, { error: 'Could not reach authentication service.' }) };
  }

  if (!authRes.ok) {
    return { error: jsonResponse(401, { error: 'Session token is expired or invalid.' }) };
  }

  const user = await authRes.json();
  const userId = typeof user?.id === 'string' ? user.id.trim() : '';
  if (!/^[0-9a-fA-F-]{16,64}$/.test(userId)) {
    return { error: jsonResponse(401, { error: 'Invalid authenticated user identity.' }) };
  }

  return { userId };
}

/**
 * Reads up to `maxBytes + 1` from a ReadableStream so oversized payloads fail
 * closed without buffering arbitrary memory into the isolate.
 */
async function readBoundedBytes(stream, maxBytes) {
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel('Payload exceeds 25 MiB limit').catch(() => {});
      return null;
    }
    chunks.push(value);
  }

  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export async function handleVaultRequest(request, env, _ctx, fetchImpl = fetch) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (request.method === 'GET' && path === '/health') {
    return jsonResponse(200, {
      ok: true,
      service: 'ttg-vault-docs',
      hasBucket: Boolean(env.VAULT_DOCS_BUCKET),
    });
  }

  if (!env.VAULT_DOCS_BUCKET) {
    return jsonResponse(500, { error: 'R2 bucket binding VAULT_DOCS_BUCKET is not configured.' });
  }

  const auth = await authenticateSupabaseUser(request, env, fetchImpl);
  if (auth.error) return auth.error;
  const userId = auth.userId;

  // List encrypted document objects for this authenticated user only
  if (request.method === 'GET' && path === '/docs') {
    const prefix = `users/${userId}/docs/`;
    const cursor = url.searchParams.get('cursor') || undefined;
    const listed = await env.VAULT_DOCS_BUCKET.list({
      prefix,
      limit: 500,
      cursor,
    });
    const docs = (listed.objects || []).map(obj => ({
      docId: obj.key.slice(prefix.length).replace(/\.enc$/, ''),
      size: obj.size,
      etag: obj.httpEtag || obj.etag || null,
      uploaded: obj.uploaded instanceof Date ? obj.uploaded.toISOString() : obj.uploaded || null,
    }));
    return jsonResponse(200, {
      ok: true,
      docs,
      truncated: Boolean(listed.truncated),
      cursor: listed.cursor || null,
    });
  }

  // Document-level routes: /docs/:docId
  if (!path.startsWith('/docs/')) {
    return jsonResponse(404, { error: 'Not found.' });
  }

  const docId = decodeURIComponent(path.slice('/docs/'.length));
  if (!DOC_ID_PATTERN.test(docId)) {
    return jsonResponse(400, { error: 'Invalid document identifier.' });
  }

  const objectKey = `users/${userId}/docs/${docId}.enc`;

  if (request.method === 'PUT') {
    const contentLengthHeader = request.headers.get('Content-Length');
    if (contentLengthHeader !== null) {
      const declaredLength = Number(contentLengthHeader);
      if (Number.isFinite(declaredLength) && declaredLength > MAX_DOC_BYTES) {
        return jsonResponse(413, { error: 'Encrypted document exceeds 25 MiB limit.' });
      }
    }

    const bytes = await readBoundedBytes(request.body, MAX_DOC_BYTES);
    if (bytes === null) {
      return jsonResponse(413, { error: 'Encrypted document exceeds 25 MiB limit.' });
    }
    if (bytes.byteLength < MIN_AES_GCM_BYTES) {
      return jsonResponse(400, {
        error: 'Encrypted payload must include AES-GCM IV, ciphertext, and authentication tag.',
      });
    }

    const shaHeader = (request.headers.get('X-Doc-Sha256') || '').trim().slice(0, 64);
    const putResult = await env.VAULT_DOCS_BUCKET.put(objectKey, bytes, {
      httpMetadata: {
        contentType: 'application/octet-stream',
        cacheControl: 'no-store',
      },
      customMetadata: {
        ownerId: userId,
        docId,
        sha256: shaHeader,
        uploadedAt: new Date().toISOString(),
      },
    });

    logEvent('info', 'vault_doc_uploaded', {
      userId,
      docId,
      bytes: bytes.byteLength,
    });

    return jsonResponse(200, {
      ok: true,
      docId,
      key: objectKey,
      bytes: bytes.byteLength,
      etag: putResult?.etag || null,
    });
  }

  if (request.method === 'GET') {
    const object = await env.VAULT_DOCS_BUCKET.get(objectKey);
    if (!object) {
      return jsonResponse(404, { error: 'Encrypted document not found in R2.' });
    }

    return new Response(object.body, {
      status: 200,
      headers: corsHeaders({
        'Content-Type': 'application/octet-stream',
        'X-Doc-Sha256': object.customMetadata?.sha256 || '',
      }),
    });
  }

  if (request.method === 'DELETE') {
    await env.VAULT_DOCS_BUCKET.delete(objectKey);
    logEvent('info', 'vault_doc_deleted', { userId, docId });
    return jsonResponse(200, { ok: true, docId, deleted: true });
  }

  return jsonResponse(405, { error: `Method ${request.method} not allowed.` });
}

export default {
  async fetch(request, env, ctx) {
    return handleVaultRequest(request, env, ctx);
  },
};
