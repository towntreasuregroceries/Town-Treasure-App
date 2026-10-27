/* ══ Data Layer ══ */

// === Crypto Utilities for E2EE ===
const Crypto = {
  /**
   * Derive encryption key with per-user salt (v2).
   * If userId is provided, uses a unique salt per user for stronger isolation.
   * Falls back to legacy static salt if userId is omitted.
   */
  async deriveKey(password, userId) {
    const enc = new TextEncoder();
    const saltStr = userId ? `ttg-vault-v2-${userId}` : "town-treasure-secure-salt-v1";
    const salt = enc.encode(saltStr);
    const keyMaterial = await crypto.subtle.importKey(
      "raw", enc.encode(password), { name: "PBKDF2" }, false, ["deriveBits", "deriveKey"]
    );
    const key = await crypto.subtle.deriveKey(
      { name: "PBKDF2", salt: salt, iterations: 100000, hash: "SHA-256" },
      keyMaterial,
      { name: "AES-GCM", length: 256 },
      true,
      ["encrypt", "decrypt"]
    );
    return await crypto.subtle.exportKey("jwk", key);
  },

  /** Legacy key derivation (static salt) — used for migration fallback only */
  async deriveKeyLegacy(password) {
    const enc = new TextEncoder();
    const salt = enc.encode("town-treasure-secure-salt-v1");
    const keyMaterial = await crypto.subtle.importKey(
      "raw", enc.encode(password), { name: "PBKDF2" }, false, ["deriveBits", "deriveKey"]
    );
    const key = await crypto.subtle.deriveKey(
      { name: "PBKDF2", salt: salt, iterations: 100000, hash: "SHA-256" },
      keyMaterial,
      { name: "AES-GCM", length: 256 },
      true,
      ["encrypt", "decrypt"]
    );
    return await crypto.subtle.exportKey("jwk", key);
  },

  async encrypt(dataObj, jwkKey) {
    if (!jwkKey) throw new Error("Missing encryption key");
    const key = await crypto.subtle.importKey("jwk", jwkKey, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const enc = new TextEncoder();
    const cipherText = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: iv }, key, enc.encode(JSON.stringify(dataObj))
    );
    const payload = new Uint8Array(iv.length + cipherText.byteLength);
    payload.set(iv, 0);
    payload.set(new Uint8Array(cipherText), iv.length);
    return Crypto.bufferToBase64(payload);
  },

  async decrypt(base64Str, jwkKey) {
    if (!jwkKey || !base64Str) return null;
    try {
      const key = await crypto.subtle.importKey("jwk", jwkKey, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
      const payload = Crypto.base64ToBuffer(base64Str);
      const iv = payload.slice(0, 12);
      const cipherText = payload.slice(12);
      const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv }, key, cipherText);
      const dec = new TextDecoder();
      return JSON.parse(dec.decode(decrypted));
    } catch(e) {
      console.error("Decryption failed", e);
      return null;
    }
  },

  bufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    const len = bytes.byteLength;
    const chunkSize = 0x8000; 
    for (let i = 0; i < len; i += chunkSize) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  },

  base64ToBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }
};

const state = {
  restaurants: JSON.parse(localStorage.getItem('ttg_restaurants') || '[]'),
  deletedRestaurantIds: JSON.parse(localStorage.getItem('ttg_deleted_restaurant_ids') || '[]'),
  invoices: JSON.parse(localStorage.getItem('ttg_invoices') || '[]'),
  deletedInvoiceIds: JSON.parse(localStorage.getItem('ttg_deleted_invoice_ids') || '[]'),
  restoredInvoiceIds: JSON.parse(localStorage.getItem('ttg_restored_invoice_ids') || '[]'),
  recordActions: JSON.parse(localStorage.getItem('ttg_record_actions') || '{}'),
  expenses: JSON.parse(localStorage.getItem('ttg_expenses') || '[]'),
  deletedInvoices: JSON.parse(localStorage.getItem('ttg_deleted_invoices') || '[]'),
  staff: JSON.parse(localStorage.getItem('ttg_staff') || '[]'),
  salaryPayments: JSON.parse(localStorage.getItem('ttg_salary_payments') || '[]'),
  recurringExpenses: JSON.parse(localStorage.getItem('ttg_recurring_expenses') || '[]'),
  priceLists: JSON.parse(localStorage.getItem('ttg_price_lists') || '[]'),
  deletedStaff: JSON.parse(localStorage.getItem('ttg_deleted_staff') || '[]'),
  deletedPriceLists: JSON.parse(localStorage.getItem('ttg_deleted_pricelists') || '[]'),
  borrowings: JSON.parse(localStorage.getItem('ttg_borrowings') || '[]'),
  settings: JSON.parse(localStorage.getItem('ttg_settings') || '{}'),
  nextInvNum: 1001
};

function mergeRecordActions(local = {}, remote = {}) {
  const merged = {};
  new Set([...Object.keys(local || {}), ...Object.keys(remote || {})]).forEach(collection => {
    const ids = new Set([...Object.keys(local?.[collection] || {}), ...Object.keys(remote?.[collection] || {})]);
    merged[collection] = {};
    ids.forEach(id => {
      const a = local?.[collection]?.[id] || {};
      const b = remote?.[collection]?.[id] || {};
      const deletedAt = Math.max(Number(a.deletedAt || 0), Number(b.deletedAt || 0));
      const restoredAt = Math.max(Number(a.restoredAt || 0), Number(b.restoredAt || 0));
      merged[collection][id] = { deletedAt, restoredAt };
    });
  });
  return merged;
}

function isRecordDeleted(actions, collection, id) {
  const action = actions?.[collection]?.[id];
  return !!action && Number(action.deletedAt || 0) > 0 && Number(action.deletedAt || 0) >= Number(action.restoredAt || 0);
}

function includeLegacyDeleteBins(actions, collection, records = []) {
  const result = { ...(actions || {}) };
  const byId = { ...(result[collection] || {}) };
  (Array.isArray(records) ? records : []).forEach(item => {
    if (!item?.id) return;
    const current = byId[item.id] || {};
    const deletedAt = Date.parse(item.deletedAt || '') || 1;
    byId[item.id] = { ...current, deletedAt: Math.max(Number(current.deletedAt || 0), deletedAt) };
  });
  result[collection] = byId;
  return result;
}

function includeLegacyInvoiceActions(actions, deletedIds = [], restoredIds = [], deletedRecords = [], activeRecords = []) {
  const result = { ...(actions || {}) };
  const byId = { ...(result.invoices || {}) };
  const deletedSet = new Set(deletedIds || []);
  const restoredSet = new Set(restoredIds || []);
  const deletedById = new Map((deletedRecords || []).filter(item => item?.id).map(item => [item.id, item]));
  const activeIds = new Set((activeRecords || []).filter(item => item?.id).map(item => item.id));
  const ids = new Set([...deletedSet, ...restoredSet, ...deletedById.keys()]);
  ids.forEach(id => {
    const current = byId[id];
    if (current && (Number(current.deletedAt || 0) > 0 || Number(current.restoredAt || 0) > 0)) return;
    // Old vaults stored tombstone IDs without action times. Treat legacy restore
    // markers as newer only when an active invoice copy is present.
    const deletedAt = (deletedSet.has(id) || deletedById.has(id)) ? 1 : 0;
    const restoredAt = restoredSet.has(id) && activeIds.has(id) ? 2 : 0;
    byId[id] = { deletedAt, restoredAt };
  });
  result.invoices = byId;
  return result;
}

