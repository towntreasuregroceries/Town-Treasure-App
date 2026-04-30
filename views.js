/* ══ Invoice View / Print ══ */
function viewInvoice(id) {
  const inv = DB.invoices.find(i => i.id === id);
  if (!inv) return;
  currentViewInvoiceId = id;
  const rest = DB.restaurants.find(r => r.id === inv.restaurantId) || {};
  const container = document.getElementById('invoiceViewContainer');
  
  // Build items rows
  const itemsRows = inv.items.map((it, idx) => `
    <tr>
      <td style="text-align: center; width: 50px;">${(idx + 1).toString().padStart(2, '0')}</td>
      <td>${it.desc}</td>
      <td style="text-align: right;">KSh ${fmtMoney(it.sellPrice)}</td>
      <td style="text-align: center;">${it.qty} ${it.unit || 'pcs'}</td>
      <td style="text-align: right;">KSh ${fmtMoney(it.total)}</td>
    </tr>
  `).join('');

  container.innerHTML = `
  <div class="invoice-preview" id="invoice-doc">
    <div class="invoice-header-shape">
      <div class="header-content">
         <img src="assets/logo.png" alt="Logo" class="invoice-logo-img">
      </div>
    </div>
    
    <div class="invoice-title-row">
       <div class="invoice-title">INVOICE</div>
       <table class="invoice-meta-grid" style="border-collapse: collapse; background: transparent; font-size: 0.85rem;">
          <tr>
            <td class="meta-label" style="font-weight: 700; color: #424242; text-align: right; padding: 0 15px 5px 0; border: none;">Receipt No:</td>
            <td class="meta-value" style="color: #616161; text-align: right; padding: 0 0 5px 0; border: none;">${inv.number}</td>
          </tr>
          <tr>
            <td class="meta-label" style="font-weight: 700; color: #424242; text-align: right; padding: 0 15px 0 0; border: none;">Order Date:</td>
            <td class="meta-value" style="color: #616161; text-align: right; padding: 0 0 0 0; border: none;">${fmtDate(inv.date)}</td>
          </tr>
       </table>
    </div>

    <div class="invoice-billed-to" style="display: flex; justify-content: space-between;">
      <div style="padding-left: 5px;">
        <h4 style="margin-bottom: 12px; color: #424242;">FROM:</h4>
        <p style="font-weight: 700; font-size: 1rem; margin-bottom: 8px; color: #2E7D32;">Town Treasure Groceries</p>
        <div style="display: flex; flex-direction: column; gap: 6px;">
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg> 0708567696</p>
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"></path><polyline points="22,6 12,13 2,6"></polyline></svg> towntreasuregroceries@gmail.com</p>
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg> towntreasuregroceries.com</p>
        </div>
      </div>
      <div style="text-align: right; padding-right: 5px;">
        <h4 style="margin-bottom: 12px; color: #424242;">BILLED TO:</h4>
        <p style="font-weight: 700; font-size: 1rem; margin-bottom: 8px; color: #424242;">${inv.restaurantName}</p>
        <p style="font-size: 0.85rem; margin-bottom: 4px;">${rest.address || ''}</p>
        <p style="font-size: 0.85rem;">${rest.phone || ''}</p>
      </div>
    </div>

    <div class="invoice-table-wrapper">
      <table class="receipt-table">
        <thead>
          <tr>
            <th style="width: 50px; text-align: center;">SL<br>No.</th>
            <th>Item Description</th>
            <th style="text-align: right;">Unit Price</th>
            <th style="text-align: center;">Quantity</th>
            <th style="text-align: right;">Total</th>
          </tr>
        </thead>
        <tbody>
          ${itemsRows}
        </tbody>
      </table>
    </div>

    <div class="invoice-totals-wrapper" style="display: flex; justify-content: flex-end; padding: 20px 50px 0;">
      <div class="totals-table-wrapper" style="width: 350px;">
        <table class="totals-table" style="width: 100%; border-collapse: collapse;">
          <tr>
            <td style="text-align: right; padding: 8px 20px; font-size: 0.85rem; color: #424242;">Sub Total:</td>
            <td style="text-align: right; padding: 8px 20px; font-size: 0.85rem; color: #424242;">KSh ${fmtMoney(inv.totalSell)}</td>
          </tr>
          <tr class="grand-total" style="background-color: #61b146; color: white;">
            <td style="text-align: right; padding: 8px 20px; font-weight: bold; font-size: 0.9rem;">Grand Total:</td>
            <td style="text-align: right; padding: 8px 20px; font-weight: bold; font-size: 0.9rem;">KSh ${fmtMoney(inv.totalSell)}</td>
          </tr>
        </table>
      </div>
    </div>

    <div style="page-break-inside: avoid; break-inside: avoid; margin-top: auto;">
      <div class="invoice-bottom-details" style="display: flex; justify-content: space-between; padding: 15px 50px 5px; position: relative; z-index: 2; margin-top: 10px;">
        <div class="payment-details" style="width: 200px;">
          <h4 style="font-size: 0.9rem; color: #424242; margin-bottom: 10px;">Visit Us Online:</h4>
          <div class="qr-wrapper" style="position: relative; width: 100px; height: 100px; margin-bottom: 8px;">
            <img src="assets/qr%20code.jpg" alt="QR Code" style="width: 100%; height: 100%; object-fit: contain; border-radius: 8px;">
          </div>
          <p style="font-size: 0.65rem; color: #616161; text-align: left; line-height: 1.3;">Scan to visit our website<br>and explore our fresh<br>grocery catalog online.</p>
        </div>
      </div>

      <div class="invoice-footer-shape">
         <div style="position: absolute; bottom: 20px; left: 0; right: 0; display: flex; justify-content: space-between; padding: 0 50px; color: white; z-index: 5;">
            <div style="font-style: italic; font-size: 0.9rem;">Thank you, ${inv.restaurantName}, for Shopping with us</div>
            <div style="font-size: 0.8rem;"></div>
         </div>
      </div>
    </div>
    <div class="watermark-overlay">
      <img src="assets/logo.png" alt="Stamp" class="watermark-stamp">
      <div class="watermark-text">Town Treasure Groceries</div>
    </div>
  </div>`;

  navigateTo('invoice-view');
  
  // Set the PDF download filename to the exact invoice number
  const btn = document.getElementById('btnDownloadPdf');
  if (btn) {
    btn.setAttribute('onclick', `downloadPDF('invoiceViewContainer', '${inv.number}')`);
  }

  // Auto-paginate immediately so the user sees the true A4 layout
  setTimeout(() => {
    const doc = document.getElementById('invoice-doc');
    if (doc && typeof paginateElement === 'function') {
      paginateElement(doc);
    }
  }, 10);
}

