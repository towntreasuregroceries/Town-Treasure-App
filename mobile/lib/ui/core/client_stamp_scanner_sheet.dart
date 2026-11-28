import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/services/stamp_locator_service.dart';
import '../../data/services/supabase_service.dart';
import 'app_lock_guard.dart';
import 'theme/app_theme.dart';
import 'user_friendly_error.dart';

/// Serializable payload for executing `ChrominanceStampProcessor` on a
/// background isolate via [compute] so large Android camera photos NEVER freeze
/// the Flutter UI thread or trigger an ANR.
class _StampProcessRequest {
  const _StampProcessRequest({
    required this.inputBytes,
    required this.receiverName,
    required this.inkClarity,
    this.locationHint,
  });

  final Uint8List inputBytes;
  final String receiverName;
  final double inkClarity;
  final StampLocationHint? locationHint;
}

Future<ClientStampScanResult> _runStampProcess(_StampProcessRequest req) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Future<ClientStampScanResult>(() => _processStampIsolate(req));
  }
  return compute(_processStampIsolate, req);
}

ClientStampScanResult _processStampIsolate(_StampProcessRequest req) {
  return ChrominanceStampProcessor.processStampBytes(
    req.inputBytes,
    receiverName: req.receiverName,
    locationHint: req.locationHint,
    inkClarity: req.inkClarity,
  );
}

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
    this.usedAiLocalization = false,
    this.stampOrganization = '',
    this.stampDate = '',
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
  final bool usedAiLocalization;
  final String stampOrganization;
  final String stampDate;

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
        usedAiLocalization: usedAiLocalization,
        stampOrganization: stampOrganization,
        stampDate: stampDate,
      );
}

/// Multi-spectral chrominance + local-illumination rubber-stamp extractor (v3.1).
///
/// Optimized with integer `Int32List` integral images and bounded working
/// dimensions (`<= 1000px`) for fast, low-memory background-isolate execution.
///
/// Supports two modes:
/// 1. **AI Spatial Hybrid (`locationHint != null`)**: crops real camera pixels
///    to Gemini's `box_2d`, suppresses pale pre-printed form lines via chromatic
///    hue-distance separation, auto-straightens via PCA principal-axis inertia
///    on transparent RGBA (zero black corners), and fits a tight shape-aware
///    oval/circle mask.
/// 2. **Offline Local Mode (`locationHint == null`)**: runs integral-image
///    local paper white-balancing + border flood-fill desk removal + density
///    outlier trimming so isolated paper-edge specks never blow up the crop.
class ChrominanceStampProcessor {
  ChrominanceStampProcessor._();

  /// Estimates the dominant tilt angle (in degrees) of dark stamp ink using
  /// second-order central image moments (PCA principal axis).
  static double estimatePrincipalAxisTiltDeg(img.Image crop) {
    final w = crop.width;
    final h = crop.height;
    var sumW = 0.0;
    var meanX = 0.0;
    var meanY = 0.0;
    final weights = Float32List(w * h);

    for (var y = 0; y < h; y++) {
      final rowOff = y * w;
      for (var x = 0; x < w; x++) {
        final p = crop.getPixel(x, y);
        final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final dark = math.max(0.0, 170.0 - lum);
        if (dark > 40.0) {
          final wt = dark * dark;
          weights[rowOff + x] = wt;
          sumW += wt;
          meanX += x * wt;
          meanY += y * wt;
        }
      }
    }
    if (sumW <= 1.0) return 0.0;
    meanX /= sumW;
    meanY /= sumW;

    var mu20 = 0.0;
    var mu02 = 0.0;
    var mu11 = 0.0;
    for (var y = 0; y < h; y++) {
      final rowOff = y * w;
      for (var x = 0; x < w; x++) {
        final wt = weights[rowOff + x];
        if (wt <= 0) continue;
        final dx = x - meanX;
        final dy = y - meanY;
        mu20 += wt * dx * dx;
        mu02 += wt * dy * dy;
        mu11 += wt * dx * dy;
      }
    }
    final thetaRad = 0.5 * math.atan2(2.0 * mu11, mu20 - mu02);
    return thetaRad * 180.0 / math.pi;
  }