function normalizeAppDate(value) {
  if (!value) return '';
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
  }
  const text = String(value).trim();
  let match = text.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (match) return `${match[1]}-${match[2]}-${match[3]}`;
  match = text.match(/^(\d{8})$/);
  if (match) {
    const compact = match[1];
    const yearFirst = [Number(compact.slice(0, 4)), Number(compact.slice(4, 6)), Number(compact.slice(6, 8))];
    const dayFirst = [Number(compact.slice(4, 8)), Number(compact.slice(2, 4)), Number(compact.slice(0, 2))];
    const isValid = ([year, month, day]) => {
      if (year < 1000 || month < 1 || month > 12 || day < 1 || day > 31) return false;
      const candidate = new Date(year, month - 1, day);
      return candidate.getFullYear() === year && candidate.getMonth() === month - 1 && candidate.getDate() === day;
    };
    if (isValid(yearFirst)) return `${compact.slice(0, 4)}-${compact.slice(4, 6)}-${compact.slice(6, 8)}`;
    if (isValid(dayFirst)) return `${compact.slice(4, 8)}-${compact.slice(2, 4)}-${compact.slice(0, 2)}`;
    return '';
  }
  match = text.match(/^(\d{2})[/-](\d{2})[/-](\d{4})$/);
  if (match) return `${match[3]}-${match[2]}-${match[1]}`;
  const parsed = new Date(text);
  if (Number.isNaN(parsed.getTime())) return '';
  return `${parsed.getFullYear()}-${String(parsed.getMonth() + 1).padStart(2, '0')}-${String(parsed.getDate()).padStart(2, '0')}`;
}

function parseAppDate(value) {
  const iso = normalizeAppDate(value);
  if (!iso) return new Date(NaN);
  const [year, month, day] = iso.split('-').map(Number);
  return new Date(year, month - 1, day);
}

function appDateKey(value) {
  return normalizeAppDate(value).replace(/-/g, '') || '00000000';
}

function mergeRecordsById(local = [], remote = [], collection, actions = {}, deletedBin = false) {
  const map = new Map();
  const unkeyed = [];
  const all = [...(Array.isArray(remote) ? remote : []), ...(Array.isArray(local) ? local : [])];
  all.forEach(item => {
    if (!item || !item.id) { if (item) unkeyed.push(item); return; }
    if (isRecordDeleted(actions, collection, item.id) !== deletedBin) return;
    const current = map.get(item.id);
    const freshness = record => Date.parse(record.updatedAt || record.createdAt || record.deletedAt || 0) || 0;
    if (!current || freshness(item) > freshness(current)) map.set(item.id, item);
  });
  return [...map.values(), ...unkeyed];
}

function mergeInvoicesById(local = [], remote = [], actions = {}) {
  const map = new Map();
  const unkeyed = [];
  [...(Array.isArray(remote) ? remote : []), ...(Array.isArray(local) ? local : [])].forEach(invoice => {
    if (!invoice) return;
    if (invoice.id && isRecordDeleted(actions, 'invoices', invoice.id)) return;
    const key = invoice.id ? `id:${invoice.id}` : (invoice.number ? `number:${String(invoice.number).trim().toUpperCase()}` : '');
    if (!key) {
      if (!unkeyed.some(item => JSON.stringify(item) === JSON.stringify(invoice))) unkeyed.push(invoice);
      return;
    }
    const current = map.get(key);
    const freshness = record => Date.parse(record.updatedAt || record.createdAt || 0) || 0;
    if (!current || freshness(invoice) > freshness(current)) map.set(key, invoice);
  });
  return [...map.values(), ...unkeyed];
}

function mergeRestaurantsById(local = [], remote = [], deletedIds = []) {
  const deleted = new Set(deletedIds || []);
  const map = new Map();
  [...(Array.isArray(remote) ? remote : []), ...(Array.isArray(local) ? local : [])].forEach(item => {
    if (!item || !item.id || deleted.has(item.id)) return;
    const current = map.get(item.id);
    const freshness = restaurant => Date.parse(restaurant.updatedAt || restaurant.createdAt || 0) || 0;
    if (!current || freshness(item) > freshness(current)) map.set(item.id, item);
  });
  return Array.from(map.values());
}

function mergeSettingsByTimestamp(local = {}, remote = {}) {
  const localTime = Date.parse(local.updatedAt || 0) || 0;
  const remoteTime = Date.parse(remote.updatedAt || 0) || 0;
  return localTime > remoteTime ? { ...remote, ...local } : { ...local, ...remote };
}

function isMissingVaultRevisionColumn(error) {
  const code = String(error?.code || '');
  const details = `${error?.message || ''} ${error?.details || ''}`.toLowerCase();
  return ['42703', 'PGRST204'].includes(code) && details.includes('revision');
}

