/* ══ Smart Insights Engine ══ */

function generateInsights() {
  const insights = { urgent: [], attention: [], good: [] };
  const now = new Date();
  const thisMonth = now.toISOString().slice(0, 7);
  const lastMonthDate = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const lastMonth = lastMonthDate.toISOString().slice(0, 7);

  const activeInvoices = DB.invoices.filter(i => i.status !== 'draft');
  const thisMonthInvs = activeInvoices.filter(i => i.date && i.date.startsWith(thisMonth));
  const lastMonthInvs = activeInvoices.filter(i => i.date && i.date.startsWith(lastMonth));

  // 🔴 URGENT: Overdue invoices
  const overdue = activeInvoices.filter(i => {
    if (i.status === 'paid') return false;
    if (i.dueDate && new Date(i.dueDate) < now) return true;
    // If no due date, consider overdue after 30 days
    const invDate = new Date(i.date);
    return (now - invDate) > 30 * 24 * 60 * 60 * 1000 && i.status !== 'paid';
  });
  if (overdue.length > 0) {
    const total = overdue.reduce((s, i) => s + i.totalSell, 0);
    insights.urgent.push(`${overdue.length} invoice${overdue.length > 1 ? 's' : ''} overdue — total <strong>KES ${fmtMoney(total)}</strong> outstanding`);
  }

  // 🔴 URGENT: Unpaid salaries
  const activeStaff = DB.staff.filter(s => s.status === 'active');
  const unpaidStaff = activeStaff.filter(s => {
    const isPaid = DB.salaryPayments.some(p => p.staffId === s.id && p.month === thisMonth);
    if (isPaid) return false;
    const payDay = parseInt(s.payDay) || 5;
    return now.getDate() >= payDay;
  });
  if (unpaidStaff.length > 0) {
    const names = unpaidStaff.map(s => s.name).join(', ');
    const total = unpaidStaff.reduce((s, x) => s + x.salary, 0);
    insights.urgent.push(`Unpaid salaries: <strong>${names}</strong> — KES ${fmtMoney(total)}`);
  }

  // 🔴 URGENT: Recurring expenses due/overdue
  const recurringDue = DB.recurringExpenses.filter(r => {
    const dueDay = parseInt(r.dueDay) || 1;
    const isPaid = DB.expenses.some(e => e.category === r.category && e.desc === r.desc && e.date && e.date.startsWith(thisMonth));
    return !isPaid && now.getDate() >= dueDay;
  });
  if (recurringDue.length > 0) {
    recurringDue.forEach(r => {
      insights.urgent.push(`<strong>${r.desc}</strong> (KES ${fmtMoney(r.amount)}) is due — not yet paid this month`);
    });
  }

  // 🟡 ATTENTION: Restaurants with old unpaid invoices
  const restDebts = {};
  activeInvoices.filter(i => i.status !== 'paid').forEach(inv => {
    const days = Math.floor((now - new Date(inv.date)) / (1000 * 60 * 60 * 24));
    if (days > 30) {
      if (!restDebts[inv.restaurantName]) restDebts[inv.restaurantName] = { total: 0, days: 0 };
      restDebts[inv.restaurantName].total += inv.totalSell;
      restDebts[inv.restaurantName].days = Math.max(restDebts[inv.restaurantName].days, days);
    }
  });
  Object.entries(restDebts).forEach(([name, d]) => {
    insights.attention.push(`<strong>${name}</strong> owes KES ${fmtMoney(d.total)} — oldest invoice is ${d.days} days old`);
  });

  // 🟡 ATTENTION: Borrowed Loans (Boss's Account)
  const borrowings = DB.borrowings;
  if (borrowings && borrowings.length > 0) {
    let totalBorrowed = 0;
    let totalRepaid = 0;
    borrowings.forEach(loan => {
      if (loan.type !== 'repay') {
        totalBorrowed += loan.amount || 0;
        const repaid = (loan.repayments || []).reduce((s, r) => s + (r.amount || 0), 0);
        totalRepaid += repaid;
      }
    });
    const outstanding = totalBorrowed - totalRepaid;
    if (outstanding > 0) {
      insights.attention.push(`<strong>Boss's Account</strong> has an outstanding loan balance of KES ${fmtMoney(outstanding)}. Consider making partial repayments to clear it.`);
    }
  }

  // 🟡 ATTENTION: Expense category spikes vs last month
  const thisMonthExps = DB.expenses.filter(e => e.type === 'expense' && e.date && e.date.startsWith(thisMonth));
  const lastMonthExps = DB.expenses.filter(e => e.type === 'expense' && e.date && e.date.startsWith(lastMonth));
  const thisByCategory = {};
  const lastByCategory = {};
  thisMonthExps.forEach(e => { thisByCategory[e.category] = (thisByCategory[e.category] || 0) + e.amount; });
  lastMonthExps.forEach(e => { lastByCategory[e.category] = (lastByCategory[e.category] || 0) + e.amount; });

  Object.entries(thisByCategory).forEach(([cat, amount]) => {
    const lastAmt = lastByCategory[cat] || 0;
    if (lastAmt > 0) {
      const pctChange = ((amount - lastAmt) / lastAmt) * 100;
      if (pctChange > 25) {
        insights.attention.push(`<strong style="text-transform:capitalize">${cat}</strong> expenses up ${pctChange.toFixed(0)}% vs last month (KES ${fmtMoney(amount)} vs ${fmtMoney(lastAmt)})`);
      }
    }
  });

  // 🟢 GOOD NEWS: Revenue comparison
  const thisRevenue = thisMonthInvs.reduce((s, i) => s + i.totalSell, 0);
  const lastRevenue = lastMonthInvs.reduce((s, i) => s + i.totalSell, 0);
  if (thisRevenue > 0 && lastRevenue > 0) {
    const pct = ((thisRevenue - lastRevenue) / lastRevenue) * 100;
    if (pct > 0) {
      insights.good.push(`Revenue up <strong>${pct.toFixed(0)}%</strong> this month — KES ${fmtMoney(thisRevenue)} vs KES ${fmtMoney(lastRevenue)} last month`);
    } else if (pct < -5) {
      insights.attention.push(`Revenue down <strong>${Math.abs(pct).toFixed(0)}%</strong> vs last month`);
    }
  } else if (thisRevenue > 0) {
    insights.good.push(`This month's revenue: <strong>KES ${fmtMoney(thisRevenue)}</strong> from ${thisMonthInvs.length} invoices`);
  }

  // 🟢 GOOD NEWS: Top customer this month
  if (thisMonthInvs.length > 0) {
    const byRest = {};
    thisMonthInvs.forEach(i => { byRest[i.restaurantName] = (byRest[i.restaurantName] || 0) + i.totalSell; });
    const top = Object.entries(byRest).sort((a, b) => b[1] - a[1])[0];
    if (top) {
      insights.good.push(`Top customer: <strong>${top[0]}</strong> — KES ${fmtMoney(top[1])} this month`);
    }
  }

  // 🟢 GOOD NEWS: Profit margin
  const thisProfit = thisMonthInvs.reduce((s, i) => s + i.profit, 0);
  if (thisRevenue > 0) {
    const margin = (thisProfit / thisRevenue) * 100;
    insights.good.push(`Gross profit margin: <strong>${margin.toFixed(1)}%</strong> this month`);
  }

  // 🟢 GOOD NEWS: All salaries paid
  if (activeStaff.length > 0 && unpaidStaff.length === 0 && now.getDate() >= 5) {
    insights.good.push(`All ${activeStaff.length} staff salaries paid this month`);
  }

  // 🟢 Milestone
  const totalInvoices = activeInvoices.length;
  const milestones = [10, 25, 50, 100, 250, 500, 1000];
  milestones.forEach(m => {
    if (totalInvoices >= m && totalInvoices < m + 5) {
      insights.good.push(`Milestone: <strong>${m}+ invoices</strong> created!`);
    }
  });

  return insights;
}

