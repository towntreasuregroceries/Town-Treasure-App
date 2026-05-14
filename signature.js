/* ══ Signature Scanner — Mobile-First ══ */

function openSignatureScanner() {
  // Reset UI
  document.getElementById('sigPreview').style.display = 'none';
  document.getElementById('sigPreview').src = '';
  document.getElementById('sigPlaceholder').style.display = 'flex';
  document.getElementById('btnSigSave').style.display = 'none';
  document.getElementById('sigCameraInput').value = '';
  document.getElementById('sigGalleryInput').value = '';
  document.getElementById('signatureScannerModal').classList.add('active');
}

function closeSignatureScanner() {
  document.getElementById('signatureScannerModal').classList.remove('active');
}

function handleSignatureFile(event) {
  const file = event.target.files[0];
  if (!file) return;

  const loading = document.getElementById('sigLoading');
  loading.style.display = 'flex';

  const reader = new FileReader();
  reader.onload = function(e) {
    const img = new Image();
    img.onload = function() {
      const canvas = document.getElementById('sigCanvas');
      canvas.width = img.width;
      canvas.height = img.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0);

      // Process: remove background, tint ink blue, crop
      processSignatureImage(ctx, canvas.width, canvas.height);

      const preview = document.getElementById('sigPreview');
      preview.src = canvas.toDataURL('image/png');
      preview.style.display = 'block';
      document.getElementById('sigPlaceholder').style.display = 'none';
      document.getElementById('btnSigSave').style.display = 'inline-block';
      loading.style.display = 'none';
    };
    img.onerror = function() {
      loading.style.display = 'none';
      toast('Could not load image. Try again.', 'error');
    };
    img.src = e.target.result;
  };
  reader.readAsDataURL(file);
}

function processSignatureImage(ctx, width, height) {
  const imageData = ctx.getImageData(0, 0, width, height);
  const data = imageData.data;

  // Find average brightness for adaptive threshold
  let totalBrightness = 0;
  for (let i = 0; i < data.length; i += 4) {
    totalBrightness += 0.34 * data[i] + 0.5 * data[i + 1] + 0.16 * data[i + 2];
  }
  const threshold = (totalBrightness / (width * height)) * 0.85;

  let minX = width, minY = height, maxX = 0, maxY = 0;

  for (let i = 0; i < data.length; i += 4) {
    const brightness = 0.34 * data[i] + 0.5 * data[i + 1] + 0.16 * data[i + 2];

    if (brightness < threshold) {
      // Signature ink → deep biro blue
      data[i] = 10;
      data[i + 1] = 20;
      data[i + 2] = 120;
      data[i + 3] = 255;

      const x = (i / 4) % width;
      const y = Math.floor((i / 4) / width);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    } else {
      // Background → transparent
      data[i + 3] = 0;
    }
  }

  ctx.putImageData(imageData, 0, 0);

  // Crop to bounding box
  if (maxX > minX && maxY > minY) {
    const pad = 20;
    minX = Math.max(0, minX - pad);
    minY = Math.max(0, minY - pad);
    maxX = Math.min(width, maxX + pad);
    maxY = Math.min(height, maxY + pad);

    const cropW = maxX - minX;
    const cropH = maxY - minY;
    const croppedData = ctx.getImageData(minX, minY, cropW, cropH);
    ctx.canvas.width = cropW;
    ctx.canvas.height = cropH;
    ctx.putImageData(croppedData, 0, 0);
  }
}

function saveSignature() {
  const canvas = document.getElementById('sigCanvas');
  const dataUrl = canvas.toDataURL('image/png');

  const settings = DB.settings || {};
  settings.signature = dataUrl;
  DB.settings = settings;

  toast("Signature saved to vault!", "success");
  closeSignatureScanner();
}
