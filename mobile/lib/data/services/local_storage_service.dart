import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
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
  FlutterSecureKeyStore([
    FlutterSecureStorage? storage,
    this._useNativeChannel = true,
  ]) : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const MethodChannel _nativeChannel =
      MethodChannel('com.towntreasuregroceries/secure_kv');

  final FlutterSecureStorage _storage;
  final bool _useNativeChannel;

  Future<String?> _readNative(String key) async {
    if (!_useNativeChannel) return null;
    try {
      return await _nativeChannel.invokeMethod<String>('read', {'key': key});
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _writeNative(String key, String value) async {
    if (!_useNativeChannel) return false;
    try {
      await _nativeChannel.invokeMethod<void>(
        'write',
        {'key': key, 'value': value},
      );
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteNative(String key) async {
    if (!_useNativeChannel) return;
    try {
      await _nativeChannel.invokeMethod<void>('delete', {'key': key});
    } catch (_) {}
  }

  @override
  Future<String?> read(String key) async {
    final nativeVal = await _readNative(key);
    if (nativeVal != null && nativeVal.isNotEmpty) {
      return nativeVal;
    }
    try {
      final legacyVal = await _storage.read(key: key);
      if (legacyVal != null && legacyVal.isNotEmpty) {
        // Silently migrate healthy legacy entries into Android Keystore v2.
        await _writeNative(key, legacyVal);
      }
      return legacyVal;
    } catch (_) {
      // Heal permanently corrupted EncryptedSharedPreferences/Keystore entries
      // instead of failing every read with PlatformException("Exception encountered").
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final savedNative = await _writeNative(key, value);
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      if (!savedNative) rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    await _deleteNative(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}

/// Offline persistence layer using Android Keystore (`SecureKvStore`) for
/// credentials/keys and transparent AES-256-GCM encryption over `sqflite`
/// (`ttg_vault_cache.db`) for large vault collections and clerk staging queues.
class LocalStorageService {
  LocalStorageService({
    SecureKeyStore? secureStore,
    this._databaseOpener,
  }) : _secureStore = secureStore ?? FlutterSecureKeyStore();

  static const String keyE2eKey = 'ttg_e2e_key';
  static const String keyLocalDbKey = 'ttg_local_db_key_v1';
  static const String keySaltVersion = 'ttg_salt_version';
  static const String keyUserId = 'ttg_user_id';
  static const String keyUserEmail = 'ttg_user_email';
  static const String keyBiometricEnabled = 'ttg_biometric_enabled';
  static const String keyLastPage = 'ttg_last_page';
  static const String keySavedPrinter = 'ttg_saved_printer';

  static const String encryptedRowPrefix = 'enc:v1:';
  static const int _ivLength = 12;
  static const int _macLength = 16;

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
  final AesGcm _localAesGcm = AesGcm.with256bits();
  Database? _db;
  Future<Database>? _openingDb;
  Map<String, dynamic>? _cachedE2eKey;
  SecretKey? _cachedLocalDbKey;
  Future<SecretKey>? _loadingLocalDbKey;

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

  Future<SecretKey> _getOrCreateLocalDbKey() async {
    final cached = _cachedLocalDbKey;
    if (cached != null) return cached;
    final inflight = _loadingLocalDbKey;
    if (inflight != null) return inflight;

    final future = _loadOrMintLocalDbKey();
    _loadingLocalDbKey = future;
    try {
      final key = await future;
      _cachedLocalDbKey = key;
      return key;
    } finally {
      if (identical(_loadingLocalDbKey, future)) {
        _loadingLocalDbKey = null;
      }
    }
  }

  Future<SecretKey> _loadOrMintLocalDbKey() async {
    String? encoded;
    try {
      encoded = await _secureStore.read(keyLocalDbKey);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      encoded = await _secureStore.read(keyLocalDbKey);
    }
    if (encoded != null && encoded.isNotEmpty) {
      try {
        final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
        final rawBytes = base64Url.decode(padded);
        if (rawBytes.length == 32) {
          return SecretKey(rawBytes);
        }
      } catch (_) {}
    }

    final freshKey = await _localAesGcm.newSecretKey();
    final freshBytes = await freshKey.extractBytes();
    final serialized = base64Url.encode(freshBytes).replaceAll('=', '');
    await _secureStore.write(keyLocalDbKey, serialized);
    return SecretKey(freshBytes);
  }

  Future<String> _encryptSqlValue(String plainText) async {
    final secretKey = await _getOrCreateLocalDbKey();
    final nonce = _localAesGcm.newNonce();
    final box = await _localAesGcm.encrypt(
      utf8.encode(plainText),
      secretKey: secretKey,
      nonce: nonce,
    );
    final macBytes = box.mac.bytes;
    final combined = Uint8List(_ivLength + box.cipherText.length + _macLength);
    combined.setRange(0, _ivLength, nonce);
    combined.setRange(_ivLength, _ivLength + box.cipherText.length, box.cipherText);
    combined.setRange(_ivLength + box.cipherText.length, combined.length, macBytes);
    return '$encryptedRowPrefix${base64Encode(combined)}';
  }

  Future<String?> _decryptSqlValue(String storedValue) async {
    if (!storedValue.startsWith(encryptedRowPrefix)) {
      return storedValue;
    }
    final b64 = storedValue.substring(encryptedRowPrefix.length);
    try {
      final bytes = base64Decode(b64);
      if (bytes.length < _ivLength + _macLength) return null;
      final secretKey = await _getOrCreateLocalDbKey();
      final nonce = bytes.sublist(0, _ivLength);
      final cipherText = bytes.sublist(_ivLength, bytes.length - _macLength);
      final mac = Mac(bytes.sublist(bytes.length - _macLength));
      final plainBytes = await _localAesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: secretKey,
      );
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }

  /// Ensures `kv_store` exists and seamlessly migrates any legacy plaintext
  /// cache rows to AES-256-GCM ciphertext without interrupting the user.
  Future<void> init() async {
    await _runWithDb((db) async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS kv_store (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      final legacyRows = await db.query(
        'kv_store',
        columns: ['key', 'value', 'updated_at'],
        where: 'value NOT LIKE ?',
        whereArgs: ['$encryptedRowPrefix%'],
      );
      if (legacyRows.isEmpty) return;

      final batch = db.batch();
      for (final row in legacyRows) {
        final k = row['key']?.toString();
        final v = row['value']?.toString();
        if (k == null || v == null) continue;
        final enc = await _encryptSqlValue(v);
        batch.update(
          'kv_store',
          {
            'value': enc,
            'updated_at': row['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
          },
          where: 'key = ?',
          whereArgs: [k],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // --- Secure Key Store ---

  /// Evicts cached key material from Dart RAM when Biometric App Lock locks
  /// the session in the background. Keys reload seamlessly from Android
  /// Keystore once unlocked — never prompting for a password.
  void evictInMemoryKeys() {
    _cachedE2eKey?.clear();
    _cachedE2eKey = null;
    _cachedLocalDbKey = null;
  }

  bool get hasCachedInMemoryKeys =>
      _cachedE2eKey != null || _cachedLocalDbKey != null;

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
    _cachedE2eKey?.clear();
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
    evictInMemoryKeys();
    await _secureStore.delete(keyUserId);
    await _secureStore.delete(keyUserEmail);
    await _secureStore.delete(keyE2eKey);
    await _secureStore.delete(keySaltVersion);
    await _secureStore.delete(keyLastPage);
    await _secureStore.delete(keyLocalDbKey);
  }

  // --- Encrypted SQLite Key-Value Store ---

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
      final stored = rows.first['value']?.toString();
      if (stored == null) return null;
      if (!stored.startsWith(encryptedRowPrefix)) {
        // Transparent on-the-fly upgrade if a legacy plaintext row was read before init().
        final encrypted = await _encryptSqlValue(stored);
        await db.update(
          'kv_store',
          {
            'value': encrypted,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'key = ?',
          whereArgs: [key],
        );
        return stored;
      }
      return _decryptSqlValue(stored);
    });
  }

  Future<void> setRaw(String key, String value) async {
    final encrypted = await _encryptSqlValue(value);
    await _runWithDb((db) async {
      await db.insert(
        'kv_store',
        {
          'key': key,
          'value': encrypted,
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
