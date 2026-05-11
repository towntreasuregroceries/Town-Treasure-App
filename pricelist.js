/* ══ Price List Module (Independent) ══ */

let currentPriceListId = null;
let priceListAutoSaveTimer = null;

/* ── Price List CRUD ── */
function renderPriceLists() {
  const body = document.getElementById('priceListsBody');
  if (!body) return;
  const lists = DB.priceLists.slice().reverse();

  if (!lists.length) {
    body.innerHTML = '<tr><td colspan="5" class="empty-state"><h3>No price lists yet</h3><p>Create your first price list to share with restaurants.</p></td></tr>';
    return;
  }

  body.innerHTML = lists.map(pl => {
    const statusCls = pl.status === 'active' ? 'badge-success' : pl.status === 'draft' ? 'badge-warning' : 'badge-info';
    const itemCount = pl.items ? pl.items.length : 0;
    return `<tr>
      <td><strong>${pl.name}</strong></td>
      <td>${itemCount} items</td>
      <td>${fmtDate(pl.updatedAt || pl.createdAt)}</td>
      <td><span class="badge ${statusCls}">${pl.status}</span></td>
      <td>
        <button class="btn btn-sm btn-primary" onclick="editPriceList('${pl.id}')">Edit</button>
        <button class="btn btn-sm btn-secondary" onclick="duplicatePriceList('${pl.id}')">Duplicate</button>
        <button class="btn btn-sm btn-danger" onclick="deletePriceList('${pl.id}')">Del</button>
      </td>
    </tr>`;
  }).join('');
}

function createNewPriceList() {
  const pl = {
    id: genId(),
    name: 'Price List — ' + new Date().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }),
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

  body.innerHTML = pl.items.map((item, idx) => buildPriceListRow(item, idx)).join('');
  attachPriceListListeners();
}

