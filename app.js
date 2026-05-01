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

/* ══ WebAuthn App Lock ══ */
function bufferToBase64url(buffer) {
  const bytes = new Uint8Array(buffer);
  let str = '';
  for (const charCode of bytes) str += String.fromCharCode(charCode);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function base64urlToBuffer(base64url) {
  const padding = '='.repeat((4 - base64url.length % 4) % 4);
  const base64 = (base64url + padding).replace(/\-/g, '+').replace(/_/g, '/');
  const rawData = atob(base64);
  const buffer = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) buffer[i] = rawData.charCodeAt(i);
  return buffer;
}

function updateLockUI() {
  const isLocked = localStorage.getItem('ttg_device_lock');
  const txt = document.getElementById('lockStatusText');
  if (txt) txt.textContent = isLocked ? 'Disable App Lock' : 'Enable App Lock';
}

async function toggleDeviceLock() {
  if (localStorage.getItem('ttg_device_lock')) {
    customConfirm('Are you sure you want to disable the app lock?', 'Disable Lock', 'Yes, Disable', true, () => {
      localStorage.removeItem('ttg_device_lock');
      updateLockUI();
      toast('App Lock disabled');
    });
    return;
  }
  
  if (!window.PublicKeyCredential) {
    toast("Your device doesn't support WebAuthn / Passkeys.", 'error');
    return;
  }
  try {
    const challenge = new Uint8Array(32);
    crypto.getRandomValues(challenge);
    const userId = new Uint8Array(16);
    crypto.getRandomValues(userId);

    const credential = await navigator.credentials.create({
      publicKey: {
        challenge: challenge,
        rp: { name: "Town Treasure Groceries" },
        user: { id: userId, name: "Owner", displayName: "Store Owner" },
        pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
        authenticatorSelection: { authenticatorAttachment: "platform", userVerification: "required" },
        timeout: 60000
      }
    });

    if (credential) {
      localStorage.setItem('ttg_device_lock', bufferToBase64url(credential.rawId));
      updateLockUI();
      toast('App Lock enabled successfully!');
    }
  } catch (err) {
    console.error(err);
    toast('Failed to setup device lock. Ensure screen lock is enabled.', 'error');
  }
}

async function unlockDevice() {
  const credIdStr = localStorage.getItem('ttg_device_lock');
  if (!credIdStr) {
    document.getElementById('lockScreen').style.display = 'none';
    return;
  }
  try {
    const challenge = new Uint8Array(32);
    crypto.getRandomValues(challenge);
    const assertion = await navigator.credentials.get({
      publicKey: {
        challenge: challenge,
        allowCredentials: [{ type: 'public-key', id: base64urlToBuffer(credIdStr) }],
        userVerification: 'required',
        timeout: 60000
      }
    });
    if (assertion) {
      document.getElementById('lockScreen').style.display = 'none';
    }
  } catch (err) {
    console.error(err);
    toast('Authentication failed', 'error');
  }
}

function initLockScreen() {
  if (localStorage.getItem('ttg_device_lock')) {
    document.getElementById('lockScreen').style.display = 'flex';
  }
  updateLockUI();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initLockScreen);
} else {
  initLockScreen();
}
