/* ══ Payroll & Monthly Salaries Module ══ */

/* ── Staff Register ── */
function openStaffModal(id) {
  const modal = document.getElementById('staffModal');
  document.getElementById('staffModalTitle').textContent = id ? 'Edit Staff' : 'Add Staff';
  if (id) {
    const s = DB.staff.find(x => x.id === id);
    if (!s) return;
    document.getElementById('editStaffId').value = s.id;
    document.getElementById('staffName').value = s.name || '';
    document.getElementById('staffRole').value = s.role || '';
    document.getElementById('staffSalary').value = s.salary || '';
    document.getElementById('staffPhone').value = s.phone || '';
    document.getElementById('staffPayDay').value = s.payDay || '5';
  } else {
    document.getElementById('editStaffId').value = '';
    ['staffName', 'staffRole', 'staffPhone'].forEach(f => document.getElementById(f).value = '');
    document.getElementById('staffSalary').value = '';
    document.getElementById('staffPayDay').value = '5';
  }
  openModal('staffModal');
}

function saveStaff() {
  const id = document.getElementById('editStaffId').value;
  const name = document.getElementById('staffName').value.trim();
  const role = document.getElementById('staffRole').value.trim();
  const salary = parseFloat(document.getElementById('staffSalary').value) || 0;
  const phone = document.getElementById('staffPhone').value.trim();
  const payDay = document.getElementById('staffPayDay').value || '5';

  if (!name) return toast('Staff name is required', 'error');
  if (!salary) return toast('Salary amount is required', 'error');

  const staffMember = {
    id: id || genId(),
    name, role, salary, phone, payDay,
    status: 'active',
    createdAt: new Date().toISOString()
  };

  const list = DB.staff;
  const idx = list.findIndex(x => x.id === staffMember.id);
  if (idx >= 0) {
    staffMember.createdAt = list[idx].createdAt;
    list[idx] = staffMember;
  } else {
    list.push(staffMember);
  }
  DB.staff = list;
  closeModal('staffModal');
  renderPayrollTab();
  toast(idx >= 0 ? 'Staff updated' : 'Staff added');
}

function deleteStaff(id) {
  customConfirm('This staff member will be moved to the Recycle Bin.', 'Remove Staff', 'Yes, Remove', true, () => {
    const s = DB.staff.find(x => x.id === id);
    if (s) {
      const deleted = { ...s, deletedAt: new Date().toISOString() };
      const bin = DB.deletedStaff;
      bin.push(deleted);
      DB.deletedStaff = bin;
    }
    DB.staff = DB.staff.filter(x => x.id !== id);
    renderPayrollTab();
    toast('Staff moved to Recycle Bin');
  });
}

function restoreStaff(id) {
  const bin = DB.deletedStaff;
  const s = bin.find(x => x.id === id);
  if (!s) return;
  const restored = { ...s };
  delete restored.deletedAt;
  const list = DB.staff;
  list.push(restored);
  DB.staff = list;
  DB.deletedStaff = bin.filter(x => x.id !== id);
  renderBin();
  toast('Staff member restored');
}

/* ── Monthly Salary Payments ── */
function getPayrollMonth() {
  return document.getElementById('payrollMonth')?.value || new Date().toISOString().slice(0, 7);
}

function isSalaryPaid(staffId, month) {
  return DB.salaryPayments.some(p => p.staffId === staffId && p.month === month);
}

function getSalaryPayment(staffId, month) {
  return DB.salaryPayments.find(p => p.staffId === staffId && p.month === month);
}

