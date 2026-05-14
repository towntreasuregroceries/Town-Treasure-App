/* ══ Invoice View / Print ══ */
function viewInvoice(id) {
  const inv = DB.invoices.find(i => i.id === id);
  if (!inv) return;
  currentViewInvoiceId = id;
  const rest = DB.restaurants.find(r => r.id === inv.restaurantId) || {};
  const container = document.getElementById('invoiceViewContainer');
  
  // Build items rows
  const itemsRows = inv.items.map((it, idx) => `
    <tr>
      <td style="text-align: center; width: 50px;">${(idx + 1).toString().padStart(2, '0')}</td>
      <td>${it.desc}</td>
      <td style="text-align: right;">KSh ${fmtMoney(it.sellPrice)}</td>
      <td style="text-align: center;">${it.qty} ${it.unit || 'kgs'}</td>
      <td style="text-align: right;">KSh ${fmtMoney(it.total)}</td>
    </tr>
  `).join('');

  container.innerHTML = `
  <div class="invoice-preview" id="invoice-view-doc">
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
       <div class="invoice-title">INVOICE</div>
       <table class="invoice-meta-grid" style="border-collapse: collapse; background: transparent; font-size: 0.85rem;">
          <tr>
            <td class="meta-label" style="font-weight: 700; color: #424242; text-align: right; padding: 0 15px 5px 0; border: none;">Receipt No:</td>
            <td class="meta-value" style="color: #616161; text-align: right; padding: 0 0 5px 0; border: none;">${inv.number}</td>
          </tr>
          <tr>
            <td class="meta-label" style="font-weight: 700; color: #424242; text-align: right; padding: 0 15px 0 0; border: none;">Order Date:</td>
            <td class="meta-value" style="color: #616161; text-align: right; padding: 0 0 0 0; border: none;">${fmtDate(inv.date)}</td>
          </tr>
       </table>
    </div>

    <div class="invoice-billed-to" style="display: flex; justify-content: space-between;">
      <div style="padding-left: 5px;">
        <h4 style="margin-bottom: 12px; color: #424242;">FROM:</h4>
        <p style="font-weight: 700; font-size: 1rem; margin-bottom: 8px; color: #2E7D32;">Town Treasure Limited</p>
        <div style="display: flex; flex-direction: column; gap: 6px;">
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg> 0708567696</p>
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"></path><polyline points="22,6 12,13 2,6"></polyline></svg> towntreasuregroceries@gmail.com</p>
           <p style="display: flex; align-items: center; gap: 8px; font-size: 0.85rem;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg> towntreasuregroceries.com</p>
        </div>
      </div>
      <div style="text-align: right; padding-right: 5px;">
        <h4 style="margin-bottom: 12px; color: #424242;">BILLED TO:</h4>
        <p style="font-weight: 700; font-size: 1rem; margin-bottom: 8px; color: #424242;">${inv.restaurantName}</p>
        <p style="font-size: 0.85rem; margin-bottom: 4px;">${rest.address || ''}</p>
        <p style="font-size: 0.85rem;">${rest.phone || ''}</p>
      </div>
    </div>

    <div class="invoice-table-wrapper">
      <table class="receipt-table">
        <thead>
          <tr>
            <th style="width: 50px; text-align: center;">SL<br>No.</th>
            <th>Item Description</th>
            <th style="text-align: right;">Unit Price</th>
            <th style="text-align: center;">Quantity</th>
            <th style="text-align: right;">Total</th>
          </tr>
        </thead>
        <tbody>
          ${itemsRows}
        </tbody>
      </table>
    </div>

    <div class="invoice-totals-wrapper" style="display: flex; justify-content: flex-end; padding: 20px 50px 0;">
      <div class="totals-table-wrapper" style="width: 350px;">
        <table class="totals-table" style="width: 100%; border-collapse: collapse;">
          <tr>
            <td style="text-align: right; padding: 8px 20px; font-size: 0.85rem; color: #424242;">Sub Total:</td>
            <td style="text-align: right; padding: 8px 20px; font-size: 0.85rem; color: #424242;">KSh ${fmtMoney(inv.totalSell)}</td>
          </tr>
          <tr class="grand-total" style="background-color: #61b146; color: white;">
            <td style="text-align: right; padding: 8px 20px; font-weight: bold; font-size: 0.9rem;">Grand Total:</td>
            <td style="text-align: right; padding: 8px 20px; font-weight: bold; font-size: 0.9rem;">KSh ${fmtMoney(inv.totalSell)}</td>
          </tr>
        </table>
      </div>
    </div>

    <div style="page-break-inside: avoid; break-inside: avoid; margin-top: auto;">
      <div class="invoice-bottom-details" style="display: flex; justify-content: space-between; padding: 15px 50px 5px; position: relative; z-index: 2; margin-top: 10px;">
        <div class="payment-details" style="width: 200px;">
          <h4 style="font-size: 0.9rem; color: #424242; margin-bottom: 10px;">Visit Us Online:</h4>
          <div class="qr-wrapper" style="position: relative; width: 100px; height: 100px; margin-bottom: 8px;">
            <img src="assets/qr%20code.jpg" alt="QR Code" style="width: 100%; height: 100%; object-fit: contain; border-radius: 8px;">
          </div>
          <p style="font-size: 0.65rem; color: #616161; text-align: left; line-height: 1.3;">Scan to visit our website<br>and explore our fresh<br>grocery catalog online.</p>
        </div>
      </div>

      <div class="invoice-footer-shape">
         <div style="position: absolute; bottom: 20px; left: 0; right: 0; display: flex; justify-content: space-between; padding: 0 50px; color: white; z-index: 5;">
            <div style="font-style: italic; font-size: 0.9rem;">Thank you, ${inv.restaurantName}, for Shopping with us</div>
            <div style="font-size: 0.8rem;"></div>
         </div>
      </div>
      
      <!-- M-Pesa Styled Official Stamp -->
      <div class="official-stamp" style="position:absolute; right:60px; bottom:140px; width:220px; border:3px solid rgba(20,20,20,0.85); border-radius:10px; padding:10px; text-align:center; transform:rotate(-4deg); z-index:10; background:transparent; mix-blend-mode:multiply; box-shadow:none;">
        <img src="assets/stamp.png" style="max-width: 140px; max-height: 50px; object-fit: contain; filter: grayscale(100%); mix-blend-mode: multiply; margin-bottom: 5px;">
        <div style="font-size:1.1rem; font-weight:900; color:#000000; letter-spacing:1px; margin-bottom:5px;">${inv.status === 'paid' ? 'PAID & PROCESSED' : 'AUTHORIZED'}</div>
        <div style="font-size:0.7rem; color:#dc2626; font-family:monospace;">DATE: ${fmtDate(new Date().toISOString().slice(0,10))}</div>
        ${(DB.settings && DB.settings.signature) ? `<img src="${DB.settings.signature}" style="max-width:200px; max-height:80px; margin-top:5px; display:inline-block; mix-blend-mode:multiply;">` : `<div style="height:40px; margin-top:5px; border-bottom:1px solid #000000; width:80%; margin:5px auto 0 auto; line-height:50px; font-size:0.6rem; color:#000000;">Sign Here</div>`}
      </div>
      
    </div>
    <div class="watermark-overlay">
      <img src="assets/logo.png" alt="Stamp" class="watermark-stamp">
      <div class="watermark-text">Town Treasure Limited</div>
    </div>
  </div>`;

  navigateTo('invoice-view');
  
  // Set the PDF download filename to the exact invoice number
  const btn = document.getElementById('btnDownloadPdf');
  if (btn) {
    btn.setAttribute('onclick', `generateInvoicePDF('${inv.id}')`);
  }

  // Auto-paginate immediately so the user sees the true A4 layout
  setTimeout(() => {
    const doc = document.getElementById('invoice-view-doc');
    if (doc && typeof paginateElement === 'function') {
      paginateElement(doc);
    }
  }, 10);
}

