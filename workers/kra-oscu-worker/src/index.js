const SANDBOX_API_BASE = 'https://etims-api-sbx.kra.go.ke/etims-api';
const PROD_API_BASE = 'https://etims-api.kra.go.ke/etims-api';
const DEFAULT_ALLOWED_ORIGIN = 'https://towntreasuregroceries.github.io';
const MAX_OSCU_BODY_BYTES = 2 * 1024 * 1024;

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

function jsonResponse(status, body, request = null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': resolveAllowedOrigin(request),
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Vary': 'Origin',
      'Cache-Control': 'no-store',
    },
  });
}

async function readBoundedJson(request, maxBytes = MAX_OSCU_BODY_BYTES) {
  const declaredLen = Number(request.headers.get('Content-Length') || '0');
  if (Number.isFinite(declaredLen) && declaredLen > maxBytes) {
    return { error: jsonResponse(413, { error: 'Request payload is too large.' }, request) };
  }
  if (!request.body) {
    return { error: jsonResponse(400, { error: 'Missing JSON request body.' }, request) };
  }
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel('Payload exceeds limit').catch(() => {});
      return { error: jsonResponse(413, { error: 'Request payload is too large.' }, request) };
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  try {
    return { data: JSON.parse(new TextDecoder().decode(out)) };
  } catch (_) {
    return { error: jsonResponse(400, { error: 'Invalid JSON request body.' }, request) };
  }
}

