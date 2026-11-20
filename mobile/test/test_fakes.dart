import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';

class InMemorySecureKeyStore implements SecureKeyStore {
  final Map<String, String> _data = {};

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}

Future<LocalStorageService> createTestLocalStorage() async {
  sqfliteFfiInit();
  final storage = LocalStorageService(
    secureStore: InMemorySecureKeyStore(),
    databaseOpener: () async {
      return databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    },
  );
  await storage.init();
  return storage;
}

class FakeSupabaseGateway implements SupabaseGateway {
  AuthUserInfo? user;
  String? accessToken = 'fake-access-token';
  bool missingRevisionColumn = false;
  String? vaultData;
  int vaultRevision = 0;
  bool hasVaultRow = false;
  bool forceConflictOnce = false;
  String? nextConflictRemoteData;
  int? nextConflictRemoteRevision;
  bool failSaveOnce = false;
  int signOutCalls = 0;
  int signOutOthersCalls = 0;
  Set<String>? invitedEmails;

  final List<Map<String, dynamic>> stagedInvoices = [];
  bool stagedAccessible = true;

  @override
  Future<AuthUserInfo?> getCurrentUser() async => user;

  @override
  Future<String?> getAccessToken() async => user != null ? accessToken : null;

  @override
  Future<void> verifyInvitedEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (invitedEmails != null && !invitedEmails!.contains(normalized)) {
      throw Exception('Signups not allowed for otp');
    }
  }

  @override
  Future<AuthUserInfo> signInWithPassword(
    String email,
    String password,
  ) async {
    final u = AuthUserInfo(id: user?.id ?? 'user-1', email: email);
    user = u;
    return u;
  }

  @override
  Future<AuthUserInfo> verifySignupOtp(String email, String token) async {
    final u = AuthUserInfo(id: user?.id ?? 'user-1', email: email);
    user = u;
    return u;
  }

  @override
  Future<void> signOut({bool othersOnly = false}) async {
    if (othersOnly) {
      signOutOthersCalls++;
    } else {
      signOutCalls++;
      user = null;
    }
  }

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<int?> readVaultRevision(String userId) async {
    if (missingRevisionColumn) {
      throw const VaultSyncException(
        'Server revision protection is not available.',
        code: 'VAULT_REVISION_MIGRATION_MISSING',
      );
    }
    if (!hasVaultRow) return null;
    return vaultRevision;
  }

  @override
  Future<RemoteVaultRow?> readVaultRow(String userId) async {
    if (missingRevisionColumn) {
      throw const VaultSyncException(
        'Server revision protection is not available.',
        code: 'VAULT_REVISION_MIGRATION_MISSING',
      );
    }
    if (!hasVaultRow) return null;
    return RemoteVaultRow(
      data: vaultData,
      revision: vaultRevision,
      revisionSupported: true,
    );
  }

  @override
  Future<String?> readVaultDataOnly(String userId) async {
    return hasVaultRow ? vaultData : null;
  }

  @override
  Future<CasSaveResult> saveEncryptedVaultCas({
    required String userId,
    required int expectedRevision,
    required String encryptedData,
  }) async {
    if (failSaveOnce) {
      failSaveOnce = false;
      throw const VaultSyncException('Simulated network failure');
    }
    if (forceConflictOnce) {
      forceConflictOnce = false;
      if (nextConflictRemoteData != null) {
        vaultData = nextConflictRemoteData;
      }
      vaultRevision = nextConflictRemoteRevision ?? (expectedRevision + 1);
      hasVaultRow = true;
      return CasSaveResult(saved: false, revision: vaultRevision);
    }
    if (hasVaultRow && vaultRevision != expectedRevision) {
      return CasSaveResult(saved: false, revision: vaultRevision);
    }
    if (!hasVaultRow && expectedRevision != 0) {
      return const CasSaveResult(saved: false, revision: 0);
    }
    hasVaultRow = true;
    vaultRevision = expectedRevision + 1;
    vaultData = encryptedData;
    return CasSaveResult(saved: true, revision: vaultRevision);
  }

  @override
  Future<bool> checkStagedInvoicesAccessible() async => stagedAccessible;

  @override
  Future<List<Map<String, dynamic>>> fetchStagedInvoices(
    String ownerUserId,
  ) async {
    return stagedInvoices
        .where((e) => e['owner_user_id'] == ownerUserId)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPendingStagedInvoices() async {
    return stagedInvoices.where((e) => e['status'] == 'pending').toList();
  }

  @override
  Future<Map<String, dynamic>?> fetchStagedInvoiceById(
    String ownerUserId,
    String id,
  ) async {
    for (final row in stagedInvoices) {
      if (row['id'] == id && row['owner_user_id'] == ownerUserId) return row;
    }
    return null;
  }

  @override
  Future<void> upsertStagedInvoice(Map<String, dynamic> record) async {
    final idx = stagedInvoices.indexWhere((e) => e['id'] == record['id']);
    if (idx >= 0) {
      stagedInvoices[idx] = record;
    } else {
      stagedInvoices.add(record);
    }
  }

  @override
  Future<bool> updateStagedInvoiceStatus(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final idx = stagedInvoices.indexWhere((e) => e['id'] == id);
    if (idx < 0) return false;
    stagedInvoices[idx] = {...stagedInvoices[idx], ...payload};
    return true;
  }

  @override
  Future<bool> rejectStagedInvoice(String id, String reason) async {
    final idx = stagedInvoices.indexWhere(
      (e) => e['id'] == id && e['status'] == 'pending',
    );
    if (idx < 0) return false;
    stagedInvoices[idx] = {
      ...stagedInvoices[idx],
      'status': 'rejected',
      'rejection_reason': reason,
    };
    return true;
  }

  @override
  Future<bool> deleteUnapprovedStagedInvoice(String id) async {
    final idx = stagedInvoices.indexWhere(
      (e) => e['id'] == id && e['status'] != 'approved',
    );
    if (idx < 0) return false;
    stagedInvoices.removeAt(idx);
    return true;
  }

  @override
  Future<Map<String, dynamic>> invokeClerkApi(Map<String, dynamic> body) async {
    return {};
  }
}