  static ClientStampScanResult processStampBytes(
    Uint8List inputBytes, {
    String receiverName = '',
    DateTime? capturedAt,
    StampLocationHint? locationHint,
    double inkClarity = 0.0,
  }) {
    final rawSha256 =
        crypto.sha256.convert(inputBytes).toString().toLowerCase();
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode stamp photo.');
    }

    final oriented = img.bakeOrientation(decoded);
    final rawEvidenceJpeg = _encodeEvidenceJpeg(oriented);
    final clampedClarity = inkClarity.clamp(-18.0, 28.0);

    if (locationHint != null && locationHint.hasValidBox) {
      return _processWithSpatialHint(
        oriented: oriented,
        rawEvidenceJpeg: rawEvidenceJpeg,
        rawSha256: rawSha256,
        receiverName: receiverName,
        capturedAt: capturedAt,
        hint: locationHint,
        inkClarity: clampedClarity,
      );
    }

    return _processFullFrameOffline(
      oriented: oriented,
      rawEvidenceJpeg: rawEvidenceJpeg,
      rawSha256: rawSha256,
      receiverName: receiverName,
      capturedAt: capturedAt,
      inkClarity: clampedClarity,
    );
  }

  static Uint8List _encodeEvidenceJpeg(img.Image oriented) {
    var ev = oriented;
    const maxDim = 1200;
    if (ev.width > maxDim || ev.height > maxDim) {
      if (ev.width >= ev.height) {
        ev = img.copyResize(
          ev,
          width: maxDim,
          interpolation: img.Interpolation.linear,
        );
      } else {
        ev = img.copyResize(
          ev,
          height: maxDim,
          interpolation: img.Interpolation.linear,
        );
      }
    }
    return Uint8List.fromList(img.encodeJpg(ev, quality: 80));
  }

  static ClientStampScanResult _processWithSpatialHint({
    required img.Image oriented,
    required Uint8List rawEvidenceJpeg,
    required String rawSha256,
    required String receiverName,
    required DateTime? capturedAt,
    required StampLocationHint hint,
    required double inkClarity,
  }) {
    final box = hint.box2d;
    final ymin = (box[0] / 1000.0 * oriented.height)
        .round()
        .clamp(0, oriented.height - 1)
        .toInt();
    final xmin = (box[1] / 1000.0 * oriented.width)
        .round()
        .clamp(0, oriented.width - 1)
        .toInt();
    final ymax = (box[2] / 1000.0 * oriented.height)
        .round()
        .clamp(math.min(oriented.height, ymin + 12), oriented.height)
        .toInt();
    final xmax = (box[3] / 1000.0 * oriented.width)
        .round()
        .clamp(math.min(oriented.width, xmin + 12), oriented.width)
        .toInt();

    final padX = ((xmax - xmin) * 0.03).round();
    final padY = ((ymax - ymin) * 0.03).round();
    final cx0 = math.max(0, xmin - padX);
    final cy0 = math.max(0, ymin - padY);
    final cw = math.min(oriented.width - cx0, (xmax - xmin) + padX * 2);
    final ch = math.min(oriented.height - cy0, (ymax - ymin) + padY * 2);

    var crop = img.copyCrop(oriented, x: cx0, y: cy0, width: cw, height: ch);
    const maxCropDim = 900;
    if (crop.width > maxCropDim || crop.height > maxCropDim) {
      if (crop.width >= crop.height) {
        crop = img.copyResize(
          crop,
          width: maxCropDim,
          interpolation: img.Interpolation.linear,
        );
      } else {
        crop = img.copyResize(
          crop,
          height: maxCropDim,
          interpolation: img.Interpolation.linear,
        );
      }
    }

    var coarseRot = 0.0;
    var fineFallbackRot = hint.uprightClockwiseRotationDeg;
    if (hint.uprightClockwiseRotationDeg.abs() > 45.0) {
      final snapped = ((hint.uprightClockwiseRotationDeg / 90.0).round() * 90)
          .toDouble();
      coarseRot = snapped;
      fineFallbackRot = hint.uprightClockwiseRotationDeg - snapped;
    }

    final width = crop.width;
    final height = crop.height;
    final stride = width + 1;
    final intLen = (width + 1) * (height + 1);
    final intR = Int32List(intLen);
    final intG = Int32List(intLen);
    final intB = Int32List(intLen);

    for (var y = 0; y < height; y++) {
      var sumR = 0;
      var sumG = 0;
      var sumB = 0;
      final prevRow = y * stride;
      final curRow = (y + 1) * stride;
      for (var x = 0; x < width; x++) {
        final p = crop.getPixel(x, y);
        sumR += p.r.toInt();
        sumG += p.g.toInt();
        sumB += p.b.toInt();
        intR[curRow + x + 1] = intR[prevRow + x + 1] + sumR;
        intG[curRow + x + 1] = intG[prevRow + x + 1] + sumG;
        intB[curRow + x + 1] = intB[prevRow + x + 1] + sumB;
      }
    }

    final radius = math.max(24, math.min(width, height) ~/ 6);
    final lumDrops = Float32List(width * height);
    final chromas = Float32List(width * height);
    final normR = Uint8List(width * height);
    final normG = Uint8List(width * height);
    final normB = Uint8List(width * height);
    final wbRList = Float32List(width * height);
    final wbGList = Float32List(width * height);
    final wbBList = Float32List(width * height);

    var coreR = 0.0;
    var coreG = 0.0;
    var coreB = 0.0;
    var coreCount = 0;

    for (var y = 0; y < height; y++) {
      final y0 = math.max(0, y - radius);
      final y1 = math.min(height - 1, y + radius);
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final idx = rowOff + x;
        final p = crop.getPixel(x, y);
        final x0 = math.max(0, x - radius);
        final x1 = math.min(width - 1, x + radius);
        final area = (x1 - x0 + 1) * (y1 - y0 + 1);

        final i11 = (y1 + 1) * stride + (x1 + 1);
        final i01 = y0 * stride + (x1 + 1);
        final i10 = (y1 + 1) * stride + x0;
        final i00 = y0 * stride + x0;

        final bgR =
            math.max(45.0, (intR[i11] - intR[i01] - intR[i10] + intR[i00]) / area);
        final bgG =
            math.max(45.0, (intG[i11] - intG[i01] - intG[i10] + intG[i00]) / area);
        final bgB =
            math.max(45.0, (intB[i11] - intB[i01] - intB[i10] + intB[i00]) / area);

        final wbR = (p.r * (250.0 / bgR)).clamp(0.0, 255.0);
        final wbG = (p.g * (250.0 / bgG)).clamp(0.0, 255.0);
        final wbB = (p.b * (250.0 / bgB)).clamp(0.0, 255.0);
        wbRList[idx] = wbR;
        wbGList[idx] = wbG;
        wbBList[idx] = wbB;

        final lumBg = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
        final lumPx = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final lumDrop = math.max(0.0, lumBg - lumPx);
        final cMax = math.max(wbR, math.max(wbG, wbB));
        final cMin = math.min(wbR, math.min(wbG, wbB));
        lumDrops[idx] = lumDrop;
        chromas[idx] = cMax - cMin;

        final meanCh = (wbR + wbG + wbB) / 3.0;
        normR[idx] =
            ((meanCh + (wbR - meanCh) * 1.32) * 0.80).round().clamp(0, 240);
        normG[idx] =
            ((meanCh + (wbG - meanCh) * 1.32) * 0.80).round().clamp(0, 240);
        normB[idx] =
            ((meanCh + (wbB - meanCh) * 1.32) * 0.80).round().clamp(0, 240);

        if (lumDrop > 78.0 &&
            x > width * 0.18 &&
            x < width * 0.82 &&
            y > height * 0.18 &&
            y < height * 0.82) {
          coreR += wbR;
          coreG += wbG;
          coreB += wbB;
          coreCount++;
        }
      }
    }

    final avgCoreR = coreCount > 20 ? coreR / coreCount : 70.0;
    final avgCoreG = coreCount > 20 ? coreG / coreCount : 70.0;
    final avgCoreB = coreCount > 20 ? coreB / coreCount : 70.0;
    final coreChroma = math.max(avgCoreR, math.max(avgCoreG, avgCoreB)) -
        math.min(avgCoreR, math.min(avgCoreG, avgCoreB));
    final isChromaticStamp = coreChroma >= 14.0;

    final mask = Uint8List(width * height);
    final strength = Float32List(width * height);
    final baseFloor =
        ((hint.hasPrintedFormUnderneath ? 50.0 : 24.0) + inkClarity)
            .clamp(12.0, 95.0);

    for (var y = 0; y < height; y++) {
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final idx = rowOff + x;
        final ld = lumDrops[idx];
        final ch = chromas[idx];

        double score;
        if (hint.hasPrintedFormUnderneath && isChromaticStamp) {
          final dR = wbRList[idx] - avgCoreR;
          final dG = wbGList[idx] - avgCoreG;
          final dB = wbBList[idx] - avgCoreB;
          final colorDist = math.sqrt(dR * dR + dG * dG + dB * dB);
          if (ch < 12.0 && ld < 78.0) {
            score = ld * 0.55;
          } else if (colorDist > 115.0 && ld < 85.0) {
            score = ld * 0.50;
          } else {
            score = ld + ch * 0.45;
          }
        } else {
          score = math.max(ld, 0.88 * ch);
        }

        strength[idx] = score;
        if (score >= baseFloor) {
          mask[idx] = 1;
        }
      }
    }

    final rgbaUnrotated = img.Image(width: width, height: height, numChannels: 4);
    for (var y = 0; y < height; y++) {
      final rowOff = y * width;
      for (var x = 0; x < width; x++) {
        final idx = rowOff + x;
        if (mask[idx] != 1) {
          rgbaUnrotated.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }
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
        if (neighbors <= 2 && strength[idx] < baseFloor + 18.0) {
          rgbaUnrotated.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }
        final alpha = (((strength[idx] - (baseFloor - 6.0)) / 30.0) * 255.0)
            .round()
            .clamp(55, 255);
        rgbaUnrotated.setPixelRgba(
          x,
          y,
          normR[idx],
          normG[idx],
          normB[idx],
          alpha,
        );
      }
    }

    final workingRgba = coarseRot.abs() >= 45.0
        ? img.copyRotate(
            rgbaUnrotated,
            angle: coarseRot,
            interpolation: img.Interpolation.linear,
          )
        : rgbaUnrotated;

    final pcaTilt = coarseRot.abs() >= 45.0
        ? fineFallbackRot
        : estimatePrincipalAxisTiltDeg(crop);
    final fineRot =
        (hint.shape == 'oval' || hint.shape == 'rectangle') &&
                coarseRot.abs() < 45.0 &&
                pcaTilt.abs() <= 35.0
            ? -pcaTilt
            : fineFallbackRot;

    final rotated = fineRot.abs() >= 1.0
        ? img.copyRotate(
            workingRgba,
            angle: fineRot,
            interpolation: img.Interpolation.linear,
          )
        : workingRgba;

    var minX = rotated.width;
    var minY = rotated.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < rotated.height; y++) {
      for (var x = 0; x < rotated.width; x++) {
        if (rotated.getPixel(x, y).a >= 120) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (maxX < minX || maxY < minY) {
      return _processFullFrameOffline(
        oriented: oriented,
        rawEvidenceJpeg: rawEvidenceJpeg,
        rawSha256: rawSha256,
        receiverName: receiverName,
        capturedAt: capturedAt,
        inkClarity: inkClarity,
      );
    }

    if (hint.shape == 'oval' || hint.shape == 'circle') {
      final cx = (minX + maxX) / 2.0;
      final cy = (minY + maxY) / 2.0;
      final rx = math.max(1.0, ((maxX - minX) / 2.0) * 1.015);
      final ry = math.max(1.0, ((maxY - minY) / 2.0) * 1.015);
      for (var y = minY; y <= maxY; y++) {
        for (var x = minX; x <= maxX; x++) {
          final dx = (x - cx) / rx;
          final dy = (y - cy) / ry;
          if (dx * dx + dy * dy > 1.0) {
            rotated.setPixelRgba(x, y, 0, 0, 0, 0);
          }
        }
      }
    }

    var sumInkR = 0;
    var sumInkG = 0;
    var sumInkB = 0;
    var inkCount = 0;
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final p = rotated.getPixel(x, y);
        if (p.a >= 120) {
          sumInkR += p.r.toInt();
          sumInkG += p.g.toInt();
          sumInkB += p.b.toInt();
          inkCount++;
        }
      }
    }
    if (inkCount < 20) {
      throw const FormatException(
        'No clear stamp ink detected inside the located region. Lower the Ink Clarity slider or retake in good light.',
      );
    }

    const pad = 12;
    final cropX = math.max(0, minX - pad);
    final cropY = math.max(0, minY - pad);
    final cropW = math.min(rotated.width - cropX, (maxX - minX + 1) + pad * 2);
    final cropH = math.min(rotated.height - cropY, (maxY - minY + 1) + pad * 2);
    var finalImg = img.copyCrop(
      rotated,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );
    if (finalImg.width > 760) {
      finalImg = img.copyResize(
        finalImg,
        width: 760,
        interpolation: img.Interpolation.average,
      );
    }

    final pngBytes = Uint8List.fromList(img.encodePng(finalImg, level: 4));
    final effectiveReceiver = receiverName.trim().isNotEmpty
        ? receiverName.trim()
        : hint.receiverOrUser.trim();

    return ClientStampScanResult(
      stampPngBytes: pngBytes,
      stampDataUri: 'data:image/png;base64,${base64Encode(pngBytes)}',
      rawPhotoJpegBytes: rawEvidenceJpeg,
      rawPhotoSha256: rawSha256,
      capturedAtIso: (capturedAt ?? DateTime.now()).toUtc().toIso8601String(),
      width: finalImg.width,
      height: finalImg.height,
      receiverName: effectiveReceiver,
      dominantInkLabel: _classifyDominantInk(
        sumInkR / inkCount,
        sumInkG / inkCount,
        sumInkB / inkCount,
      ),
      usedAiLocalization: true,
      stampOrganization: hint.stampOrganization,
      stampDate: hint.stampDate,
    );
  }

  static ClientStampScanResult _processFullFrameOffline({
    required img.Image oriented,
    required Uint8List rawEvidenceJpeg,
    required String rawSha256,
    required String receiverName,
    required DateTime? capturedAt,
    required double inkClarity,
  }) {
    var working = oriented;
    const maxDim = 1000;
    if (working.width > maxDim || working.height > maxDim) {
      if (working.width >= working.height) {
        working = img.copyResize(
          working,
          width: maxDim,
          interpolation: img.Interpolation.linear,
        );
      } else {
        working = img.copyResize(
          working,
          height: maxDim,
          interpolation: img.Interpolation.linear,
        );
      }
    }

    final width = working.width;
    final height = working.height;
    final stride = width + 1;
    final intLen = (width + 1) * (height + 1);

    final intR = Int32List(intLen);
    final intG = Int32List(intLen);
    final intB = Int32List(intLen);

    for (var y = 0; y < height; y++) {
      var sumR = 0;
      var sumG = 0;
      var sumB = 0;
      final prevRow = y * stride;
      final curRow = (y + 1) * stride;
      for (var x = 0; x < width; x++) {
        final p = working.getPixel(x, y);
        sumR += p.r.toInt();
        sumG += p.g.toInt();
        sumB += p.b.toInt();
        intR[curRow + x + 1] = intR[prevRow + x + 1] + sumR;
        intG[curRow + x + 1] = intG[prevRow + x + 1] + sumG;
        intB[curRow + x + 1] = intB[prevRow + x + 1] + sumB;
      }
    }

    final radius = math.max(24, math.min(width, height) ~/ 7);
    final strength = Float32List(width * height);
    final mask = Uint8List(width * height);
    final normR = Uint8List(width * height);
    final normG = Uint8List(width * height);
    final normB = Uint8List(width * height);
    final threshold = (22.0 + inkClarity).clamp(10.0, 68.0);

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

        final bgR =
            math.max(45.0, (intR[i11] - intR[i01] - intR[i10] + intR[i00]) / area);
        final bgG =
            math.max(45.0, (intG[i11] - intG[i01] - intG[i10] + intG[i00]) / area);
        final bgB =
            math.max(45.0, (intB[i11] - intB[i01] - intB[i10] + intB[i00]) / area);

        final wbR = (p.r * (250.0 / bgR)).clamp(0.0, 255.0);
        final wbG = (p.g * (250.0 / bgG)).clamp(0.0, 255.0);
        final wbB = (p.b * (250.0 / bgB)).clamp(0.0, 255.0);

        final lumBg = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
        final lumPx = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final lumDrop = math.max(0.0, lumBg - lumPx);

        final cMax = math.max(wbR, math.max(wbG, wbB));
        final cMin = math.min(wbR, math.min(wbG, wbB));
        final chromaSpan = cMax - cMin;

        final s = math.max(lumDrop, 0.88 * chromaSpan);
        strength[idx] = s;
        if (s >= threshold) {
          mask[idx] = 1;
        }

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

    final rowCounts = Int32List(height);
    final colCounts = Int32List(width);
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
        if (neighbors <= 2 && strength[idx] < threshold + 20.0) {
          outFull.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }

        final alpha = (((strength[idx] - (threshold - 2.0)) / 36.0) * 255.0)
            .round()
            .clamp(45, 255);
        final r = normR[idx];
        final g = normG[idx];
        final b = normB[idx];
        outFull.setPixelRgba(x, y, r, g, b, alpha);

        if (alpha >= 90) {
          rowCounts[y]++;
          colCounts[x]++;
          sumInkR += r;
          sumInkG += g;
          sumInkB += b;
          inkCount++;
        }
      }
    }

    if (inkCount < 20) {
      throw const FormatException(
        'No clear stamp or signature ink detected. Place the stamped white slip in good lighting and try again.',
      );
    }

    // Trim sparse outer outlier specks (0.5% cumulative ink margin) so a
    // stray edge speck never blows up the crop and makes the stamp look tiny.
    final trimMargin = math.max(1, (inkCount * 0.005).round());
    var minY = 0;
    var acc = 0;
    while (minY < height - 1 && acc + rowCounts[minY] < trimMargin) {
      acc += rowCounts[minY];
      minY++;
    }
    var maxY = height - 1;
    acc = 0;
    while (maxY > minY && acc + rowCounts[maxY] < trimMargin) {
      acc += rowCounts[maxY];
      maxY--;
    }
    var minX = 0;
    acc = 0;
    while (minX < width - 1 && acc + colCounts[minX] < trimMargin) {
      acc += colCounts[minX];
      minX++;
    }
    var maxX = width - 1;
    acc = 0;
    while (maxX > minX && acc + colCounts[maxX] < trimMargin) {
      acc += colCounts[maxX];
      maxX--;
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

    final pngBytes = Uint8List.fromList(img.encodePng(cropped, level: 4));
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
      usedAiLocalization: false,
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

class _CheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 10.0;
    final light = Paint()..color = const Color(0xFFFFFFFF);
    final dark = Paint()..color = const Color(0xFFF1F5F2);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0.0; y < size.height; y += cell) {
      final row = (y ~/ cell);
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x ~/ cell) + row).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

