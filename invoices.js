/* ══ Invoice Line Items ══ */
function addLineItem() {
  const row = document.createElement('tr');
  row.innerHTML = `<td><input type="text" placeholder="e.g. Onions" class="item-desc"></td><td><input type="number" min="0" step="any" value="1" class="item-qty"></td><td><select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;"><option value="kgs">Kgs</option><option value="litres">Litres</option><option value="pieces" selected>Pieces</option><option value="crates">Crates</option><option value="bags">Bags</option><option value="trays">Trays</option><option value="bundles">Bundles</option><option value="dozen">Dozen</option></select></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy"></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell"></td><td class="item-total" style="font-weight:600">0.00</td><td><button type="button" class="btn-remove-row" onclick="removeLineItem(this)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></td>`;
  document.getElementById('lineItemsBody').appendChild(row);
  attachLineListeners(row);
}
function removeLineItem(btn) {
  const rows = document.getElementById('lineItemsBody').rows;
  if (rows.length <= 1) return;
  btn.closest('tr').remove();
  calcInvoiceTotals();
}
function calcInvoiceTotals() {
  let sell = 0, buy = 0;
  document.querySelectorAll('#lineItemsBody tr').forEach(row => {
    const q = parseFloat(row.querySelector('.item-qty')?.value) || 0;
    const s = parseFloat(row.querySelector('.item-sell')?.value) || 0;
    const b = parseFloat(row.querySelector('.item-buy')?.value) || 0;
    const t = q * s;
    row.querySelector('.item-total').textContent = fmtMoney(t);
    sell += t;
    buy += q * b;
  });
  document.getElementById('invSubtotal').textContent = fmtMoney(sell);
  document.getElementById('invCost').textContent = fmtMoney(buy);
  document.getElementById('invProfit').textContent = fmtMoney(sell - buy);
}
function attachLineListeners(row) {
  row.querySelectorAll('input').forEach(inp => inp.addEventListener('input', calcInvoiceTotals));
}
document.querySelectorAll('#lineItemsBody tr').forEach(attachLineListeners);

/* ══ Secure Invoice Number Generation ══ */
function generateSecureInvoiceNumber(dateStr) {
  const d = new Date(dateStr || Date.now());
  const dayBin = d.getDate().toString(2).padStart(5, '0');
  const moBin = (d.getMonth() + 1).toString(2).padStart(4, '0');
  const yrBin = (d.getFullYear() % 100).toString(2).padStart(7, '0');
  
  // Combine into a 16-bit integer and convert to base 36 (produces 3 uppercase chars)
  const binDate = parseInt(yrBin + moBin + dayBin, 2); 
  const dateCode = binDate.toString(36).toUpperCase().padStart(3, '0');
  
  // Generate 3 random uppercase letters/numbers
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let randCode = '';
  for(let i=0; i<3; i++) {
    randCode += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  
  // Mix them securely: Date[0] + Rand[0] + Date[1] + Rand[1] + Date[2] + Rand[2]
  return 'TTG-' + dateCode[0] + randCode[0] + dateCode[1] + randCode[1] + dateCode[2] + randCode[2];
}

/* ══ Save Invoice ══ */
function saveInvoice() {
  const restId = document.getElementById('invRestaurant').value;
  if (!restId) return toast('Select a restaurant', 'error');
  const items = [];
  let valid = true;
  document.querySelectorAll('#lineItemsBody tr').forEach(row => {
    const desc = row.querySelector('.item-desc').value.trim();
    const qty = parseFloat(row.querySelector('.item-qty').value) || 0;
    const unit = row.querySelector('.item-unit')?.value || 'pieces';
    const buy = parseFloat(row.querySelector('.item-buy').value) || 0;
    const sell = parseFloat(row.querySelector('.item-sell').value) || 0;
    if (!desc) { valid = false; return; }
    items.push({ desc, qty, unit, buyPrice: buy, sellPrice: sell, total: qty * sell });
  });
  if (!valid || !items.length) return toast('Fill in all item descriptions', 'error');
  const totalSell = items.reduce((s, i) => s + i.total, 0);
  const totalBuy = items.reduce((s, i) => s + i.qty * i.buyPrice, 0);
  const rest = DB.restaurants.find(r => r.id === restId);
  const invDateVal = document.getElementById('invDate').value || new Date().toISOString().slice(0,10);
  const inv = {
    id: genId(), number: generateSecureInvoiceNumber(invDateVal), restaurantId: restId,
    restaurantName: rest ? rest.name : 'Unknown',
    date: invDateVal,
    dueDate: document.getElementById('invDueDate').value || '',
    items, totalSell, totalBuy, profit: totalSell - totalBuy,
    notes: document.getElementById('invNotes').value.trim(),
    status: 'pending', createdAt: new Date().toISOString()
  };
  const list = DB.invoices; list.push(inv); DB.invoices = list;
  toast('Invoice ' + inv.number + ' created!');
  resetInvoiceForm();
  viewInvoice(inv.id);
}
function resetInvoiceForm() {
  document.getElementById('invRestaurant').value = '';
  document.getElementById('invDate').value = new Date().toISOString().slice(0,10);
  document.getElementById('invDueDate').value = '';
  document.getElementById('invNotes').value = '';
  const body = document.getElementById('lineItemsBody');
  body.innerHTML = '';
  addLineItem();
  calcInvoiceTotals();
}

/* ══ Invoices List ══ */
function renderInvoicesList() {
  populateRestaurantDropdowns();
  const search = (document.getElementById('invoiceSearch')?.value || '').toLowerCase();
  const filterRest = document.getElementById('invoiceFilterRestaurant')?.value || '';
  const filterStatus = document.getElementById('invoiceFilterStatus')?.value || '';
  let invs = DB.invoices.slice().reverse();
  if (search) invs = invs.filter(i => i.number.toLowerCase().includes(search) || i.restaurantName.toLowerCase().includes(search));
  if (filterRest) invs = invs.filter(i => i.restaurantId === filterRest);
  if (filterStatus) invs = invs.filter(i => i.status === filterStatus);
  const body = document.getElementById('invoicesListBody');
  if (!invs.length) { body.innerHTML = '<tr><td colspan="8" class="empty-state"><h3>No invoices found</h3></td></tr>'; return; }
  body.innerHTML = invs.map(i => {
    const badgeCls = i.status === 'paid' ? 'badge-success' : i.status === 'overdue' ? 'badge-danger' : 'badge-warning';
    return `<tr><td><strong>${i.number}</strong></td><td>${i.restaurantName}</td><td>${fmtDate(i.date)}</td><td>${i.items.length}</td><td>KES ${fmtMoney(i.totalSell)}</td><td style="color:var(--green-700)">KES ${fmtMoney(i.profit)}</td><td><span class="badge ${badgeCls}">${i.status}</span></td><td><button class="btn btn-sm btn-secondary" onclick="viewInvoice('${i.id}')">View</button> <button class="btn btn-sm btn-danger" onclick="deleteInvoice('${i.id}')">Del</button></td></tr>`;
  }).join('');
}
function deleteInvoice(id) {
  customConfirm('Are you sure you want to delete this invoice? This cannot be undone.', 'Delete Invoice', 'Yes, Delete', true, () => {
    DB.invoices = DB.invoices.filter(i => i.id !== id);
    renderInvoicesList(); toast('Invoice deleted');
  });
}
function markAsPaid(id) {
  const list = DB.invoices;
  const inv = list.find(i => i.id === id);
  if (inv) { inv.status = 'paid'; DB.invoices = list; toast('Marked as paid'); viewInvoice(id); }
}
