import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'app_lock_guard.dart';
import 'theme/app_theme.dart';
import 'user_friendly_error.dart';

/// Result of capturing and extracting a client's Proof-of-Delivery (POD) rubber
/// stamp and receiver sign-off from a white verification slip.
class ClientStampScanResult {
  const ClientStampScanResult({
    required this.stampPngBytes,
    required this.stampDataUri,
    required this.rawPhotoJpegBytes,
    required this.rawPhotoSha256,
    required this.capturedAtIso,
    required this.width,
    required this.height,
    this.receiverName = '',
    this.dominantInkLabel = 'Official Ink',
  });

  final Uint8List stampPngBytes;
  final String stampDataUri;
  final Uint8List rawPhotoJpegBytes;
  final String rawPhotoSha256;
  final String capturedAtIso;
  final int width;
  final int height;
  final String receiverName;
  final String dominantInkLabel;

  ClientStampScanResult withReceiverName(String name) => ClientStampScanResult(
        stampPngBytes: stampPngBytes,
        stampDataUri: stampDataUri,
        rawPhotoJpegBytes: rawPhotoJpegBytes,
        rawPhotoSha256: rawPhotoSha256,
        capturedAtIso: capturedAtIso,
        width: width,
        height: height,
        receiverName: name.trim(),
        dominantInkLabel: dominantInkLabel,
      );
}

/// Multi-spectral chrominance + local-illumination rubber-stamp extractor.
///
/// Unlike monochrome signature thresholding, this preserves the authentic
/// purple/violet, crimson red, royal blue, green, or black rubber-stamp ink
/// AND any overlapping ballpoint receiver signature while turning uneven paper
/// lighting and shadows completely transparent (`alpha = 0`).
class ChrominanceStampProcessor {
  ChrominanceStampProcessor._();

  static ClientStampScanResult processStampBytes(
    Uint8List inputBytes, {
    String receiverName = '',
    DateTime? capturedAt,
  }) {
    final rawSha256 =
        crypto.sha256.convert(inputBytes).toString().toLowerCase();
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode stamp photo.');
    }

    var working = img.bakeOrientation(decoded);
    const maxDim = 1350;
    if (working.width > maxDim || working.height > maxDim) {
      if (working.width >= working.height) {
        working = img.copyResize(
          working,
          width: maxDim,
          interpolation: img.Interpolation.cubic,
        );
      } else {
        working = img.copyResize(
          working,
          height: maxDim,
          interpolation: img.Interpolation.cubic,
        );
      }
    }

    final rawEvidenceJpeg = Uint8List.fromList(
      img.encodeJpg(working, quality: 82),
    );

    final width = working.width;
    final height = working.height;
    final stride = width + 1;
    final intLen = (width + 1) * (height + 1);

    // 3-channel integral images to model local paper white under shadows.
    final intR = Float64List(intLen);
    final intG = Float64List(intLen);
    final intB = Float64List(intLen);

    for (var y = 0; y < height; y++) {
      var sumR = 0.0;
      var sumG = 0.0;
      var sumB = 0.0;
      final prevRow = y * stride;
      final curRow = (y + 1) * stride;
      for (var x = 0; x < width; x++) {
        final p = working.getPixel(x, y);
        sumR += p.r;
        sumG += p.g;
        sumB += p.b;
        intR[curRow + x + 1] = intR[prevRow + x + 1] + sumR;
        intG[curRow + x + 1] = intG[prevRow + x + 1] + sumG;
        intB[curRow + x + 1] = intB[prevRow + x + 1] + sumB;
      }
    }

    final radius = math.max(28, math.min(width, height) ~/ 7);
    final strength = Float32List(width * height);
    final mask = Uint8List(width * height);
    final normR = Uint8List(width * height);
    final normG = Uint8List(width * height);
    final normB = Uint8List(width * height);