typedef StampImageBytesPicker = Future<Uint8List?> Function(ImageSource source);

/// Dedicated bottom-sheet scanner used in both Owner App and Clerk App to
/// photograph or ML-Kit-scan a client's stamped + signed verification slip,
/// localize the rubber stamp via Gemini AI Studio Free Tier (`POST /stamp/locate`)
/// with automatic offline fallback, auto-straighten + remove paper background
/// on a background isolate (zero UI freezes), and punch it onto the order.
class ClientStampScannerSheet extends StatefulWidget {
  const ClientStampScannerSheet({
    super.key,
    required this.clientName,
    this.orderReference = '',
    this.initialReceiverName = '',
    this.imagePicker,
    this.stampLocator,
    this.documentScanner,
    this.clerkInviteToken,
  });

  final String clientName;
  final String orderReference;
  final String initialReceiverName;
  final StampImageBytesPicker? imagePicker;
  final StampLocatorGateway? stampLocator;
  final DocumentScannerGateway? documentScanner;
  final String? clerkInviteToken;

  static Future<ClientStampScanResult?> show(
    BuildContext context, {
    required String clientName,
    String orderReference = '',
    String initialReceiverName = '',
    StampImageBytesPicker? imagePicker,
    StampLocatorGateway? stampLocator,
    DocumentScannerGateway? documentScanner,
    String? clerkInviteToken,
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
        stampLocator: stampLocator,
        documentScanner: documentScanner,
        clerkInviteToken: clerkInviteToken,
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
  Uint8List? _lastRawBytes;
  StampLocationHint? _lastLocationHint;
  String? _fallbackNote;
  double _inkClarity = 0.0;
  bool _busy = false;
  bool _reprocessingSlider = false;
  int _processGen = 0;
  String _busyMessage = 'Extracting true-color stamp...';
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

  StampLocatorGateway? _resolveLocator() {
    if (widget.stampLocator != null) return widget.stampLocator;
    SupabaseGateway? auth;
    try {
      auth = context.read<SupabaseGateway?>();
    } catch (_) {
      auth = null;
    }
    final invite = (widget.clerkInviteToken ?? '').trim();
    if (auth == null && invite.isEmpty) return null;
    return CloudflareStampLocatorService(
      authGateway: auth,
      clerkInviteToken: invite.isNotEmpty ? invite : null,
    );
  }

  DocumentScannerGateway _resolveDocScanner() =>
      widget.documentScanner ?? const MlKitDocumentScannerGateway();

  Future<Uint8List?> _pickBytes(ImageSource source) async {
    if (widget.imagePicker != null) {
      return widget.imagePicker!(source);
    }
    final picked = await AppLockGuard.runWithoutRelock(
      () => _defaultPicker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      ),
    );
    return picked?.readAsBytes();
  }

  Future<void> _processCapturedBytes(Uint8List bytes) async {
    final gen = ++_processGen;
    setState(() {
      _busy = true;
      _error = null;
      _fallbackNote = null;
      _busyMessage = 'Locating official stamp & straightening...';
    });

    StampLocationHint? hint;
    String? fallbackReason;
    final locator = _resolveLocator();
    if (locator != null) {
      hint = await locator.locateStamp(bytes);
      if (hint == null && locator is CloudflareStampLocatorService) {
        fallbackReason = locator.lastFallbackReason;
      }
    }

    if (!mounted || gen != _processGen) return;
    setState(() {
      _busyMessage = hint != null
          ? 'Separating true-color stamp ink from background...'
          : 'Extracting stamp cleanly in background...';
    });

    final result = await _runStampProcess(
      _StampProcessRequest(
        inputBytes: bytes,
        receiverName: _receiverCtrl.text,
        locationHint: hint,
        inkClarity: 0.0,
      ),
    );
    if (!mounted || gen != _processGen) return;

    if (_receiverCtrl.text.trim().isEmpty &&
        result.receiverName.trim().isNotEmpty) {
      _receiverCtrl.text = result.receiverName.trim();
    }

    setState(() {
      _lastRawBytes = bytes;
      _lastLocationHint = hint;
      _fallbackNote = hint == null ? fallbackReason : null;
      _inkClarity = 0.0;
      _scanResult = result;
      _busy = false;
    });
  }

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
      _busyMessage = 'Opening camera...';
    });
    try {
      final bytes = await _pickBytes(source);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await _processCapturedBytes(bytes);
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

  Future<void> _captureWithMlKitScanner() async {
    setState(() {
      _busy = true;
      _error = null;
      _busyMessage = 'Launching ML Kit Document Scanner...';
    });
    try {
      final bytes = await _resolveDocScanner().scanSinglePage();
      if (bytes == null || bytes.isEmpty) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await _processCapturedBytes(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = UserFriendlyError.format(
          e,
          fallback:
              'Document scanner is unavailable on this device. Use Snap Stamp or Gallery instead.',
        );
      });
    }
  }

  Future<void> _reprocessWithClarity(double clarity) async {
    final raw = _lastRawBytes;
    if (raw == null) return;
    final gen = ++_processGen;
    setState(() {
      _inkClarity = clarity;
      _reprocessingSlider = true;
    });
    try {
      final result = await _runStampProcess(
        _StampProcessRequest(
          inputBytes: raw,
          receiverName: _receiverCtrl.text,
          locationHint: _lastLocationHint,
          inkClarity: clarity,
        ),
      );
      if (!mounted || gen != _processGen) return;
      setState(() {
        _scanResult = result;
        _reprocessingSlider = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || gen != _processGen) return;
      setState(() {
        _reprocessingSlider = false;
        _error = 'Clarity too high — slide left to restore faint stamp ink.';
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
                '3. Snap a photo or scan the slip — AI isolates, straightens, and strips the background automatically (works offline too).',
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
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('btn_capture_stamp_mlkit'),
                    onPressed: _busy ? null : _captureWithMlKitScanner,
                    icon: const Icon(Icons.document_scanner_outlined, size: 18),
                    label: const Text('Scan Slip'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('btn_capture_stamp_gallery'),
              onPressed: _busy ? null : () => _capture(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Choose Photo From Gallery'),
            ),
            if (_busy) ...[
              const SizedBox(height: 18),
              Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(
                      color: AppTheme.forestGreen,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _busyMessage,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                      ),
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Container(
                            key: const Key('badge_stamp_extraction_mode'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _scanResult!.usedAiLocalization
                                  ? AppTheme.sageTint
                                  : AppTheme.surfaceSage,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _scanResult!.usedAiLocalization
                                  ? 'AI Localized • ${_scanResult!.dominantInkLabel}'
                                  : 'Offline Local • ${_scanResult!.dominantInkLabel}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.forestGreenDeep,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'SHA: ${_scanResult!.rawPhotoSha256.substring(0, 8)}…',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                    if (_fallbackNote != null &&
                        _fallbackNote!.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        _fallbackNote!,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                    ],
                    if (_scanResult!.stampOrganization.isNotEmpty ||
                        _scanResult!.stampDate.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        [
                          if (_scanResult!.stampOrganization.isNotEmpty)
                            _scanResult!.stampOrganization,
                          if (_scanResult!.stampDate.isNotEmpty)
                            _scanResult!.stampDate,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.slateMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CustomPaint(
                        painter: _CheckerboardPainter(),
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: 110,
                            maxHeight: 165,
                          ),
                          padding: const EdgeInsets.all(8),
                          alignment: Alignment.center,
                          child: _reprocessingSlider
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: AppTheme.forestGreen,
                                  ),
                                )
                              : Image.memory(
                                  _scanResult!.stampPngBytes,
                                  fit: BoxFit.contain,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text(
                          'Ink Clarity',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            key: const Key('slider_stamp_ink_clarity'),
                            value: _inkClarity,
                            min: -16.0,
                            max: 24.0,
                            divisions: 20,
                            activeColor: AppTheme.forestGreen,
                            onChanged: (v) => setState(() => _inkClarity = v),
                            onChangeEnd: (v) => _reprocessWithClarity(v),
                          ),
                        ),
                        Text(
                          _inkClarity == 0
                              ? 'Auto'
                              : (_inkClarity > 0
                                  ? '+${_inkClarity.round()}'
                                  : '${_inkClarity.round()}'),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
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
                onPressed: _reprocessingSlider
                    ? null
                    : () {
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
