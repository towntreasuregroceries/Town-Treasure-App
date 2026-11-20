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
  });

  final String cuInvoiceNumber;
  final String receiptSignature;
  final String internalData;
  final String qrCodeUrl;
  final String sdcDateTime;
}

/// Calls a Cloudflare/server KRA eTIMS OSCU relay (`saveTrnsSalesReq`) so KRA CMC
/// credentials remain off mobile phones while returning the signed CU invoice number
/// and official KRA verification QR URL.
class KraOscuService {
  KraOscuService({
    required this._supabase,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const String defaultOscuRelayUrl =
      'https://ttg-kra-oscu.towntreasuregroceries.workers.dev';

  final SupabaseGateway _supabase;
  final http.Client _http;

  Future<OscuFiscalResult> submitSalesInvoice({
    required Invoice invoice,
    required KraCompanyProfile profile,
    Restaurant? buyer,
  }) async {
    final customUrl = profile.oscuRelayUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final relayUrl = customUrl.isNotEmpty ? customUrl : defaultOscuRelayUrl;
    if (!profile.hasValidSellerPin) {
      throw StateError(
        'Set a valid 11-character Company KRA PIN before issuing an eTIMS invoice.',
      );
    }

    final token = await _supabase.getAccessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in first to connect with KRA eTIMS OSCU.');
    }

    final payload = KraTaxCalculator.buildOscuSalesPayload(
      invoice: invoice,
      profile: profile,
      buyer: buyer,
    );

    final res = await _http
        .post(
          Uri.parse('$relayUrl/oscu/sales'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'sandbox': profile.oscuSandbox,
            'cuSerial': profile.cuSerialNumber.trim(),
            'saveTrnsSalesReq': payload,
          }),
        )
        .timeout(const Duration(seconds: 30));

    final decoded = jsonDecode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300 || decoded is! Map) {
      final err = decoded is Map
          ? (decoded['error'] ?? decoded['resultMsg'] ?? 'KRA eTIMS request failed.')
          : 'KRA eTIMS request failed (HTTP ${res.statusCode}).';
      throw StateError(err.toString());
    }

    final data = decoded['data'] is Map
        ? Map<String, dynamic>.from(decoded['data'] as Map)
        : Map<String, dynamic>.from(decoded);

    final rcptSign = (data['rcptSign'] ?? '').toString().trim();
    final intrData = (data['intrData'] ?? '').toString().trim();
    final sdcDateTime = (data['sdcDateTime'] ?? '').toString().trim();
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
    );
  }
}
