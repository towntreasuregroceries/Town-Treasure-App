import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/app_lock_guard.dart';
import '../../core/stamp_signature_helper.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';

/// Result of thresholding and cropping a scanned signature image.
class SignatureScanResult {
  const SignatureScanResult({
    required this.pngBytes,
    required this.dataUri,
    required this.width,
    required this.height,
  });

  final Uint8List pngBytes;
  final String dataUri;
  final int width;
  final int height;
}

/// Processes raw signature images with local illumination leveling, border
/// shadow/table-edge removal, despeckling, deep biro blue ink (`RGB(10, 20, 120)`),
/// transparent background, auto-rotation, and 20px-padded bounding-box crop.
class SignatureProcessor {
  SignatureProcessor._();

  static const int inkRed = StampSignatureHelper.inkRed;
  static const int inkGreen = StampSignatureHelper.inkGreen;
  static const int inkBlue = StampSignatureHelper.inkBlue;

  static SignatureScanResult processSignatureBytes(Uint8List inputBytes) {
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode signature image.');
    }

    final oriented = img.bakeOrientation(decoded);
    final width = oriented.width;
    final height = oriented.height;
    final pixelCount = math.max(1, width * height);

    final lum = Float64List(width * height);
    var opaqueCount = 0;
    var totalBrightness = 0.0;

