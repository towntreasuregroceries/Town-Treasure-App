import 'package:supabase_flutter/supabase_flutter.dart';

/// Result from reading a vault row or metadata from `encrypted_vault`.
class RemoteVaultRow {
  const RemoteVaultRow({
    this.data,
    required this.revision,
    this.revisionSupported = true,
  });

  final String? data;
  final int revision;
  final bool revisionSupported;
}

/// Result from `save_encrypted_vault_cas` RPC.
class CasSaveResult {
  const CasSaveResult({
    required this.saved,
    required this.revision,
  });

  final bool saved;
  final int revision;
}

/// Authenticated user snapshot decoupled from Supabase SDK internals for tests.
class AuthUserInfo {
  const AuthUserInfo({
    required this.id,
    this.email,
  });

  final String id;
  final String? email;
}

/// Exception carrying structured error codes matching `data.js`.
class VaultSyncException implements Exception {
  const VaultSyncException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => code != null ? 'VaultSyncException($code): $message' : message;
}

/// Gateway interface over Supabase operations for testability and clean separation.
abstract class SupabaseGateway {
  Future<AuthUserInfo?> getCurrentUser();
  Future<String?> getAccessToken();
  Future<AuthUserInfo> signInWithPassword(String email, String password);
  Future<void> verifyInvitedEmail(String email);
  Future<AuthUserInfo> verifySignupOtp(String email, String token);
  Future<void> signOut({bool othersOnly = false});
  Future<void> updatePassword(String newPassword);

  Future<int?> readVaultRevision(String userId);
  Future<RemoteVaultRow?> readVaultRow(String userId);
  Future<String?> readVaultDataOnly(String userId);
  Future<CasSaveResult> saveEncryptedVaultCas({
    required String userId,
    required int expectedRevision,
    required String encryptedData,
  });

  Future<bool> checkStagedInvoicesAccessible();
  Future<List<Map<String, dynamic>>> fetchStagedInvoices(String ownerUserId);
  Future<List<Map<String, dynamic>>> fetchPendingStagedInvoices();
  Future<Map<String, dynamic>?> fetchStagedInvoiceById(
    String ownerUserId,
    String id,
  );
  Future<void> upsertStagedInvoice(Map<String, dynamic> record);
  Future<bool> updateStagedInvoiceStatus(
    String id,
    Map<String, dynamic> payload,
  );
  Future<bool> rejectStagedInvoice(String id, String reason);
  Future<bool> deleteUnapprovedStagedInvoice(String id);
  Future<Map<String, dynamic>> invokeClerkApi(Map<String, dynamic> body);
}

/// Live Supabase client wrapper configured with the production Town Treasure
/// project URL and anon key from `supabase-config.js`.
class SupabaseService implements SupabaseGateway {
  SupabaseService({SupabaseClient? client}) : _injectedClient = client;

  static const String supabaseUrl = 'https://hufxsjfmgjeyfdidsvcq.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh1ZnhzamZtZ2pleWZkaWRzdmNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2OTc4NTcsImV4cCI6MjEwOTI3Mzg1N30.AERGUhCqait59P0JhA-Ph1F-Kz2pzjfdqYyxMXRSfJY';

  static const String summaryColumns =
      'id,owner_user_id,submitted_by_invite_id,submission_key,clerk_name,restaurant_name,invoice_date,items_json,delivery_cost,other_cost,total_sell,total_buy,notes,status,rejection_reason,target_user_id,target_user_email,target_user_name,created_at,updated_at';

  static bool _initialized = false;
  final SupabaseClient? _injectedClient;

  /// Initializes the global Supabase Flutter SDK once.
  static Future<void> initialize() async {
    if (_initialized) return;
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
    _initialized = true;
  }

  SupabaseClient get client => _injectedClient ?? Supabase.instance.client;

  static bool isMissingRevisionColumnError(Object error) {
    if (error is PostgrestException) {
      final code = error.code ?? '';
      final details = '${error.message} ${error.details ?? ''}'.toLowerCase();
      return (code == '42703' || code == 'PGRST204') &&
          details.contains('revision');
    }
    return false;
  }

  @override
  Future<AuthUserInfo?> getCurrentUser() async {
    final session = client.auth.currentSession;
    final user = session?.user ?? client.auth.currentUser;
    if (user == null) return null;
    return AuthUserInfo(id: user.id, email: user.email);
  }

  @override
  Future<String?> getAccessToken() async {
    return client.auth.currentSession?.accessToken;
  }

  @override
  Future<AuthUserInfo> signInWithPassword(String email, String password) async {
    final res = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final user = res.user;
    if (user == null) {
      throw const VaultSyncException('Sign in failed: no user returned.');
    }
    return AuthUserInfo(id: user.id, email: user.email);
  }

  @override
  Future<void> verifyInvitedEmail(String email) async {
    await client.auth.signInWithOtp(
      email: email.trim().toLowerCase(),
      shouldCreateUser: false,
    );
  }

