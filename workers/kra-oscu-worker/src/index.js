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
  return { userId: user.id };
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
    });
  }

  const auth = await authenticateSupabaseUser(request, env, fetchImpl);
  if (auth.error) return auth.error;

  if (request.method === 'POST' && path === '/oscu/sales') {
    const cmcKey = (env.KRA_CMC_KEY || '').trim();
    if (!cmcKey) {
      return jsonResponse(503, {
        error:
          'KRA OSCU key (KRA_CMC_KEY) is not added to this server yet. Enter Receipt No. & Receipt Signature manually or add your KRA GavaConnect CMC key.',
      });
    }

    const body = await request.json();
    const reqPayload = body?.saveTrnsSalesReq;
    if (!reqPayload || !reqPayload.tin || !Array.isArray(reqPayload.itemList)) {
      return jsonResponse(400, { error: 'Invalid OSCU sales invoice payload.' });
    }

    const sandbox = body?.sandbox === true;
    const base = sandbox ? SANDBOX_API_BASE : PROD_API_BASE;
    const kraRes = await fetchImpl(`${base}/saveTrnsSalesReq`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        tin: String(reqPayload.tin),
        bhfId: String(reqPayload.bhfId || '00'),
        cmcKey,
      },
      body: JSON.stringify(reqPayload),
    });

    const kraJson = await kraRes.json();
    if (!kraRes.ok || (kraJson.resultCd && kraJson.resultCd !== '000')) {
      return jsonResponse(502, {
        error: kraJson.resultMsg || `KRA eTIMS rejected invoice (HTTP ${kraRes.status}).`,
        kraResponse: kraJson,
      });
    }

    const data = kraJson.data || {};
    const cuSerial = (body?.cuSerial || reqPayload.tin).toString().trim();
    const rcptNo = data.rcptNo ?? reqPayload.invcNo;
    const rcptSign = String(data.rcptSign || '');
    const host = sandbox ? 'https://etims-sbx.kra.go.ke' : 'https://etims.kra.go.ke';
    const qrCodeUrl = rcptSign
      ? `${host}/common/link/etims/receipt/indexEtimsInvoiceData?Data=${reqPayload.tin}${reqPayload.bhfId || '00'}${rcptSign}`
      : '';

    return jsonResponse(200, {
      ok: true,
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
