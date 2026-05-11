/* ══ Monthly Restaurant Statements ══ */

function renderStatementsPage() {
  const restSelect = document.getElementById('stmtRestaurant');
  if (restSelect) {
    const rests = DB.restaurants;
    restSelect.innerHTML = '<option value="">Select restaurant…</option><option value="__all__">📄 All Restaurants</option>' +
      rests.map(r => `<option value="${r.id}">${r.name}</option>`).join('');
  }
  const monthInput = document.getElementById('stmtMonth');
  if (monthInput && !monthInput.value) {
    monthInput.value = new Date().toISOString().slice(0, 7);
  }
}

function generateStatement() {
  const restId = document.getElementById('stmtRestaurant')?.value;
  const month = document.getElementById('stmtMonth')?.value;
  if (!restId) return toast('Select a restaurant', 'error');
  if (!month) return toast('Select a month', 'error');

  const output = document.getElementById('statementOutput');
  if (!output) return;

  if (restId === '__all__') {
    // Batch: generate for all restaurants
    let allHtml = '';
    DB.restaurants.forEach(rest => {
      allHtml += buildStatementHTML(rest, month);
    });
    output.innerHTML = allHtml || '<div class="empty-state"><h3>No data found</h3></div>';
  } else {
    const rest = DB.restaurants.find(r => r.id === restId);
    if (!rest) return toast('Restaurant not found', 'error');
    output.innerHTML = buildStatementHTML(rest, month);
  }
}

