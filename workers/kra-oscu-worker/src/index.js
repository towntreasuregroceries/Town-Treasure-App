const SANDBOX_API_BASE = 'https://etims-api-sbx.kra.go.ke/etims-api';
const PROD_API_BASE = 'https://etims-api.kra.go.ke/etims-api';

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Cache-Control': 'no-store',
    },
  });
}

async function authenticateSupabaseUser(request, env, fetchImpl = fetch) {
  const auth = request.headers.get('Authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
  const token = match ? match[1].trim() : '';
  if (!token) return { error: jsonResponse(401, { error: 'Missing sign-in session token.' }) };

  const url = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const anonKey = (env.SUPABASE_ANON_KEY || '').trim();
  const res = await fetchImpl(`${url}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: anonKey },
  });
  if (!res.ok) return { error: jsonResponse(401, { error: 'Session expired. Please sign in again.' }) };
  const user = await res.json();
  if (!user?.id) return { error: jsonResponse(401, { error: 'Invalid user session.' }) };

  const allowedIds = (env.ALLOWED_OWNER_IDS || '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);
  const allowedEmails = (env.ALLOWED_OWNER_EMAILS || '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);
  const userEmail = typeof user.email === 'string' ? user.email.trim().toLowerCase() : '';
  if (
    (allowedIds.length > 0 && !allowedIds.includes(user.id)) ||
    (allowedEmails.length > 0 && !allowedEmails.includes(userEmail))
  ) {
    return { error: jsonResponse(403, { error: 'Your account is not authorized to issue KRA eTIMS invoices.' }) };
  }

  return { userId: user.id, email: userEmail };
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
    return jsonResponse(204, {});
  }
  if (request.method === 'GET' && path === '/health') {
    return jsonResponse(200, {
      ok: true,
      service: 'ttg-kra-oscu',
      hasCmcKey: Boolean(env.KRA_CMC_KEY),
      hasDb: Boolean(env.DB),
    });
  }

  const auth = await authenticateSupabaseUser(request, env, fetchImpl);
  if (auth.error) return auth.error;

  const cmcKey = (env.KRA_CMC_KEY || '').trim();
  if (!cmcKey && (path === '/oscu/sales' || path === '/oscu/credit-note' || path === '/oscu/init' || path === '/oscu/items/sync')) {
    return jsonResponse(503, {
      error:
        'KRA OSCU key (KRA_CMC_KEY) is not added to this server yet. Enter Receipt No. & Receipt Signature manually or add your KRA GavaConnect CMC key.',
    });
  }

  if (request.method === 'POST' && path === '/oscu/init') {
    const body = await request.json();
    const tin = String(body?.tin || '').trim().toUpperCase();
    const bhfId = String(body?.bhfId || '00').trim() || '00';
    const dvcSrlNo = String(body?.dvcSrlNo || '').trim();
    if (!tin || !dvcSrlNo) {
      return jsonResponse(400, { error: 'Company KRA PIN and OSCU Device Serial are required.' });
    }
    const base = body?.sandbox === true ? SANDBOX_API_BASE : PROD_API_BASE;
    const kraRes = await fetchImpl(`${base}/selectInitOsdcInfo`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', tin, bhfId, cmcKey },
      body: JSON.stringify({ tin, bhfId, dvcSrlNo }),
    });
    const kraJson = await kraRes.json();
    if (!kraRes.ok || (kraJson.resultCd && kraJson.resultCd !== '000')) {
      return jsonResponse(502, {
        error: kraJson.resultMsg || `KRA OSCU init failed (HTTP ${kraRes.status}).`,
        kraResponse: kraJson,
      });
    }
    return jsonResponse(200, { ok: true, data: kraJson.data || kraJson });
  }

  if (request.method === 'POST' && path === '/oscu/items/sync') {
    const body = await request.json();
    const tin = String(body?.tin || '').trim().toUpperCase();
    const bhfId = String(body?.bhfId || '00').trim() || '00';
    const items = Array.isArray(body?.items) ? body.items : [];
    if (!tin || items.length === 0) {
      return jsonResponse(400, { error: 'Company KRA PIN and category items are required.' });
    }
    const base = body?.sandbox === true ? SANDBOX_API_BASE : PROD_API_BASE;
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
        return jsonResponse(502, {
          error: kraJson.resultMsg || `KRA saveItem failed for ${itemCd}.`,
          kraResponse: kraJson,
        });
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
    return jsonResponse(200, { ok: true, synced });
  }

  if (request.method === 'POST' && (path === '/oscu/sales' || path === '/oscu/credit-note')) {
    const isCreditNote = path === '/oscu/credit-note';
    const body = await request.json();
    const reqPayload = body?.saveTrnsSalesReq;
    if (!reqPayload || !reqPayload.tin || !Array.isArray(reqPayload.itemList)) {
      return jsonResponse(400, { error: 'Invalid OSCU sales invoice payload.' });
    }

    const tin = String(reqPayload.tin).trim().toUpperCase();
    const bhfId = String(reqPayload.bhfId || '00').trim() || '00';
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
      return jsonResponse(400, { error: 'Credit Note requires originalInvcNo > 0.' });
    }

    const sandbox = body?.sandbox === true;
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
      return jsonResponse(502, {
        error: kraJson.resultMsg || `KRA eTIMS rejected transaction (HTTP ${kraRes.status}).`,
        kraResponse: kraJson,
      });
    }

    const data = kraJson.data || {};
    const cuSerial = (body?.cuSerial || tin).toString().trim();
    const rcptNo = data.rcptNo ?? invcNo;
    const rcptSign = String(data.rcptSign || '');
    const host = sandbox ? 'https://etims-sbx.kra.go.ke' : 'https://etims.kra.go.ke';
    const qrCodeUrl = rcptSign
      ? `${host}/common/link/etims/receipt/indexEtimsInvoiceData?Data=${tin}${bhfId}${rcptSign}`
      : '';

    return jsonResponse(200, {
      ok: true,
      invcNo,
      cuInvoiceNumber: `${cuSerial}/${rcptNo}`,
      qrCodeUrl,
      data,
    });
  }

  return jsonResponse(404, { error: 'Route not found.' });
}

export default {
  async fetch(request, env, ctx) {
    return handleOscuRequest(request, env, ctx);
  },
};