const DB = {
  get restaurants() { return state.restaurants; },
  set restaurants(v) { state.restaurants = v; localStorage.setItem('ttg_restaurants', JSON.stringify(v)); this.syncToSupabase(); },
  get deletedRestaurantIds() { return state.deletedRestaurantIds; },
  set deletedRestaurantIds(v) { state.deletedRestaurantIds = Array.isArray(v) ? v : []; localStorage.setItem('ttg_deleted_restaurant_ids', JSON.stringify(state.deletedRestaurantIds)); this.syncToSupabase(); },
  get invoices() { return state.invoices; },
  set invoices(v) { state.invoices = v; localStorage.setItem('ttg_invoices', JSON.stringify(v)); this.syncToSupabase(); },
  get deletedInvoiceIds() { return state.deletedInvoiceIds; },
  set deletedInvoiceIds(v) { state.deletedInvoiceIds = Array.isArray(v) ? v : []; localStorage.setItem('ttg_deleted_invoice_ids', JSON.stringify(state.deletedInvoiceIds)); this.syncToSupabase(); },
  get restoredInvoiceIds() { return state.restoredInvoiceIds; },
  set restoredInvoiceIds(v) { state.restoredInvoiceIds = Array.isArray(v) ? v : []; localStorage.setItem('ttg_restored_invoice_ids', JSON.stringify(state.restoredInvoiceIds)); this.syncToSupabase(); },
  get recordActions() { return state.recordActions; },
  set recordActions(v) { state.recordActions = v && typeof v === 'object' ? v : {}; localStorage.setItem('ttg_record_actions', JSON.stringify(state.recordActions)); this.syncToSupabase(); },
  get expenses() { return state.expenses; },
  set expenses(v) { state.expenses = v; localStorage.setItem('ttg_expenses', JSON.stringify(v)); this.syncToSupabase(); },
  get deletedInvoices() { return state.deletedInvoices; },
  set deletedInvoices(v) { state.deletedInvoices = v; localStorage.setItem('ttg_deleted_invoices', JSON.stringify(v)); this.syncToSupabase(); },
  get staff() { return state.staff; },
  set staff(v) { state.staff = v; localStorage.setItem('ttg_staff', JSON.stringify(v)); this.syncToSupabase(); },
  get salaryPayments() { return state.salaryPayments; },
  set salaryPayments(v) { state.salaryPayments = v; localStorage.setItem('ttg_salary_payments', JSON.stringify(v)); this.syncToSupabase(); },
  get recurringExpenses() { return state.recurringExpenses; },
  set recurringExpenses(v) { state.recurringExpenses = v; localStorage.setItem('ttg_recurring_expenses', JSON.stringify(v)); this.syncToSupabase(); },
  get priceLists() { return state.priceLists; },
  set priceLists(v) { state.priceLists = v; localStorage.setItem('ttg_price_lists', JSON.stringify(v)); this.syncToSupabase(); },
  get deletedStaff() { return state.deletedStaff; },
  set deletedStaff(v) { state.deletedStaff = v; localStorage.setItem('ttg_deleted_staff', JSON.stringify(v)); this.syncToSupabase(); },
  get deletedPriceLists() { return state.deletedPriceLists; },
  set deletedPriceLists(v) { state.deletedPriceLists = v; localStorage.setItem('ttg_deleted_pricelists', JSON.stringify(v)); this.syncToSupabase(); },
  get borrowings() { return state.borrowings; },
  set borrowings(v) { state.borrowings = v; localStorage.setItem('ttg_borrowings', JSON.stringify(v)); this.syncToSupabase(); },
  get settings() { return state.settings; },
  set settings(v) { state.settings = v; localStorage.setItem('ttg_settings', JSON.stringify(v)); this.syncToSupabase(); },
  
  get nextInvNum() {
    if (state.invoices.length === 0) return state.nextInvNum;
    let maxNum = 1000;
    state.invoices.forEach(i => {
      const numStr = i.number ? i.number.replace('TTG-', '') : '';
      const numPart = parseInt(numStr, 10);
      if (!isNaN(numPart) && numPart > maxNum) maxNum = numPart;
    });
    return maxNum + 1;
  },
  set nextInvNum(v) { /* Computed dynamically, ignore sets */ },
  
  // Debounce timer for sync — prevents hammering Supabase on every keystroke
  _syncTimer: null,
  _syncVersion: 0,
  _syncInFlight: null,
  _syncRequestedAgain: false,
  _remoteRevision: null,

  markRecordDeleted(collection, id) {
    if (!collection || !id) return;
    const actions = { ...(state.recordActions || {}) };
    const records = { ...(actions[collection] || {}) };
    records[id] = { deletedAt: Date.now(), restoredAt: Number(records[id]?.restoredAt || 0) };
    actions[collection] = records;
    this.recordActions = actions;
  },

  markRecordRestored(collection, id) {
    if (!collection || !id) return;
    const actions = { ...(state.recordActions || {}) };
    const records = { ...(actions[collection] || {}) };
    records[id] = { deletedAt: Number(records[id]?.deletedAt || 0), restoredAt: Date.now() };
    actions[collection] = records;
    this.recordActions = actions;
  },

  async syncToSupabase() {
    // Debounce: wait 3 seconds of inactivity before syncing
    if (this._syncTimer) clearTimeout(this._syncTimer);
    this._syncTimer = setTimeout(() => {
      this._syncTimer = null;
      this._doSync();
    }, 3000);
  },

  async _doSync() {
    if (this._syncInFlight) {
      this._syncRequestedAgain = true;
      return this._syncInFlight;
    }
    this._syncInFlight = (async () => {
      let result;
      do {
        this._syncRequestedAgain = false;
        result = await this._performSync();
      } while (this._syncRequestedAgain);
      return result;
    })();
    try {
      return await this._syncInFlight;
    } finally {
      this._syncInFlight = null;
    }
  },

  async _performSync() {
    if (!supabaseClient) return false;
    const uid = getUserId();
    if (!uid) return false; // Not logged in, skip sync
    
    const e2eKeyStr = localStorage.getItem('ttg_e2e_key');
    if (!e2eKeyStr) {
      console.warn("No E2EE key found. Sync skipped.");
      return false;
    }

    try {
      const jwkKey = JSON.parse(e2eKeyStr);

      // Revision compare-and-swap prevents two devices from overwriting each
      // other's changes. Never fall back to an unguarded vault write.
      for (let attempt = 1; attempt <= 3; attempt++) {
        let { data: remoteRow, error: remoteReadError } = await supabaseClient
          .from('encrypted_vault')
          .select('data, revision')
          .eq('user_id', uid)
          .maybeSingle();
        if (isMissingVaultRevisionColumn(remoteReadError)) {
          const migrationError = new Error('Server revision protection is not available. Cloud sync was stopped to protect existing records; apply supabase_vault_revision.sql and retry.');
          migrationError.code = 'VAULT_REVISION_MIGRATION_MISSING';
          throw migrationError;
        }
        if (remoteReadError) throw remoteReadError;
        const expectedRevision = Number(remoteRow?.revision ?? 0);
        if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0) {
          throw new Error('The server returned an invalid vault revision; sync was stopped to protect existing records.');
        }
        this._remoteRevision = expectedRevision;

        if (remoteRow && remoteRow.data) {
          const remoteVault = await Crypto.decrypt(remoteRow.data, jwkKey);
          if (!remoteVault || typeof remoteVault !== 'object') {
            throw new Error('Could not decrypt the current vault; sync was stopped to protect existing records.');
          }
          {
            state.recordActions = mergeRecordActions(state.recordActions, remoteVault.recordActions || {});
            state.recordActions = includeLegacyInvoiceActions(
              state.recordActions,
              [...(state.deletedInvoiceIds || []), ...(remoteVault.deletedInvoiceIds || [])],
              [...(state.restoredInvoiceIds || []), ...(remoteVault.restoredInvoiceIds || [])],
              [...(state.deletedInvoices || []), ...(remoteVault.deletedInvoices || [])],
              [...(state.invoices || []), ...(remoteVault.invoices || [])]
            );
            const invoiceActions = state.recordActions.invoices || {};
            const deletedInvoiceIds = new Set(Object.keys(invoiceActions).filter(id => isRecordDeleted(state.recordActions, 'invoices', id)));
            const restoredInvoiceIds = new Set(Object.keys(invoiceActions).filter(id => !isRecordDeleted(state.recordActions, 'invoices', id) && Number(invoiceActions[id].restoredAt || 0) > 0));
            state.restoredInvoiceIds = Array.from(restoredInvoiceIds);
            state.deletedInvoiceIds = Array.from(deletedInvoiceIds);

            // Merge by immutable invoice ID, keep the newest edit, and honor
            // delete/restore tombstones so stale snapshots cannot resurrect records.
            state.invoices = mergeInvoicesById(state.invoices, remoteVault.invoices, state.recordActions).sort((a, b) =>
              appDateKey(b.date).localeCompare(appDateKey(a.date))
              || String(b.createdAt || '').localeCompare(String(a.createdAt || ''))
            );
            localStorage.setItem('ttg_invoices', JSON.stringify(state.invoices));
            state.deletedInvoices = mergeRecordsById(state.deletedInvoices, remoteVault.deletedInvoices, 'invoices', state.recordActions, true);
            localStorage.setItem('ttg_deleted_invoices', JSON.stringify(state.deletedInvoices));
            localStorage.setItem('ttg_deleted_invoice_ids', JSON.stringify(state.deletedInvoiceIds));
            localStorage.setItem('ttg_restored_invoice_ids', JSON.stringify(state.restoredInvoiceIds));

            // A deletion tombstone prevents intentional restaurant removals from
            // being resurrected by the safety merge from a stale remote snapshot.
            const deletedRestaurantIds = new Set([
              ...(state.deletedRestaurantIds || []),
              ...(remoteVault.deletedRestaurantIds || [])
            ]);
            state.deletedRestaurantIds = Array.from(deletedRestaurantIds);
            localStorage.setItem('ttg_deleted_restaurant_ids', JSON.stringify(state.deletedRestaurantIds));
            state.restaurants = mergeRestaurantsById(state.restaurants, remoteVault.restaurants, deletedRestaurantIds);
            localStorage.setItem('ttg_restaurants', JSON.stringify(state.restaurants));

            // Merge other records by ID before writing the single encrypted vault row.
            // This preserves offline additions and prevents overlapping syncs from
            // replacing unrelated collections with an older in-memory snapshot.
            state.recordActions = includeLegacyDeleteBins(state.recordActions, 'staff', [...(state.deletedStaff || []), ...(remoteVault.deletedStaff || [])]);
            state.recordActions = includeLegacyDeleteBins(state.recordActions, 'priceLists', [...(state.deletedPriceLists || []), ...(remoteVault.deletedPriceLists || [])]);
            const genericCollections = ['expenses', 'staff', 'salaryPayments', 'recurringExpenses', 'priceLists', 'borrowings'];
            genericCollections.forEach(collection => {
              state[collection] = mergeRecordsById(state[collection], remoteVault[collection], collection, state.recordActions);
            });
            state.deletedStaff = mergeRecordsById(state.deletedStaff, remoteVault.deletedStaff, 'staff', state.recordActions, true);
            state.deletedPriceLists = mergeRecordsById(state.deletedPriceLists, remoteVault.deletedPriceLists, 'priceLists', state.recordActions, true);
            state.settings = mergeSettingsByTimestamp(state.settings, remoteVault.settings || {});
            localStorage.setItem('ttg_record_actions', JSON.stringify(state.recordActions));
            genericCollections.forEach(collection => localStorage.setItem(`ttg_${collection === 'salaryPayments' ? 'salary_payments' : collection === 'recurringExpenses' ? 'recurring_expenses' : collection}`, JSON.stringify(state[collection])));
            localStorage.setItem('ttg_staff', JSON.stringify(state.staff));
            localStorage.setItem('ttg_price_lists', JSON.stringify(state.priceLists));
            localStorage.setItem('ttg_deleted_staff', JSON.stringify(state.deletedStaff));
            localStorage.setItem('ttg_deleted_pricelists', JSON.stringify(state.deletedPriceLists));
            localStorage.setItem('ttg_settings', JSON.stringify(state.settings));
          }
        }
        this._syncVersion++;
        const appState = {
          _vaultVersion: this._syncVersion,
          _lastSync: new Date().toISOString(),
          invoices: state.invoices,
          deletedInvoiceIds: state.deletedInvoiceIds,
          restoredInvoiceIds: state.restoredInvoiceIds,
          recordActions: state.recordActions,
          expenses: state.expenses,
          restaurants: state.restaurants,
          deletedRestaurantIds: state.deletedRestaurantIds,
          deletedInvoices: state.deletedInvoices,
          staff: state.staff,
          salaryPayments: state.salaryPayments,
          recurringExpenses: state.recurringExpenses,
          priceLists: state.priceLists,
          deletedStaff: state.deletedStaff,
          deletedPriceLists: state.deletedPriceLists,
          borrowings: state.borrowings,
          settings: state.settings
        };
        const encryptedPayload = await Crypto.encrypt(appState, jwkKey);
        const { data: saveResult, error: saveError } = await supabaseClient.rpc('save_encrypted_vault_cas', {
          p_user_id: uid,
          p_expected_revision: expectedRevision,
          p_data: encryptedPayload
        });
        if (saveError) throw saveError;
        const returnedRevision = Number(saveResult?.revision);
        if (typeof saveResult?.saved !== 'boolean' || !Number.isSafeInteger(returnedRevision) || returnedRevision < 0) {
          throw new Error('The server returned an invalid compare-and-swap result; sync was stopped.');
        }

        if (saveResult?.saved === true) {
          if (returnedRevision !== expectedRevision + 1) {
            throw new Error('The server returned an unexpected vault revision; sync was stopped.');
          }
          this._remoteRevision = returnedRevision;
          console.log('Successfully synced encrypted vault (server revision ' + this._remoteRevision + ', ' + state.invoices.length + ' invoices)');
          return true;
        }

        this._remoteRevision = returnedRevision;
        if (attempt < 3) {
          console.warn('[Vault] Another device saved first; refreshing and merging before retry', {
            attemptedRevision: expectedRevision,
            currentRevision: this._remoteRevision
          });
          continue;
        }
        const conflict = new Error('The vault kept changing on another device. Your local data is safe; sync needs another attempt.');
        conflict.code = 'VAULT_REVISION_CONFLICT';
        throw conflict;
      }
      return false;
    } catch (e) {
      console.error(`Error syncing vault to Supabase:`, e);
      const now = Date.now();
      if (!window.lastOfflineToast || now - window.lastOfflineToast > 5000) {
        const message = e?.code === 'VAULT_REVISION_CONFLICT'
          ? 'Sync paused because the vault is changing on another device. Your local data is saved; try syncing again shortly.'
          : e?.code === 'VAULT_REVISION_MIGRATION_MISSING'
            ? 'Cloud sync paused because server revision protection is missing. Your local data is preserved; contact the account owner before switching devices.'
            : 'Offline mode: Data saved locally.';
        if (typeof toast === 'function') toast(message, 'warning');
        window.lastOfflineToast = now;
      }
      return false;
    }
  },

  /** Force an immediate sync (bypasses debounce) */
  async syncNow() {
    if (this._syncTimer) clearTimeout(this._syncTimer);
    this._syncTimer = null;
    return await this._doSync();
  },

  /** Read the current server ledger without merging browser-cache records into it. */
  async getRemoteInvoiceSnapshot() {
    if (!supabaseClient || !getUserId()) return { ok: false, invoices: [] };
    const keyString = localStorage.getItem('ttg_e2e_key');
    if (!keyString) return { ok: false, invoices: [] };

    try {
      let { data, error } = await supabaseClient
        .from('encrypted_vault')
        .select('data, revision')
        .eq('user_id', getUserId())
        .maybeSingle();
      if (isMissingVaultRevisionColumn(error)) {
        ({ data, error } = await supabaseClient
          .from('encrypted_vault')
          .select('data')
          .eq('user_id', getUserId())
          .maybeSingle());
      }
      if (error) throw error;
      if (!data?.data) return { ok: true, invoices: [], revision: Number(data?.revision || 0) };

      const vault = await Crypto.decrypt(data.data, JSON.parse(keyString));
      if (!vault || typeof vault !== 'object') throw new Error('Could not decrypt the current server vault.');
      const actions = includeLegacyInvoiceActions(
        vault.recordActions || {},
        vault.deletedInvoiceIds || [],
        vault.restoredInvoiceIds || [],
        vault.deletedInvoices || [],
        vault.invoices || []
      );
      const invoices = mergeInvoicesById([], vault.invoices || [], actions)
        .filter(invoice => invoice && invoice.status !== 'draft');
      return { ok: true, invoices, revision: Number(data.revision ?? 0) };
    } catch (error) {
      console.error('[Vault] Could not read current server invoice snapshot:', error);
      return { ok: false, invoices: [] };
    }
  },

  /** Re-encrypt a vault after its old key was verified by loadFromSupabase(). */
  async reencryptVault(jwkKey) {
    if (!supabaseClient || !getUserId() || !jwkKey) return false;
    try {
      const appState = {
        _vaultVersion: ++this._syncVersion,
        _lastSync: new Date().toISOString(),
        invoices: state.invoices,
        deletedInvoiceIds: state.deletedInvoiceIds,
        restoredInvoiceIds: state.restoredInvoiceIds,
        recordActions: state.recordActions,
        expenses: state.expenses,
        restaurants: state.restaurants,
        deletedRestaurantIds: state.deletedRestaurantIds,
        deletedInvoices: state.deletedInvoices,
        staff: state.staff,
        salaryPayments: state.salaryPayments,
        recurringExpenses: state.recurringExpenses,
        priceLists: state.priceLists,
        deletedStaff: state.deletedStaff,
        deletedPriceLists: state.deletedPriceLists,
        borrowings: state.borrowings,
        settings: state.settings
      };
      const encryptedPayload = await Crypto.encrypt(appState, jwkKey);
      if (Number.isSafeInteger(this._remoteRevision) && this._remoteRevision >= 0) {
        const { data: saveResult, error } = await supabaseClient.rpc('save_encrypted_vault_cas', {
          p_user_id: getUserId(),
          p_expected_revision: this._remoteRevision,
          p_data: encryptedPayload
        });
        if (error) throw error;
        if (saveResult?.saved !== true) throw new Error('Vault changed during key migration; no server data was overwritten.');
        const returnedRevision = Number(saveResult.revision);
        if (!Number.isSafeInteger(returnedRevision) || returnedRevision !== this._remoteRevision + 1) {
          throw new Error('The server returned an unexpected vault revision during key migration.');
        }
        this._remoteRevision = returnedRevision;
      } else {
        throw new Error('Server revision protection is not available; key migration write was stopped.');
      }
      return true;
    } catch (error) {
      console.error('[E2EE] Vault key migration write failed:', error);
      return false;
    }
  },
  
  async loadFromSupabase() {
    if (!supabaseClient) return false;
    this._remoteRevision = null;
    const uid = getUserId();
    if (!uid) return false; // Not logged in
    
    const e2eKeyStr = localStorage.getItem('ttg_e2e_key');
    if (!e2eKeyStr) {
      console.warn("No E2EE key found. Loading skipped.");
      return false;
    }

    const localDeletedRestaurantIds = new Set(state.deletedRestaurantIds || []);
    const localRestaurants = (state.restaurants || []).slice();
    const localSettings = { ...(state.settings || {}) };
    const localInvoices = (state.invoices || []).slice();
    const localDeletedInvoices = (state.deletedInvoices || []).slice();
    const localDeletedInvoiceIds = new Set(state.deletedInvoiceIds || []);
    const localRestoredInvoiceIds = new Set(state.restoredInvoiceIds || []);
    const localRecordActions = state.recordActions || {};
    const localGenericCollections = ['expenses', 'staff', 'salaryPayments', 'recurringExpenses', 'priceLists', 'borrowings']
      .reduce((acc, key) => (acc[key] = (state[key] || []).slice(), acc), {});
    const localDeletedStaff = (state.deletedStaff || []).slice();
    const localDeletedPriceLists = (state.deletedPriceLists || []).slice();

    try {
      let revisionSupport = true;
      let { data, error } = await supabaseClient
        .from('encrypted_vault')
        .select('data, revision')
        .eq('user_id', uid)
        .single();
      if (isMissingVaultRevisionColumn(error)) {
        revisionSupport = false;
        ({ data, error } = await supabaseClient
          .from('encrypted_vault')
          .select('data')
          .eq('user_id', uid)
          .single());
      }

      if (error && error.code !== 'PGRST116') throw error; // Ignore "no rows" error

      if (data && data.data) {
        this._remoteRevision = revisionSupport ? Number(data.revision ?? 0) : null;
        if (revisionSupport && (!Number.isSafeInteger(this._remoteRevision) || this._remoteRevision < 0)) {
          throw new Error('The server returned an invalid vault revision.');
        }
        // Decrypt the payload
        const jwkKey = JSON.parse(e2eKeyStr);
        const appState = await Crypto.decrypt(data.data, jwkKey);
        
        if (appState) {
          state.recordActions = mergeRecordActions(localRecordActions, appState.recordActions || {});
          state.recordActions = includeLegacyInvoiceActions(
            state.recordActions,
            [...localDeletedInvoiceIds, ...(appState.deletedInvoiceIds || [])],
            [...localRestoredInvoiceIds, ...(appState.restoredInvoiceIds || [])],
            [...localDeletedInvoices, ...(appState.deletedInvoices || [])],
            [...localInvoices, ...(appState.invoices || [])]
          );
          state.recordActions = includeLegacyDeleteBins(state.recordActions, 'staff', [...localDeletedStaff, ...(appState.deletedStaff || [])]);
          state.recordActions = includeLegacyDeleteBins(state.recordActions, 'priceLists', [...localDeletedPriceLists, ...(appState.deletedPriceLists || [])]);
          const invoiceActions = state.recordActions.invoices || {};
          const deletedInvoiceIds = new Set(Object.keys(invoiceActions).filter(id => isRecordDeleted(state.recordActions, 'invoices', id)));
          const restoredInvoiceIds = new Set(Object.keys(invoiceActions).filter(id => !isRecordDeleted(state.recordActions, 'invoices', id) && Number(invoiceActions[id].restoredAt || 0) > 0));
          const remoteInvoiceMap = new Map((appState.invoices || []).filter(Boolean).map(i => [i.id || (i.number ? `number:${String(i.number).trim().toUpperCase()}` : ''), i]));
          const freshness = inv => Date.parse(inv.updatedAt || inv.createdAt || 0) || 0;
          state.invoices = mergeInvoicesById(localInvoices, appState.invoices, state.recordActions).sort((a, b) =>
            appDateKey(b.date).localeCompare(appDateKey(a.date))
            || String(b.createdAt || '').localeCompare(String(a.createdAt || ''))
          );
          state.deletedInvoiceIds = Array.from(deletedInvoiceIds);
          state.restoredInvoiceIds = Array.from(restoredInvoiceIds);
          state.deletedInvoices = mergeRecordsById(localDeletedInvoices, appState.deletedInvoices, 'invoices', state.recordActions, true);
          const hasUnsyncedLocalInvoice = localInvoices.some(inv => {
            const key = inv?.id || (inv?.number ? `number:${String(inv.number).trim().toUpperCase()}` : '');
            if (!key || (inv.id && deletedInvoiceIds.has(inv.id))) return false;
            const remote = remoteInvoiceMap.get(key);
            return !remote || freshness(inv) > freshness(remote);
          }) || JSON.stringify(localRecordActions.invoices || {}) !== JSON.stringify((appState.recordActions || {}).invoices || {})
            || [...deletedInvoiceIds].some(id => !(appState.deletedInvoiceIds || []).includes(id))
            || [...restoredInvoiceIds].some(id => !(appState.restoredInvoiceIds || []).includes(id));
          const remoteDeletedRestaurantIds = new Set(appState.deletedRestaurantIds || []);
          const hasUnsyncedLocalRestaurantDeletion = [...localDeletedRestaurantIds]
            .some(id => !remoteDeletedRestaurantIds.has(id));
          // Keep local deletion tombstones during offline use, and merge them
          // with remote tombstones so other signed-in devices honor deletions.
          state.deletedRestaurantIds = Array.from(new Set([
            ...(state.deletedRestaurantIds || []),
            ...(appState.deletedRestaurantIds || [])
          ]));
          const genericCollections = ['expenses', 'staff', 'salaryPayments', 'recurringExpenses', 'priceLists', 'borrowings'];
          genericCollections.forEach(collection => {
            state[collection] = mergeRecordsById(localGenericCollections[collection], appState[collection], collection, state.recordActions);
          });
          state.deletedStaff = mergeRecordsById(localDeletedStaff, appState.deletedStaff, 'staff', state.recordActions, true);
          state.deletedPriceLists = mergeRecordsById(localDeletedPriceLists, appState.deletedPriceLists, 'priceLists', state.recordActions, true);
          state.restaurants = mergeRestaurantsById(localRestaurants, appState.restaurants, state.deletedRestaurantIds);
          state.settings = mergeSettingsByTimestamp(localSettings, appState.settings || {});
          
          localStorage.setItem('ttg_invoices', JSON.stringify(state.invoices));
          localStorage.setItem('ttg_deleted_invoice_ids', JSON.stringify(state.deletedInvoiceIds));
          localStorage.setItem('ttg_restored_invoice_ids', JSON.stringify(state.restoredInvoiceIds));
          localStorage.setItem('ttg_record_actions', JSON.stringify(state.recordActions));
          localStorage.setItem('ttg_expenses', JSON.stringify(state.expenses));
          localStorage.setItem('ttg_restaurants', JSON.stringify(state.restaurants));
          localStorage.setItem('ttg_deleted_restaurant_ids', JSON.stringify(state.deletedRestaurantIds));
          localStorage.setItem('ttg_deleted_invoices', JSON.stringify(state.deletedInvoices));
          localStorage.setItem('ttg_staff', JSON.stringify(state.staff));
          localStorage.setItem('ttg_salary_payments', JSON.stringify(state.salaryPayments));
          localStorage.setItem('ttg_recurring_expenses', JSON.stringify(state.recurringExpenses));
          localStorage.setItem('ttg_price_lists', JSON.stringify(state.priceLists));
          localStorage.setItem('ttg_deleted_staff', JSON.stringify(state.deletedStaff));
          localStorage.setItem('ttg_deleted_pricelists', JSON.stringify(state.deletedPriceLists));
          localStorage.setItem('ttg_borrowings', JSON.stringify(state.borrowings));
          localStorage.setItem('ttg_settings', JSON.stringify(state.settings));

          // Carry offline deletions back to the encrypted vault on reconnection.
          const hasUnsyncedGenericActions = JSON.stringify(localRecordActions) !== JSON.stringify(appState.recordActions || {});
          const hasUnsyncedGenericRecords = genericCollections.some(collection =>
            JSON.stringify(state[collection]) !== JSON.stringify(appState[collection] || []));
          const hasUnsyncedLocalRestaurantChanges = JSON.stringify(state.restaurants) !== JSON.stringify(appState.restaurants || [])
            || hasUnsyncedLocalRestaurantDeletion;
          const hasUnsyncedLocalSettings = JSON.stringify(state.settings) !== JSON.stringify(appState.settings || {});
          if (hasUnsyncedLocalRestaurantChanges || hasUnsyncedLocalInvoice || hasUnsyncedGenericActions || hasUnsyncedGenericRecords || hasUnsyncedLocalSettings) this.syncToSupabase();
          
          console.log('Loaded and decrypted data from vault');
          return true;
        } else {
          if (typeof toast === 'function') toast('Failed to decrypt data. Incorrect key?', 'error');
          return false;
        }
      }
      this._remoteRevision = revisionSupport ? 0 : null;
      return true; // No data yet
    } catch (e) {
      console.error('Error loading from vault:', e);
      if (typeof toast === 'function') toast('Offline mode: Using locally cached data', 'warning');
      return false;
    }
  },

  clearLocalData() {
    state.restaurants = [];
    state.deletedRestaurantIds = [];
    state.invoices = [];
    state.deletedInvoiceIds = [];
    state.restoredInvoiceIds = [];
    state.recordActions = {};
    state.expenses = [];
    state.deletedInvoices = [];
    state.staff = [];
    state.salaryPayments = [];
    state.recurringExpenses = [];
    state.priceLists = [];
    state.deletedStaff = [];
    state.deletedPriceLists = [];
    state.borrowings = [];
    state.settings = {};
    ['ttg_restaurants', 'ttg_deleted_restaurant_ids', 'ttg_invoices', 'ttg_deleted_invoice_ids', 'ttg_restored_invoice_ids', 'ttg_record_actions', 'ttg_expenses', 'ttg_deleted_invoices',
     'ttg_staff', 'ttg_salary_payments', 'ttg_recurring_expenses',
     'ttg_price_lists', 'ttg_deleted_staff', 'ttg_deleted_pricelists',
     'ttg_borrowings', 'ttg_settings'].forEach(k => localStorage.removeItem(k));
  }
};

