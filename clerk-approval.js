/* ═══════════════════════════════════════════════════════════════════════════
   Town Treasure Groceries — Clerk Approval & Review UI
   Executive Review interface for Veronica to inspect, adjust, and approve
   dockets submitted by clerks before committing to her encrypted ledger.
   ═══════════════════════════════════════════════════════════════════════════ */

let currentClerkTab = 'pending';
let activeReviewSubmissionId = null;

/** Render the Clerk Submissions page */
async function renderClerkSubmissionsPage() {
  const tbody = document.getElementById('clerkSubmissionsBody');
  if (!tbody) return;

  tbody.innerHTML = `<tr><td colspan="8" class="empty-state">Loading clerk submissions...</td></tr>`;

  try {
    const all = await StagingDB.getAllSubmissions();
    const filtered = all.filter(item => {
      if (currentClerkTab === 'pending') return item.status === 'pending';
      if (currentClerkTab === 'approved') return item.status === 'approved';
      if (currentClerkTab === 'rejected') return item.status === 'rejected';
      return true;
    });

    // Update pending badge count
    const pendingCount = all.filter(i => i.status === 'pending').length;
    const tabPendingCount = document.getElementById('clerkTabPendingCount');
    if (tabPendingCount) tabPendingCount.textContent = pendingCount;

    if (!filtered.length) {
      let emptyMsg = 'No pending clerk submissions.';
      if (currentClerkTab === 'approved') emptyMsg = 'No approved submissions in history yet.';
      if (currentClerkTab === 'rejected') emptyMsg = 'No rejected submissions.';

      tbody.innerHTML = `
        <tr>
          <td colspan="8" class="empty-state" style="padding:48px 20px;">
            <div style="color:var(--text-3); margin-bottom:12px;">
              <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M22 12h-6l-2 3h-4l-2-3H2"></path>
                <path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
              </svg>
            </div>
            <h3 style="margin-bottom:6px; color:var(--text); font-size:1.1rem;">${emptyMsg}</h3>
            <p style="color:var(--text-2); font-size:0.85rem; max-width:500px; margin:0 auto 16px;">
              When clerks or assistants enter or scan dockets at clerk.html, they appear here awaiting your review and encrypted approval.
            </p>
            <div style="display:flex; justify-content:center; gap:10px; flex-wrap:wrap;">
              <a href="clerk.html" target="_blank" class="btn btn-sm btn-primary" style="text-decoration:none; display:inline-flex; align-items:center; gap:6px;">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
                  <polyline points="15 3 21 3 21 9"></polyline>
                  <line x1="10" y1="14" x2="21" y2="3"></line>
                </svg>
                Open Clerk Intake Portal
              </a>
              <button class="btn btn-sm btn-secondary" onclick="seedSampleClerkDockets()" style="display:inline-flex; align-items:center; gap:6px;">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                  <polyline points="7 10 12 15 17 10"></polyline>
                  <line x1="12" y1="15" x2="12" y2="3"></line>
                </svg>
                Load Demo Dockets
              </button>
              <button class="btn btn-sm btn-secondary" onclick="openImportDocketModal()" style="display:inline-flex; align-items:center; gap:6px;">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
                  <polyline points="14 2 14 8 20 8"></polyline>
                  <line x1="12" y1="18" x2="12" y2="12"></line>
                  <line x1="9" y1="15" x2="15" y2="15"></line>
                </svg>
                Import Docket Code
              </button>
            </div>
          </td>
        </tr>
      `;
      return;
    }

    tbody.innerHTML = filtered.map(item => {
      const itemsCount = (item.items_json || []).length;
      const totalSellFmt = typeof fmtMoney === 'function' ? fmtMoney(item.total_sell) : Number(item.total_sell || 0).toLocaleString();
      
      let statusBadge = '';
      if (item.status === 'pending') {
        statusBadge = `
          <span class="badge" style="background:#fef3c7; color:#b45309; font-weight:600; padding:4px 8px; border-radius:6px; display:inline-flex; align-items:center; gap:4px;">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
            Pending Review
          </span>`;
      } else if (item.status === 'approved') {
        statusBadge = `
          <span class="badge" style="background:#ecfdf5; color:#047857; font-weight:600; padding:4px 8px; border-radius:6px; display:inline-flex; align-items:center; gap:4px;">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg>
            Approved
          </span>`;
      } else {
        statusBadge = `
          <span class="badge" style="background:#fef2f2; color:#b91c1c; font-weight:600; padding:4px 8px; border-radius:6px; display:inline-flex; align-items:center; gap:4px;">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="15" y1="9" x2="9" y2="15"></line><line x1="9" y1="9" x2="15" y2="15"></line></svg>
            Returned
          </span>`;
      }

      const photos = Array.isArray(item.receipt_photos) && item.receipt_photos.length 
        ? item.receipt_photos 
        : (item.receipt_photo ? [item.receipt_photo] : []);
      const pageCount = photos.length;

      const photoThumb = photos[0] 
        ? `<div style="position:relative; display:inline-block;">
             <img src="${photos[0]}" style="width:48px; height:48px; object-fit:cover; border-radius:6px; border:1px solid var(--border); cursor:pointer;" onclick="openPhotoZoom('${item.id}')" title="Click to view full docket note">
             ${pageCount > 1 ? `<span style="position:absolute; bottom:-3px; right:-3px; background:var(--primary); color:#fff; font-size:9px; font-weight:700; border-radius:10px; padding:1px 5px; line-height:1.2; box-shadow:0 1px 3px rgba(0,0,0,0.3);">${pageCount}P</span>` : ''}
           </div>`
        : `<span style="display:inline-flex; align-items:center; justify-content:center; width:48px; height:48px; background:var(--gray-100); border-radius:6px; color:var(--text-3);"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline></svg></span>`;

      let actionBtns = '';
      if (item.status === 'pending') {
        actionBtns = `
          <button class="btn btn-sm btn-primary" onclick="openClerkReviewModal('${item.id}')" style="font-weight:600; display:inline-flex; align-items:center; gap:5px;">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
              <circle cx="12" cy="12" r="3"></circle>
            </svg>
            Review &amp; Approve
          </button>
        `;
      } else {
        actionBtns = `
          <button class="btn btn-sm btn-secondary" onclick="openClerkReviewModal('${item.id}')">
            View Details
          </button>
        `;
      }

      return `
        <tr>
          <td>${photoThumb}</td>
          <td><strong>${escapeHtml(item.invoice_date || '—')}</strong></td>
          <td><strong>${escapeHtml(item.restaurant_name || 'General Wholesale')}</strong></td>
          <td><span style="color:var(--text-2);">${escapeHtml(item.clerk_name || 'Clerk')}</span></td>
          <td>${itemsCount} item${itemsCount !== 1 ? 's' : ''}</td>
          <td><strong>KES ${totalSellFmt}</strong></td>
          <td>${statusBadge}</td>
          <td>${actionBtns}</td>
        </tr>
      `;
    }).join('');

  } catch (err) {
    console.error('Error rendering clerk submissions:', err);
    tbody.innerHTML = `<tr><td colspan="8" class="empty-state" style="color:var(--danger)">Error loading submissions: ${err.message}</td></tr>`;
  }
}