function markSalaryPaid(staffId) {
  const month = getPayrollMonth();
  const s = DB.staff.find(x => x.id === staffId);
  if (!s) return;

  if (isSalaryPaid(staffId, month)) {
    toast('Already paid for this month', 'warning');
    return;
  }

  const payment = {
    id: genId(),
    staffId: s.id,
    staffName: s.name,
    month: month,
    amount: s.salary,
    datePaid: new Date().toISOString().slice(0, 10),
    createdAt: new Date().toISOString()
  };

  // Add salary payment record
  const payments = DB.salaryPayments;
  payments.push(payment);
  DB.salaryPayments = payments;

  // Also create a matching expense entry
  const expense = {
    id: genId(),
    type: 'expense',
    date: payment.datePaid,
    desc: `Salary — ${s.name} (${s.role || 'Staff'})`,
    category: 'salaries',
    amount: s.salary
  };
  const expenses = DB.expenses;
  expenses.push(expense);
  DB.expenses = expenses;

  renderPayrollTab();
  toast(`${s.name}'s salary marked as paid`);
}

function undoSalaryPayment(staffId) {
  const month = getPayrollMonth();
  const payment = getSalaryPayment(staffId, month);
  if (!payment) return;

  customConfirm(`Undo salary payment for this month? This will also remove the expense entry.`, 'Undo Payment', 'Yes, Undo', true, () => {
    DB.salaryPayments = DB.salaryPayments.filter(p => p.id !== payment.id);
    // Remove matching expense
    DB.expenses = DB.expenses.filter(e => !(e.category === 'salaries' && e.desc.includes(payment.staffName) && e.date === payment.datePaid && e.amount === payment.amount));
    renderPayrollTab();
    toast('Payment undone');
  });
}

/* ── Recurring Expenses ── */
function openRecurringModal(id) {
  document.getElementById('recurringModalTitle').textContent = id ? 'Edit Recurring Expense' : 'Add Recurring Expense';
  if (id) {
    const r = DB.recurringExpenses.find(x => x.id === id);
    if (!r) return;
    document.getElementById('editRecurringId').value = r.id;
    document.getElementById('recurringDesc').value = r.desc || '';
    document.getElementById('recurringCategory').value = r.category || 'other';
    document.getElementById('recurringAmount').value = r.amount || '';
    document.getElementById('recurringDueDay').value = r.dueDay || '1';
  } else {
    document.getElementById('editRecurringId').value = '';
    document.getElementById('recurringDesc').value = '';
    document.getElementById('recurringCategory').value = 'rent';
    document.getElementById('recurringAmount').value = '';
    document.getElementById('recurringDueDay').value = '1';
  }
  openModal('recurringModal');
}

function saveRecurring() {
  const id = document.getElementById('editRecurringId').value;
  const desc = document.getElementById('recurringDesc').value.trim();
  const category = document.getElementById('recurringCategory').value;
  const amount = parseFloat(document.getElementById('recurringAmount').value) || 0;
  const dueDay = document.getElementById('recurringDueDay').value || '1';

  if (!desc) return toast('Description is required', 'error');
  if (!amount) return toast('Amount is required', 'error');

  const item = { id: id || genId(), desc, category, amount, dueDay, createdAt: new Date().toISOString() };
  const list = DB.recurringExpenses;
  const idx = list.findIndex(x => x.id === item.id);
  if (idx >= 0) { item.createdAt = list[idx].createdAt; list[idx] = item; }
  else list.push(item);
  DB.recurringExpenses = list;
  closeModal('recurringModal');
  renderRecurringTab();
  toast(idx >= 0 ? 'Updated' : 'Recurring expense added');
}

function deleteRecurring(id) {
  customConfirm('Delete this recurring expense?', 'Delete', 'Yes, Delete', true, () => {
    DB.recurringExpenses = DB.recurringExpenses.filter(x => x.id !== id);
    renderRecurringTab();
    toast('Deleted');
  });
}

function isRecurringPaid(recurringId, month) {
  const r = DB.recurringExpenses.find(x => x.id === recurringId);
  if (!r) return false;
  return DB.expenses.some(e => e.category === r.category && e.desc === r.desc && e.date && e.date.startsWith(month));
}