/** Normalize restaurant names for safe exact-name and alias matching. */
function normalizeRestaurantName(name) {
  return String(name || '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/&/g, ' and ')
    .replace(/\b(the|hotel|hotels|restaurant|restaurants|suites|resort|club|inn|lodge|limited|ltd)\b/g, ' ')
    .replace(/[^a-z0-9]/g, '');
}

function restaurantNameEditSimilarity(a, b) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (Math.min(a.length, b.length) < 4) return 0;
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(
        current[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
      );
    }
    previous = current;
  }
  return 1 - previous[b.length] / Math.max(a.length, b.length);
}

function restaurantNameSimilarity(a, b) {
  const left = normalizeRestaurantName(a);
  const right = normalizeRestaurantName(b);
  if (!left || !right) return 0;
  const charScore = restaurantNameEditSimilarity(left, right);
  const tokens = value => new Set(String(value || '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/&/g, ' and ')
    .replace(/\b(the|hotel|hotels|restaurant|restaurants|suites|resort|club|inn|lodge|limited|ltd)\b/g, ' ')
    .match(/[a-z0-9]+/g) || []);
  const leftTokens = tokens(a);
  const rightTokens = tokens(b);
  const shared = [...leftTokens].filter(token => rightTokens.has(token)).length;
  const tokenScore = (2 * shared) / Math.max(1, leftTokens.size + rightTokens.size);
  // Shared distinctive words help with OCR word splits (for example,
  // "Thrive Kitchen" vs "Thrive Craft"), but the score is only a suggestion.
  // It never attaches an invoice without an exact alias or human confirmation.
  return Math.max(charScore, tokenScore);
}

/**
 * Resolve a supplied name conservatively. Exact unique names and aliases can be
 * used automatically; fuzzy matches are suggestions and require a person to
 * confirm them before the alias is learned.
 */
function resolveRestaurantName(name, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  const key = normalizeRestaurantName(name);
  const records = (restaurants || []).filter(r => r && r.id && r.name);
  if (!key) return { status: 'empty', restaurant: null, candidates: [] };

  const exact = records.filter(r => [r.name, ...(Array.isArray(r.aliases) ? r.aliases : [])]
    .some(value => normalizeRestaurantName(value) === key));
  if (exact.length === 1) {
    const restaurant = exact[0];
    const method = normalizeRestaurantName(restaurant.name) === key ? 'name' : 'alias';
    return { status: 'matched', restaurant, method, score: 1, candidates: [{ restaurant, score: 1 }] };
  }
  if (exact.length > 1) {
    return { status: 'ambiguous', restaurant: null, candidates: exact.map(restaurant => ({ restaurant, score: 1 })) };
  }
  if (key.length < 3) return { status: 'unmatched', restaurant: null, candidates: [] };

  const ranked = records.map(restaurant => {
    const variants = [restaurant.name, ...(Array.isArray(restaurant.aliases) ? restaurant.aliases : [])];
    const score = Math.max(0, ...variants.map(variant => restaurantNameSimilarity(name, variant)));
    return { restaurant, score };
  }).filter(candidate => candidate.score >= 0.50)
    .sort((a, b) => b.score - a.score || String(a.restaurant.name).localeCompare(String(b.restaurant.name)));
  const first = ranked[0];
  const second = ranked[1];
  if (!first) return { status: 'unmatched', restaurant: null, candidates: [] };
  const margin = first.score - (second?.score ?? 0);
  if (first.score >= 0.64 && margin >= 0.12) {
    return { status: 'suggested', restaurant: first.restaurant, score: first.score, candidates: ranked.slice(0, 3) };
  }
  if (first.score >= 0.62 && margin < 0.12) {
    return { status: 'ambiguous', restaurant: null, candidates: ranked.filter(item => first.score - item.score < 0.12).slice(0, 3) };
  }
  return { status: 'possible', restaurant: null, score: first.score, candidates: ranked.slice(0, 3) };
}

/** Return only an unambiguous exact name or alias match. */
function findRestaurantByName(name, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  const result = resolveRestaurantName(name, restaurants);
  return result.status === 'matched' ? result.restaurant : null;
}

/** Legacy helper: return near-match candidates, never treat them as matches. */
function findPotentialRestaurantMatches(name, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  return resolveRestaurantName(name, restaurants).candidates.map(candidate => candidate.restaurant);
}

/** Resolve legacy invoices by ID first, then by a unique exact name/alias. */
function resolveInvoiceRestaurant(invoice, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  if (!invoice) return { status: 'unmatched', restaurant: null, method: null };
  const records = restaurants || [];
  const byId = invoice.restaurantId && records.find(r => r && r.id === invoice.restaurantId);
  if (byId) return { status: 'matched', restaurant: byId, method: 'id' };
  const byName = resolveRestaurantName(invoice.restaurantName, records);
  return byName.status === 'matched'
    ? { ...byName, method: 'legacy-name' }
    : byName;
}

function invoiceBelongsToRestaurant(invoice, restaurant, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  const resolved = resolveInvoiceRestaurant(invoice, restaurants);
  return resolved.status === 'matched' && resolved.restaurant.id === restaurant?.id;
}

function invoiceRestaurantDisplayName(invoice, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  const resolved = resolveInvoiceRestaurant(invoice, restaurants);
  return resolved.status === 'matched' ? resolved.restaurant.name : (invoice?.restaurantName || 'Unknown');
}

function restaurantNameVariants(restaurant) {
  return [restaurant?.name, ...(Array.isArray(restaurant?.aliases) ? restaurant.aliases : [])]
    .map(value => String(value || '').trim())
    .filter(Boolean);
}

/** Find non-exact name overlaps for review; these are never auto-merged. */
function findSimilarRestaurantRecords(restaurant, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  if (!restaurant) return [];
  const variants = restaurantNameVariants(restaurant);
  return (restaurants || []).filter(other => other && other.id !== restaurant.id).map(other => ({
    restaurant: other,
    score: Math.max(0, ...variants.flatMap(a => restaurantNameVariants(other).map(b => restaurantNameSimilarity(a, b))))
  })).filter(candidate => candidate.score >= 0.50)
    .sort((a, b) => b.score - a.score || String(a.restaurant.name).localeCompare(String(b.restaurant.name)));
}

function restaurantOptionLabel(restaurant, restaurants = (typeof DB !== 'undefined' ? DB.restaurants : [])) {
  if (!restaurant) return '';
  const variants = new Set(restaurantNameVariants(restaurant).map(normalizeRestaurantName).filter(Boolean));
  const conflicts = (restaurants || []).filter(other => other && other.id !== restaurant.id
    && restaurantNameVariants(other).some(name => variants.has(normalizeRestaurantName(name))));
  const similar = findSimilarRestaurantRecords(restaurant, restaurants).filter(candidate => !conflicts.some(item => item.id === candidate.restaurant.id));
  const detail = [restaurant.address, restaurant.phone, restaurant.contact].filter(Boolean).join(' | ');
  const recordId = String(restaurant.id || '').slice(-6);
  if (conflicts.length) return `${restaurant.name} (${detail ? `${detail} | ` : ''}record ${recordId})`;
  if (similar.length) return `${restaurant.name} (possible duplicate: ${similar.slice(0, 2).map(item => item.restaurant.name).join(', ')})`;
  return restaurant.name || '';
}
/** Register a confirmed OCR spelling, refusing aliases already claimed elsewhere. */
function registerRestaurantAlias(restaurantId, alias) {
  const name = String(alias || '').trim();
  const key = normalizeRestaurantName(name);
  const records = (typeof DB !== 'undefined' && Array.isArray(DB.restaurants)) ? DB.restaurants : [];
  const target = records.find(r => r.id === restaurantId);
  if (!target || !key) return { ok: false, reason: 'invalid' };
  const conflicts = records.filter(r => r.id !== restaurantId
    && [r.name, ...(Array.isArray(r.aliases) ? r.aliases : [])].some(value => normalizeRestaurantName(value) === key));
  if (conflicts.length) return { ok: false, reason: 'conflict', conflicts };

  const aliases = Array.isArray(target.aliases) ? target.aliases.slice() : [];
  if ([target.name, ...aliases].some(value => normalizeRestaurantName(value) === key)) {
    return { ok: true, restaurant: target, changed: false };
  }
  aliases.push(name);
  const updated = { ...target, aliases, updatedAt: new Date().toISOString() };
  DB.restaurants = records.map(r => r.id === restaurantId ? updated : r);
  if (typeof DB.syncNow === 'function') DB.syncNow();
  if (typeof renderRestaurants === 'function') renderRestaurants();
  return { ok: true, restaurant: updated, changed: true };
}

function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
function fmtMoney(n) { return Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
function fmtDate(value) {
  if (!value) return '—';
  const date = parseAppDate(value);
  if (!date || Number.isNaN(date.getTime())) return String(value);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(date.getDate())}/${pad(date.getMonth() + 1)}/${date.getFullYear()}`;
}

/** Sanitize user input before inserting into innerHTML to prevent XSS */
function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  const s = String(str);
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}

/**
 * Attempt E2EE key migration: try per-user salt first, fall back to legacy.
 * Returns the working JWK key and whether migration occurred.
 * SAFE: Never destroys data — always falls back to old key.
 */
async function migrateE2EKey(password, userId) {
  // 1. Try new per-user key
  const newKey = await Crypto.deriveKey(password, userId);
  localStorage.setItem('ttg_e2e_key', JSON.stringify(newKey));

  // 2. Try loading vault with new key
  const loaded = await DB.loadFromSupabase();
  if (loaded) {
    // New key worked (either already migrated, or no data yet)
    localStorage.setItem('ttg_salt_version', '2');
    console.log('[E2EE] Per-user salt key working.');
    return { key: newKey, migrated: false };
  }

  // 3. New key failed — try legacy key (SAFE FALLBACK)
  console.log('[E2EE] Per-user key failed, trying legacy key...');
  const legacyKey = await Crypto.deriveKeyLegacy(password);
  localStorage.setItem('ttg_e2e_key', JSON.stringify(legacyKey));

  const legacyLoaded = await DB.loadFromSupabase();
  if (legacyLoaded) {
    // The old key successfully decrypted the current vault. Re-encrypt that
    // loaded state explicitly; normal sync now refuses unreadable remote data.
    console.log('[E2EE] Legacy key worked. Migrating to per-user salt...');
    if (DB._syncTimer) { clearTimeout(DB._syncTimer); DB._syncTimer = null; }
    if (DB._syncInFlight) await DB._syncInFlight;
    const migrated = await DB.reencryptVault(newKey);
    if (migrated) {
      localStorage.setItem('ttg_e2e_key', JSON.stringify(newKey));
      localStorage.setItem('ttg_salt_version', '2');
      console.log('[E2EE] Migration complete — vault re-encrypted with per-user salt.');
      return { key: newKey, migrated: true };
    }
    localStorage.setItem('ttg_e2e_key', JSON.stringify(legacyKey));
    console.warn('[E2EE] Vault remains on the legacy key; retry migration after reconnecting.');
    return { key: legacyKey, migrated: false };
  }

  // 4. Both failed — keep legacy key (safest option, probably a network error)
  console.warn('[E2EE] Both keys failed. Keeping legacy key for offline cache.');
  localStorage.setItem('ttg_e2e_key', JSON.stringify(legacyKey));
  return { key: legacyKey, migrated: false };
}

/** Export data as Excel-compatible CSV for accountants */
function exportToExcel(type, startDate = null, endDate = null) {
  let csv = '';
  let filename = '';
  const today = new Date().toISOString().slice(0, 10);
  const suffix = (startDate && endDate) ? `_${startDate}_to_${endDate}` : `_${today}`;

  const filterByDate = (itemDate) => {
    if (!itemDate) return false;
    if (startDate && appDateKey(itemDate) < appDateKey(startDate)) return false;
    if (endDate && appDateKey(itemDate) > appDateKey(endDate)) return false;
    return true;
  };

  if (type === 'invoices') {
    filename = `TTG_Invoices${suffix}.csv`;
    csv = '"Invoice #","Restaurant","Date","Due Date","Items","Total Sell (KES)","Total Buy (KES)","Delivery Cost","Other Cost","Profit (KES)","Status"\n';
    DB.invoices.filter(i => i.status !== 'draft' && filterByDate(i.date)).forEach(i => {
      csv += `"${i.number}","${invoiceRestaurantDisplayName(i).replace(/"/g, '""')}","${fmtDate(i.date)}","${i.dueDate ? fmtDate(i.dueDate) : ''}","${(i.items || []).length}","${i.totalSell}","${i.totalBuy}","${i.deliveryCost || 0}","${i.otherCost || 0}","${i.profit}","${i.status}"\n`;
    });
  } else if (type === 'expenses') {
    filename = `TTG_Expenses${suffix}.csv`;
    csv = '"Date","Description","Category","Amount (KES)","Type"\n';
    DB.expenses.filter(e => filterByDate(e.date)).forEach(e => {
      csv += `"${fmtDate(e.date)}","${(e.desc || '').replace(/"/g, '""')}","${e.category}","${e.amount}","${e.type}"\n`;
    });
  } else if (type === 'staff') {
    filename = `TTG_Payroll${suffix}.csv`;
    csv = '"Name","Role","Monthly Salary (KES)","Phone","Pay Day","Status"\n';
    DB.staff.forEach(s => {
      csv += `"${(s.name || '').replace(/"/g, '""')}","${s.role || ''}","${s.salary}","${s.phone || ''}","${s.payDay || 5}","${s.status}"\n`;
    });
  } else if (type === 'restaurants') {
    filename = `TTG_Restaurants${suffix}.csv`;
    csv = '"Name","Contact","Phone","Address","Total Sales (KES)"\n';
    DB.restaurants.forEach(r => {
      const total = DB.invoices.filter(i => invoiceBelongsToRestaurant(i, r) && i.status !== 'draft' && filterByDate(i.date)).reduce((s, i) => s + (i.totalSell || 0), 0);
      csv += `"${(r.name || '').replace(/"/g, '""')}","${r.contact || ''}","${r.phone || ''}","${r.address || ''}","${total}"\n`;
    });
  } else if (type === 'all') {
    // Full financial summary
    filename = `TTG_Full_Export${suffix}.csv`;
    csv = '"=== INVOICES ==="\n';
    csv += '"Invoice #","Restaurant","Date","Total Sell","Total Buy","Profit","Status"\n';
    DB.invoices.filter(i => i.status !== 'draft' && filterByDate(i.date)).forEach(i => {
      csv += `"${i.number}","${invoiceRestaurantDisplayName(i).replace(/"/g, '""')}","${fmtDate(i.date)}","${i.totalSell}","${i.totalBuy}","${i.profit}","${i.status}"\n`;
    });
    csv += '\n"=== EXPENSES ==="\n';
    csv += '"Date","Description","Category","Amount","Type"\n';
    DB.expenses.filter(e => filterByDate(e.date)).forEach(e => {
      csv += `"${fmtDate(e.date)}","${(e.desc || '').replace(/"/g, '""')}","${e.category}","${e.amount}","${e.type}"\n`;
    });
    csv += '\n"=== STAFF ==="\n';
    csv += '"Name","Role","Salary","Pay Day"\n';
    DB.staff.forEach(s => {
      csv += `"${(s.name || '').replace(/"/g, '""')}","${s.role || ''}","${s.salary}","${s.payDay || 5}"\n`;
    });
  }

  if (!csv) return toast('No data to export', 'warning');

  // Add BOM for Excel to recognize UTF-8
  const bom = '\uFEFF';
  const blob = new Blob([bom + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
  toast(`Exported ${filename}`, 'success');
}
function toast(msg, type = 'success') {
  const c = document.getElementById('toastContainer');
  if (!c) return;
  const t = document.createElement('div');
  t.className = 'toast ' + type;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, 3000);
}
function openModal(id) { document.getElementById(id).classList.add('active'); }
function closeModal(id) { document.getElementById(id).classList.remove('active'); }

