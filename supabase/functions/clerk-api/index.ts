import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
};

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function makeToken(bytes: Uint8Array) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

async function hashToken(token: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}

function cleanText(value: unknown, maxLength: number, required = false) {
  if (typeof value !== 'string') return required ? null : '';
  const result = value.trim().slice(0, maxLength);
  return required && !result ? null : result;
}

function finiteNonNegative(value: unknown, field: string) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw new Error(`${field} must be zero or greater.`);
  return number;
}

function normalizeDocket(docket: Record<string, unknown>) {
  const clerkName = cleanText(docket.clerk_name, 120, true);
  const restaurantName = cleanText(docket.restaurant_name, 180, true);
  const invoiceDate = cleanText(docket.invoice_date, 10, true);
  if (!clerkName || !restaurantName || !invoiceDate || !/^\d{4}-\d{2}-\d{2}$/.test(invoiceDate)) {
    throw new Error('Clerk name, restaurant, and a valid invoice date are required.');
  }

  if (!Array.isArray(docket.items_json) || docket.items_json.length < 1 || docket.items_json.length > 200) {
    throw new Error('A docket must contain between 1 and 200 line items.');
  }

  const items = docket.items_json.map((raw, index) => {
    const item = raw as Record<string, unknown>;
    const desc = cleanText(item?.desc ?? item?.name, 180, true);
    if (!desc) throw new Error(`Line item ${index + 1} needs a description.`);
    const qty = Number(item.qty);
    if (!Number.isFinite(qty) || qty <= 0) throw new Error(`Line item ${index + 1} needs a quantity greater than zero.`);
    const sellPrice = finiteNonNegative(item.sellPrice ?? item.price ?? item.sell, `Line item ${index + 1} price`);
    const buyPrice = finiteNonNegative(item.buyPrice ?? item.buy ?? 0, `Line item ${index + 1} cost`);
    return {
      desc,
      qty,
      unit: cleanText(item.unit, 30) || 'kgs',
      sellPrice,
      buyPrice,
      total: qty * sellPrice,
    };
  });

  const deliveryCost = finiteNonNegative(docket.delivery_cost, 'Delivery cost');
  const otherCost = finiteNonNegative(docket.other_cost, 'Other cost');
  const itemTotal = items.reduce((sum, item) => sum + item.total, 0);
  const buyTotal = items.reduce((sum, item) => sum + item.qty * item.buyPrice, 0);
  const suppliedPhotos = Array.isArray(docket.receipt_photos) ? docket.receipt_photos : [];
  if (suppliedPhotos.length > 20) throw new Error('A docket can include at most 20 receipt pages.');
  const photo = typeof docket.receipt_photo === 'string' ? docket.receipt_photo : null;
  const photos = suppliedPhotos.length
    ? suppliedPhotos
    : (photo ? [photo] : []);
  const imageDataUrl = /^data:image\/(?:jpe?g|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$/i;
  if (photos.some(value => typeof value !== 'string' || value.length > 12_000_000 || !imageDataUrl.test(value))) {
    throw new Error('Receipt pages must be valid JPEG, PNG, WebP, or GIF image data.');
  }
  const normalizedPhoto = photos[0] ?? null;

  return {
    clerk_name: clerkName,
    restaurant_name: restaurantName,
    invoice_date: invoiceDate,
    items_json: items,
    delivery_cost: deliveryCost,
    other_cost: otherCost,
    total_sell: itemTotal + deliveryCost + otherCost,
    total_buy: buyTotal,
    receipt_photo: normalizedPhoto,
    receipt_photos: photos,
    notes: cleanText(docket.notes, 4000),
  };
}

async function getOwnerFromJwt(request: Request) {
  const authorization = request.headers.get('Authorization') || '';
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match || !anonKey) return null;
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${match[1]}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await userClient.auth.getUser(match[1]);
  if (error || !data.user) return null;
  return data.user;
}