function payRecurring(recurringId) {
  const month = getPayrollMonth();
  const r = DB.recurringExpenses.find(x => x.id === recurringId);
  if (!r) return;

  if (isRecurringPaid(recurringId, month)) {
    toast('Already paid this month', 'warning');
    return;
  }

  const expense = {
    id: genId(),
    type: 'expense',
    date: new Date().toISOString().slice(0, 10),
    desc: r.desc,
    category: r.category,
    amount: r.amount
  };
  const list = DB.expenses;
  list.push(expense);
  DB.expenses = list;
  renderRecurringTab();
  toast(`${r.desc} marked as paid`);
}

/* ── Render Functions ── */
function renderPayrollTab() {
  const month = getPayrollMonth();
  const activeStaff = DB.staff.filter(s => s.status === 'active');
  const body = document.getElementById('payrollBody');
  if (!body) return;

  if (!activeStaff.length) {
    body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No staff members yet</h3><p>Add your first staff member to start tracking salaries.</p></td></tr>';
    updatePayrollSummary(month);
    return;
  }

  const now = new Date();
  const [yr, mo] = month.split('-').map(Number);
  const payMonthDate = new Date(yr, mo - 1, 1);

  body.innerHTML = activeStaff.map(s => {
    const paid = isSalaryPaid(s.id, month);
    const payment = getSalaryPayment(s.id, month);
    const dueDay = parseInt(s.payDay) || 5;
    const dueDate = new Date(yr, mo - 1, dueDay);
    const isOverdue = !paid && now > dueDate && now.getMonth() >= payMonthDate.getMonth() && now.getFullYear() >= payMonthDate.getFullYear();

    let statusBadge, actionBtn;
    if (paid) {
      statusBadge = `<span class="badge badge-success">✅ Paid</span><br><small style="color:var(--text-2)">${fmtDate(payment.datePaid)}</small>`;
      actionBtn = `<button class="btn btn-sm btn-secondary" onclick="undoSalaryPayment('${s.id}')">Undo</button>`;
    } else if (isOverdue) {
      statusBadge = `<span class="badge badge-danger">❌ Overdue</span>`;
      actionBtn = `<button class="btn btn-sm btn-primary" onclick="markSalaryPaid('${s.id}')">Pay Now</button>`;
    } else {
      statusBadge = `<span class="badge badge-warning">⏳ Due</span>`;
      actionBtn = `<button class="btn btn-sm btn-primary" onclick="markSalaryPaid('${s.id}')">Pay</button>`;
    }

    return `<tr>
      <td><strong>${escapeHtml(s.name)}</strong></td>
      <td>${escapeHtml(s.role || '—')}</td>
      <td>KES ${fmtMoney(s.salary)}</td>
      <td>${statusBadge}</td>
      <td>${actionBtn}</td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="openStaffModal('${s.id}')">Edit</button>
        <button class="btn btn-sm btn-danger" onclick="deleteStaff('${s.id}')">Del</button>
      </td>
    </tr>`;
  }).join('');

  updatePayrollSummary(month);
}

function updatePayrollSummary(month) {
  const activeStaff = DB.staff.filter(s => s.status === 'active');
  const totalPayroll = activeStaff.reduce((s, x) => s + x.salary, 0);
  const paidCount = activeStaff.filter(s => isSalaryPaid(s.id, month)).length;
  const paidAmount = activeStaff.filter(s => isSalaryPaid(s.id, month)).reduce((s, x) => s + x.salary, 0);

  const el = document.getElementById('payrollSummary');
  if (el) {
    el.innerHTML = `
      <div class="stat-card fade-up"><div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 00-3-3.87"/><path d="M16 3.13a4 4 0 010 7.75"/></svg></div><div class="stat-info"><h4>Total Staff</h4><div class="stat-value">${activeStaff.length}</div></div></div>
      <div class="stat-card fade-up"><div class="stat-icon orange"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6"/></svg></div><div class="stat-info"><h4>Monthly Payroll</h4><div class="stat-value">KES ${fmtMoney(totalPayroll)}</div></div></div>
      <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 11-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg></div><div class="stat-info"><h4>Paid This Month</h4><div class="stat-value">${paidCount} / ${activeStaff.length}</div><div class="stat-change ${paidCount === activeStaff.length ? 'up' : 'down'}">KES ${fmtMoney(paidAmount)} of ${fmtMoney(totalPayroll)}</div></div></div>
      <div class="stat-card fade-up"><div class="stat-icon ${totalPayroll - paidAmount > 0 ? 'red' : 'green'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg></div><div class="stat-info"><h4>Outstanding</h4><div class="stat-value">KES ${fmtMoney(totalPayroll - paidAmount)}</div></div></div>`;
  }
}

