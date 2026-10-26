/* ══ Invoice Line Items ══ */
function addLineItem() {
  const row = document.createElement('tr');
  row.innerHTML = `<td><input type="text" placeholder="e.g. Onions" class="item-desc"></td><td><input type="number" min="0" step="any" value="1" class="item-qty"></td><td><select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;"><option value="kgs" selected>Kgs</option><option value="litres">Litres</option><option value="pieces">Pieces</option><option value="crates">Crates</option><option value="bags">Bags</option><option value="trays">Trays</option><option value="bundles">Bundles</option><option value="dozen">Dozen</option><option value="packets">Packets</option><option value="bunch">Bunch</option></select></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy"></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell"></td><td class="item-total" style="font-weight:600">0.00</td><td><button type="button" class="btn-remove-row" onclick="removeLineItem(this)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></td>`;
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
  const deliveryCost = parseFloat(document.getElementById('invDeliveryCost')?.value) || 0;
  const otherCost = parseFloat(document.getElementById('invOtherCost')?.value) || 0;
  
  if (document.getElementById('invSubtotal')) document.getElementById('invSubtotal').textContent = fmtMoney(sell);
  if (document.getElementById('invCost')) document.getElementById('invCost').textContent = fmtMoney(buy) + (deliveryCost || otherCost ? ` (+ ${fmtMoney(deliveryCost+otherCost)} ops)` : '');
  if (document.getElementById('invProfit')) document.getElementById('invProfit').textContent = fmtMoney(sell - buy - deliveryCost - otherCost);
}
function attachLineListeners(row) {
  row.querySelectorAll('input').forEach(inp => inp.addEventListener('input', calcInvoiceTotals));
}
document.querySelectorAll('#lineItemsBody tr').forEach(attachLineListeners);

/* ══ Secure Invoice Number Generation ══ */
function generateSecureInvoiceNumber(dateStr) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const used = new Set((typeof DB !== 'undefined' ? [...DB.invoices, ...(DB.deletedInvoices || [])] : [])
    .filter(inv => inv && inv.status !== 'draft').map(inv => String(inv.number || '').toUpperCase()));
  for (let attempt = 0; attempt < 1000; attempt++) {
    let suffix = '';
    for (let i = 0; i < 4; i++) suffix += chars.charAt(Math.floor(Math.random() * chars.length));
    const number = `TTG-${suffix}`;
    if (!used.has(number)) return number;
  }
  throw new Error('Could not generate a unique invoice number. Please try saving again.');
}