/** Switch tabs between Pending, Approved, and Rejected */
function switchClerkTab(tab, btn) {
  currentClerkTab = tab;
  document.querySelectorAll('#page-clerk-submissions .tab-btn').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');
  renderClerkSubmissionsPage();
}

/** Helper to seed sample clerk dockets on demand */
function seedSampleClerkDockets() {
  StagingDB.seedDemoDockets(true);
  toast('Demo clerk dockets loaded successfully!', 'success');
  renderClerkSubmissionsPage();
}

/** Open modal to import a docket code or file */
function openImportDocketModal() {
  const code = prompt('Paste docket code or JSON submitted by clerk:');
  if (!code || !code.trim()) return;

  StagingDB.importDocketFromCode(code.trim())
    .then(record => {
      toast(`Imported docket for ${record.restaurant_name} into staging queue!`, 'success');
      renderClerkSubmissionsPage();
    })
    .catch(err => {
      toast('Import failed: ' + err.message, 'error');
    });
}

/** Open the Side-by-Side Review & Approval Modal */
async function openClerkReviewModal(id) {
  activeReviewSubmissionId = id;
  const all = await StagingDB.getAllSubmissions();
  const item = all.find(x => x.id === id);
  if (!item) return toast('Submission not found', 'error');

  // Fill in basic details
  document.getElementById('crmClerkName').textContent = item.clerk_name || 'Assistant';
  document.getElementById('crmSubmittedAt').textContent = new Date(item.created_at).toLocaleString();
  document.getElementById('crmRestaurantName').value = item.restaurant_name || '';
  document.getElementById('crmInvoiceDate').value = item.invoice_date || new Date().toISOString().slice(0, 10);
  document.getElementById('crmDeliveryCost').value = item.delivery_cost || 0;
  document.getElementById('crmOtherCost').value = item.other_cost || 0;
  document.getElementById('crmClerkNotes').textContent = item.notes ? `"${item.notes}"` : 'No notes provided by clerk.';

  // Photos & Multi-page switcher
  const photoContainer = document.getElementById('crmPhotoContainer');
  const photos = Array.isArray(item.receipt_photos) && item.receipt_photos.length 
    ? item.receipt_photos 
    : (item.receipt_photo ? [item.receipt_photo] : []);

  if (photos.length > 0) {
    let activeIdx = 0;
    
    const renderPhotoView = (idx) => {
      activeIdx = idx;
      let tabsHtml = '';
      if (photos.length > 1) {
        tabsHtml = `
          <div style="display:flex; justify-content:center; gap:6px; margin-bottom:10px;">
            ${photos.map((p, i) => `
              <button type="button" class="btn btn-sm ${i === activeIdx ? 'btn-primary' : 'btn-secondary'}" onclick="switchCrmReviewPhoto(${i})" style="font-size:0.78rem; font-weight:600; padding:3px 12px; border-radius:16px;">
                Page ${i + 1}
              </button>
            `).join('')}
          </div>
        `;
      }

      photoContainer.innerHTML = `
        ${tabsHtml}
        <div style="position:relative; width:100%; display:flex; justify-content:center;">
          <img id="crmZoomablePhoto" src="${photos[activeIdx]}" style="max-width:100%; max-height:480px; object-fit:contain; border-radius:8px; border:1px solid var(--border); box-shadow:0 2px 8px rgba(0,0,0,0.1); cursor:zoom-in;" onclick="togglePhotoZoom(this)" title="Click to zoom">
        </div>
        <div style="margin-top:8px; font-size:0.75rem; color:var(--text-3); text-align:center;">
          ${photos.length > 1 ? `Showing Page ${activeIdx + 1} of ${photos.length}. ` : ''}Click docket image to toggle zoom
        </div>
      `;
    };

    window.switchCrmReviewPhoto = (newIdx) => {
      renderPhotoView(newIdx);
    };

    renderPhotoView(0);
  } else {
    photoContainer.innerHTML = `
      <div style="padding:40px 20px; text-align:center; background:var(--gray-100); border-radius:8px; color:var(--text-2);">
        <div style="color:var(--text-3); margin-bottom:8px;">
          <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
            <polyline points="14 2 14 8 20 8"></polyline>
          </svg>
        </div>
        No physical receipt photo was attached to this docket.
      </div>
    `;
  }

  // Populate line items table
  const tbody = document.getElementById('crmLineItemsBody');
  tbody.innerHTML = '';
  const items = item.items_json || [];

  if (!items.length) {
    addCrmLineItem('Produce Item', 1, 'kgs', 0, 0);
  } else {
    items.forEach(it => {
      addCrmLineItem(
        it.desc || it.name || '',
        it.qty || 1,
        it.unit || 'kgs',
        it.buyPrice || it.buy || 0,
        it.sellPrice || it.sell || it.price || 0
      );
    });
  }

  calcCrmTotals();

  // Button visibility based on status
  const approveBtn = document.getElementById('btnCrmApprove');
  const rejectBtn = document.getElementById('btnCrmReject');
  if (item.status === 'pending') {
    approveBtn.style.display = 'inline-flex';
    rejectBtn.style.display = 'inline-flex';
  } else {
    approveBtn.style.display = 'none';
    rejectBtn.style.display = 'none';
  }

  openModal('clerkReviewModal');
}