function renderRecurringTab() {
  const month = getPayrollMonth();
  const items = DB.recurringExpenses;
  const body = document.getElementById('recurringBody');
  if (!body) return;

  if (!items.length) {
    body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No recurring expenses</h3><p>Add monthly costs like rent, utilities, or subscriptions.</p></td></tr>';
    return;
  }

  const now = new Date();
  const [yr, mo] = month.split('-').map(Number);

  body.innerHTML = items.map(r => {
    const paid = isRecurringPaid(r.id, month);
    const dueDay = parseInt(r.dueDay) || 1;
    const dueDate = new Date(yr, mo - 1, dueDay);
    const isOverdue = !paid && now > dueDate;

    let statusBadge, actionBtn;
    if (paid) {
      statusBadge = `<span class="badge badge-success">✅ Paid</span>`;
      actionBtn = '';
    } else if (isOverdue) {
      statusBadge = `<span class="badge badge-danger">❌ Overdue</span>`;
      actionBtn = `<button class="btn btn-sm btn-primary" onclick="payRecurring('${r.id}')">Pay Now</button>`;
    } else {
      statusBadge = `<span class="badge badge-warning">⏳ Due ${dueDay}th</span>`;
      actionBtn = `<button class="btn btn-sm btn-primary" onclick="payRecurring('${r.id}')">Pay</button>`;
    }

    return `<tr>
      <td><strong>${escapeHtml(r.desc)}</strong></td>
      <td style="text-transform:capitalize">${escapeHtml(r.category)}</td>
      <td>KES ${fmtMoney(r.amount)}</td>
      <td>Due ${dueDay}th</td>
      <td>${statusBadge} ${actionBtn}</td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="openRecurringModal('${r.id}')">Edit</button>
        <button class="btn btn-sm btn-danger" onclick="deleteRecurring('${r.id}')">Del</button>
      </td>
    </tr>`;
  }).join('');
}

function renderPersonalTab() {
  const month = getPayrollMonth();
  const personal = DB.expenses.filter(e => e.category === 'personal' || e.category === 'airtime' || e.category === 'food_personal' || e.category === 'medical' || e.category === 'family' || e.category === 'clothing' || e.category === 'entertainment' || e.category === 'savings' || e.category === 'personal_transport' || e.category === 'other_personal');
  const monthlyPersonal = personal.filter(e => e.date && e.date.startsWith(month)).reverse();
  const body = document.getElementById('personalBody');
  if (!body) return;

  const totalPersonal = monthlyPersonal.reduce((s, e) => s + e.amount, 0);

  if (!monthlyPersonal.length) {
    body.innerHTML = '<tr><td colspan="5" class="empty-state"><h3>No personal expenses this month</h3><p>Track your personal spending — airtime, food, medical, family, etc.</p></td></tr>';
  } else {
    body.innerHTML = monthlyPersonal.map(e => {
      const catLabel = getPersonalCategoryLabel(e.category);
      return `<tr>
        <td>${fmtDate(e.date)}</td>
        <td>${escapeHtml(e.desc)}</td>
        <td><span class="badge badge-info">${catLabel}</span></td>
        <td>KES ${fmtMoney(e.amount)}</td>
        <td><button class="btn btn-sm btn-danger" onclick="deleteExpense('${e.id}')">Del</button></td>
      </tr>`;
    }).join('');
  }

  const sumEl = document.getElementById('personalTotal');
  if (sumEl) sumEl.textContent = 'KES ' + fmtMoney(totalPersonal);
}

