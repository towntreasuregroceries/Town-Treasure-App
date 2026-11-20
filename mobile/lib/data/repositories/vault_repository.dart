import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../domain/models/models.dart';
import '../../ui/core/user_friendly_error.dart';
import '../services/crypto_service.dart';
import '../services/local_storage_service.dart';
import '../services/supabase_service.dart';

class KeyMigrationResult {
  const KeyMigrationResult({
    required this.key,
    required this.migrated,
  });

  final Map<String, dynamic> key;
  final bool migrated;
}

class RemoteInvoiceSnapshot {
  const RemoteInvoiceSnapshot({
    required this.ok,
    this.invoices = const [],
    this.revision = 0,
  });

  final bool ok;
  final List<Invoice> invoices;
  final int revision;
}

class _CachedRemoteVault {
  const _CachedRemoteVault({
    required this.userId,
    required this.revision,
    required this.data,
  });

  final String userId;
  final int revision;
  final String data;
}

/// Encrypted vault repository with revision compare-and-swap (CAS) sync and
/// deterministic tombstone/merge semantics matching `data.js`.
class VaultRepository extends ChangeNotifier {
  VaultRepository({
    required CryptoService cryptoService,
    required LocalStorageService localStorage,
    required this._supabase,
    this._syncDebounceDuration = const Duration(seconds: 3),
  })  : _crypto = cryptoService,
        _storage = localStorage;

  final CryptoService _crypto;
  final LocalStorageService _storage;
  final SupabaseGateway _supabase;
  final Duration _syncDebounceDuration;

  Future<Map<String, dynamic>> getSavedPrinterConfig() =>
      _storage.getSavedPrinterConfig();

  Future<void> savePrinterConfig(Map<String, dynamic> config) =>
      _storage.setSavedPrinterConfig(config);

  List<Restaurant> _restaurants = [];
  List<String> _deletedRestaurantIds = [];
  List<Invoice> _invoices = [];
  List<String> _deletedInvoiceIds = [];
  List<String> _restoredInvoiceIds = [];
  Map<String, Map<String, RecordAction>> _recordActions = {};
  List<Expense> _expenses = [];
  List<Invoice> _deletedInvoices = [];
  List<Staff> _staff = [];
  List<SalaryPayment> _salaryPayments = [];
  List<RecurringExpense> _recurringExpenses = [];
  List<PriceList> _priceLists = [];
  List<Staff> _deletedStaff = [];
  List<PriceList> _deletedPriceLists = [];
  List<Borrowing> _borrowings = [];
  VaultSettings _settings = const VaultSettings();

  Timer? _syncTimer;
  int _syncVersion = 0;
  Future<bool>? _syncInFlight;
  bool _syncRequestedAgain = false;
  int? _remoteRevision;
  _CachedRemoteVault? _remoteVaultCache;
  String? _lastSyncError;
  bool _isSyncing = false;

  // --- Read-only state getters ---

  List<Restaurant> get restaurants => List.unmodifiable(_restaurants);
  List<String> get deletedRestaurantIds =>
      List.unmodifiable(_deletedRestaurantIds);
  List<Invoice> get invoices => List.unmodifiable(_invoices);
  List<String> get deletedInvoiceIds => List.unmodifiable(_deletedInvoiceIds);
  List<String> get restoredInvoiceIds => List.unmodifiable(_restoredInvoiceIds);
  Map<String, Map<String, RecordAction>> get recordActions => _recordActions;
  List<Expense> get expenses => List.unmodifiable(_expenses);
  List<Invoice> get deletedInvoices => List.unmodifiable(_deletedInvoices);
  List<Staff> get staff => List.unmodifiable(_staff);
  List<SalaryPayment> get salaryPayments => List.unmodifiable(_salaryPayments);
  List<RecurringExpense> get recurringExpenses =>
      List.unmodifiable(_recurringExpenses);
  List<PriceList> get priceLists => List.unmodifiable(_priceLists);
  List<Staff> get deletedStaff => List.unmodifiable(_deletedStaff);
  List<PriceList> get deletedPriceLists =>
      List.unmodifiable(_deletedPriceLists);
  List<Borrowing> get borrowings => List.unmodifiable(_borrowings);
  VaultSettings get settings => _settings;
  KraCompanyProfile get kraProfile => _settings.kraProfile;
  List<PersonalDocument> get personalDocuments => _settings.personalDocuments;
  String get personalDocsWorkerUrl => _settings.personalDocsWorkerUrl;
  int? get remoteRevision => _remoteRevision;
  String? get lastSyncError => _lastSyncError;
  bool get isSyncing => _isSyncing;

  /// Computed next sequential invoice number matching `DB.nextInvNum` in `data.js`.
  int get nextInvNum {
    if (_invoices.isEmpty) return 1001;
    var maxNum = 1000;
    for (final inv in _invoices) {
      final numStr = inv.number.replaceAll('TTG-', '');
      final numPart = int.tryParse(numStr);
      if (numPart != null && numPart > maxNum) {
        maxNum = numPart;
      }
    }
    return maxNum + 1;
  }

