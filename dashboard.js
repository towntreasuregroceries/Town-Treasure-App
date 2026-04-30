/* ══ Dashboard ══ */
let revenueChartInst = null, topRestChartInst = null;
function refreshDashboard() {
  const invs = DB.invoices;
  const now = new Date();
  const thisMonth = invs.filter(i => { const d = new Date(i.date); return d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear(); });
  const totalSales = thisMonth.reduce((s, i) => s + i.totalSell, 0);
  const totalProfit = thisMonth.reduce((s, i) => s + i.profit, 0);
  const totalCost = thisMonth.reduce((s, i) => s + i.totalBuy, 0);
  const paidCount = thisMonth.filter(i => i.status === 'paid').length;
  document.getElementById('dashboardStats').innerHTML = `
    <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/></svg></div><div class="stat-info"><h4>This Month Sales</h4><div class="stat-value">KES ${fmtMoney(totalSales)}</div><div class="stat-change up">${thisMonth.length} invoices</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6"/></svg></div><div class="stat-info"><h4>This Month Profit</h4><div class="stat-value">KES ${fmtMoney(totalProfit)}</div><div class="stat-change ${totalProfit>=0?'up':'down'}">${totalSales > 0 ? ((totalProfit/totalSales)*100).toFixed(1) + '% margin' : '—'}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon orange"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg></div><div class="stat-info"><h4>Total Cost (Buy)</h4><div class="stat-value">KES ${fmtMoney(totalCost)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 11-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg></div><div class="stat-info"><h4>Paid Invoices</h4><div class="stat-value">${paidCount} / ${thisMonth.length}</div></div></div>`;
  // Revenue chart - last 6 months
  const months = [];
  const salesData = [], profitData = [];
  for (let m = 5; m >= 0; m--) {
    const d = new Date(now.getFullYear(), now.getMonth() - m, 1);
    months.push(d.toLocaleDateString('en', { month: 'short', year: '2-digit' }));
    const mi = invs.filter(i => { const id = new Date(i.date); return id.getMonth() === d.getMonth() && id.getFullYear() === d.getFullYear(); });
    salesData.push(mi.reduce((s, i) => s + i.totalSell, 0));
    profitData.push(mi.reduce((s, i) => s + i.profit, 0));
  }
  if (revenueChartInst) revenueChartInst.destroy();
  const ctx1 = document.getElementById('revenueChart');
  if (ctx1) {
    revenueChartInst = new Chart(ctx1, {
      type: 'bar', data: {
        labels: months,
        datasets: [
          { label: 'Sales', data: salesData, backgroundColor: 'rgba(76,175,80,.7)', borderRadius: 6 },
          { label: 'Profit', data: profitData, backgroundColor: 'rgba(46,125,50,.85)', borderRadius: 6 }
        ]
      }, options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'bottom' } }, scales: { y: { beginAtZero: true } } }
    });
  }
  // Top restaurants chart (This Month)
  const restTotals = {};
  thisMonth.forEach(i => { restTotals[i.restaurantName] = (restTotals[i.restaurantName] || 0) + i.totalSell; });
  const sorted = Object.entries(restTotals).sort((a, b) => b[1] - a[1]).slice(0, 5);
  if (topRestChartInst) topRestChartInst.destroy();
  const ctx2 = document.getElementById('topRestaurantsChart');
  if (ctx2 && sorted.length) {
    const colors = ['#4CAF50','#66BB6A','#81C784','#A5D6A7','#C8E6C9'];
    topRestChartInst = new Chart(ctx2, {
      type: 'doughnut', data: {
        labels: sorted.map(s => s[0]),
        datasets: [{ data: sorted.map(s => s[1]), backgroundColor: colors }]
      }, options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'bottom', labels: { boxWidth: 12 } } } }
    });
  }
  // Recent invoices (This Month)
  const recent = thisMonth.slice().reverse().slice(0, 8);
  const tbody = document.getElementById('recentInvoicesBody');
  if (!recent.length) { tbody.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No invoices yet this month</h3><p>Create an invoice to see data here.</p></td></tr>'; return; }
  tbody.innerHTML = recent.map(i => {
    const bc = i.status === 'paid' ? 'badge-success' : i.status === 'overdue' ? 'badge-danger' : 'badge-warning';
    return `<tr style="cursor:pointer" onclick="viewInvoice('${i.id}')"><td><strong>${i.number}</strong></td><td>${i.restaurantName}</td><td>${fmtDate(i.date)}</td><td>KES ${fmtMoney(i.totalSell)}</td><td style="color:var(--green-700)">KES ${fmtMoney(i.profit)}</td><td><span class="badge ${bc}">${i.status}</span></td></tr>`;
  }).join('');
}

