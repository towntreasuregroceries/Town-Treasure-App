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

    <div style="height: 180px;"></div>

    <div class="invoice-footer-shape">
      <div style="position:absolute;bottom:20px;left:0;right:0;display:flex;justify-content:space-between;padding:0 50px;color:white;z-index:5;">
        <div style="font-style:italic;font-size:0.9rem;">Thank you for your business, ${rest.name}!</div>
        <div style="font-size:0.8rem;">Account Statement — ${monthName}</div>
      </div>
    </div>
    <div class="watermark-overlay" style="z-index:1;"><img src="assets/logo.png" alt="Stamp" class="watermark-stamp"><div class="watermark-text">Town Treasure Limited</div></div>
    
    <!-- Official Stamp -->
    <div class="official-stamp" style="position:absolute; right:60px; bottom:80px; width:220px; border:3px solid rgba(20,20,20,0.85); border-radius:10px; padding:10px; text-align:center; transform:rotate(-4deg); z-index:10; background:transparent; mix-blend-mode:multiply; box-shadow:none;">
      <img src="assets/stamp.png" style="max-width: 140px; max-height: 50px; object-fit: contain; filter: grayscale(100%); mix-blend-mode: multiply; margin-bottom: 5px;">
      <div style="font-size:1.1rem; font-weight:900; color:#000000; letter-spacing:1px; margin-bottom:5px;">ACCOUNT VERIFIED</div>
      <div style="font-size:0.7rem; color:#dc2626; font-family:monospace;">DATE: ${fmtDate(new Date().toISOString().slice(0,10))}</div>
      ${(DB.settings && DB.settings.signature) ? `<img src="${DB.settings.signature}" style="max-width:200px; max-height:80px; margin-top:5px; display:inline-block; mix-blend-mode:multiply;">` : `<div style="height:40px; margin-top:5px; border-bottom:1px solid #000000; width:80%; margin:5px auto 0 auto; line-height:50px; font-size:0.6rem; color:#000000;">Sign Here</div>`}
    </div>
  </div>`;
}

async function downloadStatementPDF() {
  const restId = document.getElementById('stmtRestaurant')?.value;
  const month = document.getElementById('stmtMonth')?.value;
  if (!restId || !month) return toast('Select a restaurant and month first', 'error');
  
  if (restId === '__all__') {
    toast('Batch PDF generation requires individual processing. Generating for first restaurant...', 'info');
    // For simplicity, handle just one or alert.
    return toast('Please select a specific restaurant to generate PDF.', 'warning');
  }

  const rest = DB.restaurants.find(r => r.id === restId);
  if (!rest) return;

  if (!window.jspdf) {
    toast('PDF generator is still loading. Please try again.', 'warning');
    return;
  }

  toast('Generating Statement PDF...', 'info');

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

  const getSvgIcon = (type) => {
    let svg = '';
    if (type === 'phone') svg = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg>';
    if (type === 'email') svg = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"></path><polyline points="22,6 12,13 2,6"></polyline></svg>';
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  };

  try {
    let logoData = null;
    let logoWidth = 0, logoHeight = 0;
    try {
      logoData = await loadImage('assets/logo.png');
      const imgProps = doc.getImageProperties(logoData);
      logoHeight = 55;
      logoWidth = (imgProps.width * logoHeight) / imgProps.height;
    } catch (e) { console.warn("Could not load logo", e); }

    const phoneIcon = await loadImage(getSvgIcon('phone'));
    const emailIcon = await loadImage(getSvgIcon('email'));

    const drawHeaderShapes = (isFirstPage) => {
      doc.setFillColor(97, 177, 70); 
      doc.rect(0, 0, a4Width, 110, 'F');
      doc.setFillColor(49, 58, 67); 
      doc.ellipse(a4Width, -158, 500, 258, 'F');
      if (logoData) doc.addImage(logoData, 'PNG', 40, 25, logoWidth, logoHeight);

      // Watermark
      doc.saveGraphicsState();
      doc.setGState(new doc.GState({ opacity: 0.06 }));
      doc.setTextColor(180, 180, 180);
      doc.setFontSize(45);
      doc.setFont("helvetica", "bold");
      doc.text("Town Treasure Limited", 100, 550, { angle: 30 });
      doc.restoreGraphicsState();
    };

    drawHeaderShapes(true);

    const [yr, mo] = month.split('-').map(Number);
    const monthName = new Date(yr, mo - 1, 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    const monthStart = `${month}-01`;
    const monthEnd = new Date(yr, mo, 0).toISOString().slice(0, 10);
    
    // --- Title Row ---
    doc.setFont("helvetica", "bold");
    doc.setFontSize(26);
    doc.setTextColor('#61b146');
    doc.text("MONTHLY", 40, 150);
    doc.text("STATEMENT", 40, 180);

    doc.setFontSize(10);
    doc.setTextColor('#424242');
    doc.text("Period:", 480, 150, { align: "right" });
    doc.setFont("helvetica", "normal");
    doc.setTextColor('#616161');
    doc.text(monthName, 555, 150, { align: "right" });
    
    doc.setFont("helvetica", "bold");
    doc.setTextColor('#424242');
    doc.text("Generated:", 480, 165, { align: "right" });
    doc.setFont("helvetica", "normal");
    doc.setTextColor('#616161');
    doc.text(fmtDate(new Date().toISOString().slice(0, 10)), 555, 165, { align: "right" });

    // --- Addresses ---
    let startY = 220;
    doc.setFontSize(10);
    doc.setFont("helvetica", "bold");
    doc.setTextColor('#424242');
    doc.text("FROM:", 40, startY);
    doc.text("TO:", 555, startY, { align: "right" });
    
    doc.setFontSize(11);
    doc.setTextColor('#61b146');
    doc.text("Town Treasure Limited", 40, startY + 18);
    
    doc.setTextColor('#424242');
    doc.text(rest.name, 555, startY + 18, { align: "right" });

    doc.setFontSize(10);
    doc.setFont("helvetica", "normal");
    doc.setTextColor('#616161');
    
    if (phoneIcon) doc.addImage(phoneIcon, 'PNG', 40, startY + 26, 10, 10);
    doc.text("0708567696", 55, startY + 34);
    
    if (emailIcon) doc.addImage(emailIcon, 'PNG', 40, startY + 41, 10, 10);
    doc.text("towntreasuregroceries@gmail.com", 55, startY + 49);

    if (rest.address) doc.text(rest.address, 555, startY + 34, { align: "right" });
    if (rest.phone) doc.text(rest.phone, 555, startY + 49, { align: "right" });

    // --- Data Processing ---
    const allInvoices = DB.invoices.filter(i => i.restaurantId === rest.id && i.status !== 'draft');
    const priorInvoices = allInvoices.filter(i => i.date < monthStart);
    const priorPaidTotal = priorInvoices.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);
    const priorInvoicedTotal = priorInvoices.reduce((s, i) => s + i.totalSell, 0);
    const openingBalance = priorInvoicedTotal - priorPaidTotal;

    const monthInvoices = allInvoices.filter(i => i.date >= monthStart && i.date <= monthEnd);
    const monthInvoicedTotal = monthInvoices.reduce((s, i) => s + i.totalSell, 0);
    const monthPaidTotal = monthInvoices.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);

    let runningBalance = openingBalance;
    const transactions = [];

    monthInvoices.sort((a, b) => a.date.localeCompare(b.date)).forEach(inv => {
      runningBalance += inv.totalSell;
      transactions.push([
        fmtDate(inv.date),
        `Invoice ${inv.number}`,
        `${inv.items.length} items`,
        `KES ${fmtMoney(inv.totalSell)}`,
        '',
        `KES ${fmtMoney(runningBalance)}`
      ]);

      if (inv.status === 'paid') {
        runningBalance -= inv.totalSell;
        transactions.push([
          fmtDate(inv.date),
          `Payment — ${inv.number}`,
          '',
          '',
          `KES ${fmtMoney(inv.totalSell)}`,
          `KES ${fmtMoney(runningBalance)}`
        ]);
      }
    });
    const closingBalance = runningBalance;

    // --- Opening Balance Banner ---
    startY += 90;
    doc.setFillColor(248, 250, 252);
    doc.setDrawColor(226, 232, 240);
    doc.rect(40, startY, a4Width - 80, 30, 'FD');
    doc.setFont("helvetica", "bold");
    doc.setFontSize(10);
    doc.setTextColor('#424242');
    doc.text(`Previous Unpaid Balance (Prior to 1 ${monthName.split(' ')[0]}):`, 50, startY + 20);
    doc.setTextColor(openingBalance > 0 ? '#dc2626' : '#2E7D32');
    doc.text(`KES ${fmtMoney(openingBalance)}`, a4Width - 50, startY + 20, { align: "right" });

    // --- Transactions Table ---
    doc.autoTable({
      startY: startY + 45,
      head: [["Date", "Description", "Details", "Debit", "Credit", "Balance"]],
      body: transactions.length ? transactions : [["", "No transactions this month", "", "", "", ""]],
      theme: 'plain',
      styles: { fontSize: 9.5, cellPadding: 8, textColor: '#424242' },
      headStyles: { fillColor: '#313a43', textColor: '#ffffff', fontStyle: 'bold', valign: 'middle' },
      alternateRowStyles: { fillColor: '#f8fafc' },
      columnStyles: {
        3: { halign: 'right', textColor: '#dc2626' },
        4: { halign: 'right', textColor: '#2E7D32' },
        5: { halign: 'right', fontStyle: 'bold' }
      },
      margin: { left: 40, right: 40, bottom: 60 },
      didDrawPage: function (data) {
        if (data.pageNumber > 1) drawHeaderShapes(false);
      }
    });

    let finalY = doc.lastAutoTable.finalY + 30;
    if (finalY > a4Height - 240) {
      doc.addPage();
      finalY = 160;
    }

    // --- Summary & Age Analysis ---
    doc.setFontSize(10);
    doc.setTextColor('#424242');
    doc.text("Total Invoiced:", a4Width - 160, finalY, { align: "right" });
    doc.setTextColor('#dc2626');
    doc.text(`KES ${fmtMoney(monthInvoicedTotal)}`, a4Width - 40, finalY, { align: "right" });
    
    doc.setTextColor('#424242');
    doc.text("Total Paid:", a4Width - 160, finalY + 20, { align: "right" });
    doc.setTextColor('#2E7D32');
    doc.text(`KES ${fmtMoney(monthPaidTotal)}`, a4Width - 40, finalY + 20, { align: "right" });
    
    doc.setDrawColor(97, 177, 70);
    doc.setLineWidth(1.5);
    doc.line(a4Width - 220, finalY + 30, a4Width - 40, finalY + 30);
    
    doc.setFont("helvetica", "bold");
    doc.setTextColor('#424242');
    doc.text("Total Amount Owed:", a4Width - 160, finalY + 45, { align: "right" });
    doc.setTextColor(closingBalance > 0 ? '#dc2626' : '#2E7D32');
    doc.text(`KES ${fmtMoney(closingBalance)}`, a4Width - 40, finalY + 45, { align: "right" });

    if (closingBalance > 0) {
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

      doc.setFillColor(255, 247, 237);
      doc.setDrawColor(254, 215, 170);
      doc.setLineWidth(1);
      doc.rect(40, finalY, 320, 60, 'FD');
      
      // Draw Debt Age Analysis Icon (simple bar chart svg)
      const chartIconSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#92400e" stroke-width="2.5"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>';
      const chartIconData = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(chartIconSvg);
      
      try {
        const chartImg = await loadImage(chartIconData);
        doc.addImage(chartImg, 'PNG', 48, finalY + 5, 12, 12);
      } catch(e) {}
      
      doc.setFontSize(9);
      doc.setFont("helvetica", "bold");
      doc.setTextColor('#92400e');
      doc.text("Debt Age Analysis", 65, finalY + 15);
      
      doc.setFontSize(8);
      doc.setTextColor('#616161');
      doc.setFont("helvetica", "normal");
      doc.text("Current", 50, finalY + 35);
      doc.text("30 Days", 120, finalY + 35);
      doc.text("60 Days", 190, finalY + 35);
      doc.text("90+ Days", 260, finalY + 35);

      doc.setFontSize(9);
      doc.setFont("helvetica", "bold");
      doc.setTextColor('#2E7D32'); doc.text(`KES ${fmtMoney(current)}`, 50, finalY + 50);
      doc.setTextColor('#d97706'); doc.text(`KES ${fmtMoney(days30)}`, 120, finalY + 50);
      doc.setTextColor('#ea580c'); doc.text(`KES ${fmtMoney(days60)}`, 190, finalY + 50);
      doc.setTextColor('#dc2626'); doc.text(`KES ${fmtMoney(days90)}`, 260, finalY + 50);
    }

    // --- Official Stamp ---
    try {
      const stampX = a4Width - 200;
      const stampY = finalY + 70;
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
      doc.text("ACCOUNT VERIFIED", stampX + 90, stampY + 55, { align: "center" });
      
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
      doc.ellipse(a4Width / 2, a4Height - 40, a4Width * 0.8, 20, 'F');
      doc.rect(0, a4Height - 40, a4Width, 40, 'F');
      
      doc.setFont("helvetica", "italic");
      doc.setFontSize(9);
      doc.setTextColor('#ffffff');
      doc.text(`Thank you for your business, ${rest.name}!`, 40, a4Height - 15);
      doc.setFont("helvetica", "normal");
      doc.setFontSize(8);
      doc.text(`Account Statement — ${monthName}`, a4Width - 40, a4Height - 15, { align: "right" });
    }

    const filename = `Statement_${rest.name.replace(/\s+/g, '_')}_${monthName}.pdf`;
    doc.save(filename);
    toast('PDF Downloaded!', 'success');

  } catch (error) {
    console.error("PDF Generation Error: ", error);
    toast("Error generating Statement PDF", "error");
  }
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