/** Add a line item row to the review modal */
function addCrmLineItem(desc = '', qty = 1, unit = 'kgs', buy = 0, sell = 0) {
  const tbody = document.getElementById('crmLineItemsBody');
  const tr = document.createElement('tr');
  tr.innerHTML = `
    <td><input type="text" class="form-control crm-item-desc" value="${escapeHtml(desc)}" placeholder="e.g. Tomatoes" style="padding:6px 8px; font-size:0.85rem;"></td>
    <td><input type="number" step="any" min="0" class="form-control crm-item-qty" value="${qty}" style="width:70px; padding:6px 8px; font-size:0.85rem;" oninput="calcCrmTotals()"></td>
    <td>
      <select class="form-control crm-item-unit" style="padding:6px 4px; font-size:0.85rem;">
        <option value="kgs" ${unit==='kgs'?'selected':''}>Kgs</option>
        <option value="crates" ${unit==='crates'?'selected':''}>Crates</option>
        <option value="bags" ${unit==='bags'?'selected':''}>Bags</option>
        <option value="pieces" ${unit==='pieces'?'selected':''}>Pieces</option>
        <option value="bundles" ${unit==='bundles'?'selected':''}>Bundles</option>
        <option value="litres" ${unit==='litres'?'selected':''}>Litres</option>
        <option value="trays" ${unit==='trays'?'selected':''}>Trays</option>
        <option value="dozen" ${unit==='dozen'?'selected':''}>Dozen</option>
      </select>
    </td>
    <td><input type="number" step="any" min="0" class="form-control crm-item-buy" value="${buy}" placeholder="0.00" style="width:85px; padding:6px 8px; font-size:0.85rem;" oninput="calcCrmTotals()"></td>
    <td><input type="number" step="any" min="0" class="form-control crm-item-sell" value="${sell}" placeholder="0.00" style="width:85px; padding:6px 8px; font-size:0.85rem;" oninput="calcCrmTotals()"></td>
    <td class="crm-item-total" style="font-weight:600; text-align:right; font-size:0.85rem; padding-right:8px;">0.00</td>
    <td>
      <button type="button" class="btn-remove-row" onclick="removeCrmLineItem(this)" style="background:none; border:none; color:var(--text-3); cursor:pointer;">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
    </td>
  `;
  tbody.appendChild(tr);
}