    for (var y = 0; y < height; y++) {
      final y0 = math.max(0, y - radius);
      final y1 = math.min(height - 1, y + radius);
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final idx = rowOff + x;
        final p = working.getPixel(x, y);
        if (p.a < 40) continue;

        final x0 = math.max(0, x - radius);
        final x1 = math.min(width - 1, x + radius);
        final area = (x1 - x0 + 1) * (y1 - y0 + 1);

        final i11 = (y1 + 1) * stride + (x1 + 1);
        final i01 = y0 * stride + (x1 + 1);
        final i10 = (y1 + 1) * stride + x0;
        final i00 = y0 * stride + x0;

        final bgR = math.max(45.0, (intR[i11] - intR[i01] - intR[i10] + intR[i00]) / area);
        final bgG = math.max(45.0, (intG[i11] - intG[i01] - intG[i10] + intG[i00]) / area);
        final bgB = math.max(45.0, (intB[i11] - intB[i01] - intB[i10] + intB[i00]) / area);

        // White-balance pixel against local paper illumination to preserve true stamp hue
        final wbR = (p.r * (250.0 / bgR)).clamp(0.0, 255.0);
        final wbG = (p.g * (250.0 / bgG)).clamp(0.0, 255.0);
        final wbB = (p.b * (250.0 / bgB)).clamp(0.0, 255.0);

        final lumBg = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
        final lumPx = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final lumDrop = math.max(0.0, lumBg - lumPx);

        final cMax = math.max(wbR, math.max(wbG, wbB));
        final cMin = math.min(wbR, math.min(wbG, wbB));
        final chromaSpan = cMax - cMin;

        // Combine optical density drop AND chromaticity span so faint red/purple
        // rubber-stamp borders are captured cleanly while grey shadows vanish.
        final s = math.max(lumDrop, 0.88 * chromaSpan);
        strength[idx] = s;
        if (s >= 22.0) {
          mask[idx] = 1;
        }

        // Enhance pigment richness slightly for crisp rendering over white PDF cards
        final meanCh = (wbR + wbG + wbB) / 3.0;
        final boostR = (meanCh + (wbR - meanCh) * 1.28) * 0.82;
        final boostG = (meanCh + (wbG - meanCh) * 1.28) * 0.82;
        final boostB = (meanCh + (wbB - meanCh) * 1.28) * 0.82;
        normR[idx] = boostR.round().clamp(0, 240);
        normG[idx] = boostG.round().clamp(0, 240);
        normB[idx] = boostB.round().clamp(0, 240);
      }
    }

    // Flood-fill erase dark desk/table borders touching the outer image edges
    if (width >= 140 && height >= 140) {
      final qx = Int32List(width * height);
      final qy = Int32List(width * height);
      var head = 0;
      var tail = 0;

      void seed(int sx, int sy) {
        final idx = sy * width + sx;
        if (mask[idx] == 1) {
          mask[idx] = 2;
          qx[tail] = sx;
          qy[tail] = sy;
          tail++;
        }
      }

      for (var x = 0; x < width; x++) {
        seed(x, 0);
        seed(x, height - 1);
      }
      for (var y = 1; y < height - 1; y++) {
        seed(0, y);
        seed(width - 1, y);
      }

      final limitX = (width * 0.16).round();
      final limitY = (height * 0.16).round();
      while (head < tail) {
        final cx = qx[head];
        final cy = qy[head];
        head++;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = cy + dy;
          if (ny < 0 || ny >= height) continue;
          final nearBorderY = ny < limitY || ny >= height - limitY;
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx;
            if (nx < 0 || nx >= width) continue;
            final nearBorderX = nx < limitX || nx >= width - limitX;
            if (!nearBorderX && !nearBorderY) continue;
            final nIdx = ny * width + nx;
            if (mask[nIdx] == 1) {
              mask[nIdx] = 2;
              qx[tail] = nx;
              qy[tail] = ny;
              tail++;
            }
          }
        }
      }
      for (var i = 0; i < mask.length; i++) {
        if (mask[i] == 2) {
          mask[i] = 0;
          strength[i] = 0;
        }
      }
    }

    // Despeckle isolated single-pixel paper grain and compute tight bounding box
    var minX = width;
    var minY = height;
    var maxX = -1;
    var maxY = -1;
    var sumInkR = 0;
    var sumInkG = 0;
    var sumInkB = 0;
    var inkCount = 0;

    final outFull = img.Image(width: width, height: height, numChannels: 4);
    for (var y = 0; y < height; y++) {
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final idx = rowOff + x;
        if (mask[idx] != 1) {
          outFull.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }

        // Check 3x3 neighborhood to drop single-pixel sensor noise
        var neighbors = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= width) continue;
            if (mask[ny * width + nx] == 1) neighbors++;
          }
        }
        if (neighbors <= 2 && strength[idx] < 42.0) {
          outFull.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }

        final alpha = (((strength[idx] - 20.0) / 36.0) * 255.0)
            .round()
            .clamp(45, 255);
        final r = normR[idx];
        final g = normG[idx];
        final b = normB[idx];
        outFull.setPixelRgba(x, y, r, g, b, alpha);

        if (alpha >= 90) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
          sumInkR += r;
          sumInkG += g;
          sumInkB += b;
          inkCount++;
        }
      }
    }

    if (maxX < minX || maxY < minY || inkCount < 20) {
      throw const FormatException(
        'No clear stamp or signature ink detected. Place the stamped white slip in good lighting and try again.',
      );
    }

    const pad = 12;
    final cropX = math.max(0, minX - pad);
    final cropY = math.max(0, minY - pad);
    final cropW = math.min(width - cropX, (maxX - minX + 1) + pad * 2);
    final cropH = math.min(height - cropY, (maxY - minY + 1) + pad * 2);

    var cropped = img.copyCrop(
      outFull,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );
    if (cropped.width > 720) {
      cropped = img.copyResize(
        cropped,
        width: 720,
        interpolation: img.Interpolation.average,
      );
    }

    final pngBytes = Uint8List.fromList(img.encodePng(cropped, level: 6));
    final avgR = sumInkR / inkCount;
    final avgG = sumInkG / inkCount;
    final avgB = sumInkB / inkCount;

    return ClientStampScanResult(
      stampPngBytes: pngBytes,
      stampDataUri: 'data:image/png;base64,${base64Encode(pngBytes)}',
      rawPhotoJpegBytes: rawEvidenceJpeg,
      rawPhotoSha256: rawSha256,
      capturedAtIso: (capturedAt ?? DateTime.now()).toUtc().toIso8601String(),
      width: cropped.width,
      height: cropped.height,
      receiverName: receiverName.trim(),
      dominantInkLabel: _classifyDominantInk(avgR, avgG, avgB),
    );
  }

  static String _classifyDominantInk(double r, double g, double b) {
    if (r > g + 28 && b > g + 22) return 'Violet / Purple Ink';
    if (b > r + 24 && b > g + 20) return 'Royal Blue Ink';
    if (r > g + 32 && r > b + 24) return 'Crimson Red Ink';
    if (g > r + 20 && g > b + 15) return 'Emerald Ink';
    return 'Carbon / Dark Ink';
  }
}

