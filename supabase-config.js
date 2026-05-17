const supabaseUrl = 'https://bulptzqaoddnptiwfrce.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1bHB0enFhb2RkbnB0aXdmcmNlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MzE5ODgsImV4cCI6MjA5MzEwNzk4OH0.XHM5Xa3dqOAL5bU4AbATuu9xTVFnkX8BB8_joIFdfKM';

// Initialize the Supabase client
const supabaseClient = window.supabase ? window.supabase.createClient(supabaseUrl, supabaseKey) : null;

/* ══ Auth Helpers ══ */
let currentUser = null;

async function getCurrentUser() {
  if (!supabaseClient) return null;
  const { data: { session } } = await supabaseClient.auth.getSession();
  currentUser = session?.user || null;
  return currentUser;
}

function getUserId() {
  return currentUser?.id || null;
}

async function signUp(email, password) {
  if (!supabaseClient) throw new Error('Supabase not available');
  const { data, error } = await supabaseClient.auth.signUp({ email, password });
  if (error) throw error;
  currentUser = data.user;
  return data;
}

async function verifyOtp(email, token) {
  if (!supabaseClient) throw new Error('Supabase not available');
  const { data, error } = await supabaseClient.auth.verifyOtp({ email, token, type: 'signup' });
  if (error) throw error;
  currentUser = data.user;
  return data;
}

async function signIn(email, password) {
  if (!supabaseClient) throw new Error('Supabase not available');
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  currentUser = data.user;
  return data;
}

async function signOut() {
  if (!supabaseClient) return;
  await supabaseClient.auth.signOut();
  currentUser = null;
  // Clear ALL local data on sign out — comprehensive cleanup
  ['ttg_restaurants', 'ttg_invoices', 'ttg_expenses', 'ttg_deleted_invoices',
   'ttg_staff', 'ttg_salary_payments', 'ttg_recurring_expenses',
   'ttg_price_lists', 'ttg_deleted_staff', 'ttg_deleted_pricelists',
   'ttg_borrowings', 'ttg_settings', 'ttg_last_page'].forEach(k => localStorage.removeItem(k));
}
