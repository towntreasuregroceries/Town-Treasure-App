import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/models.dart';
import '../services/local_storage_service.dart';
import '../services/supabase_service.dart';
import 'vault_repository.dart';

/// Maker-checker clerk staging repository matching `StagingDB` in `staging.js`.
class StagingRepository extends ChangeNotifier {
  StagingRepository({
    required this._supabase,
    required LocalStorageService localStorage,
    required VaultRepository vaultRepository,
  })  : _storage = localStorage,
        _vault = vaultRepository;

  final SupabaseGateway _supabase;
  final LocalStorageService _storage;
  final VaultRepository _vault;

  List<StagingDocket> _cachedSubmissions = [];
  int _pendingCount = 0;

  List<StagingDocket> get cachedSubmissions =>
      List.unmodifiable(_cachedSubmissions);
  int get pendingCount => _pendingCount;

  /// Returns locally cached staging items, purging any legacy `stg_demo_` rows.
  Future<List<StagingDocket>> getLocalQueue() async {
    final raw =
        await _storage.getJsonList(LocalStorageService.keyStagedInvoices);
    final clean = <StagingDocket>[];
    var changed = false;
    for (final row in raw) {
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty || id.startsWith('stg_demo_')) {
        changed = true;
        continue;
      }
      clean.add(StagingDocket.fromJson(row));
    }
    if (changed) {
      await setLocalQueue(clean);
    }
    return clean;
  }

  Future<void> setLocalQueue(List<StagingDocket> list) async {
    await _storage.setJson(
      LocalStorageService.keyStagedInvoices,
      list.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<String>> getDeletedQueueIds() =>
      _storage.getStringList(LocalStorageService.keyDeletedStagedInvoiceIds);

  Future<void> setDeletedQueueIds(List<String> ids) async {
    await _storage.setJson(
      LocalStorageService.keyDeletedStagedInvoiceIds,
      ids.toSet().toList(),
    );
  }

  /// Ownership isolation filter matching `isSubmissionForUser` in `staging.js`.
  static bool isSubmissionForUser(
    StagingDocket item, {
    required String? userId,
    required String? userEmail,
  }) {
    final uid = (userId ?? '').trim();
    final email = (userEmail ?? '').trim().toLowerCase();
    if (uid.isEmpty && email.isEmpty) return false;

    if (item.ownerUserId != null && item.ownerUserId!.isNotEmpty) {
      return uid.isNotEmpty && item.ownerUserId == uid;
    }

    if ((item.targetUserId != null && item.targetUserId!.isNotEmpty) ||
        (item.targetUserEmail != null && item.targetUserEmail!.isNotEmpty)) {
      if (uid.isNotEmpty && item.targetUserId == uid) return true;
      if (email.isNotEmpty &&
          item.targetUserEmail?.toLowerCase().trim() == email) {
        return true;
      }
      return false;
    }

    if (item.notes.contains('[Target:')) {
      if (email.isNotEmpty && item.notes.toLowerCase().contains(email)) {
        return true;
      }
      if (uid.isNotEmpty && item.notes.contains(uid)) return true;
      return false;
    }

    if (email.isNotEmpty &&
        (email.contains('veron') || email.contains('njuguna'))) {
      return true;
    }
    return false;
  }

  Future<({String? uid, String? email})> _getCurrentIdentity() async {
    final user = await _supabase.getCurrentUser();
    final uid = user?.id ?? await _storage.getUserId();
    final email = (user?.email ?? await _storage.getUserEmail() ?? '')
        .toLowerCase()
        .trim();
    return (uid: uid, email: email.isEmpty ? null : email);
  }

  /// Fetches submissions combining Supabase and offline queue with isolation.
  Future<List<StagingDocket>> getAllSubmissions({
    bool filterForCurrentUser = true,
  }) async {
    final ident = await _getCurrentIdentity();
    final uid = ident.uid;
    if (uid == null || uid.isEmpty) return [];

    final deletedIds = (await getDeletedQueueIds()).toSet();
    final local = (await getLocalQueue()).where((item) {
      if (deletedIds.contains(item.id)) return false;
      if (item.ownerUserId == uid || item.targetUserId == uid) return true;
      if (ident.email != null &&
          item.targetUserEmail?.toLowerCase().trim() == ident.email) {
        return true;
      }
      return false;
    }).toList();

    List<StagingDocket> combined = local;
    final hasSb = await _supabase.checkStagedInvoicesAccessible();
    if (hasSb) {
      try {
        final rows = await _supabase.fetchStagedInvoices(uid);
        final map = <String, StagingDocket>{};
        for (final row in rows) {
          final docket = StagingDocket.fromJson(row);
          if (docket.id.isEmpty || docket.id.startsWith('stg_demo_')) continue;
          map[docket.id] = docket;
        }
        for (final item in local) {
          if (!item.id.startsWith('stg_demo_') && !map.containsKey(item.id)) {
            map[item.id] = item;
          }
        }
        combined = map.values
            .where((item) => !deletedIds.contains(item.id))
            .toList();
      } catch (_) {
        combined = local.where((x) => !deletedIds.contains(x.id)).toList();
      }
    }

    final result = filterForCurrentUser
        ? combined
            .where(
              (item) => isSubmissionForUser(
                item,
                userId: uid,
                userEmail: ident.email,
              ),
            )
            .toList()
        : combined;

    _cachedSubmissions = result;
    _pendingCount = result.where((d) => d.isPending).length;
    notifyListeners();
    return result;
  }

  /// Fetches lightweight pending submission headers for badge counts.
  Future<List<StagingDocket>> getPendingSubmissions() async {
    final ident = await _getCurrentIdentity();
    final deletedIds = (await getDeletedQueueIds()).toSet();

    if (await _supabase.checkStagedInvoicesAccessible()) {
      try {
        final rows = await _supabase.fetchPendingStagedInvoices();
        final pending = rows
            .map(StagingDocket.fromJson)
            .where(
              (item) =>
                  item.id.isNotEmpty &&
                  !deletedIds.contains(item.id) &&
                  isSubmissionForUser(
                    item,
                    userId: ident.uid,
                    userEmail: ident.email,
                  ),
            )
            .toList();
        _pendingCount = pending.length;
        notifyListeners();
        return pending;
      } catch (_) {
        // Fall through to local queue on network/query failure.
      }
    }

    final localPending = (await getLocalQueue())
        .where(
          (item) =>
              item.isPending &&
              item.id.isNotEmpty &&
              !deletedIds.contains(item.id) &&
              isSubmissionForUser(
                item,
                userId: ident.uid,
                userEmail: ident.email,
              ),
        )
        .toList();
    _pendingCount = localPending.length;
    notifyListeners();
    return localPending;
  }

  /// Fetches one full docket including receipt photos when opened for review.
  Future<StagingDocket?> getSubmission(String id) async {
    if (id.isEmpty) throw ArgumentError('A docket ID is required.');
    final ident = await _getCurrentIdentity();
    if (ident.uid == null || ident.uid!.isEmpty) {
      throw StateError('Sign in to view this docket.');
    }
    final row = await _supabase.fetchStagedInvoiceById(ident.uid!, id);
    return row == null ? null : StagingDocket.fromJson(row);
  }

  /// Submits or updates a staged docket to Supabase and updates local cache.
  Future<StagingDocket> submitDocket(StagingDocket docket) async {
    final ident = await _getCurrentIdentity();
    final signedInUserId = ident.uid;
    if (signedInUserId == null || signedInUserId.isEmpty) {
      throw StateError('Sign in to save a clerk docket to the review queue.');
    }
    if (!await _supabase.checkStagedInvoicesAccessible()) {
      throw StateError(
        'Could not reach the secure review queue. The docket was not submitted; retry when connected.',
      );
    }

    final targetId = docket.targetUserId ?? signedInUserId;
    final targetEmail = docket.targetUserEmail ?? ident.email;
    final targetName = docket.targetUserName ?? 'Owner';

    var formattedNotes = docket.notes.trim();
    if (targetName.isNotEmpty || (targetEmail != null && targetEmail.isNotEmpty)) {
      final emailPart =
          targetEmail != null && targetEmail.isNotEmpty ? ' ($targetEmail)' : '';
      final targetTag = '[Target: $targetName$emailPart]';
      if (!formattedNotes.contains('[Target:')) {
        formattedNotes =
            formattedNotes.isNotEmpty ? '$targetTag $formattedNotes' : targetTag;
      }
    }

    final record = docket.copyWith(
      id: docket.id.isNotEmpty ? docket.id : 'stg_${AppHelpers.genId()}',
      ownerUserId: signedInUserId,
      notes: formattedNotes,
      status: 'pending',
      rejectionReason: '',
      targetUserId: targetId,
      targetUserEmail: targetEmail,
      targetUserName: targetName,
      createdAt: docket.createdAt ?? DateTime.now().toUtc().toIso8601String(),
    );

    await _supabase.upsertStagedInvoice(record.toJson());

    final deleted = (await getDeletedQueueIds())
        .where((id) => id != record.id)
        .toList();
    await setDeletedQueueIds(deleted);

    final local = await getLocalQueue();
    final idx = local.indexWhere((x) => x.id == record.id);
    if (idx >= 0) {
      local[idx] = record;
    } else {
      local.insert(0, record);
    }
    await setLocalQueue(local);
    await getPendingSubmissions();
    return record;
  }

  /// Approves a staged docket and commits it into the encrypted vault with CAS sync.
  /// Mirrors the idempotency and strict restaurant checks in `staging.js`.
  Future<Invoice> approveSubmission(
    String id, {
    String? restaurantName,
    String? date,
    String? dueDate,
    List<InvoiceLineItem>? items,
    double? deliveryCost,
    double? otherCost,
  }) async {
    final all = await getAllSubmissions(filterForCurrentUser: false);
    final idx = all.indexWhere((x) => x.id == id);
    if (idx < 0) {
      throw StateError('Submission not found in staging queue.');
    }
    final item = all[idx];

    // Idempotency guard: reuse an already-committed invoice for this docket.
    Invoice? existingInvoice;
    for (final inv in _vault.invoices) {
      if (inv.sourceSubmissionId == id ||
          (item.generatedInvoiceNumber != null &&
              inv.number == item.generatedInvoiceNumber)) {
        existingInvoice = inv;
        break;
      }
    }
    if (existingInvoice != null) {
      final synced = await _vault.syncNow();
      if (!synced) {
        throw StateError(
          'The invoice is only saved locally because the encrypted vault did not confirm sync. Retry sync before approving again.',
        );
      }
      final updated = await _supabase.updateStagedInvoiceStatus(id, {
        'status': 'approved',
        'rejection_reason': '',
      });
      if (!updated) {
        throw StateError(
          'The invoice is in the vault, but the staged docket status could not be updated.',
        );
      }
      await _updateLocalDocketApproved(item, existingInvoice.number);
      await getPendingSubmissions();
      return existingInvoice;
    }

    for (final archived in _vault.deletedInvoices) {
      if (archived.sourceSubmissionId == id ||
          (item.generatedInvoiceNumber != null &&
              archived.number == item.generatedInvoiceNumber)) {
        throw StateError(
          'This docket already has invoice ${archived.number} in the Recycle Bin. Restore that invoice instead of approving again.',
        );
      }
    }

    if (!item.isPending) {
      throw StateError(
        'This docket is already ${item.status}. No new invoice was created.',
      );
    }

    final resolvedItems = (items ?? item.itemsJson).map((it) {
      final qty = it.qty <= 0 ? 1.0 : it.qty;
      return it.copyWith(
        desc: it.desc.trim().isEmpty ? 'Produce Item' : it.desc.trim(),
        qty: qty,
        total: qty * it.sellPrice,
      );
    }).toList();

    final totalSell =
        resolvedItems.fold<double>(0, (sum, it) => sum + it.total);
    final totalBuy = resolvedItems.fold<double>(
        0, (sum, it) => sum + (it.qty * it.buyPrice));
    final effectiveDelivery = deliveryCost ?? item.deliveryCost;
    final effectiveOther = otherCost ?? item.otherCost;
    final profit = totalSell - totalBuy - effectiveDelivery - effectiveOther;

    final candidateRestName = (restaurantName ?? item.restaurantName).trim();
    final resolution =
        Restaurant.resolveName(candidateRestName, _vault.restaurants);
    if (resolution.status != RestaurantResolutionStatus.matched ||
        resolution.restaurant == null) {
      throw StateError(
        'This restaurant name is not uniquely registered. Confirm an existing match or create the restaurant before approving.',
      );
    }
    final matchedRestaurant = resolution.restaurant!;
    final invDate = date ??
        (item.invoiceDate.isNotEmpty
            ? item.invoiceDate
            : AppHelpers.normalizeAppDate(DateTime.now()));
    final invNumber = _vault.generateSecureInvoiceNumber();

    final clerkNote =
        item.clerkName.isNotEmpty ? '[Submitted by Clerk: ${item.clerkName}]' : '';
    final combinedNotes =
        [item.notes, clerkNote].where((s) => s.isNotEmpty).join(' ');
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final newInvoice = Invoice(
      id: 'stg_$id',
      sourceSubmissionId: id,
      number: invNumber,
      restaurantId: matchedRestaurant.id,
      restaurantName: matchedRestaurant.name,
      date: invDate,
      dueDate: dueDate ?? '',
      items: resolvedItems,
      totalSell: totalSell,
      totalBuy: totalBuy,
      deliveryCost: effectiveDelivery,
      otherCost: effectiveOther,
      profit: profit,
      notes: combinedNotes,
      status: 'pending',
      createdAt: nowIso,
      updatedAt: nowIso,
    );

    final invList = List<Invoice>.from(_vault.invoices);
    final existingIdx = invList.indexWhere((inv) => inv.id == newInvoice.id);
    if (existingIdx >= 0) {
      invList[existingIdx] = newInvoice;
    } else {
      invList.insert(0, newInvoice);
    }
    await _vault.setInvoices(invList, sync: false);

    // Sync linked operational expenses (matching InvoicesViewModel.saveInvoice)
    final replacedExpenses =
        _vault.expenses.where((e) => e.invId == newInvoice.id).toList();
    for (final exp in replacedExpenses) {
      await _vault.markRecordDeleted('expenses', exp.id, sync: false);
    }
    final nextExpenses =
        _vault.expenses.where((e) => e.invId != newInvoice.id).toList();
    if (effectiveDelivery > 0) {
      nextExpenses.add(
        Expense(
          id: AppHelpers.genId(),
          invId: newInvoice.id,
          type: 'expense',
          date: invDate,
          desc: 'Delivery: ${newInvoice.number} (${newInvoice.restaurantName})',
          category: 'transport',
          amount: effectiveDelivery,
        ),
      );
    }
    if (effectiveOther > 0) {
      nextExpenses.add(
        Expense(
          id: AppHelpers.genId(),
          invId: newInvoice.id,
          type: 'expense',
          date: invDate,
          desc: 'Ops Cost: ${newInvoice.number} (${newInvoice.restaurantName})',
          category: 'other',
          amount: effectiveOther,
        ),
      );
    }
    if (replacedExpenses.isNotEmpty ||
        effectiveDelivery > 0 ||
        effectiveOther > 0) {
      await _vault.setExpenses(nextExpenses, sync: false);
    }

    if (!await _vault.syncNow()) {
      throw StateError(
        'The invoice is only saved locally because the encrypted vault did not confirm sync. Retry sync before approving again.',
      );
    }

    await _updateLocalDocketApproved(
      item.copyWith(
        restaurantName: matchedRestaurant.name,
        invoiceDate: invDate,
        deliveryCost: effectiveDelivery,
        otherCost: effectiveOther,
        totalSell: totalSell,
        totalBuy: totalBuy,
        itemsJson: resolvedItems,
      ),
      invNumber,
    );

    if (!await _supabase.checkStagedInvoicesAccessible()) {
      throw StateError(
        'The invoice is saved locally, but Supabase could not confirm the docket status.',
      );
    }

    final statusUpdated = await _supabase.updateStagedInvoiceStatus(id, {
      'status': 'approved',
      'rejection_reason': '',
      'restaurant_name': matchedRestaurant.name,
      'invoice_date': invDate,
      'delivery_cost': effectiveDelivery,
      'other_cost': effectiveOther,
      'total_sell': totalSell,
      'total_buy': totalBuy,
      'items_json': resolvedItems.map((e) => e.toJson()).toList(),
    });
    if (!statusUpdated) {
      throw StateError(
        'The invoice is safely in the vault, but the docket status did not sync.',
      );
    }

    await getPendingSubmissions();
    return newInvoice;
  }

  Future<void> rejectSubmission(String id, [String reason = '']) async {
    if (!await _supabase.checkStagedInvoicesAccessible()) {
      throw StateError(
        'Could not reach the review queue. Reconnect and retry.',
      );
    }
    final updated = await _supabase.rejectStagedInvoice(id, reason);
    if (!updated) {
      throw StateError(
        'This docket is no longer pending. Refresh the queue before changing it.',
      );
    }
    final local = await getLocalQueue();
    final lIdx = local.indexWhere((x) => x.id == id);
    if (lIdx >= 0) {
      local[lIdx] = local[lIdx].copyWith(
        status: 'rejected',
        rejectionReason: reason,
      );
    }
    await setLocalQueue(local);
    await getPendingSubmissions();
  }

  Future<bool> deleteSubmission(String id) async {
    if (!await _supabase.checkStagedInvoicesAccessible()) {
      throw StateError(
        'Could not reach the review queue. Reconnect and retry.',
      );
    }
    final removed = await _supabase.deleteUnapprovedStagedInvoice(id);
    if (!removed) {
      throw StateError(
        'Only an unapproved docket can be deleted. Refresh the queue and check its status.',
      );
    }
    final deletedIds = await getDeletedQueueIds();
    await setDeletedQueueIds([...deletedIds, id]);
    final local = (await getLocalQueue()).where((x) => x.id != id).toList();
    await setLocalQueue(local);
    await getPendingSubmissions();
    return true;
  }

  static String exportDocketAsCode(StagingDocket docket) {
    final jsonBytes = utf8.encode(jsonEncode(docket.toJson()));
    return base64Encode(jsonBytes);
  }

  static StagingDocket parseDocketCode(String rawStr) {
    final trimmed = rawStr.trim();
    Map<String, dynamic>? decoded;
    try {
      final bytes = base64Decode(trimmed);
      final obj = jsonDecode(utf8.decode(bytes));
      if (obj is Map) decoded = Map<String, dynamic>.from(obj);
    } catch (_) {
      try {
        final obj = jsonDecode(trimmed);
        if (obj is Map) decoded = Map<String, dynamic>.from(obj);
      } catch (_) {
        throw const FormatException(
          'Invalid docket format. Provide valid docket JSON or exported code.',
        );
      }
    }
    if (decoded == null ||
        decoded['restaurant_name'] == null ||
        decoded['items_json'] is! List) {
      throw const FormatException(
        'Invalid docket: missing restaurant name or line items.',
      );
    }
    return StagingDocket.fromJson(decoded);
  }

  Future<void> _updateLocalDocketApproved(
    StagingDocket item,
    String invNumber,
  ) async {
    final local = await getLocalQueue();
    final updated = item.copyWith(
      status: 'approved',
      rejectionReason: '',
      approvedAt: DateTime.now().toUtc().toIso8601String(),
      generatedInvoiceNumber: invNumber,
    );
    final idx = local.indexWhere((x) => x.id == item.id);
    if (idx >= 0) {
      local[idx] = updated;
    } else {
      local.insert(0, updated);
    }
    await setLocalQueue(local);
  }
}
