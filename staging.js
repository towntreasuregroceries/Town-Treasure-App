/* ═══════════════════════════════════════════════════════════════════════════
   Town Treasure Groceries — Staging Service
   Maker-Checker Approval Bridge between Clerks and Veronica's Encrypted Vault
   ═══════════════════════════════════════════════════════════════════════════ */

const StagingDB = {
  _supabaseAvailable: null,
  _clerkInviteOwner: null,

  getClerkInviteToken() {
    try {
      return sessionStorage.getItem('ttg_clerk_invite_token') || '';
    } catch (e) {
      return '';
    }
  },

  isClerkPortalPage() {
    return /(?:^|\/)clerk\.html$/i.test(window.location.pathname);
  },

  getClerkSubmissionKey() {
    let key = '';
    try { key = sessionStorage.getItem('ttg_clerk_submission_key') || ''; } catch (e) {}
    if (!key) {
      key = typeof crypto !== 'undefined' && crypto.randomUUID
        ? crypto.randomUUID()
        : `sub_${Date.now()}_${Math.random().toString(36).slice(2, 14)}`;
      try { sessionStorage.setItem('ttg_clerk_submission_key', key); } catch (e) {}
    }
    return key;
  },

  resetClerkSubmissionKey() {
    try { sessionStorage.removeItem('ttg_clerk_submission_key'); } catch (e) {}
  },

  async callClerkApi(body) {
    if (!supabaseClient) throw new Error('Secure clerk service is unavailable. Reconnect and retry.');
    const { data, error } = await supabaseClient.functions.invoke('clerk-api', { body });
    if (error) {
      let message = error.message || 'Clerk request failed.';
      try {
        const detail = await error.context?.json();
        if (detail?.error) message = detail.error;
      } catch (e) {}
      throw new Error(message);
    }
    if (!data || data.error) throw new Error(data?.error || 'Clerk service returned no result.');
    return data;
  },

  async createClerkInvite() {
    return await this.callClerkApi({ action: 'create_invite' });
  },

  /** Check if Supabase client is initialized and staged_invoices table is accessible */
  async checkSupabase() {
    if (this._supabaseAvailable === true) return true;
    if (typeof supabaseClient === 'undefined' || !supabaseClient) {
      this._supabaseAvailable = false;
      return false;
    }
    try {
      const { error } = await supabaseClient.from('staged_invoices').select('id').limit(1);
      this._supabaseAvailable = !error;
      return !error;
    } catch (e) {
      this._supabaseAvailable = false;
      return false;
    }
  },

  /** Helper to generate realistic visual docket SVG receipt for demo/offline verification */
  generateDocketSVG(docketNum, client, date, items, clerk) {
    const rows = (items || []).slice(0, 8).map((it, idx) => `
      <text x="32" y="${175 + idx * 26}" font-family="monospace" font-size="12" fill="#1f2937">${(idx + 1).toString().padStart(2, '0')}. ${it.desc}</text>
      <text x="290" y="${175 + idx * 26}" font-family="monospace" font-size="12" fill="#1f2937" text-anchor="end">${it.qty} ${it.unit}</text>
      <text x="390" y="${175 + idx * 26}" font-family="monospace" font-size="12" fill="#1f2937" text-anchor="end">KES ${it.sellPrice || it.price || 0}</text>
      <text x="510" y="${175 + idx * 26}" font-family="monospace" font-weight="bold" font-size="12" fill="#111827" text-anchor="end">KES ${(it.qty * (it.sellPrice || it.price || 0)).toLocaleString()}</text>
    `).join('');

    const subtotal = (items || []).reduce((s, i) => s + (i.qty * (i.sellPrice || i.price || 0)), 0);

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="550" height="480" viewBox="0 0 550 480">
      <rect width="100%" height="100%" fill="#fffdfa" stroke="#d1d5db" stroke-width="2" rx="8"/>
      <rect x="20" y="20" width="510" height="74" fill="#f0fdf4" stroke="#86efac" rx="6"/>
      <text x="35" y="48" font-family="sans-serif" font-weight="bold" font-size="16" fill="#166534">TOWN TREASURE GROCERIES</text>
      <text x="35" y="68" font-family="sans-serif" font-size="11" fill="#15803d">WHOLESALE PRODUCE &amp; FRESH DELIVERY NOTE</text>
      <text x="515" y="48" font-family="monospace" font-size="12" fill="#374151" text-anchor="end">DOCKET: ${docketNum}</text>
      <text x="515" y="68" font-family="monospace" font-size="11" fill="#4b5563" text-anchor="end">DATE: ${date}</text>
      
      <text x="30" y="118" font-family="sans-serif" font-size="12" fill="#4b5563">Client / Destination: <tspan font-weight="bold" fill="#111827">${client}</tspan></text>
      <text x="30" y="136" font-family="sans-serif" font-size="11" fill="#6b7280">Intake Clerk: ${clerk} | Dispatch Inspection Verified</text>
      
      <line x1="20" y1="148" x2="530" y2="148" stroke="#9ca3af" stroke-dasharray="4"/>
      
      <text x="32" y="162" font-family="sans-serif" font-weight="bold" font-size="11" fill="#4b5563">ITEM DESCRIPTION</text>
      <text x="290" y="162" font-family="sans-serif" font-weight="bold" font-size="11" fill="#4b5563" text-anchor="end">QTY</text>
      <text x="390" y="162" font-family="sans-serif" font-weight="bold" font-size="11" fill="#4b5563" text-anchor="end">RATE</text>
      <text x="510" y="162" font-family="sans-serif" font-weight="bold" font-size="11" fill="#4b5563" text-anchor="end">TOTAL</text>
      
      ${rows}
      
      <line x1="20" y1="390" x2="530" y2="390" stroke="#d1d5db"/>
      <text x="32" y="415" font-family="sans-serif" font-size="11" fill="#6b7280">PHYSICAL CARBON COPY -- TOWN TREASURE</text>
      <text x="380" y="415" font-family="sans-serif" font-weight="bold" font-size="12" fill="#111827">TOTAL: KES ${subtotal.toLocaleString()}</text>
      <rect x="360" y="425" width="150" height="42" fill="none" stroke="#16a34a" stroke-width="1.5" stroke-dasharray="3" rx="4"/>
      <text x="435" y="442" font-family="sans-serif" font-size="10" font-weight="bold" fill="#15803d" text-anchor="middle">GOODS RECEIVED IN ORDER</text>
      <text x="435" y="456" font-family="sans-serif" font-size="9" fill="#166534" text-anchor="middle">HEAD CHEF SIGNATURE</text>
    </svg>`;
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  },

  /** Create authentic initial Kenyan produce dockets for maker-checker evaluation */
  createDefaultDemoDockets() {
    const today = new Date().toISOString().slice(0, 10);
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);

    const docket1Items = [
      { desc: 'Red Onions (Medium)', qty: 50, unit: 'kgs', buyPrice: 110, sellPrice: 155, price: 155, total: 7750 },
      { desc: 'Roma Tomatoes', qty: 3, unit: 'crates', buyPrice: 2400, sellPrice: 3200, price: 3200, total: 9600 },
      { desc: 'Potatoes (Shangi)', qty: 2, unit: 'bags', buyPrice: 3100, sellPrice: 4200, price: 4200, total: 8400 },
      { desc: 'Sukuma Wiki', qty: 25, unit: 'bundles', buyPrice: 20, sellPrice: 35, price: 35, total: 875 },
      { desc: 'Dhania (Coriander)', qty: 15, unit: 'bundles', buyPrice: 25, sellPrice: 40, price: 40, total: 600 },
      { desc: 'Sweet Capsicum (Hoho)', qty: 12, unit: 'kgs', buyPrice: 130, sellPrice: 180, price: 180, total: 2160 }
    ];

    const docket2Items = [
      { desc: 'Baby Spinach', qty: 20, unit: 'bundles', buyPrice: 30, sellPrice: 50, price: 50, total: 1000 },
      { desc: 'English Cucumbers', qty: 15, unit: 'kgs', buyPrice: 80, sellPrice: 130, price: 130, total: 1950 },
      { desc: 'Button Mushrooms', qty: 8, unit: 'kgs', buyPrice: 350, sellPrice: 520, price: 520, total: 4160 },
      { desc: 'Garlic (Imported)', qty: 10, unit: 'kgs', buyPrice: 240, sellPrice: 350, price: 350, total: 3500 },
      { desc: 'Fresh Mint', qty: 10, unit: 'bundles', buyPrice: 20, sellPrice: 40, price: 40, total: 400 }
    ];

    return [
      {
        id: 'stg_demo_golden_crest',
        clerk_name: 'Daniel Ochieng',
        restaurant_name: 'The Golden Crest Hotel',
        invoice_date: today,
        items_json: docket1Items,
        delivery_cost: 500,
        other_cost: 0,
        total_sell: 29885,
        total_buy: 22400,
        receipt_photo: this.generateDocketSVG('DKT-8821', 'The Golden Crest Hotel', today, docket1Items, 'Daniel Ochieng'),
        notes: 'Morning kitchen dispatch. Quality checked and verified by Head Chef James.',
        status: 'pending',
        rejection_reason: '',
        created_at: new Date(Date.now() - 7200000).toISOString()
      },
      {
        id: 'stg_demo_sankara',
        clerk_name: 'Faith Muthoni',
        restaurant_name: 'Sankara Suites',
        invoice_date: yesterday,
        items_json: docket2Items,
        delivery_cost: 450,
        other_cost: 50,
        total_sell: 11510,
        total_buy: 8100,
        receipt_photo: this.generateDocketSVG('DKT-8819', 'Sankara Suites', yesterday, docket2Items, 'Faith Muthoni'),
        notes: 'Banquet prep produce order. Received and stamped by storekeeper.',
        status: 'pending',
        rejection_reason: '',
        created_at: new Date(Date.now() - 86400000).toISOString()
      }
    ];
  },

  /** Get locally cached staging items (never auto-seeds demo dockets) */
  getLocalQueue() {
    try {
      const stored = localStorage.getItem('ttg_staged_invoices');
      if (stored) {
        const parsed = JSON.parse(stored);
        if (Array.isArray(parsed)) {
          // Actively purge any legacy hardcoded demo dockets
          const clean = parsed.filter(x => x && x.id && !x.id.startsWith('stg_demo_'));
          if (clean.length !== parsed.length) {
            this.setLocalQueue(clean);
          }
          return clean;
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  },

  /** Save locally cached staging items */
  setLocalQueue(list) {
    try {
      localStorage.setItem('ttg_staged_invoices', JSON.stringify(list));
    } catch (e) {
      console.warn('LocalStorage quota exceeded or storage unavailable:', e);
    }
  },

  getDeletedQueueIds() {
    try {
      const ids = JSON.parse(localStorage.getItem('ttg_deleted_staged_invoice_ids') || '[]');
      return Array.isArray(ids) ? ids : [];
    } catch (e) {
      return [];
    }
  },

  setDeletedQueueIds(ids) {
    localStorage.setItem('ttg_deleted_staged_invoice_ids', JSON.stringify(Array.from(new Set(ids || []))));
  },

  /** Reset or re-seed sample dockets */
  seedDemoDockets(force = true) {
    const demo = this.createDefaultDemoDockets();
    if (force) {
      this.setLocalQueue(demo);
    } else {
      const current = this.getLocalQueue();
      const ids = new Set(current.map(x => x.id));
      demo.forEach(d => {
        if (!ids.has(d.id)) current.push(d);
      });
      this.setLocalQueue(current);
    }
    this.updatePendingCountBadge();
    return demo;
  },

  /** Export docket as portable base64 string */
  exportDocketAsCode(docket) {
    return btoa(unescape(encodeURIComponent(JSON.stringify(docket))));
  },

  /** Import docket from portable string or JSON */
  async importDocketFromCode(rawStr) {
    let obj;
    try {
      const decoded = decodeURIComponent(escape(atob(rawStr.trim())));
      obj = JSON.parse(decoded);
    } catch(e) {
      try {
        obj = JSON.parse(rawStr.trim());
      } catch(e2) {
        throw new Error('Invalid docket format. Please provide valid docket JSON or exported code.');
      }
    }
    if (!obj || !obj.restaurant_name || !Array.isArray(obj.items_json)) {
      throw new Error('Invalid docket: missing restaurant name or line items.');
    }
    
    // Check if docket already exists in the queue by id to avoid duplicate copies
    if (obj.id) {
      const all = await this.getAllSubmissions(false);
      const existing = all.find(x => x.id === obj.id);
      if (existing) {
        return existing;
      }
    }
    
    return await this.submitDocket(obj);
  },

  /** Get active user identifier for isolation filtering */
  getCurrentUserIdentifier() {
    let uid = null;
    let email = null;
    if (typeof currentUser !== 'undefined' && currentUser) {
      uid = currentUser.id;
      email = (currentUser.email || '').toLowerCase().trim();
    }
    if (!uid && typeof getUserId === 'function') {
      uid = getUserId();
    }
    if (!email) {
      email = (localStorage.getItem('ttg_user_email') || '').toLowerCase().trim();
    }
    if (!uid) {
      uid = localStorage.getItem('ttg_user_id');
    }
    return { uid, email };
  },

  /** Check if a submission belongs to the current user */
  isSubmissionForUser(item, userIdent) {
    if (!userIdent || (!userIdent.uid && !userIdent.email)) {
      return false; // Never leak store submissions when user identity is unestablished
    }

    const userEmail = (userIdent.email || '').toLowerCase().trim();
    const userUid = userIdent.uid || '';

    if (item.owner_user_id) return Boolean(userUid && item.owner_user_id === userUid);

    // Explicit target user id or email match
    if (item.target_user_id || item.target_user_email) {
      if (userUid && item.target_user_id === userUid) return true;
      if (userEmail && item.target_user_email && item.target_user_email.toLowerCase().trim() === userEmail) return true;
      // Targeted to another specific account
      return false;
    }

    // Target specified inside notes: [Target: Veronica (email)]
    if (item.notes && item.notes.includes('[Target:')) {
      if (userEmail && item.notes.toLowerCase().includes(userEmail)) return true;
      if (userUid && item.notes.includes(userUid)) return true;
      // Target specified for someone else
      return false;
    }

    // Default legacy untargeted docket: only show for Veronica's legacy account
    if (userEmail && (userEmail.includes('veron') || userEmail.includes('njuguna'))) {
      return true;
    }
    return false;
  },

  /** Fetch all submissions (combines Supabase and local queue with deduplication and user isolation) */
  async getAllSubmissions(filterForCurrentUser = true) {
    const inviteToken = this.getClerkInviteToken();
    if (inviteToken) {
      const result = await this.callClerkApi({ action: 'list', invite_token: inviteToken });
      this._clerkInviteOwner = result.owner || null;
      return Array.isArray(result.submissions) ? result.submissions : [];
    }
    if (this.isClerkPortalPage()) {
      throw new Error('This clerk page needs a valid invite link. Ask the account owner for a new one.');
    }

    if (typeof getCurrentUser === 'function' && (!currentUser || !currentUser.id)) {
      try { await getCurrentUser(); } catch(e) {}
    }

    const userIdent = this.getCurrentUserIdentifier();
    const deletedIds = new Set(this.getDeletedQueueIds());
    const local = this.getLocalQueue().filter(item => {
      if (deletedIds.has(item.id)) return false;
      if (!userIdent?.uid) return false;
      return item.owner_user_id === userIdent.uid
        || item.target_user_id === userIdent.uid
        || (userIdent.email && (item.target_user_email || '').toLowerCase().trim() === userIdent.email.toLowerCase().trim());
    });
    const hasSb = await this.checkSupabase();
    let combined = local;

    if (hasSb) {
      try {
        const { data, error } = await supabaseClient
          .from('staged_invoices')
          .select('*')
          .order('created_at', { ascending: false });

        if (error) throw error;

        // Retry failed remote deletes while keeping those records hidden locally.
        if (deletedIds.size) {
          const { error: deleteError } = await supabaseClient
            .from('staged_invoices')
            .delete()
            .in('id', Array.from(deletedIds));
          if (deleteError) console.warn('[Staging] Pending delete retry warning:', deleteError);
        }

        // Merge Supabase data with local items
        const map = new Map();
        (data || []).forEach(item => {
          if (item.id && item.id.startsWith('stg_demo_')) return;
          map.set(item.id, {
            ...item,
            id: item.id,
            clerk_name: item.clerk_name,
            restaurant_name: item.restaurant_name,
            invoice_date: item.invoice_date,
            items_json: item.items_json || [],
            delivery_cost: parseFloat(item.delivery_cost) || 0,
            other_cost: parseFloat(item.other_cost) || 0,
            total_sell: parseFloat(item.total_sell) || 0,
            total_buy: parseFloat(item.total_buy) || 0,
            receipt_photo: item.receipt_photo || null,
            receipt_photos: Array.isArray(item.receipt_photos) ? item.receipt_photos : (item.receipt_photo ? [item.receipt_photo] : []),
            notes: item.notes || '',
            status: item.status || 'pending',
            rejection_reason: item.rejection_reason || '',
            target_user_id: item.target_user_id || null,
            target_user_email: item.target_user_email || null,
            target_user_name: item.target_user_name || null,
            created_at: item.created_at || new Date().toISOString()
          });
        });

        // Include local entries if not in Supabase (skip demo dockets)
        local.forEach(item => {
          if (item.id && item.id.startsWith('stg_demo_')) return;
          if (!map.has(item.id)) map.set(item.id, item);
        });

        combined = Array.from(map.values()).filter(item => !deletedIds.has(item.id));
      } catch (e) {
        console.warn('[Staging] Error fetching from Supabase, using local queue:', e);
        combined = local.filter(x => !x.id || (!x.id.startsWith('stg_demo_') && !deletedIds.has(x.id)));
      }
    } else {
      combined = local.filter(x => !x.id || (!x.id.startsWith('stg_demo_') && !deletedIds.has(x.id)));
    }

    // Support explicit target object filtering (e.g. from clerk portal)
    if (filterForCurrentUser && typeof filterForCurrentUser === 'object') {
      const tId = filterForCurrentUser.targetOwnerId || '';
      const tEmail = (filterForCurrentUser.targetOwnerEmail || '').toLowerCase().trim();
      return combined.filter(item => {
        if (tId && item.target_user_id) return item.target_user_id === tId;
        if (tEmail && item.target_user_email) return item.target_user_email.toLowerCase().trim() === tEmail;
        if (item.notes && item.notes.includes('[Target:')) {
          if (tEmail && item.notes.toLowerCase().includes(tEmail)) return true;
          if (tId && item.notes.includes(tId)) return true;
          return false;
        }
        return false;
      });
    }

    if (!filterForCurrentUser) return combined;

    return combined.filter(item => this.isSubmissionForUser(item, userIdent));
  },

  /** Fetch only pending submissions */
  async getPendingSubmissions() {
    const all = await this.getAllSubmissions(true);
    return all.filter(s => s.status === 'pending');
  },

  /** Submit or update a docket (called by Clerk portal) */
  async submitDocket(docket) {
    const genUUID = () => {
      if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
      return 'stg_' + Date.now() + '_' + Math.random().toString(36).substring(2, 7);
    };

    const signedInUserId = (typeof getUserId === 'function' && getUserId())
      || (typeof currentUser !== 'undefined' && currentUser?.id)
      || null;
    const targetId = signedInUserId || docket.target_user_id || localStorage.getItem('ttg_target_owner_id') || null;
    const targetEmail = docket.target_user_email || localStorage.getItem('ttg_target_owner_email') || null;
    const targetName = docket.target_user_name || localStorage.getItem('ttg_target_owner_name') || 'Veronica';

    let formattedNotes = (docket.notes || '').trim();
    if (targetName || targetEmail) {
      const targetTag = `[Target: ${targetName}${targetEmail ? ' (' + targetEmail + ')' : ''}]`;
      if (!formattedNotes.includes('[Target:')) {
        formattedNotes = formattedNotes ? `${targetTag} ${formattedNotes}` : targetTag;
      }
    }

    const record = {
      id: docket.id || genUUID(),
      owner_user_id: signedInUserId || targetId,
      clerk_name: (docket.clerk_name || 'Clerk').trim(),
      restaurant_name: (docket.restaurant_name || 'General Wholesale').trim(),
      invoice_date: docket.invoice_date || new Date().toISOString().slice(0, 10),
      items_json: Array.isArray(docket.items_json) ? docket.items_json : [],
      delivery_cost: parseFloat(docket.delivery_cost) || 0,
      other_cost: parseFloat(docket.other_cost) || 0,
      total_sell: parseFloat(docket.total_sell) || 0,
      total_buy: parseFloat(docket.total_buy) || 0,
      receipt_photo: docket.receipt_photo || (docket.receipt_photos && docket.receipt_photos[0]) || null,
      receipt_photos: Array.isArray(docket.receipt_photos) ? docket.receipt_photos : (docket.receipt_photo ? [docket.receipt_photo] : []),
      notes: formattedNotes,
      status: 'pending',
      rejection_reason: '',
      target_user_id: targetId,
      target_user_email: targetEmail,
      target_user_name: targetName,
      created_at: docket.created_at || new Date().toISOString()
    };

    const inviteToken = this.getClerkInviteToken();
    if (inviteToken) {
      // The invite token is verified server-side. Never fall back to a local
      // queue or direct anon-table write when the secure service is unavailable.
      // A local ID is generated above for the legacy/local queue path. Only send
      // an ID to the API when the clerk is explicitly correcting a returned row.
      const apiDocket = { ...record };
      if (!docket.id) delete apiDocket.id;
      const result = await this.callClerkApi({
        action: 'submit',
        invite_token: inviteToken,
        submission_key: docket.submission_key || this.getClerkSubmissionKey(),
        docket: apiDocket,
      });
      const saved = result.submission;
      if (!saved?.id) throw new Error('The server did not confirm the saved docket. Keep this form open and retry.');
      this.setDeletedQueueIds(this.getDeletedQueueIds().filter(deletedId => deletedId !== saved.id));
      const inviteLocal = this.getLocalQueue();
      const inviteIndex = inviteLocal.findIndex(item => item.id === saved.id);
      if (inviteIndex >= 0) inviteLocal[inviteIndex] = saved;
      else inviteLocal.unshift(saved);
      this.setLocalQueue(inviteLocal);
      return saved;
    }
    if (this.isClerkPortalPage()) {
      throw new Error('This clerk page needs a valid invite link. Ask the account owner for a new one.');
    }

    if (!signedInUserId) throw new Error('Sign in to save a clerk docket to the review queue.');
    const hasSb = await this.checkSupabase();
    if (!hasSb) throw new Error('Could not reach the secure review queue. The docket was not submitted; keep the form open and retry.');
    const { error: saveError } = await supabaseClient.from('staged_invoices').upsert([record], { onConflict: 'id' });
    if (saveError) throw new Error('The review queue did not confirm this docket: ' + saveError.message);

    // Update local cache only after the server confirms the write.
    this.setDeletedQueueIds(this.getDeletedQueueIds().filter(deletedId => deletedId !== record.id));
    const local = this.getLocalQueue();
    const existingIdx = local.findIndex(x => x.id === record.id);
    if (existingIdx >= 0) {
      local[existingIdx] = record;
    } else {
      local.unshift(record);
    }
    this.setLocalQueue(local);

    // Update pending badge if in app
    if (typeof this.updatePendingCountBadge === 'function') {
      this.updatePendingCountBadge();
    }

    return record;
  },

  /**
   * Approve a staged docket and commit it into Veronica's E2EE Private Vault.
   * This executes DB.invoices = ..., which triggers automatic E2EE encryption
   * with Veronica's master password key!
   */
  async approveSubmission(id, adjustedData = {}) {
    const all = await this.getAllSubmissions(false);
    const item = all.find(x => x.id === id);
    if (!item) throw new Error('Submission not found in staging queue.');

    // A docket is an idempotent approval unit. If an earlier click committed it
    // but the status update or response was interrupted, reuse that invoice.
    const existingInvoice = (DB.invoices || []).find(invoice => invoice && (
      invoice.sourceSubmissionId === id ||
      (item.generated_invoice_number && invoice.number === item.generated_invoice_number)
    ));
    if (existingInvoice) {
      const local = this.getLocalQueue();
      const index = local.findIndex(record => record.id === id);
      if (index >= 0) {
        local[index] = { ...local[index], status: 'approved', rejection_reason: '', generated_invoice_number: existingInvoice.number };
      } else {
        local.unshift({ ...item, status: 'approved', rejection_reason: '', generated_invoice_number: existingInvoice.number });
      }
      this.setLocalQueue(local);
      if (typeof DB.syncNow !== 'function' || !(await DB.syncNow())) {
        throw new Error('The invoice is only saved locally because the encrypted vault did not confirm sync. Keep this docket pending and retry sync before approving again.');
      }
      try {
        if (!(await this.checkSupabase())) throw new Error('Review queue is unavailable.');
        const { data: updated, error: statusError } = await supabaseClient.from('staged_invoices')
          .update({ status: 'approved', rejection_reason: '' }).eq('id', id).select('id').maybeSingle();
        if (statusError) throw statusError;
        if (!updated) throw new Error('Staged docket is no longer available.');
      } catch (statusErr) {
        throw new Error('The invoice is already safely in the vault, but its docket status could not be updated. Refresh and retry to repair the status.');
      }
      this.updatePendingCountBadge();
      return existingInvoice;
    }
    const archivedInvoice = (DB.deletedInvoices || []).find(invoice => invoice && (
      invoice.sourceSubmissionId === id ||
      (item.generated_invoice_number && invoice.number === item.generated_invoice_number)
    ));
    if (archivedInvoice) {
      throw new Error(`This docket already has invoice ${archivedInvoice.number} in the Recycle Bin. Restore that invoice instead of approving the docket again.`);
    }
    if (item.status !== 'pending') {
      throw new Error(`This docket is already ${item.status}. No new invoice was created. Check the invoice list or recycle bin before changing its status.`);
    }

    // Prepare line items
    const rawItems = adjustedData.items || item.items_json || [];
    const items = rawItems.map(it => {
      const q = parseFloat(it.qty) || 1;
      const b = parseFloat(it.buyPrice || it.buy) || 0;
      const s = parseFloat(it.sellPrice || it.sell || it.price) || 0;
      return {
        desc: (it.desc || it.name || 'Produce Item').trim(),
        qty: q,
        unit: it.unit || 'kgs',
        buyPrice: b,
        sellPrice: s,
        total: q * s
      };
    });

    const totalSell = items.reduce((sum, it) => sum + it.total, 0);
    const totalBuy = items.reduce((sum, it) => sum + (it.qty * it.buyPrice), 0);
    const deliveryCost = parseFloat(adjustedData.deliveryCost !== undefined ? adjustedData.deliveryCost : item.delivery_cost) || 0;
    const otherCost = parseFloat(adjustedData.otherCost !== undefined ? adjustedData.otherCost : item.other_cost) || 0;
    const profit = totalSell - totalBuy - deliveryCost - otherCost;

    let restName = (adjustedData.restaurantName || item.restaurant_name || 'General Wholesale').trim();

    // The approval UI resolves fuzzy names explicitly. Keep this storage layer
    // strict so an unresolved spelling can never silently create a duplicate.
    const restaurantResolution = resolveRestaurantName(restName, DB.restaurants || []);
    if (restaurantResolution.status !== 'matched') {
      throw new Error('This restaurant name is not uniquely registered. Confirm an existing match or create the restaurant before approving.');
    }
    const matchedRestaurant = restaurantResolution.restaurant;
    const restId = matchedRestaurant.id;
    restName = matchedRestaurant.name;
    const invDate = adjustedData.date || item.invoice_date || new Date().toISOString().slice(0, 10);
    const invNumber = typeof generateSecureInvoiceNumber === 'function'
      ? generateSecureInvoiceNumber(invDate)
      : 'TTG-' + Math.random().toString(36).substring(2, 6).toUpperCase();

    const clerkNote = item.clerk_name ? `[Submitted by Clerk: ${item.clerk_name}]` : '';
    const combinedNotes = [item.notes, clerkNote].filter(Boolean).join(' ');

    const newInvoice = {
      // Same source docket always maps to the same invoice ID, including across tabs.
      id: `stg_${String(id)}`,
      sourceSubmissionId: id,
      number: invNumber,
      restaurantId: restId,
      restaurantName: restName,
      date: invDate,
      dueDate: adjustedData.dueDate || '',
      items: items,
      totalSell: totalSell,
      totalBuy: totalBuy,
      deliveryCost: deliveryCost,
      otherCost: otherCost,
      profit: profit,
      notes: combinedNotes,
      status: 'pending', // Pending payment from restaurant client
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };

    // ══ COMMIT TO VERONICA'S VAULT ══
    // DB.invoices setter automatically triggers DB.syncToSupabase(), which
    // completely encrypts this new invoice using Veronica's master password key!
    if (typeof DB !== 'undefined' && DB.invoices) {
      const invList = DB.invoices;
      const existingIndex = invList.findIndex(invoice => invoice && invoice.id === newInvoice.id);
      if (existingIndex >= 0) invList[existingIndex] = newInvoice;
      else invList.unshift(newInvoice);
      DB.invoices = invList;
    }
    if (typeof DB.syncNow !== 'function' || !(await DB.syncNow())) {
      throw new Error('The invoice is only saved locally because the encrypted vault did not confirm sync. The docket remains pending; retry sync before approving again.');
    }

    // Update staging status locally
    const local = this.getLocalQueue();
    const lIdx = local.findIndex(x => x.id === id);
    if (lIdx >= 0) {
      local[lIdx].status = 'approved';
      local[lIdx].rejection_reason = '';
      local[lIdx].restaurant_name = restName;
      local[lIdx].invoice_date = invDate;
      local[lIdx].delivery_cost = deliveryCost;
      local[lIdx].other_cost = otherCost;
      local[lIdx].total_sell = totalSell;
      local[lIdx].total_buy = totalBuy;
      local[lIdx].items_json = items;
      local[lIdx].approved_at = new Date().toISOString();
      local[lIdx].generated_invoice_number = invNumber;
    } else {
      const copy = {
        ...item,
        status: 'approved',
        rejection_reason: '',
        restaurant_name: restName,
        invoice_date: invDate,
        delivery_cost: deliveryCost,
        other_cost: otherCost,
        total_sell: totalSell,
        total_buy: totalBuy,
        items_json: items,
        approved_at: new Date().toISOString(),
        generated_invoice_number: invNumber
      };
      local.unshift(copy);
    }
    this.setLocalQueue(local);

    // Update staging status in Supabase if accessible
    const hasSb = await this.checkSupabase();
    if (hasSb) {
      try {
        const updatePayload = {
          status: 'approved',
          rejection_reason: '',
          restaurant_name: restName,
          invoice_date: invDate,
          delivery_cost: deliveryCost,
          other_cost: otherCost,
          total_sell: totalSell,
          total_buy: totalBuy,
          items_json: items
        };
        const { data: statusUpdate, error } = await supabaseClient
          .from('staged_invoices')
          .update(updatePayload)
          .eq('id', id)
          .select('id')
          .maybeSingle();

        if (error) throw error;
        if (!statusUpdate) throw new Error('The staged docket was not updated.');
      } catch (sbErr) {
        throw new Error('The invoice is safely in the vault, but the docket status did not sync. Refresh and retry to repair the status.');
      }
    } else {
      throw new Error('The invoice is safely saved locally, but Supabase could not confirm the docket status. Reconnect and retry before treating the approval as complete.');
    }

    // Update badges
    this.updatePendingCountBadge();

    return newInvoice;
  },

  /** Reject a submission and send feedback back to the clerk */
  async rejectSubmission(id, reason = '') {
    if (!(await this.checkSupabase())) throw new Error('Could not reach the review queue. The docket was not returned; reconnect and retry.');
    const { data: updated, error: updateError } = await supabaseClient.from('staged_invoices')
      .update({ status: 'rejected', rejection_reason: reason, updated_at: new Date().toISOString() })
      .eq('id', id).eq('status', 'pending').select('id').maybeSingle();
    if (updateError) throw updateError;
    if (!updated) throw new Error('This docket is no longer pending. Refresh the queue before changing it.');

    const local = this.getLocalQueue();
    const lIdx = local.findIndex(x => x.id === id);
    if (lIdx >= 0) {
      local[lIdx].status = 'rejected';
      local[lIdx].rejection_reason = reason;
    } else {
      const all = await this.getAllSubmissions(false);
      const item = all.find(x => x.id === id);
      if (item) {
        local.unshift({ ...item, status: 'rejected', rejection_reason: reason });
      }
    }
    this.setLocalQueue(local);

    this.updatePendingCountBadge();
  },

  /** Permanently delete a docket from review queue (both Supabase and local cache) */
  async deleteSubmission(id) {
    const inviteToken = this.getClerkInviteToken();
    if (inviteToken) {
      const result = await this.callClerkApi({ action: 'delete', invite_token: inviteToken, id });
      if (result.deleted !== true) throw new Error('The server did not confirm this docket deletion.');
      this.setLocalQueue(this.getLocalQueue().filter(item => item.id !== id));
      this.setDeletedQueueIds([...this.getDeletedQueueIds(), id]);
      return true;
    }

    if (!(await this.checkSupabase())) throw new Error('Could not reach the review queue. The docket was not deleted; reconnect and retry.');
    const { data: removed, error: deleteError } = await supabaseClient.from('staged_invoices')
      .delete().eq('id', id).neq('status', 'approved').select('id').maybeSingle();
    if (deleteError) throw deleteError;
    if (!removed) throw new Error('Only an unapproved docket can be deleted. Refresh the queue and check its status.');
    this.setDeletedQueueIds([...this.getDeletedQueueIds(), id]);
    const local = this.getLocalQueue().filter(x => x.id !== id);
    this.setLocalQueue(local);

    this.updatePendingCountBadge();
    return true;
  },

  /** Update sidebar badge and dashboard pending alert */
  async updatePendingCountBadge() {
    try {
      const pending = await this.getPendingSubmissions();
      const count = pending.length;

      // Sidebar badge
      const badge = document.getElementById('clerkPendingBadge');
      if (badge) {
        if (count > 0) {
          badge.textContent = count;
          badge.style.display = 'inline-block';
        } else {
          badge.style.display = 'none';
        }
      }

      // Tab count in Clerk Submissions page
      const tabCount = document.getElementById('clerkTabPendingCount');
      if (tabCount) tabCount.textContent = count;

      // Dashboard Alert Banner
      const banner = document.getElementById('clerkPendingBanner');
      if (banner) {
        if (count > 0) {
          banner.innerHTML = `
            <div style="display:flex; align-items:center; gap:12px; flex-wrap:wrap; justify-content:space-between; width:100%;">
              <div style="display:flex; align-items:center; gap:12px;">
                <div style="background:#fef3c7; color:#d97706; width:40px; height:40px; border-radius:10px; display:flex; align-items:center; justify-content:center;">
                  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M22 12h-6l-2 3h-4l-2-3H2"></path>
                    <path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
                  </svg>
                </div>
                <div>
                  <h4 style="margin:0; font-size:0.95rem; font-weight:700; color:#92400e;">
                    ${count} Clerk Docket${count > 1 ? 's' : ''} Awaiting Your Approval
                  </h4>
                  <p style="margin:2px 0 0; font-size:0.82rem; color:#b45309;">
                    Submitted by your clerks/secretaries. Review the physical dockets, verify pricing, and commit them to your encrypted ledger.
                  </p>
                </div>
              </div>
              <button class="btn btn-sm btn-primary" onclick="navigateTo('clerk-submissions')" style="white-space:nowrap; background:#d97706; border-color:#d97706;">
                Review Dockets →
              </button>
            </div>
          `;
          banner.style.display = 'block';
          banner.style.background = 'linear-gradient(135deg, #fffbeb, #fef3c7)';
          banner.style.border = '1px solid #fde68a';
          banner.style.borderRadius = 'var(--radius)';
          banner.style.padding = '14px 18px';
        } else {
          banner.style.display = 'none';
        }
      }
    } catch (e) {
      console.warn('[Staging] Failed to update pending badge:', e);
    }
  }
};

// Periodically check for new clerk submissions every 30 seconds
setInterval(() => {
  if (typeof StagingDB !== 'undefined' && typeof StagingDB.updatePendingCountBadge === 'function') {
    StagingDB.updatePendingCountBadge();
  }
}, 30000);
