/* ══ Data Layer ══ */
const state = {
  restaurants: [],
  invoices: [],
  expenses: [],
  nextInvNum: 1001
};

const DB = {
  get restaurants() { return state.restaurants; },
  set restaurants(v) { state.restaurants = v; this.syncToSupabase('restaurants', v); },
  get invoices() { return state.invoices; },
  set invoices(v) { state.invoices = v; this.syncToSupabase('invoices', v); },
  get expenses() { return state.expenses; },
  set expenses(v) { state.expenses = v; this.syncToSupabase('expenses', v); },
  
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
    try {
      // Clear and re-insert for sync. For production with multiple users, use granular operations.
      const { error: delError } = await supabaseClient.from(table).delete().neq('id', '0');
      if (delError) throw delError;
      
      if (data && data.length > 0) {
        const { error: insError } = await supabaseClient.from(table).insert(data);
        if (insError) throw insError;
      }
    } catch (e) {
      console.error(`Error syncing ${table} to Supabase:`, e);
      alert(`Error syncing to database: ${e.message}`);
    }
  },
  
  async loadFromSupabase() {
    if (!supabaseClient) return false;
    try {
      const tables = ['restaurants', 'invoices', 'expenses'];
      for (const table of tables) {
        const { data, error } = await supabaseClient.from(table).select('*');
        if (error) throw error;
        state[table] = data || [];
      }
      return true;
    } catch (e) {
      console.error('Error loading from Supabase:', e);
      alert('Error loading from database!');
      return false;
    }
  }
};

function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
function fmtMoney(n) { return Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
function fmtDate(d) { if (!d) return '—'; return new Date(d).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); }
function toast(msg, type = 'success') {
  const c = document.getElementById('toastContainer');
  const t = document.createElement('div');
  t.className = 'toast ' + type;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, 3000);
}
function openModal(id) { document.getElementById(id).classList.add('active'); }
function closeModal(id) { document.getElementById(id).classList.remove('active'); }
