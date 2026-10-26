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
  const titles = { dashboard:'Dashboard','new-invoice':'New Invoice',invoices:'Invoices','clerk-submissions':'Clerk Submissions',restaurants:'Restaurants',expenses:'Capital & Expenses',reports:'Reports','invoice-view':'Invoice','recycle-bin':'Recycle Bin',pricelists:'Price Lists','pricelist-edit':'Edit Price List','pricelist-view':'Price List',statements:'Statements' };
  document.getElementById('pageTitle').textContent = titles[page] || 'Dashboard';
  document.getElementById('sidebar').classList.remove('open');
  if (page === 'dashboard') { refreshDashboard(); if(typeof renderInsightsPanel==='function') renderInsightsPanel(); if(typeof renderMonthlyPnL==='function') renderMonthlyPnL(); if(typeof StagingDB !== 'undefined') StagingDB.updatePendingCountBadge(); }
  if (page === 'invoices') renderInvoicesList();
  if (page === 'clerk-submissions' && typeof renderClerkSubmissionsPage === 'function') renderClerkSubmissionsPage();
  if (page === 'restaurants') renderRestaurants();
  if (page === 'expenses') renderExpenses();
  if (page === 'new-invoice') populateRestaurantDropdowns();
  if (page === 'recycle-bin') renderBin();
  if (page === 'reports') {
    populateRestaurantDropdowns();
    generateReport();
  }
  if (page === 'pricelists' && typeof renderPriceLists === 'function') renderPriceLists();
  if (page === 'statements' && typeof renderStatementsPage === 'function') renderStatementsPage();
}
document.querySelectorAll('.nav-item[data-page]').forEach(n => {
  n.addEventListener('click', () => navigateTo(n.dataset.page));
});