    for (var y = 0; y < height; y++) {
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final p = oriented.getPixel(x, y);
        final b = 0.34 * p.r + 0.5 * p.g + 0.16 * p.b;
        lum[rowOff + x] = b;
        if (p.a >= 50) {
          totalBrightness += b;
          opaqueCount++;
        }
      }
    }

    final isPhoto = (opaqueCount / pixelCount) > 0.5;
    final avgBrightness =
        opaqueCount > 0 ? (totalBrightness / opaqueCount) : 255.0;
    final isDarkBackground = isPhoto && avgBrightness < 115.0;
    final inkMap = Uint8List(width * height);

    if (isPhoto) {
      // Integral-image local illumination map so uneven phone shadows across
      // paper do not turn into ink blocks or prevent tight cropping.
      final stride = width + 1;
      final integral = Float64List((width + 1) * (height + 1));
      for (var y = 0; y < height; y++) {
        var rowSum = 0.0;
        final srcRow = y * width;
        final prevIntRow = y * stride;
        final curIntRow = (y + 1) * stride;
        for (var x = 0; x < width; x++) {
          rowSum += lum[srcRow + x];
          integral[curIntRow + x + 1] = integral[prevIntRow + x + 1] + rowSum;
        }
      }

      final radius = math.max(24, math.min(width, height) ~/ 8);
      for (var y = 0; y < height; y++) {
        final y0 = math.max(0, y - radius);
        final y1 = math.min(height - 1, y + radius);
        final srcRow = y * width;
        for (var x = 0; x < width; x++) {
          final p = oriented.getPixel(x, y);
          if (p.a < 50) continue;

          final x0 = math.max(0, x - radius);
          final x1 = math.min(width - 1, x + radius);
          final area = (x1 - x0 + 1) * (y1 - y0 + 1);
          final sum = integral[(y1 + 1) * stride + (x1 + 1)] -
              integral[y0 * stride + (x1 + 1)] -
              integral[(y1 + 1) * stride + x0] +
              integral[y0 * stride + x0];
          final localBg = sum / area;
          final b = lum[srcRow + x];

          bool isInk;
          if (isDarkBackground) {
            final cMax = math.max(p.r, math.max(p.g, p.b)).toDouble();
            final cMin = math.min(p.r, math.min(p.g, p.b)).toDouble();
            final sat = cMax > 0 ? (cMax - cMin) / cMax : 0.0;
            isInk = (b > localBg + 16) || (sat > 0.16 && cMax > 24);
          } else {
            isInk = b < (localBg - 22);
          }
          if (isInk) {
            inkMap[srcRow + x] = 1;
          }
        }
      }

      // Erase dark table edges connected to the outer border of camera photos.
      if (width >= 160 && height >= 160) {
        final qx = Int32List(width * height);
        final qy = Int32List(width * height);
        var head = 0;
        var tail = 0;

        void seed(int sx, int sy) {
          final idx = sy * width + sx;
          if (inkMap[idx] == 1) {
            inkMap[idx] = 0;
            qx[tail] = sx;
            qy[tail] = sy;
            tail++;
          }
        }

        for (var x = 0; x < width; x++) {
          seed(x, 0);
          seed(x, height - 1);
        }
        for (var y = 0; y < height; y++) {
          seed(0, y);
          seed(width - 1, y);
        }

        while (head < tail) {
          final px = qx[head];
          final py = qy[head];
          head++;
          if (px > 0) seed(px - 1, py);
          if (px + 1 < width) seed(px + 1, py);
          if (py > 0) seed(px, py - 1);
          if (py + 1 < height) seed(px, py + 1);
        }

        // Despeckle isolated camera noise pixels before computing crop bounds.
        final cleaned = Uint8List.fromList(inkMap);
        for (var y = 1; y < height - 1; y++) {
          final r = y * width;
          for (var x = 1; x < width - 1; x++) {
            final idx = r + x;
            if (inkMap[idx] == 0) continue;
            final neighbors = inkMap[idx - 1] +
                inkMap[idx + 1] +
                inkMap[idx - width] +
                inkMap[idx + width] +
                inkMap[idx - width - 1] +
                inkMap[idx - width + 1] +
                inkMap[idx + width - 1] +
                inkMap[idx + width + 1];
            if (neighbors < 2) {
              cleaned[idx] = 0;
            }
          }
        }
        for (var i = 0; i < inkMap.length; i++) {
          inkMap[i] = cleaned[i];
        }
      }
    } else {
      // Transparent digital drawing: normalize existing opaque strokes.
      for (var y = 0; y < height; y++) {
        final r = y * width;
        for (var x = 0; x < width; x++) {
          if (oriented.getPixel(x, y).a >= 50) {
            inkMap[r + x] = 1;
          }
        }
      }
    }

    var minX = width;
    var minY = height;
    var maxX = -1;
    var maxY = -1;

    for (var y = 0; y < height; y++) {
      final r = y * width;
      for (var x = 0; x < width; x++) {
        if (inkMap[r + x] == 1) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }

    // Strengthen thin high-res camera strokes so signatures print bold & clear.
    final cropSpan =
        (maxX >= minX && maxY >= minY) ? math.max(maxX - minX, maxY - minY) : 0;
    if (isPhoto && cropSpan >= 300) {
      final dilated = Uint8List.fromList(inkMap);
      for (var y = math.max(1, minY); y <= math.min(height - 2, maxY); y++) {
        final r = y * width;
        for (var x = math.max(1, minX); x <= math.min(width - 2, maxX); x++) {
          if (inkMap[r + x] == 0) continue;
          dilated[r + x - 1] = 1;
          dilated[r + x + 1] = 1;
          dilated[r - width + x] = 1;
          dilated[r + width + x] = 1;
        }
      }
      for (var i = 0; i < inkMap.length; i++) {
        inkMap[i] = dilated[i];
      }
    }

    final rgba = img.Image(width: width, height: height, numChannels: 4);
    for (var y = 0; y < height; y++) {
      final r = y * width;
      for (var x = 0; x < width; x++) {
        if (inkMap[r + x] == 1) {
          rgba.setPixelRgba(x, y, inkRed, inkGreen, inkBlue, 255);
        } else {
          rgba.setPixelRgba(x, y, 0, 0, 0, 0);
        }
      }
    }

    var finalImage = rgba;
    if (maxX >= minX && maxY >= minY) {
      const pad = 20;
      final cropX = math.max(0, minX - pad);
      final cropY = math.max(0, minY - pad);
      final cropRight = math.min(width - 1, maxX + pad);
      final cropBottom = math.min(height - 1, maxY + pad);
      final cropW = math.max(1, cropRight - cropX + 1);
      final cropH = math.max(1, cropBottom - cropY + 1);
      finalImage = img.copyCrop(
        rgba,
        x: cropX,
        y: cropY,
        width: cropW,
        height: cropH,
      );

      // Auto-rotate vertical phone photos of horizontal signatures.
      if (isPhoto && width >= 200 && cropH > cropW * 1.25) {
        finalImage = img.copyRotate(finalImage, angle: -90);
      }
      if (finalImage.width > 900 || finalImage.height > 900) {
        final scale = 900.0 / math.max(finalImage.width, finalImage.height);
        finalImage = img.copyResize(
          finalImage,
          width: math.max(1, (finalImage.width * scale).round()),
          height: math.max(1, (finalImage.height * scale).round()),
        );
      }
    }

    final pngBytes = Uint8List.fromList(img.encodePng(finalImage));
    final dataUri = 'data:image/png;base64,${base64Encode(pngBytes)}';
    return SignatureScanResult(
      pngBytes: pngBytes,
      dataUri: dataUri,
      width: finalImage.width,
      height: finalImage.height,
    );
  }

  /// Decodes a `data:image/png;base64,...` URI into bytes, or `null` if invalid.
  static Uint8List? decodeDataUri(String? dataUri) {
    if (dataUri == null || dataUri.isEmpty) return null;
    final comma = dataUri.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

typedef ImageBytesPicker = Future<Uint8List?> Function(ImageSource source);

/// Modal bottom sheet to scan, threshold, preview, and save the owner's
/// signature to `VaultSettings.signature`.
class SignatureScannerSheet extends StatefulWidget {
  const SignatureScannerSheet({
    super.key,
    required this.initialSignatureUri,
    required this.onSaveSignature,
    this.imagePicker,
  });

  final String? initialSignatureUri;
  final Future<void> Function(String? dataUri) onSaveSignature;
  final ImageBytesPicker? imagePicker;

  @override
  State<SignatureScannerSheet> createState() => _SignatureScannerSheetState();
}

class _SignatureScannerSheetState extends State<SignatureScannerSheet> {
  final ImagePicker _defaultPicker = ImagePicker();

  Uint8List? _previewBytes;
  String? _pendingDataUri;
  bool _hasChanges = false;
  bool _isProcessing = false;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _previewBytes = SignatureProcessor.decodeDataUri(widget.initialSignatureUri);
    _pendingDataUri = widget.initialSignatureUri;
  }

  Future<Uint8List?> _pickBytes(ImageSource source) async {
    if (widget.imagePicker != null) {
      return widget.imagePicker!(source);
    }
    final picked = await AppLockGuard.runWithoutRelock(
      () => _defaultPicker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      ),
    );
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  Future<void> _captureAndProcess(ImageSource source) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    try {
      final rawBytes = await _pickBytes(source);
      if (rawBytes == null) {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
        return;
      }
      final result = SignatureProcessor.processSignatureBytes(rawBytes);
      if (!mounted) return;
      setState(() {
        _previewBytes = result.pngBytes;
        _pendingDataUri = result.dataUri;
        _hasChanges = true;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not process signature image. Try a clearer photo.';
        _isProcessing = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await widget.onSaveSignature(_pendingDataUri);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not save signature: ${UserFriendlyError.format(e)}';
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: 20 +
              math.max(
                MediaQuery.viewInsetsOf(context).bottom,
                math.max(
                  MediaQuery.viewPaddingOf(context).bottom,
                  MediaQuery.paddingOf(context).bottom,
                ),
              ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.draw_outlined, color: AppTheme.forestGreen),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'My Signature',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateDark,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Sign on blank white paper, then take a photo or choose from your gallery. Background paper is removed and ink is tinted deep biro blue.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.slateMuted,
                  ),
            ),
            const SizedBox(height: 16),
            Container(
              height: 190,
              decoration: BoxDecoration(
                color: AppTheme.surfaceSage,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_previewBytes != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Image.memory(
                        _previewBytes!,
                        fit: BoxFit.contain,
                      ),
                    )
                  else
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.gesture_outlined,
                          size: 44,
                          color: AppTheme.slateMuted.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Your processed signature will appear here',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.slateMuted,
                              ),
                        ),
                      ],
                    ),
                  if (_isProcessing)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 10),
                            Text('Removing background...'),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                style: const TextStyle(color: AppTheme.danger, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('btn_sig_camera'),
                    onPressed: _isProcessing || _isSaving
                        ? null
                        : () => _captureAndProcess(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Take Photo'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('btn_sig_gallery'),
                    onPressed: _isProcessing || _isSaving
                        ? null
                        : () => _captureAndProcess(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_previewBytes != null)
                  TextButton.icon(
                    key: const Key('btn_sig_clear'),
                    onPressed: _isProcessing || _isSaving
                        ? null
                        : () {
                            setState(() {
                              _previewBytes = null;
                              _pendingDataUri = null;
                              _hasChanges = true;
                            });
                          },
                    icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
                    label: const Text(
                      'Remove',
                      style: TextStyle(color: AppTheme.danger),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('btn_sig_save'),
                  onPressed: (!_hasChanges || _isProcessing || _isSaving)
                      ? null
                      : _save,
                  child: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save to Vault'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