function shareWhatsApp() {
  if (!currentViewInvoiceId) return;
  const inv = DB.invoices.find(i => i.id === currentViewInvoiceId);
  if (!inv) return;
  const rest = DB.restaurants.find(r => r.id === inv.restaurantId);
  if (!rest) return;

  let phone = rest.phone ? rest.phone.replace(/[^\d+]/g, '') : '';
  if (phone.startsWith('0')) phone = '254' + phone.slice(1);

  const text = `Hello ${rest.contact || rest.name},

Thank you for choosing Town Treasure Groceries! Please find attached your invoice for the recent order.

*Invoice No:* ${inv.number}
*Date:* ${inv.date}
*Total Amount:* KES ${fmtMoney(inv.totalSell)}

Feel free to reach out for any queries. We appreciate your business!`;

  const filename = `Invoice_${inv.number}_${rest.name.replace(/\s+/g, '_')}`;

  // 1. Download the PDF automatically
  toast('Downloading PDF...', 'success');
  generateInvoicePDF(currentViewInvoiceId);
  
  // 2. Open WhatsApp directly to the specific contact
  setTimeout(() => {
    window.open(`https://wa.me/${phone}?text=${encodeURIComponent(text)}`, '_blank');
  }, 1500);
}


/* ══ jsPDF Invoice Generator ══ */
async function generateInvoicePDF(id) {
  const inv = DB.invoices.find(i => i.id === id);
  if (!inv) return;
  const rest = DB.restaurants.find(r => r.id === inv.restaurantId) || {};
  
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

  const primaryColor = '#61b146';
  const textColor = '#424242';
  const lightText = '#616161';
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
    if (type === 'web') svg = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#61b146" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg>';
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  };

  try {
    let logoData = null;
    let logoWidth = 0;
    let logoHeight = 0;
    try {
      logoData = await loadImage('assets/logo.png');
      const imgProps = doc.getImageProperties(logoData);
      logoHeight = 55;
      logoWidth = (imgProps.width * logoHeight) / imgProps.height;
    } catch (e) { console.warn("Could not load logo", e); }

    const phoneIcon = await loadImage(getSvgIcon('phone'));
    const emailIcon = await loadImage(getSvgIcon('email'));
    const webIcon = await loadImage(getSvgIcon('web'));

    const drawHeaderShapes = () => {
      // Green background - flat at the bottom as requested
      doc.setFillColor(97, 177, 70); 
      doc.rect(0, 0, a4Width, 110, 'F');
      
      // Dark Slate perfect smooth curve
      doc.setFillColor(49, 58, 67); 
      doc.ellipse(a4Width, -158, 500, 258, 'F');
      
      if (logoData) doc.addImage(logoData, 'PNG', 40, 25, logoWidth, logoHeight);
    };

    // --- 1. Watermark ---
    doc.setTextColor(245, 245, 245);
    doc.setFontSize(45); // Reduced size so it fits inside the PDF
    doc.setFont("helvetica", "bold");
    doc.text("Town Treasure Limited", 100, 550, { angle: 30 });
    doc.setTextColor(textColor);

    // --- 2. Header ---
    drawHeaderShapes();

    // --- 3. Title Row ---
    doc.setFont("helvetica", "bold");
    doc.setFontSize(26);
    doc.setTextColor(primaryColor);
    doc.text("INVOICE", 40, 160);

    doc.setFontSize(10);
    doc.setTextColor(textColor);
    doc.text("Receipt No:", 480, 150, { align: "right" });
    doc.setFont("helvetica", "normal");
    doc.setTextColor(lightText);
    doc.text(inv.number, 555, 150, { align: "right" });
    
    doc.setFont("helvetica", "bold");
    doc.setTextColor(textColor);
    doc.text("Order Date:", 480, 165, { align: "right" });
    doc.setFont("helvetica", "normal");
    doc.setTextColor(lightText);
    doc.text(fmtDate(inv.date), 555, 165, { align: "right" });

    // --- 4. FROM and TO ---
    doc.setFontSize(10);
    doc.setFont("helvetica", "bold");
    doc.setTextColor(textColor);
    doc.text("FROM:", 40, 205);
    doc.text("BILLED TO:", 555, 205, { align: "right" });

    doc.setFontSize(11);
    doc.setTextColor(primaryColor);
    doc.text("Town Treasure Limited", 40, 223);
    
    doc.setTextColor(textColor);
    doc.text(inv.restaurantName, 555, 223, { align: "right" });

    doc.setFontSize(9);
    doc.setFont("helvetica", "normal");
    doc.setTextColor(lightText);
    
    // Icons & Text for FROM
    doc.addImage(phoneIcon, 'PNG', 40, 233, 10, 10);
    doc.text("0708567696", 55, 242);
    
    doc.addImage(emailIcon, 'PNG', 40, 248, 10, 10);
    doc.text("towntreasuregroceries@gmail.com", 55, 257);
    
    doc.addImage(webIcon, 'PNG', 40, 263, 10, 10);
    doc.text("towntreasuregroceries.com", 55, 272);

    if (rest.address) doc.text(rest.address, 555, 242, { align: "right" });
    if (rest.phone) doc.text(rest.phone, 555, 257, { align: "right" });

    // --- 5. Line Items ---
    const tableColumn = ["SL\nNO.", "ITEM DESCRIPTION", "UNIT PRICE", "QUANTITY", "TOTAL"];
    const tableRows = inv.items.map((it, idx) => [
      (idx + 1).toString().padStart(2, '0'),
      it.desc,
      `KSh ${fmtMoney(it.sellPrice)}`,
      `${it.qty} ${it.unit || 'kgs'}`,
      `KSh ${fmtMoney(it.total)}`
    ]);

    doc.autoTable({
      startY: 295,
      margin: { top: 160, bottom: 60 },
      head: [tableColumn],
      body: tableRows,
      theme: 'plain',
      styles: { fontSize: 9.5, cellPadding: 10, textColor: '#424242' },
      headStyles: { fillColor: '#313a43', textColor: '#ffffff', fontStyle: 'bold', valign: 'middle' },
      alternateRowStyles: { fillColor: '#f8fafc' },
      columnStyles: {
        0: { halign: 'center', cellWidth: 40 },
        2: { halign: 'right' },
        3: { halign: 'center' },
        4: { halign: 'right' }
      },
      didDrawPage: function (data) {
        // Redraw header on new pages if it breaks across pages
        if (data.pageNumber > 1) {
          drawHeaderShapes();
        }
      }
    });

    // --- 6. Totals & QR on Last Page ---
    let finalY = doc.lastAutoTable.finalY + 20;
    
    // Ensure we have enough space for the totals and QR code (approx 120pt needed)
    if (finalY > a4Height - 140) {
      doc.addPage();
      finalY = 160; // start below the header on the new page
    }

    doc.setFontSize(9.5);
    doc.setFont("helvetica", "bold");
    doc.setTextColor(textColor);
    doc.text("Sub Total:", 420, finalY + 18, { align: "right" });
    doc.text(`KSh ${fmtMoney(inv.totalSell)}`, 545, finalY + 18, { align: "right" });
    
    doc.setFillColor(97, 177, 70);
    doc.rect(340, finalY + 28, 215, 26, 'F');
    doc.setTextColor('#ffffff');
    doc.text("Grand Total:", 420, finalY + 45, { align: "right" });
    doc.text(`KSh ${fmtMoney(inv.totalSell)}`, 545, finalY + 45, { align: "right" });

    // QR Code anchored just above the footer
    try {
      const qrData = await loadImage('assets/qr%20code.jpg');
      const qrY = a4Height - 145; // Fixed absolute coordinate above footer
      doc.addImage(qrData, 'JPEG', 40, qrY, 70, 70);
      
      doc.setFontSize(9.5);
      doc.setFont("helvetica", "bold");
      doc.setTextColor(textColor);
      doc.text("Visit Us Online:", 40, qrY - 8);
      
      doc.setFont("helvetica", "normal");
      doc.setFontSize(8.5);
      doc.setTextColor(lightText);
      doc.text("Scan to visit our website\nand explore our fresh\ngrocery catalog online.", 120, qrY + 25);
    } catch(e) {}

    // --- 6.5 Official M-Pesa Style Stamp ---
    try {
      const stampX = a4Width - 200;
      const stampY = a4Height - 175;
      const boxW = 180;
      const boxH = 100;
      
      // Box
      doc.setDrawColor(30, 30, 30);
      doc.setLineWidth(2.5);
      doc.roundedRect(stampX, stampY, boxW, boxH, 10, 10, 'D');
      
      // Texts & Logo
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
      doc.text(inv.status === 'paid' ? "PAID & PROCESSED" : "AUTHORIZED", stampX + 90, stampY + 55, { align: "center" });
      
      doc.setFont("courier", "normal");
      doc.setFontSize(7);
      doc.setTextColor(220, 38, 38);
      doc.text(`DATE: ${fmtDate(new Date().toISOString().slice(0,10))}`, stampX + 90, stampY + 67, { align: "center" });
      
      // Signature
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

    // --- 7. Footer on ALL Pages ---
    const pageCount = doc.internal.getNumberOfPages();
    for (let i = 1; i <= pageCount; i++) {
      doc.setPage(i);
      doc.setFillColor(49, 58, 67);
      doc.ellipse(a4Width / 2, a4Height - 40, a4Width * 0.8, 20, 'F');
      doc.rect(0, a4Height - 40, a4Width, 40, 'F');
      
      doc.setFont("helvetica", "italic");
      doc.setFontSize(9);
      doc.setTextColor('#ffffff');
      doc.text(`Thank you, ${inv.restaurantName}, for Shopping with us`, 40, a4Height - 15);
    }

    const filename = `Invoice_${inv.number}_${inv.restaurantName.replace(/\s+/g, '_')}.pdf`;
    doc.save(filename);

  } catch (error) {
    console.error("PDF Generation Error: ", error);
    toast("Error generating PDF", "error");
  }
}