/* ══ Save Invoice ══ */
function saveInvoice(bypassDuplicateCheck = false) {
  const restId = document.getElementById('invRestaurant').value;
  if (!restId) return toast('Select a restaurant', 'error');
  const items = [];
  let valid = true;
  document.querySelectorAll('#lineItemsBody tr').forEach(row => {
    const desc = row.querySelector('.item-desc').value.trim();
    const qty = parseFloat(row.querySelector('.item-qty').value) || 0;
    const unit = row.querySelector('.item-unit')?.value || 'kgs';
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
  let invId = document.getElementById('editInvoiceId').value;
  const existingEditRecord = invId ? DB.invoices.find(i => i.id === invId) : null;

  // ══ Town Treasure Smart Audit — Ledger Collision Guard ══
  if ((!invId || existingEditRecord?.status === 'draft') && !bypassDuplicateCheck && typeof TTGAudit !== 'undefined' && typeof DB !== 'undefined' && Array.isArray(DB.invoices)) {
    try {
      const cand = {
        restaurant_name: rest ? rest.name : '',
        invoice_date: invDateVal,
        total_sell: totalSell,
        items_json: items
      };

      let matched = null;
      let highestScore = 0;
      for (const ex of DB.invoices.filter(invoice => invoice && invoice.status !== 'draft' && invoice.id !== invId)) {
        if (restId && ex.restaurantId && ex.restaurantId !== restId) continue;
        const s = TTGAudit.calculateHeuristicScore(cand, ex);
        if (s.score > highestScore) {
          highestScore = s.score;
          matched = ex;
        }
      }

      if (matched && highestScore >= 0.70) {
        const mAmt = Number(matched.totalSell || 0).toLocaleString();
        const mNum = matched.number || 'Invoice';
        const mItemsCount = (matched.items || matched.items_json || []).length;
        const clientName = rest ? rest.name : 'Selected Client';

        // High-Visibility Hazard Collision Modal
        const dupModal = document.getElementById('invoiceDuplicateModal');
        if (dupModal) {
          const headingEl = document.getElementById('invDupModalHeading');
          if (headingEl) {
            headingEl.textContent = 
              `Duplicate Alert: An invoice (#${mNum}) for ${clientName} on ${invDateVal} already exists in Veronica's encrypted vault.`;
          }
          const detailsEl = document.getElementById('invDupModalDetails');
          if (detailsEl) {
            detailsEl.textContent = 
              `Town Treasure Smart Audit matched this entry with ${Math.round(highestScore * 100)}% confidence against vault records. Saving this docket without review may cause double-billing.`;
          }
          const exNumEl = document.getElementById('invDupExistingNum');
          if (exNumEl) exNumEl.textContent = `#${mNum} (${clientName})`;
          const exDateEl = document.getElementById('invDupExistingDate');
          if (exDateEl) exDateEl.textContent = `Date: ${matched.date || invDateVal} • ${mItemsCount} items`;
          const exTotalEl = document.getElementById('invDupExistingTotal');
          if (exTotalEl) exTotalEl.textContent = `KES ${mAmt}`;
          const newClientEl = document.getElementById('invDupNewClient');
          if (newClientEl) newClientEl.textContent = `${clientName}`;
          const newDateEl = document.getElementById('invDupNewDate');
          if (newDateEl) newDateEl.textContent = `Date: ${invDateVal} • ${items.length} items`;
          const newTotalEl = document.getElementById('invDupNewTotal');
          if (newTotalEl) newTotalEl.textContent = `KES ${Number(totalSell || 0).toLocaleString()}`;
          
          const overlapEl = document.getElementById('invDupOverlapText');
          if (overlapEl) {
            try {
              const norm = (str) => {
                if (typeof TTGAudit !== 'undefined' && typeof TTGAudit.canonicalProduce === 'function') {
                  return TTGAudit.canonicalProduce(str);
                }
                return (str || '').toLowerCase().trim();
              };
              const matchingItems = items.filter(it => 
                (matched.items || []).some(m => norm(m.desc || m.name) === norm(it.desc || it.name))
              ).length;
              overlapEl.textContent = matchingItems > 0 
                ? `⚠️ Produce Overlap: ${matchingItems} of ${items.length} produce lines match the existing vault docket.`
                : `⚠️ Identical Client & Date Collision. Potential double-submission detected.`;
            } catch (cmpErr) {
              overlapEl.textContent = '⚠️ Ledger Collision: Client and date match an existing invoice in the vault.';
            }
          }

          const overrideBtn = document.getElementById('btnConfirmOverrideInvoiceDuplicate');
          if (overrideBtn) {
            overrideBtn.onclick = function() {
              closeModal('invoiceDuplicateModal');
              saveInvoice(true);
            };
          }
          openModal('invoiceDuplicateModal');
          return;
        }

        // High-Alert Fallback
        if (typeof customConfirm === 'function') {
          customConfirm(
            `⚠️ INTEGRITY HAZARD: Town Treasure Smart Audit detected an existing invoice (#${mNum}) for ${clientName} on ${invDateVal} for KES ${mAmt}.\n\nSaving this will inject a potential duplicate into Veronica's encrypted vault.\n\nDo you want to proceed and save as an additional separate delivery?`,
            '⚠️ Integrity Hazard: Duplicate Invoice Collision',
            'Save as 2nd Delivery Anyway',
            true,
            function() {
              saveInvoice(true);
            }
          );
          return;
        }
      }
    } catch (auditErr) {
      console.warn('[Smart Audit] Invoice duplicate detection note:', auditErr);
    }
  }

  let invNumber, createdAt = new Date().toISOString();
  const originalInvoice = existingEditRecord;
  if (invId) {
    const existing = originalInvoice;
    if (existing) {
      createdAt = existing.createdAt || createdAt;
      invNumber = existing.status === 'draft' || /-D$/i.test(existing.number || '')
        ? generateSecureInvoiceNumber(invDateVal)
        : existing.number;
    }
  }
  if (!invId) { invId = genId(); invNumber = generateSecureInvoiceNumber(invDateVal); }

    const deliveryCost = parseFloat(document.getElementById('invDeliveryCost').value) || 0;
    const otherCost = parseFloat(document.getElementById('invOtherCost').value) || 0;
    
    const inv = {
      id: invId, number: invNumber || generateSecureInvoiceNumber(invDateVal), restaurantId: restId,
      restaurantName: rest ? rest.name : 'Unknown',
      date: invDateVal,
      dueDate: document.getElementById('invDueDate').value || '',
      items, totalSell, totalBuy, deliveryCost, otherCost, profit: totalSell - totalBuy - deliveryCost - otherCost,
      notes: document.getElementById('invNotes').value.trim(),
      status: originalInvoice && originalInvoice.status !== 'draft' ? originalInvoice.status : 'pending',
      paidDate: originalInvoice?.paidDate,
      createdAt, updatedAt: new Date().toISOString()
    };
  const list = DB.invoices; 
  const idx = list.findIndex(i => i.id === invId);
  if (idx >= 0) list[idx] = inv; else list.push(inv);
  DB.invoices = list;
  
  // Create or update associated expenses
  const replacedExpenses = DB.expenses.filter(e => e.invId === invId);
  replacedExpenses.forEach(expense => DB.markRecordDeleted?.('expenses', expense.id));
  let expList = DB.expenses.filter(e => e.invId !== invId); // Replace auto-generated linked costs
  if (deliveryCost > 0) {
    expList.push({ id: genId(), invId, type: 'expense', date: invDateVal, desc: `Delivery: ${inv.number} (${inv.restaurantName})`, category: 'transport', amount: deliveryCost });
  }
  if (otherCost > 0) {
    expList.push({ id: genId(), invId, type: 'expense', date: invDateVal, desc: `Ops Cost: ${inv.number} (${inv.restaurantName})`, category: 'other', amount: otherCost });
  }
  DB.expenses = expList;
  if (typeof DB.syncNow === 'function') DB.syncNow();
  toast('Invoice ' + inv.number + ' created!');
  document.getElementById('editInvoiceId').value = '';
  if(typeof checkInvoiceDraft === 'function') checkInvoiceDraft();
  resetInvoiceForm();
  viewInvoice(inv.id);
}
function resetInvoiceForm() {
  document.getElementById('editInvoiceId').value = '';
  document.getElementById('invRestaurant').value = '';
  document.getElementById('invDate').value = new Date().toISOString().slice(0,10);
  document.getElementById('invDueDate').value = '';
  document.getElementById('invNotes').value = '';
  document.getElementById('invDeliveryCost').value = '';
  document.getElementById('invOtherCost').value = '';
  const body = document.getElementById('lineItemsBody');
  body.innerHTML = '';
  addLineItem();
  calcInvoiceTotals();
}

function saveInvoiceDraft(silent = false) {
  const restId = document.getElementById('invRestaurant').value;
  const items = [];
  document.querySelectorAll('#lineItemsBody tr').forEach(row => {
    const desc = row.querySelector('.item-desc').value.trim();
    const qty = parseFloat(row.querySelector('.item-qty').value) || 0;
    const unit = row.querySelector('.item-unit')?.value || 'kgs';
    const buy = parseFloat(row.querySelector('.item-buy').value) || 0;
    const sell = parseFloat(row.querySelector('.item-sell').value) || 0;
    if (desc || qty > 0 || buy > 0 || sell > 0) {
      items.push({ desc, qty, unit, buyPrice: buy, sellPrice: sell, total: qty * sell });
    }
  });

  const totalSell = items.reduce((s, i) => s + i.total, 0);
  const totalBuy = items.reduce((s, i) => s + i.qty * i.buyPrice, 0);
  const rest = DB.restaurants.find(r => r.id === restId);
  const invDateVal = document.getElementById('invDate').value || new Date().toISOString().slice(0,10);
  
  let invId = document.getElementById('editInvoiceId').value;
  const currentRecord = invId ? DB.invoices.find(i => i.id === invId) : null;
  if (currentRecord && currentRecord.status !== 'draft') {
    if (!silent) toast('This is an existing invoice. Use Save Invoice to update it.', 'warning');
    return;
  }
  let invNumber, createdAt = new Date().toISOString();
  if (invId) {
    const existing = DB.invoices.find(i => i.id === invId);
    if (existing) { invNumber = existing.number; createdAt = existing.createdAt; }
  }
  if (!invId) { invId = genId(); invNumber = generateSecureInvoiceNumber(invDateVal) + '-D'; }

  const deliveryCost = parseFloat(document.getElementById('invDeliveryCost')?.value) || 0;
  const otherCost = parseFloat(document.getElementById('invOtherCost')?.value) || 0;

  const draft = {
    id: invId,
    number: invNumber,
    restaurantId: restId || '',
    restaurantName: rest ? rest.name : 'Unknown',
    date: invDateVal,
    dueDate: document.getElementById('invDueDate').value || '',
    items, totalSell, totalBuy, deliveryCost, otherCost, profit: totalSell - totalBuy - deliveryCost - otherCost,
    notes: document.getElementById('invNotes').value.trim(),
    status: 'draft',
    createdAt,
    updatedAt: new Date().toISOString()
  };

  const list = DB.invoices;
  const idx = list.findIndex(i => i.id === invId);
  if (idx >= 0) list[idx] = draft; else list.push(draft);
  DB.invoices = list;

  document.getElementById('editInvoiceId').value = draft.id;
  if (!silent) toast('Draft saved to database!');
  checkInvoiceDraft();
}

function loadInvoiceDraft(id) {
  let draft;
  if (typeof id === 'string' && id) {
    draft = DB.invoices.find(i => i.id === id);
  } else {
    draft = DB.invoices.find(i => i.status === 'draft');
  }
  if (!draft) { toast('No draft found.', 'error'); return; }
  
  if (typeof navigateTo === 'function') navigateTo('new-invoice');
  
  document.getElementById('editInvoiceId').value = draft.id;
  if (draft.restaurantId) document.getElementById('invRestaurant').value = draft.restaurantId;
  if (draft.date) document.getElementById('invDate').value = normalizeAppDate(draft.date);
  if (draft.dueDate) document.getElementById('invDueDate').value = draft.dueDate;
  if (draft.notes) document.getElementById('invNotes').value = draft.notes;
  if (draft.deliveryCost) document.getElementById('invDeliveryCost').value = draft.deliveryCost;
  else document.getElementById('invDeliveryCost').value = '';
  if (draft.otherCost) document.getElementById('invOtherCost').value = draft.otherCost;
  else document.getElementById('invOtherCost').value = '';
  
  const body = document.getElementById('lineItemsBody');
  body.innerHTML = '';
  if (draft.items && draft.items.length > 0) {
    draft.items.forEach(item => {
      const row = document.createElement('tr');
      row.innerHTML = `<td><input type="text" placeholder="e.g. Tomatoes" class="item-desc" value="${item.desc || ''}"></td><td><input type="number" min="0" step="any" class="item-qty" value="${item.qty || 1}"></td><td><select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;"><option value="kgs" ${item.unit === 'kgs' || !item.unit ? 'selected' : ''}>Kgs</option><option value="litres" ${item.unit === 'litres' ? 'selected' : ''}>Litres</option><option value="pieces" ${item.unit === 'pieces' ? 'selected' : ''}>Pieces</option><option value="crates" ${item.unit === 'crates' ? 'selected' : ''}>Crates</option><option value="bags" ${item.unit === 'bags' ? 'selected' : ''}>Bags</option><option value="trays" ${item.unit === 'trays' ? 'selected' : ''}>Trays</option><option value="bundles" ${item.unit === 'bundles' ? 'selected' : ''}>Bundles</option><option value="dozen" ${item.unit === 'dozen' ? 'selected' : ''}>Dozen</option><option value="packets" ${item.unit === 'packets' ? 'selected' : ''}>Packets</option><option value="banch" ${item.unit === 'banch' ? 'selected' : ''}>Banch</option></select></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy" value="${item.buyPrice !== undefined ? item.buyPrice : (item.buy || '')}"></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell" value="${item.sellPrice !== undefined ? item.sellPrice : (item.sell || '')}"></td><td class="item-total" style="font-weight:600">0.00</td><td><button type="button" class="btn-remove-row" onclick="removeLineItem(this)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></td>`;
      body.appendChild(row);
      attachLineListeners(row);
    });
    calcInvoiceTotals();
  } else {
    addLineItem();
  }
  toast('Draft loaded!');
}

function checkInvoiceDraft() {
  const drafts = DB.invoices.filter(i => i.status === 'draft').reverse();
  const section = document.getElementById('draftsSection');
  const body = document.getElementById('draftsListBody');
  if (!section || !body) return;
  
  if (drafts.length > 0) {
    section.style.display = 'block';
    body.innerHTML = drafts.map(d => {
      const dateStr = fmtDate(d.createdAt || d.date);
      const itemsCount = d.items ? d.items.length : 0;
      return `<tr>
        <td>${dateStr}</td>
        <td>${d.restaurantName || 'Unknown'}</td>
        <td>${itemsCount} item(s)</td>
        <td>
          <button class="btn btn-sm btn-primary" onclick="loadInvoiceDraft('${d.id}')">Resume</button>
          <button class="btn btn-sm btn-danger" onclick="deleteDraft('${d.id}')">Del</button>
        </td>
      </tr>`;
    }).join('');
  } else {
    section.style.display = 'none';
  }
}
let autoSaveTimer = null;
function triggerAutoSave() {
  clearTimeout(autoSaveTimer);
  autoSaveTimer = setTimeout(() => {
    const editingId = document.getElementById('editInvoiceId')?.value;
    const editingRecord = editingId ? DB.invoices.find(i => i.id === editingId) : null;
    // Editing a saved invoice is explicit-save only; never demote it to a draft.
    if (editingRecord && editingRecord.status !== 'draft') return;
    const restId = document.getElementById('invRestaurant')?.value;
    let hasItems = false;
    document.querySelectorAll('#lineItemsBody tr').forEach(row => {
      const desc = row.querySelector('.item-desc')?.value.trim();
      const buy = parseFloat(row.querySelector('.item-buy')?.value) || 0;
      const sell = parseFloat(row.querySelector('.item-sell')?.value) || 0;
      if (desc || buy > 0 || sell > 0) hasItems = true;
    });
    if (restId || hasItems) {
      saveInvoiceDraft(true);
    }
  }, 1000);
}

document.addEventListener('DOMContentLoaded', () => {
  checkInvoiceDraft();
  const form = document.getElementById('invoiceForm');
  if (form) {
    form.addEventListener('input', triggerAutoSave);
    form.addEventListener('change', triggerAutoSave);
  }
});

function deleteDraft(id) {
  customConfirm('Are you sure you want to delete this draft?', 'Delete Draft', 'Yes, Delete', true, () => {
    clearTimeout(autoSaveTimer);
    const draft = DB.invoices.find(i => i.id === id);
    if (draft) {
      const bin = DB.deletedInvoices.filter(i => i.id !== id);
      bin.push({ ...draft, deletedAt: new Date().toISOString(), originalStatus: 'draft' });
      DB.deletedInvoices = bin;
      DB.deletedInvoiceIds = Array.from(new Set([...(DB.deletedInvoiceIds || []), id]));
      DB.restoredInvoiceIds = (DB.restoredInvoiceIds || []).filter(restoredId => restoredId !== id);
      DB.markRecordDeleted?.('invoices', id);
    }
    DB.invoices = DB.invoices.filter(i => i.id !== id);
    if (document.getElementById('editInvoiceId').value === id) resetInvoiceForm();
    if (typeof DB.syncNow === 'function') DB.syncNow();
    checkInvoiceDraft(); toast('Draft deleted');
  });
}

/* ══ Invoices List ══ */
function renderInvoicesList() {
  populateRestaurantDropdowns();
  const search = (document.getElementById('invoiceSearch')?.value || '').toLowerCase();
  const filterRest = document.getElementById('invoiceFilterRestaurant')?.value || '';
  const filterStatus = document.getElementById('invoiceFilterStatus')?.value || '';
  const dateKey = appDateKey;
  let invs = DB.invoices.filter(i => i.status !== 'draft').slice()
    .sort((a, b) => dateKey(b.date).localeCompare(dateKey(a.date))
      || String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
  if (search) invs = invs.filter(i => i.number.toLowerCase().includes(search) || i.restaurantName.toLowerCase().includes(search));
  if (filterRest) invs = invs.filter(i => i.restaurantId === filterRest);
  if (filterStatus) invs = invs.filter(i => i.status === filterStatus);
  const body = document.getElementById('invoicesListBody');
  if (!invs.length) { body.innerHTML = '<tr><td colspan="8" class="empty-state"><h3>No invoices found</h3></td></tr>'; return; }
  body.innerHTML = invs.map(i => {
    const badgeCls = i.status === 'paid' ? 'badge-success' : i.status === 'overdue' ? 'badge-danger' : 'badge-warning';
    return `<tr><td><strong>${escapeHtml(i.number)}</strong></td><td>${escapeHtml(i.restaurantName)}</td><td>${fmtDate(i.date)}</td><td>${i.items.length}</td><td>KES ${fmtMoney(i.totalSell)}</td><td style="color:var(--green-700)">KES ${fmtMoney(i.profit)}</td><td><span class="badge ${badgeCls}">${i.status}</span></td><td><button class="btn btn-sm btn-secondary" onclick="viewInvoice('${i.id}')">View</button> <button class="btn btn-sm btn-primary" onclick="editInvoice('${i.id}')">Edit</button> <button class="btn btn-sm btn-danger" onclick="deleteInvoice('${i.id}')">Del</button></td></tr>`;
  }).join('');
}
function deleteInvoice(id) {
  customConfirm('This invoice will be moved to the Recycle Bin. You can restore it later.', 'Delete Invoice', 'Yes, Delete', true, () => {
    clearTimeout(autoSaveTimer);
    const inv = DB.invoices.find(i => i.id === id);
    if (inv) {
      // Move to recycle bin with deletion timestamp
      const deleted = { ...inv, deletedAt: new Date().toISOString(), originalStatus: inv.status };
      const bin = DB.deletedInvoices;
      bin.push(deleted);
      DB.deletedInvoices = bin;
      DB.deletedInvoiceIds = Array.from(new Set([...(DB.deletedInvoiceIds || []), id]));
      DB.restoredInvoiceIds = (DB.restoredInvoiceIds || []).filter(restoredId => restoredId !== id);
      DB.markRecordDeleted?.('invoices', id);
    }
    DB.invoices = DB.invoices.filter(i => i.id !== id);
    DB.expenses.filter(e => e.invId === id).forEach(expense => DB.markRecordDeleted?.('expenses', expense.id));
    DB.expenses = DB.expenses.filter(e => e.invId !== id);
    if (document.getElementById('editInvoiceId').value === id) resetInvoiceForm();
    if (typeof DB.syncNow === 'function') DB.syncNow();
    renderInvoicesList();
    toast('Invoice moved to Recycle Bin');
  });
}

/* ══ Recycle Bin ══ */
let binTab = 'invoices';
function switchBinTab(tab, btn) {
  binTab = tab;
  document.querySelectorAll('#page-recycle-bin .tab-btn').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');
  renderBin();
}

function renderBin() {
  const body = document.getElementById('binListBody');
  const header = document.getElementById('binTableHeader');
  const actionsBar = document.getElementById('binActionsBar');
  const selectAll = document.getElementById('binSelectAll');
  if (selectAll) selectAll.checked = false;
  if (actionsBar) actionsBar.style.display = 'none';

  let items = [];
  
  if (binTab === 'invoices') {
    items = DB.deletedInvoices.slice().reverse();
    header.innerHTML = `<tr><th style="width:40px;"><input type="checkbox" id="binSelectAll" onchange="toggleBinSelectAll(this)" title="Select all"></th><th>Invoice #</th><th>Restaurant</th><th>Date</th><th>Total</th><th>Deleted On</th><th>Action</th></tr>`;
    
    if (!items.length) {
      body.innerHTML = '<tr><td colspan="7" class="empty-state"><div class="bin-empty-icon"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="color:var(--text-3)"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg></div><h3>No deleted invoices</h3></td></tr>';
      return;
    }
    body.innerHTML = items.map(i => `<tr>
      <td><input type="checkbox" class="bin-checkbox" value="${i.id}" onchange="updateBinSelection()"></td>
      <td><strong>${i.number}</strong></td>
      <td>${i.restaurantName || 'Unknown'}</td>
      <td>${fmtDate(i.date)}</td>
      <td>KES ${fmtMoney(i.totalSell)}</td>
      <td><span style="color:var(--text-2);font-size:.85rem;">${i.deletedAt ? fmtDate(i.deletedAt.slice(0, 10)) : '—'}</span></td>
      <td><button class="btn btn-sm btn-primary" onclick="restoreInvoice('${i.id}')"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg> Restore</button></td>
    </tr>`).join('');
  } 
  else if (binTab === 'staff') {
    items = DB.deletedStaff.slice().reverse();
    header.innerHTML = `<tr><th style="width:40px;"><input type="checkbox" id="binSelectAll" onchange="toggleBinSelectAll(this)" title="Select all"></th><th>Name</th><th>Role</th><th>Salary</th><th>Deleted On</th><th>Action</th></tr>`;
    
    if (!items.length) {
      body.innerHTML = '<tr><td colspan="6" class="empty-state"><div class="bin-empty-icon"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="color:var(--text-3)"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg></div><h3>No deleted staff</h3></td></tr>';
      return;
    }
    body.innerHTML = items.map(s => `<tr>
      <td><input type="checkbox" class="bin-checkbox" value="${s.id}" onchange="updateBinSelection()"></td>
      <td><strong>${s.name}</strong></td>
      <td>${s.role || '—'}</td>
      <td>KES ${fmtMoney(s.salary)}</td>
      <td><span style="color:var(--text-2);font-size:.85rem;">${s.deletedAt ? fmtDate(s.deletedAt.slice(0, 10)) : '—'}</span></td>
      <td><button class="btn btn-sm btn-primary" onclick="restoreStaff('${s.id}')"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg> Restore</button></td>
    </tr>`).join('');
  }
  else if (binTab === 'pricelists') {
    items = DB.deletedPriceLists.slice().reverse();
    header.innerHTML = `<tr><th style="width:40px;"><input type="checkbox" id="binSelectAll" onchange="toggleBinSelectAll(this)" title="Select all"></th><th>Name</th><th>Items</th><th>Deleted On</th><th>Action</th></tr>`;
    
    if (!items.length) {
      body.innerHTML = '<tr><td colspan="5" class="empty-state"><div class="bin-empty-icon"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="color:var(--text-3)"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg></div><h3>No deleted price lists</h3></td></tr>';
      return;
    }
    body.innerHTML = items.map(p => `<tr>
      <td><input type="checkbox" class="bin-checkbox" value="${p.id}" onchange="updateBinSelection()"></td>
      <td><strong>${p.name}</strong></td>
      <td>${p.items ? p.items.length : 0} items</td>
      <td><span style="color:var(--text-2);font-size:.85rem;">${p.deletedAt ? fmtDate(p.deletedAt.slice(0, 10)) : '—'}</span></td>
      <td><button class="btn btn-sm btn-primary" onclick="restorePriceList('${p.id}')"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg> Restore</button></td>
    </tr>`).join('');
  }
}

function restoreInvoice(id) {
  const bin = DB.deletedInvoices;
  const inv = bin.find(i => i.id === id);
  if (!inv) return toast('Invoice not found in bin.', 'error');
  const restored = { ...inv };
  restored.status = inv.originalStatus || inv.status || 'pending';
  delete restored.deletedAt; delete restored.originalStatus;
  restored.updatedAt = new Date().toISOString();
  const list = DB.invoices; list.push(restored); DB.invoices = list;
  DB.deletedInvoices = bin.filter(i => i.id !== id);
  DB.deletedInvoiceIds = (DB.deletedInvoiceIds || []).filter(deletedId => deletedId !== id);
  DB.restoredInvoiceIds = Array.from(new Set([...(DB.restoredInvoiceIds || []), id]));
  DB.markRecordRestored?.('invoices', id);
  
  let expList = DB.expenses.filter(e => e.invId !== id);
  if (restored.deliveryCost > 0) expList.push({ id: genId(), invId: id, type: 'expense', date: restored.date, desc: `Delivery: ${restored.number} (${restored.restaurantName})`, category: 'transport', amount: restored.deliveryCost });
  if (restored.otherCost > 0) expList.push({ id: genId(), invId: id, type: 'expense', date: restored.date, desc: `Ops Cost: ${restored.number} (${restored.restaurantName})`, category: 'other', amount: restored.otherCost });
  DB.expenses = expList;
  if (typeof DB.syncNow === 'function') DB.syncNow();
  
  renderBin(); toast('Invoice restored!');
}

function restoreSelectedBinItems() {
  const checkboxes = document.querySelectorAll('.bin-checkbox:checked');
  if (!checkboxes.length) return toast('No items selected.', 'error');
  const ids = Array.from(checkboxes).map(cb => cb.value);
  
  customConfirm(`Restore ${ids.length} selected item(s)?`, 'Restore Items', 'Yes, Restore', false, () => {
    if (binTab === 'invoices') {
      const bin = DB.deletedInvoices; const list = DB.invoices; let expList = DB.expenses;
      ids.forEach(id => {
        const inv = bin.find(i => i.id === id);
        if (inv) { 
          const r = { ...inv }; r.status = inv.originalStatus || inv.status || 'pending'; delete r.deletedAt; delete r.originalStatus; r.updatedAt = new Date().toISOString(); list.push(r);
          expList = expList.filter(e => e.invId !== id);
          if (r.deliveryCost > 0) expList.push({ id: genId(), invId: id, type: 'expense', date: r.date, desc: `Delivery: ${r.number} (${r.restaurantName})`, category: 'transport', amount: r.deliveryCost });
          if (r.otherCost > 0) expList.push({ id: genId(), invId: id, type: 'expense', date: r.date, desc: `Ops Cost: ${r.number} (${r.restaurantName})`, category: 'other', amount: r.otherCost });
        }
      });
      DB.invoices = list; DB.deletedInvoices = bin.filter(i => !ids.includes(i.id)); DB.expenses = expList;
      const restoredIds = ids.filter(id => bin.some(item => item.id === id));
      DB.deletedInvoiceIds = (DB.deletedInvoiceIds || []).filter(deletedId => !restoredIds.includes(deletedId));
      DB.restoredInvoiceIds = Array.from(new Set([...(DB.restoredInvoiceIds || []), ...restoredIds]));
      restoredIds.forEach(id => DB.markRecordRestored?.('invoices', id));
    } 
    else if (binTab === 'staff') {
      const bin = DB.deletedStaff; const list = DB.staff;
      ids.forEach(id => {
        const s = bin.find(i => i.id === id);
        if (s) { const r = { ...s }; delete r.deletedAt; list.push(r); }
      });
      DB.staff = list; DB.deletedStaff = bin.filter(i => !ids.includes(i.id));
      ids.forEach(id => { if (bin.some(item => item.id === id)) DB.markRecordRestored?.('staff', id); });
    }
    else if (binTab === 'pricelists') {
      const bin = DB.deletedPriceLists; const list = DB.priceLists;
      ids.forEach(id => {
        const p = bin.find(i => i.id === id);
        if (p) { const r = { ...p }; delete r.deletedAt; list.push(r); }
      });
      DB.priceLists = list; DB.deletedPriceLists = bin.filter(i => !ids.includes(i.id));
      ids.forEach(id => { if (bin.some(item => item.id === id)) DB.markRecordRestored?.('priceLists', id); });
    }
    if (typeof DB.syncNow === 'function') DB.syncNow();
    renderBin();
    toast(ids.length + ' item(s) restored!');
  });
}

function toggleBinSelectAll(master) {
  document.querySelectorAll('.bin-checkbox').forEach(cb => { cb.checked = master.checked; });
  updateBinSelection();
}

function updateBinSelection() {
  const checked = document.querySelectorAll('.bin-checkbox:checked').length;
  const bar = document.getElementById('binActionsBar');
  const countEl = document.getElementById('binSelectedCount');
  if (checked > 0) {
    bar.style.display = 'flex';
    countEl.textContent = checked + ' selected';
  } else {
    bar.style.display = 'none';
  }
}
function markAsPaid(id) {
  const list = DB.invoices;
  const inv = list.find(i => i.id === id);
  if (inv) {
    inv.status = 'paid';
    inv.paidDate = new Date().toISOString().slice(0, 10);
    inv.updatedAt = new Date().toISOString();
    DB.invoices = list;
    toast('Marked as paid');
    viewInvoice(id);
  }
}

function editInvoice(id) {
  const inv = DB.invoices.find(i => i.id === id);
  if (!inv) { toast('Invoice not found.', 'error'); return; }
  
  if (typeof navigateTo === 'function') navigateTo('new-invoice');
  
  document.getElementById('editInvoiceId').value = inv.id;
  if (inv.restaurantId) document.getElementById('invRestaurant').value = inv.restaurantId;
  if (inv.date) document.getElementById('invDate').value = normalizeAppDate(inv.date);
  if (inv.dueDate) document.getElementById('invDueDate').value = inv.dueDate;
  if (inv.notes) document.getElementById('invNotes').value = inv.notes;
  if (inv.deliveryCost) document.getElementById('invDeliveryCost').value = inv.deliveryCost;
  else document.getElementById('invDeliveryCost').value = '';
  if (inv.otherCost) document.getElementById('invOtherCost').value = inv.otherCost;
  else document.getElementById('invOtherCost').value = '';
  
  const body = document.getElementById('lineItemsBody');
  body.innerHTML = '';
  if (inv.items && inv.items.length > 0) {
    inv.items.forEach(item => {
      const row = document.createElement('tr');
      row.innerHTML = `<td><input type="text" placeholder="e.g. Tomatoes" class="item-desc" value="${item.desc || ''}"></td><td><input type="number" min="0" step="any" class="item-qty" value="${item.qty || 1}"></td><td><select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;"><option value="kgs" ${item.unit === 'kgs' || !item.unit ? 'selected' : ''}>Kgs</option><option value="litres" ${item.unit === 'litres' ? 'selected' : ''}>Litres</option><option value="pieces" ${item.unit === 'pieces' ? 'selected' : ''}>Pieces</option><option value="crates" ${item.unit === 'crates' ? 'selected' : ''}>Crates</option><option value="bags" ${item.unit === 'bags' ? 'selected' : ''}>Bags</option><option value="trays" ${item.unit === 'trays' ? 'selected' : ''}>Trays</option><option value="bundles" ${item.unit === 'bundles' ? 'selected' : ''}>Bundles</option><option value="dozen" ${item.unit === 'dozen' ? 'selected' : ''}>Dozen</option><option value="packets" ${item.unit === 'packets' ? 'selected' : ''}>Packets</option><option value="banch" ${item.unit === 'banch' ? 'selected' : ''}>Banch</option></select></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy" value="${item.buyPrice !== undefined ? item.buyPrice : (item.buy || '')}"></td><td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell" value="${item.sellPrice !== undefined ? item.sellPrice : (item.sell || '')}"></td><td class="item-total" style="font-weight:600">0.00</td><td><button type="button" class="btn-remove-row" onclick="removeLineItem(this)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></td>`;
      body.appendChild(row);
      attachLineListeners(row);
    });
    calcInvoiceTotals();
  } else {
    addLineItem();
  }
  toast('Editing Invoice ' + inv.number);
}
