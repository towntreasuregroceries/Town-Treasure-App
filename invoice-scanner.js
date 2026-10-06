/* ═══════════════════════════════════════════════════════════════════════════
   Town Treasure Groceries — Direct Invoice Docket Scanner & CSV Integration
   Supports Single & Multi-Page Physical Paper Dockets
   ═══════════════════════════════════════════════════════════════════════════ */

let lastExtractedDocketData = null;
let veronicaDocketPhotos = [];

/** Open the Docket Scanner Modal */
function openInvoiceScannerModal() {
  lastExtractedDocketData = null;
  veronicaDocketPhotos = [];
  
  const resultsWrap = document.getElementById('vScanResultsWrap');
  if (resultsWrap) resultsWrap.style.display = 'none';

  const progressWrap = document.getElementById('vScanProgressWrap');
  if (progressWrap) progressWrap.style.display = 'none';

  const btnApply = document.getElementById('btnApplyScannedInvoice');
  if (btnApply) btnApply.style.display = 'none';

  const btnDl = document.getElementById('btnDownloadScannedCsv');
  if (btnDl) btnDl.style.display = 'none';

  renderVeronicaPhotosList();
  openModal('invoiceScannerModal');
}

/** Handle photo or PDF selection (supports single or multiple pages/documents) */
async function handleVeronicaDocketPhoto(inputOrFiles) {
  let files = [];
  if (inputOrFiles instanceof HTMLInputElement) {
    if (!inputOrFiles.files || !inputOrFiles.files.length) return;
    files = Array.from(inputOrFiles.files);
    inputOrFiles.value = ''; // Reset so the same file can be re-selected if needed
  } else if (Array.isArray(inputOrFiles) || inputOrFiles instanceof FileList) {
    files = Array.from(inputOrFiles);
  } else if (inputOrFiles instanceof File) {
    files = [inputOrFiles];
  } else {
    return;
  }

  const progressWrap = document.getElementById('vScanProgressWrap');
  const progressText = document.getElementById('vScanProgressText');

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

        if (pdfResult.pages && pdfResult.pages.length) {
          pdfResult.pages.forEach(p => veronicaDocketPhotos.push(p.dataUrl));
          toast(`Extracted ${pdfResult.pages.length} page(s) from PDF!`, 'success');
        } else {
          toast('No renderable pages found in PDF.', 'warning');
        }
      } catch (err) {
        console.error('PDF parsing error:', err);
        toast('PDF extraction error: ' + err.message, 'error');
      } finally {
        if (progressWrap) progressWrap.style.display = 'none';
      }
    } else {
      // Process photo / image file
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

            veronicaDocketPhotos.push(dataUrl);
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

  renderVeronicaPhotosList();
}

/** Render thumbnail previews of all attached docket pages */
function renderVeronicaPhotosList() {
  const dropzone = document.getElementById('vScanDropzone');
  const previewWrap = document.getElementById('vScanPreviewWrap');
  const photoGrid = document.getElementById('vScanPhotoGrid');

  if (!veronicaDocketPhotos.length) {
    if (dropzone) dropzone.style.display = 'block';
    if (previewWrap) previewWrap.style.display = 'none';
    return;
  }

  if (dropzone) dropzone.style.display = 'none';
  if (previewWrap) previewWrap.style.display = 'block';

  if (photoGrid) {
    photoGrid.innerHTML = veronicaDocketPhotos.map((dataUrl, idx) => `
      <div style="position:relative; display:inline-block; margin:6px; border:1px solid var(--border); border-radius:8px; overflow:hidden; background:#fff; box-shadow:0 2px 6px rgba(0,0,0,0.08);">
        <img src="${dataUrl}" style="width:110px; height:130px; object-fit:cover; display:block;" alt="Docket Page ${idx + 1}">
        <div style="position:absolute; bottom:0; left:0; right:0; background:rgba(0,0,0,0.65); color:#fff; font-size:0.7rem; font-weight:700; text-align:center; padding:2px 0;">
          Page ${idx + 1}
        </div>
        <button type="button" onclick="removeVeronicaPhoto(${idx})" title="Remove page" style="position:absolute; top:3px; right:3px; background:var(--danger, #dc2626); color:#fff; border:none; border-radius:50%; width:20px; height:20px; cursor:pointer; display:flex; align-items:center; justify-content:center;">
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
        </button>
      </div>
    `).join('') + `
      <div style="display:inline-flex; flex-direction:column; gap:6px; vertical-align:top; margin:6px;">
        <button type="button" onclick="document.getElementById('veronicaCameraInput').click()" style="width:105px; height:38px; border:1px solid var(--green-300); border-radius:6px; background:var(--green-50); color:var(--green-900); font-size:0.72rem; font-weight:600; cursor:pointer; display:flex; align-items:center; justify-content:center; gap:4px;">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
          <span>+ Camera</span>
        </button>
        <button type="button" onclick="document.getElementById('veronicaGalleryInput').click()" style="width:105px; height:38px; border:1px solid var(--border); border-radius:6px; background:#fff; color:var(--text); font-size:0.72rem; font-weight:600; cursor:pointer; display:flex; align-items:center; justify-content:center; gap:4px;">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>
          <span>+ Gallery</span>
        </button>
        <button type="button" onclick="document.getElementById('veronicaPdfInput').click()" style="width:105px; height:38px; border:1px solid #93c5fd; border-radius:6px; background:#eff6ff; color:#1e40af; font-size:0.72rem; font-weight:600; cursor:pointer; display:flex; align-items:center; justify-content:center; gap:4px;">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line></svg>
          <span>+ PDF</span>
        </button>
      </div>
    `;
  }

  // Update OCR trigger button text
  const btnRun = document.getElementById('btnRunVeronicaOCR');
  if (btnRun) {
    btnRun.innerHTML = `
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:middle; margin-right:5px;">
        <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
      </svg>
      Auto-Extract from ${veronicaDocketPhotos.length} Page${veronicaDocketPhotos.length > 1 ? 's' : ''}
    `;
  }
}

