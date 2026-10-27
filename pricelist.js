/* ══ Price List Module (Independent) ══ */

let currentPriceListId = null;
let priceListAutoSaveTimer = null;

/* ── Price List CRUD ── */
function renderPriceLists() {
  const body = document.getElementById('priceListsBody');
  if (!body) return;
  const lists = DB.priceLists.slice().reverse();

  if (!lists.length) {
    body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No price lists yet</h3><p>Create your first price list to share with restaurants.</p></td></tr>';
    return;
  }

  body.innerHTML = lists.map(l => {
    const statusBadge = `<span class="badge ${l.status === 'active' ? 'badge-success' : l.status === 'draft' ? 'badge-warning' : 'badge-info'}">${l.status}</span>`;
    return `<tr>
      <td><strong>${escapeHtml(l.name)}</strong></td>
      <td>${fmtDate(l.updatedAt)}</td>
      <td>${l.items.filter(i => !i.isHeader).length} items</td>
      <td>${statusBadge}</td>
      <td><span class="badge badge-info" style="font-size:0.75rem;">${l.shareId ? 'Linked' : 'Private'}</span></td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="viewPriceList('${l.id}')">View</button>
        <button class="btn btn-sm btn-primary" onclick="editPriceList('${l.id}')">Edit</button>
        <button class="btn btn-sm btn-secondary" onclick="duplicatePriceList('${l.id}')">Dup</button>
        <button class="btn btn-sm btn-danger" onclick="deletePriceList('${l.id}')">Del</button>
      </td>
    </tr>`;
  }).join('');
}