  @override
  Future<AuthUserInfo> verifySignupOtp(String email, String token) async {
    final res = await client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.signup,
    );
    final user = res.user;
    if (user == null) {
      throw const VaultSyncException('OTP verification failed.');
    }
    return AuthUserInfo(id: user.id, email: user.email);
  }

  @override
  Future<void> signOut({bool othersOnly = false}) async {
    await client.auth.signOut(
      scope: othersOnly ? SignOutScope.others : SignOutScope.local,
    );
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    await client.auth.updateUser(UserAttributes(password: newPassword));
  }

  @override
  Future<int?> readVaultRevision(String userId) async {
    try {
      final row = await client
          .from('encrypted_vault')
          .select('revision')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) return null;
      final rawRev = row['revision'];
      if (rawRev == null || rawRev is! num || rawRev < 0 || rawRev % 1 != 0) {
        throw const VaultSyncException(
          'The server returned an invalid vault revision; sync was stopped.',
        );
      }
      return rawRev.toInt();
    } on PostgrestException catch (e) {
      if (isMissingRevisionColumnError(e)) {
        throw const VaultSyncException(
          'Server revision protection is not available. Cloud sync was stopped to protect existing records; apply supabase_vault_revision.sql and retry.',
          code: 'VAULT_REVISION_MIGRATION_MISSING',
        );
      }
      rethrow;
    }
  }

  @override
  Future<RemoteVaultRow?> readVaultRow(String userId) async {
    try {
      final row = await client
          .from('encrypted_vault')
          .select('data, revision')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) return null;
      final rawRev = row['revision'];
      if (rawRev == null || rawRev is! num || rawRev < 0 || rawRev % 1 != 0) {
        throw const VaultSyncException(
          'The server returned an invalid vault revision; sync was stopped.',
        );
      }
      return RemoteVaultRow(
        data: row['data']?.toString(),
        revision: rawRev.toInt(),
        revisionSupported: true,
      );
    } on PostgrestException catch (e) {
      if (isMissingRevisionColumnError(e)) {
        throw const VaultSyncException(
          'Server revision protection is not available. Cloud sync was stopped to protect existing records; apply supabase_vault_revision.sql and retry.',
          code: 'VAULT_REVISION_MIGRATION_MISSING',
        );
      }
      rethrow;
    }
  }

  @override
  Future<String?> readVaultDataOnly(String userId) async {
    final row = await client
        .from('encrypted_vault')
        .select('data')
        .eq('user_id', userId)
        .maybeSingle();
    return row?['data']?.toString();
  }

  @override
  Future<CasSaveResult> saveEncryptedVaultCas({
    required String userId,
    required int expectedRevision,
    required String encryptedData,
  }) async {
    final raw = await client.rpc(
      'save_encrypted_vault_cas',
      params: {
        'p_user_id': userId,
        'p_expected_revision': expectedRevision,
        'p_data': encryptedData,
      },
    );
    if (raw is! Map) {
      throw const VaultSyncException(
        'The server returned an invalid compare-and-swap result; sync was stopped.',
      );
    }
    final saved = raw['saved'];
    final rev = raw['revision'];
    if (saved is! bool || rev is! num || rev < 0 || rev % 1 != 0) {
      throw const VaultSyncException(
        'The server returned an invalid compare-and-swap result; sync was stopped.',
      );
    }
    return CasSaveResult(saved: saved, revision: rev.toInt());
  }

  @override
  Future<bool> checkStagedInvoicesAccessible() async {
    try {
      await client.from('staged_invoices').select('id').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchStagedInvoices(
    String ownerUserId,
  ) async {
    final rows = await client
        .from('staged_invoices')
        .select(summaryColumns)
        .eq('owner_user_id', ownerUserId)
        .order('created_at', ascending: false);
    return (rows as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPendingStagedInvoices() async {
    final rows = await client
        .from('staged_invoices')
        .select('id, owner_user_id, target_user_id, target_user_email, notes, status')
        .eq('status', 'pending');
    return (rows as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> fetchStagedInvoiceById(
    String ownerUserId,
    String id,
  ) async {
    final row = await client
        .from('staged_invoices')
        .select('*')
        .eq('owner_user_id', ownerUserId)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<void> upsertStagedInvoice(Map<String, dynamic> record) async {
    await client.from('staged_invoices').upsert([record], onConflict: 'id');
  }

  @override
  Future<bool> updateStagedInvoiceStatus(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final updated = await client
        .from('staged_invoices')
        .update(payload)
        .eq('id', id)
        .select('id')
        .maybeSingle();
    return updated != null;
  }

  @override
  Future<bool> rejectStagedInvoice(String id, String reason) async {
    final updated = await client
        .from('staged_invoices')
        .update({
          'status': 'rejected',
          'rejection_reason': reason,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', id)
        .eq('status', 'pending')
        .select('id')
        .maybeSingle();
    return updated != null;
  }

  @override
  Future<bool> deleteUnapprovedStagedInvoice(String id) async {
    final removed = await client
        .from('staged_invoices')
        .delete()
        .eq('id', id)
        .neq('status', 'approved')
        .select('id')
        .maybeSingle();
    return removed != null;
  }

  @override
  Future<Map<String, dynamic>> invokeClerkApi(Map<String, dynamic> body) async {
    final res = await client.functions.invoke('clerk-api', body: body);
    final data = res.data;
    if (data is! Map || data['error'] != null) {
      final msg = data is Map ? (data['error']?.toString() ?? 'Clerk request failed.') : 'Clerk service returned no result.';
      throw VaultSyncException(msg);
    }
    return Map<String, dynamic>.from(data);
  }
}