/** Remove single page from queue */
function removeVeronicaPhoto(idx) {
  veronicaDocketPhotos.splice(idx, 1);
  renderVeronicaPhotosList();
}

/** Run OCR extraction across all attached pages */
async function runVeronicaOCR() {
  if (!veronicaDocketPhotos.length) return toast('Please attach at least one docket photo', 'warning');

  const progressWrap = document.getElementById('vScanProgressWrap');
  const progressText = document.getElementById('vScanProgressText');
  progressWrap.style.display = 'block';
  progressText.textContent = `Initializing analysis for ${veronicaDocketPhotos.length} page(s)...`;

  const btnRun = document.getElementById('btnRunVeronicaOCR');
  if (btnRun) btnRun.disabled = true;

  try {
    const result = await OCRConsensus.processDocket(veronicaDocketPhotos, (status) => {
      progressText.textContent = status;
    });

    lastExtractedDocketData = result;
    progressWrap.style.display = 'none';

    renderScannedDocketResults(result);
    toast(`Successfully extracted ${result.items.length} items across ${veronicaDocketPhotos.length} page(s)!`, 'success');

  } catch (err) {
    console.error('Docket OCR processing failed:', err);
    progressWrap.style.display = 'none';
    toast('Error processing docket: ' + err.message, 'error');
  } finally {
    if (btnRun) btnRun.disabled = false;
  }
}

/** Render extracted items in the scanner modal */
function renderScannedDocketResults(result) {
  const resultsWrap = document.getElementById('vScanResultsWrap');
  resultsWrap.style.display = 'block';

  document.getElementById('vScanConfidence').textContent = `${result.confidence}% Confidence (${result.enginesUsed.join(' + ')})`;
  document.getElementById('vScanItemsCount').textContent = `${result.items.length} items extracted`;

  const tbody = document.getElementById('vScanItemsBody');
  tbody.innerHTML = (result.items || []).map(it => `
    <tr>
      <td><strong>${escapeHtml(it.desc)}</strong></td>
      <td>${it.qty}</td>
      <td>${escapeHtml(it.unit)}</td>
      <td>KES ${fmtMoney(it.price || it.sellPrice || 0)}</td>
      <td style="text-align:right; font-weight:600;">KES ${fmtMoney(it.total)}</td>
    </tr>
  `).join('');

  document.getElementById('vScanSubtotalText').textContent = 'KES ' + fmtMoney(result.subtotal);

  const btnApply = document.getElementById('btnApplyScannedInvoice');
  if (btnApply) btnApply.style.display = 'inline-flex';

  const btnDownload = document.getElementById('btnDownloadScannedCsv');
  if (btnDownload) btnDownload.style.display = 'inline-flex';
}