function renderInsightsPanel() {
  const el = document.getElementById('insightsPanel');
  if (!el) return;

  const insights = generateInsights();
  const hasAny = insights.urgent.length + insights.attention.length + insights.good.length > 0;

  if (!hasAny) {
    el.innerHTML = `<div class="card" style="margin-bottom:24px;">
      <div class="card-header"><h3><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:text-bottom;margin-right:8px"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path><polyline points="16 17 21 12 16 7"></polyline><line x1="21" y1="12" x2="9" y2="12"></line></svg> Smart Insights</h3></div>
      <div class="card-body"><p style="color:var(--text-2);text-align:center;padding:20px;">Everything looks good! No alerts right now.</p></div>
    </div>`;
    return;
  }

  let html = `<div class="card" style="margin-bottom:24px;">
    <div class="card-header"><h3><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:text-bottom;margin-right:8px"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path><polyline points="16 17 21 12 16 7"></polyline><line x1="21" y1="12" x2="9" y2="12"></line></svg> Smart Insights</h3></div>
    <div class="card-body" style="padding:16px 22px;">`;

  if (insights.urgent.length) {
    html += `<div class="insight-section"><div class="insight-label insight-urgent">Urgent</div>`;
    insights.urgent.forEach(msg => { html += `<div class="insight-item insight-item-urgent">${msg}</div>`; });
    html += `</div>`;
  }

  if (insights.attention.length) {
    html += `<div class="insight-section"><div class="insight-label insight-attention">Attention</div>`;
    insights.attention.forEach(msg => { html += `<div class="insight-item insight-item-attention">${msg}</div>`; });
    html += `</div>`;
  }

  if (insights.good.length) {
    html += `<div class="insight-section"><div class="insight-label insight-good">Good News</div>`;
    insights.good.forEach(msg => { html += `<div class="insight-item insight-item-good">${msg}</div>`; });
    html += `</div>`;
  }

  html += `</div></div>`;
  el.innerHTML = html;
}

