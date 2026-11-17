const supabaseUrl = 'https://hufxsjfmgjeyfdidsvcq.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh1ZnhzamZtZ2pleWZkaWRzdmNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2OTc4NTcsImV4cCI6MjEwOTI3Mzg1N30.AERGUhCqait59P0JhA-Ph1F-Kz2pzjfdqYyxMXRSfJY';

// Initialize the Supabase client
const supabaseClient = window.supabase ? window.supabase.createClient(supabaseUrl, supabaseKey) : null;

/* ══ Auth Helpers ══ */
let currentUser = null;

async function getCurrentUser() {
  if (!supabaseClient) return null;
  const { data: { session } } = await supabaseClient.auth.getSession();
  currentUser = session?.user || null;
  if (currentUser) {
    if (currentUser.id) localStorage.setItem('ttg_user_id', currentUser.id);
    if (currentUser.email) localStorage.setItem('ttg_user_email', currentUser.email.toLowerCase().trim());
  }
  return currentUser;
}

function getUserId() {
  return currentUser?.id || localStorage.getItem('ttg_user_id') || null;
}

async function signUp() {
  throw new Error('Public sign-up is disabled. Ask the administrator for an invite.');
}

async function verifyOtp(email, token) {
  if (!supabaseClient) throw new Error('Supabase not available');
  const { data, error } = await supabaseClient.auth.verifyOtp({ email, token, type: 'signup' });
  if (error) throw error;
  currentUser = data.user;
  if (currentUser) {
    if (currentUser.id) localStorage.setItem('ttg_user_id', currentUser.id);
    if (currentUser.email) localStorage.setItem('ttg_user_email', currentUser.email.toLowerCase().trim());
  }
  return data;
}

async function signIn(email, password) {
  if (!supabaseClient) throw new Error('Supabase not available');
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  currentUser = data.user;
  if (currentUser) {
    if (currentUser.id) localStorage.setItem('ttg_user_id', currentUser.id);
    if (currentUser.email) localStorage.setItem('ttg_user_email', currentUser.email.toLowerCase().trim());
  }
  return data;
}

async function signOut() {
  if (!supabaseClient) return false;
  if (typeof DB !== 'undefined' && typeof DB.syncNow === 'function') {
    const synced = await DB.syncNow();
    if (!synced) {
      if (typeof toast === 'function') toast('Sign out paused: the latest changes could not be synced. Reconnect and try again so they are not lost.', 'error');
      return false;
    }
  }
  try {
    const { error } = await supabaseClient.auth.signOut();
    if (error) throw error;
  } catch (error) {
    console.error('Sign out failed:', error);
    if (typeof toast === 'function') toast('Sign out failed. Your local data has been kept.', 'error');
    return false;
  }
  currentUser = null;
  localStorage.removeItem('ttg_user_id');
  localStorage.removeItem('ttg_user_email');
  // Clear ALL local data on sign out — comprehensive cleanup
  ['ttg_restaurants', 'ttg_deleted_restaurant_ids', 'ttg_invoices', 'ttg_deleted_invoice_ids', 'ttg_restored_invoice_ids',
   'ttg_expenses', 'ttg_deleted_invoices', 'ttg_record_actions',
   'ttg_staff', 'ttg_salary_payments', 'ttg_recurring_expenses',
   'ttg_price_lists', 'ttg_deleted_staff', 'ttg_deleted_pricelists',
   'ttg_borrowings', 'ttg_settings', 'ttg_last_page', 'ttg_staged_invoices'].forEach(k => localStorage.removeItem(k));
  return true;
}

/* ══ Basic UI Inspection Deterrent (Right-Click & DevTools Shortcuts) ══ */
function isBlockedInspectionShortcut(event) {
  if (!event) return false;
  const key = String(event.key || '').toUpperCase();
  if (key === 'F12' || event.keyCode === 123) return true;
  if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && key === 'U') return true;
  if (event.ctrlKey && event.shiftKey && ['I', 'J', 'C', 'K'].includes(key)) return true;
  if (event.metaKey && event.altKey && ['I', 'J', 'C', 'K', 'U'].includes(key)) return true;
  return false;
}

function installUiInspectionGuard() {
  if (typeof document === 'undefined' || typeof document.addEventListener !== 'function') return;
  const host = typeof window !== 'undefined' ? window : globalThis;
  if (host.__ttgUiGuardInstalled) return;
  host.__ttgUiGuardInstalled = true;

  document.addEventListener('contextmenu', function (event) {
    event.preventDefault();
  });

  document.addEventListener('keydown', function (event) {
    if (isBlockedInspectionShortcut(event)) {
      event.preventDefault();
    }
  });
}

installUiInspectionGuard();