function buildPriceListRow(item, idx) {
  const categories = ['vegetables', 'fruits', 'cereals', 'dairy', 'meat', 'fish', 'legumes', 'spices', 'packaged', 'other'];
  const catOptions = categories.map(c => `<option value="${c}" ${item.category === c ? 'selected' : ''}>${c.charAt(0).toUpperCase() + c.slice(1)}</option>`).join('');
  const units = ['kgs', 'litres', 'pieces', 'crates', 'bags', 'trays', 'bundles', 'dozen', 'packets', 'banch'];
  const unitOptions = units.map(u => `<option value="${u}" ${item.unit === u ? 'selected' : ''}>${u.charAt(0).toUpperCase() + u.slice(1)}</option>`).join('');

  return `<tr data-item-id="${item.id}">
    <td><input type="text" class="pl-item-name" value="${item.name || ''}" placeholder="e.g. Tomatoes"></td>
    <td><select class="pl-item-cat form-control" style="padding:6px 4px;font-size:0.8rem;">${catOptions}</select></td>
    <td><select class="pl-item-unit form-control" style="padding:6px 4px;font-size:0.8rem;">${unitOptions}</select></td>
    <td><input type="number" class="pl-item-price" min="0" step="any" value="${item.price || ''}" placeholder="0.00"></td>
    <td><input type="text" class="pl-item-notes" value="${item.notes || ''}" placeholder="Grade A, etc."></td>
    <td><button type="button" class="btn-remove-row" onclick="removePriceListRow(this)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></td>
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

function removePriceListRow(btn) {
  const body = document.getElementById('plItemsBody');
  if (body.rows.length <= 1) return toast('Must have at least one item', 'warning');
  btn.closest('tr').remove();
  triggerPriceListAutoSave();
}

function attachPriceListListeners() {
  document.querySelectorAll('#plItemsBody input, #plItemsBody select').forEach(inp => {
    inp.removeEventListener('input', triggerPriceListAutoSave);
    inp.addEventListener('input', triggerPriceListAutoSave);
  });
}

function triggerPriceListAutoSave() {
  clearTimeout(priceListAutoSaveTimer);
  priceListAutoSaveTimer = setTimeout(() => savePriceListDraft(), 1000);
}

/* ── Save / Publish ── */
function collectPriceListData() {
  const items = [];
  document.querySelectorAll('#plItemsBody tr').forEach(row => {
    items.push({
      id: row.getAttribute('data-item-id') || genId(),
      name: row.querySelector('.pl-item-name')?.value.trim() || '',
      category: row.querySelector('.pl-item-cat')?.value || 'other',
      unit: row.querySelector('.pl-item-unit')?.value || 'kgs',
      price: parseFloat(row.querySelector('.pl-item-price')?.value) || 0,
      notes: row.querySelector('.pl-item-notes')?.value.trim() || ''
    });
  });
  return items;
}

function savePriceListDraft() {
  if (!currentPriceListId) return;
  const list = DB.priceLists;
  const idx = list.findIndex(x => x.id === currentPriceListId);
  if (idx < 0) return;

  list[idx].name = document.getElementById('plEditName')?.value.trim() || list[idx].name;
  list[idx].items = collectPriceListData();
  list[idx].updatedAt = new Date().toISOString();
  DB.priceLists = list;
}

function publishPriceList() {
  if (!currentPriceListId) return;
  const list = DB.priceLists;
  const idx = list.findIndex(x => x.id === currentPriceListId);
  if (idx < 0) return;

  const items = collectPriceListData().filter(i => i.name);
  if (!items.length) return toast('Add at least one item with a name', 'error');

  list[idx].name = document.getElementById('plEditName')?.value.trim() || list[idx].name;
  list[idx].status = document.getElementById('plEditStatus')?.value || 'active';
  list[idx].items = items;
  list[idx].updatedAt = new Date().toISOString();
  DB.priceLists = list;
  toast('Price list saved!');
  navigateTo('pricelists');
}

/* ── Smart Import from Past Invoices ── */
function smartImportItems() {
  const invoices = DB.invoices.filter(i => i.status !== 'draft');
  if (!invoices.length) return toast('No invoices found to import from', 'warning');

  // Extract unique items with latest prices
  const itemMap = {};
  invoices.sort((a, b) => a.date.localeCompare(b.date)).forEach(inv => {
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

  // Add imported items to current list
  const body = document.getElementById('plItemsBody');
  importedItems.forEach(item => {
    const row = document.createElement('tr');
    const id = genId();
    row.setAttribute('data-item-id', id);
    row.innerHTML = buildPriceListRow({ ...item, id, notes: '' }, body.rows.length).replace(/^<tr[^>]*>/, '').replace(/<\/tr>$/, '');
    body.appendChild(row);
  });
  attachPriceListListeners();
  triggerPriceListAutoSave();
  toast(`Imported ${importedItems.length} items from past invoices`);
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
  customConfirm('This price list will be moved to the Recycle Bin.', 'Delete Price List', 'Yes, Delete', true, () => {
    const pl = DB.priceLists.find(x => x.id === id);
    if (pl) {
      const deleted = { ...pl, deletedAt: new Date().toISOString() };
      const bin = DB.deletedPriceLists;
      bin.push(deleted);
      DB.deletedPriceLists = bin;
    }
    DB.priceLists = DB.priceLists.filter(x => x.id !== id);
    renderPriceLists();
    toast('Price list moved to Recycle Bin');
  });
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
  renderBin();
  toast('Price list restored');
}

/* ── Download / Share Price List ── */
function downloadPriceListPDF() {
  if (!currentPriceListId) return;
  savePriceListDraft();
  const pl = DB.priceLists.find(x => x.id === currentPriceListId);
  if (!pl) return;

  // Build preview and download
  const previewEl = buildPriceListPreview(pl);
  const wrapper = document.createElement('div');
  wrapper.appendChild(previewEl);
  document.body.appendChild(wrapper);

  const opt = {
    margin: [0, 0, 0, 0],
    filename: `${pl.name.replace(/[^a-zA-Z0-9]/g, '_')}.pdf`,
    image: { type: 'jpeg', quality: 1.0 },
    html2canvas: { scale: 2, useCORS: true },
    jsPDF: { unit: 'in', format: 'a4', orientation: 'portrait' }
  };

  document.body.classList.add('exporting-pdf');
  html2pdf().set(opt).from(previewEl).save().then(() => {
    document.body.classList.remove('exporting-pdf');
    document.body.removeChild(wrapper);
  });
  toast('Downloading PDF...');
}

function sharePriceListWhatsApp() {
  if (!currentPriceListId) return;
  savePriceListDraft();
  const pl = DB.priceLists.find(x => x.id === currentPriceListId);
  if (!pl) return;

  const items = (pl.items || []).filter(i => i.name);
  let text = `📋 *TOWN TREASURE GROCERIES*\n*${pl.name}*\n\n`;

  // Group by category
  const grouped = {};
  items.forEach(i => {
    if (!grouped[i.category]) grouped[i.category] = [];
    grouped[i.category].push(i);
  });

  const catEmoji = { vegetables: '🥕', fruits: '🍎', cereals: '🌾', dairy: '🥛', meat: '🍖', fish: '🐟', legumes: '🫘', spices: '🧂', packaged: '🥫', other: '📦' };

  Object.entries(grouped).forEach(([cat, catItems]) => {
    text += `${catEmoji[cat] || '📦'} *${cat.toUpperCase()}*\n`;
    catItems.forEach(i => {
      text += `  ${i.name} — KES ${fmtMoney(i.price)} / ${i.unit}${i.notes ? ' (' + i.notes + ')' : ''}\n`;
    });
    text += '\n';
  });

  text += `📞 Orders: 0708567696\n📧 towntreasuregroceries@gmail.com\n⚠️ Prices subject to market changes`;

  // Download PDF first
  downloadPriceListPDF();
  setTimeout(() => {
    window.open(`https://wa.me/?text=${encodeURIComponent(text)}`, '_blank');
  }, 1500);
}

