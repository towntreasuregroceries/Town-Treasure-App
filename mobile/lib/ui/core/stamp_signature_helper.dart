import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Shared image enhancer for Town Treasure corporate stamps and handwritten
/// authorization signatures across PDF builders and live previews.
///
/// Solves two real-world rendering issues:
/// 1. `assets/stamp.png` sits inside a 500x500 square with ~35% empty outer
///    margin, which previously shrank the visible emblem inside PDF stamp boxes
///    and washed out dark green ink when converted naively to grayscale.
/// 2. Saved camera-scanned signatures often carry wide transparent margins,
///    stray dust specks that inflate the bounding box, or thin high-res pen
///    strokes that look faint when downscaled to A4 stamp dimensions.
class StampSignatureHelper {
  StampSignatureHelper._();

  static const int inkRed = 10;
  static const int inkGreen = 20;
  static const int inkBlue = 120;

  static int? _cachedStampKey;
  static Uint8List? _cachedStampPng;

  static String? _cachedSigUri;
  static Uint8List? _cachedSigPng;

  /// Tight-crops `stamp.png` around its visible emblem and converts the dark
  /// forest-green textured stamp into high-contrast charcoal stamp ink.
  static Uint8List? prepareStampPng(Uint8List? rawBytes) {
    if (rawBytes == null || rawBytes.isEmpty) return null;
    final key = Object.hash(
      rawBytes.length,
      rawBytes.first,
      rawBytes[rawBytes.length ~/ 2],
      rawBytes.last,
    );
    if (_cachedStampKey == key && _cachedStampPng != null) {
      return _cachedStampPng;
    }

    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return rawBytes;

      final w = decoded.width;
      final h = decoded.height;
      final out = img.Image(width: w, height: h, numChannels: 4);

      var minX = w;
      var minY = h;
      var maxX = -1;
      var maxY = -1;

      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = decoded.getPixel(x, y);
          final a = p.a.toInt();
          if (a < 18) {
            out.setPixelRgba(x, y, 0, 0, 0, 0);
            continue;
          }
          final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          if (lum > 246) {
            out.setPixelRgba(x, y, 0, 0, 0, 0);
            continue;
          }

          // Boost midtone ink density so textured stamp letters stay crisp
          final darkened = (lum * 0.52).round().clamp(12, 165);
          final boostedAlpha = math.min(255, (a * 1.12).round());
          out.setPixelRgba(x, y, darkened, darkened, darkened, boostedAlpha);

          if (boostedAlpha > 35 && lum < 235) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }

      var cropped = out;
      if (maxX >= minX && maxY >= minY) {
        const pad = 6;
        final cx = math.max(0, minX - pad);
        final cy = math.max(0, minY - pad);
        final cr = math.min(w - 1, maxX + pad);
        final cb = math.min(h - 1, maxY + pad);
        cropped = img.copyCrop(
          out,
          x: cx,
          y: cy,
          width: math.max(1, cr - cx + 1),
          height: math.max(1, cb - cy + 1),
        );
      }

