const MAX_INVITE_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
const IDLE_TIMEOUT_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_VAULT_HISTORY = 100;
const MAX_JSON_BODY_BYTES = 25 * 1024 * 1024; // 25 MiB cap across /clerk, /vault/cas, /staged
const CLERK_HOURLY_SUBMISSION_CAP = 30;
const DEFAULT_ALLOWED_ORIGIN = 'https://towntreasuregroceries.github.io';

function resolveAllowedOrigin(request) {
  const origin = request?.headers?.get('Origin')?.trim() || '';
  if (!origin) return DEFAULT_ALLOWED_ORIGIN;
  if (
    origin === DEFAULT_ALLOWED_ORIGIN ||
    /^http:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?$/i.test(origin)
  ) {
    return origin;
  }
  return DEFAULT_ALLOWED_ORIGIN;
}

function corsHeaders(request = null, extra = {}) {
  return {
    'Access-Control-Allow-Origin': resolveAllowedOrigin(request),
    'Access-Control-Allow-Headers': 'authorization, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Vary': 'Origin',
    'Cache-Control': 'no-store',
    ...extra,
  };
}

function jsonResponse(status, body, request = null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders(request, { 'Content-Type': 'application/json; charset=utf-8' }),
  });
}

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
      await reader.cancel('Payload exceeds limit').catch(() => {});
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

async function readBoundedJson(request, maxBytes = MAX_JSON_BODY_BYTES, tooLargeMsg = 'Request payload is too large.') {
  const declaredLen = Number(request.headers.get('Content-Length') || '0');
  if (Number.isFinite(declaredLen) && declaredLen > maxBytes) {
    return { error: jsonResponse(413, { error: tooLargeMsg }, request) };
  }
  const bytes = await readBoundedBytes(request.body, maxBytes);
  if (bytes === null) {
    return { error: jsonResponse(413, { error: tooLargeMsg }, request) };
  }
  try {
    const text = new TextDecoder().decode(bytes);
    return { data: JSON.parse(text) };
  } catch (_) {
    return { error: jsonResponse(400, { error: 'Invalid JSON request body.' }, request) };
  }
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}

function makeInviteToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function cleanText(value, maxLength, required = false) {
  if (typeof value !== 'string') return required ? null : '';
  const result = value.trim().slice(0, maxLength);
  return required && !result ? null : result;
}

function finiteNonNegative(value, field) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) {
    throw new Error(`${field} must be zero or greater.`);
  }
  return number;
}