function shareWhatsApp() {
  if (!currentViewInvoiceId) return;
  const inv = DB.invoices.find(i => i.id === currentViewInvoiceId);
  if (!inv) return;
  const rest = DB.restaurants.find(r => r.id === inv.restaurantId);
  if (!rest || !rest.phone) {
    toast('No phone number saved for this restaurant', 'error');
    return;
  }
  
  // Clean phone number (leave digits and + if present)
  let phone = rest.phone.replace(/[^\d+]/g, '');
  if (phone.startsWith('0')) {
    phone = '254' + phone.slice(1); // Defaulting to Kenyan code (+254) as KSh is used
  }

  const text = `Hello ${rest.contact || rest.name},
Here is your invoice from Town Treasure Groceries:

*Invoice No:* ${inv.number}
*Date:* ${inv.date}
*Total Amount:* KES ${fmtMoney(inv.totalSell)}

Please download the PDF from our portal or contact us for a copy. Thank you for your business!`;

  const url = `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
  window.open(url, '_blank');
}

/* ══ Expenses & Capital ══ */
let expenseTab = 'expenses';
function switchExpenseTab(tab, btn) {
  expenseTab = tab;
  document.querySelectorAll('#page-expenses .tab-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  renderExpenses();
}
function saveExpense() {
  const e = {
    id: genId(),
    type: document.getElementById('expType').value,
    date: document.getElementById('expDate').value || new Date().toISOString().slice(0,10),
    desc: document.getElementById('expDesc').value.trim(),
    category: document.getElementById('expCategory').value,
    amount: parseFloat(document.getElementById('expAmount').value) || 0
  };
  if (!e.desc || !e.amount) return toast('Fill all fields', 'error');
  const list = DB.expenses; list.push(e); DB.expenses = list;
  closeModal('expenseModal');
  ['expDesc','expAmount'].forEach(f => document.getElementById(f).value = '');
  renderExpenses(); toast('Entry saved');
}
function deleteExpense(id) {
  customConfirm('Are you sure you want to delete this entry?', 'Delete Entry', 'Yes, Delete', true, () => {
    DB.expenses = DB.expenses.filter(e => e.id !== id);
    renderExpenses(); toast('Deleted');
  });
}
function renderExpenses() {
  const all = DB.expenses.slice().reverse();
  const filtered = all.filter(e => expenseTab === 'capital' ? e.type === 'capital' : e.type === 'expense');
  const body = document.getElementById('expensesBody');
  if (!filtered.length) { body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No entries yet</h3></td></tr>'; return; }
  body.innerHTML = filtered.map(e => {
    const typeBadge = e.type === 'capital' ? 'badge-success' : 'badge-warning';
    return `<tr><td>${fmtDate(e.date)}</td><td>${e.desc}</td><td>${e.category}</td><td>KES ${fmtMoney(e.amount)}</td><td><span class="badge ${typeBadge}">${e.type}</span></td><td><button class="btn btn-sm btn-danger" onclick="deleteExpense('${e.id}')">Del</button></td></tr>`;
  }).join('');
  // Capital stats
  const totalCap = DB.expenses.filter(e => e.type === 'capital').reduce((s, e) => s + e.amount, 0);
  const totalExp = DB.expenses.filter(e => e.type === 'expense').reduce((s, e) => s + e.amount, 0);
  const totalRev = DB.invoices.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);
  document.getElementById('capitalStats').innerHTML = `
    <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6"/></svg></div><div class="stat-info"><h4>Total Capital</h4><div class="stat-value">KES ${fmtMoney(totalCap)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon red"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/></svg></div><div class="stat-info"><h4>Total Expenses</h4><div class="stat-value">KES ${fmtMoney(totalExp)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/></svg></div><div class="stat-info"><h4>Paid Revenue</h4><div class="stat-value">KES ${fmtMoney(totalRev)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon ${(totalCap + totalRev - totalExp) >= 0 ? 'green' : 'red'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg></div><div class="stat-info"><h4>Net Balance</h4><div class="stat-value">KES ${fmtMoney(totalCap + totalRev - totalExp)}</div></div></div>`;
}
