import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/app_lock_guard.dart';
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

/// Processes raw signature images identically to `signature.js`:
/// adaptive brightness thresholding, deep biro blue ink (`RGB(10, 20, 120)`),
/// transparent background, and 20px-padded bounding-box crop.
class SignatureProcessor {
  SignatureProcessor._();

  static const int inkRed = 10;
  static const int inkGreen = 20;
  static const int inkBlue = 120;

  static SignatureScanResult processSignatureBytes(Uint8List inputBytes) {
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode signature image.');
    }

    final oriented = img.bakeOrientation(decoded);
    final width = oriented.width;
    final height = oriented.height;
    final rgba = img.Image(width: width, height: height, numChannels: 4);

    var totalBrightness = 0.0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = oriented.getPixel(x, y);
        totalBrightness += 0.34 * pixel.r + 0.5 * pixel.g + 0.16 * pixel.b;
      }
    }

    final pixelCount = math.max(1, width * height);
    final threshold = (totalBrightness / pixelCount) * 0.85;

    var minX = width;
    var minY = height;
    var maxX = -1;
    var maxY = -1;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = oriented.getPixel(x, y);
        final brightness = 0.34 * pixel.r + 0.5 * pixel.g + 0.16 * pixel.b;
        if (brightness < threshold) {
          rgba.setPixelRgba(x, y, inkRed, inkGreen, inkBlue, 255);
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
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