function getPersonalCategoryLabel(cat) {
  const labels = {
    'personal': 'Personal', 'airtime': '📱 Airtime', 'food_personal': '🍽️ Food & Meals',
    'medical': '🏥 Medical', 'family': '👨‍👩‍👧 Family', 'clothing': '👔 Clothing',
    'entertainment': '🎬 Entertainment', 'savings': '🏦 Savings',
    'personal_transport': '🚗 Transport', 'other_personal': '📦 Other'
  };
  return labels[cat] || cat;
}

function openPersonalExpenseModal() {
  document.getElementById('expType').value = 'expense';
  document.getElementById('expCategory').value = 'personal';
  document.getElementById('expDate').value = new Date().toISOString().slice(0, 10);
  openModal('personalExpenseModal');
}

function savePersonalExpense() {
  const desc = document.getElementById('personalExpDesc').value.trim();
  const category = document.getElementById('personalExpCategory').value;
  const amount = parseFloat(document.getElementById('personalExpAmount').value) || 0;
  const date = document.getElementById('personalExpDate').value || new Date().toISOString().slice(0, 10);

  if (!desc) return toast('Description is required', 'error');
  if (!amount) return toast('Amount is required', 'error');

  const expense = { id: genId(), type: 'expense', date, desc, category, amount };
  const list = DB.expenses;
  list.push(expense);
  DB.expenses = list;
  closeModal('personalExpenseModal');
  renderPersonalTab();
  toast('Personal expense saved');
}

/* ── Expense Tab Switching (Enhanced) ── */
let currentExpenseTab = 'expenses';
function switchExpenseTab(tab, btn) {
  currentExpenseTab = tab;
  document.querySelectorAll('#page-expenses .tab-btn').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');

  // Hide all tab content
  document.querySelectorAll('.expense-tab-content').forEach(el => el.style.display = 'none');

  // Show selected
  const target = document.getElementById('expTab-' + tab);
  if (target) target.style.display = 'block';

  if (tab === 'expenses' || tab === 'capital') {
    expenseTab = tab;
    renderExpenses();
  }
  if (tab === 'salaries') renderPayrollTab();
  if (tab === 'recurring') renderRecurringTab();
  if (tab === 'personal') renderPersonalTab();
  if (tab === 'borrowings') renderBorrowingsTab();
}

/* ── Boss's Account (Borrowings) ── */
function openBorrowingModal(id) {
  document.getElementById('borrowingModalTitle').textContent = id ? 'Edit Loan' : "Record New Loan";
  if (id) {
    const b = DB.borrowings.find(x => x.id === id);
    if (!b) return;
    document.getElementById('editBorrowingId').value = b.id;
    document.getElementById('borrowingDate').value = b.date || new Date().toISOString().slice(0, 10);
    document.getElementById('borrowingDesc').value = b.desc || '';
    document.getElementById('borrowingAmount').value = b.amount || '';
  } else {
    document.getElementById('editBorrowingId').value = '';
    document.getElementById('borrowingDate').value = new Date().toISOString().slice(0, 10);
    document.getElementById('borrowingDesc').value = '';
    document.getElementById('borrowingAmount').value = '';
  }
  openModal('borrowingModal');
}

function saveBorrowing() {
  const id = document.getElementById('editBorrowingId').value;
  const date = document.getElementById('borrowingDate').value || new Date().toISOString().slice(0, 10);
  const desc = document.getElementById('borrowingDesc').value.trim();
  const amount = parseFloat(document.getElementById('borrowingAmount').value) || 0;

  if (!amount) return toast('Amount is required', 'error');

  const list = DB.borrowings;
  const idx = list.findIndex(x => x.id === id);
  if (idx >= 0) {
    list[idx].date = date;
    list[idx].desc = desc;
    list[idx].amount = amount;
    updateLinkedExpense(list[idx].id, amount, date, desc, 'borrow');
  } else {
    const item = { id: genId(), date, desc, amount, repayments: [], createdAt: new Date().toISOString() };
    list.push(item);
    createLinkedExpense(item.id, amount, date, desc, 'borrow');
  }
  
  DB.borrowings = list;
  closeModal('borrowingModal');
  renderBorrowingsTab();
  toast(id ? 'Loan updated' : 'Loan saved');
}