/* ══ Restaurants ══ */
function openNewRestaurantModal() {
  document.getElementById('editRestaurantId').value = '';
  ['restName','restAliases','restContact','restPhone','restAddress'].forEach(f => document.getElementById(f).value = '');
  document.getElementById('restaurantModalTitle').textContent = 'Add Restaurant';
  openModal('restaurantModal');
}
function saveRestaurant() {
  const id = document.getElementById('editRestaurantId').value;
  const aliases = (document.getElementById('restAliases').value || '').split(/[\n,;]+/).map(x => x.trim()).filter(Boolean);
  const r = { id: id || genId(), name: document.getElementById('restName').value.trim(), aliases, contact: document.getElementById('restContact').value.trim(), phone: document.getElementById('restPhone').value.trim(), address: document.getElementById('restAddress').value.trim(), updatedAt: new Date().toISOString() };
  if (!r.name) return toast('Name is required', 'error');
  const list = DB.restaurants;
  const idx = list.findIndex(x => x.id === r.id);
  if (idx >= 0) r.createdAt = list[idx].createdAt || r.updatedAt;
  else r.createdAt = r.updatedAt;
  const isNew = idx < 0;
  const otherRestaurants = list.filter(x => x.id !== r.id);
  const proposedNames = [r.name, ...r.aliases];
  const duplicates = otherRestaurants.filter(existing =>
    proposedNames.some(name => findRestaurantByName(name, [existing]))
  );
  if (isNew && duplicates.length) {
    return toast(`“${duplicates[0].name}” already exists. Edit it and add other spellings as aliases.`, 'error');
  }
  const commit = () => saveRestaurantRecord(r, isNew, duplicates);
  if (duplicates.length) {
    const names = duplicates.map(x => x.name).join(', ');
    return customConfirm(
      `Merge ${names} into ${r.name}? Existing invoices will be reassigned to ${r.name}, and future OCR matches will use this restaurant.`,
      'Merge Duplicate Restaurants', 'Merge & Save', false, commit
    );
  }
  commit();
}
function saveRestaurantRecord(r, isNew, duplicates = []) {
  const duplicateIds = new Set(duplicates.map(x => x.id));
  if (duplicateIds.size) {
    const duplicateNames = new Set(duplicates.flatMap(x => [x.name, ...(Array.isArray(x.aliases) ? x.aliases : [])])
      .map(normalizeRestaurantName));
    DB.deletedRestaurantIds = Array.from(new Set([...(DB.deletedRestaurantIds || []), ...duplicateIds]));
    DB.invoices = DB.invoices.map(invoice => duplicateIds.has(invoice.restaurantId)
      || duplicateNames.has(normalizeRestaurantName(invoice.restaurantName))
      ? { ...invoice, restaurantId: r.id, restaurantName: r.name, updatedAt: new Date().toISOString() }
      : invoice);
  }
  const list = DB.restaurants.filter(existing => !duplicateIds.has(existing.id));
  const idx = list.findIndex(x => x.id === r.id);
  if (idx >= 0) list[idx] = r; else list.push(r);
  DB.restaurants = list;
  closeModal('restaurantModal');
  document.getElementById('editRestaurantId').value = '';
  ['restName','restAliases','restContact','restPhone','restAddress'].forEach(f => document.getElementById(f).value = '');
  renderRestaurants();
  populateRestaurantDropdowns();
  if (isNew) {
    const invRestaurant = document.getElementById('invRestaurant');
    if (invRestaurant) invRestaurant.value = r.id;
  }
  if (typeof DB.syncNow === 'function') DB.syncNow();
  toast(duplicates.length
    ? `Restaurant saved; merged ${duplicates.length} duplicate restaurant record${duplicates.length === 1 ? '' : 's'}.`
    : (isNew ? 'Restaurant added' : 'Restaurant updated'));
}
function editRestaurant(id) {
  const r = DB.restaurants.find(x => x.id === id);
  if (!r) return;
  document.getElementById('editRestaurantId').value = r.id;
  document.getElementById('restName').value = r.name;
  document.getElementById('restAliases').value = Array.isArray(r.aliases) ? r.aliases.join('\n') : '';
  document.getElementById('restContact').value = r.contact || '';
  document.getElementById('restPhone').value = r.phone || '';
  document.getElementById('restAddress').value = r.address || '';
  document.getElementById('restaurantModalTitle').textContent = 'Edit Restaurant';
  openModal('restaurantModal');
}
function deleteRestaurant(id) {
  customConfirm('Are you sure you want to delete this restaurant? All associated invoices will remain but show as Unknown.', 'Delete Restaurant', 'Yes, Delete', true, () => {
    DB.deletedRestaurantIds = Array.from(new Set([...(DB.deletedRestaurantIds || []), id]));
    DB.restaurants = DB.restaurants.filter(x => x.id !== id);
    renderRestaurants();
    if (typeof DB.syncNow === 'function') DB.syncNow();
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
    return `<tr><td><strong>${escapeHtml(r.name)}</strong></td><td>${escapeHtml(r.contact||'—')}</td><td>${escapeHtml(r.phone||'—')}</td><td>${escapeHtml(r.address||'—')}</td><td><strong>KES ${fmtMoney(total)}</strong></td><td><button class="btn btn-sm btn-secondary" onclick="editRestaurant('${r.id}')">Edit</button> <button class="btn btn-sm btn-primary" onclick="quickStatement('${r.id}')" style="display:inline-flex;align-items:center;gap:4px;"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line></svg>Statement</button> <button class="btn btn-sm btn-danger" onclick="deleteRestaurant('${r.id}')">Del</button></td></tr>`;
  }).join('');
}

/* ══ Populate Restaurant Dropdowns ══ */
function populateRestaurantDropdowns() {
  const rests = DB.restaurants;
  const opts = rests.map(r => `<option value="${r.id}">${escapeHtml(r.name)}</option>`).join('');
  const sel = document.getElementById('invRestaurant');
  if (sel) sel.innerHTML = '<option value="">Select restaurant…</option>' + opts;
  const f = document.getElementById('invoiceFilterRestaurant');
  if (f) f.innerHTML = '<option value="">All Restaurants</option>' + opts;
  const rr = document.getElementById('reportRestaurant');
  if (rr) rr.innerHTML = opts;
}