typedef StampImageBytesPicker = Future<Uint8List?> Function(ImageSource source);

/// Dedicated bottom-sheet scanner used in both Owner App and Clerk App to
/// photograph a client's stamped + signed verification slip, remove the paper
/// background while preserving authentic ink color, and punch it onto the order.
class ClientStampScannerSheet extends StatefulWidget {
  const ClientStampScannerSheet({
    super.key,
    required this.clientName,
    this.orderReference = '',
    this.initialReceiverName = '',
    this.imagePicker,
  });

  final String clientName;
  final String orderReference;
  final String initialReceiverName;
  final StampImageBytesPicker? imagePicker;

  static Future<ClientStampScanResult?> show(
    BuildContext context, {
    required String clientName,
    String orderReference = '',
    String initialReceiverName = '',
    StampImageBytesPicker? imagePicker,
  }) {
    return showModalBottomSheet<ClientStampScanResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => ClientStampScannerSheet(
        clientName: clientName,
        orderReference: orderReference,
        initialReceiverName: initialReceiverName,
        imagePicker: imagePicker,
      ),
    );
  }

  @override
  State<ClientStampScannerSheet> createState() =>
      _ClientStampScannerSheetState();
}

class _ClientStampScannerSheetState extends State<ClientStampScannerSheet> {
  final ImagePicker _defaultPicker = ImagePicker();
  late final TextEditingController _receiverCtrl;
  ClientStampScanResult? _scanResult;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _receiverCtrl = TextEditingController(text: widget.initialReceiverName);
  }

  @override
  void dispose() {
    _receiverCtrl.dispose();
    super.dispose();
  }

  Future<Uint8List?> _pickBytes(ImageSource source) async {
    if (widget.imagePicker != null) {
      return widget.imagePicker!(source);
    }
    final picked = await AppLockGuard.runWithoutRelock(
      () => _defaultPicker.pickImage(
        source: source,
        maxWidth: 1800,
        maxHeight: 1800,
        imageQuality: 92,
      ),
    );
    return picked?.readAsBytes();
  }

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _pickBytes(source);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final result = ChrominanceStampProcessor.processStampBytes(
        bytes,
        receiverName: _receiverCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _scanResult = result;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = UserFriendlyError.format(
          e,
          fallback:
              'Could not extract stamp clearly. Place the stamped white slip in good light and try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final refSuffix = widget.orderReference.trim().isNotEmpty
        ? ' • ${widget.orderReference.trim()}'
        : '';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              MediaQuery.viewPaddingOf(context).bottom,
            ) +
            20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppTheme.sageTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.verified_outlined,
                    color: AppTheme.forestGreen,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Absorb Client Delivery Stamp',
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      Text(
                        '${widget.clientName}$refSuffix',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.slateMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSage,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: const Text(
                'Paperless Verification Protocol:\n'
                '1. Client inspects the order and stamps a blank white slip.\n'
                '2. Client signs & writes today\'s date across their stamp.\n'
                '3. Snap a photo below — paper background is removed while keeping their authentic stamp color.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppTheme.slateInk,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('input_pod_receiver_name'),
              controller: _receiverCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Received By (Storekeeper / Chef Name)',
                hintText: 'e.g. John Kamau — Receiving',
                prefixIcon: Icon(Icons.badge_outlined, size: 19),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('btn_capture_stamp_camera'),
                    onPressed:
                        _busy ? null : () => _capture(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Snap Stamp'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('btn_capture_stamp_gallery'),
                    onPressed:
                        _busy ? null : () => _capture(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('From Gallery'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 18),
              const Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(color: AppTheme.forestGreen),
                    SizedBox(height: 8),
                    Text(
                      'Extracting true-color stamp & removing paper background...',
                      style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: AppTheme.danger,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (_scanResult != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.leafGreen, width: 1.4),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Extracted (${_scanResult!.dominantInkLabel})',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.forestGreenDeep,
                          ),
                        ),
                        Text(
                          'SHA-256: ${_scanResult!.rawPhotoSha256.substring(0, 10)}…',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: Image.memory(
                        _scanResult!.stampPngBytes,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('btn_confirm_punch_client_stamp'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.forestGreenDeep,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () {
                  Navigator.of(context).pop(
                    _scanResult!.withReceiverName(_receiverCtrl.text),
                  );
                },
                icon: const Icon(Icons.approval_outlined, size: 19),
                label: const Text('Punch Stamp onto Order'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