function buildStatementHTML(rest, month) {
  const [yr, mo] = month.split('-').map(Number);
  const monthName = new Date(yr, mo - 1, 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
  const monthStart = `${month}-01`;
  const nextMonth = mo === 12 ? `${yr + 1}-01` : `${yr}-${String(mo + 1).padStart(2, '0')}`;
  const monthEnd = new Date(yr, mo, 0).toISOString().slice(0, 10); // Last day of month

  // Get ALL invoices for this restaurant (not drafts)
  const allInvoices = DB.invoices.filter(i => i.restaurantId === rest.id && i.status !== 'draft');

  // Opening balance: sum of unpaid invoices BEFORE this month
  const priorInvoices = allInvoices.filter(i => i.date < monthStart);
  const priorPaidTotal = priorInvoices.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);
  const priorInvoicedTotal = priorInvoices.reduce((s, i) => s + i.totalSell, 0);
  const openingBalance = priorInvoicedTotal - priorPaidTotal;

  // This month's transactions
  const monthInvoices = allInvoices.filter(i => i.date >= monthStart && i.date <= monthEnd);
  const monthInvoicedTotal = monthInvoices.reduce((s, i) => s + i.totalSell, 0);
  const monthPaidInvoices = monthInvoices.filter(i => i.status === 'paid');
  const monthPaidTotal = monthPaidInvoices.reduce((s, i) => s + i.totalSell, 0);

  // Build transaction rows
  let runningBalance = openingBalance;
  const transactions = [];

  // Add invoices as debits (sorted by date)
  monthInvoices.sort((a, b) => a.date.localeCompare(b.date)).forEach(inv => {
    runningBalance += inv.totalSell;
    transactions.push({
      date: inv.date,
      desc: `Invoice ${inv.number}`,
      items: inv.items.length + ' items',
      debit: inv.totalSell,
      credit: 0,
      balance: runningBalance,
      type: 'invoice'
    });

    // If paid, add a credit entry
    if (inv.status === 'paid') {
      runningBalance -= inv.totalSell;
      transactions.push({
        date: inv.date,
        desc: `Payment — ${inv.number}`,
        items: '',
        debit: 0,
        credit: inv.totalSell,
        balance: runningBalance,
        type: 'payment'
      });
    }
  });

  const closingBalance = runningBalance;

  // Age analysis
  const unpaidInvoices = allInvoices.filter(i => i.status !== 'paid' && i.date <= monthEnd);
  const now = new Date(yr, mo - 1, new Date().getDate());
  let current = 0, days30 = 0, days60 = 0, days90 = 0;
  unpaidInvoices.forEach(inv => {
    const invDate = new Date(inv.date);
    const daysDiff = Math.floor((now - invDate) / (1000 * 60 * 60 * 24));
    if (daysDiff <= 30) current += inv.totalSell;
    else if (daysDiff <= 60) days30 += inv.totalSell;
    else if (daysDiff <= 90) days60 += inv.totalSell;
    else days90 += inv.totalSell;
  });

  // Build HTML
  const txRows = transactions.map(tx => `
    <tr style="${tx.type === 'payment' ? 'background:#f0fdf4;' : ''}">
      <td style="font-size:0.85rem;">${fmtDate(tx.date)}</td>
      <td>${tx.desc}</td>
      <td style="font-size:0.82rem;color:#616161;">${tx.items}</td>
      <td style="text-align:right;color:${tx.debit ? '#dc2626' : 'transparent'};">${tx.debit ? 'KES ' + fmtMoney(tx.debit) : ''}</td>
      <td style="text-align:right;color:${tx.credit ? '#2E7D32' : 'transparent'};">${tx.credit ? 'KES ' + fmtMoney(tx.credit) : ''}</td>
      <td style="text-align:right;font-weight:600;">KES ${fmtMoney(tx.balance)}</td>
    </tr>
  `).join('');

  return `
  <div class="invoice-preview" id="statement-doc" style="max-width:900px;margin-bottom:30px;">
    <div class="invoice-header-shape" style="position:relative;height:140px;overflow:hidden;border-top-left-radius:8px;border-top-right-radius:8px;">
      <svg width="100%" height="140" viewBox="0 0 800 140" preserveAspectRatio="none" style="display:block;position:absolute;top:0;left:0;width:100%;height:100%;"><rect x="0" y="0" width="800" height="140" fill="#61b146"/><path d="M240,0 L810,0 L810,80 Q610,120 240,80 Z" fill="#313a43"/><path d="M-50,140 Q400,60 850,140 Z" fill="white"/></svg>
      <div class="header-content"><img src="assets/logo.png" alt="Logo" class="invoice-logo-img"></div>
    </div>

    <div class="invoice-title-row">
      <div class="invoice-title">MONTHLY STATEMENT</div>
      <table class="invoice-meta-grid" style="border-collapse:collapse;background:transparent;font-size:0.85rem;">
        <tr><td style="font-weight:700;color:#424242;text-align:right;padding:0 15px 5px 0;border:none;">Period:</td><td style="color:#616161;text-align:right;padding:0 0 5px 0;border:none;">${monthName}</td></tr>
        <tr><td style="font-weight:700;color:#424242;text-align:right;padding:0 15px 0 0;border:none;">Generated:</td><td style="color:#616161;text-align:right;padding:0;border:none;">${fmtDate(new Date().toISOString().slice(0, 10))}</td></tr>
      </table>
    </div>

    <div class="invoice-billed-to" style="display:flex;justify-content:space-between;">
      <div style="padding-left:5px;">
        <h4 style="margin-bottom:12px;color:#424242;">FROM:</h4>
        <p style="font-weight:700;font-size:1rem;margin-bottom:8px;color:#2E7D32;">Town Treasure Limited</p>
        <div style="display: flex; flex-direction: column; gap: 6px;">
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg> 0708567696</p>
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"></path><polyline points="22,6 12,13 2,6"></polyline></svg> towntreasuregroceries@gmail.com</p>
        </div>
      </div>
      <div style="text-align:right;padding-right:5px;">
        <h4 style="margin-bottom:12px;color:#424242;">TO:</h4>
        <p style="font-weight:700;font-size:1rem;margin-bottom:8px;color:#424242;">${rest.name}</p>
        <p style="font-size:0.85rem;">${rest.address || ''}</p>
        <p style="font-size:0.85rem;">${rest.phone || ''}</p>
      </div>
    </div>

    <!-- Opening Balance -->
    <div style="margin:0 50px 15px;padding:12px 20px;background:#f8fafc;border-radius:8px;display:flex;justify-content:space-between;border:1px solid #e2e8f0;align-items:center;">
      <span style="font-weight:600;color:#424242;">Previous Unpaid Balance (Prior to 1 ${monthName.split(' ')[0]}):</span>
      <span style="font-weight:700;color:${openingBalance > 0 ? '#dc2626' : '#2E7D32'};font-size:1.05rem;">KES ${fmtMoney(openingBalance)}</span>
    </div>

    <!-- Transactions -->
    <div class="invoice-table-wrapper">
      <table class="receipt-table">
        <thead><tr>
          <th>Date</th><th>Description</th><th>Details</th>
          <th style="text-align:right;">Debit</th><th style="text-align:right;">Credit</th><th style="text-align:right;">Balance</th>
        </tr></thead>
        <tbody>
          ${txRows || '<tr><td colspan="6" style="text-align:center;padding:20px;color:#616161;">No transactions this month</td></tr>'}
        </tbody>
      </table>
    </div>

    <!-- Summary -->
    <div style="display:flex;justify-content:flex-end;padding:15px 50px;">
      <div style="width:380px;">
        <div style="display:flex;justify-content:space-between;padding:8px 0;font-size:0.9rem;"><span>Total Invoiced:</span><strong style="color:#dc2626;">KES ${fmtMoney(monthInvoicedTotal)}</strong></div>
        <div style="display:flex;justify-content:space-between;padding:8px 0;font-size:0.9rem;"><span>Total Paid:</span><strong style="color:#2E7D32;">KES ${fmtMoney(monthPaidTotal)}</strong></div>
        <div style="display:flex;justify-content:space-between;padding:10px 0;font-size:1.1rem;border-top:2px solid #61b146;margin-top:8px;">
          <span style="font-weight:700;">Total Amount Owed:</span>
          <strong style="color:${closingBalance > 0 ? '#dc2626' : '#2E7D32'};">KES ${fmtMoney(closingBalance)}</strong>
        </div>
      </div>
    </div>

    <!-- Age Analysis -->
    ${closingBalance > 0 ? `
    <div style="margin:10px 50px 20px;padding:15px 20px;background:#fff7ed;border-radius:8px;border:1px solid #fed7aa;">
      <h4 style="font-size:0.85rem;color:#92400e;margin-bottom:10px;display:flex;align-items:center;gap:6px;">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>
        Debt Age Analysis
      </h4>
      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px;font-size:0.82rem;">
        <div><div style="color:#616161;">Current</div><div style="font-weight:700;color:#2E7D32;">KES ${fmtMoney(current)}</div></div>
        <div><div style="color:#616161;">30 Days</div><div style="font-weight:700;color:#d97706;">KES ${fmtMoney(days30)}</div></div>
        <div><div style="color:#616161;">60 Days</div><div style="font-weight:700;color:#ea580c;">KES ${fmtMoney(days60)}</div></div>
        <div><div style="color:#616161;">90+ Days</div><div style="font-weight:700;color:#dc2626;">KES ${fmtMoney(days90)}</div></div>
      </div>
    </div>` : ''}

    <div class="invoice-footer-shape">
      <div style="position:absolute;bottom:20px;left:0;right:0;display:flex;justify-content:space-between;padding:0 50px;color:white;z-index:5;">
        <div style="font-style:italic;font-size:0.9rem;">Thank you for your business, ${rest.name}!</div>
        <div style="font-size:0.8rem;">Account Statement — ${monthName}</div>
      </div>
    </div>
    <div class="watermark-overlay" style="z-index:1;"><img src="assets/logo.png" alt="Stamp" class="watermark-stamp"><div class="watermark-text">Town Treasure Limited</div></div>
  </div>`;
}