function createNewPriceList() {
  const defaultTodayName = 'Price List — ' + new Date().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
  const existingEmptyDraft = (DB.priceLists || []).find(pl => 
    pl && pl.status === 'draft' && 
    pl.name === defaultTodayName && 
    (!pl.items || pl.items.length <= 1) && 
    (!pl.items[0]?.name || !pl.items[0].name.trim())
  );
  if (existingEmptyDraft) {
    editPriceList(existingEmptyDraft.id);
    toast('Resumed today’s active draft price list', 'info');
    return;
  }

  const pl = {
    id: genId(),
    name: defaultTodayName,
    subtitle: 'Food Supplies (Veg and Fruits)',
    status: 'draft',
    items: [
      { id: genId(), name: '', category: 'vegetables', unit: 'kgs', price: 0, notes: '' }
    ],
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  const list = DB.priceLists;
  list.push(pl);
  DB.priceLists = list;
  editPriceList(pl.id);
}

function editPriceList(id) {
  const pl = DB.priceLists.find(x => x.id === id);
  if (!pl) return toast('Price list not found', 'error');
  currentPriceListId = id;

  document.getElementById('plEditName').value = pl.name;
  document.getElementById('plEditSubtitle').value = pl.subtitle || 'Food Supplies (Veg and Fruits)';
  document.getElementById('plEditStatus').value = pl.status;
  renderPriceListItems(pl);
  navigateTo('pricelist-edit');
}

function renderPriceListItems(pl) {
  const body = document.getElementById('plItemsBody');
  if (!body) return;

  if (!pl.items || !pl.items.length) {
    body.innerHTML = '';
    addPriceListRow();
    return;
  }

  body.innerHTML = pl.items.map((item, idx) => item.isHeader ? buildCategoryHeaderRow(item) : buildPriceListRow(item, idx)).join('');
  attachPriceListListeners();
  auditPriceListDuplicates();
}

function buildCategoryHeaderRow(item) {
  return `<tr data-item-id="${item.id}" data-type="header" style="background: linear-gradient(135deg, #61b146, #4a9e36); cursor: move;">
    <td colspan="5" style="padding: 10px 16px; border: none;">
      <input type="text" class="pl-header-name" value="${escapeHtml(item.name || '')}" placeholder="e.g. Fruits, Meat, Vegetables…" 
        style="background:transparent; border:none; color:white; font-weight:700; font-size:1rem; letter-spacing:0.5px; text-transform:uppercase; width:100%; outline:none;">
    </td>
    <td style="border: none; text-align: right; padding-right: 16px; white-space: nowrap;">
      <button type="button" onclick="insertPriceListHeaderBelow(this)" style="color:rgba(255,255,255,0.9); background:rgba(0,0,0,0.15); border:none; cursor:pointer; padding:4px 6px; border-radius:4px; margin-right:4px; font-weight:bold; font-size:12px; vertical-align:middle;" title="Add Header Below">H+</button>
      <button type="button" onclick="insertPriceListRowBelow(this)" style="color:rgba(255,255,255,0.9); background:rgba(0,0,0,0.15); border:none; cursor:pointer; padding:4px; border-radius:4px; margin-right:4px; vertical-align:middle;" title="Add Item Below">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:block;"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
      </button>
      <button type="button" class="btn-remove-row" onclick="removePriceListRow(this)" style="color:rgba(255,255,255,0.9); background:rgba(220,38,38,0.8); border:none; cursor:pointer; padding:4px; border-radius:4px; vertical-align:middle;" title="Remove Header">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:block;"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
    </td>
  </tr>`;
}

function buildPriceListRow(item, idx) {
  const categories = ['vegetables', 'fruits', 'cereals', 'dairy', 'meat', 'fish', 'legumes', 'spices', 'packaged', 'other'];
  const catOptions = categories.map(c => `<option value="${c}" ${item.category === c ? 'selected' : ''}>${c.charAt(0).toUpperCase() + c.slice(1)}</option>`).join('');
  const units = ['kgs', 'litres', 'pieces', 'crates', 'bags', 'trays', 'bundles', 'dozen', 'packets', 'bunch'];
  const unitOptions = units.map(u => `<option value="${u}" ${item.unit === u ? 'selected' : ''}>${u.charAt(0).toUpperCase() + u.slice(1)}</option>`).join('');

  return `<tr data-item-id="${item.id}">
    <td><input type="text" class="pl-item-name" value="${escapeHtml(item.name || '')}" placeholder="e.g. Tomatoes"></td>
    <td><select class="pl-item-cat form-control" style="padding:6px 4px;font-size:0.8rem;">${catOptions}</select></td>
    <td><select class="pl-item-unit form-control" style="padding:6px 4px;font-size:0.8rem;">${unitOptions}</select></td>
    <td><input type="number" class="pl-item-price" min="0" step="any" value="${item.price || ''}" placeholder="0.00"></td>
    <td><input type="text" class="pl-item-notes" value="${escapeHtml(item.notes || '')}" placeholder="Grade A, etc."></td>
    <td style="white-space:nowrap; text-align:right;">
      <button type="button" style="color:var(--primary); background:var(--primary-lt); border:none; cursor:pointer; padding:5px 7px; border-radius:4px; margin-right:4px; font-weight:bold; font-size:12px; vertical-align:middle;" onclick="insertPriceListHeaderBelow(this)" title="Add Header Below">H+</button>
      <button type="button" style="color:var(--primary); background:var(--primary-lt); border:none; cursor:pointer; padding:6px; border-radius:4px; margin-right:4px; vertical-align:middle;" onclick="insertPriceListRowBelow(this)" title="Add Item Below">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:block;"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
      </button>
      <button type="button" class="btn-remove-row" onclick="removePriceListRow(this)" style="padding:6px; border-radius:4px; vertical-align:middle;" title="Remove Row">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:block;"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
    </td>
  </tr>`;
}

function addPriceListRow() {
  const body = document.getElementById('plItemsBody');
  if (!body) return;
  const item = { id: genId(), name: '', category: 'vegetables', unit: 'kgs', price: 0, notes: '' };
  const idx = body.rows.length;
  const row = document.createElement('tr');
  row.setAttribute('data-item-id', item.id);
  row.innerHTML = buildPriceListRow(item, idx).replace(/^<tr[^>]*>/, '').replace(/<\/tr>$/, '');
  body.appendChild(row);
  attachPriceListListeners();
  triggerPriceListAutoSave();
}

function addCategoryHeader() {
  const body = document.getElementById('plItemsBody');
  if (!body) return;
  const item = { id: genId(), name: '', isHeader: true };
  const temp = document.createElement('tbody');
  temp.innerHTML = buildCategoryHeaderRow(item);
  const row = temp.firstElementChild;
  body.appendChild(row);
  attachPriceListListeners();
  row.querySelector('.pl-header-name')?.focus();
  triggerPriceListAutoSave();
}

function removePriceListRow(btn) {
  const body = document.getElementById('plItemsBody');
  if (body.rows.length <= 1) return toast('Must have at least one item', 'warning');
  btn.closest('tr').remove();
  auditPriceListDuplicates();
  triggerPriceListAutoSave();
}

function insertPriceListRowBelow(btn) {
  const currentRow = btn.closest('tr');
  let category = 'vegetables';
  let unit = 'kgs';
  
  if (currentRow.getAttribute('data-type') !== 'header') {
    category = currentRow.querySelector('.pl-item-cat')?.value || 'vegetables';
    unit = currentRow.querySelector('.pl-item-unit')?.value || 'kgs';
  } else {
    // If inserting below a header, try to guess the category from the header name
    const headerName = currentRow.querySelector('.pl-header-name')?.value || '';
    category = guessPriceListCategory(headerName);
  }

  const item = { id: genId(), name: '', category, unit, price: 0, notes: '' };
  const temp = document.createElement('tbody');
  temp.innerHTML = buildPriceListRow(item, 0);
  const newRow = temp.firstElementChild;
  
  currentRow.insertAdjacentElement('afterend', newRow);
  attachPriceListListeners();
  
  // Focus the newly inserted row's name input
  const nameInput = newRow.querySelector('.pl-item-name');
  if (nameInput) nameInput.focus();
  
  triggerPriceListAutoSave();
}

function insertPriceListHeaderBelow(btn) {
  const currentRow = btn.closest('tr');
  const item = { id: genId(), name: '', isHeader: true };
  const temp = document.createElement('tbody');
  temp.innerHTML = buildCategoryHeaderRow(item);
  const newRow = temp.firstElementChild;
  
  currentRow.insertAdjacentElement('afterend', newRow);
  attachPriceListListeners();
  
  const nameInput = newRow.querySelector('.pl-header-name');
  if (nameInput) nameInput.focus();
  
  triggerPriceListAutoSave();
}

function insertPriceListRowTop() {
  const body = document.getElementById('plItemsBody');
  if (!body) return;
  const item = { id: genId(), name: '', category: 'vegetables', unit: 'kgs', price: 0, notes: '' };
  
  const firstRow = body.firstElementChild;
  if (firstRow && firstRow.getAttribute('data-type') !== 'header') {
    item.category = firstRow.querySelector('.pl-item-cat')?.value || 'vegetables';
    item.unit = firstRow.querySelector('.pl-item-unit')?.value || 'kgs';
  } else if (firstRow && firstRow.getAttribute('data-type') === 'header') {
    const headerName = firstRow.querySelector('.pl-header-name')?.value || '';
    item.category = guessPriceListCategory(headerName);
  }

  const temp = document.createElement('tbody');
  temp.innerHTML = buildPriceListRow(item, 0);
  const newRow = temp.firstElementChild;
  
  body.prepend(newRow);
  attachPriceListListeners();
  
  const nameInput = newRow.querySelector('.pl-item-name');
  if (nameInput) nameInput.focus();
  
  triggerPriceListAutoSave();
}

function insertPriceListHeaderTop() {
  const body = document.getElementById('plItemsBody');
  if (!body) return;
  const item = { id: genId(), name: '', isHeader: true };
  const temp = document.createElement('tbody');
  temp.innerHTML = buildCategoryHeaderRow(item);
  const newRow = temp.firstElementChild;
  
  body.prepend(newRow);
  attachPriceListListeners();
  
  const nameInput = newRow.querySelector('.pl-header-name');
  if (nameInput) nameInput.focus();
  
  triggerPriceListAutoSave();
}

function attachPriceListListeners() {
  document.querySelectorAll('#plItemsBody input, #plItemsBody select').forEach(inp => {
    inp.removeEventListener('input', onPriceListFieldInput);
    inp.addEventListener('input', onPriceListFieldInput);
  });
}

function onPriceListFieldInput() {
  auditPriceListDuplicates();
  triggerPriceListAutoSave();
}

/**
 * Town Treasure Catalog Audit: Real-Time Produce Commodity Duplicate Detection
 * Detects identical commodities or normalized produce names across rows.
 */
function auditPriceListDuplicates() {
  const rows = document.querySelectorAll('#plItemsBody tr:not([data-type="header"])');
  const counts = new Map();

  rows.forEach(row => {
    const input = row.querySelector('.pl-item-name');
    const rawName = (input?.value || '').trim();
    if (!rawName) return;

    const normKey = (typeof TTGAudit !== 'undefined' && TTGAudit.normalizeItemName)
      ? TTGAudit.normalizeItemName(rawName)
      : rawName.toLowerCase().replace(/[^a-z0-9]/g, '');

    if (!normKey) return;

    const list = counts.get(normKey) || [];
    list.push({ row, input, rawName });
    counts.set(normKey, list);
  });

  const duplicates = [];
  counts.forEach((occurrences, normKey) => {
    if (occurrences.length > 1) {
      duplicates.push({
        name: occurrences[0].rawName,
        normKey,
        count: occurrences.length,
        occurrences
      });
    }
  });

  // Clear previous badges & highlights
  document.querySelectorAll('#plItemsBody .pl-dup-badge').forEach(b => b.remove());
  rows.forEach(r => {
    const inp = r.querySelector('.pl-item-name');
    if (inp) {
      inp.style.borderColor = '';
      inp.style.background = '';
    }
    r.style.background = '';
  });

  const banner = document.getElementById('plDuplicateAlertBanner');

  if (duplicates.length > 0) {
    duplicates.forEach(dup => {
      dup.occurrences.forEach(occ => {
        if (occ.input) {
          occ.input.style.borderColor = '#ef4444';
          occ.input.style.background = '#fef2f2';
          occ.row.style.background = '#fff5f5';

          const badge = document.createElement('span');
          badge.className = 'pl-dup-badge';
          badge.style.cssText = 'color:#991b1b; font-size:0.72rem; font-weight:700; background:#fee2e2; border:1px solid #fca5a5; padding:2px 6px; border-radius:4px; margin-left:6px; display:inline-flex; align-items:center; gap:3px; vertical-align:middle; white-space:nowrap;';
          badge.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/></svg> Duplicate (${dup.count}x)`;
          occ.input.insertAdjacentElement('afterend', badge);
        }
      });
    });

    if (banner) {
      const namesList = duplicates.map(d => `"${d.name}" (${d.count}x)`).join(', ');
      const titleEl = document.getElementById('plDupBannerTitle');
      const textEl = document.getElementById('plDupBannerText');
      if (titleEl) titleEl.textContent = `🚨 Duplicate Produce Commodities Detected (${duplicates.length})`;
      if (textEl) textEl.textContent = `The following items appear multiple times in this price list: ${namesList}. Please consolidate prices or distinguish specific varieties.`;
      banner.style.display = 'block';
    }
  } else {
    if (banner) banner.style.display = 'none';
  }

  return duplicates;
}

function triggerPriceListAutoSave() {
  clearTimeout(priceListAutoSaveTimer);
  priceListAutoSaveTimer = setTimeout(() => savePriceListDraft(), 1000);
}

/* ── Save / Publish ── */
function collectPriceListData() {
  const items = [];
  document.querySelectorAll('#plItemsBody tr').forEach(row => {
    const isHeader = row.getAttribute('data-type') === 'header';
    if (isHeader) {
      items.push({
        id: row.getAttribute('data-item-id') || genId(),
        name: row.querySelector('.pl-header-name')?.value.trim() || '',
        isHeader: true
      });
    } else {
      items.push({
        id: row.getAttribute('data-item-id') || genId(),
        name: row.querySelector('.pl-item-name')?.value.trim() || '',
        category: row.querySelector('.pl-item-cat')?.value || 'other',
        unit: row.querySelector('.pl-item-unit')?.value || 'kgs',
        price: parseFloat(row.querySelector('.pl-item-price')?.value) || 0,
        notes: row.querySelector('.pl-item-notes')?.value.trim() || ''
      });
    }
  });
  return items;
}

function savePriceListDraft() {
  if (!currentPriceListId) return;
  const list = DB.priceLists;
  const idx = list.findIndex(x => x.id === currentPriceListId);
  if (idx < 0) return;

  list[idx].name = document.getElementById('plEditName')?.value.trim() || list[idx].name;
  list[idx].subtitle = document.getElementById('plEditSubtitle')?.value.trim() || list[idx].subtitle || '';
  list[idx].items = collectPriceListData();
  list[idx].updatedAt = new Date().toISOString();
  DB.priceLists = list;
}

/**
 * Town Treasure Catalog Collision Audit:
 * Compares title and produce commodity lines against existing catalog records in DB.priceLists.
 * Detects identical/duplicate price lists to prevent redundant catalog creation.
 */
function checkPriceListCollisions(name, items, excludeId = null) {
  try {
    if (!DB || !Array.isArray(DB.priceLists)) return null;

    const normProduce = (str) => {
      if (typeof TTGAudit !== 'undefined') {
        if (typeof TTGAudit.canonicalProduce === 'function') return TTGAudit.canonicalProduce(str);
        if (typeof TTGAudit.normalizeItemName === 'function') return TTGAudit.normalizeItemName(str);
      }
      return (str || '').toLowerCase().trim().replace(/[^a-z0-9]/g, '');
    };

    const normTitle = (str) => {
      return (str || '').toLowerCase().trim().replace(/\s+/g, ' ').replace(/[^a-z0-9]/g, '');
    };

    const targetTitle = normTitle(name);
    const validItems = (items || []).filter(i => !i.isHeader && (i.name || '').trim());
    const targetProduceKeys = new Set(validItems.map(i => normProduce(i.name)).filter(Boolean));

    const candidates = DB.priceLists.filter(pl => pl && pl.id !== excludeId && !pl.deletedAt);
    if (!candidates.length) return null;

    const collisions = [];

    for (const pl of candidates) {
      const candTitle = normTitle(pl.name);
      const isExactTitle = targetTitle && candTitle && targetTitle === candTitle;

      const candItems = (pl.items || []).filter(i => !i.isHeader && (i.name || '').trim());
      const candProduceKeys = new Set(candItems.map(i => normProduce(i.name)).filter(Boolean));

      const matchingKeys = [];
      targetProduceKeys.forEach(k => {
        if (candProduceKeys.has(k)) matchingKeys.push(k);
      });

      const minCount = Math.min(targetProduceKeys.size, candProduceKeys.size);
      const maxCount = Math.max(targetProduceKeys.size, candProduceKeys.size);

      const overlapRatio = minCount > 0 ? (matchingKeys.length / minCount) : 0;
      const totalRatio = maxCount > 0 ? (matchingKeys.length / maxCount) : 0;

      let confidence = 0;

      if (isExactTitle && (totalRatio >= 0.70 || (targetProduceKeys.size === 0 && candProduceKeys.size === 0))) {
        confidence = 0.99;
      } else if (targetProduceKeys.size >= 3 && totalRatio >= 0.85) {
        confidence = 0.96;
      } else if (isExactTitle) {
        confidence = 0.90;
      } else if (targetProduceKeys.size >= 3 && overlapRatio >= 0.75) {
        confidence = 0.85;
      } else if (targetProduceKeys.size >= 1 && minCount <= 2 && overlapRatio === 1.0) {
        confidence = 0.82;
      } else if (targetProduceKeys.size >= 4 && overlapRatio >= 0.65) {
        confidence = 0.75;
      }

      if (confidence >= 0.75) {
        collisions.push({
          matched: pl,
          confidence,
          isExactTitle,
          matchingKeys,
          overlapRatio,
          totalRatio,
          existingItemCount: candItems.length
        });
      }
    }

    if (!collisions.length) return null;

    collisions.sort((a, b) => (b.confidence - a.confidence) || (b.overlapRatio - a.overlapRatio));
    return collisions[0];
  } catch (err) {
    console.warn('[Smart Audit] Price list collision check error:', err);
    return null;
  }
}

/**
 * Renders the High-Alert Crimson Collision Modal for Price Lists
 */
function showPriceListDuplicateModal(opts) {
  const modal = document.getElementById('priceListDuplicateModal');
  if (!modal) {
    if (typeof customConfirm === 'function') {
      customConfirm(
        `${opts.heading}\n\n${opts.details}\n\nDo you want to proceed anyway?`,
        opts.title || '⚠️ Duplicate Price List Detected',
        'Proceed Anyway',
        true,
        opts.onProceed
      );
    }
    return;
  }

  const titleEl = document.getElementById('plDupModalMainTitle');
  if (titleEl) titleEl.textContent = opts.title || 'INTEGRITY HAZARD: DUPLICATE PRICE LIST';

  const headingEl = document.getElementById('plDupModalHeading');
  if (headingEl) headingEl.textContent = opts.heading || 'A matching price list already exists in the catalog ledger.';

  const detailsEl = document.getElementById('plDupModalDetails');
  if (detailsEl) detailsEl.textContent = opts.details || 'Saving without review will create redundant duplicate catalogs and cause pricing confusion.';

  const exNameEl = document.getElementById('plDupExistingName');
  if (exNameEl) exNameEl.textContent = opts.existingName || '—';

  const exDateEl = document.getElementById('plDupExistingDate');
  if (exDateEl) exDateEl.textContent = opts.existingDate || '—';

  const exCountEl = document.getElementById('plDupExistingCount');
  if (exCountEl) exCountEl.textContent = opts.existingCount || '—';

  const newNameEl = document.getElementById('plDupNewName');
  if (newNameEl) newNameEl.textContent = opts.newName || '—';

  const newDateEl = document.getElementById('plDupNewDate');
  if (newDateEl) newDateEl.textContent = opts.newDate || '—';

  const newCountEl = document.getElementById('plDupNewCount');
  if (newCountEl) newCountEl.textContent = opts.newCount || '—';

  const overlapEl = document.getElementById('plDupOverlapText');
  if (overlapEl) {
    overlapEl.textContent = opts.overlapText || '';
    overlapEl.style.display = opts.overlapText ? 'block' : 'none';
  }

  const adviceEl = document.getElementById('plDupAdviceText');
  if (adviceEl && opts.adviceText) adviceEl.textContent = opts.adviceText;

  const btnConfirm = document.getElementById('btnConfirmOverridePriceListDuplicate');
  if (btnConfirm) {
    btnConfirm.onclick = function() {
      closeModal('priceListDuplicateModal');
      if (typeof opts.onProceed === 'function') {
        opts.onProceed();
      }
    };
  }

  openModal('priceListDuplicateModal');
}

function publishPriceList(bypassDuplicateCheck = false) {
  if (!currentPriceListId) return;
  const list = DB.priceLists;
  const idx = list.findIndex(x => x.id === currentPriceListId);
  if (idx < 0) return;

  const items = collectPriceListData().filter(i => i.name && i.name.trim());
  if (!items.length) return toast('Add at least one item with a name', 'error');

  const plName = document.getElementById('plEditName')?.value.trim() || list[idx].name;

  if (!bypassDuplicateCheck) {
    // 1. Cross-price-list collision check against all other existing price lists
    const collision = checkPriceListCollisions(plName, items, currentPriceListId);
    if (collision) {
      const matchPct = Math.round(collision.confidence * 100);
      const overlapText = collision.matchingKeys && collision.matchingKeys.length > 0
        ? `⚠️ Produce Overlap: ${collision.matchingKeys.length} matching commodities (${Math.round(collision.overlapRatio * 100)}% match with "${collision.matched.name}").`
        : `⚠️ Identical Title Collision: Another price list already exists with the name "${collision.matched.name}".`;

      showPriceListDuplicateModal({
        title: 'INTEGRITY HAZARD: DUPLICATE PRICE LIST DETECTED',
        heading: `A matching price list ("${collision.matched.name}") already exists in Veronica's catalog ledger.`,
        details: `Town Treasure Smart Audit detected ${matchPct}% similarity against an existing saved price list. Saving without review will create redundant duplicate catalogs and cause pricing confusion.`,
        existingName: collision.matched.name,
        existingDate: `Date: ${fmtDate(collision.matched.updatedAt || collision.matched.createdAt)}`,
        existingCount: `${collision.existingItemCount} produce lines`,
        newName: plName,
        newDate: `Date: ${fmtDate(new Date())}`,
        newCount: `${items.filter(i => !i.isHeader).length} produce lines`,
        overlapText: overlapText,
        adviceText: 'If this price list is already saved in your catalog, please cancel and view the existing record. If this is an intentional updated version or seasonal revision, you can override and save.',
        onProceed: function() {
          publishPriceList(true);
        }
      });
      return;
    }

    // 2. Internal duplicate commodity check within the active price list
    const internalDuplicates = auditPriceListDuplicates();
    if (internalDuplicates.length > 0) {
      const dupNames = internalDuplicates.map(d => `${d.name} (${d.count}x)`).join(', ');
      showPriceListDuplicateModal({
        title: 'CATALOG HAZARD: DUPLICATE PRODUCE COMMODITIES',
        heading: `Duplicate produce commodities detected in this price list table (${internalDuplicates.length}).`,
        details: `The following produce items appear multiple times: ${dupNames}. Duplicate produce lines will cause confusion when sending price lists to restaurants or calculating invoices.`,
        existingName: 'Table Duplicates',
        existingDate: `${internalDuplicates.length} repeated lines`,
        existingCount: internalDuplicates.map(d => `• ${d.name} (${d.count}x)`).slice(0, 3).join(', '),
        newName: plName,
        newDate: 'Active Draft',
        newCount: `${items.filter(i => !i.isHeader).length} total items`,
        overlapText: `⚠️ Repeated Commodities: ${dupNames}`,
        adviceText: 'Please review the highlighted red rows in your table to consolidate prices or distinguish specific varieties (e.g., Spinach Local vs Spinach Hybrid).',
        onProceed: function() {
          publishPriceList(true);
        }
      });
      return;
    }
  }

  list[idx].name = plName;
  list[idx].subtitle = document.getElementById('plEditSubtitle')?.value.trim() || list[idx].subtitle || '';
  list[idx].status = document.getElementById('plEditStatus')?.value || 'active';
  list[idx].items = items;
  list[idx].updatedAt = new Date().toISOString();
  DB.priceLists = list;
  toast('Price list saved!', 'success');
  viewPriceList(currentPriceListId);
}

function viewPriceList(id) {
  const pl = DB.priceLists.find(x => x.id === id);
  if (!pl) return;
  currentPriceListId = id;
  const previewEl = buildPriceListPreview(pl);
  const container = document.getElementById('pricelistPreviewHtml');
  if (container) {
    container.innerHTML = '';
    container.appendChild(previewEl);
  }
  navigateTo('pricelist-view');
}

/* ── Smart Import from Past Invoices ── */
function smartImportItems() {
  const invoices = DB.invoices.filter(i => i.status !== 'draft');
  if (!invoices.length) return toast('No invoices found to import from', 'warning');

  // Extract unique items with latest prices
  const itemMap = {};
  invoices.sort((a, b) => appDateKey(a.date).localeCompare(appDateKey(b.date))).forEach(inv => {
    inv.items.forEach(item => {
      const key = item.desc.toLowerCase().trim();
      if (key) {
        itemMap[key] = {
          name: item.desc.trim(),
          unit: item.unit || 'kgs',
          price: item.sellPrice,
          category: guessPriceListCategory(item.desc)
        };
      }
    });
  });

  const importedItems = Object.values(itemMap).sort((a, b) => a.name.localeCompare(b.name));
  if (!importedItems.length) return toast('No items found in invoices', 'warning');

  // De-duplicate against items already in the active price list
  const existingNames = new Set(
    collectPriceListData()
      .filter(i => !i.isHeader && i.name)
      .map(i => (typeof TTGAudit !== 'undefined' ? TTGAudit.normalizeItemName(i.name) : i.name.toLowerCase().trim()))
  );

  const newItems = importedItems.filter(item => {
    const norm = (typeof TTGAudit !== 'undefined' ? TTGAudit.normalizeItemName(item.name) : item.name.toLowerCase().trim());
    return !existingNames.has(norm);
  });

  if (!newItems.length) return toast('All produce items from past invoices are already in this price list', 'info');

  // Add non-duplicate imported items to current list
  const body = document.getElementById('plItemsBody');
  newItems.forEach(item => {
    const row = document.createElement('tr');
    const id = genId();
    row.setAttribute('data-item-id', id);
    row.innerHTML = buildPriceListRow({ ...item, id, notes: '' }, body.rows.length).replace(/^<tr[^>]*>/, '').replace(/<\/tr>$/, '');
    body.appendChild(row);
  });
  attachPriceListListeners();
  auditPriceListDuplicates();
  triggerPriceListAutoSave();
  const skippedCount = importedItems.length - newItems.length;
  toast(`Imported ${newItems.length} items${skippedCount > 0 ? ` (${skippedCount} duplicates skipped)` : ''}`);
}

function guessPriceListCategory(name) {
  const n = name.toLowerCase();
  const vegKeywords = ['tomato', 'onion', 'potato', 'cabbage', 'spinach', 'carrot', 'pepper', 'lettuce', 'cucumber', 'broccoli', 'kale', 'sukuma', 'dhania', 'pilipili', 'courgette', 'managu', 'terere'];
  const fruitKeywords = ['banana', 'orange', 'apple', 'mango', 'avocado', 'watermelon', 'pineapple', 'passion', 'lemon', 'lime', 'pawpaw', 'papaya', 'grape'];
  const cerealKeywords = ['rice', 'maize', 'wheat', 'flour', 'ugali', 'bread', 'chapati', 'spaghetti', 'pasta'];
  const dairyKeywords = ['milk', 'cheese', 'yoghurt', 'butter', 'cream', 'ghee'];
  const meatKeywords = ['chicken', 'beef', 'goat', 'pork', 'mutton', 'sausage', 'bacon'];
  const fishKeywords = ['fish', 'tilapia', 'nile', 'sardine', 'tuna', 'omena'];
  const spiceKeywords = ['salt', 'sugar', 'pepper', 'ginger', 'garlic', 'turmeric', 'cumin', 'royco', 'curry'];

  if (vegKeywords.some(k => n.includes(k))) return 'vegetables';
  if (fruitKeywords.some(k => n.includes(k))) return 'fruits';
  if (cerealKeywords.some(k => n.includes(k))) return 'cereals';
  if (dairyKeywords.some(k => n.includes(k))) return 'dairy';
  if (meatKeywords.some(k => n.includes(k))) return 'meat';
  if (fishKeywords.some(k => n.includes(k))) return 'fish';
  if (spiceKeywords.some(k => n.includes(k))) return 'spices';
  return 'other';
}

/* ── Duplicate / Delete ── */
function duplicatePriceList(id) {
  const original = DB.priceLists.find(x => x.id === id);
  if (!original) return;
  const copy = {
    ...JSON.parse(JSON.stringify(original)),
    id: genId(),
    name: original.name + ' (Copy)',
    status: 'draft',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  const list = DB.priceLists;
  list.push(copy);
  DB.priceLists = list;
  renderPriceLists();
  toast('Price list duplicated');
}

function deletePriceList(id) {
  customConfirm('This price list will be moved to the Recycle Bin.', 'Delete Price List', 'Yes, Delete', true, () => runWithActionProgress('Deleting price list…', 'Moving this price list to the Recycle Bin and syncing the change.', async () => {
    const pl = DB.priceLists.find(x => x.id === id);
    if (pl) {
      const deleted = { ...pl, deletedAt: new Date().toISOString() };
      const bin = DB.deletedPriceLists;
      bin.push(deleted);
      DB.deletedPriceLists = bin;
    }
    DB.priceLists = DB.priceLists.filter(x => x.id !== id);
    DB.markRecordDeleted?.('priceLists', id);
    renderPriceLists();
    const synced = typeof DB.syncNow === 'function' ? await DB.syncNow() : false;
    return synced
      ? { status: 'success', title: 'Price list deleted', message: 'The price list was moved to the Recycle Bin and synced.' }
      : { status: 'warning', title: 'Price list deleted on this phone', message: 'The price list is in this device’s Recycle Bin, but cloud sync was not confirmed. Retry sync before switching devices.' };
  }));
}

function restorePriceList(id) {
  const bin = DB.deletedPriceLists;
  const pl = bin.find(x => x.id === id);
  if (!pl) return;
  const restored = { ...pl };
  delete restored.deletedAt;
  const list = DB.priceLists;
  list.push(restored);
  DB.priceLists = list;
  DB.deletedPriceLists = bin.filter(x => x.id !== id);
  DB.markRecordRestored?.('priceLists', id);
  if (typeof DB.syncNow === 'function') DB.syncNow();
  renderBin();
  toast('Price list restored');
}

/* ── Download / Share Price List ── */
async function downloadPriceListPDF() {
  console.log('[PriceList PDF] Starting download, currentPriceListId:', currentPriceListId);
  if (!currentPriceListId) { toast('No price list selected', 'warning'); return; }
  const pl = DB.priceLists.find(x => x.id === currentPriceListId);
  if (!pl) { toast('Price list not found', 'error'); return; }

  if (!window.jspdf) {
    toast('PDF generator is still loading. Please try again.', 'warning');
    return;
  }
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF({
    orientation: 'p', unit: 'pt', format: 'a4',
    encryption: {
      userPassword: '',
      ownerPassword: 'TTG-' + (getUserId() || 'secure').slice(0, 12) + '-pdf',
      userPermissions: ['print']
    }
  });

  const a4Width = 595.28;
  const a4Height = 841.89;

    const loadImage = (src) => {
      return new Promise((resolve, reject) => {
        const img = new Image();
        img.crossOrigin = 'Anonymous';
        img.onload = () => {
          const canvas = document.createElement('canvas');
          canvas.width = img.width;
          canvas.height = img.height;
          const ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0);
          resolve(canvas.toDataURL('image/png'));
        };
        img.onerror = reject;
        img.src = src;
      });
    };

    const loadGrayscaleImage = (src) => {
      return new Promise((resolve, reject) => {
        const img = new Image();
        img.crossOrigin = 'Anonymous';
        img.onload = () => {
          const canvas = document.createElement('canvas');
          canvas.width = img.width;
          canvas.height = img.height;
          const ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0);
          try {
            const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
            const data = imageData.data;
            for (let i = 0; i < data.length; i += 4) {
              const avg = 0.299 * data[i] + 0.587 * data[i+1] + 0.114 * data[i+2];
              data[i] = avg; data[i+1] = avg; data[i+2] = avg;
            }
            ctx.putImageData(imageData, 0, 0);
          } catch(e) {}
          resolve(canvas.toDataURL('image/png'));
        };
        img.onerror = reject;
        img.src = src;
      });
    };

  toast('Generating Price List PDF...', 'info');

  try {
    const drawBrandElements = (isFirstPage) => {
      // Top Green & Slate bars
      doc.setFillColor(97, 177, 70); 
      doc.rect(0, 0, a4Width, 8, 'F');
      doc.setFillColor(49, 58, 67); 
      doc.rect(0, 8, a4Width, 3, 'F');

      // Watermark with transparency so it never obscures content
      doc.saveGraphicsState();
      doc.setGState(new doc.GState({ opacity: 0.06 }));
      doc.setTextColor(180, 180, 180);
      doc.setFontSize(50);
      doc.setFont("helvetica", "bold");
      doc.text("Town Treasure Limited", 90, 500, { angle: 30 });
      doc.restoreGraphicsState();
      doc.setTextColor(49, 58, 67); // Reset
    };

    drawBrandElements(true);

    let logoData = null;
    try {
      logoData = await loadImage('assets/61367-removebg-preview.png');
      const imgProps = doc.getImageProperties(logoData);
      const logoHeight = 85; // Increased size as requested
      const logoWidth = (imgProps.width * logoHeight) / imgProps.height;
      doc.addImage(logoData, 'PNG', (a4Width - logoWidth) / 2, 35, logoWidth, logoHeight);
    } catch (e) { console.warn("Could not load logo", e); }

    let startY = 145; // Shifted down due to larger logo
    const subtitle = pl.subtitle || 'Food Supplies (Veg and Fruits)';

    // Subtitle (editable)
    doc.setFont("helvetica", "bold");
    doc.setFontSize(14);
    doc.setTextColor(49, 58, 67);
    doc.text(subtitle, a4Width / 2, startY, { align: "center" });

    // Email & Tel
    startY += 18;
    doc.setFont("helvetica", "bold");
    doc.setFontSize(10);
    doc.setTextColor(49, 58, 67);
    doc.text("Email: thetowntreasure25@gmail.com | TEL: 0708567696", a4Width / 2, startY, { align: "center" });

    // Horizontal Line
    startY += 15;
    doc.setDrawColor(220, 220, 220);
    doc.setLineWidth(1);
    doc.line(70, startY, a4Width - 70, startY);

    // Title "Price List"
    startY += 30;
    doc.setFont("helvetica", "bold");
    doc.setFontSize(24);
    doc.setTextColor(97, 177, 70);
    doc.text("Price List", a4Width / 2, startY, { align: "center" });

    // Split items by category headers into sections
    const allItems = (pl.items || []).filter(i => i.name || i.isHeader);
    const unitMap = { 
      'kgs': 'Kilogram', 'litres': 'Litre', 'pieces': 'Each', 'crates': 'Crate', 
      'bags': 'Bag', 'trays': 'Tray', 'bundles': 'Bundle', 'dozen': 'Dozen', 
      'packets': 'Packet', 'banch': 'Bunch', 'bunch': 'Bunch', 'each': 'Each'
    };

    const sections = [];
    let curSec = { header: null, items: [] };
    allItems.forEach(it => {
      if (it.isHeader) {
        if (curSec.items.length || curSec.header) sections.push(curSec);
        curSec = { header: it.name, items: [] };
      } else {
        curSec.items.push(it);
      }
    });
    if (curSec.items.length || curSec.header) sections.push(curSec);

    const tableMargin = { left: 70, right: 70, bottom: 60, top: 40 };
    const tableColumn = ["Commodity Description", "Measurement", "Price (KES)"];
    let currentY = startY + 20;

    sections.forEach(sec => {
      // Draw category header banner
      if (sec.header) {
        // Check if we need a new page
        if (currentY > a4Height - 120) {
          doc.addPage();
          drawBrandElements(false);
          currentY = 40;
        }
        const bannerX = 70;
        const bannerW = a4Width - 140;
        const bannerH = 28;
        // Green gradient banner
        doc.setFillColor(97, 177, 70);
        doc.roundedRect(bannerX, currentY, bannerW, bannerH, 3, 3, 'F');
        doc.setFont("helvetica", "bold");
        doc.setFontSize(11);
        doc.setTextColor(255, 255, 255);
        doc.text(sec.header.toUpperCase(), bannerX + 10, currentY + 18);
        currentY += bannerH + 2;
      }

      if (!sec.items.length) return;

      const tableRows = sec.items.map(it => {
        let unitLabel = unitMap[(it.unit || 'kgs').toLowerCase()] || (it.unit.charAt(0).toUpperCase() + it.unit.slice(1));
        if (it.unit === 'pieces') unitLabel = 'Each';
        return [it.name, unitLabel, fmtMoney(it.price)];
      });

      doc.autoTable({
        startY: currentY,
        head: [tableColumn],
        body: tableRows,
        theme: 'grid',
        styles: {
          fontSize: 10, cellPadding: 8, textColor: '#333333',
          lineColor: '#d1d5db', lineWidth: 0.5, font: "helvetica", valign: 'middle'
        },
        headStyles: {
          fillColor: '#61b146', textColor: '#ffffff', fontStyle: 'bold',
          lineWidth: 0.5, lineColor: '#d1d5db'
        },
        columnStyles: {
          0: { halign: 'left', cellWidth: 'auto', fontStyle: 'normal' },
          1: { halign: 'left', cellWidth: 120, textColor: '#6b7280' },
          2: { halign: 'right', cellWidth: 100, fontStyle: 'bold', textColor: [46, 125, 50] }
        },
        margin: tableMargin,
        didDrawPage: function (data) {
          if (data.pageNumber > 1) {
            drawBrandElements(false);
          }
        }
      });
      currentY = doc.lastAutoTable.finalY + 15;
    });

    // --- QR Code on Last Page ---
    try {
      const qrData = await loadImage('assets/qr%20code.jpg');
      const qrY = a4Height - 145;
      doc.addImage(qrData, 'JPEG', 40, qrY, 70, 70);
      
      doc.setFontSize(9.5);
      doc.setFont("helvetica", "bold");
      doc.setTextColor(49, 58, 67);
      doc.text("Visit Us Online:", 40, qrY - 8);
      
      doc.setFont("helvetica", "normal");
      doc.setFontSize(8.5);
      doc.setTextColor('#6b7280');
      doc.text("Scan to visit our website\nand explore our fresh\ngrocery catalog online.", 120, qrY + 25);
    } catch(e) { console.warn("Could not load QR code", e); }

    // --- Official Stamp ---
    try {
      const stampX = a4Width - 200;
      const stampY = a4Height - 195;
      const boxW = 180;
      const boxH = 120;
      
      doc.setDrawColor(30, 30, 30);
      doc.setLineWidth(2.5);
      doc.roundedRect(stampX, stampY, boxW, boxH, 10, 10, 'D');
      
      try {
        const stampData = await loadGrayscaleImage('assets/stamp.png');
        const props = doc.getImageProperties(stampData);
        let sH = 35;
        let sW = (sH * props.width) / props.height;
        if (sW > 140) {
          sW = 140;
          sH = (sW * props.height) / props.width;
        }
        doc.addImage(stampData, 'PNG', stampX + 90 - (sW/2), stampY + 5, sW, sH);
      } catch(e) {
        doc.setFont("helvetica", "bold");
        doc.setFontSize(8);
        doc.setTextColor(0, 0, 0);
        doc.text("TOWN TREASURE GROCERIES", stampX + 90, stampY + 25, { align: "center" });
      }
      
      doc.setFontSize(12);
      doc.setTextColor(0, 0, 0);
      doc.text("APPROVED PRICING", stampX + 90, stampY + 55, { align: "center" });
      
      doc.setFont("courier", "normal");
      doc.setFontSize(7);
      doc.setTextColor(220, 38, 38);
      doc.text(`DATE: ${fmtDate(new Date().toISOString().slice(0,10))}`, stampX + 90, stampY + 67, { align: "center" });
      
      try {
        if (DB.settings && DB.settings.signature) {
          const sigData = await loadImage(DB.settings.signature);
          const props = doc.getImageProperties(sigData);
          const maxSigW = 160;
          let sigH = 45;
          let sigW = (sigH * props.width) / props.height;
          if (sigW > maxSigW) {
            sigW = maxSigW;
            sigH = (sigW * props.height) / props.width;
          }
          doc.addImage(sigData, 'PNG', stampX + 90 - (sigW/2), stampY + 70, sigW, sigH);
        } else {
          doc.setDrawColor(0, 0, 0);
          doc.setLineWidth(0.5);
          doc.line(stampX + 30, stampY + 88, stampX + 150, stampY + 88);
          doc.setFont("helvetica", "normal");
          doc.setFontSize(6);
          doc.setTextColor(0, 0, 0);
          doc.text("Sign Here", stampX + 90, stampY + 95, { align: "center" });
        }
      } catch(e) {}
    } catch(err) {
      console.warn("Failed to draw stamp on PDF", err);
    }

    // --- Footer on ALL Pages ---
    const pageCount = doc.internal.getNumberOfPages();
    for (let i = 1; i <= pageCount; i++) {
      doc.setPage(i);
      doc.setFillColor(49, 58, 67);
      doc.rect(0, a4Height - 40, a4Width, 40, 'F');
      
      doc.setFont("helvetica", "italic");
      doc.setFontSize(9);
      doc.setTextColor('#ffffff');
      doc.text("Town Treasure Groceries — Fresh & Affordable", a4Width / 2, a4Height - 15, { align: "center" });
    }

    const filename = `${pl.name.replace(/[^a-zA-Z0-9]/g, '_')}.pdf`;
    doc.save(filename);
    toast('PDF Downloaded!', 'success');

  } catch (error) {
    console.error("PDF Generation Error: ", error);
    toast("Error generating PDF", "error");
  }
}

function sharePriceListWhatsApp() {
  if (!currentPriceListId) return;
  const pl = DB.priceLists.find(x => x.id === currentPriceListId);
  if (!pl) return;

  const items = (pl.items || []).filter(i => i.name);
  let text = `*TOWN TREASURE GROCERIES*\n*${pl.name}*\n\n`;

  // Group by category
  const grouped = {};
  items.forEach(i => {
    if (!grouped[i.category]) grouped[i.category] = [];
    grouped[i.category].push(i);
  });

  Object.entries(grouped).forEach(([cat, catItems]) => {
    text += `*${cat.toUpperCase()}*\n`;
    catItems.forEach(i => {
      text += `  - ${i.name} — KES ${fmtMoney(i.price)} / ${i.unit}${i.notes ? ' (' + i.notes + ')' : ''}\n`;
    });
    text += '\n';
  });

  text += `Orders: 0708567696\nEmail: thetowntreasure25@gmail.com\nPrices subject to market changes`;

  // Download PDF first
  downloadPriceListPDF();
  setTimeout(() => {
    window.open(`https://wa.me/?text=${encodeURIComponent(text)}`, '_blank');
  }, 1500);
}

function buildPriceListPreview(pl) {
  const allItems = (pl.items || []).filter(i => i.name || i.isHeader);
  const subtitle = pl.subtitle || 'Food Supplies (Veg and Fruits)';
  
  const unitMap = { 
    'kgs': 'Kilogram', 
    'litres': 'Litre', 
    'pieces': 'Each', 
    'crates': 'Crate', 
    'bags': 'Bag', 
    'trays': 'Tray', 
    'bundles': 'Bundle', 
    'dozen': 'Dozen', 
    'packets': 'Packet', 
    'banch': 'Bunch',
    'bunch': 'Bunch',
    'each': 'Each'
  };

  // Split items into sections — each header starts a new section
  const sections = [];
  let currentSection = { header: null, items: [] };
  allItems.forEach(it => {
    if (it.isHeader) {
      if (currentSection.items.length || currentSection.header) {
        sections.push(currentSection);
      }
      currentSection = { header: it.name, items: [] };
    } else {
      currentSection.items.push(it);
    }
  });
  if (currentSection.items.length || currentSection.header) {
    sections.push(currentSection);
  }

  const theadRow = `<tr style="background:#61b146;color:white;">
    <th style="padding:12px;text-align:left;border:1px solid #d1d5db;border-left:none;">Commodity Description</th>
    <th style="padding:12px;text-align:left;border:1px solid #d1d5db;">Measurement</th>
    <th style="padding:12px;text-align:right;border:1px solid #d1d5db;border-right:none;">Price (KES)</th>
  </tr>`;

  let sectionsHtml = sections.map(sec => {
    const headerBanner = sec.header 
      ? `<div style="background:linear-gradient(135deg,#61b146,#4a9e36);color:white;font-weight:700;font-size:15px;letter-spacing:0.5px;text-transform:uppercase;padding:10px 14px;margin-top:24px;border-radius:4px 4px 0 0;">${sec.header}</div>` 
      : '';
    
    if (!sec.items.length) return headerBanner;

    const rows = sec.items.map(it => {
      let unitLabel = unitMap[(it.unit || 'kgs').toLowerCase()] || (it.unit.charAt(0).toUpperCase() + it.unit.slice(1));
      if (it.unit === 'pieces') unitLabel = 'Each';
      return `<tr>
        <td style="padding:12px;border:1px solid #d1d5db;border-left:none;">${it.name}</td>
        <td style="padding:12px;border:1px solid #d1d5db;color:#6b7280;">${unitLabel}</td>
        <td style="padding:12px;border:1px solid #d1d5db;border-right:none;text-align:right;font-weight:700;color:#2e7d32;">${fmtMoney(it.price)}</td>
      </tr>`;
    }).join('');

    const topRadius = sec.header ? 'border-radius:0;' : '';
    return `${headerBanner}
      <table style="width:100%;border-collapse:collapse;font-size:14px;border:1px solid #d1d5db;${topRadius}">
        <thead>${theadRow}</thead>
        <tbody>${rows}</tbody>
      </table>`;
  }).join('');

  const el = document.createElement('div');
  el.className = 'invoice-preview';
  el.style.width = '210mm';
  el.style.minHeight = '297mm';
  el.style.margin = '0 auto';
  el.style.backgroundColor = '#ffffff';
  el.style.position = 'relative';
  el.style.boxSizing = 'border-box';
  
  el.innerHTML = `
    <div style="position:absolute;top:0;left:0;right:0;height:12px;background:#61b146;"></div>
    <div style="position:absolute;top:12px;left:0;right:0;height:4px;background:#313a43;"></div>
    
    <div style="position:absolute;top:50%;left:50%;transform:translate(-50%, -50%) rotate(-30deg);font-size:80px;color:rgba(245,245,245,0.7);font-weight:bold;white-space:nowrap;z-index:0;pointer-events:none;">Town Treasure Limited</div>

    <div style="position:relative;z-index:1;padding:40px 60px 240px;">
      <div style="text-align:center;margin-top:20px;">
        <img src="assets/61367-removebg-preview.png" style="height:110px;object-fit:contain;display:block;margin:0 auto;" alt="Logo">
        <h2 style="font-size:18px;color:#313a43;margin:20px 0 5px;">${subtitle}</h2>
        <p style="font-size:14px;color:#313a43;font-weight:600;margin:0;">Email: thetowntreasure25@gmail.com | TEL: 0708567696</p>
        <hr style="border:none;border-top:1px solid #e0e0e0;margin:20px 20px;">
        <h1 style="font-size:28px;color:#61b146;margin:30px 0;">Price List</h1>
      </div>

      ${sectionsHtml}
      
      <!-- Official Stamp -->
      <div class="official-stamp" style="position:absolute; right:60px; bottom:80px; width:220px; border:3px solid rgba(20,20,20,0.85); border-radius:10px; padding:10px; text-align:center; transform:rotate(-4deg); z-index:10; background:transparent; mix-blend-mode:multiply; box-shadow:none;">
        <img src="assets/stamp.png" style="max-width: 140px; max-height: 50px; object-fit: contain; filter: grayscale(100%); mix-blend-mode: multiply; margin-bottom: 5px;">
        <div style="font-size:1.1rem; font-weight:900; color:#000000; letter-spacing:1px; margin-bottom:5px;">APPROVED PRICING</div>
        <div style="font-size:0.7rem; color:#dc2626; font-family:monospace;">DATE: ${fmtDate(new Date().toISOString().slice(0,10))}</div>
        ${(DB.settings && DB.settings.signature) ? `<img src="${DB.settings.signature}" style="max-width:180px; height:auto; max-height:70px; margin-top:5px; display:inline-block; object-fit:contain; mix-blend-mode:multiply;">` : `<div style="height:40px; margin-top:5px; border-bottom:1px solid #000000; width:80%; margin:5px auto 0 auto; line-height:50px; font-size:0.6rem; color:#000000;">Sign Here</div>`}
      </div>
    </div>

    <div style="position:absolute;bottom:0;left:0;right:0;height:45px;background:#313a43;color:white;display:flex;align-items:center;justify-content:center;font-style:italic;font-size:12px;z-index:2;">
      Town Treasure Groceries — Fresh & Affordable
    </div>
  `;
  return el;
}

/* ═══════════════════════════════════════════════════════════════════════════
   Town Treasure Groceries — Price List Optical Scanner & Vision Ingestion
   ═══════════════════════════════════════════════════════════════════════════ */

let priceListScanPhotos = [];
let lastExtractedPriceListData = null;
let priceListScanTargetMode = 'new'; // 'new' or 'append'

function openPriceListScannerModal(mode = 'new') {
  priceListScanTargetMode = mode;
  lastExtractedPriceListData = null;
  priceListScanPhotos = [];

  const titleEl = document.getElementById('priceListScannerModalTitle');
  if (titleEl) {
    titleEl.textContent = mode === 'new' 
      ? 'Scan & Create New Price List (Optical Engine)' 
      : 'Scan & Append to Price List (Optical Engine)';
  }

  const dropzone = document.getElementById('plScanDropzone');
  if (dropzone) dropzone.style.display = 'block';

  const previewWrap = document.getElementById('plScanPreviewWrap');
  if (previewWrap) previewWrap.style.display = 'none';

  const resultsWrap = document.getElementById('plScanResultsWrap');
  if (resultsWrap) resultsWrap.style.display = 'none';

  const progressWrap = document.getElementById('plScanProgressWrap');
  if (progressWrap) progressWrap.style.display = 'none';

  const btnApply = document.getElementById('btnApplyScannedPriceList');
  if (btnApply) btnApply.style.display = 'none';

  renderPriceListPhotosList();
  openModal('priceListScannerModal');
}

async function handlePriceListPhoto(inputOrFiles) {
  let files = [];
  if (inputOrFiles instanceof HTMLInputElement) {
    if (!inputOrFiles.files || !inputOrFiles.files.length) return;
    files = Array.from(inputOrFiles.files);
    inputOrFiles.value = '';
  } else if (Array.isArray(inputOrFiles) || inputOrFiles instanceof FileList) {
    files = Array.from(inputOrFiles);
  } else if (inputOrFiles instanceof File) {
    files = [inputOrFiles];
  } else {
    return;
  }

  const progressWrap = document.getElementById('plScanProgressWrap');
  const progressText = document.getElementById('plScanProgressText');

  for (const file of files) {
    const isPdf = file.type === 'application/pdf' || (file.name && file.name.toLowerCase().endsWith('.pdf'));

    if (isPdf) {
      if (progressWrap) {
        progressWrap.style.display = 'block';
        if (progressText) progressText.textContent = `Converting PDF pages (${file.name})...`;
      }
      try {
        const pdfResult = await OCRConsensus.convertPdfToPages(file, (status) => {
          if (progressText) progressText.textContent = status;
        });

        const pageImages = pdfResult.images || (pdfResult.pages ? pdfResult.pages.map(p => p.dataUrl || p) : []);
        if (pageImages && pageImages.length) {
          pageImages.forEach(img => {
            const dataUrl = typeof img === 'string' ? img : (img.dataUrl || img);
            priceListScanPhotos.push(dataUrl);
          });
          toast(`Loaded ${pageImages.length} page${pageImages.length > 1 ? 's' : ''} from PDF!`, 'success');
        } else {
          toast('No pages could be extracted from PDF.', 'warning');
        }
      } catch (err) {
        console.error('PDF parsing error:', err);
        toast('PDF extraction error: ' + err.message, 'error');
      } finally {
        if (progressWrap) progressWrap.style.display = 'none';
      }
    } else {
      // Image file
      await new Promise((resolve) => {
        const reader = new FileReader();
        reader.onload = (e) => {
          const img = new Image();
          img.onload = () => {
            const maxDim = 1600;
            let w = img.width, h = img.height;
            if (w > maxDim || h > maxDim) {
              if (w > h) { h = Math.round(h * maxDim / w); w = maxDim; }
              else { w = Math.round(w * maxDim / h); h = maxDim; }
            }
            const canvas = document.createElement('canvas');
            canvas.width = w;
            canvas.height = h;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, w, h);
            const dataUrl = canvas.toDataURL('image/jpeg', 0.85);

            priceListScanPhotos.push(dataUrl);
            resolve();
          };
          img.onerror = resolve;
          img.src = e.target.result;
        };
        reader.onerror = resolve;
        reader.readAsDataURL(file);
      });
    }
  }

  renderPriceListPhotosList();
}

function renderPriceListPhotosList() {
  const dropzone = document.getElementById('plScanDropzone');
  const previewWrap = document.getElementById('plScanPreviewWrap');
  const photoGrid = document.getElementById('plScanPhotoGrid');

  if (!priceListScanPhotos.length) {
    if (dropzone) dropzone.style.display = 'block';
    if (previewWrap) previewWrap.style.display = 'none';
    return;
  }

  if (dropzone) dropzone.style.display = 'none';
  if (previewWrap) previewWrap.style.display = 'block';

  if (photoGrid) {
    photoGrid.innerHTML = priceListScanPhotos.map((dataUrl, idx) => `
      <div style="position:relative; display:inline-block; margin:6px; border:1px solid var(--border); border-radius:8px; overflow:hidden; background:#fff; box-shadow:0 2px 6px rgba(0,0,0,0.08);">
        <img src="${dataUrl}" style="width:110px; height:130px; object-fit:cover; display:block;" alt="Price List Page ${idx + 1}">
        <div style="position:absolute; bottom:0; left:0; right:0; background:rgba(0,0,0,0.65); color:#fff; font-size:0.7rem; font-weight:700; text-align:center; padding:2px 0;">
          Page ${idx + 1}
        </div>
        <button type="button" onclick="removePriceListPhoto(${idx})" title="Remove page" style="position:absolute; top:3px; right:3px; background:var(--danger, #dc2626); color:#fff; border:none; border-radius:50%; width:20px; height:20px; cursor:pointer; display:flex; align-items:center; justify-content:center;">
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
        </button>
      </div>
    `).join('');
  }

  const btnRun = document.getElementById('btnRunPriceListOCR');
  if (btnRun) {
    btnRun.innerHTML = `
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:middle; margin-right:5px;">
        <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
      </svg>
      Extract Produce Pricing from ${priceListScanPhotos.length} Page${priceListScanPhotos.length > 1 ? 's' : ''}
    `;
  }
}

function removePriceListPhoto(idx) {
  priceListScanPhotos.splice(idx, 1);
  renderPriceListPhotosList();
}

async function runPriceListOCR() {
  if (!priceListScanPhotos.length) return toast('Please attach at least one price list photo or PDF page', 'warning');

  const progressWrap = document.getElementById('plScanProgressWrap');
  const progressText = document.getElementById('plScanProgressText');
  if (progressWrap) progressWrap.style.display = 'block';
  if (progressText) progressText.textContent = `Analyzing ${priceListScanPhotos.length} page(s) with Optical Engine...`;

  const btnRun = document.getElementById('btnRunPriceListOCR');
  if (btnRun) btnRun.disabled = true;

  try {
    const result = await OCRConsensus.processPriceList(priceListScanPhotos, (status) => {
      if (progressText) progressText.textContent = status;
    });

    lastExtractedPriceListData = result;
    if (progressWrap) progressWrap.style.display = 'none';

    renderScannedPriceListResults(result);
    const produceCount = (result.items || []).filter(i => !i.isHeader).length;
    toast(`Successfully extracted ${produceCount} items across ${priceListScanPhotos.length} page(s)!`, 'success');
  } catch (err) {
    console.error('Price List Optical Scan failed:', err);
    if (progressWrap) progressWrap.style.display = 'none';
    toast('Optical extraction error: ' + err.message, 'error');
  } finally {
    if (btnRun) btnRun.disabled = false;
  }
}

function renderScannedPriceListResults(result) {
  const resultsWrap = document.getElementById('plScanResultsWrap');
  const tbody = document.getElementById('plScanItemsBody');
  const countEl = document.getElementById('plScanItemsCount');
  const docTitleEl = document.getElementById('plScanDocTitle');
  const btnApply = document.getElementById('btnApplyScannedPriceList');

  if (!result || !result.items || !result.items.length) {
    if (resultsWrap) resultsWrap.style.display = 'none';
    if (btnApply) btnApply.style.display = 'none';
    return;
  }

  const items = result.items;
  const produceItems = items.filter(i => !i.isHeader);

  if (countEl) {
    countEl.textContent = `${produceItems.length} produce item${produceItems.length !== 1 ? 's' : ''} extracted`;
  }
  if (docTitleEl) {
    docTitleEl.textContent = result.name || 'Price List';
  }

  if (tbody) {
    tbody.innerHTML = items.map(it => {
      if (it.isHeader) {
        return `
          <tr style="background:#e8f5e9; font-weight:700;">
            <td colspan="4" style="color:#2e7d32; text-transform:uppercase; font-size:0.78rem; padding:6px 10px; letter-spacing:0.5px;">
              📁 SECTION: ${escapeHtml(it.name)}
            </td>
          </tr>
        `;
      }
      return `
        <tr>
          <td style="font-weight:600; color:var(--text);">${escapeHtml(it.name)} ${it.notes ? `<small style="color:#6b7280; font-weight:normal;">(${escapeHtml(it.notes)})</small>` : ''}</td>
          <td style="color:var(--text-2); text-transform:capitalize;">${escapeHtml(it.category || 'vegetables')}</td>
          <td style="color:var(--text-2);">${escapeHtml(it.unit || 'kgs')}</td>
          <td style="text-align:right; font-weight:700; color:#15803d;">KES ${(parseFloat(it.price) || 0).toLocaleString()}</td>
        </tr>
      `;
    }).join('');
  }

  if (resultsWrap) resultsWrap.style.display = 'block';
  if (btnApply) {
    btnApply.style.display = 'inline-flex';
    btnApply.textContent = priceListScanTargetMode === 'new' ? 'Create New Price List' : 'Apply to Active Table';
  }
}

function applyScannedPriceList(bypassDuplicateCheck = false) {
  if (!lastExtractedPriceListData || !lastExtractedPriceListData.items || !lastExtractedPriceListData.items.length) {
    return toast('No extracted items to apply', 'warning');
  }

  const items = lastExtractedPriceListData.items;
  const plName = lastExtractedPriceListData.name || ('Price List — ' + new Date().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }));

  if (priceListScanTargetMode === 'new') {
    if (!bypassDuplicateCheck) {
      const collision = checkPriceListCollisions(plName, items, null);
      if (collision) {
        const matchPct = Math.round(collision.confidence * 100);
        showPriceListDuplicateModal({
          title: 'INTEGRITY HAZARD: DUPLICATE SCANNED PRICE LIST',
          heading: `An identical or matching price list ("${collision.matched.name}") already exists in Veronica's catalog ledger.`,
          details: `Town Treasure Smart Audit detected ${matchPct}% similarity between this scan and existing catalog records. Continuing will create a redundant duplicate price list in the database.`,
          existingName: collision.matched.name,
          existingDate: `Date: ${fmtDate(collision.matched.updatedAt || collision.matched.createdAt)}`,
          existingCount: `${collision.existingItemCount} produce lines`,
          newName: plName,
          newDate: `Date: ${fmtDate(new Date())}`,
          newCount: `${items.filter(i => !i.isHeader).length} produce lines`,
          overlapText: `⚠️ Produce Overlap: ${collision.matchingKeys.length} matching commodities (${Math.round(collision.overlapRatio * 100)}% overlap with "${collision.matched.name}").`,
          adviceText: 'An existing price list with matching produce items already exists. You can stop and view the existing catalog, or proceed anyway to create a new separate price list record.',
          onProceed: function() {
            applyScannedPriceList(true);
          }
        });
        return;
      }
    }

    const pl = {
      id: genId(),
      name: plName,
      subtitle: lastExtractedPriceListData.subtitle || 'Food Supplies (Veg and Fruits)',
      status: 'draft',
      items: items,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };
    const list = DB.priceLists;
    list.push(pl);
    DB.priceLists = list;
    closeModal('priceListScannerModal');
    editPriceList(pl.id);
    toast(`Created new price list with ${items.filter(i => !i.isHeader).length} items from optical scan!`, 'success');
  } else {
    const pl = DB.priceLists.find(x => x.id === currentPriceListId);
    if (!pl) return toast('Current price list not found', 'error');

    const body = document.getElementById('plItemsBody');
    if (!body) return;

    const existingItems = collectPriceListData();
    const hasMeaningfulItems = existingItems.some(i => i.name && i.name.trim().length > 0);

    if (!hasMeaningfulItems) {
      body.innerHTML = '';
      pl.items = items;
      renderPriceListItems(pl);
    } else {
      items.forEach((item) => {
        const row = document.createElement('tr');
        const id = item.id || genId();
        row.setAttribute('data-item-id', id);
        if (item.isHeader) {
          row.setAttribute('data-type', 'header');
          row.style.background = 'linear-gradient(135deg, #61b146, #4a9e36)';
          row.style.cursor = 'move';
          row.innerHTML = buildCategoryHeaderRow({ ...item, id }).replace(/^<tr[^>]*>/, '').replace(/<\/tr>$/, '');
        } else {
          row.innerHTML = buildPriceListRow({ ...item, id }, body.rows.length).replace(/^<tr[^>]*>/, '').replace(/<\/tr>$/, '');
        }
        body.appendChild(row);
      });
      attachPriceListListeners();
      auditPriceListDuplicates();
      triggerPriceListAutoSave();
    }
    closeModal('priceListScannerModal');
    const scannedCount = items.filter(i => !i.isHeader).length;
    const dups = typeof auditPriceListDuplicates === 'function' ? auditPriceListDuplicates() : [];
    if (dups.length > 0) {
      toast(`Appended ${scannedCount} items from optical scan. ⚠️ ${dups.length} duplicate commodities flagged in table`, 'warning');
    } else {
      toast(`Appended ${scannedCount} items from optical scan!`, 'success');
    }
  }
}


