/* Town Treasure Groceries — App Entry Point */
/* All modules are loaded via separate script tags in index.html */
/* This file is kept for any future initialization or global state */
console.log('Town Treasure Groceries — Invoice & Books v1.0');

function paginateElement(doc) {
  if (!doc) return;
  const width = doc.offsetWidth;
  if (!width) return;
  
  const a4Height = width * (297 / 210);
  doc.style.height = 'auto';
  
  const height = doc.offsetHeight;
  const pages = Math.ceil(height / a4Height);
  
  // If content barely overflows by less than 15%, keep it on the current page count - 1
  // This prevents a tiny overflow from creating a mostly-empty second page
  const overflow = height - ((pages - 1) * a4Height);
  const overflowRatio = overflow / a4Height;
  
  if (pages > 1 && overflowRatio < 0.15) {
    // Content barely spills over — fit it on fewer pages
    doc.style.height = ((pages - 1) * a4Height - 10) + 'px';
  } else {
    doc.style.height = ((pages * a4Height) - 10) + 'px';
  }
}

function downloadPDF(elementId, filenamePrefix) {
  const element = document.getElementById(elementId);
  if (!element || typeof html2pdf === 'undefined') {
    alert("PDF generator not ready or element not found.");
    return;
  }
  
  // Create a loading overlay to hide the scroll jump from the user
  const overlay = document.createElement('div');
  overlay.innerHTML = '<div style="background:white; padding:20px; border-radius:8px; box-shadow:0 4px 12px rgba(0,0,0,0.15); color:var(--green-600); font-weight:bold; font-size:1.2rem; display:flex; align-items:center; gap:10px;"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="animation:spin 1s linear infinite;"><line x1="12" y1="2" x2="12" y2="6"></line><line x1="12" y1="18" x2="12" y2="22"></line><line x1="4.93" y1="4.93" x2="7.76" y2="7.76"></line><line x1="16.24" y1="16.24" x2="19.07" y2="19.07"></line><line x1="2" y1="12" x2="6" y2="12"></line><line x1="18" y1="12" x2="22" y2="12"></line><line x1="4.93" y1="19.07" x2="7.76" y2="16.24"></line><line x1="16.24" y1="7.76" x2="19.07" y2="4.93"></line></svg> Generating PDF...</div>';
  Object.assign(overlay.style, {
    position: 'fixed', top: '0', left: '0', width: '100vw', height: '100vh',
    backgroundColor: 'rgba(255,255,255,0.95)', zIndex: '999999',
    display: 'flex', alignItems: 'center', justifyContent: 'center'
  });
  document.body.appendChild(overlay);

  // Save current scroll position and jump to top to prevent html2canvas cropping/blank bugs
  const sy = window.scrollY;
  window.scrollTo(0, 0);

  // Clone the element to avoid modifying the UI during PDF generation
  const clone = element.cloneNode(true);
  
  // Ensure the clone has proper styling for the PDF format
  clone.classList.add('pdf-export');
  clone.style.position = 'absolute';
  clone.style.top = '0';
  clone.style.left = '0';
  clone.style.zIndex = '1';
  clone.style.padding = '0';
  clone.style.margin = '0';
  clone.style.width = '800px'; 
  clone.style.boxShadow = 'none';
  clone.style.border = 'none'; 
  
  document.body.appendChild(clone);
  
  // We need to find the actual doc inside the clone if the elementId is the container
  const docToPaginate = clone.id === 'invoice-doc' ? clone : clone.querySelector('#invoice-doc');
  if (docToPaginate) {
    paginateElement(docToPaginate);
  }
  
  const opt = {
    margin:       [0, 0, 0, 0],
    filename:     `${filenamePrefix}.pdf`,
    image:        { type: 'jpeg', quality: 1.0 },
    html2canvas:  { scale: 2, useCORS: true, scrollY: 0, windowWidth: 800 },
    jsPDF:        { unit: 'in', format: 'a4', orientation: 'portrait' }
  };
  
  document.body.classList.add('exporting-pdf');
  
  // Let the browser paint the jump before capturing
  setTimeout(() => {
    html2pdf().set(opt).from(clone).save().then(() => {
      document.body.classList.remove('exporting-pdf');
      document.body.removeChild(clone);
      document.body.removeChild(overlay);
      window.scrollTo(0, sy);
    }).catch(err => {
      console.error("PDF Gen Error:", err);
      document.body.classList.remove('exporting-pdf');
      if (document.body.contains(clone)) document.body.removeChild(clone);
      if (document.body.contains(overlay)) document.body.removeChild(overlay);
      window.scrollTo(0, sy);
      alert("Failed to generate PDF. Please try again.");
    });
  }, 150);
}

// Apply the same magic trick for the native Print dialog
window.addEventListener('beforeprint', () => {
  const docs = document.querySelectorAll('.invoice-preview');
  docs.forEach(doc => paginateElement(doc));
});

window.addEventListener('afterprint', () => {
  const docs = document.querySelectorAll('.invoice-preview');
  docs.forEach(doc => {
    doc.style.height = 'auto';
  });
  setTimeout(() => {
    document.querySelectorAll('.fade-up').forEach((el, i) => {
      setTimeout(() => el.classList.add('visible'), i * 100);
    });
  }, 100);

  // Check if we already have permission, if so, check bills
  if ('Notification' in window && Notification.permission === 'granted') {
    document.getElementById('btnNotify').style.color = 'var(--green-500)';
    checkPendingBills();
  }
});

function enableNotifications() {
  if (!('Notification' in window)) {
    toast('Notifications are not supported in this browser.', 'error');
    return;
  }
  
  Notification.requestPermission().then(permission => {
    if (permission === 'granted') {
      document.getElementById('btnNotify').style.color = 'var(--green-500)';
      toast('Notifications enabled!', 'success');
      checkPendingBills();
    } else {
      toast('Notification permission denied.', 'error');
    }
  });
}

function checkPendingBills() {
  if (!DB || !DB.invoices) return;
  const pendingCount = DB.invoices.filter(i => i.status === 'pending' || i.status === 'overdue').length;
  
  if (pendingCount > 0) {
    // Only notify once per session to avoid spamming
    if (!sessionStorage.getItem('notifiedPending')) {
      new Notification('Town Treasure Groceries', {
        body: `You have ${pendingCount} pending/overdue invoices that need attention!`,
        icon: 'assets/favicon.png'
      });
      sessionStorage.setItem('notifiedPending', 'true');
    }
  }
}
