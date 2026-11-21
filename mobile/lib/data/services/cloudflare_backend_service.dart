import 'dart:convert';

import 'package:http/http.dart' as http;

import 'supabase_service.dart';

/// Hybrid Cloudflare backend adapter implementing [SupabaseGateway].
///
/// Auth stays on Supabase (via [authGateway]), while all application data
/// (Vault CAS, Vault history, Staged dockets + R2 photos, and Clerk Intake API)
/// is served from Cloudflare Workers (`ttg-api` backed by D1 + R2).
class CloudflareBackendService implements SupabaseGateway {
  CloudflareBackendService({
    required this.authGateway,
    this.baseUrl = defaultBaseUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const String defaultBaseUrl =
      'https://ttg-api.towntreasuregroceries.workers.dev';

  final SupabaseGateway authGateway;
  final String baseUrl;
  final http.Client _http;

  String get _root => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Uri _uri(String path) => Uri.parse('$_root$path');

  Future<String> _requireAccessToken() async {
    final token = (await authGateway.getAccessToken())?.trim() ?? '';
    if (token.isEmpty) {
      throw const VaultSyncException('Please sign in again to sync with cloud.');
    }
    return token;
  }

  Map<String, String> _jsonHeaders({String? bearerToken}) => {
        'Content-Type': 'application/json',
        if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      };

  Map<String, dynamic> _decodeJsonObject(http.Response res) {
    final raw = res.body.trim();
    if (raw.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const VaultSyncException('Unexpected non-object server response.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Never _throwHttpError(http.Response res, String fallback) {
    try {
      final decoded = _decodeJsonObject(res);
      final msg = decoded['error']?.toString().trim();
      if (msg != null && msg.isNotEmpty) {
        throw VaultSyncException(msg, code: decoded['code']?.toString());
      }
    } catch (e) {
      if (e is VaultSyncException) rethrow;
    }
    throw VaultSyncException('$fallback (HTTP ${res.statusCode}).');
  }

  // --- Auth (stays on Supabase Auth) ---

  @override
  Future<AuthUserInfo?> getCurrentUser() => authGateway.getCurrentUser();

  @override
  Future<String?> getAccessToken() => authGateway.getAccessToken();

  @override
  Future<AuthUserInfo> signInWithPassword(String email, String password) =>
      authGateway.signInWithPassword(email, password);

  @override
  Future<void> verifyInvitedEmail(String email) =>
      authGateway.verifyInvitedEmail(email);

  @override
  Future<AuthUserInfo> verifySignupOtp(String email, String token) =>
      authGateway.verifySignupOtp(email, token);

  @override
  Future<void> signOut({bool othersOnly = false}) =>
      authGateway.signOut(othersOnly: othersOnly);

  @override
  Future<void> updatePassword(String newPassword) =>
      authGateway.updatePassword(newPassword);

  // --- Encrypted Vault (Cloudflare D1 + R2) ---

  @override
  Future<int?> readVaultRevision(String userId) async {
    final token = await _requireAccessToken();
    final res = await _http
        .get(_uri('/vault/revision'), headers: _jsonHeaders(bearerToken: token))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not read cloud vault revision');
    }
    final data = _decodeJsonObject(res);
    if (data['exists'] != true) return null;
    final rawRev = data['revision'];
    if (rawRev is! num || rawRev < 0 || rawRev % 1 != 0) {
      throw const VaultSyncException(
        'The server returned an invalid vault revision; sync was stopped.',
      );
    }
    return rawRev.toInt();
  }

  @override
  Future<RemoteVaultRow?> readVaultRow(String userId) async {
    final token = await _requireAccessToken();
    final res = await _http
        .get(_uri('/vault'), headers: _jsonHeaders(bearerToken: token))
        .timeout(const Duration(seconds: 45));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not load cloud vault');
    }
    final data = _decodeJsonObject(res);
    if (data['exists'] != true) return null;
    final rawRev = data['revision'];
    if (rawRev is! num || rawRev < 0 || rawRev % 1 != 0) {
      throw const VaultSyncException(
        'The server returned an invalid vault revision; sync was stopped.',
      );
    }
    return RemoteVaultRow(
      data: data['data']?.toString(),
      revision: rawRev.toInt(),
      revisionSupported: true,
    );
  }

  @override
  Future<String?> readVaultDataOnly(String userId) async {
    final row = await readVaultRow(userId);
    return row?.data;
  }

  @override
  Future<CasSaveResult> saveEncryptedVaultCas({
    required String userId,
    required int expectedRevision,
    required String encryptedData,
  }) async {
    final token = await _requireAccessToken();
    final res = await _http
        .post(
          _uri('/vault/cas'),
          headers: _jsonHeaders(bearerToken: token),
          body: jsonEncode({
            'expectedRevision': expectedRevision,
            'data': encryptedData,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not save cloud vault');
    }
    final raw = _decodeJsonObject(res);
    final saved = raw['saved'];
    final rev = raw['revision'];
    if (saved is! bool || rev is! num || rev < 0 || rev % 1 != 0) {
      throw const VaultSyncException(
        'The server returned an invalid compare-and-swap result; sync was stopped.',
      );
    }
    return CasSaveResult(saved: saved, revision: rev.toInt());
  }

  // --- Staged Dockets (Cloudflare D1 + R2) ---

  @override
  Future<bool> checkStagedInvoicesAccessible() async {
    try {
      final token = (await authGateway.getAccessToken())?.trim() ?? '';
      if (token.isEmpty) return false;
      final res = await _http
          .get(_uri('/staged/pending'), headers: _jsonHeaders(bearerToken: token))
          .timeout(const Duration(seconds: 15));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchStagedInvoices(
    String ownerUserId,
  ) async {
    final token = await _requireAccessToken();
    final res = await _http
        .get(_uri('/staged'), headers: _jsonHeaders(bearerToken: token))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not fetch staged dockets');
    }
    final data = _decodeJsonObject(res);
    final rows = data['rows'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPendingStagedInvoices() async {
    final token = await _requireAccessToken();
    final res = await _http
        .get(_uri('/staged/pending'), headers: _jsonHeaders(bearerToken: token))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not fetch pending dockets');
    }
    final data = _decodeJsonObject(res);
    final rows = data['rows'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> fetchStagedInvoiceById(
    String ownerUserId,
    String id,
  ) async {
    final token = await _requireAccessToken();
    final encodedId = Uri.encodeComponent(id);
    final res = await _http
        .get(
          _uri('/staged/$encodedId'),
          headers: _jsonHeaders(bearerToken: token),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not load staged docket');
    }
    final data = _decodeJsonObject(res);
    final row = data['row'];
    return row is Map ? Map<String, dynamic>.from(row) : null;
  }

  @override
  Future<void> upsertStagedInvoice(Map<String, dynamic> record) async {
    final id = record['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const VaultSyncException('Docket ID is required.');
    }
    final token = await _requireAccessToken();
    final encodedId = Uri.encodeComponent(id);
    final res = await _http
        .put(
          _uri('/staged/$encodedId'),
          headers: _jsonHeaders(bearerToken: token),
          body: jsonEncode(record),
        )
        .timeout(const Duration(seconds: 45));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not save staged docket');
    }
  }

  @override
  Future<bool> updateStagedInvoiceStatus(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final token = await _requireAccessToken();
    final encodedId = Uri.encodeComponent(id);
    final res = await _http
        .patch(
          _uri('/staged/$encodedId/status'),
          headers: _jsonHeaders(bearerToken: token),
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not update docket status');
    }
    final data = _decodeJsonObject(res);
    return data['updated'] == true;
  }

  @override
  Future<bool> rejectStagedInvoice(String id, String reason) async {
    final token = await _requireAccessToken();
    final encodedId = Uri.encodeComponent(id);
    final res = await _http
        .post(
          _uri('/staged/$encodedId/reject'),
          headers: _jsonHeaders(bearerToken: token),
          body: jsonEncode({'reason': reason}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not reject docket');
    }
    final data = _decodeJsonObject(res);
    return data['updated'] == true;
  }

  @override
  Future<bool> deleteUnapprovedStagedInvoice(String id) async {
    final token = await _requireAccessToken();
    final encodedId = Uri.encodeComponent(id);
    final res = await _http
        .delete(
          _uri('/staged/$encodedId'),
          headers: _jsonHeaders(bearerToken: token),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwHttpError(res, 'Could not delete docket');
    }
    final data = _decodeJsonObject(res);
    return data['deleted'] == true;
  }

  // --- Clerk Intake API (Cloudflare Worker + D1 + R2) ---

  @override
  Future<Map<String, dynamic>> invokeClerkApi(Map<String, dynamic> body) async {
    final isOwnerInviteCreate = body['action']?.toString() == 'create_invite';
    final bearerToken =
        isOwnerInviteCreate ? await _requireAccessToken() : null;
    final res = await _http
        .post(
          _uri('/clerk'),
          headers: _jsonHeaders(bearerToken: bearerToken),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));
    final data = _decodeJsonObject(res);
    if (res.statusCode < 200 || res.statusCode >= 300 || data['error'] != null) {
      final msg =
          data['error']?.toString() ?? 'Clerk request failed (HTTP ${res.statusCode}).';
      throw VaultSyncException(msg);
    }
    return data;
  }
}