/* ══ Reports ══ */
function toggleReportRestaurant() {
  const t = document.getElementById('reportType').value;
  document.getElementById('reportRestaurantGroup').style.display = t === 'restaurant' ? 'block' : 'none';
  document.getElementById('reportProductGroup').style.display = t === 'product' ? 'block' : 'none';
  
  // Populate product dropdown when product type is selected
  if (t === 'product') {
    const productMap = {};
    DB.invoices.forEach(inv => {
      inv.items.forEach(item => {
        const name = item.desc.trim();
        const key = name.toLowerCase();
        if (!productMap[key]) productMap[key] = { name: name, qty: 0, unit: item.unit || 'pcs', count: 0 };
        productMap[key].qty += item.qty;
        productMap[key].count++;
      });
    });
    const select = document.getElementById('reportProduct');
    select.innerHTML = '<option value="">Select a product…</option>' + 
      Object.entries(productMap)
        .sort((a, b) => a[1].name.localeCompare(b[1].name))
        .map(([key, p]) => `<option value="${key}">${p.name} — ${p.qty} ${p.unit} sold (${p.count}x)</option>`)
        .join('');
  }
}
function toggleReportDate() {
  const t = document.getElementById('reportDateType')?.value || 'single';
  document.getElementById('reportSingleGroup').style.display = t === 'single' ? 'block' : 'none';
  document.getElementById('reportFromGroup').style.display = t === 'range' ? 'block' : 'none';
  document.getElementById('reportToGroup').style.display = t === 'range' ? 'block' : 'none';
}

