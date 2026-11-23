import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Abstraction over secure key-value storage for testability.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyStore implements SecureKeyStore {
  FlutterSecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Offline persistence layer using `flutter_secure_storage` for credentials/keys
/// and `sqflite` for large encrypted-vault collections and clerk staging queues.
class LocalStorageService {
  LocalStorageService({
    SecureKeyStore? secureStore,
    this._databaseOpener,
  }) : _secureStore = secureStore ?? FlutterSecureKeyStore();

  static const String keyE2eKey = 'ttg_e2e_key';
  static const String keySaltVersion = 'ttg_salt_version';
  static const String keyUserId = 'ttg_user_id';
  static const String keyUserEmail = 'ttg_user_email';
  static const String keyBiometricEnabled = 'ttg_biometric_enabled';
  static const String keyLastPage = 'ttg_last_page';
  static const String keySavedPrinter = 'ttg_saved_printer';

  // Exact collection keys matching `data.js` and `supabase-config.js`.
  static const String keyRestaurants = 'ttg_restaurants';
  static const String keyDeletedRestaurantIds = 'ttg_deleted_restaurant_ids';
  static const String keyInvoices = 'ttg_invoices';
  static const String keyDeletedInvoiceIds = 'ttg_deleted_invoice_ids';
  static const String keyRestoredInvoiceIds = 'ttg_restored_invoice_ids';
  static const String keyRecordActions = 'ttg_record_actions';
  static const String keyExpenses = 'ttg_expenses';
  static const String keyDeletedInvoices = 'ttg_deleted_invoices';
  static const String keyStaff = 'ttg_staff';
  static const String keySalaryPayments = 'ttg_salary_payments';
  static const String keyRecurringExpenses = 'ttg_recurring_expenses';
  static const String keyPriceLists = 'ttg_price_lists';
  static const String keyDeletedStaff = 'ttg_deleted_staff';
  static const String keyDeletedPriceLists = 'ttg_deleted_pricelists';
  static const String keyBorrowings = 'ttg_borrowings';
  static const String keySettings = 'ttg_settings';

  // Staging keys matching `staging.js`.
  static const String keyStagedInvoices = 'ttg_staged_invoices';
  static const String keyDeletedStagedInvoiceIds =
      'ttg_deleted_staged_invoice_ids';

  static const List<String> allVaultDataKeys = [
    keyRestaurants,
    keyDeletedRestaurantIds,
    keyInvoices,
    keyDeletedInvoiceIds,
    keyRestoredInvoiceIds,
    keyRecordActions,
    keyExpenses,
    keyDeletedInvoices,
    keyStaff,
    keySalaryPayments,
    keyRecurringExpenses,
    keyPriceLists,
    keyDeletedStaff,
    keyDeletedPriceLists,
    keyBorrowings,
    keySettings,
  ];

  static const List<String> allStagingKeys = [
    keyStagedInvoices,
    keyDeletedStagedInvoiceIds,
  ];

  final SecureKeyStore _secureStore;
  final Future<Database> Function()? _databaseOpener;
  Database? _db;
  Future<Database>? _openingDb;
  Map<String, dynamic>? _cachedE2eKey;

  Future<Database> _getDb() async {
    final current = _db;
    if (current != null && current.isOpen) return current;
    final pending = _openingDb;
    if (pending != null) return pending;

    final completerFuture = _openDatabaseFresh();
    _openingDb = completerFuture;
    try {
      final db = await completerFuture;
      _db = db;
      return db;
    } finally {
      if (identical(_openingDb, completerFuture)) {
        _openingDb = null;
      }
    }
  }

  Future<Database> _openDatabaseFresh() async {
    if (_databaseOpener != null) {
      return _databaseOpener();
    }
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'ttg_vault_cache.db');
    return openDatabase(
      fullPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  Future<T> _runWithDb<T>(Future<T> Function(Database db) action) async {
    try {
      final db = await _getDb();
      return await action(db);
    } on DatabaseException catch (e) {
      if (e.isDatabaseClosedError() ||
          e.toString().toLowerCase().contains('database_closed')) {
        _db = null;
        _openingDb = null;
        final reopened = await _getDb();
        return action(reopened);
      }
      rethrow;
    }
  }

  /// Ensures the `kv_store` table exists (helpful for injected test databases).
  Future<void> init() async {
    final db = await _getDb();
    await db.execute('''
      CREATE TABLE IF NOT EXISTS kv_store (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  // --- Secure Key Store ---

  Future<Map<String, dynamic>?> getE2eKey() async {
    final cached = _cachedE2eKey;
    if (cached != null) {
      return Map<String, dynamic>.from(cached);
    }

    String? raw;
    try {
      raw = await _secureStore.read(keyE2eKey);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      raw = await _secureStore.read(keyE2eKey);
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final jwk = Map<String, dynamic>.from(decoded);
      _cachedE2eKey = Map<String, dynamic>.from(jwk);
      return jwk;
    } catch (_) {
      return null;
    }
  }

  Future<void> setE2eKey(Map<String, dynamic> jwk) async {
    final copy = Map<String, dynamic>.from(jwk);
    _cachedE2eKey = copy;
    await _secureStore.write(keyE2eKey, jsonEncode(copy));
  }

  Future<void> clearE2eKey() async {
    _cachedE2eKey = null;
    await _secureStore.delete(keyE2eKey);
  }

  Future<String?> getSaltVersion() => _secureStore.read(keySaltVersion);
  Future<void> setSaltVersion(String version) =>
      _secureStore.write(keySaltVersion, version);

  Future<String?> getUserId() => _secureStore.read(keyUserId);
  Future<void> setUserId(String userId) =>
      _secureStore.write(keyUserId, userId);

  Future<String?> getUserEmail() => _secureStore.read(keyUserEmail);
  Future<void> setUserEmail(String email) =>
      _secureStore.write(keyUserEmail, email.toLowerCase().trim());

  Future<bool> isBiometricEnabled() async {
    return (await _secureStore.read(keyBiometricEnabled)) == 'true';
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    if (enabled) {
      await _secureStore.write(keyBiometricEnabled, 'true');
    } else {
      await _secureStore.delete(keyBiometricEnabled);
    }
  }

  Future<String?> getLastPage() => _secureStore.read(keyLastPage);
  Future<void> setLastPage(String page) =>
      _secureStore.write(keyLastPage, page);

  Future<void> clearAuthMetadata() async {
    _cachedE2eKey = null;
    await _secureStore.delete(keyUserId);
    await _secureStore.delete(keyUserEmail);
    await _secureStore.delete(keyE2eKey);
    await _secureStore.delete(keySaltVersion);
    await _secureStore.delete(keyLastPage);
  }

  // --- SQLite Key-Value Store ---

  Future<String?> getRaw(String key) async {
    return _runWithDb((db) async {
      final rows = await db.query(
        'kv_store',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value']?.toString();
    });
  }

  Future<void> setRaw(String key, String value) async {
    await _runWithDb((db) async {
      await db.insert(
        'kv_store',
        {
          'key': key,
          'value': value,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> deleteKey(String key) async {
    await _runWithDb((db) async {
      await db.delete('kv_store', where: 'key = ?', whereArgs: [key]);
    });
  }

  Future<List<Map<String, dynamic>>> getJsonList(String key) async {
    final raw = await getRaw(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> getStringList(String key) async {
    final raw = await getRaw(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>> getJsonMap(String key) async {
    final raw = await getRaw(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> setJson(String key, Object value) async {
    await setRaw(key, jsonEncode(value));
  }

  Future<Map<String, dynamic>> getSavedPrinterConfig() =>
      getJsonMap(keySavedPrinter);

  Future<void> setSavedPrinterConfig(Map<String, dynamic> value) =>
      setJson(keySavedPrinter, value);

  Future<void> clearVaultData() async {
    await _runWithDb((db) async {
      final batch = db.batch();
      for (final key in allVaultDataKeys) {
        batch.delete('kv_store', where: 'key = ?', whereArgs: [key]);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Comprehensive sign-out cleanup matching `supabase-config.js` `signOut()`.
  Future<void> clearAllOnSignOut() async {
    await _runWithDb((db) async {
      final batch = db.batch();
      for (final key in [...allVaultDataKeys, ...allStagingKeys]) {
        batch.delete('kv_store', where: 'key = ?', whereArgs: [key]);
      }
      await batch.commit(noResult: true);
    });
    await clearAuthMetadata();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
