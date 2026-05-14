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
        <button class="btn btn-sm btn-primary" onclick="viewPriceList('${pl.id}')">View</button>
        <button class="btn btn-sm btn-secondary" onclick="editPriceList('${pl.id}')">Edit</button>
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
}

function buildCategoryHeaderRow(item) {
  return `<tr data-item-id="${item.id}" data-type="header" style="background: linear-gradient(135deg, #61b146, #4a9e36); cursor: move;">
    <td colspan="5" style="padding: 10px 16px; border: none;">
      <input type="text" class="pl-header-name" value="${item.name || ''}" placeholder="e.g. Fruits, Meat, Vegetables…" 
        style="background:transparent; border:none; color:white; font-weight:700; font-size:1rem; letter-spacing:0.5px; text-transform:uppercase; width:100%; outline:none;">
    </td>
    <td style="border: none; text-align: center;">
      <button type="button" class="btn-remove-row" onclick="removePriceListRow(this)" style="color:rgba(255,255,255,0.8);">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
    </td>
  </tr>`;
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

function publishPriceList() {
  if (!currentPriceListId) return;
  const list = DB.priceLists;
  const idx = list.findIndex(x => x.id === currentPriceListId);
  if (idx < 0) return;

  const items = collectPriceListData().filter(i => i.name);
  if (!items.length) return toast('Add at least one item with a name', 'error');

  list[idx].name = document.getElementById('plEditName')?.value.trim() || list[idx].name;
  list[idx].subtitle = document.getElementById('plEditSubtitle')?.value.trim() || list[idx].subtitle || '';
  list[idx].status = document.getElementById('plEditStatus')?.value || 'active';
  list[idx].items = items;
  list[idx].updatedAt = new Date().toISOString();
  DB.priceLists = list;
  toast('Price list saved!');
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
      ownerPassword: 'TownTreasure2025!',
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
      const stampY = a4Height - 175;
      const boxW = 180;
      const boxH = 100;
      
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
        ${(DB.settings && DB.settings.signature) ? `<img src="${DB.settings.signature}" style="max-width:200px; max-height:80px; margin-top:5px; display:inline-block; mix-blend-mode:multiply;">` : `<div style="height:40px; margin-top:5px; border-bottom:1px solid #000000; width:80%; margin:5px auto 0 auto; line-height:50px; font-size:0.6rem; color:#000000;">Sign Here</div>`}
      </div>
    </div>

    <div style="position:absolute;bottom:0;left:0;right:0;height:45px;background:#313a43;color:white;display:flex;align-items:center;justify-content:center;font-style:italic;font-size:12px;z-index:2;">
      Town Treasure Groceries — Fresh & Affordable
    </div>
  `;
  return el;
}