function deleteBorrowing(id) {
  customConfirm('Delete this loan and all its partial repayments?', 'Delete Loan', 'Yes, Delete', true, () => {
    const loan = DB.borrowings.find(x => x.id === id);
    if(loan) {
      deleteLinkedExpense(loan.id, 'borrow');
      (loan.repayments || []).forEach(r => deleteLinkedExpense(r.id, 'repay'));
    }
    DB.borrowings = DB.borrowings.filter(x => x.id !== id);
    renderBorrowingsTab();
    toast('Loan deleted');
  });
}

function openRepayModal(loanId) {
  document.getElementById('repayBorrowingId').value = loanId;
  document.getElementById('repayDate').value = new Date().toISOString().slice(0, 10);
  document.getElementById('repayAmount').value = '';
  document.getElementById('repayDesc').value = '';
  openModal('repayModal');
}

function saveRepayment() {
  const loanId = document.getElementById('repayBorrowingId').value;
  const date = document.getElementById('repayDate').value || new Date().toISOString().slice(0, 10);
  const amount = parseFloat(document.getElementById('repayAmount').value) || 0;
  const desc = document.getElementById('repayDesc').value.trim();

  if (!amount) return toast('Amount is required', 'error');

  const list = DB.borrowings;
  const loan = list.find(x => x.id === loanId);
  if (!loan) return;
  if (!loan.repayments) loan.repayments = [];

  const repayId = genId();
  loan.repayments.push({ id: repayId, date, amount, desc });
  
  createLinkedExpense(repayId, amount, date, 'Repayment: ' + (loan.desc || 'Loan'), 'repay');

  DB.borrowings = list;
  closeModal('repayModal');
  renderBorrowingsTab();
  toast('Repayment saved');
}

function viewRepayments(loanId) {
  const loan = DB.borrowings.find(x => x.id === loanId);
  if (!loan || !loan.repayments || !loan.repayments.length) return toast('No repayments found', 'info');
  
  const body = document.getElementById('repaymentsHistoryBody');
  body.innerHTML = loan.repayments.map(r => `
    <tr>
      <td>${fmtDate(r.date)}</td>
      <td style="color:var(--green-700)">KES ${fmtMoney(r.amount)}</td>
      <td>${r.desc || '—'}</td>
      <td><button class="btn btn-sm btn-danger" onclick="deleteRepayment('${loanId}', '${r.id}')">Del</button></td>
    </tr>
  `).join('');
  openModal('repaymentsHistoryModal');
}

function deleteRepayment(loanId, repayId) {
  customConfirm('Delete this repayment?', 'Delete Repayment', 'Yes, Delete', true, () => {
    const list = DB.borrowings;
    const loan = list.find(x => x.id === loanId);
    if(loan && loan.repayments) {
      loan.repayments = loan.repayments.filter(r => r.id !== repayId);
      deleteLinkedExpense(repayId, 'repay');
      DB.borrowings = list;
      viewRepayments(loanId);
      renderBorrowingsTab();
      toast('Repayment deleted');
      if(!loan.repayments.length) closeModal('repaymentsHistoryModal');
    }
  });
}

function createLinkedExpense(refId, amount, date, desc, type) {
  const expList = DB.expenses;
  if (type === 'borrow') {
    expList.push({ id: genId(), refId, refType: 'boss_loan', type: 'expense', date, desc: `Boss Loan: ${desc}`, category: 'personal', amount });
  } else if (type === 'repay') {
    expList.push({ id: genId(), refId, refType: 'boss_repay', type: 'capital', date, desc: `Boss Repayment`, category: 'capital', amount });
  }
  DB.expenses = expList;
}