function buildPriceListPreview(pl) {
  const items = (pl.items || []).filter(i => i.name);
  const grouped = {};
  items.forEach(i => {
    if (!grouped[i.category]) grouped[i.category] = [];
    grouped[i.category].push(i);
  });

  const catEmoji = { vegetables: '🥕', fruits: '🍎', cereals: '🌾', dairy: '🥛', meat: '🍖', fish: '🐟', legumes: '🫘', spices: '🧂', packaged: '🥫', other: '📦' };

  let tablesHtml = '';
  Object.entries(grouped).forEach(([cat, catItems]) => {
    tablesHtml += `
      <div style="margin-bottom:20px;">
        <h3 style="font-size:0.95rem;color:#2E7D32;margin-bottom:8px;text-transform:uppercase;letter-spacing:1px;">${catEmoji[cat] || '📦'} ${cat}</h3>
        <table class="receipt-table" style="margin-bottom:0;">
          <thead><tr><th>Item</th><th style="text-align:right;">Unit</th><th style="text-align:right;">Price (KES)</th>${catItems.some(i => i.notes) ? '<th>Notes</th>' : ''}</tr></thead>
          <tbody>${catItems.map(i => `<tr><td>${i.name}</td><td style="text-align:right;text-transform:capitalize;">${i.unit}</td><td style="text-align:right;font-weight:600;">KES ${fmtMoney(i.price)}</td>${catItems.some(x => x.notes) ? `<td style="font-size:0.8rem;color:#616161;">${i.notes || ''}</td>` : ''}</tr>`).join('')}</tbody>
        </table>
      </div>`;
  });

  const el = document.createElement('div');
  el.className = 'invoice-preview';
  el.style.maxWidth = '800px';
  el.innerHTML = `
    <div class="invoice-header-shape" style="position:relative;height:140px;overflow:hidden;border-top-left-radius:8px;border-top-right-radius:8px;">
      <svg width="100%" height="140" viewBox="0 0 800 140" preserveAspectRatio="none" style="display:block;position:absolute;top:0;left:0;width:100%;height:100%;"><rect x="0" y="0" width="800" height="140" fill="#61b146"/><path d="M240,0 L810,0 L810,80 Q610,120 240,80 Z" fill="#313a43"/><path d="M-50,140 Q400,60 850,140 Z" fill="white"/></svg>
      <div class="header-content"><img src="assets/logo.png" alt="Logo" class="invoice-logo-img"></div>
    </div>
    <div class="invoice-title-row">
      <div class="invoice-title">PRICE LIST</div>
      <div style="text-align:right;font-size:0.85rem;color:#616161;">${pl.name}</div>
    </div>
    <div style="padding:0 50px 20px;">
      ${tablesHtml}
    </div>
    <div style="padding:10px 50px 20px;font-size:0.82rem;color:#616161;border-top:1px solid #e0e0e0;margin:0 50px;">
      <p>📞 Orders: 0708567696 &nbsp;|&nbsp; 📧 towntreasuregroceries@gmail.com</p>
      <p style="margin-top:4px;">⚠️ Prices are subject to market changes without prior notice.</p>
    </div>
    <div class="invoice-footer-shape">
      <div style="position:absolute;bottom:20px;left:0;right:0;display:flex;justify-content:space-between;padding:0 50px;color:white;z-index:5;">
        <div style="font-style:italic;font-size:0.9rem;">Town Treasure Groceries — Fresh & Affordable</div>
        <div style="font-size:0.8rem;">towntreasuregroceries.com</div>
      </div>
    </div>`;
  return el;
}