/** Apply extracted docket items directly to Veronica's New Invoice form */
function applyExtractedItemsToInvoice() {
  if (!lastExtractedDocketData) return;

  const data = lastExtractedDocketData;

  // Auto-select restaurant if recognized
  if (data.restaurantName && typeof DB !== 'undefined') {
    const matched = (DB.restaurants || []).find(r => r.name.toLowerCase().includes(data.restaurantName.toLowerCase()));
    if (matched) {
      document.getElementById('invRestaurant').value = matched.id;
    }
  }

  // Set date
  if (data.date) {
    document.getElementById('invDate').value = data.date;
  }

  // Populate line items
  const tbody = document.getElementById('lineItemsBody');
  tbody.innerHTML = '';

  (data.items || []).forEach(it => {
    const row = document.createElement('tr');
    row.innerHTML = `
      <td><input type="text" class="item-desc" value="${escapeHtml(it.desc)}" placeholder="Produce item"></td>
      <td><input type="number" min="0" step="any" class="item-qty" value="${it.qty || 1}"></td>
      <td>
        <select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;">
          <option value="kgs" ${it.unit === 'kgs' || it.unit === 'kg' ? 'selected' : ''}>Kgs</option>
          <option value="crates" ${it.unit === 'crates' ? 'selected' : ''}>Crates</option>
          <option value="bags" ${it.unit === 'bags' ? 'selected' : ''}>Bags</option>
          <option value="pieces" ${it.unit === 'pieces' || it.unit === 'pcs' ? 'selected' : ''}>Pieces</option>
          <option value="bunches" ${it.unit === 'bunches' ? 'selected' : ''}>Bunches</option>
          <option value="heads" ${it.unit === 'heads' ? 'selected' : ''}>Heads</option>
          <option value="pnts" ${it.unit === 'pnts' || it.unit === 'punnets' ? 'selected' : ''}>Punnets</option>
          <option value="bundles" ${it.unit === 'bundles' ? 'selected' : ''}>Bundles</option>
          <option value="litres" ${it.unit === 'litres' ? 'selected' : ''}>Litres</option>
          <option value="trays" ${it.unit === 'trays' ? 'selected' : ''}>Trays</option>
          <option value="dozen" ${it.unit === 'dozen' ? 'selected' : ''}>Dozen</option>
        </select>
      </td>
      <td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy" value="${it.buyPrice || 0}"></td>
      <td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell" value="${it.sellPrice || it.price || 0}"></td>
      <td class="item-total" style="font-weight:600">${fmtMoney(it.total)}</td>
      <td>
        <button type="button" class="btn-remove-row" onclick="removeLineItem(this)">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>
      </td>
    `;
    tbody.appendChild(row);
    if (typeof attachLineListeners === 'function') attachLineListeners(row);
  });

  if (typeof calcInvoiceTotals === 'function') calcInvoiceTotals();

  closeModal('invoiceScannerModal');
  toast(`Applied ${data.items.length} items from docket into invoice form!`, 'success');
}

// Aliases for compatibility
function applyScannedDocketToInvoice() {
  applyExtractedItemsToInvoice();
}

function exportCurrentScannedDocketToCsv() {
  downloadScannedCsv();
}

/** Download extracted items as CSV */
function downloadScannedCsv() {
  if (!lastExtractedDocketData || !lastExtractedDocketData.items) return;
  OCRConsensus.downloadCSV(lastExtractedDocketData.items, `docket_${lastExtractedDocketData.date || 'extracted'}.csv`);
  toast('CSV file downloaded successfully');
}

/** Export current invoice form line items as CSV */
function exportCurrentInvoiceCsv() {
  const items = [];
  document.querySelectorAll('#lineItemsBody tr').forEach(row => {
    const desc = row.querySelector('.item-desc')?.value?.trim();
    const qty = parseFloat(row.querySelector('.item-qty')?.value) || 0;
    const unit = row.querySelector('.item-unit')?.value || 'kgs';
    const buy = parseFloat(row.querySelector('.item-buy')?.value) || 0;
    const sell = parseFloat(row.querySelector('.item-sell')?.value) || 0;
    if (desc) {
      items.push({ desc, qty, unit, buyPrice: buy, sellPrice: sell, total: qty * sell });
    }
  });

  if (!items.length) {
    return toast('No line items to export', 'warning');
  }

  const invDate = document.getElementById('invDate')?.value || new Date().toISOString().slice(0, 10);
  OCRConsensus.downloadCSV(items, `invoice_items_${invDate}.csv`);
  toast('Invoice line items exported to CSV');
}

