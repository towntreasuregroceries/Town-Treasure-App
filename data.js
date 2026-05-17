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
  invoices: JSON.parse(localStorage.getItem('ttg_invoices') || '[]'),
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

const DB = {
  get restaurants() { return state.restaurants; },
  set restaurants(v) { state.restaurants = v; localStorage.setItem('ttg_restaurants', JSON.stringify(v)); this.syncToSupabase(); },
  get invoices() { return state.invoices; },
  set invoices(v) { state.invoices = v; localStorage.setItem('ttg_invoices', JSON.stringify(v)); this.syncToSupabase(); },
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

  async syncToSupabase() {
    // Debounce: wait 3 seconds of inactivity before syncing
    if (this._syncTimer) clearTimeout(this._syncTimer);
    this._syncTimer = setTimeout(() => this._doSync(), 3000);
  },

  async _doSync() {
    if (!supabaseClient) return;
    const uid = getUserId();
    if (!uid) return; // Not logged in, skip sync
    
    const e2eKeyStr = localStorage.getItem('ttg_e2e_key');
    if (!e2eKeyStr) {
      console.warn("No E2EE key found. Sync skipped.");
      return;
    }

    try {
      this._syncVersion++;
      // 1. Gather all local state with version tracking
      const appState = {
        _vaultVersion: this._syncVersion,
        _lastSync: new Date().toISOString(),
        invoices: state.invoices,
        expenses: state.expenses,
        restaurants: state.restaurants,
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

      // 2. Encrypt it completely
      const jwkKey = JSON.parse(e2eKeyStr);
      const encryptedPayload = await Crypto.encrypt(appState, jwkKey);

      // 3. Save to the secure vault (overwrites existing row for this user)
      const { error } = await supabaseClient
        .from('encrypted_vault')
        .upsert({ user_id: uid, data: encryptedPayload }, { onConflict: 'user_id' });

      if (error) throw error;
      console.log('Successfully synced encrypted vault (v' + this._syncVersion + ')');
    } catch (e) {
      console.error(`Error syncing vault to Supabase:`, e);
      const now = Date.now();
      if (!window.lastOfflineToast || now - window.lastOfflineToast > 5000) {
        if (typeof toast === 'function') toast(`Offline mode: Data saved locally.`, 'warning');
        window.lastOfflineToast = now;
      }
    }
  },

  /** Force an immediate sync (bypasses debounce) */
  async syncNow() {
    if (this._syncTimer) clearTimeout(this._syncTimer);
    await this._doSync();
  },
  
  async loadFromSupabase() {
    if (!supabaseClient) return false;
    const uid = getUserId();
    if (!uid) return false; // Not logged in
    
    const e2eKeyStr = localStorage.getItem('ttg_e2e_key');
    if (!e2eKeyStr) {
      console.warn("No E2EE key found. Loading skipped.");
      return false;
    }

    try {
      const { data, error } = await supabaseClient
        .from('encrypted_vault')
        .select('data')
        .eq('user_id', uid)
        .single();

      if (error && error.code !== 'PGRST116') throw error; // Ignore "no rows" error

      if (data && data.data) {
        // Decrypt the payload
        const jwkKey = JSON.parse(e2eKeyStr);
        const appState = await Crypto.decrypt(data.data, jwkKey);
        
        if (appState) {
          state.invoices = appState.invoices || [];
          state.expenses = appState.expenses || [];
          state.restaurants = appState.restaurants || [];
          state.deletedInvoices = appState.deletedInvoices || [];
          state.staff = appState.staff || [];
          state.salaryPayments = appState.salaryPayments || [];
          state.recurringExpenses = appState.recurringExpenses || [];
          state.priceLists = appState.priceLists || [];
          state.deletedStaff = appState.deletedStaff || [];
          state.deletedPriceLists = appState.deletedPriceLists || [];
          state.borrowings = appState.borrowings || [];
          state.settings = appState.settings || {};
          
          localStorage.setItem('ttg_invoices', JSON.stringify(state.invoices));
          localStorage.setItem('ttg_expenses', JSON.stringify(state.expenses));
          localStorage.setItem('ttg_restaurants', JSON.stringify(state.restaurants));
          localStorage.setItem('ttg_deleted_invoices', JSON.stringify(state.deletedInvoices));
          localStorage.setItem('ttg_staff', JSON.stringify(state.staff));
          localStorage.setItem('ttg_salary_payments', JSON.stringify(state.salaryPayments));
          localStorage.setItem('ttg_recurring_expenses', JSON.stringify(state.recurringExpenses));
          localStorage.setItem('ttg_price_lists', JSON.stringify(state.priceLists));
          localStorage.setItem('ttg_deleted_staff', JSON.stringify(state.deletedStaff));
          localStorage.setItem('ttg_deleted_pricelists', JSON.stringify(state.deletedPriceLists));
          localStorage.setItem('ttg_borrowings', JSON.stringify(state.borrowings));
          localStorage.setItem('ttg_settings', JSON.stringify(state.settings));
          
          console.log('Loaded and decrypted data from vault');
          return true;
        } else {
          if (typeof toast === 'function') toast('Failed to decrypt data. Incorrect key?', 'error');
          return false;
        }
      }
      return true; // No data yet
    } catch (e) {
      console.error('Error loading from vault:', e);
      if (typeof toast === 'function') toast('Offline mode: Using locally cached data', 'warning');
      return false;
    }
  },

  clearLocalData() {
    state.restaurants = [];
    state.invoices = [];
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
    ['ttg_restaurants', 'ttg_invoices', 'ttg_expenses', 'ttg_deleted_invoices',
     'ttg_staff', 'ttg_salary_payments', 'ttg_recurring_expenses',
     'ttg_price_lists', 'ttg_deleted_staff', 'ttg_deleted_pricelists',
     'ttg_borrowings', 'ttg_settings'].forEach(k => localStorage.removeItem(k));
  }
};

function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
function fmtMoney(n) { return Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
function fmtDate(d) { if (!d) return '—'; return new Date(d).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); }

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
    // Legacy worked! Now migrate: re-encrypt with new key
    console.log('[E2EE] Legacy key worked. Migrating to per-user salt...');
    localStorage.setItem('ttg_e2e_key', JSON.stringify(newKey));
    localStorage.setItem('ttg_salt_version', '2');
    await DB.syncNow(); // Immediate sync with new key
    console.log('[E2EE] Migration complete — vault re-encrypted with per-user salt.');
    return { key: newKey, migrated: true };
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
    if (startDate && itemDate < startDate) return false;
    if (endDate && itemDate > endDate) return false;
    return true;
  };

  if (type === 'invoices') {
    filename = `TTG_Invoices${suffix}.csv`;
    csv = '"Invoice #","Restaurant","Date","Due Date","Items","Total Sell (KES)","Total Buy (KES)","Delivery Cost","Other Cost","Profit (KES)","Status"\n';
    DB.invoices.filter(i => i.status !== 'draft' && filterByDate(i.date)).forEach(i => {
      csv += `"${i.number}","${(i.restaurantName || '').replace(/"/g, '""')}","${i.date}","${i.dueDate || ''}","${i.items.length}","${i.totalSell}","${i.totalBuy}","${i.deliveryCost || 0}","${i.otherCost || 0}","${i.profit}","${i.status}"\n`;
    });
  } else if (type === 'expenses') {
    filename = `TTG_Expenses${suffix}.csv`;
    csv = '"Date","Description","Category","Amount (KES)","Type"\n';
    DB.expenses.filter(e => filterByDate(e.date)).forEach(e => {
      csv += `"${e.date}","${(e.desc || '').replace(/"/g, '""')}","${e.category}","${e.amount}","${e.type}"\n`;
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
      const total = DB.invoices.filter(i => i.restaurantId === r.id && i.status !== 'draft' && filterByDate(i.date)).reduce((s, i) => s + (i.totalSell || 0), 0);
      csv += `"${(r.name || '').replace(/"/g, '""')}","${r.contact || ''}","${r.phone || ''}","${r.address || ''}","${total}"\n`;
    });
  } else if (type === 'all') {
    // Full financial summary
    filename = `TTG_Full_Export${suffix}.csv`;
    csv = '"=== INVOICES ==="\n';
    csv += '"Invoice #","Restaurant","Date","Total Sell","Total Buy","Profit","Status"\n';
    DB.invoices.filter(i => i.status !== 'draft' && filterByDate(i.date)).forEach(i => {
      csv += `"${i.number}","${(i.restaurantName || '').replace(/"/g, '""')}","${i.date}","${i.totalSell}","${i.totalBuy}","${i.profit}","${i.status}"\n`;
    });
    csv += '\n"=== EXPENSES ==="\n';
    csv += '"Date","Description","Category","Amount","Type"\n';
    DB.expenses.filter(e => filterByDate(e.date)).forEach(e => {
      csv += `"${e.date}","${(e.desc || '').replace(/"/g, '""')}","${e.category}","${e.amount}","${e.type}"\n`;
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
