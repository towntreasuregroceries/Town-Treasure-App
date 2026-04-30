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
  
  // Clone the element to avoid modifying the UI during PDF generation
  const clone = element.cloneNode(true);
  clone.classList.add('pdf-export');
  clone.style.padding = '0';
  clone.style.margin = '0';
  clone.style.width = '800px';
  clone.style.boxShadow = 'none';
  clone.style.border = 'none';
  
  document.body.appendChild(clone);
  
  const docToPaginate = clone.id === 'invoice-doc' ? clone : clone.querySelector('#invoice-doc');
  if (docToPaginate) {
    paginateElement(docToPaginate);
  }
  
  const opt = {
    margin:       [0, 0, 0, 0],
    filename:     `${filenamePrefix}.pdf`,
    image:        { type: 'jpeg', quality: 1.0 },
    html2canvas:  { scale: 2, useCORS: true },
    jsPDF:        { unit: 'in', format: 'a4', orientation: 'portrait' }
  };
  
  document.body.classList.add('exporting-pdf');
  html2pdf().set(opt).from(clone).save().then(() => {
    document.body.classList.remove('exporting-pdf');
    document.body.removeChild(clone);
  });
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