async function resolveInvite(token: unknown) {
  if (typeof token !== 'string' || token.length < 40 || token.length > 100) return null;
  const tokenHash = await hashToken(token);
  const { data, error } = await admin
    .from('clerk_invites')
    .select('id, owner_user_id, owner_email, owner_name, expires_at, revoked_at')
    .eq('token_hash', tokenHash)
    .maybeSingle();
  if (error || !data || data.revoked_at || Date.parse(data.expires_at) <= Date.now()) return null;
  return data;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return reply(405, { error: 'Method not allowed.' });
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return reply(500, { error: 'Clerk service is not configured.' });

  try {
    const rawBody = await request.text();
    if (rawBody.length > 25_000_000) return reply(413, { error: 'Docket upload is too large.' });
    const body = JSON.parse(rawBody);

    if (body.action === 'create_invite') {
      const user = await getOwnerFromJwt(request);
      if (!user) return reply(401, { error: 'Sign in to create a clerk link.' });
      const token = makeToken(crypto.getRandomValues(new Uint8Array(32)));
      const tokenHash = await hashToken(token);
      const ownerName = cleanText(user.user_metadata?.full_name ?? user.user_metadata?.name, 120)
        || cleanText(user.email?.split('@')[0], 120)
        || 'Account owner';
      const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
      const { data, error } = await admin.from('clerk_invites').insert({
        owner_user_id: user.id,
        token_hash: tokenHash,
        owner_email: user.email ?? null,
        owner_name: ownerName,
        expires_at: expiresAt,
      }).select('id, owner_user_id, owner_email, owner_name, expires_at').single();
      if (error) throw error;
      const { error: revokeError } = await admin.from('clerk_invites')
        .update({ revoked_at: new Date().toISOString() })
        .eq('owner_user_id', user.id)
        .is('revoked_at', null)
        .neq('id', data.id);
      if (revokeError) {
        await admin.from('clerk_invites').delete().eq('id', data.id);
        throw revokeError;
      }
      return reply(200, { token, invite: data });
    }

    const invite = await resolveInvite(body.invite_token);
    if (!invite) return reply(401, { error: 'This clerk link is invalid or expired. Ask the account owner for a new link.' });

    if (body.action === 'list') {
      const { data, error } = await admin.from('staged_invoices')
        .select('*')
        .eq('owner_user_id', invite.owner_user_id)
        .eq('submitted_by_invite_id', invite.id)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return reply(200, {
        owner: { name: invite.owner_name, email: invite.owner_email },
        submissions: data ?? [],
      });
    }

    if (body.action === 'delete') {
      const id = cleanText(body.id, 160, true);
      if (!id) return reply(400, { error: 'Docket ID is required.' });
      const { data: removed, error } = await admin.from('staged_invoices')
        .delete()
        .eq('id', id)
        .eq('owner_user_id', invite.owner_user_id)
        .eq('submitted_by_invite_id', invite.id)
        .in('status', ['pending', 'rejected'])
        .select('id')
        .maybeSingle();
      if (error) throw error;
      if (!removed) return reply(409, { error: 'Only a pending or returned docket from this invite can be deleted.' });
      return reply(200, { deleted: true });
    }

    if (body.action !== 'submit') return reply(400, { error: 'Unsupported clerk action.' });
    if (!body.docket || typeof body.docket !== 'object' || Array.isArray(body.docket)) {
      return reply(400, { error: 'Docket data is required.' });
    }
    const submissionKey = cleanText(body.submission_key, 80, true);
    if (!submissionKey || !/^[A-Za-z0-9_-]{16,80}$/.test(submissionKey)) {
      return reply(400, { error: 'A valid submission retry key is required.' });
    }
    const fields = normalizeDocket(body.docket);

    const { data: prior, error: priorError } = await admin.from('staged_invoices')
      .select('*')
      .eq('owner_user_id', invite.owner_user_id)
      .eq('submitted_by_invite_id', invite.id)
      .eq('submission_key', submissionKey)
      .maybeSingle();
    if (priorError) throw priorError;
    if (prior) return reply(200, { submission: prior, replayed: true });

    const requestedId = cleanText(body.docket.id, 160);
    const baseRecord = {
      ...fields,
      owner_user_id: invite.owner_user_id,
      submitted_by_invite_id: invite.id,
      submission_key: submissionKey,
      target_user_id: invite.owner_user_id,
      target_user_email: invite.owner_email,
      target_user_name: invite.owner_name,
      status: 'pending',
      rejection_reason: '',
      updated_at: new Date().toISOString(),
    };

    if (requestedId) {
      const { data: returned, error: lookupError } = await admin.from('staged_invoices')
        .select('id, status, submitted_by_invite_id')
        .eq('id', requestedId)
        .eq('owner_user_id', invite.owner_user_id)
        .eq('submitted_by_invite_id', invite.id)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (!returned || returned.status !== 'rejected') {
        return reply(409, { error: 'Only a returned docket from this invite can be corrected.' });
      }
      const { data, error } = await admin.from('staged_invoices')
        .update(baseRecord)
        .eq('id', requestedId)
        .eq('owner_user_id', invite.owner_user_id)
        .eq('submitted_by_invite_id', invite.id)
        .eq('status', 'rejected')
        .select('*')
        .maybeSingle();
      if (error) throw error;
      if (!data) return reply(409, { error: 'This docket has already changed. Refresh the clerk history and try again.' });
      return reply(200, { submission: data, replayed: false });
    }

    const record = {
      ...baseRecord,
      id: `stg_${crypto.randomUUID()}`,
      created_at: new Date().toISOString(),
    };
    const { data, error } = await admin.from('staged_invoices').insert(record).select('*').single();
    if (error?.code === '23505') {
      const { data: replay } = await admin.from('staged_invoices').select('*')
        .eq('owner_user_id', invite.owner_user_id)
        .eq('submitted_by_invite_id', invite.id)
        .eq('submission_key', submissionKey)
        .maybeSingle();
      if (replay) return reply(200, { submission: replay, replayed: true });
    }
    if (error) throw error;
    return reply(200, { submission: data, replayed: false });
  } catch (error) {
    console.error('[clerk-api]', error);
    return reply(400, { error: error instanceof Error ? error.message : 'Clerk request failed.' });
  }
});