async function authenticateSupabaseUser(request, env, fetchImpl = fetch) {
  const auth = request.headers.get('Authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
  const token = match ? match[1].trim() : '';
  if (!token) {
    return { error: jsonResponse(401, { error: 'Missing Bearer session token.' }, request) };
  }

  const supabaseUrl = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const anonKey = (env.SUPABASE_ANON_KEY || '').trim();
  if (!supabaseUrl || !anonKey) {
    return { error: jsonResponse(500, { error: 'Auth configuration missing.' }, request) };
  }

  let res;
  try {
    res = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${token}`, apikey: anonKey },
    });
  } catch (_) {
    return { error: jsonResponse(502, { error: 'Could not verify user session.' }, request) };
  }
  if (!res.ok) {
    return { error: jsonResponse(401, { error: 'Session expired. Please sign in again.' }, request) };
  }
  const user = await res.json();
  const userId = typeof user?.id === 'string' ? user.id.trim() : '';
  if (!userId || !/^[A-Za-z0-9_-]{3,64}$/.test(userId)) {
    return { error: jsonResponse(401, { error: 'Invalid user session.' }, request) };
  }

  const userEmail = typeof user.email === 'string' ? user.email.toLowerCase().trim() : '';
  const allowedIds = (env.ALLOWED_OWNER_IDS || '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);
  const allowedEmails = (env.ALLOWED_OWNER_EMAILS || '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);

  if (
    (allowedIds.length > 0 && !allowedIds.includes(userId)) ||
    (allowedEmails.length > 0 && !allowedEmails.includes(userEmail))
  ) {
    return {
      error: jsonResponse(403, { error: 'This account is not authorized to access Town Treasure owner data.' }, request),
    };
  }

  const fullName = cleanText(
    user.user_metadata?.full_name ?? user.user_metadata?.name ?? '',
    120,
  );
  return {
    userId,
    email: userEmail || null,
    fullName,
  };
}

function normalizeDocketInput(docket) {
  const clerkName = cleanText(docket.clerk_name, 120, true);
  const restaurantName = cleanText(docket.restaurant_name, 180, true);
  const invoiceDate = cleanText(docket.invoice_date, 10, true);
  if (!clerkName || !restaurantName || !invoiceDate || !/^\d{4}-\d{2}-\d{2}$/.test(invoiceDate)) {
    throw new Error('Clerk name, restaurant, and a valid invoice date are required.');
  }
  if (!Array.isArray(docket.items_json) || docket.items_json.length < 1 || docket.items_json.length > 200) {
    throw new Error('A docket must contain between 1 and 200 line items.');
  }

  const items = docket.items_json.map((item, index) => {
    const desc = cleanText(item?.desc ?? item?.name, 180, true);
    if (!desc) throw new Error(`Line item ${index + 1} needs a description.`);
    const qty = Number(item?.qty);
    if (!Number.isFinite(qty) || qty <= 0) {
      throw new Error(`Line item ${index + 1} needs a quantity greater than zero.`);
    }
    const sellPrice = finiteNonNegative(item?.sellPrice ?? item?.price ?? item?.sell, `Line item ${index + 1} price`);
    const buyPrice = finiteNonNegative(item?.buyPrice ?? item?.buy ?? 0, `Line item ${index + 1} cost`);
    return {
      desc,
      qty,
      unit: cleanText(item?.unit, 30) || 'kgs',
      sellPrice,
      buyPrice,
      total: qty * sellPrice,
    };
  });

  const deliveryCost = finiteNonNegative(docket.delivery_cost ?? 0, 'Delivery cost');
  const otherCost = finiteNonNegative(docket.other_cost ?? 0, 'Other cost');
  const itemTotal = items.reduce((sum, item) => sum + item.total, 0);
  const buyTotal = items.reduce((sum, item) => sum + item.qty * item.buyPrice, 0);

  const suppliedPhotos = Array.isArray(docket.receipt_photos) ? docket.receipt_photos : [];
  if (suppliedPhotos.length > 20) {
    throw new Error('A docket can include at most 20 receipt pages.');
  }
  const singlePhoto = typeof docket.receipt_photo === 'string' && docket.receipt_photo.trim()
    ? docket.receipt_photo.trim()
    : null;
  const photos = suppliedPhotos.length ? suppliedPhotos : (singlePhoto ? [singlePhoto] : []);
  const imageDataUrl = /^data:image\/(?:jpe?g|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$/i;
  if (photos.some(v => typeof v !== 'string' || v.length > 12_000_000 || !imageDataUrl.test(v))) {
    throw new Error('Receipt pages must be valid JPEG, PNG, WebP, or GIF image data.');
  }

  return {
    clerk_name: clerkName,
    restaurant_name: restaurantName,
    invoice_date: invoiceDate,
    items,
    delivery_cost: deliveryCost,
    other_cost: otherCost,
    total_sell: itemTotal + deliveryCost + otherCost,
    total_buy: buyTotal,
    photos,
    notes: cleanText(docket.notes ?? '', 4000),
  };
}

function parseStoredPhotoKeys(photoKeysJson) {
  try {
    const parsed = typeof photoKeysJson === 'string' ? JSON.parse(photoKeysJson) : photoKeysJson;
    if (Array.isArray(parsed)) return parsed.filter(k => typeof k === 'string' && k.length > 0);
  } catch (_) {}
  return [];
}

async function deleteOrphanedPhotosFromR2(env, oldPhotoKeysJson, retainedKeys = []) {
  const oldKeys = parseStoredPhotoKeys(oldPhotoKeysJson);
  if (!oldKeys.length) return;
  const keepSet = new Set(retainedKeys);
  for (const key of oldKeys) {
    if (!keepSet.has(key)) {
      await env.STORAGE.delete(key).catch(() => {});
    }
  }
}

async function storePhotosToR2(env, ownerId, docketId, photos) {
  const keys = [];
  for (let i = 0; i < photos.length; i++) {
    const key = `staged/${ownerId}/${docketId}/page-${i}.txt`;
    await env.STORAGE.put(key, photos[i], {
      httpMetadata: { contentType: 'text/plain; charset=utf-8', cacheControl: 'no-store' },
    });
    keys.push(key);
  }
  return keys;
}

async function hydratePhotosFromR2(env, photoKeysJson) {
  const keys = parseStoredPhotoKeys(photoKeysJson);
  const photos = [];
  for (const key of keys) {
    const obj = await env.STORAGE.get(key);
    if (obj) photos.push(await obj.text());
  }
  return photos;
}

function rowToStagedDto(row, hydratedPhotos = null) {
  let items = [];
  try {
    const parsed = typeof row.items_json === 'string' ? JSON.parse(row.items_json) : row.items_json;
    if (Array.isArray(parsed)) items = parsed;
  } catch (_) {}

  const out = {
    id: row.id,
    owner_user_id: row.owner_user_id,
    submitted_by_invite_id: row.submitted_by_invite_id ?? null,
    submission_key: row.submission_key ?? null,
    clerk_name: row.clerk_name,
    restaurant_name: row.restaurant_name,
    invoice_date: row.invoice_date,
    items_json: items,
    delivery_cost: Number(row.delivery_cost ?? 0),
    other_cost: Number(row.other_cost ?? 0),
    total_sell: Number(row.total_sell ?? 0),
    total_buy: Number(row.total_buy ?? 0),
    notes: row.notes ?? '',
    status: row.status,
    rejection_reason: row.rejection_reason ?? '',
    target_user_id: row.target_user_id ?? null,
    target_user_email: row.target_user_email ?? null,
    target_user_name: row.target_user_name ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
  if (hydratedPhotos !== null) {
    out.receipt_photos = hydratedPhotos;
    out.receipt_photo = hydratedPhotos[0] ?? null;
  }
  return out;
}

function sanitizeForClerk(row) {
  const { total_buy: _tb, target_user_email: _te, ...rest } = row;
  if (Array.isArray(rest.items_json)) {
    rest.items_json = rest.items_json.map(item => {
      if (!item || typeof item !== 'object') return item;
      const { buyPrice: _bp, buy: _b, ...pub } = item;
      return pub;
    });
  }
  return rest;
}

async function checkClerkHourlyRateLimit(env, ownerUserId, inviteId, nowMs = Date.now()) {
  const hourBucket = new Date(nowMs).toISOString().slice(0, 13);
  const oneHourAgoIso = new Date(nowMs - 60 * 60 * 1000).toISOString();

  const bucketRow = await env.DB.prepare(
    'SELECT submissions FROM clerk_rate_limits WHERE invite_id = ? AND hour_bucket = ?',
  )
    .bind(inviteId, hourBucket)
    .first();
  const bucketCount = Number(bucketRow?.submissions ?? 0);
  if (bucketCount >= CLERK_HOURLY_SUBMISSION_CAP) {
    return { allowed: false, hourBucket };
  }

  const liveCountRow = await env.DB.prepare(
    'SELECT COUNT(*) AS cnt FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND updated_at >= ?',
  )
    .bind(ownerUserId, inviteId, oneHourAgoIso)
    .first();
  if (Number(liveCountRow?.cnt ?? 0) >= CLERK_HOURLY_SUBMISSION_CAP) {
    return { allowed: false, hourBucket };
  }

  return { allowed: true, hourBucket };
}

async function recordClerkSubmissionRateCount(env, inviteId, hourBucket, nowMs = Date.now()) {
  const nowIso = new Date(nowMs).toISOString();
  const cutoffBucket = new Date(nowMs - 24 * 60 * 60 * 1000).toISOString().slice(0, 13);
  await env.DB.prepare(
    `INSERT INTO clerk_rate_limits (invite_id, hour_bucket, submissions, updated_at)
     VALUES (?, ?, 1, ?)
     ON CONFLICT(invite_id, hour_bucket) DO UPDATE SET
       submissions = submissions + 1,
       updated_at = excluded.updated_at`,
  )
    .bind(inviteId, hourBucket, nowIso)
    .run();
  await env.DB.prepare('DELETE FROM clerk_rate_limits WHERE hour_bucket < ?')
    .bind(cutoffBucket)
    .run()
    .catch(() => {});
}

async function resolveClerkInvite(env, token) {
  if (typeof token !== 'string' || token.length < 40 || token.length > 100) {
    return {
      ok: false,
      error: 'This clerk link is invalid or expired. Ask the account owner for a new link.',
    };
  }
  const tokenHash = await sha256Hex(token);
  const invite = await env.DB.prepare(
    'SELECT id, owner_user_id, owner_email, owner_name, expires_at, revoked_at FROM clerk_invites WHERE token_hash = ?',
  )
    .bind(tokenHash)
    .first();

  if (!invite || invite.revoked_at) {
    return {
      ok: false,
      error: 'This clerk link is invalid or has been revoked. Ask the account owner for a new link.',
    };
  }

  const nowMs = Date.now();
  const expiresMs = Date.parse(invite.expires_at);
  if (!Number.isFinite(expiresMs) || expiresMs <= nowMs) {
    return {
      ok: false,
      error: 'This 30-day clerk token has expired. Ask the account owner for a new link.',
    };
  }

  const issuedAtMs = expiresMs - MAX_INVITE_LIFETIME_MS;
  let lastActivityMs = issuedAtMs;
  const recent = await env.DB.prepare(
    'SELECT updated_at, created_at FROM staged_invoices WHERE submitted_by_invite_id = ? ORDER BY updated_at DESC LIMIT 25',
  )
    .bind(invite.id)
    .all();

  for (const row of recent.results || []) {
    const subMs = Date.parse(String(row.updated_at || row.created_at || ''));
    if (Number.isFinite(subMs) && subMs > lastActivityMs) {
      lastActivityMs = subMs;
    }
  }

  const idleExpiresMs = lastActivityMs + IDLE_TIMEOUT_MS;
  if (idleExpiresMs <= nowMs) {
    return {
      ok: false,
      error: 'This clerk token expired after 7 days of inactivity. Ask the account owner for a new link.',
    };
  }

  const effectiveExpiresMs = Math.min(expiresMs, idleExpiresMs);
  return {
    ok: true,
    invite: {
      ...invite,
      last_activity_at: new Date(lastActivityMs).toISOString(),
      idle_expires_at: new Date(idleExpiresMs).toISOString(),
      effective_expires_at: new Date(effectiveExpiresMs).toISOString(),
    },
  };
}

async function handleVaultCas(request, env, userId, expectedRevision, data) {
  if (!Number.isInteger(expectedRevision) || expectedRevision < 0 || typeof data !== 'string' || !data) {
    return jsonResponse(400, { error: 'Invalid vault revision or encrypted payload.' }, request);
  }

  const nowIso = new Date().toISOString();
  const dataHash = await sha256Hex(data);
  const current = await env.DB.prepare(
    'SELECT revision, r2_key, created_at FROM (SELECT revision, r2_key, updated_at AS created_at FROM vault_meta WHERE user_id = ?)',
  )
    .bind(userId)
    .first();

  if (!current) {
    // Fail closed if the live row disappeared while retained history still exists.
    const hist = await env.DB.prepare(
      'SELECT MAX(revision) AS max_rev FROM vault_history WHERE user_id = ?',
    )
      .bind(userId)
      .first();
    if (hist && hist.max_rev !== null && hist.max_rev !== undefined) {
      return jsonResponse(200, { saved: false, revision: Number(hist.max_rev) }, request);
    }
    if (expectedRevision !== 0) {
      return jsonResponse(200, { saved: false, revision: 0 }, request);
    }

    const r2Key = `vault/${userId}/rev-1.enc`;
    await env.STORAGE.put(r2Key, data, {
      httpMetadata: { contentType: 'text/plain; charset=utf-8', cacheControl: 'no-store' },
      customMetadata: { userId, revision: '1', sha256: dataHash },
    });
    const ins = await env.DB.prepare(
      'INSERT INTO vault_meta (user_id, revision, r2_key, sha256, updated_at) VALUES (?, 1, ?, ?, ?) ON CONFLICT(user_id) DO NOTHING',
    )
      .bind(userId, r2Key, dataHash, nowIso)
      .run();

    if ((ins.meta?.changes ?? 0) === 1) {
      return jsonResponse(200, { saved: true, revision: 1 }, request);
    }
    await env.STORAGE.delete(r2Key).catch(() => {});
    const winner = await env.DB.prepare('SELECT revision FROM vault_meta WHERE user_id = ?')
      .bind(userId)
      .first();
    return jsonResponse(200, { saved: false, revision: Number(winner?.revision ?? 0) }, request);
  }

  const currentRev = Number(current.revision);
  if (currentRev !== expectedRevision) {
    return jsonResponse(200, { saved: false, revision: currentRev }, request);
  }

  const nextRev = currentRev + 1;
  const nextKey = `vault/${userId}/rev-${nextRev}.enc`;
  await env.STORAGE.put(nextKey, data, {
    httpMetadata: { contentType: 'text/plain; charset=utf-8', cacheControl: 'no-store' },
    customMetadata: { userId, revision: String(nextRev), sha256: dataHash },
  });

  const upd = await env.DB.prepare(
    'UPDATE vault_meta SET revision = ?, r2_key = ?, sha256 = ?, updated_at = ? WHERE user_id = ? AND revision = ?',
  )
    .bind(nextRev, nextKey, dataHash, nowIso, userId, currentRev)
    .run();

  if ((upd.meta?.changes ?? 0) !== 1) {
    await env.STORAGE.delete(nextKey).catch(() => {});
    const winner = await env.DB.prepare('SELECT revision FROM vault_meta WHERE user_id = ?')
      .bind(userId)
      .first();
    return jsonResponse(200, { saved: false, revision: Number(winner?.revision ?? currentRev) }, request);
  }

  await env.DB.prepare(
    'INSERT INTO vault_history (user_id, revision, r2_key, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, revision) DO NOTHING',
  )
    .bind(userId, currentRev, current.r2_key, nowIso)
    .run();

  // Prune history beyond latest 100 snapshots
  const oldRows = await env.DB.prepare(
    'SELECT revision, r2_key FROM vault_history WHERE user_id = ? ORDER BY revision DESC LIMIT -1 OFFSET ?',
  )
    .bind(userId, MAX_VAULT_HISTORY)
    .all();

  for (const old of oldRows.results || []) {
    await env.DB.prepare('DELETE FROM vault_history WHERE user_id = ? AND revision = ?')
      .bind(userId, old.revision)
      .run();
    if (old.r2_key && old.r2_key !== nextKey) {
      await env.STORAGE.delete(old.r2_key).catch(() => {});
    }
  }

  return jsonResponse(200, { saved: true, revision: nextRev }, request);
}

export async function handleApiRequest(request, env, _ctx, fetchImpl = fetch) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(request) });
  }

  if (request.method === 'GET' && path === '/health') {
    return jsonResponse(
      200,
      {
        ok: true,
        service: 'ttg-api',
        hasDb: Boolean(env.DB),
        hasStorage: Boolean(env.STORAGE),
      },
      request,
    );
  }

  if (!env.DB || !env.STORAGE) {
    return jsonResponse(500, { error: 'Cloudflare D1/R2 bindings are missing.' }, request);
  }

  if (path === '/admin/seed') {
    return jsonResponse(404, { error: 'Not found.' }, request);
  }

  // --- Clerk API (unauthenticated invite-token routes + authenticated create_invite) ---
  if (request.method === 'POST' && path === '/clerk') {
    const parsed = await readBoundedJson(request, MAX_JSON_BODY_BYTES, 'Docket upload is too large.');
    if (parsed.error) return parsed.error;
    const body = parsed.data;
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return jsonResponse(400, { error: 'Clerk request body must be a JSON object.' }, request);
    }

    try {
      if (body.action === 'create_invite') {
        const auth = await authenticateSupabaseUser(request, env, fetchImpl);
        if (auth.error) return auth.error;
        const token = makeInviteToken();
        const tokenHash = await sha256Hex(token);
        const ownerName = auth.fullName || cleanText(auth.email?.split('@')[0] ?? '', 120) || 'Account owner';
        const nowMs = Date.now();
        const nowIso = new Date(nowMs).toISOString();
        const expiresAt = new Date(nowMs + MAX_INVITE_LIFETIME_MS).toISOString();
        const idleExpiresAt = new Date(nowMs + IDLE_TIMEOUT_MS).toISOString();
        const inviteId = `inv_${crypto.randomUUID()}`;

        await env.DB.prepare(
          'INSERT INTO clerk_invites (id, owner_user_id, token_hash, owner_email, owner_name, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        )
          .bind(inviteId, auth.userId, tokenHash, auth.email, ownerName, expiresAt, nowIso)
          .run();

        await env.DB.prepare(
          'UPDATE clerk_invites SET revoked_at = ? WHERE owner_user_id = ? AND revoked_at IS NULL AND id != ?',
        )
          .bind(nowIso, auth.userId, inviteId)
          .run();

        return jsonResponse(
          200,
          {
            token,
            invite: {
              id: inviteId,
              owner_user_id: auth.userId,
              owner_email: auth.email,
              owner_name: ownerName,
              expires_at: expiresAt,
              last_activity_at: nowIso,
              idle_expires_at: idleExpiresAt,
              effective_expires_at: idleExpiresAt,
              max_lifetime_days: 30,
              idle_timeout_days: 7,
            },
          },
          request,
        );
      }

      const resolution = await resolveClerkInvite(env, body.invite_token);
      if (!resolution.ok) {
        return jsonResponse(401, { error: resolution.error }, request);
      }
      const invite = resolution.invite;

      if (body.action === 'list') {
        let rowsRes;
        if (body.submission_id !== undefined) {
          const id = cleanText(body.submission_id, 160, true);
          if (!id) return jsonResponse(400, { error: 'A valid docket ID is required.' }, request);
          rowsRes = await env.DB.prepare(
            'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND id = ? ORDER BY created_at DESC LIMIT 100',
          )
            .bind(invite.owner_user_id, invite.id, id)
            .all();
        } else {
          rowsRes = await env.DB.prepare(
            'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? ORDER BY created_at DESC LIMIT 100',
          )
            .bind(invite.owner_user_id, invite.id)
            .all();
        }

        const includePhotos = body.include_photos !== false;
        const submissions = [];
        for (const row of rowsRes.results || []) {
          const photos = includePhotos ? await hydratePhotosFromR2(env, row.photo_keys_json) : null;
          submissions.push(sanitizeForClerk(rowToStagedDto(row, photos)));
        }
        return jsonResponse(
          200,
          {
            // Expose display name only; never expose owner's private login email to clerk links.
            owner: { name: invite.owner_name },
            invite: {
              expires_at: invite.expires_at,
              last_activity_at: invite.last_activity_at,
              idle_expires_at: invite.idle_expires_at,
              effective_expires_at: invite.effective_expires_at,
              max_lifetime_days: 30,
              idle_timeout_days: 7,
            },
            submissions,
          },
          request,
        );
      }

      if (body.action === 'delete') {
        const id = cleanText(body.id, 160, true);
        if (!id) return jsonResponse(400, { error: 'Docket ID is required.' }, request);
        const existing = await env.DB.prepare(
          "SELECT id, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND submitted_by_invite_id = ? AND status IN ('pending', 'rejected')",
        )
          .bind(id, invite.owner_user_id, invite.id)
          .first();
        if (!existing) {
          return jsonResponse(409, { error: 'Only a pending or returned docket from this invite can be deleted.' }, request);
        }
        await env.DB.prepare('DELETE FROM staged_invoices WHERE id = ?').bind(id).run();
        await deleteOrphanedPhotosFromR2(env, existing.photo_keys_json, []);
        return jsonResponse(200, { deleted: true }, request);
      }

      if (body.action !== 'submit') {
        return jsonResponse(400, { error: 'Unsupported clerk action.' }, request);
      }
      if (!body.docket || typeof body.docket !== 'object' || Array.isArray(body.docket)) {
        return jsonResponse(400, { error: 'Docket data is required.' }, request);
      }
      const submissionKey = cleanText(body.submission_key, 80, true);
      if (!submissionKey || !/^[A-Za-z0-9_-]{16,80}$/.test(submissionKey)) {
        return jsonResponse(400, { error: 'A valid submission retry key is required.' }, request);
      }

      const fields = normalizeDocketInput(body.docket);

      // Idempotent replay lookup
      const prior = await env.DB.prepare(
        'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND submission_key = ?',
      )
        .bind(invite.owner_user_id, invite.id, submissionKey)
        .first();
      if (prior) {
        const photos = await hydratePhotosFromR2(env, prior.photo_keys_json);
        return jsonResponse(
          200,
          {
            submission: sanitizeForClerk(rowToStagedDto(prior, photos)),
            replayed: true,
          },
          request,
        );
      }

      // Persistent per-invite hourly burst limit (30/hr, immune to submit+delete loops)
      const nowMs = Date.now();
      const rateCheck = await checkClerkHourlyRateLimit(env, invite.owner_user_id, invite.id, nowMs);
      if (!rateCheck.allowed) {
        return jsonResponse(
          429,
          {
            error: 'Hourly submission limit reached for this clerk link. Try again later.',
          },
          request,
        );
      }

      const nowIso = new Date(nowMs).toISOString();
      const requestedId = cleanText(body.docket.id, 160);
      if (requestedId) {
        const returned = await env.DB.prepare(
          'SELECT id, status, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND submitted_by_invite_id = ?',
        )
          .bind(requestedId, invite.owner_user_id, invite.id)
          .first();
        if (!returned || returned.status !== 'rejected') {
          return jsonResponse(
            409,
            {
              error: 'Only a returned docket from this invite can be corrected.',
            },
            request,
          );
        }
        const photoKeys = await storePhotosToR2(env, invite.owner_user_id, requestedId, fields.photos);
        const upd = await env.DB.prepare(
          `UPDATE staged_invoices SET
             submission_key = ?, clerk_name = ?, restaurant_name = ?, invoice_date = ?,
             items_json = ?, delivery_cost = ?, other_cost = ?, total_sell = ?, total_buy = ?,
             photo_keys_json = ?, notes = ?, status = 'pending', rejection_reason = '',
             updated_at = ?
           WHERE id = ? AND owner_user_id = ? AND submitted_by_invite_id = ? AND status = 'rejected'`,
        )
          .bind(
            submissionKey,
            fields.clerk_name,
            fields.restaurant_name,
            fields.invoice_date,
            JSON.stringify(fields.items),
            fields.delivery_cost,
            fields.other_cost,
            fields.total_sell,
            fields.total_buy,
            JSON.stringify(photoKeys),
            fields.notes,
            nowIso,
            requestedId,
            invite.owner_user_id,
            invite.id,
          )
          .run();
        if ((upd.meta?.changes ?? 0) !== 1) {
          return jsonResponse(
            409,
            {
              error: 'This docket has already changed. Refresh the clerk history and try again.',
            },
            request,
          );
        }
        await deleteOrphanedPhotosFromR2(env, returned.photo_keys_json, photoKeys);
        await recordClerkSubmissionRateCount(env, invite.id, rateCheck.hourBucket, nowMs);
        const updatedRow = await env.DB.prepare('SELECT * FROM staged_invoices WHERE id = ?')
          .bind(requestedId)
          .first();
        return jsonResponse(
          200,
          {
            submission: sanitizeForClerk(rowToStagedDto(updatedRow, fields.photos)),
            replayed: false,
          },
          request,
        );
      }

      const newId = `stg_${crypto.randomUUID()}`;
      const photoKeys = await storePhotosToR2(env, invite.owner_user_id, newId, fields.photos);
      try {
        await env.DB.prepare(
          `INSERT INTO staged_invoices (
             id, owner_user_id, submitted_by_invite_id, submission_key, clerk_name,
             restaurant_name, invoice_date, items_json, delivery_cost, other_cost,
             total_sell, total_buy, photo_keys_json, notes, status, rejection_reason,
             target_user_id, target_user_email, target_user_name, created_at, updated_at
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?, ?, ?, ?, ?)`,
        )
          .bind(
            newId,
            invite.owner_user_id,
            invite.id,
            submissionKey,
            fields.clerk_name,
            fields.restaurant_name,
            fields.invoice_date,
            JSON.stringify(fields.items),
            fields.delivery_cost,
            fields.other_cost,
            fields.total_sell,
            fields.total_buy,
            JSON.stringify(photoKeys),
            fields.notes,
            invite.owner_user_id,
            invite.owner_email ?? null,
            invite.owner_name ?? null,
            nowIso,
            nowIso,
          )
          .run();
      } catch (err) {
        const replay = await env.DB.prepare(
          'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND submitted_by_invite_id = ? AND submission_key = ?',
        )
          .bind(invite.owner_user_id, invite.id, submissionKey)
          .first();
        if (replay) {
          await deleteOrphanedPhotosFromR2(env, JSON.stringify(photoKeys), []);
          const photos = await hydratePhotosFromR2(env, replay.photo_keys_json);
          return jsonResponse(
            200,
            {
              submission: sanitizeForClerk(rowToStagedDto(replay, photos)),
              replayed: true,
            },
            request,
          );
        }
        throw err;
      }

      await recordClerkSubmissionRateCount(env, invite.id, rateCheck.hourBucket, nowMs);
      const createdRow = await env.DB.prepare('SELECT * FROM staged_invoices WHERE id = ?')
        .bind(newId)
        .first();
      return jsonResponse(
        200,
        {
          submission: sanitizeForClerk(rowToStagedDto(createdRow, fields.photos)),
          replayed: false,
        },
        request,
      );
    } catch (error) {
      return jsonResponse(
        400,
        {
          error: error instanceof Error ? error.message : 'Clerk request failed.',
        },
        request,
      );
    }
  }

  // --- All remaining routes require an authenticated Supabase owner JWT ---
  const auth = await authenticateSupabaseUser(request, env, fetchImpl);
  if (auth.error) return auth.error;
  const userId = auth.userId;

  // Vault endpoints
  if (request.method === 'GET' && path === '/vault/revision') {
    const meta = await env.DB.prepare('SELECT revision FROM vault_meta WHERE user_id = ?')
      .bind(userId)
      .first();
    if (!meta) return jsonResponse(200, { exists: false, revision: null }, request);
    return jsonResponse(200, { exists: true, revision: Number(meta.revision) }, request);
  }

  if (request.method === 'GET' && path === '/vault') {
    const meta = await env.DB.prepare('SELECT revision, r2_key FROM vault_meta WHERE user_id = ?')
      .bind(userId)
      .first();
    if (!meta) return jsonResponse(200, { exists: false, revision: 0, data: null }, request);
    const obj = await env.STORAGE.get(meta.r2_key);
    const data = obj ? await obj.text() : null;
    return jsonResponse(
      200,
      {
        exists: true,
        revision: Number(meta.revision),
        data,
      },
      request,
    );
  }

  if (request.method === 'POST' && path === '/vault/cas') {
    const parsed = await readBoundedJson(request, MAX_JSON_BODY_BYTES, 'Encrypted vault snapshot exceeds 25 MiB limit.');
    if (parsed.error) return parsed.error;
    const body = parsed.data;
    const expectedRevision = Number(body?.expectedRevision);
    const data = body?.data;
    return handleVaultCas(request, env, userId, expectedRevision, data);
  }

  // Owner Staged Invoices endpoints
  if (request.method === 'GET' && path === '/staged') {
    const rows = await env.DB.prepare(
      `SELECT id, owner_user_id, submitted_by_invite_id, submission_key, clerk_name,
              restaurant_name, invoice_date, items_json, delivery_cost, other_cost,
              total_sell, total_buy, notes, status, rejection_reason,
              target_user_id, target_user_email, target_user_name, created_at, updated_at
       FROM staged_invoices WHERE owner_user_id = ? ORDER BY created_at DESC`,
    )
      .bind(userId)
      .all();
    return jsonResponse(
      200,
      {
        rows: (rows.results || []).map(r => rowToStagedDto(r, null)),
      },
      request,
    );
  }

  if (request.method === 'GET' && path === '/staged/pending') {
    const rows = await env.DB.prepare(
      "SELECT id, owner_user_id, target_user_id, target_user_email, notes, status FROM staged_invoices WHERE owner_user_id = ? AND status = 'pending'",
    )
      .bind(userId)
      .all();
    return jsonResponse(200, { rows: rows.results || [] }, request);
  }

  if (path.startsWith('/staged/')) {
    const rest = path.slice('/staged/'.length);
    const parts = rest.split('/').filter(Boolean);
    const stagedId = decodeURIComponent(parts[0] || '');
    const subAction = parts[1] || '';

    if (!stagedId || stagedId.length > 160) {
      return jsonResponse(400, { error: 'Invalid docket ID.' }, request);
    }

    if (request.method === 'GET' && !subAction) {
      const row = await env.DB.prepare(
        'SELECT * FROM staged_invoices WHERE owner_user_id = ? AND id = ?',
      )
        .bind(userId, stagedId)
        .first();
      if (!row) return jsonResponse(200, { row: null }, request);
      const photos = await hydratePhotosFromR2(env, row.photo_keys_json);
      return jsonResponse(200, { row: rowToStagedDto(row, photos) }, request);
    }

    if (request.method === 'PUT' && !subAction) {
      const parsed = await readBoundedJson(request, MAX_JSON_BODY_BYTES, 'Staged docket payload exceeds 25 MiB limit.');
      if (parsed.error) return parsed.error;
      const rec = parsed.data || {};
      const nowIso = new Date().toISOString();

      // Strict tenant isolation guard before writing R2 or D1 (CRIT-1 fix)
      const existing = await env.DB.prepare(
        'SELECT owner_user_id, photo_keys_json, created_at FROM staged_invoices WHERE id = ?',
      )
        .bind(stagedId)
        .first();
      if (existing && existing.owner_user_id !== userId) {
        return jsonResponse(403, { error: 'Forbidden: docket belongs to another account.' }, request);
      }

      const rawPhotos = Array.isArray(rec.receipt_photos) ? rec.receipt_photos : [];
      const photos = rawPhotos.length
        ? rawPhotos.filter(p => typeof p === 'string' && p.length > 0)
        : (typeof rec.receipt_photo === 'string' && rec.receipt_photo.length > 0
            ? [rec.receipt_photo]
            : []);
      const photoKeys = photos.length
        ? await storePhotosToR2(env, userId, stagedId, photos)
        : parseStoredPhotoKeys(existing?.photo_keys_json);
      const itemsJson = typeof rec.items_json === 'string'
        ? rec.items_json
        : JSON.stringify(Array.isArray(rec.items_json) ? rec.items_json : []);

      const upsertRes = await env.DB.prepare(
        `INSERT INTO staged_invoices (
           id, owner_user_id, submitted_by_invite_id, submission_key, clerk_name,
           restaurant_name, invoice_date, items_json, delivery_cost, other_cost,
           total_sell, total_buy, photo_keys_json, notes, status, rejection_reason,
           target_user_id, target_user_email, target_user_name, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           clerk_name = excluded.clerk_name,
           restaurant_name = excluded.restaurant_name,
           invoice_date = excluded.invoice_date,
           items_json = excluded.items_json,
           delivery_cost = excluded.delivery_cost,
           other_cost = excluded.other_cost,
           total_sell = excluded.total_sell,
           total_buy = excluded.total_buy,
           photo_keys_json = excluded.photo_keys_json,
           notes = excluded.notes,
           status = excluded.status,
           rejection_reason = excluded.rejection_reason,
           updated_at = excluded.updated_at
         WHERE staged_invoices.owner_user_id = excluded.owner_user_id`,
      )
        .bind(
          stagedId,
          userId,
          rec.submitted_by_invite_id ?? null,
          rec.submission_key ?? null,
          String(rec.clerk_name ?? 'Clerk'),
          String(rec.restaurant_name ?? 'General Wholesale'),
          String(rec.invoice_date ?? '').slice(0, 10),
          itemsJson,
          Number(rec.delivery_cost ?? 0),
          Number(rec.other_cost ?? 0),
          Number(rec.total_sell ?? 0),
          Number(rec.total_buy ?? 0),
          JSON.stringify(photoKeys),
          String(rec.notes ?? ''),
          String(rec.status ?? 'pending'),
          String(rec.rejection_reason ?? ''),
          rec.target_user_id ?? userId,
          rec.target_user_email ?? auth.email,
          rec.target_user_name ?? null,
          rec.created_at ?? existing?.created_at ?? nowIso,
          rec.updated_at ?? nowIso,
        )
        .run();

      if ((upsertRes.meta?.changes ?? 0) === 0) {
        if (photos.length) {
          await deleteOrphanedPhotosFromR2(env, JSON.stringify(photoKeys), []);
        }
        return jsonResponse(403, { error: 'Forbidden: docket belongs to another account.' }, request);
      }
      if (photos.length && existing?.photo_keys_json) {
        await deleteOrphanedPhotosFromR2(env, existing.photo_keys_json, photoKeys);
      }
      return jsonResponse(200, { ok: true, id: stagedId }, request);
    }

    if (request.method === 'PATCH' && subAction === 'status') {
      const parsed = await readBoundedJson(request, 2 * 1024 * 1024);
      if (parsed.error) return parsed.error;
      const payload = parsed.data || {};
      const nowIso = new Date().toISOString();
      const sets = ['status = ?', 'updated_at = ?'];
      const vals = [String(payload.status || 'approved'), String(payload.updated_at || nowIso)];
      if (payload.rejection_reason !== undefined) {
        sets.push('rejection_reason = ?');
        vals.push(String(payload.rejection_reason ?? ''));
      }
      if (payload.items_json !== undefined) {
        sets.push('items_json = ?');
        vals.push(
          typeof payload.items_json === 'string'
            ? payload.items_json
            : JSON.stringify(payload.items_json),
        );
      }
      if (payload.total_buy !== undefined) {
        sets.push('total_buy = ?');
        vals.push(Number(payload.total_buy ?? 0));
      }
      if (payload.total_sell !== undefined) {
        sets.push('total_sell = ?');
        vals.push(Number(payload.total_sell ?? 0));
      }
      vals.push(stagedId, userId);

      const res = await env.DB.prepare(
        `UPDATE staged_invoices SET ${sets.join(', ')} WHERE id = ? AND owner_user_id = ?`,
      )
        .bind(...vals)
        .run();
      return jsonResponse(200, { updated: (res.meta?.changes ?? 0) > 0 }, request);
    }

    if (request.method === 'POST' && subAction === 'reject') {
      const parsed = await readBoundedJson(request, 512 * 1024);
      if (parsed.error) return parsed.error;
      const payload = parsed.data || {};
      const reason = String(payload?.reason ?? '');
      const res = await env.DB.prepare(
        "UPDATE staged_invoices SET status = 'rejected', rejection_reason = ?, updated_at = ? WHERE id = ? AND owner_user_id = ? AND status = 'pending'",
      )
        .bind(reason, new Date().toISOString(), stagedId, userId)
        .run();
      return jsonResponse(200, { updated: (res.meta?.changes ?? 0) > 0 }, request);
    }

    if (request.method === 'DELETE' && !subAction) {
      const existing = await env.DB.prepare(
        "SELECT id, photo_keys_json FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND status != 'approved'",
      )
        .bind(stagedId, userId)
        .first();
      if (!existing) {
        return jsonResponse(200, { deleted: false }, request);
      }
      const res = await env.DB.prepare(
        "DELETE FROM staged_invoices WHERE id = ? AND owner_user_id = ? AND status != 'approved'",
      )
        .bind(stagedId, userId)
        .run();
      if ((res.meta?.changes ?? 0) > 0) {
        await deleteOrphanedPhotosFromR2(env, existing.photo_keys_json, []);
      }
      return jsonResponse(200, { deleted: (res.meta?.changes ?? 0) > 0 }, request);
    }
  }

  return jsonResponse(404, { error: 'Route not found.' }, request);
}

export default {
  async fetch(request, env, ctx) {
    return handleApiRequest(request, env, ctx);
  },
};