/* ══ Expenses & Capital ══ */
let expenseTab = 'expenses';
function switchExpenseTab(tab, btn) {
  expenseTab = tab;
  document.querySelectorAll('#page-expenses .tab-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  renderExpenses();
}
function saveExpense() {
  const e = {
    id: genId(),
    type: document.getElementById('expType').value,
    date: document.getElementById('expDate').value || new Date().toISOString().slice(0,10),
    desc: document.getElementById('expDesc').value.trim(),
    category: document.getElementById('expCategory').value,
    amount: parseFloat(document.getElementById('expAmount').value) || 0
  };
  if (!e.desc || !e.amount) return toast('Fill all fields', 'error');
  const list = DB.expenses; list.push(e); DB.expenses = list;
  closeModal('expenseModal');
  ['expDesc','expAmount'].forEach(f => document.getElementById(f).value = '');
  renderExpenses(); toast('Entry saved');
}
function deleteExpense(id) {
  customConfirm('Are you sure you want to delete this entry?', 'Delete Entry', 'Yes, Delete', true, () => {
    DB.expenses = DB.expenses.filter(e => e.id !== id);
    renderExpenses(); toast('Deleted');
  });
}
function renderExpenses() {
  const all = DB.expenses.slice().reverse();
  const filtered = all.filter(e => expenseTab === 'capital' ? e.type === 'capital' : e.type === 'expense');
  const body = document.getElementById(expenseTab === 'capital' ? 'capitalBody' : 'expensesBody');
  if (!body) return;
  if (!filtered.length) { body.innerHTML = '<tr><td colspan="6" class="empty-state"><h3>No entries yet</h3></td></tr>'; return; }
  body.innerHTML = filtered.map(e => {
    const typeBadge = e.type === 'capital' ? 'badge-success' : 'badge-warning';
    return `<tr><td>${fmtDate(e.date)}</td><td>${e.desc}</td><td style="text-transform:capitalize">${e.category}</td><td>KES ${fmtMoney(e.amount)}</td><td><span class="badge ${typeBadge}">${e.type}</span></td><td><button class="btn btn-sm btn-danger" onclick="deleteExpense('${e.id}')">Del</button></td></tr>`;
  }).join('');
  // Capital stats
  const totalCap = DB.expenses.filter(e => e.type === 'capital').reduce((s, e) => s + e.amount, 0);
  const totalExp = DB.expenses.filter(e => e.type === 'expense').reduce((s, e) => s + e.amount, 0);
  const totalRev = DB.invoices.filter(i => i.status === 'paid').reduce((s, i) => s + i.totalSell, 0);
  document.getElementById('capitalStats').innerHTML = `
    <div class="stat-card fade-up"><div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6"/></svg></div><div class="stat-info"><h4>Total Capital</h4><div class="stat-value">KES ${fmtMoney(totalCap)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon red"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/></svg></div><div class="stat-info"><h4>Total Expenses</h4><div class="stat-value">KES ${fmtMoney(totalExp)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/></svg></div><div class="stat-info"><h4>Paid Revenue</h4><div class="stat-value">KES ${fmtMoney(totalRev)}</div></div></div>
    <div class="stat-card fade-up"><div class="stat-icon ${(totalCap + totalRev - totalExp) >= 0 ? 'green' : 'red'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="10" x2="22" y2="10"/></svg></div><div class="stat-info"><h4>Net Balance</h4><div class="stat-value">KES ${fmtMoney(totalCap + totalRev - totalExp)}</div></div></div>`;
}