function updateLinkedExpense(refId, amount, date, desc, type) {
  const expList = DB.expenses;
  const exp = expList.find(e => e.refId === refId && e.refType === (type === 'borrow' ? 'boss_loan' : 'boss_repay'));
  if (exp) {
    exp.amount = amount;
    exp.date = date;
    if(type === 'borrow') exp.desc = `Boss Loan: ${desc}`;
    DB.expenses = expList;
  }
}

function deleteLinkedExpense(refId, type) {
  DB.expenses = DB.expenses.filter(e => !(e.refId === refId && e.refType === (type === 'borrow' ? 'boss_loan' : 'boss_repay')));
}

function renderBorrowingsTab() {
  const loans = DB.borrowings.filter(b => b.type !== 'repay').map(b => {
    if (!b.repayments) b.repayments = [];
    return b;
  }).slice().reverse();
  
  const body = document.getElementById('borrowingsBody');
  if (!body) return;

  let totalBorrowed = 0;
  let totalRepaid = 0;

  loans.forEach(loan => {
    totalBorrowed += loan.amount || 0;
    const repaid = loan.repayments.reduce((s, r) => s + (r.amount || 0), 0);
    totalRepaid += repaid;
  });

  const balance = totalBorrowed - totalRepaid;

  const stats = document.getElementById('borrowingStats');
  if (stats) {
    stats.innerHTML = `
      <div class="stat-card fade-up"><div class="stat-icon red"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg></div><div class="stat-info"><h4>Total Loans</h4><div class="stat-value">KES ${fmtMoney(totalBorrowed)}</div></div></div>
      <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg></div><div class="stat-info"><h4>Total Repaid</h4><div class="stat-value">KES ${fmtMoney(totalRepaid)}</div></div></div>
      <div class="stat-card fade-up"><div class="stat-icon ${balance > 0 ? 'orange' : 'blue'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg></div><div class="stat-info"><h4>Outstanding Balance</h4><div class="stat-value">KES ${fmtMoney(balance)}</div></div></div>
    `;
  }

  if (!loans.length) {
    body.innerHTML = '<tr><td colspan="7" class="empty-state"><h3>No loans yet</h3><p>Record a new loan above.</p></td></tr>';
    return;
  }

  body.innerHTML = loans.map(b => {
    const repaid = b.repayments.reduce((s, r) => s + (r.amount || 0), 0);
    const bal = b.amount - repaid;
    
    let statusBadge = '';
    if (bal <= 0) statusBadge = '<span class="badge badge-success">Paid</span>';
    else if (repaid > 0) statusBadge = '<span class="badge badge-warning">Partial</span>';
    else statusBadge = '<span class="badge badge-danger">Unpaid</span>';
    
    return `<tr>
      <td>${fmtDate(b.date)}</td>
      <td>${escapeHtml(b.desc)}</td>
      <td style="font-weight:600; color: var(--danger)">KES ${fmtMoney(b.amount)}</td>
      <td style="color: var(--green-700)">KES ${fmtMoney(repaid)}</td>
      <td style="font-weight:600;">KES ${fmtMoney(bal)}</td>
      <td>${statusBadge}</td>
      <td>
        <button class="btn btn-sm btn-primary" onclick="openRepayModal('${b.id}')" ${bal <= 0 ? 'disabled' : ''}>Repay</button>
        <button class="btn btn-sm btn-secondary" onclick="viewRepayments('${b.id}')" ${repaid === 0 ? 'disabled' : ''}>History</button>
        <button class="btn btn-sm btn-secondary" onclick="openBorrowingModal('${b.id}')">Edit</button>
        <button class="btn btn-sm btn-danger" onclick="deleteBorrowing('${b.id}')">Del</button>
      </td>
    </tr>`;
  }).join('');
}