function removeCrmLineItem(btn) {
  const tbody = document.getElementById('crmLineItemsBody');
  if (tbody.rows.length <= 1) return;
  btn.closest('tr').remove();
  calcCrmTotals();
}

/** Recalculate totals in the review modal */
function calcCrmTotals() {
  let sell = 0, buy = 0;
  document.querySelectorAll('#crmLineItemsBody tr').forEach(row => {
    const q = parseFloat(row.querySelector('.crm-item-qty')?.value) || 0;
    const s = parseFloat(row.querySelector('.crm-item-sell')?.value) || 0;
    const b = parseFloat(row.querySelector('.crm-item-buy')?.value) || 0;
    const t = q * s;
    const totalCell = row.querySelector('.crm-item-total');
    if (totalCell) totalCell.textContent = typeof fmtMoney === 'function' ? fmtMoney(t) : t.toFixed(2);
    sell += t;
    buy += (q * b);
  });

  const deliveryCost = parseFloat(document.getElementById('crmDeliveryCost')?.value) || 0;
  const otherCost = parseFloat(document.getElementById('crmOtherCost')?.value) || 0;
  const profit = sell - buy - deliveryCost - otherCost;

  const fmt = val => typeof fmtMoney === 'function' ? fmtMoney(val) : val.toLocaleString();

  const elSubtotal = document.getElementById('crmSubtotal');
  const elCost = document.getElementById('crmCost');
  const elProfit = document.getElementById('crmProfit');

  if (elSubtotal) elSubtotal.textContent = 'KES ' + fmt(sell);
  if (elCost) elCost.textContent = 'KES ' + fmt(buy + deliveryCost + otherCost);
  if (elProfit) {
    elProfit.textContent = 'KES ' + fmt(profit);
    elProfit.style.color = profit >= 0 ? 'var(--primary)' : 'var(--danger)';
  }
}