function setActionStatus(title, message, status = 'progress') {
  const titleEl = document.getElementById('actionStatusTitle');
  const messageEl = document.getElementById('actionStatusMessage');
  const icon = document.getElementById('actionStatusIcon');
  const footer = document.getElementById('actionStatusFooter');
  if (!titleEl || !messageEl || !icon || !footer) return;

  titleEl.textContent = title;
  messageEl.textContent = message;
  if (status === 'progress') {
    icon.style.background = 'var(--info-lt)';
    icon.style.color = 'var(--info)';
    icon.innerHTML = '<span class="auth-spinner" style="width:22px;height:22px;border:2.5px solid var(--border);border-top-color:var(--primary);"></span>';
    footer.style.display = 'none';
  } else {
    const icons = {
      success: { background: 'var(--green-100, #dcfce7)', color: 'var(--green-700, #15803d)', svg: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="20 6 9 17 4 12"></polyline></svg>' },
      warning: { background: 'var(--warning-lt, #fef3c7)', color: 'var(--warning, #b45309)', svg: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line></svg>' },
      error: { background: 'var(--danger-lt, #fee2e2)', color: 'var(--danger, #dc2626)', svg: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>' }
    };
    const appearance = icons[status] || icons.success;
    icon.style.background = appearance.background;
    icon.style.color = appearance.color;
    icon.innerHTML = appearance.svg;
    footer.style.display = 'flex';
  }
  openModal('actionStatusModal');
}

async function runWithActionProgress(progressTitle, progressMessage, action) {
  const startedAt = Date.now();
  setActionStatus(progressTitle, progressMessage, 'progress');
  await new Promise(resolve => {
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => requestAnimationFrame(resolve));
    else setTimeout(resolve, 40);
  });

  let result;
  try {
    result = await action();
  } catch (error) {
    const remaining = Math.max(0, 350 - (Date.now() - startedAt));
    if (remaining) await new Promise(resolve => setTimeout(resolve, remaining));
    setActionStatus('Action failed', error?.message || 'The action could not be completed. Please retry.', 'error');
    return { status: 'error', error };
  }

  const remaining = Math.max(0, 350 - (Date.now() - startedAt));
  if (remaining) await new Promise(resolve => setTimeout(resolve, remaining));
  const outcome = result && typeof result === 'object'
    ? result
    : { status: result === false ? 'warning' : 'success', title: result === false ? 'Needs attention' : 'Complete', message: '' };
  const status = ['success', 'warning', 'error'].includes(outcome.status) ? outcome.status : 'success';
  setActionStatus(outcome.title || (status === 'success' ? 'Complete' : status === 'warning' ? 'Needs attention' : 'Action failed'), outcome.message || 'The action is complete.', status);
  return outcome;
}

async function runWithProgressOverlay(progressTitle, progressMessage, action) {
  const startedAt = Date.now();
  setActionStatus(progressTitle, progressMessage, 'progress');
  await new Promise(resolve => {
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => requestAnimationFrame(resolve));
    else setTimeout(resolve, 40);
  });
  try {
    return await action();
  } finally {
    const remaining = Math.max(0, 350 - (Date.now() - startedAt));
    if (remaining) await new Promise(resolve => setTimeout(resolve, remaining));
    closeModal('actionStatusModal');
  }
}

let confirmCallback = null;
function customConfirm(message, title, btnText, isDanger, callback) {
  document.getElementById('confirmMessage').innerText = message;
  document.getElementById('confirmTitle').innerText = title || 'Confirm Action';
  const actionBtn = document.getElementById('confirmActionBtn');
  actionBtn.innerText = btnText || 'Confirm';
  
  const iconWrap = document.getElementById('confirmIcon');
  if (isDanger) {
    actionBtn.className = 'btn btn-danger';
    iconWrap.style.background = 'var(--danger-lt)';
    iconWrap.style.color = 'var(--danger)';
    iconWrap.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>';
  } else {
    actionBtn.className = 'btn btn-primary';
    iconWrap.style.background = 'var(--info-lt)';
    iconWrap.style.color = 'var(--info)';
    iconWrap.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>';
  }

  confirmCallback = () => {
    closeModal('confirmModal');
    if (callback) callback();
  };
  
  actionBtn.onclick = confirmCallback;
  openModal('confirmModal');
}
