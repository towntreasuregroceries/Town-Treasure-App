/* ══ Signature Scanner ══ */

let sigStream = null;

async function openSignatureScanner() {
  document.getElementById('sigPreview').style.display = 'none';
  document.getElementById('btnSigRetake').style.display = 'none';
  document.getElementById('btnSigSave').style.display = 'none';
  document.getElementById('btnSigCapture').style.display = 'inline-block';
  document.getElementById('sigVideo').style.display = 'block';
  document.getElementById('signatureScannerModal').style.display = 'flex';

  try {
    sigStream = await navigator.mediaDevices.getUserMedia({ 
      video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } } 
    });
    document.getElementById('sigVideo').srcObject = sigStream;
  } catch (err) {
    console.error("Camera access failed", err);
    toast("Could not access camera. Please allow camera permissions.", "error");
  }
}

function closeSignatureScanner() {
  document.getElementById('signatureScannerModal').style.display = 'none';
  if (sigStream) {
    sigStream.getTracks().forEach(track => track.stop());
    sigStream = null;
  }
}

function captureSignature() {
  const video = document.getElementById('sigVideo');
  const canvas = document.getElementById('sigCanvas');
  const preview = document.getElementById('sigPreview');
  const loading = document.getElementById('sigLoading');

  if (!sigStream) return;

  loading.style.display = 'flex';

  // Small delay to allow UI to update
  setTimeout(() => {
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const ctx = canvas.getContext('2d');
    
    // Draw current frame
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    
    // Process image to extract signature
    processSignatureImage(ctx, canvas.width, canvas.height);
    
    preview.src = canvas.toDataURL('image/png');
    
    video.style.display = 'none';
    preview.style.display = 'block';
    
    document.getElementById('btnSigCapture').style.display = 'none';
    document.getElementById('btnSigRetake').style.display = 'inline-block';
    document.getElementById('btnSigSave').style.display = 'inline-block';
    
    loading.style.display = 'none';
  }, 100);
}

function retakeSignature() {
  document.getElementById('sigPreview').style.display = 'none';
  document.getElementById('sigVideo').style.display = 'block';
  document.getElementById('btnSigRetake').style.display = 'none';
  document.getElementById('btnSigSave').style.display = 'none';
  document.getElementById('btnSigCapture').style.display = 'inline-block';
}

function processSignatureImage(ctx, width, height) {
  const imageData = ctx.getImageData(0, 0, width, height);
  const data = imageData.data;
  
  // Convert to grayscale and find average brightness
  let totalBrightness = 0;
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const brightness = 0.34 * r + 0.5 * g + 0.16 * b;
    totalBrightness += brightness;
  }
  
  const avgBrightness = totalBrightness / (width * height);
  // Adaptive threshold based on average brightness (darker marks get kept)
  const threshold = avgBrightness * 0.85;

  let minX = width, minY = height, maxX = 0, maxY = 0;

  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    
    const brightness = 0.34 * r + 0.5 * g + 0.16 * b;
    
    if (brightness < threshold) {
      // It's part of the signature: turn it to a deep blue ink color
      data[i] = 10;     // R
      data[i + 1] = 20; // G
      data[i + 2] = 120;// B
      data[i + 3] = 255;// Alpha
      
      // Track bounding box
      const x = (i / 4) % width;
      const y = Math.floor((i / 4) / width);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    } else {
      // Background: make transparent
      data[i + 3] = 0;
    }
  }
  
  ctx.putImageData(imageData, 0, 0);

  // Crop to bounding box with some padding
  if (maxX > minX && maxY > minY) {
    const padding = 20;
    minX = Math.max(0, minX - padding);
    minY = Math.max(0, minY - padding);
    maxX = Math.min(width, maxX + padding);
    maxY = Math.min(height, maxY + padding);
    
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