/** Toggle full-size zoom on the receipt photo */
function togglePhotoZoom(img) {
  if (img.classList.contains('zoomed')) {
    img.classList.remove('zoomed');
    img.style.maxHeight = '480px';
    img.style.cursor = 'zoom-in';
  } else {
    img.classList.add('zoomed');
    img.style.maxHeight = 'none';
    img.style.cursor = 'zoom-out';
  }
}

/** Quick photo zoom modal popup */
async function openPhotoZoom(id) {
  const all = await StagingDB.getAllSubmissions();
  const item = all.find(x => x.id === id);
  if (!item || (!item.receipt_photo && (!item.receipt_photos || !item.receipt_photos.length))) return;
  openClerkReviewModal(id);
}

/** Execute Approval: Commit to Veronica's encrypted vault! */
async function executeClerkApproval() {
  if (!activeReviewSubmissionId) return;

  const restName = document.getElementById('crmRestaurantName').value.trim();
  if (!restName) return toast('Restaurant Name is required', 'error');

  const items = [];
  let valid = true;
  document.querySelectorAll('#crmLineItemsBody tr').forEach(row => {
    const desc = row.querySelector('.crm-item-desc').value.trim();
    const qty = parseFloat(row.querySelector('.crm-item-qty').value) || 0;
    const unit = row.querySelector('.crm-item-unit').value || 'kgs';
    const buyPrice = parseFloat(row.querySelector('.crm-item-buy').value) || 0;
    const sellPrice = parseFloat(row.querySelector('.crm-item-sell').value) || 0;

    if (!desc) { valid = false; return; }
    items.push({ desc, qty, unit, buyPrice, sellPrice, total: qty * sellPrice });
  });

  if (!valid || !items.length) {
    return toast('Please fill in descriptions for all line items', 'error');
  }

  const btnApprove = document.getElementById('btnCrmApprove');
  btnApprove.disabled = true;
  btnApprove.textContent = 'Encrypting & Saving...';

  try {
    const adjustedData = {
      restaurantName: restName,
      date: document.getElementById('crmInvoiceDate').value || new Date().toISOString().slice(0, 10),
      deliveryCost: parseFloat(document.getElementById('crmDeliveryCost').value) || 0,
      otherCost: parseFloat(document.getElementById('crmOtherCost').value) || 0,
      items: items
    };

    const newInvoice = await StagingDB.approveSubmission(activeReviewSubmissionId, adjustedData);

    closeModal('clerkReviewModal');
    toast(`Invoice ${newInvoice.number} approved and encrypted into your private vault!`, 'success');

    // Re-render UI
    if (typeof renderInvoicesList === 'function') renderInvoicesList();
    if (typeof refreshDashboard === 'function') refreshDashboard();
    if (typeof renderClerkSubmissionsPage === 'function') renderClerkSubmissionsPage();
    if (typeof populateRestaurantDropdowns === 'function') populateRestaurantDropdowns();

  } catch (err) {
    console.error('Approval failed:', err);
    toast('Error approving docket: ' + err.message, 'error');
  } finally {
    btnApprove.disabled = false;
    btnApprove.innerHTML = `
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:middle; margin-right:5px;">
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"></path>
      </svg>
      Approve &amp; Encrypt into Vault
    `;
  }
}

