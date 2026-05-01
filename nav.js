/* ══ Navigation ══ */
let currentViewInvoiceId = null;
function navigateTo(page) {
  localStorage.setItem('ttg_last_page', page);
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const el = document.getElementById('page-' + page);
  if (el) el.classList.add('active');
  const nav = document.querySelector(`[data-page="${page}"]`);
  if (nav) nav.classList.add('active');
  const titles = { dashboard:'Dashboard','new-invoice':'New Invoice',invoices:'Invoices',restaurants:'Restaurants',expenses:'Capital & Expenses',reports:'Reports','invoice-view':'Invoice' };
  document.getElementById('pageTitle').textContent = titles[page] || 'Dashboard';
  document.getElementById('sidebar').classList.remove('open');
  if (page === 'dashboard') refreshDashboard();
  if (page === 'invoices') renderInvoicesList();
  if (page === 'restaurants') renderRestaurants();
  if (page === 'expenses') renderExpenses();
  if (page === 'new-invoice') populateRestaurantDropdowns();
  if (page === 'reports') {
    populateRestaurantDropdowns();
    generateReport();
  }
}
document.querySelectorAll('.nav-item[data-page]').forEach(n => {
  n.addEventListener('click', () => navigateTo(n.dataset.page));
});

/* ══ Restaurants ══ */
function openNewRestaurantModal() {
  document.getElementById('editRestaurantId').value = '';
  ['restName','restContact','restPhone','restAddress'].forEach(f => document.getElementById(f).value = '');
  document.getElementById('restaurantModalTitle').textContent = 'Add Restaurant';
  openModal('restaurantModal');
}
function saveRestaurant() {
  const id = document.getElementById('editRestaurantId').value;
  const r = { id: id || genId(), name: document.getElementById('restName').value.trim(), contact: document.getElementById('restContact').value.trim(), phone: document.getElementById('restPhone').value.trim(), address: document.getElementById('restAddress').value.trim() };
  if (!r.name) return toast('Name is required', 'error');
  const list = DB.restaurants;
  const idx = list.findIndex(x => x.id === r.id);
  const isNew = idx < 0;
  if (!isNew) list[idx] = r; else list.push(r);
  DB.restaurants = list;
  closeModal('restaurantModal');
  document.getElementById('editRestaurantId').value = '';
  ['restName','restContact','restPhone','restAddress'].forEach(f => document.getElementById(f).value = '');
  renderRestaurants();
  populateRestaurantDropdowns();
  if (isNew) {
    const invRestaurant = document.getElementById('invRestaurant');
    if (invRestaurant) invRestaurant.value = r.id;
  }
  toast(isNew ? 'Restaurant added' : 'Restaurant updated');
}
function editRestaurant(id) {
  const r = DB.restaurants.find(x => x.id === id);
  if (!r) return;
  document.getElementById('editRestaurantId').value = r.id;
  document.getElementById('restName').value = r.name;
  document.getElementById('restContact').value = r.contact || '';
  document.getElementById('restPhone').value = r.phone || '';
  document.getElementById('restAddress').value = r.address || '';
  document.getElementById('restaurantModalTitle').textContent = 'Edit Restaurant';
  openModal('restaurantModal');
}
function deleteRestaurant(id) {
  customConfirm('Are you sure you want to delete this restaurant? All associated invoices will remain but show as Unknown.', 'Delete Restaurant', 'Yes, Delete', true, () => {
    DB.restaurants = DB.restaurants.filter(x => x.id !== id);
    renderRestaurants();
    toast('Restaurant deleted');
  });
}
function renderRestaurants() {
  const body = document.getElementById('restaurantsBody');
  const rests = DB.restaurants;
  const invs = DB.invoices;
  if (!rests.length) { body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No restaurants yet</h3><p>Add your first restaurant client to get started.</p></td></tr>'; return; }
  body.innerHTML = rests.map(r => {
    const total = invs.filter(i => i.restaurantId === r.id).reduce((s, i) => s + (i.totalSell || 0), 0);
    return `<tr><td><strong>${r.name}</strong></td><td>${r.contact||'—'}</td><td>${r.phone||'—'}</td><td>${r.address||'—'}</td><td><strong>KES ${fmtMoney(total)}</strong></td><td><button class="btn btn-sm btn-secondary" onclick="editRestaurant('${r.id}')">Edit</button> <button class="btn btn-sm btn-danger" onclick="deleteRestaurant('${r.id}')">Del</button></td></tr>`;
  }).join('');
}

/* ══ Populate Restaurant Dropdowns ══ */
function populateRestaurantDropdowns() {
  const rests = DB.restaurants;
  const opts = rests.map(r => `<option value="${r.id}">${r.name}</option>`).join('');
  const sel = document.getElementById('invRestaurant');
  if (sel) sel.innerHTML = '<option value="">Select restaurant…</option>' + opts;
  const f = document.getElementById('invoiceFilterRestaurant');
  if (f) f.innerHTML = '<option value="">All Restaurants</option>' + opts;
  const rr = document.getElementById('reportRestaurant');
  if (rr) rr.innerHTML = opts;
}