      final encoded = Uint8List.fromList(img.encodePng(cropped));
      _cachedStampKey = key;
      _cachedStampPng = encoded;
      return encoded;
    } catch (_) {
      return rawBytes;
    }
  }

  /// Decodes a `data:image/...;base64,...` URI and tight-crops + enhances the
  /// signature so even previously saved faint/uncropped signatures render crisp
  /// and legible inside PDF and UI stamp boxes.
  static Uint8List? prepareSignaturePng(String? signatureDataUri) {
    if (signatureDataUri == null || signatureDataUri.trim().isEmpty) {
      return null;
    }
    final trimmed = signatureDataUri.trim();
    if (_cachedSigUri == trimmed && _cachedSigPng != null) {
      return _cachedSigPng;
    }

    final raw = decodeRawSignatureDataUri(trimmed);
    if (raw == null || raw.isEmpty) return null;

    final enhanced = enhanceDecodedSignatureBytes(raw);
    _cachedSigUri = trimmed;
    _cachedSigPng = enhanced;
    return enhanced;
  }

  /// Raw base64 data-URI decoder matching `InvoicePdfBuilder.decodeSignatureDataUrl`.
  static Uint8List? decodeRawSignatureDataUri(String? signature) {
    if (signature == null || signature.trim().isEmpty) return null;
    final trimmed = signature.trim();
    final match = RegExp(
      r'^data:image\/(?:png|jpe?g|webp|gif);base64,([A-Za-z0-9+/=\s]+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) return null;
    try {
      final cleanB64 = match.group(1)!.replaceAll(RegExp(r'\s+'), '');
      return base64Decode(cleanB64);
    } catch (_) {
      return null;
    }
  }

  /// Cleans, despeckles, tight-crops, auto-rotates, and strengthens thin camera
  /// strokes on an already-thresholded or transparent signature PNG.
  static Uint8List enhanceDecodedSignatureBytes(Uint8List rawBytes) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return rawBytes;

      final w = decoded.width;
      final h = decoded.height;
      // Leave tiny synthetic test images (e.g. 1x1 fixtures) untouched.
      if (w < 16 || h < 16) return rawBytes;

      final mask = Uint8List(w * h);
      var rawInkCount = 0;
      for (var y = 0; y < h; y++) {
        final rowOff = y * w;
        for (var x = 0; x < w; x++) {
          final p = decoded.getPixel(x, y);
          final a = p.a.toInt();
          final lum = 0.34 * p.r + 0.5 * p.g + 0.16 * p.b;
          if (a >= 35 && lum < 235) {
            mask[rowOff + x] = 1;
            rawInkCount++;
          }
        }
      }

      if (rawInkCount == 0) return rawBytes;

      // Remove isolated dust specks on larger images so stray pixels never
      // prevent tight cropping around the actual signature strokes.
      if (w >= 48 && h >= 48) {
        final cleaned = Uint8List.fromList(mask);
        for (var y = 1; y < h - 1; y++) {
          final r = y * w;
          for (var x = 1; x < w - 1; x++) {
            final idx = r + x;
            if (mask[idx] == 0) continue;
            final neighbors = mask[idx - 1] +
                mask[idx + 1] +
                mask[idx - w] +
                mask[idx + w] +
                mask[idx - w - 1] +
                mask[idx - w + 1] +
                mask[idx + w - 1] +
                mask[idx + w + 1];
            if (neighbors < 2) {
              cleaned[idx] = 0;
            }
          }
        }
        for (var i = 0; i < mask.length; i++) {
          mask[i] = cleaned[i];
        }
      }

      var minX = w;
      var minY = h;
      var maxX = -1;
      var maxY = -1;
      var keptCount = 0;

      for (var y = 0; y < h; y++) {
        final r = y * w;
        for (var x = 0; x < w; x++) {
          if (mask[r + x] == 1) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
            keptCount++;
          }
        }
      }

      if (keptCount == 0 || maxX < minX || maxY < minY) {
        return rawBytes;
      }

      final cropSpan = math.max(maxX - minX + 1, maxY - minY + 1);
      // Gently thicken ultra-thin high-res camera strokes so they stay bold
      // and legible when scaled down to a 44pt PDF stamp box.
      if (cropSpan >= 280) {
        final dilated = Uint8List.fromList(mask);
        final radius = cropSpan >= 700 ? 2 : 1;
        for (var y = minY; y <= maxY; y++) {
          final r = y * w;
          for (var x = minX; x <= maxX; x++) {
            if (mask[r + x] == 0) continue;
            for (var dy = -radius; dy <= radius; dy++) {
              final ny = y + dy;
              if (ny < 0 || ny >= h) continue;
              final nr = ny * w;
              for (var dx = -radius; dx <= radius; dx++) {
                if (dx * dx + dy * dy > radius * radius + 1) continue;
                final nx = x + dx;
                if (nx >= 0 && nx < w) {
                  dilated[nr + nx] = 1;
                }
              }
            }
          }
        }
        for (var i = 0; i < mask.length; i++) {
          mask[i] = dilated[i];
        }
      }

      final pad = math.max(6, (cropSpan * 0.03).round().clamp(6, 18));
      final cx = math.max(0, minX - pad);
      final cy = math.max(0, minY - pad);
      final cr = math.min(w - 1, maxX + pad);
      final cb = math.min(h - 1, maxY + pad);
      final cw = math.max(1, cr - cx + 1);
      final ch = math.max(1, cb - cy + 1);

      var out = img.Image(width: cw, height: ch, numChannels: 4);
      for (var y = 0; y < ch; y++) {
        final srcRow = (cy + y) * w;
        for (var x = 0; x < cw; x++) {
          if (mask[srcRow + cx + x] == 1) {
            out.setPixelRgba(x, y, inkRed, inkGreen, inkBlue, 255);
          } else {
            out.setPixelRgba(x, y, 0, 0, 0, 0);
          }
        }
      }

      // Auto-rotate vertical phone captures of horizontal signatures.
      if (ch > cw * 1.35 && ch >= 80) {
        out = img.copyRotate(out, angle: -90);
      }

      return Uint8List.fromList(img.encodePng(out));
    } catch (_) {
      return rawBytes;
    }
  }
}