/** Reject / Return to Clerk */
function executeClerkRejection() {
  if (!activeReviewSubmissionId) return;

  const reason = prompt('Reason for returning this docket to the clerk (optional):', 'Please verify quantities on the receipt');
  if (reason === null) return; // User cancelled prompt

  StagingDB.rejectSubmission(activeReviewSubmissionId, reason)
    .then(() => {
      closeModal('clerkReviewModal');
      toast('Docket marked as rejected and returned to clerk queue.', 'warning');
      renderClerkSubmissionsPage();
    })
    .catch(err => toast('Error rejecting: ' + err.message, 'error'));
}

/** Helper to build a personalized, targeted Clerk Portal URL for the active account */
async function getClerkPortalShareUrl() {
  let user = null;
  if (typeof getCurrentUser === 'function') {
    try { user = await getCurrentUser(); } catch(e) {}
  }
  const uid = user ? user.id : (localStorage.getItem('ttg_user_id') || '');
  const email = user ? (user.email || '') : (localStorage.getItem('ttg_user_email') || '');
  const name = user?.user_metadata?.full_name || (email ? email.split('@')[0] : 'Veronica');
  
  const baseUrl = window.location.origin + window.location.pathname.replace(/[^\/]*$/, 'clerk.html');
  const params = new URLSearchParams();
  if (uid) params.set('to', uid);
  if (name) params.set('name', name);
  if (email) params.set('email', email);
  
  const query = params.toString();
  return query ? `${baseUrl}?${query}` : baseUrl;
}

/** Copy personalized Clerk Portal direct URL to clipboard */
async function copyClerkPortalLink() {
  const url = await getClerkPortalShareUrl();
  const ident = typeof StagingDB !== 'undefined' ? StagingDB.getCurrentUserIdentifier() : {};
  const targetLabel = ident.email || 'Veronica';
  
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(url).then(() => {
      toast(`Clerk Portal link copied! Linked directly to your account (${targetLabel}).`, 'success');
    }).catch(() => {
      prompt(`Copy this Clerk Portal link (routed to ${targetLabel}):`, url);
    });
  } else {
    prompt(`Copy this Clerk Portal link (routed to ${targetLabel}):`, url);
  }
}

/** Share personalized Clerk Portal URL directly via WhatsApp */
async function shareClerkPortalWhatsApp() {
  const url = await getClerkPortalShareUrl();
  const ident = typeof StagingDB !== 'undefined' ? StagingDB.getCurrentUserIdentifier() : {};
  const name = ident.email ? ident.email.split('@')[0] : 'Veronica';
  const text = `Hi! Here is your Town Treasure Groceries Clerk Portal link to submit produce dockets directly for ${name}'s review and approval:\n\n${url}`;
  const waUrl = `https://api.whatsapp.com/send?text=${encodeURIComponent(text)}`;
  window.open(waUrl, '_blank');
}

/** Check for incoming shared docket code in URL parameters */
async function checkUrlImportDocket() {
  if (typeof window === 'undefined') return;
  const params = new URLSearchParams(window.location.search);
  const code = params.get('import_docket') || params.get('docket_code');
  if (!code) return;

  // Clear parameter from URL so browser refresh doesn't re-import
  try {
    const cleanUrl = window.location.pathname + window.location.hash;
    window.history.replaceState({}, document.title, cleanUrl);
  } catch(e) {}

  try {
    if (typeof StagingDB !== 'undefined' && typeof StagingDB.importDocketFromCode === 'function') {
      const imported = await StagingDB.importDocketFromCode(code);
      toast(`Imported docket from ${imported.clerk_name} (${imported.restaurant_name})!`, 'success');
      if (typeof navigateTo === 'function') navigateTo('clerk-submissions');
      if (typeof renderClerkSubmissionsPage === 'function') renderClerkSubmissionsPage();
      if (typeof openClerkReviewModal === 'function') openClerkReviewModal(imported.id);
    }
  } catch(err) {
    console.error('Error importing docket from URL:', err);
    toast('Error importing shared docket: ' + err.message, 'error');
  }
}

// Check on startup
if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => setTimeout(checkUrlImportDocket, 600));
  } else {
    setTimeout(checkUrlImportDocket, 600);
  }
}