function downloadStatementPDF() {
  const el = document.getElementById('statementOutput');
  if (!el || !el.innerHTML.trim()) return toast('Generate a statement first', 'error');
  downloadPDF('statementOutput', 'Statement');
}

function shareStatementWhatsApp() {
  const restId = document.getElementById('stmtRestaurant')?.value;
  const month = document.getElementById('stmtMonth')?.value;
  if (!restId || restId === '__all__') return toast('Select a specific restaurant to share', 'warning');

  const rest = DB.restaurants.find(r => r.id === restId);
  if (!rest) return;

  const [yr, mo] = month.split('-').map(Number);
  const monthName = new Date(yr, mo - 1, 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });

  let phone = rest.phone ? rest.phone.replace(/[^\d+]/g, '') : '';
  if (phone.startsWith('0')) phone = '254' + phone.slice(1);

  const text = `Hello ${rest.contact || rest.name},

Here is your account statement from Town Treasure Groceries for *${monthName}*.

Please find the attached PDF statement showing all invoices and payments for the period.

For any queries, please call 0708567696.

Thank you for your business!`;

  downloadStatementPDF();
  setTimeout(() => {
    window.open(`https://wa.me/${phone}?text=${encodeURIComponent(text)}`, '_blank');
  }, 1500);
}

/* ── Quick Statement from Restaurant Page ── */
function quickStatement(restId) {
  navigateTo('statements');
  setTimeout(() => {
    const restSelect = document.getElementById('stmtRestaurant');
    if (restSelect) restSelect.value = restId;
    const monthInput = document.getElementById('stmtMonth');
    if (monthInput && !monthInput.value) monthInput.value = new Date().toISOString().slice(0, 7);
    generateStatement();
  }, 100);
}