  /// Generates a unique `TTG-XXXX` invoice number matching `invoices.js`.
  String generateSecureInvoiceNumber() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final used = <String>{
      for (final inv in [..._invoices, ..._deletedInvoices])
        if (!inv.isDraft && inv.number.isNotEmpty) inv.number.toUpperCase(),
    };
    final rng = Random.secure();
    for (var attempt = 0; attempt < 1000; attempt++) {
      final buf = StringBuffer('TTG-');
      for (var i = 0; i < 4; i++) {
        buf.write(chars[rng.nextInt(chars.length)]);
      }
      final candidate = buf.toString();
      if (!used.contains(candidate)) return candidate;
    }
    throw StateError(
      'Could not generate a unique invoice number. Please try saving again.',
    );
  }

  /// Hydrates in-memory state from offline SQLite cache.
  Future<void> loadFromLocalCache() async {
    await _storage.init();
    _restaurants = (await _storage.getJsonList(LocalStorageService.keyRestaurants))
        .map(Restaurant.fromJson)
        .toList();
    _deletedRestaurantIds =
        await _storage.getStringList(LocalStorageService.keyDeletedRestaurantIds);
    _invoices = (await _storage.getJsonList(LocalStorageService.keyInvoices))
        .map(Invoice.fromJson)
        .toList();
    _deletedInvoiceIds =
        await _storage.getStringList(LocalStorageService.keyDeletedInvoiceIds);
    _restoredInvoiceIds =
        await _storage.getStringList(LocalStorageService.keyRestoredInvoiceIds);
    _recordActions = _parseRecordActionsMap(
      await _storage.getJsonMap(LocalStorageService.keyRecordActions),
    );
    _expenses = (await _storage.getJsonList(LocalStorageService.keyExpenses))
        .map(Expense.fromJson)
        .toList();
    _deletedInvoices =
        (await _storage.getJsonList(LocalStorageService.keyDeletedInvoices))
            .map(Invoice.fromJson)
            .toList();
    _staff = (await _storage.getJsonList(LocalStorageService.keyStaff))
        .map(Staff.fromJson)
        .toList();
    _salaryPayments =
        (await _storage.getJsonList(LocalStorageService.keySalaryPayments))
            .map(SalaryPayment.fromJson)
            .toList();
    _recurringExpenses =
        (await _storage.getJsonList(LocalStorageService.keyRecurringExpenses))
            .map(RecurringExpense.fromJson)
            .toList();
    _priceLists = (await _storage.getJsonList(LocalStorageService.keyPriceLists))
        .map(PriceList.fromJson)
        .toList();
    _deletedStaff =
        (await _storage.getJsonList(LocalStorageService.keyDeletedStaff))
            .map(Staff.fromJson)
            .toList();
    _deletedPriceLists =
        (await _storage.getJsonList(LocalStorageService.keyDeletedPriceLists))
            .map(PriceList.fromJson)
            .toList();
    _borrowings = (await _storage.getJsonList(LocalStorageService.keyBorrowings))
        .map(Borrowing.fromJson)
        .toList();
    _settings = VaultSettings.fromJson(
      await _storage.getJsonMap(LocalStorageService.keySettings),
    );
    notifyListeners();
  }

  // --- Mutators (persist locally + schedule debounced sync) ---

  Future<void> setRestaurants(List<Restaurant> value, {bool sync = true}) async {
    _restaurants = List<Restaurant>.from(value);
    await _storage.setJson(
      LocalStorageService.keyRestaurants,
      _restaurants.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setDeletedRestaurantIds(List<String> value,
      {bool sync = true}) async {
    _deletedRestaurantIds = List<String>.from(value);
    await _storage.setJson(
      LocalStorageService.keyDeletedRestaurantIds,
      _deletedRestaurantIds,
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setInvoices(List<Invoice> value, {bool sync = true}) async {
    _invoices = List<Invoice>.from(value);
    await _storage.setJson(
      LocalStorageService.keyInvoices,
      _invoices.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setDeletedInvoiceIds(List<String> value,
      {bool sync = true}) async {
    _deletedInvoiceIds = List<String>.from(value);
    await _storage.setJson(
      LocalStorageService.keyDeletedInvoiceIds,
      _deletedInvoiceIds,
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setRestoredInvoiceIds(List<String> value,
      {bool sync = true}) async {
    _restoredInvoiceIds = List<String>.from(value);
    await _storage.setJson(
      LocalStorageService.keyRestoredInvoiceIds,
      _restoredInvoiceIds,
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setRecordActions(
    Map<String, Map<String, RecordAction>> value, {
    bool sync = true,
  }) async {
    _recordActions = _cloneRecordActions(value);
    await _storage.setJson(
      LocalStorageService.keyRecordActions,
      _recordActionsToJson(_recordActions),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setExpenses(List<Expense> value, {bool sync = true}) async {
    _expenses = List<Expense>.from(value);
    await _storage.setJson(
      LocalStorageService.keyExpenses,
      _expenses.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setDeletedInvoices(List<Invoice> value,
      {bool sync = true}) async {
    _deletedInvoices = List<Invoice>.from(value);
    await _storage.setJson(
      LocalStorageService.keyDeletedInvoices,
      _deletedInvoices.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setStaff(List<Staff> value, {bool sync = true}) async {
    _staff = List<Staff>.from(value);
    await _storage.setJson(
      LocalStorageService.keyStaff,
      _staff.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setSalaryPayments(List<SalaryPayment> value,
      {bool sync = true}) async {
    _salaryPayments = List<SalaryPayment>.from(value);
    await _storage.setJson(
      LocalStorageService.keySalaryPayments,
      _salaryPayments.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setRecurringExpenses(List<RecurringExpense> value,
      {bool sync = true}) async {
    _recurringExpenses = List<RecurringExpense>.from(value);
    await _storage.setJson(
      LocalStorageService.keyRecurringExpenses,
      _recurringExpenses.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setPriceLists(List<PriceList> value, {bool sync = true}) async {
    _priceLists = List<PriceList>.from(value);
    await _storage.setJson(
      LocalStorageService.keyPriceLists,
      _priceLists.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setDeletedStaff(List<Staff> value, {bool sync = true}) async {
    _deletedStaff = List<Staff>.from(value);
    await _storage.setJson(
      LocalStorageService.keyDeletedStaff,
      _deletedStaff.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setDeletedPriceLists(List<PriceList> value,
      {bool sync = true}) async {
    _deletedPriceLists = List<PriceList>.from(value);
    await _storage.setJson(
      LocalStorageService.keyDeletedPriceLists,
      _deletedPriceLists.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setBorrowings(List<Borrowing> value, {bool sync = true}) async {
    _borrowings = List<Borrowing>.from(value);
    await _storage.setJson(
      LocalStorageService.keyBorrowings,
      _borrowings.map((e) => e.toJson()).toList(),
    );
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> setSettings(VaultSettings value, {bool sync = true}) async {
    _settings = value;
    await _storage.setJson(LocalStorageService.keySettings, _settings.toJson());
    notifyListeners();
    if (sync) scheduleSync();
  }

  Future<void> saveKraProfile(
    KraCompanyProfile profile, {
    bool sync = true,
  }) async {
    await setSettings(_settings.withKraProfile(profile), sync: sync);
  }

  Future<void> savePersonalDocsWorkerUrl(
    String workerUrl, {
    bool sync = true,
  }) async {
    await setSettings(
      _settings.withPersonalDocsWorkerUrl(workerUrl),
      sync: sync,
    );
  }

  Future<void> savePersonalDocumentMeta(
    PersonalDocument doc, {
    bool sync = true,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updated = doc.copyWith(
      createdAt: doc.createdAt ?? nowIso,
      updatedAt: nowIso,
    );
    final docs = List<PersonalDocument>.from(_settings.allPersonalDocumentsRaw);
    final idx = docs.indexWhere((d) => d.id == updated.id);
    if (idx >= 0) {
      docs[idx] = updated;
    } else {
      docs.insert(0, updated);
    }
    await setSettings(_settings.withPersonalDocuments(docs), sync: sync);
  }

  Future<void> deletePersonalDocumentMeta(
    String docId, {
    bool sync = true,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final docs = List<PersonalDocument>.from(_settings.allPersonalDocumentsRaw);
    final idx = docs.indexWhere((d) => d.id == docId);
    if (idx < 0) return;
    docs[idx] = docs[idx].copyWith(
      deletedAt: nowIso,
      updatedAt: nowIso,
      r2Synced: false,
    );
    await setSettings(_settings.withPersonalDocuments(docs), sync: sync);
  }

  Future<void> markRecordDeleted(String collection, String id,
      {bool sync = true}) async {
    if (collection.isEmpty || id.isEmpty) return;
    final next = _cloneRecordActions(_recordActions);
    final byId = next.putIfAbsent(collection, () => {});
    final prev = byId[id] ?? const RecordAction();
    byId[id] = RecordAction(
      deletedAt: DateTime.now().millisecondsSinceEpoch,
      restoredAt: prev.restoredAt,
    );
    await setRecordActions(next, sync: sync);
  }

  Future<void> markRecordRestored(String collection, String id,
      {bool sync = true}) async {
    if (collection.isEmpty || id.isEmpty) return;
    final next = _cloneRecordActions(_recordActions);
    final byId = next.putIfAbsent(collection, () => {});
    final prev = byId[id] ?? const RecordAction();
    byId[id] = RecordAction(
      deletedAt: prev.deletedAt,
      restoredAt: DateTime.now().millisecondsSinceEpoch,
    );
    await setRecordActions(next, sync: sync);
  }

  // --- Static Merge & Tombstone Algorithms (100% parity with `data.js`) ---

  static Map<String, Map<String, RecordAction>> mergeRecordActions(
    Map<String, Map<String, RecordAction>> local,
    Map<String, Map<String, RecordAction>> remote,
  ) {
    final merged = <String, Map<String, RecordAction>>{};
    final collections = <String>{...local.keys, ...remote.keys};
    for (final collection in collections) {
      final localCol = local[collection] ?? const <String, RecordAction>{};
      final remoteCol = remote[collection] ?? const <String, RecordAction>{};
      final ids = <String>{...localCol.keys, ...remoteCol.keys};
      final outCol = <String, RecordAction>{};
      for (final id in ids) {
        final a = localCol[id] ?? const RecordAction();
        final b = remoteCol[id] ?? const RecordAction();
        outCol[id] = RecordAction(
          deletedAt: max(a.deletedAt, b.deletedAt),
          restoredAt: max(a.restoredAt, b.restoredAt),
        );
      }
      merged[collection] = outCol;
    }
    return merged;
  }

  static bool isRecordDeleted(
    Map<String, Map<String, RecordAction>> actions,
    String collection,
    String id,
  ) {
    final action = actions[collection]?[id];
    return action != null && action.isDeleted;
  }

  static Map<String, Map<String, RecordAction>> includeLegacyDeleteBins(
    Map<String, Map<String, RecordAction>> actions,
    String collection,
    List<Map<String, dynamic>> records,
  ) {
    final result = _cloneRecordActions(actions);
    final byId = result.putIfAbsent(collection, () => {});
    for (final item in records) {
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final current = byId[id] ?? const RecordAction();
      final parsedDeleted = AppHelpers.parseTimestampMs(item['deletedAt']);
      final deletedAt = parsedDeleted > 0 ? parsedDeleted : 1;
      byId[id] = RecordAction(
        deletedAt: max(current.deletedAt, deletedAt),
        restoredAt: current.restoredAt,
      );
    }
    return result;
  }

  static Map<String, Map<String, RecordAction>> includeLegacyInvoiceActions(
    Map<String, Map<String, RecordAction>> actions, {
    List<String> deletedIds = const [],
    List<String> restoredIds = const [],
    List<Invoice> deletedRecords = const [],
    List<Invoice> activeRecords = const [],
  }) {
    final result = _cloneRecordActions(actions);
    final byId = result.putIfAbsent('invoices', () => {});
    final deletedSet = deletedIds.toSet();
    final restoredSet = restoredIds.toSet();
    final deletedRecordIds = <String>{
      for (final item in deletedRecords)
        if (item.id.isNotEmpty) item.id,
    };
    final activeIds = <String>{
      for (final item in activeRecords)
        if (item.id.isNotEmpty) item.id,
    };
    final ids = <String>{...deletedSet, ...restoredSet, ...deletedRecordIds};
    for (final id in ids) {
      final current = byId[id];
      if (current != null &&
          (current.deletedAt > 0 || current.restoredAt > 0)) {
        continue;
      }
      final deletedAt =
          (deletedSet.contains(id) || deletedRecordIds.contains(id)) ? 1 : 0;
      final restoredAt =
          (restoredSet.contains(id) && activeIds.contains(id)) ? 2 : 0;
      byId[id] = RecordAction(deletedAt: deletedAt, restoredAt: restoredAt);
    }
    return result;
  }

  static List<Map<String, dynamic>> mergeRecordsById(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
    String collection,
    Map<String, Map<String, RecordAction>> actions, {
    bool deletedBin = false,
  }) {
    final map = <String, Map<String, dynamic>>{};
    final unkeyed = <Map<String, dynamic>>[];

    int freshness(Map<String, dynamic> record) {
      return AppHelpers.parseTimestampMs(
        record['updatedAt'] ?? record['createdAt'] ?? record['deletedAt'],
      );
    }

    for (final item in [...remote, ...local]) {
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) {
        unkeyed.add(item);
        continue;
      }
      if (isRecordDeleted(actions, collection, id) != deletedBin) continue;
      final current = map[id];
      if (current == null || freshness(item) > freshness(current)) {
        map[id] = item;
      }
    }
    return [...map.values, ...unkeyed];
  }

  static List<Invoice> mergeInvoicesById(
    List<Invoice> local,
    List<Invoice> remote,
    Map<String, Map<String, RecordAction>> actions,
  ) {
    final map = <String, Invoice>{};
    final unkeyed = <Invoice>[];
    final unkeyedJson = <String>{};

    int freshness(Invoice record) {
      return AppHelpers.parseTimestampMs(record.updatedAt ?? record.createdAt);
    }

    for (final invoice in [...remote, ...local]) {
      if (invoice.id.isNotEmpty &&
          isRecordDeleted(actions, 'invoices', invoice.id)) {
        continue;
      }
      final key = invoice.id.isNotEmpty
          ? 'id:${invoice.id}'
          : (invoice.number.trim().isNotEmpty
              ? 'number:${invoice.number.trim().toUpperCase()}'
              : '');
      if (key.isEmpty) {
        final encoded = jsonEncode(invoice.toJson());
        if (unkeyedJson.add(encoded)) {
          unkeyed.add(invoice);
        }
        continue;
      }
      final current = map[key];
      if (current == null || freshness(invoice) > freshness(current)) {
        map[key] = invoice;
      }
    }
    return [...map.values, ...unkeyed];
  }

  static List<Restaurant> mergeRestaurantsById(
    List<Restaurant> local,
    List<Restaurant> remote,
    Set<String> deletedIds,
  ) {
    final map = <String, Restaurant>{};

    int freshness(Restaurant r) {
      return AppHelpers.parseTimestampMs(r.updatedAt ?? r.createdAt);
    }

    for (final item in [...remote, ...local]) {
      if (item.id.isEmpty || deletedIds.contains(item.id)) continue;
      final current = map[item.id];
      if (current == null || freshness(item) > freshness(current)) {
        map[item.id] = item;
      }
    }
    return map.values.toList();
  }

  static VaultSettings mergeSettingsByTimestamp(
    VaultSettings local,
    VaultSettings remote,
  ) {
    final localTime = AppHelpers.parseTimestampMs(local.updatedAt);
    final remoteTime = AppHelpers.parseTimestampMs(remote.updatedAt);
    final localMap = local.toJson();
    final remoteMap = remote.toJson();
    final merged = localTime > remoteTime
        ? <String, dynamic>{...remoteMap, ...localMap}
        : <String, dynamic>{...localMap, ...remoteMap};

    // Merge nested `kraProfile` by its own `updatedAt` so a signature or document edit never clobbers tax config.
    final localKra = local.extra[VaultSettings.keyKraProfile];
    final remoteKra = remote.extra[VaultSettings.keyKraProfile];
    if (localKra is Map && remoteKra is Map) {
      final lKraTime = AppHelpers.parseTimestampMs(localKra['updatedAt']);
      final rKraTime = AppHelpers.parseTimestampMs(remoteKra['updatedAt']);
      merged[VaultSettings.keyKraProfile] = lKraTime >= rKraTime
          ? Map<String, dynamic>.from(localKra)
          : Map<String, dynamic>.from(remoteKra);
    }

    // Merge personal documents by `id` using latest `updatedAt` / `deletedAt` tombstone.
    final docsById = <String, PersonalDocument>{};
    for (final doc in [
      ...remote.allPersonalDocumentsRaw,
      ...local.allPersonalDocumentsRaw,
    ]) {
      final existing = docsById[doc.id];
      if (existing == null) {
        docsById[doc.id] = doc;
      } else {
        final dTime = AppHelpers.parseTimestampMs(
          doc.updatedAt ?? doc.deletedAt ?? doc.createdAt,
        );
        final eTime = AppHelpers.parseTimestampMs(
          existing.updatedAt ?? existing.deletedAt ?? existing.createdAt,
        );
        if (dTime >= eTime) {
          docsById[doc.id] = doc;
        }
      }
    }
    if (docsById.isNotEmpty) {
      merged[VaultSettings.keyPersonalDocs] =
          docsById.values.map((d) => d.toJson()).toList();
    }

    return VaultSettings.fromJson(merged);
  }

  // --- Sync & Remote Vault Operations ---

  void scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(_syncDebounceDuration, () {
      _syncTimer = null;
      _doSync();
    });
  }

  Future<bool> syncNow() {
    _syncTimer?.cancel();
    _syncTimer = null;
    return _doSync();
  }

  Future<bool> _doSync() async {
    if (_syncInFlight != null) {
      _syncRequestedAgain = true;
      return _syncInFlight!;
    }
    final completer = Completer<bool>();
    _syncInFlight = completer.future;
    _isSyncing = true;
    notifyListeners();

    var result = false;
    try {
      do {
        _syncRequestedAgain = false;
        result = await _performSync();
      } while (_syncRequestedAgain);
      completer.complete(result);
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _syncInFlight = null;
      _isSyncing = false;
      notifyListeners();
    }
    return result;
  }

  Future<String?> _getActiveUserId() async {
    final user = await _supabase.getCurrentUser();
    if (user != null && user.id.isNotEmpty) return user.id;
    return _storage.getUserId();
  }

  Future<RemoteVaultRow?> _readRemoteVault(String uid) async {
    final revision = await _supabase.readVaultRevision(uid);
    if (revision == null) {
      _remoteVaultCache = null;
      return null;
    }
    final cached = _remoteVaultCache;
    if (cached != null &&
        cached.userId == uid &&
        cached.revision == revision) {
      return RemoteVaultRow(
        data: cached.data,
        revision: revision,
        revisionSupported: true,
      );
    }
    final row = await _supabase.readVaultRow(uid);
    if (row == null) {
      _remoteVaultCache = null;
      return null;
    }
    if (row.data != null) {
      _remoteVaultCache = _CachedRemoteVault(
        userId: uid,
        revision: row.revision,
        data: row.data!,
      );
    }
    return row;
  }

  Future<bool> _performSync() async {
    final uid = await _getActiveUserId();
    if (uid == null || uid.isEmpty) return false;
    final jwkKey = await _storage.getE2eKey();
    if (jwkKey == null) return false;

    try {
      _lastSyncError = null;
      for (var attempt = 1; attempt <= 3; attempt++) {
        final remoteRow = await _readRemoteVault(uid);
        final expectedRevision = remoteRow?.revision ?? 0;
        if (expectedRevision < 0) {
          throw const VaultSyncException(
            'The server returned an invalid vault revision; sync was stopped to protect existing records.',
          );
        }
        _remoteRevision = expectedRevision;

        if (remoteRow != null &&
            remoteRow.data != null &&
            remoteRow.data!.isNotEmpty) {
          final remoteMap = await _crypto.decrypt(remoteRow.data, jwkKey);
          if (remoteMap == null) {
            throw const VaultSyncException(
              'Could not decrypt the current vault; sync was stopped to protect existing records.',
            );
          }
          final remoteVault = VaultData.fromJson(remoteMap);
          await _mergeRemoteVaultIntoState(remoteVault);
        }

        _syncVersion++;
        final payloadState = VaultData(
          vaultVersion: _syncVersion,
          lastSync: DateTime.now().toUtc().toIso8601String(),
          invoices: _invoices,
          deletedInvoiceIds: _deletedInvoiceIds,
          restoredInvoiceIds: _restoredInvoiceIds,
          recordActions: _recordActions,
          expenses: _expenses,
          restaurants: _restaurants,
          deletedRestaurantIds: _deletedRestaurantIds,
          deletedInvoices: _deletedInvoices,
          staff: _staff,
          salaryPayments: _salaryPayments,
          recurringExpenses: _recurringExpenses,
          priceLists: _priceLists,
          deletedStaff: _deletedStaff,
          deletedPriceLists: _deletedPriceLists,
          borrowings: _borrowings,
          settings: _settings,
        );
        final encryptedPayload =
            await _crypto.encrypt(payloadState.toJson(), jwkKey);

        final saveResult = await _supabase.saveEncryptedVaultCas(
          userId: uid,
          expectedRevision: expectedRevision,
          encryptedData: encryptedPayload,
        );

        if (saveResult.saved) {
          if (saveResult.revision != expectedRevision + 1) {
            throw const VaultSyncException(
              'The server returned an unexpected vault revision; sync was stopped.',
            );
          }
          _remoteRevision = saveResult.revision;
          _remoteVaultCache = _CachedRemoteVault(
            userId: uid,
            revision: saveResult.revision,
            data: encryptedPayload,
          );
          notifyListeners();
          return true;
        }

        _remoteRevision = saveResult.revision;
        if (attempt < 3) {
          continue;
        }
        throw const VaultSyncException(
          'The vault kept changing on another device. Your local data is safe; sync needs another attempt.',
          code: 'VAULT_REVISION_CONFLICT',
        );
      }
      return false;
    } on VaultSyncException catch (e) {
      _lastSyncError = UserFriendlyError.format(e);
      notifyListeners();
      return false;
    } catch (e) {
      _lastSyncError = UserFriendlyError.format(
        e,
        fallback: 'Could not sync with cloud right now. Saved locally.',
      );
      notifyListeners();
      return false;
    }
  }

  Future<bool> loadFromSupabase() async {
    _remoteRevision = null;
    final uid = await _getActiveUserId();
    if (uid == null || uid.isEmpty) return false;
    final jwkKey = await _storage.getE2eKey();
    if (jwkKey == null) return false;

    final localDeletedRestaurantIds = _deletedRestaurantIds.toSet();
    final localRestaurants = List<Restaurant>.from(_restaurants);
    final localSettings = _settings;
    final localInvoices = List<Invoice>.from(_invoices);
    final localDeletedInvoices = List<Invoice>.from(_deletedInvoices);
    final localDeletedInvoiceIds = _deletedInvoiceIds.toSet();
    final localRestoredInvoiceIds = _restoredInvoiceIds.toSet();
    final localRecordActions = _cloneRecordActions(_recordActions);
    final localExpenses = List<Expense>.from(_expenses);
    final localStaff = List<Staff>.from(_staff);
    final localSalaryPayments = List<SalaryPayment>.from(_salaryPayments);
    final localRecurringExpenses =
        List<RecurringExpense>.from(_recurringExpenses);
    final localPriceLists = List<PriceList>.from(_priceLists);
    final localDeletedStaff = List<Staff>.from(_deletedStaff);
    final localDeletedPriceLists = List<PriceList>.from(_deletedPriceLists);
    final localBorrowings = List<Borrowing>.from(_borrowings);

    try {
      var revisionSupport = true;
      RemoteVaultRow? row;
      try {
        row = await _readRemoteVault(uid);
      } on VaultSyncException catch (e) {
        if (e.code == 'VAULT_REVISION_MIGRATION_MISSING') {
          revisionSupport = false;
          final legacyData = await _supabase.readVaultDataOnly(uid);
          if (legacyData != null) {
            row = RemoteVaultRow(
              data: legacyData,
              revision: 0,
              revisionSupported: false,
            );
          }
        } else {
          rethrow;
        }
      }

      if (row != null && row.data != null && row.data!.isNotEmpty) {
        _remoteRevision = revisionSupport ? row.revision : null;
        final decrypted = await _crypto.decrypt(row.data, jwkKey);
        if (decrypted == null) {
          _lastSyncError = 'Failed to decrypt vault data.';
          notifyListeners();
          return false;
        }
        final remoteVault = VaultData.fromJson(decrypted);
        await _mergeRemoteVaultIntoState(remoteVault);

        final hasUnsynced = _hasUnsyncedLocalChanges(
          remoteVault: remoteVault,
          localInvoices: localInvoices,
          localRecordActions: localRecordActions,
          localDeletedRestaurantIds: localDeletedRestaurantIds,
          localDeletedInvoiceIds: localDeletedInvoiceIds,
          localRestoredInvoiceIds: localRestoredInvoiceIds,
          localDeletedInvoices: localDeletedInvoices,
          localRestaurants: localRestaurants,
          localExpenses: localExpenses,
          localStaff: localStaff,
          localSalaryPayments: localSalaryPayments,
          localRecurringExpenses: localRecurringExpenses,
          localPriceLists: localPriceLists,
          localDeletedStaff: localDeletedStaff,
          localDeletedPriceLists: localDeletedPriceLists,
          localBorrowings: localBorrowings,
          localSettings: localSettings,
        );
        if (hasUnsynced) {
          scheduleSync();
        }
        notifyListeners();
        return true;
      }

      _remoteRevision = revisionSupport ? 0 : null;
      notifyListeners();
      return true;
    } catch (e) {
      _lastSyncError = UserFriendlyError.format(
        e,
        fallback: 'Could not refresh cloud data. Showing your local records.',
      );
      notifyListeners();
      return false;
    }
  }

  /// Attempts per-user v2 salt key first, falling back safely to legacy v1
  /// static salt and migrating via CAS write (`migrateE2EKey` in `data.js`).
  Future<KeyMigrationResult> migrateE2EKey(
    String password,
    String? userId,
  ) async {
    final newKey = await _crypto.deriveKey(password, userId);
    await _storage.setE2eKey(newKey);

    final loaded = await loadFromSupabase();
    if (loaded) {
      await _storage.setSaltVersion('2');
      return KeyMigrationResult(key: newKey, migrated: false);
    }

    final legacyKey = await _crypto.deriveKeyLegacy(password);
    await _storage.setE2eKey(legacyKey);

    final legacyLoaded = await loadFromSupabase();
    if (legacyLoaded) {
      _syncTimer?.cancel();
      _syncTimer = null;
      if (_syncInFlight != null) {
        await _syncInFlight;
      }
      final migrated = await reencryptVault(newKey);
      if (migrated) {
        await _storage.setE2eKey(newKey);
        await _storage.setSaltVersion('2');
        return KeyMigrationResult(key: newKey, migrated: true);
      }
      await _storage.setE2eKey(legacyKey);
      return KeyMigrationResult(key: legacyKey, migrated: false);
    }

    await _storage.setE2eKey(legacyKey);
    return KeyMigrationResult(key: legacyKey, migrated: false);
  }

  /// Re-encrypts the already-loaded vault using `newJwkKey` with CAS guard.
  Future<bool> reencryptVault(Map<String, dynamic> newJwkKey) async {
    final uid = await _getActiveUserId();
    if (uid == null || uid.isEmpty) return false;
    final expectedRev = _remoteRevision;
    if (expectedRev == null || expectedRev < 0) {
      return false;
    }

    try {
      _syncVersion++;
      final appState = VaultData(
        vaultVersion: _syncVersion,
        lastSync: DateTime.now().toUtc().toIso8601String(),
        invoices: _invoices,
        deletedInvoiceIds: _deletedInvoiceIds,
        restoredInvoiceIds: _restoredInvoiceIds,
        recordActions: _recordActions,
        expenses: _expenses,
        restaurants: _restaurants,
        deletedRestaurantIds: _deletedRestaurantIds,
        deletedInvoices: _deletedInvoices,
        staff: _staff,
        salaryPayments: _salaryPayments,
        recurringExpenses: _recurringExpenses,
        priceLists: _priceLists,
        deletedStaff: _deletedStaff,
        deletedPriceLists: _deletedPriceLists,
        borrowings: _borrowings,
        settings: _settings,
      );
      final encryptedPayload =
          await _crypto.encrypt(appState.toJson(), newJwkKey);
      final saveResult = await _supabase.saveEncryptedVaultCas(
        userId: uid,
        expectedRevision: expectedRev,
        encryptedData: encryptedPayload,
      );
      if (!saveResult.saved || saveResult.revision != expectedRev + 1) {
        return false;
      }
      _remoteRevision = saveResult.revision;
      _remoteVaultCache = _CachedRemoteVault(
        userId: uid,
        revision: saveResult.revision,
        data: encryptedPayload,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reads the current server non-draft invoices without mutating local state.
  Future<RemoteInvoiceSnapshot> getRemoteInvoiceSnapshot() async {
    final uid = await _getActiveUserId();
    if (uid == null || uid.isEmpty) {
      return const RemoteInvoiceSnapshot(ok: false);
    }
    final jwkKey = await _storage.getE2eKey();
    if (jwkKey == null) {
      return const RemoteInvoiceSnapshot(ok: false);
    }

    try {
      RemoteVaultRow? row;
      try {
        row = await _readRemoteVault(uid);
      } on VaultSyncException catch (e) {
        if (e.code == 'VAULT_REVISION_MIGRATION_MISSING') {
          final data = await _supabase.readVaultDataOnly(uid);
          if (data != null) {
            row = RemoteVaultRow(
              data: data,
              revision: 0,
              revisionSupported: false,
            );
          }
        } else {
          rethrow;
        }
      }
      if (row == null || row.data == null || row.data!.isEmpty) {
        return RemoteInvoiceSnapshot(
          ok: true,
          invoices: const [],
          revision: row?.revision ?? 0,
        );
      }

      final decrypted = await _crypto.decrypt(row.data, jwkKey);
      if (decrypted == null) {
        return const RemoteInvoiceSnapshot(ok: false);
      }
      final vault = VaultData.fromJson(decrypted);
      final actions = includeLegacyInvoiceActions(
        vault.recordActions,
        deletedIds: vault.deletedInvoiceIds,
        restoredIds: vault.restoredInvoiceIds,
        deletedRecords: vault.deletedInvoices,
        activeRecords: vault.invoices,
      );
      final invoices = mergeInvoicesById(const [], vault.invoices, actions)
          .where((inv) => !inv.isDraft)
          .toList();
      return RemoteInvoiceSnapshot(
        ok: true,
        invoices: invoices,
        revision: row.revision,
      );
    } catch (_) {
      return const RemoteInvoiceSnapshot(ok: false);
    }
  }

  Future<void> clearLocalData() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    _remoteVaultCache = null;
    _remoteRevision = null;
    _restaurants = [];
    _deletedRestaurantIds = [];
    _invoices = [];
    _deletedInvoiceIds = [];
    _restoredInvoiceIds = [];
    _recordActions = {};
    _expenses = [];
    _deletedInvoices = [];
    _staff = [];
    _salaryPayments = [];
    _recurringExpenses = [];
    _priceLists = [];
    _deletedStaff = [];
    _deletedPriceLists = [];
    _borrowings = [];
    _settings = const VaultSettings();
    await _storage.clearVaultData();
    notifyListeners();
  }

  // --- Internal Merge & Persistence Helpers ---

  Future<void> _mergeRemoteVaultIntoState(VaultData remoteVault) async {
    var actions = mergeRecordActions(_recordActions, remoteVault.recordActions);
    actions = includeLegacyInvoiceActions(
      actions,
      deletedIds: [..._deletedInvoiceIds, ...remoteVault.deletedInvoiceIds],
      restoredIds: [..._restoredInvoiceIds, ...remoteVault.restoredInvoiceIds],
      deletedRecords: [..._deletedInvoices, ...remoteVault.deletedInvoices],
      activeRecords: [..._invoices, ...remoteVault.invoices],
    );
    actions = includeLegacyDeleteBins(
      actions,
      'staff',
      [
        ..._deletedStaff.map((e) => e.toJson()),
        ...remoteVault.deletedStaff.map((e) => e.toJson()),
      ],
    );
    actions = includeLegacyDeleteBins(
      actions,
      'priceLists',
      [
        ..._deletedPriceLists.map((e) => e.toJson()),
        ...remoteVault.deletedPriceLists.map((e) => e.toJson()),
      ],
    );

    final invoiceActions = actions['invoices'] ?? const <String, RecordAction>{};
    final deletedInvIds = invoiceActions.keys
        .where((id) => isRecordDeleted(actions, 'invoices', id))
        .toList();
    final restoredInvIds = invoiceActions.keys
        .where(
          (id) =>
              !isRecordDeleted(actions, 'invoices', id) &&
              (invoiceActions[id]?.restoredAt ?? 0) > 0,
        )
        .toList();

    final mergedInvoices =
        mergeInvoicesById(_invoices, remoteVault.invoices, actions)
          ..sort((a, b) {
            final dateCmp =
                AppHelpers.appDateKey(b.date).compareTo(AppHelpers.appDateKey(a.date));
            if (dateCmp != 0) return dateCmp;
            return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
          });

    final mergedDeletedInvoices = mergeRecordsById(
      _deletedInvoices.map((e) => e.toJson()).toList(),
      remoteVault.deletedInvoices.map((e) => e.toJson()).toList(),
      'invoices',
      actions,
      deletedBin: true,
    ).map(Invoice.fromJson).toList();

    final deletedRestIds = <String>{
      ..._deletedRestaurantIds,
      ...remoteVault.deletedRestaurantIds,
    };
    final mergedRestaurants = mergeRestaurantsById(
      _restaurants,
      remoteVault.restaurants,
      deletedRestIds,
    );

    final mergedExpenses = mergeRecordsById(
      _expenses.map((e) => e.toJson()).toList(),
      remoteVault.expenses.map((e) => e.toJson()).toList(),
      'expenses',
      actions,
    ).map(Expense.fromJson).toList();

    final mergedStaff = mergeRecordsById(
      _staff.map((e) => e.toJson()).toList(),
      remoteVault.staff.map((e) => e.toJson()).toList(),
      'staff',
      actions,
    ).map(Staff.fromJson).toList();

    final mergedSalaryPayments = mergeRecordsById(
      _salaryPayments.map((e) => e.toJson()).toList(),
      remoteVault.salaryPayments.map((e) => e.toJson()).toList(),
      'salaryPayments',
      actions,
    ).map(SalaryPayment.fromJson).toList();

    final mergedRecurring = mergeRecordsById(
      _recurringExpenses.map((e) => e.toJson()).toList(),
      remoteVault.recurringExpenses.map((e) => e.toJson()).toList(),
      'recurringExpenses',
      actions,
    ).map(RecurringExpense.fromJson).toList();

    final mergedPriceLists = mergeRecordsById(
      _priceLists.map((e) => e.toJson()).toList(),
      remoteVault.priceLists.map((e) => e.toJson()).toList(),
      'priceLists',
      actions,
    ).map(PriceList.fromJson).toList();

    final mergedBorrowings = mergeRecordsById(
      _borrowings.map((e) => e.toJson()).toList(),
      remoteVault.borrowings.map((e) => e.toJson()).toList(),
      'borrowings',
      actions,
    ).map(Borrowing.fromJson).toList();

    final mergedDeletedStaff = mergeRecordsById(
      _deletedStaff.map((e) => e.toJson()).toList(),
      remoteVault.deletedStaff.map((e) => e.toJson()).toList(),
      'staff',
      actions,
      deletedBin: true,
    ).map(Staff.fromJson).toList();

    final mergedDeletedPriceLists = mergeRecordsById(
      _deletedPriceLists.map((e) => e.toJson()).toList(),
      remoteVault.deletedPriceLists.map((e) => e.toJson()).toList(),
      'priceLists',
      actions,
      deletedBin: true,
    ).map(PriceList.fromJson).toList();

    final mergedSettings =
        mergeSettingsByTimestamp(_settings, remoteVault.settings);

    _recordActions = actions;
    _deletedInvoiceIds = deletedInvIds;
    _restoredInvoiceIds = restoredInvIds;
    _invoices = mergedInvoices;
    _deletedInvoices = mergedDeletedInvoices;
    _deletedRestaurantIds = deletedRestIds.toList();
    _restaurants = mergedRestaurants;
    _expenses = mergedExpenses;
    _staff = mergedStaff;
    _salaryPayments = mergedSalaryPayments;
    _recurringExpenses = mergedRecurring;
    _priceLists = mergedPriceLists;
    _borrowings = mergedBorrowings;
    _deletedStaff = mergedDeletedStaff;
    _deletedPriceLists = mergedDeletedPriceLists;
    _settings = mergedSettings;

    await _persistAllToStorage();
  }

  Future<void> _persistAllToStorage() async {
    await _storage.setJson(
      LocalStorageService.keyInvoices,
      _invoices.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyDeletedInvoiceIds,
      _deletedInvoiceIds,
    );
    await _storage.setJson(
      LocalStorageService.keyRestoredInvoiceIds,
      _restoredInvoiceIds,
    );
    await _storage.setJson(
      LocalStorageService.keyRecordActions,
      _recordActionsToJson(_recordActions),
    );
    await _storage.setJson(
      LocalStorageService.keyExpenses,
      _expenses.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyRestaurants,
      _restaurants.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyDeletedRestaurantIds,
      _deletedRestaurantIds,
    );
    await _storage.setJson(
      LocalStorageService.keyDeletedInvoices,
      _deletedInvoices.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyStaff,
      _staff.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keySalaryPayments,
      _salaryPayments.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyRecurringExpenses,
      _recurringExpenses.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyPriceLists,
      _priceLists.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyDeletedStaff,
      _deletedStaff.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyDeletedPriceLists,
      _deletedPriceLists.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keyBorrowings,
      _borrowings.map((e) => e.toJson()).toList(),
    );
    await _storage.setJson(
      LocalStorageService.keySettings,
      _settings.toJson(),
    );
  }

  bool _hasUnsyncedLocalChanges({
    required VaultData remoteVault,
    required List<Invoice> localInvoices,
    required Map<String, Map<String, RecordAction>> localRecordActions,
    required Set<String> localDeletedRestaurantIds,
    required Set<String> localDeletedInvoiceIds,
    required Set<String> localRestoredInvoiceIds,
    required List<Invoice> localDeletedInvoices,
    required List<Restaurant> localRestaurants,
    required List<Expense> localExpenses,
    required List<Staff> localStaff,
    required List<SalaryPayment> localSalaryPayments,
    required List<RecurringExpense> localRecurringExpenses,
    required List<PriceList> localPriceLists,
    required List<Staff> localDeletedStaff,
    required List<PriceList> localDeletedPriceLists,
    required List<Borrowing> localBorrowings,
    required VaultSettings localSettings,
  }) {
    final remoteInvoiceMap = <String, Invoice>{};
    for (final inv in remoteVault.invoices) {
      final key = inv.id.isNotEmpty
          ? inv.id
          : (inv.number.trim().isNotEmpty
              ? 'number:${inv.number.trim().toUpperCase()}'
              : '');
      if (key.isNotEmpty) remoteInvoiceMap[key] = inv;
    }

    int freshness(Invoice inv) =>
        AppHelpers.parseTimestampMs(inv.updatedAt ?? inv.createdAt);

    final deletedSet = _deletedInvoiceIds.toSet();
    final hasUnsyncedInvoice = localInvoices.any((inv) {
      final key = inv.id.isNotEmpty
          ? inv.id
          : (inv.number.trim().isNotEmpty
              ? 'number:${inv.number.trim().toUpperCase()}'
              : '');
      if (key.isEmpty || (inv.id.isNotEmpty && deletedSet.contains(inv.id))) {
        return false;
      }
      final remote = remoteInvoiceMap[key];
      return remote == null || freshness(inv) > freshness(remote);
    });

    if (hasUnsyncedInvoice) return true;
    if (jsonEncode(_recordActionsToJson(localRecordActions)) !=
        jsonEncode(_recordActionsToJson(remoteVault.recordActions))) {
      return true;
    }
    if (localDeletedRestaurantIds
        .any((id) => !remoteVault.deletedRestaurantIds.contains(id))) {
      return true;
    }
    if (_deletedInvoiceIds
        .any((id) => !remoteVault.deletedInvoiceIds.contains(id))) {
      return true;
    }
    if (_restoredInvoiceIds
        .any((id) => !remoteVault.restoredInvoiceIds.contains(id))) {
      return true;
    }

    bool listChanged(List<Object> merged, List<Object> remote) =>
        jsonEncode(merged) != jsonEncode(remote);

    if (listChanged(
      _restaurants.map((e) => e.toJson()).toList(),
      remoteVault.restaurants.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _expenses.map((e) => e.toJson()).toList(),
      remoteVault.expenses.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _staff.map((e) => e.toJson()).toList(),
      remoteVault.staff.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _salaryPayments.map((e) => e.toJson()).toList(),
      remoteVault.salaryPayments.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _recurringExpenses.map((e) => e.toJson()).toList(),
      remoteVault.recurringExpenses.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _priceLists.map((e) => e.toJson()).toList(),
      remoteVault.priceLists.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (listChanged(
      _borrowings.map((e) => e.toJson()).toList(),
      remoteVault.borrowings.map((e) => e.toJson()).toList(),
    )) {
      return true;
    }
    if (jsonEncode(_settings.toJson()) !=
        jsonEncode(remoteVault.settings.toJson())) {
      return true;
    }

    return false;
  }

  static Map<String, Map<String, RecordAction>> _parseRecordActionsMap(
    Map<String, dynamic> raw,
  ) {
    final result = <String, Map<String, RecordAction>>{};
    raw.forEach((collection, records) {
      if (records is Map) {
        final byId = <String, RecordAction>{};
        records.forEach((id, action) {
          if (action is Map) {
            byId[id.toString()] =
                RecordAction.fromJson(Map<String, dynamic>.from(action));
          }
        });
        result[collection] = byId;
      }
    });
    return result;
  }

  static Map<String, Map<String, RecordAction>> _cloneRecordActions(
    Map<String, Map<String, RecordAction>> source,
  ) {
    return source.map(
      (collection, records) => MapEntry(
        collection,
        Map<String, RecordAction>.from(records),
      ),
    );
  }

  static Map<String, dynamic> _recordActionsToJson(
    Map<String, Map<String, RecordAction>> actions,
  ) {
    return actions.map(
      (collection, records) => MapEntry(
        collection,
        records.map((id, action) => MapEntry(id, action.toJson())),
      ),
    );
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }
}
