import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../../ui/core/app_lock_guard.dart';
import 'cloudflare_backend_service.dart';
import 'supabase_service.dart';

/// Top-level isolate entrypoint so decoding & downscaling large Android camera
/// photos never blocks the Flutter UI thread.
Uint8List? _prepareCompactJpegIsolate(Uint8List rawBytes) {
  final decoded = img.decodeImage(rawBytes);
  if (decoded == null) return null;
  var oriented = img.bakeOrientation(decoded);
  const maxDim = 960;
  if (oriented.width > maxDim || oriented.height > maxDim) {
    if (oriented.width >= oriented.height) {
      oriented = img.copyResize(
        oriented,
        width: maxDim,
        interpolation: img.Interpolation.linear,
      );
    } else {
      oriented = img.copyResize(
        oriented,
        height: maxDim,
        interpolation: img.Interpolation.linear,
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(oriented, quality: 82));
}

/// Spatial & semantic stamp localization metadata returned by `POST /stamp/locate`
/// (`gemini-3.5-flash-lite` Free Tier via `ttg-api`).
class StampLocationHint {
  const StampLocationHint({
    required this.box2d,
    this.shape = 'rectangle',
    this.uprightClockwiseRotationDeg = 0.0,
    this.stampOrganization = '',
    this.stampDate = '',
    this.receiverOrUser = '',
    this.stampInkColor = '',
    this.hasPrintedFormUnderneath = false,
    this.model = 'gemini-3.5-flash-lite',
  });

  /// Normalized `[ymin, xmin, ymax, xmax]` in `0..1000`.
  final List<double> box2d;

  /// `'oval'`, `'circle'`, or `'rectangle'`.
  final String shape;

  /// Clockwise rotation in degrees (`-180..180`) to make stamp text upright.
  final double uprightClockwiseRotationDeg;

  final String stampOrganization;
  final String stampDate;
  final String receiverOrUser;
  final String stampInkColor;
  final bool hasPrintedFormUnderneath;
  final String model;

  bool get hasValidBox =>
      box2d.length == 4 &&
      box2d[2] > box2d[0] + 15 &&
      box2d[3] > box2d[1] + 15;

  static StampLocationHint? tryParse(Map<String, dynamic> json) {
    final rawBox = json['box_2d'];
    if (rawBox is! List || rawBox.length != 4) return null;
    final parsed = <double>[];
    for (final v in rawBox) {
      if (v is num && v.isFinite) {
        parsed.add(v.toDouble().clamp(0.0, 1000.0));
      } else {
        return null;
      }
    }
    if (parsed[2] <= parsed[0] + 15 || parsed[3] <= parsed[1] + 15) {
      return null;
    }

    final rawShape = (json['shape'] ?? '').toString().trim().toLowerCase();
    final shape = const {'oval', 'circle', 'rectangle'}.contains(rawShape)
        ? rawShape
        : 'rectangle';
    final rawRot = json['upright_clockwise_rotation_deg'];
    final rot = rawRot is num && rawRot.isFinite
        ? rawRot.toDouble().clamp(-180.0, 180.0)
        : 0.0;

    return StampLocationHint(
      box2d: parsed,
      shape: shape,
      uprightClockwiseRotationDeg: rot,
      stampOrganization: (json['stamp_organization'] ?? '').toString().trim(),
      stampDate: (json['stamp_date'] ?? '').toString().trim(),
      receiverOrUser: (json['receiver_or_user'] ?? '').toString().trim(),
      stampInkColor: (json['stamp_ink_color'] ?? '').toString().trim(),
      hasPrintedFormUnderneath: json['has_printed_form_underneath'] == true,
      model: (json['model'] ?? 'gemini-3.5-flash-lite').toString().trim(),
    );
  }
}

/// Abstract gateway for AI-assisted stamp spatial localization.
abstract class StampLocatorGateway {
  Future<StampLocationHint?> locateStamp(Uint8List photoBytes);
}

/// Calls Cloudflare Worker `POST /stamp/locate` using either an authenticated
/// Owner Supabase Bearer token or a valid Clerk invite token.
///
/// Resizes large photos on a background isolate and degrades gracefully to
/// `null` on offline networks, timeouts, or unconfigured server keys so
/// on-device extraction never blocks a delivery.
class CloudflareStampLocatorService implements StampLocatorGateway {
  CloudflareStampLocatorService({
    this.authGateway,
    this.clerkInviteToken,
    this.baseUrl = CloudflareBackendService.defaultBaseUrl,
    this.timeout = const Duration(seconds: 12),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final SupabaseGateway? authGateway;
  final String? clerkInviteToken;
  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  String? lastFallbackReason;

  @override
  Future<StampLocationHint?> locateStamp(Uint8List photoBytes) async {
    lastFallbackReason = null;
    try {
      String? bearerToken;
      if (authGateway != null) {
        final tok = (await authGateway!.getAccessToken())?.trim() ?? '';
        if (tok.isNotEmpty) bearerToken = tok;
      }
      final inviteTok = (clerkInviteToken ?? '').trim();
      if (bearerToken == null && inviteTok.isEmpty) {
        lastFallbackReason = 'No active cloud session — using offline extractor';
        return null;
      }

      final uploadJpeg = Platform.environment.containsKey('FLUTTER_TEST')
          ? _prepareCompactJpegIsolate(photoBytes)
          : await compute(_prepareCompactJpegIsolate, photoBytes);
      if (uploadJpeg == null || uploadJpeg.isEmpty) return null;

      final root = baseUrl.replaceAll(RegExp(r'/+$'), '');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
      };
      final payload = <String, dynamic>{
        'image_base64': base64Encode(uploadJpeg),
        if (bearerToken == null && inviteTok.isNotEmpty)
          'invite_token': inviteTok,
      };

      final res = await _http
          .post(
            Uri.parse('$root/stamp/locate'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (res.statusCode == 503) {
        lastFallbackReason =
            'AI server key not configured yet on Cloudflare (GEMINI_API_KEY) — using offline mode';
        return null;
      }
      if (res.statusCode == 429) {
        lastFallbackReason = 'AI free-tier busy — using offline mode';
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        lastFallbackReason = 'AI locator unavailable (HTTP ${res.statusCode})';
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return StampLocationHint.tryParse(Map<String, dynamic>.from(decoded));
    } catch (_) {
      lastFallbackReason = 'Offline or slow network — using offline mode';
      return null;
    }
  }
}

/// Abstract gateway for on-device paper edge detection & perspective flattening
/// via Google ML Kit Document Scanner (100% free & offline on Android).
abstract class DocumentScannerGateway {
  Future<Uint8List?> scanSinglePage();
}

/// Default Android Google Play Services ML Kit Document Scanner wrapper.
class MlKitDocumentScannerGateway implements DocumentScannerGateway {
  const MlKitDocumentScannerGateway();

  @override
  Future<Uint8List?> scanSinglePage() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormat: DocumentFormat.jpeg,
        mode: ScannerMode.full,
        pageLimit: 1,
        isGalleryImport: true,
      ),
    );
    try {
      final result = await AppLockGuard.runWithoutRelock(
        () => scanner.scanDocument(),
      );
      final images = result.images;
      if (images.isEmpty) return null;
      final file = File(images.first);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } finally {
      await scanner.close().catchError((_) {});
    }
  }
}