/* ══ Dynamic Monthly P&L ══ */
function renderMonthlyPnL() {
  const el = document.getElementById('monthlyPnL');
  if (!el) return;

  const monthSelect = document.getElementById('pnlMonth');
  const month = monthSelect?.value || new Date().toISOString().slice(0, 7);
  const [yr, mo] = month.split('-').map(Number);
  const monthName = new Date(yr, mo - 1, 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });

  // Previous month for comparison
  const prevDate = new Date(yr, mo - 2, 1);
  const prevMonth = prevDate.toISOString().slice(0, 7);

  // Revenue
  const invs = DB.invoices.filter(i => i.status !== 'draft' && i.date && i.date.startsWith(month));
  const prevInvs = DB.invoices.filter(i => i.status !== 'draft' && i.date && i.date.startsWith(prevMonth));
  const revenue = invs.reduce((s, i) => s + i.totalSell, 0);
  const prevRevenue = prevInvs.reduce((s, i) => s + i.totalSell, 0);
  const cogs = invs.reduce((s, i) => s + i.totalBuy, 0);
  const grossProfit = revenue - cogs;

  // Expenses by category
  const exps = DB.expenses.filter(e => e.type === 'expense' && e.date && e.date.startsWith(month));
  const expByCategory = {};
  exps.forEach(e => {
    const label = getExpenseCategoryLabel(e.category);
    expByCategory[label] = (expByCategory[label] || 0) + e.amount;
  });
  const totalExpenses = exps.reduce((s, e) => s + e.amount, 0);

  // Salaries total
  const salaryTotal = DB.salaryPayments.filter(p => p.month === month).reduce((s, p) => s + p.amount, 0);

  // Capital
  const capital = DB.expenses.filter(e => e.type === 'capital' && e.date && e.date.startsWith(month)).reduce((s, e) => s + e.amount, 0);

  // Net profit
  const netProfit = grossProfit - totalExpenses;
  const prevNetProfit = prevInvs.reduce((s, i) => s + i.profit, 0) - DB.expenses.filter(e => e.type === 'expense' && e.date && e.date.startsWith(prevMonth)).reduce((s, e) => s + e.amount, 0);

  // Revenue change badge
  let revBadge = '';
  if (prevRevenue > 0) {
    const pct = ((revenue - prevRevenue) / prevRevenue) * 100;
    revBadge = `<span class="stat-change ${pct >= 0 ? 'up' : 'down'}" style="margin-left:8px;">${pct >= 0 ? '↑' : '↓'}${Math.abs(pct).toFixed(1)}% vs last month</span>`;
  }

  // Expense category rows
  const catRows = Object.entries(expByCategory).sort((a, b) => b[1] - a[1]).map(([cat, amt]) =>
    `<div style="display:flex;justify-content:space-between;padding:4px 0;font-size:0.88rem;"><span style="color:var(--text-2);">${cat}</span><span style="color:#dc2626;">(KES ${fmtMoney(amt)})</span></div>`
  ).join('');

  el.innerHTML = `
  <div class="card" style="margin-bottom:24px;">
    <div class="card-header">
      <h3><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:text-bottom;margin-right:8px"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path></svg> Monthly P&L</h3>
      <input type="month" class="form-control" id="pnlMonth" value="${month}" onchange="renderMonthlyPnL()" style="width:auto;padding:6px 10px;font-size:0.85rem;">
    </div>
    <div class="card-body">
      <h4 style="font-size:0.85rem;color:var(--text-2);margin-bottom:16px;">${monthName} ${revBadge}</h4>

      <div style="margin-bottom:16px;">
        <div style="font-size:0.75rem;color:var(--text-2);text-transform:uppercase;font-weight:600;margin-bottom:8px;">Income</div>
        <div style="display:flex;justify-content:space-between;padding:4px 0;font-size:0.92rem;"><span>Sales Revenue</span><strong style="color:#2E7D32;">KES ${fmtMoney(revenue)}</strong></div>
        <div style="display:flex;justify-content:space-between;padding:4px 0;font-size:0.88rem;"><span style="color:var(--text-2);">Less: Cost of Goods</span><span style="color:#dc2626;">(KES ${fmtMoney(cogs)})</span></div>
        <div style="display:flex;justify-content:space-between;padding:8px 0;font-size:0.95rem;border-top:1px solid var(--border);margin-top:6px;">
          <strong>Gross Profit</strong>
          <strong style="color:${grossProfit >= 0 ? '#2E7D32' : '#dc2626'};">KES ${fmtMoney(grossProfit)} ${revenue > 0 ? '(' + (grossProfit / revenue * 100).toFixed(1) + '%)' : ''}</strong>
        </div>
      </div>

      <div style="margin-bottom:16px;">
        <div style="font-size:0.75rem;color:var(--text-2);text-transform:uppercase;font-weight:600;margin-bottom:8px;">Expenses</div>
        ${salaryTotal > 0 ? `<div style="display:flex;justify-content:space-between;padding:4px 0;font-size:0.88rem;"><span style="color:var(--text-2);">Salaries & Payroll</span><span style="color:#dc2626;">(KES ${fmtMoney(salaryTotal)})</span></div>` : ''}
        ${catRows}
        <div style="display:flex;justify-content:space-between;padding:8px 0;font-size:0.92rem;border-top:1px solid var(--border);margin-top:6px;">
          <strong>Total Expenses</strong><strong style="color:#dc2626;">(KES ${fmtMoney(totalExpenses)})</strong>
        </div>
      </div>

      <div style="background:${netProfit >= 0 ? '#f0fdf4' : '#fef2f2'};border-radius:8px;padding:14px 18px;margin-top:12px;">
        <div style="display:flex;justify-content:space-between;font-size:1.1rem;">
          <strong>NET PROFIT</strong>
          <strong style="color:${netProfit >= 0 ? '#2E7D32' : '#dc2626'};">KES ${fmtMoney(netProfit)} ${revenue > 0 ? '(' + (netProfit / revenue * 100).toFixed(1) + '%)' : ''}</strong>
        </div>
      </div>

      ${capital > 0 ? `<div style="display:flex;justify-content:space-between;padding:10px 0;font-size:0.88rem;margin-top:8px;"><span style="color:var(--text-2);">Capital Added</span><strong style="color:#2563eb;">KES ${fmtMoney(capital)}</strong></div>` : ''}
    </div>
  </div>`;
}

function getExpenseCategoryLabel(cat) {
  const labels = {
    'transport': 'Transport', 'rent': 'Rent', 'utilities': 'Utilities',
    'supplies': 'Supplies', 'salaries': 'Salaries', 'inventory': 'Inventory',
    'capital': 'Capital', 'other': 'Other',
    'personal': 'Personal', 'airtime': 'Airtime', 'food_personal': 'Food & Meals',
    'medical': 'Medical', 'family': 'Family', 'clothing': 'Clothing',
    'entertainment': 'Entertainment', 'savings': 'Savings',
    'personal_transport': 'Personal Transport', 'other_personal': 'Other Personal'
  };
  return labels[cat] || cat;
}
