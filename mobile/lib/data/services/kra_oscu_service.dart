import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/models.dart';
import 'supabase_service.dart';

class OscuFiscalResult {
  const OscuFiscalResult({
    required this.cuInvoiceNumber,
    required this.receiptSignature,
    required this.internalData,
    required this.qrCodeUrl,
    required this.sdcDateTime,
    this.invcNo,
  });

  final String cuInvoiceNumber;
  final String receiptSignature;
  final String internalData;
  final String qrCodeUrl;
  final String sdcDateTime;
  final int? invcNo;
}

/// Calls the Cloudflare KRA eTIMS OSCU relay (`ttg-kra-oscu`) so KRA CMC
/// credentials remain off mobile devices while returning the signed CU invoice number,
/// sequential `invcNo`, SDC timestamp, and official KRA verification QR URL.
class KraOscuService {
  KraOscuService({
    required this._supabase,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const String defaultOscuRelayUrl =
      'https://ttg-kra-oscu.towntreasuregroceries.workers.dev';

  final SupabaseGateway _supabase;
  final http.Client _http;

  String _resolveRelayUrl(KraCompanyProfile profile) {
    final customUrl = profile.oscuRelayUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return customUrl.isNotEmpty ? customUrl : defaultOscuRelayUrl;
  }

  Future<String> _requireAccessToken(KraCompanyProfile profile) async {
    if (!profile.hasValidSellerPin) {
      throw StateError(
        'Set a valid 11-character Company KRA PIN before contacting KRA eTIMS OSCU.',
      );
    }
    final token = await _supabase.getAccessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in first to connect with KRA eTIMS OSCU.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required String token,
    required Map<String, dynamic> body,
  }) async {
    final res = await _http
        .post(
          Uri.parse(url),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    final decoded = jsonDecode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || decoded is! Map) {
      final err = decoded is Map
          ? (decoded['error'] ?? decoded['resultMsg'] ?? 'KRA eTIMS request failed.')
          : 'KRA eTIMS request failed (HTTP ${res.statusCode}).';
      throw StateError(err.toString());
    }
    return Map<String, dynamic>.from(decoded);
  }

  OscuFiscalResult _parseFiscalResult(
    Map<String, dynamic> decoded,
    KraCompanyProfile profile,
  ) {
    final data = decoded['data'] is Map
        ? Map<String, dynamic>.from(decoded['data'] as Map)
        : Map<String, dynamic>.from(decoded);

    final rcptSign = (data['rcptSign'] ?? '').toString().trim();
    final intrData = (data['intrData'] ?? data['intrlData'] ?? '').toString().trim();
    final sdcDateTime = (data['sdcDateTime'] ?? data['vsdcRcptPbctDate'] ?? '').toString().trim();
    final invcNo = (decoded['invcNo'] as num?)?.toInt() ??
        (data['invcNo'] as num?)?.toInt() ??
        (data['rcptNo'] as num?)?.toInt();
    final rawCuNo = (decoded['cuInvoiceNumber'] ??
            data['cuInvoiceNumber'] ??
            data['rcptNo'] ??
            '')
        .toString()
        .trim();

    if (rawCuNo.isEmpty || rcptSign.isEmpty) {
      throw StateError(
        'KRA eTIMS did not return a receipt signature or CU invoice number.',
      );
    }

    final explicitQr = (decoded['qrCodeUrl'] ?? data['qrCodeUrl'] ?? '')
        .toString()
        .trim();
    final qrUrl = explicitQr.isNotEmpty
        ? explicitQr
        : KraTaxCalculator.buildEtimsQrUrl(
            sellerKraPin: profile.normalizedSellerPin,
            branchId: profile.etimsBranchId,
            receiptSignature: rcptSign,
            sandbox: profile.oscuSandbox,
          );

    return OscuFiscalResult(
      cuInvoiceNumber: rawCuNo,
      receiptSignature: rcptSign,
      internalData: intrData,
      qrCodeUrl: qrUrl,
      sdcDateTime: sdcDateTime,
      invcNo: invcNo,
    );
  }

  Future<OscuFiscalResult> submitSalesInvoice({
    required Invoice invoice,
    required KraCompanyProfile profile,
    Restaurant? buyer,
  }) async {
    final token = await _requireAccessToken(profile);
    final relayUrl = _resolveRelayUrl(profile);
    final payload = KraTaxCalculator.buildOscuSalesPayload(
      invoice: invoice,
      profile: profile,
      buyer: buyer,
      sequentialInvcNo: invoice.etimsInvcNo ?? 0,
    );

    final decoded = await _postJson(
      '$relayUrl/oscu/sales',
      token: token,
      body: {
        'sandbox': profile.oscuSandbox,
        'cuSerial': profile.cuSerialNumber.trim(),
        'saveTrnsSalesReq': payload,
      },
    );
    return _parseFiscalResult(decoded, profile);
  }

  Future<OscuFiscalResult> submitCreditNote({
    required Invoice originalInvoice,
    required KraCompanyProfile profile,
    Restaurant? buyer,
  }) async {
    final token = await _requireAccessToken(profile);
    final relayUrl = _resolveRelayUrl(profile);
    final origNo = originalInvoice.etimsInvcNo ?? 0;
    if (origNo <= 0) {
      throw StateError(
        'A Credit Note requires the original OSCU invoice sequence number.',
      );
    }
    final payload = KraTaxCalculator.buildOscuSalesPayload(
      invoice: originalInvoice,
      profile: profile,
      buyer: buyer,
      isCreditNote: true,
      originalInvcNo: origNo,
    );

    final decoded = await _postJson(
      '$relayUrl/oscu/credit-note',
      token: token,
      body: {
        'sandbox': profile.oscuSandbox,
        'cuSerial': profile.cuSerialNumber.trim(),
        'originalInvcNo': origNo,
        'saveTrnsSalesReq': payload,
      },
    );
    return _parseFiscalResult(decoded, profile);
  }

  Future<Map<String, dynamic>> initializeDevice({
    required KraCompanyProfile profile,
  }) async {
    final token = await _requireAccessToken(profile);
    final relayUrl = _resolveRelayUrl(profile);
    final serial = profile.cuSerialNumber.trim();
    if (serial.isEmpty) {
      throw StateError('Enter your OSCU Device Serial first before initializing.');
    }
    return _postJson(
      '$relayUrl/oscu/init',
      token: token,
      body: {
        'sandbox': profile.oscuSandbox,
        'tin': profile.normalizedSellerPin,
        'bhfId': profile.etimsBranchId.trim().isEmpty ? '00' : profile.etimsBranchId.trim(),
        'dvcSrlNo': serial,
      },
    );
  }

  Future<Map<String, dynamic>> syncProduceCategories({
    required KraCompanyProfile profile,
  }) async {
    final token = await _requireAccessToken(profile);
    final relayUrl = _resolveRelayUrl(profile);
    final categories = KraTaxCalculator.coreOscuCategories
        .map((c) => {
              'itemCd': c.itemCd,
              'itemClsCd': c.itemClsCd,
              'itemNm': c.label,
              'taxTyCd': c.itemCd == 'TTG-TAX-16' ? 'B' : 'A',
            })
        .toList();
    return _postJson(
      '$relayUrl/oscu/items/sync',
      token: token,
      body: {
        'sandbox': profile.oscuSandbox,
        'tin': profile.normalizedSellerPin,
        'bhfId': profile.etimsBranchId.trim().isEmpty ? '00' : profile.etimsBranchId.trim(),
        'items': categories,
      },
    );
  }
}