function generateReport() {
  const type = document.getElementById('reportType').value;
  const dateType = document.getElementById('reportDateType')?.value || 'single';
  const restId = document.getElementById('reportRestaurant')?.value;
  
  let from = '', to = '', dateRange = '';
  
  if (dateType === 'single') {
    from = document.getElementById('reportSingleDate').value;
    to = from;
    dateRange = from ? fmtDate(from) : 'All Time';
  } else if (dateType === 'range') {
    from = document.getElementById('reportFrom').value;
    to = document.getElementById('reportTo').value;
    dateRange = (from ? fmtDate(from) : 'Start') + ' — ' + (to ? fmtDate(to) : 'Present');
  } else {
    dateRange = 'All Time';
  }
  
  // ── Invoice Data ──
  let invs = DB.invoices.slice();
  if (from) invs = invs.filter(i => i.date >= from);
  if (to) invs = invs.filter(i => i.date <= to);
  
  if (type === 'product') {
    const productName = (document.getElementById('reportProduct')?.value || '').toLowerCase().trim();
    if (!productName) return toast('Please select a product from the dropdown', 'error');
    
    // Find all line items matching the product across all invoices
    const matches = [];
    let totalQty = 0, totalSell = 0, totalBuy = 0;
    const byRestaurant = {};
    const byUnit = {};
    
    invs.forEach(inv => {
      inv.items.forEach(item => {
        if (item.desc.toLowerCase().trim().includes(productName)) {
          const unit = item.unit || 'pcs';
          matches.push({
            invoiceNum: inv.number,
            restaurant: inv.restaurantName,
            date: inv.date,
            qty: item.qty,
            unit: unit,
            sellPrice: item.sellPrice,
            buyPrice: item.buyPrice,
            total: item.total,
            cost: item.qty * item.buyPrice,
            profit: item.total - (item.qty * item.buyPrice)
          });
          totalQty += item.qty;
          totalSell += item.total;
          totalBuy += item.qty * item.buyPrice;
          
          // Group by restaurant
          if (!byRestaurant[inv.restaurantName]) byRestaurant[inv.restaurantName] = { qty: 0, sell: 0, buy: 0, count: 0 };
          byRestaurant[inv.restaurantName].qty += item.qty;
          byRestaurant[inv.restaurantName].sell += item.total;
          byRestaurant[inv.restaurantName].buy += item.qty * item.buyPrice;
          byRestaurant[inv.restaurantName].count++;
          
          // Group by unit
          if (!byUnit[unit]) byUnit[unit] = 0;
          byUnit[unit] += item.qty;
        }
      });
    });
    
    const totalProfit = totalSell - totalBuy;
    const unitSummary = Object.entries(byUnit).map(([u, q]) => `${q} ${u}`).join(', ');
    
    const output = document.getElementById('reportOutput');
    output.innerHTML = `
    <div class="invoice-preview" id="invoice-doc" style="max-width:900px;">
      <div class="invoice-header-shape" style="position:relative; height:140px; overflow:hidden; border-top-left-radius:8px; border-top-right-radius:8px;">
        <svg width="100%" height="140" viewBox="0 0 800 140" preserveAspectRatio="none" style="display:block; position:absolute; top:0; left:0; width:100%; height:100%;">
          <rect x="0" y="0" width="800" height="140" fill="#61b146"/>
          <path d="M240,0 L810,0 L810,80 Q610,120 240,80 Z" fill="#313a43"/>
          <path d="M-50,140 Q400,60 850,140 Z" fill="white"/>
        </svg>
        <div class="header-content">
           <img src="assets/logo.png" alt="Logo" class="invoice-logo-img">
        </div>
      </div>
      
      <div class="invoice-title-row">
         <div class="invoice-title">PRODUCT REPORT</div>
         <div class="invoice-meta-grid">
            <div class="meta-label">Product:</div>
            <div class="meta-value" style="text-transform: capitalize;">${productName}</div>
            <div class="meta-label">Period:</div>
            <div class="meta-value">${dateRange}</div>
         </div>
      </div>

      <!-- ═══ Product Summary ═══ -->
      <div style="display: flex; justify-content: space-between; margin: 0 50px 20px; border-top: 2px solid var(--border); border-bottom: 2px solid var(--border); padding: 15px 0;">
        <div>
          <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Qty Sold</h4>
          <div style="font-size: 1.2rem; font-weight: 700; color: #2563eb;">${unitSummary || '0'}</div>
          <div style="font-size: 0.75rem; color: #616161; margin-top: 3px;">${matches.length} transactions</div>
        </div>
        <div>
          <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Revenue</h4>
          <div style="font-size: 1.2rem; font-weight: 700; color: #2E7D32;">KES ${fmtMoney(totalSell)}</div>
        </div>
        <div>
          <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Cost</h4>
          <div style="font-size: 1.2rem; font-weight: 700; color: #dc2626;">KES ${fmtMoney(totalBuy)}</div>
        </div>
        <div>
          <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Profit</h4>
          <div style="font-size: 1.2rem; font-weight: 700; color: ${totalProfit >= 0 ? '#2E7D32' : '#dc2626'};">KES ${fmtMoney(totalProfit)}</div>
        </div>
      </div>

      <!-- ═══ By Restaurant ═══ -->
      ${Object.keys(byRestaurant).length > 0 ? `
      <div class="invoice-table-wrapper" style="margin-bottom: 20px;">
         <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">Sales by Restaurant</h3>
         <table class="receipt-table">
            <thead><tr><th>Restaurant</th><th style="text-align: center;">Times Ordered</th><th style="text-align: right;">Qty</th><th style="text-align: right;">Revenue</th><th style="text-align: right;">Cost</th><th style="text-align: right;">Profit</th></tr></thead>
            <tbody>${Object.entries(byRestaurant).sort((a,b)=>b[1].sell-a[1].sell).map(([name,d])=>`<tr><td><strong>${name}</strong></td><td style="text-align: center;">${d.count}</td><td style="text-align: right;">${d.qty}</td><td style="text-align: right;">KES ${fmtMoney(d.sell)}</td><td style="text-align: right;">KES ${fmtMoney(d.buy)}</td><td style="text-align: right; color: var(--green-700);">KES ${fmtMoney(d.sell - d.buy)}</td></tr>`).join('')}</tbody>
         </table>
      </div>
      ` : ''}

      <!-- ═══ Transaction History ═══ -->
      <div class="invoice-table-wrapper" style="margin-bottom: 20px; position: relative; z-index: 2;">
         <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">Transaction History</h3>
         ${matches.length > 0 ? `
         <table class="receipt-table">
            <thead><tr><th>Invoice</th><th>Restaurant</th><th>Date</th><th style="text-align: right;">Qty</th><th>Unit</th><th style="text-align: right;">Sell Price</th><th style="text-align: right;">Total</th><th style="text-align: right;">Profit</th></tr></thead>
            <tbody>${matches.sort((a,b)=>a.date.localeCompare(b.date)).map(m=>`<tr><td>${m.invoiceNum}</td><td>${m.restaurant}</td><td>${fmtDate(m.date)}</td><td style="text-align: right;">${m.qty}</td><td style="text-transform: capitalize;">${m.unit}</td><td style="text-align: right;">KES ${fmtMoney(m.sellPrice)}</td><td style="text-align: right;">KES ${fmtMoney(m.total)}</td><td style="text-align: right; color: var(--green-700);">KES ${fmtMoney(m.profit)}</td></tr>`).join('')}</tbody>
         </table>
         ` : '<p style="padding: 20px; color: #616161;">No transactions found for this product in the selected period.</p>'}
      </div>

      <div class="invoice-footer-shape">
         <div style="position: absolute; bottom: 18px; left: 0; right: 0; display: flex; justify-content: space-between; padding: 0 50px; color: white; z-index: 5;">
            <div style="font-style: italic; font-size: 0.85rem;">Generated on ${fmtDate(new Date().toISOString().slice(0,10))} — Town Treasure Groceries</div>
            <div style="font-size: 0.75rem;">Product Report</div>
         </div>
      </div>
      <div class="watermark-overlay" style="z-index: 1;">
         <img src="assets/logo.png" alt="Stamp" class="watermark-stamp">
         <div class="watermark-text">Town Treasure Groceries</div>
      </div>
    </div>`;
    return; // Exit early — product report is done
  }
  
  if (type === 'restaurant' && restId) invs = invs.filter(i => i.restaurantId === restId);
  const totalSell = invs.reduce((s, i) => s + i.totalSell, 0);
  const totalBuy = invs.reduce((s, i) => s + i.totalBuy, 0);
  const totalProfit = invs.reduce((s, i) => s + i.profit, 0);
  const paidTotal = invs.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);
  const pendingTotal = invs.filter(i => i.status !== 'paid').reduce((s, i) => s + i.totalSell, 0);
  const restName = type === 'restaurant' ? (DB.restaurants.find(r => r.id === restId)?.name || 'Unknown') : 'All Restaurants';

  // ── Expenses & Capital Data ──
  let expenses = DB.expenses.slice();
  if (from) expenses = expenses.filter(e => e.date >= from);
  if (to) expenses = expenses.filter(e => e.date <= to);
  const expenseItems = expenses.filter(e => e.type === 'expense');
  const capitalItems = expenses.filter(e => e.type === 'capital');
  const totalExpenses = expenseItems.reduce((s, e) => s + e.amount, 0);
  const totalCapital = capitalItems.reduce((s, e) => s + e.amount, 0);
  
  // Group expenses by category
  const byCategory = {};
  expenseItems.forEach(e => {
    if (!byCategory[e.category]) byCategory[e.category] = { total: 0, count: 0 };
    byCategory[e.category].total += e.amount;
    byCategory[e.category].count++;
  });

  // ── Net Position ──
  const netIncome = paidTotal - totalBuy;
  const netPosition = totalCapital + paidTotal - totalBuy - totalExpenses;

  // Group invoices by restaurant
  const byRest = {};
  invs.forEach(i => {
    if (!byRest[i.restaurantName]) byRest[i.restaurantName] = { sell: 0, buy: 0, profit: 0, count: 0 };
    byRest[i.restaurantName].sell += i.totalSell;
    byRest[i.restaurantName].buy += i.totalBuy;
    byRest[i.restaurantName].profit += i.profit;
    byRest[i.restaurantName].count++;
  });

  const output = document.getElementById('reportOutput');
  output.innerHTML = `
  <div class="invoice-preview" id="invoice-doc" style="max-width:900px;">
    <div class="invoice-header-shape" style="position:relative; height:140px; overflow:hidden; border-top-left-radius:8px; border-top-right-radius:8px;">
      <svg width="100%" height="140" viewBox="0 0 800 140" preserveAspectRatio="none" style="display:block; position:absolute; top:0; left:0; width:100%; height:100%;">
        <rect x="0" y="0" width="800" height="140" fill="#61b146"/>
        <path d="M240,0 L810,0 L810,80 Q610,120 240,80 Z" fill="#313a43"/>
        <path d="M-50,140 Q400,60 850,140 Z" fill="white"/>
      </svg>
      <div class="header-content">
         <img src="assets/logo.png" alt="Logo" class="invoice-logo-img">
      </div>
    </div>
    
    <div class="invoice-title-row">
       <div class="invoice-title">FINANCIAL REPORT</div>
       <div class="invoice-meta-grid">
          <div class="meta-label">For:</div>
          <div class="meta-value">${restName}</div>
          <div class="meta-label">Period:</div>
          <div class="meta-value">${dateRange}</div>
       </div>
    </div>

    <!-- ═══ Financial Summary ═══ -->
    <div style="display: flex; justify-content: space-between; margin: 0 50px 20px; border-top: 2px solid var(--border); border-bottom: 2px solid var(--border); padding: 15px 0;">
      <div>
        <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Sales</h4>
        <div style="font-size: 1.2rem; font-weight: 700; color: #2E7D32;">KES ${fmtMoney(totalSell)}</div>
        <div style="font-size: 0.75rem; color: #61b146; margin-top: 3px; font-weight: 600;">${invs.length} invoices</div>
      </div>
      <div>
        <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Total Profit</h4>
        <div style="font-size: 1.2rem; font-weight: 700; color: #2E7D32;">KES ${fmtMoney(totalProfit)}</div>
      </div>
      <div>
        <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Expenses</h4>
        <div style="font-size: 1.2rem; font-weight: 700; color: #dc2626;">KES ${fmtMoney(totalExpenses)}</div>
      </div>
      <div>
        <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Capital In</h4>
        <div style="font-size: 1.2rem; font-weight: 700; color: #2563eb;">KES ${fmtMoney(totalCapital)}</div>
      </div>
      <div>
        <h4 style="font-size: 0.75rem; color: #616161; text-transform: uppercase; margin-bottom: 4px; font-weight: 600;">Net Position</h4>
        <div style="font-size: 1.2rem; font-weight: 700; color: ${netPosition >= 0 ? '#2E7D32' : '#dc2626'};">KES ${fmtMoney(netPosition)}</div>
      </div>
    </div>
    
    <!-- ═══ Payment Status ═══ -->
    <div style="display: flex; gap: 20px; margin: 0 50px 20px;">
      <div style="flex: 1; background: #f0fdf4; border-radius: 8px; padding: 12px 16px;">
        <div style="font-size: 0.75rem; color: #616161; text-transform: uppercase; font-weight: 600;">Paid</div>
        <div style="font-size: 1.1rem; font-weight: 700; color: #2E7D32;">KES ${fmtMoney(paidTotal)}</div>
      </div>
      <div style="flex: 1; background: #fffbeb; border-radius: 8px; padding: 12px 16px;">
        <div style="font-size: 0.75rem; color: #616161; text-transform: uppercase; font-weight: 600;">Pending</div>
        <div style="font-size: 1.1rem; font-weight: 700; color: #d97706;">KES ${fmtMoney(pendingTotal)}</div>
      </div>
    </div>

    <!-- ═══ Restaurant Breakdown ═══ -->
    <div class="invoice-table-wrapper" style="margin-bottom: 20px;">
       <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">Sales by Restaurant</h3>
       <table class="receipt-table">
          <thead><tr><th>Restaurant</th><th>Invoices</th><th style="text-align: right;">Total Sales</th><th style="text-align: right;">Total Cost</th><th style="text-align: right;">Profit</th><th style="text-align: center;">Margin</th></tr></thead>
          <tbody>${Object.entries(byRest).sort((a,b)=>b[1].sell-a[1].sell).map(([name,d])=>`<tr><td><strong>${name}</strong></td><td>${d.count}</td><td style="text-align: right;">KES ${fmtMoney(d.sell)}</td><td style="text-align: right;">KES ${fmtMoney(d.buy)}</td><td style="text-align: right; color:var(--green-700)">KES ${fmtMoney(d.profit)}</td><td style="text-align: center;">${d.sell>0?((d.profit/d.sell)*100).toFixed(1)+'%':'—'}</td></tr>`).join('')}</tbody>
       </table>
    </div>

    <!-- ═══ Expenses by Category ═══ -->
    ${Object.keys(byCategory).length > 0 ? `
    <div class="invoice-table-wrapper" style="margin-bottom: 20px;">
       <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">Expenses by Category</h3>
       <table class="receipt-table">
          <thead><tr><th>Category</th><th style="text-align: center;">Entries</th><th style="text-align: right;">Total Amount</th><th style="text-align: center;">% of Expenses</th></tr></thead>
          <tbody>${Object.entries(byCategory).sort((a,b)=>b[1].total-a[1].total).map(([cat,d])=>`<tr><td style="text-transform: capitalize;"><strong>${cat}</strong></td><td style="text-align: center;">${d.count}</td><td style="text-align: right; color: #dc2626;">KES ${fmtMoney(d.total)}</td><td style="text-align: center;">${totalExpenses>0?((d.total/totalExpenses)*100).toFixed(1)+'%':'—'}</td></tr>`).join('')}</tbody>
       </table>
    </div>
    ` : ''}

    <!-- ═══ Capital Injections ═══ -->
    ${capitalItems.length > 0 ? `
    <div class="invoice-table-wrapper" style="margin-bottom: 20px;">
       <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">Capital Injections</h3>
       <table class="receipt-table">
          <thead><tr><th>Date</th><th>Description</th><th>Category</th><th style="text-align: right;">Amount</th></tr></thead>
          <tbody>${capitalItems.sort((a,b)=>a.date.localeCompare(b.date)).map(e=>`<tr><td>${fmtDate(e.date)}</td><td>${e.desc}</td><td style="text-transform: capitalize;">${e.category}</td><td style="text-align: right; color: #2563eb;">KES ${fmtMoney(e.amount)}</td></tr>`).join('')}</tbody>
       </table>
    </div>
    ` : ''}

    <!-- ═══ All Invoices ═══ -->
    <div class="invoice-table-wrapper" style="margin-bottom: 20px; position: relative; z-index: 2;">
       <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">All Invoices</h3>
       <table class="receipt-table">
          <thead><tr><th>#</th><th>Restaurant</th><th>Date</th><th style="text-align: right;">Amount</th><th style="text-align: right;">Profit</th><th style="text-align: center;">Status</th></tr></thead>
          <tbody>${invs.sort((a,b)=>a.date.localeCompare(b.date)).map(i=>`<tr><td>${i.number}</td><td>${i.restaurantName}</td><td>${fmtDate(i.date)}</td><td style="text-align: right;">KES ${fmtMoney(i.totalSell)}</td><td style="text-align: right;">KES ${fmtMoney(i.profit)}</td><td style="text-align: center;"><span class="badge ${i.status==='paid'?'badge-success':'badge-warning'}">${i.status}</span></td></tr>`).join('')}</tbody>
       </table>
    </div>

    <!-- ═══ Expense Details ═══ -->
    ${expenseItems.length > 0 ? `
    <div class="invoice-table-wrapper" style="margin-bottom: 20px; position: relative; z-index: 2;">
       <h3 style="font-size:0.95rem;margin-bottom:10px;color: #424242;">All Expenses</h3>
       <table class="receipt-table">
          <thead><tr><th>Date</th><th>Description</th><th>Category</th><th style="text-align: right;">Amount</th></tr></thead>
          <tbody>${expenseItems.sort((a,b)=>a.date.localeCompare(b.date)).map(e=>`<tr><td>${fmtDate(e.date)}</td><td>${e.desc}</td><td style="text-transform: capitalize;">${e.category}</td><td style="text-align: right; color: #dc2626;">KES ${fmtMoney(e.amount)}</td></tr>`).join('')}</tbody>
       </table>
    </div>
    ` : ''}

    <div class="invoice-footer-shape">
       <div style="position: absolute; bottom: 18px; left: 0; right: 0; display: flex; justify-content: space-between; padding: 0 50px; color: white; z-index: 5;">
          <div style="font-style: italic; font-size: 0.85rem;">Generated on ${fmtDate(new Date().toISOString().slice(0,10))} — Town Treasure Groceries</div>
          <div style="font-size: 0.75rem;">Financial Report</div>
       </div>
    </div>
    <div class="watermark-overlay" style="z-index: 1;">
       <img src="assets/logo.png" alt="Stamp" class="watermark-stamp">
       <div class="watermark-text">Town Treasure Groceries</div>
    </div>
  </div>`;
}
function printReport() { window.print(); }

/* ══ Init ══ */
document.addEventListener('DOMContentLoaded', async () => {
  document.getElementById('headerDate').textContent = new Date().toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long',year:'numeric'});
  document.getElementById('invDate').value = new Date().toISOString().slice(0,10);
  document.getElementById('expDate').value = new Date().toISOString().slice(0,10);
  
  const today = new Date().toISOString().slice(0,10);
  if (document.getElementById('reportSingleDate')) document.getElementById('reportSingleDate').value = today;
  document.getElementById('reportFrom').value = today;
  document.getElementById('reportTo').value = today;
  if (document.getElementById('reportDateType')) {
    document.getElementById('reportDateType').value = 'single';
    toggleReportDate();
  }
  
  if (typeof DB !== 'undefined' && DB.loadFromSupabase) {
    await DB.loadFromSupabase();
  }
  
  populateRestaurantDropdowns();
  refreshDashboard();
});