async function authenticateSupabaseUser(request, env, fetchImpl = fetch) {
  const auth = request.headers.get('Authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
  const token = match ? match[1].trim() : '';
  if (!token) return { error: jsonResponse(401, { error: 'Missing sign-in session token.' }, request) };

  const url = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const anonKey = (env.SUPABASE_ANON_KEY || '').trim();
  const res = await fetchImpl(`${url}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: anonKey },
  });
  if (!res.ok) return { error: jsonResponse(401, { error: 'Session expired. Please sign in again.' }, request) };
  const user = await res.json();
  if (!user?.id) return { error: jsonResponse(401, { error: 'Invalid user session.' }, request) };

  const allowedIds = (env.ALLOWED_OWNER_IDS || '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);
  const allowedEmails = (env.ALLOWED_OWNER_EMAILS || '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);

  // Fail closed when neither allowlist variable is configured (CRIT-2 fix)
  if (allowedIds.length === 0 && allowedEmails.length === 0) {
    return {
      error: jsonResponse(
        503,
        { error: 'KRA eTIMS owner allowlist is not configured on this server.' },
        request,
      ),
    };
  }

  const userEmail = typeof user.email === 'string' ? user.email.trim().toLowerCase() : '';
  if (
    (allowedIds.length > 0 && !allowedIds.includes(user.id)) ||
    (allowedEmails.length > 0 && !allowedEmails.includes(userEmail))
  ) {
    return {
      error: jsonResponse(403, { error: 'Your account is not authorized to issue KRA eTIMS invoices.' }, request),
    };
  }

  const sandboxOnlyEmails = (env.SANDBOX_ONLY_EMAILS || '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);

  return {
    userId: user.id,
    email: userEmail,
    sandboxOnly: sandboxOnlyEmails.includes(userEmail),
  };
}

function enforceEnvironmentAndTinGuard(request, env, auth, tin, sandbox) {
  if (auth.sandboxOnly && sandbox !== true) {
    return jsonResponse(
      403,
      {
        error:
          'Developer monitoring account can only submit to KRA Sandbox (enable Sandbox mode) so live CEO fiscal sequences remain untouched.',
      },
      request,
    );
  }
  const pinnedTin = (env.ALLOWED_SELLER_TIN || '').trim().toUpperCase();
  if (pinnedTin && !sandbox && tin !== pinnedTin) {
    return jsonResponse(
      403,
      { error: 'Seller KRA PIN does not match the authorized company PIN for live eTIMS.' },
      request,
    );
  }
  return null;
}

async function allocateSequentialInvcNo(env, tin, bhfId) {
  if (!env.DB) return 1;
  const nowIso = new Date().toISOString();
  await env.DB.prepare(
    'INSERT INTO oscu_sequences (tin, bhf_id, next_invc_no, updated_at) VALUES (?, ?, 1, ?) ON CONFLICT(tin, bhf_id) DO NOTHING',
  )
    .bind(tin, bhfId, nowIso)
    .run();

  const row = await env.DB.prepare(
    'UPDATE oscu_sequences SET next_invc_no = next_invc_no + 1, updated_at = ? WHERE tin = ? AND bhf_id = ? RETURNING next_invc_no - 1 AS allocated',
  )
    .bind(nowIso, tin, bhfId)
    .first();

  return Number(row?.allocated ?? 1);
}

export async function handleOscuRequest(request, env, _ctx, fetchImpl = fetch) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: jsonResponse(204, {}, request).headers });
  }
  if (request.method === 'GET' && path === '/health') {
    return jsonResponse(
      200,
      {
        ok: true,
        service: 'ttg-kra-oscu',
        hasCmcKey: Boolean(env.KRA_CMC_KEY),
        hasDb: Boolean(env.DB),
      },
      request,
    );
  }

  const auth = await authenticateSupabaseUser(request, env, fetchImpl);
  if (auth.error) return auth.error;

  const cmcKey = (env.KRA_CMC_KEY || '').trim();
  if (!cmcKey && (path === '/oscu/sales' || path === '/oscu/credit-note' || path === '/oscu/init' || path === '/oscu/items/sync')) {
    return jsonResponse(
      503,
      {
        error:
          'KRA OSCU key (KRA_CMC_KEY) is not added to this server yet. Enter Receipt No. & Receipt Signature manually or add your KRA GavaConnect CMC key.',
      },
      request,
    );
  }

  if (request.method === 'POST' && path === '/oscu/init') {
    const parsed = await readBoundedJson(request);
    if (parsed.error) return parsed.error;
    const body = parsed.data;
    const tin = String(body?.tin || '').trim().toUpperCase();
    const bhfId = String(body?.bhfId || '00').trim() || '00';
    const dvcSrlNo = String(body?.dvcSrlNo || '').trim();
    if (!tin || !dvcSrlNo) {
      return jsonResponse(400, { error: 'Company KRA PIN and OSCU Device Serial are required.' }, request);
    }
    const sandbox = body?.sandbox === true;
    const guardErr = enforceEnvironmentAndTinGuard(request, env, auth, tin, sandbox);
    if (guardErr) return guardErr;

    const base = sandbox ? SANDBOX_API_BASE : PROD_API_BASE;
    const kraRes = await fetchImpl(`${base}/selectInitOsdcInfo`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', tin, bhfId, cmcKey },
      body: JSON.stringify({ tin, bhfId, dvcSrlNo }),
    });
    const kraJson = await kraRes.json();
    if (!kraRes.ok || (kraJson.resultCd && kraJson.resultCd !== '000')) {
      return jsonResponse(
        502,
        {
          error: kraJson.resultMsg || `KRA OSCU init failed (HTTP ${kraRes.status}).`,
          kraResponse: kraJson,
        },
        request,
      );
    }
    return jsonResponse(200, { ok: true, data: kraJson.data || kraJson }, request);
  }

  if (request.method === 'POST' && path === '/oscu/items/sync') {
    const parsed = await readBoundedJson(request);
    if (parsed.error) return parsed.error;
    const body = parsed.data;
    const tin = String(body?.tin || '').trim().toUpperCase();
    const bhfId = String(body?.bhfId || '00').trim() || '00';
    const items = Array.isArray(body?.items) ? body.items : [];
    if (!tin || items.length === 0) {
      return jsonResponse(400, { error: 'Company KRA PIN and category items are required.' }, request);
    }
    const sandbox = body?.sandbox === true;
    const guardErr = enforceEnvironmentAndTinGuard(request, env, auth, tin, sandbox);
    if (guardErr) return guardErr;

    const base = sandbox ? SANDBOX_API_BASE : PROD_API_BASE;
    const synced = [];
    for (const item of items) {
      const itemCd = String(item.itemCd || '').trim();
      const itemClsCd = String(item.itemClsCd || '').trim();
      const itemNm = String(item.itemNm || '').trim();
      const taxTyCd = String(item.taxTyCd || 'A').trim();
      const kraRes = await fetchImpl(`${base}/saveItem`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', tin, bhfId, cmcKey },
        body: JSON.stringify({
          tin,
          bhfId,
          itemCd,
          itemClsCd,
          itemTyCd: '2',
          itemNm,
          orgnNatCd: 'KE',
          pkgUnitCd: 'NT',
          qtyUnitCd: 'KGM',
          taxTyCd,
          dftPrc: 0,
          useYn: 'Y',
          regrId: 'TownTreasureApp',
          regrNm: 'Town Treasure',
          modrId: 'TownTreasureApp',
          modrNm: 'Town Treasure',
        }),
      });
      const kraJson = await kraRes.json();
      if (!kraRes.ok || (kraJson.resultCd && kraJson.resultCd !== '000')) {
        return jsonResponse(
          502,
          {
            error: kraJson.resultMsg || `KRA saveItem failed for ${itemCd}.`,
            kraResponse: kraJson,
          },
          request,
        );
      }
      if (env.DB) {
        await env.DB.prepare(
          `INSERT INTO oscu_items (tin, item_cd, item_cls_cd, item_nm, tax_ty_cd, synced_at)
           VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(tin, item_cd) DO UPDATE SET synced_at = excluded.synced_at`,
        )
          .bind(tin, itemCd, itemClsCd, itemNm, taxTyCd, new Date().toISOString())
          .run();
      }
      synced.push(itemCd);
    }
    return jsonResponse(200, { ok: true, synced }, request);
  }

  if (request.method === 'POST' && (path === '/oscu/sales' || path === '/oscu/credit-note')) {
    const isCreditNote = path === '/oscu/credit-note';
    const parsed = await readBoundedJson(request);
    if (parsed.error) return parsed.error;
    const body = parsed.data;
    const reqPayload = body?.saveTrnsSalesReq;
    if (!reqPayload || !reqPayload.tin || !Array.isArray(reqPayload.itemList)) {
      return jsonResponse(400, { error: 'Invalid OSCU sales invoice payload.' }, request);
    }

    const tin = String(reqPayload.tin).trim().toUpperCase();
    const bhfId = String(reqPayload.bhfId || '00').trim() || '00';
    const sandbox = body?.sandbox === true;
    const guardErr = enforceEnvironmentAndTinGuard(request, env, auth, tin, sandbox);
    if (guardErr) return guardErr;

    let invcNo = Number(reqPayload.invcNo ?? 0);
    if (!Number.isInteger(invcNo) || invcNo <= 0) {
      invcNo = await allocateSequentialInvcNo(env, tin, bhfId);
    }

    const finalPayload = {
      ...reqPayload,
      tin,
      bhfId,
      invcNo,
      rcptTyCd: isCreditNote ? 'R' : (reqPayload.rcptTyCd || 'S'),
      orgInvcNo: isCreditNote ? Number(body?.originalInvcNo || reqPayload.orgInvcNo || 0) : 0,
    };

    if (isCreditNote && (!Number.isInteger(finalPayload.orgInvcNo) || finalPayload.orgInvcNo <= 0)) {
      return jsonResponse(400, { error: 'Credit Note requires originalInvcNo > 0.' }, request);
    }

    const base = sandbox ? SANDBOX_API_BASE : PROD_API_BASE;
    const kraRes = await fetchImpl(`${base}/saveTrnsSalesOsdc`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        tin,
        bhfId,
        cmcKey,
      },
      body: JSON.stringify(finalPayload),
    });

    const kraJson = await kraRes.json();
    if (!kraRes.ok || (kraJson.resultCd && kraJson.resultCd !== '000')) {
      return jsonResponse(
        502,
        {
          error: kraJson.resultMsg || `KRA eTIMS rejected transaction (HTTP ${kraRes.status}).`,
          kraResponse: kraJson,
        },
        request,
      );
    }

    const data = kraJson.data || {};
    const cuSerial = (body?.cuSerial || tin).toString().trim();
    const rcptNo = data.rcptNo ?? invcNo;
    const rcptSign = String(data.rcptSign || '');
    const host = sandbox ? 'https://etims-sbx.kra.go.ke' : 'https://etims.kra.go.ke';
    const qrCodeUrl = rcptSign
      ? `${host}/common/link/etims/receipt/indexEtimsInvoiceData?Data=${tin}${bhfId}${rcptSign}`
      : '';

    return jsonResponse(
      200,
      {
        ok: true,
        invcNo,
        cuInvoiceNumber: `${cuSerial}/${rcptNo}`,
        qrCodeUrl,
        data,
      },
      request,
    );
  }

  return jsonResponse(404, { error: 'Route not found.' }, request);
}

export default {
  async fetch(request, env, ctx) {
    return handleOscuRequest(request, env, ctx);
  },
};
