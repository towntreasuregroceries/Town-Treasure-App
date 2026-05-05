/* ══ Data Layer ══ */
const state = {
  restaurants: JSON.parse(localStorage.getItem('ttg_restaurants') || '[]'),
  invoices: JSON.parse(localStorage.getItem('ttg_invoices') || '[]'),
  expenses: JSON.parse(localStorage.getItem('ttg_expenses') || '[]'),
  deletedInvoices: JSON.parse(localStorage.getItem('ttg_deleted_invoices') || '[]'),
  nextInvNum: 1001
};

const DB = {
  get restaurants() { return state.restaurants; },
  set restaurants(v) { state.restaurants = v; localStorage.setItem('ttg_restaurants', JSON.stringify(v)); this.syncToSupabase('restaurants', v); },
  get invoices() { return state.invoices; },
  set invoices(v) { state.invoices = v; localStorage.setItem('ttg_invoices', JSON.stringify(v)); this.syncToSupabase('invoices', v); },
  get expenses() { return state.expenses; },
  set expenses(v) { state.expenses = v; localStorage.setItem('ttg_expenses', JSON.stringify(v)); this.syncToSupabase('expenses', v); },
  get deletedInvoices() { return state.deletedInvoices; },
  set deletedInvoices(v) { state.deletedInvoices = v; localStorage.setItem('ttg_deleted_invoices', JSON.stringify(v)); this.syncToSupabase('deleted_invoices', v); },
  
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
  
  async syncToSupabase(table, data) {
    if (!supabaseClient) return;
    const uid = getUserId();
    if (!uid) return; // Not logged in, skip sync
    try {
      // Delete only this user's rows, then re-insert
      const { error: delError } = await supabaseClient.from(table).delete().eq('user_id', uid);
      if (delError) throw delError;
      
      if (data && data.length > 0) {
        // Attach user_id to every row
        const withUser = data.map(row => ({ ...row, user_id: uid }));
        const { error: insError } = await supabaseClient.from(table).insert(withUser);
        if (insError) throw insError;
      }
    } catch (e) {
      console.error(`Error syncing ${table} to Supabase:`, e);
      const now = Date.now();
      if (!window.lastOfflineToast || now - window.lastOfflineToast > 5000) {
        if (typeof toast === 'function') toast(`Offline mode: Data saved locally.`, 'warning');
        window.lastOfflineToast = now;
      }
    }
  },
  
  async loadFromSupabase() {
    if (!supabaseClient) return false;
    const uid = getUserId();
    if (!uid) return false; // Not logged in
    try {
      const tables = ['restaurants', 'invoices', 'expenses', 'deleted_invoices'];
      for (const table of tables) {
        try {
          // RLS automatically filters by user_id, but we also filter explicitly
          const { data, error } = await supabaseClient.from(table).select('*').eq('user_id', uid);
          if (error) { console.warn(`Table '${table}' not available:`, error.message); continue; }
          const stateKey = table === 'deleted_invoices' ? 'deletedInvoices' : table;
          const lsKey = table === 'deleted_invoices' ? 'ttg_deleted_invoices' : `ttg_${table}`;
          state[stateKey] = data || [];
          localStorage.setItem(lsKey, JSON.stringify(state[stateKey]));
        } catch (tableErr) {
          console.warn(`Skipping table '${table}':`, tableErr);
        }
      }
      return true;
    } catch (e) {
      console.error('Error loading from Supabase:', e);
      if (typeof toast === 'function') toast('Offline mode: Using locally cached data', 'warning');
      return false;
    }
  },

  clearLocalData() {
    state.restaurants = [];
    state.invoices = [];
    state.expenses = [];
    state.deletedInvoices = [];
    ['ttg_restaurants', 'ttg_invoices', 'ttg_expenses', 'ttg_deleted_invoices'].forEach(k => localStorage.removeItem(k));
  }
};

function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
function fmtMoney(n) { return Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
function fmtDate(d) { if (!d) return '—'; return new Date(d).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); }
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