/** Open CSV Import Modal */
function openCsvImportModal() {
  document.getElementById('csvImportText').value = '';
  document.getElementById('csvFileInput').value = '';
  openModal('csvImportModal');
}

/** Handle CSV file upload */
function handleCsvFileUpload(input) {
  const file = input.files[0];
  if (!file) return;

  const reader = new FileReader();
  reader.onload = (e) => {
    document.getElementById('csvImportText').value = e.target.result;
  };
  reader.readAsText(file);
}

/** Parse and apply CSV text into the Line Items table */
function applyCsvTextToInvoice() {
  const text = document.getElementById('csvImportText').value.trim();
  if (!text) return toast('Please upload a CSV file or paste CSV text', 'error');

  const items = OCRConsensus.csvToItems(text);
  if (!items.length) return toast('No valid line items found in CSV', 'error');

  const tbody = document.getElementById('lineItemsBody');
  tbody.innerHTML = '';

  items.forEach(it => {
    const row = document.createElement('tr');
    row.innerHTML = `
      <td><input type="text" class="item-desc" value="${escapeHtml(it.desc)}" placeholder="Produce item"></td>
      <td><input type="number" min="0" step="any" class="item-qty" value="${it.qty || 1}"></td>
      <td>
        <select class="item-unit form-control" style="padding:6px 4px;font-size:0.8rem;">
          <option value="kgs" ${it.unit === 'kgs' || it.unit === 'kg' ? 'selected' : ''}>Kgs</option>
          <option value="crates" ${it.unit === 'crates' ? 'selected' : ''}>Crates</option>
          <option value="bags" ${it.unit === 'bags' ? 'selected' : ''}>Bags</option>
          <option value="pieces" ${it.unit === 'pieces' || it.unit === 'pcs' ? 'selected' : ''}>Pieces</option>
          <option value="bunches" ${it.unit === 'bunches' ? 'selected' : ''}>Bunches</option>
          <option value="heads" ${it.unit === 'heads' ? 'selected' : ''}>Heads</option>
          <option value="pnts" ${it.unit === 'pnts' || it.unit === 'punnets' ? 'selected' : ''}>Punnets</option>
          <option value="bundles" ${it.unit === 'bundles' ? 'selected' : ''}>Bundles</option>
          <option value="litres" ${it.unit === 'litres' ? 'selected' : ''}>Litres</option>
          <option value="trays" ${it.unit === 'trays' ? 'selected' : ''}>Trays</option>
          <option value="dozen" ${it.unit === 'dozen' ? 'selected' : ''}>Dozen</option>
        </select>
      </td>
      <td><input type="number" min="0" step="any" placeholder="0.00" class="item-buy" value="${it.buyPrice || 0}"></td>
      <td><input type="number" min="0" step="any" placeholder="0.00" class="item-sell" value="${it.sellPrice || 0}"></td>
      <td class="item-total" style="font-weight:600">${fmtMoney(it.total)}</td>
      <td>
        <button type="button" class="btn-remove-row" onclick="removeLineItem(this)">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>
      </td>
    `;
    tbody.appendChild(row);
    if (typeof attachLineListeners === 'function') attachLineListeners(row);
  });

  if (typeof calcInvoiceTotals === 'function') calcInvoiceTotals();

  closeModal('csvImportModal');
  toast(`Imported ${items.length} line items from CSV into invoice!`, 'success');
}

// Setup Drag & Drop for Veronica Docket Dropzone
if (typeof document !== 'undefined') {
  function initVeronicaDropzone() {
    const dropzone = document.getElementById('vScanDropzone');
    if (!dropzone) return;

    ['dragenter', 'dragover'].forEach(eventName => {
      dropzone.addEventListener(eventName, (e) => {
        e.preventDefault();
        e.stopPropagation();
        dropzone.style.borderColor = 'var(--primary)';
        dropzone.style.background = '#dcfce7';
      }, false);
    });

    ['dragleave', 'drop'].forEach(eventName => {
      dropzone.addEventListener(eventName, (e) => {
        e.preventDefault();
        e.stopPropagation();
        dropzone.style.borderColor = 'var(--green-300)';
        dropzone.style.background = 'var(--green-50)';
      }, false);
    });

    dropzone.addEventListener('drop', (e) => {
      const dt = e.dataTransfer;
      if (dt && dt.files && dt.files.length) {
        handleVeronicaDocketPhoto(dt.files);
      }
    }, false);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initVeronicaDropzone);
  } else {
    initVeronicaDropzone();
  }
}
